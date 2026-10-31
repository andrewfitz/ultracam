# C. Operator red team of the proposed interface

Date: 2026-10-30. Reviewed: `docs/ui-audit/README.md` sections 5, 8, 9 and 10, reports 02 and 06, and the code at `2c4929c`. I did not write the proposal.

**Evidence limits.** Everything here comes from reading code, renders and the reports. Nothing was run. Behavior I traced but did not see is marked "traced". Heights are estimates built from row sizes measured in `component-sidebar-*` (2x renders, 260 pt wide).

## Result

The proposal is sound and mostly a real improvement. Morning setup drops from about 20 actions to 9, and the failure cases get better everywhere except two. Most of its calls stand. It has one wrong call, one false claim and three layout problems.

**Wrong call.** LUT off moved from one click to two. In the panic case the fix is LUT off, not Effects off. The proposal treats them as one hazard. They are opposites: LUT off changes pixels only, and Effects off changes the format Zoom is receiving.

**False claim.** "Close both side panes and lose nothing you need" is not true as written.

**Layout problems.**
- Strip alert rows still change the strip's height, so the Cut button moves at the moment you reach for it.
- Hold appearing beside Auto moves the toolbar under the pointer.
- The left pane puts Recording, and so the owner's Format control, below the fold on a 13-inch display.

| # | Call | Verdict |
|---|---|---|
| 1 | Stop Cameras off the toolbar while running | **KEEP** |
| 2 | Processing, LUT and effects in an Effects menu | **REVISE** |
| 3 | Format global, in the sidebar, read-only strip label | **KEEP** |
| 4 | Timecode picker in the sidebar | **REVISE** |
| 5 | Hardware in the sidebar, none on the strip | **KEEP** |
| 6 | Stop Camera in the ⋯ menu | **KEEP** |
| 7 | One clock per camera, session clock in the status bar only | **KEEP** |
| 8 | Strategy only in the toolbar Auto menu | **KEEP** |
| 9 | Cut button on the strip as well as the toolbar | **KEEP** |
| 10 | Attention in the sidebar | **REVISE** |
| 11 | "Close both side panes and lose nothing" | **REVISE** |
| 12 | Left pane height | **REVISE** |
| 13 | Scope | **REVISE** |

## How I counted

- **Actions:** clicks, key presses and required menu levels. A system file dialog counts as "+dialog".
- **Attention moves:** changes of pane or window the operator must look at.
- **Assumptions:** sidebar open, Zoom windowed, no background shortcuts, unless a row says otherwise.
- **Today:** recounted from the code. Report 02 says confirming format takes 5 actions, but the sidebar and the Ready line already show it, so reading is 0 and changing is 5.
- **"With fixes":** the proposal plus the revisions in this file.
- **Not counted:** a first click that only activates the window. See live check 1.
- **Totals:** they exclude steps set once per rig (timecode, Anchor, Emphasis), and also Hold, which is optional. Those rows appear in the step table.

## Before and after

### Totals

| Workflow | Today | Proposed | With fixes |
|---|---|---|---|
| 1. Morning setup | 19 to 23 actions, 7 moves | 9 actions, 3 moves | 9 actions, 3 moves |
| 2. Zoom, backup started mid-call | 4 actions, 1 move | 4 actions, 1 move | 4 actions, 1 move |
| 3. Two-camera ISO shoot | 10 actions, 5 moves | 6 actions, 3 moves | 6 actions, 3 moves |
| 4. Program, cuts, Auto, override, record | 7 to 9 actions, 4 moves | 6 actions, 3 moves | 6 actions, 3 moves |
| 5. Bad LUT, window visible | 1 action, 1 move | **2 actions, 2 moves** | 1 action, 1 move |
| 5. Camera hang, recovery only | 2, or 3 with a confirmation | **3, or 4 with a confirmation** | Same as proposed, but detected |
| 6. Cut with Zoom full-screen | 3 gestures | 3 gestures | 1 key, once the shortcuts are scheduled |

### Step by step

