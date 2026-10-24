import CoreMedia
import CoreVideo
import Darwin
import Metal
import MonitorKit
import QuartzCore
import XCTest

/// Counts heap allocations made by one thread through libmalloc's logger hook.
private typealias FeedHostMallocLogger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
nonisolated(unsafe) private var feedHostCountedThread: pthread_t?
nonisolated(unsafe) private var feedHostCountedAllocations = 0
private let feedHostMallocLogger: FeedHostMallocLogger = { type, _, _, _, _, _ in
  guard type & 2 != 0, let thread = feedHostCountedThread, pthread_equal(pthread_self(), thread) != 0
  else { return }
  feedHostCountedAllocations += 1
}
private func countingAllocations(_ body: () throws -> Void) rethrows -> Int? {
  guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
  let slot = symbol.assumingMemoryBound(to: FeedHostMallocLogger?.self)
  let previous = slot.pointee
  feedHostCountedAllocations = 0
  feedHostCountedThread = pthread_self()
  slot.pointee = feedHostMallocLogger
  defer {
    slot.pointee = previous
    feedHostCountedThread = nil
  }
  try body()
  return feedHostCountedAllocations
}

/// A surface's latest-frame slot, as a consumer of a feed host.
private final class Slot: MonitorFeedConsumer, @unchecked Sendable {
  let lock = NSLock()
  private var value: MonitorFeedHost.Delivery?
  private var count = 0
  func accept(_ delivery: MonitorFeedHost.Delivery) {
    lock.lock()
    value = delivery
    count += 1
    lock.unlock()
  }
  var latest: MonitorFeedHost.Delivery? { lock.withLock { value } }
  var accepted: Int { lock.withLock { count } }
}

/// Signals when a submission completes.
private final class Completion: MonitorGPUCompletion, @unchecked Sendable {
  private let semaphore = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var failed = false
  func gpuCompleted(kind: Int, gpuStart: Double, gpuEnd: Double, failed: Bool) {
    lock.withLock { self.failed = failed }
    semaphore.signal()
  }
  func wait() -> Bool {
    guard semaphore.wait(timeout: .now() + 10) == .success else { return false }
    return lock.withLock { !failed }
  }
}

/// MonitorFeedHost (delivery side and render-side wrapping) and MonitorGPUContext
/// (submission clock, encode contexts, render thread) against real MonitorKit.
@objcMembers final class MonitorFeedHostChecks: XCTestCase {
  // MARK: - Fixtures

  private func buffer(
    _ format: OSType, width: Int, height: Int, fill: UInt32? = nil
  ) throws -> CVPixelBuffer {
    var made: CVPixelBuffer?
    XCTAssertEqual(
      CVPixelBufferCreate(
        nil, width, height, format,
        [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
        &made), kCVReturnSuccess)
    let image = try XCTUnwrap(made)
    if let fill {
      CVPixelBufferLockBaseAddress(image, [])
      defer { CVPixelBufferUnlockBaseAddress(image, []) }
      let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(image)).assumingMemoryBound(to: UInt32.self)
      let words = CVPixelBufferGetBytesPerRow(image) * height / 4
      for i in 0..<words { base[i] = fill }
    }
    return image
  }

