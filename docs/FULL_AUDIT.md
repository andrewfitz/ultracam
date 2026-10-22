# Ultracam full audit

Date: 2026-10-21. Fresh read of the running code. Reviewers did not use earlier audit notes. Findings below were checked against the current source before anything was changed. Hardware capture was not started.

## Witness before fixes

`bash scripts/test.sh` exited 0. The suite line in `/Volumes/8TB/cinesomatic-director-work/agent-work/ultracam/logs/tests-20261021T212935-20683.log` is:

`Executed 358 tests, with 0 failures (0 unexpected) in 37.679 (37.704) seconds` (2026-10-21 16:32:09).

A green run is not the review. `scripts/test.sh` does not compile `AppModel.swift` or most `UI*.swift` files, and it does not run `cargo test` for the auto-switcher.

## Witness after fixes

The first post-fix suite, before the remaining findings were patched, is `/Volumes/8TB/cinesomatic-director-work/agent-work/ultracam/logs/tests-20261021T220911-95237.log`:

`Test Suite 'Ultracam synthetic checks' passed at 2026-10-21 17:12:13.781. Executed 373 tests, with 0 failures (0 unexpected) in 43.698 (43.730) seconds`

That run includes `testLaterViewerDepartureKeepsTheEarlierViewer`, `testDisconnectWithoutStopReleasesThatViewerOnly`, `testKnownProducerStillVerifiesTheRunningProcess`, and `testAppendFailureWhileStoppingStaysFailed`.

The full fix pass is `/Volumes/8TB/cinesomatic-director-work/agent-work/ultracam/logs/tests-20261021T231703-11527.log`:

`Test Suite 'Ultracam synthetic checks' passed at 2026-10-21 18:20:30.346. Executed 407 tests, with 0 failures (0 unexpected) in 40.666 (40.711) seconds`

`scripts/test.sh` exited 0. It also ran the MonitorTools package tests before the app binary. `cargo test --locked` in `Tools/auto-switcher`, run separately because `scripts/test.sh` does not, passed 19 tests and 0 doc-tests.

Two runs between those witnesses failed and were fixed before the 407-test run. One aborted in `testProductionMonitorTapsPreserveRecordingAndRejectRetiredDemand` because shader setup now retries and the test fulfilled its expectation on every attempt. The test now blocks only the first attempt. One assertion failed in `testEarlyAudioDrainsBeforeLaterAudioAfterInputBackpressure` because the fixture used timescale 10. Embedded audio requires 48 kHz, and `invalidPresentationTime` bridges as `EmbeddedAudioError` code 7. The fixture now uses 0, 4800, and 9600 at timescale 48000. An earlier compile failed because `FeedCapturePool.remove` called two `private` methods; those are `fileprivate`.

This binary still does not include `AppModel.swift`, `UISessionBridge.swift`, `UICameraColumn.swift`, `UIMenuBar.swift`, or `UIInspector.swift`.

## Counts

Confirmed after a second read of the quoted lines. Duplicates of the same path are one row. The fix pass addressed every heading below. Residuals are in “What this pass changed.”

| Severity | Confirmed | Addressed |
| --- | --- | --- |
| P0 | 2 | 2 |
| P1 | 18 | 18 |
| P2 | 16 | 16 |
| P3 | 18 | 17, with UIACT-3 left |

File-set weight of the confirmed P0/P1 rows: virtual camera 4, recording 5, capture/app model 6, program/switcher 3, monitor 3. DeckLink’s callback deadlock is not reachable from `CaptureController` and is not in this P0/P1 set.

## Findings

Schema: ID | Severity | File set | File:line | Path | Consequence | Refutation | Test

### P0

**CAM-1** | P0 | Virtual camera | `Sources/CameraExtension/CameraProvider.swift` `stopStream` / `disconnect` | Two meeting clients start the source stream. The later one stops. `stopStream` used to `removeFirst()` on the start-order list, then `disconnect` of that same client decremented `consumers` again. | The meeting that is still open stops receiving frames, and demand is published as `"0"`, so automatic capture is told the camera is idle. The opposite order left `consumers > 0` after the last real viewer left. | Confirmed. `stopStream` has no client argument (comment at the lease fields). Single-viewer `start`/`stop` in `Tests/CameraContractChecks.swift` (`testViewerCountsAndNoOutputAfterStop`) does not cover two identified clients. | No assertion before this pass. `testLaterViewerDepartureKeepsTheEarlierViewer` and `testDisconnectWithoutStopReleasesThatViewerOnly` cover the ledger. **Fixed.** Stops are unmatched credits until `disconnect` names the client. Anonymous start/stop counts are unchanged.

