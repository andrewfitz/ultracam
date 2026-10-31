# F. Fact check of the UI and UX audit

Date: 2026-10-30. Checked against the current tree at `2c4929c` and the renders in `.build/agent-work/build/ultracam/ui-verify/latest/png/` (built 11:46).

`Sources` is unchanged since the audited commit `30c8d73`. `Packages/MonitorKit` has uncommitted edits, but none in `AudioMeterView.swift`, the one MonitorKit file cited here.

**Method.** Code claims were read at the cited lines. Pixel figures come from a stdlib PNG reader in `/tmp/factcheck`, run with `python3 -I`, using the report's method: the most common pixel in the crop against the most extreme pixel. Files on `/Volumes/4TB Cam B` were read only. Nothing was built or run, and the app and its preferences were not touched.

**Limits.** Runtime statements are traced from code, not run. Report 01 and report 04 were not audited beyond the README claims listed here.

## Result

| Verdict | Claims |
|---|---|
| WRONG | 4 |
| PARTLY | 21 |
| UNVERIFIABLE | 6 |
| CORRECT | 73 |
| **Total** | **104** |

Error rate: 25 of 98 checkable claims (26%) are wrong or partly right, and 4 of 98 (4%) are plainly wrong. The sample is weighted toward claims that drive decisions and toward the claims named in the brief, so don't read this as the rate for the whole audit.

**Errors that affect a decision:** rows 1, 2, 3, 6, 7, 8 and 11. Everything else is wording, or a figure that doesn't change the outcome.

## Wrong and partly right

