import AppKit
import MonitorKitCore
import SwiftUI
import SystemExtensions

/// A camera's monitor-only LUT (W4 step 7): the strip's ⋯ menu control, and the
/// real AppModel offline saving it through the monitor preferences, restoring
/// it, and handing it to the camera's feed host.
@MainActor enum MonitorLUTVerify {
  private final class Publisher: AppVirtualCameraRegistryPublishing {
    func publish(_ snapshot: VirtualCameraRegistrySnapshot) {}
  }

  private static func installer() -> ExtensionInstaller {
    ExtensionInstaller(services: ExtensionInstaller.Services(
      preflight: { ExtensionInstallPreflight(developerSigned: true, hasInstallEntitlement: true) },
      makeRequest: { change in
        switch change {
        case .install: return .activationRequest(forExtensionWithIdentifier: VideoContract.extensionID, queue: .main)
        case .remove: return .deactivationRequest(forExtensionWithIdentifier: VideoContract.extensionID, queue: .main)
        }
      }, submit: { _ in }))
  }

  static func run(verifier: Verifier) throws {
    try menu(verifier: verifier)
    try model(verifier: verifier)
  }

  /// The ⋯ menu's Monitor LUT submenu, without and with a chosen file.
  private static func menu(verifier: Verifier) throws {
    let session = UIFixtures.standalone()
    var context = UIContext.fixture(session)
    guard let camera = context.presentation.cameras.first else {
      return verifier.check("monitor LUT: a fixture camera", false)
    }
    let monitor = UIFixtureMonitorSettings(session: session)
    context.monitor = monitor
    /// The ⋯ menu's items and the Monitor LUT submenu's.
    func items() -> (menu: [NSMenuItem], lut: [NSMenuItem]) {
      let strip = HostedView(UIChannelStripView(camera: camera, context: context), size: CGSize(width: 560, height: 230), dark: false)
      defer { strip.close() }
      let menu = Menus.items(in: strip.host, containing: "Load LUT…")
      return (menu, menu.first { $0.title == "Monitor LUT" }?.submenu?.items ?? [])
    }
    let empty = items()
    let menuTitles = empty.menu.map(\.title).joined(separator: ", ")
    verifier.check("monitor LUT: the strip ⋯ menu has a Monitor LUT submenu",
      empty.menu.first { $0.title == "Monitor LUT" }?.submenu != nil, menuTitles, viewDependent: true)
    if let load = empty.menu.firstIndex(where: { $0.title == "Load LUT…" }),
      let lut = empty.menu.firstIndex(where: { $0.title == "Monitor LUT" }) {
      verifier.check("monitor LUT: listed right after Load LUT…", lut == load + 1, menuTitles, viewDependent: true)
    }
    func item(_ title: String, in list: [NSMenuItem]) -> NSMenuItem? { list.first { $0.title == title } }
    let titles = empty.lut.map(\.title).joined(separator: ", ")
    verifier.check("monitor LUT: offers Load Monitor LUT… without a file",
      item("Load Monitor LUT…", in: empty.lut)?.isEnabled == true, titles, viewDependent: true)
    verifier.check("monitor LUT: Show is off and disabled without a file",
      item("Show Monitor LUT", in: empty.lut).map { !$0.isEnabled && $0.state == .off } == true, titles, viewDependent: true)
    verifier.check("monitor LUT: Remove is disabled without a file",
      item("Remove Monitor LUT", in: empty.lut)?.isEnabled == false, titles, viewDependent: true)

    var chosen = monitor.preferences(for: camera.id)
    chosen.monitorLUT = MonitorLUTChoice(bookmark: Data([1]), fileName: "Show.cube")
    monitor.setPreferences(chosen, for: camera.id)
    let full = items().lut
    let fullTitles = full.map(\.title).joined(separator: ", ")
    verifier.check("monitor LUT: names the chosen file", item("Show.cube", in: full) != nil, fullTitles, viewDependent: true)
    verifier.check("monitor LUT: offers Replace Monitor LUT… with a file",
      item("Replace Monitor LUT…", in: full)?.isEnabled == true, fullTitles, viewDependent: true)
    verifier.check("monitor LUT: Show is on and enabled with a file",
      item("Show Monitor LUT", in: full).map { $0.isEnabled && $0.state == .on } == true, fullTitles, viewDependent: true)
    verifier.check("monitor LUT: Remove is enabled with a file",
      item("Remove Monitor LUT", in: full)?.isEnabled == true, fullTitles, viewDependent: true)
  }

