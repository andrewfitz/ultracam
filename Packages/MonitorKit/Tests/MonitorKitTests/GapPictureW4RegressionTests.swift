import CoreVideo
import IOSurface
import Metal
import XCTest

@testable import MonitorKit

/// Regressions for the W4 gap-picture review: the texture cache treats another
/// ref to the same live IOSurface as a hit, warm-up builds the compute stand-in
/// and the processed (Program) variant, and an untagged buffer can be read as
/// unlabelled code values.
final class GapPictureW4RegressionTests: XCTestCase {
  static let slog3 = SignalDescription(encoding: .log(.sLog3SGamut3Cine))

  func buffer(_ layout: PixelLayout = .v210, width: Int = 66, height: Int = 38, seed: UInt64 = 3) throws
    -> CVPixelBuffer
  {
    try XCTUnwrap(PictureTests.picture(layout, width: width, height: height, seed: seed).pixelBuffer(range: .legal))
  }

  /// A second pixel buffer over the same live IOSurface, reached through another
  /// ref, as a frame from a camera extension or helper process arrives
  /// (`IOSurfaceLookupFromMachPort`, then `CVPixelBufferCreateWithIOSurface`).
  func sameSurface(as pb: CVPixelBuffer) throws -> CVPixelBuffer {
    let surface = try XCTUnwrap(CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue())
    let port = IOSurfaceCreateMachPort(surface)
    defer { mach_port_deallocate(mach_task_self_, port) }
    let other = try XCTUnwrap(IOSurfaceLookupFromMachPort(port))
    XCTAssertFalse(other === surface, "another ref to the surface")
    XCTAssertEqual(IOSurfaceGetID(other), IOSurfaceGetID(surface))
    var out: Unmanaged<CVPixelBuffer>?
    XCTAssertEqual(CVPixelBufferCreateWithIOSurface(nil, other, nil, &out), kCVReturnSuccess)
    return try XCTUnwrap(out).takeRetainedValue()
  }

  // MARK: - Texture cache: one surface, several refs

  /// Alternating two refs to one live surface makes no texture, commits no
  /// residency and leaves the frames' release tokens unmarked after the first lookup.
  func testAnotherRefToTheSameSurfaceIsACacheHit() throws {
    let gpu = try requireGPU()
    let residency = try MonitorResidency(device: gpu.device)
    let cache = MonitorTextureCache(device: gpu.device, residency: residency, idleLifetime: 60)
    for layout in [PixelLayout.v210, .biplanar(.s420, bitDepth: 10)] {
      cache.removeAll()
      let a = try buffer(layout), b = try sameSurface(as: try buffer(layout))
      let b2 = try sameSurface(as: a)
      let first = try cache.frame(a, now: 1)
      _ = try cache.frame(b, now: 1)  // another surface: its own textures
      let made = cache.texturesMade, commits = residency.commitCount, count = cache.count
      var frames: [MonitorFrame] = []
      var i = 0
      while i < 10 {
        frames.append(try cache.frame(i % 2 == 0 ? b2 : a, now: 2 + Double(i)))
        i += 1
      }
      XCTAssertEqual(cache.texturesMade, made, "\(layout): no texture per frame")
      XCTAssertEqual(residency.commitCount, commits, "\(layout): no residency commit per frame")
      XCTAssertEqual(cache.count, count, "\(layout)")
      XCTAssertFalse(first.frozenPlanes?.released.load(ordering: .relaxed) ?? true, "\(layout): still cached")
      for f in frames {
        XCTAssertTrue(f.packed === first.packed && f.luma === first.luma && f.chroma === first.chroma, "\(layout)")
        XCTAssertFalse(f.frozenPlanes?.released.load(ordering: .relaxed) ?? true, "\(layout)")
        XCTAssertFalse(f.secondPlanes?.released.load(ordering: .relaxed) ?? false, "\(layout)")
      }
      // `makeTexture` through the other ref finds the same texture.
      let other = try XCTUnwrap(CVPixelBufferGetIOSurface(b2)?.takeUnretainedValue())
      let packedWidth = layout == .v210 ? (66 + 5) / 6 : 66
      let texture = try cache.makeTexture(
        iosurface: other, plane: 0, format: layout == .v210 ? .rgba32Uint : .r16Unorm, width: packedWidth,
        height: 38, now: 20)
      XCTAssertTrue(texture === (first.packed ?? first.luma))
      XCTAssertEqual(cache.texturesMade, made)
    }
  }

  // MARK: - Warm-up: the compute stand-in

