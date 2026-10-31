# Validation A: defects and fixes

Reviewer role: skeptical capture and recording engineer. Tree: `2c4929c`, read on 2026-10-30. Read-only. Nothing built, run or recovered. Evidence is source, the two 12:24 journals and sidecars, `ffprobe` of the `.partial` files, and the unified log.

Labels: **V** verified in code or on a real file. **I** inferred. **U** unknown.

## 1. What changed

The audit's diagnosis holds. Its journal fix does not, as written. Three defects of equal severity were missed.

| Item | Verdict | One line |
|---|---|---|
| Journal cause and numbers | KEEP | Reproduced exactly |
| Journal fix | **REVISE** | "As lines 702-709 do" is false, and a +1 run rule breaks on 100% of real frames |
| "Stop journaling past the cap" | **REVISE** | Right idea. Needs a reserve, a sidecar record, a new message and one rewritten test |
| "Never finalized" | **REVISE** | Stale. Both were finalized at 18:59:13 and are complete movies |
| "On the writer queue" | **REVISE** | It is the recorder queue, holding the capture buffer |
| Timecode=Source workaround | **REVISE** | Safe here only with conditions |
| B1 | REVISE | Store beside `allowCPUConversion`, not in the snapshot |
| B2 | REVISE | `stopped: true` is also sent on every normal stop |
| B3 | REVISE | Needs an entitlement, and screen sharing hides notifications by default |
| B4 and section 4 | **REVISE** | Feeding health is not enough. Four more parts are needed |
| B5 | **REVISE** | The stated fix alone turns tally off for good in Separate |
| B6 | KEEP with conditions | Does not risk the every-frame rule if preview stays in the formula |
| B7 | REVISE | Real, lower severity. `send` is not in scope there |
| B8, B10, B11, B12, B13, B15 | KEEP | Verified |
| B9 | REVISE | Do not touch the estimator table |
| B14 | REVISE | Also change the default mode |
| **N1, new** | **Add to phase 0** | A failed take keeps showing a red REC and a running clock. Today it did for 6 h 16 m |
| **N2, new** | **Add to phase 0** | A 2-frame dropout during a take very likely ends it. This is the next take-killer |
| **N3, new** | **Add to phase 1** | HDMI loss is invisible after the first frame: the UI reads `.live` |

## 2. The journal failure

### Claims checked

| Claim | Result |
|---|---|
| Journal 16,777,011 bytes, 68,245 entries, one per frame | V. 245.84 bytes each. All `nativeTimecode`, all from `AVAssetSourceRecordingWriter.swift:726` (each has `nativeTimecodeMetadata`, none has `nativeSourceTimecode`) |
| 18.98 minutes at 59.94 | V. 68,245 × 1001/60000 = 1,138.55 s. Also 37.95 min at 29.97, 45.5 at 25, 47.4 at 23.976, 22.75 at 50p |
| Cause at `:723-727`, `journalFull` at `RecordingTakeSidecar.swift:225`, take fails at `SourceRecording.swift:1119-1135` | V. Sidecar `finalError` states it |
| Both takes failed on the same frame | V. Identical size and count on both cameras. One cap ended every ISO at once |
| "Never finalized" | **Stale.** V. Log 18:59:13.455: `take failed ... frames=68245`. Sidecars now read `finished: true`. `ffprobe -f mov`: 1,138.554 s, 68,245 video frames, 8-channel lpcm, 68,245 tmcd samples, on both. The audit's 1,131 s was read before finish |
| "On the writer queue" | **Wrong queue.** V. Line 726 runs on the recorder queue (`SourceRecording.swift:1106`, class note at writer `:12-17`). It sits between GPU repack and VideoToolbox submit, with the capture buffer still retained by `sample`. A slow sync holds a driver frame, and queue capacity is 12 frames (`SourceRecording.swift:269`) |
| Per-frame `fsync` and atomic sidecar rewrite | V at `RecordingTakeSidecar.swift:229-231`. It caused no loss in this take: `lateFrames=0`, `sourceDrops=0` |
| `:739` is the same hazard | V, but **not reachable here**. It needs `declaredRate.isVariable` (`:609`). DeckLink always declares `.constant(duration)` (`DeckLinkCapturePlugin.swift:187`), and no shipped plugin declares variable (V, by search) |

