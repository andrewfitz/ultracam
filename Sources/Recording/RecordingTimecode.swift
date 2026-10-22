import AVFoundation
import CoreMedia
import Foundation

/// The two video rates supported by the UltraStudio capture contract.
///
/// The media clock is exact (1001/30000 or 1001/60000 seconds per frame),
/// while the timecode clock uses the corresponding nominal integer rate (30 or
/// 60 frames per second).  That distinction is what makes drop-frame labels
/// necessary when a timecode is anchored to wall clock time.
public enum RecordingFrameRate: Equatable, Sendable {
  case fps2997
  case fps5994

  public var frameDuration: CMTime {
    switch self {
    case .fps2997:
      return CMTime(value: 1001, timescale: 30_000)
    case .fps5994:
      return CMTime(value: 1001, timescale: 60_000)
    }
  }

  public var nominalFramesPerSecond: Int64 {
    switch self {
    case .fps2997: return 30
    case .fps5994: return 60
    }
  }

  fileprivate var rateNumerator: Int64 {
    switch self {
    case .fps2997: return 30_000
    case .fps5994: return 60_000
    }
  }

  fileprivate var rateDenominator: Int64 { 1_001 }

  fileprivate var dropFramesPerMinute: Int64 {
    switch self {
    case .fps2997: return 2
    case .fps5994: return 4
    }
  }
}

/// Chooses whether a recorder creates a timecode from the computer clock or
/// preserves an embedded source timecode.
public enum RecordingTimecodePolicy: Equatable, Sendable {
  /// Anchor each feed at its own start date and advance it using source media
  /// time. PC-time recordings sample that date from the computer clock once,
  /// at the first written frame, then count media frames. This keeps
  /// separately started feeds independent and avoids sampling `Date()` on
  /// every frame.
  case wallClock

  /// Start at 00:00:00:00 and advance with the source media clock. This is
  /// useful when the operator wants a deterministic record-start timecode
  /// while still writing a real QuickTime `tmcd` track.
  case recordStart

  /// Use the source's embedded timecode.  No timecode is fabricated when a
  /// source value is absent; callers can then omit the tmcd sample.
  case source
}

/// A SMPTE timecode label and its frame number in the 24-hour timecode day.
public struct RecordingTimecode: Equatable, Sendable, CustomStringConvertible {
  public let frameRate: RecordingFrameRate
  public let frameNumber: Int64
  public let hours: Int
  public let minutes: Int
  public let seconds: Int
  public let frames: Int
  public let dropFrame: Bool

  public init(frameNumber: Int64, frameRate: RecordingFrameRate, dropFrame: Bool) {
    self.frameRate = frameRate
    let dayFrames = Self.framesPerDay(frameRate: frameRate, dropFrame: dropFrame)
    let normalized = ((frameNumber % dayFrames) + dayFrames) % dayFrames
    self.frameNumber = normalized
    self.dropFrame = dropFrame

    if dropFrame {
      let nominal = frameRate.nominalFramesPerSecond
      let drop = frameRate.dropFramesPerMinute
      let framesPer10Minutes = nominal * 600 - drop * 9
      let framesPerHour = framesPer10Minutes * 6
      let hour = normalized / framesPerHour
      let remainderInHour = normalized % framesPerHour
      let tenMinuteBlock = remainderInHour / framesPer10Minutes
      let remainderInBlock = remainderInHour % framesPer10Minutes

      var minute = tenMinuteBlock * 10
      let frameInMinute: Int64
      if remainderInBlock < nominal * 60 {
        frameInMinute = remainderInBlock
      } else {
        let afterFirstMinute = remainderInBlock - nominal * 60
        minute += 1 + afterFirstMinute / (nominal * 60 - drop)
        frameInMinute = afterFirstMinute % (nominal * 60 - drop) + drop
      }

      self.hours = Int(hour)
      self.minutes = Int(minute)
      self.seconds = Int(frameInMinute / nominal)
      self.frames = Int(frameInMinute % nominal)
    } else {
      let nominal = frameRate.nominalFramesPerSecond
      let framesPerHour = nominal * 3_600
      self.hours = Int(normalized / framesPerHour)
      let remainderInHour = normalized % framesPerHour
      self.minutes = Int(remainderInHour / (nominal * 60))
      let frameInMinute = remainderInHour % (nominal * 60)
      self.seconds = Int(frameInMinute / nominal)
      self.frames = Int(frameInMinute % nominal)
    }
  }

