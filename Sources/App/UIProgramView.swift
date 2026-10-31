import SwiftUI

/// Program View: the Program picture (what the virtual camera sends) beside the sources, each
/// with a full-width Cut, then collapsed strips anchored at the bottom. Spare height goes to
/// Program, by narrowing the source column. Cuts, Auto and Hold are the toolbar's; the shot
/// timer and recent cuts are in the status bar and its Program popover.
struct UIProgramView: View {
  let context: UIContext

  private var session: UISessionSnapshot { context.session }
  private var onAir: UICameraSnapshot? { session.cameras.first { $0.id == session.onAirID } }

  var body: some View {
    let _ = UIRenderProbe.count("UIProgramView")
    VStack(alignment: .leading, spacing: UIPictureSpacing.gutter) {
      UIProgramRowLayout(gutter: UIPictureSpacing.gutter) {
        programPicture
        VStack(spacing: 12) {
          ForEach(context.presentation.cameras) { camera in
            source(camera)
          }
        }
      }
      // The height left over goes to Program; the strips stay anchored at the bottom.
      .frame(maxHeight: .infinity, alignment: .top)
      VStack(spacing: 8) {
        ForEach(context.presentation.cameras) { camera in
          UIChannelStripView(camera: camera, context: context)
        }
      }
    }
    .padding(UIPictureSpacing.margin)
  }

  private var programTally: UITally {
    context.presentation.cameras.first { $0.id == session.onAirID }?.tally ?? .none
  }

  private var programPicture: some View {
    let tally = programTally
    return context.pictures.programPicture()
      .aspectRatio(16 / 9, contentMode: .fit)
      .clipShape(RoundedRectangle(cornerRadius: 14))
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
          UIMonitorToolButtons(targetID: MonitorFeedHost.programTarget, name: "Program",
            activeTools: UIMonitorTool.allCases.filter { UIMonitorBridge.activeTools(context.monitor.preferences(for: MonitorFeedHost.programTarget)).contains($0) },
            isProgram: true, toggle: { context.send(.toggleTool(cameraID: MonitorFeedHost.programTarget, $0)) },
            monitor: context.monitor)
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
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Program, \(onAir?.name ?? "no camera") \(tally == .onAir ? "on air" : "selected")")
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

/// Program and its sources side by side. Program is as large as the height allows; the source
/// column takes the rest of the width, between its narrowest and widest.
struct UIProgramRowLayout: Layout {
  var gutter: CGFloat
  static let sourceWidth: ClosedRange<CGFloat> = 220...320

  private func widths(_ width: CGFloat, height: CGFloat?) -> (program: CGFloat, sources: CGFloat) {
    let byHeight = height.map { $0 * 16 / 9 } ?? .infinity
    let program = max(320, min(width - gutter - Self.sourceWidth.lowerBound, byHeight))
    let sources = min(Self.sourceWidth.upperBound, max(Self.sourceWidth.lowerBound, width - gutter - program))
    return (min(program, width - gutter - sources), sources)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 1000
    let split = widths(width, height: proposal.height)
    let sources = subviews.count > 1 ? subviews[1].sizeThatFits(ProposedViewSize(width: split.sources, height: nil)).height : 0
    return CGSize(width: width, height: max(split.program * 9 / 16, sources))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let split = widths(bounds.width, height: proposal.height)
    guard subviews.count == 2 else { return }
    subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: split.program, height: split.program * 9 / 16))
    subviews[1].place(at: CGPoint(x: bounds.maxX - split.sources, y: bounds.minY),
      proposal: ProposedViewSize(width: split.sources, height: nil))
  }

  func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
    subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

  func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
    subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
}
