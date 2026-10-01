## Integration tests against a real `cursor-sdk-bridge` process (no Cursor
## API key required) plus the adapter-side callback server.
##
## The bridge is resolved via `CURSOR_SDK_BRIDGE_BIN`, the user cache, or a
## download of the pinned release.

import std/[unittest, asyncdispatch, asyncnet, json, options, strutils, os, net, tables]
import cursor
import cursor/[connect, http, protobuf, bridge]

when not defined(windows):
  import std/posix
  proc pidAlive(pid: int): bool = posix.kill(Pid(pid), 0) == 0

suite "bridge lifecycle":
  test "launch, handshake, ping, version, shutdown":
    proc run() {.async.} =
      var opts = initBridgeLaunchOptions()
      opts.workspace = getTempDir()
      var sawOutput = false
      opts.onOutput = proc(line: string) {.gcsafe.} =
        sawOutput = true
        doAssert not line.startsWith("cursor-sdk-bridge ready"), "discovery line must not be forwarded"
      let b = await launchBridge(opts)
      check b.managed
      check b.pid > 0
      check b.url.startsWith("http://127.0.0.1:")
      check b.token.len > 0
      check b.info.schemaVersion == 1
      let rpc = newConnectClient(b.url, b.token)
      let pong = await rpc.unary("SdkBridgeControlService", "Ping")
      check pong["message"].getStr == "pong"
      let v = await rpc.unary("SdkBridgeControlService", "GetVersion")
      check v["protocolVersion"].getStr == ProtocolVersion
      let pid = b.pid
      await b.shutdown()
      check b.hasExited
      check b.exitCode == 0
      when not defined(windows):
        check not pidAlive(pid)
      await b.shutdown()  # idempotent
      discard sawOutput
    waitFor run()

  test "bad executable surfaces a BridgeError":
    proc run() {.async.} =
      var opts = initBridgeLaunchOptions()
      opts.exe = getTempDir() / "definitely-not-a-bridge"
      expect BridgeError:
        discard await launchBridge(opts)
    waitFor run()

  test "process that exits before ready reports its output":
    proc run() {.async.} =
      var opts = initBridgeLaunchOptions()
      when defined(windows):
        opts.exe = findExe("cmd")
        opts.env = @[]
      else:
        opts.exe = findExe("sh")
      # `sh` with no stdin exits immediately; the bridge manager must notice.
      try:
        discard await launchBridge(opts)
        check false
      except BridgeError as e:
        check "before becoming ready" in e.msg
    waitFor run()

suite "client":
  test "lazy start, typed control RPCs, auth error, stream error, close":
    proc run() {.async.} =
      var o = initClientOptions()
      o.workspace = getTempDir()
      o.apiKey = "unused-here"
      let c = newClient(o)
      check not c.isStarted
      check (await c.ping()) == "pong"
      check c.isStarted
      let v = await c.bridgeVersion()
      check v.protocolVersion == "sdk.v1"
      check "agent.send" in v.capabilities
      check await c.hasCapability("run.observe")

      # Wrong bearer token -> AuthError without SdkErrorDetails.
      let bad = newConnectClient(c.bridge.url, "nope")
      try:
        discard await bad.unary("SdkBridgeControlService", "Ping")
        check false
      except AuthError as e:
        check e.httpStatus == 401
        check e.details.isNone

      # Unknown run -> error carrying SdkErrorDetails.
      try:
        discard await c.getRun("run-does-not-exist")
        check false
      except RpcError as e:
        check e.details.isSome
        check "not found" in e.details.get.message

      # Stream failure arrives in the EndStreamResponse -> typed error.
      try:
        let s = await c.sendRaw("agent-does-not-exist", UserMessage(text: "hi"))
        discard await s.next()
        check false
      except NotFoundError as e:
        check e.connectCode == ccNotFound

      # Catalog calls demand an api key per call; a bad one is an AuthError.
      try:
        discard await c.me()
        check false
      except AuthError:
        discard

      let pid = c.bridge.pid
      await c.close()
      when not defined(windows):
        check not pidAlive(pid)
    waitFor run()

  test "attach to an external bridge":
    proc run() {.async.} =
      var o = initClientOptions()
      o.workspace = getTempDir()
      let owner = newClient(o)
      await owner.start()
      var ao = initClientOptions()
      ao.bridgeUrl = owner.bridge.url
      ao.bridgeToken = owner.bridge.token
      let attached = newClient(ao)
      check (await attached.ping()) == "pong"
      check not attached.bridge.managed
      await attached.close()            # must not stop the owner's bridge
      check (await owner.ping()) == "pong"
      await owner.close()
    waitFor run()

  test "missing api key is reported before any RPC":
    proc run() {.async.} =
      var o = initClientOptions()
      o.apiKey = ""
      let saved = getEnv(ApiKeyEnv)
      putEnv(ApiKeyEnv, "")
      defer: putEnv(ApiKeyEnv, saved)
      let c = newClient(o)
      expect AuthError:
        discard c.requireApiKey()
    waitFor run()

