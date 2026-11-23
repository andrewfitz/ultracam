import SwiftUI

/// Main window content: camera columns by layout, the on-demand inspector beside them, and
/// the status bar under both. There is no left pane: the pictures are the camera list, the
/// status bar reports the session and Record's popover sets up recording. The inspector is a
/// panel of the content, not the system's column: it starts under the toolbar and ends above
/// the status bar, which runs the window's full width. Every change goes through `context.send`.
struct UIMainWindowView: View {
  let context: UIContext
  /// Measured channel-strip height per camera, so the pictures are fitted to what the strips
  /// really take (the strip's height changes with its contents and when it collapses).
  @State private var stripHeights: [String: CGFloat] = [:]
  /// The detail's size once it stops changing (see `UISettledSize`).
  @State private var settled = UISettledSize()
  /// Whether the cells have been shown: once the detail's size has settled and every shown
  /// strip has been measured, so the first layout seen is the real one (see `revealIfMeasured`).
  @State private var revealed = false

  /// Space between a picture and its strip (`UICameraColumnView`), between grid cells,
  /// and around the pictures (clear of the inspector and window edges).
  private let columnSpacing: CGFloat = 10
  private let cellSpacing = UIPictureSpacing.gutter
  private let margin = UIPictureSpacing.margin

  var body: some View {
    let _ = UIRenderProbe.count("UIMainWindowView")
    HStack(spacing: 0) {
      detail.frame(maxWidth: .infinity, maxHeight: .infinity)
      if context.session.inspectorOpen { UIInspectorPanel(context: context) }
    }
    // Under the pictures and the inspector alike: the inspector doesn't push it aside.
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: 0) {
        if context.presentation.programAvailable { UIProgramSwitchBar(context: context) }
        UIStatusBarView(context: context)
      }
    }
    // No hard line under the title bar: content scrolling under the toolbar gets the system's
    // soft edge instead.
    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    // The title stays for the Window menu, Mission Control and VoiceOver, but isn't drawn:
    // it cost the toolbar 100 pt to repeat the status bar.
    .navigationTitle(context.presentation.title)
    .toolbar(removing: .title)
    // Under 1100 pt switching and monitor controls use their compact layout.
    .onGeometryChange(for: Bool.self) { $0.size.width < 1100 } action: { context.send(.setNarrowWindow($0)) }
    // The Interrupted Takes sheet, from Record's popover and the Record menu.
    .sheet(isPresented: Binding(get: { context.session.interruptedTakesOpen },
      set: { if !$0 { context.send(.hideInterruptedTakes) } })) {
      UIInterruptedTakesSheet(context: context.current)
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
        Label("No Cameras", systemImage: UISymbol.noCameras)
      } description: {
        Text("Add a camera, then choose its input device.")
      } actions: {
        Button("Add Camera") { context.send(.addCamera) }
          .disabled(!context.session.canAddCamera)
      }
    } else {
      switch context.presentation.layout {
      case .programView:
        UIProgramView(context: context)
      case .single:
        if let camera = context.presentation.selected ?? cameras.first {
          // Size the picture so the picture and its strip fit the window height.
          cells(singleFit(camera)) { width in column(camera).id(camera.id).frame(width: width) }
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
    let ready = settled.value != nil
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
      // (the inspector opening) it keeps the settled width and overhangs, centered. This frame
      // takes the detail's live size on every frame of the animation, and the scale reads it
      // there. Scaling the cells inside instead cost more: the scroll view's visible bounds lag
      // the animation.
      .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
      .visualEffect { content, proxy in
        // Before the first settled size the cells are hidden, at their own size.
        let scale = ready ? fit.scale(laidOut: width, live: proxy.size) : 1
        UIRenderProbe.sample("cells scale", scale)
        return content.scaleEffect(scale, anchor: .top)
      }
    }
    .onGeometryChange(for: CGSize.self) { $0.size } action: {
      settled.changed(to: $0)
      revealIfMeasured()
    }
    // Hidden until laid out at the real size and strip heights: at startup they were first
    // fitted to a placeholder size and guessed strips, scaled, then refitted, a flash of garble.
    .opacity(revealed ? 1 : 0)
    .allowsHitTesting(revealed)
    .accessibilityHidden(!revealed)
    .task {
      // Never hidden for long, whatever the measurements do.
      guard !revealed else { return }
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled else { return }
      revealed = true
    }
  }

  /// Shows the cells once the size has settled and every shown camera's strip is measured.
  private func revealIfMeasured() {
    guard !revealed, settled.value != nil else { return }
    let cameras = context.presentation.cameras
    let shown: [UICameraPresentation]
    switch context.presentation.layout {
    case .programView: shown = []
    case .single: shown = (context.presentation.selected ?? cameras.first).map { [$0] } ?? []
    case .sideBySide, .fourUp: shown = cameras
    }
    if shown.allSatisfy({ stripHeights[$0.id] != nil }) { revealed = true }
  }

  // MARK: Fitting

  /// A camera's picture and strip. Reports the strip's height (the column minus its 16:9 picture).
  private func column(_ camera: UICameraPresentation) -> some View {
    UICameraColumnView(camera: camera, context: context)
      .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
        // Round and ignore sub-point changes so fitting the width to the strip can't oscillate.
        let rounded = max(0, (size.height - size.width * 9 / 16 - columnSpacing).rounded())
        if abs((stripHeights[camera.id] ?? -1) - rounded) >= 1 { stripHeights[camera.id] = rounded }
        revealIfMeasured()
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
    // (an expanded strip's controls don't fit under about 400 pt and would spill out of the cell;
    // a collapsed one carrying Four Up's 64 pt Cut slot needs about 340 pt for its name and state).
    let cutSlot = context.presentation.layout == .fourUp && context.presentation.programAvailable
    return UIDetailFit(columns: 2, rows: (cameras.count + 1) / 2, strip: cameras.map(stripHeight).max() ?? 0,
      narrowest: cameras.contains { !$0.collapsed } ? 400 : cutSlot ? 340 : 260, margin: margin, cellSpacing: cellSpacing,
      columnSpacing: columnSpacing)
  }

  /// The measured strip height, or an estimate until the first layout pass.
  private func stripHeight(_ camera: UICameraPresentation) -> CGFloat {
    stripHeights[camera.id] ?? (camera.collapsed ? 56 : 192)
  }
}

