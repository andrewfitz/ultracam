// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Darwin
import Foundation
import MonitorKitAudio
import Synchronization
import XCTest

/// Third audit round: regressions for the audio module's fixes.
final class Audit3AudioTests: XCTestCase {
  /// The first `process` call of each entry point on a fresh meter allocates
  /// nothing, in unoptimized builds too. `process(bufferList:)` used to
  /// instantiate a key path and generic metadata on its first call (18
  /// allocations on the audio thread). Metadata and key paths are cached
  /// process-wide, so this only catches a regression when it is the first
  /// bufferList call in the process (run alone); in a full suite it is weak.
  /// One allocation of exactly the Swift runtime's metadata page is tolerated
  /// per call: any first use of any type can make the runtime's metadata pool
  /// take a new page, so whether one lands here depends on what ran before (it
  /// did on CI runners, where the GPU tests skip). Every other allocation fails.
  func testFirstProcessCallsDoNotAllocate() throws {
    guard AllocationCounter.allocations({ _ = [Int](repeating: 1, count: Int.random(in: 1000...2000)) }) ?? 0 > 0 else {
      throw XCTSkip("malloc_logger is not honoured on this system")
    }
    let fs = 48000.0
    let frames = 300
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fs, channels: 2, interleaved: true)!
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    pcm.frameLength = 512
    let list = pcm.audioBufferList
    let block = PlanarBlock(channelCount: 2, capacity: 512)
    let readOnly = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: 2)
    defer { readOnly.deallocate() }
    readOnly[0] = UnsafePointer(block.pointers[0])
    readOnly[1] = UnsafePointer(block.pointers[1])
    let int16 = [Int16](repeating: 100, count: 1024)
    let int32 = [Int32](repeating: 100, count: 1024)
    let float = [Float](repeating: 0.1, count: 1024)
    let planar16 = UnsafeMutablePointer<UnsafeMutablePointer<Int16>>.allocate(capacity: 2)
    let planar32 = UnsafeMutablePointer<UnsafeMutablePointer<Int32>>.allocate(capacity: 2)
    let storage16 = UnsafeMutablePointer<Int16>.allocate(capacity: 1024)
    let storage32 = UnsafeMutablePointer<Int32>.allocate(capacity: 1024)
    defer {
      planar16.deallocate()
      planar32.deallocate()
      storage16.deallocate()
      storage32.deallocate()
    }
    storage16.initialize(repeating: 100, count: 1024)
    storage32.initialize(repeating: 100, count: 1024)
    planar16[0] = storage16
    planar16[1] = storage16 + 512
    planar32[0] = storage32
    planar32[1] = storage32 + 512

    // Every meter is made before counting; each call below is its meter's first.
    var meters: [AudioMeter] = []
    for _ in 0..<9 { meters.append(try AudioMeter(sampleRate: fs, channelCount: 2)) }
    let loudnessList = try LoudnessMeter(sampleRate: fs, channelCount: 2)
    let loudnessPlanar = try LoudnessMeter(sampleRate: fs, channelCount: 2)
    let counts: [Int] = try int16.withUnsafeBufferPointer { i16 in
      try int32.withUnsafeBufferPointer { i32 in
        try float.withUnsafeBufferPointer { f in
          [
            try XCTUnwrap(AllocationSizes.unexplained {
              meters[0].process(bufferList: list, frameCount: frames, format: .float32)
            }),
            try XCTUnwrap(AllocationSizes.unexplained {
              loudnessList.process(bufferList: list, frameCount: frames, format: .float32)
            }),
            try XCTUnwrap(AllocationSizes.unexplained { meters[1].process(planar: block.pointers, frameCount: frames) }),
            try XCTUnwrap(AllocationSizes.unexplained { meters[2].process(planar: UnsafePointer(readOnly), frameCount: frames) }),
            try XCTUnwrap(AllocationSizes.unexplained { meters[3].process(planar: UnsafePointer(planar16), frameCount: frames) }),
            try XCTUnwrap(AllocationSizes.unexplained { meters[4].process(planar: UnsafePointer(planar32), frameCount: frames) }),
            try XCTUnwrap(AllocationSizes.unexplained { meters[5].process(interleaved: f.baseAddress!, frameCount: frames) }),
            try XCTUnwrap(AllocationSizes.unexplained { meters[6].process(interleaved: i16.baseAddress!, frameCount: frames) }),
            try XCTUnwrap(AllocationSizes.unexplained { meters[7].process(interleaved: i32.baseAddress!, frameCount: frames) }),
            try XCTUnwrap(AllocationSizes.unexplained {
              meters[8].restart()
              meters[8].process(planar: block.pointers, frameCount: 1)
              meters[8].flush()
              _ = meters[8].snapshot()
            }),
            try XCTUnwrap(AllocationSizes.unexplained {
              loudnessPlanar.process(planar: block.pointers, frameCount: frames)
              _ = loudnessPlanar.snapshot()
            }),
          ]
        }
      }
    }
    XCTAssertEqual(
      counts, [Int](repeating: 0, count: counts.count),
      "first-call allocations per entry point: \(AllocationSizes.log)")
  }

  /// A zero-width scale (equal bounds, e.g. `digitalPeak(range: 0...0)`) or an
  /// infinite one divided 0 by 0 or inf by inf, and `position(of:)` returned
  /// NaN instead of a clamped position.
  func testDegenerateScalePositionsAreNotNaN() {
    let point = MeterScale.digitalPeak(range: 0...0)
    XCTAssertEqual(point.position(of: 0), 0)
    XCTAssertEqual(point.position(of: 1), 1)
    XCTAssertEqual(point.position(of: -1), 0)
    XCTAssertEqual(point.layout(level: 0, hold: 0).bar, 0)
    let infinite = MeterScale(
      unit: .dBFS, lowerBound: -60, upperBound: .infinity, mapping: .amplitude, marks: [], zones: [])
    XCTAssertEqual(infinite.position(of: .infinity), 0)
    let flat = MeterScale(unit: .dBFS, lowerBound: -10, upperBound: -10, marks: [], zones: [])
    XCTAssertEqual(flat.position(forReading: -10), 0)
  }

  /// `channelCount` is public, so a host can build a snapshot that claims
  /// more channels than the 16 slots hold; `isOver`, the true-peak maxima and
  /// `peakSummary` looped to it and trapped on slot 16 (the cross-module report
  /// came from LevelMeterView(snapshot:)).
  func testOversizedChannelCountStaysInsideTheStorage() {
    var s = AudioMeterSnapshot()
    s.channelCount = 40
    s.programmeChannelMask = .max
    // Nothing set: every loop runs to the end, where the old code trapped.
    XCTAssertFalse(s.isOver())
    XCTAssertEqual(s.maximumTruePeak, -.infinity)
    s.channels[3].truePeakMax = -0.5
    XCTAssertTrue(s.isOver())
    XCTAssertEqual(s.maximumTruePeak, -0.5)
    XCTAssertEqual(s.programmeMaximumTruePeak, -0.5)
    XCTAssertFalse(MeterText.peakSummary(s, channels: 40).isEmpty)
    s.channelCount = -3
    XCTAssertFalse(s.isOver())
    XCTAssertEqual(s.maximumTruePeak, -.infinity)
    XCTAssertEqual(MeterText.peakSummary(s, channels: 2), "no reading")
  }

  /// The clip count saturates instead of wrapping: a channel stuck at full
  /// scale used to read 2^20 here after 2^32 + 2^20 clipped samples.
  func testClipCountSaturates() throws {
    let meter = try AudioMeter(configuration: .init(sampleRate: 768_000, channelCount: 1, meters: []))
    let frames = 1 << 20
    let block = PlanarBlock(channelCount: 1, capacity: frames)
    block.pointers[0].update(repeating: 1, count: frames)
    var total: UInt64 = 0
    while total <= UInt64(UInt32.max) {
      meter.process(planar: block.pointers, frameCount: frames)
      total += UInt64(frames)
    }
    meter.flush()
    XCTAssertEqual(meter.snapshot()[0].clipCount, UInt32.max)
    XCTAssertTrue(meter.snapshot()[0].isOver())
    meter.resetPeaks()
    meter.flush()
    XCTAssertEqual(meter.snapshot()[0].clipCount, 0)
  }

  /// Coverage for the audit, not a fix: the readings that do not depend on
  /// publish timing come out the same whatever the callback sizes (0, 1,
  /// odd, chunk-boundary and long calls), at every true-peak / PPM path.
  func testReadingsDoNotDependOnCallbackPartition() throws {
    for fs in [44100.0, 48000, 96000, 192_000, 352_800, 768_000] {
      let frames = Int(fs * 3.2)
      let a = Signal.noise(amplitude: 0.7, frames: frames, seed: 1)
      let b = Signal.noise(amplitude: 0.7, frames: frames, seed: 2)
      let mixed = zip(a, b).map { 0.6 * $0 + 0.4 * $1 }
      let s = Signal(sampleRate: fs, channels: [a, mixed, b])
      let whole = try AudioMeter(sampleRate: fs, channelCount: 3)
      let pieces = try AudioMeter(sampleRate: fs, channelCount: 3)
      feed(whole, s, sizes: [4096])
      feed(pieces, s, sizes: [1, 0, 7, 255, 256, 257, 1000, 3])
      let x = whole.snapshot()
      let y = pieces.snapshot()
      for c in 0..<3 {
        XCTAssertEqual(x[c].truePeakMax, y[c].truePeakMax, accuracy: 1e-5, "true-peak max at \(fs)")
        XCTAssertEqual(x[c].clipCount, y[c].clipCount, "clips at \(fs)")
        XCTAssertEqual(x[c].rms, y[c].rms, accuracy: 1e-4, "RMS at \(fs)")
        XCTAssertEqual(x[c].vu, y[c].vu, accuracy: 1e-3, "VU at \(fs)")
      }
      XCTAssertEqual(x.loudness.integrated, y.loudness.integrated, accuracy: 1e-4, "I at \(fs)")
      XCTAssertEqual(x.loudness.momentary, y.loudness.momentary, accuracy: 1e-4, "M at \(fs)")
      XCTAssertEqual(x.loudness.shortTerm, y.loudness.shortTerm, accuracy: 1e-4, "S at \(fs)")
      XCTAssertEqual(x.correlation, y.correlation, accuracy: 1e-5, "correlation at \(fs)")
      XCTAssertEqual(x.frameCount, y.frameCount)
    }
  }

  private func feed(_ meter: AudioMeter, _ signal: Signal, sizes: [Int]) {
    let block = PlanarBlock(channelCount: signal.channels.count, capacity: 4096)
    var offset = 0
    var k = 0
    while offset < signal.frameCount {
      let n = min(sizes[k % sizes.count], signal.frameCount - offset)
      k += 1
      block.fill(from: signal, offset: offset, count: n)
      meter.process(planar: block.pointers, frameCount: n)
      offset += n
    }
    meter.flush()
  }
}

