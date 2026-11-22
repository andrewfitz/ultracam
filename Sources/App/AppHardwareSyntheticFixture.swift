#if ULTRACAM_TEST_SUPPORT
import Foundation
import CoreMedia
import CoreVideo

/// Explicit command-driven hardware for tool verification. No timer, capture
/// device, CMIO connection or camera publication is opened by construction.
@MainActor final class AppHardwareSyntheticFixture {
  let plugin: FakeCapturePlugin
  let registry: VendorRegistry
  let sink = SyntheticCameraSink()
  let programSink = SyntheticCameraSink()
  let publisher = SyntheticRegistryPublisher()
  let format: SourceFormat
  let audio: SourceAudioFormat
  let duration: CMTime
  private let claims = CaptureDeviceClaims()

  init(duration: CMTime = VideoContract.fastDuration, deviceIDs: [String] = ["fake:fixture"], audioChannels: Int = 2,
       width: Int = 3840, height: Int = 2160, pixel: PixelFormatID = .v210) throws {
    guard duration == VideoContract.fastDuration || duration == VideoContract.slowDuration else {
      throw PluginError.unsupported("Synthetic fixture supports Part A rates only")
    }
    self.duration = duration
    format = try SourceFormat(width: width, height: height, pixel: pixel, rate: .constant(duration))
    audio = try SourceAudioFormat(sampleRate: 48000, channels: audioChannels, sample: .int32,
      interleaved: true, layout: AudioChannelMap(), clock: .pairedWithFrames)
    plugin = FakeCapturePlugin(format: format, audio: .present(audio), deviceIDs: deviceIDs)
    registry = try VendorRegistry(capture: [plugin])
  }
  var hardware: AppHardware {
    let plugin = plugin, sink = sink, programSink = programSink, claims = claims
    var hardware = AppHardware.registry(registry, captureServices: { id in
      var services = CaptureServices.registry(feedID: id, plugins: [plugin], claims: claims)
      // Both paths: a fixture camera must never reach the Mac's real virtual cameras.
      services.connect = { _, _ in try sink.connect() }
      services.connectWithSource = { _, _, _ in try sink.connect() }
      services.preNegotiate = nil
      services.disconnect = { sink.disconnect() }
      services.send = { sink.send($0) }
      return services
    })
    hardware.programBridge = { route in
      ProgramOutputBridge(route: route, connect: { _, _ in try programSink.connect() },
        disconnect: { programSink.disconnect() }, send: { programSink.send($0) },
        preNegotiate: { _, _ in programSink.preNegotiate() }, paced: true)
    }
    return hardware
  }
  func connect() { plugin.setConnected(true) }
  func disconnect() { plugin.setConnected(false) }
  func stop() { plugin.sessions.forEach { $0.stop() } }

