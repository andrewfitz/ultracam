# MonitorKit fresh bug audit and repair plan

## Objective

Audit the current MonitorKit implementation as if no prior review exists, find real defects, repair them, and leave a reproducible, tested commit. The audit target is the complete MonitorKit delivery surface:

- `Packages/MonitorKit/Sources`, including Swift, Metal shader text, and all five products.
- `Packages/MonitorKit/Tests`, with new tests added for every confirmed defect.
- The app integration that owns MonitorKit behavior: `Sources/App/Monitor*.swift`, the MonitorKit host checks, `Tools/MonitorAppIntegration`, and build or validation scripts that package or exercise the monitor.

Existing audit logs, changelogs, progress notes, and prior claims are context only. They are not evidence that a behavior is correct. The current worktree is the baseline and must be captured before any repair starts.

The baseline capture is non-destructive: save the complete diff and untracked-file list, create a dedicated audit worktree from that snapshot, and leave the user's original worktree untouched. Do not reset, clean, or discard existing work. Every agent works from the same captured baseline in its own worktree; reports and artifacts live under a run-specific directory outside the source tree.

## Invariants to prove

Every finding is evaluated against the contract it can violate:

1. **Pixel and color correctness:** source, output, and monitor stages use the declared range, matrix, transfer, primaries, chroma siting, LUT, HDR, and EDR rules; CPU references, classic Metal, Metal 4, and UI output agree within documented tolerances.
2. **GPU command ownership:** MonitorKit only encodes into host-owned work, never commits or waits, and leaves unrelated attachments and depth or stencil state intact.
3. **Lifetime and residency:** textures, frames, buffers, pipelines, archives, argument tables, and LUT resources remain alive until the GPU is finished, including replaced, frozen, skipped, and out-of-order submissions.
4. **Threading:** public mutable state has a documented owner or synchronization; render, capture, scope, audio, and SwiftUI threads cannot race or deadlock; shutdown releases every worker and display link.
5. **Format and geometry coverage:** planar, packed, subsampled, bit-depth, aperture, pixel-aspect, flip, de-squeeze, crop, magnification, multisample, HDR, and attachment combinations either work or fail explicitly.
6. **Performance contract:** no per-frame CPU allocations or copies beyond the documented host handoff, no hidden queue or thread creation, bounded GPU work, and no pipeline compilation on the display tick after warm-up.
7. **Failure behavior:** invalid inputs, unavailable GPU features, pipeline failures, missing drawables, archive corruption, and device loss produce safe fallback behavior and actionable errors without partial state corruption.
8. **API and packaging:** public symbols, availability, Sendable annotations, resource bundles, shader entry points, release stripping, and documentation match the shipped products.

## Audit sequence

### 0. Baseline and evidence

- Snapshot the complete current worktree, including untracked files, before edits.
- Record toolchain, OS, GPU, package revision, build settings, and environment variables.
- Establish a clean audit branch from that snapshot. Verify that its status is clean before the first test and record the exact baseline commit or tree hash.
- Run a clean package build and the complete package test suite from a new build directory.
- Run the app host checks, integration executable, UI type-check, UI verification, and app self-test where hardware permits.
- Run once with Metal API and shader validation enabled and once with sanitizers or thread checking where supported.
- Store logs and test counts under a run-specific external artifact directory; do not use an old report as a baseline.
- Treat a passing existing test as a starting observation only; independently inspect the implementation and add a regression test when a contract is at risk.

### 1. Static and contract audit

- Inventory every public API, shader function, resource, test target, and app integration call site.
- Compile with Swift 6 warnings as errors and inspect concurrency diagnostics, unchecked Sendable types, force unwraps, forced casts, unsafe pointers, and error paths.
- Reflect every Metal argument buffer, struct stride, function constant, texture format, threadgroup size, barrier, and residency declaration against its Swift counterpart.
- Trace ownership of every frame, texture, buffer, pipeline, archive, and callback from creation through replacement and shutdown.
- Build a matrix of input signal × stage × output color × LUT × tool × target format and mark every unsupported combination.

### 2. Focused module audits

Each module audit must produce: a finding list with file and line, a minimal reproducer or proof, severity, a regression test, a fix, and verification evidence.

- **Core model and math:** signal interpretation, transfer functions, primaries, range scaling, HDR/SDR transforms, LUT parsing and sampling, state normalization, geometry and aperture math.
- **Picture path:** frame wrapping and texture cache, decode, per-stage readings, LUT order, focus masks, zebras, false color, clipping, guides, magnification, freeze, render and compute paths.
- **Metal 4 and classic Metal:** command encoding, argument tables, pipeline specialization, barriers, residency, completion watermarks, asynchronous compilation, archive load/save and device capability fallback.
- **Scopes:** waveform, vectorscope, histogram, accumulation cadence, bin precision, stage/LUT/color interpretation, fused versus split paths, resource retirement.
- **Audio:** packet handoff, ring overflow, channel layouts, sample rates, peak/RMS/VU/PPM/true-peak/loudness math, resets, discontinuities, and callback isolation.
- **UI and renderer:** display-link scheduling, scene membership, state handoff, surface tiling, layer color spaces and EDR headroom, SwiftUI bindings, accessibility, shutdown, and allocation behavior.
- **App integration:** feed discovery, capture and recording handoff, freeze ownership, scope scheduling, program output, diagnostics, persistence/migration, and real-device start/stop.
- **Build and release:** generated project inputs, package resources, archive/cache directories, release symbols, validation scripts, deployment targets, and stale or missing bundle content.

