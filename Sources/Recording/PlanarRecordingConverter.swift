import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import Metal

/// Recording-only native planar conversion. No resize or chroma resampling:
/// 420f maps to video-range 420v; I420 interleaves separate U/V into 420v.
/// P216/PA16 quantize native 16-bit codes to x422; PA16 alpha is validated,
/// retained, and explicitly ignored. Video-range 420v can go directly to HEVC
/// Main; authoritative full-range 420v is requantized into distinct storage.
final class PlanarRecordingConverter: @unchecked Sendable {
  enum ConversionError: Error { case unavailable, unsupportedFormat, invalidLayout, gpuFailed(String), timedOut }
  private let device: MTLDevice
  private let queue: MTL4CommandQueue
  private let pipeline: MTLComputePipelineState
  private let slots = DispatchSemaphore(value: 3)
  let budget: GPUAllocationBudget

  static func supports(source: OSType, destination: OSType) -> Bool {
    ([kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, OSType(0x49343230)].contains(source) && destination == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) ||
      ([OSType(0x50323136), OSType(0x50413136)].contains(source) && destination == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
  }

  init(device: MTLDevice, budget: GPUAllocationBudget? = nil) throws {
    guard device.supportsFamily(.metal4) else { throw ConversionError.unavailable }
    self.device = device
    self.budget = try budget ?? GPUAllocationBudget(policy: GPUAllocationBudgetPolicy(maximumBytes: 512 * 1024 * 1024, minimumSlots: 1))
    queue = try device.makeMTL4CommandQueue(descriptor: MTL4CommandQueueDescriptor())
    let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
    let ld = MTL4LibraryDescriptor(); ld.source = Self.shader
    let library = try compiler.makeLibrary(descriptor: ld)
    let function = MTL4LibraryFunctionDescriptor(); function.library = library; function.name = "convertPlanarRecording"
    let pd = MTL4ComputePipelineDescriptor(); pd.computeFunctionDescriptor = function
    pipeline = try compiler.makeComputePipelineState(descriptor: pd)
  }

  private final class Wait: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    var result: Result<Void, Error>?
  }
  func convert(_ source: CVPixelBuffer, sourceRange: Colorimetry.Range? = nil, into destination: CVPixelBuffer) throws {
    let wait = Wait()
    try convert(source, sourceRange: sourceRange, into: destination) { result in wait.result = result; wait.done.signal() }
    guard wait.done.wait(timeout: .now() + 2) == .success else { throw ConversionError.timedOut }
    try wait.result!.get()
  }

