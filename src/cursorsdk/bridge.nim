## Bridge manager: spawn `cursor-sdk-bridge`, perform the ready-line
## handshake, read the bearer token, and shut the process down.
##
## See vendor/sdk-bridge/docs/protocol.md.

import std/[asyncdispatch, json, os, strutils, options, deques, locks, exitprocs]
import bridge_supervisor, bridge_fetch, connect, errors, version

export bridge_fetch.BridgeBinEnv, bridge_fetch.locateBridge, bridge_fetch.fetchBridge,
       bridge_fetch.defaultBridgeDir

const
  ReadyPrefix = "cursor-sdk-bridge ready "
  OutputTailLines = 200

type
  BridgeInfo* = object
    ## Parsed discovery line. Unknown JSON keys are preserved in `raw`.
    schemaVersion*: int
    serverVersion*: string
    pid*: int
    transport*: string
    protocol*: string
    host*: string
    port*: int
    url*: string
    authTokenFile*: string
    workspaceRef*: string
    stateRoot*: string
    maxConcurrentAgents*: Option[int]
    maxMessageBytes*: Option[int]
    raw*: JsonNode

  BridgeLaunchOptions* = object
    exe*: string
      ## Bridge executable. Empty: resolve via `locateBridge` (env override,
      ## cache, download).
    workspace*: string
      ## `--workspace`. Empty: current directory.
    stateRoot*: string           ## `--state-root`
    localStore*: string          ## `--local-store` (LocalAgentStoreConfig JSON)
    storeCallbackUrl*: string    ## `--store-callback-url` (with the token, or neither)
    storeCallbackToken*: string  ## `--store-callback-auth-token`
    toolCallbackUrl*: string     ## `--tool-callback-url` (with the token, or neither)
    toolCallbackToken*: string   ## `--tool-callback-auth-token`
    apiKey*: string
      ## Placed in the bridge environment as `CURSOR_API_KEY`. Empty: the
      ## caller's `CURSOR_API_KEY` is inherited if set.
    verbose*: bool               ## `--verbose`: log every RPC to stderr
    env*: seq[(string, string)]  ## extra environment entries
    extraArgs*: seq[string]
      ## Appended verbatim after the generated arguments, for flags without
      ## a dedicated option (`--max-concurrent-agents`, `--max-message-bytes`;
      ## see protocol.md). Not validated here; an unknown flag makes the
      ## bridge exit before ready, with its usage text in `BridgeError.stderr`.
    startupTimeoutMs*: int       ## 0 → 30 000
    allowDownload*: bool         ## download the pinned release if missing (default true)
    onOutput*: proc(line: string) {.gcsafe.}
      ## Receives every bridge stderr/stdout line except the discovery line.

  Bridge* = ref object
    info*: BridgeInfo
    url*: string
    token*: string
    managed*: bool               ## false when attached to an external bridge
    pid*: int
    exitCode*: int
    sup: Supervisor
    exited: bool
    ready: bool
    readyFut: Future[BridgeInfo]
    exitFut: Future[void]
    outputTail: Deque[string]
    onOutput: proc(line: string) {.gcsafe.}
    closed: bool

proc initBridgeLaunchOptions*(): BridgeLaunchOptions =
  BridgeLaunchOptions(startupTimeoutMs: 30_000, allowDownload: true)

# ---------------------------------------------------------------------------
# PID-based kill and exit-time cleanup

when defined(windows):
  import std/winlean
  proc killPid(pid: int) =
    let h = openProcess(PROCESS_TERMINATE, 0, DWORD(pid))
    if h != 0:
      discard terminateProcess(h, 1)
      discard closeHandle(h)
else:
  import std/posix
  proc killPid(pid: int) =
    discard posix.kill(Pid(pid), SIGKILL)

var
  managedPidsLock: Lock
  managedPids {.guard: managedPidsLock.}: seq[int]
  exitProcInstalled = false

initLock(managedPidsLock)

