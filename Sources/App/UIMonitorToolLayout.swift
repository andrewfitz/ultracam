import AppKit
import SwiftUI

// The monitor tool popovers' shared layout: a header, then two fixed-width
// columns of titled groups, with an aligned label column. Every popover uses it,
// so they read as one system and size to their content instead of scrolling.

@MainActor enum UIToolLayout {
  /// One column of groups.
  // Keep enough room for the slider track and its readout while dragging.
  // The old width let SwiftUI renegotiate the popover on every value change,
  // which made the zebra form visibly jump and could reflow the surrounding UI.
  static let columnWidth: CGFloat = 356
  static let columnSpacing: CGFloat = 12
  /// The label column of a settings row.
  static let labelWidth: CGFloat = 104
  static let padding: CGFloat = 16
  /// Two columns and the space between them.
  static let contentWidth = columnWidth * 2 + columnSpacing
  static let panelWidth = contentWidth + padding * 2

  /// The tallest a popover's settings get before they scroll: the screen's
  /// visible height, less room for the tool bar, the arrow and the header.
  static var maximumSettingsHeight: CGFloat {
    max(320, (NSScreen.main?.visibleFrame.height ?? 900) - 180)
  }
}

/// Two top-aligned columns of groups, then full-width notes under both.
struct UIToolColumns<Leading: View, Trailing: View, Footer: View>: View {
  let leading: Leading
  let trailing: Trailing
  let footer: Footer

  init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing,
    @ViewBuilder footer: () -> Footer) {
    self.leading = leading()
    self.trailing = trailing()
    self.footer = footer()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: UIToolLayout.columnSpacing) {
        VStack(alignment: .leading, spacing: UIToolLayout.columnSpacing) { leading }
          .frame(width: UIToolLayout.columnWidth, alignment: .topLeading)
        VStack(alignment: .leading, spacing: UIToolLayout.columnSpacing) { trailing }
          .frame(width: UIToolLayout.columnWidth, alignment: .topLeading)
      }
      VStack(alignment: .leading, spacing: 4) { footer }
        .padding(.horizontal, 4)
    }
    .frame(width: UIToolLayout.contentWidth, alignment: .leading)
  }
}

extension UIToolColumns where Footer == EmptyView {
  init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
    self.init(leading: leading, trailing: trailing) { EmptyView() }
  }
}

/// A titled box of settings. `accessory` sits at the end of the title line,
/// for example the switch of the zebra set the box holds.
struct UIToolGroup<Content: View, Accessory: View>: View {
  let title: String
  let content: Content
  let accessory: Accessory

  init(_ title: String, @ViewBuilder content: () -> Content, @ViewBuilder accessory: () -> Accessory) {
    self.title = title
    self.content = content()
    self.accessory = accessory()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 6) {
        Text(title)
          .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
          .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 4)
        accessory
      }
      .frame(minHeight: 18)
      .padding(.horizontal, 4)
      VStack(alignment: .leading, spacing: 8) { content }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
  }
}

extension UIToolGroup where Accessory == EmptyView {
  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.init(title, content: content) { EmptyView() }
  }
}

/// A settings row: the label in the popover's label column, the control beside it.
struct UIToolLabeledContentStyle: LabeledContentStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(alignment: .center, spacing: 8) {
      configuration.label
        .font(.callout)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: UIToolLayout.labelWidth, alignment: .leading)
      configuration.content
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

extension View {
  /// A checkbox or stepper as macOS draws it, box or arrows beside its own
  /// label, instead of in the popover's label column.
  func uiToolInline() -> some View {
    labeledContentStyle(.automatic)
  }

  /// This control as a settings row titled `title`. Its own label is hidden on
  /// screen and still names it for VoiceOver.
  func uiToolRow(_ title: String) -> some View {
    LabeledContent(title) { self.labelsHidden() }
  }
}