/// The inspector as a panel of the window's content, beside the pictures. The system's
/// inspector column runs the window's full height: behind the toolbar's controls at the top,
/// and beside the status bar, which it pushes aside. This one sits between the two. It opens
/// and closes at once, and the pictures refit as they do for any change of the detail's size.
/// Its leading edge drags to resize it.
struct UIInspectorPanel: View {
  let context: UIContext
  /// Its width, kept across launches.
  @AppStorage("ui.inspector.width") private var storedWidth = UIInspectorPanel.defaultWidth
  /// The width while its edge is dragged; kept when the drag ends.
  @State private var dragWidth: Double?
  @State private var dragStart: Double?

  /// 280 pt fits every row; past 460 pt the pictures lose more than the form gains.
  static let widths = 280.0...460.0
  static let defaultWidth = 320.0

  private var width: Double {
    let proposed = dragWidth ?? storedWidth
    guard proposed.isFinite else { return Self.defaultWidth }
    return min(max(proposed, Self.widths.lowerBound), Self.widths.upperBound)
  }

  var body: some View {
    HStack(spacing: 0) {
      Divider()
      UIInspectorView(context: context)
        .frame(width: width)
    }
    // The form's grouped background, to the panel's edges; opaque with Reduce Transparency.
    .background(.bar)
    // Inside the content's safe area: none of it shows behind the toolbar.
    .clipped()
    .overlay(alignment: .leading) { resizeHandle }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Inspector")
  }

  private var resizeHandle: some View {
    Color.clear.frame(width: 8).contentShape(Rectangle())
      .pointerStyle(.frameResize(position: .leading))
      .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
        .onChanged { value in
          let start = dragStart ?? width
          dragStart = start
          dragWidth = start - value.translation.width
        }
        .onEnded { _ in
          storedWidth = width
          dragWidth = nil
          dragStart = nil
        })
      .accessibilityRepresentation {
        Stepper("Inspector width", value: Binding(get: { width }, set: { storedWidth = $0 }), in: Self.widths, step: 20)
          .accessibilityValue("\(Int(width.rounded())) points")
      }
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

  /// Under this the size is the split view still setting up (zero, or a sliver), never one to
  /// lay out at: cells fitted to it were about 1 pt wide and then scaled up.
  static let smallest: CGFloat = 100

  func changed(to size: CGSize) {
    guard size.width >= Self.smallest, size.height >= Self.smallest else { return }
    pending?.cancel()
    // The first real size is adopted at once, so the first layout is the real one.
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
