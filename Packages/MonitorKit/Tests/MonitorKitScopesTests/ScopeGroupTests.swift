import Metal
import MonitorKit
import MonitorKitCore
import XCTest

@testable import MonitorKitScopes

/// A group's fused pass leaves every member exactly as accumulating it alone would.
final class ScopeGroupTests: XCTestCase {
  struct Result: Equatable {
    var bins: [[UInt32]]
    var statistics: [ScopeStatistics?]
  }

  static func settings(_ kinds: [ScopeKind], stage: SignalStage = .source) -> [ScopeSettings] {
    kinds.map { kind in
      var s = ScopeSettings(kind: kind, stage: stage)
      s.waveformMode = .rgbParade
      s.waveformColumns = 300
      s.waveformLevels = 256
      s.histogramMode = .rgbOverlay
      s.histogramBins = 512
      s.vectorscopeSize = 256
      s.clipHighPercent = 90
      s.clipLowPercent = 5
      return s
    }
  }

  /// Bins and statistics (generation zeroed) of each accumulator.
  static func result(_ accumulators: [ScopeAccumulator]) throws -> Result {
    Result(
      bins: try accumulators.map { try readBins($0) },
      statistics: accumulators.map {
        var s = $0.statistics
        s?.generation = 0
        return s
      })
  }

  func compare(
    _ settings: [ScopeSettings], _ frame: TestFrame, engine: ScopeEngine, luts: (MonitorLUT?, MonitorLUT?) = (nil, nil),
    fused expected: Int, packedLimit: Int? = nil, dispatch: MTLDispatchType = .serial, _ label: String,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let alone = try settings.map { try engine.makeAccumulator(settings: $0) }
    let members = try settings.map { try engine.makeAccumulator(settings: $0) }
    if let packedLimit { (alone + members).forEach { $0.packedBinLimit = packedLimit } }
    try GPU.run { cb in
      for a in alone { try a.accumulate(frame.frame, burnInLUT: luts.0, monitorLUT: luts.1, into: cb) }
    }
    let group = try engine.makeGroup(members)
    let (_, queue, _) = try GPU.require()
    // Twice: the second run reuses the tile and pipeline, and must clear the first's bins.
    for _ in 0..<2 {
      let cb = try XCTUnwrap(queue.makeCommandBuffer())
      let encoder = try XCTUnwrap(cb.makeComputeCommandEncoder(dispatchType: dispatch))
      try group.accumulate(frame.frame, burnInLUT: luts.0, monitorLUT: luts.1, using: encoder)
      encoder.endEncoding()
      cb.commit()
      cb.waitUntilCompleted()
      XCTAssertNil(cb.error, label, file: file, line: line)
    }
    XCTAssertEqual(group.fusedMemberCount, expected, "\(label): fused members", file: file, line: line)
    let a = try Self.result(alone), b = try Self.result(members)
    for i in settings.indices {
      XCTAssertEqual(b.bins[i], a.bins[i], "\(label): \(settings[i].kind) bins", file: file, line: line)
      XCTAssertEqual(b.statistics[i], a.statistics[i], "\(label): \(settings[i].kind) statistics", file: file, line: line)
      XCTAssertEqual(members[i].generation, 2, label, file: file, line: line)
      XCTAssertEqual(members[i].statistics?.generation, 2, label, file: file, line: line)
      XCTAssertEqual(members[i].context, alone[i].context, label, file: file, line: line)
    }
  }

  func engine() throws -> ScopeEngine {
    _ = try GPU.require()
    return try XCTUnwrap(GPU.synchronousEngine)
  }

  /// Every fused specialization's static threadgroup memory fits beside the
  /// largest dynamic block the group dispatches.
  func testFusedKernelsFitTheThreadgroupBudget() throws {
    let engine = try engine()
    for mask in 1..<8 {
      let scopes = FusedScopes(rawValue: UInt8(mask))
      for layout in [PixelLayout.v210, .bgra8, .biplanar(.s420, bitDepth: 10)] {
        let pipeline = try engine.computePipeline(
          ScopeEngine.ComputeKey(kernel: .fused, layout: layout.scopeLayoutCode, scopes: scopes))
        XCTAssertLessThanOrEqual(
          pipeline.staticThreadgroupMemoryLength + engine.threadgroupMemoryBudget,
          min(engine.device.maxThreadgroupMemoryLength, 32 * 1024), "\(scopes) \(layout)")
      }
    }
  }

  func testEveryCombinationEveryLayout() throws {
    let engine = try engine()
    let combinations: [[ScopeKind]] = [
      [.waveform, .vectorscope, .histogram], [.waveform, .histogram], [.waveform, .vectorscope],
      [.histogram, .vectorscope], [.vectorscope, .waveform, .histogram],
    ]
    for kind in TestFrame.Kind.all {
      let frame = try TestFrame.natural(kind, width: 251, height: 37, seed: 17, mirror: false)
      for kinds in combinations {
        try compare(Self.settings(kinds), frame, engine: engine, fused: kinds.count, "\(kind) \(kinds)")
      }
    }
  }

