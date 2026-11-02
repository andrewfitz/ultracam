# UltraCam and MonitorKit: complete source audit and repair plan

Status: source review, repairs and available local validation finished. See `ULTRACAM_MONITORKIT_DEEP_AUDIT_NOTES.md` for findings, actual test outcomes and remaining hardware/platform limits.

## Objective

Find and fix bugs throughout our UltraCam and MonitorKit code. Review every in-scope production file, trace behavior across subsystem boundaries, exercise failures and lifecycle transitions, and verify each repair against the production path. Existing audit plans and reports are not inputs to this audit or evidence of correctness.

This is a fresh implementation review. Existing tests are useful witnesses, but passing them does not replace reading the code, establishing its intended behavior, and looking for failures the tests do not cover. The audit includes existing committed code and current uncommitted code.

Spend the effort on reading code, following execution paths, reproducing failures, and fixing them. Use existing tests and tools first. Add a small regression or reproducer when it helps expose a concrete bug. Do not build a general audit framework, new harness platform, benchmark suite, exhaustive combination generator, reporting system, or CI project. Do not refactor working code or add speculative hardening to make the audit look productive. Missing tests alone are not bugs.

## Scope

Ownership determines scope, not directory names or repository boundaries. MonitorKit is our code even though it is a Git submodule. Our Blackmagic and Sony adapters are our code even though they live under `Vendors/`.

| Included | Coverage |
|---|---|
| `Sources/App` | App entry point, models, capture coordination, monitoring, GPU processing, recording integration, camera control, settings, diagnostics, and every UI/action path |
| `Sources/DeviceAPI` | Plugin contracts, discovery, claims, frame/audio handoff, memory layout, compatibility conversion, GPU ingest, errors, and observation |
| `Sources/Shared` | Formats, color contracts, GPU decoders, retention, routing, demand, timing, switcher coordination, registry, and transport |
| `Sources/Program` | Program scaling and color description |
| `Sources/Recording` | Writers, pixel/audio conversion, cadence, timestamps, timecode, file lifecycle, metadata, statistics, and recovery |
| `Sources/CameraExtension`, `Sources/CameraProvider` | Extension entry point, authorization, format negotiation, queues, producer/consumer lifecycle, and output |
| `Vendors/Blackmagic/Sources`, `Vendors/Sony/Sources` | Our Swift/native adapters, allocators, discovery, callbacks, worker threads, credentials integration, and SDK error handling |
| `Packages/MonitorKit/Sources` | All five products: MonitorKitCore, MonitorKit, MonitorKitScopes, MonitorKitAudio, MonitorKitUI; all shader text and resource-loading code |
| `Tools/auto-switcher` | Our Rust implementation, C interface, schemas, and Swift bridge |
| Our tests and tools | `Tests`, MonitorKit tests, adapter tests, smoke tools, UI verification, fixtures, and test registration |
| Our build and configuration code | `scripts`, project-generation inputs, `Ultracam.xcodeproj`, `Config`, plugin manifests, package manifest, CI definitions, and relevant resources |

Exclude third-party SDK implementations, headers, dispatch code, binaries, drivers, frameworks, downloaded packages, Rust dependencies, and generated build/cache contents. In particular, exclude `Vendors/*/SDK/**`, third-party contents of `ThirdParty/**`, package checkouts, and Cargo dependency sources. Do not perform an SDK/library audit, dependency upgrade campaign, advisory sweep, or license review.

Review our use of external APIs: arguments, ownership, synchronization, error handling, availability, and fallback behavior. Consult API contracts where needed to establish what our code must do; do not expand this into reviewing their implementation. A suspected external defect is a separately noted limitation unless a bug in our handling can be demonstrated.

Include dormant, fallback, debug-only, and conditionally compiled first-party paths. Identify obsolete paths explicitly instead of silently omitting them. Documentation establishes intended behavior where useful, but implementation and tests must be checked independently.

## 1. Start with the current code

