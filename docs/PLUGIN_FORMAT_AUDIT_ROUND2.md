# Plugin and source-format audit — round 2

Independent Sol 6.1 read-only review of the current shared workspace, 2026-10-29. Baseline under review: `dcb58e1`, with dirty/untracked MonitorKit submodule changes included. The original implementation baseline `37c3f8f062ab26921bad4b500c544b9093315463` is historical context. This ledger preserves [round 1](PLUGIN_FORMAT_AUDIT.md); it does not overwrite or extend its 1,237/0 receipt to later source changes.

Thirty scopes produced `/tmp/audit2-*.md` reports. They inspected assigned production code and integration, with per-report exact file inventories and explicit limits. Review itself did not run builds, tests, GPU/UI, hardware, network, signing or Keychain actions. Subsequent owner executions below are separate evidence. This document was written read-only with respect to production/tests; no builds were started by its author.

## Latest source and gate checkpoint

All **51 confirmed source findings** have focused fixes and independent reviewer
closure; the retained 52nd ID is withdrawn. Combined execution also exposed a
LUT lease defect and two UI defects, now fixed and reviewer-closed. Composed
receipts pass app1,292/0, current meter19/0, strict UI1,427/0, monitor host24/0
and integration37/0, CLI6, required GPU follow-up1/0 and Sony runner corrections.
The app receipt predates the final two-file meter delta; current focused/UI
receipts cover that delta. Refreshed unsigned SDK-absent Debug and SDK-present Release shipping builds also pass with unchanged source hashes.
The failed initial monolithic run remains historical; no monolithic success or
signed/hardware qualification is claimed.

The initial858-file snapshot gate23728 stopped before heavy phases because
`.github` workflows were omitted. The corrected complete-checkout snapshot
`/Volumes/8TB/cinesomatic-build/ultracam-stage2-final-1793301464099283000`
(1,236 files; no missing compiled-suite registrations) then passed strict app
compilation but failed runtime: **1,290 tests, seven assertion failures,
zero unexpected errors across four cases**. It is terminal, not a live gate.
Exact [failure summary](/tmp/ultracam-stage2-failures.md) and
[full app log](/Volumes/8TB/cinesomatic-build/ultracam-stage2-work-1793301464099283000/agent-work/ultracam/logs/tests-20261029T191755-32640.log).

MonitorKit completed1,080 with zero errors and12 skips; its required Metal4
CPU encode benchmark skipped because compute10.3µs exceeded10µs under load13/12.
A quiet targeted rerun now passed1/0/0 with unchanged source/test hashes, compute9.4µs≤10µs, and no threshold/flag changes; [receipt](/Volumes/8TB/cinesomatic-build/monitorkit-final-required-benchmark/evidence.json). This closes only the required benchmark follow-up; the original1080/12-skip package receipt remains historical.
Rust22 passed. Post-app standalone vendor CLI entries were not reached.
The coherent retry [app runtime](/Volumes/8TB/cinesomatic-build/ultracam-stage2-retry-1793303244042887000/app-runtime.log)
passed **1,292 tests, zero failures/unexpected errors, no app skips** in306.963s,
exit zero, after strict compilation. Exact app and vendor suite discovery checks
passed; all three lease regressions are included. The only production delta from
the failed full snapshot is the LUT lease retirement fix; test fixture
corrections are also included.

This is **composed validation**, not a retroactively monolithic test.sh pass:
unchanged package hashes retain1,080 completed/12 skips plus the separate quiet
required benchmark1/0/0; Rust22 and static receipts are retained.
[Standalone vendor CLI six-entry run](/Volumes/8TB/cinesomatic-build/ultracam-stage2-retry-1793303244042887000/vendor-cli.log) passed.
[Shipping UI typecheck](/tmp/ultracam-round2-ui-typecheck.log) passed.
SDK-absent Debug and SDK-present Release unsigned shipping builds both passed.
[Initial shipping verification](/Volumes/8TB/cinesomatic-build/shipping-round2-20261029-200707/final-verification.json)
records unchanged source hashes and source-equal localization tables (Sony36,
Blackmagic7) in both actual bundles. Root additionally verified arm64 bundles,
shared app-group policy, seven Sony runtime libraries present only in the
SDK-present build, and canonical SDK-absent restoration. No signed qualification
is implied.

The vendor CLI27-versus26 deployment warning is resolved by three test-runner
script changes; production Sources remained unchanged. Exact reruns passed
without warnings: [control](/tmp/sony-target-control.log),
[credentials](/tmp/sony-target-credential.log),
[plugin](/tmp/sony-target-plugin.log). Actual native object and Swift executable
`LC_BUILD_VERSION` both report minos26.0 ([receipt](/tmp/sony-target-build-version.log)).
Root freshly ran BuildContracts68/0 in5.117s and git diff whitespace check clean.
The first strict UI run compiled cleanly but failed1,414/12 with zero pending
(223 images,173s): six live-idle CPU cases88–92% and six viewer counts11→13.
[Original receipt](/Volumes/8TB/cinesomatic-director-work/agent-work/build/ultracam/ui-verify/20261029T201445-81365/ui-verify.log).
Both findings are now fixed and independently reviewer-closed. The corrected
[strict full UI](/Users/andrew/Projects/ai/ultracam/.build/agent-work/build/ultracam/ui-verify/20261029T202220-86784/ui-verify.log)
passes **1,427, zero failures/pending,223 images in178s**. Unchanged<25%
Onone idle budgets pass: two-camera10.1/6.4/7.2%, four-camera10.2/7.3/7.8%;
meter cadence is preserved. All six lifecycle checks plus the new mono
accessibility case pass. [SourceAudioMeter focused19/0](/tmp/ultracam-live-meter-perf/attachment-close-green.log)
also passes on current code.

