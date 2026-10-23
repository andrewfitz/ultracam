# UI redesign: preparation inventory

Status: preparation. No UI code changes yet. This document lists what the current
app window and menu bar panel show and do, so a clean-room design can cover all
of it. Mockups come next and are reviewed before any real SwiftUI is written.

> Note (2026-10-22): `Packages/MonitorTools` and its `MonitorToolsUI` views named below were retired in W4; the monitor now runs on MonitorKit with app-owned surfaces (see [the integration map](MONITORKIT_INTEGRATION_MAP.md)).

Sources read: `Sources/App/UltracamApp.swift`, `MenuBarInterface.swift`,
`FeedInterface.swift`, `RecordingInterface.swift`, `MonitorWorkspaceView.swift`,
`AppModel.swift`, `AppSettingsStore.swift`, `RecordingModel.swift`, and
`Packages/MonitorTools/Sources/MonitorToolsUI/*`.

Scope column: **G** = global (app-wide), **F** = per feed (stored in
`FeedDescriptor`), **S** = per surface (one tile, window or tray, not saved).

## 1. Surfaces today

| Surface | Implementation | Notes |
|---|---|---|
| Main window | `Window("Ultracam", id: "main")` → `ContentView` | One window only, so the native video layer stays attached to one view. Min 850×590, default 1080×700. One long `ScrollView`. |
| Menu bar panel | `MenuBarExtra(.window)` → `MenuBarInterface` | Fixed 380 pt wide. Height = `min(700, max(420, screenHeight − 80))`. Header stays put; the body scrolls. Uses its own `miniPreviewRenderer`. |
| Menu bar icon | `MenuBarStatusIcon` | 3 states: `video` (stopped/starting), `video.fill` (processing live), `arrow.right.square` (bypass live). |
| Detached monitor windows | `MonitorDetachedWindows` (AppKit `NSWindow` + `NSHostingView`) | 800×580, any number. Title `Monitor · <feed>`. Each has its own target picker. |
| App menus | `.commands` | Feed menu, Hide from Dock in app menu, Quit replaced. |
| Open panels | `NSOpenPanel` | LUT `.cube`, default recording folder, per-feed recording folder. |

## 2. Main window inventory

Current layout, top to bottom: [monitor workspace | 292 pt feed controls column],
resource summary, Recording, Cameras, Effects, LUT, feed notice. Every section is a
custom `ControlPanel` rounded rectangle.

### 2.1 Feed status and transport (`FeedControls`, first panel)

| Element | Current control | States / gating | Scope | Notes |
|---|---|---|---|---|
| Selected feed name | Caption text | — | F | |
| Feed state | Dot + label (`FeedStateLabel`) | Stopped · Automatic · idle · Connecting · Waiting for HDMI · Ready · Live | F | Tooltip shows `update.message`. |
| Start / Stop feed | `.borderedProminent` button | Hidden in automatic mode; disabled when the device is missing or the LUT is loading | F | ⌘↩ |
| Retry feed | Button | Only in automatic mode after a failed start | F | |
| Processing (master bypass) | Switch | — | F | ⇧⌘B. Applied-state label: Effects selected / Complete bypass selected / Applying change… / Effects active / Complete bypass active |
| Start when camera is in use | Mini switch + status caption | Turns manual Start/Stop off | F | Status text from `automaticFeedStatus` |

### 2.2 Input and signal (second panel)

| Element | Current control | States / gating | Scope | Notes |
|---|---|---|---|---|
| Capture input | Pop-up picker, or "No UltraStudio detected" | Disabled while running | F | |
| Refresh devices | Borderless icon button | Disabled while running | G | |
| Input format | Monospaced text | "Not detected" when stopped | F | e.g. 3840×2160 10-bit 4:2:2 59.94 |
| Output format | Monospaced text | "Not streaming" | F | |
| Timecode (RP188) | Monospaced text | "—" when absent | F | Selectable |
| Embedded audio meter | Custom L/R peak + RMS bars, dB readout | "No signal" | F | 2 ch, 48 kHz |

### 2.3 Virtual camera (third panel)

