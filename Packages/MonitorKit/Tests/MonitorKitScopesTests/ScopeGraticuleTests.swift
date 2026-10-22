import Foundation
import MonitorKitCore
import XCTest

@testable import MonitorKitScopes

final class ScopeGraticuleTests: XCTestCase {
  func testPQAnchors() {
    // SMPTE ST 2084 reference values.
    XCTAssertEqual(ScopeTransfer.pqSignal(nits: 0), 7.3e-7, accuracy: 1e-6)
    XCTAssertEqual(ScopeTransfer.pqSignal(nits: 100), 0.50808, accuracy: 1e-4)
    XCTAssertEqual(ScopeTransfer.pqSignal(nits: 203), 0.58069, accuracy: 1e-4)
    XCTAssertEqual(ScopeTransfer.pqSignal(nits: 1000), 0.75183, accuracy: 1e-4)
    XCTAssertEqual(ScopeTransfer.pqSignal(nits: 10000), 1, accuracy: 1e-12)
    for nits in [0.1, 1, 48, 100, 203, 1000, 4000, 10000] {
      XCTAssertEqual(ScopeTransfer.pqNits(signal: ScopeTransfer.pqSignal(nits: nits)), nits, accuracy: nits * 1e-9)
    }
  }

  func testHLGAnchors() {
    // BT.2100: 75% HLG is 203 cd/m² on a 1000 cd/m² display (BT.2408); 100% is peak.
    XCTAssertEqual(ScopeTransfer.hlgNits(signal: 0.75), 203, accuracy: 0.6)
    XCTAssertEqual(ScopeTransfer.hlgNits(signal: 1), 1000, accuracy: 0.01)
    XCTAssertEqual(ScopeTransfer.hlgOETF(1.0 / 12), 0.5, accuracy: 1e-9)
    XCTAssertEqual(ScopeTransfer.hlgOETF(1), 1, accuracy: 1e-7)
    XCTAssertEqual(ScopeTransfer.hlgGamma(peak: 1000), 1.2)
    for nits in [0.1, 1, 10, 100, 203, 500, 1000] {
      XCTAssertEqual(ScopeTransfer.hlgNits(signal: ScopeTransfer.hlgSignal(nits: nits)), nits, accuracy: nits * 1e-9)
    }
    // BT.2408 Table 1 on a 1000 cd/m² display: the grey card (26 cd/m²) is 38%
    // (0.3786 unrounded) and reference white (203 cd/m²) 75%.
    XCTAssertEqual(ScopeTransfer.hlgSignal(nits: 26), 0.3786, accuracy: 1e-4)
    XCTAssertEqual(ScopeTransfer.hlgSignal(nits: 203), 0.75, accuracy: 2e-3)
  }

  /// The default skin-tone line is the NTSC I axis in the U/V plane, 123°
  /// (MATH.md 7, cross-checked in MathReferenceTests.testSkinToneLineIsTheNTSCIAxis).
  func testSkinToneLineDefaultsToTheNTSCIAxis() {
    XCTAssertEqual(ScopeDisplay().skinToneAngle, 123)
    var display = ScopeDisplay()
    display.skinToneAngle = .nan
    XCTAssertEqual(display.normalized().skinToneAngle, 123)
  }

  func testPercentTicks() {
    let ticks = WaveformScale.percent.ticks(range: .legal)
    XCTAssertEqual(ticks.map(\.value), stride(from: 0.0, through: 100, by: 10).map { $0 })
    XCTAssertEqual(ticks.filter(\.isMajor).map(\.label), ["0", "50", "100"])
    XCTAssertEqual(ticks.last?.level, 1)
  }

  func testCodeTicksFollowTheRange() {
    let legal = WaveformScale.codeValues.ticks(range: .legal)
    XCTAssertEqual(legal.first { $0.value == 940 }?.level, 1)
    XCTAssertEqual(legal.first { $0.value == 64 }?.level, 0)
    XCTAssertEqual(legal.first { $0.value == 1019 }?.level, ScopeLevelAxis.high, "snapped onto the axis top")
    XCTAssertEqual(legal.first { $0.value == 4 }?.level ?? 0, -60.0 / 876, accuracy: 1e-12)
    let full = WaveformScale.codeValues.ticks(range: .full)
    XCTAssertEqual(full.first { $0.value == 1023 }?.level, 1)
    XCTAssertEqual(full.first { $0.value == 0 }?.level, 0)
  }

