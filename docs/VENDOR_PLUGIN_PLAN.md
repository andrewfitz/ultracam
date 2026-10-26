# Vendor plugin plan

## Goal

Move Blackmagic and Sony out of the app's core and into self-contained vendor
plugins that talk to the app through one internal API. Later, the same API
should take UVC, AJA, Canon, Panasonic, RED or Blackmagic camera control
without any change to the core.

"Plugin" here means a folder in the repo, compiled into the app and listed in
one registry file. There is no dlopen, no loadable bundles and no third-party
binaries at run time. Each plugin folder carries its vendor SDK, or the script
that installs the SDK when its license forbids redistribution. Updating an SDK
then touches only that folder, and a developer adding a vendor copies a folder
and follows one guide.

The plan has two parts, and they are separate projects:
- **Part A** is the plugin boundary: the API, the folders, the build, and
  closing the leaks.
- **Part B** opens the video pipeline to sources other than 4K 10-bit 4:2:2,
  which Part A doesn't do.

A new capture vendor that doesn't deliver exactly today's format needs both.

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
  - `GPUIngest`, the core's GPU-upload service for SDKs that return frames in
    ordinary memory;
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
  func observeDevices(_ handler: @escaping @MainActor @Sendable ([CaptureDeviceInfo]) -> Void)
    -> DeviceObservation
  /// What `start` will deliver, if known before the first frame, so the
  /// controller can warm the GPU and connect the camera sink (today's
  /// `capturePixelFormat`, `CaptureController.swift:414-417`). Nil with
  /// `.automatic` timing until the source is detected.
  func expectedFormat(deviceID: String, timing: CaptureTiming) -> SourceFormat?
  func makeSession() -> any CaptureSession           // one per start, own control queue
  func diagnostics(deviceID: String) -> DeviceDiagnostics?
  func settings(deviceID: String) -> [VendorSetting] // per device: EDID HDR, connector, …
  func apply(_ value: VendorSettingValue, to setting: VendorSetting.ID, deviceID: String)
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
  var frame: @Sendable (CVPixelBuffer, CaptureFrameInfo) -> Void   // pts, duration, signalValid, timecode
  var media: (@Sendable (CaptureMediaStats) -> Void)?              // meters + presence, per callback
  var rawAudio: (@Sendable (CaptureAudioPacket) -> Void)?          // nil: no embedded audio
  var event: @Sendable (CaptureEvent) -> Void
}