  /// Parses the conventional `HH:MM:SS:FF` (NDF) or `HH:MM:SS;FF` (DF)
  /// representation.  The separator must agree with `dropFrame` and the two
  /// frame labels omitted at a non-tenth minute are rejected.
  public init?(
    string: String,
    frameRate: RecordingFrameRate,
    dropFrame: Bool
  ) {
    let normalized = string.replacingOccurrences(of: ";", with: ":")
    let fields = normalized.split(separator: ":", omittingEmptySubsequences: false)
    guard fields.count == 4,
      let hours = Int(fields[0]), let minutes = Int(fields[1]),
      let seconds = Int(fields[2]), let frames = Int(fields[3]),
      (0..<24).contains(hours), (0..<60).contains(minutes),
      (0..<60).contains(seconds), (0..<Int(frameRate.nominalFramesPerSecond)).contains(frames),
      string.count == 11,
      (dropFrame ? string[string.index(string.startIndex, offsetBy: 8)] == ";"
        : string[string.index(string.startIndex, offsetBy: 8)] == ":") else {
      return nil
    }
    if dropFrame && minutes % 10 != 0 && seconds == 0 && frames < Int(frameRate.dropFramesPerMinute) {
      return nil
    }

    let nominal = frameRate.nominalFramesPerSecond
    let nominalFrames = Int64((hours * 3_600 + minutes * 60 + seconds)) * nominal
      + Int64(frames)
    let dropped = dropFrame
      ? frameRate.dropFramesPerMinute * Int64(minutes + hours * 60 - (minutes + hours * 60) / 10)
      : 0
    self.init(frameNumber: nominalFrames - dropped, frameRate: frameRate, dropFrame: dropFrame)
  }

  /// Parses a label and takes the drop-frame flag from its separator, as the
  /// capture boundary reports RP188: `HH:MM:SS;FF` is drop-frame and
  /// `HH:MM:SS:FF` is not. Frames run 0–29 at 29.97 and 0–59 at 59.94.
  public init?(string: String, frameRate: RecordingFrameRate) {
    guard let dropFrame = Self.dropFrame(declaredBy: string) else { return nil }
    self.init(string: string, frameRate: frameRate, dropFrame: dropFrame)
  }

  /// The drop-frame flag a `HH:MM:SS?FF` label declares with its last
  /// separator, or nil when the label is not in that form.
  public static func dropFrame(declaredBy label: String) -> Bool? {
    let characters = Array(label)
    guard characters.count == 11 else { return nil }
    switch characters[8] {
    case ";": return true
    case ":": return false
    default: return nil
    }
  }

  public var description: String { stringValue }

  public var stringValue: String {
    String(format: "%02d:%02d:%02d%@%02d", hours, minutes, seconds,
      dropFrame ? ";" : ":", frames)
  }

  fileprivate static func framesPerDay(frameRate: RecordingFrameRate, dropFrame: Bool) -> Int64 {
    let nominalDay = frameRate.nominalFramesPerSecond * 86_400
    guard dropFrame else { return nominalDay }
    return nominalDay - frameRate.dropFramesPerMinute * 54 * 24
  }
}

/// A deterministic wall-clock-to-timecode mapper for one recording feed.
///
/// The initializer's default date is the current computer time.  Tests and
/// multi-feed recorders should pass an explicit start date.  A new mapper is
/// created for each feed so a second feed started later receives its own wall
/// clock anchor even when both feeds use a source timeline beginning at zero.
public struct RecordingTimecodeSession: Sendable {
  public let frameRate: RecordingFrameRate
  public let dropFrame: Bool
  public let policy: RecordingTimecodePolicy
  public let startDate: Date
  public let sourceStartTime: CMTime

