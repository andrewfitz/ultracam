# UltraCam and MonitorKit performance pass — 2026-11-02

This pass targets first-party UltraCam, MonitorKit, and the application's Blackmagic/Sony adapters. SDKs, external libraries, formats, quality settings, and benchmark thresholds were not changed. Eighteen fresh GPT-6.1 Sol agents covered implementation, measurements, and independent correctness review. Changes are local and uncommitted.

The starting application revision was `819f2fe60120cf904719a9ff627cc7e5dadcd85f`; MonitorKit was `508476639855296641bbf46c2fbe3b40037eea47`. The baseline also includes the existing 60/120 Hz scope preference edits. Concurrent control, UI, and recording-LUT feature changes were preserved; they are not counted as optimizations from this pass. Full application comparisons therefore describe the measured snapshots, while isolated comparisons establish each optimization's own effect.

Evidence, original sources, optimized binaries, commands, and raw logs are under `/Volumes/8TB/cinesomatic-build/performance-20261102`. `baseline/` preserves the starting source; `final-v1/` records the full integration and matched measurements; `final-v2/` captures the latest live source for focused integration. Their source hash manifests identify the validated inputs. Three integration corrections were preserved before successful application compilation: a buffer parameter shadowed by a color-description local, a vendor-specific comment rejected by the existing boundary lint, and a stored `CFString` attachment key rejected by strict concurrency (now stored as `String` and bridged at use).

Measurements use an Apple M4 Max, 16 CPU/40 GPU cores, 48 GB memory, macOS 27.0.1, Xcode 27, arm64 optimized builds. The UI display runs at 240 Hz. The user's running UltraCam, Resolve, Docker VM, and unrelated work remained active. Our timed GPU/UI windows exclude our own compilation work. Raw timings and failures are retained; small fluctuations are not promoted into speedup claims.

**Measured CPU improvements**

| Operation and workload | Before | After | Interpretation |
| --- | ---: | ---: | --- |
| PCM conversion, 1,500 × 480-frame stereo Int16 interleaved packets | 14.904 ms | 9.917 ms | Thread CPU, alternating implementations in one optimized executable |
| PCM conversion, 1,500 × 480-frame 16-channel Float32 planar packets | 109.240 ms | 71.190 ms | Same method; 16 sample/layout/channel cases improve 26.9–36.1% |
| Stable Blackmagic source descriptions, 10,000 frames | 464.310 ms | 9.368 ms | Isolated process CPU; includes process startup and candidate differential checks |
| Swift auto-switcher queue + FFI, 210,000 empty-output ticks | 761.521 ms | 603.738 ms | Median process CPU, five alternating baseline/candidate pairs; 20.7% lower |
| Rust director, 140,000 eligible ticks with 1,500 audio/80 transcript history | 671.023 ms | 146.767 ms | Same paired process-CPU method; 78.1% lower |

These measurements do not claim equivalent improvements in whole-application CPU, frame rate, or latency. PCM output and timestamps matched a 14,582,536-byte baseline fixture exactly (SHA-256 `ea4816df6fb6752fc060a7685592e13a2e9448a62cfdfae1f4fda97f1f71db8f`). The format-cache differential checks cover changed physical declarations, equivalent rates, invalid rates, and clock domains.

**Removed recurring work and memory allocation**

