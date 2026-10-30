# 03. Feature inventory and placement

Audited against commit 30c8d73 on 2026-10-30, from source only. No build was run and the running app was not touched.

## How to read the master table

**File keys** (all under `Sources/App/` unless a path is given): Side = UISessionSidebar, Col = UICameraColumn, Tool = UIToolbar, Insp = UIInspector, Stat = UIStatusBar, Set = UISettings, Dev = UISettingsDeviceSettings, Cmd = UICommands, MB = UIMenuBar, Prog = UIProgramView, Diag = UIDiagnostics, Help = UIHelp, Feed = UIFeedSettingsMenu, Ctl = UICameraControl, Bridge = UISessionBridge, Pres = UIPresentation, Model = AppModel, Rec = RecordingModel, Store = AppSettingsStore, Bar = UIMonitorTools, Forms = UIMonitorToolForms, FC = UIMonitorToolFalseColor, Pic = UIMonitorToolPicture, Scope = UIScopeSettings, Det = MonitorWorkspaceView, Work = `Sources/Shared/MonitorWorkspace.swift`, Main = UIMainWindow, App = UltracamApp.

**Surfaces**: sidebar, overlay (on the picture), ctx (picture context menu), strip, overflow (strip ⋯ menu), toolbar, inspector, status (status bar and its popovers), Settings/tab, menu (app menu bar, by menu name), panel (menu bar item), Diagnostics, Help, ProgView, detached (detached monitor window).

**Flags**: a duplicated; b in code, not in UI; c UI without purpose; d wrong cadence; e hardcoded, should be a setting; f lock that looks unnecessary (review).

**Placement rule**: per take or per session goes on the main window. Set-once or set-per-rig goes in Settings. Per-camera deep setup goes in the inspector. Needed while the window is hidden also goes in the panel. Everything with a shortcut gets a menu command. A menu command and a panel row are justified secondaries by rule, so flag a means a surface beyond those, with no workflow reason.

**Settings tab names in PRIMARY** are the new structure from "Proposed Settings structure" below: General, Cameras, Recording, Program, Monitoring, Advanced.

## Master placement table

### A. App and window

| ID | Item | Scope, persistence | Surfaces today | Flags | PRIMARY | Secondaries | Action |
|---|---|---|---|---|---|---|---|
| A1 | Dock or menu bar only | Global, `ultracam.hideFromDock` Store:557,588 | Settings/General Set:57; menu Ultracam Cmd:37 | a | Settings › General | None | Remove Cmd:37: a set-once choice has no reason to be a menu checkbox. Labels also differ. |
| A2 | Open at login | Global, SMAppService Set:47,114 | Settings/General Set:62 | | Settings › General | None | Keep. |
| A3 | Quit | Action. `.quit` Bridge:424 | menu Cmd:41 ⌘Q; panel MB:462 | e | App menu | Panel | Quit asks nothing while recording or on air; App:44-64 stops every take. See E-list item 5. |
| A4 | Show main window | Action. `.openMainWindow` | menu Window Cmd:280 ⌘0; panel MB:451 | | Window menu | Panel | Keep. |
| A5 | Open Settings | Action. `.openSettings` | menu (system ⌘,); panel MB:452 | | App menu | Panel | Keep. |
| A6 | Picture layout | Session, `ui.layout` Bridge:10,34 | toolbar Tool:51; menu View Cmd:225 ⌥⌘1-4; Settings/General Set:85 | a c d | Toolbar | View menu | Remove Set:85. It binds the same key as the live layout (Set:44), so there is no default layout, only a mirror. Last-used layout already persists. |
| A7 | New camera strips collapsed | Global, `ui.collapsed.default`, read at Add Camera Bridge:45,344 | Settings/General Set:96 | c d | Removed | None | Remove. Applies only at Add Camera, which a 1-2 camera rig does about twice ever. Bridge:40 comment names a section that no longer exists. |
| A8 | Collapse one strip | Per camera, `ui.collapsed` Bridge:11 | strip Col:747 | | Strip | None | Keep. |
| A9 | Collapse all strips | Session, action | toolbar Tool:61; menu View Cmd:232 ⌥⌘S | f | Toolbar | View menu | Keep. Disabled in Four Up and Program View (Tool:68); see lock list. |
| A10 | Sidebar visibility | Session, `ui.sidebar` Bridge:12 | system toolbar button (NavigationSplitView, Main:24); menu View Cmd:230 ⌃⌘S | | Toolbar | View menu | Keep. |
| A11 | Inspector visibility and open for camera | Session, not persisted (Bridge:22) | toolbar Tool:73; menu View Cmd:238 ⌥⌘I; ctx Col:429; overflow Col:801; overlay Col:137; panel MB:585; sidebar rows Side:51 | a | Toolbar | View menu, ctx, panel | Remove overflow Col:801: ctx and sidebar rows already open it per camera. |
| A12 | Swap Pictures | Session, `ui.order` Bridge:19,304 | ctx Col:420; menu View Cmd:241 | | ctx | View menu | Keep. Swaps the first two only (Bridge:306). |
| A13 | Expand and Restore picture | Session, not persisted (Bridge:21) | ctx Col:415-417; menu View Cmd:243-249; toolbar Tool:39 (restore) | | ctx | View menu, toolbar restore | Keep. |
| A14 | Select camera | Session, `selectedFeedID` Store:469 | overlay Col:107; sidebar rows Side:72 (3+ cameras); menu Camera Cmd:94 ⌘1-4 | | Picture click | Camera menu, sidebar rows | Keep. No way to change the selection from the panel, which matters for F1 below. |

### B. Camera lifecycle

| ID | Item | Scope, persistence | Surfaces today | Flags | PRIMARY | Secondaries | Action |
|---|---|---|---|---|---|---|---|
| B1 | Start or stop all cameras | Session, action | toolbar Tool:24; menu Camera Cmd:85 ⌘↩; panel MB:369 | | Toolbar | Camera menu, panel | Keep. |
| B2 | Start or stop one camera | Session, action | strip Col:769; overflow Col:832; overlay Col:153; menu Camera Cmd:62; panel MB:587 | a | Strip | Camera menu, panel, collapsed-strip overflow | Remove overflow Col:832-836 on expanded strips: the same control is in the header above it. A collapsed strip has no other Start or Stop, so it keeps this item. |
| B3 | Add camera | Rig, action | sidebar Side:82; menu Camera Cmd:100; empty state Main:73 | f | Sidebar | Camera menu | Keep. Lock review. |
| B4 | Remove camera | Rig, action, confirms UIAction:112 | overflow Col:837; inspector Insp:54; menu Camera Cmd:105 | a f | Inspector | Camera menu | Remove overflow. Lock review. |
| B5 | Rename camera | Rig, `name` Store:258 | overflow Col:827; inspector Insp:49; menu Camera Cmd:76 | a f | Inspector | Camera menu | Remove overflow. Lock review. |
| B6 | Camera enabled flag | Per camera, `enabled` Store:282 | None. Filtered throughout `Sources/Shared/FeedRuntime.swift`, never written by a UIAction | b | Removed | None | Do not expose. Stop Camera covers the need. Delete the field after migration. |
| B7 | Retry a failed start | Per camera, action | overlay Col:147; strip Col:693, Col:780; collapsed strip Col:1133; inspector Insp:322; panel MB:361 | a | Strip | Panel | Remove Insp:322. A stopped camera can show Retry on the picture and the header together (Col:147, Col:780). Keep the header one. |
| B8 | Start with camera apps | Per camera, `automaticFeed` Store:281 | inspector Insp:313; panel MB:374 (selected camera only); sidebar Side:243 (status plus link) | c | Inspector | Panel | Remove the sidebar Automation section (Side:239). It cannot change the setting, only opens the inspector. Panel row belongs per camera; move it into the camera submenu, see P1. |
| B9 | Automatic status text | Per camera, runtime Model:1302 | inspector Insp:329; sidebar Side:247; overlay Col:171 | | Inspector | Overlay on failure | Keep, minus the sidebar. |
| B10 | Show live preview while waiting | Session, runtime | panel MB:364 | | Panel | None | Keep. |
| B11 | Video preview | Per camera, `previewEnabled` Store:279 | inspector Insp:140; ctx Col:425-427; overlay Col:160; menu Camera Cmd:72 ⇧⌘P; panel MB:436; detached Det:89 | a | ctx | Camera menu, panel, overlay recovery button | Remove Insp:140: a session toggle, not deep setup. Sync copies it (Model:179) though every Sync description lists what stays separate and omits this. |

