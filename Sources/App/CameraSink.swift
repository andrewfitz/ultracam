import CoreMediaIO
import Foundation
import IOSurface
import os

/// Virtual camera output: connects, negotiated formats, send failures, queue state.
let cameraOutputLog = Logger(subsystem: "org.ultracam.app", category: "camera")

/// LUT loads, restores, toggles and the monitor's burn-in source.
let lutLog = Logger(subsystem: "org.ultracam.app", category: "lut")

/// Virtual camera registry publishes.
let registryLog = Logger(subsystem: "org.ultracam.app", category: "registry")

/// Feed lifecycle: starts, stops, selection.
let captureLog = Logger(subsystem: "org.ultracam.app", category: "capture")

/// A four-character code as text (`v210`, `420v`), for logs.
func fourCC(_ code: OSType) -> String {
  let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xff) }
  guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else { return String(format: "0x%08x", code) }
  return String(decoding: bytes, as: UTF8.self)
}

// Queue-altered is a notification, not a transfer of sample ownership. CMIO's
// consumer owns the dequeued enqueue retain and releases it after use. Releasing
// the notification token here caused real installed-extension double frees.
let cameraSinkQueueAltered: CMIODeviceStreamQueueAlteredProc = { _, _, _ in }

// CMSimpleQueue does not retain its elements. Each successful enqueue owns
// exactly one retain, transferred to CMIO on dequeue or released by our stop
// drain if the sample was never consumed.
final class CameraBufferQueue {
  let queue: CMSimpleQueue
  private let lock = NSLock()
  private var closed = false
  private let retention: MediaRetentionLedger
  private static var retentionKey: CFString { "org.ultracam.camera.transport-retention" as CFString }
  private final class RetainedMedia: NSObject {
    let lease: MediaRetentionLedger.Lease
    init(_ lease: MediaRetentionLedger.Lease) { self.lease = lease }
  }

  init(_ queue: CMSimpleQueue, retentionPolicy: MediaRetentionPolicy = try! MediaRetentionPolicy(
    maximumBytes: 256 * 1024 * 1024, maximumDuration: 8 * 1001.0 / 30_000, minimumSlots: 2)) {
    self.queue = queue
    retention = MediaRetentionLedger(policy: retentionPolicy)
  }
  var retentionSnapshot: MediaRetentionLedger.Snapshot { retention.snapshot }
  deinit { drain() }

  func send(_ sample: CMSampleBuffer) throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !closed else { throw VideoError.message("Virtual camera queue is closed.") }
    guard let image = CMSampleBufferGetImageBuffer(sample) else { throw VideoError.message("Camera sample has no image.") }
    let count = CVPixelBufferGetPlaneCount(image)
    let planes = count == 0
      ? [MediaStorageExtent.Plane(rowBytes: CVPixelBufferGetBytesPerRow(image), rows: CVPixelBufferGetHeight(image))]
      : (0..<count).map { MediaStorageExtent.Plane(rowBytes: CVPixelBufferGetBytesPerRowOfPlane(image, $0), rows: CVPixelBufferGetHeightOfPlane(image, $0)) }
    let bytes = try MediaStorageExtent.allocationBytes(planes: planes,
      pixelBufferDataSize: CVPixelBufferGetDataSize(image),
      ioSurfaceAllocationSize: CVPixelBufferGetIOSurface(image).map { IOSurfaceGetAllocSize($0.takeUnretainedValue()) })
    let lease: MediaRetentionLedger.Lease
    do { lease = try retention.admit(bytes: bytes, duration: CMSampleBufferGetDuration(sample).seconds) }
    catch MediaRetentionFailure.byteLimit { return false }
    catch MediaRetentionFailure.durationLimit { return false }
    catch MediaRetentionFailure.slotLimit { return false }
    // A metadata copy shares the IOSurface, but has its own lifetime. Attaching
    // to the caller's sample would let an unrelated preview hold this budget.
    var copy: CMSampleBuffer?
    let copyStatus = CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleBufferOut: &copy)
    guard copyStatus == noErr, let copy else { lease.release(); throw VideoError.message("Copy camera sample metadata failed (\(copyStatus)).") }
    CMSetAttachment(copy, key: Self.retentionKey, value: RetainedMedia(lease), attachmentMode: kCMAttachmentMode_ShouldNotPropagate)
    // Do not use a count-then-enqueue check. CMIO can dequeue concurrently,
    // so the count is only a hint and creates a race at the capacity edge.
    // CMSimpleQueueEnqueue is the ownership and backpressure boundary.
    let retained = Unmanaged.passRetained(copy)
    let status = CMSimpleQueueEnqueue(queue, element: retained.toOpaque())
    if status != noErr { retained.release() }
    if status == kCMSimpleQueueError_QueueIsFull { return false }
    guard status == noErr else { throw VideoError.message("Send camera frame failed (\(status)).") }
    return true
  }

  // Call only after stopping the CMIO consumer. CMSimpleQueue permits one
  // producer and one consumer; draining a live consumer would violate that.
  func drain() {
    lock.lock()
    defer { lock.unlock() }
    guard !closed || CMSimpleQueueGetCount(queue) > 0 else { return }
    closed = true
    while let token = CMSimpleQueueDequeue(queue) {
      Unmanaged<CMSampleBuffer>.fromOpaque(token).release()
    }
  }

  // Prevent a callback racing teardown from enqueuing after the stream has
  // been stopped. Draining remains a separate operation so CameraSink can
  // close admission before asking CMIO to quiesce its consumer.
  func close() {
    lock.lock()
    closed = true
    lock.unlock()
  }
}

