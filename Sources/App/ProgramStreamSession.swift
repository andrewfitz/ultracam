@preconcurrency import AVFAudio
import CoreMedia
import Foundation
import LocalAuthentication
import Security

/// The chosen settings are frozen into a concrete canvas at stream startup. Every
/// connection, including recovery, publishes that same format until the session ends.
struct ProgramStreamFormat: Codable, Equatable, Sendable {
  var size: ResizeTarget = .hd1080
  var rate: FrameRateTarget = .fps30
  var codec: ProgramStreamVideoCodec = .h264
  var videoMbps = 6
  var scalingMode: ProgramScalingMode = .fit
  var allowUpscale = false
  var colorSpaceID = "rec709-video"

  static let sizes = ResizeTarget.allCases
  static let rates = FrameRateTarget.allCases
  var supportedColorSpaceIDs: [String] {
    switch codec {
    case .hevcMain10, .hevcMain10_422: return ["rec709-video", "rec2020-pq-video", "rec2020-hlg-video"]
    default: return ["rec709-video"]
    }
  }

  func validate() throws {
    guard (1...50).contains(videoMbps) else {
      throw ProgramStreamSettingsError(message: "Choose a stream bitrate between 1 and 50 Mbps.")
    }
    guard supportedColorSpaceIDs.contains(colorSpaceID) else {
      throw ProgramStreamSettingsError(message: "Choose a color space supported by the selected stream codec.")
    }
  }
}

extension ProgramStreamFormat {
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    size = try values.decode(ResizeTarget.self, forKey: .size)
    rate = try values.decode(FrameRateTarget.self, forKey: .rate)
    codec = try values.decode(ProgramStreamVideoCodec.self, forKey: .codec)
    videoMbps = try values.decode(Int.self, forKey: .videoMbps)
    scalingMode = try values.decode(ProgramScalingMode.self, forKey: .scalingMode)
    allowUpscale = try values.decodeIfPresent(Bool.self, forKey: .allowUpscale) ?? false
    colorSpaceID = try values.decode(String.self, forKey: .colorSpaceID)
  }
}

struct ProgramStreamConfiguration: Codable, Equatable, Sendable {
  var name = ""
  var server = ""
  var audioFeedID: String?
  var firstChannel = 0
  var format = ProgramStreamFormat()
}

extension ProgramStreamConfiguration {
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    name = try values.decode(String.self, forKey: .name)
    server = try values.decode(String.self, forKey: .server)
    audioFeedID = try values.decodeIfPresent(String.self, forKey: .audioFeedID)
    firstChannel = try values.decode(Int.self, forKey: .firstChannel)
    // Destinations saved before selectable formats always used 1080p30 H.264 at 6 Mbps.
    format = try values.decodeIfPresent(ProgramStreamFormat.self, forKey: .format) ?? ProgramStreamFormat()
    try format.validate()
  }
}

enum ProgramStreamPhase: String, Equatable, Sendable {
  case idle, connecting, streaming, reconnecting, failed
}

struct ProgramStreamSnapshot: Equatable, Sendable {
  var phase: ProgramStreamPhase = .idle
  var configured = false
  var name = ""
  var audioFeedID: String?
  var firstChannel = 0
  var format = ProgramStreamFormat()
  var startedAt: Date?
  var pictureFresh = false
  var pictureFeedID: String?
  var lastVideoSentAt: Date?
  var audioMissing = false
  var audioPeak: Float = 0
  var lastError: String?
  var lastInterruption: ProgramStreamDisconnectReason?
  var needsSetup = false
  var bitrate: Double = 0
  var droppedVideo: UInt64 = 0
  var audioGaps: UInt64 = 0

  var active: Bool { phase == .connecting || phase == .streaming || phase == .reconnecting }
}

struct ProgramStreamSettingsError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

protocol ProgramStreamCredentialStoring: Sendable {
  func read() throws -> Data?
  func write(_ data: Data) throws
  func remove() throws
}

