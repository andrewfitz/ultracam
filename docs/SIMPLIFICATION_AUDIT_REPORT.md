# Simplification audit — 2026-11-03

Implementation and subsequent regression results: [SIMPLIFICATION_IMPLEMENTATION_20261103.md](SIMPLIFICATION_IMPLEMENTATION_20261103.md). The audit observations and source references below retain their original baseline.

## Result and evidence boundary

The best opportunities are dormant parallel implementations, redundant test infrastructure, and small recurring operations. The review does not justify a general rewrite or replacing the vendor/monitor architecture. Several apparently complicated mechanisms enforce real ownership, timing, and failure guarantees.

Six GPT-6.1 Sol agents reviewed distinct scopes: dead code; capture/vendor ownership; recording/GPU; UI/MonitorKit; switching; build/test machinery. The coordinating review checked representative source/caller evidence and consolidated findings. Dead-code and capture reviewers independently checked the unused feed fan-out; capture independently checked the Swift-director deletion boundary; UI/monitor independently checked the constant format set and GPU rollback proposals. These are source-backed findings, not completed remediation or measured performance gains.

Baseline: host `27eca32e7b08d86737779eb66eeae409cba6d389`; MonitorKit `508476639855296641bbf46c2fbe3b40037eea47`, both including existing working-tree changes. Status, binary diffs, file inventories, and SHA-256 source manifest are retained in `/Volumes/8TB/cinesomatic-build/simplification-audit-20261103`. Line references below describe that working source. Existing work in `PERFORMANCE_OPTIMIZATION_20261102.md` is not counted as a new finding.

No production code changed. No build, test suite, fresh profile, hardware test, or signed-package validation was executed. The completed work is the static review; the planned dynamic measurement pass remains outstanding. Missing runtime evidence is explicitly reflected in the dispositions below.

## Reachability and responsibility map

- Shipping capture delivers through `CaptureController` into `ProgramOutputRoute` using installed callbacks. `FeedSession` state remains active, but its separate publication/fan-out route is only exercised by tests.
- Real automatic source demand is reconciled by `AppModel.reconcileAutomaticFeed` using automatic policy, preview, camera clients, recording, manual stops, and switching. A second demand coordinator embedded in `FeedCoordinator` is not activated by shipping callers.
- Live natural switching runs through AppModel → Swift `AutoSwitcherBridge` → Rust director → Program frame application → acknowledgment. The separate Swift natural director's evaluation has only test callers; production still constructs and resets its dormant state. Fixed-interval switching remains live.
- Recording owns distinct format conversion, clock mapping, take-specific LUT rendering, and writer lifetimes. These are not interchangeable merely because their APIs resemble each other.
- Host monitor surfaces use MonitorKit primitives while owning app-specific display, freeze, source, and retirement behavior. Public package convenience renderers support other consumers and platforms.
- `scripts/test.sh` compiles all App Swift files except `UltracamApp.swift`, plus shared/media/vendor and test sources. Its broad coverage does not replace shipping configuration, extension installation, or hardware qualification.

## Recommended local cleanup

### S01 — Delete unused recording counters

**High confidence; low impact; delete.** `Sources/Recording/RecordingCompatibilityPolicy.swift:23–34` declares `RecordingConversionCounters`, but repository scans found no construction, parameter, property, decoding, or dynamic registration. This is an internal Swift value type, not a public package API.

Remove only the unused type: four counters, an uncalled mutation method, and Codable/Equatable/Sendable conformances. Keep `RecordingCompatibilityPolicy`, its persisted setting, and live recording statistics. No runtime saving is claimed for an uninstantiated type. Validate with shipping typecheck and existing recording-policy checks; no new test is needed.

### S02 — Delete fictitious recording-cache policy knobs

**High confidence; low impact; delete.** `Sources/Recording/RecordingPixelConverter.swift:58–61` describes count-based eviction and declares unused `idleConversions` and `maxCachedTextures`. Actual eviction at `:388–399` uses elapsed age, completion state, and byte pressure. Its `sequence` argument is also unused; callers are at `:69,303,375,410`.

Remove the stale constants/comment and unused argument. Preserve actual converter sequence and each entry's `lastUsed`: they protect pending GPU work. Compile and run existing recording-cache budget checks. This removes misleading policy, not measurable processing cost.

### S03 — Remove unused FeedSession generation and failure state

**High confidence; low impact; delete.** `Sources/Shared/FeedRuntime.swift:25,52,61,66–69` writes a generation no caller reads. `FeedSession.fail` has no callers, and its `.failed` state is only assigned there.