1. Capture UltraCam and MonitorKit revisions, tracked diffs, staged diffs, and untracked source contents before changes. Preserve existing work; do not reset, stash, clean, or overwrite it.
2. List our source files in both repositories, including untracked files, native includes, shaders, and conditional paths. Keep a simple reviewed/not-reviewed checklist so no files get missed. No per-symbol coverage database or mandatory narrative for clean files.
3. Check what the existing builds and test runners actually compile. Note production paths they omit. Run the existing baseline build/tests and record failures and skips; continue source review if a missing device or tool blocks a check.
4. Record environment details relevant to reproducing a failure. Keep build outputs and logs in a run-specific directory using existing tooling.
5. If code changes during the audit, re-read the affected diff and callers. Recheck affected results against the final tree; do not attribute an old passing test to new code.

Use a run-specific `ULTRACAM_WORK_ROOT` outside the source tree, for example `/Volumes/8TB/cinesomatic-build/audits/ultracam-monitorkit/<run-id>`. Use the existing path resolver for derived-data and package-cache locations. Preserve logs before later runs replace convenience links.

## 2. Follow complete execution paths

Trace these paths as the relevant code is reviewed:

- Device discovery → selection → capture start → native callback → admission → frame ownership → GPU ingest → processing → preview, monitor, recording, and camera transport → release.
- Captured audio → packet ownership → clock mapping → metering, recording, and switcher decisions → discontinuity/reset/shutdown.
- Source selection or settings change → persisted intent → route/demand updates → asynchronous work → published UI state and actual output.
- Program cut/failover → selected frame and color description → timestamp mapping → recording and camera consumers.
- App launch → settings migration → device restoration → extension connection; then sleep/wake, disconnect, stop, and quit.

At each boundary, check thread/actor ownership, resource lifetime, queue limits, clocks, cancellation, and failure handling on both sides. Write down or sketch a chain only when it helps reason about a bug. No architecture-documentation project before starting the review.

## 3. Review every subsystem

The order below prioritizes costly failures; every row remains required. Read all implementation files, trace callers and callbacks, and inspect error paths and existing tests. Use the listed failure cases to challenge the code. Construct targeted reproductions where the code or behavior gives a reason to investigate, and repair confirmed defects as they are found.

