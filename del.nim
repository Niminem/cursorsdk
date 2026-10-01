import std/[asyncdispatch, strutils]
import src/cursorsdk

proc main() {.async.} =
  let client = newClient(readFile(".env").split("=")[1].strip())                      # key from CURSOR_API_KEY, cwd as workspace
  defer: waitFor client.close()                 # Shutdown RPC → wait → kill; never leaks
  let agent = await client.createAgent("composer-2.5")
  let run = await agent.send("Summarize this repository.")
  while true:                                   # stream assistant text as it arrives
    let chunk = await run.nextText()
    if chunk.isNone: break
    stdout.write chunk.get
  let res = await run.wait()
  echo "\nstatus: ", res.status, " in ", res.durationMs, " ms"
  await agent.close()

waitFor main()