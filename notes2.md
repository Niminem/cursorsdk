# notes2.md: review of README, tests, and implementation vs. the vendored `sdk-bridge` docs

Review performed against the working tree at `ebf9473` (bridge pin `v1.0.35`,
`vendor/sdk-bridge` submodule at tag `v1.0.35`, Nim 2.2.10, Windows x64).

How the claims below were checked:

- Every README code fragment was compiled verbatim (in a scratch file outside
  the repo) against `src/`; see "README" for the one thing that did not compile.
- `tests/t_codecs.nim`, `tests/t_bridge.nim`, `tests/t_live.nim` and
  `src/cursorsdk.nim` were compiled with `--warnings:on --hints:on` and the
  `XDeclaredButNotUsed` / `UnusedImport` hints collected.
- `t_codecs` and `t_bridge` were run (all green). `t_live` was compiled but
  **not run** (it spends real requests against the key in `.env`).
- Source was read side by side with `vendor/sdk-bridge/README.md`,
  `docs/protocol.md`, `docs/services.md`, `docs/streaming.md`,
  `docs/errors.md`, `docs/versioning.md`, `docs/smoke-test.md`, the seven
  `.proto` files, and the `examples/python-adapter` reference.

---

## 1. README.md

### Verified correct (no change needed)

- Every symbol named in the "API overview" table exists with the documented
  shape: `Client` (`call`, `stream`, `ping`, `bridgeVersion`, `hasCapability`,
  `setToolCallback`, `me`, `listModels`, `listRepositories`, all 20
  `SdkAgentService` RPCs, `relaunches`), `Agent` (`id`, `model`, `cwd`, `info`,
  `reload`, `close`, `archive`, `unarchive`, `delete(force)`,
  `cancelNonTerminalRuns`, `runs`, `messages`, `usage`), `Run` (`next`,
  `nextText`, `wait`, `text`, `failed`, `raiseIfFailed`, `observe`, `cancel`,
  `close`, `keepalives`), `CallbackServer` (`registerTool`, `setStoreHandler`),
  and every `ClientOptions` field listed.
- All twelve `RpcError` subclasses listed under "Errors" exist in
  `errors.nim`, and the accessors `sdkErrorCode`, `connectCode`, `details`,
  `requestId`, `retryAfter`, `rateLimit` are all present.
- Resolution order for the bridge binary (`CURSOR_SDK_BRIDGE_BIN` → cache →
  download + `SHA256SUMS.txt` + `manifest.json`) matches `bridge_fetch.nim`.
- `nimble fetchBridge` task exists. `nimble test` relies on nimble's built-in
  default task (runs `tests/t*.nim`); `tests/config.nims` adds `src` to the
  path, so this works without an explicit task.
- Version story: nimble `version = "1.0.35"`, `version.nim`
  `BridgeVersion = "1.0.35"`, submodule at `v1.0.35`,
  `proto/manifest.json` `sdkVersion = "1.0.35"`. All consistent.
- "Bridge resilience" section matches `client.nim` (`needsRelaunch`, `ensure`),
  `agent.nim` (`ensureLoaded` re-resumes and cancels non-terminal runs) and
  `run.nim` (`wait` raises "run … lost" instead of falling back to
  `WaitLiveRun`). `t_bridge` "auto-relaunch" and the opt-out path confirm the
  documented behaviour.
- "Streaming": keepalive counting, unknown-envelope skipping, `WaitLiveRun`
  exemption from the unary timeout (`waitLiveRun` passes `timeoutMs = 0`), and
  the `observe` offset rule (`after` only when the run itself came from
  `ObserveRun`) all match the code.
- "The bridge binary": stdout and stderr are indeed merged
  (`poStdErrToStdOut` in `bridge_supervisor.nim`); `CURSOR_SDK_CLIENT_LANGUAGE=nim`
  is set; exit handler (`addExitProc(killAllManaged)`) exists.
- Quick start's `defer: waitFor client.close()` inside an `{.async.}` proc
  compiles (nested `waitFor` is tolerated by `asyncdispatch`).

### Changed