| # | Claim | Source | Verdict | Evidence |
|---|---|---|---|---|
| 1 | Moving LUT, Resize, Color, Frame rate and Processing behind one menu is justified because "each one renegotiates what Zoom is receiving" | README §5 Output row | WRONG | False for LUT in normal use. r3 P0-2 says "LUT doesn't", and 02:254 keeps the LUT chip on the strip for that reason. `applyLUT` touches the contract only through `untouched` (`VideoContract.swift:279-282`), so a LUT toggle can change it only when the LUT is the sole departure from the source. **Decision:** the stated reason for taking LUT off the strip doesn't hold. README §9 also misstates 02's position (row 13). |
| 2 | Program color "also applies in Separate mode", so rename it "Color space" | 06 V12 (:230), copy table (:443) | WRONG | `programColorimetry` is written at `AppSettingsStore.swift:357` and read only at `ProgramOutputRoute.swift:48`. 03 D7 ("No effect in Separate mode") is right, and README §6 is right to file it under Switching. **Decision:** drop the rename and its copy-pass row. |
| 3 | "Saved takes hide their dropouts... 60 lost frames read 'Saved'" | README B12, 02:85, 02 F16 | PARTLY | `dropsLine` does vanish after the take (`UIPresentation.swift:679`). But since `dcb58e1`, `SourceRecording.swift:1202` writes "The input was missing N frames in M gaps during this take..." into `warning`. That flows through `UISessionBridge.swift:161` and `UIPresentation.swift:665` to `UICameraColumn.swift:908`, which shows the note on Saved. Statistics survive the stop (`RecordingModel.swift:954`). `strip-saved-dark` simply has no gap fixture. True for the 2026-10-28 take, which predates that change, and true once the camera stops (`.stopped` hides Saved) and in Recent Takes. **Decision:** B12 narrows to "keep it after the camera stops, and in Takes". |
| 4 | "Find out a take had gaps: run `scripts/diagnose-capture.py` or read the log" | 02 §5 before and after | PARTLY | Same trace as row 3. The Saved note reports frames and gaps, truncated to one line with the full text in help (`UICameraColumn.swift:936-939`). The script is only needed once Saved has gone. |
| 5 | "14 red marks become 9" | 06 V6, §12 | PARTLY | 14 is right: my count of `main-program-meeting-1320` gives 14 with the toolbar stop keyed. 9 isn't reachable by 06's own fixes. V6 and V1 replace red text and fill with red dots, so V6 plus V10 give 11. |
| 6 | Use Record › Recover Interrupted Takes for the two failed takes | README §1 | PARTLY | The item exists (`UICommands.swift:144-149`), but 03:137 and 03:480 say it probably does nothing unless the Recording pane is mounted. The notification is posted straight after the open request. **Decision:** point the owner at the sidebar's Interrupted Takes › Recover (`UISessionSidebar.swift:205-219`), which sends `.recover` directly. |
| 7 | "Hold appears beside Auto when Auto is on, for every strategy" is presented as a UI placement | README §5, 02 F22 | PARTLY | Hold today is a Rust director setting only. `manualHold` is consumed at `AutoSwitcherBridge.swift:107`, and `SwitcherCoordinator.evaluate` never reads it. Fixed interval needs engine work, and PLAN.md's shared API defined `canHoldShot` as "natural talking head only". **Decision:** this belongs in the estimate, not just in Phase 3 layout. |
| 8 | Menu bar runs "in 14 rows or fewer" | README §5 | PARTLY | The list omits Start or Stop Cameras, though the Toolbar section says that stays in the menu bar. With 2 cameras, Program, one drive, no problem and that row, the list is 14. Add a second drive and one problem with an action and it is 17. 02 §3.8 lists still more (Strategy, Record All, folder row). **Decision:** the budget holds only when healthy. |
| 9 | "Time left is 11 times too short" | README B9 | PARTLY | 597 against 55 Mb/s is right: the 2026-10-30 `.partial` files work out at 64.3 Mb/s, less 9.2 for 8-channel PCM (05). It applies only to the idle estimate. A rolling take uses its measured rate (`UILiveTelemetry.swift:48`). |
| 10 | ⋯ repeats 11 listed items, and "nothing unique is left on an expanded strip" | 03:229 | PARTLY | The code at `UICameraColumn.swift:800-839` has two more entries: `UIMonitorLUTMenu` (:819) and Use Default Folder (:822). The Monitor LUT menu is unique to ⋯ today (03 E5 says so). "Nothing unique" holds only if E5's move to the Picture popover counts as a removal. Use Default Folder also lives in Inspector and Settings. |
| 11 | Sync: "the descriptions say only inputs and folders stay separate" | 03:381 | PARTLY | `UISessionSidebar.swift:103` and `UISettings.swift:308` also say source declarations stay per camera. `UIInspector.swift:160` doesn't mention declarations, and none of the three says "only". The audit missed the larger mismatch: Sync copies them (`AppModel.swift:175-177`: source profile and both LUT spaces). **Decision:** add this to the Sync fix and to the confirmation text. |
| 12 | Scope:8 and Set:673 "say scopes follow every frame" | 03 H11 | PARTLY | Scope:8 is a code comment, not UI text. Set:673 says every monitor shows every frame and "only a scope may skip an update while the GPU is still drawing", which is misleading against the 15 Hz cap but doesn't say scopes follow every frame. `UIScopeDescription.swift` says "Every pixel", not every frame. |
| 13 | Effect chips: "02 move to inspector" | README §9 | PARTLY | 02:254 keeps the LUT chip as a strip toggle. Only Resize, Color, Frame-rate and Processing move. |
| 14 | ON AIR white text 3.94, in a table marked "light mode unless noted" | 06 §9 | PARTLY | 3.94 is dark mode. Light mode measures 4.10. Both fail 4.5, so V8 stands. |
| 15 | Selected-camera panel rows are "shown as a subtitle only with several cameras" | 03 P1 | PARTLY | True for MB:374 and MB:432. Video Preview (MB:436) has no subtitle at all. |
| 16 | Removing three rows ends selection dependence in the menu bar | README §5, 02 §3.8 | PARTLY | "Show Live Preview" also depends on it: `waiting` reads the selected camera (`UIMenuBar.swift:346`, `:363`). README's rule "no row may depend" needs this row too. |
| 17 | At-rest tools are a P1-11 regression: "Regressed, restore" | 02 §7, 02:222 | PARTLY | Auto and the Stop All label are regressions. The tool bar isn't: `b621bc7` was a deliberate fix (06:35 is right). See the b621bc7 section. |
| 18 | "F5: Monitor pane is explanation only" is listed under "Regressed or never landed" | 06 §11 | PARTLY | F5's fix was explanation only, and PLAN.md's result records that as done. Longer prose is a drift. "Still no controls" is what F5 decided. |
| 19 | "Nothing here reopens a resolved finding unless marked" | 06:33 | PARTLY | V7 stops focus from selecting, which reopens D7's merge of selection and focus and isn't marked. Section 11 lists three overturns. See the polish section. |
| 20 | Program mode says "Camera 1 on air" in the subtitle, status bar, ON AIR pill, strip badge and output line | 06 V10 | PARTLY | Four of the five show in `main-program-meeting-1320-dark`. Camera 1's output row there is an unlabeled glyph, as 06 V5 itself says; the words exist only in the accessibility text "In Program · on air". |
| 21 | README §10: "D8, keep time left, takes, Saved; no app names" | README §10 | PARTLY | REPORT D8 also keeps "director timeline (single audio lane)" and limits "Record with camera apps" to the D6 rules. See the D1 to D8 table. |
| 22 | README §10: "D7, one visible selection" | README §10 | PARTLY | REPORT D7 merges selection and focus. README drops the focus half, which is the part V7 changes. |
| 23 | Menu has "about 18 rows, 6 separators" | 02:137 | WRONG | 7 separators with the card: `UIMenuBar.swift:366`, 380, 394, 399, 429, 446, 453. No decision depends on it. |
| 24 | "Everything a preset would hold already persists" | README §7 | WRONG | Codec and timecode don't persist today (B1, confirmed below). It becomes true only after Phase 0. |
| 25 | Reset's text "Set:740 reads as if everything goes" | 03 L6 | PARTLY | Set:740 lists "Cameras, effects, folders, monitor tools and layout", which doesn't claim sign-ins. The sweeping wording is the help at Set:736, "Reset every saved preference". The survival facts themselves are correct (rows 37 and 38). |