Remove those members and update the misleading related comment in `Sources/App/CaptureController.swift:413–415`. Keep FeedSession running/idle/unavailable state. Keep CaptureController's separate, actively checked generation. Validate shipping typecheck and capture/feed lifecycle checks.

### S04 — Stop rebuilding constant format membership per frame

**High confidence in redundant operation; unmeasured runtime impact; stop doing work.** `Sources/App/LUTProcessor.swift:642–648` constructs a Set and union inside input validation. Its members do not depend on the frame. Submission and synchronous processing call this validation.

Use a private static immutable set with exactly the same members. Do not unify it with the different recording LUT admission list merely to eliminate similar text. This removes recurring set construction/hashing; actual optimized allocation counts and CPU savings need measurement. Validate unsupported formats and existing LUT pixel/color/ownership and recording burn-in checks.

### S05 — Stop constructing whole live sessions for camera snapshots

**High confidence in redundant data flow; unmeasured runtime impact; stop doing work.** `Sources/App/UILiveTelemetry.swift:201–210` builds `liveSession` then extracts one camera. The session path at `:157–168` refreshes drives, mutates a copied camera array, updates the shot clock, and traverses all cameras' signal-loss ages. Drive lookup at `:54–60` reads the drive revision and collects folders even before consulting its cache.

Capture-only consumers include `UICameraColumn.swift:280–283` and `UIInspector.swift:148–158`. They need none of the recording-drive or shot work. Existing `UILiveSource.camera` at `:116–134` can update one snapshot.

Update the selected snapshot directly; obtain drives only for take/all consumers and maintain the selected camera's loss age. Preserve nil-live fixtures and missing-camera behavior. Do not remove session/presentation APIs: status and other views use them. Validate capture/take/all paths, signal-loss age, time-left display, shipping typecheck and strict UI checks. The existing performance pass removed presentation derivation; this finding concerns the remaining session construction.

**Behavioral prerequisite identified during report review:** `UISessionBridge.cachedDrives` at `:351–362` updates `UIDriveLevels.shared` on cache misses. The removed lookup is therefore also a possible trigger for low/full drive alerts. Other snapshot/take/drive paths call it, but their availability and timing must be verified when the sidebar or recording views are hidden. Establish the alert refresh owner before removing capture-only lookups. Test low/full transitions in those states. The proven recurring cost is revision/folder/cache lookup; physical drive reads are cached for two seconds, not performed on every capture update. This makes S05 a behavior-sensitive optimization, not a guaranteed pure data-flow deletion.

### S06 — Represent one pending automatic decision as one value

**High confidence; maintenance improvement; collapse.** `Sources/App/AppModel.swift:421–422` stores decision ID and target as separate optionals, assigned together at `:1185–1186` and cleared together at six sites (`:598,1041,1082,1204,1221,1477`). Partial states are representable despite having no intended meaning.

Use one optional value containing ID and target. Preserve the host correlation: Rust proposal state and Program frame eligibility are different responsibilities. Validate applied/rejected/expired cuts, manual supersession, rebasing, stop/start, and feed removal. No CPU benefit is claimed.

## Remove dormant parallel machinery

### S07 — Remove the dormant capture-demand mirror

**High confidence in reachability; medium change risk; delete after confirming no intended internal reference API.** `Sources/Shared/FeedRuntime.swift:109–110,140` owns another demand coordinator. `setProgramConsumer` at `:543`, `setDedicatedCameraConsumer` at `:553`, and `activeDemandFeedIDs` at `:574` have test consumers but no shipping callers. Event/topology updates and removal guards maintain that inactive model.

The real policy is `Sources/App/AppModel.swift:1692–1740`. It differs from `RouteDemandCoordinator`'s preview-never-starts rule, so wiring the dormant policy into production would change behavior rather than simplify it. The mirror is unpopulated by shipping consumers, not entirely unexecuted: production `FeedCoordinator.remove` reads its snapshot at `FeedRuntime.swift:389–390`. Removing that guard is justified only by confirming that shipping code cannot acquire dedicated/manual demand in this mirror; retain the separate running-session and capture-pool removal checks.

Remove the FeedCoordinator integration, then the standalone policy and its test suite if it has no intentionally retained role. Preserve real automatic-demand, recording, preview, manual-stop, and topology tests. Remove only tests protecting retired behavior. Validate target membership and those live policies. Benefit: one less apparent source of lifecycle truth; no measured speedup.

### S08 — Remove unused per-session frame routing