| Step | Today | Proposed | Result |
|---|---|---|---|
| **1. Morning setup** | | | |
| Launch, Start Cameras | 2 | 2 | Same |
| Choose output mode | 1, or 3 and a wait | 0 | Better |
| Which device feeds each camera | 4 to 6 | 0 | Better |
| Camera control link | 2 to 4 | 0 | Better |
| Read format and timecode | 0 | 0 | Same |
| Change format | 5 | 2 | Better |
| Change timecode | 5 | 2, or 5 with fixes | Same with fixes, set once per rig |
| Choose strategy | 2 | 2 | Same |
| Set Anchor or Emphasis | 2 each, in Program View | 3 each | **Worse**, rare |
| Pick the camera in Zoom | 3+, one device listed | 3+, three devices listed | **Worse**: an easy wrong pick, caught only by the row and tally |
| **2. Zoom, backup mid-call** | | | |
| Roll from the menu bar | 2 | 2 | Same |
| No folder set | Dead end | 2 + dialog | Better |
| Processing row next to Record | Hazard | Gone | Better |
| Stop | 2 | 2 | Same |
| Meeting ends, take still rolling | Nothing says | Nothing says | **Still wrong** |
| **3. ISO shoot** | | | |
| Set format | 5 | 2 | Better |
| Change default folder | 1 + dialog | Not defined: README's mock drops `Change…` | **Worse as drawn**; keep the button |
| Room check | 0, wrong figure | 0, right figure | Better |
| Roll, stop | 1, 1 | 1, 1 | Same; better labels |
| Add a late camera | 1 on the strip | 1 on the strip, 2 from the toolbar | Better |
| Prove the takes are clean | Script or log | 0 | Better |
| Find the takes | 1 to 3 | 1 | Better |
| **4. Program** | | | |
| Enter Program with takes rolling | 6+, plus Zoom reselect | 0 | Better |
| Cut, Auto on, override, record | 1 each | 1 each | Same |
| Hold, sidebar open | 1 | 1 | Same |
| Hold, sidebar closed | 2, Program menu | 1 | Better |
| Read shot timer, sidebar closed, Program View | 0 | **Not possible** | **Worse** |
| Read recent cuts, sidebar closed, Program View | 1 scroll | **Not possible** | **Worse**, low cost |
| Know when Auto can cut after an override | Not shown | Not shown; README drops 02's F22 fix | **Still wrong** |
| **5. Failures** | | | |
| HDMI loss on air, Manual | 1 | 1, also on the placeholder | Better aim |
| HDMI loss on air, Auto | 1, Auto doesn't react | 0 after about 1 s | Better; return is undefined |
| Bad LUT, window visible | 1 | 2 | **Worse** |
| Bad LUT, app hidden | 5 | 5, or 4 with fixes | Same, better with fixes |
| Drive low | One orange segment | Notification and row, same recovery | Better warning |
| Drive-full recovery | 3 + dialog | 3 + dialog, +1 with the sidebar closed | Same or **worse** |
| Both cameras drop together | One warning | Full list | Better |
| Camera hang | See Failures below | | Mixed |
| **6. App hidden, full-screen meeting** | | | |
| See a problem | Reveal the bar | Notification, untested | Better if it arrives |
| Cut, Auto, Hold | 3 each | 3 each | Same |
| Record one of two | 4 | 3 | Better |
| Change format | Not possible | 4 | Better |
| Effects off | 3, on an unseen selection | 4, on a named camera | Worse by one, and correct |

## Failures: what the code actually does

**HDMI loss.** Section 4 is right, and two rules are missing. `manualHold` means "Auto stays on but makes no cuts", so a Hold left on keeps Program on a dead camera. And section 4 sets a hold before cutting away, but no hold before cutting back. On this rig dropouts come in bursts on both cameras (2026-10-30), so Auto could bounce.
- **Add:** lost signal on the on-air camera overrides Hold, clears it, and says so in Attention. A dead picture isn't a shot worth holding.
- **Add:** a camera is not eligible again until its signal has been steady for 5 s.

**Camera hang.** The word covers three different faults, and only two are handled.

