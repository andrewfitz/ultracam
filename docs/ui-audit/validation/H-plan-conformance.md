# H · Plan conformance of the r5 mockups

Date: 2026-10-31. Review only: read every word of the 15 pages in `docs/mockups/r5/*.html`, plus renders where shape mattered. Plan: `docs/ui-audit/README.md` revision 4 wins. Code read at the working tree. Nothing was built, launched or changed apart from this file.

**How this was checked.** Every text node on every page was matched against `Sources`, `Vendors`, `Packages/MonitorKit` and `docs/ui-audit`. 1,936 distinct strings; every miss was read by hand. Every `.pic` element was parsed for its tool bar contents. Every `s="…"` symbol was matched against report 07. Labels: **verified** means read in code or in the HTML.

## Result

| Severity | Count |
|---|---|
| Violates an owner decision | 7 |
| Contradicts the plan | 16 |
| Invented, in neither code nor plan | 9 |
| Missing, no drawn home or state | 16 |
| Inconsistent between pages | 24 |

Of the seven owner-level findings, five are clear (O1, O3, O4, O5, O6). Two need the owner's word: O2, hover under 480 pt, and O7, Clean View at rest.

**Holding everywhere, verified:** the word Feed appears on no page. "Coming later" appears on no page. No output or mode picker on any page: Copy Diagnostics drops the Output mode line. Every drawn tab bar shows eight tabs in README order. No switching section in the sidebar. Format is in the sidebar, the Record toolbar menu, the Record app menu and the menu bar, with read-only strips. Channels Shown is in Settings › Audio. Tools are drawn collapsed at rest with enabled tools on every camera picture in every placeholder state.

**Ruled compliant, so nobody re-raises it:** "Cut to Camera 2" in the Attention row (main-program frame 3) is a switching control in the sidebar, but README section 5 rule 4 orders it ("Show Cut at the warning and on the placeholder"). It is a problem's one action, not a switching section.

## 1. Violates an owner decision

### O1. The Program picture has no tools button
**Page:** main-program, frames 1 to 7, the large Program picture. **Verified:** `tools=0` on all seven, while every tile has one. Code draws it always (`UIAppProviders.swift:124`), and monitor-tools draws Program with tools.
**Fix:** add the tools button plus enabled tools at top right of the Program picture in all seven frames. Focus Peaking stays dimmed on hover. Also retitle monitor-tools frame "Program View tile, hover" to "Program picture, hover": it is the Program target, not a camera tile, which is why Focus Peaking is dimmed.

### O2. Hover does not expand below 480 pt
**Pages:** picture-states, right-hand 342 pt column, every hovered frame (Live, Enabled tools, Signal lost, Camera stopped, Clean View, Output menu), and the page subtitle "every state that has room for it". monitor-tools, "Narrow picture, under 480 pt, hover: one menu" and "the menu open". The rule comes from 06 V15. README section 6 says hover expands the full bar "in every state", and the owner set it. This is width, not state, but a 342 pt or Four Up picture is an ordinary live case.
**Fix:** the bar is 284 pt in code (6 × 40 + 24 + 12 spacing + 8 padding, `UIMonitorTools.swift:127-145`), so it fits a 342 pt picture. On hover, when the name row can't hold it, draw the full bar on its own row directly under the name row, right aligned. Tally and name stay. Redraw those frames and delete "that has room for it". Keep the one menu only below about 304 pt (284 + 20 margin), which is reachable only at the 260 pt Four Up floor or with both panes open, and get the owner's yes for that one case. The second row is this review's proposal, not a plan decision, so the owner must approve it before anyone redraws. If the owner prefers the menu on narrow pictures, write that exception into README section 6 instead.

### O3. Two hovered frames draw the collapsed bar
**Page:** picture-states, Frozen left frame and Zoomed left frame. **Verified:** timecode, Output menu and view controls are drawn, so they are hovered, but the tool bar is the bare tools button.
**Fix:** draw the expanded bar in both left frames.

