import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import Metal
import VideoToolbox

/// Full precision RGB repack for ProRes 4444. Declared video range expands
/// to the encoder full range; superblack/superwhite clip at that boundary. Metal 4
/// submissions retain the original, destination, and byte leases until feedback.
final class RecordingRGBPixelConverter: @unchecked Sendable {
  enum ConversionError: Error {
    case unavailable(String), invalidInput(String), commandFailed(String)
  }
  static let outputPixelFormat = kCVPixelFormatType_64RGBALE
  private let device: MTLDevice
  private let queue: MTL4CommandQueue
  private let pipeline: MTLComputePipelineState
  private let packedPipeline: MTLComputePipelineState
  let budget: GPUAllocationBudget
  private let slots = DispatchSemaphore(value: 3)
  private let submissionGate: MTLSharedEvent?
  #if ULTRACAM_TEST_SUPPORT
  var feedbackFailureForTesting: Error?
  #endif

  init(device: MTLDevice, budget: GPUAllocationBudget? = nil, submissionGate: MTLSharedEvent? = nil) throws {
    guard device.supportsFamily(.metal4) else { throw ConversionError.unavailable("RGB recording requires Metal 4") }
    self.device = device; self.submissionGate = submissionGate
    self.budget = try budget ?? GPUAllocationBudget(policy: GPUAllocationBudgetPolicy(maximumBytes: 512 * 1024 * 1024, minimumSlots: 1))
    queue = try device.makeMTL4CommandQueue(descriptor: MTL4CommandQueueDescriptor())
    let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
    let libraryDescriptor = MTL4LibraryDescriptor(); libraryDescriptor.source = Self.shader
    let library = try compiler.makeLibrary(descriptor: libraryDescriptor)
    func build(_ name: String) throws -> MTLComputePipelineState {
      let function = MTL4LibraryFunctionDescriptor(); function.library = library; function.name = name
      let descriptor = MTL4ComputePipelineDescriptor(); descriptor.computeFunctionDescriptor = function
      return try compiler.makeComputePipelineState(descriptor: descriptor)
    }
    pipeline = try build("recordingRGB16"); packedPipeline = try build("recordingPackedRGB16")
  }

