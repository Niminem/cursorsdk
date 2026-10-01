# cursorsdk

Cursor SDK Bridge client for the Nim programming language.

Drive [Cursor agents](https://cursor.com/docs/sdk) from Nim through
[`cursor-sdk-bridge`](https://github.com/cursor/sdk-bridge): a small local
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

Via Nimble:

```sh
nimble install cursorsdk
```

Or clone from source:

```sh
git clone --recursive https://github.com/Niminem/cursorsdk   # --recursive pulls the vendored sdk-bridge protocol docs
cd cursorsdk
nimble install
```

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

The fragments in the rest of this README omit their imports and assume
they run inside an `{.async.}` proc. `import std/asyncdispatch` and
`import cursorsdk` are all they need: `cursorsdk` re-exports `std/json`
(`JsonNode`, `%*`), `std/tables` (the `mcpServers` / `customTools` tables),
and `std/options` (`some`, `isNone`, ...). Every fragment is compiled by
`tests/t_readme.nim`.

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
| `Client`         | Owns the bridge process and transport. Typed low-level RPCs for every `SdkAgentService`, `SdkCursorService`, and `SdkBridgeControlService` method (`Shutdown` is issued by `close`), plus `call`/`stream` escape hatches for raw JSON. `relaunches` counts bridge relaunches and `restartBridge` forces one; `maxConcurrentAgents` / `loadedAgents` expose the advertised agent limit and this client's loaded count. |
| `Agent`          | `createAgent` / `resumeAgent`; `send` → `Run`; `id`, `model`, `cwd`; `info`, `reload`, `close`, `archive`, `unarchive`, `delete(force)`, `cancelNonTerminalRuns`, `runs`, `messages`, `usage`.      |
| `Run`            | `next` (events), `nextText` (assistant text), `wait` (terminal `RunResult`), `text`, `failed`, `raiseIfFailed`, `observe` (re-attach after a dropped stream), `cancel`, `close`, `keepalives`.       |
| `CallbackServer` | Loopback server for custom tools (`registerTool`) and custom stores (`setStoreHandler`).                                                                                                             |
| `ClientOptions`  | API key, workspace, bridge path/URL/token, extra bridge `env` and `bridgeArgs`, state root, default store, callback endpoints, `verbose` / `onBridgeOutput` logging, startup/RPC timeouts, `allowDownload`, `autoRelaunch` / `onBridgeRelaunch`. |

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
o.env = @[("CURSOR_SDK_BRIDGE_PORT", "49152")]   # extra bridge environment
o.bridgeArgs = @["--max-concurrent-agents", "4"] # extra bridge flags
let client = newClient(o)
```

`bridgeArgs` is appended verbatim to the bridge command line, for the flags
that have no environment variable (`--max-concurrent-agents`,
`--max-message-bytes`); an unknown flag makes the bridge exit before it is
ready, with its usage text in `BridgeError.stderr`.

When the bridge advertises `maxConcurrentAgents` (it does so only if you
pass `--max-concurrent-agents`), this client enforces it: `createAgent` and
`resumeAgent` raise `RateLimitError` once `client.loadedAgents` equals
`client.maxConcurrentAgents.get`. `loadedAgents` counts the agents this
client created or resumed on the current bridge process and has not yet
`close`d or `delete`d; re-resuming a loaded agent does not take a second
slot, and the count resets when the bridge is relaunched. It is the
client's own bookkeeping: agents loaded through the raw `call` escape
hatch, or by another client attached to the same bridge, are not counted.
The bridge itself does not enforce the limit (see "Notes on this bridge
release").

For long-running hosts, pin the model catalog so creating and resuming
agents never touches the network:

```nim
o.modelCatalog = await newClient(apiKey = key).listModels()  # fetch once, refresh on your schedule
o.agentLoadTimeoutMs = 15_000        # CreateAgent / ResumeAgent only; default: unaryTimeoutMs
```

Without it, the bridge validates `AgentOptions.model` against a `ListModels`
call it makes itself, with no timeout, on the first load per process, and a
hang there wedges every later `createAgent` / `resumeAgent` until the
process is replaced (see "Notes on this bridge release"). With it, validation
is local. `modelCatalog` relies on an undocumented bridge environment
variable (`CURSOR_SDK_LOCAL_MODEL_CATALOG_JSON`, verified on 1.0.35); only
model IDs are passed, so use the canonical IDs the catalog returns.

Attach to a bridge you already run (tests, hosts that manage the process):

```nim
o.bridgeUrl = "http://127.0.0.1:49152"
o.bridgeToken = readFile("/path/to/auth-token").strip   # strip: std/strutils
```

Attached bridges are not shut down by `client.close()`. Nothing is spawned
until the first RPC (or `await client.start()`); `client.ping()`,
`client.bridgeVersion()`, and `client.hasCapability("agent.usage")` report
bridge health, version, and feature flags.

Two checks run at start, before any other RPC. Option pairs must be
complete: `bridgeUrl`/`bridgeToken`, `toolCallbackUrl`/`toolCallbackToken`,
and `storeCallbackUrl`/`storeCallbackToken` are each both-or-neither, and
setting only one raises `BridgeError` before anything is spawned (the
protocol calls a lone URL or token a startup error). Then, once the bridge
is reachable, `GetVersion` must report protocol `sdk.v1`; a managed bridge
that fails this is shut down and a `BridgeError` names the protocol and
version it reported. The downloaded archive's `manifest.json` is checked
too, but that covers only the download path, not `CURSOR_SDK_BRIDGE_BIN` or
an attached bridge.

### Bridge resilience

If a *managed* bridge process exits unexpectedly, the next RPC relaunches it
and the call proceeds. Agents are durable on disk (the same property
`resumeAgent` relies on), so existing `Agent` handles keep working and the
conversation continues from the last completed turn: on its next `send()`
an `Agent` re-resumes itself on the new bridge (a fresh process only knows
agents it has loaded) and cancels any run the dead bridge left non-terminal
(the bridge rejects `Send` while one is "active"). A runtime
`setToolCallback` / `attachToolCallbacks` registration is re-applied;
launch-time callback URLs are passed again on the command line, and your
`CallbackServer` is unaffected since it lives in your process.

What is lost: runs that were in progress on the dead bridge. Local runs
execute inside the bridge, so they die with it. `next()` fails with
`TransportError`; `wait()` detects that the bridge exited (allowing up to
1.5 s for the exit to be reported, since the socket error can arrive
first) and raises `TransportError` ("run … lost") rather than falling back
to `WaitLiveRun` for a run the new bridge never had; `observe()` replays
what was recorded
but never sees a terminal `result`. Continue by calling `send()` again. An RPC that
races the crash can also fail once with `TransportError` before the exit is
noticed; the one after it relaunches.

```nim
o.autoRelaunch = true                # default
o.onBridgeRelaunch = proc(exitCode: int, outputTail: string) {.gcsafe.} =
  stderr.writeLine "bridge exited (", exitCode, "), relaunching\n", outputTail
# later: client.relaunches  # how many times it has happened
```

A bridge that is up but wedged does not relaunch by itself. `await
client.restartBridge()` replaces the process on demand with the same
semantics as a crash relaunch (`relaunches` increments, `loadedAgents`
resets, handles re-resume on their next `send`, in-progress runs on the old
process are lost). The known case is a `TransportError` timeout from
`createAgent` / `resumeAgent`; retrying without a restart hits the same hung
call:

```nim
try:
  agent = await client.createAgent(modelId)
except TransportError:
  await client.restartBridge()
  agent = await client.createAgent(modelId)
```

Set `autoRelaunch = false` to get a hard `TransportError` instead. Attached
bridges (`bridgeUrl`) are never relaunched. This goes beyond the upstream
adapter design, which treats a dead bridge as fatal; it still honours that
design (one managed bridge per client, lazy start, attach supported, exit
handler kills the live process) and is opt-out. It was added as a workaround
for the bridge 1.0.35 crash after `run.cancel()` on Windows (see "Notes on
this bridge release") and is kept as general hardening: a crashed bridge
should not require rebuilding your client.

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
valid ones. `some(newSeq[string]())` offers no built-in tools at all; deny
wins when both are set.

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
`run.keepalives`) and unknown envelope cases. Dispatch on `kind` and, for
`rekMessage`, on `msgType` (`system`, `assistant`, `thinking`, `tool_call`,
`status`, `usage`, ...). Payloads are
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
`WaitLiveRun` if the connection drops (that RPC is exempt from the unary
timeout, since a run can outlast the 60 s default), `run.observe()`
re-attaches to the durable event log (replaying from the start unless this
run itself came from `observe`), and `client.observeRun(runId)` does the same
from a bare id.
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
[docs/services.md](vendor/sdk-bridge/docs/services.md) for the rules;
`tests/t_live.nim` has a complete in-memory store.

Checkpoint blobs grow with the conversation. `newCallbackServer(maxBody =
...)` caps the `Content-Length` a callback request may carry; the default,
`DefaultCallbackMaxBody` (64 MiB), is well above the 8 MiB that
`std/asynchttpserver` would otherwise apply. A larger body is refused with
a bare HTTP 413 before your handler runs, which the bridge reports as a
store failure. (The server cannot take this from the bridge's advertised
`maxMessageBytes`: it has to be bound before the bridge is launched.)

## The bridge binary

Resolution order:

1. `CURSOR_SDK_BRIDGE_BIN`: explicit path to a bridge executable.
2. The user cache: `getCacheDir("cursorsdk")/<version>/bin/cursor-sdk-bridge`
   (`.exe` on Windows).
3. Download `cursor-sdk-bridge-standalone-<os>-<arch>.tar.gz` for the pinned
  release from GitHub, verify it against the release's `SHA256SUMS.txt`,
   check `manifest.json` (`protocol` is `sdk.v1`, `sdkVersion` is the
   pinned release), and extract into the cache.

Downloads shell out to `curl` and extraction to `tar`; both ship with macOS,
Windows 10+, and Linux. Compile with `-d:ssl` to download with
`std/httpclient` instead. Set `ClientOptions.allowDownload = false` to fail
instead of downloading.

The bridge binds `127.0.0.1` on an ephemeral port. Its stderr and stdout are
merged and drained by a dedicated thread (so a full pipe never blocks it) and
forwarded line by line to
`ClientOptions.onBridgeOutput`. The discovery line is never forwarded or
logged. On `client.close()` the bridge receives a `Shutdown` RPC, is given
5 seconds, then killed; an exit handler kills any bridge still alive when
the host process ends. The bridge is launched with
`CURSOR_SDK_CLIENT_LANGUAGE=nim` so Cursor can attribute traffic.

## Debugging

- `ClientOptions.verbose = true` passes `--verbose` so the bridge logs each
RPC's name, outcome, duration, and full error to stderr (via
`onBridgeOutput`). Request and response payloads are never logged. The flag
is accepted by bridge 1.0.35 but is not listed in the upstream CLI table in
[docs/protocol.md](vendor/sdk-bridge/docs/protocol.md).
- `BridgeError.stderr` and `client.bridge.outputTailText()` hold the last
bridge output when startup fails.
- When an RPC fails and you suspect this package rather than the bridge or
your key, run the curl-only sequence in
[docs/smoke-test.md](vendor/sdk-bridge/docs/smoke-test.md) against the
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
- `createAgent` and `resumeAgent` validate the model against the catalog,
so they need a working API key and network even though the agent runs
locally. The bridge fetches the catalog itself (`GET /v1/models`) on the
first load per process and per API key, with no timeout, and caches the
pending promise; a request that stalls therefore never fails, never expires,
and blocks every later `CreateAgent` / `ResumeAgent` on that process. Runs
on already-loaded agents are unaffected. From this client it surfaces as
`TransportError: SdkAgentService/CreateAgent: timed out`; the fixes are
`modelCatalog` (no network call at all) and `restartBridge` on timeout (see
"Client options" and "Bridge resilience"). Observed once in the live suite
on a freshly spawned bridge; read from the 1.0.35 binary
(`CloudApiClient.request` is a bare `fetch`, `localModelListCache` evicts
only on rejection).
- `--max-concurrent-agents` is advertised on the ready line but not
enforced: a second `CreateAgent` against a limit of 1 succeeds. This
package enforces the advertised value client-side (see
[Client options](#client-options)). A value of `0` is rejected at startup.
- **Windows: `agent.delete()` fails for any agent that has run a turn.** The
bridge keeps each agent's SQLite store (`agents/<id>/store.db` + WAL) open
for the life of the process and `DeleteAgent` removes the directory without
closing it. POSIX allows unlinking open files; Windows refuses with
`InternalError` ("EBUSY: resource busy or locked, rm …"). `close()`,
`archive()`, and waiting do not release the handle. The agent stays
registered, and any fresh bridge process can delete it (`close()` the
client, create a new one, then `delete()`). Agents that never ran have no
`store.db` yet, so `delete(force = true)` on a fresh agent works everywhere.
- **Windows: `run.cancel()` can crash the bridge.** `CancelRun` succeeds and
the run reports `CANCELLED`, but within about a second the bridge process
can die with a Bun "Internal assertion failure" (exit code 3). Cancelling on
the first stream event crashes it every time; cancelling after real text has
streamed crashes it some of the time. No client-side timing avoids it.
**`cancel()` is still usable:** the cancelled run is already terminal when
the crash happens, and the client relaunches the bridge once the exit is
noticed (see "Bridge resilience"). The practical effect is a startup delay,
one `TransportError` on any stream open at the time or any RPC racing the
crash, and the loss of other runs that were in progress on that bridge. Set
`onBridgeRelaunch` if you want to log it. macOS/Linux are not affected.

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
- `tests/t_readme.nim`: compile-only check of every code fragment in this
README (copied verbatim into procs that are never called).
- `tests/t_bridge.nim`: spawns a real bridge, exercises handshake, auth,
streaming errors, shutdown, attaching to an external bridge, auto-relaunch
after the process is killed (and the opt-out), URL/token pair validation,
the `GetVersion` protocol check (against a fake bridge), the advertised
agent limit, `restartBridge`, and the callback server (JSON, binary
protobuf, chunked bodies). Needs the bridge binary (downloaded if absent)
but no API key.
- `tests/t_live.nim`: full turns against Cursor's API, including a custom
tool round trip with a >15 s tool pause (keepalives), a custom store round
trip, cancellation (on its own bridge, verifying auto-relaunch if the bridge
crashes), a bridge killed mid-run (`wait()` reports the run lost, the agent
recovers), observe/replay, `delete(force = true)`, `modelCatalog` (a model
id absent from the real catalog is accepted when ours lists it, proving
validation stayed local), client-side enforcement of `maxConcurrentAgents`,
and agent lifecycle. Tests that spawn their own bridge pass the catalog and
a 15 s `agentLoadTimeoutMs`, so they cannot hang on the bridge's own
`ListModels` call. Runs only when `CURSOR_API_KEY` is set (or present in a
gitignored `.env`).
Spends real requests. On Windows, post-run `delete()` assertions are
skipped (printed as `skipped`) because of the bridge `EBUSY` bug above.

## License

MIT
