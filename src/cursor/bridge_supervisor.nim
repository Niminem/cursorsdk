## Blocking supervisor thread that owns the `cursor-sdk-bridge` child
## process.
##
## `std/osproc` streams block, and on Windows its pipes are not overlapped,
## so they cannot be driven by `asyncdispatch`. Instead one dedicated thread
## owns the `Process` object, drains its stderr/stdout line by line (the
## bridge blocks if that pipe fills), and reports events to the async side
## through a `Channel`, waking the dispatcher with an `AsyncEvent` after
## every send. The main thread never touches the `Process`; it kills by PID
## when it has to.

import std/[asyncdispatch, osproc, streams, strtabs, os]

type
  BridgeEventKind* = enum
    bekSpawned      ## process started; `pid` is set
    bekSpawnFailed  ## `startProcess` raised; `error` is set
    bekOutput       ## one line of combined stderr/stdout; `line` is set
    bekExited       ## process exited; `exitCode` is set. Always the last event.

  BridgeEvent* = object
    case kind*: BridgeEventKind
    of bekSpawned: pid*: int
    of bekSpawnFailed: error*: string
    of bekOutput: line*: string
    of bekExited: exitCode*: int

  SupervisorShared* = object
    ## Lives in shared memory (`createShared`) for the lifetime of the thread.
    chan*: Channel[BridgeEvent]
    event*: AsyncEvent

  SupervisorConfig* = object
    exe*: string
    args*: seq[string]
    workingDir*: string
    env*: seq[(string, string)]   ## extra/overriding environment entries
    shared*: ptr SupervisorShared

  Supervisor* = object
    shared*: ptr SupervisorShared
    thread: Thread[SupervisorConfig]
    running: bool

proc post(cfg: SupervisorConfig, ev: sink BridgeEvent) =
  cfg.shared.chan.send(ev)
  cfg.shared.event.trigger()

proc supervisorMain(cfg: SupervisorConfig) {.thread.} =
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs(): env[k] = v
  for (k, v) in cfg.env: env[k] = v
  var options = {poStdErrToStdOut}
  when defined(windows):
    options.incl poDaemon  # no console window
  var p: Process
  try:
    p = startProcess(cfg.exe, workingDir = cfg.workingDir, args = cfg.args,
                     env = env, options = options)
  except OSError, IOError:
    cfg.post(BridgeEvent(kind: bekSpawnFailed, error: getCurrentExceptionMsg()))
    return
  cfg.post(BridgeEvent(kind: bekSpawned, pid: p.processID))
  let output = p.outputStream
  var line: string
  try:
    while output.readLine(line):
      cfg.post(BridgeEvent(kind: bekOutput, line: line))
  except IOError, OSError:
    discard  # pipe closed; fall through to waitForExit
  let code = p.waitForExit()
  p.close()
  cfg.post(BridgeEvent(kind: bekExited, exitCode: code))

proc start*(sup: var Supervisor, exe: string, args: seq[string], workingDir: string,
            env: seq[(string, string)]) =
  ## Allocates shared state and launches the supervisor thread. The caller
  ## must register `sup.shared.event` with `addEvent` to receive wakeups.
  doAssert not sup.running
  sup.shared = createShared(SupervisorShared)
  sup.shared.chan.open()
  sup.shared.event = newAsyncEvent()
  let cfg = SupervisorConfig(exe: exe, args: args, workingDir: workingDir,
                             env: env, shared: sup.shared)
  createThread(sup.thread, supervisorMain, cfg)
  sup.running = true

proc tryRecv*(sup: var Supervisor): (bool, BridgeEvent) =
  ## Non-blocking receive; `(false, _)` when the channel is empty.
  if sup.shared == nil: return (false, BridgeEvent())
  let r = sup.shared.chan.tryRecv()
  (r.dataAvailable, r.msg)

proc finish*(sup: var Supervisor) =
  ## Joins the thread (it exits after posting `bekExited`) and frees shared
  ## state. Only call after `bekExited` was observed, or after the process
  ## was killed by PID (the thread then sees EOF and exits on its own).
  if not sup.running: return
  joinThread(sup.thread)
  sup.shared.chan.close()
  try: sup.shared.event.close()
  except CatchableError: discard
  freeShared(sup.shared)
  sup.shared = nil
  sup.running = false

proc isRunning*(sup: Supervisor): bool = sup.running
