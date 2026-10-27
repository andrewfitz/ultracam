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

The contract is established before the first frame of a run. On Part A's
serialized delivery stream, `CaptureEvent.formatChanged(SourceFormat)` must
precede the first frame of that format. Its delivery envelope and every
`CaptureFrameInfo` carry a `CaptureEpochID` and the format signature. A changed
size, pixel format, scan mode, declared rate, clock domain or colourimetry
starts a new epoch. A source-clock reset also starts a new epoch even when the
format is unchanged. Consumers drain or explicitly retire old work before
accepting the new epoch; late callbacks cannot enter the new route. Recording
must finalize or visibly stop if the new contract cannot fit the active take.

The format signature is a deterministic digest of a versioned canonical
encoding of `SourceFormat` and the relevant pixel-table entry revision, computed
once per declaration. Specify key ordering, enum IDs and rational/time
normalization; neither default Codable output nor Swift's randomized `Hasher`
is a persistent signature. It describes format content, not a capture run.
`CaptureEpochID` separately combines a fresh session UUID for each start with
a monotonically increasing epoch counter. Reconnecting to an identical format
therefore preserves its signature but gets a new session identity. Ordinary
clock-estimator updates change neither the signature nor the epoch.
Clock-domain kinds belong to format content; runtime clock-instance IDs and
their bindings do not. Replacing a clock instance starts an epoch even when
the canonical format signature stays the same.

Part B also extends Part A's ordered contract with
`CaptureEvent.audioFormatChanged(SourceAudioDeclaration)`. An initial
declaration precedes the first video frame or audio packet, distinguishing
known absence, a known format and discovery still pending. Recording admission
requires a resolved declaration; receiving the first audio packet is too late
to decide which writer inputs to create. Audio presence, format or clock-binding
changes start a new epoch, including when the video format is unchanged; emit
the current video and audio declarations before media in that epoch. B6 must
update the Part A API, adapter and all bundled plugins together.

### GPU by default; CPU conversion only as an opt-in compatibility setting

Ultracam builds for arm64 only (`generate_project.py`, `ARCHS="arm64"`) and
targets macOS 26. So every Mac it runs on is Apple Silicon, with a GPU and
unified memory, and every route the app designs is a GPU route.

Metal 4 is required. The app and camera extension check Metal 4 support and
resource creation before starting GPU work, and report an actionable error if
unavailable. There is no Metal 3 fallback. The CPU conversion setting does not
bypass this requirement.

Decided on 2026-10-26: CPU conversion survives only behind one setting.

**The setting.** Settings gets "Allow CPU conversion (compatibility)". It is
global, persisted [P], and **off by default**.

The value is sampled when a capture session or take starts and remains fixed
for that session/take. Changing it never changes the route of an in-flight
frame; the next session reports the new policy in diagnostics and its sidecar.

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
  - **Primary path:** where the SDK lets us supply the frame allocator, the
    plugin gives it IOSurface-backed, page-aligned memory, and the GPU reads
    the frame in place.
  - **Otherwise:** use `makeBuffer(bytesNoCopy:length:options:deallocator:)`
    only after the SDK's allocator contract establishes a valid owned range.
    Read `vm_page_size`; check arithmetic for overflow, align the start down
    and the end up, and pass the pixel offset to the kernel. The **entire
    rounded range** must lie inside a retained backing allocation in one valid
    VM region. Page rounding and a non-nil Metal buffer are not proof of
    ownership or safety. Do not wrap neighbouring heap allocations or cross a
    guard page. Validate every plane's stride, extent and offset. If these
    guarantees cannot be established, refuse ingest or use the counted CPU
    compatibility copy when enabled.
  - **Under Metal 4,** each wrapped buffer must be in an `MTLResidencySet`
    before use. Residency-set updates are serialized because the API is not
    thread-safe. Cache by allocation identity (base pointer, length and an SDK
    allocation-generation token), not by pointer alone. A cached wrapper pins
    the allocation for its whole lifetime; each submission separately retains
    a frame lease preventing SDK writes/reuse until GPU completion. If the SDK
    offers only a frame lease, discard the wrapper and residency membership
    after GPU completion and before releasing that lease; do not cache across
    frames. `deallocator: nil` is safe only with this explicit external owner.
  - **Unpack** with the format's GPU kernel straight into an IOSurface pool.
    That GPU write is the same format conversion any non-native format gets.
    The plugin keeps the vendor frame alive until the command buffer
    completes.
- **Enforcement:** two checks.
  - **A grep check** fails if CPU pixel APIs appear in `Sources/`, `Vendors/`
    or `Packages/MonitorKit/Sources` outside an allowlist. Tests are exempt.
    The APIs:
    - `CVPixelBufferLockBaseAddress` and `CVPixelBufferGetBaseAddress*`;
    - `IOSurfaceLock` and `IOSurfaceGetBaseAddress*`;
    - `MTLTexture.getBytes`/`replace(region:)`;
    - `vImage`;
    - `VTPixelTransferSession`.
    Also inventory `memcpy`/`memmove`/`memset`, `MTLBuffer.contents` and the
    `CVPixelBufferCreateWithBytes`/`CVPixelBufferCreateWithPlanarBytes` APIs.
    These are review triggers, not proof of CPU video conversion: the same
    APIs handle uniforms, statistics, PCM and zero-copy buffer wrappers. New
    unclassified call sites fail lint until classified. CPU video payload
    access belongs only in the compatibility converter or test fakes.
  - **A structural check** covers what a grep can't see: VideoToolbox converts
    internally when handed a format its encoder doesn't take. A recorder test
    asserts that the encoder's input format equals the GPU repack's output
    for every table entry, unless the setting is on.
  The allowlist is scoped to exact symbols or call sites, with a reason and
  the kind of data accessed. No whole production file is exempt. It includes:
  - the 2×2×2 identity LUT upload (`LUTProcessor.swift:343`), which is LUT
    data, not video;
  - one `CPUCompatibilityConverter` type, which is the only code that may
    touch pixels on the CPU, and runs only when the setting is on;
  - non-video uniform uploads in `MonitorGPUContext`, statistics-buffer
    initialization in `ScopeAccumulator`, and aggregate statistics reads in
    `ScopeStatisticsReader`; these never copy video frames;
  - the PCM shuffle in `EmbeddedAudioRecording`, scoped to that operation.

  - **Exempt from the grep:** comments, test-support fakes
    (`Sources/DeviceAPI/Fake*.swift` write CPU test patterns). A test-only fake
    exemption never permits the same path to run in a production session.
  - **The one current video violation** is the extension's standby fill
    ("Fix now"). The `VTPixelTransferSession` hit at
    `RecordingPixelConverter.swift:12` is a comment.

### The contract types

These live in `Sources/Shared`, so the extension compiles them too.

```swift
struct Rational: Hashable, Codable, Sendable { var numerator: Int, denominator: Int }

struct CaptureEpochID: Hashable, Codable, Sendable {
  var sessionID: UUID
  var epoch: UInt64
}

struct SourceFormat: Hashable, Codable, Sendable {
  var width: Int, height: Int
  var pixelAspect: Rational              // 1:1 for nearly everything
  var scan: Scan                         // reported so admission can refuse interlaced/PsF
  var pixel: PixelFormatID               // key into the format table
  var colour: Colorimetry                // primaries, transfer, matrix, range, chroma siting (h + v)
  var rate: FrameRate
  var clock: VideoClockDomain
}

struct ClockMapping: Hashable, Codable, Sendable {
  var sourceAnchor: CMTime
  var hostAnchor: CMTime
  var rate: Rational                    // host seconds per source second
}

enum VideoClockDomain: Hashable, Codable, Sendable {
  case hostTime
  case deviceClock                      // kind only; instance is runtime state
}

struct ClockInstanceID: Hashable, Codable, Sendable { var value: UUID }

struct CaptureClockBindings: Hashable, Codable, Sendable {
  var video: ClockInstanceID
  var audio: ClockInstanceID?            // nil for absent/unknown or paired audio
}

enum FrameRate: Hashable, Codable, Sendable {
  case constant(CMTime)                  // exact frame duration, e.g. 1001/24000
  case variable(nominal: CMTime, shortest: CMTime, longest: CMTime)
}

enum AudioClockDomain: Hashable, Codable, Sendable {
  case pairedWithFrames
  case hostTime
  case deviceClock                      // kind only; instance is runtime state
}

struct SourceAudioFormat: Hashable, Codable, Sendable {  // plain Swift fields; the ASBD is derived
  var sampleRate: Double, channels: Int
  var sample: AudioSampleType                    // int16, int24in32, int32, float32
  var interleaved: Bool
  var layout: AudioChannelMap                    // layout tag plus [AudioChannelLabel] for discrete maps
  var clock: AudioClockDomain
}

enum SourceAudioDeclaration: Hashable, Codable, Sendable {
  case unknown                          // discovery pending; recording not admitted
  case absent                           // known to have no audio
  case present(SourceAudioFormat)
}

struct Timecode: Hashable, Codable, Sendable {    // replaces the HH:MM:SS;FF string
  var hours, minutes, seconds, frames: Int
  var dropFrame: Bool                            // from the stream (today the ';'), not the rate
  var fieldMark: Bool?
}
```

