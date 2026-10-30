import CoreMedia
import CoreVideo
import Foundation
import Metal
import IOSurface
import XCTest

@objcMembers final class ProgramScalingGPUChecks: XCTestCase {
  private final class Output: @unchecked Sendable {
    let lock = NSLock()
    private var value: CVPixelBuffer?
    func set(_ image: CVPixelBuffer) { lock.lock(); value = image; lock.unlock() }
    func get() -> CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return value }
  }

  func testRGBSourceAndProgramPQTargetConvertPixelsOnGPU() throws {
    var source: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 32, 32, kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &source), kCVReturnSuccess)
    let image = try XCTUnwrap(source)
    CVPixelBufferLockBaseAddress(image, [])
    let stride = CVPixelBufferGetBytesPerRow(image)
    let pixels = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<32 { for x in 0..<32 {
      let i = y * stride + x * 4
      pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 255; pixels[i + 3] = 255
    } }
    CVPixelBufferUnlockBaseAddress(image, [])
    let normalizer = try ProgramNormalizer()
    let pq = Colorimetry(primaries: .rec2020, transfer: .pq, matrix: .rec2020, range: .video,
      horizontalChromaSiting: .center, verticalChromaSiting: .center)
    var values: [UInt8] = []
    for colour in [Colorimetry.rec709Video, pq] {
      let done = DispatchSemaphore(value: 0)
      let result = Output()
      try normalizer.normalize(image, to: ProgramOutputFormat(width: 32, height: 32,
        pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        duration: CMTime(value: 1, timescale: 30), colour: colour)) {
        if case let .success(output) = $0 { result.set(output) }
        done.signal()
      }
      XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
      let output = try XCTUnwrap(result.get())
      CVPixelBufferLockBaseAddress(output, .readOnly)
      values.append(CVPixelBufferGetBaseAddressOfPlane(output, 0)!.assumingMemoryBound(to: UInt8.self)[0])
      CVPixelBufferUnlockBaseAddress(output, .readOnly)
      let actual = try LUTProcessor.sourceColorimetry(output)
      XCTAssertEqual(actual.primaries, colour.primaries)
      XCTAssertEqual(actual.transfer, colour.transfer)
      XCTAssertEqual(actual.matrix, colour.matrix)
    }
    XCTAssertEqual(values[0], 63, "709 saturated red is converted to legal-range luma")
    XCTAssertNotEqual(values[0], values[1], "PQ conversion must change pixels rather than just tags")
  }

  func testOddWidthRGBPreconversionPreservesImageExtentAndEdges() throws {
    var storage: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 641, 480, kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &storage), kCVReturnSuccess)
    let source = try XCTUnwrap(storage)
    CVPixelBufferLockBaseAddress(source, [])
    let bytes = CVPixelBufferGetBaseAddress(source)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(source)
    for y in 0..<480 { for x in 0..<641 {
      let i = y * stride + x * 4
      // Blue edge bands on red expose both crop/fit and the final odd pair.
      bytes[i] = x < 8 || x >= 633 ? 255 : 0
      bytes[i + 1] = 0; bytes[i + 2] = x < 8 || x >= 633 ? 0 : 255; bytes[i + 3] = 255
    } }
    CVPixelBufferUnlockBaseAddress(source, [])
    for mode in [ProgramScalingMode.fit, .crop] {
      let output = try converted(source, width: 640, height: 480, mode: mode)
      XCTAssertEqual(CVPixelBufferGetWidth(output), 640)
      XCTAssertEqual(CVPixelBufferGetHeight(output), 480)
      CVPixelBufferLockBaseAddress(output, .readOnly)
      let y = CVPixelBufferGetBaseAddressOfPlane(output, 0)!.assumingMemoryBound(to: UInt8.self)
      let row = CVPixelBufferGetBytesPerRowOfPlane(output, 0)
      XCTAssertEqual(Int(y[240 * row]), 32, accuracy: 1)
      XCTAssertEqual(Int(y[240 * row + 320]), 63, accuracy: 1)
      XCTAssertEqual(Int(y[240 * row + 639]), 32, accuracy: 1)
      // 641x480 fit occupies 640x479; padding to 642 would occupy 640x478.
      XCTAssertEqual(Int(y[478 * row + 320]), 63, accuracy: 1)
      XCTAssertEqual(Int(y[479 * row + 320]), mode == .fit ? 16 : 63, accuracy: 1)
      CVPixelBufferUnlockBaseAddress(output, .readOnly)
      XCTAssertEqual(try LUTProcessor.sourceColorimetry(output), Colorimetry(primaries: .rec709,
        transfer: .rec709, matrix: .rec709, range: .video, horizontalChromaSiting: .center, verticalChromaSiting: .center))
    }
  }

  func testOddWidth420WorksWithMatchingAndConvertedColour() throws {
    let source = try chromaFixture(width: 641, height: 480, colour: .rec709Video,
      cb: { x, _ in x >= 317 ? 192 : 128 })
    let pq = Colorimetry(primaries: .rec2020, transfer: .pq, matrix: .rec2020, range: .video,
      horizontalChromaSiting: .center, verticalChromaSiting: .center)
    for colour in [Colorimetry.rec709Video, pq] {
      let output = try converted(source, width: 640, height: 480, colour: colour)
      XCTAssertEqual(CVPixelBufferGetWidth(output), 640)
      XCTAssertEqual(CVPixelBufferGetHeight(output), 480)
      let actual = try LUTProcessor.sourceColorimetry(output)
      XCTAssertEqual(actual.primaries, colour.primaries)
      XCTAssertEqual(actual.transfer, colour.transfer)
      XCTAssertEqual(actual.matrix, colour.matrix)
      XCTAssertEqual(actual.range, .video)
      XCTAssertEqual(actual.horizontalChromaSiting, .center)
      XCTAssertEqual(actual.verticalChromaSiting, .center)
      XCTAssertGreaterThan(chroma(output, x: 319, y: 120), chroma(output, x: 160, y: 120))
    }
  }

  func testPackedSourcesExecuteThroughProgramOutput() throws {
    for type: OSType in [0x32767579, 0x79757673, 0x72323130, 0x5231324c] {
      var storage: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferCreate(nil, 128, 64, type,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &storage), kCVReturnSuccess)
      let image = try XCTUnwrap(storage)
      CVPixelBufferLockBaseAddress(image, [])
      let stride = CVPixelBufferGetBytesPerRow(image)
      let bytes = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
      memset(bytes, 0, stride * 64)
      for y in 0..<64 { for x in 0..<128 {
        let row = y * stride
        if type == 0x72323130 {
          for (i, value) in [UInt8(0x3a), 0xc1, 0x00, 0x40].enumerated() { bytes[row + x * 4 + i] = value }
        } else if type == 0x5231324c {
          for bit in 0..<12 { let offset = x * 36 + bit; bytes[row + offset / 8] |= UInt8(1 << (offset % 8)) }
        } else {
          bytes[row + x * 2] = type == 0x32767579 ? 128 : 100
          bytes[row + x * 2 + 1] = type == 0x32767579 ? 100 : 128
        }
      } }
      CVPixelBufferUnlockBaseAddress(image, [])
      let normalizer = try ProgramNormalizer()
      let done = DispatchSemaphore(value: 0)
      let result = Output()
      try normalizer.normalize(image, to: ProgramOutputFormat(width: 128, height: 64,
        pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        duration: CMTime(value: 1, timescale: 30))) {
        if case let .success(output) = $0 { result.set(output) }
        done.signal()
      }
      XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
      let output = try XCTUnwrap(result.get())
      CVPixelBufferLockBaseAddress(output, .readOnly)
      let value = CVPixelBufferGetBaseAddressOfPlane(output, 0)!.assumingMemoryBound(to: UInt8.self)[0]
      XCTAssertEqual(value, type == 0x72323130 || type == 0x5231324c ? 63 : 100)
      CVPixelBufferUnlockBaseAddress(output, .readOnly)
    }
  }

  func testProgramByteBudgetDeduplicatesPlanesAndRetainsInFlightStorage() throws {
    var source: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &source), kCVReturnSuccess)
    let image = try XCTUnwrap(source)
    let tiny = try ProgramNormalizer(cacheMaximumBytes: 1)
    let format = ProgramOutputFormat(width: 64, height: 64,
      pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, duration: CMTime(value: 1, timescale: 30))
    XCTAssertThrowsError(try tiny.normalize(image, to: format) { _ in })
    var largeStorage: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 512, 512, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &largeStorage), kCVReturnSuccess)
    let large = try XCTUnwrap(largeStorage)
    let backing = try XCTUnwrap(CVPixelBufferGetIOSurface(large)?.takeUnretainedValue())
    let pressure = try ProgramNormalizer(cacheMaximumBytes: IOSurfaceGetAllocSize(backing))
    XCTAssertThrowsError(try pressure.normalize(large, to: format) { _ in })
    XCTAssertEqual(pressure.allocationSnapshot.bytes, 0, "A refused uncommitted encode releases its cache leases")
    let normalizer = try ProgramNormalizer()
    let gate = try XCTUnwrap(MTLCreateSystemDefaultDevice()?.makeSharedEvent())
    normalizer.waitForTesting(gate, value: 1)
    defer { gate.signaledValue = 1 }
    let done = DispatchSemaphore(value: 0)
    try normalizer.normalize(image, to: format) { _ in done.signal() }
    let pending = normalizer.allocationSnapshot
    XCTAssertEqual(pending.allocations, 2, "Source and destination charge once each despite two plane views")
    XCTAssertEqual(pending.leases, 4)
    normalizer.releaseIdleResources()
    XCTAssertEqual(normalizer.allocationSnapshot.bytes, pending.bytes, "GPU-pending surfaces survive idle eviction")
    gate.signaledValue = 1
    XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
    normalizer.releaseIdleResources()
    XCTAssertEqual(normalizer.allocationSnapshot.bytes, 0)
  }

  func testFullRange420SourceIsConvertedToVideoBlack() throws {
    var storage: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &storage), kCVReturnSuccess)
    let source = try XCTUnwrap(storage)
    CVPixelBufferLockBaseAddress(source, [])
    for plane in 0..<2 { memset(CVPixelBufferGetBaseAddressOfPlane(source, plane)!, plane == 0 ? 0 : 128,
      CVPixelBufferGetBytesPerRowOfPlane(source, plane) * CVPixelBufferGetHeightOfPlane(source, plane)) }
    CVPixelBufferUnlockBaseAddress(source, [])
    let normalizer = try ProgramNormalizer()
    let done = DispatchSemaphore(value: 0)
    let result = Output()
    try normalizer.normalize(source, to: ProgramOutputFormat(width: 64, height: 64,
      pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, duration: CMTime(value: 1, timescale: 30))) {
      if case let .success(output) = $0 { result.set(output) }; done.signal()
    }
    XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
    let output = try XCTUnwrap(result.get())
    CVPixelBufferLockBaseAddress(output, .readOnly)
    XCTAssertEqual(CVPixelBufferGetBaseAddressOfPlane(output, 0)!.assumingMemoryBound(to: UInt8.self)[0], 16)
    CVPixelBufferUnlockBaseAddress(output, .readOnly)
  }

  func testNDIPlanarAndAlphaSourcesExecuteThroughProgramOutput() throws {
    for type: OSType in [0x55595641, 0x49343230, 0x50413136, 0x50323136] {
      try CPUMemoryPixelFormatRegistration.ensure(type)
      var storage: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferCreate(nil, 128, 64, type,
        [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true,
         kCVPixelBufferBytesPerRowAlignmentKey: 256] as CFDictionary, &storage), kCVReturnSuccess)
      let source = try XCTUnwrap(storage)
      try VideoBufferLayout.validate(source)
      CVPixelBufferLockBaseAddress(source, [])
      for plane in 0..<CVPixelBufferGetPlaneCount(source) {
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(source, plane))
        let stride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
        let rows = CVPixelBufferGetHeightOfPlane(source, plane)
        memset(base, 0, stride * rows)
        if type == 0x55595641 {
          if plane == 0 { for row in 0..<rows { for x in 0..<128 {
            base.storeBytes(of: UInt8(128), toByteOffset: row * stride + x * 2, as: UInt8.self)
            base.storeBytes(of: UInt8(126), toByteOffset: row * stride + x * 2 + 1, as: UInt8.self)
          } } }
        } else if type == 0x49343230 { memset(base, plane == 0 ? 126 : 128, stride * rows) }
        else {
          let samples = base.assumingMemoryBound(to: UInt16.self)
          for index in 0..<(stride * rows / 2) { samples[index] = plane == 0 ? 32128 : (plane == 1 ? 32768 : 0) }
        }
      }
      CVPixelBufferUnlockBaseAddress(source, [])
      let normalizer = try ProgramNormalizer()
      let done = DispatchSemaphore(value: 0)
      let result = Output()
      try normalizer.normalize(source, to: ProgramOutputFormat(width: 64, height: 32,
        pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, duration: CMTime(value: 1, timescale: 30))) {
        if case let .success(output) = $0 { result.set(output) }; done.signal()
      }
      XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
      let output = try XCTUnwrap(result.get())
      CVPixelBufferLockBaseAddress(output, .readOnly)
      XCTAssertEqual(Int(CVPixelBufferGetBaseAddressOfPlane(output, 0)!.assumingMemoryBound(to: UInt8.self)[0]), 126, accuracy: 1)
      CVPixelBufferUnlockBaseAddress(output, .readOnly)
      XCTAssertEqual(CVPixelBufferGetPixelFormatType(source), type, "Normalization must not mutate source format identity")
    }
  }

  private func chromaFixture(width: Int, height: Int, colour: Colorimetry,
                             cb: (Int, Int) -> UInt8, cr: UInt8 = 128) throws -> CVPixelBuffer {
    var storage: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &storage), kCVReturnSuccess)
    let source = try XCTUnwrap(storage)
    CVPixelBufferLockBaseAddress(source, [])
    memset(CVPixelBufferGetBaseAddressOfPlane(source, 0)!, 100, CVPixelBufferGetBytesPerRowOfPlane(source, 0) * height)
    let uv = CVPixelBufferGetBaseAddressOfPlane(source, 1)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(source, 1)
    for y in 0..<((height + 1) / 2) { for x in 0..<((width + 1) / 2) {
      uv[y * stride + x * 2] = cb(x, y); uv[y * stride + x * 2 + 1] = cr
    } }
    CVPixelBufferUnlockBaseAddress(source, [])
    LUTProcessor.stampDeclaredColorimetry(colour, on: source)
    return source
  }

  private func converted(_ source: CVPixelBuffer, width: Int, height: Int,
                         mode: ProgramScalingMode = .fit, colour: Colorimetry = .rec709Video) throws -> CVPixelBuffer {
    let normalizer = try ProgramNormalizer()
    let done = DispatchSemaphore(value: 0), result = Output()
    try normalizer.normalize(source, to: ProgramOutputFormat(width: width, height: height,
      pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      duration: CMTime(value: 1, timescale: 30), scalingMode: mode, colour: colour)) {
      if case let .success(output) = $0 { result.set(output) }; done.signal()
    }
    XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
    return try XCTUnwrap(result.get())
  }

  private func chroma(_ image: CVPixelBuffer, x: Int, y: Int) -> UInt8 {
    CVPixelBufferLockBaseAddress(image, .readOnly); defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
    return CVPixelBufferGetBaseAddressOfPlane(image, 1)!.assumingMemoryBound(to: UInt8.self)[y * CVPixelBufferGetBytesPerRowOfPlane(image, 1) + x * 2]
  }

  func testAuthoritativeColourAndVerticalChromaSitingAreNormalizedTogether() throws {
    let target = ProgramOutputFormat(width: 16, height: 16,
      pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, duration: CMTime(value: 1, timescale: 30))
    func declaration(_ vertical: Colorimetry.ChromaSiting) -> Colorimetry {
      Colorimetry(primaries: .rec709, transfer: .rec709, matrix: .rec709, range: .video,
        horizontalChromaSiting: .center, verticalChromaSiting: vertical)
    }
    let center = try chromaFixture(width: 16, height: 16, colour: declaration(.center), cb: { _, y in UInt8(64 + min(y, 2) * 64) })
    let top = try chromaFixture(width: 16, height: 16, colour: declaration(.top), cb: { _, y in UInt8(64 + min(y, 2) * 64) })
    CVBufferRemoveAttachment(top, LUTProcessor.declaredColorimetryAttachmentKey) // Also prove standard Top-only metadata.
    let bottom = try chromaFixture(width: 16, height: 16, colour: declaration(.bottom), cb: { _, y in UInt8(64 + min(y, 2) * 64) })
    XCTAssertFalse(target.matchesColourAndAspect(top))
    XCTAssertFalse(target.matchesColourAndAspect(bottom))
    let centered = try converted(center, width: 16, height: 16)
    let fromTop = try converted(top, width: 16, height: 16)
    let fromBottom = try converted(bottom, width: 16, height: 16)
    XCTAssertEqual(chroma(centered, x: 0, y: 0), 64)
    XCTAssertEqual(chroma(fromTop, x: 0, y: 0), 80)
    XCTAssertEqual(chroma(fromBottom, x: 0, y: 1), 112)
    for output in [centered, fromTop, fromBottom] {
      XCTAssertEqual(try LUTProcessor.sourceColorimetry(output), target.colour)
      XCTAssertTrue(target.matchesColourAndAspect(output))
    }
    let left = Colorimetry(primaries: .rec709, transfer: .rec709, matrix: .rec709, range: .video,
      horizontalChromaSiting: .left, verticalChromaSiting: .center)
    let source = try chromaFixture(width: 16, height: 16, colour: left, cb: { x, _ in UInt8(64 + min(x, 2) * 64) })
    let recentered = try converted(source, width: 16, height: 16)
    XCTAssertEqual(chroma(recentered, x: 0, y: 0), 80)
    XCTAssertEqual(try LUTProcessor.sourceColorimetry(recentered), target.colour)
    XCTAssertTrue(target.matchesColourAndAspect(recentered))
    var fullStorage: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &fullStorage), kCVReturnSuccess)
    let full = try XCTUnwrap(fullStorage)
    CVPixelBufferLockBaseAddress(full, [])
    for plane in 0..<2 {
      let values = CVPixelBufferGetBaseAddressOfPlane(full, plane)!.assumingMemoryBound(to: UInt16.self)
      let count = CVPixelBufferGetBytesPerRowOfPlane(full, plane) * CVPixelBufferGetHeightOfPlane(full, plane) / 2
      for index in 0..<count { values[index] = UInt16(512) << 6 }
    }
    CVPixelBufferUnlockBaseAddress(full, [])
    LUTProcessor.stampDeclaredColorimetry(Colorimetry(primaries: .rec709, transfer: .rec709, matrix: .rec709,
      range: .full, horizontalChromaSiting: .center, verticalChromaSiting: .center), on: full)
    let video = try converted(full, width: 16, height: 16)
    XCTAssertEqual(try LUTProcessor.sourceColorimetry(video), target.colour)
    XCTAssertTrue(target.matchesColourAndAspect(video))
    CVPixelBufferLockBaseAddress(video, .readOnly)
    XCTAssertEqual(CVPixelBufferGetBaseAddressOfPlane(video, 0)!.assumingMemoryBound(to: UInt8.self)[0], 126)
    CVPixelBufferUnlockBaseAddress(video, .readOnly)
  }

  func testOddFitAndCropOriginsPreserveChromaPhaseAtColoredEdges() throws {
    let colour = Colorimetry(primaries: .rec709, transfer: .rec709, matrix: .rec709, range: .video,
      horizontalChromaSiting: .center, verticalChromaSiting: .center)
    let portrait = try chromaFixture(width: 32, height: 64, colour: colour, cb: { _, _ in 64 }, cr: 192)
    let pillar = try converted(portrait, width: 66, height: 64)
    XCTAssertEqual(chroma(pillar, x: 7, y: 0), 128)
    XCTAssertEqual(chroma(pillar, x: 8, y: 0), 96, "Odd origin17 covers half of chroma cell16...17")
    XCTAssertEqual(chroma(pillar, x: 9, y: 0), 64)
    let landscape = try chromaFixture(width: 64, height: 32, colour: colour, cb: { _, _ in 64 })
    let letter = try converted(landscape, width: 64, height: 66)
    XCTAssertEqual(chroma(letter, x: 0, y: 7), 128)
    XCTAssertEqual(chroma(letter, x: 0, y: 8), 96)
    XCTAssertEqual(chroma(letter, x: 0, y: 9), 64)
    let edge = try chromaFixture(width: 64, height: 32, colour: colour, cb: { x, _ in UInt8(64 + min(x, 2) * 64) })
    let crop = try converted(edge, width: 62, height: 32, mode: .crop)
    XCTAssertEqual(chroma(crop, x: 0, y: 0), 96, "Crop origin-1 retains the half-chroma phase")
  }

  func testOddSourceChromaUsesImageExtentRatherThanRoundedPlaneExtent() throws {
    for (horizontal, vertical) in [(Colorimetry.ChromaSiting.center, Colorimetry.ChromaSiting.center), (.left, .top)] {
      let colour = Colorimetry(primaries: .rec709, transfer: .rec709, matrix: .rec709, range: .video,
        horizontalChromaSiting: horizontal, verticalChromaSiting: vertical)
      let oddWidth = try chromaFixture(width: 3, height: 4, colour: colour, cb: { x, _ in x == 0 ? 64 : 192 })
      let wide = try converted(oddWidth, width: 6, height: 8)
      let expected: [UInt8] = horizontal == .center ? [64, 96, 160] : [64, 128, 192]
      for x in 0..<3 { XCTAssertEqual(chroma(wide, x: x, y: 0), expected[x]) }
      let oddHeight = try chromaFixture(width: 4, height: 3, colour: colour, cb: { _, y in y == 0 ? 64 : 192 })
      let tall = try converted(oddHeight, width: 8, height: 6)
      let expectedY: [UInt8] = vertical == .center ? [64, 96, 160] : [64, 128, 192]
      for y in 0..<3 { XCTAssertEqual(chroma(tall, x: 0, y: y), expectedY[y]) }
    }
  }

  func testDeclaredCodeRangeOverridesSourceFourCCDefaults() throws {
    for (pixel, range, black, white) in [
      (kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, Colorimetry.Range.full, UInt16(0), UInt16(1023)),
      (kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, Colorimetry.Range.video, UInt16(64), UInt16(940))] {
      var storage: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, pixel,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &storage), kCVReturnSuccess)
      let source = try XCTUnwrap(storage)
      CVPixelBufferLockBaseAddress(source, [])
      for plane in 0..<2 {
        let samples = CVPixelBufferGetBaseAddressOfPlane(source, plane)!.assumingMemoryBound(to: UInt16.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(source, plane) / 2
        for y in 0..<16 { for x in 0..<16 { samples[y * stride + x] = (plane == 1 ? 512 : (x < 8 ? black : white)) << 6 } }
      }
      CVPixelBufferUnlockBaseAddress(source, [])
      LUTProcessor.stampDeclaredColorimetry(Colorimetry(primaries: .rec709, transfer: .rec709, matrix: .rec709,
        range: range, horizontalChromaSiting: .center, verticalChromaSiting: .center), on: source)
      let output = try converted(source, width: 16, height: 16)
      CVPixelBufferLockBaseAddress(output, .readOnly)
      let y = CVPixelBufferGetBaseAddressOfPlane(output, 0)!.assumingMemoryBound(to: UInt8.self)
      XCTAssertEqual(Int(y[0]), 16)
      XCTAssertEqual(Int(y[15]), 235)
      CVPixelBufferUnlockBaseAddress(output, .readOnly)
      XCTAssertEqual(try LUTProcessor.sourceColorimetry(output).range, .video)
    }
    let full8 = Colorimetry(primaries: .rec709, transfer: .rec709, matrix: .rec709, range: .full,
      horizontalChromaSiting: .center, verticalChromaSiting: .center)
    let image = try chromaFixture(width: 16, height: 16, colour: full8, cb: { _, _ in 128 })
    CVPixelBufferLockBaseAddress(image, [])
    let pixels = CVPixelBufferGetBaseAddressOfPlane(image, 0)!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<16 { for x in 0..<16 { pixels[y * CVPixelBufferGetBytesPerRowOfPlane(image, 0) + x] = x < 8 ? 0 : 255 } }
    CVPixelBufferUnlockBaseAddress(image, [])
    let video = try converted(image, width: 16, height: 16)
    CVPixelBufferLockBaseAddress(video, .readOnly)
    let result = CVPixelBufferGetBaseAddressOfPlane(video, 0)!.assumingMemoryBound(to: UInt8.self)
    XCTAssertEqual(result[0], 16); XCTAssertEqual(result[15], 235)
    CVPixelBufferUnlockBaseAddress(video, .readOnly)
  }

  func testPortraitFitsWithBlackPillarboxAndCropFills() throws {
    var source: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 32, 64, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &source), kCVReturnSuccess)
    let image = try XCTUnwrap(source)
    CVPixelBufferLockBaseAddress(image, [])
    for plane in 0..<2 {
      memset(CVPixelBufferGetBaseAddressOfPlane(image, plane)!, plane == 0 ? 100 : 128,
        CVPixelBufferGetBytesPerRowOfPlane(image, plane) * CVPixelBufferGetHeightOfPlane(image, plane))
    }
    CVPixelBufferUnlockBaseAddress(image, [])
    for mode in [ProgramScalingMode.fit, .crop] {
      let normalizer = try ProgramNormalizer()
      let done = DispatchSemaphore(value: 0)
      let result = Output()
      try normalizer.normalize(image, to: ProgramOutputFormat(width: 64, height: 64,
        pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, duration: CMTime(value: 1, timescale: 30), scalingMode: mode)) {
        if case let .success(output) = $0 { result.set(output) }
        done.signal()
      }
      XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
      let output = try XCTUnwrap(result.get())
      CVPixelBufferLockBaseAddress(output, .readOnly)
      let y = CVPixelBufferGetBaseAddressOfPlane(output, 0)!.assumingMemoryBound(to: UInt8.self)
      XCTAssertEqual(Int(y[0]), mode == .fit ? 16 : 100)
      XCTAssertEqual(Int(y[32]), 100)
      CVPixelBufferUnlockBaseAddress(output, .readOnly)
    }
  }
}
