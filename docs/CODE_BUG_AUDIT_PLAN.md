# Ultracam code and vendor bug-audit plan

## Objective

Find, reproduce, classify, and either fix or explicitly disposition defects across the complete Ultracam delivery surface. The audit covers code owned by Ultracam, code imported or vendored from third parties, and the seams between them. It must examine the current committed revision and the current working-tree changes independently.

This is a bug audit, not only a test run. A passing test suite is evidence for the paths it exercises; it is not evidence that uncompiled targets, signed extension behavior, hardware paths, packaging, concurrency, failure handling, or vendor boundaries are correct. The audit runs against the live current branch and working tree; it does not freeze development or require a separate checkout.

## Audit boundary and ownership map

| Surface | Paths | Audit treatment |
|---|---|---|
| App and extension | `Sources/App`, `Sources/CameraExtension`, `Sources/Shared`, `Sources/Recording` | Full source review, build, unit/contract tests, race and failure testing, signed runtime checks |
| Native capture | `Sources/DeckLinkBackend` and `Sources/DeckLinkBackend/*.inc` | Full C++/Objective-C++ review, callback/lifetime/thread checks, device and format matrix, hardware smoke tests |
| GPU | `Sources/App/*.metal`, `Packages/MonitorKit/Sources/**/*.metal` | Shader compilation, bounds/format/math review, GPU validation, resource-pressure and device-loss tests |
| External package boundary | `Packages/MonitorKit/Sources`, `Packages/MonitorKit/Tests` | Treat the pinned git submodule as external code: audit its implementation and integration, record upstream provenance, and keep upstream/package findings separate from Ultracam integration findings |
| Rust tool | `Tools/auto-switcher` | `cargo test --locked`, clippy/audit checks, FFI/ABI and protocol review, fuzz/property tests, CLI failure tests |
| Tools and scripts | `Tools`, `scripts`, `scripts/*.py`, shell entry points | Shell/Python safety, stale-path and exit-status checks, clean-machine execution, packaging/signing tests |
| Project and release surface | `Ultracam.xcodeproj`, `Config`, entitlements, plists, generated project scripts | Build-graph completeness, target parity, signing, entitlements, hardened-runtime, release/debug differences |
| Vendored DeckLink SDK | `ThirdParty/DeckLinkSDK` | Do not rewrite vendor code. Record exact version/license, compare against upstream advisories, inspect wrappers and assumptions, test supported API usage and ownership rules |
| Vendored Sony SDK | `ThirdParty/SonyCameraRemoteSDK` | Record SDK version and binary hashes, inspect headers and dylib loading/signing, validate credentials/network/error boundaries, compare vendor release/security notices |
| Generated/build artifacts | `Packages/MonitorTools/.build`, `Tools/auto-switcher/target`, derived data | Exclude from product correctness unless they affect generation or packaging; verify they are not accidentally shipped or used as source of truth |
| Tests and fixtures | `Tests`, package tests, integration/smoke tools | Audit for false positives, missing registration, weak assertions, nondeterminism, and tests that do not compile the production path they claim to cover |

The ownership ledger must label every source asset as **ours**, **vendor**, **generated**, or **test/tooling**, with the responsible review method and evidence location. Embedded vendor binaries receive hash and provenance records even when their source is unavailable.

### Relationship to the MonitorKit plan

[`MONITORKIT_FRESH_BUG_AUDIT_PLAN.md`](MONITORKIT_FRESH_BUG_AUDIT_PLAN.md) is the specialized workstream for the `Packages/MonitorKit` submodule and its app integration. It supplies deeper GPU, color, scope, audio, renderer, and Metal-lifetime invariants than this general plan. Both plans use the same starting status metadata, evidence directory, finding IDs, and final verification gate. The repo-wide plan remains the source of truth for ownership, vendor disposition, release packaging, and cross-subsystem findings.

## Phase 0: establish a trustworthy baseline

1. Record commit, submodule/package revisions, toolchain/Xcode/macOS versions, host architecture, SDK versions, and connected hardware.
2. Record `git status`, the current diff, ignored build artifacts, generated-project inputs, and a timestamped environment manifest. Continue working on the current branch; do not reset, clean, stash, or discard existing changes.
3. Build a file inventory with language, target, ownership, generated status, binary status, and test coverage. Confirm that every Swift/Obj-C++/C++/Metal/Rust/Python/shell file is assigned.
4. Build the app and camera-extension targets from a clean derived-data directory. Separately build package products and the Rust tool.
5. Run the existing checks as witnesses, but record which production files each command actually compiles. At minimum inspect `scripts/test.sh`, UI verification, app self-test, monitor integration, recording smokes, camera smokes, and `cargo test --locked`.
6. Treat the current `docs/FULL_AUDIT.md` as historical evidence to re-check, not as a pass certificate. Explicitly carry forward its gaps: app/UI files omitted from the synthetic binary, signed extension/install behavior, hardware capture, live Sony control, and release packaging.

