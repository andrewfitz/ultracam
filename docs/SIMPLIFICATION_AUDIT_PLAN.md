# Dead code, complexity, and efficiency audit

Date: 2026-11-03. Status: planned; no audit findings established yet.

## Objective

Find code and machinery Ultracam can delete, collapse, or stop executing while preserving supported behavior. Cover dead code, speculative generality, duplicated responsibilities, inefficient data flow, poor ownership boundaries, redundant state, and maintenance-heavy build/test infrastructure. The preferred recommendation is the smallest change that removes a demonstrated cost.

This is a simplification audit, distinct from the existing bug audits. A large file, protocol, defensive check, or fallback is a review lead, not proof of bad design. Splitting a large file without reducing coupling or reasoning cost is not a successful simplification. Do not replace existing machinery with a new framework merely to make it look cleaner.

The immediate deliverable is an evidence-backed report and ordered remediation backlog. Implementation follows separately; planning does not authorize deleting features, changing output quality, or relaxing correctness gates.

## Baseline and scope

- Record host commit, MonitorKit submodule revision, working-tree diffs and source hashes at execution time. Preserve all existing edits. The current tree contains uncommitted performance work in the host, MonitorKit, Rust director, and vendor adapters.
- Read `PERFORMANCE_OPTIMIZATION_20261102.md` and its referenced evidence before proposing overlapping work. Revalidate against current source; do not claim those changes as new findings.
- Cover first-party code in `Sources`, `Packages/MonitorKit`, `Vendors/*/Sources`, `Tools`, `scripts`, `Tests`, project generation, configuration, and CI. Keep MonitorKit library/API findings separate from host integration findings.
- Treat vendor SDK payloads as dependencies: inspect inclusion, duplication, and wrapper cost, without rewriting vendor internals. Exclude generated outputs and build caches from source-size rankings; inspect their packaging and retention separately.
- Use current source, manifests, generated target membership, and executable entry points to establish reachability. Existing plans and documentation may describe future or obsolete paths; neither proves current support.
- Store execution logs, profiles, and snapshots under a run-specific directory in `/Volumes/8TB/cinesomatic-build`, respecting `scripts/work_paths.py`. Keep the report and backlog in `docs`; do not create another persistent audit service or framework.

## Pass 1 — map what actually ships and runs

Produce a compact inventory of source ownership, target membership, entry points, supported configurations, and feature consumers. Trace representative routes from capture callback through processing, preview, Program, recording, and camera extension. Separately trace UI commands, persistence, camera control, and the Swift/Rust boundary.

Compare the generated project with its inputs, package products, vendor manifests, script source lists, and test registration. Identify code compiled only by tests, files absent from every target, duplicate implementations compiled into different targets, and debug/verification helpers included in shipping builds. Distinguish intentional shared compilation from avoidable binary duplication.

Record source/binary size and build/test duration as baselines, not quality scores. Identify the highest-change or most tightly coupled areas where useful history is available; prioritize those alongside runtime cost.

## Pass 2 — prove dead and unnecessary code

Search for unused declarations, unreachable branches, abandoned feature flags, unused settings, superseded implementations, unreferenced resources/shaders, obsolete scripts, stale migrations, redundant dependencies, and test-only production APIs.

For each deletion candidate:

1. Trace callers from real entry points, including callbacks, selectors, notifications, FFI, shader names loaded as strings, generated registrations, and persisted identifiers.
2. Check Debug/Release, SDK-present/absent, host/extension, package consumers, and supported platform paths. App non-use does not establish that a public MonitorKit API is dead.
3. Classify it as proven unreachable, conditionally used, compatibility-required, planned-only, or unresolved. Test-only reachability requires a product/API decision; it is not automatic deletion proof.
4. Propose the exact removal boundary, including now-unnecessary tests, configuration, resources, and documentation. Give the validation that would disprove the removal's safety.

Zero text references or a static-analysis warning alone is insufficient. Do not call a fallback dead merely because available hardware does not exercise it. Do not retire migrations without establishing which saved versions remain supported.