1. **Fragments did not compile as written.** The "Agent options" snippet does
   `opts.mcpServers["fs"] = ...`, which needs `std/tables`; the custom-tool and
   custom-store snippets use `%*` / `JsonNode`, which need `std/json`. Neither
   module is re-exported by `cursorsdk` (`client.nim` exports only `options`,
   `types`, `errors`). Added a one-paragraph note after the one-shot example
   stating which imports the fragments assume. (Alternative, not applied: have
   `types.nim` `export tables` and `export json`, since `Table` and `JsonNode`
   are part of the public API surface. See §4.)
2. API overview, `Client` row: added "(`Shutdown` is issued by `close`)". There
   is no `client.shutdown()`; the RPC is sent from `Bridge.shutdown` via
   `client.close()`.
3. "The bridge binary", cache path: added "(`.exe` on Windows)" to match
   `bridgeExeName()`.
4. Added the missing trailing newline (CRLF, matching the file).

### Left as is (judgement calls)

- "Notes on this bridge release" and the Windows EBUSY / CancelRun-crash
  paragraphs are empirical claims about bridge 1.0.35 that cannot be verified
  statically; they are consistent with the code comments in `t_live.nim`,
  `agent.nim` and `client.nim`.
- `agent.usage()` is documented as returning `InternalError` with
  `feature_unavailable` in the message. Per `docs/errors.md` a bridge that set
  `SDK_ERROR_CODE_FEATURE_UNAVAILABLE` would map to `PermissionError` here;
  the README reflects what was observed (the bridge evidently sends no
  `sdk_error_code` for this case). Worth re-checking on the next bridge pin.

---

## 2. Tests

### `tests/t_codecs.nim`

- Compiles with no hints or warnings of its own. Every import is used.
- Suites match the header comment (SHA-256, protobuf, Struct, SdkErrorDetails,
  Connect errors, discovery line, timestamps, stream envelopes, request
  serialization). No dead code found.
- No changes.

### `tests/t_bridge.nim`

- **Dead code on Windows (fixed).** `let pid = ...` at the end of "launch,
  handshake, ping, version, shutdown" and of "lazy start, …, close" was only
  consumed inside `when not defined(windows)`, so on Windows the compiler
  reported `'pid' is declared but not used`. Rather than silencing it, added a
  Windows `pidAlive` (`OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)` +
  `GetExitCodeProcess != STILL_ACTIVE`) and removed both `when` guards. The
  "process is really gone after shutdown/close" assertion now runs on every
  platform; it passed on Windows.
- `killProcess` on Windows now uses `TerminateProcess` via `std/winlean`
  instead of shelling out to `taskkill`. Same semantics as `/F`, no `cmd.exe`
  dependency, and it is the same primitive `bridge.nim`'s `killPid` uses.
- "missing api key is reported before any RPC" wraps a synchronous check in an
  `{.async.}` proc with no `await`. Harmless; left as is for uniformity.
- "auto-relaunch after the bridge dies" says the runtime tool-callback
  re-registration is "exercised by the relaunch succeeding". That is a weak
  check (it proves `SetToolCallback` did not fail on the new bridge, not that
  the value was re-applied). There is no bridge RPC to read the registered
  callback back, so nothing stronger is possible without a live tool call;
  the live custom-tool test covers the real path. Left as is.
- Header comment and all other test comments are accurate.
- Re-ran after the edit: 11/11 pass.

### `tests/t_live.nim` (compiled only, not run)

- No unused imports, no `XDeclaredButNotUsed` hints. Header comment is
  accurate (`CURSOR_TEST_MODEL`, `CURSOR_TEST_VERBOSE`, `.env` fallback).
- `deleteAfterRunWorks` and `killProcess` are both used.
- The cancel test's comments are consistent with the README: the test waits
  for ≥1 s of streamed text to *reduce* the Windows crash probability, and the
  README says no timing *avoids* it. Both statements can be true.
- `check killClient.relaunches == 0  # wait() must not relaunch by itself`
  matches `run.nim`: `wait` never calls `client.ensure`.
- Unverified assumptions in the in-memory store (not asserted, so they cannot
  cause a false pass, but could cause a bridge-side failure if the bridge ever
  calls them): `runEvents.list` returns `{"events": [...]}` and
  `runEvents.append` returns `{"offset": "<n>"}`. `docs/services.md` only
  specifies the *input* of `append` and says outputs must be bare records; it
  does not give the `list`/`append` output shapes. If a future bridge starts
  calling `runEvents.list` (e.g. for `ObserveRun` on a custom store) this is
  the first place to look.
