# Natural talking-head auto-switcher plan

## Purpose and current status

This plan defines the Natural Talking Head director and its integration with
the Program output route. It is a profile of the multi-camera switcher, not a
replacement for capture, processing, frame ownership, virtual-camera
registration, or route demand management.

The repository currently contains a deterministic director and isolated
Program/timestamp contracts, but the live audio/transcript path, Program
integration, profile persistence, and UI are not complete. The feature must
not be described as implemented until the end-to-end gates in this document
pass. The multi-camera runtime remains a prerequisite; the existing one-feed
runtime must be extended before this profile can switch live sources.

The reusable implementation boundary is `Tools/auto-switcher`. It is a
standalone Rust library and CLI with a JSONL realtime protocol, offline media
analysis, bounded PCM cue extraction, versioned output schemas, and a delayed
Ollama advisory interface. The Swift host now consumes its cut instructions
through `AutoSwitcherBridge`, gates them through the Program route's
source-time boundary, and sends frame-boundary acknowledgements; the Rust
package does not directly own Core Media or Swift frame buffers. Transcript
injection and Ollama advisory display remain extension points for the next
integration pass.

## Scope

The first profile chooses between two existing processed camera feeds of one
seated talking-head subject. It consumes synchronized audio and transcript
cues and emits timestamped, acknowledged camera-cut requests. It does not
own media buffers, render video, run LUT/effects processing, or publish a
virtual camera.

The profile cuts only the Program route, which is always there with two cameras.
The director runs when the strategy is automatic, two or more cameras run, and
Program has a picture (a client or its monitor) or a take is active: with neither,
its cuts would reach nobody. Each feed's own virtual camera is unaffected. Its
audio and clock come from the anchor while it runs, otherwise the emphasis
camera, never the UI selection.

The first release assumes one editorial subject and two stable roles:

```text
Anchor:
  default angle, pauses, uncertain cues, long explanations, and fallback

Emphasis:
  tighter or more expressive angle for a strong editorial beat
```

The roles are persisted by stable `FeedID`; array order is never used as
identity. A later profile may support more than two roles.

## Prerequisites and runtime topology

The feature depends on:

- descriptor-driven multi-feed capture with stable `FeedID` values;
- route-aware demand and a resource governor;
- queue-owned `ProcessedFrame`/`FrameLease` fan-out;
- a Program route that maps source timestamps to one monotonic Program clock;
- a synchronized audio source and a transcript/ASR adapter;
- a serial or actor-confined switcher state owner.

The runtime flow is:

```text
audio samples ───────┐
                      ├─> Cue adapter ─> bounded cue store ─┐
transcript revisions ┘                                      │
                                                           v
processed feed frames ─> Program coordinator <─ director evaluation
                                  │
                                  ├─> timestamped cut request
                                  ├─> target pre-roll/demand
                                  └─> Program frame-boundary acknowledgement
```

The director is evaluated only while the Program route has an active
consumer. Stopping Program demand stops cue evaluation, cancels pending
requests, releases target pre-roll demand, and resets the session generation.
No polling loop is introduced when the route is idle.

## Clock and cue contract

All cue and frame times must be expressed in one session media timeline. The
adapter owns conversion from audio, transcript, and video clocks and reports
the conversion version and measured offset. A cue from an old session or old
clock generation is discarded.

```swift
struct CueClock {
    let sessionGeneration: UInt64
    let timescale: Int32
    let epoch: Int64
    let source: CueSource
}

enum CueSource: Codable, Equatable {
    case embeddedAudio
    case microphone
    case transcript(provider: String)
}

struct AudioCue {
    let id: UInt64
    let clock: CueClock
    let time: CMTime
    let duration: CMTime
    let speechEnergy: Float       // normalized 0...1 after noise-floor calibration
    let pauseDuration: TimeInterval
    let emphasis: Float           // normalized 0...1
    let laughter: Float           // normalized 0...1
    let isSpeechStart: Bool
    let isSpeechStop: Bool
}

struct TranscriptCue {
    let segmentID: String         // stable across revisions
    let revision: UInt32
    let clock: CueClock
    let timeRange: CMTimeRange
    let kind: CueKind
    let confidence: Float         // 0...1
    let isFinal: Bool
}
```