| Element | Current control | States / gating | Scope | Notes |
|---|---|---|---|---|
| Connected badge | Green text | Running and a client is connected | G | |
| Camera message | Caption | "A signed build is required…" when unsigned | G | |
| Setup & details | DisclosureGroup | — | G | |
| Install camera / Remove camera | Buttons | Disabled when unsigned, while a request is pending, or while running | G | Install status text, unavailable reason |

### 2.4 Diagnostics (disclosure under the column)

Delivered fps, processing ms, video bitrate, video drops, audio format, audio bitrate,
audio packets/samples/drops; full window only: source gaps, capture admission, output
buffers, camera transport, preview drops plus a footnote; then the raw `update.message`,
`cameraMessage` and preview error. Shown only while running (except the messages).
Scope F.

### 2.5 Resource summary (`AppResourceSummary`)

"Ultracam total": CPU %, GPU (video) %, memory. Sampled once per second only while
visible. Each value has a long help string explaining what it measures. Scope G.

### 2.6 Recording (`RecordingControls`)

| Element | Current control | States / gating | Scope | Notes |
|---|---|---|---|---|
| Header summary | "No feeds recording" / "N feeds active" | — | G | |
| Codec | Pop-up: ProRes 422 10-bit, HEVC Main10 4:2:2 | — | G | |
| Timecode mode | Pop-up: Source timecode, Record start, PC time (default) | — | G | Help text per mode |
| Default folder | Path text, Choose…/Change…, Clear | — | G | Bookmark persisted |
| Crash-recovery note | Caption | — | G | |
| Interrupted takes list | Rows with Recover + spinner | Only one recovery at a time | G | Recovery message; "Show recovered movie in Finder" |
| Record all / Pause all / Stop all | Small buttons | `canRecordAny/PauseAny/StopAny` | G | |
| Per-feed row: status dot + name + status | — | idle grey · recording red · paused orange · finishing grey · failed orange | F | |
| Per-feed transport | Record / Pause / Resume / Stop / spinner | Record disabled with no folder; Finishing shows a spinner only | F | |
| Per-feed folder | Path, Choose…/Change…, Use default, "Default" tag | Applies to next take | F | |
| Stats row 1 | Elapsed, File size, Dropped frames (orange if > 0) | Always shown | F | |
| Stats row 2 | Encoded frames, Encode rate, Video bitrate | During/after a take | F | |
| Encoder details | DisclosureGroup: HW/SW, latency + peak, writer queue, encoder pending, audio drops, encoder/writer errors, filename, last error | During/after a take | F | |
| Error | Orange label | — | F | |

### 2.7 Cameras and Program switcher (`MultiCameraControls`)

| Element | Current control | States / gating | Scope | Notes |
|---|---|---|---|---|
| Add feed | Borderless "+ Add" | `canEditFeedTopology` | G | |
| Selected feed | Pop-up picker | `canEditFeedTopology` | G | **Picks which feed all of §2.1–2.3, §2.8, §2.9 edit** |
| Remove feed | Trash icon | Needs ≥ 2 feeds, `canEditFeedTopology` | G | |
| Feed name | Text field, commits on Return | `canEditFeedTopology` | F | |
| Output mode | Picker: Separate cameras / Program / switcher | Disabled while running | G | |
| Automatic switching | Mini switch | Program mode only | G | |
| Strategy | Picker: Manual, Fixed interval, Natural talking head, Dynamic analysis (later) | Needs automatic switching | G | |
| Interval | Slider 1–30 s, step 0.5 | Fixed interval only | G | |
| Anchor / Emphasis | Pickers (Automatic or a feed) | Natural talking head only | G | Director status caption |
| Program cut buttons | One bordered button per enabled feed, accent tint = on air | Program mode | G | Manual cut |

### 2.8 Effects (`PipelineControls`), ordered

| # | Element | Detail | Gating | Scope |
|---|---|---|---|---|
| 1 | LUT | "Loaded .cube" / "Optional · load a .cube" | Disabled until a LUT loads | F |
| 2 | Downscale | 1080p · Lanczos 3 | — | F |
| 3 | Color | 4:2:0 8-bit (off = 4:2:2 10-bit) | — | F |
| 4 | Frame rate | Limit to 29.97 | — | F |

All are checkboxes, disabled while a LUT is loading. Laid out horizontally in the window
and vertically in the tray. The tray shows "Bypass selected" when processing is off.