- `killProcess` here still uses `taskkill`. It could adopt the `winlean`
  helper from `t_bridge.nim`, but I did not change a live test I could not
  run.
- No changes.

---

## 3. Implementation vs. `vendor/sdk-bridge` docs

Legend: ✓ conforms · ≈ conforms with a deviation · ✗ gap.

### `docs/protocol.md` — lifecycle and handshake

| Requirement | Status | Where / note |
| --- | --- | --- |
| Spawn with `CURSOR_API_KEY` in env, `--workspace` | ✓ | `bridge.nim` `launchBridge`, `buildArgs` |
| `CURSOR_SDK_CLIENT_LANGUAGE=<lang>` | ✓ | `"nim"` via `version.nim` |
| Capture **stderr**, scan for `cursor-sdk-bridge ready ` | ≈ | stdout is merged into stderr (`poStdErrToStdOut`). Needed because `std/osproc` pipes on Windows are not overlapped and one thread drains one stream. Benign: the bridge prints nothing meaningful on stdout. Documented in README. |
| Validate `schemaVersion == 1`, `transport == "tcp"`, `protocol == "connect"`; ignore unknown fields | ✓ | `parseReadyLine`; `raw` keeps unknown keys |
| Prefer `url`, fall back to `host`+`port`, bracket IPv6 | ✓ | `parseReadyLine` |
| ~30 s startup timeout; surface stderr if the process exits first | ✓ | `BridgeError.stderr` from `outputTail` |
| Keep draining stderr forever | ✓ | supervisor thread loops until EOF |
| Never log the discovery line; prefer inline `authToken` if present | ✓ | `handleEvent` skips it; `readToken` prefers inline |
| Read bearer token from `authTokenFile`, trimmed | ✓ | `readToken` |
| `maxConcurrentAgents` / `maxMessageBytes` from discovery | ≈ | Parsed into `BridgeInfo` but never consulted. |
| Shutdown: `Shutdown` RPC (or SIGTERM) → wait ~5 s → kill; also at process exit | ✓ | `Bridge.shutdown` (RPC → `exitFut.withTimeout` → `killPid`), `addExitProc(killAllManaged)`. At exit it kills by PID without a `Shutdown` RPC, which the doc allows. |
| Attach to an already-running bridge (URL + token) | ✓ | `attachBridge`, `ClientOptions.bridgeUrl/bridgeToken` |
| CLI: `--state-root`, `--local-store`, `--store-callback-*`, `--tool-callback-*` | ✓ | `buildArgs` |
| CLI: `--host`, `--port` | ≈ | Not exposed. Reachable through `ClientOptions.env` (`CURSOR_SDK_BRIDGE_HOST/PORT`). Ephemeral default is what the doc recommends. |
| CLI: `--max-concurrent-agents`, `--max-message-bytes` | ✗ | Not exposed and they have no env-var equivalent, so there is no way to set them. Suggest `BridgeLaunchOptions.extraArgs: seq[string]` (and a `ClientOptions` passthrough). |
| CLI: `--verbose` | ≈ | Used by this package; **not in the upstream flag table**. README calls this out. If a future bridge drops the flag, startup would fail with "unknown option" captured in `BridgeError.stderr`. |
| Callback URL/token "must be provided together; supplying only one is a startup error" | ≈ | `buildArgs` emits both flags whenever the URL is set, so an empty token becomes `--tool-callback-auth-token ""`. The bridge may accept an empty token (then every callback would fail auth) or reject it; either way a client-side check in `startImpl` (`BridgeError` if URL xor token) would give a clearer error. Same for `bridgeUrl` without `bridgeToken` (the Python adapter rejects that pairing up front). |

### `docs/protocol.md` / README milestone 3 — transport, auth, errors

