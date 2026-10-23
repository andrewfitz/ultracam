# Monitor Tools audit and qualification

> **Historical.** `Packages/MonitorTools` was retired in W4 (step 8, 2026-10-22): [MonitorKit](../Packages/MonitorKit/README.md) replaced it, as planned in [the integration map](MONITORKIT_INTEGRATION_MAP.md). The findings below are about the retired package and are kept as a record.

Reviewed October 20, 2026. The [plan](MONITOR_TOOLS_PLAN.md) records intended
behavior and release gates; [VALIDATION.md](../VALIDATION.md) records executed
checks. Historical design findings below do not themselves prove implementation
or performance. Continuous EL Zone, physical multi-input qualification, the FX3
color chain and receiver-observed Program cuts remain unqualified.

## Original Astra hard review

The original review found no critical issue and four actionable design gaps.
After plan revisions, Astra confirmed all four resolved at the design level,
without a new critical/high contradiction. Original source line references
precede this implementation and are not presented as current code locations.
Astra inspected source and documentation only; that review did not run tests,
operate the app/camera, change settings or record footage.

| Severity | Finding | Required correction and current disposition |
| --- | --- | --- |
| High | Recording isolation had an enforceable gate, but virtual-camera delivery did not | Add paired tools-off/on delivery counts, cadence, mapped timestamps, transport drops and fixed p95/p99 latency tolerances for feeds and Program. Feed synthetic IPC now has six paired passing profiles; physical input and receiver-observed Program cuts remain separate gates. |
| Medium | Tools-off multi-view and shader-failure fallback lacked an explicit independent owned clean route | Add bounded shader-independent clean-copy/presentation admission, producer release and explicit exhaustion states. CleanPreviewService and corresponding lifetime, fallback, native-window and memory tests are implemented. |
| Medium | Program source-focus peaking required provenance deferred by the plan | Disable Program source-focus and calibrated false color until source/output correspondence is implemented and qualified. Program permits output picture, guides, zebras and scopes. |
| Medium | Source-to-output geometry correspondence was underspecified | Carry separate geometries and pixel-center mapping; test asymmetric aperture through actual 4K-to-1080p processing and reject unsupported transforms. Geometry/provenance and stale-result checks are implemented and tested. |

Additional review decisions were incorporated:

- Frozen Clean must reveal an admitted clean counterpart of the same frame,
  with matching metadata/configuration, or give an explicit unavailable reason.
- Named workloads need minimum useful picture/scope rates and age limits.
  Indefinite degradation or merely skipping all monitor work cannot pass.
- Tools disable releases analysis; visible clean pictures still own presentation
  demand/resources. Guides add no staging beyond that clean-preview route.
- Side by Side fallback belongs in the initial layout milestone; Four Up has
  corresponding later coverage.
- No definite macOS 15/Swift packaging incompatibility or additional recorder
  finalization defect was established. Host resource loading still required a
  real signed build. Synchronous invalidation followed by queued cleanup alone
  did not prove recording finalization waited for processing.

The broader plan audit also required recorder admission independent of a blocked
processing queue, same-frame source/output pairing without PTS lookup/backlogs,
committed and retired resource accounting across reconnect/removal, packed v210
producer lifetime coverage, independent capture demand, local surface controls,
separate transport/range/Log interpretation and independent color references.

## User clarification: ARRI-style on Sony

The initial implementation supported literal ARRI LogC profiles and incorrectly
made the requested Sony workflow depend on matching an ARRI camera. The user
clarified that the requirement is the false-color exposure scheme on Sony S-Log3.
The correction uses Sony per-channel decoding and gamut luminance before mapping
to LogC3 EI800 reference bands, with honest reference highlight/shadow labels.
It does not infer Sony clipping or noise limits from ALEXA thresholds. Sol review
found no blocking issue across scalar math, GPU transport/gamut/provenance and
atomic settings bindings. Targeted checks pass 44 Core, 6 new Sony GPU and 23 UI
tests. The final full app/package runs pass 316 and 112 tests respectively,
with 11 additional actual AppModel/hosted-window integration checks,
including strict concurrency/warnings-as-errors; signed build 12 / extension 4
passes metadata/resources/signature. Paired and sustained synthetic workloads
subsequently pass; final app-only lifecycle checks and installation also pass.
Executed results remain separate from this read-only review.

