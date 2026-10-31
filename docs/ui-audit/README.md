# Ultracam UI and UX audit: decisions and plan

Date: 2026-10-30. Revision 4: revision 2 followed an independent validation pass. Revisions 3 and 4 record the owner's review: tabs for Settings, the monitor tool bar collapses on hover-off but keeps enabled tools visible, and Switching leaves the sidebar. Code reviewed at `2c4929c`. This is a review only: no source changed.

This file is the decision record. Where anything below it disagrees, this file wins, with one exception: [validation J](validation/J-rulings.md) holds the rulings from the audit of the full mockup set and overrides the text here where the two differ. The drawn set in `docs/mockups/r5/` shows the result.

| Evidence | Covers |
|---|---|
| [01](01-output-mode-architecture.md) · [validation B](validation/B-iso-program-red-team.md) | ISO and Program, and the attempt to break the design |
| [02](02-live-workflows-and-panes.md) · [validation C](validation/C-operator-red-team.md) | Live workflows, and an operator's run through the proposed design, with before and after counts |
| [03](03-feature-inventory-and-placement.md) | 141 capabilities: every surface, one home, shortcuts, hardcoded values |
| [04](04-vendor-and-hardware.md) · [05](05-audio-and-recording-format.md) · [validation E](validation/E-settings-audio-hardware.md) | Hardware, audio, recording format, Settings contents |
| [06](06-visual-polish-and-native.md) · [validation D](validation/D-platform-feasibility.md) | 39 visual findings, color system, copy pass, and what macOS actually allows |
| [07](07-visual-language.md) | Every surface's symbols, type levels and reusable components, with symbol names checked for macOS 26 |
| [validation A](validation/A-defects-and-fixes.md) | Every defect and fix, re-derived, with the journal rule replayed on the real take files |
| [validation G, H, I, J](validation/J-rulings.md) | Audits of the full mockup set for consistency, plan conformance and live use, and the rulings on them |
| [validation F](validation/F-fact-check.md) | 104 claims checked: 73 correct, 21 partly right, 4 wrong, 6 unverifiable |

**Evidence limits.** Everything comes from code, offscreen renders, files on disk and the system log. Nothing was tested on live cameras or in a meeting app. Renders use synthetic data, so no render shows the live strip: 8 meter rows, 6 of them silent on this rig, plus a Camera Control row. Labels: **verified** means read in code or on a real file. **Traced** means followed through code, not run.

## 1. What validation changed

| First pass | Now | Why |
|---|---|---|
| Journal fix: journal only when the run breaks | **New rule** (section 2) | The stated rule failed: the FX3 repeats labels, so "next label +1" still journals every frame. Replayed on both real journals, the new rule keeps 36 records and rebuilds all 68,245 labels |
| One recording fault | **Three** (section 2) | A failed take keeps showing REC, and a dropout during a take very likely ends it. Fixing the journal alone would move the failure to the first dropout |
| HDMI loss handled with a hold | **The app can't see HDMI loss after the first frame** | After the first frame the UI reads live whatever arrives, so every "No signal" state is unreachable |
| One `programActive` flag | **Replaced** (section 4) | Cuts wouldn't land with no client, and the rule would have gone black under a red tally |
| Program always published | **Published with 2+ cameras** | One camera has nothing to switch, and a third entry invites a wrong pick in Zoom |
| Show Switching Controls preference | **Dropped** | It was the old mode in a new name |
| 3 to 5 days for ISO and Program | **7 to 10 days plus two sessions with you** | The first estimate counted only removing the mode |
| Every effect behind a menu | **LUT stays one click** | LUT off changes pixels, never Zoom's format. It is the panic control |
| Time-sensitive notifications reach you | **Not on their own** | They need an entitlement, and sharing a screen may silence them. A floating panel is added, with limits (section 5) |
| Left pane as drawn | **Trimmed** | Too tall: about 1046 pt in the heavy case, with Format below the fold on a 13-inch display |
| "Close both panes and lose nothing" | **Reworded, and made true** | It was false: one-click fixes were lost, and the shot timer now lives in the status bar |
| Nine Settings sections, "Devices" | **Eight, "Hardware"** | Monitoring's one control is per camera, so it belongs in the Scopes popover |
| Loudness pair setting | **Dropped** | Nobody asked, and it would do half a job, because Auto still reads channels 1-2 |
| Rig presets | **Still not now, plus a Setup block** | "Configurations" most likely means how each vendor's gear is set up, which the first pass missed |

**Survived unchanged:** retiring the output mode, the three-pane structure, the session board idea, global format, Stop Cameras off the toolbar, Channels Shown in Settings, and the placement rule.

**Rejected from the review:** making the Settings rebuild optional. It was called out of scope, but you asked for that overhaul by name.

## 2. Fix first: recording and virtual output

### Takes fail at about 19 minutes

**Verified.** In the installed build, with Mac Clock or Record Start and a source carrying timecode, every frame adds a journal entry, and a full 16 MiB journal fails the take: about 19 minutes at 59.94, 38 at 29.97.

