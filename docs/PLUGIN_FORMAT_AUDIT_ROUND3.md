# Plugin and source-format audit — round 3

Scope reconciliation recorded 2026-10-29 (America/Chicago). Round 3 follows the user's rule: exclude only areas that had zero findings in **both** prior rounds. Prior fixed findings still count as findings for this rule. A missing prior audit is not a zero-finding audit.

## Exclusions

**No whole round-2 scope meets the double-zero criterion; all 30 scopes remain eligible.** Round 1 contains 28 independent report files. Round 2 contains 30 independent scope reports; `/tmp/audit2-monitor-ui-closure.md` is a closure addendum, not a 31st scope. These are scope/report counts, not unique defect counts.

Round 2's five zero-finding scopes were checked individually:

| Round-2 zero-finding scope | Round-1 evidence | Round-3 disposition |
|---|---|---|
| Capture lifecycle/epoch cancellation | [capture lifecycle](/tmp/audit-capture-lifecycle.md): two P2 findings (stale consumer continuation; startup cancellation) | Include |
| CPU-memory ownership/GPU ingest | [GPU ingest](/tmp/audit-gpu-ingest.md): one P1 and two P2 findings (storage registration, compatibility copy, ordering) | Include |
| Monitor engine/raw GPU decoders | [monitor GPU](/tmp/audit-monitor-gpu.md): P1 4K R12L texture dimension finding | Include |
| Shared source/storage contracts | [source contracts](/tmp/audit-source-contracts.md): P3 UYVA identity; [admission/layout](/tmp/audit-admission-layout.md): P2 final packed group | Include |
| Sony native SDK/discovery | [Sony control](/tmp/audit-sony-control.md) covers the Swift/native adapter and has two P2 lifecycle findings, but explicitly says unchanged SDK internals were excluded. There is no independent round-1 Sony-native zero-finding report. | Include: partial overlap and unreviewed native internals do not establish double-zero |

The finding counts in this table describe original report claims and are not a fresh confirmation of bugs in current source. Duplicate claims across reports are not added into a defect total here. Static zero findings do not establish hardware or runtime qualification.

## Mapping of all 30 round-2 scopes to the 28 round-1 reports

Mappings identify nearest substantive coverage; scope boundaries changed between rounds, so they are many-to-many rather than an asserted one-to-one partition. Names below are `/tmp/audit-<name>.md` for round 1 and `/tmp/audit2-<name>.md` for round 2.

| Round-2 report | Round-1 coverage | Round-2 result | Round-3 scope |
|---|---|---|---|
| app-ui | ui-settings; discovery-clocks | Findings | Include |
| audio-meter | pcm-audio; monitor-color-audio | Findings | Include |
| build-manifest | manifests-resources; ci-build | Findings | Include |
| camera-extension | camera-extension | Findings | Include |
| camera-sink | camera-sink; source-contracts | Findings | Include |
| capture-audio | capture-api; discovery-clocks; pcm-audio; cross-plan | Findings | Include |
| capture-contract | capture-api; test-gates | Findings | Include |
| capture-lifecycle | capture-lifecycle | Zero actionable findings | Include |
| ci-security | ci-build; manifests-resources | Findings | Include |
| control-contract | registry-credentials | Findings | Include |
| cpu-ingest | gpu-ingest; capture-lifecycle | Zero actionable findings | Include |
| cross-plan | cross-plan; source-contracts; program-timing; gpu-budgets | Findings | Include |
| decklink-native | decklink-native | Findings | Include |
| decklink-swift | decklink-swift; discovery-clocks | Findings | Include |
| lut | lut-gpu; admission-layout | Findings | Include |
| monitor-color | monitor-color-audio; ui-settings | Findings | Include |
| monitor-gpu | monitor-gpu | Zero actionable findings | Include |
| monitor-ui | monitor-gpu; monitor-color-audio; ui-settings | Findings | Include |
| pcm-audio | pcm-audio; cross-plan | Findings | Include |
| program-pixels | program-gpu | Findings | Include |
| program-timing | program-timing; gpu-budgets | Findings | Include |
| recording-model | recording-model | Findings | Include |
| recording-pixels | recording-pixels; gpu-budgets | Findings | Include |
| recording-timing | recording-timeline | Findings | Include |
| recording-writer | recording-writer; recording-timeline | Findings | Include |
| rust-switching | program-timing (Swift/Rust ledger and schema reviewed); test-gates | Findings | Include |
| sony-native | sony-control (adapter overlap; unchanged SDK internals explicitly excluded) | Zero actionable findings | Include |
| sony-plugin | sony-control; registry-credentials; manifests-resources | Findings | Include |
| source-formats | source-contracts; admission-layout | Zero actionable findings | Include |
| test-gates | test-gates; ci-build | Findings | Include |

