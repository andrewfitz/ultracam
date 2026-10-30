# Ultracam live workflows and pane decisions

Audit date: 2026-10-30. Build state: commit `30c8d73`, renders in `.build/agent-work/build/ultracam/ui-verify/latest/png/`.

## How to read this

- **Evidence.** This comes from reading the source and the offscreen renders. Nothing was run. Render text is fixture data. Statements about runtime behaviour are traced from code, and the ones that most need a live test are marked "traced, not run".
- **Severity is for live use.** **Blocks:** the operator can't do the job in the moment, or loses material without knowing. **Costs time:** the job gets done, with hunting, waiting or a stop. **Annoyance:** noise or inconsistency.
- **Assumption from the brief.** Every proposal assumes both kinds of virtual camera can exist at once. Section 6 says what changes if they can't.
- **Other reports.** Settings structure, vendor hardware, audio channel counts and visual polish belong to other audits. They appear here only where a workflow depends on them.

## 1. The result

### The placement rule

Each control goes where its scope and its live frequency put it. Most of the clutter comes from breaking this rule, for example a per-camera setup control on the live strip, or a session control in three places.

| Scope | Used while live? | Home | Job in one line |
|---|---|---|---|
| Whole session | Yes, an action | **Toolbar** | Cut, Auto, Hold, Record, Stop |
| Whole session | Glance, or pre-show setup | **Left pane** | What is connected, what is going out, where it is being saved, what is wrong |
| Whole session | Glance, sidebar closed | **Status bar** | One line of health |
| One camera | Yes | **Picture and strip** | See it, hear it, roll it |
| One camera | No, setup | **Inspector** | Input, LUT, effects, per-camera behaviour |
| App-wide | Set once | **Settings** | Defaults and policy |
| Whole session | Yes, app hidden | **Menu bar** | Run the session without the window |
| Engineering detail | No | **Diagnostics** | Counters and messages |

### The left pane in one sentence

**The left pane becomes the session board.** It reads as the signal chain: Attention, Cameras (hardware), Virtual Cameras (what meeting apps can see), Switching, Recording, Takes. Today it mostly repeats what is on screen, and it can't answer the questions the operator has before going live.

### Worst findings

1. **F01, blocks.** A camera that stops by itself ends its take and then looks exactly like a camera the operator stopped. No warning, no reason, and in Separate mode no attention badge on the menu bar icon.
2. **F02, blocks.** No alert can reach an operator who isn't looking at the window. The app has no notifications, sounds or dock bounce. In a full-screen meeting macOS hides the menu bar, and the menu bar icon is the only remote signal.
3. **F03, blocks.** When the on-air camera loses HDMI, Program stays on it and neither Auto strategy reacts, because no-signal never marks a source unhealthy. Zoom gets a held frame, then nothing new, until the operator cuts by hand (traced, not run).

## 2. Workflow walkthroughs

Each table logs the steps as they work today. "Actions" counts clicks, keys and required menu navigation.

### Workflow 1: morning setup

| Step | Actions | Where attention goes | Finding |
|---|---|---|---|
| Launch | 1 | The app opens with cameras stopped. Cameras otherwise start only when a meeting app opens them. | None |
| Pick output mode | 1, or 3 and a wait | This must happen before Start. If the last session used the other mode and cameras are already up: Stop Cameras and Switch, wait, Start Cameras again. | **F04** |
| Start cameras | 1 | Toolbar. Then each picture and each strip badge. | None |
| Confirm which device feeds which camera | 2 to 3 per camera | Hidden. It's a tooltip on the strip name (`UICameraColumn.swift:726`) or the inspector, reached by select plus ⌥⌘I. The Input value truncates ("UltraStud...order 12G" in `component-inspector-dark`). | **F05** |
| Confirm camera control link | 1 to 2 per camera | Only the signal badge's menu says "Control camera disconnected" (`UIFeedSettingsMenu.swift:33`). The strip row is a plain "Camera Control" button with no state (`UICameraControl.swift:10`). | **F05** |
| Confirm record format | 5 | ⌘, then Recording tab, scroll a 700 pt pane, read, close. The sidebar line is read-only (`UISessionSidebar.swift:155`). | **F06** |
| Confirm audio | 0 | Strip meters. "Audio OK" only means audio is present (`UIPresentation.swift:772`), so it stays "OK" on clipped audio. | **F27** |
| Confirm disk | 0 | Sidebar drive rows. The idle "time left" is too long when two cameras share a drive. | **F07** |
| Join Zoom | 3+ | In Zoom, pick the Ultracam camera, and pick the microphone yourself. The note "Video only — select your microphone" is buried in a status popover (`UIStatusBar.swift:257`). | **F08** |
| Confirm Zoom sees it | 0 | Sidebar row, strip glyph, status bar segment and ON AIR ring. Four echoes of one fact. | F20 |

No screen answers "is everything ready?". The operator assembles that from the picture, strip, sidebar, status bar, inspector and Settings.

### Workflow 2: Zoom with one camera, backup recording started mid-call

Assumes Zoom in a window and Ultracam behind it.

