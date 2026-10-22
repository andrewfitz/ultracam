import MonitorToolsCore
import MonitorToolsUI
import SwiftUI

/// Live pictures for the app. Every picture (cameras, Program, the menu bar)
/// is a monitor surface: a Metal layer that draws every camera frame on the
/// display refresh, with any tools in the same pass. Hidden or occluded
/// pictures do no GPU work.
@MainActor struct UIAppPictures: UIPictureProviding {
  let model: AppModel
  /// `compact` is the menu bar preview: no scopes and no tool chrome.
  func picture(cameraID: String, compact: Bool) -> AnyView {
    AnyView(UIAppLivePicture(model: model, coordinator: model.monitorCoordinator, cameraID: cameraID, compact: compact))
  }
  func programPicture() -> AnyView {
    AnyView(UIAppLivePicture(model: model, coordinator: model.monitorCoordinator, cameraID: "program", compact: false))
  }
}

/// Which pictures are in Clean View. The presenter owns the clean state; the
/// picture's overlays (name, tally, REC, tool chips) read it here so Clean View
/// hides them too. Fixtures never set it, so their pictures stay decorated.
@MainActor @Observable final class UICleanViewState {
  static let shared = UICleanViewState()
  private(set) var clean: Set<String> = []
  func set(_ isClean: Bool, for targetID: String) {
    if isClean { clean.insert(targetID) } else { clean.remove(targetID) }
  }
}

/// Monitor settings stored per camera by the MonitorCoordinator.
@MainActor struct UIAppMonitorSettings: UIMonitorSettingsProviding {
  let model: AppModel
  func configuration(for cameraID: String) -> MonitorConfiguration {
    model.monitorCoordinator.configuration(for: MonitorTargetID(cameraID))
  }
  func setConfiguration(_ configuration: MonitorConfiguration, for cameraID: String) {
    model.monitorCoordinator.setConfiguration(configuration, for: MonitorTargetID(cameraID))
  }
}

/// Owns one surface identity for the lifetime of the picture.
private struct UIAppLivePicture: View {
  let model: AppModel
  @ObservedObject var coordinator: MonitorCoordinator
  let cameraID: String
  let compact: Bool
  @State private var surfaceID = UUID()

  var body: some View {
    let target = MonitorTargetID(cameraID)
    UIAppSurfacePicture(model: model, coordinator: coordinator,
      presenter: coordinator.surface(id: surfaceID, target: target),
      surfaceID: surfaceID, target: target, compact: compact)
      .id(target)
  }
}

private struct UIAppSurfacePicture: View {
  let model: AppModel
  @ObservedObject var coordinator: MonitorCoordinator
  @ObservedObject var presenter: MonitorSurfacePresenter
  let surfaceID: UUID
  let target: MonitorTargetID
  let compact: Bool
  @State private var hovering = false

  private var isProgram: Bool { target.rawValue == "program" }
  private var configuration: MonitorConfiguration { coordinator.configuration(for: target) }
  private var displayConfiguration: MonitorConfiguration { presenter.isFrozen ? presenter.configuration : configuration }
  private var previewEnabled: Bool { coordinator.isPreviewEnabled(for: target) }
  private var scopesShown: Bool {
    previewEnabled && displayConfiguration.toolsEnabled && displayConfiguration.scopes.enabled
  }
  private var guidesShown: Bool {
    displayConfiguration.toolsEnabled && displayConfiguration.guides.enabled && !presenter.isClean
  }

  var body: some View {
    ZStack {
      Color.black
      if !previewEnabled {
        Color.black.overlay { MonitorSurfaceVisibility(presenter: presenter).allowsHitTesting(false) }
      } else {
        ZStack {
          MonitorNativePicture(presenter: presenter)
          if guidesShown {
            MonitorGuideOverlay(settings: displayConfiguration.guides)
              .aspectRatio(presenter.pictureAspectRatio, contentMode: .fit)
              .allowsHitTesting(false)
          }
        }
      }
      if scopesShown && !compact && !presenter.isClean {
        VStack {
          Spacer(minLength: 0)
          MonitorNativeScope(presenter: presenter)
            .overlay { MonitorScopeGraticule(showGrid: displayConfiguration.scopes.graticule) }
            .frame(maxWidth: .infinity)
            .frame(height: 96)
            .background(Color.black.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 10).padding(.bottom, 40)
            .accessibilityLabel(displayConfiguration.scopes.mode == .rgbParade ? "RGB parade" : "Luma waveform")
        }
      }
    }
    .overlay(alignment: .topTrailing) {
      // Program's tool bar lives with its picture (camera pictures draw theirs in the overlay).
      // Always shown, so the tools can be found; Clean View hides it until hover.
      if isProgram && !compact && previewEnabled && (hovering || !presenter.isClean) {
        UIMonitorToolButtons(targetID: target.rawValue, name: "Program",
          activeTools: UIMonitorTool.allCases.filter { UIMonitorBridge.activeTools(configuration).contains($0) },
          isProgram: true,
          toggle: { [coordinator, target] tool in UIMonitorBridge.toggle(tool, for: target.rawValue, coordinator: coordinator) },
          monitor: UIAppMonitorSettings(model: model))
          .padding(10)
      }
    }
    .clipped()
    .onHover { hovering = $0 }
    .onAppear {
      register()
      if !isProgram && !compact { UIMonitorBridge.register(presenter, cameraID: target.rawValue) }
      if !compact { UICleanViewState.shared.set(presenter.isClean, for: target.rawValue) }
    }
    .onDisappear {
      coordinator.unregisterSurface(id: surfaceID, target: target)
      UIMonitorBridge.unregister(cameraID: target.rawValue, presenter: presenter)
      if !compact { UICleanViewState.shared.set(false, for: target.rawValue) }
    }
    .onChange(of: presenter.isClean) { _, isClean in
      if !compact { UICleanViewState.shared.set(isClean, for: target.rawValue) }
    }
    .onChange(of: previewEnabled) { _, _ in register() }
    .onChange(of: presenter.isFreezePending) { _, _ in register() }
    .onChange(of: presenter.isFrozen) { _, _ in register() }
    .onChange(of: configuration.scopes.enabled) { _, _ in register() }
    .onChange(of: configuration.toolsEnabled) { _, _ in register() }
  }

  private func register() {
    // One Metal picture path for every surface; nothing uses the native preview.
    if !isProgram && !compact { UIMonitorBridge.setUsesNativePreview(false, cameraID: target.rawValue) }
    coordinator.registerSurface(
      id: surfaceID, target: target, isVisible: previewEnabled,
      scopeVisible: configuration.toolsEnabled && configuration.scopes.enabled && !presenter.isFrozen
        && previewEnabled && !compact)
  }
}
