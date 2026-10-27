# Full Alpha Pipeline Plan

## Objective

Support alpha end to end for alpha-bearing RGB inputs in both MonitorKit and Ultracam's application pipeline. Preserve alpha through GPU decode, filtering, LUTs, preview rendering, Program normalization, virtual-camera delivery, and alpha-capable recording. Keep YUV inputs opaque with alpha equal to one.

This plan covers Ultracam-owned code and `Packages/MonitorKit` only. It does not modify third-party SDK code or vendor implementations.

## Decisions and invariants

- Alpha-bearing RGB formats are supported: BGRA/RGBA 8-bit, RGB10A2, RGBA16 unorm, RGBA16Float, and RGBA32Float where the platform path exposes them.
- YUV formats remain opaque (`alpha = 1.0`).
- Internal filtering uses premultiplied RGB plus alpha, then converts back to the selected output representation. This prevents halos around transparent edges.
- LUTs and color transforms modify RGB only. Alpha is carried unchanged except where an explicit composite operation changes it.
- Picture overlays are alpha-composited over the picture. Pixels outside the picture are transparent for offscreen targets; display surfaces may explicitly composite onto their configured background.
- Existing opaque output contracts remain unchanged unless an alpha-capable output format is explicitly selected.
- Alpha support must fail closed when a negotiated sink, codec, or surface cannot represent it.
- Alpha is an explicit route/output capability, not an inferred property of a YUV/RGB enum. Unknown straight/premultiplied semantics fail closed.
- Color transforms and LUTs operate on unassociated RGB. Filtering and compositing use premultiplied RGB, with a defined zero-alpha RGB policy.

## Phase 1: contract and format inventory

1. Document the supported alpha formats and straight/premultiplied conventions in `Sources/Shared/VideoContract.swift`, `Sources/Shared/ProcessedFrame.swift`, `Sources/Shared/VideoBufferLayout.swift`, and MonitorKit's public frame documentation.
2. Extend `ColorTarget` and `ProgramOutputFormat` with explicit alpha-capable RGB targets, including their CoreVideo format, Metal format, byte layout, range, and premultiplication metadata.
3. Add capability helpers for alpha presence, planar layout, 4:2:0 geometry, codec compatibility, and whether a negotiated consumer can carry alpha. Thread those capabilities through `ProgramOutputBridge`, `PipelineConfiguration`, `AppSettingsStore`, `UIPresentation`, `UISessionBridge`, `UIInspector`, and the relevant UI state.
4. Keep existing YUV defaults and negotiation behavior unchanged; alpha must be opt-in until every active consumer in a route supports it.
5. Add explicit alpha metadata/attachments to `MonitorFrame`, `SignalDescription`, and `ProcessedFrameMetadata`; do not infer straight versus premultiplied state from the CoreVideo pixel format alone.

Acceptance: every alpha-capable format has one canonical contract entry; unsupported combinations produce a clear error; existing YUV contract tests remain unchanged.

## Phase 2: MonitorKit frame and Metal ABI

1. Add an explicit preserve-alpha mode to the MonitorKit pass/target configuration. Preserve the existing `mk_decode` luma contract while adding an explicit alpha value to the decoded/stage representation, avoiding accidental use of `.w` as alpha or luma. Version/update the shared shader source contract and ABI tests because hosts can embed `MKDecode.msl` directly.
2. Add alpha reads for RGB textures and an opaque-alpha path for YUV/packed formats. Unassociate RGB before LUT/color transforms, then premultiply for filtering/compositing and apply the defined zero-alpha policy.
3. Add alpha filtering that uses the same nearest, box, and bicubic footprints as RGB. Use premultiplied RGB during filtering.
4. Carry alpha through source, output, and monitor stages; LUTs and display transforms must leave alpha unchanged.
5. Update both fragment and compute picture paths, navigator, letterbox, and outside-image behavior.
6. Make overlay operations explicit alpha composites and preserve the selected target's alpha semantics.
7. Verify freeze copies, texture-cache paths, and Metal 4 residency paths retain alpha texels.

Acceptance: raw Metal and CoreVideo-backed BGRA/RGBA8, RGB10A2, RGBA16Unorm, RGBA16Float, and RGBA32Float frames retain alpha through all three stages; YUV decode returns alpha one; fragment and compute output readbacks match including alpha for opaque, fractional, and zero-alpha pixels.

## Phase 3: MonitorKit tests and compatibility

1. Add synthetic alpha gradients and transparent-edge fixtures for every alpha-bearing layout.
2. Test straight and premultiplied inputs, unassociate/premultiply round trips, filtering modes, odd dimensions, clean apertures, navigator, freeze/unfreeze, cache warm-up, and LUT-enabled stages.
3. Read back `rgba16Float`, `rgba16Unorm`, `rgba8Unorm`, and BGRA targets to verify alpha numerically.
4. Add tests for overlay compositing and transparent outside-image pixels.
5. Run the existing MonitorKit core, decode, output-GPU, freeze, cache, and Metal tests.

Acceptance: all new alpha tests pass on the Metal device; existing GPU/color tests remain green; no public frame ABI regression is introduced.

## Phase 4: LUTProcessor, ProgramNormalizer, and app GPU pipeline

