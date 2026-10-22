import CoreVideo
import Foundation
import Metal

// Capture-queue ownership. Production processing uses explicit 32-bit float
// Metal textures and LUT samples. Native preview consumes the output directly.
final class LUTProcessor {
  struct PackedInputDiagnostics: Sendable {
    var noCopyFrames: UInt64 = 0
    var copiedFrames: UInt64 = 0
    var lastPath = "No packed processing"
  }

  struct WorkingResourceDiagnostics: Sendable {
    var floatTextureBytes: Int
    var packedCopyBytes: Int
    var outputPoolActive: Bool
  }

  /// Opt-in qualification timestamps. The normal capture path leaves the
  /// observer nil; diagnostics never retain a frame or command buffer.
  struct CommandTiming: Sendable {
    let commitBegin: Double
    let commitReturn: Double
    let gpuStart: Double
    let gpuEnd: Double
    let waitReturn: Double
    let meterReturn: Double
  }

  // Configure on this processor's owning serial queue before processing.
  var commandTimingObserver: (@Sendable (CommandTiming) -> Void)?

  private(set) var packedInputDiagnostics = PackedInputDiagnostics()
  private let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private let states: [String: MTLComputePipelineState]
  private var textureCache: CVMetalTextureCache!
  private var textureCacheUses = 0
  // Often enough to release cache-retained pool buffers, not every frame.
  private static let textureCacheFlushInterval = 32
  private var pool: CVPixelBufferPool?
  private var poolConfiguration: PipelineConfiguration?
  private var passthroughPool: CVPixelBufferPool?
  private var passthroughFormat: (type: OSType, width: Int, height: Int)?
  private var cube: CubeLUT?
  private var cubeBuffer: MTLBuffer
  private var fullTexture: MTLTexture?
  private var horizontalTexture: MTLTexture?
  private var scaledTexture: MTLTexture?

  var workingResourceDiagnostics: WorkingResourceDiagnostics {
    WorkingResourceDiagnostics(floatTextureBytes: [fullTexture, horizontalTexture, scaledTexture]
      .compactMap { $0 }.reduce(0) { $0 + $1.allocatedSize },
      packedCopyBytes: 0, outputPoolActive: pool != nil)
  }

  private struct Parameters {
    var geometry: SIMD4<UInt32>
    var domainLow: SIMD4<Float>
    var domainScale: SIMD4<Float>
    var decodeRange: SIMD4<Float>
    var decodeMatrix: SIMD4<Float>
    var encodeMatrix: SIMD4<Float>
    var options: SIMD4<UInt32>
  }

