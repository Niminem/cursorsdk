## Live end-to-end tests against Cursor's API. Skipped unless a key is
## available via `CURSOR_API_KEY` or a `.env` file in the repository root
## (`CURSOR_API_KEY=...`). These spend real requests.
##
## Set `CURSOR_TEST_MODEL` to override the model (default: `composer-2.5`,
## falling back to the first model from `ListModels`). Set
## `CURSOR_TEST_VERBOSE=1` to print every stream event.

import std/[unittest, asyncdispatch, json, options, strutils, os, sets, tables,
            monotimes, times]
import cursorsdk

proc loadApiKey(): string =
  result = getEnv("CURSOR_API_KEY")
  if result.len > 0: return
  let envFile = currentSourcePath().parentDir.parentDir / ".env"
  if fileExists(envFile):
    for line in envFile.lines:
      let l = line.strip()
      if l.startsWith("CURSOR_API_KEY="):
        result = l["CURSOR_API_KEY=".len .. ^1].strip(chars = {' ', '"', '\''})
        return

let apiKey = loadApiKey()
let verbose = getEnv("CURSOR_TEST_VERBOSE").len > 0

# cursor-sdk-bridge 1.0.35 keeps each agent's SQLite store (store.db + WAL)
# open for the life of the process, and DeleteAgent removes the agent's
# directory without closing it first. POSIX allows unlinking open files, so
# macOS/Linux are fine; Windows refuses with EBUSY for any agent that has
# run a turn, and the bridge can later crash (Bun internal assertion). Skip
# those deletes on Windows until upstream closes the store before rm.
const deleteAfterRunWorks = not defined(windows)

if apiKey.len == 0:
  echo "t_live: CURSOR_API_KEY not set; skipping live tests"
