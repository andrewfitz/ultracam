import Foundation

/// Scripted readings for the hardware-awareness fields; connects and disconnects at once.
@MainActor
private final class ReadingsBridge: UCSonyCameraControl {
  nonisolated(unsafe) var json = "[]"
  nonisolated(unsafe) var setCalls = 0
  override var available: Bool { false }
  override func connectFeed(_ feedID: String, camera: String, address: String, authentication: Bool, user: String, password: String,
    fingerprint: String, completion: @escaping UCSonyReply) { completion("[]", nil) }
  override func refreshFeed(_ feedID: String, completion: @escaping UCSonyReply) { completion(json, nil) }
  override func setFeed(_ feedID: String, code: UInt32, value: UInt64, completion: @escaping UCSonyReply) {
    setCalls += 1; completion("[]", nil)
  }
  override func disconnectFeed(_ feedID: String, completion: @escaping UCSonyReply) { completion("[]", nil) }
}

@MainActor
private final class Bridge: UCSonyCameraControl {
  nonisolated(unsafe) var simulatedAvailable = false
  override var available: Bool { simulatedAvailable }
  override var sdkVersion: String? { "2.2.0" }
  nonisolated(unsafe) var calls: [String] = []
  nonisolated(unsafe) var lastKey = ""
  nonisolated(unsafe) var pendingCleanup = false
  nonisolated(unsafe) var expectedConnection: (String, Bool)?
  nonisolated(unsafe) var failConnect = false
  nonisolated(unsafe) var holdCleanup = false
  nonisolated(unsafe) var cleanupReply: UCSonyReply?
  nonisolated(unsafe) var cacheAddress: String?
  nonisolated(unsafe) var cacheAuthentication = true
  nonisolated(unsafe) var connectAdmissions = 0
  nonisolated private func cachedJSON() -> String {
    "{\"id\":\"02:11:22:33:44:55\",\"model\":\"FX3\",\"address\":\"\(cacheAddress!)\",\"authentication\":\(cacheAuthentication),\"fingerprint\":\"\(cacheAuthentication ? "pin" : "")\",\"fingerprintError\":\"\"}"
  }
  override func discover(_ reply: @escaping UCSonyReply) {
    if cacheAddress != nil { reply("[" + cachedJSON() + "]", nil); return }
    reply(nil, "Sony SDK is unavailable in this build.")
  }
  override func connectFeed(_ feedID: String, camera: String, address: String, authentication: Bool, user: String, password: String,
    fingerprint: String, completion: @escaping UCSonyReply) {
    if let cacheAddress, cacheAddress != address || cacheAuthentication != authentication {
      completion(nil, "Camera endpoint or authentication changed after preparation."); return
    }
    connectAdmissions += 1
    if let expectedConnection {
      precondition(address == expectedConnection.0 && authentication == expectedConnection.1,
        "Native connect must receive the immutable approved endpoint and authentication")
    }
    lastKey = feedID; calls.append("connect")
    completion(failConnect ? nil : "[]", failConnect ? "Synthetic connect failure" : nil)
  }
  override func refreshFeed(_ feedID: String, completion: @escaping UCSonyReply) {
    calls.append("refresh")
    completion("""
    [{"id":"iso","title":"ISO","code":1,"value":18446744073709551615,"writable":true,"choices":[{"value":18446744073709551615,"label":"Maximum"}]},{"id":"monitoringDisplayHDMI","title":"HDMI camera display","code":2,"value":2,"writable":true,"choices":[{"value":1,"label":"Off"},{"value":2,"label":"On"}]},{"id":"faceEyeFrameDisplay","title":"Face/Eye frames","code":3,"value":1,"writable":true,"choices":[{"value":1,"label":"Off"},{"value":2,"label":"On"}]}]
    """, nil)
  }
  override func setFeed(_ feedID: String, code: UInt32, value: UInt64, completion: @escaping UCSonyReply) {
    precondition(code == 1 ? value == UInt64.max : value == 1); calls.append("set"); completion("[]", nil)
  }
  override func disconnectFeed(_ feedID: String, completion: @escaping UCSonyReply) {
    calls.append("disconnect")
    if holdCleanup { cleanupReply = completion; return }
    completion(pendingCleanup ? nil : "[]", pendingCleanup ? "Disconnect acknowledgement pending" : nil)
  }
  override func prepareCamera(address: String, macAddress: String, authentication: Bool,
    completion: @escaping UCSonyReply) {
    if cacheAddress != nil {
      cacheAddress = address; cacheAuthentication = authentication
      completion(cachedJSON(), nil); return
    }
    completion("""
    {"id":"02:11:22:33:44:66","model":"FX3","address":"192.168.1.10","authentication":false,"fingerprint":"","fingerprintError":""}
    """, nil)
  }
}

