import Metal
import MonitorKit
import MonitorKitCore
import MonitorKitScopes
import XCTest

@testable import MonitorKitUI

/// GPU time of a scope wall tick: the renderer's one render pass and fused scope
/// group against the separate passes and accumulations it replaced. The GPU is
/// shared, so runs are interleaved and the minimum and median of each are printed;
/// nothing is asserted on time.
final class GPUBenchmarks: XCTestCase {
  func testOnePassAndFusedScopesAgainstSeparatePasses() throws {
    let gpu = try requireGPU()
    let frames = [try gpu.sdrFrame(width: 1920, height: 1080, seed: 0), try gpu.sdrFrame(width: 1920, height: 1080, seed: 9)]
    let source = MonitorSource()
    var state = MonitorState()
    state.zebras[0] = ZebraSet(mode: .lowerLimit, level: 90)
    state.focus.enabled = true
    let tiles = (0..<4).map { MonitorRegion(x: Double($0 % 2) / 2, y: Double($0 / 2) / 2, width: 0.5, height: 0.5) }
    let surfaces = tiles.map { MonitorSurface(source: source, state: state, region: $0) }
    var w = ScopeSettings(kind: .waveform, stage: .output)
    w.waveformMode = .rgbParade
    let settings = [w, ScopeSettings(kind: .vectorscope, stage: .output), ScopeSettings(kind: .histogram, stage: .output)]
    let scopeRegions = (0..<3).map { MonitorRegion(x: 0.55 + Double($0) * 0.15, y: 0.7, width: 0.14, height: 0.25) }
    let overlays = (0..<3).map { MonitorScopeOverlay(source: source, settings: settings[$0], region: scopeRegions[$0]) }
    let scopes = try gpu.scopeEngine()
    let renderer = MonitorRenderer(
      engine: gpu.engine, scene: MonitorScene(surfaces: surfaces, scopes: overlays), scopeEngine: scopes)
    let target = gpu.texture(.rgba16Float, 3840, 2160, usage: [.renderTarget])
    let size = (w: target.width, h: target.height)

    let feed = gpu.engine.makeFeed()
    let passes = (0..<4).map { _ in gpu.engine.makePass() }
    let accumulators = try settings.map { try scopes.makeAccumulator(settings: $0) }
    let scopeRenderers = (0..<3).map { _ in scopes.makeRenderer() }
    func separate(_ frame: MonitorFrame, _ cb: MTLCommandBuffer) throws {
      try feed.analyze(frame, focus: state.focus, into: cb)
      for i in 0..<4 {
        try passes[i].encode(
          frame: frame, feed: feed, state: state, target: target,
          viewport: tiles[i].viewport(width: size.w, height: size.h)!, clear: i == 0, into: cb)
      }
      for i in 0..<3 {
        try accumulators[i].accumulate(frame, feed: feed, into: cb)
        try scopeRenderers[i].render(
          accumulators[i], target: target, viewport: scopeRegions[i].viewport(width: size.w, height: size.h)!, into: cb)
      }
    }
    func time(_ body: (MTLCommandBuffer) throws -> Void) throws -> Double {
      let cb = gpu.queue.makeCommandBuffer()!
      try body(cb)
      cb.commit()
      cb.waitUntilCompleted()
      return (cb.gpuEndTime - cb.gpuStartTime) * 1000
    }
    var one: [Double] = [], many: [Double] = []
    for i in 0..<24 {
      let frame = frames[i % 2]
      source.submit(frame)
      try renderer.update()
      let a = try time { try renderer.encode(target: target, into: $0) }
      let b = try time { try separate(frame, $0) }
      if i >= 4 {
        one.append(a)
        many.append(b)
      }
    }
    XCTAssertEqual(renderer.scopeGroup(for: overlays[0])?.fusedMemberCount, 3)
    func stats(_ v: [Double]) -> String {
      let s = v.sorted()
      return String(format: "min %.3f median %.3f ms", s[0], s[s.count / 2])
    }
    print(
      "BENCH 4 tiles of 1080p + parade, vectorscope, histogram into 4K rgba16Float, GPU per new frame: one pass + fused group \(stats(one)); separate passes \(stats(many))"
    )
  }

  /// What a drawable waits for: one 4K frame drawn into a 1080p bgr10a2 target
  /// with a fused parade, vectorscope and histogram of it. The all-in-one encode
  /// against the split one's picture command buffer (the scope buffer, committed
  /// after it, is timed apart). Interleaved, min and median printed.
  func testSplitScopesTakeTheAccumulationOffThePicturesBuffer() throws {
    let gpu = try requireGPU()
    let frames = [try gpu.sdrFrame(width: 3840, height: 2160, seed: 0), try gpu.sdrFrame(width: 3840, height: 2160, seed: 9)]
    var w = ScopeSettings(kind: .waveform)
    w.waveformMode = .rgbParade
    let settings = [w, ScopeSettings(kind: .vectorscope), ScopeSettings(kind: .histogram)]
    let scopes = try gpu.scopeEngine()
    func rig() -> (MonitorSource, MonitorRenderer) {
      let source = MonitorSource()
      let overlays = (0..<3).map {
        MonitorScopeOverlay(
          source: source, settings: settings[$0],
          region: MonitorRegion(x: 0.55 + Double($0) * 0.15, y: 0.7, width: 0.14, height: 0.25))
      }
      let renderer = MonitorRenderer(
        engine: gpu.engine, scene: MonitorScene(surfaces: [MonitorSurface(source: source)], scopes: overlays),
        scopeEngine: scopes)
      return (source, renderer)
    }
    let (wholeSource, whole) = rig()
    let (splitSource, split) = rig()
    let target = gpu.texture(.bgr10a2Unorm, 1920, 1080, usage: [.renderTarget])
    func ms(_ cb: MTLCommandBuffer) -> Double { (cb.gpuEndTime - cb.gpuStartTime) * 1000 }
    var a: [Double] = [], b: [Double] = [], c: [Double] = []
    for i in 0..<38 {
      let frame = frames[i % 2]
      wholeSource.submit(frame)
      try whole.update()
      let cb = gpu.queue.makeCommandBuffer()!
      try whole.encode(target: target, into: cb)
      cb.commit()
      cb.waitUntilCompleted()

      splitSource.submit(frame)
      try split.update()
      let pictures = gpu.queue.makeCommandBuffer()!
      try split.encodePictures(target: target, into: pictures)
      pictures.commit()
      let scopeBuffer = gpu.queue.makeCommandBuffer()!
      XCTAssertTrue(split.encodeScopes(into: scopeBuffer))
      scopeBuffer.commit()
      scopeBuffer.waitUntilCompleted()
      if i >= 4 {
        a.append(ms(cb))
        b.append(ms(pictures))
        c.append(ms(scopeBuffer))
      }
    }
    func stats(_ v: [Double]) -> String {
      let s = v.sorted()
      return String(format: "min %.3f median %.3f ms", s[0], s[s.count / 2])
    }
    print(
      "BENCH 4K frame + fused parade/vectorscope/histogram into 1080p bgr10a2, GPU the drawable waits for: all-in-one \(stats(a)); split pictures buffer \(stats(b)) (its scope buffer \(stats(c)))"
    )
  }
}
