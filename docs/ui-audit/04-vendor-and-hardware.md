# Audit 04: vendor and hardware awareness

Date: 2026-10-30. Read-only audit of the tree at commit `30c8d73`. No build was run, no capture device was opened, and no setting was read from the installed app.

Evidence labels used below:

- **Verified:** read in this repo's code or in the SDK headers under `Vendors/*/SDK/include`.
- **Measured:** seen on this Mac today with `system_profiler SPThunderboltDataType SPUSBDataType`.
- **Memory:** project notes from earlier sessions, not re-tested today.
- **Outside:** my knowledge of the products, not proven here.

File references are relative to the repo root. `Sources/App/` and `Vendors/Blackmagic/Sources/` are shortened where the context is clear.

## Decisions at a glance

| Question | Decision |
|---|---|
| Home for hardware | A new **Devices** tab in Settings, between Camera and Switcher. It lists every capture device and camera body, grouped by vendor, including expected hardware that is absent. |
| Pairing | Pairing moves from the Camera Control sheet to Devices. The sheet stays for operating a connected body. |
| Main window | One **source row** in each expanded strip names both links in the chain. Otherwise the window stays calm: hardware appears only as exceptions, through the existing warning segment. |
| Inspector | Source section gains connector and link. Camera Control becomes an inline status block. |
| Plugin API | Yes, it needs additions: an idle-readable device status, typed facts and problems, a semantic tag on control properties, a control vendor snapshot, and a plugin-supplied missing-device hint. |
| Rig presets | Not now. Everything a preset would hold already persists. Show "expected but absent" hardware instead. |

## Corrections to the brief

These change the design, so they come first.

1. **There is no UltraStudio 4K Mini on this Mac today.** Measured: `system_profiler` lists two **UltraStudio Mini Recorder 12G** units. Project memory agrees. The string "UltraStudio 4K Mini" appears in this repo as UI fixture data (`Sources/App/UIContext.swift:150-151`). So the same-model duplicate case is this rig, not an edge case.
2. **Both units currently sit behind the OWC hub.** Measured: both are direct children of the OWC Thunderbolt 5 Hub, at 40 Gb/s, firmware 68.1, on the same Mac port. Memory says one was direct and one on the hub, so the wiring has changed or the note is stale. An ANYOYO TB501Pro is on the same hub. `system_profiler SPUSBHostDataType` also lists two Blackmagic entries, "DMC Device", vendor `0x1edb`, product `0xbf0f`, at 12 Mb/s, under the hub's USB 2 side. Product `0xbf0f` matches the units' Thunderbolt device ID, so these look like the healthy units' management endpoints, not a USB fallback. No Sony device is on USB. (`SPUSBDataType` prints nothing on this macOS version, so use the Host variant.)
3. **A lead on the 2026-10-30 simultaneous drop.** Both units lost signal within 11 ms (memory). If the wiring today matches the wiring that day, the hub is a concrete shared component. This is a lead only. The units flagged "no input", which is the HDMI side, and the logs showed nothing on Thunderbolt. Each unit needs about 11 Gb/s at 4K59.94 v210, so bandwidth on the 80 Gb/s uplink is not the obvious cause. Check whether the wiring was the same on that day.
4. **An "HDMI · USB 3 link" chip cannot work.** Memory: a unit that falls back to USB 3 never gets a PCIe device, so DeckLink never lists it. `BMDDeckLinkDeviceInterface` can report USB only for a device the driver can see, and this one it can't. The real symptom is a saved input that is simply missing. The design treats it that way (see "The USB 3 fallback" in section 4).
5. **Fixture text.** The inspector's "does not report supported formats" is fixture text, as the brief expected. The real DeckLink string is worse in a different way: `3840 × 2160, 1001/60000 s` (`DeckLinkCapturePlugin.swift:413`), a raw frame duration shown to the user.

---

## 1. What the app knows today, and where it surfaces

### The data flow

Every plugin fact passes through one narrow point.

```
CaptureSourcePlugin               VendorRegistry                AppHardware               UI
 descriptor ─────────────┐        CaptureVendorSnapshot         devices() ─► [InputDevice]
 driverStatus() ─────────┼──────► (descriptor, status,    ───►  driverWarning() ─► String?
 devices() ──────────────┘         devices, error)              captureDescriptor(id)
 diagnostics(deviceID:) ────────────────────────────────────►   diagnostics(id) ─► Diagnostics window
 settings(deviceID:) ───────────────────────────────────────►   settingsPlugins() ─► Settings > Advanced

CameraControlPlugin
 discover / prepare / connect ─► CameraControlStore (per feed) ─► 640×690 sheet
 properties ────────────────────► CameraControlFeedState ───────► sheet, badge menu, optional overlay
```

`VendorRegistry.snapshot` has the right shape (`Sources/DeviceAPI/VendorRegistry.swift:3-12`), but `AppHardware.registry` flattens it into a list of IDs and names plus one warning string (`Sources/App/AppHardware.swift:86-101`). Control plugins are not in the snapshot at all. **The app has vendor data, but nothing holds an inventory.**

### What the app knows, and where it shows