### C. Input and source declaration

| ID | Item | Scope, persistence | Surfaces today | Flags | PRIMARY | Secondaries | Action |
|---|---|---|---|---|---|---|---|
| C1 | Input device | Per camera, `selectedDevice` Store:259, `inputClearedByChoice` Store:261 | inspector Insp:98; panel MB:546-583 | d | Inspector | None | Remove MB:546-583. Rig setup is not needed with the window hidden, and each camera adds about seven rows. |
| C2 | Refresh inputs | Action `.refreshInputs` | inspector Insp:147; overlay Col:142; panel MB:578 | c f | Overlay (input disconnected state) | None | Hot-plug already updates the list (Model:485). Keep only the recovery button on Col:142. |
| C3 | Supported source formats | Per device, read-only | inspector Insp:115 | d | Settings › Cameras › device page | None | A device fact, not a camera setting. Move. |
| C4 | Signal state | Per camera, runtime | inspector Insp:120; strip badge Col:728; Feed:39; sidebar rows Side:65 | | Strip badge | Inspector | Keep. Display only. |
| C5 | Live timecode | Per camera, runtime | overlay Col:226; inspector Insp:134; panel card MB:706,720; Diagnostics Diag:128 | | Overlay | Inspector, Diagnostics, panel card | Keep. Display only. |
| C6 | Source profile | Per camera, `sourceProfileID` Store:271 | inspector Insp:247 (in the LUT section); popovers FC:48 "Camera log", reachable from False Color FC:143 and Picture Pic:76 | a d | Inspector, moved to Source | False Color popover | It declares the capture signal (Insp:251 says so), yet sits under LUT. Move. Remove the Picture popover copy. Keep the False Color copy because the mode depends on it. |
| C7 | Input code range | Per camera, `signal.range` Work:433 | popover FC:57 only, via FC:143 or Pic:76 (Log to Rec.709 mode) | d | Inspector › Source | None | Move. A camera declaration should not need a monitor tool open to be found. |
| C8 | Log transport | Per camera, `signal.transport` Work:435 | popover FC:64 only | d | Inspector › Source | None | Same as C7. |
| C9 | Legacy gamut text | Per camera, `gamut` Store:269; `.setGamut` UIAction:39 | None; no caller of `.setGamut` | b | Removed | None | Dead action. Delete once the migration no longer needs it. |
| C10 | Input connector | Per device, vendor policy, DeckLinkCapturePlugin:348 | Settings/Advanced Dev:13 | d | Settings › Cameras › device page | None | Rig setup filed under Advanced. Move. |
| C11 | Advertise HDR to cameras | Per device, vendor policy; legacy `ultracam.advertiseHDRToCameras` Store:559 | Settings/Advanced Dev:13 (HDMI connector only, DeckLinkCapturePlugin:468) | d | Settings › Cameras › device page | None | See "Advertise HLG". |
| C12 | Driver warning | Global, runtime Model:55 | Diagnostics Diag:251; start refusal text Model:1275 | b | Status warning | Diagnostics | A missing or old Desktop Video driver reaches the user only as a start refusal or in Diagnostics. Add to `warning()` Pres:818. |

### D. Effects and processing

| ID | Item | Scope, persistence | Surfaces today | Flags | PRIMARY | Secondaries | Action |
|---|---|---|---|---|---|---|---|
| D1 | Processing bypass | Per camera, `pipelineEnabled` Store:278 | strip Col:1046; inspector Insp:161; menu Camera Cmd:69 ⇧⌘B; panel MB:432, MB:532 | a | Strip | Inspector section switch, Camera menu, panel | Panel has it twice. Keep MB:532 per camera. Show MB:432 only with one camera. |
| D2 | Effect switches LUT, Resize, Color format, Frame-rate cap | Per camera, `applyLUT` `downscale` `convertTo420` `reduceFrameRate` Store:262-265 | strip chips Col:1080; inspector Insp:164; panel MB:538 | | Strip chips | Inspector rows, panel | Keep. Merge rows with D3 to D5. |
| D3 | Output size | Per camera, `resizeTarget` Store:266 | inspector Insp:174 | a | Inspector, on the Resize row | None | Second row for one effect; also force-enables it (Bridge:325). See "Effects". |
| D4 | Color format value | Per camera, `colorTarget` Store:267 | inspector Insp:189 | a | Inspector, on the Color format row | None | Same, Bridge:326. |
| D5 | Frame-rate cap value | Per camera, `frameRateTarget` Store:268 | inspector Insp:193 | a | Inspector, on the Frame-rate cap row | None | Same, Bridge:327. |
| D6 | Aspect, Fit or Crop | Per camera, `scalingMode` Store:272 | inspector Insp:184 | d | Inspector, sub-row of Resize | None | Applies only when resizing. Group it there. |
| D7 | Program color | Per camera, `programColorSpaceID` Store:275 | inspector Insp:178 | d | Settings › Program | None | Read only by `ProgramOutputRoute.swift:48`. No effect in Separate mode. One Program output takes it from whichever camera owns the contract (Model:1396-1410). Make it one Program setting. |
| D8 | Sync cameras | Rig, `syncCameras` Store:477 | Settings/Camera Set:307; sidebar Side:100; inspector Insp:158 | a d | Inspector, top of Effects | None | See "Sync cameras". |
| D9 | Output format readout | Per camera, runtime | Feed:17; inspector footer Insp:211; status Stat:253; Diagnostics Diag:119 | | Feed badge menu | Inspector, status, Diagnostics | Keep. Display only. |

### E. LUTs

| ID | Item | Scope, persistence | Surfaces today | Flags | PRIMARY | Secondaries | Action |
|---|---|---|---|---|---|---|---|
| E1 | Load or replace burn-in LUT | Per camera, `lutBookmark` Store:280 | inspector Insp:233; menu File Cmd:49 ⌘O; overflow Col:818; strip Locate Col:704; panel MB:545 | a | Inspector | File menu, strip Locate on error | Remove overflow Col:818 and panel MB:545. An open panel launched with the window hidden is not a hidden-window need. |
| E2 | Remove one camera's LUT | Per camera, `forgetLUT` Model:695, `.forgetLUT` UIAction:52 | None per camera; only the global Set:765 | b | Inspector › LUT | None | Add Remove LUT. Today the only way to clear one LUT clears all of them. |
| E3 | Forget all saved LUTs | Global action, confirms Set:756 | Settings/Advanced Set:720 | | Settings › Advanced | None | Keep. Also clears monitor LUTs (Set:769). |
| E4 | LUT input and output space | Per camera, `lutInputSpaceID` `lutOutputSpaceID` Store:273-274 | inspector Insp:255, Insp:258 | | Inspector › LUT | None | Keep. Show only with a LUT loaded. |
| E5 | Monitor LUT load, show, remove | Per camera, `monitorLUT` Work:42 | overflow Col:819 only; bulk forget Set:769 | d | Picture popover | None | The Picture popover is where the Monitor stage is chosen and explained, and it never mentions this LUT. Move there. |

