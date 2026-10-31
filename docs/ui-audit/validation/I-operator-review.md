# I. Operator review of the r5 mockups

Date: 2026-10-31. Reviewed: `docs/mockups/r5/`, renders in `png/`, against `docs/ui-audit/README.md` and validation C. Read-only. Nothing was run.

**Evidence limits.** These are static mockups with made-up data, so timing, click-through and real meter behavior are untested. Target sizes are measured off the renders. See "Coverage" at the end for what I did not look at.

## Verdict

This is a real improvement and close to right. Strips that never change height, the problem-first status bar, Attention that disappears when empty, and the alert panel are all things I'd run a show on.

It is not ready to build as drawn. Three faults would hurt in a real session:

1. **The plan's panic control exists only on expanded strips.** Program View and Four Up have no LUT toggle at all.
2. **The worst event in the show is the quietest frame.** A lost on-air camera drops from red to a white outline, on a dark card, with a 21 pt grey button.
3. **Cut is the weakest control in Program View.** The red Stop buttons are the loudest, and they sit next to ⋯ with no prompt.

Clutter has mostly moved rather than gone. The plain text is fixed, but the strip's two middle rows are now a wall of chips, and the status bar has a glyph on every segment.

## Blocks

| # | Page · frame | Problem | Exact change |
|---|---|---|---|
| B1 | main-program, all frames · main-layouts 3 · strip-states, every collapsed strip | **No LUT toggle on a collapsed strip.** README and validation C count "Bad LUT, window visible" as 1 action. That holds only on an expanded strip. "LUT" appears nowhere in main-program's text. In Program View it's expand plus toggle, 2 actions, and expanding a strip can resize pictures (`gridFit`, validation C), or 4 gestures from the menu bar. ⋯ only offers `Load LUT…` | Add a fixed-width `LUT On` / `LUT Off` slot to the collapsed row, same words as the expanded toggle, left of the meter. In the 342 pt cell the compact meter yields first, as it already does. Validation C's count of 1 action is wrong as drawn |
| B2 | main-layouts 3 (Four Up) | **No Cut on the strip or tile.** Cut has been kept for "eyes on the pictures", but with four pictures on screen the only target is the toolbar. Program View gives each tile a Cut; Four Up gives none | Add the Cut slot to the collapsed row whenever the layout has no tile Cut. Program View doesn't need it |
| B3 | main-program, all · sidebar-toolbar-states, Toolbar | **Toolbar cuts read as tabs.** `1 Camera 1` `2 Camera 2` looks like a segmented selector with a filled current item. D1 says clicking a picture selects and never cuts, then this lookalike goes straight to air. A tired click "to look at Camera 2" cuts the meeting | Leave them where they are. Put one ⇆ glyph at the start of the group, one only, so the group reads as Cut. Add "Cut to Camera 2" as help. It stays at digits-only widths |
| B4 | main-program 1, 2, 4, 5 | **Cut has the least weight below the pictures.** A grey 27 pt bar with a dim label, while two to four solid red Stop buttons sit below it. Red means "stop the take" more loudly than it means on air | Tile Cut: 36 pt tall, bold label, the same stronger gray as the `LUT On` button, the key shown as `Cut ⌃2`. No white fill: white already means "this is on" (P6, tools), so Cut gets its weight from size and position. Collapsed rolling strip: Stop is a neutral square, always, with no hover state, because the pill already says it's rolling. Red below the pictures then means a meter problem |
| B5 | strip-states, collapsed · main-program · main-layouts 3 | **Stop sits about 11 pt from ⋯ on a row you click in a hurry, and it doesn't ask.** Settings says "Plain ⌘R on one camera stays unprompted", and alerts has no dialog for one take, so as drawn a miss on ⋯ ends a take. Four Up has four of these | Don't add a prompt. Move ⋯ to the left of the meter so the meter separates them: `name · state · LUT · ⋯ · meter · Stop` |
| B6 | main-program 3 · picture-states "Signal lost, on air, Auto off" | **On-air loss calms down instead of up.** ON AIR becomes a white outline, the red ring goes, and the card is near black. The rule "no red without frames" is right, but nothing replaced the alarm. The way out is a 133 × 21 pt grey button in the middle of the largest picture on screen. The fault is also said in six places: sidebar glyph, Attention, Program placeholder, tile placeholder, collapsed strip, status bar. `Cut to Camera 2` appears three times, and with tile Cut and toolbar that's five ways to do one thing | Program picture and on-air tile get a 4 pt **orange** ring and a filled orange `NO PICTURE` pill. Program placeholder Cut matches tile Cut: 36 pt tall, at least 200 pt wide. Remove the button from the Attention row for this one problem, because you're looking at the picture, not the sidebar. Keep it in the status bar. **This departs from README section 5,** where every render of the list carries the action. The tile placeholder drops to glyph and "Signal lost", with no timer and no sentence |
| B7 | picture-states "Signal lost, rolling" · main-program 3 · overview · strip-states `recordingNoSignal` · alerts | **The take warning is wrong at the moment it matters.** `Signal lost 0:06` above `Take continues for up to 10 s` makes you do subtraction. A loss over 10 s ends the take. Beside it, a green `0 dropped` reassures you while the badge says `No signal · 5` | Replace with a countdown: `Take ends in 4 s`, in Attention and the placeholder. While signal is lost, the green tick row reads `Losing frames` in orange. **This changes the plan as well as the mockup:** README section 5 specifies how long the signal has been lost, and that the take ends. Keep the lost time, and say the end as a countdown |
| B8 | picture-states "Signal lost, off air" small · strip-states collapsed, LUT unavailable and Fallback · main-program 3 | **Failures lose their instruction when the strip collapses.** "The strip says what to do", but a collapsed strip reads only `No signal`, and LUT and fallback problems shrink to `Ready ⚠`, which is no use. Stopped, Couldn't start and 2 problems already carry words and an action on the collapsed row, so this is inconsistent | Collapsed row shows the problem's short name instead of the state: `Check HDMI`, `LUT missing`, `ProRes fallback`, with its action as a small button in the row, as `Stopped [Start]` already does |
| B9 | picture-states "Frozen", right frame | **A frozen picture looks live at rest.** The caption admits nothing marks it. Mid-show that reads as a hung camera, and you start restarting things that aren't broken | Add a `Frozen` stage pill beside the name at rest, in the slot `Source before LUT` already uses. Same treatment for `200%` |