  /// After warm-up, a compute surface's first state change (a tool, clean, a
  /// colour) draws with the warmed all-tools kernel instead of compiling it on
  /// the encoding thread.
  func testWarmUpBuildsTheComputeStandIn() throws {
    let m = try requireMTL4()
    let gpu = m.gpu
    let engine = try MonitorEngine(device: gpu.device, specialization: .asynchronous)
    m.queue.addResidencySet(engine.residency.set)
    defer { m.queue.removeResidencySet(engine.residency.set) }
    let state = MonitorState()
    try engine.warmUp(
      targets: [], layouts: [.v210],
      surfaces: [
        MonitorSurfaceConfiguration(
          target: MonitorRenderTargetFormat(colorPixelFormat: .rgba16Float), layout: .v210, state: state,
          frameSize: (width: 96, height: 54), viewportSize: (width: 96, height: 54), compute: true)
      ])
    let frame = try m.frame(PictureTests.picture(width: 96, height: 54), signal: .rec709)
    let target = m.target(96, 54, format: .rgba16Float, usage: [.shaderWrite, .shaderRead])
    let pass = engine.makePass(), feed = engine.makeFeed()
    let callerBuilt = engine.pipelinesBuiltOnCaller
    try m.run { s in try pass.encodeCompute(frame: frame, feed: feed, state: state, target: target, into: s) }
    XCTAssertEqual(engine.pipelinesBuiltOnCaller, callerBuilt, "the first frame")
    var changes: [MonitorState] = []
    var zebra = state
    zebra.zebras[0].enabled = true
    changes.append(zebra)
    var clean = zebra
    clean.clean = true
    changes.append(clean)
    var transform = state
    transform.displayTransform.mode = .logToRec709
    changes.append(transform)
    for (i, changed) in changes.enumerated() {
      try m.run { s in try pass.encodeCompute(frame: frame, feed: feed, state: changed, target: target, into: s) }
      XCTAssertEqual(engine.pipelinesBuiltOnCaller, callerBuilt, "change \(i) compiled nothing on the encoding thread")
    }
  }

  /// A render surface's stand-in is built for its own target even when `targets`
  /// leaves that format out.
  func testWarmUpBuildsARenderSurfaceStandIn() throws {
    let gpu = try requireGPU()
    let engine = try MonitorEngine(device: gpu.device, specialization: .asynchronous)
    try engine.warmUp(
      targets: [], layouts: [.v210],
      surfaces: [
        MonitorSurfaceConfiguration(
          target: MonitorRenderTargetFormat(colorPixelFormat: .bgr10a2Unorm), layout: .v210,
          frameSize: (width: 96, height: 54), viewportSize: (width: 96, height: 54))
      ])
    let frame = try PictureTests.picture(width: 96, height: 54).frame(gpu, signal: .rec709)
    let pass = engine.makePass(), feed = engine.makeFeed()
    let t = gpu.target(96, 54, format: .bgr10a2Unorm)
    let built = engine.pipelinesBuiltOnCaller
    try gpu.run { cb in try pass.encode(frame: frame, feed: feed, state: MonitorState(), target: t, into: cb) }
    XCTAssertTrue(pass.usesSpecializedPipeline)
    var zebra = MonitorState()
    zebra.zebras[0].enabled = true
    try gpu.run { cb in try pass.encode(frame: frame, feed: feed, state: zebra, target: t, into: cb) }
    XCTAssertEqual(engine.pipelinesBuiltOnCaller, built, "the change drew with the warmed stand-in")
  }

  // MARK: - Warm-up: processed (Program) surfaces

  /// A processed surface resolves peaking and log false colour off, so warm-up
  /// must derive that variant: the first Program frame then draws specialized.
  func testWarmUpBuildsTheProcessedVariant() throws {
    let gpu = try requireGPU()
    let lut = try gpu.engine.warmUpLUT()
    let target = MonitorRenderTargetFormat(colorPixelFormat: .bgr10a2Unorm)
    var state = MonitorState()
    state.focus.enabled = true
    state.falseColor.mode = .sonySLog3
    func configuration(processed: Bool) -> MonitorSurfaceConfiguration {
      MonitorSurfaceConfiguration(
        target: target, layout: .v210, state: state, signal: Self.slog3, frameSize: (width: 96, height: 54),
        viewportSize: (width: 96, height: 54), isProcessed: processed)
    }
    XCTAssertFalse(configuration(processed: false).isProcessed, "camera signal by default")
    let camera = try MonitorEngine.pipelineKeys(for: configuration(processed: false), placeholder: lut)
    let program = try MonitorEngine.pipelineKeys(for: configuration(processed: true), placeholder: lut)
    XCTAssertEqual(camera.count, 1)
    XCTAssertEqual(program.count, 1)
    XCTAssertNotEqual(camera, program, "peaking and log false colour are off on a processed picture")

    let engine = try MonitorEngine(device: gpu.device, specialization: .asynchronous)
    try engine.warmUp(targets: [target], layouts: [.v210], surfaces: [configuration(processed: true)])
    var frame = try PictureTests.picture(width: 96, height: 54).frame(gpu, signal: Self.slog3)
    frame.isProcessed = true
    let pass = engine.makePass(), feed = engine.makeFeed()
    let t = gpu.target(96, 54, format: .bgr10a2Unorm)
    let built = engine.pipelinesBuiltOnCaller
    try gpu.run { cb in
      try feed.analyze(frame, focus: state.focus, into: cb)
      try pass.encode(frame: frame, feed: feed, state: state, target: t, into: cb)
    }
    XCTAssertTrue(pass.usesSpecializedPipeline, "the Program surface draws specialized on its first frame")
    XCTAssertEqual(engine.pipelinesBuiltOnCaller, built)
    XCTAssertEqual(pass.status.reason(for: .focusPeaking), .requiresCameraSignal)
  }

