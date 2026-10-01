## Adapter-served callback services: `SdkCustomToolCallbackService` and
## `SdkStoreCallbackService`.
##
## The bridge calls *into* this process to execute user-defined tools and,
## optionally, to persist agent state. `CallbackServer` is a small loopback
## Connect server on `std/asynchttpserver` that authenticates the bridge
## with a bearer token we generate, decodes JSON or binary-protobuf unary
## requests (including chunked bodies), and dispatches to Nim handlers.
##
## ```nim
## let tools = newCallbackServer()
## tools.registerTool("get_weather", "Current weather for a city",
##   %*{"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]},
##   proc(args: JsonNode, ctx: ToolContext): Future[JsonNode] {.async.} =
##     result = %*{"tempC": 21, "city": args["city"].getStr})
## await tools.start()
## let client = newClient()
## await client.attachToolCallbacks(tools)
## var opts = AgentOptions(model: model("composer-2.5"))
## opts.useTools(tools)
## let agent = await client.createAgent(opts)
## ```
##
## See vendor/sdk-bridge/docs/services.md.

import std/[asyncdispatch, asynchttpserver, json, tables, strutils, sysrand, base64, net]
import types, errors, protobuf, client

const
  ToolCallbackPath = "/sdk.v1.SdkCustomToolCallbackService/CallCustomTool"
  StoreCallbackPath = "/sdk.v1.SdkStoreCallbackService/CallStore"
  DefaultCallbackMaxBody* = 64 * 1024 * 1024
    ## Default `maxBody` for `newCallbackServer`. `std/asynchttpserver`'s
    ## own default is 8 MiB, which a custom store's `checkpoints.create` /
    ## `update` (a base64 conversation blob that grows with the agent) can
    ## exceed on a long-lived agent. The server cannot default to
    ## `BridgeInfo.maxMessageBytes`: it has to exist (and be bound) before
    ## the bridge that would advertise that value is launched.

type
  ToolContext* = object
    toolName*: string
    toolCallId*: string              ## correlates with `tool_call` stream events
    agentId*: string

  ToolHandler* = proc(args: JsonNode, ctx: ToolContext): Future[JsonNode] {.gcsafe.}
    ## Receives the tool arguments (JSON object) and returns the result.
    ## Results that are not JSON objects are wrapped as `{"value": ...}`.

  StoreHandler* = proc(substore, meth: string, input: JsonNode): Future[JsonNode] {.gcsafe.}
    ## Receives (`agents|runs|runEvents|checkpoints`, `get|create|update|
    ## delete|list|append`, input). Return the bare record object, or `nil`
    ## for a null result (get miss, delete).

  CallbackServer* = ref object
    server: AsyncHttpServer
    host: string
    port*: Port                      ## bound port (after `start`)
    url*: string                     ## `http://127.0.0.1:<port>` (after `start`)
    authToken*: string               ## bearer token the bridge must present
    tools: Table[string, ToolHandler]
    toolDefs: Table[string, CustomToolDefinition]
    store: StoreHandler
    running: bool
    loopFut: Future[void]

proc randomToken(): string =
  let bytes = urandom(32)
  result = base64.encode(bytes, safe = true)
  while result.len > 0 and result[^1] == '=': result.setLen(result.len - 1)

proc newCallbackServer*(host = "127.0.0.1", port = Port(0),
                        maxBody = DefaultCallbackMaxBody): CallbackServer =
  ## Creates a server bound lazily by `start`. Port 0 picks an ephemeral port.
  ## `maxBody` caps the `Content-Length` of a callback request; a larger
  ## body is refused by `std/asynchttpserver` with a bare HTTP 413 before
  ## any handler runs (chunked bodies are not subject to it).
  CallbackServer(host: host, port: port, authToken: randomToken(),
                 server: newAsyncHttpServer(reuseAddr = true, maxBody = maxBody))

# ---------------------------------------------------------------------------
# Registration

proc registerTool*(s: CallbackServer, name: string, description: string,
                   inputSchema: JsonNode, handler: ToolHandler,
                   outputSchema: JsonNode = nil) =
  ## Registers a tool. `inputSchema` is a JSON Schema object describing the
  ## arguments. The definition is exposed via `customTools` for
  ## `LocalAgentOptions.customTools`.
  s.tools[name] = handler
  s.toolDefs[name] = CustomToolDefinition(
    description: (if description.len > 0: some(description) else: none(string)),
    inputSchema: inputSchema, outputSchema: outputSchema)

