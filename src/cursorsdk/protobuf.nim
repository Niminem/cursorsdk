## Minimal protobuf wire-format support.
##
## The bridge speaks JSON with us everywhere except two places: the
## `sdk.v1.SdkErrorDetails` payload inside Connect error details is binary
## protobuf, and callback requests from the bridge may arrive as
## `application/proto`. This module provides the primitives for both, plus
## a `google.protobuf.Struct` <-> `JsonNode` codec.

import std/[json, math]

type
  WireType* = enum
    wtVarint = 0, wtFixed64 = 1, wtLengthDelimited = 2, wtStartGroup = 3,
    wtEndGroup = 4, wtFixed32 = 5

  ProtoField* = object
    number*: int
    wireType*: WireType
    varint*: uint64       ## wtVarint
    fixed64*: uint64      ## wtFixed64 (raw bits)
    fixed32*: uint32      ## wtFixed32 (raw bits)
    bytes*: string        ## wtLengthDelimited

# ---------------------------------------------------------------------------
# Reading

proc readVarint*(data: string, pos: var int): uint64 =
  var shift = 0
  while true:
    if pos >= data.len:
      raise newException(ValueError, "truncated varint")
    let b = uint8(data[pos]); inc pos
    result = result or (uint64(b and 0x7f) shl shift)
    if (b and 0x80) == 0: break
    shift += 7
    if shift > 63:
      raise newException(ValueError, "varint too long")

proc readFixed64(data: string, pos: var int): uint64 =
  if pos + 8 > data.len: raise newException(ValueError, "truncated fixed64")
  for i in 0 ..< 8:
    result = result or (uint64(uint8(data[pos + i])) shl (8 * i))
  pos += 8

proc readFixed32(data: string, pos: var int): uint32 =
  if pos + 4 > data.len: raise newException(ValueError, "truncated fixed32")
  for i in 0 ..< 4:
    result = result or (uint32(uint8(data[pos + i])) shl (8 * i))
  pos += 4

proc readLengthDelimited*(data: string, pos: var int): string =
  let n = int(readVarint(data, pos))
  if n < 0 or pos + n > data.len:
    raise newException(ValueError, "truncated length-delimited field")
  result = data[pos ..< pos + n]
  pos += n

iterator fields*(data: string): ProtoField =
  ## Iterates the top-level fields of a serialized message. Groups are
  ## not supported (proto3 never emits them).
  var pos = 0
  while pos < data.len:
    let tag = readVarint(data, pos)
    var f = ProtoField(number: int(tag shr 3))
    let wt = int(tag and 7)
    if wt > 5 or wt == 3 or wt == 4:
      raise newException(ValueError, "unsupported wire type " & $wt)
    f.wireType = WireType(wt)
    case f.wireType
    of wtVarint: f.varint = readVarint(data, pos)
    of wtFixed64: f.fixed64 = readFixed64(data, pos)
    of wtLengthDelimited: f.bytes = readLengthDelimited(data, pos)
    of wtFixed32: f.fixed32 = readFixed32(data, pos)
    else: discard
    yield f

# ---------------------------------------------------------------------------
# Writing

proc writeVarint*(buf: var string, v: uint64) =
  var x = v
  while true:
    let b = uint8(x and 0x7f)
    x = x shr 7
    if x == 0:
      buf.add char(b); break
    buf.add char(b or 0x80)

proc writeTag(buf: var string, number: int, wt: WireType) =
  buf.writeVarint(uint64(number shl 3) or uint64(ord(wt)))

proc writeVarintField*(buf: var string, number: int, v: uint64) =
  buf.writeTag(number, wtVarint)
  buf.writeVarint(v)

proc writeBytesField*(buf: var string, number: int, data: string) =
  buf.writeTag(number, wtLengthDelimited)
  buf.writeVarint(uint64(data.len))
  buf.add data

proc writeStringField*(buf: var string, number: int, s: string) =
  if s.len > 0: buf.writeBytesField(number, s)

proc writeFixed64Field*(buf: var string, number: int, bits: uint64) =
  buf.writeTag(number, wtFixed64)
  for i in 0 ..< 8: buf.add char((bits shr (8 * i)) and 0xff)

# ---------------------------------------------------------------------------
# google.protobuf.Struct / Value / ListValue

proc encodeValue*(n: JsonNode): string {.gcsafe.}
proc encodeStruct*(n: JsonNode): string {.gcsafe.}

proc encodeListValue(n: JsonNode): string {.gcsafe.} =
  for e in n: result.writeBytesField(1, encodeValue(e))

proc encodeValue*(n: JsonNode): string {.gcsafe.} =
  ## Serializes a `JsonNode` as `google.protobuf.Value`.
  if n.isNil: result.writeVarintField(1, 0); return
  case n.kind
  of JNull: result.writeVarintField(1, 0)
  of JInt: result.writeFixed64Field(2, cast[uint64](float64(n.getBiggestInt)))
  of JFloat: result.writeFixed64Field(2, cast[uint64](n.getFloat))
  of JString: result.writeBytesField(3, n.getStr)
  of JBool: result.writeVarintField(4, (if n.getBool: 1'u64 else: 0'u64))
  of JObject: result.writeBytesField(5, encodeStruct(n))
  of JArray: result.writeBytesField(6, encodeListValue(n))

proc encodeStruct*(n: JsonNode): string {.gcsafe.} =
  ## Serializes a JSON object as `google.protobuf.Struct`.
  if n.isNil or n.kind != JObject: return ""
  for k, v in n:
    var entry: string
    entry.writeBytesField(1, k)
    entry.writeBytesField(2, encodeValue(v))
    result.writeBytesField(1, entry)

proc decodeValue*(data: string): JsonNode {.gcsafe.}
proc decodeStruct*(data: string): JsonNode {.gcsafe.}

proc decodeListValue(data: string): JsonNode {.gcsafe.} =
  result = newJArray()
  for f in fields(data):
    if f.number == 1 and f.wireType == wtLengthDelimited:
      result.add decodeValue(f.bytes)

proc decodeValue*(data: string): JsonNode {.gcsafe.} =
  ## Parses a serialized `google.protobuf.Value`.
  result = newJNull()
  for f in fields(data):
    case f.number
    of 1: result = newJNull()
    of 2:
      if f.wireType == wtFixed64:
        let d = cast[float64](f.fixed64)
        if d == trunc(d) and abs(d) < 9.007199254740992e15: result = %int64(d)
        else: result = %d
    of 3:
      if f.wireType == wtLengthDelimited: result = %f.bytes
    of 4:
      if f.wireType == wtVarint: result = %(f.varint != 0)
    of 5:
      if f.wireType == wtLengthDelimited: result = decodeStruct(f.bytes)
    of 6:
      if f.wireType == wtLengthDelimited: result = decodeListValue(f.bytes)
    else: discard

proc decodeStruct*(data: string): JsonNode {.gcsafe.} =
  ## Parses a serialized `google.protobuf.Struct` into a JSON object.
  result = newJObject()
  for f in fields(data):
    if f.number != 1 or f.wireType != wtLengthDelimited: continue
    var key = ""
    var value: JsonNode = newJNull()
    for e in fields(f.bytes):
      if e.number == 1 and e.wireType == wtLengthDelimited: key = e.bytes
      elif e.number == 2 and e.wireType == wtLengthDelimited: value = decodeValue(e.bytes)
    result[key] = value
