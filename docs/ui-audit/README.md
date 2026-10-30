# Ultracam UI and UX audit: decisions and plan

Date: 2026-10-30. Commit reviewed: `30c8d73`. This is a review only: no source changed.

This file is the decision record. Six specialist reports sit beside it as evidence:

| Report | Covers |
|---|---|
| [01](01-output-mode-architecture.md) | ISO and Program as always-available cameras, and live add, rename and remove |
| [02](02-live-workflows-and-panes.md) | Six live workflows, click by click, and the job of each pane |
| [03](03-feature-inventory-and-placement.md) | 141 capabilities: every surface each appears on, its one home, shortcuts, hardcoded values |
| [04](04-vendor-and-hardware.md) | Vendor and hardware awareness, Devices design, plugin API additions |
| [05](05-audio-and-recording-format.md) | Audio channels by stage, recording format |
| [06](06-visual-polish-and-native.md) | 39 ranked visual findings, color system, copy pass, Settings look and behavior |

Where a report and this file disagree, this file wins. Section 9 lists each conflict and how it was settled.

**Evidence limits.** Everything comes from code, offscreen renders and files on disk. Nothing was run against live cameras or a meeting app, because the installed app was running. Renders use synthetic data, and two gaps matter: fixtures show stereo meters and no camera-control store, so **no render shows the strip as it looks live** (05, 06 V14). The real strip has 8 meter rows, 6 of them silent on this rig, plus a Camera Control row.

## 1. Fix first: takes are failing at about 19 minutes

**Confirmed. This is in the installed build and it is the default configuration.**

Both 2026-10-30 12:24 takes stopped at 12:43 and never finalized. Each journal is 16,777,011 bytes against a 16 MiB cap, and 68,245 entries at 59.94 fps is 18.98 minutes.

- **Cause.** Since `dcb58e1` (2026-10-29), any timecode mode except Source writes one journal entry per frame when the source carries timecode (`AVAssetSourceRecordingWriter.swift:723-727`). A full journal throws `journalFull` (`RecordingTakeSidecar.swift:225`), and that fails the take (`SourceRecording.swift:1119-1135`).
- **Duration.** About 19 minutes at 59.94, 38 minutes at 29.97.
- **Same hazard, second path.** Constant frame rate compatibility also journals every frame (`AVAssetSourceRecordingWriter.swift:739`).
- **Also a per-frame cost.** Each entry does an `fsync` and rewrites the sidecar JSON atomically (`RecordingTakeSidecar.swift:229-231`), on the writer queue, at frame rate.
- **Workaround until fixed.** Set Timecode to Source (from the code, not tested). It returns to Mac Clock on every launch (section 2).
- **The two takes.** Keep the `.partial` files in `/Volumes/4TB Cam B`. Use Record › Recover Interrupted Takes. Not attempted here.

**Fix.** Journal a label only when it breaks the run, as lines 702-709 already do for source timecode. Do the same for line 739. Metadata filling up must never end a take: past the cap, stop journaling and note it in the sidecar.

## 2. Other defects found on the way

All verified in code unless marked.

