# E. Validation: Settings, audio, recording format, hardware

Date: 2026-10-30. Reviewed `docs/ui-audit/README.md` sections 6, 7 and 8 against reports 03, 04 and 05, at commit `2c4929c`. Read-only. No build, no device opened, no `defaults`, Ultracam untouched. Take files were read with `ffprobe` and `ffmpeg -f null` only.

Labels: **[V]** Verified in code, a header or a real file. **[I]** Inferred. **[U]** Unknown. Paths are relative to the repo root; `.mm` means `Vendors/Blackmagic/Sources/DeckLinkBackend.mm`.

## Verdicts

| # | Decision | Verdict |
|---|---|---|
| S1 | Settings as a sidebar window | KEEP |
| S2 | Nine sections | REVISE: eight. Monitoring goes |
| S3 | Alerts section | REVISE: keep it, without background shortcuts |
| S4 | Program color under Switching | REVISE: move to Virtual Cameras |
| S5 | "Devices" with expanding rows | REVISE: keep the rows, name it "Hardware" |
| S6 | No Cameras section in Settings | KEEP |
| S7 | Nothing lost from 03 to README | REVISE: six gaps |
| S8 | Channels shown lives in Settings › Audio | KEEP |
| S9 | Default for new cameras | KEEP as a built-in default, no Default row |
| A1 | Channel counts by stage, 8 rows with 6 silent | KEEP |
| A2 | As Detected | REVISE: one wording fix |
| A3 | −90 dBTP signal test | KEEP |
| A4 | Fixed 44 pt block | REVISE: the block holds, the 8 and 16 readouts do not |
| A5 | Highest pair, only grows | KEEP |
| A6 | Nothing added to the capture path | KEEP |
| A7 | Loudness pair setting | DROP from this plan |
| A8 | As Detected over a plain count picker | KEEP As Detected; plain picker rejected |
| F1 | One global format | KEEP |
| F2 | Menu wording: "this drive, this source" | REVISE |
| F3 | Nearest-format fallback | REVISE: keep it, disable more, show it everywhere |
| F4 | Estimates in phase 4 | REVISE: before the control ships |
| F5 | Timecode and folder scope | KEEP |
| H1 | List of what is unused | KEEP, one Sony correction |
| H2 | Reading idle status | REVISE: reads are safe, device-wide subscription is unproven |
| H3 | Off the main thread and frame path | KEEP, with three rules |
| H4 | Plugin API additions | REVISE: smaller |
| H5 | Expected but absent hardware | REVISE: saved assignments only |
| H6 | Sony pairing moves | KEEP, Reconnect stays near the camera |
| H7 | Sony battery and overheating reads | KEEP, fix the battery unit |
| H8 | Rig presets: not now | KEEP, with a corrected reason |
| H9 | Reading of "configurations" | REVISE: add a Setup block |

## Settings

### S1. Sidebar window: KEEP

[V] Six hardcoded pane heights and a 640 pt window exist today (`Sources/App/UISettings.swift:27,110,238,370,490,679,749`). Nothing found argues against 06 section 8.

### S2. Nine sections: REVISE to eight

**Monitoring goes, because its one control is not app-wide.**

- [V] Scope refresh is stored per target in `MonitorScopePreferences.refreshHz` (`Sources/Shared/MonitorWorkspace.swift:474-478`) and read per target (`Sources/App/MonitorSurface.swift:1398,1610`, `Sources/App/MonitorCoordinator.swift:136`). 03 H11 itself says "Per camera".
- [V] A row in Settings has no camera to apply to. The Scopes popover already binds the whole struct (`Sources/App/UIScopeSettings.swift:19`), so one `Picker` belongs there beside the other scope settings.
- [I] The alternative, a global value written over every camera, invents semantics nobody asked for.

With that row gone Monitoring has no controls, so the section is removed. Its prose already goes to Help.

No other merge is justified. Audio has a per-camera table plus one level, Virtual Cameras gains a control (S4), and General stays short on purpose. 06 says the sidebar is fine up to 10 sections, so count alone forces nothing.

### S3. Alerts: REVISE

Keep it. Five event switches, sound and a low-space level are seven controls about one thing.

Remove "background shortcuts". [V] Its only source is 02 F26 and the table at `docs/ui-audit/02-live-workflows-and-panes.md:350`. README sections 4 and 5 never mention it, section 11 schedules no work for it, and [V] no global hotkey code exists (03 line 352). [I] It is also not an alert. It needs its own design and belongs in General when built.

### S4. Program color: REVISE

[V] It is an output property, read only by the Program route (03 D7, `Sources/App/AppSettingsStore.swift:357`), with three values (`Sources/App/UIInspector.swift:178-182`). Once README section 3 makes Program an always-published virtual camera, it belongs with Virtual Cameras. Switching then holds only cut behavior. [I] Migration seeds the one value from the first camera's saved `programColorSpaceID`.

### S5. Noun and shape: REVISE the noun, KEEP the rows

