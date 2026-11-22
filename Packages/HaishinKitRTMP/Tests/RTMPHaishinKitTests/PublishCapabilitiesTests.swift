import XCTest
@testable import RTMPHaishinKit

final class PublishCapabilitiesTests: XCTestCase {
    private func response(_ command: AMFObject? = nil, info: AMFObject = [:]) -> RTMPResponse {
        RTMPResponse(RTMPCommandMessage(streamId: 0, transactionId: 1, objectEncoding: .amf0,
            commandName: "_result", commandObject: command, arguments: [info]))
    }

    func testUnadvertisedAndLegacyCodecLists() {
        XCTAssertTrue(response().supportsVideoPublishing(fourCC: "av01"))
        XCTAssertTrue(response(["fourCcList": ["*"]]).supportsVideoPublishing(fourCC: "av01"))
        let list: AMFObject = ["fourCcList": ["hvc1"]]
        XCTAssertTrue(response(info: list).supportsVideoPublishing(fourCC: "hvc1"))
        XCTAssertFalse(response(info: list).supportsVideoPublishing(fourCC: "av01"))
        XCTAssertFalse(response(["fourCcList": [String]()]).supportsVideoPublishing(fourCC: "av01"))
    }

    func testDecoderAndForwarderCanAcceptPublishedVideo() {
        for flags in [1.0, 4.0, 6.0] {
            let map: AMFObject = ["av01": flags]
            XCTAssertTrue(response(["videoFourCcInfoMap": map]).supportsVideoPublishing(fourCC: "av01"))
        }
        let map: AMFObject = ["av01": 2.0, "hvc1": 4.0]
        let response = response(["fourCcList": ["*"]], info: ["videoFourCcInfoMap": AMFArray(map)])
        XCTAssertFalse(response.supportsVideoPublishing(fourCC: "av01"))
        XCTAssertTrue(response.supportsVideoPublishing(fourCC: "hvc1"))
        XCTAssertFalse(response.supportsVideoPublishing(fourCC: "vp09"))
        let wildcard: AMFObject = ["*": 4, "av01": 2]
        XCTAssertTrue(self.response(["videoFourCcInfoMap": wildcard]).supportsVideoPublishing(fourCC: "av01"))
    }

    func testInvalidMaskIsRejectedWithoutNumericOverflow() {
        for value in [Double.nan, Double.infinity, -1, 0, 0.5, Double.greatestFiniteMagnitude] {
            let map: AMFObject = ["av01": value]
            XCTAssertFalse(response(["videoFourCcInfoMap": map]).supportsVideoPublishing(fourCC: "av01"))
        }
    }

    func testCapabilityMapSurvivesConnectResponseWireEncoding() throws {
        let flags: AMFObject = ["hvc1": 4.0, "av01": 2.0]
        let commandMap = try wireResponse(["videoFourCcInfoMap": flags], capabilities: [:])
        let infoMap = try wireResponse(["fourCcList": ["*"]], capabilities: ["videoFourCcInfoMap": AMFArray(flags)])
        for result in [commandMap, infoMap] {
            XCTAssertFalse(result.supportsVideoPublishing(fourCC: "av01"))
            XCTAssertTrue(result.supportsVideoPublishing(fourCC: "hvc1"))
        }
    }

    func testLegacyCodecListSurvivesConnectResponseWireEncoding() throws {
        let result = try wireResponse(["fourCcList": ["av01", "hvc1"]], capabilities: [:])
        XCTAssertTrue(result.supportsVideoPublishing(fourCC: "av01"))
        XCTAssertTrue(result.supportsVideoPublishing(fourCC: "hvc1"))
        XCTAssertFalse(result.supportsVideoPublishing(fourCC: "vp09"))
    }

    private func wireResponse(_ advertised: AMFObject, capabilities: AMFObject) throws -> RTMPResponse {
        var info = capabilities
        info["code"] = "NetConnection.Connect.Success"
        let command = RTMPCommandMessage(streamId: 0, transactionId: 1, objectEncoding: .amf0,
            commandName: "_result", commandObject: advertised,
            arguments: [info])
        let buffer = RTMPChunkBuffer(chunkSize: command.payload.count)
        buffer.put(command.payload)
        let header = RTMPChunkMessageHeader(timestmap: 0, messageLength: command.payload.count,
            messageTypeId: command.type.rawValue, messageStreamId: 0)
        try header.put(buffer, chunkSize: command.payload.count)
        return RTMPResponse(try XCTUnwrap(header.makeMessage() as? RTMPCommandMessage))
    }
}