Notes:
- `SourceFormat` and its nested values use custom Codable implementations for
  `CMTime` and associated enum cases. Decoding validates positive dimensions,
  a non-zero rational denominator, a table entry for `pixel`, legal scan/rate
  bounds, and `shortest <= nominal <= longest` for variable rates. Invalid
  values are rejected at the plugin boundary.
- Clock domains describe timestamp semantics. Clock-instance IDs, their
  `CaptureClockBindings` and current mappings are runtime state, outside
  `SourceFormat`/`SourceAudioFormat` and their signatures. Bindings accompany
  the ordered epoch declarations; each media delivery resolves its clock via
  that epoch. Equal instance IDs mean the same physical clock; paired audio
  resolves through its paired-frame rule. Host-time bindings use the session's
  host-clock instance and identity mapping. Device-clock IDs may be newly
  allocated on reconnect without changing format signatures. A mapping
  maps `t` to `hostAnchor + (t - sourceAnchor) * rate`; both anchors refer to
  the same instant. Host-time stamps use an identity mapping. Device clocks
  require a mapping before host-timed output; there is no implicit assumption
  that their timestamps start at zero. Validate numeric anchors and a positive
  finite rate before accepting a mapping.
- Mapping updates carry the session/epoch, clock ID, revision and effective
  delivery sequence on Part A's ordered stream. A frame captures the applicable
  revision so asynchronous GPU completion cannot remap an older frame using a
  newer estimate. Ordinary drift refinements preserve the epoch and output
  continuity. A reset, regression or correction outside the accepted tolerance
  is an explicit counted discontinuity and starts a new epoch.
- Recording retains source video timing (relative to the take origin); Program
  uses mapped host timing and a bounded drift estimator. Independently clocked
  audio is converted into the take's video clock, not appended with host PTS;
  section 7 defines the clock composition and PCM drift correction. Paired
  audio retains today's callback pairing rule.
- `ClockMapping` is a Hashable/Codable value, not a `CMClock`; its CMTime
  fields have explicit serialization in the owning type, without retroactive
  protocol conformances on system types.
- `AudioStreamBasicDescription` isn't stored, because it isn't `Equatable`,
  and a retroactive conformance would warn, which is an error with warnings
  treated as errors.
- Drop-frame belongs to the timecode stream, because 29.97 NDF is common.
- The natural timescale is derived, not stored: `CMTime.timescale` of the
  constant duration.

### One shared format table

`PixelFormatTable` (Shared, so the extension has it too) holds one entry per
supported fourCC, and every stage reads its layout from that entry:
- planes;
- Metal formats for each plane (`r16Unorm`/`rg16Unorm`/`r8Unorm`…);
- bit depth and container shift (10 bits stored high in 16-bit words, 8 bits,
  12 bits);
- chroma subsampling;
- the default range, which `Colorimetry.range` overrides (today range is
  inferred from the fourCC at `LUTProcessor.swift:662` and
  `ProgramNormalizer.swift:247`, and v210 has no full-range variant);
- endianness (`r210`, `R12B` and `R10b` are big-endian);
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

The table is also the capability registry. Each entry declares which route
implementations exist, and a generated conformance check fails if a supported
entry lacks an input, LUT, Program, recording, monitor or extension route.
Hand-written fourCC switches are permitted only for decoding details inside
the table's implementation and are checked against the table in tests.

## Fix now

These are bugs in today's code. The ones marked **B0** are pure fixes with
no dependencies, and can land at any time. The ones marked **B1** need B1's
format table or the compatibility setting.

| Where | Bug | Live today? |
|---|---|---|
| `UISupport.swift:131-132`, called from `UISessionBridge.swift:379-381` | `sourceProfile(forGamut:)` returns `"sony-slog3-sgamut3cine"` when the gamut text contains "Cine", and `"sony-slog3-sgamut3"` otherwise. Turning on false colour for any undeclared camera (Rec.709, PQ, ARRI, "Unspecified") declares it S-Log3. "Canon Cinema Gamut" maps to S-Gamut3.Cine. | **Yes**, B0. Return nil when nothing matches. |
| `AppSettingsStore.swift:326` vs `:209,230,254` [P] | A missing `gamut` key decodes as `"S-Gamut3.Cine / S-Log3"`, but new feeds default to `"Unspecified / custom LUT"`. | **Yes**, B0. Make both "Unspecified". |
| `UISettings.swift:660` | "False color works when … declared as Sony S-Log3". Six-band and ARRI modes work without that. | **Yes**, B0. Wording only. |
| `README.md:88-89` | Says 16-bit audio; capture is 32-bit. | **Yes**, B0. Wording only. |
| `UIPresentation.swift:204` | Says "ProRes 422 10-bit"; the recorder writes ProRes 422 HQ (`RecordingModel.swift:14`). | **Yes**, B0. Wording only. |
| `LUTShaders.metal:169-182, 216-225` | The Lanczos path scales the window and `t` by `scale` even when upscaling, so upscales (720p→1080p, 1080p→4K) collapse toward nearest-neighbour. | No: every source is 4K, so the pipeline only scales down. Fix with `max(scale, 1)` before the first non-4K source. |
| `VideoContract.swift:190` | `untouched` treats `resizeTarget == .uhd4K` as "no resize". With a 1080p source, the sink would negotiate 3840×2160 (`CameraSink.swift:211`) and refuse every frame on size (`:315-319`). | No (4K only). Fixed in B2. |
| `SourceRecording.swift:234` | Drop-frame timecode is chosen when `frameRate == .fps2997 \|\| .fps5994`, which is always true, so a 25p take gets a drop-frame `tmcd` track. | No (4K 29.97/59.94 only). |
| `VideoContract.swift:166` | `Int32(title)!` crashes if a rate with a fractional title (119.88, 47.952) is added without an explicit duration. | No. It's a trap for B3. |
| `AVAssetSourceRecordingWriter.swift:65-66`, `:417`, `:480-484`, `:496-497` | Recording's CPU routes: `videoToolboxConverts` when no GPU route exists, a capture buffer that isn't IOSurface-backed, and a failed GPU repack ("Never lose the frame: let VideoToolbox convert it") all hand the frame to VideoToolbox's CPU conversion. | **Yes**, though unused with today's single format. B1: put all three behind the compatibility setting (one `CPUCompatibilityConverter`). Off: no GPU route means the take refuses to start, and a GPU failure is a counted lost recording frame. On: they convert on the CPU, counted and badged. |
| `CameraProvider.swift:413-446` [EXT] | The standby black frame is filled on the CPU (`CVPixelBufferLockBaseAddress` plus `memset`, and a v210 word pattern), tagged 709. Built once per format (`:384`). | **Yes**, B1. Add Metal to the extension target and implement a format-specific GPU standby producer. Planar formats may use clear-load passes; packed formats such as v210 require a verified compute or buffer path because a texture clear may not express their repeating word pattern. Prove every published format on representative Apple GPUs before removing the CPU path. Tags come from the published format. |
| `RecordingModel.swift` vs `UISupport.swift:9-14` | The recorder's space guard (`SourceRecording.swift:94-99`, bytes per pixel) and the UI's time-left estimate (`707`/`354` Mb/s, `fallbackMegabits: 707` at `:36`) disagree by about 2.5× at 59.94. | **Yes**. One estimator, in B9. |

## Inventory

### 1. Admission gates

Each gate compares against constants. Each must compare against the declared
`SourceFormat` and the format table instead.

