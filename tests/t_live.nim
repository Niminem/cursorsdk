## Live end-to-end tests against Cursor's API. Skipped unless a key is
## available via `CURSOR_API_KEY` or a `.env` file in the repository root
## (`CURSOR_API_KEY=...`). These spend real requests.
##
## Set `CURSOR_TEST_MODEL` to override the model (default: `composer-2`,
## falling back to the first model from `ListModels`). Set
## `CURSOR_TEST_VERBOSE=1` to print every stream event.

import std/[unittest, asyncdispatch, json, options, strutils, os, sets]
import cursor

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

if apiKey.len == 0:
  echo "t_live: CURSOR_API_KEY not set; skipping live tests"
else:
  suite "live":
    var workspace = getTempDir() / "cursor-nim-live"
    createDir(workspace)
    writeFile(workspace / "README.md", "# Fixture\n\nThis directory exists for the cursor-nim live test.\n")

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
          modelId = "composer-2"
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

    test "custom tool round trip":
      proc run() {.async.} =
        let tools = newCallbackServer()
        var calls = 0
        tools.registerTool("get_secret_number",
          "Returns the secret number. Call this whenever asked for the secret number.",
          %*{"type": "object", "properties": {}},
          proc(args: JsonNode, ctx: ToolContext): Future[JsonNode] {.async.} =
            inc calls
            if verbose: stderr.writeLine("[tool] called with " & $args & " ctx=" & $ctx)
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
        echo "  tool calls: ", calls, " text: ", res.text.strip()
        check res.status == rlsFinished
        check calls >= 1
        check sawToolCall
        check "4242" in res.text
        await toolAgent.delete()
      waitFor run()

    test "cancel an in-flight run":
      proc run() {.async.} =
        let run = await agent.send(
          "Write a very long essay (at least 3000 words) about the history of compilers.")
        # Wait for the first event so the run id is known, then cancel.
        discard await run.next()
        check run.runId.len > 0
        await run.cancel()
        let res = await run.wait()
        echo "  status after cancel: ", res.status
        check res.status in {rlsCancelled, rlsFinished}
      waitFor run()

    test "prompt one-shot":
      proc run() {.async.} =
        let text = await client.prompt("Reply with exactly the word DONE and nothing else.", modelId)
        check "DONE" in text.toUpperAscii
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
        await agent.delete()
        expect RpcError:
          discard await client.getAgent(agent.id)
      waitFor run()

    test "shutdown":
      waitFor client.close()
      check client.bridge.hasExited