# The registry is a GC'd global guarded by a lock and only touched from the
# main thread plus the exit handler, so the gcsafe casts are sound.

proc killAllManaged() {.noconv, gcsafe.} =
  var pids: seq[int]
  {.cast(gcsafe).}:
    withLock managedPidsLock:
      pids = managedPids
      managedPids.setLen(0)
  for pid in pids:
    killPid(pid)

proc trackPid(pid: int) {.gcsafe.} =
  {.cast(gcsafe).}:
    withLock managedPidsLock:
      managedPids.add pid
      if not exitProcInstalled:
        exitProcInstalled = true
        addExitProc(killAllManaged)

proc untrackPid(pid: int) {.gcsafe.} =
  {.cast(gcsafe).}:
    withLock managedPidsLock:
      let i = managedPids.find(pid)
      if i >= 0: managedPids.delete(i)

# ---------------------------------------------------------------------------
# Discovery line

proc parseReadyLine*(line: string): BridgeInfo =
  ## Parses the JSON following the `cursor-sdk-bridge ready ` prefix.
  ## Raises `BridgeError` when required fields are missing or invalid.
  if not line.startsWith(ReadyPrefix):
    raise (ref BridgeError)(msg: "not a bridge discovery line")
  var node: JsonNode
  try:
    node = parseJson(line[ReadyPrefix.len .. ^1])
  except JsonParsingError, ValueError:
    raise (ref BridgeError)(msg: "malformed bridge discovery JSON")
  if node.kind != JObject:
    raise (ref BridgeError)(msg: "bridge discovery payload is not an object")
  result.raw = node
  result.schemaVersion = node.getOrDefault("schemaVersion").getInt(-1)
  if result.schemaVersion != 1:
    raise (ref BridgeError)(msg: "unsupported bridge discovery schemaVersion " & $result.schemaVersion)
  result.transport = node.getOrDefault("transport").getStr
  if result.transport != "tcp":
    raise (ref BridgeError)(msg: "unsupported bridge transport: " & result.transport)
  result.protocol = node.getOrDefault("protocol").getStr
  if result.protocol != "connect":
    raise (ref BridgeError)(msg: "unsupported bridge protocol: " & result.protocol)
  result.serverVersion = node.getOrDefault("serverVersion").getStr
  result.pid = node.getOrDefault("pid").getInt
  result.host = node.getOrDefault("host").getStr
  result.port = node.getOrDefault("port").getInt
  result.url = node.getOrDefault("url").getStr
  if result.url.len == 0:
    if result.host.len == 0 or result.port == 0:
      raise (ref BridgeError)(msg: "bridge discovery line has no url/host/port")
    let h = if result.host.contains(':'): "[" & result.host & "]" else: result.host
    result.url = "http://" & h & ":" & $result.port
  result.authTokenFile = node.getOrDefault("authTokenFile").getStr
  result.workspaceRef = node.getOrDefault("workspaceRef").getStr
  result.stateRoot = node.getOrDefault("stateRoot").getStr
  if node.hasKey("maxConcurrentAgents"):
    result.maxConcurrentAgents = some(node["maxConcurrentAgents"].getInt)
  if node.hasKey("maxMessageBytes"):
    result.maxMessageBytes = some(node["maxMessageBytes"].getInt)

proc readToken(info: BridgeInfo): string =
  # Older bridges inline the token; prefer it when present.
  let inline = info.raw.getOrDefault("authToken")
  if not inline.isNil and inline.kind == JString and inline.getStr.len > 0:
    return inline.getStr
  if info.authTokenFile.len == 0:
    raise (ref BridgeError)(msg: "bridge discovery line has no authTokenFile")
  try:
    result = readFile(info.authTokenFile).strip()
  except IOError, OSError:
    raise (ref BridgeError)(msg: "cannot read bridge auth token file " & info.authTokenFile &
                                 ": " & getCurrentExceptionMsg())
  if result.len == 0:
    raise (ref BridgeError)(msg: "bridge auth token file is empty: " & info.authTokenFile)