/// Frames reach the camera, the preview and Program as the capture card's own
/// IOSurface, or as the processor's IOSurface output. Nothing
/// is copied here: a frame without an IOSurface is an error, not a reason to copy.
final class CameraFrameStager {
  func stage(_ sample: CMSampleBuffer) throws -> CMSampleBuffer {
    guard let input = CMSampleBufferGetImageBuffer(sample) else { throw VideoError.message("Camera sample has no image.") }
    try VideoBufferLayout.validate(input)
    guard CVPixelBufferGetIOSurface(input) != nil else {
      throw VideoError.message("The camera frame is not IOSurface-backed, so it can't be shared without a copy.")
    }
    return sample
  }
}

// A failed stop is not evidence that CMIO's single consumer has quiesced.
// Active streams reserve capacity too, so failed teardown cannot accumulate
// unbounded quarantined queues across reconnects or sink destruction.
final class CameraStreamStopRecovery: @unchecked Sendable {
  static let shared = CameraStreamStopRecovery(capacity: 32)
  private struct Entry {
    let deviceID: CMIODeviceID
    let streamID: CMIOStreamID
    var queue: CameraBufferQueue?
    let stop: () -> OSStatus
    var retryScheduled = false
  }
  private let lock = NSRecursiveLock()
  private let capacity: Int
  private let schedule: (@escaping () -> Void) -> Void
  private var entries: [UUID: Entry] = [:]

  init(capacity: Int, schedule: ((@escaping () -> Void) -> Void)? = nil) {
    self.capacity = capacity
    self.schedule = schedule ?? { action in
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: DispatchWorkItem(block: action))
    }
  }

  func reserve(deviceID: CMIODeviceID, streamID: CMIOStreamID, queue: CameraBufferQueue? = nil, stop: @escaping () -> OSStatus) throws -> UUID {
    try lock.withLock {
      guard entries.count < capacity else { throw VideoError.message("Virtual camera stream recovery capacity is exhausted; unresolved streams must stop before reconnecting.") }
      guard !entries.values.contains(where: { $0.deviceID == deviceID && $0.streamID == streamID }) else {
        throw VideoError.message("This virtual camera stream still owns an active or unresolved connection. Wait for its stop to succeed before reconnecting.")
      }
      let token = UUID()
      entries[token] = Entry(deviceID: deviceID, streamID: streamID, queue: queue, stop: stop)
      return token
    }
  }

  var retainedStreams: Int { lock.withLock { entries.count } }

  func attach(_ queue: CameraBufferQueue, to token: UUID) {
    lock.withLock { precondition(entries[token] != nil); entries[token]?.queue = queue }
  }

  func cancelUnstarted(_ token: UUID) {
    lock.withLock { _ = entries.removeValue(forKey: token) }
  }

  func stop(_ token: UUID) {
    lock.withLock {
      guard var entry = entries[token], !entry.retryScheduled else { return }
      entry.queue?.close()
      let status = entry.stop()
      if status == noErr {
        entry.queue?.drain()
        entries.removeValue(forKey: token)
      } else {
        cameraOutputLog.error("Virtual camera stop failed (\(status, privacy: .public)); retaining closed queue until stop succeeds.")
        entry.retryScheduled = true
        entries[token] = entry
        schedule { [self] in
          lock.withLock {
            guard entries[token] != nil else { return }
            entries[token]?.retryScheduled = false
            stop(token)
          }
        }
      }
    }
  }
}

