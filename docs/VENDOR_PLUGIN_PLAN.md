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
  `SonySLog` and `SonyARRIStyleFalseColor` (`MonitorWorkspace.swift`) and the
  gamut list (`UIInspector.swift:16`). They are monitoring maths, not SDK
  integrations.

## Where the code stands

### Seams that already exist

- `CaptureServices` (`CaptureController.swift:1614`) is a closure-based
  injection point. `CaptureServices.live` is the only place that builds an
  `UltracamBackend`.
- `AppHardware` (`AppModel.swift:31`) is the app-level seam. `.offline` is a
  half-built fake used about 15 times by UIVerify and MonitorAppIntegration.
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
  - `:1494-1497` hard-codes the rate;
  - `EmbeddedAudioClockAnchor.place()` rejects any other timescale.
- **Clock:** packet times are on the device's audio clock, not the video
  clock. The app maps them itself. `EmbeddedAudioClockAnchor`
  (`SourceRecordingAdapter.swift:343-430`) pairs each packet with the frame
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

`Sources/DeviceAPI/` holds:
- the Swift protocols and value types;
- one C header, `DeviceAPI.h`, for the constants that ObjC++ plugins write.
  `UltracamCaptureHostTimeAttachmentKey` moves there. The single-module build
  generates no `-Swift.h`, so native code can't see Swift constants.

Plugins depend on DeviceAPI and on system frameworks. The rest of the app
depends on DeviceAPI and never names a plugin type.

### Capture source

```swift
protocol CaptureSourcePlugin: Sendable {
  static var descriptor: VendorDescriptor { get }   // id "decklink", name, badge, SDK status
  func driverStatus() -> DriverStatus                // installed / supported / user-facing message
  func devices() throws -> [CaptureDeviceInfo]       // id "<plugin>:<anything>"
  func observeDevices(_ handler: @escaping @MainActor @Sendable ([CaptureDeviceInfo]) -> Void)
    -> DeviceObservation
  func makeSession() -> any CaptureSession           // one per feed, own control queue
  func diagnostics(deviceID: String) -> DeviceDiagnostics?
  var settings: [VendorSetting] { get }              // e.g. DeckLink "Advertise HDR to cameras"
}

protocol CaptureSession: AnyObject, Sendable {
  /// The format this session will deliver, known before the first frame,
  /// so the controller can warm the GPU and connect the camera sink
  /// (today's `capturePixelFormat`, `CaptureController.swift:414-417`).
  var nativeFormat: SourceFormat { get }
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
  case waitingForSignal, signalLost(reason: String), unsupportedInput(String),
       formatChanged(SourceFormat), fatal(String), info(String)
}
```

**Value types:**
- `CaptureFrameInfo` carries a `Timecode` struct: hours, minutes, seconds,
  frames, a drop-frame flag, and the rate. It is tied to its frame and
  replaces the string.
- `SourceFormat`, `FrameRate`, `Colorimetry`, `SourceAudioFormat` and
  `Timecode` are defined in [SOURCE_FORMAT_PLAN.md](SOURCE_FORMAT_PLAN.md):
  size, scan, pixel format, colour, exact rate and audio format with its
  clock domain.
- `CaptureAudioPacket` gives interleaved PCM, its `SourceAudioFormat`, and the
  packet time in that format's clock domain.
