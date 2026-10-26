import CoreMediaIO
import Foundation
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

  init(_ queue: CMSimpleQueue) { self.queue = queue }
  deinit { drain() }

  func send(_ sample: CMSampleBuffer) throws -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !closed else { throw VideoError.message("Virtual camera queue is closed.") }
    // Do not use a count-then-enqueue check. CMIO can dequeue concurrently,
    // so the count is only a hint and creates a race at the capacity edge.
    // CMSimpleQueueEnqueue is the ownership and backpressure boundary.
    let retained = Unmanaged.passRetained(sample)
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
/// IOSurface (DeckLink SDK 16), or as the processor's IOSurface output. Nothing
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

final class CameraSink {
  private var deviceID: CMIODeviceID = 0
  private var streamID: CMIOStreamID = 0
  private var queue: CameraBufferQueue?
  private var negotiatedFormat: CMVideoFormatDescription?
  private var negotiatedDuration: CMTime?
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

  func connect(configuration: PipelineConfiguration, passthroughFormat: OSType) throws {
    let pixelFormat = configuration.untouched ? passthroughFormat : configuration.pixelFormat
    cameraOutputLog.notice("""
      Camera connect: \(self.route.feedID ?? "Program", privacy: .public) → \(self.route.deviceUID, privacy: .public), \
      \(configuration.width, privacy: .public)×\(configuration.height, privacy: .public) \
      \(fourCC(pixelFormat), privacy: .public), frame \(configuration.duration.value, privacy: .public)/\
      \(configuration.duration.timescale, privacy: .public) s
      """)
    do { try connectOnce(configuration: configuration, passthroughFormat: passthroughFormat) } catch {
      cameraOutputLog.error("""
        Camera connect failed: \(self.route.feedID ?? "Program", privacy: .public) → \(self.route.deviceUID, privacy: .public): \
        \(error.localizedDescription, privacy: .public)
        """)
      throw error
    }
  }

  private func connectOnce(configuration: PipelineConfiguration, passthroughFormat: OSType) throws {
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
      let format = try VideoContract.formatDescription(width: configuration.width, height: configuration.height,
        pixelFormat: configuration.untouched ? passthroughFormat : configuration.pixelFormat)
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
      // AVFoundation clients such as Zoom claim device control before starting
      // the source. In automatic mode the producer necessarily arrives later.
      // The extension can negotiate our authorized producer's sample contract
      // itself; don't require stealing another client's device-control lease.
      let controlled = controlledByAnotherProcess(id)
      do {
        if !controlled {
          for stream in [paired.sink, paired.source] {
            var address = CMIOObjectPropertyAddress(mSelector: UInt32(kCMIOStreamPropertyFormatDescription),
              mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: UInt32(kCMIOObjectPropertyElementMain))
            var description = Unmanaged.passUnretained(format).toOpaque()
            try check(CMIOObjectSetPropertyData(stream, &address, 0, nil,
              UInt32(MemoryLayout<CMVideoFormatDescription>.size), &description), "Set virtual camera format")
            address.mSelector = UInt32(kCMIOStreamPropertyFrameRate)
            var rate = 1 / configuration.duration.seconds
            try check(CMIOObjectSetPropertyData(stream, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &rate),
              "Set virtual camera frame rate")
          }
        }
      } catch {
        // Also handle Zoom acquiring control between the read and setter.
        guard controlledByAnotherProcess(id) else { throw error }
      }
      var unmanaged: Unmanaged<CMSimpleQueue>?
      try check(CMIOStreamCopyBufferQueue(paired.sink, cameraSinkQueueAltered, nil, &unmanaged), "Open camera queue")
      guard let unmanaged else { throw VideoError.message("Camera queue is unavailable.") }
      queue = CameraBufferQueue(unmanaged.takeRetainedValue())
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
    return try queue.send(try stager.stage(sample))
  }

  /// Which field of `sample` differs from the negotiated contract, expected vs
  /// actual; nil when it matches.
  static func mismatch(_ sample: CMSampleBuffer, format: CMVideoFormatDescription, duration: CMTime) -> String? {
    let expected = CMVideoFormatDescriptionGetDimensions(format)
    let subtype = CMFormatDescriptionGetMediaSubType(format)
    guard CMSampleBufferDataIsReady(sample) else { return "data not ready" }
    guard let image = CMSampleBufferGetImageBuffer(sample) else { return "no image buffer" }
    guard let sampleFormat = CMSampleBufferGetFormatDescription(sample) else { return "no format description" }
    let sampleSubtype = CMFormatDescriptionGetMediaSubType(sampleFormat)
    if sampleSubtype != subtype { return "format subtype: expected \(fourCC(subtype)), got \(fourCC(sampleSubtype))" }
    let size = CMVideoFormatDescriptionGetDimensions(sampleFormat)
    if size.width != expected.width || size.height != expected.height {
      return "format dimensions: expected \(expected.width)×\(expected.height), got \(size.width)×\(size.height)"
    }
    if CVPixelBufferGetWidth(image) != Int(expected.width) || CVPixelBufferGetHeight(image) != Int(expected.height) {
      return "image dimensions: expected \(expected.width)×\(expected.height), got \(CVPixelBufferGetWidth(image))×\(CVPixelBufferGetHeight(image))"
    }
    let pixelFormat = CVPixelBufferGetPixelFormatType(image)
    if pixelFormat != subtype { return "pixel format: expected \(fourCC(subtype)), got \(fourCC(pixelFormat))" }
    let time = CMSampleBufferGetPresentationTimeStamp(sample)
    if !time.isNumeric || time.epoch != 0 || time.seconds < 0 {
      return "presentation time: expected a numeric time ≥ 0 in epoch 0, got \(time.value)/\(time.timescale) epoch \(time.epoch)"
    }
    let sampleDuration = CMSampleBufferGetDuration(sample)
    if sampleDuration != duration {
      return "frame duration: expected \(duration.value)/\(duration.timescale), got \(sampleDuration.value)/\(sampleDuration.timescale)"
    }
    return nil
  }

  func disconnect() {
    queue?.close()
    if streamID != 0 { _ = CMIODeviceStopStream(deviceID, streamID) }
    queue?.drain()
    queue = nil
    negotiatedFormat = nil
    negotiatedDuration = nil
    stager = CameraFrameStager()
    deviceID = 0
    streamID = 0
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
