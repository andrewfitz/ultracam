import SwiftUI

/// The paired body's output timing (what it sends over HDMI), as rows of the inspector's
/// Camera Control section. They were the signal badge's menu on the strip; the badge is gone,
/// the signal's format is on the picture, and what is set once is in the inspector.
struct UICameraOutputTimingRows: View {
    let cameraID: String
    let store: CameraControlStore

    var body: some View {
        let state = store.state(for: cameraID)
        if store.assignment(for: cameraID) != nil, state.connected {
            ForEach(state.properties.filter { $0.role == .outputTiming }) { property in
                if property.writable, !property.options.isEmpty {
                    Picker(property.localizedLabel(), selection: Binding(get: { property.value }, set: { value in
                        Task { await store.set(property, value: value, feedID: cameraID) }
                    })) {
                        if !property.options.contains(where: { $0.value == property.value }) {
                            Text(UIControlPresentation.value(property)).tag(property.value)
                        }
                        ForEach(property.options) { Text($0.localizedLabel()).tag($0.value) }
                    }
                    .disabled(state.busy)
                } else {
                    LabeledContent(property.localizedLabel()) { Text(UIControlPresentation.value(property)) }
                }
            }
        }
    }
}