| Area | Before | After |
| --- | --- | --- |
| Program-only delivery | One unused `CMSampleBuffer` creation per rendered frame | None; preview/camera consumers still receive samples |
| LUT processor output retention | Scan cached output views, filter/map/concatenate arrays, take cache lock per submission | Retain the actual output entries directly with the frame |
| LUT processor RGB dispatch | Construct a four-entry dictionary per submission | Switch on format |
| LUT processor queue dependency | Queue-stage barrier on every frame | Barrier only for frames sharing the resize intermediate; resize dispatch barrier retained |
| Successful monitor-picture feedback | Render-thread lock, block enqueue, and wake per picture | Update already-locked timing counters directly |
| Live GUI values | Full camera presentation for six snapshot-only leaves; full session presentation for three problem surfaces | Derive only the values those views display; subscriptions and refresh rates preserved |
| CPU-memory GPU ingest | One Metal queue per frame; queue-wide residency additions/removals | One queue per ingester; residency attached to each command |
| Packed 4:2:2 recording | One Metal queue per frame; queue-wide residency additions/removals | One queue per converter; independent command resources retained through feedback |
| Processed-frame ownership | One storage lock allocation/frame; `2L + 1` storage lock/unlock pairs for `L` route leases | ARC owns storage; no storage lock; release callback remains outside lease lock |
| Recording PCM decode, 480 frames × 16 channels | 7,680 Data borrows plus a separate 30,720-byte decoded array | One borrow for interleaved / 16 for planar; decode into the final combined array |
| Native Int16/Int32 audio metering | Two temporary Float arrays/packet for live + take | Borrow native aligned samples; at 16 channels/48 kHz, removes 6,144,000 bytes/s of temporary sample storage |
| Stable Blackmagic physical metadata | 10,000 JSON/signature computations per 10,000 stable frames | Zero after the accepted declaration is cached; physical metadata still validated every frame |
| Blackmagic RGB buffer interface | Two interface queries and associated retains/releases | One validated interface reused |
| Monitor texture cache, biplanar hit | Two lock/search operations; resumed stale frame recreates chroma texture | One paired hit; zero recreated textures in all six measured NV12/P010 idle-resume cases |
| Monitor warm-up | N identical placeholder LUT parses/uploads for N surfaces | One shared placeholder per warm-up |
| Fixed false-color tables | Sony: one array/10 conversions; ARRI-style: two arrays/12 transformations; LogC: one array/six conversions per lookup | Immutable tables initialized once |
| Unchanged monitor update | Resolve layer color every idle update | Reuse the resolved layer until its observed inputs change |
| Scope minification | Apply log/gamma to every visited source bin | Preserve normalization order, maximize densities, apply the curve once per output channel |
| Fused scopes | Recompute quotient/remainder per work item | Advance the same coordinates between items |
| Empty switcher response | Construct String/Data/JSONDecoder for canonical `[]` | Recognize the canonical response before decoding; control callbacks retained |
| Rust boundary selection | Build a temporary candidate vector; ten allocations/reallocations per measured eligible tick | Stream the same candidates into the existing selection operation; zero such allocations |

Allocation and operation counts are exact source/instrumentation comparisons, not inferred wall-time gains. The cache probes verified zero steady-state heap allocations before and after across nine format/pool cases. GUI baseline two-camera idle visited the migrated camera-presentation paths about 10.5 times/s; the new snapshot probe records those avoided derivations.

Pixel decoding, effects, scaling, scopes, native ingest, and recording conversion remain on their existing Metal paths. Small audio blocks remain on the existing CPU/Accelerate path to avoid GPU submission overhead. Scope resolution keeps every bin visit and its normalization; histogram handling and output quality are unchanged. No cadence, precision, allocation budget, durability, or failure threshold was relaxed.

**GPU/UI comparisons and integrated validation**

The coordinated A/B measurements show a repeatable reduction in minified scope resolve work. Four ABBA runs use the same optimized XCTest executable, with only the embedded baseline/candidate shader resources changed; runtime SHA-256 checks verify each loaded shader. Alternating display gain by 0.01% forces a fresh trace each draw. This measures resolve plus draw, not complete application rendering.

| Viewport / scope | Baseline GPU ms | Candidate GPU ms | Change |
| --- | ---: | ---: | ---: |
| 3840×2160 / vectorscope 2048 | 0.4315 | 0.4381 | +1.5% |
| 3840×2160 / waveform 4096×2048 RGB overlay | 0.5414 | 0.5581 | +3.1% |
| 480×270 / vectorscope 2048 | 0.1529 | 0.1325 | −13.4% |
| 480×270 / waveform 4096×2048 RGB overlay | 0.1960 | 0.1571 | −19.8% |
| 240×135 / vectorscope 2048 | 0.2693 | 0.2302 | −14.5% |
| 240×135 / waveform 4096×2048 RGB overlay | 0.2651 | 0.2051 | −22.6% |

The main picture workload is unchanged within observed variation: 1080p all-tools GPU median 0.282→0.281 ms, four feeds in one pass 1.400→1.406 ms, classic CPU encode 7.0→7.3 µs. All 14 final representative benchmarks pass; the initial baseline run passed 13 and used its existing load-aware CPU-budget skip once (12.0 µs versus 10 µs, load 26.5 on 12 performance cores).

Matched UI runs compile the same immutable original verifier sources with identical `-j2 -O -whole-module-optimization`, default 2/4-camera live/fixed-meter workloads, and each snapshot's matching app shader. Aggregate CPU results are mixed, so no overall application/UI CPU, memory, FPS, or latency improvement is claimed.

| Idle case | Baseline main / process CPU | Candidate main / process CPU |
| --- | ---: | ---: |
| Two cameras, live meters | 9.0% / 11% | 9.7% / 12% |
| Two cameras, fixed meters | 7.8% / 9% | 8.4% / 10% |
| Four cameras, live meters | 9.4% / 12% | 7.7% / 10% |
| Four cameras, fixed meters | 7.2% / 9% | 7.8% / 10% |

