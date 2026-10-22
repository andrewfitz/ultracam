import CoreVideo
@preconcurrency import Metal
import MonitorToolsCore
import XCTest
@testable import MonitorToolsMetal

final class ELZoneMetalTests: XCTestCase {
  private func configuration(_ profile: String, offset: Double = 0) -> MonitorConfiguration {
    var config = MonitorConfiguration(); config.toolsEnabled = true; config.pictureStage = .source
    config.sourceProfileID = profile; config.falseColor.mode = .elZone
    config.falseColor.profileID = ELZoneProfile.profileID
    config.falseColor.specificationVersion = ELZoneProfile.specificationVersion
    config.falseColor.referenceOffsetStops = offset
    config.falseColor.exposureIndex = 1250
    return config
  }

  func testELZoneAllNativeCodesAndRescaledTransportMatchVersionedCPUConvention() throws {
    let runtime = try metalRuntime()
    for profile in ["sony-slog3-sgamut3cine","sony-slog3-sgamut3"] {
      let gamut = try XCTUnwrap(ELZoneProfile.gamut(forSourceProfileID: profile))
      for (range,mapping) in [(MonitorCodeRange.full,MonitorSourceLogMapping.native10Bit),(.legal,.native10Bit),(.legal,.fullRescaledToLegal10Bit)] {
        for offset in [-1.0,0,1] { for start in stride(from: 0,through: 1023,by: 256) {
          let codes = Array(start..<(start+256)).map { mapping == .native10Bit ? $0 : Int((64+Double($0)*876/1023).rounded()) }
          var config = configuration(profile,offset:offset); config.sourceLogMapping = mapping
          let display = try render(runtime,source:packed(codes:codes),config:config,range:range,sourceProfile:profile)
          let bytes = try pixels(display)
          for (index,code) in codes.enumerated() {
            let value = mapping == .native10Bit ? Double(code)/1023 : Double(code-64)/876
            let expected = try XCTUnwrap(ELZoneProfile.color(rgb:.init(r:value,g:value,b:value),gamut:gamut,referenceOffsetStops:offset))
            assertPixel(bytes,at:index*6,rgb:[expected.r,expected.g,expected.b].map { Int(($0*255).rounded()) },message:"EL code \(code),mapping \(mapping),offset \(offset),\(profile)")
          }
        }}
      }
    }
  }

  func testELZoneDecodesColoredRGBBeforeGamutLuminanceAndRetainsSourceLookIndependence() throws {
    let runtime = try metalRuntime()
    for (r,g,b) in [(140,24,24),(24,24,146),(105,105,105)] {
      for profile in ["sony-slog3-sgamut3cine","sony-slog3-sgamut3"] {
        let gamut = try XCTUnwrap(ELZoneProfile.gamut(forSourceProfileID:profile))
        let expected = try XCTUnwrap(ELZoneProfile.color(rgb:.init(r:Double(r)/255,g:Double(g)/255,b:Double(b)/255),gamut:gamut))
        var config = configuration(profile); config.pictureStage = .processedOutput
        for outputValue: UInt8 in [10,240] {
          let display = try render(runtime,source:bgra(r:UInt8(r),g:UInt8(g),b:UInt8(b)),output:bgra(r:outputValue,g:outputValue,b:outputValue),config:config,range:.full,sourceProfile:profile)
          assertPixel(try pixels(display),at:0,rgb:[expected.r,expected.g,expected.b].map { Int(($0*255).rounded()) })
        }
      }
    }
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
