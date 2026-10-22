import AppKit
import Metal
import MonitorKitScopes
import SwiftUI
import MonitorKit
import MonitorKitCore
import Synchronization
import XCTest

@testable import MonitorKitUI

/// The view without a window or display link: its drawable-free draw runs the
/// exact tick a display link runs, so layer tagging, headroom and gestures are
/// testable headless.
@MainActor
final class MetalViewTests: XCTestCase {
  func makeView(_ gpu: UIGPU, surfaces: [MonitorSurface], mode: MonitorMetalViewMode? = nil) -> MonitorMetalView {
    MonitorMetalView(
      engine: gpu.engine, scene: MonitorScene(surfaces: surfaces), mode: mode ?? .convenience(queue: gpu.queue))
  }

  func draw(_ view: MonitorMetalView, _ gpu: UIGPU, into target: MTLTexture) throws {
    try gpu.run { view.drawOffscreen(into: target, commandBuffer: $0) }
  }

  func testLayerStartsAsRec709AndIsConfiguredForLowLatency() throws {
    let gpu = try requireGPU()
    let view = MonitorMetalView(
      engine: gpu.engine, mode: .convenience(queue: gpu.queue),
      configuration: MonitorMetalViewConfiguration(maximumDrawableCount: 9, preferredFrameLatency: 0))
    let layer = view.metalLayer
    XCTAssertTrue(view.layer === layer, "the view is backed by its CAMetalLayer")
    XCTAssertEqual(layer.pixelFormat, .bgr10a2Unorm)
    XCTAssertEqual(layer.colorspace?.name as String?, CGColorSpace.itur_709 as String)
    XCTAssertFalse(layer.wantsExtendedDynamicRangeContent)
    XCTAssertEqual(layer.maximumDrawableCount, 3, "clamped to 2…3")
    XCTAssertEqual(view.configuration.preferredFrameLatency, 1, "clamped to 1…2")
    XCTAssertFalse(layer.presentsWithTransaction)
    XCTAssertTrue(layer.framebufferOnly)
    XCTAssertTrue(layer.device === gpu.device)
    XCTAssertTrue(view.commandQueue === gpu.queue, "a given queue is used, none created")
    XCTAssertNotNil(MonitorMetalView(engine: gpu.engine).commandQueue, "one is created only when none is given")
    XCTAssertNil(MonitorMetalView(engine: gpu.engine, mode: .hostDriven { _ in true }).commandQueue)
  }

  /// The layer follows the scene's output colour on the next tick: pixel format,
  /// colour space, EDR and its metadata, for PQ, extended linear and SDR.
  func testLayerFollowsOutputColor() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    source.submit(try gpu.pqFrame())
    let view = makeView(gpu, surfaces: [MonitorSurface(source: source)])
    let target = gpu.texture(.rgba16Float, 64, 16)
    try draw(view, gpu, into: target)
    let layer = view.metalLayer
    XCTAssertEqual(layer.pixelFormat, .rgba16Float)
    XCTAssertEqual(layer.colorspace?.name as String?, CGColorSpace.itur_2100_PQ as String)
    XCTAssertTrue(layer.wantsExtendedDynamicRangeContent)
    XCTAssertNotNil(layer.edrMetadata)

    view.scene.outputColor = MonitorOutputColor(primaries: .displayP3, encoding: .extendedLinear)
    try draw(view, gpu, into: target)
    XCTAssertEqual(layer.colorspace?.name as String?, CGColorSpace.extendedLinearDisplayP3 as String)
    XCTAssertTrue(layer.wantsExtendedDynamicRangeContent)
    XCTAssertNil(layer.edrMetadata)