Peak physical footprint is essentially flat, 515.3→514.8 MiB; maximum RSS is 313.8→324.8 MiB. These are whole-run peaks across setup and all cases, not steady-state memory per camera. Candidate snapshot-only leaves avoid full camera-presentation derivation at 12–20.5 evaluations/s; concurrent external telemetry/UI changes prevent attributing aggregate body counts to individual optimization patches.

Both matched UI runs pass 311 checks and fail two unchanged 50 ms idle-stall budgets: baseline 71.5/69.4 ms, candidate 121.4/59.8 ms. Structural and meter-rate checks pass. The initial non-WMO baseline also retained two other failures: an inspector transition of 266.5 ms versus 250 ms, and capture refresh printed as 3.0/s but below its exact 3 Hz floor. The separate full current-verifier run on `final-v1` passes 1,865 checks, has no structural failures and accounts for every check, writes 293 images, and fails two idle-stall budgets at 90.6/60.5 ms. These failed gates remain failures; no timing threshold or assertion was changed.

The full release MonitorKit run executes 1,107 tests across five bundles: 1,092 pass, 12 skip, and three cases fail six assertions. Every failing case reproduces on the untouched baseline:

- `ScopeContractTests.testNoAllocationGrowthOver100Accumulations`: exact allocation equality observes a 5,029,888-byte decrease, both before and after.
- `ScopeContractTests.testSteadyStateEncodeMakesNoHeapAllocations`: waveform, vectorscope, and histogram each report two heap allocations against the existing limit of one.
- `ScopeLifetimeTests.testEveryFrameChangesWithThreeUnretainedFramesInFlight`: two command buffers report `InvalidResource`, code 9.

The package suite is therefore not green. The 12 skipped cases remain explicit coverage gaps:

| Suite | Skipped cases and reason |
| --- | --- |
| `DisplayLinkTests` | `testDisplayLinkDrawsAndPresents`, `testHostDrivenLinkOnARenderThread`: window-test opt-in disabled |
| `MeterLayerTests` | `testALiveMeterTicksOnlyOnScreen`, `testLayersLandWhereTheViewSays`: window-test opt-in disabled |
| `Metal4Benchmarks` | `testMetal4CPUEncodeCost`: existing load-aware budget skip, 14 µs versus 10 µs on load 31.4 |
| `PipelineArchiveBenchmarks` | `testInitAndWarmUpWithSeveralFiles`, `testTimeToFirstSpecializedFrame`, `testWarmUpDuration`: warm-start benchmark opt-in disabled |
| `PipelineArchiveValidationTests` | `testAValidatedSessionBuildsAndWritesNothing`: shader-validation opt-in disabled |
| `Fresh02ColorMatrixPerformanceTests` | `testOldAndNewColorMatrixMicrobenchmark`: paired microbenchmark opt-in disabled |
| `Perf01GuideGridTests` | `testWideGridMicrobenchmark`: grid microbenchmark opt-in disabled |
| `Fresh14CorrelationTests` | `testCorrelationAndInitializationMicrobenchmark`: paired microbenchmark opt-in disabled |

Integrated app proof on the frozen `final-v1` inputs:

| Gate | Result |
| --- | --- |
| Unsigned production Release and bundle validation | Pass; host-only resources validated, no MonitorTools shipped |
| Release app self-test | 39 passed, zero failures; no live-camera argument |
| Comprehensive optimized app XCTest | 1,610 passed, zero failures/skips; 331.251 s |
| Source declarations | Two passed |
| Contract coverage, all registered-suite discovery, GPU skip checks | Pass |
| Snapshot integrity after builds/runtimes | 721 recorded input hashes match |

Latest live integration is a separate `final-v2` proof. Optimized app compilation passes with strict concurrency and warnings as errors, reusing the existing package and Rust caches. Thirteen affected suites pass all 125 tests with zero failures/skips in 27.294 s: both new recording burn-in suites (7 + 3 tests), Program demand and immediate selection/cut observation (17), LUT pixel/color/ownership cases, capture lifecycle/isolation, and monitor-host checks. Runtime discovery verifies every selected suite's source-declared count, including both newly registered recording suites. The latest source-declaration checks also pass two tests. Both changed package tests—the scope reduction reference and forced-resolve PiP benchmark—pass without skips. No optimization regression was established by these latest checks.

