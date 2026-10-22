import Metal
import MonitorKit
import MonitorKitCore
import XCTest

@testable import MonitorKitScopes

/// GPU time from command-buffer timestamps on the dev machine. Each sample is
/// one command buffer holding `batch` encodes, divided by `batch`, so the
/// per-command-buffer scheduling cost is amortized; the median of the samples
/// is reported.
final class ScopeBenchmarkTests: XCTestCase {
  static func gpuMilliseconds(
    batch: Int = 10, samples: Int = 9, minimum: Bool = false, _ encode: (MTLCommandBuffer) throws -> Void) throws
    -> Double
  {
    let (_, queue, _) = try GPU.require()
    var times: [Double] = []
    for i in 0..<(samples + 1) {
      let cb = try XCTUnwrap(queue.makeCommandBuffer())
      for _ in 0..<batch { try encode(cb) }
      cb.commit()
      cb.waitUntilCompleted()
      if let error = cb.error { throw error }
      if i > 0 { times.append((cb.gpuEndTime - cb.gpuStartTime) * 1000 / Double(batch)) }
    }
    return minimum ? times.min()! : times.sorted()[times.count / 2]
  }

  enum Content: String, CaseIterable { case natural, noise, flat }

  static func frame(_ kind: TestFrame.Kind, _ content: Content, width: Int = 3840, height: Int = 2160) throws
    -> TestFrame
  {
    switch content {
    case .natural: return try TestFrame.natural(kind, width: width, height: height, mirror: false)
    case .noise:
      var r = SeededRandom(42)
      var noise = [SIMD3<Int>](repeating: .zero, count: width * height)
      for i in noise.indices { noise[i] = SIMD3(r.int(64...940), r.int(64...960), r.int(64...960)) }
      let shift = { (depth: Int) in 10 - depth }
      return try TestFrame.make(
        kind, width: width, height: height,
        codes: { x, y in
          let v = noise[y * width + x]
          if case .biplanar(_, 8) = kind { return v &>> shift(8) }
          if case .uyvy8 = kind { return v &>> shift(8) }
          if case .yuyv8 = kind { return v &>> shift(8) }
          return v
        },
        rgb: { x, y in SIMD3<Float>(noise[y * width + x]) / 1023 }, mirror: false)
    case .flat:
      return try TestFrame.make(
        kind, width: width, height: height, codes: { _, _ in SIMD3(500, 400, 600) },
        rgb: { _, _ in SIMD3(0.5, 0.4, 0.3) }, mirror: false)
    }
  }

  /// Engines that never specialize and that specialize on first use, on this thread.
  static let engines: [(String, ScopeEngine)] = {
    guard let device = GPU.device else { return [] }
    return [("general", try? ScopeEngine(device: device, specialization: .off)),
            ("specialized", try? ScopeEngine(device: device, specialization: .synchronous))]
      .compactMap { name, engine in engine.map { (name, $0) } }
  }()

  static let scopes: [(String, ScopeSettings)] = {
    var luma = ScopeSettings(kind: .waveform, stage: .source)
    luma.waveformColumns = 1024
    luma.waveformLevels = 512
    var parade = luma
    parade.waveformMode = .rgbParade
    var ycbcr = luma
    ycbcr.waveformMode = .ycbcrParade
    var histogram = ScopeSettings(kind: .histogram, stage: .source)
    histogram.histogramMode = .rgbOverlay
    var vector = ScopeSettings(kind: .vectorscope, stage: .source)
    vector.vectorscopeSize = 512
    return [
      ("waveform luma", luma), ("waveform RGB parade", parade), ("waveform YCbCr parade", ycbcr),
      ("histogram RGB", histogram), ("vectorscope", vector),
    ]
  }()

  func testBenchmarkAccumulation4K() throws {
    _ = try GPU.require()
    var report = ["4K accumulation, GPU ms per scope (median of 9 × 10):"]
    for kind in [TestFrame.Kind.v210, .biplanar(.s420, 10), .bgra8] {
      for content in Content.allCases {
        let frame = try Self.frame(kind, content)
        for (engineName, engine) in Self.engines {
          var line = "\(kind) \(content.rawValue) \(engineName):"
          for (name, settings) in Self.scopes {
            let accumulator = try engine.makeAccumulator(settings: settings)
            let ms = try Self.gpuMilliseconds { cb in
              try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
            }
            line += String(format: " %@ %.3f;", name, ms)
          }
          report.append(line)
        }
      }
    }
    print(report.joined(separator: "\n"))
  }

