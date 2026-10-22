import Foundation
import MonitorKitCore
import XCTest

@testable import MonitorKitScopes

final class ScopeSettingsTests: XCTestCase {
  func testRoundTrip() throws {
    var s = ScopeSettings(kind: .vectorscope, stage: .monitor)
    s.vectorscopeZoom = 4
    s.colorimetry = .bt2020
    s.waveformMode = .ycbcrParade
    s.histogramMode = .rgbParade
    s.display.waveformScale = .pqNits
    s.display.histogramScale = .logarithmic
    s.display.vectorscopeTargets = .percent100
    s.display.trace = .colorized
    s.display.backgroundOpacity = 0.3
    let data = try JSONEncoder().encode(s)
    XCTAssertEqual(try JSONDecoder().decode(ScopeSettings.self, from: data), s)
  }

  func testLenientDecode() throws {
    let json = """
      {"schemaVersion": 1, "kind": "histogram", "stage": "nonsense", "vectorscopeZoom": 3,
       "waveformLevels": 99999, "histogramBins": 333, "clipHighPercent": "high",
       "display": {"brightness": -5, "gain": 1e9, "trace": 7, "skinToneAngle": 400}}
      """
    let s = try JSONDecoder().decode(ScopeSettings.self, from: Data(json.utf8))
    XCTAssertEqual(s.kind, .histogram)
    XCTAssertEqual(s.stage, .output, "malformed values fall back to defaults")
    XCTAssertEqual(s.vectorscopeZoom, 1)
    XCTAssertEqual(s.waveformLevels, 2048)
    XCTAssertEqual(s.histogramBins, 332, "even")
    XCTAssertEqual(s.clipHighPercent, 100)
    XCTAssertEqual(s.display.brightness, 0)
    XCTAssertEqual(s.display.gain, 20)
    XCTAssertEqual(s.display.trace, .phosphor)
    XCTAssertEqual(s.display.skinToneAngle, 360)
  }

  func testUnknownSchemaAndGarbageDecodeAsDefaults() throws {
    let future = try JSONDecoder().decode(
      ScopeSettings.self, from: Data(#"{"schemaVersion": 9, "kind": "histogram"}"#.utf8))
    XCTAssertEqual(future, ScopeSettings())
    let array = try JSONDecoder().decode(ScopeSettings.self, from: Data("[1, 2]".utf8))
    XCTAssertEqual(array, ScopeSettings())
  }

  func testNormalizedClampsEverything() {
    var s = ScopeSettings()
    s.waveformColumns = 7
    s.waveformLevels = 1
    s.vectorscopeSize = 3001
    s.clipLowPercent = .nan
    s.display.backgroundOpacity = .infinity
    s.display.graticuleOpacity = 2
    let n = s.normalized()
    XCTAssertEqual(n.waveformColumns, 64)
    XCTAssertEqual(n.waveformLevels, 64)
    XCTAssertEqual(n.vectorscopeSize, 2048)
    XCTAssertEqual(n.clipLowPercent, 0)
    XCTAssertEqual(n.display.backgroundOpacity, 0.85)
    XCTAssertEqual(n.display.graticuleOpacity, 1)
    XCTAssertEqual(n.normalized(), n)
  }

  func testParadeColumnsAreEvenThirds() {
    var s = ScopeSettings()
    s.waveformColumns = 1024
    s.waveformMode = .rgbParade
    XCTAssertEqual(s.waveformColumnsPerChannel, 340)
    s.waveformMode = .luma
    XCTAssertEqual(s.waveformColumnsPerChannel, 1024)
  }

  func testAccumulationKeyIgnoresDisplay() {
    var a = ScopeSettings(), b = ScopeSettings()
    b.display.brightness = 3
    b.display.waveformScale = .hlgNits
    XCTAssertEqual(a.accumulationKey, b.accumulationKey)
    a.stage = .source
    XCTAssertNotEqual(a.accumulationKey, b.accumulationKey)
  }

  func testColorimetryFollowsTheStage() {
    XCTAssertEqual(ScopeColorimetry.auto.matrix(source: .bt2020, lutApplied: false), .bt2020)
    XCTAssertEqual(ScopeColorimetry.auto.matrix(source: .bt2020, lutApplied: true), .bt709)
    XCTAssertEqual(ScopeColorimetry.bt601.matrix(source: .bt2020, lutApplied: true), .bt601)
  }

  func testIntensityCurves() {
    XCTAssertEqual(ScopeIntensityCurve.logarithmic.value(density: 0), 0)
    XCTAssertEqual(ScopeIntensityCurve.logarithmic.value(density: 16), 1, accuracy: 1e-12)
    XCTAssertEqual(ScopeIntensityCurve.logarithmic.value(density: 1000), 1)
    XCTAssertEqual(ScopeIntensityCurve.gamma.value(density: 16), 1, accuracy: 1e-12)
    // A single pixel among many still lights the trace.
    XCTAssertGreaterThan(ScopeIntensityCurve.logarithmic.value(density: 0.03), 0.05)
    var previous = -1.0
    for d in stride(from: 0.0, through: 20, by: 0.25) {
      let v = ScopeIntensityCurve.logarithmic.value(density: d)
      XCTAssertGreaterThanOrEqual(v, previous)
      previous = v
    }
  }
}
