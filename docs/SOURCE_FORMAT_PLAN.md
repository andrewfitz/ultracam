# Source format plan

This is Part B of [the vendor plugin plan](VENDOR_PLUGIN_PLAN.md).

## Goal

Every stage of the app assumes one source: a Sony FX3 over HDMI into a
Blackmagic UltraStudio, giving:
- 3840×2160 10-bit 4:2:2 video (v210), at 29.97 or 59.94, tagged Rec.709;
- 48 kHz 32-bit stereo audio, paired with each frame;
- `HH:MM:SS;FF` timecode.

This plan removes every one of those assumptions. Each source then describes
itself, and every stage follows that description, still entirely on the GPU
with no CPU pixel copies.

Decided on 2026-10-26: Part B is in scope, and it covers *all* hard-coded
assumptions, not just size, format and rate.

The inventory below came from four read-only audits of the working tree on
2026-10-26:
- capture and runtime;
- GPU and the virtual camera;
- recording and audio;
- UI, settings and MonitorKit.

Line numbers drift; search for the quoted constant. Tags:
- **[P]** persisted in settings, so changing it needs a migration;
- **[F]** written into recorded files;
- **[EXT]** compiled into the camera extension;
- **[CLIENT]** visible to Zoom, OBS and other apps.

## The principle

The plugin declares one `SourceFormat`, and the frames confirm it. It flows
through capture, LUT, monitor, Program, recording and the virtual camera. No
stage compares a frame against a constant. Each one compares against the
format its source declared, and an unsupported format is refused with a clear
message naming the stage.

### GPU by default; CPU conversion only as an opt-in compatibility setting

Ultracam builds for arm64 only (`generate_project.py`, `ARCHS="arm64"`) and
targets macOS 26. So every Mac it runs on is Apple Silicon, with a GPU and
unified memory, and every route the app designs is a GPU route.

Decided on 2026-10-26: CPU conversion survives only behind one setting.

**The setting.** Settings gets "Allow CPU conversion (compatibility)". It is
global, persisted [P], and **off by default**.

**With it off (the default), no CPU pixel path runs:**
- Every format conversion, scale, colour conversion, fill and repack is a GPU
  kernel.
- A format with no GPU route is refused at admission (or before a take
  starts), with a message naming the format and the stage. The message also
  says that the compatibility setting would allow it.
- If a GPU command fails on one frame (a pool exhausted, a command buffer
  error), that frame is a counted, visible error for that consumer.

**With it on:**
- A stage with no GPU route for a format may hand the frame to the system's
  CPU conversion: VideoToolbox in recording, and a CPU copy into an IOSurface
  for an ingest buffer the GPU can't wrap.
- The same applies to a frame whose GPU command failed.
- Every CPU-handled frame is counted per camera and per stage. The camera
  shows a "CPU conversion" badge while any are happening, and diagnostics and
  the take's sidecar record the count.
- It never changes a route that has a GPU path. It only replaces "refused"
  with "converted on the CPU, and shown".

**Why keep it:** a source we haven't written a kernel for yet works
immediately (a new NDI format, an unusual webcam fourCC), while the GPU route
is built.
- **CPU-memory sources need no CPU copy either.** Some SDKs return frames in
  ordinary memory: NDI, software decoders. Unified memory lets the GPU read
  that memory directly:
  - wrap the frame's pages in an `MTLBuffer` with
    `makeBuffer(bytesNoCopy:length:options:deallocator:)`. The range is
    page-aligned: round the start down and the length up;
  - unpack it with the format's GPU kernel straight into an IOSurface pool.

  That GPU write is the same format conversion any non-native format gets.
  The plugin keeps the vendor frame alive until the command buffer completes.
  Where the SDK lets us supply the allocator, the plugin gives it
  IOSurface-backed, page-aligned memory, and the GPU reads the frame in place.
- **Enforcement:** a check script fails if `CVPixelBufferLockBaseAddress`,
  `CVPixelBufferGetBaseAddress*` or `MTLTexture.getBytes`/`replace(region:)`
  appears in `Sources/` or `Vendors/` outside an allowlist. Tests are exempt.
  The allowlist has two entries:
  - the 2×2×2 identity LUT upload (`LUTProcessor.swift:343`), which is LUT
    data, not video;
  - one `CPUCompatibilityConverter` type, which is the only code that may
    touch pixels on the CPU, and runs only when the setting is on.

  The extension's standby fill is the one current violation ("Fix now").

### The contract types

These live in `Sources/Shared`, so the extension compiles them too.

```swift
struct SourceFormat: Equatable, Sendable {
  var width: Int, height: Int
  var pixelAspect: (Int, Int)            // 1:1 for nearly everything
  var scan: Scan                         // progressive, interlaced(topFirst), psf
  var pixel: PixelFormatID               // key into the format table
  var colour: Colorimetry                // primaries, transfer, matrix, range, chroma siting
  var rate: FrameRate                    // exact rational duration + nominal + variable flag
}

struct FrameRate: Equatable, Sendable {
  var duration: CMTime                   // exact, e.g. 1001/24000
  var isVariable: Bool                   // webcams, NDI
  var nominal: Double { 1 / duration.seconds }
  var timescale: CMTimeScale             // natural timescale for this rate (24000, 25, 60000…)
  var dropFrameTimecode: Bool            // only the 1001-based 30/60 families
}

struct SourceAudioFormat: Equatable, Sendable {
  var description: AudioStreamBasicDescription   // rate, channels, sample type, packing
  var layout: AudioChannelLayoutTag
  var clock: AudioClockDomain                    // pairedWithFrames, hostTime, own(device clock + mapping)
}

struct Timecode: Equatable, Sendable {           // replaces the HH:MM:SS;FF string
  var hours, minutes, seconds, frames: Int
  var rate: FrameRate, dropFrame: Bool, fieldMark: Bool?
}
```

