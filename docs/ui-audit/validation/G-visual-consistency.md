# G · Visual consistency audit of the r5 mockups

Date: 2026-10-31. Review only: no mockup or code changed. Covers all 15 pages in `docs/mockups/r5/`, `kit.css`, and the renders in `png/`. Rules: [README](../README.md), [07](../07-visual-language.md) sections 1 to 3, [06](../06-visual-polish-and-native.md) section 6.

**Result: 46 findings. 15 P1, 21 P2, 10 P3.** The main cause is that `kit.css` itself is off the type scale and has no switch, menu, popover, alert or segmented control, so each page drew its own. Most of the fixes go in the kit once.

| Severity | Meaning |
|---|---|
| **P1** | Misleads on a live surface, breaks a decided rule across pages, or is a kit error every page inherits |
| **P2** | One component drawn differently between pages |
| **P3** | Polish and mockup housekeeping |

## How this was checked

- **Renders.** Every page was read in overlapping 1600 px bands. `sips -c` ignored the crop offset on tall images and returned whole pages, so the bands were cut with a small Swift script instead. Frames below are named by caption.
- **Measurements.** Computed font size, weight, contrast, overflow and component size came from about 8,300 text nodes, using copies of the pages in headless Chrome under `/tmp`. Contrast composites translucent fills, and takes the first stop of a gradient.
- **Native reference.** Real AppKit controls were measured and drawn offscreen, with no window shown and no screen capture. **This Mac is on macOS 27.0.1 and the target is 26.0,** so the native sizes below are evidence from 27, not proof for 26. The alert's bitmap would not render, so its geometry, natural (left) text alignment and 13 pt body come from the view tree.
- **Symbols.** Candidates were drawn at 12, 13 and 15 pt on both tool bar fills. This Mac reports each as introduced in 2019 to 2023, so all should exist on 26.
- **A hook blocked one combined shell command,** as a false alarm on a heredoc. The probe was rerun from plain scratch files in `/tmp/ultracam-audit-g/`. Nothing outside `/tmp` and this report was written. Ultracam was not launched or quit.

## Decisions

**Picture tool glyph: `camera.filters`.** 07 section 1 already says so, and 25 of 26 uses agree. The odd one is overview.html, which uses `circle.lefthalf.filled`. That glyph sits beside Zebra's `circle.lefthalf.striped.horizontal`, and in the overview's tool bar the two read as the same mark. Its two lower rings draw dim at 12 pt, so set `.symbolRenderingMode(.monochrome)` in the app.

**Clip glyph: `arrow.up.and.line.horizontal.and.arrow.down`.** Change 07 section 1 and drop its "confirm in render". Drawn at 12, 13 and 15 pt, `sun.max.trianglebadge.exclamationmark` fails twice: the body reads as a sun, meaning brightness, and the badge is a clear warning triangle, which 07 reserves for warnings. 07 names this fallback for exactly that case. It holds at 12 pt on both fills and says over and under a limit. Same change in `TileToolbar.swift`.

**Zebra passes** its 07 render check. `circle.lefthalf.striped.horizontal` is distinct at 12 and 13 pt on both fills.

## P1

**G1 · Sidebar width.** `kit.css` `.win`, overview.html, sidebar-toolbar-states.html (every frame), alerts.html (Attention rows). These draw 262 pt, but README section 10 and main-layouts say 236. So the page that proves sidebar wrapping proves it 26 pt too wide. Attention rows and the drive camera row wrap differently at the true width.
Fix: `.win { grid-template-columns:236px 1fr; }`, `.sbars { grid-template-columns:repeat(5,236px); }`, `.side { width:236px; }` on that page, `.sb { width:236px; }` on alerts, then re-read the wraps.

**G2 · Camera number on the picture.** main-layouts, main-program, monitor-tools, overview: 49 pictures join "1 Camera 1" inside one name pill. picture-states uses a separate digit capsule, which is what 07 asks for: "Strong digit in its own capsule, so it reads as the Cut digit".
Fix: all pictures use `<span class="numcap pic">1</span><span class="pill">Camera 1</span>` inside `.ptop`. Picture-states' 24 pt capsule is the correct form.

**G3 · Clip symbol.** monitor-tools (44), picture-states (6), main-layouts, overview. See Decisions.
Fix: `s="arrow.up.and.line.horizontal.and.arrow.down"`.

**G4 · Tool bar states on the overview.** overview.html, Camera 1 and Camera 2. Three errors on the page people open first:
- `kit.css:73` draws `.tools .act` at white 0.22. Four pages override it to white 0.9 with a black glyph, as 07 requires, so the kit is wrong and only the overview shows it.
- The tools button uses `slider.horizontal.3` with a tool on. It should be `slider.horizontal.below.square.filled.and.square`.
- The Picture glyph is `circle.lefthalf.filled`, as in Decisions.

Fix: `.tools .act { background:rgba(255,255,255,.9); color:#000; }` in the kit, delete the four overrides, and change both symbols.

