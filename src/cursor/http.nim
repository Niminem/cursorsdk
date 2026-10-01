## Minimal asynchronous HTTP/1.1 client over `std/asyncnet`.
##
## The bridge serves Connect over HTTP/1.1 on loopback. `std/httpclient`
## cannot hand back a response body incrementally in the way Connect
## server-streams need (frame-by-frame, with no read timeout during long
## idle periods), so this module implements the small subset we need:
## one request per connection, fixed-length and chunked response bodies,
## and exact-size body reads.

import std/[asyncdispatch, asyncnet, strutils, tables, net]
import errors

export Port

type
  HttpHeaders* = Table[string, string]
    ## Response headers with lower-cased keys.

  HttpResponseHead* = object
    status*: int
    reason*: string
    headers*: HttpHeaders

  BodyFraming = enum
    bfNone          ## no body (or not yet determined)
    bfUntilClose    ## read until the peer closes
    bfContentLength ## `remaining` bytes left
    bfChunked       ## RFC 7230 chunked transfer coding

  HttpConnection* = ref object
    sock: AsyncSocket
    framing: BodyFraming
    remaining: int       ## bytes left for bfContentLength
    chunkRemaining: int  ## bytes left in the current chunk for bfChunked
    bodyDone: bool
    closed: bool

proc transportError(msg: string): ref TransportError =
  (ref TransportError)(msg: msg)

proc connectHttp*(host: string, port: Port): Future[HttpConnection] {.async.} =
  ## Opens a TCP connection to `host:port`.
  let sock = newAsyncSocket(buffered = true)
  try:
    await sock.connect(host, port)
  except OSError as e:
    sock.close()
    raise transportError("connect to " & host & ":" & $port & " failed: " & e.msg)
  result = HttpConnection(sock: sock)

proc close*(conn: HttpConnection) =
  if conn != nil and not conn.closed:
    conn.closed = true
    try: conn.sock.close()
    except CatchableError: discard

proc isClosed*(conn: HttpConnection): bool = conn == nil or conn.closed

proc sendRequest*(conn: HttpConnection, meth, path, host: string,
                  headers: seq[(string, string)], body: string) {.async.} =
  ## Writes a complete request with a fixed-length body.
  var req = newStringOfCap(256 + body.len)
  req.add meth; req.add ' '; req.add path; req.add " HTTP/1.1\r\n"
  req.add "Host: "; req.add host; req.add "\r\n"
  req.add "Connection: close\r\n"
  req.add "Content-Length: "; req.add $body.len; req.add "\r\n"
  for (k, v) in headers:
    req.add k; req.add ": "; req.add v; req.add "\r\n"
  req.add "\r\n"
  req.add body
  try:
    await conn.sock.send(req)
  except OSError as e:
    raise transportError("send failed: " & e.msg)

proc recvLineChecked(conn: HttpConnection): Future[string] {.async.} =
  ## `recvLine` that distinguishes a blank line ("\r\L") from EOF ("").
  try:
    result = await conn.sock.recvLine()
  except OSError as e:
    raise transportError("recv failed: " & e.msg)

proc readResponseHead*(conn: HttpConnection): Future[HttpResponseHead] {.async.} =
  ## Reads the status line and headers and configures body framing.
  var statusLine = await conn.recvLineChecked()
  if statusLine.len == 0:
    raise transportError("connection closed before response status line")
  # Tolerate stray blank lines before the status line.
  while statusLine == "\r\L":
    statusLine = await conn.recvLineChecked()
    if statusLine.len == 0:
      raise transportError("connection closed before response status line")
  let parts = statusLine.split(' ', maxsplit = 2)
  if parts.len < 2 or not parts[0].startsWith("HTTP/1."):
    raise transportError("malformed status line: " & statusLine)
  try:
    result.status = parseInt(parts[1])
  except ValueError:
    raise transportError("malformed status code: " & statusLine)
  result.reason = if parts.len > 2: parts[2] else: ""
  result.headers = initTable[string, string]()
  while true:
    let line = await conn.recvLineChecked()
    if line.len == 0:
      raise transportError("connection closed inside response headers")
    if line == "\r\L": break
    let colon = line.find(':')
    if colon <= 0: continue
    let key = line[0 ..< colon].strip().toLowerAscii
    let value = line[colon + 1 .. ^1].strip()
    if key in result.headers:
      result.headers[key] = result.headers[key] & ", " & value
    else:
      result.headers[key] = value
  # Determine framing (RFC 7230 §3.3.3).
  if result.headers.getOrDefault("transfer-encoding").toLowerAscii.contains("chunked"):
    conn.framing = bfChunked
  elif "content-length" in result.headers:
    try:
      conn.remaining = parseInt(result.headers["content-length"].strip())
    except ValueError:
      raise transportError("malformed Content-Length")
    conn.framing = bfContentLength
    conn.bodyDone = conn.remaining == 0
  elif result.status == 204 or result.status == 304 or result.status div 100 == 1:
    conn.framing = bfNone
    conn.bodyDone = true
  else:
    conn.framing = bfUntilClose

