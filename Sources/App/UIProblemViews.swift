import SwiftUI

// The one problem list as views: the row every surface shares and the popover's list
// (the status bar's, and a strip's). Two levels (ruling 26): solid amber with dark text for
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
      .padding(.horizontal, 8).frame(height: 24).contentShape(Rectangle())
      .background(level.text.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
      .fixedSize()
  }
}

/// One problem: what happened, the detail under it, its one action.
struct UIProblemRow: View {
  let problem: UIProblem
  let context: UIContext

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
              .frame(width: 24, height: 24).contentShape(Rectangle())
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
      if let action = problem.action {
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
  /// The status bar's list also holds setup rows, which aren't problems: then it's titled for itself.
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