  // MARK: - R14: untagged buffers

  /// An untagged buffer is BT.709 by default (W1 behaviour); asked for strictly it
  /// is unlabelled, so the picture is a code-value view and calibrated tools
  /// report `.requiresKnownTransfer`, as MonitorTools refused.
  func testUntaggedBufferCanBeReadAsUnlabelledCodeValues() throws {
    let gpu = try requireGPU()
    let pb = try buffer()
    XCTAssertEqual(MonitorFrame.signal(of: pb, range: .legal).encoding, .display(.bt709), "the default")
    let strict = MonitorFrame.signal(of: pb, range: .legal, untaggedTransfer: .unknown)
    XCTAssertEqual(strict.encoding, .unknown)
    var expected = MonitorFrame.signal(of: pb, range: .legal)
    expected.encoding = .unknown
    XCTAssertEqual(strict, expected, "only the transfer differs")

    // Tags it knows keep their meaning; one it does not is untagged too.
    let tags: [(CFString, SignalEncoding)] = [
      (kCVImageBufferTransferFunction_ITU_R_709_2, .display(.bt709)),
      (kCVImageBufferTransferFunction_ITU_R_2020, .display(.bt709)),
      (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .display(.pq)),
      (kCVImageBufferTransferFunction_ITU_R_2100_HLG, .display(.hlg)),
      (kCVImageBufferTransferFunction_sRGB, .display(.sRGB)),
      (kCVImageBufferTransferFunction_Linear, .display(.linear)),
      (kCVImageBufferTransferFunction_SMPTE_ST_428_1, .unknown),
      (kCVImageBufferTransferFunction_UseGamma, .unknown),
    ]
    for (tag, encoding) in tags {
      let tagged = try buffer()
      CVBufferSetAttachment(tagged, kCVImageBufferTransferFunctionKey, tag, .shouldPropagate)
      XCTAssertEqual(
        MonitorFrame.signal(of: tagged, range: .legal, untaggedTransfer: .unknown).encoding, encoding, "\(tag)")
      XCTAssertEqual(
        MonitorFrame.signal(of: tagged, range: .legal, untaggedTransfer: .display(.bt709)).encoding,
        encoding == .unknown ? .display(.bt709) : encoding, "\(tag)")
    }

    // Through the texture cache and `wrap`: the host's strict signal gives the
    // code-value view and the known-transfer refusal; the default does not.
    let cache = MonitorTextureCache(device: gpu.device, residency: try MonitorResidency(device: gpu.device))
    var stops = MonitorState()
    stops.falseColor.mode = .custom
    stops.falseColor.customUnit = .stops
    let wrapCache = gpu.cache
    let frames = [
      (try cache.frame(pb, signal: strict), true), (try cache.frame(pb), false),
      (try MonitorFrame.wrap(pb, cache: wrapCache, signal: strict), true),
      (try MonitorFrame.wrap(pb, cache: wrapCache), false),
    ]
    for (i, (frame, unlabelled)) in frames.enumerated() {
      let feed = gpu.engine.makeFeed(), pass = gpu.engine.makePass()
      let t = gpu.target(frame.width, frame.height)
      try gpu.run { cb in try pass.encode(frame: frame, feed: feed, state: MonitorState(), target: t, into: cb) }
      XCTAssertEqual(pass.status.isCodeValueView, unlabelled, "frame \(i)")
      try gpu.run { cb in try pass.encode(frame: frame, feed: feed, state: stops, target: t, into: cb) }
      XCTAssertEqual(
        pass.status.reason(for: .falseColor) == .requiresKnownTransfer, unlabelled, "frame \(i): \(pass.status)")
    }
  }
}
