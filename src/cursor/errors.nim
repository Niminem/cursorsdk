## Error model: a `CursorError` root, launch/transport failures, and an
## `RpcError` hierarchy mapped from Connect codes plus the stable
## `sdk.v1.SdkErrorCode` taxonomy carried in `SdkErrorDetails`.
##
## See vendor/sdk-bridge/docs/errors.md.

import std/[json, options, strutils, times, base64]
import protobuf

type
  CursorError* = object of CatchableError
    ## Root of every error raised by this package.

  BridgeError* = object of CursorError
    ## Bridge process failures: binary not found, download/verify failure,
    ## exit before the ready line, malformed discovery line, handshake
    ## timeout. `stderr` holds captured bridge output when available.
    stderr*: string

  TransportError* = object of CursorError
    ## Socket / HTTP / Connect framing failures.

  ConnectCode* = enum
    ## Connect protocol error codes (https://connectrpc.com/docs/protocol#error-codes).
    ccUnknown = "unknown"
    ccCanceled = "canceled"
    ccInvalidArgument = "invalid_argument"
    ccDeadlineExceeded = "deadline_exceeded"
    ccNotFound = "not_found"
    ccAlreadyExists = "already_exists"
    ccPermissionDenied = "permission_denied"
    ccResourceExhausted = "resource_exhausted"
    ccFailedPrecondition = "failed_precondition"
    ccAborted = "aborted"
    ccOutOfRange = "out_of_range"
    ccUnimplemented = "unimplemented"
    ccInternal = "internal"
    ccUnavailable = "unavailable"
    ccDataLoss = "data_loss"
    ccUnauthenticated = "unauthenticated"

  SdkErrorCode* = enum
    ## `sdk.v1.SdkErrorCode`. Values not known at build time decode to
    ## `secUnspecified`; the raw integer is kept in `SdkErrorDetails.rawCode`.
    secUnspecified = 0
    secUnauthorized = 1
    secApiKeyNotFound = 2
    secPlanRequired = 3
    secRoleForbidden = 4
    secFeatureUnavailable = 5
    secAgentNotFound = 6
    secRunNotFound = 7
    secValidationError = 8
    secInvalidModel = 9
    secInvalidBranchName = 10
    secRepositoryRequired = 11
    secRepositoryAccess = 12
    secPrResolutionFailed = 13
    secUsageLimitExceeded = 14
    secAgentBusy = 15
    secAgentArchived = 16
    secRunNotCancellable = 17
    secRateLimitExceeded = 18
    secUpstreamError = 19
    secInternalError = 20
    secClientCancelled = 21

  RateLimitInfo* = object
    limit*: Option[uint64]
    remaining*: Option[uint64]
    resetEpochSeconds*: Option[uint64]

  SdkErrorDetails* = object
    requestId*: Option[string]
    sdkErrorCode*: SdkErrorCode
    rawCode*: int               ## wire value, even if unknown to this build
    message*: string
    helpUrl*: Option[string]
    provider*: Option[string]
    retryAfter*: Option[Duration]
    rateLimit*: Option[RateLimitInfo]

  RpcError* = object of CursorError
    ## A failed RPC. Catch a subclass to branch on category, or inspect
    ## `details` for the stable `sdkErrorCode`.
    connectCode*: ConnectCode
    httpStatus*: int            ## 0 for errors delivered in a stream's EndStreamResponse
    details*: Option[SdkErrorDetails]

  AuthError* = object of RpcError
    ## Bad/missing Cursor API key, or bad/missing bridge bearer token.
  PermissionError* = object of RpcError
    ## Plan, role, or feature restrictions.
  NotFoundError* = object of RpcError
  ValidationError* = object of RpcError
    ## Invalid request, model, branch, or repository options.
  RateLimitError* = object of RpcError
    ## Rate or usage limits; honour `retryAfter` / `rateLimit`.
  AgentBusyError* = object of RpcError
  AgentArchivedError* = object of RpcError
  RunNotCancellableError* = object of RpcError
  UpstreamError* = object of RpcError
  InternalError* = object of RpcError
  UnavailableError* = object of RpcError
    ## Transient: `unavailable` / `deadline_exceeded`.
  CancelledError* = object of RpcError

