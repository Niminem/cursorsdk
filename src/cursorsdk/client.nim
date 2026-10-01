## `Client`: owns one managed (or attached) bridge and exposes typed
## low-level RPCs mirroring `SdkAgentService`, `SdkCursorService`, and
## `SdkBridgeControlService`. The `Agent` and `Run` handles build on this.
##
## The bridge is started lazily on the first RPC and stopped by `close`.

import std/[asyncdispatch, json, os, options, strutils]
import bridge, connect, errors, types

export options, types, errors
export bridge.Bridge, bridge.BridgeInfo, bridge.hasExited, bridge.waitExit, bridge.outputTailText

const
  ApiKeyEnv* = "CURSOR_API_KEY"
  AgentService = "SdkAgentService"
  CursorService = "SdkCursorService"
  ControlService = "SdkBridgeControlService"

type
  ClientOptions* = object
    apiKey*: string
      ## Cursor API key. Empty: `CURSOR_API_KEY` from the environment.
    workspace*: string
      ## Bridge `--workspace` and default `cwd` for local agents. Empty: cwd.
    bridgePath*: string
      ## Explicit bridge executable. Empty: `CURSOR_SDK_BRIDGE_BIN`, cache, download.
    bridgeUrl*: string
      ## Attach to an already-running bridge instead of spawning one.
    bridgeToken*: string
      ## Bearer token for `bridgeUrl`.
    stateRoot*: string
    localStore*: Option[LocalAgentStoreConfig]
      ## Default store for every agent (`--local-store`).
    verbose*: bool
      ## Pass `--verbose` so the bridge logs every RPC to stderr.
    onBridgeOutput*: proc(line: string) {.gcsafe.}
      ## Receives bridge stderr lines (diagnostics). Default: dropped.
    startupTimeoutMs*: int       ## 0 → 30 000
    unaryTimeoutMs*: int         ## 0 → 60 000
    allowDownload*: bool         ## default true
    env*: seq[(string, string)]  ## extra bridge environment
    toolCallbackUrl*, toolCallbackToken*: string
      ## Launch-time custom-tool callback registration (see callbacks.nim).
    storeCallbackUrl*, storeCallbackToken*: string
      ## Launch-time store callback registration (custom stores).

  Client* = ref object
    opts*: ClientOptions
    bridge*: Bridge
    rpc*: ConnectClient
    startFut: Future[void]
    closed: bool

proc initClientOptions*(): ClientOptions =
  ClientOptions(allowDownload: true)

proc normalizeWorkspace*(path: string): string =
  ## Canonical absolute path (symlinks resolved when the directory exists).
  ## The bridge keys each local agent store by the exact cwd string, so the
  ## same canonical form must be used for the bridge workspace, agent `cwd`,
  ## and management-call `cwd` options.
  let p = if path.len == 0: getCurrentDir() else: path
  try:
    result = expandFilename(p)
  except OSError:
    result = absolutePath(p)

proc newClient*(opts: ClientOptions): Client =
  ## Creates a client. Nothing is spawned until the first RPC (or `start`).
  var o = opts
  if o.apiKey.len == 0: o.apiKey = getEnv(ApiKeyEnv)
  o.workspace = normalizeWorkspace(o.workspace)
  Client(opts: o)

proc newClient*(apiKey = "", workspace = ""): Client =
  var o = initClientOptions()
  o.apiKey = apiKey
  o.workspace = workspace
  newClient(o)

proc apiKey*(c: Client): string = c.opts.apiKey

proc requireApiKey*(c: Client): string =
  ## The configured API key, or an `AuthError` explaining how to set one.
  if c.opts.apiKey.len == 0:
    raise newRpcError(ccUnauthenticated,
      "no Cursor API key: set " & ApiKeyEnv & " or ClientOptions.apiKey")
  c.opts.apiKey