/// Keep endpoint and key together. Some services put credentials in the URL itself;
/// neither the full URL nor a partially updated server/key pair may reach defaults.
struct ProgramStreamKeychain: ProgramStreamCredentialStoring {
  let account: String
  init(account: String = UUID().uuidString) { self.account = account }
  private var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: "org.ultracam.program-stream",
     kSecAttrAccount as String: account,
     kSecUseDataProtectionKeychain as String: true,
     kSecAttrSynchronizable as String: false]
  }
  private func check(_ status: OSStatus) throws {
    guard status == errSecSuccess else {
      throw ProgramStreamSettingsError(message: "The stream credentials could not be accessed in Keychain (\(status)).")
    }
  }
  func read() throws -> Data? {
    var request = query
    let context = LAContext()
    context.interactionNotAllowed = true
    request[kSecUseAuthenticationContext as String] = context
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    try check(status)
    guard let data = result as? Data else {
      throw ProgramStreamSettingsError(message: "Save the stream destination again.")
    }
    return data
  }
  func write(_ data: Data) throws {
    let request = query
    let values: [String: Any] = [kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
    var status = SecItemUpdate(request as CFDictionary, values as CFDictionary)
    if status == errSecItemNotFound {
      var item = request
      item.merge(values) { _, new in new }
      status = SecItemAdd(item as CFDictionary, nil)
      if status == errSecDuplicateItem {
        status = SecItemUpdate(request as CFDictionary, values as CFDictionary)
      }
    }
    try check(status)
  }
  func remove() throws {
    let status = SecItemDelete(query as CFDictionary)
    if status != errSecItemNotFound { try check(status) }
  }
}

@MainActor
final class ProgramStreamSession {
  private struct Saved: Codable { var configuration: ProgramStreamConfiguration; var key: String }
  private static let settingsMarker = "programStream.credentialAccount"
  private let credentialAccount: String
  private let defaults: UserDefaults
  private let credentials: any ProgramStreamCredentialStoring
  private let makePublisher: @Sendable () -> any ProgramStreamPublishing
  private let retryDelays: [TimeInterval]
  private let preflightTimeout: TimeInterval
  private let connectionTimeout: TimeInterval
  private let progressTimeout: TimeInterval
  private var generation: UInt64 = 0
  private var attempt: UInt64 = 0
  private var retryIndex = 0
  private var closingCount = 0
  private var task: Task<Void, Never>?
  private var watchdog: Task<Void, Never>?
  private var publisher: (any ProgramStreamPublishing)?
  private var media: ProgramStreamMedia?
  private var liveSettings: Saved?
  private var previousDrops: UInt64 = 0
  private var loaded = false
  private(set) var configuration = ProgramStreamConfiguration()
  private(set) var snapshot = ProgramStreamSnapshot()
  var onChange: (() -> Void)?
  var needsShutdown: Bool { snapshot.active || closingCount > 0 }

  init(defaults: UserDefaults = .standard,
       credentials: (any ProgramStreamCredentialStoring)? = nil,
       makePublisher: @escaping @Sendable () -> any ProgramStreamPublishing = { makeProgramStreamPublisher() },
       retryDelays: [TimeInterval] = [1, 2, 4, 8, 15], preflightTimeout: TimeInterval = 5,
       connectionTimeout: TimeInterval = 25, progressTimeout: TimeInterval = 8) {
    self.defaults = defaults
    let account = defaults.string(forKey: Self.settingsMarker).flatMap(UUID.init(uuidString:)) ?? UUID()
    credentialAccount = account.uuidString
    self.credentials = credentials ?? ProgramStreamKeychain(account: account.uuidString)
    self.makePublisher = makePublisher
    self.retryDelays = retryDelays
    self.preflightTimeout = preflightTimeout
    self.connectionTimeout = connectionTimeout
    self.progressTimeout = progressTimeout
    if defaults.string(forKey: Self.settingsMarker) != nil {
      do {
        guard let saved = try readSaved() else {
          throw ProgramStreamSettingsError(message: "Save the stream destination again.")
        }
        configuration = saved.configuration
        loaded = true
        reflectSettings()
      } catch {
        snapshot.lastError = error.localizedDescription
        snapshot.needsSetup = true
      }
    }
  }

