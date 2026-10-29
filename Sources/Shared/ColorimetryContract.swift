import CryptoKit
import Foundation

/// Immutable colour identity carried by source and output declarations.
/// Runtime clock bindings and capture-instance identifiers are deliberately
/// outside this value, so reconnects cannot change its signature.
struct ColorimetryContract: Hashable, Codable, Sendable {
  let primaries: Colorimetry.Primaries
  let transfer: Colorimetry.Transfer
  let matrix: Colorimetry.Matrix
  let range: Colorimetry.Range
  let horizontalChromaSiting: Colorimetry.ChromaSiting
  let verticalChromaSiting: Colorimetry.ChromaSiting

  init(primaries: Colorimetry.Primaries, transfer: Colorimetry.Transfer,
       matrix: Colorimetry.Matrix, range: Colorimetry.Range = .video,
       horizontalChromaSiting: Colorimetry.ChromaSiting = .left,
       verticalChromaSiting: Colorimetry.ChromaSiting = .center) {
    self.primaries = primaries; self.transfer = transfer; self.matrix = matrix
    self.range = range
    self.horizontalChromaSiting = horizontalChromaSiting
    self.verticalChromaSiting = verticalChromaSiting
  }

  init(_ value: Colorimetry) {
    self.init(primaries: value.primaries, transfer: value.transfer,
              matrix: value.matrix, range: value.range,
              horizontalChromaSiting: value.horizontalChromaSiting,
              verticalChromaSiting: value.verticalChromaSiting)
  }

  var colorimetry: Colorimetry {
    Colorimetry(primaries: primaries, transfer: transfer, matrix: matrix,
                range: range, horizontalChromaSiting: horizontalChromaSiting,
                verticalChromaSiting: verticalChromaSiting)
  }

  /// SHA-256 of the versioned, sorted canonical colour payload.
  var signature: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = (try? encoder.encode(self)) ?? Data()
    return SHA256.hash(data: Data("ultracam-colorimetry-v1:".utf8) + data)
      .map { String(format: "%02x", $0) }.joined()
  }

  static let rec709Video = Self(Colorimetry.rec709Video)
  static let identity = Self(primaries: .unspecified, transfer: .linear, matrix: .identity,
                             range: .full, horizontalChromaSiting: .unspecified,
                             verticalChromaSiting: .unspecified)
}