**High confidence; medium change risk; delete.** `Sources/Shared/FeedRuntime.swift:26,30–34` creates a fan-out for each accessed session. Session `publish/addRoute` at `:72–81` and coordinator wrappers at `:461–471` are exercised only by the FeedRuntime routing test. Shipping delivery at `:271–285` installs direct callbacks to ProgramOutputRoute.

Remove session fan-out ownership/injection, publication helpers, and that test-only scenario. Keep session state and live callback generation/acceptance fences. **Keep the generic `FrameFanOut` implementation:** ProgramOutputRoute actively uses it. Validate capture lifecycle and Program route tests. Benefit: eliminate an unused instance per session and a misleading second delivery path. Independently corroborated by two reviewers.

### S09 — Retire the test-only Swift natural director if it is not an intentional oracle

**High confidence in reachability; explicit role decision needed; conditional delete.** `Sources/Shared/NaturalTalkingHeadAutoSwitcher.swift:80–474` implements a second director. `SwitcherCoordinator.swift:113–114,136` stores/constructs it; director evaluation at `:366–415` is test-only, explicitly labeled at `:406`. Live natural switching uses AppModel and the Rust bridge.

No documented differential/reference-oracle role was found; the historical audit notes call this a dormant Swift director, and its tests exercise it independently of Rust. Confirm its intended role, then remove director-specific state, evaluation, resets, decision-based acknowledgment overloads (`SwitcherCoordinator.swift:436–463`), and tests. Preserve the generic feed-ID acknowledgment overloads at `:470–496`, removing only their director-specific reconciliation at `:487–490`. Preserve/move `TalkingHeadDirectorMode` at `NaturalTalkingHeadAutoSwitcher.swift:35`: persisted settings use it. Preserve fixed-interval policy, automatic request latch, generic Program scheduling, health/readiness, timeline carry and abandoned-cut handling. Preserve the actual AppModel → Rust acknowledgment after frame application.

Validate settings decoding, coordinator/Program routing, AppModel automatic switching, bridge integration, and `cargo test --locked`. Benefit is reducing two independently maintained natural-direction implementations to one, not a proven runtime gain. Capture review independently confirmed this narrow boundary.

### S10 — Collapse the test-only direct claim API

**High confidence in reachability; optional lower-priority simplification.** `Sources/DeviceAPI/CaptureDeviceClaims.swift:6–11,20–26,35–42` supports owner-wide nil-token claims/releases; callers use this directly only in registry tests. Shipping `makeSession` uses UUID-scoped `ClaimedCaptureSession`.

Test through claimed sessions, remove the direct owner API, and use `Set<UUID>` instead of optional tokens if no intended direct API remains. Preserve locks, exclusive/shareable semantics, wrapper ownership, and SDK stop barrier. Validate same-owner distinct sessions, start failure, repeated stop, retained session lifetime, and device exclusivity. This simplifies claim semantics without inlining the vendor abstraction.

## Build and test machinery

### S11 — Remove duplicate aggregate MonitorFeedHost execution, subject to membership comparison

**High confidence in duplicate suite; medium-high confidence in removal boundary.** `scripts/ci-vendor-checks.sh:20–24` runs `test.sh` and later the standalone host checks. `scripts/test.sh:90` compiles `MonitorFeedHostChecks.swift`; `Tests/main.swift:231` registers the same class as `Tests/MonitorKitHost/main.swift:6`. The standalone script acknowledges the overlap.

Propose removing the standalone invocation from the aggregate, retaining it for focused developer runs. Follow-up inspection resolved the vendor distinction: `vendor-build.sh:12–25` uses the fourth argument only for Swift membership. Both commands use test native sources/defines/link flags; main additionally compiles five Blackmagic Swift test files. Sony Swift membership is identical. This is not a separate shipping-native gate. Main also enables `CAPTURE_LIFECYCLE_TESTS`; standalone does not. The production difference is the optional one-shot sample-creation test hook in `VideoContract.swift:103–119`, not a second capture implementation. Confirm equivalent MonitorFeedHost behavior and retain hook-free shipping compilation elsewhere before dropping the aggregate invocation. This can avoid an additional whole-host compile, native/Rust/package build invocations, and repeated suite; elapsed savings were not measured. Validate suite counts, skips, and both configurations.

### S12 — Consolidate runtime coverage verification

**High confidence in duplication; medium change risk.** `scripts/test.sh:105` runs the historical `NEW_SUITES` subset from `scripts/check-test-coverage.py:8–19,39–45`, immediately before full discovery/registration/count verification at `test.sh:107–165`, using the same verification helper.

