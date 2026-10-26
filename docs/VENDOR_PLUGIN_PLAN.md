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
and follows one document.

## Two kinds of plugin

A vendor provides one or both of these. They have unrelated interfaces.

| Kind | Does | Today | Later |
|---|---|---|---|
| **Capture source** | Lists input devices, follows hot-plug, delivers video frames (plus audio and timecode when it has them), reports driver status and diagnostics | Blackmagic DeckLink | UVC (AVFoundation), AJA NTV2, NDI |
| **Camera control** | Finds cameras on the network or over USB/Bluetooth, pairs, reads and sets properties, sends events, attached to one feed | Sony Camera Remote SDK | Canon, Panasonic, Blackmagic cameras (REST/Bluetooth), RED |

Today both live in `Sources/DeckLinkBackend/`. Sony control is not even a
separate translation unit: `UltracamBackend.mm:2871` does
`#include "SonyCameraControl.inc"`. Splitting them is step one of the move.

Not covered by this plan:
- **Program output to hardware** (DeckLink/AJA playout). `UltracamBackend.h`
  has no output methods. It would become a third kind later.
- **Colour-science presets**: `SonySLog` and `SonyARRIStyleFalseColor` in
  `MonitorWorkspace.swift`, and the gamut list in `UIInspector.swift:16`. These
  are monitoring maths, not SDK integrations, and stay in MonitorKit and the
  app.

## What exists already

The seams are mostly there; the work is naming them and closing the leaks.

- `CaptureServices` (`CaptureController.swift:1614`) is already a closure-based
  injection point. `CaptureServices.live` is the only place that builds an
  `UltracamBackend`.
- `AppHardware` (`AppModel.swift:31`) is the app-level seam. `.live` wires
  DeckLink. `.offline` is a half-built fake that UIVerify and
  MonitorAppIntegration already use about 15 times.
- Device IDs are already namespaced: `decklink:00000000a1850ab8`
  (`UIPresentation.swift:333`). Saved feed descriptors need no migration if we
  make `<vendorID>:<stable id>` the rule.
- Sony control is keyed by feed ID, not by capture device (`SonyCameraStore`),
  which is the right shape for any camera-control vendor.
- The GPU pipeline already accepts several formats (`LUTProcessor.swift:863-874`):
  v210 (`422YpCbCr10`), 10-bit 422/420 biplanar, 8-bit 422/420 biplanar.
- The camera extension never links vendor code. It must stay that way.

## The internal API

A new `Sources/DeviceAPI/` holds the protocols and plain value types: Swift
only, no vendor imports. Plugins depend on DeviceAPI and on system frameworks.
The rest of the app depends on DeviceAPI and never on a plugin.

### Capture source

```swift
protocol CaptureSourcePlugin: Sendable {
  static var descriptor: VendorDescriptor { get }   // id "decklink", name, badge, SDK status
  func driverStatus() -> DriverStatus                // installed / supported / user-facing message
  func devices() throws -> [CaptureDeviceInfo]       // id is "<vendor>:<stable id>"
  func observeDevices(_ handler: @escaping @MainActor ([CaptureDeviceInfo]) -> Void) -> DeviceObservation
  func makeSession() -> any CaptureSession           // one per feed, own control queue
  func diagnostics(deviceID: String) -> DeviceDiagnostics?
  var settings: [VendorSetting] { get }              // e.g. DeckLink "Advertise HDR to cameras"
}

protocol CaptureSession: AnyObject, Sendable {
  func start(deviceID: String, timing: CaptureTiming,   // .automatic | .fixed(inputFast:)
             handlers: CaptureHandlers) throws
  func stop()
  var counters: CaptureCounters { get }              // device drops, backlog, max backlog
}

struct CaptureHandlers {
  var frame: (CVPixelBuffer, CaptureFrameTiming, Bool /*signalValid*/) -> Void
  var rawAudio: ((CaptureAudioPacket) -> Void)?      // nil: plugin has no embedded audio
  var timecode: ((String?) -> Void)?
  var event: (CaptureEvent) -> Void
}
```

This replaces the eight `start`/`startAuto` overloads in `UltracamBackend.h`
at the plugin boundary. At first, `CaptureServices.live` adapts one
`any CaptureSession` onto the existing eight `CaptureServices` closures.
`CaptureController` (which branches on which closures are set, at
`CaptureController.swift:416-510`) and its tests stay unchanged. Collapsing
`CaptureServices` itself to one `start` is a separate cleanup after step 3.

