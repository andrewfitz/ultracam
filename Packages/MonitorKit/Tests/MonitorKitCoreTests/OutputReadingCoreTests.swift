import Foundation
import XCTest

@testable import MonitorKitCore

/// `SignalDescription.outputReading`: the Output and Monitor stages' own range
/// and matrix. Persisted leniently, and absent in older descriptions.
final class OutputReadingCoreTests: XCTestCase {
  func testRoundTripsAndOlderDescriptionsReadEveryStageAsTheSource() throws {
    let signal = SignalDescription(
      range: .full, matrix: .smpte240m, encoding: .log(.sLog3SGamut3Cine),
      outputReading: SignalReading(range: .legal, matrix: .bt709))
    let data = try JSONEncoder().encode(signal)
    XCTAssertEqual(try JSONDecoder().decode(SignalDescription.self, from: data), signal)
    // A description saved before the field existed.
    let old = Data(#"{"range":"full","matrix":"bt709","chromaSiting":"left","encoding":{"display":{"_0":"bt709"}}}"#.utf8)
    let decoded = try JSONDecoder().decode(SignalDescription.self, from: old)
    XCTAssertNil(decoded.outputReading)
    XCTAssertFalse(decoded.hasDistinctOutputReading)
    // A malformed reading is no reading; a reading with a bad field is lenient.
    let bad = Data(#"{"range":"legal","outputReading":7}"#.utf8)
    XCTAssertNil(try JSONDecoder().decode(SignalDescription.self, from: bad).outputReading)
    let partial = Data(#"{"range":"legal","outputReading":{"range":"full","matrix":"nonsense"}}"#.utf8)
    XCTAssertEqual(
      try JSONDecoder().decode(SignalDescription.self, from: partial).outputReading,
      SignalReading(range: .full, matrix: .bt709))
  }

  func testStageSignals() {
    var s = SignalDescription(range: .full, matrix: .smpte240m)
    XCTAssertEqual(s.effectiveOutputReading, s.sourceReading)
    s.outputReading = SignalReading(range: .legal, matrix: .bt709)
    XCTAssertTrue(s.hasDistinctOutputReading)
    XCTAssertEqual(s.signal(for: .source), s)
    XCTAssertEqual(s.signal(for: .output), s.outputSignal)
    XCTAssertEqual(s.signal(for: .monitor).range, .legal)
    XCTAssertEqual(s.signal(for: .monitor).matrix, .bt709)
    // The output reading decodes the same codes: code 940 is white there, not in the declared full range.
    let declared = DecodeReference.rgb(lumaCode: 940, cbCode: 512, crCode: 512, bitDepth: 10, range: s.range, matrix: s.matrix)
    let output = DecodeReference.rgb(
      lumaCode: 940, cbCode: 512, crCode: 512, bitDepth: 10, range: s.outputSignal.range, matrix: s.outputSignal.matrix)
    XCTAssertEqual(output.luma, 1)
    XCTAssertEqual(declared.luma, 940.0 / 1023)
  }
}
