import Foundation
import CoreMedia
import CoreVideo

/// Temporary native boundary until the vendor target move. Delivery uses a
/// recursive lock across the complete native callback, including audio-only
/// callbacks. Events from control/discovery threads acquire the same lock.
final class DeckLinkCaptureSession: CaptureSession, @unchecked Sendable {
  private let backend = DeckLinkBackend()
  private let control = DispatchQueue(label: "Ultracam.DeckLinkCapture.control")
  private let delivery = NSRecursiveLock()
  private enum State { case fresh, running, failed, stopped }
  private var state: State = .fresh // control queue only
  private struct NativeCleanup: @unchecked Sendable { let backend: DeckLinkBackend }
  deinit { let cleanup = NativeCleanup(backend: backend); control.async { cleanup.backend.stop() } }
  private var deviceID: String?
  private var timing: CaptureTiming?
  private var accepting = false // delivery lock
  private var handlers: CaptureHandlers?
  private var epoch = CaptureEpochID(sessionID: UUID(), epoch: 0)
  private static func pairedBindings() -> CaptureClockBindings {
    // Callback pairing is a recording alignment policy, not proof that the
    // SDK packet clock and video stream clock share an origin. Keep distinct
    // identities until an independently measured mapping is available.
    CaptureClockBindings(video: ClockInstanceID(), audio: ClockInstanceID())
  }
  private var bindings = DeckLinkCaptureSession.pairedBindings()
  private var sequence: UInt64 = 0
  private var format: SourceFormat?
  private var admission: SourceAdmissionSnapshot?
  private var pairedFrame: UInt64?
  private var lastFrameTime: CMTime?
  private var frameTimecode: Timecode?
  private var failures: UInt64 = 0
  private let callbackKey = "Ultracam.DeckLinkCapture.callback.\(UUID())"
  static let audioFormat = try! SourceAudioFormat(sampleRate: 48_000, channels: 2, sample: .int32,
    interleaved: true, layout: AudioChannelMap(), clock: .pairedWithFrames)
  private var sessionAudioFormat = DeckLinkCaptureSession.audioFormat
  private var sessionAudioDeclaration: SourceAudioDeclaration = .unknown
  private func sourceClockDiscontinuous(at time: CMTime) -> Bool {
    guard let lastFrameTime else { return false }
    return time < lastFrameTime || CMTimeCompare(CMTimeSubtract(time, lastFrameTime),
      CMTime(value: UCDeckLinkMaximumSourceGapSeconds, timescale: 1)) > 0
  }

