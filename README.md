# cursorsdk

Cursor SDK Bridge client for the Nim programming language.

Drive [Cursor agents](https://cursor.com/docs/sdk) from Nim through
`[cursor-sdk-bridge](https://github.com/cursor/sdk-bridge)`: a small local
process that embeds Cursor's TypeScript SDK and exposes it over the stable
`sdk.v1` Connect protocol. This package locates (or downloads) the bridge,
spawns it, handles the handshake and authentication, and wraps the agent
surface in an idiomatic async Nim API. The bridge is invisible in the happy
path.

- Pure standard library: no dependencies.
- JSON on the wire; the two binary-protobuf corners (`SdkErrorDetails`,
callback requests) are handled by a tiny built-in codec.
- Local agents. Cloud agents are not modelled (see
[Scope](#scope-and-support)); pull requests are welcome.

"Local" means the agent loop and file access run on your machine, in the
directory you point it at. Inference always goes through Cursor's hosted
models, and the same `CURSOR_API_KEY` is used either way. The public API is
meant to read like a Nim translation of the
[TypeScript](https://cursor.com/docs/sdk/typescript) and
[Python](https://cursor.com/docs/sdk/python) SDKs; their guides explain the
agent model in more depth than this README does.

## Install

Not yet in the Nimble package index. Until it is, install from source:

```sh
git clone --recursive https://github.com/Niminem/cursorsdk   # --recursive pulls the vendored sdk-bridge protocol docs
cd cursorsdk
nimble install
```

Once published: `nimble install cursorsdk`.

Requires Nim 2.2.10 or newer. A Cursor API key is required to run agents:
create a user API key under API Keys in the
[Cursor Dashboard](https://cursor.com/dashboard) (or a service account key
under Team settings) and export it as `CURSOR_API_KEY`. Team Admin API keys
are not supported by the SDK.

Prebuilt bridge binaries exist for macOS and Linux (x64 and arm64) and
Windows (x64 only; on Windows ARM, point `CURSOR_SDK_BRIDGE_BIN` at a bridge
you built or obtained yourself). The binary is downloaded on first use (see
[The bridge binary](#the-bridge-binary)). To prefetch it, for example in CI
or a Docker build:

```sh
nimble fetchBridge
```

This package has been verified on macOS (x64) and Windows. Linux is untested.

## Quick start

```nim
import std/asyncdispatch
import cursorsdk

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

waitFor main()
```

One-shot (create → send → wait → close; returns the terminal `RunResult` and
raises `RunError` if the run fails):

```nim
let res = await client.prompt("Reply with one word: ready?", model = "composer-2.5")
echo res.text, " (", res.durationMs, " ms)"
```

Two things to know before running anything larger:

- **Tool calls are not gated.** A local agent reads, writes, and runs shell
commands in its working directory without asking; there is no
human-in-the-loop prompt in headless runs. Restrict it with
`opts.tools` / `opts.disallowedTools`, `opts.local.sandbox = some(true)`,
or `opts.local.autoReview = some(true)` (see [Agent options](#agent-options)).
- **Discover model ids; do not hard-code them.** `await client.listModels()`
returns the ids, parameters, and preset variants available to your account.
`createAgent` rejects unknown ids with a `ValidationError` listing valid ones.



## API overview


| Type             | Role                                                                                                                                                                                                 |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Client`         | Owns the bridge process and transport. Typed low-level RPCs for every `SdkAgentService`, `SdkCursorService`, and `SdkBridgeControlService` method, plus `call`/`stream` escape hatches for raw JSON. |
| `Agent`          | `createAgent` / `resumeAgent`; `send` → `Run`; `id`, `model`, `cwd`; `info`, `reload`, `close`, `archive`, `unarchive`, `delete(force)`, `runs`, `messages`, `usage`.                                |
| `Run`            | `next` (events), `nextText` (assistant text), `wait` (terminal `RunResult`), `text`, `failed`, `raiseIfFailed`, `observe` (re-attach after a dropped stream), `cancel`, `close`, `keepalives`.       |
| `CallbackServer` | Loopback server for custom tools (`registerTool`) and custom stores (`setStoreHandler`).                                                                                                             |
| `ClientOptions`  | API key, workspace, bridge path/URL/token, state root, default store, callback endpoints, verbose logging, startup/RPC timeouts, `allowDownload`.                                                    |


Mapping to first-party names where they differ: `Agent.create` →
`client.createAgent`, `Agent.resume` → `client.resumeAgent`, `run.stream()`
→ `run.next()` in a loop, `run.iter_text()` → `run.nextText()`,
`Cursor.me()` / `Cursor.models.list()` / `Cursor.repositories.list()` →
`client.me()` / `client.listModels()` / `client.listRepositories()`,
`agent.agentId` → `agent.id`, `RunResult.result` → `RunResult.text`,
`Agent.prompt()` → `client.prompt` (same `RunResult` return; ours also raises
`RunError` when the run does not finish).

### Client options

```nim
var o = initClientOptions()
o.apiKey = "key_..."                 # default: CURSOR_API_KEY
o.workspace = "/path/to/repo"        # default: current directory
o.verbose = true                     # bridge logs every RPC (name, outcome, duration) to stderr
o.onBridgeOutput = proc(line: string) {.gcsafe.} = stderr.writeLine line
let client = newClient(o)
```

Attach to a bridge you already run (tests, hosts that manage the process):

```nim
o.bridgeUrl = "http://127.0.0.1:49152"
o.bridgeToken = readFile("/path/to/auth-token").strip
```

Attached bridges are not shut down by `client.close()`. Nothing is spawned
until the first RPC (or `await client.start()`); `client.ping()`,
`client.bridgeVersion()`, and `client.hasCapability("agent.usage")` report
bridge health, version, and feature flags.

### Agent options

```nim
var opts = AgentOptions(model: model("composer-2.5"), name: "reviewer", mode: amoPlan)
opts.local.cwd = "/path/to/repo"
opts.local.sandbox = some(true)
opts.tools = some(@["read", "grep", "glob", "ls"]) # allow-list; read-only agent
opts.mcpServers["fs"] = McpServerConfig(kind: mskStdio, command: "npx",
  args: @["-y", "@modelcontextprotocol/server-filesystem", "."])
let agent = await client.createAgent(opts)
```

`tools` and `disallowedTools` take the SDK's public tool vocabulary (`read`,
`edit`, `grep`, `glob`, `ls`, `shell`, `mcp`, `task`, `webSearch`, ...);
unknown names fail `createAgent` with a `ValidationError` that lists the
valid ones. `some(@[])` offers no built-in tools at all; deny wins when both
are set.

`AgentOptions.extra` and `SendOptions.extra` merge raw JSON into the request
for fields this package does not model. `apiKey` defaults to the client key
and `local.cwd` to the client workspace.

The bridge keeps one local agent store per working directory, keyed by the
exact path string. This package canonicalises paths (`normalizeWorkspace`)
and defaults the `cwd` of management calls (`getAgent`, `getRun`,
`listRuns`, `archiveAgent`, ...) to the client workspace; `Agent` methods
pass the agent's own `cwd`. When you look up an agent created with a
different directory, pass that directory as `cwd`.

### Conversations and resuming

An agent keeps its conversation across `send` calls: a follow-up `send` sees
everything the previous run did. State is persisted in the bridge's local
store, so it survives process restarts. `createAgent` always starts a fresh
agent with a new `id`; to continue one later, keep `agent.id` and resume it:

```nim
let agent = await client.resumeAgent(savedId)
let run = await agent.send("Also update the changelog.")
```

Options that are not persisted on the agent and must be passed again on
resume: `tools`, `disallowedTools`, inline `mcpServers`, and custom tools
(`opts.useTools(server)`). `agent.model` on a resumed agent reflects what
the bridge reports, which may be empty unless you pass `model` again.

### Sending messages

```nim
let run = await agent.send(UserMessage(text: "What is in this screenshot?",
  images: @[SdkImage(data: base64Png, mimeType: "image/png")]))
```

`SendOptions` carries a per-send `model` override (sticky: later sends keep
it), a `mode` override (`amoAgent` / `amoPlan`), `mcpServers` (replaces the
creation-time set for that run), `force` (expire a stuck local run first),
and the `enableDeltas` / `enableSteps` switches described below.

### Streaming

`Run.next` yields `RunEvent`s and skips keepalives (counted in
`run.keepalives`) and unknown envelope cases. Dispatch on `kind` and, for `rekMessage`, on `msgType` (`system`,
`assistant`, `thinking`, `tool_call`, `status`, `usage`, ...). Payloads are
`JsonNode`s matching the public SDK's message shapes; accessors cover the
common ones: `assistantText`, `thinkingText`, `toolCallName`,
`toolCallStatus`, `tokenUsage`, `statusMessage`, `runId`, `agentId`. The
`args`/`result` of `tool_call` payloads are not a stable schema.

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

After the stream ends, `run.wait()` returns the terminal `RunResult`:
`status`, `text` (the final assistant text; `result` on the wire), `model`,
`durationMs`, `usage` (cumulative token counts, when reported), `git`, and
`createdAt`. `run.text` and `run.failed` read the same result without
awaiting. A run stream is consumed once; `wait()` drains whatever `next()`
has not.

Opt into raw deltas or completed steps with
`SendOptions(enableDeltas: true)` / `SendOptions(enableSteps: true)`; they
arrive as `rekInteractionUpdate` / `rekStep` events.

Dropping a stream never cancels the run. `run.wait()` falls back to
`WaitLiveRun` if the connection drops, `run.observe()` re-attaches to the
durable event log (replaying from the start unless this run itself came from
`observe`), and `client.observeRun(runId)` does the same from a bare id.
`run.cancel()` requests cancellation; the stream still ends with a
`CANCELLED` result followed by `done`.

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
`sdkErrorCode`, `connectCode`, `details`, `requestId`, `retryAfter`, and
`rateLimit`. The message carries the full `request_id` when present; quote
it in support requests.
- `RunError`: raised by `prompt` and `Run.raiseIfFailed` when a run ends in
`ERROR`, `CANCELLED`, or `EXPIRED`. A failed run is not an RPC failure;
`Run.wait` returns the result and `RunResult.status` tells you what
happened. The human-readable reason is in `RunError.statusMessage`
(`run.lastStatusMessage`), taken from the last `status` event.

```nim
try:
  discard await client.createAgent("not-a-model")
except ValidationError as e:
  echo e.sdkErrorCode, " ", e.requestId
except RateLimitError as e:
  echo "retry after ", e.retryAfter
```

Errors the bridge does not classify (no `SdkErrorCode`, Connect code
`internal`) surface as `InternalError`; the message still explains the cause.

### Custom tools

```nim
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
```

Tool results must be JSON objects; scalars are wrapped as `{"value": ...}`.
`textResult("...")` builds an MCP-style text content envelope. An exception
raised by a handler is returned to the bridge as a Connect `internal` error
carrying the message. In the stream, custom tools show
up as `tool_call` events whose `toolCallName` resolves to your tool's name.
A tool may take as long as it needs: after ~15 s of silence the bridge
keeps the run stream alive with keepalive frames, which `Run.next` skips
and counts in `run.keepalives`.

### Custom stores

Set `ClientOptions.localStore = some(LocalAgentStoreConfig(kind: "custom"))`
together with `storeCallbackUrl`/`storeCallbackToken` pointing at a started
`CallbackServer` with a `setStoreHandler`, and the bridge persists every
agent, run, run event, and conversation checkpoint through your Nim code
instead of its own SQLite store:

```nim
let store = newCallbackServer()
store.setStoreHandler(proc(substore, meth: string, input: JsonNode): Future[JsonNode] {.async.} =
  ...)
await store.start()
var o = initClientOptions()
o.localStore = some(LocalAgentStoreConfig(kind: "custom"))
o.storeCallbackUrl = store.url
o.storeCallbackToken = store.authToken
let client = newClient(o)
```

The handler receives (`agents|runs|runEvents|checkpoints`,
`get|create|update|delete|list|append`, input) and returns the bare record,
or `nil` for a null result. Shapes observed from a real turn on this bridge
release: `create`/`update` wrap the record (`{"agent": {...}}`,
`{"run": {...}}`); `get` carries ids (`{"agentId"}`, `{"agentId", "runId"}`,
`{"agentId", "blobId"}`); `agents.list` carries `{"filter": {"cwd"}}` and
expects `{"items": [...]}`; `runEvents.append` is
`{"runId", "eventType", "payload"}`; checkpoint blobs are base64 strings,
written as `{"agentId", "blobId", "data"}` and read back as
`{"found": bool, "data": ...}`. See
`[docs/services.md](vendor/sdk-bridge/docs/services.md)` for the rules;
`tests/t_live.nim` has a complete in-memory store.

## The bridge binary

Resolution order:

1. `CURSOR_SDK_BRIDGE_BIN`: explicit path to a bridge executable.
2. The user cache: `getCacheDir("cursorsdk")/<version>/bin/cursor-sdk-bridge`.
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
the host process ends. The bridge is launched with
`CURSOR_SDK_CLIENT_LANGUAGE=nim` so Cursor can attribute traffic.

## Debugging

- `ClientOptions.verbose = true` makes the bridge log each RPC's name,
outcome, duration, and full error to stderr (via `onBridgeOutput`).
Request and response payloads are never logged.
- `BridgeError.stderr` and `client.bridge.outputTailText()` hold the last
bridge output when startup fails.
- When an RPC fails and you suspect this package rather than the bridge or
your key, run the curl-only sequence in
`[docs/smoke-test.md](vendor/sdk-bridge/docs/smoke-test.md)` against the
cached binary; it answers "is it me or the bridge?" with no adapter code.



## Notes on this bridge release

Behaviour observed against `cursor-sdk-bridge` v1.0.35 that is worth knowing:

- `createAgent` pre-creates the agent's first run before anything is sent
(stored as `queued`; `getRun` / `listRuns` report it as `RUNNING`).
`agent.delete()` on an agent that never completed a turn therefore fails
with an `InternalError` ("active run … is not terminal. Call run.cancel()
first."); `archive` works. `agent.delete(force = true)` cancels every
non-terminal run first and then deletes; use it deliberately, since it
also cancels a run that is genuinely in progress. This is not documented
upstream and was observed empirically (a custom store sees `runs.create`
with `status: "queued"` during `CreateAgent`).
- `agent.usage()` (`GetUsage`) is cloud-only: local agents get an
`InternalError` whose message says `feature_unavailable`. `listArtifacts` /
`downloadArtifact` are likewise cloud-only.
- `createAgent` validates the model against the catalog, so it needs a
working API key and network even though the agent runs locally.
- **Windows: `agent.delete()` fails for any agent that has run a turn.** The
bridge keeps each agent's SQLite store (`agents/<id>/store.db` + WAL) open
for the life of the process and `DeleteAgent` removes the directory without
closing it. POSIX allows unlinking open files; Windows refuses with
`InternalError` ("EBUSY: resource busy or locked, rm …"). `close()`,
`archive()`, and waiting do not release the handle. The agent stays
registered, and the delete succeeds from a fresh bridge process (restart the
client, then delete). Agents that never ran have no `store.db` yet, so
`delete(force = true)` on a fresh agent works everywhere.
- **Cancelling a run early in its life crashes the bridge** (Bun "Internal
assertion failure", exit code 3; every later RPC then fails with
"connection closed" or "connection refused"). The window is wider than the
first event: a `thinking` start frame can arrive within tens of ms on a warm
agent and cancelling there still crashes. Before calling `run.cancel()`, wait
until real text (`assistantText` / `thinkingText`) has streamed and at least
a second has passed. This narrows the race; it does not eliminate it.



## Scope and support

Cursor publishes and supports the `sdk.v1` contract and the bridge binaries;
this package is a community adapter, not a first-party SDK. Local agents are
the supported surface. Cloud agent options are not modelled: a request with
`AgentOptions.extra = %*{"cloud": {...}}` is passed through unchanged (no
local `cwd` is injected in that case), and the management, run, catalog, and
artifact RPCs on `Client` are runtime-agnostic, but none of this is tested
against cloud agents. SDK runs follow the same pricing and Privacy Mode rules
as the IDE; spend appears on the usage dashboard under the SDK tag.

## Versioning

This package pins one release of `cursor/sdk-bridge`, vendored as the
`vendor/sdk-bridge` submodule and recorded in `src/cursorsdk/version.nim`. The
first three components of the nimble version equal the bridge release
(`1.0.35`). Fixes to this package that do not change the bridge add a fourth
component (`1.0.35.1`). `sdk.v1` evolves additively, so a client built
against one tag keeps working with newer bridges; gate on
`client.hasCapability(...)` when you depend on a newer feature.

## Testing

```sh
nimble test
```

- `tests/t_codecs.nim`: pure unit tests (no network).
- `tests/t_bridge.nim`: spawns a real bridge, exercises handshake, auth,
streaming errors, shutdown, and the callback server. Needs the bridge
binary (downloaded if absent) but no API key.
- `tests/t_live.nim`: full turns against Cursor's API, including a custom
tool round trip with a >15 s tool pause (keepalives), a custom store round
trip, cancellation, observe/replay, `delete(force = true)`, and agent
lifecycle. Runs only when
`CURSOR_API_KEY` is set (or present in a gitignored `.env`). Spends real
requests.



## License

MIT