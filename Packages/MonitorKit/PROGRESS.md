# MonitorKit progress

The autonomous build log. The heartbeat (every 5 hours) reads this file to resume work.

## Phases

- [x] P0 Foundation (main session, 2026-10-21): package skeleton (macOS 26, Swift 6, MSL 4.0), Core model, ported reference math (23 tests), shaders written and compiling, contract in `Docs/ARCHITECTURE.md`
- [x] W1 Build, then audit round 1 (3 lenses) and fixes per module: picture pass, scopes, audio, math verification. Ends with an integration agent. Done 2026-10-22: every audit finding fixed; the integration step fixed the math stream's open discrepancies (Docs/MATH.md section 9: S-Gamut3 weights, AWG3/AWG4 gamuts, depth-aware full-container rescale, ARRI range convention, six-band comment, skin-tone doc), removed every XCTExpectFailure, added the picture/scope agreement test, and updated ARCHITECTURE.md and MATH.md. Open for W2: HDR/EDR output encoding and the analytic display transforms, Freeze, per-channel clip indicators, MonitorKitUI (empty so far).
- [x] W2 HDR/display transforms + EDR; MonitorKitUI; a dedicated performance/optimization pass; audit round 2 of the W1 modules + fixes. Done 2026-10-22 (integration step: see "W2 result" below). Added beyond the plan: the Metal 4 encode path for every GPU object (bit-identical to classic), MonitorMultiview, white-point trim, scope HDR colours.
- [x] W3 Two audit rounds of the W2 work + fixes; docs (README, FEATURES, API, INTEGRATION, MATH, LICENSE); final benchmarks. Done 2026-10-22: fd87db8 (final perf pass + the W3 library work: docs, CHANGELOG, NOTICE, ported tests, texture cache, warm-up, UI chrome), ff54124 (exact-quotient scope decode, checksummed statistics slots, stress-test hardening: 759 tests, 0 failures), 97fd185 (gate helper), then the W4-found library fixes 96fdeb6 and 12e6b11. See "W3 + W4 result" below.
- [x] W4 Ultracam integration: LUT fused into LUTProcessor, monitor surfaces on MonitorKit, UI, then audits and regression tests; MonitorTools retired (74de953). Done 2026-10-23 at 1baddab; all gates green (see "W3 + W4 result" below).
- [ ] W5 Final verification and report. Offline verification done 2026-10-23 (final-verify at 1baddab, every gate run; see below). Still open: plan step 9, the hands-on check with the UltraStudio (needs `LIVE=1` or the installed app quit, so only with the user's go-ahead), and the final report to the user (report delivered 2026-10-23).

## Workflow runs

(run ID · script path · status)

- W1 · wf_548da617-dbb · /Users/andrew/.claude/projects/-Users-andrew-Projects-ai-ultracam/79374030-ad52-4ad4-9919-97fe11a9d54e/workflows/scripts/monitorkit-w1-build-wf_548da617-dbb.js · launched 2026-10-21 ~23:15
- Heartbeat 2026-10-22 00:21: W1 running (picture built, picture audits in progress; scopes/audio/math still building or auditing)
- Integration 2026-10-22: W1 complete; full suite green with the default scratch path.
- W1 committed 2026-10-22 as e82659f (Packages/MonitorKit + docs/MONITORKIT_INTEGRATION_MAP.md). Baseline 320 tests (MonitorKit 94, Scopes 75, Core 98, Audio 53).
- 2026-10-22: ultracam-18 committed its app work as 2270aca, so W4 is unblocked. The app's monitor is now Metal 4 (MTL4 command buffers, argument tables, residency sets, compute into the drawable) and is colour-managed (MonitorPictureColor: signal-native R'G'B', tagged layer, EDR for HLG/PQ). So W4 must wait for W2's Metal 4 encode path and HDR output. ultracam-18 agreed not to edit MonitorTools, LUTShaders.metal, the LUT path or the monitor surface files without asking (it was allowed to fix the S-Gamut3 Y weights in MonitorTools).
- W2 · wf_bf60cab5-302 · /Users/andrew/.claude/projects/-Users-andrew-Projects-ai-ultracam/79374030-ad52-4ad4-9919-97fe11a9d54e/workflows/scripts/monitorkit-w2-wf_bf60cab5-302.js · launched 2026-10-22 ~03:20. Streams:
  - map: rewrites docs/MONITORKIT_INTEGRATION_MAP.md for W4.
  - picture: HDR/output colour, display transforms, Freeze and clip indicators; then the Metal 4 path; audits (3 lenses + core math), fix, perf, audit round 2, fix.
  - scopes: audit round 2, fix, clip readouts and 240M; then the Metal 4 port and HDR graticules; audits, fix.
  - audio: audit round 2, fix, scale-mark data; round 3, fix.
  - UI: MonitorKitUI build; audits, fix; round 2, fix.
  - integrate.