@main
struct SonyPluginChecks {
  @MainActor static func main() async throws {
    let actualAbsentBridge = UCSonyCameraControl()
    precondition(!actualAbsentBridge.available && actualAbsentBridge.sdkVersion == nil)
    let bridge = Bridge()
    let plugin = SonyControlPlugin(backend: bridge)
    let camera = ControlCamera(pluginID: "sony", id: "02:11:22:33:44:55", name: "FX3",
      transport: .network, address: "192.168.1.10", fingerprint: "pin")
    precondition(plugin.descriptor.id == "sony")
    precondition(plugin.descriptor.displayNameKey == "sony.descriptor.name")
    let localizationRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("bundle")
    defer { try? FileManager.default.removeItem(at: localizationRoot) }
    try FileManager.default.createDirectory(at: localizationRoot.appendingPathComponent("en.lproj"), withIntermediateDirectories: true)
    try Data("\"sony.descriptor.name\" = \"Sony localized fixture\";\n\"sony.control.choice.on\" = \"Enabled fixture\";\n\"sony.control.choice.off\" = \"Disabled fixture\";\n".utf8).write(to: localizationRoot.appendingPathComponent("en.lproj/SonyControl.strings"))
    let localizationBundle = Bundle(path: localizationRoot.path)!
    precondition(plugin.descriptor.localizedDisplayName(in: localizationBundle) == "Sony localized fixture")
    precondition(plugin.descriptor.localizedDisplayName() == "Sony")
    precondition(plugin.descriptor.badgeAssetName == "SonyLogo")
    precondition(plugin.descriptor.badgeText == "Sony")
    precondition(plugin.descriptor.sdkPresent == false)
    precondition(plugin.descriptor.sdkVersion == nil)
    let presentBridge = Bridge()
    presentBridge.simulatedAvailable = true
    let presentPlugin = SonyControlPlugin(backend: presentBridge)
    precondition(presentPlugin.descriptor.sdkVersion == "2.2.0")
    precondition(presentBridge.calls.isEmpty, "Reading SDK metadata must not call camera operations")
    precondition(plugin.credentialService == "org.ultracam.sony-camera-control.credentials.v1")
    do {
      _ = try await plugin.discover()
      throw NSError(domain: "SonyPluginChecks: expected unavailable", code: 3)
    } catch let error as ControlError { precondition(error.code == .unavailable) }
    let account = try plugin.credentialAccount(for: camera, fingerprint: "pin")
    precondition(account == "02:11:22:33:44:55.64f46a7526a186d2346552453ae478ca51244674f5b21ba150bd483b39f7c812")
    try await plugin.disconnect(feedID: "unstarted", generation: 10)
    do {
      try await plugin.connect(feedID: "unstarted", generation: 10, camera: camera, credentials: nil)
      preconditionFailure("A disconnected generation was readmitted")
    } catch let error as ControlError { precondition(error.code == .staleGeneration) }
    precondition(bridge.calls.isEmpty)
    bridge.expectedConnection = (camera.address, camera.authenticationMode == .usernamePassword)
    try await plugin.connect(feedID: "feed", generation: 1, camera: camera, credentials: nil)
    let firstKey = bridge.lastKey
    let properties = try await plugin.properties(feedID: "feed", generation: 1)
    precondition(properties.first?.value == .unsignedInteger(UInt64.max))
    let mappedOn = properties.first(where: { $0.id == "monitoringDisplayHDMI" })!.options.last!
    precondition(mappedOn.localizedLabel(in: localizationBundle) == "Enabled fixture")
    let mappedOff = properties.first(where: { $0.id == "monitoringDisplayHDMI" })!.options.first!
    precondition(mappedOff.localizedLabel(in: localizationBundle) == "Disabled fixture")
    precondition(properties.first?.labelKey == "sony.control.iso")
    precondition(properties.first?.localizationTable == "SonyControl")
    precondition(properties.first?.localizedLabel() == "ISO")
    precondition(properties.first?.options.first?.labelKey == nil, "Dynamic numeric labels remain verbatim")
    precondition(properties.first(where: { $0.id == "monitoringDisplayHDMI" })?.options.last?.labelKey == "sony.control.choice.on")
    precondition(properties.contains(where: { $0.id == "cameraDisplay" && $0.value == .boolean(true) && $0.role == .cameraDisplay }))
    precondition(properties.first(where: { $0.id == "iso" })?.overlayOrder == 0)
    precondition(properties.first(where: { $0.id == "monitoringDisplayHDMI" })?.role == .hidden)
    try await plugin.set("cameraDisplay", value: .boolean(false), feedID: "feed", generation: 1)
    precondition(bridge.calls.filter { $0 == "set" }.count == 2)
    try await plugin.set("iso", value: .unsignedInteger(UInt64.max), feedID: "feed", generation: 1)
    try await plugin.disconnect(feedID: "feed", generation: 1)
    try await plugin.connect(feedID: "feed", generation: 2, camera: camera, credentials: nil)
    precondition(firstKey != bridge.lastKey)
    let count = bridge.calls.count
    try await plugin.disconnect(feedID: "feed", generation: 1)
    precondition(bridge.calls.count == count)
    do {
      _ = try await plugin.prepare(.endpoint(ControlEndpoint(address: camera.address,
        expectedIdentity: camera.id, authenticationMode: .none)))
      preconditionFailure("Mismatched manual identity was accepted")
    } catch let error as ControlError { precondition(error.code == .changedIdentity) }
    bridge.pendingCleanup = true
    do {
      try await plugin.disconnect(feedID: "feed", generation: 2)
      preconditionFailure("Pending cleanup must fail")
    } catch let error as ControlError {
      guard error.code == .cleanupPending else { throw NSError(domain: "SonyPluginChecks: expected cleanupPending", code: 1) }
    }
    do {
      try await plugin.connect(feedID: "other", generation: 3, camera: camera, credentials: nil)
      throw NSError(domain: "SonyPluginChecks: expected busy while cleanup pending", code: 2)
    } catch let error as ControlError { precondition(error.code == .busy) }
    bridge.pendingCleanup = false
    try await plugin.disconnect(feedID: "feed", generation: 2)
    let failedBridge = Bridge()
    failedBridge.failConnect = true
    failedBridge.holdCleanup = true
    let failedPlugin = SonyControlPlugin(backend: failedBridge)
    let failing = Task { try await failedPlugin.connect(feedID: "first", generation: 1, camera: camera, credentials: nil) }
    for _ in 0..<1000 { if failedBridge.cleanupReply != nil { break }; await Task.yield() }
    precondition(failedBridge.cleanupReply != nil, "Connect cleanup must be held deterministically")
    let competing = Task { try await failedPlugin.connect(feedID: "replacement", generation: 2, camera: camera, credentials: nil) }
    for _ in 0..<100 { await Task.yield() }
    precondition(failedBridge.calls.filter { $0 == "connect" }.count == 1,
      "The camera claim was released during cleanup")
    do { try await competing.value; preconditionFailure("Expected busy") }
    catch let error as ControlError { precondition(error.code == .busy) }
    failedBridge.holdCleanup = false
    failedBridge.cleanupReply?(nil, "Synthetic pending cleanup")
    failedBridge.cleanupReply = nil
    do { try await failing.value; preconditionFailure("Synthetic connect must fail") } catch {}
    try await failedPlugin.disconnect(feedID: "first", generation: 1)
    failedBridge.failConnect = false
    try await failedPlugin.connect(feedID: "replacement", generation: 2, camera: camera, credentials: nil)
    try await failedPlugin.disconnect(feedID: "replacement", generation: 2)
    let mutable = Bridge()
    mutable.cacheAddress = "192.0.2.1"
    let pinnedPlugin = SonyControlPlugin(backend: mutable)
    let prepared = try await pinnedPlugin.prepare(.camera(ControlCamera(pluginID: "sony", id: camera.id,
      name: "FX3", transport: .network, address: "192.0.2.1", fingerprint: "pin", authenticationMode: .usernamePassword)))
    _ = try await pinnedPlugin.prepare(.endpoint(ControlEndpoint(address: "192.0.2.2", expectedIdentity: camera.id, authenticationMode: .none)))
    do {
      try await pinnedPlugin.connect(feedID: "approved", generation: 1, camera: prepared.camera,
        credentials: .usernamePassword(username: "synthetic", password: "synthetic"))
      preconditionFailure("Mutable preparation cache replaced the approved endpoint")
    } catch let error as ControlError { precondition(error.code == .changedIdentity) }
    precondition(mutable.connectAdmissions == 0)
    // A discovery replacement is subject to exactly the same atomic native gate.
    mutable.cacheAddress = "192.0.2.3"; mutable.cacheAuthentication = false
    _ = try await pinnedPlugin.discover()
    do {
      try await pinnedPlugin.connect(feedID: "approved", generation: 2, camera: prepared.camera,
        credentials: .usernamePassword(username: "synthetic", password: "synthetic"))
      preconditionFailure("Discovery replaced the approved authenticated endpoint")
    } catch let error as ControlError { precondition(error.code == .changedIdentity) }
    precondition(mutable.connectAdmissions == 0)
    // Battery in the unit the body reports: 78 minutes is never 78%, and only a known unit warns.
    let minutes = SonyControlPlugin.battery(value: 78, unitLabel: "Minutes")
    precondition(minutes.label == "78 min" && minutes.unit == .minutes && minutes.severity == nil)
    precondition(SonyControlPlugin.battery(value: 78, unitLabel: "Percent") == ("78%", .percent, nil))
    precondition(SonyControlPlugin.battery(value: 12, unitLabel: "Percent").severity == .warning)
    precondition(SonyControlPlugin.battery(value: 10, unitLabel: "Minutes").severity == .warning)
    precondition(SonyControlPlugin.battery(value: 12, unitLabel: nil) == ("12", nil, nil), "No unit: raw, no warning")
    precondition(SonyControlPlugin.battery(value: 7, unitLabel: "Voltage").severity == nil)
    // Not read yet (the SDK's untaken value): no number and no warning, in any unit.
    for unit in ["Minutes", "Percent", nil] {
      precondition(SonyControlPlugin.battery(value: 0xFFFF, unitLabel: unit) == ("—", nil, nil), "Untaken battery read as a number")
    }
    // OnWarning: known keys become notices, recoveries are info, anything else is dropped.
    precondition(SonyControlPlugin.notice(forWarning: "storageFull")?.severity == .warning)
    precondition(SonyControlPlugin.notice(forWarning: "reconnecting")?.severity == .notice)
    precondition(SonyControlPlugin.notice(forWarning: "networkRecovered")?.severity == .info)
    precondition(SonyControlPlugin.notice(forWarning: "131089") == nil)
    // A picture suggests a source profile only when a declaration describes it exactly.
    precondition(SonyControlPlugin.sourceProfile(gamma: "S-Log3", gamut: "S-Gamut3.Cine") == "sony-slog3-sgamut3cine")
    precondition(SonyControlPlugin.sourceProfile(gamma: "S-Log3", gamut: "S-Gamut3") == "sony-slog3-sgamut3")
    precondition(SonyControlPlugin.sourceProfile(gamma: "ITU709", gamut: "709") == "rec709-video")
    precondition(SonyControlPlugin.sourceProfile(gamma: "ITU709", gamut: "ITU709 Matrix") == "rec709-video")
    precondition(SonyControlPlugin.sourceProfile(gamma: "ITU709", gamut: "S-Gamut3") == nil)
    precondition(SonyControlPlugin.sourceProfile(gamma: "ITU709", gamut: "Black & White") == nil)
    precondition(SonyControlPlugin.sourceProfile(gamma: "ITU709", gamut: nil) == nil)
    precondition(SonyControlPlugin.sourceProfile(gamma: "S-Cinetone", gamut: "S-Cinetone") == nil)
    precondition(SonyControlPlugin.sourceProfile(gamma: "S-Log3", gamut: "S-Gamut") == nil)
    precondition(plugin.descriptor.localizedMissingDeviceHint()?.contains("Remote Shoot Function") == true)
    let readings = ReadingsBridge()
    readings.json = """
    [{"id":"battery","title":"Battery","code":10,"value":78,"writable":false,"choices":[],"label":"78"},\
    {"id":"batteryUnit","title":"Battery unit","code":11,"value":1,"writable":false,"choices":[],"label":"Minutes"},\
    {"id":"overheating","title":"Overheating","code":12,"value":1,"writable":false,"choices":[],"label":"About to overheat"},\
    {"id":"gamma","title":"Gamma","code":13,"value":771,"writable":false,"choices":[],"label":"S-Log3"},\
    {"id":"colorMode","title":"Color mode","code":14,"value":8,"writable":false,"choices":[],"label":"S-Gamut3.Cine"},\
    {"id":"firmware","title":"Firmware","code":15,"value":0,"writable":false,"choices":[],"label":"7.02"}]
    """
    let readingsPlugin = SonyControlPlugin(backend: readings)
    try await readingsPlugin.connect(feedID: "readings", generation: 1, camera: camera, credentials: nil)
    let read = try await readingsPlugin.properties(feedID: "readings", generation: 1)
    let battery = read.first { $0.id == "battery" }
    precondition(battery?.role == .power && battery?.unit == .minutes && battery?.currentValueLabel == "78 min" && battery?.severity == nil)
    precondition(read.first { $0.id == "batteryUnit" }?.role == .hidden)
    let heat = read.first { $0.id == "overheating" }
    precondition(heat?.role == .thermal && heat?.severity == .warning)
    precondition(read.first { $0.id == "gamma" }?.suggestedSourceProfileID == "sony-slog3-sgamut3cine")
    precondition(read.first { $0.id == "colorMode" }?.role == .colorProfile)
    precondition(read.first { $0.id == "firmware" }?.role == .firmware)
    readings.json = """
    [{"id":"monitoringDisplayHDMI","title":"HDMI","code":2,"value":2,"writable":true,"choices":[{"value":1,"label":"Off"}]},
    {"id":"faceEyeFrameDisplay","title":"Frames","code":3,"value":2,"writable":true,"choices":[{"value":2,"label":"On"}]}]
    """
    do {
      try await readingsPlugin.set("cameraDisplay", value: .boolean(false), feedID: "readings", generation: 1)
      preconditionFailure("Unavailable grouped display value was accepted")
    } catch let error as ControlError { precondition(error.code == .invalidRequest) }
    precondition(readings.setCalls == 0, "Validate the entire grouped display change before writing any setting")
    try await readingsPlugin.disconnect(feedID: "readings", generation: 1)
    print("Sony plugin checks passed")
  }
}