### O4. LUT is not one click on a collapsed strip
**Pages:** main-layouts frame 3 (Four Up), main-program frames 1 to 7, strip-states every collapsed cell. Four Up and Program View always collapse strips (`UIPresentation.swift:672`), and the collapsed strip drawn has no LUT control, so the panic control is two or more clicks in the layout a switcher uses most. Today's collapsed strip does carry the chips when they fit (`UICameraColumn.swift:1146`).
**Fix:** add an icon-only LUT toggle, `cube.fill` on, `cube` off, 24 pt, with help and label, between the meter and the record button on every collapsed strip. At 342 pt the compact meter yields first, as strip-states already says.

### O5. The Clip Indicators mark is a warning triangle
**Pages:** monitor-tools (44 uses), picture-states (6), overview (1), main-layouts (1), all `sun.max.trianglebadge.exclamationmark`. The overview's own note says Zebra and Clip get their own marks so a triangle only means a warning, and this mark contains a triangle with an exclamation mark. At 13 pt the badge shrinks to a speck, but in the popover header it is plain. 07 named the fallback for this.
**Fix:** use `arrow.up.and.line.horizontal.and.arrow.down` everywhere, and update 07. No other triangle fails: every `exclamationmark.triangle.fill` is on a real warning, and `arrow.triangle.2.circlepath` is not a triangle.

### O6. A problem is repeated in the same place
| Page, frame | Repeat | Fix |
|---|---|---|
| strip-states, failed: disk full | Record row "Disk full" and folder row "No space left" | Folder row shows "—" for time left. The caption on noFolder already sets this rule |
| main-program frame 3 | Program picture and Camera 1 tile, side by side, both say "Signal lost 0:06 / Take continues for up to 10 s". Program isn't recorded, so that sentence doesn't belong on it | Program picture: "Camera 1 signal lost" and Cut to Camera 2 only. Sentence stays on the tile |
| picture-states "Camera stopped unexpectedly" 549 pt, with strip-states "Unexpected stop" | Start on the picture and Start Camera in the strip header, "Saved up to 12:31" in both | Over an expanded strip, the picture gives the reason only, as code already does for plain stopped (`UICameraColumn.swift:151`). Start on the picture only when collapsed |
| picture-states "Couldn't start" 549 pt, with strip-states "Couldn't start" | Retry on both. 03 B7: "Keep the header one" | Same rule. Retry on the picture only when collapsed |
| sidebar-toolbar-states, Problems | Attention "8TB has 24m left", Recording row "8TB 24m left", same pane | Attention title "8TB is low", action Folder for Next Take…. The time stays in the Recording row |
| sidebar-toolbar-states, No folder | Attention "No folder", Recording row "Not set", though the caption says "Said once" | Recording row shows "—" |

### O7. Clean View at rest has no tools button, and no written exception
**Pages:** picture-states "Clean View, at rest", monitor-tools "Clean View at rest". The owner's rule has no exception, and README never carves one out. The drawing does match the code (`UICameraColumn.swift:211`) and the point of Clean View.
**Fix:** keep the drawing and ask the owner for a one-line exception in README section 6. Until then it stands as a breach of "no exception".

## 2. Contradicts the plan

