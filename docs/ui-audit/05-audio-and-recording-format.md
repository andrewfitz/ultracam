# UI audit 05: audio channels and recording format

Audited 2026-10-30 against `main` at 30c8d73, and against the running app (build 39, started 12:20) through read-only evidence: unified log, `ffprobe`/`ffmpeg` on take files, and the take sidecars. No code changed, no build run, Ultracam not touched.

Evidence tags: **[V]** verified in code or on a real file. **[I]** inferred. Heights and layer counts are computed from the constants in the code, not measured on screen.

## Urgent, outside the brief: takes are failing at about 19 minutes

**Both takes from today's 12:24 session stopped at 12:43 and were never finalized.**

- [V] `/Volumes/4TB Cam B/Camera 1` and `/Camera 2` each hold a `.partial` of about 9.16 GB, last written 12:43, with `finished: false` in the sidecar. Capture kept running afterwards (the log shows frames delivered past 12:44).
- [V] Each journal is 16,777,011 bytes against a 16 MiB cap (`RecordingTakeSidecar.swift:199`, `AVAssetSourceRecordingWriter.swift:300`). Camera 1's has 68,245 lines, all `nativeTimecode`, one per frame.
- [V] Camera 1's partial runs 1,131 s by `ffprobe`. 68,245 frames at 59.94 is 18 m 58 s.
- [V] The cause in code: `AVAssetSourceRecordingWriter.swift:725-727` journals every frame's native label when `sourceNativeTrackExpected == false`, which is any timecode mode except Source (`:724`). That line reached this form in dcb58e1 (2026-10-29). Earlier takes ran 89 minutes.
- [V] When the journal is full, `append` throws `journalFull` (`RecordingTakeSidecar.swift:225`). The writer queue's catch sets the take to `.failed` (`SourceRecording.swift:1119-1135`).
- [I] So with Mac Clock or Record Start, a source that carries timecode fails at about 19 minutes at 59.94, or 38 minutes at 29.97. Mac Clock is the default, and the default returns on every launch (see B2). No log line confirms the failure itself; the journal, the sidecar and the code all agree.

Fix before anything below. Journal a label only when it breaks the run from the previous frame, as line 703-709 already does for source timecode. The two 12:24 takes should be recoverable through Recover Interrupted Takes; do not delete the `.partial` files.

## Part A: audio channels

### What the owner is probably seeing

**The screenshots are misleading here.** Every fixture feeds two status peaks, so they show L and R (`UIAudioMeterPanel.swift:149`, `:118`). The live app does not.

- [V] Each UltraStudio reports 8 HDMI channels (log, "device maximum 8 channels", 11:23 today).
- [V] Since dcb58e1 (2026-10-29 11:50) capture enables the whole group, and the live meter takes its channel count from that declaration (`CaptureController.swift:1527`, `:1569`, `AudioMeterTap.swift:248-251`, `LevelMeterView.swift:224`).
- [V] Today's take has an 8-channel PCM track. `astats` at 5:00 for 20 s: channels 1 and 2 peak at −29.4 dB, **channels 3 to 8 are digital silence**.
- [I] So the live strip shows eight 3 pt rows with no row labels, six of them permanently empty, and is about 34 pt taller than the screenshots. I could not screenshot the live app. This is almost certainly the origin of "how many audio channels show".

### Channel counts by stage