| Knowledge | Held in | Where a person sees it | Gap |
|---|---|---|---|
| Vendor name | `VendorDescriptor.displayName` | Input picker group title, only with more than one capture vendor (`UIContext.swift:26-28`). With one vendor it never shows. | Vendor is invisible as text on this rig. |
| Vendor logo | `badgeAssetName` | One mark in the strip header (`UICameraColumn.swift:722-724`) | `feedBrand` returns Sony if assigned, else the capture vendor (`:739-744`). **Assigning a Sony body hides the Blackmagic mark.** Collapsed strips show neither. |
| `badgeText`, `signalHint` | `VendorDescriptor` | `badgeText` is only a fallback for a missing logo (`UIControlPresentation.swift:6-9`). `localizedSignalHint` has no caller. | Dead field. |
| SDK version | `VendorDescriptor.sdkVersion` | Nowhere. No reader in `Sources/App`. | Dead field. |
| SDK present | `sdkPresent` | Only inside the sheet (`UICameraControl.swift:59-60`). `CameraControlStore.available` (`:103`) has no caller. | SDK-absent builds still show Camera Control. |
| Driver installed/supported/reason | `DriverStatus` | `driverWarning`, a string (`AppHardware.swift:90-97`), shown in the Diagnostics Device section (`UIDiagnostics.swift:251`) and start refusal text (`AppModel.swift:1275-1276`). | Start is disabled when no device is listed (`AppModel.swift:1213-1216`), so in practice only Diagnostics shows why. The picture says "No input selected" or "Input disconnected". |
| Driver version | `DriverStatus.version` | Not read from there. Appears as "Driver version" among vendor fields in Diagnostics, per camera. | No global place. |
| Device ID | `CaptureDeviceInfo.id` | Last 4 hex digits when two names collide (`UIPresentation.swift:348-358`); full ID in Diagnostics. | Good base. See below on names. |
| Device name | `CaptureDeviceInfo.name` | Input picker, strip tooltip, badge menu, placeholders | `lastInputNames` is memory-only (`AppModel.swift:256, 518`). After a relaunch with the unit unplugged, the label falls back to `missingLabel`'s "Input device · ICEA" form, the path `main-live-model-dark.png` renders from fixture data. |
| Connectors | `CaptureDeviceInfo.connectors` | **Nowhere.** Set at `DeckLinkCapturePlugin.swift:412`, dropped by `InputDevice.init` (`AppHardware.swift:14-16`). No reader anywhere. | Dead field. |
| Selected connector | `VendorSetting` | Settings > Advanced only | The strip and inspector never say HDMI or SDI. |
| Supported modes | `supportedModes` string | Inspector, always expanded | Raw durations. It is the `DoesSupportVideoMode` subset for the selected connector (`DeckLinkBackend.mm:296-320`). |
| Detected signal | `CaptureUpdate.sourceFormat` | Badge ("2160p 59.94"); Diagnostics has the full detail | **Inspector invents part of it:** `"\(format) · 4:2:2"` is hardcoded (`UIInspector.swift:341`) though the plugin negotiates RGB formats too (`DeckLinkCapturePlugin.swift:231`). |
| Signal presence, temperature, backlog | Session stats | Diagnostics, per camera, while that device has run | Sampled only in a session (`DeckLinkBackend.mm:2623-2640`). An idle device shows "—". |
| In use by another app | `bmdDeviceCaptureBusy` | An error string after pressing Start (`DeckLinkBackend.mm:2293-2295`) | Never shown in advance. |
| Hot-plug | `IDeckLinkDiscovery` | Input list updates live (`AppModel.swift:486-489`) | Good. |
| Sony discovered list | `CameraControlStore.cameras` | Sheet only, and only after a scan | No list outside the sheet. |
| Sony assignment | `assignments[plugin][feed]` | Inspector caption (`UIInspector.swift:36-38`), sheet | Strip shows only the logo. |
| Sony connection state | `CameraControlFeedState.connected` | Inspector caption, sheet, and the badge menu's "Control camera disconnected" | **A dropped body raises no warning.** The optional overlay just disappears (`UICameraControl.swift:234`). `warning()` has no control input (`UIPresentation.swift:817-848`). There is no retry loop by design (`docs/SONY_CONTROL.md:129-131`), so it stays down silently. |
| Sony sign-in saved | `hasSavedCredentials` | Sheet only | Fine there, but belongs in Devices. |
| Sony properties | `ControlProperty` list | Sheet grid; `outputTiming` in the badge menu; overlay if enabled | Battery reaches only the sheet. It's in no overlay list (`SonyControlPlugin.swift:292`). |
| Assignment persistence failure | `discoveryMessages["persistence"]` | **Nowhere.** The sheet reads only `discoveryMessages[pluginID]` (`UICameraControl.swift:171`). | Silent failure. |

### Diagnostics today

`UIDiagnostics.swift:245-271` shows the device block per Ultracam camera, so a device assigned to no camera has no diagnostics at all. Defects in that block:

- "Signal" appears twice: as a vendor field (`DeckLinkCapturePlugin.swift:457`) and as `signalPresent` (`UIDiagnostics.swift:256-258`).
- "HDMI dynamic range" is the EDID advertisement, not the signal (`DeckLinkBackend.mm:1673`). The label misleads.
- "Captured audio channels" reads 2 when idle, a default rather than a measurement (`:1666`).
- "Host capture clock: Unavailable" shows a warning on a stopped device (`UIDiagnostics.swift:263`).

`UIDiagnosticsText.summary` (`UISettings.swift:777-806`), the text a person pastes for support, contains **no hardware at all**: no driver, model, device ID, link, vendor or Sony state.

### `scripts/diagnose-capture.py`

Read, not run. `devices` compiles a small probe that reads PersistentID, signal lock, busy, detected mode, flags, colorspace, PCIe width and generation, and temperature, then parses `system_profiler` for Thunderbolt link and firmware. Those facts are what the app should know. Today they live in a developer script.

Two notes:

- The probe's comments show these reads need no open input. The script can't run on a machine with no developer tools, and it never reaches the app.
- It reads the detected mode with `GetInt` (`:231`), but the backend says SDK 16 returns it as an interface (`DeckLinkBackend.mm:1960-1965`). That line may print nothing on a 16.x driver. Verify when someone next runs it.

### State is passed as text

`DeckLinkCaptureSession.event` classifies native messages by substring (`DeckLinkCapturePlugin.swift:301-308`). They then become message strings, and `UIFormatLabels.signal` parses them again for "no hdmi" and "no video signal" (`UISessionBridge.swift:73-80`). The typed `CaptureEvent` already exists one layer down (`CaptureController.swift:1619-1633`). Native strings also say "UltraStudio HDMI input" while selecting SDI (`DeckLinkBackend.mm:2309`). Plugin text may name a vendor, but it should not name the wrong connector.