  func testHDRTicks() {
    let pq = WaveformScale.pqNits.ticks(range: .legal)
    XCTAssertEqual(pq.first?.value, 0.1)
    XCTAssertEqual(pq.last?.value, 10000)
    XCTAssertEqual(pq.last?.level, 1)
    XCTAssertEqual(pq.first { $0.value == 100 }?.level ?? 0, 0.50808, accuracy: 1e-4)
    XCTAssertEqual(pq.first { $0.value == 0.1 }?.label, "0.1")
    XCTAssertEqual(pq.first { $0.value == 10000 }?.label, "10000")
    XCTAssertTrue(zip(pq, pq.dropFirst()).allSatisfy { $0.level < $1.level }, "ascending")
    let hlg = WaveformScale.hlgNits.ticks(range: .legal)
    XCTAssertEqual(hlg.first { $0.value == 1000 }?.level ?? 0, 1, accuracy: 1e-7)
    XCTAssertEqual(hlg.first { $0.value == 203 }?.level ?? 0, 0.75, accuracy: 0.001)
    XCTAssertTrue(zip(hlg, hlg.dropFirst()).allSatisfy { $0.level < $1.level }, "ascending")
  }

  func testWaveformLabelPositions() {
    var s = ScopeSettings(kind: .waveform)
    s.display.waveformScale = .percent
    let g = ScopeGraticule(settings: s, context: ScopeContext(), viewportWidth: 1024, viewportHeight: 512)
    let hundred = g.labels.first { $0.value == 100 }!
    // The centre of the bin 100% lands in: floor(1.07 · 512 / 1.16) = 472.
    XCTAssertEqual(hundred.position.y, 1 - 472.5 / 512, accuracy: 1e-12)
    XCTAssertEqual(hundred.position.y, 1 - 1.07 / 1.16, accuracy: 0.5 / 512, "within half a bin of the axis")
    XCTAssertEqual(hundred.position.x, 0)
    XCTAssertEqual(g.labels.first { $0.value == 0 }!.position.y, 1 - 30.5 / 512, accuracy: 1e-12)
    XCTAssertEqual(g.elements.count, 11)

    s.display.waveformScale = .pqNits
    s.waveformMode = .rgbParade
    let pq = ScopeGraticule(settings: s, context: ScopeContext(), viewportWidth: 1024, viewportHeight: 512)
    let n203 = pq.labels.first { $0.value == 203 && $0.role == .tick }!
    XCTAssertEqual(
      n203.position.y, 1 - ScopeLevelAxis.drawnFraction(ofLevel: ScopeTransfer.pqSignal(nits: 203), bins: 512),
      accuracy: 1e-12)
    XCTAssertEqual(pq.labels.filter { $0.role == .channel }.map(\.text), ["R", "G", "B"])

    s.display.waveformScale = .hlgNits
    s.kind = .histogram
    let hlg = ScopeGraticule(settings: s, context: ScopeContext(), viewportWidth: 800, viewportHeight: 300)
    let n1000 = hlg.labels.first { $0.value == 1000 }!
    XCTAssertEqual(n1000.position.x, ScopeLevelAxis.drawnFraction(ofLevel: 1, bins: 512), accuracy: 1e-12)
    XCTAssertEqual(n1000.position.x, ScopeLevelAxis.fraction(ofLevel: 1), accuracy: 0.5 / 512)
    XCTAssertEqual(n1000.position.y, 1)
  }

  func testVectorscopeTargetGeometry() {
    let r709 = VectorscopeTarget.bars(matrix: .bt709, amplitude: 0.75)
    let red = r709.first { $0.name == "R" }!, yellow = r709.first { $0.name == "Yl" }!
    XCTAssertEqual(red.cr, 0.375, accuracy: 1e-12)
    XCTAssertEqual(red.cb, -0.75 * 0.2126 / (2 * (1 - 0.0722)), accuracy: 1e-12)
    XCTAssertEqual(red.angle, 102.9, accuracy: 0.1)
    XCTAssertEqual(yellow.angle, 174.8, accuracy: 0.1)
    XCTAssertTrue(red.angle < 123 && 123 < yellow.angle, "the skin-tone line sits between red and yellow")
    let full709 = VectorscopeTarget.bars(matrix: .bt709, amplitude: 1)
    XCTAssertEqual(full709.first { $0.name == "B" }!.cb, 0.5, accuracy: 1e-12)
    XCTAssertEqual(full709.first { $0.name == "R" }!.cr, 0.5, accuracy: 1e-12)
    for (a, b) in zip(r709, full709) {
      XCTAssertEqual(a.cb, b.cb * 0.75, accuracy: 1e-12)
      XCTAssertEqual(a.angle, b.angle, accuracy: 1e-9)
    }
    let r2020 = VectorscopeTarget.bars(matrix: .bt2020, amplitude: 1).first { $0.name == "R" }!
    XCTAssertEqual(r2020.cb, -0.2627 / (2 * (1 - 0.0593)), accuracy: 1e-12)
    // Every 100% target fits the 1× plane.
    for m in [YCbCrMatrix.bt601, .bt709, .bt2020] {
      for t in VectorscopeTarget.bars(matrix: m, amplitude: 1) {
        XCTAssertLessThan(max(abs(t.cb), abs(t.cr)), VectorscopeGeometry.halfExtent)
      }
    }
  }