## Final app lifecycle review

Read-only Sol review found no blocking defect in the final app-only corrections.
Removing a feed refreshes monitor choices, capture-demand routes and the published
camera registry; a late update from its removed controller cannot overwrite the
missing-feed state. Unavailable targets clear sink consumers immediately. Detached
windows retain their chooser when cleared, can bind another target independently
of the main workspace, and break the hosting-view ownership cycle on close.
Isolated tests use the actual AppModel and hosted window with private defaults and
a capture-only registry publisher. They enumerate devices without starting capture
or modifying the user's settings. Hosted-window checks establish state, demand,
content and close behavior; GPU-buffer drain is qualified by separate lifetime tests.

## Implementation review and fixes

Sol implementation agents and an independent read-only reviewer repeatedly
checked the package, host integration, lifecycle and qualification harnesses.
The earlier frozen build passed 313 app tests and 87 package tests: 26
core/adaptive, 7 color, 35 Metal and 19 UI. Critical-pipeline feedback later passed
315 app and 96 package tests. Both predate the Sony correction. Earlier receipts
and candidate fingerprints:
`/Volumes/8TB/cinesomatic-director-work/agent-work/monitor-final-verification/verification-command-final.json`.

Confirmed defects found and corrected during implementation include:

- Recording submission could inherit processing admission pressure. Validated
  raw source submission now precedes GPU processing admission, with a stalled
  processing/preview regression and real recorder-core integration checks.
- A stalled target could block globally available analysis capacity. Fair
  metadata-only admission now permits other targets while preserving one
  in-flight job per target across retired generations.
- Native integer ARRI boundaries could change through floating-point conversion.
  GPU tests now cover exact published legal/full LogC3 and LogC4 boundaries and
  explicitly declared full-to-legal transport reconstruction.
- Aggregate planar bytes-per-row was used as alignment, producing excessive
  allocations for 4K planar copies. Per-plane rows, 64-byte allocation alignment
  and actual active-byte comparisons cover padded/awkward layouts.
- Analysis success/fallback/error delivery could retain borrowed producer storage
  while a consumer blocked. Inputs now release before GPU commit or owned-only
  delivery; working sets return to cache before delivery. Callbacks cannot free
  committed resources or their budget early. Blocked-consumer regressions verify
  producer release, subsequent same-target progress and bounded errors.
- Completion/deadline races could suppress an already completed result. An atomic
  completion-versus-expiry claim resolves publication while committed resources
  remain charged until completion.
- Presenter validation occurred too early to prevent a later stale store.
  Generation/revision/sequence validation now occurs inside final presentation
  storage, including across clear/rebind transitions.
- Cancelling Freeze could leave a background-accepted, unpublished frozen frame.
  Pending results and published snapshots now cancel consistently.
- Native surface capacity could release before asynchronous native display/GPU
  teardown. Picture/scope reservations survive those completions. Surface ledger
  identities are independent of feed-generation retirement.
- Conservative working-set estimates could shrink before lazy storage existed.
  Shrinking retains future same-key staging/bin allowance, verifies actual
  allocations and never permits uncharged growth. Four idle sets avoid forced
  fourth-target churn while remaining bounded.

The runtime uses three analysis jobs, four clean-copy jobs and at most four idle
working sets. The shared ledger reserves at most 256 MiB total and 192 MiB
non-clean, including retired resources; clean presentation satisfies the 64 MiB
reserve. It charges actual module-owned allocations plus explicit estimates for
additional native compositor buffers. These caps are not whole-process or
OS/driver-memory bounds. Borrowed producer storage and the original native
main/tray tools-off route are reported/qualified separately.

Repeated pressure reduces picture composition to 720p and spatial scope sampling
to stride four, preserving full-source focus. Default 15 Hz and selected 30 Hz
scope requests reduce to 12 Hz; explicit 10 Hz stays 10 Hz. Recovery requires
five healthy seconds. The original focused-15/background-10 priority proposal is
not implemented; current delivery depends on per-target requests and fair shared
admission. Diagnostics expose requested/effective rates, quality, ages and skips.

## Qualification and preserved failures

The fixed useful-monitoring gates are at least 20 unique pictures/s and 10 unique
scope updates/s per declared enabled target, with p95 picture/scope ages no more
than 100/200 ms. Pipeline/receiver p95 and p99 limits are baseline +2/+5 ms.
Recording/source/media invariants are separate gates and cannot be excused as
scheduling noise. Source cadence must remain at least 98% of nominal without
catch-up bursts, with source-thread policy readback/restoration verified.

