@preconcurrency import AVFoundation
import Foundation

enum ProgramStreamVideoCodec: String, CaseIterable, Codable, Sendable {
  case h264, hevc, hevcMain10, hevcMain10_422, av1

  var title: String {
    switch self {
    case .h264: "H.264 (hardware)"
    case .hevc: "HEVC Main (hardware)"
    case .hevcMain10: "HEVC Main 10 (hardware)"
    case .hevcMain10_422: "HEVC Main 4:2:2 10 (hardware)"
    case .av1: "AV1 (software)"
    }
  }

  var pixelFormat: OSType {
    switch self {
    case .hevcMain10: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    case .hevcMain10_422: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
    case .h264, .hevc, .av1: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }
  }
}

protocol ProgramStreamVideoEncoding: AnyObject, Sendable {
  var inputBufferCapacity: Int { get }
  var output: AsyncStream<CMSampleBuffer> { get }
  func append(_ sample: CMSampleBuffer)
  func releaseOutputSlot()
  func finish()
}

extension ProgramStreamVideoEncoding {
  var inputBufferCapacity: Int { 2 }
}

struct ProgramStreamTransportStatistics: Equatable, Sendable {
  var connected = false
  var bytesSent: UInt64 = 0
  var queuedBytes = 0
  var droppedVideo: UInt64 = 0
  var bytesPerSecond: Int?
  var disconnectReason: ProgramStreamDisconnectReason?
  var encodedVideoFramesPerSecond: Int?
}

/// Only fixed local descriptions may enter operator status and diagnostics.
enum ProgramStreamDisconnectReason: String, Sendable {
  case rejected = "The destination rejected the stream."
  case connectionFailed = "Could not connect to the destination."
  case connectionTimedOut = "The destination did not respond in time."
  case connectionClosed = "The destination connection closed."
  case publishEnded = "The destination ended the publish."
  case socketBacklog = "The upload queue exceeded its live buffer."
  case uploadStalled = "The upload stopped making progress."
  case encoderFailure = "The video encoder stopped producing valid frames."
  case videoDeliveryStalled = "Program video stopped reaching the publisher."
  case audioDiscontinuity = "The Program audio clock jumped more than eight seconds."
}

enum ProgramStreamPublisherError: Error, Equatable {
  case rejected
  case unavailable
  case timedOut
  case encoderUnavailable
  case unsupportedCodec
}

protocol ProgramStreamPublishing: AnyObject, Sendable {
  func connect(server: String, key: String, format: ProgramStreamFormat, onDisconnect: @escaping @Sendable (ProgramStreamDisconnectReason) -> Void) async throws
  func setMediaEpoch(_ epoch: CMTime)
  func appendVideo(_ sample: CMSampleBuffer)
  func appendAudio(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime)
  func statistics() async -> ProgramStreamTransportStatistics
  func close() async
}

extension ProgramStreamPublishing {
  func setMediaEpoch(_ epoch: CMTime) {}

  func connect(server: String, key: String, onDisconnect: @escaping @Sendable (ProgramStreamDisconnectReason) -> Void) async throws {
    try await connect(server: server, key: key, format: .init(), onDisconnect: onDisconnect)
  }
}

#if ULTRACAM_STREAM_PUBLISHING || canImport(RTMPHaishinKit)
import HaishinKit
import Logboard
import RTMPHaishinKit
import VideoToolbox

func makeProgramStreamPublisher() -> any ProgramStreamPublishing { RTMPProgramPublisher() }

#if ULTRACAM_STREAM_SMOKE
func makeProgramStreamPublisher(beforeCompressedSend: @escaping @Sendable () async -> Void) -> any ProgramStreamPublishing {
  let publisher = RTMPProgramPublisher()
  publisher.beforeCompressedSend = beforeCompressedSend
  return publisher
}
#endif

/// One instance owns one network connection. The media callbacks enqueue immutable samples
/// synchronously, and each track has a single drain task to preserve order across actor hops.
private final class RTMPProgramPublisher: ProgramStreamPublishing, @unchecked Sendable {
  private let lock = NSLock()
  private let connection: RTMPConnection
  private let stream: RTMPStream
  private var closed = false
  private var live = false
  private var pendingFailure: ProgramStreamPublisherError?
  private var emptyWriteReports = 0
  private var maximumQueuedBytes = 0
  private var tasks = [Task<Void, Never>]()
  private var startup: Task<Void, any Error>?
  private var shutdown: Task<Void, Never>?
  private var disconnected: (@Sendable (ProgramStreamDisconnectReason) -> Void)?
  private var transport = ProgramStreamTransportStatistics()
  private var mediaEpoch: CMTime?
  private var videoInput: AsyncStream<CMSampleBuffer>.Continuation?
  private var audioInput: AsyncStream<AudioPacket>.Continuation?

