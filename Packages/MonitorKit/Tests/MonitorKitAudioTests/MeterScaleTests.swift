import Foundation
import MonitorKitAudio
import XCTest

/// The scale data a meter view draws: marks, mapping onto the travel, zones
/// and the conversion from the meters' readings.
final class MeterScaleTests: XCTestCase {
  static var all: [MeterScale] {
    [
      .digitalPeak(), .digitalPeak(unit: .dBFS, maximumPeak: 0), .digitalPeak(range: -40...0, alignment: .smpte),
      .vu, .ppm(.typeI), .ppm(.typeIIa), .ppm(.typeIIb), .ppmNordic,
      .loudness(.ebuPlus9), .loudness(.ebuPlus18), .loudness(.ebuPlus9, unit: .lufs),
      .loudness(.ebuPlus18, unit: .lufs, target: -24),
    ]
  }

  /// Every scale: marks ascending inside the bounds, zones contiguous over
  /// them, and positions that rise with the value from 0 to 1.
  func testScalesAreWellFormed() {
    for scale in Self.all {
      let name = "\(scale.unit) \(scale.lowerBound)...\(scale.upperBound)"
      XCTAssertLessThan(scale.lowerBound, scale.upperBound, name)
      XCTAssertFalse(scale.marks.isEmpty, name)
      for (a, b) in zip(scale.marks, scale.marks.dropFirst()) { XCTAssertLessThan(a.value, b.value, name) }
      for mark in scale.marks {
        XCTAssertTrue((scale.lowerBound...scale.upperBound).contains(mark.value), name)
        if mark.isMajor { XCTAssertNotNil(mark.label, name) }
      }
      XCTAssertEqual(scale.zones.first?.lower, scale.lowerBound, name)
      XCTAssertEqual(scale.zones.last?.upper, scale.upperBound, name)
      for (a, b) in zip(scale.zones, scale.zones.dropFirst()) { XCTAssertEqual(a.upper, b.lower, name) }
      for zone in scale.zones { XCTAssertLessThan(zone.lower, zone.upper, name) }
      if let a = scale.alignment { XCTAssertTrue((scale.lowerBound...scale.upperBound).contains(a), name) }
      if let p = scale.permittedMaximum { XCTAssertGreaterThan(p, scale.alignment ?? -.infinity, name) }

      XCTAssertEqual(scale.position(of: scale.upperBound), 1, accuracy: 1e-12, name)
      XCTAssertEqual(scale.position(of: scale.upperBound + 10), 1, name)
      XCTAssertEqual(scale.position(of: -.infinity), 0, name)
      XCTAssertEqual(scale.position(of: .nan), 0, name)
      var last = -1.0
      var v = scale.lowerBound
      while v <= scale.upperBound {
        let p = scale.position(of: v)
        XCTAssertGreaterThan(p, last, "\(name) at \(v)")
        last = p
        v += (scale.upperBound - scale.lowerBound) / 97
      }
      XCTAssertEqual(scale.zone(of: scale.lowerBound - 100), scale.zones.first?.kind, name)
      XCTAssertEqual(scale.zone(of: scale.upperBound + 100), scale.zones.last?.kind, name)
    }
  }

  /// IEC 60268-18 marks, EBU R 68 alignment and PML ticks, R 128 zones.
  func testDigitalPeakScale() {
    let s = MeterScale.digitalPeak()
    XCTAssertEqual(s.unit, .dBTP)
    XCTAssertEqual(
      s.marks.filter(\.isMajor).map(\.value), [-60, -50, -40, -35, -30, -25, -20, -15, -10, -5, 0])
    XCTAssertEqual(s.marks.filter(\.isMajor).map(\.label), ["-60", "-50", "-40", "-35", "-30", "-25", "-20", "-15", "-10", "-5", "0"])
    XCTAssertEqual(s.marks.filter { !$0.isMajor }.map(\.value), [-18, -9])
    XCTAssertEqual(s.alignment, -18)
    XCTAssertEqual(s.permittedMaximum, -9)
    XCTAssertEqual(s.zones.map(\.kind), [.normal, .caution, .over])
    XCTAssertEqual(s.zones.map(\.lower), [-60, -9, -1])
    XCTAssertEqual(s.zone(of: -9.5), .normal)
    XCTAssertEqual(s.zone(of: -9), .caution)
    XCTAssertEqual(s.zone(of: -0.5), .over)
    XCTAssertEqual(s.position(of: -30), 0.5, accuracy: 1e-12)
    XCTAssertEqual(s.value(forReading: -12.5), -12.5)

    // SMPTE RP 155 alignment: -20 dBFS, PML -11.
    let smpte = MeterScale.digitalPeak(unit: .dBFS, range: -40...0, alignment: .smpte, maximumPeak: 0)
    XCTAssertEqual(smpte.alignment, -20)
    XCTAssertEqual(smpte.permittedMaximum, -11)
    XCTAssertEqual(smpte.marks.filter { !$0.isMajor }.map(\.value), [-11])
    XCTAssertEqual(smpte.zones.map(\.kind), [.normal, .caution])
  }

