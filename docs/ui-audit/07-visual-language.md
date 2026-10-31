# 07 · Visual language: symbols, type and scannability

Date: 2026-10-30. Review only: no source changed. Code reviewed at `2a99179`. Follows [README](README.md) revision 4, which wins where this file and it disagree. Layouts are the plan's. This file decides how each thing is drawn.

**The test for every row below:** it adds no click, hides no control, removes no information, and makes a state or value readable from 2 feet during a show.

**How to read the tables.** "Today" cites the current code. Where the plan rebuilds a surface, "Change" draws the planned element, not today's. Tiers rank how much reading a change saves:

| Tier | Meaning |
|---|---|
| **A** | Read every few seconds during a show |
| **B** | Read when something goes wrong, or between takes |
| **C** | Setup, closed during live work |

**Ranked order of work:**

1. Signal badge and dropout count on the strip
2. Record row, one recording state in every state
3. Status bar segments as typed pieces
4. Output row: state glyph, value chips, LUT On or Off
5. Toolbar: red dot, Auto and Hold words, one Cut symbol
6. Picture pills, tally glyphs and placeholders
7. Sidebar camera rows and drive rows
8. Monitor tool glyphs, so a warning shape means a warning
9. Menu bar rows
10. Settings tabs and Hardware rows

**Symbol check.** Run from `/tmp` on this Mac. This Mac is on macOS 27.0.1 and the deployment target is 26.0 (`Ultracam.xcodeproj/project.pbxproj:1220`), so an `NSImage` lookup alone proves nothing about 26. Each name was also read from the system's `name_availability.plist`. Every symbol named in this file exists and was introduced in macOS 15.0 or earlier, so all are available on 26.0. Failed lookups, all rejected: `play.badge.automatic`, `anchor`, `video.badge.exclamationmark`, `gpu`, `hdmi`, `tally`. No symbol used by today's code failed.

**Not verified.** The lookup proves a symbol exists, not that it reads well. Nothing here was built or rendered. Items marked *confirm in render* need a look at real size before they're trusted.

**Mockup.** `docs/mockups/r5/index.html` follows this file. Link speed, device temperature and memory card state were drawn in an early version and removed, because the plan doesn't put them on the row. Thunderbolt speed isn't in the SDK, temperature belongs in the expanded row, and media appears only when it's a problem.

---

## 1. Symbol map

One symbol per noun, everywhere. State variants are listed with their noun. "Same" means today's code already does this.

| Noun | Symbol | Today, if different |
|---|---|---|
| Camera (the source you add and run) | `video`; `video.fill` while on air in menus | Same. Inspector and Diagnostics empty states use `video.slash` |
| No cameras yet | `video.badge.plus` | `video.slash` (`UIMainWindow.swift:69`) |
| No signal, and a dropout count | `video.slash` | Same for the placeholder. Dropouts have no symbol |
| Virtual camera, in use | `video.badge.checkmark`, green | Same |
| Virtual camera, not in use | `video.badge.ellipsis`, gray | `video.badge.checkmark`, gray, which shows a check for "not in use" |
| Program, and On air on Program | `tv` | Same in the status bar. Also `dot.radiowaves.left.and.right` on the strip (`UICameraColumn.swift:1101`); retire it |
| ISO tally | `video.fill` | None |
| Cut | `arrow.left.arrow.right` | Also `arrow.right.circle` (`UIProgramView.swift:94`) and `tv` (`UIMenuBar.swift:405`, `:529`) |
| Auto (switching) | `wand.and.sparkles` | Also `wand.and.stars` (`UIMenuBar.swift:409`) |
| Start with camera apps | `bolt.badge.automatic` | `wand.and.rays` (`UIMenuBar.swift:375`), a third wand |
| Hold | `pin`, off; `pin.fill`, on | None. `pause` is taken by recording, and a raised hand means something else in a meeting |
| Shot time | `timer` | None |
| Layout: Single | `rectangle` | Same |
| Layout: Side by Side | `rectangle.split.2x1` | Same |
| Layout: Program View | `sidebar.squares.trailing` | `tv` (`UIPresentation.swift:26`, from 06 V16) |
| Layout: Four Up | `square.grid.2x2` | Same |
| Inspector | `sidebar.trailing` | Also `sidebar.right` (`UIMenuBar.swift:586`) |
| Expand or collapse a strip | `chevron.right`, `chevron.down` | Same |
| Collapse all strips | `rectangle.compress.vertical`, `rectangle.expand.vertical` | Same |
| More | `ellipsis.circle` | Same |
| Add | `plus` | Same |
| Record, the action | `record.circle` | Same |
| Recording, the state | Drawn 7 to 8 pt red dot | Same |
| Stop, in menus and buttons | `stop.fill` | Also `stop.circle` (`UIMenuBar.swift:387`, `:390`, `:519`) |
| Paused | `pause.fill`, orange | Same. Menu row uses `pause` (`UIMenuBar.swift:522`) |
| Resume, Start | `play.fill` | Same. Menu row uses `play` (`UIMenuBar.swift:522`) |
| Saved | `checkmark.circle.fill`, green | Same |
| Take | `film` | Same |
| Format (codec) | `film.stack` | None |
| Timecode | `clock` | None |
| Folder, and Show in Finder | `folder` | Also `magnifyingglass` (`UISettings.swift:150`, `UISessionSidebar.swift:194`), which reads as search |
| Drive | `externaldrive` | Same |
| Drive low or full | `externaldrive.badge.exclamationmark`, orange | `exclamationmark.triangle.fill` replaces the drive (`UISessionSidebar.swift:321`), so the row loses its noun |
| LUT | `cube` off; `cube.fill` on | `cube` on one menu row only |
| Effects | `square.stack.3d.up` | Same, on one menu row |
| Effects off | `square.stack.3d.up.slash` | None |
| Updating output | `arrow.triangle.2.circlepath` | Same |
| Picture settings, signal stage | `camera.filters` | Same |
| Preview hidden | `eye.slash` | Same |
| Show preview | `eye` | Same |
| Freeze | `snowflake` | Same |
| Clean View | `rectangle.dashed`; `rectangle.inset.filled` while on | Same in the app. MonitorKit's detached bar uses `eye.slash` and `eye` (`TileToolbar.swift:48`, `PictureControls.swift:595`), a collision with Preview hidden |
| Detach | `arrow.up.forward.square` | Same |
| Monitor tools | `slider.horizontal.3`; `slider.horizontal.below.square.filled.and.square` with tools on | Same |
| Zebra | `circle.lefthalf.striped.horizontal` | `line.diagonal`, which reads as "disabled". *Confirm in render* at 13 pt on the dark capsule |
| False Color | `paintpalette` | Same |
| Clip Indicators | `sun.max.trianglebadge.exclamationmark` | `exclamationmark.triangle`, the warning shape in white. *Confirm in render:* its badge must not read as a warning at 13 pt. If it does, use `arrow.up.and.line.horizontal.and.arrow.down` |
| Focus Peaking | `scope` | Same |
| Guides | `squareshape.split.3x3` | Same |
| Scopes | `waveform.path.ecg` | Same, and it stops being a Settings tab icon |
| Input, capture device | `cable.connector` | Same on the placeholder |
| Input disconnected | `cable.connector.slash` | Same |
| Camera body | `camera` | None |
| Camera Control | `camera.aperture` | Same |
| Wi-Fi link | `wifi`; lost, `wifi.slash` | Same |
| Battery, percent known | `battery.100percent`, `.75percent`, `.50percent`, `.25percent`, `.0percent` | None |
| Battery, unit is minutes | `minus.plus.batteryblock` | None. Never a level glyph for minutes (README section 8) |
| Temperature, overheating | `thermometer.high`, orange | None |
| Sign-in | `key.fill` | Same |
| Needs a look | `exclamationmark.triangle.fill`, orange, always filled | Also the outline `exclamationmark.triangle` (15 sites, 2 of them the Clip symbol) and `exclamationmark.circle.fill` (`UIInspector.swift:207`, `UISettings.swift:333`) |
| Information | `info.circle` | Same |
| Retry, refresh | `arrow.clockwise` | Same |
| Audio | `waveform` | Same. Always gray (06 V6), so `UICameraColumn.swift:674` stops turning it red |
| Microphone reminder | `mic.slash` | None |
| CPU, GPU, memory | Words | No symbol: see section 5 |
| Diagnostics | `stethoscope` | None |
| Settings | `gearshape` | Same |
| Open window | `macwindow` | Same |
| Copy | `doc.on.doc`; done, `checkmark` | Same |
| Install or update extension | `video.badge.plus`, `arrow.down.circle` | Same |
| Restart needed | `arrow.clockwise.circle` | Same |
| Alerts | `bell` | None |
| Settings tab: General | `gearshape` | Same |
| Settings tab: Hardware | `cable.connector` | New tab |
| Settings tab: Virtual Cameras | `video.badge.checkmark` | Camera, `video` |
| Settings tab: Recording | `record.circle` | Same |
| Settings tab: Audio | `waveform` | New tab |
| Settings tab: Switching | `arrow.left.arrow.right` | Switcher, `tv` |
| Settings tab: Alerts | `bell` | New tab |
| Settings tab: Advanced | `gearshape.2` | `slider.horizontal.3`, which belongs to monitor tools |

