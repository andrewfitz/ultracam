@preconcurrency import CoreVideo
import Foundation
@preconcurrency import Metal
import MonitorToolsCore

public struct MonitorFrameSignal: Equatable, Sendable {
  public let range: MonitorCodeRange
  public let matrix: MonitorYCbCrMatrix
  /// The transfer the tools interpret: the declared source profile when one is
  /// set, otherwise the buffer's transfer function tag.
  public let transfer: String
  public let profileID: String?
  /// The buffer's own colorimetry tags (kCVImageBufferColorPrimariesKey and
  /// kCVImageBufferTransferFunctionKey values), nil when untagged. These pick
  /// the display colorspace; `transfer` may name a profile instead.
  public let primaries: String?
  public let transferFunction: String?
  public init(
    range: MonitorCodeRange, matrix: MonitorYCbCrMatrix, transfer: String, profileID: String? = nil,
    primaries: String? = nil, transferFunction: String? = nil
  ) {
    self.range = range
    self.matrix = matrix
    self.transfer = transfer
    self.profileID = profileID
    self.primaries = primaries
    self.transferFunction = transferFunction
  }
  /// The same signal read with another code range.
  public func withRange(_ range: MonitorCodeRange) -> MonitorFrameSignal {
    MonitorFrameSignal(
      range: range, matrix: matrix, transfer: transfer, profileID: profileID,
      primaries: primaries, transferFunction: transferFunction)
  }
}

/// One producer frame: the source and, when processed, the output made from it.
/// Holding a bundle keeps both pixel buffers alive; nothing here copies pixels.
public struct MonitorFrameBundle: @unchecked Sendable {
  public let stamp: MonitorFrameStamp
  public let source: CVPixelBuffer
  public let output: CVPixelBuffer?
  public let sourceGeometry: MonitorGeometry
  public let outputGeometry: MonitorGeometry?
  public let sourceSignal: MonitorFrameSignal?
  public let outputSignal: MonitorFrameSignal?
  public let correspondence: MonitorCorrespondence?
  public init(
    stamp: MonitorFrameStamp, source: CVPixelBuffer, output: CVPixelBuffer? = nil,
    sourceGeometry: MonitorGeometry? = nil, outputGeometry: MonitorGeometry? = nil,
    correspondence: MonitorCorrespondence? = nil, sourceSignal: MonitorFrameSignal? = nil,
    outputSignal: MonitorFrameSignal? = nil
  ) {
    self.stamp = stamp
    self.source = source
    self.output = output
    self.sourceGeometry =
      sourceGeometry
      ?? MonitorGeometry(
        width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
    self.outputGeometry = outputGeometry
    self.correspondence = correspondence
    self.sourceSignal = sourceSignal
    self.outputSignal = outputSignal
  }
}

public enum MonitorPreviewError: Error, Equatable {
  case unsupportedFormat, invalidLayout, notIOSurfaceBacked, allocationFailed, shadersUnavailable,
    gpuFailed
}

/// The GPU view of one image: its planes as textures read in place.
/// `format` is the shader layout code (see MonitorTools.metal.txt).
public struct MonitorPlanes: @unchecked Sendable {
  public let format: UInt32
  public let width: Int
  public let height: Int
  public let pixelFormat: OSType
  public let plane0: MTLTexture
  /// The chroma plane for biplanar layouts; `plane0` again for packed layouts.
  public let plane1: MTLTexture
  public var isBiplanar: Bool { format >= 2 }
  public func isSameImage(as other: MonitorPlanes) -> Bool { plane0 === other.plane0 }

  /// Shader layout code and plane texture formats for a Core Video format.
  static func layout(_ type: OSType) -> (UInt32, MTLPixelFormat, MTLPixelFormat?)? {
    switch type {
    case kCVPixelFormatType_422YpCbCr10: (0, .rgba32Uint, nil)
    case kCVPixelFormatType_32BGRA: (1, .rgba8Uint, nil)
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: (2, .r8Uint, .rg8Uint)
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: (3, .r8Uint, .rg8Uint)
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: (4, .r16Uint, .rg16Uint)
    case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: (5, .r16Uint, .rg16Uint)
    case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange: (6, .r16Uint, .rg16Uint)
    case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange: (7, .r16Uint, .rg16Uint)
    default: nil
    }
  }
}

/// A frame ready for encoding. Live frames read the producer's IOSurfaces and
/// keep their pixel buffers; frozen frames own GPU copies and keep no buffer.
/// Retain it (see `MonitorEncodeContext.retain`) until the GPU has finished.
public struct MonitorGPUFrame: @unchecked Sendable {
  public let stamp: MonitorFrameStamp
  public let source: MonitorPlanes
  public let output: MonitorPlanes?
  public let sourceGeometry: MonitorGeometry
  public let outputGeometry: MonitorGeometry?
  public let sourceSignal: MonitorFrameSignal?
  public let outputSignal: MonitorFrameSignal?
  public let correspondence: MonitorCorrespondence?
  let sourceBuffer: CVPixelBuffer?
  let outputBuffer: CVPixelBuffer?

  init(
    bundle: MonitorFrameBundle, source: MonitorPlanes, output: MonitorPlanes?
  ) {
    stamp = bundle.stamp
    self.source = source
    self.output = output
    sourceGeometry = bundle.sourceGeometry
    outputGeometry = bundle.outputGeometry
    sourceSignal = bundle.sourceSignal
    outputSignal = bundle.outputSignal
    correspondence = bundle.correspondence
    sourceBuffer = bundle.source
    outputBuffer = bundle.output
  }

  init(copying frame: MonitorGPUFrame, source: MonitorPlanes, output: MonitorPlanes?) {
    stamp = frame.stamp
    self.source = source
    self.output = output
    sourceGeometry = frame.sourceGeometry
    outputGeometry = frame.outputGeometry
    sourceSignal = frame.sourceSignal
    outputSignal = frame.outputSignal
    correspondence = frame.correspondence
    sourceBuffer = nil
    outputBuffer = nil
  }

  /// True while the frame still reads producer buffers rather than owned copies.
  public var borrowsProducerBuffers: Bool { sourceBuffer != nil || outputBuffer != nil }
  public func planes(for stage: MonitorStage) -> MonitorPlanes {
    stage == .source ? source : (output ?? source)
  }
  public func signal(for stage: MonitorStage, configuration: MonitorConfiguration)
    -> MonitorFrameSignal?
  {
    if stage == .processedOutput, let output, !output.isSameImage(as: source) {
      return outputSignal
    }
    return sourceSignal.map { $0.withRange(configuration.sourceCodeRange ?? $0.range) }
  }
  public func geometry(for stage: MonitorStage) -> MonitorGeometry {
    guard stage == .processedOutput, let output, !output.isSameImage(as: source) else {
      return sourceGeometry
    }
    return outputGeometry ?? MonitorGeometry(width: output.width, height: output.height)
  }
  func retainResources(in context: MonitorEncodeContext) {
    context.retain(source.plane0)
    if source.isBiplanar { context.retain(source.plane1) }
    if let output {
      context.retain(output.plane0)
      if output.isBiplanar { context.retain(output.plane1) }
    }
    if let sourceBuffer { context.retain(sourceBuffer) }
    if let outputBuffer { context.retain(outputBuffer) }
  }
}
