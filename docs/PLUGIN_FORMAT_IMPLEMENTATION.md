# Plugin and source-format implementation

Coordinated implementation of `VENDOR_PLUGIN_PLAN.md` (A) and
`SOURCE_FORMAT_PLAN.md` (B), started 2026-10-27.

Baseline HEAD: `37c3f8f062ab26921bad4b500c544b9093315463`.
Existing Sony, MonitorKit and other working-tree edits are retained. This is
not a clean baseline commit; do not stage those edits wholesale or describe
the initial test run as a clean-checkout run.

## Current integration checkpoint — 2026-10-28

The final coherent app runtime `20261029T021627-36836` passed all **1,237 tests
with zero failures and no skips**. Its camera-focused selection passed 39/39
and RecordingModel passed 29/29, including original-folder and recovery-root
edge cases. The earlier 1,237/1 run had one URL-alias fixture assertion; the
corrected snapshot changed only that test, with production sources verified
unchanged. Capture-focused validation passed 68/68 and GPU delivery lifecycle
passed 2/2.

Twenty-eight independent audit reports were reconciled against current fixes
and focused receipts in [PLUGIN_FORMAT_AUDIT.md](PLUGIN_FORMAT_AUDIT.md).
That ledger records the final automated gate and the remaining qualification
limits; original reports are historical findings, not current failure status.

MonitorKit completed 1,080 cases with zero failures (1,068 passed, 12 skipped).
The four opt-in window tests, eight affected raw-decoder tests and one quiet
CPU benchmark rerun passed separately. The quiet rerun measured 10.9 µs
against its 15 µs render-encode budget. Other intentionally skipped opt-in
lanes remain qualified as such. Rust behavioral tests passed all 20 cases.
The ingest/stop-drain focused receipts are
`/tmp/b7-ingest-test/stop-drain-green.log` (34/0) and
`/tmp/b7-ingest-test/r12-eight-green.log` (27/0).
`/tmp/recording-pcm-final.log` (27/0) is recording timing/colour/provenance
evidence, not the PCM-converter test-suite count.

The current local Sony SDK-present unsigned Release build and hardened bundle
validator passed. All seven runtime libraries and actual named localization
table lookups were verified; 208 source hashes were unchanged. Canonical
SDK-absent generation was restored and checked. The receipt is
`/Volumes/8TB/cinesomatic-build/vendor-sdkpresent-current-20261029/verification.json`.
This closes local SDK-present build validation, not physical camera operation,
external SDK-present CI, signed provisioning/CI or release qualification.

Fresh structural verification also passed all 137 cases across Build (58),
VendorSDK (11), Bundle (20), Boundary (14), CI (7) and CPU-pixel (27) suites.
Actual CPU-access lint classified 57 sites with zero unresolved, and canonical
generation passed. All six standalone manifest entries passed; the Sony
control rerun corrected only its obsolete no-retry test expectation, with
production unchanged. Its mock credentials/store, light/dark UI/overlay and
native adapter checks exited zero at 02:43:24 UTC; see the audit ledger receipt.

Fresh no-external-volume build proof remains unverified. The internal snapshot
completed locked Rust compilation/project generation, and package resolution
outside the outer sandbox succeeded using only internal MonitorKit. The
follow-up build denying `/Volumes/8TB` still failed on nested SwiftPM
`sandbox_apply: Operation not permitted` (exit 74), even with supported
package-resolution/update suppression flags. No supported Xcode option disables
the nested sandbox. No build remains active; qualification needs a fresh macOS
host/CI without the drive. Receipt:
`/private/tmp/ultracam-portability-1215fjje/verification.json`.

The user approved removal of unused `Sources/Recording/HEVCRecording.swift`;
root deleted it and regenerated the canonical project. Strict whole-app
compilation passed (run `20261029T024836-60558`, exit zero), and the three
replacement HEVC production checks passed with no skips. Logs are
`.build/agent-work/ultracam/logs/test-compile-20261029T024836-60558.log` and
`tests-hevc-cleanup-20261029T024836-60558.log` in the same directory. Deletion
is the only production delta from the 1,237/0 snapshot; remaining deltas are
tests/lint. This is a post-cleanup compile/focused pass, not another full run. The earlier automatic-review rejection is historical, with no approval
blocker remaining. Andrew's live FX3 full chain, other supported GPU families, external
SDK-present/signed CI and release/redistribution receipts remain pending.
Native VFR feed-camera forwarding stays explicitly refused until actual-client
qualification. These limits prevent claiming full plan completion despite the
green automated gates.

