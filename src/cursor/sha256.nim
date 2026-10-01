## Minimal SHA-256 (FIPS 180-4) used to verify downloaded bridge archives
## against the release's `SHA256SUMS.txt` without pulling in a dependency.

import std/strutils

const K = [
  0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32, 0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
  0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32, 0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
  0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32, 0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
  0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32, 0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
  0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32, 0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
  0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32, 0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
  0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32, 0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
  0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32, 0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]

type Sha256State* = object
  h: array[8, uint32]
  buf: array[64, byte]
  bufLen: int
  total: uint64

proc rotr(x: uint32, n: int): uint32 {.inline.} = (x shr n) or (x shl (32 - n))

proc compress(s: var Sha256State, block64: openArray[byte]) =
  var w: array[64, uint32]
  for i in 0 ..< 16:
    w[i] = (uint32(block64[i*4]) shl 24) or (uint32(block64[i*4+1]) shl 16) or
           (uint32(block64[i*4+2]) shl 8) or uint32(block64[i*4+3])
  for i in 16 ..< 64:
    let s0 = rotr(w[i-15], 7) xor rotr(w[i-15], 18) xor (w[i-15] shr 3)
    let s1 = rotr(w[i-2], 17) xor rotr(w[i-2], 19) xor (w[i-2] shr 10)
    w[i] = w[i-16] + s0 + w[i-7] + s1
  var a = s.h[0]; var b = s.h[1]; var c = s.h[2]; var d = s.h[3]
  var e = s.h[4]; var f = s.h[5]; var g = s.h[6]; var hh = s.h[7]
  for i in 0 ..< 64:
    let S1 = rotr(e, 6) xor rotr(e, 11) xor rotr(e, 25)
    let ch = (e and f) xor ((not e) and g)
    let t1 = hh + S1 + ch + K[i] + w[i]
    let S0 = rotr(a, 2) xor rotr(a, 13) xor rotr(a, 22)
    let maj = (a and b) xor (a and c) xor (b and c)
    let t2 = S0 + maj
    hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2
  s.h[0] += a; s.h[1] += b; s.h[2] += c; s.h[3] += d
  s.h[4] += e; s.h[5] += f; s.h[6] += g; s.h[7] += hh

proc initSha256*(): Sha256State =
  result.h = [0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
              0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]

proc update*(s: var Sha256State, data: openArray[byte]) =
  s.total += uint64(data.len)
  var i = 0
  if s.bufLen > 0:
    while s.bufLen < 64 and i < data.len:
      s.buf[s.bufLen] = data[i]; inc s.bufLen; inc i
    if s.bufLen == 64:
      s.compress(s.buf); s.bufLen = 0
  while i + 64 <= data.len:
    s.compress(data.toOpenArray(i, i + 63)); i += 64
  while i < data.len:
    s.buf[s.bufLen] = data[i]; inc s.bufLen; inc i

proc update*(s: var Sha256State, data: string) =
  if data.len > 0:
    s.update(data.toOpenArrayByte(0, data.high))

proc finish*(s: var Sha256State): array[32, byte] =
  let bitLen = s.total * 8
  var pad = @[0x80'u8]
  while (s.bufLen + pad.len) mod 64 != 56: pad.add 0'u8
  for i in countdown(7, 0): pad.add byte((bitLen shr (i * 8)) and 0xff)
  s.update(pad)
  doAssert s.bufLen == 0
  for i in 0 ..< 8:
    result[i*4] = byte(s.h[i] shr 24); result[i*4+1] = byte(s.h[i] shr 16)
    result[i*4+2] = byte(s.h[i] shr 8); result[i*4+3] = byte(s.h[i])

proc toHex*(digest: array[32, byte]): string =
  result = newStringOfCap(64)
  for b in digest: result.add b.toHex(2).toLowerAscii

proc sha256Hex*(data: string): string =
  var s = initSha256()
  s.update(data)
  s.finish().toHex

proc sha256HexFile*(path: string): string =
  ## Streams `path` through SHA-256 in 1 MiB chunks.
  var s = initSha256()
  var f = open(path, fmRead)
  defer: f.close()
  var chunk = newString(1 shl 20)
  while true:
    let n = f.readChars(chunk.toOpenArray(0, chunk.high))
    if n == 0: break
    s.update(chunk.toOpenArrayByte(0, n - 1))
  s.finish().toHex