`CueKind` remains `phraseEnd`, `sentenceEnd`, `question`, or
`transition`. The upstream transcript adapter, rather than the director, is
responsible for word/phrase alignment and any semantic classification. Audio
energy must be calibrated against a noise floor; raw microphone level must
never be used as a portable threshold.

Transcript updates are keyed by `segmentID` and revision. A newer revision
replaces an older one, a final revision cannot be replaced by a non-final
revision, and a committed decision records the segment ID and session
generation. A changed range for an already committed segment cannot create a
second decision in that generation.

Cue storage is bounded. The adapter supplies a watermark; the director keeps
only the configured look-back window plus pending candidate data and prunes
committed tombstones after the session retention horizon. Evaluation must not
become O(session duration).

If the transcript provider is unavailable, the adapter reports that state and
the director uses audio-only boundaries. If audio is unavailable or stale,
the director enters the explicit audio-degraded fallback described below.

## Director contract

```swift
enum CameraHealth: Equatable {
    case healthy(lastFrameAt: CMTime)
    case unhealthy(reason: String)
    case unknown
}

struct NaturalTalkingHeadInput {
    let sessionGeneration: UInt64
    let mediaTime: CMTime
    let currentCameraID: FeedID
    let anchorCameraID: FeedID
    let emphasisCameraID: FeedID
    let currentShotStartedAt: CMTime
    let lastCommittedCutAt: CMTime?
    let cameraHealth: [FeedID: CameraHealth]
    let audioState: CueAvailability
    let audioCues: [AudioCue]
    let transcriptCues: [TranscriptCue]
}

enum CutReason: Codable, Equatable {
    case emphasisBoundary(label: String)
    case emphasisResolved
    case audioDegradedFallback
    case cameraHealthFallback
}

enum CueAvailability: Equatable {
    case live(lastCueAt: CMTime)
    case unavailable(reason: String)
    case stale(lastCueAt: CMTime)
}

struct CutDecision: Equatable {
    let decisionID: UUID
    let sessionGeneration: UInt64
    let targetCameraID: FeedID
    let cutTime: CMTime
    let expiresAt: CMTime
    let confidence: Float
    let reason: CutReason
}
```

The caller serializes evaluation and supplies the current output state. The
director returns either no decision or one `CutDecision`. `CutDecision` is
an idempotent request, not proof that output changed. The output coordinator
must return exactly one of:

```text
applied(decisionID, appliedAt)
rejected(decisionID, reason)
expired(decisionID)
cancelled(decisionID)
```

Acknowledgement is required before the director may emit another automatic
decision. A missing acknowledgement cannot permanently wedge the director:
the request expires at `expiresAt`, is cancelled, and the next evaluation
returns to a safe state.

`cutTime` is an earliest valid media boundary. The Program scheduler must not
apply the request to a target frame whose source/media timestamp is earlier
than `cutTime`. The scheduler flushes stale queued frames at the applied cut,
maps the target source clock to the next monotonic Program timestamp, and
reports the applied frame boundary back to the director.

## Persisted profile and settings

Add a versioned, `Codable`, validated profile. The profile is stored inside
the versioned switcher settings and migrated with the app-settings snapshot.