**Program and Virtual Camera are two nouns.** `tv` means Program, the switched picture. `video.badge.checkmark` means a virtual camera a meeting app is using. Ultracam · Program is a virtual camera, so its row in Virtual Cameras uses the virtual camera symbol, and its switching state uses `tv`.

**Color rule for every symbol.** The symbol carries the tone and words stay in a label color. Battery low, drive low, body lost and no signal are orange, never red. The only filled red is the tally pill, darkened 20% (06 V8). A red dot only ever means recording.

---

## 2. Type levels

The scale in `UIStyle.swift:34-53` stands. Two tokens are new, and the scale now reaches Settings, the inspector, popovers and Diagnostics (06 section 7).

| Level | Token | Size | Use | Color |
|---|---|---|---|---|
| 1 | `uiTally` **new** | 12 pt bold | ON AIR, ISO, NEXT, PROGRAM pills | White or black on the pill |
| 2 | `uiClock` | 17 pt semibold, mono digits | Strip recording clock | Primary |
| 3 | `uiPlaceholderTitle` | 15 pt semibold | Placeholder title | White 90% |
| 4 | `uiTitle` | 13 pt bold | Camera name, popover title | Primary |
| 5 | `uiValueStrong` **new** | 12 pt semibold, mono digits | The number you came for: time left, shot time, dropouts, session clock | Primary |
| 6 | `uiValue` | 12 pt, mono digits | Other values | Primary |
| 7 | `uiRow`, `uiRowEmphasis` | 12 pt | Row text, record state, problem title | Primary |
| 8 | `uiMeta` | 11 pt | Labels, units, footers, captions | Secondary |
| 9 | `uiOverlay` | 11 pt semibold | Text on the picture | White |
| 10 | `uiBadge` | 10 pt semibold | Chips: the floor | Primary, or secondary when neutral |

**Value and unit.** The number takes level 5 or 6, the unit takes level 8. "1 h 52 m" draws 1 and 52 strong, h and m small and dim, sharing a baseline. Label text sits at level 8 beside a level 5 or 6 value, never the other way round.

**Clocks and counts** always use monospaced digits, so digits don't move as they change.

**Raw styles to replace**, from 06 section 7: `.subheadline` in the status bar and sidebar, `.caption` prose in Settings, inspector, Diagnostics and Camera Control. `.caption` stays on the menu bar card, which is a compact scale. Add `uiCompactOverlay` there, as 06 says.

---

## 3. Reusable components

### Build

