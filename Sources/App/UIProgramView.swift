import SwiftUI

/// Optional Program View layout: the Program picture (what the virtual camera
/// sends), sources with explicit Cut buttons, the cut bar with shot timer,
/// collapsed strips and recent cuts. Side by Side with tally stays the default.
struct UIProgramView: View {
  let context: UIContext

  private var session: UISessionSnapshot { context.session }
  private var onAir: UICameraSnapshot? { session.cameras.first { $0.id == session.onAirID } }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HStack(alignment: .top, spacing: 12) {
          programPicture
            .frame(maxWidth: .infinity)
          VStack(spacing: 10) {
            ForEach(context.presentation.cameras) { camera in
              source(camera)
            }
          }
          .frame(width: 300)
        }
        UIProgramCutBar(context: context)
        ForEach(context.presentation.cameras) { camera in
          UIChannelStripView(camera: camera, context: context)
        }
        UIRecentCutsList(cuts: session.recentCuts)
      }
    }
    .scrollBounceBehavior(.basedOnSize)
    .contentMargins(12, for: .scrollContent)
  }

  private var programPicture: some View {
    let tally: UITally = session.onAirID == nil ? .none : (session.programInUse ? .onAir : .program)
    return context.pictures.programPicture()
      .aspectRatio(16 / 9, contentMode: .fit)
      .clipShape(RoundedRectangle(cornerRadius: 14))
      .overlay {
        if tally == .onAir {
          RoundedRectangle(cornerRadius: 14).strokeBorder(Color.red, lineWidth: 4)
        }
      }
      .overlay(alignment: .topLeading) {
        HStack(spacing: 6) {
          Label("Ultracam · Program", systemImage: "tv").font(.subheadline.weight(.semibold)).uiPictureOverlay()
          UITallyBadge(tally: tally)
        }
        .padding(10)
      }
      .overlay(alignment: .bottomLeading) {
        HStack(spacing: 6) {
          if let onAir {
            // "On air" only while a meeting app shows Program; otherwise it's just the Program camera.
            Text("\(onAir.name) \(tally == .onAir ? "on air" : "in Program")").font(.subheadline.weight(.semibold)).uiPictureOverlay()
          }
          if let format = onAir?.outputFormat {
            Text(format).font(.subheadline.weight(.semibold).monospacedDigit()).uiPictureOverlay()
          }
          if session.programFormatMismatch {
            Label {
              Text("Cameras use different formats — converted to the Program format")
            } icon: {
              Image(systemName: "arrow.triangle.2.circlepath")
            }
            .font(.subheadline.weight(.semibold))
            .uiPictureOverlay()
          }
        }
        .padding(10)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Program, \(onAir?.name ?? "no camera") \(tally == .onAir ? "on air" : "selected")")
  }

  private func source(_ camera: UICameraPresentation) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      UIColumnPictureLayout {
        UICameraPictureView(camera: camera, context: context, compact: true)
      }
      HStack {
        Text("\(camera.number)").font(.headline.monospacedDigit()).foregroundStyle(.secondary)
        Text(camera.name).font(.headline).lineLimit(1).truncationMode(.middle)
        Spacer()
        if camera.tally == .onAir || camera.tally == .program, let label = camera.tally.label {
          UIBadge(text: label, tone: camera.tally == .onAir ? .onAir : .neutral)
        } else {
          Button {
            context.send(.cut(cameraID: camera.id))
          } label: {
            Label("Cut", systemImage: "arrow.right.circle")
          }
          .disabled(!camera.cutEnabled)
          .help("Cut to \(camera.name) (⌃\(camera.number))")
          .accessibilityLabel("Cut to \(camera.name)")
        }
      }
    }
  }
}

/// Numbered cuts, Auto, strategy, Hold Shot and the shot timer.
struct UIProgramCutBar: View {
  let context: UIContext
  @State private var anchor: (value: TimeInterval?, at: Date) = (nil, .now)