**Historical notes below are superseded by this checkpoint and the audit
ledger.** Earlier incomplete stages, missing registrations, failed runs and
“ongoing” implementation descriptions are retained as chronology only; they
do not describe the current software state or invalidate the final receipts.

## Integration order

1. A1 shared contracts, capture/control API, fakes and DeckLink adapter; B0
   independent fixes. Keep production capture behavior and legacy test seams.
2. A2 strict builds; A3 Sony split, generic store and migration. Integrate
   native moves with all build entry points in one verified wave.
3. A4 manifests/vendor moves; A5 typed core and UI adoption. Shared files and
   generated project have one owner at a time.
4. Activate B1 only after A5. B2–B7 can be prepared as isolated helpers/tests
   earlier; they are not complete until wired into production and verified.
5. Finish A6/A7 tooling, isolation and guide alongside B8/B9 cleanup using
   disjoint file ownership. Preserve both plans' live verification gates.

User requests up to 30 GPT-6.1 Sol subagents. This is a concurrency ceiling,
not a requirement to create overlapping work. Parent owns integration, this
log, plan reconciliation and `Tests/main.swift`; build owner serializes broad
builds and owns scripts/project generation. Focused TDD harnesses may run in
parallel; performance comparisons require a quiet run.

## Initial ownership

| Lane | Write surface | Integration gate | Verification |
|---|---|---|---|
| Shared formats | New Shared source contract and timebase files; corresponding tests | A1 types before consumers; timebase activation B3 | Canonical identity, validation, exact time arithmetic |
| Capture API | DeviceAPI capture types/fake, conformance tests | A1 | Lifecycle, stop races, ordering, bounded ownership |
| Control API/store | DeviceAPI control types/fake; new generic app store/credentials | A3 before UI migration | Generations, identity, secrets, late replies |
| Registry | DeviceAPI registry and claims; dedicated tests | A1 before live routing | Partial failures, ID validation, claims |
| DeckLink adapter | Temporary DeviceAPI adapter; native backend header/implementation; dedicated tests | Native grouping plus all builds | Callback parity and quiescence |
| Capture core | CaptureController, new services bridge, source-recording adapter | API/registry/adapter available | Existing behavior and plugin bridge parity |
| Sony | Vendors/Sony, existing Sony native files and Sony tools | Coordinate backend include removal with build owner | SDK-present/absent compile, lifecycle tests |
| Build | scripts, generated project, build contract tests | One integration/build wave at a time | Strict builds, manifests, target membership |
| GPU standby | New Shared GPU producer/shader and tests | Prepare now, activate B1 after proof | Actual GPU output for all published formats |
| B0 | UISupport, UISettings, UIPresentation, README; declaration tests | Complete; ownership released | Supported and unmatched source declarations |

## Test discipline

User required TDD after the first foundation edits began. Subsequent behavior
changes require a failing regression test before implementation, followed by
focused green and integration checks. Initial code-first foundation work is
reported honestly; B0 has retrospective red/green evidence against the actual
old and current function. No unit-test result substitutes for live capture,
client compatibility, SDK redistribution evidence or hardware validation.

## Current evidence

### Integrated checkpoint and active work

Part A automated integration is complete: strict UI **1,426/0**, monitor app
**37/0**, monitor host **19/0**, and contract CI **80/0**. Both actual unsigned
SDK-absent and Sony-present Release bundles built and validated with arm64 host
and extension. Camera, recovery and UITour helpers compiled without launching.
The canonical SDK-absent project is restored. The later distinct-device fake
regression passes its focused 13-test suite; it adds one test beyond the 749
app aggregate below and has not yet been included in another aggregate run.

B1a is active with disjoint shared, capture, native, LUT, recording and output
owners. Shared admission passes eight strict Swift 6 tests after recorded reds.
The actual recording writer first failed its new cadence rejection test before
the fix. Broad builds remain serialized after source freeze. Live FX3 checks
remain pending; unsigned validation bundles were neither launched nor installed.
Andrew explicitly requested continuing implementation and will test the FX3
later. Only this M4 Max is available for GPU qualification. After the 18-slot
proof and lifecycle tests passed, Andrew explicitly authorized: “Activate GPU
standby; track other hardware testing.” Other GPU families remain unverified;
the plan now records this activation decision. Metal 4 remains required with
no CPU or Metal 3 standby fallback.