  private struct AudioPacket: @unchecked Sendable {
    let pcm: AVAudioPCMBuffer
    let time: AVAudioTime
  }

  // RTMP command arguments and server-supplied status descriptions can carry publish keys.
  // Install this once before the first connection initializes the library's shared loggers.
  private static let configureLogging: Void = {
    for identifier in [kRTMPHaishinKitIdentifier, kHaishinKitIdentifier] {
      LBLogger.with(identifier).appender = NullAppender.shared
    }
  }()

  #if ULTRACAM_STREAM_SMOKE
  fileprivate var beforeCompressedSend: (@Sendable () async -> Void)?
  #endif

  init() {
    _ = Self.configureLogging
    // The transport waits for Network.framework to process each RTMP chunk. At
    // 50 Mbps, 128 KiB chunks keep most pictures within one or two TLS writes.
    let client = RTMPConnection(chunkSize: 128 * 1024)
    connection = client
    stream = RTMPStream(connection: client)
  }

  func connect(server: String, key: String, format: ProgramStreamFormat, onDisconnect: @escaping @Sendable (ProgramStreamDisconnectReason) -> Void) async throws {
    guard var url = URLComponents(string: server), let host = url.host, !host.isEmpty, !key.isEmpty,
      let scheme = url.scheme?.lowercased(),
      url.rangeOfPort == nil || url.port.map({ (1...65_535).contains($0) }) == true,
      scheme == "rtmps" || (scheme == "rtmp" && ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host))
    else { throw ProgramStreamPublisherError.rejected }
    url.scheme = scheme
    guard let endpoint = url.string else { throw ProgramStreamPublisherError.rejected }
    guard format.size != .source else { throw ProgramStreamPublisherError.encoderUnavailable }
    try format.validate()
    let videoBitRate = format.videoMbps * 1_000_000
    let opening = try lock.withLock {
      guard !closed, disconnected == nil else { throw CancellationError() }
      maximumQueuedBytes = (videoBitRate + 160_000) / 4 + 64_000
      disconnected = onDisconnect
      let opening = Task {
        try await open(endpoint: endpoint, key: key, format: format, videoBitRate: videoBitRate)
      }
      startup = opening
      return opening
    }

