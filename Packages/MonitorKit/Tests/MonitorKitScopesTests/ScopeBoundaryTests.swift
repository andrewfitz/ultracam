import Metal
import MonitorKit
import MonitorKitCore
import XCTest

@testable import MonitorKitScopes

/// Classification boundaries are exact, and every matrix and chroma siting
/// bins like the CPU reference.
final class ScopeBoundaryTests: XCTestCase {
  static let matrices: [YCbCrMatrix] = [.bt601, .bt709, .bt2020, .smpte240m]

  func statistics(_ settings: ScopeSettings, _ frame: TestFrame) throws -> ScopeStatistics {
    let (_, _, engine) = try GPU.require()
    let accumulator = try engine.makeAccumulator(settings: settings)
    try GPU.run { cb in try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
    return try XCTUnwrap(accumulator.statistics)
  }

  /// A neutral frame at an exact code clips at exactly that level, on every
  /// matrix, layout family and scope: BT.2020 white at code 940 counts at
  /// 100%, a 240M neutral at code 721 at 75%. The expected level comes from
  /// Core's reference decode, as the picture pass's IRE does.
  func testNeutralCodesClipExactlyAtTheirLevel() throws {
    for matrix in Self.matrices {
      for (code, kind) in [(940, TestFrame.Kind.biplanar(.s444, 10)), (721, .v210), (64, .biplanar(.s420, 10)),
                           (235, .biplanar(.s422, 8))] {
        let depth: Int
        if case .biplanar(_, let d) = kind { depth = d } else { depth = 10 }
        let signal = SignalDescription(range: .legal, matrix: matrix)
        let center = 1 << (depth - 1)
        let frame = try TestFrame.make(kind, width: 96, height: 10, signal: signal, codes: { _, _ in SIMD3(code, center, center) })
        let level = DecodeReference.rgb(
          lumaCode: Double(code), cbCode: Double(center), crCode: Double(center), bitDepth: depth, range: .legal,
          matrix: matrix
        ).luma
        let percent = level * 100
        for scope in ScopeKind.allCases {
          for colorimetry in [ScopeColorimetry.auto, .bt601, .bt2020] {
            let label = "\(matrix) code \(code) \(kind) \(scope) \(colorimetry)"
            var s = ScopeSettings(kind: scope, stage: .source)
            s.colorimetry = colorimetry
            s.clipHighPercent = percent
            s.clipLowPercent = percent
            let at = try statistics(s, frame)
            XCTAssertEqual(at.clippedHigh, SIMD4(repeating: 1), "\(label): at the high threshold")
            XCTAssertEqual(at.clippedLow, SIMD4(repeating: 1), "\(label): at the low threshold")
            XCTAssertEqual(at.lumaMaximum, level, accuracy: 1.0 / 1_048_576, label)
            s.clipHighPercent = percent + 0.01
            s.clipLowPercent = percent - 0.01
            let beside = try statistics(s, frame)
            XCTAssertEqual(beside.clippedHigh, .zero, "\(label): just above")
            XCTAssertEqual(beside.clippedLow, .zero, "\(label): just below")
          }
        }
      }
    }
  }

  /// A saturated colour at luma code 940 is at 100% luma on every matrix: the
  /// scope reads the transport Y', as zebras do, not Y' rebuilt from R'G'B'.
  func testChromaticPixelAtWhiteLumaCountsAsLumaClipped() throws {
    for matrix in Self.matrices {
      let frame = try TestFrame.make(
        .biplanar(.s444, 10), width: 64, height: 8, signal: SignalDescription(matrix: matrix),
        codes: { x, _ in SIMD3(940, 300 + x, 700 - x) })
      for scope in ScopeKind.allCases {
        var s = ScopeSettings(kind: scope, stage: .source)
        s.clipHighPercent = 100
        let stats = try statistics(s, frame)
        XCTAssertEqual(stats.clippedHigh[3], 1, "\(matrix) \(scope)")
        XCTAssertEqual(stats.lumaMinimum, 1, accuracy: 1.0 / 1_048_576, "\(matrix) \(scope)")
      }
    }
  }

  /// Every matrix and every horizontal and vertical chroma siting, through
  /// each scope's bins.
  func testEveryMatrixAndChromaSiting() throws {
    let (_, _, engine) = try GPU.require()
    for matrix in Self.matrices {
      for siting in ChromaSiting.allCases {
        for vertical in ChromaVerticalSiting.allCases {
          let signal = SignalDescription(matrix: matrix, chromaSiting: siting, chromaVerticalSiting: vertical)
          let kinds: [TestFrame.Kind] =
            vertical == .center ? [.v210, .uyvy8, .biplanar(.s422, 10), .biplanar(.s420, 8)] : [.biplanar(.s420, 10)]
          for kind in kinds {
            let frame = try TestFrame.natural(kind, width: 118, height: 23, seed: 13, signal: signal)
            for scope in ScopeKind.allCases {
              var s = ScopeSettings(kind: scope, stage: .source)
              s.waveformMode = .ycbcrParade
              s.waveformColumns = 120
              s.waveformLevels = 256
              s.histogramMode = .rgbParade
              s.histogramBins = 256
              s.vectorscopeSize = 256
              let accumulator = try engine.makeAccumulator(settings: s)
              try GPU.run { cb in try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
              XCTAssertEqual(accumulator.context.matrix, matrix)
              ScopeAccumulationTests.reference(accumulator, frame).check(
                try readBins(accumulator), "\(matrix) \(siting) \(vertical) \(kind) \(scope)")
            }
          }
        }
      }
    }
  }

  /// The Y'CbCr parade's chroma code ticks sit on the bins those codes fill.
  func testYCbCrParadeChromaTicksMatchTheBins() throws {
    let (_, _, engine) = try GPU.require()
    for (cb, cr) in [(512, 512), (64, 960), (300, 700)] {
      let frame = try TestFrame.make(
        .biplanar(.s444, 10), width: 64, height: 8, codes: { _, _ in SIMD3(500, cb, cr) })
      var s = ScopeSettings(kind: .waveform, stage: .source)
      s.waveformMode = .ycbcrParade
      s.waveformLevels = 2048
      s.waveformColumns = 192
      let accumulator = try engine.makeAccumulator(settings: s)
      try GPU.run { cb in try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
      let bins = try readBins(accumulator)
      let layout = accumulator.layout
      for (channel, code) in [(1, cb), (2, cr)] {
        let rows = (0..<layout.rows).filter { bins[layout.index(channel: channel, row: $0, column: 0)] > 0 }
        XCTAssertEqual(rows.count, 1, "channel \(channel) code \(code)")
        let level = (Double(code) - 512) / 896 + 0.5
        let bin = Int((ScopeLevelAxis.fraction(ofLevel: level) * Double(layout.rows)).rounded(.down))
        XCTAssertEqual(rows.first, bin, "channel \(channel) code \(code)")
        if let tick = WaveformScale.codeValues.chromaTicks(range: .legal).first(where: { $0.value == Double(code) }) {
          XCTAssertEqual(tick.level, level, accuracy: 1e-12)
        }
      }
    }
  }
}