### 2.9 LUT (`LUTControls`)

LUT file name (or "Loading LUT…"), title or "A LUT is optional…" hint, spinner,
Load LUT…/Change… button, LUT input gamut picker (S-Gamut3.Cine / S-Log3,
S-Gamut3 / S-Log3), orange error label. Scope F. Bookmark persisted.

### 2.10 Feed notice (`FeedNotice`)

An info label for actionable messages that aren't already shown elsewhere
(e.g. "Saved LUT could not be restored"). Scope F.

## 3. Monitor workspace (in the window, partly in `MonitorToolsUI` package)

### 3.1 Workspace shell (`MonitorWorkspaceShell`, package)

| Element | Current control | Notes |
|---|---|---|
| Layout | Segmented: Single / Side by Side / Four Up | Saved in `MonitorWorkspaceState` |
| Swap tiles | Button | Multi-tile only, swaps tiles 0 and 1 |
| Expand tile / Restore layout | Button + context menu | Expands the focused tile |
| Focus | Tap or context menu "Focus tile"; accent border | Focused tile receives ⌃⌥F / ⌃⌥C |
| Split divider | Draggable, 0.2–0.8, accessibility adjustable | Side by Side only |

### 3.2 Tile chrome (`MonitorTileChrome` package + `MonitorBoundTile` app)

| Element | Current control | Scope | Notes |
|---|---|---|---|
| Target | Pop-up: Choose feed, feeds, Program, "Missing feed" | S (tile bindings saved) | |
| Status | Caption: Live, Starting, Feed stopped, Preview hidden, Monitor unavailable, No Signal, Stale… | S | |
| Picture | Native video or owned monitor picture, 16:9 black placeholder | S | Native preview only when Processed Output + tools off + not frozen |
| Picture signal | Mini picker: Source / Processed Output | F | Source disabled for Program |
| Picture legend | "Picture: …", "Frozen picture · …" | S | |
| Monitor tools | Mini switch + 5 buttons opening popovers (falls back to a Settings menu when narrow) | F | |
| Detail text | Pipeline / interpretation caption | S | |
| False color legend | `MonitorFalseColorLegend` | F | Unavailable on Program |
| Focus note | "Focus: Source" / unavailable on Program | F | |
| Show/Hide preview | Button | F | Per-target preview flag |
| Freeze / Unfreeze / Cancel Freeze | Button | S | ⌃⌥F on focused tile |
| Clean / Decorated view | Button | S | ⌃⌥C on focused tile |
| Hold Clean | Press-and-hold pill | S | Window only |
| View menu | Show/hide scopes in this view; zoom Fit/150/200/400% | S | |
| Detach | Button | S | Window only |
| Context menu | Freeze, Clean, Reset monitor tools, Copy settings to → | F/S | |
| Monitoring diagnostics | DisclosureGroup: requested/delivered rates, quality tier, offers/admitted/skipped, memory budget, GPU deadline, surface timing, presentation estimate | S | |
| Scopes pane | Title (mode · stage), Dock/Expand (120/240 pt), native scope + graticule, timing, interpretation, IRE footnote | S | |

Two `ViewThatFits` button rows exist (wide and narrow).

### 3.3 Monitor tool settings (popovers, package `MonitorToolsToolbar`)

| Tool | Settings |
|---|---|
| Guides | Enabled, Thirds, Center cross, Safe area, Opacity, Contrast |
| Zebra | Enabled, Mode (Above threshold / Band), Threshold IRE 0–109, Width IRE 0–30, Opacity; bypass note when false color is on |
| False Color | *(Updated: the working tree is now Off / Sony S-Log3 / EL Zone, Sony profiles only, ARRI kept as "Unsupported saved mode"; the original inventory follows.)* Mode (Off / EL Zone unavailable / ARRI or ARRI-style), Camera/Log profile (Unknown, Sony S-Gamut3.Cine/S-Log3, Sony S-Gamut3/S-Log3, ARRI LogC3 EI800, ALEXA 35 LogC4 EI800), Input code range (native / legal / full), Log transport mapping, Exposure index stepper (ARRI only), explanatory captions |
| Focus | Focus peaking, Highlight color (red/green/blue/yellow/white), Sensitivity, Noise rejection, Opacity |
| Scopes | Enabled, Scope (RGB parade / Luma waveform), Signal (Source / Processed Output), Refresh 10/15/30 Hz, Trace gain 0.25–4, Graticule |