  func testEveryModeAndShape() throws {
    let engine = try engine()
    let frame = try TestFrame.natural(.v210, width: 1280, height: 720, seed: 23, mirror: false)
    for waveformMode in WaveformMode.allCases {
      for histogramMode in HistogramMode.allCases {
        var s = Self.settings([.waveform, .histogram, .vectorscope])
        s[0].waveformMode = waveformMode
        s[0].waveformColumns = waveformMode == .luma ? 1024 : 960
        s[0].waveformLevels = 512
        s[1].histogramMode = histogramMode
        s[2].vectorscopeZoom = 2
        try compare(s, frame, engine: engine, fused: 3, "\(waveformMode) \(histogramMode)")
      }
    }
    // 32-bit waveform bins, and the largest levels with the histogram beside them.
    var s = Self.settings([.waveform, .histogram, .vectorscope])
    s[0].waveformColumns = 64
    s[0].waveformLevels = 2048
    try compare(s, frame, engine: engine, fused: 3, packedLimit: 1000, "32-bit bins")
  }

  func testOddAndTinyFrames() throws {
    let engine = try engine()
    for (width, height) in [(7, 3), (1, 1), (65, 129), (3841, 17)] {
      let frame = try TestFrame.natural(.biplanar(.s420, 10), width: width, height: height, seed: 3, mirror: false)
      try compare(
        Self.settings([.waveform, .histogram, .vectorscope]), frame, engine: engine, fused: 3, "\(width)×\(height)")
      try compare(Self.settings([.histogram, .vectorscope]), frame, engine: engine, fused: 2, "\(width)×\(height) H+V")
    }
  }

  func testStagesWithLUTsAndConcurrentEncoders() throws {
    let (device, _, _) = try GPU.require()
    let engine = try engine()
    let cube = try ScopeAccumulationTests.makeCube(size: 17) { SIMD3(pow($0.x, 0.8), $0.y * 0.9 + 0.05, pow($0.z, 1.2)) }
    let lut = try MonitorLUT(device: device, cube: cube)
    let frame = try TestFrame.natural(.v210, width: 640, height: 180, seed: 8, mirror: false)
    for stage in SignalStage.allCases {
      for dispatch in [MTLDispatchType.serial, .concurrent] {
        try compare(
          Self.settings([.waveform, .histogram, .vectorscope], stage: stage), frame, engine: engine, luts: (lut, lut),
          fused: 3, dispatch: dispatch, "\(stage) \(dispatch)")
      }
    }
  }

  /// Members measuring something else, repeats of a kind and a histogram too
  /// large to share threadgroup memory are accumulated on their own.
  func testIncompatibleMembersRunAlone() throws {
    let engine = try engine()
    let frame = try TestFrame.natural(.bgra8, width: 320, height: 90, seed: 2, mirror: false)
    var s = Self.settings([.waveform, .histogram, .vectorscope, .waveform])
    s[2].stage = .output
    try compare(s, frame, engine: engine, fused: 2, "other stage and a second waveform")
    s = Self.settings([.waveform, .histogram, .vectorscope])
    s[1].clipHighPercent = 95
    try compare(s, frame, engine: engine, fused: 2, "other clip level")
    s[1].clipHighPercent = 90
    s[1].colorimetry = .bt2020
    try compare(s, frame, engine: engine, fused: 2, "other colorimetry")
    s = Self.settings([.waveform, .histogram, .vectorscope])
    s[1].histogramBins = 4096
    try compare(s, frame, engine: engine, fused: 2, "a 24 KB histogram")
    try compare(Self.settings([.vectorscope]), frame, engine: engine, fused: 0, "one member")
    try compare(Self.settings([.histogram, .histogram]), frame, engine: engine, fused: 0, "one per kind")
    let a = try engine.makeAccumulator(settings: ScopeSettings(kind: .waveform))
    XCTAssertThrowsError(try engine.makeGroup([a, a]), "an accumulator listed twice")
    let (device, _, _) = try GPU.require()
    let other = try ScopeEngine(device: device, specialization: .off)
    XCTAssertThrowsError(try engine.makeGroup([a, try other.makeAccumulator()]), "another engine's accumulator")
  }

  /// With asynchronous specialization the group runs scope by scope until the
  /// fused pipeline is built, then fuses; results are identical throughout.
  func testAsynchronousEngineFusesOnceBuilt() throws {
    let (device, queue, _) = try GPU.require()
    let engine = try ScopeEngine(device: device, specialization: .asynchronous)
    let frame = try TestFrame.natural(.uyvy8, width: 400, height: 100, seed: 4, mirror: false)
    let settings = Self.settings([.waveform, .histogram, .vectorscope])
    let alone = try settings.map { try engine.makeAccumulator(settings: $0) }
    try GPU.run { cb in for a in alone { try a.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) } }
    let expected = try Self.result(alone)
    let members = try settings.map { try engine.makeAccumulator(settings: $0) }
    let group = try engine.makeGroup(members)
    let deadline = Date().addingTimeInterval(20)
    var sawUnfused = false
    repeat {
      let cb = try XCTUnwrap(queue.makeCommandBuffer())
      try group.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
      cb.commit()
      cb.waitUntilCompleted()
      if group.fusedMemberCount == 0 { sawUnfused = true }
      XCTAssertEqual(try Self.result(members), expected)
    } while group.fusedMemberCount == 0 && Date() < deadline
    XCTAssertEqual(group.fusedMemberCount, 3, "fused once the pipeline is ready")
    XCTAssertTrue(sawUnfused, "the first frame did not wait for the compiler")
    XCTAssertTrue(members.allSatisfy { group.isFused($0) })
  }
}