  private var session: UISessionSnapshot { context.session }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        ForEach(context.presentation.cutButtons) { button in
          cutButton(button)
        }
        Divider().frame(height: 20)
        // Auto needs a strategy first, so the strategy picker stays available while Auto is off.
        Toggle("Auto", isOn: Binding(get: { context.presentation.autoSwitching }, set: { context.send(.setAutoSwitching($0)) }))
          .toggleStyle(.switch)
          .disabled(!context.presentation.canAutoSwitch)
          .help(context.presentation.canAutoSwitch
            ? "Automatic switching (⌃⌥A)" : "Choose a switching strategy first.")
        Picker("Strategy", selection: strategyBinding) {
          ForEach([SwitcherStrategy.manual, .fixedInterval, .naturalTalkingHead, .dynamicAnalysis], id: \.self) { strategy in
            Text(UIStrategy.title(strategy)).tag(strategy)
              .selectionDisabled(strategy == .dynamicAnalysis)
          }
        }
        .labelsHidden()
        .fixedSize()
        .help("Switching strategy")
        Toggle("Hold Shot", isOn: Binding(get: { session.autoHold }, set: { context.send(.setAutoHold($0)) }))
          .toggleStyle(.button)
          .disabled(!context.presentation.canHoldShot)
          .help("Keep the current shot: Auto stays on but makes no cuts")
        Spacer()
      }
      if session.strategy == .naturalTalkingHead {
        HStack(spacing: 14) {
          Picker("Anchor", selection: Binding(get: { session.anchorID }, set: { context.send(.setAnchor(cameraID: $0)) })) {
            Text("Automatic").tag(String?.none)
            ForEach(context.presentation.cameras) { camera in Text(camera.name).tag(String?.some(camera.id)) }
          }
          .fixedSize()
          .help("The camera the director returns to between emphasis shots")
          Picker("Emphasis", selection: Binding(get: { session.emphasisID }, set: { context.send(.setEmphasis(cameraID: $0)) })) {
            Text("Automatic").tag(String?.none)
            ForEach(context.presentation.cameras) { camera in Text(camera.name).tag(String?.some(camera.id)) }
          }
          .fixedSize()
          .help("The camera the director cuts to for emphasis")
          Spacer()
        }
        .disabled(!context.presentation.autoSwitching)
      }
      TimelineView(.periodic(from: .now, by: 1)) { timeline in
        shotTimer(now: timeline.date)
      }
    }
    .padding(12)
    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
    .onAppear { anchor = (session.shot.currentShot, .now) }
    .onChange(of: session.shot.currentShot) { _, value in anchor = (value, .now) }
  }

  private var strategyBinding: Binding<SwitcherStrategy> {
    Binding(get: { session.strategy }, set: { context.send(.setStrategy($0)) })
  }

  private func strategy(from title: String) -> SwitcherStrategy {
    [SwitcherStrategy.manual, .fixedInterval, .naturalTalkingHead, .dynamicAnalysis]
      .first { UIStrategy.title($0) == title } ?? .manual
  }

  @ViewBuilder private func cutButton(_ button: UICutButton) -> some View {
    let label = HStack(spacing: 4) {
      Text("\(button.number)").monospacedDigit().fontWeight(.bold)
      Text(button.name)
      if button.pending { Text("Next").font(.subheadline).foregroundStyle(.secondary) }
    }
    if button.onAir {
      Button { context.send(.cut(cameraID: button.id)) } label: { label }
        .buttonStyle(.borderedProminent).tint(.red)
        .accessibilityLabel("\(button.name), on air")
    } else {
      // A pending cut is outlined in green; the capsule shape keeps the outline on the button's edge.
      Button { context.send(.cut(cameraID: button.id)) } label: { label }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .overlay(Capsule().strokeBorder(button.pending ? Color.green : .clear, lineWidth: 1.5).allowsHitTesting(false))
        .disabled(!button.enabled)
        .help("Cut to \(button.name) (⌃\(button.number))")
        .accessibilityLabel(button.pending ? "\(button.name), cut pending" : "Cut to \(button.name)")
    }
  }

  @ViewBuilder private func shotTimer(now: Date) -> some View {
    let shot = session.shot
    let current = anchor.value.map { $0 + max(0, now.timeIntervalSince(anchor.at)) }
    let maximum = max(shot.maximum, 1)
    HStack(spacing: 12) {
      Text(current.map { String(format: "Shot %.0f s", $0) } ?? "No shot yet")
        .font(.callout.monospacedDigit().weight(.semibold))
        .frame(width: 96, alignment: .leading)
      GeometryReader { proxy in
        let width = proxy.size.width
        ZStack(alignment: .leading) {
          Capsule().fill(.fill.tertiary).frame(height: 8)
          Capsule().fill(LinearGradient(colors: [.green, .green, .yellow], startPoint: .leading, endPoint: .trailing))
            .frame(width: width * min(1, (current ?? 0) / maximum), height: 8)
          marker(at: shot.minimum / maximum, width: width, label: "min \(Int(shot.minimum)) s")
          marker(at: shot.softMaximum / maximum, width: width, label: "soft max \(Int(shot.softMaximum)) s")
          // Primary, not red, as in Settings › Switcher: red means on air or recording.
          marker(at: 1, width: width, label: "max \(Int(shot.maximum)) s", color: .primary)
        }
        .frame(maxHeight: .infinity, alignment: .top)
      }
      .frame(height: 30)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Shot timer")
    .accessibilityValue(current.map { "\(Int($0)) seconds, minimum \(Int(shot.minimum)), maximum \(Int(shot.maximum))" } ?? "No shot")
  }

  private func marker(at fraction: Double, width: CGFloat, label: String, color: Color = .secondary) -> some View {
    let x = width * min(1, max(0, fraction))
    return ZStack(alignment: .topLeading) {
      Rectangle().fill(color).frame(width: 1.5, height: 14).offset(x: x - 0.75, y: -3)
      Text(label).font(.subheadline).foregroundStyle(.secondary).fixedSize()
        .offset(x: min(max(0, x - 24), width - 60), y: 13)
    }
  }
}

/// Program cuts applied this session, newest first.
struct UIRecentCutsList: View {
  let cuts: [UICutRecord]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Recent Cuts").font(.headline)
      if cuts.isEmpty {
        Text("No cuts yet.").font(.callout).foregroundStyle(.secondary)
      } else {
        ForEach(cuts.prefix(6)) { cut in
          HStack(spacing: 10) {
            Text(cut.at, format: .dateTime.hour().minute().second())
              .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Text("Cut to \(cut.cameraName)").font(.callout)
            Spacer()
            UIBadge(text: cut.automatic ? "Auto" : "Manual")
          }
          .accessibilityElement(children: .combine)
        }
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
  }
}