| # | Page, frame | Problem | Fix |
|---|---|---|---|
| P1 | alerts "Input Connector"; settings-hardware "Asks first…" and expanded row note | README says ask first. The backend refuses: `setDeviceConnector` returns `E_ACCESSDENIED` while Ultracam's own session is active (`DeckLinkBackend.mm:1583`). The sheet's verb can't succeed | See ruling (f). Delete both sheets. Row reads "Stop Camera 1 to change". Keep the Advertise HDR sheet |
| P2 | settings-hardware, whole sheet section, "Camera Settings · FX3 A", "Camera Settings…" buttons, page title | README section 8, 06 section 5 and 07 say Camera Control, and code titles it `Camera Control · name` (`UICameraControl.swift:42`). Only 04's sketch says Camera Settings. inspector and popovers already say Camera Control… | Rename the sheet, buttons, caption and page title. Title "Camera Control · Camera 1", per 07 |
| P3 | overview, Camera 1 and hovered Camera 2 | Enabled tool uses kit.css 22% white, not 07's white fill and black glyph. Tools button is `slider.horizontal.3` with a tool on. Hover bar ends in `circle.lefthalf.filled`, not `camera.filters` | Change `.tools .act` in kit.css to `rgba(255,255,255,.9)`, `#000`, and drop the three page overrides. Use the on-state button symbol. Use `camera.filters` |
| P4 | strip-states, Channels Shown 342 pt column, all four | Output row reads "Not in use On": the word LUT is gone, and so is the Effects control. main-layouts 6a says "The LUT toggle keeps its words", and 07 fixes "LUT On" | Draw `LUT On` and the icon-only Effects button in all four cells |
| P5 | sidebar-toolbar-states, Problems, first row | Two actions, Start and Why. README section 5: "each problem with one action". README's own section 6 sketch shows both, so README disagrees with itself | Start only, as alerts draws it. Fix the README sketch |
| P6 | main-layouts frame 5, inspector | Differs from inspector.html: has Video preview (03 B11 removes) and Time left (03 G14 removes), "Camera settings", "LUT input space", no effect numbers, no Code range or Log transport | Replace with the running inspector from inspector.html, cropped to fit |
| P7 | inspector, every Recording section | "Constant frame rate (compatibility)" always drawn. 03: only once the input has reported a variable rate, or the saved value is on | Remove from the base frames. Add one frame showing it |
| P8 | menubar, Camera submenus | Input submenu kept on a running camera. README placement: one camera, setup, goes to the inspector; 03 C1 removes it, for seven rows a camera. 07 still lists it | Remove the row and the "Camera 2 submenu, with Input open" frame. Correct 07 |
| P9 | menubar, Effects submenu | Rows numbered 1 Output size, 2 Color format, 3 Frame-rate cap. inspector numbers 2, 3, 4. 07: "Effect rows keep their numbers" | Number 2, 3, 4 |
| P10 | sidebar-toolbar-states, Problems, No folder, Four cameras | Sidebar chips for PROGRAM and NEXT. 07: "a filled ON AIR or ISO chip". main-layouts frame 1 and main-program frames 3, 6, 7 show none in the same states | Chips ON AIR and ISO only. Change the Four cameras caption. The strip and picture own the rest |
| P11 | every sidebar, Virtual Cameras | Rows read "Program", "Camera 1". README's sketch and the published names are "Ultracam · Program". The rows must match what Zoom lists | Use the full names. README's sketch fits 236 pt |
| P12 | picture-states "No input selected" | 06 section 5: use "No input", replacing "No input selected". README adopts 06 | Title "No input". Sentence stays |
| P13 | monitor-tools, Picture popover, all four | Signal row kept. 03 H14 removes it, as the stage menu owns it | Remove the row, keep its caption as help. Low: README is silent |
| P14 | popovers, "Two drives, notes" | Status segment reads "REC 2 41:07" with one camera paused. 07: paused shows `pause.fill` and count | "REC 1 41:07", then `pause.fill` and 1 |
| P15 | main-program frame 3 | "Audio 1 of 2" with no warning form. Code counts live cameras only, so it is 1 of 1 and no warning | "Audio 1 of 1" |
| P16 | popovers, "Format fallback" | "ProRes 4444 isn't available for 2160p 59.94". The real reason is chroma: it needs an RGB source (`RecordingProfileMatrix.swift`), as the Format menus say | "ProRes 4444 needs an RGB source. This take records ProRes 422 HQ." |

**The rate for ProRes 422 HQ also needs a decision.** Every page says ~1.6 Gb/s, from 05's table. The estimator gives 1.77 (0.444 bytes per pixel, `RecordingSizeEstimator.swift:18`), and 05's own LT and 422 rows match the estimator, so 1.6 is the odd one. README says the rate must follow what records. Change to ~1.8 Gb/s on app-menus, menubar, sidebar-toolbar-states, popovers and alerts. Time-left figures barely move.

## 3. Invented: in neither code nor plan

