## Connect protocol client (JSON codec) for the bridge.
##
## Every RPC is `POST http://<host>:<port>/sdk.v1.<Service>/<Method>`.
## Unary calls use `application/json`; server streams use
## `application/connect+json` with the Connect enveloped framing:
## `1 byte flags | 4 byte big-endian length | payload`. A frame with flag
## `0x02` is the final `EndStreamResponse`, whose JSON carries `error` if and
## only if the RPC failed.
##
## See https://connectrpc.com/docs/protocol and
## vendor/sdk-bridge/docs/streaming.md.

import std/[asyncdispatch, json, options, strutils, uri, net]
import http, errors

const
  ConnectProtocolVersion = "1"
  EndStreamFlag = 0x02'u8
  CompressedFlag = 0x01'u8

type
  ConnectClient* = ref object
    host*: string
    port*: Port
    hostHeader: string
    token*: string
    unaryTimeoutMs*: int
      ## Default deadline for unary RPCs (60 s). Streams have no deadline,
      ## and individual calls can override it via `unary`'s `timeoutMs`.

  ConnectStream* = ref object
    ## A server-stream in progress. Call `next` until it returns `none`.
    conn: HttpConnection
    finished: bool
    rpc: string

proc newConnectClient*(url, token: string, unaryTimeoutMs = 60_000): ConnectClient =
  ## `url` is the bridge base URL from the ready line, e.g. `http://127.0.0.1:49152`.
  let u = parseUri(url)
  if u.scheme != "http":
    raise (ref TransportError)(msg: "bridge URL must be http://, got: " & url)
  var host = u.hostname
  if host.len == 0:
    raise (ref TransportError)(msg: "bridge URL has no host: " & url)
  var port = 80
  if u.port.len > 0:
    port = parseInt(u.port)
  result = ConnectClient(host: host, port: Port(port), token: token,
                         unaryTimeoutMs: unaryTimeoutMs)
  result.hostHeader = (if host.contains(':'): "[" & host & "]" else: host) & ":" & $port

proc rpcPath(service, meth: string): string =
  "/sdk.v1." & service & "/" & meth

proc authHeaders(c: ConnectClient, contentType: string): seq[(string, string)] =
  @[("Content-Type", contentType),
    ("Authorization", "Bearer " & c.token),
    ("Connect-Protocol-Version", ConnectProtocolVersion),
    ("Accept-Encoding", "identity")]

type
  ConnSlot = ref object
    ## Lets `unary` reach the connection `unaryImpl` is using, so a fired
    ## deadline can close it instead of leaving it open until the bridge
    ## answers or goes away.
    conn: HttpConnection

proc unaryImpl(c: ConnectClient, service, meth: string, request: JsonNode,
               slot: ConnSlot): Future[JsonNode] {.async.} =
  let conn = await connectHttp(c.host, c.port)
  slot.conn = conn
  defer: conn.close()
  let body = if request.isNil: "{}" else: $request
  await conn.sendRequest("POST", rpcPath(service, meth), c.hostHeader,
                         c.authHeaders("application/json"), body)
  let head = await conn.readResponseHead()
  let respBody = await conn.readAll()
  if head.status != 200:
    raise errorFromConnectBody(respBody, head.status)
  if respBody.strip().len == 0:
    return newJObject()
  try:
    result = parseJson(respBody)
  except JsonParsingError, ValueError:
    raise (ref TransportError)(msg: service & "/" & meth & ": response is not JSON: " &
                                    respBody[0 ..< min(respBody.len, 200)])