Both 12:24 takes failed at 12:43 on the same frame count. They are complete 18:58 movies with 68,245 frames, closed cleanly at 18:59 and hidden as `.partial` files on `/Volumes/4TB Cam B`. Recover them from the sidebar's Interrupted Takes section, not the Record menu, which may do nothing. Recovery has not been attempted.

**Nothing reads the journal.** That makes this fix safe, and the cost is forensic detail only.

**Fix.** Two parts:

1. Journal a native label only when it can't be predicted: the first two frames, any gap or pause, any change of rate, epoch or drop-frame flag, or any frame whose label minus the label two frames back differs from the current stride. The stride starts at 2, which fits both 1:1 and paired counters. Variable-rate labels stay per frame. Code is in validation A.
2. Metadata must never end a take. The writer calls a non-throwing `journal(_:)`. Label and timing records stop at 15 MiB, clock and audio records may use the last 1 MiB, and anything past that is counted and dropped. The sidecar and the take's note both say so. `RecordingTakeLifecycleChecks:152-178` must be rewritten.

After this, the journal lasts about 595 hours at this rig's rate, and the limits are disk and signal. **The longest take on record is 101 minutes, so run one take of 3 hours or more that crosses a dropout before trusting long sessions.**

### A failed take still reads as recording (N1)

**Verified, and this is what happened today.** Nothing reacts when a take fails, so the strip, REC pill and clock kept running for 6 h 16 m after both cameras stopped writing, until Stop at 18:59. Only an orange status segment and the menu bar triangle showed it.

**Fix.** Stop the take automatically on failure. Show `.failed` first in the strip's recording and paused states. If the writer closed cleanly, publish the movie instead of hiding it for recovery. Log at the moment of failure, as the only log line today comes at Stop.

### A dropout during a take very likely ends it (N2)

**Path verified, runtime traced.** On a no-input callback, audio arrives with no paired frame, and since `dcb58e1` that rejects the take (`CaptureController.swift:1724-1727`). No take on this code has met a dropout yet. Today's rate of 5 per camera in 399 minutes would give a 1-hour take on two cameras about a 22% chance of surviving.

**Fix.** Keep placing unpaired audio from the last valid pair, instead of rejecting or dropping it, since dropping would slip sync for the rest of the take. **Ship with the journal fix, never after it.** Add a test using `FakeCaptureSession`.

### Virtual camera connections are failing

**Verified in the log.** All 12 `Camera connect failed` lines today, with none succeeding, 11:23 to 12:33, on both cameras, each saying to install and enable the extension. The failure shows only in Diagnostics.

**Likely cause, not proven: a pending restart.** The system camera list shows the UltraStudios and OBS but no Ultracam camera, though `systemextensionsctl` shows build 10 activated and enabled. Build 10 landed on 2026-10-30 at 01:27 and the Mac last restarted on 10-25. That matches the app's own "enabled, not started until a restart" state. The camera list was read with Ultracam closed. The failing line is traced to the provider lookup (`VirtualCameraRegistryTransport.swift:88`), not confirmed by a log line. Whether the app's restart banner showed is unknown.

**Restart the Mac, then confirm an Ultracam camera appears in Zoom.** If it doesn't, this is a real transport bug and comes first, because every part of section 4 uses this path. Either way, a connect failure must reach the main window, not just Diagnostics.

### Until this is fixed

Treat ISO recording in the installed build as unreliable.

- Set Timecode to Source before every take and after every launch. This relies on the first frame carrying a label. It does nothing about N2.
- Watch the status bar during a take. The strip will not show a failure.
- Restart the Mac, then check that Zoom lists an Ultracam camera and shows a real picture.

## 3. Other defects

All verified unless marked.