## Phase 1: static and structural bug sweep

Run tools appropriate to the language and review findings manually. The output is a finding ledger with file/line, trigger, impact, evidence, owner, and proposed regression test.

- Swift: compiler warnings as errors, strict concurrency diagnostics, API availability, force unwrap/try, actor isolation, Sendable violations, unchecked continuation/callback completion, notification and observer lifetime, persistence migrations, and error paths that discard failures.
- C++/Objective-C++: clang static analyzer, compiler warnings, ARC/CF ownership, COM-style `AddRef`/`Release`, CVPixelBuffer and IOSurface lifetime, callback reentrancy, queue affinity, lock ordering, integer/size conversion, and exception/`NSError` boundaries.
- Metal: compile every shader for the deployment target; inspect thread bounds, texture/plane formats, NaN/Inf and range handling, synchronization, resource lifetime, and device loss/recovery.
- Rust: `cargo fmt --check`, `cargo clippy --all-targets --all-features -- -D warnings`, `cargo test --locked`, dependency audit, unsafe/FFI review, CString ownership, protocol framing, time ordering, and panic/error propagation.
- Python/shell: shellcheck/strict-mode review, quoting and path traversal, temporary-file cleanup, symlink and bundle replacement safety, subprocess exit handling, credential exposure, and clean-environment reproducibility.
- Project/config: compare generated project to committed project, verify all source files and package products are in the intended targets, check Debug/Release divergence, entitlements, bundle identifiers, embedded dylibs, rpaths, architecture, and signing/notarization assumptions.

## Phase 2: bug classes and review lenses

Every module must be reviewed through each applicable lens, with a concrete negative test or documented reason it cannot be automated.

1. **Functional and contract correctness:** input formats, output formats, state transitions, settings migration, UI actions, camera routing, recording semantics, program switching, registry snapshots, and schema/version compatibility.
2. **Concurrency and reentrancy:** races, lost updates, deadlocks, queue inversion, callback-after-stop, duplicate start/stop, cancellation, actor isolation, and teardown while work is in flight.
3. **Memory and resource safety:** leaks, retain cycles, double release, use-after-free, buffer aliasing, pool exhaustion, GPU/IOSurface/Metal resource lifetime, file descriptors, sockets, security-scoped bookmarks, and temporary files.
4. **Time and media correctness:** PTS/DTS monotonicity, fractional frame rates, timecode, audio/video sync, clock jumps, backpressure, dropped-frame accounting, pause/resume, discontinuities, and long-running rollover.
5. **Error and recovery behavior:** partial initialization, unavailable devices, malformed media, disk-full, permission denial, lost network/camera, GPU timeout/device loss, interrupted recording, retry budgets, and stale error state.
6. **Security and privacy:** producer authorization, signing/team validation, entitlements, app-group isolation, keychain use, credential/log redaction, network trust, malformed registry input, unsafe file paths, dylib loading, code signing, and local inter-process attacks.
7. **Numerical and visual correctness:** color range/primaries, LUT edge cases, 8/10-bit conversion, chroma subsampling, HDR/EDR, false color/scopes, overflow/underflow, rounding, and shader precision.
8. **Performance and capacity:** frame deadlines, queue growth, CPU/GPU/memory budgets, thermal degradation, high camera counts, long recordings, disk throughput, and recovery under pressure.
9. **Compatibility and lifecycle:** supported macOS/Xcode/SDK versions, device/format combinations, app upgrade and uninstall, extension install/update, signed release versus local build, sleep/wake, display changes, and meeting-app client churn.
10. **Packaging and supply chain:** dependency drift, vulnerable/out-of-support vendor versions, binary provenance/hashes, license obligations, duplicate SDK versions, missing embedded libraries, rpath issues, and reproducibility.
11. **Observability and UX truthfulness:** diagnostics must describe actual state, counters must not double count, errors must be actionable, and UI labels/status must match behavior.
12. **Test quality:** uncompiled production paths, vacuous assertions, tests that assert the bug, missing boundary cases, flaky timing, fixture leakage, and false green results.

## Phase 3: dynamic test matrix

### Deterministic and property tests

