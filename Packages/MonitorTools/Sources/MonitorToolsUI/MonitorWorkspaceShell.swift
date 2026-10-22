import MonitorToolsCore
import SwiftUI

public struct MonitorTargetOption: Identifiable, Hashable {
  public var id: MonitorTargetID
  public var title: String
  public var isAvailable: Bool
  public init(id: MonitorTargetID, title: String, isAvailable: Bool = true) {
    self.id = id
    self.title = title
    self.isAvailable = isAvailable
  }
}

/// Layout owns only surface focus and temporary expansion. Feed subscriptions belong to the adapter.
public struct MonitorWorkspaceShell<Tile: View>: View {
  @Binding var workspace: MonitorWorkspaceState
  @State private var focusedTile = 0
  @State private var expandedTile: Int?
  @State private var dragStartRatio: Double?
  @State private var splitWidth = 640.0
  private let tile: (Int, Bool) -> Tile
  public init(
    workspace: Binding<MonitorWorkspaceState>, @ViewBuilder tile: @escaping (Int, Bool) -> Tile
  ) {
    _workspace = workspace
    self.tile = tile
  }
  public var body: some View {
    VStack(spacing: 8) {
      HStack {
        Picker("Monitor layout", selection: $workspace.layout) {
          Text("Single").tag(MonitorWorkspaceLayout.single)
          Text("Side by Side").tag(MonitorWorkspaceLayout.sideBySide)
          Text("Four Up").tag(MonitorWorkspaceLayout.fourUp)
        }.pickerStyle(.segmented).frame(maxWidth: 330)
        Spacer()
        if expandedTile != nil {
          Button("Restore layout") { expandedTile = nil }
        } else if workspace.layout != .single {
          Button("Swap tiles") {
            while workspace.tileBindings.count < 4 { workspace.tileBindings.append(nil) }
            workspace.tileBindings.swapAt(0, 1)
          }
          Button("Expand tile") { expandedTile = focusedTile }
        }
      }.controlSize(.small)
      if let index = expandedTile {
        surface(index)
      } else {
        switch workspace.layout {
        case .single: surface(0)
        case .sideBySide: split
        case .fourUp:
          VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
              surface(0)
              surface(1)
            }
            HStack(alignment: .top, spacing: 8) {
              surface(2)
              surface(3)
            }
          }
        }
      }
    }.onChange(of: workspace.layout) { _, _ in expandedTile = nil }
  }
  private func surface(_ index: Int) -> some View {
    tile(index, focusedTile == index)
      .frame(maxWidth: .infinity, alignment: .top)
      .padding(3)
      .overlay(
        RoundedRectangle(cornerRadius: 8).strokeBorder(
          focusedTile == index ? Color.accentColor : .clear, lineWidth: 1)
      )
      .simultaneousGesture(TapGesture().onEnded { focusedTile = index })
      .contextMenu {
        Button("Focus tile") { focusedTile = index }
        Button(expandedTile == nil ? "Expand tile" : "Restore layout") {
          expandedTile = expandedTile == nil ? index : nil
        }
      }
  }
  private var split: some View {
    MonitorSplitLayout(ratio: workspace.normalizedSplitRatio) {
      surface(0)
      Rectangle().fill(.secondary.opacity(0.3)).frame(width: 6).padding(.horizontal, 2)
        .contentShape(Rectangle())
        .gesture(
          DragGesture().onChanged { value in
            if dragStartRatio == nil { dragStartRatio = workspace.normalizedSplitRatio }
            workspace.splitRatio = min(
              0.8,
              max(0.2, (dragStartRatio ?? 0.5) + value.translation.width / max(1, splitWidth - 10)))
          }.onEnded { _ in dragStartRatio = nil }
        )
        .accessibilityLabel("Monitor divider")
        .accessibilityAdjustableAction { direction in
          workspace.splitRatio = min(
            0.8, max(0.2, workspace.normalizedSplitRatio + (direction == .increment ? 0.05 : -0.05))
          )
        }
      surface(1)
    }
    .onGeometryChange(for: Double.self) {
      $0.size.width
    } action: {
      splitWidth = $0
    }
  }

}