- `CaptureTiming` is `.automatic` (follow the source's mode) or
  `.fixed(SourceFormat)`. Until B3, the DeckLink plugin maps `.fixed` onto
  today's `inputFast` flag.

**Event wording:** the core turns events into user text, worded neutrally
("Waiting for signal…"). Plugins add vendor hints through
`VendorDescriptor.signalHint`, such as "Check the FX3 HDMI output and selected
frame rate."

**Collapsing the start variants:** this API replaces the eight
`start`/`startAuto` overloads in `UltracamBackend.h` at the plugin boundary.
At first, `CaptureServices.live` adapts one session onto the existing eight
`CaptureServices` closures, and maps `CaptureEvent` back onto today's
strings. `CaptureController` (which branches on which closures are set,
`:416-510`) and its tests stay unchanged until step 4. Live capture keeps the
source-audio path, so meters and timecode behave exactly as now.

**Routing:** `AppHardware.captureServices` is built per feed, not per device
(`AppModel.swift:403-404`). A feed that switches from a DeckLink input to
another vendor's device keeps the same services. So the live services resolve
the plugin from the device ID at each `start` and build a session from that
plugin, rather than fixing a plugin when the feed is created.

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
  static var descriptor: VendorDescriptor { get }
  func discover() async throws -> [ControlCamera]    // stable id (Sony: MAC), name, address
  func prepare(_ camera: ControlCamera) async throws -> PairingRequirement
  func connect(feedID: String, camera: ControlCamera, credentials: ControlCredentials?) async throws
  func properties(feedID: String) async throws -> [ControlProperty]   // id, label, value, options, writable
  func set(_ property: ControlProperty.ID, value: ControlValue, feedID: String) async throws
  func disconnect(feedID: String) async
  func shutdown() async -> String?
  func credentialAccount(for camera: ControlCamera, fingerprint: String) throws -> String
  var events: AsyncStream<ControlEvent> { get }      // typed: changed, disconnected, error
}
```

This mirrors `UCSonyCameraControl` and `SonyCameraStore`, which are already
feed-keyed.

**What the core keeps:**
- feed assignment persistence, keyed by plugin ID;
- Keychain storage, with the service name `org.ultracam.<plugin>.credentials.v1`;
- fingerprint pinning;
- the reconnect-once-at-launch rule;
- a generic property panel.

**What the plugin supplies:**
- **The Keychain account string.** Sony's scheme
  (`SonyCameraCredentials.swift:37-50`) requires a 12-hex-digit MAC, and
  another vendor's IDs won't fit it.
- **Its own SwiftUI view**, optionally, for anything the generic panel can't
  show.

### Shared types

- **`VendorDescriptor`**: ID, display name, badge text ("SONY",
  "BLACKMAGIC"), signal hint, SDK version, and whether the SDK is present. It
  replaces the `Brand` enum (`UIFeedSettingsMenu.swift:104`) and the name
  sniffing.
  - Plugin IDs are permanent. They are stored in device IDs, settings and
    Keychain service names.
- **`DeviceDiagnostics`**: the common counters (drops, backlog, temperature,
  signal, host time mapped) plus `[(label, value)]` vendor sections. It
  replaces `UltracamDeviceDiagnostics` in the app.
- **`DriverStatus`**: one per plugin. The single `driverWarning` string
  (`AppModel.swift:35`, `:534`) becomes a list.
- **`VendorRegistry.swift`**: a hard-coded array of plugin types, and the only
  file that names them all.
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
- **No CPU pixel path at all.** Every Mac Ultracam runs on is Apple Silicon
  (arm64 only, macOS 26), with a GPU and unified memory. So there is no CPU
  fallback, not even a counted one. A format without a GPU route is refused
  at admission, and a check script fails on any CPU pixel access. See "GPU
  only, with no CPU fallback" in [SOURCE_FORMAT_PLAN.md](SOURCE_FORMAT_PLAN.md).
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

The plugin API above carries these types: `CaptureSession.nativeFormat` is a
`SourceFormat`, and `CaptureAudioPacket` carries a `SourceAudioFormat`. A
plugin written against Part A doesn't change when Part B lands, and Part B
only widens which formats it may declare.

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
two things. The built app embeds Sony's dylibs. The source tree holds Sony's
installer, not Sony's files.

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

**Entitlements:** `disable-library-validation`, the
`com.blackmagic-design.desktopvideo.DeckLinkHardwareXPCService` mach-lookup
exception and the Desktop Video preferences exception belong to DeckLink. The
manifest records each owner, and a check fails if `App.entitlements` lacks
one. Entitlements are checked, never written automatically.

`scripts/vendors.py` reads the manifests. Every build entry point uses it:

| File | Hard-coded today |
|---|---|
| `scripts/generate_project.py` | `sony_root`/`sony_available` (:17-18), the `Sources/DeckLinkBackend` glob (:37), the bridging header (:139), link flags (:143-145), the inline Sony block (:146-170) |
| `scripts/test.sh` | backend `.mm` (:47), `DeckLinkAPIDispatch.cpp` (:50), the bridging header (:57), the explicit Swift file list (:60-80), link flags (:82) |
| `scripts/ui-verify.sh` | backend `.mm` (:51), dispatch `.cpp` (:53), the depth-1 source `find` (:58), the bridging header (:64) |
| `scripts/ui-typecheck.sh` | DeckLink SDK dir and bridging header (:18-23), source glob (:24) |
| `scripts/sony-control-checks.sh` | `.inc` and header paths (:9-18) |
| `scripts/sony-hardware-smoke.sh`, `sony-sandbox-ui-check.sh`, `monitor-app-integration.sh`, `monitor-feed-host-checks.sh` | backend and Sony paths |
| `Tools/SonyControlChecks/Native.mm`, `Hardware.mm`, `main.swift` | relative `#include` of the `.inc` and the Sony header |

