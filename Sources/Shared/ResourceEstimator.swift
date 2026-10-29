import Foundation

/// The owner of a retained resource. A demand's owner is charged once even when
/// the same work is visible at several pipeline stages.
public enum ResourceStage: String, Sendable, Codable { case capture, recording, gpu }

public struct ResourceDemand: Sendable, Hashable {
  public let owner: String
  public let stage: ResourceStage
  public let bytes: Int
  public let duration: TimeInterval
  public let slots: Int
  public init(owner: String, stage: ResourceStage, bytes: Int, duration: TimeInterval, slots: Int = 1) {
    self.owner = owner; self.stage = stage; self.bytes = bytes; self.duration = duration; self.slots = slots
  }
}

public struct ResourceLimits: Sendable, Equatable {
  public let bytes: Int
  public let duration: TimeInterval
  public let slots: Int
  public init(bytes: Int, duration: TimeInterval, slots: Int) { self.bytes = bytes; self.duration = duration; self.slots = slots }
}

public struct ResourceEstimate: Sendable, Equatable {
  public let bytes: Int
  public let duration: TimeInterval
  public let slots: Int
  public init(bytes: Int, duration: TimeInterval, slots: Int) { self.bytes = bytes; self.duration = duration; self.slots = slots }
}

public enum ResourceRejection: Error, Sendable, Equatable, CustomStringConvertible {
  case invalid(String), overflow(String), bytes(required: Int, limit: Int), duration(required: TimeInterval, limit: TimeInterval), slots(required: Int, limit: Int)
  public var description: String {
    switch self { case .invalid(let s): return "invalid resource demand: \(s)"; case .overflow(let s): return "resource estimate overflow: \(s)"; case .bytes(let r, let l): return "resource byte limit exceeded (\(r) > \(l))"; case .duration(let r, let l): return "resource duration limit exceeded (\(r) > \(l))"; case .slots(let r, let l): return "resource slot limit exceeded (\(r) > \(l))" }
  }
}

/// Aggregates capture, recording and GPU reservations. Owners are keyed so a
/// hand-off between stages does not double count the same retained payload.
public struct ResourceEstimator: Sendable {
  public let limits: ResourceLimits
  private var demands: [String: ResourceDemand] = [:]
  public init(limits: ResourceLimits) { self.limits = limits }
  public var estimate: ResourceEstimate { Self.aggregate(demands.values) }
  public var activeOwners: Set<String> { Set(demands.keys) }

  @discardableResult public mutating func admit(owner: String, stage: ResourceStage, bytes: Int, duration: TimeInterval, slots: Int = 1) -> Result<ResourceEstimate, ResourceRejection> {
    admit(ResourceDemand(owner: owner, stage: stage, bytes: bytes, duration: duration, slots: slots))
  }

  @discardableResult public mutating func admit(_ demand: ResourceDemand) -> Result<ResourceEstimate, ResourceRejection> {
    do { try Self.validate(demand) } catch let error as ResourceRejection { return .failure(error) } catch { return .failure(.invalid(String(describing: error))) }
    var next = demands; next[demand.owner] = demand
    let total = Self.aggregate(next.values)
    if total.bytes > limits.bytes { return .failure(.bytes(required: total.bytes, limit: limits.bytes)) }
    if total.duration > limits.duration { return .failure(.duration(required: total.duration, limit: limits.duration)) }
    if total.slots > limits.slots { return .failure(.slots(required: total.slots, limit: limits.slots)) }
    demands = next; return .success(total)
  }
  public mutating func release(owner: String) { demands.removeValue(forKey: owner) }
  public mutating func removeAll() { demands.removeAll() }

  public static func estimate(_ demands: some Sequence<ResourceDemand>) throws -> ResourceEstimate {
    let values = Array(demands)
    try validateAll(values)
    var unique: [String: ResourceDemand] = [:]
    for d in values { unique[d.owner] = d }
    var b = 0, slots = 0, duration = 0.0
    for d in unique.values {
      let (nb, bo) = b.addingReportingOverflow(d.bytes); guard !bo else { throw ResourceRejection.overflow("bytes") }; b = nb
      let (ns, so) = slots.addingReportingOverflow(d.slots); guard !so else { throw ResourceRejection.overflow("slots") }; slots = ns
      duration += d.duration; guard duration.isFinite else { throw ResourceRejection.overflow("duration") }
    }
    return ResourceEstimate(bytes: b, duration: duration, slots: slots)
  }
  private static func validateAll(_ demands: some Sequence<ResourceDemand>) throws {
    for d in demands { try validate(d) }
  }
  private static func validate(_ d: ResourceDemand) throws {
    guard !d.owner.isEmpty, d.bytes >= 0, d.slots >= 0, d.duration.isFinite, d.duration >= 0 else { throw ResourceRejection.invalid("owner, bytes, slots and duration must be nonnegative; duration must be finite") }
  }
  private static func aggregate(_ values: some Sequence<ResourceDemand>) -> ResourceEstimate {
    var b = 0, s = 0, t = 0.0
    for d in values { let (nb, ob) = b.addingReportingOverflow(d.bytes); b = ob ? Int.max : nb; let (ns, os) = s.addingReportingOverflow(d.slots); s = os ? Int.max : ns; t += d.duration; if !t.isFinite { t = .infinity } }
    return ResourceEstimate(bytes: b, duration: t, slots: s)
  }
}
