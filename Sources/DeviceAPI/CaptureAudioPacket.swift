import Foundation
import CoreMedia

struct CaptureAudioPacket: Sendable {
  let planes: [Data]
  let byteCount: Int
  let sampleFrameCount: Int
  let format: SourceAudioFormat
  let packetTime: CMTime
  let pairedFrameSequence: UInt64?

  init(planes: [Data], sampleFrameCount: Int, format: SourceAudioFormat,
       packetTime: CMTime, pairedFrameSequence: UInt64? = nil) throws {
    try self.init(planes: planes, sampleFrameCount: sampleFrameCount, format: format,
      packetTime: packetTime, pairedFrameSequence: pairedFrameSequence, copyStorage: true)
  }

  /// The native producer has already copied PCM into independently owned,
  /// immutable storage. Borrowed or mutable SDK bytes must use `init(planes:)`.
  init(ownedInterleavedPCM data: Data, sampleFrameCount: Int, format: SourceAudioFormat,
       packetTime: CMTime, pairedFrameSequence: UInt64? = nil) throws {
    guard format.interleaved else { throw PluginError.unsupported("Invalid interleaved PCM packet") }
    try self.init(planes: [data], sampleFrameCount: sampleFrameCount, format: format,
      packetTime: packetTime, pairedFrameSequence: pairedFrameSequence, copyStorage: false)
  }

  private init(planes: [Data], sampleFrameCount: Int, format: SourceAudioFormat,
               packetTime: CMTime, pairedFrameSequence: UInt64?, copyStorage: Bool) throws {
    let planeCount = format.interleaved ? 1 : format.channels
    let (samples, overflow) = sampleFrameCount.multipliedReportingOverflow(by: format.channels)
    let (bytes, byteOverflow) = samples.multipliedReportingOverflow(by: format.sample.bytesPerSample)
    guard sampleFrameCount >= 0, !overflow, !byteOverflow,
      planes.count == planeCount,
      planes.allSatisfy({ $0.count == bytes / planeCount }), packetTime.isNumeric,
      packetTime.timescale > 0, packetTime.epoch == 0, packetTime.value >= 0 else { throw PluginError.unsupported("Invalid PCM packet") }
    if copyStorage {
      self.planes = planes.map { plane in
        plane.withUnsafeBytes { bytes in
          guard let base = bytes.baseAddress, !bytes.isEmpty else { return Data() }
          return Data(bytes: base, count: bytes.count)
        }
      }
    } else {
      self.planes = planes
    }
    self.byteCount = bytes
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