Move complete discovery into the script entry point and remove the obsolete subset/invocation. Preserve parser helpers and explicit source-membership guarantees: the historical list might catch an omitted file the discovery glob misses. Validate missing suites/files, duplicate registration, extension methods, counts, failures, and skips using existing BuildContracts fixtures. Benefit: one inventory and coverage policy instead of two.

### S13 — Test the actual declaration instead of extracting its source

**High confidence; medium integration risk; collapse.** `scripts/test-source-declarations.py:9–19` finds a method by spelling, balances raw braces, and copies it into a generated `UIMonitorBridge`. It compiles a separate executable at `:25–33`. The two tests are conditionally excluded from the broad app test binary even though that binary now compiles `UISupport.swift`.

Register those tests in the normal executable against the actual declaration; remove the extraction script, invocation, and discovery exception. Confirm accessibility/actor isolation and preserve both supported/unmatched profile cases. Benefit: delete a custom parser, synthetic declaration, compiler setup, and separate count gate. Tradeoff: these two tests will then depend on the full app test build, losing their independent lightweight execution path; do not claim faster focused feedback without measuring it. Do not generalize this into building a better Swift parser.

### S14 — Clarify historical maps rather than rewrite their evidence

**Confirmed historical/current differences; low-priority documentation suggestion, not a product defect.** `docs/IMPLEMENTATION_MAP.md:314` says tests omit AppModel/views, unlike current `scripts/test.sh:68–85`. However, its opening explicitly dates the read-only survey to 2026-10-21. `docs/MONITORKIT_INTEGRATION_MAP.md:567` references old `monitor-tools-package.sh`; it is also a dated transition survey with historical notes. Current helper is `monitor-kit-package.sh`.

Do not rewrite the original survey claims as though they were current documentation errors. If current navigation presents these maps as operational instructions, add a brief historical-status notice and link to current build/test guidance. No evidence was established that someone is currently following the obsolete commands. No runtime benefit.

## Evidence-backed work that needs measurement or deeper failure analysis

| Candidate | Established evidence | Next step and constraint |
| --- | --- | --- |
| Whole-cache rollback snapshots | `RecordingPixelConverter.swift:281` and `ProgramNormalizer.swift:300` traverse/copy texture metadata under lock every submission, only for failure rollback. Recording then touches three texture views. | Profile realistic cache sizes. Consider a small per-submission record of touched entries. Preserve old metadata, insertion rollback, repeated touches, eviction and unsignaled-sequence recovery. Require injected partial failures and cache-budget/lifetime tests; do not simply remove rollback. |
| PCM intermediate copies | `ClockMappedPCMBridge.swift:61–64` copies retained input planes to Data before synchronous decode; output also crosses Float/Data/CMBlockBuffer storage. | Measure before introducing borrowing APIs. Preserve buffer lifetime, alignment/layout validation, preflight, clock state and exact output/timing fixtures. At 16 channels/48 kHz/Float32, input payload alone is 3,072,000 bytes/s per recording; this is arithmetic, not measured bandwidth cost. |
| Two audio JSON FFI cycles | `AutoSwitcherBridge.swift:222–258` sends audio then tick. Rust `director.rs:123–125` always returns no outputs for audio. | Benchmark a combined host operation preserving audio-then-tick order. Keep CLI JSONL/offline semantics. The prior optimization of empty-result decoding is already done. Another ABI surface may cost more than it saves. |
| Planar converter setup | `PlanarRecordingConverter.swift:94–144` creates command/residency/table/parameter resources per conversion. | Profile before adding a reusable ring: new reuse state could increase complexity. |
| Monitor diagnostics fan-out | `MonitorCoordinator.swift:76–79,97–128` refreshes once/second and globally publishes changed diagnostics; subscribers at `UILiveTelemetry.swift:349–359` invalidate. | Measure subscriber/offscreen behavior. LUT errors and stale-state transitions are real consumers, so do not stop scheduling solely because pictures/scopes are hidden. |

The rollback cross-review established an important constraint: provisional sequence tagging prevents pressure eviction of textures selected for the pending encode. Do not defer all tagging until commit. A local rollback record must capture a key's original state only once, distinguish new entries, restore both metadata fields, and avoid resurrecting evicted entries or modifying replacement entries. No shared transaction framework is required.

## Complexity that should remain

