import Metal
import MonitorKit
import MonitorKitCore
import XCTest

@testable import MonitorKitScopes

/// Specialized pipelines (one layout's decode, one scope's drawing) give
/// exactly what the general ones give.
final class ScopeSpecializationTests: XCTestCase {
  func engines() throws -> (general: ScopeEngine, specialized: ScopeEngine) {
    _ = try GPU.require()
    return (try XCTUnwrap(GPU.generalEngine), try XCTUnwrap(GPU.synchronousEngine))
  }

  func testLayoutCodeMirrorsTheFrame() throws {
    for kind in TestFrame.Kind.all {
      let frame = try TestFrame.natural(kind, width: 12, height: 4, mirror: false)
      XCTAssertEqual(frame.frame.layout.scopeLayoutCode, frame.frame.parameters.shape.x, "\(kind)")
    }
  }

  func testSpecializedAccumulationMatchesGeneral() throws {
    let (general, specialized) = try engines()
    for kind in TestFrame.Kind.all {
      let frame = try TestFrame.natural(kind, width: 203, height: 31, seed: 6, mirror: false)
      for scope in ScopeKind.allCases {
        var s = ScopeSettings(kind: scope, stage: .source)
        s.waveformMode = .ycbcrParade
        s.waveformColumns = 200
        s.waveformLevels = 256
        s.vectorscopeSize = 256
        let a = try general.makeAccumulator(settings: s), b = try specialized.makeAccumulator(settings: s)
        try GPU.run { cb in
          try a.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
          try b.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
        }
        XCTAssertEqual(try readBins(a), try readBins(b), "\(kind) \(scope)")
        var sa = a.statistics, sb = b.statistics
        sa?.generation = 0
        sb?.generation = 0
        XCTAssertEqual(sa, sb, "\(kind) \(scope)")
      }
    }
    XCTAssertGreaterThanOrEqual(specialized.specializedPipelineCount.compute, 5 * 3)
  }