```swift
enum DirectorMode: String, Codable {
    case lowLatency
    case transcriptAssisted
}

enum SwitcherStrategy: String, Codable {
    case manual
    case fixedInterval
    case naturalTalkingHead
    case dynamicAnalysis // reserved; remains explicitly unavailable
}

struct NaturalTalkingHeadProfile: Codable, Equatable {
    var version = 1
    var enabled = false
    var anchorFeedID: FeedID?
    var emphasisFeedID: FeedID?
    var mode: DirectorMode = .transcriptAssisted
    var minimumShotDuration = 10.0
    var cooldown = 1.5
    var emphasisHold = 5.0
    var softMaximumShotDuration = 20.0
    var maximumShotDuration = 30.0
    var forcedCutGracePeriod = 2.0
    var forcedBoundaryLookback = 1.0
    var boundaryWindow = 0.24
    var candidateDwell = 0.30
    var transcriptConfidenceThreshold: Float = 0.72
    var pauseBoundaryDuration = 0.22
    var cutThreshold: Float = 0.68
    var hysteresisMargin: Float = 0.12
    var transcriptOutputDelay = 0.35
    var pacingBias: Float = 0       // -1 calm ... +1 active
    var manualHold = false
}
```

`DirectorMode.lowLatency` uses no deliberate output delay and only already
arrived, final transcript cues. `DirectorMode.transcriptAssisted` uses the
configured delay and a cue watermark to admit cleaner boundaries. The delay
is a real Program buffering policy, not just a scoring option.

Validation clamps finite ranges, rejects negative durations, requires distinct
role IDs, and falls back to anchor-only holding when the profile is invalid.
Runtime health must still be confirmed before either role is used. Existing v1 settings migrate with manual switching and Natural
Talking Head disabled. A profile or role change increments the session
generation, clears candidates, cancels pending decisions, and requires fresh
output state.

The UI exposes:

- Natural Talking Head enabled/disabled;
- anchor and emphasis feed;
- Low Latency / Transcript Assisted mode;
- minimum shot, cooldown, emphasis hold, soft maximum, hard maximum, forced
  cut grace period, forced-boundary lookback, and output delay;
- calm ↔ active pacing bias;
- transcript confidence threshold;
- manual hold and immediate camera override.

Manual hold suppresses automatic candidates. An immediate override clears the
candidate, cancels any pending automatic request, updates the current-shot
start time, and starts a fresh cooldown even when the selected camera is
already current.

## State machine and event priority

```text
HOLD_CURRENT
  -> CANDIDATE_CUT
  -> WAIT_FOR_SAFE_BOUNDARY
  -> REQUEST_PENDING
  -> HOLD_NEW_SHOT
  -> CANDIDATE_RETURN
  -> REQUEST_PENDING
  -> HOLD_ANCHOR

HOLD_CURRENT or HOLD_NEW_SHOT
  -> FORCED_CUT_PENDING
  -> REQUEST_PENDING
```

The director processes events in this order:

1. session/clock discontinuity, stop, profile change, or manual override;
2. current/target camera health and source readiness;
3. pending request acknowledgement, rejection, expiry, or cancellation;
4. minimum hold and cooldown gates;
5. cue ingestion, candidate scoring, and safe-boundary selection.

The state machine has explicit transitions for target loss, current-camera
loss, missing acknowledgements, feed removal, audio degradation, and the hard
shot deadline. `FORCED_CUT_PENDING` may bypass normal editorial scoring but
still waits for a safe gap or the absolute cap. A state label alone is never
treated as an output switch; any fallback switch is an actual acknowledged
Program decision.

## Editorial decision rules

A cut from Anchor to Emphasis requires:

```text
valid synchronized audio evidence
+ a phrase/sentence/question/transition boundary or calibrated pause
+ strong enough emphasis after normalization
+ minimum shot duration satisfied
+ cooldown expired
+ target healthy and ready
+ no manual hold
+ no pending request
+ candidate score above threshold and hysteresis margin
```

A return to Anchor requires:

```text
emphasis shot minimum hold satisfied
+ thought resolved by a sentence/transition boundary or calibrated pause
+ delivery energy settled
+ anchor healthy and ready
```

Audio level alone never triggers a normal cut. It changes confidence; the
boundary supplies the edit window. Question and transition cues are weighted
by the configured profile but do not bypass the boundary requirement.

