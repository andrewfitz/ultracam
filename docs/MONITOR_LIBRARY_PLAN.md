# Monitor library plan

Date: 2026-10-21. Status: phase 1 in progress. Name: **MonitorKit**.

Goal: a software equivalent of the monitoring assists on a Sony FX3 and a Blackmagic Video Assist 12G HDR, as a standalone Swift/Metal package that any Apple-silicon app can use. Ultracam is its first client. Using the library must cost nothing compared with code built directly into the app: no extra copies, command buffers, queues, threads or allocations.

Related docs:
- [Device inventory](MONITOR_DEVICE_INVENTORY.md): what each device offers, with sources and the unverified items.
- [GPU pipeline plan](GPU_PIPELINE_PLAN.md): this library **is** §3 "GPU monitor" of that plan. This doc replaces §3's bullets with an API contract. That plan's retirement list (ledger, fairness, adaptive tiers, composite pool, CleanPreviewService, deadlines, AVSampleBufferDisplayLayer picture) and its keep list (pixel-correctness tests) still apply.
- [Color references](MONITOR_COLOR_REFERENCES.md): the classifier math is ported unchanged, because the qualification receipts depend on it.

## Zero-overhead contract

This contract is testable, and each rule has a check in the package tests.

1. **The host's GPU objects.** The library never creates an `MTLDevice`, `MTLCommandQueue`, thread or dispatch queue. It takes the host's device at init and the host's command buffer per frame.
2. **Encode, never commit.** Every per-frame call is `encode(…, into: MTLCommandBuffer)`. The library never commits, waits or adds a completion handler. Scheduling and pipelining stay with the host.
3. **Borrowed inputs.** The source is a texture the host already has: an IOSurface `CVPixelBuffer` through the host's `CVMetalTextureCache`, or any `MTLTexture`. Packed v210 is read as an `rgba32Uint` texture view, the way `LUTProcessor` does it now. No staging copy and no `bytesNoCopy` buffer.
4. **Direct output.** The destination is any texture the host chooses: a `CAMetalLayer` drawable, an offscreen texture, or the host's own output texture (opt-in only).
5. **No per-frame allocation.** Pipelines are compiled at init. Persistent textures (focus mask, scope bins, LUT textures) are created when the format or settings change, never per frame. Parameters go through `setBytes`.
6. **No CPU readback on the frame path.** Scopes are drawn on the GPU from GPU bins. Numbers the UI needs (clip %, peak level) arrive through a small shared buffer that the host reads whenever it likes.
7. **Fusable.** The decode, transfer, classifier, zebra, peaking-weight and guide functions also ship as a Metal header. A host kernel can `#include` it and run decode + LUT + monitor in **one** pass. With linked functions (`MTLLinkedFunctions` as private functions, inlined when the pipeline is built), the same works from a precompiled `.metallib` without the source.

Acceptance, measured on 4K 59.94 v210 with the full picture suite on:
- copies per frame = 0
- command buffers the library creates = 0
- bytes allocated after warm-up = 0
- GPU time per stage is reported; budgets are set from the first measurement, not guessed

A test host checks the same frame encoded inline against the same frame encoded through the library. The pixels must be identical and the GPU-time difference within noise.

## Three integration tiers

| Tier | The host does | Extra GPU work |
| --- | --- | --- |
| **Fused** | Includes the Metal header and calls `mk_*` functions in its own kernel | None; same pass |
| **Encode** | Calls `MonitorPass.encode(frame, state, into: cb, target:)` after its own work | One pass over the destination pixels, plus scopes at their own rate |
| **View** | Puts in `MonitorView` (a CAMetalLayer, display-link driven) and gives it frames | Same as Encode; the view owns only its drawable |

Ultracam uses **Encode** for monitor surfaces and can move the picture pass to **Fused** inside `LUTProcessor` once the GPU plan's step 2 lands.

## Feature matrix

The suite is the union of both devices. Product UI names modes by behaviour, never by device name ("Band zebra", not "FX3 zebra").

### Already in MonitorTools (port, then retire the old package)
- Thirds guide, center cross, safe area (one size)
- IRE zebra, one set, above-threshold or band
- False color: Sony S-Log3 pattern, ARRI-style on S-Log3 (LogC3/LogC4 bands), EL Zone (still labelled unavailable)
- Source-resolution focus peaking, 5 colours, sensitivity, noise rejection
- RGB parade and luma waveform (spatial)

### To build (signal-only, no camera metadata needed)