**Expanding rows are right.** Device rows appear and vanish with hot-plug. Child pages in the sidebar would make the saved `settings.section` selection (06 section 8) point at a device that left, and [V] a `DisclosureGroup` already works in a grouped Settings form (`Sources/App/UISettings.swift:468`). The sidebar stays fixed.

**"Cameras" (03) is wrong.** [V] Camera is the project's noun for Ultracam's channel (memory, 04 "Nouns"), and Virtual Cameras is its neighbor. A third meaning would not survive.

**"Hardware" beats "Devices".**

- It is the owner's word: "what hardware is connected". README section 7 is already titled Hardware awareness.
- Virtual cameras are devices to macOS and to Zoom, so "Devices" beside "Virtual Cameras" invites the question of why they are separate. "Hardware" does not.

Cost is one label, so decide now. Inside the section keep 04's terms: capture device, camera body.

[U] Whether a pop-up inside a `DisclosureGroup` label takes clicks without toggling the row needs a render check. Row width is tight at 580 pt, so the link column drops first and stays in the expanded row.

### S6. No Cameras section: KEEP

A channels, folder and automation table would be a third noun clash, a wide table in a 580 pt form, and a duplicate of the inspector. People look for audio channels under Audio and folders under Recording.

**Rule for the exception:** a per-camera setting gets a Settings table only when the owner compares cameras side by side and it is not needed live. Folders and Channels shown pass. Everything else stays in the inspector, so the section 5 rule is enough.

### S7. Audit of 03's Settings rows

Every row of 03 whose PRIMARY is Settings:

| 03 row | Item | README home | Status |
|---|---|---|---|
| A1, A2 | Show in, Open at login | General | Landed |
| C3 | Supported source formats | None | **Lost.** 03 says device page, 04 keeps a disclosure in the inspector and omits it from the expanded device. Put it in the expanded capture device row and remove it from the inspector |
| C10, C11 | Input connector, Advertise HDR | Devices | Landed |
| D7 | Program color | Switching | Landed; moves under S4 |
| F13, F15 | Fixed interval, shot timing | Switching | Landed |
| F16 | Advanced cut decisions | Switching › Advanced | Landed; section 9 records the reversal |
| F17 | Restore switcher defaults | Unlisted | **Omitted.** 06 places it at the bottom of its pane. Name it |
| G7, G8 | File name pattern, camera subfolders | Recording | Landed |
| G10 | Clear default folder | Implied by the folder table | Landed; 06's Path row covers it |
| G15 | Low-space warning | Alerts | Moved from 03's Recording; unrecorded |
| G21 | Allow CPU conversion | Advanced | Landed |
| H11 | Scope refresh | Monitoring | **Wrong home.** Goes to the Scopes popover (S2) |
| I4 | True-peak warning level | Audio | Moved from 03's Monitoring; unrecorded |
| E3, L6 | Forget LUTs, Reset | Advanced | Landed |
| K1, K2, K3 | Extension install, remove, approve | Virtual Cameras | Landed |
| L2 | Copy Diagnostics | Advanced | **Unrecorded reversal.** 03 removes it, the README keeps it. Follow 03: it is on the Diagnostics window (`Sources/App/UIDiagnostics.swift`, 03 L2) |

Also found:

- **J1 conflict is not in section 9.** 03 makes the inspector the home for assignment, 04 moves it. Record it (H6).
- **J4 Camera display is lost.** [V] It sits in the strip's output row (`Sources/App/UICameraColumn.swift:1041,1058-1075`). README section 5 rebuilds that row and never places it. Put it in the Effects menu: the code comment says it belongs with video and output controls, and it changes the picture.
- **Published Cameras, Open Diagnostics and the strategy picker** are absent from "Leaves Settings" though they do leave. B7's "route through send" is a phase 0 stopgap for a picker phase 4 deletes.
- **Two 05 defects missed section 2.** [V] Eight unlabelled channels get 7.1 names in the popover (`Packages/MonitorKit/Sources/MonitorKitUI/AudioMeterView.swift:285`). [V] `Sources/App/UIStatusBar.swift:368` says "48 kHz stereo" on an 8-channel source.

### S8. Channels shown in Settings: KEEP

The owner's words are "settings window ... more settings need to be put in there, like how many audio channels show". "In there" is the Settings window. 05's "the owner's sentence doesn't name the place" is wrong.

Layout at 4 cameras: four rows at about 30 pt, plus the true-peak row and a header, roughly 190 pt in a 620 pt pane [I]. One picker per row fits 580 pt comfortably.

One correction: 05 disables values above the declared count, but Settings is mostly used with cameras stopped, when no count is declared. [V] Device maxima are not in `CaptureDeviceInfo` (`Sources/DeviceAPI/CaptureSourcePlugin.swift:4-16`). So nothing is disabled: a higher value shows what exists, and a running camera's row reads "Showing 2 of 8".

The right-click item needs a MonitorKit input: [V] `LevelMeterBody` owns its own `.contextMenu` (`Packages/MonitorKit/Sources/MonitorKitUI/LevelMeterView.swift:417-419`), so [I] a host menu around it will not show.

### S9. Default for new cameras: KEEP as built in

