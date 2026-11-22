import AVFoundation
import Foundation

/// One instance per capture session, accessed on its serial configuration/delegate queue.
final class MacCameraAudio {
  static let settingsKey = "microphone"
  private static let off = "off"
  private static let linkedPrefix = "linked:"
  private static let inputPrefix = "input:"
  private static let claims = MacMicrophoneClaims()
  // The host meter and source activity path accept up to sixteen channels.
  private static let maximumChannels = 16
  private static let maximumPacketBytes = 1024 * 1024
  private let selection: String
  private var input: AVCaptureDeviceInput?
  private var connection: AVCaptureConnection?
  private var claimedUID: String?
  private var converted = false
  private var activeMode: AVCaptureDevice.MicrophoneMode?
  private var packetFormat: PacketFormat?
  private(set) var output: AVCaptureAudioDataOutput?
  private(set) var status = "Microphone Off"

  init(selection: String?) { self.selection = selection ?? Self.off }
  deinit { if let claimedUID { Self.claims.release(claimedUID) } }

  var isEnabled: Bool { selection != Self.off }
  func isCurrentDisconnect(_ notifiedDevice: ObjectIdentifier) -> Bool {
    guard let device = (connection?.inputPorts.first?.input as? AVCaptureDeviceInput)?.device else { return false }
    return Self.isCurrentDisconnect(notifiedDevice, attached: ObjectIdentifier(device), stillConnected: device.isConnected)
  }

  static func isCurrentDisconnect(_ notifiedDevice: ObjectIdentifier, attached: ObjectIdentifier,
    stillConnected: Bool) -> Bool {
    // AVFoundation may vend a different wrapper for a disconnected device.
    // A replacement that is still connected must never inherit that event.
    notifiedDevice == attached || !stillConnected
  }

  var deviceUID: String? {
    guard isEnabled else { return nil }
    for prefix in [Self.linkedPrefix, Self.inputPrefix] where selection.hasPrefix(prefix) {
      return String(selection.dropFirst(prefix.count))
    }
    return selection
  }

  private static func microphones() -> [AVCaptureDevice] {
    let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
      .devices.filter { $0.isConnected && !$0.uniqueID.isEmpty }
    let countByUID = Dictionary(grouping: devices, by: \.uniqueID)
    return devices.filter { countByUID[$0.uniqueID]?.count == 1 }.sorted {
        if $0.localizedName == $1.localizedName { return $0.uniqueID < $1.uniqueID }
        return $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending
      }
  }

  private static func linkedMicrophone(for camera: AVCaptureDevice) -> AVCaptureDevice? {
    var candidates: [String: AVCaptureDevice] = [:]
    for device in [camera] + camera.linkedDevices where device.isConnected && device.hasMediaType(.audio) {
      candidates[device.uniqueID] = device
    }
    guard candidates.count == 1 else { return nil }
    return candidates.values.first
  }

  static func setting(for camera: AVCaptureDevice, selected: String?) -> VendorSetting {
    var choices: [VendorSetting.Choice] = [
      .init(id: off, label: "Off", labelKey: "microphone.off", localizationTable: "MacCamera")
    ]
    if let linked = linkedMicrophone(for: camera) {
      choices.append(.init(id: linkedPrefix + linked.uniqueID, label: "System linked · \(linked.localizedName)"))
    }
    let devices = microphones()
    let duplicates = Dictionary(grouping: devices, by: \.localizedName)
    choices += devices.map {
      let label = duplicates[$0.localizedName, default: []].count == 1
        ? $0.localizedName : "\($0.localizedName) · \($0.uniqueID)"
      return .init(id: inputPrefix + $0.uniqueID, label: label)
    }
    let selected = selected ?? off
    if !choices.contains(where: { $0.id == selected }) {
      if let existing = choices.first(where: { $0.id == inputPrefix + selected }) {
        choices.append(.init(id: selected, label: existing.label))
      } else {
        choices.append(.init(id: selected, label: "Saved microphone unavailable"))
      }
    }
    return VendorSetting(id: settingsKey, labelKey: "microphone.label", value: .choice(selected),
      allowedValues: .choices(choices), mutable: true, availabilityReason: nil,
      interruptsCapture: true, labelFallback: "Microphone", localizationTable: "MacCamera")
  }