| Fault | What happens | In the proposal |
|---|---|---|
| GPU stuck over 2 s | The watchdog calls `fail()` and the camera stops (`CaptureController.swift:709-722`) | Covered by the unexpected-stop row, 1 click to Start |
| Capture stops delivering | The watchdog reports no signal and waits for the source (`:725-737`) | Takes the HDMI-loss path |
| Camera extension stops taking frames | `.full` is counted and logged only (`:2297-2303`, `:1362-1369`) | **Not covered.** Zoom can freeze while Ultracam looks healthy (traced) |

The third is the bad one. No alert exists, tally stays red, and recovery means hunting. See "What is missing" item 1.

**Drive filling.** `Change…` applies to the next take only, so on a rolling take the row promises more than it does. Name the action `Folder for Next Take…`. Also move B9 and B10 from phase 4 to phase 1. Otherwise phase 1 ships a low-drive notification driven by an estimate README itself calls about 11 times short on HEVC. A false alarm in a morning setup teaches the operator to ignore the one that matters.

## The calls

### 1. Stop Cameras removed from the toolbar while running: KEEP

No live job needs to stop every camera. It's an end-of-day action, and ⌘↩, the Camera menu and the menu bar cover it. Removal also fixes a hazard the reports don't mention: today a double-click on Start Cameras lands its second click on Stop Cameras in the same spot.

Two details need writing down:
- `camerasRunning` is true if any one camera runs, so the new rule must be "shown while any camera is stopped", labeled "Start Camera 2" when only one is.
- README section 5's menu bar order omits Stop Cameras, while its toolbar section promises it. Add the row.

### 2. Processing, LUT and effects in an Effects menu: REVISE

**The panic case.** Everything in this menu was treated as equally dangerous, and that's the error. The code separates them:
- **LUT off** changes pixels, not format. `AppModel.swift:1432-1442` sets `contract.applyLUT = false` with the comment "it never renegotiates the Program camera". The chip's own help says the same. Report 02 kept it on the strip for this reason, and section 9 lost that when it adopted 06's menu.
- **Effects off** is the opposite. It restores the source's resolution, color and frame rate, so the format Zoom receives changes. `pipelineEnabled` also feeds the Program contract.

So one-click bypass is a safety control, but the safety control is **LUT off, not Effects off**. A wrong picture in a meeting is a bad LUT nearly every time, and the operator's hands should not go through a menu to reach it. Taking Effects off the live surface is correct.

There is a second loss. README's output line doesn't mention the LUT, so with the chip gone nothing on the live surface says a LUT is on.

**Replacement for README section 5, Output row:**

> **Output row:** Cut slot, then "Output 1080p · 4:2:0 8-bit · 29.97 · In use", then a **LUT toggle**, then one **Effects menu** holding Resize, Color, Frame rate and Effects Off. The LUT toggle is one click, because it changes pixels and never the output format. Everything in the menu is two deliberate clicks, because each one changes what Zoom is receiving.

Rules:
- The toggle has a fixed width, with a slot reserved when no LUT is loaded, so nothing moves. It's today's chip without the width change V5 complained about.
- With Sync cameras on, the toggle changes both cameras (`AppModel.swift:1572`). That's correct, and the button help should say so.
- Below 440 pt the output line falls back to "1080p 29.97 · In use". The row as drawn doesn't fit a 400 pt cell.
- In each menu bar camera submenu, LUT becomes a direct row. It's nested under Effects today, which costs 5 gestures. That makes it 4.
- Use one noun. README says "Processing" and 06 says "Effects". Use 06's "Effects Off". ⇧⌘B stays: it needs Ultracam frontmost and V7 fixes its target.

Section 9's "Effect chips" row changes to match.

A LUT flip still goes through `reconfigure` and shows "Updating output…" briefly (`AppModel.swift:1596`, `CaptureController.swift:755-758`). The format doesn't change. See live check 2.

### 3. Format global, in the sidebar, read-only strip label: KEEP

Global suits one operator on 1 to 2 cameras: fewer surfaces, and fallback covers mismatched sources. 05's A-cam and B-cam case is real, but it can be added later. The sidebar plus the Record menu means closing the pane loses nothing. The label stays read-only, because a control on a strip that changes every camera would mis-state its own scope.