  private let wallClockFrame: Int64
  private let calendar: Calendar

  public init(
    frameRate: RecordingFrameRate,
    dropFrame: Bool = true,
    policy: RecordingTimecodePolicy = .wallClock,
    startDate: Date = Date(),
    sourceStartTime: CMTime = .zero,
    calendar: Calendar = .autoupdatingCurrent
  ) {
    self.frameRate = frameRate
    self.dropFrame = dropFrame
    self.policy = policy
    self.startDate = startDate
    self.sourceStartTime = sourceStartTime
    self.calendar = calendar
    self.wallClockFrame = Self.wallClockFrameNumber(
      at: startDate, frameRate: frameRate, dropFrame: dropFrame, calendar: calendar)
  }

  /// Returns a timecode for a source PTS.  In wall-clock mode, source PTS is
  /// used only for elapsed frame count after this feed's anchor.  In source
  /// mode, `sourceTimecode` is returned unchanged and `nil` means no source
  /// timecode was available.
  public func timecode(
    for sourceTime: CMTime,
    sourceTimecode: RecordingTimecode? = nil
  ) -> RecordingTimecode? {
    if policy == .source { return sourceTimecode }
    if policy == .recordStart {
      guard let offset = frameOffset(from: sourceTime, to: frameRate, origin: sourceStartTime) else {
        return nil
      }
      return RecordingTimecode(frameNumber: offset, frameRate: frameRate, dropFrame: dropFrame)
    }
    guard let offset = frameOffset(from: sourceTime, to: frameRate, origin: sourceStartTime) else {
      return nil
    }
    return RecordingTimecode(frameNumber: wallClockFrame + offset, frameRate: frameRate,
      dropFrame: dropFrame)
  }

  /// The anchor's wall-clock timecode.  This is useful for recorders that write
  /// the first tmcd sample before their first source PTS is available.
  public var startTimecode: RecordingTimecode {
    RecordingTimecode(
      frameNumber: policy == .wallClock ? wallClockFrame : 0,
      frameRate: frameRate,
      dropFrame: dropFrame)
  }

  private static func wallClockFrameNumber(
    at date: Date,
    frameRate: RecordingFrameRate,
    dropFrame: Bool,
    calendar: Calendar
  ) -> Int64 {
    let components = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
    let hour = Int64(max(0, min(23, components.hour ?? 0)))
    let minute = Int64(max(0, min(59, components.minute ?? 0)))
    let second = Int64(max(0, min(60, components.second ?? 0)))
    let nanosecond = Int64(max(0, min(999_999_999, components.nanosecond ?? 0)))
    let wholeSeconds = hour * 3_600 + minute * 60 + min(second, 59)
    let totalNanoseconds = wholeSeconds * 1_000_000_000 + nanosecond

    let frame: Int64
    if dropFrame {
      // Drop-frame timecode tracks the true 1000/1001 media rate, then omits
      // two (or four) labels at each minute except each tenth minute.
      frame = (totalNanoseconds * frameRate.rateNumerator)
        / (1_000_000_000 * frameRate.rateDenominator)
    } else {
      // NDF deliberately uses the nominal rate.  It therefore drifts from
      // real time, as SMPTE NDF timecode is expected to do.
      frame = (totalNanoseconds * frameRate.nominalFramesPerSecond) / 1_000_000_000
    }
    let dayFrames = RecordingTimecode.framesPerDay(frameRate: frameRate, dropFrame: dropFrame)
    return ((frame % dayFrames) + dayFrames) % dayFrames
  }

