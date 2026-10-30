# Output mode architecture: can ISO and Program always both be available?

Date: 2026-10-30. Commit reviewed: 30c8d73.

Method: code reading only. Nothing was built, launched or run, and no live app or `defaults` domain was touched. Every "Verified" claim comes from the cited line. "Inferred" means I reasoned from the code or from general CMIO knowledge and did not observe it.

## 1. Answer

**Yes. Always publish both. The mode as an output concept should stop existing.**

The limitation is mostly arbitrary:

- The extension never treated ISO and Program as exclusive. It has no branch on device kind, and a test already publishes both together.
- The capture path already sends one frame to a feed camera and to Program.
- The either-or exists in two small app-side `switch` statements.
- "Stop every camera first" exists because the app applies the mode to capture in one place, once, when a camera starts.
- "Stop recording first" protects nothing. Recording does not read the mode.

Three things are real, but none of them requires a mode:

1. A camera should not do work for a route nobody is watching. Today that is partly handled by the mode and partly not handled at all.
2. Meeting apps cache device lists. That is a reason to stop changing the list, so it argues against any hot-switching design that adds and removes devices.
3. Program and ISO mean different things for tally and status, and the UI has to show both.

The recommended design and its costs are in sections 7 and 8. No camera extension update is needed, which also means no macOS approval or restart cycle.

## 2. What enforces the rule today

### Enforcement chain (verified)

| Layer | Where | What it does |
|---|---|---|
| UI | `Sources/App/UISessionSidebar.swift:511-521`, `:589` | Picker disabled unless `session.canEditTopology`; picks the reason text |
| UI | `Sources/App/UISettings.swift:348`, `Sources/App/UIMenuBar.swift:469-483`, `Sources/App/UICommands.swift:155-168` | Same rule in Settings, menu bar and Program menu |
| Bridge | `Sources/App/UISessionBridge.swift:206` | Copies `model.canEditFeedTopology` into the snapshot |
| Model guard | `Sources/App/AppModel.swift:788-789` | `setOutputMode` returns silently unless `canEditFeedTopology` |
| Rule | `Sources/App/AppModel.swift:129-135` | No LUT load on any camera, no camera running or accepting on any camera, no take active on any camera |
| Pure policy | `Sources/App/AutomaticFeedPolicy.swift:30-32` | `!loading && !sourceActive && !recordingActive` |

`FeedCoordinator.setOutputMode` has no guard of its own (`Sources/Shared/FeedRuntime.swift:439-460`). The rule lives only in `AppModel`.

### History (verified)

- 2026-10-15, `c111ce9`: `canEditFeedTopology` first appears as `!running && !loading`. The commit message has no body.
- 2026-10-15, `e486ed3`: the output picker is disabled while running, in `FeedInterface.swift`.
- 2026-10-21, `a32b220`: the `recordingActive` clause and the model guard in `setOutputMode` appear. The commit message is "before redesign".
- 2026-10-25, `4b14f60`: adds Stop Cameras and Switch, which works around the rule rather than questioning it.

No commit message, plan or comment says why the mode must be exclusive or why recording blocks it. That absence does not prove there was no reason, but no reason is recorded.

## 3. Each constraint: real or incidental