| Stage | Channels | Where | Notes |
|---|---|---|---|
| Device limit | HDMI 8 on this rig (log). SDI uses the separate SDI maximum | `DeckLinkBackend.mm:1334-1338` | |
| Capture enable | 2, 8 or 16, by device and connector | `DeckLinkBackend.mm:1312-1315`, `:1200`, `:2376` | A hardware group, not what the signal carries |
| Raw packet | All declared | `DeckLinkBackend.mm:784-808`, `DeckLinkCapturePlugin.swift:286-290` | Copied twice, see Cost |
| Status peaks and RMS | **First 2 only** | `DeckLinkBackend.mm:760-761`, `DeckLinkCapturePlugin.swift:219-226`, `UIPresentation.swift:67-70` | Feeds `UIAudioLevels`, the fallback meter and auto-switcher activity |
| Declared format | Negotiated count, 48 kHz, int32, interleaved, no labels | `DeckLinkCapturePlugin.swift:74-81` | `AudioChannelMap()` is empty |
| Live meter | All declared, up to 16 | `AudioMeterTap.swift:248-251`, `MonitorKitAudio.swift:18` | Packet refused if its count differs from the meter's (`:391`) |
| Take meter | All declared | `AudioMeterTap.swift:629-649` | Runs from take start whether or not a view is open |
| Loudness, Max TP, phase | **Channels 1-2** | `SourceAudioMeterInput.swift:53-54`, `AudioMeterConfiguration.swift:231`, `:345` | `first:` exists but no caller sets it |
| Overs | All declared | `AudioMeterTapDisplay.swift:12`, `:33`, `MeterDisplay.swift:251` | |
| Recording | All declared, one track, 24-bit PCM, discrete layout | `AVAssetSourceRecordingWriter.swift:1957-1958`, `PairedPCMRecording.swift`, `SourcePCMWriterSettings.swift:30-31` | |
| Virtual camera | None | `Sources/CameraExtension` has no audio stream | `CameraProvider.swift:662` is only a transport-type constant |
| Program | None | No audio in `ProgramOutputRoute`, `ProgramOutputBridge`, `CameraSink` | |
| Local monitoring | None | No audio output API in `Sources` | |

**Recorded but not metered? Dropped?** Neither, since dcb58e1. Every channel captured is recorded and metered. [V] Every finished take I sampled, the latest from 10-28, is stereo by `ffprobe`, so channels beyond the first pair were dropped until that commit. The same commit introduced the journal failure above.

**Side effect the owner should know.** [V] Takes now carry an 8-channel track where six are silent. That is 9.2 Mb/s of PCM instead of 2.3, about 3 GB more per hour per camera, which is roughly 13% on a 55 Mb/s HEVC take. [I] Editors will import eight channels. This audit does not change it, because "channels shown" is a display setting, and recording every embedded channel is the right default for a backup recorder.

### Where stereo is still hardcoded

| Assumption | Where | Effect in shipping |
|---|---|---|
| `EmbeddedAudioFormat.channelCount = 2` | `EmbeddedAudioRecording.swift:28` | Default meter before the declaration arrives (`AudioMeterTap.swift:68-76`). Writer fallback with no take context (`AVAssetSourceRecordingWriter.swift:1959`) |
| Stereo guards and cached format | `EmbeddedAudioRecording.swift:151`, `:238`, `:277`, `:348-356` | Test path only. Shipping recording goes through `sourceAudioWithAdmission`; `receiveRawAudio` is called only under `ULTRACAM_TEST_SUPPORT` (`CaptureController.swift:643-672`, `:1744`) |
| L and R peaks | `DeckLinkBackend.mm:760`, `UIPresentation.swift:69` | Auto-switcher activity sees channels 1-2 only on DeckLink, despite the comment at `SourceAudioMeterInput.swift:36` |
| Two silent channels placeholder | `UIAudioMeterPanel.swift:118` | The strip starts at 2 rows and jumps to 8 when the declaration lands |
| "48 kHz stereo from each input" | `UIStatusBar.swift:368` | **False today**: the source is 8 channels |
| 7.1 names at 8 channels | `AudioMeterView.swift:285` | The popover labels unlabelled discrete channels L R C LFE Lss Rss Lrs Rrs, which contradicts `SourceAudioMeterInput.swift:45-47` ("never infer a surround order from channel count"). The strip numbers them 1 to 8 (`LevelMeterView.swift:103`), so the two views disagree |
| Error text says "stereo" | `AVAssetSourceRecordingWriter.swift:1610` | Cosmetic |

These are not stereo assumptions: `audioMeterMaximumChannelCount` is 16, `OverWatch.channels` is 16, `snapshot.channels` holds 16, and the meter views accept 16.

Related: [V] the audio re-sync path is in the same test-only branch (`noteAudioResync` has one caller, `SourceRecordingAdapter.swift:314`), so the "audio re-synced" take note appears unreachable in shipping. Worth a separate check.