Yes, a default exists: As Detected, as the decoded value when the key is absent. No editable Default row. As Detected already adapts, this rig has 1 to 2 cameras, and a Default row adds a "Use Default" state to every camera for no gain. It reads 2 before anything is detected, which is what the owner wants on the first run.

## Audio

### A1. Counts by stage: KEEP

| Stage | Count on this rig | Evidence |
|---|---|---|
| Capture enable | 8 | [V] Device maximum picks 2, 8 or 16 (`.mm:1312-1315,1335-1338`). Both 12:24 sidecars declare `channels: 8` |
| Recording | 8 | [V] `ffprobe`: both 12:24 takes lpcm 8 channels, 9.216 Mb/s. Takes through 10-28 are stereo |
| Live meter | 8 rows | [V] `LevelMeterSource.channelCount` reads the meter's configuration (`LevelMeterView.swift:224`), configured from the declaration (`Sources/App/CaptureController.swift:1527`, `Sources/App/AudioMeterTap.swift:248-251`) |
| Silent rows | 6 | [V] `astats` over all of both takes: channels 3 to 8 are −inf start to finish, on both cameras |
| Status peaks, Auto activity | 2 | [V] `.mm:760-761`, `peaks: [lp, rp]` at `Vendors/Blackmagic/Sources/DeckLinkCapturePlugin.swift:226`. The comment at `Sources/App/SourceAudioMeterInput.swift:36` overstates this |
| Loudness, Max TP, phase | 1-2 | [V] `SourceAudioMeterInput.swift:53-54`, `programmePair` default |
| Virtual cameras, Program, monitoring | 0 | [V] No audio stream or output API found (`Sources/CameraExtension`, search of `Sources`) |

05's claim is right: 8 rows, no row labels beyond 4 channels (`LevelMeterView.swift:490`), two readout lines (`:511`), about 78 pt against 44. [I] The look itself is unobserved. No live render exists.

### A2. As Detected: REVISE the wording

It is sound. [V] The SDK offers maxima only (`Vendors/Blackmagic/SDK/include/DeckLinkAPI.h:613-614`), no status ID reports audio present (`:700-760`), and `IDeckLinkAudioInputPacket` has only count, bytes and time (`:1499-1507`). Measuring is the only option.

"Since capture started" is slightly false. [V] Detection would sit in `watchForOvers`, which runs only while a view or take holds the meters (`AudioMeterTap.swift:255-256` `ingest` guard, `beginTake` attaches). With the window closed and no take nothing is measured. [I] Harmless, since nothing is shown then either, but the text should say so.

### A3. −90 dBTP: KEEP

- [V] Silent embedded channels here are exactly zero, so any threshold separates them.
- [V] Real signal is far above it: Camera 1 channels 1-2 have a median 1 s peak of −45.6 dB, Camera 2 −48.4 dB.
- [I] It sits at one 16-bit LSB (−90.3 dBFS). A dithered 16-bit source idles above it and counts, which is correct: that channel is routed and live. A 24-bit idle channel stays hidden until it speaks, and then appears.

Do not add a duration test. [V] Camera 1 took a full-scale event at 3:02 in channels 1-2 (two 1 s windows at 0.0 dB) and channels 3 to 8 stayed bit-exact zero through it and through the whole take. Nothing suggests transients reach empty channels.

### A4. Fixed 44 pt block: REVISE

[V] The block is 12 bars + 2 + 14 ruler + 3 + about 13 readout (`LevelMeterView.swift:182-194,484-533`). Height holds at 4, 8 and 16.

**The narrowest strip is narrower than 05 assumed.** [V] The cell is `min(byWidth, max(narrowest, byHeight))` (`Sources/App/UIMainWindow.swift:281`), so 400 is not a floor on width. At the 980 pt minimum window with a 236 pt sidebar and two cameras: (744 − 40 − 20) / 2 = 342 pt. Less 24 padding (`UICameraColumn.swift:621`), 28 gutter (`:601`) and 8 spacing leaves 282 pt of meter. Four cells are 64.5 pt each, not 79. With both side panes open the cell can reach 210 pt before a pane closes (`UIMainWindow.swift:35`), but [V] the code already says strips spill under 400 (`:152`), so that is not a meter problem.

**Eight: bars fit, the readout does not.** [I] A `1–2 −29.4` entry is about 49 pt at 10 pt and OVER needs about 41 pt. Entries aligned under four cells end at 266 pt at this width, so OVER overruns 282 by about 25 pt. It needs a meter 384 pt wide, a strip of about 444. Use the "Highest" line at 8 as well as 16. It is about 135 pt and fits every width above.

**Sixteen:** 05's "own ruler per cell" cannot hold, as two bar rows share one 14 pt ruler slot, so rulers are per column. 2.25 / 0.5 pt bars are not pixel-aligned at 1x. Use 2 / 1: 2 + 1 + 2 = 5, and 5 + 2 + 5 = 12.

[V] `LevelMeterRuler` drops crowded labels (`LevelMeterView.swift:718`), so narrow rulers degrade cleanly.

### A5. Highest pair, only grows: KEEP