| Where | Assumes | Generalize |
|---|---|---|
| `UltracamBackend.mm:851` | `GetWidth() != 3840 \|\| GetHeight() != 2160 \|\| != bmdFormat10BitYUV` is fatal | compare against the declared `SourceFormat` and the table |
| `UltracamBackend.mm:866-868` | `rowBytes < 10240`, "3840 × 2160 v210 needs …". 1080p v210 is 5120 bytes, so 1080p fails here even after `:851` is fixed | compare against the declared `SourceFormat` and the table |
| `UltracamBackend.mm:886` | accepts v210 only | compare against the declared `SourceFormat` and the table |
| `UltracamBackend.mm:220-229`, `:812`, `:856` | `supportedFrameDuration` allows only 1001/30000 and 1001/60000; anything else is "UltraStudio supplied an invalid frame timestamp" | compare against the declared `SourceFormat` and the table |
| `UltracamBackend.mm:554`, `:201`, `:560-562` | the mode list is `bmdMode4K2160p2997/5994` only; format detection requires YCbCr422 at 10 or 12 bit and rejects RGB 4:4:4 and 8-bit | compare against the declared `SourceFormat` and the table |
| `CaptureController.swift:1048-1056` | width 3840, height 2160, `tenBit422`, duration fast/slow | compare against the declared `SourceFormat` and the table |
| `CaptureController.swift:971-976` | recording admission: the same four | compare against the declared `SourceFormat` and the table |
| `LUTProcessor.swift:533-538` | 3840×2160 and `tenBit422` | compare against the declared `SourceFormat` and the table |
| `AVAssetSourceRecordingWriter.swift:368`, `:379` | v210 only; size must equal the configured 3840×2160 | compare against the declared `SourceFormat` and the table |
| `CameraSink.swift:83`, `:315-319`, `:328`; extension admit `CameraProvider.swift:219`, `:306`, `:315` [EXT] | `VideoBufferLayout` formats only; the sink compares size and duration exactly (`!=`); the extension allows 1 µs on duration | compare against the declared `SourceFormat` and the table |
| `ProgramOutputBridge.swift:355` | drops frames whose duration differs from the negotiated one | compare against the declared `SourceFormat` and the table |
| `ProgramTimestampMapper.swift:112-115` | rejects a source whose timescale changes | compare against the declared `SourceFormat` and the table |
| `UltracamBackend.mm:201` | only the 2160p mode filter keeps interlaced modes out today; nothing reads field count or dominance | refuse interlaced and PsF at admission from `SourceFormat.scan`, with a clear message (decided: no interlaced support) |
| `UltracamBackend.mm:2008` | refusal text "Unsupported HDMI input … 4K YUV 4:2:2 at 29.97 or 59.94" | the plugin's supported-modes text |

### 2. Size, aspect and scaling

| Where | Assumes | Generalize |
|---|---|---|
| `VideoContract.swift:180-181`, `:178` [EXT] | width and height fall back to 3840/2160 when not downscaling | use the source size |
| `VideoContract.swift:132-137` [P] | `ResizeTarget` is 720/1080/UHD only, with `height = width * 9 / 16` | add "Source size", DCI 4096, and size from aspect; never offer an upscale as a default |
| `LUTProcessor.swift:594`, `ProgramNormalizer` | aspect isn't kept, so 4:3 or 17:9 sources are stretched | fit (letterbox or pillarbox) in the kernel; the policy is a decision below |
| `LUTProcessor.swift:422` | the warm buffer is 4K v210 | warm from `expectedFormat`, or on the first `formatChanged` |
| `RecordingModel.swift:370` | `width: 3840, height: 2160` | take it from the source |
| `ProgramNormalizer.swift:562-578` | box filter for integer ratios up to 4, else 2-tap bilinear; aliases at large ratios such as 8K→720p | multi-tap or two-pass |
| `VideoBufferLayout.swift:22`, `:50` [EXT] | row stride only has to be a multiple of 4 or the component size | check Metal's linear-texture alignment, so third-party buffers map |
| pixel aspect | `kCVImageBufferPixelAspectRatioKey` is only copied (`AVAssetSourceRecordingWriter.swift:56`); no scaler reads it, and `LUTProcessor.swift:974-975` strips the display dimensions on downscale | scale from `SourceFormat.pixelAspect`; tag outputs square |
| `CameraProvider.swift:118-141` [EXT][CLIENT] | the extension publishes only 1280×720, 1920×1080 and 3840×2160, built once when the stream is created. Apple's header says a stream's `formats` "should not change during the life cycle of the associated stream" (`CMIOExtensionStream.h`) | enumerate the **full supported superset** at creation: client output sizes (720p, 1080p, UHD and DCI 4096) × supported `ColorTarget` and output-colourimetry combinations, with valid frame durations for every supported rate; preserve today's entries and append new ones. Section 10 defines complete format identity and staged availability. Portrait sources fit into one of these client sizes; portrait output sizes are not promised until added to the superset. "Source size" picks the nearest pre-enumerated size with an otherwise compatible contract, never a new entry. Unsupported sizes or colour variants need an app/extension update; never add them to a live stream |
| `MonitorSurface.swift:99` | starts at 16:9 until the first frame | use the declared aspect (cosmetic) |
| `UISessionBridge.swift:55-74` | splits the format *string* `"3840 × 2160 · v210 · …"` and forces `"\(height)p"` | use the structured `SourceFormat` |

### 3. Pixel format, bit depth and chroma

| Where | Assumes | Generalize |
|---|---|---|
| `UltracamBackend.mm:1014`, `:1051`; `DoesSupportVideoMode` at `:205-206`, `:1856`, `:1862-1867` | always requests `bmdFormat10BitYUV` | request the detected format. DeckLink's formats (`DeckLinkAPIModes.h:219-228`) are `2vuy` (8-bit YUV), `v210` (10-bit YUV), and 10/12-bit RGB (`r210`, `R10b`, `R12B`, `R12L`, some big-endian). There is **no 12-bit YUV**, so 12-bit 4:2:2 sources arrive as v210. Use `2vuy` for 8-bit and RGB for 4:4:4 |
| `CaptureController.swift:417`, `:1720`; `AppModel.swift:1415` | `capturePixelFormat` and Program `passthroughFormat` are `kCVPixelFormatType_422YpCbCr10` | `expectedFormat` or `formatChanged` |
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
| `inputFast` threaded through `CaptureController.swift:10, 135 (initial `sourceDuration = fastDuration`), 440, 598, 1059, 1315`; `AppModel.swift:1098, 1106, 1171-1174`; `AutomaticFeedPolicy.swift:12`; `LiveTelemetry.swift:47` | the same, at runtime. (`UILiveTelemetry.swift:45` and `UISettings.swift:130` hard-code `nominalMegabits(fast: true)`, which is a 59.94 bitrate assumption; see section 9) | replace it everywhere |
| `UltracamBackend.mm:1847`, `:1865`, `:1872`, `:815` | the mode comes from `inputFast`; stream timescale `inputFast ? 60000 : 30000` (auto mode always 60000), which can't represent 23.976 (2502.5 ticks) or 119.88; the high-frame-rate fallback is `requestedMode == bmdMode4K2160p5994` | the detected mode's own timescale |
| `UltracamBackend.mm:814` | `duration * 30 < timeScale` means "high frame rate" | `FrameRate.nominal > 30` |
| `ProgramTimestampMapper.swift:67`, `:252`; `SwitcherCoordinator.swift:18`, `:23`, `:333` (a 1 ms evaluation timescale); `AutoSwitcherBridge.swift:256-257`; `CameraProvider.swift:387` [EXT] | `programTimescale = 60_000`, and `60_000` for cut and expiry times and the standby cadence | **one common timescale, 240000**, for Program, the mapper, the switcher and the timeline. It is exact for 23.976, 24, 25, 29.97, 30, 47.952, 48, 50, 59.94, 60, 100, 119.88 and 120. A Program-rate timescale isn't enough: a 59.94 source into a 23.976 Program is 400.4 ticks at 24000 |
| `FeedRuntime.swift:484` | `count < 4` caps repeats at 4×, so 7.5 fps into 59.94 under-fills the grid | repeat only within a bounded source-gap window derived from `mayPause` and the configured maximum repeat duration; count each repeat, then report a discontinuity instead of generating unbounded output |
| `VideoContract.swift:155` [P][EXT] | `FrameRateTarget` stops at 60; no 48, 100 or 119.88/120 | add them, and fix the `Int32(title)!` crash first |
| `CameraProvider.swift:84`, `:140-141` [EXT][CLIENT] | default 59.94; min `fps60`, max `fps23976`; `validFrameDurations` only from that list | from the published format |
| `CaptureController.swift:828`, `:948`, `:1044` | any duration change resets drop tracking, the host-time anchor and the gate | in VFR mode, don't treat a change as a mode change |
| `MonitorFeedHost.swift:509` | the source rate is estimated from one timestamp gap | use `FrameRate`; smooth it for VFR |
| `MonitorCoordinator.swift:133-135` | scopes run once per source frame, so 120 Hz scopes at 120 fps | cap the scope rate in time |
| `MonitorWorkspace.swift:463` [P] | `refreshRates = [10, 15, 30]` is stored but ignored | wire it up or remove it |
| `AVAssetSourceRecordingWriter.swift:1121-1122`; `RecordingTimecode.swift:11-46` [F] | the writer already uses `rate.frameDuration.timescale`, but the rate can only be one of `RecordingTimecode`'s two cases | pass the source's `FrameRate`; choose one fixed video-track timescale using the recording timebase rules below |
| `AVAssetSourceRecordingWriter.swift:291-297`; `SourceRecording.swift:176`; `RecordingModel.swift:368-376` [F] | `matchingFrameRate` falls back to the configured rate; the default is `.fps5994`, and the model never passes a rate. **A 25p take is silently labelled 59.94** | pass `FrameRate`; refuse a mismatch |
| `SourceRecording.swift:740-758`; `AVAssetSourceRecordingWriter.swift:1282-1284` | the 60000 frame key; skip detection uses the previous frame's duration, so VFR reports false skips | skip detection only for constant-rate sources |
| `SourceRecording.swift:175` [F] | `maxKeyFrameInterval: 60` counts frames (0.5 s at 120p, 2.4 s at 25p) | `maxKeyFrameIntervalDuration` in seconds |
| `AutoSwitcherTimelineRecorder.swift:300`, `:533`; `Tools/auto-switcher` `model.rs:341` [F] | `timescale 60_000` in timeline JSON (`schema_version 2` at `:239`) | a timescale that 23.976 divides exactly, such as 240000 (also exact for 47.952 and 119.88); bump the schema |
| `UIInspector.swift` and `UIFeedSettingsMenu` frame-rate pickers | 29.97/59.94-centric copy (`CaptureController.swift:596-598` "29.97/59.94") | list the plugin's supported modes |