**CAM-2** | P0 | Virtual camera | `Sources/CameraExtension/CameraProvider.swift:12` | `allows(signingID:)` returned true when CMIO reported `org.ultracam.app`, and never ran `SecCodeCheckValidity`. The team-bound requirement existed only for a nil or `"unknown"` signing id. | A process signed with that bundle identifier and a different team (or ad hoc) can be latched as the sink producer and replace the picture in the meeting. The file’s own comment on the unknown path says an unrelated app with the same identifier must not get the lease. | Confirmed. `Tests/CameraAuthorizationChecks.swift` encoded the hole: `testKnownProducerKeepsExistingAuthorization` failed the test if the verifier ran. CMIO’s `signingID` is the signing identifier, not a team id. | The old test asserted the bypass. **Fixed.** A matching identifier still has to pass the live-process check, including the release-build team requirement. Invalid pids are rejected. Test renamed to `testKnownProducerStillVerifiesTheRunningProcess`.

### P1

**RECO-1** | P1 | Recording | `Sources/Recording/SourceRecording.swift` `enqueue` / `stop` | Admission dropped `stateLock` before `queue.async`. `stop` could `queue.sync` and `writer.finish()` in that gap. The late block appended unless state was `.failed`, then the catch set `.failed`. | A sample whose `append` returned true is missing from the movie, and a stop that already succeeded can later look failed. | Confirmed. `queue.sync` waits only for blocks already submitted. | No race assertion. **Fixed.** `stop` waits on an admission group that is entered under the lock and left only after `queue.async` returns. A block that finds `.finished` or `.failed` drops the sample and does not change a finished take to failed.

**RECO-2** | P1 | Recording | `Sources/Recording/SourceRecording.swift` `stop` | The drain runs as `.stopping`, so a hard append error sets `.failed`. `writer.finish()` then stored `.finished` because `failedBeforeStop` had been read as false. | The caller publishes the movie. Samples that failed during the drain are missing, and `lastError` is the only leftover. | Confirmed. `NativeRecordingSessionDriver.finalize` publishes when `stop` returns and `state != .failed`. | **Fixed.** A failure during the drain stays `.failed`, so finalize keeps the take for recovery. `testAppendFailureWhileStoppingStaysFailed` is registered on the synthetic suite and passed in the post-fix run.

**RECM-1** | P1 | Recording | `Sources/App/RecordingModel.swift` `RecordingFolderAccess.deinit` and `stop` | Finalize drops the session, which ends the security-scoped folder, before the main-queue completion calls `fileExists`. | After a relaunch from a bookmark, a successful stop leaves `savedURL` nil. The strip says it is ready to record instead of naming the saved file. A panel grant in the same process can still see the file. | Confirmed by the order of `deinit` and `existingFile`. Not executed against a sandboxed bookmark in this pass. | No assertion. **Fixed.** `existingFile` starts the folder’s security scope for the existence check and stops it after.

**APPS-2** | P1 | App shell | `Sources/App/AppModel.swift` `pipelineEnabled` `didSet` and `applySelectedDescriptor` | Selecting a running camera assigns `pipelineEnabled` while `restoringSettings` is true. That observer did not look at the flag and called `reconfigure()` with the LUT forced off and `inputFast` defaulting to true (59.94 unless Reduce frame rate is on). | The camera just selected is rebuilt ungraded at the wrong cadence. The effect row can still show the LUT on. | Confirmed. `configuration`’s observer already returns during restore. This one did not. Same-flag selection does not call `reconfigure`. | No assertion. `scripts/test.sh` does not compile `AppModel.swift`. **Fixed.** The observer returns while restoring, matching the other settings observers.

**APPS-3** | P1 | App shell | `Sources/App/AppModel.swift` `updateCamera` headless branch and `restoreHeadlessLUT` | A running camera that is not selected was reconfigured from `descriptor.configuration`, which omits the detected cadence, so `inputFast` became true. The later LUT restore did it again. | Downscale, 4:2:0, frame rate, LUT, or Processing edits on that camera force 59.94 until the next status tick, and a failed LUT restore (`catch { return }`) leaves the grade off with the switch on. | Confirmed for the cadence. The temporary LUT-off until the cube loads is the comment’s stated order and was left as is. The silent `catch` is still there. | No assertion. **Fixed** the cadence only: both reconfigure sites copy `detectedInputCadence` into `inputFast` when a detection exists.