  static func expectedFormat(fast: Bool) -> SourceFormat {
    DeckLinkCapturePlugin.modeCatalog[fast ? 1 : 0]
  }
  var counters: CaptureCounters {
    delivery.lock(); defer { delivery.unlock() }
    return CaptureCounters(deviceDroppedFrames: backend.deviceDroppedFrames, conversionFailures: failures,
      currentBacklog: Int(backend.availableFrameBacklog), maximumBacklog: Int(backend.maximumFrameBacklog))
  }
  func start(deviceID: String, timing: CaptureTiming, handlers: CaptureHandlers) throws {
    try control.sync {
      if state == .running {
        guard self.deviceID == deviceID, self.timing == timing else { throw PluginError.invalidState("Session already running with another configuration") }
        return
      }
      guard state == .fresh else { throw PluginError.invalidState("Create a new capture session after stop or failure") }
      var fast = false
      if case .fixed(let requested) = timing {
        guard requested.scan == .progressive, requested.pixel == .v210, !requested.rate.isVariable else { throw PluginError.unsupported("DeckLink requires a progressive v210 constant-rate mode") }
        backend.setRequestedFormat(width: requested.width, height: requested.height, duration: requested.rate.nominal)
        fast = requested == Self.expectedFormat(fast: true)
      }
      self.deviceID = deviceID; self.timing = timing
      installHandlers(handlers)
      backend.setCallbackGroupHandlers(begin: { [weak self] in self?.beginGroup() }, end: { [weak self] in self?.endGroup() })
      backend.setCallbackTimecodeHandler { [weak self] in self?.receiveTimecode($0) }
      backend.setCPUMemoryFrameHandler { [weak self] frame, pts, duration in
        self?.receiveOwnedMemory(frame, pts, duration)
      }
      backend.setAudioFormatHandler { [weak self] channels in
        guard let self else { return }
        self.delivery.lock(); defer { self.delivery.unlock() }
        if channels > 0, let format = try? SourceAudioFormat(sampleRate: 48_000, channels: channels, sample: .int32,
          interleaved: true, layout: AudioChannelMap(), clock: .pairedWithFrames) {
          self.sessionAudioFormat = format; self.sessionAudioDeclaration = .present(format)
        } else { self.sessionAudioDeclaration = .absent }
        self.emit(.event(.audioFormatChanged(self.sessionAudioDeclaration)))
      }
      let media: UltracamMediaStatsHandler = { [weak self] tc, pts, frames, channels, lp, rp, lr, rr, bytes, present in
        self?.receiveMedia(tc, pts, Int(frames), Int(channels), Double(lp), Double(rp), Double(lr), Double(rr), Int(bytes), present)
      }
      let audio: UltracamRawAudioHandler = { [weak self] data, pts, frames, channels, bytes in
        self?.receiveAudio(data, pts, Int(frames), Int(channels), Int(bytes))
      }
      do {
        switch timing {
        case .automatic:
          try backend.startAuto(deviceID: deviceID, frameHandler: { [weak self] buffer, pts, duration, valid in
            self?.receiveFrame(buffer, pts, duration, valid)
          }, mediaHandler: media, rawAudioHandler: audio, eventHandler: { [weak self] in self?.receiveEvent($0) })
        case .fixed(let requested):
          let duration = requested.rate.nominal
          try backend.start(deviceID: deviceID, inputFast: fast, frameHandler: { [weak self] buffer, pts, valid in
            self?.receiveFrame(buffer, pts, duration, valid)
          }, mediaHandler: media, rawAudioHandler: audio, eventHandler: { [weak self] in self?.receiveEvent($0) })
        }
        state = .running
      } catch {
        delivery.lock(); accepting = false; delivery.unlock()
        backend.stop()
        delivery.lock(); self.handlers = nil; delivery.unlock()
        state = .failed
        throw error
      }
    }
  }
  private func installHandlers(_ handlers: CaptureHandlers) {
    delivery.lock(); defer { delivery.unlock() }
    self.handlers = handlers; accepting = true
    emit(.event(.audioFormatChanged(.unknown)))
  }
  #if CAPTURE_LIFECYCLE_TESTS
  // Hardware-free injection uses the production admission, group and frame
  // handlers. It neither reads nor changes pixel storage.
  func startFixture(handlers: CaptureHandlers) {
    control.sync {
      installHandlers(handlers)
      delivery.lock(); sessionAudioDeclaration = .present(sessionAudioFormat)
      emit(.event(.audioFormatChanged(sessionAudioDeclaration))); delivery.unlock()
      state = .running
    }
  }
  func deliverFixtureFrame(_ buffer: CVPixelBuffer, at time: CMTime, timecode: String? = nil) {
    beginGroup(); defer { endGroup() }
    receiveTimecode(timecode)
    receiveFrame(buffer, time, VideoContract.slowDuration, true)
  }
  func deliverFixtureGroup(_ buffer: CVPixelBuffer, videoTime: CMTime, audioTime: CMTime, samples: Data) {
    beginGroup(); defer { endGroup() }
    receiveFrame(buffer, videoTime, VideoContract.slowDuration, true)
    receiveMedia(nil, audioTime, 2, 2, 0, 0, 0, 0, samples.count, true)
    receiveAudio(samples, audioTime, 2, 2, 4)
  }
  func deliverFixtureMediaWithoutAudio(_ buffer: CVPixelBuffer, at time: CMTime) {
    beginGroup(); defer { endGroup() }
    receiveFrame(buffer, time, VideoContract.slowDuration, true)
    receiveMedia(nil, .invalid, 0, 0, 0, 0, 0, 0, 0, false)
  }
  func deliverOwnedFixture(_ owner: UCDeckLinkOwnedMemoryFrame, at time: CMTime) {
    beginGroup(); defer { endGroup() }
    receiveOwnedMemory(owner, time, VideoContract.slowDuration)
  }
  #endif
  func stop() {
    precondition(Thread.current.threadDictionary[callbackKey] == nil, "Never stop synchronously from capture delivery")
    control.sync {
      delivery.lock(); accepting = false; delivery.unlock()
      backend.stop()
      delivery.lock(); handlers = nil; delivery.unlock()
      state = .stopped
    }
  }
  private func beginGroup() {
    delivery.lock()
    Thread.current.threadDictionary[callbackKey] = self
    pairedFrame = nil
    frameTimecode = nil
  }
  private func receiveTimecode(_ value: String?) { frameTimecode = Self.timecode(value) }
  private func endGroup() {
    pairedFrame = nil
    Thread.current.threadDictionary.removeObject(forKey: callbackKey)
    delivery.unlock()
  }
  private func emit(_ payload: CaptureDelivery.Payload) {
    guard accepting else { return }
    sequence += 1
    let prior = Thread.current.threadDictionary[callbackKey]
    Thread.current.threadDictionary[callbackKey] = self
    defer { Thread.current.threadDictionary[callbackKey] = prior }
    handlers?.deliver(CaptureDelivery(sequence: sequence, epochID: epoch, formatSignature: format?.signature ?? "",
      clockBindings: bindings, mappingRevision: 0, payload: payload))
  }
  private func receiveFrame(_ buffer: CVPixelBuffer, _ pts: CMTime, _ duration: CMTime, _ valid: Bool) {
    guard accepting else { return }
    do {
      let fields = CVBufferCopyAttachment(buffer, kCVImageBufferFieldCountKey, nil) as? NSNumber
      let fieldDetail = CVBufferCopyAttachment(buffer, kCVImageBufferFieldDetailKey, nil)
      let scan: Scan = fields?.intValue == 2 || fieldDetail != nil ? .interlaced : .progressive
      if let fields, fields.doubleValue != 1 && fields.doubleValue != 2 { throw PluginError.unsupported("Invalid DeckLink field count") }
      let next = try SourceFormat(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
        pixelAspect: Self.pixelAspect(buffer), scan: scan, pixel: PixelFormatID(rawValue: CVPixelBufferGetPixelFormatType(buffer)),
        colour: Self.colour(buffer), rate: .constant(duration))
      let clockReset = sourceClockDiscontinuous(at: pts)
      let formatChanged = next != format
      let boundary = clockReset || (formatChanged && format != nil)
      let nextEpoch = boundary ? CaptureEpochID(sessionID: epoch.sessionID, epoch: epoch.epoch + 1) : epoch
      let nextBindings = boundary ? Self.pairedBindings() : bindings
      let snapshot: SourceAdmissionSnapshot
      if !formatChanged, !clockReset, let admission { snapshot = admission }
      else { snapshot = try SourceAdmissionSnapshot(format: next, epochID: nextEpoch, clockBindings: nextBindings, stage: .capture) }
      try snapshot.validate(SourceAdmissionMetadata(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
        pixel: PixelFormatID(rawValue: CVPixelBufferGetPixelFormatType(buffer)), isPlanar: CVPixelBufferIsPlanar(buffer),
        planeCount: CVPixelBufferGetPlaneCount(buffer), rowBytes: CVPixelBufferGetBytesPerRow(buffer),
        dataSize: CVPixelBufferGetDataSize(buffer), presentationTime: pts, duration: duration,
        epochID: nextEpoch, formatSignature: next.signature), stage: .capture)
      epoch = nextEpoch; bindings = nextBindings; admission = snapshot
      if boundary {
        emit(.event(.discontinuity))
      }
      if formatChanged || clockReset {
        format = next
        emit(.event(.formatChanged(next)))
        emit(.event(.audioFormatChanged(sessionAudioDeclaration)))
      }
      let info = CaptureFrameInfo(epochID: epoch, formatSignature: next.signature, presentationTime: pts,
        duration: duration, signalValid: valid, timecode: frameTimecode, hostTimeReference: .presentationEnd,
        captureHostTime: Self.captureHostTime(CVBufferCopyAttachment(buffer, UltracamCaptureHostTimeAttachmentKey as CFString, nil) as? NSNumber))
      try info.validate()
      lastFrameTime = pts
      pairedFrame = sequence + 1
      emit(.frame(CapturedPixelBuffer(immutable: buffer), info))
    } catch { failures += 1; emit(.event(.fatal(error.localizedDescription))) }
  }
  private func receiveMedia(_ tc: String?, _ pts: CMTime, _ frames: Int, _ channels: Int,
    _ lp: Double, _ rp: Double, _ lr: Double, _ rr: Double, _ bytes: Int, _ present: Bool) {
    guard accepting else { return }
    emit(.media(CaptureMediaInfo(timecode: Self.timecode(tc), pairedFrameSequence: pairedFrame,
      audioDeclaration: sessionAudioDeclaration,
      audioPacketTime: present ? pts : nil, audioClockInstance: present ? bindings.audio : nil,
      sampleFrameCount: present ? frames : 0, byteCount: present ? bytes : 0,
      peaks: present ? [lp, rp] : [0, 0], rms: present ? [lr, rr] : [0, 0])))
  }
  private func receiveOwnedMemory(_ owner: UCDeckLinkOwnedMemoryFrame, _ pts: CMTime, _ duration: CMTime) {
    guard accepting else { return }
    do {
      let rgb = owner.pixelFormat == 0x72323130 || owner.pixelFormat == 0x5231324c
      guard rgb else { throw PluginError.unsupported("Unexpected owned SDK pixel format") }
      guard let allocationLength = Int(exactly: owner.allocationLength) else { throw PluginError.unsupported("Owned allocation length overflows") }
      let colour = Colorimetry(
        primaries: owner.colorPrimaries == kCVImageBufferColorPrimaries_ITU_R_709_2 as String ? .rec709 :
          owner.colorPrimaries == kCVImageBufferColorPrimaries_ITU_R_2020 as String ? .rec2020 : .unspecified,
        transfer: owner.transferFunction == kCVImageBufferTransferFunction_ITU_R_709_2 as String ? .rec709 :
          owner.transferFunction == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String ? .pq :
          owner.transferFunction == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String ? .hlg : .unspecified,
        matrix: .identity, range: owner.fullRange ? .full : .video,
        horizontalChromaSiting: .unspecified, verticalChromaSiting: .unspecified)
      let next = try SourceFormat(width: owner.width, height: owner.height,
        pixel: PixelFormatID(rawValue: owner.pixelFormat), colour: colour, rate: .constant(duration))
      let boundary = sourceClockDiscontinuous(at: pts) || (format != nil && format != next)
      let nextEpoch = boundary ? CaptureEpochID(sessionID: epoch.sessionID, epoch: epoch.epoch + 1) : epoch
      let nextBindings = boundary ? Self.pairedBindings() : bindings
      let snapshot = try SourceAdmissionSnapshot(format: next, epochID: nextEpoch, clockBindings: nextBindings, stage: .capture)
      try snapshot.validate(SourceAdmissionMetadata(width: owner.width, height: owner.height,
        pixel: PixelFormatID(rawValue: owner.pixelFormat), isPlanar: false, planeCount: 0,
        rowBytes: owner.rowBytes, dataSize: allocationLength, presentationTime: pts, duration: duration,
        epochID: nextEpoch, formatSignature: next.signature), stage: .capture)
      let memory = try Self.ownedMemoryFrame(owner)
      epoch = nextEpoch; bindings = nextBindings; admission = snapshot
      if boundary { emit(.event(.discontinuity)) }
      if format != next || boundary {
        format = next; emit(.event(.formatChanged(next))); emit(.event(.audioFormatChanged(sessionAudioDeclaration)))
      }
      let info = CaptureFrameInfo(epochID: epoch, formatSignature: next.signature, presentationTime: pts,
        duration: duration, signalValid: true, timecode: frameTimecode, hostTimeReference: .presentationEnd,
        captureHostTime: Self.captureHostTime(owner.captureHostTimeSeconds))
      try info.validate()
      lastFrameTime = pts; pairedFrame = sequence + 1
      emit(.cpuMemory(memory, info))
    } catch { failures += 1; emit(.event(.fatal(error.localizedDescription))) }
  }
  static func ownedMemoryFrame(_ owner: UCDeckLinkOwnedMemoryFrame) throws -> CapturedCPUMemoryFrame {
    guard let allocationLength = Int(exactly: owner.allocationLength) else { throw PluginError.unsupported("Owned allocation length overflows") }
    let allocation = NoCopyIngestAllocation(baseAddress: owner.pointer, length: allocationLength,
      generation: owner.generation, release: { withExtendedLifetime(owner) {} })
    let base = UInt(bitPattern: owner.pointer), length = allocationLength, generation = owner.generation
    let memory = CapturedCPUMemoryFrame(pointer: owner.pointer, width: owner.width, height: owner.height,
      bytesPerRow: owner.rowBytes, allocation: allocation, inspectVM: { roundedBase, roundedLength in
        let offset = roundedBase.subtractingReportingOverflow(base)
        guard !offset.overflow, offset.partialValue <= UInt(length), roundedLength > 0,
          UInt(roundedLength) <= UInt(length) - offset.partialValue else { return nil }
        // Exact caller-owned mmap extent, not an inferred driver VM region.
        return NoCopyVMRange(baseAddress: roundedBase, length: roundedLength, generation: generation)
      }, frameOwner: owner, pixelFormat: owner.pixelFormat)
    _ = try memory.validatedCPUReadableLength()
    return memory
  }
  private static func captureHostTime(_ value: NSNumber?) -> CMTime? {
    guard let seconds = value?.doubleValue, seconds.isFinite, seconds > 0 else { return nil }
    return CMTime(seconds: seconds, preferredTimescale: 1_000_000_000)
  }
  private func receiveAudio(_ data: Data?, _ pts: CMTime, _ frames: Int, _ channels: Int, _ bytes: Int) {
    guard accepting, let data else { return }
    do {
      guard channels == sessionAudioFormat.channels, bytes == 4 else { throw PluginError.unsupported("Unexpected DeckLink PCM layout") }
      emit(.rawAudio(try CaptureAudioPacket(planes: [data], sampleFrameCount: frames, format: sessionAudioFormat,
        packetTime: pts, pairedFrameSequence: pairedFrame)))
    } catch { failures += 1; emit(.event(.fatal(error.localizedDescription))) }
  }
  private func receiveEvent(_ text: String) {
    delivery.lock(); defer { delivery.unlock() }
    let prior = Thread.current.threadDictionary[callbackKey]
    Thread.current.threadDictionary[callbackKey] = self
    defer { Thread.current.threadDictionary[callbackKey] = prior }
    emit(.event(Self.event(text)))
  }
  static func event(_ text: String) -> CaptureEvent {
    let lower = text.lowercased()
    if text.hasPrefix("Capture error: ") { return .fatal(String(text.dropFirst(15))) }
    if lower.contains("unsupported") { return .unsupportedInput(text) }
    if lower.contains("no hdmi video signal") || lower.contains("no video signal") { return .signalLost(reason: text) }
    if lower.contains("waiting") { return .waitingForSignal }
    return .info(text)
  }
  static func timecode(_ text: String?) -> Timecode? {
    guard let text else { return nil }
    let labels = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == ":" || $0 == ";" })
    let parts = labels.compactMap { Int($0) }
    guard labels.count == 4, parts.count == 4 else { return nil }
    return try? Timecode(hours: parts[0], minutes: parts[1], seconds: parts[2], frames: parts[3], dropFrame: text.contains(";"))
  }
  private static func pixelAspect(_ buffer: CVPixelBuffer) throws -> Rational {
    guard let attachment = CVBufferCopyAttachment(buffer, kCVImageBufferPixelAspectRatioKey, nil) else { return .one }
    guard let values = attachment as? [String: NSNumber],
      let horizontal = values[kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String],
      let vertical = values[kCVImageBufferPixelAspectRatioVerticalSpacingKey as String],
      horizontal.int64Value > 0, vertical.int64Value > 0,
      horizontal.doubleValue.isFinite, vertical.doubleValue.isFinite,
      horizontal.doubleValue == Double(horizontal.int64Value), vertical.doubleValue == Double(vertical.int64Value)
      else { throw PluginError.unsupported("Invalid DeckLink pixel aspect ratio") }
    return try Rational(horizontal.int64Value, vertical.int64Value)
  }
  private static func colour(_ buffer: CVPixelBuffer) -> Colorimetry {
    func tag(_ key: CFString) -> String? { CVBufferCopyAttachment(buffer, key, nil) as? String }
    let p = tag(kCVImageBufferColorPrimariesKey), t = tag(kCVImageBufferTransferFunctionKey), m = tag(kCVImageBufferYCbCrMatrixKey)
    let pixel = CVPixelBufferGetPixelFormatType(buffer)
    let rgb = pixel == 0x72323130 || pixel == 0x5231324c
    return Colorimetry(primaries: p == kCVImageBufferColorPrimaries_ITU_R_2020 as String ? .rec2020 : p == kCVImageBufferColorPrimaries_ITU_R_709_2 as String ? .rec709 : .unspecified,
      transfer: t == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String ? .pq : t == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String ? .hlg : t == kCVImageBufferTransferFunction_ITU_R_709_2 as String ? .rec709 : .unspecified,
      matrix: rgb ? .identity : m == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String ? .rec2020 : m == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String ? .rec709 : .unspecified,
      range: pixel == 0x5231324c ? .full : .video, horizontalChromaSiting: rgb ? .unspecified : .left, verticalChromaSiting: rgb ? .unspecified : .center)
  }
}