| Component | What it draws | Used at |
|---|---|---|
| **`UISymbol`** | One enum of symbol names, with state variants as functions: `UISymbol.virtualCamera(inUse:)`, `.lut(on:)`, `.hold(on:)`. It enforces section 1. MonitorKit can't import it, so `TileToolbar.swift:39` keeps its own list and takes the same Zebra, Clip and Clean names | Every `systemName:` and `systemImage:` in `Sources/App`, and `row(symbol:)` in `UIMenuBar.swift` |
| **`UIStateGlyph`** | One small glyph for a state: recording (red dot), paused (`pause.fill`), warning (triangle), healthy (green dot), starting (`ProgressView`), inactive (gray hollow dot). A warning is never just an orange dot, so color is never alone | Replaces `Circle()` fills at `UICameraColumn.swift:265`, `:1184`; `UIStatusBar.swift:98`, `:317`; `UISessionSidebar.swift:61`, `:152`; `UIMenuBar.swift:762`; `UIStyle.swift:123`; and the `circle.fill` at `UIFeedSettingsMenu.swift:38` |
| **`UIValue`** | Value plus unit on one baseline, with one accessibility label. Takes parts, not a joined string. Use `HStack(alignment: .firstTextBaseline, spacing: 2)` | Time left, shot time, clocks with units, sizes, rates, `UIMonitorSlider`, `UISettingsSlider`, Resources |
| **`UIIconValue`** | Symbol, then `UIValue`, with `.help` and an accessibility label always required. The value keeps its width and the label truncates first | Replaces `collapsedLabel` (`UICameraColumn.swift:1171`), `noteLine` (`:933`) and the drop line (`:916`). Sidebar rows, status bar pieces, recording popover, Takes row |
| **`UIValueChip`** | A read-only capsule: `UIBadge` plus an optional leading symbol. Extend `UIBadge` rather than adding a type | Format on the folder row, output values, Auto and Manual on cut rows, assigned camera on Hardware rows |
| **`UICountChip`** | Symbol plus a count, shown only above zero | Dropouts on the signal badge and sidebar row |
| **`UILevelBar`** | A 4 pt capsule, two sizes: 28 pt mini and full width. Gray fill, orange when low, and always next to a number | `UIDriveRow` (`UISessionSidebar.swift:328`), strip folder row, shot time in the status bar, full width in the Recording section |
| **`UIBatteryGlyph`** | Picks the level symbol by bucket (88, 63, 38, 13) and shows the percent. With a minutes unit, shows `minus.plus.batteryblock` and "78 min". With no known unit, shows the raw value and no warning. Orange below the warning level | Sidebar camera row, Hardware row, Camera Control sheet, camera submenu |
| **`UIProblemRow`** | Triangle, title at `uiRowEmphasis`, reason at `uiMeta`, one action button. One view, same height everywhere the strip needs | Replaces `UICameraColumn.swift:688-707`, `UISessionSidebar.swift:207-219`, `UIInspector.swift:240-246`, `:316-325`, `UIStatusBar.swift:330-335`. Attention, strip problem row, inspector |
| **`UIPictureStatePill`** | The REC pill and all its states, in one view, with a compact size | Merges `UICameraColumn.swift:260-291` and `UIMenuBar.swift:756-769` |

### Reuse as they are

| Today | Why it's right | Next step |
|---|---|---|
| `UIBadge` (`UIStyle.swift:112`) | Tone on a dot, words in label color | Gains a symbol |
| `UIRecordButton` (`UIStyle.swift:162`) | Round to square is a clear, shape-based state | None |
| `UITallyBadge` (`UIStyle.swift:138`) | Fixed height, strong word | Gains a glyph and `uiTally`; fix the VoiceOver text (06) |
| `UISidebarRow` (`UISessionSidebar.swift:296`) | Tone on the symbol, not the words | Base for Virtual Camera rows |
| `UIDriveRow` (`UISessionSidebar.swift:314`) | Name, value, bar, full accessibility value | Takes `UIValue` and `UILevelBar` |
| `gutterIcon` (`UICameraColumn.swift:649`) | Keeps text in one column | Add `.accessibilityHidden(true)` (06 section 9) |
| `UIDiagnosticsRow` (`UIDiagnostics.swift:57`) | Triangle only when something's wrong | None |
| Popover header (`UIMonitorTools.swift:311-326`) | Symbol, title, one subtitle, switch: the best header in the app | Use it for the status popovers' titles |
| Menu `.badge` (`UICameraColumn.swift:807`) | Trailing value in a native menu row | Use it for property rows in the camera badge menu |
| `UIFirstFitting` (`UIStyle.swift:220`) | Drops detail by width, without re-measuring | Use it for every density choice below |

**Code note.** Typed elements need typed data. `UIStatusBar.swift:142-143` parses display strings by splitting on " · ", which breaks once those strings change. Add structured fields to `UIStatusSegment` and `UICameraPresentation` (output values, time left, drops as `Int`), and keep the existing strings for `.help` and VoiceOver, so the tooltips lose nothing. `UIFormatLabels.shortFormat` (`UISessionBridge.swift:60`) parses a different string and isn't affected.

---

## 4. Surfaces

### Toolbar

File: `UIToolbar.swift`.

| Tier | Element | Today | Change |
|---|---|---|---|
| A | Record, rolling | `stop.fill` in a red filled button: "Stop All (2) 12:31" (`:202`, `:212`) | `UIStateGlyph` red dot, then "Stop 2 Recordings" in label color. The dot survives a non-key window; the fill didn't. The clock moves to the status bar (README). Keep the words: this ends something |
| A | Cut button, on air | Red prominent fill (`:138`), plus a dot | Red dot, bold number and name, selected glass state. No fill. The dot is the tally |
| A | Cut button, next | Green dot and capsule outline (`:147`) | Keep both, and add the word "Next" through `UIFirstFitting` when it fits. Outline plus dot means it isn't color alone |
| A | Camera number | Bold mono digit (`:170`) | Keep. It's the shortcut digit and the fallback under 1100 pt |
| A | Auto | Tinted toggle, `wand.and.sparkles` (`:112-113`) | `wand.and.sparkles` plus "Auto On" or "Auto Off", fixed width. The word carries the state, because the tint goes gray in a non-key window |
| A | Hold | Not in the toolbar | `pin` plus "Hold" off, `pin.fill` plus "Hold" on, and dimmed when Auto is off |
| B | Start Cameras | `play.fill` and words (`:27`) | Same. Keep words |
| B | Record, idle | `record.circle`, "Record All" (`:193`) | Same, in label color. Red appears only once rolling |
| C | Layout picker | `tv` segment (`UIPresentation.swift:26`) | `sidebar.squares.trailing` |