**Exposure**
- Two zebra sets, shown together. Each set is **Band** (level ± range) or **Lower limit** (level and above). Presets 70–100 and 100+ IRE, plus custom levels in 1-IRE steps. Different stripe angle per set.
- Fixed 6-band false color on display-referred video: purple, blue, green (middle grey), pink (+1 stop / skin), yellow (near clip), red (clip). Blackmagic doesn't publish the band edges, so we pick them, document them in code and label them "Ultracam convention".
- User-defined false-color scale (bands in IRE or stops, with colours), saved as a versioned profile.
- Clip indicators: per-channel over/under highlight, plus clip % readouts.

**Scopes** (every pixel, persistent bins, rate chosen by the host, the picture never waits)
- Waveform: luma, RGB overlay, RGB parade, YCbCr parade
- Vectorscope: 1×/2×/4× zoom, 75% and 100% targets, skin-tone line, Rec.709 and Rec.2020 target sets
- Histogram: luma, RGB overlay, RGB parade
- Graticules: IRE/percent, 10-bit code values, HDR nits for PQ and HLG (ticks 0.1 to 10,000 nits)
- Display controls: scope brightness, background opacity, overlay or PiP placement
- High quality: threadgroup-local accumulation, then global merge; log intensity mapping; phosphor-style trace; 16-bit float rendering

**Focus**
- Peaking with two styles: coloured edges, or brightened detail ("Peak"). Levels Low/Mid/High plus a continuous control. Colours red, yellow, blue, white, green.
- Magnify: 1:1 pixel, 2×, 4×, and continuous pinch zoom. Pan, plus an inset that shows the zoomed region. Sharp sampling (nearest for 1:1, bicubic otherwise). Overlays stay correct while zoomed.
- Blue Only (blue channel in greyscale) and a true luma monochrome view

**Framing**
- Aspect guides: 9:16, 4:5, 1:1, 4:3, 13:9, 14:9, 15:9, 16:9, 17:9, 1.66, 1.85, 1.91, 2:1, 2.35, 2.39, 2.40, plus custom. Line or matte, with opacity and colour.
- Safe areas: 80%, 90%, 93% action and custom
- Grids: thirds, square, diagonal + square, crosshair, center dot. These combine freely.
- Anamorphic de-squeeze: 1.3, 1.33, 1.5, 1.6 (applied as 1.65, as Sony does), 1.66, 1.8, 2.0, custom
- Flip: horizontal (mirror), vertical, 180°
- Guide lines are drawn analytically in the shader, anti-aliased and pixel-exact at any zoom, with no line textures.

**Color pipeline**
- Display 3D LUT: .cube 17/33/65, plus 1D shaper. Tetrahedral interpolation for quality, hardware trilinear for speed. Applies to the monitor only unless the host routes it elsewhere.
- Analytic display transforms (no LUT): S-Log3→709, HLG→709, PQ→SDR tone map
- Monitor-only brightness, contrast, saturation, and white-point trim (temperature/tint)
- HDR viewing: EDR on Apple displays (rgba16Float layer, PQ or HLG colour space). Signal override: Auto, Rec.709, Rec.2020 SDR, HLG, PQ at 300/500/800/1000/2000/4000 nits.