- Run all existing Swift/package tests and add focused regressions for every confirmed finding.
- Add state-machine/property tests for camera demand, virtual-camera viewer leases, registry generations, switcher cuts, recording lifecycle, recovery, and settings migration.
- Use malformed, truncated, empty, oversized, unsupported, and out-of-order inputs for registry JSON, media samples, LUTs, audio packets, SDK responses, and Rust protocol events.
- Run repeated stress loops for start/stop, connect/disconnect, format renegotiation, camera add/remove, cut/rollback, pause/resume, and concurrent recording/preview/monitor changes.

### Sanitizers and race checks

- Run AddressSanitizer, UndefinedBehaviorSanitizer, ThreadSanitizer, and leak/resource checks on testable native paths where supported.
- Use Swift concurrency checking and race-focused tests for callback and actor boundaries.
- Exercise GPU validation, Metal API validation, and command-buffer timeout/device-removal paths.
- Run with aggressive queue delays, injected allocation failures, writer failures, dropped callbacks, and controlled clock jumps.

### Integration and real-runtime checks

- Build and run the complete app target, camera extension, package host, monitor integration, recording smoke tools, UI verification, and app self-test from clean artifacts.
- Validate signed local and release-like bundles: nested dylib signing, entitlements, system-extension install/update/remove, app-group agreement, keychain persistence, and launch after upgrade.
- Test with no hardware, one supported DeckLink input, unsupported/mismatched formats, signal loss/restore, multiple cameras, multiple meeting clients, display sleep/wake, and app quit/relaunch.
- With approved hardware, test DeckLink capture and Sony control separately from synthetic tests. Record driver/firmware/OS versions and keep hardware failures distinct from code failures.

## Third-party/vendor audit

For each vendor, create a separate report rather than folding vendor defects into first-party findings:

1. Identify exact release/version, source or binary provenance, license/notice, supported platform, and known end-of-life status.
2. Hash every committed dylib/static library and compare it with the vendor delivery record.
3. Check current vendor security advisories and CVEs, compatibility notes, and upgrade history. A vendor defect is recorded with the upstream identifier and an actionable mitigation or upgrade decision.
4. Audit only the integration contract in depth: ABI/layout assumptions, ownership, thread/callback rules, error mapping, format/range semantics, and loading/signing behavior.
5. Verify that no vendor source, binary, generated artifact, credential, or license file is accidentally modified, omitted from packaging, or used outside its license.
6. Fuzz or fault-inject the boundary where feasible; do not claim that a black-box vendor binary has been fully source-audited.

## Finding protocol

Each finding must contain:

- stable ID and severity (`P0` data loss/security/deadlock/outage, `P1` major incorrect behavior or recovery failure, `P2` bounded/intermittent defect, `P3` minor correctness/diagnostic/maintainability issue);
- exact path and line or symbol, ownership class, affected target, preconditions, minimal reproduction, and observed versus expected behavior;
- impact, exploitability or operational likelihood, evidence link/log, and whether the issue is in our code, vendor code, or the integration;
- fix owner, regression test, validation command, and residual risk.

Do not merge duplicate reports. Do not downgrade a finding because the current test suite is green. If a suspected defect is disproved, retain the refutation evidence and the missing-coverage note.

## Exit criteria

The audit is complete only when:

- every in-scope source and binary is present in the ownership/coverage ledger;
- app, extension, package, native, Metal, Rust, scripts, and release packaging have each been built from clean artifacts;
- every P0/P1 is fixed or has an explicit accepted-risk decision with owner and deadline;
- every confirmed fix has a focused regression test or a recorded hardware-only validation procedure;
- vendor versions, hashes, licenses, advisories, and integration assumptions are documented;
- sanitizer, stress, failure-injection, UI, integration, and hardware gates have recorded results and environment metadata;
- the final audit runs on the post-fix tree, including a clean checkout and the full working-tree diff review;
- known limitations are stated plainly, especially unsupported hardware/OS combinations and vendor black-box areas.

## Deliverables

1. `docs/CODE_BUG_AUDIT_PLAN.md` (this plan).
2. `docs/CODE_BUG_AUDIT_INVENTORY.md` with ownership, targets, dependencies, and coverage.
3. `docs/CODE_BUG_AUDIT_FINDINGS.md` with the shared finding ledger and dispositions, including links to the MonitorKit findings.
4. `docs/VENDOR_AUDIT.md` with versions, hashes, licenses, advisories, and integration results.
5. Reproducible logs/artifacts for each gate, plus focused regression tests and fixes.
6. A final report that states what was tested, what was not testable, and the remaining accepted risks.