Harness review corrected invalid measurement assumptions before final
qualification: coalescing sleep-based sources were replaced by independently
paced Mach source threads; main-loop inspection time was separated from SDK
receiver queue-insertion time; off/on camera segments share the same connection
and rational source grid; and the production-LUT wrapper now matches the app's
user-interactive processing queue. Earlier failed receipts remain historical
evidence, not rewritten passes or proof of hardware saturation.

Current final receipts establish:

- Six paired installed-extension output profiles (1080p NV12, 4K x422, 4K v210,
  each at 29.97/59.94), with every segment at least 30 seconds: all 16,194
  original frames delivered with exact pixels, order, PTS/duration and no retries.
  Source, useful monitoring and receiver-latency gates pass. No physical input
  was used. All outliers, including an earlier short-comparison failure, remain.
- Four-feed native 4K clean presentation passes a 30-second synthetic check at
  roughly 29.93–29.96 pictures/s per feed, with ledger teardown to zero. Explicit
  per-tile compositor estimates are included; this is not compositor-throughput
  measurement on four real windows/devices.
- Earlier one-feed declared LogC3/LogC4 EI800 paired recording cases pass both
  codecs in the short matrix; these used a processed picture with source-based
  classification. Two-feed ProRes passes that short matrix; two-feed HEVC
  tools-off clean-picture cadence fails (19.776/18.976 Hz), so those enabled
  comparisons are not promoted to qualified runs.
- A two-feed 30-second ordinary ProRes check preserves all media and useful
  monitoring but fails processing p99 latency (+5.3/+5.7 ms against a +5 ms
  allowance). Two feeds are not fully sustained-qualified by that result.
- Four independent native 4K full-tools feeds remain unqualified: observed
  picture delivery around 18.6–21 Hz does not consistently meet the 20 Hz gate.
  A Four Up layout and shared analysis do not establish four distinct full-tools
  feeds at every source rate/codec.

The previous reduced-tier 10 Hz target measured 9.9859 Hz in a 30-second
29.97-source HEVC run. The request was corrected to 12 Hz while retaining the
unchanged 10 Hz acceptance gate, phase-locked scheduling, full-source focus and
five-second recovery. Current scope12 fingerprints distinguish that correction
from prior receipts.

The final camera receipt is
`/Volumes/8TB/cinesomatic-director-work/agent-work/build/ultracam-e2e/cmio-smoke/controlled-source-final-v5-cap12-20261020/receipt-30s.json`.
The current recording/native receipt index is
`/Volumes/8TB/cinesomatic-director-work/agent-work/monitor-final-verification/qualification-scope12-index.json`.
Sustained sequence results and installed-host verification will be recorded in
VALIDATION after completion; short paired baseline comparisons must not be
described as 30-minute paired recording comparisons.

Further harness review found a Source picture declaration overwritten by a later
Processed Output assignment. Existing dimensions correctly recorded a 1920×1080
clean picture; those historical receipts cannot qualify native 4K source-picture
presentation. The corrected harness records/asserts the configured stage and
every clean frame's expected dimensions. Scope counting now uses a monotonic
sequence high-water mark and excludes warmup sequence zero. Per-work
autorelease pools match production capture. These corrections do not establish
the cause of any prior latency failure.

Later source-only hardening makes activity cleanup explicit before process exit
and matches the app's early all-Source tap before LUT processing. Earlier
disassembly shows the activity return retained; premature activity release was
not established. Existing results must therefore not be relabeled as proven
App Nap failures. New receipts will include explicit activity ownership evidence,
configured stage/dimensions and separate early Source callback timing.

The latest corrected-native-Source 30-second HEVC comparison still fails the
unchanged processing p99 tolerance: baseline 13.8 ms versus enabled 28.1 ms;
p95 improves from 9.3 to 8.4 ms. All 900 frames per side, audio/timecode references,
source cadence and useful picture/scope delivery pass. Opt-in value-only command
timestamps capture a 52.249 ms interval between GPU completion and return from
the processing wait, and a separate 37.135 ms wait before GPU execution followed
by 1.944 ms execution. Meter, consumer and terminal cleanup timing does not
explain those events. Driver completion/notification versus CPU scheduling still
needs diagnosis; no GPU saturation, production fix or causal success is claimed.
The long sequence and installation remain held while this failure is investigated.
Receipt:
`/Volumes/8TB/cinesomatic-director-work/agent-work/build/ultracam/monitor-recording/20261020T072842-35367/capacity-29.97-1feed-logc4-30s-compare-HEVC/takes/recording-receipt.json`.

