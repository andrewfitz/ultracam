import Foundation
import CoreMedia

struct CaptureAudioPacket: Sendable {
  let planes: [Data]
  let sampleFrameCount: Int
  let format: SourceAudioFormat
  let packetTime: CMTime
  let pairedFrameSequence: UInt64?
  init(planes: [Data], sampleFrameCount: Int, format: SourceAudioFormat,
       packetTime: CMTime, pairedFrameSequence: UInt64? = nil) throws {
    let bytesPerSample: Int
    switch format.sample {
    case .int16: bytesPerSample = 2
    case .int24in32, .int32, .float32: bytesPerSample = 4
    }
    let (samples, overflow) = sampleFrameCount.multipliedReportingOverflow(by: format.interleaved ? format.channels : 1)
    let (bytes, byteOverflow) = samples.multipliedReportingOverflow(by: bytesPerSample)
    guard sampleFrameCount >= 0, !overflow, !byteOverflow,
      planes.count == (format.interleaved ? 1 : format.channels),
      planes.allSatisfy({ $0.count == bytes }), packetTime.isNumeric,
      packetTime.epoch == 0, packetTime >= .zero else { throw PluginError.unsupported("Invalid PCM packet") }
    // Force independent immutable storage; no SDK-backed no-copy Data escapes.
    self.planes = planes.map { Data($0.map { $0 }) }
    self.sampleFrameCount = sampleFrameCount
    self.format = format
    self.packetTime = packetTime
    self.pairedFrameSequence = pairedFrameSequence
  }
}
struct CaptureMediaInfo: Sendable {
  let timecode: Timecode?
  let pairedFrameSequence: UInt64?
  let audioDeclaration: SourceAudioDeclaration
  let audioPacketTime: CMTime?
  let audioClockInstance: ClockInstanceID?
  let sampleFrameCount: Int
  let byteCount: Int
  let peaks: [Double]
  let rms: [Double]
}