### What each surface shows now

| Surface | 2 ch | 8 ch (today) | 16 ch |
|---|---|---|---|
| Strip | L/R rows, 44 pt block | 8 unlabelled rows, 2 readout lines, about 78 pt | 16 rows, 4 readout lines, about 140 pt |
| Collapsed strip, menu bar, Program overlay | 7.5 pt | 17.25 pt | 35.25 pt, taller than the 24 pt record button, so [I] the row grows |
| Audio popover (312 pt inner) | L R | About 323 pt minimum, slightly over, with wrong 7.1 labels | About 435 pt minimum, [I] overflows |
| Diagnostics | Strip meter | Same | Same |

Strip heights (`LevelMeterView.swift:182-194`, `:484-533`): the block height depends on the declared channel count. So it changes between stopped and live, and at the first declaration, and two cameras can differ. There is no setting anywhere for any of this. Overs on any channel light OVER and count in the take note, while the note's Max TP is the programme pair only.

### Spec: Channels shown

**Scope: per camera, saved with the camera.** Embeds differ by source: a camera with 2 active channels beside a mixer feed with ISOs is the normal case. It sits with `recordingConstantFrameRate` in `FeedDescriptor`, and Sync Cameras leaves it alone, like folders.

**Values: As detected (default), 2, 4, 8, 16.** Values above the declared count are disabled.

- **As detected cannot mean "what the signal carries" as reported by the device.** [V] The DeckLink SDK exposes maximums only (`DeckLinkAPI.h:613-614`) and no status for channels present. So "As detected" is measured: the smallest tier of 2, 4, 8 or 16 that covers the highest pair that has carried signal (true peak above −90 dBTP) since this capture started. It only grows, so a muted mic never removes its bars. It resets when the capture restarts. On today's rig it shows 2.
- **2** shows the loudness pair. **4** and **8** show the first pairs, and the last pair is replaced by the loudness pair if that lies outside them.

**Loudness pair: per camera, default 1-2.** Offered as 1-2, 3-4 and so on up to the declared count. It drives loudness, Max TP, PLR and phase together, because `correlationChannels` and `programmeChannelMask` both read the layout. It is disabled, showing "From source layout", when a source declares labels. A saved pair beyond the declared count falls back to 1-2 with a note, since `programmePair` would otherwise produce a layout the meter rejects.

Changing the pair replaces the live meter through the existing `requestSession` path, on the main thread, so loudness starts over. **A running take keeps the pair it started with**, and the take's note names its pair.

**Meter layout: one fixed block at every value.** The block stays at today's 44 pt (12 bars, 2, 14 ruler, 3, 13 readout), so the strip height never changes with channels, detection or state. Pairs sit in cells side by side, not stacked.

| Shown | Cells | Bar / gap | Readout line |
|---|---|---|---|
| 2 | 1 | 5 / 2 (identical to today) | `L −5.7  R −6.4 dBTP` |
| 4 | 2 in a row | 5 / 2 | `1–2 −5.7  3–4 −∞`, the pair's higher value |
| 8 | 4 in a row | 5 / 2 | Four entries aligned under the cells |
| 16 | 4 cells, 2 rows | 2.25 / 0.5, 2 between rows | `Highest 9–10 −3.2 dBTP` |

- Cell gap 8 pt. Each cell has its own ruler, and `LevelMeterRuler` already drops crowded labels.
- At the narrowest strip each of the 4 cells is about 79 pt wide.
- The loudness pair's label is primary colour and the rest secondary.
- OVER stays right. An over on a hidden channel still lights it, and its help names the channel ("Over on channel 7, not shown").
- Stopped, no-audio and placeholder states use the same block, so nothing jumps at start.
- Numbers 1 to n everywhere unless the source declares labels.

**Collapsed strip, menu bar and Program overlay:** always two rows, the loudness pair, with the over dot covering every channel. Fixed at 7.5 pt. The tooltip and VoiceOver keep the summary, which reads every declared channel.

