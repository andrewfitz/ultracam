# Multi-camera and Program switcher plan

## Goal

Extend Ultracam from one Blackmagic input and one virtual camera to a reusable multi-feed system. Each feed can have its own LUT, effects, preview, audio/video telemetry, and saved settings. Every feed is published as its own virtual camera, and with two or more feeds Ultracam · Program is published too, with manual or fixed-interval switching. There is no output mode: demand decides all work (see Demand and lifecycle).

The design stores an arbitrary number of feed descriptors. It does not impose a four-feed limit. The UI can recommend four active feeds for the intended Mac Studio workflow, while the runtime resource governor reports when the hardware cannot sustain the requested active pipelines.

## Core architecture

```text
FeedDescriptor
    ↓
FeedSession
    ↓
CaptureController → ProcessedFrame stream
    ↓
Output routes
    ├── Dedicated virtual camera
    └── Program switcher → Program virtual camera
```

`AppModel` becomes a `FeedCoordinator` that owns a stable ordered collection of `FeedDescriptor` values and lazily-created `FeedSession` instances. The current single-camera behavior becomes Feed 1 using the same reusable path.

Each `FeedSession` owns or references:

- one physical Blackmagic input assignment
- one `CaptureController`
- one DeckLink backend and camera sink
- one main preview renderer and one tray renderer
- one automatic camera-demand monitor
- one LUT/effects configuration
- one telemetry snapshot
- one or more output routes

The pipeline must remain single-source. A processed frame is published through a queue-owned `ProcessedFrame` or `FrameLease` abstraction with explicit ownership and timestamp rules. Output routes may consume the same processed frame without re-running the LUT, scaling, or color conversion.

## Feed persistence

Introduce stable `FeedID` values and versioned `FeedDescriptor` records containing:

- stable ID, display name, and ordering
- selected Blackmagic device ID
- LUT security-scoped bookmark and LUT-enabled state
- downscale, color-format, frame-rate, processing, and preview settings
- automatic-start preference
- enabled state

Global settings contain:

- selected feed ID
- `outputMode`: retired. Decoded, kept and written back unread, so an older build finds a valid value after a downgrade
- switcher configuration
- virtual-camera registry version

Migrate the current single-feed v1 settings into Feed 1 without losing the selected device, LUT bookmark, effects, or preview preferences. Decode old settings with defaults for new fields.

## Physical input ownership

A device manager reserves each physical Blackmagic input for at most one feed. Feed assignment states are explicit:

```text
available
reserved
capturing
unavailable
conflict
```

Two feeds cannot silently claim the same UltraStudio. Conflicts appear before capture starts and remain visible in the feed UI. A feed may be persisted while its physical device is unavailable.

The runtime resource governor permits any number of configured feeds but limits active capture and processing based on actual device availability, GPU memory, queue pressure, and measured frame timing. It reports inability to sustain a feed instead of silently dropping frames.

## Virtual-camera registry and extension

Store a versioned virtual-camera registry in the shared app group. The app writes complete registry snapshots transactionally. The extension loads the last valid snapshot, reconciles changes, and never publishes a partial update. If the app exits, the extension retains the last valid registry.

Refactor the extension into one generic descriptor-driven implementation:

```text
CameraProvider
  ├── VirtualCameraDevice(feedID: ...)
  │     ├── source stream
  │     └── sink stream
  ├── VirtualCameraDevice(feedID: ...)
  │     ├── source stream
  │     └── sink stream
  └── ...
```

Every virtual device has stable:

- feed ID
- device UID
- source stream ID
- sink stream ID
- display name
- demand property

There are no Camera 1, Camera 2, or Program-specific implementations. All devices use the same source/sink, negotiation, standby, producer authorization, and demand-count code.

When a feed is removed while an application is using it, mark it unavailable, stop accepting new clients, and remove it only after existing consumers release it. This avoids dangling Zoom camera references. Camera applications may need a restart after registry changes because they can cache device enumeration.

## Demand and lifecycle

Demand is route-aware, and the demand monitor runs for the app's whole life. Nothing depends on a mode:

```text
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

Rising edges act at once. A falling client edge takes effect after 5 s, so a meeting app probing a camera doesn't restart capture or the director. A user Stop ignores the hold.

A client can arrive before its sink. The closed sink's contract is written to the device whenever it changes, so the client finds the right format. If it holds device control on another format, the sink connects anyway and its first sample renegotiates inside the extension. A failed connect tries again every second while a client waits, and raises a problem. If meeting apps won't take that format change, `FeedLifecycleDemandPolicy.sinkOpensWithCamera` is the one-constant fallback: each sink opens with its camera and takes no frames until a client comes.

Automatic start continues to use event-driven source-stream notifications rather than polling.

The idle path must release capture timers, working GPU resources, processing queues, preview queues, and DeckLink resources. The app may retain ordinary process state and the persisted LUT.

## Published cameras

Each enabled feed publishes its own virtual camera, for example:

```text
Ultracam · Camera 1
Ultracam · Camera 2
Ultracam · Camera N
Ultracam · Program   (with two or more)
```

One function, `VirtualCameraRegistrySnapshot.devices(for:)`, builds the list. Only adding, removing or renaming a camera changes it, so meeting apps, which cache it, rarely have to look again. The extension's limit of 32 devices means at most 31 cameras. Removing a camera needs only that camera stopped; adding and renaming are always live. Reset All Settings alone needs the whole app idle.

Each feed independently reports:

- input and output format/rate
- LUT and effects state
- audio channels, sample rate, meters, packets, samples, bytes, bitrate, and gaps
- video timecode, bitrate, frame rate, and drop counters
- preview and camera-client demand

Two synthetic feeds must qualify independent configuration, telemetry, demand, and shutdown behavior before hardware testing.

## Program switcher

Add a `SwitcherCoordinator` separate from `CaptureController`. Its persisted state contains:

- selected feed ID
- manual/automatic mode
- fixed interval in seconds
- switch strategy
- future Program audio policy

Strategies are represented explicitly:

```text
fixedInterval
 dynamicAnalysis