# ---------------------------------------------------------------------------
# Accessors

proc sdkErrorCode*(e: ref RpcError): SdkErrorCode =
  if e.details.isSome: e.details.get.sdkErrorCode else: secUnspecified

proc requestId*(e: ref RpcError): Option[string] =
  if e.details.isSome: e.details.get.requestId else: none(string)

proc retryAfter*(e: ref RpcError): Option[Duration] =
  if e.details.isSome: e.details.get.retryAfter else: none(Duration)

proc rateLimit*(e: ref RpcError): Option[RateLimitInfo] =
  if e.details.isSome: e.details.get.rateLimit else: none(RateLimitInfo)

# ---------------------------------------------------------------------------
# Protobuf wire decoding for sdk.v1.SdkErrorDetails

proc decodeDuration(data: string): Duration =
  var seconds = 0'i64
  var nanos = 0'i32
  for f in fields(data):
    if f.wireType != wtVarint: continue
    case f.number
    of 1: seconds = cast[int64](f.varint)
    of 2: nanos = cast[int32](uint32(f.varint))
    else: discard
  initDuration(seconds = seconds, nanoseconds = nanos)

proc decodeRateLimitInfo(data: string): RateLimitInfo =
  for f in fields(data):
    if f.wireType != wtVarint: continue
    case f.number
    of 1: result.limit = some(f.varint)
    of 2: result.remaining = some(f.varint)
    of 3: result.resetEpochSeconds = some(f.varint)
    else: discard

proc toSdkErrorCode*(raw: int): SdkErrorCode =
  if raw >= ord(low(SdkErrorCode)) and raw <= ord(high(SdkErrorCode)):
    SdkErrorCode(raw)
  else:
    secUnspecified

proc decodeSdkErrorDetails*(data: string): SdkErrorDetails =
  ## Decodes a serialized `sdk.v1.SdkErrorDetails` message. Unknown fields
  ## are skipped (forward compatibility).
  for f in fields(data):
    case f.number
    of 1:
      if f.wireType == wtLengthDelimited: result.requestId = some(f.bytes)
    of 2:
      if f.wireType == wtVarint:
        result.rawCode = int(f.varint)
        result.sdkErrorCode = toSdkErrorCode(result.rawCode)
    of 3:
      if f.wireType == wtLengthDelimited: result.message = f.bytes
    of 4:
      if f.wireType == wtLengthDelimited: result.helpUrl = some(f.bytes)
    of 5:
      if f.wireType == wtLengthDelimited: result.provider = some(f.bytes)
    of 6:
      if f.wireType == wtLengthDelimited: result.retryAfter = some(decodeDuration(f.bytes))
    of 7:
      if f.wireType == wtLengthDelimited: result.rateLimit = some(decodeRateLimitInfo(f.bytes))
    else: discard

proc decodeBase64Lenient*(s: string): string =
  ## Accepts standard or URL-safe alphabets, with or without padding.
  var t = s.strip().replace('-', '+').replace('_', '/')
  while t.len mod 4 != 0: t.add '='
  base64.decode(t)

# ---------------------------------------------------------------------------
# Connect error body -> RpcError

proc parseConnectCode*(s: string): ConnectCode =
  for c in ConnectCode:
    if $c == s: return c
  ccUnknown

