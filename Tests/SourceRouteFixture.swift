import CoreMedia
import CoreVideo
import Foundation
import XCTest

/// Test-only CPU pattern construction; the production path receives an IOSurface.
struct SourceRouteFixture {
  let image: CVPixelBuffer
  let format: SourceFormat

  init(pixel: PixelFormatID) throws {
    let rgb = [PixelFormatID.bgra8, .r210, .r12L].contains(pixel)
    let colour = Colorimetry(primaries: .rec709, transfer: .rec709,
      matrix: rgb ? .identity : .rec709,
      range: [.full420, .bgra8, .r12L].contains(pixel) ? .full : .video,
      horizontalChromaSiting: rgb ? .unspecified : .center,
      verticalChromaSiting: rgb ? .unspecified : .center)
    format = try SourceFormat(width: 128, height: 72, pixel: pixel, colour: colour,
      rate: .constant(VideoContract.fastDuration))
    if pixel == .r210 || pixel == .r12L {
      let base = try XCTUnwrap(CVPixelFormatDescriptionCreateWithPixelFormatType(nil, kCVPixelFormatType_32BGRA))
      var descriptor = base as! [String: Any]
      descriptor[kCVPixelFormatConstant as String] = pixel.rawValue
      descriptor[kCVPixelFormatBitsPerBlock as String] = pixel == .r12L ? 36 : 32
      CVPixelFormatDescriptionRegisterDescriptionWithPixelFormatType(descriptor as CFDictionary, pixel.rawValue)
    }
    if [.uyva, .p216, .i420, .pa16].contains(pixel) {
      try CPUMemoryPixelFormatRegistration.ensure(pixel.rawValue)
    }
    var made: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(nil, 128, 72, pixel.rawValue,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true, kCVPixelBufferBytesPerRowAlignmentKey: 256] as CFDictionary, &made), kCVReturnSuccess)
    image = try XCTUnwrap(made)
    XCTAssertNotNil(CVPixelBufferGetIOSurface(image))
    CVPixelBufferLockBaseAddress(image, [])
    defer { CVPixelBufferUnlockBaseAddress(image, []) }
    if CVPixelBufferIsPlanar(image) {
      for plane in 0..<CVPixelBufferGetPlaneCount(image) {
        let p = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(image, plane)).assumingMemoryBound(to: UInt8.self)
        let count = CVPixelBufferGetBytesPerRowOfPlane(image, plane) * CVPixelBufferGetHeightOfPlane(image, plane)
        if pixel == .p216 || pixel == .pa16 {
          let words = UnsafeMutableRawPointer(p).assumingMemoryBound(to: UInt16.self)
          for i in 0..<(count / 2) {
            words[i] = plane == 0 ? 32128 : (plane == 1 ? 32768 : (i.isMultiple(of: 2) ? 0 : 65535))
          }
        } else if pixel == .uyva {
          for i in 0..<count { p[i] = plane == 0 ? (i.isMultiple(of: 2) ? 128 : 126) : (i.isMultiple(of: 2) ? 0 : 255) }
        } else {
          p.initialize(repeating: plane == 0 ? (pixel == .full420 ? 128 : 126) : 128, count: count)
        }
      }
    } else {
      let p = try XCTUnwrap(CVPixelBufferGetBaseAddress(image)).assumingMemoryBound(to: UInt8.self)
      let stride = CVPixelBufferGetBytesPerRow(image)
      p.initialize(repeating: 0, count: stride * 72)
      for row in 0..<72 { for x in 0..<128 {
        let offset = row * stride
        if pixel == .r12L {
          for c in 0..<3 { for bit in 0..<12 {
            let position = x * 36 + c * 12 + bit
            if (x < 32 ? (c == 0 ? 4095 : 0) : 2048) & (1 << bit) != 0 { p[offset + position / 8] |= UInt8(1 << (position % 8)) }
          } }
        } else if pixel == .r210 {
          let word = x < 32 ? UInt32(940 << 20 | 64 << 10 | 64) : UInt32(502 << 20 | 502 << 10 | 502)
          for b in 0..<4 { p[offset + x * 4 + b] = UInt8((word >> UInt32(24 - b * 8)) & 255) }
        } else if pixel == .bgra8 {
          for c in 0..<4 { p[offset + x * 4 + c] = c == 3 ? 255 : (x < 32 ? (c == 2 ? 255 : 0) : 128) }
        } else {
          p[offset + x * 2] = pixel == .twoVuy ? 128 : 126
          p[offset + x * 2 + 1] = pixel == .twoVuy ? 126 : 128
        }
      } }
    }
  }
}