Every round-1 report appears in this mapping. Round-2 scope/result sources: [round-2 scope matrix](PLUGIN_FORMAT_AUDIT_ROUND2.md#scope-matrix) and the five original zero-finding reports. Round-1 source: [reconciliation](PLUGIN_FORMAT_AUDIT.md) and original reports. No ancestor `AGENTS.md` was present at the repository or any ancestor through `/` when this reconciliation was prepared.

## Round-3 findings

All 30 independent `/tmp/audit3-*.md` scope reports were inspected. Ten scopes report **16 new actionable claims: one P1, fourteen P2, one P3**. Twenty scopes report no new actionable finding. No duplicate root-cause claim was identified, so the raw and normalized claim counts are both 16. These are static audit claims, not 16 executed reproductions. Earlier corrected findings mentioned in the reports are not counted again.

**The original inventory remains 16 claims. Subsequent independent fix review confirmed one additional audit claim (R3-17) and two fix-introduced regressions (R3-F01 ownership, R3-F02 synchronized declarations), tracked separately below: 17 audit claims plus two fix regressions, 19 tracked defects.** Fix ownership records work assignment only. No current production edit, passing test, or closure is inferred from an owner's assignment or files changing. Each original scope reviewer must independently review the corresponding fix; focused execution and broader integration evidence must retain their own snapshot/qualification boundaries.

| ID | Severity / claim | Original report | Assigned fix owner | Status |
|---|---|---|---|---|
| R3-01 | P2 — Clearing every input to None is lost on relaunch; empty saved selections are autoassigned again. | [app-ui](/tmp/audit3-app-ui.md) | `r3_fix_ui_settings` | Focused fix accepted by original reviewer; CPU extraction evidence only |
| R3-02 | P2 — Reusable capture transcript oracle accepts changed video/audio contracts and clock bindings within one epoch. Test validation defect; no native emission defect asserted. | [capture-contract](/tmp/audit3-capture-contract.md) | `r3_fix_contract` | Focused fixed; independent reviewer closed (root-reported) |
| R3-03 | P2 — Bundle dependency resolution skips an earlier existing external run-path match in favor of a later bundled/system candidate. | [ci-security](/tmp/audit3-ci-security.md), CI3-01 | `r3_fix_gates` | Focused fix accepted (root-reported); bundle fixtures only |
| R3-04 | P2 — Same-name legacy DeckLink hotplug can reuse another live device's fallback identifier. | [decklink-native](/tmp/audit3-decklink-native.md), first finding | `r3_fix_decklink` | Focused fixed; original reviewer accepted after ownership correction |
| R3-05 | P2 — Partial connector preference reapplication leaves stale ownership and restores the wrong video connector on stop. | [decklink-native](/tmp/audit3-decklink-native.md), second finding | `r3_fix_decklink` | Focused fixed; original reviewer accepted |
| R3-06 | P2 — Camera log picker edits leave contradictory source IDs and revert on settings reload. | [monitor-color](/tmp/audit3-monitor-color.md), MC-01 | `r3_fix_ui_settings` | Focused fix accepted (root-reported) |
| R3-07 | P3 — Program six-band/custom false color incorrectly shows an unavailable warning and omits its legend. | [monitor-color](/tmp/audit3-monitor-color.md), MC-02 | `r3_fix_ui_settings` | Focused fixed; independent reviewer accepted, including detached mode filtering (root-reported) |
| R3-08 | P2 — Failed asynchronous GPU feedback consumes unchanged picture/scope state and prevents resubmission. | [monitor-ui](/tmp/audit3-monitor-ui.md), MUI-1 | `r3_fix_monitor` | Focused fixed; original reviewer accepted; strict host 27/0/0 skips |
| R3-09 | P1 — Frozen feed allocations retain only discarded-core residency after GPU recovery. | [monitor-ui](/tmp/audit3-monitor-ui.md), MUI-2 | `r3_fix_monitor` | Focused fixed; original reviewer accepted; strict host 27/0/0 skips |
| R3-10 | P2 — Failed asynchronous freeze copy replaces the valid source before successful completion. | [monitor-ui](/tmp/audit3-monitor-ui.md), MUI-3 | `r3_fix_monitor` | Focused fixed; original reviewer accepted; strict host 27/0/0 skips |
| R3-11 | P2 — Odd-width accepted sources fail Program's intermediate preconversion path. | [program-pixels](/tmp/audit3-program-pixels.md) | `r3_fix_program` | Focused GREEN 17; independent reviewer accepted (root-reported) |
| R3-12 | P2 — Reselecting an original recovery root discovers takes without repairing/retaining its bookmark across destination changes. | [recording-model](/tmp/audit3-recording-model.md) | `r3_fix_recovery` | Focused fix accepted; included in later full 1,305/0 baseline |
| R3-13 | P2 — Candidate dwell completion can emit a director decision whose expiry has already passed. | [rust-switching](/tmp/audit3-rust-switching.md), RS3-1 | `r3_fix_rust` | Focused GREEN 23; original reviewer accepted |
| R3-14 | P2 — Performance-only UI success shares the full-suite success cache and can suppress required checks. | [test-gates](/tmp/audit3-test-gates.md), F1 | `r3_fix_gates` | Focused fixed; original reviewer accepted |
| R3-15 | P2 — UI verification cache omits the Rust sources, manifest, lockfile and build inputs of its compiled dependency. | [test-gates](/tmp/audit3-test-gates.md), F2 | `r3_fix_gates` | Focused fixed; original reviewer accepted |
| R3-16 | P2 — Standalone monitor runners accept skipped tests despite required GPU-proof policy. | [test-gates](/tmp/audit3-test-gates.md), F3 | `r3_fix_gates` | Focused fixed; original reviewer accepted |

The three monitor recovery claims are distinct: retry bookkeeping (R3-08), replacement-queue residency (R3-09), and preservation of valid copy pixels/source ownership (R3-10). The two UI-cache claims require separate mode isolation and dependency-closure corrections (R3-14/15). No cross-report duplicate was found.

The 20 no-new-finding reports are [audio-meter](/tmp/audit3-audio-meter.md), [build-manifest](/tmp/audit3-build-manifest.md), [camera-extension](/tmp/audit3-camera-extension.md), [camera-sink](/tmp/audit3-camera-sink.md), [capture-audio](/tmp/audit3-capture-audio.md), [capture-lifecycle](/tmp/audit3-capture-lifecycle.md), [control-contract](/tmp/audit3-control-contract.md), [cpu-ingest](/tmp/audit3-cpu-ingest.md), [cross-plan](/tmp/audit3-cross-plan.md), [decklink-swift](/tmp/audit3-decklink-swift.md), [lut](/tmp/audit3-lut.md), [monitor-gpu](/tmp/audit3-monitor-gpu.md), [pcm-audio](/tmp/audit3-pcm-audio.md), [program-timing](/tmp/audit3-program-timing.md), [recording-pixels](/tmp/audit3-recording-pixels.md), [recording-timing](/tmp/audit3-recording-timing.md), [recording-writer](/tmp/audit3-recording-writer.md), [sony-native](/tmp/audit3-sony-native.md), [sony-plugin](/tmp/audit3-sony-plugin.md), and [source-formats](/tmp/audit3-source-formats.md). Their exact inspected files, confidence and coverage limitations remain in each report. Zero new findings is not a correctness certificate.

R3-02 receipt: [RED](/tmp/r3-capture-contract/red.log) records one test with six failed assertions; [GREEN](/tmp/r3-capture-contract/green.log) records one test, zero failures. The focused harness uses extracted actual Transcript and production types (root-reported); this is one grouped claim, not six findings. Root reports original reviewer `r3_capture_contract` independently confirmed epoch immutability/reset and the allowed unknown-to-resolved audio transition. This contract correction was subsequently included in the recorded 1,305/0 baseline.

## Subsequent fix review and receipts

| Follow-up | Confirmed claim | Owner / current disposition |
|---|---|---|
| R3-17 (RS3-2) | P2 — Late forced-cut evaluation can still select a historical boundary whose instruction expiry has passed. Distinct from original candidate-dwell R3-13. [review](/tmp/audit3-rust-switching.md#closure-review-and-additional-forced-cut-expiry-case) | `r3_fix_rust`; focused GREEN 24; original reviewer accepted |
| R3-F01 | P1 — Initial legacy-identity fix shallow-copied `ComRef` via `std::move`, releasing references still used by the identity map/vector. This was introduced by fixing R3-04, not an original audit claim. [closure](/tmp/audit3-decklink-native-closure.md) | `r3_fix_decklink`; move-only ownership correction and reference-balance regression accepted by original reviewer |

| R3-F02 | P2 — MC-01's initial monitor callback fix called `updateCamera` with processing synchronization enabled, broadcasting one feed's camera-log declaration to other feeds. This was introduced while fixing R3-06. | `r3_fix_ui_settings`; minimal callback `shareProcessing=false` correction independently accepted by original monitor-color reviewer (root-reported); CPU RED four assertions to GREEN, actual affected XCTest and full strict UI GREEN |

The 17 audit claims comprise one P1, fifteen P2 and one P3. R3-F01 adds one confirmed P1 ownership regression. R3-F02 adds one confirmed P2 declaration-sync regression. Across all 19 tracked defects: two P1, sixteen P2 and one P3. R3-07's expanded blanket-disable and detached-toolbar corrections remain within the original Program false-color availability/legend claim; no extra independent claim is counted for that expansion.

- **DeckLink R3-04/05 and R3-F01:** [final closure](/tmp/audit3-decklink-native-closure.md) accepts both original fixes and the new ownership correction. [Ownership RED](/tmp/r3-decklink-ownership-red.log) records two suites/one failure; [GREEN](/tmp/r3-decklink-ownership-green.log) records two suites/zero failures. The reviewer inspected the empty [strict compile output](/tmp/r3-decklink-ownership-build.log). These are synthetic ownership/connector receipts, not hardware validation.
- **Recovery R3-12:** [original reviewer closure](/tmp/audit3-recording-model.md#independent-closure-review) accepts the retention/bookmark repair. The extracted actual scan method and real recovery/store implementation ran under a reduced model shell: RED three counterexample failures to GREEN. The subsequent full 1,305/0 app baseline supplies actual model-suite integration evidence; sandbox/export qualification remains separate.
- **App None R3-01:** [original reviewer closure](/tmp/audit3-app-ui.md#closure-review) accepts explicit persisted intent. Root reports RED eight assertions to GREEN. CPU extraction mirrors some descriptor encode/decode scaffolding and is not a full descriptor/app compilation receipt.
- **Monitor color R3-06/07:** root reports MC-01 and MC-02 accepted, including permitted modes in the detached toolbar. Four actual `B1dSettingsMigrationChecks` XCTest cases were added; helper-focused checks were GREEN, and the subsequent affected 208/0 receipt executes the expanded 12-case suite. No complete settings/UI integration pass inferred.
- **CI R3-03 and test gates R3-14/15/16:** root reports CI fix accepted; [test-gate original reviewer closure](/tmp/audit3-test-gates.md#independent-closure-review-current-fixes) accepts all three gate fixes. [RED](/tmp/audit3-gates-red.log) has 12 subcase/method failures across five selected tests; [GREEN](/tmp/audit3-gates-green.log) selects three standalone-verifier tests plus two bundle tests, not five standalone tests. [Broader contracts](/tmp/audit3-gates-broad.log) additionally covers prior GPU-proof policy. Actual standalone UI/GPU execution and a newly built bundle are separate gates.
- **Rust R3-13:** [review](/tmp/audit3-rust-switching.md#closure-review-and-additional-forced-cut-expiry-case) accepts candidate expiry correction; [RED](/tmp/audit3-rust-red.log) shows two focused failures and [GREEN](/tmp/audit3-rust-green.log) passes 21 director plus two ledger tests. The subsequent forced-cut R3-17 fix is also independently accepted: [RED](/tmp/audit3-rust-forced-red.log) reproduces cut3/expiry5 at tick5.2; [GREEN](/tmp/audit3-rust-forced-green.log) records 22 director plus two ledger tests passing.
- **Program R3-11:** root reports focused GREEN 17 and independent reviewer acceptance. **Monitor R3-08/09/10:** original reviewer independently closed all three fixes; strict host and separate Metal-validation receipts are recorded below.

All 16 original claims, the additional audited claim and both fix-introduced regressions now have focused fixes and independent reviewer acceptance: 19 accepted tracked defects, none pending focused closure. This count is 19 tracked defects total, not 19 original audit findings. Root reports the new helper is wired into standard `scripts/test.sh`; adding that gate is not proof of executing the combined gate.

Monitor closure evidence: [handoff](/tmp/r3-monitor-fix-report.md) and [original reviewer closure](/tmp/audit3-monitor-ui.md). [Mutation RED](/tmp/r3-monitor-red-runtime.log) ran 27 tests with eight assertion failures and two unexpected errors; the three targeted regressions failed. A wrong RGB-plane unwrap in the RED fixture was corrected before final GREEN; other residency failures independently demonstrated the defect. [Final strict GREEN](/tmp/r3-monitor-green-final.log) ran 27 tests, zero failures, zero skips. Reusing the exact binary with Metal API/shader validation enabled [ran 27 tests, zero failures, one expected pipeline-archive skip](/tmp/r3-monitor-metalvalidation.log); all three new recovery tests passed. Three scoped source hashes matched before/after (root-reported). The earlier run compiled before its fixture correction is discarded as final evidence. This establishes focused host recovery/residency behavior on this machine, not other-GPU or full-app qualification.

## Combined app validation — failed first run and fixture correction

The [first current-tree app runtime](/Volumes/8TB/cinesomatic-build/ultracam-round3-final-1793309195495652000/app-runtime.log) executed 1,305 tests with two assertion failures in one Program test, zero unexpected errors, in 322.396 seconds (root-reported summary). This is a failed run and is retained as such; it is not final validation success.

The deterministic [actual route/bridge fixture RED](/tmp/program-budget-fixture/red.log) published 23 of 30 samples with seven overflows: the fixture blocked consumption while exceeding the legitimate 0.4-second retained-surface budget. The corrected fixture pumps its background consumer per frame while preserving 30 deliveries, off-main ingest/send and exact PTS. [Focused GREEN](/tmp/program-budget-fixture/green.log) reports 30 exact host-grid samples, zero overflow and zero main-thread sends. Root inspected the correction and closure. Only the test changed; production remained frozen (root-reported).

This is an integration test-fixture correction, not another confirmed production defect; that correction did not increment the then-current 18-defect count. The corrected full-app retry subsequently passed with the composed receipt below; the failed first run remains historical evidence.

## Corrected coherent validation

The [composed receipt](/Volumes/8TB/cinesomatic-build/ultracam-round3-final-1793309939781180000/COMPOSED_RECEIPT.json) records corrected app **1,305 tests, zero failures/unexpected errors and no skips**, XCTest duration 315.678 seconds. Strict compilation exited zero in 287.158 seconds. Exact app/vendor discovery, app coverage, required GPU-proof skip policy, static checks, Rust 24 (22 director plus two ledger), and all six vendor CLI entries passed against the recorded snapshot. The [1,240-file manifest](/Volumes/8TB/cinesomatic-build/ultracam-round3-final-1793309939781180000/SNAPSHOT_SHA256.json) identifies that source baseline. Only the Program test-fixture correction and documentation changed after the failed run; production remained frozen (root-reported).

The [retained package receipt](/Volumes/8TB/cinesomatic-build/ultracam-round3-final-1793309939781180000/RETAINED_PACKAGE_RECEIPT.json) establishes exact hash equality of 281 package files. It retains the prior package 1,080 completed/12 skipped result and separate required benchmark 1/0/no skips; this is **not a fresh package run**. The composed validation does not claim a monolithic `test.sh` pass or eliminate those recorded optional skips.

The subsequent [strict UI run](../.build/agent-work/build/ultracam/ui-verify/20261029T215012-61827/ui-verify.log) recorded 1,426 passed, one failed, zero pending and 223 images in 161 seconds (root-reported). The failure exposed R3-F02, an actual fix-introduced production regression; this failed UI run is retained and is not green validation. The minimal AppModel callback now sets `shareProcessing=false`, while other update callers retain the default true behavior. Root reports CPU RED four assertions to GREEN, one added actual regression in the 12-case `B1dSettingsMigrationChecks` suite, and independent original-reviewer acceptance. The subsequent affected runtime below executes that suite.

**The 1,305/0 full-app receipt predates this one-production-file `AppModel.swift` delta.** Final strict compilation and 208 affected tests subsequently passed as recorded below. Subsequent strict UI, monitor integration and shipping results are recorded below. The aborted monitor-integration run `215428` produced no result. No combined current-tree full pass is inferred from the prior baseline and focused helper. Signing, release and physical-device qualification remain separate.

## Current AppModel delta — affected validation GREEN

The [current composed receipt](/Volumes/8TB/cinesomatic-build/ultracam-round3-final-1793311015043563000/COMPOSED_RECEIPT.json) records **208 affected tests, zero failures/unexpected errors and zero skips in 8.086 seconds**, exact selected-suite discovery and required GPU-proof policy passing. Whole-app strict compilation passed in 358.664 seconds and static checks passed in 13.154 seconds. The current snapshot remained unchanged during validation and live code matches it; subsequent differences are documentation only (root-reported).

The 208 cases comprise B1d settings migration 12, settings 18, monitor coordinator 65, LUT-space settings six, derived admission 11, declared signal three, monitor host 27, source-format route one, automatic feed ten, and UI presentation 55. This executes the new sync-isolation regression and settings cases previously marked unrun. Final evidence composes the earlier full **1,305/0** baseline with these current affected **208/0** results; **no fresh full 1,306-test runtime is claimed**. The receipt lists the sole production delta `AppModel.swift`, plus its test/helper and ledger differences, and confirms unchanged package source.

The forced [full strict UI rerun](../.build/agent-work/build/ultracam/ui-verify/20261029T220421-73553/ui-verify.log) passed **1,427 checks, zero failed/pending, 223 images in 172 seconds**. The original synchronization/false-color failure now passes with its assertion intact (root-reported); no fixture weakening is claimed. The earlier 1,426/one-failed UI run remains historical evidence above.

The [final monitor integration](../.build/monitor-app-integration/20261029T220858-78049/tests.log) passed **37 tests, zero failures and zero skips**, including its required-proof gate (root-reported gate result). UI 1,427/0 and integration 37/0 ran against the same current code. The owner reports identical before/after hashes for 270 source files, digest `a4a60d7c9a97365dcc84899f8b2e4cb840491feb9185c770c006e02302072b21`.

Refreshed unsigned shipping validation passed for Debug with SDK absent and Release with SDK present (root-reported exit zero). The [final verification](/Volumes/8TB/cinesomatic-build/shipping-round3-final-20261029-221248/final-verification.json) records no source changes and source-equal localization tables in both products: SonyControl 36 entries and BlackmagicCapture seven. Root additionally reports updated validators passed for arm64 host and extension, Debug had zero embedded SDK frameworks, Release contained exactly seven Sony libraries, and 427 hashes remained unchanged. Final `AppModel.swift` hash: `509a755a5d3f943f740d984338055fa356925fc36dca1984d219171eed2eebe6` (root-reported). Canonical SDK-absent project generation was restored in final cleanup.

All authorized round-3 code, focused review and local automated validation are complete. Final evidence composes the earlier full app 1,305/0 with current affected 208/0, strict UI 1,427/0, monitor integration 37/0, and refreshed unsigned shipping checks; it is not a fresh current-tree full 1,306-test or monolithic `test.sh` receipt. Actual signing, external CI, release/redistribution, physical FX3/SDI/Sony behavior, other supported GPU families and previously unproven no-external-drive portability remain external/manual qualification limits.

## Verification boundaries

The audit reports describe read-only static inspection of the shared working tree. Proposed regressions are not execution receipts. The original static reports themselves establish no runtime qualification; subsequent focused executions above have their stated narrow scopes. The first combined app run failed as recorded above; the corrected coherent full-app retry passed with the exact boundaries below. Native device, other-GPU, SDK, signing and release qualification remain separate. Earlier rounds' receipts remain tied to their recorded snapshots. Local `/tmp` reports may expire; preserve them with final integration evidence.

This ledger's author inspected reports and edited this document only; no production/test edits, builds, tests, commits or worktrees were performed.