One conflict to settle: README puts the label on the folder row, and 06 V10 puts it on the Ready line. Use the folder row. It's there in every state, and the Ready line is replaced by the clock during a take. Drop V10's Ready text.

### 4. Timecode in the sidebar: REVISE

It fails the proposal's own rule. Timecode is set once per rig, and nobody changes it live. Once B1 saves it, a picker pays for itself perhaps a few times a year.

The drawn row also can't exist: "Format [...] Timecode [...]" needs about 320 pt, and the pane is 236. It costs a second row in a pane that's already over budget.

**Replacement in the sidebar's Recording section:**

```
Format [HEVC 4:2:2 ▾]
Camera original · Mac Clock
```

The caption gives the morning check at 0 actions. The control stays in Settings › Recording, so remove Timecode from "Leaves Settings" in README section 6.

### 5. Hardware in the sidebar, none on the strip: KEEP

The strip keeps the signal badge, and that's all it needs live. Two conditions, because the mock's text is wider than the pane:
- At 236 pt, "UltraStudio 12G · 2160p 59.94 · 4 dropouts" truncates at about 35 characters and loses the dropouts. Write it as `2160p 59.94 · 4 dropouts · UltraStudio 12G`, so the device truncates first. Full name in help. The signal badge's menu names the input, as 04 proposes.
- A low camera battery shows only in the sidebar line. If the control vendor reports it, it needs an Attention row.

### 6. Stop Camera in the ⋯ menu: KEEP

Recovery costs one more click on a rare action, in exchange for removing the largest labeled control on the strip, which is destructive and almost never used live. Start then appears in the same header position, so the second step needs no hunting.

The operator's problem with a hang isn't that click. It's finding out, which is covered under "What is missing".

### 7. One clock per camera, session clock in the status bar only: KEEP

06 section 2 and README section 5 agree on the rule: toolbar clock gone, one per camera, session clock in the status bar. Compact Program View tiles work, because their strips are collapsed and the pill keeps its digits. A fixed "Stop 2 Recordings" also stops the toolbar changing width each second.

Corrections to 06 section 2:

| Row | 06 says | Should say |
|---|---|---|
| Take clock, per camera | No echoes | Menu bar row allowed: it's the only view when hidden |
| Take clock, collapsed strip | Remove digits | Keep digits when the picture is in Clean View. Otherwise Clean View plus a collapsed strip shows no clock |
| Output format | Owned by the picture menu | Owned by the strip output row. The picture menu only appears on hover |
| Tally, sidebar row | 3+ cameras | Every count |
| Camera original note | Ready line | Sidebar caption, per README |

Also, 02 keeps the clock on collapsed strips and 06 removes it. Take 06, which README cites.

### 8. Strategy only in the toolbar Auto menu: KEEP

It suits pre-show. `SwitcherSettings` is saved, so this is usually a check, and the sidebar shows it for free. A sidebar picker would cost the same 2 clicks and add a stray-click risk.

This departs from the placement rule's "pre-show setup goes in the left pane", and that's fine: one control is worth more than the rule.

Spec gaps to close:
- With strategy Manual, clicking Auto opens the strategy menu and choosing turns Auto on, as `UIToolbar.swift:119-124` does now. The proposal doesn't say.
- Anchor and Emphasis stay enabled with Auto off. Program View disables them today (`UIProgramView.swift:157`), which is backward for pre-show setup.
- README and 06 V4 disagree on whether Hold sits in this menu. README wins: it's a separate button.

### 9. Cut button on the strip as well as the toolbar: KEEP

It's the same action in two places, which is normally what this audit removes, but it's the one case that earns it. In Side by Side the operator is watching pictures, and the strip Cut sits under the picture being taken. It costs 64 pt in a row that already exists, and the slot prevents a double-click doing harm because it turns into "On air".

### 10. Attention in the sidebar when the operator may have it closed: REVISE

Keep the section, but it can't be the main alarm, for three reasons:
- It's invisible with the sidebar closed.
- It's a list that scrolls, so a problem can arrive above the viewport.
- With the sidebar closed, the action sits behind the status popover, making it 2 clicks.