The threading rules from `UltracamBackend.h` become the API contract, written
once in DeviceAPI:
- start and stop run on one control queue per session.
- Frame and audio callbacks arrive on the plugin's own thread and must return
  promptly.
- Within one callback, the frame goes before its audio.
- Never call `stop()` from a handler.
- The pixel buffer owns the vendor frame until its last release.

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
  var events: AsyncStream<ControlEvent> { get }
}
```

This mirrors `UCSonyCameraControl` and `SonyCameraStore`, which are already
feed-keyed. The core keeps the vendor-neutral parts:
- feed assignment persistence, keyed by vendor ID;
- Keychain storage;
- fingerprint pinning policy;
- the reconnect-once-at-launch rule;
- a generic property panel.

A plugin can add its own SwiftUI view for anything the generic panel can't show.

### Shared types

- `VendorDescriptor`: ID, display name, short badge text ("SONY",
  "BLACKMAGIC"), SDK version, and whether the SDK is present. It replaces the
  `Brand` enum (`UIFeedSettingsMenu.swift:104`) and the name sniffing.
- `DeviceDiagnostics`: the common counters (drops, backlog, temperature,
  signal, host-time mapped) plus `[(label, value)]` vendor sections. It
  replaces `UltracamDeviceDiagnostics` in the app.
- `CaptureAudioPacket`: interleaved PCM, sample rate, channels, bytes per
  sample, packet time on the video stream clock. Metering stays in the app
  (`AudioMeterTap`). Plugins send raw samples only, so the peak/RMS code in
  `UltracamBackend.mm:624-663` moves out of the vendor code.
- `UltracamCaptureHostTimeAttachmentKey` moves into DeviceAPI as the
  documented way any plugin supplies a hardware arrival time.
- `VendorRegistry.swift`: a hard-coded array of plugin types, the only file
  that names them all. `AppHardware.live` is built from it. With more than one
  capture plugin, the device list is the concatenation of all of them, and a
  feed resolves its plugin from the device ID prefix.

## Video rules every plugin must follow

These come straight from the pipeline requirements and are written into
`docs/PLUGINS.md` as acceptance criteria:

- Every frame is delivered; there is no drop-when-busy. Device-side losses
  show up in `counters`.
- Frames are IOSurface-backed CVPixelBuffers that Metal can use without a
  copy. The plugin owns the allocation: DeckLink's default allocator already
  does this. An AJA plugin would DMA into IOSurface-backed buffers it
  allocates. UVC frames from AVFoundation are already IOSurface-backed.
- No CPU pixel conversion. A plugin declares its native formats. If a format
  has no shader path yet, the plugin's PR adds the shader path. Today's gap is
  packed 8-bit 4:2:2 (`2vuy`, common on UVC). The UVC plugin can ask
  AVFoundation for `420v`, which the pipeline already takes, or add a `2vuy`
  kernel.
- Timing comes from the source: presentation time and actual duration from
  the device clock, never from a user-chosen rate.

## Folder layout and SDKs

```text
Vendors/
  Blackmagic/
    vendor.json              # id, kinds, SDK pin, build settings (below)
    README.md                # what it supports, SDK version, license note, how to update
    Sources/                 # DeckLinkCapturePlugin.swift + DeckLinkBackend.mm/.h + .inc
    SDK/include/             # DeckLink SDK 16.0 headers, license blocks intact (committed)
    Tests/                   # DeckLinkChecks*.swift, BackendTestSupport.inc
  Sony/
    vendor.json
    README.md
    Sources/                 # SonyControlPlugin.swift, SonyCameraControl.mm/.h, discovery
    SDK/                     # gitignored; filled by install script from the developer's own download
    Tests/                   # SonyControlChecks
    UI/                      # optional: UISonyCamera.swift extras the generic panel can't show