/// Stable CMIO destination identity for one processed feed.
///
/// The extension derives the same UID and stream names from
/// `VirtualCameraDescriptor`, so an app-side capture controller never has to
/// guess which virtual camera a frame belongs to.
struct CameraSinkRoute: Equatable, Sendable {
  let feedID: String?
  let deviceUID: String
  let sinkStreamName: String
  let sourceStreamName: String

  init(feedID: FeedID) {
    self.init(descriptor: .feed(feedID: feedID.rawValue))
  }

  init(descriptor: VirtualCameraDescriptor) {
    // Feed and Program devices share this transport. The descriptor carries
    // the stable UID and stream names, so no second sink implementation is
    // needed for the Program output.
    self.feedID = descriptor.feedID
    self.deviceUID = descriptor.deviceUID
    self.sinkStreamName = descriptor.kind == .feed && descriptor.feedID == "default"
      ? VideoContract.sinkName
      : "\(descriptor.displayName) Input"
    self.sourceStreamName = descriptor.displayName
  }
}

/// Pairs a virtual camera's source and input streams without treating a
/// display name that merely contains "input" as the sink.
enum CameraStreamNames {
  /// `kCMIOStreamPropertyDirection` as the CMIO DAL reports it to clients:
  /// 1 is an input stream (input to this Mac: a camera's source, which a
  /// client captures from) and 0 is an output stream (this Mac sends into it:
  /// the camera's sink). This is NOT the extension-side
  /// `CMIOExtensionStream.Direction`, where `.sink` is 1. The installed
  /// extension publishes "Ultracam · Camera 1" with direction 1 and
  /// "Ultracam · Camera 1 Input" with direction 0. Treating 1 as the sink made
  /// the app start each camera's source as a viewer and enqueue into that
  /// viewer's receive queue, so the real sink was never consumed and camera
  /// apps only ever saw standby black.
  static let sinkDirection: UInt32 = 0
  static let sourceDirection: UInt32 = 1

  static func pair(_ streams: [(id: UInt32, name: String, direction: UInt32?)],
    sinkName: String, sourceName: String) -> (sink: UInt32, source: UInt32)? {
    let sinkByDirection = streams.first { $0.direction == sinkDirection }?.id
    let sourceByDirection = streams.first { $0.direction == sourceDirection && $0.id != sinkByDirection }?.id
    if let sinkByDirection, let sourceByDirection { return (sinkByDirection, sourceByDirection) }
    if let sink = streams.first(where: { $0.name == sinkName })?.id,
      let source = streams.first(where: { $0.name == sourceName && $0.id != sink })?.id {
      return (sink, source)
    }
    guard streams.count == 2 else { return nil }
    let first = streams[0]
    let second = streams[1]
    if first.name == second.name + " Input" { return (first.id, second.id) }
    if second.name == first.name + " Input" { return (second.id, first.id) }
    if let source = streams.first(where: { $0.name == sourceName }) {
      guard let sink = streams.first(where: { $0.id != source.id }) else { return nil }
      return (sink.id, source.id)
    }
    return nil
  }
}

/// Calls `changed` on the main queue whenever CMIO's device list changes, as when the camera
/// extension starts and its cameras appear. Removes its listener when released.
final class CMIODeviceListWatcher {
  private let block: CMIOObjectPropertyListenerBlock
  private let registered: Bool

  init(changed: @escaping @MainActor @Sendable () -> Void) {
    let system = CMIOObjectID(kCMIOObjectSystemObject)
    // A process sees software cameras, and hears of them, only after opting in.
    var visibility = Self.address(kCMIOHardwarePropertyAllowScreenCaptureDevices)
    var allow: UInt32 = 1
    _ = CMIOObjectSetPropertyData(system, &visibility, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
    block = { _, _ in MainActor.assumeIsolated { changed() } }
    var devices = Self.address(kCMIOHardwarePropertyDevices)
    let status = CMIOObjectAddPropertyListenerBlock(system, &devices, .main, block)
    registered = status == noErr
    if !registered { cameraOutputLog.error("Virtual camera watch unavailable: CMIO status \(status, privacy: .public)") }
  }

  deinit {
    guard registered else { return }
    var devices = Self.address(kCMIOHardwarePropertyDevices)
    _ = CMIOObjectRemovePropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &devices, .main, block)
  }

