# 06 · Visual polish and native fit

Audit date 2026-10-30, against the renders in
`.build/agent-work/build/ultracam/ui-verify/latest/png/` (built 11:46 from the state of `30c8d73`) and the
current source. Read-only: nothing was built, launched or edited.

## 0. How to read this

**Severity.** `live-risk`: could cost a recording or a meeting, or misstates what is on air. `clarity`: slows or
misleads the operator. `polish`: finish.

**What was examined.** Every `main-*`, `layout-*`, `component-*`, `settings-*`, `diagnostics-*`, `popover-*`
(`popover-recording`, `popover-audio`, `popover-audio-live`) and `menubar-*` render in dark; every `monitor-tool-*`
in dark; all 11 expanded strip states, the live-meter variants and all 12 collapsed states in dark; a sample of `scope-*`; and light versions wherever contrast was in question. The menu rows
come from the `menubar-*.txt` dumps; VoiceOver from the `accessibility-*.tsv` files.

**Measured, not estimated.** Contrast ratios and strip heights were read from the PNG pixels. Contrast is the
darkest or lightest text pixel against the most common background pixel in the crop.

**Limits you should know about.**

- The offscreen window isn't key, so toolbar tint, switch color and sidebar text draw in their inactive look. For
  one finding (V1) that is the point, because Ultracam is also not key during a meeting. Elsewhere I don't judge
  tint from these renders, and sidebar text contrast is excluded.
- **Fixture gap.** Every fixture has `cameraControls == nil`, but the live app always passes a store
  (`UILiveRoot.swift:57`). So only `main-live-model-*` shows what the owner actually sees in the strip header and
  the extra Wi-Fi row (V14). Every other render of a strip shows a layout the app doesn't ship. The fixture should get
  a store.
- Not rendered, judged from code only: the detached monitor window, Help, the lower half of the inspector, live
  Diagnostics tabs, the status popovers for Output and Program, and anything with the sidebar and inspector open
  together in a full window.

**Earlier decisions.** Nothing here reopens a resolved finding unless marked. Section 11 lists regressions and the
three decisions I overturn with reasons (F4 pane heights, F3 "Processing" toggle name, the visible window title).
The always-on tool bar was a deliberate fix (`b621bc7`, 2026-10-21), not a regression of P1-11, and V9 keeps what
that commit gained.

---

## 1. Verdicts on the owner's list

| Item | Verdict | Finding |
|---|---|---|
| Seven tool buttons with chevrons at rest | Change. One button at rest, full bar on hover, chevrons only on the hovered or active tool. | V9 |
| Picture name repeated in the strip | Keep on the picture, keep in the strip header: they do different jobs. Change the tally, REC, clock and format repeats. | V10 |
| REC state, timer and format repeated | Change. One clock per camera, one per session. | V10 |
| Mixed strip rhythm; "Cut" and "Processing" come and go | Change. Fixed row heights; one fixed output row. | V5, V11 |
| Two record-state indicators per camera, plus toolbar, plus status bar | Change. Picture REC pill, strip record row, status bar. Toolbar becomes a verb only. | V10 |
| Empty area under the strips in Side by Side | Change. Center the block, anchored so collapsing doesn't move the pictures. | V13 |
| "Stop Cameras" vs "Stop All (2)" | **Change, live-risk.** | V1 |
| Program layout icon splits the control | Half native, half ours: see below. Keep four fixed segments, change the icon. | V16 |
| Toolbar title is plain "Ultracam" | Keep the window's title, stop drawing it. | V17 |
| Inspector Effects: checkboxes plus pickers | Change. One row per effect. | V12 |
| Settings footnotes as documentation | Change. | Section 8 |
| Status bar density | Change. Short readout always, Audio icon-only when fine. | V18 |
| Menu bar card and compact rows | Change. Row budget back to 14; drop the duplicate rows. | V19, V20 |
| Red for both record and on air | Keep one red (D8), separated by form: on air is the only filled red. | V6, section 6 |
| Selection blue ring vs tally red ring | Keep both on the picture. Fix the color source and the gap. | V2 |
| Sidebar Hold and Auto toggles | Remove. Auto gets one home, in the toolbar. | V4 |

The Program icon: macOS hides a segmented control's divider next to the selected segment, so with Side by Side
selected the only visible line falls between Program View and Four Up (`main-program-meeting-1320-dark`). That line
is correct native drawing. What makes it look wrong is that the `tv` glyph is wider and differently shaped than its
neighbors, and that the control changes from three segments to four with the output mode.

---

## 2. State ownership

The cause of the repetition is that no surface owns anything, so every surface echoes everything. This map decides
it. "Echo" means allowed to repeat; everything else in that row is removed.

| Fact | Owner | Allowed echoes | Remove |
|---|---|---|---|
| Camera identity | Strip header | Picture name pill; camera's menu | Nothing. On video the name is what the eye lands on; in the strip it scopes the controls. |
| Tally (on air, Program, Next) | Picture: pill and ring | Toolbar cut dot; sidebar row (3+ cameras); menu bar | Strip "On air" badge (expanded and collapsed), except in Clean View, which hides the picture's tally |
| Take clock, per camera | Expanded: strip clock. Collapsed: picture pill. | None | Picture pill's digits while the strip is expanded (pill stays as "● REC"); collapsed strip's clock |
| Take clock, session | Status bar | None | Toolbar clock |
| Stop recording | Strip record button; toolbar | Menus | Nothing |
| Source format | Strip header badge | Inspector Signal row | Ready line's "2160p 59.94 ·" |
| Output format | Picture "Output · 1080p 29.97" menu | Effects menu rows | Three format chips in the strip |
| Output in use | Strip output row | Status bar, sidebar row | Window subtitle |
| Auto on or off | Toolbar | Status bar words; menus | Sidebar toggle; Program View cut bar toggle |
| Camera original note | Ready record line | Record button help | Permanent footnote on the folder row |

---

## 3. Findings, ranked

### Live-risk

**V1 · live-risk · Toolbar.** `main-program-meeting-1320-dark`, `main-standalone-1320-dark`, `main-standalone-980-dark`;
`UIToolbar.swift:27`, `:199-218`; `UIPresentation.swift:383`, `:806`; `UIMainWindow.swift:215`.
- **Problem:** Stop Cameras and Stop All (2) sit side by side with the same square glyph in the same gray capsule,
  because the red `.borderedProminent` tint goes gray whenever Ultracam isn't key, which is all of a meeting. The
  code already knows this: `UIToolbar.swift:155-157` added a dot to the cut buttons for that exact reason.