  private var hasCredentialReference: Bool {
    defaults.string(forKey: Self.settingsMarker).flatMap(UUID.init(uuidString:))?.uuidString == credentialAccount
  }

  private func readSaved() throws -> Saved? {
    guard hasCredentialReference else { return nil }
    let data: Data?
    do { data = try credentials.read() }
    catch { throw ProgramStreamSettingsError(message: "Unlock your Keychain and try again.") }
    guard let data else { return nil }
    do {
      var saved = try JSONDecoder().decode(Saved.self, from: data)
      saved.configuration = try validatedConfiguration(saved.configuration)
      try validateKey(saved.key)
      return saved
    } catch {
      throw ProgramStreamSettingsError(message: "Save the stream destination again.")
    }
  }

  private func validatedConfiguration(_ config: ProgramStreamConfiguration) throws -> ProgramStreamConfiguration {
    var next = config
    try next.format.validate()
    next.name = next.name.trimmingCharacters(in: .whitespacesAndNewlines)
    next.server = next.server.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !next.name.isEmpty, next.name.utf8.count <= 128 else {
      throw ProgramStreamSettingsError(message: "Enter a destination name of up to 128 bytes.")
    }
    guard next.server.utf8.count <= 8192, var url = URLComponents(string: next.server),
      url.scheme?.lowercased() == "rtmps", let host = url.host, !host.isEmpty,
      url.rangeOfPort == nil || url.port.map({ (1...65_535).contains($0) }) == true,
      url.fragment == nil, next.server.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
      next.server.rangeOfCharacter(from: .controlCharacters) == nil else {
      throw ProgramStreamSettingsError(message: "Enter a valid RTMPS server URL.")
    }
    url.scheme = "rtmps"
    next.server = url.string ?? next.server
    guard next.firstChannel >= 0, next.firstChannel < 64, next.firstChannel.isMultiple(of: 2),
      next.audioFeedID?.isEmpty != true else {
      throw ProgramStreamSettingsError(message: "Choose an embedded audio feed and channel pair.")
    }
    return next
  }

  private func validateKey(_ secret: String) throws {
    guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      secret.rangeOfCharacter(from: .controlCharacters) == nil, secret.utf8.count <= 16384 else {
      throw ProgramStreamSettingsError(message: "Enter a stream key for this server.")
    }
  }

  func save(_ config: ProgramStreamConfiguration, key: String) throws {
    let next = try validatedConfiguration(config)
    var secret = key
    if key.isEmpty, let previous = try readSaved(), previous.configuration.server == next.server {
      secret = previous.key
    }
    try validateKey(secret)
    do { try credentials.write(JSONEncoder().encode(Saved(configuration: next, key: secret))) }
    catch { throw ProgramStreamSettingsError(message: "The stream destination could not be saved in Keychain.") }
    defaults.set(credentialAccount, forKey: Self.settingsMarker)
    configuration = next
    loaded = true
    if !snapshot.active { snapshot = ProgramStreamSnapshot(); reflectSettings() }
    onChange?()
  }

  func resetConfiguration() throws {
    stop()
    if hasCredentialReference {
      do { try credentials.remove() }
      catch { throw ProgramStreamSettingsError(message: "The stream destination could not be removed from Keychain.") }
    }
    defaults.removeObject(forKey: Self.settingsMarker)
    loaded = false
    configuration = ProgramStreamConfiguration()
    snapshot = ProgramStreamSnapshot()
    onChange?()
  }