| Step | Actions | Where attention goes | Finding |
|---|---|---|---|
| Start the take | 2 | Menu bar icon, then Record. ⌘R needs Ultracam frontmost. | None. This is the app's best path. |
| No folder set | Dead end | The Record row is disabled with no reason and the menu has no Choose Folder row (`UIMenuBar.swift:383-384`). The operator opens the main window mid-call. | **F09** |
| Confirm it rolled | 1 to 2 | Menu bar dot appears within about 1 s (`UIMenuBar.swift:110-121`). To see the clock, reopen the menu. | None |
| Near Record in the menu | Hazard | Top-level Processing sits in the same menu, on the selected camera. One wrong click is a complete bypass, and it renegotiates the camera Zoom is receiving (`UIMenuBar.swift:431-434`). | **F10** |
| Meeting ends | 1 to 3 | The take keeps rolling. Nothing says the meeting ended. The sidebar's "Backup recording / Coming later" (`UISessionSidebar.swift:258-264`) is a placeholder with no use during a session. | **F21** |

### Workflow 3: two-camera ISO shoot, no meeting app

| Step | Actions | Where attention goes | Finding |
|---|---|---|---|
| Set format | 5 | Settings, as in workflow 1. | **F06** |
| Set folders | 2+ | Default folder is in the sidebar. A camera's own folder is in ⋯, the inspector or Settings: three routes, and the sidebar doesn't show the override. | **F11** |
| Check room | 0 | Time left is computed for one camera at nominal 4K59.94, and only cameras already recording add their rate (`UISupport.swift:63-65`, `UILiveTelemetry.swift:44-48`). The figure halves when two cameras roll to one drive. | **F07** |
| Roll | 1 | Record All (⌥⌘R). It's enabled if any one camera is ready (`UIPresentation.swift:717`), and `recordAll` then loops over every camera (`RecordingModel.swift:998`). The label doesn't warn that only some are ready. | **F12** |
| Add a late camera | 1 to 3 | Once one camera rolls the toolbar shows "Stop All (1)", so there's no Record All (`UIPresentation.swift:720`). Use the strip button, or menu bar › Camera 2 › Record. | **F13** |
| Monitor | 0 | A row of seven tool buttons sits on the top of every picture at rest, over the headroom the operator is checking (`UICameraColumn.swift:210-213`). | **F14** |
| Drive fills | Several | An orange status segment and a menu bar triangle at under 30 minutes, a hard-coded threshold with no second stage (`UIPresentation.swift:830`). When it's full the take fails, and recovery is Choose Folder then Record per camera. | **F02**, **F15** |
| Signal drops | See workflow 5 | | F01, F16 |
| Stop | 1 | "Stop All (2)" sits next to "Stop Cameras": same size, same square icon. One ends takes, the other ends takes and capture and output. | **F17** |
| Check the takes were clean | Not possible | The dropped count is only shown while recording (`UIPresentation.swift:679`). The Saved state shows name and duration, so a take with 60 missing frames in 32 gaps, as on 2026-10-28, reads "Saved" (`strip-saved-dark`). The figures exist in `SourceRecording.swift:439-442`. | **F16** |
| Find the takes | 1 to 3 | Saved · Show in Finder is on the strip until the camera stops, then the strip says "Not recording" (`UIPresentation.swift:555`). Recent Takes truncates the duration ("Oct 19, 2026 at 3:53 AM ·…" in `component-sidebar-dark`). "Show Recordings in Finder" opens one folder only, so a camera with its own folder is missed (`UISessionBridge.swift:401-404`). | **F18** |

### Workflow 4: two-camera Program with cuts, Auto, override, Hold and recording

| Step | Actions | Where attention goes | Finding |
|---|---|---|---|
| Enter Program | 1 to 3 | As workflow 1. With a take rolling: stop takes, stop cameras, switch, start, roll new takes, reselect in Zoom. | **F04** |
| Manual cut | 1 | Toolbar number button, ⌃1 to ⌃4, or strip Cut. This works well. | None |
| Choose strategy | 2 | Sidebar picker, Program View picker, Program menu or menu bar. If the sidebar is closed in Side by Side, only menus remain. | **F19** |
| Turn on Auto | 1 | Toolbar toggle, sidebar switch, Program View switch, menu row. With Manual selected the toolbar control becomes a menu. | **F19** |
| Override | 1 | A cut during Auto works, but nothing says when the director may cut again. Natural talking head uses a cooldown (`NaturalTalkingHeadAutoSwitcher.swift:169-175`). Fixed interval keeps its timer running, so an automatic cut can land soon after a manual one (`SwitcherCoordinator.swift:311-322`, traced, not run). | **F22** |
| Hold | 1 to 3 | Hold is the operator's main override, yet it isn't in the toolbar (`UIToolbar.swift:102-132`) and has no shortcut (`UICommands.swift:189-190`). It exists only for Natural talking head (`UIPresentation.swift:727`). | **F22** |
| Program View | 1 | Program picture and tiles are excellent. Below them: a cut bar repeating the toolbar, collapsed strips, and Recent Cuts below the fold at 1320 wide (`layout-programView-dark`). With the sidebar open, one screen has Auto three times, and Strategy, Hold and the shot timer twice. | **F19** |
| Record at the same time | 1 | Takes are per-camera originals, and Program itself isn't recorded. On a Program screen "REC 2" invites the wrong assumption. The explanation is a per-strip footnote that disappears when collapsed or narrow (`UICameraColumn.swift:1012-1014`). | **F23** |
| Program in a narrow window | | At 980 wide the toolbar pushes layout and inspector into overflow (`main-program-meeting-980-dark`). Strip rows differ between cameras: the Cut row keeps "Processing", the on-air row loses it (`main-program-meeting-1320-dark`). | F31 |