  @MainActor static func authorize(selection: String?) async {
    guard let selection, selection != off, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
    if let permissionRequest { _ = await permissionRequest.value; return }
    let request = Task { await AVCaptureDevice.requestAccess(for: .audio) }
    permissionRequest = request
    _ = await request.value
    permissionRequest = nil
  }

  @MainActor private static var permissionRequest: Task<Bool, Never>?

  /// Call inside beginConfiguration/commitConfiguration, with the camera input already installed.
  func attach(to session: AVCaptureSession, cameraInput: AVCaptureDeviceInput,
    delegate: any AVCaptureAudioDataOutputSampleBufferDelegate, queue: DispatchQueue) {
    guard output == nil, let uid = deviceUID else { return }
    guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
      status = "Allow microphone access in System Settings › Privacy & Security › Microphone."
      return
    }
    let camera = cameraInput.device
    let audioDevice: AVCaptureDevice?
    if uid == camera.uniqueID && cameraInput.ports.contains(where: { $0.mediaType == .audio }) {
      audioDevice = camera
    } else if selection.hasPrefix(Self.linkedPrefix) {
      audioDevice = Self.linkedMicrophone(for: camera).flatMap { $0.uniqueID == uid ? $0 : nil }
    } else {
      audioDevice = Self.microphones().first(where: { $0.uniqueID == uid })
    }
    guard let audioDevice, audioDevice.isConnected else {
      status = "The selected microphone is disconnected."
      return
    }
    guard Self.claims.claim(uid) else {
      status = "The selected microphone is already used by another feed."
      return
    }
    do {
      try configure(session, audioDevice: audioDevice, cameraInput: cameraInput, delegate: delegate, queue: queue)
      claimedUID = uid
      updateStatus()
    } catch {
      Self.claims.release(uid)
      status = "The selected microphone could not be opened. \(error.localizedDescription)"
    }
  }

  private func configure(_ session: AVCaptureSession, audioDevice: AVCaptureDevice,
    cameraInput: AVCaptureDeviceInput, delegate: any AVCaptureAudioDataOutputSampleBufferDelegate,
    queue: DispatchQueue) throws {
    let ownsInput = audioDevice.uniqueID != cameraInput.device.uniqueID
    let selectedInput = ownsInput ? try AVCaptureDeviceInput(device: audioDevice) : cameraInput
    let audioPorts = selectedInput.ports.filter { $0.mediaType == .audio && $0.isEnabled }
    guard audioPorts.count == 1 else {
      throw PluginError.unsupported("The input has no unique audio port.")
    }
    let output = AVCaptureAudioDataOutput()
    let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audioDevice.activeFormat.formatDescription)?.pointee
    if let asbd, asbd.mChannelsPerFrame > Self.maximumChannels {
      throw PluginError.unsupported("Microphone input supports up to \(Self.maximumChannels) channels.")
    }
    if let asbd, Self.sampleType(asbd) == nil {
      output.audioSettings = Self.pcmSettings
      converted = true
    } else {
      output.audioSettings = nil
      converted = false
    }
    if ownsInput {
      guard session.canAddInput(selectedInput) else { throw PluginError.busy("The session refused the audio input.") }
      session.addInputWithNoConnections(selectedInput)
    }
    var configured = false
    defer {
      if !configured && ownsInput { session.removeInput(selectedInput) }
    }
    guard session.canAddOutput(output) else { throw PluginError.busy("The session refused the audio output.") }
    session.addOutputWithNoConnections(output)
    let connection = AVCaptureConnection(inputPorts: audioPorts, output: output)
    guard session.canAddConnection(connection) else {
      session.removeOutput(output)
      throw PluginError.busy("The session could not connect the selected audio port.")
    }
    session.addConnection(connection)
    output.setSampleBufferDelegate(delegate, queue: queue)
    self.input = ownsInput ? selectedInput : nil
    self.output = output
    self.connection = connection
    configured = true
  }

  func detach(from session: AVCaptureSession) {
    if let connection { session.removeConnection(connection) }
    if let output {
      output.setSampleBufferDelegate(nil, queue: nil)
      session.removeOutput(output)
    }
    if let input { session.removeInput(input) }
    if let claimedUID { Self.claims.release(claimedUID) }
    connection = nil
    output = nil
    input = nil
    claimedUID = nil
    activeMode = nil
    status = isEnabled ? "The selected microphone is unavailable." : "Microphone Off"
  }

  private static let pcmSettings: [String: Int] = [
    AVFormatIDKey: Int(kAudioFormatLinearPCM),
    AVLinearPCMBitDepthKey: 32,
    AVLinearPCMIsFloatKey: 1,
    AVLinearPCMIsBigEndianKey: 0,
    AVLinearPCMIsNonInterleaved: 0
  ]

  /// Retry once with converted PCM when the first sample disagrees with the advertised native format.
  func requestPCMConversion() -> Bool {
    guard let output, !converted else { return false }
    output.audioSettings = Self.pcmSettings
    converted = true
    updateStatus()
    return true
  }

  private func updateStatus() {
    let activeMode = AVCaptureDevice.activeMicrophoneMode
    self.activeMode = activeMode
    let mode: String
    switch activeMode {
    case .standard: mode = "Standard"
    case .voiceIsolation: mode = "Voice Isolation"
    case .wideSpectrum: mode = "Wide Spectrum"
    @unknown default: mode = "Unknown microphone mode"
    }
    let name = (connection?.inputPorts.first?.input as? AVCaptureDeviceInput)?.device.localizedName
    status = "\(name ?? "Microphone") · \(mode)\(converted ? " · Converted to Float32 PCM" : "")"
  }

  static func sampleType(_ asbd: AudioStreamBasicDescription) -> AudioSampleType? {
    let flags = asbd.mFormatFlags
    guard asbd.mFormatID == kAudioFormatLinearPCM, flags & kAudioFormatFlagIsBigEndian == 0,
      asbd.mFramesPerPacket == 1, asbd.mBytesPerPacket == asbd.mBytesPerFrame,
      asbd.mChannelsPerFrame > 0 else { return nil }
    let channels = flags & kAudioFormatFlagIsNonInterleaved == 0 ? UInt64(asbd.mChannelsPerFrame) : 1
    guard UInt64(asbd.mBytesPerFrame) % channels == 0 else { return nil }
    let bytesPerSample = UInt64(asbd.mBytesPerFrame) / channels
    if flags & kAudioFormatFlagIsFloat != 0 {
      return asbd.mBitsPerChannel == 32 && bytesPerSample == 4 ? .float32 : nil
    }
    guard flags & kAudioFormatFlagIsSignedInteger != 0 else { return nil }
    switch (asbd.mBitsPerChannel, bytesPerSample) {
    case (16, 2): return .int16
    case (24, 4): return flags & kAudioFormatFlagIsAlignedHigh == 0 ? .int24in32 : nil
    case (32, 4): return .int32
    default: return nil
    }
  }

  func packet(from sample: CMSampleBuffer, clock: AudioClockDomain = .deviceClock) throws -> CaptureAudioPacket {
    let packet = try Self.readPacket(sample, clock: clock, cachedFormat: &packetFormat)
    if output != nil, activeMode != AVCaptureDevice.activeMicrophoneMode { updateStatus() }
    return packet
  }

  enum SampleError: LocalizedError {
    case unsupportedEncoding
    var errorDescription: String? { "The microphone delivered an unsupported audio encoding." }
  }

  static func readPacket(_ sample: CMSampleBuffer, clock: AudioClockDomain = .deviceClock) throws -> CaptureAudioPacket {
    var cachedFormat: PacketFormat?
    return try readPacket(sample, clock: clock, cachedFormat: &cachedFormat)
  }

  private struct PacketFormat {
    let description: CMAudioFormatDescription
    let format: SourceAudioFormat
    let bytesPerFrame: Int
  }

  private static func readFormat(_ description: CMAudioFormatDescription, clock: AudioClockDomain) throws -> PacketFormat {
    guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
      throw PluginError.unsupported("Microphone sample has no ready audio data.")
    }
    let channels = Int(asbd.mChannelsPerFrame)
    guard (1...maximumChannels).contains(channels) else {
      throw PluginError.unsupported("Microphone input supports between one and \(maximumChannels) channels.")
    }
    guard let type = sampleType(asbd) else { throw SampleError.unsupportedEncoding }
    let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
    let format = try SourceAudioFormat(sampleRate: asbd.mSampleRate, channels: channels, sample: type,
      interleaved: interleaved, layout: try channelMap(description, channels: channels), clock: clock)
    return PacketFormat(description: description, format: format, bytesPerFrame: Int(asbd.mBytesPerFrame))
  }

  private static func readPacket(_ sample: CMSampleBuffer, clock: AudioClockDomain,
    cachedFormat: inout PacketFormat?) throws -> CaptureAudioPacket {
    guard CMSampleBufferDataIsReady(sample), let description = CMSampleBufferGetFormatDescription(sample) else {
      throw PluginError.unsupported("Microphone sample has no ready audio data.")
    }
    let packetFormat: PacketFormat
    // Core Media descriptions are immutable. Their full equality includes the
    // PCM stream description and channel layout used by the format signature.
    if let cachedFormat, cachedFormat.format.clock == clock,
      cachedFormat.description === description || CFEqual(cachedFormat.description, description) {
      packetFormat = cachedFormat
    } else {
      packetFormat = try readFormat(description, clock: clock)
      cachedFormat = packetFormat
    }
    let format = packetFormat.format
    let interleaved = format.interleaved
    let channels = format.channels
    let frameCount = CMSampleBufferGetNumSamples(sample)
    let (bytes, overflow) = frameCount.multipliedReportingOverflow(by: packetFormat.bytesPerFrame)
    let planeCount = interleaved ? 1 : channels
    guard frameCount > 0, !overflow, bytes <= maximumPacketBytes / planeCount else {
      throw PluginError.unsupported("Microphone packet exceeds the audio buffer limit.")
    }

    let buffers = AudioBufferList.allocate(maximumBuffers: planeCount)
    defer { free(buffers.unsafeMutablePointer) }
    var storage: CMBlockBuffer?
    let result = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil,
      bufferListOut: buffers.unsafeMutablePointer, bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: planeCount),
      blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &storage)
    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
    return try withExtendedLifetime(storage) {
      guard result == noErr, buffers.count == planeCount else {
        throw PluginError.unsupported("Microphone sample has an invalid audio buffer list.")
      }
      let planes = try buffers.map { buffer in
        guard let data = buffer.mData, buffer.mDataByteSize == bytes,
          buffer.mNumberChannels == (interleaved ? channels : 1) else {
          throw PluginError.unsupported("Microphone sample has an invalid PCM plane.")
        }
        return interleaved ? Data(bytes: data, count: bytes) : Data(bytesNoCopy: data, count: bytes, deallocator: .none)
      }
      if interleaved {
        return try CaptureAudioPacket(ownedInterleavedPCM: planes[0], sampleFrameCount: frameCount,
          format: format, packetTime: pts)
      }
      // The packet initializer owns a copy before releasing the Core Media storage.
      return try CaptureAudioPacket(planes: planes, sampleFrameCount: frameCount, format: format, packetTime: pts)
    }
  }

  private static func channelMap(_ description: CMAudioFormatDescription, channels: Int) throws -> AudioChannelMap {
    var size = 0
    guard let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &size) else {
      return AudioChannelMap()
    }
    let offset = MemoryLayout<AudioChannelLayout>.offset(of: \AudioChannelLayout.mChannelDescriptions)!
    guard size >= offset else { throw PluginError.unsupported("Microphone channel layout is truncated.") }
    let tag = layout.pointee.mChannelLayoutTag
    if tag & 0xffff0000 == kAudioChannelLayoutTag_Unknown { return AudioChannelMap() }
    if tag == kAudioChannelLayoutTag_UseChannelDescriptions {
      let count = Int(layout.pointee.mNumberChannelDescriptions)
      guard count == channels, size >= offset + count * MemoryLayout<AudioChannelDescription>.stride else {
        throw PluginError.unsupported("Microphone channel descriptions do not match the sample.")
      }
      let addresses = UnsafeRawPointer(layout).advanced(by: offset).assumingMemoryBound(to: AudioChannelDescription.self)
      let labels = (0..<count).map { addresses[$0].mChannelLabel }
      guard !labels.contains(kAudioChannelLabel_UseCoordinates) else {
        throw PluginError.unsupported("The microphone uses an unsupported coordinate channel layout.")
      }
      return AudioChannelMap(labels: labels)
    }
    if tag == kAudioChannelLayoutTag_UseChannelBitmap {
      // Bitmap order is ascending by channel bit. Core Audio channel labels
      // corresponding to those positions are one-based for the defined bed channels.
      let bitmap = layout.pointee.mChannelBitmap.rawValue
      let labels: [UInt32] = (0..<18).compactMap { bit in
        bitmap & (UInt32(1) << bit) == 0 ? nil : UInt32(bit + 1)
      }
      guard bitmap >> 18 == 0, labels.count == channels else {
        throw PluginError.unsupported("Microphone channel bitmap cannot be preserved.")
      }
      return AudioChannelMap(labels: labels)
    }
    guard tag & 0xffff == channels else {
      throw PluginError.unsupported("Microphone channel layout does not match the sample.")
    }
    return AudioChannelMap(layoutTag: tag)
  }
}