| # | Defect | Where | Fix |
|---|---|---|---|
| B1 | Codec and timecode are not saved. Every launch returns to ProRes 422 HQ and Mac Clock, so forgetting to re-pick HEVC records at about 30 times the data rate | `RecordingModel.swift:633,659` | Save both |
| B2 | A camera that stops itself ends its take, then looks like a normal stop. The reason reaches only the log | `AppModel.swift:1150-1160`, `UIPresentation.swift:555` | Keep an unexpected-stop state (section 4) |
| B3 | Nothing can reach an operator outside the window: no notification, sound or dock bounce exists | Search of `Sources` and MonitorKit | Section 4 |
| B4 | On-air HDMI loss leaves Program on the dead camera, and Auto does not react. Traced, not run | Health goes false only on stop paths (`AppModel.swift:1185,1284`) | Section 4 |
| B5 | Tally is wrong in Separate: a connected sink counts as a meeting client, so a running camera shows ON AIR with no viewer | `UISessionBridge.swift:128`, `CaptureController.swift:2448` | `inUse` means a real client only |
| B6 | Running cameras render every frame with nobody watching. The no-demand branch can never run, against the project's GPU rule | `FeedRuntime.swift:257`, `CaptureController.swift:2140` | Section 3 |
| B7 | Settings' strategy picker bypasses the bridge, so choosing Manual leaves automatic on | `UISettings.swift:418-423`, compare `UISessionBridge.swift:363-368` | Route through `send` |
| B8 | The source-mismatch refusal prints the literal text `(matrixProfile.displayName)` | `SourceRecording.swift:337` | Interpolate |
| B9 | HEVC estimates run about 11 times high, so time left is 11 times too short | `RecordingSizeEstimator.swift:18` | Use measured rates |
| B10 | Time left ignores other cameras on the same drive until they roll | `UISupport.swift:63-65` | Sum assigned cameras |
| B11 | The inspector hardcodes "4:2:2" in Signal | `UIInspector.swift:340` | Use the real format |
| B12 | Saved takes hide their dropouts: the count disappears at the end of a take, so 60 lost frames read "Saved" | `UIPresentation.swift:679` | Keep it on Saved and Takes |
| B13 | Only one warning shows at a time, yet both cameras dropped together on 2026-10-30 | `UIPresentation.swift:818-847` | Return a list |
| B14 | Transcript assisted is the default director mode, and nothing feeds it | `ingestTranscript` has no caller in `Sources/App` beyond its definition | Hide the picker until a source exists |
| B15 | The selection ring uses the system accent, so a Red accent reads as on air | `UICameraColumn.swift:99` | Fixed blue |

## 3. ISO and Program: always both

**Your instinct was right. Retire the output mode.** Always publish every camera plus Ultracam · Program. What each one costs is decided by whether something is watching it.

- The either-or lives in two app-side `switch` statements. The extension never distinguishes them, and a test already publishes both (`Tests/CameraRegistryRuntimeChecks.swift:90-110`).
- "Stop recording first" protects nothing, because recording does not read the mode. No commit or doc records a reason for the lock.
- A stable device list is also better for meeting apps. Zoom caches its list, so a hot-switch that changes devices would be worse (`VALIDATION.md:781`).

```
programActive     = Program has a client || Program monitor visible || (Auto on && a take is active)
camera sink open  = this camera's virtual camera has a client
GPU processing    = sink open || programActive
```

The cost: no extension update, no macOS approval, no settings migration. The estimate in 01 is 500 to 800 lines in about 18 source files and 3 to 5 days, including real meeting-app testing.

Consequences:

- **Removed:** the Output control in the sidebar, Settings and menus, "Stop Cameras and Switch", and every lock message.
- **Added:** cut buttons appear with 2 or more cameras. They stay neutral while Program has no client.
- **Kept:** View › Show Switching Controls, a never-locked view preference, stored in the existing `outputMode` key so downgrades still work.
- **Tally:** red means a viewer can see this picture, by either route. Two cameras can be red.
- **New hazard:** if Zoom is on Ultracam · Camera 1 and you cut Program, the cuts do not reach it. Attention says so.
- **Also unlocked:** rename live. Add live after two fixes. Remove a stopped camera while others run. Reset stays locked.

Top risk: the no-demand path has never run in the app, so telemetry and first-frame behavior need work (01 section 12).

## 4. Live alerts

A problem must reach the operator wherever they are looking.

- **One problem list.** `warning()` returns all problems, worst first. The Attention section, status bar popover and menu bar all render that list, each problem with one action.
- **Unexpected stop.** Stored per camera with its reason and the take's result, until acknowledged. "Camera 1 stopped: [reason]. Take saved up to 12:31", with Start.
- **System notifications**, time-sensitive level, for: camera stopped unexpectedly, take ended early, recording with no signal, on-air camera lost, drive low or full. Sound off by default, because the room may have open microphones. Test inside a real full-screen meeting, as Focus settings may hold them back.
- **No-signal feeds source health, after a hold.** Auto cuts away from a lost camera. Manual gets a Cut button at the warning. Use a hold of about 1 second: the real dropouts here were 2 frames, and cutting on those would make Auto twitch.
- **Signal lost placeholder** says how long, and stops giving setup advice when the camera had a picture.

## 5. The placement rule and the three panes