There's a worse fault under this. README says strip rows never appear or vanish, but 06 V11 keeps alert rows as the one row that does. Today's render shows the cost: the LUT alert pushes Camera 2's output row and meters about 31 pt lower than Camera 1's (`main-problems-1320-dark`), and `gridFit` sizes every picture to the tallest strip. In Program the output row is the Cut row, so on a short window this moves the Cut button and shrinks both pictures, at the moment the operator is aiming.

**Replacement:**

> A camera's problem **replaces its folder row in place**. The folder row grows to 24 pt in every state, matching 06's alert row, so the strip never changes height. It shows the worst problem and its one action, with "2 problems" opening the list if there are more. Session problems go in the first status bar segment, **with their action as a button in the bar**, so the fix is one click with the sidebar closed. The sidebar's Attention section is pinned above the scrolling list. It never opens the sidebar by itself, because that would resize the pictures during a show.

### 11. "You can close both side panes and lose nothing you need": REVISE

As written, it's false. Taking README literally, with the cut bar gone from Program View:

| Lost with the sidebar closed | Needed live? | Fix |
|---|---|---|
| Shot timer | Yes, with Auto | Status bar Program segment |
| When Auto can cut next | Yes | Status bar Program segment |
| One-click problem actions | Yes | Item 10 |
| Dropouts while no take is rolling | Yes, on this rig | Count on the signal badge when above zero |
| Recent cuts | No | Accept |
| Microphone reminder, hardware list, takes | No | Accept |

Note that 06 V22 keeps a shot timer bar in Program View and README removes the bar. README wins by its own rule, so the timer goes.

**Replacement for the status bar's Program segment:** "Camera 1 · shot 8 s · Auto", and after an override "Camera 1 · shot 3 s · Auto in 4 s". It adds no row and works in every layout. It also restores 02's F22 fix, which README dropped.

**Replacement for the test:** "You can close both side panes during a live session and still see and act on everything the show needs." With the fixes above, that's true.

### 12. Is the left pane too tall? REVISE

Yes. **A 13-inch display can't hold it in the realistic case, and neither can a 27-inch at the default window height.**

Measured rows: section header 32 pt, one-line row 29, two-line row 39, drive row with bar 48. Most README mock lines are wider than the pane: about 35 characters fit at 11 pt in 204 pt, and the lines run 39 to 42. So those rows take two lines.

