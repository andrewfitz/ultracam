import CoreGraphics
import CoreVideo
import Metal
import MonitorToolsMetal
import QuartzCore

/// How a picture layer presents its pixels: the drawable format, the
/// colorspace Core Animation reads them in, and whether they are HDR.
///
/// The picture pass writes the signal's own non-linear R'G'B' (the YCbCr
/// matrix undone, no transfer applied), so the layer colorspace carries the
/// signal's primaries and transfer and Core Animation color-matches and, for
/// HLG and PQ, tone-maps, as AVSampleBufferDisplayLayer did. Anything not
/// tagged BT.2020, HLG or PQ (including log sources shown as code values)
/// stays Rec.709, as before.
struct MonitorPictureColor: Equatable, Sendable {
  enum Space: Equatable, Sendable {
    case rec709, rec2020, hlg, pq
  }
  let space: Space

  static let rec709 = MonitorPictureColor(space: .rec709)

  init(space: Space) { self.space = space }

  init(signal: MonitorFrameSignal?) {
    guard let signal, signal.profileID == nil else {
      // A declared camera log profile is a code-value view, never a display transform.
      self = .rec709
      return
    }
    let transfer = signal.transferFunction ?? signal.transfer
    if transfer == Self.hlgTransfer {
      space = .hlg
    } else if transfer == Self.pqTransfer {
      space = .pq
    } else if signal.primaries == Self.rec2020Primaries {
      space = .rec2020
    } else {
      space = .rec709
    }
  }

  private static let hlgTransfer = kCVImageBufferTransferFunction_ITU_R_2100_HLG as String
  private static let pqTransfer = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
  private static let rec2020Primaries = kCVImageBufferColorPrimaries_ITU_R_2020 as String

  var isHDR: Bool { space == .hlg || space == .pq }

  /// 10-bit for SDR; half float for HDR so Core Animation's EDR path takes it.
  var pixelFormat: MTLPixelFormat { isHDR ? .rgba16Float : .bgr10a2Unorm }

  var colorSpaceName: CFString {
    switch space {
    case .rec709: CGColorSpace.itur_709
    case .rec2020: CGColorSpace.itur_2020
    case .hlg: CGColorSpace.itur_2100_HLG
    case .pq: CGColorSpace.itur_2100_PQ
    }
  }

  /// Sets the layer's format, colorspace and EDR state. Call only on change;
  /// it works from any thread inside its own transaction.
  func apply(to layer: CAMetalLayer) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    if layer.pixelFormat != pixelFormat { layer.pixelFormat = pixelFormat }
    layer.colorspace = CGColorSpace(name: colorSpaceName)
    layer.wantsExtendedDynamicRangeContent = isHDR
    switch space {
    case .hlg:
      layer.edrMetadata = CAEDRMetadata.isAvailable ? CAEDRMetadata.hlg : nil
    case .pq:
      // HDR10 defaults for content without mastering metadata: 1000-nit
      // mastering peak, reference white 100 nits.
      layer.edrMetadata =
        CAEDRMetadata.isAvailable
        ? CAEDRMetadata.hdr10(minLuminance: 0.005, maxLuminance: 1000, opticalOutputScale: 100)
        : nil
    case .rec709, .rec2020:
      layer.edrMetadata = nil
    }
    CATransaction.commit()
  }
}
