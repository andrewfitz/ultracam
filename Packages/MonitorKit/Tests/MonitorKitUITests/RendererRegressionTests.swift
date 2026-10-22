import Metal
import MonitorKit
import MonitorKitCore
import MonitorKitScopes
import XCTest

@testable import MonitorKitUI

/// Regressions from the UI audit: focus analysis per surface, resubmitted
/// frames, fused scope groups, accumulation keys, the scope engine off the
/// tick, completion-based release and the per-renderer headroom.
final class RendererRegressionTests: XCTestCase {
  func monitorLUT(_ gpu: UIGPU) throws -> MonitorLUT {
    // An inverting look, so the monitor stage's values differ from the source's.
    let cube = try CubeLUT(
      text: "LUT_3D_SIZE 2\n1 1 1\n0 1 1\n1 0 1\n0 0 1\n1 1 0\n0 1 0\n1 0 0\n0 0 0\n")
    return try MonitorLUT(device: gpu.device, cube: cube)
  }

  /// Monitor-stage peaking on a surface that hides the monitor LUT is analysed
  /// on the stage it shows (the output stage), so it is drawn, every frame.
  func testMonitorStagePeakingWithTheMonitorLUTOff() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    source.setLUT(try monitorLUT(gpu), routing: .monitorOnly)
    var state = MonitorState()
    state.focus.enabled = true
    state.focus.stage = .monitor
    state.monitorLUT = false
    let surface = MonitorSurface(source: source, state: state)
    let renderer = MonitorRenderer(engine: gpu.engine, scene: MonitorScene(surfaces: [surface]))
    let target = gpu.texture(.bgra8Unorm, 64, 36)
    for i in 0..<2 {
      source.submit(try gpu.sdrFrame(seed: UInt8(i)))
      try renderer.update()
      try gpu.run { try renderer.encode(target: target, into: $0) }
      XCTAssertTrue(surface.status.isActive(.focusPeaking), "\(surface.status)")
    }
  }

  /// Surfaces of one source with different analyses (stage, level) each draw
  /// with their own mask, the same pixels as each analysed and drawn alone;
  /// surfaces that ask for the same analysis share one.
  func testSurfacesWithDifferentAnalysesEachGetTheirOwn() throws {
    let gpu = try requireGPU()
    let frame = try gpu.sdrFrame(width: 96, height: 54)
    let lut = try monitorLUT(gpu)
    let source = MonitorSource()
    source.setLUT(lut, routing: .monitorOnly)
    source.submit(frame)
    func peaking(_ stage: SignalStage, _ sensitivity: Double, _ color: PeakingColor = .red) -> MonitorState {
      var s = MonitorState()
      s.focus.enabled = true
      s.focus.stage = stage
      s.focus.sensitivity = sensitivity
      s.focus.color = color
      s.focus.opacity = 1
      return s
    }
    let states = [
      peaking(.source, 0.25), peaking(.monitor, 0.25), peaking(.source, 0.9), peaking(.source, 0.25, .yellow),
    ]
    let regions = (0..<4).map { MonitorRegion(x: Double($0) / 4, y: 0, width: 0.25, height: 1) }
    let surfaces = (0..<4).map { MonitorSurface(source: source, state: states[$0], region: regions[$0]) }
    let renderer = MonitorRenderer(engine: gpu.engine, scene: MonitorScene(surfaces: surfaces))
    let target = gpu.texture(.bgra8Unorm, 160, 40)
    try renderer.update()
    try gpu.run { try renderer.encode(target: target, into: $0) }
    XCTAssertEqual(renderer.feedCount(for: source), 3, "three distinct analyses; the fourth shares the first's")
    XCTAssertTrue(renderer.feed(for: surfaces[0]) === renderer.feed(for: surfaces[3]))
    XCTAssertFalse(renderer.feed(for: surfaces[0]) === renderer.feed(for: surfaces[2]))
    for s in surfaces { XCTAssertTrue(s.status.isActive(.focusPeaking), "\(s.status)") }

    let reference = gpu.texture(.bgra8Unorm, 160, 40)
    try gpu.run { cb in
      for i in 0..<4 {
        let feed = gpu.engine.makeFeed()
        feed.monitorLUT = lut
        try feed.analyze(frame, focus: states[i].focus, into: cb)
        let vp = regions[i].viewport(width: 160, height: 40)!
        try gpu.engine.makePass().encode(
          frame: frame, feed: feed, state: states[i], target: reference, viewport: vp, clear: i == 0, into: cb)
      }
    }
    XCTAssertEqual(Texels(target), Texels(reference))

    // A steady frame analyses nothing more; dropping the odd ones out frees their feeds.
    let counts = (0..<4).map { renderer.feed(for: surfaces[$0])!.analysisCount }
    renderer.setNeedsDisplay()
    try renderer.update()
    try gpu.run { try renderer.encode(target: target, into: $0) }
    XCTAssertEqual((0..<4).map { renderer.feed(for: surfaces[$0])!.analysisCount }, counts)
    surfaces[1].updateState { $0.focus.enabled = false }
    surfaces[2].updateState { $0.focus.enabled = false }
    try renderer.update()
    try gpu.run { try renderer.encode(target: target, into: $0) }
    XCTAssertEqual(renderer.feedCount(for: source), 1)
  }

  /// A surface that draws nothing (an empty region) asks for no analysis.
  func testAnUndrawnSurfaceAnalysesNothing() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    source.submit(try gpu.sdrFrame())
    var state = MonitorState()
    state.focus.enabled = true
    let hidden = MonitorSurface(source: source, state: state, region: MonitorRegion(x: 0, y: 0, width: 0, height: 1))
    let shown = MonitorSurface(source: source)
    let renderer = MonitorRenderer(engine: gpu.engine, scene: MonitorScene(surfaces: [hidden, shown]))
    let target = gpu.texture(.bgra8Unorm, 64, 36)
    try renderer.update()
    try gpu.run { try renderer.encode(target: target, into: $0) }
    XCTAssertEqual(renderer.feed(for: source)?.analysisCount, 0)
    hidden.region = MonitorRegion(x: 0, y: 0, width: 0.5, height: 1)
    try renderer.update()
    try gpu.run { try renderer.encode(target: target, into: $0) }
    XCTAssertEqual(renderer.feed(for: source)?.analysisCount, 1)
    XCTAssertTrue(hidden.status.isActive(.focusPeaking))
  }

  /// A frame resubmitted with the same id but a new signal (a signal override
  /// on a paused source) is taken: the layer is re-tagged and the pass draws it.
  func testResubmittedFrameWithANewSignalIsTaken() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    var frame = try gpu.sdrFrame()
    source.submit(frame)
    let surface = MonitorSurface(source: source)
    let renderer = MonitorRenderer(engine: gpu.engine, scene: MonitorScene(surfaces: [surface]))
    let target = gpu.texture(.bgra8Unorm, 64, 36)
    try renderer.update()
    try gpu.run { try renderer.encode(target: target, into: $0) }
    XCTAssertEqual(renderer.layerColor, MonitorLayerColor(primaries: .rec709, kind: .sdr(.bt1886)))
    frame.signal = SignalDescription(range: .full, matrix: .bt2020, encoding: .display(.pq), primaries: .rec2020)
    source.submit(frame)
    XCTAssertTrue(try renderer.update())
    XCTAssertEqual(renderer.layerColor, MonitorLayerColor(primaries: .rec2020, kind: .pq))
    XCTAssertEqual(renderer.frame(for: source)?.signal.encoding, .display(.pq))
    frame.pixelAspectRatio = 2
    source.submit(frame)
    XCTAssertTrue(try renderer.update())
    try gpu.run { try renderer.encode(target: target, into: $0) }
    XCTAssertEqual(surface.layout?.imageRect.width ?? 0, 64, accuracy: 1e-9, "a 2:1 pixel aspect fills the width")
    // The very same frame again changes nothing.
    source.submit(frame)
    XCTAssertFalse(try renderer.update())
  }

  /// Waveform, vectorscope and histogram of one source and stage accumulate in
  /// one fused group pass, with the pixels of three separate accumulations.
  func testScopesOfASourceShareOneFusedGroup() throws {
    let gpu = try requireGPU()
    let scopes = try gpu.scopeEngine()
    let frame = try gpu.sdrFrame(width: 96, height: 54)
    let source = MonitorSource()
    source.submit(frame)
    var w = ScopeSettings(kind: .waveform, stage: .output)
    w.waveformColumns = 128
    w.waveformLevels = 128
    let settings = [w, ScopeSettings(kind: .vectorscope, stage: .output), ScopeSettings(kind: .histogram, stage: .output)]
    let regions = (0..<3).map { MonitorRegion(x: Double($0) / 3, y: 0, width: 1.0 / 3, height: 1) }
    let overlays = (0..<3).map { MonitorScopeOverlay(source: source, settings: settings[$0], region: regions[$0]) }
    let renderer = MonitorRenderer(engine: gpu.engine, scene: MonitorScene(scopes: overlays), scopeEngine: scopes)
    let target = gpu.texture(.bgra8Unorm, 192, 64)
    try renderer.update()
    try gpu.run { try renderer.encode(target: target, into: $0) }
    let group = try XCTUnwrap(renderer.scopeGroup(for: overlays[0]))
    XCTAssertTrue(renderer.scopeGroup(for: overlays[1]) === group)
    XCTAssertTrue(renderer.scopeGroup(for: overlays[2]) === group)
    XCTAssertEqual(group.fusedMemberCount, 3)

    let reference = gpu.texture(.bgra8Unorm, 192, 64)
    let feed = gpu.engine.makeFeed()
    try gpu.run { cb in
      let clear = MTLRenderPassDescriptor()
      clear.colorAttachments[0].texture = reference
      clear.colorAttachments[0].loadAction = .clear
      clear.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
      clear.colorAttachments[0].storeAction = .store
      cb.makeRenderCommandEncoder(descriptor: clear)!.endEncoding()
      for i in 0..<3 {
        let a = try scopes.makeAccumulator(settings: settings[i])
        try a.accumulate(frame, feed: feed, into: cb)
        let r = scopes.makeRenderer()
        r.setOutputColor(MonitorOutputColor.signalNative.explicit(for: renderer.layerColor))
        try r.render(a, target: reference, viewport: regions[i].viewport(width: 192, height: 64)!, clear: false, into: cb)
      }
    }
    XCTAssertEqual(Texels(target), Texels(reference))
  }

  /// Display edits and moves redraw from the cached bins; a bin setting, a new
  /// frame or the monitor-LUT choice re-accumulates.
  func testOnlyWhatTheBinsDependOnReaccumulates() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    source.setLUT(try monitorLUT(gpu), routing: .monitorOnly)
    source.submit(try gpu.sdrFrame())
    let overlay = MonitorScopeOverlay(source: source, settings: ScopeSettings(kind: .waveform, stage: .monitor))
    let renderer = MonitorRenderer(
      engine: gpu.engine, scene: MonitorScene(scopes: [overlay]), scopeEngine: try gpu.scopeEngine())
    let target = gpu.texture(.bgra8Unorm, 64, 36)
    func draw() throws -> UInt32 {
      try renderer.update()
      try gpu.run { try renderer.encode(target: target, into: $0) }
      return renderer.accumulator(for: overlay)!.generation
    }
    let first = try draw()
    var s = overlay.settings
    s.display.brightness = 0.9
    s.display.graticuleOpacity = 0.2
    overlay.settings = s
    XCTAssertEqual(try draw(), first, "a display edit")
    XCTAssertEqual(renderer.accumulator(for: overlay)?.settings.display.brightness, 0.9)
    overlay.region = MonitorRegion(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    XCTAssertEqual(try draw(), first, "a move")
    s.waveformMode = .rgbParade
    overlay.settings = s
    let parade = try draw()
    XCTAssertNotEqual(parade, first, "a bin setting")
    overlay.monitorLUTEnabled = false
    let noLUT = try draw()
    XCTAssertNotEqual(noLUT, parade, "the monitor-LUT choice")
    XCTAssertFalse(renderer.accumulator(for: overlay)!.appliedMonitorLUT)
    source.submit(try gpu.sdrFrame(seed: 3))
    XCTAssertNotEqual(try draw(), noLUT, "a new frame")
  }

  /// Without a scope engine the renderer builds the engine's shared one off the
  /// display thread: the pictures draw meanwhile, the scope joins when it is ready.
  func testScopeEngineBuildsOffTheTick() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    source.submit(try gpu.sdrFrame())
    let surface = MonitorSurface(source: source, region: MonitorRegion(x: 0, y: 0, width: 0.5, height: 1))
    let overlay = MonitorScopeOverlay(
      source: source, settings: ScopeSettings(kind: .histogram), region: MonitorRegion(x: 0.5, y: 0, width: 0.5, height: 1))
    let renderer = MonitorRenderer(engine: gpu.engine, scene: MonitorScene(surfaces: [surface], scopes: [overlay]))
    let target = gpu.texture(.bgra8Unorm, 64, 36)
    try renderer.update()
    try gpu.run { try renderer.encode(target: target, into: $0) }
    XCTAssertNotNil(surface.layout, "the picture draws while the scopes build")
    let deadline = Date().addingTimeInterval(60)
    while renderer.accumulator(for: overlay) == nil && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
      try renderer.update()
    }
    let accumulator = try XCTUnwrap(renderer.accumulator(for: overlay))
    XCTAssertTrue(renderer.scopeEngine === (try MonitorRenderer.sharedScopeEngine(for: gpu.engine)))
    XCTAssertTrue(renderer.needsDisplay(width: 64, height: 36, pixelFormat: .bgra8Unorm))
    try gpu.run { try renderer.encode(target: target, into: $0) }
    XCTAssertTrue(accumulator.hasData)
    XCTAssertNil(renderer.lastError)
  }

  /// Completion reported by the host releases replaced frames at once; an idle
  /// release drops the source's frame too, and the next tick takes it back.
  func testCompletionAndIdleReleases() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    let renderer = MonitorRenderer(engine: gpu.engine, scene: MonitorScene(surfaces: [MonitorSurface(source: source)]))
    let target = gpu.texture(.bgra8Unorm, 16, 9)
    source.submit(try gpu.sdrFrame(width: 16, height: 9))
    try renderer.update()
    try gpu.run { try renderer.encode(target: target, into: $0) }
    source.submit(try gpu.sdrFrame(width: 16, height: 9, seed: 1))
    try renderer.update()
    try gpu.run { try renderer.encode(target: target, into: $0) }
    XCTAssertEqual(renderer.retiredCount, 1, "held for the window")
    renderer.noteCompleted(through: renderer.encodeCount)
    XCTAssertEqual(renderer.retiredCount, 0, "released once reported complete")

    weak var held: MTLTexture?
    try autoreleasepool {
      let f = try gpu.sdrFrame(width: 16, height: 9, seed: 2)
      held = f.luma
      source.submit(f)
      try renderer.update()
      try gpu.run { try renderer.encode(target: target, into: $0) }
      source.clear()  // the host's slot lets go; only the renderer holds it
    }
    let sequence = source.sequence
    source.submit(try gpu.sdrFrame(width: 16, height: 9, seed: 3))
    // Paused: no tick takes the newer frame.
    XCTAssertNotNil(held)
    renderer.noteCompleted(through: renderer.encodeCount)
    renderer.releaseIdleResources()
    XCTAssertNil(renderer.frame(for: source))
    XCTAssertNil(held, "a paused renderer pins no frame")
    XCTAssertGreaterThan(source.sequence, sequence)
    XCTAssertTrue(try renderer.update(), "the next tick takes the latest frame")
    XCTAssertNotNil(renderer.frame(for: source))
  }

  /// A renderer's own headroom (its view's screen) wins over the scene's.
  func testDisplayHeadroomOverridesTheScene() throws {
    let gpu = try requireGPU()
    let scene = MonitorScene()
    scene.headroom = 2
    let renderer = MonitorRenderer(engine: gpu.engine, scene: scene)
    try renderer.update()
    XCTAssertEqual(renderer.headroom, 2)
    renderer.displayHeadroom = 5
    try renderer.update()
    XCTAssertEqual(renderer.headroom, 5)
    renderer.displayHeadroom = .nan
    try renderer.update()
    XCTAssertEqual(renderer.headroom, 1)
    renderer.displayHeadroom = nil
    try renderer.update()
    XCTAssertEqual(renderer.headroom, 2)
  }
}