    do {
      try await withTaskCancellationHandler {
        try await opening.value
      } onCancel: {
        Task { await self.close() }
      }
    } catch {
      let (wasClosed, startupFailure) = lock.withLock { (closed, pendingFailure) }
      await close()
      if wasClosed || Task.isCancelled { throw CancellationError() }
      if startupFailure == .timedOut { throw ProgramStreamPublisherError.timedOut }
      if startupFailure == .rejected { throw ProgramStreamPublisherError.rejected }
      if error is CancellationError || error is ProgramStreamPublisherError { throw error }
      if case RTMPConnection.Error.connectionTimedOut = error { throw ProgramStreamPublisherError.timedOut }
      if case RTMPConnection.Error.requestFailed(let response) = error,
         [RTMPConnection.Code.connectRejected.rawValue, RTMPConnection.Code.connectInvalidApp.rawValue]
          .contains(response.status?.code ?? "") { throw ProgramStreamPublisherError.rejected }
      if case RTMPStream.Error.requestFailed(let response) = error,
         [RTMPStream.Code.publishBadName.rawValue, RTMPStream.Code.recordNoAccess.rawValue,
          RTMPStream.Code.connectRejected.rawValue].contains(response.status?.code ?? "") {
        throw ProgramStreamPublisherError.rejected
      }
      throw ProgramStreamPublisherError.unavailable
    }
  }

  private func open(endpoint: String, key: String, format: ProgramStreamFormat, videoBitRate: Int) async throws {
    try checkOpen()
    let dropped: @Sendable () -> Void = { [weak self] in self?.countDroppedVideo() }
    let failed: @Sendable () -> Void = { [weak self] in self?.ended(.encoderFailure) }
    let encoder: any ProgramStreamVideoEncoding
    if format.codec == .av1 {
      do { encoder = try makeProgramStreamAV1Encoder(format: format, dropped: dropped, failed: failed) }
      catch { throw ProgramStreamPublisherError.encoderUnavailable }
    } else {
      encoder = try ProgramStreamHardwareEncoder(format: format, dropped: dropped, failed: failed)
    }
    try await stream.setAudioSettings(AudioCodecSettings(bitRate: 160_000, sampleRate: 48_000))
    let codecID: UInt32 = switch format.codec {
    case .h264: 7
    case .av1: kCMVideoCodecType_AV1
    default: kCMVideoCodecType_HEVC
    }
    await stream.setPublishMetadata([
      "videocodecid": Double(codecID), "width": format.size.width, "height": format.size.height,
      "framerate": 1 / format.rate.duration.seconds, "videodatarate": format.videoMbps * 1_000
    ])
    await stream.setBitRateStrategy(TransportObserver(mamimumVideoBitRate: videoBitRate) { [weak self] report in self?.received(report) })
    let connectionEvents = await connection.status
    let streamEvents = await stream.status
    let monitor = Task { [weak self] in
      for await event in connectionEvents {
        switch event.code {
        case RTMPConnection.Code.connectRejected.rawValue, RTMPConnection.Code.connectInvalidApp.rawValue:
          // An initial connect rejection may carry an authentication challenge. The
          // command result classifies final startup rejection after authentication.
          self?.ended(.rejected, onlyWhenLive: true)
        case RTMPConnection.Code.connectUploadBacklog.rawValue:
          self?.ended(.socketBacklog)
        case RTMPConnection.Code.connectClosed.rawValue, RTMPConnection.Code.connectFailed.rawValue,
             RTMPConnection.Code.connectAppshutdown.rawValue, RTMPConnection.Code.connectIdleTimeOut.rawValue:
          self?.ended(.connectionClosed)
        default: break
        }
      }
    }
    let streamMonitor = Task { [weak self] in
      for await event in streamEvents {
        switch event.code {
        case RTMPStream.Code.publishBadName.rawValue, RTMPStream.Code.recordNoAccess.rawValue,
             RTMPStream.Code.connectRejected.rawValue:
          self?.ended(.rejected)
        case RTMPStream.Code.connectClosed.rawValue, RTMPStream.Code.failed.rawValue,
             RTMPStream.Code.publishIdle.rawValue, RTMPStream.Code.unpublishSuccess.rawValue:
          self?.ended(.publishEnded)
        default: break
        }
      }
    }
    guard install([monitor, streamMonitor]) else { throw CancellationError() }
    // A peer can accept TCP and never return an RTMP handshake. The library's socket
    // timeout covers TCP establishment; closing here also releases the pending handshake.
    let handshakeTimeout = Task { [weak self, connection] in
      do { try await Task.sleep(for: .seconds(20)) } catch { return }
      guard !Task.isCancelled, self?.startupTimedOut() == true else { return }
      await connection.closePermanently(gracefully: false)
    }
    defer { handshakeTimeout.cancel() }
    let response = try await connection.connect(endpoint)
    try checkOpen()
    if format.codec != .h264 {
      let fourCC = format.codec == .av1 ? "av01" : "hvc1"
      guard response.supportsVideoPublishing(fourCC: fourCC) else {
        throw ProgramStreamPublisherError.unsupportedCodec
      }
    }
    _ = try await stream.publish(key)
    try checkOpen()
    guard await connection.connected else { throw ProgramStreamPublisherError.unavailable }
    try checkOpen()
    try await startMedia(encoder)
  }

  private func checkOpen() throws {
    try Task.checkCancellation()
    try lock.withLock {
      if closed { throw CancellationError() }
      if let pendingFailure { throw pendingFailure }
    }
  }

  private func startupTimedOut() -> Bool {
    lock.withLock {
      guard !closed, !live, pendingFailure == nil else { return false }
      pendingFailure = .timedOut
      transport.disconnectReason = .connectionTimedOut
      return true
    }
  }

  private func install(_ work: [Task<Void, Never>]) -> Bool {
    lock.withLock {
      guard !closed else {
        work.forEach { $0.cancel() }
        return false
      }
      tasks += work
      return true
    }
  }

  private func countDroppedVideo() {
    lock.withLock { transport.droppedVideo &+= 1 }
  }

  func setMediaEpoch(_ epoch: CMTime) {
    lock.withLock {
      if mediaEpoch == nil { mediaEpoch = epoch }
    }
  }

  private func configureStreamEpoch() async {
    if let epoch = lock.withLock({ mediaEpoch }) {
      await stream.setPublishEpoch(epoch)
    }
  }

  private func startMedia(_ encoder: any ProgramStreamVideoEncoding) async throws {
    let video = AsyncStream.makeStream(of: CMSampleBuffer.self, bufferingPolicy: .bufferingNewest(encoder.inputBufferCapacity))
    let audio = AsyncStream.makeStream(of: AudioPacket.self, bufferingPolicy: .bufferingNewest(8))
    let videoDrain = Task { [weak self] in
      defer { encoder.finish() }
      var firstPicture = true
      for await sample in video.stream {
        guard !Task.isCancelled else { return }
        if firstPicture {
          await self?.configureStreamEpoch()
          firstPicture = false
        }
        guard !Task.isCancelled else { return }
        encoder.append(sample)
      }
    }
    #if ULTRACAM_STREAM_SMOKE
    let beforeSend = beforeCompressedSend
    #endif
    let compressedDrain = Task { [stream] in
      for await sample in encoder.output {
        defer { encoder.releaseOutputSlot() }
        guard !Task.isCancelled else { return }
        #if ULTRACAM_STREAM_SMOKE
        await beforeSend?()
        #endif
        guard !Task.isCancelled else { return }
        await stream.appendEncodedVideo(sample)
      }
    }
    let audioDrain = Task { [weak self, stream] in
      var lastEnd: Int64?
      var silence: AVAudioPCMBuffer?
      for await packet in audio.stream {
        guard !Task.isCancelled else { return }
        let start = packet.time.isSampleTimeValid && packet.time.sampleRate == 48_000 ? packet.time.sampleTime :
          CMTimeConvertScale(CMClockMakeHostTimeFromSystemUnits(packet.time.hostTime),
            timescale: 48_000, method: .roundHalfAwayFromZero).value
        guard start > 0, start <= Int64.max - Int64(packet.pcm.frameLength), start >= (lastEnd ?? start) else { continue }
        if lastEnd == nil { await self?.configureStreamEpoch() }
        guard !Task.isCancelled else { return }
        // Queue missing samples in order after the encoder's existing tail.
        // The codec's internal skip path is rendered ahead of queued PCM.
        if var cursor = lastEnd, start > cursor {
          guard start - cursor <= 8 * 48_000 else {
            self?.ended(.audioDiscontinuity)
            return
          }
          if silence == nil {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: packet.pcm.format, frameCapacity: 4096),
              let channels = buffer.floatChannelData else { self?.ended(.audioDiscontinuity); return }
            for channel in 0..<Int(buffer.format.channelCount) {
              channels[channel].update(repeating: 0, count: 4096)
            }
            silence = buffer
          }
          guard let silence else { return }
          while cursor < start {
            guard !Task.isCancelled else { return }
            let count = min(4096, start - cursor)
            silence.frameLength = AVAudioFrameCount(count)
            let host = CMClockConvertHostTimeToSystemUnits(CMTime(value: cursor, timescale: 48_000))
            await stream.append(silence, when: AVAudioTime(hostTime: host, sampleTime: cursor, atRate: 48_000))
            cursor += count
          }
        }
        let when = AVAudioTime(hostTime: packet.time.hostTime, sampleTime: start, atRate: 48_000)
        await stream.append(packet.pcm, when: when)
        lastEnd = start + Int64(packet.pcm.frameLength)
      }
    }
    let drains = [videoDrain, compressedDrain, audioDrain]
    do {
      try lock.withLock {
        if closed { throw CancellationError() }
        if let pendingFailure { throw pendingFailure }
        tasks += drains
        videoInput = video.continuation
        audioInput = audio.continuation
        live = true
        transport.connected = true
      }
    } catch {
      drains.forEach { $0.cancel() }
      for drain in drains { await drain.value }
      throw error
    }
  }

  func appendVideo(_ sample: CMSampleBuffer) {
    lock.withLock {
      if case .dropped = videoInput?.yield(sample) { transport.droppedVideo &+= 1 }
    }
  }

  func appendAudio(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
    guard buffer.frameLength > 0, buffer.frameLength <= 4096, time.isHostTimeValid else { return }
    lock.withLock { _ = audioInput?.yield(AudioPacket(pcm: buffer, time: time)) }
  }

  func statistics() async -> ProgramStreamTransportStatistics {
    let fps = Int(await stream.currentFPS)
    return lock.withLock {
      var result = transport
      result.encodedVideoFramesPerSecond = fps
      return result
    }
  }

  private func received(_ report: NetworkMonitorReport) {
    let reason = lock.withLock { () -> ProgramStreamDisconnectReason? in
      guard live, !closed else { return nil }
      let sent = UInt64(max(0, report.totalBytesOut))
      let queued = max(0, report.currentQueueBytesOut)
      // Count actual transport reports with outstanding data. A suspended app, quiet
      // encoder or delayed UI poll supplies no evidence that the network has stalled.
      emptyWriteReports = queued > 0 && sent == transport.bytesSent ? emptyWriteReports + 1 : 0
      transport.bytesSent = sent
      transport.queuedBytes = queued
      transport.bytesPerSecond = max(0, report.currentBytesOutPerSecond)
      if queued > maximumQueuedBytes { return .socketBacklog }
      return emptyWriteReports >= 8 ? .uploadStalled : nil
    }
    if let reason { ended(reason) }
  }

  private func ended(_ reason: ProgramStreamDisconnectReason, onlyWhenLive: Bool = false) {
    let callback = lock.withLock { () -> (@Sendable (ProgramStreamDisconnectReason) -> Void)? in
      guard !closed, transport.disconnectReason == nil, live || !onlyWhenLive else { return nil }
      transport.disconnectReason = reason
      pendingFailure = reason == .rejected ? .rejected : .unavailable
      guard live else { return nil }
      live = false
      transport.connected = false
      finishMedia()
      tasks.forEach { $0.cancel() }
      return disconnected
    }
    callback?(reason)
  }

  // Requires lock.
  private func finishMedia() {
    videoInput?.finish()
    audioInput?.finish()
    videoInput = nil
    audioInput = nil
  }

  func close() async {
    let shutdown = lock.withLock {
      if let shutdown { return shutdown }
      closed = true
      live = false
      disconnected = nil
      transport.connected = false
      finishMedia()
      let gracefully = transport.disconnectReason == nil
      let opening = startup
      startup = nil
      let work = tasks
      tasks.removeAll()
      let shutdown = Task { [connection] in
        opening?.cancel()
        work.forEach { $0.cancel() }
        await connection.closePermanently(gracefully: gracefully)
        _ = await opening?.result
        for task in work { await task.value }
      }
      self.shutdown = shutdown
      return shutdown
    }
    await shutdown.value
  }

  private struct TransportObserver: StreamBitRateStrategy {
    let mamimumVideoBitRate: Int
    let mamimumAudioBitRate = 160_000
    let receive: @Sendable (NetworkMonitorReport) -> Void

    func adjustBitrate(_ event: NetworkMonitorEvent, stream: some StreamConvertible) async {
      switch event {
      case .status(let report), .publishInsufficientBWOccured(let report): receive(report)
      case .reset: break
      }
    }
  }
}