### 3. Dynamic and adversarial validation

- Add property and boundary tests for every math and normalization function.
- Add CPU/GPU golden tests for all supported layouts and stages, including random valid inputs and extreme values.
- Compare classic and Metal 4 output hashes or toleranced pixels for identical inputs.
- Stress three or more frames in flight while replacing feeds, LUTs, surfaces, scopes, and frozen frames; include out-of-order completion and missing drawables.
- Exercise concurrent state updates, shutdown during callbacks, device/queue failures, archive corruption, and repeated start/stop cycles.
- Run allocation and timing measurements in release-like conditions, with validation-layer runs excluded from performance conclusions.
- Run on every available GPU family and at least one real UltraStudio path when hardware is available.

### 4. Repair protocol

- Fix only confirmed defects or test gaps that demonstrate a contract violation.
- Keep each fix small and localized; preserve public behavior unless the contract requires a change.
- Add the narrow regression test first, then implement the fix, then run the relevant focused suite.
- Re-run the whole package and integration matrix after each repair group.
- Re-audit the final diff from four independent lenses: correctness, concurrency/lifetime, GPU/API compatibility, and test/release quality.

Integration is serialized. The primary agent cherry-picks only verified agent commits into the audit branch, resolves conflicts by preserving the smallest tested change, and runs the affected suite after each batch. A commit that cannot be reproduced from its report and test command is rejected and returned to its owner. The original worktree is updated only after the audit branch passes final verification.

## Parallel execution matrix

Twenty agents are used with model `gpt-6.1-sol`. The first pass is read-only except for per-agent reports and tests in isolated worktrees. The second pass assigns each confirmed finding to its reporting agent or a dedicated owner in an isolated worktree. No two agents edit the same file set concurrently.

Each slot receives the same fresh-audit brief, the baseline tree hash, its file ownership boundary, and a unique worktree and artifact directory. Agents must not read old audit reports to close a finding, must not amend another agent's commit, and must stop at a shared-file boundary rather than editing through it. The primary agent remains responsible for cross-module findings, cherry-pick order, and final verification.

1. Repository inventory and public-contract map.
2. Core colorimetry and transfer math.
3. Core signal/range/matrix/chroma interpretation.
4. Core LUT parser, sampling, and normalization.
5. Core geometry, layout, aperture, and state normalization.
6. Picture frame wrapping, texture cache, and decode.
7. Picture pass specialization, tool ordering, and output stages.
8. Metal shader correctness and Swift/Metal ABI reflection.
9. Classic Metal command encoding and resource lifetime.
10. Metal 4 command encoding, residency, barriers, and completion.
11. Pipeline archives, warm-up, async compilation, and failure recovery.
12. Scope math, bins, precision, and color interpretation.
13. Scope GPU accumulation, fusion, cadence, and retirement.
14. Audio packet handoff, ring behavior, and callback isolation.
15. Audio meter and loudness reference math and edge cases.
16. MonitorKitUI renderer, display links, layers, and EDR.
17. SwiftUI controls, state handoff, accessibility, and shutdown.
18. Ultracam app integration, feeds, surfaces, freeze, and diagnostics.
19. Build, packaging, generated project, release symbols, and integration gates.
20. Adversarial end-to-end reviewer: cross-module races, unsupported combinations, and reproducibility of all findings.

Each agent must report: `finding ID`, severity (`blocker`, `high`, `medium`, `low`), exact location, trigger, violated invariant, reproducer, proposed fix, test name, and verification command. Agents must commit only their isolated, verified fix with a descriptive message and must not rewrite unrelated code.

Reports must distinguish a confirmed defect from an untested suspicion. A finding is confirmed only when the reproducer fails on the captured baseline and passes after the fix, or when a static proof establishes an invariant violation and a focused test demonstrates the affected behavior. Duplicate findings are merged under one ID before repair assignment.

## Severity and merge gates

- **Blocker:** crash, memory or GPU safety issue, corrupted output, deadlock, data loss, or a broken supported integration. Must be fixed before merge.
- **High:** deterministic contract violation, incorrect color/math result, resource leak, or unsupported path that is advertised as supported. Must be fixed or explicitly removed from the public contract.
- **Medium:** intermittent correctness, lifecycle, performance, or UI defect with a reproducible trigger. Fix when the owner can add a focused regression test.
- **Low:** documentation, diagnostics, or hardening issue that does not change output or safety. Track separately unless the fix is risk-free.

The audit is complete only when every blocker and high finding has a merged fix and regression test, the full validation matrix passes, the final four-lens review finds no unassigned high-risk item, and the resulting commits are documented with test evidence and known hardware limitations.

## Final verification and commit

- Rebuild from a fresh checkout of the audit branch with no incremental artifacts.
- Run the full package, Metal validation, UI, host, integration, and app self-test gates.
- Repeat the highest-risk stress tests three times and record variance.
- Verify the release bundle, resources, symbols, and generated project.
- Review `git diff`, `git diff --check`, and the final commit graph; ensure no scratch files or stale reports are included.
- Commit the plan, fixes, tests, and verification metadata as a coherent audit result.
- Publish a final report listing every finding (fixed, rejected with evidence, or deferred with explicit risk), the exact commands and hardware used, and any remaining limitations that need a live device or future API decision.
