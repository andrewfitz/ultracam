import Foundation
import XCTest
import CoreMedia
import CoreVideo

@objcMembers final class DeckLinkAdapterContractChecks: XCTestCase {
  func testNativeAuditHostTimeConnectorReadbackAndSignalPresence() {
    var error: NSError?
    XCTAssertTrue(UltracamRunNativeAuditSyntheticChecks(&error), error?.localizedDescription ?? "Native audit regression failed")
  }
  func testBlackmagicDescriptorUsesNamedLocalizationTableAndLiteralFallback() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try #""decklink.descriptor.name" = "Localized capture"; "decklink.descriptor.signal" = "Localized connectors";"#.write(
      to: root.appendingPathComponent("BlackmagicCapture.strings"), atomically: true, encoding: .utf8)
    let bundle = try XCTUnwrap(Bundle(path: root.path))
    let descriptor = DeckLinkCapturePlugin().descriptor
    XCTAssertEqual(descriptor.localizedDisplayName(in: bundle), "Localized capture")
    XCTAssertEqual(descriptor.localizedSignalHint(in: bundle), "Localized connectors")
    XCTAssertEqual(descriptor.localizedDisplayName(in: Bundle(for: Self.self)), "Blackmagic DeckLink")
  }
  func testBlackmagicSettingsAndOptionsResolveStableKeysWithFallbacks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try #""decklink.setting.inputConnector" = "Localized input"; "decklink.setting.advertiseHDRToCameras" = "Localized HDR"; "decklink.connector.optical" = "Localized optical";"#.write(
      to: root.appendingPathComponent("BlackmagicCapture.strings"), atomically: true, encoding: .utf8)
    let bundle = try XCTUnwrap(Bundle(path: root.path))
    let setting = try DeckLinkCapturePlugin.connectorSetting(mask: 7, selected: 4)
    XCTAssertEqual(setting.localizedLabel(in: bundle), "Localized input")
    XCTAssertEqual(DeckLinkCapturePlugin.hdrSetting(enabled: false).localizedLabel(in: bundle), "Localized HDR")
    guard case .choices(let choices) = setting.allowedValues else { return XCTFail("Missing connector choices") }
    XCTAssertEqual(choices.last?.localizedLabel(in: bundle), "Localized optical")
    XCTAssertEqual(setting.localizedLabel(in: Bundle(for: Self.self)), "Input connector")
    XCTAssertEqual(choices.last?.localizedLabel(in: Bundle(for: Self.self)), "Optical SDI")
  }
  func testConnectorSettingContainsOnlyAdvertisedChoices() throws {
    let setting = try DeckLinkCapturePlugin.connectorSetting(mask: 1 | 4, selected: 4)
    XCTAssertEqual(setting.value, .choice("optical"))
    XCTAssertTrue(setting.interruptsCapture)
    guard case .choices(let choices) = setting.allowedValues else { return XCTFail("Expected connector choices") }
    XCTAssertEqual(choices.map(\.id), ["sdi", "optical"])
    let unsupportedSaved = try DeckLinkCapturePlugin.connectorSetting(mask: 2, selected: 1)
    XCTAssertNotNil(unsupportedSaved.applicationError)
    XCTAssertTrue(unsupportedSaved.mutable)
    XCTAssertThrowsError(try DeckLinkCapturePlugin.connectorSetting(mask: 0, selected: 1))
  }
  func testConnectorCapabilityIsolationSelectionAndLeaseRestore() {
    var error: NSError?
    XCTAssertTrue(UltracamRunConnectorSyntheticChecks(&error), error?.localizedDescription ?? "Connector policy failed")
  }
  func testNativeGapPolicyUsesElapsedSecondsAcrossFrameRates() {
    var error: NSError?
    XCTAssertTrue(UltracamRunElapsedGapSyntheticChecks(&error), error?.localizedDescription ?? "Elapsed source gap policy failed")
  }
  func testLongForwardGapStartsNewEpochBeforeFrame() throws {
    let recorder = AdapterDeliveryRecorder(), session = DeckLinkCaptureSession()
    session.startFixture(handlers: CaptureHandlers(deliver: { recorder.append($0) }))
    defer { session.stop() }
    let buffer = try fixtureBuffer()
    session.deliverFixtureFrame(buffer, at: .zero)
    session.deliverFixtureFrame(buffer, at: CMTime(value: 12, timescale: 1))
    let frames = recorder.values.filter { if case .frame = $0.payload { true } else { false } }
    XCTAssertEqual(frames.count, 2)
    XCTAssertNotEqual(frames[0].epochID, frames[1].epochID)
    XCTAssertTrue(recorder.values.contains { if case .event(.discontinuity) = $0.payload { $0.epochID == frames[1].epochID } else { false } })
  }
  func testRawRGBUsesPhysicalColorMetadataAndColorChangesEpoch() throws {
    var error: NSError?
    XCTAssertTrue(UltracamRunOwnedColorSyntheticChecks(&error), error?.localizedDescription ?? "Owned color metadata failed")
    let recorder = AdapterDeliveryRecorder(), session = DeckLinkCaptureSession()
    session.startFixture(handlers: CaptureHandlers(deliver: { recorder.append($0) }))
    defer { session.stop() }
    session.deliverOwnedFixture(UltracamCreateOwnedRGBColorFixture(0x72373039, 0), at: .zero)
    session.deliverOwnedFixture(UltracamCreateOwnedRGBColorFixture(0x32303230, 2), at: VideoContract.slowDuration)
    session.deliverOwnedFixture(UltracamCreateOwnedRGBColorFixture(0x32303230, 3), at: CMTimeMultiply(VideoContract.slowDuration, multiplier: 2))
    let values = recorder.values
    let formats = values.compactMap { value -> (SourceFormat, CaptureEpochID)? in
      if case .event(.formatChanged(let format)) = value.payload { return (format, value.epochID) }; return nil
    }
    XCTAssertEqual(formats.count, 3)
    guard formats.count == 3 else { return }
    XCTAssertEqual(formats[0].0.colour.primaries, .rec709)
    XCTAssertEqual(formats[0].0.colour.transfer, .rec709)
    XCTAssertEqual(formats[1].0.colour.primaries, .rec2020)
    XCTAssertEqual(formats[1].0.colour.transfer, .pq)
    XCTAssertEqual(formats[1].0.colour.matrix, .identity)
    XCTAssertNotEqual(formats[0].1, formats[1].1)
    XCTAssertEqual(formats[2].0.colour.transfer, .hlg)
    XCTAssertNotEqual(formats[1].1, formats[2].1)
    XCTAssertTrue(formats.allSatisfy { $0.0.colour.range == .video && $0.0.colour.horizontalChromaSiting == .unspecified })
    let timestamps = values.compactMap { value -> CMTime? in
      if case .cpuMemory(_, let info) = value.payload { return info.captureHostTime }; return nil
    }
    XCTAssertEqual(timestamps.count, 3)
    XCTAssertTrue(timestamps.allSatisfy { $0 == CMTime(value: 47, timescale: 1) })
  }
  func testOwnedSDKAllocatorRetainsFramePastStopAndRejectsForeignMemory() {
    var error: NSError?
    XCTAssertTrue(UltracamRunOwnedAllocatorSyntheticChecks(&error), error?.localizedDescription ?? "Owned SDK allocator failed")
  }
  func testOwnedRGBMemoryBuildsBoundedNoCopyGPULease() throws {
    let sdk = UltracamCreateOwnedRGBFixture()
    let memory = try DeckLinkCaptureSession.ownedMemoryFrame(sdk)
    let lease = try memory.lease()
    XCTAssertEqual(memory.pixelFormat, PixelFormatID.r210.rawValue)
    XCTAssertEqual(lease.byteLength, 4096)
    XCTAssertEqual(lease.roundedBaseAddress, UInt(bitPattern: sdk.pointer))
    XCTAssertEqual(lease.roundedLength, Int(sdk.allocationLength))
    var completion: (() -> Void)?
    lease.submitGPU { completion = $0 }
    XCTAssertNotNil(completion)
    completion?()
  }
  func testMissingPCMPacketPreservesResolvedEpochAudioDeclaration() throws {
    let recorder = AdapterDeliveryRecorder(), session = DeckLinkCaptureSession()
    session.startFixture(handlers: CaptureHandlers(deliver: { recorder.append($0) }))
    defer { session.stop() }
    session.deliverFixtureMediaWithoutAudio(try fixtureBuffer(), at: .zero)
    guard let value = recorder.values.first(where: { if case .media = $0.payload { true } else { false } }),
      case .media(let media) = value.payload else { return XCTFail("Missing media delivery") }
    XCTAssertEqual(media.audioDeclaration, .present(DeckLinkCaptureSession.audioFormat))
    XCTAssertNil(media.audioPacketTime)
    XCTAssertNil(media.audioClockInstance)
    XCTAssertEqual(media.sampleFrameCount, 0)
    XCTAssertEqual(media.byteCount, 0)
    XCTAssertFalse(recorder.values.contains { if case .event(.audioFormatChanged(.absent)) = $0.payload { true } else { false } })
  }
  func testPairedPacketAndVideoOriginsRemainDistinctWithoutInventedMapping() throws {
    let recorder = AdapterDeliveryRecorder(), session = DeckLinkCaptureSession()
    session.startFixture(handlers: CaptureHandlers(deliver: { recorder.append($0) }))
    defer { session.stop() }
    session.deliverFixtureGroup(try fixtureBuffer(), videoTime: CMTime(value: 100, timescale: 1),
      audioTime: CMTime(value: 7, timescale: 1), samples: Data(repeating: 0, count: 16))
    let values = recorder.values
    guard let frame = values.first(where: { if case .frame = $0.payload { true } else { false } }),
      let media = values.first(where: { if case .media = $0.payload { true } else { false } }),
      let raw = values.first(where: { if case .rawAudio = $0.payload { true } else { false } }),
      case .media(let info) = media.payload, case .rawAudio(let packet) = raw.payload else { return XCTFail("Missing callback group") }
    XCTAssertNotEqual(frame.clockBindings.video, raw.clockBindings.audio)
    XCTAssertEqual(info.audioClockInstance, raw.clockBindings.audio)
    XCTAssertEqual(info.audioPacketTime, CMTime(value: 7, timescale: 1))
    XCTAssertEqual(packet.packetTime, CMTime(value: 7, timescale: 1))
    XCTAssertEqual(packet.pairedFrameSequence, frame.sequence)
    XCTAssertEqual(info.pairedFrameSequence, frame.sequence)
    XCTAssertEqual(packet.format.clock, .pairedWithFrames)
    XCTAssertFalse(values.contains { if case .event(.clockMappingChanged) = $0.payload { true } else { false } })
    XCTAssertTrue(values.allSatisfy { $0.mappingRevision == 0 })
  }
  func testDetectedPixelFormatIsNegotiatedWithoutPrecisionCoercion() {
    var error: NSError?
    XCTAssertTrue(UltracamRunPixelNegotiationSyntheticChecks(&error), error?.localizedDescription ?? "Detected pixel negotiation failed")
  }
  func testDescriptorReportsCompiledSDKVersion() {
    XCTAssertEqual(DeckLinkCapturePlugin().descriptor.sdkVersion, DeckLinkBackend.sdkVersion())
    XCTAssertEqual(DeckLinkBackend.sdkVersion(), "16.0.0")
  }
  func testSDKModeContractsCoverHDAndHighFrameRate() {
    var error: NSError?
    XCTAssertTrue(UltracamRunExpandedModeSyntheticChecks(&error), error?.localizedDescription ?? "Expanded SDK modes failed")
  }
  func testB2ModeCatalogIsImmutableExactAndCurrentOnly() throws {
    XCTAssertEqual(DeckLinkCapturePlugin.modeCatalog.count, 2)
    XCTAssertEqual(Set(DeckLinkCapturePlugin.modeCatalog.map { $0.width }), [3840])
    XCTAssertEqual(Set(DeckLinkCapturePlugin.modeCatalog.map { $0.height }), [2160])
    XCTAssertEqual(Set(DeckLinkCapturePlugin.modeCatalog.map { $0.pixel }), [.v210])
    XCTAssertEqual(Set(DeckLinkCapturePlugin.modeCatalog.map { $0.rate.nominal }), [VideoContract.slowDuration, VideoContract.fastDuration])
    XCTAssertEqual(try DeckLinkCapturePlugin.activeFormat(width: 1920, height: 1080, duration: VideoContract.slowDuration).width, 1920)
    XCTAssertEqual(try DeckLinkCapturePlugin.activeFormat(width: 3840, height: 2160, duration: CMTime(value: 1, timescale: 24)).rate.nominal, CMTime(value: 1, timescale: 24))
  }
  func testB2ActiveModePreservesCatalogMetadata() throws {
    for expected in DeckLinkCapturePlugin.modeCatalog {
      let active = try DeckLinkCapturePlugin.activeFormat(width: expected.width, height: expected.height, duration: expected.rate.nominal)
      XCTAssertEqual(active, expected)
      XCTAssertEqual(active.scan, .progressive)
      XCTAssertEqual(active.pixelAspect, .one)
    }
  }
  func testNativeDeclarationAndPackedBufferConsistency() {
    var error: NSError?
    XCTAssertTrue(UltracamRunFrameContractSyntheticChecks(&error), error?.localizedDescription ?? "Native frame declaration mismatch")
  }
  func testNativePackedWireBoundsMatchSharedPixelTable() throws {
    let entry = try XCTUnwrap(PixelFormatTable.entry(for: .v210))
    for width in [1, 6, 7, 1920, 3840] {
      XCTAssertEqual(UInt64(try SourceAdmissionSnapshot.minimumPackedRowBytes(entry: entry, width: width)),
        UltracamV210MinimumRowBytes(UInt64(width)))
    }
    XCTAssertEqual(UltracamV210MinimumRowBytes(UInt64.max), 0)
  }
  func testAdapterRefusesInterlacedFrameAttachmentsBeforePublication() throws {
    let recorder = AdapterDeliveryRecorder(), session = DeckLinkCaptureSession()
    session.startFixture(handlers: CaptureHandlers(deliver: { recorder.append($0) }))
    defer { session.stop() }
    let buffer = try fixtureBuffer()
    CVBufferSetAttachment(buffer, kCVImageBufferFieldCountKey, NSNumber(value: 2), .shouldPropagate)
    session.deliverFixtureFrame(buffer, at: .zero)
    XCTAssertFalse(recorder.values.contains { if case .frame = $0.payload { true } else { false } })
    XCTAssertEqual(session.counters.conversionFailures, 1)
  }
  func testAdapterRefusesNonSquareAndFractionalAspectMetadata() throws {
    for horizontal in [NSNumber(value: 2), NSNumber(value: 1.5)] {
      let recorder = AdapterDeliveryRecorder(), session = DeckLinkCaptureSession()
      session.startFixture(handlers: CaptureHandlers(deliver: { recorder.append($0) }))
      let buffer = try fixtureBuffer()
      let ratio = [kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String: horizontal,
        kCVImageBufferPixelAspectRatioVerticalSpacingKey as String: NSNumber(value: 1)]
      CVBufferSetAttachment(buffer, kCVImageBufferPixelAspectRatioKey, ratio as CFDictionary, .shouldPropagate)
      session.deliverFixtureFrame(buffer, at: .zero)
      XCTAssertEqual(recorder.values.contains { if case .frame = $0.payload { true } else { false } }, horizontal.doubleValue == 2)
      XCTAssertEqual(session.counters.conversionFailures, horizontal.doubleValue == 2 ? 0 : 1)
      session.stop()
    }
  }
  func testAdapterDeclaresExactFrameMetadataAndEndReferencedHostTime() throws {
    let recorder = AdapterDeliveryRecorder(), session = DeckLinkCaptureSession()
    session.startFixture(handlers: CaptureHandlers(deliver: { recorder.append($0) }))
    defer { session.stop() }
    let buffer = try fixtureBuffer()
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
    session.deliverFixtureFrame(buffer, at: .zero)
    let values = recorder.values
    guard let declaration = values.compactMap({ value -> SourceFormat? in
      if case .event(.formatChanged(let format)) = value.payload { return format }; return nil
    }).first, let frame = values.first(where: { if case .frame = $0.payload { true } else { false } }),
      case .frame(_, let info) = frame.payload else { return XCTFail("Missing ordered declaration and frame") }
    XCTAssertEqual(declaration.colour.primaries, .rec2020)
    XCTAssertEqual(declaration.colour.transfer, .hlg)
    XCTAssertEqual(declaration.colour.matrix, .rec2020)
    XCTAssertEqual(declaration.scan, .progressive)
    XCTAssertEqual(declaration.rate.nominal, info.duration)
    XCTAssertEqual(declaration.signature, frame.formatSignature)
    XCTAssertEqual(info.hostTimeReference, .presentationEnd)
  }
  func testWholeNativeCallbackGroupIncludingAudioOnlyAndEvents() {
    var error: NSError?
    XCTAssertTrue(UltracamRunCallbackGroupSyntheticChecks(&error), error?.localizedDescription ?? "Native callback group boundary failed")
  }
  func testPerDeviceHDRPolicyIsolationAndHardwareFailures() {
    var error: NSError?
    XCTAssertTrue(UltracamRunPerDeviceHDRSyntheticChecks(&error), error?.localizedDescription ?? "Per-device HDR policy failed")
  }
  func testHDRSettingDeclarationIsPerDeviceAndInterrupting() {
    let setting = DeckLinkCapturePlugin.hdrSetting(enabled: true)
    XCTAssertEqual(setting.id, "decklink:advertiseHDRToCameras")
    XCTAssertEqual(setting.value, .boolean(true))
    XCTAssertTrue(setting.mutable)
    XCTAssertTrue(setting.interruptsCapture)
  }
  func testFailedHDRSettingRetainsDesiredValueAndAllowsRetryOrOff() {
    let failure = PluginError.failed("EDID write failed")
    let setting = DeckLinkCapturePlugin.hdrSetting(enabled: true, applicationError: failure)
    XCTAssertEqual(setting.value, .boolean(true))
    XCTAssertEqual(setting.applicationError, failure)
    XCTAssertTrue(setting.mutable)
  }
  func testUnknownHDRDeviceReportsTypedUnavailable() async {
    do {
      try await DeckLinkCapturePlugin().apply(.boolean(true), to: "decklink:advertiseHDRToCameras", deviceID: "decklink:missing")
      XCTFail("Absent device must fail")
    } catch PluginError.unavailable {} catch { XCTFail("Expected unavailable, got \(error)") }
  }
  func testHDRBootstrapRejectsNonBooleanPolicy() {
    let policy = VendorSettingsPolicy(inheritedByPlugin: ["decklink": [DeckLinkCapturePlugin.hdrSettingID: .text("on")]])
    XCTAssertThrowsError(try DeckLinkCapturePlugin().configureSettings(policy)) { error in
      guard case PluginError.unsupported = error else { return XCTFail("Expected unsupported setting value") }
    }
  }
  func testTypedEventTranslation() {
    if case .fatal(let message) = DeckLinkCaptureSession.event("Capture error: disconnected") {
      XCTAssertEqual(message, "disconnected")
    } else { XCTFail("Expected fatal event") }
    if case .signalLost = DeckLinkCaptureSession.event("No HDMI video signal — waiting for the camera to reconnect.") {} else { XCTFail("Expected signal loss") }
    if case .unsupportedInput = DeckLinkCaptureSession.event("Unsupported HDMI input: 1080p") {} else { XCTFail("Expected unsupported input") }
  }
  func testTimecodePreservesDropFrameAndMissingValue() {
    XCTAssertNil(DeckLinkCaptureSession.timecode(nil))
    XCTAssertNil(DeckLinkCaptureSession.timecode("invalid"))
    XCTAssertNil(DeckLinkCaptureSession.timecode("01:x:02:03:04"))
    XCTAssertEqual(DeckLinkCaptureSession.timecode("01:02:03;04"),
      try Timecode(hours: 1, minutes: 2, seconds: 3, frames: 4, dropFrame: true))
  }
  func testStopBeforeStartIsTerminalAndIdempotent() {
    let session = DeckLinkCaptureSession()
    session.stop(); session.stop()
    XCTAssertThrowsError(try session.start(deviceID: "synthetic:missing", timing: .automatic,
      handlers: CaptureHandlers(deliver: { _ in })))
  }
  func testDiagnosticsPreserveNativeCapabilities() {
    let native = UltracamDeviceDiagnostics()
    native.setValue("driver-test", forKey: "driverVersion")
    native.setValue(16, forKey: "maximumHDMIAudioChannels")
    native.setValue(2, forKey: "capturedAudioChannels")
    native.setValue(true, forKey: "supportsHDRMetadata")
    native.setValue("PQ", forKey: "hdmiDynamicRange")
    native.setValue("Detected input", forKey: "signal")
    native.setValue(NSNumber(value: false), forKey: "signalPresent")
    XCTAssertEqual(DeckLinkCapturePlugin.translateDiagnostics(native).signalPresent, false)
    let fields = Dictionary(uniqueKeysWithValues: DeckLinkCapturePlugin.translateDiagnostics(native).vendorFields.map { ($0.label, $0.value) })
    XCTAssertEqual(fields["Driver version"], "driver-test")
    XCTAssertEqual(fields["Maximum HDMI audio channels"], "16")
    XCTAssertEqual(fields["Captured audio channels"], "2")
    XCTAssertEqual(fields["HDR metadata"], "Yes")
    XCTAssertEqual(fields["HDMI dynamic range"], "PQ")
    XCTAssertEqual(fields.count, 13)
  }
  func testPairedAudioDeclarationUsesVideoClockBeforeFrames() throws {
    let recorder = AdapterDeliveryRecorder()
    let session = DeckLinkCaptureSession()
    session.startFixture(handlers: CaptureHandlers(deliver: { recorder.append($0) }))
    defer { session.stop() }
    session.deliverFixtureFrame(try fixtureBuffer(), at: CMTime(value: 100, timescale: 1))
    let values = recorder.values
    guard let declaration = values.first(where: { if case .event(.audioFormatChanged(.present)) = $0.payload { true } else { false } }), case .event(.audioFormatChanged(.present(let audio))) = declaration.payload else {
      return XCTFail("Audio declaration must precede frame admission")
    }
    XCTAssertEqual(audio.clock, .pairedWithFrames)
    XCTAssertNotEqual(values[0].clockBindings.audio, values[0].clockBindings.video)
  }
  func testSameFormatTimestampResetStartsNewEpochBeforeFrame() throws {
    let recorder = AdapterDeliveryRecorder()
    let session = DeckLinkCaptureSession()
    session.startFixture(handlers: CaptureHandlers(deliver: { recorder.append($0) }))
    defer { session.stop() }
    let buffer = try fixtureBuffer()
    session.deliverFixtureFrame(buffer, at: CMTime(value: 100, timescale: 1))
    session.deliverFixtureFrame(buffer, at: .zero)
    let values = recorder.values
    let frames = values.filter { if case .frame = $0.payload { true } else { false } }
    XCTAssertEqual(frames.count, 2)
    XCTAssertNotEqual(frames[0].epochID, frames[1].epochID)
    XCTAssertNotEqual(frames[0].clockBindings.video, frames[1].clockBindings.video)
    XCTAssertNotEqual(frames[1].clockBindings.audio, frames[1].clockBindings.video)
    guard let boundary = values.first(where: { if case .event(.discontinuity) = $0.payload { true } else { false } }) else {
      return XCTFail("Reset requires an ordered discontinuity")
    }
    XCTAssertLessThan(boundary.sequence, frames[1].sequence)
    XCTAssertEqual(boundary.epochID, frames[1].epochID)
  }
  func testFrameTimecodeIsAvailableAtFrameAdmission() throws {
    let recorder = AdapterDeliveryRecorder()
    let session = DeckLinkCaptureSession()
    session.startFixture(handlers: CaptureHandlers(deliver: { recorder.append($0) }))
    defer { session.stop() }
    session.deliverFixtureFrame(try fixtureBuffer(), at: .zero, timecode: "01:02:03;04")
    let frames = recorder.values.compactMap { value -> CaptureFrameInfo? in
      if case .frame(_, let info) = value.payload { return info }; return nil
    }
    XCTAssertEqual(frames.first?.timecode, try Timecode(hours: 1, minutes: 2, seconds: 3, frames: 4, dropFrame: true))
  }
  private func fixtureBuffer() throws -> CVPixelBuffer {
    var value: CVPixelBuffer?
    let status = CVPixelBufferCreate(nil, 3840, 2160, kCVPixelFormatType_422YpCbCr10, nil, &value)
    guard status == kCVReturnSuccess, let value else { throw PluginError.failed("Fixture allocation") }
    return value
  }
}

private final class AdapterDeliveryRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [CaptureDelivery] = []
  func append(_ value: CaptureDelivery) { lock.withLock { storage.append(value) } }
  var values: [CaptureDelivery] { lock.withLock { storage } }
}
