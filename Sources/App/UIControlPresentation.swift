import Foundation

/// Presentation consumes plugin metadata and typed values, never vendor IDs.
enum UIControlPresentation {
    enum Badge: Equatable { case asset(String), text(String) }
    static func badge(_ descriptor: VendorDescriptor, assetAvailable: (String) -> Bool = { _ in true }) -> Badge {
        if let name = descriptor.badgeAssetName, !name.isEmpty, assetAvailable(name) { return .asset(name) }
        return .text(descriptor.badgeText)
    }
    static func value(_ property: ControlProperty, in bundle: Bundle = .main) -> String {
        property.currentValueLabel ?? property.options.first(where: { $0.value == property.value })?.localizedLabel(in: bundle) ?? value(property.value)
    }
    static func value(_ value: ControlValue) -> String {
        switch value {
        case .boolean(let value): return value ? "On" : "Off"
        case .integer(let value): return String(value)
        case .unsignedInteger(let value): return String(value)
        case .decimal(let value): return String(value)
        case .text(let value), .choice(let value): return value
        }
    }
    static func overlay(_ properties: [ControlProperty], compact: Bool = false, in bundle: Bundle = .main) -> String {
        let fields = properties.filter { $0.overlayOrder != nil }.sorted { $0.overlayOrder! < $1.overlayOrder! }
        return (compact ? Array(fields.prefix(3)) : fields).map { "\($0.localizedLabel(in: bundle)) \(value($0, in: bundle))" }.joined(separator: " · ")
    }
}