  /// Accepted work owns both buffers and budget leases through Metal feedback,
  /// even when a synchronous caller times out or a take is stopped.
  func convert(_ source: CVPixelBuffer, sourceRange: Colorimetry.Range? = nil, into destination: CVPixelBuffer,
    completion: @escaping @Sendable (Result<Void, Error>) -> Void) throws {
    let sourceType = CVPixelBufferGetPixelFormatType(source), destinationType = CVPixelBufferGetPixelFormatType(destination)
    guard Self.supports(source: sourceType, destination: destinationType) else { throw ConversionError.unsupportedFormat }
    let sixteen = sourceType == 0x50323136 || sourceType == 0x50413136
    let i420 = sourceType == 0x49343230
    let ndi: NDIPlanarLayout? = i420 ? .i420 : (sourceType == 0x50413136 ? .pa16 : nil)
    let sourcePlaneCount = ndi == nil ? 2 : 3
    let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
    guard width > 0, height > 0, width.isMultiple(of: 2), sixteen || height.isMultiple(of: 2),
      CVPixelBufferGetWidth(destination) == width, CVPixelBufferGetHeight(destination) == height,
      CVPixelBufferIsPlanar(source), CVPixelBufferIsPlanar(destination),
      CVPixelBufferGetPlaneCount(source) == sourcePlaneCount, CVPixelBufferGetPlaneCount(destination) == 2,
      let inputSurface = CVPixelBufferGetIOSurface(source)?.takeUnretainedValue(),
      let outputSurface = CVPixelBufferGetIOSurface(destination)?.takeUnretainedValue(),
      inputSurface !== outputSurface else { throw ConversionError.invalidLayout }
    if let ndi {
      let descriptors = try ndi.planes(width: width, height: height)
      for (plane, descriptor) in descriptors.enumerated() {
        let stride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
        let (length, overflow) = stride.multipliedReportingOverflow(by: descriptor.height)
        let offset = IOSurfaceGetBaseAddress(inputSurface).distance(to: IOSurfaceGetBaseAddressOfPlane(inputSurface, plane))
        let (end, extentOverflow) = offset.addingReportingOverflow(length)
        guard !overflow, !extentOverflow, offset >= 0, end <= IOSurfaceGetAllocSize(inputSurface),
          stride >= descriptor.minimumRowBytes, stride.isMultiple(of: descriptor.componentBytes),
          CVPixelBufferGetWidthOfPlane(source, plane) == descriptor.width,
          CVPixelBufferGetHeightOfPlane(source, plane) == descriptor.height,
          IOSurfaceGetPlaneCount(inputSurface) == sourcePlaneCount,
          IOSurfaceGetWidthOfPlane(inputSurface, plane) == descriptor.width,
          IOSurfaceGetHeightOfPlane(inputSurface, plane) == descriptor.height,
          IOSurfaceGetBytesPerRowOfPlane(inputSurface, plane) == stride else { throw ConversionError.invalidLayout }
      }
    }
    guard slots.wait(timeout: .now()) == .success else { throw ConversionError.unavailable }
    var submitted = false
    defer { if !submitted { slots.signal() } }
    var leases: [GPUAllocationBudget.Lease] = []
    for surface in [inputSurface, outputSurface] {
      leases.append(try budget.acquire(backingID: UInt64(UInt(bitPattern: IOSurfaceGetBaseAddress(surface))),
        bytes: IOSurfaceGetAllocSize(surface), generation: 0, owner: surface))
    }
    let allocator = device.makeCommandAllocator(), command = device.makeCommandBuffer()
    guard let allocator, let command else { throw ConversionError.unavailable }
    let residency = try device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
    var tables: [MTL4ArgumentTable] = [], textures: [MTLTexture] = [], parameters: [MTLBuffer] = []
    command.beginCommandBuffer(allocator: allocator)
    var ended = false
    defer { if !ended { command.endCommandBuffer() } }
    for plane in 0..<2 {
      let pw = plane == 0 ? width : width / 2
      let ph = plane == 0 || sixteen ? height : height / 2
      for (buffer, surface) in [(source, inputSurface), (destination, outputSurface)] {
        let sourceBuffer = buffer === source
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        let (minimum, overflow) = pw.multipliedReportingOverflow(by: (plane == 0 || (i420 && sourceBuffer) ? 1 : 2) * (sixteen ? 2 : 1))
        let (length, lengthOverflow) = stride.multipliedReportingOverflow(by: ph)
        guard !overflow, !lengthOverflow, length > 0, stride >= minimum, stride.isMultiple(of: sixteen ? 2 : 1),
          CVPixelBufferGetWidthOfPlane(buffer, plane) == pw, CVPixelBufferGetHeightOfPlane(buffer, plane) == ph,
          IOSurfaceGetPlaneCount(surface) == (sourceBuffer ? sourcePlaneCount : 2), IOSurfaceGetWidthOfPlane(surface, plane) == pw,
          IOSurfaceGetHeightOfPlane(surface, plane) == ph, IOSurfaceGetBytesPerRowOfPlane(surface, plane) == stride else { throw ConversionError.invalidLayout }
        let baseAddress = IOSurfaceGetBaseAddress(surface), planeAddress = IOSurfaceGetBaseAddressOfPlane(surface, plane)
        let offset = baseAddress.distance(to: planeAddress)
        let (end, extentOverflow) = offset.addingReportingOverflow(length)
        guard offset >= 0, !extentOverflow, end <= IOSurfaceGetAllocSize(surface) else { throw ConversionError.invalidLayout }
      }
      let format: MTLPixelFormat = sixteen ? (plane == 0 ? .r16Uint : .rg16Uint) : (plane == 0 ? .r8Uint : .rg8Uint)
      func texture(_ surface: IOSurfaceRef, usage: MTLTextureUsage, textureFormat: MTLPixelFormat, index: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: textureFormat, width: pw, height: ph, mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = usage
        guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: index) else { throw ConversionError.invalidLayout }
        return texture
      }
      let input = try texture(inputSurface, usage: .shaderRead, textureFormat: i420 ? .r8Uint : format, index: plane)
      let output = try texture(outputSurface, usage: .shaderWrite, textureFormat: format, index: plane)
      let separateV = i420 && plane == 1 ? try texture(inputSurface, usage: .shaderRead, textureFormat: .r8Uint, index: 2) : input
      let range = sourceRange ?? (sourceType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ? .full : .video)
      let values: [UInt32] = [sixteen ? 1 : 0, range == .full ? 1 : 0, plane == 0 ? 1 : 0, i420 && plane == 1 ? 1 : 0]
      guard let parameter = device.makeBuffer(bytes: values, length: values.count * 4) else { throw ConversionError.unavailable }
      leases.append(try budget.acquire(backingID: parameter.gpuAddress, bytes: parameter.allocatedSize, generation: 0, owner: parameter))
      let td = MTL4ArgumentTableDescriptor(); td.maxBufferBindCount = 1; td.maxTextureBindCount = 3
      let table = try device.makeArgumentTable(descriptor: td)
      table.setAddress(parameter.gpuAddress, index: 0); table.setTexture(input.gpuResourceID, index: 0); table.setTexture(output.gpuResourceID, index: 1)
      table.setTexture(separateV.gpuResourceID, index: 2)
      for texture in [input, output, separateV] { residency.addAllocation(texture) }
      residency.addAllocation(parameter)
      guard let encoder = command.makeComputeCommandEncoder() else { throw ConversionError.unavailable }
      encoder.setComputePipelineState(pipeline); encoder.setArgumentTable(table)
      encoder.dispatchThreads(threadsPerGrid: MTLSize(width: pw, height: ph, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 1))
      encoder.endEncoding(); tables.append(table); parameters.append(parameter); textures += [input, output, separateV]
    }
    command.endCommandBuffer(); ended = true
    CVBufferPropagateAttachments(source, destination)
    // The destination fourCC and its format description must both declare video
    // range; never retain a producer's optional full-range extension after remap.
    CVBufferSetAttachment(destination, kCMFormatDescriptionExtension_FullRangeVideo, kCFBooleanFalse, .shouldPropagate)
    residency.commit(); queue.addResidencySet(residency)
    let resources = Submission(converter: self, buffers: [source, destination], allocator: allocator,
      command: command, residency: residency, tables: tables, parameters: parameters, textures: textures, leases: leases, completion: completion)
    let options = MTL4CommitOptions(); options.addFeedbackHandler { feedback in resources.finish(feedback.error) }
    queue.commit([command], options: options); submitted = true
  }

  private final class Submission: @unchecked Sendable {
    let converter: PlanarRecordingConverter; let buffers: [CVPixelBuffer]
    let allocator: MTL4CommandAllocator; let command: MTL4CommandBuffer; let residency: MTLResidencySet
    let tables: [MTL4ArgumentTable]; let parameters: [MTLBuffer]; let textures: [MTLTexture]; let leases: [GPUAllocationBudget.Lease]
    let completion: @Sendable (Result<Void, Error>) -> Void
    init(converter: PlanarRecordingConverter, buffers: [CVPixelBuffer], allocator: MTL4CommandAllocator,
      command: MTL4CommandBuffer, residency: MTLResidencySet, tables: [MTL4ArgumentTable], parameters: [MTLBuffer],
      textures: [MTLTexture], leases: [GPUAllocationBudget.Lease], completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
      self.converter = converter; self.buffers = buffers; self.allocator = allocator; self.command = command; self.residency = residency
      self.tables = tables; self.parameters = parameters; self.textures = textures; self.leases = leases; self.completion = completion
    }
    func finish(_ error: Error?) {
      converter.queue.removeResidencySet(residency); leases.forEach { $0.release() }; converter.slots.signal()
      if let error { completion(.failure(ConversionError.gpuFailed(error.localizedDescription))) } else { completion(.success(())) }
    }
  }

  private static let shader = """
  #include <metal_stdlib>
  using namespace metal;
  kernel void convertPlanarRecording(texture2d<uint,access::read> source [[texture(0)]],
    texture2d<uint,access::write> destination [[texture(1)]], texture2d<uint,access::read> v [[texture(2)]],
    constant uint4 &p [[buffer(0)]], uint2 pos [[thread_position_in_grid]]) {
    if (pos.x >= destination.get_width() || pos.y >= destination.get_height()) return;
    uint4 codes = source.read(pos);
    if (p.w == 1u) codes.g = v.read(pos).r;
    if (p.x == 1u && p.y == 0u) codes = min((codes + 32u) >> 6u, uint4(1023u)) << 6u;
    else if (p.y == 1u) {
      float maximum = p.x == 1u ? 65535.0f : 255.0f;
      float scale = p.x == 1u ? 4.0f : 1.0f;
      float4 c = float4(codes);
      c = p.z == 1u ? 16.0f * scale + c * (219.0f * scale / maximum) :
        128.0f * scale + (c - (p.x == 1u ? 32768.0f : 128.0f)) * (224.0f * scale / maximum);
      codes = uint4(clamp(round(c), 0.0f, p.x == 1u ? 1023.0f : 255.0f));
      if (p.x == 1u) codes <<= 6u;
    }
    destination.write(codes, pos);
  }
  """
}
