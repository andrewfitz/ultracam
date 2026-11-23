@preconcurrency import AVFAudio
import CoreMedia
import Foundation

final class FixtureKeychain: ProgramStreamCredentialStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var value: Data?
  func read() throws -> Data? { lock.withLock { value } }
  func write(_ data: Data) throws { lock.withLock { value = data } }
  func remove() throws { lock.withLock { value = nil } }
}

/// Only the loopback fixture converts the transport scheme. All session settings and
/// media paths are the production ones. The optional TLS scenario uses the original URL.
final class FixturePublisher: ProgramStreamPublishing, @unchecked Sendable {
  private let transport: any ProgramStreamPublishing
  private let loopbackPlaintext: Bool
  private let didConnect: @Sendable () -> Void
  private let didAppendVideo: @Sendable (CMSampleBuffer) -> Void
  private let didAppendAudio: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
  private let lock = NSLock()
  private var initialVideoDrops: Int

  init(loopbackPlaintext: Bool, transport: any ProgramStreamPublishing = makeProgramStreamPublisher(),
       initialVideoDrops: Int = 0,
       didConnect: @escaping @Sendable () -> Void = {},
       didAppendVideo: @escaping @Sendable (CMSampleBuffer) -> Void = { _ in },
       didAppendAudio: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { _, _ in }) {
    self.transport = transport
    self.loopbackPlaintext = loopbackPlaintext
    self.initialVideoDrops = initialVideoDrops
    self.didConnect = didConnect
    self.didAppendVideo = didAppendVideo
    self.didAppendAudio = didAppendAudio
  }

  func connect(server: String, key: String, format: ProgramStreamFormat, onDisconnect: @escaping @Sendable (ProgramStreamDisconnectReason) -> Void) async throws {
    guard var url = URLComponents(string: server), let host = url.host else { throw URLError(.badURL) }
    let addresses = Host(name: host).addresses
    guard !addresses.isEmpty, addresses.allSatisfy({ $0 == "127.0.0.1" || $0 == "::1" }) else {
      throw URLError(.unsupportedURL)
    }
    if loopbackPlaintext { url.scheme = "rtmp" }
    try await transport.connect(server: url.string!, key: key, format: format, onDisconnect: onDisconnect)
    didConnect()
  }

  func setMediaEpoch(_ epoch: CMTime, includesAudio: Bool) {
    transport.setMediaEpoch(epoch, includesAudio: includesAudio)
  }

  func appendVideo(_ sample: CMSampleBuffer) {
    if lock.withLock({
      guard initialVideoDrops > 0 else { return false }
      initialVideoDrops -= 1
      return true
    }) { return }
    didAppendVideo(sample)
    transport.appendVideo(sample)
  }
  func appendAudio(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
    didAppendAudio(buffer, time)
    transport.appendAudio(buffer, at: time)
  }
  func statistics() async -> ProgramStreamTransportStatistics { await transport.statistics() }
  func close() async { await transport.close() }
}