struct DeckLinkCapturePlugin: CaptureSourcePlugin {
  static let localizationTable = "BlackmagicCapture"
  static let connectorSettingID = "decklink:inputConnector"
  static let connectors: [(id: String, bit: UInt32, label: String, connector: Connector)] = [
    ("hdmi", 2, "HDMI", .hdmi), ("sdi", 1, "SDI", .sdi), ("optical", 4, "Optical SDI", .optical),
  ]
  static func connectorSetting(mask: UInt32, selected: UInt32) throws -> VendorSetting {
    let choices = connectors.filter { mask & $0.bit != 0 }
    guard !choices.isEmpty, let current = connectors.first(where: { $0.bit == selected }) else { throw PluginError.unsupported("Selected capture connector is unsupported") }
    return VendorSetting(id: connectorSettingID, labelKey: "decklink.setting.inputConnector", value: .choice(current.id),
      allowedValues: .choices(choices.map { .init(id: $0.id, label: $0.label,
        labelKey: "decklink.connector.\($0.id)", localizationTable: localizationTable) }), mutable: true,
      availabilityReason: nil, interruptsCapture: true,
      applicationError: mask & selected == 0 ? .unsupported("Saved input connector is not supported by this device") : nil,
      labelFallback: "Input connector", localizationTable: localizationTable)
  }
  /// Legacy defaults for the old inputFast API. Actual device capabilities
  /// come from the SDK catalog below, never from these defaults.
  static let modeCatalog: [SourceFormat] = [
    try! SourceFormat(width: 3840, height: 2160, pixel: .v210, rate: .constant(VideoContract.slowDuration)),
    try! SourceFormat(width: 3840, height: 2160, pixel: .v210, rate: .constant(VideoContract.fastDuration)),
  ]
  static func activeFormat(width: Int, height: Int, duration: CMTime) throws -> SourceFormat {
    guard width > 0, height > 0, width <= 16384, height <= 16384,
      duration.isNumeric, duration > .zero, duration.epoch == 0,
      duration.seconds >= 1.0 / 120, duration.seconds <= 1.0 / 23 else { throw PluginError.unsupported("Invalid HDMI mode dimensions or cadence") }
    return try SourceFormat(width: width, height: height, pixel: .v210, rate: .constant(duration))
  }
  static func modeCatalog(deviceID: String) throws -> [SourceFormat] {
    guard let device = try DeckLinkBackend.devices().first(where: { $0.identifier == deviceID }) else {
      throw PluginError.unavailable("DeckLink device is unavailable")
    }
    return try device.modes.map { try activeFormat(width: $0.width, height: $0.height, duration: $0.frameDuration) }
  }
  static let hdrSettingID = "decklink:advertiseHDRToCameras"
  static func hdrSetting(enabled: Bool, applicationError: PluginError? = nil) -> VendorSetting {
    VendorSetting(id: hdrSettingID, labelKey: "decklink.setting.advertiseHDRToCameras", value: .boolean(enabled),
      allowedValues: .unrestricted, mutable: true, availabilityReason: nil, interruptsCapture: true,
      applicationError: applicationError, labelFallback: "Advertise HDR to cameras", localizationTable: localizationTable)
  }
  func configureSettings(_ policy: VendorSettingsPolicy) throws {
    guard policy.version == 1 else { throw PluginError.unsupported("Unsupported vendor settings policy version") }
    func boolean(_ value: VendorSettingValue) throws -> Bool {
      guard case .boolean(let enabled) = value else { throw PluginError.unsupported("HDR advertisement requires a Boolean value") }
      return enabled
    }
    // Validate the complete policy before performing any hardware operation.
    let inherited = try policy.inheritedByPlugin[descriptor.id]?[Self.hdrSettingID].map(boolean)
    var devices: [String: Bool] = [:]
    var inputConnectors: [String: NSNumber] = [:]
    for (deviceID, settings) in policy.desiredByDevice where deviceID.hasPrefix("decklink:") {
      if let value = settings[Self.hdrSettingID] { devices[deviceID] = try boolean(value) }
      if let value = settings[Self.connectorSettingID] {
        guard case .choice(let id) = value, let connector = Self.connectors.first(where: { $0.id == id }) else {
          throw PluginError.unsupported("Invalid input connector choice")
        }
        inputConnectors[deviceID] = NSNumber(value: connector.bit)
      }
    }
    DeckLinkBackend.seedInputConnectors(inputConnectors)
    Self.seedHDRAdvertisements(devices)
    if let inherited { Self.setAdvertisesHDR(inherited) }
  }
  var descriptor: VendorDescriptor {
    return VendorDescriptor(id: "decklink", displayName: "Blackmagic DeckLink", badgeText: "DECKLINK",
      signalHint: "HDMI / SDI / optical", sdkVersion: DeckLinkBackend.sdkVersion(), sdkPresent: true, badgeAssetName: "BlackmagicLogo",
      displayNameKey: "decklink.descriptor.name", signalHintKey: "decklink.descriptor.signal", localizationTable: Self.localizationTable)
  }
  func driverStatus() -> DriverStatus {
    let info = DeckLinkBackend.driverInfo()
    return DriverStatus(installed: info.installed, supported: info.supported, version: info.version, reason: info.message)
  }
  private static func device(_ value: UltracamDevice) -> CaptureDeviceInfo {
    CaptureDeviceInfo(id: value.identifier, name: value.name, connectors: connectors.filter { value.videoInputConnections & $0.bit != 0 }.map(\.connector), shareable: false,
      mayPause: nil, supportedModes: value.modes.map { "\($0.width) × \($0.height), \($0.frameDuration.value)/\($0.frameDuration.timescale) s" }.joined(separator: "; "))
  }
  func devices() throws -> [CaptureDeviceInfo] { try DeckLinkBackend.devices().map(Self.device) }
  @MainActor func observeDevices(_ handler: @escaping @MainActor @Sendable (CaptureDeviceSnapshot) -> Void) -> DeviceObservation {
    let observation = DeviceObservation(handler)
    let token = DeckLinkBackend.addDeviceListObserver { values in
      observation.deliver(CaptureDeviceSnapshot(status: driverStatus(), devices: values.map(Self.device), error: nil))
    }
    observation.onCancel { DeckLinkBackend.removeDeviceListObserver(token) }
    return observation
  }
  func expectedFormat(deviceID: String, timing: CaptureTiming) -> SourceFormat? {
    if case .fixed(let format) = timing, let device = try? DeckLinkBackend.devices().first(where: { $0.identifier == deviceID }),
      device.modes.contains(where: { $0.width == format.width && $0.height == format.height && $0.frameDuration == format.rate.nominal }),
      format.scan == .progressive, format.pixel == .v210 { return format }
    return nil
  }
  func makeSession() -> any CaptureSession { DeckLinkCaptureSession() }
  func diagnostics(deviceID: String) -> DeviceDiagnostics? {
    guard let value = DeckLinkBackend.diagnostics(deviceID: deviceID) else { return nil }
    return Self.translateDiagnostics(value)
  }
  static func setAdvertisesHDR(_ enabled: Bool) { DeckLinkBackend.setAdvertisesHDR(enabled) }
  static func seedHDRAdvertisements(_ values: [String: Bool]) {
    DeckLinkBackend.seedHDRAdvertisements(values.mapValues { NSNumber(value: $0) })
  }
  static func translateDiagnostics(_ value: UltracamDeviceDiagnostics) -> DeviceDiagnostics {
    func yes(_ value: Bool) -> String { value ? "Yes" : "No" }
    return DeviceDiagnostics(counters: CaptureCounters(deviceDroppedFrames: value.deviceDroppedFrames,
      currentBacklog: Int(value.frameBacklog), maximumBacklog: Int(value.maximumFrameBacklog)),
      temperatureCelsius: value.temperatureCelsius == NSNotFound ? nil : Double(value.temperatureCelsius),
      signalPresent: value.signalPresent?.boolValue, hostTimeMapped: value.hostTimeMapped,
      vendorFields: [
        .init(label: "Device identifier", value: value.identifier),
        .init(label: "Device name", value: value.name),
        .init(label: "Driver version", value: value.driverVersion),
        .init(label: "Maximum HDMI audio channels", value: String(value.maximumHDMIAudioChannels)),
        .init(label: "Captured audio channels", value: String(value.capturedAudioChannels)),
        .init(label: "Format detection", value: yes(value.supportsFormatDetection)),
        .init(label: "HDR metadata", value: yes(value.supportsHDRMetadata)),
        .init(label: "Colorspace metadata", value: yes(value.supportsColorspaceMetadata)),
        .init(label: "HDMI timecode", value: yes(value.supportsHDMITimecode)),
        .init(label: "High frame rate timecode", value: yes(value.supportsHighFrameRateTimecode)),
        .init(label: "Session active", value: yes(value.sessionActive)),
        .init(label: "Signal", value: value.signal ?? "Unknown"),
        .init(label: "HDMI dynamic range", value: value.hdmiDynamicRange),
      ])
  }
  func settings(deviceID: String) async throws -> [VendorSetting] {
    do {
      guard let device = try DeckLinkBackend.devices().first(where: { $0.identifier == deviceID }) else { throw PluginError.unavailable("DeckLink device is unavailable") }
      let state = try DeckLinkBackend.inputConnectorState(deviceID: deviceID)
      let selected = state.connection
      var connector = try Self.connectorSetting(mask: device.videoInputConnections, selected: selected)
      connector.applicationError = state.applicationError.map(Self.settingError)
      if selected != 2 { return [connector] }
      let hdr = try DeckLinkBackend.hdrAdvertisementState(deviceID: deviceID)
      return [connector, Self.hdrSetting(enabled: hdr.enabled, applicationError: hdr.applicationError.map(Self.settingError))]
    }
    catch { throw Self.settingError(error) }
  }
  func apply(_ value: VendorSettingValue, to setting: VendorSetting.ID, deviceID: String) async throws {
    if setting == Self.connectorSettingID {
      guard case .choice(let id) = value, let connector = Self.connectors.first(where: { $0.id == id }) else { throw PluginError.unsupported("Invalid input connector choice") }
      do { try DeckLinkBackend.setInputConnector(connector.bit, deviceID: deviceID) }
      catch { throw Self.settingError(error) }
      return
    }
    guard setting == Self.hdrSettingID, case .boolean(let enabled) = value else {
      throw PluginError.unsupported("Unsupported DeckLink setting or value")
    }
    do { try DeckLinkBackend.setHDRAdvertisement(enabled, deviceID: deviceID) }
    catch { throw Self.settingError(error) }
  }
  private static func settingError(_ error: Error) -> PluginError {
    if let plugin = error as? PluginError { return plugin }
    let native = error as NSError
    guard native.domain == "UCDeckLinkSettings" else { return .failed(native.localizedDescription) }
    switch native.code {
    case 1: return .unavailable(native.localizedDescription)
    case 2: return .unsupported(native.localizedDescription)
    case 3: return .busy(native.localizedDescription)
    default: return .failed(native.localizedDescription)
    }
  }
}