**G5 · Orange words and the placeholder on the overview.** These are the only orange text in all 15 pages. 06 section 6 and 07 say label-color words beside a triangle.
- Sidebar and picture "Signal lost **0:06**" digits are orange. The picture also lacks the title's triangle and tints the `video.slash` cause symbol. 07 keeps it gray.
- Settings frame: chips "No signal" and "S-Log3, Camera 2 is Rec.709" are orange text.
- Settings frame: `cable.connector` and `camera` are tinted green or orange, with color alone carrying health. settings-hardware uses a dot or triangle plus a white glyph.

Fix: replace these with picture-states' Signal lost markup and settings-hardware's `.hw` rows. Remove `style="color:var(--orange)"` and `class="o"` from the words.

**G6 · The kit is off the type scale.** `kit.css` sets values that 07 section 2 doesn't have, and pages inherit them. 46% of all text nodes, captions included, are 10.5, 11.5 or 12.5.

| Element | Kit | 07 level | Fix |
|---|---|---|---|
| `.clock` | 20 bold | `uiClock` 17 semibold | `font-size:17px; font-weight:600` |
| `.name`, `.big`, inspector `.hdr .big` 16 | 14, 16 bold | `uiTitle` 13 bold | `font-size:13px` |
| `.hold .t` | 17 | `uiPlaceholderTitle` 15 semibold | `font-size:15px` |
| `.lab` | 11.5 | `uiMeta` 11 | `font-size:11px` |
| `.unit` | 10.5 medium | `uiMeta` 11 | `font-size:11px; font-weight:400` |
| `.chip`, `.badge` | 11, 11.5 | `uiBadge` 10 semibold | `font-size:10px` |
| `.pill` | 12 | `uiOverlay` 11 semibold | `font-size:11px` |
| `.stat` | 12, 11.5 on one page | `uiMeta` 11, values 12 | `font-size:11px`; `.stat b { font-size:12px }` |

Settings and inspector row text is 13 regular, which is the native form size but is on no level of 07. Add it to 07 as a form-row level instead of shrinking those rows.

**G7 · Value and unit.** main-layouts, main-program, overview, popovers, sidebar-toolbar-states, strip-states: about 110 "1h 52m", drawn as one string in one weight. menubar and alerts spell it "1 h 52 m", and the Attention rows say both "24m" and "22 m". 07 section 2 says 1 and 52 strong, h and m small and dim, on one baseline.
Fix everywhere: `<span class="uval"><b>1</b><i>h</i> <b>52</b><i>m</i></span>`, with `.uval` from the kit block. Menu badges keep plain "1 h 52 m", because `NSMenuItemBadge` takes a string.

**G8 · One dialog drawn three ways, with a different default.** alerts.html is the master. inspector.html "Turning Sync on" and settings.html and settings-hardware.html confirmations redraw it.
- Sync: alerts says "Copy Camera 1's effects to Camera 2?", Cancel default, "Turn On Sync". Inspector says "Sync cameras from Camera 1?", **"Sync Cameras" is the blue default**, and it lists monitor tools, not the LUT. Rewriting other cameras' effects mustn't be the Return key.
- Connector: alerts "Change Left UltraStudio to SDI?", settings-hardware "Change the connector on Left UltraStudio?", with no default drawn.
- Forget: "Forget Saved LUTs?" against "Forget saved LUTs?".

Shapes also differ: `.sheet` 460 wide, app icon left, capsule buttons, `.alert` 262 and 300 centered, no icon. AppKit's alert here measures 260 wide with a 64 pt icon top left, then left-aligned title and 13 pt text, and two 110 × 28 buttons, corner radius 26.
Fix: one `.alert` from the kit block, copy from alerts.html, Cancel default on anything that ends or rewrites something. The other pages reference it or drop the frame. Use "Interrupted Takes" as the only `.sheet`.

**G9 · "Camera Settings" is the wrong noun.** settings-hardware.html: page title, section heading and both sheets, 7 uses. Every other page, README section 8 and 07 say Camera Control. The sheet's title also names the body, where 07 has "Camera Control · Camera 1" with the camera name in secondary.
Fix: `Camera Control · <span>Camera 1</span>`, at 13 bold, and keep "FX3 A" on the assigned-body row.

**G10 · Battery glyph buckets.** main-layouts, main-program, overview, settings-hardware, sidebar-toolbar-states: 28 uses of `battery.50percent` for 64%. `UIBatteryGlyph` buckets at 88, 63, 38, 13, so 64% is `.75percent`. settings-hardware's 12% uses `.25percent` and should be `.0percent`.
Fix: `s="battery.75percent"` beside 64%, `s="battery.0percent"` beside 12%.

**G11 · Switches.** Four drawings, none native. inspector and monitor-tools 27 × 16, main-layouts and main-program 26 × 15, settings and settings-hardware 32 × 19, plus `.sw.small` at 80% scale. All have round thumbs at about 1.7 to 1. The AppKit render has a capsule thumb in a track of about 2.25 to 1: regular 54 × 24, small 44 × 20, mini 36 × 16. The round thumb is the look from before macOS 26, so this is a platform change, not carelessness.
Fix: `.sw` in the kit block. Settings uses `.sw.reg`, inspector and popover headers `.sw`, nested zebra rows `.sw.mini`. Delete the page copies and `.sw.small`.