| Scope | Used live? | Home |
|---|---|---|
| Whole session | An action | Toolbar |
| Whole session | A glance or pre-show setup | Left pane |
| Whole session | A glance, sidebar closed | Status bar |
| One camera | Yes | Picture and strip |
| One camera | No, setup | Inspector |
| App-wide | Set once or per rig | Settings |
| Whole session | App hidden | Menu bar |
| Engineering detail | No | Diagnostics |

**The test of the split:** you can close both side panes during a live session and lose nothing you need.

### Left pane: the session board

It reads in signal order and answers what the window cannot show today: what is connected, what is going out, where it is saving, what is wrong.

```
ATTENTION                        only when something needs it
  ▲ Camera 1 stopped on its own   [Start] [Why]
CAMERAS                                               +
  ● Camera 1                                      On air
    UltraStudio 12G · 2160p 59.94 · 4 dropouts
    Sony FX3 · connected · 78%
VIRTUAL CAMERAS
  ✓ Ultracam · Program            In use · 1080p 29.97
    Ultracam · Camera 1           Not in use
    Video only. Pick your microphone in the meeting app.
SWITCHING                                    with 2+ cameras
  Auto · Natural talking head
  Camera 1 · shot 8 s  ▬▬▬▬▬|▬▬▬|▬▬
  5:22:23 Camera 1  Auto
RECORDING
  Format [HEVC 4:2:2 ▾]   Timecode [Mac Clock ▾]
  Takes · 8TB · Camera 1, 2              1 h 52 m left
  ▬▬▬▬▬▬▬▬▬▬
  Camera original, no LUT or effects
TAKES
  5:40 PM · 12:31 · 2 cameras · 0 lost           [Show]
```

**Removed:** Output control, Sync cameras, Auto toggle, Strategy picker, Hold, the "2 recording" line, Automation, and both "Coming later" rows. Interrupted Takes becomes an Attention row. Empty Attention means healthy.

### Centre: pictures and strips

Job: see it, hear it, roll it. Each fact has one owner (06 section 2).

- **Picture at rest:** name, tally, REC pill, plus one tools button and any active tools. The full tool bar appears on hover. The REC pill never truncates.
- **Program View:** loses the cut bar and Recent Cuts, and tiles get full-width Cut buttons.
- **Strip, removed:** the On Air badge, Stop Camera button (moves to ⋯), size and bitrate, Own Folder badge, footnote, Camera Control row, all effect chips and the Processing switch.
- **Strip, fixed rows:** header · record row · folder and time left, with read-only format · output row · meters. Rows never appear or vanish, so nothing moves under the pointer.
- **Output row:** Cut slot, then "Output 1080p · 4:2:0 8-bit · 29.97 · In use", then one Effects menu holding LUT, Resize, Color, Frame rate and Processing. Two deliberate clicks, because each one renegotiates what Zoom is receiving. D2 still holds: no prompt.
- **One clock per camera.** Pressing Record must not resize the picture.

### Right: inspector

Setup only, closed during live work. Order follows the signal: Source, Camera Control, LUT, Effects, Recording, Automation, Rename and Remove. One row per effect, merging each checkbox with its value. Sync cameras lives only here, with a confirmation naming the source camera, because turning it on rewrites other cameras' effects.

### Toolbar

`[1 Camera 1] [2 Camera 2] | [Auto ▾] [Hold]` ... `[Start Cameras, only when needed]` `[● Stop 2 Recordings ▾]` | `[layouts]` | `[inspector]`

- **Auto** gets a word on it, plus a menu with Strategy, Anchor and Emphasis. This is the only Auto control on screen.
- **Hold** appears beside Auto when Auto is on, for every strategy, with ⌃⌥H.
- **Stop Cameras is gone while running.** It stays at ⌘↩, in the Camera menu and in the menu bar. That ends the same-glyph confusion with Stop All Recordings.
- **Record menu** offers Format, Record Camera 2 and Pause All.
- **Red dots, not red fills,** because prominent tints go gray when the window isn't key, which is all of a meeting.

### Status bar

Problems first, then Virtual Cameras, Program, Recording, Audio. Session clock lives here. "Audio OK" becomes "Audio 2 of 2". Drop memory and "(video)".

### Menu bar