All are per feed (`MonitorConfiguration` in `FeedDescriptor`).

## 4. Menu bar panel inventory (`MenuBarInterface`)

Pinned header: feed state, camera connection, Start/Stop (small), Processing switch +
applied state, automatic toggle + status.

Scrolling body: compact monitor tile (own target choice, no Detach/Hold Clean),
preview error + Retry preview, Effects checklist (vertical), LUT (compact; gamut in a
disclosure), Cameras/switcher (same as the window), "Feed details" disclosure (input
device, metadata, audio meter, virtual camera, compact diagnostics), feed notice.

Pinned footer: resource summary, Hide from Dock checkbox, Open window, Quit.

**Not in the panel today:** Recording (no record/stop from the menu bar), monitor
layout, detach.

## 5. Commands and shortcuts

| Command | Where | Shortcut | Gating |
|---|---|---|---|
| Start feed / Stop feed | Feed menu | ⌘↩ | Disabled in automatic mode or when start isn't possible |
| Start when camera is in use | Feed menu | — | |
| Processing enabled | Feed menu | ⇧⌘B | |
| Video preview | Feed menu | ⇧⌘P | |
| Hide from Dock | App menu (after Settings) + tray | — | Switches activation policy |
| Quit Ultracam | App menu | ⌘Q | Saves; waits for active recordings to finish |
| Freeze (focused tile) | Tile | ⌃⌥F | |
| Clean view (focused tile) | Tile | ⌃⌥C | |
| New window | Removed | — | `CommandGroup(replacing: .newItem) {}` |

There is no Settings scene, no toolbar, and no Recording/View/Window menu commands.

## 6. Behavioral constraints the design must respect

1. **One main video view.** The main native preview (`previewRenderer`) must stay
   attached to one view. A tabbed or sidebar design must not unmount and remount it
   on every navigation; keep it in a persistent pane. The tray uses
   `miniPreviewRenderer`. A design that needs more simultaneous native previews needs
   renderer changes.
2. **Visibility drives work.** Monitor surfaces register visible/hidden and scope
   visibility with `MonitorCoordinator`; hidden or occluded views do no GPU work.
   Collapsed or hidden UI should actually hide (unmount or report not visible), not
   just shrink.
3. **Gating rules (keep all):** device picker and output mode locked while running;
   add/remove/rename behind `canEditFeedTopology`; Start disabled with no device or
   while the LUT loads; Install/Remove gated by signing, pending state and running;
   Record needs a folder; Finishing blocks duplicate actions; Quit waits on recordings;
   Source analysis tools unavailable for Program.
4. **Automatic mode** replaces Start/Stop with status (and Retry after a failure). A
   visible preview counts as demand, so the preview toggle has side effects.
5. **Package boundary.** Tile chrome, toolbar, popovers, legend and diagnostics live in
   `Packages/MonitorTools/Sources/MonitorToolsUI` with their own tests
   (`MonitorToolsUITests`). Redesigning tiles means changing the package API too.
6. **Content requirements.** The `.help` strings and accessibility labels/values are
   specific and accurate (e.g. what the GPU % excludes, what bypass means). Carry them
   into the new design; they are content, not decoration.