- **Fix:**
  - Drop `.buttonStyle(.borderedProminent).tint(.red)` from `.stop` and `.stopAll`. Draw the label like
    `UICutButtonLabel`: an 8 pt red `Circle()` followed by the words, so it survives a non-key window.
  - Labels: "Stop Recording" (one take running) and "Stop 2 Recordings" (more). No clock (V10). "Stop All (1)" must
    never appear: when one of several cameras records, the label is "Stop Recording".
  - **Change only the label in `UIRecordControl.title` for that case.** Keep `.stopAll` and its `.stopAllRecordings`
    action when one of several cameras records. The `.stop` case sends `.toggleRecordingSelected`
    (`UIToolbar.swift:199-201`), so with Camera 2 recording and Camera 1 selected it would start a second take.
  - Put the record control first, a `ToolbarSpacer(.fixed)` next, then the camera control, so they sit on separate
    glass.
  - Rename the camera control "Stop All Cameras", matching its confirmation button (`UIMainWindow.swift:215`). The
    menu bar already separates these (`stop.fill` for cameras, `stop.circle` for recordings); the toolbar now agrees.

**V2 · live-risk · Picture.** `UICameraColumn.swift:99`, `:89`; `UIStyle.swift:63`; `main-program-meeting-1320-dark`.
- **Problem:** The selection ring is `Color.accentColor` and the app defines no accent, so a user with the Red,
  Orange or Green system accent gets a selection ring that reads as on air, a warning, or Next.
- **Fix:** Use `Color.blue` for the ring, as a fixed state color (section 6). On a picture that is both selected
  and on air, keep both rings on the picture, but separate them: `ringOutset` 6 and line width 2, giving a 4 pt gap
  (1.5 pt today, so they read as one thick band). This stays inside the 20 pt gutter. In the live app
  confirm Graphite and Red accents with a camera selected.

**V3 · live-risk · Picture, 980 pt.** `main-four-up-980-dark` (bottom row of Camera 1 reads "…" and "● F"),
`main-program-meeting-980-dark` ("14:22:…", "REC…"), `main-standalone-980-dark`; `UICameraColumn.swift:223-236`.
- **Problem:** At the minimum window the recording pill truncates to a dot and one letter, because the timecode,
  Output menu and view controls all take width first.
- **Fix:** `recordingPill.fixedSize().layoutPriority(2)`; the picture's bottom row gives way in this order: timecode
  first, then the Output menu's format text ("Output"), then the view controls fold into the context menu. Hide the
  timecode pill below a 560 pt picture width. A REC pill must never truncate at any size.

**V4 · live-risk · Auto.** `main-program-meeting-1320-dark`, `component-sidebar-dark`, `layout-programView-dark`;
`UIToolbar.swift:112-129`; `UISessionSidebar.swift:110-132`; `UIProgramView.swift:120-138`.
- **Problem:** Whether a machine is cutting your meeting is shown by an unlabeled wand in the toolbar, while the
  same switch appears three times at once in Program View with the sidebar open (REPORT P1-11 said one control).
- **Fix:**
  - Toolbar: `Label("Auto", …)` with `.labelStyle(.titleAndIcon)`, so the word is always visible, followed by a
    chevron-only `Menu` in the same group holding Strategy, Hold Current Shot, Anchor and Emphasis.
  - Sidebar: delete the Auto toggle, Strategy picker and Hold toggle. Keep one row, "Switching", with the value
    "Auto · Natural talking head" or "Manual", and the shot timer under it.
  - Program View: delete Auto, Strategy, Hold, Anchor and Emphasis from the cut bar. The Program menu and menu bar
    rows stay; those are legitimate echoes.
  - When Auto is on and Hold is on, the toolbar reads "Auto · Hold".

**V5 · live-risk · Strip output row.** `main-program-meeting-1320-dark` (Camera 1's row is an unlabeled glyph,
Camera 2 shows Cut and "Processing"), `strip-stopped-dark` (no output words, no Processing label),
`strip-live-meter-narrow-dark`; `UICameraColumn.swift:1018-1054`, `:1077-1085`; `UIStyle.swift:195-210`.
- **Problem:** Four chips take the row, so the operator loses the words that say what the meeting receives, and
  one mis-click on a chip renegotiates the meeting's format with no undo (D2 allows that, so it needs to be a
  deliberate act). Chips also change width when toggled (the checkmark appears), so toggling one can make "Processing"
  vanish under the pointer. "Not in use" fits worse than "In use", so the label flips when a meeting connects.
  At the 400 pt cell the strip is wider than its picture and clips at both edges.