| Requirement | Status | Where / note |
| --- | --- | --- |
| `Authorization: Bearer` on **every** request, unary and streaming | ✓ | `authHeaders` used by both `unaryImpl` and `serverStream` |
| HTTP/1.1 only; `POST /sdk.v1.<Service>/<Method>` | ✓ | `rpcPath`, hand-rolled `http.nim` |
| JSON (`application/json`) unary; `application/connect+json` streams with 1+4 byte framing; `0x02` end-stream | ✓ | `connect.nim` |
| Verify `Ping` then `GetVersion` (`protocol_version == "sdk.v1"`) after handshake | ≈ | Not done automatically in `Client.start`. The package relies on `manifest.json` for downloaded binaries, but a `CURSOR_SDK_BRIDGE_BIN` override is never protocol-checked. Cheap to add: one `GetVersion` in `startImpl` with a `BridgeError` on mismatch. |
| Decode `SdkErrorDetails` from `details[].value` (base64) | ✓ | `extractSdkErrorDetails`; also falls back to the `debug` JSON rendering |
| Map `sdk_error_code` + Connect code to an error hierarchy; expose full `request_id`, `retry_after`, `rate_limit` | ✓ | `classify`, accessors; `request_id` is appended untruncated to `msg` |
| Tolerate unknown enum values | ✓ | `rawCode` kept, `secUnspecified` otherwise |
| Parse protobuf JSON with unknown-field tolerance everywhere | ✓ | all parsers are `JsonNode`-based `getOrDefault` |
| Bare `UNAUTHENTICATED` without details → auth error | ✓ | `t_bridge` asserts `AuthError` + `details.isNone` |
| Connect `Connect-Protocol-Version: 1` header | ✓ | sent (optional per spec) |
| Compression | ✓ | `Accept-Encoding: identity`; a compressed frame is a `TransportError` |
| Unary timeout | ≈ | On timeout the future is detached but the socket is not closed; it lingers until the bridge answers or closes. Only matters for a hung bridge. |

### README milestone 4 / `docs/streaming.md` — runs

| Requirement | Status | Where / note |
| --- | --- | --- |
| `CreateAgent` with explicit `options.model`, `local.cwd = ["<workspace>"]`, explicit `api_key` | ✓ | `fillDefaults` always injects the key (`requireApiKey`) and a canonical `cwd` |
| Catalog calls require per-call `api_key` | ✓ | `catalogRequest`; missing key raises `AuthError` *before* the RPC |
| Dispatch on `envelope` oneof; ignore empty (keepalive) and unknown cases | ✓ | `parseRunEvent`, `Run.next`; keepalives counted |
| Keepalives must not advance offset bookkeeping | ✓ | `track` is not called for `rekUnknown` |
| Track last non-empty `offset` | ≈ | Unknown-but-non-empty envelope cases that *do* carry an offset are skipped before `track`, so `lastOffset` is not advanced for them. Defensible ("offsets you processed") but means a future envelope case would be replayed on resume. Trivial. |
| `status` payload `message` surfaced as the failure reason | ✓ | `lastStatusMessage` → `RunError.statusMessage` |
| `result` then `done` end the run | ✓ | `track` sets `finished` on `done` |
| Dropped stream does not cancel; `wait()` falls back to `WaitLiveRun` | ✓ | `Run.wait` |
| `ObserveRun` only resumed with offsets from `ObserveRun` | ✓ | `observe` uses `lastOffset` only when `fromObserve` |
| `WaitLiveRun` has no deadline | ✓ | `timeoutMs = 0` |
| `run_id` learned from first `sdk_message` (`run_id`/`runId`) | ✓ | `RunEvent.runId` accepts both spellings |
| `CancelRun` with optional `agent_id` hint | ✓ | `cancelRun(runId, agentId)` |
| Bridge-exit detection in `wait()` | ≈ | Beyond the doc. Detection depends on the `bekExited` event having been processed (`sleepAsync(0)` gives one poll). If the exit lands later (the Windows post-cancel crash can take ~1 s), `wait()` falls through to `WaitLiveRun` on a dead port and raises a connect-refused `TransportError` instead of "run … lost". Same error class, different message; README's "An RPC that races the crash can also fail once" covers this. |

### `docs/services.md`

