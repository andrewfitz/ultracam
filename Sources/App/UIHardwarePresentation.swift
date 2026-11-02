import Foundation

// What Ultracam knows about its hardware, as Settings › Hardware, the left pane, the problem
// list and Copy Diagnostics show it. Built from plugin facts only: every word about a vendor's
// hardware comes from its plugin, so nothing here names one.

/// A capture device, listed or not. An absent one is here only because a camera is assigned
/// to it, and keeps its last known name and its plugin's hint.
struct UIHardwareDevice: Identifiable, Equatable {
  enum Health: Equatable { case healthy, attention, absent }
  struct Camera: Equatable { var id: String; var name: String; var running: Bool }
  var id: String
  /// The nickname, the driver's label or the last name seen, in that order.
  var name: String
  /// The driver's own name when a nickname replaces it.
  var driverName: String?
  var present: Bool
  var model: String?
  var cameras: [Camera] = []
  var status: CaptureDeviceStatus?
  /// What to check, from its plugin; absent devices only.
  var hint: String?
  var modes: [SourceFormat] = []

  var health: Health {
    guard present else { return .absent }
    return status?.problems.contains { $0.severity >= .warning } == true ? .attention : .healthy
  }
  /// The cameras using it that are running: their settings can drop the signal.
  var runningCameras: [Camera] { cameras.filter(\.running) }
  /// One line under the name when collapsed: its connector, its signal, its link. A nil lock
  /// is unknown, so it says nothing rather than "No signal".
  var summary: [String] {
    guard present else { return [] }
    var pieces: [String] = []
    if let connector = status?.connector { pieces.append(UIHardwareText.connector(connector)) }
    if let detected = status?.detected, status?.signalLocked != false { pieces.append(FormatDisplayIdentity(detected).short) }
    else if status?.signalLocked == false { pieces.append("No signal") }
    if let link = status.map(\.link), let text = UIHardwareText.link(link) { pieces.append(text) }
    return pieces
  }
}

/// A camera body: assigned to a camera, found by a scan, or both.
struct UIHardwareBody: Identifiable, Equatable {
  enum Health: Equatable { case healthy, attention, absent }
  var camera: ControlCamera
  var id: String { camera.id }
  /// The Ultracam camera it's paired with.
  var feedID: String?
  var cameraName: String?
  var connected = false
  /// It dropped on its own; Reconnect uses the saved sign-in.
  var lost = false
  /// It's reconnecting on its own.
  var retrying = false
  /// Listed by the latest scan, or connected.
  var found = false
  /// A scan has run since launch, so "not found" means something.
  var scanned = false
  var properties: [ControlProperty] = []
  var notice: String?
  var noticeSeverity: DeviceSeverity?

  var battery: UIBattery? { UIHardwareText.battery(properties) }
  /// Problems the body reports about itself: overheating, a low battery, a card error.
  var warnings: [ControlProperty] {
    properties.filter { [.thermal, .power, .media].contains($0.role) && ($0.severity ?? .info) >= .warning }
  }
  var overheating: ControlProperty? { warnings.first { $0.role == .thermal } }
  var health: Health {
    if !connected { return lost ? .attention : .absent }
    return warnings.isEmpty && (noticeSeverity ?? .info) < .warning ? .healthy : .attention
  }
  /// "Reconnecting…", "Disconnected", "Not found on the network" or "Not connected", while it
  /// isn't connected.
  var connectionText: String {
    if connected { return "Connected" }
    if retrying { return "Reconnecting…" }
    if lost { return "Disconnected" }
    if feedID != nil && scanned && !found { return "Not found on the network" }
    return feedID == nil ? camera.address : "Not connected"
  }
}

/// How a paired body meets its camera's capture device: read-only facts, and an advisory only
/// when two facts conflict. Nothing here changes a setting on its own.
struct UIBodySetup: Equatable {
  enum Tone: Equatable { case positive, warning }
  struct Row: Equatable { var label: String; var pieces: [String]; var note: String? = nil; var tone: Tone = .positive }
  enum Action: Equatable {
    /// Declare the camera's source profile (a `SourceColorSpaceCatalog` ID).
    case useSourceProfile(String)
    /// Set one of the body's own writable properties.
    case setProperty(ControlProperty.ID, ControlValue)
  }
  struct Advisory: Equatable { var title: String; var detail: String; var actionTitle: String; var action: Action }
  var rows: [Row] = []
  var advisory: Advisory?