Sources/DeviceAPI/           # protocols, value types, registry, fake plugins
```

There are two SDK policies, and `vendor.json` states which one applies:

- **Redistributable** (DeckLink headers): the SDK is committed under
  `SDK/`. `vendor.json` records the version and a checksum.
  `scripts/vendor-sdk.py verify blackmagic` replaces the version check in
  `fetch-decklink-sdk.sh`. To update, replace `SDK/include`, bump the version,
  and run verify.
- **Local install** (Sony): the SDK is never committed or fetched.
  `scripts/vendor-sdk.py install sony <zip>` generalizes
  `install-sony-sdk.py`. It checks the archive layout and records the
  installed version in a gitignored stamp. Without the SDK, the plugin builds
  as "unavailable", like `ULTRACAM_SONY_SDK` does today, and the app explains
  why.
- **No SDK** (UVC): system frameworks only.
- **AJA NTV2**: check libajantv2's license for the exact release before
  committing it under `SDK/`.

Because the Sony SDK can't go in a public repo, "bundled with its SDK" means
two things. The built app embeds Sony's dylibs, as it does now. The source
tree holds Sony's installer, not Sony's files.

## Build system

`vendor.json` holds everything the build scripts now hard-code per vendor:
- source files;
- header search paths;
- libraries and frameworks;
- preprocessor defines;
- dylibs to embed, with their subfolders (Sony's `CrAdapter/`);
- the "SDK available" predicate;
- the Info.plist keys and entitlements the plugin needs.

The entitlements are checked, never auto-written: Sony needs local network
access.

A small `scripts/vendors.py` reads every manifest. Each build entry point
consumes it instead of its own copy of the paths:

| File | Hard-coded today |
|---|---|
| `scripts/generate_project.py` | `sony_root`/`sony_available` (:17-18), the `Sources/DeckLinkBackend` glob (:37), the bridging header path (:139), the inline Sony block (:146-170) |
| `scripts/test.sh` | backend `.mm` compile (:47), bridging header (:57) |
| `scripts/ui-verify.sh` | backend `.mm` compile (:51), bridging header (:64) |
| `scripts/ui-typecheck.sh` | bridging header, DeckLink SDK dir (:18-23) |
| `scripts/sony-control-checks.sh` | `.inc` and header paths (:9-18) |
| `Tools/SonyControlChecks/Native.mm` | relative `#include` of the `.inc` (:2) |

The bridging header becomes generated: `Sources/DeviceAPI/VendorBridgingHeader.h`
imports each plugin's one public ObjC header. That keeps the single-module
build every script uses today. Per-plugin Clang module maps or Swift packages
would give compiler-enforced isolation at the cost of reworking `test.sh` and
`ui-verify.sh`, which compile everything in one `swiftc` call. For now, a
check script enforces the boundary instead: it fails if app code names a
plugin type, or if plugin code reaches past DeviceAPI.

## Leaks to close in the app

1. `AppHardware.diagnostics` returns the DeckLink ObjC type:
   `AppModel.swift:37`, `AppModel.swift:1465`, `UIDiagnostics.swift:237`.
   Change it to `DeviceDiagnostics`.
2. `AppHardware.setAdvertisesHDR` (`AppModel.swift:40`, `:104`, `:392`) is a
   DeckLink EDID feature. Make it a `VendorSetting` the DeckLink plugin
   declares. Settings show it only when that plugin is present, and the
   stored key stays the same.
3. Brand detection by matching device names, at `UICameraColumn.swift:725` and
   `UIFeedSettingsMenu.swift:64-66`. Replace it with the feed's
   `VendorDescriptor`.
4. Vendor copy:
   - "Choose the Blackmagic capture device" (`UIInspector.swift:105`) becomes
     "Choose the capture device".
   - The "Blackmagic input" fallback name (`UIPresentation.swift:346`) comes
     from the vendor's display name.
   - "Blackmagic input detected…" (`UIFeedSettingsMenu.swift:36`) becomes a
     vendor-supplied hint.
5. `SourceRecordingAdapter.swift`: rename `appendDeckLinkAudio` and its
   comments (:6, :23, :89, :143-175, :305-343) to the neutral
   `CaptureAudioPacket` contract. Audio is optional. A UVC camera's audio is a
   separate Core Audio device, so the recorder must take "no embedded audio"
   as normal.
6. Sony UI (`UICameraColumn.swift` `sonyStore`/`sonyChoice`/`sonyCameras`,
   `UISonyCamera.swift`, `UIFeedSettingsMenu.swift`) goes through a
   `CameraControlStore` that holds the feed's control plugin. The Sony-only
   HDMI-display toggle becomes a property the Sony plugin exposes.
7. Settings and Keychain: keep the Sony Keychain service
   `org.ultracam.sony-camera-control.credentials.v1` unchanged, so saved
   logins survive. Move feed assignments to a vendor-keyed dictionary, with a
   one-time migration from the current Sony keys. Add a test to
   `SettingsChecks`.

