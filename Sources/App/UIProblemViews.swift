import SwiftUI

// The one problem list as views: the row every surface shares, the popover's list and the
// sidebar's pinned Attention. Two levels (ruling 26): solid amber with dark text for
// damage to what's on air or rolling, a wash with a border for everything else.

extension UIProblemLevel {
  var fill: Color { self == .damage ? .orange : Color.orange.opacity(0.08) }
  var border: Color { self == .damage ? .clear : Color.orange.opacity(0.5) }
  /// Dark on the amber fill in both appearances; the system's label color on the wash.
  var text: Color { self == .damage ? Color.black : .primary }
  var secondaryText: Color { self == .damage ? Color.black.opacity(0.75) : .secondary }
  var glyph: Color { self == .damage ? Color.black : .orange }
}

/// A button a problem row offers. Plain, so it stays readable on the amber fill.
struct UIProblemButton: View {
  let action: UIProblemAction
  let level: UIProblemLevel
  let context: UIContext

  var body: some View {
    Button(action.title) { context.send(action.action) }
      .buttonStyle(.plain)
      .font(.uiMeta.weight(.semibold))
      .foregroundStyle(level.text)
      .padding(.horizontal, 8).frame(height: 20)
      .background(level.text.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
      .fixedSize()
  }
}

/// One problem: what happened, the detail under it, its one action.
struct UIProblemRow: View {
  let problem: UIProblem
  let context: UIContext
  /// In Attention, an on-air loss leaves its Cut to the picture.
  var showsAction = true

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: problem.symbol ?? UISymbol.warning).imageScale(.small)
          .foregroundStyle(problem.symbol == nil ? problem.level.glyph : .secondary)
          .accessibilityHidden(true)
        // Line limits, not fixedSize: the split view measures its columns at their narrowest,
        // where a fixed height would be a word a line and push the window's minimum past the screen.
        Text(problem.title).font(.uiRowEmphasis).foregroundStyle(problem.level.text).lineLimit(3)
        if let dismiss = problem.dismiss {
          // Apart from the one action: Details only looks, and this takes the row off the list.
          Spacer(minLength: 4)
          Button { context.send(dismiss.action) } label: {
            Image(systemName: UISymbol.close).font(.uiMeta.weight(.semibold))
              .frame(width: 18, height: 18).contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .foregroundStyle(problem.level.secondaryText)
          .help(dismiss.title)
          .accessibilityLabel(dismiss.title)
        }
      }
      if let detail = problem.detail {
        Text(detail).font(.uiMeta).foregroundStyle(problem.level.secondaryText).lineLimit(3)
          .help(detail)
      }
      if showsAction, let action = problem.action {
        HStack {
          Spacer(minLength: 0)
          UIProblemButton(action: action, level: problem.level, context: context)
        }
      }
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(problem.level.fill, in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(problem.level.border, lineWidth: 1))
    .accessibilityElement(children: .contain)
  }
}

/// Every problem, worst first. The status bar's popover, and the strip's "2 problems".
struct UIProblemList: View {
  let problems: [UIProblem]
  let context: UIContext
  /// Attention's list also holds setup rows, which aren't problems: it's titled for itself.
  var title: String? = nil
  /// Past this the rows scroll, so a long list never runs off the screen.
  private static let maxListHeight: CGFloat = 420

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title ?? (problems.count == 1 ? "1 problem" : "\(problems.count) problems")).font(.uiTitle)
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(problems) { UIProblemRow(problem: $0, context: context) }
        }
      }
      .scrollBounceBehavior(.basedOnSize)
      // As tall as the rows up to the limit: the popover takes the list's ideal height.
      .frame(maxHeight: Self.maxListHeight)
      .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// Above the sidebar's scrolling list, so a problem can't arrive out of view. It never
/// opens the sidebar by itself: that would resize the pictures during a show.
struct UIAttentionSection: View {
  let context: UIContext
  /// More than this and the rest are one click away, so the list below keeps its room.
  private static let shown = 3
  @State private var listOpen = false

  /// Lost-signal rows carry a clock, so they tick; a drive's time left only needs a look now and then.
  private var refresh: TimeInterval {
    context.session.cameras.contains { $0.signalLostFor != nil } ? 1 : 5
  }

  var body: some View {
    UILiveSession(context: context, refresh: refresh, probe: "UILiveSession(attention)") { (session: UISessionSnapshot) in
      let rows = UIPresentationBuilder.problems(session) + UIPresentationBuilder.setupRows(session)
      if !rows.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("ATTENTION").font(.uiBadge).foregroundStyle(.secondary)
            .accessibilityLabel("Attention")
          ForEach(rows.prefix(Self.shown)) { UIProblemRow(problem: $0, context: context, showsAction: !$0.attentionOmitsAction) }
          if rows.count > Self.shown {
            Button("\(rows.count - Self.shown) more") { listOpen = true }
              .buttonStyle(.link).font(.uiMeta)
              .popover(isPresented: $listOpen, arrowEdge: .trailing) {
                UIProblemList(problems: rows, context: context, title: "Attention")
                  .padding(12).frame(width: 340, alignment: .leading)
              }
          }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Attention")
      }
    }
  }
}