proc parseSdkErrorCodeName(s: string): Option[SdkErrorCode] =
  ## Accepts "SDK_ERROR_CODE_AGENT_BUSY", "AGENT_BUSY", or an integer string.
  var name = s
  if name.startsWith("SDK_ERROR_CODE_"): name = name[len("SDK_ERROR_CODE_") .. ^1]
  try:
    return some(toSdkErrorCode(parseInt(name)))
  except ValueError: discard
  const names = [
    "UNSPECIFIED", "UNAUTHORIZED", "API_KEY_NOT_FOUND", "PLAN_REQUIRED", "ROLE_FORBIDDEN",
    "FEATURE_UNAVAILABLE", "AGENT_NOT_FOUND", "RUN_NOT_FOUND", "VALIDATION_ERROR",
    "INVALID_MODEL", "INVALID_BRANCH_NAME", "REPOSITORY_REQUIRED", "REPOSITORY_ACCESS",
    "PR_RESOLUTION_FAILED", "USAGE_LIMIT_EXCEEDED", "AGENT_BUSY", "AGENT_ARCHIVED",
    "RUN_NOT_CANCELLABLE", "RATE_LIMIT_EXCEEDED", "UPSTREAM_ERROR", "INTERNAL_ERROR",
    "CLIENT_CANCELLED"]
  for i, n in names:
    if n == name: return some(SdkErrorCode(i))
  none(SdkErrorCode)

proc parseDurationJson(s: string): Option[Duration] =
  ## google.protobuf.Duration JSON form: "3.5s".
  var t = s.strip()
  if not t.endsWith("s"): return none(Duration)
  t = t[0 ..< ^1]
  try:
    let f = parseFloat(t)
    return some(initDuration(nanoseconds = int64(f * 1e9)))
  except ValueError:
    return none(Duration)

proc detailsFromDebugJson(node: JsonNode): SdkErrorDetails =
  ## Builds details from the `debug` JSON rendering of SdkErrorDetails.
  if node.kind != JObject: return
  if node.hasKey("requestId") and node["requestId"].kind == JString:
    result.requestId = some(node["requestId"].getStr)
  if node.hasKey("sdkErrorCode"):
    let c = node["sdkErrorCode"]
    if c.kind == JString:
      let parsed = parseSdkErrorCodeName(c.getStr)
      if parsed.isSome:
        result.sdkErrorCode = parsed.get
        result.rawCode = ord(parsed.get)
    elif c.kind == JInt:
      result.rawCode = c.getInt
      result.sdkErrorCode = toSdkErrorCode(result.rawCode)
  if node.hasKey("message") and node["message"].kind == JString:
    result.message = node["message"].getStr
  if node.hasKey("helpUrl") and node["helpUrl"].kind == JString:
    result.helpUrl = some(node["helpUrl"].getStr)
  if node.hasKey("provider") and node["provider"].kind == JString:
    result.provider = some(node["provider"].getStr)
  if node.hasKey("retryAfter") and node["retryAfter"].kind == JString:
    result.retryAfter = parseDurationJson(node["retryAfter"].getStr)
  if node.hasKey("rateLimit") and node["rateLimit"].kind == JObject:
    var rl: RateLimitInfo
    let r = node["rateLimit"]
    proc u64(n: JsonNode): Option[uint64] =
      case n.kind
      of JInt: some(uint64(n.getBiggestInt))
      of JString:
        try: some(uint64(parseBiggestUInt(n.getStr)))
        except ValueError: none(uint64)
      else: none(uint64)
    if r.hasKey("limit"): rl.limit = u64(r["limit"])
    if r.hasKey("remaining"): rl.remaining = u64(r["remaining"])
    if r.hasKey("resetEpochSeconds"): rl.resetEpochSeconds = u64(r["resetEpochSeconds"])
    result.rateLimit = some(rl)

proc extractSdkErrorDetails*(errorNode: JsonNode): Option[SdkErrorDetails] =
  ## Finds the `sdk.v1.SdkErrorDetails` entry in a Connect error's `details`
  ## array. Prefers the binary `value` (authoritative), falling back to the
  ## optional `debug` JSON rendering.
  if errorNode.kind != JObject or not errorNode.hasKey("details"): return
  let details = errorNode["details"]
  if details.kind != JArray: return
  for d in details:
    if d.kind != JObject: continue
    let typ = d.getOrDefault("type")
    if typ.isNil or typ.kind != JString: continue
    if not typ.getStr.endsWith("SdkErrorDetails"): continue
    let value = d.getOrDefault("value")
    if not value.isNil and value.kind == JString and value.getStr.len > 0:
      try:
        return some(decodeSdkErrorDetails(decodeBase64Lenient(value.getStr)))
      except ValueError, CatchableError:
        discard
    let dbg = d.getOrDefault("debug")
    if not dbg.isNil and dbg.kind == JObject:
      return some(detailsFromDebugJson(dbg))
  none(SdkErrorDetails)

