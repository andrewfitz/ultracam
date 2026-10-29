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
  let publisher = SyntheticRegistryPublisher()
  let format: SourceFormat
  let audio: SourceAudioFormat
  let duration: CMTime
  private let claims = CaptureDeviceClaims()

  init(duration: CMTime = VideoContract.fastDuration, deviceIDs: [String] = ["fake:fixture"]) throws {
    guard duration == VideoContract.fastDuration || duration == VideoContract.slowDuration else {
      throw PluginError.unsupported("Synthetic fixture supports Part A rates only")
    }
    self.duration = duration
    format = try SourceFormat(width: 3840, height: 2160, pixel: .v210, rate: .constant(duration))
    audio = try SourceAudioFormat(sampleRate: 48000, channels: 2, sample: .int32,
      interleaved: true, layout: AudioChannelMap(), clock: .pairedWithFrames)
    plugin = FakeCapturePlugin(format: format, audio: .present(audio), deviceIDs: deviceIDs)
    registry = try VendorRegistry(capture: [plugin])
  }
  var hardware: AppHardware {
    let plugin = plugin, sink = sink, claims = claims
    return .registry(registry, captureServices: { id in
      var services = CaptureServices.registry(feedID: id, plugins: [plugin], claims: claims)
      services.connect = { _, _ in sink.connect() }
      services.disconnect = { sink.disconnect() }
      services.send = { sink.send($0) }
      return services
    })
  }
  func connect() { plugin.setConnected(true) }
  func disconnect() { plugin.setConnected(false) }
  func stop() { plugin.sessions.forEach { $0.stop() } }

  /// Explicit test-only CPU pattern generation. The production app excludes
  /// this entire file. The returned v210 IOSurface is published immutably.
  func makePattern() throws -> CVPixelBuffer {
    var made: CVPixelBuffer?
    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true]
    guard CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10,
      attributes as CFDictionary, &made) == kCVReturnSuccess, let image = made else {
      throw PluginError.failed("Synthetic IOSurface allocation failed")
    }
    guard CVPixelBufferLockBaseAddress(image, []) == kCVReturnSuccess else { throw PluginError.failed("Synthetic pixel lock failed") }
    defer { CVPixelBufferUnlockBaseAddress(image, []) }
    guard let base = CVPixelBufferGetBaseAddress(image) else { throw PluginError.failed("Synthetic pixels unavailable") }
    let stride = CVPixelBufferGetBytesPerRow(image)
    for y in 0..<2160 {
      let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt32.self)
      for group in 0..<(stride / 16) {
        let luma = UInt32(64 + min(group, 639) * 876 / 639)
        row[group * 4] = 512 | (luma << 10) | (512 << 20)
        row[group * 4 + 1] = luma | (512 << 10) | (luma << 20)
        row[group * 4 + 2] = 512 | (luma << 10) | (512 << 20)
        row[group * 4 + 3] = luma | (512 << 10) | (luma << 20)
      }
    }
    CVBufferSetAttachment(image, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(image, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(image, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    return image
  }
  /// Each active session receives frame → media → PCM in one admitted group.
  /// Return count is admitted sessions, so stopped sessions never mask progress.
  @discardableResult func emit(_ image: CVPixelBuffer, index: Int32) throws -> Int {
    guard index >= 0 else { throw PluginError.unsupported("Synthetic frame index must be nonnegative") }
    let pts = CMTimeMultiply(duration, multiplier: index)
    let nominal: Int32 = duration == VideoContract.fastDuration ? 60 : 30
    let seconds = Int(index / nominal)
    let timecode = try Timecode(hours: (1 + seconds / 3600) % 24, minutes: (seconds / 60) % 60,
      seconds: seconds % 60, frames: Int(index % nominal), dropFrame: false)
    return try plugin.sessions.reduce(0) { count, session in
      let context = session.context
      let frameSequence = context.nextSequence
      let info = CaptureFrameInfo(epochID: context.epochID, formatSignature: context.formatSignature,
        presentationTime: pts, duration: duration, signalValid: true, timecode: timecode)
      let startSample = Int64(index) * duration.value * 48000 / Int64(duration.timescale)
      let endSample = (Int64(index) + 1) * duration.value * 48000 / Int64(duration.timescale)
      let sampleCount = Int(endSample - startSample)
      // Signed little-endian constant-amplitude stereo: the declared peaks
      // and RMS below exactly describe these owned PCM samples.
      var pcm = Data(capacity: sampleCount * 8)
      for _ in 0..<sampleCount { pcm.append(contentsOf: [0, 0, 0, 32, 0, 0, 0, 16]) }
      let audioTime = CMTime(value: startSample, timescale: 48000)
      let packet = try CaptureAudioPacket(planes: [pcm], sampleFrameCount: sampleCount, format: audio,
        packetTime: audioTime, pairedFrameSequence: frameSequence)
      let media = CaptureMediaInfo(timecode: timecode, pairedFrameSequence: frameSequence,
        audioDeclaration: .present(audio), audioPacketTime: audioTime, audioClockInstance: nil,
        sampleFrameCount: sampleCount, byteCount: pcm.count, peaks: [0.25, 0.125], rms: [0.25, 0.125])
      return count + (session.submitGroup([.frame(CapturedPixelBuffer(immutable: image), info), .media(media), .rawAudio(packet)]) ? 1 : 0)
    }
  }
}

final class SyntheticCameraSink: @unchecked Sendable {
  private let lock = NSLock()
  private var connections = 0
  private var sent = 0
  func connect() { lock.withLock { connections += 1 } }
  func disconnect() { lock.withLock { connections = max(0, connections - 1) } }
  func send(_ sample: CMSampleBuffer) -> Bool { lock.withLock { sent += 1; return true } }
  var sentCount: Int { lock.withLock { sent } }
}
@MainActor final class SyntheticRegistryPublisher: AppVirtualCameraRegistryPublishing {
  private(set) var snapshots: [VirtualCameraRegistrySnapshot] = []
  func publish(_ snapshot: VirtualCameraRegistrySnapshot) { snapshots.append(snapshot) }
}
#endif