public struct MonitorTileChrome<Picture: View, Scopes: View>: View {
  @Binding var target: MonitorTargetID?
  @Binding var configuration: MonitorConfiguration
  public var choices: [MonitorTargetOption]
  public var status: String
  public var detail: String
  public var compact: Bool
  public var legendConfiguration: MonitorConfiguration?
  public var showsScopes: Bool
  private let picture: Picture
  private let scopes: Scopes
  public init(
    target: Binding<MonitorTargetID?>, configuration: Binding<MonitorConfiguration>,
    choices: [MonitorTargetOption], status: String, detail: String = "", compact: Bool = false,
    legendConfiguration: MonitorConfiguration? = nil, showsScopes: Bool = true,
    @ViewBuilder picture: () -> Picture,
    @ViewBuilder scopes: () -> Scopes
  ) {
    _target = target
    _configuration = configuration
    self.choices = choices
    self.status = status
    self.detail = detail
    self.compact = compact
    self.legendConfiguration = legendConfiguration
    self.showsScopes = showsScopes
    self.picture = picture()
    self.scopes = scopes()
  }
  private var isProgram: Bool { target?.rawValue == "program" }
  var pictureCaption: String {
    let displayed = legendConfiguration ?? configuration
    if !isProgram && displayed.toolsEnabled && displayed.falseColor.mode != .off {
      return "False color: Source analysis · selected picture signal: \(displayed.pictureStage == .source ? "Source" : "Processed Output")"
    }
    return "Picture: \(isProgram ? "Program Output" : displayed.pictureStage == .source ? "Source" : "Processed Output")"
  }
  public var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Picker("Monitor target", selection: $target) {
          Text("Choose feed").tag(Optional<MonitorTargetID>.none)
          if let target, !choices.contains(where: { $0.id == target }) {
            Text("Missing feed").tag(Optional(target))
          }
          ForEach(choices) { Text($0.title).tag(Optional($0.id)) }
        }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        Text(status).font(.caption).foregroundStyle(.secondary)
      }
      picture
      HStack {
        Picker("Picture signal", selection: $configuration.pictureStage) {
          Text("Source").tag(MonitorStage.source).disabled(isProgram)
          Text("Processed Output").tag(MonitorStage.processedOutput)
        }.controlSize(.mini)
      }
      Text(pictureCaption).font(.caption2)
      if legendConfiguration != nil {
        Text("Frozen · " + pictureCaption)
          .font(.caption)
      }
      MonitorToolsToolbar(
        configuration: $configuration, compact: compact, supportsSourceAnalysis: !isProgram)
      if !detail.isEmpty {
        Text(detail).font(.caption2).foregroundStyle(.secondary).fixedSize(
          horizontal: false, vertical: true)
      }
      if (legendConfiguration ?? configuration).toolsEnabled
        && (legendConfiguration ?? configuration).falseColor.mode != .off
      {
        if isProgram {
          Text("False Color unavailable for Program: source Log provenance is required").font(
            .caption2)
        } else {
          MonitorFalseColorLegend(configuration: legendConfiguration ?? configuration)
        }
      }
      if (legendConfiguration ?? configuration).toolsEnabled
        && (legendConfiguration ?? configuration).focus.enabled
      {
        Text(isProgram ? "Focus unavailable for Program" : "Focus: Source").font(.caption2)
      }
      if showsScopes && (legendConfiguration ?? configuration).toolsEnabled
        && (legendConfiguration ?? configuration).scopes.enabled
      {
        scopes
      }
    }.padding(7).background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
  }
}

/// Measures each tile at its actual split width and preserves its complete natural height.
struct MonitorSplitLayout: Layout {
  var ratio: Double
  private let dividerWidth = 10.0
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard subviews.count == 3 else { return .zero }
    let idealWidth =
      subviews[0].sizeThatFits(.unspecified).width + subviews[2].sizeThatFits(.unspecified).width
      + dividerWidth
    let width = proposal.width ?? max(320, idealWidth.isFinite ? idealWidth : 640)
    let usable = max(0, width - dividerWidth)
    let left = subviews[0].sizeThatFits(ProposedViewSize(width: usable * ratio, height: nil))
    let right = subviews[2].sizeThatFits(ProposedViewSize(width: usable * (1 - ratio), height: nil))
    return CGSize(width: width, height: max(left.height, right.height))
  }
  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    guard subviews.count == 3 else { return }
    let usable = max(0, bounds.width - dividerWidth)
    subviews[0].place(
      at: bounds.origin, anchor: .topLeading,
      proposal: ProposedViewSize(width: usable * ratio, height: nil))
    subviews[1].place(
      at: CGPoint(x: bounds.minX + usable * ratio, y: bounds.minY), anchor: .topLeading,
      proposal: ProposedViewSize(width: dividerWidth, height: bounds.height))
    subviews[2].place(
      at: CGPoint(x: bounds.minX + usable * ratio + dividerWidth, y: bounds.minY),
      anchor: .topLeading, proposal: ProposedViewSize(width: usable * (1 - ratio), height: nil))
  }
}
