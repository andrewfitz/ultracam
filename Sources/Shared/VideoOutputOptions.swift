import CoreMedia

/// How a source frame is placed in the fixed output canvas.
enum ProgramScalingMode: String, Codable, CaseIterable, Sendable {
  case fit
  case crop
}

enum ResizeTarget: String, Codable, CaseIterable, Sendable {
  case hd720, hd1080, uhd4K, source, dci4K
  var title: String { switch self { case .hd720: "720p"; case .hd1080: "1080p"; case .uhd4K: "4K UHD"; case .source: "Source size"; case .dci4K: "4K DCI" } }
  // Source size is resolved by PipelineConfiguration; these defaults retain
  // compatibility for UI callers without an active source declaration.
  var width: Int { switch self { case .hd720: 1280; case .hd1080: 1920; case .uhd4K, .source: 3840; case .dci4K: 4096 } }
  var height: Int { switch self { case .hd720: 720; case .hd1080: 1080; case .uhd4K, .source, .dci4K: 2160 } }
}

enum FrameRateTarget: String, Codable, CaseIterable, Sendable {
  case fps60, fps5994, fps50, fps30, fps2997, fps25, fps24, fps23976
  case fps47952, fps48, fps100, fps11988, fps120
  var title: String { switch self {
    case .fps60: "60"; case .fps5994: "59.94"; case .fps50: "50"
    case .fps30: "30"; case .fps2997: "29.97"; case .fps25: "25"
    case .fps24: "24"; case .fps23976: "23.976"
    case .fps47952: "47.952"; case .fps48: "48"; case .fps100: "100"
    case .fps11988: "119.88"; case .fps120: "120"
  } }
  var duration: CMTime { switch self {
    case .fps5994: CMTime(value: 1001, timescale: 60_000)
    case .fps2997: CMTime(value: 1001, timescale: 30_000)
    case .fps23976: CMTime(value: 1001, timescale: 24000)
    case .fps47952: CMTime(value: 1001, timescale: 48000)
    case .fps11988: CMTime(value: 1001, timescale: 120000)
    case .fps60: CMTime(value: 1, timescale: 60)
    case .fps50: CMTime(value: 1, timescale: 50)
    case .fps30: CMTime(value: 1, timescale: 30)
    case .fps25: CMTime(value: 1, timescale: 25)
    case .fps24: CMTime(value: 1, timescale: 24)
    case .fps48: CMTime(value: 1, timescale: 48)
    case .fps100: CMTime(value: 1, timescale: 100)
    case .fps120: CMTime(value: 1, timescale: 120)
  } }
}