  private static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(mSelector: UInt32(selector), mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
      mElement: UInt32(kCMIOObjectPropertyElementMain))
  }
}

final class CameraSink {
  private var stopRecoveryToken: UUID?
  private var deviceID: CMIODeviceID = 0
  private var streamID: CMIOStreamID = 0
  private var queue: CameraBufferQueue?
  private var negotiatedFormat: CMVideoFormatDescription?
  private var negotiatedDuration: CMTime?
  private var sourcePauseAllowanceSeconds: Double?
  private var stager = CameraFrameStager()
  private let registrySnapshot: () -> VirtualCameraRegistrySnapshot?
  let route: CameraSinkRoute

  init(bufferQueue: CameraBufferQueue? = nil, route: CameraSinkRoute,
    registrySnapshot: @escaping () -> VirtualCameraRegistrySnapshot? = { VirtualCameraRegistryStore().load() }) {
    queue = bufferQueue
    self.route = route
    self.registrySnapshot = registrySnapshot
  }

  convenience init(bufferQueue: CameraBufferQueue? = nil, feedID: FeedID) {
    self.init(bufferQueue: bufferQueue, route: CameraSinkRoute(feedID: feedID))
  }
  deinit { disconnect() }

  func connect(configuration: PipelineConfiguration, passthroughFormat: OSType, sourceFormat: SourceFormat? = nil) throws {
    try Self.validateCameraSource(sourceFormat)
    sourcePauseAllowanceSeconds = configuration.sourcePauseAllowanceSeconds
    let pixelFormat = route.feedID == nil ? ProgramOutputFormat(configuration: configuration, passthroughFormat: passthroughFormat).pixelFormat : (configuration.untouched ? passthroughFormat : configuration.pixelFormat)
    cameraOutputLog.notice("""
      Camera connect: \(self.route.feedID ?? "Program", privacy: .public) → \(self.route.deviceUID, privacy: .public), \
      \(configuration.width, privacy: .public)×\(configuration.height, privacy: .public) \
      \(fourCC(pixelFormat), privacy: .public), frame \(configuration.duration.value, privacy: .public)/\
      \(configuration.duration.timescale, privacy: .public) s
      """)
    do { try connectOnce(configuration: configuration, passthroughFormat: passthroughFormat, sourceFormat: sourceFormat) } catch {
      cameraOutputLog.error("""
        Camera connect failed: \(self.route.feedID ?? "Program", privacy: .public) → \(self.route.deviceUID, privacy: .public): \
        \(error.localizedDescription, privacy: .public)
        """)
      throw error
    }
  }

  static func validateCameraSource(_ sourceFormat: SourceFormat?) throws {
    guard sourceFormat?.rate.isVariable != true else {
      throw VideoError.message("Variable-frame-rate feed camera output is unavailable until real-client validation completes. Preview and recording remain available.")
    }
  }

  static func resolvedOutputColour(configuration: PipelineConfiguration, sourceFormat: SourceFormat?) throws -> Colorimetry {
    let physical = sourceFormat?.colour ?? Colorimetry(
      primaries: .rec709, transfer: .rec709, matrix: .rec709,
      range: .video, horizontalChromaSiting: .unspecified, verticalChromaSiting: .unspecified)
    let interpreted = physical.overridingRGBEncoding(with: configuration.sourceColorimetryOverride)
    let encoded: Colorimetry
    if configuration.applyLUT {
      guard let target = configuration.lutOutputColorimetry else {
        throw VideoError.message("Virtual camera output requires the loaded LUT's explicit output colour contract.")
      }
      guard target.range == .video else {
        throw VideoError.message("The feed GPU encoder requires a video-range LUT output contract.")
      }
      encoded = target
    } else {
      encoded = interpreted
    }
    if configuration.untouched { return encoded }
    // The feed GPU encoder performs native video-range YUV encoding with
    // centered chroma, independently of the interpreted source's storage.
    return Colorimetry(primaries: encoded.primaries, transfer: encoded.transfer,
      matrix: encoded.matrix == .identity ? .rec709 : encoded.matrix, range: .video,
      horizontalChromaSiting: .center, verticalChromaSiting: .center)
  }

