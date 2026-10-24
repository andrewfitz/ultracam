# App conformance review: real app vs round-4 design

**Reviewed (read-only):**
- **Design:** `docs/mockups/r4/*`, `SELF_CHECK.md`, `docs/mockups/r3/audit/REPORT.md` (D1–D8) and `docs/IMPLEMENTATION_MAP.md`.
- **Code:** `Sources/App/UI*.swift` and `UltracamApp.swift`, the per-camera API in `AppModel.swift`, and `RecordingModel.swift`.
- **Renders and dumps:**
  - latest ui-verify PNGs (`…/ui-verify/latest/png/`)
  - self-test renders and `menus.tsv` (`…/app-self-test/latest/`)
  - the old UI at `a32b220` (`FeedInterface.swift`, `RecordingInterface.swift`, `MenuBarInterface.swift`, `MonitorWorkspaceView.swift`)

**Caveats:**
- **Blank sidebar and inspector backgrounds:** the vibrancy is blank in offscreen captures. That's a capture artifact.
- **Grey switches and prominent buttons:** offscreen windows are never key, so these always render grey. Visual tint findings are marked "verify in an active window".

## Summary counts

| Status | Count |
|---|---|
| OK | 41 |
| MISSING | 10 |
| NOT WIRED | 4 |
| WRONG | 17 |
| DEFERRED-by-design | 6 |
| **Total** | 78 |

## Findings

### Main window: shell, toolbar, layouts

| # | Item | Status | Evidence | Fix suggestion | Sev |
|---|---|---|---|---|---|
| 1 | Session sidebar (output, Program summary, drives + time left, recent takes, interrupted takes, automation; camera rows only with more than 2 cameras) | OK | `UISessionSidebar.swift`; `component-sidebar-*.png`; live window capture | – | – |
| 2 | Sidebar auto-hides below 1100 pt; ⌃⌘S toggles it | OK | `UIMainWindow.swift` `sidebarShown`, `columnVisibility`; `UICommands.swift:140` | – | – |
| 3 | Status bar missing at minimum width (980×680) | WRONG | `main-single-meeting-980-dark.png` and `main-program-meeting-980-light.png` have no status bar; 1320 renders do. `UIStatusBar.swift:12` is a three-option `ViewThatFits` in `.safeAreaInset` | Make the last option always fit: output + recording + warning only, each `.lineLimit(1)` with `.layoutPriority`, no fixed widths. Or use `.frame(minWidth: 0)` and truncate. Add a ui-verify assertion that the status bar text exists at 980 | P1 |
| 4 | Toolbar: layout picker, collapse all, Start/Stop Cameras, record control with verb, inspector toggle | OK | `UIToolbar.swift`; `main-program-meeting-1320-*.png` | – | – |
| 5 | Record control and Stop Cameras go into overflow (») at 980 wide | WRONG | `main-program-meeting-980-light.png`: the toolbar shows only cuts, layout and collapse, plus » | Give the record control and Stop Cameras `ToolbarItem(placement: .primaryAction)` with high visibility priority (`ToolbarItemVisibilityPriority`, macOS 26). Let the layout picker overflow first, then collapse | P2 |
| 6 | Stop/Start Cameras toolbar item is icon-only (a square) | WRONG | `main-single-meeting-980-dark.png`, self-test render: stop or play glyph with no label | Use `.labelStyle(.titleAndIcon)` ("Stop Cameras") as the r4 toolbar spec says, or at least a clear tooltip plus a distinct symbol (`video.slash`) | P3 |
| 7 | Program cut group: red-filled on air, green outline when pending, ⌃n help, Auto toggle | OK (verify in an active window) | `UIToolbar.swift:83` borderedProminent `.tint(.red)`; renders show it grey because the offscreen window is inactive | Check in the live app (self-test runs inactive). Add an explicit red `background(Capsule)` if prominent tint goes grey when the window isn't key | P3 |
| 8 | Layouts: Single, Side by Side (2 columns, 2×2 with 3–4 cameras), Four Up (collapsed strips), Program View | OK | `UIMainWindow.swift:55–95`; `layout-*.png` | – | – |
| 9 | One camera always uses Single, and Single fits the window height | OK | `UIMainWindow.swift` `layout` override + GeometryReader | – | – |
| 10 | Old resizable split ratio, Swap Tiles, Expand/Restore Tile (MonitorWorkspaceShell) | MISSING | old `MonitorWorkspaceView.swift` used `MonitorWorkspaceShell` with swap/expand/split drag; the new grid has fixed equal columns | Lowest cost: an "Expand" item in the picture context menu (temporary Single for that camera, Esc restores) and "Swap Positions" (reorder `feedDescriptors`). A draggable split is optional | P3 |
| 11 | Inspector on demand (closed by default), ⌥⌘I, shows the selected camera | OK | `UIMainWindow.swift` `.inspector`; self-test passes "inspector shows…"; live capture | – | – |
| 12 | Inspector's accessibility values lag what it draws (Signal row read "Camera stopped" while drawing "No HDMI signal") | WRONG | `UISelfTest.swift` comment; `accessibility-live.txt` | Give the Signal row an explicit `.accessibilityValue(signalText)`, or `.id(snapshot.running)` on the section so the AX node is rebuilt when state changes | P3 |
| 13 | Confirmations: Stop Camera while recording/on air, Stop All Cameras (dialog in the window, NSAlert otherwise) | OK | `UIMainWindow.swift` `.confirmationDialog`; `UISessionBridge.send` alert fallback | – | – |
| 14 | Empty state with no cameras ("Add Camera") | OK | `UIMainWindow.swift:41` | – | – |