    view.scene.outputColor = MonitorOutputColor(primaries: .rec709, encoding: .sdr(.sRGB))
    let sdr = gpu.texture(.bgr10a2Unorm, 64, 16)
    try draw(view, gpu, into: sdr)
    XCTAssertEqual(layer.pixelFormat, .bgr10a2Unorm)
    XCTAssertEqual(layer.colorspace?.name as String?, CGColorSpace.sRGB as String)
    XCTAssertFalse(layer.wantsExtendedDynamicRangeContent)
    XCTAssertEqual(view.driver.layerChanges, 3)
    try draw(view, gpu, into: sdr)
    XCTAssertEqual(view.driver.layerChanges, 3, "an unchanged colour is not re-applied")
  }

  /// The headroom reaches the pass's uniforms through the scene.
  func testHeadroomOverridePropagates() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    source.submit(try gpu.pqFrame())
    var state = MonitorState()
    state.displayTransform.mode = .hdrPassthrough
    let surface = MonitorSurface(source: source, state: state)
    let view = makeView(gpu, surfaces: [surface])
    view.scene.outputColor = MonitorOutputColor(primaries: .rec2020, encoding: .extendedLinear)
    let target = gpu.texture(.rgba16Float, 64, 16)
    var brightest: [Float] = []
    for h in [1.0, 6.0] {
      view.headroomOverride = h
      XCTAssertEqual(view.headroom, h)
      XCTAssertEqual(view.scene.headroom, 1, "the view's screen is its own: the shared scene is untouched")
      try draw(view, gpu, into: target)
      XCTAssertEqual(view.renderer.headroom, h)
      XCTAssertEqual(view.renderer.pass(for: surface)?.outputColor.headroom, h)
      brightest.append(Texels(target)[63, 4].x)
    }
    XCTAssertGreaterThan(brightest[1], brightest[0])
    view.headroomOverride = .nan
    XCTAssertEqual(view.headroom, 1)
  }

  /// The view's tick draws what its renderer draws on its own.
  func testOffscreenDrawMatchesTheRenderer() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    let frame = try gpu.sdrFrame()
    source.submit(frame)
    var state = MonitorState()
    state.falseColor.mode = .sixBand
    let view = makeView(gpu, surfaces: [MonitorSurface(source: source, state: state)])
    let target = gpu.texture(.bgr10a2Unorm, 80, 45)
    try draw(view, gpu, into: target)

    let renderer = MonitorRenderer(engine: gpu.engine, scene: MonitorScene(surfaces: [MonitorSurface(source: source, state: state)]))
    let reference = gpu.texture(.bgr10a2Unorm, 80, 45)
    try renderer.update()
    try gpu.run { try renderer.encode(target: reference, into: $0) }
    XCTAssertEqual(Texels(target), Texels(reference))
    XCTAssertEqual(view.drawCount, 1)
  }

  /// Host mode: the view only hands over a target and calls the host, which
  /// draws (here the view's own scene) into its own command buffer.
  func testHostDrivenModeCallsTheHost() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    source.submit(try gpu.sdrFrame())
    // The closure runs on the link's thread, so what it records is behind a lock.
    let log = Mutex<[(needs: Bool, drawable: Bool, texture: ObjectIdentifier)]>([])
    let view = MonitorMetalView(
      engine: gpu.engine, scene: MonitorScene(surfaces: [MonitorSurface(source: source)]),
      mode: .hostDriven { context in
        let call = (needs: context.needsDisplay, drawable: context.drawable != nil, texture: ObjectIdentifier(context.texture))
        log.withLock { $0.append(call) }
        guard context.needsDisplay else { return false }
        let cb = gpu.queue.makeCommandBuffer()!
        try? context.renderer.encode(target: context.texture, into: cb)
        cb.commit()
        cb.waitUntilCompleted()
        return true
      })
    view.headroomOverride = 2
    let target = gpu.texture(.bgra8Unorm, 32, 18)
    view.drawOffscreen(into: target)
    view.drawOffscreen(into: target)
    let calls = log.withLock { $0 }
    XCTAssertEqual(calls.count, 2)
    XCTAssertEqual(calls.map(\.needs), [true, false])
    XCTAssertEqual(calls.map(\.drawable), [false, false])
    XCTAssertTrue(calls.allSatisfy { $0.texture == ObjectIdentifier(target) })
    XCTAssertEqual(view.drawCount, 1)
    XCTAssertEqual(view.skippedCount, 1)
    XCTAssertGreaterThan(Texels(target).values.reduce(0) { $0 + $1.x }, 0, "the host drew the picture")
  }

  func testDrawableSizeFollowsBoundsAndScale() throws {
    let gpu = try requireGPU()
    let view = MonitorMetalView(engine: gpu.engine)
    view.setFrameSize(NSSize(width: 200, height: 100))
    XCTAssertEqual(view.metalLayer.drawableSize, CGSize(width: 200, height: 100))
    view.metalLayer.contentsScale = 2
    view.setFrameSize(NSSize(width: 150.5, height: 80))
    XCTAssertEqual(view.metalLayer.drawableSize, CGSize(width: 301, height: 160))
    XCTAssertEqual(view.driver.pixelsPerPoint, 2)
  }

  /// Keyboard and mouse edit the surface's magnification through `MonitorMagnifier`
  /// and report it, normalized.
  func testKeyboardAndMouseEditMagnification() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    source.submit(try gpu.sdrFrame(width: 160, height: 90))
    let surface = MonitorSurface(source: source)
    let view = makeView(gpu, surfaces: [surface])
    view.setFrameSize(NSSize(width: 160, height: 90))
    var reported = 0
    view.onSurfaceStateChange = { s in
      XCTAssertTrue(s === surface)
      reported += 1
    }
    let target = gpu.texture(.bgra8Unorm, 160, 90)
    try draw(view, gpu, into: target)
    XCTAssertNotNil(surface.layout)

    func key(_ characters: String, _ code: UInt16) -> NSEvent {
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
        characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
    func mouse(_ type: NSEvent.EventType, _ x: Double, _ y: Double, clicks: Int = 1) -> NSEvent {
      NSEvent.mouseEvent(
        with: type, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
        eventNumber: 0, clickCount: clicks, pressure: 1)!
    }
    view.keyDown(with: key("+", 24))
    XCTAssertEqual(surface.state.geometry.magnification.zoom, 1.25, accuracy: 1e-9)
    XCTAssertEqual(reported, 1)
    try draw(view, gpu, into: target)
    let before = try XCTUnwrap(surface.layout).imageRect
    view.mouseDown(with: mouse(.leftMouseDown, 80, 45))
    view.mouseDragged(with: mouse(.leftMouseDragged, 70, 45))
    view.mouseUp(with: mouse(.leftMouseUp, 70, 45))
    try draw(view, gpu, into: target)
    let after = try XCTUnwrap(surface.layout).imageRect
    XCTAssertEqual(after.x, before.x - 10, accuracy: 1e-6, "the picture follows the drag")
    view.keyDown(with: key("0", 29))
    XCTAssertEqual(surface.state.geometry.magnification, Magnification())
    try draw(view, gpu, into: target)
    view.mouseDown(with: mouse(.leftMouseDown, 40, 30, clicks: 2))
    XCTAssertTrue(surface.state.geometry.magnification.pixelExact)
    XCTAssertGreaterThanOrEqual(reported, 4)
    XCTAssertEqual(surface.state, surface.state.normalized())
  }

  /// Every event counts: zooms and drags that arrive between draws build on each
  /// other, since each maps through the layout of the surface's current state in
  /// this view, not the last draw's. Here the host never draws at all.
  func testGesturesBetweenDrawsAccumulate() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    source.submit(try gpu.sdrFrame(width: 320, height: 180))
    var state = MonitorState()
    state.geometry.magnification.zoom = 4
    let surface = MonitorSurface(source: source, state: state)
    let view = MonitorMetalView(
      engine: gpu.engine, scene: MonitorScene(surfaces: [surface]), mode: .hostDriven { _ in false })
    view.setFrameSize(NSSize(width: 160, height: 90))
    XCTAssertNil(surface.layout, "nothing was drawn")
    func key(_ characters: String, _ code: UInt16) -> NSEvent {
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
        characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
    func mouse(_ type: NSEvent.EventType, _ x: Double, _ y: Double) -> NSEvent {
      NSEvent.mouseEvent(
        with: type, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    view.keyDown(with: key("+", 24))
    view.keyDown(with: key("+", 24))
    XCTAssertEqual(surface.state.geometry.magnification.zoom, 4 * 1.25 * 1.25, accuracy: 1e-9)

    func imageX() -> Double {
      MonitorLayout(
        pictureWidth: 320, pictureHeight: 180, viewportWidth: 160, viewportHeight: 90,
        geometry: surface.state.geometry
      ).imageRect.x
    }
    let before = imageX()
    view.mouseDown(with: mouse(.leftMouseDown, 80, 45))
    view.mouseDragged(with: mouse(.leftMouseDragged, 70, 45))
    view.mouseDragged(with: mouse(.leftMouseDragged, 60, 45))
    view.mouseUp(with: mouse(.leftMouseUp, 60, 45))
    XCTAssertEqual(imageX(), before - 20, accuracy: 1e-6, "two drags of 10 px move the picture 20 px")
  }

  /// One scene in two views of different sizes and screens: each view's
  /// gestures map through its own size, and each keeps its own screen headroom.
  func testOneSceneInTwoViews() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    source.submit(try gpu.sdrFrame(width: 320, height: 180))
    var state = MonitorState()
    state.geometry.magnification.zoom = 4
    let surface = MonitorSurface(source: source, state: state)
    let scene = MonitorScene(surfaces: [surface])
    let small = MonitorMetalView(engine: gpu.engine, scene: scene, mode: .convenience(queue: gpu.queue))
    let large = MonitorMetalView(engine: gpu.engine, scene: scene, mode: .convenience(queue: gpu.queue))
    small.setFrameSize(NSSize(width: 160, height: 90))
    large.setFrameSize(NSSize(width: 320, height: 180))
    small.headroomOverride = 1
    large.headroomOverride = 4
    try draw(small, gpu, into: gpu.texture(.bgra8Unorm, 160, 90))  // publishes the small view's layout
    func imageX() -> Double {
      MonitorLayout(
        pictureWidth: 320, pictureHeight: 180, viewportWidth: 320, viewportHeight: 180, geometry: surface.state.geometry
      ).imageRect.x
    }
    let before = imageX()
    func mouse(_ type: NSEvent.EventType, _ x: Double) -> NSEvent {
      NSEvent.mouseEvent(
        with: type, location: NSPoint(x: x, y: 90), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    large.mouseDown(with: mouse(.leftMouseDown, 160))
    large.mouseDragged(with: mouse(.leftMouseDragged, 150))
    large.mouseUp(with: mouse(.leftMouseUp, 150))
    XCTAssertEqual(imageX(), before - 10, accuracy: 1e-6, "10 points in the large view move its picture 10 pixels")
    try draw(large, gpu, into: gpu.texture(.bgra8Unorm, 320, 180))
    try draw(small, gpu, into: gpu.texture(.bgra8Unorm, 160, 90))
    XCTAssertEqual(small.renderer.headroom, 1)
    XCTAssertEqual(large.renderer.headroom, 4)
  }

  /// The same two steps straight through `MonitorMagnifier` against one stale
  /// layout lose the first (what the view used to do); against the state they add.
  func testMagnifierStepsAgainstTheStateAdd() {
    var g = ViewGeometry()
    g.magnification.zoom = 4
    func layout(_ g: ViewGeometry) -> MonitorLayout {
      MonitorLayout(pictureWidth: 1920, pictureHeight: 1080, viewportWidth: 960, viewportHeight: 540, geometry: g)
    }
    let stale = layout(g)
    var m = MonitorMagnifier.zoom(g.magnification, by: 1.5, about: (480, 270), layout: stale)
    m = MonitorMagnifier.zoom(m, by: 1.5, about: (480, 270), layout: stale)
    XCTAssertEqual(m.zoom, 6, accuracy: 1e-9, "a stale layout drops a step")
    var fresh = g
    fresh.magnification = MonitorMagnifier.zoom(fresh.magnification, by: 1.5, about: (480, 270), layout: layout(fresh))
    fresh.magnification = MonitorMagnifier.zoom(fresh.magnification, by: 1.5, about: (480, 270), layout: layout(fresh))
    XCTAssertEqual(fresh.magnification.zoom, 9, accuracy: 1e-9)
  }

  /// A paused view keeps no frame once its command buffers completed, so a
  /// capture pool needs no spare buffers for a hidden monitor; resumed, it draws
  /// the source's latest frame again.
  func testPausedViewReleasesItsFrames() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    let view = makeView(gpu, surfaces: [MonitorSurface(source: source)])
    let target = gpu.texture(.bgra8Unorm, 32, 18)
    weak var held: MTLTexture?
    try autoreleasepool {
      let f = try gpu.sdrFrame(width: 32, height: 18)
      held = f.luma
      source.submit(f)
      view.drawOffscreen(into: target)  // into the view's own command buffer
      source.submit(try gpu.sdrFrame(width: 32, height: 18, seed: 1))
    }
    XCTAssertNotNil(held, "the renderer still holds the frame it drew")
    view.isPaused = true
    // The view releases again once its last buffers completed (the idle marker's handler).
    let end = Date().addingTimeInterval(2)
    while Date() < end && (view.renderer.frame(for: source) != nil || held != nil) {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertNil(view.renderer.frame(for: source))
    XCTAssertNil(held, "a paused view pins no frame")
    view.isPaused = false
    view.drawOffscreen(into: target)
    XCTAssertNotNil(view.renderer.frame(for: source))
  }

  func testGesturesCanBeTurnedOff() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    source.submit(try gpu.sdrFrame())
    let surface = MonitorSurface(source: source)
    let view = MonitorMetalView(
      engine: gpu.engine, scene: MonitorScene(surfaces: [surface]), mode: .convenience(queue: gpu.queue),
      configuration: MonitorMetalViewConfiguration(gesturesEnabled: false))
    try draw(view, gpu, into: gpu.texture(.bgra8Unorm, 64, 36))
    XCTAssertFalse(view.acceptsFirstResponder)
    view.mouseDown(
      with: NSEvent.mouseEvent(
        with: .leftMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, eventNumber: 0, clickCount: 2, pressure: 1)!)
    XCTAssertFalse(surface.state.geometry.magnification.pixelExact)
  }

  /// Status changes reach the main thread once per change, with VoiceOver's value.
  func testStatusChangesAreReported() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    source.submit(try gpu.sdrFrame())
    let surface = MonitorSurface(source: source)
    let view = makeView(gpu, surfaces: [surface])
    var changes = 0
    view.onStatusChange = { changes += 1 }
    let target = gpu.texture(.bgra8Unorm, 64, 36)
    try draw(view, gpu, into: target)
    surface.updateState { $0.falseColor.mode = .sixBand }
    try draw(view, gpu, into: target)
    try draw(view, gpu, into: target)
    XCTAssertEqual(changes, 2)
    XCTAssertEqual(view.accessibilityValue() as? String, surface.status.activeLabels.joined(separator: ", "))
    XCTAssertEqual(view.accessibilityRole(), .image)
  }
}

