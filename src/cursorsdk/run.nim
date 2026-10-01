## `Run`: the streaming surface for one agent turn.
##
## Wraps a live `Send` stream or a durable `ObserveRun` stream. Iterate
## events with `next`, pull assistant text with `nextText`, or block with
## `wait`. A dropped stream never cancels the run: `observe` re-attaches and
## `wait` falls back to `WaitLiveRun`. A bridge that exits mid-run does kill
## the run; `wait` then raises `TransportError` ("run lost").
##
## See vendor/sdk-bridge/docs/streaming.md.

import std/[asyncdispatch, json, options]
import client, connect, errors, types

type
  RunError* = object of CursorError
    ## Raised by `prompt`-style helpers when a run ends in `ERROR`,
    ## `CANCELLED`, or `EXPIRED`. `wait` itself does not raise for these;
    ## inspect `RunResult.status` instead.
    status*: RunLifecycleStatus
    errorCode*: Option[string]
    statusMessage*: string           ## last human-readable `status` message
    result*: RunResult

  Run* = ref object
    client*: Client
    agentId*: string
    runId*: string                   ## known after the first event
    lastOffset*: string              ## last non-empty offset seen
    status*: RunLifecycleStatus
    errorCode*: Option[string]
    lastStatusMessage*: string
    keepalives*: int                 ## empty envelopes skipped by `next`
    stream: ConnectStream
    fromObserve: bool
    finished: bool
    resultOpt: Option[RunResult]
    relaunchesAtStart: int           ## detects a bridge that died under this run

proc newRun*(client: Client, agentId: string, stream: ConnectStream, fromObserve = false): Run =
  Run(client: client, agentId: agentId, stream: stream, fromObserve: fromObserve,
      relaunchesAtStart: client.relaunches)

proc finished*(r: Run): bool = r.finished
proc isObserve*(r: Run): bool = r.fromObserve

proc result*(r: Run): Option[RunResult] =
  ## The terminal result, once the `result` event has been seen.
  r.resultOpt

proc text*(r: Run): string =
  ## Final assistant text, or "" before the run completes.
  if r.resultOpt.isSome: r.resultOpt.get.text else: ""

proc close*(r: Run) =
  ## Drops the stream. Does not cancel the run.
  r.finished = true
  if r.stream != nil: r.stream.close()

proc track(r: Run, ev: RunEvent) =
  if ev.offset.len > 0: r.lastOffset = ev.offset
  if r.runId.len == 0:
    let id = ev.runId
    if id.len > 0: r.runId = id
  if r.agentId.len == 0:
    let id = ev.agentId
    if id.len > 0: r.agentId = id
  case ev.kind
  of rekMessage:
    if ev.msgType == "status":
      let m = ev.statusMessage
      if m.len > 0: r.lastStatusMessage = m
  of rekResult:
    r.status = ev.result.status
    r.errorCode = ev.result.errorCode
    r.resultOpt = some(ev.result.result)
  of rekDone:
    r.finished = true
  else: discard

proc next*(r: Run): Future[Option[RunEvent]] {.async.} =
  ## Returns the next event, or `none` when the stream has ended.
  ## Keepalives (counted in `keepalives`) and unknown envelope cases are
  ## skipped. Raises
  ## `TransportError` if the connection drops (the run keeps executing;
  ## use `observe` or `wait`) and `RpcError` if the bridge fails the stream.
  while not r.finished:
    var m: Option[JsonNode]
    try:
      m = await r.stream.next()
    except CatchableError:
      r.finished = true
      raise
    if m.isNone:
      r.finished = true
      break
    let ev = parseRunEvent(m.get)
    if ev.kind == rekUnknown:
      if ev.isKeepalive: inc r.keepalives
      # An envelope case this build does not know was still delivered at
      # its offset; advance past it so a later `observe` does not replay
      # it. Keepalives carry no offset (streaming.md) and never advance.
      elif ev.offset.len > 0: r.lastOffset = ev.offset
      continue
    r.track(ev)
    return some(ev)
  result = none(RunEvent)

proc nextText*(r: Run): Future[Option[string]] {.async.} =
  ## Returns the next non-empty chunk of assistant text, or `none` at the end.
  while true:
    let ev = await r.next()
    if ev.isNone: return none(string)
    let t = ev.get.assistantText
    if t.len > 0: return some(t)