## Unverifiable

| # | Claim | Source | Verdict | Evidence |
|---|---|---|---|---|
| 26 | 2026-10-28 take had 60 missing frames in 32 gaps | 02:85, README B12 | UNVERIFIABLE | **Unknown in the repo.** `git grep` finds no such figure outside `docs/ui-audit`. It matches the user's auto-memory note, not a repo file. |
| 27 | Both cameras dropped together at 13:59:04 on 2026-10-30 | 02:114, README B13, §12 | UNVERIFIABLE | **Unknown in the repo.** Same as row 26. The failed takes ended at 12:43, so their sidecars don't cover it. |
| 28 | The real dropouts here were 2 frames | README §4, 02:108 | UNVERIFIABLE | **Unknown in the repo.** Both 2026-10-30 sidecars show `recording.sourceVideoLost: 2`, consistent but not proof. The 1 second hold rests on this. |
| 29 | Both units now sit behind the OWC hub | README §12 | UNVERIFIABLE | **Unknown in the repo.** Memory note only. |
| 30 | Only one warning shows "yet both cameras dropped together on 2026-10-30" | README B13 | UNVERIFIABLE | The code half is correct (row 58). The event half is row 27. |
| 31 | Record › Recover Interrupted Takes does nothing when Settings opens on another tab | 03:480, 06:638 | UNVERIFIABLE | 03 hedges with "probably"; 06 states it as fact. Whether macOS keeps unselected `TabView` panes mounted needs a run. The dependency itself is row 39. |

## Correct