Only-grows is what stops the block changing during a show. A noise-floor channel above −90 counts as signal, which is the right reading: something is connected. If unwanted, pin the count. Reset at capture start, at `Sources/App/CaptureController.swift:532-534`, with no persistence: a dead pair costs nothing until it carries signal, then appears.

### A6. Capture path: KEEP

[V] `ingest` stays one atomic load when unwatched (`AudioMeterTap.swift:255-256`). The test runs on the meter queue in `watchForOvers` (`:356,430-432`), on a snapshot it already reads per packet, never on the driver thread. Add a rule 05 omits: **the view reads the mask in the existing 100 ms loop** (`Sources/App/UIAudioMeterPanel.swift:139`), so there is no new timer. The mask lives on the tap, so a replaced meter does not clear it.

### A7. Loudness pair: DROP

Nobody asked for it, and on this rig it can only be 1-2. [V] It also does half a job: Auto activity would still read channels 1-2 (A1), so a mic on 3-4 would meter and not cut. It touches `configure`, whose guard compares only the format (`AudioMeterTap.swift:240`), plus `requestSession`, the take note and migration fallback. Do pair and Auto together when a source needs it. "2" shows channels 1-2, and collapsed strips show 1-2.

### A8. As Detected over a plain count picker: KEEP

Without detection the default must be a number. 2 hides a real mixer feed on 3-4 with no hint. 8 is today's complaint. As Detected costs an atomic `UInt16`, one comparison per channel, a tier function and a test, about 40 lines [I], on paths that exist. Keep it.

## Recording format

### F1. Global: KEEP

The overrule of 05 is correct on the evidence.

| Session | Cameras | Format | Video rate | Length | Drive |
|---|---|---|---|---|---|
| 10-19 21:09, 21:13, 22:18 | Feed 1 | HQ | 1.64-1.66 Gb/s | 34-57 s | 8TB |
| 10-19 21:26, 21:44, 22:02 | Feed 1 | HEVC | 28 Mb/s | 2-14 min | 8TB |
| 10-20 19:43 | Feed 1 | HEVC | 28 Mb/s | 101 min | 8TB |
| 10-24 21:33, 21:38 | Camera 2 | HQ | 1.63-1.67 Gb/s | 4 min, 12 s | 4TB |
| 10-25 10:10 | Camera 2 | HEVC | 55 Mb/s | 18 min | 4TB |
| 10-26 12:49 | Camera 2 | HQ | 1.58 Gb/s | 89 s | 8TB |
| **10-28 19:10** | **Both** | **HEVC, both** | 55 Mb/s | 51 s | 8TB, both |
| 10-28 20:10 | Camera 1 | HEVC | 55 Mb/s | 89 min | 8TB |
| **10-30 12:24** | **Both** | **HEVC, both** | 55 Mb/s | 19 min | 4TB, both |

[V] from `ffprobe` and sidecars (`outputContract.codec` is `hvc1`, source pixel `v210`). The Camera 2 file for 10-28 20:10 is on neither drive, so its codec is unknown.

- **Both paired sessions match in codec and drive.** n = 2, so this is suggestive, not proof.
- **Every take over 10 minutes is HEVC. Every HQ take is under 5 minutes.** [I] HQ looks like the launch default (B1), not a choice, so the real preference is one format. That also weakens 05's "uses both HQ and HEVC".
- **Both sources are identical,** 2160p 59.94 v210 (`sourceSignature` matches in both sidecars), so per-camera availability cannot differ on this rig.
- 05's "A-cam/B-cam split" and "two drives" have no take behind them.

Cost: per camera is cheap in the model, one line beside `RecordingModel.swift:867`. It is expensive in the UI: a control on each strip, Use Default, Use for All, a "2 formats" summary, a submenu in both ⋯ forms and REC popover rows. Global is one control on four surfaces. And [I] the decision is reversible: `FeedDescriptor.recordingCodec: RecordingCodec?` can be added later with `decodeIfPresent` and no migration.

[V] Safety during a take holds either way: the configuration is copied once at `RecordingModel.swift:864`.

**Add:** `RecordingFeedState.takeCodec`. [V] It does not exist (`RecordingModel.swift:119-131`) and the README's "shows its take's own format" needs it, since the strip otherwise shows the next-take value.

### F2. Menu wording: REVISE

"Its real rate and the time left on this drive, for this source" describes one camera. A global control has no single drive or source. See the replacement text.

### F3. Fallback: REVISE

**Keep falling back rather than refusing.** A missed take cannot be recovered; an unexpected codec can. That is the right rule for a backup recorder, and it applies across families too. I considered refusing when the family changes, and rejected it: a Record All with one camera quietly refused loses material, which is the failure section 1 exists to stop.

[V] The table is right against the routes (`Sources/Recording/RecordingProfileMatrix.swift:122-144`, `requires422` at `:48-50`, `Sources/Shared/SourceFormat.swift:165-177`). [I] HEVC Main 10 has no reachable route, so it should never be offered.

The surprise is real in three places:

1. **The biggest jump.** HEVC 4:2:2 on an RGB source becomes ProRes 4444: [I] about 55 Mb/s to about 2.7 Gb/s at UHD 59.94, so 4 TB lasts about 3.3 hours. The rate and time left must follow the codec that will actually record.
2. **The strip is not always there.** [V] Four Up and Program View force collapsed strips (`Sources/App/UIPresentation.swift:672`), which have no format line, and the menu bar has no strip at all. "Shown in orange on its strip" misses those.
3. **Choices that can never work are offered.** On this rig 4444 would fall back on every camera, every time. Disable a codec no current source can use, so fallback fires only for a mixed rig or a source that changes later. With identical v210 sources it never fires here.

**Correction to 05:** [V] `record(feedID:)` does not know the source. `RecordingModel` has no source format, and validation happens later off the main actor (`Sources/Recording/SourceRecording.swift:334`). Resolve from `AppModel.liveCameraUpdate(id)?.sourceFormat` (`Sources/App/AppModel.swift:1480`) through a closure given to the model, then set `take.codec` and `takeCodec`. [V] The sidecar already records the real codec in `outputContract.codec`.

### F4. Estimates: REVISE, before the control ships

The README puts the menu in phase 3 and B9, B10 in phase 4. The menu's purpose is an informed HQ against HEVC choice, and it would show HEVC at 597 Mb/s against a measured 55: [V] all six HEVC takes since 10-25 measure between 55.05 and 55.19 Mb/s, and [V] the table gives 0.15 bytes per pixel (`Sources/Recording/RecordingSizeEstimator.swift:18`). B9 and B10 must land with or before it.

Three corrections to 05's plan:

- **Do not change line 18.** [V] The free-space guard reads the same estimator (`SourceRecording.swift:260,726,1284`), and a test pins the ratio (`Tests/RecordingSizeEstimatorChecks.swift:17`). Override HEVC 4:2:2 in the UI path only, `UIRecordingLibrary.nominalMegabits` (`Sources/App/UISupport.swift:15-17`), which keeps 05's promise that the guard stays cautious.
- **Use 0.014, not 0.015.** 55.1 Mb/s over 497 Mpx/s is 0.0139 bytes per pixel.
- **Drop 05's saved-rate tier.** [V] HEVC varied 0.3% across takes and content, so a corrected constant plus the live measured rate is enough. One caution: [V] rates were 28 Mb/s before 10-25 and 55 after, so an encoder change moves this figure. [U] Why it changed. [V] No bitrate key is set (grep of `Sources/Recording`).

Add PCM. [V] 8 channels are 9.2 Mb/s, 17% of a HEVC take, and uncounted today.

ProRes needs nothing: HQ's estimate of 1,766 Mb/s against 1,583-1,671 measured is usefully cautious.

### F5. Timecode and folder: KEEP

Timecode stays global so cameras stay comparable, and folder stays default plus override. Both are the right model and need no change. The Timecode picker's prominence is only safe after the journal fix, which phase 0 already puts first.

## Hardware

### H1. List of unused features: KEEP

[V] All 04's DeckLink identifiers exist at the cited header lines: `BMDDeckLinkModelName` :658, `VendorName` :656, `DeviceInterface` :629, values :422-424, PCIe :719-720, Busy :724, flags :813-815, FRL :728, reference :584, :740, temperature :685, serial and label `DeckLinkAPIConfiguration.h:231-232`. [V] The backend has no use of ModelName, VendorName, DeviceInterface, PCIExpress or DeviceInformation. [V] No header mentions firmware.

[V] Sony: `Movie_File_Format` :80, `ResolutionForMain` :127, `MovieShootingMode` :132, `LogShootingMode` :584, `PictureProfile_Gamma` :220, media slots :675-677, overheating :766, `SoftwareVersion` :750, and warnings `CrError.h:188-196`. `OnWarning` is not overridden (`Vendors/Sony/Sources/SonyCameraControl.mm:355-392`).

**Correction.** [V] The bridge prints `BatteryRemain` as a percentage (`SonyCameraControl.mm:168`), but a unit property exists (`CrDeviceProperty_BatteryRemainDisplayUnit`, `CrDeviceProperty.h:130`, values minute, percent, voltage at `:2231-2235`). See H7.

**Missed by 04's summary, and relevant to the owner:** `Movie_HDMIOutputAudioCH` :282 (values CH1CH2, CH3CH4 at the `CrHDMIOutputAudioCH` enum). See H9.

### H2. Idle status: REVISE

**Reads are safe.** [V] Production code already reads `bmdDeckLinkStatusBusy` from a device another app may own, specifically to avoid touching it: "refuse before touching it" (`.mm:2288-2295`, also `:1585-1588,1804-1807`). [V] Detected-mode reads before enable exist too (`.mm:1947-1956`). [V] While Ultracam owns a device, the same interfaces are read on the control queue at 1 Hz and on notifications (`.mm:2622-2640`, `:2600-2604`). [V] `diagnose-capture.py` reads all of this with no input enabled.

The hazard is the opposite: writes. Selecting a connector or EDID renegotiates HDMI (`.mm:2290-2292`). A status reader must never call `HDMILease::select`.

