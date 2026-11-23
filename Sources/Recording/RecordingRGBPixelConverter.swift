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
  private let packedTexturePipeline: MTLComputePipelineState
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
    packedTexturePipeline = try build("recordingPackedTextureRGB16")
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
      try self.submit(pipeline: self.pipeline, input: nil, texture: source, width: source.width, height: source.height,
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
    // with makeBuffer(bytesNoCopy:). Decode directly from a bounded native
    // texture view so the recorder never stages a second copy of the frame.
    // Eight-byte texels keep even a 16384-pixel R12L row under the
    // conservative Metal 4 texture limit. Tail texels may contain only owned
    // row padding; the raw decoder reads exactly the declared 36 bits/pixel.
    let view = try Self.sourceTextureLayout(width: width, height: height, format: format, physicalStride: physicalStride)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: view.pixelFormat, width: view.width, height: height, mipmapped: false)
    descriptor.storageMode = .shared; descriptor.usage = .shaderRead
    guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else {
      throw ConversionError.invalidInput("Packed RGB IOSurface cannot provide a bounded native texture view")
    }
    try submit(pipeline: packedTexturePipeline, input: nil, texture: texture, width: width, height: height,
      parameters: [UInt32(RGBFormat.allCases.firstIndex(of: format)!),
        (sourceRange ?? (format == .r210 ? .video : .full)) == .video ? 1 : 0],
      destination: destination, owner: source, sourceSurface: surface, completion: completion)
  }

  struct SourceTextureLayout {
    let pixelFormat: MTLPixelFormat
    let width: Int
    let viewRowBytes: Int
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
    let (viewBytes, viewOverflow) = texels.multipliedReportingOverflow(by: bytesPerTexel)
    guard !viewOverflow, texels <= 16384, viewBytes <= physicalStride else {
      throw ConversionError.invalidInput("RGB native texture view would exceed owned row storage")
    }
    return SourceTextureLayout(pixelFormat: format == .r12l ? .rgba16Uint : .rgba8Uint,
      width: texels, viewRowBytes: viewBytes)
  }

  func convert(packedRGB input: MTLBuffer, width: Int, height: Int, bytesPerRow: Int,
    format: RGBFormat, sourceRange: Colorimetry.Range? = nil, into destination: CVPixelBuffer) throws {
    let minimum = try format.minimumRowBytes(width: width)
    let (extent, overflow) = bytesPerRow.multipliedReportingOverflow(by: height)
    guard height > 0, !overflow, extent <= input.length, bytesPerRow >= minimum,
      input.device === device, width <= Int(UInt32.max), height <= Int(UInt32.max), bytesPerRow <= Int(UInt32.max) else {
      throw ConversionError.invalidInput("Invalid packed RGB input allocation")
    }
    try wait { completion in
      try self.submit(pipeline: self.packedPipeline, input: input, texture: nil, width: width, height: height,
        parameters: [UInt32(width), UInt32(height), UInt32(bytesPerRow), UInt32(RGBFormat.allCases.firstIndex(of: format)!),
          (sourceRange ?? (format == .r210 ? .video : .full)) == .video ? 1 : 0],
        destination: destination, owner: nil, completion: completion)
    }
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
      leases.forEach { $0.release() }; converter.slots.signal()
      if let error { completion(.failure(ConversionError.commandFailed(error.localizedDescription))) }
      else { completion(.success(())) }
    }
  }

  private func submit(pipeline: MTLComputePipelineState, input: MTLBuffer?, texture: MTLTexture?, width: Int, height: Int,
    parameters values: [UInt32], destination: CVPixelBuffer, owner: AnyObject?,
    sourceSurface: IOSurfaceRef? = nil,
    completion: @escaping @Sendable (Result<Void, Error>) -> Void) throws {
    guard width > 0, height > 0, width <= 16384, height <= 16384,
      CVPixelBufferGetPixelFormatType(destination) == Self.outputPixelFormat,
      CVPixelBufferGetWidth(destination) == width, CVPixelBufferGetHeight(destination) == height,
      !CVPixelBufferIsPlanar(destination), let surface = CVPixelBufferGetIOSurface(destination)?.takeUnretainedValue() else {
      throw ConversionError.invalidInput("Expected matching IOSurface RGBA16 destination")
    }
    if let inputSurface = sourceSurface ?? texture?.iosurface, IOSurfaceGetID(inputSurface) == IOSurfaceGetID(surface) {
      throw ConversionError.invalidInput("Source and destination alias the same IOSurface")
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
    if let texture, sourceSurface == nil {
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
    residency.commit()
    command.beginCommandBuffer(allocator: allocator)
    command.useResidencySet(residency)
    guard let encoder = command.makeComputeCommandEncoder() else {
      command.endCommandBuffer(); throw ConversionError.unavailable("RGB recording encoder unavailable")
    }
    encoder.setComputePipelineState(pipeline); encoder.setArgumentTable(table)
    encoder.dispatchThreads(threadsPerGrid: MTLSize(width: width, height: height, depth: 1),
      threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
    encoder.endEncoding(); command.endCommandBuffer()
    let submission = Submission(converter: self, destination: destination, owner: owner, input: input,
      textures: [output] + (texture.map { [$0] } ?? []), parameters: parameters, table: table,
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
  uint4 expandPackedRGB(uint3 codes, uint maximumCode, uint videoRange) {
    uint3 expanded;
    if (videoRange) {
      // Encoder l64r is full range. Legal video RGB maps to full range;
      // superblack/superwhite clip at this unsigned representation boundary.
      int black = maximumCode == 255 ? 16 : (maximumCode == 1023 ? 64 : 256);
      uint span = maximumCode == 255 ? 219 : (maximumCode == 1023 ? 876 : 3504);
      uint3 legal = uint3(clamp(int3(codes) - black, int3(0), int3(span)));
      expanded = (legal * 65535u + span / 2u) / span;
    } else {
      expanded = (codes * 65535u + maximumCode / 2u) / maximumCode;
    }
    return uint4(expanded, 65535u);
  }
  uint3 decodeRGBWord(uint4 bytes, uint format) {
    if (format < 2u) return format == 0u ? bytes.bgr : bytes.rgb;
    uint word = (bytes.r << 24) | (bytes.g << 16) | (bytes.b << 8) | bytes.a;
    return uint3((word >> 20) & 1023, (word >> 10) & 1023, word & 1023);
  }
  kernel void recordingPackedTextureRGB16(texture2d<uint, access::read> source [[texture(0)]],
    texture2d<uint, access::write> output [[texture(1)]], constant uint2 &p [[buffer(0)]],
    uint2 xy [[thread_position_in_grid]]) {
    if (xy.x >= output.get_width() || xy.y >= output.get_height()) return;
    uint3 codes;
    if (p.x < 3u) {
      codes = decodeRGBWord(source.read(xy), p.x);
    } else {
      // Each RGBA16 texel exposes 64 consecutive little-endian source bits.
      const uint bit = xy.x * 36u;
      const uint texel = bit / 64u;
      const uint shift = bit % 64u;
      ulong pixel = as_type<ulong>(ushort4(source.read(uint2(texel, xy.y)))) >> shift;
      if (shift + 36u > 64u) {
        pixel |= as_type<ulong>(ushort4(source.read(uint2(texel + 1u, xy.y)))) << (64u - shift);
      }
      codes = uint3(uint(pixel), uint(pixel >> 12), uint(pixel >> 24)) & 4095u;
    }
    output.write(expandPackedRGB(codes, p.x < 2u ? 255u : (p.x == 2u ? 1023u : 4095u), p.y), xy);
  }
  kernel void recordingPackedRGB16(device const uchar *bytes [[buffer(0)]],
    constant uint *p [[buffer(1)]], texture2d<uint, access::write> output [[texture(0)]],
    uint2 xy [[thread_position_in_grid]]) {
    if (xy.x >= p[0] || xy.y >= p[1]) return;
    device const uchar *row = bytes + ulong(xy.y) * p[2];
    uint3 codes; uint maximumCode;
    if (p[3] < 3u) {
      uint i = xy.x * 4;
      codes = decodeRGBWord(uint4(row[i], row[i+1], row[i+2], row[i+3]), p[3]);
      maximumCode = p[3] < 2u ? 255u : 1023u;
    } else {
      ulong bit = ulong(xy.x) * 36;
      for (uint c = 0; c < 3; ++c) {
        ulong b = bit + c * 12; uint shift = uint(b & 7); ulong i = b >> 3;
        codes[c] = ((uint(row[i]) | (uint(row[i+1]) << 8)) >> shift) & 4095;
      }
      maximumCode = 4095;
    }
    output.write(expandPackedRGB(codes, maximumCode, p[4]), xy);
  }
  """
}