/// Records the size of each heap allocation made on this thread, through the
/// same `malloc_logger` hook as `AllocationCounter`.
enum AllocationSizes {
  static let capacity = 64
  static let depth = 24
  nonisolated(unsafe) static let sizes = UnsafeMutablePointer<Int>.allocate(capacity: capacity)
  nonisolated(unsafe) static let frames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(
    capacity: capacity * depth)
  nonisolated(unsafe) static let frameCounts = UnsafeMutablePointer<Int32>.allocate(capacity: capacity)
  static let count = Atomic<Int>(0)
  static let thread = Atomic<UInt>(0)
  /// Each call's allocations other than a metadata page, with their stacks.
  nonisolated(unsafe) static var log: [String] = []
  static let logger: AllocationCounter.Logger = { type, _, arg2, arg3, _, _ in
    // stack_logging_type_alloc; realloc reports alloc | dealloc with its size third.
    guard type & 2 != 0 else { return }
    guard AllocationSizes.thread.load(ordering: .relaxed) == UInt(bitPattern: pthread_self()) else { return }
    let index = AllocationSizes.count.add(1, ordering: .relaxed).oldValue
    guard index < AllocationSizes.capacity else { return }
    AllocationSizes.sizes[index] = Int(type & 4 != 0 ? arg3 : arg2)
    // backtrace(3) walks frame pointers and does not allocate.
    AllocationSizes.frameCounts[index] = backtrace(
      AllocationSizes.frames + index * AllocationSizes.depth, Int32(AllocationSizes.depth))
  }
  /// `swift_debug_metadataAllocatorPageSize`: the size of each page the
  /// runtime's metadata allocator takes from malloc.
  static let metadataPageSize: Int? = dlsym(
    UnsafeMutableRawPointer(bitPattern: -2), "_swift_debug_metadataAllocatorPageSize"
  ).map { $0.load(as: Int.self) }

