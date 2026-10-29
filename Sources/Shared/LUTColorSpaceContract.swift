import Foundation

/// The colour-space contract around a LUT. A LUT is a transform between two
/// declared spaces; applying it to a differently tagged image is unsafe unless
/// the caller explicitly supplies a conversion for that edge.
struct LUTColorSpaceContract: Hashable, Sendable {
  let input: Colorimetry
  let output: Colorimetry

  init(input: Colorimetry, output: Colorimetry) {
    self.input = input
    self.output = output
  }

  init(input: ColorimetryContract, output: ColorimetryContract) {
    self.init(input: input.colorimetry, output: output.colorimetry)
  }

  static let rec709Video = Self(input: Colorimetry.rec709Video, output: Colorimetry.rec709Video)

  /// LUT samples are normalized RGB after YCbCr unpacking. Matrix, range,
  /// and chroma siting describe that transport, not the RGB encoding the LUT
  /// expects. They remain exact in explicit conversion endpoints, where the
  /// caller identifies concrete source and destination declarations.
  static func sameRGBEncoding(_ lhs: Colorimetry, _ rhs: Colorimetry) -> Bool {
    lhs.primaries == rhs.primaries && lhs.transfer == rhs.transfer
  }

  /// Validates both sides of the LUT. No implicit retagging or colour
  /// conversion is allowed. A conversion must name the exact mismatched edge.
  func validate(source: Colorimetry, destination: Colorimetry,
                conversion: LUTColorSpaceConversion = .none) throws {
    switch conversion {
    case .none: break
    case .sourceAndOutput(let from, let to, let out, let target):
      guard from == source, to == input else {
        throw LUTColorSpaceContractError.inputMismatch(expected: input, actual: source)
      }
      guard out == output, target == destination else {
        throw LUTColorSpaceContractError.outputMismatch(expected: destination, actual: output)
      }
    case .sourceToLUTInput(let from, let to):
      guard from == source, to == input else {
        throw LUTColorSpaceContractError.inputMismatch(expected: input, actual: source)
      }
    case .lutOutputToDestination(let from, let to):
      guard from == output, to == destination else {
        throw LUTColorSpaceContractError.outputMismatch(expected: destination, actual: output)
      }
    }
    if !Self.sameRGBEncoding(source, input) {
      guard conversion == .sourceToLUTInput(from: source, to: input) ||
        conversion == .sourceAndOutput(fromSource: source, toLUTInput: input, fromLUTOutput: output, toDestination: destination) else {
        throw LUTColorSpaceContractError.inputMismatch(expected: input, actual: source)
      }
    }
    if !Self.sameRGBEncoding(output, destination) {
      guard conversion == .lutOutputToDestination(from: output, to: destination) ||
        conversion == .sourceAndOutput(fromSource: source, toLUTInput: input, fromLUTOutput: output, toDestination: destination) else {
        throw LUTColorSpaceContractError.outputMismatch(expected: destination, actual: output)
      }
    }
  }
}

enum LUTColorSpaceConversion: Hashable, Sendable {
  case none
  case sourceAndOutput(fromSource: Colorimetry, toLUTInput: Colorimetry, fromLUTOutput: Colorimetry, toDestination: Colorimetry)
  case sourceToLUTInput(from: Colorimetry, to: Colorimetry)
  case lutOutputToDestination(from: Colorimetry, to: Colorimetry)
}

enum LUTColorSpaceContractError: Error, Equatable, Sendable {
  case inputMismatch(expected: Colorimetry, actual: Colorimetry)
  case outputMismatch(expected: Colorimetry, actual: Colorimetry)
}
