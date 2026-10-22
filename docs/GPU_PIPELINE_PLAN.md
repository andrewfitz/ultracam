# GPU pipeline plan

Date: 2026-10-21. Goal: every frame, fully on the GPU, no CPU pixel copies, and no "drop when busy" rules anywhere. From four read-only audits (capture, processing/output, monitor, recording). Nothing here is built yet.

## Root cause of most copies

The build uses DeckLink SDK 12.0 (`cache/ultracam/decklink-sdk/DeckLinkAPIVersion.h`, fetched from a pinned OBS copy). Its branch in `UltracamBackend.mm` wraps driver memory with `CVPixelBufferCreateWithBytes`: v210, no IOSurface. Every consumer that needs an IOSurface or Metal then copies or re-maps the frame (22.1 MB at 3840×2160 v210, 1.33 GB/s at 59.94).

Fix: the UltraStudio writes into IOSurfaces. **Now on SDK 16.0** (`ThirdParty/DeckLinkSDK`, in the repo). Its default input allocator captures into IOSurface-backed buffers, and the backend's existing `CreateCVPixelBufferRef` branch is now the one compiled. The options below are for controlling the pool size, if the driver's default proves too small.
- Preferred: the current Desktop Video SDK (download from Blackmagic; registration required). Use its buffer-allocator provider and verify `CVPixelBufferGetIOSurface != nil` at runtime.
- SDK 12 fallback: `IDeckLinkInput::SetVideoInputFrameMemoryAllocator` with an `IDeckLinkMemoryAllocator` that returns base addresses of pooled v210 IOSurfaces (10,240 B/row, 16 KB aligned, 16–24 surfaces, growable). Map base address → surface; wrap with `CVPixelBufferCreateWithIOSurface`; keep the DeckLink frame AddRef'd until the last consumer releases the pixel buffer.

## Findings by stage

**Capture ingest** (`CaptureController`, `CameraSink`, `GPURawFrameCopy`, `SharedMetalBuffer`)
- Processing off: each frame is staged into a pool IOSurface by a GPU blit with `waitUntilCompleted` on the capture queue, or a CPU row copy if wrapping fails.
- Processing on: each frame locks the buffer, calls `mach_vm_region`, and maps a new 22 MB `makeBuffer(bytesNoCopy:)`. If alignment fails, `LUTProcessor` does a 22 MB CPU memcpy.
- One serial queue does all per-frame work and waits for the GPU. Only one frame is ever in flight.
- Camera connect and reconnect (`establish` → `discoverDevices`, up to 3 s) run on the frame queue.
- `GPURawFrameCopy` creates its own device and queue, and is rebuilt on idle or a contract change.

**Processing** (`LUTProcessor`, `LUTShaders.metal`)
- The frame-rate gate runs after the GPU work, so at 59.94 → 29.97 half the rendered frames are thrown away.
- `rgba32Float` intermediates: about 490 MB of traffic per frame. The LUT does manual trilinear interpolation with 8 buffer reads per pixel.
- Four compute encoders per frame; decode+LUT and scale+encode can be fused.

**Monitor** (`Packages/MonitorTools`)
- A CPU memcpy of the whole picture into a newly allocated `CVPixelBuffer` on every analysed frame, plus extra staging copies when the source and picture differ.
- Skips everywhere:
  - try-locks in the sink and ledger, plus a rate limiter
  - fairness round-robin, 3 analysis slots
  - working-set, clean, output and scope leases
  - composite pool capped at 8 buffers
  - a 0.25 s deadline
  - quality tiers: 1080p/720p picture cap, scope stride 2/4, scope capped at 12 Hz
- Utility-QoS worker, nine queue hops, an AVSampleBufferDisplayLayer per surface, and a new sample buffer and format description per frame.

**Recording** (`Sources/Recording`)
- VideoToolbox very likely CPU-copies each non-IOSurface v210 frame into its own pool.
- The capture thread takes the writer lock (`_ = telemetry`), which the encoder callback holds during file creation and appends.
- Free-space syscalls on every sample (about 120/s).
- Drops:
  - queue limit 12, shared by audio and video
  - an encoded frame is dropped when the writer input isn't ready
  - audio pending cap of 64
  - timecode not ready

**Output and Program**
- Drop points:
  - CMIO sink queue only 3 deep
  - preview ring of 24, which allows about 400 ms of latency and forces 64 output buffers
  - Program route keeps only the newest frame, and passes through the main actor per frame
- Camera extension: a new format description per standby frame; sink polling adds up to 8 ms.

## Design

