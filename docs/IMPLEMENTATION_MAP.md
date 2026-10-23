# Implementation map: round-3 UI → existing code

Read-only mapping, written 2026-10-21 against the working tree on `main`. It lists every API the
new SwiftUI UI needs, what's per-feed vs selected-only today, the build and test hooks, and a gap
list.

> Note (2026-10-22): `Packages/MonitorTools` and its `MonitorToolsUI` views named below were retired in W4; the monitor now runs on MonitorKit with app-owned surfaces (see [the integration map](MONITORKIT_INTEGRATION_MAP.md)).

The target design is round 3 plus audit decisions D1–D8 (`docs/mockups/r3/audit/REPORT.md`).
Line numbers are approximate; re-check them before editing.

## 1. App structure: replace vs reuse

| File | Today | Plan |
|---|---|---|
| `Sources/App/UltracamApp.swift` | `Window("main")` → `ContentView`. `.commands` adds the Feed menu (Start/Stop ⌘↩, automatic toggle, Processing ⇧⌘B, Video preview ⇧⌘P), Hide from Dock, and a Quit override. `MenuBarExtra(.window)` hosts `MenuBarInterface`. `AppDelegate` sets the activation policy (hideFromDock) and handles `applicationShouldTerminate`, waiting for `recordingModel.stopAll`. | **Rewrite the scenes and commands.** Keep the AppDelegate quit logic. Add a `Settings` scene, a Diagnostics `Window`, and the detached-monitor `WindowGroup(for:)`. |
| `FeedInterface.swift` (789) | `ContentView`, `ControlPanel`, `FeedPreview`, `PreviewPlaceholder`, `FeedControls`, `MultiCameraControls`, `InputDeviceControl`, `FeedStateLabel`, `StartStopButton`, `AutomaticFeedControl`, `PipelineEnableControl`, `AppliedPipelineState`, `FeedMetadata`, `FeedDiagnostics`, `AudioLevelMeter`/`LevelBar` (+ `normalized`, `decibelText`), `PipelineControls`, `LUTControls`, `FeedNotice`, `CameraOutputControls`. | **Replace the views.** Reuse `FeedPreview`'s layout idea and `AudioLevelMeter`'s math (normalized and dB helpers, peak marker on RMS bar), and carry over the `.help` strings. |
| `RecordingInterface.swift` (283) | `RecordingControls`, `RecordingFeedRow`, `AppResourceSummary` (1 s sampler while visible). | **Replace the views.** Reuse the `AppResourceSummary` sampling loop and its help text. |
| `MenuBarInterface.swift` (88) | `MenuBarStatusIcon` (3 symbol states), `MenuBarInterface` (380 pt panel). | **Replace both.** |
| `MonitorWorkspaceView.swift` (410) | `MonitorWorkspaceView` → package `MonitorWorkspaceShell`. `MonitorWorkspaceTile` / `MonitorBoundTile` handle surface registration, native-vs-owned choice, freeze, clean and zoom. `MonitorDetachedWindows` (NSWindow), `MonitorWindowOwner`, `MonitorCompactPreview` (tray). | **Keep the registration logic.** Copy the `register()` / `usesNativePreview` rules exactly; they gate GPU work. Replace the chrome with the r3 overlay tile. Detached windows can stay AppKit or move to `WindowGroup(for: MonitorTargetID)`. |
| `VideoPreview.swift` | `VideoPreviewRenderer` (`bindSource`, `flush`, `isPresented`, `onVisibilityChange`). `VideoPreview` (NSViewRepresentable around an AVSampleBufferDisplayLayer). | **Reuse unchanged.** Only two native renderers exist: `previewRenderer` and `miniPreviewRenderer`. Both are bound to the selected feed (`AppModel.selectFeed`, ~431). |
| Package `MonitorToolsUI` | `MonitorNativePicture`, `MonitorNativeScope`, `MonitorSurfaceVisibility`, `MonitorSurfacePresenter`, `MonitorToolsToolbar` (tool popovers), `MonitorGuideOverlay`, `MonitorFalseColorLegend`, `MonitorScopeGraticule`, `MonitorDiagnosticsView`, `MonitorPictureZoom`, `MonitorWorkspaceShell`/`MonitorTileChrome`. | **Reuse** the picture, scope, visibility, guide overlay, legend, graticule and zoom. **Replace** `MonitorTileChrome`/`MonitorWorkspaceShell` usage with app-side r3 tiles. Optionally keep the `MonitorToolsToolbar` popover *content* behind a split-button entry; its settings bodies are complete and tested in `MonitorToolsUITests`. |