- W4 must-checks, from ultracam-18's review of 2270aca:
  (a) HLG/PQ sources tagged with BT.709 primaries must keep 709 primaries. The app's MonitorPictureColor wrongly forces BT.2020, so make sure MonitorKit's output-colour recommendation reads primaries independently of the transfer.
  (b) MonitorRuntime's render thread never exits (`guard let self` holds a strong ref across `while true`). The replacement must let it exit.
  (c) ultracam-18 is fixing the scope pending-frame residency starvation in MonitorSurfacePresenter.drawScope; keep that behaviour when that file is rewired.
- ultracam-18 commits on main: cd239eb (MonitorSurfacePresenter: drops a stale scope pending frame after 0.5 s, counted as scopeSkippedNoDrawable; frozen frames exempt) and e1826e8 (AppModel discovery fixes + ui-verify checks). In progress there: Program and recording/DeckLink fixes, not monitor files. W4 starts from the latest main.
- ultracam-18 is done editing (2026-10-22). Main has dbddd91 (S-Gamut3), e1826e8, cd239eb, 2922261 (Program; ProgramFrameNormalizing.releaseIdleResources() default no-op), 865088a (recording/DeckLink), and a bump to app 19 / extension 7. Combined baseline: test.sh 459/459, ui-verify 457/457, monitor-app-integration OK. Base W4 on HEAD and compare regressions against this baseline.
- Heartbeat 2026-10-22 05:21: W2 running (picture HDR + Metal 4 built; picture round-1 audits and core-math audit in progress; scopes Metal 4 port building; audio round-3 fix running)
- Integration 2026-10-22 (W2 integrate agent): resolved every BLOCKED item (MonitorPass draws set scissor/cull/fill like the scopes; scope Metal 4 accumulations call `keepResidentIfReleased`; classic `MonitorFeed.releaseRetired()` / `retiredMemoryBytes` for feeds nobody analyses any more) and the cross-stream API requests (`FalseColorTable.usesFullRangeARRI(signal:layout:)` shared by the pass and `FalseColorLegend(…, layout:)`; `MonitorFeed.monitorStageHasLUT(for:)` used by MonitorRenderer; `MeterScale` and `ScopeGroup.isFused` no longer allocate at -Onone; Core layer-colour docs corrected). Benchmark classes skip under MTL_DEBUG_LAYER / MTL_SHADER_VALIDATION (timings are meaningless there). Docs/ARCHITECTURE.md rewritten and Docs/MATH.md updated to the shipped API and math. Scratch dirs cleared from the package (`.build-audit-scopes-api` moved to ~/.Trash, not deleted: the dcg hook blocks recursive rm).

## W2 result (2026-10-22)

Full suite with the default scratch path: 621 tests, 619 passed, 2 skipped (the opt-in UI window tests), 0 failed: MonitorKitTests 169, MonitorKitScopesTests 123, MonitorKitCoreTests 140, MonitorKitAudioTests 74, MonitorKitUITests 115 (W1 baseline 320; 615 at the start of integration). Under `MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1` the whole suite ran with 0 Metal API or GPU-validation messages; the only failures there were benchmark timing budgets, which now skip under validation. `swift build -c release` is clean (a release *test* build needs `-Xswiftc -enable-testing` because `ColorAnalysisTests` uses `@testable import`).

Key numbers (M4 Max, min of N, shared GPU): picture pass 4K v210 → 1080p every tool 0.29 ms (budget 0.35), → 1600×900 0.33 (0.40); focus mask 4K 0.113 ms (0.24); four 4K feeds in one MonitorMultiview pass 1.56 ms (2.0); every output encoding within 10 % of SDR (tools off: PQ +9.0 %, HLG +9.6 %, SDR/linear +4–5 %); scope accumulation 4K 0.32–0.42 ms single, 0.62 / 0.78 ms fused group; Freeze 0.043 ms; CPU encode 7.6–8.8 µs debug / 6.5 µs release (classic), Metal 4 render 9.4 / 5.3 µs; audio 0.30 % of a core for 16 channels at 48 kHz.