  init(properties: [ControlProperty], cameraName: String, declaredProfileID: String, captureName: String?,
       detected: SourceFormat?, timecodeMode: RecordingTimecodeMode) {
    func values(_ role: ControlPropertyRole) -> [String] {
      properties.filter { $0.role == role }.flatMap { UIHardwareText.pieces(UIControlPresentation.value($0)) }
    }
    // HDMI format, compared with what the capture device detects.
    let hdmi = values(.outputTiming).filter { $0 != "Off" }
    if !hdmi.isEmpty {
      var row = Row(label: "HDMI output", pieces: hdmi)
      if let detected, let captureName {
        let short = FormatDisplayIdentity(detected).short
        let size = "\(detected.height)p"
        let rate = 1 / detected.rate.nominal.seconds
        // A size is "2160p"; a rate is "59.94p" or "59.94". Only a clear answer either way.
        let rates = hdmi.compactMap { piece -> Double? in
          let number = Double(piece.hasSuffix("p") ? String(piece.dropLast()) : piece)
          return number.flatMap { $0 > 0 && $0 < 240 ? $0 : nil }
        }
        let sizes = hdmi.filter { $0.hasSuffix("p") && (Double($0.dropLast()) ?? 0) >= 240 }
        let ambiguous = hdmi.contains { $0.contains("/") || $0 == "Auto" }
        let sizeMatches = sizes.contains(size), rateMatches = rates.contains { abs($0 - rate) < 0.02 }
        if sizeMatches && rateMatches { row.note = "Matches \(captureName)" }
        else if !ambiguous && ((!sizes.isEmpty && !sizeMatches) || (!rates.isEmpty && !rateMatches)) {
          row.note = "\(captureName) detects \(short)"; row.tone = .warning
        }
      }
      rows.append(row)
    }
    if let display = properties.first(where: { $0.role == .cameraDisplay }) {
      rows.append(Row(label: "Camera display", pieces: [display.value == .boolean(true) ? "On" : "Off"]))
    }
    let timecode = properties.first { $0.role == .timecodeOutput }
    if let timecode { rows.append(Row(label: "Timecode out", pieces: [UIControlPresentation.value(timecode)])) }
    let audio = values(.hdmiAudio)
    if !audio.isEmpty { rows.append(Row(label: "Audio on HDMI", pieces: audio)) }
    let picture = values(.colorProfile)
    let suggested = properties.first { $0.role == .colorProfile && $0.suggestedSourceProfileID != nil }?.suggestedSourceProfileID
    if !picture.isEmpty {
      var row = Row(label: "Picture", pieces: picture)
      if let suggested, Self.same(suggested, declaredProfileID) {
        row.note = "\(cameraName) declares \(UIHardwareText.profileShort(suggested))"
      }
      rows.append(row)
    }
    // One advisory, the worse first: a declaration that misreads the picture changes false
    // color and LUTs; missing timecode changes only the take's labels.
    if let suggested, !Self.same(suggested, declaredProfileID) {
      advisory = Advisory(title: declaredProfileID == "unspecified" ? "\(cameraName) has no source declared"
          : "\(cameraName) is declared \(UIHardwareText.profileShort(declaredProfileID))",
        detail: "The body reports \(picture.joined(separator: " "))",
        actionTitle: "Use \(UIHardwareText.profileShort(suggested))", action: .useSourceProfile(suggested))
    } else if timecodeMode == .source, let timecode, UIControlPresentation.value(timecode) == "Off",
      timecode.writable, let on = timecode.options.first(where: { $0.label == "On" }) {
      advisory = Advisory(title: "\(cameraName) records the source’s timecode", detail: "The body sends none on HDMI",
        actionTitle: "Turn On", action: .setProperty(timecode.id, on.value))
    }
  }

  /// No declaration reads as Rec.709, which is what an undeclared camera is treated as.
  static func same(_ suggested: String, _ declared: String) -> Bool {
    let declared = declared == "unspecified" ? "rec709-video" : declared
    return suggested == declared
  }
}