  private final class WaitResult: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    var result: Result<Void, Error>?
  }
  private func wait(_ submit: (@escaping @Sendable (Result<Void, Error>) -> Void) throws -> Void) throws {
    let state = WaitResult()
    try submit { result in state.result = result; state.done.signal() }
    guard state.done.wait(timeout: .now() + 2) == .success else {
      throw ConversionError.commandFailed("RGB recording GPU submission exceeded two seconds")
    }
    try state.result!.get()
  }

  func convert(decodedRGB source: MTLTexture, sourceBitDepth: Int, into destination: CVPixelBuffer) throws {
    guard (8...16).contains(sourceBitDepth), source.pixelFormat == .rgba32Float, source.device === device else {
      throw ConversionError.invalidInput("RGB repack requires full precision rgba32Float")
    }
    try wait { completion in
      try self.submit(input: nil, texture: source, width: source.width, height: source.height,
        parameters: [UInt32((1 << sourceBitDepth) - 1)], destination: destination, owner: nil, completion: completion)
    }
  }

  func convert(_ source: CVPixelBuffer, format: RGBFormat, sourceRange: Colorimetry.Range? = nil, into destination: CVPixelBuffer) throws {
    try wait { completion in try self.convert(source, format: format, sourceRange: sourceRange, into: destination, completion: completion) }
  }

  /// Returns after bounded admission/encoding, before GPU completion. Failure to
  /// admit throws; accepted submissions report exactly one completion result.
  func convert(_ source: CVPixelBuffer, format: RGBFormat, sourceRange: Colorimetry.Range? = nil, into destination: CVPixelBuffer,
    completion: @escaping @Sendable (Result<Void, Error>) -> Void) throws {
    let expected: OSType
    switch format {
    case .bgra8: expected = kCVPixelFormatType_32BGRA
    case .rgba8: expected = kCVPixelFormatType_32RGBA
    case .r210: expected = 0x72323130
    case .r12l: expected = 0x5231324c
    }
    let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
    let logicalBytes = try format.minimumRowBytes(width: width)
    let physicalStride = CVPixelBufferGetBytesPerRow(source)
    let (physicalExtent, physicalOverflow) = physicalStride.multipliedReportingOverflow(by: height)
    guard CVPixelBufferGetPixelFormatType(source) == expected, !CVPixelBufferIsPlanar(source),
      height > 0, logicalBytes <= physicalStride, !physicalOverflow,
      let surface = CVPixelBufferGetIOSurface(source)?.takeUnretainedValue(),
      physicalExtent <= IOSurfaceGetAllocSize(surface) else {
      throw ConversionError.invalidInput("Packed RGB recording requires bounded original IOSurface storage")
    }
    // A CV IOSurface may own fewer bytes than a VM page. Never alias its base
    // with makeBuffer(bytesNoCopy:). Read only a bounded native texture view,
    // then copy on the GPU into a Metal-owned private allocation.
    // Eight-byte texels keep even a 16384-pixel R12L row under the
    // conservative Metal 4 texture limit. Tail texels may contain only owned
    // row padding; the raw decoder reads exactly the declared 36 bits/pixel.
    let view = try Self.sourceTextureLayout(width: width, height: height, format: format, physicalStride: physicalStride)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: view.pixelFormat, width: view.width, height: height, mipmapped: false)
    descriptor.storageMode = .shared; descriptor.usage = .shaderRead
    let (aligned, alignmentOverflow) = logicalBytes.addingReportingOverflow(255)
    guard !alignmentOverflow else { throw ConversionError.invalidInput("RGB staging stride overflow") }
    let stride = aligned / 256 * 256
    let (bytes, overflow) = stride.multipliedReportingOverflow(by: height)
    guard !overflow, let view = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0),
      let input = device.makeBuffer(length: bytes, options: .storageModePrivate) else {
      throw ConversionError.invalidInput("Packed RGB IOSurface cannot provide a bounded native texture view")
    }
    try submitPacked(input: input, width: width, height: height, stride: stride,
      format: format, sourceRange: sourceRange, destination: destination,
      owner: source, copySource: view, sourceSurface: surface, completion: completion)
  }

  struct SourceTextureLayout {
    let pixelFormat: MTLPixelFormat
    let width: Int
    let copiedRowBytes: Int
  }

  static func sourceTextureLayout(width: Int, height: Int, format: RGBFormat,
    physicalStride: Int) throws -> SourceTextureLayout {
    // Apple 7-9 provide at least 16384; avoid ever constructing an invalid
    // descriptor (Metal validation can terminate the process before returning nil).
    guard width > 0, height > 0, width <= 16384, height <= 16384 else {
      throw ConversionError.invalidInput("RGB dimensions exceed the supported Metal texture bounds")
    }
    let logical = try format.minimumRowBytes(width: width)
    let bytesPerTexel = format == .r12l ? 8 : 4
    let (tail, overflow) = logical.addingReportingOverflow(bytesPerTexel - 1)
    guard !overflow else { throw ConversionError.invalidInput("RGB texture row overflow") }
    let texels = tail / bytesPerTexel
    let (copied, copyOverflow) = texels.multipliedReportingOverflow(by: bytesPerTexel)
    guard !copyOverflow, texels <= 16384, copied <= physicalStride else {
      throw ConversionError.invalidInput("RGB native texture view would exceed owned row storage")
    }
    return SourceTextureLayout(pixelFormat: format == .r12l ? .rgba16Uint : .rgba8Uint,
      width: texels, copiedRowBytes: copied)
  }

  func convert(packedRGB input: MTLBuffer, width: Int, height: Int, bytesPerRow: Int,
    format: RGBFormat, sourceRange: Colorimetry.Range? = nil, into destination: CVPixelBuffer) throws {
    try wait { completion in
      try self.submitPacked(input: input, width: width, height: height, stride: bytesPerRow,
        format: format, sourceRange: sourceRange, destination: destination, owner: nil, completion: completion)
    }
  }

  private func submitPacked(input: MTLBuffer, width: Int, height: Int, stride: Int,
    format: RGBFormat, sourceRange: Colorimetry.Range?, destination: CVPixelBuffer, owner: AnyObject?,
    copySource: MTLTexture? = nil, sourceSurface: IOSurfaceRef? = nil,
    completion: @escaping @Sendable (Result<Void, Error>) -> Void) throws {
    let minimum = try format.minimumRowBytes(width: width)
    let (extent, overflow) = stride.multipliedReportingOverflow(by: height)
    guard height > 0, !overflow, extent <= input.length, stride >= minimum,
      input.device === device, width <= Int(UInt32.max), height <= Int(UInt32.max), stride <= Int(UInt32.max) else {
      throw ConversionError.invalidInput("Invalid packed RGB input allocation")
    }
    try submit(input: input, texture: nil, width: width, height: height,
      parameters: [UInt32(width), UInt32(height), UInt32(stride), UInt32(RGBFormat.allCases.firstIndex(of: format)!),
        (sourceRange ?? (format == .r210 ? .video : .full)) == .video ? 1 : 0],
      destination: destination, owner: owner, copySource: copySource, sourceSurface: sourceSurface, completion: completion)
  }

  private final class Submission: @unchecked Sendable {
    let converter: RecordingRGBPixelConverter
    let destination: CVPixelBuffer
    let sourceOwner: AnyObject?
    let input: MTLBuffer?
    let textures: [MTLTexture]
    let parameters: MTLBuffer
    let table: MTL4ArgumentTable
    let allocator: MTL4CommandAllocator
    let command: MTL4CommandBuffer
    let residency: MTLResidencySet
    let leases: [GPUAllocationBudget.Lease]
    let completion: @Sendable (Result<Void, Error>) -> Void
    init(converter: RecordingRGBPixelConverter, destination: CVPixelBuffer, owner: AnyObject?, input: MTLBuffer?,
      textures: [MTLTexture], parameters: MTLBuffer, table: MTL4ArgumentTable, allocator: MTL4CommandAllocator,
      command: MTL4CommandBuffer, residency: MTLResidencySet, leases: [GPUAllocationBudget.Lease],
      completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
      self.converter = converter; self.destination = destination; sourceOwner = owner; self.input = input
      self.textures = textures; self.parameters = parameters; self.table = table; self.allocator = allocator
      self.command = command; self.residency = residency; self.leases = leases; self.completion = completion
    }
    func finish(_ error: Error?) {
      converter.queue.removeResidencySet(residency)
      leases.forEach { $0.release() }; converter.slots.signal()
      if let error { completion(.failure(ConversionError.commandFailed(error.localizedDescription))) }
      else { completion(.success(())) }
    }
  }

  private func submit(input: MTLBuffer?, texture: MTLTexture?, width: Int, height: Int,
    parameters values: [UInt32], destination: CVPixelBuffer, owner: AnyObject?,
    copySource: MTLTexture? = nil, sourceSurface: IOSurfaceRef? = nil,
    completion: @escaping @Sendable (Result<Void, Error>) -> Void) throws {
    guard CVPixelBufferGetPixelFormatType(destination) == Self.outputPixelFormat,
      CVPixelBufferGetWidth(destination) == width, CVPixelBufferGetHeight(destination) == height,
      !CVPixelBufferIsPlanar(destination), let surface = CVPixelBufferGetIOSurface(destination)?.takeUnretainedValue() else {
      throw ConversionError.invalidInput("Expected matching IOSurface RGBA16 destination")
    }
    guard slots.wait(timeout: .now()) == .success else { throw ConversionError.unavailable("RGB recording in-flight limit reached") }
    var submitted = false
    defer { if !submitted { slots.signal() } }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Uint, width: width, height: height, mipmapped: false)
    descriptor.storageMode = .shared; descriptor.usage = [.shaderWrite]
    guard let output = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0),
      let parameters = device.makeBuffer(bytes: values, length: values.count * 4),
      let command = device.makeCommandBuffer(), let allocator = device.makeCommandAllocator() else {
      throw ConversionError.unavailable("RGB recording GPU allocation failed")
    }
    var leases: [GPUAllocationBudget.Lease] = []
    leases.append(try budget.acquire(backingID: UInt64(UInt(bitPattern: IOSurfaceGetBaseAddress(surface))),
      bytes: IOSurfaceGetAllocSize(surface), generation: 0, owner: surface))
    if let sourceSurface {
      leases.append(try budget.acquire(backingID: UInt64(UInt(bitPattern: IOSurfaceGetBaseAddress(sourceSurface))),
        bytes: IOSurfaceGetAllocSize(sourceSurface), generation: 0, owner: sourceSurface))
    }
    if let input {
      leases.append(try budget.acquire(backingID: input.gpuAddress, bytes: input.allocatedSize, generation: 0, owner: input))
    }
    if let texture {
      leases.append(try budget.acquire(backingID: UInt64(UInt(bitPattern: Unmanaged.passUnretained(texture as AnyObject).toOpaque())),
        bytes: texture.allocatedSize, generation: 0, owner: texture))
    }
    leases.append(try budget.acquire(backingID: parameters.gpuAddress, bytes: parameters.allocatedSize, generation: 0, owner: parameters))
    let residency = try device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
    residency.addAllocation(output); residency.addAllocation(parameters)
    let tableDescriptor = MTL4ArgumentTableDescriptor()
    tableDescriptor.maxBufferBindCount = 2; tableDescriptor.maxTextureBindCount = 2
    let table = try device.makeArgumentTable(descriptor: tableDescriptor)
    if let input { table.setAddress(input.gpuAddress, index: 0); residency.addAllocation(input) }
    table.setAddress(parameters.gpuAddress, index: input == nil ? 0 : 1)
    if let texture { table.setTexture(texture.gpuResourceID, index: 0); residency.addAllocation(texture) }
    table.setTexture(output.gpuResourceID, index: input == nil ? 1 : 0)
    command.beginCommandBuffer(allocator: allocator)
    if let copySource, let input {
      residency.addAllocation(copySource)
      guard let copy = command.makeComputeCommandEncoder() else {
        command.endCommandBuffer(); throw ConversionError.unavailable("RGB staging GPU copy unavailable")
      }
      copy.copy(sourceTexture: copySource, sourceSlice: 0, sourceLevel: 0,
        sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
        sourceSize: MTLSize(width: copySource.width, height: copySource.height, depth: 1),
        destinationBuffer: input, destinationOffset: 0, destinationBytesPerRow: Int(values[2]), destinationBytesPerImage: 0)
      copy.endEncoding()
    }
    guard let encoder = command.makeComputeCommandEncoder() else {
      command.endCommandBuffer(); throw ConversionError.unavailable("RGB recording encoder unavailable")
    }
    if copySource != nil {
      // Metal 4 does not infer dependencies between encoders. The decode must
      // observe completed private-buffer writes from the preceding blit pass.
      encoder.barrier(afterQueueStages: .blit, beforeStages: .dispatch, visibilityOptions: [])
    }
    encoder.setComputePipelineState(input == nil ? pipeline : packedPipeline); encoder.setArgumentTable(table)
    encoder.dispatchThreads(threadsPerGrid: MTLSize(width: width, height: height, depth: 1),
      threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
    encoder.endEncoding(); command.endCommandBuffer(); residency.commit(); queue.addResidencySet(residency)
    let submission = Submission(converter: self, destination: destination, owner: owner, input: input,
      textures: [output] + (texture.map { [$0] } ?? []) + (copySource.map { [$0] } ?? []), parameters: parameters, table: table,
      allocator: allocator, command: command, residency: residency, leases: leases, completion: completion)
    let options = MTL4CommitOptions()
    options.addFeedbackHandler { feedback in
      #if ULTRACAM_TEST_SUPPORT
      submission.finish(self.feedbackFailureForTesting ?? feedback.error)
      #else
      submission.finish(feedback.error)
      #endif
    }
    if let submissionGate { queue.waitForEvent(submissionGate, value: 1) }
    queue.commit([command], options: options); submitted = true
  }

  /// A successful pixel repack does not establish codec support. Probe the
  /// exact integer input contract before opening a take; never substitute a
  /// lower precision input when the system refuses it.
  static func validateEncoderInput(width: Int, height: Int) throws {
    guard width > 0, height > 0, width <= Int(Int32.max), height <= Int(Int32.max) else {
      throw ConversionError.invalidInput("Invalid ProRes 4444 dimensions")
    }
    let attributes = [kCVPixelBufferPixelFormatTypeKey: outputPixelFormat,
      kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height] as CFDictionary
    var session: VTCompressionSession?
    let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
      codecType: kCMVideoCodecType_AppleProRes4444, encoderSpecification: [
        kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
      ] as CFDictionary, imageBufferAttributes: attributes, compressedDataAllocator: nil,
      outputCallback: nil, refcon: nil, compressionSessionOut: &session)
    guard status == noErr, let session else {
      throw ConversionError.unavailable("VideoToolbox refused ProRes 4444 RGBA16 input (\(status))")
    }
    defer { VTCompressionSessionInvalidate(session) }
    let prepared = VTCompressionSessionPrepareToEncodeFrames(session)
    guard prepared == noErr else {
      throw ConversionError.unavailable("VideoToolbox cannot prepare ProRes 4444 RGBA16 input (\(prepared))")
    }
  }

  private static let shader = """
  #include <metal_stdlib>
  using namespace metal;
  kernel void recordingRGB16(texture2d<float, access::read> source [[texture(0)]],
    texture2d<uint, access::write> output [[texture(1)]], constant uint &maximumCode [[buffer(0)]],
    uint2 p [[thread_position_in_grid]]) {
    if (p.x >= output.get_width() || p.y >= output.get_height()) return;
    float3 rgb = clamp(source.read(p).rgb, 0.0f, 1.0f);
    // Rounding preserves every source code when normalized RGB has 16 or
    // fewer bits; alpha is intentionally opaque under B5's alpha policy.
    uint3 codes = uint3(round(rgb * float(maximumCode)));
    uint3 expanded = (codes * 65535u + maximumCode / 2u) / maximumCode;
    output.write(uint4(expanded, 65535u), p);
  }
  kernel void recordingPackedRGB16(device const uchar *bytes [[buffer(0)]],
    constant uint *p [[buffer(1)]], texture2d<uint, access::write> output [[texture(0)]],
    uint2 xy [[thread_position_in_grid]]) {
    if (xy.x >= p[0] || xy.y >= p[1]) return;
    device const uchar *row = bytes + ulong(xy.y) * p[2];
    uint3 codes; uint maximumCode;
    if (p[3] < 2) {
      uint i = xy.x * 4; codes = uint3(row[i], row[i+1], row[i+2]);
      if (p[3] == 0) codes = codes.bgr;
      maximumCode = 255;
    } else if (p[3] == 2) {
      uint i = xy.x * 4;
      uint word = (uint(row[i]) << 24) | (uint(row[i+1]) << 16) | (uint(row[i+2]) << 8) | uint(row[i+3]);
      codes = uint3((word >> 20) & 1023, (word >> 10) & 1023, word & 1023);
      maximumCode = 1023;
    } else {
      ulong bit = ulong(xy.x) * 36;
      for (uint c = 0; c < 3; ++c) {
        ulong b = bit + c * 12; uint shift = uint(b & 7); ulong i = b >> 3;
        codes[c] = ((uint(row[i]) | (uint(row[i+1]) << 8)) >> shift) & 4095;
      }
      maximumCode = 4095;
    }
    uint3 expanded;
    if (p[4] != 0) {
      // Encoder l64r is full range. Legal video RGB maps to full range;
      // superblack/superwhite clip at this unsigned representation boundary.
      int black = maximumCode == 255 ? 16 : (maximumCode == 1023 ? 64 : 256);
      uint span = maximumCode == 255 ? 219 : (maximumCode == 1023 ? 876 : 3504);
      uint3 legal = uint3(clamp(int3(codes) - black, int3(0), int3(span)));
      expanded = (legal * 65535u + span / 2u) / span;
    } else {
      expanded = (codes * 65535u + maximumCode / 2u) / maximumCode;
    }
    output.write(uint4(expanded, 65535u), xy);
  }
  """
}
