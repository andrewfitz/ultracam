import CoreVideo
import Metal
import Synchronization
import XCTest

@testable import MonitorKit

/// Regressions for the gap-picture audit: cache-frame residency on Metal 4, a new
/// cache texture resident before it is published, broken pixel aspect ratios
/// reported as unsupported geometry, `.picture` in one status list, the code-value
/// view and LUT entries following what is drawn, and warm-up honouring the
/// frame's pixel aspect ratio, aperture and unknown sizes.
final class GapPictureRegressionTests: XCTestCase {
  static let slog3 = SignalDescription(encoding: .log(.sLog3SGamut3Cine))

  func buffer(_ layout: PixelLayout = .biplanar(.s420, bitDepth: 10), width: Int = 66, height: Int = 38, seed: UInt64 = 9)
    throws -> CVPixelBuffer
  {
    try XCTUnwrap(PictureTests.picture(layout, width: width, height: height, seed: seed).pixelBuffer(range: .legal))
  }

  func planes(_ f: MonitorFrame) -> [MTLTexture] { [f.packed, f.luma, f.chroma].compactMap { $0 } }

  /// One frame through a fresh pass into a float target.
  func render(
    _ gpu: TestGPU, _ frame: MonitorFrame, state: MonitorState, burn: MonitorLUT? = nil, monitor: MonitorLUT? = nil,
    width: Int? = nil, height: Int? = nil, pass: MonitorPass? = nil
  ) throws -> (Pixels, MonitorPass) {
    let feed = gpu.engine.makeFeed()
    feed.burnInLUT = burn
    feed.monitorLUT = monitor
    let pass = pass ?? gpu.engine.makePass()
    let t = gpu.target(width ?? frame.width, height ?? frame.height)
    try gpu.run { cb in try pass.encode(frame: frame, feed: feed, state: state, target: t, into: cb) }
    return (Pixels(t), pass)
  }

  // MARK: - Texture cache residency (Metal 4)

  /// A stalled camera's last cache frame, redrawn after the cache flushed (or
  /// swept) its textures and their submissions completed, is resident again for
  /// the submission that reads it, and leaves once that one completes.
  func testCacheFrameRedrawnAfterFlushIsResidentAgain() throws {
    let gpu = try requireMTL4().gpu
    let engine = try MonitorEngine(device: gpu.device)
    let cache = MonitorTextureCache(device: gpu.device, residency: engine.residency, idleLifetime: 2)
    let residency = engine.residency
    let pass = engine.makePass(), feed = engine.makeFeed()
    let viewport = MonitorViewport(width: 48, height: 27)
    let format = MonitorRenderTargetFormat(colorPixelFormat: .rgba16Float)
    for (index, pb) in [try buffer(), try buffer(.v210, seed: 4)].enumerated() {
      let base = UInt64(index * 10)
      let frame = try cache.frame(pb, owner: 7, now: 100)
      let textures = planes(frame)
      func submission(_ i: UInt64) throws -> MonitorSubmission {
        MonitorSubmission(commandBuffer: try XCTUnwrap(gpu.device.makeCommandBuffer()), index: base + i, completedIndex: base + i - 1)
      }
      try pass.prepare(frame: frame, feed: feed, state: MonitorState(), viewport: viewport, target: format, submission: try submission(1))
      for t in textures { XCTAssertTrue(residency.contains(t)) }
      // The camera stops: its textures leave once submission 1 completes.
      cache.flush(owner: 7)
      for t in textures { XCTAssertTrue(residency.contains(t), "submission 1 may still read it") }
      residency.release(through: base + 1)
      for t in textures { XCTAssertFalse(residency.contains(t)) }
      // The held frame is drawn again (a zebra toggle, a resize): resident at encode time.
      var zebra = MonitorState()
      zebra.zebras[0].enabled = true
      try pass.prepare(frame: frame, feed: feed, state: zebra, viewport: viewport, target: format, submission: try submission(2))
      for t in textures { XCTAssertTrue(residency.contains(t), "the redraw's submission reads it") }
      residency.release(through: base + 2)
      for t in textures { XCTAssertFalse(residency.contains(t), "and it leaves once that completes") }
    }
    XCTAssertEqual(residency.pendingReleaseCount, 0)
  }