Icon-only controls here, all with help and accessibility labels today: layout segments, collapse, inspector. Keep.

### Picture overlays

File: `UICameraColumn.swift`.

| Tier | Element | Today | Change |
|---|---|---|---|
| A | ON AIR | Word only, 11 pt, red fill (`UIStyle.swift:143`) | `tv` plus ON AIR at `uiTally`, on the darkened pill |
| A | ISO | Doesn't exist yet | `video.fill` plus ISO. The glyph separates two red pills from across a desk |
| A | NEXT, PROGRAM | Word on green or outlined (`UIStyle.swift:147`) | Same forms, at `uiTally` |
| A | REC pill | "● REC 12:31" (`:266`) | "● REC" at rest, with digits only when the strip is collapsed (README). Never truncates. One `UIPictureStatePill` |
| A | Paused pill | `pause.fill` and "Paused 12:31" (`:273-274`) | Same, through the shared pill |
| A | No signal pill | Whole pill orange, including words (`:284`) | Orange triangle, white "REC · no signal". The color moves off the words |
| A | Number pill | Program mode only (`:189`) | Always with 2+ cameras, because the mode is retired. Strong digit in its own capsule, so it reads as the Cut digit |
| A | Stage notice | "Source · before LUT" in one string (`:343`) | `camera.filters`, "Source" strong, "before LUT" dim. This says the picture isn't what's going out |
| A | Monitor tools at rest | Faint 24% white fill (`UIMonitorTools.swift:170`) | Enabled tools only, with white 0.9 fill and black glyph (06 V9), so "on" is readable without looking for it |
| B | CPU copy pill | "CPU copy · Ingest · 1234" (`:247`) | Orange triangle, "CPU copy", "Ingest" dim, mono count. It's a warning, so it should look like one |
| B | Compatibility pill | "Compatibility conversion · Recording · 1234" (`UIPresentation.swift:82`) | Orange triangle, "Compatibility conversion", "Recording" dim, mono count. Both pills sit beside REC, which must not truncate, so they yield first |
| B | Signal menu | "Output · 1080p 29.97" (`:360`) | "Output" dim, value strong |
| B | Camera settings overlay | "ISO 800 · 1/60 · f/2.8", one string (`UIControlPresentation.swift:24`) | One cell per field: small dim label, mono value. The compact three-field fallback stays |
| C | Timecode | Mono text on hover (`:227`) | Same. It reads as timecode without help |
| C | View controls | Icon-only (`:367-389`) | Same. Each has help and a label |

### Picture placeholders

File: `UICameraColumn.swift:121-166`, drawn by `UIPicturePlaceholder` (`:551`).

| Tier | State | Today | Change |
|---|---|---|---|
| A | No signal | `video.slash`, gray, title (`:129`) | Keep the symbol, gray, so the cause reads by shape. Title row: orange triangle, "Signal lost", mono time. Sentence stays |
| A | Input disconnected | `cable.connector.slash`, gray (`:140`) | Same treatment: gray cause symbol, orange triangle on the title row |
| B | Unsupported format, Couldn't start | Outline triangle, gray (`:132`, `:145`) | `exclamationmark.triangle.fill`, orange, large. No second triangle |
| B | No input selected | `cable.connector` (`:135`) | Same symbol, plus the orange triangle on the title row |
| B | Stopped | `video` (`:150`) | Same, gray. Nothing wrong, so no orange |
| B | Starting | Progress (`:126`) | Same |
| B | Preview hidden | `eye.slash` (`:158`) | Same. Output continues, so no orange |
| B | Updating output | Pill with `arrow.triangle.2.circlepath` (`:163`) | Same |
| C | Compact detail | `.caption` (`:579`) | `.uiMeta` (06 section 7) |

### Expanded strip

File: `UICameraColumn.swift`. Rows follow the plan: header, record, folder or problem, output, meters.

| Tier | Element | Today | Change |
|---|---|---|---|
| A | Signal badge, live | Green dot, format, chevron (`UIFeedSettingsMenu.swift:37-43`) | Same, with `UICountChip` (`video.slash` and count) when dropouts are above zero, at `uiBadge`. Help says "5 signal dropouts since Start" |
| A | Signal badge, problem | Orange dot and words | Orange triangle and words. Dot and triangle mean different things now |
| A | Signal badge, stopped | Gray dot, "Stopped" | `UIStateGlyph` inactive. Secondary words |
| A | Record state word | Red text (`:896`) | Red dot plus "Recording" in primary (06 V6) |
| A | Clock | `uiClock` (`:900`) | Same. Paused: secondary, as today |
| A | Dropped | `checkmark.circle.fill` green or triangle orange, "0 dropped" secondary (`:917-919`) | Same glyphs. Count at `uiValueStrong`, word at `uiMeta`, and primary above zero |
| A | Folder row | Path, then "· 1 h 52 m left" (`:1002-1005`) | `folder`, path dim with last component primary, then `UILevelBar` mini, `UIValue` "1 h 52 m", dim "left". The full path stays in help |
| A | Format on the folder row | Doesn't exist yet | `UIValueChip` "HEVC 4:2:2", plus dim "~64 Mb/s" |
| A | Format fallback | Doesn't exist yet | Orange triangle, "ProRes 4444 → ProRes 422 HQ" in label color (README section 9) |
| A | Time left low | Same weight as any other | `externaldrive.badge.exclamationmark` orange before the value |
| A | Problem row | Two shapes (`:688`, `:699`) | `UIProblemRow`, replacing the folder row at the same height |
| A | Cut slot | `Label("Cut")` (`:1093`) | Same symbol, fixed 64 pt |
| A | Cut slot, on air | Doesn't exist as a slot | `tv` plus "On air", plain gray text, so the pill stays the only filled red |
| A | Output line | "Ultracam · Camera 1 · In use" (`UIPresentation.swift:654`) | State glyph, then separate values: "1080p", "4:2:0 8-bit", "29.97" as `uiValue`, then "In use" in primary or "Not in use" in secondary. Under 440 pt: "1080p 29.97" and the word |
| A | LUT toggle | Chip with a checkmark that changes its width (`UIStyle.swift:201`) | `cube.fill` plus "LUT On", or `cube` plus "LUT Off", fixed width, same pattern as Auto. Disabled with no LUT loaded. This changes the mockup's "✓ LUT" |
| A | Effects menu | Doesn't exist yet | `square.stack.3d.up`, "Effects", count "3 of 3". Effects off: `square.stack.3d.up.slash`, "Effects Off" |
| A | Updating | Spinner and words (`:1033-1035`) | Same |
| B | Audio gutter | Red while recording (`:674`) | Always gray |
| B | Meter | MonitorKit's readout | Same. See section 5 |