Run the session with the window hidden, in 14 rows or fewer. Order: card, problems with actions, cuts, Auto, Hold, record per camera, format, one time-left line per drive, camera submenus, Open, Settings, Quit. **No row may depend on the window's selection**, which removes top-level Processing, Video Preview and Start with Camera Apps.

## 6. Settings window

**Rebuild as a sidebar window like System Settings.** Fixed 820 pt wide, default height 620, resizable in height, with no per-pane heights. Each pane scrolls, so the window never jumps. It reopens where you left it. Layout rules, row kinds and help-text rules are in 06 section 8.

| Section | Contains |
|---|---|
| **General** | Show Ultracam in, Open at login, Ask before ending a recording or on-air video |
| **Devices** | Every capture device and camera body, grouped by vendor (section 7) |
| **Virtual Cameras** | Extension status, Install, Update, Remove |
| **Recording** | Folder table with default and per-camera rows, file-name pattern and preview, camera subfolders |
| **Audio** | **Channels shown** and loudness pair per camera, true-peak warning level |
| **Switching** | Program color, Fixed interval, Natural talking head timing, Advanced cut decisions |
| **Monitoring** | Scope refresh rate |
| **Alerts** | Which events notify, sound, low-space levels, background shortcuts |
| **Advanced** | Allow CPU conversion, Copy Diagnostics, Forget Saved LUTs, Reset |

**Leaves Settings:** Layout and New Camera Strips (no real use), Output mode, Sync cameras, Backup Recording placeholder, Dynamic analysis placeholder, Monitor prose (to Help), Codec and Timecode (to the main window), Crash Recovery (to Attention).

**Channels shown.** Per camera, because embeds differ by source. Values: As Detected, 2, 4, 8, 16. "As Detected" is measured, because DeckLink reports only maximums: it means the highest pair that has carried signal since capture started, and it only grows. The meter block stays 44 pt tall at every value, so strip height never changes. Hidden channels are still metered and recorded, and an over on a hidden channel still lights OVER. Collapsed strips always show the loudness pair. The right-click menu on a meter offers the same choice.

Today's reality: 8 channels are captured, recorded and metered, loudness reads channels 1-2, and the virtual cameras and Program carry no audio. On this rig 3-8 are silent, so "As Detected" shows 2. Detail: 05 Part A.

## 7. Hardware awareness

The data mostly exists in `VendorRegistry`, but `AppHardware` flattens it to IDs, names and a warning string. Connectors, SDK version and the signal hint have no UI reader. Idle devices have no status, "in use elsewhere" appears only after Start, and a Sony drop raises no warning.

**Settings › Devices.** One section per vendor, in registry order, with expandable rows: health, name, assigned camera, state, link. Includes **expected hardware that is absent**, by last known name. This rig has two identical Mini Recorder 12Gs, so per-device nicknames matter.

- **Pairing moves here.** The assignment pop-up is the pairing control, and sign-in opens inline. The Camera Control sheet keeps one job: operating a connected body.
- **Input connector and Advertise HDR** move here from Advanced. These can drop the signal, so ask first when the device is in use.
- **Main window shows hardware through the left pane and problems.** No extra strip row.
- **Plugin API additions:** idle-readable device status, typed facts and problems, control telemetry tags, a control vendor snapshot, and a plugin-supplied missing-device hint. Vendor names stay out of `Sources/App`, which `scripts/check-vendor-boundaries.py` enforces.
- **A USB 3 fallback unit cannot be detected.** DeckLink never lists it, so the symptom is a saved input gone missing. The missing-device hint should say to check the hub. An "HDMI · USB 3" chip cannot work.
- **Rig presets: not now.** Everything a preset would hold already persists.

A build without the Sony SDK must read as normal, with no warnings.

## 8. Recording format

**Format is in the left pane's Recording section, the Record toolbar menu, the Record app menu and the menu bar.** Each strip shows its camera's format read-only, so closing the sidebar loses nothing. It applies to the next take. A rolling camera shows its take's own format, read-only.

The menu shows each codec with its real rate and the time left on this drive, for this source. A camera whose source cannot use the choice takes the nearest format, shown in orange on its strip ("ProRes 4444 → ProRes 422 HQ"), so the UI never fails a take for something it already knew. Fallback table: 05.

**Program is not recorded.** A streaming session leaves per-camera originals and a cut list. The UI should say so plainly. A real Program recording needs its own design, including whose audio it carries, so it stays out of this plan with no placeholder.

