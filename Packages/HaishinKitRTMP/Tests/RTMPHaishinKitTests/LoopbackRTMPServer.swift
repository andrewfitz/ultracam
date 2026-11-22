import Foundation
import Network
@testable import RTMPHaishinKit

/// A minimal loopback RTMP ingest for wire tests. It completes the handshake, accepts
/// connect, createStream and publish, and records every media message with its absolute
/// timestamp as a receiver reconstructs it from the chunk headers.
final class LoopbackRTMPServer: @unchecked Sendable {
    struct Media: Equatable {
        let type: UInt8
        let timestamp: UInt32
        let payload: Data
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "org.ultracam.test.loopback-rtmp")
    private let lock = NSLock()
    private let answersCloseStream: Bool
    private var media: [Media] = []
    private var commands: [String] = []
    private var peers: [NWConnection] = []

    init(answersCloseStream: Bool = true) throws {
        self.answersCloseStream = answersCloseStream
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    deinit { stop() }

    /// Starts listening and returns the loopback URL to publish to.
    func start() async throws -> String {
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            // The listener reports state changes serially on `queue`.
            final class Once: @unchecked Sendable { var continuation: CheckedContinuation<UInt16, any Error>? }
            let once = Once()
            once.continuation = continuation
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    once.continuation?.resume(returning: listener.port?.rawValue ?? 0)
                    once.continuation = nil
                case .failed(let error):
                    once.continuation?.resume(throwing: error)
                    once.continuation = nil
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] peer in self?.accept(peer) }
            listener.start(queue: queue)
        }
        return "rtmp://127.0.0.1:\(port)/live"
    }

    func stop() {
        listener.cancel()
        lock.withLock { peers }.forEach { $0.cancel() }
    }

    var receivedMedia: [Media] { lock.withLock { media } }
    var receivedCommands: [String] { lock.withLock { commands } }

    private func accept(_ peer: NWConnection) {
        lock.withLock { peers.append(peer) }
        peer.start(queue: queue)
        let session = Session(server: self, peer: peer)
        session.receive()
    }

    fileprivate func record(_ message: Media) { lock.withLock { media.append(message) } }
    fileprivate func record(command: String) { lock.withLock { commands.append(command) } }
    fileprivate var repliesToCloseStream: Bool { answersCloseStream }

    /// Per-connection parser state. Only the server queue touches it.
    private final class Session: @unchecked Sendable {
        private weak var server: LoopbackRTMPServer?
        private let peer: NWConnection
        private var handshake = Data()
        private var handshakeDone = false
        private let reader = RTMPChunkBuffer()
        private let writer = RTMPChunkBuffer()
        private var headers: [UInt16: RTMPChunkMessageHeader] = [:]
        private var startTypes: [UInt16: RTMPChunkType] = [:]
        private var inProgress: Set<UInt16> = []
        private var absolute: [UInt16: UInt32] = [:]
        private var deltas: [UInt16: UInt32] = [:]

        init(server: LoopbackRTMPServer, peer: NWConnection) {
            self.server = server
            self.peer = peer
        }

        func receive() {
            peer.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, complete, error in
                if let data, !data.isEmpty { consume(data) }
                if complete || error != nil { peer.cancel(); return }
                receive()
            }
        }

        private func consume(_ data: Data) {
            guard handshakeDone else {
                handshake.append(data)
                if handshake.count >= 1 + 1536 { sendS0S1S2() }
                guard handshake.count >= 1 + 1536 + 1536 else { return }
                handshakeDone = true
                let rest = handshake.subdata(in: (1 + 1536 + 1536)..<handshake.count)
                if !rest.isEmpty { parse(rest) }
                return
            }
            parse(data)
        }

        private var sentS0S1S2 = false

        private func sendS0S1S2() {
            guard !sentS0S1S2 else { return }
            sentS0S1S2 = true
            var packet = Data([0x03])
            packet.append(Data(count: 1536))
            packet.append(handshake.subdata(in: 1..<(1 + 1536)))
            peer.send(content: packet, completion: .idempotent)
        }

        private func parse(_ data: Data) {
            reader.put(data)
            while reader.hasRemaining {
                let rollback = reader.position
                do {
                    let (type, chunkStreamId) = try reader.getBasicHeader()
                    let header = headers[chunkStreamId] ?? RTMPChunkMessageHeader()
                    headers[chunkStreamId] = header
                    try reader.getMessageHeader(type, messageHeader: header)
                    if !inProgress.contains(chunkStreamId) {
                        startTypes[chunkStreamId] = type
                        inProgress.insert(chunkStreamId)
                    }
                    guard let message = header.makeMessage() else { continue }
                    inProgress.remove(chunkStreamId)
                    header.reset()
                    let timestamp: UInt32
                    switch startTypes[chunkStreamId] ?? .zero {
                    case .zero:
                        timestamp = header.timestamp
                        deltas[chunkStreamId] = 0
                    case .one, .two:
                        deltas[chunkStreamId] = header.timestamp
                        timestamp = (absolute[chunkStreamId] ?? 0) &+ header.timestamp
                    case .three:
                        timestamp = (absolute[chunkStreamId] ?? 0) &+ (deltas[chunkStreamId] ?? 0)
                    }
                    absolute[chunkStreamId] = timestamp
                    handle(message, header: header, timestamp: timestamp)
                } catch {
                    reader.position = rollback
                    return
                }
            }
        }

        private func handle(_ message: some RTMPMessage, header: RTMPChunkMessageHeader, timestamp: UInt32) {
            switch message {
            case let message as RTMPSetChunkSizeMessage:
                reader.chunkSize = Int(message.size)
            case let message as RTMPCommandMessage:
                server?.record(command: message.commandName)
                reply(to: message)
            case is RTMPAudioMessage, is RTMPVideoMessage:
                server?.record(Media(type: header.messageTypeId, timestamp: timestamp, payload: message.payload))
            default:
                break
            }
        }

        private func reply(to command: RTMPCommandMessage) {
            let status: (String) -> AMFObject = { code in ["level": "status", "code": code, "description": ""] }
            switch command.commandName {
            case "connect":
                send(RTMPCommandMessage(streamId: 0, transactionId: command.transactionId, objectEncoding: .amf0,
                    commandName: "_result", commandObject: ["fmsVer": "FMS/3,0,1,123", "capabilities": 31.0],
                    arguments: [status("NetConnection.Connect.Success")]))
            case "createStream":
                send(RTMPCommandMessage(streamId: 0, transactionId: command.transactionId, objectEncoding: .amf0,
                    commandName: "_result", commandObject: nil, arguments: [1.0]))
            case "publish":
                send(RTMPCommandMessage(streamId: command.streamId, transactionId: 0, objectEncoding: .amf0,
                    commandName: "onStatus", commandObject: nil, arguments: [status("NetStream.Publish.Start")]))
            case "closeStream":
                guard server?.repliesToCloseStream == true else { return }
                send(RTMPCommandMessage(streamId: command.streamId, transactionId: 0, objectEncoding: .amf0,
                    commandName: "onStatus", commandObject: nil, arguments: [status("NetStream.Unpublish.Success")]))
            default:
                break
            }
        }

        private func send(_ message: RTMPCommandMessage) {
            var bytes = Data()
            for chunk in writer.putMessage(.zero, chunkStreamId: RTMPChunkStreamId.command.rawValue, message: message) {
                bytes.append(chunk)
            }
            peer.send(content: bytes, completion: .idempotent)
        }
    }
}
