import Foundation
import HaishinKit
import Network

final actor RTMPSocket {
    static let defaultWindowSizeC = Int(UInt8.max)
    typealias ReceivedData = (data: Data, receivedAt: DispatchTime)

    enum Error: Swift.Error {
        case invalidState
        case endOfStream
        case connectionTimedOut
        case connectionNotEstablished(_ error: NWError?)
    }

    /// Serializes and queues each complete RTMP message at the call site. A single
    /// socket writer sends the resulting chunks in order.
    final class Output: @unchecked Sendable {
        private static let maximumBytes = 16 * 1024 * 1024
        private let lock = NSLock()
        private let chunks = RTMPChunkBuffer()
        private var continuation: AsyncStream<Data>.Continuation?
        private var onOverflow: (@Sendable () -> Void)?
        private var pendingBytes = 0

        var queuedBytes: Int { lock.withLock { pendingBytes } }

        func start(_ continuation: AsyncStream<Data>.Continuation, onOverflow: @escaping @Sendable () -> Void) {
            lock.withLock {
                self.continuation = continuation
                self.onOverflow = onOverflow
                pendingBytes = 0
                chunks.chunkSize = RTMPChunkMessageHeader.chunkSize
            }
        }

        func stop() {
            lock.withLock {
                continuation?.finish()
                continuation = nil
                onOverflow = nil
            }
        }

        func setChunkSize(_ size: Int) {
            lock.withLock { chunks.chunkSize = size }
        }

        func send(_ data: Data) -> DispatchTime? {
            lock.withLock { enqueue([data]) ? .now() : nil }
        }

        func send(_ type: RTMPChunkType, chunkStreamId: RTMPChunkStreamId, message: some RTMPMessage) -> Int {
            lock.withLock {
                guard continuation != nil else { return 0 }
                let parts = Array(chunks.putMessage(type, chunkStreamId: chunkStreamId.rawValue, message: message))
                return !parts.isEmpty && enqueue(parts) ? message.payload.count : 0
            }
        }

        func didSend(_ count: Int) {
            lock.withLock { pendingBytes -= count }
        }

        private func enqueue(_ parts: [Data]) -> Bool {
            guard let continuation else { return false }
            let bytes = parts.reduce(0) { $0 + $1.count }
            guard bytes <= Self.maximumBytes - pendingBytes else {
                continuation.finish()
                self.continuation = nil
                onOverflow?()
                onOverflow = nil
                return false
            }
            pendingBytes += bytes
            parts.forEach { continuation.yield($0) }
            return true
        }
    }

    private(set) var pathReport: NWConnection.DataTransferReport.PathReport?
    private let timeout: Int
    private var connected = false
    private var closed = false
    private var windowSizeC = RTMPSocket.defaultWindowSizeC
    private var securityLevel: StreamSocketSecurityLevel = .none
    private var totalBytesIn = 0
    private var totalBytesOut = 0
    private var parameters: NWParameters = .tcp
    private var dataTransferReport: NWConnection.PendingDataTransferReport?
    private var connection: NWConnection? {
        didSet {
            oldValue?.viabilityUpdateHandler = nil
            oldValue?.stateUpdateHandler = nil
            oldValue?.forceCancel()
        }
    }
    private let output: Output
    private(set) var didOverflow = false
    private var qualityOfService: DispatchQoS = .userInitiated
    private var continuation: CheckedContinuation<Void, any Swift.Error>?
    private var connectTimeout: Task<Void, Never>?
    private lazy var networkQueue = DispatchQueue(label: "com.haishinkit.HaishinKit.RTMPSocket.network", qos: qualityOfService)

    init(output: Output, qualityOfService: DispatchQoS, securityLevel: StreamSocketSecurityLevel, timeout: Int) {
        self.output = output
        self.qualityOfService = qualityOfService
        self.timeout = timeout
        switch securityLevel {
        case .ssLv2, .ssLv3, .tlSv1, .negotiatedSSL:
            parameters = .tls
        default:
            parameters = .tcp
        }
    }

    func connect(_ name: String, port: Int) async throws {
        try Task.checkCancellation()
        guard !closed, connection == nil else {
            throw Error.invalidState
        }
        totalBytesIn = 0
        totalBytesOut = 0
        pathReport = nil
        do {
            let connection = NWConnection(to: NWEndpoint.hostPort(host: .init(name), port: .init(integerLiteral: NWEndpoint.Port.IntegerLiteralType(port))), using: parameters)
            self.connection = connection
            try await withCheckedThrowingContinuation { (checkedContinuation: CheckedContinuation<Void, Swift.Error>) in
                self.continuation = checkedContinuation
                connectTimeout = Task {
                    let seconds = min(UInt64(clamping: timeout), UInt64.max / 1_000_000_000)
                    do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) } catch { return }
                    guard let continuation else {
                        return
                    }
                    continuation.resume(throwing: Error.connectionTimedOut)
                    self.continuation = nil
                    close()
                }
                connection.stateUpdateHandler = { state in
                    Task { await self.stateDidChange(to: state) }
                }
                connection.viabilityUpdateHandler = { viability in
                    Task { await self.viabilityDidChange(to: viability) }
                }
                connection.start(queue: networkQueue)
            }
        } catch {
            throw error
        }
    }

    func recv() -> AsyncStream<ReceivedData> {
        AsyncStream<ReceivedData> { continuation in
            Task {
                defer { continuation.finish() }
                do {
                    while connected {
                        let received = try await recv()
                        continuation.yield(received)
                        totalBytesIn += received.data.count
                    }
                } catch {}
            }
        }
    }

    func close(_ error: NWError? = nil) {
        guard !closed else { return }
        closed = true
        connectTimeout?.cancel()
        connectTimeout = nil
        if let continuation {
            continuation.resume(throwing: Error.connectionNotEstablished(error))
            self.continuation = nil
        }
        connected = false
        output.stop()
        connection = nil
        continuation = nil
        dataTransferReport = nil
        pathReport = nil
    }

    private func stateDidChange(to state: NWConnection.State) {
        guard !closed else { return }
        switch state {
        case .ready:
            logger.info("Connection is ready.")
            connected = true
            let (stream, continuation) = AsyncStream<Data>.makeStream()
            Task {
                do {
                    for await data in stream {
                        guard connected else { return }
                        try await send(data)
                        guard connected else { return }
                        totalBytesOut += data.count
                        output.didSend(data.count)
                    }
                } catch {
                    close(error as? NWError)
                }
            }
            output.start(continuation) { [weak self] in
                Task { await self?.overflowed() }
            }
            self.dataTransferReport = connection?.startDataTransferReport()
            self.continuation?.resume()
            self.continuation = nil
            connectTimeout?.cancel()
            connectTimeout = nil
        case .waiting(let error):
            logger.warn("Connection waiting:", error)
            close(error)
        case .setup:
            logger.debug("Connection is setting up.")
        case .preparing:
            logger.debug("Connection is preparing.")
        case .failed(let error):
            logger.warn("Connection failed:", error)
            close(error)
        case .cancelled:
            logger.info("Connection cancelled.")
            close()
        @unknown default:
            logger.error("Unknown connection state.")
        }
    }

    private func overflowed() {
        didOverflow = true
        close()
    }

    private func viabilityDidChange(to viability: Bool) {
        logger.info("Connection viability changed to ", viability)
        if viability == false {
            close()
        }
    }

    private func send(_ data: Data) async throws {
        return try await withCheckedThrowingContinuation { continuation in
            guard let connection else {
                continuation.resume(throwing: Error.invalidState)
                return
            }
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume()
            })
        }
    }

    private func updateTransportStatistics() async {
        guard let connection, let dataTransferReport else {
            return
        }
        self.dataTransferReport = connection.startDataTransferReport()
        let report = await withCheckedContinuation { continuation in
            dataTransferReport.collect(queue: networkQueue) { report in
                continuation.resume(returning: report)
            }
        }
        guard connected else {
            return
        }
        pathReport = report.aggregatePathReport
    }

    private func recv() async throws -> ReceivedData {
        return try await withCheckedThrowingContinuation { continuation in
            guard let connection else {
                continuation.resume(throwing: Error.invalidState)
                return
            }
            connection.receive(minimumIncompleteLength: 0, maximumLength: windowSizeC) { content, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let content {
                    continuation.resume(returning: (content, .now()))
                } else {
                    continuation.resume(throwing: Error.endOfStream)
                }
            }
        }
    }
}

extension RTMPSocket: NetworkTransportReporter {
    // MARK: NetworkTransportReporter
    func makeNetworkMonitor() async -> NetworkMonitor {
        return .init(self)
    }

    func makeNetworkTransportReport() async -> NetworkTransportReport {
        await updateTransportStatistics()
        return .init(queueBytesOut: output.queuedBytes, totalBytesIn: totalBytesIn, totalBytesOut: totalBytesOut)
    }
}
