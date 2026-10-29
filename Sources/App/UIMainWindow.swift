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
  /// The detail's size once it stops changing (see `UISettledSize`).
  @State private var settled = UISettledSize()

  /// Space between a picture and its strip (`UICameraColumnView`), between grid cells,
  /// and around the pictures (clear of the sidebar, inspector and window edges).
  private let columnSpacing: CGFloat = 10
  private let cellSpacing = UIPictureSpacing.gutter
  private let margin = UIPictureSpacing.margin

  var body: some View {
    let _ = UIRenderProbe.count("UIMainWindowView")
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
      // Laid out at least at the column's minimum width: while the column opens or closes the
      // form keeps that layout and is revealed, instead of laying out every row at every frame.
      UIMinimumWidthLayout(minimum: 280) { UIInspectorView(context: context) }
        .clipped()
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
        Text("Add a camera, then choose its input device.")
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
          cells(singleFit(camera)) { width in column(camera).frame(width: width) }
        }
      case .sideBySide, .fourUp:
        // Fit the cells to the height as well as the width, so every picture and its strip
        // (collapsed in Four Up) is on screen at the default window size.
        cells(gridFit(cameras)) { width in
          // Two cells to a row, top-aligned (Side by Side is one row of two).
          UICellRowsLayout(spacing: cellSpacing) {
            ForEach(cameras) { camera in
              column(camera).frame(width: width)
            }
          }
        }
      }
    }
  }

  /// The cells at the width `fit` gives the detail's settled size, centered in a scroll view.
  /// While the detail's size changes (a side column animating, a live resize) they keep that
  /// layout and the scroll view scales, larger or smaller, so the cells are as wide as `fit`
  /// gives the live size: in the render pass alone, so no body is evaluated and nothing is laid
  /// out again until the size settles (`UISettledSize`), and then at the size they were shown at.
  private func cells(_ fit: UIDetailFit, @ViewBuilder content: (CGFloat) -> some View) -> some View {
    let width = fit.width(in: settled.size)
    // In an overlay, so the cells' width never becomes the detail's ideal size (the split view
    // turns that into constraints, and changing it from its own size loops).
    return Color.clear.overlay {
      ScrollView {
        content(width)
          .frame(maxWidth: .infinity)
      }
      .scrollBounceBehavior(.basedOnSize)
      .contentMargins(margin, for: .scrollContent)
      // A vertical scroll view is never narrower than its content, so while the detail narrows
      // (the sidebar opening) it keeps the settled width and overhangs, centered. This frame takes
      // the detail's live size on every frame of the animation (on macOS 26 the sidebar floats
      // over the detail and animates its safe area), and the scale reads it there. Scaling the
      // cells inside instead cost more: the scroll view's visible bounds lag the animation.
      .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
      .visualEffect { content, proxy in
        let scale = fit.scale(laidOut: width, live: proxy.size)
        UIRenderProbe.sample("cells scale", scale)
        return content.scaleEffect(scale, anchor: .top)
      }
    }
    .onGeometryChange(for: CGSize.self) { $0.size } action: { settled.changed(to: $0) }
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

  /// The single layout: the picture and its strip fit the window height.
  private func singleFit(_ camera: UICameraPresentation) -> UIDetailFit {
    UIDetailFit(columns: 1, rows: 1, strip: stripHeight(camera), narrowest: 420, margin: margin, cellSpacing: cellSpacing,
      columnSpacing: columnSpacing)
  }

  /// The widest cell that fits two columns across and every row (picture and strip) down.
  private func gridFit(_ cameras: [UICameraPresentation]) -> UIDetailFit {
    // A short window scrolls rather than shrinking cells below what their strips need
    // (an expanded strip's controls don't fit under about 400 pt and would spill out of the cell).
    UIDetailFit(columns: 2, rows: (cameras.count + 1) / 2, strip: cameras.map(stripHeight).max() ?? 0,
      narrowest: cameras.contains { !$0.collapsed } ? 400 : 260, margin: margin, cellSpacing: cellSpacing,
      columnSpacing: columnSpacing)
  }

  /// The measured strip height, or an estimate until the first layout pass.
  private func stripHeight(_ camera: UICameraPresentation) -> CGFloat {
    stripHeights[camera.id] ?? (camera.collapsed ? 56 : 190)
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

/// The detail's size, adopted once it has stopped changing for a moment. Every frame of a side
/// column's animation (or a live window resize) changed the cells' widths, and laying out every
/// picture, strip and control again took longer than a frame. Until the size settles the cells
/// keep their layout and scale (`cells(_:content:)`), as the Metal pictures keep their drawables.
@MainActor @Observable final class UISettledSize {
  private(set) var value: CGSize?
  @ObservationIgnored private var pending: DispatchWorkItem?
  /// How long the size must hold still: a little more than a frame of a live resize's gaps.
  private static let delay = 0.12

  /// The size to lay out at: the settled one, or a typical one before the first.
  var size: CGSize { value ?? CGSize(width: 1000, height: 700) }

  func changed(to size: CGSize) {
    pending?.cancel()
    // The first size is adopted at once, so the first layout is the real one.
    guard value != nil else { value = size; return }
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.value != size else { return }
      self.value = size
    }
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
  }
}

/// How wide the detail's cells are for a size: as wide as the columns allow, and no taller than
/// the rows allow, but never under `narrowest` (a short window scrolls instead).
struct UIDetailFit: Sendable {
  var columns: Int
  var rows: Int
  var strip: CGFloat
  var narrowest: CGFloat
  var margin: CGFloat
  var cellSpacing: CGFloat
  var columnSpacing: CGFloat

  func width(in size: CGSize) -> CGFloat {
    let columns = CGFloat(max(1, columns)), rows = CGFloat(max(1, rows))
    let byWidth = (size.width - margin * 2 - cellSpacing * (columns - 1)) / columns
    let rowHeight = (size.height - margin * 2 - cellSpacing * (rows - 1)) / rows
    let byHeight = (rowHeight - strip - columnSpacing) * 16 / 9
    return max(1, min(byWidth, max(narrowest, byHeight)).rounded(.down))
  }

  /// The scale that makes cells laid out `laidOut` wide as wide as `width(in:)` gives the live
  /// size: under 1 while the detail is smaller than its settled size, over 1 while larger, and
  /// exactly 1 at the settled size, so adopting it lays the cells out where they already were.
  func scale(laidOut: CGFloat, live: CGSize) -> CGFloat {
    guard laidOut > 0, live.width > 0, live.height > 0 else { return 1 }
    return min(4, max(0.05, width(in: live) / laidOut))
  }
}

/// Lays its content out at least `minimum` wide, leading-aligned, whatever narrower width it is
/// offered (a column opening or closing); it still takes only the width it's offered.
struct UIMinimumWidthLayout: Layout {
  let minimum: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? minimum
    let height = subviews.first?.sizeThatFits(ProposedViewSize(width: max(width, minimum), height: proposal.height)).height ?? 0
    return CGSize(width: width, height: proposal.height ?? height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for subview in subviews {
      subview.place(at: bounds.origin, proposal: ProposedViewSize(width: max(bounds.width, minimum), height: bounds.height))
    }
  }

  func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
    subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

  func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
    subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
}

/// Cells two to a row, each row as tall as its tallest cell, the cells at their own (fixed)
/// widths and top-aligned. Unlike an HStack or Grid row aligned `.top`, it asks no cell for
/// alignment guides: those queries walked every picture and strip in every layout pass.
struct UICellRowsLayout: Layout {
  var spacing: CGFloat
  var perRow = 2

  private func rows(_ subviews: Subviews) -> [(cells: [(index: Int, size: CGSize)], height: CGFloat)] {
    stride(from: 0, to: subviews.count, by: perRow).map { start in
      let cells = (start..<min(start + perRow, subviews.count)).map { ($0, subviews[$0].sizeThatFits(.unspecified)) }
      return (cells, cells.map(\.1.height).max() ?? 0)
    }
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let rows = rows(subviews)
    let width = rows.map { row in row.cells.map(\.size.width).reduce(0, +) + spacing * CGFloat(max(0, row.cells.count - 1)) }.max() ?? 0
    let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
    return CGSize(width: width, height: height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var y = bounds.minY
    for row in rows(subviews) {
      var x = bounds.minX
      for cell in row.cells {
        subviews[cell.index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(cell.size))
        x += cell.size.width + spacing
      }
      y += row.height + spacing
    }
  }

  func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
    subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

  func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
    subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
}