1. Extend `LUTProcessor` and `LUTShaders.metal` first: current `fullPackedNV12`, `fullPacked422`, `fullPlanarNV12`, `fullPlanar422`, horizontal-resize, vertical-resize, passthrough, and warm-up paths decode YUV and write opaque YUV. Add RGB alpha-bearing source/output paths, intermediate alpha storage, premultiplied filtering, and alpha-preserving output writes.
2. Carry alpha in `ProcessedFrameMetadata` and `VideoBufferLayout`, including buffer attachments and premultiplication state, so downstream stages do not infer semantics from the pixel format alone.
3. Extend `ProgramNormalizer.Code` and source/destination dispatch to handle RGB alpha-bearing buffers in addition to the existing YUV kernels.
4. Add Metal kernels for RGB resize/copy, straight/premultiplied conversion, and alpha-preserving output writes.
5. Update source and destination texture binding, IOSurface texture creation, pool attributes, and cached-surface keys.
6. Preserve alpha during resize, frame-rate conversion, LUT application, Program handoff, and passthrough. Keep the current zero-CPU-copy and nonblocking GPU behavior.
7. Add output-contract validation so an alpha source cannot silently enter an opaque destination when alpha preservation is requested.

Acceptance: LUT processing and Program normalization preserve a known alpha pattern across identity, resize, LUT-on, and format conversion; YUV normalization behavior and throughput remain unchanged; GPU stalls/backpressure retain current behavior.

## Phase 5: camera and virtual-camera delivery

1. Advertise alpha-capable formats only when the camera extension, sink path, and connected consumer can carry them. Maintain a capability matrix rather than assuming every virtual-camera client accepts RGBA.
2. Update negotiation, format descriptions, dimension validation, and frame validation for RGB alpha formats.
3. Update standby/black-frame generation to produce transparent or opaque black according to the negotiated contract.
4. Preserve alpha in `CameraSink`, `CameraProvider`, sample-buffer creation, and timestamp/discontinuity handling.
5. Add explicit diagnostics when a downstream client requests an opaque-only format.

Acceptance: a negotiated alpha-capable stream receives unchanged alpha; unsupported clients continue to receive the existing YUV formats; standby and recovery frames have documented alpha behavior.

## Phase 6: recording and delivery outputs

1. Extend recording configuration to distinguish opaque YUV profiles from alpha-capable RGB/ProRes 4444 profiles, and probe the actual VideoToolbox encoder capabilities at runtime.
2. Update `Sources/Recording/RecordingPixelConverter.swift` for alpha-preserving conversion and direct passthrough where the encoder accepts the source format.
3. Update `Sources/Recording/AVAssetSourceRecordingWriter.swift`, pixel-buffer pools, format descriptions, encoder capability checks, and source/encoder format validation. Alpha recording should be explicitly limited to combinations that the selected MOV/codec path proves it can encode.
4. Preserve alpha through source recording, Program recording, pause/resume, recovery, and segment boundaries.
5. Reject a requested alpha recording when the selected codec/container cannot encode alpha rather than silently flattening it.

Acceptance: an alpha-capable recording round-trips alpha at representative frames; opaque recordings remain byte/behavior compatible; unsupported codec requests fail before capture begins.

## Phase 7: app surfaces and UI behavior

1. Update `MonitorSurface`, `MonitorRenderer`, `MonitorGPUContext`, and offscreen render targets to preserve alpha where requested.
2. Keep visible window/layer previews intentionally opaque unless the surface configuration requests transparency.
3. Ensure overlays, scopes, guides, zebras, false-color, navigator, letterbox, and status graphics have explicit alpha-compositing behavior. Scopes may remain opaque overlays by policy.
4. Update diagnostics and format labels to show alpha capability and whether the current output is opaque or transparent.

Acceptance: offscreen/program targets retain alpha while normal visible previews remain visually unchanged; UI overlays do not create unintended transparent holes.

## Phase 8: integration, performance, and rollout

1. Add end-to-end tests from alpha-bearing input through MonitorKit, Program, virtual-camera sample delivery, and recording where the platform supports it.
2. Run app Debug build, MonitorKit package tests, GPU readback tests, camera contract tests, and recording tests.
3. Benchmark alpha and opaque paths at 1080p and 4K; keep alpha-disabled paths free of unnecessary work.
4. Measure the extra alpha reads and intermediate bandwidth at 1080p and 4K; add a no-alpha specialization so opaque paths do not pay for alpha filtering.
5. Add logging and counters for alpha negotiation failures, fallback-to-opaque decisions, and unsupported codecs.
6. Roll out behind an explicit alpha-capable output setting, then make it default only after platform compatibility is confirmed.

Acceptance: end-to-end alpha behavior is documented, tested, and observable; opaque workloads show no material regression; every fallback is explicit and diagnosable.

## Risks and limits

- CoreVideo and VideoToolbox support for alpha-capable formats varies by OS, codec, and hardware. Capability probing must be runtime-based.
- Virtual-camera clients may only accept YUV and may force an opaque conversion.
- ProRes 4444 and other alpha codecs may not be available for every recording configuration.
- Premultiplied versus straight alpha must be encoded in the contract; guessing from buffer contents is unsafe.
- Scope and false-color tools measure RGB signal values and should not treat transparent pixels as valid camera signal unless explicitly configured.

## Completion gate

The feature is complete only when MonitorKit, Program normalization, camera delivery, recording, and app surfaces either preserve alpha end to end or explicitly report the exact boundary where the negotiated platform contract is opaque.