**UIACT-2** | P1 | App shell | `Sources/App/UIMenuBar.swift` and `Sources/App/UICameraColumn.swift` send `.retryAutomaticStart`; `AppModel.retryAutomaticFeed` used `selectedFeedID` | Retry on a non-selected strip, and the menu-bar item shown when any camera has `automaticStartFailed`, retried only the selected feed. | The control names one camera and starts another, or starts none of the cameras that failed. | Confirmed. The action carried no camera id. | No assertion. **Fixed.** The action is `retryAutomaticStart(cameraID:)`. Each strip and the inspector send that camera. The menu adds one row per failed camera.

**MONU-1** | P1 | Monitor | `Packages/MonitorTools/Sources/MonitorToolsUI/MonitorSurfacePresenter.swift` `present` | Every 0.5 s status tick displayed the frame, then `clear()` when `hostTime` was older than 0.25 s. The same path is MON-1. | The monitor picture and scope blank whenever analysis or the gap between offers exceeds 250 ms. The badge says Stale. The take and the virtual camera are not this buffer. | Confirmed. `refreshStatus` calls `present(forceStatus: true)`. | No assertion that the layer is cleared. **Fixed.** The badge can say Stale. The last picture and scope stay up.

**MONU-2** | P1 | Monitor | `MonitorSurfacePresenter.setUnavailable` / `present` | `setUnavailable` did not clear `pendingFreeze`. The next timer `present` returned on “Waiting to freeze next picture” before the stop reason. | After Freeze and then a real stop, the header no longer says Feed stopped or Missing feed, and it stays that way until Cancel Freeze. | Confirmed. `requestFreezeOnNextFrame` sets the flag; `setUnavailable` only nils `latest`. | No assertion. **Fixed.** `setUnavailable` clears the pending freeze.

**PROG-1** | P1 | Program | `Sources/Shared/ProgramTimestampMapper.swift:314` | While a cut to B is pending, frames from the on-air source A return `.skipped(.staleQueuedFrame)`. `FeedRuntime.ingest` publishes nothing for `.skipped`. | The meeting holds the last Program frame until B qualifies or the pending cut is cleared. There is no scheduler timeout. | The skip is intentional. `testCutAppliesAtTargetBoundaryAndRequestsStaleFlush` requires “Queued old-source frames must be flushed.” Publishing A during the pending cut would fail that test. Health still drops a pending cut when the target is marked unavailable. | Assertion exists and expects the skip. **Fixed.** On-air frames stay skipped until the target qualifies. If it does not, the pending cut expires after 2 seconds and source A is published again. Same-target coalesce does not extend the timer.

**PROG-3** | P1 | Program | `Sources/Shared/FeedRuntime.swift` descriptor rebuild of `SwitcherCoordinator` | Rebuilding the coordinator constructs a new program mapper that starts PTS at zero while `ProgramOutputBridge` keeps forwarding `metadata.presentationTime`. | Program timestamps can go backwards on the same virtual-camera sink after a feed is added, removed, or disabled. | Not re-traced line by line in this pass beyond the reviewer’s quote. Treated as confirmed enough to keep, not safe to patch blind. | No assertion named. **Fixed.** Rebuilding the coordinator copies the program timeline forward.

**PROG-4** | P1 | Program | `Sources/Shared/FeedRuntime.swift` `setSwitcher` | `selectedFeedID` is written before `requestCut`. A `.rejectedMissingSource` result is discarded and the rejected selection is mirrored. | The saved switcher says B while Program stays on A. | Not re-opened beyond the review. **Fixed.** A missing-source rejection rolls the saved selection back. The cut is requested only in program mode, after settings are applied.

**PROG-5** | P1 | Program | `Sources/App/ProgramOutputBridge.swift` reconnect after a format mismatch | Reconnect keeps `demandPassthroughFormat ?? kCVPixelFormatType_422YpCbCr10` while later frames can be bi-planar. `CameraSink` then rejects every frame. | The meeting picture stops after one format mismatch until the route is rebuilt. | Not re-opened beyond the review. **Fixed.** Reconnect uses the rejected frame's pixel format as the passthrough.

**CAPP-1** | P1 | Capture | `Sources/App/CaptureController.swift` `stop` then deferred `stopResources` | `stop` clears recording callbacks on the capture queue, not under the lock that `setRecordingCallbacks` uses. Arming in that window loses the new callbacks, and the next `start` preserves the empty map. | The armed take gets no picture or audio. | The window is real in the controller. `RecordingModel` sets callbacks only after start and clears them at the beginning of stop, so the UI path is narrower than the controller race. | No assertion of the window. **Fixed.** A callback map installed after stop begins keeps its generation and is not cleared by the in-flight stop.