| # | Defect | Fix |
|---|---|---|
| N3 | HDMI loss is invisible after the first frame: the UI reads live whenever a source format is known (`UISessionBridge.swift:72`) | Typed `CaptureSignal` on `CaptureUpdate`, published on transition. Everything in section 5 depends on it |
| B1 | Codec and timecode aren't saved | Two keys beside `allowCPUConversion`, no migration, include in Reset |
| B2 | A camera that stops itself looks like a normal stop. `stopped: true` is sent for both | `CaptureStopCause`, plus an `UnexpectedStop` held until acknowledged |
| B3 | Nothing reaches an operator outside the window | Section 5 |
| B4 | On-air loss doesn't move Program or Auto | Section 5 |
| B5 | A connected sink counts as a viewer, giving false ON AIR | Use real client demand **and start the demand monitor always**. The fix alone turns Separate tally off permanently |
| B6 | Running cameras render every frame for nobody | Section 4 |
| B7 | Settings' strategy picker leaves automatic on after Manual. Lower severity: picking a strategy later re-enables Auto silently | One `AppModel.setStrategy(_:)` |
| B8 | The source mismatch refusal prints literal `(matrixProfile.displayName)` and `(error)` | Interpolate both |
| B9 | Idle HEVC estimates run about 11 times high | Display only: `UIRecordingLibrary` uses 0.014 bytes per pixel plus PCM. **Do not change `RecordingSizeEstimator.swift:18`,** which also guards free space |
| B10 | Idle time left ignores other cameras on the drive | Sum assigned cameras |
| B11 | The inspector hardcodes "4:2:2" | Use the real format |
| B12 | Dropouts vanish once the camera stops: Saved does show the gap note, but the Saved state is lost | Keep Saved after stop. Show lost frames in Takes |
| B13 | One warning at a time | Return a list |
| B14 | Transcript Assisted is the default and nothing feeds it | Hide it, and force Low Latency until a source exists |
| B15 | Selection ring follows the system accent, so a Red accent reads as on air | Fixed blue |
| B16 | Extension queue stalls are only counted, so Zoom can freeze while Ultracam looks healthy (traced) | Queue full for 2 s raises a problem with Restart Camera |
| B17 | A take keeps rolling after the meeting ends | After 2 minutes unused: "Still recording: no meeting app is using Ultracam". Never stop the take (D6) |
| B18 | Eight unlabeled channels get 7.1 names in the popover, and the status text says "48 kHz stereo" on 8 channels | Number them. Use the real count |
| B19 | `Copy Diagnostics` has no hardware in it | Add driver, model, device ID, link and Sony state |

Wrong in code comments: four say recording gets the burn-in LUT. It never does.

## 4. ISO and Program

**You were right. Retire the output mode.** Every camera is always published, plus Ultracam · Program once there are two or more. Nothing is locked. The extension needs no update.

The lock protected nothing: recording never reads the mode, and no commit or doc gives a reason. A stable device list also suits meeting apps, because Zoom caches its list.

### What decides the work

```
programClient    = Program has a client (released after a 5 s hold)
programPicture   = programClient || Program monitor visible
cameraClient(c)  = c's virtual camera has a client (released after a 5 s hold)
autoTake         = automatic strategy && a take is active

scheduler        = always, on metadata, so a cut lands in every layout
source wanted(c) = automatic cameras only: cameraClient(c) || programPicture
                   || autoTake || c records || c's preview is visible
sink open(c)     = cameraClient(c) && c running
GPU render(c)    = sink open(c) || sink connecting(c) || (programPicture && c running)
Program sink     = programClient && any enabled camera running
monitor(c)       = every output-cadence source frame, always
recording(c)     = every source frame, always
```

| Situation | Sink | Render | Cuts |
|---|---|---|---|
| Running, nobody watching, preview up | No | **None** | Land |
| Recording, no client | No | **None** | Land |
| Program View open, no client | No | All cameras | Land, with a picture |
| One ISO client | That camera | That camera | Land |
| Program client | Program | All cameras | Land |
| ISO and Program clients | Both | All cameras | Land |

Rules that keep this safe:

- **Late sink.** Pre-negotiate each camera's format when its contract changes. Replace the busy-mismatch throw from `dcb58e1` with connect-then-renegotiate. Retry once a second while a client is waiting, and raise a problem instead of a Diagnostics line. **This is the blocker:** today's code gives an ISO client black under a red tally.
- **Release hold.** A client leaving takes effect after 5 s, so a meeting app probing devices doesn't restart capture, the director or timeline files. A user Stop ignores the hold.
- **Losing the on-air source.** If it stops or fails and another camera is producing, Program moves to it and says so. Today Program goes black and a cut doesn't recover it.
- **Director.** Runs when strategy is automatic, 2+ cameras run, and Program has a picture or a take is active. Its audio and clock come from the anchor, not from the UI selection.
- **Idle path.** It has never run in the app. Set applied state and timing correctly so a camera with no client doesn't read as Updating. Keep the processor built, and free GPU resources after 30 s without a render.

The on-screen picture keeps showing the LUT without a render, and recording is unaffected: both verified.

### Tally

Red needs frames arriving, not just a client. A camera is either `ON AIR` (Program) or `ISO` (its own device), so two reds never hide which picture Program is on.

```
live(c)      = c running, signal live
ON AIR (red) : c on air && Program client && Program sink connected && live(c)
ISO    (red) : own client && own sink connected && live(c), and not ON AIR
NEXT         : pending cut target, and neither of the above
PROGRAM      : on air, not ON AIR, 2+ cameras
```

A client that exists but isn't receiving frames shows no red and raises a problem: "A camera app is waiting for Camera 1". If you cut while an ISO client exists and Program has none, Attention says the cuts aren't reaching it.

### What else this unlocks

Rename live. Add live, once adding stops flushing Program. Remove a stopped camera while others run. Reset stays locked. A rename reaches meeting apps only when the extension restarts.

### Behavior that changes

Starting one camera no longer starts the others for Program. Start All covers that habit.

**Fallback.** If renegotiating under a meeting app fails in testing, open the sink with the camera and send no frames until a client arrives. That gives instant joins at the cost of a polling timer per running camera.

