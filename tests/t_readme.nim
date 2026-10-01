## Compile check for the code fragments in README.md. Nothing here runs:
## each fragment is copied verbatim into a proc that is never called, with
## the free variables the surrounding prose implies (`client`, `agent`,
## `run`, `o`, ...) declared just above it. If a README edit breaks a
## fragment, this file stops compiling.
##
## Keep the fragments in sync with the README by hand; the README section
## is named above each one. The only import the README promises beyond
## `cursorsdk` is `std/asyncdispatch` (`std/strutils` is noted inline where
## the attach fragment uses `strip`).

import std/[unittest, asyncdispatch, strutils]
import cursorsdk

{.push used.}

# --- Quick start (the full program, minus its final `waitFor main()`) ------

proc quickStart() =
  proc main() {.async.} =
    let client = newClient()                      # key from CURSOR_API_KEY, cwd as workspace
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
  # README: `waitFor main()` (not run here)

# --- Quick start: one-shot --------------------------------------------------

proc oneShot(client: Client) {.async.} =
  let res = await client.prompt("Reply with one word: ready?", model = "composer-2.5")
  echo res.text, " (", res.durationMs, " ms)"

# --- Client options -----------------------------------------------------------

proc clientOptions() =
  var o = initClientOptions()
  o.apiKey = "key_..."                 # default: CURSOR_API_KEY
  o.workspace = "/path/to/repo"        # default: current directory
  o.verbose = true                     # bridge logs every RPC (name, outcome, duration) to stderr
  o.onBridgeOutput = proc(line: string) {.gcsafe.} = stderr.writeLine line
  o.env = @[("CURSOR_SDK_BRIDGE_PORT", "49152")]   # extra bridge environment
  o.bridgeArgs = @["--max-concurrent-agents", "4"] # extra bridge flags
  let client = newClient(o)
  discard client

proc attachOptions(o: var ClientOptions) =
  o.bridgeUrl = "http://127.0.0.1:49152"
  o.bridgeToken = readFile("/path/to/auth-token").strip   # strip: std/strutils

# --- Bridge resilience --------------------------------------------------------

proc resilienceOptions(o: var ClientOptions) =
  o.autoRelaunch = true                # default
  o.onBridgeRelaunch = proc(exitCode: int, outputTail: string) {.gcsafe.} =
    stderr.writeLine "bridge exited (", exitCode, "), relaunching\n", outputTail
  # later: client.relaunches  # how many times it has happened

# --- Agent options ------------------------------------------------------------

proc agentOptions(client: Client) {.async.} =
  var opts = AgentOptions(model: model("composer-2.5"), name: "reviewer", mode: amoPlan)
  opts.local.cwd = "/path/to/repo"
  opts.local.sandbox = some(true)
  opts.tools = some(@["read", "grep", "glob", "ls"]) # allow-list; read-only agent
  opts.mcpServers["fs"] = McpServerConfig(kind: mskStdio, command: "npx",
    args: @["-y", "@modelcontextprotocol/server-filesystem", "."])
  let agent = await client.createAgent(opts)
  discard agent

# --- Conversations and resuming -------------------------------------------------

proc resuming(client: Client, savedId: string) {.async.} =
  let agent = await client.resumeAgent(savedId)
  let run = await agent.send("Also update the changelog.")
  discard run

# --- Sending messages -------------------------------------------------------------

proc sendingImages(agent: Agent, base64Png: string) {.async.} =
  let run = await agent.send(UserMessage(text: "What is in this screenshot?",
    images: @[SdkImage(data: base64Png, mimeType: "image/png")]))
  discard run

# --- Streaming ----------------------------------------------------------------------

proc streaming(run: Run) {.async.} =
  while true:
    let ev = await run.next()
    if ev.isNone: break
    let e = ev.get
    case e.kind
    of rekMessage:
      case e.msgType
      of "assistant": stdout.write e.assistantText
      of "tool_call": echo "\n[", e.toolCallName, " ", e.toolCallStatus, "]"
      of "usage": echo "\ntokens: ", e.tokenUsage.get.totalTokens
      else: discard
    of rekResult: echo "\n", e.result.status
    else: discard

# --- Errors -------------------------------------------------------------------------

proc errors(client: Client) {.async.} =
  try:
    discard await client.createAgent("not-a-model")
  except ValidationError as e:
    echo e.sdkErrorCode, " ", e.requestId
  except RateLimitError as e:
    echo "retry after ", e.retryAfter

# --- Custom tools -------------------------------------------------------------------

proc customTools() {.async.} =
  let tools = newCallbackServer()
  tools.registerTool("get_weather", "Current weather for a city",
    %*{"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]},
    proc(args: JsonNode, ctx: ToolContext): Future[JsonNode] {.async.} =
      result = %*{"city": args["city"].getStr, "tempC": 21})

  let client = newClient()
  await client.attachToolCallbacks(tools)        # starts the server, registers it with the bridge
  var opts = AgentOptions(model: model("composer-2.5"))
  opts.useTools(tools)                           # declares the tools on the agent
  let agent = await client.createAgent(opts)
  discard agent

# --- Custom stores (the README elides the handler body as `...`) ---------------------

proc customStores() {.async.} =
  let store = newCallbackServer()
  store.setStoreHandler(proc(substore, meth: string, input: JsonNode): Future[JsonNode] {.async.} =
    result = nil)                                # README: `...`
  await store.start()
  var o = initClientOptions()
  o.localStore = some(LocalAgentStoreConfig(kind: "custom"))
  o.storeCallbackUrl = store.url
  o.storeCallbackToken = store.authToken
  let client = newClient(o)
  discard client

{.pop.}

suite "readme":
  test "every README fragment compiles":
    check true