## 2. AppModel (`Sources/App/AppModel.swift`, `@MainActor @Observable`)

### Public surface

| Member | Line | Scope |
|---|---|---|
| `hideFromDock` | 21 | global |
| `devices: [InputDevice]`, `refresh()` | 28, 329 | global |
| `feedDescriptors`, `selectedFeedID`, `selectedFeedName` | 31–32, 94 | global |
| `outputMode`, `setOutputMode(_:)` (guarded by topology) | 37, 496 | global |
| `switcherSettings`, `updateSwitcher(_:)` (recreates the Rust bridge) | 45, 507 | global |
| `switcherSelectedFeedID` (on air), `switcherPendingFeedID` (pending cut), `switcherStatus` | 46–48 | Program |
| `naturalTalkingHeadEnabled`, `naturalAnchorFeedID`, `naturalEmphasisFeedID`, `naturalDirectorStatus` | 50–84 | Program |
| `canEditFeedTopology` | 87 | false while any source is active OR any recording is active |
| **`selectedDevice`, `configuration`, `gamut`, `pipelineEnabled`, `previewEnabled`, `automaticFeedEnabled`** | 98–133 | **selected feed only.** `didSet` saves and `reconfigure()`s the selected capture. |
| `cameraDemandError`, `lutTitle`, `lutFileName`, `lutError`, `lutLoaded`, `loading` | 135–142 | selected feed only |
| `running`, `previewReady`, `update: CaptureUpdate` | 140–143 | **selected feed only** |
| `installer: ExtensionInstaller` | 144 | global |
| `previewRenderer`, `miniPreviewRenderer` | 145–146 | bound to the selected feed |
| `monitorCoordinator`, `recordingModel` | 151, 160 | global |
| `chooseLUT()` | 342 | NSOpenPanel → selected feed |
| `selectFeed(_:)` | 422 | rebinds renderers, `capture`, handlers; reapplies the descriptor; restores the LUT |
| `addFeed`, `removeFeed`, `renameFeed` | 445–494 | topology-locked |
| `requestProgramCut(to:)` | 519 | sends a manual override to the director |
| `saveSettings()` | 582 | writes the *selected* descriptor from app bindings |
| `canStartFeed`, `start()`, `stop()` | 644, 648, 701 | selected feed |
| `ingestAutoSwitcherTranscript(...)` | 838 | external ASR hook (the app has no recognizer) |
| `cameraRequested`, `automaticCaptureRequested`, `automaticFeedStatus`, `retryAutomaticFeed()` | 947–981 | selected feed |
| `resetPreview()` | 1071 | flushes both renderers (the "Retry preview" action) |

### Per-feed vs selected-only (key facts)

- **Live status is selected-only.** `installCaptureUpdateHandler` (~853) installs `onUpdate` for any
  feed, but after handling `stopped` and cadence it does `guard self.selectedFeedID == feedID else
  { return }` (~881). `self.update` therefore only ever holds the selected feed's `CaptureUpdate`.
  Non-selected feeds' timecode, audio, formats, drops and messages are discarded.
- **Settings are stored per feed.** `FeedDescriptor` has `selectedDevice`, `applyLUT`, `downscale`,
  `convertTo420`, `reduceFrameRate`, `gamut`, `pipelineEnabled`, `previewEnabled`, `lutBookmark`,
  `automaticFeed`, `enabled` and `monitorConfiguration` (`AppSettingsStore.swift` ~220). But they're
  **edited only through the selected-feed bindings**: `saveSettings()` builds the descriptor from
  them.
