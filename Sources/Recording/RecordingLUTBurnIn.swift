import CoreVideo
import Foundation

/// A camera's burn-in LUT applied to a take's frames on the GPU, in the
/// recorder's direct capture → encoder path (Settings › Recording › Burn LUT
/// into recordings). Fixed when the take starts: a LUT the camera loads or
/// turns off mid-take changes Program and the virtual camera at once, and the
/// next take, never the take already rolling.
///
/// The writer hands `render` the clean capture buffer and an IOSurface buffer
/// from the encoder's own pool, already in the encoder's native layout. The
/// implementation decodes, applies the LUT and encodes in one GPU pass into
/// that buffer, which goes straight to VideoToolbox: no CPU copy, no preview
/// or Program frame, no extra buffer. Size, frame rate, timing and timecode
/// stay the source's; only the pixels and their colour tags change.
///
/// The recording module only knows this protocol (it also builds without the
/// app), so the app supplies the implementation (`RecordingLUTRenderer`).
protocol RecordingLUTBurnIn: AnyObject, Sendable {
  /// The take's LUT as the operator knows it (its `TITLE`, else its file's
  /// name), and the file it was read from when known, for the sidecar.
  var lutName: String { get }
  var lutFileName: String? { get }
  /// The LUT's declared input and output colour (its colour-space contract).
  var lutInputColour: Colorimetry { get }
  var lutOutputColour: Colorimetry { get }
  /// The colour of the frames `render` writes, which the file is tagged with:
  /// the LUT's output primaries and transfer, video range, centred chroma.
  /// Program and the virtual camera tag their burned-in output the same way.
  var outputColour: Colorimetry { get }
  /// Nil when this source layout and encoder layout have a GPU burn-in route;
  /// otherwise why not, for the operator.
  func refusal(sourcePixelFormat: OSType, encoderPixelFormat: OSType) -> String?
  /// Renders `source` through the LUT into `destination` (same size, the
  /// encoder's native layout) and returns once the GPU has finished, with its
  /// GPU time in milliseconds. `sourceColour` is the camera's declared colour
  /// (nil: read the buffer's tags). Called on the recorder's serial queue only.
  func render(_ source: CVPixelBuffer, sourceColour: Colorimetry?, into destination: CVPixelBuffer) throws -> Double
}

extension RecordingLUTBurnIn {
  /// The sidecar's record of the LUT this take burned in.
  var sidecarRecord: RecordingTakeSidecar.BurnedInLUT {
    RecordingTakeSidecar.BurnedInLUT(name: lutName, fileName: lutFileName, inputColour: lutInputColour,
      outputColour: lutOutputColour, recordedColour: outputColour)
  }
}

enum RecordingLUTBurnInError: Error, LocalizedError, Equatable {
  /// The take can't burn its LUT in on the GPU. Ultracam never records the
  /// clean picture in its place, and never converts on the CPU to do it.
  case unsupported(String)
  /// A frame's GPU burn-in failed. The take stops rather than mix clean frames in.
  case renderFailed(String)

  var errorDescription: String? {
    switch self {
    case let .unsupported(reason):
      return "Burn LUT into recordings can’t record this take: \(reason) Turn the setting off to record the clean camera picture."
    case let .renderFailed(reason):
      return "The take stopped: burning the LUT into a frame failed on the GPU (\(reason))."
    }
  }
}