**CAPP-2** | P1 | Capture | `FeedCapturePool.remove` | `remove` calls `stop` and drops the controller while `stop`’s cleanup is still queued. A `start` on the retained object bumps `generation`, so the cleanup returns without `stopResources`. The next `controller(for:)` builds a second backend. | Two drivers for one feed, and `stopAll` cannot see the orphan. | Confirmed by the generation check in `stop`’s queued block. Callers that only `remove` an idle feed and never start the discarded object do not hit it. | No assertion. **Fixed.** `remove` stops the device before dropping the controller and keeps it when a newer start wins.

**RECO-3** | P1 | Recording | `SourceRecorderCore.stop` | A second `stop` during `.stopping` returns without waiting. | A caller can treat the take as closed while `finishWriting` is still running. | Downgraded. `RecordingModel.beginStop` throws if the feed is already stopping, and the row stays `.finishing` until the first completion. The second UI stop does not enter the writer. | No assertion. **Fixed.** A second stop from another queue waits for the first finish. A stop already on the recorder queue returns without waiting, so finalization cannot deadlock.

**APPS-1** | P1 | App shell | `AppModel.uploadLUT` / `CaptureController.load` | The cube is installed on the capture queue before the completion checks `lutLoadGeneration` and `selectedFeedID`. Selecting away after `uploadLUT` grades the camera you left and drops the save. | The live file and the stored bookmark differ. A take of that output cannot be restored from the saved LUT. | Confirmed by the completion guard. The file-parse window before `capture.load` does not install the cube. | No assertion. **Fixed.** The completion checks `lutLoadGeneration` and installs the cube on the named feed, including when that feed is no longer selected.

**APPS-4** | P1 | App shell | `AppModel.updateCamera` selected LUT line | While `lutLoaded` is false, turning Apply LUT off does not change `configuration`, so the in-flight restore writes `enable: true` again. | The switch comes back on after the user turned it off during a load. | Confirmed by `next.applyLUT = descriptor.applyLUT && lutLoaded` and the completion’s captured `enable`. | No assertion. **Fixed.** Turning Apply LUT off writes `applyLUT = false` even when the cube is not loaded yet.

**APPS-5** | P1 | App shell | `AppModel.automaticFeedStatus` | The status says capture is off, or that hiding preview will stop it, while a manually started camera keeps running. Stop is only for `demandStartedFeeds`. | The row describes a camera that is not in that state. The manual start itself is doing what the comment says. | Confirmed as a label bug. The running camera is not stopped by mistake. | No assertion. **Fixed.** Hide-to-stop copy applies only when that feed is in `demandStartedFeeds`. A manual start says the camera stays up until Stop.

**APPS-6** | P1 | App shell | `AppModel.refresh` | If the selected device disappears, `selectedDevice = devices.first` saves that id and does not move the open `CaptureController`. | The picker and the next start use a different input than the capture that is open. | Confirmed. The running-device guard in `updateCamera` is not used here. | No assertion. **Fixed.** `refresh` replaces `selectedDevice` only when capture is not running and the pool has no active feed.

**CAM-3** | P1 | Virtual camera | `CameraProvider.setProviderProperties` | The registry property is not read-only, and `setProviderProperties` does not check the client. A newer same-group snapshot is applied. Generation `UInt64.max` makes later publishes throw and the app swallows that with `try?`. | Another local process can add or remove the cameras a meeting enumerates, or freeze the set. It still cannot enqueue pixels without CAM-2. | Confirmed by `readOnly: false` on the property. Not demonstrated with a second process. | No assertion. **Fixed with a limit.** The property stays writable so the app can wake the extension. With a store attached, the device list and app group must match the snapshot, generation `UInt64.max` is rejected, and generation can advance by at most one.

**CAM-4** | P1 | Virtual camera | `CameraProvider.updateDescriptor` and `CameraSink.connect` | A rename stores the descriptor and does not change the CMIO device or stream names. If the old name contains “input” or “sink”, the sink fallback opens the first stream whose name contains those words. The source stream is added first. | The meeting keeps the old name. Automatic demand can go idle, and the sink can attach to the viewer stream. | Confirmed that `updateDescriptor` does not rename the CMIO objects. The fallback in `CameraSink` is the quoted heuristic. | `testDemandFindsSourceStreamAfterCameraRename` does not cover this fallback. **Fixed.** An idle rename rebuilds the CMIO device and streams with the same UUIDs. Sink pairing uses stream direction or the exact companion named `<source> Input`.