### One shared format table

`PixelFormatTable` (Shared, so the extension has it too) holds one entry per
supported fourCC, and every stage reads its layout from that entry:
- planes;
- Metal formats for each plane (`r16Unorm`/`rg16Unorm`/`r8Unorm`…);
- bit depth and container shift (10 bits stored high in 16-bit words, 8 bits,
  12 bits);
- chroma subsampling;
- the default range;
- row alignment;
- whether the format is packed (v210, 2vuy, yuvs), and which kernel reads it.

These all keep their own lists today, and they disagree:
- `LUTProcessor` (`:863-876`);
- `VideoBufferLayout`;
- `ProgramNormalizer` (`:516-525`);
- `RecordingPixelConverter`;
- `MonitorFeedHost` (`:697-717`);
- the extension's standby fill (`CameraProvider.swift:414-444`).

For example, LUT passthrough accepts `xf20` and `420f`, which
`VideoBufferLayout` and `ProgramNormalizer` refuse.

## Fix now

These are bugs in today's code, separate from the refactor:

| Where | Bug | Live today? |
|---|---|---|
| `UISupport.swift:131-132`, called from `UISessionBridge.swift:379-381` | `sourceProfile(forGamut:)` returns `"sony-slog3-sgamut3cine"` when the gamut text contains "Cine", and `"sony-slog3-sgamut3"` otherwise. Turning on false colour for any undeclared camera (Rec.709, PQ, ARRI, "Unspecified") declares it S-Log3. "Canon Cinema Gamut" maps to S-Gamut3.Cine. | **Yes**. Return nil when nothing matches. |
| `AppSettingsStore.swift:326` vs `:209,230,254` [P] | A missing `gamut` key decodes as `"S-Gamut3.Cine / S-Log3"`, but new feeds default to `"Unspecified / custom LUT"`. | **Yes**. Make both "Unspecified". |
| `UISettings.swift:660` | "False color works when … declared as Sony S-Log3". Six-band and ARRI modes work without that. | **Yes**. Wording only. |
| `README.md:88-89` | Says 16-bit audio; capture is 32-bit. | **Yes**. Wording only. |
| `UIPresentation.swift:204` | Says "ProRes 422 10-bit"; the recorder writes ProRes 422 HQ (`RecordingModel.swift:14`). | **Yes**. Wording only. |
| `LUTShaders.metal:169-182, 216-225` | The Lanczos path scales the window and `t` by `scale` even when upscaling, so upscales (720p→1080p, 1080p→4K) collapse toward nearest-neighbour. | No: every source is 4K, so the pipeline only scales down. Fix with `max(scale, 1)` before the first non-4K source. |
| `VideoContract.swift:190` | `untouched` treats `resizeTarget == .uhd4K` as "no resize". With a 1080p source, the sink would negotiate 3840×2160 (`CameraSink.swift:211`) and refuse every frame (`:328`). | No (4K only). |
| `SourceRecording.swift:234` | Drop-frame timecode is chosen when `frameRate == .fps2997 \|\| .fps5994`, which is always true, so a 25p take gets a drop-frame `tmcd` track. | No (4K 29.97/59.94 only). |
| `VideoContract.swift:166` | `Int32(title)!` crashes if a rate with a fractional title (119.88, 47.952) is added without an explicit duration. | No. It's a trap for B3. |
| `AVAssetSourceRecordingWriter.swift:65-66`, `:417`, `:480-484`, `:496-497` | Recording's CPU routes: `videoToolboxConverts` when no GPU route exists, a capture buffer that isn't IOSurface-backed, and a failed GPU repack ("Never lose the frame: let VideoToolbox convert it") all hand the frame to VideoToolbox's CPU conversion. | **Yes**, though unused with today's single format. Put all three behind the compatibility setting (one `CPUCompatibilityConverter`). Off: no GPU route means the take refuses to start, and a GPU failure is a counted lost recording frame. On: they convert on the CPU, counted and badged. |
| `CameraProvider.swift:413-446` [EXT] | The standby black frame is filled on the CPU (`CVPixelBufferLockBaseAddress` plus `memset`, and a v210 word pattern), tagged 709. | **Yes**. Clear it on the GPU (Metal in the extension) from the format table's black values, with tags from the published format. |
| `RecordingModel.swift` vs `UISupport.swift:9-14` | The recorder's space guard (`SourceRecording.swift:94-99`, bytes per pixel) and the UI's time-left estimate (`707`/`354` Mb/s, `fallbackMegabits: 707` at `:36`) disagree by about 2.5× at 59.94. | **Yes**. One estimator (B9). |

## Inventory

### 1. Admission gates

Each gate compares against constants. Each must compare against the declared
`SourceFormat` and the format table instead.