The UI fixes change two production files after app1,292/0 and both earlier
shipping builds. Therefore current validation is composed app1,292 + focused
meter19 + strict UI1,427, **not** a claimed app1,293/full-rerun result. Monitor host24/0 and integration37/0 pass without skips. Refreshed unsigned
SDK-absent Debug and SDK-present Release builds and actual arm64 host/extension
bundle validation also pass: [final shipping verification](/Volumes/8TB/cinesomatic-build/shipping-final-refresh-20261029-204358/final-verification.json).
Source hashes remained unchanged and match the final meter/UI receipts; both
bundles contain source-equal Sony36/Blackmagic7 localization tables. Debug omits
Sony runtime libraries; Release contains exactly seven. Canonical generation was
restored. No known source defect or authorized execution gate remains open;
signed/hardware qualifications stay separate.

## Combined-run integration follow-ups

These preserve the original52-ID inventory and separately track failures found
by combined execution, rather than silently relabeling them as closed.

| Follow-up | Evidence / disposition |
|---|---|
| R2-I01 — independent LUT passthrough retains capture SDK lease | SCOPED CLOSED — actual [GPU GREEN3/0](/tmp/b4-lease-green.log), independently reviewer-closed. ARC retirement of GPU/callback resources now precedes permit signal. New regressions keep the lease alive through callback return and release it after idle, even with handler blocked after permit. Original failure was a production ownership defect, not fixture-only. Final app1,292/0 includes these regressions; CLI6 and unsigned builds2 passed separately; strict UI1,427/0 passed after the later meter fixes; monitor host24/0 and integration37/0 passed without skips; refreshed unsigned shipping2 passed. |
| R2-I02 — Program fixture backlog assumptions | Two Program cases contributed five assertions: capture-thread ordering416 versus23 delivered, and fractional grid10 versus9. Owner corrected fixture drain scheduling: [RED](/tmp/program-budget-fixture-red.log) → [focused2 GREEN](/tmp/program-budget-fixture-green.log) inspected; corrected app1,292/0 now passed; CLI6 and unsigned builds2 passed separately; strict UI1,427/0 now passed after fixing R2-I05/I06; monitor host24/0 and integration37/0 passed without skips; refreshed unsigned shipping2 passed. Production regression is not inferred from these fixture assertions. |
| R2-I03 — stale source-profile transport assertion | `DerivedOutputAdmissionChecks...:77` expected manualPQ to replace physical709 matrix. Corrected test-only to preserve transport and applied to the new coherent snapshot. Linked R2-21/R2-21.M settings/runtime follow-up; Corrected app1,292/0 now passed, including settings/transport fixtures; CLI6 and unsigned builds2 passed separately; strict UI1,427/0 now passed after fixing R2-I05/I06; monitor host24/0 and integration37/0 passed without skips; refreshed unsigned shipping2 passed. |
| R2-I04 — required package GPU proof skipped under load | SCOPED CLOSED — quiet actual benchmark1 passed/0 failed/0 skipped, compute9.4µs≤10µs; unchanged Sources+Tests hashes and no threshold/flag changes. [Evidence](/Volumes/8TB/cinesomatic-build/monitorkit-final-required-benchmark/evidence.json). Original1080 package/12skip receipt remains historical; this is not a new complete package run. |
| R2-I05 — live idle meter CPU regression | CLOSED with actual strict full UI1,427/0 and independent static reviewer closure. Identity-only main-actor replacement polling preserves meter cadence; unchanged<25% Onone budgets now pass:2cam10.1/6.4/7.2%,4cam10.2/7.3/7.8% versus prior88–92%. Exact new UI receipt above; earlier failure remains historical. |
| R2-I06 — viewer attachment lifecycle leaks | CLOSED with actual strict UI1,427/0: all six attachment lifecycle checks and new mono accessibility case pass. Explicit Attachment close validated by [focused SourceAudioMeter19/0](/tmp/ultracam-live-meter-perf/attachment-close-green.log). Reviewer closed; current two-file production delta is covered by refreshed unsigned shipping2 with matching source hashes. |

The first final monitor integration attempt stopped at harness compilation because
`Tools/MonitorAppIntegration/main.swift` still supplied the removed `inputFast`
property. The obsolete harness argument was removed; this is a verification-only
correction with no production delta. Root independently reviewed the current
`burnInLUT` active policy. The next [monitor runtime](/tmp/ultracam-round2-monitor-app-scope-rate-failed.log)
ran37 tests with four assertion failures in one case and zero skips: its stale
scope-cadence expectation ignored the intentional10/15Hz user cap. Actual9.5/14Hz
at picture30 matched the committed `scopeCadence` policy and plan line424. The
harness expectation was corrected and independently reviewer-accepted; no
production source changed. Actual [monitor host24/0/0 skips](/tmp/ultracam-round2-monitor-host.log)
now passes. The corrected [integration37/0/0 skips](/tmp/ultracam-round2-monitor-app-final.log)
also passes. Selected10/15/30Hz scope measurements were9.40/14.42/26.42fps;
picture remained30.17/30.34/29.91fps with busy/noDrawable0 in every case.

