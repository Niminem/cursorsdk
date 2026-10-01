# TODO

Consolidated from `notes.md` and `notes2.md`, re-checked against the working
tree at `892a257` (bridge pin `v1.0.35`, Nim 2.2.10). Items that both notes
reported as fixed were verified in the code and are not repeated here; items
that only matter for cloud agents are dropped (see the end). `t_codecs` and
`t_bridge` were run on Windows while preparing this list (all green);
`t_live` was not run in this session, but was ran just before- all passed.

Target platforms: Windows x64 and macOS. Linux is "should work, untested".

Out of scope by decision (do not add back): CI configuration, git commits or
tags made by an agent, publishing to the Nimble package index, release
preparation. All verification is local; the owner reviews and commits diffs.

## (a) Must fix before calling the repo complete

- [x] **Verify the protocol after the handshake.** `protocol.md` says to
  `Ping` then `GetVersion` and check `protocol_version == "sdk.v1"`; the
  client only checks `manifest.json` on download, so a `CURSOR_SDK_BRIDGE_BIN`
  override (or a cache someone copied by hand) is never protocol-checked. One
  `GetVersion` in `startImpl` raising `BridgeError` on mismatch closes it.
  Files: `src/cursorsdk/client.nim` (`startImpl`), `tests/t_bridge.nim`.
  Done 2026-10-01: `startImpl` calls `GetVersion` before publishing `rpc`;
  a managed bridge that fails it is shut down. Tested against a fake bridge
  answering `sdk.v2`. Also fixed while here: `Client.start` cached a future
  that failed before its first `await` (the reset callback is `callSoon`'d
  and `await` on a finished future does not yield), so a synchronous
  validation failure was sticky for an immediate retry.
- [x] **Validate URL/token pairs before launch.** `buildArgs` emits
  `--tool-callback-auth-token ""` (and the store equivalent) whenever only the
  URL is set, and `bridgeUrl` without `bridgeToken` is accepted; the protocol
  calls "only one of the pair" a startup error, and the Python adapter rejects
  it up front. Raise `BridgeError` client-side with a clear message.
  Files: `src/cursorsdk/client.nim` (`startImpl`), `src/cursorsdk/bridge.nim`
  (`buildArgs`), `tests/t_bridge.nim`.
  Done 2026-10-01: `bridge.requirePair` (exported); `launchBridge` checks
  both callback pairs before spawning, `startImpl` checks
  `bridgeUrl`/`bridgeToken`. Tested for all three pairs plus the raw
  `launchBridge` path.
- [x] **Expose `maxBody` on the callback server.** `newAsyncHttpServer`
  defaults to 8 MiB; a larger `Content-Length` callback body gets a bare HTTP
  413, not a Connect error. Custom stores send `checkpoints.create/update`
  with a base64 conversation blob that grows with the agent, so a long-lived
  agent on a custom store can hit this silently. Add
  `newCallbackServer(maxBody = ...)` and consider `BridgeInfo.maxMessageBytes`
  as the default when the discovery line advertises it.
  Files: `src/cursorsdk/callbacks.nim`, `src/cursorsdk/bridge.nim`
  (`BridgeInfo`), `README.md` (Custom stores).
  Done 2026-10-01: `newCallbackServer(maxBody = DefaultCallbackMaxBody)`,
  64 MiB. `BridgeInfo.maxMessageBytes` is not a usable default: the
  server must be bound (its URL goes on the bridge command line) before
  the bridge that would advertise the value exists. Documented in the
  README, including that `asynchttpserver` applies the cap to
  `Content-Length` bodies only.
- [x] **Clean compile of `src/`.** `types.nim:193` `protoName(e:
  RunLifecycleStatus)` is the only `protoName` with no serializer and emits
  `XDeclaredButNotUsed` on every build of every dependent (confirmed with
  `--hints:on`). Delete it (no request field carries a `RunLifecycleStatus`).
  Files: `src/cursorsdk/types.nim`.
  Done 2026-10-01; `nim c --hints:on --warnings:on src/cursorsdk.nim` is
  silent for `src/`.