## Repetition counts

Counted from the renders and each page's text.

| Fact | main-layouts 4 and 5 (Side by Side, 2 cameras, on air) | main-program 1 (2 cameras) | Drop |
|---|---|---|---|
| **On air** | 6 with the sidebar open, 5 closed: toolbar dot, sidebar badge, ring, pill, strip `On air`, status `Camera 1` | **9:** toolbar dot, sidebar badge, Program ring, Program pill, Program `Camera 1` label, tile ring, tile pill, `On air` under the tile, status `Camera 1` | Sidebar badge. The tile's pill and the `On air` caption: the tile keeps its ring. Keep the slot's height. ISO and PROGRAM pills stay, because those carry information. Program picture keeps ring, pill and label |
| **Recording state** | 8 for 2 takes: REC pill ×2, `● Recording` ×2, Stop ×2, toolbar, status | 8: the same | `● Recording` word and dot on rolling strips, expanded and collapsed. The big clock beside the stop square says it. Paused, Saved and Failed keep their words. The space goes to the LUT slot |
| **Clock** | 3: strip ×2, status. Plus sidebar Takes `12:31`, a different fact that reads the same | 3: pill ×2, status. Plus the same sidebar figure | Leave at 3: per take plus session is the plan's floor. Fix the look-alike: `Last take 12:31`. See P9 |
| **Format** | Record format 3: sidebar, strip ×2. Output chips ×2. Source badge ×2 | 1 and 1. Clean | Leave record format. Cut the output chips: P1 |
| **Time left** | 4: sidebar, strip ×2, status | 2 with sidebar, 1 without. Clean | Remove from strips. Status bar shows the worst drive, sidebar shows every drive. Both exist in every layout that has them |
| **Problem** (one camera) | overview: 6 places. Picture, signal badge, strip row, status bar, Attention, sidebar glyph. The sentence `Take continues for up to 10 s` is word for word in picture and Attention | Frame 3: 6, as in B6 | Sidebar glyph stays, because it's state. Attention stops repeating the picture's sentence: it states the consequence for the take and nothing else. B6 for the buttons |
| **Virtual camera use** | Sidebar 3 rows, strip ×2, status: `Not in use` 5 times on one screen in frame 1, plus `0 of 3 in use` | Sidebar and status | Print `In use` only when true. Gray glyph is enough for not in use |