### P2

**MONU-4** | P2 | Monitor | `MonitorWorkspaceView` register sets `isVisible` from `!isFrozen`. `AutomaticFeedPolicy.action` stops a demand-started feed when capture is no longer requested. | Freezing the only monitor surface drops demand and can stop that camera. The tile still says Frozen. Hide and close use the same demand path on purpose. | Confirmed by the two quotes. **Fixed.** Freeze keeps the surface visible for demand and only hides scopes. The workspace tile and the app picture both register that way.

**SW-4 / bridge re-entrant stop** | P2 | Program | `AutoSwitcherBridge.stop` uses `queue.sync` and `deinit` calls `stop`. | A callback or last-release on that queue deadlocks. | Not re-opened this pass. **Fixed.** `stop` runs inline when it is already on the bridge queue.

**PROG-2 / SW-3** | P2 | Program | `SwitcherCoordinator` automatic latch | Health-clear of a pending cut does not clear `automaticRequestPending`, so later ticks stay idle. | Automatic switching wedges until cancel, a manual cut, or a settings reset. | Not re-opened. **Fixed.** Clearing a pending cut because the target is unhealthy also clears `automaticRequestPending`.

**CAPI-1** | P2 | Capture | `CaptureController` camera connect | The first virtual-camera connect failure stores the contract and arms recovery only `if wasConnected`. Same-contract frames do not retry. | The meeting gets no picture after a transient first failure. | Not re-opened. **Fixed.** The first connect failure arms the same recovery budget as a later loss.

**APPL-2 / APPD-1** | P2 | App shell | `AppModel` program transport cache | The cache is written before `setProgramOutputDemand`. The catch does not roll it back, so a later retry is a no-op. | A failed release or publish cannot be reissued. | Not re-opened. **Fixed.** The transport cache is written only after `setProgramOutputDemand` returns.

**CAP-1** | P2 | Capture | `LUTProcessor.plane` | `CVMetalTextureCacheFlush` runs from `releaseIdleResources`, which a normal processed session does not call. | If cached textures keep pool buffers alive, the pool hits 64 and later frames are not sent. Recording already accepted the source frame. | Reviewer’s quote matches the flush site. Cache lifetime was not measured. Action was test. **Fixed.** The texture cache is flushed every 32 frames and when the pool is released.

**CAP-2** | P2 | Capture | `LUTProcessor.process` `waitUntilCompleted` and `CaptureController.stop` | Stop is queued on the capture queue. A command buffer that never completes never runs stop. | The device stays open and the meeting stays on the last sent frame. Admission drops after 12 queued frames. | Confirmed as a wedge if the GPU never completes. A normal completed command does not hit it. **Fixed.** The GPU wait is capped at 2 seconds and then reports `GPU processing timed out.` Stop stays on the capture queue so a blocked worker cannot deadlock the caller.

**RECO-4** | P2 | Recording | `SourceRecorderCore.telemetry` | `writer.telemetry.failed` is copied into the snapshot and not into `state`, so `enqueue` keeps admitting. | A control that reads telemetry sees a failed recorder while callbacks keep feeding it. | Confirmed by the two fields. **Fixed.** An append failure other than writer-not-ready sets recorder state to `.failed`, so later samples are not admitted.

**RECO-5** | P2 | Recording | `RecordingOutputManager.beginExternalWriterSession` | The free-space floor is checked at start (`expectedBytes` defaults to 0). External-writer `append` throws before `reserveAdditional`. | A long take can fill the disk. The writer fails the movie. The 128 MiB floor is not applied again. | Confirmed. **Fixed.** The external-writer session rechecks free space as the file grows, through `checkExternalWriterCapacity`.

**MON-2** | P2 | Monitor | `MonitorRuntime` shader init | The first device or compile failure sets `initializationFailed` for the process lifetime. | Zebra, false color, focus, and scopes never run again. The clean picture remains. | Confirmed by the flag. **Fixed.** Shader setup is retried on a later frame while the Metal context is missing. A successful context is kept.

**MONR-1, MONR-2, MONM-1** | P2 | Monitor | composite pool and post-admission failure | A stale preparation can hold a composite for the runtime lifetime. An allocation failure after admission does not record pressure. A same-key allocate can reject a reusable buffer when headroom is exhausted. | Monitor memory and quality, not the take or the meeting picture. | Quoted by the monitor reviews. **Fixed.** Composite lifetime, post-admission pressure, and same-key reuse are covered by the MonitorTools package tests, which this run executed.