  /// AppModel offline: choose, persist (the selected camera's descriptor is
  /// rebuilt on every save), restore in a new model, hide, remove.
  private static func model(verifier: Verifier) throws {
    let suiteName = "org.ultracam.ui-verify-monitor-lut.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      return verifier.check("monitor LUT: defaults suite", false)
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ui-verify-monitor-lut-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var lattice = ["TITLE \"Monitor Check\"", "LUT_3D_SIZE 2"]
    for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { lattice.append("\(1 - Float(r)) \(1 - Float(g)) \(1 - Float(b))") } } }
    let cube = folder.appendingPathComponent("monitor-check.cube")
    try lattice.joined(separator: "\n").write(to: cube, atomically: true, encoding: .utf8)

    let settings = AppSettingsStore(defaults: defaults)
    let alpha = FeedID(rawValue: "ui-verify-monitor-lut-alpha"), beta = FeedID(rawValue: "ui-verify-monitor-lut-beta")
    settings.saveSnapshot(AppSettingsSnapshot(feeds: [
      FeedDescriptor(id: alpha, name: "Camera 1", selectedDevice: "ui-verify-monitor-lut-a"),
      FeedDescriptor(id: beta, name: "Camera 2", selectedDevice: "ui-verify-monitor-lut-b"),
    ], selectedFeedID: alpha, outputMode: .separateCameras))
    func makeModel() -> AppModel {
      AppModel(settingsStore: settings, registryStore: VirtualCameraRegistryStore(defaults: defaults),
        registryPublisher: Publisher(), recordingFolderStore: RecordingFolderStore(defaults: defaults),
        installer: installer(), hardware: .offline)
    }
    func settle(until condition: () -> Bool) {
      let deadline = Date().addingTimeInterval(10)
      while !condition() && Date() < deadline { MainLoop.run(seconds: 0.01) }
    }
    func saved(_ id: FeedID) -> FeedDescriptor? { settings.loadSnapshot().feeds.first { $0.id == id } }

    @MainActor final class Outcome { var value: Result<LoadedLUT, any Error>? }
    let outcome = Outcome()
    Task { @MainActor in
      do { outcome.value = .success(try await MonitorFeedHost.monitorLUTLoader.load(url: cube)) } catch {
        outcome.value = .failure(error)
      }
    }
    settle { outcome.value != nil }
    guard case .success(let file)? = outcome.value else {
      return verifier.check("monitor LUT: the file loads", false, "\(String(describing: outcome.value))")
    }

    let model = makeModel()
    let monitor = UIAppMonitorSettings(model: model)
    for (id, name) in [(alpha, "selected"), (beta, "other")] {
      UIMonitorLUTMenu.chosen(file, cameraID: id.rawValue, monitor: monitor)
      verifier.check("monitor LUT: choosing saves the \(name) camera's bookmark",
        saved(id)?.monitorLUTBookmark == file.bookmark && saved(id)?.monitor.monitorLUT?.fileName == "monitor-check.cube")
      verifier.check("monitor LUT: choosing shows the \(name) camera's Monitor picture",
        monitor.preferences(for: id.rawValue).state.pictureStage == .monitor && saved(id)?.monitor.state.pictureStage == .monitor)
      verifier.check("monitor LUT: the \(name) camera's burn-in LUT is untouched",
        saved(id)?.lutBookmark == nil && saved(id)?.applyLUT == false)
    }
    // The selected camera's descriptor is rebuilt from the model on every save.
    model.saveSettings()
    verifier.check("monitor LUT: a later save keeps it", saved(alpha)?.monitorLUTBookmark == file.bookmark)
    let host = model.monitorCoordinator.captureSink(for: MonitorTargetID(alpha.rawValue))
    settle { host.monitorLUTState != .loading && host.monitorLUTState != .none }
    verifier.check("monitor LUT: the camera's feed host loads it", host.monitorLUTState == .loaded("Monitor Check"),
      "\(host.monitorLUTState)")

    UIMonitorLUTMenu.setShown(false, cameraID: alpha.rawValue, monitor: monitor)
    verifier.check("monitor LUT: hiding it persists", saved(alpha)?.monitorLUTEnabled == false && saved(alpha)?.monitorLUTBookmark != nil)
    UIMonitorLUTMenu.setShown(true, cameraID: alpha.rawValue, monitor: monitor)

    let restored = makeModel()
    verifier.check("monitor LUT: a new session restores the choice",
      restored.monitorCoordinator.preferences(for: MonitorTargetID(alpha.rawValue)).monitorLUT?.bookmark == file.bookmark)
    let restoredHost = restored.monitorCoordinator.captureSink(for: MonitorTargetID(beta.rawValue))
    settle { restoredHost.monitorLUTState != .loading && restoredHost.monitorLUTState != .none }
    verifier.check("monitor LUT: a new session loads it", restoredHost.monitorLUTState == .loaded("Monitor Check"),
      "\(restoredHost.monitorLUTState)")

    let restoredMonitor = UIAppMonitorSettings(model: restored)
    UIMonitorLUTMenu.remove(cameraID: beta.rawValue, monitor: restoredMonitor)
    verifier.check("monitor LUT: Remove forgets the bookmark", saved(beta)?.monitorLUTBookmark == nil)
    verifier.check("monitor LUT: Remove clears the host at once", restoredHost.monitorLUTState == .none && restoredHost.monitorLUT == nil)
    verifier.check("monitor LUT: Remove leaves the other camera's", saved(alpha)?.monitorLUTBookmark == file.bookmark)
  }
}