**G12 · Eight-channel meter readout.** popovers.html, "8 channels", per-channel maxima at 6.5 pt (`.mmax.tiny`), 16 values, unreadable in the render. 168 meter labels are under 10 pt. Rulers and legends are measurement and 07 section 5 lets them keep their type. A readout isn't a graticule, and README section 7 replaced this row with one line because it overflows.
Fix: at 8 and 16 channels drop `.mmax`, and under the bars print `Highest 1–2 <b>−2.1</b> <span class="unit">dBTP</span>` at 11 pt. Raise `.ph2`, `.mtop`, `.mlab` to 9 pt. Also picture-states camera settings overlay `.cam small` from 9.5 to 10.

**G13 · Menus.** Five implementations. `.menu.nm` in app-menus, menubar, popovers. `.nm` in picture-states, sidebar-toolbar-states, strip-states. `.pm` and `.mi` in settings and settings-hardware. `.menuopen` in inspector. `.open` in monitor-tools. Sizes run 12.5 to 13 pt, row radius 5 to 6, background `#2b2b2e`, `#2f2f32`, `#333336`. The second form's selected row doesn't set white text: 3.32:1 at "Format". `.open` draws its check and submenu arrow as text characters, not symbols.
Fix: the app-menus form, moved to the kit as below, 13 pt, 24 pt rows. Replace `✓` and `›` with `checkmark` and `chevron.right`. Signal badge menu states "Connected" and "Disconnected" sit at 4.39:1, and 06 accepts that for metadata, never a state word, so use `.bd.act`.

**G14 · Button heights.** `.btn` renders at 24.9, 23.6, 21.6, 20, 18.9 and 16.9 pt because height comes from padding. The status bar's action is 16.9 on sidebar-toolbar-states and 18.9 on main-program. 06 section 7 sets 24 as the interactive floor, and native sizes are 16, 20, 24, 28. `.mini` is the same control at 20.9 and 18.9, and `.popup` is 21.6, 19.6, 18.3.
Fix: fixed heights: `.btn`, `.popup`, `.cut`, `.lut` 24, `.btn.sm`, `.popup.sm` 20 (native small, for the status bar and Attention only), `.cut.wide` 28. Retire `.mini`. Delete every page-level `padding` override.

**G15 · Output row overflows at real width.** main-layouts, frame 1 and the stopped frame: Effects sticks out 4 pt past the strip's right edge, beyond Pause and ⋯ above it, and the 6a frame by 3 pt. The cause is that strip-states' "normal width" is 549, but a 1320 window with a 236 sidebar gives 511. So main-layouts dropped "3 of 3" from Effects, which README section 6 and 07 require. The strip page was validated at a width the window doesn't have.
Fix: draw strip-states at 511 and 342. At 511 use `.sr.out { gap:4px }` and `.sr.out .chips { gap:2px }`. If "3 of 3" still doesn't fit, record a density tier that drops the `4:2:0 8-bit` chip into help, so the count stays.

## P2

**G16 · Popup indicator.** Settings, inspector, sidebar Format, monitor-tools and settings-hardware all use `chevron.down` on selection popups. The AppKit render shows `chevron.up.chevron.down` on a popup and a single chevron on a pull-down. monitor-tools already uses it twice.
Fix: popups use `chevron.up.chevron.down`. Pull-downs keep `chevron.down`: Effects, Record, Add, Choose….

**G17 · Popover shell.** popovers `.pop` is `#2b2b2e`, `#47474a`, radius 14, with an arrow. monitor-tools `.pv` and `.pop3` are `#2a2a2d`, `#57575a`, radius 12, no arrow. settings `.pop` is `#2f2f32`, radius 10, no arrow. Header symbol is 18 primary against 20 dim. 06 section 7 moves padding from 14 to 12.
Fix: `.pop` and `.ph` from the kit block, with `.pop.wide` for 756 pt tools.

**G18 · Segmented controls.** diagnostics `.seg` (radius 8, 12 pt) against monitor-tools `.sg` (radius 6, 11.5 pt, 21 tall). popovers reuses the name `.seg` for a status segment. The AppKit render fills the selected segment with accent blue; confirm on 26 before keeping gray.
Fix: `.seg` from the kit block. Rename the popovers class `.stseg`.

**G19 · Tally forms.** `.onairp`, `.nextp`, `.progp`, `.tnext`, `.tprog`, `.pgm` draw three pills four ways. PROGRAM's outline is 0.85 on main pages, 0.6 on picture-states and sidebar. The menubar's ON AIR keeps radius 10 at 20 tall while its neighbor uses 8. `.onairp` has a hard-coded `left:124px`, which leaves a wide gap on the overview. `.tagred` is `#c9352c`, but 20% darker than `--red` is `#cc372e`.
Fix: `.tally` in the kit block.

**G20 · Sidebar tally chips.** main-layouts, main-program, overview, sidebar-toolbar-states: word only, so ON AIR and ISO are the same red chip, the case 07 adds glyphs to solve. `.tagpr` is 13 tall against 15.
Fix: `.tchip` in the kit block, with `tv` or `video.fill` at 10 pt.