A bounded same-device cross-queue experiment tests one proposed mechanism:
monitor GPU timing callbacks were held for approximately 240/397/650 ms while an
independent GPU blit signaled a shared event and a separate thread waited for it.
Those waits returned in 0.144/0.634/0.628 ms, before each callback was released.
Producer storage was already released and 2,175,104 bytes remained charged.
This is negative evidence for that injected cross-queue interference mechanism
on the current driver, not proof that every notification/scheduling path is
independent. No production policy change followed. The initial diagnostic is
preserved in `monitor-final-verification/monitor-cross-queue-diagnostic-initial.json`.

## Source-only priority feedback awaiting execution

Review confirmed a separate M7 gap: monitor admission could remain healthy while
the output pipeline missed its own frame budget. New source changes add bounded
per-producer metadata feedback. A queue-age-plus-processing-time breach of one
original input frame interval pauses new monitor analysis globally, preserving
owned clean presentation and all committed leases. One second of fresh healthy
samples permits reduced analysis; five further fresh healthy seconds restores
nominal quality. A gap over two frame intervals restarts the current fresh-health
span. Silence alone cannot recover a stalled producer.

Producer handles remain active when monitor surfaces hide. Explicit Stop/removal
clears their contribution; native generation and handle identity prevent stale
reports, stop or deinit from reviving/removing replacements. A new authoritative
handle starts a new native-generation epoch. The app reports already-known entry
pressure before its early Source offer, and completed timing after processing or
the no-output-demand branch. User tool settings and recording/camera contracts
are unchanged. This is priority enforcement, not a claim to fix OS scheduling.

Core policy, Metal clean/recovery/lifetime and actual-controller recording/camera
regressions are written. A read-only review caught and corrected an entry-report
ordering gap, replacement-handle high-water inheritance and hidden-epoch Stop
handling. These additions now pass 315 app and 96 package tests, strict
concurrency and warnings-as-errors, and a signed build with verified resources
and signature. The critical-feedback receipt is recorded in VALIDATION. That
snapshot predates the subsequently requested Sony ARRI-style correction.

The System Trace run did not reproduce the long tail. Its export lacked template
metadata; recovery import failed with `No space left on device`. No thread-state
causality is claimed. The trace left a 12,306,083,744-byte Instruments scratch file
internally. Automatic `dcg` review blocked its exact relocation from `/var` to the
external trace directory under rule `core.filesystem:mv-sensitive-source-root-home`.
The owner completed disk recovery; the named scratch path is absent and internal
headroom is restored to 81 GiB. No bypass was attempted. Heavy checks resumed;
final qualification and installation now await the corrected Sony sustained runs. Compact trace logs and failure metadata
remain in `monitor-final-verification/trace-hevc-20261020T074146` externally.

## Explicit remaining dependencies

- **EL Zone:** official palette and stop anchors are documented and tested, but
  authoritative continuous intervals, input interpretation and integration terms
  remain unresolved. The app reports this mode unavailable. No generic exposure
  classifier is labeled EL Zone. See [primary references](MONITOR_COLOR_REFERENCES.md).
- **Camera calibration:** published ARRI LogC3 EI800 and ALEXA 35 LogC4 EI800
  code-value classifications are supported for explicitly declared matching
  inputs. Sony S-Log3 reference math is not ARRI-on-FX3 calibration. Actual HDMI
  transport scaling, LUT/gamut/levels and physical source chains need qualification.
- **HDR:** PQ, HLG and unknown-transfer pictures keep clean native presentation;
  composed overlays are unavailable. Available numeric scopes retain explicit
  signal labels rather than applying an implicit SDR conversion.
- **Program:** source peaking/false color remain unavailable. Synthetic routing
  and stale-result tests do not qualify receiver-observed physical cuts.