proc startImpl(c: Client) {.async.} =
  if c.opts.bridgeUrl.len > 0:
    c.bridge = attachBridge(c.opts.bridgeUrl, c.opts.bridgeToken)
  else:
    var lo = initBridgeLaunchOptions()
    lo.exe = c.opts.bridgePath
    lo.workspace = c.opts.workspace
    lo.stateRoot = c.opts.stateRoot
    if c.opts.localStore.isSome: lo.localStore = $c.opts.localStore.get.toJson
    lo.toolCallbackUrl = c.opts.toolCallbackUrl
    lo.toolCallbackToken = c.opts.toolCallbackToken
    lo.storeCallbackUrl = c.opts.storeCallbackUrl
    lo.storeCallbackToken = c.opts.storeCallbackToken
    lo.apiKey = c.opts.apiKey
    lo.verbose = c.opts.verbose
    lo.env = c.opts.env
    lo.startupTimeoutMs = c.opts.startupTimeoutMs
    lo.allowDownload = c.opts.allowDownload
    lo.onOutput = c.opts.onBridgeOutput
    c.bridge = await launchBridge(lo)
  c.rpc = newConnectClient(c.bridge.url, c.bridge.token,
                           unaryTimeoutMs = (if c.opts.unaryTimeoutMs > 0: c.opts.unaryTimeoutMs else: 60_000))

proc start*(c: Client): Future[void] =
  ## Starts (or attaches to) the bridge. Idempotent; concurrent callers
  ## share one startup.
  if c.closed:
    var f = newFuture[void]("Client.start")
    f.fail((ref BridgeError)(msg: "client is closed"))
    return f
  if c.startFut.isNil:
    c.startFut = c.startImpl()
    # Allow retry after a failed start.
    c.startFut.callback = proc (f: Future[void]) =
      if f.failed: c.startFut = nil
  c.startFut

proc isStarted*(c: Client): bool = c.rpc != nil

proc ensure(c: Client): Future[void] {.inline.} = c.start()

proc close*(c: Client, graceSeconds = 0, timeoutMs = 5_000) {.async.} =
  ## Shuts the managed bridge down (`Shutdown` RPC → wait → kill).
  ## Idempotent. Attached bridges are left running.
  if c.closed: return
  c.closed = true
  if c.bridge != nil:
    await c.bridge.shutdown(graceSeconds, timeoutMs)

# ---------------------------------------------------------------------------
# Raw access

proc call*(c: Client, service, meth: string, request: JsonNode = nil): Future[JsonNode] {.async.} =
  ## Unary RPC escape hatch: `await client.call("SdkAgentService", "GetAgent", %*{...})`.
  await c.ensure()
  result = await c.rpc.unary(service, meth, request)

proc stream*(c: Client, service, meth: string, request: JsonNode = nil): Future[ConnectStream] {.async.} =
  ## Server-stream RPC escape hatch.
  await c.ensure()
  result = await c.rpc.serverStream(service, meth, request)

# ---------------------------------------------------------------------------
# SdkBridgeControlService

proc ping*(c: Client): Future[string] {.async.} =
  let r = await c.call(ControlService, "Ping", %*{})
  result = jStr(r, "message")

proc bridgeVersion*(c: Client): Future[BridgeVersionInfo] {.async.} =
  let r = await c.call(ControlService, "GetVersion", %*{})
  result = parseBridgeVersionInfo(r)

proc hasCapability*(c: Client, capability: string): Future[bool] {.async.} =
  let v = await c.bridgeVersion()
  result = capability in v.capabilities

proc setToolCallback*(c: Client, url, authToken: string) {.async.} =
  ## Registers (or clears, with an empty `url`) the custom-tool callback
  ## endpoint after startup.
  discard await c.call(ControlService, "SetToolCallback", %*{"url": url, "authToken": authToken})

# ---------------------------------------------------------------------------
# SdkCursorService (catalog; per-call api_key is mandatory)

proc catalogRequest(c: Client): JsonNode =
  %*{"options": {"apiKey": c.requireApiKey()}}

proc me*(c: Client): Future[SdkUser] {.async.} =
  let r = await c.call(CursorService, "Me", c.catalogRequest())
  result = parseSdkUser(jObj(r, "user"))

proc listModels*(c: Client): Future[seq[SdkModel]] {.async.} =
  let r = await c.call(CursorService, "ListModels", c.catalogRequest())
  for m in jArr(r, "items"): result.add parseSdkModel(m)

proc listRepositories*(c: Client): Future[seq[SdkRepository]] {.async.} =
  let r = await c.call(CursorService, "ListRepositories", c.catalogRequest())
  for m in jArr(r, "items"): result.add parseSdkRepository(m)