### F. Output and Program

| ID | Item | Scope, persistence | Surfaces today | Flags | PRIMARY | Secondaries | Action |
|---|---|---|---|---|---|---|---|
| F1 | Output mode | Session, `outputMode` Store:470 | sidebar Side:97,582; menu Program Cmd:156; panel MB:395,468; Settings/Camera Set:343 | a f | Sidebar | Program menu, panel | Remove Set:343. It lacks Stop and Switch and uses a fourth label set. Lock is covered by another agent. |
| F2 | Stop Cameras and Switch | Action | sidebar Side:604; menu Program Cmd:167; panel MB:483 | | Sidebar | Program menu, panel | Keep, follows F1. |
| F3 | Published camera status | Runtime | sidebar Side:107,136; Settings/Camera Set:356; status Stat:243; strip Col:1101; panel card MB:660; subtitle Pres:788 | a c | Sidebar | Status popover, strip | Remove Set:356, an informational section. |
| F4 | Cut to camera | Per cut, `switcher.selectedFeedID` Store:166 | toolbar Tool:137-144; strip Col:1091; overflow Col:805; ProgView Prog:92, Prog:176-181; menu Program Cmd:178 ⌃1-4; panel MB:403, MB:528 | a | Toolbar | Program menu, panel, ProgView source tiles | Remove Col:805, Col:1091, MB:528 and the cut bar buttons Prog:115. Up to seven controls for one action. Removing Col:1091 also returns the output label to Program strips. |
| F5 | Automatic switching | Session, `switcher.automatic` Store:167 | toolbar Tool:112,119; sidebar Side:110; ProgView Prog:120; menu Program Cmd:184 ⌃⌥A; panel MB:407 | a | Toolbar | Program menu, panel | Remove Side:110 and Prog:120. |
| F6 | Switching strategy | Session, `switcher.strategy` Store:169, default manual | sidebar Side:116; ProgView Prog:125; toolbar Auto menu Tool:119; menu Program Cmd:192; panel MB:415; Settings/Switcher Set:433 | a c d | Sidebar | Program menu, panel, toolbar Auto menu, ProgView | Remove Set:433. It bypasses the bridge, so choosing Manual there leaves `automatic` true (Set:418 versus Bridge:366), and it offers a disabled Dynamic analysis row. |
| F7 | Hold current shot | Session, `manualHold` Store:61 | sidebar Side:125; ProgView Prog:135; menu Program Cmd:189; panel MB:412 | | Sidebar | Program menu, panel, ProgView | Keep. Add a shortcut. |
| F8 | Anchor camera | Session, `anchorFeedID` Store:44 | ProgView Prog:143; menu Program Cmd:203 | d | Sidebar, under Strategy | Program menu, ProgView | Absent from the sidebar, where the strategy that needs it lives. ProgView disables it unless Auto is on (Prog:157), the menu does not. |
| F9 | Emphasis camera | Session, `emphasisFeedID` Store:45 | ProgView Prog:149; menu Program Cmd:211 | d | Sidebar, under Strategy | Program menu, ProgView | Same as F8. |
| F10 | Shot timer | Runtime | sidebar Side:131; ProgView Prog:191 | | Sidebar | ProgView | Keep. |
| F11 | Recent cuts | Session, runtime, cap 20 Model:460 | status Stat:287 (5); ProgView Prog:230 (6); Diagnostics Diag:366 (all) | a | Status popover | ProgView, Diagnostics | Keep, but use one display length. |
| F12 | Format mismatch notice | Runtime `programFormatMismatch` Model:1628 | ProgView Prog:63; status Stat:278; Diagnostics Diag:327 | | Status popover | ProgView, Diagnostics | Keep. Display only. |
| F13 | Fixed interval | Global, `intervalSeconds` Store:168 | Settings/Switcher Set:440 | e | Settings › Program | None | Default disagrees: the model default is 5 s (Store:168,190), Restore Defaults writes 8 s (Set:528). Set:414 is also 8, overwritten on appear at Set:495. Use one constant. |
| F14 | Director mode | Global, `mode` Store:46, default transcript assisted | Settings/Switcher Set:442 | c | Removed | None | No transcript source exists: `ingestTranscript` (AutoSwitcherBridge:204) has no caller. Hide it and run low latency until one exists. |
| F15 | Shot timing: minimum, soft max, max, cooldown, emphasis hold, forced-cut grace | Global, Store:47-52 | Settings/Switcher Set:454-461 | | Settings › Program | None | Keep with the timeline graphic. |
| F16 | Advanced cut decisions, eight sliders | Global, Store:53-60 | Settings/Switcher Set:468-476 | c | Removed | None | Remove all eight from the UI, values stay as code defaults. Two are transcript-only, and any change recreates the running director (Model:805). |
| F17 | Restore switcher defaults | Action | Settings/Switcher Set:482 | | Settings › Program | None | Keep. |
| F18 | Director timeline sidecar | Automatic, AutoSwitcherTimelineRecorder | Footnote Set:485 | | Stays automatic | None | Keep. Written beside the default folder only (Model:904). |

### G. Recording