| Where | Assumes |
|---|---|
| `UltracamBackend.mm:851` | `GetWidth() != 3840 \|\| GetHeight() != 2160 \|\| != bmdFormat10BitYUV` is fatal |
| `UltracamBackend.mm:866-868` | `rowBytes < 10240`, "3840 × 2160 v210 needs …". 1080p v210 is 5120 bytes, so 1080p fails here even after `:851` is fixed |
| `UltracamBackend.mm:886` | accepts v210 only |
| `UltracamBackend.mm:220-229`, `:812`, `:856` | `supportedFrameDuration` allows only 1001/30000 and 1001/60000; anything else is "UltraStudio supplied an invalid frame timestamp" |
| `UltracamBackend.mm:554`, `:201`, `:560-562` | the mode list is `bmdMode4K2160p2997/5994` only; format detection requires YCbCr422 at 10 or 12 bit and rejects RGB 4:4:4 and 8-bit |
| `CaptureController.swift:1048-1056` | width 3840, height 2160, `tenBit422`, duration fast/slow |
| `CaptureController.swift:971-976` | recording admission: the same four |
| `LUTProcessor.swift:533-538` | 3840×2160 and `tenBit422` |
| `AVAssetSourceRecordingWriter.swift:368`, `:379` | v210 only; size must equal the configured 3840×2160 |
| `CameraSink.swift:83`, `:328`; extension admit `CameraProvider.swift:219`, `:306`, `:315` [EXT] | `VideoBufferLayout` formats only; the duration must match within 1 µs |
| `ProgramOutputBridge.swift:355` | drops frames whose duration differs from the negotiated one |
| `ProgramTimestampMapper.swift:112-115` | rejects a source whose timescale changes |

### 2. Size, aspect and scaling

| Where | Assumes | Generalize |
|---|---|---|
| `VideoContract.swift:180-181`, `:178` [EXT] | width and height fall back to 3840/2160 when not downscaling | use the source size |
| `VideoContract.swift:132-137` [P] | `ResizeTarget` is 720/1080/UHD only, with `height = width * 9 / 16` | add "Source size", DCI 4096, and size from aspect; never offer an upscale as a default |
| `LUTProcessor.swift:594`, `ProgramNormalizer` | aspect isn't kept, so 4:3 or 17:9 sources are stretched | fit (letterbox or pillarbox) in the kernel; the policy is a decision below |
| `LUTProcessor.swift:422` | the warm buffer is 4K v210 | warm from `nativeFormat` |
| `RecordingModel.swift:370` | `width: 3840, height: 2160` | take it from the source |
| `ProgramNormalizer.swift:562-578` | box filter for integer ratios up to 4, else 2-tap bilinear; aliases at large ratios such as 8K→720p | multi-tap or two-pass |
| `VideoBufferLayout.swift:22`, `:50` [EXT] | row stride only has to be a multiple of 4 or the component size | check Metal's linear-texture alignment, so third-party buffers map |
| `MonitorSurface.swift:99` | starts at 16:9 until the first frame | use the declared aspect (cosmetic) |
| `UISessionBridge.swift:55-74` | splits the format *string* `"3840 × 2160 · v210 · …"` and forces `"\(height)p"` | use the structured `SourceFormat` |

### 3. Pixel format, bit depth and chroma

| Where | Assumes | Generalize |
|---|---|---|
| `UltracamBackend.mm:1014`, `:1051` | always requests `bmdFormat10BitYUV`, so a 12-bit source is silently cut to 10-bit | request the detected format: 12-bit YUV or RGB 4:4:4 when present |
| `CaptureController.swift:417`, `:1720`; `AppModel.swift:1415` | `capturePixelFormat` and Program `passthroughFormat` are `kCVPixelFormatType_422YpCbCr10` | `nativeFormat.pixel` |
| `CaptureController.swift:1528-1531` | `InputFormat.label` knows only 4:2:0-8 and 4:2:2-10; everything else is "Unknown" | label from the format table |
| `LUTShaders.metal:37-63` | `PackedSource` reads only v210; `PlanarSource` reads 4:2:2 only and ignores vertical chroma position | kernels for each table entry, including 4:2:0 vertical siting |
| `LUTShaders.metal:73-74` | `65535.0f / 64.0f` assumes 10 bits stored high | depth and shift come in `Parameters` |
| `LUTProcessor.swift:587-590` | planes always map as `.r16Unorm`/`.rg16Unorm` | read from the table |
| `LUTProcessor.swift:665` | code ranges are 10-bit `64/876/512/896` | derive them from depth and range |
| `LUTProcessor.swift:559`; `LUTShaders.metal:86-93` | output is 8- or 10-bit only, always video range | follow the output target; full range when chosen |
| `VideoContract.swift:139-152` [P][EXT][CLIENT] | `ColorTarget` has only four video-range YUV formats | append (indices are a contract); add full range and 4:4:4 if wanted |
| `VideoContract.swift:49` [EXT][CLIENT] | `formatDescription` limited to `tenBit422 ∪ ColorTarget` | the format table |
| `RecordingPixelConverter.swift:54`, `:208`; `SourceRecording.swift:73`, `:79` | in: v210 only; out: x422 pool only | a repack kernel per (source, encoder) pair, from the table |
| `AVAssetSourceRecordingWriter.swift:65-66`, `:480-481`, `:496-497` | `videoToolboxConverts`: when no GPU route exists, VideoToolbox converts on the **CPU** | behind the compatibility setting from B0 (see "Fix now"); a new format still brings its GPU repack, and without one recording refuses it unless the setting is on |
| `MonitorFeedHost.swift:476`; MonitorKit `Signal.swift:263` | range falls back to `.legal` | take the range from the format; full-range webcams send `420f` |

MonitorKit's `PixelLayout` (`Signal.swift:13-33`) already handles v210, uyvy,
nv12, p010 and RGB. It is the model for the table.

### 4. Frame rate, timescale and variable rate

