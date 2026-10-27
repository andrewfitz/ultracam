# Vendor plugin plan

## Goal

Move Blackmagic and Sony out of the app's core and into self-contained vendor
plugins that talk to the app through one internal API. Later, the same API
should take UVC, AJA, Canon, Panasonic, RED or Blackmagic camera control
without any change to the core.

"Plugin" here means a folder in the repo, compiled into the app and listed in
one registry file. There are no loadable plugin bundles or runtime plugin
discovery. Vendor SDKs may still load driver libraries, and their dylibs may be runtime dependencies
(Sony is the first example); their paths, signatures, install names and
licenses are managed by the vendor manifest. Updating an SDK should change the
vendor folder and its generated-project check only. A developer adding a
vendor copies a folder and follows one guide.

The plan has two parts, and they are separate projects:
- **Part A** is the plugin boundary: the API, the folders, the build, and
  closing the leaks.
- **Part B** opens the video pipeline to sources other than 4K 10-bit 4:2:2,
  which Part A doesn't do.

A new capture vendor that doesn't deliver exactly today's format needs both.

## Acceptance gates for the first implementation slice

Revised 2026-10-27 after review. Step 1 implements the capture contract and
exercises it with the fake and DeckLink adapter. Build and release checks land
in steps 4 and 6; the following requirements govern those later steps too:

- **Delivery ordering:** capture callbacks use one serialized delivery stream.
  Every delivery carries a monotonically increasing sequence number. A
  `formatChanged` delivery must precede the first frame for that format, and
  frame, media and audio deliveries preserve their source order. The core must
  never infer ordering from callback threads or queue arrival order.
- **Backpressure and loss:** “every frame” means the plugin does not
  intentionally drop an admitted source frame because a consumer is busy. The
  core owns queue limits and records host-side drops separately from device
  drops. Step 5 closes unbounded paths and records each queue's budget,
  admission result and overload behavior; it does not promise lossless delivery to
  every downstream consumer under arbitrary load.
- **Lifecycle:** `CaptureSession` has an explicit state machine for
  `start`, repeated `start`, `stop` before/after start, and failure. `stop`
  is a quiescence barrier: it returns only after no delivery can begin. A
  callback never calls `stop` synchronously. Queue and pool budgets bound
  retention; buffers remain valid after stop while consumers still own them.
- **Availability and partial failure:** a registry snapshot reports each
  plugin's availability, status and device-list error independently. One
  missing SDK or failed driver must not hide devices from other plugins.
- **Strict concurrency:** all SDK-backed reference types are isolated behind
  actors or explicitly documented `@unchecked Sendable` wrappers. The
  `CVPixelBuffer` crossing the delivery boundary uses one audited wrapper;
  raw SDK objects never cross it.
- **Build isolation:** until separate targets exist, the boundary check is
  documented as linting rather than compiler isolation. CI also checks the
  generated Xcode project, plugin symbol imports and target membership.
- **Release legality:** Sony runtime redistribution is a hard prerequisite for
  an official release. Local unsigned/debug builds may omit unavailable SDKs;
  every build checks its enabled dependencies. Official release validation
  additionally requires Sony, valid signatures and recorded license evidence.

## Two kinds of plugin

A vendor provides one or both of these. They have unrelated interfaces.

| Kind | Does | Today | Later |
|---|---|---|---|
| **Capture source** | Lists input devices, follows hot-plug, delivers video frames (plus audio and timecode when it has them), reports driver status and diagnostics | Blackmagic DeckLink | AJA NTV2, UVC (AVFoundation), NDI |
| **Camera control** | Finds cameras on the network or over USB/Bluetooth, pairs, reads and sets properties, sends events, attached to one feed | Sony Camera Remote SDK | Canon, Panasonic, Blackmagic cameras (REST/Bluetooth), RED |

Today both live in `Sources/DeckLinkBackend/`. Sony control is not even a
separate translation unit: `UltracamBackend.mm:2871` does
`#include "SonyCameraControl.inc"`.

Not covered by this plan:
- **Program output to hardware** (DeckLink or AJA playout) would be a third
  kind later. `UltracamBackend.h` has no output methods.
- **Colour-science presets** stay in MonitorKit and the app. These are
  `SonySLog3FalseColor` and `SonyARRIStyleFalseColor` (`MonitorWorkspace.swift`) and the
  gamut list (`UIInspector.swift:16`). They are monitoring maths, not SDK
  integrations.

## Where the code stands

Line numbers are as of 2026-10-26. Other sessions edit these files, so they
drift: search for the quoted code.

### Seams that already exist

- `CaptureServices` (`CaptureController.swift:1614`) is a closure-based
  injection point. `CaptureServices.live` is the only place that builds an
  `UltracamBackend`.
- `AppHardware` (`AppModel.swift:31`) is the app-level seam. `.offline` is a
  half-built fake used 18 times by UIVerify and MonitorAppIntegration.
- Device IDs start with the vendor. There are two forms:
  - the persistent ID, `decklink:00000000a1850ab8` (`UIPresentation.swift:333`);
  - a legacy name-and-index fallback, `decklink:<name>:<index>`
    (`UltracamBackend.mm:186`).

  The rule: the plugin ID is the text before the first colon, and the rest
  belongs to the plugin.
- Sony control is keyed by feed ID, not by capture device (`SonyCameraStore`),
  which is the right shape for any camera-control vendor.
- The camera extension never links vendor code. It must stay that way.

### The single input format

The whole app assumes one source: 3840×2160 10-bit 4:2:2 (v210 or 10-bit
4:2:2 biplanar) at 29.97 or 59.94 fps, Rec.709, with 48 kHz 32-bit stereo
audio paired with each frame, over HDMI.

That assumption is enforced at about a dozen gates, starting with
`UltracamBackend.mm:851`, `CaptureController.swift:1048-1056` and
`LUTProcessor.swift:533-538`. Below the gates it is baked in as constants:
- shader maths, buffer sizes and timescales;
- recording settings, the extension's format list, and stored settings;
- UI text.

`LUTProcessor.swift:863-874` lists 8-bit and 4:2:0 copy layouts, but nothing
can reach them, because the gates run first.

The full inventory, about 150 items, is in
[SOURCE_FORMAT_PLAN.md](SOURCE_FORMAT_PLAN.md) (Part B). The limit also
refuses a 1080p camera on an UltraStudio, so Part B is worth doing for DeckLink
alone.

### Audio

- **Format:** embedded audio is 48 kHz signed 32-bit throughout:
  - `CaptureController.swift:1016` rejects any other sample size;
  - the rate comes from `EmbeddedAudioFormat.sampleRate` (`:1501-1506`);
  - `EmbeddedAudioClockAnchor.place()` rejects any other timescale.
- **Clock:** packet times are on the device's audio clock, not the video
  clock. The app maps them itself. `EmbeddedAudioClockAnchor`
  (`SourceRecordingAdapter.swift:358-445`) pairs each packet with the frame
  delivered in the same callback, which is why frame-then-audio order is part
  of the contract.
- **Metering:** live capture uses the source-audio path. On it, peak and RMS
  come from the backend (`UltracamBackend.mm:618-663`). The raw-audio-only
  path zeroes them and sends no timecode (`CaptureController.swift:1022-1025`).
- **Timecode:** it is read only when a media handler is set (`.mm:818`). It
  arrives as an `HH:MM:SS;FF` string whose `;` carries the drop-frame flag
  that `SourceRecording.swift:232` parses.

### Events

Capture events are free-form strings, and the core matches their text:
- prefix and substring checks at `CaptureController.swift:452-461`
  ("Capture error: ", "no video signal", "unsupported");
