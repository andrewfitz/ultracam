# Simplification implementation and regression results

Implemented 2026-11-03 against host `27eca32e7b08d86737779eb66eeae409cba6d389` plus the existing working-tree performance changes. Six GPT-6.1 Sol agents supplied the original audit; implementation used scoped Sol agents and a separate source review, followed by integrated validation. Changes remain uncommitted. Existing MonitorKit and host performance changes were preserved.

## Changes

| Report entries | Result |
| --- | --- |
| S01–S03 | Removed unused recording counters, stale cache constants/eviction argument, and unread FeedSession generation/failure machinery. Kept native capture generation fences and actual GPU completion/eviction policy. |
| S04 | Hoisted the identical LUT supported-format set into private immutable static storage. Admission and layout validation are unchanged. |
| S05 | Snapshot-only camera leaves update one snapshot instead of building a whole live session. Kept drive lookup before camera lookup, including missing-camera behavior, to preserve low-space alert updates and observation. Drive-lookup elimination is intentionally deferred. |
| S06 | Pending automatic decision ID and target now form one optional value. Existing acknowledgment, rejection, expiry, stop and clock-rebase paths retain their order. |
| S07–S08 | Removed the unpopulated capture-demand mirror and unused per-session fan-out. Kept AppModel's live demand policy, session running state, capture-pool guards, direct Program delivery, and generic FrameFanOut. |
| S09 | Removed the test-only Swift natural director and director-specific coordinator state/hooks. Moved the persisted mode enum into SwitcherCoordinator. Kept the live Rust director, fixed-interval policy, generic acknowledgments, health/readiness and Program scheduling. |
| S10 | Removed direct owner-wide claims; all claims use actual UUID-scoped sessions. Tests now exercise acquisition/release through those sessions. |
| S11 | Removed duplicate standalone MonitorFeedHost invocation from aggregate CI; retained the standalone script and the suite in the main test executable. |
| S12 | Consolidated full suite discovery/count/skip verification into check-test-coverage.py. Registered suites must have compiled source declarations; missing registration, duplicate registration, extension methods and partial runtime coverage have regression checks. |
| S13 | Registered both source-profile declaration tests in the actual app test binary with MainActor isolation. Removed the source-extraction compiler script and special discovery exception. |
| S14 | Added historical-status/current-guidance notes to the two old implementation maps without rewriting their dated observations. |

Net production source reduction relative to the starting working tree: **1,078 lines**. This describes size, not a measured performance improvement.

Project regeneration removed retired source references and also added the existing RecordingLUTRenderer.swift and RecordingLUTBurnIn.swift files missing from the checked-in project. These canonical additions are required for the current shipping source tree; they are not new LUT features from this pass.

## Regression results

| Check | Result |
| --- | --- |
| Unsigned production Release build and bundle validation | Passed; host/extension built and bundle metadata/resources validated |
| Built Release app self-test | 39 passed, zero failures; no live-camera mode |
| Optimized full app XCTest | **1,625 passed, zero failures, zero skips**, 294.969 seconds wall time |
| Complete source/runtime suite accounting | Passed: 171 suites, 1,625 declared methods accounted for |
| Required GPU proof/skip check | Passed; no skipped app tests |
| Strict offscreen UI verification | **1,867 passed, zero failures, zero pending**, 293 images, 209 seconds |
| Rust release tests, locked dependencies | 27 passed (25 core, 2 streaming); no failures |
| Vendor contract aggregate | 166 tests passed across BuildContracts, VendorSDK, BundleContracts, BoundaryContracts, CIContracts and CPUPixelContracts; canonical generation and boundary checks passed |
| Diagnostic contracts | 10 passed |
| Discovery, settings-intent, ownership, app-source integration and standby scripts | Passed |
| Isolated coordinator regression run | 11 passed under strict concurrency and warnings as errors |
| Diff whitespace and final input integrity | Passed; no validated source/test/script/tool/vendor inputs changed during the successful runtime checks |

The full run includes the new snapshot follow-mode/fixture/loss-age parity test, claimed-session failure/stop/deinit coverage, generic acknowledgment/fixed-interval latch regression, and actual declaration tests. The broad runtime suite also exercises capture lifecycle, automatic demand, Program routing, recording and GPU behavior.

One initial app test compilation was invalidated by a whitespace edit to a test file while the compiler was running. It was discarded and rebuilt successfully with edits frozen; no failed or partial run was counted as a pass. The first direct Rust test invocation lacked the toolchain's rustc path; the successful invocation used the same explicit RUSTC/RUSTDOC setup as the repository script.

The app test binary was built with `scripts/test.sh --app-compile-only`, then run in full, followed by the complete coverage and GPU-skip checkers. This separates app regression evidence from the standalone MonitorKit test suite, which was not rerun. MonitorKit package products were built from the existing dirty submodule; prior standalone package failures documented in PERFORMANCE_OPTIMIZATION_20261102.md are not cleared by this work.

## Deferred work and limits

Whole-cache rollback snapshots, PCM ownership copies, combined audio/tick FFI, planar conversion setup, and monitor diagnostics scheduling remain profiling candidates. No new caching, resource rings, ABI, shader math, or clock conversion was introduced. No throughput or latency improvement is claimed from this pass's UI or source-level operation reductions.

No signed installation, live physical camera/Sony session, or third-party virtual-camera consumer qualification was performed. The successful synthetic and unsigned checks do not establish those hardware/deployment results.

## Evidence and reproduction

Logs, baseline/final diffs, source hashes and final integrity results:
`/Volumes/8TB/cinesomatic-build/simplification-implementation-20261103`.

Key receipts: `shipping-build.log`, `app-self-test.log`, `app-compile-retry.log`, `app-tests.log`, `app-coverage.log`, `gpu-proof-check.log`, `ui-verify.log`, `rust-tests.log`, `contracts.log`, `validated-source-hashes.json`, and `final-input-integrity.json`. Isolated coordinator evidence is under the audit directory's `switcher-remediation` folder.

Use `ULTRACAM_WORK_ROOT=/Volumes/8TB/cinesomatic-build/simplification-implementation-20261103` with the repository build/test/UI scripts. The successful full test executable is recorded in `app-compile-retry.log`; run it with `ULTRACAM_SHADER` pointing to the checkout's `Sources/App/LUTShaders.metal`, then invoke `scripts/check-test-coverage.py` and `scripts/check-gpu-proof-skips.py --app` on its runtime log with `ULTRACAM_REQUIRE_GPU_PROOFS=1`.