**G21 · Rings.** ISO is 4 pt on main-layouts and main-program, 3 pt on picture-states.
Fix: `.pic.onair, .pic.iso { box-shadow:inset 0 0 0 4px var(--red); }` and `.pic.nx { box-shadow:inset 0 0 0 3px var(--green); }` in the kit. Drop `.pic.nxt`.

**G22 · Status bar.** 30 tall on main pages, 28 on sidebar-toolbar-states, gaps of 15, 14, 12, plus a separate `.bigstat` on popovers. 13 pt symbols appear only on that one page: 233 of them.
Fix: `.stat` at 30, gap 12, 12 pt symbols, one `.sbar` wrapper for detached bars.

**G23 · Toolbar grouping.** README says three pieces of glass. main-layouts and main-program have three. overview has five, and sidebar-toolbar-states splits Cut from Auto and Hold, and keeps inspector separate. overview also omits the collapse control.
Fix: main-layouts' structure, with `.vs` dividers.

**G24 · Camera row glyph.** main-layouts, main-program, overview, sidebar-toolbar-states: green `video.fill` marks a running camera. 07 says `UIStateGlyph`, and `video.fill` means ISO tally or on air in menus.
Fix: `<span class="dot gr"></span>` before the name. Stopped uses `.dot.hollow`.

**G25 · "Camera original" symbol and order.** overview, main-layouts, main-program, sidebar-toolbar-states, popovers: 20 uses of `camera`, which is the camera body symbol, and the order is reversed. README and 07: "Camera original · Mac Clock", with `clock` on Mac Clock only.
Fix: `<span class="lab">Camera original</span>` first, no symbol.

**G26 · Takes row.** Three forms. main pages "5:40 PM 12:31", then `video` "2", "0 lost", Show All. sidebar-toolbar-states "12:31 5:40 PM", "2 cameras". overview "2 clean", button "All". 07: `film`, time, duration, `video` and count, then the check and "0 lost".
Fix: the main-page form everywhere.

**G27 · Drive cameras row.** main pages put capsules on the drive line. sidebar-toolbar-states adds a row with round `.ntag` and names. 07 says names with capsules, falling to capsules alone when they don't fit, which at 236 pt is the main form. Five capsule classes exist: `.num` (radius 5), `.ntag` (8), `.tc` (4), `.num1` (18 tall), and picture `.num`. `.ntag` is 4.32:1.
Fix: `.numcap` from the kit block, in `--text`.

**G28 · Orange wash.** `.warnrow` .12, `.attn` .13 with a .45 border, `.prob` .12, `.mw` .14, `.chip.pb` .16. 06 section 6 says wash 0.08 with a 0.5 border. The strong wash is also why `--dim` drops to 4.46:1 on a wash row.
Fix: `--wash:rgba(255,159,10,.08); --washline:rgba(255,159,10,.5);` used by all of them.

**G29 · Attention action alignment.** main-program frame 7 left-aligns Details under the text, because its `.attn .act` lacks `justify-content`. alerts and sidebar-toolbar-states right-align. Body styles `.ttl` and `.ti` are the same thing twice.
Fix: `.prob` from the kit block, used by Attention, the inspector and Hardware.

**G30 · One problem, several sentences.** "8TB has 24m left", "8TB: 22 m left", "8TB is nearly full". "Camera 2 signal lost", "Camera 2 no signal". "Video only — select…" against "Video only. Select…". "Restart Camera" against the menubar's "Restart". README section 5 has one problem list rendering everywhere.
Fix: "8TB: 22 m left", "Camera 2 signal lost", "Video only. Select your microphone in your meeting app.", "Restart Camera". The menu bar row needs G33's fix for room.

**G31 · Cut and LUT widths.** Cut is 68 in the kit, 64 in `.oo`, 58 in narrow, auto-sized elsewhere. 07 fixes it at 64. LUT is 70, 62, 44, or auto on main pages, where 07 asks for fixed width. Narrow strip-states shortens to "On", though main-layouts' note says the toggle keeps its words, and it renders "LUT On".
Fix: `.cut { width:64px }`, `.lut { width:70px; justify-content:center }`, and keep the words at every width.

**G32 · Collapsed strip.** 44 tall on main-layouts and main-program, 38 on strip-states, a different 58 pt tile on the overview. Compact meter is 96 wide against 56.
Fix: `.strip.col .sr { height:36px }`, 38 in all, and one `.cm { width:56px }`.

**G33 · Menu bar row collision.** menubar "Multiple problems": "A camera app is waiting for Camera 1" runs 5 pt past its column, into the Restart badge.
Fix: make the panel 360 wide, or give the title `overflow:hidden; text-overflow:ellipsis`. Do not shorten the action.

**G34 · Placeholder and empty titles.** 17 on overview, main-layouts, main-program. 15 on picture-states and monitor-tools. Empty states are 15 bold on diagnostics and inspector, 17 bold for No Cameras. 07 has one level, 15 semibold. Picture buttons `.bb` are a third button style. "Camera Stopped" is capitalized only on diagnostics. The stopped sentence has three versions: "its video input", "its picture", "its HDMI input".
Fix: G6's `.hold .t`, `.empty .t` the same, `.btn.sm` for picture buttons, and "Start the camera to see its video input."

