import CoreMedia
import CoreVideo
import IOSurface
import Metal

/// Standalone, opt-in standby producer. Completion is the only point at which
/// the image may be published. No CPU pixel access and no legacy Metal fallback.
final class GPUStandbyProducer {
  private let device: MTLDevice
  private let pipelines: [String: MTLComputePipelineState]

  init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
    guard let device, device.supportsFamily(.metal4) else {
      throw VideoError.message("GPU standby requires a Metal 4 GPU. This device cannot produce GPU standby images.")
    }
    self.device = device
    do {
      let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
      let descriptor = MTL4LibraryDescriptor()
      descriptor.source = Self.shader
      descriptor.name = "Ultracam GPU standby"
      let library = try compiler.makeLibrary(descriptor: descriptor)
      var pipelines: [String: MTLComputePipelineState] = [:]
      for name in ["black8", "neutral8", "black10", "neutral10", "zero10", "packed210"] {
        let function = MTL4LibraryFunctionDescriptor()
        function.library = library
        function.name = name
        let pipeline = MTL4ComputePipelineDescriptor()
        pipeline.computeFunctionDescriptor = function
        pipelines[name] = try compiler.makeComputePipelineState(descriptor: pipeline)
      }
      self.pipelines = pipelines
    } catch {
      throw VideoError.message("Cannot compile Metal 4 standby kernels: \(error.localizedDescription)")
    }
  }

  /// Allocates one IOSurface and submits its fill. Resources, including this
  /// producer, survive until Metal feedback; callers may immediately release it.
  func makeBlack(format: CMVideoFormatDescription,
    completion: @escaping @Sendable (Result<GPUStandbyImage, Error>) -> Void) throws {
    let dimensions = CMVideoFormatDescriptionGetDimensions(format)
    let type = CMFormatDescriptionGetMediaSubType(format)
    _ = try VideoContract.formatDescription(width: Int(dimensions.width), height: Int(dimensions.height), pixelFormat: type)
    var image: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, Int(dimensions.width), Int(dimensions.height), type,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &image)
    guard status == kCVReturnSuccess, let image, let surface = CVPixelBufferGetIOSurface(image)?.takeUnretainedValue() else {
      throw VideoError.message("Cannot allocate IOSurface-backed GPU standby image (\(status)).")
    }
    try VideoBufferLayout.validate(image)
    // Only copy explicit published color tags; a future contract must not be
    // silently relabelled Rec.709 by the producer.
    for (source, destination) in [
      (kCMFormatDescriptionExtension_ColorPrimaries, kCVImageBufferColorPrimariesKey),
      (kCMFormatDescriptionExtension_TransferFunction, kCVImageBufferTransferFunctionKey),
      (kCMFormatDescriptionExtension_YCbCrMatrix, kCVImageBufferYCbCrMatrixKey),
      (kCMFormatDescriptionExtension_ChromaLocationTopField, kCVImageBufferChromaLocationTopFieldKey),
      (kCMFormatDescriptionExtension_ChromaLocationBottomField, kCVImageBufferChromaLocationBottomFieldKey),
      (kCMFormatDescriptionExtension_PixelAspectRatio, kCVImageBufferPixelAspectRatioKey),
      (kCMFormatDescriptionExtension_FieldCount, kCVImageBufferFieldCountKey),
      (kCMFormatDescriptionExtension_FieldDetail, kCVImageBufferFieldDetailKey)] {
      if let value = CMFormatDescriptionGetExtension(format, extensionKey: source) {
        CVBufferSetAttachment(image, destination, value, .shouldPropagate)
      }
    }
    let queueDescriptor = MTL4CommandQueueDescriptor()
    queueDescriptor.label = "Ultracam standby fill"
    let queue = try device.makeMTL4CommandQueue(descriptor: queueDescriptor)
    let residency = try device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
    guard let allocator = device.makeCommandAllocator(), let command = device.makeCommandBuffer() else {
      throw VideoError.message("Metal 4 standby command allocation failed.")
    }
    let packed = type == kCVPixelFormatType_422YpCbCr10
    let eight = ColorTarget.allCases.contains { $0.pixelFormat == type && $0.isEightBit }
    var textures: [MTLTexture] = []
    var tables: [MTL4ArgumentTable] = []
    command.beginCommandBuffer(allocator: allocator)
    for plane in 0..<(packed ? 1 : 2) {
      let bytes = packed ? 4 : (eight ? 1 : 2)
      let stride = packed ? CVPixelBufferGetBytesPerRow(image) : CVPixelBufferGetBytesPerRowOfPlane(image, plane)
      let rows = packed ? CVPixelBufferGetHeight(image) : CVPixelBufferGetHeightOfPlane(image, plane)
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: packed ? .r32Uint : (eight ? .r8Uint : .r16Uint),
        width: stride / bytes, height: rows, mipmapped: false)
      descriptor.storageMode = .shared
      descriptor.usage = .shaderWrite
      guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: plane) else {
        command.endCommandBuffer()
        throw VideoError.message("Metal 4 cannot map standby \(VideoContract.fourCC(type)) plane \(plane), including its row padding. This GPU/IOSurface layout is unsupported; do not activate GPU standby.")
      }
      textures.append(texture)
      residency.addAllocation(texture)
      let tableDescriptor = MTL4ArgumentTableDescriptor()
      tableDescriptor.maxTextureBindCount = 1
      let table = try device.makeArgumentTable(descriptor: tableDescriptor)
      table.setTexture(texture.gpuResourceID, index: 0)
      tables.append(table)
      let name = packed ? "packed210" : (eight ? (plane == 0 ? "black8" : "neutral8") :
        (plane == 1 ? "neutral10" : (type == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange ? "zero10" : "black10")))
      guard let pipeline = pipelines[name], let encoder = command.makeComputeCommandEncoder() else {
        command.endCommandBuffer()
        throw VideoError.message("Metal 4 standby encoder unavailable.")
      }
      encoder.setComputePipelineState(pipeline)
      encoder.setArgumentTable(table)
      encoder.dispatchThreads(threadsPerGrid: MTLSize(width: stride / bytes, height: rows, depth: 1),
        threadsPerThreadgroup: MTLSize(width: min(32, pipeline.threadExecutionWidth), height: 1, depth: 1))
      encoder.endEncoding()
    }
    command.endCommandBuffer()
    residency.commit()
    queue.addResidencySet(residency)
    let options = MTL4CommitOptions()
    let submission = RetainedSubmission(producer: self, image: image, textures: textures,
      tables: tables, allocator: allocator, command: command, residency: residency, queue: queue,
      completion: completion)
    options.addFeedbackHandler { feedback in submission.finish(error: feedback.error) }
    queue.commit([command], options: options)
  }

  /// Constructed only after encoding ends. No member is mutated after capture;
  /// feedback is Metal's one completion callback. The callback owns every
  /// non-Sendable Metal resource until GPU access has ended, and never encodes.
  private final class RetainedSubmission: @unchecked Sendable {
    let producer: GPUStandbyProducer
    let image: CVPixelBuffer
    let textures: [MTLTexture]
    let tables: [MTL4ArgumentTable]
    let allocator: MTL4CommandAllocator
    let command: MTL4CommandBuffer
    let residency: MTLResidencySet
    let queue: MTL4CommandQueue
    let completion: @Sendable (Result<GPUStandbyImage, Error>) -> Void

    init(producer: GPUStandbyProducer, image: CVPixelBuffer, textures: [MTLTexture],
      tables: [MTL4ArgumentTable], allocator: MTL4CommandAllocator, command: MTL4CommandBuffer,
      residency: MTLResidencySet, queue: MTL4CommandQueue,
      completion: @escaping @Sendable (Result<GPUStandbyImage, Error>) -> Void) {
      self.producer = producer; self.image = image; self.textures = textures
      self.tables = tables; self.allocator = allocator; self.command = command
      self.residency = residency; self.queue = queue; self.completion = completion
    }

    func finish(error: Error?) {
      queue.removeResidencySet(residency)
      if let error {
        completion(.failure(VideoError.message("Metal 4 standby fill failed: \(error.localizedDescription)")))
      } else { completion(.success(GPUStandbyImage(pixelBuffer: image))) }
    }
  }

  private static let shader: String = {
    let fills = [("black8", "16u"), ("neutral8", "128u"), ("black10", "4096u"),
      ("neutral10", "32768u"), ("zero10", "0u"),
      ("packed210", "((p.x & 1u) == 0u ? (512u | (64u << 10) | (512u << 20)) : (64u | (512u << 10) | (64u << 20)))")]
    return "#include <metal_stdlib>\nusing namespace metal;\n" + fills.map { name, value in
      "kernel void \(name)(texture2d<uint, access::write> dst [[texture(0)]], uint2 p [[thread_position_in_grid]]) { if (p.x < dst.get_width() && p.y < dst.get_height()) dst.write(uint4(\(value)), p); }"
    }.joined(separator: "\n")
  }()
}

/// Completed immutable standby image handoff. GPU writing has ended before
/// creation. Consumers may retain/read the pixel buffer but must not mutate it
/// while another consumer holds this handoff.
struct GPUStandbyImage: @unchecked Sendable {
  let pixelBuffer: CVPixelBuffer
}
