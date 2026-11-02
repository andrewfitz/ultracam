import MonitorKit
import MonitorKitUI
import SwiftUI

/// Live pictures for the app. Every picture (cameras, Program, the menu bar) is a
/// monitor surface: a Metal layer MonitorKit draws every camera frame into on the
/// display refresh, with any tools (guides included) in the same pass. Hidden or
/// occluded pictures do no GPU work.
@MainActor struct UIAppPictures: UIPictureProviding {
  let model: AppModel
  /// `compact` is the menu bar preview: no scopes and no tool chrome.
  func picture(cameraID: String, compact: Bool, zoom: Double) -> AnyView {
    AnyView(UIAppLivePicture(model: model, coordinator: model.monitorCoordinator, cameraID: cameraID,
      compact: compact, zoom: zoom))
  }
  func programPicture() -> AnyView {
    AnyView(UIAppLivePicture(model: model, coordinator: model.monitorCoordinator, cameraID: "program",
      compact: false, zoom: 1))
  }
}

/// Which pictures are in Clean View, and which are frozen. The presenter owns both; the
/// picture's overlays (name, tally, REC, tools, the Frozen pill) read them here. Fixtures
/// set them only to render those states.
@MainActor @Observable final class UICleanViewState {
  static let shared = UICleanViewState()
  private(set) var clean: Set<String> = []
  /// Pictures held by Freeze: they look live at rest, so the picture says so.
  private(set) var frozen: Set<String> = []
  func set(_ isClean: Bool, for targetID: String) {
    if isClean { clean.insert(targetID) } else { clean.remove(targetID) }
  }
  func setFrozen(_ isFrozen: Bool, for targetID: String) {
    if isFrozen != frozen.contains(targetID) {
      if isFrozen { frozen.insert(targetID) } else { frozen.remove(targetID) }
    }
  }
}

/// Monitor settings stored per camera by the MonitorCoordinator.
@MainActor struct UIAppMonitorSettings: UIMonitorSettingsProviding {
  let model: AppModel
  func preferences(for cameraID: String) -> MonitorFeedPreferences {
    model.monitorCoordinator.preferences(for: MonitorTargetID(cameraID))
  }
  func setPreferences(_ preferences: MonitorFeedPreferences, for cameraID: String) {
    model.monitorCoordinator.setPreferences(preferences, for: MonitorTargetID(cameraID))
  }
  func monitorLUTState(for cameraID: String) -> MonitorFeedHost.MonitorLUTState {
    model.monitorCoordinator.monitorLUTState(for: MonitorTargetID(cameraID))
  }
  func scopeMeasurement(for cameraID: String) -> (signal: SignalDescription?, stageLUT: Bool) {
    model.monitorCoordinator.scopeMeasurement(for: MonitorTargetID(cameraID))
  }
}

extension Magnification {
  /// A zoom about the picture's centre, without MonitorKit's navigator (the app's
  /// zoom is a centre crop, as it always was).
  static func centered(zoom: Double) -> Magnification {
    var value = Magnification()
    value.zoom = zoom.isFinite ? min(8, max(1, zoom)) : 1
    value.showsNavigator = false
    return value
  }
}

/// Owns one surface identity for the lifetime of the picture.
private struct UIAppLivePicture: View {
  let model: AppModel
  @ObservedObject var coordinator: MonitorCoordinator
  let cameraID: String
  let compact: Bool
  let zoom: Double
  @State private var surfaceID = UUID()

  var body: some View {
    let target = MonitorTargetID(cameraID)
    UIAppSurfacePicture(model: model, coordinator: coordinator,
      presenter: coordinator.surface(id: surfaceID, target: target),
      surfaceID: surfaceID, target: target, compact: compact, zoom: zoom)
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
  let zoom: Double
  @Environment(\.openWindow) private var openWindow

  private var isProgram: Bool { target.isProgram }
  private var preferences: MonitorFeedPreferences { coordinator.preferences(for: target) }
  private var displayed: MonitorFeedPreferences { presenter.isFrozen ? presenter.shownPreferences : preferences }
  private var previewEnabled: Bool { coordinator.isPreviewEnabled(for: target) }
  private var scopesShown: Bool { previewEnabled && displayed.scopesShown }

  var body: some View {
    let _ = UIRenderProbe.count("UIAppSurfacePicture")
    ZStack {
      Color.black
      if !previewEnabled {
        Color.black.overlay { MonitorSurfaceVisibility(presenter: presenter).allowsHitTesting(false) }
      } else {
        MonitorNativePicture(presenter: presenter)
      }
      if scopesShown && !compact && !presenter.isClean && !UIScopePopOuts.shared.open.contains(target.rawValue) {
        // MonitorKit draws the scope and its graticule at the card's size; the labels are SwiftUI.
        GeometryReader { geometry in
          UIScopeCard(description: UIScopeDescription(scopes: displayed.scopes, signal: presenter.shownSignal,
            stageLUT: presenter.scopeMeasuresLUT(displayed), isProgram: isProgram),
            size: geometry.size,
            onPopOut: { openWindow(id: UIScopeWindow.id, value: target.rawValue) },
            onHide: {
              coordinator.setPreferences(UIMonitorBridge.toggled(.scopes, in: preferences, isProgram: isProgram),
                for: target)
            }
          ) {
            MonitorNativeScope(presenter: presenter)
          }
        }
      }
    }
    // Every picture's tool bar is in its overlays (Program's in UIProgramPictureView), not here.
    .clipped()
    .onAppear {
      presenter.setMagnification(.centered(zoom: zoom))
      register()
      if !compact { UIMonitorBridge.register(presenter, cameraID: target.rawValue) }
      if !compact { UICleanViewState.shared.set(presenter.isClean, for: target.rawValue) }
    }
    .onDisappear {
      coordinator.unregisterSurface(id: surfaceID, target: target)
      UIMonitorBridge.unregister(cameraID: target.rawValue, presenter: presenter)
      if !compact {
        UICleanViewState.shared.set(false, for: target.rawValue)
        UICleanViewState.shared.setFrozen(false, for: target.rawValue)
      }
    }
    .onChange(of: zoom) { _, value in presenter.setMagnification(.centered(zoom: value)) }
    .onChange(of: presenter.isClean) { _, isClean in
      if !compact { UICleanViewState.shared.set(isClean, for: target.rawValue) }
    }
    .onChange(of: presenter.isFrozen) { _, isFrozen in
      if !compact { UICleanViewState.shared.setFrozen(isFrozen, for: target.rawValue) }
    }
    .onChange(of: previewEnabled) { _, _ in register() }
    .onChange(of: presenter.isFreezePending) { _, _ in register() }
    .onChange(of: presenter.isFrozen) { _, _ in register() }
    .onChange(of: preferences.scopesShown) { _, _ in register() }
  }

  private func register() {
    coordinator.registerSurface(
      id: surfaceID, target: target, isVisible: previewEnabled,
      scopeVisible: preferences.scopesShown && !presenter.isFrozen && previewEnabled && !compact)
  }
}