### Workflow 5: something goes wrong live

What the operator gets today, event by event.

| Event | Picture and strip | Status bar | Menu bar icon | Outside the app | What to do | Finding |
|---|---|---|---|---|---|---|
| 2-frame HDMI dropout, the real case on 2026-10-30 | At most a flash. During a take the count turns orange. | Nothing | Nothing | Nothing | Nothing asked. With no take running, the event leaves no trace in the UI. | **F16** |
| Signal lost for seconds, recording | "No signal" placeholder, orange strip, "REC · no signal" pill (`strip-recordingNoSignal-dark`). Good. | Warning, last in the bar | Triangle, which replaces the recording dot | Nothing | Check the cable. The placeholder gives generic setup advice and no duration. | **F02**, **F24** |
| On-air camera lost, Manual | Same | "Camera 1 on air: no signal" | Triangle | Nothing | Cut to the other camera. The warning offers no cut. Popover is text only (`UIStatusBar.swift:234-236`). | **F03**, **F24** |
| On-air camera lost, Auto | Same | Same | Triangle | Nothing | Same. No-signal doesn't mark a source unhealthy: `retireProgramSource` runs only when capture stops or fails (`AppModel.swift:1160`, `1204`, `1283`). Fixed interval may also choose a no-signal camera as its next cut, because health stays true (traced, not run). | **F03** |
| Camera stops itself (capture error, device error, GPU stall) | "Camera stopped", "Stopped", "Not recording" | Nothing in Separate. In Program, only if it's the on-air camera. | Recording dot goes, no triangle | Nothing | Nothing tells the operator it happened. | **F01** |
| Drive disconnected or full | "Recording failed" or "Disk full", with actions (`strip-failed-dark`). Good. | Warning | Triangle | Nothing | Choose Folder or Details. | **F02**, **F15** |
| Both cameras drop together, as at 13:59:04 on 2026-10-30 | Both strips | **One** warning: `warning()` returns the first match (`UIPresentation.swift:818-847`) | Triangle | Nothing | The second camera's problem isn't named until the first is fixed. | **F25** |

**How F01 happens.** `CaptureController.fail()` publishes a stopped update (`CaptureController.swift:1184-1196`). AppModel stops that camera's recording (`AppModel.swift:1156-1160`). The bridge then reads no update, because the camera isn't running (`UISessionBridge.swift:113`), so the reason is dropped. `stripState` goes straight to `.stopped` (`UIPresentation.swift:555`), which also hides the Saved state. Diagnostics shows capture messages only while a camera runs (`UIDiagnostics.swift:190-195`). The reason ends up in the system log alone. In release builds plain no-signal waits for the source and doesn't fail (`CaptureController.swift:725-737`, `2801-2807`), so F01 covers real errors and not ordinary HDMI loss.

Related: `AppModel.showStatus` writes director and virtual camera errors onto the selected camera's message (`AppModel.swift:1000-1004`), which the UI shows only in a start-failure placeholder and Diagnostics. An error such as "Natural Talking Head could not start its Rust director" is therefore effectively silent. This is part of F01.

### Workflow 6: app hidden during a full-screen meeting

By default macOS hides the menu bar in a full-screen app until the pointer reaches the top edge, so every row below costs one extra gesture. None of the shortcuts work: every key equivalent is app-local, and `addGlobalMonitorForEvents` and `RegisterEventHotKey` appear nowhere in the source.

| Task | From the menu bar today | Gap |
|---|---|---|
| See that something is wrong | Only if the bar is revealed. The icon can't reach the operator. | **F02** |
| Read the problem | Open menu: one orange line | **F25** |
| Cut | Reveal, icon, row: 3 gestures. Key shortcuts don't reach a hidden app. | **F26** |
| Auto on or off, Hold, Strategy | Available | Rows sit low in the menu, below Stop Cameras, Record and Output. |
| Record, Stop All | Available | None |
| Record one of two cameras, or pause | Camera submenu, 3 gestures | **F13** |
| See a preview | Live card while the menu is open | Good. It closes with the menu. |
| Drive time left | Footnote with CPU, and the **first drive only** (`UIMenuBar.swift:286-290`) | **F28** |
| Choose folder or format | No row | **F09**, **F06** |
| Know which camera a top-level row affects | Depends on the window's selection, which the operator can't see | **F10** |

The menu has about 18 rows, 6 separators and the card for two cameras in Program, against the ≤14 budget set in `docs/mockups/r3/audit/REPORT.md`.

## 3. Pane decisions

### 3.1 Left pane: row-by-row test

