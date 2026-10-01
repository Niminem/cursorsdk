# Review notes: cursorsdk vs. cursor/sdk-bridge v1.0.35

Review of the root README, the tests, and the implementation against the
vendored protocol documentation in `vendor/sdk-bridge/` (`README.md`,
`docs/protocol.md`, `docs/services.md`, `docs/streaming.md`,
`docs/errors.md`, `docs/versioning.md`, `docs/smoke-test.md`, the seven
`proto/sdk/v1/*.proto` files, and `examples/python-adapter/`).

Sections 1-3 are the findings. Section 4 lists what was changed in this
pass; section 5 lists what was deliberately left alone.

## 1. README

Verified correct against the code: the API-overview table (all 20
`SdkAgentService` RPCs, 3 `SdkCursorService`, 4 `SdkBridgeControlService`
methods exist on `Client`), bridge resolution order and cache path,
shutdown sequence, `CURSOR_SDK_CLIENT_LANGUAGE=nim`, error-class mapping,
version pin (`1.0.35` in `version.nim`, the nimble file, and the submodule
tag), Nim floor (`>= 2.2.10`), the Bridge resilience section, the Windows
notes, and the Testing section.

Problems found (all fixed, see section 4):

- Two markdown links were wrapped in backticks and rendered as literal
  text: the `cursor-sdk-bridge` link in the intro and the `smoke-test.md`
  link under Debugging.
- `some(@[])` in the Agent options prose does not compile (empty seq
  literal has no inferable element type).
- "`run.wait()` falls back to `WaitLiveRun`" was over-promising: the RPC
  ran under the 60 s unary deadline (see section 3).
- "Its stderr is drained" understated what happens: stdout and stderr are
  merged (`poStdErrToStdOut`).
- `ClientOptions.verbose` passes `--verbose`, which is not in the upstream
  CLI flag table; the README did not say so.
- API table omitted `Agent.cancelNonTerminalRuns`, `Client.relaunches`,
  and `ClientOptions.env` / `onBridgeOutput`.
- Cosmetic: one unwrapped ~120-column line in Streaming, several runs of
  2-3 blank lines, `t_bridge.nim` description missing the attach and
  auto-relaunch tests.

Not changed, worth knowing: the Quick start uses
`defer: waitFor client.close()` inside an `{.async.}` proc. It works (and
is why `prompt` avoids `await` inside `finally`), but no test compiles that
exact snippet.

## 2. Tests

- `tests/t_bridge.nim`: `sawOutput` was written and then `discard`ed; the
  real assertion is the `doAssert` inside the `onOutput` callback. Removed.
- `tests/t_bridge.nim`: `std/tables` was imported but unused. Removed.
- `tests/t_live.nim`: the cancel test accepts `rlsFinished` as well as
  `rlsCancelled` without saying why. Comment added (cancellation is
  cooperative; a run already wrapping up can still finish).
- `killProcess` is duplicated between `t_bridge.nim` and `t_live.nim`.
  Left as is; they are separate binaries and the helper is three lines.
- `t_codecs.nim`: nothing dead; the two "real bridge payload" fixtures are
  valuable regression anchors.

## 3. Implementation vs. the vendored docs

### Conformant