| # | Constraint | Verdict | Evidence |
|---|---|---|---|
| 1 | The registry publishes feeds or Program, not both | **Incidental** | The either-or is only in `Sources/App/VirtualCameraRegistryPublishing.swift:19-27` and `Sources/Shared/FeedRuntime.swift:603-612`. `validate()` only forbids more than one Program device (`Sources/Shared/VirtualCameraRegistry.swift:195-197`). The extension does not branch on kind: a grep for `.program` or `kind` in `Sources/CameraExtension` finds nothing but the fallback `.feed` calls. `testPublishesStableDescriptorDevicesAndReusesRuntimeOnReconcile` publishes `[feed, program]` (`Tests/CameraRegistryRuntimeChecks.swift:90-110`). `testProgramRuntimeFollowsSwitcherAtFrameBoundary` publishes two feeds plus Program (`:167-179`). `docs/MULTI_CAMERA_PLAN.md:100` says all devices share one implementation. |
| 2 | Cameras must be stopped | **Incidental, one wiring gap** | The mode reaches capture in one place, `launchCapture` (`Sources/App/AppModel.swift:1179`), evaluated once per start. `setCameraOutputEnabled` is written to run while capture runs: it closes the sink or requests a reconnect (`Sources/App/CaptureController.swift:407-421`), and the next frame reconnects through `establish` and `reconnectIfDue` (`:2122`, `:1255-1257`, `:1290-1298`). Nothing calls it for a running camera. |
| 3 | Nothing may be recording | **Incidental** | Recording takes the source image from the capture path (`Sources/App/CaptureController.swift:1857-1862`), not from the feed camera or Program. Recording tests run with camera output off (`Tests/RecordingModelChecks.swift:125`, `Tests/CaptureRecordingIsolationChecks.swift:671`). A running camera already survives a take. The clause exists only because recording implies a running camera, so it becomes redundant once constraint 2 goes. |
| 4 | No LUT may be loading on any camera | **Incidental for the mode** | A late load is fenced by generation and by descriptor presence (`Sources/App/AppModel.swift:619`), and `removeFeed` cancels it (`:759`). Nothing about a LUT interacts with the registry. |
| 5 | A second sink cannot coexist with Program | **False** | `deliver` already does feed camera first, Program last, on the same `rendered` buffer (`Sources/App/CaptureController.swift:2225-2269`). `testProgramHandlerRunsAfterCameraAndCanBeSwappedWhileFramesFlow` asserts each of 12 frames reached the camera and then Program, while the handler is swapped 200 times (`Tests/EndToEndChecks.swift:1253-1271`). Program has its own `CameraSink` and bridge (`Sources/App/ProgramOutputBridge.swift:100-107`). |
| 6 | The Program scheduler must not see frames in ISO use | **Real goal, wrong key** | Skipping work is correct, but it is keyed on the mode (`Sources/Shared/ProgramOutputRoute.swift:299-303`, `:445`). It should be keyed on whether Program has a consumer. With no client the route already does no pixel work (`:568-571`). |
| 7 | Meeting apps cannot follow a device change | **Real, and argues for this design** | "Camera applications may need a restart after registry changes" (`docs/MULTI_CAMERA_PLAN.md:102`). "Zoom 7.2.2 was restarted to refresh its cached camera list" (`VALIDATION.md:781`). The UI tells users to choose the new camera after a mode change (`Sources/App/UISettings.swift:352`). A stable list removes the problem. |
| 8 | A device with a client must not vanish | **Real, already handled** | Devices stay published until the last client leaves (`Sources/CameraExtension/CameraProvider.swift:564-570`, `:601-604`). Pinned by `testDemandAndRemovalAreIndependentPerDevice` and `testLiveRegistryControlChangesToProgramWhilePreservingActiveFeedClient` (`Tests/CameraRegistryRuntimeChecks.swift:112-128`, `:35-54`). |
| 9 | The director only runs on Program | **Real, but keyed wrongly** | `docs/AUTO_SWITCHER_PLAN.md:35-36` states it. `reconcileAutoSwitcher` gates on the mode (`Sources/App/AppModel.swift:876`). The right key is whether anything consumes its output. |
| 10 | Program and ISO need one contract | **False** | Each device has its own runtime and negotiated format (`Sources/CameraExtension/CameraProvider.swift:82-83`, `:243-283`). Program holds one contract per client session and converts other sources on the GPU (`Sources/App/AppModel.swift:1397-1403`, `Sources/Shared/ProgramOutputRoute.swift:610-632`). |

## 4. What would break

### 4a. Removing only the guard (a hot-switchable mode that still changes the device list)

Verified from the code path after `Sources/App/AppModel.swift:788-796`:

- **ISO to Program with cameras running.** The registry drops the feeds, but `cameraOutputEnabled` stays true (it is only set at `:1179`). Each running camera keeps its sink, so `inUse` stays true through `sink?.client != nil` (`Sources/CameraExtension/CameraProvider.swift:92-95`). The device is never removed and frames keep flowing to a camera that is not in the registry.
- **Program to ISO with cameras running.** `cameraOutputEnabled` stays false, so `establish` never connects (`Sources/App/CaptureController.swift:1267-1270`). The new feed devices show standby black (`Sources/CameraExtension/CameraProvider.swift:411-442`).
- **A meeting app on the old device** keeps it until it lets go. With the sink closed, `stopConsumption` clears the input (`:912`) and standby black follows. The user has to reselect. Inferred: a meeting participant sees black until then.

