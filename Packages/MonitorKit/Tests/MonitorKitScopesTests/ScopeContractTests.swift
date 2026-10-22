import Darwin
import Foundation
import Metal
import MonitorKit
import MonitorKitCore
import Synchronization
import XCTest

@testable import MonitorKitScopes

/// Counts heap allocations made on the calling thread, through libmalloc's
/// logger hook (the same harness as MonitorKitTests).
enum AllocationCounter {
  typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
  nonisolated(unsafe) static var count = 0
  nonisolated(unsafe) static var thread: pthread_t?
  nonisolated(unsafe) static let slot: UnsafeMutablePointer<Logger?>? = dlsym(
    UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger"
  ).map { $0.assumingMemoryBound(to: Logger?.self) }

  /// Allocations made by `body` on this thread, or nil when the hook is unavailable.
  static func measure(_ body: () throws -> Void) rethrows -> Int? {
    guard let slot, slot.pointee == nil else {
      try body()
      return nil
    }
    count = 0
    thread = pthread_self()
    slot.pointee = { type, _, _, _, _, _ in
      // MALLOC_LOG_TYPE_ALLOCATE
      if type & 2 != 0, let t = AllocationCounter.thread, pthread_equal(pthread_self(), t) != 0 {
        AllocationCounter.count += 1
      }
    }
    defer {
      slot.pointee = nil
      thread = nil
    }
    try body()
    return count
  }
}