suite "callback server":
  proc withServer(body: proc(s: CallbackServer): Future[void]) =
    proc run() {.async.} =
      let s = newCallbackServer()
      s.registerTool("echo", "echoes its arguments", %*{"type": "object"},
        proc(args: JsonNode, ctx: ToolContext): Future[JsonNode] {.async.} =
          result = %*{"echo": args, "tool": ctx.toolName, "callId": ctx.toolCallId, "agent": ctx.agentId})
      s.registerTool("scalar", "returns a bare string", %*{"type": "object"},
        proc(args: JsonNode): JsonNode = %"plain")
      s.registerTool("boom", "always fails", %*{"type": "object"},
        proc(args: JsonNode): JsonNode = raise newException(ValueError, "kaboom"))
      s.setStoreHandler(proc(substore, meth: string, input: JsonNode): Future[JsonNode] {.async.} =
        if meth == "get": return nil
        result = %*{"substore": substore, "method": meth, "input": input})
      await s.start()
      check s.url.startsWith("http://127.0.0.1:")
      check s.customTools.len == 3
      try:
        await body(s)
      finally:
        s.stop()
    waitFor run()

  test "JSON tool and store calls":
    withServer(proc(s: CallbackServer) {.async.} =
      let rpc = newConnectClient(s.url, s.authToken)
      let r = await rpc.unary("SdkCustomToolCallbackService", "CallCustomTool",
        %*{"toolName": "echo", "args": {"x": 1}, "toolCallId": "tc1", "agentId": "a1"})
      check r["result"]["echo"]["x"].getInt == 1
      check r["result"]["callId"].getStr == "tc1"
      check r["result"]["agent"].getStr == "a1"
      let scalar = await rpc.unary("SdkCustomToolCallbackService", "CallCustomTool", %*{"toolName": "scalar", "args": {}})
      check scalar["result"]["value"].getStr == "plain"
      let created = await rpc.unary("SdkStoreCallbackService", "CallStore",
        %*{"substore": "agents", "method": "create", "input": {"agent": {"id": "a"}}})
      check created["output"]["method"].getStr == "create"
      let miss = await rpc.unary("SdkStoreCallbackService", "CallStore", %*{"substore": "agents", "method": "get", "input": {}})
      check not miss.hasKey("output"))

  test "errors: bad token, unknown tool, failing tool, unknown RPC":
    withServer(proc(s: CallbackServer) {.async.} =
      let bad = newConnectClient(s.url, "wrong")
      expect AuthError:
        discard await bad.unary("SdkCustomToolCallbackService", "CallCustomTool", %*{"toolName": "echo"})
      let rpc = newConnectClient(s.url, s.authToken)
      expect NotFoundError:
        discard await rpc.unary("SdkCustomToolCallbackService", "CallCustomTool", %*{"toolName": "nope"})
      try:
        discard await rpc.unary("SdkCustomToolCallbackService", "CallCustomTool", %*{"toolName": "boom"})
        check false
      except InternalError as e:
        check "kaboom" in e.msg
      expect RpcError:
        discard await rpc.unary("SdkSomethingElse", "Whatever"))

  test "binary protobuf tool call":
    withServer(proc(s: CallbackServer) {.async.} =
      var req = ""
      req.writeBytesField(1, "echo")
      req.writeBytesField(2, encodeStruct(%*{"n": 2, "s": "v"}))
      req.writeBytesField(3, "call-9")
      req.writeBytesField(4, "agent-9")
      let conn = await connectHttp("127.0.0.1", s.port)
      defer: conn.close()
      await conn.sendRequest("POST", "/sdk.v1.SdkCustomToolCallbackService/CallCustomTool", "127.0.0.1",
        @[("Content-Type", "application/proto"), ("Authorization", "Bearer " & s.authToken)], req)
      let head = await conn.readResponseHead()
      check head.status == 200
      check head.headers["content-type"] == "application/proto"
      let body = await conn.readAll()
      var res: JsonNode
      for f in fields(body):
        if f.number == 1: res = decodeStruct(f.bytes)
      check res["echo"]["n"].getInt == 2
      check res["echo"]["s"].getStr == "v"
      check res["callId"].getStr == "call-9"
      check res["agent"].getStr == "agent-9")

  test "chunked request body is decoded":
    withServer(proc(s: CallbackServer) {.async.} =
      let payload = $(%*{"toolName": "echo", "args": {"chunked": true}})
      let sock = newAsyncSocket(buffered = true)
      await sock.connect("127.0.0.1", s.port)
      defer: sock.close()
      var raw = "POST /sdk.v1.SdkCustomToolCallbackService/CallCustomTool HTTP/1.1\r\n" &
                "Host: 127.0.0.1\r\nAuthorization: Bearer " & s.authToken & "\r\n" &
                "Content-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
      let half = payload.len div 2
      raw.add toHex(half).toLowerAscii.strip(leading = true, chars = {'0'}) & "\r\n" & payload[0 ..< half] & "\r\n"
      raw.add toHex(payload.len - half).toLowerAscii.strip(leading = true, chars = {'0'}) & "\r\n" & payload[half .. ^1] & "\r\n"
      raw.add "0\r\n\r\n"
      await sock.send(raw)
      var response = ""
      while true:
        let part = await sock.recv(4096)
        if part.len == 0: break
        response.add part
      check response.startsWith("HTTP/1.1 200")
      let bodyStart = response.find("\r\n\r\n") + 4
      let r = parseJson(response[bodyStart .. ^1])
      check r["result"]["echo"]["chunked"].getBool)