1. **Zero-copy ingest.** We own the IOSurface pool (above). One `CVPixelBuffer` per frame goes to the GPU, the preview, CMIO and VideoToolbox unchanged. Wrap each surface for Metal once and cache it by IOSurface ID. Remove `CameraFrameStager`, `GPURawFrameCopy` and the per-frame `SharedMetalBuffer` from the steady state.
2. **Pipelined processing.**
   - Apply the frame-rate gate before the GPU.
   - Encode, commit and return. Fan out to preview, CMIO, monitor and Program from the completion handler, on one delivery queue, in commit order.
   - Keep 3 frames in flight; size the pools to in-flight count plus downstream retention.
   - Use `rgba16Float` intermediates or fused passes; the 3D LUT texture with hardware trilinear needs a banding check.
   - Use one shared device and queue, kept warm.
3. **GPU monitor.**
   - Per surface, a CAMetalLayer driven by the display link.
   - Ingest is an atomic "latest frame" slot per target, with no locks.
   - Each vsync runs one pass:
     - sample the source (v210 via the cached buffer or texture) or the output planes (CVMetalTextureCache)
     - apply the existing minify, false color, zebra and peaking shader code
     - write into the drawable; focus keeps its separate source-resolution mask pass
   - Scopes: their own command buffer at the user's rate, every pixel, persistent bins and textures. The picture never waits on them.
   - Freeze blits the frame into owned textures.
   - Shaders compiled into a .metal resource.
   - Retire:
     - the ledger, fairness, adaptive policy and tiers, critical-pipeline gating
     - the composite pool, CleanPreviewService and deadlines
     - the AVSampleBufferDisplayLayer picture and presentation admission
4. **No skip rules.**
   - Remove the capture admission limit, pool backpressure drops, the preview ring replacement, and the recording queue and writer drops.
   - Size the queues for real stalls.
   - If a stage truly cannot keep up, that is an error that is shown and counted, never a silent drop.
5. **Off the frame path.**
   - Camera connect and reconnect run on a control queue, with an atomic sink swap.
   - Recording never blocks capture: telemetry in atomics, writer appends on their own queue.
   - Disk-space checks about once a second.
   - Program route pumped from the delivery queue.
   - Thread priority raised for capture and delivery: the realtime and workgroup policy, not just QoS.

## Order

1 → 2 → 3 → 4/5. Each step: unit tests, UI checks, self-test, then a hands-on check with the UltraStudio and per-stage counters (copies, frames in flight, presented FPS, late vsyncs, GPU time).

## Tests that encode the old behavior

- Monitor: MonitorAdaptivePolicyTests, MonitorCriticalPipelinePolicyTests, MonitorCompositePoolTests, RuntimeResourceReuseTests, the ledger cases in MonitorCoreTests, and the skip/budget cases in MonitorMetalTests: delete with the mechanism.
- Pixel-correctness tests (MonitorQualityTests, false color, El Zone, geometry): keep, with the harness retargeted to the new renderer.
- App: MonitorCoordinatorChecks (30/60 Hz caps); capture tests asserting admission and pool drops.

## Other open items from earlier rounds

From the regression review of the backend audit pass (fixes for the rest are in eb52316):
- **Program mode:** the 2 s pending-cut expiry can drop a cut while a source is still opening, and a cut that expires leaves `automaticRequestPending` set, which wedges fixed-interval cuts (PROG-2).
- **Recording:** the free-space recheck during a take reads a cached value, so it does not catch a filling drive. It goes once disk checks move off the media queue (above).
- **Start Camera:** gives no message when automatic mode can't start (e.g. no Ultracam camera).
- **Installer:** the "Requesting camera extension removal…" status stuck after two failed removals. Not reproduced from code; ask where it was seen.
- **Extension:** the ObjectIdentifier request match can in theory match a new request at a reused address.
- **AppModel:**
  - `chooseLUT(feedID:)` for a non-selected camera drops the selected camera's in-flight LUT restore.
  - `applySelectedDescriptor` no longer clears `loading`.

From the UI rounds:
- ⌃1–⌃4 labels in the strip ⋯ menu, skipped because of the risk of a duplicate key handler.
- Program format normalization (one fixed Program contract plus conversion), which touches AppModel, AutomaticFeedPolicy, FeedRuntime, ProgramOutputBridge, CameraSink and the effect stage.

Live state to recheck after the rebuild:
- **Tearing and jumps in the preview:** the cause is unconfirmed. The leading suspect is monitor composite-pool reuse while WindowServer still displays the buffer; the pool revert is uncommitted. The rebuild removes that path.
- **Camera extension:** v6 is built but not installed by macOS; the user still needs Install Camera and possibly a reboot.
- **Concurrent edits:** Grok edited the monitor sink, coordinator, diagnostics and FULL_AUDIT.md (uncapping the monitor rate). Merge with those edits, don't overwrite them.
