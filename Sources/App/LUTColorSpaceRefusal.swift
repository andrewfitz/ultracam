import Foundation

extension LUTColorSpaceContractError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .inputMismatch(let expected, let actual):
      "The LUT input space is \(Self.name(expected)), but the source is \(Self.name(actual)). Set LUT input space to match the source in the camera's settings."
    case .outputMismatch(let expected, let actual):
      "The LUT output space is \(Self.name(actual)), but the output needs \(Self.name(expected)). Set LUT output space in the camera's settings."
    }
  }

  /// Matched on RGB encoding, as the contract is; transport is not part of the name.
  private static func name(_ colour: Colorimetry) -> String {
    SourceColorSpaceCatalog.entries.first { LUTColorSpaceContract.sameRGBEncoding($0.color, colour) }?.title
      ?? "\(colour.primaries) / \(colour.transfer)"
  }
}
