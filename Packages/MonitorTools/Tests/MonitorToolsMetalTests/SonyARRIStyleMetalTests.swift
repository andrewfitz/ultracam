import CoreVideo
@preconcurrency import Metal
import MonitorToolsCore
import XCTest

@testable import MonitorToolsMetal

// Saved Sony ARRI-style selections now intentionally migrate to published Sony Pattern2.
// Literal ARRI qualification remains covered independently in MonitorMetalTests.
final class SonySLog3MetalTests: XCTestCase {
  private let cine = "sony-slog3-sgamut3cine"
  private let gamut3 = "sony-slog3-sgamut3"
  private let adaptation = "arri-style-slog3-logc3-ei800-v1"

  // Catches classifying Sony's encoded values directly with an ARRI camera table,
  // losing native-code offsets, and treating the camera EI as an IRE-band adjustment.
  func testSonyAnchorsAcrossNativeAndRescaledLegalTransport() throws {
    let runtime = try metalRuntime()
    for (range, mapping) in [
      (MonitorCodeRange.full, MonitorSourceLogMapping.native10Bit),
      (.legal, .native10Bit), (.legal, .fullRescaledToLegal10Bit),
    ] {
      let codes = [95, 420, 496, 550]
      let transported = codes.map {
        mapping == .native10Bit ? $0 : Int((64 + Double($0) * 876 / 1023).rounded())
      }
      let source = try packed(codes: transported)
      var config = configuration(sourceProfile: cine)
      config.sourceLogMapping = mapping
      config.falseColor.exposureIndex = 1250
      let display = try render(
        runtime, source: source, config: config, range: range, sourceProfile: cine)
      let bytes = try pixels(display)
      for (index, code) in transported.enumerated() {
        let native = mapping == .native10Bit ? Double(code)/1023 : Double(code-64)/876
        let color = try XCTUnwrap(SonySLog3FalseColor.color(nativeSignalLuma:native))
        assertPixel(bytes,at:index*6,rgb:[color.r,color.g,color.b].map { Int(($0*255).rounded()) })
      }
      XCTAssertFalse(display.availability.contains { $0.contains("False color unavailable") })
    }
  }

  // BGRA stores encoded channels directly; unlike YUV, readRGB has not
  // expanded its legal range. This catches applying the YUV inverse twice.
  func testSonyBGRANativeAndExplicitRescaledTransport() throws {
    let runtime = try metalRuntime()
    for (value, mapping) in [
      (UInt8(105), MonitorSourceLogMapping.native10Bit),
      (UInt8(106), .fullRescaledToLegal10Bit),
    ] {
      var config = configuration(sourceProfile: cine)
      config.sourceLogMapping = mapping
      let display = try render(
        runtime, source: bgra(r: value, g: value, b: value), config: config, range: .legal,
        sourceProfile: cine)
      assertPixel(try pixels(display), at: 0, rgb: [0, 255, 0])
    }
  }

  // Sony Pattern2 uses declared transport-matrix signal luma, independently of
  // Sony scene-linear gamut or camera EI; this is not the historical adaptation.
  func testSonyPublishedIREUsesSignalLumaIndependentlyOfSceneGamut() throws {
    let runtime = try metalRuntime()
    let source = try bgra(r: 105, g: 105, b: 140)
    for (profile, expected) in [(cine, [0, 255, 0]), (gamut3, [0, 255, 0])] {
      let display = try render(
        runtime, source: source, config: configuration(sourceProfile: profile), range: .full,
        sourceProfile: profile)
      assertPixel(try pixels(display), at: 0, rgb: expected)
    }
  }

  // Catches sampling a processed LUT output instead of the paired source.
  func testSonyFalseColorIgnoresProcessedOutputLook() throws {
    let runtime = try metalRuntime()
    let source = try packed(codes: [420])
    for value: UInt8 in [10, 240] {
      let output = try bgra(r: value, g: value, b: value, width: 6)
      var config = configuration(sourceProfile: cine)
      config.pictureStage = .processedOutput
      let display = try render(
        runtime, source: source, output: output, config: config, range: .legal,
        sourceProfile: cine)
      assertPixel(try pixels(display), at: 0, rgb: [0, 255, 0])
    }
  }

  // Catches accepting mismatched source metadata, unsupported transfer, or
  // missing correspondence merely because the selected profile is Sony.
  func testSonyQualificationFailsClosed() throws {
    let runtime = try metalRuntime()
    let source = try packed(codes: [420])
    let output = try bgra(r: 10, g: 10, b: 10, width: 6)
    var config = configuration(sourceProfile: cine)
    config.pictureStage = .processedOutput
    for (profile, transfer, correspondence, range) in [
      (gamut3, "S-Log3", Optional(MonitorCorrespondence.identity), MonitorCodeRange.legal),
      (cine, "Rec709", Optional(MonitorCorrespondence.identity), .legal),
      (cine, "S-Log3", nil, .legal),
    ] {
      let display = try render(
        runtime, source: source, output: output, config: config, range: range,
        sourceProfile: profile, transfer: transfer, correspondence: correspondence)
      assertPixel(try pixels(display), at: 0, rgb: [10, 10, 10])
      XCTAssertTrue(display.availability.contains { $0.contains("False color unavailable") })
    }
    config.sourceLogMapping = .fullRescaledToLegal10Bit
    let display = try render(
      runtime, source: source, output: output, config: config, range: .full,
      sourceProfile: cine)
    assertPixel(try pixels(display), at: 0, rgb: [10, 10, 10])
    XCTAssertTrue(display.availability.contains { $0.contains("False color unavailable") })
  }