| Where | Assumes | Generalize |
|---|---|---|
| `VideoContract.swift:13-14`, `:175`, `:186-188` [EXT] | `inputFast: Bool`, so 1001/60000 or 1001/30000 are the only cadences | `FrameRate` |
| `inputFast` threaded through `CaptureController.swift:10, 440, 598, 1059, 1315`; `AppModel.swift:1098, 1106, 1171-1174`; `AutomaticFeedPolicy.swift:12`; `LiveTelemetry.swift:46`; `UILiveTelemetry.swift:45`; `UISettings.swift:130` | the same, at runtime | replace it everywhere |
| `UltracamBackend.mm:1847`, `:1865`, `:1872` | the mode comes from `inputFast`; stream timescale `inputFast ? 60000 : 30000` (auto mode always 60000), which can't represent 23.976 (2502.5 ticks) or 119.88 | the detected mode's own timescale |
| `UltracamBackend.mm:814` | `duration * 30 < timeScale` means "high frame rate" | `FrameRate.nominal > 30` |
| `ProgramTimestampMapper.swift:67`, `:252`; `SwitcherCoordinator.swift:18`, `:23` | `programTimescale = 60_000` | the Program output rate's own timescale |
| `FeedRuntime.swift:484` | `count < 4` caps repeats at 4×, so 7.5 fps into 59.94 under-fills the grid | no cap; a counted repeat per grid slot |
| `VideoContract.swift:155` [P][EXT] | `FrameRateTarget` stops at 60; no 48, 100 or 119.88/120 | add them, and fix the `Int32(title)!` crash first |
| `CameraProvider.swift:84`, `:140-141` [EXT][CLIENT] | default 59.94; min `fps60`, max `fps23976`; `validFrameDurations` only from that list | from the published format |
| `CaptureController.swift:828`, `:948`, `:1044` | any duration change resets drop tracking, the host-time anchor and the gate | in VFR mode, don't treat a change as a mode change |
| `MonitorFeedHost.swift:509` | the source rate is estimated from one timestamp gap | use `FrameRate`; smooth it for VFR |
| `MonitorCoordinator.swift:133-135` | scopes run once per source frame, so 120 Hz scopes at 120 fps | cap the scope rate in time |
| `MonitorWorkspace.swift:463` [P] | `refreshRates = [10, 15, 30]` is stored but ignored | wire it up or remove it |
| `AVAssetSourceRecordingWriter.swift:1121-1122` [F] | movie and video timescale 30000 or 60000 | the source rate's timescale (keeps 23.976 exact) |
| `AVAssetSourceRecordingWriter.swift:291-297`; `SourceRecording.swift:176`; `RecordingModel.swift:368-376` [F] | `matchingFrameRate` falls back to the configured rate; the default is `.fps5994`, and the model never passes a rate. **A 25p take is silently labelled 59.94** | pass `FrameRate`; refuse a mismatch |
| `SourceRecording.swift:740-758`; `AVAssetSourceRecordingWriter.swift:1282-1284` | the 60000 frame key; skip detection uses the previous frame's duration, so VFR reports false skips | skip detection only for constant-rate sources |
| `SourceRecording.swift:175` [F] | `maxKeyFrameInterval: 60` counts frames (0.5 s at 120p, 2.4 s at 25p) | `maxKeyFrameIntervalDuration` in seconds |
| `AutoSwitcherTimelineRecorder.swift:300`, `:533`; `Tools/auto-switcher` `model.rs:341` [F] | `timescale 60_000` in timeline JSON (`schema_version 2` at `:239`) | a timescale that 23.976 divides exactly, such as 240000 (also exact for 47.952 and 119.88); bump the schema |
| `UIInspector.swift` and `UIFeedSettingsMenu` frame-rate pickers | 29.97/59.94-centric copy (`CaptureController.swift:596-598` "29.97/59.94") | list the plugin's supported modes |

### 5. Timecode

| Where | Assumes | Generalize |
|---|---|---|
| `UltracamBackend.mm:425-512`, `:505` | the pair-counter heuristic assumes 2:1 field pairing at 59.94; frame labels above `highFrameRate ? 59 : 29` are rejected | limits from `FrameRate`; check field pairing against RP 188, not vendor folklore |
| `UltracamBackend.mm:818` | timecode is read only when a media handler is set | always, if the plugin supports it |
| `RecordingTimecode.swift:11-46`, `:40-45`, `:327-336` [F] | only `fps2997`/`fps5994`; drop counts and TimeCode32 quanta tied to 30/60 | from `FrameRate`: NDF for integer rates, DF only for the 1001 30/60 families |
| `RecordingTimecode.swift:124-172`; `SourceRecording.swift:232` | parses the 11-character `HH:MM:SS[:;]FF` string; frames below the nominal rate (`:156` "0–59 at 59.94") | the `Timecode` struct |
| `SourceRecording.swift:159`; `AVAssetSourceRecordingWriter.swift:280-286` | relies on the `UltracamCaptureHostTime` attachment; without it, wall-clock timecode is anchored at first encode | a required plugin field, with "start" or "end" of frame declared |

### 6. Colour, LUT space and source declaration