# ---------------------------------------------------------------------------
# Event pump

proc outputTailText*(b: Bridge): string =
  ## Recent bridge output, for diagnostics.
  var lines: seq[string]
  for l in b.outputTail: lines.add l
  lines.join("\n")

proc recordOutput(b: Bridge, line: string) =
  if b.outputTail.len >= OutputTailLines: discard b.outputTail.popFirst()
  b.outputTail.addLast line
  if b.onOutput != nil:
    try: b.onOutput(line)
    except CatchableError: discard

proc handleEvent(b: Bridge, ev: BridgeEvent) =
  case ev.kind
  of bekSpawned:
    b.pid = ev.pid
    trackPid(ev.pid)
  of bekSpawnFailed:
    b.exited = true
    if not b.readyFut.finished:
      b.readyFut.fail((ref BridgeError)(msg: "failed to start cursor-sdk-bridge: " & ev.error))
    if not b.exitFut.finished: b.exitFut.complete()
  of bekOutput:
    if not b.ready and ev.line.startsWith(ReadyPrefix):
      # Never forward or log the discovery line: older bridges inline the token.
      try:
        let info = parseReadyLine(ev.line)
        b.ready = true
        if not b.readyFut.finished: b.readyFut.complete(info)
      except BridgeError as e:
        if not b.readyFut.finished: b.readyFut.fail(e)
    else:
      b.recordOutput(ev.line)
  of bekExited:
    b.exited = true
    b.exitCode = ev.exitCode
    untrackPid(b.pid)
    if not b.readyFut.finished:
      b.readyFut.fail((ref BridgeError)(
        msg: "cursor-sdk-bridge exited with code " & $ev.exitCode & " before becoming ready",
        stderr: b.outputTailText()))
    if not b.exitFut.finished: b.exitFut.complete()

proc drain(b: Bridge): bool =
  ## Called when the supervisor signals; returns true to unregister.
  while true:
    let (ok, ev) = b.sup.tryRecv()
    if not ok: break
    b.handleEvent(ev)
  b.exited

# ---------------------------------------------------------------------------
# Launch / attach

proc requirePair*(urlName, url, tokenName, token: string) =
  ## Raises `BridgeError` unless `url` and `token` are both set or both
  ## empty. protocol.md: "Callback URL/token pairs must be provided together;
  ## supplying only one is a startup error." Checked client-side so the
  ## message names the option instead of surfacing as a bridge exit.
  if (url.len > 0) != (token.len > 0):
    let missing = if url.len > 0: tokenName else: urlName
    raise (ref BridgeError)(msg: urlName & " and " & tokenName &
                                 " must be set together (" & missing & " is empty)")

proc validate(opts: BridgeLaunchOptions) =
  requirePair("storeCallbackUrl", opts.storeCallbackUrl,
              "storeCallbackToken", opts.storeCallbackToken)
  requirePair("toolCallbackUrl", opts.toolCallbackUrl,
              "toolCallbackToken", opts.toolCallbackToken)

proc buildArgs(opts: BridgeLaunchOptions, workspace: string): seq[string] =
  # Pairs are complete here: `validate` ran first.
  result = @["--workspace", workspace]
  if opts.stateRoot.len > 0: result.add ["--state-root", opts.stateRoot]
  if opts.localStore.len > 0: result.add ["--local-store", opts.localStore]
  if opts.storeCallbackUrl.len > 0:
    result.add ["--store-callback-url", opts.storeCallbackUrl,
                "--store-callback-auth-token", opts.storeCallbackToken]
  if opts.toolCallbackUrl.len > 0:
    result.add ["--tool-callback-url", opts.toolCallbackUrl,
                "--tool-callback-auth-token", opts.toolCallbackToken]
  if opts.verbose: result.add "--verbose"
  result.add opts.extraArgs

