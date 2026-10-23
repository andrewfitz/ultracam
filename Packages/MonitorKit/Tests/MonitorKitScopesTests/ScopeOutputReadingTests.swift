import Metal
import MonitorKit
import MonitorKitCore
import XCTest

@testable import MonitorKitScopes

/// Scopes of the Output and Monitor stages read the codes with the signal's
/// `outputReading` (the per-stage decode): every scope kind measures what a
/// frame labelled with that stage's reading alone gives, bins and statistics
/// bit for bit, and agrees with the picture pass on the same stage.
final class ScopeOutputReadingTests: XCTestCase {
  static let declaredFull = SignalDescription(
    range: .full, outputReading: SignalReading(range: .legal, matrix: .bt709))
  static let smpte240m = SignalDescription(
    matrix: .smpte240m, outputReading: SignalReading(range: .legal, matrix: .bt709))

  static func relabelled(_ frame: MonitorFrame, _ signal: SignalDescription) -> MonitorFrame {
    var f = frame
    f.signal = signal
    return f
  }

  static func single(_ frame: MonitorFrame, _ stage: SignalStage) -> MonitorFrame {
    var s = frame.signal.signal(for: stage)
    s.outputReading = nil
    return relabelled(frame, s)
  }

  func luts(_ device: MTLDevice) throws -> (MonitorLUT, MonitorLUT) {
    (
      try MonitorLUT(
        device: device, cube: try ScopeAccumulationTests.makeCube(size: 17) { $0 * SIMD3(1.04, 1.02, 0.97) - 0.004 }),
      try MonitorLUT(
        device: device, cube: try ScopeAccumulationTests.makeCube(size: 17) { SIMD3($0.y, $0.x, $0.z) * 1.01 - 0.002 })
    )
  }

  func testEveryScopeOfEveryStageReadsItsStage() throws {
    let (device, _, engine) = try GPU.require()
    let (burn, look) = try luts(device)
    let (width, height) = (96, 24)
    for kind in [TestFrame.Kind.v210, .biplanar(.s420, 10), .uyvy8, .bgra8] {
      let base = try ScopePictureAgreementTests.extremes(kind, width: width, height: height, chroma: 40).frame
      for signal in [Self.declaredFull, Self.smpte240m] {
        let frame = Self.relabelled(base, signal)
        for withLUTs in [false, true] {
          for stage in SignalStage.allCases {
            for scope in [ScopeKind.waveform, .vectorscope, .histogram] {
              var settings = ScopeSettings(kind: scope, stage: stage)
              if scope == .waveform { settings.waveformMode = .rgbParade }
              let label = "\(kind) \(signal.matrix) \(stage) \(scope) LUTs \(withLUTs)"
              let a = try engine.makeAccumulator(settings: settings)
              let b = try engine.makeAccumulator(settings: settings)
              let burnLUT = withLUTs ? burn : nil, monitorLUT = withLUTs ? look : nil
              try GPU.run { cb in
                try a.accumulate(frame, burnInLUT: burnLUT, monitorLUT: monitorLUT, into: cb)
                try b.accumulate(Self.single(frame, stage), burnInLUT: burnLUT, monitorLUT: monitorLUT, into: cb)
              }
              XCTAssertEqual(try readBins(a), try readBins(b), label)
              let sa = try XCTUnwrap(a.statistics), sb = try XCTUnwrap(b.statistics)
              XCTAssertEqual(sa.clippedHigh, sb.clippedHigh, label)
              XCTAssertEqual(sa.clippedLow, sb.clippedLow, label)
              XCTAssertEqual(sa.lumaMinimum, sb.lumaMinimum, label)
              XCTAssertEqual(sa.lumaMaximum, sb.lumaMaximum, label)
              XCTAssertEqual(sa.lumaAverage, sb.lumaAverage, label)
              // What the graticule is labelled with: the stage's own reading.
              XCTAssertEqual(a.context, b.context, label)
              XCTAssertEqual(a.context.range, signal.signal(for: stage).range, label)
            }
          }
        }
      }
    }
  }

  /// The fused group reads its stage the same way.
  func testAFusedGroupReadsItsStage() throws {
    let (device, _, _) = try GPU.require()
    guard let engine = GPU.synchronousEngine else { throw XCTSkip("no engine") }
    let (burn, _) = try luts(device)
    let frame = Self.relabelled(
      try ScopePictureAgreementTests.extremes(.v210, width: 96, height: 24, chroma: 40).frame, Self.declaredFull)
    for stage in SignalStage.allCases {
      func group(_ f: MonitorFrame) throws -> [[UInt32]] {
        let members = try [ScopeKind.waveform, .histogram, .vectorscope].map {
          try engine.makeAccumulator(settings: ScopeSettings(kind: $0, stage: stage))
        }
        let g = try engine.makeGroup(members)
        try GPU.run { cb in try g.accumulate(f, burnInLUT: burn, monitorLUT: nil, into: cb) }
        return try members.map { try readBins($0) }
      }
      XCTAssertEqual(try group(frame), try group(Self.single(frame, stage)), "\(stage)")
    }
  }

  /// The picture's IRE tools and the scope's clip count agree on each stage of a
  /// camera declared full range on a legal link (and of a 240M source read as
  /// BT.709 downstream), with and without a burn-in LUT: the same reading, the
  /// same stage Y', the same inclusive 100 %.
  func testPictureAndScopeAgreeOnEachStagesReading() throws {
    let (device, _, engine) = try GPU.require()
    let monitor = try MonitorEngine(device: device, specialization: .synchronous)
    let (burn, _) = try luts(device)
    let (width, height) = (96, 32)
    let agreement = ScopePictureAgreementTests()
    for kind in [TestFrame.Kind.v210, .biplanar(.s422, 10), .bgra8] {
      let base = try ScopePictureAgreementTests.highlights(kind, width: width, height: height).frame
      for signal in [Self.declaredFull, Self.smpte240m] {
        let frame = Self.relabelled(base, signal)
        for stage in SignalStage.allCases {
          for withLUT in [false, true] {
            let feed = monitor.makeFeed()
            if withLUT { feed.burnInLUT = burn }
            let picture = try agreement.pictureCount(frame, stage: stage, feed: feed, pass: monitor.makePass())
            var settings = ScopeSettings(kind: .histogram, stage: stage)
            settings.clipHighPercent = 100
            let accumulator = try engine.makeAccumulator(settings: settings)
            try GPU.run { cb in try accumulator.accumulate(frame, feed: feed, into: cb) }
            let stats = try XCTUnwrap(accumulator.statistics)
            let scope = Int((stats.clippedHigh.w * Double(stats.pixelCount)).rounded())
            XCTAssertEqual(picture, scope, "\(kind) \(signal.matrix) \(stage) LUT \(withLUT)")
          }
        }
        // The declared full range puts few pixels at white on the source; the
        // legal output reading puts a third (exactly 940) and more there.
        if signal == Self.declaredFull, !kind.isRGB {
          let source = try agreement.pictureCount(frame, stage: .source, feed: monitor.makeFeed(), pass: monitor.makePass())
          let output = try agreement.pictureCount(frame, stage: .output, feed: monitor.makeFeed(), pass: monitor.makePass())
          XCTAssertLessThan(source, output, "\(kind)")
          XCTAssertGreaterThan(output, width * height / 4, "\(kind)")
        }
      }
    }
  }
}
