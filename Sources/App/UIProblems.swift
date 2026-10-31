import Foundation

// One problem list. Status bar, Attention, menu bar and popover all render it, worst
// first, each problem with one action. Derived from the snapshot alone, so what it says
// and in what order can be tested without capture hardware.

/// Two levels (ruling 26): damage to what is on air or rolling, and everything else.
enum UIProblemLevel: Sendable, Equatable { case damage, notice }

/// What a problem offers. Every render of a problem uses the same one.
struct UIProblemAction: Sendable, Equatable {
  var title: String
  var action: UIAction
}

/// The events that leave the window. Text is meeting-safe: a banner may land on a shared
/// display, so camera names and state only, never a drive, path or take name.
enum UIAlertEvent: String, Sendable, Equatable, CaseIterable {
  case cameraStopped, takeEndedEarly, recordingNoSignal, onAirLost, driveLow
}

struct UIProblemAlert: Sendable, Equatable {
  var event: UIAlertEvent
  var title: String
  var body: String
  /// One of the three worst: it also gets the floating panel.
  var showsPanel = false
}

struct UIProblem: Sendable, Equatable, Identifiable {
  /// Stable while the problem lasts, so a repeat replaces it and a clear removes it.
  var id: String
  var title: String
  var detail: String?
  var level: UIProblemLevel
  var cameraID: String?
  var action: UIProblemAction?
  /// What the strip says to do, in place of its folder row. Nil when the record row or
  /// nothing on the strip carries it.
  var stripText: String?
  var alert: UIProblemAlert?
  /// Lower is worse. Internal to the ordering.
  fileprivate var rank = 0
}

/// A camera's worst problem as its strip shows it.
struct UIStripProblem: Sendable, Equatable {
  var text: String
  var level: UIProblemLevel
  var action: UIProblemAction?
  /// More than one: the row says how many, and its words open the list.
  var count: Int
}

extension UIPresentationBuilder {
  /// How long a take survives a loss: a gap past this starts a new capture epoch,
  /// which ends the take when frames return (`UCDeckLinkMaximumSourceGapSeconds`).
  static let takeGapLimit: TimeInterval = 10

  // MARK: Facts

  static func isLive(_ camera: UICameraSnapshot) -> Bool {
    if case .live = camera.signal { return camera.running }
    return false
  }

  static func isRolling(_ camera: UICameraSnapshot) -> Bool {
    camera.recording.status == .recording || camera.recording.status == .paused
  }

  /// The camera a cut would land on: live, and not waiting out its return hold.
  static func canTakeCut(_ camera: UICameraSnapshot) -> Bool { isLive(camera) && camera.cutBlockedFor == nil }

  /// Where a cut away from `camera` should go: the next camera in strip order, wrapping.
  static func nextLive(after camera: UICameraSnapshot, in session: UISessionSnapshot) -> UICameraSnapshot? {
    let ids = session.cameras.map { FeedID(rawValue: $0.id) }
    let next = ProgramFailover.nextLive(after: FeedID(rawValue: camera.id), order: ids) { id in
      id.rawValue != camera.id && session.cameras.first { $0.id == id.rawValue }.map(canTakeCut) == true
    }
    return session.cameras.first { $0.id == next?.rawValue }
  }

  /// The strip says "Signal lost 0:06"; a camera that never had a picture just says "No signal".
  static func lostClock(_ camera: UICameraSnapshot) -> String? {
    camera.signalLostFor.map(UIFormat.shortElapsed)
  }

  /// `Take ends in 4 s`, counting down, while a rolling take is losing its picture. The
  /// take ends when frames return after the limit, so past it that's what this says.
  static func takeCountdown(_ camera: UICameraSnapshot) -> String? {
    guard isRolling(camera), let lost = camera.signalLostFor else { return nil }
    let left = Int((takeGapLimit - lost).rounded(.up))
    return left > 0 ? "Take ends in \(left) s" : "Take ends when the signal returns"
  }

  private static func onAir(_ session: UISessionSnapshot) -> UICameraSnapshot? {
    session.outputMode == .program ? session.cameras.first { $0.id == session.onAirID } : nil
  }

  private static func hasNoPicture(_ camera: UICameraSnapshot) -> Bool {
    guard camera.running else { return false }
    switch camera.signal {
    case .noSignal, .unsupported, .deviceMissing: return true
    case .none, .connecting, .live: return false
    }
  }

  // MARK: The list

  /// Every problem, worst first. A status of no problems is an empty list.
  static func problems(_ session: UISessionSnapshot) -> [UIProblem] {
    var list = sessionProblems(session)
    for camera in session.cameras { list += cameraProblems(camera, in: session) }
    return list.enumerated().sorted { lhs, rhs in
      (lhs.element.rank, lhs.offset) < (rhs.element.rank, rhs.offset)
    }.map(\.element)
  }