The final comparison matches all 794 recorded `final-v2` first-party source/test/build-input hashes against the live checkout, with zero snapshot or live mismatches. The only intervening production behavior change is the external selection/cut observation revision; the recording help text and LUT comment also changed. Production APIs did not change, so the earlier unsigned Release/self-test proof is retained and the full 1,610-test run remains explicitly tied to `final-v1`. The full suite and full UI run were not repeated for `final-v2`. Latest evidence is in `integration-v2-app-tests-build.log`, `integration-v2-app-tests-runtime.log`, `integration-v2-scope-tests.log`, `final-v2-source-hashes.json`, and `integration-v2-source-comparison.json`.

Baseline selected package correctness also passes 83 tests plus five core/shaper tests. Detailed matched measurements, all failing assertions, skips, commands, runtime context, binary/resource hashes, and raw logs are preserved in `measurements/MEASUREMENTS.md`, `final-summary.json`, `matched-ui-summary.json`, `scope-abba-summary.json`, `baseline-scope-failure-comparison.log`, and `final-package-all.log`. `INTEGRATION.md` and `integration-validation.json` record the full app proof.

Focused validations completed across the pass:

- Baseline and candidate each pass 15 ingest checks with Metal API validation, including 64 distinct concurrent frames and source lifetime after ingester release.
- Baseline and candidate each pass three packed-recording GPU checks, including 48 concurrent distinct outputs and zero retained allocation budget after completion.
- Candidate CPU cadence: 20 tests; optimized frame ownership: eight tests, including concurrent release and callback reentrancy.
- Recording PCM: 13 existing tests plus exact byte/timestamp comparison across sample formats, channel counts, sample rates, packet sizes, drift, pause, and malformed-input recovery.
- Audio: baseline/current each pass 20 checks; three package stage checks include 131,072 integer normalization comparisons and nonfinite/threshold behavior.
- Blackmagic: 17 native entry points pass before/after; 23 physical-format differential cases match baseline behavior.
- Switcher: 27 Rust and 11 focused Swift tests pass against the actual candidate static library.
- Independent CPU and GPU source reviews completed. The GPU review found the 32-set queue residency limit during development; command-owned residency and the above burst tests address it.

**Rejected changes and coverage**

One isolated tetrahedral-LUT math rewrite was rejected. Its GPU minimum improved from 0.356–0.358 ms to 0.343–0.344 ms, but candidate medians overlapped baseline variation and were slower than the best baseline median. No shader change from that experiment was retained. A rolling-loudness sum rewrite was also left out: the small absolute saving did not justify added numerical-state risk.

The review covered app capture/admission and publication, processing/normalization, GUI and telemetry, monitor coordination/rendering, every MonitorKit product, audio, recording/conversion/recovery, native adapters, routing/cadence/virtual-camera transport, and the Rust/Swift switcher. Existing bounded queues/pools, source ownership, pipeline specialization, scope fusion, zero-copy leases, demand-driven timers, recovery streaming, and sidecar durability were retained where no practical improvement was demonstrated. Timeline recording's full-history rewrite every 30 events remains a possible future persistence redesign; this pass does not change its failure/recovery contract.

**Reproduction**

`measurements/commands.json` contains exact baseline/final build and runtime commands. Final matched Release UI measurements use external copies of `scripts/ui-verify.sh` with identical `-j2 -O -whole-module-optimization`, immutable original `Tools/UIVerify` sources, `UI_PERF_ONLY=1`, camera counts `2,4`, meters `live,fixed`, and each snapshot’s matching `ULTRACAM_SHADER`. Earlier non-WMO runs are retained as context. The separate full current UI proof uses the normal unoptimized verifier with `-j2 -Onone`. Comprehensive and latest focused app tests use external execution-only scripts with `-j4 -O -whole-module-optimization`; production scripts, test assertions, and thresholds are unchanged. Package comparisons use release XCTest products and identical selected tests; scope resolve instrumentation extends the existing PiP benchmark for both variants.

Per-change commands, fixtures, raw measurements, and review evidence are in `perf_recording/`, `perf_native/`, `perf_runtime_switcher/`, `perf_ingest/`, `perf_audio/`, `perf_app_gpu/`, `perf_gui/`, `perf_mk_engine/`, `perf_mk_scopes/`, `perf_mk_core_ui/`, `perf_mk_renderer/`, `perf_monitor_app/`, `perf_capture/`, `perf_review_gpu/`, and `perf_review_cpu/` beneath the evidence root. `perf_mk_shaders/` records the rejected variant. No new benchmark framework or production profiling subsystem was introduced.