**Audio popover:** the same channels, and a compact "Channels" and "Loudness pair" picker under each camera's name. Width 340 for up to 4 shown, 460 for 8 or 16. **Diagnostics:** always every declared channel, plus "Declared 8 · shown 2 · signal on 1–2".

**Where the setting lives:** Inspector, a new Audio section. Also the meter's context menu and the audio popover, so it is one click from what it changes. I read "put in there" as the camera's settings; the owner's sentence doesn't name the place.

**Cost**

- Capture path: **nothing added, nothing changed.** `ingest` keeps its one atomic load when no view is attached. DeckLink stays at 2/8/16.
- Meter queue: one per-channel comparison per packet, on the snapshot `watchForOvers` already reads, to keep an atomic `UInt16` signal mask. Hidden channels are still metered, because overs and the take's numbers depend on it.
- Display: rendering stays on the existing Core Animation layer pool (`MeterLayers`), with no SwiftUI per frame. Hidden channels get no layers: 2 rows take about 12 layers against about 45 for today's 8.
- Existing, not changed: each packet is copied twice before the meter (`DeckLinkBackend.mm:802`, then the byte-wise `Data($0.map { $0 })` at `CaptureAudioPacket.swift:24`). That cost grew fourfold with 8 channels. It deserves its own fix, as the second copy looks avoidable.

**Exact changes**

1. `AppSettingsStore.swift`: `FeedDescriptor.audioChannelsShown` and `audioLoudnessPair`, decoded with `decodeIfPresent`, added to the key lists at `:362` and `:369`.
2. `UIAction.swift`, `UISessionBridge.swift`, `UIPresentation.swift`: two actions and the snapshot fields, on the `recordingConstantFrameRate` pattern.
3. `SourceAudioMeterInput.swift:49`: `loudnessChannels(for:first:)`.
4. `AudioMeterTap.swift`: pair argument on `configure` and `configuration(for:take:)`, `setProgrammePair`, signal mask in `watchForOvers`, cleared at capture start. Note the guard at `:240` compares only the format, so a pair change needs its own path.
5. `AudioTakeSummary.note`: names the pair.
6. MonitorKit `LevelMeterView`, `AudioMeterView`: a `shownChannels` input, cell layout and a slice case on `LevelMeterChannels` so frames stay allocation-free. `rows`/`rowsHeight` become fixed for `.strip` and `.compact`.
7. `UIAudioMeterPanel.swift`: pass the set and explicit labels, and use the fixed block for the placeholder. The explicit labels fix the 7.1 mislabel.
8. `UIInspector.swift`, `UIStatusBar.swift`: pickers, popover width, and replace the line at `:368` with the declared count.
9. Fixtures and ui-verify: add 8-channel (2 active) and 16-channel strips. **Today nothing renders more than 2**, which is how this went unseen.

Later, separate change: point the two channels read at `DeckLinkBackend.mm:760` at the loudness pair, so auto-switching follows a mic on 3-4. Same work, different offset.

## Part B: recording format

### B1. Codecs and availability

[V] Seven options (`RecordingModel.swift:8-10`, names at `RecordingProfileMatrix.swift:55-64`): ProRes 422 LT, 422, 422 HQ, 4444, HEVC Main, HEVC Main 10, HEVC Main 10 4:2:2. **There is no ProRes Proxy.** I'm leaving it out of this change; nobody asked and LT covers the small-file ProRes case. `ProRes422Profile.swift` is a separate older two-case enum that the UI doesn't use.

Availability comes from the source pixel format, by `RecordingProfileMatrix.repackRoute` (`:122-144`):

| Source | Available |
|---|---|
| v210 (both cameras today, from the sidecar), 2vuy, yuvs, UYVA, P216, PA16 | LT, 422, HQ, HEVC 4:2:2 |
| 420v, 420f, I420 | HEVC Main |
| BGRA, RGBA, r210, R12L | ProRes 4444 |

[I] HEVC Main 10 has no reachable route, as its native x420 isn't in the visible pixel table at `SourceFormat.swift:165-177`. On the owner's cameras only four codecs ever apply. [V] Real takes show the owner uses both HQ (10-24, 10-26) and HEVC 4:2:2 (10-28, today).