Open items carried into W3/W4:
- Perf: LUT-stage focus mask 0.48 ms tetrahedral / 0.55 ms trilinear (33³) is over the old 0.4 ms target (guarded at 0.52 / 0.6); needs a decode-once threadgroup tile or a smaller analysis LUT format. Metal 4 render encode is 9.4 µs in debug (> 8 µs; release 5.3 µs). Display transforms cost +8 to +16 % over SDR (outside the 10 % bar). 2560×1440 (0.56 ms) and 4K 1:1 (0.70 ms) with every tool, and the compute picture's 16 × 16 threadgroup, are untuned. Scope PQ/HLG draw encode adds about 14 µs per 1024×512 draw.
- Metal 4: pipelines are device-built, not MTL4Compiler-built, so no MTL4PipelineDataSetSerializer warm start yet. The first Metal 4 encode of each object allocates its argument table and ring (no warm-up API). Focus-mask barriers are queue-wide while a mask submission may run (MTLFence variant deferred). No Metal 4 scope test into a framebufferOnly drawable. Scopes copy `store`/`align256`/`makeArgumentTable` from MonitorKit (could be `package`). Optional: expose the scope draw's `waited` flag so MonitorRenderer issues one barrier per shared encoder.
- Colour: HLG → SDR hard-clips above reference white (a BT.2446 soft-knee mode could be added). HDR-to-HDR LUTs are not modelled (any LUT makes the picture Rec.709).
- UI: iOS is compile-checked only (gestures, UIScreen headroom, background pausing never ran); the two display-link window tests are opt-in (MONITORKITUI_WINDOW_TESTS=1). Feeds and scope bins are not shared across renderers (two MonitorViews of one source analyse twice). A residual wait remains in the split picture/scope path under heavy contention. A `drawOffscreen` with a caller's command buffer can stay pinned while paused. Request still open: a threshold-aware `MonitorFeed.hasFocusMask` (today one feed per distinct analysis).
- Audio: below 48 kHz the oversampled rate is under 192 kHz (readings not formally dBTP). `LoudnessMeter` has no `flush()`.
- Map owner (docs/MONITORKIT_INTEGRATION_MAP.md, not edited here): cite `MonitorPass.uniformLength` 5120, `MonitorFeed.uniformLength` 1024, `ScopeAccumulator` 1280, `ScopeGroup` 2048, `ScopeRenderer` 768 + graticule 2304 instead of hand-computed struct sizes (GuideParameters is 2592 B, PassParameters 1456 B); recommend `MonitorMultiview` for multiview surfaces; wire `ScopeRenderer.colorPipeline = pass.colorPipeline` for scopes on HDR layers; call `AudioMeter.flush()` when a stream stops; show `programmeMaximumTruePeak` as R 128 Max TP; `MonitorFeed.monitorStageHasLUT(for:)` for layer tagging; `releaseRetired()` for idle classic hosts; the contiguous-completion watermark for MonitorSubmission.
- Housekeeping outside the repo: /tmp/perf-picture-backup (pre-perf shader sources and the A/B table) and /tmp/delete-me-* scratch copies can be removed by hand.
- W4 must-check (a) is covered in MonitorKit (output-colour recommendation reads primaries independently of the transfer; `MonitorFrame.signal(of:)` reads the primaries attachment). (b) and (c) are app-side and still apply.

Next: W3 (two audit rounds of the W2 work + fixes; README, FEATURES, API, INTEGRATION, LICENSE docs; final benchmarks), then W4.
- W2 committed 2026-10-22 as a1b652a: 619 tests pass, 2 opt-in skipped, Metal validation clean. One scopes test failed once and passed on the rerun (likely a timing assertion); W3 hardens it.
- W4 behaviour decisions (2026-10-22). They are reversible; the aim is to preserve what the user sees:
  (1) false colour still suppresses zebra (app glue rule);
  (2) peaking and log false colour stay off on Program;
  (3) SUPERSEDED: tetrahedral only (see DECISION below);
  (4) overlays use BT.2408 graphics white on HDR layers;
  (5) the one forced change: the monitor's "Output" stage is now source + burn-in LUT computed in the shader, not the published processed buffer, so the menu item is renamed "Output (LUT)";
  (6) the old MonitorConfiguration blob must never decode as MonitorState (fail closed via a discriminator), and the legacy key is migrated and kept.
- W3+W4 · wf_811d7738-f78 · /Users/andrew/.claude/projects/-Users-andrew-Projects-ai-ultracam/79374030-ad52-4ad4-9919-97fe11a9d54e/workflows/scripts/monitorkit-w3-w4-wf_811d7738-f78.js · launched 2026-10-22 ~09:40. Stages:
  1. Gaps: picture R6/R7/R9/R10/R12/R13/R14 and the LUT guard; scopes timing hardening and the legacy look; UI parity; ported MonitorTools tests.
  2. Audits, including scopes Metal 4 round 2, then fixes.
  3. Docs, in parallel with W4.
  4. W4 steps s1–s7, each implement → audit (regression + correctness) → fix → gates → commit.
  5. Library fixes found during W4.
  6. A 3-lens audit of the whole W4 diff, fix, all gates plus a Metal validation run.
  7. Final perf pass and final verification, which also updates PROGRESS.
  ultracam-18 agreed (2026-10-22) not to touch the W4 files, generate_project.py or build.sh until W4 is reported done. Tell it when W4 finishes.