The director rejects duplicate segment revisions, immediate A → B → A
reversals, stale cues, invalid clocks, and requests for an unhealthy or
unready target.

## Scoring and timing

Every score component is normalized to `0...1`; weights and thresholds are
profile data and are recorded in replay diagnostics.

```text
cutScore =
    boundaryConfidence * boundaryWeight
  + emphasisScore      * emphasisWeight
  + pauseScore          * pauseWeight
  + pacingNeed          * pacingWeight
  + targetFreshness     * freshnessWeight
  - rapidRecutPenalty
  - lowConfidencePenalty
  - insufficientHoldPenalty
```

The score must exceed `cutThreshold` and beat the current-shot score by
`hysteresisMargin` for `candidateDwell`. Candidate identity and dwell timing
are based on the cue event/watermark, not on how often the caller happens to
poll, so replay results are evaluation-cadence independent.

Normative starting defaults are:

```text
minimumShotDuration: 10.0 s
cooldown: 1.5 s
emphasisHold: 5.0 s
softMaximumShotDuration: 20.0 s
maximumShotDuration: 30.0 s
forcedCutGracePeriod: 2.0 s
forcedBoundaryLookback: 1.0 s
boundaryWindow: 240 ms
candidateDwell: 300 ms
transcriptOutputDelay: 350 ms
transcriptConfidenceThreshold: 0.72
pauseBoundaryDuration: 220 ms
cutThreshold: 0.68
hysteresisMargin: 0.12
```

The ten-second minimum is a safety floor for automatic camera jumps. When an
older saved profile contains a shorter value, app-settings migration raises it
to ten seconds before the director is started.

The soft maximum is advisory: it increases pacing pressure during normal
selection. `maximumShotDuration` is a hard editorial deadline measured from
the last applied cut, or from the first valid Program frame for the initial
shot. It prevents a healthy but quiet scene from remaining on one angle for
minutes.

When the deadline is reached, the director enters `FORCED_CUT_PENDING`. It
prefers the nearest speech gap, pause, speech stop, or already aligned
transcript boundary around the deadline. A boundary observed in the
`forcedBoundaryLookback` window may be applied immediately if it has not
already been passed by the output route; otherwise the director waits for the
nearest upcoming gap during `forcedCutGracePeriod`. Forced selection bypasses
the normal emphasis score and hysteresis requirements, but still requires a
healthy, ready target and a valid Program frame.

If no safe gap arrives by `deadline + forcedCutGracePeriod`, the coordinator
cuts at the first valid target frame after that absolute cap. This is the only
planned exception to the normal boundary requirement, and its reason is
`forced maximum shot duration`. The cap must be finite, greater than the
minimum shot duration and cooldown, and visible in diagnostics.

## Demand, pre-roll, and output application

The initial release keeps both role feeds running while Natural Talking Head
is active. The resource governor may refuse to enable the profile when two
active pipelines cannot be sustained; it must report that refusal rather than
silently dropping the target feed. A later optimization may replace this
with target-feed pre-roll, but that requires an explicit readiness lease,
warm-up deadline, and release transition.

A target that is not healthy and ready before a decision expires is cancelled
without changing Program output.

The output coordinator owns frame queues and applies a decision at the first
target frame at or after `cutTime`. It coalesces rapid requests by decision ID,
flushes stale frames at the applied boundary, and preserves monotonic Program
timestamps. The director never touches pixel buffers, frame ownership, LUTs,
or output routes.

Program audio is a separate policy. The first release may use a stable
microphone/selected source for cue analysis and keep Program audio monitoring
unchanged. It must not imply that virtual audio follows camera cuts until a
separate `ProgramAudioPolicy` is implemented and tested.

## Fallbacks and diagnostics