---

## 2. What the hardware can report

"Backend" means the native bridge reads it. "UI" means a person can see it.

### Blackmagic

Headers are `Vendors/Blackmagic/SDK/include/`, SDK 16.0.

| Item | Source | Backend | UI | Status |
|---|---|---|---|---|
| Display name | `IDeckLink::GetDisplayName`; `BMDDeckLinkDisplayName` `DeckLinkAPI.h:657` | Yes `.mm:1721` | Yes | Verified |
| Model name, vendor name | `BMDDeckLinkModelName :658`, `BMDDeckLinkVendorName :656` | No | No | Verified. The comment at `AppHardware.swift:5` calls `name` the model, but it is the display name. |
| Persistent ID | `BMDDeckLinkPersistentID :620` | Yes `.mm:245` | Suffix | Verified. Stability across ports is Outside. |
| Topological ID, device group | `:621-622` | No | No | Verified. No use needed yet. |
| Connection type | `BMDDeckLinkDeviceInterface :629`, values PCI/USB/Thunderbolt `:422-424` | No | No | Verified |
| PCIe width, generation | `bmdDeckLinkStatusPCIExpressLinkWidth/Speed :719-720` | Script only `:234-235` | No | Verified. Memory saw x4 Gen3 on these units. |
| Thunderbolt link rate | Not in the SDK | Script, via `system_profiler` `:274-279` | No | Measured: 40 Gb/s on both. Needs IORegistry in the app. |
| Firmware | **No header mentions firmware** (grep over all 49 files) | Script only | No | Verified absent from SDK. `system_profiler` shows 68.1 on both units; whether that is the device or Thunderbolt firmware is unproven. |
| Driver version | `BMDDeckLinkAPIVersion :673` | Yes `.mm:1269` | Diagnostics | Verified. Memory: Desktop Video 16.4. |
| Driver/firmware match | No SDK call | No | No | Outside: Desktop Video Setup prompts for this. Ultracam can't detect it, so it should not claim to. |
| Serial number, label | `bmdDeckLinkConfigDeviceInformationSerialNumber/Label`, `DeckLinkAPIConfiguration.h:231-232` | No | No | Verified in headers. Whether these units populate them is unknown. Memory: both report placeholder USB serial `123456`, so do not trust a serial without a hardware check. |
| Busy (capture, playback, serial) | `bmdDeckLinkStatusBusy :724`, flags `:813-815` | At start and settings only | Error text | Verified |
| Input connectors | `BMDDeckLinkVideoInputConnections :624`, config `Configuration.h:134` | Yes | Advanced only | Verified |
| Audio connections | `:626`, config `Configuration.h:168` | Forced to embedded | No | Verified |
| Signal lock | `bmdDeckLinkStatusVideoInputSignalLocked :738` | Logged only `.mm:2600-2604` | No (session flag in Diagnostics) | Verified |
| Detected mode, format flags, field dominance | `:704, :711-712` | Yes | Badge, Diagnostics | Verified |
| Bit depth, 4:2:2 vs 4:4:4 | `bmdDetectedVideoInput* :222-227` | Yes | Diagnostics; inspector hardcodes 4:2:2 | Verified |
| Colorimetry, dynamic range | `:713-714` | Yes | Diagnostics | Verified |
| HDR mastering metadata | `bmdDeckLinkFrameMetadataHDR* :477-497` | EOTF and colorspace only `.mm:1116-1121` | Transfer only | Verified. MaxCLL, primaries and luminance unread. |
| HDMI input FRL rate | `bmdDeckLinkStatusHDMIInputFRLRate :728` | No | No | Verified. Relevant to marginal 18 Gb/s cables, though applicability to these units is unknown. |
| Embedded audio channels | `BMDDeckLinkMaximumHDMIAudioChannels :614`, `MaximumAudioChannels :613` | Yes, enables 2/8/16 | Diagnostics | Verified |
| Reference / genlock | `BMDDeckLinkHasReferenceInput :584`, status `:722-723, :740`, values `:253-255` | No | No | Verified. Outside: these recorders likely have no reference input, so show only if `HasReferenceInput`. |
| Temperature | `bmdDeckLinkStatisticDeviceTemperature :685` | Session only `.mm:2637-2639` | Diagnostics | Verified. Memory: 67–69 °C idle. |
| Vendor settings | Connector, EDID | Yes | Advanced | Verified. Conversion mode (`Configuration.h:136`) and pass-through (`:141`) are not exposed and need not be. |

Of the rows that need the app to do something, the highest value are connection type, model name, idle signal lock, idle busy, and PCIe link. All are verified in headers and cheap to read.

### Sony

Headers are `Vendors/Sony/SDK/include/`. The fields read today are the table at `SonyCameraControl.mm:32-63`.

**Header presence does not prove FX3 support.** The per-model table is in Sony's API reference, which isn't in this repo. The bridge already filters on `IsGetEnableCurrentValue` (`.mm:605`), so an unsupported property is omitted rather than shown wrong. Every "Header only" row needs a check against a live FX3.