  static func requestedFormat(configuration: PipelineConfiguration, passthroughFormat: OSType,
                              sourceFormat: SourceFormat?) throws -> CMVideoFormatDescription {
    try validateCameraSource(sourceFormat)
    let pixel = configuration.untouched ? passthroughFormat : configuration.pixelFormat
    // A declaration-free caller selects the fixed Rec709 compatibility
    // configuration. Frame admission still requires matching explicit tags.
    let legacy = try VideoContract.formatDescription(width: configuration.width, height: configuration.height, pixelFormat: pixel)
    let colour = try resolvedOutputColour(configuration: configuration, sourceFormat: sourceFormat)
    guard colour.primaries != .unspecified, colour.transfer != .unspecified, colour.matrix != .unspecified else {
      throw VideoError.message("Virtual camera output requires an explicit source colour contract.")
    }
    var tags = CMFormatDescriptionGetExtensions(legacy) as! [String: Any]
    let primaries: CFString
    switch colour.primaries {
    case .rec709: primaries = kCVImageBufferColorPrimaries_ITU_R_709_2
    case .rec2020: primaries = kCVImageBufferColorPrimaries_ITU_R_2020
    default: throw VideoError.message("The virtual camera does not support this source colour gamut.")
    }
    let transfer: CFString
    switch colour.transfer {
    case .rec709: transfer = kCVImageBufferTransferFunction_ITU_R_709_2
    case .pq: transfer = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
    case .hlg: transfer = kCVImageBufferTransferFunction_ITU_R_2100_HLG
    default: throw VideoError.message("The virtual camera does not support this source transfer function.")
    }
    let matrix: CFString
    switch colour.matrix {
    case .rec709: matrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
    case .rec2020: matrix = kCVImageBufferYCbCrMatrix_ITU_R_2020
    default: throw VideoError.message("The virtual camera does not support this source colour matrix.")
    }
    tags[kCMFormatDescriptionExtension_ColorPrimaries as String] = primaries
    tags[kCMFormatDescriptionExtension_TransferFunction as String] = transfer
    tags[kCMFormatDescriptionExtension_YCbCrMatrix as String] = matrix
    // Untouched output preserves native range; processed output uses the
    // processor's advertised native output FourCC range.
    if configuration.untouched, sourceFormat != nil {
      tags[kCMFormatDescriptionExtension_FullRangeVideo as String] = colour.range == .full
    }
    if !configuration.untouched {
      tags[kCMFormatDescriptionExtension_ChromaLocationTopField as String] = kCVImageBufferChromaLocation_Center
    } else if colour.horizontalChromaSiting == .center && colour.verticalChromaSiting == .center {
      tags[kCMFormatDescriptionExtension_ChromaLocationTopField as String] = kCVImageBufferChromaLocation_Center
    } else if colour.horizontalChromaSiting != .unspecified || colour.verticalChromaSiting != .unspecified {
      throw VideoError.message("The virtual camera does not publish this untouched chroma siting; use GPU processing into a published output contract.")
    }
    var result: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreate(allocator: nil, codecType: pixel,
      width: Int32(configuration.width), height: Int32(configuration.height),
      extensions: tags as CFDictionary, formatDescriptionOut: &result)
    guard status == noErr, let result else { throw VideoError.message("Cannot create camera output declaration (\(status)).") }
    return result
  }