**04's subscription is the unproven part.** [V] `bmdStatusChanged` is subscribed only during a session (`.mm:2416,2544`). [U] Whether a second subscriber on a device is supported, or how often it fires while another app captures. The SDK manual is not in the repo.

**Decide: poll, on demand.** Every 2 s on the registry queue, while the main window or the Hardware section is visible, reading only devices with no Ultracam session. Sessions already publish their stats. It needs no new SDK callback, and it stops when nobody is looking. 2 s is quick enough for the pull-a-cable test in 04. Subscribe later only if a live check shows it is safe.

[U] Whether lock and detected mode update with no input enabled (04 open item 2). Check `scripts/diagnose-capture.py devices` once, outside a meeting. If they do not, show "Unknown" while idle and never "No signal".

### H3. Threads: KEEP, with three rules

[V] Design is right: a background reader with a cache, and the UI rule at `Sources/App/UIDiagnostics.swift:243-244` holds. [V] `mutex` is not on the frame path: registry calls occur only at start and stop (`.mm:2270-2414,2648`).

1. SDK calls run on the registry's serial queue (`.mm:1372`), which also serializes device removal (`:1421-1425`), so device pointers stay valid.
2. Never hold `mutex` across an SDK call: copy pointers under it, read outside. `diagnostics()` takes that lock on the UI's behalf (`.mm:1656`).
3. Keep status apart from the device list, as 04 says. [V] `applyDevices` re-runs settings restore (`Sources/App/AppModel.swift:520-523`).

### H4. Plugin API: REVISE

The README's five items contain two that are not needed, and 04's detail carries more.

**Drop:**

- **`VendorRegistrySnapshot.control` / control vendor snapshot.** [V] `CameraControlStore` already exposes `descriptors`, `cameras`, `assignments` and per-camera state (`Sources/App/CameraControlStore.swift:71-72,104,117-121`). The pane can read the store.
- **`ControlTelemetryKind` as a new type.** [V] `ControlPropertyRole` is already the semantic tag (`Sources/DeviceAPI/CameraControlTypes.swift:72`). Add cases `power, thermal, media, colorProfile`. Nothing persists it (`docs/SONY_CONTROL.md`, "No camera values are saved").
- **`DeviceChip`.** Its stated use is the source row, which the README rejected.
- **`unusableHardware()`.** Its only consumer is a USB probe 04 itself calls an optional spike.
- **`DriverStatus.actionTitle/actionURL`, `deviceNoun`, `unavailableInBuildText`,** and removing `DeviceDiagnostics.vendorFields`: none is needed for Hardware to work. Revisit each when a screen needs it.

**Keep, in full:**

```swift
// CaptureSourcePlugin, both with nil defaults
func status(deviceID: String) -> CaptureDeviceStatus?          // cached, never calls the driver
@MainActor func observeStatus(_ handler: ...) -> DeviceObservation?

struct CaptureDeviceStatus { availability; signalLocked: Bool?; detected: SourceFormat?;
                             link: DeviceLinkKind; facts: [DeviceFact]; problems: [DeviceProblem] }
// plus DeviceFact, DeviceProblem, DeviceSeverity, DeviceAvailability, DeviceLinkKind
// Temperature is a fact.

CaptureDeviceInfo.model: String?
VendorDescriptor.missingDeviceHint / missingDeviceHintKey
ControlPropertyRole: + power, thermal, media, colorProfile
ControlProperty.severity: DeviceSeverity?
ControlProperty.suggestedSourceProfileID: String?              // H9
ControlEvent.notice(feedID:generation:message:severity:)        // OnWarning
ControlCamera.model: String?, firmware: String?                 // optional, as 04 explains
```

[V] 04's warning stands: `ControlCamera` additions must be optional, as the blob uses synthesized `Codable`.

### H5. Expected but absent: REVISE

Worth it, and nearly free. [V] It is this rig's known failure: a USB 3 fallback unit is never listed (memory), so the symptom is a saved input gone missing.

But limit it to **hardware a camera is assigned to**: `FeedDescriptor.selectedDevice` and saved control assignments. Both exist. The only new storage is the last-seen name, beside the nickname, and 04's Phase 0 already adds it. 04's sample row "UltraStudio · 0AB8, None, Last seen today" needs a history of every device ever seen, for no decision.

### H6. Sony pairing moves: KEEP

By the placement rule pairing is per rig, and [V] the sheet starts from a camera and has no view of the rig (`Sources/App/UICameraControl.swift:125-183`). [V] `connect(camera:to:)` needs no change. It is a view extraction, about 70 lines.

Three conditions:

1. **The sheet keeps Reconnect.** A body dropping mid-show must not send anyone to Settings. Reconnect uses saved credentials and has no sign-in step. It appears in the Attention row and inspector too.
2. **Scan on the button only.** [V] Opening the sheet scans today (`UICameraControl.swift:86`). Opening Settings must not, since discovery does UDP and fingerprint work.
3. **Deep link.** The inspector's Assign Camera Body opens Hardware with the row expanded, using 06's root receiver.

Record 03 J1 against 04 in section 9.

### H7. Sony reads: KEEP