proc recvExactRaw(conn: HttpConnection, n: int): Future[string] {.async.} =
  ## Reads exactly `n` bytes from the socket, or fewer at EOF.
  if n <= 0: return ""
  try:
    result = await conn.sock.recv(n)
  except OSError as e:
    raise transportError("recv failed: " & e.msg)

proc nextChunkHeader(conn: HttpConnection) {.async.} =
  ## Positions `conn` at the start of the next chunk's data, or marks the
  ## body as done when the terminating zero-length chunk is seen.
  var line = await conn.recvLineChecked()
  # The CRLF that terminates the previous chunk's data may show up as a
  # blank line here if it was not consumed; skip it.
  while line == "\r\L":
    line = await conn.recvLineChecked()
  if line.len == 0:
    raise transportError("connection closed inside chunked body")
  let semi = line.find(';')
  let sizeStr = (if semi >= 0: line[0 ..< semi] else: line).strip()
  var size: int
  try:
    size = parseHexInt(sizeStr)
  except ValueError:
    raise transportError("malformed chunk size: " & line)
  if size == 0:
    # Consume trailers until the blank line.
    while true:
      let t = await conn.recvLineChecked()
      if t.len == 0 or t == "\r\L": break
    conn.bodyDone = true
  else:
    conn.chunkRemaining = size

proc readBody*(conn: HttpConnection, maxBytes: int): Future[string] {.async.} =
  ## Reads up to `maxBytes` of body, honouring the response framing.
  ## Returns "" once the body is complete.
  if conn.bodyDone or maxBytes <= 0: return ""
  case conn.framing
  of bfNone:
    conn.bodyDone = true
    return ""
  of bfUntilClose:
    let data = await conn.recvExactRaw(maxBytes)
    if data.len == 0: conn.bodyDone = true
    return data
  of bfContentLength:
    let want = min(maxBytes, conn.remaining)
    let data = await conn.recvExactRaw(want)
    if data.len < want:
      raise transportError("connection closed with " & $(conn.remaining - data.len) & " body bytes outstanding")
    conn.remaining -= data.len
    if conn.remaining == 0: conn.bodyDone = true
    return data
  of bfChunked:
    if conn.chunkRemaining == 0:
      await conn.nextChunkHeader()
      if conn.bodyDone: return ""
    let want = min(maxBytes, conn.chunkRemaining)
    let data = await conn.recvExactRaw(want)
    if data.len < want:
      raise transportError("connection closed inside chunk")
    conn.chunkRemaining -= data.len
    if conn.chunkRemaining == 0:
      # Consume the CRLF after the chunk data.
      let crlf = await conn.recvExactRaw(2)
      if crlf.len < 2:
        raise transportError("connection closed after chunk")
    return data

proc readExact*(conn: HttpConnection, n: int): Future[string] {.async.} =
  ## Reads exactly `n` body bytes across framing boundaries. Returns fewer
  ## only if the body ends first.
  result = newStringOfCap(n)
  while result.len < n:
    let part = await conn.readBody(n - result.len)
    if part.len == 0: break
    result.add part

proc readAll*(conn: HttpConnection): Future[string] {.async.} =
  ## Reads the remainder of the body.
  while true:
    let part = await conn.readBody(64 * 1024)
    if part.len == 0: break
    result.add part