Wiring `setCameraOutputEnabled` fixes the first two and not the third. So a hot switch that changes the list is rejected.

### 4b. Publishing both without other changes

- **Eager sinks.** Every running camera opens its sink at start with no client (`Sources/App/CaptureController.swift:561-565`). Today a Program-mode user avoids this. Publishing both and enabling output for everything would add a frame-rate stream of IPC and a poll timer at 4x the frame rate per camera in the extension (`Sources/CameraExtension/CameraProvider.swift:890-897`), with `receive` storing `latest` and returning because `consumers` is 0 (`:359-364`). This breaks the "costs nothing" rule.
- **Demand monitoring is off in the common case.** The monitor runs only in Program mode or with an automatic camera (`Sources/App/AppModel.swift:502`, `:1010-1011`). A Program client would go unseen.
- **Program gating.** `programMode` feeds transport (`:1393`), source demand (`:1344`, `:1358`), the director (`:876`), audio ticks (`:979`) and the Program monitor target (`:1024`). All need a new key.
- **Clause 3 of `programRequested`** (`:1344-1346`): "a camera the user started keeps Program's sources up". Without a mode this would make any manual Start pull up every automatic camera.
- **Tally and status.** A camera can now be directly in use and on Program, and the two-case `switch` statements (`Sources/App/UIPresentation.swift:521`, `:644`, `:730`) cannot express that.
- **Registry limit.** `maximumDevices` is 32 (`Sources/Shared/VirtualCameraRegistryTransport.swift:11`), so with Program the limit is 31 cameras. `add` has no limit today (`Sources/Shared/FeedRuntime.swift:333-341`).

## 5. Findings along the way

These are verified in code. None has been observed in a live run.

- **F1. GPU work runs for nobody.** `wireCamera` installs `onProcessedFrame` for every camera (`Sources/App/AppModel.swift:1133`, `Sources/Shared/FeedRuntime.swift:254-262`), and the only assignment in `Sources` is that one. So the "no downstream demand" branch (`Sources/App/CaptureController.swift:2138-2153`) can never run in the app. It is tested only with a synthetic controller (`Tests/CaptureRecordingIsolationChecks.swift:772`). Today a running camera with only a monitor renders every frame, then the route throws it away at `acceptingCapture` (`Sources/Shared/ProgramOutputRoute.swift:445`) or `outputActive` (`:568`). This is an existing break of the project rule, and it is the largest saving available here.
- **F2. A connected sink reads as a meeting client.** `camera.inUse` includes `cameraOutputActive` (`Sources/App/UISessionBridge.swift:128`), which is simply `cameraConnected` (`Sources/App/CaptureController.swift:2448`). So in Separate mode a running camera with the extension installed shows ON AIR with no viewer (`Sources/App/UIPresentation.swift:527`). The lock also claims "A meeting app is showing Ultracam" (`Sources/App/UISessionSidebar.swift:517-518`). That means Stop Cameras and Switch is normally unreachable from Separate mode. `Tools/UIVerify/ProgramOutputVerify.swift` misses this because its fixture sets `inUse` by hand.
- **F3. `routeDemand` can go stale.** The monitor drops removed routes and clears state without emitting (`Sources/App/CameraDemandMonitor.swift:76-80`, `:113-118`), so `routeDemand` keeps the last value (`Sources/App/AppModel.swift:498`). An always-on monitor over a stable route set removes this class of bug.
- **F4. The documented demand model is not wired in.** `setProgramConsumer` and `setDedicatedCameraConsumer` have no callers in `Sources/App` (only their definitions at `Sources/Shared/FeedRuntime.swift:531`, `:542`). So `programConsumerActive` is always false in the app, and the demand branches at `:168`, `:324`, `:363`, `:454` and the guard at `:354-355` never act. Real demand is `reconcileAutomaticFeed` (`Sources/App/AppModel.swift:1339-1386`). Do not build on `programConsumerActive`. Delete this path or wire it, as a separate decision.
- **F5. Two registry projections.** `forFeeds` (`Sources/App/VirtualCameraRegistryPublishing.swift:14`) publishes, while `registryDevices` (`Sources/Shared/FeedRuntime.swift:603`) feeds the demand monitor. The app's coordinator has no store (`Sources/App/AppModel.swift:358`), so its own publish is memory-only. They should be one function.
- **F6. A rename never reaches a meeting app until the extension restarts**, running or idle. `updateDescriptor` only stores the value (`Sources/CameraExtension/CameraProvider.swift:194-197`), and names are set at init (`:181`, `:698`). `Sources/App/CameraDemandMonitor.swift:166-168` documents the stale names. Inferred: `CMIOExtensionDevice` has no public way to change `localizedName` in place.
- **F7. Adding a camera flushes Program.** Any change to the feed list runs `flushOutputLocked`, which clears the stage and drains the consumer queue (`Sources/Shared/ProgramOutputRoute.swift:333`, `:762-767`). That is correct when a source is removed. On an add it drops frames that are valid. The test named for this case checks cut state only (`Tests/ProgramOutputRouteChecks.swift:1088-1118`).
- **F8. Selecting a stopped camera starves the director.** Ticks come only from the selected camera (`Sources/App/AppModel.swift:866`, `:1171`), and `selectFeed` does not reconcile (`:710-716`). `addFeed` selects the new camera (`:729`), so a live add would stall Auto.