  init() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      throw VideoError.message("A Metal GPU is required.")
    }
    self.device = device
    commandQueue = queue
    let library: MTLLibrary
    if let path = ProcessInfo.processInfo.environment["ULTRACAM_METALLIB"] {
      library = try device.makeLibrary(URL: URL(fileURLWithPath: path))
    } else {
      let url = ProcessInfo.processInfo.environment["ULTRACAM_SHADER"].map { URL(fileURLWithPath: $0) }
        ?? Bundle.main.url(forResource: "LUTShaders", withExtension: "metal")
      guard let url else { throw VideoError.message("GPU shader resource is missing.") }
      library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
    }
    var states: [String: MTLComputePipelineState] = [:]
    for name in ["planarLUT", "packedLUT", "lanczosHorizontal", "lanczosVertical", "encodeNV12", "encode422"] {
      guard let function = library.makeFunction(name: name) else { throw VideoError.message("Missing GPU function \(name).") }
      states[name] = try device.makeComputePipelineState(function: function)
    }
    self.states = states
    guard let buffer = device.makeBuffer(length: 16, options: .storageModeShared) else {
      throw VideoError.message("Cannot allocate LUT buffer.")
    }
    cubeBuffer = buffer
    let status = CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    guard status == kCVReturnSuccess else { throw VideoError.message("Cannot create GPU texture cache.") }
  }

  func load(_ cube: CubeLUT) throws {
    let data = cube.data
    guard let buffer = data.withUnsafeBytes({ bytes in
      device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
    }) else { throw VideoError.message("Cannot upload LUT to GPU.") }
    self.cube = cube
    cubeBuffer = buffer
  }

  // Run before enabling native capture. Allocate the packed input staging,
  // floating-point working textures, output pool and first three frames while
  // no live frame can arrive. The generated black image is never published.
  func prepare(configuration: PipelineConfiguration) throws {
    if configuration.untouched { releaseIdleResources(); return }
    var source: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &source)
    guard status == kCVReturnSuccess, let source,
      CVPixelBufferLockBaseAddress(source, []) == kCVReturnSuccess else {
      throw VideoError.message("Cannot prepare capture processing buffers (\(status)).")
    }
    let stride = CVPixelBufferGetBytesPerRow(source) / 4
    guard let address = CVPixelBufferGetBaseAddress(source) else {
      CVPixelBufferUnlockBaseAddress(source, [])
      throw VideoError.message("Cannot initialize capture processing buffers.")
    }
    let words = address.assumingMemoryBound(to: UInt32.self)
    var row = [UInt32](repeating: 0, count: stride)
    for offset in Swift.stride(from: 0, to: 3840 / 6 * 4, by: 4) {
      row[offset] = 512 | (64 << 10) | (512 << 20)
      row[offset + 1] = 64 | (512 << 10) | (64 << 20)
      row[offset + 2] = 512 | (64 << 10) | (512 << 20)
      row[offset + 3] = 64 | (512 << 10) | (64 << 20)
    }
    row.withUnsafeBytes { bytes in
      for y in 0..<2160 { memcpy(words.advanced(by: y * stride), bytes.baseAddress!, bytes.count) }
    }
    CVPixelBufferUnlockBaseAddress(source, [])
    var warm = [CVPixelBuffer]()
    for _ in 0..<VideoContract.warmBufferCount { warm.append(try process(source, configuration: configuration)) }
    withExtendedLifetime(warm) {}
  }

  private func preparePool(_ configuration: PipelineConfiguration) throws -> CVPixelBufferPool {
    if let previous = poolConfiguration, previous.width == configuration.width,
      previous.height == configuration.height, previous.pixelFormat == configuration.pixelFormat,
      let pool { return pool }
    var pool: CVPixelBufferPool?
    let status = CVPixelBufferPoolCreate(nil,
      [kCVPixelBufferPoolMinimumBufferCountKey: VideoContract.warmBufferCount] as CFDictionary, [
      kCVPixelBufferPixelFormatTypeKey: configuration.pixelFormat,
      kCVPixelBufferWidthKey: configuration.width,
      kCVPixelBufferHeightKey: configuration.height,
      kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true,
    ] as CFDictionary, &pool)
    guard status == kCVReturnSuccess, let pool else { throw VideoError.message("Cannot allocate output pool.") }
    self.pool = pool
    poolConfiguration = configuration
    return pool
  }

  private func texture(width: Int, height: Int, existing: inout MTLTexture?) throws -> MTLTexture {
    if let existing, existing.width == width, existing.height == height { return existing }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
    descriptor.storageMode = .private
    descriptor.usage = [.shaderRead, .shaderWrite]
    guard let result = device.makeTexture(descriptor: descriptor) else { throw VideoError.message("Cannot allocate GPU working texture.") }
    existing = result
    return result
  }

  // Capture-queue only, after synchronous processing has finished. Published
  // pixel buffers remain valid; loaded LUT and compiled pipeline states stay.
  func releaseIdleResources() {
    let hadResources = fullTexture != nil || horizontalTexture != nil || scaledTexture != nil ||
      pool != nil
    fullTexture = nil
    horizontalTexture = nil
    scaledTexture = nil
    pool = nil
    poolConfiguration = nil
    passthroughPool = nil
    passthroughFormat = nil
    if hadResources { CVMetalTextureCacheFlush(textureCache, 0) }
  }

  /// Processing off: one GPU blit of the capture frame into an IOSurface this
  /// process owns. DeckLink reuses its buffer once our frame reference is gone,
  /// even while the window server or a meeting app still shows it; a pool
  /// buffer is not recycled while another process is using its IOSurface.
  func passthrough(_ input: CVPixelBuffer) throws -> CVPixelBuffer {
    let width = CVPixelBufferGetWidth(input), height = CVPixelBufferGetHeight(input)
    let type = CVPixelBufferGetPixelFormatType(input)
    guard CVPixelBufferGetIOSurface(input) != nil else {
      throw VideoError.message("The capture frame is not IOSurface-backed. Update Desktop Video.")
    }
    let planes = try Self.copyPlanes(type: type, width: width, height: height)
    if passthroughFormat?.type != type || passthroughFormat?.width != width || passthroughFormat?.height != height {
      var next: CVPixelBufferPool?
      let status = CVPixelBufferPoolCreate(nil,
        [kCVPixelBufferPoolMinimumBufferCountKey: VideoContract.warmBufferCount] as CFDictionary,
        [kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height, kCVPixelBufferPixelFormatTypeKey: type,
          kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &next)
      guard status == kCVReturnSuccess, let next else { throw VideoError.message("Cannot allocate passthrough frames (\(status)).") }
      passthroughPool = next
      passthroughFormat = (type, width, height)
    }
    var output: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, passthroughPool!,
      [kCVPixelBufferPoolAllocationThresholdKey: VideoContract.outputBufferLimit] as CFDictionary, &output)
    guard status == kCVReturnSuccess, let output else { throw VideoError.message("Passthrough frames are busy (\(status)).") }
    guard let command = commandQueue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else {
      throw VideoError.message("GPU is unavailable.")
    }
    command.label = "Passthrough"
    var wrappers: [CVMetalTexture] = []
    for plane in planes {
      let (sourceWrapper, source) = try view(input, plane: plane)
      let (targetWrapper, target) = try view(output, plane: plane)
      wrappers += [sourceWrapper, targetWrapper]
      blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
        sourceSize: MTLSize(width: plane.width, height: plane.height, depth: 1),
        to: target, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
    }
    blit.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    withExtendedLifetime(wrappers) {}
    guard command.status == .completed else {
      throw VideoError.message(command.error?.localizedDescription ?? "GPU passthrough failed.")
    }
    CVBufferRemoveAllAttachments(output)
    for mode in [CVAttachmentMode.shouldPropagate, .shouldNotPropagate] {
      if let attachments = CVBufferCopyAttachments(input, mode) { CVBufferSetAttachments(output, attachments, mode) }
    }
    return output
  }

  private struct CopyPlane { var index: Int; var format: MTLPixelFormat; var width: Int; var height: Int }

  /// Texture views that cover each plane's media exactly. v210 is read as one
  /// RGBA32Uint texel per 6-pixel group, as in the DeckLink SDK's Metal sample.
  private static func copyPlanes(type: OSType, width: Int, height: Int) throws -> [CopyPlane] {
    switch type {
    case kCVPixelFormatType_422YpCbCr10:
      return [CopyPlane(index: 0, format: .rgba32Uint, width: (width + 5) / 6, height: height)]
    case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
      return [CopyPlane(index: 0, format: .r16Uint, width: width, height: height),
        CopyPlane(index: 1, format: .rg16Uint, width: width / 2, height: height)]
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
      return [CopyPlane(index: 0, format: .r16Uint, width: width, height: height),
        CopyPlane(index: 1, format: .rg16Uint, width: width / 2, height: height / 2)]
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
      return [CopyPlane(index: 0, format: .r8Uint, width: width, height: height),
        CopyPlane(index: 1, format: .rg8Uint, width: width / 2, height: height / 2)]
    default:
      throw VideoError.message("Passthrough does not support \(VideoContract.fourCC(type)) frames.")
    }
  }

  private func view(_ buffer: CVPixelBuffer, plane: CopyPlane) throws -> (CVMetalTexture, MTLTexture) {
    var wrapper: CVMetalTexture?
    let status = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, plane.format,
      plane.width, plane.height, plane.index, &wrapper)
    guard status == kCVReturnSuccess, let wrapper, let texture = CVMetalTextureGetTexture(wrapper) else {
      throw VideoError.message("Cannot map frame plane \(plane.index) for the GPU (\(status)).")
    }
    return (wrapper, texture)
  }

  private func plane(_ buffer: CVPixelBuffer, index: Int, format: MTLPixelFormat) throws -> (CVMetalTexture, MTLTexture) {
    var wrapper: CVMetalTexture?
    let status = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, format,
      CVPixelBufferGetWidthOfPlane(buffer, index), CVPixelBufferGetHeightOfPlane(buffer, index), index, &wrapper)
    guard status == kCVReturnSuccess, let wrapper, let texture = CVMetalTextureGetTexture(wrapper) else {
      throw VideoError.message("Cannot map video plane \(index) to GPU (\(status)).")
    }
    return (wrapper, texture)
  }

  private func dispatch(_ name: String, on command: MTLCommandBuffer, width: Int, height: Int,
    configure: (MTLComputeCommandEncoder) -> Void) throws {
    guard let state = states[name], let encoder = command.makeComputeCommandEncoder() else {
      throw VideoError.message("Cannot create GPU encoder.")
    }
    encoder.label = name
    encoder.setComputePipelineState(state)
    configure(encoder)
    let w = state.threadExecutionWidth
    encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
      threadsPerThreadgroup: MTLSize(width: w, height: min(8, state.maxTotalThreadsPerThreadgroup / w), depth: 1))
    encoder.endEncoding()
  }

  func process(_ input: CVPixelBuffer, configuration: PipelineConfiguration) throws -> CVPixelBuffer {
    let width = CVPixelBufferGetWidth(input), height = CVPixelBufferGetHeight(input)
    let type = CVPixelBufferGetPixelFormatType(input)
    guard width == 3840, height == 2160 else {
      throw VideoError.message("Expected 3840 × 2160 input; received \(width) × \(height).")
    }
    guard VideoContract.tenBit422.contains(type) else { throw VideoError.message("Expected 10-bit 4:2:2 input.") }
    try VideoBufferLayout.validate(input)
    if configuration.untouched { releaseIdleResources(); return input }
    guard !configuration.applyLUT || cube != nil else { throw VideoError.message("Load a LUT or turn off Apply LUT.") }
    let chromaLocation = CVBufferCopyAttachment(input, kCVImageBufferChromaLocationTopFieldKey, nil) as? String
    // SMPTE/QuickTime 4:2:2 is left-cosited unless the producer labels it centered.
    let chromaOffset: Float = chromaLocation == kCVImageBufferChromaLocation_Center as String ||
      chromaLocation == kCVImageBufferChromaLocation_Top as String ||
      chromaLocation == kCVImageBufferChromaLocation_Bottom as String ? 0.5 : 0
    let matrix = CVBufferCopyAttachment(input, kCVImageBufferYCbCrMatrixKey, nil) as? String
    let kr: Float = matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String ? 0.2627 :
      (matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String ? 0.299 : 0.2126)
    let kb: Float = matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String ? 0.0593 :
      (matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String ? 0.114 : 0.0722)
    let kg = 1 - kr - kb
    let fullRange = type == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
    let low = cube?.domainMin ?? .zero
    let scale = SIMD3<Float>(repeating: 1) / ((cube?.domainMax ?? SIMD3(repeating: 1)) - low)
    var parameters = Parameters(
      geometry: SIMD4(UInt32(width), UInt32(height), UInt32(CVPixelBufferGetBytesPerRow(input) / 4), UInt32(cube?.dimension ?? 2)),
      domainLow: SIMD4(low.x, low.y, low.z, chromaOffset), domainScale: SIMD4(scale.x, scale.y, scale.z, 0),
      decodeRange: SIMD4(fullRange ? 0 : 64, fullRange ? 1023 : 876, 512, fullRange ? 1023 : 896),
      decodeMatrix: SIMD4(2 * (1 - kr), 2 * (1 - kb), 2 * kb * (1 - kb) / kg, 2 * kr * (1 - kr) / kg),
      encodeMatrix: SIMD4(configuration.applyLUT ? 0.2126 : kr, configuration.applyLUT ? 0.0722 : kb, 0, 0),
      options: SIMD4(configuration.applyLUT ? 1 : 0, 0, 0, 0))
    // Reserve output before encoding or mapping a borrowed capture frame. A
    // stalled consumer must not cause work or extend native frame lifetimes.
    let pool = try preparePool(configuration)
    var output: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
      [kCVPixelBufferPoolAllocationThresholdKey: VideoContract.outputBufferLimit] as CFDictionary, &output)
    if status == kCVReturnWouldExceedAllocationThreshold {
      flushTextureCache(force: true)
      throw VideoError.outputBackPressure
    }
    guard status == kCVReturnSuccess, let output else { throw VideoError.message("Output buffers are busy (\(status)).") }
    let (yWrapper, y) = try plane(output, index: 0, format: configuration.convertTo420 ? .r8Unorm : .r16Unorm)
    let (uvWrapper, uv) = try plane(output, index: 1, format: configuration.convertTo420 ? .rg8Unorm : .rg16Unorm)
    guard let command = commandQueue.makeCommandBuffer() else { throw VideoError.message("GPU is unavailable.") }
    command.label = "LUT → Lanczos → output format"
    let full = try texture(width: width, height: height, existing: &fullTexture)
    var wrappers: [CVMetalTexture] = [yWrapper, uvWrapper]
    if type == kCVPixelFormatType_422YpCbCr10 {
      // SDK 16 capture frames are IOSurface-backed, so the GPU reads the capture
      // memory through the texture cache. There is no copy path.
      guard CVPixelBufferGetIOSurface(input) != nil else {
        throw VideoError.message("The capture frame is not IOSurface-backed. Update Desktop Video.")
      }
      var groupWrapper: CVMetalTexture?
      let groupStatus = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, input, nil, .rgba32Uint,
        (width + 5) / 6, height, 0, &groupWrapper)
      guard groupStatus == kCVReturnSuccess, let groupWrapper, let groups = CVMetalTextureGetTexture(groupWrapper) else {
        throw VideoError.message("Cannot map the capture frame for the GPU (\(groupStatus)).")
      }
      wrappers.append(groupWrapper)
      packedInputDiagnostics.noCopyFrames &+= 1
      packedInputDiagnostics.lastPath = "No copy"
      try dispatch("packedLUT", on: command, width: width, height: height) { encoder in
        encoder.setTexture(groups, index: 3)
        encoder.setBuffer(cubeBuffer, offset: 0, index: 0)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.size, index: 1)
        encoder.setTexture(full, index: 2)
      }
    } else {
      let (yWrapper, y) = try plane(input, index: 0, format: .r16Unorm)
      let (uvWrapper, uv) = try plane(input, index: 1, format: .rg16Unorm)
      wrappers += [yWrapper, uvWrapper]
      try dispatch("planarLUT", on: command, width: width, height: height) { encoder in
        encoder.setTexture(y, index: 0); encoder.setTexture(uv, index: 1); encoder.setTexture(full, index: 2)
        encoder.setBuffer(cubeBuffer, offset: 0, index: 0)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.size, index: 1)
      }
    }
    var final = full
    if configuration.downscale {
      let horizontal = try texture(width: configuration.width, height: height, existing: &horizontalTexture)
      let scaled = try texture(width: configuration.width, height: configuration.height, existing: &scaledTexture)
      try dispatch("lanczosHorizontal", on: command, width: horizontal.width, height: horizontal.height) {
        $0.setTexture(full, index: 0); $0.setTexture(horizontal, index: 1)
      }
      try dispatch("lanczosVertical", on: command, width: scaled.width, height: scaled.height) {
        $0.setTexture(horizontal, index: 0); $0.setTexture(scaled, index: 1)
      }
      final = scaled
    } else {
      horizontalTexture = nil
      scaledTexture = nil
    }
    try dispatch(configuration.convertTo420 ? "encodeNV12" : "encode422", on: command, width: final.width, height: final.height) {
      $0.setTexture(final, index: 0); $0.setTexture(y, index: 1); $0.setTexture(uv, index: 2)
      $0.setBytes(&parameters, length: MemoryLayout<Parameters>.size, index: 1)
    }
    let timingObserver = commandTimingObserver
    let commitBegin = timingObserver == nil ? 0 : ProcessInfo.processInfo.systemUptime
    let completed = DispatchSemaphore(value: 0)
    let retainedWrappers = wrappers
    command.addCompletedHandler { _ in
      withExtendedLifetime(retainedWrappers) {}
      completed.signal()
    }
    command.commit()
    let commitReturn = timingObserver == nil ? 0 : ProcessInfo.processInfo.systemUptime
    // Stop is queued on this same capture queue. An unbounded wait would keep
    // a wedged command buffer from ever running it.
    let waitResult = completed.wait(timeout: .now() + 2)
    let waitReturn = timingObserver == nil ? 0 : ProcessInfo.processInfo.systemUptime
    if waitResult == .success, command.status == .completed {
      AppGPUActivity.shared.record(start: command.gpuStartTime, end: command.gpuEndTime)
    }
    if let timingObserver {
      timingObserver(CommandTiming(commitBegin: commitBegin, commitReturn: commitReturn,
        gpuStart: command.gpuStartTime, gpuEnd: command.gpuEndTime, waitReturn: waitReturn,
        meterReturn: ProcessInfo.processInfo.systemUptime))
    }
    withExtendedLifetime(wrappers) {}
    guard waitResult == .success, command.status == .completed else {
      throw VideoError.message(waitResult == .timedOut
        ? "GPU processing timed out."
        : (command.error?.localizedDescription ?? "GPU processing failed."))
    }
    flushTextureCache(force: false)
    // Pool buffers can carry attachments from their previous use. Start from a
    // clean attachment set, then carry the source's geometry/timing metadata
    // into the new image. Color labels are overridden below after the exact
    // decode/encode matrix is known; this avoids dropping pixel aspect ratio,
    // clean aperture, and producer-specific metadata on LUT-processed frames.
    CVBufferRemoveAllAttachments(output)
    CVBufferPropagateAttachments(input, output)
    // Encoders average each pair/block, producing centered chroma even if input
    // samples were left-cosited. Never carry the source's location onto output.
    CVBufferSetAttachment(output, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center, .shouldPropagate)
    CVBufferRemoveAttachment(output, kCVImageBufferChromaLocationBottomFieldKey)
    if configuration.downscale {
      CVBufferRemoveAttachment(output, kCVImageBufferCleanApertureKey)
      CVBufferRemoveAttachment(output, kCVImageBufferDisplayDimensionsKey)
    }
    // Only preserve a matrix we actually decoded. An arbitrary attachment is
    // not a valid color contract: the decode path intentionally falls back to
    // Rec.709 for unknown values, so carrying that unknown value to the output
    // would make downstream clients interpret the encoded pixels differently
    // from the matrix used to produce them.
    let outputMatrix: CFString
    if configuration.applyLUT {
      outputMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
    } else if matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String {
      outputMatrix = kCVImageBufferYCbCrMatrix_ITU_R_2020
    } else if matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String {
      outputMatrix = kCVImageBufferYCbCrMatrix_ITU_R_601_4
    } else {
      outputMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
    }
    CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, outputMatrix, .shouldPropagate)
    if configuration.applyLUT {
      CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
      CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    }
    return output
  }

  private func flushTextureCache(force: Bool) {
    if !force {
      textureCacheUses &+= 1
      guard textureCacheUses >= Self.textureCacheFlushInterval else { return }
    }
    textureCacheUses = 0
    CVMetalTextureCacheFlush(textureCache, 0)
  }
}
