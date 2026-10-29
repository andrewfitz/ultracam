import CoreVideo
import Foundation
import IOSurface
import Metal

/// Asynchronous, code-exact 8-bit packed input -> encoder-native x422. No
/// allocation cache: every budget lease ends at GPU feedback. Each submission
/// owns its command memory and retains the original capture allocation.
final class Packed422RecordingConverter: @unchecked Sendable {
  enum Failure: Error { case unavailable, unsupportedSource, invalidOutput, capacity, gpu(String) }
  typealias Completion = @Sendable (Result<CVPixelBuffer, Error>) -> Void
  static let outputPixelFormat = kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
  private let device: MTLDevice
  private let decoder: Packed422GPU4
  private let budget: GPUAllocationBudget
  private let maximumInFlight: Int
  private let lock = NSLock()
  private var active = 0

  init(device: MTLDevice? = MTLCreateSystemDefaultDevice(), maximumBytes: Int = 256 * 1024 * 1024, maximumInFlight: Int = 3) throws {
    guard let device, device.supportsFamily(.metal4), maximumInFlight > 0 else { throw Failure.unavailable }
    self.device = device; self.maximumInFlight = maximumInFlight
    decoder = try Packed422GPU4(device: device)
    budget = GPUAllocationBudget(policy: try GPUAllocationBudgetPolicy(maximumBytes: maximumBytes, minimumSlots: 1))
  }
  var retainedAllocationBytes: Int { budget.snapshot().bytes }