| Workstream | Deep review and failure cases |
|---|---|
| Recording and recovery | Start/stop/cancel races; partial writer setup; append/finalization failure; source removal during a take; disk-full, permission loss and unavailable folders; naming collisions and overwrite prevention; sidecar/media consistency; interrupted files and recovery idempotence; codec/format eligibility; correct duration, frame count and audio track content |
| Native capture and control adapters | `AddRef`/`Release`, ARC/CF and callback ownership; allocator alignment and bounds; callback-after-stop and callback reentrancy; reconnect generations; delayed cleanup; worker-thread shutdown; signal/format changes; device disappearance; rejected SDK calls; stale discovery; unsigned property values; credential identity and redaction |
| DeviceAPI and frame admission | Plugin identity/claims; format declarations versus delivered bytes; dimensions, stride, plane offsets and buffer sizes; integer overflow; zero-copy eligibility and fallback; queue ordering; stale generations; capture/audio metadata; malformed frames; resources rejected before admission or abandoned after failure |
| Shared GPU processing | Packed/planar/RGB/NDI-layout decode; shader/host ABI; thread bounds; resource hazards; command completion; no-copy memory locks; texture cache identity; allocation budgets; pool exhaustion; standby/warm-up; resize/reformat; failed command buffers; CPU fallback agreement |
| Timing and program output | Rational frame rates; clock conversion and drift; PTS monotonicity; discontinuities and wraparound; cut/failover atomicity; source cadence versus output cadence; duplication/drop policy; color/geometry metadata during switching; concurrent output consumers; isolation from monitor-only changes |
| Camera extension and IPC | Producer authorization; registry validation and publication atomicity; stale generations and leases; queue accounting; format negotiation; client churn; producer death; no-signal fallback; start/stop balance; buffer retention; app/extension restarts; signed runtime behavior |
| App lifecycle and coordination | Actual startup/teardown order; cancellation; overlapping start/stop and selection; route-demand changes; observers/tasks/timers; actor isolation; partial initialization; feed removal; reconnect/backoff; sleep/wake; app quit while recording or GPU work is pending |
| MonitorKitCore | Signal defaults and interpretation; range, matrix, transfer and primaries; log/HDR/SDR conversion; LUT parsing/interpolation/domain; invalid and extreme values; aperture, aspect, crop and de-squeeze math; normalization and persisted state |
| MonitorKit picture engine | Raw/CV frame decode; pixel-buffer and texture ownership; source/output/monitor stage ordering; LUT application; overlays and tool combinations; freeze/unfreeze; target attachment compatibility; sampling geometry; missing drawable; stale caches; unsupported input rejection |
| MonitorKit Metal backends | Classic Metal and Metal 4 parity; Swift/shader structure layout; function constants; argument tables; barriers; residency; resource retirement; out-of-order completion; host command ownership; warm-up and asynchronous specialization; pipeline archives; device capability fallback |
| MonitorKitScopes | Waveform/vector/histogram reference math; bin boundaries and accumulation overflow; range/transfer/stage interpretation; LUT ordering; fused/split equivalence; cadence; resize; multiple surfaces; stale results; GPU resource lifetime and reset |
| MonitorKitAudio | Ring-buffer publication and overflow; packet and channel layouts; sample-rate changes; peak/RMS/VU/PPM/true-peak/loudness math; silence and non-finite values; reset races; discontinuities; channel weighting; windows/gating; callback isolation and teardown |
| MonitorKitUI and host integration | Display-link ownership; rendering/state handoff; layer color spaces and EDR; surface resize/display changes; tiling; scene/view lifecycle; SwiftUI bindings; frozen-frame retention; scope/audio scheduling; selected source/stage; diagnostics reflecting actual render state |
| App UI, actions and settings | Every action/menu/shortcut; model and view agreement; disabled/hidden controls; selection changes during actions; dismissal/cancellation; persistence round trips and migration; malformed settings; device disappearance; errors and recovery; accessibility actions that invoke app behavior |
| Rust switcher and Swift FFI | ABI/layout and string ownership; null/length validation; panic boundaries; event parsing; ordering and timestamps; channel identity; thresholds/hysteresis; stale or missing audio; reset/restart; deterministic decisions; timeline persistence and error propagation |
| Build, resources and test machinery | All source membership and feature configurations; Debug/Release differences; extension isolation; resource/shader loading; generated-project consistency; our embedding/signing/rpath logic; test discovery; false-green scripts; unsafe path handling; subprocess failures; retries/skips masking failures |

Read MonitorKit's platform-conditional code too. Use available platform builds/tests when needed to check those paths; record unavailable validation without starting a separate platform-qualification project.

## 4. Bugs to look for throughout the code

- **Correctness:** preconditions, invariants, state transitions, error returns, partial success, stale state, and behavior at boundaries.
- **Concurrency:** mutable state ownership, unchecked sendability, actor crossings, lock ordering, callback reentrancy, cancellation, completion exactly once, and work arriving after teardown.
- **Lifetime:** retain cycles, leaks, use-after-free, pointer validity, frame/buffer aliasing, GPU in-flight resources, temporary files, handles, and unbounded queues.
- **Media and numerical behavior:** rational timing, A/V sync, color metadata versus pixels, bit depth/range, chroma siting, alpha, rounding/overflow, NaN/Inf, and invalid geometry.
- **Failure recovery:** allocation failure, missing features/resources, device loss, malformed inputs, stalled consumers, failed writes, lost permissions, and recoverability without restarting the app.
- **Local security and privacy bugs:** IPC validation, file paths, credential handling, logging, authorization, and our native input bounds.
- **Capacity and sustained operation:** bounded memory/queues, frame deadline misses, growing resource retention, long sessions, repeated reconfiguration, and recovery after pressure subsides.
- **Test credibility:** production code actually exercised, meaningful assertions, independent expected values, deterministic synchronization, timeout behavior, and explicit skip/retry accounting.

Searches, compiler diagnostics, and static analyzers guide review; none counts as a completed audit by itself. Avoid cosmetic refactors, speculative redesign, and arbitrary performance tuning. Fix demonstrated behavior, safety, resource, or diagnostic defects.