| Requirement (doc) | Where | Status |
| --- | --- | --- |
| Spawn with `CURSOR_API_KEY`, `--workspace`, `CURSOR_SDK_CLIENT_LANGUAGE` (protocol.md) | `bridge.nim` `launchBridge` | OK |
| Ready-line prefix, `schemaVersion==1`, `transport=="tcp"`, `protocol=="connect"`, unknown keys ignored, `url` preferred over bracketed host:port | `parseReadyLine` | OK |
| 30 s startup timeout; exit-before-ready surfaces captured output | `launchBridge`, `handleEvent(bekExited)` | OK |
| Drain stderr forever; never log the discovery line | supervisor thread; `handleEvent(bekOutput)` | OK |
| Token from `authTokenFile`, trimmed; inline `authToken` preferred when present | `readToken` | OK |
| Shutdown RPC, wait ~5 s, kill; exit-time cleanup | `Bridge.shutdown`, `addExitProc(killAllManaged)` | OK |
| Attach to an external URL + token | `attachBridge` | OK |
| Bearer on every request including streams; `Connect-Protocol-Version: 1` | `ConnectClient.authHeaders` | OK |
| Connect streaming framing: flags + BE length, `0x02` end-stream carrying `error` | `connect.nim` | OK |
| `SdkErrorDetails` from base64 `details[].value`, `debug` fallback; `request_id`, `retry_after`, `rate_limit` exposed; unknown enum values tolerated | `errors.nim` | OK |
| Always set `options.api_key` on `CreateAgent`/`ResumeAgent`; per-call key on catalog RPCs | `fillDefaults`, `catalogRequest` | OK |
| Skip keepalives and unknown envelope cases; track last non-empty offset | `Run.next`, `Run.track` | OK |
| Surface the last `status` message as the failure reason | `RunError.statusMessage`, `Run.lastStatusMessage` | OK |
| Resume `ObserveRun` only with offsets that came from `ObserveRun` (streaming.md) | `Run.observe` via `fromObserve` | OK, stricter than the Python example |
| `ToolList` wrapper so an empty `tools` list is distinguishable from unset | `AgentOptions.toJson` | OK |
| Callback server: bearer validation, chunked bodies, JSON and binary proto, scalar wrapping, bare store outputs, `nil` -> unset `output` | `callbacks.nim` | OK (chunked decoding is in `std/asynchttpserver` and covered by a test) |
| Store callback launch-time only; tool callback at launch or via `SetToolCallback` | `buildArgs`, `setToolCallback` | OK |
| `ReloadAgent` (in the proto, missing from services.md's table) | `reloadAgent` | OK |

### Deliberate deviations (mostly Windows-motivated)

1. Supervisor thread + `Channel` + `AsyncEvent` instead of async pipes
   (`bridge_supervisor.nim`). `std/osproc` pipes are not overlapped on
   Windows, so `asyncdispatch` cannot drive them. Portable; documented in
   the module header.
2. `poStdErrToStdOut` merges stdout into the drained stream. The protocol
   puts the ready line on stderr; merging is a superset. Any future stdout
   output from the bridge would be treated as a diagnostic line.
3. `poDaemon` on Windows to avoid a console window. Harmless.
4. Kill by PID (`TerminateProcess` / `SIGKILL`); no SIGINT/SIGTERM path.
   protocol.md allows "Shutdown RPC or SIGTERM", and Windows has no
   SIGTERM, so this is in-spec.
5. Auto-relaunch (`autoRelaunch`, `onBridgeRelaunch`, `Client.relaunches`,
   `Agent.generation` / `ensureLoaded`, `Run.relaunchesAtStart`). Upstream
   treats a dead bridge as fatal. Added for the 1.0.35 Bun crash after
   `CancelRun` on Windows; kept as general hardening; opt-out.
6. `Run.wait` raises `TransportError("run ... lost")` instead of falling
   back to `WaitLiveRun` when the managed bridge has exited. Correct: the
   relaunched bridge never had that run.
7. `Agent.delete(force)` / `cancelNonTerminalRuns`: workaround for
   `CreateAgent` pre-creating a `queued` run (observed via a custom store;
   not documented upstream).
8. `normalizeWorkspace` canonicalises paths and defaults `cwd` on
   management calls. The docs say stores are keyed by cwd but do not say
   to canonicalise; this matters on Windows (case, slash direction).
9. `--verbose` flag. Not in protocol.md's CLI table; accepted by 1.0.35.
   README now says so.

### Gaps and suggestions

- FIXED: `WaitLiveRun` ran under the 60 s unary deadline, so
  `Run.wait`'s recovery path would fail with
  `TransportError("timed out after 60000 ms")` on any run with more than a
  minute left. The Python reference adapter passes `timeout=None` for this
  one RPC. `ConnectClient.unary` and `Client.call` now take `timeoutMs`
  (`-1` = client default, `0` = none) and `waitLiveRun` passes `0`.
- `verifyManifest` only asserts `protocol == "sdk.v1"`. versioning.md
  recommends matching `manifest.json` `sdkVersion` to the pinned tag.
  Asserting `sdkVersion == BridgeVersion` would catch a stale or
  corrupted cache directory. Not changed in this pass: it only runs on
  download, which the local cache means the normal test run never
  exercises, so a mistake there would go unnoticed until a fresh machine.
  Add it when a clean-cache download can be verified.
- Proto fields intentionally not modelled (cloud-only; reachable through
  `AgentOptions.extra` / `SendOptions.extra`): `AgentOptions.cloud`,
  `SendOptions.cloud`, `ListAgentsOptions.pr_url`. `GetRunOptions.runtime`
  is also not passed by `getRun`. Consistent with the local-only scope.
- `Agent.createAgent` sets `options.local.cwd = c.opts.workspace` on the
  handle even when `extra["cloud"]` is present. `fillDefaults` correctly
  omits it from the wire request, but the handle's `cwd()` and a relaunch
  `resumeAgentRaw(a.id, a.options)` would then carry a `local.cwd`. Only
  reachable when passing a cloud request through `extra`, which is out of
  scope. An `if not cloud` guard mirroring `fillDefaults` would close it.
- `--host`, `--port`, `--max-concurrent-agents`, `--max-message-bytes` are
  not exposed. Ephemeral loopback is the right default;
  `ClientOptions.env` lets a caller set `CURSOR_SDK_BRIDGE_PORT` if needed.

## 4. Changes made in this pass

- `README.md`: unwrapped the two backticked links; `some(@[])` ->
  `some(newSeq[string]())`; `wait()` fallback sentence now states the
  no-deadline behaviour; stderr/stdout wording; `--verbose` noted as
  undocumented upstream; API table rows for `Client`, `Agent`,
  `ClientOptions` extended; `t_bridge.nim` description extended; long
  line rewrapped; extra blank lines removed.
- `src/cursorsdk/connect.nim`: `unary` gained `timeoutMs = -1`
  (`-1` = client default, `0` = no deadline); doc comment on
  `unaryTimeoutMs` updated.
- `src/cursorsdk/client.nim`: `call` gained and forwards `timeoutMs`;
  `waitLiveRun` passes `timeoutMs = 0`; `ClientOptions.unaryTimeoutMs`
  doc comment notes the exemption.
- `tests/t_bridge.nim`: removed dead `sawOutput`; removed unused
  `std/tables` import.
- `tests/t_live.nim`: comment explaining why the cancel test accepts
  `rlsFinished`.

Nothing was compiled or run as part of this pass.

## 5. Left alone on purpose

- `killProcess` duplication across the two test binaries.
- `manifest.json` `sdkVersion` assertion (see above).
- Cloud `cwd` guard in `Agent.createAgent` (out of scope).
- Quick start `defer: waitFor client.close()` pattern (works; untested).
