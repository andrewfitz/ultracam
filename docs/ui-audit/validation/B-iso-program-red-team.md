# B. Red team: retiring ISO/Program and letting demand decide

Date: 2026-10-30. Commit read: `2c4929c`. Subject: `docs/ui-audit/README.md` sections 3 and 11, and `docs/ui-audit/01-output-mode-architecture.md`.

Method: traced source by hand. Nothing was built, launched, signalled or edited. I also read the unified log with `log show`, `strings` on the installed extension, and `systemextensionsctl list`. All three are read-only. No Zoom session appears in the available log, so **no client behaviour below was observed**.

Labels: **V** verified in the cited code or binary. **I** inferred from verified facts. **U** unknown until a real client is tested.

## 1. Verdict

**The goal survives. The rules as written do not.** Retire the mode, keep a stable list, let demand decide. That is still the best option, and no extension change is needed.

Six things must change first:

1. **Blocker: late sink against a client holding device control.** The design turns every ISO client into a late-sink client. Since `dcb58e1` that path throws on any format mismatch and does not retry. The Zoom run the report cites predates that commit. This is the only finding that can leave a meeting black with a red tally.
2. **A cut with no client is not a cut.** `programActive` overloads two things: "the scheduler is running" and "someone wants pixels". Split them. The scheduler runs always, on metadata, at no GPU cost. This also replaces the third clause and removes the flip that strands pending cuts.
3. **Falling edges need a hold.** A brief client open otherwise stops capture, restarts the director, and writes a timeline file.
4. **Stopping the on-air camera blacks Program even with another camera live.** The later cut does not bring it back, because nothing reconciles the transport after an immediate selection.
5. **Red must mean frames are arriving,** not that a client exists.
6. **Phase order:** B5 cannot ship in Phase 1 without the always-on monitor, and the demand core cannot ship alone without fix 1.

Estimate: 7 to 10 working days plus owner qualification sessions, not 3 to 5.

## 2. What the design got right

Checked against code, not taken from the report.

| Claim | Result |
|---|---|
| The extension does not branch on kind | V. `CameraProvider.swift` reads `kind` nowhere. The only descriptor test is the legacy `feedID == "default"` sink name (`:698`) |
| Program and feeds coexist in the extension | V. `validate()` only limits Program to one device (`VirtualCameraRegistry.swift:195-197`); `testPublishesStableDescriptorDevicesAndReusesRuntimeOnReconcile` publishes both (`Tests/CameraRegistryRuntimeChecks.swift:90-110`) |
| Recording does not depend on output or the mode | V. It appends on the driver thread, before admission and before the capture queue (`CaptureController.swift:2012-2027`) |
| The no-demand branch is unreachable in the app | V. `onProcessedFrame` has one assignment (`FeedRuntime.swift:257`), made for every camera at `AppModel.swift:1133`. `services.preview` is never set in production, so `hasPreview` is false |
| A visible picture survives with no render | V. See scenario 7 |
| A device with a client survives removal | V. `CameraProvider.swift:564-570`, `:601-604` |
| 102 `outputMode` lines in 15 source files | V |
| F1, F2, F3, F5, F7, F8 | V |

A hot switch that changes the list really is worse. Its objection stands, and this review confirms section 6's rejection of it.

**Installed extension (V).** `systemextensionsctl` shows build 10 activated. The commit order is misleading: `b367013` changed `CameraProvider.swift` 17 minutes after the bump commit `6d0f1be`. The activated binary (`/Library/SystemExtensions/1556EB28…`, dated 01:08) already contains that commit's new string, so it was built from the edited tree. It also contains `4cc_udmd_glob_0000`, the 32-device message, `multipleProgramDevices`, and the `renegotiation failed` path. Its hash differs from the copy inside `/Applications/Ultracam.app` (dated 11:48), which is also numbered 10 and is not what runs. Exact equality with HEAD is I, not V.

## 3. Scenarios, traced

### 3.1 Two cameras, no meeting app, operator cuts

As designed: `programActive` is false, so `acceptingCapture` is false, and after step 4 nothing renders.

| Step | What happens | Evidence |
|---|---|---|
| ⌃2 pressed | `requestProgramCut` → `requestSelection(cutsAllowed: false)` | `AppModel.swift:811`, `FeedRuntime.swift:475-481` |
| Decision | `guard cutsAllowed, state.isOnAir` fails, so `selectImmediately` runs | `ProgramOutputRoute.swift:375-378` |
| Frames | None involved. No boundary, no `cutApplied` | `SwitcherCoordinator.swift:198-206` |
| App state | No `recentCuts` entry, no shot timer reset, because those live only in the cut-applied handler | `AppModel.swift:449-458` |