## Count and status rules

Initial inventory: **54 raw claims → 52 deduplicated IDs**. Two repeated observations share IDs: take-pause metering (audio-meter + PCM) and queued Program surface retention (cross-plan + Program-timing). The camera mixed-active/pending stop claim was initially conditional and is now **withdrawn as a confirmed bug** after native callback-contract review. Its ID stays in the ledger; **51 actionable claims** remain in the original inventory, not 51 reproduced failures. Five scopes reported no independently actionable finding. Linked subfinding `R2-21.M` tracks the later monitor-override integration gap under the same source-override root cause; the grouped count stays52. Counts are claim inventory, not proof that all claims remain open or all fixes are correct.

- **Pending**: static finding awaits reproduction or owner evidence.
- **Reproduced RED**: a targeted test failed as expected; no closure until corresponding GREEN/recheck.
- **Focused fixed**: reported code change plus relevant successful execution/review; final combined gate remains separate.
- **Withdrawn**: original proposed bug trigger was not established under the native callback contract; keep ID/history but exclude it from open-defect counts.
- A filename containing `green`, a code edit, route registration or test existence is not a successful receipt.

## Scope matrix

| Scope / exact report | Assigned fix owner | Finding IDs / scoped result |
|---|---|---|
| App discovery/UI: [report](/tmp/audit2-app-ui.md) | `pause_shareable` | R2-01 |
| Audio meter/app views: [report](/tmp/audit2-audio-meter.md) | `audio_meter_integration` | R2-02, R2-03, R2-04 |
| Build generation/SDK publication: [report](/tmp/audit2-build-manifest.md) | `b0_fixes` | R2-05, R2-06 |
| CMIO runtime/authorization: [report](/tmp/audit2-camera-extension.md) | `b2_extension_catalog` | R2-07, R2-08, R2-09 |
| App camera transport: [report](/tmp/audit2-camera-sink.md) | `shared_formats_recovery` | R2-10, R2-11 |
| Capture-to-recording paired audio: [report](/tmp/audit2-capture-audio.md) | `capture_core` | R2-12, R2-13, R2-14 |
| Reusable capture transcript oracle: [report](/tmp/audit2-capture-contract.md) | `capture_api` | R2-15, R2-16 |
| Capture lifecycle/epoch cancellation: [report](/tmp/audit2-capture-lifecycle.md) | `capture_core` | No independently actionable finding; static scope only |
| Signed bundle/universal dependencies: [report](/tmp/audit2-ci-security.md) | `audit_ci_build` | R2-17, R2-18 |
| Generic control/credentials: [report](/tmp/audit2-control-contract.md) | `control_api` | R2-19, R2-20 |
| CPU-memory ownership/GPU ingest: [report](/tmp/audit2-cpu-ingest.md) | `queue_audit` | No independently actionable finding; static scope only |
| Cross-plan storage/retention: [report](/tmp/audit2-cross-plan.md) | `b4_color_contract / program_retention` | R2-21, R2-22 |
| Native capture/discovery/connector: [report](/tmp/audit2-decklink-native.md) | `decklink_adapter` | R2-23, R2-24, R2-25 |
| DeckLink Swift observation: [report](/tmp/audit2-decklink-swift.md) | `decklink_adapter` | R2-26 |
| LUT decode/conversion: [report](/tmp/audit2-lut.md) | `b4_lut_paths` | R2-27, R2-28 |
| Monitor source declaration picker: [report](/tmp/audit2-monitor-color.md) | `pause_shareable` | R2-29 |
| Monitor engine/raw GPU decoders: [report](/tmp/audit2-monitor-gpu.md) | `monitor_ui_fit` | No independently actionable finding; static scope only |
| Monitor display/recovery/scopes: [report](/tmp/audit2-monitor-ui.md) | `monitor_ui_fit` | R2-30, R2-31, R2-32, R2-33; linked R2-21.M |
| PCM/take meter admission: [report](/tmp/audit2-pcm-audio.md) | `audio_meter_integration` | R2-03 |
| Program GPU range/geometry: [report](/tmp/audit2-program-pixels.md) | `b2_program_scaling` | R2-34, R2-35 |
| Program cadence/drift/retention: [report](/tmp/audit2-program-timing.md) | `program_retention` | R2-36, R2-37, R2-22 |
| Model/recovery roots: [report](/tmp/audit2-recording-model.md) | `b9_estimator_cleanup` | R2-38, R2-39 |
| Recorder GPU/input contract: [report](/tmp/audit2-recording-pixels.md) | `b5_recording_matrix` | R2-40 |
| Recording CFR/timecode arithmetic: [report](/tmp/audit2-recording-timing.md) | `b3_vfr_timeline` | R2-41, R2-42 |
| Writer failure/drain/finalization: [report](/tmp/audit2-recording-writer.md) | `recording_policy` | R2-43, R2-44 |
| Swift/Rust ledger/replay/diagnosis: [report](/tmp/audit2-rust-switching.md) | `b0_fixes / r2_rust_switching` | R2-45, R2-46, R2-47 |
| Sony native SDK/discovery: [report](/tmp/audit2-sony-native.md) | `sony_plugin` | No independently actionable finding; static scope only |
| Sony prepare/connect/options: [report](/tmp/audit2-sony-plugin.md) | `sony_plugin` | R2-48, R2-49 |
| Shared source/storage contracts: [report](/tmp/audit2-source-formats.md) | `shared_formats_recovery` | No independently actionable finding; static scope only |
| Integration runners/GPU gates/diagnosis: [report](/tmp/audit2-test-gates.md) | `b0_fixes` | R2-50, R2-51, R2-52 |