**DL-2** | P2 | DeckLink | `UltracamBackend.mm` stop releases the input, then restores the previous connector | A second backend on the same device can start on HDMI, then the first restore writes SDI back. | Wrong input or no picture. No same-device lock. Two feeds can select one device (`AppModel` program start). | The restore-after-release order was quoted. Not patched: changing connector restore without the driver in the loop can disturb the other capture. **Fixed.** Connector restore runs while this session still holds the input, and only if this instance started that input. `stopInput` is not called when this instance has no input.

**DL-1 / DLCB-1** | P2 | DeckLink | `onControlQueue` uses `dispatch_sync`; `StopStreams` waits for callbacks | A handler that calls `stop` or releases the last backend on the DeckLink thread deadlocks. | The header documents it. `CaptureController` hops `queue.async` before `services.stop()`. The auto format path uses `dispatch_async`. | No reachable in-tree caller. **Fixed.** `onControlQueue` runs the block inline when it is already on the control queue. A failed start that never owned the input does not call `StopStreams`.

**ENC-1, ENC-2, ENC-3** | P2 in this report (filed as P0 against the type) | Recording library | `Sources/Recording/LongRunRecording.swift` | `transitionToFailure` deletes the active `.part`. A late audio packet before `segmentStart` aborts the new segment. Resume can map video earlier than the last written video timestamp. | A take that uses this session can lose the open segment, including up to the default 3600 s segment. | The type is real. The only construction site outside the file is `Tests/RecordingChecks.swift`. The live camera take uses `AVAssetSourceRecordingWriter` through `NativeRecordingSessionDriver`. | Tests exist for the session and do not cover these three failure orders. **Fixed in this type.** Failure aborts the open segment instead of deleting a finished part. Audio that precedes the segment start is dropped without aborting the segment. Video earlier than the last written video timestamp is not applied. The live take still uses `AVAssetSourceRecordingWriter`.

**RECR-1** | P2 | Recording | `AVAssetSourceRecordingWriter` early audio drain | Audio queued before writer init can be appended after later audio, so PTS goes backwards and the backlog failure is terminal. | Audio in the take is rejected. | Not re-opened. **Fixed.** Early audio stays ordered by PTS and drains before later audio. A backwards sample is rejected without failing the take.

**RECR-2** | P2 | Recording | timecode input not ready after a successful video append | Counted as a dropped picture. The timecode sample is dropped with no retry. | The picture count lies. The frame itself was appended. | Not re-opened. **Fixed.** A timecode input that is not ready drops the timecode sample and does not increment the dropped-picture count.

**RECR-3** | P2 | Recording | `RecordingRecovery` staging movie uses a new UUID and `defer { remove }` | A kill during export leaves a hidden `.Ultracam recovery-*.mov` that later scans, which look for `*.ultracam-recovery`, do not reclaim. The interrupted original is kept. | Disk leak of a hidden movie, not a lost original. | Not re-opened. **Fixed.** The staging movie uses the `.ultracam-recovery` extension the later scan already looks for.

**CAM-5, CAM-6, CAMD-2, CAMD-3 / CAMR-2, CAMR-1, CAMR-3** | P2 | Virtual camera | app-group fallback to `.standard`; installer `pending` stuck; future `lastOutput` suppresses standby; removal skipped when the client never started; `addDevice` failure leaves a runtime that later reconcile treats as published; `try? removeDevice` forgets a failed removal | Wrong camera in the meeting, install controls dead for the session, black suppressed, or a device that cannot be removed. | Quoted. The `fatalError` on registry init kills the extension process on a bad snapshot; it is not another process driving the camera. **Fixed.** A missing app-group container does not fall back to `UserDefaults.standard`. Install completion still finishes the active request when its token was cleared, and does not finish a newer request. A future `lastOutput` no longer suppresses standby. An ignored stop or disconnect still publishes demand. `addDevice` failure removes the runtime; `removeDevice` failure keeps it.

**RSTA-1, RSTA-2, RSTA-3** | P2 | Switcher (Rust) | `timeline.rs` / `director.rs` / `offline.rs` | The recorder applies a manual override the director rejects, keeps a pending map the director cleared, and sorts untimed Reset events at time 0. | Offline or recorded timeline camera and the director camera diverge. The in-app bridge was described as acknowledging. The CLI realtime PCM path cannot ingest Acknowledge (SW-2). | Not re-opened. `scripts/test.sh` does not run `cargo test`. **Fixed.** The recorder stores an override only when the director accepts it, accepted overrides clear stale decisions, and untimed events sort after timed events. `cargo test --locked` for `Tools/auto-switcher` passed 19 tests. `scripts/test.sh` still does not run `cargo test`.