| Row | Shown elsewhere? | Needed live? | Decision |
|---|---|---|---|
| Extension banner | Settings › Camera | Only when wrong | **Move** into Attention |
| Cameras · n header | No rows at 1 to 2 cameras, so a heading over nothing (`UISessionSidebar.swift:56-58`) | Yes, once it has content | **Rebuild** as the hardware list, always shown |
| Add Camera (+) | Camera menu | No | **Keep** in the Cameras header |
| Output segmented control | Program menu, menu bar, Settings | Locked in the moments it's wanted | **Remove** (F04) |
| Lock text and Stop Cameras and Switch | Same | No | **Remove** |
| Sync cameras | Inspector and Settings (`UISessionSidebar.swift:100`, `UIInspector.swift:158`, `UISettings.swift:307`) | No | **Remove**. Keep the inspector's only. |
| Ultracam · Program, in use | Status bar, strip glyph | Yes: "is Zoom seeing me?" | **Keep** in Virtual Cameras |
| Ultracam · Camera n, in use | Same | Yes | **Keep** |
| Auto switching | Toolbar, Program View, menus | Yes, but in one place | **Remove**; toolbar owns it |
| Strategy | Program View, menus | Pre-show | **Keep** in Switching |
| Hold current shot | Program View, menus | Yes, as an action | **Remove**; toolbar owns it |
| Shot timer | Program View | Glance | **Keep** in Switching |
| "2 recording" line | Toolbar, status bar, strips, pictures | No | **Remove** |
| Codec and timecode, read-only | Settings | Pre-show | **Replace** with a Format picker |
| Drive rows | Status bar, strip | Yes | **Merge** with folders |
| Folder row | Strip | Pre-show | **Merge** with drives |
| Recent Takes | Saved state, while it lasts | After a take | **Keep**, with better rows |
| Interrupted Takes | Settings › Recording | Once, after a crash | **Move** to one Attention row |
| Start with camera apps | Inspector, menu bar | No. It's a per-camera setting. | **Remove**. The state appears on the Cameras row, a failure in Attention. |
| Backup recording, Coming later | Settings | No, and it does nothing | **Remove** |

### 3.2 Left pane: contents by section

```text
ATTENTION                       only when something needs it
  ▲ Camera 1 stopped on its own   [Start] [Why]
  ▲ 8TB 24 min left               [Change…]
CAMERAS                                               +
  ● Camera 1                                     On air
    UltraStudio 12G · 2160p 59.94
    Sony · connected
  ● Camera 2
    UltraStudio 12G · 2160p 29.97 · 4 dropouts
VIRTUAL CAMERAS
  ✓ Ultracam · Program            In use · 1080p 29.97
    Ultracam · Camera 1           Not in use
    Ultracam · Camera 2           Not in use
    Video only. Pick your microphone in the meeting app.
SWITCHING                                 collapsible
  Strategy   [Natural talking head]
  Anchor     [Automatic]   Emphasis [Automatic]
  Camera 1 · shot 8 s  ▬▬▬▬▬|▬▬▬|▬▬
  5:22:23 Camera 1  Auto
  5:21:58 Camera 2  Manual
RECORDING
  Format     [ProRes 422 HQ]
  Takes · On 8TB · Camera 1            1 h 52 m left
  ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬
  B-cam · On Archive · Camera 2        5 h 40 m left
  ▬▬▬▬▬
  Camera original, no LUT or effects · Mac Clock
TAKES
  5:40 PM · 12:31 · 2 cameras · 0 lost           [Show]
```

Rules for each section:

- **Attention.** Lists every current problem, worst first, each with one action. It takes the output of the same logic as `warning()`, changed to return a list. It holds active problems and events the operator hasn't acknowledged, such as a camera that stopped itself. It's absent when all is well, so an empty sidebar means healthy.
- **Cameras.** One row per camera at every camera count, removing the current over-2 gate. Line 1: status, name, tally text. Line 2: input device, format and any dropout count since the camera started (`signalDropouts` already exists in `CaptureController.swift:31`). Line 3 only with a control camera: vendor and link state. "Starts with camera apps" also appears here when set. A click selects and opens the inspector, as now. The context menu has Start or Stop, Rename and Show Inspector. Exact hardware wording belongs to the vendor audit.
- **Virtual Cameras.** Status only, no switches. One line with the microphone reminder, because that's when the operator needs it.
- **Switching.** Appears with 2 or more cameras. The operator can collapse it, and the state persists. It never appears or disappears on its own, so rows don't jump under the pointer when Zoom connects. Anchor and Emphasis appear only for Natural talking head. Recent cuts move here from Program View and stop at 3.
- **Recording.** The Format picker lists what every running camera can record, and marks the rest unavailable. Today availability follows the selected camera only (`UISettings.swift:133-134`). A change applies to the next take, as folder changes do. Timecode stays in Settings and shows as a caption. Each distinct destination is one row combining folder, drive, cameras, time left, bar and a Change action. Time left covers all cameras assigned to that drive at their real format (F07).
- **Takes.** Time, duration, camera count and frames lost. Date only when not today. Groups a roll's files into one row. Show in Finder reveals all its files, across folders.

The sidebar stays open by default and can be hidden during a live session without losing anything essential, because the toolbar and status bar carry the live items. That's the test of the split.

### 3.3 Centre: pictures