- **Physical capacity:** real multi-input devices, window/compositor throughput,
  thermals and sustainable codec/tool combinations require matching executed
  receipts. Capture input remains 4K 10-bit 4:2:2, including bypass; 1080p is
  processed/virtual output, not a fabricated native-input test profile.

## Final documentation review

The final read-only review found and corrected an accidentally duplicated audit
document, an overbroad native-preview statement in README, missing HDR composition
limits, a stale two-job resource table and ambiguous memory-cap wording. The
accidental duplicate is preserved externally in the final verification directory;
this document restores historical findings and current dispositions. The original
Astra findings above were recovered directly from the reviewing agent's retained
report, not inferred from implementation success.

## Deferred low-impact shape limitation

A source admitted before critical-pipeline recovery can retain its existing width
when recovery caps analysis height. An ultrawide 1920×600 example can therefore
remain 1920×600 while a fresh offer would fit 1280×400. Memory remains charged and
bounded; current 16:9 qualification is unaffected. No ultrawide capacity claim is
made. A future change should apply the same width-and-height fit at both admission
and preparation, with an aspect-ratio regression.

## Sony workload checks and helper admission review

The current native four-feed 4K-v210 clean run passes at 29.796–29.829 unique
pictures/s per tile, 13.6/24.8 ms p95/p99 age, actual 3840×2160 dimensions and
zero retained ledger bytes after teardown. Receipt: `native-clean-sony-final-30s`.

The first Sony-Cine ProRes tools-off baseline admits/processes 899/900 frames,
so its enabled segment is skipped and no comparison is claimed. The recording
still preserves all 900 frames, audio and timecode with zero recording drops.
Read-only review finds a helper/app mismatch: helper admission uses `lock.try()`
on the statistics mutex, while production CaptureController uses a blocking
metadata-only lock and only rejects its capacity bound (12). The failed receipt
does not record rejection reason, so the particular missing processed frame is
not attributed conclusively to contention. A focused RED/GREEN reproduction proves the admission semantic mismatch and
validates the corrected metadata gate, including capacity 12 and drained state.
New declared comparisons pass both codecs, the second Sony gamut and two feeds;
see VALIDATION for current receipts. The original failure remains preserved.

The same predetermined first run's HEVC comparison passes: 900/900 processed and
recorded frames per segment, exact source/audio/timecode references, no drops,
pipeline latency p95 6.8→5.5 ms and p99 8.8→6.3 ms (off→on), useful monitor rates
29.927 picture / 15.013 scope Hz, p95 ages 12.5/12.8 ms and zero unavailable
requested tools. These results do not establish the cause of earlier OS/driver
latency tails. Complete first receipt is preserved under
`monitor-final-verification/sony-cine-primary-pair-30s/takes/recording-receipt.json`.

## Sustained qualification progress

The frozen Sony snapshot passes 30 minutes of four-feed native clean and two-feed
ProRes enabled monitoring, including full media decode, zero media/capacity drops,
matching-short-baseline latency tolerances, useful rates/ages and drained ledger.
See VALIDATION for exact measurements and receipts. Single-feed HEVC sustained
qualification also passes all 53,947 processed/recorded/decoded frames and fixed
rate, age, media and baseline-latency gates. The full sequence passes, with
161,841 recorded frames fully decoded across both codecs. After those runs
completed, app-only regressions reproduced and fixed the detached nil-target
chooser, removal topology refresh, late removed-feed callbacks and stale sink
consumers. The actual AppModel/hosted-window integration suite passes all 11
checks with complete strict concurrency and warnings as errors. The qualified
recording/Metal/helper sources are unchanged. The final suite passes 316 app,
112 strict package and 11 isolated integration checks. Signed host 12 is installed
and responds to native menu input; extension 4 sections are unchanged. Generated
media/caches and the old app copy are in recoverable Trash, with compact evidence
and source retained. See VALIDATION for the final executable hash and receipts.

## Source-picture coordinate regression

A live Source-view report exposed an untested nonidentity-output case: the
compositor inverted the source-to-output mapping even when its picture pixels
were already in source coordinates. This displaced focus and ARRI-style
classification and stretched clamped boundary samples into long lines. Host 14
uses identity for source pictures, retaining correspondence for processed
pictures. New BGRA/v210 scale/crop image comparisons failed before the change
and pass afterward; all 115 package checks pass under strict concurrency with
warnings as errors. Earlier identity-only tests did not cover this case.