- **Fix:** One row recipe, always the same:
  - **Leading:** in Program mode a fixed-width 64 pt slot: Cut button, or the same slot reading "On air" as plain text
    with the radiowaves glyph. In Separate mode the existing gutter glyph and output line, falling back to "In use"
    or "Not in use".
  - **Trailing:** one small `Menu`, "Effects · 4 of 4", containing the four toggles with their values ("Resize ·
    1080p") and "Show in Inspector", then the Effects switch at `.controlSize(.small)`.
  - The chips go. D2 is untouched: there is still no prompt, it just takes two clicks. N3's toggle semantics carry
    over into the menu's checkmark items. Collapsed strips lose their chips too.

**V6 · live-risk · Strip, light mode.** `strip-recording-light`; `UICameraColumn.swift:895-896`, `:919`,
`:674`; `UIStyle.swift:172`, `:143-146`.
- **Problem:** The words read during a take fail 4.5:1: "Recording" in red is 3.84:1 in light and 4.04:1 in dark at
  12 pt semibold, and "0 dropped" is 3.93:1, where a nonzero count is the reason to look. This also breaks PLAN's rule
  on colored text. The window carries 14 red marks in `main-program-meeting-1320` when keyed.
- **Fix:**
  - "Recording" in `.primary`, with a 7 pt red dot in front, same as the status bar.
  - `dropsLine` in `.primary`.
  - Waveform gutter icon always `.secondary`. Its red variant at `:674` is a recent addition that means nothing a
    glance can use; the tooltip stays.
  - Result: 14 red marks become 9.

**V7 · live-risk · Picture focus.** `main-four-up-1320-dark` (Camera 1 shows its timecode and view controls while the
selection ring is on Camera 2); `UICameraColumn.swift:59-60`, `:109-115`.
- **Problem:** `revealed` is true on keyboard focus, and a picture takes focus by itself, so one picture's controls
  stay out at rest and don't follow selection. `onChange(of: focused)` also selects whichever picture gets focus,
  which can move the target of ⌘R and ⇧⌘B without a click. Fixtures ignore `select`, so verify that part live.
- **Fix:** `.focusable(!compact, interactions: .activate)`, so clicks and window activation don't focus the picture
  and only Full Keyboard Access does (confirm that behavior in the live app). Keep the reveal on that focus. Remove the auto-select from `onChange(of: focused)`
  and select on Space or Return instead. Clicks still select through `onTapGesture`.

**V8 · live-risk · ON AIR pill.** `main-program-meeting-1320-dark`; `UIStyle.swift:145`, `:153`.
- **Problem:** White on the tally red is 3.94:1 at 11 pt bold, on the most important word in the app.
- **Fix:** Pill background `Color.red.mix(with: .black, by: 0.2)`, which measures 5.75:1. The ring stays pure red.
  It's still a system color, and the pill reads stronger.

### Clarity

**V9 · clarity · Tool bar.** Every `main-*`, `monitor-tool-bar-dark`, `main-stopped-1320-dark`,
`main-live-model-dark`; `UICameraColumn.swift:211`; `UIMonitorTools.swift:81-87`, `:164-192`; `UIPresentation.swift:46`, `:56`.
- **Problem:** Thirteen controls in a capsule about 285 pt wide sit on every picture at rest, including stopped and disconnected
  ones where no tool can act, and that noise is the price paid in `b621bc7` for discoverability. The on state is a
  faint fill. Zebra's glyph is a single slash that reads as "disabled", and Clip's triangle is the app's warning symbol
  in a white outline.
- **Fix:** Keep `b621bc7`'s gains (always findable, works with no signal, View › Monitor Tools). Change the presentation:
  - **At rest:** the existing `menu` button alone (28 × 28 capsule), showing the filled variant when a tool is on,
    plus a small glyph for each active tool. The bar expands on hover, or while one of its popovers is open.
  - **Hovered:** the bar, with each chevron visible only on the hovered tool and on tools that are on. The chevron's
    16 × 24 hit area stays reserved so nothing shifts. VoiceOver and keyboard always reach them.
  - **Order and grouping:** Zebra, False Color, Clip | Focus, Guides | Scopes | Picture, with a 1 pt divider at each
    `|`. Exposure, then framing, then measurement.
  - **On state:** white fill at 0.9 with a black glyph, not a 24 % white wash. Passes color-independently.
  - **Glyphs:** Zebra `circle.lefthalf.striped.horizontal`, Clip `sun.max.trianglebadge.exclamationmark`. Confirm both
    render at 13 pt.

**V10 · clarity · Repetition.** `main-single-meeting-1320-dark`, `strip-recording-collapsed-dark` (three red dots in a
row), `main-program-meeting-1320-dark`; `UICameraColumn.swift:243-291`, `:732`, `:1130-1131`; `UIToolbar.swift:202`, `:212`.
- **Problem:** With one camera recording, the screen says "12:31" four times, and Program mode says "Camera 1 on air"
  in the subtitle, status bar, ON AIR pill, strip badge and output line.
- **Fix:** Apply section 2. In code: `recordingPill` shows digits only when `camera.collapsed`; remove `tallyBadge`
  from `header` and `collapsed` unless the picture is in Clean View; remove the elapsed text from
  `UIToolbarRecordControl`; `.ready` record detail becomes "ProRes 422 HQ · camera original"; delete the footnote
  from `folderContent`. H11's concern is met better: the note appears when you are about to press Record.

**V11 · clarity · Strip rhythm.** `strip-ready-dark` 207 pt, `strip-recording-dark` 212.5 pt, `strip-saved-dark` 224 pt;
`main-stopped-1320-dark` vs `main-single-meeting-1320-dark`; `UICameraColumn.swift:883-930`; `UIMainWindow.swift:136-141`.
- **Problem:** The strip height changes with state and the picture is fitted to that height, so pressing Record makes
  the picture 11 pt narrower (926 to 915 pt at 1320) and moves every strip control. By the same arithmetic a saved take shrinks
  it by about 30 pt. Side by side, strips drift apart: bottoms at 582 and 586 pt, because of the Own folder badge and the
  Cut button.
- **Fix:** Fixed rows, in every state (recipe in section 7). The record row is 44 pt with two lines in every state; a
  saved take's note joins the detail line. Alert rows (`LUT unavailable`) are the only variable rows and add 24 each,
  and only they may change the fit. Use the fixed expanded height in `stripHeight`, not a measured one, so a state change
  can't move the picture.

**V12 · clarity · Inspector Effects.** `component-inspector-dark`; `UIInspector.swift:156-219`.
- **Problem:** "3 Color format" (a checkbox) sits four rows above "Color format" (its picker), Sync cameras and Aspect
  aren't effects, and the digits are 1.87:1.
- **Fix:** One row per effect, in pipeline order: `LabeledContent { Picker.labelsHidden() } label: { Toggle(.checkbox) }`.
  - Rows: Effects (master switch), LUT → moved here from the LUT section as its checkbox plus file name, Output size
    (with Aspect as a second control under it, shown only when the output differs from the source aspect),
    Color format, Frame-rate cap.
  - Disable the picker while its checkbox is off. Delete the digits; the footer says "Applied top to bottom".
  - Move Sync cameras to the top of the inspector, under the camera name: it isn't this camera's setting.
  - Rename Program color to "Color space", since it also applies in Separate mode.
  - Replace the 3-line paragraph at `:197` with an info button (section 8).

**V13 · clarity · Side by Side.** `main-program-meeting-1320-dark`, `main-collapsed-dark`; `UIMainWindow.swift:88-95`, `:105-129`.
- **Problem:** Two cells are width-limited and top-aligned, leaving 244 pt of nothing above the status bar at the
  default window, and more when collapsed.
- **Fix:** Center the block vertically, computed from the **expanded** strip height, so collapsing a strip doesn't
  move the pictures. In `cells`: top inset = `max(margin, (height − pictureHeight − expandedStripHeight − spacing) / 2)`.
  Don't grow the pictures past the width fit. Quiet space around a picture is correct for a monitor wall.

**V14 · clarity · Real strip header.** `main-live-model-dark` (only render with a real store);
`UIFeedSettingsMenu.swift:36-44`; `UICameraColumn.swift:664-671`, `:727-731`.
- **Problem:** In the live app the header badge renders at the wrong size: `.menuStyle(.borderlessButton)` throws away
  the label's badge styling, so it's a 13 pt title with a 14 pt white disc, and the dot's tone color is gone. A
  Wi-Fi row adds a strip row that fixtures never show.
- **Fix:**
  - `.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()`, the same recipe as `signalMenu`
    (`UICameraColumn.swift:313-316`), then the existing capsule label renders as designed.
  - Delete the Wi-Fi row. Add "Camera Control…" to the badge menu and the ⋯ menu; the inspector row stays.
  - Rename per the copy pass.
  - Give the UI fixture a `CameraControlStore`.

**V15 · clarity · Tools on dead pictures, uneven bars.** `main-stopped-1320-dark`, `main-live-model-dark`,
`main-four-up-980-dark`; `UIMonitorToolButtons` `ViewThatFits`.
- **Problem:** At 980 pt the on-air picture folds to the menu button and its neighbors keep the full bar, purely
  because ON AIR took more width, so same-size pictures look different.
- **Fix:** V9 removes this at rest. On hover, decide bar or menu from picture width alone (under 480 pt: menu),
  not from what's left beside the name.

**V16 · clarity · Layout picker.** `main-program-meeting-1320-dark`, `layout-*`; `UIPresentation.swift:22-29`,
`:796`; `UIToolbar.swift:50-59`.
- **Problem:** The segment list changes between modes, so Four Up is the third segment in Separate and the fourth in
  Program while its shortcut stays ⌥⌘4; the `tv` glyph also means Program in the status bar and menu.
- **Fix:** Always four segments, Program View disabled in Separate mode with help "Available in Program mode". Glyphs:
  `rectangle`, `rectangle.split.2x1`, `sidebar.squares.trailing` (large pane plus thumbnails, which is what Program
  View is), `square.grid.2x2`. With one camera, keep today's hidden picker.
  Separately, `layout-single-dark` and `main-output-locked-separate-dark` draw the selected segment as a solid white
  blob hiding its glyph. Two renders of dozens, so probably an offscreen artifact. Verify on a key window before acting.

**V17 · clarity · Title.** `main-program-meeting-980-dark` (layout, collapse and inspector pushed into the `>>`
overflow); `UIMainWindow.swift:42-43`; `UIPresentation.swift:786-793`.
- **Problem:** "Ultracam" over "Camera 1 on air" costs about 100 pt of toolbar to repeat the status bar word for word
  (S6 regressed), and at 980 pt that width is what pushes view controls into overflow.
- **Fix:** Overturning only the display: keep `.navigationTitle("Ultracam")` for the Window menu, Mission Control and
  VoiceOver, as PLAN decided, add `.toolbar(removing: .title)`, and drop `.navigationSubtitle`. Under 1100 pt, the
  cut group shows number only ("1", "2") via `ViewThatFits`, with names in help.

**V18 · clarity · Status bar.** `component-status-bar-dark`, `main-standalone-1320-dark`;
`UIStatusBar.swift:19-26`, `:96-107`, `:177-188`; `UIPresentation.swift:746-752`.
- **Problem:** Engineering readouts and reassurance sit at the same weight as the warning, the segments don't look
  clickable, and "CPU —" and "GPU (video)" are diagnostics vocabulary in an everyday bar. "8TB 1 h 52 m · Archive
  5 h 40 m left" puts the unit at the very end of a list.
- **Fix:**
  - `.buttonStyle(.accessoryBar)` on segments, for a hover highlight and a real 24 pt height.
  - Audio: icon only when fine, words only when something's wrong.
  - Resources: always the short form, "CPU 12% · GPU 8%"; hide CPU until its first sample. Memory and the qualifiers
    stay in the popover. Remove `.full`.
  - Recording: "REC 2 · 12:31 · 8TB 1 h 52 m left · Archive 5 h 40 m left", with "left" on every drive.
  - The warning segment stays the last of the left-hand group and gets `.fontWeight(.medium)`.

**V19 · clarity · Menu bar rows.** `menubar-program-meeting.txt`; `UIMenuBar.swift:427-443`.
- **Problem:** Program mode has 18 top-level rows plus the card (the r3 budget was about 14), Processing is repeated
  inside every camera's submenu, and with one camera "Start with Camera Apps" names no target.
- **Fix:** Remove the top-level Processing and Video Preview rows (Video Preview moves into the camera submenu, ⇧⌘P and
  ⇧⌘B stay on the main menu). Move Automatic Switching, Hold and Strategy into one "Switching" submenu whose
  subtitle is "Auto · Natural talking head". That gives 14 rows in Program with two cameras.

**V20 · clarity · Menu bar card.** `menubar-preview-program-meeting-dark`, `menubar-preview-standalone-dark`;
`UIMenuBar.swift:697-710`, `:733-754`.
- **Problem:** The "1 · on air" pill covers most of a 74 pt thumbnail, the Program picture has no tally
  ring although the camera picture does, and two-up puts REC top-left and the name bottom-left, opposite of everywhere else.
- **Fix:** Thumbnail pill is the number only; the ring plus the row's "On air" subtitle carry the state. Add the red
  ring to `programPicture`. In `miniPicture`, name top-left and REC bottom-right, as on the main picture. Remove the
  timecode pill from the card; nobody reads frames from a menu.

**V21 · clarity · Detached monitor.** `MonitorWorkspaceView.swift:285` (no render).
- **Problem:** The same camera gets a different tool bar in a detached window: a different set (no Picture panel),
  order, on state (`.tint`), backing (`.chrome` material), and spelling ("False Colour").
- **Fix:** Use `UIMonitorToolButtons` in `MonitorDetachedChrome`, with `MonitorTileToolbar` kept for other hosts of
  the library. Add a render of this window to `ui-verify`.

**V22 · clarity · Program View.** `layout-programView-dark`, `component-program-view-dark`; `UIProgramView.swift:84-100`,
`:113-140`, `:191-217`; `UIToolbar.swift:101`.
- **Problem:** Each camera has two Cut buttons in view, with different glyphs (`arrow.right.circle` on the tile,
  `arrow.left.arrow.right` in the strip), plus the toolbar; the Program picture says "Camera 1 on air" next to ON AIR;
  and Recent Cuts runs off the bottom of the scroll view at the default window.
- **Fix:** Tile Cut button is the only cut in the detail area; delete the cut bar's buttons; after V4 the bar is just
  the shot timer. Use `arrow.left.arrow.right` everywhere. Bottom-left pill reads "Camera 1" and format. Give the source
  column's camera number and name the same 24 pt row as Cut.

**V23 · clarity · Sidebar content.** `component-sidebar-dark`, `component-sidebar-problems-dark`;
`UISessionSidebar.swift:99-104`, `:56-89`, `:239-265`.
- **Problem:** Sync cameras sits inside Output and appears in three places; Backup recording is a permanent dead row;
  "Cameras · 2" is a header with no rows; "Start with camera apps" is a button that looks like a label.
- **Fix:** Delete Sync from the sidebar (inspector and Settings keep it). Delete the Backup recording row; "Coming later"
  stays in Settings only. Keep the Cameras header (it carries Add), but move the count to `.badge`. Give the
  automation row a trailing chevron so it reads as a link to the inspector.

**V24 · clarity · Meter, light mode.** `strip-recording-light`, `strip-live-meter-light`;
`Packages/MonitorKit/Sources/MonitorKitUI/AudioMeterView.swift:174`.
- **Problem:** In light mode the unlit zones are near-black (`lightTrack` white 0.2), so −6 to 0 looks like a heavier
  bar than the signal itself.
- **Fix:** `lightTrack: Color(white: 0.86)`. The `-20` reference tick then needs primary at 0.6 in light mode; check
  it against the full `popover-audio-live` too.

**V25 · clarity · Output vs source format.** `main-single-meeting-1320-dark`.
- **Problem:** "2160p 59.94" in the strip and "Output · 1080p 29.97" 40 pt above it look like a contradiction with
  no explanation.
- **Fix:** Badge tooltip "Signal arriving from \(input)". Effects menu's first line reads "2160p 59.94 → 1080p 29.97". No
  new visible text in the header.

**V26 · clarity · Inspector Source section.** `component-inspector-dark`; `UIInspector.swift:115-119`.
- **Problem:** A right-aligned four-line paragraph sits in a value column, for a device that reports nothing.
- **Fix:** Hide the row when the device reports no formats; otherwise put the list in a section footer, left-aligned.

**V27 · clarity · Scopes.** `scope-rgbParade-dark`, `scope-vectorscope-light`; `UIScopeDescription.swift`, `UIScopePanel.swift:17`.
- **Problem:** Three lines of metadata ("Live · Scope PTS 12.345 · 0.0 s old") sit under each scope, and a regular-size Expand
  button outweighs the scope's title.
- **Fix:** Hide the status line while live and fresh; show it only when stale, paused or unavailable. Keep one
  description line. Expand becomes an icon-only `.borderless` `arrow.up.left.and.arrow.down.right`, 24 × 24.

### Polish

**V28 · polish · Record button.** `strip-ready-dark`, `main-standalone-1320-dark`; `UIStyle.swift:171-181`.
Problem: idle is a bigger red mass than recording, so a stopped take looks louder than a live one. Fix: idle dot 0.5 ×
size; while recording, the ring is red at 2 pt and the square stays.

**V29 · polish · Strip wording in transient states.** `strip-recording-dark` ("— · —"), `strip-finishing-dark`,
`strip-noFolder-dark`; `UIPresentation.swift:678`; `UICameraColumn.swift:977`.
Problem: the placeholder dashes look like a glitch, "Finishing…" sits beside "Saving…", and No folder says it three
times. Fix: hide `sizeLine` until bytes arrive; delete the trailing "Saving…"; in No folder, drop the "No recording
folder" row's time left and keep Choose Folder…

**V30 · polish · Compact OVER lamp.** `strip-*-collapsed-dark`; `UICameraColumn.swift:1144-1157`.
Problem: the unlabeled hollow "○" beside the compact meter is the OVER lamp, and it has no meaning at a glance. Fix:
give it `.help("OVER")` and draw lit only; hide when clear.

**V31 · polish · Meter left edge.** `strip-recording-dark`.
Problem: L and R sit at the text column (48 pt) but bars start at 80 pt, breaking H14's edge. Fix: pass a label width
that starts bars at 60 pt.

**V32 · polish · Placeholder.** `main-live-model-dark`; `UIInputLabels.missingLabel`.
Problem: "Reconnect Input device · ICEA or choose another input." reads like a template, and `cable.connector.slash` looks
like a figure at 32 pt. Fix: fallback "Reconnect the input or choose another."; use `cable.connector` plus the title.

**V33 · polish · Camera settings overlay.** `UICameraControl.swift:238-239`.
Problem: the only picture overlay with a rounded rectangle and `.caption`, outside H3's single metric. Fix: use
`uiPictureOverlay()`.

**V34 · polish · Sidebar truncation.** `component-sidebar-dark`; `UISessionSidebar.swift:188`.
Problem: "Oct 19, 2026 at 3:53 AM ·…" loses the duration, the useful half. Fix: drop the year ("Oct 19, 3:53 AM")
and show the duration as a `.monospacedDigit()` trailing value.

**V35 · polish · Extension banner.** `component-sidebar-problems-dark`; `UISessionSidebar.swift:452-456`.
Problem: "Install" three times, and the icon near-invisible (check on a key window). Fix: title "Ultracam camera not
installed", body one sentence, button "Install Camera Extension…"; icon `.foregroundStyle(.secondary)`.

**V36 · polish · Tool popovers.** `monitor-tool-zebra-dark`, `monitor-tool-program-focus-dark`.
Problem: "Program · Program Output" stutters; "Zebra 1 · picture" is cryptic; on Program, a disabled form shows a
switch that is visibly off and still looks live. Fix: subtitle "Program"; "Zebra 1 · follows picture"; hide the form
under the reason when a tool is unavailable. These popovers are otherwise the best-organized surface in the app.

**V37 · polish · Diagnostics.** `diagnostics-dark`; `UIDiagnostics.swift:108-115`.
Problem: the empty state is wrapped in a form card, so it reads as a setting. Fix: when stopped with no take, show a
plain `ContentUnavailableView` filling the window, Device row beneath.

**V38 · polish · Camera Control sheet.** `UICameraControl.swift:77`.
Problem: a fixed 640 × 690 sheet with hand-built layout, the one form that isn't a grouped `Form`. Fix: `Form` with
`.formStyle(.grouped)`, `.frame(width: 560)`, height from content up to 640.

**V39 · polish · CPU copy pill.** `UICameraColumn.swift:247`.
Problem: "CPU copy · Ingest · 12" is pipeline vocabulary on the picture, though it does need to be seen. Fix: "CPU copy
· 12 frames", full text in help.

---

## 4. Index by screen

| Screen | Findings |
|---|---|
| Toolbar | V1, V4, V16, V17 |
| Picture | V2, V3, V7, V8, V9, V10, V15, V32, V33, V39 |
| Strip | V5, V6, V10, V11, V14, V25, V28, V29, V30, V31 |
| Layouts | V13, V22 |
| Sidebar | V4, V23, V34, V35 |
| Inspector | V12, V26 |
| Status bar | V18 |
| Menu bar | V19, V20 |
| Detached monitor, scopes, popovers | V21, V24, V27, V36 |
| Diagnostics, sheets | V37, V38 |
| Settings | Section 8 |

---

## 5. Copy pass

### Decisions on terms

| Concept | Use | Replace |
|---|---|---|
| The processing chain | **Effects**: section, master switch, menu item, ⇧⌘B | "Processing" in `UICameraColumn.swift:1047-1053`, `UIInspector.swift:161`, `UIMenuBar.swift:432`, `:532`, Help. This overturns F3. Two nouns for one idea is the problem, and Diagnostics uses "Processing" for a millisecond timing. |
| Master off | "Effects off" and footer "Camera original goes out unchanged." | "Complete bypass" in the UI; "bypass" stays in the menu bar's accessibility label if useful |
| Device or connector | **Input** | Inspector section "Source" becomes "Input" |
| What's arriving | **Signal** | "No HDMI signal" variants |
| Monitor stage | **Source** only as the stage name, "Source · before LUT" | "Source" anywhere else |
| Log declaration | **Camera log** | "Source profile" (`UIInspector.swift:247`), "source declaration" (`UISettings.swift:308`, `:672`, sidebar help), "From source tags / unspecified" becomes "Not declared" |
| Formats list | "Supported formats" | "Supported source formats" |
| Unplugged | "Input disconnected" | Badge "Input missing" (`UIPresentation.swift:577`) |
| Never chosen | "No input" | "No input selected" |
| No folder | "No folder" | "No recording folder", `UIPresentation.swift:681` |
| Output mode | **Separate** and **Program** | "Separate (ISO)", "Separate cameras" |
| Meeting apps | "meeting apps" | "camera apps": "Start with meeting apps", `UISessionSidebar.swift:243`, `UIInspector.swift:313`, `UIMenuBar.swift:374`, `UISettings.swift:211` |
| Size effect | "Output size" | "Resize" in `effectLongTitles`, menus, Help |
| Color space | "Color space" | "Program color" |
| Copying tools | "Copy Monitor Settings To" | "Copy Settings To" (`UICameraColumn.swift:412`) |
| Saving a take | "Saving…" and "Writing the last of the take" | "Finishing…" |
| Automatic strategy | "Strategy" | "Automatic strategy" (`UISettings.swift:433`) |

### Stop verbs (final set)

| Control | Label |
|---|---|
| One camera | Stop Camera |
| All cameras | Stop All Cameras |
| One take | Stop Recording |
| Several takes | Stop 2 Recordings |
| Status popover | Stop All Recordings |
| Output change | Stop Cameras and Switch |

Remove "Stop All (n)" from `UIRecordControl.title` and the `UIToolbar` label. The Pause label is unchanged.

### Camera, never Feed

These are the only user-visible ones. Type and variable names stay.

| Where | Now | Change to |
|---|---|---|
| `UIFeedSettingsMenu.swift:44` | "Feed settings for Camera 1" | "Camera Control for Camera 1" |
| `UIFeedSettingsMenu.swift:45` | "Feed settings, 2160p…" | "Camera 1 signal, 2160p 59.94" |
| `UIFeedSettingsMenu.swift:34` | "Open camera settings…" | "Camera Control…" |
| `UICameraControl.swift:103` | "Show camera settings over this feed" | "Show camera settings over this picture" |
| `UICameraControl.swift:174` | "assigned to another feed" | "This control camera is assigned to another Ultracam camera. Unassign it there first." |
| `PictureControls.swift:468` | "Also changes the output feed." | "Also changes the camera output." |

### Other strings

- Extension: "Install Camera" and "Update Camera" become "Install Camera Extension…" and "Update Camera Extension…",
  matching Settings.
- MonitorKit spelling: "False Colour", "display colours", "18% grey", "One stop over grey", "stays grey" against the
  app's "False Color" and "gray". American throughout, including public library strings shown here.
- Detached tool bar: "Magnify" is "Zoom" and "Clean" is "Clean View" in the app.
- `UITallyBadge`: `.accessibilityLabel(text.capitalized)` gives "On Air"; use `tally.label` (S13).
- Section headers: "Video compatibility" and "Input device settings" are sentence case; F13 chose title case.
- Program output line: "In Program · on air" becomes "On air"; "In Program · no viewer yet" stays; "Program source" stays.

---

## 6. State color system

One meaning per color, and form separates shades of meaning. System colors only.

| Color | Means | Form | Never |
|---|---|---|---|
| **Red** | On air | The only **filled** red: tally pill (darkened 20 %, V8) and ring | |
| **Red** | Recording | **Dot** (7–8 pt) plus label-color words; stop square in the record button; red ring while active | Red text, filled red buttons, gutter icons, warnings, failures, shot limits |
| **Green** | Healthy or next | Dot on signal badge, output-in-use glyph, saved check, Next ring and pill | "Good" text. Green words |
| **Orange** | Needs a look | Triangle or dot plus label-color words; strip wash at 0.08 with a 0.5 border; pause glyph | Decoration; "Manual". Automatic things |
| **Blue** | Selected | The selection ring only, always `Color.blue`, whatever the system accent | Tally. Anything else |
| **Accent** | System control state | Switches, checkmarks, focus, list selection | State |
| **Yellow** | Approaching a limit | Meter caution zone; shot timer past the soft maximum | Warnings. Those are orange |
| **Gray** | Inactive or neutral | Stopped, not in use, disabled | |

Meter and false-color palettes are measurement scales, not UI state, and they keep their own colors.

**Non-key windows.** Prominent tints go gray when the window isn't key, so no state may depend on a filled control.
Tally and recording in the toolbar are drawn with `Circle()` fills, which hold their color.

**Current violations, all fixed above:** `Recording` red text (V6), red waveform (V6), red filled Stop (V1), accent
selection ring (V2). The strip's red "On air" dot is identical to the REC dot beside it; removing it (V10) resolves this.

---

## 7. Spacing and typography check against UIStyle

### Type

The scale in `UIStyle.swift:34-53` is sound, and the main window follows it, with one exception: `UICameraColumn.swift:579`
still sets `.caption` for the compact placeholder's detail text, shown on Program source tiles. Change it to `.uiMeta`.
The scale stops at the main window's edge.

| File | `.caption` or `.caption2` prose | Verdict |
|---|---|---|
| `UISettings.swift` | 8, including `UISettingsFootnote` (:35) | Change to `.uiMeta` (11 pt); footers are read text |
| `UIInspector.swift` | 5 (:38, :117, :198, :253, :261) | Change to `.uiMeta`; its own footers already use it |
| `UIDiagnostics.swift` | 5 (:142, :238, :377, :404, :435) | Change to `.uiMeta` |
| `UICameraControl.swift` | 9 | Change to `.uiMeta` |
| `UISettingsDeviceSettings.swift` | 4 | Change to `.uiMeta` |
| `UIFeedSettingsMenu.swift` | 3 | Fine on the badge; menu rows ignore it, so delete it there |
| `UIMenuBar.swift` | 8 | Keep: pills on a 340 pt picture, a documented compact scale. Add `uiCompactOverlay` |

`.system(size:)` on text, which the rule forbids: `UIFeedSettingsMenu.swift:60` (8 pt brand mark) and
`UIScopePanel.swift:17` (9 and 8 pt graticule labels; acceptable as a scope's own graticule, note it in the comment).
The rest are symbols.

Raw styles that should use tokens: `UIStatusBar.swift` (`.subheadline` ×13) and `UISessionSidebar.swift` (×19) are
`.uiMeta` by another name; `UIProgramView.swift:49`, `:58`, `:61`, `:69` are `.uiOverlay`.

### Spacing

Census across the strip, status bar, style, Program view and sidebar: 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 20, 24.
Adopt four named steps, alongside `UIPictureSpacing`:

```swift
enum UISpace {
  static let tight: CGFloat = 4    // icon to its text
  static let row: CGFloat = 8      // within a row, between strip rows
  static let group: CGFloat = 12   // card padding, between groups
  static let section: CGFloat = 20 // UIPictureSpacing.margin and gutter
}
```

Values of 1–3 inside a label stack are fine.

| Off-grid value | Where | Change to |
|---|---|---|
| 5 | Status segment spacing, REC pill | 4 |
| 6 | Picture overlay HStack, Program source stack, compact strip gaps | 8 |
| 7 | Status padding | 8 |
| 9 | Tally pill padding | 8 |
| 10 | Picture-to-strip spacing, overlay inset, strip vertical padding | 12 (update `columnSpacing`) |
| 14 | Popover padding | 12 |

### Control heights

| Value | Use | Note |
|---|---|---|
| 18 | Badge | Fine, not interactive |
| 22 | Status segment | Change to 24 |
| 24 | Picture pills, floor for interactive | Fine |
| 28 | Picture bars | Fine |
| 12 / 14 | Corner radii of strip and picture | Fine |

### Strip recipe (V11)

| Row | Height | Contents |
|---|---|---|
| Header | 24 | Chevron, brand, name, signal badge, ⋯ camera button |
| Divider | | |
| Record | 44 | Button, label over clock or detail, size and drops, one action |
| Folder | 20 | Path, time left, Own folder |
| Alert (optional) | 24 each | Triangle, title, reason, action |
| Divider | | |
| Output | 24 | V5 recipe |
| Meter | 46 | Bars, scale, readout |

Spacing is 4 within a group and 8 around dividers; card padding 12. Total without alerts: 224 pt, the same in every
state. Today's strip in the live app measures 230 pt (`main-live-model-dark`, Camera 2, stopped, with the Wi-Fi row), so
this is slightly shorter and it stops moving. A saved take's note joins the record row's detail line, and overflow goes to help.

---

## 8. Settings window

Another report decides what goes where. This section decides how it looks and behaves. The current file is a useful
starting point: `Form` and `.formStyle(.grouped)` are right; the problems are in sizing, prose and row discipline.

### What's wrong now

- **Heights.** `UISettings.swift:110`, `:238`, `:370`, `:490`, `:679`, `:749` hardcode 400, 700, 430, 660, 360 and 520.
  These drift with content: Recording cuts off inside Crash Recovery at 700 (`settings-recording-dark`), and the Reset
  section's header is cut in half at 520 (`settings-advanced-dark`).
- **Width.** 640 pt holds six toolbar tabs, not ten.
- **Prose.** Footers hold up to four sentences of documentation at 10 pt. The Monitor pane has no settings at all.
- **Rows.** Sync cameras' explanation is a row of its own (`:308`); Install and Remove share a row at full width;
  "Published Cameras" can render as a bare header (`settings-camera-dark`); slider thumbs for 10, 20 and 30 s sit in the
  first quarter of ranges that run to 180 s.
- **State.** `settings-camera-dark` shows "Not installed" beside a footer saying "Camera extension request completed".

### Window

**Style: a sidebar window, like System Settings.** Keep the `Settings` scene so ⌘, and the app menu stay automatic.
Inside, `NavigationSplitView`:

| Property | Value |
|---|---|
| Width | Fixed 820 pt: sidebar 200, detail 620 |
| Height | Default 620, minimum 460, grows to the screen. The user may resize vertically |
| Sidebar | `List(selection:)`, `.listStyle(.sidebar)`, one `Label(title, systemImage:)` per section, `.navigationSplitViewColumnWidth(200)` |
| Sidebar toggle | `.toolbar(removing: .sidebarToggle)`; the column never collapses |
| Title | The section's name via `.navigationTitle`; no toolbar buttons |
| Selection | `@AppStorage("settings.section")`, so Settings reopens where it was left |
| Grouping | Sections in logical order, with one divider before the system-level group (Advanced and the like) |
| Glass | What the split view supplies. None added. No materials in the form |
| Minimize, zoom | As the `Settings` scene gives them |

**Why not toolbar tabs.** That's the older convention and Safari carries about ten, but it costs three things here.
Ten tabs need about 800 pt of width and a grouped form uses about 620 of it. Native tabs want the window to resize per
pane, and `Form` reports no intrinsic height, so every pane would need measuring. Worst, in-pane changes (the Fixed
interval row, the Advanced disclosure, approval rows) would resize the window during an edit and move controls out
from under the pointer. Switcher with Advanced open runs about 1000 pt by estimate, past a 13-inch display's usable height. A stable
window has none of these problems, and the sidebar costs nothing at 7 sections and scales to 10.

**Sizing, instead of hardcoded heights.** Delete all six `.frame(height:)` calls. The root takes
`.frame(width: 820).frame(minHeight: 460, idealHeight: 620, maxHeight: .infinity)`, and the scene gets
`.windowResizability(.contentSize)`. Panes scroll inside the detail column; `.scrollBounceBehavior(.basedOnSize)` stays.
Switching sections never changes the window. Confirm in the real app that the `Settings` scene honors the height range;
if it doesn't, add `.resizable` to the style mask on appear.

**Deep links.** `UISettings.swift:241` receives "UIShowRecovery" inside the Recording pane, which won't exist when
another section is selected. Move the receiver to the root, set the selection, then present the sheet.

### Rows

Every row is one of these. Nothing else goes in a section.

| Kind | Build | Rule |
|---|---|---|
| Value | `Picker`, `Toggle` | Label left, control trailing. `Toggle` is `.switch` |
| Choice | Segmented for 2–3 short options, pop-up otherwise | No segmented control over 300 pt |
| Status | `LabeledContent` with `.secondary` value | Read-only, and it must be real state |
| Action | `LabeledContent { Button }` | One button per row |
| Subtitle | `LabeledContent { } label: { Text; Text }` | One short line, under the label |
| Number | `TextField` (56 pt, `.monospacedDigit`, trailing) + unit + `Stepper` | Sliders only where the range is 0–100 % and exact values don't matter; the three shot limits and five advanced values become fields |
| Path | `Text`, `.lineLimit(1)`, `.truncationMode(.middle)`, `.help(fullPath)` + button | One Choose…; Show in Finder and Clear go in a `Menu` on the same row |

- **Section rules.** A section with no rows doesn't render. Section headers in Title Case. An unusable row is disabled
  when it applies but can't be used now, and hidden when it doesn't apply to the current strategy or mode.
- **Install and Remove.** Row 1: status left, one button right ("Install Camera Extension…" or "Update…"). Row 2, only when
  installed: "Remove Camera Extension…".
- **Destructive.** Last section of the last pane, alone, `role: .destructive`, confirmation first.
- **Restore Defaults.** Bottom trailing of its pane, outside any section.
- **Status from a request.** Show the result beside the control, only until the next state change. Never in a footer.

### Help text

| Length | Where | Rule |
|---|---|---|
| A few words | Subtitle under the label | Current state or consequence |
| One sentence | Section footer | `UISettingsFootnote` at `.uiMeta`, one per section, at most two lines at 580 pt (about 180 characters) |
| Anything longer | Info button | `info.circle`, `.borderless`, 24 × 24, trailing in the row or section header. Opens a `.popover` 320 wide at `.uiRow`, `.fixedSize(horizontal: false, vertical: true)`, selectable, with an accessibility label "About \(row)" |
| Reference | Help window | Crash recovery internals, GPU route explanations, fragment timing |

`.help()` may repeat a short hint, but is never the only home for text: it needs a pointer and a pause, so keyboard and
VoiceOver users never get it. Build one `UISettingsInfoButton(title:text:)`, and use it everywhere.

Current footers, for reference:

| Footer | Becomes |
|---|---|
| `:81` App (2 unrelated sentences) | Info button; drop the icon legend to Help |
| `:204` Format (3 sentences) | "Records the camera original, without LUT or effects." plus info button |
| `:233` Crash Recovery (5 sentences) | "Recovery keeps the original." plus info button |
| `:672`, `:673` Monitor | Info buttons in whichever pane takes these rows. A pane must contain a control |
| `:697` Video compatibility (4 sentences) | "Applies to the next capture or take." plus info button |
| `:308` Sync explanation | Subtitle on the row, 1 short line, plus info button |

### Tests and renders

Replacing tabs changes the `settings-window-*` render and any UI test that finds tabs by name. The blank tab bar in the
fixture goes away with it. Render each section at 820 × 620 and at the 460 minimum.

---

## 9. Accessibility

### Contrast (measured, light mode unless noted)

| Element | Ratio | Target | Action |
|---|---|---|---|
| "Recording", red, 12 pt semibold | 3.84 (dark 4.04) | 4.5 | V6 |
| White on ON AIR, 11 pt bold | 3.94 | 4.5 | V8, reaches 5.75 |
| "0 dropped" | 3.93 | 4.5 | V6 |
| `.secondary` on strip, sidebar card, Settings | 3.9–3.95 | 4.5 | System semantic color; accept for metadata, never for a state word. Increase Contrast raises it |
| OVER lamp, unlit | 1.34 (dark 1.49) | 3.0 | It's a button: `LevelMeterView.swift:671` stroke and text at `.secondary` |
| Inspector effect digits | 1.87 | | Deleted by V12 |
| Disabled LUT chip | 1.87 (dark 2.25) | Exempt | |
| Status bar `.secondary` | 4.61 | 4.5 | Pass |
| Orange on overlay, over white video | 4.52 | 4.5 | Pass, narrowly |
| Sidebar section header | 2.10 | | Excluded: system style in an inactive window |

### VoiceOver (from the `accessibility-*.tsv` files)

| Gap | Evidence | Fix |
|---|---|---|
| Symbols read aloud with wrong words | `AXImage "Move"` (folder glyph), `AXImage "Selected"` (check before "0 dropped") | `.accessibilityHidden(true)` in `gutterIcon` and on the drops symbol |
| Zoom menu has no name | Two blank `AXMenuButton` rows | `.accessibilityLabel` on a `Menu` isn't reaching the button: label the Menu's content `Label`, or use `.accessibilityRepresentation`. Same cause below |
| "Picture signal" not applied | `AXMenuButton "Output · 1080p 29.97"`, twice | As above; expose once with value |
| "More" unscoped | `AXMenuButton "More"`, twice | As above: "More for Camera 1" exists in code but doesn't arrive |
| Unnamed switch | Camera 2: `AXStaticText "Processing"`, then an `AXCheckBox` with no title and value 1 | `.accessibilityLabel("Effects for \(camera.name)")` on the toggle |
| Record, Pause, chips unscoped | Two "Stop Recording", two "Pause" | Pass the name: "Stop Recording, Camera 1", "Pause Camera 1" |
| Chip names are values | `AXCheckBox "1080p"` | The new menu items read "Output size, 1080p" |
| Badges unknown role | `AXUnknown "2160p 59.94"`, "On air", "Recording 12:31" | `.accessibilityElement(children: .combine)`, not `.ignore`, on text-only badges |
| Meter has no reading | `AXUnknown "Camera 1 audio"` | `.accessibilityValue("Left −5.7, right −6.4 dBTP")`, refreshed about once a second |
| Selection not exposed | `UICameraPictureView` | `.accessibilityAddTraits(camera.selected ? .isSelected : [])` |
| Case | "On Air" | See copy pass |

The 8 blank `AXButton` rows in `accessibility-problems.tsv` are scroll bar parts next to `AXValueIndicator`, not app controls.
Good already: tool buttons carry on or off values, and cameras have a Cut action by name.

### Hit targets

| Control | Size | Action |
|---|---|---|
| Tool settings chevron | 16 × 24 | Under the 24 floor in width. Keep, since V9 reveals it per tool; make it a 20 pt slot |
| Effects switch | Mini | `.controlSize(.small)` (V5) |
| Status segment | 22 high | 24 (V18) |
| Sidebar Add, Show in Finder; inspector refresh | About 16 | `.frame(minWidth: 24, minHeight: 24).contentShape(Rectangle())` |
| Compact record, ⋯, chevron, picture buttons | 24 or larger | Pass |

### Motion, transparency, contrast, color

- **Reduce Motion is not read anywhere.** `UICameraColumn.swift:239` animates the reveal and `TileToolbar.swift:691` pulses a
  symbol. Read `accessibilityReduceMotion`: no animation on the reveal, and `isActive: pulses && !reduceMotion`.
- **Reduce Transparency.** Only system materials and opaque-enough capsules; correct as `UIStyle.swift:3-7` states.
  Don't add glass.
- **Increase Contrast** is read once (`UICameraColumn.swift:598`). Add it to the tool on state and the overlay capsule
  (`opacity` 0.72 to 0.85).
- **Color-only meaning.** Tally has words and rings. The gaps: tool on state (V9), compact OVER lamp (V30), and the
  shot timer gradient, which needs its existing `Shot 8 s` text kept. Meter zones also have a scale.

---

## 10. Worth keeping

The strip's single left edge (H14). The dark capsules over video. The tool popovers' two-column layout. Native `NSMenu`
rows. The template menu bar icon with knocked-out badges, which stays clear in `menubar-icons`. `UIFirstFitting` as a
technique. The confirmation rules for Stop. Don't let this round disturb any of them.

---

## 11. Against earlier decisions

**Confirmed fixed, no regression:** N1 symbol-plus-label tones, N2 gray disabled record, N3 system toggles, N5 failed in
orange, N13 single selection ring, H3 overlay metric (one exception, V33), H5 and H6 fitting, S1 Auto needs a strategy,
S3 Couldn't start, F1 column minimums, F9 and F11 Diagnostics.

**Regressed or never landed:**

| Decision | State now | Finding |
|---|---|---|
| P1-11: Auto in one control | Three at once | V4 |
| S6: subtitle only what the status bar doesn't say | Word for word | V17 |
| D8 and PLAN: red limits; colored text only if large enough | Red text at 12 pt; new red waveform | V6 |
| r3: menu bar budget of about 14 rows | 18 in Program | V19 |
| F4: panes fit their content | Heights drifted; two panes cut at the fold | Section 8 |
| F5: Monitor pane is explanation only | Still no controls, and longer | Section 8 |
| F13: title-case headers | Two sentence-case headers | Section 5 |
| S13: sentence case outside the picture | "On Air" for VoiceOver | Section 5 |

**Overturned, with reasons:**

| Decision | New | Why |
|---|---|---|
| F4: window resizes per pane | One stable window with a sidebar | Ten sections, and in-pane changes would move controls |
| F3: toggle stays "Processing" | "Effects" | One noun; "Processing" is also a timing in Diagnostics |
| PLAN: visible title "Ultracam" | Title kept for the system, not drawn | It costs 100 pt and repeats the status bar |

---

## 12. Top ten

1. **V1:** separate Stop Recording from Stop All Cameras by label, glyph, position and a red dot that survives a non-key window.
2. **V2:** fix the selection ring to blue, since a Red system accent makes it read as on air.
3. **V3:** never truncate the REC pill at minimum width.
4. **V4:** one labeled Auto control in the toolbar.
5. **V5:** replace the four chips with one Effects menu and a fixed output row.
6. **V6 and V8:** bring Recording, drops and ON AIR to 4.5:1; 14 red marks become 9.
7. **V9:** one tool button at rest, full bar on hover, chevrons on demand.
8. **V10 and V11:** one clock per camera, fixed row heights, no picture jump on Record.
9. **V14:** fix the real strip header and give the fixtures a camera-control store.
10. **Section 8:** a sidebar Settings window at one stable size, with one-sentence footers and info buttons.