- [x] **Fix two stale doc comments.** `ClientOptions.onBridgeOutput` says
  "bridge stderr lines" but receives merged stderr+stdout (as
  `BridgeLaunchOptions.onOutput` and the README already say); the module list
  in `cursorsdk.nim` omits `cursorsdk/version`, which it exports.
  Files: `src/cursorsdk/client.nim`, `src/cursorsdk.nim`.
  Done 2026-10-01.
- [ ] **Run `t_live` once on each target platform** against the final code
  and record the result (date, OS, bridge version, model) in the README
  Testing section or a `CHANGELOG`. The last two review passes compiled but
  did not run it; the Windows cancel/relaunch and kill-mid-run tests have no
  other coverage.
  Files: `tests/t_live.nim`, `README.md`.
  Windows done 2026-10-01 (bridge 1.0.35, `composer-2.5`, 11/11; two
  `EBUSY` skips, plain-delete-fails line, no post-cancel crash that run;
  recorded in README Testing). macOS still open.

## (b) Nice to have

- [x] **`BridgeLaunchOptions.extraArgs`** (plus a `ClientOptions`
  passthrough) so `--max-concurrent-agents` / `--max-message-bytes` can be set;
  they have no env-var equivalent, unlike `--host` / `--port`
  (`CURSOR_SDK_BRIDGE_HOST/PORT` via `ClientOptions.env`).
  Files: `src/cursorsdk/bridge.nim`, `src/cursorsdk/client.nim`, `README.md`.
  Done 2026-10-01 as `BridgeLaunchOptions.extraArgs` /
  `ClientOptions.bridgeArgs`; `t_bridge` passes `--max-concurrent-agents 3`
  and checks it comes back on the ready line.
- [ ] **Honour `BridgeInfo.maxConcurrentAgents` / `maxMessageBytes`.** Parsed
  from the discovery line but never consulted; at minimum use
  `maxMessageBytes` as the callback-server default (see (a)).
  Files: `src/cursorsdk/bridge.nim`, `src/cursorsdk/callbacks.nim`.
  2026-10-01: the "at minimum" part is not feasible (the callback server is
  bound before the bridge launches; see the (a) note). `maxBody` is a
  constructor parameter instead. `maxConcurrentAgents` still unused.
- [x] **Assert `manifest.json` `sdkVersion == BridgeVersion`** in
  `verifyManifest`, as `versioning.md` recommends. Low risk today because the
  cache dir is keyed by version, so pair it with the clean-cache download
  check in the definition of done rather than fixing blind.
  Files: `src/cursorsdk/bridge_fetch.nim`.
  Done 2026-10-01; exercised on Windows with a forced re-download
  (`nim r src/cursorsdk/bridge_fetch.nim --force`): checksum and manifest
  (protocol + sdkVersion 1.0.35) passed.
- [x] **Close the socket when a unary deadline fires.** `unary` detaches the
  future but leaves the connection open until the bridge answers or closes;
  only matters for a hung bridge.
  Files: `src/cursorsdk/connect.nim`.
  Done 2026-10-01 (`ConnSlot` shared between `unary` and `unaryImpl`).
- [ ] **Re-export `std/tables` and `std/json` from `types.nim`** (or
  `cursorsdk.nim`). `Table` and `JsonNode` are part of the public surface
  (`mcpServers`, `customTools`, `extra`, tool handlers); the README currently
  documents the extra imports instead. Design decision, either is fine.
  Files: `src/cursorsdk/types.nim` or `src/cursorsdk.nim`, `README.md`.
- [ ] **Compile-check the README fragments as a test.** Both review passes
  found non-compiling snippets by hand (`some(@[])`, missing imports). A
  compile-only `tests/t_readme.nim` (fragments wrapped in procs that are
  never called; no network) would catch the next one, including the Quick start's
  `defer: waitFor client.close()` inside an `{.async.}` proc.
  Files: new `tests/t_readme.nim`, `README.md`.
- [ ] **Advance `lastOffset` for unknown-but-non-empty envelopes.** `Run.next`
  skips unknown envelope cases before `track`, so a future envelope type that
  carries an offset would be replayed on `observe`. Trivial; "offsets you
  processed" is also a defensible reading.
  Files: `src/cursorsdk/run.nim`.