  /// A v210 frame of one mid-grey: Y, Cb and Cr all at code 512 (legal range).
  private func greyV210(width: Int = 48, height: Int = 16) throws -> CVPixelBuffer {
    let image = try buffer(
      kCVPixelFormatType_422YpCbCr10, width: width, height: height, fill: 512 | (512 << 10) | (512 << 20))
    CVBufferSetAttachment(image, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(
      image, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(
      image, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    return image
  }

  private func host(_ target: String = "alpha", gpu: MonitorGPUContext? = nil) -> (MonitorFeedHost, Slot) {
    let host = MonitorFeedHost(target: target, gpu: gpu)
    let slot = Slot()
    host.setConsumers([slot])
    return (host, slot)
  }

  private func offer(
    _ host: MonitorFeedHost, _ image: CVPixelBuffer, generation: UInt64 = 1, sequence: UInt64
  ) {
    host.offer(image, pts: CMTime(value: CMTimeValue(sequence), timescale: 60), captureGeneration: generation,
      sequence: sequence)
  }

  private func gpuCore() throws -> (MonitorGPUContext, MonitorGPUContext.Core) {
    guard let device = LUTProcessor.sharedDevice, device.supportsFamily(.metal4) else {
      throw XCTSkip("No Metal 4 device")
    }
    let gpu = MonitorGPUContext(device: { device })
    return (gpu, try gpu.core())
  }

  private func target(_ core: MonitorGPUContext.Core, width: Int, height: Int) throws -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]
    d.storageMode = .shared
    let texture = try XCTUnwrap(core.device.makeTexture(descriptor: d))
    core.hostResidency.addAllocation(texture)
    core.hostResidency.commit()
    return texture
  }

  private func pixel(_ texture: MTLTexture, x: Int, y: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 4)
    texture.getBytes(&bytes, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
    return bytes
  }

  /// Draws `delivery` into `target` with `state` through the host and the context; waits.
  private func draw(
    _ delivery: MonitorFeedHost.Delivery, host: MonitorFeedHost, core: MonitorGPUContext.Core,
    pass: MonitorPass, state: MonitorState, into target: MTLTexture
  ) throws -> MonitorFrame {
    let completion = Completion()
    var drawn: MonitorFrame?
    try core.submit(completion: completion) { context in
      let frame = try host.frame(delivery, in: context, core: core)
      drawn = frame
      try pass.encode(
        frame: frame, feed: host.feed(engine: core.engine), state: state, target: target, into: context.submission)
    }
    XCTAssertTrue(completion.wait(), "The monitor submission failed")
    return try XCTUnwrap(drawn)
  }

  // MARK: - Delivery side

  /// The kept MonitorCoordinatorChecks allocation case, against the feed host: the
  /// primaries, transfer and matrix tags, the clean aperture and the pixel aspect are
  /// read, and a steady stream of tagged frames allocates nothing on the delivery thread.
  func testSteadyOffersReadColorimetryAndGeometryWithoutAllocating() throws {
    let image = try buffer(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, width: 64, height: 36)
    CVBufferSetAttachment(image, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
    CVBufferSetAttachment(
      image, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
    CVBufferSetAttachment(image, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
    // Core Video rebuilds dictionary attachments on every read (they live on the
    // IOSurface), so the host must not read them per frame.
    CVBufferSetAttachment(
      image, kCVImageBufferCleanApertureKey,
      [
        kCVImageBufferCleanApertureWidthKey: 60, kCVImageBufferCleanApertureHeightKey: 34,
        kCVImageBufferCleanApertureHorizontalOffsetKey: 0, kCVImageBufferCleanApertureVerticalOffsetKey: 0,
      ] as CFDictionary, .shouldPropagate)
    CVBufferSetAttachment(
      image, kCVImageBufferPixelAspectRatioKey,
      [kCVImageBufferPixelAspectRatioHorizontalSpacingKey: 4, kCVImageBufferPixelAspectRatioVerticalSpacingKey: 3]
        as CFDictionary, .shouldPropagate)
    let (host, slot) = host("a")
    var sequence: UInt64 = 0
    func next() {
      sequence += 1
      offer(host, image, sequence: sequence)
    }
    for _ in 0..<20 { next() }
    let delivery = try XCTUnwrap(slot.latest)
    XCTAssertEqual(delivery.stamp.sequence, sequence)
    XCTAssertEqual(delivery.layout, .p010)
    XCTAssertEqual(delivery.signal.primaries, .rec2020)
    XCTAssertEqual(delivery.signal.encoding, .display(.hlg))
    XCTAssertEqual(delivery.signal.matrix, .bt2020)
    XCTAssertEqual(delivery.signal.range, .legal)
    XCTAssertEqual(delivery.geometry.cleanAperture, MonitorRect(x: 2, y: 1, width: 60, height: 34))
    XCTAssertEqual(delivery.geometry.pixelAspectRatio, 4.0 / 3.0, accuracy: 1e-9)
    XCTAssertFalse(delivery.isProcessed)
    guard let allocations = countingAllocations({ for _ in 0..<200 { next() } }) else {
      throw XCTSkip("malloc_logger unavailable")
    }
    XCTAssertEqual(slot.latest?.stamp.sequence, sequence)
    XCTAssertEqual(slot.accepted, 220)
    XCTAssertEqual(allocations, 0, "Steady-state offers allocate on the delivery thread")
  }

  /// Must-check (a): an HLG or PQ buffer tagged with BT.709 primaries keeps them.
  func testHDRTransferWithBT709PrimariesKeepsBT709() throws {
    for transfer in [kCVImageBufferTransferFunction_ITU_R_2100_HLG, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ] {
      let image = try buffer(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, width: 64, height: 36)
      CVBufferSetAttachment(image, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
      CVBufferSetAttachment(
        image, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
      let (host, slot) = host("hdr709")
      offer(host, image, sequence: 1)
      let signal = try XCTUnwrap(slot.latest).signal
      XCTAssertEqual(signal.primaries, .rec709, "\(transfer)")
      XCTAssertNotEqual(signal.encoding, .display(.bt709), "\(transfer)")
    }
  }

  /// The clean aperture's vertical offset points down (ISO/IEC 14496-12 `clap`, as
  /// `CVImageBufferGetCleanRect` reports it once its lower-left origin is flipped).
  func testCleanApertureOffsetsFollowCoreVideo() throws {
    let image = try buffer(kCVPixelFormatType_422YpCbCr10, width: 1920, height: 1080)
    CVBufferSetAttachment(
      image, kCVImageBufferCleanApertureKey,
      [
        kCVImageBufferCleanApertureWidthKey: 1800, kCVImageBufferCleanApertureHeightKey: 1000,
        kCVImageBufferCleanApertureHorizontalOffsetKey: -10, kCVImageBufferCleanApertureVerticalOffsetKey: 20,
      ] as CFDictionary, .shouldPropagate)
    let (host, slot) = host("clap")
    offer(host, image, sequence: 1)
    let aperture = try XCTUnwrap(try XCTUnwrap(slot.latest).geometry.cleanAperture)
    XCTAssertEqual(aperture, MonitorRect(x: 50, y: 60, width: 1800, height: 1000))
    let clean = CVImageBufferGetCleanRect(image)
    XCTAssertEqual(aperture.x, Double(clean.origin.x), accuracy: 1e-9)
    XCTAssertEqual(aperture.y, 1080 - Double(clean.origin.y + clean.height), accuracy: 1e-9)
  }

  /// The camera's declaration applies; Program ignores it, is processed, and never
  /// takes a burn-in LUT.
  func testDeclarationAppliesToCamerasAndProgramIsProcessed() throws {
    let image = try greyV210()
    let (camera, cameraSlot) = host("cam")
    offer(camera, image, sequence: 1)
    let before = try XCTUnwrap(cameraSlot.latest)
    XCTAssertEqual(before.signal.encoding, .display(.bt709))
    camera.setSignalDeclaration(MonitorSignalDeclaration(logProfileID: "sony-slog3-sgamut3cine", range: .full))
    offer(camera, image, sequence: 2)
    let declared = try XCTUnwrap(cameraSlot.latest)
    XCTAssertEqual(declared.signal.encoding, .log(try XCTUnwrap(LogEncoding(profileID: "sony-slog3-sgamut3cine"))))
    XCTAssertEqual(declared.signal.range, .full)
    XCTAssertNil(before.signal.outputReading, "Undeclared: the stages read the codes alike")
    XCTAssertEqual(declared.signal.outputReading, SignalReading(range: .legal, matrix: .bt709),
      "The burn-in reads the format's range, as LUTProcessor does; the signal carries both readings")
    XCTAssertTrue(declared.signal.hasDistinctOutputReading)
    XCTAssertEqual(declared.outputSignal.range, .legal)
    XCTAssertNil(declared.outputSignal.outputReading)
    XCTAssertEqual(declared.outputSignal.encoding, declared.signal.encoding)
    XCTAssertEqual(declared.signal(reading: .source), declared.signal)
    XCTAssertEqual(declared.signal(reading: .output), declared.outputSignal)
    XCTAssertEqual(declared.signal(reading: .monitor), declared.outputSignal)
    XCTAssertEqual(camera.signal(of: image), declared.signal)
    XCTAssertGreaterThan(declared.stamp.revision, before.stamp.revision)
    XCTAssertTrue(declared.stamp.follows(before.stamp))

    let (program, programSlot) = host(MonitorFeedHost.programTarget)
    XCTAssertTrue(program.isProgram)
    program.setSignalDeclaration(MonitorSignalDeclaration(logProfileID: "sony-slog3-sgamut3cine"))
    offer(program, image, sequence: 1)
    let mix = try XCTUnwrap(programSlot.latest)
    XCTAssertTrue(mix.isProcessed)
    XCTAssertEqual(mix.signal.encoding, .display(.bt709))
    XCTAssertEqual(mix.outputSignal, mix.signal, "Program has one reading")
    XCTAssertNil(mix.signal.outputReading)
    program.setSignalDeclaration(MonitorSignalDeclaration(range: .full))
    offer(program, image, sequence: 2)
    XCTAssertNil(try XCTUnwrap(programSlot.latest).signal.outputReading, "Program takes no declaration")
    if let device = LUTProcessor.sharedDevice {
      let lut = try LUTProcessor.makeLUT(try CubeLUT(text: "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n"), device: device)
      program.burnInLUT = lut
      XCTAssertNil(program.burnInLUT, "Program's frames are already processed")
      camera.burnInLUT = lut
      XCTAssertTrue(camera.burnInLUT === lut)
    }
  }

  /// The Output and Monitor stages decode as the burn-in does: SMPTE 240M as
  /// BT.709 (LUTProcessor's matrices are BT.2020, BT.601 and otherwise BT.709),
  /// and a declared range never; the Source stage keeps the tag and the
  /// declaration. The frame carries both readings whatever stage a pass
  /// measures, so each stage decodes with its own levels and matrix.
  func testOutputStagesDecodeAsTheBurnIn() throws {
    let image = try greyV210()
    CVBufferSetAttachment(
      image, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_SMPTE_240M_1995, .shouldPropagate)
    let (gpu, core) = try gpuCore()
    let (camera, slot) = host("cam-240m", gpu: gpu)
    camera.setSignalDeclaration(MonitorSignalDeclaration(range: .full))
    XCTAssertEqual(camera.signal(of: image).matrix, .smpte240m)
    XCTAssertEqual(camera.outputSignal(of: image).matrix, .bt709)
    offer(camera, image, sequence: 1)
    let delivery = try XCTUnwrap(slot.latest)
    XCTAssertEqual(delivery.signal.matrix, .smpte240m)
    XCTAssertEqual(delivery.signal.outputReading, SignalReading(range: .legal, matrix: .bt709))
    XCTAssertEqual(delivery.outputSignal.matrix, .bt709)
    let decode = LUTProcessor.parameters(for: image, matrix: kCVImageBufferYCbCrMatrix_SMPTE_240M_1995 as String,
      lut: nil).decodeRange
    let completion = Completion()
    try core.submit(completion: completion) { context in
      let frame = try camera.frame(delivery, in: context, core: core)
      XCTAssertEqual(frame.signal, delivery.signal, "Both readings reach MonitorKit")
      let source = frame.parameters(for: .source), output = frame.parameters(for: .output)
      XCTAssertEqual(source.levels, SIMD4(0, 1023, 512, 1023), "Source: the declared Full range")
      XCTAssertEqual(output.levels, SIMD4(64, 876, 512, 896), "Output: the legal range LUTProcessor reads")
      XCTAssertEqual(frame.parameters(for: .monitor), output)
      XCTAssertEqual(output.levels, decode, "The same levels as the burn-in's decode")
      XCTAssertNotEqual(output.matrix, source.matrix, "Output: BT.709, not the tagged SMPTE 240M")
      let again = try camera.frame(delivery, in: context, core: core)
      XCTAssertEqual(again.signal, frame.signal, "Every pass draws the same frame, never relabelled")
      XCTAssertEqual(again.id, frame.id, "One picture, analysed once")
    }
    XCTAssertTrue(completion.wait())

    // A camera that publishes the frame untouched (its passthrough copy keeps the
    // tags): the Output and Monitor stages keep SMPTE 240M, and still the format's range.
    XCTAssertEqual(camera.outputSignal(of: image, untouched: true).matrix, .smpte240m)
    camera.offer(image, pts: CMTime(value: 2, timescale: 60), captureGeneration: 1, sequence: 2, untouched: true)
    let untouched = try XCTUnwrap(slot.latest)
    XCTAssertEqual(untouched.stamp.sequence, 2)
    XCTAssertEqual(untouched.signal.matrix, .smpte240m)
    XCTAssertEqual(untouched.signal.outputReading, SignalReading(range: .legal, matrix: .smpte240m))
    XCTAssertEqual(untouched.outputSignal.matrix, .smpte240m, "Published untouched: the tag stays")
    XCTAssertEqual(untouched.outputSignal.range, .legal)
    XCTAssertGreaterThan(untouched.stamp.revision, delivery.stamp.revision, "The Output reading changed")
    offer(camera, image, sequence: 3)
    XCTAssertEqual(try XCTUnwrap(slot.latest).outputSignal.matrix, .bt709, "Processed again: the burn-in's BT.709")
    let passthrough = Completion()
    try core.submit(completion: passthrough) { context in
      let frame = try camera.frame(untouched, in: context, core: core)
      let source = frame.parameters(for: .source), output = frame.parameters(for: .output)
      XCTAssertEqual(output.levels, SIMD4(64, 876, 512, 896), "Output: the format's legal range")
      XCTAssertEqual(output.matrix, source.matrix, "Output: the tagged SMPTE 240M decode")
      let processed = try camera.frame(delivery, in: context, core: core).parameters(for: .output)
      XCTAssertNotEqual(output.matrix, processed.matrix, "Not the burn-in's BT.709")
    }
    XCTAssertTrue(passthrough.wait())

    // Undeclared and untouched, the stages read the codes alike: no second reading,
    // so MonitorKit draws exactly as for a single-reading frame.
    camera.setSignalDeclaration(nil)
    camera.offer(image, pts: CMTime(value: 4, timescale: 60), captureGeneration: 1, sequence: 4, untouched: true)
    let alike = try XCTUnwrap(slot.latest)
    XCTAssertNil(alike.signal.outputReading)
    XCTAssertEqual(alike.outputSignal, alike.signal)
  }

  /// Peaking on the Output stage of a camera declared Full: the mask the surface
  /// analyses (the frame, or the frame read as its Output stage alone) is the one
  /// the picture shows; a mask analysed with the declared range is not.
  func testOutputStageFocusMaskIsAnalysedWithTheBurnInReading() throws {
    let (gpu, core) = try gpuCore()
    let (camera, slot) = host("focus", gpu: gpu)
    camera.setSignalDeclaration(MonitorSignalDeclaration(range: .full))
    let image = try greyV210()
    let pass = core.engine.makePass()
    let target = try target(core, width: 48, height: 16)
    defer {
      core.hostResidency.removeAllocation(target)
      core.hostResidency.commit()
    }
    var state = MonitorState()
    state.pictureStage = .source
    state.focus.enabled = true
    state.focus.stage = .output
    var sequence: UInt64 = 0
    /// Whether the picture finds a mask after analysing the frame labelled `label`.
    func analysed(_ label: (MonitorFeedHost.Delivery) -> SignalDescription?) throws -> Bool {
      sequence += 1
      offer(camera, image, sequence: sequence)
      let delivery = try XCTUnwrap(slot.latest)
      XCTAssertTrue(delivery.signal.hasDistinctOutputReading)
      let completion = Completion()
      try core.submit(completion: completion) { context in
        let frame = try camera.frame(delivery, in: context, core: core)
        let feed = camera.feed(engine: core.engine)
        var analysis = frame
        if let signal = label(delivery) { analysis.signal = signal }
        try feed.analyze(analysis, focus: state.focus, into: context.submission)
        try pass.encode(frame: frame, feed: feed, state: state, target: target, into: context.submission)
      }
      XCTAssertTrue(completion.wait())
      var missing = false
      for entry in pass.status.unavailable where entry.tool == .focusPeaking {
        if case .focusNotAnalyzed = entry.reason { missing = true }
      }
      return !missing
    }
    XCTAssertTrue(try analysed { _ in nil }, "The frame itself: each stage reads its own")
    XCTAssertTrue(try analysed { $0.signal(reading: .output) }, "The Output stage's reading alone")
    XCTAssertFalse(try analysed { $0.signal(reading: .source).sourceOnly }, "Analysed with the declared Full range")
  }

  /// Generations: a new capture generation gets a newer stamp generation; after an
  /// invalidation the stopped generation (and older ones) is rejected; nothing is
  /// offered without consumers.
  func testGenerationsRejectionAndConsumers() throws {
    let image = try greyV210()
    let (host, slot) = host("gen")
    offer(host, image, generation: 1, sequence: 1)
    let first = try XCTUnwrap(slot.latest).stamp
    offer(host, image, generation: 2, sequence: 1)
    let second = try XCTUnwrap(slot.latest).stamp
    XCTAssertGreaterThan(second.generation, first.generation)
    XCTAssertTrue(second.follows(first))
    XCTAssertFalse(first.follows(second), "An older generation never replaces a newer one")
    var older = second
    older.sequence = 0
    XCTAssertFalse(older.follows(second), "An older sequence never replaces a newer one")
    // A retried delivery with the same sequence is the same source frame; it
    // must not replace the slot or inflate accepted-frame diagnostics.
    offer(host, image, generation: 2, sequence: 1)
    XCTAssertEqual(slot.accepted, 2, "Duplicate source sequence is ignored")
    host.invalidate(rejectingCaptureGeneration: 2)
    offer(host, image, generation: 2, sequence: 2)
    offer(host, image, generation: 1, sequence: 3)
    XCTAssertEqual(slot.accepted, 2, "The stopped generation is rejected")
    offer(host, image, generation: 3, sequence: 1)
    XCTAssertEqual(slot.accepted, 3)
    let third = try XCTUnwrap(slot.latest).stamp
    XCTAssertGreaterThan(third.generation, second.generation)
    XCTAssertGreaterThan(third.revision, second.revision)
    host.setConsumers([])
    offer(host, image, generation: 3, sequence: 2)
    XCTAssertEqual(slot.accepted, 3)
    XCTAssertEqual(host.offerStatistics.frames, 3, "No consumers, no per-frame work")
    XCTAssertEqual(host.observedSourceFrameHz, 0, "Equal timestamps give no rate")
  }

  // MARK: - Render side

  /// A delivery wraps over the shared texture cache at encode time: resident, with
  /// the delivery's ID (so a second surface reuses the analysis), the same texture on
  /// every draw, and made again (and resident again) after its feed is flushed.
  func testWrapAtEncodeIsResidentSharedAndSurvivesFlush() throws {
    let (gpu, core) = try gpuCore()
    try core.engine.prepare(pixelFormat: .bgra8Unorm, layouts: [.v210])
    let (host, slot) = host("wrap", gpu: gpu)
    offer(host, try greyV210(), sequence: 1)
    let delivery = try XCTUnwrap(slot.latest)
    let pass = core.engine.makePass()
    let target = try target(core, width: 48, height: 16)
    let made = core.frames.texturesMade
    let first = try draw(delivery, host: host, core: core, pass: pass, state: MonitorState(), into: target)
    XCTAssertEqual(first.id, delivery.frameID)
    XCTAssertEqual(first.layout, .v210)
    let packed = try XCTUnwrap(first.packed)
    XCTAssertTrue(core.engine.residency.contains(packed))
    XCTAssertEqual(core.frames.texturesMade, made + 1)
    XCTAssertEqual(core.frames.count(owner: host.owner), 1)
    // Mid grey: Y 512 is (512 - 64) / 876 of the legal range, about 130 of 255.
    for value in pixel(target, x: 24, y: 8).prefix(3) { XCTAssertEqual(Double(value), 130.4, accuracy: 3) }
    let second = try draw(delivery, host: host, core: core, pass: pass, state: MonitorState(), into: target)
    XCTAssertEqual(second.id, first.id, "Every surface gives one frame one ID")
    XCTAssertTrue(second.packed === packed, "Steady state makes no texture")
    XCTAssertEqual(core.frames.texturesMade, made + 1)
    gpu.flushFrames(owner: host.owner)
    XCTAssertEqual(core.frames.count(owner: host.owner), 0)
    let third = try draw(delivery, host: host, core: core, pass: pass, state: MonitorState(), into: target)
    let remade = try XCTUnwrap(third.packed)
    XCTAssertFalse(remade === packed)
    XCTAssertTrue(core.engine.residency.contains(remade))
    for value in pixel(target, x: 24, y: 8).prefix(3) { XCTAssertEqual(Double(value), 130.4, accuracy: 3) }
    XCTAssertEqual(core.clock.completedIndex, core.statistics.submissions)
  }

  /// The feed's burn-in LUT reaches the Output and Monitor stages and not the Source
  /// stage ("Output (LUT)" is the source plus the burn-in LUT in MonitorKit's shader).
  func testBurnInLUTReachesTheOutputStageOnly() throws {
    let (gpu, core) = try gpuCore()
    try core.engine.prepare(pixelFormat: .bgra8Unorm, layouts: [.v210])
    let (host, slot) = host("lut", gpu: gpu)
    var lines = ["LUT_3D_SIZE 2"]
    for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { lines.append("\(1 - r) \(1 - g) \(1 - b)") } } }
    let invert = try LUTProcessor.makeLUT(try CubeLUT(text: lines.joined(separator: "\n")), device: core.device)
    host.burnInLUT = invert
    offer(host, try greyV210(), sequence: 1)
    let delivery = try XCTUnwrap(slot.latest)
    let pass = core.engine.makePass()
    let target = try target(core, width: 48, height: 16)
    XCTAssertTrue(host.feed(engine: core.engine).burnInLUT === invert)
    XCTAssertNil(host.lutMismatch)
    for (stage, expected) in [(SignalStage.source, 130.4), (.output, 124.6), (.monitor, 124.6)] {
      var state = MonitorState()
      state.pictureStage = stage
      _ = try draw(delivery, host: host, core: core, pass: pass, state: state, into: target)
      for value in pixel(target, x: 24, y: 8).prefix(3) {
        XCTAssertEqual(Double(value), expected, accuracy: 3, "\(stage)")
      }
    }
    host.burnInLUT = nil
    XCTAssertNil(host.feed(engine: core.engine).burnInLUT)
  }

  /// A steady draw's host work (observe, two cache lookups at most, the frame value,
  /// keeping the pixel buffer) allocates nothing on the render thread.
  func testSteadyWrapAllocatesNothing() throws {
    let (gpu, core) = try gpuCore()
    let (host, slot) = host("steady", gpu: gpu)
    for (sequence, image) in [
      try greyV210(),
      try buffer(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, width: 64, height: 36),
    ].enumerated() {
      offer(host, image, sequence: UInt64(sequence + 1))
      let delivery = try XCTUnwrap(slot.latest)
      let context = try core.begin()
      _ = try host.frame(delivery, in: context, core: core)
      let allocations = try countingAllocations {
        for _ in 0..<20 { _ = try host.frame(delivery, in: context, core: core) }
      }
      core.abandon(context)
      guard let allocations else { throw XCTSkip("malloc_logger unavailable") }
      XCTAssertEqual(allocations, 0, "Steady wraps allocate on the render thread (\(String(describing: delivery.layout)))")
    }
  }

  // MARK: - GPU context

  func testSubmissionClockReportsTheContiguousWatermark() {
    let clock = MonitorGPUContext.SubmissionClock()
    XCTAssertEqual(clock.reserve().index, 1)
    XCTAssertEqual(clock.reserve().index, 2)
    XCTAssertEqual(clock.reserve().index, 3)
    let fourth = clock.reserve()
    XCTAssertEqual(fourth.index, 4)
    XCTAssertEqual(fourth.completed, 0)
    XCTAssertEqual(clock.complete(2), 0, "Out of order: 1 is still running")
    XCTAssertEqual(clock.complete(4), 0)
    XCTAssertEqual(clock.complete(1), 2)
    XCTAssertEqual(clock.complete(3), 4)
    XCTAssertEqual(clock.reserve().completed, 4)
    XCTAssertEqual(clock.counts.reserved, 5)
  }

  /// Uniforms are 256-byte aligned, never overlap, hold a picture and its analysis
  /// several times over in the first 32 KB, and grow past it rather than fail.
  func testEncodeContextUniformsAreAlignedAndGrow() throws {
    let (_, core) = try gpuCore()
    let context = try core.begin()
    XCTAssertGreaterThanOrEqual(context.index, 1)
    var end: UInt64 = 0
    for length in [1, MonitorPass.uniformLength, MonitorFeed.uniformLength, 300] {
      let allocation = context.allocateUniforms(length: length)
      XCTAssertEqual(allocation.gpuAddress % 256, 0)
      XCTAssertGreaterThanOrEqual(allocation.gpuAddress, end)
      end = allocation.gpuAddress + UInt64(length)
    }
    let pictures = MonitorGPUContext.uniformCapacity / (MonitorPass.uniformLength + MonitorFeed.uniformLength)
    XCTAssertGreaterThanOrEqual(pictures, 5)
    let grown = core.statistics.uniformChunksGrown
    // 6912 bytes so far: five more pictures overflow the first 32 KB.
    for _ in 0...pictures { _ = context.allocateUniforms(length: MonitorPass.uniformLength) }
    XCTAssertEqual(core.statistics.uniformChunksGrown, grown + 1)
    let completion = Completion()
    core.commit(context, completion: completion)
    XCTAssertTrue(completion.wait())
    // The pooled context comes back with [32 KB, 32 KB]. A request larger than
    // its second chunk replaces it: the replaced buffer leaves residency, so the
    // host set holds exactly the live chunks however often that happens.
    let resident = core.hostResidency.allocationCount
    for round in 1...3 {
      let reused = try core.begin()
      XCTAssertTrue(reused === context, "the completed context is reused")
      _ = reused.allocateUniforms(length: MonitorGPUContext.uniformCapacity)
      let large = reused.allocateUniforms(length: MonitorGPUContext.uniformCapacity + 4096 * round)
      XCTAssertEqual(large.gpuAddress % 256, 0)
      XCTAssertEqual(core.hostResidency.allocationCount, resident, "round \(round)")
      let done = Completion()
      core.commit(reused, completion: done)
      XCTAssertTrue(done.wait())
    }
    XCTAssertEqual(core.statistics.uniformChunksGrown, grown + 4)
  }

  /// Every submission handed out completes, also one whose encode threw, so the
  /// watermark (and with it MonitorKit's deferred releases) never stalls.
  func testAFailedEncodeStillCompletesItsSubmission() throws {
    let (_, core) = try gpuCore()
    struct Failure: Error {}
    XCTAssertThrowsError(try core.submit { _ in throw Failure() })
    XCTAssertEqual(core.statistics.failedEncodes, 1)
    XCTAssertEqual(core.statistics.abandonedDrawables, 0)
    let reserved = core.statistics.submissions
    let deadline = Date().addingTimeInterval(5)
    while core.clock.completedIndex < reserved, Date() < deadline { usleep(1000) }
    XCTAssertEqual(core.clock.completedIndex, reserved)
    XCTAssertEqual(core.engine.residency.completedSubmission, reserved)
  }

  /// An encode that throws after rendering into a drawable still waits for the
  /// drawable before that work and signals it after, so the layer's drawables keep
  /// cycling (more failures than the layer has drawables) and every submission
  /// completes.
  func testAFailedEncodeIntoADrawableStillWaitsForAndSignalsIt() throws {
    let (gpu, core) = try gpuCore()
    let layer = CAMetalLayer()
    layer.device = core.device
    layer.pixelFormat = .bgra8Unorm
    layer.framebufferOnly = false
    layer.drawableSize = CGSize(width: 64, height: 36)
    gpu.attachDrawables(layer.residencySet)
    defer { gpu.detachDrawables(layer.residencySet) }
    struct Failure: Error {}
    for attempt in 0..<(layer.maximumDrawableCount * 3) {
      let drawable = try XCTUnwrap(layer.nextDrawable(), "drawable \(attempt)")
      XCTAssertThrowsError(
        try core.submit(drawable: drawable) { context in
          let pass = MTL4RenderPassDescriptor()
          pass.colorAttachments[0].texture = drawable.texture
          pass.colorAttachments[0].loadAction = .clear
          pass.colorAttachments[0].storeAction = .store
          pass.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 0, blue: 0, alpha: 1)
          let encoder = try XCTUnwrap(context.commandBuffer.makeRenderCommandEncoder(descriptor: pass))
          encoder.endEncoding()
          throw Failure()
        })
    }
    let attempts = layer.maximumDrawableCount * 3
    XCTAssertEqual(core.statistics.failedEncodes, attempts)
    XCTAssertEqual(
      core.statistics.abandonedDrawables, attempts,
      "every failed encode waited for and signalled its drawable")
    let reserved = core.statistics.submissions
    let deadline = Date().addingTimeInterval(5)
    while core.clock.completedIndex < reserved, Date() < deadline { usleep(1000) }
    XCTAssertEqual(core.clock.completedIndex, reserved)
  }

  /// The display-link run loop is read without a hop to the render thread: it
  /// answers on the render thread itself (no self-deadlock), never hangs while
  /// `stop()` races it, and is nil once stopped.
  func testDisplayLinkRunLoopNeverWaitsOnTheRenderThread() throws {
    let render = MonitorGPUContext.RenderThread(name: "test.render.loop")
    final class Box: @unchecked Sendable {
      let lock = NSLock()
      var loop: RunLoop?
      var current: RunLoop?
    }
    let box = Box()
    let answered = expectation(description: "answered on the render thread")
    render.perform {
      let loop = render.runLoopForDisplayLinks
      box.lock.withLock {
        box.loop = loop
        box.current = RunLoop.current
      }
      answered.fulfill()
    }
    wait(for: [answered], timeout: 2)
    box.lock.withLock {
      XCTAssertNotNil(box.loop)
      XCTAssertTrue(box.loop === box.current, "the render thread's own run loop")
    }
    XCTAssertTrue(render.runLoopForDisplayLinks === box.lock.withLock { box.loop })
    render.stop()
    XCTAssertNil(render.runLoopForDisplayLinks)
    // stop() racing the accessor on fresh threads: every call returns.
    let races = 40
    let returned = expectation(description: "every racing call returns")
    returned.expectedFulfillmentCount = races
    for index in 0..<races {
      let racing = MonitorGPUContext.RenderThread(name: "test.render.race.\(index)")
      DispatchQueue.global(qos: .userInitiated).async {
        _ = racing.runLoopForDisplayLinks
        returned.fulfill()
      }
      DispatchQueue.global(qos: .userInitiated).async { racing.stop() }
    }
    wait(for: [returned], timeout: 5)
  }

  /// Must-check (b): the render thread exits once stopped, or once its owner goes away.
  func testRenderThreadExitsWhenStoppedOrReleased() throws {
    final class Box: @unchecked Sendable {
      let lock = NSLock()
      var thread: Thread?
    }
    final class PolicyBox: @unchecked Sendable {
      let lock = NSLock()
      var policy: thread_time_constraint_policy_data_t?
    }
    func runningThread(_ render: MonitorGPUContext.RenderThread) throws -> Thread {
      let box = Box()
      let ran = expectation(description: "ran on the render thread")
      render.perform {
        box.lock.withLock { box.thread = Thread.current }
        ran.fulfill()
      }
      wait(for: [ran], timeout: 2)
      let thread = try XCTUnwrap(box.lock.withLock { box.thread })
      XCTAssertFalse(thread.isMainThread)
      return thread
    }
    func waitUntilFinished(_ thread: Thread) -> Bool {
      let deadline = Date().addingTimeInterval(2)
      while !thread.isFinished, Date() < deadline { usleep(1000) }
      return thread.isFinished
    }
    let stopped = MonitorGPUContext.RenderThread(name: "test.render.stop")
    // The render thread runs on a real-time schedule of one display refresh.
    let scheduled = expectation(description: "read the render thread's schedule")
    let policyBox = PolicyBox()
    stopped.perform {
      policyBox.lock.withLock { policyBox.policy = MonitorGPUContext.RenderThread.currentTimeConstraint() }
      scheduled.fulfill()
    }
    wait(for: [scheduled], timeout: 2)
    let policy = try XCTUnwrap(policyBox.lock.withLock { policyBox.policy }, "a time-constraint policy")
    let expected = MonitorGPUContext.RenderThread.realTimeSchedule(
      refreshHz: MonitorGPUContext.RenderThread.fastestDisplayRefreshRate())
    XCTAssertEqual(policy.period, expected.period, "one refresh of the fastest display")
    // The kernel may raise the computation (XNU makes it at least half the constraint).
    XCTAssertGreaterThanOrEqual(policy.computation, expected.computation)
    XCTAssertLessThanOrEqual(policy.computation, policy.constraint)
    XCTAssertEqual(policy.constraint, expected.constraint)
    XCTAssertLessThanOrEqual(expected.constraint, expected.period)
    XCTAssertEqual(policy.preemptible, 1)
    let first = try runningThread(stopped)
    stopped.stop()
    XCTAssertTrue(waitUntilFinished(first))
    XCTAssertTrue(stopped.hasExited)
    stopped.perform { XCTFail("A stopped render thread runs nothing") }
    var released: MonitorGPUContext? = MonitorGPUContext(device: { nil })
    let second = try runningThread(try XCTUnwrap(released).renderThread)
    released = nil
    XCTAssertTrue(waitUntilFinished(second), "Releasing the context ends its render thread")
  }

  /// Without a device the context reports why, and retries only after a delay.
  func testUnavailableGPUIsReportedAndRetriedLater() {
    let gpu = MonitorGPUContext(device: { nil })
    XCTAssertThrowsError(try gpu.core())
    XCTAssertNotNil(gpu.unavailableReason)
    XCTAssertNil(gpu.builtCore)
    XCTAssertThrowsError(try gpu.core())
    XCTAssertEqual(gpu.statistics, MonitorGPUContext.Statistics())
  }

  /// The app keeps its pipeline warm start under its own Caches directory (its
  /// container's, sandboxed); a process with no bundle identifier keeps none.
  func testPipelineCacheLivesInTheAppsCaches() {
    let caches = URL(fileURLWithPath: "/Users/x/Library/Containers/org.ultracam.app/Data/Library/Caches")
    XCTAssertEqual(
      MonitorGPUContext.pipelineCacheDirectory(bundleIdentifier: "org.ultracam.app", caches: caches)?.path,
      "/Users/x/Library/Containers/org.ultracam.app/Data/Library/Caches/org.ultracam.app/MonitorKitPipelines")
    XCTAssertNil(MonitorGPUContext.pipelineCacheDirectory(bundleIdentifier: nil, caches: caches))
    XCTAssertNil(MonitorGPUContext.pipelineCacheDirectory(bundleIdentifier: "", caches: caches))
    XCTAssertNil(MonitorGPUContext.pipelineCacheDirectory(bundleIdentifier: "org.ultracam.app", caches: nil))
    XCTAssertEqual(MonitorCoordinator.sharedGPU.pipelineCacheDirectory, MonitorGPUContext.appPipelineCacheDirectory)
    XCTAssertNil(MonitorGPUContext().pipelineCacheDirectory, "Only the app's shared context keeps one")
  }

  /// With a cache directory both engines warm-start: the first context's warm-up
  /// saves an archive for each (made lazily, in a directory that did not exist),
  /// and a second context on it builds every warm-up pipeline from them.
  func testWarmUpSavesAndAWarmStartCompilesNothing() throws {
    guard let device = LUTProcessor.sharedDevice, device.supportsFamily(.metal4) else {
      throw XCTSkip("No Metal 4 device")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ultracam-pipelines-\(UUID().uuidString)")
    let directory = root.appendingPathComponent("MonitorKitPipelines")
    defer { try? FileManager.default.removeItem(at: root) }
    let plain = try MonitorGPUContext(device: { device }).core()
    XCTAssertNil(plain.engine.pipelineArchive)
    XCTAssertNil(plain.scopeEngine.pipelineArchive)

    let cold = try MonitorGPUContext(device: { device }, pipelineCacheDirectory: directory).core()
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "Nothing is written before a save")
    let coldEngine = try XCTUnwrap(cold.engine.pipelineArchive)
    let coldScopes = try XCTUnwrap(cold.scopeEngine.pipelineArchive)
    XCTAssertEqual(coldEngine.directory, directory)
    XCTAssertEqual(coldScopes.directory, directory)
    XCTAssertTrue(cold.engine.compiler.map { $0 === cold.compiler } == true,
      "The core reports the compiler the archive builds with")
    XCTAssertGreaterThan(try cold.warmUp(), 0)
    XCTAssertGreaterThanOrEqual(coldEngine.statistics.saves, 1, "\(coldEngine.statistics)")
    XCTAssertGreaterThanOrEqual(coldScopes.statistics.saves, 1, "\(coldScopes.statistics)")
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    XCTAssertTrue(names.contains { $0.hasPrefix("MonitorKit-") }, "\(names)")
    XCTAssertTrue(names.contains { $0.hasPrefix("MonitorKitScopes-") }, "\(names)")

    let warm = try MonitorGPUContext(device: { device }, pipelineCacheDirectory: directory).core()
    let warmEngine = try XCTUnwrap(warm.engine.pipelineArchive)
    let warmScopes = try XCTUnwrap(warm.scopeEngine.pipelineArchive)
    XCTAssertGreaterThanOrEqual(warmEngine.statistics.filesLoaded, 1)
    XCTAssertGreaterThanOrEqual(warmScopes.statistics.filesLoaded, 1)
    try warm.warmUp()
    XCTAssertEqual(warmEngine.statistics.misses, 0, "\(warmEngine.statistics)")
    XCTAssertEqual(warmScopes.statistics.misses, 0, "\(warmScopes.statistics)")
    XCTAssertGreaterThan(warmEngine.statistics.hits, 0)
    XCTAssertGreaterThan(warmScopes.statistics.hits, 0)
  }
}

private extension SignalDescription {
  /// This signal with the Source stage's reading on every stage.
  var sourceOnly: SignalDescription {
    var value = self
    value.outputReading = nil
    return value
  }
}
