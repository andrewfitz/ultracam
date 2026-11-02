# Fresh blind audit — November 2, 2026

Used 30 fresh GPT-6.1 Sol reviewers, including two independent reviewers of the fixes. Their instructions excluded prior audit plans, findings and history. Reviewed current first-party UltraCam and all five MonitorKit products, our native adapters, Rust switcher, UI, tools and build code. SDK/library implementations were excluded.

**21 pre-existing issues repaired: 16 app/package bugs, 4 tooling bugs, 1 test-discovery bug.** Related symptoms with a shared cause are grouped; corrections to newly written tests are not counted.

## Fixes

| # | Location | Repair |
|---|---|---|
| 1 | `CaptureController.swift` | Queued epoch cleanup no longer erases the first new frame's clock baseline, which hid subsequent source-frame gaps. |
| 2 | `CameraProvider.swift` | Failed native removal retains the runtime owning unowned stream callbacks; registry retries can complete removal. |
| 3 | `VirtualCameraRegistryTransport.swift` | Generation exhaustion cannot produce a forbidden `UInt64.max` publication. |
| 4 | `RecordingOutputManager.swift` | Byte writes consume reservations as space is used, preventing premature disk-space failures from double counting. |
| 5 | `RecordingTimecode.swift` | Native SMPTE labels reject signed/non-ASCII numeric components instead of silently accepting malformed metadata. |
| 6 | `FeedRuntime.swift` | Delayed cut notifications reconcile demand from current route state, preventing demand from moving back to a disabled feed. |
| 7 | Blackmagic `DeckLinkBackend.mm` | Connector changes publish their refreshed mode catalog to observers instead of leaving cached capabilities stale. |
| 8 | `SonyControlPlugin.swift` | Authentication disconnects remain authentication/nonretryable failures instead of becoming retryable transport errors. |
| 9 | `MonitorSurface.swift` | No signal, Clean View and disabled tools cancel pending scopes and stale retry work. |
| 10 | `UIMenuBar.swift` | Open menu icons/tints refresh despite SF Symbol images having nil names. |
| 11 | `AutoSwitcherBridge.swift`, `AutoSwitcherTimelineRecorder.swift` | Manual logs follow accepted director state/time, cancel pending cuts, record the applied cut and update subsequent origins/generations. |
| 12 | MonitorKit `MKMonitor.msl` | Repeated shader composition compiles once, matching the existing documented contract. |
| 13 | `ScopeSettings.swift` | Native-resolution dimensions saturate before arithmetic that could overflow. |
| 14 | `LoudnessMeter.swift` | Invalid channel counts are rejected before allocating their layout. |
| 15 | MonitorKitUI `Scene.swift` | Region edge conversion handles the largest integer dimensions without trapping or breaking shared boundaries. |
| 16 | `DisplayDriver.swift`, `MonitorRenderer.swift` | Every owned picture/scope buffer is checked for failure; unchanged scenes retry focus/scope analysis as well as presentation. In-flight resources remain retained. |
| 17 | UIVerify `Support.swift` | PNG encode/write failures produce failure status rather than silent success. |
| 18 | `LivePerformanceVerify.swift` | Invalid/empty workload configuration fails instead of skipping every measurement or trapping. |
| 19 | UITour `click.swift`, `scroll.swift` | Invalid arity, nonfinite coordinates and unrepresentable scroll counts are rejected. |
| 20 | `ProgramCadenceCPU/Boundaries.swift` | Existing boundary stubs compile against the current settings, logger and sink APIs. |
| 21 | `LayoutTests.swift` | Five aperture/geometry tests moved out of a model extension into a discoverable XCTest class. |

## Verification

- Full app regression binary: **1,594 tests passed, zero failures or skips**. Existing discovery checker verified every registered suite's actual method count.
- All five MonitorKit bundles: **1,102 tests passed, including 11 skips**, zero failures. New recovery, geometry, shader-composition, scope and audio regressions executed.
- Fresh Debug and Release app/extension builds passed. App self-test: **39 passed**.
- Strict UI verification: **1,786 passed, zero pending, one inspector refresh-rate failure** during combined workloads; 293 images written. Isolated four-camera/live-meter rerun: **79 passed, zero failures**, without changing thresholds. The original failure remains in the logs.
- Existing native Blackmagic suites: **17 passed**. Sony plugin/lifecycle checks passed. Focused Rust suite: **27 passed**. Focused DeviceAPI, recording converters, control/settings, audio, layout and scope checks passed.
- BuildContracts: **74 passed**; BundleContracts: **27 passed**. Existing cadence CPU checks: **19 passed**. Tools' focused executable checks: **27 passed**, with baseline false-green reproductions.
- Fresh recovery smoke: all four ProRes/HEVC interruption cases passed, including audio/timecode track checks, original preservation and recovery idempotence.
- Swift concurrency/warnings-as-errors compilation, shell syntax and final whitespace checks passed. Execution copies used four compiler workers; repository test/UI runners were not modified for parallelism.

Evidence and exact logs: `/Volumes/8TB/cinesomatic-build/audits/blind-20261102/`. Principal logs: `app-tests.log`, `package-tests.log`, `release-build.log`, `app-self-test.log`, `ui-verify.log`, `quiet-ui-perf.log`, `recovery-smoke.log`, `discovery.log`, and per-reviewer focused results.

Local validation used Xcode 27.0 on arm64 macOS 27.0.1 with the app's macOS 26 deployment target. Actual native hardware faults, installed/signed-extension removal failure, other GPU families, UIKit runtime and macOS 26 runtime were not exercised. GPU error recovery tests inject command status rather than faulting the device. Unsupported-domain numerical suspicions were not converted into speculative changes.

The six initially dirty source/test/tool files remain byte-identical to the captured baseline. Generation synchronized membership for the existing `UIScopeOverlay.swift`; the commit uses the portable project library path. No SDK/dependency changes, new test framework or CI project. MonitorKit was subsequently committed as `704949f` at the user's request; the UltraCam commit records that submodule revision and the related pending recording/UI verification changes.
