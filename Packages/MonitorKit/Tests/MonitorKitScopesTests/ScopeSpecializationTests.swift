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
}