  func testVectorscopeGraticuleLayout() {
    var s = ScopeSettings(kind: .vectorscope)
    s.display.vectorscopeTargets = .both
    let g = ScopeGraticule(settings: s, context: ScopeContext(matrix: .bt709), viewportWidth: 800, viewportHeight: 400)
    XCTAssertEqual(g.plot.z, 0.5, accuracy: 1e-12, "square plot, half the width")
    XCTAssertEqual(g.plot.x, 0.25, accuracy: 1e-12)
    XCTAssertEqual(g.targets.count, 12)
    XCTAssertEqual(g.labels.filter { $0.role == .target }.count, 12)
    // The 75% red label sits just outside its target, on the same angle.
    let red = g.targets.first { $0.name == "R" && $0.amplitude == 0.75 }!
    let label = g.labels.first { $0.text == "R" && $0.value == 0.75 }!
    let centre = SIMD2(0.5, 0.5)
    let v = (label.position - centre) * SIMD2(800, -400)
    XCTAssertEqual(atan2(v.y, v.x) * 180 / .pi, red.angle, accuracy: 0.01)
    let targetRadius = red.magnitude / VectorscopeGeometry.halfExtent * 200
    XCTAssertGreaterThan((v * v).sum().squareRoot(), targetRadius)
    s.vectorscopeZoom = 2
    let zoomed = ScopeGraticule(settings: s, context: ScopeContext(matrix: .bt709), viewportWidth: 800, viewportHeight: 400)
    XCTAssertLessThan(zoomed.labels.filter { $0.role == .target }.count, 12, "off-plot targets lose their labels")
    for label in zoomed.labels { XCTAssertTrue((0...1).contains(label.position.x) && (0...1).contains(label.position.y)) }
    if case .circle(_, let r1, _) = g.elements[0], case .circle(_, let r2, _) = zoomed.elements[0] {
      XCTAssertEqual(r2, r1 * 2, accuracy: 1e-12)
    } else {
      XCTFail("outer circle first")
    }
    s.display.showsSkinToneLine = false
    s.display.vectorscopeTargets = .none
    let bare = ScopeGraticule(settings: s, context: ScopeContext(), viewportWidth: 400, viewportHeight: 400)
    XCTAssertEqual(bare.elements.count, 4)
    XCTAssertTrue(bare.labels.isEmpty)
  }

  /// Code values on the Y'CbCr parade: luma codes on the Y panel, chroma codes
  /// (512 neutral, 64 and 960 the legal extremes) on the Cb and Cr panels.
  func testYCbCrParadeLabelsChromaCodes() {
    var s = ScopeSettings(kind: .waveform)
    s.waveformMode = .ycbcrParade
    s.display.waveformScale = .codeValues
    let g = ScopeGraticule(settings: s, context: ScopeContext(range: .legal), viewportWidth: 900, viewportHeight: 400)
    let luma = g.labels.filter { $0.role == .tick && $0.position.x == 0 }
    let chroma = g.labels.filter { $0.role == .tick && $0.position.x == 1.0 / 3 }
    XCTAssertEqual(luma.map(\.text), ["4", "64", "128", "256", "384", "512", "640", "768", "896", "940", "1019"])
    XCTAssertEqual(chroma.map(\.text), ["64", "128", "256", "384", "512", "640", "768", "896", "960"])
    func y(_ level: Double) -> Double { 1 - ScopeLevelAxis.drawnFraction(ofLevel: level, bins: s.waveformLevels) }
    XCTAssertEqual(chroma.first { $0.text == "512" }!.position.y, y(0.5), accuracy: 1e-12, "neutral chroma")
    XCTAssertEqual(chroma.first { $0.text == "64" }!.position.y, y(0), accuracy: 1e-12)
    XCTAssertEqual(chroma.first { $0.text == "960" }!.position.y, y(1), accuracy: 1e-12)
    XCTAssertEqual(luma.first { $0.text == "940" }!.position.y, y(1), accuracy: 1e-12)
    // Luma lines stop at the first divider; chroma lines start there.
    for element in g.elements {
      guard case .line(let a, let b, _) = element, a.y == b.y else { continue }
      XCTAssertTrue((a.x == 0 && b.x == 1.0 / 3) || (a.x == 1.0 / 3 && b.x == 1), "\(a) → \(b)")
    }
    let full = WaveformScale.codeValues.chromaTicks(range: .full)
    XCTAssertEqual(full.first { $0.value == 512 }!.level, 0.5, accuracy: 1e-12)
    XCTAssertEqual(full.first { $0.value == 1023 }!.level, 1 - 0.5 / 1023, accuracy: 1e-12)
    // Other scales label chroma in percent: nits mean nothing for chroma.
    XCTAssertEqual(WaveformScale.pqNits.chromaTicks(range: .legal), WaveformScale.percent.ticks(range: .legal))
    s.display.waveformScale = .pqNits
    let pq = ScopeGraticule(settings: s, context: ScopeContext(), viewportWidth: 900, viewportHeight: 400)
    XCTAssertTrue(pq.labels.filter { $0.position.x == 1.0 / 3 }.allSatisfy { !$0.text.contains(".") })
    XCTAssertLessThanOrEqual(pq.elements.count, ScopeGraticuleParameters.maximumShapes)
  }

