# cursor

Cursor SDK Bridge client for the Nim programming language.

Drive [Cursor agents](https://cursor.com/docs/sdk) from Nim through
[`cursor-sdk-bridge`](https://github.com/cursor/sdk-bridge): a small local
process that embeds Cursor's TypeScript SDK and exposes it over the stable
`sdk.v1` Connect protocol. This package locates (or downloads) the bridge,
spawns it, handles the handshake and authentication, and wraps the full
agent surface in an idiomatic async Nim API. The bridge is invisible in the
happy path.

- Pure standard library: no dependencies.
- `std/asyncdispatch` throughout.
- JSON on the wire; the two binary-protobuf corners (`SdkErrorDetails`,
  callback requests) are handled by a tiny built-in codec.
- Local agents. Cloud agents are out of scope for this package, but the
  low-level client is runtime-agnostic and pull requests are welcome.

## Install

```sh
nimble install cursor
```

Requires Nim 2.2.10 or newer. A Cursor API key is required to run agents:
create one at [cursor.com/dashboard/api](https://cursor.com/dashboard/api)
and export it as `CURSOR_API_KEY`.

The bridge binary is downloaded on first use (see
[The bridge binary](#the-bridge-binary)). To prefetch it, for example in CI
or a Docker build:

```sh
nimble fetchBridge
```

## Quick start

```nim
import std/asyncdispatch
import cursor

proc main() {.async.} =
  let client = newClient()                      # key from CURSOR_API_KEY, cwd as workspace
  defer: waitFor client.close()                 # Shutdown RPC → wait → kill; never leaks
  let agent = await client.createAgent("composer-2")
  let run = await agent.send("Summarize this repository.")
  while true:                                   # stream assistant text as it arrives
    let chunk = await run.nextText()
    if chunk.isNone: break
    stdout.write chunk.get
  let res = await run.wait()
  echo "\nstatus: ", res.status, " in ", res.durationMs, " ms"
  await agent.close()

waitFor main()
```

One-shot:

```nim
let text = await client.prompt("Reply with one word: ready?", model = "composer-2")
```

## API overview

| Type | Role |
| --- | --- |
| `Client` | Owns the bridge process and transport. Typed low-level RPCs for every `SdkAgentService`, `SdkCursorService`, and `SdkBridgeControlService` method, plus `call`/`stream` escape hatches for raw JSON. |
| `Agent` | `createAgent` / `resumeAgent`; `send` → `Run`; `info`, `close`, `archive`, `unarchive`, `delete`, `runs`, `messages`, `usage`. |
| `Run` | `next` (events), `nextText` (assistant text), `wait` (terminal `RunResult`), `observe` (re-attach after a dropped stream), `cancel`, `raiseIfFailed`. |
| `CallbackServer` | Loopback server for custom tools (`registerTool`) and custom stores (`setStoreHandler`). |
| `ClientOptions` | API key, workspace, bridge path/URL/token, state root, default store, verbose logging, startup/RPC timeouts. |

### Client options

```nim
var o = initClientOptions()
o.apiKey = "key_..."                 # default: CURSOR_API_KEY
o.workspace = "/path/to/repo"        # default: current directory
o.verbose = true                     # bridge logs every RPC to stderr
o.onBridgeOutput = proc(line: string) {.gcsafe.} = stderr.writeLine line
let client = newClient(o)
```

Attach to a bridge you already run (tests, hosts that manage the process):

```nim
o.bridgeUrl = "http://127.0.0.1:49152"
o.bridgeToken = readFile("/path/to/auth-token").strip
```

### Agent options

```nim
var opts = AgentOptions(model: model("composer-2"), name: "reviewer", mode: amoPlan)
opts.local.cwd = "/path/to/repo"
opts.local.sandbox = some(true)
opts.tools = some(@["read_file", "grep"])        # allow-list of built-in tools
opts.mcpServers["fs"] = McpServerConfig(kind: mskStdio, command: "npx", args: @["-y", "@modelcontextprotocol/server-filesystem", "."])
let agent = await client.createAgent(opts)
```

`AgentOptions.extra` and `SendOptions.extra` merge raw JSON into the request
for fields this package does not model.

The bridge keeps one local agent store per working directory, keyed by the
exact path string. This package canonicalises paths (`normalizeWorkspace`)
and defaults the `cwd` of management calls (`getAgent`, `getRun`,
`listRuns`, `archiveAgent`, ...) to the client workspace; `Agent` methods
pass the agent's own `cwd`. When you look up an agent created with a
different directory, pass that directory as `cwd`.

### Streaming

`Run.next` yields `RunEvent`s and skips keepalives and unknown envelope
cases. Dispatch on `kind` and, for `rekMessage`, on `msgType` (`status`,
`thinking`, `assistant`, `tool_call`, `usage`, ...). Payloads are
`JsonNode`s matching the public SDK's message shapes; accessors cover the
common ones: `assistantText`, `thinkingText`, `toolCallName`,
`toolCallStatus`, `tokenUsage`, `statusMessage`, `runId`, `agentId`.

```nim
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
```

Opt into raw deltas or completed steps with
`SendOptions(enableDeltas: true)` / `SendOptions(enableSteps: true)`.

Dropping a stream never cancels the run. `run.wait()` falls back to
`WaitLiveRun` if the connection drops, and `client.observeRun(runId)`
replays the durable event log.

### Errors

Everything derives from `CursorError`:

- `BridgeError`: the process could not be located, downloaded, started, or
  did not become ready. `stderr` holds captured bridge output.
- `TransportError`: socket, HTTP, or framing failures, and RPC timeouts.
- `RpcError` and subclasses, mapped from the Connect code and the stable
  `sdk.v1.SdkErrorCode`: `AuthError`, `PermissionError`, `NotFoundError`,
  `ValidationError`, `RateLimitError`, `AgentBusyError`,
  `AgentArchivedError`, `RunNotCancellableError`, `UpstreamError`,
  `InternalError`, `UnavailableError`, `CancelledError`. Inspect
  `details`, `requestId`, `retryAfter`, and `rateLimit`.
- `RunError`: raised by `prompt` and `Run.raiseIfFailed` when a run ends in
  `ERROR`, `CANCELLED`, or `EXPIRED`. A failed run is not an RPC failure;
  `Run.wait` returns the result and `RunResult.status` tells you what happened.

```nim
try:
  discard await client.createAgent("not-a-model")
except ValidationError as e:
  echo e.sdkErrorCode, " ", e.requestId
except RateLimitError as e:
  echo "retry after ", e.retryAfter
```

### Custom tools

```nim
let tools = newCallbackServer()
tools.registerTool("get_weather", "Current weather for a city",
  %*{"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]},
  proc(args: JsonNode, ctx: ToolContext): Future[JsonNode] {.async.} =
    result = %*{"city": args["city"].getStr, "tempC": 21})

let client = newClient()
await client.attachToolCallbacks(tools)        # starts the server, registers it with the bridge
var opts = AgentOptions(model: model("composer-2"))
opts.useTools(tools)                           # declares the tools on the agent
let agent = await client.createAgent(opts)
```

Tool results must be JSON objects; scalars are wrapped as `{"value": ...}`.
`textResult("...")` builds an MCP-style text content envelope.

### Custom stores

Set `ClientOptions.localStore = some(LocalAgentStoreConfig(kind: "custom"))`
together with `storeCallbackUrl`/`storeCallbackToken` pointing at a started
`CallbackServer` with a `setStoreHandler`. The handler receives
(`agents|runs|runEvents|checkpoints`, `get|create|update|delete|list|append`,
input) and returns the bare record object, or `nil` for a null result. See
[`docs/services.md`](vendor/sdk-bridge/docs/services.md) for the structural rules.

## The bridge binary

Resolution order:

1. `CURSOR_SDK_BRIDGE_BIN`: explicit path to a bridge executable.
2. The user cache: `getCacheDir("cursor-nim")/<version>/bin/cursor-sdk-bridge`.
3. Download `cursor-sdk-bridge-standalone-<os>-<arch>.tar.gz` for the pinned
   release from GitHub, verify it against the release's `SHA256SUMS.txt`,
   check `manifest.json`, and extract into the cache.

Downloads shell out to `curl` and extraction to `tar`; both ship with macOS,
Windows 10+, and Linux. Compile with `-d:ssl` to download with
`std/httpclient` instead. Set `ClientOptions.allowDownload = false` to fail
instead of downloading.

The bridge binds `127.0.0.1` on an ephemeral port. Its stderr is drained by a
dedicated thread (so a full pipe never blocks it) and forwarded to
`ClientOptions.onBridgeOutput`. The discovery line is never forwarded or
logged. On `client.close()` the bridge receives a `Shutdown` RPC, is given
5 seconds, then killed; an exit handler kills any bridge still alive when
the host process ends.

## Versioning

This package pins one release of `cursor/sdk-bridge`, vendored as the
`vendor/sdk-bridge` submodule and recorded in `src/cursor/version.nim`. The
first three components of the nimble version equal the bridge release
(`1.0.35`). Fixes to this package that do not change the bridge add a fourth
component (`1.0.35.1`). `sdk.v1` evolves additively, so a client built
against one tag keeps working with newer bridges.

## Testing

```sh
nimble test
```

- `tests/t_codecs.nim`: pure unit tests (no network).
- `tests/t_bridge.nim`: spawns a real bridge, exercises handshake, auth,
  streaming errors, shutdown, and the callback server. Needs the bridge
  binary (downloaded if absent) but no API key.
- `tests/t_live.nim`: full turns against Cursor's API, including a custom
  tool round trip. Runs only when `CURSOR_API_KEY` is set (or present in a
  gitignored `.env`). Spends real requests.

## License

MIT