### Camera picture and channel strip

| # | Item | Status | Evidence | Fix suggestion | Sev |
|---|---|---|---|---|---|
| 15 | D1: a click selects (blue outer ring) and never cuts; VoiceOver default action is Select; "Cut to Camera N" is a named action | OK | `UICameraColumn.swift:46–51, 71`; ui-verify interaction checks | – | – |
| 16 | Tally: red ring + ON AIR only with a client, PROGRAM without one, NEXT (green) only while a cut is pending | OK | `UIPresentation.swift` `tally(for:in:)`; `UIStyle.swift` `UITallyBadge`; unit tests | – | – |
| 17 | At rest: identity, tally, REC/Paused/no-signal pill, active-tool chips. Hover/focus reveals tools, timecode, signal picker, freeze/clean/zoom/detach (live tiles only) | OK | `UICameraColumn.swift` `revealed`; renders | – | – |
| 18 | Placeholders: Starting, No HDMI signal (with hint), Unsupported, Input disconnected (Refresh Inputs), Camera stopped (Start Camera), Preview hidden (Show Preview), Updating output | OK | `UICameraColumn.swift:85–115`; `main-light-live.png` (No HDMI signal) | – | – |
| 19 | Clean View hides only guides and scope; name, tally and REC pills stay | WRONG | `UIAppProviders.swift` checks `presenter.isClean` only for guides/scope; overlays in `UICameraColumn.swift` ignore clean state | Expose `isClean` per camera (`UIMonitorBridge` presenter lookup, or a field in the snapshot) and hide the overlays when clean. Keep a tiny "Clean" chip so it's discoverable | P3 |
| 20 | Hold Clean (press-and-hold) | MISSING | old `MonitorWorkspaceView.swift` "Hold Clean" gesture; not in new UI (reported by agent A) | Optional: a long-press on the Clean overlay button sets clean while held | P3 |
| 21 | Preview error + Retry Preview (camera output keeps running) | MISSING | `.retryPreview` is never sent from any view (grep); old `FeedInterface.swift` `PreviewErrorNotice` had "Retry preview". Error only shows in Diagnostics/Settings | Add a placeholder state to the picture when `snapshot.previewError != nil`: "Preview failed · Camera output continues" + "Retry Preview" → `.retryPreview`. Also a ⋯ item and a warning in `UIPresentationBuilder.warning` | P1 |
| 22 | Expanded strip: header (name, status, tally, Stop/Start Camera, ⋯), single record control + Pause/Resume, saved/noFolder/failed/finishing states, folder + time left + camera-original note, output row (Cut / in use), chips, labelled Processing, audio | OK | `UICameraColumn.swift`; `strip-*.png` for all 11 states | – | – |
| 23 | Narrow output row in Program mode reads "In use" (ambiguous; should say "On air"/"In Program") | WRONG | `main-program-meeting-980-light.png` Camera 1 strip shows "((·)) In use" | Short form should use `outputLine`'s first word: "On air" / "In Program" / "Program source" | P3 |
| 24 | Collapsed strip: one line (chevron, name, tally, rec state, compact chips, meter, record, ⋯) | OK | `strip-*-collapsed-*.png` | – | – |
| 25 | ⋯ menu: Show Inspector, Cut (Program), Record/Stop, Pause/Resume, Load LUT…, Choose Folder…, Use Default, Copy Monitor Settings To ›, Rename… (locked with reason), Diagnostics…, Stop/Start Camera, Remove Camera… | OK | `UICameraColumn.swift:461–505` | – | – |
| 26 | ⋯ "Remove Camera…" removes immediately, with no confirmation (the inspector asks first) | WRONG | `UICameraColumn.swift:502` sends `.removeCamera` directly | Route through the same confirmation (add `.removeCamera` to `UIAction.needsConfirmation`) | P2 |
| 27 | "Copy Settings To" doesn't offer Program | MISSING | `UICameraColumn.swift:275, 484` list cameras only; old context menu included every target, Program included | Add a Program entry when `outputMode == .program` → `.copyMonitorSettings(from:to: "program")` | P3 |
| 28 | Monitor tool split buttons + popovers (Guides, Zebra, False Color Off/Sony S-Log3/ARRI-style/ARRI LogC/Six band/Custom, Focus, Scopes); Program limits | OK | `UIMonitorTools.swift`; `component-camera-column-*.png` | – | – |
| 29 | Picture zoom Fit/150/200/400 | OK | `UICameraColumn.swift:236` | – | – |
| 30 | Picture signal Output/Source picker | OK | `UICameraColumn.swift:205` | – | – |
| 31 | Detach to Window | OK | `UISupport.swift` → `MonitorDetachedWindows.open` (old AppKit window kept) | – | – |
| 32 | Scopes drawn as a 96 pt overlay at the bottom of the picture, not as a card under the strip as in r4 | WRONG (minor) | `UIAppProviders.swift` scope VStack; r4 main-expanded shows a scope card | Acceptable variant. If you want r4 parity, host `MonitorNativeScope` below the strip in `UICameraColumnView` when the Scopes tool is on | P3 |
| 33 | Selecting a camera is silently ignored while a LUT is restoring | WRONG | `AppModel.selectFeed` guard `!loading` (line ~424); picture tap / ⌘n do nothing | Queue the selection (remember the requested id and select when `loading` clears), or allow selection and cancel the in-flight LUT restore (it's already generation-guarded) | P2 |
| 34 | Selecting a running camera re-restores its saved LUT and reconfigures it ("Updating output…" flash on that camera) | WRONG (minor) | `AppModel.selectFeed` → `applySelectedDescriptor` → `restoreLUT` → `configuration.applyLUT` didSet → `reconfigure()` | Skip the reload when the camera's controller already has that bookmark loaded (track the loaded bookmark per controller) | P3 |

### Program view

| # | Item | Status | Evidence | Fix suggestion | Sev |
|---|---|---|---|---|---|
| 35 | Program picture with ON AIR/PROGRAM, on-air line, format line, mismatch warning | OK | `UIProgramView.swift`; `layout-programView-dark.png` | – | – |
| 36 | Source tiles with explicit Cut buttons (D1) | OK | `UIProgramView.swift:85–91` | – | – |
| 37 | Cut bar: numbered cuts, pending, Auto, strategy, Hold Shot, shot timer with min/soft max/max | OK | `UIProgramView.swift`; render | – | – |
| 38 | Recent Cuts list (Auto/Manual) instead of the full director timeline | OK / DEFERRED | `UIProgramView.swift:220`; D8 | Cut reasons need director data (deferred) | – |
| 39 | Program picture has no monitor tool buttons (guides/zebra/scopes on Program) | MISSING | `UIProgramView.swift` programPicture has no `UIMonitorToolButtons`; r4 program-view shows tools with source-only ones disabled | Overlay `UIMonitorToolButtons` with the presentation for "program" (cameraID "program"; source-only tools disabled with the existing reason) | P3 |

### Natural talking-head director

| # | Item | Status | Evidence | Fix suggestion | Sev |
|---|---|---|---|---|---|
| 40 | Anchor and Emphasis camera pickers (`naturalAnchorFeedID` / `naturalEmphasisFeedID`) | MISSING | No "Anchor" anywhere in `Sources/App/UI*.swift`; old `FeedInterface.swift` `MultiCameraControls` had both; r4 app-menus Program menu lists Anchor › / Emphasis › | Add pickers to Settings › Switcher and the Program menu (Anchor › Automatic / Camera N; Emphasis › …) writing `switcherSettings.naturalTalkingHead.anchorFeedID/emphasisFeedID` via `updateSwitcher` (add `UIAction.setAnchor/setEmphasis`) | P1 |
| 41 | Director status text (`naturalDirectorStatus`) | OK | `UIDiagnostics.swift` Program tab | – | – |
| 42 | Strategy picker in the Program menu omits Dynamic analysis (later) | OK (by design) | `UICommands.swift:126` | – | – |

### Menus and shortcuts (real app, `menus.tsv`)

| # | Item | Status | Evidence | Fix suggestion | Sev |
|---|---|---|---|---|---|
| 43 | Menus: Ultracam, File, Edit, View, Camera, Record, Program, Window, Help, with every r4 shortcut and no duplicate key equivalents | OK | `menus.tsv`; self-test "no duplicate shortcuts" | – | – |
| 44 | Window menu lists "Ultracam" and "Diagnostics" twice: SwiftUI's automatic entries for the Window scenes, plus the custom ones | WRONG | `menus.tsv` lines "Window › Ultracam", "Window › Diagnostics" ×2 | Remove the custom `CommandGroup(before: .windowList)` buttons and keep ⌘0 by adding `.keyboardShortcut("0")` to the scene (`Window(...).keyboardShortcut`), or hide the automatic entries with `.commandsRemoved()` on those scenes | P2 |
| 45 | Help › Ultracam Help (⌘?) has no help book (shows "Help isn't available") | WRONG | `menus.tsv`; no help book in bundle | Replace `.help` group with a link to docs (README/VALIDATION), or remove it | P3 |
| 46 | Record › Recover Interrupted Takes… recovers only the first take silently | WRONG (minor) | `UICommands.swift:103` | Open Settings › Recording's recovery sheet (or the sidebar section) instead | P3 |
| 47 | Camera menu: Start/Stop selected camera, Processing ⇧⌘B, Video Preview ⇧⌘P, Show Inspector, Rename…, Start/Stop All Cameras ⌘↩, Select Camera ⌘1–4, Add Camera | OK | `UICommands.swift:45–79`; `menus.tsv` | – | – |
| 48 | Record menu lacks Pause/Resume for the selected camera (only Pause All) | MISSING (minor) | `UICommands.swift:82–105` | Add "Pause/Resume Recording Camera N" | P3 |

### Menu bar item

| # | Item | Status | Evidence | Fix suggestion | Sev |
|---|---|---|---|---|---|
| 49 | NSStatusItem + NSMenu with live preview item (Program + tally-only thumbnails; two-camera; stopped/waiting with "Show Live Preview"), native rows, per-camera submenus, cut rows with ⌃n (top level only), confirmations via NSAlert, preview torn down on close | OK | `UIMenuBar.swift`; `menubar-preview-*.png`; ui-verify menu checks | – | – |
| 50 | Template icon with recording-dot / attention-triangle badges + accessibility labels | OK | `UIMenuBar.swift:130–150`; ui-verify icon renders | – | – |
| 51 | Failed automatic start "Retry" (banner/row) not offered in the menu bar or main window | MISSING | `.retryAutomaticStart` is sent only from the inspector (`UIInspector.swift`), and only when the status text contains "retry"; r4 menubar (e) / states show a Retry banner | Put a Retry row in the menu bar and a Retry button in the strip header when the camera has `automaticStart`, isn't running, and the status reports failure. A presentation flag is better than string matching | P2 |

### Settings and Diagnostics

| # | Item | Status | Evidence | Fix suggestion | Sev |
|---|---|---|---|---|---|
| 52 | Six panes (General, Recording, Camera, Switcher, Monitor, Advanced), grouped forms, light/dark | OK | `UISettings.swift`; `settings-*.png` | – | – |
| 53 | Open at login via SMAppService (with approval status) | OK | `UISettings.swift:44–112` | – | – |
| 54 | Reset All Settings: backend `AppModel.resetAllSettings()` exists but the button is disabled ("Coming later") | NOT WIRED | `UISettings.swift:609` `Button("Reset…") {}.disabled(true)`; `AppModel.resetAllSettings` | Enable when `model.canEditFeedTopology`; confirm; call `model.resetAllSettings()`, then show "Ultracam will quit to finish resetting" and `NSApp.terminate` | P2 |
| 55 | Forget Saved LUTs misses the selected camera (uses `updateCamera`, which ignores `lutBookmark` for the selected camera) | NOT WIRED | `UISettings.swift:626–632`; `AppModel.forgetLUT(_:)` exists | Call `model.forgetLUT(descriptor.id)` for each camera | P2 |
| 56 | "Strip density" default (`ui.collapsed.default`) is stored but never read | NOT WIRED | `UISettings.swift:43`; no reader | In `UIInterfaceState.init`, when `ui.collapsed` is absent and density = collapsed, start with all cameras collapsed (and apply to newly added cameras) | P3 |
| 57 | "Default layout" writes the same key as the current layout (`ui.layout`), so it's really "current layout" | WRONG (minor) | `UISettings.swift:42`; `UISessionBridge.swift` `UIInterfaceState` | Fine as a "Layout" picker. Rename the label to "Layout", or store a separate default applied at launch | P3 |
| 58 | Camera extension install/remove with gating, approval-pending card, Open System Settings | OK | `UISettings.swift:300–330`; sidebar banner | – | – |
| 59 | Sidebar has no "Install Camera" prompt when the extension isn't installed (signed build); `UIInstallState.installed` is unused | NOT WIRED | `UISessionSidebar.swift` banner states only unavailable/pending/needsApproval; `UISupport.swift` `UIExtensionDetector` | Add `.notInstalled` banner when `install.installed == false && install.canRequestChanges` with "Install Camera" → `.installCameraExtension` | P2 |
| 60 | Recording pane: folders, per-camera folders, codec, timecode (Mac Clock / Record Start / No Timecode Track), file name preview, camera-original note, recovery sheet | OK | `UISettings.swift` | – | – |
| 61 | Switcher pane: strategy, interval, director mode with honest caption, shot timing, advanced tunables, Restore Defaults | OK (except Anchor/Emphasis, #40) | `UISettings.swift` | – | – |
| 62 | Diagnostics: per-camera tabs (any camera), Program tab, App tab with 60 s history, Copy Diagnostics | OK | `UIDiagnostics.swift`; `diagnostics-*.png`, live capture | – | – |
| 63 | Diagnostics tab picker is segmented, not the macOS 27 `.tabs` style | OK (deliberate) | macOS 15 deployment target | Optionally `if #available(macOS 27, *) { .pickerStyle(.tabs) }` | P3 |

### States, errors and wording

| # | Item | Status | Evidence | Fix suggestion | Sev |
|---|---|---|---|---|---|
| 64 | Recording · no signal, disk low warning, failed take, saved take, finishing, noFolder, waiting/no signal, updating output | OK | `UIPresentation.swift` `stripState`, `warning`; unit tests | – | – |
| 65 | LUT restore/load error isn't shown in the main window (only the inspector, which is closed by default); not in the status bar warning | MISSING | `UIPresentationBuilder.warning` ignores `lutError`; old `FeedNotice` showed "Saved LUT could not be restored" in the window | Add `lutError` to `warning()` ("Camera 1: LUT unavailable") and show an orange line in the strip's output row with "Locate…" → `.chooseLUT` | P2 |
| 66 | Automatic-mode status line isn't shown in the main window (inspector only) | MISSING | `automaticStatus` is only read in `UIInspector.swift` / sidebar for the selected camera; r4 states show it in the window | Show it in the sidebar Automation section for every camera with `automaticStart` (it partly does for the selected camera) and on the stopped placeholder ("Waiting for a camera app") | P3 |
| 67 | No consumer app names anywhere in UI strings | WRONG (two backend strings) | `ExtensionInstaller.swift:172` "…select Ultracam in Zoom."; shown in Settings/sidebar status | Change to "select Ultracam in your meeting app" | P3 |
| 68 | "Feed" wording leaks from backend strings | WRONG (minor) | `AppModel.swift:989` "Feed stopped. Retry…", `CaptureController.swift:885` "Feed ready — no active video destination.", `RecordingModel` "Start this feed before recording it…" | Replace "Feed"/"feed" with "Camera"/"camera" in user-visible messages (the recording file-name fallback "Feed" can stay internal) | P3 |
| 69 | Recent takes show date only (duration nil) | WRONG (minor) | `UISupport.swift` `recentTakes` sets `duration: nil` | Read duration lazily (`AVURLAsset.load(.duration)`) in the cached scan, or show file size instead | P3 |

### Dark/light and native conformance

| # | Item | Status | Evidence | Fix suggestion | Sev |
|---|---|---|---|---|---|
| 70 | System colors and materials; every screen renders in light and dark; picture overlays stay dark capsules in light | OK | `UIStyle.swift`; ui-verify `*-light.png` / `*-dark.png` | – | – |
| 71 | Reduce Transparency and Increase Contrast: system materials (sidebar, inspector, `.bar`, popovers) adapt on their own; overlays on video are dark capsules (black at 72%), no custom glass | OK | `UIStyle.swift` header, `uiPictureOverlay`, `uiPictureControls`; the unused `UIGlassBackground`/`uiGlass` was removed | – | – |
| 72 | Native containers: NavigationSplitView, `.inspector`, Form `.grouped`, Settings scene, Window scenes, NSMenu, `confirmationDialog`, popovers | OK | code | – | – |

### Deferred by design (D6/D8, user-approved)

| # | Item | Status | Evidence | Fix suggestion | Sev |
|---|---|---|---|---|---|
| 73 | Backup recording with camera apps (D6) | DEFERRED-by-design | sidebar/Settings "Coming later" | – | – |
| 74 | Consumer count ("In use by 2 apps") | DEFERRED-by-design | shows "In use" (boolean) | – | – |
| 75 | Full director timeline (per-camera lanes, cut reasons) | DEFERRED-by-design | Recent Cuts with Auto/Manual only | – | – |
| 76 | Lid-close notice | DEFERRED-by-design | idle sleep already prevented by `beginActivity` | – | – |
| 77 | Per-camera "Publish as Camera" toggle | DEFERRED-by-design | not in UI (r4 marks NEW) | – | – |
| 78 | Sparkline history for drops by stage | DEFERRED-by-design | Diagnostics App tab has charts; drop sparklines not built | – | – |

## Top 15 to fix (by severity)

1. **#21** Preview error + Retry Preview is lost (P1).
2. **#40** Anchor / Emphasis camera pickers for the director are lost (P1).
3. **#3** The status bar disappears at minimum width (P1).
4. **#5** At 980 pt the record control and Stop Cameras fall into toolbar overflow (P2).
5. **#26** ⋯ Remove Camera has no confirmation (P2).
6. **#33** Selection is silently ignored while a LUT restores (P2).
7. **#44** The Window menu lists Ultracam and Diagnostics twice (P2).
8. **#51** There's no Retry for a failed automatic start outside the inspector (P2).
9. **#54** Reset All Settings isn't wired, though the backend exists (P2).
10. **#55** Forget Saved LUTs misses the selected camera; `forgetLUT` exists (P2).
11. **#59** There's no "Install Camera" prompt when the extension is absent; the `installed` flag is unused (P2).
12. **#65** A LUT error is invisible in the main window and status bar (P2).
13. **#19** Clean View leaves the name, tally and REC overlays (P3).
14. **#67 / #68** "Zoom" and "Feed" leak through backend strings (P3).
15. **#10 / #27 / #39** Lost or missing monitor-workspace extras: expand/swap, copy settings to Program, tools on the Program picture (P3).

## Resolution (2026-10-21)

Every item above that was MISSING, NOT WIRED or WRONG has been either fixed or deferred:

| # | Resolution |
|---|---|
| 3 | Status bar density follows its width and always shows output, recording and the warning; content minimum height 620 so it isn't clipped at 980×680. |
| 5, 6 | Toolbar order: cameras, record control and Restore Layout first; the layout picker and collapse overflow first. Stop/Start Cameras shows its title. |
| 10 | Expand Picture, Restore Layout and Swap Pictures (picture context menu and View menu). A resizable split stays deferred (P3). |
| 12 | The inspector's Signal row sets its accessibility value explicitly. The live self-test checks the picture's own label. |
| 19 | Clean View hides the camera name, tally, REC pill and tool chips (`UICleanViewState`). |
| 21 | Preview error card with Retry Preview on the picture. |
| 23 | In Program mode the narrow output row says On air or In Program. |
| 26 | Remove Camera always asks first (one bridge confirmation, from the ⋯ menu, the Camera menu and the inspector). |
| 27 | Copy Settings To includes Program in Program mode. |
| 33 | Selecting a camera while a LUT restores works; the stale load is invalidated. |
| 39 | Program picture has the monitor tool split buttons; source-only tools are disabled with the reason. |
| 40 | Anchor and Emphasis pickers in the Program menu and the Program View cut bar. |
| 44 | No duplicate Window menu entries; "Main Window ⌘0" sits above the automatic window list. |
| 45 | Help › Ultracam Help (⌘?) opens an in-app help window: getting started, good-to-know, all shortcuts. |
| 46 | Recover Interrupted Takes… opens Settings › Recording's recovery list. |
| 48 | Record menu has Pause/Resume Recording for the selected camera. |
| 51 | A failed automatic start shows Retry on the picture, strip, inspector and menu bar item, and a status bar warning. |
| 54 | Reset All Settings works: confirm, reset, quit. Disabled while cameras run or recordings finish. |
| 55 | Forget Saved LUTs clears every camera, including the selected one (`AppModel.forgetLUT`). |
| 56 | New-camera strip density is read for cameras added afterwards. |
| 57 | Relabelled "Layout" (it is the main window's layout, the same as View › Layout). |
| 59 | Sidebar banner "Install the Ultracam camera…" with Install Camera when no Ultracam device exists. |
| 65 | LUT errors appear on the strip (Locate…) and in the status bar and menu bar warning. |
| 66 | The automatic status line shows in the sidebar's Automation section and the inspector. |
| 67, 68 | Backend messages no longer name a meeting app or say "Feed". |
| 69 | Recent takes show their duration (read in the background, cached). |

**Deferred (P3 polish, by decision):**
- resizable split ratio between two pictures
- Hold Clean press-and-hold
- the scope drawn as a card under the strip rather than over the picture's lower area
- the brief "Updating output…" when selecting a running camera re-applies its saved LUT; the camera format doesn't change, so a meeting isn't interrupted

**Deferred by design** (shown as "Coming later" where they appear):
- backup recording automation (D6)
- consumer count
- the full director timeline
- lid-close notice
- the publish-as-camera toggle
- drop sparklines