B1a focused checkpoints now include shared admission **8**, LUT GPU admission
**4**, recording admission **6**, native adapter **18** plus **7** native checks,
DeviceAPI **14**, Program timestamp mapping **24**, and downstream output
admission **6** plus **16** existing camera checks, all passing their focused
runs. These counts overlap existing coverage and are not an aggregate total.
Capture-controller integration subsequently passed **27** focused tests
(10 new admission tests plus the prior 17 typed/budget/bridge tests). Actual
review reds preceded fixes for changed audio-clock bindings, admission after a
fatal event, audio-first declarations and old-epoch queued delivery. The full
`scripts/test.sh` gate subsequently passed on the frozen checkout: **793 app
tests / 0 failures**, **1,056 MonitorKit tests / 0 failures / 11 established
skips**, **80 contract fixtures**, and the Sony software/native/plugin/layout
checks. All **25 new suites / 136 methods** were verified executed. The strict
compiler log was empty. The historical GPU timing miss did not recur; no retry
or threshold change was needed. Evidence: `/tmp/ultracam-b1a-full-tests.log`.
The remaining B1a checks also passed: strict UI **1,426/0**, actual typed
monitor composition **37/0**, and the unsigned canonical SDK-absent bundle
and validator. Host and extension are arm64; the extension's new shared helper
membership compiled. No app launch, installation or signing occurred.
Derived output checks enforce geometry/layout and exact producer cadence;
complete colour enforcement remains with B4 so current HDR passthrough stays
working before the colour-aware catalog is installed.

The B1b CPU-access lint now has **18** passing fixtures and the real scan
passes with **31 classified sites / 0 unresolved** after production CPU standby
removal. Its classifications
are scoped to path, symbol and call shape; pinned SDK boundaries are reported
separately. VideoToolbox's internal conversion routes require the separate
writer/encoder tests and are not certified by lexical scanning. B1b policy,
sidecar and take-context implementation is now active. Its first actual
M4 Max standby proof passes all **18** published slots, checking **193,835,520**
media and padding bytes plus format/colour metadata. Lifecycle integration is
now passes **4** lifecycle and **6** actual runtime tests, including the default
production GPU route across all 18 slots. A 100-format-change regression first
submitted 101 fills; the fix bounds this to one active submission and coalesces
the latest requested format. All 16 existing camera checks pass with their
original pixel/timestamp assertions, adapted to await asynchronous readiness.
Recording policy/take lifecycle checks pass **23** focused tests, and settings
and badge activity pass **5** focused checks. Take-context ordering integration
and the combined B1b gate remain pending. Other GPU families remain unverified.
B1c retention work remains preparatory: the shared policy scratch and ownership
review are complete, but production queue/pool/cache limits have not been
activated or accepted as the B1c gate. B1d's settings scratch records the
intended migration and lenient decoding work; the production settings gate is
also pending. B2 remains a planned format-expansion step: no 1080p/720p input,
size/aspect catalog expansion, or row-byte capability should be inferred from
the current shared types or tests.

Preparation for later steps is not production activation:

- B1c shared policy scratch: `/tmp/ultracam-b1c-retention`; GPU pool/cache and
  CMIO transport ownership reviews are complete. Keep command concurrency,
  allocation bytes, queued-media duration and cache idle age separate.
- B1d settings scratch: `/tmp/ultracam-b1b-preparation.md` includes the actual
  legacy unknown-enum decoding red and migration scope.
- B3 follow-up: verify recording computer-clock timecode/creation-date use of
  the native frame-end host attachment. B1a corrected presentation mapping;
  the writer's `captureDate(of:)` still reads the original attachment and has
  no explicit frame-reference parameter. Preserve native SMPTE timecode.

The historical post-A5 optimized app gate passed **749 tests, zero failures** in
74.06 seconds (`/tmp/ultracam-a5-app-tests-2.log`). All 20 new suites executed
their 95 expected methods. Strict Swift compilation had no warnings, and the
manifest Sony software, credential, plugin and layout checks passed. The old
unlimited-burst test retains its 30-frame delivery assertions under an explicit
bounded fixture capacity; a new real GPU/camera/preview test uses the actual
production default constructor, verifies 12 admissions and 18 core refusals,
complete lease drain, zero other loss categories, and successful next-frame
delivery. Production capacity was not increased. Subsequent strict UI, monitor
integration and SDK-present/absent bundle gates passed as recorded above.

The optimized app-only integration checkpoint passed **714 tests, zero failures**
in 72.76 seconds. Its 13 new suites ran all 62 expected tests; the discovery
gate checks execution, not just compilation. Strict compilation emitted no
warnings. Paced/combined capture checks reported zero drops. Evidence:
`/tmp/ultracam-app-only-integration-10.log`. This checkpoint predates the A5
changes below and the successful combined B1a run recorded above.