### Why labels were journaled per frame

- **V.** No commit message explains it (`dcb58e1` is "save").
- **V.** The intent is in `RecordingModel.swift:57`: labels are "retained in the sidecar when no movie timecode track exists". Mac Clock and Record Start generate their own track, so the camera's labels have no other home, and `:723` sets `sourceNativeTrackExpected` false for those modes.
- **V.** This contradicts the class note at `RecordingTakeSidecar.swift:90-91`: "exceptional timing and mapping records".

### What depends on the data

**Nothing reads the journal.** V: no reader exists in `Sources`, `scripts` or `Tools`.

- Recovery is an AVAsset passthrough export (`RecordingRecovery.swift:180-192`). It only copies the journal file (`RecordingTakeSidecar.swift:276-289`), and that copy requires the file to exist.
- The movie's tmcd track is written from attachments, not from the journal.
- So a thinner journal costs the app nothing. It costs only forensic detail, and a lossless rule costs none.

Tests:

| Test | Effect of the fix |
|---|---|
| `RecordingB3TimecodeChecks:480` (2 labels, late CFR and VFR) | Stays green if a change of rate, epoch or drop flag counts as a break, and if VFR stays per frame |
| `RecordingB3TimecodeChecks:329` (`cadenceSourceTiming`) | Stays green. First frame always records |
| `RecordingB3TimecodeChecks:711` | Unaffected. No native labels there |
| `CaptureNativeTimecodeChecks` | Unaffected. Uses a fake writer and tests attachments only |
| `RecordingPolicyChecks:17-19` | Stays green if `append` keeps throwing and only the writer's call sites change |
| `RecordingTakeLifecycleChecks:152-178` | **Must be rewritten.** It pins "journal of 1 byte fails the take, 0 submissions" |

### Why the stated fix fails

`Journal a label only when it breaks the run, as lines 702-709 already do.`

1. **Lines 702-709 have no run logic.** V. They journal when the rate is variable, the duration has no matching rate, or the field mark changed. There is nothing to copy. `fieldMark` is also always nil from DeckLink (`DeckLinkCapturePlugin.swift:314`), so that branch is dead. If someone plumbs the flag, `:707` becomes per-frame in every mode, Source included.
2. **The obvious rules do not work on this rig.** V, measured on both journals. The FX3 sends a pair counter with no field mark: labels go 00, 00, 02, 02. `frameNumber` steps are 0 or +2, plus +6 at each drop-frame minute.

| Rule | Entries of 68,245 | Failure at 59.94 |
|---|---|---|
| Today | 68,245 | 19 min |
| Next label = previous + 1 | 68,245 | 19 min. **No change at all** |
| Journal when the label changes | 34,122 | 38 min. Still fails |
| Rule below | **36** | Not reached in practice |

The rule below was replayed on both real journals: 36 records each, and the decoder rebuilt all 68,245 `frameNumber` values exactly.

### REVISE: the fix

Replace the first sentence of the README's **Fix** paragraph with:

> Journal a native label only when it cannot be predicted: the first two frames, any gap or pause (`pts` differs from the previous frame's end), any change of rate, epoch or drop-frame flag, or any frame whose `frameNumber - frameNumber[two frames back]` differs from the current stride. The stride starts at 2, which fits both 1:1 and paired counters. A held label is stride 0. A break sets the stride to the new value. VFR labels stay per frame. Line 739 journals only when duration or contiguity changes.

```swift
/// Recorder queue. Decides which native labels the journal must keep.
private struct NativeLabelRun {
  private var last: (frame: Int64, end: CMTime)?
  private var older: Int64?
  private var identity: (RecordingFrameRate, CMTimeEpoch, Bool)?
  private var stride: Int64 = 2
  mutating func breaks(_ v: TimecodeMetadata, pts: CMTime, duration: CMTime) -> Bool {
    let contiguous = last.map { CMTimeCompare($0.end, pts) == 0 } ?? false
    let same = identity.map { $0.0 == v.frameRate && $0.1 == v.epoch && $0.2 == v.dropFrame } ?? false
    var broke = !contiguous || !same || older == nil
    if !broke, let older, v.frameNumber - older != stride { stride = v.frameNumber - older; broke = true }
    older = contiguous ? last?.frame : nil
    last = (v.frameNumber, CMTimeAdd(pts, duration))
    identity = (v.frameRate, v.epoch, v.dropFrame)
    return broke
  }
}
```

At `:724`: keep the condition, and for constant rate add `&& nativeRun.breaks(value, pts: pts, duration: duration)`. Decode `value` once, not at both `:716` and `:725`. Midnight wrap is one more break and needs no special case.

Rejected, with reasons:

- **New run-length event format.** Not needed. The next record's `originalValue` gives the run length, and the schema stays readable by old sidecars.
- **Rotating files.** `copyPairedMetadata` and `removePairedMetadata` assume one journal, and nothing needs the extra data.
- **Batched `fsync`.** Worth it only for VFR, which no plugin produces. At about 1 record every 33 s the existing path is fine. Revisit with a VFR source.

### REVISE: "past the cap, stop journaling and note it"

**Acceptable**, because nothing reads the journal, but not as a one-liner. `RecordingTakeSidecar.swift:188` promises "metadata was not discarded", and the conversion note at `AVAssetSourceRecordingWriter.swift:467` promises timing is "retained in the journal". Both become untrue.

Replace the README's last Fix sentence with:

> Metadata must never end a take. The writer calls a non-throwing `journal(_:)`. Label, quantization and cadence records stop at 15 MiB. Clock mapping, provenance, pause and audio records may use the last 1 MiB. Past that, count and drop. The first suppressed record sets `Snapshot.journalTruncation` (first `originalValue` and timescale, plus a count per kind, decoded with `decodeIfPresent`). The sidecar and the take's note both say so. A journal write error is counted the same way. Creating the sidecar at take start stays fatal.

- New text for `:188`: `"The recording metadata journal reached its limit. Recording continued; timing records after that point were not kept."`
- Conditional note at `:467`: "retained in the journal" must gain "up to the point in `journalTruncation`" when truncated.
- Rewrite `RecordingTakeLifecycleChecks:152-178`: a 1-byte journal now gives a finished take, one submission, and a non-empty `journalTruncation`.
- Add `journal.suppressed` to the counter dictionary at `:1384`.
- **Also non-fatal: `:2046-2047`.** See the workaround below.

Other take-ending metadata throws, for the same review: `:703`, `:715` (label over 4,096 bytes), `:2056`, and `SourceRecording.swift:834-838`. All are unreachable on this rig today (I).

### Other appends

| Line | Rate | Verdict |
|---|---|---|
| `:432` | Per mapping revision | Bounded. DeckLink sends revision 0 always (`DeckLinkCapturePlugin.swift:176`), and the real journals hold none (V) |
| `:496` | Per clock event | Same |
| `:586` | Per epoch change | Bounded by `lastOriginalSourceEpoch`. Test at `RecordingB3TimecodeChecks:419` covers the audio twin |
| `:637` | **Per frame, VFR only** | `original` non-nil only when quantized (`RecordingTimebase.swift:135`). Real take: `quantizedSamples: 0` (V) |
| `:683` | Per resume, only when nonzero | Bounded by the operator |
| `:707` | Per frame only for VFR or an unmatched rate | Not firing here (V). Route through `journal(_:)` |
| `:726` | **Per frame, the failure** | Fixed above |
| `:739` | **Per frame, VFR with CFR on** | Not reachable here |
| `:1509` | Per epoch | Bounded |
| `:1545` | Once, then the take fails | Bounded |

**Pause:** does not fill it. V. Paused frames stop at `SourceRecording.swift:1000-1002`, before the writer. A resume costs two records.

**VFR:** still heavy. Three records per frame at 245 to about 450 bytes hits the budget in about 6 to 8 minutes at 60 fps (I). The take now survives that, with its timing record truncated and stated.

### Longest safe take after the fix

At 59.94 on this rig, 36 records per 19 minutes is 107.5 per hour, or 26.4 KB/h.

| Case | Journal budget (15 MiB) lasts | Take ends? |
|---|---|---|
| Today's labels | 595 h, about 25 days | No |
| Plus a bad day: 32 gaps per 89 min, 2 records each | 425 h, about 18 days | No |
| Worst case: every label unpredictable | 18 min | **No.** Labels truncate and the take continues |

So the journal stops being a limit at any rate and in any mode. Real limits:

- **Disk, measured.** This take wrote 64.3 Mb/s, or 28.9 GB/h. 3,267 GiB free on Cam B gives 121 h for one camera, 60 h for two. ProRes HQ at about 1.63 Gb/s gives 4.8 h and 2.4 h.
- **Signal.** A loss over 10 s ends the take by design (`DeckLinkBackend.h:9`, `CaptureController.swift:1398-1426`). See N2.
- **Unknown.** No take has finished past 89 minutes. Container behavior over several hours is untested (U). Before trusting a long session, run one take of 3 hours or more.

### REVISE: the workaround

Timecode=Source does avoid `:726` here. V: `sourceNativeTrackExpected` is true when the first frame has a label and the rate is constant (`:723`), and frame 1 had one today. Line 707 does not fire on this rig. But replace the README bullet with:

> **Workaround until fixed.** Set Timecode to Source before every take, and again after every launch. This relies on the first frame carrying a label. If it does not, every later labelled frame journals and the take fails as before, with no timecode track. A flipped drop-frame bit also ends a Source take (`AVAssetSourceRecordingWriter.swift:2046-2047`). A simpler guard is to turn off HDMI timecode output on both cameras, as labels then never reach the journal in any mode (`:724`); not tested. Neither protects against N2. During a take, watch the status bar: the strip will not show a failure (N1).

Also keep this in mind about Source tracks. V: both cameras skip labels at each non-tenth minute while `dropFrame` is false, so the source is drop-frame but unflagged. Each tmcd sample still carries the true label, so a per-frame reader is correct. A reader that counts from the first sample drifts 4 labels a minute (I).

### Does a failed take finalize, and why `.partial`?

- **It does not finalize by itself.** V. Nothing reacts to `statistics.failed` (`RecordingModel.swift:970-986`). The writer stays open, with state `.failed`, until someone presses Stop. `.partial` had no final index for 6 h 16 m.
- **Stop then closes it cleanly.** V: `finish` runs (`:2063-2092`), and for a recorder-raised failure `finishWriting` succeeds.
- **It stays hidden anyway.** V: `RecordingModel.swift:553` sends every `.failed` state to `preserveForRecovery`, even when `stopError == nil` and the movie is whole. So a complete 19-minute movie sits as a dot-file that Finder does not show, and a passthrough export is needed to get it back.

**REVISE. Add to the fix:**

```swift
// RecordingModel.refreshStatistics, after storing the snapshot:
if snapshot.failed, feeds[index].status == .recording || feeds[index].status == .paused { stop(feedID: id) }

// finalize(): the writer closed cleanly means the movie is whole, whatever ended the take.
if stopError != nil { session.output.preserveForRecovery() }
else if hadVideo { _ = try session.output.finish() }
else { try session.output.cancel() }
```

Then keep the throw at `:565`, so the failure stays reported, and at `:949` also set `savedURL` when the file exists. The strip's Show in Finder already uses it (`UICameraColumn.swift:968`). `testMoviePublicationRequiresFinishedOwnedMetadata` still holds, as `finish` requires the sidecar to be finished. About 16 strings say "kept for recovery" and need a pass. A writer-level failure still goes to recovery. Add a log line at the moment of failure in `failLocked` and at `SourceRecording.swift:1132-1135`: today the only line comes at Stop, which is why the audit found none for 12:43.

Auto-rollover into a new take after a failure is a separate owner decision. It is not included.

### The two takes

Keep the README's advice. Recovery is still right, because `.ultracam-recovery` exists and the `.mov` does not. Update the wording: they are complete, 18:58 each. `droppedVideo=2` is not the real loss. The route closed itself at `CaptureController.swift:1755-1757` after the first refused audio packet, so the 6 hours after 12:43 are uncounted (V).

## 3. New defects of equal severity

### N1. A failed take still reads as recording

**V, from code and the real incident. Blocks.**

- `stripState` returns `.failed` only under `.idle` (`UIPresentation.swift:550-554`). A failed take has `status == .recording`, so it returns `.recording`.
- The strip says "Recording" in red, the REC pill and clock keep running (`:595`, `UICameraColumn.swift:266`), and the toolbar and status bar keep "REC 2" (`:714`, `:751`). The session clock runs on (`RecordingSessionClock`): the take meter logged 23,711 s, which is 12:24:02 to 18:59:13.
- **What does show:** an orange status-bar segment and a menu bar triangle (`:821`, `:916`), and Diagnostics. Only the first failed camera is named.
- The strip showed "2 dropped".
- Today's real effect: **two ISO cameras recorded nothing for 6 h 16 m under a live REC.** Whether anyone was relying on them is unknown (U).

The README's B-table and report 02 miss this. 02 lists "Drive disconnected or full: Recording failed... Good", which is true only after Stop.

**Fix.** The auto-stop above, plus `if recording.failed { return .failed }` first in `.recording` and `.paused`. Add `UIPresentationChecks` cases for `status: .recording, failed: true`. Phase 0.

### N2. A dropout during a take very likely ends it

**Path V. Runtime precondition I. Blocks once the journal is fixed.**

1. In a no-input callback, `deliverVideo` returns before the frame handler (`DeckLinkBackend.mm:984-988`). `beginGroup` has cleared `pairedFrame`.
2. The audio is still reported. The comments at `:958-963` and `:981-983` say this is deliberate, and that Desktop Video delivers packets while video is absent.
3. `receiveAudio` sends `pairedFrameSequence: nil`, so `pair` is nil (`CaptureController.swift:1691-1693`).
4. `clock` is `.pairedWithFrames` (sidecar, V). `deliverRecordingAudio` then calls `rejectRecordingMetadata` with a message (`:1724-1727`), which reaches `failTakeMetadata` and fails the take.

- Added in `dcb58e1`. V.
- **No take on this code has met a dropout.** The only two takes since, on these drives, have `gaps=0`, and the first dropout of that run came at 12:51, after they failed. V. The 89-minute take with 32 gaps predates it.
- Today each camera had 5 dropouts in 399 minutes, one per 80 minutes. A 1-hour take would survive on one camera about 47% of the time, and on both about 22% (I). On a day like 10-28 it would last minutes.

**Fix.** Replace the reject with continued placement. Keep the last valid pair `(videoTime, packetTime)`, and for an unpaired packet pass `videoTime = last.videoTime + (packetTime - last.packetTime)`. Do not drop the packet instead: the LPCM track is written back to back whatever its timestamps (`SourceRecordingAdapter.swift:420-423`), so a dropped packet would slip sync for the rest of the take. The older re-anchor and silence-fill code sits on the test-only path (05 at line 67, V).

Add a test with `FakeCaptureSession`: frame, audio with nil pair, frame, in one take. It needs no hardware. Phase 0.

Related, V: DeckLink never passes no-signal frames to the recorder, so `invalidVideoSinceLastFrame` is never set on this route, and the comment at `SourceRecording.swift:1147` does not describe it. An outage of 10 s or more ends the take at `:1174` or on the new epoch. That is acceptable, but the alert text must say so: "Recording · no signal" lasts at most 10 s.

### N3. HDMI loss is invisible after the first frame

**V from code, not run. Blocks live monitoring.**

- `UIFormatLabels.signal` returns `.live` whenever `update.sourceFormat` is set (`UISessionBridge.swift:72`), before any string test.
- `sourceFormat` is `declaredAdmission?.format` (`CaptureController.swift:2422`). `clearSignal` does not touch it (`:1131-1140`). The `.signalLost` handler does not either (`:1629-1630`), and neither does the watchdog (`:725-737`). Only a new epoch clears it (`:1398-1418`), and a loss under 10 s makes none.
- So after the first frame, `.noSignal` is unreachable on a running camera. These never fire live: "No signal" placeholder, "REC · no signal", `programWarning`'s "on air: no signal", and `warning()`'s no-signal lines.
- Added in `dcb58e1`. `FormatDisplayIdentityChecks:62-68` pins the behavior, with a stale label overridden by format.
- All renders use fixtures, which set `.noSignal` directly. So report 02's "Good" for that row, and README section 4's "Signal lost placeholder", describe a state the app does not reach. The owner's check 3 in section 12 will show this at once.

**Fix.** See B4.

## 4. Defects B1 to B15

### B1. REVISE

Verified: `RecordingModel.swift:633,659`, written only at `UISettings.swift:135-136`.

**Replacement:** two keys beside `allowCPUConversion`, which is the existing pattern for a global recording setting (`AppSettingsStore.swift:558,583-585`, `AppModel.swift:41-45,367`).

- `ultracam.recordingCodec` and `ultracam.recordingTimecodeMode`, stored as raw strings.
- **Migration:** none. A missing or unknown value uses today's defaults, HQ and Mac Clock. An unknown value must never throw. No version bump.
- Add both to `resetAll` (`:575`), or Reset leaves them behind.
- Load before `recordingModel` can start a take, at `AppModel.swift:367`. Save from `didSet`, as the policy does.

Why not 05's `AppSettingsSnapshot`: it is built by `feedCoordinator.snapshot` (`FeedRuntime.swift:577`), which does not own recording, and each save republishes the camera registry. A snapshot version bump would also fail `validated()` on downgrade (`:499`). Do not guess the default from old sidecars.

### B2. REVISE

The defect is verified: `AppModel.swift:1150-1160`, `UISessionBridge.swift:113`, `UIPresentation.swift:555`. In release builds, plain no-signal waits (`followsSourceTiming`), so this covers real errors only.

**A user stop cannot be told from a failure today.** V: `performStop` also publishes `stopped: true` (`CaptureController.swift:836`), and the `update.stopped` branch runs for both. Do not compare `message` with "Stopped".

**Replacement:**

```swift
enum CaptureStopCause: Sendable, Equatable { case requested, failed(String) }  // on CaptureUpdate
// performStop sets .requested. fail() sets .failed(value). failFromSource already goes through fail().

struct UnexpectedStop: Equatable, Sendable {
  let reason: String
  let at: Date
  var take: UnexpectedTakeResult?
}
enum UnexpectedTakeResult: Equatable, Sendable {
  case none
  case saved(URL, duration: TimeInterval, lostFrames: UInt64)
  case interrupted(URL)
}
// AppModel: var unexpectedStops: [FeedID: UnexpectedStop]
```

- **Created** in `cameraDidUpdate` on `.failed`, and also for N1 when a take ends early with the camera still running. `take` is filled in by `onRecordingFinished`.
- **Lifetime.** In memory until acknowledged. A successful restart clears the camera half, but a take result stays until acknowledged. Removing the camera clears it. Not persisted: after a relaunch, Interrupted Takes carries the loss.
- **Same fix for `.saved`:** move `if !camera.running` below the Saved check at `:555`.
- The related `showStatus` finding (`AppModel.swift:1000-1004`) is verified. Keep it in this item.

### B3. REVISE

Verified: no `UNUserNotification`, `NSSound`, `requestUserAttention` or global hotkey anywhere in `Sources`, `Packages` or `Vendors`.

Add to section 4:

- Time-sensitive delivery needs `com.apple.developer.usernotifications.time-sensitive`, absent from `Config/App.entitlements` (V). Whether the current signing supports it is U.
- macOS holds banners during screen sharing unless "Allow notifications when mirroring or sharing the display" is on, and it is off by default (I, from platform knowledge). A shared screen is the normal state of a meeting. Change section 12 check 4 to "during a full-screen meeting **while sharing the screen**".
- Add `NSApp.requestUserAttention(.criticalRequest)` as a second channel.

### B4 and section 4. REVISE

The defect is verified, and worse than stated (N3). Health goes false only at `AppModel.swift:1185,1284` and `FeedRuntime.swift:404-407`.

**How no-signal is known, with no string parsing.** The facts already exist as types: `.signalLost` (`CaptureDelivery.swift:66`), `signalLostAt` (`CaptureController.swift:206`), and `lastReceived`. Only the plugin's boundary parses text (`DeckLinkCapturePlugin.swift:305`). Add to `CaptureUpdate`:

```swift
enum CaptureSignal: Sendable, Equatable { case waiting, live, lost(since: TimeInterval), unsupported(String) }
```

- Set `lost` from `signalLostAt`, and also in the watchdog path at `:725-737` (frames stopped entirely), which does not call `noteSignalLost` today.
- `UIFormatLabels.signal` reads this first. `sourceFormat` only supplies the label. Update `FormatDisplayIdentityChecks:62`.
- Publish on the transition. Invalid frames never reach `publishIfDue` (`:2028`), so nothing publishes during a loss.

**Is a hold of about 1 second right?** Yes. V, from today's log: all 10 dropouts lasted 23 to 33 ms, so 1 s is 30 times the longest. It is also inside Program's 2 s repeat window (`ProgramOutputRoute.swift:225`), so Zoom sees a held frame and no stall. Two conditions:

- Time it with a timer. No frames and no updates arrive during a loss, so nothing will fire on its own. AppModel starts one on `lost`.
- Add a **return hold of 3 s** of continuous signal before the camera is eligible again, or a flapping cable makes Auto cut back into it.

**What Auto does on loss, today and needed:**

| Case | Today | Needed |
|---|---|---|
| Natural talking head | `health_fallback` exists (`director.rs:518`), never triggered | Fails anyway: see below |
| Fixed interval | Skips unhealthy targets only at the next interval (`SwitcherCoordinator.swift:321`) | Cut at hold expiry |
| Director tick | Runs on the **selected** camera's updates (`AppModel.swift:1171`) | If that camera is the lost one, ticks stop and the fallback never runs (V). Do not depend on it |
| Hold on | `manual_hold` returns before the fallback (`director.rs:291-296`) | Decide, below |
| 3+ cameras | Rust tracks only anchor and emphasis (`:251-255`); fallback returns None for others (`:527`) | Use the app rule below |
| Signal returns | Bridge is only ever told `healthy: false` (`AppModel.swift:1288`). Rust keeps it (V) | Send `healthy: true` after the return hold |
| Every camera lost | `nextHealthyFeed` nil | Stay on the current camera. Say "No camera has a picture". No cut |

**Replacement for the README bullet:**

> **On-air loss.** AppModel owns one failover rule for every strategy. When a camera has been lost for 1 s, mark it unhealthy. If it is on Program and Auto is on, cut to the next live camera in strip order and tell the director with `manualOverride`. If no camera is live, stay and warn. With Auto off, cut nothing, and show Cut at the warning. A camera becomes eligible again after 3 s of continuous signal, with `healthy: true` sent to both Program and the director. Nothing cuts back on its own, except the director's ordinary rules. **Hold:** loss overrides it once, because Hold protects a shot and this shot has no picture. Hold stays on for the new shot, and the operator is notified.

The Hold rule is my choice, and it is the one item here the owner may reverse. Do not skip the alert either way. Marking a lost camera unhealthy also refuses manual cuts to it (`SwitcherCoordinator.swift:276`), which is right, but the `cutEnabled` state must explain why.

**Placeholder:** keep "says how long". It needs N3 first.

### B5. REVISE

The defect is verified at `UISessionBridge.swift:128`. `cameraConnected` is the sink, not a client. But the stated fix is unsafe alone.

**V:** `routeDemand`, which is the real client signal, is filled only by `demandMonitor`, and that runs only in Program or with an automatic camera (`AppModel.swift:502,1010`). In plain Separate it never starts, so `cameraInUse` is always false. "`inUse` means a real client only" would turn tally off permanently.

**Replacement:** "`inUse` = `model.cameraInUse(id)`, and start `demandMonitor` unconditionally at launch and in `installAutomaticFeedMonitor`." The demand property is the extension's own signal on the source stream, so the sink does not trigger it (`CameraDemandMonitor.swift:155,177`). Treat `requested == nil` as "unknown", not "not in use". Phase 2 needs this anyway, so it costs nothing extra.

### B6. KEEP, with conditions

Verified: `onProcessedFrame` is always installed (`AppModel.swift:1133`, `FeedRuntime.swift:254-262`), so `processedHandler != nil` always holds and the branch at `CaptureController.swift:2140` never runs.

**Every-frame rule: no risk to recording.** V: `receive` hands frames to the recorder on the driver thread (`:2016-2027`), before the queue hop and before this gate. Monitors keep the source frame (`:2141`). A consumer that does not exist cannot miss frames. Conditions:

1. **The formula omits preview.** The rule names preview as a consumer, and the branch tests `hasPreview`. Replace with `GPU processing = sink open || programActive || preview visible`.
2. `:2146` sets `applied = nil`, so `pipelineEnabledApplied` is nil and `UISessionBridge.swift:126` reports `applying`. Every idle camera would show `.updating` forever (V). Fix this in the same change.
3. `programActive` must rise before the first Program frame is due, for **all** cameras, or a first cut waits on `ensurePrepared` (`wait: false`, `:2157`). That is the 01 top risk, and it stands.

### B7. REVISE

Verified: `UISettings.swift:418-423` omits the line at `UISessionBridge.swift:366`.

Two corrections:

- Lower severity. With strategy Manual and `automatic` true, nothing auto-cuts (`SwitcherCoordinator.swift:311`, `UIPresentation.swift:725`). The harm is that picking a strategy later re-enables Auto silently.
- That view holds `model`, not `context`, so "route through `send`" does not fit. Replace with one `AppModel.setStrategy(_:)` that both call.

### B8. KEEP

Verified at `SourceRecording.swift:337`. Fix both interpolations: `\(matrixProfile.displayName)` and `\(error)`.

### B9. REVISE

Verified: 0.15 bytes per pixel is 597 Mb/s at UHD 59.94, and the real take is about 53 Mb/s of video.

**Do not edit `RecordingSizeEstimator.swift:18`.** It also drives the free-space floor (`SourceRecording.swift:726,1284`), and `RecordingSizeEstimatorChecks` pins the HEVC ratio. A low figure there admits takes the drive cannot hold if an encoder runs high.

**Replacement:** "Keep the estimator as the cautious admission figure. Add a display-only rate: rolling measured, then last measured for that codec, size and rate, then a corrected nominal. Add audio." That matches 05's list, whose wording "HEVC corrected" must be read as display only.

Correction to 05: 8 channels of 24-bit 48 kHz is 11.52 Mb/s, not 9.2. The extra cost over stereo is 3.9 GB/h, not 3.

### B10. KEEP

Verified at `UISupport.swift:63-65`. Note: `videoMegabitsPerSecond` is 0 for a take's first sample, so the sum briefly falls back. Handle this in the same change.

### B11. KEEP

Verified at `UIInspector.swift:340`.

### B12. KEEP

Verified at `UIPresentation.swift:679`. The Takes list must read `recording.sourceVideoLost` and `recording.sourceSkippedFrames` from sidecars, and show nothing for older takes without them. Count N1 and N2 correctly first. A failed take's "2" understates its loss.

### B13. KEEP

Verified at `UIPresentation.swift:818-847`. `menuBarIcon` depends on it (`:916`).

### B14. REVISE

Verified: `ingestTranscript` has no caller, and the default is at `AppSettingsStore.swift:46`. Hiding the picker leaves the mode on.

In Rust, `transcriptAssisted` also widens a window by `transcript_output_delay` (`director.rs:698-699`). It is not a pure no-op.

**Replacement:** "Hide the picker, and have `normalizeForRuntime` force `.lowLatency` until a transcript source exists." Keep the saved value, so nothing is lost. The picker's own help text states the audio-only fallback, so the severity is low.

### B15. KEEP

Verified at `UICameraColumn.swift:99`. `Config/Assets.xcassets` has no `AccentColor`, so it follows the system accent.

## 5. Corrected phase 0

Replace the phase 0 row in README section 11 with:

| Phase | Work | Size |
|---|---|---|
| **0. Stop losing material** | Journal fix with `NativeLabelRun` and budget, N2 unpaired audio, N1 auto-stop and strip state, publish whole movies, failure log line, B1, B7, B8, B11, B15 | 1 day |

Order within phase 0: N2 and the journal together, then N1. **Shipping the journal fix alone moves the failure from minute 19 to the first dropout**, with the same false REC on screen.

Move N3 and the typed signal state to the top of phase 1. Section 4's failover cannot work without it.

Before calling phase 0 done, run one live take of 3 hours or more that crosses a real or forced dropout.

## 6. Open

- **U:** whether Desktop Video delivers an audio packet on a no-input callback on this hardware. The code comments say it does. A log line in `reportRawAudio` would settle it, but the fix is right either way.
- **U:** whether anyone was rolling on purpose between 12:43 and 18:59.
- **U:** container and writer behavior past 89 minutes.
- **U:** time-sensitive entitlement with the current signing.
- **Owner decision:** loss overrides Hold (B4). Auto-rollover after a failed take (section 2).