| Item | Source | Bridge | UI | Status |
|---|---|---|---|---|
| Model | `GetModel`, `ICrCameraObjectInfo.h:18`; SSDP `x_modelname` | Read, then dropped. `ControlCamera.name` takes the friendly name (`SonyControlPlugin.swift:281`). | Friendly name only | Verified |
| Firmware | `CrDeviceProperty_SoftwareVersion`, `CrDeviceProperty.h:750` | No | No | Header only. `docs/SONY_CONTROL.md:257` records 7.02 from an SSDP check, not in the app. |
| Connection path | `GetConnectionTypeName`, `GetAdaptorName` `:31-32`; `CreateCameraObjectInfoUSBConnection`, `CameraRemote_SDK.h:65` | Hardcoded `.network` (`SonyControlPlugin.swift:282`). `prepare` refuses other transports (`:73`). | Wi-Fi icon | Verified. USB exists in the SDK, unused. |
| Pairing, credentials state | `authenticationMode`, `fingerprint`, `hasSavedCredentials` | Yes | Sheet | Verified |
| Recording format | `Movie_File_Format :80`, `Movie_Recording_Setting :81`, `ResolutionForMain :127` | No | No | Header only |
| Recording frame rate | `Movie_Recording_FrameRateSetting :82` | Yes | Badge menu, sheet | Verified |
| Shooting mode | `ExposureProgramMode :43` read. `MovieShootingMode :132`, `ColorGamut :133`, `TargetDisplay :134`, `LogShootingMode :584-585`, `CameraOperatingMode :793` are not. | Partly | Sheet | Verified / Header only |
| Shutter, ISO, WB, iris | Read at `.mm:32-40`; `actualISO` too | Yes | Sheet, overlay | Verified |
| Exposure index, base ISO | Read at `.mm:57-58` | Yes | Sheet | Verified |
| Picture profile, gamma | `PictureProfile :218`, `_Gamma :220`, `CreativeLook :245` | No | No | Header only. Needed for the colour cross-check. |
| Media slots | `MediaSLOT1/2_Status`, `RemainingTime`, `RemainingNumber :675-683`; `WritingState :786-787`; `RecordingAvailableType :789-790` | No | No | Header only |
| Battery | `BatteryRemain :669` read. `BatteryLevel :670`, `RemainingInMinutes :724`, `InVoltage :725`, `DCVoltage :726`, `TotalBattery* :830-831`, `PowerSource :131` are not. | Partly | Sheet only | Verified / Header only |
| Body recording state | `RecordingState :672` | Yes | Sheet only | Verified |
| HDMI output | Resolution, 4K timing, RAW rate, display read (`.mm:44-48`). `RecMedia :272`, `RAW :275`, `ColorGamutForRAWOut :277`, `TimeCode :278`, `RecControl :279`, `AudioCH :282` are not. | Partly | Sheet, badge menu | Verified / Header only |
| Timecode | `TimeCodePreset/Format/Run/Make :205-208` | No | No | Header only |
| Tally | `TallyLampControlRed/Green/Yellow :567-569`, enum `:5329` | No | No | Header only. FX3 support is unknown and Ultracam's tally is on-screen. |
| Overheating, errors | `DeviceOverheatingState :766`, `CameraErrorCautionStatus :812` | No | No | Header only. High value on an FX3 running for hours (Outside). |
| Lens | `LensModelName :772`, `LensVersionNumber :765`, `LensSerialNumber :878` | No | No | Header only |
| Warnings | `OnWarning`, `OnWarningExt`, `IDeviceCallback.h:31-33`; `CrWarning_Connect_Reconnecting`, `File_StorageFull`, `NetworkErrorOccurred`, `CrError.h:190-196` | **Not overridden** (`.mm:363-392`) | No | Verified: dropped. |
| SDK version | `GetSDKVersion`, `CameraRemote_SDK.h:150` | Yes `.mm:539` | No | Verified. Manifest pins 2.2.0. |

`GetDeviceProperties` copies Sony's local list without contacting the body (`docs/SONY_CONTROL.md:107-108`), so reading more fields adds no traffic. Adding a field to `sonyFields` also subscribes it to change refresh (`.mm:391`). Exclude any field that ticks constantly, such as remaining time while recording, the way focus telemetry is excluded (`:391-392`).

---

## 3. How a person connects hardware today

### Connecting a Sony body to an Ultracam camera

Before the app: enable Remote Shoot Function on the body, put the Mac and body on one Wi-Fi network, and allow the macOS Local Network prompt (`docs/SONY_CONTROL.md:3-15`).

1. **Find the control.** It has three entry points and two names (Camera Control, Open camera settings…):
   - The expanded strip's **Camera Control** row (`UICameraColumn.swift:664-671`). A collapsed strip doesn't have it. ⋯ has no entry either, except Show Inspector.
   - **Inspector > Camera Control** (`UIInspector.swift:33-41`). Open with ⌥⌘I, the toolbar, or ⋯ > Show Inspector.
   - The status-badge menu, but **only after a camera is already assigned** (`UIFeedSettingsMenu.swift:19-34`). Unassigned, it shows "Output timing is controlled by the source" and stops (`:35`). That is a dead end at the moment a person is looking for this.
2. **Click Camera Control.** A 640×690 sheet opens (`UICameraControl.swift:77`). A 2.5-second scan runs if the 30-second cache is stale (`:86`).
3. **Choose the body** from the pop-up "Choose a camera" (`:152-155`). It auto-selects only if exactly one is found (`:200`), so this rig always needs the step. Friendly names only; the address appears only if names collide (`:203`).
4. If nothing appears: **Rescan**, or open **Add camera by address** and type an IP address, a MAC address, set an authentication toggle, and click **Check Camera** (`:158-170`).
5. Selecting a body checks for a saved sign-in, which runs a fresh discovery (`SonyControlPlugin.swift:65`), so the UI pauses again.
6. **With a saved sign-in:** click **Connect Using Saved Sign-In**. **Without:** type user name and password, then click **Connect and Assign to Camera 1** (`:176-195`).
7. **Pairing check:** nothing. The app can't know which HDMI cable the body feeds, and only the docs say to verify it (`docs/SONY_CONTROL.md:13-14`).
8. Optionally turn on **Show camera settings over this feed**, then **Done**.

That is about six clicks plus typing, per camera. Everything after step 2 is behind a modal sheet with no list of the rig.

Related controls and where they are hidden:

- Disconnect, Reconnect, Unassign and Forget Saved Sign-In are only in the sheet. After a body drops, the only route to Reconnect is reopening the sheet.
- HDMI timing is in the status-badge menu, which looks like a status readout rather than a control.
- The sheet says "feed" in three places (`:103`, `:174`; `CameraControlStore.swift:430`), and the badge tooltip says "Feed settings" (`UIFeedSettingsMenu.swift:44`). Project noun is Camera.
- "Camera" means both an Ultracam camera and a physical body in the same sheet ("Camera Control · Camera 1", "Choose a camera").