- Non-selected feeds can be reconfigured directly with
  `feedCoordinator.reconfigureCapture(feedID:configuration:pipelineEnabled:)` (FeedRuntime ~527),
  as `restoreHeadlessLUT` does (~893), but nothing public in AppModel exposes it.
- **LUT:**
  - The selected feed loads via `chooseLUT` / `restoreLUT` → `capture.load`.
  - Headless feeds start with `applyLUT=false`, then `restoreHeadlessLUT` loads their saved bookmark
    asynchronously.
  - There is no UI path to choose a LUT for a non-selected feed without selecting it.
- **Start:**
  - **Separate mode:** starts only the selected feed (`startFeed` ~654).
  - **Program mode:** starts the selected feed plus every enabled, device-assigned, not manually
    stopped descriptor, headless with `previewEnabled:false` (~656–684).
  - **Automatic policy:** can start any feed (`reconcileAutomaticFeed` ~983).
- **Stop:** `stop()` (701) inserts the selected feed into `manuallyStoppedFeeds`, stops only the
  selected feed **and calls `recordingModel.stop(feedID:)`** (707). Program headless sources keep
  running.
- **Recording keeps capture alive.** In `reconcileAutomaticFeed` the demand includes `recording`
  (~1001), and `.stop` is skipped while recording (~1032), so a backup take keeps the feed running
  after Zoom closes.
- **Demand:**
  - **Routes:** `CameraDemandMonitor` gives a boolean per virtual-camera route (`requested == "1"`,
    CameraDemandMonitor ~181).
  - **Preview:** a visible preview or monitor surface counts as preview demand
    (`policy.previewDemand`, ~1003).
  - **Program:** demand also includes monitor demand on "program", Program route demand, or a
    running non-auto selected feed (~984).
- **Consumer count.** The extension tracks `consumers: Int` (CameraProvider ~87, 735) but publishes
  only `"1"/"0"` (~680). The app never learns how many clients there are, or which app.
- **Applying state.** `reconfigure()` (~639) sets `update.pipelineEnabledApplied = nil` and
  `output = ""`. The capture queue publishes "Updating output…" (CaptureController ~466) until the
  first new frame, and `AppliedPipelineState` compared applied vs selected.
- **Preview error:** `update.previewError` plus `resetPreview()`.
- **Installer** (`ExtensionInstaller`):
  - `status`, `pending`, `unavailableReason`, `canRequestChanges`, `install()`, `uninstall()`.
  - Status strings: "Requesting … activation…", then "Approve Ultracam in System Settings → General
    → Login Items & Extensions → Camera Extensions." (needs approval), then completion or failure.
- **Settings persistence.** `AppSettingsStore.loadSnapshot` / `saveSnapshot`. `AppSettingsSnapshot`
  (~316) holds `feeds`, `selectedFeedID`, `outputMode`, `switcher`, `programMonitorConfiguration`,
  `monitorWorkspace` and `virtualCameraRegistryVersion`. `hideFromDock` is a separate key.
- **Virtual camera registry.** `VirtualCameraRegistrySnapshot.forFeeds`
  (`VirtualCameraRegistryPublishing.swift:14`):
  - Separate mode: one camera per *enabled* feed, "Ultracam · <name>".
  - Program mode: "Ultracam · Program".
  - Published on every `saveSettings`.

### `CaptureUpdate` fields (CaptureController.swift ~7–47)

`message, input, output, inputFast, sourceDuration, mediaTime, pipelineEnabledApplied, frames,
dropped, processingMS, previewDelivered, sourceDrops, captureDrops, poolDrops, cameraDrops,
previewDrops, previewFrames, outputFPS, displayedFrames, rendererDrops, previewError, timecode,
audioChannels, audioSampleRate, audioPackets, audioSamples, audioBytes, audioDrops,
audioPeakLeft/Right, audioRMSLeft/Right, audioBitrateKbps, audioPresent, audioPacketTime,
videoBitrateMbps, videoDrops, cameraOutputActive, cameraMessage, stopped`.