  /// The usual layout, RGB parade + vectorscope + histogram of one stage, in one command buffer.
  func testBenchmarkThreeScopes4K() throws {
    let (device, _, _) = try GPU.require()
    let cube = try ScopeAccumulationTests.makeCube(size: 33) { SIMD3(pow($0.x, 0.9), $0.y, pow($0.z, 1.1)) }
    let lut = try MonitorLUT(device: device, cube: cube)
    var report = ["4K natural, RGB parade + vectorscope + histogram of one stage, GPU ms (median of 9 × 10):"]
    for kind in [TestFrame.Kind.v210, .biplanar(.s420, 10), .bgra8] {
      let frame = try Self.frame(kind, .natural)
      for (engineName, engine) in Self.engines {
        for stage in [SignalStage.source, .output] {
          let accumulators = try [Self.scopes[1].1, Self.scopes[4].1, Self.scopes[3].1].map { s -> ScopeAccumulator in
            var s = s
            s.stage = stage
            return try engine.makeAccumulator(settings: s)
          }
          let separate = try Self.gpuMilliseconds { cb in
            for a in accumulators { try a.accumulate(frame.frame, burnInLUT: lut, monitorLUT: nil, into: cb) }
          }
          let group = try engine.makeGroup(accumulators)
          try group.prepare(layouts: [frame.frame.layout])
          let fused = try Self.gpuMilliseconds { cb in
            try group.accumulate(frame.frame, burnInLUT: lut, monitorLUT: nil, into: cb)
          }
          XCTAssertEqual(group.fusedMemberCount, 3)
          report.append(
            String(format: "%@ %@ %@: separate %.3f, fused group %.3f", "\(kind)", engineName, "\(stage)", separate, fused))
        }
      }
    }
    print(report.joined(separator: "\n"))
  }

  func testBenchmarkAccumulationWithLUT4K() throws {
    let (device, _, _) = try GPU.require()
    let cube = try ScopeAccumulationTests.makeCube(size: 33) { SIMD3(pow($0.x, 0.9), $0.y, pow($0.z, 1.1)) }
    let lut = try MonitorLUT(device: device, cube: cube)
    let frame = try Self.frame(.v210, .natural)
    for (engineName, engine) in Self.engines {
      var line = "4K v210 natural, output stage with a 33³ tetrahedral LUT, \(engineName):"
      for kind in ScopeKind.allCases {
        var s = ScopeSettings(kind: kind, stage: .output)
        s.waveformMode = .rgbParade
        let accumulator = try engine.makeAccumulator(settings: s)
        let ms = try Self.gpuMilliseconds { cb in
          try accumulator.accumulate(frame.frame, burnInLUT: lut, monitorLUT: nil, into: cb)
        }
        line += String(format: " %@ %.3f;", kind.rawValue, ms)
      }
      print(line)
    }
  }

  func testBenchmarkRender() throws {
    let (device, _, _) = try GPU.require()
    let frame = try Self.frame(.v210, .natural, width: 1920, height: 1080)
    for (width, height) in [(1024, 512), (3840, 2160)] {
      let d = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
      d.usage = [.renderTarget, .shaderRead]
      d.storageMode = .private
      let target = try XCTUnwrap(device.makeTexture(descriptor: d))
      for (engineName, engine) in Self.engines {
        var line = "render \(width)×\(height) bgra8 \(engineName), GPU ms per draw (median of 9 × 10):"
        var overlay = Self.scopes[0].1
        overlay.waveformMode = .rgbOverlay
        for (name, settings) in Self.scopes + [("waveform RGB overlay", overlay)] {
          let accumulator = try engine.makeAccumulator(settings: settings)
          try GPU.run { cb in try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
          let renderer = engine.makeRenderer()
          let ms = try Self.gpuMilliseconds { cb in try renderer.render(accumulator, target: target, into: cb) }
          line += String(format: " %@ %.3f;", name, ms)
        }
        // Background and graticule only: the cost of blending over the target.
        let empty = try engine.makeAccumulator(settings: Self.scopes[0].1)
        let renderer = engine.makeRenderer()
        let floor = try Self.gpuMilliseconds { cb in try renderer.render(empty, target: target, into: cb) }
        line += String(format: " no data (floor) %.3f;", floor)
        print(line)
      }
    }
  }
}
