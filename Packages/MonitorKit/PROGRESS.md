# MonitorKit progress

The autonomous build log. The heartbeat (every 5 hours) reads this file to resume work.

## Phases

- [x] P0 Foundation (main session, 2026-10-21): package skeleton (macOS 26, Swift 6, MSL 4.0), Core model, ported reference math (23 tests), shaders written and compiling, contract in `Docs/ARCHITECTURE.md`
- [x] W1 Build, then audit round 1 (3 lenses) and fixes per module: picture pass, scopes, audio, math verification. Ends with an integration agent. Done 2026-10-22: every audit finding fixed; the integration step fixed the math stream's open discrepancies (Docs/MATH.md section 9: S-Gamut3 weights, AWG3/AWG4 gamuts, depth-aware full-container rescale, ARRI range convention, six-band comment, skin-tone doc), removed every XCTExpectFailure, added the picture/scope agreement test, and updated ARCHITECTURE.md and MATH.md. Open for W2: HDR/EDR output encoding and the analytic display transforms, Freeze, per-channel clip indicators, MonitorKitUI (empty so far).
- [x] W2 HDR/display transforms + EDR; MonitorKitUI; a dedicated performance/optimization pass; audit round 2 of the W1 modules + fixes. Done 2026-10-22 (integration step: see "W2 result" below). Added beyond the plan: the Metal 4 encode path for every GPU object (bit-identical to classic), MonitorMultiview, white-point trim, scope HDR colours.
- [ ] W3 Two audit rounds of the W2 work + fixes; docs (README, FEATURES, API, INTEGRATION, MATH, LICENSE); final benchmarks
- [ ] W4 (GATED: starts only after session "ultracam-18" commits its app work: GPU monitor in MonitorTools, pipelined LUTProcessor, Program, Recording, DeckLink SDK 16. Its app files are off limits until then) Ultracam integration: LUT fused into LUTProcessor, monitor surfaces on MonitorKit, UI, then 2 audits and regression tests
- [ ] W5 Final verification and report

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

## Queued peer findings (ultracam-18, 2026-10-22) — fold in after W4 final-verify, before releasing the freeze
1. AppModel refused-Start expiry: drop the camera's `refusedStarts` entry (or call expireResolvedStartRefusals()) whenever its selectedDevice changes — selectedDevice didSet for the selected camera, updateCamera/setInput for others. Today a stale "Couldn't start" can resurface on a later unplug.
2. AppModel.startRefusal: `selectedDevice.isEmpty` should say "Choose an input for this camera." not "Connect the UltraStudio."
3. ProgramOutputBridge ~404-416 host-time anchoring: re-anchor when mapped time is more than ~2 frame durations behind/ahead of now, not only past ±1 s (short on-air gaps leave a lasting latency offset). Low priority.
- Heartbeat 2026-10-22 15:21: W3+W4 (wf_811d7738-f78) still running; W4 through s4-feedhost committed (8e1808b, 15:00), feed-host gates in progress
