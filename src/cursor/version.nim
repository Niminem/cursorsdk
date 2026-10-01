## Pinned bridge release and protocol identifiers.
##
## `BridgeVersion` must match the `vendor/sdk-bridge` submodule tag and the
## first three components of the nimble package version.

const
  BridgeVersion* = "1.0.35"
    ## Release tag (without the leading `v`) of cursor/sdk-bridge this
    ## package was built and verified against.
  BridgeReleaseTag* = "v" & BridgeVersion
  ProtocolVersion* = "sdk.v1"
    ## Protobuf package / protocol contract implemented by the bridge.
  BridgeRepo* = "cursor/sdk-bridge"
  BridgeReleaseBaseUrl* = "https://github.com/" & BridgeRepo & "/releases/download/" & BridgeReleaseTag
  ClientLanguage* = "nim"
    ## Reported to the bridge via `CURSOR_SDK_CLIENT_LANGUAGE` for traffic
    ## attribution.