## 5. Prove behavior with existing tools and focused checks

### Existing entry points

Use these existing checks for the behavior under review. Run focused checks after a fix, affected integration checks after a related group of fixes, and the full existing app/package suite plus fresh Debug/Release builds at the end. Do not repeat unrelated expensive checks without a reason.

| Check | Entry points and interpretation |
|---|---|
| Full app/test baseline | `bash scripts/test.sh`; includes package tests, our Rust tool, synthetic app/native checks, and contract checks. Audit its suite registration and skip/retry reporting. It does not prove the installed extension or physical device behavior. |
| Real app builds | `bash scripts/build.sh --debug` and `bash scripts/build.sh`; use fresh derived data and record generated project changes. Build our supported SDK-present/absent variants without auditing the SDK code. |
| Monitor integration | `bash scripts/monitor-feed-host-checks.sh`, `bash scripts/monitor-app-integration.sh` |
| UI and app self-test | `bash scripts/ui-typecheck.sh`, `FORCE=1 STRICT=1 UI_PERF_ONLY=0 bash scripts/ui-verify.sh`, `SKIP_BUILD=0 bash scripts/app-self-test.sh`; verify expected cases actually ran. Cached success, partial runs and pending failures do not count as a full pass. |
| Normal app startup and shutdown | Launch fresh Debug and Release apps without `--ui-self-test`. Check restored settings/connections, alerts and background shortcuts, then quit/relaunch; also quit during recording and pending camera/GPU work where available. The self-test skips connection restoration, alerts and shortcut startup. Use existing controls and logs; no new UI automation framework. |
| Recording recovery | `bash scripts/recording-recovery-smoke.sh`; also exercise `Tools/RecordingOutputSmoke` and `Tools/RecordingStopSmoke` through their current build/run paths. Validate decoded media and metadata, not merely file existence. |
| GPU lifecycle | `bash scripts/check-gpu-standby.sh`; package/app GPU tests with `ULTRACAM_REQUIRE_GPU_PROOFS=1` where supported; Metal API/shader validation in a separate correctness run. |
| Our Sony adapter | `scripts/sony-plugin-checks.sh`, `scripts/sony-control-checks.sh`, `scripts/sony-credential-checks.sh`, `scripts/sony-conformance-checks.sh`; exercise live control separately when hardware is available. |
| Physical and signed integration | Current camera/Sony smoke runners and signed app build/extension runtime; explicitly record hardware, installed extension, client applications, and actual exercised modes. A successful build is not a runtime pass. |
| Focused language checks | Use compiler/concurrency diagnostics and existing Rust/Python/shell checks. Apply clang analysis or supported ASan/UBSan/TSan runs to native ownership, bounds or race concerns when useful. Do not build an instrumentation framework or run every tool on every file. |

Use raw `swift test` with a fresh scratch directory for focused MonitorKit reproductions when needed. Do not assume `monitor-kit-package.sh` has a standalone `test` subcommand: package suite orchestration currently lives in `scripts/test.sh`.

For final runs, explicitly set or clear runner options that select partial tests, skip builds, or change SDK configuration. Keep `CARGO_TARGET_DIR` and `MONITOR_KIT_PACKAGE_CACHE` inside the selected work directory when fresh artifacts are required. Check logs for executed tests, failures, skips and retries; exit status alone is insufficient. A retry pass is not evidence that an intermittent bug is fixed.

### Targeted reproductions and integration checks

- Start with an existing test, fixture or smoke tool. Extend it with the smallest case that exposes the suspected failure. A small standalone reproducer is appropriate when the existing tools cannot reach the path; do not generalize it into a framework.
- For a race, control the relevant callback ordering where practical. For a leak or timing failure, use a bounded repetition run. Before running, state the action sequence, repetitions/duration and observable failure condition in the bug note. Choose these from the suspected mechanism; do not invent universal soak durations or performance budgets.
- Check malformed layouts/LUTs, extreme math inputs and unexpected state transitions when reviewing their handling. Use small deterministic or seeded cases when useful, without a blanket property-testing or fuzzing campaign.
- For color/audio/math bugs, use independently established expected values and justified tolerances. Agreement between two implementations of the same mistake is insufficient.
- For recording bugs, inspect decoded media, timing, audio and recovery behavior; file existence alone proves little.
- Exercise the combined capture → monitoring → recording/output path, including source changes, stop/restart and teardown. Exercise other combinations when shared resources, state transitions or findings make them relevant. Do not generate an exhaustive Cartesian or pairwise test matrix.
- Inject a failure at the smallest useful existing boundary when a real failure is impractical to trigger. Keep any necessary test seam local to the behavior being checked.
- Record the actual result and limits. Hardware-dependent behavior remains unverified until exercised; continue finding and fixing independently testable bugs meanwhile.