  func testSpecializedDrawingMatchesGeneral() throws {
    let (device, _, _) = try GPU.require()
    let (general, specialized) = try engines()
    let frame = try TestFrame.natural(.v210, width: 640, height: 360, seed: 12, mirror: false)
    var cases: [ScopeSettings] = WaveformMode.allCases.map {
      var s = ScopeSettings(kind: .waveform, stage: .source)
      s.waveformMode = $0
      return s
    }
    cases += HistogramMode.allCases.map {
      var s = ScopeSettings(kind: .histogram, stage: .source)
      s.histogramMode = $0
      return s
    }
    var vector = ScopeSettings(kind: .vectorscope, stage: .source)
    vector.display.trace = .colorized
    cases.append(vector)
    for s in cases {
      var images: [[UInt8]] = []
      for engine in [general, specialized] {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 300, height: 200, mipmapped: false)
        d.usage = .renderTarget
        d.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: d))
        let accumulator = try engine.makeAccumulator(settings: s)
        try GPU.run { cb in
          try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
          try engine.makeRenderer().render(accumulator, target: target, clear: true, into: cb)
        }
        var bytes = [UInt8](repeating: 0, count: 300 * 200 * 4)
        target.getBytes(&bytes, bytesPerRow: 1200, from: MTLRegionMake2D(0, 0, 300, 200), mipmapLevel: 0)
        images.append(bytes)
      }
      let differing = zip(images[0], images[1]).filter { abs(Int($0) - Int($1)) > 1 }.count
      XCTAssertEqual(differing, 0, "\(s.kind) \(s.waveformMode) \(s.histogramMode)")
    }
  }

  /// `prepare` builds what the settings need up front, so the first frame is specialized.
  func testPrepareBuildsTheSpecializedPipelines() throws {
    let (device, _, _) = try GPU.require()
    let engine = try ScopeEngine(device: device, specialization: .asynchronous)
    XCTAssertEqual(engine.specializedPipelineCount.compute, 0)
    var waveform = ScopeSettings(kind: .waveform)
    waveform.waveformMode = .rgbParade
    try engine.prepare(
      settings: [waveform, ScopeSettings(kind: .histogram)], layouts: [.v210, .bgra8], pixelFormat: .bgra8Unorm)
    XCTAssertEqual(engine.specializedPipelineCount.compute, 4)
    XCTAssertEqual(engine.specializedPipelineCount.render, 2)
    let accumulator = try engine.makeAccumulator(settings: waveform)
    let frame = try TestFrame.natural(.v210, width: 64, height: 8, mirror: false)
    try GPU.run { cb in try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
    XCTAssertEqual(engine.specializedPipelineCount.compute, 4, "nothing more to build")
  }

  /// Settings warm-up on a `.off` engine builds only the general render
  /// pipeline per format: `.off` never uses a specialized one, so compiling
  /// any would only cost start-up time and memory.
  func testSettingsWarmUpOnAnOffEngineBuildsNothingSpecialized() throws {
    let (device, queue, _) = try GPU.require()
    let engine = try ScopeEngine(device: device, specialization: .off)
    var parade = ScopeSettings(kind: .waveform, stage: .source)
    parade.waveformMode = .ycbcrParade
    let settings = [parade, ScopeSettings(kind: .vectorscope), ScopeSettings(kind: .histogram)]
    let layouts: [PixelLayout] = [.v210, .uyvy8, .p010]
    try engine.prepare(settings: settings, layouts: layouts, pixelFormats: ScopeEngine.drawablePixelFormats)
    XCTAssertEqual(engine.specializedPipelineCount.compute, 0, "no layout-specialized kernel")
    XCTAssertEqual(engine.specializedPipelineCount.render, 0, "no scope-specialized fragment")
    for format in ScopeEngine.drawablePixelFormats { XCTAssertTrue(engine.isPrepared(pixelFormat: format), "\(format)") }
    XCTAssertEqual(
      engine.builtOnCallerThread.withLock { $0 }.render, ScopeEngine.drawablePixelFormats.count,
      "one general render pipeline per format")
    XCTAssertEqual(engine.builtOnCallerThread.withLock { $0 }.compute, 0, "the general kernels are made at init")
    try engine.prepare(settings: settings, layouts: layouts, target: nil)
    XCTAssertEqual(engine.builtOnCallerThread.withLock { $0 }.compute, 0)

    // Frames then use the general pipelines and compile nothing.
    let built = engine.builtOnCallerThread.withLock { $0 }
    let frame = try TestFrame.natural(.v210, width: 320, height: 180, seed: 3, mirror: false)
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 300, height: 200, mipmapped: false)
    d.usage = .renderTarget
    d.storageMode = .private
    let target = try XCTUnwrap(device.makeTexture(descriptor: d))
    for s in settings {
      let a = try engine.makeAccumulator(settings: s), r = engine.makeRenderer()
      let cb = try XCTUnwrap(queue.makeCommandBuffer())
      try a.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
      try r.render(a, target: target, clear: true, into: cb)
      cb.commit()
      cb.waitUntilCompleted()
      XCTAssertNil(cb.error)
      XCTAssertTrue(r.isReady, "\(s.kind)")
    }
    XCTAssertEqual(engine.specializedPipelineCount.compute, 0)
    XCTAssertEqual(engine.specializedPipelineCount.render, 0)
    XCTAssertEqual(engine.builtOnCallerThread.withLock { $0 }.render, built.render, "drawing compiled nothing")
    XCTAssertEqual(engine.builtOnCallerThread.withLock { $0 }.compute, built.compute)
    XCTAssertTrue(engine.pipelineBuildFailures.isEmpty, "\(engine.pipelineBuildFailures)")
  }

  /// A `.off` engine's frame path returns the general pipelines even when a
  /// specialized one for the same key is cached (built through an internal
  /// path), so `.off` always means general pipelines only.
  func testOffEngineFramePathIgnoresCachedSpecializedPipelines() throws {
    let (device, _, _) = try GPU.require()
    let engine = try ScopeEngine(device: device, specialization: .off)
    let target = MonitorRenderTargetFormat(colorPixelFormat: .bgra8Unorm)
    let layout = PixelLayout.v210.scopeLayoutCode
    let specializedKernel = ScopeEngine.ComputeKey(kernel: ScopeKind.waveform.kernel, layout: layout)
    let generalKernel = ScopeEngine.ComputeKey(kernel: ScopeKind.waveform.kernel, layout: nil)
    let specializedFused = ScopeEngine.ComputeKey(kernel: .fused, layout: layout, scopes: [.waveform, .vectorscope])
    let generalFused = ScopeEngine.ComputeKey(kernel: .fused, layout: nil, scopes: [.waveform, .vectorscope])
    let s = ScopeSettings(kind: .waveform)
    let specializedRender = ScopeEngine.RenderKey(
      target: target, scope: ScopeEngine.DrawVariant(kind: s.kind.shaderCode, mode: s.shaderMode))
    let generalRender = ScopeEngine.RenderKey(target: target, scope: nil)
    // Cache the specialized ones and the general ones directly.
    let cachedKernel = try engine.computePipeline(specializedKernel)
    let cachedFused = try engine.computePipeline(specializedFused)
    let cachedRender = try engine.renderPipeline(specializedRender)
    let general = try engine.computePipeline(generalKernel)
    let fused = try engine.computePipeline(generalFused)
    let render = try engine.renderPipeline(generalRender)

    let (kernel, kernelIsFinal) = try engine.computePipeline(for: specializedKernel)
    XCTAssertTrue(kernel === general, "the general kernel")
    XCTAssertFalse(kernel === cachedKernel)
    XCTAssertTrue(kernelIsFinal)
    let (fusedState, fusedIsFinal) = engine.fusedPipeline(for: specializedFused)
    XCTAssertTrue(fusedState === fused, "the all-tools fused kernel")
    XCTAssertFalse(fusedState === cachedFused)
    XCTAssertTrue(fusedIsFinal)
    let (drawn, drawnIsFinal) = try engine.renderPipeline(for: specializedRender)
    XCTAssertTrue(drawn === render, "the general render pipeline")
    XCTAssertFalse(drawn === cachedRender)
    XCTAssertTrue(drawnIsFinal)
  }
}
