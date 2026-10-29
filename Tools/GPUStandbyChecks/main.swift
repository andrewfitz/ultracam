import CoreMedia
import CoreVideo
import Darwin
import Foundation
import Metal
import Synchronization

// Standalone hardware proof: no capture, CMIO publication, app launch or install.
// CPU mapping below is readback verification only; production fills remain GPU-only.
struct SlotEvidence: Encodable {
  let index: Int
  let contractID: String
  let width: Int
  let height: Int
  let fourCC: String
  var planeStrides: [Int] = []
  var checkedBytes = 0
  var status = "failed"
  var error: String?
}
struct HardwareEvidence: Encodable {
  let schemaVersion = 1
  let generatedAt = ISO8601DateFormatter().string(from: Date())
  var status = "failed"
  var gpuName: String?
  var registryID: String?
  let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
  var slots: [SlotEvidence] = []
  var error: String?
}
struct ProofFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) { self.description = description }
}
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
  guard condition() else { throw ProofFailure(message) }
}
func prove(_ contract: ExtensionFormatContract, index: Int, producer: GPUStandbyProducer) -> SlotEvidence {
  var evidence = SlotEvidence(index: index, contractID: contract.id, width: contract.width,
    height: contract.height, fourCC: VideoContract.fourCC(contract.pixel.rawValue))
  do {
    let type = contract.pixel.rawValue
    let format = try OutputFormatCatalog.descriptions()[index]
    let done = DispatchSemaphore(value: 0)
    let result = Mutex<Result<GPUStandbyImage, Error>?>(nil)
    try producer.makeBlack(format: format) { value in result.withLock { $0 = value }; done.signal() }
    guard done.wait(timeout: .now() + 15) == .success else { throw ProofFailure("GPU completion timed out after 15 seconds") }
    guard let completed = result.withLock({ $0 }) else { throw ProofFailure("GPU completion returned no result") }
    let image = try completed.get().pixelBuffer
    try VideoBufferLayout.validate(image)
    try require(CVPixelBufferGetWidth(image) == contract.width && CVPixelBufferGetHeight(image) == contract.height,
      "Completed image dimensions differ from published slot")
    try require(CVPixelBufferGetPixelFormatType(image) == type, "Completed pixel format differs from published slot")
    let sample = try VideoSampleFactory().sample(image, at: .zero, duration: VideoContract.fastDuration)
    if let mismatch = DerivedOutputContract(format: format, duration: VideoContract.fastDuration).mismatch(sample) {
      throw ProofFailure("Standby sample differs from published slot: \(mismatch)")
    }
    guard let sampleFormat = CMSampleBufferGetFormatDescription(sample) else { throw ProofFailure("Missing sample format") }
    for (source, destination) in [
      (kCMFormatDescriptionExtension_ColorPrimaries, kCVImageBufferColorPrimariesKey),
      (kCMFormatDescriptionExtension_TransferFunction, kCVImageBufferTransferFunctionKey),
      (kCMFormatDescriptionExtension_YCbCrMatrix, kCVImageBufferYCbCrMatrixKey)] {
      guard let expected = CMFormatDescriptionGetExtension(format, extensionKey: source),
        let actual = CVBufferCopyAttachment(image, destination, nil), CFEqual(expected, actual),
        let sampleValue = CMFormatDescriptionGetExtension(sampleFormat, extensionKey: source), CFEqual(expected, sampleValue) else {
        throw ProofFailure("Published color tag was not preserved in image and sample: \(source)")
      }
    }
    let locked = CVPixelBufferLockBaseAddress(image, .readOnly)
    try require(locked == kCVReturnSuccess, "Cannot lock completed image for readback (\(locked))")
    defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
    let packed = type == kCVPixelFormatType_422YpCbCr10
    let eight = ColorTarget.allCases.contains { $0.pixelFormat == type && $0.isEightBit }
    for plane in 0..<(packed ? 1 : 2) {
      let stride = packed ? CVPixelBufferGetBytesPerRow(image) : CVPixelBufferGetBytesPerRowOfPlane(image, plane)
      let rows = packed ? CVPixelBufferGetHeight(image) : CVPixelBufferGetHeightOfPlane(image, plane)
      guard let base = packed ? CVPixelBufferGetBaseAddress(image) : CVPixelBufferGetBaseAddressOfPlane(image, plane) else {
        throw ProofFailure("Missing plane \(plane) base address")
      }
      evidence.planeStrides.append(stride)
      // Check all bytes in every row, including IOSurface row padding. v210
      // starts its four-word packing group afresh at each physical row.
      for row in 0..<rows {
        let address = base.advanced(by: row * stride)
        if packed {
          for x in 0..<stride / 4 {
            let expected: UInt32 = x % 2 == 0 ? 512 | (64 << 10) | (512 << 20) : 64 | (512 << 10) | (64 << 20)
            if address.load(fromByteOffset: x * 4, as: UInt32.self) != expected {
              throw ProofFailure("v210 mismatch row \(row), word \(x)")
            }
          }
        } else if eight {
          let expected: UInt8 = plane == 0 ? 16 : 128
          for x in 0..<stride where address.load(fromByteOffset: x, as: UInt8.self) != expected {
            throw ProofFailure("8-bit mismatch plane \(plane), row \(row), byte \(x)")
          }
        } else {
          let expected: UInt16 = plane == 1 ? 512 << 6 : (type == kCVPixelFormatType_422YpCbCr10BiPlanarFullRange ? 0 : 64 << 6)
          for x in 0..<stride / 2 where address.load(fromByteOffset: x * 2, as: UInt16.self) != expected {
            throw ProofFailure("10-bit mismatch plane \(plane), row \(row), word \(x)")
          }
        }
      }
      evidence.checkedBytes += stride * rows
    }
    evidence.status = "passed"
  } catch { evidence.error = String(describing: error) }
  return evidence
}

var outputPath: String?
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--output" {
  outputPath = CommandLine.arguments[2]
} else if CommandLine.arguments.count != 1 {
  FileHandle.standardError.write(Data("Usage: gpu-standby-checks [--output PATH]\n".utf8))
  exit(64)
}
var evidence = HardwareEvidence()
if let device = MTLCreateSystemDefaultDevice() {
  evidence.gpuName = device.name
  evidence.registryID = String(device.registryID)
  if device.supportsFamily(.metal4) {
    do {
      let producer = try GPUStandbyProducer(device: device)
      for (index, contract) in ExtensionFormatCatalog.published.enumerated() {
        evidence.slots.append(autoreleasepool { prove(contract, index: index, producer: producer) })
      }
      evidence.status = evidence.slots.count == OutputFormatCatalog.published.count && evidence.slots.allSatisfy { $0.status == "passed" } ? "passed" : "failed"
    } catch { evidence.error = String(describing: error) }
  } else {
    evidence.status = "unsupported"
    evidence.error = "Metal 4 is required; this device was not tested through a fallback."
  }
} else {
  evidence.status = "unsupported"
  evidence.error = "No Metal device is available."
}
do {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  let data = try encoder.encode(evidence)
  if let outputPath { try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic) }
  FileHandle.standardOutput.write(data)
  FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
  FileHandle.standardError.write(Data("Cannot write proof evidence: \(error)\n".utf8))
  exit(1)
}
exit(evidence.status == "passed" ? 0 : evidence.status == "unsupported" ? 2 : 1)