```text
Transcript unavailable -> audio-only cue mode; show degraded status
Audio stale/unavailable while on Anchor -> hold Anchor
Audio stale/unavailable while on Emphasis -> acknowledged fallback cut to Anchor
Target unhealthy/unready -> reject candidate and keep current
Current camera unhealthy -> emergency cut to healthy Anchor at next valid frame
Both cameras unhealthy -> hold last valid frame or emit configured black output
Clock discontinuity -> cancel pending work, increment generation, return Anchor
No target frame before expiry -> cancel request and report reason
No safe cue before soft maximum -> continue holding with pacing-pressure status
Hard maximum reached -> arm forced cut and show deadline/grace countdown
Forced grace exhausted -> cut at first valid frame and report forced reason
Program demand stops -> cancel work, release demand, reset generation
```

Diagnostics expose current camera, role health, cue freshness, clock offset,
mode, current state, pending decision ID and expiry, candidate score, target
readiness, applied/rejected/expired reason, and last fallback. Reasons use a
structured enum plus display text rather than an unparseable free-form string.

## Verification

### Durable replay timeline

Realtime and offline runs emit the v2 session timeline defined in
`Tools/auto-switcher/schemas/session-timeline.schema.json`. The ledger keeps
the ordered input events, director outputs, every proposed/applied/expired cut,
source and Program timestamps, recording artifact paths, and the media timebase
used for integer tick conversion. The app writes the same ledger beside the
recording output folder when Natural Talking Head starts, and updates it when
source recordings start or finish. A later editor can therefore resolve each
cut against the recorded source file without relying on wall-clock time. Source
movies use the stable feed ID plus UTC datetime in their names; timeline files
use UTC datetime names and add a numeric suffix on a collision.

Build deterministic replay fixtures containing audio cues, transcript revisions,
clock mappings, health changes, feed readiness, Program frames, and expected
decision/acknowledgement traces. Keep private audio and video local; fixtures
may contain synthetic cues or redacted metadata only.

Unit and integration tests must verify:

- no cut before `cutTime` or before minimum hold/cooldown;
- normal cuts respect the soft maximum while hard maximums force a cut within
  the configured grace period;
- forced cuts prefer the nearest speech gap and use the absolute-cap fallback
  only when no gap arrives;
- candidate dwell is independent of evaluation cadence;
- low-latency and transcript-assisted delay behavior;
- revised and reordered transcript cues do not duplicate committed cuts;
- stable session-generation and clock-discontinuity reset behavior;
- audio-only operation and audio-degraded fallback from Emphasis;
- unhealthy/unknown/current/target camera behavior;
- target pre-roll, missing target frames, expiry, cancellation, and coalescing;
- exact acknowledgement, rejection, timeout, and stale-decision handling;
- manual hold and immediate override semantics;
- monotonic Program timestamps and stale-frame flushing across cuts;
- no automatic work while Program demand is inactive;
- bounded cue memory and evaluation cost over a multi-hour replay;
- persisted profile migration, validation, role repair, and settings changes;
- UI diagnostics for every degraded and fallback state;
- end-to-end runtime invocation from cue adapter through Program output.

The feature is ready only when these replay/integration checks pass together
with the existing multi-camera, frame-ownership, demand, registry, and build
verification gates.

## Implementation sequence

1. Add `NaturalTalkingHeadProfile`, strategy selection, role persistence,
   validation, migration, and UI bindings.
2. Implement audio/transcript adapters, clock conversion, cue IDs/revisions,
   freshness reporting, and bounded cue storage.
3. Extend the Program cut request with decision ID, earliest cut time,
   expiry, cancellation, and acknowledgement.
4. Implement target pre-roll/readiness and current-camera health fallback.
5. Connect the director to the live Program-demand lifecycle and remove the
   cue-dropping evaluator path.
6. Add structured diagnostics and local replay tooling.
7. Add deterministic, property-based, and end-to-end tests listed above.
8. Qualify two-feed hardware behavior, demand transitions, output timing, and
   sustained resource usage before enabling the profile by default.