  /// The idle sweep has the same effect, and a frame from a live entry costs no
  /// residency change per encode.
  func testCacheFrameRedrawnAfterIdleSweepIsResidentAgain() throws {
    let gpu = try requireMTL4().gpu
    let engine = try MonitorEngine(device: gpu.device)
    let residency = engine.residency
    let cache = MonitorTextureCache(device: gpu.device, residency: residency, idleLifetime: 2)
    let pass = engine.makePass(), feed = engine.makeFeed()
    let viewport = MonitorViewport(width: 48, height: 27)
    let format = MonitorRenderTargetFormat(colorPixelFormat: .rgba16Float)
    let stalled = try cache.frame(try buffer(), owner: 1, now: 100)
    func prepare(_ frame: MonitorFrame, _ i: UInt64) throws {
      let s = MonitorSubmission(commandBuffer: try XCTUnwrap(gpu.device.makeCommandBuffer()), index: i, completedIndex: i - 1)
      try pass.prepare(frame: frame, feed: feed, state: MonitorState(), viewport: viewport, target: format, submission: s)
    }
    try prepare(stalled, 1)
    try prepare(stalled, 2)
    let commits = residency.commitCount
    try prepare(stalled, 3)
    XCTAssertEqual(residency.commitCount, commits, "a live cache frame changes no residency")
    // Another camera's lookup 3 s later sweeps the stalled camera's textures.
    _ = try cache.frame(try buffer(.bgra8, seed: 2), owner: 2, now: 103)
    XCTAssertEqual(cache.count(owner: 1), 0)
    residency.release(through: 3)
    for t in planes(stalled) { XCTAssertFalse(residency.contains(t)) }
    try prepare(stalled, 4)
    for t in planes(stalled) { XCTAssertTrue(residency.contains(t)) }
    residency.release(through: 4)
    for t in planes(stalled) { XCTAssertFalse(residency.contains(t)) }
  }

  /// Either plane's released entry makes every plane resident again: a flush
  /// between the luma and chroma lookups leaves the luma entry released and the
  /// chroma entry live.
  func testEitherReleasedPlaneMakesTheFrameResidentAgain() throws {
    let gpu = try requireMTL4().gpu
    let residency = try MonitorResidency(device: gpu.device)
    let luma = gpu.texture(.r16Unorm, 8, 8, usage: .shaderRead)
    let chroma = gpu.texture(.rg16Unorm, 4, 4, usage: .shaderRead)
    for (n, releaseFirst) in [(UInt64(1), true), (2, false)] {
      // Submission n reads the frame and has not completed.
      residency.observe(
        MonitorSubmission(commandBuffer: try XCTUnwrap(gpu.device.makeCommandBuffer()), index: n, completedIndex: n - 1))
      var frame = try MonitorFrame(
        layout: .biplanar(.s420, bitDepth: 10), width: 8, height: 8, luma: luma, chroma: chroma, signal: .rec709)
      frame.frozenPlanes = FrozenPlanes()
      frame.secondPlanes = FrozenPlanes()
      frame.keepResidentIfReleased(in: residency)
      XCTAssertFalse(residency.contains(luma), "nothing released: nothing changes")
      (releaseFirst ? frame.frozenPlanes : frame.secondPlanes)?.markReleased()
      frame.keepResidentIfReleased(in: residency)
      XCTAssertTrue(residency.contains(luma))
      XCTAssertTrue(residency.contains(chroma))
      XCTAssertTrue(residency.contains(luma), "until submission \(n) completes")
      residency.release(through: n)
      XCTAssertFalse(residency.contains(luma))
      XCTAssertFalse(residency.contains(chroma))
    }
  }

  /// A lookup that finds a texture another thread just made finds it resident:
  /// the texture joins the set before it is published.
  func testTexturesAreResidentBeforeAnotherThreadCanFindThem() throws {
    let gpu = try requireGPU()
    let residency = try MonitorResidency(device: gpu.device)
    let cache = MonitorTextureCache(device: gpu.device, residency: residency)
    let missing = Mutex(0)
    for round in 0..<24 {
      // Fresh surfaces each round, so every thread races on the miss.
      nonisolated(unsafe) let pb = try buffer(width: 34, height: 18, seed: UInt64(round))
      DispatchQueue.concurrentPerform(iterations: 8) { _ in
        guard let f = try? cache.frame(pb, now: 1) else { return }
        var n = 0
        if let t = f.luma, !residency.contains(t) { n += 1 }
        if let t = f.chroma, !residency.contains(t) { n += 1 }
        if n > 0 { missing.withLock { $0 += n } }
      }
    }
    XCTAssertEqual(missing.withLock { $0 }, 0)
    XCTAssertEqual(cache.texturesMade, 48)
  }