| # | Claim | Source | Verdict | Evidence |
|---|---|---|---|---|
| 32 | Program has 18 top-level rows plus the card | 06 V19, 02:137 | CORRECT | `menubar-program-meeting.txt`: 17 commands plus the stats footnote make 18. The "Cameras" header is a 19th entry if counted. Removing 4 gives V19's 14 on the same count. |
| 33 | Top-level panel rows act on the selected camera | 02 F10, 03 P1 | CORRECT | `UIMenuBar.swift:373-377`, `:431-438`. |
| 34 | Picking a value silently enables the effect | 03:423, 03 D3-D5 | CORRECT | `UISessionBridge.swift:325-327` sets `downscale`, `convertTo420` and `reduceFrameRate`. |
| 35 | Sync copies `previewEnabled` | 03 B11, :381 | CORRECT | `AppModel.swift:179`. |
| 36 | Sync doesn't copy `recordingConstantFrameRate` | 03:381 | CORRECT | Absent from `AppModel.swift:164-180`. |
| 37 | Reset All leaves Keychain sign-ins | 03 J6, L6 | CORRECT | `CameraControlStore.reset()` (:289) has no `credentials.delete`. The only delete is at :396. |
| 38 | Reset All leaves recovery bookmarks | 03 L6 | CORRECT | Key `recordingRecoveryRootBookmarks` (`RecordingRecovery.swift:249`) isn't matched by the filter at `AppSettingsStore.swift:574-578`. |
| 39 | `UIShowRecovery` needs the Recording pane mounted | 03 G16, :480 | CORRECT | The only receiver is `UISettings.swift:241`, inside that pane. |
| 40 | Stop All Recordings has no confirmation | 03 G2, E-list 5 | CORRECT | `needsConfirmation` falls to `default: nil` (`UIAction.swift:107-127`). |
| 41 | Quit has no confirmation and stops every take | 03 A3 | CORRECT | `UICommands.swift:41-44`, `UISessionBridge.swift:424-426`, `UltracamApp.swift:44-64`. |
| 42 | File stem is `feed_timestamp_NNN_UUID` and the Settings preview omits the UUID | 03:403, G7 | CORRECT | `RecordingOutputManager.swift:361`, `UISettings.swift:246-251`. Files on disk match. |
| 43 | `_001` is shared by cameras using one folder and restarts each launch | 03:403 | CORRECT | `pathNonce` (:201, :358), one manager per folder (`RecordingModel.swift:601-610`). On disk, Camera 1 `_001` and Camera 2 `_002` started in the same second. |
| 44 | Fixed interval defaults 5 s in the model, 8 s from Restore Defaults | 03 F13, E-list 7 | CORRECT | `AppSettingsStore.swift:168,190`, `UISettings.swift:528`. Set:414 is overwritten at :495. |
| 45 | Scope refresh defaults to 15 Hz and has no UI | 03 H11 | CORRECT | `MonitorWorkspace.swift:478`. No `UI*.swift` reads or writes `refreshHz`. Consumed at `MonitorSurface.swift:1398,1610`. |
| 46 | Strip heights 207, 212.5 and 224 pt | 06 V11 | CORRECT | Measured in `strip-ready`, `strip-recording` and `strip-saved`, light and dark. |
| 47 | Picture narrows 11 pt, 926 to 915 | 06 V11 | CORRECT | Measured: x 630-2481 against 641-2470 at 2x. |
| 48 | Saved shrinks the picture about 30 pt | 06 V11 | CORRECT | 17 × 16/9 = 30.2. Arithmetic, as stated. |
| 49 | Strip bottoms at 582 and 586 pt | 06 V11 | CORRECT | Measured 582.5 and 586.5 in `main-program-meeting-1320-dark`. |
| 50 | "Recording" contrast 3.84 light, 4.04 dark | 06 V6 | CORRECT | Measured: (222,74,58) on (248,248,248); (223,79,65) on (34,34,34). |
| 51 | "0 dropped" contrast 3.93 | 06 V6 | CORRECT | Measured in light: (124,124,124) on (248,248,248). Dark is 5.72, which passes. |
| 52 | Pill reaches 5.75:1 after a 20% mix with black | 06 V8 | CORRECT | Computed from the measured dark red. |
| 53 | "12:31" appears four times with one camera recording | 06 V10 | CORRECT | `main-single-meeting-1320-dark`: toolbar, picture pill, strip clock, status bar. |
| 54 | Hold exists only for Natural talking head | 02 F22, :97 | CORRECT | `UIPresentation.swift:727`, comment at `UICommands.swift:183`. |
| 55 | Fixed Interval timer keeps running after a manual cut | 02:96 | CORRECT | `requestManualCut` (`SwitcherCoordinator.swift:274-283`) never touches `fixedIntervalOrigin`. It resets only at :262, :322, :326 and :489. |
| 56 | Unused actions: selectNumber, cutNumber, setGamut, clearDefaultFolder, removeCameraExtension | 03:249 | CORRECT | Each appears only as a `case` and a handler. No `.send` anywhere in `Sources` or `Tests`. |
| 57 | `forgetLUT`, `recover` and `installCameraExtension` are bypassed or unsent as stated | 03:249 | CORRECT | `UISettings.swift:765`, :281, :315. `recover` and install are still sent by the sidebar, as 03 implies. |
| 58 | `warning()` returns the first match only | README B13, 02 F25 | CORRECT | `UIPresentation.swift:818-847`. |
| 59 | Program has no audio; virtual cameras have no audio | README §6, 05 | CORRECT | No audio in `ProgramOutputRoute`, `ProgramOutputBridge` or `CameraSink`. `Sources/CameraExtension` has only the transport constant at `CameraProvider.swift:662`. |
| 60 | Input Connector and Advertise HDR have `interruptsCapture: true` and no prompt | 03:319 | CORRECT | `DeckLinkCapturePlugin.swift:351,376`. `UISettingsDeviceSettings.swift:17-19` applies directly, with only the caption at :32. No lock in `VendorSettingsStore.apply`. |
| 61 | Advertise HDR shows only on HDMI | 03 C11 | CORRECT | `DeckLinkCapturePlugin.swift:468`. |
| 62 | Journal failure cause and figures | README §1 | CORRECT | Both journals: 16,777,011 bytes, 68,245 `nativeTimecode` entries, 18.98 min at 59.94. Both sidecars: `finalError` "Recording metadata journal is full". Journal mtime 12:43. The `.partial` and sidecar mtimes are 18:59, after the audit; their size still fits 18.98 min, and no `.mov` exists. |
| 63 | `dcb58e1` (2026-10-29) introduced per-frame journaling | README §1 | CORRECT | `git log -S` on `sourceNativeTrackExpected` and `cadenceSourceTiming`. |
| 64 | Per-frame path, including the constant frame rate path | README §1 | CORRECT | `AVAssetSourceRecordingWriter.swift:723-727`, `:739`. |
| 65 | `journalFull` fails the take; each entry fsyncs and rewrites the sidecar | README §1 | CORRECT | `RecordingTakeSidecar.swift:225`, :229-231; `SourceRecording.swift:1119-1135`. |
| 66 | B1: codec and timecode aren't saved; about 30 times the rate | README B1 | CORRECT | `RecordingModel.swift:633,659` are plain vars. 1,766 or 1,583-1,671 against 55 Mb/s is 29 to 32 times. |
| 67 | B2: a self-stopped camera reads as a normal stop | README B2, 02 F01 | CORRECT | `AppModel.swift:1150-1160`, `UISessionBridge.swift:113`, `UIPresentation.swift:555`. |
| 68 | B3: no notification, sound or dock bounce | README B3 | CORRECT | Grep of `Sources` and MonitorKit sources found no `UNUserNotification`, `NSSound`, `requestUserAttention`, `NSBeep` or `AudioServicesPlay`. |
| 69 | B4: health goes false only on stop and failed-start paths | README B4, 02 F03 | CORRECT | Traced: `AppModel.swift:1185,1284`, `FeedRuntime.swift:406`. No-signal path at `CaptureController.swift:725-734` doesn't touch health. |
| 70 | B5: a connected sink counts as a client in Separate | README B5 | CORRECT | Traced: `UISessionBridge.swift:128`, `CaptureController.swift:1352`, `:2448`, tally at `UIPresentation.swift:527`. |
| 71 | B6: the no-demand branch can't run | README B6 | CORRECT | Traced: `AppModel.swift:1133` installs `onProcessedFrame` always, so `CaptureController.swift:2140` always passes. |
| 72 | B7: Settings' strategy picker leaves Auto on | README B7 | CORRECT | `UISettings.swift:418-423` against `UISessionBridge.swift:363-368`. Presentation masks it under Manual; it resurfaces on the next strategy pick. |
| 73 | B8: literal text in the refusal | README B8 | CORRECT | `SourceRecording.swift:337`. `(error)` is literal too. |
| 74 | B10: time left ignores non-rolling cameras | README B10 | CORRECT | `UILiveTelemetry.swift:44-48` keeps recording or paused takes only; `UISupport.swift:63-65`. |
| 75 | B11: hardcoded 4:2:2 | README B11 | CORRECT | `UIInspector.swift:340`. |
| 76 | B14: Transcript assisted default with no feed | README B14 | CORRECT | `AppSettingsStore.swift:46`. `ingestTranscript` callers are in `Tests` only. |
| 77 | B15: selection ring uses accent, and the app defines none | README B15, 06 V2 | CORRECT | `UICameraColumn.swift:99`. No `AccentColor` asset in the repo. |
| 78 | 141 capabilities and 39 findings | README table | CORRECT | Counted 141 master rows in 03 and V1 to V39 in 06. |
| 79 | A test publishes both kinds of device | README §3 | CORRECT | `Tests/CameraRegistryRuntimeChecks.swift:90-110`. |
| 80 | Zoom cached its camera list | README §3 | CORRECT | `VALIDATION.md:781`, one Zoom 7.2.2 observation. See inference list for what it is stretched to. |
| 81 | `UI_REDESIGN.md:105,226` lock the output mode | README §10 | CORRECT | Both lines say so. |
| 82 | Record All enabled if any camera is ready | 02 F12 | CORRECT | `UIPresentation.swift:717`, `RecordingModel.swift:998`. |
| 83 | After one camera rolls the toolbar shows "Stop All (1)" | 02 F13 | CORRECT | `UIPresentation.swift:720`. |
| 84 | Low-drive warning is a fixed 30 minutes, duplicated | 03 G15 | CORRECT | `UIPresentation.swift:830`, `UISessionSidebar.swift:318`. |
| 85 | Menu bar shows only the first drive | 02 F28 | CORRECT | `UIMenuBar.swift:286-290`. |
| 86 | Menu bar triangle replaces the recording dot | 02 F32 | CORRECT | `UIPresentation.swift:915-917`. |
| 87 | Show Recordings opens one folder only | 02 F18 | CORRECT | `UISessionBridge.swift:401-404`. |
| 88 | `showStatus` writes app errors to the selected camera's message | 02:118 | CORRECT | `AppModel.swift:1000-1004`. |
| 89 | Session dropouts never reach the UI | 02 F16 | CORRECT | `signalDropouts` has no reader outside `CaptureController.swift`. |
| 90 | No global hotkey exists | 02:122 | CORRECT | No `addGlobalMonitorForEvents` or `RegisterEventHotKey` in `Sources` or MonitorKit sources. |
| 91 | Sidebar has no camera rows at 1 to 2 cameras | 02:146 | CORRECT | `UISessionSidebar.swift:58`. |
| 92 | Stop controls: same glyph, gray unkeyed; `.stop` sends `.toggleRecordingSelected` | 06 V1 | CORRECT | `main-program-meeting-1320-dark`; `UIToolbar.swift:198-218`. |
| 93 | Thirteen controls in about 285 pt | 06 V9 | CORRECT | Six tools with chevrons plus Picture. Measured about 284 pt. |
| 94 | REC pill truncates to a dot and one letter at 980 | 06 V3 | CORRECT | `main-four-up-980-dark`, Camera 1. |
| 95 | On-air picture folds to one button at 980 while neighbors keep the bar | 06 V15 | CORRECT | Same render. |
| 96 | 244 pt of empty space above the status bar | 06 V13 | CORRECT | Measured 243.5 pt. |
| 97 | Live strip measures 230 pt | 06 §7 | CORRECT | `main-live-model-dark`, Camera 2: y 740 to 1199 at 2x. |
| 98 | Settings hardcoded heights and width | 06 §8, 03:447 | CORRECT | `UISettings.swift:27`, :110, :238, :370, :490, :679, :749. |
| 99 | Reset header cut at 520; bare Published Cameras header; "Not installed" beside "request completed" | 06 §8 | CORRECT | `settings-advanced-dark`, `settings-camera-dark`. |
| 100 | `.caption` and `.subheadline` counts | 06 §7 | CORRECT | 8, 5, 5, 9, 4, 3, 8; `.subheadline` 13 and 19. |
| 101 | Reduce Motion unread; Increase Contrast read once | 06 §9 | CORRECT | Grep of `Sources/App`. |
| 102 | `lightTrack` is white 0.2 | 06 V24 | CORRECT | `AudioMeterView.swift:174`, unmodified. |
| 103 | `Move` and `Selected` read aloud as images; 8 blank `AXButton` rows | 06 §9 | CORRECT | `accessibility-program-meeting.tsv`, `accessibility-problems.tsv`. |
| 104 | True-peak, fragment, auto-stop and shot-floor constants as cited | 03 E-list | CORRECT | `AudioMeterTapDisplay.swift:43-44,169`; `AVAssetSourceRecordingWriter.swift:1944-1945`; `AutomaticFeedPolicy.swift:63`; `AppSettingsStore.swift:109`. |