final class MacMicrophoneClaims: @unchecked Sendable {
  private let lock = NSLock()
  private var claimed: Set<String> = []

  func claim(_ uid: String) -> Bool { lock.withLock { claimed.insert(uid).inserted } }
  func release(_ uid: String) { _ = lock.withLock { claimed.remove(uid) } }
}

struct MacCameraAudioTimeline {
  enum Transition: Equatable { case continuous, gap, reset }
  private var lastPTS: CMTime?
  private var expectedPTS: CMTime?

  mutating func reset() { lastPTS = nil; expectedPTS = nil }

  func overlapsExpectedTime(_ packet: CaptureAudioPacket) -> Bool {
    guard let expectedPTS else { return false }
    return (expectedPTS - packet.packetTime).seconds > 1 / packet.format.sampleRate
  }

  mutating func ingest(_ packet: CaptureAudioPacket) -> Transition {
    defer {
      lastPTS = packet.packetTime
      expectedPTS = CMTimeAdd(packet.packetTime,
        CMTime(seconds: Double(packet.sampleFrameCount) / packet.format.sampleRate, preferredTimescale: 1_000_000_000))
    }
    guard let lastPTS, let expectedPTS else { return .continuous }
    let delta = CMTimeSubtract(packet.packetTime, expectedPTS).seconds
    if packet.packetTime <= lastPTS || delta < -0.02 { return .reset }
    return delta > 0.02 ? .gap : .continuous
  }
}