[V] There is no cadence to add. Reads are change-driven, coalesced to one per 500 ms per camera (`docs/SONY_CONTROL.md`, Activity and threading). `GetDeviceProperties` copies a local list, and all SDK work runs on one dedicated thread (`SonyCameraControl.mm:523`). `BatteryRemain` is already read (`:60`).

Rules:

- **Battery unit.** Read `BatteryRemainDisplayUnit` too. A low-battery warning must not treat 78 minutes as 78%. [U] What an FX3 reports. Until checked on a body, print the unit it gives and raise no threshold warning unless it is percent.
- **Overheating is safe to add.** [V] Three states at `CrDeviceProperty.h:2831-2836`, so it maps to severity directly and changes rarely.
- **Exclude ticking fields.** [V] Adding to `sonyFields` subscribes to change refresh (`SonyCameraControl.mm:386-392`). Filter `MediaSLOT*_RemainingTime` in `OnPropertyChangedCodes`, as focus fields are.
- [U] Which fields an FX3 returns. [V] The bridge omits unsupported ones (`SonyCameraControl.mm:605`), so a gap reads as absent, never wrong.

### H8. Rig presets: KEEP "not now"

[V] 04's table holds: everything a preset would store persists (`Sources/App/CameraControlStore.swift:9-12`, `Sources/DeviceAPI/VendorSettingsPolicy.swift:5-9`, `FeedDescriptor`). One rig, one Mac.

But "Everything a preset would hold already persists" answers only one reading of the owner's phrase, and not the likelier one. Replace the line (H9).

### H9. "sony blackmagic configurations": REVISE

**Best reading.** [I] The owner means **how each vendor's hardware is set up**, and how the two meet: the FX3 feeding the UltraStudio. The clause sits in a list with "what hardware is connected", after a sentence about putting more settings in the Settings window. It is about awareness of vendor-specific setup, not saving and recalling snapshots. "Presets" is the less likely reading.

The README covers the Blackmagic half (connector, HDR) and nothing on the Sony half. **04's Phase 3 cross-checks did not reach section 7 at all**, and they are the closest thing to the answer.

**What the chain looks like, and what is unread:**

| Link | Property | State |
|---|---|---|
| Body HDMI format | `Movie_HDMIOutputResolution`, `Movie_HDMIOutput4KSetting` | [V] Read, in sheet and badge menu |
| Body OSD on HDMI | `MonitoringOutputDisplayHDMI` | [V] Read and writable, on the strip today |
| Body HDMI timecode | `Movie_HDMIOutputTimeCode` :278 | [V] Header only, unread |
| Body HDMI audio routing | `Movie_HDMIOutputAudioCH` :282 | [V] Header only, unread |
| Body picture | `PictureProfile_Gamma` :220, `LogShootingMode` :584, `MovieShootingMode` :132 | [V] Header only, unread |
| Ultracam's declaration | `sourceProfileID`, LUT spaces | [V] Per camera, set by hand |
| Capture side | Detected format, connector, EDID | [V] Known |

Why it matters here: [V] both 12:24 sidecars say Rec.709, which is the HDMI tags. [U] Whether those FX3s were on S-Log3. An S-Log3 body with an undeclared profile gives wrong false color, and nothing warns today. [I] Timecode is similar: HDMI timecode from the body is what took the journal to 19 minutes.

**Do this: a Setup block on each paired body's expanded row.** Read-only facts, compared with the capture side, with an advisory line only on an objective mismatch:

```
Setup
  HDMI output     2160p 59.94 · 10-bit           matches UltraStudio
  Camera display  On                             Camera menus show in the picture  [Turn Off]
  Timecode out    On
  Audio on HDMI   CH1/CH2
  Picture         S-Log3 · S-Gamut3.Cine         Camera 1 is declared Rec.709  [Use S-Log3]
```

Rules:

- **Advisory only, never automatic.** [V] `SourceColorSpaceCatalog.swift:3` says "Neither LUT names nor camera names select a space". [Use S-Log3] is the user declaring it, on evidence read from the body, which respects that rule.
- **No per-model defaults and no recommended-settings table.** What is "right" depends on the shoot. Only compare facts that can conflict: body HDMI format against detected input, body gamma against declared profile, Source timecode against body timecode off.
- **Vendor knowledge stays in the plugin.** It sets `suggestedSourceProfileID` to a catalog ID, and the host renders it. `scripts/check-vendor-boundaries.py` stays clean.
- **Writes** are limited to properties already writable through `ControlProperty`.
- [I] `Movie_HDMIOutputAudioCH` suggests the body embeds a chosen pair, which fits channels 3 to 8 being silent. Show it. [U] Whether an FX3 can embed more.
- [U] Every field needs a live FX3 check (README section 12 item 5 already covers this).

This goes in phase 5 with Sony fields, not after. It answers the owner's phrase and needs only reads.

## Exact README changes

**Section 6 table:**

