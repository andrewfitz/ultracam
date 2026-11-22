// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import CoreVideo
import Metal
import XCTest
import simd

@testable import MonitorKit

/// Shared fixtures for the scenario tests (`MonitorPixelTests`, `PictureQualityTests`,
/// `CleanApertureTests` and the false-colour and geometry scenario classes): small
/// CoreVideo pictures wrapped through the host's texture cache, as a capture app
/// delivers them, drawn by the full picture pass and checked pixel by pixel.
///
/// Conventions every scenario follows:
/// - **Processed output.** A "processed output look" is a burn-in `MonitorLUT`: the
///   output stage is the source plus the feed's burn-in LUT, computed in the shader
///   at source resolution, with no second, downscaled output buffer. A "flat output"
///   is a constant LUT (`Fixtures.constantLUT`). A picture that is not the camera's
///   own signal is a frame with `isProcessed` set, which refuses log false colour and
///   peaking (`.requiresCameraSignal`).
/// - **`pictureStage`.** `MonitorState.pictureStage = .source` shows the decoded
///   camera signal; the default `.monitor` stage shows the picture after the LUTs.
/// - **Profiles.** `SignalDescription.encoding` is the single declaration of curve,
///   gamut and `LogTransport`, so a profile/signal mismatch cannot be expressed; the
///   analogue is a mode on a signal it does not classify (`MonitorUnavailableReason`).
/// - **Exposure index.** Sony Pattern 2 takes none.
/// - **Pixels.** Scenarios render into `rgba32Float` (`TestGPU.render`) and compare
///   classified colours exactly and grey fallbacks within float precision.
/// - **Size.** Each scenario renders at the size of its fixture picture.
enum Fixtures {
  /// A 2³ cube mapping every input to `value`: a burn-in LUT that makes the output
  /// stage flat.
  /// Values exact in half float (k/16) keep the LUT texture's result exact.
  static func constantLUT(_ gpu: TestGPU, _ value: Float) throws -> MonitorLUT {
    var text = "LUT_3D_SIZE 2\n"
    for _ in 0..<8 { text += "\(value) \(value) \(value)\n" }
    return try MonitorLUT(device: gpu.device, cube: try CubeLUT(text: text))
  }

  /// Two flat output levels, near black and near white.
  static let flatLevels: [Float] = [1.0 / 16, 15.0 / 16]

  /// An 8-bit BGRA picture of `(r, g, b)` codes per pixel.
  static func bgra(width: Int, height: Int, _ codes: (Int, Int) -> (Int, Int, Int)) -> SyntheticFrame {
    var f = SyntheticFrame(layout: .bgra8, width: width, height: height)
    f.rgb = (0..<(width * height)).map { i in
      let c = codes(i % width, i / width)
      return SIMD3(Double(c.0), Double(c.1), Double(c.2)) / 255
    }
    return f
  }

  /// A neutral 8-bit BGRA picture of code `value(x, y)`.
  static func grey(width: Int, height: Int, _ value: @escaping (Int, Int) -> Int) -> SyntheticFrame {
    bgra(width: width, height: height) { x, y in
      let v = value(x, y)
      return (v, v, v)
    }
  }

  /// The picture as an IOSurface `CVPixelBuffer` wrapped through the host's texture
  /// cache, the path a capture app's frames take. `signal` overrides
  /// the attachments, as a host declaring a camera profile does.
  static func wrapped(_ gpu: TestGPU, _ picture: SyntheticFrame, signal: SignalDescription) throws -> MonitorFrame {
    guard let buffer = picture.pixelBuffer(range: signal.range) else {
      throw XCTSkip("CoreVideo cannot allocate \(picture.layout)")
    }
    return try MonitorFrame.wrap(buffer, cache: gpu.cache, signal: signal)
  }

  static func signal(_ encoding: SignalEncoding, range: CodeRange, matrix: YCbCrMatrix = .bt709) -> SignalDescription {
    SignalDescription(range: range, matrix: matrix, encoding: encoding)
  }

  static let sLog3Cine = SignalEncoding.log(.sLog3SGamut3Cine)
  static let sLog3 = SignalEncoding.log(.sLog3SGamut3)

  static func sLog3(_ gamut: ColorGamut, transport: LogTransport = .native) -> SignalEncoding {
    .log(LogEncoding(curve: .sLog3, gamut: gamut, transport: transport))
  }

  static func logC(_ curve: LogCurve, transport: LogTransport = .native) -> SignalEncoding {
    .log(LogEncoding(curve: curve, gamut: curve == .arriLogC4 ? .arriWideGamut4 : .arriWideGamut3, transport: transport))
  }

  /// The transported 10-bit code for a native camera code: unchanged for
  /// `native10Bit`, squeezed into 64…940 for `fullRescaledToLegal10Bit`.
  static func transported(_ code: Int, _ transport: LogTransport) -> Int {
    transport == .native ? code : Int((64 + Double(code) * 876 / 1023).rounded())
  }

  /// The native normalized value of a transported code in a legal or full
  /// 10-bit container: code/1023 natively, (code - 64)/876 when rescaled.
  static func native(transported code: Int, _ transport: LogTransport) -> Double {
    transport == .native ? Double(code) / 1023 : Double(code - 64) / 876
  }

  static func vector(_ c: ColorRGB) -> SIMD3<Float> { SIMD3(Float(c.r), Float(c.g), Float(c.b)) }

  static func grey(_ v: Double) -> ColorRGB { ColorRGB(r: v, g: v, b: v) }
}

/// Classified colours exactly; an unclassified pixel's grey within float precision.
func assertFixturePixel(
  _ gpu: SIMD3<Float>, _ expected: ColorRGB, exact: Bool, _ message: @autoclosure () -> String,
  file: StaticString = #filePath, line: UInt = #line
) {
  let e = simd_clamp(Fixtures.vector(expected), .zero, SIMD3(repeating: 1))
  if exact {
    XCTAssertEqual(gpu, e, message(), file: file, line: line)
  } else {
    XCTAssertLessThanOrEqual(simd_reduce_max(simd_abs(gpu - e)), 2e-6, message(), file: file, line: line)
  }
}