## 5. Live alerts

A problem has to reach you wherever you're looking. No single channel does, so these are layered.

- **One problem list.** Status bar, Attention and menu bar render the same list, each problem with one action.
- **One problem, said once per place.** The picture says what happened, the strip says what to do, and the signal badge holds the state. The REC pill stays plain REC.
- **Camera problem.** It replaces that camera's folder row in place. The row is 24 pt in every state, so the strip never changes height and Cut never moves. "2 problems" opens the list.
- **Session problem.** First status bar segment, with its action as a button in the bar, so it's one click with the sidebar closed.
- **Attention.** Pinned above the scrolling sidebar. It never opens the sidebar by itself, because that would resize pictures mid-show.
- **Unexpected stop.** "Camera 1 stopped: [reason]. Take saved up to 12:31", with Start. A restart clears the camera part; the take result stays until acknowledged.
- **System notifications** for: camera stopped unexpectedly, take ended early, recording with no signal, on-air camera lost, drive low or full. Time-sensitive only when on air or rolling. Needs the Time Sensitive capability and a change to `prepare_local_build.py`. Text stays safe to show a meeting. Sound off by default. Ask permission in Settings or before a session, never while live.
- **Alert panel** for the three worst: on-air camera lost, take ended early, camera stopped while on air. A small non-activating panel at `.screenSaver` level, with sharing set to none. It reaches a full-screen meeting only when Ultracam's windows are closed. With a window open it's untested.

Not used: `requestUserAttention` adds no reach. Keep on Top for detached monitors won't layer over a full-screen meeting.

**On-air loss, for every strategy.** AppModel owns one rule, timed by its own timer, because no frames arrive during a loss:

1. After 1 s without signal, mark the camera unhealthy. All 10 dropouts today lasted 23 to 33 ms.
2. If it's on Program and Auto is on, cut to the next live camera in strip order and tell the director.
3. If no camera is live, stay and warn: "No camera has a picture".
4. With Auto off, cut nothing. Show Cut at the warning and on the placeholder.
5. **Hold:** loss overrides it once, because a shot with no picture isn't worth holding. Hold stays on for the new shot, and you're told.
6. **Loud, not quiet.** On-air loss draws an orange ring, a large Cut and a live countdown, `Take ends in 4 s`. Red stays reserved for frames arriving.
7. A camera is eligible again after 5 s of steady signal. Nothing cuts back on its own, apart from the director's ordinary rules.

The placeholder says how long the signal has been lost. A loss over 10 s ends the take by design, so the placeholder says that.

## 6. The placement rule and the three panes

| Scope | Used live? | Home |
|---|---|---|
| Whole session | An action | Toolbar |
| Whole session | A glance or pre-show setup | Left pane |
| Whole session | A glance, sidebar closed | Status bar |
| One camera | Yes | Picture and strip |
| One camera | No, setup | Inspector |
| App-wide or per rig | Set once | Settings |
| Whole session | App hidden | Menu bar |
| Engineering detail | No | Diagnostics |

**The test of the split:** you can close both side panes during a live session and still see and act on everything the show needs.

**Exception:** a per-camera setting gets a table in Settings only when cameras are compared side by side and it isn't needed live. Folders and Channels Shown pass.

### Left pane: the session board

It reads in signal order and answers what the window can't show today: what is connected, what's going out, where it's saving, what's wrong.

```
ATTENTION                                       pinned
  ▲ Camera 1 stopped on its own   [Start] [Why]
CAMERAS                                              +
  ● Camera 1                                    ON AIR
    UltraStudio 12G · HDMI
    FX3 · Wi-Fi · 78%
VIRTUAL CAMERAS                            collapsible
  ✓ Ultracam · Program                          In use
    Ultracam · Camera 1                     Not in use
RECORDING
  Format [HEVC 4:2:2 ▾]
  Camera original · Mac Clock
  Takes · 8TB · Camera 1, 2            1 h 52 m left
  ▬▬▬▬▬▬▬▬▬▬            [Folder for Next Take…]
TAKES
  5:40 PM · 12:31 · 2 cameras · 0 lost        [Show All]
```

- **Heavy case:** about 663 pt, down from 1046 (estimated). It fits every display checked, including 1440 × 900. Only Virtual Cameras collapses, and nothing collapses by itself.
- **Cameras** shows only what the strip doesn't: capture device, connector, camera body, Wi-Fi and battery. The strip's signal badge owns format and dropouts.
- **Takes** shows the latest only. `Show All` reveals them in Finder.
- **Virtual Cameras** is one line each. The microphone reminder appears only until something is in use.
- **No Switching section.** Everything about switching is in the toolbar, and the shot time is in the status bar. The owner rejected a sidebar section, and it only repeated those two.
- **Removed:** Output control, Sync cameras, Auto, Strategy, Hold, the shot timer, the "2 recording" line, Automation, both "Coming later" rows. Interrupted Takes becomes an Attention row. An empty Attention means healthy.

### Centre: pictures and strips