  private func frameOffset(from sourceTime: CMTime, to frameRate: RecordingFrameRate, origin: CMTime) -> Int64? {
    guard sourceTime.isValid, sourceTime.isNumeric, sourceTime.epoch == 0,
      sourceTime.timescale > 0, origin.isValid, origin.isNumeric, origin.epoch == 0,
      origin.timescale > 0 else { return nil }
    let delta = CMTimeSubtract(sourceTime, origin)
    guard delta.isValid, delta.isNumeric, delta.epoch == 0, delta.value >= 0 else { return nil }
    let numerator = delta.value.multipliedReportingOverflow(by: frameRate.rateNumerator)
    let denominator = Int64(delta.timescale).multipliedReportingOverflow(by: frameRate.rateDenominator)
    if !numerator.overflow && !denominator.overflow && denominator.partialValue > 0 {
      return numerator.partialValue / denominator.partialValue
    }
    let frames = (Double(delta.value) / Double(delta.timescale))
      * Double(frameRate.rateNumerator) / Double(frameRate.rateDenominator)
    guard frames.isFinite, frames >= 0, frames <= Double(Int64.max) else { return nil }
    return Int64(frames.rounded(.down))
  }
}

public enum RecordingTimecodeError: Error, Equatable, CustomStringConvertible {
  case incompatibleTimecode
  case coreMedia(OSStatus)

  public var description: String {
    switch self {
    case .incompatibleTimecode: return "Timecode does not match this track."
    case let .coreMedia(status): return "Core Media error (\(status))."
    }
  }
}

/// A QuickTime `tmcd` track description and sample factory.
///
/// Samples contain one big-endian signed 32-bit frame number, as required by
/// the TimeCode32 media format.  The format description carries exact 1001/1000
/// frame duration, nominal frame quanta and the drop-frame flag, so AVAsset
/// writers can attach this sample stream to a ProRes video track.
public final class QuickTimeTimecodeTrack {
  public let frameRate: RecordingFrameRate
  public let dropFrame: Bool
  public let formatDescription: CMFormatDescription

  public init(frameRate: RecordingFrameRate, dropFrame: Bool = true) throws {
    self.frameRate = frameRate
    self.dropFrame = dropFrame
    var description: CMFormatDescription?
    var flags: UInt32 = kCMTimeCodeFlag_24HourMax
    if dropFrame { flags |= kCMTimeCodeFlag_DropFrame }
    let status = CMTimeCodeFormatDescriptionCreate(
      allocator: nil,
      timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
      frameDuration: frameRate.frameDuration,
      frameQuanta: UInt32(frameRate.nominalFramesPerSecond),
      flags: flags,
      extensions: nil,
      formatDescriptionOut: &description)
    guard status == noErr, let description else { throw RecordingTimecodeError.coreMedia(status) }
    self.formatDescription = description
  }

  /// Creates the AVAssetWriter input for this `tmcd` media track.
  public func makeInput() -> AVAssetWriterInput {
    AVAssetWriterInput(mediaType: .timecode, outputSettings: nil,
      sourceFormatHint: formatDescription)
  }

  public func sample(
    for timecode: RecordingTimecode,
    at presentationTime: CMTime = .zero,
    duration: CMTime? = nil
  ) throws -> CMSampleBuffer {
    guard timecode.frameRate == frameRate, timecode.dropFrame == dropFrame else {
      throw RecordingTimecodeError.incompatibleTimecode
    }
    let frameBytes = UInt32(bitPattern: Int32(timecode.frameNumber)).bigEndian
    var block: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
      allocator: nil, memoryBlock: nil, blockLength: MemoryLayout<UInt32>.size,
      blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
      dataLength: MemoryLayout<UInt32>.size, flags: 0, blockBufferOut: &block)
    guard status == kCMBlockBufferNoErr, let block else {
      throw RecordingTimecodeError.coreMedia(status)
    }
    status = withUnsafeBytes(of: frameBytes) { bytes in
      CMBlockBufferReplaceDataBytes(
        with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
        dataLength: MemoryLayout<UInt32>.size)
    }
    guard status == kCMBlockBufferNoErr else { throw RecordingTimecodeError.coreMedia(status) }

    var timing = CMSampleTimingInfo(
      duration: duration ?? frameRate.frameDuration,
      presentationTimeStamp: presentationTime,
      decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    var size = MemoryLayout<UInt32>.size
    status = CMSampleBufferCreateReady(
      allocator: nil, dataBuffer: block, formatDescription: formatDescription,
      sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
      sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
    guard status == noErr, let sample else { throw RecordingTimecodeError.coreMedia(status) }
    return sample
  }
}
