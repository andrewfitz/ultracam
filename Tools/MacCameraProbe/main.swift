import AVFoundation
import CoreMediaIO
import CoreVideo
import Foundation

func fourCC(_ value: FourCharCode) -> String {
  let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
  return bytes.allSatisfy { (32...126).contains($0) } ? String(decoding: bytes, as: UTF8.self) : String(format: "%08x", value)
}

func time(_ value: CMTime) -> String {
  value.isNumeric ? "\(value.value)/\(value.timescale)" : "invalid"
}

func cmioUIDs() throws -> Set<String> {
  func address(_ selector: Int) -> CMIOObjectPropertyAddress {
    CMIOObjectPropertyAddress(mSelector: UInt32(selector), mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
      mElement: UInt32(kCMIOObjectPropertyElementMain))
  }
  let system = CMIOObjectID(kCMIOObjectSystemObject)
  var property = address(kCMIOHardwarePropertyDevices)
  var size: UInt32 = 0
  let stride = UInt32(MemoryLayout<CMIOObjectID>.stride)
  guard CMIOObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr,
    size.isMultiple(of: stride), size <= 64 * 1024 else { throw Failure("Cannot size the CMIO device list") }
  guard size > 0 else { return [] }
  var devices = [CMIOObjectID](repeating: 0, count: Int(size / stride))
  var used: UInt32 = 0
  let status = devices.withUnsafeMutableBufferPointer {
    CMIOObjectGetPropertyData(system, &property, 0, nil, size, &used, $0.baseAddress!)
  }
  guard status == noErr, used <= size, used.isMultiple(of: stride) else { throw Failure("Cannot read the CMIO device list") }
  return try Set(devices.prefix(Int(used / stride)).map { device in
    var uidProperty = address(kCMIODevicePropertyDeviceUID)
    var value: Unmanaged<CFString>?
    let expectedSize = UInt32(MemoryLayout.size(ofValue: value))
    var uidSize: UInt32 = 0
    guard CMIOObjectGetPropertyData(device, &uidProperty, 0, nil, expectedSize, &uidSize, &value) == noErr,
      uidSize == expectedSize, let uid = value?.takeRetainedValue() as String? else { throw Failure("Cannot read a CMIO device UID") }
    return uid
  })
}

func label(_ format: AVCaptureDevice.Format) -> String {
  let description = format.formatDescription
  let dimensions = CMVideoFormatDescriptionGetDimensions(description)
  let rates = format.videoSupportedFrameRateRanges.map { "\(time($0.minFrameDuration))...\(time($0.maxFrameDuration))" }
  return "\(dimensions.width)x\(dimensions.height) \(fourCC(CMFormatDescriptionGetMediaSubType(description))) durations=\(rates) colorSpaces=\(format.supportedColorSpaces.map(\.rawValue))"
}

final class Samples: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
  private let maximum: Int
  private var count = 0
  private var previous = CMTime.invalid
  private var first = CMTime.invalid
  let done = DispatchSemaphore(value: 0)

  init(maximum: Int) { self.maximum = maximum }

  func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard count < maximum else { return }
    count += 1
    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
    let step = CMTimeSubtract(pts, previous)
    if count == 1 { first = pts }
    previous = pts
    let description = CMSampleBufferGetFormatDescription(sample)
    let formatSubtype = description.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "absent"
    let formatDimensions = description.map {
      let size = CMVideoFormatDescriptionGetDimensions($0)
      return "\(size.width)x\(size.height)"
    } ?? "absent"
    let image = CMSampleBufferGetImageBuffer(sample)
    let dimensions = image.map { "\(CVPixelBufferGetWidth($0))x\(CVPixelBufferGetHeight($0))" } ?? "absent"
    let pixelSubtype = image.map { fourCC(CVPixelBufferGetPixelFormatType($0)) } ?? "absent"
    let surface = image.map { CVPixelBufferGetIOSurface($0) != nil } ?? false
    let keys = [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey,
      kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocationBottomFieldKey]
    let attachments = image.map { buffer in
      keys.compactMap { key in CVBufferCopyAttachment(buffer, key, nil).map { "\(key)=\($0)" } }
    } ?? []
    print("sample \(count) pts=\(time(pts)) duration=\(time(CMSampleBufferGetDuration(sample))) step=\(time(step)) format=\(formatSubtype) formatDimensions=\(formatDimensions) pixels=\(pixelSubtype) pixelDimensions=\(dimensions) IOSurface=\(surface) \(attachments)")
    if count == maximum {
      let elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, first))
      if elapsed > 0 { print("observedFPS=\(Double(count - 1) / elapsed)") }
      done.signal()
    }
  }
}

struct Failure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}

func authorize() throws {
  if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
    let completed = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .video) { _ in completed.signal() }
    guard completed.wait(timeout: .now() + 60) == .success else { throw Failure("Camera authorization request timed out") }
  }
  guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
    throw Failure("Allow camera access under System Settings › Privacy & Security › Camera")
  }
}