  private func connectOnce(configuration: PipelineConfiguration, passthroughFormat: OSType, sourceFormat: SourceFormat?) throws {
    disconnect()
    if let desired = registrySnapshot() {
      try VirtualCameraRegistryTransport.synchronize(desired)
    }
    // Software camera devices are hidden from legacy CMIO clients by default.
    var address = CMIOObjectPropertyAddress(
      mSelector: UInt32(kCMIOHardwarePropertyAllowScreenCaptureDevices),
      mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: UInt32(kCMIOObjectPropertyElementMain))
    var allow: UInt32 = 1
    try check(CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address,
      0, nil, UInt32(MemoryLayout.size(ofValue: allow)), &allow), "Enable software camera discovery")
    for id in try discoverDevices() {
      guard try string(id, selector: kCMIODevicePropertyDeviceUID) == route.deviceUID else { continue }
      let streams = try ids(id, selector: kCMIODevicePropertyStreams)
      let format: CMVideoFormatDescription
      if route.feedID == nil {
        format = try ProgramOutputFormat(configuration: configuration, passthroughFormat: passthroughFormat).formatDescription()
      } else {
        format = try Self.requestedFormat(configuration: configuration, passthroughFormat: passthroughFormat, sourceFormat: sourceFormat)
      }
      let namedStreams = try streams.map { stream -> (id: UInt32, name: String, direction: UInt32?) in
        (stream, try string(stream, selector: kCMIOObjectPropertyName), direction(stream))
      }
      // The UID selects the feed. Match the published names, then the
      // source/input pair. A display name that contains "input" is still the
      // source; the input stream is the one named "<source> Input" or the
      // stream whose direction is into the device.
      guard let paired = CameraStreamNames.pair(namedStreams, sinkName: route.sinkStreamName,
        sourceName: route.sourceStreamName) else {
        throw VideoError.message("The virtual camera for \(route.feedID ?? "Program") does not publish its source and input streams.")
      }
      let requested = DerivedOutputContract(format: format, duration: configuration.duration)
      // Claim native identity before setters or CopyBufferQueue: an old retry
      // must not stop this connection or share its still-live native queue.
      let stopDevice = id, stopStream = paired.sink
      let recoveryToken = try CameraStreamStopRecovery.shared.reserve(deviceID: id, streamID: paired.sink) {
        CMIODeviceStopStream(stopDevice, stopStream)
      }
      var armed = false
      defer { if !armed { CameraStreamStopRecovery.shared.cancelUnstarted(recoveryToken) } }
      for stream in [paired.sink, paired.source] {
        guard requested.matchingPublishedIndex(in: try publishedFormats(stream)) != nil else {
          throw VideoError.message("The installed virtual camera does not publish this output size, pixel layout and complete colour contract. Update the camera extension or choose an installed output format.")
        }
      }
      // AVFoundation clients such as Zoom claim device control before starting
      // the source. In automatic mode the producer necessarily arrives later.
      // The extension can negotiate our authorized producer's sample contract
      // itself; don't require stealing another client's device-control lease.
      let controlled = controlledByAnotherProcess(id)
      for stream in [paired.sink, paired.source] {
        try Self.negotiateInstalledContract(format: format, duration: configuration.duration,
          controlled: { self.controlledByAnotherProcess(id) }, set: {
            var address = CMIOObjectPropertyAddress(mSelector: UInt32(kCMIOStreamPropertyFormatDescription),
              mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: UInt32(kCMIOObjectPropertyElementMain))
            var description = Unmanaged.passUnretained(format).toOpaque()
            try check(CMIOObjectSetPropertyData(stream, &address, 0, nil,
              UInt32(MemoryLayout<CMVideoFormatDescription>.size), &description), "Set virtual camera format")
            address.mSelector = UInt32(kCMIOStreamPropertyFrameRate)
            var rate = Double(configuration.duration.timescale) / Double(configuration.duration.value)
            try check(CMIOObjectSetPropertyData(stream, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &rate),
              "Set virtual camera frame rate")
          }, read: { try self.installedActiveContract(stream) })
      }
      var unmanaged: Unmanaged<CMSimpleQueue>?
      try check(CMIOStreamCopyBufferQueue(paired.sink, cameraSinkQueueAltered, nil, &unmanaged), "Open camera queue")
      guard let unmanaged else { throw VideoError.message("Camera queue is unavailable.") }
      queue = CameraBufferQueue(unmanaged.takeRetainedValue())
      CameraStreamStopRecovery.shared.attach(queue!, to: recoveryToken)
      stopRecoveryToken = recoveryToken
      armed = true
      negotiatedFormat = format
      negotiatedDuration = configuration.duration
      deviceID = id
      streamID = paired.sink
      do { try check(CMIODeviceStartStream(id, paired.sink), "Start virtual camera input") }
      catch { disconnect(); throw error }
      let size = CMVideoFormatDescriptionGetDimensions(format)
      cameraOutputLog.notice("""
        Camera connected: \(self.route.feedID ?? "Program", privacy: .public), negotiated \(size.width, privacy: .public)×\
        \(size.height, privacy: .public) \(fourCC(CMFormatDescriptionGetMediaSubType(format)), privacy: .public), \
        frame \(configuration.duration.value, privacy: .public)/\(configuration.duration.timescale, privacy: .public) s, \
        queue capacity \(self.queue.map { CMSimpleQueueGetCapacity($0.queue) } ?? 0, privacy: .public)\
        \(controlled ? ", format left to the camera app holding device control" : "", privacy: .public)
        """)
      return
    }
    throw VideoError.message("Install and approve the Ultracam camera extension, then reconnect.")
  }

  private func discoverDevices() throws -> [CMIOObjectID] {
    // The registry acknowledgement precedes CMIO's topology notification.
    // Wait only during connection, waking when the new device is published.
    let system = CMIOObjectID(kCMIOObjectSystemObject)
    let changed = DispatchSemaphore(value: 0)
    var property = CMIOObjectPropertyAddress(mSelector: UInt32(kCMIOHardwarePropertyDevices),
      mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: UInt32(kCMIOObjectPropertyElementMain))
    let listener: CMIOObjectPropertyListenerBlock = { _, _ in changed.signal() }
    let status = CMIOObjectAddPropertyListenerBlock(system, &property, .global(), listener)
    defer {
      if status == noErr { _ = CMIOObjectRemovePropertyListenerBlock(system, &property, .global(), listener) }
    }
    let deadline = DispatchTime.now() + .seconds(3)
    repeat {
      let devices = try ids(system, selector: kCMIOHardwarePropertyDevices)
      if try devices.contains(where: { try string($0, selector: kCMIODevicePropertyDeviceUID) == route.deviceUID }) {
        return devices
      }
      guard status == noErr, changed.wait(timeout: deadline) == .success else { return [] }
    } while DispatchTime.now() < deadline
    return []
  }

  func send(_ sample: CMSampleBuffer) throws -> Bool {
    guard let queue else { throw VideoError.message("Virtual camera is disconnected.") }
    if let negotiatedFormat, let negotiatedDuration,
      let mismatch = Self.mismatch(sample, format: negotiatedFormat, duration: negotiatedDuration) {
      // A failed send closes the connection, so this is at most once per connect.
      cameraOutputLog.error("Camera frame refused before sending (\(self.route.feedID ?? "Program", privacy: .public)): \(mismatch, privacy: .public)")
      throw VideoError.message("Frame does not match the virtual camera's negotiated format and timing (\(mismatch)).")
    }
    let outgoing = try Self.transportSample(sample, pauseAllowance: sourcePauseAllowanceSeconds)
    return try queue.send(try stager.stage(outgoing))
  }

  /// Copy metadata only: a transport attachment must not alter preview/recording's sample.
  static func transportSample(_ sample: CMSampleBuffer, pauseAllowance: Double?) throws -> CMSampleBuffer {
    var copy: CMSampleBuffer?
    let status = CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault, sampleBuffer: sample, sampleBufferOut: &copy)
    guard status == noErr, let copy else { throw VideoError.message("Cannot copy camera transport metadata (\(status)).") }
    CMSetAttachment(copy, key: VideoContract.sourcePauseAllowanceAttachmentKey,
      value: NSNumber(value: CameraStandbyTimingPolicy.clampedPauseAllowance(pauseAllowance)),
      attachmentMode: kCMAttachmentMode_ShouldPropagate)
    return copy
  }

  /// Which field of `sample` differs from the negotiated contract, expected vs
  /// actual; nil when it matches.
  static func mismatch(_ sample: CMSampleBuffer, format: CMVideoFormatDescription, duration: CMTime) -> String? {
    DerivedOutputContract(format: format, duration: duration).mismatch(sample)
  }

  func disconnect() {
    queue?.close()
    if let token = stopRecoveryToken {
      CameraStreamStopRecovery.shared.stop(token)
      stopRecoveryToken = nil
    } else {
      // Injected test queues have no native consumer; no CMIO stop is needed.
      queue?.drain()
    }
    queue = nil
    negotiatedFormat = nil
    negotiatedDuration = nil
    stager = CameraFrameStager()
    deviceID = 0
    streamID = 0
  }

  private func publishedFormats(_ stream: CMIOStreamID) throws -> [CMVideoFormatDescription] {
    var address = CMIOObjectPropertyAddress(mSelector: UInt32(kCMIOStreamPropertyFormatDescriptions),
      mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: UInt32(kCMIOObjectPropertyElementMain))
    var list: Unmanaged<CFArray>?
    var used: UInt32 = 0
    try check(CMIOObjectGetPropertyData(stream, &address, 0, nil,
      UInt32(MemoryLayout.size(ofValue: list)), &used, &list), "Read installed virtual-camera formats")
    guard let list else { throw VideoError.message("The installed virtual camera returned no format catalog.") }
    // CMIO documents this property as a retained CFArray owned by the caller.
    let array = list.takeRetainedValue()
    guard let descriptions = array as? [CMVideoFormatDescription] else {
      throw VideoError.message("The installed virtual camera returned an invalid format catalog.")
    }
    return descriptions
  }

  // When device control prevents setting a contract, verify what the installed
  // stream is actually using. A locally published rate list is not evidence of
  // the installed extension's cadence, nor does format identity imply cadence.
  static func negotiateInstalledContract(format: CMVideoFormatDescription, duration: CMTime,
    controlled: () -> Bool, set: () throws -> Void,
    read: () throws -> (CMVideoFormatDescription, Double)) throws {
    if !controlled() {
      do { try set() }
      catch { guard controlled() else { throw error } }
    }
    let (activeFormat, activeRate) = try read()
    guard duration.isNumeric, duration.epoch == 0, duration.value > 0, duration.timescale > 0,
      activeRate.isFinite, activeRate > 0,
      activeRate == Double(duration.timescale) / Double(duration.value),
      DerivedOutputContract.matchesFormat(format, activeFormat) else {
      throw VideoError.message("The busy installed virtual camera is using a different format or exact cadence. Stop its viewer or choose its active output contract before connecting.")
    }
  }

  private func installedActiveContract(_ stream: CMIOStreamID) throws -> (CMVideoFormatDescription, Double) {
    var address = CMIOObjectPropertyAddress(mSelector: UInt32(kCMIOStreamPropertyFormatDescription),
      mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: UInt32(kCMIOObjectPropertyElementMain))
    var description: Unmanaged<CMVideoFormatDescription>?
    var used: UInt32 = 0
    try check(CMIOObjectGetPropertyData(stream, &address, 0, nil,
      UInt32(MemoryLayout.size(ofValue: description)), &used, &description), "Read busy virtual camera format")
    guard let description else { throw VideoError.message("The busy virtual camera did not return its active format.") }
    let format = description.takeRetainedValue()
    address.mSelector = UInt32(kCMIOStreamPropertyFrameRate)
    var rate = 0.0
    try check(CMIOObjectGetPropertyData(stream, &address, 0, nil,
      UInt32(MemoryLayout<Double>.size), &used, &rate), "Read busy virtual camera cadence")
    return (format, rate)
  }

  private func controlledByAnotherProcess(_ device: CMIODeviceID) -> Bool {
    var property = CMIOObjectPropertyAddress(mSelector: UInt32(kCMIODevicePropertyDeviceControl),
      mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: UInt32(kCMIOObjectPropertyElementMain))
    var pid: pid_t = -1
    var size = UInt32(MemoryLayout<pid_t>.size)
    guard CMIOObjectGetPropertyData(device, &property, 0, nil, size, &size, &pid) == noErr else { return false }
    return pid > 0 && pid != getpid()
  }

  private func ids(_ object: CMIOObjectID, selector: Int) throws -> [UInt32] {
    var address = CMIOObjectPropertyAddress(mSelector: UInt32(selector),
      mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: UInt32(kCMIOObjectPropertyElementMain))
    var size: UInt32 = 0
    try check(CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size), "Read camera list size")
    guard size % UInt32(MemoryLayout<UInt32>.size) == 0, size <= 64 * 1024 else {
      throw VideoError.message("Invalid camera device list.")
    }
    var values = [UInt32](repeating: 0, count: Int(size) / MemoryLayout<UInt32>.size)
    if values.isEmpty { return [] }
    try values.withUnsafeMutableBytes { bytes in
      try check(CMIOObjectGetPropertyData(object, &address, 0, nil, size, &size, bytes.baseAddress!), "Read camera list")
    }
    return values
  }

  private func direction(_ object: CMIOObjectID) -> UInt32? {
    var address = CMIOObjectPropertyAddress(mSelector: UInt32(kCMIOStreamPropertyDirection),
      mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: UInt32(kCMIOObjectPropertyElementMain))
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard CMIOObjectGetPropertyData(object, &address, 0, nil, size, &size, &value) == noErr else { return nil }
    return value
  }

  private func string(_ object: CMIOObjectID, selector: Int) throws -> String {
    var address = CMIOObjectPropertyAddress(mSelector: UInt32(selector),
      mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: UInt32(kCMIOObjectPropertyElementMain))
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try check(CMIOObjectGetPropertyData(object, &address, 0, nil, size, &size, &value), "Read camera name")
    return value?.takeRetainedValue() as String? ?? ""
  }

  private func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw VideoError.message("\(operation) failed (\(status)).") }
  }
}