**Bridging header:** it becomes generated. It imports `DeviceAPI.h`, each
plugin's single public ObjC header, and `Tools/auto-switcher/include/auto_switcher.h`
(today's `BridgingHeader.h:3`). This keeps the single-module build every script
uses.

Per-plugin module maps or Swift packages would have the compiler enforce
isolation, at the cost of reworking `test.sh` and `ui-verify.sh`, which
compile everything in one `swiftc` call. For now, a check script enforces the
boundary instead. It fails if:
- app code names a plugin type;
- plugin code reaches past DeviceAPI;
- a source file outside `Vendors/` contains a vendor or product name
  (Blackmagic, UltraStudio, DeckLink, Sony, FX3), with an allowlist for the
  colour-science presets.

**Strict concurrency:** `test.sh:54` builds with `-swift-version 5`, without
`-strict-concurrency=complete` or warnings as errors, so only the Xcode build
checks the new `Sendable` API. Turn both on in `test.sh` when DeviceAPI lands.

**Outside developers:** before the repo goes public, two things block them,
whatever happens to plugins:
- `/Volumes/8TB` is hard-coded in 15 shell scripts and in `generate_project.py`.
  Make the build root an environment variable that defaults to the current
  path.
- There is no `LICENSE` file. Choose a license.

## Leaks to close in the app

1. **Diagnostics type.** `AppHardware.diagnostics` returns the DeckLink ObjC
   type (`AppModel.swift:37`, `:1465`; `UIDiagnostics.swift:237`). Change it
   to `DeviceDiagnostics`.
2. **Advertise HDR.** `AppHardware.setAdvertisesHDR` (`AppModel.swift:40`,
   `:104`, `:392`) is a DeckLink EDID feature. Make it a `VendorSetting` that
   only DeckLink declares, and keep the stored key.
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
   - Both get a test in `SettingsChecks`.

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
  - `nativeFormat` matches the frames delivered.

  The fake plugin passes it in `test.sh`. DeckLink passes it through its
  synthetic SDK harness.
- **Behaviour parity in step 1.** Run the existing `CaptureController`,
  recording and end-to-end checks unchanged. They are the proof that the
  adapter maps events, meters and timecode exactly as before.

## Risks for future vendors

- **UVC can see the app's own output.** `CameraSink.swift:203` turns on
  `AllowScreenCaptureDevices` for the whole process, so AVFoundation lists
  Ultracam's own virtual cameras. Capturing one would loop Program back into
  itself. The UVC plugin must drop devices whose unique ID starts with
  `org.ultracam.camera.device` (`VirtualCameraRegistry.swift:51-57`) or whose
  manufacturer is "Ultracam" (`CameraProvider.swift:208`). It should hide
  other virtual cameras (OBS, Continuity Camera) by default too.
- **Webcam timing** is variable-rate and stamps the start of the frame (see
  SOURCE_FORMAT_PLAN.md section 4, and the host-time rule).
- **Separate audio devices** have no frame to pair with (SOURCE_FORMAT_PLAN.md section 7, clock domains).
- **Devices shared with other apps.** A webcam in use by another app may
  refuse to start or change format underneath us. That should surface as
  `unsupportedInput` or `signalLost`, not as a fatal error.

## Sequencing

Each step builds, passes `scripts/test.sh`, and is committed on main before
the next. UI checks (`STRICT=1 bash scripts/ui-verify.sh`) run only on steps
that touch UI files. Andrew checks live capture once, at the end of Part A,
and again after each Part B format.

0. **Gate on the work in flight.** The tree has 59 uncommitted or untracked
   paths from other sessions, Grok included. They include all of the Sony
   control code and changes to `CaptureController`, `LUTProcessor`,
   `VideoContract`, `VideoBufferLayout`, `CameraProvider` and
   `generate_project.py`. Step 1 starts only once those are committed, and
   ListAgents shows no other session editing these files.
1. **DeviceAPI behind the existing seams, no files moved.**
   - Add the protocols, value types and `DeviceAPI.h`.
   - Wrap `UltracamBackend` in `DeckLinkCapturePlugin`, and build
     `CaptureServices.live` and `AppHardware.live` from the registry, with
     routing by device ID.
   - The adapter fans out to the existing closures and maps events back to
     today's strings.
   - `DeviceDiagnostics` replaces the ObjC type.
   - Turn on strict concurrency in `test.sh`.
   - Behaviour doesn't change.
2. **Split Sony from the DeckLink translation unit.**
   - `SonyCameraControl.inc` becomes its own `.mm`.
   - Add `SonyControlPlugin` and a `CameraControlStore` over the existing
     `SonyCameraStore` logic.
   - Add the settings migration and the Keychain continuity test.
   - Steps 1 and 2 touch disjoint files and can run as parallel subagents.
3. **Move into `Vendors/` and make the build manifest-driven, in one commit.**
   - Add the `vendor.json` files, `scripts/vendors.py` and the generated
     bridging header.
   - Update every row of the build table and regenerate the project.
   - Rename `UltracamBackend` to `DeckLinkBackend` (ObjC `UCDeckLinkBackend`).
   - Move the DeckLink SDK to `Vendors/Blackmagic/SDK`, and update the
     `DECKLINK_SDK_DIR` defaults and `prepare_local_build.py`.
4. **Typed events and closing the leaks.**
   - `CaptureController` consumes `CaptureEvent` directly.
   - `CaptureServices` collapses to one `start`.
   - Fix leaks 1-7.
   - The UI work (leaks 3, 4, 7) and the controller work (leaks 5, 6) can run
     as parallel subagents.
5. **SDK tooling and bundle checks.**
   - `scripts/vendor-sdk.py install|verify|status` replaces
     `fetch-decklink-sdk.sh` and `install-sony-sdk.py`, with thin wrappers
     for a while.
   - `build.sh` prints each plugin's SDK version, or why it is unavailable.
   - `validate_bundle.py` checks that each available plugin's dylibs are
     embedded and signed, that none are in the camera extension, and that
     entitlement owners are present.
6. **Fakes, conformance suite, boundary check, `docs/PLUGINS.md`.** The guide
   for outside developers covers:
   - the two kinds of plugin and the video rules;
   - the threading contract and the manifest format;
   - SDK policy and the conformance suite;
   - what Part B does and doesn't support yet.

That completes Part A. Part B ([SOURCE_FORMAT_PLAN.md](SOURCE_FORMAT_PLAN.md))
fits around it:
- B0 (fix now) can land at any time, even before step 1;
- B1 starts after step 1, once DeviceAPI exists;
- B2-B9 can overlap Part A steps 3-6, as long as each step owns its files.

Then comes the first new vendor:
- **AJA** fits today's single 4K 10-bit format, so it would prove the capture
  API without waiting on Part B. It needs AJA hardware.
- **UVC** needs no SDK and no special hardware, but it needs B1-B6 first:
  size, rate, colour, the `420v`/`2vuy` formats, and separate-device audio.

Whichever comes first, expect it to force small API fixes, and make them
before anyone outside builds on the API.

## Open decisions

Decided on 2026-10-26: Part B is in scope and covers every hard-coded
assumption. Part B's own decisions (VFR, Program rate conversion, aspect,
interlaced, audio-only takes) are in
[SOURCE_FORMAT_PLAN.md](SOURCE_FORMAT_PLAN.md).

1. **Isolation:** one module with a boundary-check script (recommended now),
   or a Swift package per plugin. Packages are enforced by the compiler, but
   they rework `test.sh` and `ui-verify.sh`, and Sony's dylibs would have to
   be wrapped as an xcframework.
2. **Folder location:** top-level `Vendors/` (recommended, because the SDKs
   sit next to the code) or `Sources/Vendors/`.
3. **Release builds without the Sony SDK:** ship with Sony control shown as
   unavailable (as now), or have `build.sh` refuse a release build that is
   missing a plugin's SDK.
4. **Going public:** choose a license, and make the build root configurable.