So the cut "lands" as a silent preselection (V). The PROGRAM tag jumps. Recent cuts and the shot clock stay still, in the sidebar the README draws with exactly those rows. The same button does two different things depending on an invisible condition.

**Rehearsal:** only in Program View, where the monitor raises `programActive`. There it works, at N full renders. In Side by Side only the tag moves. Auto cannot be rehearsed without a take or Program View, since the director stops (01 section 7b). So the README's "cut buttons stay neutral" is fine as a colour rule, but a real rehearsal exists in one layout only.

**Fix: section 5, rule R1.** The cut then lands on the target's next frame in every layout, logs, and restarts the shot clock, with zero GPU work.

Aside (V): README section 8 says a session leaves "a cut list". The timeline exists only for the Natural Talking Head director (`AppModel.swift:876-905`). A Manual session leaves only 20 in-memory entries.

### 3.2 Zoom opens Program while the on-air camera is stopped

Demand reaches `reconcileAutomaticFeed` through the monitor.

| Camera state | Result | Evidence |
|---|---|---|
| Automatic, not manually stopped | Starts in this pass, in camera order. `isFeedRunning` is true at once, so the transport opens before the first frame | `AppModel.swift:1347-1376`, `:1392-1395` |
| Manual (`automaticFeed` defaults false) | **Nothing starts.** The design's "Program's sources start when Program is wanted" applies only to automatic cameras | `AppSettingsStore.swift:281`, `AutomaticFeedPolicy.swift:26-28` |
| Manually stopped automatic | Stays off | `:1363` |