**Record row by state.** Sentences stay where a problem needs an action.

| State | Glyph | Line 1 | Line 2 | Action |
|---|---|---|---|---|
| `ready` | Record button | Ready to record | "Camera original, no LUT or effects" (the note from the removed footnote) | None |
| `recording`, `updating` | Stop button, red dot | Recording | Clock | Pause |
| `paused` | Stop button, `pause.fill` | Paused | Clock, secondary | Resume |
| `recordingNoSignal` | Stop button, triangle | Recording, no signal | Clock. The two pieces today share one string (`UIPresentation.swift:597`) | Pause |
| `finishing` | Spinner | Finishing… | Sentence stays | "Saving…" → "Finishing…" (06) |
| `saved` | `checkmark.circle.fill` | Saved | File name, then `UIValue` duration, split from one string (`UIPresentation.swift:602`) | Show in Finder |
| `noFolder` | Triangle | No folder | Sentence stays | Choose Folder… |
| `failed` | Triangle, first, also while rolling (N1) | Recording failed, or Disk full | Sentence stays | Choose Folder…, Show in Finder, Details |
| `waiting` | Dimmed button | Can't record yet | Sentence stays | Choose Folder… when needed |
| `stopped` | Dimmed button | Not recording | Sentence stays | None |

### Collapsed strip

File: `UICameraColumn.swift:1126-1206`.

| Tier | Element | Today | Change |
|---|---|---|---|
| A | Recording | Dot and clock (`:1184`) | Same, with `uiValueStrong` |
| A | No signal | "12:31 · no signal", one secondary string (`:1189`) | Triangle, clock, "No signal" in primary as separate pieces |
| A | Paused | `pause.fill` and clock (`:1192`) | Same, clock in primary |
| B | Saved, No folder, Failed, Waiting, Stopped, Ready | `collapsedLabel`, words in secondary (`:1174`) | `UIIconValue`. Problem words go to primary, because the tone rule says label color, and problems shouldn't be dimmer than rest states. Stopped and Ready stay secondary |
| B | LUT unavailable | Icon-only triangle (`:1137`) | Same. Has help and a label |

### Program View

File: `UIProgramView.swift`. The cut bar and Recent Cuts go (README).

| Tier | Element | Today | Change |
|---|---|---|---|
| A | Tile Cut | `arrow.right.circle` (`:94`) | Full-width button with `arrow.left.arrow.right` and "Cut" |
| A | Tile tally | `UIBadge` (`:89`) | `tv` plus "On air" in the Cut slot, same height, so nothing moves |
| A | Program title pill | `tv` and "Ultracam · Program" (`:49`) | Same symbol. "Ultracam" dim, "Program" strong |
| A | Lower pills | "Camera 1 on air" repeats the tally (`:58`) | "Camera 1", plus format as a mono pill (06 V22) |
| B | Format mismatch pill | Full sentence on the picture (`:65`) | `arrow.triangle.2.circlepath` and "Formats converted". The sentence moves to help. It's already in the Program popover (`UIStatusBar.swift:280`) |
| B | Tile number and name | `.headline` (`:85-86`) | Same as the picture's number capsule |

### Left sidebar: session board

File: `UISessionSidebar.swift`. All rows below are planned rows, drawn from today's parts. Body-side data (model, battery, link) waits on README section 8. A build with no body data draws one line, not an empty one.

| Tier | Element | Today | Change |
|---|---|---|---|
| A | Attention row | Banner and section rows (`:26`, `:205`) | `UIProblemRow`, pinned. Extension rows keep their nouns as the leading symbol where nothing's wrong yet: `video.badge.plus`, `arrow.clockwise.circle`, `arrow.down.circle` |
| A | Camera row, line 1 | Dot, name, badge (`:60-70`) | `UIStateGlyph`, name, then a filled ON AIR or ISO chip |
| A | Camera row, line 2 | Planned as "2160p 59.94 · 4 dropouts · UltraStudio 12G" | "2160p 59.94" at `uiValue`, `UICountChip` for dropouts, `cable.connector` plus device name at `uiMeta`. Device name truncates first |
| A | Camera row, line 3 | Planned as "Sony FX3 · connected · 78%" | `camera` and "Sony FX3", `wifi` and "Connected" at `uiMeta`, `UIBatteryGlyph`. Lost shows `wifi.slash`, orange, with "Disconnected" in primary |
| A | Virtual Camera row | Two lines (`:107`, `:136`) | One line: `UISymbol.virtualCamera(inUse:)`, name, "In use" trailing. Not-in-use names in secondary |
| A | Virtual Cameras header | Doesn't exist yet | While collapsed, shows "1 of 3 in use" trailing, so collapsing hides no state |
| A | Recording drive row | Planned as "Takes · 8TB" and "1 h 52 m left" | `folder` and "Takes", `externaldrive` and "8TB", then `UIValue` trailing, `UILevelBar` full width below |
| A | Drive cameras | Planned as "Camera 1, Camera 2" | Number capsule and name for each camera, with the number matching the toolbar digit. If the names don't fit, `UIFirstFitting` drops to capsules alone, with names in help |
| B | Format | Text in a caption (`:155`) | Picker with `film.stack` |
| B | Caption | "Camera original · Mac Clock" | "Camera original" at `uiMeta`, `clock` and "Mac Clock" |
| B | Takes row | Planned as "5:40 PM · 12:31 · 2 cameras · 0 lost" | `film`, time, `UIValue` duration, `video` and "2", then `checkmark.circle.fill` and "0 lost", or a triangle and the count in primary |
| B | Section headers | Plain (`:96`, `:148`, `:183`) | Same: see section 5 |