Job: see it, hear it, roll it. Each fact has one owner (06 section 2, with the corrections in validation C).

- **Clean View is the one exception to the rest rule:** it shows no tools at rest, and hover brings them back. The tally ring stays.
- **Picture at rest:** name, tally, REC pill, a tools button, and **every enabled monitor tool, which stays visible after the pointer leaves.** So you can always see what's active, and turning one off is one click. Hovering the picture expands the full tool bar, with chevrons, in every state, including no signal and stopped. Build the hover on the picture itself, not on `revealed`, which is live-only and would bring back the `b621bc7` bug. The owner set this behavior. The REC pill never truncates.
- **Program View:** loses the cut bar and Recent Cuts. Tiles get full-width Cut buttons.
- **Strip removed:** On Air badge, Stop Camera button (moves to ⋯), size and bitrate, Own Folder badge, footnote, Camera Control row, effect chips, Processing switch.
- **Strip rows, fixed:** header · record row · folder, time left and read-only format (or the problem) · output row · meters. Nothing appears or vanishes, and pressing Record doesn't resize the picture.
- **Output row:** Cut slot, then "Output 1080p · 4:2:0 8-bit · 29.97 · In use", then a **LUT toggle**, then one **Effects menu** holding Resize, Color, Frame rate, Camera Display and Effects Off. The LUT toggle is one click because it changes pixels, never the format. Everything in the menu changes what Zoom receives, so it takes two deliberate clicks. D2 holds: no prompt. Below 440 pt the output line shortens to "1080p 29.97 · In use".
- **One clock per camera.** Clean View plus a collapsed strip keeps the digits.
- **Signal badge:** shows a dropout count above zero, so a problem with no take rolling still leaves a trace.

### Right: inspector

Setup only, closed during live work. Order follows the signal: Input, Camera Control, LUT, Effects, Recording, Automation, Rename and Remove (J8). One row per effect, merging each checkbox with its value. Add Remove LUT, which doesn't exist per camera today. Sync cameras lives only here, with a confirmation naming the source camera, because turning it on rewrites other cameras' effects. Its help must state that it also copies source declarations and preview, which it does today.

### Toolbar

`[1 Camera 1] [2 Camera 2] [Auto Off ⌄] [Hold]` · `[Start Cameras, only when needed]` `[● Stop 2 Recordings ⌄]` · `[layouts] [inspector]`

- **Auto** is a toggle reading "Auto On" or "Auto Off" at fixed width, plus a chevron menu for Strategy, Anchor and Emphasis. It must not rely on a tint, which goes gray whenever the window isn't key. With Manual selected, clicking Auto opens the strategy menu.
- **Hold** is always present, disabled when Auto is off, so nothing shifts under the pointer. ⌃⌥H. Hold for Fixed Interval needs engine work, which is in phase 3.
- **Stop Cameras is gone while running.** It stays at ⌘↩, in the Camera menu and in the menu bar. "Start Camera 2" shows when only one is stopped.
- **Record** is a button plus chevron menu: Format, Record Camera 2, Pause All.
- **Red dots, not red fills.** Group these on three pieces of glass.
- **Check on macOS 27:** `NavigationSplitView` plus `.inspector` is reported to jump and crash there. This is unverified, and it's the main window's structure.

### Status bar

Problems first, then Virtual Cameras, Program, Recording, Audio.

- **Program segment:** "Camera 1 · shot 8 s · Auto", and after an override "Camera 1 · shot 3 s · Auto in 4 s".
- **Recording:** the session clock lives here.
- **Audio:** "Audio OK" becomes "Audio 2 of 2".
- **Resources:** drop memory and "(video)".

### Menu bar

Run the session with the window hidden. Fourteen rows or fewer when healthy; problem rows don't count against that, and all drives share one row. Order: card, problems with actions, cuts, Auto, Hold, record per camera, Pause All, format, time left, camera submenus, Start or Stop Cameras, Open, Settings, Quit.

**No row may depend on the window's selection.** That removes top-level Processing, Video Preview, Start with Camera Apps and Show Live Preview's selected-camera logic. LUT becomes a direct row in each camera submenu.

### Background shortcuts

Off by default, set in Settings › General. Uses `RegisterEventHotKey`, which needs no Accessibility permission. Defaults: ⌃⌥⌘1 to ⌃⌥⌘7 for cuts, ⌃⌥⌘A Auto, ⌃⌥⌘H Hold, ⌃⌥⌘R Record. **Global Record only starts, never stops,** because a stray chord must not end a take. A Stream Deck can send these with no Ultracam work.

### Visual language

Too much of the app is plain lines of text joined by dots, so state has to be read instead of seen. Report 07 redraws every surface. Nothing in it adds a click, hides a control or removes information. It adds no layout changes of its own.