enum CaptureEvent: Sendable {
  case formatChanged(SourceFormat)   // required before the first frame of each format
  case waitingForSignal, signalLost(reason: String), unsupportedInput(String),
       fatal(String), info(String)
}
```

**Value types:**
- `CaptureFrameInfo` carries the frame's `Timecode` struct, replacing the
  `HH:MM:SS;FF` string.
- `CaptureAudioPacket` gives the PCM, its `SourceAudioFormat`, and the packet
  time in that format's clock domain.
- `CaptureTiming` is `.automatic` (follow the source's mode) or
  `.fixed(SourceFormat)`. Until B3, the DeckLink plugin maps `.fixed` onto
  today's `inputFast` flag.
- **CPU-memory SDKs** (NDI) still hand the core a `CVPixelBuffer`. The plugin
  passes its raw frame to `GPUIngest`, which uploads on the GPU into an
  IOSurface pool and returns the buffer. Plugins never touch Metal
  themselves.

**Device settings and capabilities:**
- Part B's needs are in the API from the start: shareable and pausable
  sources, connectors, supported-modes text, and per-device settings. A
  plugin written against Part A only gains new enum cases and table entries
  when Part B lands.

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

### Threading contract

Written once in DeviceAPI, taken from `UltracamBackend.h`:
- start and stop run on one control queue per session;
- frame, media and audio callbacks arrive on the plugin's thread and return
  promptly, without allocating on the heap per frame;
- within one source callback, the frame goes before its media stats and audio;
- never call `stop()` from a handler, and no callback runs after `stop()`
  returns;
- the pixel buffer owns the vendor frame until its last release.

### Camera control

```swift
protocol CameraControlPlugin: Sendable {
  var descriptor: VendorDescriptor { get }
  /// Keychain service; Sony returns its existing
  /// "org.ultracam.sony-camera-control.credentials.v1" so saved logins survive.
  var credentialService: String { get }
  func credentialAccount(for camera: ControlCamera, fingerprint: String) throws -> String
  func discover() async throws -> [ControlCamera]    // stable id (Sony: MAC), name, address
  func prepare(_ camera: ControlCamera) async throws -> PairingRequirement
  func connect(feedID: String, camera: ControlCamera, credentials: ControlCredentials?) async throws
  func properties(feedID: String) async throws -> [ControlProperty]   // id, label, value, options, writable
  func set(_ property: ControlProperty.ID, value: ControlValue, feedID: String) async throws
  func disconnect(feedID: String) async
  func shutdown() async -> String?
  /// Events for every feed, delivered on the main actor in the order the
  /// plugin produced them, interleaved correctly with replies (a disconnect
  /// never overtakes a reconnect reply, as `SonyCameraStore.swift:112-114`
  /// relies on today). One handler, set once by the core.
  func setEventHandler(_ handler: @escaping @MainActor @Sendable (ControlEvent) -> Void)
}
// ControlEvent carries its feedID: .changed, .disconnected, .error(message)
```

This mirrors `UCSonyCameraControl` and `SonyCameraStore`, which are already
feed-keyed.

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
- **`VendorRegistry.swift`** holds `static let capture: [any
  CaptureSourcePlugin]` and `static let control: [any CameraControlPlugin]`.
  These are instances, built once. It is the only file that names every
  plugin.
  - `AppHardware.live` is built from it.
  - The device list is the concatenation of every capture plugin's devices.
  - The input picker groups devices by vendor when there is more than one
    vendor.
- **`DeviceAPI.version`**: an integer plus `docs/PLUGINS.md` changelog
  entries. The compiler catches breaks in bundled plugins, so the version is
  for outside forks to see what changed.

## Video rules every plugin must follow

These come straight from the pipeline requirements. `docs/PLUGINS.md` makes
them acceptance criteria:

- **Every frame.** Every frame is delivered; there is no drop-when-busy.
  Device-side losses show up in `counters`.
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
  duration or documents the offset.
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

Part B widens the format table and adds enum cases, so a plugin written
against Part A only gains options.

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
- Ultracam's released app embeds Sony's dylibs, and release builds require
  them (decision 3).
- The source tree holds Sony's installer, not Sony's files.

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

**Link flags:** `-lz`, `-liconv` and the Security and SystemConfiguration
frameworks (`generate_project.py:143-145`, `test.sh:82`) are Sony's
dependencies, not the app's.

**Entitlements and plist keys:** every one gets a named owner, recorded in
the manifests or as "core":
- **DeckLink:** `disable-library-validation`, the
  `com.blackmagic-design.desktopvideo.DeckLinkHardwareXPCService` mach-lookup
  exception, and the Desktop Video preferences exception.
- **Sony:** `network.client` and `network.server`, and
  `NSLocalNetworkUsageDescription`. NDI will share the last two.
- **Core:**
  - `keychain-access-groups` (used by every camera-control plugin);
  - `device.camera`;
  - the app group;
  - system-extension install.

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

**Bridging header:** it becomes generated. It imports `DeviceAPI.h`, each
plugin's single public ObjC header, and `Tools/auto-switcher/include/auto_switcher.h`
(today's `BridgingHeader.h:3`). This keeps the single-module build every script
uses.

Per-plugin module maps or Swift packages would have the compiler enforce
isolation, at the cost of reworking `test.sh` and `ui-verify.sh`, which
compile everything in one `swiftc` call. For now, a check script enforces the
boundary instead. It fails if:
- app code names a plugin type;
- plugin code reaches past DeviceAPI and Shared;
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

**Strict concurrency:** `ui-verify.sh:60` and `ui-typecheck.sh:20` already
build with `-strict-concurrency=complete -warnings-as-errors`, and so does
Xcode. The gap is `test.sh:54`, the only build of `Tests/` and the camera
extension sources outside Xcode. `Tests/` has never been checked strictly, so
turning it on is its own step (step 2), not part of a "no behaviour change"
step.

**Outside developers:** before the repo goes public, two things block them,
whatever happens to plugins:
- `/Volumes/8TB` is hard-coded in 20 files under `scripts/` and `Tools/`.
  Make the build root an environment variable (decision 5).
- There is no `LICENSE` file. Choose a license.

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
  `FakeControlPlugin.swift` turn `AppHardware.offline` into real plugins:
  devices that come and go on command, and IOSurface-backed 4K v210
  test-pattern frames at 59.94 with embedded audio and timecode. UIVerify and
  MonitorAppIntegration move onto them. Test windows stay invisible, as now.
- **Conformance suite.** `Tests/DeviceAPIConformance.swift` runs against any
  capture plugin. It checks that:
  - start and stop are idempotent;
  - no callback runs after `stop()` returns;
  - frames are IOSurface-backed and carry colour attachments;
  - presentation times rise monotonically;
  - frame-before-audio order holds;
  - device IDs carry the plugin prefix;
  - a `formatChanged` event precedes the first frame of each format, and the frames match it and `expectedFormat`.

  The fake plugin passes it in `test.sh`. DeckLink passes it through its
  synthetic SDK harness.
- **Behaviour parity in step 1.** Run the existing `CaptureController`,
  recording and end-to-end checks unchanged. They are the proof that the
  adapter maps events, meters and timecode exactly as before.

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
   - The tree has 85 uncommitted or untracked paths from other sessions, Grok
     included.
   - They include all of the Sony control code, and changes to
     `CaptureController`, `LUTProcessor`, `VideoContract`,
     `VideoBufferLayout`, `CameraProvider` and `generate_project.py`.
   - Step 1 starts only once those are committed, and ListAgents shows no
     other session editing these files.
1. **Contract types and DeviceAPI behind the existing seams, no files moved.**
   - Add `Sources/Shared/SourceFormat.swift` (the value types, plus a format
     table holding today's single format) and `Sources/DeviceAPI/`
     (protocols, `VendorRegistry`, `DeviceAPI.h`).
   - Add both to `generate_project.py` (app glob and the extension's list),
     `test.sh`, `ui-verify.sh`, `ui-typecheck.sh` and
     `monitor-app-integration.sh`.
   - `DeviceAPI.h` defines `static NSString *const
     UltracamCaptureHostTimeAttachmentKey = @"UltracamCaptureHostTime";` in
     the header, replacing the definition at `UltracamBackend.mm:80`. That
     way no new `.m` file is needed in any build.
   - Wrap `UltracamBackend` in `DeckLinkCapturePlugin.swift`. Until step 4 it
     lives in `Sources/App/`, the only folder every build already picks up
     (`generate_project.py:37` takes only `.h/.mm/.inc` from
     `Sources/DeckLinkBackend`).
   - Build `CaptureServices.live` and `AppHardware.live` from the registry,
     with routing by device ID.
   - The adapter fans out to the existing closures, and maps events back to
     today's strings.
   - `DeviceDiagnostics` replaces the ObjC type.
   - `FakeCapturePlugin` and `FakeControlPlugin` replace `AppHardware.offline`
     (UIVerify and MonitorAppIntegration move to them).
   - Behaviour doesn't change. It touches UIVerify, so run
     `STRICT=1 bash scripts/ui-verify.sh` too.
2. **Strict concurrency in `test.sh`.**
   - Add `-strict-concurrency=complete -warnings-as-errors`, and fix what it
     finds in `Tests/` and the shared sources.
   - It's on its own because `Tests/` has never been checked strictly.
3. **Split Sony from the DeckLink translation unit.**
   - `SonyCameraControl.inc` becomes `SonyCameraControl.mm`.
   - The same commit updates its compile in `test.sh:47`, `ui-verify.sh:51`,
     `sony-control-checks.sh:9` and `Tools/SonyControlChecks/Native.mm:2`/
     `Hardware.mm:2`, and adds it to `generate_project.py`.
   - Add `SonyControlPlugin` and a `CameraControlStore` over the existing
     `SonyCameraStore` logic.
   - Add the settings migration and the Keychain continuity test.
   - It shares build scripts with steps 1 and 2, so it runs after them.
4. **Move into `Vendors/`, and make the build manifest-driven, in one commit.**
   - Add the `vendor.json` files, `scripts/vendors.py` and the generated
     bridging header.
   - Every row of the build table reads the manifests, which replaces step
     1's direct edits. Regenerate the project.
   - Rename `UltracamBackend` to `DeckLinkBackend` (ObjC `UCDeckLinkBackend`).
   - Move the DeckLink SDK to `Vendors/Blackmagic/SDK`, and update the
     `DECKLINK_SDK_DIR` defaults and `prepare_local_build.py`.
5. **Typed events, and closing the leaks.**
   - `CaptureController` consumes `CaptureEvent` directly.
   - `CaptureServices` collapses to one `start`.
   - Fix leaks 2-7. Leak 1 is done in step 1, and Sony's typed events arrive
     with step 3's `CameraControlStore`.
   - Two parallel subagents, with disjoint files:
     - **UI and settings:** leaks 2, 3, 7, and leak 4 outside the controller.
       Owns `UI*.swift`, `AppModel.swift`, `AppSettingsStore.swift` and
       `SonyCameraStore.swift`.
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
   - `validate_bundle.py` checks that:
     - each available plugin's dylibs are embedded and signed;
     - none are in the camera extension;
     - every entitlement and plist key an available plugin owns is present.
7. **Conformance suite, boundary check, and `docs/PLUGINS.md`.** The guide for
   outside developers covers:
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
   - The check fails on app code naming a plugin type, on plugin code reaching
     past DeviceAPI, and on vendor names outside `Vendors/`.
   - Swift packages per plugin can come later, once the API has settled.
     Moving then is mechanical, because DeviceAPI is already the only shared
     surface.
2. **Folder: top-level `Vendors/<Vendor>/`.** The SDK, code, tests and README
   live together, so an SDK update or a new vendor touches one folder.
3. **Sony in releases.**
   - **Official releases ship with Sony control.** The signed app embeds
     Sony's libraries, as it does today.
   - **A release can't be built without it.** A signed release build
     (`build.sh` in release mode) refuses to run if any first-party plugin's
     SDK is missing. `validate_bundle.py` fails if the Sony libraries are
     absent from a release bundle.
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
   - It replaces `/Volumes/8TB` in the 20 files under `scripts/` and
     `Tools/`.
   - On this Mac, set it to the external drive to keep today's behaviour.
6. **First new vendor: UVC, after B1-B6.**
   - Anyone can test it with any webcam, and it needs no SDK.
   - It exercises the parts of the API that DeckLink can't: a different
     format and clock, separate-device audio, and VFR.
   - AJA comes when there's hardware to test on.