  /// Explicit test-only CPU pattern generation. The production app excludes
  /// this entire file. The returned IOSurface is published immutably.
  func makePattern(lumaCode: UInt32? = nil, width: Int? = nil, height: Int? = nil) throws -> CVPixelBuffer {
    let width = width ?? format.width
    let height = height ?? format.height
    var made: CVPixelBuffer?
    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
    guard CVPixelBufferCreate(nil, width, height, format.pixel.rawValue,
      attributes as CFDictionary, &made) == kCVReturnSuccess, let image = made else {
      throw PluginError.failed("Synthetic IOSurface allocation failed")
    }
    guard CVPixelBufferLockBaseAddress(image, []) == kCVReturnSuccess else { throw PluginError.failed("Synthetic pixel lock failed") }
    defer { CVPixelBufferUnlockBaseAddress(image, []) }
    if format.pixel == .video420 {
      guard let luma = CVPixelBufferGetBaseAddressOfPlane(image, 0),
        let chroma = CVPixelBufferGetBaseAddressOfPlane(image, 1) else {
        throw PluginError.failed("Synthetic planar pixels unavailable")
      }
      memset(luma, Int32((lumaCode ?? 512) / 4), CVPixelBufferGetBytesPerRowOfPlane(image, 0) * height)
      memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(image, 1) * CVPixelBufferGetHeightOfPlane(image, 1))
    } else {
      guard format.pixel == .v210, let base = CVPixelBufferGetBaseAddress(image) else {
        throw PluginError.failed("Synthetic packed pixels unavailable")
      }
      let stride = CVPixelBufferGetBytesPerRow(image)
      for y in 0..<height {
        let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
        for group in 0..<(stride / 16) {
          let luma = lumaCode ?? UInt32(64 + min(group, 639) * 876 / 639)
          row[group * 4] = 512 | (luma << 10) | (512 << 20)
          row[group * 4 + 1] = luma | (512 << 10) | (luma << 20)
          row[group * 4 + 2] = 512 | (luma << 10) | (512 << 20)
          row[group * 4 + 3] = luma | (512 << 10) | (luma << 20)
        }
      }
    }
    CVBufferSetAttachment(image, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(image, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(image, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    return image
  }
  /// Each active session receives frame → media → PCM in one admitted group.
  /// Return count is admitted sessions, so stopped sessions never mask progress.
  @discardableResult func emit(_ image: CVPixelBuffer, index: Int32, forDevice device: String? = nil,
                                firstChannelLevel: Int8 = 32, toneHz: Double? = nil, firstPairToneHz: Double? = nil,
                                captureEndHostTime: CMTime? = nil, sourceFormat: SourceFormat? = nil) throws -> Int {
    guard index >= 0 else { throw PluginError.unsupported("Synthetic frame index must be nonnegative") }
    let duration = sourceFormat?.rate.nominal ?? self.duration
    let pts = CMTimeMultiply(duration, multiplier: index)
    let nominal: Int32 = duration == VideoContract.fastDuration ? 60 : 30
    let seconds = Int(index / nominal)
    let timecode = try Timecode(hours: (1 + seconds / 3600) % 24, minutes: (seconds / 60) % 60,
      seconds: seconds % 60, frames: Int(index % nominal), dropFrame: false)
    return try plugin.sessions.reduce(0) { count, session in
      if let device, session.deviceID != device { return count }
      if let sourceFormat, session.context.formatSignature != sourceFormat.signature {
        guard session.submit(.event(.formatChanged(sourceFormat))) else { return count }
      }
      let context = session.context
      let frameSequence = context.nextSequence
      let info = CaptureFrameInfo(epochID: context.epochID, formatSignature: context.formatSignature,
        presentationTime: pts, duration: duration, signalValid: true, timecode: timecode,
        hostTimeReference: captureEndHostTime == nil ? .presentationStart : .presentationEnd,
        captureHostTime: captureEndHostTime)
      let startSample = Int64(index) * duration.value * 48000 / Int64(duration.timescale)
      let endSample = (Int64(index) + 1) * duration.value * 48000 / Int64(duration.timescale)
      let sampleCount = Int(endSample - startSample)
      // Signed stereo PCM, optionally modulated for receiver-side tone identification.
      let channels = audio.channels
      var pcm = Data(count: sampleCount * channels * MemoryLayout<Int32>.size)
      var peaks = Array(repeating: 0.0, count: channels)
      var squares = peaks
      pcm.withUnsafeMutableBytes { bytes in
        let samples = bytes.bindMemory(to: Int32.self)
        for i in 0..<sampleCount {
          let phase = 2 * .pi * Double(startSample + Int64(i)) / 48_000
          for c in 0..<channels {
            let hz = c < 2 ? firstPairToneHz ?? toneHz : toneHz
            let gain = hz.map { sin(phase * $0) } ?? 1
            let value = (c.isMultiple(of: 2) ? Double(firstChannelLevel) / 128 : 0.125) * gain
            samples[i * channels + c] = Int32(clamping: Int64(value * 2_147_483_648))
            peaks[c] = max(peaks[c], abs(value))
            squares[c] += value * value
          }
        }
      }
      let audioTime = CMTime(value: startSample, timescale: 48000)
      let packet = try CaptureAudioPacket(planes: [pcm], sampleFrameCount: sampleCount, format: audio,
        packetTime: audioTime, pairedFrameSequence: frameSequence)
      let media = CaptureMediaInfo(timecode: timecode, pairedFrameSequence: frameSequence,
        audioDeclaration: .present(audio), audioPacketTime: audioTime, audioClockInstance: nil,
        sampleFrameCount: sampleCount, byteCount: pcm.count, peaks: peaks, rms: squares.map { sqrt($0 / Double(sampleCount)) })
      return count + (session.submitGroup([.frame(CapturedPixelBuffer(immutable: image), info), .media(media), .rawAudio(packet)]) ? 1 : 0)
    }
  }
}

final class SyntheticCameraSink: @unchecked Sendable {
  private let lock = NSLock()
  private var connections = 0
  private var attempts = 0
  private var failures = 0
  private var sent = 0
  private var preNegotiated = 0
  func connect() throws {
    try lock.withLock {
      attempts += 1
      if failures > 0 { failures -= 1; throw VideoError.message("Install and enable the Ultracam camera extension.") }
      connections += 1
    }
  }
  func disconnect() { lock.withLock { connections = max(0, connections - 1) } }
  func send(_ sample: CMSampleBuffer) -> Bool { lock.withLock { sent += 1; return true } }
  func failNextConnects(_ count: Int) { lock.withLock { failures = count } }
  /// A format written to the closed camera, for its first client.
  func preNegotiate() { lock.withLock { preNegotiated += 1 } }
  var sentCount: Int { lock.withLock { sent } }
  var preNegotiations: Int { lock.withLock { preNegotiated } }
  var connectAttempts: Int { lock.withLock { attempts } }
  var openConnections: Int { lock.withLock { connections } }
}
@MainActor final class SyntheticRegistryPublisher: AppVirtualCameraRegistryPublishing {
  private(set) var snapshots: [VirtualCameraRegistrySnapshot] = []
  func publish(_ snapshot: VirtualCameraRegistrySnapshot) { snapshots.append(snapshot) }
}
#endif