- **One symbol per noun, everywhere.** Hold is a pin, because a raised hand means something else in a meeting. Program is `tv`, Cut is `arrow.left.arrow.right`. Zebra and Clip get their own marks, so a triangle only ever means a warning.
- **Icon plus value replaces dot-joined text.** Formats become chips. Drives, battery and shot time get level glyphs and bold values.
- **The number is the strong element.** Labels and units are small and dim, and digits are monospaced. Two new type levels: `uiTally` and `uiValueStrong`.
- **State is symbol plus color, never color alone.** Green check for a virtual camera in use, gray ellipsis for not in use. No red text.
- **Icons stop where they stop helping.** Words stay on anything that ends something, on problem sentences, tally words, CPU and GPU, form rows, app menus and Help (07 section 5).

Each surface's changes ship in the phase that rebuilds it. Render checks are needed for the Zebra and Clip marks at 13 pt, and for menu bar badges beside shortcuts.

### Copy

Follow 06 section 5, with two changes: the noun is **Effects**, and **Program color keeps its name**, because it has no effect outside Program. "Feed" leaves all six user-visible strings.

## 7. Settings window

**Keep native toolbar tabs, with one tab for each section below. Decided by the owner, 2026-10-30, overriding 03, 06 and validation D, which chose a sidebar window.** Tabs are the standard Mac pattern and the smaller change. Widen the window to 820 pt so eight tabs fit, and keep the `Settings` scene. Remove the six hardcoded pane heights, which cause the cut-off content, and let long panes scroll. The window may resize between tabs: that's normal Mac behavior. It reopens on the last tab. Row kinds and help-text rules: 06 section 8. Its sidebar and sizing instructions no longer apply.

| Section | Contains |
|---|---|
| **General** | Show Ultracam in, Open at login, Ask before ending a recording or on-air video, background shortcuts |
| **Hardware** | Every capture device and camera body, grouped by vendor (section 8) |
| **Virtual Cameras** | Extension status, Install, Update, Remove, Program color |
| **Recording** | Timecode, folder table with default and per-camera rows, file-name pattern and preview, camera subfolders |
| **Audio** | **Channels Shown** per camera, true-peak warning level |
| **Switching** | Fixed interval, Natural talking head timing, Advanced cut decisions, Restore Defaults |
| **Alerts** | Which events notify, sound, low-space level, real notification permission state, Turn On Alerts |
| **Advanced** | Allow CPU conversion, Forget Saved LUTs, Reset |

**Leaves Settings:** Layout and New Camera Strips (neither does anything useful), Output mode, Published Cameras, Sync cameras, Strategy, Backup Recording and Dynamic Analysis placeholders, Monitor prose (to Help), Codec (to the main window), Crash Recovery (to Attention), the drive meter, Open and Copy Diagnostics (Diagnostics window). Scope refresh goes in the Scopes popover, because it's per camera.

Removing "Coming later" rows reverses the rule at `docs/ui-polish/BRIEF.md:36` and `PLAN.md:23`. That's deliberate: a promise isn't a control.

### Channels Shown

- **Scope:** per camera, because embeds differ by source. As Detected is the built-in default.
- **Values:** As Detected, 2, 4, 8, 16. Nothing is disabled, because a stopped camera has no count. A running camera reads "Showing 2 of 8".
- **As Detected** is measured, because DeckLink reports only maximums. It's the smallest tier covering the highest pair that has carried signal (true peak above −90 dBTP) while metered since capture started. It only grows. On this rig it shows 2.
- **Height:** the meter block stays 44 pt at every value, so the strip never changes. 4 and below print each pair's maximum. 8 and 16 print one line, "Highest 3–4 −5.7 dBTP", because the 8-channel readout overflows a narrow strip.
- **Hidden channels** are still metered and recorded, and an over on one still lights OVER, with its channel named in help.
- **Collapsed strips** always show channels 1-2.
- **Right-click on a meter** offers the same choice. This needs a MonitorKit input, because the meter owns its menu.

Today's reality: 8 channels are captured, recorded and metered. Loudness and Auto read channels 1-2. Virtual cameras and Program carry no audio. Channels 3-8 were silent start to finish on both 12:24 takes.

## 8. Hardware awareness

The data mostly exists in `VendorRegistry`, but `AppHardware` flattens it to IDs, names and a warning string. Idle devices have no status, "in use elsewhere" appears only after Start, and a Sony drop raises no warning.

**Settings › Hardware.** One section per vendor, in registry order, with expanding rows: health, name, assigned camera, state, link. This rig has two identical Mini Recorder 12Gs, so nicknames matter.