proc classify(code: ConnectCode, sdkCode: SdkErrorCode): ref RpcError =
  ## Picks the exception subclass for a (connect code, sdk code) pair.
  case sdkCode
  of secUnauthorized, secApiKeyNotFound: return (ref AuthError)()
  of secPlanRequired, secRoleForbidden, secFeatureUnavailable: return (ref PermissionError)()
  of secAgentNotFound, secRunNotFound: return (ref NotFoundError)()
  of secValidationError, secInvalidModel, secInvalidBranchName, secRepositoryRequired,
     secRepositoryAccess, secPrResolutionFailed: return (ref ValidationError)()
  of secUsageLimitExceeded, secRateLimitExceeded: return (ref RateLimitError)()
  of secAgentBusy: return (ref AgentBusyError)()
  of secAgentArchived: return (ref AgentArchivedError)()
  of secRunNotCancellable: return (ref RunNotCancellableError)()
  of secUpstreamError: return (ref UpstreamError)()
  of secInternalError: return (ref InternalError)()
  of secClientCancelled: return (ref CancelledError)()
  of secUnspecified: discard
  case code
  of ccUnauthenticated: (ref AuthError)()
  of ccPermissionDenied: (ref PermissionError)()
  of ccNotFound: (ref NotFoundError)()
  of ccInvalidArgument, ccFailedPrecondition, ccOutOfRange, ccAlreadyExists: (ref ValidationError)()
  of ccResourceExhausted: (ref RateLimitError)()
  of ccCanceled: (ref CancelledError)()
  of ccUnavailable, ccDeadlineExceeded, ccAborted: (ref UnavailableError)()
  of ccInternal, ccDataLoss, ccUnknown: (ref InternalError)()
  of ccUnimplemented: (ref RpcError)()

proc newRpcError*(code: ConnectCode, message: string, httpStatus = 0,
                  details = none(SdkErrorDetails)): ref RpcError =
  ## Builds the appropriately-typed RpcError.
  let sdkCode = if details.isSome: details.get.sdkErrorCode else: secUnspecified
  result = classify(code, sdkCode)
  result.connectCode = code
  result.httpStatus = httpStatus
  result.details = details
  var msg = "[" & $code
  if sdkCode != secUnspecified: msg.add "/" & $sdkCode
  msg.add "] " & message
  if details.isSome and details.get.requestId.isSome:
    msg.add " (request_id=" & details.get.requestId.get & ")"
  result.msg = msg

proc errorFromConnectJson*(errorNode: JsonNode, httpStatus = 0): ref RpcError =
  ## Builds an RpcError from a parsed Connect error object
  ## (`{"code":..., "message":..., "details":[...]}`).
  var code = ccUnknown
  var message = ""
  if errorNode.kind == JObject:
    let c = errorNode.getOrDefault("code")
    if not c.isNil and c.kind == JString: code = parseConnectCode(c.getStr)
    let m = errorNode.getOrDefault("message")
    if not m.isNil and m.kind == JString: message = m.getStr
  else:
    message = $errorNode
  newRpcError(code, message, httpStatus, extractSdkErrorDetails(errorNode))

proc errorFromConnectBody*(body: string, httpStatus = 0): ref RpcError =
  ## Builds an RpcError from a raw Connect error body. Non-JSON bodies
  ## become `ccUnknown` errors carrying the body text.
  var node: JsonNode
  try:
    node = parseJson(body)
  except JsonParsingError, ValueError:
    return newRpcError(ccUnknown, "HTTP " & $httpStatus & ": " & body.strip(), httpStatus)
  errorFromConnectJson(node, httpStatus)