**G35 · Dropped count.** main-layouts has a strong "0". strip-states and overview are dim. 07 wants the count at `uiValueStrong`, word at `uiMeta`.
Fix: `<b>0</b> <span class="lab">dropped</span>`.

**G36 · Folder row, rate and inspector digits.** main-layouts drops "Takes/" from the folder path, and the rate loses "~" there and on the overview. A strip's rate is an estimate, so "~64 Mb/s" stays. Only the rolling popover's measured rate has no tilde. Inspector effect rows keep digits 1 to 4 at 3.52:1, which 06 V12 deletes, with footer "Applied top to bottom", not "Applied in order".
Fix: as stated.

## P3

**G37 · Captions.** Five forms. `.cap` 13.5 on main pages, 11.5 semibold on monitor-tools, diagnostics and inspector, 12.5 on picture-states and strip-states. `.cap2` 11.5. `.fc` 12 with a 2 pt indent. sidebar-toolbar-states fixes its caption height at 52.
Fix: `.cap` in the kit block, on all pages. `h2` overrides on monitor-tools go.

**G38 · Page heights.** Nothing is clipped: the last content ends inside every render. Bottom margin runs 17 to 80, against the 40 of the page padding. Set the `shot` height to: alerts 2337, app-menus 1604, diagnostics-help 4780, inspector 1576, main-layouts 7320, main-program 5638, menubar 2893, monitor-tools 10162, overview 2194, picture-states 7404, popovers 2649, settings-hardware 4432, settings 4913, sidebar-toolbar-states 5375, strip-states 5176.

**G39 · Annotation inside a frame.** overview and main-layouts `.tag` "hover: full tool bar" is `#ffe14d`, off-system, and sits on the picture like UI.
Fix: delete it, and say so in the caption.

**G40 · Red dot off meaning.** monitor-tools Focus Peaking "● Red" is a red text bullet. A red dot only means recording.
Fix: use the `.well` swatch that Guides uses.

**G41 · Decorative or off-system color.** menubar's row-order "Problems" chip is tinted orange with no state. Diagnostics graphs are drawn in blue, which 06 limits to selection.
Fix: plain `.chip`, and `stroke:var(--dim)`.

**G42 · Keycaps.** diagnostics `.key` 12.5 medium `#3c3c40`, settings 12 semibold `#3e3e41`, with `letter-spacing`.
Fix: `.key` in the kit block.

**G43 · Duplicated helpers.** `.spin` at 15, 22, 13, 12. `.lvl` in four pages. Inactive dot as `.hollow`, `.hd`, `.dot.hollow` and an inline style. Green dot as `.gd`, `.dot.gr` and 38 inline styles. Slider drawn twice, round at 12 and 16, against a capsule knob in AppKit. Stepper as `.stp` boxes on settings and text on monitor-tools. View controls `.vc` are 24 tall beside the 26 pt `.tools` on the same picture: use 26. main-layouts and main-program share 6.7 KB of CSS, settings and settings-hardware 8.7 KB, and three pages copy the same `.menu.nm` block.
Fix: kit block, then delete the copies.

**G44 · Class collisions.** Same name, different component: `.num` (4), `.tc`, `.vc`, `.pr`, `.pv`, `.ph`, `.dt`, `.tf`, `.stp`, `.sl`, `.seg`, `.sheet`, `.alert`, `.note`, `.prob`, `.pop`, `.cam`, `.empty`, `.big`, `.key`. `.r` is red in the kit and dim in monitor-tools legends. This is how drift stayed hidden.
Fix: kit names, with no page-local redefinition of a kit class.

**G45 · Window chrome.** Title bar is 48 on diagnostics, 40 on help, 32 on detached monitors, 30 on settings. All windows use radius 12, while the alert measures 26. Confirm the window radius on 26.
Fix: one `.wbar` at 32, or 52 with a toolbar.

**G46 · Open popup position.** settings "Timecode choices" and "Four cameras" drop the list below the control. A native popup opens with the checked row over the control. The docs also disagree: 06's table uses "Saving…", while 07's record-row table reads the other way. strip-states follows 06, which README names, so fix 07. And "Camera Display" against "HDMI camera display".
Fix: place the checked row over the popup, correct 07, and use "Camera Display".

## What held up

Worth keeping as they are:

- **Digits.** Every number has tabular or mono digits, because the kit sets it on `body`.
- **Red text.** None. The only red text node is G40's bullet, and the record state is a red dot plus label-color words on every page.
- **Chips and badges** are a consistent height on each page.
- **Disabled text** below 4.5:1 and white on `--blue` at 3.65:1 are exempt or system colors, as is `--dim` at 4.39:1 on menu badges (06 accepts secondary for metadata). Only "Manual" fails as a state word: `.f` at 3.82:1 on main-layouts and main-program. Use `.d`, per 07's "Manual dim".
- **Strip rows** add up to the 224 pt recipe, plus 2 pt of border.
- **Symbols** otherwise follow 07's map, and every name resolved.
- **picture-states, strip-states and app-menus** are the most faithful pages. Use them as the reference when fixing the others.

## Definitive kit additions

