import Foundation

struct CaptureCounters: Equatable, Sendable {
  var deviceDroppedFrames: UInt64 = 0
  var conversionFailures: UInt64 = 0
  var currentBacklog: Int = 0
  var maximumBacklog: Int = 0
}

struct DeviceDiagnostics: Sendable {
  struct Field: Equatable, Sendable { let label: String; let value: String }
  let counters: CaptureCounters
  let temperatureCelsius: Double?
  let signalPresent: Bool?
  let hostTimeMapped: Bool
  let vendorFields: [Field]
}
