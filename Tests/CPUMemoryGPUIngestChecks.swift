import CoreVideo
import Darwin
import Metal
import XCTest

@objcMembers final class CPUMemoryGPUIngestChecks: XCTestCase {
  func testNDIPlanarStorageAndAlphaArePreservedOnGPU() throws { try checkNDIStorage(useCPU: false) }
  func testNDIPlanarCPUFallbackPreservesAllPlanesAndCounts() throws { try checkNDIStorage(useCPU: true) }

  private func checkNDIStorage(useCPU: Bool) throws {
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { throw XCTSkip("Metal 4 GPU required") }
    for format: UInt32 in [0x49343230, 0x50323136, 0x50413136, 0x55595641] {
      let layouts = try CPUMemoryPlaneLayout.planes(pixelFormat: format, width: 8, height: 4)
      let page = Int(getpagesize())
      let raw = UnsafeMutableRawPointer.allocate(byteCount: page, alignment: page)
      defer { raw.deallocate() }
      raw.initializeMemory(as: UInt8.self, repeating: 0, count: page)
      var offset = 0
      var planes: [CapturedCPUMemoryFrame.Plane] = []
      for (index, layout) in layouts.enumerated() {
        let stride = layout.minimumRowBytes + 8
        planes.append(.init(offset: offset, bytesPerRow: stride, height: layout.height))
        for row in 0..<layout.height {
          for column in 0..<layout.minimumRowBytes {
            raw.storeBytes(of: UInt8((index * 61 + row * 17 + column) % 251),
              toByteOffset: offset + row * stride + column, as: UInt8.self)
          }
        }
        offset += stride * layout.height
      }
      let frame = CapturedCPUMemoryFrame(pointer: raw, width: 8, height: 4, bytesPerRow: planes[0].bytesPerRow,
        allocation: NoCopyIngestAllocation(baseAddress: raw, length: page, generation: 12),
        inspectVM: { base, length in NoCopyVMRange(baseAddress: base, length: length, generation: 12) },
        frameOwner: NSObject(), pixelFormat: format, planes: planes)
      let done = expectation(description: "all native planes")
      let ingester = try CPUMemoryGPUIngest(device: device)
      let receive: @Sendable (Result<CapturedPixelBuffer, Error>) -> Void = { result in
        switch result {
        case .failure(let error): XCTFail("Format \(String(format, radix: 16)): \(error)")
        case .success(let output):
          XCTAssertEqual(CVPixelBufferGetPixelFormatType(output.value), format)
          XCTAssertEqual(CVPixelBufferGetPlaneCount(output.value), layouts.count)
          CVPixelBufferLockBaseAddress(output.value, .readOnly)
          for (index, layout) in layouts.enumerated() {
            XCTAssertEqual(CVPixelBufferGetHeightOfPlane(output.value, index), layout.height)
            let expectedWidth = format == 0x55595641 && index == 0 ? 8 : layout.width
            XCTAssertEqual(CVPixelBufferGetWidthOfPlane(output.value, index), expectedWidth)
            if let pointer = CVPixelBufferGetBaseAddressOfPlane(output.value, index)?.assumingMemoryBound(to: UInt8.self) {
              let stride = CVPixelBufferGetBytesPerRowOfPlane(output.value, index)
              for row in 0..<layout.height {
                let expected = (0..<layout.minimumRowBytes).map { UInt8((index * 61 + row * 17 + $0) % 251) }
                XCTAssertEqual(Array(UnsafeBufferPointer(start: pointer.advanced(by: row * stride), count: layout.minimumRowBytes)), expected)
              }
            } else { XCTFail("Missing output plane") }
          }
          CVPixelBufferUnlockBaseAddress(output.value, .readOnly)
        }
        done.fulfill()
      }
      if useCPU {
        var count = 0
        receive(Result { try CPUCompatibilityConverter(policy: .init(allowCPUConversion: true))
          .copyIngest(frame, metal4Available: true, onCopied: { count += 1 }) })
        XCTAssertEqual(count, 1)
      } else { ingester.ingest(frame, completion: receive) }
      wait(for: [done], timeout: 10)
    }
  }

