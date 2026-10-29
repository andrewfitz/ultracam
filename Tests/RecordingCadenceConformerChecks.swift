import CoreMedia
import XCTest

@objcMembers final class RecordingCadenceConformerChecks: XCTestCase {
  private func t(_ n: Int64) -> CMTime { CMTime(value: n, timescale: 1000) }
  func testJitterDenseAndSparseUseCausalWholeFrames() throws {
    var c = try RecordingCadenceConformer<String>(frameDuration: t(40))
    XCTAssertTrue(try c.append(frame: "A", pts: t(5000), duration: t(40)).isEmpty)
    XCTAssertEqual(try c.append(frame: "B", pts: t(5010), duration: t(40)).map(\.frame), ["A"])
    XCTAssertTrue(try c.append(frame: "C", pts: t(5020), duration: t(100)).isEmpty)
    let tail = try c.finish()
    XCTAssertEqual(tail.map(\.frame), ["C", "C"])
    XCTAssertEqual(tail.map { $0.presentationTime.value }, [40, 80])
    XCTAssertEqual(c.statistics.skipped, 1)
    XCTAssertEqual(c.statistics.repeated, 1)
    XCTAssertTrue(try c.finish().isEmpty)
  }
  func testRefusedGapDoesNotConsumePendingFrame() throws {
    var c = try RecordingCadenceConformer<Int>(frameDuration: t(40), maximumGapDuration: t(100), maximumJobs: 2)
    _ = try c.append(frame: 1, pts: t(1000), duration: t(40))
    XCTAssertThrowsError(try c.append(frame: 2, pts: t(2000), duration: t(40)))
    XCTAssertEqual(c.statistics.emitted, 0)
    XCTAssertEqual(try c.finish().map(\.frame), [1])
  }
  func testPauseReanchorsOnCommonGrid() throws {
    var c = try RecordingCadenceConformer<Int>(frameDuration: t(40))
    _ = try c.append(frame: 1, pts: t(1000), duration: t(40))
    XCTAssertEqual(try c.reanchor().count, 1)
    _ = try c.append(frame: 2, pts: .zero, duration: t(40))
    XCTAssertEqual(try c.finish().first?.presentationTime.value, 40)
  }
  func testLastDenseFrameCanBeSkippedWithoutExtendingTail() throws {
    var c = try RecordingCadenceConformer<Int>(frameDuration: t(40))
    _ = try c.append(frame: 1, pts: .zero, duration: t(1))
    _ = try c.append(frame: 2, pts: t(1), duration: t(1))
    XCTAssertTrue(try c.finish().isEmpty)
    XCTAssertEqual(c.statistics.skipped, 1)
  }
  func testFractionalCadenceUsesAbsoluteIntegerGrid() throws {
    let cadence = CMTime(value: 1001, timescale: 30000)
    var c = try RecordingCadenceConformer<Int>(frameDuration: cadence)
    _ = try c.append(frame: 1, pts: t(9000), duration: cadence)
    let outputs = try c.append(frame: 2, pts: t(10000), duration: cadence)
    XCTAssertEqual(outputs.count, 30)
    for (index, output) in outputs.enumerated() {
      XCTAssertEqual(CMTimeCompare(output.presentationTime,
        CMTime(value: Int64(index) * 1001, timescale: 30000)), 0)
    }
  }

  func testJobCapIsIndependentOfGapDuration() throws {
    var c = try RecordingCadenceConformer<Int>(frameDuration: t(1), maximumGapDuration: t(10000), maximumJobs: 2)
    _ = try c.append(frame: 1, pts: .zero, duration: t(1))
    XCTAssertThrowsError(try c.append(frame: 2, pts: t(3), duration: t(1)))
    XCTAssertEqual(c.statistics.emitted, 0)
    XCTAssertEqual(try c.finish().count, 1)
  }
  func testFinishRefusesExcessiveTailAtomically() throws {
    var c = try RecordingCadenceConformer<Int>(frameDuration: t(40), maximumGapDuration: t(100))
    _ = try c.append(frame: 1, pts: .zero, duration: t(1000))
    XCTAssertThrowsError(try c.finish())
    XCTAssertEqual(c.statistics.emitted, 0)
    XCTAssertEqual(try c.append(frame: 2, pts: t(40), duration: t(40)).count, 1)
    XCTAssertEqual(try c.finish().count, 1)
  }
  func testInvalidTimestampRefusalPreservesSelection() throws {
    var c = try RecordingCadenceConformer<Int>(frameDuration: t(40))
    _ = try c.append(frame: 1, pts: t(100), duration: t(40))
    XCTAssertThrowsError(try c.append(frame: 2, pts: .invalid, duration: t(40)))
    XCTAssertThrowsError(try c.append(frame: 2, pts: t(99), duration: t(40)))
    XCTAssertEqual(try c.finish().map(\.frame), [1])
  }

  func testFractionalSourceEndNeverAddsRoundedRepeat() throws {
    for scale: Int32 in [2147483639, 2147483629] {
      for value: Int64 in [1, -1, 100000000000] {
        var c = try RecordingCadenceConformer<Int>(frameDuration: CMTime(value: 1, timescale: 30))
        _ = try c.append(frame: 1, pts: CMTime(value: value, timescale: scale), duration: CMTime(value: 1, timescale: 30))
        XCTAssertEqual(try c.finish().count, 1)
      }
    }
  }
  func testReanchorOverflowDoesNotCommitFinish() throws {
    let duration = CMTime(value: Int64.max / 2 + 1, timescale: 1)
    var c = try RecordingCadenceConformer<Int>(frameDuration: duration, maximumGapDuration: CMTime(value: Int64.max, timescale: 1))
    _ = try c.append(frame: 1, pts: .zero, duration: CMTime(value: Int64.max, timescale: 1))
    XCTAssertThrowsError(try c.reanchor())
    XCTAssertEqual(c.statistics.emitted, 0)
    XCTAssertEqual(try c.finish().count, 2)
  }

}