## 6. Alternatives considered

| Option | Verdict | Why |
|---|---|---|
| Keep the mode, improve the message | Rejected | The owner's objection stands, and F1 and F2 stay |
| Hot-switch the mode, change the device list | Rejected | Clients must reselect, and meeting apps cache lists (section 3, row 7) |
| Always publish, but a toggle blanks the inactive set | Rejected | Keeps a mode whose only effect is to break a device someone selected |
| Always publish, always feed everything | Rejected | Breaks "costs nothing": IPC and polling for every running camera |
| Single device whose content follows a toggle | Rejected | Two apps could not take different cameras, which is the point of ISO. It would also need a contract for a device that changes role |
| Publish Program only with two or more cameras | Rejected | The list would change as cameras are added, and a selected Program device would vanish at one camera. The cost of one idle device is close to zero |
| **Always publish, demand decides all work** | **Chosen** | Stable list, no mode, idle cost lower than today |

## 7. Decision

### 7a. Device list

Publish every enabled camera plus Ultracam · Program, always, in that order. Merge the two projections into one function with no mode argument. Refuse to add a 32nd camera, so the registry stays within 32 devices.

A toggle never touches the registry. After the one upgrade publish, only add, remove and rename change it.

### 7b. Demand replaces the mode

```
programActive = Program virtual camera has a client
             || Program monitor is visible
             || (automatic switching on && a take is active)

camera sink open      = this camera's virtual camera has a client
camera source wanted  = own client || programActive || recording || visible preview (automatic cameras)
camera GPU processing = sink open || programActive
```

- **Monitor.** `CameraDemandMonitor` runs for the app's whole life, over all routes.
- **Sinks.** `reconcileAutomaticFeed` drives each camera's sink from its own route, and `launchCapture` starts from the same value. Add an async variant of `setCameraOutputEnabled`, because the current one does a `queue.sync` from the main actor, and the capture queue can be held by a synchronous connect during start (`Sources/App/CaptureController.swift:409`, `:562`, `:1332-1333`, discovery up to 3 s at `Sources/App/CameraSink.swift:520`). Keep the existing method, since tests use it as a capture-queue barrier (`Tests/CaptureTypedAdmissionChecks.swift:189`).
- **Program.** The body of `FeedCoordinator.setOutputMode` becomes `setProgramActive(_:)` with the registry publish removed. It is almost exactly the transition needed (`Sources/Shared/FeedRuntime.swift:446-450`). Replace `outputMode == .program` with `programActive` in the transport, cut, director, audio tick and format-mismatch checks.
- **Clause 3 of `programRequested` goes.** A manual Start starts that camera only. Opening the Program view counts as Program demand, so that is how an operator arms and rehearses cuts before joining a meeting.
- **Director.** Natural Talking Head currently writes a timeline during takes with no Program client. The third clause of `programActive` keeps that, because the timeline file is a consumer. Without a take or client, it stops.
- **Empty Program.** When `programActive` rises and the selected camera is not running but another is, select the running one (nothing is on air, so `selectImmediately` applies). This case gets more likely once Program is always offered. Today it gives standby black (`Sources/App/AppModel.swift:1392-1395`).
- **Stop drops nothing on the other route.** Program's bridge closing does not touch feed sinks, and a feed sink closing does not touch Program, since they use separate sinks.

### 7c. What remains of the toggle