Timing as written: on-air camera automatic, other camera already running. Empty Program does not fire, because the on-air camera reads as running from `launchCapture` even though it has no frame (V: `isFeedRunning` is session state, `FeedRuntime.swift:196-198`). Zoom shows black through input lock, while a live camera sits idle (I: the scheduler's own comment gives a second or two for opening and locking, `ProgramTimestampMapper.swift:241-243`).

This rig runs both cameras on automatic (V: `Start …: automatic (preview)` in the log at 12:20:13), so Program demand starts both.

**Fix:** Empty Program tests "on-air source is not producing and another is" (`readiness(of:) == .producing`), after the start loop.

If nothing can start, `programWarning` already says so, and it survives if its Program-mode guard goes (`UIPresentation.swift:852-882`).

### 3.3 Zoom on Camera 1, second app on Program, operator stops Camera 1

If Camera 1 is not on air: Zoom gets standby black, Program is untouched. Fine.

If Camera 1 is on air (V, all):

1. The confirm appears only if `tally == .onAir` (`UIPresentation.swift:692`). Fine once tally covers both routes.
2. `endCapture` stops recording and capture, retires the source (`AppModel.swift:1199-1209`).
3. `reconcileProgramTransportDemand`: the producer is not running, so `required` falls and the bridge closes (`AutomaticFeedPolicy.swift:5-8`, `AppModel.swift:1389-1395`).
4. Both clients go to standby black after 12 frames (`VideoContract.swift:12-16`). Camera 2 is live and ignored.
5. Operator cuts to Camera 2. `isOnAir` is false, so `selectImmediately` runs, which fires no event. `requestProgramCut` never calls `reconcileProgramTransportDemand` (`AppModel.swift:811-829`), and neither does `saveSettings` (`:1018-1025`). **The bridge stays closed, and Program stays black.**

Step 5 is an existing bug in Program mode, which an always-available Program makes more reachable. The design's Empty Program rule does not help, because it fires only when `programActive` rises, and here it never fell. Reopening also hits the blocker in scenario 4.

So "Stop drops nothing on the other route" is true for sinks and false for the picture. **Fix: rules R5 and R6.**

### 3.4 Camera starts while a client already holds the device: late sink

This is the design's central new path. Today, a running ISO camera has an open sink, so:

- the extension refuses a client's format change while the sink consumes: "Stop capture in Ultracam before changing the output format" (`CameraProvider.swift:257-259`, in the installed binary), and
- a joining client gets no black, because `emitStandby` returns while `receivedAt` is recent (`:415-416`).

With lazy sinks, the client arrives first (V unless noted):

| Time | Event |
|---|---|
| Client starts | `consumers` 0→1, demand "1". `receivedAt` invalid, so black starts now (`:411-442`). The client may already have set its own format: `sink.consuming` is false, so `:257` lets it |
| Main queue | Monitor → `reconcileAutomaticFeed` → async sink enable |
| Next capture frame | `establish` → `reconnectIfDue` → `requestConnect`, which clears `reconnectRequested` (`CaptureController.swift:1316`) |
| Control queue | `connectOnce`: registry read, discovery, published-format check, then `negotiateInstalledContract` (`CameraSink.swift:419-481`) |
| Client holds control, format matches | Connects. Fine |
| Client holds control, format differs | **Throws** "The busy installed virtual camera is using a different format or exact cadence" (`:599-609`) |
| After the throw | `finishConnect`: `wasConnected` is false, so no recovery, and the `scheduleReconnect` guard fails (`CaptureController.swift:1345-1350`, `:1301`). **No retry, ever.** The message appears only in Diagnostics (`UIDiagnostics.swift:193`) |
| Result | Client on black indefinitely. Under design 7d (`inUse = cameraInUse`) the tally is **red** |

**How likely is a mismatch? Likely, by construction (I).** The extension starts at index 0 (`CameraProvider.swift:82`): 1080p NV12 at 59.94 with no chroma siting (`ExtensionFormatCatalog.swift:72-90`). The default processed contract is 1080p NV12 with centred chroma (`CameraSink.swift:402-403`). `matchesFormat` compares chroma location strictly (`DerivedOutputAdmission.swift:42-46`, `:63-67`). So a client that changes nothing still mismatches unless a previous sink left the device in the right mode. `activeRate` is also compared exactly (`CameraSink.swift:606`). Whether real Zoom holds control when this runs is U, but VALIDATION says it did on Oct 14 (`VALIDATION.md:366-370`).

**The report's evidence does not cover this.** Risk 4 cites `CameraSink.swift:463-466` and `VALIDATION.md:366-370` as the path "validated with Zoom". That section is dated October 14. `dcb58e1` (2026-10-29) replaced `if !controlled { set }` with the strict check. The comment at `:463-466` still describes the old behaviour, and `testBusyFormatMismatchAndUnreadableContractRefused` pins the new one. The first-sample negotiation that Zoom run relied on is still in the extension (`CameraProvider.swift:352-357`), but connect now throws before any sample can reach it.

**Today's exposure (I):** this already affects automatic cameras and every Program session, on the installed build. Check it regardless of this redesign. Program's failure path also has no timer: it clears state and waits for the next reconcile (`AppModel.swift:1423-1428`).

Fix: rule R3. It restores the qualified behaviour and avoids most mismatches, with no extension change.

**Separate, urgent, cause unknown.** The log holds 12 `Camera connect failed` lines and zero `Camera connected` lines (2026-10-30, 11:23 to 12:33, installed app, both feeds), all "Install and enable the Ultracam camera extension." Each failed within about a millisecond, which rules out the 3 s discovery wait unless the listener failed, and points at `providerID()` (`VirtualCameraRegistryTransport.swift:88`) (I). The extension shows `activated enabled`. The log retains only that day. Every sink in this design goes through that call, and the failure is visible only in Diagnostics. Find out why before qualifying anything (U).

### 3.5 Meeting app probing on launch

Demand flips only on `startStream` (`CameraProvider.swift:785-821`). Listing devices and reading properties change nothing (V). A quick open and close may coalesce, because the listener re-reads and `emit` de-duplicates (`CameraDemandMonitor.swift:174-196`) (I). Whether real apps start streams while probing is U: this log has no client session.

If they do, per open and close, with **no hold**:

| Item | Hidden automatic camera | Running camera |
|---|---|---|
| Capture | **Starts, then stops** at once: `.stop` → `endCapture` (`AutomaticFeedPolicy.swift:63`, `AppModel.swift:1377-1381`). Device reopens and relocks | Unaffected |
| Sink | Opens and closes | Opens and closes. Attempts are fenced, so this is safe (`CaptureController.swift:1343`) (V) |
| LUT | Safe: `loadedLUT` has one assignment, in `load` (`CaptureController.swift:462`), so a stop leaves it | Safe |
| GPU | Warm-up on each start | First render each time: 3 warm 4K frames (`LUTProcessor.swift:462`), then `releaseIdleResources`, which can block the capture queue up to 2 s if the GPU is stuck (`:556`) |
| Recording | Protected: `!recording` (`AppModel.swift:1378`). `.finishing` is not covered, but its frames are already written (I) | Unaffected |
| Director | **Stops and restarts** if `programActive` flipped: `stopAutoSwitcher` cancels the cut and finishes the timeline (`:966-976`). `finish()` force-writes the JSON (`AutoSwitcherTimelineRecorder.swift:472-479`). So each Program probe with Auto on and no take leaves a timeline file in the recording folder | Same |
| Monitor | Picture blinks unless preview keeps demand up | Unchanged |

The design adds exposure in three ways: N+1 devices to probe, a Program probe starts **every** automatic camera, and director flips are new, since today it does not depend on a client. "Add a short hold only if it proves necessary" is too weak. The director and capture cost are knowable now. **Fix: rule R4.**

### 3.6 Program audio and the Natural Talking Head director

The virtual cameras carry no audio. The director's input is the UI-selected camera's embedded audio.

| Case | Result |
|---|---|
| Selected camera differs from Program's source | Works. Ticks come from `selectedFeedID`, not the on-air source (`AppModel.swift:866`, `:1171`). This was always so (V) |
| Operator clicks another camera | Speech input and clock both move to it, mid-show, on a click that D1 promises is harmless (V). `ingestAudio` tracks silence by absolute time across that jump (`AutoSwitcherBridge.swift:153-175`). Each input has its own stream clock (I) |
| Clicks a stopped camera | Director starves: no ticks, no reconcile (`AppModel.swift:710-716`). 01 fixes this only for `addFeed`. Same trigger, wider fix needed |
| `programActive` falls with no take | Director stops, cut cancelled, timeline ends. Rises: new timeline, cooldowns reset |
| Take, no client, as designed | Works, because clause 3 forces all cameras to render. That is N 4K renders for a JSON file, against the cost rule |
| **Take start ordering** | `onRecordingStarted` calls `reconcileAutomaticFeed`, then reads `autoSwitcherTimeline` (`:425-431`). `reconcileAutomaticFeed` does not call `reconcileAutoSwitcher` unless a camera starts. If clause 3 is what starts the director, the timeline is nil at that read and **the take is never bound to it** (V) |
| Take end ordering | Safe. The recorder is held in `recordingTimelines`, and `recordingFinished` persists again after `finish()` (V) |
| Source-only path, `mediaTime` | `lastDeliveredSourceTime` is set only in `didDeliver` (`CaptureController.swift:2320`). `feedAutoSwitcherAudio` prefers `mediaTime` (`AppModel.swift:980`). Without a render it is stale, and Fixed Interval compares against it (`SwitcherCoordinator.swift:304-319`) (V). Audio time still flows, since `publishIfDue` runs in that branch |

Fix: rules R1, R7. Pin the clock to a director-owned camera.

### 3.7 Recording with no client

The check the brief asked for: `guard cameraConnected || cameraConnecting || hasPreview || processedHandler != nil` (`CaptureController.swift:2140`).

- `hasPreview` is always false in production. `services.preview` is never set (`AppHardware.swift`, `CaptureServicesBridge.swift:376`) (V). "Preview" in this app means the monitor, which never keeps processing alive (`:2126-2129`, `:571-573`).
- **Recording:** every frame, unaffected (V).
- **Monitor:** every `selected` frame, from `offerSourceOnlyInOrder` (`:2141`, `:2211-2223`). Same buffer, sequence and `untouched` flag as the rendered path (`:2245-2247`). The ordering barrier holds across the transition (V). Selection uses the output cadence in both paths (`:2137`) (V).
- **LUT on the monitor:** drawn in the monitor's own shader from `burnInLUT` (`:437`, `AppModel.swift:1126-1130`, `MonitorFeedHost.swift:710-721`). `burnInActive` follows configuration, not rendering (`:441-444`). `releaseIdleResources` does not touch the LUT (`LUTProcessor.swift:553-569`) (V).

**So section 8's "Source-only path, no render" is compatible with a visible preview showing the LUT.** The picture does not change or stop. Latency improves by the render time (I). This holds up.

What breaks is everything around the picture (V):

- `applied = nil` makes `camera.applying` true, so every idle running camera gets a permanent **"Updating output…" overlay on the picture** (`UISessionBridge.swift:126-127`, `UIPresentation.swift:541`, `UICameraColumn.swift:162-165`). During a take, strip state becomes `.updating` (`:552`).
- `outputLabel = ""` blanks the output row. Cut and Record enablement use `camera.signal`, not output, so they survive (`UIPresentation.swift:572`, `:622`, `:688`).
- `message` is overwritten every frame with "Camera ready — no active video destination."
- The processor must already exist. `start` builds it only if `hasProgram` (`:574-578`), so a naive gate defers `LUTProcessor()` to the capture queue under load.

01's risk 1 names most of these. Add the overlay on recording strips, and treat them as a required part of the gate, not polish.

### 3.8 First frames after demand

| Route | Today | Designed | Counted? |
|---|---|---|---|
| ISO on a running camera | First source frame after start, no black (V) | Black, then live with a `.time` discontinuity (`CameraProvider.swift:368-372`) | **No.** `.notSent` is silent (`CaptureController.swift:2316`) |
| Program | Black until the transport connects | Same | Yes: `withoutConsumer` (`ProgramOutputRoute.swift:568-570`) |
| Program with GPU idle | n/a | Warm-up holds the first live frame behind 3 warm renders (the frame waits for a slot, `LUTProcessor.swift:1152`) | `lateFrames` if over 2 frames |

The report's bound is wrong. "The 3 s discovery deadline" omits the registry acknowledgement of up to 2 s (`VirtualCameraRegistryTransport.swift:124-129`), and the bound does not hold at all when connect throws. With a stable list both waits are normally zero (I). Real time to first frame is U.

**Does the "every frame" rule allow it?** Yes, with one condition. A consumer that has not been connected is not a consumer a frame was dropped from, and the rule targets stalls and dropping under load. Nothing already flowing is affected: recording and monitor are untouched, and a second client on a live device gets frames at once. But the first viewer now sees black where it saw picture, and that gap must be measured, bounded and shown. **Add a counter and a time-to-first-frame figure.** If it exceeds a few frames, the fallback in section 6 applies.

### 3.9 One-camera users and Show Switching Controls

**Publish Program with 2 or more enabled cameras, not always.** The report rejected this for two reasons; both are weaker than stated.

- "The list would change as cameras are added." Only on crossing 1↔2, a rare deliberate act, and such an add already changes the list by adding a camera.
- "A selected Program device would vanish at one camera." It does not vanish under a client: it stays until the last client leaves (`CameraProvider.swift:564-570`). An app that saved it falls back at its next launch.

Against that, always publishing gives a one-camera user a second entry showing the same picture through a slower path: a paced bridge with its own contract and repeat logic, and all of Program's failure modes, for nothing. It also matches the rest of the design: cut buttons and Switching already appear at 2+. One concept, "switching exists with two cameras", replaces two gates. This rig has two cameras, so it sees no difference. A first-run user sees one device.

The cost is one condition in the projection, plus a Zoom restart to see Program after adding the second camera. That restart is already needed at upgrade.

**Show Switching Controls: DROP. It is a leftover mode.**

- 01 section 7c says it has no effect on demand. Yet hiding Program View ends monitor demand, which changes `programActive`.
- It stores in the `outputMode` key, so the old concept survives under a new name.
- Two gates (2+ cameras, and the toggle) make four states, including controls hidden while Program is on air to a client, and Auto cutting with no visible control.
- The only user it serves, two cameras and no Program use, sees neutral Cut buttons that do nothing harmful.

Keep the `outputMode` key for downgrade as a write-through value: decoded, kept, written back, read by nothing. That keeps the downgrade property of 01 without a UI.

### 3.10 Is installed build 10 really compatible?

**Yes for publishing, with the caveats below.**

| Check | Result |
|---|---|
| Adds Program or feeds live | V. `reconcileOnQueue` publishes additions and keeps existing runtimes (`CameraProvider.swift:590-597`) |
| Schema, generation, group fence | V. Unchanged (`VirtualCameraRegistry.swift:232-245`) |
| Demand property present | V. `4cc_udmd_glob_0000` in the activated binary |
| 32 devices | V at `encode` (`VirtualCameraRegistryTransport.swift:15-17`). `validate()` and `save()` do **not** check it (`VirtualCameraRegistry.swift:292-306`). So a 33-device snapshot saves, then fails at `synchronize`, which the publisher discards with `try?`. The whole update is lost, not just the extra device |
| 64 KiB | I. About 600 bytes per descriptor, so about 19 KiB at 32. Names are unbounded, but that is theoretical |
| Registry order | I: `addDevice` order, not registry order, decides until the extension restarts. A Program-mode user upgrading keeps Program first this session. Effect on "first camera" apps is U |
| Serial queue with N+1 streams | Holds up to measurement. All share one queue (`:547-552`). Samples pass by reference (I) |

Build-10 caveat: the fix for scenario 4 needs no extension change, because `admit` already renegotiates for the producer (`:352-357`, string in binary). If `ExtensionFormatCatalog` or `CameraProvider` change later, a bump is needed, and the Update banner compares numbers only (`ExtensionInstaller.swift:106-109`), so the two different binaries numbered 10 cannot be told apart by it.

The 31-camera cap is harmless in practice, since each camera needs its own exclusive input.

## 4. Tally

The README rule: red means a viewer can see this picture, by either route. **The intent is right. The conditions and the presentation are not.**

**"Can see" is wrong as written.** `tally()` returns `.onAir` for the on-air camera with no check that it is running (`UIPresentation.swift:524`). Design 7d also removes the sink check from `inUse`. Together that gives red in all of these:

- Program client, on-air camera stopped. Red on a stopped camera.
- Connect failed (scenario 4). Red on black, indefinitely.
- First-frame gap. Brief, and tolerable only if it is brief.

`cameraOutputActive` was the wrong signal for "a client exists" (F2), but it is half of the right one.

**Precedence.** NEXT wins at line 523. A cut target with its own ISO client shows NEXT, hiding that it is live. For a starting camera that can last 8 s.

**Are two reds good for an operator?** As a warning, yes: both cameras must not be stopped or changed, and `stopNeedsConfirmation` keys on it. As a switching display, no. The first thing a vision mixer needs is which picture Program is on, and two identical pills hide that. Keep both red, because the safety meaning is real, and change the **word**: `ON AIR` for Program, `ISO` for a camera seen only through its own device. Colour budget stays as report 06 sets it.

**Replacement rule:**

```
live(c)      = c running, signal live
programSeen  = Program client && Program sink connected
isoSeen(c)   = own client && own sink connected
ON AIR (red) : c is on air && programSeen && live(c)
ISO    (red) : isoSeen(c) && live(c), and not ON AIR
NEXT         : pending cut target, and neither of the above
               (a red camera also shows Next on its output line)
PROGRAM      : on air, not ON AIR, 2+ cameras
none         : otherwise
```

Client present but not connected or not live shows no red and raises an Attention row: "A camera app is waiting for Camera 1", with no app name (D8). Stop confirmation keys on ON AIR or ISO.

## 5. Design points

| # | Point | Verdict |
|---|---|---|
| 1 | Retire the mode from CMIO, capture, Settings and menus | **KEEP** |
| 2 | Publish every camera plus Program, always | **REVISE:** every enabled camera, then Program when 2 or more are enabled and at most 31 |
| 3 | No extension update, approval or migration | **KEEP**, conditional on R3 working against real clients |
| 4 | One projection function | **KEEP** |
| 5 | Refuse a 32nd camera | **REVISE:** also add the count to `validate()`, so `save` fails loudly instead of `try?` losing a publish |
| 6 | `programActive` as one flag | **REVISE:** R1 |
| 7 | `sink open = own client` | **REVISE:** R3, R4 |
| 8 | `source wanted` rule | **REVISE:** table below |
| 9 | `GPU = sink open or programActive` | **REVISE:** table below, R2 |
| 10 | Monitor runs for the app's whole life | **KEEP**, and move to Phase 1 |
| 11 | Async `setCameraOutputEnabled`, keep the sync one | **KEEP** |
| 12 | `setOutputMode` body becomes `setProgramActive` | **DROP.** With R1 there is no transition. `markSourcesIdle` strands a pending cut: it clears nothing, and expiry needs a frame or tick (`ProgramTimestampMapper.swift:296-298`, `:389-396`). The NEXT tag would stay up |
| 13 | Clause 3 of `programRequested` goes | **KEEP.** Start All covers the old habit. Tell the owner |
| 14 | Third clause (`Auto && take`) | **DROP** from the GPU rule: R1. Director rule in R7 |
| 15 | Empty Program | **REVISE:** R5 |
| 16 | "Stop drops nothing on the other route" | **REVISE** the claim: true of sinks. Picture rule is R5, R6 |
| 17 | Show Switching Controls | **DROP** (3.9) |
| 18 | Tally | **REVISE** (section 4) |
| 19 | Cut buttons at 2+, neutral with no client | **KEEP**, now always a real cut (R1) |
| 20 | `naturalTalkingHeadEnabled` stops forcing a mode | **KEEP** |
| 21 | Keep `outputMode` key | **KEEP** as an unread write-through value |
| 22 | Rename, add, remove live; Reset locked | **KEEP.** R7 replaces 01's narrower F8 fix |
| 23 | Attention: cuts do not reach an ISO client | **KEEP.** Trigger: operator cuts, an ISO client exists, Program has none |
| 24 | Keep the route-lock measurement | **KEEP** |
| 25 | Order and estimate | **REVISE** (section 7) |

### Replacement rules

**R1. The scheduler always runs; pixels are a separate demand.** Remove `acceptingCapture` as a gate. On the source-only path, call a new `route.observe(fromCapture:metadata:)` in delivery order: `state.ingest`, events, stats, no `monitorHandler`, no `enqueueLocked`. `state.ingest` needs only a `ProgramSourceFrame`, so the scheduler has no pixel dependency (`ProgramTimestampMapper.swift:4-14`, `SwitcherCoordinator.swift:401`). Running the scheduler with no consumer is already the production path in Program mode (`ProgramOutputRoute.swift:568-571`). Cost: one lock and a struct per frame, which the gate already pays.

Result: cuts are real in every layout, `isOnAir` is always true to the facts, no flip exists, and a take with no client needs no render.

**R2. No-demand branch, required with the gate.** Set `applied = pipelineEnabled`, `lastDeliveredSourceTime = frame.pts`, and an output label computed from the effective configuration. Do not overwrite `message`. Replace the `processedHandler != nil` test with a per-controller flag `programPictureWanted`, and build the processor in `start` regardless. Free GPU resources after 30 s without a render, not on the first idle frame.

**R3. Late sink.** Three parts:

- *Pre-negotiate.* When a running camera's contract changes, including at first frame, write format and rate to both streams with no sink started, if no other process holds control. It is one property write and costs nothing per frame, and an arriving client then finds the right format. This is the same setter `connectOnce` uses, allowed because the sink is not consuming (`CameraProvider.swift:257`).
- *Busy mismatch.* Replace the throw with: connect anyway, after `matchingPublishedIndex` has passed, and let the first sample renegotiate (`CameraProvider.swift:352-357`). The extension still refuses anything unpublished. Update `testBusyFormatMismatchAndUnreadableContractRefused` and the comment at `:463-466`.
- *Retry.* A failed connect with a client still demanding retries once a second, as Program's send path does (`ProgramOutputBridge.swift:327-355`), and raises an Attention row instead of a Diagnostics line.

Program uses the same path. Unknown until tested: how Zoom reacts to a format change under its lease on a mid-stream camera. If it fails, use the section 6 fallback.

**R4. Release hold.** All rising edges act at once. A falling client edge takes effect after 5 s without demand, cancelled if demand returns. It covers sink close, automatic stop, picture demand, and the director. A user Stop ignores it and acts at once. Tail cost is 5 s of a stream nobody reads, and only after a real client.

**R5. Losing the on-air source.** When the on-air camera stops or fails, or when Program picture demand rises and it is not producing, then if another enabled camera is producing, `select` it before `reconcileProgramTransportDemand`. If several are, take the next in camera order. A running starting on-air camera yields to a producing one. Show an Attention row naming the change. The contract owner is unchanged, so frames convert rather than renegotiate (`AppModel.swift:1404-1415`).

**R6. Transport.** `required = Program client && any enabled camera running`. An open sink with no frames gives standby black, keeps the client's format locked, and avoids a busy reopen. Call `reconcileProgramTransportDemand` from `requestProgramCut` on every result, which fixes 3.3 step 5.

**R7. Director.** `directorActive = strategy automatic && 2+ running && (programPicture || any take active)`. Pin its audio and clock to a director-owned camera: the anchor while running, otherwise the emphasis camera, independent of the UI selection. Call `reconcileAutoSwitcher` before reading the timeline in `onRecordingStarted`. Apply R4 to its falling edge.

### Corrected demand table

```
programClient     = Program route has a client (released after R4 hold)
programPicture    = programClient || Program monitor visible
cameraClient(c)   = c's route has a client (released after R4 hold)
autoTake          = automatic strategy && any take active

scheduler         = always, on metadata
source wanted(c)  = automatic cameras only:
                    cameraClient(c) || programPicture || autoTake
                    || c records || visible preview of c
sink open(c)      = cameraClient(c) && c running
GPU render(c)     = sink open(c) || sink connecting(c)
                    || (programPicture && c running)
Program sink      = programClient && any enabled camera running
monitor(c)        = every output-cadence source frame, always
recording(c)      = every source frame, always, on the driver thread
```

| Situation | Capture | Sink | Render | Scheduler | Director |
|---|---|---|---|---|---|
| Running, nobody watching, preview up | Yes | No | **None** | Metadata | Off |
| Recording, no client | Yes | No | **None** | Metadata | Off |
| Recording, Auto on, no client | Yes, automatic cameras too | No | **None** | Cuts land | On |
| Program View open, no client | Yes | No | N | Cuts land, picture | If Auto and `programPicture` |
| ISO client only | Yes | That camera | That camera | Metadata | Off |
| Program client | Yes | Program | N | Cuts land | If Auto |
| ISO and Program clients | Yes | Both | N | Cuts land | If Auto |
| Probe under 5 s | One start | One open | Brief | Unchanged | No restart |

The "Recording, Auto on" row is the design's most expensive case and costs nothing here.

Not in the table, worth doing later: with a Program client, non-selected cameras still render N frames that the route throws away (`ProgramOutputRoute.swift:151-155`), the plainest remaining break of the cost rule. Rendering only the on-air camera and a pending target would take two 4K renders to one. It needs care: a cut must not land on a metadata-only frame, and the target's pipeline must stay warm. Do it as its own change after qualification.

## 6. Alternatives

| Option | Verdict |
|---|---|
| The design as written | Fails 3.1, 3.3, 3.4, 3.5 |
| **The design plus R1 to R7** | **Best.** Same goal, same extension, less per-frame work, fewer states |
| Sink opens with the camera, no frames sent until a client | **Fallback.** Sink consuming locks the format first and joins are instant, as today. Costs the 4x-rate poll per running camera (`CameraProvider.swift:890-897`). Use only if R3 fails with real clients; measure that cost first |
| Keep sink open for a while after first client (R4 stretched to minutes) | No. It hides the join problem without fixing the first join |
| Per-camera "Publish" switch | No. A new persistent choice per camera, and the list changes again |
| One Program device only, ISO dropped | No. Loses two apps on two cameras, the point of ISO |
| Keep the mode, fix the lock | No. Keeps F1 and F2 and the owner's objection |

## 7. Phase order and estimate

"Each phase can ship alone" and "Each step can ship alone" are both false as listed.

- **README Phase 1 includes B5.** Changing `inUse` to `cameraInUse` while the monitor is off gives **no tally at all** on a real meeting, for a manual ISO camera in Separate. The monitor runs only in Program mode or with an automatic camera (`AppModel.swift:502`, `:1010`). That swaps a false ON AIR for a false off, which is worse. 01 step 1 has the same problem with F2.
- **Step 2 cannot ship alone.** Sinks by route regress every ISO join on release (3.4), before any benefit arrives.
- **Step 4 cannot be split** from its telemetry fixes (3.7).
- **Steps 1, 3 and 5** do ship alone once the rest is ordered.

Corrected order, inside Phase 2 unless marked:

| Step | Work | Ships alone? |
|---|---|---|
| A. In Phase 1 | Always-on monitor, then B5 with the section 4 tally | Yes |
| B | Check the 12 failed connects (3.4). Add sink telemetry and the retry | Yes, and do it first |
| C | Topology rules, F7, R7's pinned clock | Yes |
| D | R3 pre-negotiate and busy path, R6. **Qualify with Zoom on the Program path as it exists today** | Yes, and fixes today's exposure |
| E | Sinks by route, R4 hold | After D is qualified |
| F | Scheduler always on with R1, R5, retire the mode, publish at 2+, drop the toggle | Yes |
| G | GPU gate with R2 | Yes |
| H | Docs | Yes |

D before E is the key change: it makes the risky path safer on the code that exists, and it gives real evidence before every ISO user depends on it.

**Estimate.** 01's size counts the mode removal only. It omits R1 to R7, about 2 to 3 days with tests. Qualification also cannot be compressed, since it needs the owner, a real meeting app, and Ultracam not serving a meeting, and at least two rounds (after D and after E).

**7 to 10 working days of engineering, plus two owner sessions.** The line count in 01 is reasonable for the removal and about 200 lines light overall (I).

## 8. What to qualify

Add to 01's list, in this order:

1. Why `Camera connect failed` appears 12 of 12 times on the installed build.
2. Does Zoom hold device control when Program connects today, and does the mismatch throw fire? Search the log for "busy installed virtual camera".
3. Zoom's format choice on Ultracam devices, with and without pre-negotiation.
4. Zoom's behaviour when the first sample changes format under its lease.
5. Whether real apps start streams when probing. Log demand edges with timestamps first; that alone answers it.
6. Time to first live frame for an ISO join and a Program join, at 4K.
7. Clock relationship between two inputs' audio, for R7.
