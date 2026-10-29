import Foundation
import CoreMedia
import CoreVideo

/// The producer transfers immutable publication ownership: neither pixels nor
/// attachments may change until the last consumer releases the pixel buffer.
/// The SDK lease is attached before publication so legacy consumers retaining
/// only `value` have the same storage lifetime as typed consumers. The lease
/// must not retain this CVPixelBuffer itself, which would form an owner cycle.
struct CapturedPixelBuffer: @unchecked Sendable {
  let value: CVPixelBuffer
  private static let ownerKey = "org.ultracam.capture.storageOwners"
  private static let attachmentLock = NSLock()

  init(immutable value: CVPixelBuffer, retaining owner: AnyObject? = nil) {
    self.value = value
    if let owner {
      Self.attachmentLock.withLock {
        let owners: CapturedStorageOwners
        if let existing = CVBufferCopyAttachment(value, Self.ownerKey as CFString, nil) as? CapturedStorageOwners {
          owners = existing
        } else {
          owners = CapturedStorageOwners()
          CVBufferSetAttachment(value, Self.ownerKey as CFString, owners, .shouldNotPropagate)
        }
        owners.retain(owner)
      }
    }
  }
}

/// This object never retains the buffer it is attached to. Multiple wrappers
/// may add independent leases without replacing an earlier storage owner.
private final class CapturedStorageOwners: NSObject {
  private var owners: [ObjectIdentifier: AnyObject] = [:]
  func retain(_ owner: AnyObject) { owners[ObjectIdentifier(owner)] = owner }
}
/// Describes the producer's capture-host-time attachment without changing its
/// stored value. Core converts an explicitly end-referenced anchor to start
/// using this frame's exact duration; existing producers default to start.
enum CaptureHostTimeReference: Equatable, Sendable {
  case presentationStart, presentationEnd
}

struct CaptureFrameInfo: Sendable {
  let epochID: CaptureEpochID
  let formatSignature: String
  let presentationTime: CMTime
  let duration: CMTime
  let signalValid: Bool
  let timecode: Timecode?
  var hostTimeReference: CaptureHostTimeReference = .presentationStart
  /// Producer hardware timestamp, frozen with this frame before asynchronous
  /// ingest. Nil permits the consumer's documented legacy attachment fallback.
  var captureHostTime: CMTime? = nil
  func validate() throws {
    guard presentationTime.isNumeric, presentationTime.epoch == 0, presentationTime >= .zero,
      duration.isNumeric, duration.epoch == 0, duration > .zero else {
      throw PluginError.unsupported("Invalid source frame timestamp or duration")
    }
  }
}
enum CaptureEvent: Sendable {
  case formatChanged(SourceFormat), audioFormatChanged(SourceAudioDeclaration)
  case clockMappingChanged(CaptureClockMappingUpdate)
  case discontinuity, waitingForSignal, signalLost(reason: String), unsupportedInput(String), fatal(String), info(String)
}
struct CaptureDelivery: Sendable {
  enum Payload: Sendable {
    case event(CaptureEvent)
    case frame(CapturedPixelBuffer, CaptureFrameInfo)
    /// Ordinary SDK memory must pass the bounded ordered GPU ingest boundary.
    case cpuMemory(CapturedCPUMemoryFrame, CaptureFrameInfo)
    case media(CaptureMediaInfo)
    case rawAudio(CaptureAudioPacket)
  }
  let sequence: UInt64
  let epochID: CaptureEpochID
  let formatSignature: String
  let clockBindings: CaptureClockBindings
  let mappingRevision: UInt64
  let payload: Payload
}

/// Current serialized contract: the event envelope retains the old mapping
/// revision, and this update applies to the immediately next delivery. Its
/// effectiveSequence must equal the event sequence + 1; that next envelope
/// must carry `revision`. Arbitrary future scheduling requires a wider API
/// with bounded pending history, rather than overwriting a known estimate.
struct CaptureClockMappingUpdate: Sendable {
  let epochID: CaptureEpochID
  let clockID: ClockInstanceID
  let revision: UInt64
  let effectiveSequence: UInt64
  let mapping: ClockMapping
}