  /// The strip's row: the worst problem that belongs on the strip, and how many there are.
  static func stripProblem(_ camera: UICameraSnapshot, in session: UISessionSnapshot) -> UIStripProblem? {
    let own = cameraProblems(camera, in: session).filter { $0.stripText != nil }
      .sorted { $0.rank < $1.rank }
    guard let worst = own.first, let text = worst.stripText else { return nil }
    return UIStripProblem(text: text, level: worst.level, action: worst.action, count: own.count)
  }

  private static func cameraProblems(_ camera: UICameraSnapshot, in session: UISessionSnapshot) -> [UIProblem] {
    var list: [UIProblem] = []
    let id = camera.id, name = camera.name
    let onAirHere = onAir(session)?.id == id
    let rolling = isRolling(camera)
    let details = UIProblemAction(title: "Details", action: .openDiagnostics)
    let saved = takeSavedLine(camera)

    if let stop = camera.unexpectedStop, let reason = stop.reason {
      let wasOnAir = stop.wasOnAir
      list.append(UIProblem(id: "stopped.\(id)", title: "\(name) stopped: \(reason)", detail: saved.map { "Take ended early, \($0)" },
        level: wasOnAir || saved != nil ? .damage : .notice, cameraID: id,
        action: UIProblemAction(title: "Start", action: .startCamera(cameraID: id)),
        stripText: nil,
        alert: UIProblemAlert(event: .cameraStopped, title: "\(name) stopped",
          body: wasOnAir ? "Was on Program" : "Stopped on its own", showsPanel: wasOnAir), rank: wasOnAir ? 30 : 60))
    } else if camera.recording.failed || camera.recording.error != nil || camera.unexpectedStop?.take == true {
      // `failed` closes the take; a saved movie is still safe, and Details acknowledges it.
      let acknowledge = UIProblemAction(title: "Details", action: .acknowledgeStop(cameraID: id))
      if diskFull(camera, in: session) {
        list.append(UIProblem(id: "take.\(id)", title: "\(name): disk full", detail: saved.map { "Take ended early, \($0)" },
          level: .damage, cameraID: id,
          action: UIProblemAction(title: "Choose Folder…", action: .chooseRecordingFolder(cameraID: id)),
          alert: UIProblemAlert(event: .driveLow, title: "Recording drive full", body: "\(name) has no space left"), rank: 50))
      } else {
        list.append(UIProblem(id: "take.\(id)", title: "Take ended early", detail: [name, saved].compactMap { $0 }.joined(separator: ", "),
          level: .damage, cameraID: id, action: acknowledge,
          alert: UIProblemAlert(event: .takeEndedEarly, title: "\(name) take ended",
            body: saved.map { "\($0.prefix(1).uppercased())\($0.dropFirst())" } ?? "Stopped early", showsPanel: true), rank: 50))
      }
    }

    if camera.queueStalled {
      list.append(UIProblem(id: "stall.\(id)", title: "\(name): the meeting app has stopped taking video",
        detail: "Queue full for 2 s.", level: .damage, cameraID: id,
        action: UIProblemAction(title: "Restart Camera", action: .restartCamera(cameraID: id)),
        stripText: "The meeting app has stopped taking video", rank: 70))
    }
    if camera.clientWaiting {
      list.append(UIProblem(id: "waiting.\(id)", title: "A camera app is waiting for \(name)",
        detail: "It's connected, but no frames are reaching it.", level: .damage, cameraID: id,
        action: camera.running ? UIProblemAction(title: "Restart Camera", action: .restartCamera(cameraID: id))
          : UIProblemAction(title: "Start", action: .startCamera(cameraID: id)),
        stripText: "A camera app is waiting for frames", rank: 80))
    } else if let failure = camera.sinkFailure, camera.clientUnknown {
      // Whether anyone is waiting can't be read, which is itself what's wrong: with a
      // known empty route this stays quiet.
      list.append(UIProblem(id: "sink.\(id)", title: "\(name) isn't reaching meeting apps", detail: failure,
        level: .notice, cameraID: id, action: details, stripText: "Virtual camera unavailable", rank: 130))
    }

    if camera.running {
      let lost = lostClock(camera).map { " \($0)" } ?? ""
      switch camera.signal {
      case .noSignal where onAirHere && session.programInUse:
        let others = session.cameras.contains { $0.id != id && canTakeCut($0) }
        let next = nextLive(after: camera, in: session)
        let action = !session.autoSwitching ? next.map { UIProblemAction(title: "Cut to \($0.name)", action: .cut(cameraID: $0.id)) } : nil
        list.append(UIProblem(id: "onair.\(id)", title: lost.isEmpty ? "\(name) on air: no signal" : "\(name) signal lost\(lost)",
          detail: takeCountdown(camera) ?? "Still on Program", level: .damage, cameraID: id, action: action ?? details,
          stripText: "Check \(name)'s HDMI",
          alert: UIProblemAlert(event: .onAirLost, title: "\(name) signal lost",
            body: others ? "Still on Program" : "No camera has a picture", showsPanel: true), rank: 10))
      case .noSignal where rolling:
        list.append(UIProblem(id: "signal.\(id)", title: lost.isEmpty ? "\(name): recording, no signal" : "\(name) signal lost\(lost)",
          detail: takeCountdown(camera), level: .damage, cameraID: id, action: details,
          stripText: "Check \(name)'s HDMI",
          alert: UIProblemAlert(event: .recordingNoSignal, title: "\(name) recording, no signal", body: "The take ends if the signal stays off"), rank: 20))
      case .noSignal:
        list.append(UIProblem(id: "signal.\(id)", title: lost.isEmpty ? "\(name): no signal" : "\(name) signal lost\(lost)",
          level: .notice, cameraID: id, action: details, stripText: "Check \(name)'s HDMI", rank: 150))
      case .unsupported:
        list.append(UIProblem(id: "signal.\(id)", title: onAirHere && session.programInUse ? "\(name) on air: unsupported format" : "\(name): unsupported format",
          level: onAirHere && session.programInUse ? .damage : .notice, cameraID: id, action: details,
          stripText: "Choose a supported source format", rank: onAirHere && session.programInUse ? 11 : 150))
      case .deviceMissing:
        list.append(UIProblem(id: "signal.\(id)", title: onAirHere && session.programInUse ? "\(name) on air: input disconnected" : "\(name): input disconnected",
          level: onAirHere && session.programInUse ? .damage : .notice, cameraID: id,
          action: UIProblemAction(title: "Refresh Inputs", action: .refreshInputs),
          stripText: "Reconnect \(camera.inputName ?? "the input")", rank: onAirHere && session.programInUse ? 11 : 150))
      case .none, .connecting, .live:
        break
      }
    } else if onAirHere, !starting(camera), camera.unexpectedStop?.reason == nil,
      session.cameras.contains(where: isLive) || (session.programInUse && session.cameras.count == 1) {
      // Program is on a camera that isn't sending, and not one about to start for a meeting.
      let problem = camera.deviceAvailable ? "stopped" : (camera.inputName == nil ? "no input" : "input missing")
      list.append(UIProblem(id: "onair.\(id)", title: "\(name) \(session.programInUse ? "on air" : "in Program"): \(problem)",
        level: session.programInUse ? .damage : .notice, cameraID: id,
        action: UIProblemAction(title: "Start", action: .startCamera(cameraID: id)), rank: 12))
    }

    if camera.automaticStartFailed {
      list.append(UIProblem(id: "start.\(id)", title: "\(name): couldn't start", detail: camera.automaticStatus,
        level: .notice, cameraID: id,
        action: UIProblemAction(title: "Retry", action: .retryAutomaticStart(cameraID: id)),
        stripText: "Couldn't start \(name)", rank: 8))
    }
    if let error = camera.lutError {
      list.append(UIProblem(id: "lut.\(id)", title: "\(name): LUT unavailable", detail: error,
        level: .notice, cameraID: id,
        action: UIProblemAction(title: "Locate…", action: .chooseLUT(cameraID: id)),
        stripText: "LUT unavailable", rank: 170))
    }
    return list
  }