## Pass 3 — challenge design and abstraction cost

Review these areas in order. These are hypotheses to investigate, not findings.

| Area | Starting points | Questions and required evidence |
| --- | --- | --- |
| Capture ownership and lifecycle | `CaptureController.swift`, `FeedRuntime.swift`, `RouteDemandCoordinator.swift`, `ProcessedFrame.swift`, `CaptureServicesBridge.swift` | Are several objects tracking the same lifecycle/demand? Which queues, locks, epochs, leases, and adapters enforce distinct guarantees? Draw ownership and transitions before suggesting consolidation. |
| Recording | `AVAssetSourceRecordingWriter.swift`, `SourceRecording.swift`, `RecordingOutputManager.swift`, converters and clock bridges | Are format admission, time mapping, buffer conversion, and error handling repeated? Can a branch or wrapper be removed without changing pause/resume, A/V sync, recovery, or supported formats? |
| UI and state | `AppModel.swift`, `RecordingModel.swift`, `UIPresentation.swift`, `UILiveTelemetry.swift`, camera and inspector views | Which values are stored and synchronized despite being derivable? Are commands and subscriptions duplicated? Count propagation steps and invalidations for a single user action or telemetry update. |
| Monitor integration | `MonitorSurface.swift`, `MonitorCoordinator.swift`, `MonitorGPUContext.swift`, MonitorKit renderer/engine/pass/scopes | Does the host duplicate package rendering, scheduling, caching, or lifetime responsibilities? Separate necessary host adaptation from parallel implementations of the same policy. |
| Vendor and format architecture | `Sources/DeviceAPI`, vendor adapters, `SourceAdmission.swift`, format catalogs and GPU decoders | Which extensibility mechanisms have active consumers or concrete supported requirements? Are there redundant representations, registrations, policy layers, or future-only paths? Preserve real SDK isolation and extension boundaries. |
| GPU processing | `LUTProcessor.swift`, packed/planar/RGB GPU paths, MonitorKit shaders | Which implementations differ for a real format/API requirement? Which passes, intermediates, conversions, barriers, or caches can be removed? Require pixel and lifetime evidence. |
| Switching | `AutoSwitcherBridge.swift`, `NaturalTalkingHeadAutoSwitcher.swift`, `SwitcherCoordinator.swift`, `Tools/auto-switcher` | Are state, queues, acknowledgments, serialization, or scheduling duplicated across Swift/Rust? Distinguish the live app from supported standalone CLI/offline uses. |
| Build and verification | `generate_project.py`, vendor scripts, package build helper, `test.sh`, UI verification, source-text checks, CI | Are source lists and rules maintained multiple times? Do wrappers, retries, and caches cost more than they solve? Which checks verify behavior versus incidental spelling, and which build the same products repeatedly? |

For every abstraction, ask: what current consumer or invariant needs this boundary; what happens if it is inlined or removed; and does the replacement reduce state, branches, allocations, or maintenance sites? A single implementation may still justify a boundary for vendor isolation, testing, ownership, or API stability. Consolidation must demonstrate a net reduction rather than move the same complexity elsewhere.

## Pass 4 — measure wasted work

Profile release builds with matched source snapshots and settings. Start with idle and demand transitions, then active frame paths. Reuse existing performance fixtures and traces where they still apply.

| Scenario | Inspect |
| --- | --- |
| No capture; automatic mode waiting; capture with no consumers | Timers, wakeups, polling, telemetry publication, retained GPU/video allocations |
| Native bypass, processing enabled, preview hidden/occluded | Unused sample creation, copies/conversions, GPU submissions, display scheduling |
| Preview with tools off/on; scopes visible/hidden | Duplicate rendering and analysis, refresh cadence, CPU readback, resource churn |
| One and multiple feeds; Program-only and multiple consumers | Work sharing, per-consumer copies, queue depth, contention, buffer retention |
| Recording, pause/resume, stop/start | Encoder/converter setup, clock handling, audio allocations, teardown and recovery cost |
| Camera control, audio meters, automatic switching | Idle polling, burst coalescing, FFI/serialization, main-actor/UI update cost |