Icon-only: Add Camera has help and a label (`:82-86`). The planned Show All keeps its words, so the icon-only magnifier at `:194` goes.

### Status bar

File: `UIStatusBar.swift`, text from `UIPresentation.swift:754-779`. Segments stay single buttons. Each opens its popover, in plan order. Use `.buttonStyle(.accessoryBar)` from 06 V18. Density falls back through today's `UIFirstFitting` chain (`:19-26`), and help keeps the full text at every density.

| Tier | Segment | Today | Change |
|---|---|---|---|
| A | Problem | Last, triangle and text (`:124`) | First, `.fontWeight(.medium)`, its action as a button beside it |
| A | Virtual Cameras | "Ultracam · Program · In use", one string (`UIPresentation.swift:733`) | `UISymbol.virtualCamera(inUse:)`, "Program" in primary, "In use" dim. With several: "2 of 3 in use". Help keeps device names |
| A | Program | "Camera 1 on air · Auto" (`UIPresentation.swift:761`) | `tv` and "Camera 1", `timer` and "8 s", `wand.and.sparkles` and "Auto", or `pin.fill` and "Hold", or "Manual" dim with no symbol. Override: "Auto in 4 s". Shot past the soft maximum turns `timer` yellow. The number stays the reading, so color isn't alone |
| A | Recording | "REC 2 · 12:31 · 8TB 1 h 52 m · Archive 5 h 40 m left" (`UIPresentation.swift:751`) | Red dot, "REC", count, clock at `uiValueStrong`, then one `externaldrive`, name and `UIValue` per drive with "left" on each. Narrow: the shortest drive. Paused: `pause.fill` and count |
| A | Audio | `waveform`, "Audio OK" (`UIPresentation.swift:772`) | `waveform`, "Audio" dim, "2 of 2" strong (README). A warning keeps today's words, with a triangle. Not icon-only, despite 06 V18: the plan's count is the information |
| B | Resources | "CPU 31% · GPU (video) 18% · Memory" (`:216`) | "CPU" and "GPU" dim, numbers mono, primary. README drops memory here; the popover keeps it |

Shot time gets a `UILevelBar` mini at the widest density, because it shows how close the shot is to its limit. Drives don't get one here, because time left already says it.

### Status popovers

File: `UIStatusBar.swift`.

| Tier | Popover | Today | Change |
|---|---|---|---|
| A | Recording, take row | "Recording · 12:31", then "— · — · 0 dropped · 1 h 52 m left" (`:319`, `:325`) | A `Grid` with one row per camera: state glyph, name, clock, size, rate, dropped, time left, aligned across cameras. Size and rate live here now that the strip drops them |
| B | Recording, audio | "This take so far: Audio −23.4 LUFS · max −2.1 dBTP · no overs" (`:337`) | `waveform`, "−23.4 LUFS", "−2.1 dBTP", "No overs", from `AudioTakeSummary`. Warnings keep the triangle and sentence |
| B | Recording, buttons | Words (`:345`, `:350`) | `folder` on Show in Finder. Stop All Recordings keeps its words |
| B | Virtual Cameras | "In use · 1080p 29.97" (`:267`) | Same row symbols as the sidebar, `UIValueChip` for format, words for state |
| B | Virtual Cameras reminder | Sentence (`:257`) | `mic.slash` beside the same sentence |
| B | Program | "Recent cuts" rows (`:290-297`) | Same, with `wand.and.sparkles` on the Auto chip, word only on Manual |
| B | Audio | Title, panel, sentence (`:359-369`) | `UIValueChip` per camera: "48 kHz", real channel count (B18). The sentence about virtual cameras stays |
| C | Resources | Grid (`:192-196`) | Values right-aligned, primary. Prose stays |

### Inspector

File: `UIInspector.swift`. Setup only, so Tier C throughout.

| Element | Today | Change |
|---|---|---|
| Section headers | Plain (`:34`, `:145`, `:200`, `:222`, `:304`, `:327`) | Leading symbol from section 1 on each: `cable.connector`, `camera.aperture`, `cube`, `square.stack.3d.up`, `record.circle`, `bolt.badge.automatic`. A long pane is scanned by its headers |
| Camera Control line | "Sony FX3 · Connected" (`:37`) | `camera` and name, `wifi` or `wifi.slash` and status |
| Signal | "2160p 59.94 · 4:2:2" (`:340`) | Value strong, with real format (B11) |
| Time left | `LabeledContent` string (`:301`) | `UIValue` |
| Warnings | Three styles (`:124`, `:207`, `:242`) | One triangle, or `UIProblemRow` with an action |
| Orange text | Unavailable profile (`:253`) | Triangle, label-color text |
| Remove, Rename | Words (`:49`, `:54`) | Same. No icon |
| No camera | `video.slash` (`:22`) | `video` |

### Menu bar

File: `UIMenuBar.swift`. Rows stay real `NSMenuItem`s, so typed elements are limited to an image, a title, a subtitle and a badge. No custom row views, because they would lose native keyboard navigation.