```
| **General** | Show Ultracam in, Open at login, Ask before ending a recording or on-air video |
| **Hardware** | Every capture device and camera body, grouped by vendor (section 7) |
| **Virtual Cameras** | Extension status, Install, Update, Remove, Program color |
| **Recording** | Folder table with default and per-camera rows, file-name pattern and preview, camera subfolders |
| **Audio** | **Channels shown** per camera, true-peak warning level |
| **Switching** | Fixed interval, Natural talking head timing, Advanced cut decisions, Restore Defaults |
| **Alerts** | Which events notify, sound, low-space level |
| **Advanced** | Allow CPU conversion, Forget Saved LUTs, Reset |
```

**Leaves Settings, add:** Published Cameras, the drive meter (left pane, 03 G14), Open and Copy Diagnostics (Diagnostics window), Strategy (toolbar). Scope refresh is added to the Scopes popover, per camera, not to Settings.

**Channels shown, replace the paragraph:**

> **Channels shown.** Per camera, because embeds differ by source. It is a per-camera table in Settings › Audio, like the Recording folder table, because you asked for it there and it is set once per rig. That makes it one of two exceptions to the inspector rule in section 5: a setting gets a table only when cameras are compared side by side and it isn't needed live. Values: As Detected (the default for every camera), 2, 4, 8, 16. Nothing is disabled, because a stopped camera has no count; a running camera's row reads "Showing 2 of 8". As Detected is measured, because DeckLink reports only maximums: it means the smallest of 2, 4, 8 or 16 that covers the highest pair that has carried signal while metered since capture started. Signal is a true peak above −90 dBTP. It only grows, and starts over with each capture. The meter block stays 44 pt tall at every value, so strip height never changes. 4 and below print each pair's maximum; 8 and 16 print one line, "Highest 3–4 −5.7 dBTP". Hidden channels are still metered and recorded, and an over on a hidden channel still lights OVER. Collapsed strips always show channels 1-2. The right-click menu on a meter offers the same choice.

**Section 7, rename Settings › Devices to Settings › Hardware throughout, and replace these bullets:**

> - **Includes expected hardware that is absent:** anything a camera is assigned to, by last known name.
> - **Pairing moves here.** The assignment pop-up is the pairing control, and sign-in opens inline. Find Camera Bodies scans on request only. The Camera Control sheet keeps operating a connected body, and keeps Reconnect, which also appears in Attention and the inspector.
> - **Input connector, Advertise HDR and Supported formats** live on the capture device's row. These can drop the signal, so ask first when the device is in use.
> - **Setup block on each paired body.** Read-only facts about how the body meets the capture device: HDMI format, camera display, timecode out, audio on HDMI, picture profile. An advisory appears only when facts conflict, such as a body on S-Log3 with a camera declared Rec.709, with one action. No automatic changes, no per-model defaults.
> - **Plugin API additions:** cached device status with an observer, typed facts and problems, device model, a missing-device hint, control property roles with severity and a suggested source profile, a notice event, and optional model and firmware on a camera body. Vendor names stay out of `Sources/App`, which `scripts/check-vendor-boundaries.py` enforces.
> - **Idle status is polled every 2 s on the registry queue, only while the window or Hardware is visible, only for devices with no Ultracam session.** It never selects a connector.
> - **Rig presets: not now.** "Configurations" is read as how each vendor's hardware is set up, which the Setup block covers. A saved preset earns its keep only with a second rig on this Mac, and everything one would hold already persists.

**Section 5, Strip:** add "Camera display moves into the Effects menu."

**Section 8, replace the second paragraph:**

> The menu shows each codec with its rate per camera for the current sources, plus the time left: the shortest across the drives in use, counting every camera assigned to each. A codec no current source can use is disabled. A camera whose source later can't use the choice takes the nearest format, because a missed take can't be recovered and an unexpected codec can. It shows in orange on the strip ("ProRes 4444 → ProRes 422 HQ"), in the REC popover, in the record button's help, as an Attention row with its rate and time left, and in the take's note. Fallback table: 05.

**Section 9, replace the Settings structure row:**

```
| Settings structure | 03 six panes. 04 Devices tab | **Eight sidebar sections.** 03's and 06's sidebar with 04's section, named Hardware. Monitoring is removed: scope refresh is per camera and moves to the Scopes popover |
```

**Section 9, add rows:**

```
| Supported formats home | 03 device page. 04 inspector | **Hardware row.** A device fact, not a camera setting |
| Pairing home | 03 inspector. 04 Devices | **Hardware.** Per rig, and the sheet has no view of the rig. Reconnect stays near the camera |
| Copy Diagnostics | 03 remove. README kept it | **Removed from Settings.** It is on the Diagnostics window |
| Low-space and true-peak homes | 03 Recording and Monitoring | **Alerts and Audio.** Each sits with its topic |
```

**Section 11:** phase 3 gains B9 and B10, listed first. Phase 4 loses them and gains the Scopes refresh picker. Phase 5 gains the Setup block. B7 is marked as a stopgap until phase 4.

## Outside the brief

[V] The two 12:24 sidecars and `.partial` files now have an 18:59 modification time and read `finished: true` with the journal-full `finalError`. 05 recorded `finished: false`. No `.mov` exists in `Camera 1`. [U] What wrote them at 18:59. Check before relying on README section 1's recovery note.