| Requirement | Status | Where / note |
| --- | --- | --- |
| All 20 `SdkAgentService` RPCs, 3 `SdkCursorService`, 4 `SdkBridgeControlService` | ✓ | `client.nim`; `Shutdown` via `Bridge.shutdown` |
| `CreateAgent` `idempotency_key` | ✓ | `createAgentRaw(idempotencyKey)` |
| Pagination cursors on `ListAgents` / `ListRuns` | ✓ | `Page[T].nextCursor`; auto-pagination only in `cancelNonTerminalRuns` (the Python example auto-paginates everywhere; a matter of taste) |
| `GetUsage` cloud-only | ✓ | README documents the observed error |
| `SetToolCallback` clears with empty URL | ✓ | passes through; remembered for relaunch |
| Callback servers validate the bearer token on every call | ✓ | `handle` |
| Callback requests may be chunked | ✓ | `std/asynchttpserver` decodes `Transfer-Encoding: chunked` itself (verified in the 2.2.10 source); `t_bridge` covers it |
| Tool result must be a Struct (object); wrap scalars | ✓ | `wrapToolResult` → `{"value": …}`; `nil` → `{}` |
| Store output is the bare record or unset for null | ✓ | `encodeStoreResponse` omits `output` for nil/JNull |
| Store callback launch-time only | ✓ | only `ClientOptions.storeCallbackUrl/Token` → CLI flags |
| Binary (`application/proto`) callback requests | ✓ | `decodeToolRequest` / `decodeStoreRequest` handle both; response content-type mirrors the request |
| Request body size | ✗ | `newAsyncHttpServer` default `maxBody = 8 MiB`. A `Content-Length` callback body above that gets a plain HTTP 413 (not a Connect error). For custom stores, `checkpoints.create/update` carries a base64 conversation blob, which can grow large on long agents. `newCallbackServer` does not expose `maxBody`; suggest a parameter (and consider `BridgeInfo.maxMessageBytes` as the default when advertised). Chunked bodies are not size-limited by the stdlib. |

### `docs/errors.md`

- Taxonomy: all 21 `SdkErrorCode` values present with the proto numbering;
  the string-name table in `parseSdkErrorCodeName` matches the proto.
- Classification: sdk code wins over the Connect code; `secUnspecified` falls
  back to the Connect code. `deadline_exceeded`/`unavailable`/`aborted` →
  `UnavailableError`, `unimplemented` → bare `RpcError`. Reasonable.
- "Run failures are not RPC failures": honoured (`wait` returns the result;
  `RunError` only from `prompt` / `raiseIfFailed`).
- `type` match on the detail uses `endsWith("SdkErrorDetails")`, so both
  `sdk.v1.SdkErrorDetails` and a `type.googleapis.com/` prefix work.

### `docs/versioning.md`

- Pinned to one tag; unknown JSON keys, enum values, envelope cases and
  capability strings are all tolerated; `hasCapability` is available for
  gating. ✓

### Proto coverage (what is and is not modelled)

Modelled: everything in `sdk_agent_service.proto`,
`sdk_bridge_control_service.proto`, `sdk_cursor_service.proto`, both callback
services, and the local half of `sdk_messages.proto` (including
`ToolList`, `SandboxOptions`, `LocalAgentStoreConfig`, `CustomToolDefinition`
with `output_schema`, `dirs`, `auto_review`, `SdkImage` oneof + dimension,
`AgentDefinition`, both MCP config variants, `AgentModeOption`).

Not modelled (cloud only, reachable through `AgentOptions.extra` /
`SendOptions.extra`): `CloudAgentOptions`, `CloudSendOptions.env_vars`,
`CloudEnvironment*`, `CloudRepository`, `ListAgentsOptions.pr_url`,
`GetRunOptions.runtime`. Consistent with the README's stated scope.

Wire-format details checked against the proto JSON mapping: `LocalAgentOptions.cwd`
sent as a one-element array ✓; `tools` as `{"names": [...]}` ✓;
`sandbox_options.enabled` ✓; `LocalSendOptions.force` under `local` ✓; enum
values with their `PREFIX_` ✓; `uint64`/`int64` accepted as string or number ✓;
`google.protobuf.Timestamp` RFC 3339 with any fractional precision ✓.

---

## 4. Windows-specific deviations (and why they exist)

These are the places where the Nim implementation departs from the reference
design in `vendor/sdk-bridge`, all driven by Windows:

1. **Supervisor thread instead of async pipes** (`bridge_supervisor.nim`).
   `std/osproc` pipes are not overlapped on Windows, so they cannot be driven
   by `asyncdispatch`. One blocking thread owns the `Process`, drains the
   merged stderr/stdout line by line, and posts events through a `Channel` +
   `AsyncEvent`. Consequence: stdout and stderr are merged (see protocol.md
   row above).
2. **`poDaemon`** on Windows so no console window flashes for the child.
3. **Kill by PID** with `TerminateProcess` (POSIX: `SIGKILL`) rather than the
   doc's `SIGTERM`; the graceful path is the `Shutdown` RPC on both platforms,
   which the doc lists as the preferred option anyway.
4. **Auto-relaunch** (`ClientOptions.autoRelaunch`, default on). Not part of
   the upstream design, which treats a dead bridge as fatal. Added because
   bridge 1.0.35 can crash with a Bun assertion (exit 3) about a second after
   a successful `CancelRun` on Windows. The design still honours "one managed
   bridge per client, lazy start, attach supported, exit handler". `Agent`
   handles survive by re-resuming (`ensureLoaded`) and cancelling runs the
   dead bridge left non-terminal, because the bridge rejects `Send` while a
   run is "active".
5. **`delete()` after a turn fails on Windows** (`EBUSY`): the bridge keeps
   `store.db` open and `DeleteAgent` `rm`s the directory. Not an adapter bug;
   skipped in `t_live` via `deleteAfterRunWorks`. `delete(force = true)` on a
   never-run agent works everywhere.
6. **`--verbose`** is passed to the bridge for `ClientOptions.verbose`;
   accepted by 1.0.35 but absent from the upstream CLI table.
7. **Fetch path**: `curl` + `tar` shell-outs (both ship with Windows 10+),
   `.exe` suffix, `setFilePermissions` skipped on Windows, cache under
   `%LOCALAPPDATA%\cursorsdk\cache\1.0.35`. `platformSlug` refuses Windows
   ARM (no upstream binary) with a message pointing at `CURSOR_SDK_BRIDGE_BIN`.
8. **Path canonicalisation** via `expandFilename` so the same string keys the
   bridge's per-cwd store from `--workspace`, `local.cwd`, and management
   `cwd` options (case and separators matter on Windows).
9. **`t_bridge` "exits before ready"** uses `whoami` on Windows (rejects
   `--workspace`, exits 1, never reads stdin) vs `sh` elsewhere.

None of these contradict the documented contract; they are all in the
"adapter-side" space the docs leave open.

---

## 5. Suggestions not applied (outside the requested scope)

Source-level items; listed so they can be picked up deliberately:

- `types.nim:193` `protoName(e: RunLifecycleStatus)` is declared but never
  used (`XDeclaredButNotUsed`). The only enum whose `protoName` has no
  serializer. Delete, or keep if a `RunLifecycleStatus` request field is
  expected.
- `client.nim` `ClientOptions.onBridgeOutput` doc says "bridge stderr lines";
  it receives merged stderr+stdout (as `BridgeLaunchOptions.onOutput` and the
  README already say).
- `export tables` / `export json` from `types.nim` (or `cursorsdk.nim`) so that
  users of `AgentOptions.mcpServers`, `local.customTools`,
  `CallbackServer.customTools`, `JsonNode` payloads and `%*` do not need extra
  imports. The README now documents the imports instead.
- `Client.start` could `GetVersion` once and raise `BridgeError` if
  `protocolVersion != "sdk.v1"` (covers `CURSOR_SDK_BRIDGE_BIN` overrides).
- Validate `bridgeUrl`/`bridgeToken` and each callback URL/token pair are set
  together before launching.
- `BridgeLaunchOptions.extraArgs` for `--max-concurrent-agents` /
  `--max-message-bytes` (no env-var equivalents).
- `newCallbackServer(maxBody = …)` passthrough to `newAsyncHttpServer`.
- `connect.nim` `unary`: close the connection when the deadline fires.
- `cursorsdk.nim` module list omits `version` (which it does export).
- `tests/t_live.nim` `killProcess` could reuse the `winlean` helper now in
  `t_bridge.nim`.
