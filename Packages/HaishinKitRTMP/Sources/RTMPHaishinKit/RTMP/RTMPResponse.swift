import Foundation

/// The metadata  associated with the response to an RTMP protocol request.
public struct RTMPResponse: Sendable {
    /// The RTMP response status.
    public let status: RTMPStatus?
    /// The RTMP response arguments.
    public let arguments: [(any Sendable)?]
    private let commandObject: AMFObject?

    init(status: RTMPStatus?, arguments: [(any Sendable)?] = []) {
        self.status = status
        self.arguments = arguments
        commandObject = nil
    }

    init(_ message: RTMPCommandMessage) {
        arguments = message.arguments
        commandObject = message.commandObject
        status = arguments.isEmpty ? nil : .init(arguments.first as? AMFObject)
    }

    /// Servers may omit codec capabilities. When provided, honor their declared
    /// ability to receive the requested bitstream, including wildcard forwarders.
    public func supportsVideoPublishing(fourCC: String) -> Bool {
        let objects = [commandObject].compactMap { $0 } + arguments.compactMap(Self.object)
        for object in objects {
            if let map = Self.object(object["videoFourCcInfoMap"] ?? nil) {
                let mask = Self.flags(map[fourCC] ?? nil) | Self.flags(map["*"] ?? nil)
                return mask & (RTMPConnection.FourCcInfoMask.canDecode.rawValue | RTMPConnection.FourCcInfoMask.canForward.rawValue) != 0
            }
        }
        for object in objects {
            if let list = object["fourCcList"] as? [(any Sendable)?] {
                return list.contains { ($0 as? String) == fourCC || ($0 as? String) == "*" }
            }
        }
        return true
    }

    private static func object(_ value: (any Sendable)?) -> AMFObject? {
        (value as? AMFObject) ?? (value as? AMFArray)?.dict
    }

    private static func flags(_ value: (any Sendable)?) -> Int {
        if let flags = value as? Int, flags >= 0 { return flags }
        guard let number = value as? Double, number >= 0 else { return 0 }
        return Int(exactly: number) ?? 0
    }
}