The owner's "toggle whenever" survives as a **view preference**: show or hide Program controls (cut buttons, switcher section, Program view). It is never locked and has no effect on CMIO, capture or demand. It works during a recording and during a meeting.

`UIOutputModeSwitch`, `UIOutputModeControl.availability`, "Stop Cameras and Switch" and the Output submenus are deleted. Settings › Published Cameras lists all devices with In use / Not in use.

### 7d. Tally and status

- Red ON AIR means a viewer can see this picture: (on Program and Program has a client) or (own virtual camera has a client).
- PROGRAM means selected on Program with no client, shown only when Program controls are on.
- NEXT is unchanged.
- Output lines may show both: "In Program · on air" and "Ultracam · Camera 1 · In use".
- `camera.inUse` becomes `cameraInUse(id)` only, which fixes F2.
- `naturalTalkingHeadEnabled` stops forcing a mode (`Sources/App/AppModel.swift:95-97`).

## 8. Cost

### GPU

| Situation | Today | Decided design |
|---|---|---|
| Running, nobody watching | Full per-frame render (F1), plus sink IPC in Separate | Source-only path, no render, no sink |
| One ISO client | One render, sink open | Same |
| Program client, N sources | N renders plus conversion for an on-air source that differs from the contract | Same |
| ISO and Program clients | Not possible | One render per camera, one conversion at most. `rendered` is shared, not copied (`Sources/App/CaptureController.swift:2254-2268`) |

The conversion runs only for the on-air source, only when it differs from the contract (`Sources/Shared/ProgramOutputRoute.swift:610`). Non-selected sources do no pixel work in the route (`:151-155`), though their capture pipelines still render, as they do now.

The new gate is the first production use of the F1 branch, and it needs work (see section 12, risk 1).

### Memory

Verified or computed from the code:

- **Idle Program device.** One runtime holding 144 format objects: 18 legacy plus 6 DCI gives 24 SDR, times 3 transfers, times 2 chroma sitings (`Sources/Shared/ExtensionFormatCatalog.swift:72-118`). Two streams. No timer and no GPU standby until a client starts (`Sources/CameraExtension/CameraProvider.swift:289-301`, `:797`).
- **Idle route.** No pixel buffers. The stage cap of 512 MiB and 0.4 s applies only with a client (`Sources/Shared/ProgramOutputRoute.swift:170-171`, `:568`).
- **Normalizer.** Built in the background once. Warm it on the first Program demand, as `attachProgramBridge` does (`Sources/Shared/FeedRuntime.swift:224`), not at launch.
- **Pools with ISO and Program both live.** Worst-case retention for the on-air camera is 8 sink slots plus 24 Program consumer slots plus 3 in flight, or 35 buffers (`Sources/Shared/VideoContract.swift:35`, `:50`, `Sources/Shared/ProgramOutputRoute.swift:169`). Other cameras hold no Program slots, because the route skips their frames (`:151-155`). The limit is `min(64, 1 GiB / slot size)` (`Sources/App/LUTProcessor.swift:163-165`, `:278`). Inferred from 4K v210 at about 22 MB per frame: about 48 slots, so 35 fits, and normal retention is far lower because the paced bridge keeps at most 2 pending (`Sources/App/ProgramOutputBridge.swift:498`).

### Frame delivery

- Feed camera delivery is unchanged. The camera send happens before Program (`Sources/App/CaptureController.swift:2262-2268`).
- **New coupling when ISO and Program are both live.** All cameras share one route lock (`Sources/Shared/ProgramOutputRoute.swift:191`, `:444`), and the GPU conversion is encoded under it (`:66-67`, `:629`). The delivery queue is serial per camera, so a long lock hold can delay that camera's next feed-camera send. A Program stall cannot hold the same frame, as the comment says (`Sources/App/CaptureController.swift:2226-2227`), but it can hold the next one. Inferred: small, because encoding does not wait for the GPU. Measure it (`lastStageMilliseconds` exists at `Sources/Shared/ProgramOutputRoute.swift:130`).
- **Live add** must stop flushing (F7), or frames are dropped on air and the rule is broken.
- **Sink opens on demand.** No existing consumer loses a frame. A new ISO client on an already running camera sees standby until the sink connects, where today it gets frames at once. That is the same as Program today, bounded by the 3 s discovery deadline.
- **Pacing.** The bridge's rate conversion skips (`Sources/App/ProgramOutputBridge.swift:496-503`) are existing and unchanged. Whether that is acceptable under "every frame" is a separate question for Program cadence.