  func convert(_ source: CVPixelBuffer, output: CVPixelBuffer? = nil, completion: @escaping Completion) throws {
    let type = CVPixelBufferGetPixelFormatType(source)
    let format: Packed422Format
    switch type {
    case kCVPixelFormatType_422YpCbCr8: format = .twoVuy
    case kCVPixelFormatType_422YpCbCr8_yuvs: format = .yuvs
    default: throw Failure.unsupportedSource
    }
    let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
    guard width.isMultiple(of: 2), !CVPixelBufferIsPlanar(source),
      let surface = CVPixelBufferGetIOSurface(source)?.takeUnretainedValue() else { throw Failure.unsupportedSource }
    try format.validate(width: width, height: height, rowBytes: CVPixelBufferGetBytesPerRow(source), dataSize: IOSurfaceGetAllocSize(surface))
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Uint, width: width / 2, height: height, mipmapped: false)
    descriptor.storageMode = .shared; descriptor.usage = .shaderRead
    guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0) else { throw Failure.unsupportedSource }
    let lease = try budget.acquire(backingID: UInt64(IOSurfaceGetID(surface)), bytes: IOSurfaceGetAllocSize(surface), generation: 0, owner: surface)
    try submit(width: width, height: height, format: format, texture: texture, buffer: nil, rowBytes: 0,
      alphaRowBytes: nil, owner: source, sourceImage: source, sourceLease: lease, output: output, completion: completion)
  }

  /// Raw NDI UYVA: UYVY rows followed by a full-height 8-bit alpha plane.
  /// `source` owns all bytes; `owner` additionally pins any vendor allocation
  /// behind a no-copy MTLBuffer. Alpha is validated and ignored explicitly.
  func convertUYVA(_ source: MTLBuffer, owner: AnyObject, width: Int, height: Int,
                   rowBytes: Int, alphaRowBytes: Int, output: CVPixelBuffer? = nil,
                   completion: @escaping Completion) throws {
    guard width > 0, width.isMultiple(of: 2), source.device.registryID == device.registryID else { throw Failure.unsupportedSource }
    try Packed422Format.uyva.validate(width: width, height: height, rowBytes: rowBytes,
      dataSize: source.length, alphaRowBytes: alphaRowBytes)
    let lease = try budget.acquire(backingID: source.gpuAddress, bytes: source.allocatedSize, generation: 0, owner: owner)
    try submit(width: width, height: height, format: .uyva, texture: nil, buffer: source,
      rowBytes: rowBytes, alphaRowBytes: alphaRowBytes, owner: owner, sourceImage: nil, sourceLease: lease,
      output: output, completion: completion)
  }

  private func submit(width: Int, height: Int, format: Packed422Format, texture: MTLTexture?, buffer: MTLBuffer?,
                      rowBytes: Int, alphaRowBytes: Int?, owner: AnyObject, sourceImage: CVPixelBuffer?,
                      sourceLease: GPUAllocationBudget.Lease, output: CVPixelBuffer?, completion: @escaping Completion) throws {
    guard lock.withLock({ if active >= maximumInFlight { return false }; active += 1; return true }) else { throw Failure.capacity }
    var committed = false
    defer { if !committed { lock.withLock { active -= 1 } } }
    var created = output
    if created == nil {
      guard CVPixelBufferCreate(nil, width, height, Self.outputPixelFormat,
        [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary, &created) == kCVReturnSuccess else { throw Failure.invalidOutput }
    }
    guard let output = created, CVPixelBufferGetWidth(output) == width, CVPixelBufferGetHeight(output) == height,
      CVPixelBufferGetPixelFormatType(output) == Self.outputPixelFormat,
      CVPixelBufferGetPlaneCount(output) == 2,
      let surface = CVPixelBufferGetIOSurface(output)?.takeUnretainedValue() else { throw Failure.invalidOutput }
    if let sourceImage {
      if let original = CVPixelBufferGetIOSurface(sourceImage)?.takeUnretainedValue(),
        IOSurfaceGetID(original) == IOSurfaceGetID(surface) { throw Failure.invalidOutput }
      CVBufferPropagateAttachments(sourceImage, output)
    }
    var planes: [MTLTexture] = []
    for plane in 0..<2 {
      guard CVPixelBufferGetWidthOfPlane(output, plane) == (plane == 0 ? width : width / 2),
        CVPixelBufferGetHeightOfPlane(output, plane) == height,
        CVPixelBufferGetBytesPerRowOfPlane(output, plane) >= width * 2 else { throw Failure.invalidOutput }
      let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: plane == 0 ? .r16Uint : .rg16Uint,
        width: plane == 0 ? width : width / 2, height: height, mipmapped: false)
      d.storageMode = .shared; d.usage = .shaderWrite
      guard let t = device.makeTexture(descriptor: d, iosurface: surface, plane: plane) else { throw Failure.invalidOutput }
      planes.append(t)
    }
    let outputLease = try budget.acquire(backingID: UInt64(IOSurfaceGetID(surface)), bytes: IOSurfaceGetAllocSize(surface), generation: 0, owner: surface)
    let queue = try device.makeMTL4CommandQueue(descriptor: MTL4CommandQueueDescriptor())
    guard let allocator = device.makeCommandAllocator(), let command = device.makeCommandBuffer(),
      let parameters = device.makeBuffer(length: 16, options: .storageModeShared) else { throw Failure.unavailable }
    let residency = try device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
    residency.addAllocation(parameters); planes.forEach { residency.addAllocation($0) }
    if let texture { residency.addAllocation(texture) }; if let buffer { residency.addAllocation(buffer) }
    residency.commit(); queue.addResidencySet(residency)
    let td = MTL4ArgumentTableDescriptor(); td.maxBufferBindCount = 2; td.maxTextureBindCount = 3
    let table = try device.makeArgumentTable(descriptor: td)
    command.beginCommandBuffer(allocator: allocator)
    guard let encoder = command.makeComputeCommandEncoder() else { command.endCommandBuffer(); throw Failure.unavailable }
    do {
      if let texture {
        try decoder.encodeTexture(encoder: encoder, table: table, parameters: parameters,
          source: texture, format: format, luma: planes[0], chroma: planes[1])
      } else if let buffer {
        try decoder.encode(encoder: encoder, table: table, parameters: parameters,
          source: buffer, rowBytes: rowBytes, width: width, height: height, format: format,
          alphaRowBytes: alphaRowBytes, luma: planes[0], chroma: planes[1])
      }
    } catch { encoder.endEncoding(); command.endCommandBuffer(); queue.removeResidencySet(residency); throw error }
    encoder.endEncoding(); command.endCommandBuffer()
    let retained = Submission(converter: self, owner: owner, output: output, queue: queue, residency: residency,
      resources: [queue, allocator, command, parameters, table, residency] + planes.map { $0 as AnyObject } + (texture.map { [$0 as AnyObject] } ?? []) + (buffer.map { [$0 as AnyObject] } ?? []),
      leases: [sourceLease, outputLease])
    let options = MTL4CommitOptions()
    options.addFeedbackHandler { feedback in
      retained.finish()
      if let error = feedback.error { completion(.failure(Failure.gpu(error.localizedDescription))) }
      else { completion(.success(retained.output)) }
    }
    committed = true
    queue.commit([command], options: options)
  }

  private final class Submission: @unchecked Sendable {
    let converter: Packed422RecordingConverter
    let owner: AnyObject
    let output: CVPixelBuffer
    let queue: MTL4CommandQueue
    let residency: MTLResidencySet
    let resources: [AnyObject]
    let leases: [GPUAllocationBudget.Lease]
    init(converter: Packed422RecordingConverter, owner: AnyObject, output: CVPixelBuffer, queue: MTL4CommandQueue, residency: MTLResidencySet, resources: [AnyObject], leases: [GPUAllocationBudget.Lease]) {
      self.converter = converter; self.owner = owner; self.output = output; self.resources = resources; self.leases = leases; self.queue = queue; self.residency = residency
    }
    func finish() { queue.removeResidencySet(residency); leases.forEach { $0.release() }; converter.lock.withLock { converter.active -= 1 } }
  }
}