proc unary*(c: ConnectClient, service, meth: string, request: JsonNode = nil,
            timeoutMs = -1): Future[JsonNode] {.async.} =
  ## Performs a unary RPC. Raises `RpcError` (or a subclass) on a Connect
  ## error, `TransportError` on connection problems or deadline expiry.
  ## `timeoutMs`: negative → the client's `unaryTimeoutMs`; `0` → no
  ## deadline (for RPCs that block for as long as a run takes, such as
  ## `WaitLiveRun`).
  let slot = ConnSlot()
  let fut = c.unaryImpl(service, meth, request, slot)
  let deadline = if timeoutMs < 0: c.unaryTimeoutMs else: timeoutMs
  if deadline > 0:
    let completed = await fut.withTimeout(deadline)
    if not completed:
      # Let the underlying future settle later without crashing the loop,
      # and drop the socket now so a hung bridge does not pin it (the
      # pending read fails into `fut`, which the callback swallows).
      fut.callback = proc (f: Future[JsonNode]) = discard f.failed
      slot.conn.close()   # nil-safe; nil if the connect itself is hung
      raise (ref TransportError)(msg: service & "/" & meth & ": timed out after " &
                                      $deadline & " ms")
  result = await fut

proc frame(payload: string, flags: uint8 = 0): string =
  result = newStringOfCap(payload.len + 5)
  result.add char(flags)
  let n = uint32(payload.len)
  result.add char((n shr 24) and 0xff)
  result.add char((n shr 16) and 0xff)
  result.add char((n shr 8) and 0xff)
  result.add char(n and 0xff)
  result.add payload

proc serverStream*(c: ConnectClient, service, meth: string, request: JsonNode = nil): Future[ConnectStream] {.async.} =
  ## Starts a server-streaming RPC. The returned stream must be drained
  ## with `next` or `close`d.
  let conn = await connectHttp(c.host, c.port)
  let body = frame(if request.isNil: "{}" else: $request)
  try:
    await conn.sendRequest("POST", rpcPath(service, meth), c.hostHeader,
                           c.authHeaders("application/connect+json"), body)
    let head = await conn.readResponseHead()
    if head.status != 200:
      let respBody = await conn.readAll()
      raise errorFromConnectBody(respBody, head.status)
  except CatchableError:
    conn.close()
    raise
  result = ConnectStream(conn: conn, rpc: service & "/" & meth)

proc finished*(s: ConnectStream): bool = s.finished

proc close*(s: ConnectStream) =
  ## Drops the connection. Dropping a `Send` stream does not cancel the run.
  if s != nil:
    s.finished = true
    s.conn.close()

proc next*(s: ConnectStream): Future[Option[JsonNode]] {.async.} =
  ## Returns the next message, or `none` after the EndStreamResponse.
  ## Raises `RpcError` if the EndStreamResponse carries an error.
  if s.finished: return none(JsonNode)
  let header = await s.conn.readExact(5)
  if header.len < 5:
    s.close()
    raise (ref TransportError)(msg: s.rpc & ": stream ended without an EndStreamResponse frame")
  let flags = uint8(header[0])
  let length = (int(uint8(header[1])) shl 24) or (int(uint8(header[2])) shl 16) or
               (int(uint8(header[3])) shl 8) or int(uint8(header[4]))
  let payload = await s.conn.readExact(length)
  if payload.len < length:
    s.close()
    raise (ref TransportError)(msg: s.rpc & ": stream truncated inside a frame")
  if (flags and CompressedFlag) != 0:
    s.close()
    raise (ref TransportError)(msg: s.rpc & ": unexpected compressed frame")
  if (flags and EndStreamFlag) != 0:
    s.close()
    if payload.strip().len > 0:
      var endNode: JsonNode
      try:
        endNode = parseJson(payload)
      except JsonParsingError, ValueError:
        raise (ref TransportError)(msg: s.rpc & ": malformed EndStreamResponse")
      if endNode.kind == JObject and endNode.hasKey("error"):
        raise errorFromConnectJson(endNode["error"])
    return none(JsonNode)
  try:
    result = some(parseJson(payload))
  except JsonParsingError, ValueError:
    s.close()
    raise (ref TransportError)(msg: s.rpc & ": frame payload is not JSON")