| # | Page, frame | Item | Fix |
|---|---|---|---|
| N1 | strip-states, Effects menu | "Show in Inspector" row. README's menu holds Resize, Color, Frame rate, Camera Display, Effects Off | Remove. ⋯ has Show Inspector |
| N2 | inspector, Sony unassigned | "Open Hardware…" and "Pairing is in Settings". Needs a deep link the plan doesn't list | Keep, and add to README section 8 and phase 5 |
| N3 | alerts, Sync cameras | "Turn On Sync" | "Sync Cameras" (I1) |
| N4 | settings-hardware, Add by Address | "Sign-in required", "Expected identity" with placeholder. Code has a toggle "Camera access authentication is enabled" and "Expected stable identity (for example MAC address)" (`UICameraControl.swift:161-162`) | Use the code's strings |
| N5 | settings-hardware, Body not found | "Turn on Remote Shoot Function on the body…" | Keep only as text from the Sony plugin, with the boundary rule, and add to the plugin's hint list |
| N6 | settings-hardware expanded; diagnostics Device | "decklink:5B1F09E27C31" has 12 digits, "0x7e31a9c4" is another format. Code IDs are `decklink:` plus 16 hex digits | One value in that format on both pages |
| N7 | menubar, one camera | "Pause Recording ⌥⌘P". ⌥⌘P is Pause All. Selected-camera pause is ⇧⌘R | Row "Pause All ⌥⌘P", as the Record menu has |
| N8 | strip-states "LUT unavailable"; inspector "LUT file can't be read" | "Cine709.cube is missing", "Couldn't read this LUT…". The real text is `lutError` | One sentence, the real error's |
| N9 | strip-states "Two problems" | "Show" button | Make "2 problems" the control, as README says. Low |