**Recording timebase.** `CMTime.timescale` is already an `Int32`. The issue is
whether one fixed video-track timescale can represent every incoming timestamp
and duration, including values expressed using different timescales.

- Before opening the writer, use the plugin's declared timestamp timebase(s)
  and frame durations to choose a common exact scale. Compute the least common
  multiple of the required reduced denominators with overflow checks. A
  constant-rate take must represent its frame duration exactly; a VFR source
  with one stable timebase uses that scale when it represents the durations too.
- If no exact common scale fits the writer's supported positive `Int32` range,
  or a VFR source cannot declare its future timebases, use 240000 only after
  validating it as the take's quantization policy. Round absolute timestamps
  relative to one take origin, never accumulate rounded frame durations. Nearest
  rounding has at most half a tick of error per timestamp; measured interval
  error can be one tick. Record the chosen scale and measured maximum errors
  in the sidecar, retaining original timing for quantized samples.
- Validate every sample against the fixed scale. Distinct frame timestamps
  must remain strictly increasing and durations positive. If quantization
  merges timestamps or cannot satisfy the policy, refuse the take at preflight
  or finalize/visibly stop it on a later incompatible sample. Do not discard
  frames or retime them to CFR to hide the failure. Audio uses its own track
  timebase; it need not divide Program's 240000 scale.

VFR duration variation within declared bounds is expected, not a mode change.
For constant-rate sources, distinguish arrival jitter from a change in declared
cadence. Equivalent rational timestamps with different `CMTime.timescale`
values are not a clock reset. Pauses and timestamp discontinuities are explicit
events governed by the source's pause policy, separate from format changes.

### 5. Timecode

| Where | Assumes | Generalize |
|---|---|---|
| `UltracamBackend.mm:425-512`, `:505` | frame labels above `highFrameRate ? 59 : 29` are rejected; a pair-counter detector handles cameras that send full-rate labels without the high-frame-rate flag | take limits from `FrameRate`. Keep the empirical detector (the cameras really do this). Check the frame-pair rules above 30 fps against SMPTE ST 12-1 and ST 12-3 (RP 188 is only the transport). Decide 119.88 drop-frame explicitly |
| `UltracamBackend.mm:818` | timecode is read only when a media handler is set | always, if the plugin supports it |
| `RecordingTimecode.swift:11-46`, `:40-45`, `:327-336` [F] | only `fps2997`/`fps5994`; drop counts and TimeCode32 quanta tied to 30/60 | DF only for the 29.97 and 59.94 families (59.94 drops 4), and only when the stream says DF (29.97 NDF is common); NDF for everything else |
| `RecordingTimecode.swift:124-172`; `SourceRecording.swift:232` | parses the 11-character `HH:MM:SS[:;]FF` string; frames below the nominal rate (`:156` "0–59 at 59.94") | the `Timecode` struct |
| `SourceRecording.swift:159`; `AVAssetSourceRecordingWriter.swift:280-286` | relies on the `UltracamCaptureHostTime` attachment; without it, wall-clock timecode is anchored at first encode | a required plugin field, with "start" or "end" of frame declared |

Implementation policy added during review: VFR movies preserve source
timecode samples in the sidecar rather than fabricating a CFR `tmcd` track.
Define and test generated timecode separately for the opt-in CFR recording
route. This policy is not one of the original decisions confirmed on October 26.

### 6. Colour, LUT space and source declaration