| Tier | Element | Today | Change |
|---|---|---|---|
| A | Problem row | Orange title text, disabled (`:351-354`) | Image tinted with `NSImage.SymbolConfiguration(paletteColors:)` and `isTemplate = false`, title in label color, enabled with its action (README) |
| A | Cut rows | `tv`, subtitle (`:402-405`) | `arrow.left.arrow.right`. "On air" or "Next" in an `NSMenuItemBadge`, so the row stays one line and the row budget isn't taller. Available since macOS 14 (header checked). *Confirm in render* beside key equivalents |
| A | Auto | `wand.and.stars` (`:409`) | `wand.and.sparkles` |
| A | Hold | No symbol (`:412`) | `pin`, checked when on |
| A | Record per camera | `record.circle` or `stop.circle` (`:384-390`, `:519`) | `record.circle` or `stop.fill`. Clock in the badge |
| A | Time left | Planned row | `externaldrive`, "Time left", badge "8TB 1 h 52 m". Low: `externaldrive.badge.exclamationmark`, orange |
| B | Format | Planned row | `film.stack`, badge "HEVC 4:2:2" |
| B | Pause All | No symbol | `pause.fill` |
| B | Camera submenu row | "On air · REC 12:31" subtitle (`:513`) | Same subtitle, at most two parts. A menu row can't hold chips: see section 5 |
| B | Submenu rows | `pause`, `play`, `tv`, `sidebar.right`, no LUT toggle (`:522`, `:529`, `:586`) | `pause.fill`, `play.fill`, `arrow.left.arrow.right`, `sidebar.trailing`. New LUT row: `cube`, checked when on, file name as subtitle |
| B | Effects submenu | "3 of 4" subtitle (`:542`), "1 · LUT" rows (`:537`) | `square.stack.3d.up`, count in the badge. Effect rows keep their numbers, because order matters. Values in the badge |
| B | Input submenu | No symbol (`:579`) | `cable.connector` |
| B | Card, recording pill | Own copy (`:756-769`) | `UIPictureStatePill`, compact |
| B | Card thumbnails | "1 · on air" pill covers a 74 pt picture (`:749`) | Number only. The ring and the row's badge carry the state (06 V20) |
| C | Status item | Template symbols with badges (`:139-171`) | Same: see section 5 |

### Camera badge menu

File: `UIFeedSettingsMenu.swift`.

| Tier | Element | Today | Change |
|---|---|---|---|
| B | Input row | Plain text, `.font(.caption)` ignored by menus (`:16`) | `Label` with `cable.connector`. Delete the font |
| B | Output row | "Ultracam output · 1080p 29.97" (`:17`) | `Label` with `video.badge.checkmark`, value in `.badge` |
| B | Property row | "Label · Value" (`:31`) | Label with the value in `.badge`, the pattern at `UICameraColumn.swift:807` |
| B | Control link | `wifi.slash` row (`:33`) | `camera` and body name, `wifi` or `wifi.slash` state. README: the menu names both links |
| B | Open settings | "Open camera settings…" (`:34`) | "Camera Control…" with `camera.aperture` |
| C | Accessibility | "Feed settings" (`:44-45`) | Copy pass in 06 section 5. Keep the noun Camera |

### Settings

File: `UISettings.swift`, `UISettingsDeviceSettings.swift`. Tab icons are in section 1. All Tier C.

| Tab | Element | Today | Change |
|---|---|---|---|
| Every tab | Footnotes | `.caption` (`:35`) | `.uiMeta` |
| Every tab | Warnings | Three styles (`:76`, `:333`, `UISettingsDeviceSettings.swift:24`, `:35`, `:38`) | Filled orange triangle, label-color text |
| Hardware | Device row | "Name" and fields (`UISettingsDeviceSettings.swift:11`) | Health `UIStateGlyph`, `cable.connector`, name, `UIValueChip` for assigned camera, state word. Missing unit: `cable.connector.slash`, orange, last known name |
| Hardware | Link | Doesn't exist yet | Text value on the row only for links the driver reports. A USB 3 fallback unit never appears, so no "HDMI · USB 3" chip (README section 8) |
| Hardware | Body row | Doesn't exist yet | `camera`, name, `wifi`, `UIBatteryGlyph`, `thermometer.high` only when overheating |
| Hardware | Setup block | Doesn't exist yet | `LabeledContent` facts, no icons. Advisory is a `UIProblemRow` |
| Virtual Cameras | Extension row | "Version 10 installed · 11 available" (`:383`) | `arrow.down.circle`, two mono values |
| Virtual Cameras | Status | Words | `UIStateGlyph` plus words |
| Recording | Folder table | Label and path (`:174-185`) | Camera number capsule, path. Default rows in secondary |
| Recording | File names | Mono preview (`:201`) | Same |
| Audio | Channels Shown | Planned | "Showing 2 of 8" with mono digits |
| Switching | Sliders | One string (`:553`, `:561-564`) | `UIValue`: number primary, unit dim |
| Switching | Shot timeline | Bands (`:571`) | Same |
| Alerts | Permission | Planned | `bell` or `bell.slash`, state in words, Turn On Alerts as a button |
| Advanced | Reset, Forget | Words (`:720`, `:731`) | Same. No icon |

### Camera Control sheet

File: `UICameraControl.swift`. Tier C.

| Element | Today | Change |
|---|---|---|
| Title | "Camera Control · Camera 1" (`:42`) | `camera.aperture`, title, name in secondary |
| Assigned body | `wifi` and name (`:129`) | Same, plus `UIBatteryGlyph` where the data exists. `wifi.slash` orange when lost |
| Warnings | Outline triangle, orange words (`:52`, `:60`, `:63`), orange sentence (`:174`) | Filled triangle, label-color words |
| Disconnect, Unassign, Forget Saved Sign-In | Words (`:134`, `:138`, `:144`) | Same. No icon |
| Sign-in saved | `key.fill` (`:142`) | Same |
| Property grid | Label and control (`:114-120`) | Same |
| Rescan, Refresh | `arrow.clockwise` and words | Same |

### Diagnostics

File: `UIDiagnostics.swift`. Tier C. An engineering table, and it already does the right thing: mono values, triangle only when something's wrong.

| Element | Today | Change |
|---|---|---|
| Stopped | `video.slash` (`:111`) | `video` |
| Paired rows | "3 · 7 frames" under "Capture backlog · peak" (`:125`) | Same row. First value primary, the rest secondary, so the live reading stands out. The titles stay, because they name each position |
| Loudness line | Six joined fields (`:230-237`) | A `Grid` of six cells: small label over mono value |
| Footers | `.caption` (`:142`, `:377`, `:404`, `:435`) | `.uiMeta` |
| Copy | `doc.on.doc` and words (`:40`) | Same |

### Help window

File: `UIHelp.swift`. Tier C.

| Element | Today | Change |
|---|---|---|
| Shortcuts | Secondary text at the row's end (`:54`) | Key combination in primary, on `.fill.tertiary` as a keycap chip. The system font stays, per the comment at `:53` |
| Steps, Good to Know | Sentences | Same. Update "Settings › Camera" and "Processing" with the copy pass |

### Scope and monitor tool popovers

Files: `UIMonitorTool*.swift`, `UIScope*.swift`. Tier C, except the tool bar.