  /// IEC 60268-17: 0 VU at 70.7 % of the travel (3 dB below full deflection).
  func testVUScale() {
    let s = MeterScale.vu
    XCTAssertEqual(s.marks.map(\.value), [-20, -10, -7, -5, -3, -2, -1, 0, 1, 2, 3])
    XCTAssertEqual(s.marks.map(\.label), ["-20", "-10", "-7", "-5", "-3", "-2", "-1", "0", "+1", "+2", "+3"])
    XCTAssertEqual(s.position(of: 0), pow(10, -3.0 / 20), accuracy: 1e-12)
    XCTAssertEqual(s.position(of: -20), pow(10, -23.0 / 20), accuracy: 1e-12)
    XCTAssertEqual(s.zone(of: -0.1), .normal)
    XCTAssertEqual(s.zone(of: 0.5), .over)
  }

  /// The PPM scales take the meter's reading (dB re alignment) as each type's face shows it.
  func testPPMScales() {
    let bbc = MeterScale.ppm(.typeIIa)
    XCTAssertEqual(bbc.marks.map(\.label), ["1", "2", "3", "4", "5", "6", "7"])
    XCTAssertEqual(bbc.value(forReading: 0), 4)
    XCTAssertEqual(bbc.value(forReading: 8), 6, "PML: +8 dB is mark 6")
    XCTAssertEqual(bbc.value(forReading: -12), 1)
    XCTAssertEqual(bbc.zone(of: bbc.value(forReading: 9)), .over)
    for level in stride(from: -12.0, through: 12, by: 1) {
      XCTAssertEqual(bbc.value(forReading: level), PPMType.typeIIa.scaleReading(dBRelativeToAlignment: level))
    }

    let ebu = MeterScale.ppm(.typeIIb)
    XCTAssertEqual(ebu.marks.filter(\.isMajor).map(\.label), ["-12", "-8", "-4", "TEST", "+4", "+8", "+12"])
    XCTAssertEqual(ebu.marks.filter { !$0.isMajor }.map(\.value), [-10, -6, -2, 2, 6, 9, 10])
    XCTAssertEqual(ebu.value(forReading: 5), 5)
    XCTAssertEqual(ebu.zone(of: 8.9), .normal)
    XCTAssertEqual(ebu.zone(of: 9), .over)

    let din = MeterScale.ppm(.typeI)
    XCTAssertEqual(din.marks.filter(\.isMajor).map(\.label), ["-50", "-40", "-30", "-20", "-10", "-5", "0", "+5"])
    XCTAssertEqual(din.value(forReading: 0), -9, "alignment sits 9 dB below the PML")
    XCTAssertEqual(din.value(forReading: 9), 0)
    XCTAssertEqual(din.position(of: -10), 0.5, accuracy: 1e-12)
    XCTAssertEqual(din.position(of: -5), 0.66, accuracy: 1e-12)
    XCTAssertEqual(din.zone(of: 0.5), .over)
    for level in stride(from: -40.0, through: 14, by: 1) {
      XCTAssertEqual(din.value(forReading: level), PPMType.typeI.scaleReading(dBRelativeToAlignment: level))
    }

    let nordic = MeterScale.ppmNordic
    XCTAssertEqual(nordic.marks.map(\.label), ["-36", "-30", "-24", "-18", "-12", "-6", "TEST", "+6", "+9"])
    XCTAssertEqual(nordic.permittedMaximum, 9)
  }

  /// EBU Tech 3341: +9 is -18...+9 LU (-41...-14 LUFS), +18 is -36...+18 LU (-59...-5 LUFS).
  func testLoudnessScales() {
    let plus9 = MeterScale.loudness(.ebuPlus9)
    XCTAssertEqual(plus9.unit, .lu)
    XCTAssertEqual(plus9.lowerBound, -18)
    XCTAssertEqual(plus9.upperBound, 9)
    XCTAssertEqual(plus9.marks.filter(\.isMajor).map(\.label), ["-18", "-15", "-12", "-9", "-6", "-3", "0", "+3", "+6", "+9"])
    XCTAssertEqual(plus9.marks.count, 28)
    XCTAssertEqual(plus9.value(forReading: -23), 0)
    XCTAssertEqual(plus9.value(forReading: -20), 3)
    XCTAssertEqual(plus9.position(forReading: -23), 18.0 / 27, accuracy: 1e-12)
    XCTAssertEqual(plus9.position(forReading: -.infinity), 0)
    XCTAssertEqual(plus9.zones.map(\.kind), [.normal, .target, .caution])
    XCTAssertEqual(plus9.zone(of: plus9.value(forReading: -24.5)), .normal)
    XCTAssertEqual(plus9.zone(of: plus9.value(forReading: -22.5)), .target)
    XCTAssertEqual(plus9.zone(of: plus9.value(forReading: -21.5)), .caution)

    let plus18 = MeterScale.loudness(.ebuPlus18, unit: .lufs)
    XCTAssertEqual(plus18.unit, .lufs)
    XCTAssertEqual(plus18.lowerBound, -59)
    XCTAssertEqual(plus18.upperBound, -5)
    XCTAssertEqual(plus18.alignment, -23)
    XCTAssertEqual(plus18.value(forReading: -30), -30)
    XCTAssertEqual(plus18.marks.filter(\.isMajor).map(\.label), ["-59", "-53", "-47", "-41", "-35", "-29", "-23", "-17", "-11", "-5"])
    XCTAssertEqual(plus18.zones.map(\.lower), [-59, -24, -22])

    // ATSC A/85 target.
    let atsc = MeterScale.loudness(.ebuPlus9, unit: .lu, target: -24)
    XCTAssertEqual(atsc.value(forReading: -24), 0)
    XCTAssertEqual(MeterScale.loudness(.ebuPlus9, unit: .lufs, target: -24).lowerBound, -42)
  }
}