**Plan-added, so not invented:** Name pattern tokens Camera, Date, Time, Take with the UUID dropped (03 E-list 2). "Record 1 of 2" (02 F12). Alert panel switch (D section 5). PCIe x4 Gen3, firmware, Media and Power in the expanded row (04's sketch). Temperature (07). Every background chord and the "In use" row note (D section 7). Sony property rows: all real, from `SonyControl.strings`.

**Option lists against code, all correct:**

| List | Drawn | Code |
|---|---|---|
| Strategies | Manual, Fixed interval, Natural talking head | `UIOutputModeControl.strategies`; Dynamic analysis gone |
| Codecs | 7 | `RecordingCodec`. "HEVC 4:2:2" is README's short form of "HEVC Main 10 4:2:2". Disabled reasons match the matrix |
| Timecode | Source timecode, Record Start, Mac Clock | `UITimecode` |
| Output size, Color format, Frame-rate cap | Values 1080p, Fit, 4:2:0 8-bit, 29.97 | Real. **No list is drawn open** (M15) |
| Guides | Lines, Matte, Both; safe 80, 90, 93, 95; 2.39:1 | Real |
| Zebra | Above threshold, Band; 0–109 IRE | Real |
| False color | Off, Sony S-Log3, ARRI-style, ARRI LogC, Six band, Custom | `UIFalseColorChoices.modes` |
| Scopes | RGB parade, Luma, Vectorscope, Histogram; Refresh 10, 15, 30 | Real, but 2 of 6 kinds undrawn (M14) |
| Zoom | Fit, 150, 200, 400% | Real |
| Advanced cut decisions | Six values | Defaults match `NaturalTalkingHeadSettings`; transcript rows hidden per B14 |

Popover example values (zebra opacity 80%, focus 60/30/100, guides 80%) aren't the code's defaults (65%, 50/2/85, 65%). No frame claims them as defaults, so they stand as made-up data.

**Shortcuts.** No collision in the app menus, the plan's new keys included: ⌃⌥H, ⌥⌘P, ⌥⌘G, ⌥⌘Z, ⌥⌘L, ⌥⌘F, ⌥⌘X, ⌃⌥D. Layout keys match `UILayout.allCases` order. All new ⌃⌥ keys share 03's documented VoiceOver limit, with menu items as the path. Background chords skip 8, per D. The one assignment error is N7.

## 4. Missing

| # | What | Home it needs | Fix |
|---|---|---|---|
| M1 | Right-click on a meter offers Channels Shown (README section 7). Popovers' caption says right-click resets loudness, and the meter owns its menu | strip-states | Add a frame, and resolve the right-click clash in the MonitorKit input |
| M2 | "Hold overrides once, and you're told" (README section 5) | alerts, Attention and status bar | Add "Signal lost, so Program moved to Camera 2. Hold stays on" |
| M3 | Program moved "and says so" (README section 4). Only the panel and notification draw it | alerts, Attention rows | Add a row, action Details |
| M4 | Unexpected stop "stays until acknowledged" (README section 5, B2). No acknowledge control on any page | strip-states, Attention | Add the action. Details could double as it: decide |
| M5 | Strip logo. README section 8 keeps it and fixes it. No strip draws one | every strip header | Add both marks, as code's `UIFeedBrandMark` |
| M6 | C12 driver missing or old as a status problem. Only Hardware and Diagnostics draw it | sidebar-toolbar-states | Add an Attention row and bar segment |
| M7 | J5 Show camera settings over picture, primary home the context menu | picture-states, Right-click | Add the row |
| M8 | G10 and `clearDefaultFolder`: Clear. "Clear" is on no page | settings, Folders | Default row menu: Show in Finder, Clear (06 Rows) |
| M9 | `resumeAll`. Only Help's sentence mentions it | app-menus, menubar | Add a Resume All state |
| M10 | "Formats converted" pill. Popovers refers to it, and no main-program frame draws it | main-program | Add a frame |
| M11 | Strip badge states: Unsupported format, Input disconnected, No input, Input missing. Picture only | strip-states | Add expanded and collapsed cells |
| M12 | `waiting` with no folder: "Needs a supported signal and a recording folder", Choose Folder… | strip-states | Add a cell |
| M13 | Toolbar Restore Layout while expanded (`UIToolbar.swift:39`) | sidebar-toolbar-states; app-menus View | Add a frame. Secondary: View › Detach to Window (03 H21) also absent |
| M14 | Scope kinds RGB overlay and YCbCr parade | monitor-tools | Add popover frames |
| M15 | Effects submenus open: Output size with 720p, 1080p, 4K UHD, Source size, 4K DCI; four Color formats; 13 frame rates; Aspect | strip-states, inspector | Draw one open list of each |
| M16 | Extension states: Needs a signed build, Waiting for macOS…, disabled while cameras run, and the running-camera footnote (`UISettings.swift:318, 376-377, 392`) | settings, Virtual Cameras | Add frames |

**States also worth a frame:** a menu bar with three or more cameras; a running camera with no signal since Start, which "Signal lost" doesn't describe (07 keeps the sentence for it); hover on the placeholders not yet drawn hovered.

**Everything else has a home.** Every other `UIAction` case and every other primary in 03's master table is drawn, or removed by decision. All 11 `UIStripState`, 8 `UITileState`, 6 `UISignal`, 4 `UITally` plus ISO, and 6 `UIMenuBarIcon` values are drawn.

## 5. Inconsistent between pages

| # | Fact | Values | Use |
|---|---|---|---|
| I1 | Sync confirmation | alerts: "Copy Camera 1's effects to Camera 2?", "LUT", Turn On Sync. inspector: "Sync cameras from Camera 1?", "monitor tools", Sync Cameras. Code copies both (`AppModel.swift:155-205`) | inspector's title and verb. Body: "effects, LUT, monitor tools, source declarations and preview setting" |
| I2 | Duration | "1 h 52 m" menus; "1h 52m" sidebar, status, strip; "22 m", "24m", "56m". Code: "1 h 52 m", "22 min" | Code's form, on every page |
| I3 | LT and 422 rates | ~844 Mb/s, ~1.2 Gb/s (app-menus, menubar); ~835 Mb/s, ~1.19 Gb/s (sidebar-toolbar-states). Estimator: 835, and 1.2 by `UIFormat.bitrate` | ~835 Mb/s, ~1.2 Gb/s |
| I4 | Format list | 7 codecs in menus, 6 in the Record toolbar menu (no HEVC Main 10) | 7 |
| I5 | Rate prefix | "64 Mb/s" overview, main-layouts; "~64 Mb/s" strip-states | "~64 Mb/s" per 07 |
| I6 | Output row on overview | No In use word, no "3 of 3". main-layouts also lacks the count | strip-states' row |
| I7 | Idle time left | 2 h 04 m (menubar, popovers); 1 h 52 m (sidebar-toolbar, main-layouts frame 7) | 2 h 04 m when idle |
| I8 | Drive low wording | "8TB: 22 m left", "8TB has 24m left", "8TB is nearly full", "8TB low" | "8TB is low" (O6) |
| I9 | Unexpected stop | "Camera 1 stopped on its own", "Camera 1 stopped: input disconnected", README "Camera 1 stopped: [reason]" | README |
| I10 | Interrupted row | "Interrupted take" with name; "2 interrupted takes" | The count form |
| I11 | Cuts not reaching | alerts: "Cuts aren't reaching a meeting app / It's using Camera 1, not Program." main-program: "…the app using Camera 1 / It shows only Camera 1. Choose Program in that app." | main-program's, which says what to do |
| I12 | Connector sheet | Two titles and bodies | Moot after P1 |
| I13 | Stop all cameras | "Stop Cameras" overview; "Stop All Cameras" elsewhere | 06's "Stop All Cameras" |
| I14 | Takes row | Overview "2 clean", "All"; elsewhere "0 lost", "Show All" | The latter |
| I15 | Status problem | Overview has no action button; elsewhere Details | Add Details |
| I16 | File names | "Camera 1_2026-10-30_14-22-31_001.mov" Settings, alerts; "Camera 1 2026-10-30 17-40.mov" strip, diagnostics; "Camera 1 2026-10-30 12-24" sidebar | The pattern's form |
| I17 | Device temperature | 68°C Settings; 52 °C Diagnostics | One value, "52 °C" |
| I18 | Memory | 1.32 GB popover; 1.84 GB Diagnostics | One value |
| I19 | FX3 B battery | 78 min menubar; 64% elsewhere | 64% |
| I20 | HDMI 4K timing | "60p 10-bit" badge menu; "59.94p 10-bit" sheet. Labels differ too | "59.94p 10-bit" and the sheet's labels |
| I21 | Camera display | "HDMI camera display" strip; "Camera Display" menubar. Plugin string is the former | The plugin's |
| I22 | Stopped sentence | "…to see its video input." (code); "…to see its picture" monitor-tools | Code's |
| I23 | Reminder, dialog | "Video only — select…" (code) against "Video only. Select…" popovers; "Forget Saved LUTs?" alerts against "Forget saved LUTs?" settings (code) | Code's in both |
| I24 | Sample data | Couldn't start names Right UltraStudio on Camera 1; White balance Manual on the overlay, Color Temp in the sheet; sidebar "UltraStudio 12G" for both units though README says nicknames matter; "60 frames lost in 32 gaps" against "5 · 60" | Camera 1 uses Left. Color Temp. Show the nickname. One pair of counts |

## 6. Rulings

**(a) Accept 342 pt. Keep the 980 minimum.** The brief's premise needs correcting: 400 is not a width floor. `UIDetailFit.width` returns `min(byWidth, max(narrowest, byHeight))`, so 400 limits height-driven shrink only, and today's app already gives 342 at 980 with a 236 pt sidebar (validation E agrees). The new strip's rows are drawn to fit at 342, though that isn't yet proven in the app. A minimum near 1100 pt would cost the Zoom-beside-Ultracam layout. Update the comment at `UIMainWindow.swift:152`.

**(b) Accept, at two cameras.** The on-air Cut row does nothing, and the card and camera row say On air. Update 07, which still gives Cut rows an "On air" badge. Tell the owner the cap can't hold beyond this rig: three cameras is 17 rows with the same rule. Keep rows in camera order.

**(c) Reject 6.5 pt.** 10 pt is 07's floor. Each channel has 16.6 pt at 340 pt wide, and "−23.4" needs about 30. Widen this popover to about 450 pt when any camera shows more than two channels. The 340 pt width is set in one place (`UIStatusBar.swift:240`) and can follow the popover's kind, and the per-channel maxima survive, which 07's test requires. Use the "Highest" line only at 16.

**(d) Cancel is default on everything that ends something.** Return must never end a take during a show. The mockup is right, and the code must change so Cancel takes Return. Check that `confirmationDialog` honors it, and use an alert if it doesn't. Keep the verb default on Rename, and Done on Interrupted Takes.

**(e) Add all seven missing keys to Help:** ⌥⌘P, ⌥⌘G, ⌥⌘Z, ⌥⌘L, ⌥⌘F, ⌥⌘X, ⌃⌥D. The window promises every shortcut, and 03 confirms that was true. ⌃⌥H is already there.

**(f) Read-only with a reason, no sheet.** The connector can't change under a running session, so a sheet offers a verb that fails. Stopping first would end a take, which is a bad thing to bundle into a Settings row. Use 04's row: "Stop Camera 1 to change". Have `settings()` return `mutable: false` with `availabilityReason`. Another app's use reads "In use by another app". Advertise HDR does work while Ultracam captures, so "ask first" stands for it. README section 8 needs this one-line change, so tell the owner.

**(g) One switch.** README says "off by default", singular, and D's "per group" was written for a home README moved. Chords are exclusive, global Record only starts, and Auto and Hold undo themselves, so groups add four switches and no safety. Keep the per-row "In use" note.

**(h) "Input".** README's copy clause adopts 06 section 5 with two named exceptions, and this isn't one. 06 keeps "Source" for the stage name alone, and a picture already says "Source before LUT". README section 6's list is the only place saying otherwise, so correct it. Rename the first row "Device", so "Input" isn't said twice. A one-word reversal if the owner prefers Source.

## 7. README walk, sections 3 to 9

Numbers point to findings above. Tick means drawn as decided.

| Section | Items ticked | Exceptions |
|---|---|---|
| 3 Defects with a visible form | B2, B3, B5, B9 corrected rates, B10, B11, B12, B13, B14, B15, B16, B17, B18, B19. B1, B4 (see section 5), B6, B7 and B8 have no separate drawn form | B2 acknowledge M4; B9 HQ rate |
| 4 ISO and Program | All cameras published, Program at 2+, no lock, ON AIR, ISO, NEXT, PROGRAM rules, waiting client problem, cut with ISO client, rename, add and remove live, Reset locked | Program move notice M3 |
| 5 Live alerts | One list, row replaces folder at one height, 2 problems, session problem in bar, Attention pinned, notifications, panel, rules 1 to 4, 6, placeholder clock, 10 s line | P5, O6, M2 |
| 6 Sidebar | Order, heavy case, Cameras content, Takes, one-line Virtual Cameras, reminder, no Switching, removals | P10, P11 |
| 6 Centre | Picture at rest, enabled tools, REC plain, Program View, strip removals, fixed rows, output row, one clock, signal badge | O1 to O4, O7, P4 |
| 6 Inspector | Order, merged rows, Remove LUT, Sync only here | P6, P7, I1, ruling (h) |
| 6 Toolbar | Three glass groups, Auto, Hold, Start Cameras, Record menu, red dots | M13 |
| 6 Status bar | Order, Program, Recording, Audio 2 of 2, Resources | P14, P15 |
| 6 Menu bar | Order, cap, no selection rows, LUT row | P8, N7, ruling (b) |
| 6 Background | Off by default, General, chords, Record starts only | Ruling (g) |
| 6 Visual language | One symbol per noun, chips, type, state as symbol plus color | O5, P3 |
| 6 Copy | Effects, Program color, Feed gone | P12 |
| 7 Settings | Eight tabs, 820 pt, every row per section, leavers gone, Channels Shown values, As Detected, 44 pt block, hidden channels, collapsed 1-2 | M1, M8, M16 |
| 8 Hardware | Vendor groups, absent hardware, hub hint, pairing, Setup block, advisory, idle status, battery units, build without SDK, no USB chip | P1, P2, M5 |
| 9 Format | Four homes, read-only strips, rates, disabled codecs, fallback in all surfaces, Timecode caption, Program not recorded | P16, HQ rate |

**Report 07 has one error of its own.** Its record-row table says `"Saving…" → "Finishing…"`, reversing 06, which replaces "Finishing…" with "Saving…". The mockup follows 06 and README. Correct 07, not the drawing.