## Testing

- Vendor tests stay in the vendor folder: `BackendTestSupport.inc` synthetic
  SDK checks, `DeckLinkChecks*.swift`, `SonyControlChecks`. `test.sh` runs
  every plugin's tests from its manifest.
- `Sources/DeviceAPI/FakeCapturePlugin.swift` and `FakeControlPlugin.swift`
  turn `AppHardware.offline` into a real plugin: devices that come and go on
  command, and IOSurface-backed test-pattern frames at a set rate. UIVerify
  and MonitorAppIntegration move onto it. Test windows stay invisible, as now.
- A conformance suite in `Tests/DeviceAPIConformance.swift` runs against any
  capture plugin with synthetic or real hardware. It checks:
  - start/stop are idempotent;
  - no callbacks after `stop()` returns;
  - frames are IOSurface-backed;
  - presentation times rise monotonically;
  - frame-before-audio order holds within a callback;
  - device IDs carry the vendor prefix.

  The fake plugin passes it in CI. DeckLink passes it through its synthetic
  SDK harness.

## Sequencing

Each step builds, passes `scripts/test.sh`, and is committed on main before
the next. UI checks (`STRICT=1 bash scripts/ui-verify.sh`) run only on steps
that touch UI files.

0. **Land the Sony work first.** The Sony control code is all uncommitted in
   the working tree right now, and another session appears to own it. Moving
   it mid-flight would collide. Coordinate, and start step 1 only once it is
   committed.
1. **DeviceAPI behind the existing seams, no files moved.** Add the protocols
   and value types. Wrap `UltracamBackend` in `DeckLinkCapturePlugin`, and
   build `CaptureServices.live` and `AppHardware.live` from the registry.
   The adapter fans one `start` out to the existing closures, so
   `CaptureController` is untouched. `DeviceDiagnostics` replaces the ObjC
   type in the app. Behavior doesn't change.
2. **Split Sony from the DeckLink translation unit.** Make
   `SonyCameraControl.inc` its own `.mm`. Add `SonyControlPlugin` and a
   `CameraControlStore` over the existing `SonyCameraStore` logic, with the
   settings migration and Keychain continuity test.
3. **Move into `Vendors/` and make the build manifest-driven, in one commit.**
   Add `vendor.json` files, `scripts/vendors.py` and the generated bridging
   header. Update every row of the build table above and regenerate the
   project. Rename `UltracamBackend` to `DeckLinkBackend` (ObjC
   `UCDeckLinkBackend`). Move the DeckLink SDK to `Vendors/Blackmagic/SDK`,
   and update `DECKLINK_SDK_DIR` defaults and `prepare_local_build.py`.
4. **Close the UI leaks** (items 3-6 above). Brand badges, copy and the
   Settings "Advertise HDR" row all come from the plugin.
5. **SDK tooling.** Add `scripts/vendor-sdk.py install|verify|status`, which
   replaces `fetch-decklink-sdk.sh` and `install-sony-sdk.py` and keeps thin
   wrappers for a while. `build.sh` prints each plugin's SDK version, or why
   it is unavailable. `validate_bundle.py` checks that each available
   plugin's dylibs are embedded and signed, and that none are in the camera
   extension.
6. **Fakes, conformance suite, boundary check, `docs/PLUGINS.md`.** The guide
   for outside developers: the two kinds, the video rules, the manifest
   format, SDK policy, threading contract, and how to run the conformance
   suite.
7. **Proof with a second capture vendor: UVC.** Add it once steps 1-6 are in.
   It needs no SDK and needs no hardware beyond any webcam. It shows whether
   the API is really vendor-neutral, because audio is a separate device, it
   has a different pixel format, and its timing comes from AVFoundation.
   Expect it to force small API fixes, and make them before anyone outside
   builds on the API.

## Open decisions

- **Isolation:** one module with a boundary-check script (recommended now),
  or a Swift package per plugin (enforced by the compiler, but it reworks
  `test.sh` and `ui-verify.sh`, and needs Sony's dylibs wrapped as an
  xcframework).
- **Folder location:** top-level `Vendors/` (recommended, because the SDKs
  live next to the code) or `Sources/Vendors/`.
- **Release builds without the Sony SDK:** ship with Sony control shown as
  unavailable (as today), or make `build.sh` refuse a release build that is
  missing a plugin's SDK.
