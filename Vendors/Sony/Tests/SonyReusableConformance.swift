import Foundation

@MainActor private final class ConformanceSonyBackend: UCSonyCameraControl {
  override var available: Bool { true }
  override var sdkVersion: String? { "2.2.0" }
  override func connectFeed(_ feedID: String, camera: String, user: String, password: String,
    fingerprint: String, completion: @escaping UCSonyReply) { completion("[]", nil) }
  override func refreshFeed(_ feedID: String, completion: @escaping UCSonyReply) { completion("[{\"id\":\"iso\",\"title\":\"ISO\",\"code\":1,\"value\":100,\"writable\":true,\"choices\":[{\"value\":100,\"label\":\"100\"}]}]", nil) }
  override func setFeed(_ feedID: String, code: UInt32, value: UInt64, completion: @escaping UCSonyReply) {
    precondition(code == 1 && value == 100); completion("[]", nil)
  }
  override func disconnectFeed(_ feedID: String, completion: @escaping UCSonyReply) { completion("[]", nil) }
}
@main struct SonyReusableConformance {
  @MainActor static func main() async throws {
    let camera = ControlCamera(pluginID: "sony", id: "02:11:22:33:44:55", name: "Synthetic",
      transport: .network, address: "192.0.2.1", fingerprint: nil)
    try await ControlPluginConformanceHarness.run(make: { SonyControlPlugin(backend: ConformanceSonyBackend()) }, camera: camera)
    print("Sony actual adapter shared lifecycle oracle passed")
  }
}