/// The zero-overhead contract: encode only, borrowed inputs, no per-frame allocation.
final class ScopeContractTests: XCTestCase {
  func testEncodingNeverCommits() throws {
    let (device, queue, engine) = try GPU.require()
    let frame = try TestFrame.natural(.v210, width: 320, height: 180, mirror: false)
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 256, height: 128, mipmapped: false)
    d.usage = .renderTarget
    d.storageMode = .private
    let target = try XCTUnwrap(device.makeTexture(descriptor: d))
    for kind in ScopeKind.allCases {
      let accumulator = try engine.makeAccumulator(settings: ScopeSettings(kind: kind))
      let renderer = engine.makeRenderer()
      let cb = try XCTUnwrap(queue.makeCommandBuffer())
      try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
      try renderer.render(accumulator, target: target, into: cb)
      XCTAssertEqual(cb.status, .notEnqueued, "\(kind): the host commits")
      cb.commit()
      cb.waitUntilCompleted()
      XCTAssertEqual(cb.status, .completed)
    }
  }

  func testSharedComputeEncoderAndConcurrentDispatch() throws {
    let (_, queue, engine) = try GPU.require()
    let frame = try TestFrame.natural(.bgra8, width: 200, height: 100, seed: 3)
    let accumulators = try ScopeKind.allCases.map { try engine.makeAccumulator(settings: ScopeSettings(kind: $0, stage: .source)) }
    var expected: [[UInt32]] = []
    for a in accumulators {
      try GPU.run { cb in try a.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
      expected.append(try readBins(a))
    }
    for type in [MTLDispatchType.serial, .concurrent] {
      let cb = try XCTUnwrap(queue.makeCommandBuffer())
      let encoder = try XCTUnwrap(cb.makeComputeCommandEncoder(dispatchType: type))
      // Twice into one encoder: the second clear must wait for the first finalize.
      for _ in 0..<2 {
        for a in accumulators { try a.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, using: encoder) }
      }
      encoder.endEncoding()
      cb.commit()
      cb.waitUntilCompleted()
      for (a, bins) in zip(accumulators, expected) {
        XCTAssertEqual(try readBins(a), bins, "\(a.settings.kind) in a shared \(type) encoder")
      }
    }
  }

  static func heapInUse() -> Int {
    var stats = malloc_statistics_t()
    malloc_zone_statistics(nil, &stats)
    return stats.size_in_use
  }

  /// 100 accumulations and draws after warm-up: no GPU or CPU memory growth
  /// and no resource churn.
  func testNoAllocationGrowthOver100Accumulations() throws {
    let (device, queue, engine) = try GPU.require()
    let frame = try TestFrame.natural(.v210, width: 1920, height: 1080, mirror: false)
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1024, height: 512, mipmapped: false)
    d.usage = .renderTarget
    d.storageMode = .private
    let target = try XCTUnwrap(device.makeTexture(descriptor: d))
    var waveform = ScopeSettings(kind: .waveform)
    waveform.waveformMode = .rgbParade
    let scopes = try [waveform, ScopeSettings(kind: .vectorscope), ScopeSettings(kind: .histogram)].map {
      try engine.makeAccumulator(settings: $0)
    }
    let renderers = scopes.map { _ in engine.makeRenderer() }
    func cycle() throws {
      try autoreleasepool {
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        for (a, r) in zip(scopes, renderers) {
          try a.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
          try r.render(a, target: target, viewport: MonitorViewport(width: 1024, height: 512), into: cb)
        }
        cb.commit()
        cb.waitUntilCompleted()
      }
    }
    for _ in 0..<10 { try cycle() }
    let bins = scopes.map { ObjectIdentifier($0.bins) }
    let gpuBefore = device.currentAllocatedSize
    let heapBefore = Self.heapInUse()
    for _ in 0..<100 { try cycle() }
    XCTAssertEqual(scopes.map { ObjectIdentifier($0.bins) }, bins, "bins are persistent")
    XCTAssertEqual(device.currentAllocatedSize, gpuBefore, "no GPU allocation")
    let growth = Self.heapInUse() - heapBefore
    // Metal's debug layer keeps per-encoder records of its own.
    if ProcessInfo.processInfo.environment["MTL_DEBUG_LAYER"].map({ $0 != "0" }) ?? false { return }
    XCTAssertLessThan(growth, 64 * 1024, "no CPU heap growth (measured \(growth) bytes)")
  }

  /// CPU cost of encoding one accumulation plus one draw, after warm-up. The
  /// minimum is reported alongside the median because other processes share
  /// the dev machine's cores.
  func testEncodeCPUCost() throws {
    try skipTimingUnderValidation()
    let (device, queue, engine) = try GPU.require()
    let frame = try TestFrame.natural(.v210, width: 1920, height: 1080, mirror: false)
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1024, height: 512, mipmapped: false)
    d.usage = .renderTarget
    d.storageMode = .private
    let target = try XCTUnwrap(device.makeTexture(descriptor: d))
    let accumulator = try engine.makeAccumulator(settings: ScopeSettings(kind: .waveform))
    let renderer = engine.makeRenderer()
    let t = try remeasured("classic CPU encode") { () throws -> (accumulate: Double, render: Double) in
      var accumulate: [Double] = [], render: [Double] = []
      for i in 0..<220 {
        try autoreleasepool {
          let cb = try XCTUnwrap(queue.makeCommandBuffer())
          let t0 = DispatchTime.now().uptimeNanoseconds
          try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
          let t1 = DispatchTime.now().uptimeNanoseconds
          try renderer.render(accumulator, target: target, into: cb)
          let t2 = DispatchTime.now().uptimeNanoseconds
          if i >= 20 {
            accumulate.append(Double(t1 - t0) / 1000)
            render.append(Double(t2 - t1) / 1000)
          }
          cb.commit()
          if i % 50 == 0 { cb.waitUntilCompleted() }
        }
      }
      accumulate.sort()
      render.sort()
      print(
        String(
          format: "CPU encode (debug build): accumulate min %.1f / median %.1f µs, render min %.1f / median %.1f µs",
          accumulate[0], accumulate[accumulate.count / 2], render[0], render[render.count / 2]))
      return (accumulate[0], render[0])
    } until: { $0.accumulate < 60 && $0.render < 60 }
    // The release bar is 30 µs per pass; a debug build under load gets slack.
    XCTAssertLessThan(t.accumulate, 60)
    XCTAssertLessThan(t.render, 60)
  }

  /// Steady state: `prepare` allocates nothing, and accumulating or drawing
  /// into a host encoder allocates no more than the same Metal calls made
  /// inline by the host.
  func testSteadyStateEncodeMakesNoHeapAllocations() throws {
    let (device, queue, engine) = try GPU.require()
    if ProcessInfo.processInfo.environment["MTL_DEBUG_LAYER"].map({ $0 != "0" }) ?? false {
      throw XCTSkip("Metal API validation allocates inside every encoder call")
    }
    let frame = try TestFrame.natural(.v210, width: 640, height: 360, mirror: false)
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 512, height: 256, mipmapped: false)
    d.usage = .renderTarget
    d.storageMode = .private
    let target = try XCTUnwrap(device.makeTexture(descriptor: d))
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .load
    pass.colorAttachments[0].storeAction = .store
    var waveform = ScopeSettings(kind: .waveform)
    waveform.waveformMode = .rgbParade
    for settings in [waveform, ScopeSettings(kind: .vectorscope), ScopeSettings(kind: .histogram)] {
      let accumulator = try engine.makeAccumulator(settings: settings)
      let renderer = engine.makeRenderer()
      let viewport = MonitorViewport(width: 512, height: 256)
      var accumulate: [Int] = [], control: [Int] = [], prepare: [Int] = [], draw: [Int] = []
      var resolves: [Int] = [], resolveControls: [Int] = []
      for i in 0..<40 {
        try autoreleasepool {
          let cb = try XCTUnwrap(queue.makeCommandBuffer())
          let compute = try XCTUnwrap(cb.makeComputeCommandEncoder())
          guard let a = try AllocationCounter.measure({
            try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, using: compute)
          }) else { throw XCTSkip("malloc_logger is unavailable") }
          // The host making the same calls itself.
          var bytes = [UInt8](repeating: 0, count: 256)
          let c = AllocationCounter.measure {
            bytes.withUnsafeMutableBytes { raw in
              let p = raw.baseAddress!
              compute.setTexture(frame.frame.packed, index: 0)
              compute.setTexture(engine.placeholderPlane, index: 1)
              compute.setTexture(engine.placeholderPlane, index: 2)
              compute.setTexture(engine.placeholderLUT, index: 3)
              compute.setTexture(engine.placeholderLUT, index: 4)
              compute.setBytes(p, length: 80, index: 0)
              compute.setBytes(p, length: 64, index: 1)
              compute.setBytes(p, length: 64, index: 2)
              compute.setBytes(p, length: 128, index: 3)
              compute.setBuffer(accumulator.bins, offset: 0, index: 4)
              compute.setBuffer(accumulator.statisticsBuffer, offset: 0, index: 5)
              for pipeline in [engine.clearPipeline, engine.clearPipeline, engine.finalizePipeline] {
                compute.setComputePipelineState(pipeline)
                compute.setThreadgroupMemoryLength(0, index: 0)
                compute.dispatchThreadgroups(
                  MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
              }
            }
          }!
          compute.endEncoding()
          // The control encodes first: Metal allocates once in whichever
          // compute encoder follows the ended one (measured either way round).
          let resolveControl = AllocationCounter.measure {
            let e = cb.makeComputeCommandEncoder()!
            e.setComputePipelineState(engine.resolvePipeline)
            e.setBytes(&bytes, length: MemoryLayout<ScopeResolveParameters>.stride, index: 0)
            e.setBuffer(accumulator.bins, offset: 0, index: 1)
            e.setBuffer(accumulator.statisticsBuffer, offset: 0, index: 2)
            e.setTexture(renderer.traceTexture, index: 0)
            e.dispatchThreads(
              MTLSize(width: 64, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
            e.endEncoding()
          }!
          // New bins: prepare encodes the trace resolve, one compute encoder.
          let resolve = try AllocationCounter.measure {
            try renderer.prepare(accumulator, viewport: viewport, targetPixelFormat: .bgra8Unorm, into: cb)
          }!
          // Redrawing the same bins: nothing to encode.
          let p = try AllocationCounter.measure {
            try renderer.prepare(accumulator, viewport: viewport, targetPixelFormat: .bgra8Unorm, into: cb)
          }!
          let encoder = try XCTUnwrap(cb.makeRenderCommandEncoder(descriptor: pass))
          let r = AllocationCounter.measure { renderer.draw(with: encoder) }!
          encoder.endEncoding()
          cb.commit()
          cb.waitUntilCompleted()
          if i >= 5 {
            accumulate.append(a)
            control.append(c)
            prepare.append(p)
            draw.append(r)
            resolves.append(resolve)
            resolveControls.append(resolveControl)
          }
        }
      }
      let median = { (v: [Int]) in v.sorted()[v.count / 2] }
      print(
        "BENCH \(settings.kind) heap allocations: accumulate \(median(accumulate)) (inline Metal calls \(median(control))), "
          + "prepare \(prepare.max()!) (with a resolve \(median(resolves)), inline \(median(resolveControls))), "
          + "draw \(median(draw))")
      XCTAssertEqual(prepare.max(), 0, "\(settings.kind): prepare allocates in steady state")
      XCTAssertLessThanOrEqual(median(resolves), median(resolveControls), "\(settings.kind): beyond its resolve encoder")
      XCTAssertLessThanOrEqual(median(accumulate), median(control), "\(settings.kind): beyond the Metal calls it makes")
      XCTAssertEqual(median(draw), 0, "\(settings.kind): draw allocates")
    }
  }

  /// A fused group encodes fewer Metal calls than its members alone and
  /// allocates nothing of its own in steady state.
  func testGroupAllocatesNoMoreThanItsMembersAlone() throws {
    let (_, queue, _) = try GPU.require()
    let engine = try XCTUnwrap(GPU.synchronousEngine)
    let frame = try TestFrame.natural(.v210, width: 640, height: 360, mirror: false)
    let settings = [ScopeSettings(kind: .waveform), ScopeSettings(kind: .histogram), ScopeSettings(kind: .vectorscope)]
    let alone = try settings.map { try engine.makeAccumulator(settings: $0) }
    let group = try engine.makeGroup(try settings.map { try engine.makeAccumulator(settings: $0) })
    var grouped: [Int] = [], separate: [Int] = []
    for i in 0..<30 {
      try autoreleasepool {
        let cb = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(cb.makeComputeCommandEncoder())
        guard let a = try AllocationCounter.measure({
          for x in alone { try x.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, using: encoder) }
        }) else { throw XCTSkip("malloc_logger is unavailable") }
        let b = try AllocationCounter.measure {
          try group.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, using: encoder)
        }!
        encoder.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if i >= 5 {
          separate.append(a)
          grouped.append(b)
        }
      }
    }
    XCTAssertEqual(group.fusedMemberCount, 3)
    let median = { (v: [Int]) in v.sorted()[v.count / 2] }
    print("BENCH heap allocations: group \(median(grouped)), its members alone \(median(separate))")
    XCTAssertLessThanOrEqual(median(grouped), median(separate))
  }

  /// Persistent memory is the scope-sized bins, two statistics slots and one
  /// r8 graticule texel per viewport pixel.
  func testPersistentMemoryIsDocumentedSizes() throws {
    let (_, _, engine) = try GPU.require()
    var s = ScopeSettings(kind: .waveform, stage: .source)
    s.waveformColumns = 1024
    s.waveformLevels = 512
    let accumulator = try engine.makeAccumulator(settings: s)
    let frame = try TestFrame.natural(.bgra8, width: 1920, height: 1080, mirror: false)
    try GPU.run { cb in try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb) }
    XCTAssertEqual(accumulator.layout.byteLength, 1024 * 512 * 2, "16-bit bins: 1080 rows × 2 frame columns fit")
    XCTAssertEqual(
      accumulator.persistentMemoryBytes, accumulator.bins.allocatedSize + accumulator.statisticsBuffer.allocatedSize)
    XCTAssertGreaterThanOrEqual(accumulator.persistentMemoryBytes, 1024 * 512 * 2 + 256)
    XCTAssertLessThan(accumulator.persistentMemoryBytes, 1024 * 512 * 2 + 64 * 1024, "no hidden buffers")
    let renderer = engine.makeRenderer()
    XCTAssertEqual(renderer.persistentMemoryBytes, 0)
    let (device, _, _) = try GPU.require()
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 640, height: 360, mipmapped: false)
    d.usage = .renderTarget
    let target = try XCTUnwrap(device.makeTexture(descriptor: d))
    try GPU.run { cb in try renderer.render(accumulator, target: target, into: cb) }
    let graticule = try XCTUnwrap(renderer.graticuleTexture), trace = try XCTUnwrap(renderer.traceTexture)
    XCTAssertEqual(renderer.persistentMemoryBytes, graticule.allocatedSize + trace.allocatedSize)
    XCTAssertEqual(graticule.pixelFormat, .r8Unorm)
    XCTAssertEqual(
      SIMD3(graticule.width, graticule.height, 0), SIMD3(640, 384, 0), "one byte per viewport pixel, in 64-pixel steps")
    XCTAssertEqual(trace.pixelFormat, .r16Unorm)
    XCTAssertEqual(SIMD3(trace.width, trace.height, 0), SIMD3(1024, 512, 0), "one texel per bin")
    XCTAssertLessThan(renderer.persistentMemoryBytes, 640 * 384 * 2 + 1024 * 512 * 2 * 2)

    // The trace texture of every other scope: one texel per bin.
    var parade = ScopeSettings(kind: .waveform, stage: .source)
    parade.waveformMode = .rgbParade
    var histogram = ScopeSettings(kind: .histogram, stage: .source)
    histogram.histogramBins = 1024
    let narrow = try TestFrame.natural(.bgra8, width: 720, height: 486, mirror: false)
    for (settings, frame, format, width, height) in [
      (parade, frame, MTLPixelFormat.rgb10a2Unorm, 340, 512), (ScopeSettings(kind: .vectorscope, stage: .source), frame,
      .r16Unorm, 512, 512), (histogram, frame, .rgba16Unorm, 1024, 1), (ScopeSettings(kind: .waveform, stage: .source),
      narrow, .r16Unorm, 720, 512),
    ] {
      let a = try engine.makeAccumulator(settings: settings)
      let r = engine.makeRenderer()
      try GPU.run { cb in
        try a.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
        try r.render(a, target: target, into: cb)
      }
      let trace = try XCTUnwrap(r.traceTexture)
      XCTAssertEqual(trace.pixelFormat, format, "\(settings.kind)")
      XCTAssertEqual(SIMD2(trace.width, trace.height), SIMD2(width, height), "\(settings.kind)")
      XCTAssertEqual(r.persistentMemoryBytes, r.graticuleTexture!.allocatedSize + trace.allocatedSize)
    }
  }

  /// A UI thread polls the statistics while the render thread accumulates
  /// back to back: every value it sees is one whole accumulation, never a slot
  /// the GPU is clearing or filling.
  func testStatisticsReaderNeverReturnsATornSlot() throws {
    let (_, queue, engine) = try GPU.require()
    let frame = try TestFrame.make(
      .biplanar(.s444, 10), width: 96, height: 64, codes: { x, _ in SIMD3(x < 48 ? 940 : 64, 512, 512) }, mirror: false)
    var s = ScopeSettings(kind: .histogram, stage: .source)
    s.clipHighPercent = 100
    s.clipLowPercent = 0
    let accumulator = try engine.makeAccumulator(settings: s)
    let reader = accumulator.statisticsReader
    let done = Atomic<Bool>(false)
    let reads = Atomic<Int>(0), torn = Atomic<Int>(0)
    let poller = Thread {
      var last: UInt32 = 0
      while !done.load(ordering: .acquiring) {
        guard let stats = reader.statistics else { continue }
        reads.add(1, ordering: .relaxed)
        let whole =
          stats.pixelCount == 96 * 64 && stats.clippedHigh == SIMD4(repeating: 0.5)
          && stats.clippedLow == SIMD4(repeating: 0.5) && stats.lumaMaximum == 1 && stats.lumaMinimum == 0
          && stats.histogramPeak == SIMD3(repeating: 48 * 64)
        // Generations never go backwards.
        if !whole || Int32(bitPattern: stats.generation &- last) < 0 {
          if torn.add(1, ordering: .relaxed).newValue == 1 { print("TORN \(stats) last \(last)") }
        }
        last = stats.generation
      }
    }
    poller.start()
    var inFlight: [MTLCommandBuffer] = []
    for _ in 0..<600 {
      let cb = try XCTUnwrap(queue.makeCommandBuffer())
      try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: cb)
      cb.commit()
      inFlight.append(cb)
      if inFlight.count > 3 { inFlight.removeFirst().waitUntilCompleted() }
    }
    inFlight.forEach { $0.waitUntilCompleted() }
    done.store(true, ordering: .releasing)
    while !poller.isFinished { usleep(1000) }
    XCTAssertGreaterThan(reads.load(ordering: .relaxed), 1000, "the poller overlapped the GPU")
    XCTAssertEqual(torn.load(ordering: .relaxed), 0)
    XCTAssertEqual(reader.statistics?.generation, 600)
    _ = reader.statistics
    XCTAssertEqual(AllocationCounter.measure { _ = reader.statistics } ?? 0, 0, "polling allocates nothing")
  }

  /// Hand-built slots: only a slot whose stamps agree, and are neither 0 nor
  /// the open marker, decodes.
  func testStatisticsSlotStampsGateTheDecode() {
    var words = [UInt32](repeating: 0, count: 32)
    words[ScopeStatisticsWord.count] = 10
    func decode() -> ScopeStatistics? { words.withUnsafeBufferPointer { ScopeStatistics(slot: $0.baseAddress!) } }
    XCTAssertNil(decode(), "never written")
    words[ScopeStatisticsWord.begin] = 7
    words[ScopeStatisticsWord.end] = 0xFFFF_FFFF
    XCTAssertNil(decode(), "open")
    words[ScopeStatisticsWord.end] = 5
    XCTAssertNil(decode(), "reopened by a later accumulation")
    words[ScopeStatisticsWord.end] = 7
    XCTAssertNil(decode(), "stamps agree, checksum missing")
    func seal() {
      var inline = InlineArray<32, UInt32>(repeating: 0)
      for i in 0..<32 { inline[i] = words[i] }
      words[ScopeStatisticsWord.check] = ScopeStatisticsWord.checksum(inline)
    }
    seal()
    XCTAssertEqual(decode()?.generation, 7)
    XCTAssertEqual(decode()?.pixelCount, 10)
    // A copy that caught one word of the next accumulation (its clear) fails the
    // checksum though both stamps agree: the torn read the stamps alone let through.
    for word in [ScopeStatisticsWord.count, ScopeStatisticsWord.minimum, ScopeStatisticsWord.high + 3, ScopeStatisticsWord.peakAll] {
      let kept = words[word]
      words[word] = kept == 0 ? 1 : 0
      XCTAssertNil(decode(), "torn word \(word)")
      words[word] = kept
    }
    XCTAssertEqual(decode()?.pixelCount, 10)
    // A cleared slot (every word 0 but the stamps) never checks out.
    words = [UInt32](repeating: 0, count: 32)
    words[ScopeStatisticsWord.begin] = 7
    words[ScopeStatisticsWord.end] = 7
    XCTAssertNil(decode(), "cleared words")
  }

  /// The GPU writes the checksum the host verifies: every completed slot decodes.
  func testGPUChecksumMatchesTheHost() throws {
    let (_, _, engine) = try GPU.require()
    let frame = try TestFrame.natural(.v210, width: 320, height: 90, seed: 9)
    for kind in [ScopeKind.waveform, .histogram, .vectorscope] {
      let accumulator = try engine.makeAccumulator(settings: ScopeSettings(kind: kind, stage: .source))
      for generation in 1...3 {
        try GPU.run { try accumulator.accumulate(frame.frame, burnInLUT: nil, monitorLUT: nil, into: $0) }
        let stats = try XCTUnwrap(accumulator.statistics, "\(kind) #\(generation)")
        XCTAssertEqual(stats.generation, UInt32(generation))
        XCTAssertEqual(stats.pixelCount, 320 * 90)
      }
    }
  }

  /// The feed overload measures the stage with the feed's LUTs and reports which it applied.
  func testFeedOverloadAppliesTheFeedLUTs() throws {
    let (device, _, engine) = try GPU.require()
    let monitorEngine = try MonitorEngine(device: device, specialization: .off)
    let feed = monitorEngine.makeFeed()
    let cube = try ScopeAccumulationTests.makeCube(size: 17) { SIMD3(pow($0.x, 0.5), $0.y * 0.5, 1 - $0.z) }
    feed.burnInLUT = try MonitorLUT(device: device, cube: cube)
    let frame = try TestFrame.natural(.v210, width: 320, height: 90, seed: 5)
    for stage in SignalStage.allCases {
      var s = ScopeSettings(kind: .waveform, stage: stage)
      s.waveformMode = .rgbParade
      let viaFeed = try engine.makeAccumulator(settings: s), explicit = try engine.makeAccumulator(settings: s)
      try GPU.run { cb in
        try viaFeed.accumulate(frame.frame, feed: feed, into: cb)
        try explicit.accumulate(frame.frame, burnInLUT: feed.burnInLUT, monitorLUT: feed.monitorLUT, into: cb)
      }
      XCTAssertEqual(try readBins(viaFeed), try readBins(explicit), "\(stage)")
      XCTAssertEqual(viaFeed.appliedBurnInLUT, stage != .source, "\(stage)")
      XCTAssertFalse(viaFeed.appliedMonitorLUT, "the feed has no monitor LUT")
      XCTAssertEqual(viaFeed.context.matrix, stage == .source ? .bt709 : .bt709)
    }
  }
}