| Where | Assumes | Generalize |
|---|---|---|
| `VideoContract.swift:67-69` [EXT][CLIENT] | format descriptions are always BT.709 | from `Colorimetry` |
| `UltracamBackend.mm:276-307`, `:252` | `applyColorimetry` knows only 601/709/2020 and SDR/PQ/HLG; `kEOTFHDRGamma` gets no transfer; range and chroma siting are never attached | the plugin fills `Colorimetry`, and one shared function writes the CV attachments |
| `LUTProcessor.swift:657-660`; `MonitorFeedHost.swift:584-586` | the matrix falls back to BT.709 unless 2020 or 601. The two copies must change together | one helper |
| `LUTProcessor.swift:983-996` | with a LUT, output is tagged 709 whatever the LUT outputs; without one, HLG/PQ tags carry onto 8-bit 4:2:0 output; there is no transfer or primaries conversion anywhere | store the LUT's input and output spaces with it; add an optional GPU colour-conversion stage |
| `LUTProcessor.swift:654-656`, `:971`; `ProgramNormalizer.swift:360`, `:370` | chroma position: horizontal only, assumed centred, always tagged `Center` | from `Colorimetry` |
| `ScopeSettings.swift:77`; `UIScopeDescription.swift:114`; `UIInspector.swift:225` | `lutApplied ? .bt709 : source`, "The LUT should output Rec.709" | the LUT's declared output space |
| `UIInspector.swift:16` [P] | the "Input gamut" list (13 entries, Canon/Panasonic/BMD/RED included) is a *label* only; stored values are display strings (`AppSettingsStore.swift:326`) | stable IDs and a migration |
| `UIMonitorToolFalseColor.swift:11-16`; MonitorKit `Signal.swift:95-99` (`LogCurve` sLog3/LogC3/LogC4); `Colorimetry.swift:154` | the monitor's "Camera log" list is Sony and ARRI only, so Log→709 display assist (`UIMonitorToolPicture.swift:130`) and log false colour can't handle C-Log, V-Log, BMD Film or Log3G10 even though the inspector offers them | one source declaration (curve, gamut, range) shared by the inspector and the monitor, with matching MonitorKit curves; a camera plugin may *suggest* it (Sony control knows the camera's picture profile) |
| `UIScopeDescription.swift:199`, `:264`; `UIMonitorToolFalseColor.swift:62-68`; `FalseColorLegend.swift:23` | "10-bit code values" labels | keep as the convention, but label it as such on 8- and 12-bit sources |

### 7. Audio

| Where | Assumes | Generalize |
|---|---|---|
| `UltracamBackend.mm:1022`, `:627`, `:671`, `:635`, `:680`, `:633`, `:678` | `EnableAudioInput(48kHz, 32bitInteger, 2)`; `channels = 2`; the packet clock is `bmdAudioSampleRate48kHz`; a 96000-frame bound ("2 s" only at 48 kHz) | enable the device's channel count (`maximumHDMIAudioChannels` is read at `:1139`, `:1844` but unused); bounds in seconds |
| `EmbeddedAudioRecording.swift:26-33`, enforced at `:151, 155, 238, 242, 277, 281, 327, 418` [F] | 48 kHz, 2 ch, 32-bit in, 24-bit out | `SourceAudioFormat`; output depth chosen from the source |
| `EmbeddedAudioRecording.swift:52-118` | `BlackmagicAudioConverter` assumes Int32 carrying 24 significant bits | converters keyed by sample type, including float and 16-bit; rename it |
| `EmbeddedAudioRecording.swift:363-365` [F] | no channel layout written (needed above 2 channels) | write the `AudioChannelLayout` |
| `CaptureController.swift:1016`; `SourceRecordingAdapter.swift:163` | `bytesPerSample == 4` | from the format |
| `CaptureController.swift:1494-1499`, `:1506`; `SourceRecording.swift:912`; `SourceRecordingAdapter.swift:202`, `:224`, `:360`, `:363` | the literals `/ 48`, `48_000`, `144` (3 ms), `60 * 48_000` | from the sample rate |
| `SourceRecordingAdapter.swift:144-160`, `:343-445`, `:396-397`, `:411` | pairs audio with video by callback order on one thread; unpaired audio gets `offset = 0` (the raw device clock) | `AudioClockDomain`: `pairedWithFrames` keeps today's anchor; `hostTime` and `own(mapping)` place packets through the host clock |
| `UltracamBackend.h:71-73`, then `CaptureController.swift:48-51`, `:1431-1447`; `UIPresentation.swift:66-69`; `UIAudioMeterPanel.swift:104, 111, 124`; `AudioMeterTapDisplay.swift:121` | meters are left/right only | N-channel arrays (MonitorKitAudio already takes up to 16 with `standardLayout`) |
| `AudioMeterTap.swift:71-82`, `:96`, `:209`; `AudioMeterTapDisplay.swift:50` | 48 kHz 2 ch; refuses mono and anything other than 32-bit; meters only the first 2 of 8 or 16 channels; the 4096-packet queue is sized for DeckLink callbacks; a one-second window at 48 kHz | configure from the source format; size the queue in seconds |
| `AppModel.swift:996`, `:1002-1004`; `AutoSwitcherBridge.swift:133` | the switcher gets `max(L, R)` RMS against `0.035`; audio packet time and video media time are mixed as if they were one clock | a per-channel or summed voice signal; timestamps tagged with their clock domain. The Rust analyser is rate-generic; the stereo assumption is Swift-side |
| `AVAssetSourceRecordingWriter.swift:1114`, `:1133`, `:1092`, `:1219-1220` [F] | a 48 kHz stereo LPCM input is always added; the file opens only on the first video frame, and stopping before it fails | add audio inputs from the source format, or none; decide on audio-only takes |
| `SourceRecording.swift:123-134`, `:171-173`, `:652-660` | 12 frames, 256 audio packets, 1 GiB; 256 packets assumes about one per frame (a 96 kHz Core Audio device with 128-frame buffers fills it in 0.34 s and fails the take) | limits in seconds and bytes |
| `UIStatusBar.swift:368`; `UIPresentation.swift:748`, `:756` | "48 kHz stereo from each input", "No embedded audio", "without HDMI" | describe the actual source audio, including "audio from <device>" |
| `Config/App-Info.plist`, `App.entitlements:11-13` | no `NSMicrophoneUsageDescription` and no audio-input entitlement | needed before any webcam or USB audio |

### 8. Program output

| Where | Assumes | Generalize |
|---|---|---|
| `FeedRuntime.swift:17-21`, `:32-37` | `ProgramOutputFormat` comes from `PipelineConfiguration` (inheriting the 3840 fallback and two cadences) and has no colour fields; untouched means v210 4K | Program is its own chosen `SourceFormat`, with size, rate and colour |
| `ProgramNormalizer.swift:14-15`, `:247` | "every format in the pipeline is BT.709 video range"; only `xf22` full range is handled | convert every source on the GPU to Program's colour |
| behaviour of `FeedRuntime` and `ProgramNormalizer` [CLIENT] | a cut from a 709 camera to a 2020/PQ camera flips the Program tags mid-stream | the Program colour stays fixed; sources convert into it |
| `FeedRuntime.swift:484` | at most 4 repeats | see section 4 |
| Program rate conversion | today all sources share a cadence | a 25p source into a 59.94 Program repeats frames in a 2:3-like pattern, and a 59.94 source into 25p must skip frames. That skip is rate conversion, not drop-when-busy, but it has to be stated and counted (decision 2) |

### 9. Recording

| Where | Assumes | Generalize |
|---|---|---|
| `RecordingModel.swift:8-10`, `:14`, `:371-372` [P][F] | `proRes42210Bit` (actually HQ) and `hevcMain10_422` put 4:2:2 in the raw values; HEVC 4:2:2 from an 8-bit 4:2:0 webcam is a needless upsample | a profile matrix (ProRes LT/422/HQ/4444, HEVC Main/Main10/4:2:2) checked against the source; keep the old raw values as aliases |
| `SourceRecording.swift:58`, `:83-88` | `HEVC_Main42210_AutoLevel`; a hardware encoder is required; no level, size or rate check, so 8K120 fails only at session creation | validate before the take starts, and say why |
| `AVAssetSourceRecordingWriter.swift:506-513` [F] | colour tags are copied from the buffer; untagged sources make untagged files | required `Colorimetry` (section 6) |
| `AVAssetSourceRecordingWriter.swift:30-39`; `RecordingPixelConverter.swift:57-61` | 16 pooled x422 buffers "of 33 MB", 6 capture frames; 480 idle conversions for "four 59.94 feeds" | size by bytes and time |
| `SourceRecording.swift:94-99`; `UISupport.swift:9-14`, `:36`; `UISettings.swift:192` | bytes per pixel 0.444/0.30/0.15; `707`/`354` Mb/s with `fast: true` always; "2160p 10-bit 4:2:2" | one estimator from codec, size, rate and depth, used by both the guard and the UI |
| `RecordingRecovery.swift:62`, `:64`, `:157-175`, `:182` [F] | `.mov` only; a video track is required (no audio-only recovery); depends on the fragmented-movie settings at `AVAssetSourceRecordingWriter.swift:1108-1109` | fine for now; revisit if audio-only takes are allowed |
| `RecordingRecovery.swift:199-200` [P] | the folder bookmark key is `recordingFolderBookmark.feed.<feedID>` | keep feed IDs stable; plugins must not change them |

### 10. Virtual camera extension and client contract

| Where | Assumes | Generalize |
|---|---|---|
| `CameraProvider.swift:132-138` [EXT][CLIENT] | "keep the original eight indices stable"; one format list for every device | append only |
| `VirtualCameraRegistry.swift:151`, `:183` [EXT] | schema version 1, checked for exact equality, with no format fields | bump to 2 with per-device formats, shipped in the app and the extension together; old extensions must keep working until reinstalled |
| `CameraProvider.swift:381`, `:839` [EXT] | standby black after 0.5 s without frames; checks for frames at a quarter of the frame interval | in time, from the published rate; a VFR or paused source (NDI) shouldn't flash black at 0.5 s |
| `CameraProvider.swift:413-446` [EXT] | the standby fill runs on the CPU per format family, assuming video range and 709 | a GPU clear from the format table (B0) |
| `CameraProvider.swift:656` [CLIENT] | the device model is `"FX3 LUT camera"` | "Ultracam camera" |
| `VideoContract.swift:24`, `:28`, `:32`; `maxFramesInFlight = 3`; `LUTProcessor.swift:697`; `ProgramNormalizer.swift:393` [EXT] | pools of 9 / limit 64 / sink queue 8 / Program 4 count frames, not bytes (64 frames of 8K 4:2:2 10-bit is about 8 GB) | budget in bytes, keeping minimum counts |

### 11. Interface, device and signal

| Where | Assumes | Generalize |
|---|---|---|
| `UltracamBackend.mm:142-172`, `:2048-2060`; `DoesSupportVideoMode` at `:205, 1856, 1862, 1866, 2016` | `HDMILease` forces `bmdVideoConnectionHDMI`, and forces it again when Desktop Video preferences change, so SDI is never used | the connector is a per-device plugin setting (HDMI, SDI, optical), and the lease applies only when HDMI is chosen |
| `UltracamBackend.mm:105-136`, `:1253-1258`; `AppSettingsStore.swift:418`, `:445` [P]; `UISettings.swift:682-685` | EDID HDR advertisement is one global Bool | an HDMI-sink capability owned by the plugin, per device (migrate the global value onto each DeckLink device) |
| `UltracamBackend.mm:1821-1823`; `AppModel.swift:1228`, `:1235` | a device is exclusive; one feed per input | the plugin declares whether a source can be shared (NDI can) |
| `CaptureController.swift:530-558` | the 2-second no-signal watchdog | the plugin declares whether a source may legitimately pause (NDI, a webcam with its shutter closed) and its own timeout |
| `UICameraColumn.swift:130`, `:133` | "2160p 29.97 or 59.94, 10-bit 4:2:2, RAW off" | the plugin's supported-modes text |
| CPU-memory sources (NDI, software) | an IOSurface is required at `LUTProcessor.swift:578`, `:690`, `CameraSink.swift:84`, `ProgramNormalizer.swift:221`, `MonitorFeedHost.swift:685` | the GPU reads the vendor's memory in place through a no-copy `MTLBuffer`, and its unpack kernel writes the IOSurface pool (see "GPU by default"; if the memory can't be wrapped, the compatibility setting allows one counted CPU copy); downstream stays IOSurface-only |