```

`dynamicAnalysis` is initially disabled and reports “Coming later.” It must not silently fall back or pretend to analyze content.

Program output uses one virtual device:

```text
Camera 1 ─┐
Camera 2 ─┼─> Switcher → Ultracam · Program
Camera N ─┘
```

Initial behavior:

- manual cuts select the next feed at the next valid processed-frame boundary
- fixed auto-switching advances after the configured interval
- feeds without a valid signal are skipped
- Program timestamps remain monotonic across cuts
- source-to-Program timestamp mapping resets on a cut without moving backward
- Program demand keeps only the selected feed active initially
- the switcher timer runs only while the Program camera has a consumer

The first audio policy is monitoring-only: Program meters follow the selected feed. Virtual audio output is not part of this phase. Add a future `ProgramAudioPolicy` field with `selectedFeed`, `muted`, and `mix` values so the model can evolve without another persistence migration.

## User interface

The main window becomes a feed-oriented workspace:

- sidebar with a scrollable list of feeds
- per-feed name, input, live/idle state, signal state, audio meter, and drop warning
- selected-feed preview and effects/LUT controls
- detected metadata and diagnostics for the selected feed
- every published camera with its In use state
- Program preview and switcher controls with two or more feeds

The tray uses the same parameterized views in compact form:

- selected feed
- Program output state
- manual cut and automatic switching controls
- compact feed statuses and meters

The UI must use collections and scrolling rather than assuming two or four feeds.

## Implementation sequence

1. Add `FeedID`, `FeedDescriptor`, versioned persistence, and migration from current v1 settings.
2. Extract the current single feed into `FeedSession` and `FeedCoordinator` without changing one-feed behavior.
3. Introduce the ownership-safe `ProcessedFrame`/output-route abstraction while retaining the current dedicated camera route.
4. Add physical-device reservation and runtime resource-governor states.
5. Refactor the camera extension around a descriptor-driven virtual-device collection and transactional shared registry.
6. Publish a camera per feed with independent demand and telemetry.
7. Add the Program route and manual frame-boundary switching.
8. Add fixed-interval auto-switching.
9. Add the disabled dynamic-analysis strategy stub and future Program audio-policy model.
10. Refine main-window/tray UI and qualify two-feed hardware behavior.

## Verification gates

Before calling the refactor complete, test:

- migration and per-feed LUT/effects persistence
- arbitrary feed descriptor counts and stable ordering
- two feeds attempting the same physical input
- multiple virtual devices with independent source demand
- one processed frame consumed by two routes
- one route stopping while another continues
- feed removal with an active camera client
- separate-output routing for two synthetic feeds
- Program switching without timestamp regression or duplicate cuts
- fixed auto-switch timer start/stop tied to Program demand
- isolated audio/video/timecode telemetry
- clearing meters, timecode, bitrates, and counters when each feed stops
- idle release of GPU, DeckLink, preview, and output resources
- Zoom enumeration and restart behavior after registry changes

## Astra audit resolutions

The current implementation is still single-feed. These are prerequisites,
not assumed existing capabilities:

- `AppModel`, `AppSettingsStore`, and the `ultracam.settings.v1` key currently
  hold one selected device, one `CaptureController`, and one automatic-feed flag.
  Define the v1-to-v2 migration explicitly: decode the old JSON, create Feed 1
  with a deterministic UUID, move the old LUT bookmark/effects into it, write a
  complete v2 snapshot, and retain the old data until the new write succeeds.
- `CameraProvider` currently publishes one fixed device with one pair of hard-
  coded streams and global format/latest/consumer state. `VideoContract` and
  `CameraDemandMonitor` likewise identify one device. The extension entry point
  must become a registry-backed device manager before multiple feeds can work.
- The registry format must include a schema version, generation, checksum, feed
  descriptors, stable UUID derivation, and the app-group identifier. Writes use
  a temporary file followed by flush and atomic rename. The extension falls back
  to the last valid snapshot after a crash or partial write.
- Producer authorization and sink ownership are currently global to one
  provider. Ownership must become per virtual device/feed, while each source
  demand property remains per feed. Feed removal uses a grace state: unavailable
  to new clients first, removed only after existing clients release it.
- Demand notifications and producer ingestion are separate mechanisms. Source
  demand is event-driven and route-aware; the sink's frame-pull timer remains a
  bounded producer-ingest mechanism. The route demand truth table must cover
  dedicated-camera demand, Program demand, manual output demand, preview-only
  demand, and transitions where one route stops while another remains.
- `CaptureController` currently sends directly to one camera sink. Introduce a
  queue-owned `FrameLease`/`ProcessedFrame` contract containing image, PTS,
  duration, format, and metadata. Fan-out must retain/release explicitly,
  bound each route's queue, and allow one route to stop without invalidating
  another route's frame.
- Program switching needs a defined timestamp algorithm: flush stale queued
  frames at a cut, coalesce rapid cut requests, map the new source timebase to
  the next monotonic Program timestamp, and skip invalid feeds without sending
  duplicate or backward-timestamped frames.
- Physical input reservations and runtime budgets need measurable policy. Start
  with current capture admission (12 frames) and output pool (64 images) as
  inputs to a governor, then add per-feed GPU-memory, queue-latency, and frame-
  timing measurements. Failure must be explicit and visible rather than silent
  frame loss. The model may store arbitrary feeds even when fewer can run.
- Audio telemetry currently infers the sample rate from packet timing. Preserve
  that behavior for existing hardware, but add an explicit audio-rate field to
  the future media contract so per-feed and Program telemetry can distinguish
  reported rate from inferred rate.

Additional verification gates are required for the migration and boundaries:

- old v1 JSON migration and rollback after a failed v2 write
- registry crash/partial-write recovery and stable per-feed UID uniqueness
- per-feed producer ownership and source-demand transition matrix
- sink pull-timer lifecycle independent of source demand notifications
- one processed frame consumed by two routes, then one route stopping
- Program cuts during missing signal, pending frames, and rapid coalesced cuts
- resource-governor refusal/degradation with two active synthetic feeds
- telemetry reset when a feed stops while another feed continues

## Current implementation status (2026-10-15)

Completed and tested:

- versioned `FeedDescriptor` persistence with deterministic Feed 1 migration
- Natural Talking Head director with audio/transcript cues, hysteresis, output acknowledgement, and rewind reset handling
- bounded capture ownership, per-generation backpressure accounting, and frame-rate clock validation
- DeckLink timing, timecode, embedded-audio metadata, and video-format validation
- CMIO client-ID ownership and source-client disconnect cleanup
- versioned feed/program virtual-camera descriptor and registry contracts
- monotonic Program timestamp mapping, cut coalescing, stale-frame flush signaling, and missing-source handling
- queue-owned processed-frame fan-out leases with bounded route policies

The native synthetic suite currently passes 142 tests, and the debug app build passes. The remaining integration work is to connect these pure contracts to the runtime multi-feed coordinator, descriptor-driven CMIO device registry, per-route demand leases, Program output route, and per-feed UI. Until those runtime steps land, the existing app still runs one live feed while its persisted model and tested contracts are ready for the refactor.