  private func reflectSettings() {
    snapshot.configured = loaded
    snapshot.name = configuration.name
    snapshot.audioFeedID = configuration.audioFeedID
    snapshot.firstChannel = configuration.firstChannel
    snapshot.format = configuration.format
  }

  func start(validate: (ProgramStreamConfiguration) throws -> Void = { _ in }) throws {
    guard !snapshot.active else { return }
    guard let saved = try readSaved() else {
      throw ProgramStreamSettingsError(message: "Set up the streaming destination first.")
    }
    try validate(saved.configuration)
    liveSettings = saved
    loaded = true
    configuration = saved.configuration
    generation &+= 1
    retryIndex = 0
    previousDrops = 0
    snapshot = ProgramStreamSnapshot(phase: .connecting)
    reflectSettings()
    let next = ProgramStreamMedia(wantsAudio: saved.configuration.audioFeedID != nil)
    media = next
    let expected = generation
    let deadline = ProcessInfo.processInfo.systemUptime + preflightTimeout
    task = Task { [weak self] in
      guard let self else { return }
      while self.generation == expected, !Task.isCancelled {
        let health = next.health
        let audioReady = saved.configuration.audioFeedID == nil || health.audioReady
        let canvasReady = self.liveSettings?.configuration.format.size != .source
        if health.freshPicture, audioReady, canvasReady {
          self.connect(expected)
          return
        }
        if ProcessInfo.processInfo.systemUptime >= deadline {
          if !canvasReady {
            self.fail("The on-air camera has not supplied a source size. Check capture and retry.")
          } else if !health.freshPicture {
            self.fail("No Program picture arrived. Check the on-air camera and capture.")
          } else {
            self.fail("No embedded audio arrived. Check the selected feed and channel pair.", needsSetup: true)
          }
          return
        }
        try? await Task.sleep(for: .milliseconds(25))
      }
    }
    onChange?()
  }

  /// Source Size follows the initiating Program feed. Later cuts and saved edits leave
  /// the negotiated canvas intact, including on transport reconnects.
  func resolveSourceSize(_ canvas: ResizeTarget) {
    guard canvas != .source, snapshot.phase == .connecting, liveSettings?.configuration.format.size == .source else { return }
    liveSettings?.configuration.format.size = canvas
    snapshot.format.size = canvas
    onChange?()
  }

  func makeVideoHandler() -> @Sendable (CMSampleBuffer, Bool) -> Void {
    { [weak media] image, fresh in media?.video(image, fresh: fresh) }
  }

  func makeAudioHandler() -> @Sendable (AVAudioPCMBuffer, CMTime) -> Void {
    { [weak media] pcm, time in media?.audio(pcm, at: time) }
  }

  private func connect(_ expected: UInt64) {
    guard expected == generation, let settings = liveSettings else { return }
    guard settings.configuration.format.size != .source else {
      fail("The on-air camera has not supplied a source size. Check capture and retry.")
      return
    }
    attempt &+= 1
    let token = attempt
    task = Task { [weak self] in
      // A quick Stop/Start with the same key must release the old publish before
      // a second client asks the service to publish under that name.
      guard let self else { return }
      let deadline = ProcessInfo.processInfo.systemUptime + 5
      while self.closingCount > 0 {
        guard self.generation == expected, self.attempt == token, !Task.isCancelled else { return }
        if ProcessInfo.processInfo.systemUptime >= deadline {
          self.fail("The previous stream is still closing. Retry once it has disconnected.")
          return
        }
        try? await Task.sleep(for: .milliseconds(20))
      }
      guard self.generation == expected, self.attempt == token, !Task.isCancelled else { return }
      let connection = self.makePublisher()
      self.publisher = connection
      self.armWatchdog(expected, attempt: token, after: self.connectionTimeout, reason: .connectionTimedOut)
      do {
        try await connection.connect(server: settings.configuration.server, key: settings.key, format: settings.configuration.format) { [weak self] reason in
          Task { @MainActor in self?.disconnected(expected, attempt: token, reason: reason) }
        }
      } catch {
        guard self.generation == expected, self.attempt == token, !Task.isCancelled else { return }
        switch error as? ProgramStreamPublisherError {
        case .encoderUnavailable:
          self.fail("The selected \(settings.configuration.format.codec.title) encoder is unavailable for this format. Check encoder use or change the stream settings.", needsSetup: true)
        case .unsupportedCodec:
          self.fail("\(settings.configuration.name) does not accept \(settings.configuration.format.codec.title). Choose another codec in Streaming settings.", needsSetup: true)
        case .rejected:
          self.disconnected(expected, attempt: token, reason: .rejected)
        case .timedOut:
          self.disconnected(expected, attempt: token, reason: .connectionTimedOut)
        case .unavailable, nil:
          self.disconnected(expected, attempt: token, reason: .connectionFailed)
        }
        return
      }
      // Stop and disconnect already own teardown, including a connection still opening.
      guard expected == self.generation, token == self.attempt, !Task.isCancelled else { return }
      self.cancelWatchdog()
      self.media?.attach(connection)
      await self.monitor(connection, expected: expected, attempt: token, wantsAudio: settings.configuration.audioFeedID != nil)
    }
  }