## 6. Find, fix, verify

Keep one short working note for both repositories: a file checklist, actionable bug notes, and remaining questions. Group duplicate symptoms by root cause. No separate ownership ledger, evidence index, scenario registry or report suite.

For each bug, record its location, trigger, impact, cause, fix and verification command/result. Include a log or small reproduction only where needed to understand or reproduce it. Prioritize by impact:

- **P0:** data loss/corruption, memory safety, serious authorization failure, or a critical persistent crash/deadlock.
- **P1:** major supported workflow fails, substantial incorrect media output, serious leak, or unreliable recovery.
- **P2:** bounded/intermittent correctness, lifecycle, UI, or resource defect.
- **P3:** minor observable correctness or diagnostic defect.

A suspicious pattern is not automatically a bug. Investigate each concrete suspicion until it is confirmed, disproved with a reason, or explicitly left unresolved because of a stated blocker. Unresolved suspicions must appear in the final summary and prevent an unqualified all-clear; do not silently drop them or change working behavior to address a guess.

For each confirmed defect:

1. Reproduce on the captured pre-fix tree, or establish a precise source-level proof when runtime reproduction is unavailable.
2. Identify the root cause and search for the same mistake elsewhere in our code. Check affected callers and equivalent implementations; extend tests where useful.
3. Add a focused failing regression when it provides useful protection, preferably before the repair. For a trivial low-impact correction, an existing check or direct reproduction may suffice. For hardware-only defects, use a repeatable procedure and expected outcome. Avoid tests that merely mirror implementation text or restate the fix.
4. Make the smallest complete fix that restores the contract. Preserve unrelated work and behavior; do not hide failures by weakening assertions, increasing arbitrary timeouts, or silently skipping paths.
5. Demonstrate failure before and success after using the same input/environment where executable. For a source-proven bug that cannot be exercised here, distinguish the implemented fix from pending runtime verification. Run focused tests and affected integration checks.
6. Review the final patch for new races, ownership changes, compatibility changes, and incomplete error paths.
7. Record exact commands, results, and remaining limitations. Fix every confirmed in-scope bug; if a fix is blocked or intentionally deferred, keep it explicitly open with the reason and required next step.

Keep UltraCam and MonitorKit changes attributable to their respective repositories. Track paired API/integration changes together and test the exact combined tree. A superproject commit alone does not capture uncommitted MonitorKit edits. Do not automatically commit unrelated pre-existing changes.

## 7. Finish the review and check the repaired app

Work through every subsystem above, fixing bugs as they are confirmed. After the last fixes:

- Check the file checklist for omissions, including conditional code and our tests/tools/build scripts. Read the final patches and affected callers again.
- Run the full existing app/package tests, fresh Debug/Release app and extension builds, normal launches, and the integration checks relevant to the changes. Use actual GPU/device checks where available and needed; disclose skips, retries and missing hardware.
- Ensure each confirmed bug has a fix and meaningful verification, or remains explicitly open with its blocker. Resolve every concrete suspicion or list it as unresolved. Do not equate source review, compilation, synthetic tests and physical-device validation.
- Summarize bugs fixed, checks run, and anything still broken or unverified in the same working note. Preserve existing user changes.

The output is repaired code, useful regression tests, and a concise account of results. Missing hardware can limit verification, but does not justify leaving the rest of the source unread. Do not claim full completion while files, bugs, concrete suspicions or necessary verification remain outstanding. No finite audit proves the absence of all bugs.

Execution results belong in the single working note referenced above.