  // MARK: - Pixel aspect ratio

  /// A broken declared pixel aspect ratio (NaN, ±∞, 0, negative) reports
  /// `.unsupportedGeometry` and shows square pixels, as an out-of-range one does;
  /// the public getter stays finite, the geometry carries 0 and a NaN rebuilds once.
  func testBrokenPixelAspectRatioIsUnsupportedGeometry() throws {
    let gpu = try requireGPU()
    var frame = try PictureTests.picture(width: 48, height: 27).frame(gpu, signal: .rec709)
    let square = try render(gpu, frame, state: MonitorState(), width: 96, height: 96)
    XCTAssertNil(square.1.status.reason(for: .picture))
    for par in [Double.nan, .infinity, -.infinity, 0, -2, 1e-320] {
      frame.pixelAspectRatio = par
      XCTAssertEqual(frame.pixelAspectRatio, par > 0 && par.isFinite ? par : 1, "\(par)")
      let (pixels, pass) = try render(gpu, frame, state: MonitorState(), width: 96, height: 96)
      XCTAssertEqual(pass.status.reason(for: .picture), .unsupportedGeometry, "\(par)")
      XCTAssertFalse(frame.geometry.hasUsablePixelAspectRatio)
      XCTAssertEqual(frame.geometry.effectivePixelAspectRatio, 1)
      XCTAssertEqual(pass.layout, square.1.layout)
      assertSamePixels(pixels.values, square.0.values, "PAR \(par)")
      // Equality-stable: the same frame again rebuilds nothing.
      let rebuilds = pass.rebuildCount
      _ = try render(gpu, frame, state: MonitorState(), width: 96, height: 96, pass: pass)
      XCTAssertEqual(pass.rebuildCount, rebuilds, "PAR \(par)")
      XCTAssertEqual(frame.geometry, frame.geometry)
    }
    // Freeze keeps the declared ratio.
    frame.pixelAspectRatio = .nan
    let feed = gpu.engine.makeFeed()
    var frozen: MonitorFrame?
    try gpu.run { cb in frozen = try feed.freeze(frame, into: cb) }
    XCTAssertEqual(frozen?.geometry.pixelAspectRatio, 0)
    XCTAssertEqual(try render(gpu, try XCTUnwrap(frozen), state: MonitorState()).1.status.reason(for: .picture), .unsupportedGeometry)
  }

  /// A broken pixel aspect ratio tag (zero or missing spacing, not a dictionary)
  /// reads as 0 and reports; an absent tag is square pixels and does not; a good
  /// tag is its ratio. Through `wrap`, the texture cache and `geometry(of:)`.
  func testBrokenPixelAspectRatioTagsAreUnsupportedGeometry() throws {
    let gpu = try requireGPU()
    let residency = try MonitorResidency(device: gpu.device)
    let cache = MonitorTextureCache(device: gpu.device, residency: residency)
    let h = kCVImageBufferPixelAspectRatioHorizontalSpacingKey, v = kCVImageBufferPixelAspectRatioVerticalSpacingKey
    let cases: [(CFTypeRef?, Double)] = [
      (nil, 1),
      ([h: 4, v: 3] as CFDictionary, 4.0 / 3),
      ([h: 0, v: 1] as CFDictionary, 0),
      ([h: 1, v: 0] as CFDictionary, 0),
      // CoreVideo refuses to attach these (`CVBufferCopyAttachment` returns nil): absent.
      ([h: 1] as CFDictionary, 1),
      ([h: -1, v: 1] as CFDictionary, 0),
      ([h: Double.nan, v: 1] as CFDictionary, 0),
      (3 as CFNumber, 1),
    ]
    for (i, (tag, ratio)) in cases.enumerated() {
      let pb = try buffer(.bgra8, width: 32, height: 18, seed: UInt64(i))
      if let tag { CVBufferSetAttachment(pb, kCVImageBufferPixelAspectRatioKey, tag, .shouldPropagate) }
      XCTAssertEqual(MonitorFrame.pixelAspectRatio(of: pb), ratio, accuracy: 1e-12, "case \(i)")
      XCTAssertEqual(MonitorFrame.geometry(of: pb).pixelAspectRatio, ratio, accuracy: 1e-12, "case \(i)")
      let wrapped = try MonitorFrame.wrap(pb, cache: gpu.cache)
      let cached = try cache.frame(pb)
      XCTAssertEqual(wrapped.geometry, MonitorFrame.geometry(of: pb))
      XCTAssertEqual(cached.geometry, wrapped.geometry)
      XCTAssertEqual(wrapped.pixelAspectRatio, ratio == 0 ? 1 : ratio, accuracy: 1e-12)
      for frame in [wrapped, cached] {
        let reason = try render(gpu, frame, state: MonitorState(), width: 64, height: 36).1.status.reason(for: .picture)
        XCTAssertEqual(reason, ratio == 0 ? .unsupportedGeometry : nil, "case \(i)")
      }
    }
  }