/// The SwiftUI representables: the binding and the surface stay in step both ways.
@MainActor
final class RepresentableTests: XCTestCase {
  func metalView(in view: NSView) -> MonitorMetalView? {
    if let v = view as? MonitorMetalView { return v }
    for sub in view.subviews { if let v = metalView(in: sub) { return v } }
    return nil
  }

  func testMonitorViewSyncsStateBothWays() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    source.submit(try gpu.sdrFrame(width: 160, height: 90))
    var initial = MonitorState()
    initial.zebras[0] = ZebraSet(mode: .lowerLimit, level: 500)  // normalized to 120 on the way in
    let box = Box(initial)
    var statuses: [MonitorStatus] = []
    func root() -> some View {
      MonitorView(
        engine: gpu.engine, source: source, state: box.binding, queue: gpu.queue,
        onStatusChange: { statuses.append($0) }
      ).frame(width: 160, height: 90)
    }
    let hosting = NSHostingView(rootView: root())
    hosting.frame = NSRect(x: 0, y: 0, width: 160, height: 90)
    hosting.layoutSubtreeIfNeeded()
    let view = try XCTUnwrap(metalView(in: hosting))
    let surface = try XCTUnwrap(view.scene.surfaces.first)
    XCTAssertTrue(view.commandQueue === gpu.queue)
    XCTAssertEqual(surface.state, initial.normalized())
    XCTAssertEqual(surface.state.zebras[0].level, 120)
    let revision = surface.revision