Job: show what is real. Every overlay must justify covering a picture.

| Element | Decision | Reason |
|---|---|---|
| Name pill | Keep | Identity on the thing being watched |
| Number pill | Keep, shown with the switcher | Maps to ⌃1 to ⌃4 |
| ON AIR ring and badge | Keep | Primary tally |
| Selection ring | Keep (D7) | Distinct colour from tally |
| REC pill | Keep | Primary per-camera take state |
| Monitor tool bar at rest | **Change**: at rest show only active tools. Full bar on hover or focus. | F14. The code keeps them "so they can be found" (`UICameraColumn.swift:210`), which reverses P1-11. ⌥⌘K, View › Monitor Tools and hover still find them. |
| Hover row: timecode, stage, freeze, clean, zoom, detach | Keep | Hidden at rest, reasonable |
| "No signal" placeholder when the camera had a picture | **Change**: "Signal lost 0:14", no setup advice, and on an on-air camera a **Cut to Camera 2** button. | F24 |
| "Camera stopped" after a failure | **Change**: "Camera 1 stopped: [reason]. Take saved up to 12:31", with Start. | F01 |

**Program View.** Keep the Program picture and source tiles. Remove the cut bar (`UIProgramView.swift:26`): cuts, Auto and Hold live in the toolbar, and the rest moves to Switching. Remove the Recent Cuts list (`UIProgramView.swift:30`). The collapsed strips then rise into view with no scrolling. Make each tile's Cut a full-width button under the tile (`UIProgramView.swift:91-98`), so the operator isn't aiming for a small target in the far corner. Program View becomes available whenever 2 or more cameras exist.

### 3.4 Centre: camera strip, element by element

Expanded strip:

| Element | Decision | Reason |
|---|---|---|
| Chevron | Keep | Per-camera density |
| Brand mark | Keep | Vendor awareness |
| Name | Keep | Row anchor |
| Signal badge with menu | Keep | Source format and the vendor control menu. Rename its "Feed settings" label (F30). |
| On-air badge | **Remove** | The ring and ON AIR badge are directly above it; the sidebar row carries the text form |
| Stop Camera / Start / Retry button | **Change**: show only when action is needed (Start, Retry). Stop moves to ⋯. | The largest labelled control on the strip is a destructive one almost never used live |
| ⋯ menu | **Trim** | Remove Record, Pause and Cut, already one click on the strip. Keep Show Inspector, LUTs, folder, Copy Monitor Settings, Rename, Diagnostics, Stop or Start, Remove. |
| Record button | Keep | Primary control of the strip |
| Status and clock | Keep | Needed when sidebar is closed |
| Size · bitrate | **Remove** from strip | Rarely acted on live; stays in the status popover and Diagnostics |
| Dropped count | **Keep**, and keep it after the take | F16 |
| Note line | Keep | Take-specific warnings |
| Pause / Resume | Keep | It's per take and low risk. |
| Saved · Show in Finder | **Keep and persist** after the camera stops | F18 |
| Folder path | **Shorten** to volume and time left, full path in the tooltip | Destination detail now lives in Recording. Time left stays because it matters during a take. |
| "Own folder" badge | **Remove** | The Recording section names which camera goes where |
| "Camera original · no LUT or effects" | **Remove** from strip | Once in Recording; it stays in the button help (`UICameraColumn.swift:856-859`) |
| Alert rows (Retry, LUT unavailable) | Keep | One problem, one action |
| Output label | **Replace** with one read-only line: green glyph, "Output 1080p · 4:2:0 8-bit · 29.97 · In use" | Names what the camera sends. Clicking opens the inspector. |
| LUT chip | **Keep** as a toggle | It doesn't change the output format, so it's safe live |
| Resize, Color, Frame-rate chips | **Move** to the inspector; summarized in the output line | Each one renegotiates the camera Zoom is receiving, one click from the meters and from Cut. D2 still holds: no prompt. They're just no longer on the live surface. |
| Processing switch | **Move** to the inspector, ⇧⌘B, Camera menu | Same hazard, and it's the largest change of all |
| Camera display toggle | Keep | It decides whether the camera's on-screen display is in the HDMI signal, so it can spoil a shot |
| Camera Control row | **Remove** | No state, and setup is available from the signal badge and inspector. Link state goes on the Cameras row. |
| Cut button | Keep (Program) | Lead the row at a fixed position |
| Audio meter | Keep | Audio detail belongs to the audio audit |

Collapsed strip:

| Element | Decision | Reason |
|---|---|---|
| Chevron, name | Keep | |
| On-air badge | **Remove** | Same as expanded |
| State (clock, No signal, Saved, Ready) | Keep | The purpose of a collapsed strip |
| Retry, LUT warning | Keep | |
| Effect chips | **Remove** | Forced collapsed strips in Program View show them (`layout-programView-dark`). Collapsed should be calm. |
| Compact meter | Keep | The name, state, meter and record button are the live minimum |
| Record button, ⋯ | Keep | |

### 3.5 Right inspector

Job: per-camera setup. Closed during live work. D5 stands.

