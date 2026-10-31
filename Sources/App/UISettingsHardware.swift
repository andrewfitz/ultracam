import SwiftUI

/// Settings › Hardware: every capture device and camera body Ultracam knows, one section per
/// vendor in registry order, with the camera each is assigned to. A capture device's own
/// settings (its plugin's, such as the input connector) sit under it.
///
/// This is the working shell. Phase 5 replaces the rows with expanding ones (health, link,
/// facts, absent hardware, the Setup block) once the plugin API reports them, and moves
/// pairing here. Vendor names come only from each plugin's descriptor.
struct UISettingsHardwarePane: View {
  let model: AppModel
  var interface: UIInterfaceState = UIAppEnvironment.interface

  var body: some View {
    let groups = UISettingsHardwareGroups(model: model)
    UISettingsPane {
      if let warning = model.driverWarning {
        Section {
          Label { Text(warning).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: UISymbol.warning).foregroundStyle(.orange)
          }
        }
      }
      ForEach(groups.capture, id: \.vendor.id) { group in
        Section {
          if group.devices.isEmpty {
            Text("No devices connected").foregroundStyle(.secondary)
          }
          ForEach(group.devices) { device in
            deviceRow(device)
            UISettingsDeviceSettings(model: model, device: device)
          }
        } header: { Text(group.vendor.localizedDisplayName()) }
      }
      if groups.capture.isEmpty {
        Section("Capture Devices") {
          Text("Connect a capture device to see it here.").foregroundStyle(.secondary)
        }
      }
      ForEach(groups.bodies, id: \.vendor.id) { group in
        Section {
          ForEach(group.bodies, id: \.feedID) { body in
            LabeledContent {
              HStack(spacing: 8) {
                Text(body.connected ? "Connected" : "Not connected").foregroundStyle(.secondary)
                cameraChip(body.cameraName)
              }
            } label: {
              Label { Text(body.name) } icon: { Image(systemName: UISymbol.cameraBody) }
            }
          }
          if group.bodies.isEmpty {
            Text("No camera body paired").foregroundStyle(.secondary)
          }
        } header: { Text(group.vendor.localizedDisplayName()) } footer: {
          UISettingsFootnote("Pair a camera body from its camera’s ⋯ menu, Camera Control….")
        }
      }
      if let message = model.vendorSettings.persistenceMessage {
        Section {
          Label(message, systemImage: UISymbol.warning).foregroundStyle(.orange)
        }
      }
    }
  }

  private func deviceRow(_ device: InputDevice) -> some View {
    let cameras = model.feedDescriptors.filter { $0.selectedDevice == device.id }.map(\.name)
    return LabeledContent {
      HStack(spacing: 8) {
        if cameras.isEmpty { Text("Not assigned").foregroundStyle(.secondary) }
        ForEach(cameras, id: \.self) { cameraChip($0) }
      }
    } label: {
      Label { Text(model.devices.label(for: device.id) ?? device.name).font(.uiRowEmphasis) } icon: {
        Image(systemName: UISymbol.input)
      }
      if model.devices.label(for: device.id) != device.name { Text(device.name) }
    }
  }

  private func cameraChip(_ name: String?) -> some View {
    Text(name ?? "No camera")
      .font(.uiMeta)
      .foregroundStyle(name == nil ? .secondary : .primary)
      .padding(.horizontal, 6).frame(minHeight: 18)
      .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 5))
  }
}

/// What the Hardware tab lists: capture devices by vendor and paired camera bodies by vendor,
/// both in registry order. A device whose vendor isn't known still gets a section.
@MainActor struct UISettingsHardwareGroups {
  struct Capture { var vendor: VendorDescriptor; var devices: [InputDevice] }
  struct Body { var feedID: String; var name: String; var cameraName: String?; var connected: Bool }
  struct Bodies { var vendor: VendorDescriptor; var bodies: [Body] }

  var capture: [Capture] = []
  var bodies: [Bodies] = []

  init(model: AppModel) {
    var vendors = model.captureVendors
    var byVendor: [String: [InputDevice]] = [:]
    for device in model.devices {
      guard let vendor = model.captureVendor(for: device.id) else { continue }
      if !vendors.contains(where: { $0.id == vendor.id }) { vendors.append(vendor) }
      byVendor[vendor.id, default: []].append(device)
    }
    capture = vendors.map { Capture(vendor: $0, devices: byVendor[$0.id] ?? []) }
    let names = Dictionary(model.feedDescriptors.map { ($0.id.rawValue, $0.name) }, uniquingKeysWith: { first, _ in first })
    let controls = model.cameraControls
    bodies = model.controlVendors.filter(\.sdkPresent).map { vendor in
      let assigned = (controls.assignments[vendor.id] ?? [:]).sorted { $0.key < $1.key }
      return Bodies(vendor: vendor, bodies: assigned.map { feedID, assignment in
        Body(feedID: feedID, name: assignment.camera.name, cameraName: names[feedID],
          connected: controls.state(for: feedID).connected)
      })
    }
  }
}