### 12. Limits counted in frames

All of these become time or bytes, converted with the source's `FrameRate`:

- `UltracamBackend.mm:932` and `CaptureController.swift:955`: `< 600`
  frames is the discontinuity limit;
- `FeedRuntime.swift:151`: `stageCapacity = 24` ("~0.4 s at 59.94");
- `FeedRuntime.swift:158`: `healthyPublishesToRearm = 60` ("~1 s");
- `LUTProcessor.swift:934-936`: `120`/`240` ("four seconds");
- `ProgramNormalizer.swift:107`: `120` ("~2 s at 60 fps");
- `SourceRecording.swift:175`: keyframe interval;
- `SourceRecording.swift:123-134`: queues;
- the pools in section 10.

### 13. Stored settings needing migration

Before changing any default, write explicit values for existing users. Today,
missing values are filled in at read time, so changing a default silently
changes their output.

- **`AppSettingsStore.swift:292`:** nil targets become
  `.hd1080/.yuv4208/.fps2997` at read time. The 29.97 cap is wrong in 25/50
  regions.
- **The `gamut` display strings** become stable IDs (section 6).
- **`ResizeTarget`, `ColorTarget` and `FrameRateTarget` raw values** are
  append only.
- **`advertiseHDRToCameras`** becomes a per-device DeckLink setting.
- **Recording codec raw values** stay as aliases. Codec and timecode mode
  aren't stored today.
