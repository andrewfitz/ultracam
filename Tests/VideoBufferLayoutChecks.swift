import CoreVideo
import XCTest

@objcMembers final class VideoBufferLayoutChecks: XCTestCase {
  func testNDIThreePlaneAndAlphaStorageRequiresEveryPhysicalPlane() throws {
    for (type, planes, storage) in [(UInt32(0x55595641),
      [VideoBufferLayout.Plane(width: 8, height: 4, rowBytes: 16), .init(width: 8, height: 4, rowBytes: 8)], 96),
      (0x49343230, [.init(width: 8, height: 4, rowBytes: 8), .init(width: 4, height: 2, rowBytes: 4), .init(width: 4, height: 2, rowBytes: 4)], 48),
      (0x50413136, [.init(width: 8, height: 4, rowBytes: 16), .init(width: 4, height: 4, rowBytes: 16), .init(width: 8, height: 4, rowBytes: 16)], 192)] {
      var metadata = VideoBufferLayout.Metadata(width: 8, height: 4, pixelFormat: type,
        isPlanar: true, rowBytes: 0, dataSize: storage, planes: planes)
      XCTAssertNoThrow(try VideoBufferLayout.validate(metadata))
      metadata.planes.removeLast()
      XCTAssertThrowsError(try VideoBufferLayout.validate(metadata))
      metadata.planes = planes; metadata.planes[planes.count - 1].rowBytes -= 1
      XCTAssertThrowsError(try VideoBufferLayout.validate(metadata))
      metadata.planes = planes; metadata.dataSize -= 1
      XCTAssertThrowsError(try VideoBufferLayout.validate(metadata))
      metadata.dataSize = 0; metadata.planes[0].rowBytes = Int.max - 1
      XCTAssertThrowsError(try VideoBufferLayout.validate(metadata))
    }
    let odd = VideoBufferLayout.Metadata(width: 5, height: 3, pixelFormat: 0x49343230,
      isPlanar: true, rowBytes: 0, dataSize: 27,
      planes: [.init(width: 5, height: 3, rowBytes: 5), .init(width: 3, height: 2, rowBytes: 3), .init(width: 3, height: 2, rowBytes: 3)])
    XCTAssertNoThrow(try VideoBufferLayout.validate(odd))
  }

  func testCoreVideoPackedAndPlanarMetadata() throws {
    for type in [kCVPixelFormatType_422YpCbCr8, kCVPixelFormatType_422YpCbCr8_yuvs,
      kCVPixelFormatType_32BGRA,
      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] {
      var image: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferCreate(nil, 64, 32, type, nil, &image), kCVReturnSuccess)
      XCTAssertNoThrow(try VideoBufferLayout.validate(XCTUnwrap(image)))
    }
  }
  func testPackedRowsRejectShortStorageAndOverflow() throws {
    for (type, stride) in [(UInt32(0x32767579), 12), (0x79757673, 12),
      (0x42475241, 20), (0x52474241, 20), (0x72323130, 20), (0x5231324c, 23)] {
      let metadata = VideoBufferLayout.Metadata(width: 5, height: 3, pixelFormat: type,
        isPlanar: false, rowBytes: stride, dataSize: stride * 3, planes: [])
      XCTAssertNoThrow(try VideoBufferLayout.validate(metadata))
      var short = metadata; short.rowBytes -= 1
      XCTAssertThrowsError(try VideoBufferLayout.validate(short))
      short = metadata; short.dataSize -= 1
      XCTAssertThrowsError(try VideoBufferLayout.validate(short))
      short = metadata; short.height = Int.max
      XCTAssertThrowsError(try VideoBufferLayout.validate(short))
    }
  }
  func testPlanarGeometryStridesAndAggregateAllocation() throws {
    for (type, bytes, rows) in [(UInt32(0x34323066), 1, 2), (0x50323136, 2, 3)] {
      let planes = [VideoBufferLayout.Plane(width: 5, height: 3, rowBytes: 5 * bytes),
        VideoBufferLayout.Plane(width: 3, height: rows, rowBytes: 6 * bytes)]
      var metadata = VideoBufferLayout.Metadata(width: 5, height: 3, pixelFormat: type,
        isPlanar: true, rowBytes: 0, dataSize: (15 + 6 * rows) * bytes, planes: planes)
      XCTAssertNoThrow(try VideoBufferLayout.validate(metadata))
      metadata.dataSize -= 1
      XCTAssertThrowsError(try VideoBufferLayout.validate(metadata))
      metadata.dataSize = 0; metadata.planes[1].width = 2
      XCTAssertThrowsError(try VideoBufferLayout.validate(metadata))
      metadata.planes = planes; metadata.planes[1].rowBytes -= 1
      XCTAssertThrowsError(try VideoBufferLayout.validate(metadata))
      metadata.planes = planes; metadata.planes[1].rowBytes = Int.max
      XCTAssertThrowsError(try VideoBufferLayout.validate(metadata))
    }
  }
}