## README claims stated as fact that are really inference

| Claim | Why it is inference |
|---|---|
| "Stop recording first protects nothing" (§3) | `RecordingModel` doesn't read the mode, which I confirmed. "Nothing" is a reading of the code, not a test. |
| "No commit or doc records a reason for the lock" (§3) | Absence of evidence. `UI_REDESIGN.md:226` says "keep all", and `4b14f60` lists the lock's conditions without a reason. |
| "A stable device list is also better for meeting apps" (§3) | Rests on one Zoom 7.2.2 restart note in `VALIDATION.md:781`. |
| "No extension update, no macOS approval, no settings migration" (§3) | Analysis from 01. §12 item 1 concedes the upgrade is untested. |
| "Also unlocked: rename live. Add live after two fixes. Remove a stopped camera while others run" (§3) | 03:481 lists Add and Remove as undetermined and needing a live test. |
| "The no-demand path has never run in the app" (§3) | Follows from reading B6. Not observed. |
| "All verified in code" for B5, B6 and B10-type runtime effects (§2) | The mechanism is in code. "Shows ON AIR with no viewer" and "render every frame" are traced outcomes. Only B4 is marked as traced. |
| "The real strip has 8 meter rows, 6 of them silent" (evidence limits, §6) | 05 tags the channel data [V] but the strip's appearance [I]. Nothing shows it rendered. |
| "So 'As Detected' shows 2" (§6) | Prediction of a feature that doesn't exist. |
| Prominent tints go gray "which is all of a meeting" (§5) | Comment at `UIToolbar.swift:156-157` says "most of a meeting". |
| "Processing is the biggest single change a click can make" (§9) | Judgment. |
| "This rig has two identical Mini Recorder 12Gs"; USB 3 fallback "cannot be detected" (§7) | From the user's memory notes and 04, not repo evidence. I didn't audit 04. |
| The dropout facts (§2, §4, §12) | Rows 26 to 30. |

