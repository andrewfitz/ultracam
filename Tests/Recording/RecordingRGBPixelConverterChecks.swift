import CoreVideo
import Darwin
import IOSurface
import Metal
import XCTest

private final class RecordingRGBWeakOwner {
  weak var value: AnyObject?
  init(_ value: AnyObject?) { self.value = value }
}

@objcMembers final class RecordingRGBPixelConverterChecks: XCTestCase {
  func testTwelveBitRGBRampRetainsEveryCodeAndChannelOrder() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    let converter = try RecordingRGBPixelConverter(device: device)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
      width: 4096, height: 1, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = [.shaderRead]
    let input = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    var pixels = [Float](repeating: 0, count: 4096 * 4)
    for x in 0..<4096 {
      pixels[x * 4] = Float(x) / 4095
      pixels[x * 4 + 1] = Float(4095 - x) / 4095
      pixels[x * 4 + 2] = Float(x % 17) / 4095
      pixels[x * 4 + 3] = 0.25
    }
    pixels.withUnsafeBytes { input.replace(region: MTLRegionMake2D(0, 0, 4096, 1),
      mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: pixels.count * 4) }
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 4096, 1, RecordingRGBPixelConverter.outputPixelFormat,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary,
      &buffer), kCVReturnSuccess)
    let output = try XCTUnwrap(buffer)
    try converter.convert(decodedRGB: input, sourceBitDepth: 12, into: output)
    CVPixelBufferLockBaseAddress(output, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
    let codes = try XCTUnwrap(CVPixelBufferGetBaseAddress(output)).assumingMemoryBound(to: UInt16.self)
    for x in 0..<4096 {
      XCTAssertEqual(codes[x * 4], UInt16((Double(x) * 65535 / 4095).rounded()))
      XCTAssertEqual(codes[x * 4 + 1], UInt16((Double(4095 - x) * 65535 / 4095).rounded()))
      XCTAssertEqual(codes[x * 4 + 2], UInt16((Double(x % 17) * 65535 / 4095).rounded()))
      XCTAssertEqual(codes[x * 4 + 3], 65535)
      if x > 0 { XCTAssertGreaterThan(codes[x * 4], codes[(x - 1) * 4]) }
    }
  }

  func testPackedR210PreservesAllCodesIncludingVideoHeadroom() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    let converter = try RecordingRGBPixelConverter(device: device)
    var sourceBuffer: CVPixelBuffer?, destinationBuffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
    XCTAssertEqual(CVPixelBufferCreate(nil, 1024, 2, 0x72323130, attributes, &sourceBuffer), kCVReturnSuccess)
    XCTAssertEqual(CVPixelBufferCreate(nil, 1024, 2, RecordingRGBPixelConverter.outputPixelFormat,
      attributes, &destinationBuffer), kCVReturnSuccess)
    let source = try XCTUnwrap(sourceBuffer), destination = try XCTUnwrap(destinationBuffer)
    CVPixelBufferLockBaseAddress(source, [])
    let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(source)).assumingMemoryBound(to: UInt8.self)
    for row in 0..<2 { for x in 0..<1024 {
      let word = UInt32(x << 20 | (1023 - x) << 10 | (x % 31))
      let offset = row * CVPixelBufferGetBytesPerRow(source) + x * 4
      for c in 0..<4 { bytes[offset + c] = UInt8(truncatingIfNeeded: word >> (24 - c * 8)) }
    } }
    CVPixelBufferUnlockBaseAddress(source, [])
    try converter.convert(source, format: .r210, sourceRange: .full, into: destination)
    CVPixelBufferLockBaseAddress(destination, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(destination, .readOnly) }
    let output = try XCTUnwrap(CVPixelBufferGetBaseAddress(destination)).assumingMemoryBound(to: UInt16.self)
    for row in 0..<2 { for x in 0..<1024 {
      let offset = row * CVPixelBufferGetBytesPerRow(destination) / 2 + x * 4
      XCTAssertEqual(output[offset], UInt16((x * 65535 + 511) / 1023))
      XCTAssertEqual(output[offset + 1], UInt16(((1023 - x) * 65535 + 511) / 1023))
      XCTAssertEqual(output[offset + 2], UInt16(((x % 31) * 65535 + 511) / 1023))
      XCTAssertEqual(output[offset + 3], 65535)
    } }
  }

  func testPackedR12LOddRowsPreserveAllTwelveBitCodes() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    let converter = try RecordingRGBPixelConverter(device: device)
    let width = 4097, height = 2
    let stride = try RGBFormat.r12l.minimumRowBytes(width: width) + 13
    var bytes = [UInt8](repeating: 0xcd, count: stride * height)
    // Independent bit writer covers alternating nibble positions and row padding.
    for row in 0..<height { for x in 0..<width { for c in 0..<3 {
      let code = c == 0 ? x % 4096 : (c == 1 ? 4095 - x % 4096 : x % 19)
      for bit in 0..<12 {
        let offset = x * 36 + c * 12 + bit
        let index = row * stride + offset / 8
        let mask = UInt8(1 << (offset % 8))
        bytes[index] &= ~mask
        if code & (1 << bit) != 0 { bytes[index] |= mask }
      }
    } } }
    let input = try XCTUnwrap(device.makeBuffer(bytes: bytes, length: bytes.count))
    var image: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, width, height, RecordingRGBPixelConverter.outputPixelFormat,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image), kCVReturnSuccess)
    let output = try XCTUnwrap(image)
    try converter.convert(packedRGB: input, width: width, height: height, bytesPerRow: stride,
      format: .r12l, into: output)
    CVPixelBufferLockBaseAddress(output, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
    let codes = try XCTUnwrap(CVPixelBufferGetBaseAddress(output)).assumingMemoryBound(to: UInt16.self)
    for row in 0..<height { for x in 0..<width {
      let offset = row * CVPixelBufferGetBytesPerRow(output) / 2 + x * 4
      XCTAssertEqual(codes[offset], UInt16(((x % 4096) * 65535 + 2047) / 4095))
      XCTAssertEqual(codes[offset + 1], UInt16(((4095 - x % 4096) * 65535 + 2047) / 4095))
      XCTAssertEqual(codes[offset + 2], UInt16(((x % 19) * 65535 + 2047) / 4095))
      XCTAssertEqual(codes[offset + 3], 65535)
    } }
  }

  func testPendingSubmissionRetainsOriginalAndBudgetUntilGPUFeedback() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let gate = device.makeSharedEvent() else { throw XCTSkip("Metal unavailable") }
    let budget = GPUAllocationBudget(policy: try GPUAllocationBudgetPolicy(maximumBytes: 1024 * 1024, minimumSlots: 1))
    let converter = try RecordingRGBPixelConverter(device: device, budget: budget, submissionGate: gate)
    var source: CVPixelBuffer?, destination: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    XCTAssertEqual(CVPixelBufferCreate(nil, 16, 2, kCVPixelFormatType_32BGRA, attributes, &source), kCVReturnSuccess)
    XCTAssertEqual(CVPixelBufferCreate(nil, 16, 2, RecordingRGBPixelConverter.outputPixelFormat, attributes, &destination), kCVReturnSuccess)
    let heldSurface = try XCTUnwrap(CVPixelBufferGetIOSurface(XCTUnwrap(source))?.takeUnretainedValue())
    XCTAssertLessThan(IOSurfaceGetAllocSize(heldSurface), Int(getpagesize()))
    let retainedSource = RecordingRGBWeakOwner(source)
    let retainedDestination = RecordingRGBWeakOwner(destination)
    let done = DispatchSemaphore(value: 0)
    try converter.convert(XCTUnwrap(source), format: .bgra8, into: XCTUnwrap(destination)) { _ in done.signal() }
    source = nil; destination = nil
    XCTAssertEqual(done.wait(timeout: .now() + 0.05), .timedOut)
    XCTAssertNotNil(retainedSource.value)
    XCTAssertNotNil(retainedDestination.value)
    XCTAssertGreaterThan(budget.snapshot().bytes, 0)
    gate.signaledValue = 1
    XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(budget.snapshot().bytes, 0)
    XCTAssertEqual(budget.snapshot().leases, 0)
  }

  func testFailedByteAdmissionReleasesEveryLease() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    let budget = GPUAllocationBudget(policy: try GPUAllocationBudgetPolicy(maximumBytes: 1, minimumSlots: 1))
    let converter = try RecordingRGBPixelConverter(device: device, budget: budget)
    var source: CVPixelBuffer?, destination: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    XCTAssertEqual(CVPixelBufferCreate(nil, 16, 2, kCVPixelFormatType_32BGRA, attributes, &source), kCVReturnSuccess)
    XCTAssertEqual(CVPixelBufferCreate(nil, 16, 2, RecordingRGBPixelConverter.outputPixelFormat, attributes, &destination), kCVReturnSuccess)
    XCTAssertThrowsError(try converter.convert(XCTUnwrap(source), format: .bgra8, into: XCTUnwrap(destination)))
    XCTAssertEqual(budget.snapshot().bytes, 0)
    XCTAssertEqual(budget.snapshot().leases, 0)
  }

  #if ULTRACAM_TEST_SUPPORT
  func testFailedGPUFeedbackReleasesEveryLeaseAndReportsFailure() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    let budget = GPUAllocationBudget(policy: try GPUAllocationBudgetPolicy(maximumBytes: 1024 * 1024, minimumSlots: 1))
    let converter = try RecordingRGBPixelConverter(device: device, budget: budget)
    converter.feedbackFailureForTesting = NSError(domain: "RGB GPU injected feedback failure", code: 1)
    var source: CVPixelBuffer?, destination: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    XCTAssertEqual(CVPixelBufferCreate(nil, 16, 2, kCVPixelFormatType_32BGRA, attributes, &source), kCVReturnSuccess)
    XCTAssertEqual(CVPixelBufferCreate(nil, 16, 2, RecordingRGBPixelConverter.outputPixelFormat, attributes, &destination), kCVReturnSuccess)
    XCTAssertThrowsError(try converter.convert(XCTUnwrap(source), format: .bgra8, into: XCTUnwrap(destination))) { error in
      guard case RecordingRGBPixelConverter.ConversionError.commandFailed(let message) = error else {
        return XCTFail("Expected GPU command failure, got \(error)")
      }
      XCTAssertTrue(message.contains("injected feedback failure"))
    }
    XCTAssertEqual(budget.snapshot().bytes, 0)
    XCTAssertEqual(budget.snapshot().leases, 0)
  }
  #endif

  func testSubpageIOSurfaceUsesBoundedTextureCopyWithExactBGRACodes() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    let converter = try RecordingRGBPixelConverter(device: device)
    var sourceBuffer: CVPixelBuffer?, outputBuffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    XCTAssertEqual(CVPixelBufferCreate(nil, 3, 2, kCVPixelFormatType_32BGRA, attributes, &sourceBuffer), kCVReturnSuccess)
    XCTAssertEqual(CVPixelBufferCreate(nil, 3, 2, RecordingRGBPixelConverter.outputPixelFormat, attributes, &outputBuffer), kCVReturnSuccess)
    let source = try XCTUnwrap(sourceBuffer), output = try XCTUnwrap(outputBuffer)
    let surface = try XCTUnwrap(CVPixelBufferGetIOSurface(source)?.takeUnretainedValue())
    XCTAssertLessThan(IOSurfaceGetAllocSize(surface), Int(getpagesize()), "Exercise allocation smaller than one VM page")
    CVPixelBufferLockBaseAddress(source, [])
    let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(source)).assumingMemoryBound(to: UInt8.self)
    for y in 0..<2 { for x in 0..<3 {
      let offset = y * CVPixelBufferGetBytesPerRow(source) + x * 4
      bytes[offset] = UInt8(11 + x + y * 3)
      bytes[offset + 1] = UInt8(71 + x + y * 3)
      bytes[offset + 2] = UInt8(191 + x + y * 3)
      bytes[offset + 3] = 0
    } }
    CVPixelBufferUnlockBaseAddress(source, [])
    try converter.convert(source, format: .bgra8, sourceRange: .full, into: output)
    CVPixelBufferLockBaseAddress(output, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
    let values = try XCTUnwrap(CVPixelBufferGetBaseAddress(output)).assumingMemoryBound(to: UInt16.self)
    for y in 0..<2 { for x in 0..<3 {
      let offset = y * CVPixelBufferGetBytesPerRow(output) / 2 + x * 4
      XCTAssertEqual(values[offset], UInt16(191 + x + y * 3) * 257)
      XCTAssertEqual(values[offset + 1], UInt16(71 + x + y * 3) * 257)
      XCTAssertEqual(values[offset + 2], UInt16(11 + x + y * 3) * 257)
      XCTAssertEqual(values[offset + 3], 65535)
    } }
    XCTAssertEqual(converter.budget.snapshot().bytes, 0)
  }

  func testPrivateStagingBlitIsVisibleToDecodeAcrossConcurrentFrames() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    let converter = try RecordingRGBPixelConverter(device: device)
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    for batch in 0..<3 {
      var outputs: [CVPixelBuffer] = []
      let done = DispatchSemaphore(value: 0)
      for frame in 0..<3 {
        var sourceBuffer: CVPixelBuffer?, outputBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA, attributes, &sourceBuffer), kCVReturnSuccess)
        XCTAssertEqual(CVPixelBufferCreate(nil, 1280, 720, RecordingRGBPixelConverter.outputPixelFormat, attributes, &outputBuffer), kCVReturnSuccess)
        let source = try XCTUnwrap(sourceBuffer), output = try XCTUnwrap(outputBuffer)
        let red = UInt32((batch * 3 + frame) * 23 + 17)
        CVPixelBufferLockBaseAddress(source, [])
        let words = try XCTUnwrap(CVPixelBufferGetBaseAddress(source)).assumingMemoryBound(to: UInt32.self)
        let stride = CVPixelBufferGetBytesPerRow(source) / 4
        for y in 0..<720 { for x in 0..<1280 {
          words[y * stride + x] = (red << 16) | (UInt32(255 - x % 256) << 8) | UInt32(x % 256)
        } }
        CVPixelBufferUnlockBaseAddress(source, [])
        outputs.append(output)
        try converter.convert(source, format: .bgra8, sourceRange: .full, into: output) { result in
          if case .failure(let error) = result { XCTFail("Concurrent RGB submission failed: \(error)") }
          done.signal()
        }
      }
      for _ in 0..<3 { XCTAssertEqual(done.wait(timeout: .now() + 2), .success) }
      for (frame, output) in outputs.enumerated() {
        CVPixelBufferLockBaseAddress(output, .readOnly)
        let words = try XCTUnwrap(CVPixelBufferGetBaseAddress(output)).assumingMemoryBound(to: UInt16.self)
        for y in [0, 127, 359, 719] { for x in Swift.stride(from: 0, to: 1280, by: 37) {
          let offset = y * CVPixelBufferGetBytesPerRow(output) / 2 + x * 4
          XCTAssertEqual(words[offset], UInt16((batch * 3 + frame) * 23 + 17) * 257)
          XCTAssertEqual(words[offset + 1], UInt16(255 - x % 256) * 257)
          XCTAssertEqual(words[offset + 2], UInt16(x % 256) * 257)
          XCTAssertEqual(words[offset + 3], 65535)
        } }
        CVPixelBufferUnlockBaseAddress(output, .readOnly)
      }
      XCTAssertEqual(converter.budget.snapshot().bytes, 0)
    }
  }

  func testR12LIOSurfaceAtUHDAndWideBoundariesPreservesPackedTailPixels() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    let converter = try RecordingRGBPixelConverter(device: device)
    // UHD executes the complete 2160-row path. Wider rows use two rows so
    // checking 8K and the conservative texture bound stays inexpensive.
    for (width, height) in [(3640, 2), (3641, 2), (3642, 2), (3840, 2160), (7680, 2), (8192, 2), (16384, 2)] {
      try autoreleasepool {
        var sourceBuffer: CVPixelBuffer?, outputBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, 0x5231324c, attributes, &sourceBuffer), kCVReturnSuccess)
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, RecordingRGBPixelConverter.outputPixelFormat, attributes, &outputBuffer), kCVReturnSuccess)
        let source = try XCTUnwrap(sourceBuffer), output = try XCTUnwrap(outputBuffer)
        let stride = CVPixelBufferGetBytesPerRow(source)
        let layout = try RecordingRGBPixelConverter.sourceTextureLayout(width: width, height: height,
          format: .r12l, physicalStride: stride)
        XCTAssertEqual(layout.pixelFormat, .rgba16Uint)
        XCTAssertLessThanOrEqual(layout.width, 16384)
        XCTAssertLessThanOrEqual(layout.copiedRowBytes, stride)
        let rows = Array(Set([0, height / 2, height - 1])).sorted()
        let columns = [0, 1, width / 2, width - 2, width - 1]
        CVPixelBufferLockBaseAddress(source, [])
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(source)).assumingMemoryBound(to: UInt8.self)
        memset(bytes, 0, stride * height)
        for y in rows { for x in columns {
          let rgb = [(x + 17 * y + 123) % 4096, (x * 3 + y + 271) % 4096, 4095 - (x + 2 * y) % 4096]
          // Independent little-endian bit writer includes both nibble starts.
          for c in 0..<3 { for bit in 0..<12 {
            let offset = x * 36 + c * 12 + bit
            if rgb[c] & (1 << bit) != 0 { bytes[y * stride + offset / 8] |= UInt8(1 << (offset % 8)) }
          } }
        } }
        CVPixelBufferUnlockBaseAddress(source, [])
        try converter.convert(source, format: .r12l, sourceRange: .full, into: output)
        CVPixelBufferLockBaseAddress(output, .readOnly)
        let values = try XCTUnwrap(CVPixelBufferGetBaseAddress(output)).assumingMemoryBound(to: UInt16.self)
        for y in rows { for x in columns {
          let rgb = [(x + 17 * y + 123) % 4096, (x * 3 + y + 271) % 4096, 4095 - (x + 2 * y) % 4096]
          let offset = y * CVPixelBufferGetBytesPerRow(output) / 2 + x * 4
          for c in 0..<3 { XCTAssertEqual(values[offset + c], UInt16((rgb[c] * 65535 + 2047) / 4095), "\(width)×\(height), pixel \(x),\(y), channel \(c)") }
          XCTAssertEqual(values[offset + 3], 65535)
        } }
        CVPixelBufferUnlockBaseAddress(output, .readOnly)
        XCTAssertEqual(converter.budget.snapshot().bytes, 0)
      }
    }
  }

  func testR12LNativeTextureGeometryRejectsUnownedTailAndOversizedDimensions() throws {
    // A 3-pixel row has 14 logical bytes; RGBA16's final texel requires two
    // additional bytes of genuinely owned row padding, never a rounded VM span.
    XCTAssertThrowsError(try RecordingRGBPixelConverter.sourceTextureLayout(width: 3, height: 2, format: .r12l, physicalStride: 14))
    let padded = try RecordingRGBPixelConverter.sourceTextureLayout(width: 3, height: 2, format: .r12l, physicalStride: 16)
    XCTAssertEqual(padded.copiedRowBytes, 16)
    XCTAssertThrowsError(try RecordingRGBPixelConverter.sourceTextureLayout(width: 16385, height: 2, format: .r12l, physicalStride: 100000))
    XCTAssertThrowsError(try RecordingRGBPixelConverter.sourceTextureLayout(width: 3840, height: 16385, format: .r12l, physicalStride: 17280))
  }

  func testHalfFloatSourceIsRefusedBeforeEncoding() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    let converter = try RecordingRGBPixelConverter(device: device)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
      width: 16, height: 2, mipmapped: false)
    let input = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 16, 2, RecordingRGBPixelConverter.outputPixelFormat,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
    XCTAssertThrowsError(try converter.convert(decodedRGB: input, sourceBitDepth: 12, into: XCTUnwrap(buffer)))
  }
}
