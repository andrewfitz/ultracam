# Ultracam Full Bug Audit and Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Find, prove, and fix reachable defects in Ultracam, prioritising code changed since the 2026-11-21 first-party audit, with a regression test for every fix.

**Architecture:** First make the tree reproducible (version control, a single Auto Switcher source, every package's tests wired into `scripts/test.sh`). Then run six read-only audit lanes, one per subsystem, that write rows into a single findings ledger. After a triage gate, fix each confirmed finding test-first. Finish with one full verification run.

**Tech Stack:** Swift 5 mode with `-strict-concurrency=complete -warnings-as-errors`, Metal 4, XCTest via the `swiftc` harness in `scripts/test.sh`, SwiftPM packages, Rust (`cargo test --locked`), Python `unittest` contract tests.

**Spec:** No separate spec. The scope comes from the user's request ("full bug audit and fix for the ultracam app") and the open items in `docs/FIRST_PARTY_AUDIT_20261121.md`, `docs/MAC_CAMERA_VALIDATION.md`, and `VALIDATION.md`.

## Global Constraints

- Deployment target is macOS 26 on Apple silicon with Metal 4. Do not add any Metal 3 or CPU fallback.
- Test compilation stays at `-swift-version 5 -strict-concurrency=complete -warnings-as-errors`. A fix must not add warnings or `@unchecked Sendable` without a written justification in the ledger.
- Do not edit vendored SDK code (`Vendors/*/` SDK payloads, `ThirdParty/`). In `Packages/HaishinKitRTMP`, change only the Ultracam extensions named in its README: Enhanced RTMP AV1 signalling, destination codec checks, and the shared A/V epoch.
- `../MonitorKit` is out of scope. Ultracam-side integration bugs are in scope. A defect inside MonitorKit is logged with `owner: MonitorKit` and not fixed in this plan.
- Do not install or publish anything, do not run a privileged camera-extension reload, and do not run `--official-release` without explicit user approval for that step.
- A ledger row may not claim hardware behaviour without a hardware run. Synthetic evidence is labelled `synthetic`.
- Build and test output goes to `ULTRACAM_WORK_ROOT`, which defaults to `.build/`. Never write artifacts elsewhere in the checkout.
- A finding counts only when it is **reachable**: the ledger row names the production call path that triggers it. Isolated mechanisms that are caught, unreachable, or deliberate are dispositioned `not-a-bug`.

## Review Focus

1. **Stream reconnect under load.** An RTMP or RTMPS disconnect during a cut, while an ISO recording runs, should reconnect once, after the configured delay, keep the selected stereo pair, and keep A/V offset within the existing ±50 ms receiver threshold. Owned by Task 4.
2. **First samples from a Mac camera.** A zero-PTS or out-of-order first video sample (see `docs/MAC_CAMERA_VALIDATION.md:25`) must not become the session epoch or a recording's first timestamp. Owned by Task 5.
3. **Device removed mid-take.** Unplugging the active input during recording or streaming should finalize a playable partial and report a problem without leaving the device claimed. Owned by Tasks 5 and 7.
4. **Inspector open with four live meters.** Opening the inspector with four cameras and live meters stalls the main thread for 436–845 ms against a 250 ms budget (`docs/FIRST_PARTY_AUDIT_20261121.md:57-62`). Owned by Task 6.
5. **Settings saved by an older build.** Stream profiles, vendor settings, and Mac camera selections saved before the 2026-11-21 changes must load with their destination and format intact, or fail with a visible message. Silently falling back to defaults is a bug. Owned by Task 6.

---

## Ledger format (used by Tasks 2–11)

Create `docs/BUG_AUDIT_20261122.md` with one table. Every lane appends rows to it.

| Column | Content |
|---|---|
| `id` | `A-<lane>-<nn>`, e.g. `A-STREAM-03` |
| `title` | One sentence that describes the behaviour, readable without the id |
| `location` | `path:line` |
| `trigger` | Concrete input or state sequence on a production path |
| `impact` | What the operator sees or loses |
| `evidence` | Log path, reproducer test name, or measured number |
| `severity` | `P0` data loss or crash, `P1` wrong output or stuck state, `P2` degraded or recoverable, `P3` cosmetic |
| `status` | `open`, `confirmed`, `fixed`, `not-a-bug`, `deferred`, or `owner: MonitorKit` |
| `test` | Regression test name once written |

---

### Task 1: Make the tree reproducible

**Files:**
- Create: `.gitignore` (`.build/`, `**/target/`, `**/build/`, `*.xcuserstate`, `DerivedData/`)
- Modify: `scripts/auto_switcher_source.py`
- Delete, after the user approves: `Apps/AutoSwitcher_Mac-Studio.local_Nov-22-002055-2026_Conflict/`, `Tools/auto-switcher_Mac-Studio.local_Nov-21-232459-2026_Conflict/`, and `Tools/auto-switcher/` if it is superseded
- Test: `Tests/BuildContracts/test_auto_switcher_source.py`

**Current state:** The checkout has no `.git`. `Apps/AutoSwitcher` has no `src/lib.rs`, `src/llm.rs`, or `src/offline.rs`, so `scripts/auto_switcher_source.py:7` silently falls back to `../auto-switcher`. Both `*_Conflict` copies contain those files, but their `director.rs` and `model.rs` differ from the other copies. Four Auto Switcher trees exist.

**Interfaces:**
- Produces: `auto_switcher_source(root: Path) -> Path` returns `root / 'Apps/AutoSwitcher'` only. It raises `ValueError` naming the missing files and no longer falls back to a sibling checkout.

- [ ] **Step 1: Snapshot before touching anything.** Run `tar -czf ../ultracam-pre-audit-20261122.tgz --exclude=.build --exclude=target -C .. ultracam ../auto-switcher` and check that the archive lists `ultracam/README.md` and `auto-switcher/src/lib.rs`.
- [ ] **Step 2: Reconcile Auto Switcher with the user.** Produce `diff -ru` output across `Apps/AutoSwitcher`, `../auto-switcher`, and both conflict copies for `src/` and `tests/`. The user chooses the canonical file set. Copy it into `Apps/AutoSwitcher`.
- [ ] **Step 3: Write the failing test** `test_requires_in_repo_source`. Build a temp root with a complete `../auto-switcher` and an incomplete `Apps/AutoSwitcher`, then assert `ValueError` and that the message contains `src/lib.rs`. Add `test_rejects_conflict_copies`, which asserts that no path matching `*_Conflict` exists under `Apps/` or `Tools/` in the real checkout.
- [ ] **Step 4:** Run `python3 -m unittest discover -s Tests/BuildContracts -v`. Expected: both new tests FAIL.
- [ ] **Step 5:** Remove the sibling fallback in `auto_switcher_source.py`. Delete the conflict directories once the user confirms.
- [ ] **Step 6:** Re-run Step 4. Expected: PASS. Then run `cargo test --locked --manifest-path Apps/AutoSwitcher/Cargo.toml`. Expected: PASS.
- [ ] **Step 7:** Run `git init`, add the `.gitignore`, and commit `chore: baseline before 2026-11-22 bug audit`. If the user prefers to clone `github.com/andrewfitz/ultracam` and overlay this tree, do that instead.

### Task 2: Green baseline and ledger

**Files:**
- Create: `docs/BUG_AUDIT_20261122.md` (ledger header from the section above, plus an environment block)

- [ ] **Step 1:** Record the Xcode, Swift, rustc, and macOS versions, the `../MonitorKit` tree hash (`find ../MonitorKit/Sources -type f | sort | xargs shasum | shasum`), and `python3 scripts/vendor-sdk.py status`.
- [ ] **Step 2:** Run `bash scripts/build.sh`. Expected: exit 0. Each warning or failure becomes a ledger row with `evidence` set to the build log path.
- [ ] **Step 3:** Run `bash scripts/test.sh`. Expected: exit 0, with the per-suite count from `check-test-coverage.py` matching the 1,836 tests across 177 suites recorded in `VALIDATION.md`. Each failing test becomes a row. Re-run flaky tests with `ULTRACAM_TEST_SUITES=<Suite>`; a test that fails at least once in 5 runs becomes a `P2` row titled "flaky: …".
- [ ] **Step 4:** Run `bash scripts/app-self-test.sh`. Expected: 39 of 39 checks pass.
- [ ] **Step 5:** Commit `docs: baseline for 2026-11-22 audit`.

### Task 3: Run every package's tests from `test.sh`

**Files:**
- Modify: `scripts/test.sh` (after the MonitorKit package block, around line 70)
- Test: `Tests/CIContracts/test_package_coverage.py`

**Current state:** `scripts/test.sh` never runs `swift test` for `Packages/HaishinKitRTMP`, `Packages/ProgramAV1`, or `Packages/MonitorTools`. The stream transport, including Ultracam's RTMP patches, has no automated gate.

- [ ] **Step 1: Write the failing test** `test_every_package_with_tests_is_run`. For each `Packages/*/Package.swift` that has a sibling `Tests/` directory, assert that `scripts/test.sh` contains `--package-path "$task_root/Packages/<name>"`.
- [ ] **Step 2:** Run `python3 -m unittest discover -s Tests/CIContracts -v`. Expected: FAIL for 3 packages.
- [ ] **Step 3:** Add a `package_test <name>` shell function to `test.sh`. It runs `xcrun swift test --package-path … --scratch-path "$test_root/pkg-<name>"`, logs to `$logs_root/<name>-tests-$run_id.log`, and exits non-zero on failure. Call it for all three packages, skipping them under `--app-compile-only`.
- [ ] **Step 4:** Re-run Step 2. Expected: PASS. Run `bash scripts/test.sh`. Expected: exit 0. Each newly exposed package test failure becomes a ledger row.
- [ ] **Step 5:** Commit `test: run streaming and monitor-tools package tests`.

### Tasks 4–9: Audit lanes (read-only, parallelisable)

Each lane reviews only its listed paths, writes ledger rows, and changes no product code. Every row must pass the reachability rule. When a lane can write a reproducer as a failing test cheaply, it does so in the test file named for that lane and leaves the test unregistered in `Tests/main.swift` until Task 11.

Every lane checks these classes: actor isolation and `@unchecked Sendable` correctness; callback and continuation completion on every path, including cancellation; teardown and reentrancy ordering (stop during start, start during stop); `CVPixelBuffer`, `IOSurface`, and `MTLBuffer` lifetime across GPU completion; integer and `CMTime` overflow, rounding, and timescale mixing; errors that are swallowed or downgraded to defaults; persistence decode of older payloads; and unbounded queues or allocations on per-frame paths.

| Task | Lane | Paths | Changed since 11-21 | Lane-specific focus |
|---|---|---|---|---|
| 4 | `STREAM` | `Sources/Program`, `Packages/HaishinKitRTMP/Sources/RTMPHaishinKit` (Ultracam patches), `Packages/ProgramAV1`, stream parts of `Sources/App` | 157 files | Review Focus 1; reconnect deadline paths; TLS/RTMP handshake cancellation; AAC and video epoch after first-picture drop; AV1 encoder backpressure; stream-key handling in logs and profiles |
| 5 | `MACCAM` | `Vendors/MacCamera`, `Sources/DeviceAPI`, `Tools/MacCameraProbe` | 17 files | Review Focus 2 and 3; variable-rate declaration changes; device-lock lifetime; authorization denial and revocation; microphone pairing clock mapping |
| 6 | `APP` | `Sources/App` (excluding stream parts), `Config/App-Info.plist` | 45 files | Review Focus 4 and 5; main-actor work on inspector open (profile with `xctrace` Time Profiler on the UI-verify four-camera live-meter fixture); stale presentation after a feed stops |
| 7 | `REC` | `Sources/Recording`, `Sources/Shared` | 14 files | Review Focus 3; claim and reservation release on every error path; timecode across clock jumps; recovery when the final name is taken |
| 8 | `AUTOSW` | `Apps/AutoSwitcher/src`, `include/auto_switcher.h`, Swift bridge and timeline in `Sources/App` | 19 files | C ABI ownership (who frees each pointer); header and Rust signature parity; `cargo clippy -- -D warnings`; checkpoint write failure and backoff |
| 9 | `EDGE` | `Sources/CameraExtension`, `Sources/CameraProvider`, `Vendors/Blackmagic`, `Vendors/Sony`, `scripts/`, `Tools/` | about 40 files | Delta review only, against the 11-21 audit's fixed list; shell `set -euo pipefail` and exit-status propagation; scripts that silently pick a different source tree (the same class as Task 1) |

- [ ] **Step 1 (per lane):** Read the lane paths and append ledger rows.
- [ ] **Step 2 (per lane):** For each row with a reproducer, run `ULTRACAM_TEST_SUITES=<Suite> <test binary>`, Rust `cargo test <name>`, or package `swift test --filter <name>`. Expected: FAIL. Record the result in `evidence`.
- [ ] **Step 3 (per lane):** Commit `docs: <lane> audit findings`.

### Task 10: Triage gate

- [ ] **Step 1:** Merge duplicate rows across lanes and keep the lowest id. Set each row's `severity` and change `open` to `confirmed`, `not-a-bug`, or `deferred`, with a one-line reason.
- [ ] **Step 2:** Present the confirmed P0 and P1 rows to the user, and the P2 and P3 counts. The user approves the fix list before Task 11 starts.

### Task 11: Fix loop, one cycle per confirmed finding, in severity order

**Files (per finding):**
- Test: an existing suite in `Tests/<Area>Checks.swift` when one covers the area. Otherwise create a new suite and register it in `Tests/main.swift` with `suite.addTest(XCTestSuite(forTestCaseClass: <Suite>.self))`. `check-test-coverage.py` fails if registration is missing. Rust tests go in `Apps/AutoSwitcher/tests/`. Package tests go in that package's `Tests/`.
- Modify: the `location` from the ledger row

- [ ] **Step 1:** Write the regression test. Name it `test<Behaviour>` after the ledger title, and assert the operator-visible outcome.
- [ ] **Step 2:** Run it alone, e.g. `ULTRACAM_TEST_SUITES=<Suite>`. Expected: FAIL with the symptom from the row.
- [ ] **Step 3:** Make the minimal fix at the root cause.
- [ ] **Step 4:** Re-run Step 2. Expected: PASS. Then run `bash scripts/test.sh --app-compile-only`. Expected: exit 0 with no new warnings.
- [ ] **Step 5:** Set the row's `status: fixed` and `test`, then commit `fix(<lane>): <title> (A-<lane>-<nn>)`.

After every 5 fixes, or at the end of a lane, run the full `bash scripts/test.sh`.

### Task 12: Final verification and report

- [ ] **Step 1:** Run `bash scripts/build.sh`, `bash scripts/test.sh`, `bash scripts/app-self-test.sh`, `bash scripts/ui-verify.sh`, `bash scripts/recording-recovery-smoke.sh`, and `bash scripts/test-program-cadence-cpu.sh`. Expected: every command exits 0. The test count is at least the baseline from Task 2 plus the new regression tests. ui-verify shows no stall over 250 ms if Review Focus item 4 was fixed; otherwise that row stays `deferred` with the measured number.
- [ ] **Step 2:** If the user approves receiver runs, run `bash scripts/program-stream-smoke.sh <products>` and `bash scripts/program-stream-app-smoke.sh <products> 24 all`. Record the fps and A/V offsets next to the `VALIDATION.md` figures.
- [ ] **Step 3:** Add a summary to the ledger: counts by status and severity, hardware paths not exercised, and deferred rows with reasons.
- [ ] **Step 4:** Commit `docs: 2026-11-22 audit results`.