- an exact string compare in the watchdog at `:552`.

Vendor wording also sits in the core:
- "Waiting for UltraStudio signal…" (`:518`, `:552`, `:580`);
- "Check the FX3 HDMI output" (`:558`, and `UltracamBackend.mm:847`).

Sony events are strings too: `kind == "changed"` (`SonyCameraStore.swift:120`).

## The internal API (Part A)

There are two homes, because the camera extension must compile the value
types but must never see plugins:

- **`Sources/Shared/SourceFormat.swift`** holds the value types that describe
  a source: `SourceFormat`, `FrameRate`, `Colorimetry`, `SourceAudioFormat`,
  `Timecode` and `PixelFormatTable`. It is added to the extension's explicit
  file list (`generate_project.py:39-43`).
  - These types land in **step 1**, with only today's single format in the
    table. Part B widens the table; it doesn't introduce the types.
  - They are defined in [SOURCE_FORMAT_PLAN.md](SOURCE_FORMAT_PLAN.md).
- **`Sources/DeviceAPI/`** (app only) holds:
  - the plugin protocols;
  - `VendorRegistry.swift`;
  - the future `GPUIngest` service for SDKs returning frames in ordinary
    memory; its implementation lands in B7;
  - the fake plugins;
  - one C header, `DeviceAPI.h`, for constants ObjC++ plugins write.
    `UltracamCaptureHostTimeAttachmentKey` moves there, because the
    single-module build generates no `-Swift.h`, so native code can't see
    Swift constants.

Plugins depend on DeviceAPI, Shared and system frameworks. The rest of the
app depends on DeviceAPI and never names a plugin type. The one exception is
`VendorRegistry.swift`, which the boundary check allowlists.

### Capture source

```swift
protocol CaptureSourcePlugin: Sendable {
  var descriptor: VendorDescriptor { get }           // id "decklink", name, badge, hint, SDK status
  func driverStatus() -> DriverStatus                // installed / supported / user-facing message
  func devices() throws -> [CaptureDeviceInfo]
  @MainActor func observeDevices(_ handler: @escaping @MainActor @Sendable (CaptureDeviceSnapshot) -> Void)
    -> DeviceObservation
  /// What `start` will deliver, if known before the first frame, so the
  /// controller can warm the GPU and connect the camera sink (today's
  /// `capturePixelFormat`, `CaptureController.swift:414-417`). Nil with
  /// `.automatic` timing until the source is detected.
  func expectedFormat(deviceID: String, timing: CaptureTiming) -> SourceFormat?
  func makeSession() -> any CaptureSession           // one per start, own control queue
  func diagnostics(deviceID: String) -> DeviceDiagnostics?
  func settings(deviceID: String) async throws -> [VendorSetting]
  func apply(_ value: VendorSettingValue, to setting: VendorSetting.ID,
    deviceID: String) async throws
}

struct CaptureDeviceSnapshot: Sendable {
  var status: DriverStatus
  var devices: [CaptureDeviceInfo]
  var error: PluginError?     // nil for a successful empty enumeration
}

struct CaptureDeviceInfo: Identifiable, Sendable {
  var id: String                 // "<plugin>:<anything>"; plugin = text before the first colon
  var name: String
  var connectors: [Connector]    // hdmi, sdi, usb, network …
  var shareable: Bool            // one source may feed several cameras (NDI)
  var mayPause: Duration?        // nil: a 2 s gap is a lost signal; else the plugin's timeout
  var supportedModes: String     // user-facing, e.g. "2160p/1080p 23.98–60, 10-bit 4:2:2"
}

protocol CaptureSession: AnyObject, Sendable {
  func start(deviceID: String, timing: CaptureTiming, handlers: CaptureHandlers) throws
  func stop()
  var counters: CaptureCounters { get }              // device drops, backlog, max backlog
}

struct CaptureHandlers: Sendable {
  /// One serialized callback for every delivery. It is never invoked
  /// concurrently or after stop returns.
  var deliver: @Sendable (CaptureDelivery) -> Void
}

enum CaptureDelivery: Sendable {
  case event(sequence: UInt64, value: CaptureEvent)
  case frame(sequence: UInt64, buffer: CapturedPixelBuffer, info: CaptureFrameInfo)
  case media(sequence: UInt64, value: CaptureMediaInfo)
  case rawAudio(sequence: UInt64, value: CaptureAudioPacket)
}

/// The only audited CoreVideo crossing at the SDK callback boundary.
struct CapturedPixelBuffer: @unchecked Sendable {
  let value: CVPixelBuffer
}

enum CaptureEvent: Sendable {
  case formatChanged(SourceFormat)   // required before the first frame of each format
  case discontinuity                // source clock restarted
  case waitingForSignal, signalLost(reason: String), unsupportedInput(String),
       fatal(String), info(String)
}

struct CaptureFrameInfo: Sendable {
  var presentationTime: CMTime
  var duration: CMTime
  var signalValid: Bool
  var timecode: Timecode?
}

enum PluginError: Error, Sendable {
  case unavailable(String)
  case unsupported(String)
  case busy(String)
  case invalidState(String)
  case failed(String)
}
```

**Value types and invariants:**
- `CaptureFrameInfo` carries the frame's `Timecode` struct, replacing the
  `HH:MM:SS;FF` string. `presentationTime` and `duration` are numeric,
  valid values in the source clock domain; duration is strictly positive.
  Part A preserves today's non-negative, epoch-zero admission rule. A clock
  reset is preceded by a discontinuity event, even if format is unchanged.
- `CaptureAudioPacket` gives the PCM, its `SourceAudioFormat`, and the packet
  time in that format's clock domain.