### CMIO device churn

- A toggle causes none, ever.
- The upgrade only adds devices and removes none. A Separate-mode user gains Program. A Program-mode user gains one device per enabled camera. UIDs and stream IDs are derived from `kind` and `feedID`, so a selected device stays the same device (`Sources/Shared/VirtualCameraRegistry.swift:47-65`).
- No toggle means no main-actor registry handshake, which can wait up to 2 s for an acknowledgement (`Sources/Shared/VirtualCameraRegistryTransport.swift:124-129`).
- The extension's streams all share one serial queue (`Sources/CameraExtension/CameraProvider.swift:547-552`). Inferred: N+1 consumed streams are fine, since samples pass by reference, but this should be checked at 4K with a real client.

### Meeting apps

Repo evidence is limited to `docs/MULTI_CAMERA_PLAN.md:102`, `VALIDATION.md:366-372` (Zoom device-control lease, a second client) and `VALIDATION.md:781` (Zoom cached its camera list until restarted). `VALIDATION.md:829-834` says real Zoom transmission is still unqualified.

**Inferred, not tested:**

- A meeting app may need a restart once to see Program after the upgrade.
- An app holding a selected device keeps it, since the UID does not change.
- An app using "first camera" or a default could pick differently if the order changes. Keeping feeds first limits this.
- One extra camera in a picker is noise for a one-camera user. I accept that as the cost of a stable list.
- Zoom's behaviour if a selected device vanishes is unknown from this repo. This design makes that case rarer: it can only follow removing a camera.

### Extension and app version contract

No change. `currentSchemaVersion` stays 1 (`Sources/Shared/VirtualCameraRegistry.swift:151`). The wire format is unchanged, and the extension source at this commit accepts this registry. Inferred: the installed build 10 behaves the same, since I read the source and did not inspect the installed binary. `Config/Camera-Info.plist` stays at 10, so the Update banner does not fire (`Sources/App/ExtensionInstaller.swift:106-109`) and no approval or restart is needed. Only the app build number moves.

Fixing F6 would need an extension change. It is out of scope here.

### Persisted settings

No migration and no version bump. Keep the JSON key `outputMode` and its two values, with the new meaning "Program controls shown". The decoder already falls back safely (`Sources/App/AppSettingsStore.swift:543`).

Do not bump `currentVersion`. `validated()` rejects any other version (`Sources/App/AppSettingsStore.swift:499`), so an older build would discard the snapshot on downgrade. Keeping the key makes a downgrade work: the old build reads a valid mode and republishes its own device list.

### Main thread and listeners

The monitor adds one system listener plus one per route, and no streams or timers (`Sources/App/CameraDemandMonitor.swift:36-37`). `discover` reads properties on the main queue when the device list changes (`:100-103`, `:130-136`). With no extension installed, routes will hold an error (`:141`). That is shown only through `automaticStatus` (`Sources/App/AppModel.swift:1311`), but `demandRouteID` needs a new rule, since it picks a route by mode (`:1297-1299`).

## 9. Add, rename, remove and reset

`canEditTopology` is one global rule covering operations with different needs. The coordinator's own checks are already per camera (`Sources/Shared/FeedRuntime.swift:346-356`, `FeedCapturePool.remove` in `Sources/App/CaptureController.swift:2733-2755`).