- [ ] **Narrow the bridge-exit race in `Run.wait`.** Detection relies on the
  `bekExited` event having been drained after one `sleepAsync(0)`; if the
  exit lands later (the Windows post-cancel crash takes ~1 s), `wait()` falls
  through to `WaitLiveRun` on a dead port and raises a connect-refused
  `TransportError` instead of "run ... lost". Same error class, different
  message; already covered by the README's "an RPC that races the crash can
  fail once". A short bounded poll of `bridge.hasExited` would tidy it.
  Files: `src/cursorsdk/run.nim`.
- [x] **Unify `killProcess` in `tests/t_live.nim`** with the `winlean`
  `TerminateProcess` helper now in `t_bridge.nim` (drops the `taskkill` /
  `cmd.exe` dependency). Left alone last time only because `t_live` could not
  be run.
  Files: `tests/t_live.nim`.
  Done 2026-10-01; the kill-mid-run live test passed with it.
- [x] **Document the in-memory store's assumed output shapes** in the custom
  store test: `runEvents.append -> {"offset": "<n>"}` and `runEvents.list ->
  {"events": [...]}` are guesses; `services.md` specifies only the inputs.
  Not asserted, so they cannot cause a false pass, but they are the first
  thing to check if a future bridge calls `runEvents.list` on a custom store.
  Files: `tests/t_live.nim`.
  Done 2026-10-01 (comment in the `runEvents` branch).
- [x] **Nimble packaging hygiene.** Add `skipDirs = @["tests", "vendor"]`
  and skip `notes*.md` / `TODO.md` so an installed package does not carry the
  submodule and review notes.
  Files: `cursorsdk.nimble`.
  Done 2026-10-01 (`skipDirs` + `skipFiles`; `nimble check` passes).

## (c) Upstream bridge behaviour (bridge 1.0.35) we document or work around

Nothing to fix here; re-test each on the next bridge pin and drop the
workaround or the README paragraph when upstream resolves it.

- **Windows `EBUSY` on `DeleteAgent` after a turn.** The bridge keeps
  `agents/<id>/store.db` + WAL open for the life of the process and `rm`s the
  directory without closing it; POSIX unlinks fine, Windows refuses. Skipped
  in `t_live` via `deleteAfterRunWorks`; documented under "Notes on this
  bridge release". `delete(force = true)` on a never-run agent works
  everywhere. Consider filing it on `cursor/sdk-bridge` if not already
  reported.
  Files: `tests/t_live.nim`, `README.md`.
- **Windows Bun assertion crash (exit 3) ~1 s after a successful
  `CancelRun`.** Worked around by auto-relaunch (`ClientOptions.autoRelaunch`,
  `onBridgeRelaunch`, `Client.relaunches`, `Agent.ensureLoaded`,
  `Run.relaunchesAtStart`), which is beyond the upstream design (dead bridge
  is fatal there) and kept as general hardening with an opt-out. Costs one
  `TransportError` on anything racing the crash.
  Files: `src/cursorsdk/client.nim`, `src/cursorsdk/agent.nim`,
  `src/cursorsdk/run.nim`, `tests/t_live.nim`, `README.md`.
- **`CreateAgent` pre-creates a `queued` run**, so a plain `delete()` on a
  fresh agent fails with "active run ... is not terminal". Not documented
  upstream (observed through a custom store). Worked around by
  `Agent.delete(force)` / `cancelNonTerminalRuns`; `t_live` prints whether the
  plain delete starts succeeding.
  Files: `src/cursorsdk/agent.nim`, `tests/t_live.nim`, `README.md`.
- **`GetUsage` on a local agent returns `InternalError` with
  `feature_unavailable` in the message** instead of
  `SDK_ERROR_CODE_FEATURE_UNAVAILABLE` (which would map to `PermissionError`
  per `errors.md`). README documents the observed behaviour; re-check on the
  next pin and update the README if the mapping changes.
  Files: `README.md`, `src/cursorsdk/errors.nim`.
- **`--verbose` is accepted but absent from the upstream CLI table.** Used
  for `ClientOptions.verbose`; if a future bridge drops it, startup fails
  with "unknown option" captured in `BridgeError.stderr`. Documented under
  Debugging.
  Files: `src/cursorsdk/bridge.nim`, `README.md`.