- `CaptureTiming` is `.automatic` (follow the source's mode) or
  `.fixed(SourceFormat)`. Until B3, the DeckLink plugin maps `.fixed` onto
  today's `inputFast` flag after validating the entire requested format.
  Unsupported dimensions, pixels or rates are rejected, not reduced to a Bool.
- `CaptureDelivery.sequence` is strictly increasing for one session. A
  `formatChanged` event precedes the first frame using that format. Unpaired
  audio is valid for future sources and is delivered independently.
- **CPU-memory SDKs** (NDI) still hand the core a `CVPixelBuffer`. The plugin
  passes its raw frame to `GPUIngest`, which uploads on the GPU into an
  IOSurface pool and returns the buffer. Plugins never touch Metal
  themselves.

The remaining types have these minimum schemas. Step 1 supplies their checked
Sendable definitions and validation before wiring the adapter:

| Type | Required fields and behavior |
|---|---|
| `CaptureAudioPacket` | Owned immutable PCM planes, sample-frame count, `SourceAudioFormat`, packet time and optional paired-frame delivery sequence. Validate plane count/byte lengths. SDK packet storage cannot escape without an owner. |
| `CaptureMediaInfo` | Optional timecode and paired-frame sequence, audio presence/format, `audioPacketTime` in the declared audio clock domain, sample/byte counts and per-channel peaks/RMS. The legacy adapter preserves the packet timestamp when mapping to today's `CaptureMediaStats`, alongside its string timecode and first two channels. |
| `VendorSettingValue` | Tagged Boolean, signed/unsigned integer, finite decimal, text or choice ID. Settings supply current value, range/choices and whether applying interrupts capture. |
| `DriverStatus` | Installed/supported flags, version and localized reason. Driver installation is distinct from SDK availability; system-only plugins need no SDK installation. |
| `Connector` | Stable HDMI, SDI, USB, network and optical cases, independent of device identity. |
| `DeviceObservation` | Main-actor handle with idempotent cancellation. Queued notifications check the active token; cancellation from a handler is permitted. |

Media deliveries carry their packet timestamp and clock identity even when no
raw-audio consumer is installed. Never derive that timestamp from paired video
PTS: the clocks may differ. When a delivery has no audio packet, represent its
timestamp as absent and map it to the legacy invalid CMTime. Unpaired media
does not borrow the last video frame's timestamp or pairing sequence.

**Device settings and capabilities:**
- Part B's needs are in the API from the start: shareable and pausable
  sources, connectors, supported-modes text, and per-device settings. A
  plugin written against Part A can adopt formats incrementally. Part B may
  require API revisions as these capabilities are exercised; compile and run
  conformance checks for every bundled plugin on each revision.

**Event wording:**
- The core turns events into user text, worded neutrally ("Waiting for
  signal…").
- Plugins add vendor hints through `VendorDescriptor.signalHint`, for example
  "Check the FX3 HDMI output and selected frame rate."

**Collapsing the start variants:**
- This API replaces the eight `start`/`startAuto` overloads in
  `UltracamBackend.h` at the plugin boundary.
- In step 1, `CaptureServices.live` adapts one session onto the existing
  eight `CaptureServices` closures, and maps `CaptureEvent` back onto today's
  strings.
- `CaptureController` (which branches on which closures are set, `:416-510`)
  and its tests stay unchanged until step 5.
- Live capture keeps the source-audio path, so meters and timecode behave
  exactly as now.

**Routing:**
- `AppHardware.captureServices` is built per feed, not per device
  (`AppModel.swift:403-404`).
- A feed that switches from a DeckLink input to another vendor's device keeps
  the same services.
- So at each `start`, the live services resolve the plugin from the device ID
  and ask it for a session, rather than fixing a plugin when the feed is
  created.

`InputDevice` is replaced by `CaptureDeviceInfo` at the app seam; the picker,
diagnostics, settings and persisted selection all use the same snapshot. The
existing selected-device IDs are preserved byte-for-byte. A missing device
remains a stable unresolved selection rather than being silently reassigned. The core
claims an exclusive device before starting a feed; `shareable` devices may be
claimed by multiple feeds. The plugin also checks hardware exclusivity against
other processes and returns a typed busy error for an unsupported claim. Core
releases its claim on start failure, removal and stop.

### Threading contract

The native SDK may use several threads; the adapter presents one serialized
delivery stream. A callback's frame, media and paired audio are one ordered
group. Control/discovery events enter between groups. A format transition
drains old-format deliveries before announcing the new format. The core applies
format state before admitting a matching frame, including recording admission
on the callback path. Queueing only the event onto another queue is insufficient.

- Start and stop run on one control queue per session, off the main actor.
  Delivery never synchronously waits for that queue: stop may be waiting for
  delivery to finish. Never call stop synchronously from a handler.
- Callbacks return promptly. Reuse storage where possible and measure new
  allocations against baseline; existing PCM copies and CoreVideo wrappers
  mean this is not an absolute zero-allocation guarantee.
- Stop closes admission, unregisters callbacks and drains queued/active
  deliveries before returning. It does not wait for retained buffers to be
  released. Core rejects queued work from older session generations.
- A published pixel buffer and its attachments are immutable until all
  consumers release it. It owns the vendor frame even after stop. Consumers
  allocate separate output buffers; this is the audited Sendable wrapper's
  safety invariant.
- GPUIngest retains input until GPU completion and delivers only ready output.
  Its implementation belongs to B7, not Part A.

| State/action | Result |
|---|---|
| Fresh / start | Acquire resources and begin delivery; on failure, release partial resources and quiesce deliveries before throwing. |
| Running / same device and timing start | No-op, preserving original handlers. |
| Running / different configuration start | Throw `invalidState`; stop and create a new session. |
| Fresh, running or failed / stop | Become stopped, release claim and quiesce callbacks. Repeated stop is a no-op. |
| Stopped / start | Throw `invalidState`; use `makeSession` for a new start. |

The delivery callback returning acknowledges handoff, not downstream
consumption. Each consumer owns its admission result, queue budget and refusal
counter. Preview congestion must not block recording admission. Step 1 keeps
existing overload behavior and records its baseline; step 5 inventories queue
limits and resolves unbounded paths in separately tested commits. B1c converts
limits to source-relative time and bytes. Supported normal load must still
show zero unexpected loss. Overload is reported, never silent success or a
routine latest-frame policy.

### Camera control

```swift
protocol CameraControlPlugin: Sendable {
  var descriptor: VendorDescriptor { get }
  /// Keychain service; Sony returns its existing
  /// "org.ultracam.sony-camera-control.credentials.v1" so saved logins survive.
  var credentialService: String { get }
  func credentialAccount(for camera: ControlCamera, fingerprint: String) throws -> String
  func discover() async throws -> [ControlCamera]    // stable id (Sony: MAC), name, address
  func prepare(_ request: ControlPreparationRequest) async throws -> ControlPreparationResult
  func connect(feedID: String, generation: UInt64, camera: ControlCamera,
    credentials: ControlCredentials?) async throws
  func properties(feedID: String, generation: UInt64) async throws -> [ControlProperty]
  func set(_ property: ControlProperty.ID, value: ControlValue,
    feedID: String, generation: UInt64) async throws
  func disconnect(feedID: String, generation: UInt64) async throws
  func shutdown() async throws
  /// Events are ordered per feed and tagged with the connection generation.
  /// Async reply resumption order is not assumed. One handler, set once.
  @MainActor func setEventHandler(_ handler: @escaping @MainActor @Sendable (ControlEvent) -> Void)
}
enum ControlEvent: Sendable {
  case changed(feedID: String, generation: UInt64)
  case disconnected(feedID: String, generation: UInt64, reason: ControlDisconnectReason)
  case error(feedID: String, generation: UInt64, error: ControlError)
}
```

This mirrors `UCSonyCameraControl` and `SonyCameraStore`, which are already
feed-keyed.

`ControlCamera`, `PairingRequirement`, `ControlCredentials`, `ControlProperty`,
`ControlValue`, `ControlDisconnectReason` and `ControlError` are defined in
DeviceAPI with stable IDs, typed values, retryability and pairing/authentication
states. The core never parses vendor strings. The plugin serializes SDK
commands per feed. The store assigns a generation before connecting and checks
it after every await and event. A disconnect makes that generation terminal;
a late connect reply cannot resurrect it. Property reads carry an invalidation
revision so an older response cannot clear a newer change notification.
Cancellation retires the operation and releases late connections without
deleting credentials. Shutdown closes admission and disconnects all feeds;
if SDK cleanup remains pending it throws a typed error and retains callback
owners until their release is safe.
Every queued SDK command checks its generation before touching a connection;
an old disconnect cannot tear down the replacement connection. Repeated
disconnect on an already closed generation is a no-op.

| Type | Required fields and behavior |
|---|---|
| `ControlCamera` | Plugin ID, stable opaque camera ID, display name, transport/address and optional fingerprint. Codable persistence excludes secrets. |
| `ControlPreparationRequest` | Either a discovered `ControlCamera` or a typed unresolved endpoint. A manual network endpoint carries its address, optional expected stable identity (Sony: MAC) and authentication mode (`none` or `usernamePassword`), preserving today's Check Camera inputs. |
| `ControlPreparationResult` | Resolved `ControlCamera` with verified stable identity and fingerprint where available, plus `PairingRequirement`. Identity resolution failures are typed errors; an unresolved endpoint cannot become an assignment. |
| `PairingRequirement` | None, username/password with fingerprint, or explicitly unsupported flow. New pairing mechanisms require an API extension. |
| `ControlCredentials` | Typed username/password payload for Sony; redacted descriptions, never stored in preferences or diagnostics. |
| `ControlProperty` / `ControlValue` | Stable ID, localized label, writable flag/reason, current Boolean/integer/decimal/text/choice value and allowed options/range. Preserve Sony's unsigned 64-bit values. |
| `ControlDisconnectReason` / `ControlError` | Stable reason code, retryability and localized message; distinguish manual, removed, transport, authentication, changed identity, unavailable and SDK failures. |

Optional vendor views use a main-actor factory registered in `VendorRegistry`.
Its DeviceAPI context supplies feed ID, generic property state and actions;
the view cannot reach AppModel or other core internals. The generic panel is
used when no custom view is supplied.

The context includes a generic prepare action taking plugin ID and
`ControlPreparationRequest`. `CameraControlStore` invokes the plugin, checks
the operation generation and receives the resolved result. Both discovered
selection and a Sony manual-address form use this action, including when
discovery returns no cameras. The store checks the resolved identity against
any saved pin before looking up credentials or connecting; preparation never
silently replaces a saved fingerprint. Sony's SDK restriction on mixing manual
and discovered connections remains plugin-owned and surfaces as a typed error.

**What the core keeps:**
- feed assignment persistence, keyed by plugin ID;
- Keychain storage, under the plugin's `credentialService` and account;
- fingerprint pinning;
- the reconnect-once-at-launch rule;
- a generic property panel.

**What the plugin supplies:**
- **The Keychain service and account strings.** Sony's account scheme
  (`SonyCameraCredentials.swift:37-50`) requires a 12-hex-digit MAC, which
  other vendors' IDs won't fit.
- **Its own SwiftUI view**, optionally, for anything the generic panel can't
  show.

### Shared types

- **`VendorDescriptor`**: ID, display name, badge text ("SONY",
  "BLACKMAGIC"), signal hint, SDK version, and whether the SDK is present. It
  replaces the `Brand` enum (`UIFeedSettingsMenu.swift:104`) and the name
  sniffing.
  - Plugin IDs are permanent: they are stored in device IDs and settings.
- **`DeviceDiagnostics`**: the common counters (drops, backlog, temperature,
  signal, host time mapped) plus `[(label, value)]` vendor sections. It
  replaces `UltracamDeviceDiagnostics` in the app.
- **`DriverStatus`**: one per plugin. The single `driverWarning` string
  (`AppModel.swift:35`, `:534`) becomes a list.
- **`DeviceObservation`**: an idempotent cancellation token. Its callback is
  main-actor isolated and always receives a complete snapshot; releasing or
  cancelling it stops future callbacks.
- **`VendorSetting`**: a stable plugin-namespaced ID, label key, current value,
  allowed values, mutability and availability reason. `apply` is asynchronous,
  throws on failure, and is followed by a fresh settings snapshot.
- **`CaptureCounters`**: a Sendable value snapshot read under the session's
  lock or atomics: device drops, plugin conversion failures, current backlog
  and maximum backlog. Core measures admission and downstream losses itself;
  diagnostics combines the snapshots without double-counting them.
- **`VendorRegistry.swift`** holds `static let capture: [any
  CaptureSourcePlugin]` and `static let control: [any CameraControlPlugin]`.
  These are instances, built once. It is the only file that names every
  plugin.
  - `AppHardware.live` is built from it.
  - The device list is the concatenation of successful per-plugin snapshots;
    an unavailable plugin contributes its status and no devices, without
    failing the other vendors.
  - Initial enumeration catches errors independently per plugin. Observations
    publish an initial snapshot and later complete snapshots in order. An
    enumeration failure clears that plugin's selectable list, retains saved
    selections as unresolved and reports its error until a successful refresh.
    Discovery errors alone do not terminate an already running session;
    its own removal/signal event controls that lifecycle.
  - The input picker groups devices by vendor when there is more than one
    vendor.
- **`DeviceAPI.version`**: an integer plus `docs/PLUGINS.md` changelog
  entries. It is a source compatibility marker for forks. All bundled plugins
  compile against the same API; exhaustive switches and conformance checks
  expose changes at build time. There is no runtime ABI negotiation.

**Device ID rules:** plugin IDs are lowercase ASCII, contain no colon, and are
immutable once released. The registry validates the prefix and rejects empty
or malformed IDs. A future plugin-ID rename requires an explicit settings
migration; it is never inferred from the display name. Blackmagic's capture
plugin keeps ID `decklink` despite the folder name `Blackmagic`. Preserve the
opaque suffix byte-for-byte, including colons in legacy device names; reject
an empty suffix. Unknown plugin IDs remain unresolved persisted selections.
Duplicate registry IDs fail validation.

Labels, hints and supported-mode descriptions are localized display values
with stable resource keys owned by core or the plugin. They never serve as
IDs, capability checks or event discriminators.

## Video rules every plugin must follow

These come straight from the pipeline requirements. `docs/PLUGINS.md` makes
them acceptance criteria:

- **Source delivery and loss accounting.** A plugin does not deliberately drop
  an admitted source frame because a consumer is busy. If its hardware or SDK
  loses a frame, that appears in `CaptureCounters.deviceDroppedFrames`. The
  core may refuse or drop work at a bounded downstream queue; those losses are
  counted separately and are visible in diagnostics and the take sidecar. The
  API does not promise lossless delivery to every consumer under arbitrary
  overload.
- **Buffers.** Frames are IOSurface-backed CVPixelBuffers that Metal can use
  without a copy. The plugin owns the allocation:
  - DeckLink's default allocator already does this;
  - an AJA plugin would DMA into IOSurface-backed buffers it allocates;
  - AVFoundation buffers are already IOSurface-backed;
  - an SDK that returns frames in ordinary memory (NDI) is read in place by
    the GPU through a no-copy `MTLBuffer`, and its unpack kernel writes the
    IOSurface pool.
- **GPU by default; CPU only by opt-in.** Every Mac Ultracam runs on is Apple
  Silicon (arm64 only, macOS 26), with a GPU and unified memory, so every
  designed route is a GPU route. A format without one is refused, unless the
  user turns on "Allow CPU conversion (compatibility)", which is off by
  default. That setting allows a counted, badged CPU conversion in one
  allowlisted type. A check script fails on CPU pixel access anywhere else.
  See "GPU by default" in [SOURCE_FORMAT_PLAN.md](SOURCE_FORMAT_PLAN.md).
- **Timing comes from the source.** Presentation time and duration come from
  the device clock, never a user-chosen rate. The host-time attachment marks
  when the frame *finished* arriving (`UltracamBackend.h:65-68`). A plugin
  whose clock stamps the start of the frame (AVFoundation does) adds the frame
  duration or documents the offset. The delivery sequence is the ordering
  authority; callback thread arrival is not.
- **Colour tags.** Frames carry CV colour attachments (primaries, transfer
  function, matrix, range), as the DeckLink backend does at `.mm:943-975`. The
  core stops assuming BT.709.

## Part B: opening the input contract

Decided on 2026-10-26: Part B is in scope and covers every hard-coded source
assumption. It is planned in [SOURCE_FORMAT_PLAN.md](SOURCE_FORMAT_PLAN.md):
- the `SourceFormat`, `FrameRate`, `Colorimetry`, `SourceAudioFormat` and
  `Timecode` types;
- one pixel-format table shared with the extension;
- the full inventory in 15 categories;
- bugs to fix now;
- steps B0-B9, verification, and its own decisions.

The value types land in step 1, holding only today's format, and the plugin
API uses them from the start:
- `expectedFormat` and `formatChanged` carry a `SourceFormat`;
- `CaptureAudioPacket` carries a `SourceAudioFormat`;
- `CaptureDeviceInfo` already has Part B's capabilities.

Part B widens the format table and exercises these capabilities. Any required
API adjustment is versioned and verified against all bundled plugins.

## Folder layout and SDKs

```text
Vendors/
  Blackmagic/
    vendor.json              # id, kinds, SDK pin, build settings, entitlements owned
    README.md                # what it supports, SDK version, license note, how to update
    Sources/                 # DeckLinkCapturePlugin.swift, DeckLinkBackend.mm/.h
    SDK/include/             # DeckLink SDK 16.0 headers, license blocks intact (committed)
    Tests/                   # DeckLinkChecks*.swift, BackendTestSupport.inc
  Sony/
    vendor.json
    README.md
    Sources/                 # SonyControlPlugin.swift, SonyCameraControl.mm/.h, discovery
    SDK/                     # gitignored; filled from the developer's own download
    Tests/                   # SonyControlChecks
    UI/                      # optional: Sony-only views
Sources/DeviceAPI/           # protocols, value types, DeviceAPI.h, registry, fake plugins
```

There are three SDK policies, and `vendor.json` states which one applies:

- **Committed** (DeckLink headers, which may be redistributed with their
  license blocks):
  - The SDK lives under `SDK/`, and `vendor.json` records its version and
    checksum.
  - `scripts/vendor-sdk.py verify blackmagic` replaces the version check in
    `fetch-decklink-sdk.sh`.
  - To update, replace `SDK/include`, bump the version, and run verify.
- **Installed locally** (Sony):
  - The SDK is never committed or fetched.
  - `scripts/vendor-sdk.py install sony <zip>` generalizes
    `install-sony-sdk.py`. It checks the archive layout and records the
    installed version in a gitignored stamp.
  - Without the SDK, the plugin builds as "unavailable", as
    `ULTRACAM_SONY_SDK` does now, and the app explains why.
- **None** (UVC): system frameworks only.

Two licenses need checking before anyone relies on them:
- **Sony:** confirm Sony's license allows shipping its runtime dylibs inside a
  publicly downloadable app. The app already embeds them, but has not been
  published.
- **AJA:** check libajantv2's license for the exact release before committing
  it under `SDK/`.

Because the Sony SDK can't go in a public repo, "bundled with its SDK" means
two things:
- Ultracam's official released app embeds Sony's dylibs; signed Release builds
  require them (decision 3).
- The source tree holds Sony's installer, not Sony's files.

Steps 3-5 use this ownership map. Generic state and Keychain storage stay in
core; Sony identity rules and SDK behavior belong to the vendor folder.

| Existing files | Final owner / migration |
|---|---|
| `Sources/DeckLinkBackend/UltracamBackend.mm/.h`, `BackendTestSupport.inc`, `Tests/DeckLinkChecks*.swift`, `ThirdParty/DeckLinkSDK` | `Vendors/Blackmagic/{Sources,Tests,SDK}` in step 4; native backend becomes `UCDeckLinkBackend`. |
| `SonyCameraControl.inc/.h`, `SonyNetworkDiscovery.inc` | Split translation unit in step 3; move to `Vendors/Sony/Sources` in step 4. |
| `Sources/App/SonyCameraStore.swift` | Generic state/assignments/reconnect policy become `Sources/App/CameraControlStore.swift` in step 3; Sony mappings move under the vendor in step 4. |
| `Sources/App/SonyCameraCredentials.swift` | Generic Keychain operations become core `CameraControlCredentials.swift`; service/account construction stays Sony-owned. Preserve exact payload encoding and account hash. |
| `Sources/App/UISonyCamera.swift` | Generic panel stays in App; any remaining Sony-only view moves to `Vendors/Sony/UI` by step 5. |
| `UICameraColumn`, `UIFeedSettingsMenu`, `UIInspector`, `UIContext`, `UILiveRoot`, `UISessionBridge`, `MonitorWorkspaceView`, `AppModel`, `UltracamApp` | Replace Sony types and lifecycle calls with generic state/actions by step 5. |
| `Tools/SonyControlChecks/*`, Sony scripts | Sources move under `Vendors/Sony/Tests`; scripts become manifest-driven wrappers. Internal native tests compile exactly one copy of their implementation. |
| Sony/Blackmagic logo image sets in `Config/Assets.xcassets` | Move into manifest-declared vendor asset catalogs in step 4, preserving asset names. |

Persist assignments in a versioned plugin/feed dictionary. Decode legacy Sony
assignments, preserve feed/camera IDs, fingerprint and overlay choice, write
and verify the new representation, then mark migration complete. Retain legacy
data for recovery; a second launch must be a no-op. Missing plugins never erase
assignments or credentials. Test both persistent and legacy DeckLink selections,
including disconnected devices.

The Sony redistribution decision is a release gate, not a documentation task:
record the allowed dylib list, version, architecture, install names, dependent
`CrAdapter` paths and license terms in `Vendors/Sony/vendor.json`. If the terms
do not permit redistribution, the official release cannot claim Sony support.

## Build system

`vendor.json` holds everything the build scripts now hard-code per vendor:
- source files;
- header search paths;
- libraries, frameworks and extra link flags;
- preprocessor defines;
- dylibs to embed, with their subfolders (Sony's `CrAdapter/`);
- the "SDK available" predicate;
- the test entry points;
- the Info.plist keys and entitlements the plugin owns.

**Link flags:** assign dependencies by actual use. Sony declares its SDK link
flags, including `-lz` and `-liconv` where required. Core also requires Security
for generic Keychain storage. Deduplicate shared dependencies; do not remove
core requirements when Sony is unavailable.

**Entitlements and plist keys:** every one gets a named owner, recorded in
the manifests or as "core":
- **DeckLink:** `disable-library-validation`, the
  `com.blackmagic-design.desktopvideo.DeckLinkHardwareXPCService` mach-lookup
  exception, and the Desktop Video preferences exception.
- **Sony:** `network.client` and `network.server`, and a requirement for the
  core-owned `NSLocalNetworkUsageDescription`. NDI may share these requirements.
- **Core:**
  - `keychain-access-groups` (used by every camera-control plugin);
  - `device.camera`;
  - the app group;
  - system-extension install;
  - camera/local-network usage wording and selected-file/bookmark permissions.

A check fails if `App.entitlements` or `App-Info.plist` lacks a key that an
available plugin owns. Entitlements are checked, never written
automatically.

`scripts/vendors.py` reads the manifests. Every build entry point uses it:

| File | Hard-coded today |
|---|---|
| `scripts/generate_project.py` | `sony_root`/`sony_available` (:17-18), the `Sources/DeckLinkBackend` glob (:37), the bridging header (:139), link flags (:143-145), the inline Sony block (:146-170) |
| `scripts/test.sh` | backend `.mm` (:47), `DeckLinkAPIDispatch.cpp` (:50), the bridging header (:57), the explicit Swift file list (:60-80), link flags (:82) |
| `scripts/ui-verify.sh` | backend `.mm` (:51), dispatch `.cpp` (:53), the depth-1 source `find` (:58), the bridging header (:64) |
| `scripts/ui-typecheck.sh` | DeckLink SDK dir and bridging header (:18-23), source glob (:24) |
| `scripts/sony-control-checks.sh` | `.inc` and header paths (:9-18) |
| `scripts/sony-hardware-smoke.sh`, `sony-sandbox-ui-check.sh`, `sony-credential-checks.sh`, `monitor-app-integration.sh`, `monitor-feed-host-checks.sh` | backend and Sony paths |
| `Tools/SonyControlChecks/Native.mm:2`, `Hardware.mm:2` | relative `#include` of the `.inc` (`main.swift` imports only through the bridging header) |

New source folders also need adding to every build:
- `generate_project.py:37` takes only `.h/.mm/.inc` from
  `Sources/DeckLinkBackend`. The extension takes an explicit list of Shared
  files (`:39-43`).
- `test.sh:60-80` is an explicit list.
- `ui-verify.sh:58` is a depth-1 `find`.
- `ui-typecheck.sh:24` is a glob.

So step 1 adds `Sources/DeviceAPI/*.swift` and `Sources/Shared/SourceFormat.swift`
to all four directly, and step 4 replaces those edits with the manifest
reader.

The manifest is a versioned schema, not an arbitrary command line. It validates
that source files, headers, SDKs and dylibs stay inside the checkout or an
explicit SDK cache; rejects shell commands and unrecognized linker flags; and
records app/test membership for each vendor file. Vendor sources are never
eligible for the extension. Resolve paths relative to the manifest and validate
containment after resolving symlinks. Reject duplicate IDs and schema errors.

Generation uses an explicit SDK inventory. Commit the project and bridging
header in a canonical optional-SDK-absent configuration so public clones work.
SDK-enabled generation is local. CI regenerates canonical files and checks the
diff, then tests SDK-present and SDK-absent generation separately. An Xcode
pre-build check compares the generated input digest with manifests, API version
and local SDK inventory, failing with regeneration instructions if stale. CI
alone cannot prevent a developer opening a stale local project.

**Bridging header:** it becomes generated. It imports `DeviceAPI.h`, each
plugin's single public ObjC header, and `Tools/auto-switcher/include/auto_switcher.h`
(today's `BridgingHeader.h:3`). This keeps the single-module build every script
uses.

Per-plugin module maps or Swift packages would have the compiler enforce
isolation, at the cost of reworking `test.sh` and `ui-verify.sh`, which
compile everything in one `swiftc` call. Until that migration, the boundary
check is linting only; it is not a security boundary. CI also checks target
membership and forbidden imports/symbols. The lint fails if:
- app code names a plugin type;
- plugin code references known core symbols/imports outside DeviceAPI and
  Shared; this detects accidental coupling but cannot prove all dependencies;
- a Swift, ObjC or Metal file under `Sources/`, or a file under `Config/`,
  contains a vendor or product name (Blackmagic, UltraStudio, DeckLink, Sony,
  FX3). Scripts, docs and the README are out of scope.

Its allowlist:
- `Config/App-Info.plist` and `App.entitlements`, until B8 rewords the usage
  strings and the plugins own their keys;
- `VendorRegistry.swift`;
- the colour-science presets;
- preview fixtures (`UIContext.swift:114-127`);
- bundled LUT names such as `FX3_SLog3_to_709.cube`;
- the Keychain continuity test;
- `validate_bundle.py`.

The ownership table governs source, credential and UI splits. Vendor assets
are manifest resources; generic credential storage stays in core.

Privacy usage descriptions are merged as core-owned, neutral strings. A
manifest may contribute required capabilities and explanatory text, but it
cannot overwrite another plugin's `NSCameraUsageDescription` or
`NSLocalNetworkUsageDescription`.

**Strict concurrency:** `ui-verify.sh:60` and `ui-typecheck.sh:20` already
build with `-strict-concurrency=complete -warnings-as-errors`, and so does
Xcode. The gap is `test.sh:54`, the only build of `Tests/` and the camera
extension sources outside Xcode. `Tests/` has never been checked strictly, so
the full test cleanup is step 2. Step 1 already compiles the new API, fake and
adapter in a focused strict-concurrency harness alongside the strict app/UI
builds, so API isolation mistakes are found before the Sony split.

**Outside developers:** before the repo goes public, two things block them,
whatever happens to plugins:
- `/Volumes/8TB` is hard-coded in the build and test helpers under `scripts/`
  and `Tools/`. Make the build root an environment variable through one shared
  path helper (decision 5), and update fixtures separately where they are
  intentionally sample data.
- Add the chosen Apache-2.0 license and notices in step 6 (decision 4).

## Leaks to close in the app

1. **Diagnostics type.** `AppHardware.diagnostics` returns the DeckLink ObjC
   type (`AppModel.swift:37`, `:1465`; `UIDiagnostics.swift:237`). Change it
   to `DeviceDiagnostics`.
2. **Advertise HDR.** `AppHardware.setAdvertisesHDR` (`AppModel.swift:40`,
   `:104`, `:392`) is a DeckLink EDID feature.
   - Make it a per-device `VendorSetting` that only DeckLink declares.
   - Migrate the one global value onto each DeckLink device once, and keep
     reading the old key until then.
   - The UI line at `UISettings.swift:683` ("UltraStudio HDMI inputs") moves
     with it.
3. **Brand detection.** `UICameraColumn.swift:725` and
   `UIFeedSettingsMenu.swift:64-66` guess the brand from device names. Replace
   both with the feed's `VendorDescriptor`.
4. **Vendor copy:**
   - `UIInspector.swift:105` "Choose the Blackmagic capture device";
   - the `UIPresentation.swift:346` "Blackmagic input" fallback name;
   - `UIFeedSettingsMenu.swift:36`;
   - `CaptureController.swift:360`, `:518`, `:552`, `:558`, `:580`.

   All of these become neutral core text plus the vendor's hint.
5. **Event strings.** Replace string matching (`CaptureController.swift:452-461`,
   `:552`) with `CaptureEvent` cases. Make Sony's `kind` strings typed
   `ControlEvent`s.
6. **Recording names.** In `SourceRecordingAdapter.swift`, rename
   `appendDeckLinkAudio` and its comments (:6, :23, :89, :143-175, :305-343)
   to the neutral `CaptureAudioPacket` contract.
7. **Sony UI.** The Sony UI goes through a `CameraControlStore` that holds the
   feed's control plugin:
   - `UICameraColumn.swift` `sonyStore`/`sonyChoice`/`sonyCameras`;
   - `UISonyCamera.swift`;
   - `UIFeedSettingsMenu.swift`.

   The Sony-only HDMI display toggle becomes a property the Sony plugin
   exposes.
8. **Settings and Keychain:**
   - Sony's Keychain service `org.ultracam.sony-camera-control.credentials.v1`
     is kept as-is: the Sony plugin declares it as its service name, so saved
     logins survive.
   - Feed assignments move to a dictionary keyed by plugin, with a one-time
     migration from the current Sony keys.
   - Both get a test in `SettingsChecks`. That test needs
     `SonyCameraStore.swift` and `SonyCameraCredentials.swift` added to
     `test.sh`'s explicit file list (`:60-80`).

## Testing

- **Vendor tests stay in the vendor folder**: `BackendTestSupport.inc`
  synthetic SDK checks, `DeckLinkChecks*.swift`, `SonyControlChecks`.
  `test.sh` runs every plugin's tests from its manifest.
- **Fake plugins.** `Sources/DeviceAPI/FakeCapturePlugin.swift` and
  `FakeControlPlugin.swift` provide an explicit synthetic AppHardware fixture:
  devices that come and go on command, and IOSurface-backed 4K v210
  test-pattern frames at 59.94 with embedded audio and timecode. UIVerify and
  MonitorAppIntegration move onto them. Test windows stay invisible, as now.
  Fakes are test-target sources or are compiled behind an explicit test-only
  condition; their CPU pattern writer is never shipped in a Release app.
- **Conformance suite.** `Tests/DeviceAPIConformance.swift` runs against any
  capture plugin. It checks that:
  - repeated start with the same configuration and repeated stop are
    idempotent; changed/stopped starts follow the lifecycle table;
  - no callback runs after `stop()` returns;
  - deliveries are serialized, sequence numbers are monotonic, and
    `formatChanged` precedes the first matching frame;
  - frames are IOSurface-backed and carry colour attachments;
  - presentation times rise within a continuous clock segment; a reset is
    preceded by discontinuity;
  - frame-before-audio order holds for paired packets, even after a rejected
    frame; unpaired packets do not reuse a stale pairing;
  - frames match the last declared format; non-nil expectedFormat matches the
    initial format, while automatic format changes are allowed;
  - device IDs carry the plugin prefix;
  - the plugin reports device loss separately from core admission and
    downstream queue loss.

  The fake plugin passes it in `test.sh`. DeckLink passes it through its
  synthetic SDK harness.
- **Behaviour parity in step 1.** Run the existing `CaptureController`,
  recording and end-to-end checks unchanged. Add adapter-specific checks to
  prove event, meter and timecode translation; unchanged controller tests do
  not exercise the new adapter by themselves.
  Include media-only delivery with raw audio disabled, packet gaps and
  unpaired media. Assert exact packet timestamp/clock preservation and the
  resulting audio-gap and switcher timing behavior.

- **Control preparation parity in step 3.** With empty discovery, the manual
  endpoint path resolves a camera and its identity/fingerprint through the
  generic store, then follows the existing credential/pin checks. Cover failed
  resolution, expected-identity mismatch, a changed saved fingerprint, cancelled
  preparation and Sony's mixed-connection restriction.

- **Race and availability checks.** The conformance suite also runs a
  concurrent stop/callback harness, hot-plug arrival/removal, repeated start,
  missing-SDK status, one failed plugin alongside one healthy plugin, exclusive
  device contention, and unpaired audio. A synthetic test that only emits
  frames cannot prove the quiescence and ordering contract.

## Risks for future vendors

- **UVC can see the app's own output.**
  - `AllowScreenCaptureDevices` is turned on process-wide in three places:
    `CameraSink.swift:203`, `CameraDemandMonitor.swift:96` and
    `VirtualCameraRegistryTransport.swift:66`.
  - So AVFoundation lists Ultracam's own virtual cameras, and capturing one
    would loop Program back into itself.
  - The UVC plugin must drop devices whose unique ID starts with
    `org.ultracam.camera.device` (`VirtualCameraRegistry.swift:51-57`) or
    whose manufacturer is "Ultracam" (`CameraProvider.swift:208`).
  - It should hide other virtual cameras (OBS, Continuity Camera) by default
    too.
- **Webcam timing** is variable-rate and stamps the start of the frame (see
  SOURCE_FORMAT_PLAN.md section 4, and the host-time rule).
- **Separate audio devices** have no frame to pair with (SOURCE_FORMAT_PLAN.md section 7, clock domains).
- **Devices shared with other apps.** A webcam in use by another app may
  refuse to start or change format underneath us. That should surface as
  `unsupportedInput` or `signalLost`, not as a fatal error.

## Sequencing

**Each step:**
- builds;
- passes `scripts/test.sh`;
- is committed on main before the next.

**Checks and parallel work:**
- UI checks (`STRICT=1 bash scripts/ui-verify.sh`) run only on steps that
  touch UI files.
- Andrew checks live capture once at the end of Part A, and after the Part B
  steps listed in its plan.
- Steps that edit the same build scripts or the same core files never run in
  parallel.

0. **Gate on the work in flight.**
   - Record the baseline commit and a path-ownership manifest before starting;
     do not rely on a changing worktree count or an ephemeral agent listing.
   - The current worktree includes the Sony control code, and changes to
     `CaptureController`, `LUTProcessor`, `VideoContract`,
     `VideoBufferLayout`, `CameraProvider` and `generate_project.py`.
   - Step 1 starts only once the baseline is committed and no other session
     owns these paths. A clean-worktree check records the commit hash in the
     step log.
1. **Contract types and DeviceAPI behind the existing seams, no files moved.**
   - Add `Sources/Shared/SourceFormat.swift` (the value types, plus a format
     table holding today's single format) and `Sources/DeviceAPI/`
     (protocols, `VendorRegistry`, `DeviceAPI.h`).
   - Add DeviceAPI to app/test builds and SourceFormat to shared/extension
     builds in all applicable build-table entries, including both monitor
     scripts. Explicitly list the adapter in `test.sh`, which does not glob all
     App Swift files.
   - `DeviceAPI.h` defines `static NSString *const
     UltracamCaptureHostTimeAttachmentKey = @"UltracamCaptureHostTime";` in
     the header, replacing the definition at `UltracamBackend.mm:80`. That
     way no new `.m` file is needed in any build.
   - Wrap `UltracamBackend` in `DeckLinkCapturePlugin.swift`. Until step 4 it
     lives in `Sources/App/`, which the app source glob already picks up;
     native files remain in `Sources/DeckLinkBackend/` until the move.
   - Build `CaptureServices.live` and `AppHardware.live` from the registry,
     with routing by device ID.
   - The adapter fans out to the existing closures, and maps events back to
     today's strings.
   - `DeviceDiagnostics` replaces the ObjC type.
   - Add `FakeCapturePlugin` and `FakeControlPlugin` fixtures for selected
     UIVerify and MonitorAppIntegration scenarios. They are excluded from
     Release app sources or guarded by a test-only compilation condition.
   - Preserve production behavior while changing test fixtures explicitly.
     Keep `.offline` as a no-device/non-emitting option; synthetic streaming is
     opt-in, with a fake camera sink and registry publisher.
   - Add the initial conformance harness now: ordering, retained-buffer lifetime,
     stop races, partial availability and adapter event/audio/timecode parity.
     Existing controller tests alone do not exercise the new live adapter.
   - Compile the slice strictly before accepting it. Run strict UI verification
     and both monitor integration build paths; compare callback cost and loss
     counters to baseline. Step 7 expands this suite.
2. **Strict concurrency in `test.sh`.**
   - Add `-strict-concurrency=complete -warnings-as-errors`, and fix what it
     finds in `Tests/` and the shared sources.
   - Compile the DeviceAPI fake and DeckLink adapter under these flags before
     accepting the protocol as stable. `Tests/` has never been checked
     strictly, so the remaining fixes stay in this separate step.
3. **Split Sony from the DeckLink translation unit.**
   - `SonyCameraControl.inc` becomes `SonyCameraControl.mm`.
   - The same commit updates every affected compile/link entry point:
     `test.sh`, `ui-verify.sh`, `monitor-app-integration.sh`,
     `monitor-feed-host-checks.sh`, `sony-control-checks.sh`,
     `sony-hardware-smoke.sh`, `sony-sandbox-ui-check.sh` and
     `generate_project.py`. The monitor scripts must compile/link a separate
     Sony object after it leaves the backend translation unit; Sony scripts
     must stop compiling the renamed `.inc` path.
   - Update `Tools/SonyControlChecks/Native.mm` and `Hardware.mm` as needed;
     internal tests that include the implementation compile exactly one copy.
     Audit the full build table for header paths and source-list dependencies.
   - Add `SonyControlPlugin` and a `CameraControlStore` over the existing
     `SonyCameraStore` logic, including typed manual-endpoint preparation and
     its parity checks.
   - Add the settings migration and the Keychain continuity test.
   - Verify the strict app/UI build, tests and both monitor build paths in this
     commit. Compile/link Sony hardware and sandbox tools without connecting
     to hardware; add build-only modes where necessary. Run software Sony
     checks in SDK-present and SDK-absent configurations as applicable.
   - Step 4 replaces this working explicit configuration with manifests; no
     broken build entry point is deferred to that step.
   - It shares build scripts with steps 1 and 2, so it runs after them.
4. **Move into `Vendors/`, and make the build manifest-driven, in one commit.**
   - Add the `vendor.json` files, `scripts/vendors.py` and the generated
     bridging header.
   - Every row of the build table reads the manifests, replacing step 1's
     direct edits. Add schema validation, canonical generation checks and the
     Xcode stale-input guard. Regenerate the project.
   - Rename `UltracamBackend` to `DeckLinkBackend` (ObjC `UCDeckLinkBackend`).
   - Move the DeckLink SDK to `Vendors/Blackmagic/SDK`, and update the
     `DECKLINK_SDK_DIR` defaults and `prepare_local_build.py`.
5. **Typed events, and closing the leaks.**
   - `CaptureController` consumes `CaptureEvent` directly.
   - `CaptureServices` collapses to one `start`.
   - Fix leaks 2-7 and verify step 3's leak 8 migration. Leak 1 is done in
     step 1; Sony's typed events arrive in step 3.
   - Complete the ownership map and queue inventory. Resolve unbounded queue
     paths with separately tested overload policies. Vendor wording in Part B
     section 14 also becomes neutral before Part A's boundary lint is required;
     format-only wording can wait for B8.
   - Work may be split by disjoint path ownership:
     - **UI and settings:** leaks 2, 3, 7, and leak 4 outside the controller.
       Owns `UI*.swift`, `AppModel.swift`, `AppSettingsStore.swift` and
       `CameraControlStore.swift`, plus lifecycle/context callers in the
       ownership map, including `MonitorWorkspaceView` and `UltracamApp`.
     - **Controller and recording:** leaks 5 and 6, and leak 4's
       `CaptureController.swift` strings. Owns `CaptureController.swift` and
       `SourceRecordingAdapter.swift`.
   - Leak 2 (per-device EDID HDR and its migration) is owned here, not in Part
     B.
6. **SDK tooling and bundle checks.**
   - `scripts/vendor-sdk.py install|verify|status` replaces
     `fetch-decklink-sdk.sh` and `install-sony-sdk.py`, with thin wrappers
     for a while.
   - `build.sh` prints each plugin's SDK version, or why it is unavailable.
   - `validate_bundle.py` checks in every build that:
     - available plugin dylibs are present, have the expected architecture and
       install names, and non-system dependencies resolve inside the app or to
       declared externally installed drivers. System frameworks are allowed;
       runtime-loaded adapter libraries are checked as well as Mach-O links;
     - no vendor dylib is in the camera extension;
     - every entitlement and plist capability an available plugin owns is
       present.
   - Signature checks run for signed builds; unsigned builds still validate
     layout and dependencies. Notarization is a distribution gate after signing
     and submission, not a prerequisite for a local Release build.
   - Implement `ULTRACAM_WORK_ROOT` in one shared path helper, migrate build
     scripts and verify a clean clone without `/Volumes/8TB` mounted.
   - Add Apache-2.0 `LICENSE`, `NOTICE` and `THIRD_PARTY_LICENSES.md`; record
     Sony redistribution evidence before enabling official release jobs.
7. **Expand conformance, require boundary lint, and write `docs/PLUGINS.md`.**
   - CI requires manifest validation, canonical generation diff, SDK-present/
     absent builds, target isolation and signed/unsigned bundle checks.
   - Extend step 1's conformance harness to Sony lifecycle races and the full
     ownership/migration map.

   The guide for outside developers covers:

   - the two kinds of plugin and the video rules;
   - the threading contract and the manifest format;
   - SDK policy and the conformance suite;
   - what Part B does and doesn't support yet.

That completes Part A. Part B ([SOURCE_FORMAT_PLAN.md](SOURCE_FORMAT_PLAN.md))
fits around it:
- **B0** (pure bug fixes) can land at any time, even before step 1.
- **B1** starts after step 5:
  - it needs the backend on its final path and name (step 4);
  - it needs `CaptureController` consuming `CaptureEvent` and the format
    directly (step 5). Before that, the adapter still maps everything back
    onto today's eight closures and strings, which carry no `SourceFormat`.
- **Steps 6-7 and B1-B9** may interleave. Only one step at a time owns
  `CaptureController.swift` and `DeckLinkBackend.mm`.

Then comes the first new vendor: UVC, after B1-B6 (decision 6).
- **AJA** fits today's single 4K 10-bit format, so it could prove the capture
  API earlier. It needs AJA hardware.
- **UVC** needs no SDK and no special hardware, but needs B1-B6: size, rate,
  colour, the `420v`/`2vuy` formats, and separate-device audio.

Whichever comes first, expect it to force small API fixes. Make them before
anyone outside builds on the API.

## Decisions

Decided on 2026-10-26:
- Part B is in scope and covers every hard-coded assumption.
- CPU conversion is an opt-in compatibility setting, off by default.
- Interlaced signals are not supported.

Part B's other decisions are in [SOURCE_FORMAT_PLAN.md](SOURCE_FORMAT_PLAN.md):
VFR, Program rate conversion, aspect and audio-only takes.

### Decided on 2026-10-26 (confirmed by Andrew)

1. **Isolation: one module plus a boundary-check script.**
   - It works with today's build, where `test.sh` and `ui-verify.sh` compile
     everything in one `swiftc` call.
   - The check catches known forbidden references and vendor-name leaks with
     narrow allowlists. It is organizational lint, not compiler isolation.
   - Swift packages per plugin can come later, once the API has settled. That
     still requires access-control, resource and build-script work; the current
     single-module build does not prove the move will be mechanical.
2. **Folder: top-level `Vendors/<Vendor>/`.** The SDK, code, tests and README
   live together. New vendors also update the registry and generated project;
   shared API changes remain explicit.
3. **Sony in releases.**
   - **Official releases ship with Sony control.** The signed app embeds
     Sony's libraries, as it does today.
   - **A release can't be built without it.** A signed release build
     (`build.sh --signed` with Release configuration) refuses to run if any
     required first-party SDK is missing. The validator receives this explicit
     policy; it cannot infer it from SDK availability. Unsigned local Release
     builds retain SDK-absent support.
   - **Source builds by others still work.** Without the SDK installed, Sony
     control shows as unavailable with the reason, because the public repo
     can't contain Sony's SDK files.
   - **Before the first public release**, confirm that Sony's SDK licence
     allows including its runtime libraries in a downloadable app. Nothing in
     the repo records those terms.
   - `build.sh` prints each plugin's status in every build.
4. **Licence: Apache-2.0** (MIT is the simpler alternative).
   - Add a `NOTICE` and `THIRD_PARTY_LICENSES.md` naming the committed
     DeckLink headers (with their licence blocks) and the SDKs a release
     embeds.
   - The app links vendor SDKs that aren't open source: Sony, and later NDI
     and possibly AJA.
   - Under GPL, distributing those builds would need a linking exception.
   - Apache-2.0 adds a patent grant, which suits a codebase that others
     extend with plugins.
5. **Build location: one `ULTRACAM_WORK_ROOT` environment variable.**
   - It defaults to `.build/` inside the checkout.
   - It replaces build-path dependencies on `/Volumes/8TB` under `scripts/`
     and `Tools/` through one shared helper. Sample UI paths remain fixtures.
   - On this Mac, set it to the external drive to keep today's behaviour.
6. **First new vendor: UVC, after B1-B6.**
   - Anyone can test it with any webcam, and it needs no SDK.
   - It exercises the parts of the API that DeckLink can't: a different
     format and clock, separate-device audio, and VFR.
   - AJA comes when there's hardware to test on.