## Contradictions README section 9 doesn't account for

| Topic | Positions | README |
|---|---|---|
| Timecode home | 02:206 stays in Settings as a caption. 03:399 two pickers in the sidebar | §5 shows a picker, unsettled in §9 |
| Stop label | 02:297 "Stop All Recordings (2)", restoring P0-3. 06 "Stop 2 Recordings" | Uses 06's, unlisted, and drops P0-3's wording |
| Status bar order | 02:307 Problems first. 06 V18 warning stays last | Uses 02's, unlisted |
| Audio segment | 02 "Audio 2 of 2". 06 V18 icon only when fine | Uses 02's, unlisted |
| "Processing" name | 06 §5 overturns F3 to "Effects". 02 and 03 keep "Processing" | §5 says "Processing"; copy pass is in Phase 3. Unsettled |
| Menu bar Auto rows | 06 V19 one Switching submenu. 02 §3.8 flat rows | Flat rows, unlisted |
| Start with Camera Apps | 06 V19 keeps the top-level row. 02 and 03 remove it | Removed, unlisted |
| Hold location | 06 V4 inside the Auto menu. 02 beside Auto | Beside Auto, unlisted |
| Automation row | 06 V23 keeps with a chevron. 02 and 03 remove | Removed, unlisted |
| Collapse All | 02:301 removes from toolbar. 03 A9 keeps | Absent from the toolbar line, unlisted |
| Camera display toggle | 02:257 and 03 J4 keep it on the strip because it can spoil a shot | **Missing from the §5 output row, with no home stated** |
| Sync in Settings | 06 V23 keeps. 03 and README remove | Inspector only, unlisted |
| Backup "Coming later" in Settings | 06 V23 keeps. 03 G19 removes | Removed, unlisted |
| Window title | 06 V17 hides it, overturning PLAN.md | Not mentioned in §5 or §10 |
| At-rest tools | 02 "regressed". 06 "deliberate" | §9 merges the proposals, not the finding |
| Settings size | 03 780 × 560. 06 820 × 620 | Uses 06's, unlisted |
| Section count | 06 says 7 (:630) and ten (:601, :783). 03 six | Nine, listed only against 03 and 04 |
| True-peak level home | 03 Monitoring | §6 Audio, unlisted |
| Low-space level home | 03 Recording | §6 Alerts, unlisted |
| Copy Diagnostics | 03 L2 removes from Settings | §6 Advanced keeps it, unlisted |
| Output mode | §9 says only 03 assumed the mode stays. 06 also does (V5, V16, stop verbs) | Row understated |
| Fixed strip rows | README "Rows never appear or vanish". 06 V11 and 02:252 keep variable alert rows | Internal to §5 |
| Stop Cameras in the menu bar | Toolbar section says it stays. Menu bar order omits it | Internal to §5 (row 8) |