7. **Honest states.** The UI never fabricates values ("No signal", "—", "unavailable
   on Program"). New layouts need a place for these empty states.

## 7. Gaps and pain points

### 7.1 The main design question: feed-scoped controls

`FeedDescriptor` stores device, effects, gamut, LUT, processing, preview, automatic
start and monitor configuration **per feed**. But the transport, input, effects, LUT
and diagnostics panels all edit only `selectedFeedID`, which is picked from a pop-up
buried in the Cameras panel. Recording, by contrast, lists every feed. Monitor tiles
pick their own targets independently. As a result, three different "which feed"
selectors exist (Cameras picker, each tile's target, the tray's target), and it's
easy to edit the wrong feed.

A multi-camera layout (e.g. a sidebar of feeds, with an inspector for the selected one)
would resolve this. It's the first thing the mockups should settle.

### 7.2 Model state with no or limited UI

| Model state | Today |
|---|---|
| `NaturalTalkingHeadSettings`: mode, minimum/soft max/max shot, cooldown, emphasis hold, grace period, boundary lookback/window, candidate dwell, transcript confidence, pause boundary, cut threshold, hysteresis | Only anchor and emphasis are exposed |
| `switcherPendingFeedID` (queued cut not yet applied) | Not shown; cut buttons only show the on-air feed |
| `cameraDemandError` | Not shown directly |
| `FeedDescriptor.enabled` | Filters cut buttons, but no enable/disable control |
| Per-feed `previewEnabled` | Global ⇧⌘P plus per-tile Hide/Show; the relationship isn't obvious |
| `PreviewVisibilityControl` (preview switch, `FeedInterface.swift`) | Defined but not mounted anywhere |

### 7.3 Current pain points (observed from code structure)

- One long scrolling window. Recording, Cameras, Effects and LUT sit below the fold,
  under the monitor.
- Custom `ControlPanel` cards instead of native grouping (`Form`, `Section`,
  `GroupBox`, inspector).
- No toolbar. Window-level actions (layout, record all, start) are plain inline buttons.
- Tile chrome stacks up to eight caption lines and two button rows under each picture,
  which crowds Four Up.
- The tray is a scrolled copy of the whole window at 380 pt, yet it can't record.
- Diagnostics are mixed in with everyday controls in three different disclosures.
- Engineering settings (Install camera, code range, transport mapping) sit next to
  everyday controls. There is no Settings window.

## 8. Native control palette (checked against the installed SDK)

Checked in `MacOSX27.0.sdk` SwiftUI/SwiftUICore `.swiftinterface` (development target
macOS 27.0.1).

**macOS 27-only (new):** `TabsPickerStyle` / `.pickerStyle(.tabs)`, `.reorderable`
/ `reorderContainer` / `reorderDestination`, `.swipeActions` / `swipeActionsContainer`,
document APIs (`Document`, `DocumentReader/Writer`), new `symbolEffect` transitions,
`containerRelativeFrame` and accessibility additions.

**macOS 26 Liquid Glass (available):** `glassEffect`, `GlassEffectContainer`,
`glassEffectID`, `.buttonStyle(.glass)` / `.glassProminent`, `ToolbarSpacer`,
`sharedBackgroundVisibility`, `ConcentricRectangle` / `containerCornerOffset`,
`backgroundExtensionEffect`, `scrollEdgeEffectStyle`, `buttonSizing`.

**Established (macOS 11–15):** `NavigationSplitView`, `.inspector`, `Form`
`.formStyle(.grouped)`, `Settings` scene, `MenuBarExtra` (`.window` and `.menu`
styles), `.navigationSubtitle`, `.badge`, `Table`, `Gauge`, `LabeledContent`,
`ControlGroup`, `.toolbar` with `ToolbarItem` placements, `ControlSize.extraLarge`.

Candidate mapping (for the mockups to test, not decided):

| Need | Candidate |
|---|---|
| Feed list + selected-feed editing | `NavigationSplitView` sidebar (reorderable feeds, status badges) + `.inspector` |
| Window actions (start, record, layout, cut) | Glass `.toolbar` with `ToolbarSpacer` groups |
| Monitor layout | Segmented or `.tabs` picker in the toolbar |
| Grouped settings | `Form` + `Section`, `.formStyle(.grouped)` |
| Rarely changed setup (camera install, codec defaults, folders, Dock) | `Settings` scene |
| Tile overlays (status, freeze, tools) | Glass controls over the picture (`glassEffect` / `GlassEffectContainer`) instead of caption rows |
| Audio level | Custom meter (no native peak/RMS meter); `Gauge` for single values |
| Diagnostics | Separate inspector tab or window, `LabeledContent` grids |
| Tray | Keep `.window` style for the preview, or a `.menu`-style dropdown for a pure-controls variant |

## 9. Open questions for mockups

1. Sidebar of feeds + inspector, or keep a single "selected feed" with a better picker?
2. Does the tray need recording controls (record all / per feed)?
3. Should the tray keep a live preview (a second renderer, extra GPU work) or become a
   compact status + controls dropdown?
4. Where does Program/switcher live: a toolbar strip of cut buttons, a dedicated
   Program view, or both?
5. Which settings move to a Settings window (camera install, recording defaults,
   Dock visibility, false-color source declarations)?
6. Diagnostics: an inspector tab, a separate window, or both?
7. How much of the tile chrome moves onto the picture as overlays versus into the
   inspector?

## 10. Mockups, round 1

`docs/mockups/index.html` compares three directions; the PNG renders are in
`docs/mockups/png/`. They are static HTML/CSS approximations of macOS 27 controls.

- **A · Studio** (`a-studio.html`): feed sidebar, monitor with glass overlays, and an
  inspector with tabs. The menu bar panel has a preview, toggles, per-feed recording
  and cuts.
- **B · Monitor-first** (`b-monitor.html`): full-bleed Four Up, a floating toolbar and
  transport bar, and per-feed settings in a popover. The menu bar panel has no preview.
- **C · Utility** (`c-utility.html`): a tabbed window with a camera table and detail
  form, and a native menu (with per-camera submenus) as the menu bar item.

Re-render after editing: `"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
--headless=new --hide-scrollbars --force-device-scale-factor=1 --window-size=1760,1100
--virtual-time-budget=5000 --screenshot=png/<name>.png "file://$PWD/<name>.html"`
(run from `docs/mockups`).

Round 1 limits: the mockups show only the main working state (live, recording,
Program), in dark appearance only. These shortcuts are proposals, not existing
commands: ⌘1–⌘3 / ⌃1–⌃3 cuts, ⌥⌘R Record All, ⌥⌘. Stop All. The look of the tabs
picker is a guess (the API exists in the SDK; its rendering wasn't checked). Live
thumbnails in A's sidebar and cut cards conflict with §6.1 unless renderers change or
thumbnails become periodic stills.

## 11. Mockups, round 2

`docs/mockups/r2/index.html`. Base: direction A, plus C's status bar and a hybrid
menu bar dropdown (A's published preview + C's compact native rows). Designed for
1–2 cameras, scaling to 4.

- **V1 · Session sidebar** (`v1-session.html`): one-camera meeting with backup
  recording. The sidebar becomes a session panel: output, destination and space left,
  recent takes, Recover, automation.
- **V2 · Channels** (`v2-channels.html`): standalone two-camera recording side by side,
  with record, output, effects, audio and monitor tools for each feed.
- **V3 · Rail + Multiview** (`v3-multiview.html`): two-camera Program meeting. Slim rail,
  Program + sources, cut bar with shot timer, director timeline.
- **States** (`states.html`): 20 edge cases. **Settings** (`settings.html`): Recording,
  Switcher (all director tunables) and Camera panes.

Proposals marked NEW: record with camera apps, time left per drive, recent takes,
a per-feed publish toggle, director timeline, menu bar recording/attention dots, and
⌃1–⌃4 / ⌃A / ⌥⌘R shortcuts. Implementation notes (NSMenu custom view item vs.
`.window` dropdown, preview renderer budget) are in the round 2 index.

## 12. Full design, round 3

`docs/mockups/r3/index.html`. The structure is settled:

- **Left:** V1's session sidebar (cameras, output, Program/Auto, recording destination and space left, recent takes, automation). It can be hidden.
- **Each feed:** V2's channel strip under its picture, with its own recording and output. Each strip collapses to one line; collapse all with ⌥⌘S.
- **No inspector.** Deeper per-feed settings live in the strip's ⋯ popover.
- **Program:** tally on the feed pictures (red on air, green next), with an optional Program view layout.
- **Bottom:** C's status bar.
- **Menu bar:** the hybrid dropdown, a live preview plus native-style rows.

Thirteen pages: main window expanded and collapsed, Program view, one camera, standalone two-camera recording, Four Up, monitor tools, menu bar dropdowns, app menus and shortcuts, diagnostics, Settings, states, and the design/build spec. The spec maps each component to its native API and to the current Swift views it replaces.

Shortcut corrections from the conflict check: scopes are ⌥⌘K (⌥⌘W is Close All Windows), and Auto is ⌃⌥A (⌃A moves the cursor in text fields).