| Operation | Live possible? | What it needs |
|---|---|---|
| **Rename** | **Yes, now.** | Remove the guard (`Sources/App/AppModel.swift:776`). `feedCoordinator.update` already runs live for every settings edit (`:1570`). No device is touched (`Sources/CameraExtension/CameraProvider.swift:592-593`). Sinks match on UID and direction, not names (`Sources/App/CameraSink.swift:430`, `:236-240`), and demand survives a rename (`Sources/App/CameraDemandMonitor.swift:169-172`, `Tests/CameraSinkRoutingChecks.swift:43`). Recording keeps its state (`Sources/App/RecordingModel.swift:812-816`). A take copies the name when it starts (`:865-866`) and builds its path from that copy (`:413`), so a mid-take rename cannot change the open file. The meeting-app name stays stale until the extension restarts (F6), as it does when idle |
| **Add** | **Yes, with two fixes.** | Stop flushing on an add (F7), and do not move the selection to a stopped camera while the director runs (F8). Add a device-count check (section 7a). The new device is a plain add, and monitor targets are rebuilt on every save (`Sources/App/AppModel.swift:1024`) |
| **Remove** | **Yes for a stopped camera, while others run.** | Replace the global rule with: this camera is not running, not stopping, not recording, and has no LUT load in flight. A meeting client on it keeps the device until it leaves, with standby black. Call `reconcileAutoSwitcher` after removal, since the anchor or emphasis may change. If it was Program's selection, `updateFeeds` moves the selection to the first remaining camera, and if a pending cut targeted it, reports that cut as dropped (`Sources/Shared/ProgramOutputRoute.swift:327-342`). Removing a running camera stays refused: stop it first |
| **Reset All Settings** | **No.** | Keep the global rule. It is the one honest use: settings are wiped and the app quits (`Sources/App/AppModel.swift:1605-1615`) |
| **Output mode** | Gone | Section 7 |

The input picker already follows a per-camera rule (`Sources/App/AppModel.swift:1556-1558`).

## 10. Contract or habit?

**Documented, as product shape, with no rationale:**

- `docs/MULTI_CAMERA_PLAN.md:5`, `:52`, `:116`, `:183-184`
- `docs/AUTO_SWITCHER_PLAN.md:35-36`
- `docs/IMPLEMENTATION_MAP.md:33`, `:37`, `:46`, `:107`

**Documented as a rule to keep:** `docs/UI_REDESIGN.md:105` and `:226` ("Gating rules (keep all): device picker and output mode locked while running"). That was a redesign instruction to preserve behaviour, written as an inventory of what existed. This report overrides it if the owner accepts the decision.

**Not a contract:** `docs/APP_CONFORMANCE.md` checks UI against the mockups and has no row saying why the lock exists. `VALIDATION.md` records no qualification of the mode.

**Test-pinned:** yes, see section 11. These tests pin the behaviour, not a need for it. The one test pinning the global rule says so in its name: `testOtherFeedCaptureAndFinishingRecordingBlockTopologyChanges`.

## 11. Tests that change

**Rewrite for the new behaviour:**

| File | Tests |
|---|---|
| `Tests/VirtualCameraRegistryPublishingChecks.swift` | `testSeparateModePublishesOneStableDevicePerEnabledFeed`, `testProgramModePublishesOnlyProgramAndAdvancesGeneration`; signature change in `testForeignGroupDoesNotSupplyGeneration`, `testInvalidSameGroupSnapshotDoesNotSupplyGeneration` |
| `Tests/ProgramOutputRouteChecks.swift` | `testFeedCoordinatorPublishesSeparateOrProgramRegistryAndProgramDemand` (:118), `testSelectionWithNothingOnAirChangesAtOnce` (:134), `testFeedCoordinatorMutatesTheLiveProgramScheduler` (:76), `testCaptureDeliveryReachesTheProgramCameraOffTheMainThread` (:444), and the fixtures at :508, :562, :1225 (need Program active instead of `outputMode: .program`) |
| `Tests/FeedRuntimeChecks.swift` | `testProgramDemandIsReleasedWhenLeavingProgramMode` (:119), which pins the dead path in F4; `testCoordinatorKeepsStableOrderAndLazilyCreatesSessions` if the property is renamed |
| `Tests/MonitorLifecycleChecks.swift` | `programTransportRequired` cases (:55-67); `testOtherFeedCaptureAndFinishingRecordingBlockTopologyChanges` (:94) becomes per-camera rules |
| `Tests/UIPresentationChecks.swift` | `program(...)` helper (:24), `testProgramTallyIsOnAirOnlyWithAClient` (:55), `testSeparateTallyRequiresRunningAndInUse` (:72), `testOutputLinesNeverNameTheConsumerApp` (:78), `testProgramOutputLines` (:99), `testProgramStatusSaysOnAirOnlyWhileInUse` (:358), `testProgramWarningPrecedence` (:859) |
| `Tests/SettingsChecks.swift` | :108-119, :153, :194 stay valid if the key stays; rename only |
| `Tools/UIVerify/ProgramOutputVerify.swift` | `rules`, `pendingSwitch`, `menuBar`, `views`: mostly deleted (:61-290) |
| `Tools/UIVerify/main.swift` | :939, :1100-1104, :1805-1809; `settle { model.canEditFeedTopology }` at :842, :848, :1080-1083 needs a LUT-settled check instead |
| `scripts/test-app-source-integration.py` | The stub at :32-33 mirrors the guard in `feedAutoSwitcherAudio` |

