## Nim types mirroring the `sdk.v1` protobuf contract (proto3 JSON mapping:
## camelCase keys, enums as `PREFIX_NAME` strings, 64-bit integers as
## strings, `google.protobuf.Struct` as free-form `JsonNode`).
##
## Request types serialize with `toJson`; response types parse with
## `parse*`. Parsers ignore unknown fields and tolerate unknown enum values
## so an adapter built against this tag keeps working with newer bridges.
##
## Scope: local agents. Cloud-only option messages are not modelled, but
## `AgentOptions.extra` lets callers pass any raw JSON the bridge accepts.
## See vendor/sdk-bridge/proto/sdk/v1/sdk_messages.proto.

import std/[json, options, tables, strutils, times]

# ---------------------------------------------------------------------------
# JSON helpers (exported for use by the client layer)

proc jStr*(n: JsonNode, key: string, default = ""): string =
  if n.isNil or n.kind != JObject: return default
  let v = n.getOrDefault(key)
  if v.isNil or v.kind != JString: default else: v.getStr

proc jStrOpt*(n: JsonNode, key: string): Option[string] =
  if n.isNil or n.kind != JObject: return
  let v = n.getOrDefault(key)
  if not v.isNil and v.kind == JString: some(v.getStr) else: none(string)

proc jInt*(n: JsonNode, key: string, default = 0): int =
  if n.isNil or n.kind != JObject: return default
  let v = n.getOrDefault(key)
  if v.isNil: return default
  case v.kind
  of JInt: v.getInt
  of JString:
    try: parseInt(v.getStr)
    except ValueError: default
  of JFloat: int(v.getFloat)
  else: default