- **Merge** each effect's checkbox with its value. "Resize" checkbox and "Output size" picker are one setting shown in two rows, and likewise Color format and Frame-rate cap (`UIInspector.swift:163-196`).
- **Order** to match the signal path: Source, Camera Control, LUT, Effects, Recording, Automation.
- **Add** Processing and format-change notes here, since this becomes the home for those controls.
- **Show** why Input is disabled while running, in text under the picker. Today that's hover-only (`UIInspector.swift:113`).
- **Move** "Supported source formats" out of the inspector and into the Input device's entry on the Settings hardware page, with a tooltip on the Cameras row. It takes 5 lines of the first screen with a fallback sentence (`component-inspector-dark`), and it describes the device, not the camera.
- **Keep** Rename and Remove Camera at the bottom. Both are setup actions.

### 3.6 Toolbar

Job: session transport. Left to right when 2 or more cameras exist:

`[1 Camera 1] [2 Camera 2] | [Auto ▾] [Hold]` ... `[Start Cameras, only when needed]` `[Record All ▾ / ● Stop All Recordings (2) 12:31 ▾]` | `[layouts]` | `[inspector]`

| Change | Detail | Finding |
|---|---|---|
| Cut group whenever 2+ cameras exist | Red only when Program has a viewer. Existing tally states already handle this. | F04 |
| Auto is a split button | Click toggles. The arrow offers Strategy, Anchor and Emphasis. | F19 |
| Add Hold | Beside Auto, shown when Auto is on, for every strategy. Shortcut ⌃⌥H. | F22 |
| Remove "Stop Cameras" while running | Show "Start Cameras" only when a camera is stopped. Stopping stays in the Camera menu, ⌘↩ and the menu bar. | F17 |
| Rename to "Stop All Recordings (2)" | Restores P0-3's naming. "Stop All (2)" has no object. | F17 |
| Add a red dot to the stop control | The comment at `UIToolbar.swift:156-157` explains that prominent buttons go grey when the window isn't key. Cut buttons have a dot, the record stop doesn't. It's grey in `main-standalone-1320-dark`. | F29 |
| Record control gets a menu | With some cameras rolling: Stop All Recordings, Record Camera 2, Pause All. | F13 |
| Record All names partial readiness | "Record 1 of 2", with the reason in help | F12 |
| Remove Collapse All | Used rarely, disabled in two layouts (`UIToolbar.swift:61-68`). Stays in View and ⌥⌘S. | F31 |

### 3.7 Status bar

Job: one-line session health, for when the sidebar is closed.

- **Reorder:** Problems first, then Virtual Cameras, Program, Recording, Audio, then resources. Today the warning comes last, after a recording string that can run to 60 characters (`component-status-bar-dark`).
- **Problems segment:** "2 problems · Camera 1 no signal". Its popover lists all of them with actions, the same as Attention.
- **Recording:** shorten to "REC 2 · 12:31 · 1 h 52 m left", showing the lowest figure. The popover keeps per-camera and per-drive detail.
- **Audio:** say what it knows: "Audio 2 of 2" instead of "Audio OK" (F27).
- **Resources:** keep the short form only, "CPU · GPU". Remove Memory and "(video)" (`UIStatusBar.swift:216-217`). Full figures stay in the popover and Diagnostics.
- **Add** a session-wide dropped-frame figure to the Recording segment when above zero, which is what the operator is really asking the resource readout.

### 3.8 Menu bar

Job: run the session with the window hidden. Target: 14 rows or fewer for two cameras.

Order:

1. Preview card
2. Every problem, each with an action row (`Cut to Camera 2`, `Choose Folder…`, `Retry`)
3. Cut rows, Auto, Hold, Strategy
4. Record All or Stop All Recordings, plus Record or Stop for each camera at top level
5. Recording: format submenu, folder row, a time-left line for each drive
6. Cameras: one submenu each, as now, for deeper actions
7. Start or Stop Cameras
8. Open Ultracam, Settings, Quit

Remove: top-level Processing, Video Preview and Start with Camera Apps (`UIMenuBar.swift:373-377`, `431-438`). They act on a selection the operator can't see, and each camera submenu has them anyway. Remove CPU, GPU and Memory from the footnote. Remove the Output submenu (F04). No row should depend on the window's selection.

### 3.9 Where things go

Settings has its own report. These are the placements the workflows demand.

| Item | Home | Also |
|---|---|---|
| Recording format | Left pane, Recording | Record menu, menu bar |
| Timecode, file naming | Settings | Caption in Recording |
| Default folder | Left pane, Recording | Settings |
| Per-camera folder | Left pane, Recording (each destination row names its cameras) | Inspector, ⋯ |
| Output mode | Removed | |
| Sync cameras | Inspector | |
| Strategy | Left pane, Switching | Auto menu, Program menu, menu bar |
| Shot limits, interval | Settings | |
| Auto, Hold, cuts | Toolbar | Program menu, menu bar |
| Start with camera apps | Inspector | Summary on Cameras row |
| Effect on and off, except LUT | Inspector | Camera submenu in the menu bar |
| Audio channels shown | Settings | |
| Alerts and low-drive thresholds | Settings | |
| Background shortcuts | Settings | |
| Extension install | Settings | Attention when action is needed |

## 4. Findings index

### Blocks