enum UIHardwareText {
  static func connector(_ connector: Connector) -> String {
    switch connector {
    case .hdmi: return "HDMI"
    case .sdi: return "SDI"
    case .usb: return "USB"
    case .network: return "Network"
    case .optical: return "Optical SDI"
    }
  }
  static func link(_ link: DeviceLinkKind) -> String? {
    switch link {
    case .thunderbolt: return "Thunderbolt"
    case .pcie: return "PCIe"
    case .usb: return "USB"
    case .ethernet: return "Ethernet"
    case .wifi: return "Wi-Fi"
    case .bluetooth: return "Bluetooth"
    case .software, .unknown: return nil
    }
  }
  /// Plugin values sometimes join two facts with a dot ("59.94p · 10-bit"): shown apart.
  static func pieces(_ value: String) -> [String] {
    value.components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }
  /// "S-Log3" for "S-Gamut3.Cine / S-Log3": the curve, which is what a person checks.
  static func profileShort(_ id: String) -> String {
    let title = SourceColorSpaceCatalog.title(id)
    return title.components(separatedBy: " / ").last ?? title
  }
  /// The body's battery in the unit it reports. Without a unit it's shown raw and never warns.
  static func battery(_ properties: [ControlProperty]) -> UIBattery? {
    guard let power = properties.first(where: { $0.role == .power }) else { return nil }
    let number: Int? = switch power.value {
    case .unsignedInteger(let value): Int(exactly: value)
    case .integer(let value): Int(exactly: value)
    default: nil
    }
    switch (power.unit, number) {
    case (.percent?, let value?): return .percent(value)
    case (.minutes?, let value?): return .minutes(value)
    default: return .unknown(UIControlPresentation.value(power))
    }
  }
  /// "2160p" with its rates, in the order the driver lists them: "23.976", "29.97", "59.94".
  static func formatGroups(_ modes: [SourceFormat]) -> [(size: String, rates: [String])] {
    var groups: [(size: String, rates: [String])] = []
    for mode in modes {
      let parts = FormatDisplayIdentity(mode).short.split(separator: " ").map(String.init)
      guard let size = parts.first else { continue }
      let rate = parts.dropFirst().joined(separator: " ")
      if let index = groups.firstIndex(where: { $0.size == size }) {
        if !groups[index].rates.contains(rate) { groups[index].rates.append(rate) }
      } else { groups.append((size, [rate])) }
    }
    return groups
  }
}

/// Every vendor's hardware in registry order: capture devices (listed, and absent ones a camera
/// is assigned to) and camera bodies (paired, and found by a scan).
@MainActor struct UISettingsHardwareGroups {
  struct Capture { var vendor: VendorDescriptor; var driver: DriverStatus?; var devices: [UIHardwareDevice] }
  struct Bodies {
    var vendor: VendorDescriptor
    /// False in a build without this vendor's SDK: saved pairings stay listed, muted.
    var available: Bool
    var bodies: [UIHardwareBody]
  }

  var capture: [Capture] = []
  var bodies: [Bodies] = []

  init(model: AppModel) {
    let cameras = model.feedDescriptors.map { descriptor in
      (descriptor: descriptor, camera: UIHardwareDevice.Camera(id: descriptor.id.rawValue, name: descriptor.name,
        running: model.isCameraRunning(descriptor.id)))
    }
    var vendors = model.captureVendors
    var byVendor: [String: [UIHardwareDevice]] = [:]
    let inventory = model.hardwareInventory
    for device in model.devices {
      guard let vendor = model.captureVendor(for: device.id) else { continue }
      if !vendors.contains(where: { $0.id == vendor.id }) { vendors.append(vendor) }
      let info = model.captureDevice(device.id)
      let label = model.devices.label(for: device.id) ?? device.name
      let nickname = inventory.nickname(for: device.id)
      byVendor[vendor.id, default: []].append(UIHardwareDevice(id: device.id, name: nickname ?? label,
        driverName: nickname == nil ? nil : label, present: true, model: info?.model,
        cameras: cameras.filter { $0.descriptor.selectedDevice == device.id }.map(\.camera),
        status: inventory.status(for: device.id), modes: info?.modes ?? []))
    }
    // Absent: only what a camera is assigned to, by the name it was last seen with.
    let listed = Set(model.devices.map(\.id))
    var absent: [String] = []
    for entry in cameras where !entry.descriptor.selectedDevice.isEmpty && !listed.contains(entry.descriptor.selectedDevice) {
      if !absent.contains(entry.descriptor.selectedDevice) { absent.append(entry.descriptor.selectedDevice) }
    }
    for id in absent {
      guard let pluginID = try? VendorRegistry.pluginID(for: id), let vendor = vendors.first(where: { $0.id == pluginID }) else { continue }
      let nickname = inventory.nickname(for: id)
      let lastName = inventory.lastKnownNames[id]
      byVendor[vendor.id, default: []].append(UIHardwareDevice(id: id,
        name: nickname ?? lastName.map { UIInputLabels.missingLabel(id: id, lastName: $0) } ?? UIInputLabels.missingLabel(id: id, lastName: nil),
        driverName: nickname == nil ? nil : lastName, present: false,
        cameras: cameras.filter { $0.descriptor.selectedDevice == id }.map(\.camera),
        hint: vendor.localizedMissingDeviceHint()))
    }
    let drivers = model.captureDrivers
    capture = vendors.map { Capture(vendor: $0, driver: drivers[$0.id], devices: byVendor[$0.id] ?? []) }

    let names = Dictionary(model.feedDescriptors.map { ($0.id.rawValue, $0.name) }, uniquingKeysWith: { first, _ in first })
    let controls = model.cameraControls
    bodies = model.controlVendors.compactMap { vendor in
      let assigned = (controls.assignments[vendor.id] ?? [:]).sorted { $0.key < $1.key }
      // A build without this SDK: no section unless something was paired, never a problem.
      guard vendor.sdkPresent || !assigned.isEmpty else { return nil }
      let scanned = controls.cameras[vendor.id]
      var list = assigned.map { feedID, assignment -> UIHardwareBody in
        let state = controls.state(for: feedID)
        return UIHardwareBody(camera: assignment.camera, feedID: feedID, cameraName: names[feedID],
          connected: vendor.sdkPresent && state.connected, lost: vendor.sdkPresent && state.lostAt != nil,
          retrying: vendor.sdkPresent && !state.connected && state.retrying,
          found: state.connected || scanned?.contains { $0.id == assignment.camera.id } == true,
          scanned: scanned != nil, properties: state.connected ? state.properties : [],
          notice: state.notice, noticeSeverity: state.noticeSeverity)
      }
      for camera in scanned ?? [] where !list.contains(where: { $0.camera.id == camera.id }) {
        list.append(UIHardwareBody(camera: camera, found: true, scanned: true))
      }
      return Bodies(vendor: vendor, available: vendor.sdkPresent, bodies: list)
    }
  }