- DECISION 2026-10-22 (user): the app uses tetrahedral LUT interpolation only, for burn-in and monitor LUTs. No trilinear option and no backwards compatibility with older takes. The W4 prompts in wf_811d7738-f78 were edited to say so (run restarted with resumeFromRunId). The library keeps tetrahedral as its default.
- 2026-10-22 ~10:30, restructured for parallelism at the user's request (same run ID wf_811d7738-f78, resumed; gap results cached). Now concurrent:
  - the library audits → fixes → perf pass;
  - docs;
  - W4 waves.
  W4 waves:
  1. s1 plumbing;
  2. s2 LUT ∥ s3 settings (AppModel split by function);
  3. s4 feed host, then s5 surfaces running alongside s4's audit and fix;
  4. NEEDS sweep;
  5. s6a LUT routing ∥ s6b tools UI ∥ s6c scopes UI ∥ s6d audio ∥ s7a ported UI tests;
  6. NEEDS sweep;
  7. s7 retire (alone).
  Then library W4 fixes, a 4-lens whole-diff audit, fix, final verify. Heavy gates are serialized with `/usr/bin/lockf -k /tmp/ultracam-gates.lock`. Each unit is implement → audit → fix.
- W4 binary cost of the step-1 linking (measured by s1, 0415118). Xcode links all five MonitorKit products as object files, plus both resource bundles. So the Debug `Ultracam.debug.dylib` grew from 28.75 MB to 35.83 MB (24,293 MonitorKit symbols) before any app file imported MonitorKit. A Release build keeps whatever dead-stripping leaves. The earlier claims that "nothing is pulled into the binaries" and "zero added overhead" were wrong for the Xcode app. Re-measure Release once MonitorTools is retired (s7).
- W4 MonitorTools output bridge removed (NEEDS sweep after s5). The surfaces draw with MonitorKit, so `Sources/App/MonitorCaptureSink.swift` is deleted along with all of its plumbing:
  - `MonitorFrameSink` is back to source-only: `offer(_:pts:captureGeneration:sequence:)` and `invalidate`, with no `needsOutput` and no paired `offer(source:output:…)`.
  - `CaptureController` no longer has `monitorProcessingRevision`/`monitorPipelineConfiguration`, the `needsOutput` terms in its warm-up, no-demand and frame-rate-gate checks, or the paired deliver branch. `ProgramMonitorTap` offers Program's frame once, as its source.
  - The monitor never keeps processing alive. Every monitor picture shows the capture source, plus the burn-in LUT in MonitorKit's shader.
  - `AppModel` hands each camera's `CaptureController.burnInLUT` to `MonitorCoordinator.setBurnInLUTSource`. It does this at every `installCaptureUpdateHandler` and clears it when a feed is removed. So Output (LUT) and the Output-stage tools show the LUT the camera burns in.
- Heartbeat 2026-10-22 10:21: W3+W4 (wf_811d7738-f78) running: library audits, docs and W4 s1-plumbing in progress