Vendor native sources, SDKs, assets and vendor tests have moved into their final
folders. SDK contents were checked unchanged. Manifest-driven canonical
SDK-absent production UI typechecking passed after the move, including the
initial A5 settings/branding changes (`/tmp/ultracam-a4-ui-typecheck.log`).
Sony software checks passed 94 assertions through the actual generic store/UI;
credential checks used fake storage. Hardware and sandbox helpers were built
only, without a camera connection or launch.

The earlier strict UI run reported 1,395 passes and 18 failures. Seventeen
assertions still expected the old panel width despite the user's intentional
356-point columns; one confused an unavailable selected Log mode with an Off
selection. Those assertions were corrected with screenshot/source evidence and
a focused real-model regression. Later strict UI runs passed all 1,426 checks.

A5 source changes are implemented: typed production delivery, bounded source retention with
independent recording admission, scalar delivery reports, per-device vendor
settings and generic branding. Real failing regressions preceded the typed
format-admission fix and the GPU passthrough lease fix. Review also found reset
races, configuration-quarantine bypass and failed bootstrap HDR writes appearing
acknowledged; actual red regressions now precede passing focused fixes. The
current strict capture checkpoint passes 17 tests (typed admission/pairing 5,
budget 6, bridge 6). Shipping compilation excludes the eight legacy callback
seams and passed strict typechecking. Later combined results are recorded above.

The new boundary checker passed 12 fixture tests and initially rejected 42
remaining core vendor names. Neutral UI fallbacks, a neutral embedded-audio
converter name, comments and the virtual camera model now pass the actual
tree scan. Preset names and original SDK sample provenance are preserved.
This is text/target-membership lint, not compiler-enforced isolation.

A6 tooling has 11 SDK CLI fixture checks and 17 bundle validator checks,
including real Mach-O inspection and copies of installed Sony libraries. SDK
installation tests use temporary fixtures only. The real SDKs were verified
read-only; no SDK, camera, extension installation or signed bundle was changed.

The full package run executed 1,056 MonitorKit tests with 11 skips and one
timing failure: tetrahedral focus masking measured 0.41825 ms against a 0.400
ms limit. The quiet targeted repeat passed (median 0.348 ms) with no threshold
change. Preserve the original failure and repeat as separate evidence; do not
describe the original full `test.sh` invocation as passing. It stopped before
app compilation. The later full B1a invocation passed both package and app
stages without a retry; that does not erase this original failure.

The first foundations listed below are historical evidence, not a claim that
all later integration gates are complete. B1a activation followed the A5
automated checkpoint. A6/A7 tooling and documentation are integrated.
No live camera, client compatibility matrix,
deployment, platform Keychain check or official release qualification has run.

### Foundation evidence

- B0 source declaration checks: original function 10 failures; current function
  passes. Wording corrected; existing Unspecified defaults preserved.
- Shared format foundation: six focused checks pass with strict Swift 6
  compilation. Rate-aware timecode validation demonstrated red/green.
- Capture API/fake: seven focused checks pass; stale-epoch rejection and bounded
  group admission demonstrated red/green. Production adoption pending.
- Control API/fake: focused checks and strict compilation pass. Generic store
  and Sony adoption in progress.
- Build membership and manifest contract tests demonstrate intended red;
  implementation pending initial functional baseline completion.
- Initial package run exposed two MonitorKit failures (partial-tick flush
  snapshot and an inconsistent declared-pixel-aspect assertion). Both were
  reproduced and corrected; 41 focused package tests pass. The original app
  compile was deliberately not treated as a baseline after new files arrived.
- Native Sony separation and grouped DeckLink callbacks are integrated.
  DeckLink has eight runtime-discovered focused checks; subsequent regression
  fixes preserve frame timecode, paired audio and same-format clock resets.
- Registry-based live capture retains the legacy injection seam. Five bridge
  checks cover packet timing, pairing and callback/stop counter-read deadlocks.
- Generic control UI/store is wired; strict app/UI integration remains pending.
  Reconnect cleanup and sidecar write retry failures are being corrected with
  behavioral tests before another integrated run.
- Legacy unused `allTests` arrays were removed for strict concurrency; runtime
  XCTest discovery is unchanged. The build now verifies discovery counts for
  new suites so unexecuted tests cannot silently count as coverage.
- Inactive Part B helpers include recording timebase, compatibility policy,
  bounded sidecar, immutable extension catalog and GPU standby. Standby GPU
  proof covers six current pixel formats on M4 Max, not every supported Mac.
- Manifest schema and portable work-root helpers have focused contract tests;
  manifest activation/vendor moves and work-root script migration remain open.
- No full-suite or full-plan completion is claimed yet.