| ID | Item | Scope, persistence | Surfaces today | Flags | PRIMARY | Secondaries | Action |
|---|---|---|---|---|---|---|---|
| G1 | Record or stop one camera | Per take | strip Col:861, Col:1161; overflow Col:810; toolbar Tool:191,200; menu Record Cmd:113 ⌘R; panel MB:383,518 | a | Strip | Toolbar, Record menu, panel | Remove overflow Col:810. |
| G2 | Record All, Stop All | Per take | toolbar Tool:191,210; menu Record Cmd:118,122 ⌥⌘R; panel MB:383-389; status Stat:350 | e | Toolbar | Record menu, panel, status | Stop All has no confirmation (UIAction:107-127), one key from ⌘R. See E-list item 5. |
| G3 | Pause or resume one camera | Per take | strip Col:951; overflow Col:815; menu Record Cmd:125 ⇧⌘R; panel MB:520 | a | Strip | Record menu, panel, collapsed-strip overflow | Remove overflow Col:815 on expanded strips; keep it on collapsed strips. ⇧⌘R exists only during a take, so its item is absent otherwise. |
| G4 | Pause All, Resume All | Per take | menu Record Cmd:134-136 | d | Record menu | Panel | Add a panel row: pausing during a meeting is the hidden-window case. Add a shortcut. |
| G5 | Recording codec | Global, not per camera. NOT persisted: Rec:633 plain var, no key anywhere | Settings/Recording Set:190 (only setter); sidebar read-only Side:155; strip read-only Pres:619 | b d | Sidebar › Recording | Record menu › Format | Top gap. See "Recording codec and timecode". |
| G6 | Timecode mode | Global. NOT persisted: Rec:659 plain var | Settings/Recording Set:196 (only setter); sidebar read-only Side:155 | b d | Sidebar › Recording | Record menu › Timecode | Same. |
| G7 | File name pattern | Fixed, RecordingOutputManager:361 | read-only preview Set:200,246 | e | Settings › Recording | None | No options, and the preview is wrong: real names end in a UUID. |
| G8 | Camera subfolder per take | Fixed, RecordingOutputManager:347 | None | e | Settings › Recording | None | Add a Subfolder by camera toggle, on by default. |
| G9 | Default recording folder | Global, `recordingFolderBookmark` RecordingRecovery:235 | sidebar Side:175; menu Record Cmd:140; Settings/Recording Set:142 | | Sidebar | Record menu, Settings › Recording table | Keep. Settings stays as the one all-cameras view. |
| G10 | Clear default folder | Action; `.clearDefaultFolder` UIAction:80 unused, Set:152 writes directly | Settings/Recording Set:152 | | Settings › Recording | None | Keep. Route it through the action. |
| G11 | Per-camera folder | Per camera, `recordingFolderBookmark.feed.<id>` RecordingRecovery:235 | Settings/Recording Set:172; inspector Insp:282; overflow Col:820-822; strip recovery Col:961,966,981 | a | Inspector | Settings › Recording table, strip recovery buttons | Remove overflow Col:820-822. |
| G12 | Show recordings in Finder | Action | menu Record Cmd:141; panel MB:447; status Stat:345; strip Col:958,968 (saved take); Settings/Recording Set:150 | | Record menu | Panel, status, strip | Keep. |
| G13 | Recent takes | Runtime, limit 5 UISupport:83 | sidebar Side:183 | | Sidebar | None | Keep. |
| G14 | Drive space and time left | Runtime | sidebar Side:159; strip Col:1004; inspector Insp:300; status Stat:343; panel MB:286; Settings/Recording Set:156 | a | Sidebar | Strip, status, panel | Remove Insp:300 and Set:156. |
| G15 | Low-space warning | Fixed 30 min, Pres:830 and Side:318 | status, panel, sidebar via `warning()` | e | Settings › Recording | None | Make it a setting. Fix the duplicated literal. |
| G16 | Recover interrupted takes | Runtime, journals | sidebar Side:205-219; Settings/Recording Set:221 and sheet Set:265; menu Record Cmd:144 | a d | Sidebar | Record menu | Remove the Settings section and sheet. Cmd:144 opens Settings and posts `UIShowRecovery`, which only a mounted Recording tab receives (Set:241). It should reveal the sidebar section instead. |
| G17 | Constant frame rate | Per camera, `recordingConstantFrameRate` Store:277 | inspector Insp:276, only while a variable-rate source runs (Pres:134) | d | Inspector › Recording | None | See "Recording constant frame rate". |
| G18 | Variable-rate quantization | Per take, default `.nearest240000` Rec:74 | None | b | Stays fixed | None | No audience. Keep in code. |
| G19 | Backup recording | Not built | Settings/Recording Set:209; sidebar Side:258 | c | Removed | None | Remove both rows. Text in `.constant(false)` is a promise, not a control. |
| G20 | Take readout: size, drops, notes, audio | Runtime | strip Col:883-925; status Stat:314; Diagnostics Diag:161; panel submenu MB:503 | | Strip | Status, Diagnostics | Keep. |
| G21 | Allow CPU conversion | Global, `ultracam.allowCPUConversion` Store:558,583 | Settings/Advanced Set:694 | | Settings › Advanced | None | Keep. |

### H. Monitor tools (per camera, in `FeedDescriptor.monitor`, or `programMonitor` for Program)

| ID | Item | Scope, persistence | Surfaces today | Flags | PRIMARY | Secondaries | Action |
|---|---|---|---|---|---|---|---|
| H1 | Guides on or off | Per camera, `state.guides.enabled` | overlay Bar:129; overlay menu Bar:91; popover Bar:299; menu View Cmd:264; detached Det:288 | | Overlay tool bar | View menu | Keep. Add a shortcut. |
| H2 | Guide settings: frame, style, matte, safe areas, grids, center, color, opacity, contrast, width | Per camera, `state.guides` | popover Forms:29-92; detached Det:286 | | Guides popover | Detached | Keep. |
| H3 | Zebra on or off | Per camera, `state.zebras` | overlay Bar:129; overlay menu Bar:91; menu View Cmd:264; detached Det:288 | | Overlay tool bar | View menu | Keep. Add a shortcut. |
| H4 | Zebra sets 1 and 2 | Per camera | popover Forms:167-197 | | Zebra popover | Detached | Keep. |
| H5 | False color on or off, mode | Per camera, `state.falseColor.mode` | overlay Bar:129; popover FC:103; menu View Cmd:264; detached Det:288 | | Overlay tool bar | View menu | Keep. Add a shortcut. |
| H6 | False color signal, unit, offset, custom bands | Per camera | popover FC:112-208 | | False Color popover | Detached | Keep. |
| H7 | Focus peaking on or off | Per camera, `state.focus.enabled` | overlay Bar:129; popover Bar:300; menu View Cmd:264; detached Det:288 | | Overlay tool bar | View menu | Keep. Add a shortcut. |
| H8 | Focus style, color, sensitivity, noise, opacity | Per camera | popover Forms:208-233 | | Focus popover | Detached | Keep. |
| H9 | Scopes on or off | Per camera, `scopes.enabled` Work:476 | overlay Bar:129; popover Bar:301; menu View Cmd:268 ⌥⌘K; detached Det:293 | | Overlay tool bar | View menu | Keep. |
| H10 | Scope kind, signal, matrix, look, scale, zoom, targets, gain, graticule, clip readout | Per camera, `scopes.settings` | popover Scope:61-80; detached Scope:51-58 via Det:299 | | Scopes popover | Detached | Keep. |
| H11 | Scope refresh rate 10, 15, 30 Hz | Per camera, `scopes.refreshHz` Work:478 | None. Consumed at MonitorSurface:1398,1610 | b | Settings › Monitoring | None | Add. Scope:8 and Set:673 say scopes follow every frame, while the cap defaults to 15 Hz. |
| H12 | Clip indicators on or off | Per camera, `state.clipIndicators.enabled` | overlay Bar:136; overlay menu Bar:95; popover Bar:303; detached Det:288 | d | Overlay tool bar | View menu | Add to View › Monitor Tools: `UIMonitorTool` omits it (Pres:45-46), so it has no menu command. |
| H13 | Clip indicator settings | Per camera | popover Forms:252-297 | | Clip popover | None | Keep. |
| H14 | Picture stage | Per camera, `state.pictureStage` | overlay Col:293; popover Pic:46; detached Det:275 | a | Overlay stage menu | Detached | Remove Pic:46. Keep its caption as the stage menu's help. |
| H15 | Display transform, PQ peak | Per camera, `state.displayTransform` | popover Pic:59-71 | | Picture popover | Detached | Keep. |
| H16 | De-squeeze, flip | Per camera, `state.geometry` | popover Pic:81-90 | | Picture popover | Detached | Keep. |
| H17 | Display adjustments | Per camera, `state.display` | popover Pic:96-111 | | Picture popover | None | Keep. |
| H18 | Zoom | Per surface, not persisted, Col:56 | overlay Col:370; detached Det:179 | | Overlay | Detached | Keep. Pic:91 caption only points to it. |
| H19 | Freeze | Per surface | overlay Col:367; ctx Col:408; menu View Cmd:255 ⌃⌥F; detached Det:95 | | Overlay | ctx, View menu, detached | Keep. |
| H20 | Clean View | Per surface | overlay Col:368; ctx Col:410; menu View Cmd:259 ⌃⌥C; detached Det:96 | | Overlay | ctx, View menu, detached | Keep. Hold Clean exists only at Det:100. |
| H21 | Detach to window | Action, windows not restored | overlay Col:389; ctx Col:423; detached Det:114 | d | ctx | View menu | Add a View command. Remove overlay Col:389 to thin the hover row. |
| H22 | Reset monitor tools | Action | ctx Col:411; detached Det:138 | | ctx | View › Monitor Tools | Add the menu command. |
| H23 | Copy monitor settings | Action | ctx Col:412 "Copy Settings To"; overflow Col:824 "Copy Monitor Settings To"; detached Det:139 | a | ctx | None | Remove overflow. Use one label: Copy Monitor Tools To. |
| H24 | Monitor tools master switch | Per camera, `toolsEnabled` Work:32 | None. Follows `anyToolOn` (UISupport:171). Set:664 and comments call it a switch | b | View › Monitor Tools › Hide All | None | Add. Today hiding tools means turning each off. |
| H25 | Monitor workspace layout, tile bindings, split ratio | Persisted, `monitorWorkspace` Store:476, Work:513 | None. Set once by MonitorCoordinator:262-269 | b | Removed | None | Leftover of the old workspace. No UI writer found. Delete after migration. |
| H27 | Detached window target | Per window | detached Det:264 | | Detached | None | Keep. The only way to point a detached monitor at another camera. |
| H26 | Monitor pane prose | Static | Settings/Monitor Set:660-681 | c | Removed | None | Move the useful sentences to Help. |