| ID | Finding | Fix |
|---|---|---|
| F01 | A camera that stops on its own ends its take and shows as an ordinary stop, with the reason lost. `AppModel.swift:1150-1160`, `UIPresentation.swift:555`, `:818-847`, `UIDiagnostics.swift:190-195`. Status errors go to a field that's rarely shown: `AppModel.swift:1000`. | Keep an unexpected-stop state per camera with reason and take result. Show in picture, strip, Attention, status bar, menu bar, Diagnostics. |
| F02 | Nothing reaches an operator outside the window. No user notification, sound or attention request exists (searched `Sources/App`). The menu bar is hidden in full-screen meetings. | System notifications, time-sensitive level, for: camera stopped unexpectedly, take ended early, recording with no signal, on-air camera lost, drive low or full. Sound off by default, because the room may have open microphones. Choice per event in Settings. Note that Focus or Zoom's sharing settings may still hold notifications back, so test in a real meeting. |
| F03 | Program stays on a camera with no signal, and Auto doesn't react. Source health only goes false on the stop paths (`AppModel.swift:1283-1289`, `FeedRuntime.swift:404-407`), and both directors read that health (`SwitcherCoordinator.swift:510-518`, `NaturalTalkingHeadAutoSwitcher.swift:242-243`). Traced, not run. | Feed no-signal into source health. Auto cuts away on loss. Manual: a Cut button at the point of the warning. Architecture owner to confirm. |
| F04 | The Output mode can't be changed while recording or in use, needing a stop of takes and cameras. `UISessionSidebar.swift:511-521`, `UISettings.swift:348`. The strongest item in the owner's brief. | Publish both. Remove the mode. See section 6 if that isn't possible. |

### Costs time

| ID | Finding | Fix |
|---|---|---|
| F26 | No keyboard cut while a meeting is frontmost, so a cut takes 3 gestures. Key equivalents are app-local; no global hotkey exists. | Opt-in background shortcuts in Settings, for cuts, Auto, Hold and record. Choose a combination other than ⌃1 to ⌃4, because other apps may use those. |
| F05 | No view of which device and control link serve each camera. `UICameraColumn.swift:726`, `UICameraControl.swift:10`. | Cameras section |
| F06 | Record format needs Settings. `UISessionSidebar.swift:155`, `UISettings.swift:190-195`. | Picker in Recording, Record menu, menu bar |
| F07 | Idle time left is for one camera at a nominal rate. `UISupport.swift:63-65`, `UILiveTelemetry.swift:44-48`. | Estimate for all assigned cameras at their format |
| F08 | Microphone reminder is buried. `UIStatusBar.swift:257`. | Virtual Cameras line |
| F09 | Menu bar Record is a dead end with no folder. `UIMenuBar.swift:383-384`. | Reason plus Choose Folder row |
| F10 | Top-level menu bar rows act on an invisible selection, including Processing. `UIMenuBar.swift:431-438`. | Remove them. Keep camera submenus. |
| F11 | Per-camera folders have three routes and the session view doesn't show them. `UISessionSidebar.swift:160-178`. | Destination rows |
| F12 | Record All doesn't reveal partial readiness. `UIPresentation.swift:717`, `RecordingModel.swift:998`. | "Record 1 of 2" |
| F13 | After one camera rolls, the toolbar can't start the other. `UIPresentation.swift:720`. | Record menu; top-level rows in menu bar |
| F14 | Tool bar covers each picture at rest. `UICameraColumn.swift:210-213`, `main-standalone-1320-dark`. | Active tools only at rest |
| F15 | Low-drive warning has one fixed level, no second stage. `UIPresentation.swift:830`. | Warnings at 30 and 5 minutes; set in Settings; offer a folder change for the next take early |
| F16 | Dropouts leave no lasting trace. The count ends with the take, and session dropouts never appear. `UIPresentation.swift:679`, `SourceRecording.swift:439-442`, `CaptureController.swift:31`. | Frames lost and gaps in Saved and Takes; session count on the Cameras row |
| F17 | "Stop All (2)" sits next to "Stop Cameras". `UIToolbar.swift:24-31`, `:208-218`. | Full name; remove Stop Cameras while running |
| F18 | Saved state disappears when the camera stops, and folder reveal misses own-folder cameras. `UIPresentation.swift:555`, `UISessionBridge.swift:401-404`. | Persist Saved until the next take; reveal all folders |
| F19 | Auto in 4 controls, 3 on screen at once, in different control types. Strategy and Anchor scattered. `UIToolbar.swift:111-130`, `UISessionSidebar.swift:110-132`, `UIProgramView.swift:120-138`. Regresses P1-11. | Toolbar acts; Switching configures; cut bar removed |
| F22 | Hold has no toolbar place, no shortcut, one strategy only. A cut under Auto gives no signal of what happens next. `UIToolbar.swift:102-132`, `UICommands.swift:189`, `UIPresentation.swift:727`. | Toolbar Hold, ⌃⌥H, all strategies, a brief "Auto resumes in N s" beside Auto |
| F23 | Nothing on a Program screen says Program isn't recorded. `UICameraColumn.swift:1012-1014`. | "Camera original" line in Recording; status popover says "Program isn't recorded". No new feature. |
| F24 | Loss placeholder gives setup advice, no duration, no action. `UICameraColumn.swift:128-130`, `UIStatusBar.swift:234-236`. | Duration, and a Cut action for on-air cameras |
| F25 | One warning at a time, and both cameras dropped together on 2026-10-30. `UIPresentation.swift:818-847`. | `warnings` as a list everywhere |
| F28 | Menu bar shows the first drive only, so the filling one may be hidden. `UIMenuBar.swift:286-290`. | One line per drive |

