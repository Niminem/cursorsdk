## Cursor SDK Bridge client for Nim.
##
## Drives Cursor agents through the `cursor-sdk-bridge` process over the
## `sdk.v1` Connect protocol. The bridge is located (or downloaded),
## spawned, and shut down for you.
##
## ```nim
## import std/asyncdispatch
## import cursorsdk
##
## proc main() {.async.} =
##   let client = newClient()                 # CURSOR_API_KEY from the environment
##   defer: waitFor client.close()
##   let agent = await client.createAgent("composer-2.5")
##   let run = await agent.send("Summarize this repository.")
##   while true:
##     let chunk = await run.nextText()
##     if chunk.isNone: break
##     stdout.write chunk.get
##   let res = await run.wait()
##   echo "\nstatus: ", res.status, "  text: ", res.text
##   await agent.close()
##
## waitFor main()
## ```
##
## Modules:
## - `cursorsdk/client`   `Client`, `ClientOptions`, typed low-level RPCs
## - `cursorsdk/agent`    `Agent` handle and `prompt`
## - `cursorsdk/run`      `Run` handle: `next`, `nextText`, `wait`, `observe`, `cancel`
## - `cursorsdk/types`    request/response types mirroring `sdk.v1`
## - `cursorsdk/errors`   `CursorError` hierarchy
## - `cursorsdk/callbacks` custom tool and store callback servers
## - `cursorsdk/bridge`   bridge process management (advanced)

import cursorsdk/[client, agent, run, types, errors, callbacks, version]
export client, agent, run, types, errors, callbacks, version
