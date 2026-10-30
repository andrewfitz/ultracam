import CoreMedia
import CoreVideo
import Foundation
import XCTest

@objcMembers final class ProgramCadenceCPUChecks: XCTestCase {
  func testLowRateSchedulesAreCompactAndPacedAt60And120Hz() throws {
    for rate in [60, 120] {
      for seconds in [1, 2] {
        let rig = try CadenceRig(rate: rate)
        rig.send(index: 0, duration: CMTime(value: Int64(seconds), timescale: 1))
        rig.bridge.waitUntilIdle()
        XCTAssertEqual(rig.sent.count, 1, "The initial frame cannot burst its whole repeat window into CMIO")
        XCTAssertEqual(rig.route.statistics.overflowRejected, 0)
        XCTAssertEqual(rig.route.statistics.published, UInt64(seconds * rate))
        XCTAssertEqual(rig.route.stageAllocationSnapshot.allocations, 1)
        for index in 1..<(seconds * rate) { rig.advance(to: Double(index) / Double(rate)) }
        XCTAssertEqual(rig.sent.count, seconds * rate)
        XCTAssertEqual(rig.bridge.currentStatistics.dropped, 0)
        XCTAssertEqual(rig.bridge.currentStatistics.clockSkipped, 0)
        XCTAssertEqual(rig.bridge.currentStatistics.clockRepeated, 0)
        for (index, time) in rig.sent.enumerated() { XCTAssertEqual(time, Double(index) / Double(rate), accuracy: 1e-8) }
        XCTAssertLessThanOrEqual(rig.consumer.pendingCount, 1)
        XCTAssertEqual(rig.route.stageRetentionSnapshot.currentSlots, 1, "The schedule stays charged through the final paced send")
        XCTAssertEqual(rig.route.stageRetentionSnapshot.currentDuration, Double(seconds), accuracy: 1e-12,
          "One low-rate image uses the explicit minimum-slot exception, not a globally enlarged time budget")
        rig.bridge.disconnect()
        XCTAssertEqual(rig.route.stageRetentionSnapshot.currentSlots, 0)
      }
    }
  }

  func testHostGridBoundsTenMinutesOfPositiveAndNegativeClockDrift() throws {
    for speed in [1.001, 0.999] {
      let rate = 60
      let rig = try CadenceRig(rate: rate)
      let samples = Int(600 * Double(rate) * speed)
      for index in 0..<samples {
        let arrival = Double(index) / (Double(rate) * speed)
        rig.advance(to: arrival)
        rig.send(index: index)
        rig.bridge.waitUntilIdle()
      }
      rig.advance(to: 600 - 1 / Double(rate))
      XCTAssertGreaterThan(rig.sent.count, 35_990)
      XCTAssertEqual(rig.route.statistics.overflowRejected, 0)
      XCTAssertEqual(rig.bridge.currentStatistics.dropped, 0)
      for index in 1..<rig.sent.count {
        XCTAssertEqual(rig.sent[index] - rig.sent[index - 1], 1 / Double(rate), accuracy: 1e-8)
      }
      XCTAssertLessThanOrEqual(rig.maximumLead, 1 / Double(rate) + 1e-8)
      if speed > 1 { XCTAssertGreaterThan(rig.bridge.currentStatistics.clockSkipped, 25) }
      else { XCTAssertGreaterThan(rig.bridge.currentStatistics.clockRepeated, 25) }
      rig.bridge.disconnect()
      XCTAssertEqual(rig.route.stageRetentionSnapshot.currentSlots, 0)
    }
  }

  func testResetAndTopologyChangesFenceTheCurrentRepeatSchedule() throws {
    for topologyChange in [false, true] {
      let rig = try CadenceRig(rate: 60)
      rig.send(index: 0, duration: CMTime(value: 2, timescale: 1))
      rig.bridge.waitUntilIdle()
      XCTAssertEqual(rig.sent.count, 1)
      if topologyChange { rig.route.updateFeeds([FeedID(rawValue: "replacement")]) }
      else { rig.route.reset() }
      rig.advance(to: 0.5)
      XCTAssertEqual(rig.sent.count, 1, "Retired source images must not survive an output generation change")
      XCTAssertEqual(rig.route.stageRetentionSnapshot.currentSlots, 0)
      XCTAssertEqual(rig.route.stageAllocationSnapshot.bytes, 0)
      rig.bridge.disconnect()
    }
  }