- Capture, delivery, control, and watchdog queues enforce different timing and blocking guarantees. SDK stop barriers do not alone cancel pending GPU completions; generations and ordered ingestion remain necessary.
- GPU slot counts, byte budgets, retirement, and failure rollback protect pending work. RGB IOSurface staging cannot be replaced by unchecked no-copy buffer aliasing across VM/storage bounds.
- Clock mapping, paired clocks, drift handling, take-specific LUT rendering and explicit conversion authorization have different semantics. One generic converter or shared preview buffer is not an established simplification.
- Rust proposal acknowledgment, host correlation and Program target-frame eligibility are distinct. Target video PTS cannot substitute for the director's audio clock.
- MonitorKit public products/platforms and host-driven surfaces are supported APIs, not dead merely because this app chooses lower-level primitives. Host/package renderer consolidation lacks equivalence evidence.
- Slow-state versus telemetry revision separation narrows UI invalidation; those revisions are not duplicate statistics storage.
- Package cache locks and per-run product snapshots preserve exact linked inputs during concurrent builds. Narrow timing retries, boundary lint and licensed/signed/hardware lanes have distinct guarantees.
- `UISelfTestRunner` is reached by `NSClassFromString`; verification fakes are conditionally compiled. Scanned host/MonitorKit shader entry points have Swift references. No shader/resource deletion was proven.

## Ordered remediation batches

1. **Small deletions and misleading policy:** S01–S03. Compile and focused existing checks. S14 is optional historical-document navigation, not a remediation prerequisite.
2. **Dormant feed machinery:** S07–S08. Confirm internal role, remove only retired tests, verify actual lifecycle/demand/Program behavior.
3. **Local recurring work/state:** S04–S06. Preserve UI observations and output behavior; measure relevant paths where claiming performance benefit.
4. **Verification simplification:** S11–S13 after configuration/membership parity checks. Prove retained coverage before removing old gates.
5. **Role-dependent cleanup:** S09–S10. Preserve settings and real switching/claim semantics.
6. **Profile remaining leads:** prioritize whole-cache snapshots, PCM copies and FFI only if measurements justify implementation complexity.

Changes should be independently reviewable; no bulk architectural rewrite. `scripts/check-canonical-generation.py:14–21` regenerates tracked files before comparing, so use an isolated source copy for that check during remediation instead of silently modifying the dirty audit workspace.

## Report review corrections

A subsequent source review retained the core findings but corrected the following: S05 now requires preserving low-space alert refresh side effects; S07 distinguishes an unpopulated demand model from unexecuted code; S09 distinguishes test-only evaluation from production construction/reset and explicitly preserves generic acknowledgments; S11 resolves vendor membership differences; S13 records the loss of lightweight standalone testing; S14 is historical-document navigation rather than a current-code defect. S06's paired-clear count was corrected from seven to six. These 14 numbered entries are not 14 confirmed bugs: they include maintenance improvements, conditional deletions, configuration-dependent consolidation, and one optional documentation suggestion.

S11's remaining conditional compilation difference also includes Blackmagic fixture methods at `Vendors/Blackmagic/Sources/DeckLinkCapturePlugin.swift:116`, in addition to the optional sample-creation hook. S13's real `UIMonitorBridge` is `@MainActor` (`UISupport.swift:195`), unlike the extracted substitute; preserve this isolation when migrating tests rather than weakening production annotations.

## Coverage and unresolved work

| Scope | Completed | Unresolved |
| --- | --- | --- |
| Dead code/resources | Symbol/consumer searches; target and dynamic-entry spot checks | Complete compiler/member liveness, linker stripping, dependency/binary size, external tool/package users |
| Capture/vendors | Demand, fan-out, lifecycle ownership, claims, bridge/adapters | Exhaustive native Sony/Blackmagic internals, live hardware/failure timing |
| Recording/GPU | Conversion paths, cache rollback, PCM and LUT boundaries | Full recovery/timecode/writer race review, fresh GPU/pixel and encoder validation |
| UI/MonitorKit | Snapshot data flow, observation, host/package responsibility | Fresh UI profiles, offscreen scheduling, downstream API compatibility |
| Switching | Swift/Rust call paths, state/acknowledgment and FFI | Matched FFI measurements, external Rust consumers, live session |
| Build/tests/docs | Major gates, registration, retries, extraction helpers, stale maps | Build-duration baseline, full documentation inventory, signed/licensed lanes |

Additional verification weaknesses: some source-extraction helpers count braces without parsing strings/comments; the settings-intent discovery test embeds a literal loop, so it cannot establish that the current production loop behaves the same. Replace such checks only when equivalent compiled-production coverage exists. Default PR/push CI does not execute all app/Rust/package behavioral suites; broader hardware coverage is manually dispatched. These are coverage limitations, not observed test failures.

The next implementation work should start with the small confirmed deletions and dormant feed machinery. Runtime speedup claims and broader redesigns remain unsupported until the outstanding measurements and validations are performed.
