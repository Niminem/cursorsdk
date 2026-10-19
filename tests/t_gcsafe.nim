## Compile check that the public async API stays `gcsafe`, so callers can
## use it from `{.gcsafe.}` code (threads, `--threads:on` callbacks, async
## procs annotated `gcsafe`). Nothing here runs; if a change makes one of
## these calls non-gcsafe, this file stops compiling.

import std/[unittest, asyncdispatch]
import cursorsdk

{.push used.}

proc threadSafetyCheck() {.async, gcsafe.} =
  let client = newClient()
  let agent = await client.createAgent("composer-2.5")
  discard await agent.send("x")
  discard await client.prompt("x", model = "composer-2.5")

proc clientCheck(client: Client) {.async, gcsafe.} =
  await client.start()
  await client.restartBridge()
  discard await client.ping()
  discard await client.bridgeVersion()
  discard await client.me()
  discard await client.listModels()
  discard await client.listAgents()
  discard await client.getRun("run")
  await client.cancelRun("run")
  discard await client.observeRun("run")
  await client.close()

proc agentCheck(client: Client) {.async, gcsafe.} =
  let agent = await client.resumeAgent("agent")
  discard await agent.info()
  discard await agent.runs()
  discard await agent.messages()
  discard await agent.usage()
  await agent.cancelNonTerminalRuns()
  await agent.archive()
  await agent.unarchive()
  await agent.reload()
  await agent.close()
  await agent.delete(force = true)

proc runCheck(run: Run) {.async, gcsafe.} =
  discard await run.next()
  discard await run.nextText()
  discard await run.observe()
  discard await run.wait()
  await run.cancel()

proc callbacksCheck(client: Client) {.async, gcsafe.} =
  let server = newCallbackServer()
  await server.start()
  await client.attachToolCallbacks(server)
  server.stop()

{.pop.}

suite "gcsafe":
  test "public async API compiles under gcsafe":
    check true
