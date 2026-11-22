import Foundation
import Network
import XCTest
@testable import RTMPHaishinKit

final class ConnectionLifecycleTests: XCTestCase, @unchecked Sendable {
    func testCloseDuringTLSAndRTMPHandshake() async throws {
        for scheme in ["rtmps", "rtmp"] {
            let queue = DispatchQueue(label: "org.ultracam.test.stalled-handshake")
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            defer { listener.cancel() }
            let ready = expectation(description: "\(scheme) test listener ready")
            let handshake = expectation(description: "\(scheme) client sent its handshake")
            let eof = expectation(description: "\(scheme) client released its socket")
            let finished = expectation(description: "\(scheme) connect returned")
            listener.stateUpdateHandler = { state in
                if case .ready = state { ready.fulfill() }
            }
            listener.newConnectionHandler = { peer in
                peer.start(queue: queue)
                Self.drain(peer, firstBytes: handshake, eof: eof)
            }
            listener.start(queue: queue)
            await fulfillment(of: [ready], timeout: 2)
            let port = try XCTUnwrap(listener.port?.rawValue)

            let connection = RTMPConnection()
            let connecting = Task {
                defer { finished.fulfill() }
                do {
                    _ = try await connection.connect("\(scheme)://127.0.0.1:\(port)/live")
                    XCTFail("A peer that withholds its handshake cannot connect")
                } catch {}
            }
            defer { connecting.cancel() }
            await fulfillment(of: [handshake], timeout: 2)
            try await connection.close()
            await fulfillment(of: [eof, finished], timeout: 2)
        }
    }

    func testPermanentCloseBeforeConnectPreventsANewAttempt() async {
        let connection = RTMPConnection()
        await connection.closePermanently()
        do {
            _ = try await connection.connect("rtmp://127.0.0.1:1/live")
            XCTFail("A closed connection accepted a new attempt")
        } catch RTMPConnection.Error.invalidState {
            return
        } catch {
            XCTFail("A closed connection attempted to open a socket")
        }
    }

    func testOutputQueuePreservesOrderAndClosesAtItsByteLimit() async {
        let output = RTMPSocket.Output()
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        let overflow = expectation(description: "output queue overflow")
        output.start(continuation) { overflow.fulfill() }
        XCTAssertNotNil(output.send(Data([1])))
        XCTAssertNotNil(output.send(Data([2])))
        let payload = Data(repeating: 0, count: 16 * 1024 * 1024)
        XCTAssertNil(output.send(payload))
        XCTAssertNil(output.send(Data([3])))
        await fulfillment(of: [overflow], timeout: 1)
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        let end = await iterator.next()
        XCTAssertEqual(first, Data([1]))
        XCTAssertEqual(second, Data([2]))
        XCTAssertNil(end)
        XCTAssertEqual(output.queuedBytes, 2)
    }

    private static func drain(_ peer: NWConnection, firstBytes: XCTestExpectation? = nil, eof: XCTestExpectation) {
        peer.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
            if let data, !data.isEmpty { firstBytes?.fulfill() }
            if complete || error != nil {
                eof.fulfill()
                peer.cancel()
            } else {
                drain(peer, eof: eof)
            }
        }
    }
}