- **`selectedDevice` (`AppSettingsStore.swift:201`, `:222`)** and the
  recording folder bookmark keys stay valid.
- **`MonitorWorkspace.refreshRates`** is wired up or dropped.

### 14. Product names and format wording

Vendor-name leaks are Part A (vendor plan, "Leaks to close"). These are the
format and interface wording that Part B owns:

- "HDMI" where "input" is meant:
  - `UICameraColumn.swift:150`;
  - `UIMenuBar.swift:675`;
  - `UIFeedSettingsMenu.swift:4`, `:34`;
  - `UISelfTest.swift:45`;
  - `CaptureController.swift:458`;
  - `SourceRecording.swift:747`;
  - `AVAssetSourceRecordingWriter.swift:440`.
- "UltraStudio" where "capture device" is meant:
  - `UIHelp.swift:7`;
  - `UIMainWindow.swift:71`;
  - `UIToolbar.swift:87`;
  - `UISelfTest.swift:53`;
  - `UICameraColumn.swift:136`;
  - `AppModel.swift:1191`, `:1269`;
  - `UltracamBackend.mm:846-847`, `1078`, `1474`, `1809`, `2008`.
- "Blackmagic signal flag" (`SourceRecording.swift:897`) and "Blackmagic raw
  audio" (`RecordingModel.swift:126`).
- `UIInspector.swift:290` appends `" · 4:2:2"` to every live format.
- `UIFeedSettingsMenu.swift:80` "Bitrate · uncompressed HDMI".
- Usage strings:
  - `App-Info.plist:20` `NSCameraUsageDescription` names UltraStudio, and is
    exactly the prompt a webcam triggers;
  - `:22`, the local-network string, names Sony and HDMI, and NDI discovery
    triggers it.
- README lines 11, 47, 272, 376-377, 399-401 and 436 describe the single
  DeckLink/FX3 contract.
- Preview fixtures: `UIContext.swift:114-127`, `:194`, `:212`.

### 15. Test-only recording code

These types are used only by their own files and `Tests/`. Delete them, or tie
them to the production path; don't generalize them:
- `ProResRecordingConfiguration.swift` (`:71-80` rate list, `:94` 8192 limit,
  `:122-126`);
- `HEVCRecording.swift:10-17`;
- `LongRunRecording.swift` (timescale 480000, which 44.1 kHz doesn't divide;
  its own segment format at `:717-768`);
- `RecordingPerformanceContracts.swift:8-10`.

## Order of work

This follows vendor-plan Part A step 1 (DeviceAPI exists). Each step keeps the
FX3 4K59.94 path identical. Andrew checks it live after B2, B3, B5 and B6.

- **B0. Fix now.** The live items in the "Fix now" table. These are
  independent of everything else, and can land today.