  private func monitor(_ connection: any ProgramStreamPublishing, expected: UInt64, attempt token: UInt64,
                       wantsAudio: Bool) async {
    let connectedAt = ProcessInfo.processInfo.systemUptime
    var bytesAtSample: UInt64 = 0
    var observedBytes: UInt64 = 0
    var observedFrames: UInt64 = 0
    var lastStatsAt = connectedAt
    var lastProgressAt = connectedAt
    var lastFrameAt = connectedAt
    var lastEncodedAt = connectedAt
    var healthySince: TimeInterval?
    while !Task.isCancelled {
      try? await Task.sleep(for: .milliseconds(400))
      guard !Task.isCancelled, generation == expected, attempt == token else { return }
      armWatchdog(expected, attempt: token, after: progressTimeout, reason: .uploadStalled)
      let stats = await connection.statistics()
      guard !Task.isCancelled, generation == expected, attempt == token, let health = media?.health else { return }
      cancelWatchdog()
      let now = ProcessInfo.processInfo.systemUptime
      snapshot.droppedVideo = previousDrops &+ stats.droppedVideo
      snapshot.audioGaps = health.audioGaps
      snapshot.lastVideoSentAt = health.lastVideoSentAt ?? snapshot.lastVideoSentAt
      guard stats.connected else {
        disconnected(expected, attempt: token, reason: stats.disconnectReason ?? .connectionClosed)
        return
      }

      if stats.bytesSent > observedBytes { lastProgressAt = now }
      observedBytes = stats.bytesSent
      if health.sentFrames > observedFrames { lastFrameAt = now }
      observedFrames = health.sentFrames
      let encodedPicture = (stats.encodedVideoFramesPerSecond ?? 1) > 0
      if encodedPicture, health.sentFrames > 0 { lastEncodedAt = now }
      if now - lastFrameAt >= progressTimeout {
        disconnected(expected, attempt: token, reason: .videoDeliveryStalled)
        return
      }
      if now - lastEncodedAt >= progressTimeout {
        disconnected(expected, attempt: token, reason: .encoderFailure)
        return
      }
      if now - lastProgressAt >= progressTimeout {
        disconnected(expected, attempt: token, reason: .uploadStalled)
        return
      }

      // Socket totals update independently of the status sampling interval.
      if now - lastStatsAt >= 2 {
        let delta = stats.bytesSent >= bytesAtSample ? stats.bytesSent - bytesAtSample : 0
        snapshot.bitrate = Double(delta) * 8 / (now - lastStatsAt)
        lastStatsAt = now
        bytesAtSample = stats.bytesSent
      }
      if let bytesPerSecond = stats.bytesPerSecond { snapshot.bitrate = Double(bytesPerSecond) * 8 }
      let healthy = health.sentFrames > 0 && encodedPicture && stats.bytesSent > 0 &&
        now - lastProgressAt < 1.5 && now - lastFrameAt < 1.5
      if healthy {
        snapshot.phase = .streaming
        snapshot.startedAt = snapshot.startedAt ?? Date()
        snapshot.lastError = nil
        healthySince = healthySince ?? now
        if now - (healthySince ?? now) > 10 { retryIndex = 0 }
      } else {
        healthySince = nil
      }
      snapshot.pictureFresh = healthy && health.freshPicture
      snapshot.pictureFeedID = snapshot.pictureFresh ? health.pictureFeedID : nil
      snapshot.audioMissing = wantsAudio && health.sentFrames > 0 && (health.missingAudio || !health.audioReady)
      snapshot.audioPeak = snapshot.audioMissing ? 0 : health.peak
      onChange?()
    }
  }