/// Explicit encoder properties keep the selected codec, hardware and color contract
/// intact when the sample is published to an independent receiver.
private final class ProgramStreamHardwareEncoder: ProgramStreamVideoEncoding, @unchecked Sendable {
  private static let pictureCapacity = 10
  private let format: ProgramStreamFormat
  let inputBufferCapacity: Int
  let output: AsyncStream<CMSampleBuffer>
  private let continuation: AsyncStream<CMSampleBuffer>.Continuation
  // Only the serial input worker uses and releases the session after startup.
  private var session: VTCompressionSession?
  private let dropped: @Sendable () -> Void
  private let failed: @Sendable () -> Void
  private let lock = NSLock()
  private var accepting = true
  private var pending = 0
  private var nextFrameID: UInt64 = 0
  private var awaitingCallback = Set<UInt64>(minimumCapacity: pictureCapacity)
  private var encoderFullSince: TimeInterval?

  init(format: ProgramStreamFormat, dropped: @escaping @Sendable () -> Void, failed: @escaping @Sendable () -> Void) throws {
    self.format = format
    self.dropped = dropped
    self.failed = failed
    let channel = AsyncStream.makeStream(of: CMSampleBuffer.self, bufferingPolicy: .bufferingOldest(8))
    output = channel.stream
    continuation = channel.continuation
    let profile: CFString
    switch format.codec {
    case .h264: profile = kVTProfileLevel_H264_Main_AutoLevel
    case .hevc: profile = kVTProfileLevel_HEVC_Main_AutoLevel
    case .hevcMain10: profile = kVTProfileLevel_HEVC_Main10_AutoLevel
    case .hevcMain10_422: profile = kVTProfileLevel_HEVC_Main42210_AutoLevel
    case .av1: throw ProgramStreamPublisherError.encoderUnavailable
    }
    // At UHD high rates the normal AVC encoder can hold all eight input pictures.
    // Low-latency AVC emits earlier, with occasional synchronous submission bursts.
    let frameDuration = format.rate.duration
    // The low-latency H.264 rate controller drops UHD inputs above 60 fps.
    let useLowLatency = format.codec == .h264 && format.size.width >= 3840 &&
      frameDuration >= FrameRateTarget.fps60.duration && frameDuration <= FrameRateTarget.fps47952.duration
    let bitrate = format.videoMbps * 1_000_000
    let fps = 1 / frameDuration.seconds
    let hdr = format.colorSpaceID != "rec709-video"
    let transfer: CFString
    switch format.colorSpaceID {
    case "rec2020-pq-video": transfer = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
    case "rec2020-hlg-video": transfer = kCVImageBufferTransferFunction_ITU_R_2100_HLG
    default: transfer = kCVImageBufferTransferFunction_ITU_R_709_2
    }
    let properties: [CFString: Any] = [
      kVTCompressionPropertyKey_RealTime: true,
      kVTCompressionPropertyKey_ProfileLevel: profile,
      kVTCompressionPropertyKey_AllowFrameReordering: false,
      kVTCompressionPropertyKey_AverageBitRate: bitrate,
      kVTCompressionPropertyKey_DataRateLimits: [bitrate * 3 / 16, 1],
      kVTCompressionPropertyKey_ExpectedFrameRate: fps,
      kVTCompressionPropertyKey_MaxKeyFrameInterval: Int(ceil(fps * 2)),
      kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2,
      kVTCompressionPropertyKey_ColorPrimaries: hdr ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2,
      kVTCompressionPropertyKey_TransferFunction: transfer,
      kVTCompressionPropertyKey_YCbCrMatrix: hdr ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2
    ]
    let attributes = [kCVPixelBufferPixelFormatTypeKey: format.codec.pixelFormat] as CFDictionary
    func makeSession(lowLatency: Bool) -> VTCompressionSession? {
      var spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
      if lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
      var encoder: VTCompressionSession?
      let status = VTCompressionSessionCreate(allocator: nil, width: Int32(format.size.width), height: Int32(format.size.height),
        codecType: format.codec == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC,
        encoderSpecification: spec as CFDictionary, imageBufferAttributes: attributes,
        compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &encoder)
      guard let encoder else { return nil }
      guard status == noErr,
        VTSessionSetProperties(encoder, propertyDictionary: properties as CFDictionary) == noErr,
        VTCompressionSessionPrepareToEncodeFrames(encoder) == noErr,
        Self.isHardware(encoder, lowLatency: lowLatency) else {
        VTCompressionSessionInvalidate(encoder)
        return nil
      }
      return encoder
    }
    if useLowLatency, let encoder = makeSession(lowLatency: true) {
      inputBufferCapacity = 4
      session = encoder
    } else if let encoder = makeSession(lowLatency: false) {
      inputBufferCapacity = 2
      session = encoder
    } else {
      throw ProgramStreamPublisherError.encoderUnavailable
    }
  }