  // The CPU reference is independently exercised by literal Core fixtures. This
  // sweep catches any GPU/CPU disagreement at the native 10-bit transitions.
  func testSonyEveryNativeTenBitCodeMatchesCPUReference() throws {
    let runtime = try metalRuntime()
    for start in stride(from: 0, through: 1023, by: 256) {
      let codes = Array(start..<(start + 256))
      let source = try packed(codes: codes)
      for profile in [cine, gamut3] {
        let display = try render(
          runtime, source: source, config: configuration(sourceProfile: profile), range: .legal,
          sourceProfile: profile)
        let bytes = try pixels(display)
        for (index, code) in codes.enumerated() {
          let gray = Double(code) / 1023
          let rgb = try XCTUnwrap(SonySLog3FalseColor.color(
            rgb: MonitorRGB(r: gray, g: gray, b: gray), matrix: .bt709))
          assertPixel(
            bytes, at: index * 6,
            rgb: [Int((rgb.r * 255).rounded()), Int((rgb.g * 255).rounded()),
              Int((rgb.b * 255).rounded())], message: "\(profile) native code \(code)")
        }
      }
    }
  }

  private func configuration(sourceProfile: String) -> MonitorConfiguration {
    var config = MonitorConfiguration()
    config.toolsEnabled = true
    config.pictureStage = .source
    config.sourceProfileID = sourceProfile
    config.falseColor.mode = .arri
    config.falseColor.profileID = adaptation
    return config
  }

  private func metalRuntime() throws -> MonitorRuntime {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
    return MonitorRuntime()
  }


  private func render(
    _ runtime: MonitorRuntime, source: CVPixelBuffer, output: CVPixelBuffer? = nil,
    config: MonitorConfiguration, range: MonitorCodeRange, sourceProfile: String,
    transfer: String = "S-Log3", correspondence: MonitorCorrespondence? = .identity
  ) throws -> MonitorSnapshot {
    let target = MonitorTargetID(UUID().uuidString)
    let stamp = MonitorFrameStamp(
      target: target, generation: 1, sequence: 1, sourcePTS: 1, hostTime: 1,
      configurationRevision: 1)
    let frame = MonitorFrameBundle(
      stamp: stamp, source: source, output: output, correspondence: correspondence,
      sourceSignal: MonitorFrameSignal(
        range: range, matrix: .bt709, transfer: transfer, profileID: sourceProfile),
      outputSignal: MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "Rec709"))
    return try runtime.renderSnapshot(frame, configuration: config.normalized())
  }

  private func allocate(_ format: OSType, width: Int) throws -> CVPixelBuffer {
    var result: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      nil, width, 32, format, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result)
    guard status == kCVReturnSuccess, let result else {
      throw XCTSkip("Native Metal fixture allocation unavailable")
    }
    return result
  }

  private func packed(codes: [Int]) throws -> CVPixelBuffer {
    let buffer = try allocate(kCVPixelFormatType_422YpCbCr10, width: codes.count * 6)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
    for y in 0..<32 {
      let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(
        to: UInt32.self)
      for (index, code) in codes.enumerated() {
        let value = UInt32(code)
        row[index * 4] = 512 | (value << 10) | (512 << 20)
        row[index * 4 + 1] = value | (512 << 10) | (value << 20)
        row[index * 4 + 2] = row[index * 4]
        row[index * 4 + 3] = row[index * 4 + 1]
      }
    }
    return buffer
  }

  private func bgra(r: UInt8, g: UInt8, b: UInt8, width: Int = 6) throws -> CVPixelBuffer {
    let buffer = try allocate(kCVPixelFormatType_32BGRA, width: width)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
    for y in 0..<32 {
      let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(
        to: UInt8.self)
      for x in 0..<width {
        row[x * 4] = b
        row[x * 4 + 1] = g
        row[x * 4 + 2] = r
        row[x * 4 + 3] = 255
      }
    }
    return buffer
  }

  private func pixels(_ display: MonitorSnapshot) throws -> [UInt8] {
    Array(display.pictureBytes.prefix(display.width * 4))
  }

  private func assertPixel(
    _ bytes: [UInt8], at x: Int, rgb: [Int], message: String = "",
    file: StaticString = #filePath, line: UInt = #line
  ) {
    for channel in 0..<3 {
      XCTAssertEqual(
        Int(bytes[x * 4 + 2 - channel]), min(255, max(0, rgb[channel])), accuracy: 1, message,
        file: file, line: line)
    }
  }
}
