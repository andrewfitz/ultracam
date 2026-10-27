import CoreVideo
import Darwin
import Foundation
import Metal
import XCTest

private final class BorrowedGPUAllocation: @unchecked Sendable {
  let base: UnsafeMutableRawPointer
  let length: Int
  let released: @Sendable () -> Void

  init(base: UnsafeMutableRawPointer, length: Int, released: @escaping @Sendable () -> Void) {
    self.base = base
    self.length = length
    self.released = released
  }

  deinit { munmap(base, length); released() }
}

private final class GPUReleaseCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var releases = 0
  var count: Int { lock.withLock { releases } }
  func increment() { lock.withLock { releases += 1 } }
}

@objcMembers final class GPUExtendedChecks: XCTestCase {
  func testEverySelectableResizeAndColorProducesValidVideo() throws {
    let processor = try LUTProcessor()
    let source = try input(luma: { _, _ in 400 })
    for resize in ResizeTarget.allCases {
      for color in ColorTarget.allCases {
        let configuration = PipelineConfiguration(resizeTarget: resize, colorTarget: color)
        let output = try processor.process(source, configuration: configuration)
        XCTAssertEqual(CVPixelBufferGetWidth(output), resize.width)
        XCTAssertEqual(CVPixelBufferGetHeight(output), resize.height)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), color.pixelFormat)
        try VideoBufferLayout.validate(output)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        let base = CVPixelBufferGetBaseAddressOfPlane(output, 0)!
        let stride = CVPixelBufferGetBytesPerRowOfPlane(output, 0)
        let row = base.advanced(by: resize.height / 2 * stride)
        let value = color.isEightBit ? Int(row.assumingMemoryBound(to: UInt8.self)[resize.width / 2]) * 4
          : Int(row.assumingMemoryBound(to: UInt16.self)[resize.width / 2] >> 6)
        XCTAssertEqual(value, 400, accuracy: 4, "\(resize.title) \(color.title)")
        CVPixelBufferUnlockBaseAddress(output, .readOnly)
      }
    }
  }

  func test720ResizeUsesTheWholeSourcePicture() throws {
    let processor = try LUTProcessor()
    let source = try input(luma: { x, y in x < 1920 && y < 1080 ? 64 : 940 })
    let output = try processor.process(source, configuration: PipelineConfiguration(resizeTarget: .hd720))
    CVPixelBufferLockBaseAddress(output, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
    let stride = CVPixelBufferGetBytesPerRowOfPlane(output, 0)
    let pixels = CVPixelBufferGetBaseAddressOfPlane(output, 0)!.assumingMemoryBound(to: UInt8.self)
    XCTAssertEqual(pixels[180 * stride + 320], 16, accuracy: 1)
    XCTAssertEqual(pixels[180 * stride + 960], 235, accuracy: 1)
    XCTAssertEqual(pixels[540 * stride + 320], 235, accuracy: 1)
  }

  private func input(packed: Bool = false, width: Int = 3840, height: Int = 2160,
    luma: (Int, Int) -> UInt16 = { _, _ in 400 },
    cb: (Int, Int) -> UInt16 = { _, _ in 512 },
    cr: (Int, Int) -> UInt16 = { _, _ in 512 }) throws -> CVPixelBuffer {
    var result: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, width, height,
      packed ? kCVPixelFormatType_422YpCbCr10 : kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &result)
    XCTAssertEqual(status, kCVReturnSuccess)
    let buffer = try XCTUnwrap(result)
    XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    if packed {
      let stride = CVPixelBufferGetBytesPerRow(buffer) / 4
      let words = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt32.self)
      for y in 0..<height {
        for x in Swift.stride(from: 0, to: width, by: 6) {
          let offset = y * stride + x / 6 * 4
          let pair = x / 2
          words[offset] = UInt32(cb(pair, y)) | (UInt32(luma(x, y)) << 10) | (UInt32(cr(pair, y)) << 20)
          words[offset + 1] = UInt32(luma(x + 1, y)) | (UInt32(cb(pair + 1, y)) << 10) | (UInt32(luma(x + 2, y)) << 20)
          words[offset + 2] = UInt32(cr(pair + 1, y)) | (UInt32(luma(x + 3, y)) << 10) | (UInt32(cb(pair + 2, y)) << 20)
          words[offset + 3] = UInt32(luma(x + 4, y)) | (UInt32(cr(pair + 2, y)) << 10) | (UInt32(luma(x + 5, y)) << 20)
        }
      }
    } else {
      let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / 2
      let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) / 2
      let yWords = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt16.self)
      let uvWords = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt16.self)
      for y in 0..<height {
        for x in 0..<width { yWords[y * yStride + x] = luma(x, y) << 6 }
        for pair in 0..<(width / 2) {
          uvWords[y * uvStride + pair * 2] = cb(pair, y) << 6
          uvWords[y * uvStride + pair * 2 + 1] = cr(pair, y) << 6
        }
      }
    }
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    return buffer
  }

  private func read10(_ buffer: CVPixelBuffer, plane: Int, x: Int, y: Int = 0) -> UInt16 {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) / 2
    return CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt16.self)[y * stride + x] >> 6
  }

  private func customPlanarInput(type: OSType, widths: [Int], heights: [Int], strides: [Int]) throws -> CVPixelBuffer {
    var widths = widths, heights = heights, strides = strides
    let planeBytes = max(7680, strides.max() ?? 0) * 2160
    let storage = UnsafeMutableRawPointer.allocate(byteCount: planeBytes * widths.count, alignment: 64)
    var addresses: [UnsafeMutableRawPointer?] = widths.indices.map { storage.advanced(by: $0 * planeBytes) }
    var image: CVPixelBuffer?
    let status = CVPixelBufferCreateWithPlanarBytes(nil, 3840, 2160, type, nil, 0, widths.count,
      &addresses, &widths, &heights, &strides, { context, _, _, _, _ in
        context?.deallocate()
      }, storage, nil, &image)
    guard status == kCVReturnSuccess, let image else {
      storage.deallocate()
      throw VideoError.message("Cannot construct planar layout fixture (\(status)).")
    }
    return image
  }

  private func borrowedInput(offset: Int = 0, stride: Int = 10240, splitVMRegion: Bool = false,
    released: @escaping @Sendable () -> Void = {}) throws -> CVPixelBuffer {
    let page = Int(getpagesize())
    let length = ((stride * 2160 + offset + page - 1) / page) * page
    guard let allocation = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0),
      allocation != MAP_FAILED else { throw VideoError.message("Cannot allocate synthetic borrowed capture.") }
    let owner = BorrowedGPUAllocation(base: allocation, length: length, released: released)
    let bytes = allocation.advanced(by: offset).assumingMemoryBound(to: UInt32.self)
    for y in 0..<2160 {
      func luma(_ x: Int) -> UInt32 { UInt32(64 + x * 876 / 3839) }
      for x in Swift.stride(from: 0, to: 3840, by: 6) {
        let o = y * stride / 4 + x / 6 * 4
        bytes[o] = 512 | (luma(x) << 10) | (512 << 20)
        bytes[o + 1] = luma(x + 1) | (512 << 10) | (luma(x + 2) << 20)
        bytes[o + 2] = 512 | (luma(x + 3) << 10) | (512 << 20)
        bytes[o + 3] = luma(x + 4) | (512 << 10) | (luma(x + 5) << 20)
      }
    }
    if splitVMRegion {
      // Both halves stay readable, but Metal forbids wrapping their combined
      // range once a different protection creates a second VM region.
      XCTAssertEqual(mprotect(allocation.advanced(by: length / 2 / page * page), page, PROT_READ), 0)
    }
    var buffer: CVPixelBuffer?
    let context = Unmanaged.passRetained(owner).toOpaque()
    let status = CVPixelBufferCreateWithBytes(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10,
      allocation.advanced(by: offset), stride,
      { context, _ in Unmanaged<BorrowedGPUAllocation>.fromOpaque(context!).release() }, context, nil, &buffer)
    if status != kCVReturnSuccess { Unmanaged<BorrowedGPUAllocation>.fromOpaque(context).release() }
    XCTAssertEqual(status, kCVReturnSuccess)
    return try XCTUnwrap(buffer)
  }

  func testPackedAndPlanarAgreeForEveryLaneAndRowStride() throws {
    let processor = try LUTProcessor()
    try processor.load(CubeLUT(text: cubeText()))
    let config = PipelineConfiguration(applyLUT: true, downscale: false, convertTo420: false)
    let y: (Int, Int) -> UInt16 = { x, row in UInt16(200 + (x * 7 + row * 11) % 600) }
    let cb: (Int, Int) -> UInt16 = { pair, row in UInt16(350 + (pair * 13 + row * 17) % 250) }
    let cr: (Int, Int) -> UInt16 = { pair, row in UInt16(410 + (pair * 19 + row * 23) % 200) }
    let packed = try processor.process(input(packed: true, luma: y, cb: cb, cr: cr), configuration: config)
    let planar = try processor.process(input(luma: y, cb: cb, cr: cr), configuration: config)
    CVPixelBufferLockBaseAddress(packed, .readOnly)
    CVPixelBufferLockBaseAddress(planar, .readOnly)
    defer {
      CVPixelBufferUnlockBaseAddress(packed, .readOnly)
      CVPixelBufferUnlockBaseAddress(planar, .readOnly)
    }
    for plane in 0..<2 {
      let packedStride = CVPixelBufferGetBytesPerRowOfPlane(packed, plane) / 2
      let planarStride = CVPixelBufferGetBytesPerRowOfPlane(planar, plane) / 2
      let a = CVPixelBufferGetBaseAddressOfPlane(packed, plane)!.assumingMemoryBound(to: UInt16.self)
      let b = CVPixelBufferGetBaseAddressOfPlane(planar, plane)!.assumingMemoryBound(to: UInt16.self)
      for row in [0, 1, 1091, 2159] {
        for x in 0..<3840 {
          XCTAssertEqual(Double(a[row * packedStride + x] >> 6), Double(b[row * planarStride + x] >> 6), accuracy: 1,
            "v210/planar mismatch at plane \(plane), row \(row), column \(x)")
        }
      }
    }
  }

  func testChromaLocationHonoredAndOutputCentered() throws {
    let processor = try LUTProcessor()
    try processor.load(CubeLUT(text: cubeText()))
    let config = PipelineConfiguration(applyLUT: true, downscale: false, convertTo420: false)
    for packed in [false, true] {
      let source = try input(packed: packed, cb: { pair, _ in pair < 10 ? 512 : 800 })
      let left = try processor.process(source, configuration: config)
      CVBufferSetAttachment(source, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center, .shouldPropagate)
      let center = try processor.process(source, configuration: config)
      XCTAssertEqual(Double(read10(left, plane: 1, x: 18)), 584, accuracy: 1)
      XCTAssertEqual(Double(read10(center, plane: 1, x: 18)), 548, accuracy: 1)
      XCTAssertEqual(CVBufferCopyAttachment(left, kCVImageBufferChromaLocationTopFieldKey, nil) as? String,
        kCVImageBufferChromaLocation_Center as String)
    }
  }

  func testRGBOrderingAndDomainClipping() throws {
    var text = "LUT_3D_SIZE 2\nDOMAIN_MIN 0.25 0.25 0.25\nDOMAIN_MAX 0.75 0.75 0.75\n"
    for b in 0...1 { for g in 0...1 { for r in 0...1 { text += "\(b) \(r) \(g)\n" } } }
    let processor = try LUTProcessor()
    try processor.load(CubeLUT(text: text))
    let config = PipelineConfiguration(applyLUT: true, downscale: false, convertTo420: false)
    // Independent Rec.709 reference: encode source RGB, then domain-normalize,
    // clamp and permute B->R, R->G, G->B through the LUT.
    for rgb in [SIMD3<Double>(0.4, 0.6, 0.3), SIMD3<Double>(0.1, 0.7, 0.85)] {
      let y = 0.2126 * rgb.x + 0.7152 * rgb.y + 0.0722 * rgb.z
      let cb = (rgb.z - y) / (2 * (1 - 0.0722))
      let cr = (rgb.x - y) / (2 * (1 - 0.2126))
      let source = try input(luma: { _, _ in UInt16((64 + 876 * y).rounded()) },
        cb: { _, _ in UInt16((512 + 896 * cb).rounded()) }, cr: { _, _ in UInt16((512 + 896 * cr).rounded()) })
      let mapped = SIMD3<Double>(min(1, max(0, (rgb.z - 0.25) / 0.5)),
        min(1, max(0, (rgb.x - 0.25) / 0.5)), min(1, max(0, (rgb.y - 0.25) / 0.5)))
      let mappedY = 0.2126 * mapped.x + 0.7152 * mapped.y + 0.0722 * mapped.z
      let output = try processor.process(source, configuration: config)
      XCTAssertEqual(Double(read10(output, plane: 0, x: 100)), 64 + 876 * mappedY, accuracy: 2)
      XCTAssertEqual(Double(read10(output, plane: 1, x: 100)), 512 + 896 * (mapped.z - mappedY) / (2 * (1 - 0.0722)), accuracy: 2)
      XCTAssertEqual(Double(read10(output, plane: 1, x: 101)), 512 + 896 * (mapped.x - mappedY) / (2 * (1 - 0.2126)), accuracy: 2)
    }
  }

  func testLanczosMatchesIndependentScalarReferenceAtEdgesAndImpulse() throws {
    let processor = try LUTProcessor()
    let source = try input(luma: { x, _ in (x == 0 || x == 1919 || x == 3839) ? 940 : 64 })
    let output = try processor.process(source,
      configuration: PipelineConfiguration(applyLUT: false, downscale: true, convertTo420: false))
    func sinc(_ value: Double) -> Double { abs(value) < 1e-8 ? 1 : sin(.pi * value) / (.pi * value) }
    for x in [0, 1, 2, 958, 959, 960, 961, 1917, 1918, 1919] {
      let center = (Double(x) + 0.5) * 2 - 0.5
      var total = 0.0, weights = 0.0
      for sourceX in Int(ceil(center - 6))...Int(floor(center + 6)) {
        let offset = (Double(sourceX) - center) / 2
        let weight = abs(offset) < 3 ? sinc(offset) * sinc(offset / 3) : 0
        let clamped = min(3839, max(0, sourceX))
        total += ([0, 1919, 3839].contains(clamped) ? 1 : 0) * weight
        weights += weight
      }
      XCTAssertEqual(Double(read10(output, plane: 0, x: x)), max(0, min(1023, 64 + 876 * total / weights)), accuracy: 1)
    }
  }

  func testInvalidSourceRejectedEvenWithEffectsOff() throws {
    let processor = try LUTProcessor()
    let config = PipelineConfiguration(applyLUT: false, downscale: false, convertTo420: false)
    XCTAssertThrowsError(try processor.process(input(width: 1920, height: 1080), configuration: config))
    var wrongFormat: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_32BGRA, nil, &wrongFormat), kCVReturnSuccess)
    XCTAssertThrowsError(try processor.process(XCTUnwrap(wrongFormat), configuration: config))
  }

  func testMalformedPlanarGeometryIsRejectedBeforeProcessingOrBypass() throws {
    let processor = try LUTProcessor()
    let malformed = [
      ([3840], [2160], [7680]),
      ([3840, 960], [2160, 2160], [7680, 7680]),
      ([3840, 1920], [2160, 1080], [7680, 7680]),
      ([3840, 1920], [2160, 2160], [7680, 3840]),
      ([3840, 1920], [2160, 2160], [7681, 7680]),
    ]
    for type in [kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange] {
      for (widths, heights, strides) in malformed {
        let image = try customPlanarInput(type: type, widths: widths, heights: heights, strides: strides)
        XCTAssertThrowsError(try VideoBufferLayout.validate(image))
        XCTAssertThrowsError(try processor.process(image, configuration: PipelineConfiguration()))
        XCTAssertThrowsError(try processor.process(image,
          configuration: PipelineConfiguration(applyLUT: false, downscale: false, convertTo420: false)))
      }
    }
    XCTAssertFalse(processor.workingResourceDiagnostics.outputPoolActive,
      "Malformed input must fail before output allocation or GPU mapping")
  }

  func testLayoutValidatorPreservesSupportedStorageAndChromaGeometry() throws {
    for type in VideoContract.tenBit422 + [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] {
      for (width, height) in [(3840, 2160), (1920, 1080)] {
        var image: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, type,
          [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image), kCVReturnSuccess)
        XCTAssertNoThrow(try VideoBufferLayout.validate(XCTUnwrap(image)))
      }
    }
    let invalid420 = try customPlanarInput(type: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      widths: [3840, 1920], heights: [2160, 2160], strides: [3840, 3840])
    XCTAssertThrowsError(try VideoBufferLayout.validate(invalid420),
      "4:2:0 requires half-height chroma; accepting 4:2:2 geometry would corrupt transport")
  }

  func testReusedPoolDoesNotLeakLUTColorLabelsOntoBypass() throws {
    let processor = try LUTProcessor()
    try processor.load(CubeLUT(text: cubeText()))
    let source = try input()
    var config = PipelineConfiguration(applyLUT: true, downscale: true, convertTo420: true)
    for _ in 0..<8 { _ = try processor.process(source, configuration: config) }
    config.applyLUT = false
    let bypass = try processor.process(source, configuration: config)
    XCTAssertNil(CVBufferCopyAttachment(bypass, kCVImageBufferColorPrimariesKey, nil))
    XCTAssertNil(CVBufferCopyAttachment(bypass, kCVImageBufferTransferFunctionKey, nil))
    XCTAssertEqual(CVBufferCopyAttachment(bypass, kCVImageBufferYCbCrMatrixKey, nil) as? String,
      kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
  }

  func testPrewarmPreservesTenBitLUTProcessingAndPoolCapacity() throws {
    let processor = try LUTProcessor()
    try processor.load(CubeLUT(text: cubeText()))
    let config = PipelineConfiguration(applyLUT: true, downscale: false, convertTo420: false)
    try processor.prepare(configuration: config)
    let source = try syntheticRamp()
    let output = try processor.process(source, configuration: config)
    XCTAssertEqual(read10(output, plane: 0, x: 1920), UInt16(64 + 1920 * 876 / 3839))
    var held = [output]
    for _ in 1..<8 { held.append(try processor.process(source, configuration: config)) }
    XCTAssertEqual(held.count, 8, "Prewarm must release all warm frames before native capture starts")
  }

  /// Live-path warm-up commits its frames ahead of the next one and returns
  /// without waiting for the GPU; nothing fills the warm-up input on the CPU.
  func testLivePrepareDoesNotWaitAndKeepsOrder() throws {
    let processor = try LUTProcessor()
    let config = PipelineConfiguration(applyLUT: false, downscale: true, convertTo420: true)
    let started = ProcessInfo.processInfo.systemUptime
    try processor.prepare(configuration: config, wait: false)
    let prepareMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
    let order = OrderLog()
    let done = DispatchSemaphore(value: 0)
    let source = try input(packed: true)
    for index in 0..<3 {
      try processor.submit(source, configuration: config) { completed in
        if case .success = completed.result { order.append(index) }
      }
    }
    // A frame that skips the GPU is ordered behind the ones on it.
    processor.afterCommittedFrames { order.append(99); done.signal() }
    XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(order.values, [0, 1, 2, 99])
    // Nothing in flight: it still runs, on the completion queue.
    XCTAssertTrue(processor.waitUntilIdle(timeout: 2))
    processor.afterCommittedFrames { done.signal() }
    XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
    print(String(format: "LIVE_PREPARE returnMS=%.3f (3 warm frames committed, not awaited)", prepareMS))
  }

  func testIOSurfaceCaptureDecodesEveryPackedLaneWithoutACopy() throws {
    let processor = try LUTProcessor()
    try processor.load(CubeLUT(text: cubeText()))
    let config = PipelineConfiguration(applyLUT: true, downscale: false, convertTo420: false)
    let source = try input(packed: true, luma: { x, _ in UInt16(64 + x * 876 / 3839) })
    XCTAssertNotNil(CVPixelBufferGetIOSurface(source))
    let before = processor.packedInputDiagnostics
    let output = try processor.process(source, configuration: config)
    let after = processor.packedInputDiagnostics
    XCTAssertEqual(after.noCopyFrames - before.noCopyFrames, 1)
    CVPixelBufferLockBaseAddress(output, .readOnly)
    let rowStride = CVPixelBufferGetBytesPerRowOfPlane(output, 0) / 2
    let words = CVPixelBufferGetBaseAddressOfPlane(output, 0)!.assumingMemoryBound(to: UInt16.self)
    for row in [0, 1, 1091, 2159] {
      for x in 0..<3840 {
        XCTAssertEqual(Double(words[row * rowStride + x] >> 6), Double(64 + x * 876 / 3839), accuracy: 1)
      }
    }
    CVPixelBufferUnlockBaseAddress(output, .readOnly)
  }

  func testNonIOSurfaceCaptureIsRejectedNotCopied() throws {
    let processor = try LUTProcessor()
    let source = try borrowedInput()
    XCTAssertNil(CVPixelBufferGetIOSurface(source))
    XCTAssertThrowsError(try processor.process(source,
      configuration: PipelineConfiguration(applyLUT: false, downscale: true, convertTo420: true)))
    XCTAssertEqual(processor.packedInputDiagnostics.noCopyFrames, 0)
  }

  func testUndersizedPackedStrideRejectedBeforeAnyGPUOrPassthroughUse() throws {
    let processor = try LUTProcessor()
    let source = try borrowedInput(stride: 10236)
    XCTAssertThrowsError(try processor.process(source,
      configuration: PipelineConfiguration(applyLUT: false, downscale: false, convertTo420: false)))
    XCTAssertThrowsError(try processor.process(source,
      configuration: PipelineConfiguration(applyLUT: false, downscale: true, convertTo420: true)))
    XCTAssertEqual(processor.packedInputDiagnostics.noCopyFrames, 0)
  }

  func testBypassReleasesWorkingAllocationsWithoutInvalidatingPublishedFrame() throws {
    let processor = try LUTProcessor()
    let source = try input(packed: true)
    let processed = PipelineConfiguration(applyLUT: false, downscale: true, convertTo420: true)
    let published = try processor.process(source, configuration: processed)
    XCTAssertGreaterThan(processor.workingResourceDiagnostics.floatTextureBytes, 0)
    XCTAssertTrue(processor.workingResourceDiagnostics.outputPoolActive)
    func middleLuma() -> UInt8 {
      CVPixelBufferLockBaseAddress(published, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(published, .readOnly) }
      return CVPixelBufferGetBaseAddressOfPlane(published, 0)!.assumingMemoryBound(to: UInt8.self)[960]
    }
    let expected = middleLuma()
    let bypass = PipelineConfiguration(applyLUT: false, downscale: false, convertTo420: false)
    try processor.prepare(configuration: bypass)
    XCTAssertEqual(processor.workingResourceDiagnostics.floatTextureBytes, 0)
    XCTAssertFalse(processor.workingResourceDiagnostics.outputPoolActive)
    XCTAssertEqual(middleLuma(), expected, "Releasing working memory must preserve an already published IOSurface")
    XCTAssertTrue(try processor.process(source, configuration: bypass) === source)
    let resumed = try processor.process(source, configuration: processed)
    XCTAssertEqual(CVPixelBufferGetWidth(resumed), 1920)
    XCTAssertGreaterThan(processor.workingResourceDiagnostics.floatTextureBytes, 0)
  }

  func testDisablingDownscaleReleasesOnlyScalingTexturesAndPreservesPrecision() throws {
    let processor = try LUTProcessor()
    try processor.load(CubeLUT(text: cubeText()))
    let source = try syntheticRamp()
    _ = try processor.process(source,
      configuration: PipelineConfiguration(applyLUT: true, downscale: true, convertTo420: false))
    let scaledBytes = processor.workingResourceDiagnostics.floatTextureBytes
    XCTAssertGreaterThan(scaledBytes, 0)
    XCTAssertLessThan(scaledBytes, 1920 * 2160 * 16, "Downscale keeps one half-float horizontal intermediate")
    let full = try processor.process(source,
      configuration: PipelineConfiguration(applyLUT: true, downscale: false, convertTo420: false))
    XCTAssertEqual(processor.workingResourceDiagnostics.floatTextureBytes, 0,
      "Full resolution decodes, grades and encodes in one pass with no intermediate")
    XCTAssertEqual(read10(full, plane: 0, x: 1920), UInt16(64 + 1920 * 876 / 3839))
  }

  func testExpandedConsumerBudgetPreservesRetainedTenBitFramesAndReleasesIdleResources() throws {
    let processor = try LUTProcessor()
    let source = try input()
    let configuration = PipelineConfiguration(applyLUT: false, downscale: true, convertTo420: false)
    var retained = [CVPixelBuffer]()
    for frame in 0..<VideoContract.outputBufferLimit {
      // Each published frame has a different sub-eight-bit luma level. A
      // consumer backlog must preserve both buffer identity and actual pixels.
      XCTAssertEqual(CVPixelBufferLockBaseAddress(source, []), kCVReturnSuccess)
      let stride = CVPixelBufferGetBytesPerRowOfPlane(source, 0) / 2
      let words = CVPixelBufferGetBaseAddressOfPlane(source, 0)!.assumingMemoryBound(to: UInt16.self)
      for y in 0..<128 {
        for x in 0..<128 { words[y * stride + x] = UInt16(400 + frame) << 6 }
      }
      CVPixelBufferUnlockBaseAddress(source, [])
      let output = try processor.process(source, configuration: configuration)
      XCTAssertFalse(retained.contains { $0 === output })
      retained.append(output)
    }
    XCTAssertThrowsError(try processor.process(source, configuration: configuration)) { error in
      guard case VideoError.outputBackPressure = error else {
        XCTFail("Expanded demand must remain bounded: \(error)")
        return
      }
    }
    processor.releaseIdleResources()
    XCTAssertFalse(processor.workingResourceDiagnostics.outputPoolActive)
    XCTAssertEqual(processor.workingResourceDiagnostics.floatTextureBytes, 0)
    for (frame, output) in retained.enumerated() {
      XCTAssertEqual(read10(output, plane: 0, x: 16, y: 16), UInt16(400 + frame))
    }
    retained.removeAll()
    let recovered = try processor.process(source, configuration: configuration)
    XCTAssertEqual(read10(recovered, plane: 0, x: 16, y: 16), UInt16(399 + VideoContract.outputBufferLimit))
  }
}

private final class OrderLog: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [Int] = []
  func append(_ value: Int) { lock.lock(); stored.append(value); lock.unlock() }
  var values: [Int] { lock.lock(); defer { lock.unlock() }; return stored }
}