  func testMissedWakeConsumesScheduleAndExpiredImageCannotResume() throws {
    let rig = try CadenceRig(rate: 60)
    rig.send(index: 0, duration: CMTime(value: 2, timescale: 1))
    rig.bridge.waitUntilIdle()
    rig.jump(to: 1)
    rig.advance(to: 119.0 / 60)
    XCTAssertEqual(rig.sent.count, 61)
    XCTAssertEqual(rig.bridge.currentStatistics.clockSkipped, 59)
    XCTAssertEqual(rig.sent[1], 1, accuracy: 1e-8)
    rig.bridge.disconnect()

    let expired = try CadenceRig(rate: 60)
    expired.send(index: 0, duration: CMTime(value: 2, timescale: 1))
    expired.bridge.waitUntilIdle()
    expired.jump(to: 5)
    expired.advance(to: 6)
    XCTAssertEqual(expired.sent.count, 1, "A queued two-second schedule expires even with repeats remaining")
    XCTAssertEqual(expired.bridge.currentStatistics.clockSkipped, 119)
    XCTAssertEqual(expired.bridge.currentStatistics.pacingDiscontinuities, 1)
    XCTAssertEqual(expired.route.stageAllocationSnapshot.bytes, 0)
    expired.bridge.disconnect()
  }

  func testPendingMediaTimeIsBoundedEquallyAt25And120Hz() throws {
    for rate in [25, 120] {
      let image = try cadenceImage()
      let route = ProgramOutputRoute(feedIDs: [FeedID(rawValue: "held")])
      let consumer = try route.addConsumerRoute(capacity: 128, compactRepeats: true)
      for index in 0..<(rate / 2) {
        route.ingest(feedID: FeedID(rawValue: "held"), frame: ProcessedFrame(payload: image,
          metadata: ProcessedFrameMetadata(presentationTime: CMTime(value: Int64(index), timescale: Int32(rate)),
            duration: CMTime(value: 1, timescale: Int32(rate)), width: 2, height: 2,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)))
      }
      XCTAssertEqual(consumer.pendingCount, Int(0.4 * Double(rate)))
      XCTAssertEqual(route.stageRetentionSnapshot.currentDuration, 0.4, accuracy: 1e-12)
      XCTAssertEqual(route.stageAllocationSnapshot.allocations, 1, "Repeated ownership of one backing is physically charged once")
      XCTAssertEqual(route.stageAllocationSnapshot.bytes, try ProgramOutputRoute.storageBytes(image))
      route.reset()
      XCTAssertEqual(route.stageRetentionSnapshot.currentSlots, 0)
    }
  }

  func testFanoutAndInFlightOwnersRemainByteAndTimeCharged() throws {
    for rate in [25, 120] {
      let image = try cadenceImage()
      let bytes = try ProgramOutputRoute.storageBytes(image)
      let budget = try MediaRetentionPolicy(maximumBytes: bytes * 3, maximumDuration: 0.4, maximumSlots: 256, minimumSlots: 2)
      let id = FeedID(rawValue: "held")
      let route = ProgramOutputRoute(feedIDs: [id], retentionPolicy: budget)
      let consumer = try route.addConsumerRoute(capacity: 128, compactRepeats: true)
      let step = CMTime(value: 1, timescale: Int32(rate))
      route.setOutput(contract: ProgramOutputFormat(width: 2, height: 2,
        pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, duration: step), active: true)
      for index in 0..<10 {
        let payload = index == 0 ? image : try cadenceImage()
        route.ingest(feedID: id, frame: ProcessedFrame(payload: payload, metadata: ProcessedFrameMetadata(
          presentationTime: CMTime(value: Int64(index), timescale: Int32(rate)), duration: step,
          width: 2, height: 2, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)))
      }
      XCTAssertEqual(consumer.pendingCount, 3)
      XCTAssertEqual(route.stageRetentionSnapshot.currentSlots, 3)
      XCTAssertEqual(route.stageAllocationSnapshot.bytes, bytes * 3)
      XCTAssertGreaterThan(route.statistics.overflowRejected, 0)
      let inFlight = try XCTUnwrap(consumer.dequeue())
      route.reset()
      XCTAssertEqual(route.stageAllocationSnapshot.bytes, bytes, "Reset only releases pending leases; an in-flight send still owns its surface")
      XCTAssertEqual(route.stageRetentionSnapshot.currentSlots, 1)
      inFlight.release()
      XCTAssertEqual(route.stageAllocationSnapshot.bytes, 0)
      XCTAssertEqual(route.stageRetentionSnapshot.currentSlots, 0)
    }
  }
}