else:
  suite "live":
    var workspace = getTempDir() / "cursorsdk-live"
    createDir(workspace)
    writeFile(workspace / "README.md", "# Fixture\n\nThis directory exists for the cursorsdk live test.\n")

    var o = initClientOptions()
    o.apiKey = apiKey
    o.workspace = workspace
    o.verbose = verbose
    if verbose:
      o.onBridgeOutput = proc(line: string) {.gcsafe.} = stderr.writeLine("[bridge] " & line)
    let client = newClient(o)
    var modelId = getEnv("CURSOR_TEST_MODEL")

    test "catalog: me and models":
      proc run() {.async.} =
        let me = await client.me()
        check me.apiKeyName.len > 0 or me.userEmail.len > 0
        let models = await client.listModels()
        check models.len > 0
        if modelId.len == 0:
          modelId = "composer-2.5"
          var found = false
          for m in models:
            if m.id == modelId: found = true
          if not found: modelId = models[0].id
        echo "  using model: ", modelId
      waitFor run()

    var agent: Agent
    var runId: string

    test "create agent, send, stream, wait":
      proc run() {.async.} =
        agent = await client.createAgent(modelId)
        check agent.id.len > 0
        let run = await agent.send("Reply with exactly the word PONG and nothing else.")
        var types = initHashSet[string]()
        var text = ""
        var sawResult, sawDone = false
        while true:
          let ev = await run.next()
          if ev.isNone: break
          let e = ev.get
          if verbose: stderr.writeLine("[event] " & $e.raw)
          case e.kind
          of rekMessage:
            types.incl e.msgType
            text.add e.assistantText
          of rekResult: sawResult = true
          of rekDone: sawDone = true
          else: discard
        check sawResult
        check sawDone
        check run.finished
        check run.runId.len > 0
        runId = run.runId
        let res = await run.wait()
        check res.status == rlsFinished
        check not run.failed
        echo "  message types: ", types
        echo "  streamed text: ", text.strip()
        echo "  final text:    ", res.text.strip()
        check "PONG" in res.text.toUpperAscii or "PONG" in text.toUpperAscii
      waitFor run()

    test "run management and observe replay":
      proc run() {.async.} =
        let snap = await client.getRun(runId, agent.id)
        check snap.status == rlsFinished
        let runs = await agent.runs()
        var found = false
        for r in runs.items:
          if r.runId == runId: found = true
        check found
        let msgs = await agent.messages()
        check msgs.len > 0
        let obs = await client.observeRun(runId, agentId = agent.id)
        var sawResult = false
        var lastOffset = ""
        while true:
          let ev = await obs.next()
          if ev.isNone: break
          if ev.get.offset.len > 0: lastOffset = ev.get.offset
          if ev.get.kind == rekResult: sawResult = true
        check sawResult
        check lastOffset.len > 0
        let res = await obs.wait()
        check res.status == rlsFinished
      waitFor run()

    test "nextText and wait fallback":
      proc run() {.async.} =
        let run = await agent.send("Reply with exactly the word HELLO and nothing else.")
        var chunks: seq[string]
        while true:
          let t = await run.nextText()
          if t.isNone: break
          chunks.add t.get
        check chunks.len > 0
        check "HELLO" in chunks.join("").toUpperAscii
        let res = await run.wait()
        check res.status == rlsFinished
        check res.runId.len > 0
      waitFor run()

    test "custom tool round trip (with a >15 s tool pause)":
      proc run() {.async.} =
        let tools = newCallbackServer()
        var calls = 0
        tools.registerTool("get_secret_number",
          "Returns the secret number. Call this whenever asked for the secret number.",
          %*{"type": "object", "properties": {}},
          proc(args: JsonNode, ctx: ToolContext): Future[JsonNode] {.async.} =
            inc calls
            if verbose: stderr.writeLine("[tool] called with " & $args & " ctx=" & $ctx)
            # The bridge emits keepalive frames after ~15 s of idle time;
            # holding the tool past that verifies they are skipped and the
            # live stream survives the pause.
            await sleepAsync(16_000)
            result = %*{"value": 4242})
        await client.attachToolCallbacks(tools)
        defer: tools.stop()
        var opts = AgentOptions(model: model(modelId))
        opts.useTools(tools)
        let toolAgent = await client.createAgent(opts)
        let run = await toolAgent.send(
          "Call the get_secret_number tool, then reply with only the number it returned.")
        var sawToolCall = false
        while true:
          let ev = await run.next()
          if ev.isNone: break
          if verbose: stderr.writeLine("[event] " & $ev.get.raw)
          if ev.get.kind == rekMessage and ev.get.msgType == "tool_call": sawToolCall = true
        let res = await run.wait()
        echo "  tool calls: ", calls, " keepalives: ", run.keepalives, " text: ", res.text.strip()
        check res.status == rlsFinished
        check calls >= 1
        check sawToolCall
        check run.keepalives >= 1      # the pause really crossed the keepalive interval
        check "4242" in res.text
        if deleteAfterRunWorks:
          await toolAgent.delete()
        else:
          echo "  skipped delete (bridge EBUSY bug on Windows)"
      waitFor run()

    test "custom store round trip":
      # A second bridge whose local agent store is this process: an
      # in-memory store following the structural rules in
      # vendor/sdk-bridge/docs/services.md (wrapped inputs, bare outputs,
      # `{found, data}` for checkpoint reads, base64 blobs).
      proc run() {.async.} =
        var records = initTable[string, JsonNode]()   # "<substore>/<id>" -> record
        var blobs = initTable[string, string]()
        var events: seq[JsonNode]
        var seen = initHashSet[string]()
        let store = newCallbackServer()
        store.setStoreHandler(proc(substore, meth: string, input: JsonNode): Future[JsonNode] {.async.} =
          seen.incl substore & "." & meth
          case substore
          of "agents", "runs":
            let idKey = if substore == "agents": "agentId" else: "runId"
            let recKey = if substore == "agents": "agent" else: "run"
            case meth
            of "create", "update":
              let rec = input[recKey]
              records[substore & "/" & rec[idKey].getStr] = rec
              return rec
            of "get":
              return records.getOrDefault(substore & "/" & input[idKey].getStr)
            of "delete":
              records.del(substore & "/" & input[idKey].getStr)
              return nil
            of "list":
              var items = newJArray()
              for k, r in records:
                if k.startsWith(substore & "/"): items.add r
              return %*{"items": items}
            else: discard
          of "runEvents":
            if meth == "append":
              events.add input
              return %*{"offset": $events.len}
            elif meth == "list":
              var items = newJArray()
              for e in events:
                if e["runId"] == input["runId"]: items.add e
              return %*{"events": items}
          of "checkpoints":
            let k = input["agentId"].getStr & "/" & input["blobId"].getStr
            case meth
            of "create", "update":
              blobs[k] = input["data"].getStr
              return %*{"ok": true}
            of "get":
              return if k in blobs: %*{"found": true, "data": blobs[k]} else: %*{"found": false}
            of "delete":
              blobs.del(k)
              return nil
            else: discard
          else: discard
          raise newException(ValueError, "unhandled store call " & substore & "." & meth))
        await store.start()
        defer: store.stop()
        var so = initClientOptions()
        so.apiKey = apiKey
        so.workspace = workspace / "custom-store"
        createDir(so.workspace)
        so.localStore = some(LocalAgentStoreConfig(kind: "custom"))
        so.storeCallbackUrl = store.url
        so.storeCallbackToken = store.authToken
        let storeClient = newClient(so)
        try:
          let a = await storeClient.createAgent(modelId)
          check "agents.create" in seen
          let res = await (await a.send("Reply with exactly the word PONG and nothing else.")).wait()
          echo "  store calls: ", seen
          check res.status == rlsFinished
          check "runs.create" in seen
          check "runEvents.append" in seen
          check "checkpoints.create" in seen
          check "checkpoints.get" in seen
          let info = await a.info()               # served from our store
          check info.agentId == a.id
          check (await storeClient.listAgents()).items.len == 1
          await a.close()
        finally:
          await storeClient.close()
      waitFor run()

    test "cancel an in-flight run":
      proc run() {.async.} =
        let run = await agent.send(
          "Write a very long essay (at least 3000 words) about the history of compilers.")

        # Bridge 1.0.35 crashes (Bun assertion, exit 3) if CancelRun lands
        # early in a run's life. Only cancel once real text has streamed
        # for >= 1 s; a bare `thinking` start frame arrives too soon.
        let t0 = getMonoTime()
        while true:
          let ev = await run.next()
          if ev.isNone: break
          let e = ev.get
          let gotText = e.assistantText.len > 0 or e.thinkingText.len > 0
          if gotText and getMonoTime() - t0 >= initDuration(seconds = 1): break
        check run.runId.len > 0
        await run.cancel()
        let res = await run.wait()
        echo "  status after cancel: ", res.status
        check res.status in {rlsCancelled, rlsFinished}
      waitFor run()

    test "prompt one-shot":
      proc run() {.async.} =
        let res = await client.prompt("Reply with exactly the word DONE and nothing else.", modelId)
        check res.status == rlsFinished
        check res.runId.len > 0
        check "DONE" in res.text.toUpperAscii
      waitFor run()

    test "delete(force) on an agent that never ran a turn":
      # On this bridge release CreateAgent leaves a non-terminal run attached
      # to a fresh agent, so a plain delete fails (see README, "Notes on this
      # bridge release"). `force` cancels it first. If upstream changes this,
      # the plain delete may start succeeding; the forced path must keep
      # working either way.
      proc run() {.async.} =
        let fresh = await client.createAgent(modelId)
        try:
          await fresh.delete()
          echo "  plain delete succeeded (bridge no longer pre-creates a run?)"
        except RpcError as e:
          echo "  plain delete failed as documented: ", e.msg.splitLines[0]
          await fresh.delete(force = true)
        expect RpcError:
          discard await client.getAgent(fresh.id)
      waitFor run()

    test "agent lifecycle: info, close, archive, delete":
      proc run() {.async.} =
        let info = await agent.info()
        check info.agentId == agent.id
        check info.runtime == rtLocal
        await agent.close()
        await agent.archive()
        let page = await client.listAgents(ListAgentsOptions(includeArchived: some(true)))
        var found = false
        for a in page.items:
          if a.agentId == agent.id: found = true
        check found
        if deleteAfterRunWorks:
          await agent.delete()
          expect RpcError:
            discard await client.getAgent(agent.id)
        else:
          echo "  skipped delete (bridge EBUSY bug on Windows)"
      waitFor run()

    test "shutdown":
      # A bridge that died mid-suite explains any "connection refused"
      # failures above; print its last output and fail here too.
      let diedEarly = client.bridge != nil and client.bridge.hasExited
      if diedEarly:
        echo "  !! bridge exited early with code ", client.bridge.exitCode
        echo "  --- bridge output tail ---"
        echo client.bridge.outputTailText()
        echo "  --------------------------"
      waitFor client.close()
      check not diedEarly
      check client.bridge.hasExited