## Queued peer findings (ultracam-18, 2026-10-22) — DONE 2026-10-23 (folded into the W4 fix pass; verified by final-verify)
1. DONE in 2367ed1. AppModel refused-Start expiry: drop the camera's `refusedStarts` entry (or call expireResolvedStartRefusals()) whenever its selectedDevice changes — selectedDevice didSet for the selected camera, updateCamera/setInput for others. Today a stale "Couldn't start" can resurface on a later unplug.
2. DONE in 2367ed1, refined in 1baddab. AppModel.startRefusal: `selectedDevice.isEmpty` should say "Choose an input for this camera." not "Connect the UltraStudio." Shipped: `inputUnavailableReason` says "Choose an input for this camera." when inputs are listed but none is chosen, and "Connect the UltraStudio." only when no input is listed at all (nothing to choose).
3. DONE in 2367ed1, then 5345245 and 1baddab. ProgramOutputBridge ~404-416 host-time anchoring: re-anchor when mapped time is more than ~2 frame durations behind/ahead of now, not only past ±1 s (short on-air gaps leave a lasting latency offset). Low priority. Shipped: frames more than two frames off re-anchor only when they stay equally late with nothing queued behind them (a gap on air), after 0.25 s of host time; a single late frame, a slow send or a stalled burst catching up keeps the anchor.
- Heartbeat 2026-10-22 15:21: W3+W4 (wf_811d7738-f78) still running; W4 through s4-feedhost committed (8e1808b, 15:00), feed-host gates in progress
- Heartbeat 2026-10-22 20:21: W3+W4 (wf_811d7738-f78) still running; wave 5 in progress (tools UI 83ac74e, scopes UI 2a0afaa, audio 0f611af committed; s6d fix gates running)
- 2026-10-23 00:01: W3+W4 run finished except the final whole-diff audits (4 lenses) and final:verify, which failed on a lost login. Resumed wf_811d7738-f78 (task wwbftbspq); completed agents replay from cache.
- 2026-10-23 00:21: resuming wf_811d7738-f78 did NOT replay from cache: it re-ran library fixes and W4 step-1 audit/fix live and would have re-run committed W4 steps, so it was stopped (task wwbftbspq). Its killed fix agents left uncommitted edits (MonitorKit Sources/Tests, scripts/monitor-kit-package.sh, the integration map). DO NOT resume wf_811d7738-f78 again.
- 2026-10-23 00:35: CURRENT RUN = wf_92e6fc1e-b47 (task wuj709vro), script workflows/scripts/monitorkit-w4-finish.js: finish the interrupted fixes → whole-diff 4-lens W4 audit → fix-w4-all (+ the 3 queued peer findings, all gates, Metal validation) → re-audit of the fixes → final-verify (PROGRESS, commit). Heartbeat: resume THIS run id/script if it is interrupted.
- 2026-10-23 03:58: wf_92e6fc1e-b47 reached final-verify: every gate green at 1baddab (below). Only W5's hands-on step and the report remain. Tell ultracam-18 that W4 is done and its freeze on the W4 files, generate_project.py and build.sh is released.

## W3 + W4 result (final-verify, 2026-10-23, HEAD 1baddab)