- **Upstream doc gaps worth reporting**: `services.md` omits `ReloadAgent`
  from its RPC table (it is in the proto and implemented here) and does not
  specify the output shapes of `runEvents.list` / `runEvents.append` for
  custom stores.

## Definition of done

Code
- [ ] All (a) items above closed. (2026-10-01: all code items closed; only
  the macOS `t_live` run remains.)
- [x] `nim c --hints:on --warnings:on src/cursorsdk.nim` produces no hints or
  warnings originating in `src/`. (Windows, 2026-10-01.)
- [ ] `verifyManifest` and a clean-cache download exercised once on Windows
  and once on macOS (delete `getCacheDir("cursorsdk")/1.0.35`, run
  `nimble fetchBridge`, confirm checksum + manifest pass).
  Windows done 2026-10-01 via a forced re-download (same code path as a
  clean cache: download, checksum, manifest incl. `sdkVersion`, move into
  place). macOS open.

Tests
- [ ] `nimble test` green on Windows x64 and macOS (arm64; x64 too if a
  machine is available): `t_codecs`, `t_bridge`, and `t_live` with a key.
  Windows x64 done 2026-10-01: `t_codecs` 25/25, `t_bridge` 13/13,
  `t_live` 11/11 (run individually with `nim c -r`). macOS open.
- [x] `t_live` results recorded (platform, date, bridge version, model); the
  Windows `EBUSY` skips and any cancel-crash relaunch are visible in the log
  and match the README. (Windows, 2026-10-01, README Testing. The cancel
  test did not crash the bridge on this run, which the README allows.)

README
- [ ] Platform line under Install reflects what was actually run (currently
  "macOS (x64) and Windows"; add arm64 if tested).
- [ ] Every code fragment compiles (ideally via `tests/t_readme.nim`).
- [ ] "Notes on this bridge release" still matches observed 1.0.35
  behaviour; no item in (c) has been fixed upstream without the README
  noticing.

Versioning
- [ ] `cursorsdk.nimble` `version`, `version.nim` `BridgeVersion`,
  `vendor/sdk-bridge` submodule tag, and `proto/manifest.json` `sdkVersion`
  all agree (currently `1.0.35`); a package-only fix bumps a fourth component
  (`1.0.35.1`) per the README's Versioning section.
- [ ] `notes.md` and `notes2.md` removed (superseded by this file) and
  `TODO.md` trimmed to whatever is still open.

Nimble package (local verification only; no publishing)
- [x] `nimble check` passes (it does today). (Re-checked 2026-10-01 after
  the `skipDirs`/`skipFiles` change.)
- [x] `skipDirs` set so the installed package excludes `tests/`, `vendor/`,
  and the notes. (2026-10-01.)
- [ ] Fresh-clone install works on both platforms from a local path:
  `git clone --recursive <local repo> && nimble install`, then the Quick
  start runs against a real key.

## Dropped (resolved or out of scope)

- Already fixed and verified in the tree: `WaitLiveRun` with no deadline
  (`timeoutMs = 0`), README link/`some(@[])`/import-note/`.exe`/`Shutdown`
  fixes, `t_bridge` dead `sawOutput`/`pid` and unused imports, Windows
  `pidAlive` in `t_bridge`, cancel-test comment in `t_live`,
  `fillDefaults` cloud guard on the wire request.
- Cloud-only: `AgentOptions.cloud`, `SendOptions.cloud`,
  `ListAgentsOptions.pr_url`, `GetRunOptions.runtime`, and the handle-side
  `local.cwd` guard in `Agent.createAgent` (only reachable through
  `extra["cloud"]`).
- Accepted as is: `killProcess` duplicated across the two test binaries
  (separate programs, three lines); the weak "tool callback re-applied on
  relaunch" check (no RPC reads it back; the live custom-tool test covers the
  real path); auto-pagination only in `cancelNonTerminalRuns`; exit-time kill
  by PID without a `Shutdown` RPC (allowed by `protocol.md`); the merged
  stdout/stderr, `poDaemon`, `TerminateProcess`/`SIGKILL`, and path
  canonicalisation deviations (all documented, all in-spec).