### B2. Scope and timing

| Choice | Scope | Saved? | Takes effect |
|---|---|---|---|
| Codec | **Global** (`RecordingModel.swift:633`) | **No** | Next take |
| Timecode mode | **Global** (`:659`) | **No** | Next take |
| Folder | Default plus per-camera override (`:651`, `:780`) | Yes, bookmarks | Next take |
| Constant frame rate | Per camera (`AppSettingsStore.swift:277`) | Yes | Next take |
| CPU compatibility | Global, for capture and recording | Yes | Next take |

**The owner's premise needs correcting in one way: format isn't just buried, it isn't saved.** [V] `codec` and `timecodeMode` have no store, and the only shipping writes are the two Settings bindings (`UISettings.swift:135-136`). They return to HQ and Mac Clock on every launch. The installed binary dates from 11:48 today, just after HEAD. It was launched at 12:20 and recorded HEVC at 12:24, so [I] the owner re-picks HEVC after each launch, and any launch where that is forgotten records HQ at about 30 times the data rate.

**Safe during a take?** [V] Yes. `record(feedID:)` copies the configuration once on the main actor (`:864`), the driver prepares from that copy, and the writer never reads the model again. Changing codec while Camera 1 rolls can't touch that take, and Camera 2 uses the new value. The display is the problem: `RecordingFeedState` doesn't keep the take's codec, so the sidebar shows the next-take value beside a running take (`UISessionBridge.swift:195`, `UISessionSidebar.swift:155`).

### B3. Where codec can be changed today

[V] **Settings > Recording only** (`UISettings.swift:189-195`). The strip's Ready line mentions it as text (`UIPresentation.swift:619`), the sidebar shows it read-only (`UISessionSidebar.swift:155`), and the record popover, record row, ⋯ menu, Record menu and Inspector have no codec control. `popover-recording-dark` has no format line at all.

**A source that can't use the codec** is not flagged in the strip. Settings filters by the *selected* camera while the value applies to all (`UISettings.swift:133-134`), so another camera fails only when the take starts (`SourceRecording.swift:334`). That message is also broken: [V] line 337 has no backslashes, so the user reads the literal text "Recording profile (matrixProfile.displayName) is not supported by the declared source: (error)."

### B4. Data rate and time left

- [V] **HEVC estimates are about 11 times too high.** The table gives 0.15 bytes per pixel, about 597 Mb/s at UHD 59.94 (`RecordingSizeEstimator.swift:18`). Real takes measure **55 Mb/s**. No bitrate or quality key is set on the session, so this is VideoToolbox's default. Time left before a take is therefore about 11 times too short on HEVC.
- [V] ProRes HQ is close: 1,766 estimated, 1,583 to 1,671 measured.
- [V] An idle drive's time left uses the global codec at a fixed 4K 59.94 (`UISupport.swift:39`, `UISettings.swift:139`), ignoring the camera's real format, its own codec and other takes on that drive. `UILiveTelemetry.swift:48` has the same fallback.
- [V] Audio isn't counted in the rate, so 8 channels add an uncounted 9.2 Mb/s.

Worth the owner's attention: 55 Mb/s for UHD 59.94 4:2:2 10-bit is 29 times smaller than HQ, with no quality control in the app. The control below shows the real rate so that choice is informed.

### B5. Other per-take choices

