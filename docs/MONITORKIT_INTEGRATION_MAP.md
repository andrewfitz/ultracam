# MonitorKit integration map

Date: 2026-10-21. This is a read-only survey. It changes no app code. It covers two replacements: the app's GPU LUT application, and the whole `Packages/MonitorTools` package. Both move to `Packages/MonitorKit`.

Related: [Monitor library plan](MONITOR_LIBRARY_PLAN.md), [GPU pipeline plan](GPU_PIPELINE_PLAN.md), [MonitorKit architecture](../Packages/MonitorKit/Docs/ARCHITECTURE.md), [MonitorKit progress](../Packages/MonitorKit/PROGRESS.md).

## 0. Baseline and status (read first)

**Line numbers are against HEAD `7a09c71` unless marked "WT" (working tree).** They will drift.
- `PROGRESS.md` gates W4 (this integration) on session "ultracam-18" committing its app work first: the GPU monitor in MonitorTools, the pipelined `LUTProcessor`, Program, Recording and SDK 16.
- **That work started landing in the working tree while this map was being written (about 23:30).** It is uncommitted.
- **Sources:** 14 files, +3358/−890.
  - `LUTProcessor.swift` and `LUTShaders.metal` are rewritten on **Metal 4** with a fused LUT (§2.3a).
  - `VideoContract.swift` drops `captureAdmissionLimit` and `previewPendingLimit` and adds `maxFramesInFlight = 3`, `outputPoolMinimum` and `cameraSinkQueueSize = 8`.
  - The DeckLink backend and `Sources/Recording/*` also change.
- **`Packages/MonitorTools`:** it deletes `MonitorAdaptivePolicy`, `MonitorCriticalPipelinePolicy`, `MonitorCompositePool`, `MonitorCriticalPipelineProducer`, `MonitorResourceCounters`, `OwnedMetalInput`, `OwnedPreview` (which holds `CleanPreviewService`) and `MonitorPresentationEstimate`, and rewrites `MonitorRuntime` and `MonitorTools.metal.txt`. It also deletes most of the package's Metal test files (§3.7).
- **Untouched so far** (still HEAD): `CaptureController.swift`, `MonitorCaptureSink.swift`, `MonitorCoordinator.swift` and the UI files. They still reference deleted symbols such as `MonitorCriticalPipelineProducer` and `CleanPreviewService`, so the tree is mid-change and won't build until that session finishes.
- After it commits, rerun the greps in §1 and update the line numbers. The symbol-level mapping should mostly still hold.
- **Anchor for the "WT" line numbers** (taken 2026-10-21 23:33; `git diff --shortstat -- Sources/` = 14 files, +3828/−890):
  - `shasum -a 256 Sources/App/LUTProcessor.swift` = `a30ecc27ea51ad4a92e13bc9165941b4ced07d2dc256175acde7be3621c7054c`
  - `shasum -a 256 Sources/App/LUTShaders.metal` = `75d4ffc7536cfe9db69bd760bff309c10eae8e9ba0fc90461a8ab190e27241cc`
  - If those differ, re-derive the WT references in §2.3a and §2.4.

