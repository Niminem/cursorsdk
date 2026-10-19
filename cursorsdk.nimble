# Package
#
# The first three version components track the pinned cursor/sdk-bridge
# release (see src/cursorsdk/version.nim). A fourth component is reserved for
# fixes to this package that do not change the bridge version.
version       = "1.0.35.1"
author        = "Leon Lysak (Niminem)"
description   = "Cursor SDK Bridge client for the Nim programming language"
license       = "MIT"
srcDir        = "src"

# Dependencies
requires "nim >= 2.2.10"

# Tasks
task fetchBridge, "Download and verify the pinned cursor-sdk-bridge binary into the user cache":
  exec "nim r --hints:off src/cursorsdk/bridge_fetch.nim"