**Keep unchanged, and they support the design:**

- `testProgramHandlerRunsAfterCameraAndCanBeSwappedWhileFramesFlow`
- `Tests/CameraRegistryRuntimeChecks.swift` in full
- `testResetAndTopologyChangesFenceTheCurrentRepeatSchedule` (`Tests/ProgramCadenceCPUChecks.swift:59`): a replaced feed list must still flush
- All 43 `setCameraOutputEnabled(false)` call sites in `Tests`, if the method is kept
- Fixtures passing `outputMode:` in `Tools/UIVerify` and `Tools/MonitorAppIntegration`, if the initializer is kept

**New tests needed:**

- Registry contains all enabled feeds plus Program, in order, for any saved `outputMode`
- Device list is unchanged by the Program controls toggle (generation does not change the devices)
- `updateFeeds` add while on air: no flush, every frame published
- `updateFeeds` removal still flushes
- Sink follows route demand both ways while frames flow, with no capture restart
- ISO and Program both live: each gets every frame, with no copy
- `programActive` table (client, monitor, take with Auto)
- A manual Start does not start other automatic cameras
- No-consumer branch: no GPU submission, monitor and recording still get every frame, telemetry is correct
- Rename, add and removal of a stopped camera while another records

## 12. Risks and order of work

### Top risks

1. **The no-consumer branch has never run in the app.** Turning it on changes a lot:
   - `applied` becomes nil, so `camera.applying` reads true (`Sources/App/UISessionBridge.swift:126-127`) and the UI would say the output is updating.
   - `frames`, `outputFPS` and `mediaTime` stop, because they advance only in `didDeliver` (`Sources/App/CaptureController.swift:2319-2320`).
   - The user sees "Camera ready — no active video destination." (`:2150`).
   - `releaseIdleResources` runs, so the first demanded frame rebuilds on the live path, and `makeProcessor` runs on the capture queue (`:2156`). Build the processor at start as today (`:574-577`) and measure the first frames after demand arrives.
2. **Sink flapping.** Inferred: meeting apps may open and close devices while enumerating or previewing. Connects are async and state changes are de-duplicated (`Sources/App/CameraDemandMonitor.swift:191-196`), but measure this. Add a short hold before closing only if it proves necessary.
3. **Route-lock coupling** between ISO and Program (section 8).
4. **Late-sink negotiation against a client that already holds device control.** This is the automatic-mode path validated with Zoom (`Sources/App/CameraSink.swift:463-466`, `VALIDATION.md:366-370`), but it has not been tested on a camera already running mid-stream.
5. **Behaviour change.** Cameras no longer come up together just because one was started. Program's sources start when Program is wanted. Operators may need telling.

### Order

Each step can ship alone.

1. **Topology rules:** fix F7 and F8, split `canEditTopology`, allow rename, add and stopped-camera removal live. Fix F2.
2. **Demand core:** always-on monitor, `programActive`, sinks by route, async sink toggle. The mode still exists and now only selects what is published.
3. **Publish both, retire the mode:** one projection, `setProgramActive`, the view preference, new tally and status, delete the switch code.
4. **GPU gate:** make the no-consumer path production quality (risk 1).
5. **Docs:** `docs/MULTI_CAMERA_PLAN.md`, `docs/AUTO_SWITCHER_PLAN.md:35`, `docs/UI_REDESIGN.md:105,226`, `docs/IMPLEMENTATION_MAP.md`, `README.md:131,438`, and a `VALIDATION.md` entry.

### Size (estimate)

- 102 lines mention `outputMode` across 15 source files.
- Expect roughly 500 to 800 changed lines in about 18 source files, with the UI side shrinking.
- About 9 test or tool files change, plus about 10 new tests.
- Roughly 3 to 5 working days, including qualification with real meeting apps.
- No extension change.

### Qualification needed before calling this done

This requires a real meeting app, run by the owner when Ultracam is not serving a meeting:

- Upgrade with Zoom holding a camera
- Whether Zoom needs a restart to list Program
- Program in Zoom plus ISO in a second app at once, at 4K
- Time to first frame on an ISO client joining a running camera
- Open and close flapping