## Deduplicated finding ledger

| ID | Severity / finding | Evidence status |
|---|---|---|
| R2-01 | P2 — Supported-mode-only discovery updates are dropped. [report](/tmp/audit2-app-ui.md) | Focused fixed — owner reports two red→green UI/profile regressions; root confirms GREEN. Root confirms independent reviewer closure; exact focused receipt not yet supplied here. Full app separate. |
| R2-02 | P1 — Visible meter views keep a replaced session. [report](/tmp/audit2-audio-meter.md) | Focused fixed/reviewer closed — [final18 meter checks GREEN](/tmp/ultracam-audio-meter-check/session-claim-green.log) and actual [verify helper16 GREEN](/tmp/ultracam-audio-meter-check/ui-verify-concurrent-green.log); stable Attachment rebinds read/reset target. Full app separate. |
| R2-03 | P2 — Take pause membership depends on drain scheduling. [report](/tmp/audit2-audio-meter.md), [report](/tmp/audit2-pcm-audio.md) | Focused fixed/reviewer closed — per-slot take measurement eligibility; final18 GREEN and old drain-time policy reproduced four failures, owner-reported. Duplicate PCM report shares this ID. |
| R2-04 | P2 — No-packet attachment sessions retain meters without bound. [report](/tmp/audit2-audio-meter.md) | Focused fixed + independent reviewer closed (root-confirmed) — shared atomic producer claim protects prune+publication; coalesced session replacement runs off realtime thread. [Mutant RED1](/tmp/ultracam-audio-meter-check/read-only-claim-red.log) → [focused GREEN18](/tmp/ultracam-audio-meter-check/session-claim-green.log), including held producer100 transitions/history bound/first-packet preservation and nonblocking callback. Actual [AudioMeterTapVerify16 GREEN](/tmp/ultracam-audio-meter-check/ui-verify-concurrent-green.log) also passed. Corrected app runtime1,292/0 now passed; CLI6/builds2 passed; Sony script-only reruns passed; strict UI1,427/0 now passed after fixing R2-I05/I06; monitor host24/0 and integration37/0 passed without skips; refreshed unsigned shipping2 passed. |
| R2-05 | P2 — Failed SDK publication leaves directories blocking retry. [report](/tmp/audit2-build-manifest.md) | Focused fixed + independent closure recheck confirmed by root. [SDK RED](/tmp/audit2-sdk-red.log) → [GREEN13](/tmp/audit2-sdk-green.log). Full gate separate. |
| R2-06 | P2 — Relative inventory guard path resolves against wrong cwd. [report](/tmp/audit2-build-manifest.md) | Focused fixed + independent closure recheck confirmed by root. [Generation RED](/tmp/audit2-generation-red.log) → [GREEN](/tmp/audit2-generation-green.log); current BuildContracts65 pass below. |
| R2-07 | P1 — Expected code identifier bypasses signature/team verification. [report](/tmp/audit2-camera-extension.md) | Focused fixed + reviewer closed — [focused camera12/0](/tmp/ultracam-audit2-camera-focused/green.log) inspected; root reports reviewer closure. No signed/live native qualification inferred. |
| R2-08 | P1 — Delayed sink callback dereferences retired unowned runtime. [report](/tmp/audit2-camera-extension.md) | Same camera-extension12 GREEN and reviewer closure as R2-07; [receipt](/tmp/ultracam-audit2-camera-focused/green.log). Delayed callback must hold safe runtime/queue ownership. |
| R2-09 | P2? — Mixed active/pending stop-before-start bookkeeping; native sequence unconfirmed. [report](/tmp/audit2-camera-extension.md) | WITHDRAWN as a confirmed bug — reviewer determined anonymous native stop callback does not identify the canceled pending client; proposed mixed sequence was unestablished. Retain claim history, not an open production defect or a required speculative fix. |
| R2-10 | P2 — Successful setters skip installed contract readback. [report](/tmp/audit2-camera-sink.md) | Focused fixed — successful setters require readback; superseding [strict mock GREEN7/0](/tmp/ultracam-camera-stop-identity-green.log) covers five negotiation and two stop cases. Independent reviewer now closed (root-confirmed); no live CMIO proof. |
| R2-11 | P1 — Failed stop drains a potentially live consumer queue. [report](/tmp/audit2-camera-sink.md) | Focused fixed + independent reviewer closed — original six mock pass superseded by same-stream identity regression: [RED7 tests/3 failures](/tmp/ultracam-camera-stop-identity-red.log) → [strict actual CameraSink/mock GREEN7/0](/tmp/ultracam-camera-stop-identity-green.log). Five negotiation plus two stop cases include sameID blocked despite capacity4 and identity freed only after successful stop. Files frozen; independent reviewer now closed (root-confirmed), no live native proof. |
| R2-12 | P1 — 8/16-channel paired PCM enters stereo-only adapter. [report](/tmp/audit2-capture-audio.md) | Focused fixed — [RED8 methods/44 assertions](/tmp/ultracam-audit2-paired-red.log) → [actual runtime73 methods/zero failures](/tmp/ultracam-audit2-capture-final-green.log), including new8/0. Harness expected-count71 was stale after Metadata6→8, so wrapper exited2/script1 despite runtime73/0; root accepts scoped runtime evidence, not a passing complete gate. Independent capture-audio reviewer closed; corrected app runtime1,292/0 now passed; CLI6/builds2 passed; Sony script-only reruns passed; strict UI1,427/0 now passed after fixing R2-I05/I06; monitor host24/0 and integration37/0 passed without skips; refreshed unsigned shipping2 passed. Forwarding proof does not establish writer silence/jump conversion. |
| R2-13 | P2 — Paired stereo depends on an undocumented 48000 timescale. [report](/tmp/audit2-capture-audio.md) | Focused fixed — [RED8 methods/44 assertions](/tmp/ultracam-audit2-paired-red.log) → [actual runtime73 methods/zero failures](/tmp/ultracam-audit2-capture-final-green.log), including new8/0. Harness expected-count71 was stale after Metadata6→8, so wrapper exited2/script1 despite runtime73/0; root accepts scoped runtime evidence, not a passing complete gate. Independent capture-audio reviewer closed; corrected app runtime1,292/0 now passed; CLI6/builds2 passed; Sony script-only reruns passed; strict UI1,427/0 now passed after fixing R2-I05/I06; monitor host24/0 and integration37/0 passed without skips; refreshed unsigned shipping2 passed. Forwarding proof does not establish writer silence/jump conversion. |
| R2-14 | P2 — Legacy typed paired PCM bypasses matching-frame validation. [report](/tmp/audit2-capture-audio.md) | Focused fixed — [RED8 methods/44 assertions](/tmp/ultracam-audit2-paired-red.log) → [actual runtime73 methods/zero failures](/tmp/ultracam-audit2-capture-final-green.log), including new8/0. Harness expected-count71 was stale after Metadata6→8, so wrapper exited2/script1 despite runtime73/0; root accepts scoped runtime evidence, not a passing complete gate. Independent capture-audio reviewer closed; corrected app runtime1,292/0 now passed; CLI6/builds2 passed; Sony script-only reruns passed; strict UI1,427/0 now passed after fixing R2-I05/I06; monitor host24/0 and integration37/0 passed without skips; refreshed unsigned shipping2 passed. Forwarding proof does not establish writer silence/jump conversion. |
| R2-15 | P2 — CPU video accepted without video declarations. [report](/tmp/audit2-capture-contract.md) | Focused fixed + original auditor closure recheck: CPU and audio declaration oracle checks corrected. Root confirms focused execution and independent reviewer closure; exact focused receipt not yet supplied here. No round1 receipts reused. |
| R2-16 | P2 — Initial/per-epoch audio declaration not enforced. [report](/tmp/audit2-capture-contract.md) | Same focused oracle execution and original reviewer closure as R2-15. |
| R2-17 | P2 — Signed host validation omits shared group/required entitlements. [report](/tmp/audit2-ci-security.md) | Focused fixed + independent recheck closed (root-reported). Six RED assertions then [Bundle mock GREEN21](/tmp/audit2-ci-green.log). Actual signed artifact qualification separate. |
| R2-18 | P2 — Universal dependency check mixes architecture run paths. [report](/tmp/audit2-ci-security.md) | Same Bundle21 and reviewer closure as R2-17; architecture-specific runpaths fixed, no actual universal artifact claim. |
| R2-19 | P2 — Confirmed authentication not saved after initial property-read failure. [report](/tmp/audit2-control-contract.md) | Focused fixed + original auditor recheck closed: [strict Swift6 mock GREEN18](/tmp/ultracam-control-audit2-green.log), [RED](/tmp/ultracam-control-audit2-red.log). |
| R2-20 | P2 — Reset exposes another camera’s stale properties to replacement. [report](/tmp/audit2-control-contract.md) | Same strict mock18 and original auditor closure as R2-19. |
| R2-21 | P2 — Source gamut selection replaces range/matrix/siting. [report](/tmp/audit2-cross-plan.md) | Focused fixed + independent reviewer closed — RGB-encoding merge preserves transport fields; [strict Swift6 helper5/5](/tmp/source-profile-checks/green.log) plus [all13 catalog projections](/tmp/source-profile-checks/catalog-green.log) manually checked (13 profiles, not13 tests). Added linked subfinding: manual Rec709/HLG/PQ monitor overrides must propagate primaries/encoding while preserving transport. Monitor host CPU3 GREEN now covers display profiles/Codable/matrix/range/siting, and the cross-plan source reviewer closed. Settings/runtime regressions are included in the corrected app1,292/0 pass; current UI and monitor/shipping qualifications retain the checkpoint boundaries above. |
| R2-21.M | Linked monitor subfinding — manual Rec709/HLG/PQ declarations must override monitor primaries/encoding while preserving transport range/matrix/siting; owner-discovered integration follow-up to R2-21, not an extra independent audit claim. | Monitor host [CPU3 GREEN](/tmp/monitor-audit2/green-cpu.log) covers display-profile Codable/transport behavior, alongside monitor GPU2. `MonitorSignalDeclaration.sourceProfileID` and three settings projection sites updated; cross-plan source reviewer closed; settings/runtime regressions are included in the corrected app1,292/0 pass. Parent and owners supplied this scope; UI-runner/package qualifications stay separate. |
| R2-22 | P2 — Program consumer handoff releases byte/time budget too early. [report](/tmp/audit2-cross-plan.md), [report](/tmp/audit2-program-timing.md) | Focused fixed/frozen + independent reviewer closed — [initial RED24](/tmp/program-cadence-cpu-red.log), [edge RED9](/tmp/program-cadence-cpu-edges-red.log) → [strict CPU final19/0](/tmp/program-cadence-cpu-final.log). Includes ±1000ppm/10min host grid, 1fps→60/120 schedules, queued/inflight byte-time charges, reset/topology fencing and expired/missed wakes. Seven ProcessedFrame cases included; no GPU/full app claimed. |
| R2-23 | P2 — New discovery observer lacks initial snapshot. [report](/tmp/audit2-decklink-native.md) | Focused fixed + Blackmagic reviewer closed (root-reported): [adapter36/0](/tmp/round2-swift-final.log) inspected plus native GREEN reported; native receipt requested; device/driver qualification separate. |
| R2-24 | P2 — Video connector selection leaves embedded audio connector unchanged. [report](/tmp/audit2-decklink-native.md) | Same Blackmagic36/native execution and reviewer closure as R2-23; embedded audio connector selection covered synthetically. |
| R2-25 | P2 — SDI audio channel negotiation reads HDMI-only capability. [report](/tmp/audit2-decklink-native.md) | Same Blackmagic36/native execution and reviewer closure as R2-23; SDI capability path covered synthetically. |
| R2-26 | P2 — Discovery registration retains its cancellation token. [report](/tmp/audit2-decklink-swift.md) | Same Blackmagic36/native execution and reviewer closure as R2-23; observation release cleanup covered. |
| R2-27 | P1 — Native log declaration breaks processing with LUT disabled. [report](/tmp/audit2-lut.md) | Focused fixed + independent closure review appended to [LUT report](/tmp/audit2-lut.md). [RED3/27 assertions](/tmp/b4-round2-red.log) → [GPU GREEN3](/tmp/b4-round2-green.log); [combined focused GPU61/0](/tmp/b4-round2-all-green.log) now passed (prior58+new3). Initial resource-only harness failure was corrected by supplying MKLUT/shader resources to the snapshot; unchanged binary then passed. Full app separate. |
| R2-28 | P2 — RGB decode ignores authoritative range. [report](/tmp/audit2-lut.md) | Same LUT RED27→GREEN3, combined GPU61/0 and reviewer closure as R2-27. Covers24 RGB range/format/size/LUT combinations; actual unsupported transforms still refused. |
| R2-29 | P3 — Supported camera profiles labeled unsupported. [report](/tmp/audit2-monitor-color.md) | Focused fixed — owner/root report UI2 GREEN with discovery supported-mode case R2-01. Root confirms independent reviewer closure; exact focused receipt not yet supplied here. No package full gate claim. |
| R2-30 | P1 — GPU-core rebuild loses drawable residency registrations. [report](/tmp/audit2-monitor-ui.md) | Focused fixed — [GPU RED2/7 assertions](/tmp/monitor-audit2/red-gpu.log) → [GPU GREEN2](/tmp/monitor-audit2/green-gpu.log), actual corrected monitor sources; residency reattachment/shared reference count covered. Independent reviewer closed (root-confirmed); full package separate. |
| R2-31 | P2 — Monitor geometry ignores declared pixel aspect. [report](/tmp/audit2-monitor-ui.md) | Focused fixed — [CPU RED1/3 assertions](/tmp/monitor-audit2/red-aspect.log) → [CPU GREEN3](/tmp/monitor-audit2/green-cpu.log), including aspect, manual display RGB transport and ARRI legend. Independent reviewer closed (root-confirmed); full app separate. |
| R2-32 | P2 — Legend omits frame layout and misstates ARRI thresholds. [report](/tmp/audit2-monitor-ui.md) | Same CPU3 GREEN as R2-31; ARRI legal-float layout/freeze legend covered. |
| R2-33 | P2 — Transient scope encode failure consumes held-frame update. [report](/tmp/audit2-monitor-ui.md) | Same GPU2 GREEN as R2-30; unchanged held-frame scope setup failure retries exactly once. |
| R2-34 | P1 — Direct Program normalization ignores authoritative range. [report](/tmp/audit2-program-pixels.md) | Focused fixed + original reviewer closed (root-reported): actualGPU RED14 across two methods → [GREEN4](/tmp/ultracam-b2-check/audit2-green-runtime.log), exact two plus prior two regressions. Full combined separate. |
| R2-35 | P2 — Odd source chroma stretched to allocation extent. [report](/tmp/audit2-program-pixels.md) | Same actual GPU RED14→GREEN4 and reviewer closure as R2-34. |
| R2-36 | P1 — Low-rate repeat burst overflows queue before consumer notification. [report](/tmp/audit2-program-timing.md) | Focused fixed/frozen + independent reviewer closed — [initial RED24](/tmp/program-cadence-cpu-red.log), [edge RED9](/tmp/program-cadence-cpu-edges-red.log) → [strict CPU final19/0](/tmp/program-cadence-cpu-final.log). Includes ±1000ppm/10min host grid, 1fps→60/120 schedules, queued/inflight byte-time charges, reset/topology fencing and expired/missed wakes. Seven ProcessedFrame cases included; no GPU/full app claimed. |
| R2-37 | P2 — Program-ahead positive clock drift never corrected. [report](/tmp/audit2-program-timing.md) | Focused fixed/frozen + independent reviewer closed — [initial RED24](/tmp/program-cadence-cpu-red.log), [edge RED9](/tmp/program-cadence-cpu-edges-red.log) → [strict CPU final19/0](/tmp/program-cadence-cpu-final.log). Includes ±1000ppm/10min host grid, 1fps→60/120 schedules, queued/inflight byte-time charges, reset/topology fencing and expired/missed wakes. Seven ProcessedFrame cases included; no GPU/full app claimed. |
| R2-38 | P2 — In-progress recovery erases retained original-root bookmark. [report](/tmp/audit2-recording-model.md) | Focused fixed + independent reviewer closed (root-confirmed); [/tmp/b9-round2-green.log](/tmp/b9-round2-green.log) confirms busy root and alias containment, without an XCTest total. Corrected model/full app runtime1,292/0 passed. |
| R2-39 | P2 — Valid selected root containing symlink is rejected. [report](/tmp/audit2-recording-model.md) | Same recovery-focused receipt as R2-38. |
| R2-40 | P1 — Native420v bypass ignores authoritative full range. [report](/tmp/audit2-recording-pixels.md) | Focused fixed + recording-pixels reviewer closed (root-confirmed). Final integration is in [recording-focused36/0](/tmp/recording-round2-green.log), including actual range-converted output contract checks. Broad app gate separate. |
| R2-41 | P2 — CFR compatibility loses generated timecode. [report](/tmp/audit2-recording-timing.md) | Focused runtime GREEN — actual `testConformedCFRPreservesSelectedGeneratedTimecodeAcrossPause` passes in [recording-focused36/0](/tmp/recording-round2-green.log). Independent timing reviewer closed (root-confirmed); generated CFR counterexample correction documented by the reviewer. Corrected broad app runtime1,292/0 now passed; composed receipt boundaries above apply. |
| R2-42 | P2 — Generated timecode subtracts on potentially rounded grid. [report](/tmp/audit2-recording-timing.md) | Focused runtime GREEN — actual `testGeneratedTimecodeUsesExactRationalOffsetsAcrossLargeScales` passes in [recording-focused36/0](/tmp/recording-round2-green.log). Independent timing reviewer closed (root-confirmed); generated CFR counterexample correction documented by the reviewer. Corrected broad app runtime1,292/0 now passed; composed receipt boundaries above apply. |
| R2-43 | P1 — Tail flush error skips healthy movie finalization. [report](/tmp/audit2-recording-writer.md) | Focused fixed/frozen — [RED36 tests/15 failures, one unexpected](/tmp/recording-round2-red.log) → [GREEN36/0](/tmp/recording-round2-green.log); [strict compile](/tmp/recording-round2-green2-compile.log). Tail/VTComplete errors finalize readable MOV and failed sidecar, reject further append. PCM refusal preserves three accepted encoded frames with droppedVideo0/encoderErrors0/audioDiscontinuity1. Focused B3/Packed/SourceAdmission only; independent writer reviewer closed (root-confirmed), full app separate. |
| R2-44 | P2 — PCM correction failure discards already admitted video. [report](/tmp/audit2-recording-writer.md) | Focused fixed/frozen — [RED36 tests/15 failures, one unexpected](/tmp/recording-round2-red.log) → [GREEN36/0](/tmp/recording-round2-green.log); [strict compile](/tmp/recording-round2-green2-compile.log). Tail/VTComplete errors finalize readable MOV and failed sidecar, reject further append. PCM refusal preserves three accepted encoded frames with droppedVideo0/encoderErrors0/audioDiscontinuity1. Focused B3/Packed/SourceAdmission only; independent writer reviewer closed (root-confirmed), full app separate. |
| R2-45 | P2 — Swift v3 events cannot deserialize in shared Rust model. [report](/tmp/audit2-rust-switching.md) | Focused fixed — root reports Swift3 + Rust22 GREEN for shared ledger/replay protocol and ACK. Root confirms independent reviewer closure; exact receipts not yet supplied here. Corrected app runtime1,292/0 passed; CLI6/builds2 passed; Sony script-only reruns passed; strict UI1,427/0 now passed after fixing R2-I05/I06; monitor host24/0 and integration37/0 passed without skips; refreshed unsigned shipping2 passed. |
| R2-46 | P2 — Persisted ACK differs from director’s live ACK clock/value. [report](/tmp/audit2-rust-switching.md) | Same Swift3/Rust22 GREEN reported as R2-45; live/persisted director ACK matches while landing timestamps remain metadata. |
| R2-47 | P2 — Gap diagnosis attributes another camera’s signal loss. [report](/tmp/audit2-rust-switching.md) | Focused fixed — [diagnostic10 GREEN](/tmp/audit2-test-gates-diagnostic.log), including cross-camera attribution; reviewer closed (root-confirmed). Full gate separate. |
| R2-48 | P1 — Native connect not bound to approved endpoint/auth mode. [report](/tmp/audit2-sony-plugin.md) | Focused fixed + independent reviewer closed — direct Sony/native/localization mock gate GREEN (root-reported). [held-vault integration19/0](/tmp/ultracam-control-held-vault-green.log) inspected; control owner confirms frozen/no production delta, and root confirms end-to-end closure with native guard + independent review. Corrected app1,292/0 and warning-free Sony runner reruns passed; physical device qualification remains separate. |
| R2-49 | P3 — Option keys omit Sony resource table. [report](/tmp/audit2-sony-plugin.md) | Focused fixed + reviewer closed (root-reported): direct option-table localization/native mock gate GREEN. Exact receipt requested; real SDK/device separate. |
| R2-50 | P1 — Three integration compilers omit Program source directory. [report](/tmp/audit2-test-gates.md) | Focused fixed — [final BuildContracts65 GREEN](/tmp/audit2-test-gates-buildcontracts-final.log), [CI7](/tmp/audit2-test-gates-ci.log) and [diagnostic10](/tmp/audit2-test-gates-diagnostic.log). Earlier64/1 receipt is historical and corrected. Integration compiler argument fixtures cover three runners, not actual UI builds. |
| R2-51 | P2 — Hardware gate accepts skipped required proofs. [report](/tmp/audit2-test-gates.md) | Focused fixed/frozen — optional11 exact identities and enabling flags classified; new five RED→[GREEN](/tmp/audit2-gpu-skips-optional11.log), owner closure confirmed. [BuildContracts65](/tmp/audit2-test-gates-buildcontracts-final.log), [CI7](/tmp/audit2-test-gates-ci.log), [diagnostics10](/tmp/audit2-test-gates-diagnostic.log) all GREEN. Unknown same-class GPU proof skip still rejects. Additional shader predicate semantics reproduced RED4 subcases then [GREEN6](/tmp/audit2-gpu-skips-shader-predicate-green.log), exact flag handling frozen; full app/package gate separate. |
| R2-52 | P2 — Valid VFR duration intervals classified as lost frames. [report](/tmp/audit2-test-gates.md) | Focused fixed — [diagnostic10 GREEN](/tmp/audit2-test-gates-diagnostic.log); handles valid VFR duration gaps without invented loss. Distinct cross-camera attribution R2-47 shares diagnostic suite. |

