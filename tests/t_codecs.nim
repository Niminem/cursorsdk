## Unit tests for the pure codecs: SHA-256, protobuf wire format, Struct,
## SdkErrorDetails, Connect error mapping, discovery line, timestamps,
## stream envelopes, and request serialization. No network, no bridge.

import std/[unittest, json, options, times, tables, strutils, base64]
import cursorsdk/[sha256, protobuf, errors, bridge, types]

suite "sha256":
  test "known answers":
    check sha256Hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    check sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    check sha256Hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") ==
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
  test "incremental matches one-shot":
    var s = initSha256()
    for i in 0 ..< 1000: s.update("a")
    check s.finish().toHex == sha256Hex("a".repeat(1000))

suite "protobuf":
  test "varint round trip":
    for v in [0'u64, 1, 127, 128, 300, 1 shl 32, high(uint64)]:
      var buf = ""
      buf.writeVarint(v)
      var pos = 0
      check readVarint(buf, pos) == v
      check pos == buf.len
  test "Struct round trip":
    let original = %*{"s": "hi", "i": 42, "f": 1.5, "b": true, "n": nil,
                      "o": {"nested": [1, "two", false]}, "a": []}
    let decoded = decodeStruct(encodeStruct(original))
    check decoded == original
  test "unknown fields are skipped":
    var buf = ""
    buf.writeVarintField(99, 7)
    buf.writeBytesField(3, "msg")
    buf.writeFixed64Field(50, 123)
    let d = decodeSdkErrorDetails(buf)
    check d.message == "msg"

suite "SdkErrorDetails":
  test "decodes real bridge payload (message only)":
    # GetRun with an unknown id, captured from cursor-sdk-bridge 1.0.35.
    let d = decodeSdkErrorDetails(decodeBase64Lenient("GhRSdW4gcnVuLW5vIG5vdCBmb3VuZA"))
    check d.message == "Run run-no not found"
    check d.sdkErrorCode == secUnspecified
    check d.requestId.isNone
  test "decodes real bridge payload (request id + message)":
    let d = decodeSdkErrorDetails(decodeBase64Lenient(
      "CiRkYTA4YThhNS0yNDVjLTQ5NTQtYWFkNS05NzAwNjAzNzExZjcaFEludmFsaWQgVXNlciBBUEkgS2V5"))
    check d.requestId == some("da08a8a5-245c-4954-aad5-9700603711f7")
    check d.message == "Invalid User API Key"
  test "decodes every field":
    var dur = ""
    dur.writeVarintField(1, 3)                 # seconds
    dur.writeVarintField(2, 500_000_000)       # nanos
    var rl = ""
    rl.writeVarintField(1, 100); rl.writeVarintField(2, 0); rl.writeVarintField(3, 1_700_000_000)
    var buf = ""
    buf.writeBytesField(1, "req-1")
    buf.writeVarintField(2, uint64(ord(secRateLimitExceeded)))
    buf.writeBytesField(3, "slow down")
    buf.writeBytesField(4, "https://docs")
    buf.writeBytesField(5, "anthropic")
    buf.writeBytesField(6, dur)
    buf.writeBytesField(7, rl)
    let d = decodeSdkErrorDetails(buf)
    check d.requestId == some("req-1")
    check d.sdkErrorCode == secRateLimitExceeded
    check d.message == "slow down"
    check d.helpUrl == some("https://docs")
    check d.provider == some("anthropic")
    check d.retryAfter == some(initDuration(seconds = 3, nanoseconds = 500_000_000))
    check d.rateLimit.get.limit == some(100'u64)
    check d.rateLimit.get.remaining == some(0'u64)
    check d.rateLimit.get.resetEpochSeconds == some(1_700_000_000'u64)
  test "unknown enum value tolerated":
    var buf = ""
    buf.writeVarintField(2, 999)
    let d = decodeSdkErrorDetails(buf)
    check d.sdkErrorCode == secUnspecified
    check d.rawCode == 999
  test "base64 lenient":
    check decodeBase64Lenient("aGk") == "hi"
    check decodeBase64Lenient("aGk=") == "hi"
    check decodeBase64Lenient("-_8") == "\xfb\xff"

suite "connect errors":
  test "bare unauthenticated -> AuthError":
    let e = errorFromConnectBody("""{"code":"unauthenticated","message":"Unauthorized"}""", 401)
    check e of AuthError
    check e.connectCode == ccUnauthenticated
    check e.httpStatus == 401
    check e.details.isNone
  test "sdk code wins over connect code":
    var det = ""
    det.writeVarintField(2, uint64(ord(secAgentBusy)))
    det.writeBytesField(3, "busy")
    let body = $(%*{"code": "failed_precondition", "message": "busy",
                    "details": [{"type": "sdk.v1.SdkErrorDetails", "value": base64.encode(det)}]})
    let e = errorFromConnectBody(body, 412)
    check e of AgentBusyError
    check e.sdkErrorCode == secAgentBusy
  test "debug fallback when value absent":
    let body = $(%*{"code": "not_found", "message": "x",
                    "details": [{"type": "sdk.v1.SdkErrorDetails",
                                 "debug": {"sdkErrorCode": "SDK_ERROR_CODE_RUN_NOT_FOUND", "requestId": "r9", "retryAfter": "2.5s"}}]})
    let e = errorFromConnectBody(body)
    check e of NotFoundError
    check e.requestId == some("r9")
    check e.retryAfter == some(initDuration(milliseconds = 2500))
  test "connect code classification":
    check errorFromConnectBody("""{"code":"not_found","message":""}""") of NotFoundError
    check errorFromConnectBody("""{"code":"invalid_argument","message":""}""") of ValidationError
    check errorFromConnectBody("""{"code":"resource_exhausted","message":""}""") of RateLimitError
    check errorFromConnectBody("""{"code":"unavailable","message":""}""") of UnavailableError
    check errorFromConnectBody("""{"code":"internal","message":""}""") of InternalError
    check errorFromConnectBody("""{"code":"canceled","message":""}""") of CancelledError
    check errorFromConnectBody("""{"code":"permission_denied","message":""}""") of PermissionError
  test "non-JSON body":
    let e = errorFromConnectBody("<html>502</html>", 502)
    check e.connectCode == ccUnknown
    check "502" in e.msg

suite "discovery line":
  const line = """cursor-sdk-bridge ready {"schemaVersion":1,"serverVersion":"1.0.0","pid":16083,"transport":"tcp","protocol":"connect","host":"127.0.0.1","port":39217,"url":"http://127.0.0.1:39217","authTokenFile":"/tmp/x/auth-token","workspaceRef":"/tmp","stateRoot":"/home/me/.cursor/sdk-agent-store/abc","futureField":{"a":1}}"""
  test "parses and ignores unknown fields":
    let info = parseReadyLine(line)
    check info.pid == 16083
    check info.url == "http://127.0.0.1:39217"
    check info.port == 39217
    check info.authTokenFile == "/tmp/x/auth-token"
    check info.workspaceRef == "/tmp"
    check info.maxConcurrentAgents.isNone
  test "rejects wrong schema/transport/protocol":
    expect BridgeError: discard parseReadyLine(line.replace("\"schemaVersion\":1", "\"schemaVersion\":2"))
    expect BridgeError: discard parseReadyLine(line.replace("\"tcp\"", "\"unix\""))
    expect BridgeError: discard parseReadyLine(line.replace("\"connect\"", "\"grpc\""))
    expect BridgeError: discard parseReadyLine("something else")
  test "falls back to host+port":
    let info = parseReadyLine(line.replace(""""url":"http://127.0.0.1:39217",""", ""))
    check info.url == "http://127.0.0.1:39217"

suite "types":
  test "timestamps":
    check parseTimestamp("2026-10-01T03:09:15Z").get == dateTime(2026, mOct, 1, 3, 9, 15, zone = utc()).toTime
    check parseTimestamp("2026-10-01T03:09:15.123456789Z").get.nanosecond == 123456789
    check parseTimestamp("2026-10-01T03:09:15.5+02:00").get.toUnix == parseTimestamp("2026-10-01T01:09:15Z").get.toUnix
    check parseTimestamp("").isNone
    check parseTimestamp("garbage").isNone
  test "enums accept prefixed, bare, and int forms":
    check parseRunResult(%*{"status": "RUN_LIFECYCLE_STATUS_FINISHED"}).status == rlsFinished
    check parseRunResult(%*{"status": "ERROR"}).status == rlsError
    check parseRunResult(%*{"status": 5}).status == rlsCancelled
    check parseRunResult(%*{"status": "RUN_LIFECYCLE_STATUS_SOMETHING_NEW"}).status == rlsUnspecified
  test "uint64 as string or number":
    check parseRunResult(%*{"durationMs": "1234"}).durationMs == 1234
    check parseRunResult(%*{"durationMs": 1234}).durationMs == 1234
  test "run events":
    let keepalive = parseRunEvent(%*{})
    check keepalive.kind == rekUnknown
    check keepalive.isKeepalive
    check parseRunEvent(%*{"offset": "9"}).isKeepalive
    let future = parseRunEvent(%*{"somethingNew": {}, "offset": "7"})
    check future.kind == rekUnknown
    check future.offset == "7"
    check not future.isKeepalive
    let msg = parseRunEvent(%*{"sdkMessage": {"type": "assistant", "message": {"run_id": "run-1", "agent_id": "agent-1",
      "message": {"content": [{"type": "text", "text": "Hel"}, {"type": "tool_use"}, {"type": "text", "text": "lo"}]}}}, "offset": "3"})
    check msg.kind == rekMessage
    check msg.msgType == "assistant"
    check msg.assistantText == "Hello"
    check msg.runId == "run-1"
    check msg.agentId == "agent-1"
    let status = parseRunEvent(%*{"sdkMessage": {"type": "status", "message": {"status": "error", "message": "Model exploded"}}})
    check status.statusMessage == "Model exploded"
    let res = parseRunEvent(%*{"result": {"agentId": "a", "runId": "r", "status": "RUN_LIFECYCLE_STATUS_FINISHED",
      "result": {"result": "done text", "durationMs": "10", "usage": {"inputTokens": "5", "outputTokens": 7}}}})
    check res.kind == rekResult
    check res.result.status == rlsFinished
    check res.result.result.text == "done text"
    check res.result.result.runId == "r"
    check res.result.result.usage.get.outputTokens == 7
    let done = parseRunEvent(%*{"done": {"agentId": "a", "runId": "r"}})
    check done.kind == rekDone
    check done.runId == "r"
  test "AgentOptions serialization":
    var o = AgentOptions(model: model("composer-2"), apiKey: "k", name: "n", mode: amoPlan)
    o.local.cwd = "/repo"
    o.local.sandbox = some(true)
    o.local.settingSources = @[ssProject, ssUser]
    o.local.store = some(LocalAgentStoreConfig(kind: "jsonl", rootDir: "/s"))
    o.local.customTools["echo"] = CustomToolDefinition(description: some("d"), inputSchema: %*{"type": "object"})
    o.tools = some(@["read"])
    o.disallowedTools = @["shell"]
    o.mcpServers["fs"] = McpServerConfig(kind: mskStdio, command: "npx", args: @["srv"])
    o.mcpServers["web"] = McpServerConfig(kind: mskHttp, url: "http://x", transport: hmtSse)
    o.extra = %*{"cloud": {"env": {"type": "CLOUD_ENVIRONMENT_TYPE_CLOUD"}}}
    let j = o.toJson
    check j["model"]["id"].getStr == "composer-2"
    check j["apiKey"].getStr == "k"
    check j["mode"].getStr == "AGENT_MODE_OPTION_PLAN"
    check j["local"]["cwd"] == %["/repo"]
    check j["local"]["sandboxOptions"]["enabled"].getBool
    check j["local"]["settingSources"] == %["SETTING_SOURCE_PROJECT", "SETTING_SOURCE_USER"]
    check j["local"]["store"]["type"].getStr == "jsonl"
    check j["local"]["customTools"]["echo"]["description"].getStr == "d"
    check j["tools"]["names"] == %["read"]
    check j["disallowedTools"] == %["shell"]
    check j["mcpServers"]["fs"]["stdio"]["command"].getStr == "npx"
    check j["mcpServers"]["web"]["http"]["type"].getStr == "HTTP_MCP_TRANSPORT_TYPE_SSE"
    check j["cloud"]["env"]["type"].getStr == "CLOUD_ENVIRONMENT_TYPE_CLOUD"
    check not j.hasKey("agentId")
    # An empty `local` is omitted so `extra["cloud"]` can select the runtime.
    check not AgentOptions(model: model("m")).toJson.hasKey("local")
  test "SendOptions serialization omits defaults":
    check SendOptions().toJson == %*{}
    let j = SendOptions(enableDeltas: true, force: some(true), model: some(model("m"))).toJson
    check j["enableDeltas"].getBool
    check j["local"]["force"].getBool
    check j["model"]["id"].getStr == "m"
    check not j.hasKey("enableSteps")
  test "agent info parsing":
    let info = parseSdkAgentInfo(%*{"agentId": "a", "status": "AGENT_INFO_STATUS_FINISHED", "archived": false,
      "local": {"cwd": "/repo"}, "createdAt": "2026-10-01T00:00:00Z"})
    check info.runtime == rtLocal
    check info.cwd == "/repo"
    check info.status == aisFinished
    check info.createdAt.isSome