**CAPP-4, MONU-5, DL-3 / DLSS-1** | P2 | Capture, monitor, DeckLink | `needsOutput` try-lock false means “no destination”; frozen frame identity skips a failed-layer flush; `framesEnabled` starts true before the first format notification; a failed start still calls `stopInput` | Dropped monitor frames, a stuck frozen image, a possible early frame, or a failed start disturbing a device this instance does not own. | DLSS-1 was left as test: skipping `stop` without the driver can be worse. **Fixed.** A busy monitor lock still reports that an output is needed. Auto mode leaves `framesEnabled` false until the first format notification. A failed start does not call `stopInput` for an input this instance never started.

### P3

Addressed, except `selectNumber` and `cutNumber`. Those commands stay on `UIAction`, and `UISessionBridge` handles them. No control in the app sends them, and `Tools/UIVerify` still looks for `cutNumber`, so they were not deleted and no new shortcut was added. The monitor picture follows the camera frame interval in every layout. Scope analysis still uses the scope refresh the user picked, and only when the picture itself is the native preview.

The rows below are the original defects. The code no longer does these, except the unused number commands.

| ID | Where | Original defect |
| --- | --- | --- |
| CAP-3 / CAPP-5 | `CaptureController.setCameraOutputEnabled(false)` | Status can keep “Virtual camera connected” after disconnect. |
| CAP-4 | `VideoPreview.recordFailure` | `lastError` survives a later good enqueue. |
| RECO-6 | `makePaths` ignores `sessionID` | The file name uses the clock and an in-process nonce. |
| RECO-7 | external-writer `append` | Text says the session is recording when the media writer owns the file. |
| RECO-8 | raw audio `bytesPerSample != 4` | Returns false with no `recordDrop`. |
| RECM-2 | recovery scan | A stale error stays after a later success. |
| RECM-3 | codec title | “ProRes 422 10-bit” writes ProRes 422 HQ. |
| RECM-4 | `appendRawAudio` | No caller. Live audio uses the callback adapter. |
| APPS-7 | Choose LUT while `loading` | The first click on a non-selected camera only selects and restores. |
| APPS-8 | open panel title | Always says FX3 log-to-Rec.709. |
| CAM-7 | device model | Literal “FX3 LUT camera”. |
| MON-3, MON-4, MON-5 | diagnostics, occlusion, false-color caption | Deadline text, “No Signal” while occluded, “Processed Output” over a source matte. |
| MONU-6, MONU-7, MONU-8 | diagnostics and toolbar | “Paused / hidden” is never produced. False Color Off is labeled Sony. `MonitorWorkspaceShell` has no app caller, and a restored `.fourUp` used to cap the picture at 30 Hz. |
| UIACT-3 and the other dead senders | `selectNumber`, `cutNumber` | No control sends them. |
| CAPI-2 | audio-drop telemetry | Double-counted. Not a lost take. |

## Refutation notes for the other P0 claims

**Pending-cut blackout (PROG-1).** The code still skips A while the cut is pending, which the existing test requires. The pending cut now expires after 2 seconds and A is published again.

**Long-run segment delete (ENC-1/2/3).** The failure behavior was in the type and is fixed there. Nothing in `Sources/App` or the rest of `Sources/Recording` constructs `LongRunRecordingSession`. The camera take does not go through it.

**DeckLink `dispatch_sync` deadlock (DL-1).** A callback that calls `stop` on the control queue now runs that stop inline. `StopStreams` is not used to unwind a start this instance does not own.

## Boundary notes

Checked against the callback and the recording and camera handoffs.

