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
    /// The picture's camera-settings overlay: one typed piece per field, set apart by spacing, never joined with dots.
    /// A value in camera notation stands alone ("ƒ/2.8", "1/50"); any other keeps its label ("ISO 800").
    static func overlayPieces(_ properties: [ControlProperty], compact: Bool = false, in bundle: Bundle = .main) -> [String] {
        overlayFields(properties, compact: compact).map { property in
            let shown = value(property, in: bundle)
            return notation(shown) ?? "\(property.localizedLabel(in: bundle)) \(shown)"
        }
    }
    /// The overlay as one line with every field's full name, for VoiceOver and help.
    static func overlay(_ properties: [ControlProperty], compact: Bool = false, in bundle: Bundle = .main) -> String {
        overlayFields(properties, compact: compact).map { "\($0.localizedLabel(in: bundle)) \(value($0, in: bundle))" }
            .joined(separator: ", ")
    }
    private static func overlayFields(_ properties: [ControlProperty], compact: Bool) -> [ControlProperty] {
        let fields = properties.filter { $0.overlayOrder != nil }.sorted { $0.overlayOrder! < $1.overlayOrder! }
        return compact ? Array(fields.prefix(3)) : fields
    }
    /// A value that already says what it measures, as a camera's own display writes it, or nil.
    /// Read from the value's notation, never a vendor's IDs: aperture "ƒ/2.8", shutter "1/50"
    /// (its " s" dropped) or "0.5 s", shutter angle "180°", color temperature "5600 K", and
    /// focus modes "AF-C", "MF". ISO 800, Auto or Daylight alone wouldn't say what they are.
    static func notation(_ value: String) -> String? {
        func number(_ text: Substring) -> Bool {
            !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") } && Double(text) != nil
        }
        if value.hasPrefix("ƒ/") || value.hasPrefix("f/") { return number(value.dropFirst(2)) ? value : nil }
        if value.hasPrefix("1/") {
            let denominator = value.hasSuffix(" s") ? value.dropFirst(2).dropLast(2) : value.dropFirst(2)
            return number(denominator) ? "1/\(denominator)" : nil
        }
        if value.hasSuffix(" s"), number(value.dropLast(2)) { return value }
        if value.hasSuffix("°"), number(value.dropLast()) { return value }
        if value.hasSuffix(" K"), number(value.dropLast(2)) { return value }
        if ["MF", "DMF"].contains(value) || value.hasPrefix("AF-") && value.count == 4 { return value }
        return nil
    }
}