### Choosing a Blackmagic input

Automatic on first run: a camera that never had an input takes the first free one (`AppModel.swift:524-529`). To change it:

1. Stop the camera. The picker is disabled while it runs (`UIInspector.swift:112`).
2. Open the inspector and use **Source > Input** (`:98-114`), or the menu bar extra's per-camera **Input** submenu (`UIMenuBar.swift:546-580`). Not available in the strip.
3. Two same-model units show as name plus last four ID digits. Nothing says which physical box that is.

### Blackmagic vendor settings

1. ⌘, then the **Advanced** tab, then scroll past Video compatibility to **Input device settings** (`UISettings.swift:700`). Settings has no search.
2. Each device is a heading with an unstructured list of settings (`UISettingsDeviceSettings.swift:8-37`):
   - **Input connector.** Choices come from the device (`DeckLinkCapturePlugin.swift:345-354`).
   - **Advertise HDR to cameras.** Shown only when the connector is HDMI (`:468`).
3. Rows don't say which Ultracam camera uses the device, or show any health.
4. Under each setting: "Changing this setting may briefly interrupt the input signal." For the connector that is wrong. While capturing the change is **refused** with an error (`DeckLinkBackend.mm:1583`, `:113`), and the control stays enabled.
5. With no devices, it says "Connect an input device to see its settings", even when the driver is missing.

The two settings that decide whether a camera works are three layers from the camera they affect, in the tab named for things most people should never touch.

---

## 4. A proper home

### Principles

- **Two questions, two places.** "Is my rig right?" belongs on the main window as exceptions. "What is my rig?" belongs in Devices.
- **Identity survives absence.** Expected hardware stays listed when unplugged, by last known name.
- **A device is a device before it is assigned.** An idle, unassigned unit has status too.
- **The host renders; the plugin knows.** No vendor names or property IDs in `Sources/App`. `scripts/check-vendor-boundaries.py` already fails on brand words there, so this is enforced.
- **Never call the driver from the UI.** A background reader caches status. The existing rule at `UIDiagnostics.swift:243-244` stays. Nothing touches the frame path.

### Settings > Devices

A new tab, `Label("Devices", systemImage: "cable.connector")`, after Camera. Settings order becomes General, Recording, Camera, Devices, Switcher, Monitor, Advanced. The Advanced "Input device settings" section is removed.

The pane is a grouped form, one section per vendor, in registry order. Each device is a disclosure row. Pro-app precedent is Desktop Video Setup's device list with per-device settings, and ATEM's device list. A nested sheet per device would stack modals on Settings, so rows expand in place.

```
Devices                                                    [Refresh]
2 capture devices · 2 camera bodies · 1 needs attention

BLACKMAGIC DECKLINK          Desktop Video 16.4 · SDK 16.0
▸ ● Left UltraStudio        Camera 1 ▾     HDMI 2160p 59.94      Thunderbolt
▸ ● UltraStudio · 7C31      Camera 2 ▾     HDMI 2160p 59.94      Thunderbolt
▸ ○ UltraStudio · 0AB8      None ▾         Not connected         Last seen today 09:12

SONY                         Wi-Fi control · SDK 2.2.0
▸ ● ILME-FX3:A              Camera 1 ▾     Connected · 78%
▸ ▲ ILME-FX3:B              Camera 2 ▾     Disconnected          [Reconnect]
  [Find Camera Bodies]  [Add by Address…]
```

Device IDs here are illustrative.

Row anatomy, left to right: health dot, name, assignment pop-up, one-line state, link. Health is shape plus colour, since colour alone fails accessibility: filled dot healthy, hollow dot absent, triangle attention.

Expanded capture device:

```
▾ ● Left UltraStudio
    Name           [Left UltraStudio        ]   Rename stays on this Mac
    Model          UltraStudio Mini Recorder 12G
    Connection     Thunderbolt · PCIe x4 Gen3
    Connector      [HDMI ▾]                      Stop Camera 1 to change
    Signal         2160p 59.94 · 10-bit 4:2:2 · Rec.709 · 2 ch audio
    Temperature    68 °C
    Signal history 4 dropouts today · last 13:59:04, with Camera 2
    Advertise HDR to cameras    [ ]              Briefly interrupts HDMI
    Device ID      decklink:…                    (selectable text)
```

Expanded camera body:

```
▾ ● ILME-FX3:A
    Model          ILME-FX3 · firmware 7.02
    Connection     Wi-Fi · connected 2 h ago
    Sign-in        Saved in Keychain   [Forget…]
    Picture        Sent by the capture device on Camera 1: confirm on set
    Power          Battery 78%
    Media          Slot 1 OK · Slot 2 empty
    [Camera Settings…]  [Disconnect]  [Unassign]
```

Pairing moves here:

- **Find Camera Bodies** runs discovery. The bodies appear as rows immediately. No sheet.
- The assignment pop-up is the pairing control. Choosing **Camera 1** on a row calls the existing `connect(camera:to:)`. `CameraControlStore`'s feed-keyed API needs no change.
- If sign-in is needed, the row expands inline with the two fields and shows the fingerprint for a first pairing.
- Assignment pop-ups show which camera holds what. An occupied entry reads "Camera 2 (has FX3:B)" and is disabled for exclusive devices, using the rule already in `UIInputPicker.selectable`.
- Pairing asks for one confirmation on assignment: "Check that this body's HDMI goes to Left UltraStudio."

The Camera Control sheet remains for one job: operating a connected body. Its title becomes **Camera Settings · ILME-FX3:A**. Its pairing branch (`UICameraControl.swift:125-183`) moves to the Devices pane. Custom `ControlViewFactory` views keep working, since they already receive only generic actions (`ControlViewContext.swift:4`).

Nouns: **Camera** stays Ultracam's channel. Physical hardware is named by its own name. Where a sentence needs a noun, use **camera body**. "Feed" leaves the UI.

### Main window: the source row