# ---------------------------------------------------------------------------
# SdkAgentService: agents

proc fillDefaults(c: Client, options: AgentOptions): AgentOptions =
  result = options
  if result.apiKey.len == 0: result.apiKey = c.requireApiKey()
  # `extra["cloud"]` selects the cloud runtime (passthrough only; see README);
  # do not force a local cwd onto such a request.
  let cloud = not result.extra.isNil and result.extra.kind == JObject and result.extra.hasKey("cloud")
  if result.local.cwd.len == 0 and result.local.dirs.len == 0:
    if not cloud: result.local.cwd = c.opts.workspace
  elif result.local.cwd.len > 0:
    result.local.cwd = normalizeWorkspace(result.local.cwd)

proc createAgentRaw*(c: Client, options: AgentOptions, idempotencyKey = ""):
    Future[tuple[agentId: string, model: ModelSelection]] {.async.} =
  var req = %*{"options": c.fillDefaults(options).toJson}
  if idempotencyKey.len > 0: req["idempotencyKey"] = %idempotencyKey
  let r = await c.call(AgentService, "CreateAgent", req)
  result = (jStr(r, "agentId"), parseModelSelection(jObj(r, "model")))

proc resumeAgentRaw*(c: Client, agentId: string, options: AgentOptions):
    Future[tuple[agentId: string, model: ModelSelection]] {.async.} =
  let req = %*{"agentId": agentId, "options": c.fillDefaults(options).toJson}
  let r = await c.call(AgentService, "ResumeAgent", req)
  result = (jStr(r, "agentId", agentId), parseModelSelection(jObj(r, "model")))

proc reloadAgent*(c: Client, agentId: string) {.async.} =
  discard await c.call(AgentService, "ReloadAgent", %*{"agentId": agentId})

proc closeAgent*(c: Client, agentId: string) {.async.} =
  ## Releases local resources for an agent. Durable state is kept.
  discard await c.call(AgentService, "CloseAgent", %*{"agentId": agentId})

proc storeCwd(c: Client, cwd: string): string =
  ## Local agent state is stored per cwd; default to the client workspace.
  if cwd.len > 0: normalizeWorkspace(cwd) else: c.opts.workspace

proc opOptions(c: Client, cwd = ""): JsonNode =
  %*{"apiKey": c.apiKey, "cwd": c.storeCwd(cwd)}

proc getAgent*(c: Client, agentId: string, cwd = ""): Future[SdkAgentInfo] {.async.} =
  ## `cwd` selects the local store; defaults to the client workspace.
  let r = await c.call(AgentService, "GetAgent", %*{"agentId": agentId, "options": c.opOptions(cwd)})
  result = parseSdkAgentInfo(jObj(r, "agent"))

proc listAgents*(c: Client, options = ListAgentsOptions()): Future[Page[SdkAgentInfo]] {.async.} =
  var o = options
  o.cwd = c.storeCwd(o.cwd)
  let r = await c.call(AgentService, "ListAgents", %*{"options": o.toJson(c.apiKey)})
  for a in jArr(r, "items"): result.items.add parseSdkAgentInfo(a)
  result.nextCursor = jStr(r, "nextCursor")

proc archiveAgent*(c: Client, agentId: string, cwd = "") {.async.} =
  discard await c.call(AgentService, "ArchiveAgent", %*{"agentId": agentId, "options": c.opOptions(cwd)})

proc unarchiveAgent*(c: Client, agentId: string, cwd = "") {.async.} =
  discard await c.call(AgentService, "UnarchiveAgent", %*{"agentId": agentId, "options": c.opOptions(cwd)})

proc deleteAgent*(c: Client, agentId: string, cwd = "") {.async.} =
  ## Permanently deletes an agent and its durable data.
  discard await c.call(AgentService, "DeleteAgent", %*{"agentId": agentId, "options": c.opOptions(cwd)})