proc jInt64*(n: JsonNode, key: string, default = 0'i64): int64 =
  if n.isNil or n.kind != JObject: return default
  let v = n.getOrDefault(key)
  if v.isNil: return default
  case v.kind
  of JInt: v.getBiggestInt
  of JString:
    try: parseBiggestInt(v.getStr)
    except ValueError: default
  of JFloat: int64(v.getFloat)
  else: default

proc jU64*(n: JsonNode, key: string, default = 0'u64): uint64 =
  if n.isNil or n.kind != JObject: return default
  let v = n.getOrDefault(key)
  if v.isNil: return default
  case v.kind
  of JInt: uint64(v.getBiggestInt)
  of JString:
    try: uint64(parseBiggestUInt(v.getStr))
    except ValueError: default
  of JFloat: uint64(v.getFloat)
  else: default

proc jInt64Opt*(n: JsonNode, key: string): Option[int64] =
  if n.isNil or n.kind != JObject or not n.hasKey(key) or n[key].kind == JNull: return
  some(jInt64(n, key))

proc jFloat*(n: JsonNode, key: string, default = 0.0): float =
  if n.isNil or n.kind != JObject: return default
  let v = n.getOrDefault(key)
  if v.isNil: return default
  case v.kind
  of JFloat: v.getFloat
  of JInt: float(v.getBiggestInt)
  of JString:
    try: parseFloat(v.getStr)
    except ValueError: default
  else: default

proc jBool*(n: JsonNode, key: string, default = false): bool =
  if n.isNil or n.kind != JObject: return default
  let v = n.getOrDefault(key)
  if not v.isNil and v.kind == JBool: v.getBool else: default

proc jBoolOpt*(n: JsonNode, key: string): Option[bool] =
  if n.isNil or n.kind != JObject: return
  let v = n.getOrDefault(key)
  if not v.isNil and v.kind == JBool: some(v.getBool) else: none(bool)

proc jObj*(n: JsonNode, key: string): JsonNode =
  ## Returns the object at `key`, or nil.
  if n.isNil or n.kind != JObject: return nil
  let v = n.getOrDefault(key)
  if not v.isNil and v.kind == JObject: v else: nil

proc jArr*(n: JsonNode, key: string): seq[JsonNode] =
  if n.isNil or n.kind != JObject: return
  let v = n.getOrDefault(key)
  if not v.isNil and v.kind == JArray:
    for e in v: result.add e

proc jStrSeq*(n: JsonNode, key: string): seq[string] =
  for e in jArr(n, key):
    if e.kind == JString: result.add e.getStr

proc jStrTable*(n: JsonNode, key: string): Table[string, string] =
  let o = jObj(n, key)
  if o.isNil: return
  for k, v in o:
    if v.kind == JString: result[k] = v.getStr

proc parseTimestamp*(s: string): Option[Time] =
  ## Parses an RFC 3339 timestamp (`google.protobuf.Timestamp` JSON form)
  ## with any fractional-second precision.
  if s.len == 0: return
  var base = s
  var nanos = 0'i64
  let dot = s.find('.')
  if dot >= 0:
    var endIdx = dot + 1
    while endIdx < s.len and s[endIdx] in Digits: inc endIdx
    var frac = s[dot + 1 ..< endIdx]
    if frac.len > 9: frac = frac[0 ..< 9]
    while frac.len < 9: frac.add '0'
    try: nanos = parseBiggestInt(frac)
    except ValueError: nanos = 0
    base = s[0 ..< dot] & s[endIdx .. ^1]
  try:
    let dt = parse(base, "yyyy-MM-dd'T'HH:mm:sszzz", utc())
    result = some(dt.toTime + initDuration(nanoseconds = nanos))
  except TimeParseError, ValueError:
    result = none(Time)

proc jTime*(n: JsonNode, key: string): Option[Time] =
  parseTimestamp(jStr(n, key))

template addIf(o: JsonNode, key: string, cond: bool, value: untyped) =
  if cond: o[key] = %value

template addOpt[T](o: JsonNode, key: string, opt: Option[T]) =
  if opt.isSome: o[key] = %opt.get

# ---------------------------------------------------------------------------
# Enums

type
  Runtime* = enum
    rtUnspecified = "UNSPECIFIED", rtAuto = "AUTO", rtLocal = "LOCAL", rtCloud = "CLOUD"

  RunLifecycleStatus* = enum
    rlsUnspecified = "UNSPECIFIED", rlsCreating = "CREATING", rlsRunning = "RUNNING",
    rlsFinished = "FINISHED", rlsError = "ERROR", rlsCancelled = "CANCELLED",
    rlsExpired = "EXPIRED"

  AgentInfoStatus* = enum
    aisUnspecified = "UNSPECIFIED", aisRunning = "RUNNING", aisFinished = "FINISHED",
    aisError = "ERROR"

  SettingSource* = enum
    ssUnspecified = "UNSPECIFIED", ssProject = "PROJECT", ssUser = "USER", ssTeam = "TEAM",
    ssMdm = "MDM", ssPlugins = "PLUGINS", ssAll = "ALL"

  HttpMcpTransportType* = enum
    hmtUnspecified = "UNSPECIFIED", hmtHttp = "HTTP", hmtSse = "SSE"

  AgentModeOption* = enum
    amoUnspecified = "UNSPECIFIED", amoAgent = "AGENT", amoPlan = "PLAN"

const
  RuntimePrefix = "RUNTIME_"
  RunLifecycleStatusPrefix = "RUN_LIFECYCLE_STATUS_"
  AgentInfoStatusPrefix = "AGENT_INFO_STATUS_"
  SettingSourcePrefix = "SETTING_SOURCE_"
  HttpMcpTransportTypePrefix = "HTTP_MCP_TRANSPORT_TYPE_"
  AgentModeOptionPrefix = "AGENT_MODE_OPTION_"

proc parseProtoEnum[E: enum](n: JsonNode, key, prefix: string, default: E): E =
  ## Accepts `PREFIX_NAME`, bare `NAME`, or the integer ordinal.
  if n.isNil or n.kind != JObject: return default
  let v = n.getOrDefault(key)
  if v.isNil: return default
  case v.kind
  of JString:
    var name = v.getStr
    if name.startsWith(prefix): name = name[prefix.len .. ^1]
    parseEnum[E](name, default)
  of JInt:
    let i = v.getInt
    if i >= ord(low(E)) and i <= ord(high(E)): E(i) else: default
  else: default

proc protoName(e: Runtime): string = RuntimePrefix & $e
proc protoName(e: SettingSource): string = SettingSourcePrefix & $e
proc protoName(e: HttpMcpTransportType): string = HttpMcpTransportTypePrefix & $e
proc protoName(e: AgentModeOption): string = AgentModeOptionPrefix & $e

proc isTerminal*(s: RunLifecycleStatus): bool =
  s in {rlsFinished, rlsError, rlsCancelled, rlsExpired}

# ---------------------------------------------------------------------------
# Shared request/response messages

type
  ModelParameterValue* = object
    id*: string
    value*: string

  ModelSelection* = object
    id*: string                      ## e.g. "composer-2.5"; discover ids via `Client.listModels`
    params*: seq[ModelParameterValue]

  SdkImage* = object
    ## Inline image data (`data` + `mimeType`). `url` is accepted only by
    ## cloud-routed agents and is included for completeness.
    data*: string                    ## base64-encoded bytes
    mimeType*: string
    url*: string
    width*, height*: int             ## optional dimension hint (0 = unset)

  UserMessage* = object
    text*: string
    images*: seq[SdkImage]

proc model*(id: string): ModelSelection = ModelSelection(id: id)

proc toJson*(m: ModelParameterValue): JsonNode = %*{"id": m.id, "value": m.value}

proc toJson*(m: ModelSelection): JsonNode =
  result = %*{"id": m.id}
  if m.params.len > 0:
    var arr = newJArray()
    for p in m.params: arr.add p.toJson
    result["params"] = arr

proc parseModelSelection*(n: JsonNode): ModelSelection =
  if n.isNil: return
  result.id = jStr(n, "id")
  for p in jArr(n, "params"):
    result.params.add ModelParameterValue(id: jStr(p, "id"), value: jStr(p, "value"))

proc toJson*(img: SdkImage): JsonNode =
  result = newJObject()
  if img.data.len > 0:
    result["data"] = %*{"data": img.data, "mimeType": img.mimeType}
  elif img.url.len > 0:
    result["url"] = %*{"url": img.url}
  if img.width > 0 or img.height > 0:
    result["dimension"] = %*{"width": img.width, "height": img.height}

proc toJson*(m: UserMessage): JsonNode =
  result = %*{"text": m.text}
  if m.images.len > 0:
    var arr = newJArray()
    for i in m.images: arr.add i.toJson
    result["images"] = arr

# ---------------------------------------------------------------------------
# MCP / sub-agent configuration

type
  McpAuthConfig* = object
    clientId*, clientSecret*: string
    scopes*: seq[string]

  McpServerKind* = enum mskStdio, mskHttp

  McpServerConfig* = object
    case kind*: McpServerKind
    of mskStdio:
      command*: string
      args*: seq[string]
      env*: Table[string, string]
      cwd*: string
    of mskHttp:
      transport*: HttpMcpTransportType
      url*: string
      headers*: Table[string, string]
      auth*: Option[McpAuthConfig]

  AgentDefinitionMcpServer* = object
    name*: string                    ## reference to a parent-configured server
    inline*: Option[McpServerConfig] ## or an inline config (wins when set)

  AgentDefinition* = object
    description*, prompt*: string
    model*: Option[ModelSelection]
    inheritModel*: Option[bool]
    mcpServers*: seq[AgentDefinitionMcpServer]

proc toJson*(a: McpAuthConfig): JsonNode =
  result = %*{"clientId": a.clientId, "clientSecret": a.clientSecret}
  addIf(result, "scopes", a.scopes.len > 0, a.scopes)

proc toJson*(c: McpServerConfig): JsonNode =
  case c.kind
  of mskStdio:
    var s = %*{"command": c.command}
    addIf(s, "args", c.args.len > 0, c.args)
    addIf(s, "env", c.env.len > 0, c.env)
    addIf(s, "cwd", c.cwd.len > 0, c.cwd)
    result = %*{"stdio": s}
  of mskHttp:
    var h = %*{"url": c.url}
    addIf(h, "type", c.transport != hmtUnspecified, protoName(c.transport))
    addIf(h, "headers", c.headers.len > 0, c.headers)
    if c.auth.isSome: h["auth"] = c.auth.get.toJson
    result = %*{"http": h}

proc toJson*(s: AgentDefinitionMcpServer): JsonNode =
  if s.inline.isSome: %*{"inlineConfig": s.inline.get.toJson}
  else: %*{"name": s.name}

proc toJson*(d: AgentDefinition): JsonNode =
  result = newJObject()
  addIf(result, "description", d.description.len > 0, d.description)
  addIf(result, "prompt", d.prompt.len > 0, d.prompt)
  if d.model.isSome: result["model"] = d.model.get.toJson
  addOpt(result, "inheritModel", d.inheritModel)
  if d.mcpServers.len > 0:
    var arr = newJArray()
    for s in d.mcpServers: arr.add s.toJson
    result["mcpServers"] = arr

# ---------------------------------------------------------------------------
# Agent options (local)

type
  LocalAgentStoreConfig* = object
    kind*: string                    ## "sqlite" (default), "jsonl", or "custom"
    rootDir*: string                 ## required for "jsonl"

  CustomToolDefinition* = object
    description*: Option[string]
    inputSchema*: JsonNode           ## JSON Schema object
    outputSchema*: JsonNode          ## optional JSON Schema object

  LocalAgentOptions* = object
    cwd*: string                     ## primary working directory
    dirs*: seq[string]               ## explicit multi-root workspace folders
    settingSources*: seq[SettingSource]
    sandbox*: Option[bool]
    store*: Option[LocalAgentStoreConfig]
    autoReview*: Option[bool]
    customTools*: Table[string, CustomToolDefinition]

  AgentOptions* = object
    model*: ModelSelection           ## required for local agents
    apiKey*: string                  ## filled in by the client when empty
    name*: string
    local*: LocalAgentOptions
    mcpServers*: Table[string, McpServerConfig]
    agents*: Table[string, AgentDefinition]
    agentId*: string                 ## explicit id (e.g. when resuming)
    mode*: AgentModeOption
    tools*: Option[seq[string]]      ## allow-list of built-in tools (empty = none)
    disallowedTools*: seq[string]
    extra*: JsonNode                 ## raw fields merged into the request

proc toJson*(s: LocalAgentStoreConfig): JsonNode =
  result = %*{"type": s.kind}
  addIf(result, "rootDir", s.rootDir.len > 0, s.rootDir)

proc toJson*(t: CustomToolDefinition): JsonNode =
  result = newJObject()
  addOpt(result, "description", t.description)
  result["inputSchema"] = if t.inputSchema.isNil: %*{"type": "object"} else: t.inputSchema
  if not t.outputSchema.isNil: result["outputSchema"] = t.outputSchema

proc toJson*(l: LocalAgentOptions): JsonNode =
  result = newJObject()
  if l.cwd.len > 0: result["cwd"] = %[l.cwd]
  addIf(result, "dirs", l.dirs.len > 0, l.dirs)
  if l.settingSources.len > 0:
    var arr = newJArray()
    for s in l.settingSources: arr.add %protoName(s)
    result["settingSources"] = arr
  if l.sandbox.isSome: result["sandboxOptions"] = %*{"enabled": l.sandbox.get}
  if l.store.isSome: result["store"] = l.store.get.toJson
  addOpt(result, "autoReview", l.autoReview)
  if l.customTools.len > 0:
    var tools = newJObject()
    for name, t in l.customTools: tools[name] = t.toJson
    result["customTools"] = tools

proc toJson*(o: AgentOptions): JsonNode =
  result = newJObject()
  if o.model.id.len > 0: result["model"] = o.model.toJson
  addIf(result, "apiKey", o.apiKey.len > 0, o.apiKey)
  addIf(result, "name", o.name.len > 0, o.name)
  let local = o.local.toJson
  if local.len > 0: result["local"] = local
  if o.mcpServers.len > 0:
    var servers = newJObject()
    for name, c in o.mcpServers: servers[name] = c.toJson
    result["mcpServers"] = servers
  if o.agents.len > 0:
    var agents = newJObject()
    for name, a in o.agents: agents[name] = a.toJson
    result["agents"] = agents
  addIf(result, "agentId", o.agentId.len > 0, o.agentId)
  addIf(result, "mode", o.mode != amoUnspecified, protoName(o.mode))
  if o.tools.isSome: result["tools"] = %*{"names": o.tools.get}
  addIf(result, "disallowedTools", o.disallowedTools.len > 0, o.disallowedTools)
  if not o.extra.isNil and o.extra.kind == JObject:
    for k, v in o.extra: result[k] = v

# ---------------------------------------------------------------------------
# Send options

type
  SendOptions* = object
    model*: Option[ModelSelection]   ## per-send model override
    mcpServers*: Table[string, McpServerConfig]
    force*: Option[bool]             ## local-only force send
    enableDeltas*: bool              ## emit `interaction_update` events
    enableSteps*: bool               ## emit `step` events
    mode*: AgentModeOption
    extra*: JsonNode

proc toJson*(o: SendOptions): JsonNode =
  result = newJObject()
  if o.model.isSome: result["model"] = o.model.get.toJson
  if o.mcpServers.len > 0:
    var servers = newJObject()
    for name, c in o.mcpServers: servers[name] = c.toJson
    result["mcpServers"] = servers
  if o.force.isSome: result["local"] = %*{"force": o.force.get}
  addIf(result, "enableDeltas", o.enableDeltas, true)
  addIf(result, "enableSteps", o.enableSteps, true)
  addIf(result, "mode", o.mode != amoUnspecified, protoName(o.mode))
  if not o.extra.isNil and o.extra.kind == JObject:
    for k, v in o.extra: result[k] = v

# ---------------------------------------------------------------------------
# Catalog responses

type
  SdkUser* = object
    apiKeyName*: string
    userId*: uint64
    userEmail*, userFirstName*, userLastName*: string
    createdAt*: string

  ModelParameterDefinitionValue* = object
    value*, displayName*: string

  ModelParameterDefinition* = object
    id*, displayName*: string
    values*: seq[ModelParameterDefinitionValue]

  ModelVariant* = object
    params*: seq[ModelParameterValue]
    displayName*, description*: string
    isDefault*: bool

  SdkModel* = object
    id*, displayName*, description*: string
    parameters*: seq[ModelParameterDefinition]
    variants*: seq[ModelVariant]

  SdkRepository* = object
    url*: string

proc parseSdkUser*(n: JsonNode): SdkUser =
  SdkUser(apiKeyName: jStr(n, "apiKeyName"), userId: jU64(n, "userId"),
          userEmail: jStr(n, "userEmail"), userFirstName: jStr(n, "userFirstName"),
          userLastName: jStr(n, "userLastName"), createdAt: jStr(n, "createdAt"))

proc parseSdkModel*(n: JsonNode): SdkModel =
  result.id = jStr(n, "id")
  result.displayName = jStr(n, "displayName")
  result.description = jStr(n, "description")
  for p in jArr(n, "parameters"):
    var def = ModelParameterDefinition(id: jStr(p, "id"), displayName: jStr(p, "displayName"))
    for v in jArr(p, "values"):
      def.values.add ModelParameterDefinitionValue(value: jStr(v, "value"), displayName: jStr(v, "displayName"))
    result.parameters.add def
  for v in jArr(n, "variants"):
    var variant = ModelVariant(displayName: jStr(v, "displayName"), description: jStr(v, "description"),
                               isDefault: jBool(v, "isDefault"))
    for p in jArr(v, "params"):
      variant.params.add ModelParameterValue(id: jStr(p, "id"), value: jStr(p, "value"))
    result.variants.add variant

proc parseSdkRepository*(n: JsonNode): SdkRepository = SdkRepository(url: jStr(n, "url"))

# ---------------------------------------------------------------------------
# Agent info

type
  CloudAgentInfo* = object
    envType*, envName*: string
    repos*: seq[string]
    metadata*: Table[string, string]

  SdkAgentInfo* = object
    agentId*, name*, summary*: string
    lastModified*: Option[Time]
    status*: AgentInfoStatus
    createdAt*: Option[Time]
    archived*: bool
    runtime*: Runtime                ## rtLocal or rtCloud when known
    cwd*: string                     ## local agents
    cloud*: Option[CloudAgentInfo]   ## cloud agents

proc parseSdkAgentInfo*(n: JsonNode): SdkAgentInfo =
  result.agentId = jStr(n, "agentId")
  result.name = jStr(n, "name")
  result.summary = jStr(n, "summary")
  result.lastModified = jTime(n, "lastModified")
  result.status = parseProtoEnum(n, "status", AgentInfoStatusPrefix, aisUnspecified)
  result.createdAt = jTime(n, "createdAt")
  result.archived = jBool(n, "archived")
  let local = jObj(n, "local")
  let cloud = jObj(n, "cloud")
  if not local.isNil:
    result.runtime = rtLocal
    result.cwd = jStr(local, "cwd")
  elif not cloud.isNil:
    result.runtime = rtCloud
    let env = jObj(cloud, "env")
    result.cloud = some(CloudAgentInfo(envType: jStr(env, "type"), envName: jStr(env, "name"),
                                       repos: jStrSeq(cloud, "repos"),
                                       metadata: jStrTable(cloud, "metadata")))

# ---------------------------------------------------------------------------
# Usage

type
  TokenUsage* = object
    inputTokens*, outputTokens*, cacheReadTokens*, cacheWriteTokens*, totalTokens*: int64
    reasoningTokens*: Option[int64]

  UsageCost* = object
    rawCostCents*, chargedCents*: float

  RunUsage* = object
    runId*: string
    usage*: TokenUsage
    cost*: Option[UsageCost]

  AgentUsage* = object
    usage*: TokenUsage
    cost*: Option[UsageCost]
    runs*: seq[RunUsage]

proc parseTokenUsage*(n: JsonNode): TokenUsage =
  TokenUsage(inputTokens: jInt64(n, "inputTokens"), outputTokens: jInt64(n, "outputTokens"),
             cacheReadTokens: jInt64(n, "cacheReadTokens"), cacheWriteTokens: jInt64(n, "cacheWriteTokens"),
             totalTokens: jInt64(n, "totalTokens"), reasoningTokens: jInt64Opt(n, "reasoningTokens"))

proc parseUsageCost(n: JsonNode): Option[UsageCost] =
  if n.isNil: return
  some(UsageCost(rawCostCents: jFloat(n, "rawCostCents"), chargedCents: jFloat(n, "chargedCents")))

proc parseAgentUsage*(n: JsonNode): AgentUsage =
  result.usage = parseTokenUsage(jObj(n, "usage"))
  result.cost = parseUsageCost(jObj(n, "cost"))
  for r in jArr(n, "runs"):
    result.runs.add RunUsage(runId: jStr(r, "runId"), usage: parseTokenUsage(jObj(r, "usage")),
                             cost: parseUsageCost(jObj(r, "cost")))

# ---------------------------------------------------------------------------
# Runs

type
  RunGitBranchInfo* = object
    repoUrl*, branch*, prUrl*: string

  RunResult* = object
    ## `RunResult` and `RunSnapshot` share one shape on the wire.
    runId*, agentId*: string
    status*: RunLifecycleStatus
    text*: string                    ## final assistant text (`result` on the wire)
    model*: ModelSelection
    durationMs*: uint64
    git*: seq[RunGitBranchInfo]
    createdAt*: Option[Time]
    usage*: Option[TokenUsage]

  RunSnapshot* = RunResult

  RunStreamResult* = object
    agentId*, runId*: string
    status*: RunLifecycleStatus
    errorCode*: Option[string]
    result*: RunResult

  RunEventKind* = enum
    rekMessage           ## `sdk_message`: typed conversation event
    rekResult            ## `result`: terminal status and RunResult
    rekDone              ## `done`: end-of-stream marker
    rekInteractionUpdate ## `interaction_update` (opt-in via enableDeltas)
    rekStep              ## `step` (opt-in via enableSteps)
    rekUnknown           ## keepalive (empty envelope) or a case this build does not know

  RunEvent* = object
    offset*: string                  ## opaque resume token; empty for keepalives
    raw*: JsonNode                   ## the full RunStreamMessage
    case kind*: RunEventKind
    of rekMessage:
      msgType*: string               ## "system", "assistant", "tool_call", "status", ...
      message*: JsonNode             ## payload object
    of rekResult:
      result*: RunStreamResult
    of rekDone:
      doneAgentId*, doneRunId*: string
    of rekInteractionUpdate:
      updateType*: string
      update*: JsonNode
    of rekStep:
      stepType*: string
      step*: JsonNode
    of rekUnknown:
      discard

  AgentMessage* = object
    msgType*, uuid*, agentId*: string
    message*: JsonNode

  SdkArtifact* = object
    path*: string
    sizeBytes*: uint64
    updatedAt*: string

proc parseRunResult*(n: JsonNode): RunResult =
  if n.isNil: return
  result.runId = jStr(n, "runId")
  result.agentId = jStr(n, "agentId")
  result.status = parseProtoEnum(n, "status", RunLifecycleStatusPrefix, rlsUnspecified)
  result.text = jStr(n, "result")
  result.model = parseModelSelection(jObj(n, "model"))
  result.durationMs = jU64(n, "durationMs")
  for b in jArr(jObj(n, "git"), "branches"):
    result.git.add RunGitBranchInfo(repoUrl: jStr(b, "repoUrl"), branch: jStr(b, "branch"), prUrl: jStr(b, "prUrl"))
  result.createdAt = jTime(n, "createdAt")
  let usage = jObj(n, "usage")
  if not usage.isNil: result.usage = some(parseTokenUsage(usage))

proc parseRunStreamResult*(n: JsonNode): RunStreamResult =
  result.agentId = jStr(n, "agentId")
  result.runId = jStr(n, "runId")
  result.status = parseProtoEnum(n, "status", RunLifecycleStatusPrefix, rlsUnspecified)
  result.errorCode = jStrOpt(n, "errorCode")
  result.result = parseRunResult(jObj(n, "result"))
  # Fill gaps from the envelope when the nested result is sparse.
  if result.result.runId.len == 0: result.result.runId = result.runId
  if result.result.agentId.len == 0: result.result.agentId = result.agentId
  if result.result.status == rlsUnspecified: result.result.status = result.status

proc parseRunEvent*(n: JsonNode): RunEvent =
  ## Dispatches on the `envelope` oneof. Empty envelopes (keepalives) and
  ## unknown cases become `rekUnknown`.
  let offset = jStr(n, "offset")
  if n.isNil or n.kind != JObject:
    return RunEvent(kind: rekUnknown, raw: n)
  if n.hasKey("sdkMessage"):
    let m = n["sdkMessage"]
    return RunEvent(kind: rekMessage, offset: offset, raw: n, msgType: jStr(m, "type"),
                    message: (let p = jObj(m, "message"); if p.isNil: newJObject() else: p))
  if n.hasKey("result"):
    return RunEvent(kind: rekResult, offset: offset, raw: n, result: parseRunStreamResult(n["result"]))
  if n.hasKey("done"):
    let d = n["done"]
    return RunEvent(kind: rekDone, offset: offset, raw: n, doneAgentId: jStr(d, "agentId"), doneRunId: jStr(d, "runId"))
  if n.hasKey("interactionUpdate"):
    let u = n["interactionUpdate"]
    return RunEvent(kind: rekInteractionUpdate, offset: offset, raw: n, updateType: jStr(u, "type"),
                    update: (let p = jObj(u, "update"); if p.isNil: newJObject() else: p))
  if n.hasKey("step"):
    let s = n["step"]
    return RunEvent(kind: rekStep, offset: offset, raw: n, stepType: jStr(s, "type"),
                    step: (let p = jObj(s, "step"); if p.isNil: newJObject() else: p))
  RunEvent(kind: rekUnknown, offset: offset, raw: n)

proc isKeepalive*(e: RunEvent): bool =
  ## True for an empty envelope: no `envelope` case set (at most an
  ## `offset`). The bridge sends these while a run is idle, e.g. during a
  ## long tool call. Unknown envelope cases are `rekUnknown` but not keepalives.
  if e.kind != rekUnknown: return false
  if e.raw.isNil or e.raw.kind != JObject: return true
  for k, _ in e.raw:
    if k != "offset": return false
  true

proc parseAgentMessage*(n: JsonNode): AgentMessage =
  AgentMessage(msgType: jStr(n, "type"), uuid: jStr(n, "uuid"), agentId: jStr(n, "agentId"),
               message: (let p = jObj(n, "message"); if p.isNil: newJObject() else: p))

proc parseSdkArtifact*(n: JsonNode): SdkArtifact =
  SdkArtifact(path: jStr(n, "path"), sizeBytes: jU64(n, "sizeBytes"), updatedAt: jStr(n, "updatedAt"))

# ---------------------------------------------------------------------------
# List / operation options and pages

type
  ListAgentsOptions* = object
    limit*: int
    cursor*: string
    runtime*: Runtime
    cwd*: string
    includeArchived*: Option[bool]

  ListRunsOptions* = object
    limit*: int
    cursor*: string
    runtime*: Runtime
    cwd*: string

  ListAgentMessagesOptions* = object
    limit*, offset*: int
    runtime*: Runtime
    cwd*: string

  Page*[T] = object
    items*: seq[T]
    nextCursor*: string              ## empty when there are no further pages

  BridgeVersionInfo* = object
    bridgeVersion*, protocolVersion*: string
    capabilities*: seq[string]

proc toJson*(o: ListAgentsOptions, apiKey: string): JsonNode =
  result = newJObject()
  addIf(result, "limit", o.limit > 0, o.limit)
  addIf(result, "cursor", o.cursor.len > 0, o.cursor)
  addIf(result, "runtime", o.runtime != rtUnspecified, protoName(o.runtime))
  addIf(result, "cwd", o.cwd.len > 0, o.cwd)
  addOpt(result, "includeArchived", o.includeArchived)
  addIf(result, "apiKey", apiKey.len > 0, apiKey)

proc toJson*(o: ListRunsOptions, apiKey: string): JsonNode =
  result = newJObject()
  addIf(result, "limit", o.limit > 0, o.limit)
  addIf(result, "cursor", o.cursor.len > 0, o.cursor)
  addIf(result, "runtime", o.runtime != rtUnspecified, protoName(o.runtime))
  addIf(result, "cwd", o.cwd.len > 0, o.cwd)
  addIf(result, "apiKey", apiKey.len > 0, apiKey)

proc toJson*(o: ListAgentMessagesOptions, apiKey: string): JsonNode =
  result = newJObject()
  addIf(result, "limit", o.limit > 0, o.limit)
  addIf(result, "offset", o.offset > 0, o.offset)
  addIf(result, "runtime", o.runtime != rtUnspecified, protoName(o.runtime))
  addIf(result, "cwd", o.cwd.len > 0, o.cwd)
  addIf(result, "apiKey", apiKey.len > 0, apiKey)

proc parseBridgeVersionInfo*(n: JsonNode): BridgeVersionInfo =
  BridgeVersionInfo(bridgeVersion: jStr(n, "bridgeVersion"), protocolVersion: jStr(n, "protocolVersion"),
                    capabilities: jStrSeq(n, "capabilities"))

# ---------------------------------------------------------------------------
# Convenience accessors on stream payloads

proc assistantText*(ev: RunEvent): string =
  ## Extracts text from an `assistant` sdk_message payload. Handles the
  ## content-block form (`message.content[].text`) and plain `text` fields.
  if ev.kind != rekMessage or ev.msgType != "assistant": return ""
  let m = ev.message
  var inner = jObj(m, "message")
  if inner.isNil: inner = m
  let content = inner.getOrDefault("content")
  if not content.isNil:
    case content.kind
    of JString: return content.getStr
    of JArray:
      for part in content:
        if part.kind == JObject and jStr(part, "type", "text") == "text":
          result.add jStr(part, "text")
      return
    else: discard
  result = jStr(inner, "text")

proc runId*(ev: RunEvent): string =
  ## Best-effort run id from any event that carries one.
  case ev.kind
  of rekMessage: jStr(ev.message, "run_id", jStr(ev.message, "runId"))
  of rekResult: ev.result.runId
  of rekDone: ev.doneRunId
  else: ""

proc agentId*(ev: RunEvent): string =
  case ev.kind
  of rekMessage: jStr(ev.message, "agent_id", jStr(ev.message, "agentId"))
  of rekResult: ev.result.agentId
  of rekDone: ev.doneAgentId
  else: ""

proc thinkingText*(ev: RunEvent): string =
  ## Text of a `thinking` sdk_message, or "".
  if ev.kind == rekMessage and ev.msgType == "thinking": jStr(ev.message, "text") else: ""

proc tokenUsage*(ev: RunEvent): Option[TokenUsage] =
  ## Token counts carried by a `usage` sdk_message.
  if ev.kind == rekMessage and ev.msgType == "usage":
    let u = jObj(ev.message, "usage")
    if not u.isNil: return some(parseTokenUsage(u))
  none(TokenUsage)

proc toolCallName*(ev: RunEvent): string =
  ## Tool name of a `tool_call` sdk_message. Custom tools surface as
  ## `mcp` with the user tool under `args.toolName`; this resolves that.
  if ev.kind != rekMessage or ev.msgType != "tool_call": return ""
  result = jStr(ev.message, "name")
  if result == "mcp":
    let inner = jStr(jObj(ev.message, "args"), "toolName")
    if inner.len > 0: result = inner

proc toolCallStatus*(ev: RunEvent): string =
  ## `running` / `completed` / `error` for a `tool_call` sdk_message.
  if ev.kind == rekMessage and ev.msgType == "tool_call": jStr(ev.message, "status") else: ""

proc statusMessage*(ev: RunEvent): string =
  ## For `status` messages: the human-readable `message` (failure reason).
  if ev.kind == rekMessage and ev.msgType == "status": jStr(ev.message, "message") else: ""