**Uncommitted at the time of writing (another session's work; do not overwrite):**
- The deployment target was raised from 15.0 to 26.0 in `scripts/generate_project.py:84`, `Packages/MonitorTools/Package.swift:6` and 11 shell scripts (see §4.3).
- `Ultracam.xcodeproj/project.pbxproj` was regenerated before the `generate_project.py` edit:
  - It still says `MACOSX_DEPLOYMENT_TARGET = 15.0` at lines 516 and 535.
  - It drops `GPURawFrameCopy.swift` and `SharedMetalBuffer.swift` and adds `UIRenameAlert.swift`.
  - It now has machine-absolute `DECKLINK_SDK_DIR` and `LIBRARY_SEARCH_PATHS`.
  - `scripts/build.sh:51` regenerates this file on every build, so `generate_project.py` is the only source of truth.
- `docs/MONITOR_LIBRARY_PLAN.md`: adds the "Platform" section.
- `Packages/MonitorKit/`: the whole package is untracked. The W1 workflow (`wf_548da617-dbb`) is building it now.

**What MonitorKit has.** It is being built live by W1; files appeared between 23:15 and 23:33. Recheck with `wc -l Packages/MonitorKit/Sources/*/*.swift` and `grep -l "class MonitorEngine\|class MonitorFeed\|class MonitorPass" -r Packages/MonitorKit/Sources`.

| As of 2026-10-21 23:33 | Exists (code present, audit pending) | Not yet |
| --- | --- | --- |
| `MonitorKitCore` | `CubeLUT`, `LUTInterpolation`, `LUTRouting`, the `CubeLUT.apply` CPU reference, `MonitorState` and its settings, `SignalDescription`/`PixelLayout`/`LogEncoding`, `MonitorLayout`/`GuideRaster`/`MonitorRect`, the false-color tables, reference math (+`DecodeReference.swift`) | — |
| `MonitorKit` | `MonitorFrame` + `wrap`, `MonitorLUT` + `LUTParameters`, `MonitorShaders`, `MonitorEngine` (`MonitorEngine.swift:9-82`), `MonitorFeed` (`burnInLUT`, `monitorLUT`, `analyze`, `hasFocusMask`, `invalidateFocusMask`; `MonitorFeed.swift:8-88`), `MonitorPass` (`encode`/`prepare`/`draw` as in the contract; `MonitorPass.swift:80-171`), `MonitorStatus`, `MonitorViewport`, `MonitorTool`, `PassParameters`; the shaders `MKLUT`, `MKDecode` and `MKMonitor` | Freeze API |
| `MonitorKitScopes` | `ScopeSettings` (`kind`, `stage`, `waveformMode`, …, `display`), `ScopeDisplay`, `ScopeGraticule`, `ScopeParameters`, `ScopeEngine` (just added), `MKScopes.msl` (518 lines) | Accumulator and renderer not confirmed |
| `MonitorKitAudio` | config, snapshot, filters, planar stage | meters not confirmed |
| `MonitorKitUI` | — (2-line stub) | `MonitorMetalView`, SwiftUI controls, legends |
| Tests | Core: 49 tests. `MonitorKitTests` has support files, but its only test compiles the shaders | GPU pixel and contract tests |

**What this means for sequencing:**
- **The LUT swap (§2) is unblocked**, and mostly done in the working tree (§2.3a).
- **The monitor swap (§3) can be prototyped** against `MonitorEngine`/`MonitorFeed`/`MonitorPass` now, but it is blocked for real use until W1's audit and the GPU pixel tests land.
- **The UI swap waits on MonitorKitUI** (W2).
- In §3, **(contract)** marks types that were contract-only when §3 was first drafted. Most now exist; treat them as "API may still change until the W1 audit".

---

## 1. Every use of MonitorTools today, and its MonitorKit replacement

Imports: `rg -n "import MonitorTools" Sources Tests Tools`. The package has three products: `MonitorToolsCore`, `MonitorToolsMetal` and `MonitorToolsUI` (`Packages/MonitorTools/Package.swift:7-10`).

### 1.1 App sources

| File:lines | MonitorTools symbols | What it does today | MonitorKit replacement |
| --- | --- | --- | --- |
| `Sources/App/AppSettingsStore.swift:2, 235, 242, 256, 293, 315` | `MonitorConfiguration` | `FeedDescriptor.monitorConfiguration`: per-camera tool settings, decoded leniently | `MonitorState` (Core) under a **new key**, plus a legacy decoder (§3.5) |
| `AppSettingsStore.swift:327-328, 334-335, 341-342, 366, 378-379` | `MonitorConfiguration`, `MonitorWorkspaceState` | `AppSettingsSnapshot.programMonitorConfiguration` and `.monitorWorkspace` | `programMonitorState: MonitorState`. The workspace becomes an **app-owned** type (§3.6) |
| `Sources/Shared/FeedRuntime.swift:4, 266-267, 281-282, 721` | `MonitorConfiguration`, `MonitorWorkspaceState` | `FeedCoordinator` holds the Program monitor config and the workspace, and writes them back into the snapshot | Same fields, retyped to `MonitorState` and the app-owned workspace type |
| `Sources/App/AppModel.swift:2, 152` | `MonitorTargetID` | `monitorDemand: Set<MonitorTargetID>` | App-owned `MonitorTargetID` (§3.6) |
| `AppModel.swift:203-207` | `MonitorTargetID`, `MonitorConfiguration` | Builds `MonitorCoordinator` from the snapshot, with "program" as a target | Same, with `MonitorState` |
| `AppModel.swift:235-262` | — | `onConfigurationChange` writes back into the descriptor. Also `onWorkspaceChange`, `onDemandChange` (into `reconcileAutomaticFeed`) and `onPreviewEnabledChange` | Same callbacks; retype the payload |
| `AppModel.swift:886, 893, 1050, 1069, 1100, 1198, 1258` | `MonitorTargetID` | `setMonitorSink`, `sourceStateChanged`, Program and preview demand, `setPreviewEnabled` | `setMonitorSink` becomes `setFeedMonitor(FeedMonitor?)` (§3.3). The others keep their shape |
| `Sources/App/CaptureController.swift:5, 106-110` | `MonitorCaptureSink` (app type) | Monitor sink, sequence and `monitorProcessingRevision` / `monitorPipelineConfiguration` | One `FeedMonitor?`. `processingRevision` goes away: output-stage pixels are computed in the monitor pass from the same `MonitorLUT` |
| `CaptureController.swift:244, 473, 898, 918-921` | — | Bumps `monitorProcessingRevision` on LUT load, reconfigure and format change | Delete. A LUT change becomes `feedMonitor.setBurnInLUT(_:)` |
| `CaptureController.swift:499-502, 516-528` | — | `setMonitorSink` and the stop-path lifecycle sink | `setFeedMonitor`. On stop: `feedMonitor.clear()` |
| `CaptureController.swift:924-931` | — | `reportCriticalPipeline`, plus the **early source-only offer** | One `feedMonitor?.publish(source: input, pts:, sequence:)`. Delete critical-pipeline reporting (GPU plan §3 retire list) |
| `CaptureController.swift:935, 938, 940-941, 973-975` | — | `needsOutput` keeps processing alive for monitor output; `reportCriticalPipeline` | Delete `hasMonitorOutput`. The monitor needs only the source |
| `CaptureController.swift:980-986` | `MonitorCorrespondence` | The **paired source+output offer**, with a scale correspondence | Delete. No processed-output tap for camera monitors (§3.2) |
| `Sources/App/MonitorCaptureSink.swift` (all 346 lines) | `MonitorRuntime`, `MonitorCriticalPipelineProducer`, `MonitorSurfacePresenter`, `MonitorConfiguration`, `MonitorFrameStamp`, `MonitorFrameBundle`, `MonitorDisplayResult`, `MonitorGeometry`, `MonitorRect`, `MonitorFrameSignal`, `MonitorCodeRange`, `MonitorYCbCrMatrix`, `MonitorCorrespondence` | Capture-side endpoint. Try-locks and drops at 123, 147, 182-185, 197-204, 215-218, 263 and 288. Clean-preview fallback at 237-248. `geometry()` at 295-326, `signal()` at 328-345 | **Replace the file** with `FeedMonitor` (§3.3). `signal()` becomes `MonitorFrame.signal(of:range:)` plus the feed's declared log encoding. `geometry()` becomes `MonitorFrame.wrap` (it reads the PAR). Clean aperture has no MonitorKit equivalent yet (API ask) |
| `Sources/App/MonitorCoordinator.swift` (281) | `MonitorRuntime` (27, 51-58), `MonitorSurfacePresenter` (31, 174-189), `MonitorTargetOption` (19, 119-126), `MonitorDiagnostics` (26, 61-70), `MonitorWorkspaceState` (11-18), `MonitorConfiguration` (20, 72-99), `MonitorTargetID` | Main-actor control: configs per target, `copySettings` (84-99), preview enable (101-114), `updateTargets` (116-164), `captureSink` (166-172), surfaces (174-216), `refreshSink` with scope-Hz cap (218-233), demand (235-245), `offerProgram` (267-280) | **Rewrite in place** with the same public surface the UI uses: `configuration(for:)` becomes `state(for:)`, plus `copySettings`, `targets`, `workspace`, demand and preview enable. It owns `MonitorEngine` (contract) and the `FeedMonitor`s. Delete runtime admission, the scope-Hz cap (`preferredHz`) and presentation admission |
| `Sources/App/MonitorWorkspaceView.swift` (317) | `MonitorTileChrome` (43, 283), `MonitorSurfaceVisibility` (55, 60), `MonitorPictureZoom` (59, 79), `MonitorNativePicture` (65), `MonitorGuideOverlay` (73), `MonitorDiagnosticsView` (157), `MonitorNativeScope` (170), `MonitorScopeGraticule` (171), `MonitorSurfacePresenter` (11) | Detached monitor windows only: `MonitorDetachedWindows` (224), `MonitorWindowOwner` (249), `DetachedMonitorContent` (264). The tile chrome brings MonitorToolsUI's toolbar and false-color legend (`MonitorWorkspaceShell.swift:176, 189`) | The `MonitorSurface` view (CAMetalLayer) or `MonitorKitUI.MonitorMetalView` (contract). Legends become MonitorKitUI legends (contract). Guides are drawn in-shader, so delete the SwiftUI overlay. Zoom becomes `MonitorState.geometry.magnification` (GPU) |
| `Sources/App/UIAppProviders.swift` (181) | `MonitorConfiguration` (35-40, 70-71, 86-89), `MonitorTargetID`, `MonitorSurfacePresenter` (63), `MonitorSurfaceVisibility` (99, 102), `MonitorGuideOverlay` (105, 113), `MonitorNativePicture` (111), `MonitorNativeScope` (125), `MonitorScopeGraticule` (126) | All in-window pictures: the native `VideoPreview` for the selected camera when no tool alters pixels (80-84, 101), a monitor surface otherwise, scopes, the Program toolbar (139-146), registration (171-180) | Every picture becomes a `MonitorSurface`. `usesNativePreview` goes (step 9 in §6.3). Remove the guide overlays (in-shader now) and presentation admission (117-120) |
| `Sources/App/UISupport.swift:4-5, 86-181` | `MonitorSurfacePresenter` (89-101), `MonitorConfiguration` (103-158), `SonySLog3FalseColor`/`ELZoneProfile` (142-149), `MonitorTargetID` | `UIMonitorBridge`: the presenter registry, `activeTools`, `sourceProfile(forGamut:)`, `toggled` (master-switch logic 126-133, 155-156), freeze/clean/detach (167-181) | Retarget to `MonitorState`: `.zebras[0].enabled`, `.falseColor.mode`, and so on. `SonySLog3FalseColor` and `ELZoneProfile` keep their names in MonitorKitCore (`Reference/`). The registry holds `MonitorSurface`s |
| `Sources/App/UIMonitorTools.swift` (349) | `MonitorConfiguration`, `MonitorZebraMode`, `MonitorPeakingColor`, `MonitorScopeMode`, `MonitorStage`, `MonitorFalseColorMode`, `MonitorCodeRange`, `MonitorSourceLogMapping`, `SonySLog3FalseColor`, `ELZoneProfile` | `UIMonitorToolButtons` (6-87). `UIMonitorToolSettingsView` (130-349) binds every field (179-266); `falseColorMode` (292-313); `sourceProfile` (315-336) | Bind to `MonitorState` (field map in §3.5). Signal settings (250-257) move to a per-feed signal editor. Or adopt the MonitorKitUI SwiftUI controls (contract) |
| `Sources/App/UIContext.swift:2, 20-21, 89-102` | `MonitorConfiguration` | `UIMonitorSettingsProviding` protocol; `UIFixtureMonitorSettings` | Retype to `MonitorState` |
| `Sources/App/UISessionBridge.swift:2, 142-143, 371-378` | `MonitorTargetID`, `MonitorConfiguration` | `activeTools` in the snapshot; reset and copy actions | Retype |
| `Sources/App/UIDiagnostics.swift:2, 101, 174-215` | `MonitorDiagnostics` | `UIDiagnosticsMonitorSection`: offered/picture/scope fps, quality tier, admitted/skipped counts, memory, GPU deadline | New rows: presented fps, late vsyncs, GPU ms per pass, `MonitorStatus` reasons (contract). Delete tier, stride, admission and deadline rows (no skip rules) |
| `Sources/App/UICameraColumn.swift:1-2, 64, 262-285` | `MonitorPictureZoom`, `MonitorStage` | SwiftUI zoom of the picture; the "Picture: Output / Source" menu | Zoom becomes `geometry.magnification`. **Picture stage has no `MonitorState` field** (gap, §3.5) |
| `Sources/App/UICommands.swift:227-242`, `UIMenuBar.swift`, `UILiveRoot.swift:11, 17, 43` | via `UIMonitorBridge` / `MonitorCoordinator` (app types) | Freeze, Clean View and the tool menu | Unchanged call sites once `UIMonitorBridge` is retargeted |
| `Sources/App/UISettings.swift:632-650` | — | Monitor pane text: "Under heavy load, new monitor analysis pauses…" (648) | Rewrite the text: the GPU plan removes skip rules |

### 1.2 Tests, Tools, scripts, project

| File:lines | Use | Action |
| --- | --- | --- |
| `Tests/MonitorCoordinatorChecks.swift:3-4` (14 tests) | `MonitorConfiguration`, `MonitorTargetID`, `CleanPreviewService`, `MonitorDisplayResult`, `MonitorFrameBundle`, `MonitorFrameStamp`, `MonitorWorkspaceState` | §3.7 |
| `Tests/MonitorLifecycleChecks.swift:2, 6-35` | Snapshot defaults and round-trip | Retarget to `MonitorState` keys and add a migration test (§3.7) |
| `Tests/CaptureRecordingIsolationChecks.swift:4-6` | `MonitorRuntime`, `MonitorSurfacePresenter`, `MonitorCaptureSink` (132-240, 242-340, 342-433, 435-522, 524-670, 883-) | §3.7 |
| `Tools/CameraSmoke/main.swift:8-9, 377-420` | `MonitorComparison` (`--monitor` mode) builds `MonitorRuntime` bundles | Rewrite over `MonitorFeed`/`MonitorPass` (contract), or drop `--monitor` |
| `Tools/MonitorAppIntegration/main.swift:2, 19-39, 86` | `MonitorTargetID`, `MonitorWorkspaceState` | Retype to the app-owned types |
| `Tools/UIVerify/main.swift:2` | `MonitorConfiguration` fixtures; Monitor settings pane (498) | Retype |
| `Tools/MonitorToolsSmoke`, `Tools/MonitorToolsRecording` (+`PipelineAdmission.swift`, `QualificationMetrics.swift`), `Tools/MonitorToolsRecordingTests`, `Tools/MonitorToolsBenchmark` | Qualification harnesses for the old runtime: ledger, admission, clean preview | Retire with the package. MonitorKit's own GPU-timing and contract tests replace them |
| `scripts/monitor-tools-package.sh:4, 14, 21-23, 28` | Builds the 3 products, sets `monitor_link_args`, copies `MonitorToolsMetal.bundle` | Rename or replace (§4.2) |
| `scripts/test.sh:21-27, 53, 60` | Package build, `swift test` of MonitorTools, link args; compiles `MonitorCoordinator.swift` and `MonitorCaptureSink.swift` | Point at MonitorKit. Update the source list after §3 |
| `scripts/ui-verify.sh:21-22` | Input hash walks `Packages/MonitorTools/Sources` (`*.swift *.metal *.txt …`) | Walk `Packages/MonitorKit/Sources` **and add `*.msl`**, or shader edits will not invalidate the cache |
| `scripts/ui-typecheck.sh:16-21`, `monitor-app-integration.sh:19-25, 45`, `camera-smoke.sh:29-31` | `monitor_package_build` and link args | Follow §4.2 |
| `scripts/camera-smoke.sh:36`, `scripts/monitor-tools-recording.sh:24` | Compile `Sources/Shared/CubeLUT.swift` by path | Remove the path once the file is deleted (§2.6) |
| `scripts/monitor-tools-{smoke,recording,benchmark,admission-checks,stress}.sh`, `scripts/monitor-tools-fingerprint.py:14-20` | Old harnesses and receipt fingerprints | Retire |
| `scripts/validate_bundle.py:59-64` | Requires `*MonitorToolsMetal.bundle` with `MonitorTools.metal.txt`; forbids "MonitorTools" in the extension | Require `*MonitorKit_MonitorKit.bundle` with `Shaders/MKLUT.msl`, `MKDecode.msl` and `MKMonitor.msl`, plus the `MonitorKitScopes` bundle once it has resources. Forbid "MonitorKit" in the extension |
| `scripts/generate_project.py:87-89, 95, 114, 125` | `XCLocalSwiftPackageReference` and 3 product dependencies, app target only | §4.1 |
| `Ultracam.xcodeproj/project.pbxproj:555-575, 954-962, 1047, 1097` | Generated output of the above | Regenerate; never hand-edit |

---

## 2. The LUT path today, and the swap to `MonitorLUT` + `mk_applyLUT`

### 2.1 Data and persistence

- **Parser:** `Sources/Shared/CubeLUT.swift`.
  - Internal `struct CubeLUT`: `title`, `dimension` (2…65), `domainMin`/`domainMax`, and `rgba` (red fastest, alpha = 1, 4 floats per entry), plus `data`.
  - `Packages/MonitorKit/Sources/MonitorKitCore/CubeLUT.swift` is the **same parser, made public**. `diff` shows only `public`, `Equatable` and doc comments differ, and the `ParseError` case is the same.
- **File access** is in `AppSettingsStore.swift:458-520`:
  - `LoadedLUT {cube, bookmark, fileName}` and `actor LUTFileLoader`.
  - `load(url:)` (471-478) makes a **security-scoped bookmark** (`.withSecurityScope, .securityScopeAllowOnlyReadAccess`), or `.minimalBookmark` when `scopedBookmarks == false` (tests).
  - `restore(bookmark:)` (480-492) resolves it with `.withSecurityScope, .withoutUI` and re-creates the bookmark if it is stale.
  - `read` (494-520) checks for a regular file, a 32 MB bound on both stat and read, and UTF-8.
  - The access window spans the read only.
  - Entitlements: `Config/App.entitlements`, `files.user-selected.read-write` and `files.bookmarks.app-scope`.
- **What is persisted:**
  - `FeedDescriptor.lutBookmark: Data?` and `FeedDescriptor.applyLUT: Bool` (`AppSettingsStore.swift:225, 232`; decoded at 305 and 312). They live inside `AppSettingsSnapshot`, which is JSON under defaults key `ultracam.settings.v2` (389, written at 434-442).
  - The legacy v1 `AppSettings` (`ultracam.settings.v1`, 198-216) carries the same two fields and is migrated at 411-427.
  - LUT *contents* are never persisted (383-384).
  - The installed app keeps this in its sandbox container. The Debug build uses `~/Library/Preferences/org.ultracam.app.plist`.

### 2.2 Control flow: settings and UI → `PipelineConfiguration` → GPU

- **`PipelineConfiguration`** (`Sources/Shared/VideoContract.swift:122-141`):
  - `applyLUT`, `downscale`, `convertTo420`, `reduceFrameRate`, `inputFast`.
  - `untouched` = `!applyLUT && !downscale && !convertTo420` (137).
  - The descriptor builds it at `AppSettingsStore.swift:268-271`.
- **Selected camera (AppModel):**
  - Init restores `configuration` with `applyLUT = false` until the GPU upload succeeds (`AppModel.swift:308-335`, especially 313), then `restoreLUT(bookmark:)` (335, 382-397).
  - `chooseLUT(feedID:)` (362-380) runs `NSOpenPanel` for `.cube`, then `LUTFileLoader.load`.
  - `uploadLUT` (399-432) calls `controller.load(cube)`. On success it sets `lutLoaded` and `lutBookmark`, `configuration.applyLUT = enable` (424) and `lutTitle`/`lutFileName`.
  - `configuration.didSet` (99-105) saves and calls `reconfigure()` (670-674).
  - `effectiveConfiguration` (664-668) masks `applyLUT && lutLoaded`.
  - `forgetLUT` (1278-1296).
  - Known bug (GPU plan line 107): `chooseLUT` for a non-selected camera drops the selected camera's in-flight restore (the `lutLoadGeneration` guard at 403 and 408).
- **Other cameras (headless):**
  - `restoreHeadlessLUT` (932-969) loads the cube into that feed's controller, then `feedCoordinator.reconfigureCapture(…applyLUT: true)` (`FeedRuntime.swift:529`). Failure handling is at 971-980.
  - It is called on selection change (580-600), on start (702-712, 1088-1093, 1178-1183, 1265-1271) and from `updateCamera` (1215-1250).
- **Capture queue:**
  - `CaptureController.load(_:expectedGeneration:completion:)` (`CaptureController.swift:235-251`) creates the `LUTProcessor` lazily and calls `processor.load(cube)`.
  - `effectiveConfiguration(inputFast:)` (653-658) turns everything off when processing is off.
  - `ensurePrepared` (660-666) re-warms when `applyLUT` changes.
  - `process()` (957-970) calls `LUTProcessor.process`.
- **UI:**
  - Effect chip 0, "LUT" (`UIPresentation.swift:444-445, 561-566`), is enabled only when `lutName != nil`. It sends `.setEffect(id, 0, on)` (`UISessionBridge.swift:289-299`), which writes `descriptor.applyLUT`.
  - The snapshot fills `effects[0]`, `lutName`, `lutLoading` and `lutError` (`UISessionBridge.swift:124-130`).
  - Inspector `lutSection` (`UIInspector.swift:147-178`): Load/Change… and the input gamut.
  - ⌘O (`UICommands.swift:39-40`), the menu bar item (`UIMenuBar.swift:420`), and "LUT unavailable · Locate…" (`UICameraColumn.swift:499-520`, 611).
  - "Forget Saved LUTs" (`UISettings.swift:663-732`).
- **Program and contracts:**
  - The LUT never changes the camera format. `FeedLifecycleDemandPolicy.programContract` (`AutomaticFeedPolicy.swift:8-14`) passes `applyLUT` through.
  - `programFormatMismatch` clears it (`AppModel.swift:1316-1330`).
  - `ProgramOutputBridge.reconnectLocked` builds a default `applyLUT = false` contract (`ProgramOutputBridge.swift:205-226`), and `sameContract` ignores it (229-235).

### 2.3 `LUTProcessor` and the kernels at HEAD (superseded in the working tree, §2.3a)

- `LUTProcessor.init` (`LUTProcessor.swift:68-95`):
  - Creates its **own** `MTLDevice` and queue (69-73).
  - Compiles `LUTShaders.metal` **from source at runtime** with `options: nil` (78-81). Overrides: `ULTRACAM_METALLIB` (75-76) and `ULTRACAM_SHADER` (78).
  - Builds pipelines for six kernels (84-87).
  - Allocates a 16-byte placeholder `cubeBuffer` (89-92).
  - The shader ships as a copied resource, not compiled by Xcode (`generate_project.py:108-109`, "Copy GPU Shader Source").
- `load(_ cube:)` (97-104): `makeBuffer(bytes: cube.data)`, an `rgba32Float` lattice in a flat `MTLBuffer`.
- `process` (291-454):
  - Throws "Load a LUT or turn off Apply LUT." when `applyLUT && cube == nil` (300). `EndToEndChecks.swift:104-122` tests this.
  - `Parameters` (58-66, mirrored at `LUTShaders.metal:4-12`) **overloads LUT fields** (315-321):
    - `geometry.w` = cube dimension
    - `domainLow.xyz` = DOMAIN_MIN
    - `domainLow.w` = **chroma offset** (read at `LUTShaders.metal:38` and `:66`)
    - `domainScale.xyz` = 1/(max−min)
    - `options.x` = applyLUT
  - `encodeMatrix` switches to Rec.709 when the LUT is applied (320), and so do the output colour tags (438-452).
  - Dispatch:
    - `packedLUT` (v210 through the texture cache, 339-359): `texture(3)` = groups, `texture(2)` = full-res `rgba32Float`, `buffer(0)` = cube, `buffer(1)` = params.
    - `planarLUT` (360-369): `texture(0)` = Y, `texture(1)` = UV, `texture(2)` = out, same buffers.
    - Then `lanczosHorizontal`/`lanczosVertical` (371-384) and `encodeNV12`/`encode422` (385-388, `buffer(1)` only).
- `LUTShaders.metal:14-25` `lookup()`: manual trilinear with 8 buffer reads; x, then y, then z; `mix`. It is called at 41 (planar) and 69 (packed) on `decode(...)` (27-31).

### 2.3a Working tree (ultracam-18, uncommitted): the fused LUT is mostly done

The in-progress rewrite already does most of §2.4, in app-owned form.

**`LUTShaders.metal` (WT):**
- Lines 1-60 hold a **verbatim copy of `MKLUT.msl`**, including the `MK_LUT_MSL` guard.
- `Parameters` (WT :63-74) now has a dedicated `chroma` row (the chroma offset no longer lives in `domainLow.w`) and embeds `mk_LUTParams lut`.
- `graded()` (WT :134-136) calls `mk_applyLUT(source.pixel(x, y, p), lut, p.lut)`.
- Eight fused kernels, each with `lut [[texture(2)]]` and `Parameters [[buffer(0)]]`:
  - `fullPackedNV12`, `fullPacked422`, `fullPlanarNV12`, `fullPlanar422`: decode + LUT + encode in one pass, no downscale (WT :177-196)
  - `horizontalPacked`, `horizontalPlanar`: decode + LUT + horizontal Lanczos (WT :233-241)
  - `verticalNV12`, `vertical422` (WT :258-269)

**`LUTProcessor.swift` (WT):**
- Still `MTLCreateSystemDefaultDevice()` per processor (:179).
- Uses `MTL4CommandQueue` (:182-185) and `MTL4Compiler` + `MTL4LibraryDescriptor` with **no `options` set** (:187-199).
- Uses argument tables (:215-231), residency sets (:236-246) and `MTL4CommitOptions` (:668-674).
- Still `cube: CubeLUT?` plus an app-made `lutTexture` (:101-102). `makeLUTTexture` (:255-273) is a `type3D rgba32Float`, `.shared`, `.shaderRead` texture uploaded with `bytesPerRow n*16` and `bytesPerImage n*n*16`. That is **byte-for-byte the same texture `MonitorLUT` builds** (`MonitorLUT.swift:31-47`).
- A 2³ identity placeholder is bound when off (:240-243).
- `load` waits for in-flight frames before swapping (:275-284).
- The LUT fields are filled by hand (:470-480). `lutShape.y = 1` is hard-coded trilinear, and `lutShape.z = applyLUT`.

**Consequence:** the Metal 4 APIs need macOS 26, so the app now needs the 26.0 target on its own, independent of MonitorKit.

### 2.4 The swap: same pass, `texture3d` + `mk_applyLUT`

This is the fused tier: decode, resize, depth and frame rate stay in `LUTProcessor`; only the LUT math and resource change.

**Against the working tree (§2.3a), the remaining delta to MonitorKit is small:**
1. **Replace the verbatim copy with the library source.** Prepend `try MonitorShaders.source([.lut])` to `descriptor.source` (WT `LUTProcessor.swift:195`).
   - The include guard makes prepending safe even before the copy is deleted from `LUTShaders.metal` (WT :1-60).
   - Alternatively keep the copy and add a drift test that asserts it equals `MKLUT.msl`.
   - `ULTRACAM_METALLIB` (WT :189-190) needs the same concatenation at metallib build time.
2. **Make the texture a `MonitorLUT`.**
   - `cube` + `lutTexture` + `makeLUTTexture` (WT :101-102, 255-284) become `lut: MonitorLUT?`. The residency calls take `lut.texture`.
   - The placeholder (WT :240-243) becomes a `MonitorLUT` of an identity 2³ cube, or stays as is.
   - The numerics do not change, because the texture is identical.
   - Build the `MonitorLUT` with `interpolation: .trilinear` **once per file load** and share the instance with the monitor feed (§3.4).
   - Keep a `load(_ cube: CubeLUT)` convenience for the tests that call `controller.load(CubeLUT)`.
3. **Take the parameters from the `MonitorLUT`.** WT :478-480 (`lutDomainLow`, `lutDomainScale`, `lutShape`) becomes `lut.parameters` (`LUTParameters` has the same 3×16-byte layout as `mk_LUTParams`), with `shape.z = 0` when `applyLUT` is off, or `LUTParameters.disabled`. The interpolation mode then comes from `MonitorLUT.interpolation` instead of a hard-coded 1.
4. **Align the compile options** with `MonitorShaders.makeLibrary` (`mathMode = .safe`, MSL 4.0 or 4.1, `MonitorShaders.swift:31-38`). Set them on `MTL4LibraryDescriptor.options` (unverified: check that `MTL4Compiler` honours `mathMode`) so the output and monitor passes compile the same `mk_applyLUT` the same way (§2.5). A public `MonitorShaders.compileOptions` would be a useful API ask.
5. **Swap `CubeLUT`** (§2.6) and **share the device** (§3.2).

**For reference, the original plan against HEAD** (still valid if the working-tree rewrite is abandoned):

**`Sources/App/LUTShaders.metal`**
1. Delete `lookup()` (14-25).
2. `planarLUT` (33-35): add `texture3d<float, access::sample> lut [[texture(4)]]`. Replace `device const float4 *cube [[buffer(0)]]` with `constant mk_LUTParams &lutParams [[buffer(0)]]`. Line 41 becomes `mk_applyLUT(decode(luma, c, p), lut, lutParams)`.
3. `packedLUT` (55-56, 69): the same change. `texture(4)` is free; `texture(0..3)` are taken.
4. Keep `Parameters` as it is so the decode and encode kernels don't move. `domainLow.w` stays the chroma offset. Optionally rename it (for example `float4 chroma`) in both the Swift and MSL structs. Leave `geometry.w`, `domainLow.xyz`, `domainScale.xyz` and `options.x` at zero, or remove them in a follow-up.

**`Sources/App/LUTProcessor.swift`**
1. Add `import MonitorKit`, which re-exports `MonitorKitCore` (`MonitorKit.swift:1`).
2. Library (74-82): `source = try MonitorShaders.source([.lut]) + "\n" + String(contentsOf: url)`.
   - `MKLUT.msl` is self-contained and include-guarded (`MK_LUT_MSL`, :7-8); duplicating `#include <metal_stdlib>` is harmless.
   - **Choose the compile options deliberately (§2.5):** keep `device.makeLibrary(source:options: nil)` for exact equality with today's output, or use `MonitorShaders.makeLibrary(device:parts:[.lut], extra:)` so the output and monitor passes share `mathMode = .safe` and MSL 4.0 (`MonitorShaders.swift:31-39`).
   - `ULTRACAM_METALLIB` (75-76): an offline metallib must be built from `MKLUT.msl` + `LUTShaders.metal` concatenated.
3. Replace `cube: CubeLUT?` and `cubeBuffer: MTLBuffer` (46-47, 89-92) with `lut: MonitorLUT?` and `placeholderLUT: MonitorLUT`. The placeholder is an identity 2³ cube built once in `init`.
   - Metal needs a 3D texture bound even when disabled. `mk_applyLUT` returns early on `shape.z == 0` (`MKLUT.msl:21`), exactly as `lookup` does on `options.x == 0` (`LUTShaders.metal:15`).
4. `load(_ cube: CubeLUT)` (97-104) becomes `load(_ lut: MonitorLUT)` (`precondition(lut.texture.device === device)`).
   - Build the `MonitorLUT` **once per file load** with `interpolation: .trilinear`, and share the same instance with the monitor feed (§3.4).
   - Keep a `load(_ cube: CubeLUT)` convenience that builds a trilinear `MonitorLUT`, for the tests at `EndToEndChecks.swift:528, 1364` and `CaptureRecordingIsolationChecks.swift:572`.
5. `process` (300, 313-321):
   - The guard becomes `lut != nil`.
   - Drop the cube-derived `low`/`scale`/dimension.
   - `var lutParams = configuration.applyLUT ? lut!.parameters : LUTParameters.disabled`. `LUTParameters` has public `var`s but no public memberwise init (`MonitorLUT.swift:5-13`); use `.disabled` or mutate a copy.
6. Dispatch (354-359, 364-368): `encoder.setTexture((configuration.applyLUT ? lut! : placeholderLUT).texture, index: 4)`, then `encoder.setBytes(&lutParams, length: MemoryLayout<LUTParameters>.stride, index: 0)`.
7. Unchanged: `encodeMatrix`, the output tags, `untouched`, prewarm (`prepare` 109-138) and the pools. `PipelineConfiguration.applyLUT` now means **burn-in on**.

### 2.5 Trilinear bit-compatibility

**Why the texel reads are identical:**
- Old read: `cube[(z*n + y)*n + x]` on a flat buffer of `cube.data`.
- New read: `lut.read(uint3(x, y, z))` on a `type3D rgba32Float` texture. It is uploaded from **the same red-fastest array** with `bytesPerRow = n*16` and `bytesPerImage = n*n*16` (`MonitorLUT.swift:31-47`).
- Both return the stored float exactly.

**Why the arithmetic is identical:**
- Clamp, scale, floor, `min(lo+1, n-1)`, `t` and the `mix` order (x, then y, then z) in `MKLUT.msl:23-36` match `LUTShaders.metal:17-24` line for line.
- The domain math also matches: `MonitorLUT` computes `scale = 1/(max−min)` in Swift exactly as `LUTProcessor.swift:313-314` does.

**What can break equality:**
1. **Interpolation default.** `MonitorLUT.init` defaults to `.tetrahedral` (`MonitorLUT.swift:28`). The compat path must pass `.trilinear` explicitly (mode 1). Never use `.hardware` (mode 2, the texture filter) on the output path.
2. **Compile options.**
   - Today the kernels compile with `options: nil`, which is the default, fast math.
   - `MonitorShaders.makeLibrary` forces `.safe` and MSL 4.0. A monitor pass compiled that way can differ from a fast-math `LUTProcessor` by a few ULPs.
   - Exact output-vs-pre-change equality requires keeping `options: nil`. Exact preview-vs-output equality requires the same options on both sides.
   - **Decision needed.** Recommended: switch `LUTProcessor` to `MonitorShaders.makeLibrary(…)` (safe math) and accept the ULP-level change against old output, which the existing tolerances absorb. That gives exact LUT equality between preview and output.
3. **Golden check.** In the working tree, ultracam-18 has already replaced `lookup()` (§2.3a); make sure its commit includes this check. The MonitorKit delta in §2.4 is numerically neutral (same texture, same `mk_applyLUT` text) unless the compile options change. Re-run the check if they do. Before deleting `lookup()`, add a temporary test:
   - Keep the old buffer kernel in a test-only shader string.
   - Run both kernels with the same compile options on a ramp, plus a random 17³ and 33³ cube with a non-unit domain.
   - Assert **exact** equality of the `rgba32Float` intermediate. Read it back via a test hook, or compare 10-bit 4:2:2 output with `convertTo420 = false`.
   - Then delete the old kernel.

**Tests that assert LUT output.** All use tolerances, so they pass if the math is unchanged or ULP-close. They should also pass with tetrahedral, because the synthetic cubes are separable along the neutral axis, but verify that before switching any default.

| Test (file:line) | LUT | Expectation |
| --- | --- | --- |
| `Tests/main.swift:39-86` `CubeTests` (5) | parser | Unchanged semantics against `MonitorKitCore.CubeLUT`. The file needs `import MonitorKit` or `import MonitorKitCore` |
| `Tests/main.swift:89-103` `testTenBitPrecision` | identity 2³ | 4K 4:2:2 output keeps >800 levels; endpoints 64 and 940 ±2 |
| `Tests/main.swift:104-118` `testLUTAndLanczosThenNV12` | 17³ x² | NV12 1080p, luma[960] = 16+219·0.25 ±3 |
| `Tests/main.swift:128-142` `testIndependentSwitches` | identity | Every switch combination gives the right geometry and format |
| `Tests/main.swift:144-162` `testNonlinearLUTPrecedesLanczos` | 17³ x² | LUT before scaling: 16+219·0.5 ±3 |
| `Tests/main.swift:163-~192` `testPackedV210Precision` | identity | v210, every lane ±1 code |
| `Tests/EndToEndChecks.swift:50-75` `testAllSwitchesAndBothRatesProduceUsableSamples` | 1−x | Constant neutral image: luma 180/71 (4:2:0) or 721/283 (4:2:2) ±1, with or without the LUT |
| `EndToEndChecks.swift:104-122` | none | `applyLUT` with no LUT throws (keep the guard) |
| `EndToEndChecks.swift:124-150` `testLUTConsumesTenBitPrecisionBeforeEightBitQuantization` | domain 0.35…0.55 | 80 distinct 8-bit levels, each ±1; output tagged Rec.709 |
| `EndToEndChecks.swift:499, 528, 1364-1374` | 17³ x² via `controller.load` | Controller paths (needs the `load(_ cube:)` convenience) |
| `Tests/GPUExtendedChecks.swift:128-155` | identity | Packed and planar agree ±1 for every lane and stride |
| `GPUExtendedChecks.swift:157-171, 173-195` | identity / reordered + domain | Chroma location ±1; RGB ordering and domain clipping ±2 (luma and both chroma) |
| `GPUExtendedChecks.swift:263-275, 277-289, 359-371` | identity | No LUT colour labels leak onto bypass; prewarm keeps 10-bit; precision kept when downscale is off |
| `Tests/CaptureRecordingIsolationChecks.swift:466, 572-583` | 17³ x² | LUT on the capture and recording path |

### 2.6 `CubeLUT` file swap

- Delete `Sources/Shared/CubeLUT.swift` and use `MonitorKitCore.CubeLUT`.
- **Do not leave both.** A declaration in the module shadows the imported one, so the app would silently keep its own type and the `MonitorLUT(cube:)` call would not type-check.
- Add the import to: `AppSettingsStore.swift` (`LoadedLUT`, `LUTFileLoader.read` at 518), `CaptureController.swift`, `LUTProcessor.swift`, `Tests/main.swift`, `EndToEndChecks.swift`, `GPUExtendedChecks.swift` and `CaptureRecordingIsolationChecks.swift`.
- Remove the path from `scripts/camera-smoke.sh:36` and `scripts/monitor-tools-recording.sh:24`.
- The camera extension never compiles `CubeLUT.swift` (`generate_project.py:31-35`), so it stays MonitorKit-free.

---

## 3. The per-feed monitor pipeline

### 3.1 Today

The frame path for one camera:
1. `CaptureController.process` offers the source to `MonitorCaptureSink` (`:929`, try-lock, may drop).
2. The sink checks generation, revision and the scope-Hz rate limit (`MonitorCaptureSink.swift:141-224`).
3. `MonitorRuntime.offer` (a utility-QoS worker) runs ledger and admission, then fairness (3 slots), then tiers, then a composite into a pooled `CVPixelBuffer` (CPU memcpy, GPU plan §Monitor).
4. On failure the sink falls back to `CleanPreviewService` (237-248).
5. `publish` (262-282) calls `MonitorSurfacePresenter.accept` (`ifCurrent` recheck).
6. Each surface has an `AVSampleBufferDisplayLayer` (`MonitorNativePicture`) and a scope NSView (`MonitorNativeScope`).
7. SwiftUI overlays draw the guides (`MonitorGuideOverlay`) and the graticule (`MonitorScopeGraticule`).

Around that path:
- **Paired output tap:** `:984`, with `MonitorCorrespondence` for focus and aperture alignment.
- **Selected camera:** it does not use the monitor at all while no tool alters pixels. `VideoPreview` (an `AVSampleBufferDisplayLayer` on the processed sample, `VideoPreview.swift:11-50, 135-185, 435-449`) is used instead (`UIAppProviders.swift:80-84`).
- **Program:** `MonitorCoordinator.offerProgram` (267-280) offers the processed Program frame as both source and output; stages are forced to output (`MonitorCaptureSink.swift:64-67`).
- **Control:** `MonitorCoordinator` (main actor) handles per-target configs, the surface registry, demand (sent to `AppModel.monitorDemand`, which feeds automatic start and preview demand at `AppModel.swift:1049-1069`) and diagnostics snapshots.
- **Toolbar:** the app's `UIMonitorToolButtons` in pictures. The detached tile uses MonitorToolsUI `MonitorToolsToolbar`.
- **Legend:** `MonitorFalseColorLegend`, in detached tiles only (`MonitorWorkspaceShell.swift:189`).
- **Diagnostics:** `UIDiagnosticsMonitorSection`.

### 3.2 New design

These rules come from the plan's added requirements and `ARCHITECTURE.md`.
- **One engine.**
  - One `MonitorEngine(device:)` (contract) per GPU, owned by `MonitorCoordinator` and created with the **same `MTLDevice`** as `LUTProcessor`.
  - A `MonitorLUT` texture can only be shared within one device.
  - Today every `LUTProcessor` calls `MTLCreateSystemDefaultDevice()` (`LUTProcessor.swift:69`; WT :179) and makes its own queue (WT: an `MTL4CommandQueue`). Inject a shared GPU context, which is GPU plan step 2 "one shared device and queue". Coordinate with ultracam-18's pipelined `LUTProcessor`.
  - Note that a Metal 4 queue plus residency sets on the processor side means the monitor's queue (classic `MTLCommandBuffer` in the `ARCHITECTURE.md` API) may differ. That is fine as long as it is the same device, but the `MonitorLUT` texture must be resident for both: on the processor side add it to the residency set (WT :243, :279-281).
- **One `MonitorFeed` per camera** (contract), plus one for "program".
  - `feed.burnInLUT` = the **same `MonitorLUT` instance** that the feed's `LUTProcessor` burns in, when `applyLUT` is on; otherwise nil.
  - `feed.monitorLUT` = the camera's monitor-only LUT.
  - **Program:** `burnInLUT = nil`. Its frames are already processed. Signal = `MonitorFrame.signal(of:range:)` (display Rec.709).
- **Camera surfaces read the source capture frame only.**
  - They wrap it with `MonitorFrame.wrap(_:cache:signal:)` (borrowed v210 `rgba32Uint` view, no copy) and the feed's declared signal (§3.5).
  - The **output stage is computed in-shader** from the same `MonitorLUT` and `mk_applyLUT` (`MKMonitor.msl:68-74`).
  - **Semantic change:** the monitor's "output" is source resolution + LUT, not the published 1080p/4:2:0 pixels.
  - So `MonitorCaptureSink.needsOutput` (120-129), the paired offer (`CaptureController.swift:980-986`) and `MonitorCorrespondence` all go away.
  - **Residual differences:**
    - Decode is algebraically equal but uses different float ops: `LUTShaders.metal:27-31` vs `MKDecode.msl:76-81`.
    - Lanczos and 8-bit encode are not shown.
    - Bit-identical output-stage tools would need `LUTProcessor` to call `mk_decodeRGB`, which the plan keeps out of scope.
- **One `MonitorPass` per surface** (contract). It draws into a `CAMetalLayer` drawable, or uses `MonitorKitUI.MonitorMetalView` (contract).
- **Shared analysis.** Once per frame per feed, `feed.analyze(frame, focus:, into: cb)` runs if any visible surface of that feed shows peaking. Scopes accumulate once per frame per feed, at the user's rate.
  - Each `MonitorMetalView` owning its own command buffer would make shared analysis need cross-view coordination.
  - **Recommended:**
    - Use one app-owned render loop per display: a `CAMetalDisplayLink` on the window's screen.
    - It draws every visible surface on that screen in **one command buffer per vsync**: wrap the latest frame of each feed, analyse it once, then encode each surface's pass, present and commit.
    - Use `MonitorMetalView` only where a surface stands alone, for example a detached window on another screen, if its API allows sharing a feed.
- **Ingest.**
  - `FeedMonitor.publish` stores the source `CVPixelBuffer` in a lock-protected **latest-frame slot** (`Synchronization.Mutex`, macOS 15+).
  - The render loop reads the slot at vsync. This is display sampling, not a drop rule. Nothing runs on the capture queue except the store.
  - The slot retains one capture buffer per feed, plus those in flight. Check the DeckLink SDK 16 input pool size (GPU plan §Root cause).
- **Freeze.** "An explicit snapshot into owned textures" (plan line 176). The API is not specified yet. Until it is, freeze keeps the last `MonitorFrame`'s pixel buffer alive and re-draws it.
- **Clean View.** It stays ephemeral (`UICleanViewState`, `UIAppProviders.swift:24-30`). The surface sets `state.clean = true` at encode time; it is not persisted.
- **Retire:** `MonitorRuntime`, ledger, fairness, tiers, composite pool, `CleanPreviewService`, critical-pipeline producer, the scope-Hz cap, presentation admission, and the per-surface `AVSampleBufferDisplayLayer` (GPU plan §3 retire list).

### 3.3 New app types

All are new files in `Sources/App` unless noted.

| New | Replaces | Owns / does |
| --- | --- | --- |
| `FeedMonitor` (`@unchecked Sendable`, render-thread confined except `publish`) | `MonitorCaptureSink` | `MonitorFeed` (contract); a `CVMetalTextureCache` on the shared device; the latest-frame slot; the `SignalDescription`; pending burn-in and monitor `MonitorLUT`s; `analyzedSequence`. `publish(source:pts:sequence:)` (capture queue), `setBurnInLUT`, `setMonitorLUT`, `setSignal` (main), `clear()` |
| `MonitorSurface` (`ObservableObject`, main actor for UI state) | `MonitorSurfacePresenter` | `MonitorPass` (contract); `CAMetalLayer`; `MonitorState` (from the coordinator) plus ephemeral clean, freeze and magnification; `status` (`MonitorStatus`, contract) for SwiftUI |
| `MonitorRenderLoop` | `MonitorRuntime` worker + presenters | A `CAMetalDisplayLink` per screen. Per vsync: one command buffer, then wrap, analyse once per feed, scopes at their rate, `pass.encode` per surface, `present`, `commit`. GPU time goes into `AppGPUActivity` |
| `MonitorCoordinator` (rewritten) | itself | `MonitorEngine`; feeds and surfaces keyed by `MonitorTargetID`; `state(for:)` / `setState(_:for:)`; `copySettings` (keep the calibration-preserving rule at 84-99, with signal settings now per feed); targets, workspace, demand, preview enable (unchanged semantics); Program publish from `offerProgram` |
| `Sources/Shared/MonitorWorkspace.swift` | MonitorToolsCore `MonitorTargetID`, `MonitorWorkspaceLayout`, `MonitorWorkspaceState` (`MonitorConfiguration.swift:3-8, 248-294`), MonitorToolsUI `MonitorTargetOption` | The same declarations and Codable keys, so the saved `tileBindings` JSON stays compatible. It goes in `Shared` because `FeedRuntime.swift:266-267` needs it. The camera extension does not compile `FeedRuntime`, so it is unaffected |

Threading:
- `MonitorFeed` and `MonitorPass` are "confined: one thread at a time" (`ARCHITECTURE.md`).
- But they are declared `@unchecked Sendable` (`MonitorFeed.swift:8`, `MonitorPass.swift:10`), so **the compiler will not stop cross-queue use**. The confinement rule is the app's to enforce: keep them inside the render-loop owner and never touch them from the capture queue.
- The WT `LUTProcessor` is now `@unchecked Sendable` with its own `feedbackQueue` (WT :30, :181). It is the first app object that could own the shared GPU context (device + queues) recommended in §3.2.
- LUT changes flow main → slot → render thread. The render thread applies `feed.burnInLUT = …` at the start of its next frame.

### 3.4 LUT routing: burn-in vs monitor-only

**Model.** This keeps every existing test and `PipelineConfiguration` meaning.
- `FeedDescriptor.lutBookmark` and `.applyLUT` stay as the **burn-in LUT**. It reaches `LUTProcessor` (real output: the virtual camera and Program) **and** every preview of that feed (`feed.burnInLUT`).
- **New** `FeedDescriptor.monitorLUTBookmark: Data?` and `monitorLUTEnabled: Bool`: the **monitor-only LUT**. It never reaches `LUTProcessor`. It is stacked after burn-in in the shader (`MKMonitor.msl:73`).
- `MonitorState.monitorLUT` (`MonitorState.swift:363`): per-surface "apply this feed's monitor LUT".
- **New** `FeedDescriptor.lutInterpolation: LUTInterpolation`. The default is `.trilinear`, which keeps today's output. Offer tetrahedral as an option. Changing the default is a product decision.
- Monitoring overlays never reach output in either mode. They exist only in the monitor pass, and `LUTProcessor` has no overlay code.

**Ownership.**
- On load or restore, `LUTFileLoader` returns a `CubeLUT`. The main actor builds **one** `MonitorLUT(device: shared, cube:, interpolation:)`. A 65³ texture is about 4.4 MB with one `replace`.
- The same instance goes to `CaptureController.load(lut)` (burn-in) and `FeedMonitor.setBurnInLUT(lut)`, or to `setMonitorLUT(lut)` for the monitor-only slot.
- The headless restore (`AppModel.swift:932-969`) must also load the monitor LUT when only `monitorLUTEnabled` is set. Today it bails unless `descriptor.applyLUT` (948, 959).

**UI.**
- Inspector `lutSection` (`UIInspector.swift:147-178`):
  - Add "Apply to: Output and previews / Monitor only".
  - Switching moves the file between the burn-in and monitor slots.
  - Add an optional second row, "Monitor LUT", for stacking.
- Effect chip 0 (`UIPresentation.swift:561-566`) stays "burn in". When the LUT is monitor-only, it is disabled with help text: "This LUT is monitor-only."
- Per surface: a "Monitor LUT" toggle in `UIMonitorToolSettingsView`, and optionally a `UIMonitorTool` case.
- Help text to update: `UIHelp.swift:49`, the recording footnotes (`UICameraColumn.swift:650, 777`, `UISettings.swift:192`, `UIHelp.swift:9`) and the input gamut help (`UIInspector.swift:176`).

### 3.5 Migration: `MonitorConfiguration` → `MonitorState`

**Data-loss trap.**
- Both schemas use `schemaVersion = 1`, and `MonitorState.init(from:)` **never throws** (`MonitorState.swift:373-387`).
- Decoding old `monitorConfiguration` JSON as `MonitorState` silently yields all defaults.
- So:
  - Keep an app-private `LegacyMonitorConfiguration`, a verbatim copy of `MonitorConfiguration.swift:30-247` including `normalized()`.
  - Decode it from the **old** key.
  - Write the result to a **new** key: `FeedDescriptor.monitorState` and `AppSettingsSnapshot.programMonitorState`.
  - Prefer the new key when present.
- **Do not bump `FeedDescriptor.version`.** `validated()` rejects any feed whose `version != 1` (`AppSettingsStore.swift:356`). A rejected snapshot falls back to the v1 legacy path (421-427) and loses all feeds.
- Add keys with `decodeIfPresent`, as the file already does.

Field by field:

| Old (`MonitorConfiguration`) | New | Note |
| --- | --- | --- |
| `toolsEnabled == false` | every tool `enabled = false` / `falseColor.mode = .off`; sub-values kept | Matches `UIMonitorBridge.toggled` (`UISupport.swift:126-133`). `clean` stays false |
| `guides.enabled, thirds, centerCross, opacity, contrast` | `guides.` same names | |
| `guides.safeArea: Bool` | `guides.safeAreas = safeArea ? [90] : []` | Old overlay inset is 5% per side (`MonitorToolsToolbar.swift:266-267`) |
| `zebra.enabled` | `zebras[0].enabled` | Old rule: false color **suppressed** zebra (`effectiveZebraEnabled`, `MonitorConfiguration.swift:144-146`). `mk_picture` draws both (`MKMonitor.msl:292-311`). Keep mutual exclusion in the app UI, or accept the change (decision) |
| `zebra.thresholdIRE` | `zebras[0].level` | Same clamp −20…120 |
| `zebra.widthIRE` (full width) | `zebras[0].range = widthIRE / 2` (half width) | Old band: `±width*.5` (`MonitorTools.metal.txt:181`); new: `level ± range` |
| `zebra.mode .aboveThreshold / .band` | `.lowerLimit / .band` | |
| `zebra.opacity` | `zebras[0].opacity` | |
| `pictureStage .source / .processedOutput` | `zebras[0].stage` = `.source / .output`; `falseColor.stage` likewise | **No picture-stage field.** `mk_picture` always shows `s.monitor` (`MKMonitor.msl:294`). The UICameraColumn Source/Output menu (262-285) either goes or needs `MonitorState.pictureStage: SignalStage` from the MonitorKit owner. Not invented here |
| `falseColor.mode .off / .sonySLog3 / .elZone` | same cases | |
| `falseColor.mode .arri` + profile `SonyARRIStyleFalseColor.profileID` | `.sonySLog3` | Old `normalized()` already migrates this (`MonitorConfiguration.swift:203-209`). `.arriStyleSLog3` exists if the product wants it back |
| `falseColor.mode .arri` + `ARRIFalseColorProfile` (LogC3/LogC4) | `.arriLogC` + feed signal `.log(LogEncoding(profileID:))` | |
| `falseColor.profileID`, `specificationVersion` | dropped | Derived from the mode |
| `falseColor.exposureIndex` | dropped | Old code allowed only 800 for ARRI (239-241) |
| `falseColor.referenceOffsetStops` (−10…10) | `referenceOffsetStops` clamped to **−6…6** | Also change the stepper range at `UIMonitorTools.swift:260` |
| `focus.enabled, color, sensitivity, noiseRejection, opacity` | `focus.` same; `style = .coloredEdges` | Same raw colour values; same `edgeThreshold` formula (`MonitorState.swift:190` vs `MonitorRuntime.swift:1047`) |
| `scopes.mode .rgbParade / .lumaWaveform`, `scopeStage` | `ScopeSettings(kind: .waveform, stage:)` with `waveformMode = .rgbParade / .luma` (`ScopeSettings.swift:144-170`) | `.processedOutput` becomes `.output` |
| `scopes.gain`, `scopes.graticule` | `ScopeSettings.display.gain`, `.display.showsGraticule` (`ScopeSettings.swift:91-107`) | |
| `scopes.enabled`, `scopes.refreshHz` | **no field**: the host picks the scope rate | Keep app-side, next to `monitorState` (for example `scopesEnabled` and `scopeRefreshHz`). `MonitorState` has no scope member; persist `ScopeSettings` beside it |
| `sourceProfileID` | **per-feed** `SignalDescription.encoding = .log(LogEncoding(profileID:transport:))` (`Signal.swift:128-138`) | New `FeedDescriptor` field (for example `monitorSignal`). If nil, derive from `gamut` as `UIMonitorBridge.sourceProfile(forGamut:)` does (`UISupport.swift:116-120`) |
| `sourceCodeRange` | `SignalDescription.range` override | nil = from the pixel format (`MonitorFrame.layout(for:)`) |
| `sourceLogMapping .native10Bit / .fullRescaledToLegal10Bit` | `LogTransport.native / .fullRescaledToLegal` | |
| — | new defaults: `zebras[1]` off, `geometry`, `display`, `monitorLUT = true`, `falseColor.customBands = []` | |
| Program (`programMonitorConfiguration`) | `programMonitorState` | Old code forced output stages (`MonitorCaptureSink.swift:64-67`). The Program feed has no burn-in, so `.source == .output` |

- Downgrade: an older build ignores the new keys and shows monitor tools off. Writing the old key as well needs a reverse map; it isn't worth it.
- Test migration on the **Debug** build's preferences only (§5).

### 3.6 App-owned types stranded by deleting MonitorTools

None of these has a MonitorKit replacement:
- `MonitorTargetID`
- `MonitorWorkspaceLayout`
- `MonitorWorkspaceState` (with `normalizedSplitRatio`)
- `MonitorTargetOption`
- `MonitorCorrespondence` (deleted, not moved)
- `MonitorDiagnostics` (replaced by new diagnostics)

Move the first four as described in §3.3. Users: `AppModel`, `FeedRuntime`, `MonitorCoordinator`, `UISupport`, `UISessionBridge`, `UIDiagnostics`, `UIAppProviders`, `MonitorWorkspaceView`, `Tools/MonitorAppIntegration/main.swift:19-39, 86`, `Tests/MonitorCoordinatorChecks`, `Tests/MonitorLifecycleChecks`.

### 3.7 Old tests: delete or retarget

This follows the GPU plan's "Tests that encode the old behavior" (lines 93-97).

**App tests**

| Test | Action |
| --- | --- |
| `MonitorCoordinatorChecks.testPausedDiagnosticsAndLayoutCapsFollowCurrentState` (63-102: 30/60 Hz caps, `requestedPictureHz`) | **Delete** (GPU plan: "MonitorCoordinatorChecks (30/60 Hz caps)") |
| `…testFreezingTheOnlySurfacePreservesDemandUntilHideOrClose` (20), `testWindowVisibilityFreezeAndPreviewHideHaveIndependentDemand` (104), `testRebindingSurfaceReleasesOldSinkAndIgnoresOldTeardown` (127), `testNativeToolsAndHiddenPreviewTransitionsPreserveIndependentDemand` (143), `testUnavailableTargetCannotReactivateMonitorConsumers` (178), `testRemovedAndDisabledTargetsReleaseOutputConsumersImmediately` (189), `testLocalScopeVisibilityUnionsDemandWithoutChangingFeedSettings` (208) | **Retarget** to the rewritten coordinator. The demand semantics remain |
| `…testExplicitlyEmptyWorkspaceIsNotRepopulatedByPreferenceUpdates` (240) | Keep (workspace logic unchanged); retype |
| `…testCopySettingsPreservesDestinationCameraCalibration` (254), `testCopyFalseColorModeUsesItsProfileWhilePreservingDestinationCalibration` (280) | Retarget: calibration is now the per-feed signal; there is no exposure index |
| `…testNativePreviewRejectsLateFramesAfterSourceRebinding` (311) | Keep while `VideoPreview` lives; delete with it (step 9 in §6.3) |
| `…testProgramMonitoringPreservesProcessingRevisionAndSelectedPixels` (335) | Retarget: Program frames reach the program feed with `burnInLUT == nil`; drop `processingRevision` |
| `MonitorLifecycleChecks.testLegacySnapshotsDefaultMonitoringOff` (6-12), `testIndependentFeedProgramAndWorkspaceRoundTrip` (14-35) | Retarget to `monitorState`. **Add** a legacy-JSON migration test covering every row of §3.5 |
| `CaptureRecordingIsolationChecks.testProductionMonitorTapsPreserveRecordingAndRejectRetiredDemand` (132) | Retarget: `FeedMonitor.publish` never blocks capture or recording |
| `…testCriticalOutputPressureKeepsCleanPreviewCameraAndRecordingAlive` (242), `testHiddenProducerInvalidationClearsItsLatestHealthEpoch` (342), `testNeedsOutputTreatsABusyLockAsWanted` (883) | **Delete** (mechanism gone) |
| `…testActualDownscaleKeepsSourceFocusAlignedAcrossAsymmetricAperture` (435) | Delete as an app test. The monitor reads the source only; aperture handling belongs in a MonitorKit pixel test |
| `…testPacedProcessedCameraAndRecordingWithMonitorGPUEnabled` (524) | Retarget to the render loop |
| Capture tests asserting admission and pool drops | GPU plan step 4, not this integration |

**Package tests**

`Packages/MonitorTools/Tests` goes with the package.

**Working tree (WT):** ultracam-18 has already deleted these files. They are still in git at `7a09c71`, so port them from there:
- `MonitorAdaptivePolicyTests`, `MonitorCriticalPipelinePolicyTests`, `MonitorCompositePoolTests`, `RuntimeResourceReuseTests`, `OwnedMetalInputTests`, `TiledMonitorKernelTests`
- **and the pixel-correctness files** `ELZoneMetalTests`, `SonyARRIStyleMetalTests`, `MonitorSamplingTests`, `SourcePictureGeometryTests`, `ProcessedFalseColorGeometryTests`, `SourceInterpretationGuardTests` and `MonitorMetalTests`.

`MonitorQualityTests` is modified, not deleted. The GPU plan (line 96) says to **keep** the pixel tests with a retargeted harness. Confirm with that session that the pixel coverage was moved, not dropped.

Port these to MonitorKit:
- **Pixel correctness (retarget the harness to `MonitorPass`):**
  - `MonitorQualityTests` (9), `ELZoneMetalTests` (2), `SonyARRIStyleMetalTests` (6), `ProcessedFalseColorGeometryTests` (1), `SourcePictureGeometryTests` (3), `MonitorSamplingTests` (2), `SourceInterpretationGuardTests` (2).
  - The `MonitorMetalTests` cases at 203, 241, 300, 420, 469, 510, 541, 642, 677, 726, 797 and 877: zebra and scope, ARRI source-before-LUT, source focus, scope RGB order, centred zebra band, HDR not retagged, ARRI rescaled table, aperture sign, graticule toggle, malformed planar height, ARRI 10-bit boundaries, declared log code view.
  - `MonitorCoreTests` settings and geometry cases (79-289), against `MonitorState`/`MonitorLayout`.
  - `SonyFalseColorUITests` (legend), against MonitorKitUI.
  - Core `ColorAnalysisTests`, `ELZoneProfileTests` and `SonyFalseColorTests` are **already ported** (`Packages/MonitorKit/Tests/MonitorKitCoreTests`).
- **Delete:**
  - `MonitorAdaptivePolicyTests`, `MonitorCriticalPipelinePolicyTests`, `MonitorCompositePoolTests`, `RuntimeResourceReuseTests`, `OwnedMetalInputTests`, `TiledMonitorKernelTests`.
  - The `MonitorCoreTests` ledger, lease and revision cases (6-78, 238, 290-405).
  - The `MonitorMetalTests` skip, budget, fairness, retry and deadline cases (28-200, 283, 345, 372, 389, 591, 756, 766, 925, 968, 1056-1801).
  - `MonitorToolsUITests` presenter and admission cases.
  - `Metal4SpikeTests.swift` (ultracam-18's spike; ask before deleting).

---

## 4. Build system

### 4.1 Xcode project

- **Today:** `generate_project.py:87-89` declares `XCLocalSwiftPackageReference(relativePath="Packages/MonitorTools")` and three `XCSwiftPackageProductDependency`s.
  - They are linked into the **app target only**: the frameworks phase at :95 and `packageProductDependencies` at :114.
  - The project's `packageReferences` is at :125.
  - The camera extension has none (pbxproj :664 `()`). `validate_bundle.py:63` enforces that.
- **Change:**
  - `relativePath="Packages/MonitorKit"`.
  - Products: `("MonitorKitCore", "MonitorKit", "MonitorKitScopes", "MonitorKitUI")`, plus `"MonitorKitAudio"` only if the meters are used.
  - Then let `build.sh:51` regenerate the pbxproj.
  - During the transition both package references can coexist: different module names, different MSL prefixes (`mk_` vs the old names), separate resource bundles. **No single Swift file may import both.** These names exist in both modules and would be ambiguous: `MonitorRect`, `ELZoneProfile`, `ELZonePublicReference`, `ELZoneReferenceStatus`, `SonySLog3FalseColor`, `SonyFalseColorCategory`, `SonyFalseColorZone`, `SonyARRIStyleFalseColor`, `ARRIFalseColorProfile`/`Zone`/`Category`, `NativeLogCodeMapping`.
- **Resources:**
  - Local package resources are copied by Xcode into `Ultracam.app/Contents/Resources/MonitorKit_MonitorKit.bundle`.
  - Verified with a SwiftPM build: the bundle contains `Contents/Resources/Shaders/{MKDecode,MKLUT,MKMonitor}.msl`.
  - `MonitorShaders.source` reads `Bundle.module`, subdirectory `Shaders` (`MonitorShaders.swift:20-21`).
  - `LUTShaders.metal` stays a copied app resource (`generate_project.py:108-109`).
- **App-side collision:** only `CubeLUT` (§2.6). A scan of every public MonitorKit type against app declarations found nothing else (`Segment` in `Tests/RecordingChecks.swift:12` is nested).

### 4.2 Script builds (`swiftc` direct link)

- **Verified:** with this toolchain, `swift build --product MonitorKitCore` and `--product MonitorKit` emit `libMonitorKitCore.a` / `libMonitorKit.a` plus `MonitorKit_MonitorKit.bundle` at `--show-bin-path`, even though the products are automatic type.
  - So `type: .static` is **not** required for the script pattern.
  - The library plan (line 117) does say "All products are static libraries". The MonitorKit owner may still add it for clarity.
- **Replace `scripts/monitor-tools-package.sh`** (or add `monitor-kit-package.sh` and switch callers one at a time):
  - `monitor_package="$task_root/Packages/MonitorKit"`.
  - The product loop (:14): `MonitorKitCore MonitorKit MonitorKitScopes MonitorKitUI`.
  - Link args (:21-23): `-lMonitorKitUI -lMonitorKitScopes -lMonitorKit -lMonitorKitCore` (+ `-lMonitorKitAudio -framework Accelerate` if Audio is used) `-framework Metal -framework QuartzCore -framework CoreVideo -framework SwiftUI`.
  - The bundle check (:28): `*MonitorKit_MonitorKit.bundle`.
  - Use a shared scratch under `/Volumes/8TB/…/monitor-package-cache`, like today. Don't share the W1 workflow's scratch.
- **Callers:** `test.sh:21-27` (also `swift test` of the package), `ui-typecheck.sh:16`, `ui-verify.sh:33`, `monitor-app-integration.sh:19`, `camera-smoke.sh:29`, `monitor-tools-recording.sh:21`, `monitor-tools-smoke.sh:13`.
- **`LUTProcessor` now needs MonitorKit at runtime.** That affects `camera-smoke.sh:39` and `monitor-tools-recording.sh:25`; both already link the monitor package. It also affects `test.sh:58`, and `ULTRACAM_SHADER` (`test.sh:36`, `ui-verify.sh:32`, `monitor-app-integration.sh:18`) keeps pointing at `LUTShaders.metal`, which `LUTProcessor` now prepends `MKLUT.msl` to.

### 4.3 Deployment target 15.0 → 26.0: every place it is set

| Place | Value now | Note |
| --- | --- | --- |
| `scripts/generate_project.py:84` (project-level `MACOSX_DEPLOYMENT_TARGET`) | 26.0 (uncommitted) | **Source of truth** for both targets |
| `Ultracam.xcodeproj/project.pbxproj:516, 535` | 15.0 (stale) | Regenerated by `build.sh:51` |
| `Config/App-Info.plist:10`, `Config/Camera-Info.plist:10` (`LSMinimumSystemVersion = $(MACOSX_DEPLOYMENT_TARGET)`) | follows | **The camera extension's minimum OS changes too.** The rebuilt extension needs a version bump so macOS replaces the installed one (see commits `0ccf83c`, `52d21ab`) |
| `scripts/build.sh:38` (exported for the Rust `auto_switcher` static lib) | 26.0 (uncommitted) | The comment at :37 still says "macOS 15" |
| `scripts/test.sh:15, 52` | 26.0 (uncommitted) | `:15` also governs `cargo` and `clang++` (`:32, :43, :48`) |
| `scripts/ui-verify.sh:31, 58`; `ui-typecheck.sh:15, 21`; `camera-smoke.sh:27, 32`; `monitor-app-integration.sh:17, 45`; `monitor-tools-admission-checks.sh:8, 13`; `monitor-tools-benchmark.sh:11, 52`; `monitor-tools-recording.sh:14, 22`; `monitor-tools-smoke.sh:8, 15` | 26.0 (uncommitted) | |
| `scripts/recording-recovery-smoke.sh:14` | `-target …macos26.0` only, no export | Add `export MACOSX_DEPLOYMENT_TARGET=26.0` for consistency |
| `Packages/MonitorTools/Package.swift:6` | `.macOS("26.0")` (uncommitted) | Goes with the package |
| `Packages/MonitorKit/Package.swift:8` | `.macOS(.v26), .iOS(.v26)` | Requires an app target ≥ 26 |

**Availability checks and APIs:**
- `Sources/App/UIToolbar.swift:35, 72`: `if #available(macOS 26.0, *) { ToolbarSpacer(…) }` is now always true; remove the conditional.
  - Checked with `swiftc -typecheck -warnings-as-errors -target arm64-apple-macos26.0` on an equivalent snippet: no warning. This is cleanup, not a build break.
- `MonitorShaders.swift:34`: `#available(macOS 27.0, …)` (MSL 4.1) stays meaningful.
- There are no other `@available`/`#available` in `Sources/`.
- **Deprecations:** raising the target makes APIs deprecated in macOS 15.x–26 warn. Both Swift (`SWIFT_TREAT_WARNINGS_AS_ERRORS`, `-warnings-as-errors`) and the ObjC++ backend (`test.sh:43` `-Werror`) turn warnings into errors.
  - The scripts already target 26.0 in the working tree, but it is not known whether they have been run since.
  - Run `ui-typecheck.sh` and `test.sh` (§5) before anything else.
- **Newly usable APIs:** `Synchronization.Mutex` (15+), `CAMetalDisplayLink` (14+), and the Metal 4 / MSL 4.0 runtime compile used by MonitorKit.

### 4.4 Swift 5 app vs Swift 6 package

- App settings: Swift 5 mode, `SWIFT_STRICT_CONCURRENCY=complete`, warnings as errors (`generate_project.py:84`). The scripts use `-swift-version 5 -strict-concurrency=complete -warnings-as-errors`.
- MonitorKit settings: tools 6.2, `swiftLanguageModes: [.v6]` and `.treatAllWarnings(as: .error)` (`Package.swift:4`).
- **Importing Swift 6 modules from Swift 5 mode is supported.**
- **Concurrency:** MonitorKit's `Sendable` and isolation annotations are enforced in the app under complete checking.
  - `MonitorEngine` and `MonitorLUT` are `@unchecked Sendable`, and `MonitorFrame` is `@unchecked Sendable`, so they can cross queues.
  - Feeds and passes are confined, which forces the ownership rule in §3.3.
  - MonitorKitUI views and controls are main-actor; the app's SwiftUI code is too.
- **Warnings as errors inside the package:** when Xcode builds the local package with the app, a new compiler warning in MonitorKit breaks the **app** build. Pin the toolchain, or ask the owner to gate the setting for CI only.
- **`@_exported import MonitorKitCore`** (`MonitorKit.swift:1`): `import MonitorKit` brings every Core name into each importing file. That is fine once `Sources/Shared/CubeLUT.swift` is gone. Every file that uses a MonitorKit type needs its own import (Swift imports are per file).

---

## 5. Test and verification commands: what is safe to run

Common rules:
- Every script needs `/Volumes/8TB` mounted (each checks).
- **Never** quit `/Applications/Ultracam.app`; it may be serving a meeting.
- **Never** run anything with `LIVE=1`.
- **Never** run `defaults` against `org.ultracam.app`. It resolves to the installed app's sandbox container.
- The Debug build uses `~/Library/Preferences/org.ultracam.app.plist`. Back it up by explicit path (`defaults export "$HOME/Library/Preferences/org.ultracam.app" <backup>.plist`) before the first launch that runs the §3.5 migration.

| Command | What it does | Safe without asking? |
| --- | --- | --- |
| `scripts/ui-typecheck.sh` | `swiftc -typecheck` of all Shared, Recording and App sources against the package | **Yes.** The fastest compile gate |
| `scripts/test.sh` | Builds the package and `swift test` (`:24-27`), the Rust lib and the DeckLink backend in `ULTRACAM_BACKEND_TESTING` mode; links the app subset + `Tests/*` into `lut-tests` and runs it | **Yes.** Synthetic frames only. Defaults are throwaway suites or the test binary's own domain (`VirtualCameraRegistryChecks.swift:115` uses `.standard` of `lut-tests`, not the app's) |
| `scripts/ui-verify.sh` (`FORCE=1`, `STRICT=0`) | Offscreen render of every screen; real `AppModel` through `UISessionBridge` with a throwaway suite (`Tools/UIVerify/main.swift:342-344`) | **Yes.** It caches on an input hash; fix that hash for MonitorKit (§1.2) |
| `scripts/monitor-app-integration.sh` | Real `AppModel` + `MonitorCoordinatorChecks`, a capturing registry publisher, no CMIO (`Tools/MonitorAppIntegration/main.swift:6-11`) | **Yes** |
| `xcrun swift test --package-path Packages/MonitorKit --scratch-path <external scratch>` | MonitorKit's own tests; GPU tests `XCTSkip` without Metal | **Yes.** Use a scratch path different from the W1 workflow's |
| `scripts/recording-recovery-smoke.sh`, `monitor-tools-{smoke,recording,benchmark,admission-checks,stress}.sh` | Synthetic media and old harnesses | Yes, but the `monitor-tools-*` harnesses retire |
| `scripts/camera-smoke.sh` (no arguments) | Build only (`:1-8`: "never installs or activates extensions") | **Yes** |
| `scripts/camera-smoke.sh --run / --full / --consumer / --registry-check / --monitor / --monitor-full` | Uses the installed camera extension. `--consumer` may make the running host start physical capture | **No. Ask the user** |
| `scripts/build.sh --debug` | Regenerates the project (`:51`) and builds the Debug app into `agent-work/ultracam/Ultracam.app`; no install | **Yes** for the live app. But it **rewrites `project.pbxproj`**, which another session has uncommitted edits in; coordinate first |
| `scripts/build.sh --signed` | Repoints the `agent-work/ultracam/Ultracam.app` symlink at the sandboxed Release build | Only last; rebuild `--debug` before any tour or self-test (memory note) |
| `scripts/app-self-test.sh` (`SKIP_BUILD=1`) | Launches a **second**, Debug Ultracam with `--ui-self-test`; never starts cameras; windows flash on screen | Yes, without `LIVE=1`. It uses the Debug preferences: back them up first |
| `scripts/ui-tour.sh` | Drives the Debug build by its own PID; saves and restores its preferences; refuses a sandboxed build | Yes, without `LIVE=1` |
| Anything with `LIVE=1`, an installer action, or quitting the installed app | Real UltraStudio or extension changes | **No** |

Checkpoint gates in §6 use: **T** = `ui-typecheck.sh`, **U** = `test.sh`, **V** = `ui-verify.sh`, **I** = `monitor-app-integration.sh`, **K** = MonitorKit `swift test`, **B** = `build.sh --debug` + `validate_bundle.py` (run by `build.sh:71`), **S** = `app-self-test.sh` (non-live).

---

## 6. Risks and the ordered plan

### 6.1 Concurrent work

| Who | Files | Rule |
| --- | --- | --- |
| Session **ultracam-18**: GPU monitor in MonitorTools, pipelined `LUTProcessor`, Program, Recording, SDK 16 (`PROGRESS.md` W4 gate) | **Actively changing now (§0):** `LUTProcessor.swift`, `LUTShaders.metal`, `VideoContract.swift`, the DeckLink backend, `Sources/Recording/*`, `ProgramTimestampMapper`, `SwitcherCoordinator`, `Packages/MonitorTools/**` (+ untracked `Metal4SpikeTests.swift`). Expected next: `CaptureController.swift`, `MonitorCaptureSink.swift`, `MonitorCoordinator.swift`, `VideoPreview.swift` (`previewPendingLimit` is gone) | **Do not start W4 until it commits.** Then re-baseline this map. Its fused Metal 4 LUT (§2.3a) leaves only the §2.4 delta. Its "GPU monitor in MonitorTools" overlaps §3 entirely: reuse its `CAMetalLayer`/display-link plumbing rather than rebuilding it |
| W1 workflow (`wf_548da617-dbb`) | `Packages/MonitorKit/**` | App-side code imports only public symbols; raise API gaps (below) with its owner |
| Grok (GPU plan line 118) | Monitor sink, coordinator, diagnostics, `FULL_AUDIT.md` (uncapped monitor rate) | Merge, don't overwrite |
| Unknown owner | Uncommitted 26.0 script edits, the stale pbxproj with absolute `DECKLINK_SDK_DIR`/`LIBRARY_SEARCH_PATHS` | Confirm who commits them. Don't commit the machine-absolute pbxproj paths unintentionally |

### 6.2 Technical risks

1. **The MonitorTools pixel-correctness tests are deleted in the working tree.** These seven files are gone: `ELZoneMetalTests`, `SonyARRIStyleMetalTests`, `MonitorSamplingTests`, `SourcePictureGeometryTests`, `ProcessedFalseColorGeometryTests`, `SourceInterpretationGuardTests` and `MonitorMetalTests` (§3.7).
   - The GPU plan (line 96) says to keep them with a retargeted harness.
   - They survive only in git at `7a09c71`.
   - MonitorKit has no GPU pixel tests yet.
   - **Confirm with ultracam-18 before it commits, and port them into MonitorKit's GPU tests from `7a09c71`.** Otherwise the false color, EL Zone, ARRI boundary and geometry qualification has no coverage.
2. **The MonitorKit monitor API is new and unaudited** (§0, dated). `MonitorKitUI` is still a stub.
3. **API gaps to raise with the MonitorKit owner:**
   - picture stage (§3.5)
   - `ScopeSettings` persistence shape
   - the freeze API
   - clean-aperture handling (old `MonitorGeometry.cleanAperture`)
   - whether `MonitorMetalView` can share a feed's analysis
   - `MonitorFrame.wrap` allocating a `[AnyObject]` per call (`MonitorFrame.swift:237`) against contract rule 5. The host should cache `MonitorFrame`s per IOSurface ID, as GPU plan step 1 suggests.
4. **Settings data loss:** the same `schemaVersion` with non-throwing decode, and the `FeedDescriptor.version` guard (§3.5). Shipping the Release build migrates the user's real container, with no downgrade path for monitor settings.
5. **Preview ≠ output at the ULP level:** fast vs safe math (§2.5) and the decode algebra (§3.2). The resize and encode stages are not visible in previews.
6. **Capture-buffer retention:** the latest-frame slot plus frames in flight hold DeckLink buffers (§3.2).
7. **Behaviour changes** that need product sign-off:
   - zebra and false color now show together
   - the Source/Output picture menu
   - the trilinear vs tetrahedral default
   - preview "output" is source resolution
8. **Camera extension rebuilt at 26.0:** a version bump is needed for macOS to replace it; the user must install it (GPU plan line 117).
9. **`.treatAllWarnings(as: .error)`** in MonitorKit can break app builds on a toolchain change.
10. **Retiring `VideoPreview`** touches demand logic (`AppModel.swift:1050-1068`, `previewRenderer.isPresented`), the menu bar mini preview (`AppModel.swift:212-221`, `UIAppProviders.swift:13, 101`), the Diagnostics "Preview" drops, and `PreviewChecks`. Keep it until the last step.

### 6.3 Ordered plan with checkpoints

0. **Preconditions.**
   - ultracam-18 has committed.
   - MonitorKit's `MonitorLUT`, `MKLUT.msl` and `CubeLUT` are frozen (W1 audit passed).
   - Rerun the §1 greps and update the line numbers here.
   - Back up the Debug preferences.
   - Gate: **T, U** green on the new baseline at 26.0, which shows any deprecation errors.
1. **Plumbing, no behaviour change.**
   - Add the MonitorKit package reference next to MonitorTools (`generate_project.py:87-89, 95, 114, 125`) and the `monitor-kit-package.sh` link args (§4.2).
   - Make `validate_bundle.py` accept the new bundle.
   - Fix the `ui-verify.sh` hash (Packages/MonitorKit + `*.msl`).
   - No file imports both packages.
   - Gate: **T, U, V, B, K**.
2. **Swap `CubeLUT`** (§2.6): delete `Sources/Shared/CubeLUT.swift`, add the imports, fix the two script source lists. Gate: **U** (CubeTests unchanged), **T**.
3. **Fused LUT in `LUTProcessor`**, trilinear, with the compile-option decision made.
   - Most of this is already in ultracam-18's working tree (§2.3a). The remaining delta is §2.4 items 1-4.
   - Golden exact-equality test against the HEAD kernel, if that session didn't add one.
   - Gate: **U** (every test in the §2.5 table), golden equal, and GPU time per frame not worse (`CommandTiming`, `LUTProcessor.swift:22-32`).
4. **One GPU context and one `MonitorLUT` per load.**
   - The device is shared by every `LUTProcessor` (align with ultracam-18's step 2).
   - `CaptureController.load(lut)` plus the test convenience.
   - AppModel builds the LUT once (§3.4).
   - Gate: **U, T**, then a Debug build that loads, restores and forgets a LUT through bookmarks, on Debug preferences only.
5. **Settings schema.**
   - App-owned `MonitorWorkspace.swift` (§3.6).
   - `LegacyMonitorConfiguration` plus the `monitorState` and `programMonitorState` keys.
   - Per-feed signal, `monitorLUTBookmark`/`monitorLUTEnabled`/`lutInterpolation`, and `ScopeSettingsV1`.
   - The coordinator still runs on MonitorTools internally: convert at the boundary.
   - Gate: **U** (retargeted `MonitorLifecycleChecks` + the new migration test), **I, V**.
6. **Monitor runtime swap (blocked on W1/W2).**
   - Add `FeedMonitor`, `MonitorSurface`, `MonitorRenderLoop` and the rewritten `MonitorCoordinator` (§3.3).
   - `CaptureController` publishes once (`:929`); delete `:935-941`, `:973-975` and `:980-986`.
   - Delete `MonitorCaptureSink.swift`.
   - Retarget `UIAppProviders`, `MonitorWorkspaceView`, `UISupport`, `UIMonitorTools`, `UIDiagnostics` and `UICameraColumn`.
   - Program is published through the coordinator.
   - Gate: **U** (§3.7 retargets), **I, V, S**, plus counters: copies per frame = 0, presented fps = display rate, late vsyncs, GPU ms per pass ≤ the MonitorKit budget (0.5 ms per 4K→1080p pass).
7. **Routing UI** (§3.4): the inspector routing picker, the monitor-LUT slot, the per-surface toggle, help text. Gate: **V, S**, and a non-live `ui-tour.sh`.
8. **Retire MonitorTools.**
   - Remove the package reference.
   - Delete `Packages/MonitorTools`, `Tools/MonitorTools*` and `scripts/monitor-tools-*.sh` + `monitor-tools-fingerprint.py`.
   - Drop the old checks from `validate_bundle.py`.
   - Rewrite the `UISettings.swift:648` text.
   - Port the package tests listed in §3.7 into MonitorKit (owner: MonitorKit).
   - Gate: **T, U, V, I, K, B, S**.
9. **Follow-ups.**
   - Retire `VideoPreview`/`AVSampleBufferDisplayLayer` (GPU plan §3).
   - Optional tetrahedral default.
   - Bump the camera extension version for shipping.
   - **Hands-on check with the UltraStudio only with the user's explicit go-ahead** (it needs the installed app quit, or `LIVE=1`).