  // MARK: - Status

  /// `.picture` is never both active and unavailable: unusable geometry wins, and
  /// the stage and code-value view stay readable.
  func testPictureIsInOneStatusListOnly() throws {
    let gpu = try requireGPU()
    var frame = try PictureTests.picture(width: 24, height: 12).frame(gpu, signal: Self.slog3)
    var s = MonitorState()
    s.pictureStage = .source
    let good = try render(gpu, frame, state: s).1.status
    XCTAssertTrue(good.isActive(.picture))
    XCTAssertNil(good.reason(for: .picture))
    for par in [0.001, 40, Double.nan, 0] {
      frame.pixelAspectRatio = par
      let st = try render(gpu, frame, state: s).1.status
      XCTAssertFalse(st.isActive(.picture), "\(par)")
      XCTAssertEqual(st.reason(for: .picture), .unsupportedGeometry, "\(par)")
      XCTAssertTrue(st.isCodeValueView)
      XCTAssertEqual(st.pictureStage, .source)
    }
    // Every tool is in at most one list.
    var all = MonitorState()
    everyTool(&all)
    all.pictureStage = .source
    let st = try render(gpu, frame, state: all).1.status
    for tool in MonitorTool.allCases {
      XCTAssertFalse(st.isActive(tool) && st.reason(for: tool) != nil, "\(tool)")
    }
  }

  /// False colour replaces the picture, so a log source under it is no code-value view.
  func testFalseColourIsNoCodeValueView() throws {
    let gpu = try requireGPU()
    let frame = try PictureTests.picture(width: 24, height: 12).frame(gpu, signal: Self.slog3)
    func label(_ st: MonitorStatus) -> String? { st.active.first { $0.tool == .picture }?.label }
    for stage in [SignalStage.monitor, .source] {
      var s = MonitorState()
      s.pictureStage = stage
      XCTAssertTrue(try render(gpu, frame, state: s).1.status.isCodeValueView)
      for mode in [FalseColorMode.elZone, .sonySLog3, .sixBand] {
        s.falseColor.mode = mode
        s.falseColor.stage = .source
        let st = try render(gpu, frame, state: s).1.status
        XCTAssertTrue(st.isActive(.falseColor), "\(mode)")
        XCTAssertFalse(st.isCodeValueView, "\(mode) on \(stage)")
        XCTAssertEqual(label(st), stage == .source ? "Source" : nil, "\(mode) on \(stage)")
      }
      // A clean surface draws no false colour: the code values are the picture again.
      s.clean = true
      XCTAssertTrue(try render(gpu, frame, state: s).1.status.isCodeValueView)
    }
  }

