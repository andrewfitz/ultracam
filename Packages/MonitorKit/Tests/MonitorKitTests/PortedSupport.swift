import CoreVideo
import Metal
import XCTest
import simd

@testable import MonitorKit

/// Shared fixtures for the tests ported from `Packages/MonitorTools/Tests`
/// (integration map §8.2, "Port as MonitorKit pixel and reference tests").
///
/// How MonitorTools concepts map onto MonitorKit, used by every `Ported*` file:
/// - **Processed output and correspondence.** MonitorTools drew a separate
///   processed output buffer (a downscaled, LUT'd copy) and mapped the source onto
///   it through a `MonitorCorrespondence`. MonitorKit has no second buffer: the
///   output stage is the source plus the feed's burn-in LUT, computed in the shader
///   at source resolution (map §7 item 2, an intended change). A "processed output
///   look" is therefore a burn-in `MonitorLUT`; a "flat output" is a constant LUT
///   (`Ported.constantLUT`). There is no correspondence to get wrong; a picture that
///   is not the camera's own signal (what a missing correspondence meant) is a
///   frame with `isProcessed` set, which refuses log false colour and peaking
///   (`.requiresCameraSignal`).
/// - **`pictureStage`.** MonitorTools' `.source` is `MonitorState.pictureStage =
///   .source` (R9); its `.processedOutput` is the default `.monitor` stage (the
///   picture after the LUTs).
/// - **Profiles and transfer strings.** MonitorTools qualified a `profileID`, a
///   transfer string and a `MonitorSourceLogMapping`. MonitorKit's
///   `SignalDescription.encoding` is the single declaration (`LogEncoding` with
///   curve, gamut and `LogTransport`), so a profile/signal mismatch cannot be
///   expressed; the analogue is a mode on a signal it does not classify
///   (`MonitorUnavailableReason`).
/// - **Exposure index.** MonitorTools carried `exposureIndex` (1250 in the tests).
///   Sony Pattern 2 and EL Zone never used it there either; MonitorKit has no EI.
/// - **Pixels.** MonitorTools compared BGRA8 snapshot bytes within ±1 code.
///   These ports render into `rgba32Float` (`TestGPU.render`) and compare classified
///   colours exactly and grey fallbacks within float precision, which is stricter.
/// - **Snapshot size.** `MonitorRuntime.renderSnapshot` picked its own preview size
///   (1080 rows at most); MonitorKit draws into a target the host sizes, so each
///   port renders at the size the original snapshot had.
enum Ported {
  /// A 2³ cube mapping every input to `value`: a burn-in LUT that makes the output
  /// stage flat, the MonitorKit form of MonitorTools' flat processed output buffer.
  /// Values exact in half float (k/16) keep the LUT texture's result exact.
  static func constantLUT(_ gpu: TestGPU, _ value: Float) throws -> MonitorLUT {
    var text = "LUT_3D_SIZE 2\n"
    for _ in 0..<8 { text += "\(value) \(value) \(value)\n" }
    return try MonitorLUT(device: gpu.device, cube: try CubeLUT(text: text))
  }

  /// The flat output levels standing in for MonitorTools' 10/255 and 240/255 output buffers.
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
  /// cache, the path MonitorTools' `CVPixelBuffer` fixtures took. `signal` overrides
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

  /// MonitorTools' transported 10-bit code for a native camera code: unchanged for
  /// `native10Bit`, squeezed into 64…940 for `fullRescaledToLegal10Bit`.
  static func transported(_ code: Int, _ transport: LogTransport) -> Int {
    transport == .native ? code : Int((64 + Double(code) * 876 / 1023).rounded())
  }

  /// MonitorTools' native normalized value of a transported code in a legal or full
  /// 10-bit container: code/1023 natively, (code - 64)/876 when rescaled.
  static func native(transported code: Int, _ transport: LogTransport) -> Double {
    transport == .native ? Double(code) / 1023 : Double(code - 64) / 876
  }

  static func vector(_ c: ColorRGB) -> SIMD3<Float> { SIMD3(Float(c.r), Float(c.g), Float(c.b)) }

  static func grey(_ v: Double) -> ColorRGB { ColorRGB(r: v, g: v, b: v) }
}

/// Classified colours exactly; an unclassified pixel's grey within float precision.
func assertPorted(
  _ gpu: SIMD3<Float>, _ expected: ColorRGB, exact: Bool, _ message: @autoclosure () -> String,
  file: StaticString = #filePath, line: UInt = #line
) {
  let e = simd_clamp(Ported.vector(expected), .zero, SIMD3(repeating: 1))
  if exact {
    XCTAssertEqual(gpu, e, message(), file: file, line: line)
  } else {
    XCTAssertLessThanOrEqual(simd_reduce_max(simd_abs(gpu - e)), 2e-6, message(), file: file, line: line)
  }
}