private func cadenceImage() throws -> CVPixelBuffer {
  var image: CVPixelBuffer?
  guard CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image) == kCVReturnSuccess, let image else {
    throw VideoError.message("CPU timing fixture allocation failed")
  }
  try ProgramOutputFormat(width: 2, height: 2, pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    duration: CMTime(value: 1, timescale: 60)).stampColour(on: image)
  return image
}

private final class CadenceRig: @unchecked Sendable {
  let route: ProgramOutputRoute
  let consumer: FrameRoute<CVPixelBuffer>
  let image: CVPixelBuffer
  let rate: Int
  var bridge: ProgramOutputBridge!
  private let lock = NSLock()
  private var time = 0.0
  private var wakes: [(Double, @Sendable () -> Void)] = []
  private var timestamps: [Double] = []
  private var lead = 0.0
  var sent: [Double] { lock.withLock { timestamps } }
  var maximumLead: Double { lock.withLock { lead } }
  init(rate: Int) throws {
    self.rate = rate
    image = try cadenceImage()
    route = ProgramOutputRoute(feedIDs: [FeedID(rawValue: "paced")])
    let baseline = ProcessInfo.processInfo.environment["ULTRACAM_CADENCE_BASELINE"] == "1"
    consumer = try route.addConsumerRoute(capacity: ProgramOutputRoute.consumerCapacity, compactRepeats: !baseline)
    bridge = ProgramOutputBridge(route: consumer, connect: { _, _ in }, disconnect: {}, send: { [weak self] sample in
      guard let self else { return false }
      self.lock.withLock {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        self.timestamps.append(pts)
        self.lead = max(self.lead, pts - self.time)
      }
      return true
    }, hostClock: { [weak self] in
      let seconds = self?.lock.withLock { self?.time ?? 0 } ?? 0
      return CMTime(value: Int64((seconds * 240_000_000).rounded()), timescale: 240_000_000)
    },
      paced: !baseline, scheduleHostWake: { [weak self] deadline, callback in
        self?.lock.withLock { self?.wakes.append((deadline.seconds, callback)) }
      })
    route.onPublished = { [weak bridge] in bridge?.schedulePump() }
    bridge.onContractChange = { [weak route] contract in route?.setOutput(contract: contract, active: contract != nil) }
    bridge.enforceContract = true
    var configuration = PipelineConfiguration()
    configuration.downscale = false; configuration.convertTo420 = false
    configuration.sourceWidth = 2; configuration.sourceHeight = 2
    configuration.sourceDuration = CMTime(value: 1, timescale: Int32(rate))
    try bridge.setDemand(true, configuration: configuration, passthroughFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    bridge.waitUntilIdle()
  }
  func send(index: Int, duration: CMTime? = nil) {
    route.ingest(feedID: FeedID(rawValue: "paced"), frame: ProcessedFrame(payload: image,
      metadata: ProcessedFrameMetadata(presentationTime: CMTime(value: Int64(index), timescale: Int32(rate)),
        duration: duration ?? CMTime(value: 1, timescale: Int32(rate)), width: 2, height: 2,
        pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)))
  }
  func jump(to target: Double) {
    let wake = lock.withLock { () -> (@Sendable () -> Void)? in
      time = target
      wakes.sort { $0.0 < $1.0 }
      guard let first = wakes.first, first.0 <= target else { return nil }
      wakes.removeFirst()
      return first.1
    }
    wake?()
    bridge.waitUntilIdle()
  }
  func advance(to target: Double) {
    var iterations = 0
    while true {
      iterations += 1
      precondition(iterations < 1000, "Pacer rescheduled an already due deadline at target \(target)")
      let wake = lock.withLock { () -> (@Sendable () -> Void)? in
        wakes.sort { $0.0 < $1.0 }
        guard let first = wakes.first, first.0 <= target + 1e-10 else { time = target; return nil }
        wakes.removeFirst(); time = first.0
        return first.1
      }
      guard let wake else { break }
      wake()
      bridge.waitUntilIdle()
    }
    bridge.pump()
  }
}
