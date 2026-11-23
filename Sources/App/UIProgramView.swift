import SwiftUI

/// Program View: the Program picture (what the virtual camera sends) beside the sources, each
/// with a full-width Cut, then collapsed strips anchored at the bottom. Spare height goes to
/// Program, by narrowing the source column. Cuts, Auto and Hold are the toolbar's; the shot
/// timer and recent cuts are in the status bar and its Program popover.
struct UIProgramView: View {
  let context: UIContext

  var body: some View {
    let _ = UIRenderProbe.count("UIProgramView")
    // The height left over goes to Program; the strips stay anchored at the bottom.
    UIProgramColumnLayout(gutter: UIPictureSpacing.gutter) {
      UIProgramRowLayout(gutter: UIPictureSpacing.gutter) {
        UIProgramPictureView(context: context)
        // More sources than the row is tall scroll in their column; Program keeps its size.
        ScrollView {
          VStack(spacing: 12) {
            ForEach(context.presentation.cameras) { camera in
              source(camera)
            }
          }
        }
        .scrollBounceBehavior(.basedOnSize)
      }
      // More strips than leave Program its shortest scroll in their own space.
      ScrollView {
        VStack(spacing: 8) {
          ForEach(context.presentation.cameras) { camera in
            UIChannelStripView(camera: camera, context: context)
          }
        }
      }
      .scrollBounceBehavior(.basedOnSize)
    }
    .padding(UIPictureSpacing.margin)
  }

  /// A source's picture and its Cut. The camera on Program keeps the slot's height with
  /// nothing in it: its ring says it, and nothing moves.
  private func source(_ camera: UICameraPresentation) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      UIColumnPictureLayout {
        UICameraPictureView(camera: camera, context: context, compact: true)
      }
      if let cut = context.presentation.cutButtons.first(where: { $0.id == camera.id }), !cut.onAir {
        UIWideCutButton(cut: cut, context: context)
      } else {
        Color.clear.frame(height: 36).accessibilityHidden(true)
      }
    }
  }
}

/// The Program picture: what the meeting has, with its own tally (never a camera's ISO), its
/// tool bar (the full bar on hover and while one of its popovers is open, as on the cameras'
/// pictures), and the camera on it. Clean View hides the tools until hover.
struct UIProgramPictureView: View {
  let context: UIContext
  @State private var hovering = false
  /// The monitor tool popover open from the bar: it keeps the bar while the pointer is on it.
  @State private var toolPanel: UIMonitorPanel?
  /// Narrow enough that the label row can't hold the full tool bar: it takes its own row.
  @State private var narrow = false
  @State private var singleColumnTools = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var session: UISessionSnapshot { context.session }
  private var target: String { MonitorFeedHost.programTarget }

  var body: some View {
    let tally = context.presentation.programTally
    let onAir = session.cameras.first { $0.id == session.onAirID }
    let placement = UIMonitorToolButtons.Placement(hovering: hovering, panelOpen: toolPanel != nil, narrow: narrow,
      clean: UICleanViewState.shared.clean.contains(target))
    return context.pictures.programPicture()
      .aspectRatio(16 / 9, contentMode: .fit)
      .clipShape(RoundedRectangle(cornerRadius: 14))
      .overlay {
        // Nothing is capturing: say so, as each source's picture does, instead of plain black.
        if !session.cameras.contains(where: \.running) {
          let black = session.stream.phase == .streaming && !session.stream.pictureFresh
          UIPicturePlaceholder(symbol: UISymbol.program, title: black ? "No Program picture" : "Program idle",
            detail: black ? "The stream is sending black. Start Capture to restore video."
              : "Start Capture to send \(onAir?.name ?? "a camera") to Program.")
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
      }
      .overlay {
        // What the meeting has: a picture gone, on air. The way out is here too.
        if tally == .noPicture, let camera = context.presentation.cameras.first(where: { $0.id == session.onAirID }),
          camera.tileState == .signalLost {
          UILiveCamera(camera: camera, context: context, follows: [], refresh: 1) { live in
            UILostSignalPlaceholder(camera: live.camera, context: context)
          }
          .clipShape(RoundedRectangle(cornerRadius: 14))
        }
      }
      .overlay {
        if let color = tally.ringColor {
          RoundedRectangle(cornerRadius: 14).strokeBorder(color, lineWidth: 4).allowsHitTesting(false)
        }
      }
      .overlay(alignment: .top) {
        VStack(spacing: 6) {
          HStack(spacing: 6) {
            HStack(spacing: 4) {
              Image(systemName: UISymbol.program).imageScale(.small)
              Text("Ultracam").foregroundStyle(.white.opacity(0.7)).fontWeight(.regular)
              Text("Program")
            }
            .font(.uiOverlay).uiPictureOverlay()
            .accessibilityElement(children: .combine)
            UITallyBadge(tally: tally)
            Spacer(minLength: 4)
            if !placement.ownRow { tools(placement) }
          }
          // Too narrow for the bar beside the name: on hover it takes its own row, right aligned.
          if placement.ownRow {
            HStack {
              Spacer(minLength: 0)
              tools(placement)
            }
          }
        }
        .padding(10)
      }
      .overlay(alignment: .bottomLeading) {
        HStack(spacing: 6) {
          if let onAir {
            Text(onAir.name).font(.uiOverlay).uiPictureOverlay()
          }
          if let format = onAir?.outputFormat {
            Text(format).font(.uiOverlay.monospacedDigit()).uiPictureOverlay()
          }
          if session.programFormatMismatch {
            Label("Formats converted", systemImage: UISymbol.updating)
              .font(.uiOverlay)
              .uiPictureOverlay()
              .help("Program cameras use different formats. The GPU converts each to the Program camera's format, so cuts don't interrupt the output.")
          }
        }
        .padding(10)
      }
      .onHover { hovering = $0 }
      .onGeometryChange(for: Bool.self) { $0.size.width < UIMonitorToolButtons.ownRowBelow } action: { narrow = $0 }
      .onGeometryChange(for: Bool.self) { $0.size.width < UIMonitorToolButtons.singleColumnPanelsBelow } action: { singleColumnTools = $0 }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovering)
      .accessibilityElement(children: .contain)
      .accessibilityLabel(Self.accessibilityLabel(onAir: onAir?.name, tally: tally))
  }

