import SwiftUI

/// The sandbox UI harness must never touch the user's production Keychain. Its
/// purpose is discovery/view verification, so saved sign-ins are intentionally
/// unavailable and the production store remains injectable.
private actor SandboxCredentials: SonyCameraCredentialStoring {
  func load(cameraID: String, fingerprint: String) async throws -> SonyCameraCredential? { nil }
  func save(_ credential: SonyCameraCredential, cameraID: String, fingerprint: String) async throws {}
  func delete(cameraID: String, fingerprint: String) async throws {}
}

/// Exercise the production Sony views and SDK inside the host's network sandbox,
/// using a separate app identity and preferences. No HDMI/extension is started.
@main struct SonySandboxCheckApp: App {
  @State private var store = SonyCameraStore(credentials: SandboxCredentials())

  var body: some Scene {
    Window("Sony Camera Software Check", id: "sony-check") {
      SonySandboxCheckRoot(store: store)
    }
    .defaultSize(width: 420, height: 160)
  }
}

private struct SonySandboxCheckRoot: View {
  let store: SonyCameraStore
  @State private var showingSettings = true

  var body: some View {
    VStack(spacing: 16) {
      Text("Sony Camera Software Check").font(.headline)
      Button("Open Camera Settings") { showingSettings = true }
    }
    .padding(24)
    .sheet(isPresented: $showingSettings) {
      UISonyCameraSettings(feedID: "software-check", name: "Software Check", store: store)
    }
  }
}