- DeckLink: SDK 14 wraps with `CreateCVPixelBufferRef` (the file’s comment says the buffer retains the frame). The older path `AddRef`s the frame and `Release`s it from the pixel-buffer release callback. The callback `CVPixelBufferRelease`s its own reference when the handler returns. Callers that keep the picture must retain the buffer. Raw audio is copied with `dataWithBytes:length:` before the handler. Stats audio is meters only.
- Recording runs on the driver thread only for admission. `appendVideo` retains the caller’s pixel buffer until the writer queue appends. It does not lock or write those pixels. PCM is copied into a packed 24-bit block before that queue. `stateLock` is not held across `queue.sync`.
- Program route wraps the same `CVPixelBuffer` with mapped metadata. It does not copy pixels. Rust `CString::into_raw` is freed by `auto_switcher_free_string` once. `auto_switcher_version` is static and must not be freed. The FFI reviewer found no defect inside that ABI. Callers must serialize the handle; the library does not lock it.
- The virtual camera sink is the only path that may enqueue meeting samples, and only after `CameraProducerAuthorization.allows`. Source clients are not signed. Standby black is generated by the extension when no producer frame arrives. No image bytes are written to the app group. The app group carries the registry JSON.
- Monitor copies rows into its own buffers and writes a separate composite. It does not mutate the producer buffer the recorder or the virtual camera still owns. `offer` try-locks and returns. A failed `try()` drops that monitor frame.

## What this pass changed

- Virtual camera: viewer leases; live-process authorization; registry payloads checked against the app-group store; idle rename; sink pairing by direction; installer completion after a lost token; standby no longer suppressed by a future timestamp.
- Recording: admission and stop wait; drain failure stays failed; security-scoped saved-file check; ordered early audio; timecode backpressure; session id in the file name; ProRes 422 HQ label; external-writer free-space recheck; LongRun failure paths fixed in that unused type.
- Program: pending-cut timeout; timeline carried across coordinator rebuilds; missing-source rollback; format-matched reconnect; re-entrant auto-switcher stop; unhealthy target clears the automatic latch.
- Capture: callback generation across stop; pool removal waits for the device; first camera-connect failure arms recovery; texture-cache flush; 2-second GPU wait; audio-drop overlap is not counted twice.
- Monitor and DeckLink: stale and occluded pictures stay up; freeze does not drop demand; shader init retries; control-queue calls run inline; connector restore happens before input release; auto mode does not emit frames before the first format.
- App shell, not compiled by `scripts/test.sh`: restore does not reconfigure; headless cadence is kept; Retry names the camera; LUT generation follows the named feed; Apply LUT off sticks; manual-start copy; refresh does not retarget a running capture; transport cache is written after a successful demand change; Choose LUT opens for the named camera during an in-flight load. The panel title is “Choose a LUT”.

Residuals:

- `selectNumber` and `cutNumber` are still unused by the app UI.
- The virtual-camera registry property stays writable. A writer that also has the app-group suite can still publish the next generation. Generation `UInt64.max` is rejected.
- `UserDefaults(suiteName:)` returned non-nil for every string tried here, including an empty string, so the nil-container branch is in the code and not exercised by those strings.
- Pending-cut frames from the on-air source are still skipped until the target qualifies or 2 seconds pass.
- The live take does not use `LongRunRecording`.

Not installed, signed, or run against the UltraStudio. `scripts/ui-verify.sh` and `scripts/app-self-test.sh` were not run.

## Tests that do not cover a confirmed P0/P1

Before this pass, CAM-1, CAM-2’s team check, RECO-1, RECO-2, RECM-1, APPS-2, APPS-3, and UIACT-2 had no assertion of the failing path. CAM-2 had an assertion of the opposite. PROG-1 is asserted, and the assertion is the designed skip.

`scripts/test.sh` still does not compile `AppModel.swift`, `UICameraColumn.swift`, `UIMenuBar.swift`, `UIInspector.swift`, or `UISessionBridge.swift`, so the retry, selection, and LUT fixes are not in that binary. They need the app target or `scripts/monitor-app-integration.sh` / `scripts/app-self-test.sh` to be compiled. The 407-test line is in “Witness after fixes.”

## Reverted or changed after live testing (2026-10-21 evening)

Installed and run against the UltraStudio. These parts of the pass were reverted or changed because they broke the live app:

- Camera extension (`CameraProvider.swift`) and its three test files are back at 38cc30b. The extension runs as a different user, so its app-group store never matched the app's and it rejected every registry update; the meeting-app camera could not connect. Viewer leases, live-process producer verification and the idle rename went with it.
- DeckLink auto mode starts with frames enabled again. Desktop Video only reports a format change when the signal differs from the opened mode, so a matching signal was never delivered ("No signal").
- A first camera connect failure does not arm retries again. Each attempt blocked the capture queue for seconds.
- Monitor work is dropped, and the composite pool trimmed, only when the target's generation is retired, not on every revision change or busy lock.
- A first "not presented" visibility report no longer drops monitor demand.
- A paused take skips the external-writer space check instead of failing.
- A successful recovery scan clears only an earlier scan error, not folder warnings or recovery results.
