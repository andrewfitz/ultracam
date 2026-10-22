import Metal
import MonitorKitCore
import XCTest

@testable import MonitorKit

/// Items other streams left open for the picture module, fixed at integration.
final class IntegrationRegressionTests: XCTestCase {
  /// Render state a host may leave in its pass: GL-style winding with back-face
  /// culling, wireframe fill and a tiny scissor. Before, the picture inherited it
  /// and drew only lines inside a 4×4 corner (or nothing at all).
  static func hostileState(_ setWinding: (MTLWinding) -> Void, _ setCull: (MTLCullMode) -> Void,
    _ setFill: (MTLTriangleFillMode) -> Void, _ setScissor: (MTLScissorRect) -> Void) {
    setWinding(.counterClockwise)
    setCull(.back)
    setFill(.lines)
    setScissor(MTLScissorRect(x: 0, y: 0, width: 4, height: 4))
  }

  func testHostRenderStateCannotHideThePicture() throws {
    let gpu = try requireGPU()
    let frame = try PictureTests.picture(width: 120, height: 68).frame(gpu, signal: .rec709)
    var state = MonitorState()
    everyTool(&state)
    let feed = gpu.engine.makeFeed()
    let viewport = MonitorViewport(x: 30, y: 20, width: 120, height: 68)
    let own = gpu.target(200, 120), host = gpu.target(200, 120)
    let a = gpu.engine.makePass(), b = gpu.engine.makePass()
    try gpu.run { cb in
      try feed.analyze(frame, focus: state.focus, into: cb)
      try a.encode(frame: frame, feed: feed, state: state, target: own, viewport: viewport, into: cb)
      try b.prepare(frame: frame, feed: feed, state: state, viewport: viewport, targetPixelFormat: .rgba32Float, into: cb)
      let d = MTLRenderPassDescriptor()
      d.colorAttachments[0].texture = host
      d.colorAttachments[0].loadAction = .clear
      d.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
      let e = try XCTUnwrap(cb.makeRenderCommandEncoder(descriptor: d))
      Self.hostileState(e.setFrontFacing, e.setCullMode, e.setTriangleFillMode, e.setScissorRect)
      try b.draw(with: e)
      e.endEncoding()
    }
    XCTAssertEqual(Pixels(own).values, Pixels(host).values)
  }

  func testHostRenderStateCannotHideThePictureOnMetal4() throws {
    let m = try requireMTL4()
    let gpu = m.gpu
    let frame = try m.frame(PictureTests.picture(width: 120, height: 68), signal: .rec709)
    var state = MonitorState()
    everyTool(&state)
    let feed = gpu.engine.makeFeed()
    let viewport = MonitorViewport(x: 30, y: 20, width: 120, height: 68)
    let own = m.target(200, 120), host = m.target(200, 120)
    let a = gpu.engine.makePass(), b = gpu.engine.makePass()
    let format = MonitorRenderTargetFormat(colorPixelFormat: .rgba32Float)
    try m.run { s in
      try feed.analyze(frame, focus: state.focus, into: s)
      try a.encode(frame: frame, feed: feed, state: state, target: own, viewport: viewport, into: s)
      try b.prepare(frame: frame, feed: feed, state: state, viewport: viewport, target: format, submission: s)
      let d = MTL4RenderPassDescriptor()
      d.colorAttachments[0].texture = host
      d.colorAttachments[0].loadAction = .clear
      d.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
      d.colorAttachments[0].storeAction = .store
      let e = try XCTUnwrap(s.commandBuffer.makeRenderCommandEncoder(descriptor: d))
      Self.hostileState(e.setFrontFacing, e.setCullMode, e.setTriangleFillMode, e.setScissorRect)
      try b.draw(with: e)
      e.endEncoding()
    }
    XCTAssertEqual(rawBytes(own), rawBytes(host))
  }

  /// A feed nobody analyses any more (peaking turned off, then the surface
  /// removed) used to keep its released mask for good on the classic path.
  func testReleaseRetiredDropsTheHeldMask() throws {
    let gpu = try requireGPU()
    let frame = try PictureTests.picture(width: 96, height: 54).frame(gpu, signal: .rec709)
    let feed = gpu.engine.makeFeed()
    var focus = FocusSettings()
    focus.enabled = true
    try gpu.run { cb in try feed.analyze(frame, focus: focus, into: cb) }
    weak let mask = feed.focusMask
    let bytes = try XCTUnwrap(mask).allocatedSize
    XCTAssertEqual(feed.retiredMemoryBytes, 0)
    try gpu.run { cb in try feed.analyze(frame, focus: FocusSettings(), into: cb) }
    XCTAssertNil(feed.focusMask)
    XCTAssertEqual(feed.retiredMemoryBytes, bytes, "held for the frames in flight, and now visible")
    feed.releaseRetired()
    XCTAssertEqual(feed.retiredMemoryBytes, 0)
    XCTAssertEqual(feed.retiredMaskCount, 0)
    XCTAssertNil(mask, "the texture is gone")
  }

  /// The public form of the pass's LUT-stage rule, which hosts use to tag the layer.
  func testMonitorStageHasLUTFollowsThePassRule() throws {
    let gpu = try requireGPU()
    let feed = gpu.engine.makeFeed()
    var state = MonitorState()
    XCTAssertFalse(feed.monitorStageHasLUT(for: state))
    let (burn, monitor) = try Metal4Tests.luts(gpu)
    feed.monitorLUT = monitor
    state.monitorLUT = false
    XCTAssertFalse(feed.monitorStageHasLUT(for: state), "a monitor LUT the surface does not show")
    state.monitorLUT = true
    XCTAssertTrue(feed.monitorStageHasLUT(for: state))
    feed.monitorLUT = nil
    feed.burnInLUT = burn
    state.monitorLUT = false
    XCTAssertTrue(feed.monitorStageHasLUT(for: state), "the burn-in LUT is on every later stage")

    // The pass's own colour pipeline follows the same rule: the transform is unavailable under a LUT.
    let frame = try PictureTests.picture(width: 32, height: 18).frame(gpu, signal: .rec709)
    state.displayTransform.mode = .logToRec709
    let pass = gpu.engine.makePass()
    try gpu.run { cb in
      try pass.encode(frame: frame, feed: feed, state: state, target: gpu.target(32, 18), into: cb)
    }
    let expected = MonitorColorPipeline(
      output: pass.outputColor, signal: frame.signal, transform: state.displayTransform,
      monitorStageHasLUT: feed.monitorStageHasLUT(for: state))
    XCTAssertEqual(pass.colorPipeline, expected)
    XCTAssertEqual(expected.status, .unavailable(.lutOnMonitorStage))
  }
}
