import SwiftUI

/// This harness exercises production control code without touching the user's
/// production Keychain. It is built but never launched by the automated checks.
private actor SandboxCredentials: CameraControlCredentialStoring {
  func load(service: String, account: String) async throws -> ControlCredentials? { nil }
  func save(_ credential: ControlCredentials, service: String, account: String) async throws {}
  func delete(service: String, account: String) async throws {}
}

@main struct SonySandboxCheckApp: App {
  @State private var store = CameraControlStore(plugins: ["sony": SonyControlPlugin()], credentials: SandboxCredentials())
  var body: some Scene {
    Window("Sony Camera Software Check", id: "sony-check") { SonySandboxCheckRoot(store: store) }
      .defaultSize(width: 420, height: 160)
  }
}
private struct SonySandboxCheckRoot: View {
  let store: CameraControlStore
  @State private var showingSettings = true
  var body: some View {
    VStack(spacing: 16) {
      Text("Sony Camera Software Check").font(.headline)
      Button("Open Camera Settings") { showingSettings = true }
    }.padding(24)
      .sheet(isPresented: $showingSettings) {
        UICameraControlSettings(feedID: "software-check", name: "Software Check", store: store)
      }
  }
}