  private func armWatchdog(_ expected: UInt64, attempt token: UInt64, after timeout: TimeInterval,
                           reason: ProgramStreamDisconnectReason) {
    cancelWatchdog()
    watchdog = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
      self?.disconnected(expected, attempt: token, reason: reason)
    }
  }

  private func cancelWatchdog() {
    watchdog?.cancel()
    watchdog = nil
  }

  private func disconnected(_ expected: UInt64, attempt token: UInt64, reason: ProgramStreamDisconnectReason) {
    guard generation == expected, attempt == token, snapshot.active else { return }
    attempt &+= 1
    task?.cancel()
    cancelWatchdog()
    media?.attach(nil)
    closePublisher()
    // Preserve the initiating interruption if the subsequent connection attempts fail.
    let startupFailure = reason == .connectionFailed || reason == .connectionTimedOut
    if !startupFailure || snapshot.lastInterruption == nil || snapshot.lastInterruption == .connectionFailed {
      snapshot.lastInterruption = reason
    }
    if reason == .rejected {
      fail("The destination rejected the stream. Check the server and stream key.", needsSetup: true)
      return
    }
    guard retryIndex < retryDelays.count else {
      fail((snapshot.lastInterruption ?? reason).rawValue + " Check the destination and retry.")
      return
    }
    let delay = retryDelays[retryIndex]
    retryIndex += 1
    previousDrops = snapshot.droppedVideo
    snapshot.phase = .reconnecting
    snapshot.pictureFresh = false
    snapshot.pictureFeedID = nil
    snapshot.audioMissing = false
    snapshot.audioPeak = 0
    snapshot.bitrate = 0
    snapshot.lastError = reason.rawValue + " Reconnecting…"
    task = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      self?.connect(expected)
    }
    onChange?()
  }

  private func closePublisher() {
    guard let previous = publisher else { return }
    publisher = nil
    closingCount += 1
    Task { [weak self] in
      await previous.close()
      self?.closingCount -= 1
    }
  }

  private func tearDown() {
    generation &+= 1
    task?.cancel()
    task = nil
    cancelWatchdog()
    media?.stop()
    media = nil
    closePublisher()
    liveSettings = nil
  }

  func stop() {
    tearDown()
    snapshot = ProgramStreamSnapshot()
    reflectSettings()
    onChange?()
  }

  /// Stop local delivery immediately and allow the closing RTMP handshake to finish on quit.
  func shutdown() async {
    stop()
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while closingCount > 0, !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline {
      try? await Task.sleep(for: .milliseconds(20))
    }
  }

  func fail(_ message: String, needsSetup: Bool = false) {
    tearDown()
    snapshot.phase = .failed
    snapshot.pictureFresh = false
    snapshot.pictureFeedID = nil
    snapshot.bitrate = 0
    snapshot.audioPeak = 0
    snapshot.audioMissing = false
    snapshot.lastError = message
    snapshot.needsSetup = needsSetup
    onChange?()
  }
}