## Current verification boundaries

- Root reports latest BuildContracts68/0 (5.117s), git diff whitespace check clean, and Sony script-only target reruns all warning-free. Native+Swift actual minos26.0 verified.
- Root reports current actual CPU lint:57 classified/zero unresolved; vendor boundary lint passed and git diff whitespace check clean. These are narrow current-tree static gates, not runtime qualification.
- The first full run failed1,290/7 assertions across four cases; the corrected coherent strict app rerun passes1,292/0 with no app skips. Standalone vendor CLI6 and unsigned shipping builds2 passed; Sony script-only deployment-target reruns passed without warnings; strict UI1,427/0 passed; monitor host24/0 and integration37/0 passed without skips; refreshed unsigned shipping2 passed. Retained package/Rust/static receipts and retry app pass compose validation; no monolithic test.sh success is claimed. Round1 receipts remain snapshot-scoped.
- The old `/tmp/audit2-buildcontracts-green.log`64/1 result is historical; [replacement BuildContracts64](/tmp/audit2-test-gates-buildcontracts.log) passes. Superseding final BuildContracts65, CI7 and diagnostics10 all pass. Optional11 package-skip classification received five targeted red→green tests and owner closure under R2-51.
- Focused GREEN plus reviewer closure is now recorded for generic control/oracle, SDK/CI, Program pixels and Blackmagic. LUT3 GPU methods passed after27 RED assertions and received independent closure review. Monitor CPU3/GPU2 passed; full app/package integration remains separate.
- Original source findings, including meter-history race, have scoped fixes/reviewer closure. Strict UI exposed live-idle CPU and attachment-lifecycle issues R2-I05/I06, now fixed and reviewer-closed with actual strict1,427/0. Earlier app1,292 remains scoped before the two-file UI production delta; focused19 plus full UI supply current complementary evidence. Combined runtime found additional LUT capture-lease retention R2-I01, now focused-fixed3/0 and reviewer-closed. Program fixture focused2, the applied manual-transport fixture correction and required quiet GPU benchmark1 have separate successful receipts. The coherent app rerun now passed1,292/0; CLI6, initial unsigned shipping2 and script-only deployment-target reruns passed; strict UI1,427/0 now passed, monitor host24/0 and integration37/0 passed without skips; refreshed unsigned shipping2 passed.
- Actual capture paired-audio73/0 remains a scoped receipt: its stale expected-count71 caused nonzero wrapper status. The first combined gate checked complete registrations and produced the failure receipt above; corrected coherent app rerun now passed1,292/0; its complete app+vendor suite discovery passed.
- Shipping UI typecheck, CLI6 and unsigned builds2 passed; UI integration R2-I05/I06 is closed with actual1,427/0; monitor host24/0 and integration37/0 passed without skips; refreshed unsigned shipping2 passed; actual signed/hardware qualification remains separate; Sony script-only deployment-target reruns passed. No build or test is run by the ledger author, and no other agent’s live handle is polled here.

- The conditional native pending-stop claim was withdrawn; real CMIO stop/quiescence, physical FX3/SDI/Sony behavior, supported GPU-family coverage, proprietary SDK behavior and signed/release qualification remain outside the static audits. Previously documented no-external-drive build proof remains environment-blocked unless a new receipt establishes it.
- Original reports and `/tmp` receipts may expire; preserve finalized receipts with the final integration/release record. Update this ledger with exact run outcome and reviewer disposition rather than inferring closure from file existence.