proc observe*(r: Run): Future[Run] {.async.} =
  ## Re-attaches to this run's durable event log via `ObserveRun`. Resumes
  ## after `lastOffset` only when this run itself came from `ObserveRun`
  ## (live `Send` offsets use a different numbering); otherwise replays from
  ## the beginning.
  if r.runId.len == 0:
    raise (ref TransportError)(msg: "run id unknown; cannot observe before the first event")
  let after = if r.fromObserve: r.lastOffset else: ""
  let s = await r.client.observeRunRaw(r.runId, after)
  result = newRun(r.client, r.agentId, s, fromObserve = true)
  result.runId = r.runId

const
  BridgeExitGraceMs = 1_500
    ## How long `wait` gives the supervisor to report a bridge exit after
    ## the stream drops. The socket error usually lands a few ms before the
    ## exit event; the bridge 1.0.35 Windows post-cancel crash can take
    ## about a second.
  BridgeExitPollMs = 50

proc bridgeLost(r: Run): bool =
  ## True once the managed bridge this run was started on is gone.
  let b = r.client.bridge
  (b != nil and b.managed and b.hasExited) or r.client.relaunches != r.relaunchesAtStart

proc wait*(r: Run): Future[RunResult] {.async.} =
  ## Drains the stream and returns the terminal `RunResult`. If the
  ## connection drops before the result arrives, falls back to
  ## `WaitLiveRun`. If the managed bridge itself exited, the run died with
  ## it and a `TransportError` ("run lost") is raised instead.
  if r.resultOpt.isSome and r.finished: return r.resultOpt.get
  try:
    while true:
      let ev = await r.next()
      if ev.isNone: break
  except TransportError:
    if r.runId.len == 0: raise
    # On loopback a dropped stream almost always means the bridge died,
    # but its exit is reported by the supervisor thread and can arrive
    # after the socket error. Poll briefly before trusting the port, so
    # this raises "run lost" rather than a connect-refused `TransportError`
    # from `WaitLiveRun`. Attached bridges are never "lost" by this client.
    # (`bridge` is nil only while a managed bridge is being relaunched.)
    let b = r.client.bridge
    if b == nil or b.managed:
      var waited = 0
      while not r.bridgeLost and waited < BridgeExitGraceMs:
        await sleepAsync(BridgeExitPollMs)
        waited += BridgeExitPollMs
      if r.bridgeLost:
        raise (ref TransportError)(msg: "run " & r.runId & " lost: the bridge exited before it finished")
  if r.resultOpt.isSome:
    return r.resultOpt.get
  if r.runId.len == 0:
    raise (ref TransportError)(msg: "stream ended without a result and the run id is unknown")
  result = await r.client.waitLiveRun(r.runId)
  r.status = result.status
  r.resultOpt = some(result)

proc cancel*(r: Run) {.async.} =
  ## Requests cancellation. The stream still delivers a terminal
  ## `CANCELLED` result followed by `done`.
  if r.runId.len == 0:
    raise (ref TransportError)(msg: "run id unknown; cannot cancel before the first event")
  await r.client.cancelRun(r.runId, r.agentId)

proc failed*(r: Run): bool =
  ## True once the run ended with a status other than `FINISHED`.
  r.resultOpt.isSome and r.status != rlsFinished

proc raiseIfFailed*(r: Run) =
  ## Raises `RunError` when `failed`.
  if r.failed:
    var msg = "run " & r.runId & " ended with status " & $r.status
    if r.errorCode.isSome: msg.add " (" & r.errorCode.get & ")"
    if r.lastStatusMessage.len > 0: msg.add ": " & r.lastStatusMessage
    raise (ref RunError)(msg: msg, status: r.status, errorCode: r.errorCode,
                         statusMessage: r.lastStatusMessage, result: r.resultOpt.get)

proc observeRun*(c: Client, runId: string, afterOffset = "", agentId = ""): Future[Run] {.async.} =
  ## Attaches to an existing run's durable events. With `afterOffset`
  ## unset, replays from the beginning.
  let s = await c.observeRunRaw(runId, afterOffset)
  result = newRun(c, agentId, s, fromObserve = true)
  result.runId = runId
  result.lastOffset = afterOffset