| Section | Light case | Heavy case | After cuts, light | After cuts, heavy |
|---|---|---|---|---|
| Attention | 80 (1 problem) | 128 (2) | 80 | 128 |
| Cameras, 3 lines each | 136 | 136 | 136 | 136 |
| Virtual Cameras, 3 rows and note | 183 | 183 | 119 | 119 |
| Switching | 134 | 134 | 134 | 134 |
| Recording | 176 (1 drive) | 238 (2) | 147 | 209 |
| Takes | 71 (1) | 227 (5, today's limit) | 71 | 71 |
| **Total** | **780** | **1046** | **687** | **797** |

| Display | List height | Proposed heavy case | After cuts, heavy case |
|---|---|---|---|
| 13-inch, 1440 × 900 scaled | About 755 | Over by about 290 | Over by about 40; collapse Switching and it fits |
| 13-inch, 1470 × 956 scaled | About 800 | Over by about 245 | Fits |
| 27-inch, default 860 window | About 810 | Over by about 235 | Fits |
| 27-inch, window at full height | About 1290 | Fits | Fits |

List height is the usable screen, less the menu bar, a 70 pt Dock and a 52 pt toolbar. Today's pane reaches about 810 with one take and about 970 with five, so the proposal is no worse than today. But it ends on the two sections the owner asked for. With no changes, **Takes scrolls off first, then Recording, and Recording holds Format.**

**What is cut, in order. Items 1 to 3 always apply. Items 4 and 5 are the operator's choice:**

1. **Takes:** one row, the latest, always. `Show All` reveals the rest in Finder. Saves 156.
2. **Timecode:** caption, not picker (call 4). Saves 29.
3. **Virtual Cameras:** one line each, status only ("Ultracam · Program … In use"). The format is on the strip. The microphone note shows only until something is in use. Saves 64.
4. **Switching:** the first section the operator collapses, keeping its value in the header ("Auto · Natural talking head"). Saves 102.
5. **Virtual Cameras:** next to collapse, the same way. Saves 87.

Attention, Cameras and Recording never collapse. Nothing collapses by itself. Extend 02's collapse rule to these two sections. At 4 cameras the pane grows by about 160, so at 13 inches operators will need 4 and 5.

README's mock also drops `Change…`. Keep it on the destination row, as `Folder for Next Take…` during a take.

### 13. The scope: REVISE

**The main window is not a redesign.** It has the same three panes, strip, toolbar, status bar and layouts. The left pane is rebuilt, which the owner directly asked for ("the left bar seems to be redundant or not very useful"). Retiring the output mode is architecture, but it answers "think about the 3 panes" and the owner has called that lock arbitrary, so it stays.

**The Settings rebuild is the one part that is a redesign.** Replacing six tabs with a nine-section sidebar window isn't in the brief I was given, and section 12 doesn't flag it as reversible, though it flags three other calls. It's also the only piece that rewrites a window that wasn't the complaint. Its Monitoring section holds a single control.

**Replacement:**
- Phase 4 becomes "Settings moves": rows leave, Channels shown and Alerts are added, B14, and 06's footer and height fixes, all in the existing tabbed window.
- The nine-section rebuild becomes an optional phase of its own, listed in section 12 under decisions the owner may want to reverse.
- B9 and B10 move to phase 1.

Phase 5's plugin API is feature work rather than redesign, and it's already separable.

## Still wrong elsewhere

These aren't on the list of calls, but they fail the same test.

| Problem | Why it matters | Replacement |
|---|---|---|
| Hold appears only when Auto is on | The cut group sits with the toolbar's principal items, so a button appearing can shift Cut under the pointer, as can "Auto · Hold" changing width | Hold always present, disabled when Auto is off. Fixed width for both |
| Auto's on state is a tinted button | The same fault V1 fixes for Stop. In the render the Auto button draws gray in a non-key window, which is all of a meeting. Whether a machine is cutting must not depend on a tint | Fixed-width words: "Auto On" and "Auto Off" |
| Menu bar budget of 14 rows | Counted from README's order, adding the Start or Stop Cameras row it promises: 14 with one drive and no problem, 17 with a problem and two drives | Problem rows don't count against the budget. All drives share one row |

## What is missing

Only what serves the brief.

1. **Detecting that Zoom has stopped taking frames.** The on-air hang above. The counters already exist. When the extension queue stays full for 2 s, add an Attention row and notification: "Camera 1: the meeting app has stopped taking video", with `Restart Camera`. Without this, the worst hang is invisible in every layout. The proposal's strongest idea is that a problem reaches the operator wherever they're looking, and this one doesn't.
2. **Background cut keys.** README section 6 lists a settings row and no phase builds them. In a full-screen meeting they're the difference between 3 gestures and 1. Put cuts, Auto and Hold in phase 3.
3. **A take still rolling after the meeting ended.** Report 02's F21 dropped out of README. In workflow 2 it quietly fills the drive. If a take started while a virtual camera was in use and nothing has used it for 2 minutes, add an Attention row: "Still recording: no meeting app is using Ultracam". Don't stop the take: that's D6's rule.

## Live checks to add to README section 12

1. **Click-through.** The app has no `acceptsFirstMouse` or `allowsWindowActivationEvents`. Confirm that with Zoom frontmost, the first click on Cut, the LUT toggle or Record acts, instead of only activating Ultracam. If it only activates, every "1 click" in this file while Zoom is key costs 2, and the toolbar and strip need fixing first.
2. **LUT flip.** Toggle the LUT with Zoom on Ultracam · Camera 1 and on Ultracam · Program. Confirm there's no visible blip. If `reconfigure` produces one, it's still the correct panic control, but the help text should stop implying it's seamless.
3. **Screen sharing.** README's notification test should include a shared screen, where macOS may silence notifications and a banner could show to the meeting.