Apply each block to `kit.css` as its comment says: CHANGE merges properties into the existing rule, REPLACE swaps the rule, ADD is new. New names are `.numcap`, `.tally`, `.tchip`, `.uval`, `.seg`, `.alert`, `.sheet`, `.pop`, `.ph`, `.prob`, `.wbar`, `.sbar`. Component names were chosen so that page-local copies can be deleted, not renamed.

```css
/* CHANGE: tokens */
:root { --wash:rgba(255,159,10,.08); --washline:rgba(255,159,10,.5); --tally:#cc372e; }

/* CHANGE: type levels, 07 section 2. .uval is new */
.lab   { color:var(--dim); font-size:11px; }
.unit  { color:var(--dim); font-size:11px; font-weight:400; }
.big, .name { font-size:13px; font-weight:700; }
.clock { font-size:17px; font-weight:600; line-height:1.1; }
.chip  { height:18px; font-size:10px; font-weight:600; }
.badge { height:18px; font-size:10px; font-weight:600; }
.pill  { font-size:11px; font-weight:600; }
.hold .t { font-size:15px; font-weight:600; }
.tab   { font-size:11px; }
.uval  { display:inline-flex; align-items:baseline; gap:2px; white-space:nowrap; }
.uval b { font-size:12px; font-weight:600; }
.uval i { font-style:normal; font-size:11px; color:var(--dim); margin-right:2px; }

/* CHANGE: window. The sidebar is 236 pt, README section 10 */
.win { grid-template-columns:236px 1fr; }

/* REPLACE: controls have fixed heights, never height from padding */
.btn, .popup { display:inline-flex; align-items:center; gap:5px; height:24px; padding:0 10px; border-radius:7px; background:var(--ctl); font-size:12px; font-weight:500; white-space:nowrap; flex:none; }
.btn.sm, .popup.sm { height:20px; padding:0 8px; font-size:11px; border-radius:6px; }
.btn.def { background:var(--blue); color:#fff; font-weight:600; }
.btn.dis, .popup.dis { background:var(--ctl2); color:var(--faint); }
.popup.wide { display:flex; justify-content:space-between; }
.cut { display:inline-flex; align-items:center; justify-content:center; gap:4px; width:64px; height:24px; border-radius:7px; background:var(--ctl); font-size:12px; font-weight:600; flex:none; }
.cut.wide { width:100%; height:28px; }
.cut.air { background:none; color:var(--dim); font-weight:500; }
.cut.no { background:var(--ctl2); color:var(--faint); }
.cut.nx, .tb.nx { box-shadow:inset 0 0 0 1.5px var(--green); }
.lut { display:inline-flex; align-items:center; justify-content:center; gap:4px; width:70px; height:24px; border-radius:7px; background:#4a4a4e; font-size:12px; font-weight:600; flex:none; }
.lut.off { background:var(--ctl); font-weight:500; }
.lut.no { background:var(--ctl2); color:var(--faint); font-weight:500; }
.tb.dis, .lay.dis { color:var(--faint); }

/* REPLACE: tool bar */
.tools .act { background:rgba(255,255,255,.9); color:#000; }

/* REPLACE: rings, 06 section 6. Delete .pic.nxt */
.pic.onair, .pic.iso { box-shadow:inset 0 0 0 4px var(--red); }
.pic.nx { box-shadow:inset 0 0 0 3px var(--green); }

/* REPLACE: orange wash, 06 section 6 */
.attn { background:var(--wash); border:1px solid var(--washline); border-radius:9px; padding:7px 9px; }
.warnrow { background:var(--wash); margin:0 -14px; padding:0 14px; }
.mw { background:var(--wash); }

/* REPLACE: status bar */
.stat { display:flex; align-items:center; gap:12px; height:30px; padding:0 14px; border-top:1px solid #000; color:var(--dim); font-size:11px; white-space:nowrap; }
.stat b { color:var(--text); font-size:12px; font-weight:600; }

/* ADD: captions and notes */
.cap { color:var(--dim); font-size:12px; font-weight:400; line-height:1.3; margin:0 0 6px; }
.cap b { color:var(--text); font-weight:600; margin-right:4px; }
.foot { color:var(--dim); font-size:11px; line-height:1.35; margin:6px 2px 0; }
.frames { display:flex; flex-wrap:wrap; gap:26px 20px; width:1420px; align-items:flex-start; }

/* ADD: picture overlays */
.ptop { position:absolute; left:12px; top:12px; display:flex; align-items:center; gap:6px; }
.pbot { position:absolute; left:12px; bottom:12px; display:flex; gap:6px; }
.ptop .pill, .pbot .pill { position:static; flex:none; white-space:nowrap; }
.numcap { display:inline-flex; align-items:center; justify-content:center; width:16px; height:16px; border-radius:5px; background:var(--chip); color:var(--text); font-size:10px; font-weight:700; flex:none; }
.numcap.pic { width:auto; min-width:24px; height:24px; padding:0 6px; border-radius:12px; background:rgba(0,0,0,.72); color:#fff; font-size:13px; }
.tally { display:flex; align-items:center; gap:5px; height:24px; padding:0 9px; border-radius:12px; font-size:12px; font-weight:700; white-space:nowrap; flex:none; }
.tally.air { background:var(--tally); color:#fff; }
.tally.nx { background:var(--green); color:#000; }
.tally.pg { background:rgba(0,0,0,.72); color:#fff; box-shadow:inset 0 0 0 1.5px rgba(255,255,255,.7); }
.tally.sm { height:20px; padding:0 7px; border-radius:10px; font-size:11px; }
.tchip { display:inline-flex; align-items:center; gap:3px; height:15px; padding:0 5px; border-radius:4px; font-size:10px; font-weight:700; white-space:nowrap; }
.tchip .ic { width:10px; height:10px; }
.tchip.air { background:var(--tally); color:#fff; }
.tchip.nx { background:var(--green); color:#000; }
.tchip.pg { color:#fff; box-shadow:inset 0 0 0 1px rgba(255,255,255,.7); }

/* ADD: state glyphs and small parts */
.dot.gr { background:var(--green); }
.dot.hollow { background:none; box-shadow:inset 0 0 0 1.5px var(--faint); }
.spin { width:15px; height:15px; border-radius:50%; border:2px solid #5a5a5e; border-top-color:#e4e4e8; display:inline-block; flex:none; }
.spin.lg { width:22px; height:22px; border-width:2.5px; }
.lvl { width:28px; height:4px; border-radius:2px; background:#3b3b3e; overflow:hidden; display:inline-block; flex:none; }
.lvl b { display:block; height:100%; background:#8c8c91; }
.lvl.low b, .track.low b { background:var(--orange); }
.key { display:inline-flex; align-items:center; height:20px; padding:0 6px; border-radius:5px; background:#3c3c40; font-size:12px; font-weight:500; white-space:nowrap; }
.well { display:inline-block; width:36px; height:17px; padding:2px; border-radius:5px; border:1px solid #6a6a6e; }
.well i { display:block; height:100%; border-radius:2px; }

/* ADD: switch. Measured on macOS 27.0.1: regular 54 x 24, small 44 x 20, mini 36 x 16. Confirm on 26 */
.sw { position:relative; display:inline-block; flex:none; width:44px; height:20px; border-radius:10px; background:#4a4a4e; }
.sw::after { content:""; position:absolute; left:2px; top:2px; width:27px; height:16px; border-radius:8px; background:#e4e4e8; }
.sw.on { background:var(--blue); }
.sw.on::after { left:15px; background:#fff; }
.sw.reg { width:54px; height:24px; border-radius:12px; }
.sw.reg::after { width:32px; height:20px; border-radius:10px; }
.sw.reg.on::after { left:20px; }
.sw.mini { width:36px; height:16px; border-radius:8px; }
.sw.mini::after { width:22px; height:12px; border-radius:6px; }
.sw.mini.on::after { left:12px; }
.sw.dis { opacity:.45; }

/* ADD: slider. i is the track, b the fill, u the knob */
.sl { position:relative; display:inline-block; flex:1; min-width:120px; height:16px; }
.sl i { position:absolute; left:0; right:0; top:6px; height:4px; border-radius:2px; background:#4d4d51; }
.sl b { position:absolute; left:0; top:6px; height:4px; border-radius:2px 0 0 2px; background:var(--blue); }
.sl u { position:absolute; top:1px; width:20px; height:14px; margin-left:-10px; border-radius:7px; background:#f2f2f4; }

/* ADD: fields and steppers */
.tf { display:inline-flex; align-items:center; height:24px; padding:0 7px; border-radius:5px; background:#1a1a1c; border:1px solid #4a4a4e; font-size:12px; white-space:nowrap; overflow:hidden; }
.tf.focus { border:2px solid var(--blue); padding:0 6px; }
.tf.ph { color:var(--faint); }
.stp { display:inline-flex; flex-direction:column; align-items:center; justify-content:center; gap:2px; width:14px; height:22px; border-radius:5px; background:var(--ctl); color:var(--dim); }
.stp .ic { width:8px; height:6px; }

/* ADD: segmented control. Gray selection is unconfirmed: AppKit on 27.0.1 drew it in accent blue */
.seg { display:inline-flex; gap:1px; height:24px; padding:2px; border-radius:7px; background:#333336; }
.seg span { display:flex; align-items:center; padding:0 10px; border-radius:5px; font-size:12px; font-weight:500; color:var(--dim); white-space:nowrap; }
.seg .on { background:#58585c; color:var(--text); }

/* ADD: menus, native rows. Use the app-menus markup: .ck, .im, .tx, .st, .r, .ks, .bd */
.menu.nm { padding:5px; font-size:13px; background:#2b2b2e; border:1px solid #47474a; border-radius:12px; box-shadow:0 10px 30px rgba(0,0,0,.45); }
.menu.nm.float { position:absolute; z-index:5; }
.nm .mrow { display:flex; justify-content:space-between; align-items:center; gap:6px; min-height:24px; padding:2px 8px 2px 4px; border-radius:6px; }
.nm .mrow.two { min-height:36px; }
.nm .mrow.hi, .nm .mrow.hi .ks, .nm .mrow.hi .bd, .nm .mrow.hi .st, .nm .mrow.hi .ic { color:#fff; }
.nm .mrow.hi { background:var(--blue); }
.nm .mrow.dis, .nm .mrow.dis .ks, .nm .mrow.dis .bd, .nm .mrow.dis .st { color:var(--faint); }
.nm .mrow .l { display:flex; align-items:center; gap:0; min-width:0; }
.nm .ck { width:15px; flex:none; display:flex; justify-content:center; }
.nm .ck .ic { width:10px; height:10px; }
.nm .im { width:22px; flex:none; display:flex; justify-content:flex-start; }
.nm .tx { display:flex; flex-direction:column; min-width:0; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.nm .st { color:var(--dim); font-size:11px; line-height:1.2; }
.nm .r { display:flex; align-items:center; gap:7px; flex:none; }
.nm .ks { color:var(--dim); font-size:12px; letter-spacing:.5px; }
.nm .bd { display:inline-flex; align-items:center; gap:4px; padding:1px 6px; border-radius:5px; background:rgba(255,255,255,.09); color:var(--dim); font-size:11px; font-weight:500; }
.nm .bd.act { color:var(--text); }
.nm .chv { width:9px; height:10px; color:var(--dim); }
.nm .hd { color:var(--dim); font-size:11px; font-weight:600; padding:6px 8px 2px 19px; }
.nm .ft { color:var(--dim); font-size:11px; padding:3px 8px 3px 19px; white-space:normal; }
.nm .sep { height:1px; background:#454548; margin:4px 12px; }

/* ADD: popover, 07 section 3 header */
.pop { position:relative; display:flex; flex-direction:column; gap:10px; width:340px; padding:12px; background:#2b2b2e; border:1px solid #47474a; border-radius:14px; box-shadow:0 10px 30px rgba(0,0,0,.45); }
.pop.wide { width:756px; }
.pop.arrow::after { content:""; position:absolute; bottom:-7px; left:var(--ax,44px); width:12px; height:12px; background:#2b2b2e; border-right:1px solid #47474a; border-bottom:1px solid #47474a; transform:rotate(45deg); }
.ph { display:flex; align-items:center; gap:8px; }
.ph .ic { width:18px; height:18px; }
.ph .pt { font-size:13px; font-weight:700; }
.ph .ps { color:var(--dim); font-size:11px; }
.ph .end { margin-left:auto; }

/* ADD: alert. Geometry from an AppKit alert, macOS 27.0.1. Confirm on 26 */
.alert { display:flex; flex-direction:column; width:260px; padding:20px 20px 16px; background:#2b2b2e; border:1px solid #47474a; border-radius:26px; box-shadow:0 12px 30px rgba(0,0,0,.5); }
.alert img { width:64px; height:64px; margin-bottom:16px; }
.alert .t { font-size:13px; font-weight:700; line-height:16px; }
.alert .m { margin-top:10px; font-size:13px; line-height:16px; color:#d9d9dd; }
.alert .btns { display:flex; gap:8px; margin:16px -4px 0; }
.alert .btns span { flex:1; display:flex; align-items:center; justify-content:center; height:28px; border-radius:14px; background:#4a4a4e; font-weight:500; }
.alert .btns .def { background:var(--blue); color:#fff; font-weight:600; }

/* ADD: sheet, for real sheets only: Interrupted Takes, Camera Control */
.sheet { display:flex; flex-direction:column; gap:12px; padding:20px; background:#2b2b2e; border:1px solid #47474a; border-radius:26px; box-shadow:0 12px 30px rgba(0,0,0,.5); }
.sheet .t { font-size:13px; font-weight:700; }

/* ADD: problem row, for Attention, inspector and Hardware */
.prob { display:grid; grid-template-columns:15px 1fr; gap:2px 6px; padding:7px 9px; }
.prob .t { font-size:12px; font-weight:600; line-height:1.25; }
.prob .x { grid-column:2; color:var(--dim); font-size:11px; line-height:1.25; }
.prob .act { grid-column:1 / 3; display:flex; justify-content:flex-end; gap:4px; margin-top:4px; }

/* ADD: empty state */
.empty { display:flex; flex-direction:column; align-items:center; justify-content:center; gap:6px; color:var(--dim); }
.empty .t { color:var(--text); font-size:15px; font-weight:600; }

/* ADD: window chrome and detached status bar */
.wbar { position:relative; display:flex; align-items:center; gap:8px; height:32px; padding:0 14px; background:#29292b; border-bottom:1px solid #000; }
.wbar.tall { height:52px; }
.wbar .tl { display:flex; gap:8px; }
.wbar .tl i { display:block; width:12px; height:12px; border-radius:50%; background:#5a5a5e; }
.sbar { height:30px; background:var(--bg); border:1px solid #47474a; border-radius:9px; }
```

**After this,** remove `.mini`, `.sel`, `.onairp`, `.tagred`, `.nextp`, `.progp`, `.tnext`, `.tprog`, `.pgm`, `.tagnx`, `.tagpr`, `.ntag`, `.num1`, the page-level `.nm` blocks, and every `.btn` padding override. The `.onairp` markup moves to `.tally.air`, which removes the hard-coded `left:124px`.