The expanded strip's "Camera Control" row (`UICameraColumn.swift:664-671`) becomes one **source row**, in the same position, with the same height. The strip header loses its brand mark, because the row now carries both.

```
[video] [BM] Left UltraStudio · HDMI        [Sony] FX3:A · 78%
```

- Left half: capture link. Right half: control link. Each has its vendor mark from the descriptor.
- Each half shows a name plus up to two plugin chips.
- `UIFirstFitting` drops, in order: model text, then to nickname or suffix, then to mark and chips. A problem chip is never dropped.
- Left half opens the inspector's Source section. Right half opens Camera Settings, or Devices when disconnected.
- No body assigned and a control vendor available: right half reads **Assign Camera Body…** and opens Devices.
- SDK absent and no assignment: right half doesn't exist.

**A two-device rig with Sony control, at a glance:**

```
Camera 1  ● 2160p 59.94 ▾                                 [Stop Camera]
…
[video] [BM] UltraStudio · 0AB8 · HDMI       [Sony] FX3:A · 78%

Camera 2  ▲ No signal ▾                                   [Stop Camera]
…
[video] [BM] UltraStudio · 7C31 · HDMI       [Sony] FX3:B · Disconnected
```

In one line per camera, a person sees what feeds it, over which connector, whether control is up, and the battery. A dropped body reads in place without a banner.

Sony media is deliberately not in this row in the ordinary case. Ultracam records on the Mac, so a body's cards don't matter unless the body itself is recording. Media appears in the row only when the plugin marks it as a problem: the body is recording and remaining time is low, or a slot reports an error. Battery is always shown. On AC, the chip reads "AC" rather than hiding, when `PowerSource` confirms it on a live body.

Other surfaces:

- **Collapsed strip:** no marks. Add a problem chip only when a device problem exists, using the existing `collapsedLabel` pattern.
- **Picture overlays:** no new hardware overlay. The optional settings overlay stays as is. Placeholders gain plugin text (below). Clean View stays clean.
- **Status badge:** keeps meaning signal and capture state. Its menu lists both links and, when unassigned, offers **Assign Camera Body…** instead of the dead-end text.
- **Status bar:** no new segment. The fixed order is a design decision (`UIStatusBar.swift:3`). Hardware feeds the existing warning segment. Its popover lists every open problem with **Open Devices**.
- **Menu bar extra:** input menu keeps working. Problems raise the existing icon state through `warning()`.

`warning()` ordering after the change:

1. Recording failure, no signal while recording, couldn't start (existing)
2. Program picture problems (existing)
3. Disk space (existing)
4. **Hardware problem with severity critical, on a camera that is assigned and enabled**
5. Signal problems on running cameras (existing)
6. **Hardware warning: low battery, overheating**
7. LUT, Program issues (existing)

A body that merely disconnected is severity notice. It shows in the source row and the popover, but doesn't turn the status bar orange, because the picture is unaffected. Low battery and overheating do, because those end the picture.

### Inspector

Source section:

- **Input** picker stays, with a tiny mark and health dot.
- New **Connector** row, editable when stopped, read-only with a reason when running. This is the existing vendor setting, rendered by the existing `UIControlPropertyField`.
- New **Link** row, from status chips.
- **Signal** row uses the real format. Remove the hardcoded 4:2:2.
- **Supported source formats** collapses into a disclosure, listing human names ("2160p 29.97, 2160p 59.94"), using the mode names `UltracamMode.name` already holds. `CaptureDeviceInfo.supportedModes` becomes a typed list.
- **Open in Devices** link.

Camera Control section becomes an inline status block: body name and state, Reconnect in place when down, plugin telemetry as read-only rows, and **Camera Settings…**. When unassigned: **Assign Camera Body…**.

### What each failure shows

| Situation | Devices | Main window |
|---|---|---|
| Driver not installed | Vendor section shows plugin text and an action button with a plugin URL. | Placeholder shows the plugin's reason in place of "Input disconnected". Warning segment critical. |
| Driver too old | Same, with installed version. | Same. The app today lists no devices and says only "Input missing". |
| Driver OK, no devices | "No devices connected" plus any expected devices as absent rows. | Existing placeholder, with the plugin's missing-device hint. |
| Vendor SDK absent from build | Muted vendor row: plugin text, for example "Not included in this build". Saved assignments listed as inactive, never deleted. **Not a problem.** No count, no warning. | No control UI at all. A saved assignment shows no vendor mark. |
| Plugin configuration or discovery error | Vendor section shows the error. Other vendors unaffected. | Warning only if a camera depends on it. |

The SDK-absent case will likely be the public build, because Sony redistribution terms aren't settled (`docs/SONY_CONTROL.md:233-237`). It must read as a normal build rather than a broken one. That requires using `CameraControlStore.available` and hiding the two `UICameraControlButton` call sites. `context.cameraControls` is always non-nil today (`UILiveRoot.swift:57`).

### Required edge cases

**Same-model duplicates.**

- Keep ID identity. Keep the four-digit suffix as the fallback label (`UIPresentation.swift:348-358`), because the driver's "(1)/(2)" follows enumeration order.
- Add an app-local nickname keyed by device ID, editable in Devices.
- Do not write `DeviceInformationLabel` to the hardware. It would change shared device state that other apps can see, for a Mac-local preference. Read it, and use it as the initial name when present.
- Persist last-seen names beside nicknames, so a unit unplugged at launch is not "Input device".
- **Telling units apart physically:** idle signal lock and detected mode update live in Devices. Pulling one HDMI cable identifies the row. No thumbnail, because that would open capture.

**Unplug during a take.**

- Today: `reportFatal` → `failFromSource` → capture stops → that camera's recording stops; other cameras continue (`DeckLinkBackend.mm:1856`, `CaptureController.swift:1619-1620`, `AppModel.swift:1150-1160`). This is the right data behaviour and must not change. The take is closed rather than held open.
- Change only what is said. Strip state, status warning, and the Devices row read "Unplugged during take at 12:31. Camera 1's take is saved." Replug does not restart a manually started camera or a take. Offer **Start Camera**. An automatic camera already restarts through `reconcileAutomaticFeed` (`AppModel.swift:536`).
- A body lost on Wi-Fi during a take has no effect on the take. Notice only.

