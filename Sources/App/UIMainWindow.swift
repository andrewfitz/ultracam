import SwiftUI

/// Main window content: session sidebar, camera columns by layout, on-demand
/// inspector and the status bar. Every change goes through `context.send`.
struct UIMainWindowView: View {
  let context: UIContext
  /// Measured channel-strip height per camera, so the pictures are fitted to what the strips
  /// really take (the strip's height changes with its contents and when it collapses).
  @State private var stripHeights: [String: CGFloat] = [:]
  /// What the side columns' bindings read (see `columnVisibility`).
  @State private var columns = UIColumnState()

  /// Space between a picture and its strip (`UICameraColumnView`), between grid cells,
  /// and around the pictures (clear of the sidebar, inspector and window edges).
  private let columnSpacing: CGFloat = 10
  private let cellSpacing = UIPictureSpacing.gutter
  private let margin = UIPictureSpacing.margin

  var body: some View {
    let _ = columns.update(from: context.session)
    NavigationSplitView(columnVisibility: columnVisibility) {
      UISessionSidebarView(context: context)
        .navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 300)
    } detail: {
      detail
        .safeAreaInset(edge: .bottom, spacing: 0) {
          UIStatusBarView(context: context)
        }
        // With both side columns open on a narrow window the pictures get squeezed and the
        // inspector is pushed past the window edge, so close the column opened earlier.
        // (A minimum width here makes AppKit loop on the split view's size constraints.)
        .onGeometryChange(for: Bool.self) { $0.size.width < 480 } action: { squeezed in
          if squeezed { context.send(.makeRoomForPictures) }
        }
    }
    // Opening the inspector otherwise draws a hard line under the title bar across the
    // pictures only; content scrolling under the toolbar gets the system's soft edge instead.
    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    .navigationTitle(context.presentation.title)
    .navigationSubtitle(context.presentation.subtitle)
    .inspector(isPresented: inspectorBinding) {
      UIInspectorView(context: context)
        .inspectorColumnWidth(min: 280, ideal: 320, max: 460)
    }
    .confirmationDialog(confirmationTitle, isPresented: confirmationBinding, titleVisibility: .visible) {
      Button(confirmationButton, role: .destructive) { context.confirm() }
      Button("Cancel", role: .cancel) { context.cancelConfirmation() }
    } message: {
      Text(context.confirmation?.message ?? "")
    }
    // The one rename prompt; the strip, inspector and Camera menu only ask for it.
    .uiRenameAlert(context)
    // 680 pt is the window minimum; the content sits below the ~52 pt toolbar.
    .frame(minWidth: 980, minHeight: 620)
  }

  // MARK: Detail

  @ViewBuilder private var detail: some View {
    let cameras = context.presentation.cameras
    if cameras.isEmpty {
      ContentUnavailableView {
        Label("No Cameras", systemImage: "video.slash")
      } description: {
        Text("Add a camera, then choose its UltraStudio input.")
      } actions: {
        Button("Add Camera") { context.send(.addCamera) }
          .disabled(!context.session.canEditTopology)
      }
    } else {
      switch context.presentation.layout {
      case .programView:
        UIProgramView(context: context)
      case .single:
        if let camera = context.presentation.selected ?? cameras.first {
          // Size the picture so the picture and its strip fit the window height.
          GeometryReader { proxy in
            let fitted = (proxy.size.height - stripHeight(camera) - columnSpacing - margin * 2) * 16 / 9
            // Never wider than the column; a short window scrolls rather than shrinking it below 420 pt.
            let width = min(proxy.size.width - margin * 2, max(420, fitted))
            ScrollView {
              column(camera)
                .frame(width: width)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .contentMargins(margin, for: .scrollContent)
          }
        }
      case .sideBySide, .fourUp:
        // Fit the cells to the height as well as the width, so every picture and its strip
        // (collapsed in Four Up) is on screen at the default window size.
        GeometryReader { proxy in
          let width = cellWidth(in: proxy.size, cameras: cameras)
          ScrollView {
            Group {
              if cameras.count <= 2 && context.presentation.layout == .sideBySide {
                HStack(alignment: .top, spacing: cellSpacing) {
                  ForEach(cameras) { camera in
                    column(camera).frame(width: width)
                  }
                }
              } else {
                Grid(horizontalSpacing: cellSpacing, verticalSpacing: cellSpacing) {
                  ForEach(Array(stride(from: 0, to: cameras.count, by: 2)), id: \.self) { start in
                    GridRow(alignment: .top) {
                      column(cameras[start]).frame(width: width)
                      if start + 1 < cameras.count {
                        column(cameras[start + 1]).frame(width: width)
                      } else {
                        Color.clear.frame(width: width, height: 1)
                      }
                    }
                  }
                }
              }
            }
            .frame(maxWidth: .infinity)
          }
          .scrollBounceBehavior(.basedOnSize)
          .contentMargins(margin, for: .scrollContent)
        }
      }
    }
  }

  // MARK: Fitting

  /// A camera's picture and strip. Reports the strip's height (the column minus its 16:9 picture).
  private func column(_ camera: UICameraPresentation) -> some View {
    UICameraColumnView(camera: camera, context: context)
      .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
        // Round and ignore sub-point changes so fitting the width to the strip can't oscillate.
        let rounded = max(0, (size.height - size.width * 9 / 16 - columnSpacing).rounded())
        if abs((stripHeights[camera.id] ?? -1) - rounded) >= 1 { stripHeights[camera.id] = rounded }
      }
  }

  /// The measured strip height, or an estimate until the first layout pass.
  private func stripHeight(_ camera: UICameraPresentation) -> CGFloat {
    stripHeights[camera.id] ?? (camera.collapsed ? 56 : 190)
  }

  /// The widest cell that fits two columns across and every row (picture and strip) down.
  private func cellWidth(in size: CGSize, cameras: [UICameraPresentation]) -> CGFloat {
    let rows = CGFloat((cameras.count + 1) / 2)
    let strip = cameras.map(stripHeight).max() ?? 0
    let byWidth = (size.width - margin * 2 - cellSpacing) / 2
    let rowHeight = (size.height - margin * 2 - cellSpacing * (rows - 1)) / rows
    let byHeight = (rowHeight - strip - columnSpacing) * 16 / 9
    // A short window scrolls rather than shrinking cells below what their strips need
    // (an expanded strip's controls don't fit under about 400 pt and would spill out of the cell).
    let narrowest: CGFloat = cameras.contains { !$0.collapsed } ? 400 : 260
    return max(0, min(byWidth, max(narrowest, byHeight))).rounded(.down)
  }

  // MARK: Bindings

  private var columnVisibility: Binding<NavigationSplitViewVisibility> {
    // Showing the sidebar is always the user's choice, whatever the window width.
    // The split view keeps the first binding it gets, so it reads the live state in `columns`,
    // not this view's copy. The split view and inspector read these on every frame of their
    // animations, so they must be cheap: `context.current` rebuilt the whole session each time.
    let columns = columns
    return Binding(
      get: { columns.sidebarVisible ? .all : .detailOnly },
      set: { value in
        columns.sidebarVisible = value != .detailOnly
        context.send(.setSidebarVisible(value != .detailOnly))
      })
  }

  private var inspectorBinding: Binding<Bool> {
    let columns = columns
    return Binding(
      get: { columns.inspectorOpen },
      // Set, never toggle: SwiftUI may echo the current value back through the binding.
      set: { open in
        columns.inspectorOpen = open
        context.send(.setInspectorOpen(open))
      })
  }

  private var confirmationBinding: Binding<Bool> {
    Binding(
      get: { context.confirmation != nil },
      // Dismissal (Escape, clicking away) clears the pending action after the buttons
      // have run, so the destructive button never loses its action to the dismissal.
      set: { presented in
        guard !presented else { return }
        let cancel = context.cancelConfirmation
        DispatchQueue.main.async { cancel() }
      })
  }

  private var confirmationTitle: String {
    switch context.confirmation?.action {
    case .stopCamera(let id): return "Stop \(context.camera(id)?.name ?? "Camera")?"
    case .stopAllCameras: return "Stop All Cameras?"
    case .removeCamera(let id): return "Remove \(context.camera(id)?.name ?? "Camera")?"
    case .resetAllSettings: return "Reset All Settings?"
    default: return "Are you sure?"
    }
  }

  private var confirmationButton: String {
    switch context.confirmation?.action {
    case .stopCamera: return "Stop Camera"
    case .stopAllCameras: return "Stop All Cameras"
    case .removeCamera: return "Remove Camera"
    case .resetAllSettings: return "Reset and Quit"
    default: return "Continue"
    }
  }
}

/// The side columns' visibility for their bindings: set at once by the bindings, and taken
/// from the session whenever the session's value changes, so a getter that runs before the
/// next update (or on every animation frame) reads the current value without rebuilding the
/// session. A body update with an older session (from this view's own state) changes nothing.
@MainActor private final class UIColumnState {
  var sidebarVisible = true
  var inspectorOpen = false
  private var seen: (sidebar: Bool, inspector: Bool)?

  func update(from session: UISessionSnapshot) {
    if seen?.sidebar != session.sidebarVisible { sidebarVisible = session.sidebarVisible }
    if seen?.inspector != session.inspectorOpen { inspectorOpen = session.inspectorOpen }
    seen = (session.sidebarVisible, session.inspectorOpen)
  }
}