func run() throws {
  let args = Array(CommandLine.arguments.dropFirst())
  guard args.isEmpty || args == ["--request-access"] || (args.count == 2 && args[0] == "--expect-feed") ||
    ((5...6).contains(args.count) && args[0] == "--capture") else {
    throw Failure("Usage: mac-camera-probe [--request-access | --expect-feed FEED_ID | --capture UID FORMAT_INDEX DURATION_VALUE/DURATION_SCALE SAMPLE_COUNT [native|420v|420f|2vuy|yuvs|BGRA]]")
  }
  if args == ["--request-access"] { try authorize() }
  let authorization = AVCaptureDevice.authorizationStatus(for: .video)
  print("cameraAuthorization=\(authorization.rawValue) os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
  let discovery = AVCaptureDevice.DiscoverySession(
    deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera],
    mediaType: .video, position: .unspecified)
  let devices = discovery.devices
  for device in devices {
    print("AVFoundation uid=\(device.uniqueID) name=\(device.localizedName) model=\(device.modelID) type=\(device.deviceType.rawValue) transport=\(fourCC(UInt32(truncatingIfNeeded: device.transportType))) continuity=\(device.isContinuityCamera)")
    for (index, format) in device.formats.enumerated() { print("  [\(index)] \(label(format))") }
  }
  let avUIDs = Set(devices.map(\.uniqueID))
  let cmio = try cmioUIDs()
  print("CMIO UIDs=\(cmio.sorted())")
  let requiredUIDs = [
    VirtualCameraDescriptor.feed(feedID: "default").deviceUID,
    VirtualCameraDescriptor.program().deviceUID
  ] + (args.first == "--expect-feed" ? [VirtualCameraDescriptor.feed(feedID: args[1]).deviceUID] : [])
  let ownUIDs = Set(requiredUIDs).union(cmio.filter(VirtualCameraDescriptor.isDeviceUID))
  for uid in ownUIDs.sorted() { print("Ultracam uid=\(uid) CMIO=\(cmio.contains(uid)) AVFoundation=\(avUIDs.contains(uid))") }
  if args.first == "--expect-feed" {
    guard ownUIDs.isSubset(of: avUIDs), ownUIDs.isSubset(of: cmio) else {
      throw Failure("Expected Ultracam output UIDs are missing from CMIO or AVFoundation")
    }
    return
  }
  guard args.first == "--capture" else { return }

  let components = args[3].split(separator: "/", omittingEmptySubsequences: false)
  guard let index = Int(args[2]), let count = Int(args[4]), (2...18000).contains(count),
    components.count == 2, let value = Int64(components[0]), value > 0,
    let scale = Int32(components[1]), scale > 0 else {
    throw Failure("Choose a listed format, a positive rational duration, and 2...18000 samples")
  }
  let requested = CMTime(value: value, timescale: scale)
  let delivery = args.count == 6 ? args[5] : "native"
  guard ["native", "420v", "420f", "2vuy", "yuvs", "BGRA"].contains(delivery) else { throw Failure("Unknown delivery format") }
  guard !VirtualCameraDescriptor.isDeviceUID(args[1]) else { throw Failure("Select an independent camera input") }
  try authorize()
  guard let device = discovery.devices.first(where: { $0.uniqueID == args[1] }), device.formats.indices.contains(index) else {
    throw Failure("Device or format unavailable after authorization. Run inventory again.")
  }
  guard !device.isInUseByAnotherApplication else { throw Failure("This camera is in use by another application") }
  let format = device.formats[index]
  guard format.videoSupportedFrameRateRanges.contains(where: {
    requested >= $0.minFrameDuration && requested <= $0.maxFrameDuration
  }) else { throw Failure("Requested duration falls outside the selected format's ranges") }

  let session = AVCaptureSession()
  let input = try AVCaptureDeviceInput(device: device)
  let output = AVCaptureVideoDataOutput()
  output.alwaysDiscardsLateVideoFrames = true
  guard session.canAddInput(input) else { throw Failure("Cannot add selected camera input") }
  session.addInput(input)
  guard session.canAddOutput(output) else { throw Failure("Cannot add video output") }
  session.addOutput(output)
  let collector = Samples(maximum: count)
  let queue = DispatchQueue(label: "org.ultracam.mac-camera-probe.samples")
  output.setSampleBufferDelegate(collector, queue: queue)
  do {
    try device.lockForConfiguration()
    defer { device.unlockForConfiguration() }
    device.activeFormat = format
    device.activeVideoMinFrameDuration = requested
    device.activeVideoMaxFrameDuration = requested
    if delivery == "native" {
      output.videoSettings = [:]
    } else {
      let pixel = delivery.utf8.reduce(FourCharCode(0)) { $0 << 8 | FourCharCode($1) }
      guard output.availableVideoPixelFormatTypes.contains(pixel) else {
        throw Failure("Video output does not advertise \(delivery) for this format")
      }
      output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixel]
    }
    print("requested=\(label(format)) duration=\(time(requested)) delivery=\(delivery) startRunningWithDeviceLock=true")
    session.startRunning()
  }
  defer {
    session.stopRunning()
    output.setSampleBufferDelegate(nil, queue: nil)
    queue.sync {}
  }
  print("running=\(session.isRunning) formatPreserved=\(device.activeFormat == format) active=\(label(device.activeFormat)) min=\(time(device.activeVideoMinFrameDuration)) max=\(time(device.activeVideoMaxFrameDuration))")
  let timeout = max(15, CMTimeGetSeconds(requested) * Double(count) * 2 + 5)
  guard session.isRunning, collector.done.wait(timeout: .now() + timeout) == .success else {
    throw Failure("Timed out waiting for requested sample count")
  }
}

do {
  try run()
} catch {
  fflush(nil)
  FileHandle.standardError.write(Data("Mac Camera probe failed: \(error)\n".utf8))
  exit(EXIT_FAILURE)
}