    // Binding → surface; an unchanged binding bumps nothing.
    hosting.rootView = root()
    hosting.layoutSubtreeIfNeeded()
    XCTAssertEqual(surface.revision, revision)
    box.value.falseColor.mode = .sixBand
    hosting.rootView = root()
    hosting.layoutSubtreeIfNeeded()
    XCTAssertEqual(surface.state.falseColor.mode, .sixBand)

    // Gesture → binding, normalized.
    let target = gpu.texture(.bgra8Unorm, 160, 90)
    try gpu.run { view.drawOffscreen(into: target, commandBuffer: $0) }
    XCTAssertTrue(statuses.last?.isActive(.falseColor) == true, "status reported: \(statuses)")
    view.keyDown(
      with: NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
        characters: "+", charactersIgnoringModifiers: "+", isARepeat: false, keyCode: 24)!)
    XCTAssertEqual(box.value.geometry.magnification.zoom, 1.25, accuracy: 1e-9)
    XCTAssertEqual(box.value, surface.state)
    // And the round trip does not bounce back as a new edit.
    let afterGesture = surface.revision
    hosting.rootView = root()
    hosting.layoutSubtreeIfNeeded()
    XCTAssertEqual(surface.revision, afterGesture)

    // A new source swaps the surface and keeps the state.
    let other = MonitorSource()
    other.submit(try gpu.sdrFrame(seed: 7))
    let swapped = NSHostingView(rootView: MonitorView(engine: gpu.engine, source: source, state: box.binding))
    swapped.frame = NSRect(x: 0, y: 0, width: 64, height: 36)
    swapped.layoutSubtreeIfNeeded()
    swapped.rootView = MonitorView(engine: gpu.engine, source: other, state: box.binding)
    swapped.layoutSubtreeIfNeeded()
    let swappedView = try XCTUnwrap(metalView(in: swapped))
    XCTAssertTrue(swappedView.scene.surfaces.first?.source === other)
    XCTAssertEqual(swappedView.scene.surfaces.first?.state, box.value)
  }

  func testScopeViewPublishesLabels() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    source.submit(try gpu.sdrFrame(width: 96, height: 54))
    let hosting = NSHostingView(
      rootView: ScopeView(
        engine: gpu.engine, scopeEngine: try gpu.scopeEngine(), source: source,
        settings: ScopeSettings(kind: .waveform), queue: gpu.queue
      ).frame(width: 200, height: 120))
    hosting.frame = NSRect(x: 0, y: 0, width: 200, height: 120)
    hosting.layoutSubtreeIfNeeded()
    let view = try XCTUnwrap(metalView(in: hosting))
    XCTAssertFalse(view.configuration.gesturesEnabled)
    let overlay = try XCTUnwrap(view.scene.scopes.first)
    XCTAssertTrue(view.scene.surfaces.isEmpty)
    var notified = 0
    let forward = view.onGraticuleChange
    view.onGraticuleChange = {
      notified += 1
      forward?()
    }
    try gpu.run { view.drawOffscreen(into: gpu.texture(.bgra8Unorm, 200, 120), commandBuffer: $0) }
    XCTAssertEqual(notified, 1)
    XCTAssertFalse(overlay.graticule?.labels.isEmpty ?? true)
    XCTAssertTrue(overlay.graticule?.labels.contains { $0.text == "100" } == true, "the 100% tick is labelled")
    XCTAssertEqual(ScopeLabelsView.anchor(.leading), UnitPoint(x: 0, y: 0.5))
    XCTAssertEqual(ScopeLabelsView.anchor(.top), UnitPoint(x: 0.5, y: 0))
  }
}