### I. Audio

| ID | Item | Scope, persistence | Surfaces today | Flags | PRIMARY | Secondaries | Action |
|---|---|---|---|---|---|---|---|
| I1 | Strip level meter | Runtime | strip Col:679; collapsed strip Col:1155; panel card MB:721 | | Strip | Panel card | Keep. |
| I2 | Full meter panel, R 128, phase | Runtime | status Stat:365; Diagnostics Diag:154,222 | | Status popover | Diagnostics | Keep. |
| I3 | Reset peaks and loudness | Action inside MonitorKit view, text UIAudioMeterPanel:66 | status popover and Diagnostics meters | | Status popover | None | Keep. Only documented by a caption. |
| I4 | Audio over and attention level | Fixed −1 dBTP, AudioMeterTapDisplay:43-44,169 | strip note Pres:664; status Stat:330 | e | Settings › Monitoring | None | Make it a setting. See E-list. |
| I5 | Meter type and scale | Fixed, UIAudioMeterPanel:23-26 says one standard meter | All meters | | Stays fixed | None | Deliberate. Keep. |
| I6 | Audio status segment | Runtime Pres:769-775 | status Stat:357 | | Status | None | Keep. |

### J. Camera control

| ID | Item | Scope, persistence | Surfaces today | Flags | PRIMARY | Secondaries | Action |
|---|---|---|---|---|---|---|---|
| J1 | Assign, connect, disconnect, sign in | Per camera, `ui.camera.controls.v1` CameraControlStore:20, Keychain | sheet Ctl:17, opened from strip Col:667, inspector Insp:35, Feed:34 | a | Inspector | Feed badge | Remove the strip row Col:665-671: the badge beside it opens the same sheet. |
| J2 | Camera properties | Per camera, on the camera | sheet Ctl:114, vendor factory Ctl:66 | | Camera Control sheet | None | Keep. |
| J3 | Output timing | Per camera, on the camera | Feed:21; sheet Ctl:115 | | Feed badge | Camera Control sheet | Keep. |
| J4 | Camera display (HDMI OSD) | Per camera, on the camera | strip Col:1058 | | Strip | None | Keep. Comment explains why it is not in the sheet. |
| J5 | Show camera settings over picture | Per camera, `showOverlay` CameraControlStore:6 | sheet Ctl:103; drawn at Col:218 | d | ctx | Camera Control sheet | A per-session view choice three clicks away. Add to ctx. |
| J6 | Forget saved sign-in | Per camera, Keychain | sheet Ctl:144 | | Camera Control sheet | None | Keep. Reset does not clear it: `credentials.delete` runs only from this action (CameraControlStore:396), not from `reset()` (:289). |
| J7 | Reconnect at launch | Fixed, App:24 | None | | Stays automatic | None | Keep. |

### K. Camera extension

| ID | Item | Scope, persistence | Surfaces today | Flags | PRIMARY | Secondaries | Action |
|---|---|---|---|---|---|---|---|
| K1 | Install or update extension | Machine | sidebar banner Side:455,467; Settings/Camera Set:315; Help:6 | | Settings › Cameras | Sidebar banner when action is needed | Keep. |
| K2 | Remove extension | Machine. `.removeCameraExtension` UIAction:95 unused, Set:316 calls installer directly | Settings/Camera Set:316 | | Settings › Cameras | None | Keep. Route it through the action. |
| K3 | Approve in System Settings | Machine | sidebar Side:478; Settings/Camera Set:326 | | Sidebar banner | Settings › Cameras | Keep. |

### L. Diagnostics, Help, status, reset

| ID | Item | Scope, persistence | Surfaces today | Flags | PRIMARY | Secondaries | Action |
|---|---|---|---|---|---|---|---|
| L1 | Open Diagnostics | Action | overflow Col:830; strip Details Col:971; status Stat:203; Settings/Advanced Set:705; Window menu per comment Cmd:275 | a c | Window menu | Status, strip Details | Remove Set:705 (link only) and overflow Col:830. Add a shortcut. |
| L2 | Copy Diagnostics | Action | Diagnostics Diag:40; Settings/Advanced Set:706 | a | Diagnostics | None | Remove Set:706. |
| L3 | App resource use | Runtime | status Stat:167; panel MB:278; Diagnostics Diag:386 | | Status | Panel, Diagnostics | Keep. |
| L4 | Warnings | Runtime `warning()` Pres:818 | status segment; panel MB:349; menu bar icon Pres:915 | | Status | Panel | Keep. |
| L5 | Help window | Static | menu Help Cmd:289 ⌘? | | Help menu | None | Keep. Update for moved settings. |
| L6 | Reset all settings | Action, confirms UIAction:114 | Settings/Advanced Set:731 | | Settings › Advanced | None | Keep. `recordingRecoveryRootBookmarks` (Store:574-578) and Keychain sign-ins (J6) survive it, though Set:740 reads as if everything goes. |
| L7 | Tally and on-air rule | Fixed Pres:520-529 | ring Col:88; badges; toolbar; panel | | Stays fixed | None | Keep. See E-list. |

### P. Panel changes in one place

| ID | Item | Scope, persistence | Surfaces today | Flags | PRIMARY | Secondaries | Action |
|---|---|---|---|---|---|---|---|
| P1 | Panel top-level selected-camera rows | Runtime | MB:374, MB:432, MB:436 act on the selected camera, shown as a subtitle only with several cameras | d | Per-camera submenu MB:498 | None | The panel cannot change the selection, so these rows reach one camera only. Move them into each camera's submenu. Keep them top level only with one camera. |

## Findings by flag

### a. Duplicated beyond what the rule allows