  func testR12LFull4KAnd8KAnd16384UseBoundedEightByteViewsWithoutReadingRowPadding() throws {
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { throw XCTSkip("Metal 4 GPU required") }
    for (width, height) in [(3840, 2160), (7680, 4320), (16384, 2), (3, 3)] {
      let logical = (width * 36 + 7) / 8
      let layout = try CPUMemoryPlaneLayout.planes(pixelFormat: 0x5231324c, width: width, height: height)[0]
      XCTAssertEqual(layout.width, (logical + 7) / 8)
      XCTAssertEqual(layout.minimumRowBytes, logical)
      let stride = logical, page = Int(getpagesize())
      let length = ((1 + stride * height + page - 1) / page) * page
      let raw = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: page)
      defer { raw.deallocate() }
      raw.initializeMemory(as: UInt8.self, repeating: 0xa5, count: length)
      for row in 0..<height { raw.storeBytes(of: UInt8(row % 251), toByteOffset: 1 + row * stride + logical - 1, as: UInt8.self) }
      let frame = CapturedCPUMemoryFrame(pointer: raw.advanced(by: 1), width: width, height: height, bytesPerRow: stride,
        allocation: NoCopyIngestAllocation(baseAddress: raw, length: length, generation: 29),
        inspectVM: { base, length in NoCopyVMRange(baseAddress: base, length: length, generation: 29) }, frameOwner: NSObject(), pixelFormat: 0x5231324c)
      let done = expectation(description: "Wide packed byte preservation")
      let ingester = try CPUMemoryGPUIngest(device: device)
      ingester.ingest(frame) { result in
        switch result {
        case .failure(let error): XCTFail("R12L \(width)x\(height): \(error)")
        case .success(let output):
          XCTAssertEqual(CVPixelBufferGetWidth(output.value), width)
          XCTAssertEqual(CVPixelBufferGetHeight(output.value), height)
          CVPixelBufferLockBaseAddress(output.value, .readOnly)
          if let base = CVPixelBufferGetBaseAddress(output.value)?.assumingMemoryBound(to: UInt8.self) {
            let outputStride = CVPixelBufferGetBytesPerRow(output.value)
            XCTAssertGreaterThanOrEqual(outputStride, ((logical + 7) / 8) * 8)
            for row in 0..<height {
              let p = base.advanced(by: row * outputStride)
              XCTAssertEqual(p[0], 0xa5)
              XCTAssertEqual(p[logical - 1], UInt8(row % 251))
              if logical % 8 != 0 { XCTAssertEqual(p[logical], 0, "Partial texel must not read the next source row") }
            }
          } else { XCTFail("Missing wide R12L storage") }
          CVPixelBufferUnlockBaseAddress(output.value, .readOnly)
        }
        done.fulfill()
      }
      wait(for: [done], timeout: 15)
    }
  }

  func testNativeRGBRegistrationAndOddWidthPaddedRows() throws {
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { throw XCTSkip("Metal 4 GPU required") }
    for format: UInt32 in [0x72323130, 0x5231324c] {
      let description = try XCTUnwrap(CPUMemoryPixelFormatRegistration.packedRGBDescription(format))
      XCTAssertEqual((description[kCVPixelFormatBitsPerBlock as String] as? NSNumber)?.intValue, format == 0x72323130 ? 32 : 288)
      XCTAssertEqual((description[kCVPixelFormatBlockWidth as String] as? NSNumber)?.intValue ?? 1, format == 0x72323130 ? 1 : 8)
      let page = Int(getpagesize())
      let raw = UnsafeMutableRawPointer.allocate(byteCount: page, alignment: page)
      defer { raw.deallocate() }
      raw.initializeMemory(as: UInt8.self, repeating: 0, count: page)
      let row = format == 0x72323130 ? 12 : 14, stride = row + 7
      for y in 0..<3 { for x in 0..<row { raw.storeBytes(of: UInt8(y * 41 + x), toByteOffset: 17 + y * stride + x, as: UInt8.self) } }
      let frame = CapturedCPUMemoryFrame(pointer: raw.advanced(by: 17), width: 3, height: 3, bytesPerRow: stride,
        allocation: NoCopyIngestAllocation(baseAddress: raw, length: page, generation: 22),
        inspectVM: { base, length in NoCopyVMRange(baseAddress: base, length: length, generation: 22) }, frameOwner: NSObject(), pixelFormat: format)
      let done = expectation(description: "Odd native storage")
      try CPUMemoryPixelFormatRegistration.ensure(format)
      let ingester = try CPUMemoryGPUIngest(device: device)
      ingester.ingest(frame) { result in
        switch result {
        case .failure(let error): XCTFail(String(describing: error))
        case .success(let output):
          XCTAssertEqual(CVPixelBufferGetWidth(output.value), 3)
          XCTAssertEqual(CVPixelBufferGetHeight(output.value), 3)
          XCTAssertEqual(CVPixelBufferGetPlaneCount(output.value), 0)
          CVPixelBufferLockBaseAddress(output.value, .readOnly)
          if let p = CVPixelBufferGetBaseAddress(output.value)?.assumingMemoryBound(to: UInt8.self) {
            let stride = CVPixelBufferGetBytesPerRow(output.value)
            for y in 0..<3 { XCTAssertEqual(Array(UnsafeBufferPointer(start: p.advanced(by: y * stride), count: row)), (0..<row).map { UInt8(y * 41 + $0) }) }
          } else { XCTFail("Missing packed storage") }
          CVPixelBufferUnlockBaseAddress(output.value, .readOnly)
        }
        done.fulfill()
      }
      wait(for: [done], timeout: 10)
    }
  }

  func testNativeRGBPackingPreservesTenAndTwelveBitCodes() throws {
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { throw XCTSkip("Metal 4 GPU required") }
    for (pixelFormat, bytes) in [(UInt32(0x72323130), [UInt8(0x3f), 0xf0, 0x01, 0x55]),
                                  (UInt32(0x5231324c), [UInt8(0xff), 0x1f, 0x80, 0x55, 0x0a])] {
      let page = Int(getpagesize())
      let raw = UnsafeMutableRawPointer.allocate(byteCount: page, alignment: page)
      defer { raw.deallocate() }
      raw.initializeMemory(as: UInt8.self, repeating: 0, count: page)
      for (i, byte) in bytes.enumerated() { raw.storeBytes(of: byte, toByteOffset: i, as: UInt8.self) }
      let frame = CapturedCPUMemoryFrame(pointer: raw, width: 1, height: 1, bytesPerRow: bytes.count,
        allocation: NoCopyIngestAllocation(baseAddress: raw, length: page, generation: 11),
        inspectVM: { base, length in NoCopyVMRange(baseAddress: base, length: length, generation: 11) },
        frameOwner: NSObject(), pixelFormat: pixelFormat)
      let done = expectation(description: "native RGB preservation")
      let ingester = try CPUMemoryGPUIngest(device: device)
      ingester.ingest(frame) { result in
        switch result {
        case .failure(let error): XCTFail(String(describing: error))
        case .success(let output):
          XCTAssertEqual(CVPixelBufferGetPixelFormatType(output.value), pixelFormat)
          CVPixelBufferLockBaseAddress(output.value, .readOnly)
          if let pointer = CVPixelBufferGetBaseAddress(output.value)?.assumingMemoryBound(to: UInt8.self) {
            XCTAssertEqual(Array(UnsafeBufferPointer(start: pointer, count: bytes.count)), bytes)
          } else { XCTFail("Missing packed output") }
          CVPixelBufferUnlockBaseAddress(output.value, .readOnly)
        }
        done.fulfill()
      }
      wait(for: [done], timeout: 10)
    }
  }

  func testMetal4CopiesBGRAIntoIOSurfaceBeforePublication() throws {
    guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { throw XCTSkip("Metal 4 GPU required") }
    let page = Int(getpagesize())
    let raw = UnsafeMutableRawPointer.allocate(byteCount: page, alignment: page)
    defer { raw.deallocate() }
    raw.initializeMemory(as: UInt8.self, repeating: 0, count: page)
    let pixels = raw.assumingMemoryBound(to: UInt8.self)
    pixels[0] = 17; pixels[1] = 51; pixels[2] = 102; pixels[3] = 255
    let allocation = NoCopyIngestAllocation(baseAddress: raw, length: page, generation: 9)
    let frame = CapturedCPUMemoryFrame(pointer: raw, width: 1, height: 1, bytesPerRow: 4,
      allocation: allocation, inspectVM: { base, length in
        NoCopyVMRange(baseAddress: base, length: length, generation: 9)
      }, frameOwner: NSObject())
    let ingester = try CPUMemoryGPUIngest(device: device)
    let done = expectation(description: "GPU publication")
    ingester.ingest(frame) { result in
      switch result {
      case .failure(let error): XCTFail(String(describing: error))
      case .success(let output):
        XCTAssertNotNil(CVPixelBufferGetIOSurface(output.value))
        CVPixelBufferLockBaseAddress(output.value, .readOnly)
        if let pointer = CVPixelBufferGetBaseAddress(output.value)?.assumingMemoryBound(to: UInt8.self) {
          XCTAssertEqual(Array(UnsafeBufferPointer(start: pointer, count: 4)), [17, 51, 102, 255])
        } else { XCTFail("Missing output pixels") }
        CVPixelBufferUnlockBaseAddress(output.value, .readOnly)
      }
      done.fulfill()
    }
    wait(for: [done], timeout: 10)
  }
}