Camera messages: "Virtual camera connected — choose Ultracam in Zoom" (~640), "Camera output
unavailable — …" (~642), "Camera output disconnected — …" (~962). The no-signal path publishes
"No video signal — waiting for HDMI." and fails after 2 s ("No valid video signal for two seconds.
Check the FX3 HDMI output.", ~440).

### FeedCoordinator (`Sources/Shared/FeedRuntime.swift:255`) and FeedCapturePool (CaptureController ~1100)

| API | Line | Notes |
|---|---|---|
| `descriptors`, `selectedFeedID`, `outputMode`, `switcher`, `switcherCoordinator`, `virtualCameraRegistrySnapshot` | 256–262 | |
| `programMonitorConfiguration`, `monitorWorkspace` | 264–265 | |
| `capturePool`, `programOutput: ProgramOutputRoute` | 267–268 | `programOutput.selectedFeedID` (on air), `pendingFeedID`, `pendingCutTime`, `hasPendingCut` (FeedRuntime 29–32) |
| `onProgramCutApplied` | 273 | |
| `capture(for:)`, `isFeedRunning(_:)`, `session(for:)`, `orderedSessions` | 315–327, 400 | `FeedSession.state` is `FeedSessionState` (140) |
| `select`, `update`, `add`, `remove` | 410–469 | |
| `start(_:)`, `stop(_:)`, `startCapture(...)`, `stopCapture(feedID:)`, `reconfigureCapture(...)`, `setPreviewEnabled(feedID:enabled:)` | 497–532 | **per feed already**; the building blocks for Stop All / per-camera start |
| `setCameraOutputEnabled(feedID:enabled:)`, `setProgramSourceHealth` | 387–393 | |
| `setOutputMode`, `setSwitcher`, `requestProgramCut(to:)` / `(to:noEarlierThan:)`, `cancelProgramCut`, `evaluateSwitcher(at:)` → `SwitcherEvaluation {idle, cutQueued, noHealthyFeed, dynamicAnalysisUnavailable}` | 554–615 | |
| `FeedCapturePool.controller(for:)`, `existingController(for:)`, `remove`, `stop`, `stopAll()` | ~1121–1162 | `stopAll` exists at controller level |

**Switcher.**
- Settings (`AppSettingsStore.swift` ~166): `SwitcherSettings{selectedFeedID, automatic,
  intervalSeconds, strategy, naturalTalkingHead}`.
- `NaturalTalkingHeadSettings` (~43) has all the tunables, including `mode`
  (`TalkingHeadDirectorMode`) and **`manualHold`** (~62). `manualHold` is passed to the Rust bridge
  (`AutoSwitcherBridge.swift:79`) but has no UI.
- The director is fed only the selected feed's audio (`feedAutoSwitcherAudio` ~826, max of L/R)
  and exposes only `pendingCut`. There's no planned-next camera and no hold-remaining value.
- `AutoSwitcherTimelineRecorder` writes the decision/cut/audio sidecar.

## 3. RecordingModel (`Sources/App/RecordingModel.swift:455`, `@MainActor @Observable`)

| Member | Line |
|---|---|
| `codec: RecordingCodec {proRes42210Bit, hevcMain10_422}`, `timecodeMode: {source ("Source timecode" — writes NO tc track), recordStart, wallClock ("PC time")}` with `.title`/`.help` | 8–49, 456, 474 |
| `outputFolder`, `customOutputFolder(for:)`, `outputFolder(for:)`, `setOutputFolder(_:for:)`, `onOutputFolderChanged` | 457, 556–567, 477 |
| `feeds: [RecordingFeedState{id,name,status: idle/recording/paused/finishing, error, statistics, isActive, displayStatus}]` | 92–106, 475 |
| `record(feedID:)` (throws `feedNotActive` → "Start this feed before recording it…"), `pause`, `resume`, `stop(feedID:)` (status → `.finishing`, then idle; `onRecordingFinished(feedID, url?)`) | ~612–660 |
| `recordAll()`, `pauseAll()`, `stopAll()`, `stopAll(completion:)` | ~701–720 |
| `canRecordAny`, `canPauseAny`, `canStopAny`, `hasActiveRecordings` | 569–576 |
| `interruptedRecordings: [InterruptedRecording{journalURL, temporaryURL, finalURL, title}]`, `refreshRecovery()`, `recover(_:)`, `recoveringID`, `recoveryMessage`, `recoveredURL` | 465–468, 496–551 |
| `onRecordingStarted(feedID, url)` | 478 |

**`RecordingStatistics`** (`Sources/Recording/RecordingStatistics.swift` ~26): `elapsed, fileBytes,
encodedFrames, droppedVideoFrames, droppedAudioPackets, encoderErrors, writerErrors, queueSamples,
queueCapacity, encoderPendingFrames, framesPerSecond, videoMegabitsPerSecond, encoderLatencyMS,
maxEncoderLatencyMS, hardwareEncoder, encoderID, failed, lastError, fileURL, elapsedText,
sizeText`. Statistics stay after stop until the next take, which is what the Saved state needs.

## 4. Monitor

- **`MonitorCoordinator`** (`Sources/App/MonitorCoordinator.swift`, `ObservableObject`):
  - `@Published workspace`, `targets`.
  - Callbacks: `onConfigurationChange`, `onWorkspaceChange`, `onDemandChange`, `onPreviewEnabledChange`.
  - Methods: `diagnostics(for:)`, `configuration(for:)`, `setConfiguration(_:for:)`,
    `copySettings(from:to:)`, `isPreviewEnabled(for:)`, `setPreviewEnabled(_:for:)`,
    `updateTargets(feeds:programAvailable:)`, `captureSink(for:)`, `surface(id:target:)`,
    `registerSurface(id:target:isVisible:scopeVisible:usesNativePreview:presentationScopeVisible:)`,
    `unregisterSurface`, `sourceStateChanged`, `offerProgram`.
- **`MonitorSurfacePresenter`** (`@Published`):
  - State: `isPresentationAdmitted`, `presentationStatus`, `status`, `detail`, `isFrozen`,
    `isFreezePending`, `isClean`, `pictureInterpretation`, `scopeTiming`, `scopeInterpretation`,
    `pictureAspectRatio`, `configuration`.
  - Methods: `requestFreezeOnNextFrame`, `cancelPendingFreeze`, `toggleFreeze`, `setClean`,
    `toggleClean`, `setUnavailable`, `setPresentationDemand`.
- **`MonitorConfiguration`** (Core): `toolsEnabled, guides, zebra, falseColor (Off / Sony S-Log3 /
  EL Zone, ARRI kept as an unsupported saved mode), focus, scopes (single mode), pictureStage,
  scopeStage, sourceProfileID, sourceCodeRange, sourceLogMapping`.
  `MonitorWorkspaceState{layout single/sideBySide/fourUp, tileBindings, splitRatio}`.
- **Package changes needed for r3 tiles:** none strictly required. The app can compose
  `MonitorNativePicture` + overlays itself.
  - **Nice to have:** expose the per-tool settings bodies from `MonitorToolsToolbar.settings(_:)` as
    public views, so split-button popovers can host one tool. Today it's private behind a string
    switch.
  - Add a "program view" layout or keep it app-side.
  - A single scope `mode` per feed means one scope per feed.

## 5. Diagnostics sources

| Data | Source |
|---|---|
| Delivered fps, processing ms, bitrates, drops by stage (source/capture/pool/camera/preview), renderer drops, audio stats, messages | `CaptureUpdate` (selected feed only today) |
| CPU, GPU (video), memory | `AppResourceSampler.sample()` (`AppResourceUsage.swift:43`), 1 Hz while visible |
| Encoder and writer stats | `RecordingStatistics` per feed |
| Monitoring rates, quality, budget, deadline | `MonitorCoordinator.diagnostics(for:)` → `MonitorDiagnostics` (`MonitorRuntimeContracts.swift` ~37–57) |
| Program output | `feedCoordinator.programOutputStatistics` (not exposed by AppModel) |

## 6. Build and test system

- **`scripts/build.sh`:** `xcodebuild -scheme Ultracam`, Release (or `--debug`), derived data on
  `/Volumes/8TB/...`, then `validate_bundle.py`. Unsigned unless `--signed` / `--local-development`.
- **`scripts/generate_project.py`:** **globs** `Sources/App/*.swift|.metal` + Shared + Recording +
  DeckLinkBackend for the app target, and the CameraExtension sources for the extension.
  - New files in `Sources/App/` (top level only, no subfolders) are picked up when you **re-run the
    generator**.
  - Subfolders like `Sources/App/UI/` are **not** globbed. Either keep the files flat in
    `Sources/App`, or extend the glob to `rglob`.
  - The generated `project.pbxproj` is checked in, so regenerate it and commit.
- **`scripts/test.sh`:**
  - Builds the MonitorTools package and runs `swift test` (including `MonitorToolsUITests`, which
    use `NSHostingView`).
  - Builds the Rust auto-switcher and the DeckLink objects.
  - Compiles **an explicit list** of App files (no `AppModel`, no SwiftUI views, no `UltracamApp`),
    plus `Tests/*.swift`, into one XCTest executable. `Tests/main.swift` builds an `XCTestSuite`
    by hand (`suite.addTest(XCTestSuite(forTestCaseClass: X.self))` ~224–268) and exits 0/1.
  - **A new test class must be added to `main.swift`.**
- **Template for app-level tests: `scripts/monitor-app-integration.sh`.** It compiles **every
  `Sources/App/*.swift` except `UltracamApp.swift`**, so `AppModel` and all SwiftUI views are
  included, with `-strict-concurrency=complete -warnings-as-errors`, plus a test `main.swift`
  (`Tools/MonitorAppIntegration/main.swift`). It already constructs a real `AppModel` with an
  injected `AppSettingsStore(defaults:)`, `VirtualCameraRegistryStore`, and a capturing registry
  publisher.
  - Note that it uses `external_root=/Volumes/8TB/cinesomatic-build`.

### Proposed test approach

**(a) Unit tests for the per-camera command layer.** Add an `Observable` per-camera model, e.g.
`CameraChannel` / `CameraChannelStore`, holding per-feed live state, settings and commands.
- Write it in `Sources/App` so it can be tested with only Shared/Recording dependencies. Keep it
  free of SwiftUI and AppModel, which talk through a small protocol.
- Add it to the `test.sh` source list, with check classes registered in `Tests/main.swift`.
- Cover: Stop Camera vs Stop All Cameras, record button state machine, selection = focus (D7), tally
  derivation (on air only when Program has a client, NEXT only while a cut is pending), D6
  automation rules (debounce, auto-started takes only), time-left math, and label/terminology
  functions.

**(b) UI verification.** Add `scripts/ui-verify.sh`, modelled on `monitor-app-integration.sh`
(compile all App sources except `UltracamApp.swift`, plus `Tools/UIVerify/main.swift`).
- Build each screen and state from a **fixture** (a protocol-backed fake model, or a real
  `AppModel` with an injected store plus a fixture-update injection hook) and host it in an
  offscreen `NSWindow` / `NSHostingView` at fixed sizes.
- Set `window.appearance` to `.aqua` and to `.darkAqua`.
- Render with `bitmapImageRepForCachingDisplay` + `cacheDisplay` to PNG under
  `/Volumes/8TB/.../ui-verify/<run>/`, and assert non-blank and expected size.
- Walk the accessibility tree (`NSAccessibility` children of the hosting view) to assert labels,
  roles and enabled states of key controls.
- Drive interactions by calling the model commands, or `performClick` on the found
  `NSAccessibilityElement`, then re-render.
- **Covers:**
  - main window: expanded, collapsed, Program view, Four Up, single camera
  - inspector, ⋯ menu, tool popovers
  - Settings panes, Diagnostics
  - dropdown content view; sheets and alerts: quit, confirm stop
  - every state from `states.html`
- **Menus:** `NSMenu` items can be built and inspected without display (titles, key equivalents,
  enabled state). Build the menu bar dropdown menu with the same builder and assert its items.
- **Also add** an in-app `--ui-verify-fixture` launch argument, used only in Debug, that loads
  fixture state for manual and visual review. Optional.

**XCUITest.** Not viable for this CLI-driven, headless-agent workflow. It needs a UI-test bundle
target in the generated project, an Xcode test runner, and macOS Accessibility/Automation TCC
approval for the runner, which prompts interactively and isn't pre-granted. Avoid it.
`NSHostingView` + accessibility inspection inside our own process needs no TCC grant.
`screencapture` of other windows needs Screen Recording permission; avoid it.

## 7. Gap list (round-3 + D1–D8 elements)

| Element | Status | Work |
|---|---|---|
| Session sidebar: cameras, output, recording, destination, automation | Mostly EXISTS | Recording destination from `recordingModel.outputFolder`. Per-feed automation exists in descriptors, but needs a per-camera setter (today only via selection). |
| **Per-camera live state in strips** (timecode, audio, format, drops, messages, preview error) for non-selected cameras | **SMALL–MEDIUM BACKEND** | Store `CaptureUpdate` per feed (`[FeedID: CaptureUpdate]`) instead of dropping it at ~881. Keep `update` as the selected alias. Low risk; the handler already runs for every feed. |
| **Per-camera settings controls** (processing, effects, LUT, input, gamut, preview, automatic) without selecting | **MEDIUM BACKEND** | Add `AppModel.updateFeed(_ id, mutate:)`: update the descriptor, then `feedCoordinator.reconfigureCapture` if running. Add per-feed LUT load/restore, generalizing `chooseLUT` / `restoreHeadlessLUT` with per-feed loading/error/title state. Alternative: since D7 merges selection and focus, every per-camera control can **select first, then act**. Selection rebinds the renderers and restores the LUT asynchronously; that's heavier but already works. Recommended: the per-feed API for status and light settings (effects, processing); LUT choose via select-then-act is acceptable. |
| Per-camera Start Camera / **Stop Camera** | SMALL BACKEND | `startFeed`/`stop` are selection-bound. Add `start(feedID:)` / `stop(feedID:)` using `feedCoordinator.startCapture` / `stopCapture` + `recordingModel.stop(feedID:)` + `manuallyStoppedFeeds`, mirroring the headless start path (~666–684). |
| **Stop All Cameras** | SMALL BACKEND | Loop `stop(feedID:)` over running feeds, then `stopAutoSwitcher`. `FeedCapturePool.stopAll` exists. |
| Confirm before stopping a recording or an in-use camera | UI only | Data: `recordingModel.feeds` status, `update.cameraOutputActive` per feed. |
| Record / pause / resume / stop per camera; record all / stop all | EXISTS | RecordingModel |
| Saved take state | SMALL | Keep the last `statistics.fileURL` after `.finishing` → idle (stats persist) and use `onRecordingFinished(url)`. Add `lastSavedURL` per feed. |
| Recent takes list | SMALL | Scan the output folder(s) for recent `.mov` (FileManager), plus `onRecordingFinished`. Reveal via NSWorkspace. |
| Disk time left | SMALL | `URLResourceValues.volumeAvailableCapacityForImportantUsage` per destination ÷ observed `videoMegabitsPerSecond` (or a codec nominal rate) × recording count. Warning thresholds are UI-side. |
| **Recording with no signal (gap telemetry)** | SMALL–MEDIUM BACKEND | `SourceRecordingCallbackAdapter.appendRawVideo` rejects `signalValid=false` (~59). Expose a rejected-frame counter / "signal lost since" in the recording statistics or per-feed `CaptureUpdate` (the "No video signal" message already exists while running). The UI can derive "Recording · no signal" from `status == .recording && update.input/no-signal message` → do that first (UI only). |
| Disk full mid-take | SMALL | The writer fails → `statistics.failed` / `lastError` / `feed.error`. Map it to a "Disk full" state when the volume has no capacity left. |
| Device unplugged vs no signal | SMALL | `devices` refresh (no device id) vs the no-signal message. No hot-plug notification exists; refresh on demand or on a timer while the window is visible. |
| Sleep prevention | PARTIAL EXISTS | `ProcessInfo.beginActivity([.userInitiated, .latencyCritical])` while capture runs (CaptureController ~274) already blocks **idle** sleep. Lid close is not handled: show a notice only (defer). |
| **Consumer count** ("In use" / "In use by 2 apps") | SMALL BACKEND (extension) | Publish `owner.consumers` as a number instead of "1"/"0" (CameraProvider ~680) and parse it in CameraDemandMonitor. Touches the signed extension. **Recommend:** show "In use" (boolean) now and defer the count. App names can't be known (D8): don't show them. |
| On-air tally, PROGRAM label, pending cut ("Cutting…"), NEXT only while pending | EXISTS | `switcherSelectedFeedID`, `switcherPendingFeedID`, Program route demand (`routeDemand[program]`, private → expose a bool). |
| Auto hold (manualHold) | SMALL | The setting exists; expose a toggle → `updateSwitcher` (recreates the bridge). |
| Program source lost / no healthy feed | SMALL | `SwitcherEvaluation.noHealthyFeed`, `retireProgramSource`. Expose the last evaluation and source health. |
| Program format mismatch indicator | SMALL | Compare `programContract` per running source (`FeedLifecycleDemandPolicy.programContract`). Expose a mismatch flag. |
| Applying change ("Updating output…") | EXISTS | `update.pipelineEnabledApplied == nil` while running, plus `update.message`. Needs per-feed `update`. |
| Preview error + Retry | EXISTS | `update.previewError`, `resetPreview()` |
| Install pending / approval waiting | EXISTS | `installer.pending`, `installer.status` |
| LUT loading / restore error / Locate… | EXISTS (selected) | `loading`, `lutError`, `chooseLUT()` |
| Automatic status text | EXISTS | `automaticFeedStatus`, `retryAutomaticFeed()` |
| **D6 backup automation** (record with camera apps, debounce, stop only auto-started takes) | **MAJOR NEW FEATURE → defer** (design only) | New policy + persistence + interplay with recording-as-demand (~1001). Show it in the UI as disabled "Coming later", or omit. |
| **Director timeline** (on-air history + single audio lane + cut reasons) | MEDIUM NEW → defer, or minimal | Data exists in `AutoSwitcherTimelineRecorder` (writes a sidecar) but isn't exposed live. Minimal version: keep an in-memory ring of applied cuts from `onProgramCutApplied` plus audio RMS from `update`. Recommend deferring the full lane view and shipping a "Recent cuts" list. |
| Diagnostics window (per-feed tabs, App tab, status popovers) | EXISTS data | Per-feed tabs need the per-feed `CaptureUpdate` map. The 60 s charts are new but small (ring buffer). |
| Settings: General / Recording / Camera / Switcher / Monitor / Advanced | EXISTS (mostly) | Open at login, default layout and strip density are NEW (small; open at login via `SMAppService.mainApp`). "Forget saved LUTs" and "Reset all settings" are small. |
| Detached monitor windows | EXISTS | `MonitorDetachedWindows` |
| Hybrid dropdown with live preview | EXISTS renderer (`miniPreviewRenderer`) | Implementation choice: `MenuBarExtra(.window)` with menu-styled rows (lowest risk; video works today), or an NSStatusItem + NSMenu custom view item (spike). Recommend `.window` first. |

## Top risks

1. **Per-camera model:** the strips assume per-feed live state and controls; AppModel is
   selection-centric. This is the critical-path backend change.
2. **Renderer budget:** two native renderers, both bound to the selected feed. Every other picture
   must be a monitor surface (`registerSurface` rules), and those can be refused under load.
3. **Test harness:** `test.sh` compiles a fixed file list without AppModel or views. UI tests need
   a new `ui-verify.sh` built on `monitor-app-integration.sh`, which uses `-warnings-as-errors`
   and strict concurrency, so new view code must compile cleanly under both.
4. **Project generator** globs only the top level of `Sources/App`. Re-run it and commit the pbxproj.
5. **Shared tree:** other agents may edit MonitorTools and MonitorCoordinator. Re-read before editing.