The ⋯ overflow menu is the largest single source: it repeats Show Inspector, Cut, Record, Pause, Load LUT, Choose Folder, Copy Monitor Tools, Rename, Diagnostics, Start or Stop and Remove (Col:801-837). With the removals in the table nothing unique is left on an expanded strip, so the ⋯ goes there.

It stays on the collapsed strip with two items, Pause or Resume and Start or Stop, because a collapsed strip has no other control for them (Col:1126-1168), and Four Up and Program View force every strip collapsed (Pres:672).

Rows flagged: A1, A6, A11, B2, B4, B5, B7, B11, C6, D1, D3, D4, D5, D8, E1, F1, F3, F4, F5, F6, F11, G1, G3, G11, G14, G16, H14, H23, J1, L1, L2.

### b. In code, not in the UI

| Row | What | Decision |
|---|---|---|
| G5, G6 | Codec and timecode are in the UI but not saved. Listed here because the persistence half does not exist | Persist |
| H11 | Scope refresh rate | Add to Settings › Monitoring |
| E2 | Remove one camera's LUT | Add to the inspector |
| H24 | Monitor tools master switch | Add View › Monitor Tools › Hide All |
| C12 | Driver warning has no status presence | Add to `warning()` |
| B6 | Camera enabled flag | Delete, do not expose |
| C9 | Legacy gamut text and `.setGamut` | Delete |
| H25 | Monitor workspace preferences | Delete |
| G18 | Variable-rate quantization policy | Stay fixed |

Unused actions with no caller: `selectNumber`, `cutNumber`, `setGamut`, `clearDefaultFolder`, `removeCameraExtension`. `forgetLUT` is sent by nothing; Set:765 calls the model directly. `recover` and `installCameraExtension` are bypassed by Settings (Set:281, Set:315). The header comment at UIAction:3-5 says views never call the models directly; Set:135-136, Set:152, Set:307, Set:315-316, Set:418-423 and Set:694 all do. Settings is where the F6 bug comes from.

### c. UI without purpose

| Row | What | Decision |
|---|---|---|
| G19 | `Toggle(isOn: .constant(false))` Set:209 and the sidebar "Coming later" row Side:258 | Remove both |
| F6 | "Dynamic analysis (Coming later)" Set:437 | Remove, with the Settings strategy picker |
| H26 | Settings › Monitor has no controls, Set:660 | Replace with real controls |
| A6 | Settings Layout mirrors the live layout | Remove |
| A7 | New camera strips | Remove |
| F3 | Published Cameras section | Remove |
| F14 | Director mode with no transcript source | Hide |
| F16 | Eight expert sliders | Remove from UI |
| B8 | Sidebar Automation row, a link to the inspector | Remove |
| L1 | Settings Open Diagnostics, a link | Remove |
| C2 | Refresh Inputs with hot-plug present | Keep only the recovery button |

### d. Wrong cadence

Too deep for how often it changes: G5 and G6 codec and timecode (per session, in Settings), H12 and H21 (monitor actions with no menu command), J5 (overlay toggle in a sheet), G4 (Pause All with no panel row), F8 and F9 (Anchor and Emphasis only in Program View and a menu).

Too shallow for how rarely it changes: D8 (Sync in the live sidebar), C1 (Input in the panel).

Set per session but also placed in Settings: A6 layout, F6 strategy.

Filed in the wrong group: C6 Source profile under LUT, C7 and C8 camera declarations inside monitor popovers, C10 and C11 rig setup under Advanced, D6 Aspect, D7 Program color, E5 Monitor LUT in overflow, C3 device facts per camera, G16 recovery in Settings.

### e. Hardcoded values: the E-list

| # | Value | Where | Decision |
|---|---|---|---|
| 1 | Codec and timecode default on every launch, ProRes 422 HQ and Mac Clock | Rec:633,659 | Persist. Not optional. |
| 2 | File name `<camera>_<yyyy-MM-dd_HH-mm-ss>_<NNN>_<UUID>.mov` | RecordingOutputManager:361,387 | Setting: Name pattern with tokens camera, date, time, take. Drop the UUID from the visible name and resolve collisions with the existing `-2` suffix (:362-368). |
| 3 | Camera subfolder always created | RecordingOutputManager:347 | Setting, on by default. |
| 4 | Low-space warning at 30 minutes | Pres:830, Side:318 | Setting: 15, 30 or 60 minutes. One constant. |
| 5 | Confirmation set: Stop Camera, Stop All Cameras, Remove, Reset only | UIAction:107-127 | Setting, Settings › General: Ask before ending a recording or on-air video, on by default. Extends today's prompts to Stop All Recordings and Quit. Plain ⌘R on one camera stays unprompted. |
| 6 | True-peak attention level −1 dBTP | AudioMeterTapDisplay:43-44,169 | Setting: −1, −2 or −3 dBTP. A Zoom mix and a broadcast deliverable want different warnings. |
| 7 | Fixed interval default 5 s or 8 s | Store:168,190; Set:528 | One constant, 8 s. Value remains a setting. |
| 8 | Scope refresh default 15 Hz | Work:478 | Already data, needs UI. |
| 9 | Program color per camera | Store:275 | One Program setting. |

Keep hardcoded, with reasons:

| Value | Where | Why it stays |
|---|---|---|
| Fragments 1 s then 10 s | AVAssetSourceRecordingWriter:1944-1945 | Crash-safety tuning. Nobody chooses this per rig. Move the prose in Set:233 to Help. |
| 128 MB free floor, 256 MB nearly full | RecordingOutputManager:108, Pres:904 | Safety margins. |
| Tally rule: on air means a client is connected | Pres:520-529 | D8 made red mean on air or recording. An option would weaken it. |
| Meter scale and type | UIAudioMeterPanel:23-26 | Stated design: one standard meter. |
| Recent takes 5, recent cuts 20 | UISupport:83, Model:460 | Display limits. Align the two cut lists (Stat:290, Prog:239). |
| Minimum shot floor 10 s | Set:456, Store:109 | Slider and decoder agree. Change both only if the owner asks. |
| New camera defaults 1080p, 4:2:0 8-bit, 29.97 | Store:306 | Copy Monitor Tools and Sync cover rig matching. |
| No delay before automatic stop | AutomaticFeedPolicy:63 | Capture stops as soon as the last client leaves. Watch for restart churn when an app switches cameras; add a delay only if it shows up. |

### f. Locks to review

Output mode is excluded; another agent covers it.

| Lock | Where | Verdict |
|---|---|---|
| Add Camera needs all cameras stopped | `canEditTopology` Model:129, Side:84, Cmd:101 | Review. Model:1057-1059 says the extension keeps existing devices until clients release them, so adding a device may be safe live. |
| Remove Camera needs all cameras stopped | Insp:55, Col:838, Cmd:106 | Review. Removing an idle camera while another runs looks safe for the same reason. |
| Rename needs all cameras stopped | Insp:50, Col:828, Cmd:80 | Review. In Program mode feed names are not published (FeedRuntime:606-612), so the lock has no device reason there. In Separate mode the published name changes (VirtualCameraRegistryPublishing:23). |
| Refresh Inputs disabled while this camera runs | Insp:149 | Unnecessary. The panel row has no such lock (MB:578). Goes away with C2. |
| Collapse All disabled in Four Up and Program View | Tool:68, Cmd:237 | Those layouts force collapsed strips (Pres:672). Hide the control rather than disable it. |
| Input change while running | Insp:112, Model:1557 | Keep. Necessary. |
| Extension install or remove while running | Set:318 | Keep. macOS replaces the extension. |
| Reset while running | Set:735 | Keep. |