  @ViewBuilder private func tools(_ placement: UIMonitorToolButtons.Placement) -> some View {
    if placement.shown {
      let active = UIMonitorBridge.activeTools(context.monitor.preferences(for: target))
      UIMonitorToolButtons(targetID: target, name: "Program",
        activeTools: UIMonitorTool.allCases.filter(active.contains),
        isProgram: true, toggle: { [context] in context.send(.toggleTool(cameraID: MonitorFeedHost.programTarget, $0)) },
        monitor: context.monitor, openPanel: $toolPanel, expanded: placement.expanded,
        singleColumnPanels: singleColumnTools)
    }
  }

  /// "Program, Camera 1 on air"; off air, "in Program", or "no picture" while a meeting waits on one.
  static func accessibilityLabel(onAir: String?, tally: UITally) -> String {
    guard let onAir else { return "Program, no camera" }
    switch tally {
    case .onAir: return "Program, \(onAir) on air"
    case .noPicture: return "Program, \(onAir), no picture"
    default: return "Program, \(onAir) in Program"
    }
  }
}

/// The Program row above the strips. The strips take their own height, unless that leaves the
/// row shorter than Program at its narrowest: then they get the rest, and scroll. The row takes
/// what's left. Given no height, both at their own.
struct UIProgramColumnLayout: Layout {
  var gutter: CGFloat
  /// Program at its narrowest (320 pt) is 180 pt tall.
  static let shortestRow: CGFloat = 180

  private func strips(_ subviews: Subviews, width: CGFloat) -> CGFloat {
    subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 1000
    guard subviews.count == 2 else { return CGSize(width: width, height: proposal.height ?? 0) }
    if let height = proposal.height { return CGSize(width: width, height: height) }
    let row = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
    return CGSize(width: width, height: row + gutter + strips(subviews, width: width))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard subviews.count == 2 else { return }
    let shown = min(strips(subviews, width: bounds.width), max(0, bounds.height - gutter - Self.shortestRow))
    let row = max(0, bounds.height - gutter - shown)
    subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: row))
    subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.maxY - shown),
      proposal: ProposedViewSize(width: bounds.width, height: shown))
  }

  func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
    subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

  func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
    subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
}

/// Program and its sources side by side. Program is as large as the height allows; the source
/// column takes the rest of the width, between its narrowest and widest. Given a height, the
/// source column is that tall (it scrolls); given none, as tall as its sources.
struct UIProgramRowLayout: Layout {
  var gutter: CGFloat
  static let sourceWidth: ClosedRange<CGFloat> = 220...320

  private func widths(_ width: CGFloat, height: CGFloat?) -> (program: CGFloat, sources: CGFloat) {
    let byHeight = height.map { $0 * 16 / 9 } ?? .infinity
    let program = max(320, min(width - gutter - Self.sourceWidth.lowerBound, byHeight))
    let available = max(0, width - gutter)
    let sources = min(available, Self.sourceWidth.upperBound, max(Self.sourceWidth.lowerBound, available - program))
    return (min(program, available - sources), sources)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 1000
    let split = widths(width, height: proposal.height)
    if let height = proposal.height { return CGSize(width: width, height: max(split.program * 9 / 16, height)) }
    let sources = subviews.count > 1 ? subviews[1].sizeThatFits(ProposedViewSize(width: split.sources, height: nil)).height : 0
    return CGSize(width: width, height: max(split.program * 9 / 16, sources))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let split = widths(bounds.width, height: proposal.height)
    guard subviews.count == 2 else { return }
    // A wide, short window limits Program by height: keep the pair together, centered.
    let x0 = bounds.minX + max(0, (bounds.width - split.program - gutter - split.sources) / 2)
    subviews[0].place(at: CGPoint(x: x0, y: bounds.minY), proposal: ProposedViewSize(width: split.program, height: split.program * 9 / 16))
    subviews[1].place(at: CGPoint(x: x0 + split.program + gutter, y: bounds.minY),
      proposal: ProposedViewSize(width: split.sources, height: proposal.height == nil ? nil : bounds.height))
  }

  func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
    subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

  func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
    subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
}