  /// The capture device a camera uses, listed or absent.
  func device(forCamera cameraID: String) -> UIHardwareDevice? {
    capture.lazy.flatMap(\.devices).first { $0.cameras.contains { $0.id == cameraID } }
  }
}

/// Hardware for Copy Diagnostics: vendors, drivers, devices with nicknames, connectors, links,
/// bodies with firmware where known, and absent assigned devices. No credentials or addresses
/// beyond the body's local one.
enum UIHardwareDiagnostics {
  @MainActor static func lines(_ groups: UISettingsHardwareGroups) -> [String] {
    var lines = ["[Hardware]"]
    for group in groups.capture {
      let driver = group.driver.map { status in
        status.installed ? (status.supported ? "driver \(status.version ?? "unknown version")"
          : "driver \(status.version ?? "") unsupported: \(status.reason ?? "")") : "driver not installed"
      } ?? "driver unknown"
      lines.append("\(group.vendor.localizedDisplayName()) (\(group.vendor.id)): \(driver), SDK \(group.vendor.sdkVersion ?? "unknown")")
      if group.devices.isEmpty { lines.append("  No devices") }
      for device in group.devices {
        var parts = ["  \(device.name)"]
        if let driverName = device.driverName { parts.append("(\(driverName))") }
        parts.append(device.present ? "present" : "absent")
        if let model = device.model { parts.append("model \(model)") }
        parts.append("ID \(device.id)")
        if let status = device.status {
          if let connector = status.connector { parts.append("connector \(UIHardwareText.connector(connector))") }
          if let link = UIHardwareText.link(status.link) { parts.append("link \(link)") }
          switch status.availability {
          case .inUseHere: parts.append("in use here")
          case .inUseElsewhere: parts.append("in use by another app")
          case .free: parts.append("free")
          case .unknown: break
          }
          if let locked = status.signalLocked { parts.append(locked ? "signal locked" : "no signal") }
          for fact in status.facts where fact.id != "model" { parts.append("\(fact.label.lowercased()) \(fact.values.joined(separator: " "))") }
        }
        if !device.cameras.isEmpty { parts.append("for \(device.cameras.map(\.name).joined(separator: ", "))") }
        lines.append(parts.joined(separator: ", "))
      }
    }
    for group in groups.bodies {
      lines.append("\(group.vendor.localizedDisplayName()) (\(group.vendor.id)): \(group.available ? "SDK \(group.vendor.sdkVersion ?? "unknown")" : "not included in this build")")
      if group.bodies.isEmpty { lines.append("  No camera bodies paired") }
      for body in group.bodies {
        var parts = ["  \(body.camera.name)"]
        if let model = body.camera.model { parts.append("model \(model)") }
        if let firmware = body.camera.firmware { parts.append("firmware \(firmware)") }
        parts.append("ID \(body.camera.id)")
        parts.append(body.connectionText.lowercased())
        if let battery = body.battery {
          switch battery {
          case .percent(let value): parts.append("battery \(value)%")
          case .minutes(let value): parts.append("battery \(value) min")
          case .unknown(let value): parts.append("battery \(value), unit unknown")
          }
        }
        for warning in body.warnings { parts.append(UIControlPresentation.value(warning).lowercased()) }
        if let notice = body.notice { parts.append(notice) }
        if let camera = body.cameraName { parts.append("for \(camera)") }
        lines.append(parts.joined(separator: ", "))
      }
    }
    return lines
  }
}