Opposite case: Input connector and Advertise HDR have `interruptsCapture: true` and no lock or prompt. A change on the Advanced pane can drop the signal on a live camera with only a caption (Dev:32). Ask first when the device is in use.

## Shortcuts

| Key | Command | Handler | In Help | Note |
|---|---|---|---|---|
| ⌘↩ | Start or stop cameras | Cmd:88 | Help:13 | |
| ⌘1-4 | Select camera | Cmd:95 | Help:21 | Only with 2+ cameras; first four only (Cmd:93) |
| ⌘O | Load LUT | Cmd:52 | Help:29 | |
| ⌘Q | Quit | Cmd:45 | No | Standard |
| ⌘0 | Show Main Window | Cmd:284 | Help:30 | |
| ⌘, | Settings | system | Help:31 | |
| ⌘? | Help | Cmd:290 | No | Standard |
| ⌘R | Record or stop selected | Cmd:114 | Help:16 | |
| ⌥⌘R | Record All or Stop All | Cmd:119,123 | Help:18 | Ends every take with no prompt |
| ⇧⌘R | Pause or resume selected | Cmd:129 | Help:17 | Item exists only during a take |
| ⇧⌘B | Processing | Cmd:71 | Help:14 | |
| ⇧⌘P | Video Preview | Cmd:74 | Help:15 | |
| ⌃1-4 | Cut | Cmd:179 | Help:19 | Collides with Mission Control, documented at Help:59 |
| ⌃⌥A | Automatic Switching | Cmd:185 | Help:20 | VoiceOver |
| ⌥⌘1-4 | Layout | Cmd:226 | Help:22 | ⌥⌘3 disabled outside Program mode |
| ⌃⌘S | Sidebar | Cmd:231 | Help:23 | |
| ⌥⌘S | Collapse strips | Cmd:235 | Help:24 | |
| ⌥⌘I | Inspector | Cmd:239 | Help:26 | |
| ⌥⌘K | Scopes | Cmd:268 | Help:25 | Only monitor tool with a key |
| ⌃⌥F | Freeze | Cmd:257, Det:95 | Help:27 | VoiceOver; also detached |
| ⌃⌥C | Clean View | Cmd:261, Det:97 | Help:28 | VoiceOver; also detached |

Collisions:

1. ⌃1-⌃4 against Mission Control desktops. Documented, and the toolbar is the fallback. Keep.
2. ⌃⌥ is the VoiceOver modifier, so ⌃⌥A, ⌃⌥F and ⌃⌥C do not reach Ultracam while VoiceOver runs. Keep them: every one has a menu item, which is the VoiceOver path.
3. ⌃⌥F and ⌃⌥C are bound twice: View menu acting on the selected camera, and the focused detached window (Det:95,97). Which wins needs a runtime check; the code alone cannot say.
4. Panel key equivalents (MB:370, 383, 403, 407, 432, 437, 451, 452, 462) work only while the panel is open, by AppKit behaviour. They read as global. Keep them as menu convention, but do not treat them as hidden-window shortcuts: Ultracam has no global hotkeys.

No duplicate key equivalent exists inside the app menus, as the claim at Cmd:6 says. Help lists all of them except the two standard ones.

Missing, proposed:

| Command | Key |
|---|---|
| Hold Current Shot | ⌃⌥H |
| Pause All | ⌥⌘P |
| Guides | ⌥⌘G |
| Zebra | ⌥⌘Z |
| False Color | ⌥⌘L |
| Focus Peaking | ⌥⌘F |
| Clip Indicators | ⌥⌘X |
| Diagnostics | ⌃⌥D (⌥⌘D is the system Dock toggle) |

Every proposed key needs a menu item, which H12 and L1 add.

## Named specifics

### Sync cameras

Three surfaces: Set:307, Side:100, Insp:158. All call `setSyncCameras`. Global, saved as `syncCameras`.

Decision: inspector only, at the top of Effects, with a confirmation when turning it on that names the source camera: "Copy Camera 1's effects to Camera 2?"

Why not the sidebar: turning it on immediately rewrites every other enabled camera's effects (Model:145-153, Model:155-180), which can renegotiate a live virtual camera, and there is no prompt. One stray click in the live panel changes what a meeting sees. Why not Settings: the operation copies from the selected camera, and Settings does not show which that is. A rig setting would normally go to Settings; this one needs the selection in view. While Sync is on, the inspector shows "Editing all cameras".

Also fix: Sync copies `previewEnabled` (Model:179) although the descriptions say only inputs and folders stay separate, and it does not copy `recordingConstantFrameRate`. State the copied set in one place.

### Output mode

Four setters: Side:582, Cmd:157, MB:472, Set:343. Three label sets for the same value: "Separate (ISO)" (Side:509), "Separate Cameras (ISO)" (Cmd:158), "Separate cameras" (Set:344), and a fourth in Stat and Pres text. Settings is the only one with no Stop and Switch. Decision: sidebar primary, Program menu and panel secondary, Settings removed, one label from `UIOutputModeControl.title`.

### Start with camera apps

Per camera. Set at Insp:313 and MB:374. The panel row changes only the selected camera (P1). The sidebar row shows names and opens the inspector, and cannot set anything. It is not in Settings, and should not be: it is per camera. Decision in B8. The main-window state that matters, a camera waiting for an app, is already on the strip badge and menu bar icon (Pres:920).

### Recording codec and timecode

- **Where they can be changed:** Settings › Recording only (Set:190, Set:196).
- **Scope:** global. One value on `RecordingModel`, copied into each take at `record()` (Rec:864). Not per camera.
- **Persistence: none.** `codec` (Rec:633) and `timecodeMode` (Rec:659) are plain properties with no `didSet`. They are not in `AppSettingsSnapshot` (Store:464-478), and a search of `Sources` finds no defaults key for either. Every launch returns to ProRes 422 HQ and Mac Clock. Tests/RecordingModelChecks:550-551 set them only in memory. Anyone recording HEVC silently records ProRes after a restart, at many times the size. The sidebar shows the value (Side:155), so it is visible, but nothing warns.
- **Global setting filtered by one camera:** the codec list follows the selected camera's source (Set:133-134), while the choice applies to every camera. With mixed sources a valid choice for one can fail another. Each take validates its own source (footer Set:204). Show the refusal on the failing strip before Record, not after.
- **Naming drift:** `RecordingTimecodeMode.title` says "PC time" (Rec:50), UI says "Mac Clock" (Bridge:452). Delete the unused one.

Decision, following the owner: sidebar Recording section gets two compact pickers, Format and Timecode, replacing the read-only line at Side:155. Same pickers under Record › Format and Record › Timecode. A change applies to the next take, which is how it already works. Add `recordingCodec` and `recordingTimecode` to the snapshot. Settings loses both. Keep them global: a per-camera override adds a surface for a problem the validation already catches.

### File naming

There are no options. The Settings preview is also wrong. Set:246-251 shows `Camera 1/Camera 1_<date>_001.mov`, while the real stem is `\(feedID)_\(timestamp)_\(take)_\(sessionID.uuidString)` (RecordingOutputManager:361), so every file ends in a 36-character UUID. The `_001` is not a take number per camera: it comes from `pathNonce` (RecordingOutputManager:201,358), shared by every camera using that folder, and it restarts each launch.