**Device in use by another app.**

- Show it in advance: the Devices row reads "In use by another app" and the Start button's help says so. The strip's left half gets a warning chip.
- The registry already knows its own sessions (`DeckLinkBackend.mm:1792`), so it can tell Ultracam's use from another app's.
- The SDK can't name the other app (no such field in the status IDs, Verified). The text should not pretend to.
- Replace "then restart", which is ambiguous, with "Close it, then start this camera." The state clears on its own.

**The USB 3 fallback.**

- Because the unit is invisible to DeckLink, the first line of defence is plugin text on a missing device: `VendorDescriptor.missingDeviceHint`. For DeckLink: "If it is plugged in, it may have fallen back to USB and can't be used. Connect it through a Thunderbolt hub." This ships without any IOKit work and fully handles the rig's known failure.
- Second line, optional, after a spike: a plugin probe that lists hardware the OS sees but the driver doesn't, via IOKit USB enumeration for Blackmagic vendor ID `0x1edb` (Measured). **A plain vendor match is wrong:** healthy units also appear on USB, at 12 Mb/s (see correction 2). The probe must compare the count of Blackmagic USB entries with the driver's device count, or look for a USB 3 link speed. A fallback unit's exact USB identity hasn't been captured, so reproduce the fault once before writing this. The result becomes a row: "UltraStudio on USB. Not usable." **Unknown:** whether a sandboxed app can read this without a new entitlement, and whether the Billboard device stays long enough to catch (Memory: "briefly"). Don't match on serial, per the placeholder note.
- Do not shell out to `system_profiler` from the app. It's slow and a sandbox risk.
- Link rate: show Thunderbolt plus PCIe width and generation from the SDK. A Thunderbolt Gb/s figure needs IORegistry and has no decision attached, since a degraded PCIe link is what would matter. If PCIe width or generation drops below what the current mode needs, the plugin raises a warning. Thresholds live in the plugin.

**Simultaneous dropouts.**

Keep an in-memory ring of signal-loss events per device, fed from the existing counter path (`CaptureController.swift:1161`). Devices shows counts and last time. If two inputs lose signal within 100 ms, the row says "with Camera 2", and the note reads: "Both inputs lost signal together. Look for a shared cause, such as power or the hub." This would have named the 2026-10-30 event at the time. It needs no plugin change.

### Plugin API additions

All additions have protocol-extension defaults, so `FakeCapturePlugin` and future vendors compile unchanged and report "unknown".

New shared types, in `Sources/DeviceAPI/DeviceStatus.swift`:

```swift
enum DeviceSeverity: Int, Codable, Sendable, Comparable { case info, notice, warning, critical }
enum DeviceLinkKind: String, Codable, Sendable { case pcie, thunderbolt, usb, ethernet, wifi, bluetooth, software, unknown }
enum DeviceAvailability: Equatable, Sendable { case unknown, free, inUseHere, inUseElsewhere }

/// A short label for the source row. Plugins choose the text and severity.
struct DeviceChip: Equatable, Sendable, Identifiable {
  let id: String; let text: String; var textKey: String? = nil
  var localizationTable: String? = nil; var severity: DeviceSeverity = .info
}
/// A row in Devices. Groups fix the order, so hosts need no vendor knowledge.
struct DeviceFact: Equatable, Sendable, Identifiable {
  enum Group: Int, Sendable { case identity, connection, signal, audio, sync, power, media, other }
  let id: String; let group: Group; let label: String; let value: String
  var labelKey: String? = nil; var localizationTable: String? = nil
}
struct DeviceProblem: Equatable, Sendable, Identifiable {
  let id: String; let severity: DeviceSeverity; let title: String
  var detail: String? = nil; var titleKey: String? = nil; var detailKey: String? = nil
  var localizationTable: String? = nil
}
struct CaptureDeviceStatus: Equatable, Sendable {
  var availability: DeviceAvailability = .unknown
  var link: DeviceLinkKind = .unknown
  var signalLocked: Bool? = nil
  var detected: SourceFormat? = nil
  var temperatureCelsius: Double? = nil
  var chips: [DeviceChip] = []
  var facts: [DeviceFact] = []
  var problems: [DeviceProblem] = []
}
```

`CaptureSourcePlugin` additions:

```swift
/// Cached; never calls the driver on the caller's thread and never opens an input.
func status(deviceID: String) -> CaptureDeviceStatus?
@MainActor func observeStatus(_ handler: @escaping @MainActor @Sendable (String, CaptureDeviceStatus) -> Void) -> DeviceObservation?
/// Hardware the OS sees but the vendor driver can't use. Empty by default.
func unusableHardware() -> [DeviceProblem]
```

`CaptureDeviceInfo` gains `model: String?`, `link: DeviceLinkKind`, and `modes: [SourceFormat]`. `connectors` finally gets read.

**Keep status separate from the device list.** `applyDevices` re-runs `vendorSettings.restore` for every device (`AppModel.swift:520-523`). Folding status into `CaptureDeviceSnapshot` would turn each status change into an SDK settings pass. Status needs its own observation path and its own `@Observable` store.

`DeviceDiagnostics.vendorFields` is removed. Diagnostics renders `status.facts` plus counters, which fixes the duplicates.

`VendorDescriptor` gains, all optional with defaults:

- `missingDeviceHint`, `missingDeviceHintKey`
- `unavailableInBuildText`, its key. The host stops composing the sentence at `UICameraControl.swift:60`.
- `deviceNoun`, its key, for empty states.

`DriverStatus` gains `actionTitle: String?` and `actionURL: URL?`.

`VendorRegistrySnapshot` gains `control: [ControlVendorSnapshot]`, so one snapshot describes all vendors. `AppHardware` gains `vendors: () -> VendorRegistrySnapshot`, plus `observeDeviceStatus`.