proc registerTool*(s: CallbackServer, name: string, description: string,
                   inputSchema: JsonNode, handler: proc(args: JsonNode): JsonNode {.gcsafe.}) =
  ## Synchronous-handler convenience.
  s.registerTool(name, description, inputSchema,
    proc(args: JsonNode, ctx: ToolContext): Future[JsonNode] {.gcsafe.} =
      result = newFuture[JsonNode]("tool." & name)
      try:
        result.complete(handler(args))
      except CatchableError as e:
        result.fail(e))

proc customTools*(s: CallbackServer): Table[string, CustomToolDefinition] =
  ## Tool definitions for `AgentOptions.local.customTools`.
  s.toolDefs

proc useTools*(o: var AgentOptions, s: CallbackServer) =
  ## Adds the server's tool definitions to `o.local.customTools`.
  for name, def in s.toolDefs: o.local.customTools[name] = def

proc setStoreHandler*(s: CallbackServer, handler: StoreHandler) =
  ## Installs the custom-store handler. The bridge must be launched with
  ## `localStore = LocalAgentStoreConfig(kind: "custom")` and
  ## `storeCallbackUrl`/`storeCallbackToken` pointing at this server.
  s.store = handler

proc textResult*(text: string): JsonNode =
  ## MCP-style content envelope for a plain-text tool result.
  %*{"content": [{"type": "text", "text": text}]}

# ---------------------------------------------------------------------------
# Connect unary plumbing

proc httpStatusFor(code: ConnectCode): HttpCode =
  case code
  of ccCanceled, ccDeadlineExceeded: HttpCode(408)
  of ccInvalidArgument, ccOutOfRange: Http400
  of ccNotFound, ccUnimplemented: Http404
  of ccAlreadyExists, ccAborted: Http409
  of ccPermissionDenied: Http403
  of ccResourceExhausted: Http429
  of ccFailedPrecondition: HttpCode(412)
  of ccUnavailable: Http503
  of ccUnauthenticated: Http401
  of ccUnknown, ccInternal, ccDataLoss: Http500

proc respondError(req: Request, code: ConnectCode, message: string): Future[void] =
  let body = $(%*{"code": $code, "message": message})
  req.respond(httpStatusFor(code), body,
              newHttpHeaders({"Content-Type": "application/json"}))

proc isBinary(contentType: string): bool =
  let ct = contentType.toLowerAscii
  ct.startsWith("application/proto") or ct.startsWith("application/x-protobuf") or
    ct.startsWith("application/protobuf")

proc decodeToolRequest(body: string, binary: bool): (JsonNode, ToolContext) =
  var args = newJObject()
  var ctx: ToolContext
  if binary:
    for f in fields(body):
      case f.number
      of 1:
        if f.wireType == wtLengthDelimited: ctx.toolName = f.bytes
      of 2:
        if f.wireType == wtLengthDelimited: args = decodeStruct(f.bytes)
      of 3:
        if f.wireType == wtLengthDelimited: ctx.toolCallId = f.bytes
      of 4:
        if f.wireType == wtLengthDelimited: ctx.agentId = f.bytes
      else: discard
  else:
    let n = parseJson(body)
    ctx.toolName = jStr(n, "toolName")
    ctx.toolCallId = jStr(n, "toolCallId")
    ctx.agentId = jStr(n, "agentId")
    let a = jObj(n, "args")
    if not a.isNil: args = a
  (args, ctx)

proc encodeToolResponse(res: JsonNode, binary: bool): string =
  if binary: result.writeBytesField(1, encodeStruct(res))
  else: result = $(%*{"result": res})

proc decodeStoreRequest(body: string, binary: bool): (string, string, JsonNode) =
  var substore, meth: string
  var input = newJObject()
  if binary:
    for f in fields(body):
      if f.wireType != wtLengthDelimited: continue
      case f.number
      of 1: substore = f.bytes
      of 2: meth = f.bytes
      of 3: input = decodeStruct(f.bytes)
      else: discard
  else:
    let n = parseJson(body)
    substore = jStr(n, "substore")
    meth = jStr(n, "method")
    let i = jObj(n, "input")
    if not i.isNil: input = i
  (substore, meth, input)