**Audio** (CPU, vDSP on the host's audio buffers, well under 1% of a core)
- Meters for 2 to 16 channels: dBFS sample peak, true peak (4× oversampled, BS.1770), VU and PPM with −18 or −20 dBFS reference. Peak hold and decay ballistics.
- Optional loudness: momentary, short-term, integrated LUFS
- Results go to a lock-free snapshot, which UI or Metal reads at display rate.

**Status and output**
- Overlays from host-supplied metadata: timecode, rec tally border, format, LUT name, custom labels. Legends and text live in the UI layer, not baked into frames.
- Clean feed: one switch turns every overlay off.
- Each surface chooses its own tool set. Several surfaces can share one frame's analysis (focus mask and scope bins are computed once per frame, not per surface).

### Out of scope (needs camera metadata or sensors the app doesn't receive)
Level gauge, EI/shutter/ISO/aperture readouts, Focus Map (depth), Bright Monitoring, face/eye frames. The status overlay API takes arbitrary host metadata, so a host that has these values can still show them.

## Package layout

```
MonitorKit/
  Sources/
    MonitorKitShaders/   Metal header (mk_*.h) + precompiled .metallib: decode, transfers,
                         classifiers, zebra, peaking, guides, LUT sampling
    MonitorKitCore/      settings model (Codable, versioned), profiles, guide geometry,
                         false-color tables, audio DSP; pure Swift, no Metal
    MonitorKit/          MonitorEngine (pipelines, one per device), MonitorFrame,
                         MonitorPass, ScopeAccumulator/ScopeRenderer, LUT loading
    MonitorKitUI/        MonitorView (CAMetalLayer), SwiftUI controls, legends, meters
  Tests/                 pixel-correctness (ported), zero-copy/alloc contract, GPU timing
  Examples/              minimal AVFoundation host, built in CI
```

All products are static libraries, with strict concurrency on and no actors on the frame path.

## API sketch

```swift
let engine = try MonitorEngine(device: device)                 // compiles pipelines once
let pass = engine.makePass()                                   // per surface: persistent textures
let scopes = engine.makeScopeAccumulator()                     // shareable across surfaces

let frame = MonitorFrame(texture: lumaOrPacked, chroma: chroma,   // borrowed, not retained
                         layout: .v210, signal: .init(range: .legal, matrix: .rec709,
                         transfer: .sLog3, gamut: .sGamut3Cine), geometry: g)

// Host's command buffer, host's drawable
scopes.accumulate(frame, into: cb)                             // when the host wants scope data
pass.encode(frame, state: monitorState, scopes: scopes, into: cb, target: drawable.texture)
cb.present(drawable); cb.commit()                              // the host does this, not the library
```

`MonitorState` is a value type: zebra sets, false color, focus, guides, LUT handle, display adjustments, scope layout. Changing it costs nothing. Only changing the LUT or the format rebuilds persistent resources.

## Phases

1. **Core and picture pass:** package skeleton, contract tests, texture decode (v210, P010, NV12, BGRA, RGBA16F, RGB10A2), the ported classifiers, two zebra sets, every false-color mode, peaking styles, guides/safe areas/grids, de-squeeze, flip, magnify, Blue Only/mono, B/C/S.
2. **Scopes:** waveform (four types), vectorscope, histogram, SDR and HDR graticules, measured at 4K60.
3. **Color and display:** .cube LUTs with tetrahedral interpolation, analytic display transforms, EDR `MonitorView`.
4. **Audio and status:** meters, loudness, metadata overlays, SwiftUI controls and legends.
5. **Ultracam adoption:** replaces `Packages/MonitorTools` as GPU plan step 3. Deletes the old runtime and its policy tests per that plan's list, and retargets the pixel tests.
6. **Extraction:** split the package history into its own repo, tag versions, and switch Ultracam to a SwiftPM URL dependency. Add the example host, API docs and CI.

Building in-tree first, then extracting, keeps Ultracam building while GPU plan step 1 is in progress. The API is designed as if the library were already external: Ultracam imports only public symbols.

## Decisions (2026-10-21)

- **Name:** MonitorKit.
- **Repo:** built in-tree at `Packages/MonitorKit`, then extracted with its history at phase 6.
- **License:** open source (MIT or Apache 2.0, chosen at extraction). The package ships no vendor code, LUTs or trademarks.
- **Phase order:** the picture pass first.

## Added requirements (2026-10-21)

- **Many feeds at once.** One engine per GPU is shared by every feed. Each feed has its own analysis and output objects, and each surface its own picture pass. There are no global locks, no shared per-frame state and no feed limit. Several feeds can be drawn into one drawable, one draw per viewport.
- **Any input or output.** Frames are textures plus a layout and a signal description, whether they come from DeckLink, AVFoundation, ScreenCaptureKit, a decoder or the app's own render. Layouts: v210, 8-bit and 10/16-bit biplanar 4:2:0/4:2:2/4:4:4 (NV12, P010, P210, …), UYVY, BGRA8/RGBA8, RGB10A2, RGBA16F and RGBA32F. The monitor reads all of them. It draws into any render target the host gives it: a drawable, an offscreen texture, or a viewport inside the host's own render pass.
- **Only the LUT moves into MonitorKit.** Decode, resize (Lanczos), color depth/encode and frame rate stay in Ultracam's `LUTProcessor`. MonitorKit provides:
  - the .cube parser
  - the LUT resource: a 3D texture, built once per load
  - the sampling function: tetrahedral, plus a trilinear mode that matches today's output
  
  The app's kernel calls that function in its own pass (the fused tier), so the burned-in LUT costs nothing extra. Monitor surfaces use the same function and the same resource, so preview and output match exactly.
- **LUT routing.** Each LUT is either:
  - **Monitor only:** shown on monitor surfaces, never in output (the FX3 "Display LUT").
  - **Burn in:** applied to the real output feed (the virtual camera, Program, anything the host routes it to) and to every preview of that feed.
  
  Zebras, false color, peaking, guides and every other tool never reach output, in either mode. A monitor-only LUT can be stacked on top of a burned-in one.
- **Signal per tool.** Zebras, false color and peaking each measure the source signal, the output (after the burn-in LUT) or the monitor picture. Everything comes from one decode in the same pass.
- **Freeze** is an explicit snapshot into owned textures. It is the only time the library copies a frame, and only when the user asks.