proc launchBridge*(opts: BridgeLaunchOptions): Future[Bridge] {.async.} =
  ## Spawns the bridge and completes the handshake. The returned `Bridge`
  ## has `url` and `token` set and is ready for RPCs. Raises `BridgeError`
  ## before spawning if a callback URL/token pair is incomplete.
  opts.validate()
  var exe = opts.exe
  if exe.len == 0:
    exe = locateBridge(allowDownload = opts.allowDownload,
                       log = if opts.onOutput != nil: opts.onOutput else: nil)
  # The caller (Client) has already canonicalised this; fall back to cwd.
  let workspace = if opts.workspace.len > 0: opts.workspace else: getCurrentDir()
  var env = @[("CURSOR_SDK_CLIENT_LANGUAGE", ClientLanguage)]
  if opts.apiKey.len > 0: env.add ("CURSOR_API_KEY", opts.apiKey)
  env.add opts.env
  let b = Bridge(managed: true, onOutput: opts.onOutput)
  b.readyFut = newFuture[BridgeInfo]("launchBridge.ready")
  b.exitFut = newFuture[void]("launchBridge.exit")
  b.sup.start(exe, buildArgs(opts, workspace), workspace, env)
  addEvent(b.sup.shared.event, proc (fd: AsyncFD): bool {.gcsafe.} = b.drain())
  let timeoutMs = if opts.startupTimeoutMs > 0: opts.startupTimeoutMs else: 30_000
  let becameReady = await b.readyFut.withTimeout(timeoutMs)
  if not becameReady:
    if b.pid != 0: killPid(b.pid)
    discard await b.exitFut.withTimeout(2_000)
    b.sup.finish()
    raise (ref BridgeError)(msg: "cursor-sdk-bridge did not become ready within " &
                                 $timeoutMs & " ms", stderr: b.outputTailText())
  try:
    b.info = await b.readyFut
  except BridgeError:
    b.sup.finish()
    raise
  if b.pid == 0: b.pid = b.info.pid
  b.url = b.info.url
  try:
    b.token = readToken(b.info)
  except BridgeError:
    killPid(b.pid)
    discard await b.exitFut.withTimeout(2_000)
    b.sup.finish()
    raise
  result = b

proc attachBridge*(url, token: string): Bridge =
  ## Wraps an already-running bridge. `shutdown` is a no-op for attached
  ## bridges; the owner of the process is responsible for stopping it.
  Bridge(managed: false, url: url, token: token,
         info: BridgeInfo(url: url, transport: "tcp", protocol: "connect", schemaVersion: 1))

proc hasExited*(b: Bridge): bool = b.exited

proc waitExit*(b: Bridge): Future[void] =
  ## Completes when a managed bridge process exits (immediately if attached).
  if b.managed: return b.exitFut
  result = newFuture[void]("attached")
  result.complete()

# ---------------------------------------------------------------------------
# Shutdown

proc shutdown*(b: Bridge, graceSeconds = 0, timeoutMs = 5_000) {.async.} =
  ## Graceful stop: `Shutdown` RPC, wait up to `timeoutMs`, then kill.
  ## Idempotent. No-op for attached bridges.
  if b == nil or b.closed: return
  b.closed = true
  if not b.managed: return
  if not b.exited:
    try:
      let rpc = newConnectClient(b.url, b.token, unaryTimeoutMs = min(timeoutMs, 5_000))
      discard await rpc.unary("SdkBridgeControlService", "Shutdown",
                              %*{"graceSeconds": graceSeconds})
    except CatchableError:
      discard  # fall through to waiting / killing
    let exitedInTime = await b.exitFut.withTimeout(timeoutMs)
    if not exitedInTime:
      killPid(b.pid)
      discard await b.exitFut.withTimeout(2_000)
  untrackPid(b.pid)
  if b.exited:
    b.sup.finish()
  else:
    # Process survived SIGKILL (should not happen); leave the thread to
    # exit on its own rather than blocking forever in joinThread.
    discard