- **Original or processed:** [V] always the original. `receive(_:)` hands the captured buffer to recording before any processing (`CaptureController.swift:1955`, `:2023`). The UI is right. **Four comments are wrong** in saying recording gets the burn-in LUT: `AppModel.swift:59-60`, `CaptureController.swift:434-436`, `MonitorFeedHost.swift:72`, `UICameraColumn.swift:456`. Fix them. No processed option is added: one exists in effect through the virtual camera, and original is what a backup should be.
- **Program recording: does not exist.** [V] Every `AVAssetWriter` is under `Sources/Recording` or the per-camera driver, keyed by feed. `ProgramOutputRoute` and `ProgramOutputBridge` have no writer, and Program has no audio. `AutoSwitcherTimelineRecorder` writes a JSON list of cuts against the source files, not a movie. So a streaming session leaves per-camera originals plus a cut list. The main UI should not imply otherwise. A Program take is a real feature (a recorder fed by Program's frames, plus a decision on whose audio it carries, as Program has none) and is out of this change. It needs its own design. No placeholder control.
- **File naming:** [V] automatic, `Feed/Feed_date_time_NNN_UUID.mov` (`RecordingOutputManager.swift:360-361`). The Settings preview omits the UUID (`UISettings.swift:250`), which real files all have. Fix the preview. NNN counts per output manager, not per camera, so one session gives Camera 2 `_001` and Camera 1 `_002`.
- **Take name or notes:** [V] none. The only note is the automatic audio one. Not added: typing during a live take is a focus risk nobody has asked to take on.
- **Timecode:** stays global so cameras stay comparable. Save it, and show it as a picker in the sidebar's Recording section.
- **Constant frame rate:** stays per camera, in the Inspector and as a toggle in the format menu, shown only for variable sources (`UIPresentation.swift:134`).
- **Folder:** unchanged.

### Decision: format is per camera, with a default

Use the folder model: a default for all cameras, plus a per-camera override. It is the shape the owner already knows ("Own folder"), and `record(feedID:)` merges folders at exactly the line where codec belongs (`:864-866`). It also solves the two real problems: each camera is checked against its own source, and each strip can state its own format. The owner's setups justify it: two drives, and an A-cam/B-cam split can want HQ and HEVC.

- `AppSettingsSnapshot.recordingCodec` and `recordingTimecodeMode`: the saved defaults, starting at HQ and Mac Clock. This fixes the save bug on its own.
- `FeedDescriptor.recordingCodec: RecordingCodec?`: nil follows the default.
- `RecordingFeedState.takeCodec`: set in `record(feedID:)`, for display.

### Spec: format control

**Control:** `UIRecordFormatMenu`, in the strip's `folderRow`, trailing, **replacing the footnote "Camera original · no LUT or effects"** (`UICameraColumn.swift:1012-1014`).

```
[folder] /Volumes/8TB/Takes/Camera 1 · 1 h 52 m left      HEVC 4:2:2 · ~55 Mb/s ⌄
```

That row already has the drive and time left, and format is what changes the time left, so the number moves beside the control. It adds no strip height. The footnote's text moves to the menu's first line, and stays in the record button's help and the Inspector. Unlike the footnote, the control never drops out: `UIFirstFitting` drops the rate first, then shortens the folder path.

**Menu:** native `Picker`, inline. One line per codec with its rate and time on this drive, for this camera's real source:

```
Camera original · no LUT or effects
Applies to the next take
──
✓ HEVC 4:2:2      ~55 Mb/s · 96 h left
  ProRes 422 LT   ~835 Mb/s · 6 h 20 m left
  ProRes 422      ~1.19 Gb/s · 4 h 25 m left
  ProRes 422 HQ   ~1.6 Gb/s · 3 h 20 m left
──
  ProRes 4444     Needs an RGB source        (disabled)
  HEVC Main       Needs a 4:2:0 source       (disabled)
──
Use Default (ProRes 422 HQ)                  (shown with an override)
Use for All Cameras
[Constant frame rate]                        (variable sources only)
```

Rows are examples. **Rolling:** from Starting through Finishing the menu is off, the chevron goes and the label shows the take's own codec, plain: `HEVC 4:2:2`. The live rate is already in the record row. Help: "Camera 1 is recording in HEVC 4:2:2. Change the format after this take." Another camera's control stays live; the model already makes that safe.

**Per camera vs. all cameras:**

- Strip: always that camera's effective format, nothing else.
- Sidebar Recording section: the read-only line becomes `Default format` and `Timecode` pickers. Changing the default affects cameras without an override, and rolling takes are untouched.
- Summary, when cameras differ: `2 formats · Mac Clock`.
- The toolbar stays Record All, with its help naming the formats.
- `Use for All Cameras` writes the default and clears overrides. If a take is rolling it says "Applies to Camera 2 now, Camera 1 after its take".

**Strips that are collapsed.** Four Up and Program View force every strip collapsed (`UIPresentation.swift:672`), so the strip control doesn't exist there. Add the same picker as a submenu at three places: `Recording Format` in the ⋯ menu (`UICameraColumn.swift:797`, in both strip forms), the Record menu for the selected camera (`UICommands.swift:112`), and each row of the REC popover, which also gains a line for the rolling take's codec. The collapsed row itself stays free of it, and the record button's help names the format.

**A source that can't use the choice:** never fail the take for something the UI knew. The camera's choice is kept, and the take uses the nearest available format:

| Chosen | Falls back to |
|---|---|
| 4444, on a 4:2:2 source | ProRes 422 HQ |
| HEVC Main or Main 10, on a 4:2:2 source | HEVC 4:2:2 |
| Any 4:2:2 codec, on a 4:2:0 source | HEVC Main |
| Any 4:2:2 codec, on an RGB source | ProRes 4444 |

The control turns orange with the warning symbol and reads `ProRes 4444 → ProRes 422 HQ`, help "ProRes 4444 isn't available for 2160p 59.94. This take records ProRes 422 HQ." `record(feedID:)` resolves the fallback from the source it knows, the take's sidecar records what happened, and the camera returns to the chosen format when a capable source returns. Before any signal, nothing is flagged. If there is no route at all, the existing refusal stands, with the broken message at `SourceRecording.swift:337` fixed.

**Estimates:** idle time left becomes per camera: free space divided by this camera's estimate plus the rates of takes rolling on that drive. Estimates come from the camera's real size, frame rate and channels, using the existing `nominalMegabits(codec:width:height:frameDuration:bitDepth:)`, plus PCM. The tilde stays until measured. Rate source, in order:

1. The rolling take's measured rate.
2. The last measured rate for that codec, size and frame rate, saved.
3. The nominal table, with HEVC corrected to about 0.015 bytes per pixel from the real takes.

`nominalBytesPerSecond` for the free-space check stays a cautious upper figure and doesn't change, so no take is newly admitted on a drive that can't hold it.

**Exact changes**

1. `RecordingModel.swift`: per-feed codec beside `feedConstantFrameRate`, merge at `:864`, `takeCodec`, fallback resolver in `RecordingCodec`. Add `RecordingCodec.fallback(for:)` beside `:37`.
2. `AppSettingsStore.swift`: the fields above. `AppModel.swift:361`, `:1053`, `:1571`: pass the override down, and restore the two defaults at load.
3. `UISessionBridge.swift:195`, `UIPresentation.swift:220`, `:619`: per-camera title, available list, fallback state. The `ready` line stops repeating the format.
4. `UICameraColumn.swift`: `UIRecordFormatMenu` in `folderContent`, submenu in `overflowMenu`.
5. `UISessionSidebar.swift:155`, `UIStatusBar.swift:307`, `UICommands.swift:112`, `UIInspector.swift:273`: the pickers.
6. `UISettings.swift:189-199`: `Default Format` and per-camera list, on the Per-Camera Folders pattern, and the file-name preview.
7. `UISupport.swift`, `UILiveTelemetry.swift:48`, `RecordingSizeEstimator.swift:18`: estimates. Add the audio rate.
8. `SourceRecording.swift:337`: the interpolation.
9. Tests: `Tests/RecordingModelChecks.swift` for the merge, persistence, fallback, and a take on one camera while another's format changes. ui-verify: strip in each state, plus a rolling mixed-format case.

## Order of work

1. The journal fix. It is losing takes now.
2. Save codec and timecode.
3. Channels shown, as display only. It is safe to ship alone and removes the six dead rows.
4. The format control and per-camera codec.
5. Estimates.

## What I could not verify

- The live strip's look at 8 channels. It follows from code and real files, but no live screenshot was allowed.
- The 16-channel paths on real hardware, including SDI. This rig is HDMI at 8.
- Whether any UI showed the 12:43 failure. The log query returned no recording error line, and the journal, sidecar and code are the evidence.
- Runtime cost of metering 8 channels. Nothing here measured the meter queue.