### Annoyance

| ID | Finding | Fix |
|---|---|---|
| F20 | "In use" and on-air state repeat in the strip badge, picture, sidebar and status bar. `UICameraColumn.swift:759-767`. | Remove strip badge |
| F21 | "Coming later" rows in the live sidebar. `UISessionSidebar.swift:258-264`. | Remove from sidebar. Settings audit decides on its copy. |
| F27 | "Audio OK" means present, not good. `UIPresentation.swift:772`. | "Audio 2 of 2" |
| F29 | Stop control has no tally dot and goes grey behind other windows. `UIToolbar.swift:198-218`. | Red dot |
| F30 | "Feed" leaks: "Feed settings" (`UIFeedSettingsMenu.swift`), "Missing feed" (`MonitorWorkspaceView.swift:373`). Three names for one mode: "Separate (ISO)", "Separate cameras", "Separate Cameras (ISO)". The menu bar placeholder says "HDMI input" on what may be SDI (`UIMenuBar.swift:688`). | Camera; a single term; "video input" |
| F31 | Strip rows differ between cameras in Program; Collapse All is disabled in two layouts. `main-program-meeting-1320-dark`, `UIToolbar.swift:68`. | Fixed row layout; View menu only |
| F32 | The menu bar triangle replaces the recording dot, so a low-drive warning hides whether a take is rolling. `UIPresentation.swift:915-917`. | Tooltip and first menu line state both |
| F33 | Detached monitor windows can't float over a full-screen meeting (no window level or collection behaviour set, `MonitorWorkspaceView.swift:369-384`). | "Keep on Top" for second-display use |

## 5. Before and after

| Task | Today | Proposed |
|---|---|---|
| See which device feeds each of 2 cameras | 4 to 6 actions | 0 |
| Change record format | 5 | 2 |
| Go from ISO to Program output with takes rolling | Takes must stop: 6+ actions, plus Zoom reselect | Pick the camera in Zoom. Takes continue. |
| Start the second camera from the menu bar | 3 | 2 |
| Hold, with sidebar closed | 3 | 1, or ⌃⌥H |
| Cut with Zoom full-screen | 3 gestures | 1 key, if enabled |
| Learn why a camera stopped | Not possible in the UI | Read the Attention row |
| Find out a take had gaps | Run `scripts/diagnose-capture.py` or read the log | Read the Saved state |

## 6. If ISO and Program can't both be published

The left pane structure holds. These parts change.

- **Virtual Cameras** keeps a two-state control at its top, listing only the published cameras under it.
- **Lock text** stays, but recording alone should stop being a reason. Takes are camera originals and don't depend on the output route, so the architecture audit should try to separate them even if the two outputs can't coexist. The prompt becomes one sentence: "Zoom loses this camera until you pick Ultracam · Program."
- **Stop Cameras and Switch** stays only if a restart truly can't be avoided.
- **Toolbar cut group, Program View and numbered pills** stay conditional on Program mode.
- **Menu bar** keeps an Output submenu.
- **Tally** keeps its current single meaning.

Remove the mode from Settings › Camera either way. One control is enough.

If both **can** be published, one new hazard needs design. Zoom might be using `Ultracam · Camera 1` while the operator is cutting Program, and cuts then don't reach the meeting. The rules:

- Tally red means "a viewer sees this camera now", from either route. Two cameras can be red.
- Cut buttons go neutral when Program has no viewer.
- If an ISO camera is in use and the operator cuts, Attention shows "A meeting app is on Ultracam · Camera 1, not Program. Cuts don't reach it." App names aren't available (D8), so the wording stays general.

## 7. Prior decisions

| Decision | Verdict | Note |
|---|---|---|
| D1, click selects and never cuts | **Holds** | Double-click to cut was considered for Program View and rejected: it adds delay to a live cut and risks accidents. The fix is a larger Cut button. |
| D2, format changes allowed without prompt | **Holds, with a move** | No prompt. The controls leave the live strip, because one stray click reaches Zoom. |
| D3, Stop Camera and Stop All Cameras | **Holds** | Only the placement changes. |
| D4, no orange skipped ring | **Holds** | |
| D5, ⋯ menu plus on-demand inspector | **Holds** | ⋯ gets shorter. |
| D6, backup automation rules | **Holds** | The placeholder row goes. |
| D7, one visible selection | **Revised for hidden use** | It holds in the window. Nothing in the menu bar may depend on it, since the selection can't be seen there. |
| D8, keep time left, takes, Saved; no app names | **Holds** | Saved gains frames lost. |
| P1-11 and P0-3 | **Regressed, restore** | At-rest tools, Auto in one control, and "Stop All Recordings (2)" have all drifted from these fixes. |