proc listAgentMessages*(c: Client, agentId: string,
                        options = ListAgentMessagesOptions()): Future[seq[AgentMessage]] {.async.} =
  var o = options
  o.cwd = c.storeCwd(o.cwd)
  let r = await c.call(AgentService, "ListAgentMessages",
                       %*{"agentId": agentId, "options": o.toJson(c.apiKey)})
  for m in jArr(r, "messages"): result.add parseAgentMessage(m)

# ---------------------------------------------------------------------------
# SdkAgentService: runs

proc sendRaw*(c: Client, agentId: string, message: UserMessage,
              options = SendOptions(), idempotencyKey = ""): Future[ConnectStream] {.async.} =
  ## Opens the live `Send` stream. Prefer `Agent.send`, which wraps it in a `Run`.
  var req = %*{"agentId": agentId, "message": message.toJson, "options": options.toJson}
  if idempotencyKey.len > 0: req["idempotencyKey"] = %idempotencyKey
  result = await c.stream(AgentService, "Send", req)

proc observeRunRaw*(c: Client, runId: string, afterOffset = ""): Future[ConnectStream] {.async.} =
  ## Opens the durable `ObserveRun` stream. Only pass offsets that came
  ## from a previous `ObserveRun` stream.
  var req = %*{"runId": runId}
  if afterOffset.len > 0: req["afterOffset"] = %afterOffset
  result = await c.stream(AgentService, "ObserveRun", req)

proc waitLiveRun*(c: Client, runId: string): Future[RunResult] {.async.} =
  ## Blocks until the run is terminal and returns its result.
  let r = await c.call(AgentService, "WaitLiveRun", %*{"runId": runId})
  result = parseRunResult(jObj(r, "result"))

proc getRun*(c: Client, runId: string, agentId = "", cwd = ""): Future[RunSnapshot] {.async.} =
  ## `cwd` selects the local store; defaults to the client workspace.
  var opts = c.opOptions(cwd)
  if agentId.len > 0: opts["agentId"] = %agentId
  let r = await c.call(AgentService, "GetRun", %*{"runId": runId, "options": opts})
  result = parseRunResult(jObj(r, "run"))

proc listRuns*(c: Client, agentId: string, options = ListRunsOptions()): Future[Page[RunSnapshot]] {.async.} =
  var o = options
  o.cwd = c.storeCwd(o.cwd)
  let r = await c.call(AgentService, "ListRuns", %*{"agentId": agentId, "options": o.toJson(c.apiKey)})
  for s in jArr(r, "items"): result.items.add parseRunResult(s)
  result.nextCursor = jStr(r, "nextCursor")

proc getRunConversation*(c: Client, runId: string): Future[JsonNode] {.async.} =
  ## The opaque conversation document for a run, parsed from JSON.
  let r = await c.call(AgentService, "GetRunConversation", %*{"runId": runId})
  let text = jStr(r, "conversationJson")
  if text.len == 0: return newJObject()
  try:
    result = parseJson(text)
  except JsonParsingError, ValueError:
    result = %text

proc cancelRun*(c: Client, runId: string, agentId = "") {.async.} =
  var req = %*{"runId": runId}
  if agentId.len > 0: req["agentId"] = %agentId
  discard await c.call(AgentService, "CancelRun", req)

# ---------------------------------------------------------------------------
# SdkAgentService: artifacts and usage (cloud agents; included for completeness)

proc listArtifacts*(c: Client, agentId: string): Future[seq[SdkArtifact]] {.async.} =
  let r = await c.call(AgentService, "ListArtifacts", %*{"agentId": agentId})
  for a in jArr(r, "artifacts"): result.add parseSdkArtifact(a)

proc downloadArtifact*(c: Client, agentId, path: string): Future[string] {.async.} =
  ## Downloads an artifact; returns the raw bytes as a string.
  let s = await c.stream(AgentService, "DownloadArtifact", %*{"agentId": agentId, "path": path})
  while true:
    let m = await s.next()
    if m.isNone: break
    let data = jStr(m.get, "data")
    if data.len > 0: result.add decodeBase64Lenient(data)

proc getUsage*(c: Client, agentId: string, runId = ""): Future[AgentUsage] {.async.} =
  var req = %*{"agentId": agentId}
  if runId.len > 0: req["runId"] = %runId
  let r = await c.call(AgentService, "GetUsage", req)
  result = parseAgentUsage(jObj(r, "usage"))