  /// LUT entries follow what is drawn: listed when something passes through the
  /// LUT, plain when the picture does, " · tools only" when only a tool does.
  func testLUTEntriesFollowWhatIsDrawn() throws {
    let gpu = try requireGPU()
    let frame = try PictureTests.picture(width: 24, height: 12).frame(gpu, signal: .rec709)
    let burn = try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 9, seed: 11))
    let monitor = try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 9, seed: 12))
    func labels(_ s: MonitorState) throws -> (burn: String?, monitor: String?) {
      let st = try render(gpu, frame, state: s, burn: burn, monitor: monitor).1.status
      return (st.active.first { $0.tool == .burnInLUT }?.label, st.active.first { $0.tool == .monitorLUT }?.label)
    }
    let b = "LUT · \(burn.cube.title)", m = "Monitor LUT · \(monitor.cube.title)", tools = " · tools only"
    var s = MonitorState()
    XCTAssertTrue(try labels(s) == (b, m), "the monitor picture shows both")
    s.pictureStage = .output
    XCTAssertTrue(try labels(s) == (b, nil), "the output picture never passes the monitor LUT")
    s.pictureStage = .source
    XCTAssertTrue(try labels(s) == (nil, nil), "the source picture shows neither")
    // A zebra measuring the output reads the burn-in LUT only.
    s.zebras[0] = ZebraSet(mode: .lowerLimit, level: 120, stage: .output)
    XCTAssertTrue(try labels(s) == (b + tools, nil))
    // Stage false colour on the monitor stage reads both.
    s.zebras[0].enabled = false
    s.falseColor.mode = .sixBand
    s.falseColor.stage = .monitor
    XCTAssertTrue(try labels(s) == (b + tools, m + tools))
    s.pictureStage = .output
    XCTAssertTrue(try labels(s) == (b, m + tools))
    // The monitor LUT switched off on this surface is never listed.
    s.monitorLUT = false
    XCTAssertTrue(try labels(s) == (b, nil))
  }

  // MARK: - Warm-up

  /// Anamorphic pixels change the filter: 144×108 at 4/3 in a 192×108 view is
  /// interpolated (footprint 0.75), square pixels are not, and warm-up builds the
  /// right one so the first frame draws specialized without compiling.
  func testWarmUpHonoursPixelAspectRatio() throws {
    let gpu = try requireGPU()
    let lut = try gpu.engine.warmUpLUT()
    let target = MonitorRenderTargetFormat(colorPixelFormat: .bgr10a2Unorm)
    func keys(par: Double, aperture: MonitorRect? = nil) throws -> [MonitorEngine.PipelineKey] {
      try MonitorEngine.pipelineKeys(
        for: MonitorSurfaceConfiguration(
          target: target, layout: .v210, frameSize: (144, 108), viewportSize: (192, 108), pixelAspectRatio: par,
          cleanAperture: aperture), placeholder: lut)
    }
    let square = try keys(par: 1), anamorphic = try keys(par: 4.0 / 3)
    XCTAssertEqual(square.count, 1)
    XCTAssertEqual(anamorphic.count, 1)
    XCTAssertFalse(square[0].variant.interpolates)
    XCTAssertTrue(anamorphic[0].variant.interpolates)
    XCTAssertEqual(try keys(par: .nan), square, "a broken ratio is square, as the pass shows it")
    // An aperture half as wide doubles the magnification.
    XCTAssertTrue(try keys(par: 1, aperture: MonitorRect(x: 36, y: 27, width: 72, height: 54))[0].variant.interpolates)

    let engine = try MonitorEngine(device: gpu.device, specialization: .asynchronous)
    try engine.warmUp(layouts: [.v210])
    try engine.warmUp(
      targets: [], layouts: [.v210],
      surfaces: [
        MonitorSurfaceConfiguration(
          target: target, layout: .v210, frameSize: (144, 108), viewportSize: (192, 108), pixelAspectRatio: 4.0 / 3)
      ])
    var frame = try PictureTests.picture(width: 144, height: 108).frame(gpu, signal: .rec709)
    frame.pixelAspectRatio = 4.0 / 3
    let pass = engine.makePass(), feed = engine.makeFeed()
    let t = gpu.target(192, 108, format: .bgr10a2Unorm)
    let built = engine.pipelinesBuiltOnCaller
    try gpu.run { cb in try pass.encode(frame: frame, feed: feed, state: MonitorState(), target: t, into: cb) }
    XCTAssertEqual(pass.layout?.footprintX ?? 0, 0.75, accuracy: 1e-9)
    XCTAssertTrue(pass.usesSpecializedPipeline)
    XCTAssertEqual(engine.pipelinesBuiltOnCaller, built)
  }

  /// Either size unknown builds both filter variants, whatever the known size.
  func testWarmUpWithOneSizeBuildsBothFilters() throws {
    let gpu = try requireGPU()
    let lut = try gpu.engine.warmUpLUT()
    let target = MonitorRenderTargetFormat(colorPixelFormat: .bgr10a2Unorm)
    let sizes: [((Int, Int)?, (Int, Int)?)] = [
      (nil, (3840, 2160)), (nil, (192, 108)), ((1920, 1080), nil), ((7680, 4320), nil), (nil, nil),
    ]
    for (frame, viewport) in sizes {
      let keys = try MonitorEngine.pipelineKeys(
        for: MonitorSurfaceConfiguration(target: target, layout: .v210, frameSize: frame, viewportSize: viewport),
        placeholder: lut)
      XCTAssertEqual(Set(keys.map(\.variant.interpolates)), [false, true], "frame \(String(describing: frame)), view \(String(describing: viewport))")
    }
  }
}