- **Includes absent hardware,** limited to anything a camera is assigned to, by last known name. This is this rig's real failure: a USB 3 fallback unit never appears in DeckLink, so the symptom is a saved input gone missing. A plugin hint says to check the hub. An "HDMI · USB 3" chip can't work.
- **Pairing moves here.** The assignment pop-up is the pairing control, and sign-in opens inline. Find Camera Bodies scans on request only. The Camera Control sheet keeps operating a connected body and keeps Reconnect, which also appears in Attention and the inspector.
- **Input connector, Advertise HDR and Supported Formats** live on the capture device's row. The first two can drop the signal, so ask first when the device is in use. Supported Formats uses human names, not `1001/60000 s`.
- **Setup block on each paired body.** This is the answer to "sony blackmagic configurations". Read-only facts about how the body meets the capture device: HDMI format, camera display, timecode out, audio on HDMI, picture profile. An advisory appears only when facts conflict, such as a body on S-Log3 with a camera declared Rec.709, with one action. No automatic changes, no per-model defaults. Vendor knowledge stays in the plugin.
- **Idle status** is polled every 2 s on the registry queue, only while the window or Hardware is visible, and only for devices with no Ultracam session. It never selects a connector, which would renegotiate HDMI. Device subscriptions are unproven, so none are added.
- **Sony:** read overheating and the battery's display unit, since a low-battery warning must not treat 78 minutes as 78%. Handle `OnWarning`, which is dropped today. A lost body gets a notice, and low battery or overheating raises a problem. Battery warns only when the unit is known.
- **Plugin API additions:** cached device status with an observer, typed facts and problems, device model, a missing-device hint, control property roles with severity and a suggested source profile, a notice event, and optional model and firmware on a camera body. The control snapshot, chips and action URLs are dropped as unneeded. Vendor names stay out of `Sources/App`, enforced by `scripts/check-vendor-boundaries.py`.
- **Main window:** hardware shows in the left pane, plus problems. No extra strip row. The strip's logo stops hiding Blackmagic when Sony is assigned, and the signal badge's menu names both links.
- **A build without the Sony SDK** must read as normal, with no warnings.

**Rig presets: not now.** One rig, one Mac, and everything a preset would hold persists once B1 lands.

## 9. Recording format

**Format is in the left pane's Recording section, the Record toolbar menu, the Record app menu and the menu bar.** Each strip shows its camera's format read-only, so closing the sidebar loses nothing. It applies to the next take. A rolling camera shows its take's own format, which needs a new `takeCodec`.

**One format for all cameras.** On the evidence: both paired sessions matched in codec and drive, every take over 10 minutes is HEVC, and both sources are identical. Every HQ take is under 5 minutes, so HQ looks like the launch default rather than a choice. Per-camera can be added later with no migration.

The menu shows each codec with its rate per camera for the current sources, plus time left: the shortest across drives in use, counting every camera assigned to each. A codec no current source can use is disabled. **The estimates must ship first,** or HEVC reads about 11 times too high.

If a camera's source later can't use the choice, it takes the nearest format, because a missed take can't be recovered and an unexpected codec can. That shows in orange on the strip ("ProRes 4444 → ProRes 422 HQ"), in the REC popover, the record button's help, an Attention row with its rate and time left, and the take's note. The rate must follow the codec that actually records: HEVC falling back to ProRes 4444 is roughly 50 times the data. Fallback table: 05. `record(feedID:)` needs a closure to read the source, as it doesn't know it today.

**Timecode** stays in Settings › Recording, shown as a caption in the sidebar. It's set once per rig once B1 saves it.

**Program is not recorded.** A streaming session leaves per-camera originals and a cut list, and the UI should say so. A real Program recording needs its own design, including whose audio it carries, so it stays out with no placeholder.

## 10. Conflicts settled

| Question | Reports | Decision and why |
|---|---|---|
| Format scope | 05 per camera. 02, 03 global | **Global.** Confirmed by the take evidence (validation E) |
| Timecode home | 03, 05 sidebar. C Settings | **Settings,** with a sidebar caption. Set once per rig, and two pickers don't fit a 236 pt pane |
| Channels Shown home | 05 inspector | **Settings › Audio.** Your sentence names the Settings window |
| Effect chips | 02 inspector, 06 menu | **LUT toggle plus Effects menu.** LUT is the panic control; the rest change Zoom's format |
| Stop Cameras | 02 remove, 06 keep | **Remove.** Also fixes a double-click on Start landing on Stop |
| Tool bar at rest | 02 active tools, 06 one button | **Your call: collapse at rest, keep enabled tools showing, expand on hover** |
| ⋯ menu | 02 trim, 03 remove | **Trim.** Stop Camera moves into it, and Monitor LUT moves to the Picture popover |
| Strip Cut | 02 keep, 03 remove | **Keep** in a fixed slot. Eyes are on the pictures |
| Hardware on the strip | 04 source row, 02 sidebar | **Sidebar** |
| Strategy home | 02, 03 sidebar. 06 toolbar | **Toolbar Auto menu only.** You rejected switching in the sidebar |
| Publish Program | 01 always, B at 2+ | **At 2+.** A device add is harmless, and one camera has nothing to switch |
| Show Switching Controls | 01 keep, B drop | **Drop** |
| Return to eligibility | A 3 s, C 5 s | **5 s** |
| Hold under signal loss | A stays on, C clears | **Overrides once, stays on** |
| Low-drive estimates | C phase 1, E phase 3 | **Phase 1.** A false alarm teaches you to ignore the real one |
| Background shortcuts home | 02, D Alerts. E General | **General.** It isn't an alert |
| Settings structure | 03 six, 04 Devices, E eight. 03, 06, D sidebar window | **Eight tabs,** one named Hardware. You chose tabs over the sidebar window |
| Copy Diagnostics | 03 remove | **Removed from Settings.** It's in the Diagnostics window |
| Supported Formats | 03 device, 04 inspector | **Hardware row.** A device fact |
| Pairing | 03 inspector, 04 Hardware | **Hardware.** Reconnect stays near the camera |
| Director tuning | 03 remove | **Keep** under Advanced. You said the feature set is how you want it |

