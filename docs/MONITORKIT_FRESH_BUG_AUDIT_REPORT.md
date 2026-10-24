# MonitorKit fresh bug audit report

This report records a new audit from baseline commit `7c7b886` (`chore: capture MonitorKit fresh audit baseline`). Existing audit reports and prior claims were not used as evidence. The reviewed execution plan is [MONITORKIT_FRESH_BUG_AUDIT_PLAN.md](MONITORKIT_FRESH_BUG_AUDIT_PLAN.md).

Twenty isolated `gpt-6.1-sol` agents covered the complete matrix in the plan: repository contracts, color and signal math, LUTs, geometry, frame/decode, picture passes, shader ABI, classic Metal, Metal 4, archives, scopes, audio, UI, SwiftUI, app integration, release packaging, and adversarial end-to-end review. Agents with no confirmed defect made no code change. Confirmed findings were required to include a reproducer, regression test, fix, and verification evidence.

## Confirmed findings fixed

| Area | Defect and repair | Commit |
| --- | --- | --- |
| Signal math | Finite native-log inputs could overflow to a non-finite normalized result. | `51d9e9d` |
| Geometry | Unsupported direct pixel aspects and out-of-contract de-squeeze values were accepted. | `6b4abd7` |
| Scope math | Packed SIMD aggregation counted unrelated lanes in the leader bin. | `2828847` |
| Pipeline archives | Files beyond retention were opened; failed async scope builds retained stale pending state. | `18a0a58` |
| Scope scheduling | Fused groups mixed incompatible accumulation intervals. | `aac7a04` |
| Audio handoff | A queued packet could be lost across a rapid meter-session change. | `ebf036f` |
| Feed lifecycle | Equal source sequence numbers were accepted as newer deliveries. | `5475c82`, `7e7008a` |
| Release project | Generated Xcode projects embedded checkout-specific SDK paths. | `54d0527` |
| Classic Metal | Encoder creation failure left cached scope state marked current. | `df1916c` |
| Picture tools | Program zebras were suppressed before unavailable log false-color fallback was resolved. | `dcf3325` |
| Focus analysis | Focus could analyze a stage that the picture pass would reject when its LUT was unavailable. | `3071136` |
| Validation archives | Metal shader validation cannot reload its instrumented archives; validated sessions now build without a cache, report the reason, and skip file-dependent archive tests. | `68c74bd` |

The archive validation behavior is covered by dedicated tests and documented in the package API and architecture documentation. The final cleanup commit `19737f4` removes a geometry test warning.

## Verification

- Fresh package test run: MonitorKitUI 151 tests, MonitorKit 289, scopes 158, core 168, and audio 79; 845 executed, 0 failures, 6 ordinary skips.
- Full Metal API plus shader validation run: every test target passed with 0 failures. Archive file tests are skipped only under `MTL_SHADER_VALIDATION`; the validated no-cache behavior tests pass.
- Release package build: `swift build --package-path Packages/MonitorKit --scratch-path /tmp/monitorkit-fresh-release-build -c release` passed.
- Package self-test: `bash scripts/monitor-kit-package.sh selftest` passed.
- Host checks: `bash scripts/monitor-feed-host-checks.sh` passed all 19 checks.
- App integration: `bash scripts/monitor-app-integration.sh` passed at 30, 60, and 240 Hz, including 4K v210 input and combined focus/zebra/guides paths.
- UI checks: `bash scripts/ui-typecheck.sh` and `FORCE=1 bash scripts/ui-verify.sh` passed (795 tests, 189 images).
- Final diff review: `git diff --check` passed; no scratch artifacts are tracked.

The app self-test could not launch its staged application because the host environment denied access to `/Volumes/8TB/cinesomatic-director-work/agent-work/ultracam/Ultracam.app` with `sandbox_extension_issue_file_to_process ... Operation not permitted`. This is an execution-environment limitation; the host, integration, package, UI, release, and validation gates passed independently. A live UltraStudio capture path was also unavailable in this run.

Final audit commits are the sequence from `51d9e9d` through `68c74bd` above, plus this report and the audit plan. The branch is ready for review with the stated hardware and sandbox limitations.