  /// Allocations made by `body`, less at most one runtime metadata page; nil
  /// when the hook is unavailable.
  static func unexplained(_ body: () -> Void) -> Int? {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
    let slot = symbol.assumingMemoryBound(to: AllocationCounter.Logger?.self)
    // Touch the statics first so their lazy initialization does not run inside the hook.
    _ = logger
    _ = (sizes, frames, frameCounts, capacity, depth)
    let page = metadataPageSize
    count.store(0, ordering: .relaxed)
    thread.store(UInt(bitPattern: pthread_self()), ordering: .relaxed)
    let previous = slot.pointee
    slot.pointee = logger
    body()
    slot.pointee = previous
    thread.store(0, ordering: .relaxed)
    let total = count.load(ordering: .relaxed)
    var pages = 0
    var report: [String] = []
    for index in 0..<min(total, capacity) {
      if pages == 0, sizes[index] == page {
        pages = 1
        continue
      }
      report.append("\(sizes[index]) B at " + stack(index))
    }
    log.append(report.isEmpty ? "none" : report.joined(separator: "; "))
    return total - pages
  }

  /// The recorded stack of allocation `index`, as image`symbol+offset frames.
  static func stack(_ index: Int) -> String {
    var parts: [String] = []
    for frame in 0..<Int(frameCounts[index]) {
      guard let address = frames[index * depth + frame] else { continue }
      var info = Dl_info()
      guard dladdr(address, &info) != 0 else {
        parts.append("\(address)")
        continue
      }
      var image = "?"
      if let path = info.dli_fname { image = String(String(cString: path).split(separator: "/").last ?? "?") }
      var name = "?"
      if let symbol = info.dli_sname { name = String(cString: symbol) }
      var offset = 0
      if let base = info.dli_saddr { offset = Int(bitPattern: address) - Int(bitPattern: base) }
      parts.append(image + "`" + name + "+" + String(offset))
    }
    return parts.joined(separator: " < ")
  }
}