README section 5 says "One problem, said once per place." Picture and Attention break that as drawn.

## Polish

| # | Page · frame | Problem | Exact change |
|---|---|---|---|
| P1 | strip-states and main-layouts, every expanded strip | The output row holds 8 items: Cut, glyph, 3 chips, in-use, LUT, Effects. With the folder row above, that's a wall of chips at two feet. Nobody reads chroma subsampling live | Make the 440 pt fallback the default at every width: one value, `1080p 29.97`. Row reads `Cut · 1080p 29.97 · LUT On · Effects`. 4:2:0 8-bit stays in the Effects menu and signal badge |
| P2 | strip-states, every state | `Effects 3 of 3` tells an operator nothing | `Effects` normally, `Effects Off` when off. main-layouts already omits the count: match it |
| P3 | main-layouts 1, 2, 4, 7 | `64 Mb/s` is on the strip 7 times on that page. README says bitrate leaves the strip. It's in the Recording popover | Remove. It frees the folder row |
| P4 | status bar, all | Seven or eight glyphs on one small line, most duplicating their word. Report 07's rule of icon plus value went too far here | Keep the triangle, REC dot and green Program glyph. Remove tv, timer, wand, drive, waveform. Merge `Program In use` and `Camera 1` into `Program: Camera 1 · 8 s`. Show `Auto in 4 s` only while counting, because the toolbar owns Auto and Hold. Keep the shot bar. Keep Audio as words |
| P5 | sidebar, Cameras · main pages | `UltraStudio 12G · HDMI` twice is useless on a rig with two identical units. Settings says `Left UltraStudio` and `FX3 A`. Plug and clock glyphs are decoration | Use nicknames. Remove `HDMI` unless the input isn't HDMI, the Wi-Fi glyph unless degraded, and the plug and clock glyphs. Keep the green camera, slash and battery |
| P6 | toolbar, Auto On, Hold on | Whether a machine is cutting is the second most important fact on screen. `Auto On` and `Auto Off` differ by one word and a slight gray. Hold on is nearly the same pill | Use the on-state the tools already have: white fill, dark glyph, for Auto On and Hold on. It's a fill, not an accent tint, so it holds in a non-key window. Keep fixed widths |
| P7 | all problem surfaces | Every problem has the same amber. An interrupted take from this morning looks like a camera stopped on air, so order is the only urgency signal | Two levels. On air or rolling damage: solid amber fill, dark text. Everything else: today's outline. Same split in Attention, status bar, menu bar and the Problems popover |
| P8 | strip-states `failed`, Take ended early · alerts · overview | `Take ended at 18:58` reads as 6:58 PM. It's a duration. There are also three names for one event: Recording failed, Take ended early, Camera 1 take ended | One wording everywhere: `Take ended early` and `18:58 saved`. Same fix for `Take saved up to 12:31` |
| P9 | sidebar, Takes | `12:31` next to a rolling `12:31`. Also three forms across pages: `5:40 PM 12:31 · 2 · 0 lost`, `2 cameras`, `2 clean`, and `All` vs `Show All` | `Last take 12:31`, then `0 lost`. Drop the camera count. Use `Show All`. One word for the fact: **lost**, not dropped or clean |
| P10 | alerts, Alert panel, Take ended early | `Details` is the wrong action. The only thing you want is to roll again, and the panel is the only surface reaching a full-screen meeting | `Record Camera 1` when the camera is live, `Details` otherwise. This does not start a take automatically |
| P11 | main-program 7 · alerts | Status bar action is `Details`, but the fix is in the sidebar's small print, so sidebar closed costs a click to learn it. The name also differs on the two pages | Status text: `Meeting app is on Camera 1, not Program`. Then `Details` has little to add, and can stay |
| P12 | alerts, Extension queue stall · picture-states CPU pills | `Queue full for 2 s`, `Ingest 212`, `Compatibility conversion Recording 96` are engineering words on live surfaces | Remove `Queue full for 2 s`. Keep the `CPU copy 212` pill, since you want it seen; `Compatibility conversion` moves to the Recording popover |
| P13 | sidebar-toolbar-states, Problems · strip-states `disk full`, `failed` | "One action each" isn't held: `Start` + `Why`, and `Choose Folder…` + folder icon + `Details` | One button. `Why` and `Details` move into a click on the row. Folder icon goes |
| P14 | main-layouts 6a | Caption hides timecode under a 560 pt picture. picture-states calls 549 pt normal and shows it. Timecode has nowhere else outside the inspector, so at a default window it may never show | Set the line at 480 pt, matching the tool bar's |
| P15 | picture-states "Clean View, at rest" | "Every overlay gone, tally included." The ring doesn't cover the picture, and Clean View with an expanded strip leaves only a gray `On air` | Keep the ring in Clean View |
| P16 | picture-states "Selected and on air" · main-program | Blue ring around red ring is the busiest edge on screen, and selection is the least urgent fact there | 1 pt blue when a tally ring is showing, 2 pt otherwise. Fixed blue stays |
| P17 | picture-states, Signal lost vs Unsupported format · overview | Three glyph rules: gray slash plus small triangle, large triangle alone, orange slash alone | One large orange glyph per placeholder, no second one, per the page's own caption |
| P18 | picture-states "Unsupported format" | The only serious failure with no button | `Show Diagnostics` |
| P19 | monitor-tools "At rest, every tool on" | Tools at rest are white-filled, so they're the brightest thing on the picture, brighter than ON AIR, in the opposite corner. The owner's behavior stands; this is its styling only | At rest: white glyph on the dark capsule, no white fill. White fill stays in the hovered bar. Still one click to turn off |
| P20 | monitor-tools, hover | 7 icons and 7 chevrons are 14 small targets. Zebra, Clip and Picture are not readable as symbols. Lives with the owner's ruling, so no change to the behavior | Enlarge chevron hit areas to the glyph's height. Keep names in help |
| P21 | menubar, icon row | Effects off, Recording and Attention are a blob at the lower left of one icon at real size. Recording must not need a squint | Remove the Effects off badge. It's not session-critical and the panel says it |
| P22 | menubar, row order | `Stop All Cameras` sits directly under the camera rows with no separator, so a slip off a camera row lands on it | Keep the prompt and add a separator above it |
| P23 | inspector · alerts · settings-hardware | Same sheet named `Camera Settings` and `Camera Control`. Same questions drafted twice: Sync (`Turn On Sync`, `Sync Cameras`), connector (two titles) | Name: `Camera Control…`, as Attention, menus and README use. One dialog each, and the alerts page version wins, since it has Cancel as default |
| P24 | settings-hardware, expanded body | `Unassign` and `Disconnect` sit beside the common `Camera Settings…`, equal weight | Put a gap before them, with `Camera Settings…` alone at the left |
| P25 | monitor-tools, detached window | `Output (LUT)` picker next to `Picture: Output (LUT)`, five text buttons, then six mono lines | Remove the `Picture:` caption. Fold the mono lines under the existing `Monitoring diagnostics` |
| P26 | overview | The page the owner opens first is stale: failed row, menu bar, Hardware, Takes (`2 clean`, `All`), legend text says "green check" | Redraw from the same kit as the other pages, or it will read as the design |
| P27 | main-layouts 7 · README | `Folder for Next Take…` shows when nothing is rolling. Validation C says `Change…` idle | `Change…` when idle |
| P28 | wording, across pages | `8TB has 24m left`, `8TB: 22 m left`, `8TB is nearly full`; `1h 52m` vs `1 h 52 m`; `camera app` vs `meeting app`; `Camera 2 no signal` vs `signal lost`; `see its video input`, `HDMI input`, `picture` | Pick `8TB: 24m left`, `1h 52m`, `meeting app`, `signal lost`, `picture` |
| P29 | main-program 1 | About 100 pt empty between the strips and status bar, while Program could be larger | Give the spare height to Program by narrowing the tile column. Strips stay anchored at the bottom |