## 9. Conflicts between reports, settled

| Question | Reports | Decision and why |
|---|---|---|
| Format scope | 05 per camera with default. 02, 03 global | **Global for now.** It is one control instead of a new override on every surface, and fallback already handles mismatched sources. Per-camera can be added later; see section 12 |
| Channels shown home | 05 inspector | **Settings › Audio.** Your sentence puts it in the Settings window. The meter's right-click menu is the live shortcut |
| Effect chips | 02 move to inspector. 06 Effects menu on the strip | **06's menu,** with Processing inside it. No always-visible switch, because Processing is the biggest single change a click can make to a live meeting |
| Toolbar Stop Cameras | 02 remove. 06 keep and rename | **02.** Fewer controls, and it removes the hazard instead of labeling it |
| Tool bar at rest | 02 active tools. 06 one button | **Both:** one button plus active tools |
| ⋯ menu | 02 trim. 03 remove on expanded strips | **Trim.** Stop Camera moves into it |
| Strip Cut button | 02 keep. 03 remove | **Keep** in a fixed slot. In Side by Side, eyes are on the pictures |
| Hardware on the strip | 04 source row. 02 sidebar rows | **Sidebar.** The strip already has too many rows, and problems surface as warnings. 04's camera menu still names both links |
| Strategy home | 02, 03 sidebar. 06 toolbar | **Toolbar Auto menu.** The sidebar shows it read-only, so there is one control |
| Output mode | 03 keep in sidebar | **Removed,** per 01. 03 assumed the mode would stay |
| Settings structure | 03 six panes. 04 Devices tab | **Nine sidebar sections.** 03's and 06's sidebar with 04's Devices |
| Director tuning sliders | 03 remove from UI | **Keep** under Advanced in Settings › Switching. You said the feature set is how you want it, and they cost nothing there |

## 10. Prior decisions

| Decision | Status |
|---|---|
| D1, click selects and never cuts | Holds |
| D2, format changes without prompt | Holds; controls move off the live surface |
| D3, Stop Camera and Stop All Cameras | Holds; placement changes |
| D4, no orange skipped ring | Holds |
| D5, ⋯ menu plus on-demand inspector | Holds; ⋯ shrinks |
| D6, backup automation rules | Holds; placeholder rows go until it is built |
| D7, one visible selection | Holds in the window; the menu bar no longer depends on it |
| D8, keep time left, takes, Saved; no app names | Holds; the sidebar stops repeating recording state |
| Left sidebar as V1 session panel | **Revised** to the session board |
| `UI_REDESIGN.md:105,226`, output locked while running | **Overridden** |

## 11. Order of work

Each phase can ship alone.

| Phase | Work | Size |
|---|---|---|
| **0. Stop losing material** | Journal fix, B1, B7, B8, B11, B15 | Hours |
| **1. Live alerts** | Section 4, B5, B12, B13, ship with fixtures for 8-channel strips and a camera-control store so renders match the app | 1 to 2 days |
| **2. ISO and Program** | 01's order: topology rules, demand core, publish both, GPU gate, docs. Includes B6 | 3 to 5 days |
| **3. Main window** | Section 5, format control, copy pass, color system, contrast | 3 to 4 days |
| **4. Settings** | Section 6, channels shown, B9, B10, B14 | 2 to 3 days |
| **5. Hardware** | Section 7, plugin API first | 3 to 5 days |

Sizes other than phase 2 are rough estimates of mine.

## 12. What needs you

**Live checks only you can run**, when Ultracam is not serving a meeting:

1. Zoom holding a camera through the upgrade to always-published, and whether it needs a restart to list Program.
2. Program in Zoom plus ISO in a second app at 4K, and time to first frame on a client joining a running camera.
3. Unplug HDMI on the on-air camera, to confirm B4.
4. A notification during a full-screen meeting.
5. Sony control on a real FX3: which fields it reports.
6. Whether the OWC hub was in the same wiring at 13:59:04 on 2026-10-30. Both units now sit behind it, which makes it a lead for the simultaneous drop, not a finding.

**Decisions made here you may want to reverse:** format is global, not per camera (section 9); Stop Cameras leaves the toolbar while running; Program recording stays out of scope.
