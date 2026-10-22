import CoreVideo
@preconcurrency import Metal
import MonitorToolsCore
import XCTest
@testable import MonitorToolsMetal

final class SourcePictureGeometryTests: XCTestCase {
  private final class Image: @unchecked Sendable {
    var bytes = [UInt8]()
    var width = 0
    var height = 0
  }
  private let mappings: [MonitorCorrespondence] = [
    .init(scaleX: 0.5, scaleY: 0.5, offsetX: 0, offsetY: 0),
    .init(scaleX: 0.5, scaleY: 0.5, offsetX: -4, offsetY: -2),
  ]

  func testSourceFocusStaysOnSourceEdgesWhenProcessedOutputIsScaledOrCropped() throws {
    for format in [kCVPixelFormatType_32BGRA, kCVPixelFormatType_422YpCbCr10] {
      let source = try fixture(format: format, width: 192, height: 96, patterned: true)
      let output = try fixture(format: format, width: 96, height: 48, patterned: false)
      var config = MonitorConfiguration()
      config.toolsEnabled = true
      config.pictureStage = .source
      config.focus.enabled = true
      config.focus.color = .yellow
      config.focus.opacity = 1
      let reference = try render(source: source, output: source, mapping: .identity, config: config)
      let edge = (55 * reference.width + 95) * 4
      XCTAssertEqual(Array(reference.bytes[edge..<edge + 3]), [0, 255, 255])
      for mapping in mappings {
        let actual = try render(source: source, output: output, mapping: mapping, config: config)
        assertSameImage(actual, reference,
          "Source focus must ignore the processed-output transform (format \(format), \(mapping))")
      }
    }
  }

  func testSourceFalseColorClassifiesTheDisplayedSourcePixelWithScaledOrCroppedOutput() throws {
    for format in [kCVPixelFormatType_32BGRA, kCVPixelFormatType_422YpCbCr10] {
      let source = try fixture(format: format, width: 192, height: 96, patterned: true)
      let output = try fixture(format: format, width: 96, height: 48, patterned: false)
      var config = MonitorConfiguration()
      config.toolsEnabled = true
      config.pictureStage = .source
      config.sourceProfileID = ARRIFalseColorProfile.logC3EI800.rawValue
      config.falseColor.mode = .arri
      config.falseColor.profileID = ARRIFalseColorProfile.logC3EI800.rawValue
      let reference = try render(source: source, output: source, mapping: .identity, config: config)
      let patch = (55 * reference.width + 110) * 4
      XCTAssertEqual(Array(reference.bytes[patch..<patch + 3]), [0, 0, 255])
      for mapping in mappings {
        let actual = try render(source: source, output: output, mapping: mapping, config: config)
        assertSameImage(actual, reference,
          "Source false color must classify its own pixel (format \(format), \(mapping))")
      }
    }
  }

  func testProcessedPictureKeepsSourceFocusMappedToTheDownscaledOutput() throws {
    let source = try fixture(format: kCVPixelFormatType_422YpCbCr10,
      width: 192, height: 96, patterned: true)
    let output = try fixture(format: kCVPixelFormatType_32BGRA,
      width: 96, height: 48, patterned: false)
    var config = MonitorConfiguration()
    config.toolsEnabled = true
    config.focus.enabled = true
    config.focus.color = .yellow
    config.focus.opacity = 1
    let actual = try render(source: source, output: output, mapping: mappings[0], config: config)
    XCTAssertEqual(actual.width, 96)
    // Pixel-center mapping samples source (96,54) at output (48,27).
    let edge = (27 * actual.width + 48) * 4
    XCTAssertEqual(Array(actual.bytes[edge..<edge + 3]), [0, 255, 255])
    let flat = (10 * actual.width + 10) * 4
    XCTAssertEqual(actual.bytes[flat], actual.bytes[flat + 2])
  }

  private func fixture(format: OSType, width: Int, height: Int, patterned: Bool) throws -> CVPixelBuffer {
    var result: CVPixelBuffer?
    _ = try XCTUnwrap(CVPixelBufferCreate(nil, width, height, format,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result) == kCVReturnSuccess ? result : nil)
    let buffer = try XCTUnwrap(result)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    memset(base, 0, CVPixelBufferGetDataSize(buffer))
    func bright(_ x: Int, _ y: Int) -> Bool {
      patterned && ((96..<144).contains(x) && (48..<72).contains(y)
        || x == width - 1 && y >= height - 8 || y == height - 1 && x >= width - 16)
    }
    for y in 0..<height {
      if format == kCVPixelFormatType_32BGRA {
        let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
        for x in 0..<width {
          let value: UInt8 = bright(x, y) ? 244 : 100
          row[x * 4] = value; row[x * 4 + 1] = value; row[x * 4 + 2] = value
          row[x * 4 + 3] = 255
        }
      } else {
        let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
        for x in Swift.stride(from: 0, to: width, by: 6) {
          let v = (0..<6).map { bright(x + $0, y) ? UInt32(980) : UInt32(400) }
          let i = x / 6 * 4
          row[i] = 512 | (v[0] << 10) | (512 << 20)
          row[i + 1] = v[1] | (512 << 10) | (v[2] << 20)
          row[i + 2] = 512 | (v[3] << 10) | (512 << 20)
          row[i + 3] = v[4] | (512 << 10) | (v[5] << 20)
        }
      }
    }
    return buffer
  }

  private func render(source: CVPixelBuffer, output: CVPixelBuffer,
    mapping: MonitorCorrespondence, config: MonitorConfiguration) throws -> Image {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
    let runtime = MonitorRuntime()
    let stamp = MonitorFrameStamp(target: MonitorTargetID("source-geometry"), generation: 1,
      sequence: 1, sourcePTS: 1, hostTime: 1, configurationRevision: 1)
    let profile = config.sourceProfileID
    let signal = MonitorFrameSignal(range: .full, matrix: .bt709,
      transfer: profile ?? "rec709", profileID: profile)
    let image = Image()
    let displayed = try runtime.renderSnapshot(MonitorFrameBundle(stamp: stamp, source: source, output: output,
      correspondence: mapping, sourceSignal: signal,
      outputSignal: MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "rec709")),
      configuration: config.normalized())
    XCTAssertTrue(displayed.availability.isEmpty, "\(displayed.availability)")
    image.width = displayed.width
    image.height = displayed.height
    image.bytes = displayed.pictureBytes
    XCTAssertFalse(image.bytes.isEmpty)
    return image
  }

  private func assertSameImage(_ actual: Image, _ reference: Image, _ message: String,
    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual.width, reference.width, file: file, line: line)
    XCTAssertEqual(actual.height, reference.height, file: file, line: line)
    XCTAssertEqual(actual.bytes.count, reference.bytes.count, file: file, line: line)
    let differences = zip(actual.bytes, reference.bytes).filter { $0 != $1 }.count
    XCTAssertEqual(differences, 0, message, file: file, line: line)
  }
}