## The questions

**1. Does each surface read in one glance?** Picture and Program: yes. Toolbar: yes. Status bar: no, P4. Expanded strip: top half yes, rows 3 and 4 no, P1 to P3. Sidebar: mostly, P5. Popovers: yes for what they are. Audio's two prose blocks are long but off the live path. Diagnostics is a wall, and that's correct. Settings: reads well.

**2. Repeated on one screen?** See the table. Worst: on air 9, problem 6, `Cut to Camera 2` 3.

**3. Harder than today?**

- **Effects in a menu: keep it.** Nothing in it is a live action, each row changes what Zoom receives, and the output value on the row shows the result. It's right provided the LUT toggle is really one click everywhere, which is B1.
- **Stop Camera in ⋯: keep it, on two conditions.** ⋯ has 10 rows, with Stop ninth, so it's a click plus a scan. Remove `Load LUT…`, `Choose Recording Folder…` and `Use Default Folder`, which the inspector and File menu cover. Add `Restart Camera` above Stop: the action already exists for B16, and a hang is the only live reason to open this menu. That's 8 rows, and recovery goes from 3 or 4 actions to 2, or 3 with a confirmation.
- **Also harder:** LUT off on collapsed strips, B1. Timecode, P14. Pause on a collapsed strip is 2 clicks: accept. Recent Cuts behind a popover: accept, it's one click. Format with the sidebar closed: accept, it's setup.

