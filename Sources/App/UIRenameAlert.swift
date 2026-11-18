import SwiftUI

extension View {
  /// The one rename prompt. Every entry point (Camera menu, the strip's ⋯ menu,
  /// the inspector) sends `.beginRename(cameraID:)`; the main window applies this once.
  func uiRenameAlert(_ context: UIContext) -> some View {
    modifier(UIRenameAlert(context: context))
  }
}

private struct UIRenameAlert: ViewModifier {
  let context: UIContext
  @State private var nameDraft = ""

  private var camera: UICameraPresentation? { context.session.renamingCameraID.flatMap { context.camera($0) } }

  /// The longest name: it's a toolbar pill, a menu title and "Ultracam · Name" in meeting apps.
  static let maxLength = 32

  private var trimmed: String { String(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxLength)) }

  /// Another camera, or Program's device when it's offered, already has this name: two
  /// devices would read the same.
  private var duplicate: Bool {
    guard let camera else { return false }
    let taken = context.presentation.cameras.filter { $0.id != camera.id }.map(\.name)
      + (context.presentation.programAvailable ? ["Program"] : [])
    return taken.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
  }

  private var message: String {
    if duplicate { return "“\(trimmed)” is already in use. Meeting apps list cameras by name, so choose another." }
    // The camera extension keeps the device name it published until it restarts.
    return "Meeting apps list the new name after Ultracam's camera restarts, for example after restarting your Mac."
  }

  func body(content: Content) -> some View {
    content
      .alert("Rename \(camera?.name ?? "Camera")", isPresented: Binding(
        get: { camera != nil },
        set: { if !$0 && context.session.renamingCameraID != nil { context.send(.endRename) } })) {
        TextField("Name", text: $nameDraft)
        Button("Rename") {
          if let camera, !trimmed.isEmpty, trimmed != camera.name, !duplicate {
            context.send(.renameCamera(cameraID: camera.id, name: trimmed))
          } else {
            context.send(.endRename)
          }
        }
        .disabled(trimmed.isEmpty || duplicate)
        Button("Cancel", role: .cancel) { context.send(.endRename) }
      } message: {
        Text(message)
      }
      .onChange(of: context.session.renamingCameraID, initial: true) { _, id in
        nameDraft = id.flatMap { context.camera($0)?.name } ?? ""
      }
      // Names stay short enough to read in a pill; a paste is cut at the limit.
      .onChange(of: nameDraft) { _, draft in
        if draft.count > Self.maxLength { nameDraft = String(draft.prefix(Self.maxLength)) }
      }
  }
}