  deinit {
    if let session { VTCompressionSessionInvalidate(session) }
  }

  private static func isHardware(_ session: VTCompressionSession, lowLatency: Bool) -> Bool {
    var hardware: Unmanaged<CFTypeRef>?
    let status = VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
      allocator: nil, valueOut: &hardware)
    let accelerated = (hardware?.takeRetainedValue() as? NSNumber)?.boolValue
    if status == noErr { return accelerated == true }
    // The Apple low-latency AVC wrapper uses AppleAVE but does not expose the flag.
    // Its creation above still requires hardware.
    guard lowLatency, status == kVTPropertyNotSupportedErr else { return false }
    var encoderID: Unmanaged<CFTypeRef>?
    let idStatus = VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_EncoderID,
      allocator: nil, valueOut: &encoderID)
    let identifier = encoderID?.takeRetainedValue() as? String
    return idStatus == noErr && identifier == "com.apple.videotoolbox.videoencoder.h264.rtvc"
  }

  // One input task calls append and finish in order. VideoToolbox can call back before encode returns.
  func append(_ sample: CMSampleBuffer) {
    guard let session else { return }
    guard let image = sample.imageBuffer,
      CVPixelBufferGetWidth(image) == format.size.width, CVPixelBufferGetHeight(image) == format.size.height,
      CVPixelBufferGetPixelFormatType(image) == format.codec.pixelFormat else {
      fail()
      return
    }
    let reservation = lock.withLock { () -> (frameID: UInt64?, stalled: Bool) in
      guard accepting else { return (nil, false) }
      guard pending < Self.pictureCapacity - inputBufferCapacity else {
        // A full raw window can prevent the next submission from advancing the encoder.
        // Let the transport watch for compressed pictures waiting to be sent.
        guard pending == awaitingCallback.count else { return (nil, false) }
        let now = ProcessInfo.processInfo.systemUptime
        let since = encoderFullSince ?? now
        encoderFullSince = since
        let stalled = now - since >= 1
        if stalled { accepting = false }
        return (nil, stalled)
      }
      pending += 1
      nextFrameID &+= 1
      awaitingCallback.insert(nextFrameID)
      return (nextFrameID, false)
    }
    guard let frameID = reservation.frameID else {
      dropped()
      if reservation.stalled { failed() }
      return
    }
    let producer = sample.retainedImageFrame
    var flags = VTEncodeInfoFlags()
    let status = VTCompressionSessionEncodeFrame(session, imageBuffer: image,
      presentationTimeStamp: sample.presentationTimeStamp, duration: sample.duration,
      frameProperties: nil, infoFlagsOut: &flags) { [weak self] status, flags, compressed in
      defer { withExtendedLifetime(producer) {} }
      self?.completeFrame(frameID, status: status, flags: flags, compressed: compressed)
    }
    if status != noErr || flags.contains(.frameDropped) {
      completeFrame(frameID, status: status, flags: flags, compressed: nil)
    }
  }

  private func completeFrame(_ frameID: UInt64, status: OSStatus, flags: VTEncodeInfoFlags, compressed: CMSampleBuffer?) {
    // Both the submission and its callback can report a synchronous drop.
    let claimed = lock.withLock {
      guard awaitingCallback.remove(frameID) != nil else { return false }
      encoderFullSince = nil
      return true
    }
    guard claimed else { return }
    guard status == noErr, !flags.contains(.frameDropped), let compressed else {
      releaseOutputSlot()
      if status == noErr, flags.contains(.frameDropped) { dropped() }
      else { fail() }
      return
    }
    // Hold the slot until RTMP consumes the reference picture so that network
    // pressure drops raw pictures before encoding instead of breaking the GOP.
    switch continuation.yield(compressed) {
    case .enqueued: return
    case .terminated:
      releaseOutputSlot()
      return
    case .dropped: break
    @unknown default: break
    }
    releaseOutputSlot()
    fail()
  }

  func releaseOutputSlot() {
    lock.withLock { pending -= 1 }
  }

  private func fail() {
    let shouldReport = lock.withLock {
      guard accepting else { return false }
      accepting = false
      return true
    }
    if shouldReport { failed() }
  }

  func finish() {
    lock.withLock { accepting = false }
    continuation.finish()
    if let session {
      self.session = nil
      VTCompressionSessionInvalidate(session)
    }
  }
}
#else
// Direct-swiftc fixtures inject their own publisher. Xcode production builds require the
// package import through ULTRACAM_STREAM_PUBLISHING.
func makeProgramStreamPublisher() -> any ProgramStreamPublishing { UnavailableProgramPublisher() }

private final class UnavailableProgramPublisher: ProgramStreamPublishing {
  func connect(server: String, key: String, format: ProgramStreamFormat, onDisconnect: @escaping @Sendable (ProgramStreamDisconnectReason) -> Void) async throws {
    throw ProgramStreamPublisherError.unavailable
  }
  func appendVideo(_ sample: CMSampleBuffer) {}
  func appendAudio(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {}
  func statistics() async -> ProgramStreamTransportStatistics { .init() }
  func close() async {}
}
#endif
