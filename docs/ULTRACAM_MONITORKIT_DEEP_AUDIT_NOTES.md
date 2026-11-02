# UltraCam / MonitorKit bug audit — November 1, 2026

Source review and focused repairs used 28 GPT-6.1 Sol subagents, including an independent review of the combined fixes. Existing MonitorKit changes were preserved. No SDK or dependency implementation was audited, and no commits were made.

Count: **49 distinct pre-existing issues fixed: 38 in app/MonitorKit code, 9 in tools/scripts, and 2 in existing native test fixtures.** Related symptoms with one root cause are grouped. Corrections to mistakes introduced during the audit are excluded.

Baseline source copies, focused reproductions and command logs: `/Volumes/8TB/cinesomatic-build/audits/bugs-20261101/`.

Local validation used Xcode 27.0 on arm64 macOS 27.0.1, with the app's macOS 26 deployment target. Metal 4 paths were exercised; macOS 26 runtime compatibility was not independently tested.

## Source review checklist

- Reviewed: all first-party production files in `Sources/App`, `DeviceAPI`, `Shared`, `Program`, `Recording`, `CameraExtension`, and `CameraProvider`.
- Reviewed: our Blackmagic and Sony adapters, Rust switcher, all five MonitorKit products and their shaders, including platform-conditional code.
- Reviewed: our build/configuration/scripts and smoke/UI tools. Read associated tests and added focused regressions; this does not claim every existing test file received a separate exhaustive audit.
- Completed: available local builds and synthetic/runtime checks below. Physical devices, installed signed extension behavior, other GPU families and UIKit runtime cannot be inferred from those results.

## Repairs

| Area | Concrete defects repaired |
|---|---|
| Recording writer | Consumed FIFO samples remained retained outside memory accounting; resume could overtake pre-pause callback submissions; journal-warning flag raced across queues. |
| Recording metadata/recovery | Sidecar writes and snapshot updates raced; one undeletable recovery staging file hid recoverable takes elsewhere; malformed recovery-tool arguments caused traps. |
| Recording format/timecode | Full-range packed sources falsely advertised incompatible recording profiles; large rational timecode offsets lost precision or trapped during integer conversion. |
| Capture | Queued watchdog timeout could clear a recovered signal or its new source-clock baseline; timeout handling now claims driver state atomically. |
| Blackmagic adapter | Reused buffers retained stale host timestamps; format diagnostics incorrectly always claimed 10-bit YUV. Two native test-fixture lifetime/expectation defects were also repaired. |
| Sony adapter | ITU709 gamma with incompatible/missing gamut falsely suggested Rec.709; grouped camera-display writes could partially mutate the camera before rejecting a later choice. |
| Processing | Supported p010 video and bi-planar 422 were rejected by LUT admission; full-p010 metadata was interpreted as video range; ProgramNormalizer could release resources while stalled GPU work still used them. |
| Monitor integration | Older capture generations displaced newer frames; unfreeze-before-copy-feedback retained a capture frame indefinitely; frozen scope labels followed live rather than copied LUT state. |
| Extension/registry | Reserved persisted generations poisoned recovery/publication; stale extension queries overwrote newer system state; first publication lost a custom registry group. |
| App UI | Installer system state was omitted from presentation; changing a picker during an async lookup attributed its result to the wrong camera; restored grid layout collapsed a single camera; alert-preference changes failed to reevaluate problems; recent-take reads lacked folder security access. |
| Switcher | Coincident Rust boundaries depended on hash iteration; timeline resets overwrote initial generation; Swift ledgers omitted control inputs. Dormant Swift director cancellation/carry paths lost acknowledgment state and could remain latched. |
| Shared helpers | Rejected timeline samples consumed pause/epoch changes; resource admission accepted overflowing totals; odd-width P216 validation accepted undersized chroma stride. These helpers have dormant or already-protected production callers. |
| MonitorKit core/picture | Log decode could return nonfinite values despite its optional failure API; CV raw decode accepted geometry for a different buffer size. |
| MonitorKit false color | Unbanded grey used the picture stage's display transform instead of the measured stage's. Updated host/shader ABI together; GPU regression failed before and passed after. |
| MonitorKit audio/UI | VU reported next filter state instead of current output; meter source/kind changes reused previous ballistic/hold state. |
| Existing tools | Smoke compile recipes omitted dependencies; camera smoke called a removed cadence configuration API; app self-test swallowed nonzero exit status; partial UI performance runs shared full-result cache; UI tour used obsolete tabs; camera smoke leaked failed-start callback/queue state and ignored paired-run stop errors. Self-test reopening searched for an obsolete menu title. |

