import CoreVideo
import IOSurface
import Metal
import Foundation

/// One-shot native-storage GPU copies; no cross-frame pointer cache. Plane
/// layout and alpha storage are preserved, with no colour conversion/relabeling.
final class CPUMemoryGPUIngest: @unchecked Sendable {
  private let device: MTLDevice
  private let pipeline: MTLComputePipelineState
  private let serial = DispatchQueue(label: "org.ultracam.cpu-memory-ingest")

  init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
    guard let device, device.supportsFamily(.metal4) else { throw Self.failure("CPU-memory ingest requires Metal 4") }
    self.device = device
    let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
    let libraryDescriptor = MTL4LibraryDescriptor()
    libraryDescriptor.source = """
      #include <metal_stdlib>
      using namespace metal;
      kernel void ingest(device const uchar *src [[buffer(0)]],
        constant uint4 *params [[buffer(1)]], texture2d<uint, access::write> dst [[texture(0)]],
        uint2 p [[thread_position_in_grid]]) {
        uint4 layout = params[0], packing = params[1];
        if (p.x >= layout.x || p.y >= layout.y) return;
        ulong i = ulong(layout.w) + ulong(p.y) * layout.z + ulong(p.x) * packing.x * packing.y;
        uint4 value = 0;
        for (uint c = 0; c < packing.y; ++c) {
          ulong column = ulong(p.x) * packing.x * packing.y + c * packing.x;
          if (column < packing.z) {
            value[c] = src[i+c*packing.x];
            if (packing.x == 2 && column + 1 < packing.z) value[c] |= uint(src[i+c*packing.x+1]) << 8;
          }
        }
        dst.write(value, p);
      }
      """
    let library = try compiler.makeLibrary(descriptor: libraryDescriptor)
    let function = MTL4LibraryFunctionDescriptor(); function.library = library; function.name = "ingest"
    let descriptor = MTL4ComputePipelineDescriptor(); descriptor.computeFunctionDescriptor = function
    pipeline = try compiler.makeComputePipelineState(descriptor: descriptor)
  }

  func ingest(_ frame: CapturedCPUMemoryFrame,
    completion: @escaping @Sendable (Result<CapturedPixelBuffer, Error>) -> Void) {
    serial.async { [self] in
      do { try encode(frame, completion: completion) }
      catch { completion(.failure(error)) }
    }
  }

  private func encode(_ frame: CapturedCPUMemoryFrame,
    completion: @escaping @Sendable (Result<CapturedPixelBuffer, Error>) -> Void) throws {
    let layouts = try frame.validatedPlaneLayouts()
    let lease = try frame.lease()
    guard lease.pixelOffset <= Int(UInt32.max), lease.byteLength <= Int(UInt32.max) - lease.pixelOffset,
      let pointer = UnsafeMutableRawPointer(bitPattern: lease.roundedBaseAddress),
      let buffer = device.makeBuffer(bytesNoCopy: pointer, length: lease.roundedLength,
        options: .storageModeShared, deallocator: nil) else { throw Self.failure("Unsafe or unwrappable SDK allocation; CPU compatibility copy required") }
    try CPUMemoryPixelFormatRegistration.ensure(frame.pixelFormat)
    var image: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, frame.width, frame.height, frame.pixelFormat,
      [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &image)
    guard status == kCVReturnSuccess, let image, let surface = CVPixelBufferGetIOSurface(image)?.takeUnretainedValue() else { throw Self.failure("Cannot allocate ingest IOSurface") }
    let planar = layouts.count > 1
    guard CVPixelBufferGetPlaneCount(image) == (planar ? layouts.count : 0) else { throw NoCopyIngestError.invalidLength }
    let queue = try device.makeMTL4CommandQueue(descriptor: MTL4CommandQueueDescriptor())
    let residency = try device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
    guard let allocator = device.makeCommandAllocator(), let command = device.makeCommandBuffer() else { throw Self.failure("Cannot create ingest command") }
    var textures: [MTLTexture] = [], parameters: [MTLBuffer] = [], tables: [MTL4ArgumentTable] = []
    residency.addAllocation(buffer)
    command.beginCommandBuffer(allocator: allocator)
    do {
      for (index, layout) in layouts.enumerated() {
        let source = frame.planes[index]
        guard source.bytesPerRow <= Int(UInt32.max), source.offset <= Int(UInt32.max) - lease.pixelOffset else { throw NoCopyIngestError.arithmeticOverflow }
        if planar {
          // UYVA's packed plane has CV pixel width, while its Metal texels
          // represent two-pixel UYVY groups. All other planes match directly.
          let expectedWidth = frame.pixelFormat == 0x55595641 && index == 0 ? frame.width : layout.width
          guard CVPixelBufferGetWidthOfPlane(image, index) == expectedWidth,
            CVPixelBufferGetHeightOfPlane(image, index) == layout.height,
            CVPixelBufferGetBytesPerRowOfPlane(image, index) >= layout.minimumRowBytes else { throw NoCopyIngestError.invalidLength }
        }
        let destinationStride = planar ? CVPixelBufferGetBytesPerRowOfPlane(image, index) : CVPixelBufferGetBytesPerRow(image)
        guard destinationStride >= layout.textureRowBytes else { throw NoCopyIngestError.invalidLength }
        let format: MTLPixelFormat
        switch (layout.componentBytes, layout.components) {
        case (1, 1): format = .r8Uint
        case (1, 2): format = .rg8Uint
        case (1, 4): format = .rgba8Uint
        case (2, 1): format = .r16Uint
        case (2, 2): format = .rg16Uint
        case (2, 4): format = .rgba16Uint
        default: throw NoCopyIngestError.unsupportedPixelFormat
        }
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: layout.width, height: layout.height, mipmapped: false)
        td.storageMode = .shared; td.usage = .shaderWrite
        guard let texture = device.makeTexture(descriptor: td, iosurface: surface, plane: index),
          let params = device.makeBuffer(length: 32, options: .storageModeShared) else { throw Self.failure("Cannot map native ingest plane") }
        let p = params.contents().assumingMemoryBound(to: SIMD4<UInt32>.self)
        p[0] = SIMD4(UInt32(layout.width), UInt32(layout.height), UInt32(source.bytesPerRow), UInt32(lease.pixelOffset + source.offset))
        p[1] = SIMD4(UInt32(layout.componentBytes), UInt32(layout.components), UInt32(layout.minimumRowBytes), 0)
        let descriptor = MTL4ArgumentTableDescriptor(); descriptor.maxBufferBindCount = 2; descriptor.maxTextureBindCount = 1
        let table = try device.makeArgumentTable(descriptor: descriptor)
        table.setAddress(buffer.gpuAddress, index: 0); table.setAddress(params.gpuAddress, index: 1); table.setTexture(texture.gpuResourceID, index: 0)
        guard let encoder = command.makeComputeCommandEncoder() else { throw Self.failure("Cannot encode ingest") }
        residency.addAllocation(texture); residency.addAllocation(params)
        encoder.setComputePipelineState(pipeline); encoder.setArgumentTable(table)
        encoder.dispatchThreads(threadsPerGrid: MTLSize(width: layout.width, height: layout.height, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        textures.append(texture); parameters.append(params); tables.append(table)
      }
    } catch { command.endCommandBuffer(); throw error }
    command.endCommandBuffer(); residency.commit(); queue.addResidencySet(residency)
    let resources = Submission(lease: lease, buffer: buffer, parameters: parameters, textures: textures,
      allocator: allocator, command: command, tables: tables, queue: queue, residency: residency)
    let options = MTL4CommitOptions()
    let output = CapturedPixelBuffer(immutable: image)
    options.addFeedbackHandler { [self, resources] feedback in
      let error = feedback.error
      serial.async {
        resources.retire()
        if let error { completion(.failure(error)) }
        else { completion(.success(output)) }
      }
    }
    queue.commit([command], options: options)
  }

  private final class Submission: @unchecked Sendable {
    let lease: NoCopyIngestLease
    var buffer: MTLBuffer?
    let parameters: [MTLBuffer]
    let textures: [MTLTexture]
    let allocator: MTL4CommandAllocator
    let command: MTL4CommandBuffer
    let tables: [MTL4ArgumentTable]
    let queue: MTL4CommandQueue
    let residency: MTLResidencySet
    init(lease: NoCopyIngestLease, buffer: MTLBuffer, parameters: [MTLBuffer], textures: [MTLTexture],
      allocator: MTL4CommandAllocator, command: MTL4CommandBuffer, tables: [MTL4ArgumentTable],
      queue: MTL4CommandQueue, residency: MTLResidencySet) {
      self.lease = lease; self.buffer = buffer; self.parameters = parameters; self.textures = textures
      self.allocator = allocator; self.command = command; self.tables = tables; self.queue = queue; self.residency = residency
    }
    func retire() {
      queue.removeResidencySet(residency)
      if let buffer { residency.removeAllocation(buffer) }; residency.commit()
      buffer = nil
      lease.completeGPU()
    }
  }
  private static func failure(_ message: String) -> Error { NSError(domain: "Ultracam.CPUMemoryIngest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