## README section 10 against `docs/mockups/r3/audit/REPORT.md`

| Decision | README description | Verdict | Note |
|---|---|---|---|
| D1 | Click selects and never cuts | CORRECT | Matches D1 and P0-1. |
| D2 | Format changes without prompt | CORRECT | Matches. REPORT also keeps "Updating output…", which README doesn't restate. |
| D3 | Stop Camera and Stop All Cameras | CORRECT | The round-4 list also put Stop All Cameras in the Program toolbar; "placement changes" covers that. |
| D4 | No orange skipped ring | CORRECT | |
| D5 | ⋯ menu plus on-demand inspector | CORRECT | |
| D6 | Backup automation rules | CORRECT | The status line "placeholder rows go" conflicts with BRIEF and PLAN (below). |
| D7 | One visible selection | PARTLY | REPORT merges selection and focus. |
| D8 | Keep time left, takes, Saved; no app names | PARTLY | Omits director timeline and the D6 limit on "Record with camera apps". |

03 and 06 cite "D8" for the red rule. That is BRIEF.md's D8, not REPORT's, whose red rule is P1-10. The content is consistent; the label isn't. "V1 session panel" isn't in REPORT.md: it comes from `docs/UI_REDESIGN.md:362` and the r2 mockups.

## Decisions in `docs/ui-polish/` that proposals reopen

