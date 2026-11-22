import CoreMedia
import Foundation
import XCTest
@testable import RTMPHaishinKit

final class PublishWireTests: XCTestCase {
    private let av1Configuration = Data([0x81, 0x04, 0x0c, 0x00])
    private let temporalUnit = Data([0x12, 0x00, 0x32, 0x01, 0xa0])

    func testAV1ConfigurationAndTemporalUnitEnvelope() throws {
        let format = try makeFormat(kCMVideoCodecType_AV1, atom: "av1C", configuration: av1Configuration)
        let configuration = try XCTUnwrap(RTMPVideoMessage(streamId: 1, timestamp: 0, formatDescription: format))
        XCTAssertEqual(configuration.payload, Data([0x90]) + Data("av01".utf8) + av1Configuration)

        let sample = try makeSample(format, data: temporalUnit, pts: 1000, dts: 1000)
        let frame = try XCTUnwrap(RTMPVideoMessage(streamId: 1, timestamp: 0, sampleBuffer: sample))
        XCTAssertEqual(frame.payload, Data([0x91]) + Data("av01".utf8) + temporalUnit)
        XCTAssertEqual(frame.compositionTime, 0)
    }

    func testAVCWithoutLegacyBiasAndSignedCompositionTime() throws {
        let format = try makeFormat(kCMVideoCodecType_H264, atom: "avcC", configuration: Data([0x01]))
        let sample = try makeSample(format, data: Data([0x00, 0x00, 0x00, 0x01, 0x65]), pts: 990, dts: 1000)
        let original = try XCTUnwrap(RTMPVideoMessage(streamId: 1, timestamp: 0, sampleBuffer: sample))
        XCTAssertEqual(original.compositionTime, 56)
        let external = try XCTUnwrap(RTMPVideoMessage(streamId: 1, timestamp: 0, sampleBuffer: sample, usesLegacyCompositionOffset: false))
        XCTAssertEqual(external.payload.prefix(5), Data([0x17, 0x01, 0xff, 0xff, 0xf6]))
        XCTAssertEqual(external.compositionTime, -10)
    }

    func testHEVCExternalNoReorderingUsesCodedFramesX() throws {
        let format = try makeFormat(kCMVideoCodecType_HEVC, atom: "hvcC", configuration: Data([0x01]))
        let data = Data([0x00, 0x00, 0x00, 0x02, 0x26, 0x01])
        let sample = try makeSample(format, data: data, pts: 1000, dts: 1000)
        let message = try XCTUnwrap(RTMPVideoMessage(streamId: 1, timestamp: 0, sampleBuffer: sample, usesLegacyCompositionOffset: false))
        XCTAssertEqual(message.payload, Data([0x93]) + Data("hvc1".utf8) + data)
        XCTAssertEqual(message.compositionTime, 0)
        let decoded = try XCTUnwrap(message.makeSampleBuffer(sample.presentationTimeStamp, formatDesciption: format))
        XCTAssertEqual(decoded.presentationTimeStamp, sample.presentationTimeStamp)
        XCTAssertEqual(try decoded.dataBuffer?.dataBytes(), data)
    }

    func testExtendedTimestampIsPresentOnEveryChunk() throws {
        let chunkSize = 3
        let writer = RTMPChunkBuffer(chunkSize: chunkSize)
        let data = Data(1...8)
        for timestamp: UInt32 in [0xfffffe, 0xffffff, 0x01234567] {
            let message = VideoPayload(timestamp: timestamp, payload: data)
            let chunks = Array(writer.putMessage(.zero, chunkStreamId: 320, message: message))
            let extended = timestamp >= 0xffffff
            XCTAssertEqual(chunks.count, 3)
            XCTAssertEqual(chunks[0].count, 3 + 11 + (extended ? 4 : 0) + 3)
            XCTAssertEqual(chunks[1].count, 3 + (extended ? 4 : 0) + 3)
            XCTAssertEqual(chunks[2].count, 3 + (extended ? 4 : 0) + 2)
            XCTAssertEqual(chunks[0].prefix(3), Data([0x01, 0x00, 0x01]))

            let reader = RTMPChunkBuffer(chunkSize: chunkSize)
            let header = RTMPChunkMessageHeader()
            for chunk in chunks {
                reader.put(chunk)
                let (type, streamID) = try reader.getBasicHeader()
                XCTAssertEqual(streamID, 320)
                try reader.getMessageHeader(type, messageHeader: header)
            }
            XCTAssertEqual(header.timestamp, timestamp)
            XCTAssertEqual(header.messageStreamId, message.streamId)
            XCTAssertEqual(header.makeMessage()?.payload, data)
        }
    }

    func testTrackCanStartLateAndResetItsEpochOnReconnect() throws {
        var timestamp = RTMPTimestamp<CMTime>()
        XCTAssertEqual(try timestamp.update(CMTime(value: 100_250, timescale: 1000), firstOffset: 0.2), 200)
        XCTAssertEqual(try timestamp.update(CMTime(value: 100_375, timescale: 1000)), 125)
        XCTAssertThrowsError(try timestamp.update(.positiveInfinity))
        timestamp.clear()
        XCTAssertEqual(try timestamp.update(CMTime(value: 200_000, timescale: 1000), firstOffset: -0.00001), 0)
    }

    private struct VideoPayload: RTMPMessage {
        let type = RTMPMessageType.video
        let streamId: UInt32 = 9
        let timestamp: UInt32
        let payload: Data
    }

    private func makeFormat(_ codec: CMVideoCodecType, atom: String, configuration: Data) throws -> CMVideoFormatDescription {
        var result: CMVideoFormatDescription?
        let extensions = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [atom: configuration]] as CFDictionary
        XCTAssertEqual(CMVideoFormatDescriptionCreate(allocator: nil, codecType: codec,
            width: 128, height: 72, extensions: extensions, formatDescriptionOut: &result), noErr)
        return try XCTUnwrap(result)
    }

    private func makeSample(_ format: CMVideoFormatDescription, data: Data, pts: Int64, dts: Int64) throws -> CMSampleBuffer {
        var sample: CMSampleBuffer?
        var buffer: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateEmpty(allocator: nil, capacity: 2, flags: 0, blockBufferOut: &buffer), noErr)
        let block = try XCTUnwrap(buffer)
        // Exercise the same packet build when a compressed sample spans multiple memory blocks.
        for length in [2, data.count - 2] {
            XCTAssertEqual(CMBlockBufferAppendMemoryBlock(block, memoryBlock: nil, length: length,
                blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: length,
                flags: kCMBlockBufferAssureMemoryNowFlag), noErr)
        }
        XCTAssertFalse(CMBlockBufferIsRangeContiguous(block, atOffset: 0, length: data.count))
        XCTAssertEqual(data.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }, noErr)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: pts, timescale: 1000),
                                        decodeTimeStamp: CMTime(value: dts, timescale: 1000))
        var size = data.count
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
}