Focused checks established before/after failures for many fixes; others have precise source proofs and passing integrated regressions. A shader compile error introduced during the false-color repair was caught by combined tests and corrected; fresh focused ABI and false-color GPU tests then passed.

## Verification

- Passed: 17 native Blackmagic synthetic groups normally and with ASan/UBSan; Sony plugin/control/conformance/credential checks; 74 build-contract tests; focused Rust suite (27 tests); focused recording/timecode/registry/installer/routing/UI and MonitorKit checks. Exact per-area commands and results are in the external logs.
- Passed: fresh final Debug and Release app/extension builds and bundle validation; normal Debug/Release launches and graceful quit requests; app self-test 39 checks, zero failures.
- Passed: corrected false-color shader GPU regression and four ABI reflection tests, with no skips.
- Passed: all five MonitorKit test bundles, 1,087 tests including 12 skips. The broad run found an incorrect new UI-test expectation; after accounting for its existing initial hold, all 210 UI tests passed on a complete UI-bundle rerun. Other bundles passed in the broad run. Logs: `final-test.log`, its referenced package log, and `package-ui-final.log`. The wrapper itself stopped on that original UI-test failure; it is not reported as a successful end-to-end command.
- Passed: actual recovery/camera helper compile/link; synthetic Metal 4 camera monitor at both 29.97/59.94 fps, 180 pictures each with no failed encodes. Recovery passed four interrupted ProRes/HEVC cases with original preservation and idempotence; every recovered movie's video/audio decoded with ffmpeg without errors.
- Strict UI verification: 1,762 checks passed, zero pending, one timing failure (two-camera idle run-loop stall 74.1 ms against 50 ms) during concurrent compilation; 277 images rendered. The same two-camera/live-meter scenario was rerun without compilation: **79 checks passed, zero failures**. Original timing failure is retained, not hidden or fixed by changing a threshold. Logs: `ui-verify.log`, `quiet-ui-perf.log`.
- Main app regression run: **1,567 tests executed, no skips**. Two newly added tests had fixture errors (PCM zero timestamp used the wrong timescale; temporary-path aliases were compared literally). Corrected fixtures preserve the assertions. A fresh optimized, strict-concurrency, warnings-as-errors test build then passed **all 60 tests in both affected recording suites**. All other app tests passed in the broad run. Logs: `app-tests.log`, `final-fixture-compile.log`, `recording-final.log`.
- Existing test-discovery checker verified every registered app suite's actual method count; GPU skip checker reported no app skips. Log: `discovery.log`. No failing or skipped newly added regression was left unaccounted for.
- Final test compiles used four compiler workers. The temporary runner flag was removed; `scripts/test.sh` has no audit diff and passes shell syntax checking. Final source diffs pass whitespace checks in both repositories. No new test framework or CI project was added.

## Remaining limits/questions

- Signed installed-extension registry writes need runtime authorization investigation; source review cannot establish which clients macOS permits to write that CMIO property.
- Physical capture/control, signed sandbox folder access and actual client churn remain distinct from the synthetic checks.
- Other GPU/platform configurations, UIKit ancestor-hidden view behavior, and cross-engine scope residency with only one engine's residency set remain unverified configurations.
- Extreme finite HLG reference inputs can overflow. No supported normal-range failure was reproduced; the above-1 input-domain policy remains an API question, so no speculative headroom clamping was added.
- The CLI has no saved-ledger replay command. A suspected UUID mismatch in such a command was disproved as a current CLI defect; no replay infrastructure was added.

These limits prevent an unqualified all-clear. This note records actual fixes and available verification, not proof that the app contains no other bugs.