| Decision and reason | Proposal | Acknowledged? |
|---|---|---|
| native.md:9: Settings' grouped form and toolbar tabs fit the platform and need no change. BRIEF: Settings (6 panes), keep | README §6 sidebar window | 06 §11 overturns F4 with reasons, but neither it nor README cites native.md |
| BRIEF:36 and PLAN:23: deferred features show as "Coming later" | README removes every such row, in Settings too | No. 06 V23 keeps them in Settings |
| F5: Monitor pane is explanation only, because the brief ruled out new features | README adds Scope refresh and sends prose to Help | 06 §11 miscalls it a regression (row 18) |
| F3: keep the toggle labelled "Processing" to match ⇧⌘B and the strip | 06 "Effects" | 06 yes. README no |
| PLAN: visible title "Ultracam" | 06 V17 | 06 yes. README silent |
| H11: the footnote is "the one line that tells the user the recording differs from what the meeting sees" | README removes it from the strip. It remains in help and the left pane | Partly. The left pane closes, which tests README's own "lose nothing" rule |
| PLAN shared API: `canHoldShot` natural talking head only, because Hold reaches only that director | README Hold for every strategy | No (row 7) |
| D7 and BRIEF: selection and focus are one | 06 V7 | No (row 19) |
| r3 round-4 list: drop sidebar camera rows at 2 or fewer cameras, because strips already show them | README Cameras section at every count | §10 says "Revised" without the reason |
| P0-4: an accent ring | B15 fixed blue | No, but BRIEF already says "blue ring", so this is a safe resolution of the two sources |

## `b621bc7` against the proposal

**The commit's reason.** The tool bar "appeared only on hover over a live picture, so with no signal it never showed and otherwise it was hard to find."

**There is a real conflict, but only in one form of the proposal.**

- **02:222 is the code that commit deleted.** "At rest show only active tools" restores the removed branch almost line for line, so it reintroduces both problems.
- **README's "one tools button plus active tools" keeps findability.** That is the right resolution, and 06 V9 states the gain to keep.
- **The hover half is the risk.** `revealed` is true only for `.live` and `.updating` (`UICameraColumn.swift:59-64`). Building "full tool bar on hover" on `revealed` recreates the exact bug: no bar on a no-signal or stopped picture. README doesn't say this; it needs one sentence.
- **06 V9 and V15 work against their own text.** They call stopped and disconnected pictures places "where no tool can act", while V9 lists "works with no signal" as a gain to keep. The commit wanted the bar there.