### Recording constant frame rate

Per camera, saved. One toggle at Insp:276, shown only when `sourceFrameRate?.isVariable` (Pres:134). `sourceFrameRate` comes from the live update (Bridge:144), which is nil unless the camera runs. So the setting disappears when the camera stops and cannot be set before the first take, and a variable-rate source may not exist on a Blackmagic rig at all. Decision: stays in Inspector › Recording, always visible once the camera's input has ever reported a variable rate, or when the saved value is on. A saved-on setting must never be invisible.

### Advertise HLG

The label in the code and UI is "Advertise HDR to cameras" (DeckLinkCapturePlugin:375). "HLG" survives only in a dangling comment at Store:593 with nothing under it. It is a per-device DeckLink vendor setting, saved in vendor policy, seeded once from the legacy key (VendorSettingsStore:22-25). Live control: Settings › Advanced › Input device settings (Dev:13), shown only when the connector is HDMI (DeckLinkCapturePlugin:468), `interruptsCapture: true`. Decision: Settings › Cameras › device page, next to Input connector. Keep the name that matches what the setting does; which HDR formats it adds is covered by the vendor audit. Remove the dangling comment.

### Default layout

Not a default. See A6. Removed. Last-used layout already restores.

### Collapse strip default

Works as described but has no purpose. See A7. Removed.

### Effects section overlap

The inspector shows four checkboxes and then, further down, three pickers for the same effects under different names: Resize and Output size, Color format twice, Frame-rate cap twice (Insp:163-196). Picking a value also ticks the box (Bridge:325-327), so a picker silently turns an effect on. Aspect and Program color sit between them and are not effects. The strip chips already show one control per effect: the value is the label (Pres:634).

Decision, one row per effect:

```
Effects                          Processing (on)
Sync cameras                               (off)
[x] 1  LUT             Cine709       Change…
[x] 2  Resize          1080p  ▾     Fit  ▾
[x] 3  Color format    4:2:0 8-bit  ▾
[x] 4  Frame-rate cap  29.97  ▾
```

The checkbox turns the effect on or off. The value is disabled while off, and choosing a value no longer changes the checkbox. Aspect lives on the Resize row. Program color leaves (D7). Source profile moves to Source (C6). LUT spaces stay in a LUT section under Effects, shown only with a LUT loaded.

## Proposed Settings structure

### Sidebar or tabs

**Decision: sidebar-navigated window, like System Settings.**

After the moves there are about 25 fixed controls plus two to three per device and one per camera, in six panes, which six tabs could hold. Count alone does not decide it. These do:

1. **Input devices are a variable list.** The Mac Studio rig has two UltraStudios, each with its own connector and HDR settings. Today they stack as a list inside one Advanced section (Dev:8). In a sidebar each device is a row under Cameras, and appears when connected.
2. **Tab heights are hardcoded because panes vary.** 400, 700, 430, 660, 360, 520 pt (Set:110, 238, 370, 490, 679, 749). The window jumps by up to 340 pt between tabs, and any pane over its number scrolls inside a fixed frame. In the Recording screenshot the content is already cut at 700 pt. A sidebar window keeps one size and scrolls the detail, so per-tab heights go away.
3. **Width.** 640 pt (Set:27) forces the Switcher sliders and folder rows to truncate. A fixed 780 × 560, resizable in height, gives the detail about 560 pt.

Cost: the Settings scene gets no free toolbar tabs, and the window needs its own `NavigationSplitView` with the sidebar always visible and its toggle removed. Worth it.

### Panes

| Pane | Moves in | Moves out | Layout |
|---|---|---|---|
| **General** | Ask before ending a recording or on-air video (new). Stays: Show Ultracam in, Open at login | Layout, New camera strips, the Hide preview footnote | One grouped form, one section. Nothing scrolls. |
| **Cameras** | Input connector, Advertise HDR, Supported source formats (per device). Extension stays | Sync cameras, Output mode, Published Cameras | Parent page: Camera Extension section with status row and Install, Update, Remove; approval row only when needed. Under it in the sidebar, one child row per connected device. Device page: connector, HDR, formats, caution text, and a prompt when `interruptsCapture` and in use. |
| **Recording** | Name pattern, Subfolder by camera, Low-space warning (new). Folder table stays | Codec, Timecode, Automation, Crash Recovery, drive meter | Section Folders: one table, Default first, then every camera, each with path, Choose and Use Default. Section File Names: pattern tokens and a live preview generated by the same function the writer uses, so it cannot drift. Section Warnings: low space. Footer points to the sidebar for format. |
| **Program** | Output color (D7), Fixed interval. Stays: shot timing, timeline graphic, Restore Defaults | Strategy, Director mode, Advanced cut decisions | Section Output: Output color. Section Fixed Interval: one slider. Section Natural Talking Head: timeline graphic above six sliders. These are always enabled, since a set-once choice should not depend on the session's strategy. |
| **Monitoring** | Scope refresh, Audio warning level (new) | All Monitor prose, to Help | Section Scopes and Section Audio, one control each. Short on purpose: it replaces a pane with no controls. |
| **Advanced** | Nothing | Input device settings, Open Diagnostics, Copy Diagnostics | Three rows: Allow CPU conversion, Forget Saved LUTs, Reset. Reset last and alone. |

All panes: `.formStyle(.grouped)`, no fixed heights, one footnote per section at most, explanations in `.help` rather than footers. Update Help:6, which names Settings › Camera, and the footers that mention the removed rows.

## Resulting main window and panel

**Sidebar:** Cameras. Output (mode, published cameras, and in Program: Strategy, Hold, Anchor, Emphasis, shot timer). Recording (state, Format, Timecode, drives, default folder). Recent Takes. Interrupted Takes. Loses Sync cameras, Auto switching, Automation.

**Inspector:** header. Source (Input, Signal, Timecode, Source profile, Code range, Log transport). Camera Control. Effects (merged). LUT (spaces, Remove). Recording (folder, Constant frame rate). Automation (Start with camera apps). Rename and Remove. Loses Video preview, Supported source formats, time left, Retry.

**Strip:** loses the Camera Control row and the Cut button. The ⋯ menu goes from expanded strips and stays on collapsed strips with Pause or Resume and Start or Stop.

**Panel:** problems, Start or Stop, Record, Pause All (new), Output, Cut rows, Automatic Switching, Hold, Strategy, per-camera submenus (Record, Pause, Processing, Effects, Start with Camera Apps, Show Inspector, Start or Stop), Finder, Open, Settings, stats, Quit. Loses Input, Load LUT and per-camera Cut.

**View › Monitor Tools:** adds Clip Indicators, Hide All, Reset. **View:** adds Detach to Window.

## Could not be determined from the code

- Which handler wins ⌃⌥F and ⌃⌥C when a detached window is focused.
- Whether Record › Recover Interrupted Takes reaches the sheet when Settings opens on another tab. By reading, `UIShowRecovery` needs the Recording pane mounted (Set:241), so it probably does nothing then. Moot if G16 is adopted.
- Whether Add Camera and Remove Camera are safe while another camera runs. The comment suggests so; it needs a live test the rules here forbid.
- Whether the Diagnostics item appears in the Window menu. Cmd:275 says SwiftUI lists it, and the menu dumps cover only the panel.
- `MonitorMetalView` keyboard zoom and pan (`+`, `-`, `0`, arrows): no file in `Sources/App` references that view, so it looks unreachable in this app, unverified at runtime.