  /// "12:31 saved", the one way a take's saved length is written.
  static func takeSavedLine(_ camera: UICameraSnapshot) -> String? {
    (camera.unexpectedStop?.savedDuration ?? camera.recording.savedDuration)
      .map { "\(UIFormat.shortElapsed($0)) saved" }
  }

  private static func sessionProblems(_ session: UISessionSnapshot) -> [UIProblem] {
    var list: [UIProblem] = []
    let details = UIProblemAction(title: "Details", action: .openDiagnostics)
    func recordsTo(_ drive: UIDrive) -> Bool {
      session.cameras.contains { isRolling($0) && UIPresentationBuilder.drive(for: $0, in: session)?.id == drive.id }
    }
    let rollingAnywhere = session.cameras.contains(where: isRolling)

    // Program has nothing to show. Not while something is still starting for the meeting.
    if session.outputMode == .program, session.programInUse, !session.cameras.contains(where: isLive),
      session.cameras.count != 1 || onAir(session) == nil,
      !session.cameras.contains(where: { starting($0) || $0.automaticStartFailed }) {
      list.append(UIProblem(id: "program.nopicture", title: "No camera has a picture",
        detail: onAir(session).map { "Program stays on \($0.name)." }, level: .damage, action: details, rank: 0))
    }
    if let moved = session.programMoved {
      list.append(UIProblem(id: "program.moved", title: "\(moved.from) signal lost",
        detail: "Program moved to \(moved.to).\(moved.heldShot ? " Hold stays on." : "")", level: .damage,
        action: UIProblemAction(title: "Details", action: .acknowledgeProgramMove),
        alert: UIProblemAlert(event: .onAirLost, title: "\(moved.from) signal lost",
          body: "Program moved to \(moved.to)", showsPanel: true), rank: 14))
    }
    if session.programQueueStalled, let onAir = onAir(session) {
      list.append(UIProblem(id: "program.stall", title: "The meeting app has stopped taking video",
        detail: "Program's queue has been full for 2 s.", level: .damage,
        action: UIProblemAction(title: "Restart Camera", action: .restartCamera(cameraID: onAir.id)), rank: 70))
    }

    // A drive with nothing free has no time left at all, so the check below never sees it.
    for drive in session.drives where isFull(drive) {
      list.append(UIProblem(id: "drive.\(drive.id)", title: "\(drive.name): no space left",
        level: recordsTo(drive) ? .damage : .notice,
        action: UIProblemAction(title: rollingAnywhere ? "Folder for Next Take…" : "Change…", action: .chooseRecordingFolder(cameraID: nil)),
        alert: UIProblemAlert(event: .driveLow, title: "Recording drive full", body: "No space left"), rank: 90))
    }
    for drive in session.drives {
      guard !isFull(drive), let left = drive.secondsLeft, left < lowDriveSeconds else { continue }
      list.append(UIProblem(id: "drive.\(drive.id)", title: "\(drive.name): \(UIFormat.duration(left)) left",
        detail: driveUsers(drive, in: session), level: recordsTo(drive) ? .damage : .notice,
        action: UIProblemAction(title: rollingAnywhere ? "Folder for Next Take…" : "Change…", action: .chooseRecordingFolder(cameraID: nil)),
        alert: UIProblemAlert(event: .driveLow, title: "Recording drive low", body: "\(UIFormat.duration(left)) left"), rank: 95))
    }

    // Cuts land on Program, and a meeting on a camera's own device won't see them.
    if session.outputMode == .program, !session.programInUse, !session.recentCuts.isEmpty,
      let iso = session.cameras.first(where: \.inUse) {
      list.append(UIProblem(id: "program.cuts", title: "Cuts aren't reaching a meeting app",
        detail: "It's using \(iso.name), not Program.", level: .notice, action: details, rank: 110))
    }
    if session.unusedTake {
      let rolling = session.cameras.filter(isRolling).count
      list.append(UIProblem(id: "take.unused", title: "Still recording: no meeting app is using Ultracam",
        detail: "Nothing has used it for 2 minutes.", level: .notice,
        action: UIProblemAction(title: rolling == 1 ? "Stop Recording" : "Stop \(rolling) Recordings", action: .stopAllRecordings), rank: 120))
    }
    // Different camera formats are converted on the GPU to the Program camera's format,
    // so they are not a problem. A cut that did not land or dropped Program frames are.
    if session.outputMode == .program, let issue = session.programIssue {
      list.append(UIProblem(id: "program.issue", title: issue, level: .notice, action: details, rank: 180))
    }
    for message in session.appProblems {
      list.append(UIProblem(id: "app.\(message.id)", title: message.text, level: .notice,
        action: UIProblemAction(title: "Details", action: .acknowledgeProblem(id: message.id)), rank: 190))
    }
    return list
  }

  /// "Camera 1 and Camera 2 record here."
  private static func driveUsers(_ drive: UIDrive, in session: UISessionSnapshot) -> String? {
    let names = session.cameras.filter { UIPresentationBuilder.drive(for: $0, in: session)?.id == drive.id }.map(\.name)
    guard let last = names.last else { return nil }
    return names.count == 1 ? "\(last) records here." : "\(names.dropLast().joined(separator: ", ")) and \(last) record here."
  }

  /// Capture without a first frame yet, or an automatic camera about to start for the
  /// meeting that just connected (a failed one already said "couldn't start").
  private static func starting(_ camera: UICameraSnapshot) -> Bool {
    if camera.running { return camera.signal == .none || camera.signal == .connecting }
    return camera.automaticStart && !camera.automaticStartFailed && camera.deviceAvailable
  }

  /// Under half an hour left counts as low.
  static let lowDriveSeconds: TimeInterval = 30 * 60

  /// The single most important problem, if any: the head of the list.
  static func warning(_ session: UISessionSnapshot) -> String? { problems(session).first?.title }
}