**4. Do failures say what happened and what to do?** Mostly. Status bar, Attention, menu bar and the alert panel are good and ordered worst first. Gaps: B6, B7, B8, P7, P10, P11. The on-air-lost alert panel with `Cut to Camera 2` is exactly right.

**5. Hierarchy?** Program View's top half is right: Program is biggest and says who is on. **Can you cut without looking down?** With a key, yes, but nothing on screen teaches the key. With a mouse, the Cut is right beside the tile, so your eye barely moves, which is the right place, but it has to be findable without reading: B4. Side by Side is fine once P1 thins the strip.

**6. Is the sidebar worth its width?** For setup and between takes, yes. Live, no, and that's fine, because it passes the close-both-panes test. Closed, you lose the hardware lines, the full virtual camera list, one-click Format, and the last take's lost count. None is a live need, and low battery reaches the status bar through the problem list. So: close it for the show. Keep it, cut per P5 and the counts table, and make `⌃⌘S` something people learn.

**7. Finish?** P8, P13, P23 and P28 are what a tired operator would notice as sloppy.

## What works: don't break it

- Strips never change height, so Cut never moves.
- Problem-first status bar with its action in the bar.
- Attention gone when empty, never opening the sidebar.
- Fixed-width `Stop 2 Recordings`, with no clock making it wobble.
- `Auto On` and `Auto Off` as words, and Hold always present.
- The shot timer turning yellow past the soft maximum.
- Program View tiles with Cut beside the picture, and the two-across four-camera layout.
- NEXT as green ring plus word, and "Next" on both buttons.
- ISO and ON AIR separated by glyph, and red only when frames arrive. Keep that rule; B6 adds orange, not red.
- The big stop and record target on expanded strips.
- LUT as a one-click word toggle on expanded strips. B1 extends it.
- Cancel as default on anything that ends something, with named verbs.
- Menu bar panel: the picture, cuts first, and no row depending on selection.
- Alert panel wording and its `Cut to Camera 2`.
- The REC pill that never truncates, and the status bar keeping Program and REC at its narrowest.
- Settings › Hardware and its single-action Setup conflict.
- Recording popover's per-camera grid, which earns its density.

## Coverage

Read at full band resolution: main-program; main-layouts apart from frame 2, the top of frame 3 and the end of frame 8, which I read as page text only; picture-states apart from its last band; strip-states; sidebar-toolbar-states; popovers; alerts; menubar; app-menus; inspector. Sampled only: monitor-tools (bands 0, 1, 3, 8, 9, 10), settings (0, 2, 3), settings-hardware (0, 2, 3), diagnostics-help (0, 2), overview (0, 1). Help text wasn't reviewed.

B5's "doesn't ask" is inferred from Settings' wording and from alerts having no single-take dialog. The plan doesn't state it for the strip button.