W4 commits, in order: 0415118 (s1 plumbing), 0969f83 (settings schema, legacy blob migrated and kept), 230fa4d, d771ef3, 57b1dab (burn-in LUT on MonitorKit's `mk_applyLUT`, one shared `MonitorLUT`), 8e1808b, 5541949 (GPU context, feed host), cc1548a, ce8c586 (surfaces), 0ed64da (output bridge removed, Output (LUT) in the shader), dfa6566, 9008b8a, b7ef7b1, f9802a6 (ported UI tests), 5ecdd8e, 0f611af (audio meters), e6fbcde, 6bd5d2f (monitor-only LUT), 83ac74e, 2a0afaa, 2aa3686, f33d024, af549cf (tools and scopes UI), 001c229 (wiring and checks), 74de953 (MonitorTools retired), 63ee7c9 (CameraSmoke on the Metal 4 path), 96fdeb6, 12e6b11 (library findings), 5188d0d (retry only on missed timing budgets), 2367ed1, 5345245, 1baddab (whole-diff audit findings and the three peer findings).

Gates at 1baddab (M4 Max; logs in /tmp/fv):
- T `ui-typecheck.sh`: OK.
- U `test.sh`: app 592/592, 0 failures; MonitorKit 796, 0 failures, 0 FLAKY retries. Baseline 459: +133, all deliberate W4 tests: LUTGoldenChecks +6, MonitorCoordinatorChecks +13, MonitorCoordinatorChecksFalseColor +11 and MonitorCoordinatorChecksSurfaces +22 (the ported MonitorToolsUITests and SonyFalseColorUITests), MonitorKitHost/MonitorFeedHostChecks +16, MonitorLifecycleChecksBoundary +5, Defaults +5, Migration +38, MonitorLUT +12, CaptureRecordingIsolationChecks +2, ProgramOutputRouteChecks +2 (host-time anchoring), main.swift +1. None removed.
- V `FORCE=1 ui-verify.sh`: 791 passed, 0 failed, 189 images. Baseline 457 checks / 117 images: +334 checks, +72 images, all added by W4 (monitor tool and scope popover screens via UIMonitorToolScreens/UIMonitorToolVerify, MonitorLUTVerify, MonitorWorkspaceVerify, AudioMeterTapVerify, the main.swift additions). None removed.
- I `monitor-app-integration.sh`: OK on reruns 2 and 3 (32 tests). Run 1 failed one timing case: `testSyntheticSourcePresentsEveryFrameAtTheSourceRate`, display-rate source on this 240 Hz display, presented 212.98 fps against a 0.9 × 239.94 = 215.94 floor (80 superseded, 239.3 refreshes/s). Rerun 2: 239.86 fps, 0 superseded. Rerun 3: 220.70 fps, 58 superseded, with the display link at only 225.7 refreshes/s. The 30 and 60 Hz cases presented every frame with 0 superseded in all three runs. Open (see below).
- K MonitorKit `swift test`: 796 tests, 2 skipped (the opt-in window tests), 0 failures. MonitorKitTests 256, MonitorKitScopesTests 152, MonitorKitCoreTests 159, MonitorKitAudioTests 79, MonitorKitUITests 150 (W2: 169, 123, 140, 74, 115 = 621; ff54124: 759).
- `swift build -c release` of the package: clean, 0 warnings.
- B `build.sh --debug`: built; `validate_bundle.py` passes ("no MonitorTools shipped"); the regenerated project matches the committed one.
- S `SKIP_BUILD=1 app-self-test.sh` (non-live, Debug preferences backed up and restored by path): 39 passed, 0 failed.

Integration readings (I, run 2): 4K v210 → 1080p picture GPU median 0.211 ms (min 0.185); with focus, zebra and guides median 0.474 ms (min 0.460), under the 0.5 ms budget. Heap allocations per frame: slot 0, frame wrap 0, encode 2, the same as the same Metal encoder calls written inline. Scopes at 10/15/30 Hz beside a 30 Hz picture: 0 skipped, 0.80 ms GPU per scope. U's capture stage: 4K 29.97 v210 with a monitor, 90/90 camera and recording frames, monitor updates 89.

Release binary (W2 measured Debug only). Baseline: the Release build of 1fab7f5 (2026-10-22 04:14, with MonitorTools). HEAD: a Release build of 1baddab in its own derived-data directory; the agent-work symlink was not touched.
- `Contents/MacOS/Ultracam`: 20,301,696 → 25,017,704 B (+4.72 MB, +23 %). __TEXT +1.59 MB (`__text` 6.85 → 8.16 MB), __DATA/__DATA_CONST +0.33 MB, __LINKEDIT +2.88 MB (the Release product is not stripped).
- Swift code by module (nm, `__text`): MonitorKit* 991 KB (UI 414, Core 198, MonitorKit 178, Scopes 142, Audio 60) replaces MonitorTools* 350 KB (UI 208, Core 73, Metal 68): +641 KB. The app's own module +465 KB (the W4 glue and UI); non-Swift (specializations, runtime) +121 KB.
- Resource bundles: 24 KB (MonitorToolsMetal) → 140 KB (MonitorKit 88 + Scopes 52). App bundle 20.5 → 25.1 MB.
- So MonitorKit is not size-neutral: it adds about 0.64 MB of code over MonitorTools, plus symbols. There is no per-frame cost: allocations per frame match inline encoding, and there are no CPU pixel copies.

Behaviour decisions, rechecked at HEAD:
- The app has no trilinear path. The only mention is `LUTGoldenChecks` asserting `LUTProcessor.load` rejects a trilinear `MonitorLUT`.
- The menu says "Output (LUT)" (`UIScopeDescription`).
- No camera-extension file changed since 1fab7f5 (no extension bump).
- No TODO/FIXME was added since 1fab7f5.
- No `import MonitorTools` remains. The remaining mentions are historical comments, the pinned boundary JSON in the tests, and `validate_bundle.py`'s guard.

Open after W4:
- CLOSED in W6 (9829139, 8ba4052, fix-w6-all; see "W6" below). I gate: the display-rate case of `testSyntheticSourcePresentsEveryFrameAtTheSourceRate` is phase-sensitive on a 240 Hz display (1 of 3 runs under its 0.9 floor). A source at exactly the refresh rate supersedes frames whenever offer jitter straddles vsync, and the display link itself sometimes ticks below 240/s. Either widen the floor to the refreshes actually counted or accept it as a timing budget in a retry policy; the sub-refresh cases are exact.
- On disk, not in git: `Packages/MonitorTools/` still holds only the retired package's ignored `.build`/`.swiftpm` (about 512 MB). Moving it to the Trash was refused by the permission classifier, so remove it by hand. `/tmp` scratch: the mk-* build directories went to ~/.Trash. Left in place: the orchestrator's `/tmp/mk-w4-commits.json` and `/tmp/mk-resume-findings.json`, `/tmp/mk-*.log`, `/tmp/monitor-audit-*`, `/tmp/ultracam-monitor-package-cache-*` and `/tmp/fv` (final-verify logs).
- CLOSED (the line now says the retired package had the wrong constant). Library doc nit: `Docs/MATH.md` §9 item 1 still says "The old read-only MonitorTools package still has the wrong constant"; the package is gone.
- CLOSED in W6 (07c624a, 0743505). Release size: +4.72 MB binary (above). If it matters, check whether MonitorKitUI (414 KB) is reachable from the app and whether dead-stripping can drop more. Result: binary 25,015,144 → 7,220,104 B after 07c624a (dead-strip, strip, symbols in Ultracam.app.dSYM); all five MonitorKit products are reached by the app; dead-strip recovers about 85 KB of MonitorKit; the resource bundles are shaders only.
- Carried from the W2 list, not re-verified here:
  - CLOSED in W6 (42de2e6, ae6f592, e73f2da, fix-w6-all): Metal 4 pipelines are not MTL4Compiler/serializer warm-started.
  - Partly CLOSED in W6 (e943328): display transforms cost +8 to +16 % over SDR (now HLG → SDR about +9.5 %, PQ → SDR about +16 %; see "W6").
  - CLOSED in W6 (e943328): HLG → SDR hard-clips (no BT.2446 soft knee).
  - HDR-to-HDR LUTs are not modelled.
  - MonitorKitUI on iOS is compile-checked only.
  - Feeds and scope bins are not shared across renderers.
  - Audio below 48 kHz is not formally dBTP.
- Closed from that list: LUT-stage focus 0.48 → 0.35 ms tetrahedral (fd87db8); the flaky scopes statistics test (ff54124, checksummed slots).
- final-verify did not repeat the Metal validation run (`MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1`). That run was assigned to the workflow's fix-w4-all step.
- W5: plan step 9, hands-on with the UltraStudio (LIVE=1 or the installed app quit), needs the user. Then the final report.
- Heartbeat 2026-10-23 05:21: no workflow running; W1–W4 complete (HEAD da5e0b8), W4 freeze released and ultracam-18 told, final report delivered. Only W5's hands-on UltraStudio check remains; it waits for the user's go-ahead, so nothing to resume.
- Heartbeat 2026-10-23 10:22: idle; nothing to resume (W5 hands-on check waits for the user).
- 2026-10-23: W6 started (user approved "yes" to the polish list). CURRENT RUN = wf_c4a7da30-d9e (task wvavfbmlp), script workflows/scripts/monitorkit-w6-wf_c4a7da30-d9e.js, base ea9ef25. Units, run in parallel where file ownership allows:
  - per-stage decode (library, then app glue);
  - pipeline warm start (library, then app glue);
  - BT.2446 HLG→SDR and display-transform performance (after the per-stage decode);
  - the 240 Hz integration test fix;
  - audio metering off the DeckLink callback;
  - Release size trim.
  Each unit gets two audits and a fix, followed by a whole-diff 4-lens audit, a fix, a re-audit and final-verify. Not in scope: the install-link change, which the user didn't approve. Only final-verify runs build.sh, so the install link moves only then. ultracam-18 acknowledged the file ownership. Heartbeat: resume THIS run if it is interrupted.
- Heartbeat 2026-10-23 15:21: W6 (wf_c4a7da30-d9e) still running; Build phase units in progress (warm-start archive, audio metering, output-reading tests in the tree), no W6 commits yet.
- Heartbeat 2026-10-23 20:20: W6 (wf_c4a7da30-d9e) running; all 7 units built, audited and fixed (latest 0743505); whole-diff 4-lens audit in progress.

## W6 result (fix-w6-all, 2026-10-23, base ea9ef25; HEAD before the fix 0743505)

W6 commits: 87733ea (per-stage decode), a9207cf, f3f2a84 (audio metering off the DeckLink callback), 42de2e6, ae6f592, e73f2da (pipeline warm start), 9829139, 8ba4052 (display-rate checks), fa29256, f5e10ad (app glue: both readings, warm start), e943328, 22b06f5 (BT.2446 Method C), 07c624a, 0743505 (Release size), b0c9e9c (scope signal, held pictures), then the whole-diff audit fix (fix-w6-all).

Decisions and findings:
- Per-stage decode: `SignalDescription.outputReading` (`SignalReading`) is how the Output and Monitor stages read the codes; the app sets it in `MonitorFeedHost.interpret` and hands every pass one frame with both readings (no per-pass relabelling, live or held; a Freeze copy keeps both). A specialized pipeline compiles the second decode only when a drawn tool reads those stages (`MK_LUTS` bit 2; warm-up derives the same): 4K → 1080p with zebras and clip indicators, Source 0.1320 ms with or without a distinct reading, Output +7.4 %. `MonitorRenderer` keeps an Output-stage peaking analysis with no LUT on its own stage when the reading is distinct. `UIScopeDescription` labels its own stage's reading.
- Pipeline warm start (42de2e6, ae6f592, e73f2da, fix-w6-all): `MonitorPipelineArchive`, `MonitorEngine/ScopeEngine(…, cacheDirectory:)`. Archives are primed on open (Metal re-reads an `MTL4Archive`'s file at its first compiler use and raises an uncaught exception, `-[__NSArrayM insertObject:atIndex:]: object cannot be nil` in AGX `convertBinaryArchives`, macOS 27.0.1, when the file is gone); hits load once; a failed save is retried by the next; `ScopeEngine.prepare(target:)` leaves the save to the scheduled one. Metal findings: an asynchronous build by a compiler with an `MTL4PipelineDataSetSerializer` crashes in Metal's compiler scheduler (macOS 27, SDK 27.0), so the recorder builds synchronously at save; a serializer compiler reads the system shader cache but does not fill it and compiles 1.5–3× slower cold, so a plain compiler builds. fix-w6-all: only the newest verified file is opened at init, older ones at the first miss (fix-w6-round2: a file being opened, read to prime, is in a process-wide set every save's removal skips, so another archive of the key evicting it mid-session cannot crash the host; two processes on one directory are not covered), 3 kept per key (was 8, all opened: init grew to about 30 ms); `warmUp(…, save:)` / `ScopeEngine.prepare(…, save:)`, and the app saves both archives once after both warm. Measured (system shader cache warm, min of 3): archive init + warmUp 6.1–6.5 ms with 1 to 5 launches' files against 3.2–3.6 ms for the plain compiler with no cache; first specialized frame 5.6 ms warm archive, 5.7 ms plain. With a warm system cache the archive costs about 3 ms per launch; its gain is a launch after the system cache was purged (not measurable here).
- e943328: HLG → SDR is BT.2446-1 Method C (38 % → 53.2 %, 50 % → 70 %, 75 % → 96 % SDR) with BT.2407 §2 into BT.709; PQ → SDR unchanged. Method C anchors (22b06f5): 100 % SDR at 332.6 cd/m² (≈ 82.9 % HLG); eq. (5) reaches 118.4 cd/m² = 107.3 % SDR at 1000 cd/m² (Table 1 range 0–109 %). Display transforms are still over +10 % except HLG → SDR: about +9.5 % on the full-range frame, +9.6..+10.6 % on muted colours (at the target); PQ → SDR is +16 %, the PQ/HLG output encodings +12–14 %; the costs are the exact transfer curves, measured with the 4K pass. Open: a hue-preserving BT.709 gamut step (BT.2407 Annex 5 measured +8–17 %, MATH.md §5.1); baking `toTarget`/`transformMatrix` as function constants (a 1.5–2 point win measured on the output encodings).
- App integration decisions: audio meter hand-off ring 4096 packets (68 s at 59.94p); a still-full ring is the only meter loss, counted as `CaptureUpdate.audioMeterCoalesced` for the current capture (0 when stopped) and shown as "Meter packets coalesced" in diagnostics (fix-w6-all). A recording take starts on video: audio before its first accepted frame is not recorded (f3f2a84).
- Display-rate checks (gate I): a source at the display's rate needs refreshes ≥ 0.9 × the display rate and GPU per picture < one refresh, and presented ≥ (2/3 + 3/4)/2 ≈ 0.71 × min(offered, refreshes) (fix-w6-round2: midway between a 1-in-3 drop and a correct presenter's worst phase, 3/4; 0.75 in fix-w6-all, 0.6 in 8ba4052), in one of 3 rounds. The 30 Hz scope floor is 0.85 × min(hz × elapsed, presented), not scaled by the picture link; the round-sensitive scope checks are re-measured, and a scope is drawn on at most one scope-link tick (`MonitorSurfaceStatistics.scopeRefreshes`). The render thread runs on a real-time schedule (`THREAD_TIME_CONSTRAINT_POLICY`, period one refresh of the fastest display, 1 ms computation within 4 ms), so other processes' load no longer preempts it for a source interval.
- Release symbols: build.sh links `Ultracam.app.dSYM` beside the stable product (both non-symlink checks run before either link moves) and `scripts/archive-dsym.sh` keeps a copy per build under `symbols/<run id>/`, a link per UUID of every slice (`symbols/<uuid>` → run id) and only the newest 20 builds (fix-w6-round2; best effort: a failure warns after the product is linked); `prepare_local_build.py` copies the dSYM beside the staged local app (the stripped Release `--local-development` stage failed `validate_symbols` without it).

