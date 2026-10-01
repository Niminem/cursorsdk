## Locating, downloading, and verifying the pinned `cursor-sdk-bridge`
## binary.
##
## Resolution order (see `locateBridge`):
## 1. `CURSOR_SDK_BRIDGE_BIN` environment variable.
## 2. The per-version user cache (`getCacheDir("cursorsdk")/<version>/bin/`).
## 3. Download the standalone archive for this platform from the pinned
##    GitHub release, verify it against the release's `SHA256SUMS.txt`, and
##    extract it into the cache.
##
## Downloads shell out to `curl` and extraction to `tar`, both of which ship
## with macOS, Windows 10+, and virtually every Linux distribution. This
## keeps the package free of dependencies and of a `-d:ssl` requirement.
## Compile with `-d:ssl` to download with `std/httpclient` instead.

import std/[os, strutils, osproc, json]
when defined(ssl):
  import std/httpclient
import version, sha256, errors

const
  BridgeBinEnv* = "CURSOR_SDK_BRIDGE_BIN"
  CacheAppName = "cursorsdk"

proc bridgeExeName*(): string =
  when defined(windows): "cursor-sdk-bridge.exe" else: "cursor-sdk-bridge"

proc platformSlug*(): tuple[os, arch: string] =
  ## Release asset naming: os `linux|darwin|win32`, arch `x64|arm64`
  ## (`win32` is `x64` only).
  when defined(windows) and defined(arm64):
    raise (ref BridgeError)(msg: "no prebuilt cursor-sdk-bridge for Windows ARM" &
                                 "; set " & BridgeBinEnv & " to a bridge executable")
  let osName =
    when defined(macosx): "darwin"
    elif defined(linux): "linux"
    elif defined(windows): "win32"
    else: ""
  let archName =
    when defined(amd64): "x64"
    elif defined(arm64): "arm64"
    else: ""
  if osName.len == 0 or archName.len == 0:
    raise (ref BridgeError)(msg: "no prebuilt cursor-sdk-bridge for " & hostOS & "/" & hostCPU &
                                 "; set " & BridgeBinEnv & " to a bridge executable")
  (osName, archName)

proc archiveName*(): string =
  let (osName, archName) = platformSlug()
  "cursor-sdk-bridge-standalone-" & osName & "-" & archName & ".tar.gz"

proc defaultBridgeDir*(): string =
  ## Directory the pinned bridge release is extracted into.
  getCacheDir(CacheAppName) / BridgeVersion

proc cachedBridgePath*(dir = defaultBridgeDir()): string =
  dir / "bin" / bridgeExeName()

proc bridgeError(msg: string): ref BridgeError = (ref BridgeError)(msg: msg)

proc runTool(cmd: string, args: seq[string]): tuple[output: string, code: int] =
  let exe = findExe(cmd)
  if exe.len == 0:
    return ("", -1)
  try:
    let r = execCmdEx(quoteShellCommand(@[exe] & args))
    result = (r.output, r.exitCode)
  except OSError, IOError:
    result = (getCurrentExceptionMsg(), -1)

proc downloadFile(url, dest: string) =
  when defined(ssl):
    let client = newHttpClient(timeout = 120_000)
    defer: client.close()
    try:
      client.downloadFile(url, dest)
    except CatchableError as e:
      raise bridgeError("download of " & url & " failed: " & e.msg)
  else:
    let (output, code) = runTool("curl", @["-fsSL", "--retry", "3", "-o", dest, url])
    if code == -1 and output.len == 0:
      raise bridgeError("curl not found; install curl, compile with -d:ssl, or set " &
                        BridgeBinEnv & " to a bridge executable")
    if code != 0:
      raise bridgeError("download of " & url & " failed (curl exit " & $code & "): " & output.strip())

proc expectedChecksum(sumsText, asset: string): string =
  for line in sumsText.splitLines:
    let parts = line.strip().splitWhitespace()
    if parts.len >= 2 and parts[^1].strip(chars = {'*'}) == asset:
      return parts[0].toLowerAscii
  raise bridgeError("SHA256SUMS.txt has no entry for " & asset)

proc extractTarGz(archive, destDir: string) =
  createDir(destDir)
  let (output, code) = runTool("tar", @["-xzf", archive, "-C", destDir])
  if code == -1 and output.len == 0:
    raise bridgeError("tar not found; extract " & archive & " manually and set " & BridgeBinEnv)
  if code != 0:
    raise bridgeError("extracting " & archive & " failed (tar exit " & $code & "): " & output.strip())

proc verifyManifest(dir: string) =
  let manifestPath = dir / "manifest.json"
  if not fileExists(manifestPath):
    raise bridgeError("extracted archive has no manifest.json in " & dir)
  let manifest = parseJson(readFile(manifestPath))
  let protocol = manifest.getOrDefault("protocol")
  if protocol.isNil or protocol.getStr != ProtocolVersion:
    raise bridgeError("bridge manifest protocol is " & $protocol & ", expected " & ProtocolVersion)

proc fetchBridge*(dir = defaultBridgeDir(), force = false,
                  log: proc(msg: string) {.gcsafe.} = nil): string =
  ## Downloads, verifies, and extracts the pinned bridge release into `dir`.
  ## Returns the executable path. No-op if it is already present unless
  ## `force` is set.
  let exe = cachedBridgePath(dir)
  if fileExists(exe) and not force:
    return exe
  let asset = archiveName()
  let tmp = dir & ".download"
  removeDir(tmp)
  createDir(tmp)
  defer: removeDir(tmp)
  let archivePath = tmp / asset
  let sumsPath = tmp / "SHA256SUMS.txt"
  if log != nil: log("downloading " & BridgeReleaseBaseUrl & "/" & asset)
  downloadFile(BridgeReleaseBaseUrl & "/" & asset, archivePath)
  downloadFile(BridgeReleaseBaseUrl & "/SHA256SUMS.txt", sumsPath)
  let expected = expectedChecksum(readFile(sumsPath), asset)
  let actual = sha256HexFile(archivePath)
  if actual != expected:
    raise bridgeError("checksum mismatch for " & asset & ": expected " & expected & ", got " & actual)
  if log != nil: log("checksum verified; extracting to " & dir)
  let staging = tmp / "extract"
  extractTarGz(archivePath, staging)
  verifyManifest(staging)
  when not defined(windows):
    setFilePermissions(staging / "bin" / bridgeExeName(),
                       {fpUserExec, fpUserRead, fpUserWrite, fpGroupExec, fpGroupRead,
                        fpOthersExec, fpOthersRead})
  removeDir(dir)
  createDir(parentDir(dir))
  moveDir(staging, dir)
  if not fileExists(exe):
    raise bridgeError("bridge executable missing after extraction: " & exe)
  exe

proc locateBridge*(allowDownload = true, log: proc(msg: string) {.gcsafe.} = nil): string =
  ## Resolves the bridge executable per the module docs.
  let override = getEnv(BridgeBinEnv)
  if override.len > 0:
    if not fileExists(override):
      raise bridgeError(BridgeBinEnv & " points to a missing file: " & override)
    return override
  let cached = cachedBridgePath()
  if fileExists(cached):
    return cached
  if not allowDownload:
    raise bridgeError("cursor-sdk-bridge " & BridgeVersion & " not found at " & cached &
                      "; run `nimble fetchBridge` or set " & BridgeBinEnv)
  fetchBridge(log = log)

when isMainModule:
  let path = fetchBridge(force = "--force" in commandLineParams(),
                         log = proc(m: string) = stderr.writeLine(m))
  echo path
