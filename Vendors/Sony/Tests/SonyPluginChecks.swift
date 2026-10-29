import Foundation

@MainActor
private final class Bridge: UCSonyCameraControl {
  nonisolated(unsafe) var simulatedAvailable = false
  override var available: Bool { simulatedAvailable }
  override var sdkVersion: String? { "2.2.0" }
  nonisolated(unsafe) var calls: [String] = []
  nonisolated(unsafe) var lastKey = ""
  nonisolated(unsafe) var pendingCleanup = false
  nonisolated(unsafe) var failConnect = false
  nonisolated(unsafe) var holdCleanup = false
  nonisolated(unsafe) var cleanupReply: UCSonyReply?
  override func discover(_ reply: @escaping UCSonyReply) {
    reply(nil, "Sony SDK is unavailable in this build.")
  }
  override func connectFeed(_ feedID: String, camera: String, user: String, password: String,
    fingerprint: String, completion: @escaping UCSonyReply) {
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
    try Data("\"sony.descriptor.name\" = \"Sony localized fixture\";\n".utf8).write(to: localizationRoot.appendingPathComponent("en.lproj/SonyControl.strings"))
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
    try await plugin.connect(feedID: "feed", generation: 1, camera: camera, credentials: nil)
    let firstKey = bridge.lastKey
    let properties = try await plugin.properties(feedID: "feed", generation: 1)
    precondition(properties.first?.value == .unsignedInteger(UInt64.max))
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
    print("Sony plugin checks passed")
  }
}
