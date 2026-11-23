@preconcurrency import AVFAudio
import CoreMedia
import HaishinKit
import XCTest
@testable import RTMPHaishinKit

final class PublishTimelineTests: XCTestCase {
    func testPictureEpochAppliesAACPrimingOnlyWhenAudioIsExpected() async throws {
        let videoOnlyTimestamp = try await firstPictureTimestamp(includesAudio: false)
        XCTAssertEqual(videoOnlyTimestamp, 125)
        let pairedTimestamp = try await firstPictureTimestamp(includesAudio: true)
        XCTAssertEqual(Int(pairedTimestamp), 169, accuracy: 1)
    }

    private func firstPictureTimestamp(includesAudio: Bool) async throws -> UInt32 {
        let server = try LoopbackRTMPServer()
        defer { server.stop() }
        let url = try await server.start()
        let connection = RTMPConnection()
        let stream = RTMPStream(connection: connection)
        try await stream.setAudioSettings(AudioCodecSettings(bitRate: 160_000, sampleRate: 48_000))
        _ = try await connection.connect(url)
        _ = try await stream.publish("key")
        let epoch = CMTime(value: 100, timescale: 1)
        await stream.setPublishEpoch(epoch, includesAudio: includesAudio)
        // The first input picture was dropped before the transport saw it.
        let pictureTime = epoch + CMTime(value: 125, timescale: 1000)
        await stream.appendEncodedVideo(try Self.picture(at: pictureTime))

        let deadline = Date(timeIntervalSinceNow: 5)
        while Date() < deadline {
            if let video = server.receivedMedia.first(where: { $0.type == 9 && $0.payload.dropFirst().first == 1 }) {
                await connection.closePermanently(gracefully: false)
                return video.timestamp
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The receiver did not get a coded picture")
        await connection.closePermanently(gracefully: false)
        throw CancellationError()
    }

    /// FLV has no edit list, so a receiver plays the AAC encoder's 2112 priming samples.
    /// A picture and the PCM captured with it must still decode at the same time.
    func testPictureAndPCMAtTheEpochDecodeTogetherAfterAACPriming() async throws {
        let server = try LoopbackRTMPServer()
        defer { server.stop() }
        let url = try await server.start()
        let connection = RTMPConnection()
        let stream = RTMPStream(connection: connection)
        try await stream.setAudioSettings(AudioCodecSettings(bitRate: 160_000, sampleRate: 48_000))
        _ = try await connection.connect(url)
        _ = try await stream.publish("key")

        let start = CMTimeConvertScale(CMClockGetTime(CMClockGetHostTimeClock()), timescale: 48_000,
                                       method: .roundHalfAwayFromZero).value
        let epoch = CMTime(value: start, timescale: 48_000)
        await stream.setPublishEpoch(epoch)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        for index in 0..<24 {
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
            pcm.frameLength = 1024
            for channel in 0..<2 { pcm.floatChannelData![channel].update(repeating: 0, count: 1024) }
            let sample = start + Int64(index * 1024)
            let host = CMClockConvertHostTimeToSystemUnits(CMTime(value: sample, timescale: 48_000))
            await stream.append(pcm, when: AVAudioTime(hostTime: host, sampleTime: sample, atRate: 48_000))
        }
        await stream.appendEncodedVideo(try Self.picture(at: epoch))

        let (audio, video) = try await Self.firstCodedFrames(server)
        XCTAssertEqual(Int(video) - Int(audio), 44, accuracy: 1,
                       "The picture at the epoch must follow the first AAC packet by the 2112-sample priming")
        await connection.closePermanently(gracefully: false)
    }

    /// The first raw AAC and coded video timestamps, excluding sequence headers.
    static func firstCodedFrames(_ server: LoopbackRTMPServer, timeout: TimeInterval = 5) async throws -> (UInt32, UInt32) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            let media = server.receivedMedia
            let audio = media.first { $0.type == 8 && $0.payload.count > 1 && $0.payload[1] == 1 }
            let video = media.first { $0.type == 9 && $0.payload.count > 1 && $0.payload[1] == 1 }
            if let audio, let video { return (audio.timestamp, video.timestamp) }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The receiver did not get both tracks: \(server.receivedMedia.map(\.type))")
        throw CancellationError()
    }

    static func picture(at time: CMTime) throws -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        let extensions = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["avcC": Data([0x01])]] as CFDictionary
        XCTAssertEqual(CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_H264,
            width: 128, height: 72, extensions: extensions, formatDescriptionOut: &format), noErr)
        let bytes = Data([0x00, 0x00, 0x00, 0x01, 0x65])
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes.count,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block), noErr)
        let data = try XCTUnwrap(block)
        XCTAssertEqual(bytes.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: data, offsetIntoDestination: 0, dataLength: bytes.count)
        }, noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: time, decodeTimeStamp: time)
        var size = bytes.count
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: nil, dataBuffer: data, formatDescription: try XCTUnwrap(format),
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
}

final class GracefulCloseBoundTests: XCTestCase {
    /// ProgramStreamSession gives a previous publisher five seconds to close before a new
    /// publish under the same key. A destination that never confirms closeStream must not
    /// hold a graceful close past the RTMP request timeout.
    func testGracefulCloseOfASilentDestinationEndsWithinTheRequestTimeout() async throws {
        let server = try LoopbackRTMPServer(answersCloseStream: false)
        defer { server.stop() }
        let url = try await server.start()
        let connection = RTMPConnection()
        let stream = RTMPStream(connection: connection)
        _ = try await connection.connect(url)
        _ = try await stream.publish("key")
        let started = ProcessInfo.processInfo.systemUptime
        await connection.closePermanently(gracefully: true)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertTrue(server.receivedCommands.contains("closeStream"))
        XCTAssertGreaterThanOrEqual(elapsed, Double(RTMPConnection.defaultRequestTimeout) / 1000 - 0.1)
        XCTAssertLessThan(elapsed, 4, "Graceful close took \(elapsed) s")
        let connected = await connection.connected
        XCTAssertFalse(connected)
    }
}