| Tier | Element | Today | Change |
|---|---|---|---|
| A | Tool bar symbols | `UIPresentation.swift:59`, `UIMonitorTools.swift:24` | Zebra and Clip from section 1. Same in `TileToolbar.swift:42` and `:45`, with Clean at `:48` and `PictureControls.swift:595` |
| C | Popover header | Symbol, title, subtitle, switch (`UIMonitorTools.swift:311-326`) | Same |
| C | Slider value | Secondary (`UIMonitorToolControls.swift:195`, `UIScopeSettings.swift:269`) | Primary, because it's the value being adjusted |
| C | Unavailable note | Outline triangle, orange words (`UIMonitorToolControls.swift:254-255`) | Filled triangle, label-color words |
| C | Other notes | Outline, gray (`UIMonitorToolFalseColor.swift:300`, `FalseColorLegend.swift:362`, `:390`, `ControlSupport.swift:135`) | Filled orange triangle. These explain why a tool isn't drawn. Update the MonitorKit strings in step |
| C | Clip readout | Three mono lines (`UIScopePanel.swift:100-103`) | Same. They're already columns |
| C | Scope title | "Scope · stage" (`UIScopePanel.swift:135`) | Same |

### Alerts, dialogs and empty states

| Tier | Element | Today | Change |
|---|---|---|---|
| B | Stop, Remove, Reset dialogs | System dialogs, verbs on buttons (`UIMainWindow.swift:51`, `UISessionBridge.swift:261`) | Same: see section 5 |
| B | Rename alert | `UIRenameAlert.swift:19` | Same |
| B | No Cameras | `video.slash` (`UIMainWindow.swift:69`) | `video.badge.plus`, with Add Camera as today |
| C | No Camera Selected | `video.slash` (`UIInspector.swift:22`) | `video` |
| C | Camera Stopped | `video.slash` (`UIDiagnostics.swift:111`) | `video` |

`video.slash` now means one thing: no signal.

### Icon-only audit

Every icon-only control after this pass, each with `.help` and an accessibility label. None ends anything.

| Control | Where | Help and label |
|---|---|---|
| Strip chevron | `UICameraColumn.swift:747` | Present |
| More | `:841` | Present |
| Start, Retry in the narrow header | `:781`, `:788` | Present. The icon-only Stop at `:772` goes with the plan's move to ⋯ |
| Tool toggles and chevrons | `UIMonitorTools.swift:165-190` | Present |
| Picture settings | `UIMonitorTools.swift:203` | Present |
| View controls | `UICameraColumn.swift:396` | Present |
| Tools menu at rest | `UIMonitorTools.swift:105` | Present |
| Enabled tool glyph at rest | Planned | Must have both. One click turns it off |
| Add Camera | `UISessionSidebar.swift:82` | Present |
| Refresh devices | `UIInspector.swift:147` | Present |
| Show in Finder | `UISettings.swift:150` | Present. Symbol becomes `folder` |
| Remove band | `UIMonitorToolFalseColor.swift:201` | Label present (`:205`). Check `.help`. A band is one row of a tool's setting and comes back with one click |

Status glyphs that aren't controls, such as `video.slash` with a count, the battery, and `wifi`, carry their meaning in `UIIconValue`'s required help and accessibility label.

---

## 5. Where plain text stays, and why

**Sentences that state a problem and what to do.** Placeholder details, record row details for `noFolder`, `failed` and `waiting`, Attention reasons, and `recordingNote`. Splitting these would lose the instruction. A joined note (`UIPresentation.swift:665`) stays a sentence.

**Words on actions that end something.** Stop Recording, Stop 2 Recordings, Stop Camera, Stop All Recordings, Remove Camera…, Reset…, Forget…, Disconnect, Unassign, Recover. No symbol replaces them. Most get none at all.

**The tally words.** ON AIR, ISO, NEXT and PROGRAM are the fastest read in the app. The glyph beside two of them only separates two red pills.

**CPU, GPU and Memory.** `cpu` and `memorychip` exist, `gpu` doesn't, and a mixed set reads worse than three short words. A label is already as short as a symbol.

**Form rows.** Settings stops at tab icons, Hardware rows and warnings. General, Recording, Audio, Switching and Advanced rows get no icons, because a label like "Timecode" is already the name of the thing, and a column of icons would make every row look alike and slow the read. Section headers in those tabs stay plain too: tabs are shallow, and one tab is on screen at a time.

**Monitor tool and scope forms.** Same reason. The popover's header carries the symbol. Fields inside are measurement parameters, read one at a time, by someone looking at them.

**Sidebar section headers.** Five words on a pane that's always in the same order. The inspector gets symbols because it's long and it scrolls.

**Diagnostics rows and the Camera Control grid.** Long label-value tables, read deliberately. The labels are the content.

**Help prose.** It's there to be read.

**System alerts and dialogs.** Native, with a question and a named verb. A custom icon adds nothing, and macOS draws the app icon.

**Menu bar subtitles.** `NSMenuItem` takes a string, and a custom view would cost keyboard navigation. Two parts at most, joined by " · ".

**App menus.** `UICommands.swift` stays text. Mac app menus have no icons by convention, and every row has a shortcut column already.

**The status item.** The template icon with its knocked-out badges works at menu bar size (06 section 10). A `square.stack.3d.up.slash` badge wouldn't read at 9 pt, so bypass keeps `arrow.right.circle.fill`. That is the one exception to section 1, and its accessibility label says "Effects off".

**Audio meter text.** Numerals and dBTP come from MonitorKit's fixed 44 pt block, already value-over-unit. Scales, legends and graticule labels are measurement, and they keep their own type and colors (06 section 6).

**Tooltips and picker rows.** `detail()` and `title()` in `UICameraControl.swift:203-205`, and `UIInputLabels.label` (`UIPresentation.swift:357`), stay as joined strings. They name a thing in one line, and a tooltip can't hold chips.

**Popover subtitles.** "Camera 1 · analysis on Output (LUT)" is a single phrase (`UIMonitorTools.swift:274-290`). "Zebra 1 · picture" (`UIMonitorToolForms.swift:169`) likewise.