- **B1. Contract, no behaviour change.**
  - Add `SourceFormat`, `FrameRate`, `Colorimetry`, `SourceAudioFormat`,
    `Timecode` and `PixelFormatTable` to Shared, so the extension compiles
    them.
  - DeckLink fills them.
  - Every gate in section 1 compares against the declared format and the
    table, which still contain only today's entries.
  - Convert section 12 to time and bytes.
  - Write explicit settings values (section 13) and migrate gamut strings to
    IDs.
- **B2. Size and aspect.**
  - Section 2, plus the row-bytes gate.
  - The Lanczos upscale fix, the `untouched` fix, and a "Source size" target.
  - Pools sized by bytes.
  - DeckLink offers its HDMI modes at every resolution.
  - First new capability: 1080p and 720p from an UltraStudio.
- **B3. Rate and time.**
  - `FrameRate` replaces `inputFast` everywhere.
  - Native timescales for capture, Program, recording and the timeline (schema
    bump).
  - The `Timecode` struct, rate-correct drop-frame, and keyframe intervals in
    seconds.
  - Extension `validFrameDurations` and new `FrameRateTarget` cases.
  - DeckLink accepts every rate it detects (23.976 to 60, plus 100/119.88/120
    where the hardware supports them).
  - VFR recording as decided (decision 1).
- **B4. Colour.**
  - `Colorimetry` from the plugin, and one CV-attachment writer.
  - LUT input and output spaces.
  - One shared source declaration (inspector and monitor) with the missing
    MonitorKit log curves.
  - Program colour target, with GPU conversion.
  - Chroma siting and full range.
- **B5. Pixel formats.** Each table entry lands with:
  - the input kernel, plus LUT, Program, recording repack, extension fill and
    monitor;
  - conformance tests.

  A format missing any of those GPU routes is refused at admission, not
  shipped half-done.

  Order: 12-bit 4:2:2, then `420v`/`420f`, then `2vuy`/`yuvs`, then 4:4:4 and
  RGB. The recording profile matrix also lands here.
- **B6. Audio.**
  - `SourceAudioFormat` end to end: other rates, channels and sample types;
    the channel layout in files; N-channel meters; the auto-switcher input;
    queue limits in seconds.
  - Clock domains, with host-time placement for unpaired audio.
  - Takes without audio, and the audio-only decision.
  - DeckLink enables all embedded channels.
- **B7. Interface and device.** The connector setting, the per-device EDID
  setting, shared versus exclusive sources, pause-tolerant sources, and
  GPU ingest for CPU-memory sources.
- **B8. Wording and stored text.** Section 14, the structured format display,
  the usage strings, the README, and supported-modes text.
- **B9. Estimates and cleanup.** One recording estimator, and remove or tie
  the test-only code (section 15).

### Parallel work

To run steps as parallel subagents, split them by file ownership:
- **capture/backend** (`UltracamBackend.mm`, `CaptureController`);
- **GPU** (`LUTProcessor`, `LUTShaders.metal`, `ProgramNormalizer`);
- **extension** (`CameraProvider`, `VideoContract`, `VideoBufferLayout`);
- **recording** (`Sources/Recording`);
- **UI** (`UI*.swift`, `AppSettingsStore`).

B1 has to land before any of that split can start, because every owner needs
its types.

## Verification

- **Synthetic sources.** The fake capture plugin (vendor plan) gains a mode
  for each table entry, size and rate: 720p25, 1080p23.976, 1080p50, 4K59.94
  v210, 4K 12-bit, 1080p 4:2:0 full range, `2vuy`, 4:4:4, and VFR. Each runs
  through the end-to-end checks.
- **The counts.** Each mode must show zero lost frames to preview, extension,
  recording, monitor and Program.
- **The CPU-pixel check** passes on every commit.
- **CPU conversion count:** zero CPU-converted frames with the compatibility
  setting off. With it on, a format that has no GPU route yet shows its CPU
  count and badge.
- **Recordings** are checked for:
  - their timescale;
  - per-frame duration: exact for constant-rate sources; for VFR, as decision
    1 settles;
  - `tmcd` drop-frame;
  - colour tags;
  - audio channel layout.
- **Extension:** an old client (an already-running Zoom) keeps working across
  the format-list and registry changes.
- **Live:** after each of B2, B3, B5 and B6, Andrew checks the FX3 at 4K59.94
  with the full chain (LUT, monitor, record, Program).

## Decided

- **CPU conversion** (2026-10-26): GPU only by default; CPU conversion only
  behind "Allow CPU conversion (compatibility)", off by default. See "GPU by
  default".

## Decisions needed

1. **Variable-frame-rate recording.** Recommendation:
   - **Default:** record every frame with the source's own timestamps (a VFR
     file). Nothing is repeated or skipped.
   - **Optional:** a per-camera "Constant frame rate (compatibility)" setting,
     off by default, shown only for sources that declare
     `FrameRate.isVariable`. It conforms the take to the nominal rate for
     editors that mishandle VFR, repeating or skipping whole frames (never
     blending) and counting each one.
2. **Program rate conversion:** repeating or skipping frames when a source's
   rate differs from Program's is rate conversion, not drop-when-busy. Accept
   that it is counted and shown, or require every source to match Program's
   rate.
3. **Aspect:** letterbox or pillarbox (recommended), crop, or stretch, when a
   source's aspect differs from the output's.
4. **Interlaced SDI (1080i):** refuse it in v1 (recommended), or add a GPU
   deinterlacer.
5. **Audio-only takes:** allow, or keep "video must start the file".
