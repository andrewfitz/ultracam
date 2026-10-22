import CoreVideo
import Metal
import XCTest
import simd

@testable import MonitorKit

/// R9 (the picture stage per surface), R10 (clean aperture and the layout query),
/// R14 (status reasons for every old MonitorTools refusal, the code-value view)
/// and the fusable LUT source's include guard.
final class PictureStageApertureTests: XCTestCase {
  static let slog3 = SignalDescription(encoding: .log(.sLog3SGamut3Cine))

  func luts(_ gpu: TestGPU) throws -> (MonitorLUT, MonitorLUT) {
    (
      try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 17, seed: 11)),
      try MonitorLUT(device: gpu.device, cube: try LUTTests.cube(size: 9, seed: 12))
    )
  }

  /// One frame through a fresh pass of `engine` into a float target.
  func render(
    _ gpu: TestGPU, engine: MonitorEngine? = nil, _ frame: MonitorFrame, state: MonitorState, burn: MonitorLUT? = nil,
    monitor: MonitorLUT? = nil, width: Int? = nil, height: Int? = nil, analyze: Bool = false
  ) throws -> (Pixels, MonitorPass) {
    let engine = engine ?? gpu.engine
    let feed = engine.makeFeed()
    feed.burnInLUT = burn
    feed.monitorLUT = monitor
    let pass = engine.makePass()
    let t = gpu.target(width ?? frame.width, height ?? frame.height)
    try gpu.run { cb in
      if analyze { try feed.analyze(frame, focus: state.focus, into: cb) }
      try pass.encode(frame: frame, feed: feed, state: state, target: t, into: cb)
    }
    return (Pixels(t), pass)
  }

  // MARK: - R9 picture stage

  /// The source picture of a feed with both LUTs is the picture of the feed
  /// without them; the output picture drops only the monitor LUT. Specialized and
  /// all-tools pipelines alike, the navigator included.
  func testPictureStageShowsTheChosenStage() throws {
    let gpu = try requireGPU()
    let off = try MonitorEngine(device: gpu.device, specialization: .off)
    let frame = try PictureTests.picture(width: 96, height: 54).frame(gpu, signal: .rec709)
    let (burn, monitor) = try luts(gpu)
    var zoomed = MonitorState()
    zoomed.geometry.magnification.zoom = 3
    zoomed.geometry.magnification.centerX = 0.3
    // A zebra on the output stage that never fires: the pipeline reads the burn-in
    // LUT, and the picture must still show the source.
    var zebra = MonitorState()
    zebra.zebras[0] = ZebraSet(mode: .lowerLimit, level: 120, stage: .output)
    for engine in [gpu.engine, off] {
      for base in [MonitorState(), zoomed, zebra] {
        let plain = try render(gpu, engine: engine, frame, state: base).0
        var s = base
        s.pictureStage = .source
        let (source, pass) = try render(gpu, engine: engine, frame, state: s, burn: burn, monitor: monitor)
        assertSamePixels(source.values, plain.values, "source picture, \(engine.specialization)")
        XCTAssertEqual(pass.status.pictureStage, .source)
        s.pictureStage = .output
        let output = try render(gpu, engine: engine, frame, state: s, burn: burn, monitor: monitor).0
        let burnOnly = try render(gpu, engine: engine, frame, state: base, burn: burn).0
        assertSamePixels(output.values, burnOnly.values, "output picture, \(engine.specialization)")
        s.pictureStage = .monitor
        let shown = try render(gpu, engine: engine, frame, state: s, burn: burn, monitor: monitor).0
        XCTAssertNotEqual(shown.values, output.values, "the monitor LUT changes the default picture")
      }
    }
    // The default (monitor stage) is the W1 picture: pinned by the W1 bit-exact tests.
    XCTAssertEqual(MonitorState().pictureStage, .monitor)
  }

  /// A source picture is the camera's signal: a display transform applies even while
  /// the feed burns a LUT in, and the layer is tagged for the source.
  func testSourcePictureTakesADisplayTransformUnderABurnInLUT() throws {
    let gpu = try requireGPU()
    let frame = try PictureTests.picture(width: 64, height: 36).frame(gpu, signal: Self.slog3)
    let (burn, _) = try luts(gpu)
    var s = MonitorState()
    s.displayTransform.mode = .logToRec709
    let (lutPicture, lutPass) = try render(gpu, frame, state: s, burn: burn)
    XCTAssertEqual(lutPass.status.reason(for: .displayTransform), .lutOnMonitorStage)
    s.pictureStage = .source
    let (source, sourcePass) = try render(gpu, frame, state: s, burn: burn)
    XCTAssertNil(sourcePass.status.reason(for: .displayTransform))
    XCTAssertTrue(sourcePass.status.isActive(.displayTransform))
    XCTAssertEqual(sourcePass.colorPipeline.transform, .logToRec709)
    let noLUT = try render(gpu, frame, state: s).0
    assertSamePixels(source.values, noLUT.values, "the transform of the source, as with no LUT at all")
    XCTAssertNotEqual(source.values, lutPicture.values)
    let feed = gpu.engine.makeFeed()
    feed.burnInLUT = burn
    XCTAssertFalse(feed.monitorStageHasLUT(for: s), "a source picture has no LUT")
    s.pictureStage = .output
    XCTAssertTrue(feed.monitorStageHasLUT(for: s))
    feed.burnInLUT = nil
    feed.monitorLUT = burn
    XCTAssertFalse(feed.monitorStageHasLUT(for: s), "the output stage has no monitor LUT")
    s.pictureStage = .monitor
    XCTAssertTrue(feed.monitorStageHasLUT(for: s))
    // The layer recommendation follows: an S-Log3 source picture is a code-value Rec.709 layer
    // without a transform, a Rec.709 SDR layer with one.
    XCTAssertEqual(
      MonitorOutputColor.signalNative.layer(for: Self.slog3, displayTransform: .logToRec709, monitorStageHasLUT: false).kind,
      .sdr(.bt1886))
  }

  func testPictureStatusLabelsAndCodeValueView() throws {
    let gpu = try requireGPU()
    let (burn, _) = try luts(gpu)
    func status(_ signal: SignalDescription, _ configure: (inout MonitorState) -> Void, burn: MonitorLUT? = nil) throws
      -> MonitorStatus
    {
      let frame = try PictureTests.picture(width: 24, height: 12).frame(gpu, signal: signal)
      var s = MonitorState()
      configure(&s)
      return try render(gpu, frame, state: s, burn: burn).1.status
    }
    func label(_ st: MonitorStatus) -> String? { st.active.first { $0.tool == .picture }?.label }

    let rec709 = try status(.rec709) { _ in }
    XCTAssertNil(label(rec709), "the default picture of a labelled signal says nothing")
    XCTAssertFalse(rec709.isCodeValueView)
    XCTAssertEqual(label(try status(.rec709) { $0.pictureStage = .source }), "Source")
    XCTAssertEqual(label(try status(.rec709) { $0.pictureStage = .output }), "Output")

    let log = try status(Self.slog3) { _ in }
    XCTAssertTrue(log.isCodeValueView)
    XCTAssertEqual(label(log), "S-Log3 code values")
    XCTAssertEqual(label(try status(Self.slog3, { $0.pictureStage = .source }, burn: burn)), "Source · S-Log3 code values")
    let lut = try status(Self.slog3, { _ in }, burn: burn)
    XCTAssertFalse(lut.isCodeValueView, "a LUT maps the log signal for viewing")
    XCTAssertNil(label(lut))
    let assisted = try status(Self.slog3) { $0.displayTransform.mode = .logToRec709 }
    XCTAssertFalse(assisted.isCodeValueView, "the display transform maps it")
    let logC4 = SignalDescription(range: .full, encoding: .log(LogEncoding(curve: .arriLogC4, gamut: .arriWideGamut4)))
    XCTAssertEqual(label(try status(logC4) { _ in }), "LogC4 code values")
    let unknown = try status(SignalDescription(encoding: .unknown)) { _ in }
    XCTAssertTrue(unknown.isCodeValueView)
    XCTAssertEqual(label(unknown), "Unlabelled code values")
    XCTAssertFalse(MonitorStatus.codeValueViewNote.isEmpty)
  }

  // MARK: - R14 status reasons

  /// MonitorTools' refusals (MonitorToolsRenderer.swift, false colour and focus
  /// qualification) and their MonitorKit reasons:
  /// - "Focus unavailable: source correspondence is unqualified" (Program, or a
  ///   processed output without a correspondence): `.requiresCameraSignal`; an
  ///   unanalysed frame: `.focusNotAnalyzed`.
  /// - "False color unavailable: source profile, signal, or correspondence is
  ///   unqualified": `.requiresLogSource`, `.unsupportedLogEncoding`, `.requiresCameraSignal`.
  /// - "Monitor tools unavailable: unsupported picture geometry": `.unsupportedGeometry`.
  /// - "… unsupported SDR transfer interpretation …; showing code values": the
  ///   code-value view label, and `.requiresKnownTransfer` for tools that need light.
  /// - "Source Log code-value view; no viewing transform or exposure calibration
  ///   applied": `isCodeValueView` and the `.picture` label.
  func testProcessedPicturesRefuseCameraSignalTools() throws {
    let gpu = try requireGPU()
    var frame = try PictureTests.picture(width: 48, height: 27).frame(gpu, signal: Self.slog3)
    frame.isProcessed = true
    var s = MonitorState()
    s.focus.enabled = true
    s.falseColor.mode = .sonySLog3
    let feed = gpu.engine.makeFeed()
    let pass = gpu.engine.makePass()
    let t = gpu.target(48, 27)
    try gpu.run { cb in
      try feed.analyze(frame, focus: s.focus, into: cb)
      try pass.encode(frame: frame, feed: feed, state: s, target: t, into: cb)
    }
    XCTAssertEqual(feed.analysisCount, 0, "a processed picture is not analysed")
    XCTAssertNil(feed.focusMask)
    XCTAssertEqual(pass.status.reason(for: .focusPeaking), .requiresCameraSignal)
    XCTAssertEqual(pass.status.reason(for: .falseColor), .requiresCameraSignal)
    var plain = s
    plain.focus.enabled = false
    plain.falseColor.mode = .off
    assertSamePixels(Pixels(t).values, try render(gpu, frame, state: plain).0.values, "neither tool is drawn")
    // Display-referred false colour measures the picture itself, so it still runs.
    s.falseColor.mode = .sixBand
    XCTAssertTrue(try render(gpu, frame, state: s).1.status.isActive(.falseColor))
    // The camera's own frame keeps both.
    frame.isProcessed = false
    s.falseColor.mode = .sonySLog3
    let camera = try render(gpu, frame, state: s, analyze: true).1
    XCTAssertTrue(camera.status.isActive(.focusPeaking))
    XCTAssertTrue(camera.status.isActive(.falseColor))
    // Freeze keeps the flag.
    frame.isProcessed = true
    var frozen: MonitorFrame?
    try gpu.run { cb in frozen = try feed.freeze(frame, into: cb) }
    XCTAssertEqual(frozen?.isProcessed, true)
    XCTAssertFalse(MonitorUnavailableReason.requiresCameraSignal.description.isEmpty)
  }

  func testUnusablePixelAspectRatioShowsSquarePixels() throws {
    let gpu = try requireGPU()
    var frame = try PictureTests.picture(width: 48, height: 27).frame(gpu, signal: .rec709)
    let square = try render(gpu, frame, state: MonitorState(), width: 96, height: 96)
    XCTAssertNil(square.1.status.reason(for: .picture))
    for par in [40.0, 0.01] {
      frame.pixelAspectRatio = par
      let (pixels, pass) = try render(gpu, frame, state: MonitorState(), width: 96, height: 96)
      XCTAssertEqual(pass.status.reason(for: .picture), .unsupportedGeometry, "\(par)")
      XCTAssertEqual(pass.layout, square.1.layout)
      assertSamePixels(pixels.values, square.0.values, "PAR \(par)")
    }
    frame.pixelAspectRatio = 16
    XCTAssertNil(try render(gpu, frame, state: MonitorState(), width: 96, height: 96).1.status.reason(for: .picture))
  }

  // MARK: - R10 clean aperture

  /// A float RGB frame with distinct pixels, and its crop as a frame of its own.
  func frames(_ gpu: TestGPU, width: Int = 16, height: Int = 8, crop: MonitorRect, seed: UInt64 = 5)
    throws -> (full: MonitorFrame, crop: MonitorFrame)
  {
    let full = SyntheticFrame.random(.rgba32Float, width: width, height: height, seed: seed)
    var part = SyntheticFrame(layout: .rgba32Float, width: Int(crop.width), height: Int(crop.height))
    for y in Int(crop.y)..<Int(crop.maxY) {
      for x in Int(crop.x)..<Int(crop.maxX) { part.rgb.append(full.rgb[y * width + x]) }
    }
    var f = try full.frame(gpu, signal: .rec709)
    f.cleanAperture = crop
    return (f, try part.frame(gpu, signal: .rec709))
  }

  /// An asymmetric aperture shows exactly its pixels: 1:1, minified, flipped,
  /// letterboxed, with guides, and the layout's aspect is the aperture's.
  func testAsymmetricApertureShowsExactlyItsPixels() throws {
    let gpu = try requireGPU()
    let crop = MonitorRect(x: 3, y: 1, width: 8, height: 4)  // 3 left, 5 right, 1 top, 3 bottom
    let (full, part) = try frames(gpu, crop: crop)
    var states: [MonitorState] = [MonitorState()]
    var flipped = MonitorState()
    flipped.geometry.flip = .rotate180
    states.append(flipped)
    var mirror = MonitorState()
    mirror.geometry.flip = .horizontal
    states.append(mirror)
    var guides = MonitorState()
    guides.guides.enabled = true
    guides.guides.safeAreas = [80]
    guides.guides.centerCross = true
    states.append(guides)
    for state in states {
      // 1:1, minified 2×, letterboxed 1:1 and pillarboxed 1:1: every tap inside the
      // aperture. (A magnified picture's bicubic taps read the frame's real pixels
      // past the aperture's edge, where the cropped frame clamps.)
      for (w, h) in [(8, 4), (4, 2), (8, 8), (13, 4)] {
        let (a, passA) = try render(gpu, full, state: state, width: w, height: h)
        let (b, passB) = try render(gpu, part, state: state, width: w, height: h)
        assertSamePixels(a.values, b.values, "\(w)×\(h) flip \(state.geometry.flip)")
        XCTAssertEqual(passA.layout?.fitRect, passB.layout?.fitRect)
        XCTAssertEqual(passA.currentGuides.counts, passB.currentGuides.counts)
      }
    }
    // Pixel (i, j) of a 1:1 picture is frame pixel (3 + i, 1 + j).
    let shown = try render(gpu, full, state: MonitorState(), width: 8, height: 4).0
    let reference = SyntheticFrame.random(.rgba32Float, width: 16, height: 8, seed: 5)
    for j in 0..<4 {
      for i in 0..<8 {
        let v = reference.rgb[(1 + j) * 16 + 3 + i]
        let expected = simd_clamp(SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z)), .zero, SIMD3(repeating: 1))
        XCTAssertEqual(shown.rgb(i, j), expected, "pixel \(i), \(j)")
      }
    }
    // The aperture's 2:1 picture letterboxes in a square viewport; the whole 2:1 frame would too,
    // but a 16:9 aperture of the same frame does not.
    let tall = try render(gpu, full, state: MonitorState(), width: 20, height: 20).1.layout
    XCTAssertEqual(tall?.fitRect, MonitorRect(x: 0, y: 5, width: 20, height: 10))
    var wide = full
    wide.cleanAperture = MonitorRect(x: 3, y: 0, width: 8, height: 8)
    XCTAssertEqual(
      try render(gpu, wide, state: MonitorState(), width: 20, height: 20).1.layout?.fitRect,
      MonitorRect(x: 0, y: 0, width: 20, height: 20), "a square aperture of the 2:1 frame fills the square")
  }

  /// Peaking's footprint follows the aperture: the mask is analysed over the
  /// whole frame, and the picture maps into it at the aperture.
  func testFocusFootprintFollowsTheAperture() throws {
    let gpu = try requireGPU()
    func step(_ width: Int, _ height: Int, edge: Int) -> SyntheticFrame {
      var f = SyntheticFrame(layout: .rgba32Float, width: width, height: height)
      f.rgb = (0..<(width * height)).map { i in i % width < edge ? SIMD3(repeating: 0.2) : SIMD3(repeating: 0.8) }
      return f
    }
    var full = try step(24, 12, edge: 12).frame(gpu, signal: .rec709)
    full.cleanAperture = MonitorRect(x: 6, y: 2, width: 12, height: 8)
    let part = try step(12, 8, edge: 6).frame(gpu, signal: .rec709)
    var s = MonitorState()
    s.focus.enabled = true
    s.focus.opacity = 1
    let a = try render(gpu, full, state: s, width: 12, height: 8, analyze: true)
    let b = try render(gpu, part, state: s, width: 12, height: 8, analyze: true)
    XCTAssertTrue(a.1.status.isActive(.focusPeaking))
    assertSamePixels(a.0.values, b.0.values, "peaking at the aperture's edge")
    XCTAssertTrue(a.0.values.contains { $0.x > 0.9 && $0.y < 0.1 }, "the edge is peaked red")
    // 2× magnified: the footprint still lands on the edge inside the aperture.
    let a2 = try render(gpu, full, state: s, width: 24, height: 16, analyze: true).0
    let b2 = try render(gpu, part, state: s, width: 24, height: 16, analyze: true).0
    for y in 4..<12 {
      for x in 8..<16 { XCTAssertEqual(a2[x, y], b2[x, y], "\(x), \(y)") }
    }
  }

  func testApertureValidationAndFreeze() throws {
    let gpu = try requireGPU()
    let s = PictureTests.picture(width: 48, height: 24)
    let packed = try s.frame(gpu, signal: .rec709).packed
    func make(_ a: MonitorRect?) throws -> MonitorFrame {
      try MonitorFrame(layout: .v210, width: 48, height: 24, packed: packed, signal: .rec709, cleanAperture: a)
    }
    XCTAssertNoThrow(try make(MonitorRect(x: 0, y: 0, width: 48, height: 24)))
    XCTAssertNoThrow(try make(MonitorRect(x: 6, y: 2, width: 36, height: 20)))
    XCTAssertNoThrow(try make(nil))
    for bad in [
      MonitorRect(x: -1, y: 0, width: 10, height: 10), MonitorRect(x: 40, y: 0, width: 10, height: 10),
      MonitorRect(x: 0, y: 0, width: 0.5, height: 10), MonitorRect(x: .nan, y: 0, width: 10, height: 10),
      MonitorRect(x: 0, y: 20, width: 10, height: 5),
    ] {
      XCTAssertThrowsError(try make(bad), "\(bad)")
    }
    let frame = try make(MonitorRect(x: 6, y: 2, width: 36, height: 20))
    XCTAssertEqual(frame.geometry.displayAspectRatio(), 36.0 / 20, accuracy: 1e-12)
    let feed = gpu.engine.makeFeed()
    var frozen: MonitorFrame?
    try gpu.run { cb in frozen = try feed.freeze(frame, into: cb) }
    XCTAssertEqual(frozen?.cleanAperture, frame.cleanAperture, "a frozen frame keeps its aperture")
  }

  /// `wrap` reads the clean aperture attachment: CoreVideo's offsets are of the
  /// aperture's centre, x right and y down, which is `CVImageBufferGetCleanRect`
  /// with its lower-left origin flipped.
  func testWrapReadsTheCleanApertureAttachment() throws {
    let gpu = try requireGPU()
    let picture = PictureTests.picture(.bgra8, width: 64, height: 40)
    let pb = try XCTUnwrap(picture.pixelBuffer(range: .full))
    let attachment: [CFString: Any] = [
      kCVImageBufferCleanApertureWidthKey: 40, kCVImageBufferCleanApertureHeightKey: 24,
      kCVImageBufferCleanApertureHorizontalOffsetKey: 6, kCVImageBufferCleanApertureVerticalOffsetKey: 5,
    ]
    CVBufferSetAttachment(pb, kCVImageBufferCleanApertureKey, attachment as CFDictionary, .shouldPropagate)
    let clean = CVImageBufferGetCleanRect(pb)
    let expected = MonitorRect(x: clean.minX, y: 40 - clean.maxY, width: clean.width, height: clean.height)
    XCTAssertEqual(expected, MonitorRect(x: 18, y: 13, width: 40, height: 24), "positive vertical offset moves down")
    XCTAssertEqual(MonitorFrame.cleanAperture(of: pb), expected)
    let frame = try MonitorFrame.wrap(pb, cache: gpu.cache)
    XCTAssertEqual(frame.cleanAperture, expected)
    XCTAssertEqual(MonitorFrame.geometry(of: pb), frame.geometry)
    // Its picture is the aperture's pixels.
    var whole = frame
    whole.cleanAperture = nil
    let cropped = try render(gpu, frame, state: MonitorState(), width: 40, height: 24).0
    let all = try render(gpu, whole, state: MonitorState(), width: 64, height: 40).0
    for y in 0..<24 {
      for x in 0..<40 { XCTAssertEqual(cropped[x, y], all[18 + x, 13 + y]) }
    }
    // Outside the frame: clipped; nonsense: ignored.
    CVBufferSetAttachment(
      pb, kCVImageBufferCleanApertureKey,
      [kCVImageBufferCleanApertureWidthKey: 64, kCVImageBufferCleanApertureHeightKey: 40,
       kCVImageBufferCleanApertureHorizontalOffsetKey: 10, kCVImageBufferCleanApertureVerticalOffsetKey: 0] as CFDictionary,
      .shouldPropagate)
    XCTAssertEqual(MonitorFrame.cleanAperture(of: pb), MonitorRect(x: 10, y: 0, width: 54, height: 40))
    CVBufferRemoveAttachment(pb, kCVImageBufferCleanApertureKey)
    XCTAssertNil(MonitorFrame.cleanAperture(of: pb))
  }

  /// The main-thread query is the pass's layout, and allocates nothing.
  func testLayoutQueryMatchesThePassWithoutAllocating() throws {
    let gpu = try requireGPU()
    var frame = try PictureTests.picture(width: 96, height: 60).frame(gpu, signal: .rec709)
    frame.cleanAperture = MonitorRect(x: 6, y: 3, width: 84, height: 50)
    frame.pixelAspectRatio = 1.5
    var state = MonitorState()
    state.geometry.desqueeze = 1.33
    state.geometry.magnification.zoom = 2.5
    state.geometry.magnification.centerX = 0.8
    state.geometry.flip = .vertical
    let viewport = MonitorViewport(width: 160, height: 90)
    let (_, pass) = try render(gpu, frame, state: state, width: 160, height: 90)
    let query = MonitorLayout(frame: frame, state: state, viewport: viewport)
    XCTAssertEqual(pass.layout, query)
    XCTAssertEqual(query.pictureWidth, 84)
    try skipUnderTheDebugLayer()
    var sink = 0.0
    let geometry = frame.geometry
    // `while`, not `for`-in: a debug build's range iterator allocates.
    let n = try XCTUnwrap(AllocationCounter.measure {
      var i = 0
      while i < 10 {
        let l = MonitorLayout(frame: frame, state: state, viewport: viewport)
        sink += l.fitRect.width + geometry.displayAspectRatio(for: state) + frame.geometry.shownRect.width
        i += 1
      }
    })
    XCTAssertEqual(n, 0)
    XCTAssertGreaterThan(sink, 0)
  }

  /// Steady-state frames with an aperture neither rebuild nor allocate; a changed
  /// aperture rebuilds once.
  func testApertureIsPartOfThePassKey() throws {
    let gpu = try requireGPU()
    var frame = try PictureTests.picture(width: 96, height: 54).frame(gpu, signal: .rec709)
    frame.cleanAperture = MonitorRect(x: 6, y: 2, width: 84, height: 50)
    let feed = gpu.engine.makeFeed(), pass = gpu.engine.makePass()
    let target = gpu.target(84, 50)
    try gpu.run { cb in try pass.encode(frame: frame, feed: feed, state: MonitorState(), target: target, into: cb) }
    let rebuilt = pass.rebuildCount
    try gpu.run { cb in try pass.encode(frame: frame, feed: feed, state: MonitorState(), target: target, into: cb) }
    XCTAssertEqual(pass.rebuildCount, rebuilt)
    frame.cleanAperture = MonitorRect(x: 0, y: 0, width: 84, height: 50)
    try gpu.run { cb in try pass.encode(frame: frame, feed: feed, state: MonitorState(), target: target, into: cb) }
    XCTAssertEqual(pass.rebuildCount, rebuilt + 1)
    XCTAssertEqual(pass.layout?.aperture, frame.cleanAperture)
    // A NaN aperture shows the whole frame and, like a NaN setting, rebuilds once, not per frame.
    frame.cleanAperture = MonitorRect(x: .nan, y: 0, width: 84, height: 50)
    try gpu.run { cb in try pass.encode(frame: frame, feed: feed, state: MonitorState(), target: target, into: cb) }
    try gpu.run { cb in try pass.encode(frame: frame, feed: feed, state: MonitorState(), target: target, into: cb) }
    XCTAssertEqual(pass.rebuildCount, rebuilt + 2)
    XCTAssertEqual(pass.layout?.aperture, MonitorRect(x: 0, y: 0, width: 96, height: 54))
  }

  /// Steady-state prepare with an aperture, a picture stage and a processed frame
  /// allocates nothing.
  func testSteadyStatePrepareWithApertureMakesNoHeapAllocations() throws {
    try skipUnderTheDebugLayer()
    let gpu = try requireGPU()
    var frame = try PictureTests.picture(width: 96, height: 54).frame(gpu, signal: Self.slog3)
    frame.cleanAperture = MonitorRect(x: 6, y: 2, width: 84, height: 50)
    frame.isProcessed = true
    let (burn, monitor) = try luts(gpu)
    let feed = gpu.engine.makeFeed(), pass = gpu.engine.makePass()
    feed.burnInLUT = burn
    feed.monitorLUT = monitor
    var state = MonitorState()
    everyTool(&state)
    state.pictureStage = .output
    let cb = try XCTUnwrap(gpu.queue.makeCommandBuffer())
    let viewport = MonitorViewport(width: 84, height: 50)
    var i = 0
    while i < 3 {
      try pass.prepare(frame: frame, feed: feed, state: state, viewport: viewport, targetPixelFormat: .bgra8Unorm, into: cb)
      i += 1
    }
    let n = try XCTUnwrap(
      try AllocationCounter.measure {
        var j = 0
        while j < 5 {
          try pass.prepare(
            frame: frame, feed: feed, state: state, viewport: viewport, targetPixelFormat: .bgra8Unorm, into: cb)
          j += 1
        }
      })
    XCTAssertEqual(n, 0)
    XCTAssertEqual(pass.status.pictureStage, .output)
  }

  // MARK: - Fusable sources

  static let oldAppLUTCopy = """
    #include <metal_stdlib>
    using namespace metal;
    #ifndef MK_LUT_MSL
    #define MK_LUT_MSL
    struct mk_LUTParams { float4 domainLow; float4 domainScale; uint4 shape; };
    float3 mk_applyLUT(float3 rgb, texture3d<float, access::sample> lut, mk_LUTParams p) { return rgb; }
    #endif
    """

  /// Map §4.3: prepending MKLUT.msl to a source that still has the app's older
  /// copy must not half-include. Either order fails to compile; the parts
  /// themselves include cleanly any number of times.
  func testLUTSourceCannotHalfInclude() throws {
    let gpu = try requireGPU()
    XCTAssertNoThrow(try MonitorShaders.makeLibrary(device: gpu.device, parts: [.lut, .lut, .decode, .decode, .lut]))
    XCTAssertNoThrow(try MonitorShaders.makeLibrary(device: gpu.device, parts: [.decode, .lut]))
    XCTAssertThrowsError(
      try MonitorShaders.makeLibrary(device: gpu.device, parts: [.lut], prefix: Self.oldAppLUTCopy), "old copy first")
    XCTAssertThrowsError(
      try MonitorShaders.makeLibrary(device: gpu.device, parts: [.lut], extra: Self.oldAppLUTCopy), "old copy after")
    XCTAssertEqual(MonitorShaders.lutLayoutVersion, 2)
    XCTAssertEqual(MemoryLayout<LUTParameters>.size, 80)
    XCTAssertEqual(MemoryLayout<FrameParameters>.size, 80)
    let source = try MonitorShaders.source([.lut])
    XCTAssertTrue(source.contains("#define MK_LUT_MSL_VERSION 2"))
    // A host kernel after the parts sees one mk_LUTParams of 80 bytes.
    XCTAssertNoThrow(
      try MonitorShaders.makeLibrary(
        device: gpu.device, parts: [.lut], extra: "static_assert(sizeof(mk_LUTParams) == 80, \"layout\");"))
  }

  /// What the app's burn-in needs from MonitorLUT: the trilinear kernel, the shaper,
  /// a declared Rec.709 output, and the same compile options as the library.
  func testLUTServesTheAppsBurnIn() throws {
    let gpu = try requireGPU()
    let cube = try LUTTests.cube(size: 17, seed: 3)
    let trilinear = try MonitorLUT(device: gpu.device, cube: cube, interpolation: .trilinear)
    XCTAssertEqual(trilinear.interpolation, .trilinear)
    XCTAssertEqual(trilinear.parameters.shape.y, 1)
    XCTAssertEqual(trilinear.outputEncoding, .rec709)
    let signal = trilinear.outputEncoding.signal
    XCTAssertEqual(signal.encoding, .display(.bt709))
    XCTAssertEqual(signal.effectivePrimaries, .rec709)
    XCTAssertEqual(signal.matrix, .bt709)
    let shaper = try MonitorLUT(device: gpu.device, cube: try LUTTests.shaperCube(size: 9, shaper: 1024, seed: 4))
    XCTAssertEqual(shaper.parameters.shape.w, 1024)
    XCTAssertEqual(MonitorShaders.compileOptions.mathMode, .safe)
    XCTAssertGreaterThanOrEqual(
      MonitorShaders.compileOptions.languageVersion.rawValue, MTLLanguageVersion.version4_0.rawValue)
  }
}