proc encodeStoreResponse(output: JsonNode, binary: bool): string =
  let isNull = output.isNil or output.kind == JNull
  if binary:
    if not isNull: result.writeBytesField(1, encodeStruct(output))
  else:
    result = if isNull: "{}" else: $(%*{"output": output})

proc wrapToolResult(res: JsonNode): JsonNode =
  ## `CallCustomToolResponse.result` is a Struct, so it must be an object.
  if res.isNil: newJObject()
  elif res.kind == JObject: res
  else: %*{"value": res}

proc handle(s: CallbackServer, req: Request) {.async.} =
  if req.reqMethod != HttpPost:
    await req.respondError(ccUnimplemented, "POST required")
    return
  let auth = req.headers.getOrDefault("authorization")
  if auth != "Bearer " & s.authToken:
    await req.respondError(ccUnauthenticated, "Unauthorized")
    return
  let contentType = req.headers.getOrDefault("content-type")
  let binary = isBinary(contentType)
  let responseType = if binary: "application/proto" else: "application/json"
  case req.url.path
  of ToolCallbackPath:
    var args: JsonNode
    var ctx: ToolContext
    try:
      (args, ctx) = decodeToolRequest(req.body, binary)
    except CatchableError as e:
      await req.respondError(ccInvalidArgument, "cannot decode CallCustomToolRequest: " & e.msg)
      return
    if ctx.toolName notin s.tools:
      await req.respondError(ccNotFound, "unknown custom tool: " & ctx.toolName)
      return
    var res: JsonNode
    try:
      res = await s.tools[ctx.toolName](args, ctx)
    except CatchableError as e:
      await req.respondError(ccInternal, "tool " & ctx.toolName & " failed: " & e.msg)
      return
    await req.respond(Http200, encodeToolResponse(wrapToolResult(res), binary),
                      newHttpHeaders({"Content-Type": responseType}))
  of StoreCallbackPath:
    if s.store == nil:
      await req.respondError(ccUnimplemented, "no store handler registered")
      return
    var substore, meth: string
    var input: JsonNode
    try:
      (substore, meth, input) = decodeStoreRequest(req.body, binary)
    except CatchableError as e:
      await req.respondError(ccInvalidArgument, "cannot decode CallStoreRequest: " & e.msg)
      return
    var output: JsonNode
    try:
      output = await s.store(substore, meth, input)
    except CatchableError as e:
      await req.respondError(ccInternal, "store " & substore & "." & meth & " failed: " & e.msg)
      return
    await req.respond(Http200, encodeStoreResponse(output, binary),
                      newHttpHeaders({"Content-Type": responseType}))
  else:
    await req.respondError(ccUnimplemented, "unknown RPC " & req.url.path)

# ---------------------------------------------------------------------------
# Lifecycle

proc serveLoop(s: CallbackServer) {.async.} =
  let cb = proc (req: Request): Future[void] {.closure, gcsafe.} = s.handle(req)
  while s.running:
    try:
      if s.server.shouldAcceptRequest():
        await s.server.acceptRequest(cb)
      else:
        await sleepAsync(50)
    except OSError, IOError:
      if not s.running: break
      await sleepAsync(10)
    except CatchableError:
      # Per-request failures are reported to the bridge as Connect errors;
      # anything else should not take the server down.
      discard

proc start*(s: CallbackServer) {.async.} =
  ## Binds the port and begins serving in the background. Afterwards `url`
  ## and `port` are set.
  if s.running: return
  s.server.listen(s.port, s.host)
  s.port = s.server.getPort()
  let h = if s.host.contains(':'): "[" & s.host & "]" else: s.host
  s.url = "http://" & h & ":" & $s.port
  s.running = true
  s.loopFut = s.serveLoop()
  s.loopFut.callback = proc (f: Future[void]) = discard f.failed

proc stop*(s: CallbackServer) =
  ## Stops accepting connections.
  if not s.running: return
  s.running = false
  s.server.close()

proc isRunning*(s: CallbackServer): bool = s.running

proc attachToolCallbacks*(c: Client, s: CallbackServer) {.async.} =
  ## Points a running bridge at this server (`SetToolCallback`). Starts
  ## the server if needed. For launch-time registration instead, set
  ## `ClientOptions.toolCallbackUrl`/`toolCallbackToken` before the first RPC.
  if not s.running: await s.start()
  await c.setToolCallback(s.url, s.authToken)