  /// A tick sits on the centre of the bin a pixel at exactly its level is
  /// counted in, at every bin count: low counts (64 levels) used to draw legal
  /// white a third of a bin above the 100% line and black below the 0% line.
  func testTicksSitOnTheBinTheirLevelLandsIn() {
    for bins in [64, 65, 100, 256, 333, 512, 1000, 2048, 4096] {
      let scale = Float(Double(bins) / (ScopeLevelAxis.high - ScopeLevelAxis.low))
      for level in [-0.07, 0, 0.18, 0.5, 1, 1.09] {
        let bin = min(max(((Float(level) - Float(ScopeLevelAxis.low)) * scale).rounded(.down), 0), Float(bins - 1))
        let drawn = ScopeLevelAxis.drawnFraction(ofLevel: level, bins: bins)
        XCTAssertEqual(drawn * Double(bins), Double(bin) + 0.5, accuracy: 1e-9, "\(bins) bins, level \(level)")
        XCTAssertEqual(drawn, ScopeLevelAxis.fraction(ofLevel: level), accuracy: 0.5 / Double(bins) + 1e-9)
      }
    }
    var s = ScopeSettings(kind: .waveform)
    s.waveformLevels = 64
    let g = ScopeGraticule(settings: s, context: ScopeContext(), viewportWidth: 1000, viewportHeight: 1000)
    // 100% is bin floor(1.07 · 64 / 1.16) = 59, 0% bin 3.
    XCTAssertEqual(g.labels.first { $0.value == 100 }!.position.y, 1 - 59.5 / 64, accuracy: 1e-12)
    XCTAssertEqual(g.labels.first { $0.value == 0 }!.position.y, 1 - 3.5 / 64, accuracy: 1e-12)
    s.kind = .histogram
    s.histogramBins = 64
    let h = ScopeGraticule(settings: s, context: ScopeContext(), viewportWidth: 1000, viewportHeight: 300)
    XCTAssertEqual(h.labels.first { $0.value == 100 }!.position.x, 59.5 / 64, accuracy: 1e-12)
  }

  /// Angles run 0…360 counter-clockwise from +Cb, as Docs/MATH.md section 7 lists them.
  func testVectorscopeTargetAnglesFollowMATH() {
    let bars = VectorscopeTarget.bars(matrix: .bt709, amplitude: 0.75)
    let angles = Dictionary(uniqueKeysWithValues: bars.map { ($0.name, $0.angle) })
    XCTAssertEqual(angles["Cy"]!, 282.91, accuracy: 0.01)
    XCTAssertEqual(angles["G"]!, 229.68, accuracy: 0.01)
    XCTAssertEqual(angles["B"]!, 354.76, accuracy: 0.01)
    XCTAssertEqual(angles["R"]!, 102.91, accuracy: 0.01)
    for matrix in [YCbCrMatrix.bt601, .bt709, .bt2020, .smpte240m] {
      for bar in VectorscopeTarget.bars(matrix: matrix, amplitude: 1) {
        XCTAssertGreaterThanOrEqual(bar.angle, 0)
        XCTAssertLessThan(bar.angle, 360)
        let radians = bar.angle * .pi / 180
        XCTAssertEqual(cos(radians) * bar.magnitude, bar.cb, accuracy: 1e-12)
        XCTAssertEqual(sin(radians) * bar.magnitude, bar.cr, accuracy: 1e-12)
      }
    }
  }
}
