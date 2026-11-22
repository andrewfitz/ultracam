import AVFoundation
import CoreMedia
import Foundation

protocol RTMPTimeConvertible {
    var seconds: TimeInterval { get }
}

private let kRTMPTimestamp_defaultTimeInterval: TimeInterval = 0

struct RTMPTimestamp<T: RTMPTimeConvertible> {
    enum Error: Swift.Error {
        case invalidSequence
    }

    private var startedAt = kRTMPTimestamp_defaultTimeInterval
    private var updatedAt = kRTMPTimestamp_defaultTimeInterval
    private var timedeltaFraction: TimeInterval = kRTMPTimestamp_defaultTimeInterval

    mutating func update(_ value: T, firstOffset: TimeInterval = 0) throws -> UInt32 {
        let seconds = value.seconds
        guard seconds.isFinite, updatedAt < seconds else {
            throw Error.invalidSequence
        }
        if startedAt == 0 {
            // PCM times are rounded to their sample grid around the video epoch.
            guard firstOffset.isFinite, firstOffset > -0.001 else {
                throw Error.invalidSequence
            }
            let delta = max(0, firstOffset * 1000)
            guard let milliseconds = UInt32(exactly: delta.rounded(.towardZero)) else {
                throw Error.invalidSequence
            }
            startedAt = seconds
            updatedAt = seconds
            timedeltaFraction = delta - Double(milliseconds)
            return milliseconds
        }
        var timedelta = (seconds - updatedAt) * 1000
        var fraction = timedeltaFraction + timedelta.truncatingRemainder(dividingBy: 1)
        if 1 <= fraction {
            fraction -= 1
            timedelta += 1
        }
        guard let milliseconds = UInt32(exactly: timedelta.rounded(.towardZero)) else {
            throw Error.invalidSequence
        }
        timedeltaFraction = fraction
        updatedAt = seconds
        return milliseconds
    }

    mutating func update(_ message: some RTMPMessage, chunkType: RTMPChunkType) {
        switch chunkType {
        case .zero:
            if startedAt == 0 {
                startedAt = TimeInterval(message.timestamp) / 1000
                updatedAt = TimeInterval(message.timestamp) / 1000
            } else {
                updatedAt = TimeInterval(message.timestamp) / 1000
            }
        default:
            updatedAt += TimeInterval(message.timestamp) / 1000
        }
    }

    mutating func clear() {
        startedAt = kRTMPTimestamp_defaultTimeInterval
        updatedAt = kRTMPTimestamp_defaultTimeInterval
        timedeltaFraction = kRTMPTimestamp_defaultTimeInterval
    }
}

extension AVAudioTime: RTMPTimeConvertible {
    var seconds: TimeInterval {
        AVAudioTime.seconds(forHostTime: hostTime)
    }
}

extension RTMPTimestamp where T == AVAudioTime {
    var value: AVAudioTime {
        return AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: updatedAt))
    }
}

extension CMTime: RTMPTimeConvertible {
}

extension RTMPTimestamp where T == CMTime {
    var value: CMTime {
        return CMTime(seconds: updatedAt, preferredTimescale: 1000)
    }
}