| Where | Assumes | Generalize |
|---|---|---|
| `VideoContract.swift:67-69` [EXT][CLIENT] | format descriptions are always BT.709 | from the selected immutable output-colourimetry variant (section 10); match source colour or explicitly convert into that variant |
| `UltracamBackend.mm:276-307`, `:252` | `applyColorimetry` knows only 601/709/2020 and SDR/PQ/HLG; `kEOTFHDRGamma` gets no transfer; range and chroma siting are never attached | the plugin fills `Colorimetry`, and one shared function writes the CV attachments |
| `LUTProcessor.swift:657-660`; `MonitorFeedHost.swift:584-586` | the matrix falls back to BT.709 unless 2020 or 601. The two copies must change together | one helper |
| `LUTProcessor.swift:983-996` | with a LUT, output is tagged 709 whatever the LUT outputs; without one, HLG/PQ tags carry onto 8-bit 4:2:0 output; there is no transfer or primaries conversion in the output path (MonitorKit converts gamut and decodes log for display only, `Colorimetry.swift:148-160`) | store the LUT's input and output spaces with it; add an optional GPU colour-conversion stage |
| `LUTProcessor.swift:653-656`, `:971`; `ProgramNormalizer.swift:360`, `:370`; `LUTShaders.metal:72` | untagged 4:2:2 chroma: LUTProcessor treats it as left-cosited (`chromaOffset` 0) while ProgramNormalizer samples it centred, so the two paths **disagree today**. Only horizontal position is read: `PlanarSource` samples 4:2:0 vertically centred. Outputs are always tagged `Center` | `Colorimetry` carries horizontal and vertical siting; one shared default for untagged sources (left-cosited, per SMPTE) |
| `ScopeSettings.swift:77`; `UIScopeDescription.swift:114`; `UIInspector.swift:225` | `lutApplied ? .bt709 : source`, "The LUT should output Rec.709" | the LUT's declared output space |
| `UIInspector.swift:16` [P] | the "Input gamut" list (13 entries, Canon/Panasonic/BMD/RED included) is a *label* only; stored values are display strings (`AppSettingsStore.swift:326`) | stable IDs and a migration |
| `UIMonitorToolFalseColor.swift:11-16`; MonitorKit `Signal.swift:95-99` (`LogCurve` sLog3/LogC3/LogC4); `Colorimetry.swift:154` | the monitor's "Camera log" list is Sony and ARRI only, so Log→709 display assist (`UIMonitorToolPicture.swift:130`) and log false colour can't handle C-Log, V-Log, BMD Film or Log3G10 even though the inspector offers them | one source declaration (curve, gamut, range) shared by the inspector and the monitor, with matching MonitorKit curves; a camera plugin may *suggest* it (Sony control knows the camera's picture profile) |
| `LUTProcessor.swift:662`; `ProgramNormalizer.swift:247` | range is inferred from the fourCC, and v210 has no full-range variant | `Colorimetry.range` overrides the fourCC's default |
| `UIScopeDescription.swift:199`, `:264`; `UIMonitorToolFalseColor.swift:62-68`; `FalseColorLegend.swift:23` | "10-bit code values" labels | keep as the convention, but label it as such on 8- and 12-bit sources |

### 7. Audio

| Where | Assumes | Generalize |
|---|---|---|
| `UltracamBackend.mm:1022`, `:627`, `:671`, `:635`, `:680`, `:633`, `:678` | `EnableAudioInput(48kHz, 32bitInteger, 2)`; `channels = 2`; a 96000-frame bound ("2 s" only at 48 kHz). 48 kHz is the only rate the DeckLink SDK has (`DeckLinkAPI.h:278`), so the rate is fine *for this plugin*; only the downstream constants are wrong. `maximumHDMIAudioChannels` is logged (`:1844`) and exposed in diagnostics (`:1312`) but not used to enable channels | enable the most channels the device reports. `EnableAudioInput` probably accepts only 2, 8 or 16 channels: check the SDK manual. Bounds in seconds |
| `EmbeddedAudioRecording.swift:26-33`, enforced at `:151, 155, 238, 242, 277, 281, 327, 418` [F] | 48 kHz, 2 ch, 32-bit in, 24-bit out | `SourceAudioFormat`; output depth chosen from the source |
| `EmbeddedAudioRecording.swift:52-118` | `BlackmagicAudioConverter` assumes Int32 carrying 24 significant bits | converters keyed by sample type, including float and 16-bit; rename it |
| `EmbeddedAudioRecording.swift:363-365` [F] | no channel layout written (needed above 2 channels) | write the `AudioChannelLayout` |
| `CaptureController.swift:1016`; `SourceRecordingAdapter.swift:163` | `bytesPerSample == 4` | from the format |
| `CaptureController.swift:1494-1499`, `:1506`; `SourceRecording.swift:912`; `SourceRecordingAdapter.swift:202`, `:224`, `:360`, `:363` | the literals `/ 48`, `48_000`, `144` (3 ms), `60 * 48_000` | from the sample rate |
| `SourceRecordingAdapter.swift:144-160`, `:343-445`, `:396-397`, `:411` | pairs audio with video by callback order on one thread; unpaired audio gets `offset = 0` (the raw device clock) | `AudioClockDomain`: `pairedWithFrames` keeps today's anchor; `hostTime` and `deviceClock` compose revisioned mappings into the recording video clock, including PCM rate correction as specified below |
| `UltracamBackend.h:71-73`, then `CaptureController.swift:48-51`, `:1431-1447`; `UIPresentation.swift:66-69`; `UIAudioMeterPanel.swift:104, 111, 124`; `AudioMeterTapDisplay.swift:121` | meters are left/right only | N-channel arrays (MonitorKitAudio already takes up to 16 with `standardLayout`) |
| `AudioMeterTap.swift:71-82`, `:96`, `:209`; `AudioMeterTapDisplay.swift:50` | 48 kHz 2 ch; refuses mono and anything other than 32-bit; meters only the first 2 of 8 or 16 channels; the 4096-packet queue is sized for DeckLink callbacks; a one-second window at 48 kHz | configure from the source format; size the queue in seconds |
| `AppModel.swift:996`, `:1002-1004`; `AutoSwitcherBridge.swift:133` | the switcher gets `max(L, R)` RMS against `0.035`; audio packet time and video media time are mixed as if they were one clock | a per-channel or summed voice signal; timestamps tagged with their clock domain. The Rust analyser is rate-generic; the stereo assumption is Swift-side |
| `AVAssetSourceRecordingWriter.swift:1114`, `:1133`, `:1092`, `:1219-1220` [F] | a 48 kHz stereo LPCM input is always added; the file opens only on the first video frame, and stopping before it fails | resolve `SourceAudioDeclaration` before creating writer inputs; `.present` configures audio even if its first packet is late, `.absent` creates video-only, and `.unknown` blocks recording admission. Video is still required to start the file; stopping before video produces no file |
| `SourceRecording.swift:123-134`, `:171-173`, `:652-660` | 12 frames, 256 audio packets, 1 GiB; 256 packets assumes about one per frame (a 96 kHz Core Audio device with 128-frame buffers fills it in 0.34 s and fails the take) | limits in seconds and bytes |
| `UIStatusBar.swift:368`; `UIPresentation.swift:748`, `:756` | "48 kHz stereo from each input", "No embedded audio", "without HDMI" | describe the actual source audio, including "audio from <device>" |
| `Config/App-Info.plist`, `App.entitlements:11-13` | no `NSMicrophoneUsageDescription` and no audio-input entitlement | needed before any webcam or USB audio |

**Recording clock and PCM duration.** The take's common timeline is the source
video clock. Let `V` map video time to host time and `A` map audio time to host
time. Place an unpaired audio timestamp `a` at `V.inverse(A(a))`, then apply the
same video-clock take origin and pause adjustment used for video. A host-time
audio clock uses identity `A`; shared audio/video clocks reduce to identity
composition. Never subtract unrelated audio and video origins independently.
Freeze the applicable mapping revisions for each queued packet, as for video,
and carry effective-sequence changes through a continuous bounded estimator.

The audio-to-video rate is `A.rate / V.rate`. Transforming packet PTS alone
does not change PCM duration: resample independently clocked PCM onto the
writer's fixed sample-rate grid using that rate, maintaining fractional sample
phase across packets. Define and test drift, slew and A/V-error bounds before
admitting this route. Exceeding them is a counted discontinuity and visible
take stop/finalization, not an unreported sample drop or timestamp jump. Audio
resampling is PCM work, exempt from the CPU **video** conversion setting but
scoped in the CPU-access allowlist. Record correction ratios and discontinuities
in diagnostics and the sidecar. Paired audio keeps the existing alignment path;
source video frames retain their timing under the recording timebase policy.

**Audio discovery and changes.** Resolve `.unknown` through an ordered audio
declaration before recording admission. Discovery has a configured deadline
and buffers pending media within both time and byte limits; failure to resolve
or buffer exhaustion refuses the take visibly rather than guessing silence or
dropping its opening frames. Preview may continue while recording waits. Once
resolved, create all writer inputs before `startWriting`. Known-present audio
needs no first packet to create its track; known-absent audio creates none.
If audio later appears, disappears, changes format or changes clock binding,
publish the new epoch/declarations before its media and finalize/visibly stop
the active take before accepting the new contract. A subsequent take uses the
new declaration. Routine mapping refinements remain within the epoch. Part A's
media-level audio metadata confirms this declaration; it cannot substitute for
it. Conformance checks must cover this event ordering for every bundled plugin.

### 8. Program output

| Where | Assumes | Generalize |
|---|---|---|
| `FeedRuntime.swift:17-21`, `:32-37` | `ProgramOutputFormat` comes from `PipelineConfiguration` (inheriting the 3840 fallback and two cadences) and has no colour fields; untouched means v210 4K | Program is its own chosen `SourceFormat`, with size, rate and colour |
| `ProgramNormalizer.swift:14-15`, `:247` | "every format in the pipeline is BT.709 video range"; only `xf22` full range is handled | convert every source on the GPU to Program's colour |
| behaviour of `FeedRuntime` and `ProgramNormalizer` [CLIENT] | a cut from a 709 camera to a 2020/PQ camera flips the Program tags mid-stream | the Program colour stays fixed; sources convert into it |
| `FeedRuntime.swift:484` | at most 4 repeats | see section 4 |
| Program rate conversion | `ProgramOutputRoute` **already** repeats frames to put 29.97 sources on the 59.94 grid, and skips the odd frames of a faster source, counted in `cadenceSkipped` (`FeedRuntime.swift:98`, `:141-147`, `:510`), within the two-cadence world | generalize it to any rate and to clock drift (decision 2), with a bounded repeat window rather than an unbounded repeat loop |

The Program contract is a complete, fixed `SourceFormat` chosen when the
Program client connects: size, pixel layout, colourimetry, pixel aspect and
constant output rate. Sources are converted to that contract before they
reach the Program camera; a source colour change never changes the Program
client's tags mid-stream. The mapper uses the source video clock and host-time
anchor, estimates drift over a bounded window, and reports every repeat, skip,
reset and correction that exceeds tolerance.

### 9. Recording

| Where | Assumes | Generalize |
|---|---|---|
| `RecordingModel.swift:8-10`, `:14`, `:371-372` [F] | `proRes42210Bit` (actually HQ) and `hevcMain10_422` put 4:2:2 in the raw values; HEVC 4:2:2 from an 8-bit 4:2:0 webcam is a needless upsample | a profile matrix (ProRes LT/422/HQ/4444, HEVC Main/Main10/4:2:2) checked against the source (the codec isn't stored, so no migration) |
| `SourceRecording.swift:58`, `:83-88` | `HEVC_Main42210_AutoLevel`; a hardware encoder is required; no level, size or rate check, so 8K120 fails only at session creation | validate before the take starts, and say why |
| `AVAssetSourceRecordingWriter.swift:506-513` [F] | colour tags are copied from the buffer; untagged sources make untagged files | required `Colorimetry` (section 6) |
| `AVAssetSourceRecordingWriter.swift:30-39`, `:110`; `RecordingPixelConverter.swift:57-61`; `ProgramNormalizer.swift:105`, `:108` | 16 pooled x422 buffers "of 33 MB", 6 capture frames, `FrameStartRing.capacity = 256`; 480 idle conversions for "four 59.94 feeds"; 96 and 384 cached surfaces | size by bytes and time |
| `SourceRecording.swift:94-99`; `UISupport.swift:9-14`, `:36`; `UISettings.swift:192` | bytes per pixel 0.444/0.30/0.15; `707`/`354` Mb/s with `fast: true` always; "2160p 10-bit 4:2:2" | one estimator from codec, size, rate and depth, used by both the guard and the UI |
| `RecordingRecovery.swift:62`, `:64`, `:157-175`, `:182` [F] | `.mov` only; a video track is required (no audio-only recovery); depends on the fragmented-movie settings at `AVAssetSourceRecordingWriter.swift:1108-1109` | fine for now; revisit if audio-only takes are allowed |
| `RecordingRecovery.swift:199-200` [P] | the folder bookmark key is `recordingFolderBookmark.feed.<feedID>` | keep feed IDs stable; plugins must not change them |

### 10. Virtual camera extension and client contract

**Published colour contracts.** `ColorTarget` identifies pixel layout/depth;
it does not identify primaries, transfer, matrix, range or chroma siting. The
shared extension catalog must enumerate a finite, explicit set of supported
output-colourimetry variants alongside size, pixel layout, scan and pixel
aspect, plus each entry's allowed rate contract. Rec.709 and Rec.2020/PQ at
the same size and fourCC are distinct entries. Build descriptions, attachments
and standby frames from the selected entry. Match the complete contract in
both app and extension, not just size and fourCC; never retag incompatible
pixels to make admission succeed.

B2 defines this catalog schema and stable append order before publishing new
sizes. Preserve existing entries and their indices. Publish only variants whose
GPU conversion/forwarding and standby routes are implemented and validated in
that shipped build; B4 appends newly supported colour variants via an extension
update, never mutating an existing stream's formats. A feed selects a matching
published colour variant or an explicitly configured GPU conversion to one;
otherwise refuse that output route with a clear message. Program similarly
selects its fixed complete output contract. After a source colour change,
continue an explicitly configured conversion only if it supports the new input;
otherwise renegotiate to a matching entry before delivering frames, or stop
that route.
When app and extension versions differ, negotiate against the installed
extension's actual catalog and reject unavailable variants. Do not assume a
new app's local catalog is already installed in the extension.

**Feed-camera cadence: preserve the confirmed every-frame policy.** Program's
clock conversion does not authorize mandatory CFR conversion on each camera's
own virtual output. Keep today's feed forwarding behavior. Before claiming
VFR feed-camera support, B3 must test source-timed delivery through the actual
CMIO extension and target clients, including pauses, duration bounds, standby
and reconnection. The current exact-duration check is an implementation
constraint, not proof that every virtual camera must be CFR.

**Proposal, not a confirmed decision:** if client testing shows that a VFR
feed needs CFR conversion, specify an opt-in feed-output compatibility option
with separate repeat/skip counts and obtain a product decision before shipping
it. The recording compatibility option does not control the camera output.
Until the route is validated, refuse unsupported VFR camera output with a clear
route-specific message; preview and recording remain available. Do not silently
repeat or skip feed frames. This validation gate does not block the CFR paths.

| Where | Assumes | Generalize |
|---|---|---|
| `CameraProvider.swift:132-138` [EXT][CLIENT] | "keep the original eight indices stable"; one format list for every device | append only |
| `VirtualCameraRegistry.swift:151`, `:183`, `:322-327` [EXT] | schema version 1, checked for exact equality, with no format fields | **keep version 1, and don't add per-device formats**. Formats are the fixed superset above, so the registry needs no format data. If it ever does, add optional fields (Codable ignores unknown keys). A bump to 2 would make an old extension's `validate()` reject the snapshot (no cameras), and `save()` with `current == nil` deletes the backup. A later breaking change should accept `<= current`, not `==` |
| `CameraProvider.swift:381`, `:839` [EXT] | standby black after 0.5 s without frames; checks for frames at a quarter of the frame interval | in time, from the published rate; a VFR or paused source (NDI) shouldn't flash black at 0.5 s |
| `CameraProvider.swift:413-446` [EXT] | the standby fill runs on the CPU per format family, assuming video range and 709 | a GPU clear (B1; see "Fix now") |
| `CameraProvider.swift:656` [CLIENT] | the device model is `"FX3 LUT camera"` | "Ultracam camera" |
| `VideoContract.swift:24`, `:28`, `:32`; `maxFramesInFlight = 3`; `LUTProcessor.swift:697`; `ProgramNormalizer.swift:393` [EXT] | pools of 9 / limit 64 / sink queue 8 / Program 4 count frames, not bytes (64 frames of 8K 4:2:2 10-bit is about 8 GB) | budget in bytes, keeping minimum counts |

### 11. Interface, device and signal

| Where | Assumes | Generalize |
|---|---|---|
| `UltracamBackend.mm:142-172`, `:2048-2060`; `DoesSupportVideoMode` at `:205, 1856, 1862, 1866, 2016` | `HDMILease` forces `bmdVideoConnectionHDMI`, and forces it again when Desktop Video preferences change, so SDI is never used | the connector is a per-device plugin setting (HDMI, SDI, optical), and the lease applies only when HDMI is chosen |
| `UltracamBackend.mm:105-136`, `:1253-1258`; `AppSettingsStore.swift:418`, `:445` [P]; `UISettings.swift:682-685` | EDID HDR advertisement is one global Bool | an HDMI-sink capability owned by the plugin, per device (migrate the global value onto each DeckLink device), done in vendor step 5 |
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
- `SourceRecording.swift:412`: `maximumSkippedFrames = 600`, a third
  discontinuity limit;
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
- **`advertiseHDRToCameras`** becomes a per-device DeckLink setting (vendor
  step 5, leak 2).
- **Recording codec and timecode mode** aren't stored today, so they need no
  migration.
- **`selectedDevice` (`AppSettingsStore.swift:201`, `:222`)** and the
  recording folder bookmark keys stay valid.
- **`MonitorWorkspace.refreshRates`** is wired up or dropped.
- **Unknown raw values fail the whole record.**
  `decodeIfPresent(ResizeTarget/ColorTarget/FrameRateTarget)` throws on an
  unknown raw value, so after a downgrade (or a value a newer build added),
  the whole feed record is lost. Append-only isn't enough: decode leniently,
  mapping unknown values to the default and keeping the rest of the record.
- **New stored settings** from this plan:
  - "Allow CPU conversion (compatibility)", global;
  - the per-camera VFR compatibility setting;
  - the per-camera aspect mode;
  - per-device DeckLink settings: EDID HDR and the connector.

### 14. Product names and format wording

Vendor-name leaks are Part A (vendor plan, "Leaks to close"). These are the
format and interface wording that Part B owns:

- "HDMI" where "input" is meant:
  - `UICameraColumn.swift:150`;
  - `UIMenuBar.swift:675`;
  - `UIFeedSettingsMenu.swift:34`;
  - `UISelfTest.swift:45`;
  - `CaptureController.swift:458`, `:554` ("waiting for HDMI");
  - `UltracamBackend.mm:2008` ("Unsupported HDMI input");
  - `SourceRecording.swift:747`;
  - `AVAssetSourceRecordingWriter.swift:440`.
- "UltraStudio" where "capture device" is meant:
  - `UIHelp.swift:7`;
  - `UIMainWindow.swift:71`;
  - `UIToolbar.swift:87`;
  - `UISelfTest.swift:53`;
  - `UICameraColumn.swift:136`;
  - `AppModel.swift:1191`, `:1269`;
  - `UltracamBackend.mm:846-847`, `1474`, `1809`. (`:1078` says "Blackmagic
    Desktop Video", which is a vendor leak for Part A.)
- "Blackmagic signal flag" (`SourceRecording.swift:897`) and "Blackmagic raw
  audio" (`RecordingModel.swift:126`).
- `UIInspector.swift:290` appends `" · 4:2:2"` to every live format.
- `UIFeedSettingsMenu.swift:4` and `:80` are inside the Sony menu and really
  mean the camera's HDMI output, so they move with the Sony plugin UI (Part A
  leak 7).
- `UISessionBridge.swift:73` reads signal state by matching "no hdmi" and "no
  video signal" in backend messages. It moves to `CaptureEvent`.
- Usage strings:
  - `App-Info.plist:20` `NSCameraUsageDescription` names UltraStudio, and is
    exactly the prompt a webcam triggers;
  - `:22`, the local-network string, names Sony and HDMI, and NDI discovery
    triggers it.
- README lines 11, 47, 376-377, 399-401 and 436 describe the single
  DeckLink/FX3 contract. Line 272 also says "macOS 15 or later"; the app
  targets macOS 26.
- Preview fixtures: `UIContext.swift:114-127`, `:194`, `:212`.

### 15. Test-only recording code

These are used only by their own files and `Tests/`. Delete them, or tie them
to the production path; don't generalize them:
- `ProResRecordingConfiguration.swift`, except `ProRes422Profile` (`:130`),
  which production uses (`SourceRecording.swift:42`, `:59`, `:66`, `:97-98`).
  Keep that type and move it into `SourceRecording.swift`. The test-only
  parts are the `:71-80` rate list, the `:94` 8192 limit and `:122-126`;
- `HEVCRecording.swift:10-17`;
- `LongRunRecording.swift` (timescale 480000, which 44.1 kHz doesn't divide;
  its own segment format at `:717-768`);
- `RecordingPerformanceContracts.swift:8-10`.

## Order of work

Dependencies:
- **B0** can land at any time.
- **B1** starts after vendor-plan step 5:
  - the value types already exist (vendor step 1);
  - the backend has its final name and path (vendor step 4);
  - `CaptureController` consumes typed events and the declared format, not
    the eight legacy closures (vendor step 5);
  - the fake plugin exists for verification (vendor step 1).

Each step keeps the FX3 4K59.94 path identical. Andrew checks it live after
B1 (the standby frame and recording's fallback change), B2, B3, B4, B5 and B6.

- **B0. Pure fixes.** The rows marked B0 in "Fix now":
  - the false-colour S-Log3 bug;
  - the gamut default;
  - the three wording fixes.

  These need nothing else.
- **B1. Contract in force, no behaviour change.** Four commits, each building
  and passing `test.sh`:
  - **B1a. Gates:** DeckLink fills the `SourceFormat`. Every gate in section 1
    compares against the declared format and the table, which still holds
    only today's entries. Session/epoch IDs reject stale deliveries independently
    of format signatures; mapping revisions are not format changes.
  - **B1b. CPU rule:**
    - first land the extension Metal standby proof on the supported GPU
      families; B1b does not remove the CPU fill until that proof passes;
    - add the CPU compatibility setting (stored, with its badge and sidecar
      counts) and `CPUCompatibilityConverter`;
    - put recording's three VideoToolbox CPU routes behind it;
    - replace the extension's standby fill with the verified GPU standby
      producer (including the packed-format proof);
    - add the two CPU-pixel checks (the grep and the recorder test), run by
      `test.sh`.
  - **B1c. Limits:** convert section 12 to time and bytes.
  - **B1d. Settings:** write explicit settings values, add lenient decoding,
    and migrate gamut strings to IDs (section 13).
- **B2. Size and aspect.**
  - Section 2, plus the row-bytes gate.
  - The Lanczos upscale fix, the `untouched` fix, and a "Source size" target
    that maps onto the extension's pre-enumerated sizes.
  - Define the extension catalog's complete colour-aware identity and stable
    append order now. Append validated size variants in this step; B4 appends
    validated colour variants through another extension update. Existing
    streams retain their immutable catalogs until replaced; verify client
    reconnection behavior rather than mutating a live list.
  - Pools sized by bytes.
  - DeckLink offers its HDMI modes at every resolution.
  - First new capability: 1080p and 720p from an UltraStudio.
- **B3. Rate and time.**
  - `FrameRate` replaces `inputFast` everywhere.
  - Native timescales for capture, Program and the timeline (schema bump).
    Program and the timeline use 240000. Constant-rate recordings use a
    timescale that represents their exact frame duration. VFR recording uses
    the fixed track-scale selection and quantization checks in section 4. The
    timeline change includes the Rust side (`Tools/auto-switcher`
    `model.rs:341`) and its tests. `test.sh` already rebuilds
    `libauto_switcher` with cargo before linking (`:31-33`, `:81`).
  - The `Timecode` struct, rate-correct drop-frame, and keyframe intervals in
    seconds.
  - Extension `validFrameDurations` and new `FrameRateTarget` cases.
  - Validate VFR feed-camera forwarding as specified in section 10; mandatory
    feed CFR conversion is not part of this step.
  - DeckLink accepts every rate it detects (23.976 to 60, plus 100/119.88/120
    where the hardware supports them).
  - VFR recording per decision 1 below.
- **B4. Colour.**
  - `Colorimetry` from the plugin, and one CV-attachment writer.
  - LUT input and output spaces.
  - One shared source declaration (inspector and monitor) with the missing
    MonitorKit log curves.
  - Program colour target, with GPU conversion.
  - Chroma siting and full range.
  - Append validated extension colour variants using B2's catalog; complete
    contract matching, GPU standby, and old/new app-extension negotiation.
- **B5. Pixel formats.** Each table entry lands with:
  - the input kernel, plus LUT, Program, recording repack, extension fill and
    monitor;
  - conformance tests.

  A format missing any of those GPU routes is refused at admission, not
  shipped half-done.

  Order: `2vuy`/`yuvs` (DeckLink 8-bit and many webcams), then `420v`/`420f`,
  then RGB 4:4:4 (`r210`, `R12L`), then the NDI formats (`UYVA`, `P216`). The recording profile matrix also lands here.
- **B6. Audio.**
  - Add ordered `SourceAudioDeclaration` events to Part A's API, adapter and
    every bundled plugin. Resolve presence/format before writer admission;
    bound discovery waits and handle audio changes as new epochs/takes.
  - `SourceAudioFormat` end to end: other rates, channels and sample types;
    the channel layout in files; N-channel meters; the auto-switcher input;
    queue limits in seconds.
  - Compose audio-to-host and inverse video-to-host mappings for recording;
    bounded PCM drift resampling onto the take's fixed audio sample grid.
  - Takes without audio; video still starts the file (decision 4).
  - DeckLink enables all embedded channels.
- **B7. Interface and device.** The connector setting (the per-device EDID
  setting is vendor step 5's), shared versus exclusive sources, pause-tolerant sources, and
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

### Take sidecar

The CPU-conversion, cadence and source-format diagnostics use one versioned
sidecar next to each take: `<take>.ultracam.json`. Version 1 contains the
source and output format signatures, session/epoch IDs, runtime clock bindings,
mapping revisions and anchors, resolved audio declaration and clock domains,
PCM drift corrections/discontinuities, recording policy, timestamp timescale
and quantization error, per-stage CPU/repeat/skip/
loss counters, and the final error or discontinuity. It is written atomically
at take start and finish, updated through a bounded journal while recording,
and recovered or deleted together with the interrupted movie. Old sidecars are
read leniently; unknown fields are ignored and missing counters default to
zero.

## Verification

- **Synthetic sources.** The fake capture plugin (vendor plan step 1) gains a mode
  for each table entry, size and rate: 720p25, 1080p23.976, 1080p50, 4K59.94
  v210, 1080p 4:2:0 full range, `2vuy`, RGB 4:4:4, and VFR. Each runs
  through the end-to-end checks for its supported routes. VFR feed-camera
  support additionally requires the real-client checks in section 10; before
  those pass, verify explicit route refusal rather than silent conversion.
- **The counts.** Each mode must show zero source-loss frames to preview,
  recording, monitor and supported feed-camera forwarding routes. Program
  repeats/skips and explicitly selected recording rate conversion must match
  expected counts; load-related drops remain zero in these supported-load
  tests. This is not a promise of lossless operation under arbitrary overload.
- **The CPU-pixel check** passes on every commit.
- **CPU conversion count:** zero CPU-converted frames with the compatibility
  setting off. With it on, a format that has no GPU route yet shows its CPU
  count and badge.
- **Recordings** are checked for:
  - their timescale;
  - per-frame duration: exact for constant-rate sources; for VFR, the source's own
    timestamps, or a constant rate with counted repeats and skips when the
    per-camera option is on;
  - `tmcd` drop-frame;
  - colour tags;
  - audio channel layout.
- **Extension:** an old client (an already-running Zoom) keeps working across
  the format-list and registry changes. The matrix also covers an old app with
  a new extension, a new app with an old extension, and a client reconnect
  after an extension update. Rec.709 and Rec.2020/PQ with identical dimensions
  and fourCC select distinct complete contracts. Check descriptions, frame
  attachments and standby output for each; an old extension refuses unavailable
  variants explicitly, and no live format list is mutated.
- **Contract failures:** tests cover invalid `SourceFormat` values, a frame
  before `formatChanged`, mid-stream colour/rate/size changes, clock drift,
  timestamp regressions, GPU command failure with CPU conversion disabled,
  bounded repeats during a pause, and audio arriving before video.
- **Clock identity:** a non-zero source anchor maps to its paired host anchor;
  ordinary drift updates do not renegotiate formats. A delayed GPU completion
  uses its captured mapping revision. A reconnect with the identical format
  and newly allocated clock-instance IDs keeps its format signature and rejects
  old-session frames. A clock-instance replacement within a session starts a
  new epoch without changing the signature when its format is otherwise equal.
- **Audio admission:** test known absence, known presence with a late first
  packet, unknown discovery that resolves or times out, bounded pending media,
  and audio arriving before video. Every writer input exists before writing
  starts. Mid-take audio appearance, disappearance, sample-format/rate/channel
  changes and clock-instance replacement stop/finalize the take before new
  media; unchanged video alone must not hide an audio contract change.
- **Recording clock alignment:** use non-zero, widely separated audio/video
  clock origins and unequal rates, including host-timed audio and shared-clock
  sources. Verify long-run A/V alignment and PCM duration on the fixed sample
  grid, continuous bounded mapping revisions, retained fractional resampling
  phase, common pause offsets, and visible failure beyond drift/error bounds.
- **Timebases:** test equivalent rational times in different scales, common
  scale overflow, long VFR runs without accumulated rounding drift, and
  timestamp collisions after quantization. A track never changes scale mid-take.
- **CPU-access lint:** allow the named uniform/statistics/PCM operations; reject
  an unclassified call site and video-copy code outside the converter. An
  unrelated call in an allowlisted file receives no exemption.
- **No-copy ingest:** test unaligned ranges, arithmetic overflow, split VM
  regions, missing allocation ownership, pointer reuse with a new allocation
  generation, and SDK release while GPU work is pending. Unsafe wrapping must
  refuse or take the explicitly enabled counted compatibility path.
- **Route coverage:** the format table generates the required route matrix;
  every entry must have input, LUT, Program, recording, monitor and extension
  implementations before it can be marked supported.
- **Live:** after each of B1, B2, B3, B4, B5 and B6, Andrew checks the FX3 at 4K59.94
  with the full chain (LUT, monitor, record, Program).

## NDI readiness

NDI isn't planned yet, but the contract should take it without another
redesign. NDI differs from today's sources in these ways, and the plan
already covers each one:

| NDI trait | Covered by |
|---|---|
| **Its own clock.** The sender runs on another computer's clock, so it drifts against Program even at the same nominal rate | `VideoClockDomain` plus runtime clock bindings and the Program drift estimator (decision 2); independently clocked audio uses `AudioClockDomain.deviceClock`, composed mappings and PCM drift correction for source-timed recording (section 7) |
| **Frames in ordinary memory.** NDI's SDK decodes its full-bandwidth stream on the CPU inside its library, which we can't move | the GPU reads the frame in place through a no-copy `MTLBuffer`; if that memory can't be wrapped, the CPU compatibility setting allows one counted copy |
| **NDI HX** (compressed H.264/HEVC) | not an acceptance criterion for Part B; confirm hardware-decoder and SDK redistribution support before adding the format entries |
| **Formats with alpha and 16-bit formats:** `UYVA`, `P216`/`PA16`, plus `NV12`, `I420`, `BGRA` | format table entries (B5); alpha ignored in v1 |
| **Any size and orientation**, including portrait phone sources | Fit by default (decision 3); feed virtual-camera outputs remain in the pre-enumerated client size superset |
| **Timestamps with jitter around a declared rate** | constant-rate with jitter: a small duration change is not a mode change (section 4) |
| **Planar float audio** at any rate and channel count, not paired with frames | `SourceAudioFormat` and its clock domains (B6) |
| **Sources that pause, and sources shared by several cameras** | pause-tolerant and shareable source flags (B7) |
| **Network discovery** | `NSBonjourServices` with `_ndi._tcp`, and the local-network usage string (section 14) |
| **The NDI SDK licence** | check its runtime redistribution and trademark terms before vendoring, as for AJA |
| **NDI output** (sending Program as NDI) | a future output plugin kind, out of scope here |

## Decided

- **CPU conversion** (2026-10-26):
  - GPU only by default;
  - CPU conversion only behind "Allow CPU conversion (compatibility)", off by
    default;
  - see "GPU by default".
- **Interlaced** (2026-10-26): no interlaced support.
  - Interlaced and PsF signals are refused at admission with a clear message.
  - The plugin reports scan type, so the refusal names the signal.

## Also decided on 2026-10-26 (confirmed by Andrew)

Chosen with NDI and webcams in mind:

1. **Variable-frame-rate recording.**
   - **Default:** record every frame with the source's own timestamps (a VFR
     file). Nothing is repeated or skipped.
   - **Option:** a per-camera "Constant frame rate (compatibility)" setting,
     off by default, shown only for sources that declare
     `FrameRate.isVariable`. It conforms the take to the nominal rate for
     editors that mishandle VFR, repeating or skipping whole frames (never
     blending) and counting each one.
   - **The trade-off:** skipping drops source frames from the file, so turning
     the option on knowingly breaks the every-frame rule for that take. Like
     the CPU setting, it is off by default, and its counts appear in the take
     and in diagnostics.
2. **Program rate conversion: accept it.**
   - **What happens:** Program runs on its own clock. When a source's rate or
     clock differs, Program repeats or skips whole source frames to stay on
     its grid. Each one is counted per source and shown in diagnostics.
   - **Why:** any source on its own clock (NDI, a webcam, or two FX3s without
     shared sync) drifts. So "every source must match Program's rate" can't
     hold even when the rates are equal.
   - **The every-frame rule still holds:** clock matching here is on the
     Program route only. It does not authorize intentional cadence drops in
     preview, source recording, the monitor or the camera's own virtual camera
     (apart from explicitly selected recording rate conversion). Supported
     feed-camera forwarding preserves source frames; VFR client compatibility
     must pass the validation gate in section 10. Overload losses are counted
     separately, as in Part A's bounded-queue contract.
   - **This extends existing behaviour.** Program already repeats and skips
     for 29.97 to 59.94, counted in `cadenceSkipped` (`FeedRuntime.swift:510`).
     The fixed 4× cap (`:484`) is replaced by the bounded repeat window in
     section 4; a paused source cannot create an unbounded send loop.
3. **Aspect: fit by default.**
   - Letterbox or pillarbox in the scaling kernel, with a per-camera
     "Fill (crop)" option. Never stretch.
   - Pixel aspect comes from `SourceFormat.pixelAspect`.
   - Portrait sources (NDI phone apps, 1080×1920) fit with pillarbox.
4. **Audio-only takes: no; video starts the file.**
   - Audio that arrives before the first frame is held for a configured,
     byte-bounded few seconds and lined up when video starts. Overflow drops
     the oldest pre-roll packet with a counted diagnostic; it never opens the
     file by itself.
   - Stopping before any video arrives makes no file and shows "No video
     arrived, so nothing was recorded" rather than an error.
   - True audio-only recording waits for an audio-source plugin kind.
   - The recorder and recovery code (`RecordingRecovery.swift:158-175`)
     assume a video track, and that's the right default for a camera app.