Use supported 4K 29.97/59.94 capture modes for hardware claims; label broader synthetic format checks explicitly. Measure CPU, GPU time/submissions, allocations and retained memory, copy counts, wakeups, latency distribution, and dropped frames as applicable. Separate compile time and unrelated system load from measurement windows. Use repeated matched trials and report variability; do not turn small noisy changes into speedup claims.

Every performance recommendation needs a measured cost, causal explanation, simpler alternative, and correctness checks. Preserve output precision, color, cadence, timestamps, queue bounds, and observable behavior. Any proposed quality/performance tradeoff must be explicit and separately decided.

## Pass 5 — audit the machinery around the code

- Inventory duplicate or obsolete test fixtures and helpers; identify assertions that freeze implementation details rather than protect behavior. Preserve distinct platform, boundary, and failure-path coverage.
- Trace each CI/check entry point to what it actually compiles and verifies. Flag duplicate compilation, unused helpers, missing test registration, and retry policies that obscure failures.
- Review generated files and checked-in artifacts for competing sources of truth. Prefer an existing canonical source over adding another manifest.
- Review dependency/product inclusion, resource packaging, stale experimental tools, and documentation that directs contributors to obsolete paths. Quantify size or maintenance cost where possible.
- Evaluate each proposed check removal against a concrete failure it currently catches. Replacing a lexical check with a compiler or behavioral guarantee is useful only when the same boundary is covered.

## Findings and prioritization

Each finding records: ID; category; exact file/symbol/line and source revision; current consumers; evidence and confidence; user/runtime or maintenance cost; smallest proposed change; expected reduction; compatibility risks; validation; and dependencies on other findings.

Use separate severity and confidence. Rank measured hot-path waste and safe deletions first, then duplicated state/policy and useful local simplifications. Put broad architectural changes last unless evidence shows a substantial payoff. Avoid arbitrary scores or line-count targets.

Assign one disposition: **delete**, **collapse**, **stop doing work**, **retain with rationale**, or **needs evidence/product decision**. Include justified retained complexity in the report so later reviews do not repeatedly propose the same unsafe deletion. Separate confirmed findings from hypotheses and defer unsupported claims.

## Validation for subsequent remediation

Use the smallest meaningful existing checks for each change, followed by shared integration checks once a coherent batch is ready. Inspect scripts before execution for hardware, installation, or environment side effects.

- Target/build changes: canonical generation and vendor boundary checks, `bash scripts/ci-vendor-checks.sh --contracts-only`, shipping typecheck, and applicable SDK-present/absent builds.
- Core/media changes: relevant checks from `scripts/test.sh`; do not assume that binary compiles the entire app.
- UI/monitor changes: shipping typecheck, strict UI verification, MonitorKit tests and applicable monitor host/integration checks.
- Rust/FFI changes: `cargo test --locked` in `Tools/auto-switcher` plus the Swift bridge/integration checks.
- Runtime changes: matched release measurements and focused output/timing/lifetime checks; include shutdown and no-consumer behavior.
- Extension, physical capture, signed packaging, or live Sony claims: run the corresponding qualified checks when available; otherwise explicitly retain those validation gaps.

Do not add tests that merely restate a reversible deletion. Add focused regressions where simplifying behavior exposes a real failure risk. Do not use passing unrelated tests to certify an unexercised route.

## Completion criteria

Deliver `SIMPLIFICATION_AUDIT_REPORT.md` containing a concise architecture/reachability map, coverage by area, confirmed findings with evidence, retained-complexity decisions, measurement results, and an ordered backlog of independently reviewable changes. Every scoped area must be reviewed or explicitly marked unreviewed with its limitation.

The audit is complete when each recommendation states what can be removed or simplified, why it is safe, what concrete cost it removes, and how it will be verified. It does not require rewriting the system or finding an issue in every area. Remediation completion is a separate status from audit completion.