`CameraControlPlugin` / types:

- `ControlCamera` gains `model: String?` and `firmware: String?`. These **must be optional**. The assignment blob is decoded with synthesized `Codable` (`CameraControlStore.swift:25`), which accepts missing keys only for optionals, so a defaulted non-optional would fail to decode every saved assignment.
- `ControlProperty` gains `telemetry: ControlTelemetryKind?` and `severity: DeviceSeverity?`, where `ControlTelemetryKind` is `power, media, recording, thermal, lens, colorProfile, firmware`. This is separate from `role`, which already means something else. The host places values by kind and never by ID.
- `ControlEvent` gains `.notice(feedID:generation:message:severity:)`, so `OnWarning` has somewhere to go.
- Sony plugin: stop using `.transport` for every disconnect reason (`SonyControlPlugin.swift:31-32`).

Inside the plugins, no API impact:

- **DeckLink:** read model, vendor, interface, PCIe link at `insert`. Subscribe to `bmdStatusChanged` on each listed device for lock and busy. Sample temperature on a slow timer on the registry queue, 10 s. Today's subscription exists only during a session (`.mm:2416`).
- **Sony:** add battery, power, media, overheat, error, model, firmware, shooting-mode and profile fields. Override `OnWarning`. Keep the fingerprint and SSH rules exactly.

A setting that is refused while capturing needs no new API. Have `settings()` return `mutable: false` with `availabilityReason`, and refresh settings on capture start and stop. `interruptsCapture` then stays true only for the EDID setting.

Typed signal state should replace string parsing in the same pass: add it to `CaptureUpdate` and delete the matching in `UISessionBridge.swift:73-80`.

### Build order

**Phase 0: fix what exists, no API change.**

1. Remove hardcoded 4:2:2 (`UIInspector.swift:341`).
2. Show human mode names (`DeckLinkCapturePlugin.swift:413`).
3. Add a hardware block to Copy Diagnostics: driver, models, device IDs, connectors, assignment, Sony connection state. No credentials.
4. Persist last-seen device names.
5. Put driver text on the placeholder and in `warning()`.
6. Fix the badge-menu dead end.
7. Hide control UI when no plugin is available.
8. Rename the mislabelled and duplicated Diagnostics rows; drop stopped-device warnings.
9. Show `discoveryMessages["persistence"]`.
10. Replace "feed" in UI text.

**Phase 1: inventory.** `DeviceStatus` types, registry snapshot, DeckLink status reader, status store, Devices tab, move vendor settings, source row, inspector rows, nicknames, signal-loss ring, `missingDeviceHint`.

**Phase 2: Sony.** Move pairing, telemetry kinds, new fields, `OnWarning`, battery and thermal warnings. Each new field checked on a live FX3.

**Phase 3: cross-checks.** Advisory only, in Devices and the inspector:

- Body's HDMI output timing against the detected input.
- Body's colour profile against the camera's declared `sourceProfileID`. "Body reports S-Log3; this camera declares Rec.709." Sony field availability permitting.
- USB probe spike.

Testing:

- Extend `FakeCapturePlugin` and `FakeControlPlugin` with scripted status, problems and telemetry. `ui-verify` renders Devices in each state above without hardware.
- Add a reusable conformance check that `status(deviceID:)` never blocks and never opens an input.
- One manual hardware pass per phase, with Ultracam idle, never during a meeting.

---

## 5. Rig configurations

**Decision: not now.**

Everything a preset would hold already persists and restores itself on launch:

| Preset content | Already stored in |
|---|---|
| Which device feeds which camera | `FeedDescriptor.selectedDevice`, a persistent device ID (`AppSettingsStore.swift:259`) |
| LUT, source profile, colour targets | `FeedDescriptor` (`:262-275`) |
| Which body controls which camera | `CameraControlAssignmentSnapshot`, by MAC (`CameraControlStore.swift:9-12`) |
| Connector, EDID policy | `VendorSettingsPolicy.desiredByDevice` (`VendorSettingsPolicy.swift:5-9`) |
| Sign-in | Keychain, identity-bound (`docs/SONY_CONTROL.md:38-40`) |

"Sony FX3 + UltraStudio, S-Log3 LUT" is therefore simply what Camera 1 is today. A preset earns its keep only when one Mac moves between rigs, and this owner has one rig on this Mac, with one to two cameras in normal use (memory). The M5 laptop has its own preferences.

Presets would also cost something real:

- A device-ID reference in a preset goes stale exactly when it's needed.
- Applying one while capturing raises the same stop-first rules as every topology edit (`canEditTopology`), and connector and EDID changes hit hardware.
- Sony sign-in identity can't travel in a preset, so a preset would imply a portability it doesn't have.

The missing value is **visibility** of the current rig, and Devices supplies that, including expected hardware that's absent. That covers the "is everything here?" check a preset would otherwise give.

Revisit if a second physical rig appears on one Mac, or a person keeps re-pointing the same inputs between two setups. The smallest version then is one named snapshot of those three stores, restored only when all cameras are stopped, with a preview of what's absent. Copying monitor settings between cameras already exists (`UICopySettingsMenu`), so per-camera presets are not needed either.

---

## Open items needing a live check

1. Whether both units were behind the hub on 2026-10-30.
2. Whether `IDeckLinkStatus` signal lock and detected mode update while no input is enabled, on these units. The script and the comment at `DeckLinkBackend.mm:1947` suggest yes, but the connector then is whatever the driver last had.
3. Whether `BMDDeckLinkDeviceInterface` reports Thunderbolt for these units.
4. Whether these units populate serial and label.
5. Which Sony header fields an FX3 on firmware 7.02 actually returns, particularly media, overheat, picture profile and `PowerSource`.
6. Whether a sandboxed app can read USB devices from IOKit without a new entitlement.
7. Whether `BMDDeckLinkPersistentID` holds when a unit moves between hub ports.