## 11. Prior decisions

| Decision | Status |
|---|---|
| D1, click selects and never cuts | Holds |
| D2, format changes without prompt | Holds; those controls move off the live surface, except LUT |
| D3, Stop Camera and Stop All Cameras | Holds; placement changes |
| D4, no orange skipped ring | Holds |
| D5, ⋯ menu plus on-demand inspector | Holds; ⋯ shrinks |
| D6, backup automation rules | Holds; placeholder rows go until it's built |
| D7, selection and focus merged | **Revised.** A click or window activation no longer focuses a picture, and focus no longer selects, because it could silently move the target of ⌘R. The menu bar stops depending on selection |
| D8, time left, recent takes, director timeline, Saved, no app names | Holds; the sidebar stops repeating recording state |
| `b621bc7`, tools findable on every picture | **Revised:** the tools button and enabled tools stay at rest, and the full bar appears on hover in every state |
| Left sidebar as V1 session panel | **Revised** to the session board |
| `UI_REDESIGN.md:105,226`, output locked while running | **Overridden** |

## 12. Order of work

**These phases run in order.** The first plan's "each phase can ship alone" was wrong: the journal fix alone just moves the failure, and the tally fix alone turns tally off.

| Phase | Work | Size |
|---|---|---|
| **0. Stop losing material** | Confirm the restart clears the failed connections. Journal fix with N2, then N1, publish whole movies, failure log line, B1, B7, B8, B11, B15. Ends with a live take over 3 hours crossing a dropout | About 1 day, plus the live take |
| **1. Tell the truth live** | N3 typed signal first. Always-on demand monitor, then B5 with the new tally. Problem list, unexpected stops, B4 failover, notifications and panel, B9, B10, B12, B13, B16, B17, B18. Fixtures with 8 channels and a camera-control store, so renders finally match the app | 3 to 4 days |
| **2. ISO and Program** | In order: topology rules. Late sink with Zoom testing on today's Program path. Sinks by route with the release hold. Always-on scheduler, publish at 2+, retire the mode. GPU gate. Docs | 7 to 10 days, plus two sessions with you |
| **3. Main window** | Section 6, format control, background shortcuts, Hold for all strategies, visual language, copy pass, color system, contrast | 4 to 5 days |
| **4. Settings** | Section 7, Channels Shown, B14, scope refresh picker | 3 days |
| **5. Hardware** | Section 8, plugin API first, Setup block, B19 | 3 to 5 days |

Sizes are estimates. In phase 2, test the late-sink change against real Zoom before sinks follow demand, because that gives evidence before every ISO user depends on it.

## 13. What needs you

**Decisions made here that you may want to reverse:**

1. Signal loss overrides Hold once.
2. Program is published only with 2+ cameras.
3. Cut buttons always show with 2+ cameras, with no hide option.
4. One format for all cameras.
5. Stop Cameras leaves the toolbar while running.
6. Program recording stays out of scope.
7. Not included: starting a new take automatically after a failed one.
8. Resize, Color, Frame rate and Effects Off move into a menu, one click further away.
9. Stop Camera moves into ⋯, one click further away.

**Live checks only you can run,** with Ultracam not serving a meeting:

1. Before phase 0 ends: a take of 3 hours or more that crosses a dropout.
2. After a restart: does an Ultracam camera appear in Zoom with a real picture?
3. **Click-through:** with Zoom frontmost, does the first click on Cut or Record act, or only activate Ultracam? If it only activates, every "one click" costs two until fixed.
4. Unplug HDMI on the on-air camera, after N3.
5. Toggle the LUT with Zoom on Program and on Camera 1, and check for a visible blip.
6. Full-screen Zoom, with and without sharing the screen: notifications and panel, with Ultracam's window open and closed, and what viewers can see.
7. Zoom through the upgrade: does it need a restart to list Program, what format does it pick, and how does it react to a format change under its lease?
8. Program in Zoom plus ISO in a second app at 4K, with time to first frame.
9. Settings from the menu bar 20 times.
10. ⌃⌥⌘ shortcuts with Zoom frontmost.
10a. Native control sizes on macOS 26: the mockups were measured on 27.0.1.
11. A real FX3: which fields it reports, and whether it can embed more than two audio channels.
12. Whether the OWC hub was in the same wiring at 13:59:04 on 2026-10-30. Both units sit behind it now. It's a lead for the simultaneous drop, not a finding.
