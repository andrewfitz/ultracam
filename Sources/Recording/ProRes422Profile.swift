import AVFoundation
import CoreMedia
import Foundation

/// ProRes 422 family members supported by the writer.
public enum ProRes422Profile: String, CaseIterable, Sendable {
  case standard
  case highQuality

  public static let proRes422: Self = .standard
  public static let proRes422HQ: Self = .highQuality

  public var codec: AVVideoCodecType {
    switch self {
    case .standard: return .proRes422
    case .highQuality: return .proRes422HQ
    }
  }

  public var codecType: CMVideoCodecType {
    switch self {
    case .standard: return kCMVideoCodecType_AppleProRes422
    case .highQuality: return kCMVideoCodecType_AppleProRes422HQ
    }
  }

  public var displayName: String {
    switch self {
    case .standard: return "Apple ProRes 422"
    case .highQuality: return "Apple ProRes 422 HQ"
    }
  }
}

