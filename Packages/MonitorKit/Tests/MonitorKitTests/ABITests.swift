import Metal
import XCTest

@testable import MonitorKit

/// The Swift parameter structs mirror the MSL structs byte for byte. Offsets come
/// from the compiled pipeline's reflection, not from reading the source.
final class ABITests: XCTestCase {
  func testAllShaderPartsCompileAndExportTheirEntryPoints() throws {
    let gpu = try requireGPU()
    for name in ["mk_fullscreen", "mk_picture", "mk_focusMask"] {
      XCTAssertNotNil(gpu.engine.library.makeFunction(name: name), name)
    }
    // Each fusable part compiles on its own, as a host would prepend it.
    _ = try MonitorShaders.makeLibrary(device: gpu.device, parts: [.lut])
    _ = try MonitorShaders.makeLibrary(device: gpu.device, parts: [.decode])
    _ = try MonitorShaders.makeLibrary(device: gpu.device, parts: [.lut, .decode])
  }

  func fragmentBuffers() throws -> [Int: MTLBufferBinding] {
    let gpu = try requireGPU()
    let d = MTLRenderPipelineDescriptor()
    d.vertexFunction = gpu.engine.library.makeFunction(name: "mk_fullscreen")
    d.fragmentFunction = try gpu.engine.library.makeFunction(
      name: "mk_picture", constantValues: MonitorEngine.constants(layout: 0, variant: .uber))
    d.colorAttachments[0].pixelFormat = .rgba32Float
    var reflection: MTLAutoreleasedRenderPipelineReflection?
    _ = try gpu.device.makeRenderPipelineState(descriptor: d, options: [.bindingInfo, .bufferTypeInfo], reflection: &reflection)
    var result: [Int: MTLBufferBinding] = [:]
    for case let b as MTLBufferBinding in try XCTUnwrap(reflection).fragmentBindings where b.type == .buffer {
      result[b.index] = b
    }
    return result
  }

  func check<T>(_ binding: MTLBufferBinding?, _ type: T.Type, _ fields: [(String, Int?)], file: StaticString = #filePath, line: UInt = #line) throws {
    let binding = try XCTUnwrap(binding, file: file, line: line)
    XCTAssertEqual(binding.bufferDataSize, MemoryLayout<T>.size, "size of \(T.self)", file: file, line: line)
    XCTAssertEqual(binding.bufferAlignment, MemoryLayout<T>.alignment, "alignment of \(T.self)", file: file, line: line)
    XCTAssertEqual(MemoryLayout<T>.stride, MemoryLayout<T>.size, file: file, line: line)
    let members = try XCTUnwrap(binding.bufferStructType?.members, file: file, line: line)
    XCTAssertEqual(members.map(\.name), fields.map(\.0), "member order of \(T.self)", file: file, line: line)
    for (member, (name, offset)) in zip(members, fields) {
      XCTAssertEqual(member.offset, try XCTUnwrap(offset, file: file, line: line), "\(T.self).\(name)", file: file, line: line)
    }
  }

  func testPassParametersMatchMSL() throws {
    typealias P = PassParameters
    let o = { (k: PartialKeyPath<P>) in MemoryLayout<P>.offset(of: k) }
    try check(try fragmentBuffers()[3], P.self, [
      ("displayToPicture", o(\.displayToPicture)), ("imageRect", o(\.imageRect)), ("navigatorRect", o(\.navigatorRect)),
      ("navigatorToPicture", o(\.navigatorToPicture)), ("navigatorVisible", o(\.navigatorVisible)),
      ("viewport", o(\.viewport)), ("guideRect", o(\.guideRect)), ("matte", o(\.matte)), ("zebra0", o(\.zebra0)),
      ("zebra1", o(\.zebra1)), ("zebra", o(\.zebra)), ("modes", o(\.modes)), ("falseColor", o(\.falseColor)),
      ("gamutWeights", o(\.gamutWeights)), ("focus", o(\.focus)), ("focusColor", o(\.focusColor)),
      ("guide", o(\.guide)), ("guideColor", o(\.guideColor)), ("display", o(\.display)), ("flags", o(\.flags)),
      ("luts", o(\.luts)), ("bandEdges", o(\.bandEdges)), ("bandColors", o(\.bandColors)),
      ("color", o(\.color)), ("colorFlags", o(\.colorFlags)), ("colorLevels", o(\.colorLevels)),
      ("hlgSource", o(\.hlgSource)), ("toneMap", o(\.toneMap)), ("assist", o(\.assist)),
      ("pictureWeights", o(\.pictureWeights)), ("targetWeights", o(\.targetWeights)), ("toTarget", o(\.toTarget)),
      ("transformMatrix", o(\.transformMatrix)), ("overlayWhite", o(\.overlayWhite)),
      ("zebraColors", o(\.zebraColors)), ("navigatorColors", o(\.navigatorColors)), ("clipLevels", o(\.clipLevels)),
      ("clipColors", o(\.clipColors)), ("whiteGain", o(\.whiteGain)), ("whiteSignalGain", o(\.whiteSignalGain)),
      ("reciprocals", o(\.reciprocals)), ("outputReading", o(\.outputReading)), ("hlgToSDR", o(\.hlgToSDR)),
      ("sourceWeights", o(\.sourceWeights)),
    ])
    let members = try XCTUnwrap(try fragmentBuffers()[3]?.bufferStructType?.members)
    let arrays = [
      ("bandEdges", PassParameters.maximumBands), ("bandColors", PassParameters.maximumBands), ("toTarget", 3),
      ("transformMatrix", 3), ("zebraColors", 2), ("navigatorColors", 2), ("clipColors", 16),
    ]
    for (name, length) in arrays {
      let array = try XCTUnwrap(members.first { $0.name == name }?.arrayType(), name)
      XCTAssertEqual(array.arrayLength, length, name)
      XCTAssertEqual(array.stride, MemoryLayout<SIMD4<Float>>.stride, name)
    }
    XCTAssertLessThanOrEqual(MemoryLayout<P>.stride, 4096, "setFragmentBytes takes at most 4 KB")
  }

  func testGuideParametersMatchMSL() throws {
    typealias G = GuideParameters
    try check(try fragmentBuffers()[4], G.self, [
      ("counts", MemoryLayout<G>.offset(of: \.counts)), ("reach", MemoryLayout<G>.offset(of: \.reach)),
      ("lines", MemoryLayout<G>.offset(of: \.lines)), ("others", MemoryLayout<G>.offset(of: \.others)),
      ("cells", MemoryLayout<G>.offset(of: \.cells)),
    ])
    let members = try XCTUnwrap(try fragmentBuffers()[4]?.bufferStructType?.members)
    XCTAssertEqual(members.first { $0.name == "lines" }?.arrayType()?.arrayLength, GuideParameters.maximumLines)
    XCTAssertEqual(members.first { $0.name == "others" }?.arrayType()?.arrayLength, 2 * GuideParameters.maximumOthers)
    let cells = try XCTUnwrap(members.first { $0.name == "cells" }?.arrayType())
    XCTAssertEqual(cells.arrayLength, 64)
    XCTAssertEqual(cells.stride, MemoryLayout<UInt32>.stride)
    XCTAssertLessThanOrEqual(MemoryLayout<G>.stride, 4096, "setFragmentBytes takes at most 4 KB")
  }

  func testFrameAndLUTParametersMatchMSL() throws {
    let buffers = try fragmentBuffers()
    typealias F = FrameParameters
    typealias P = PassFrameParameters
    // Buffer 0 holds the source reading, then the output reading, back to back.
    try check(buffers[0], P.self, [
      ("source", MemoryLayout<P>.offset(of: \.source)), ("output", MemoryLayout<P>.offset(of: \.output)),
    ])
    XCTAssertLessThanOrEqual(MemoryLayout<P>.stride, 256, "fits the Metal 4 frame block")
    let fields = [
      ("shape", MemoryLayout<F>.offset(of: \.shape)), ("options", MemoryLayout<F>.offset(of: \.options)),
      ("matrix", MemoryLayout<F>.offset(of: \.matrix)), ("levels", MemoryLayout<F>.offset(of: \.levels)),
      ("codeScale", MemoryLayout<F>.offset(of: \.codeScale)),
    ]
    for member in try XCTUnwrap(buffers[0]?.bufferStructType?.members) {
      let reading = try XCTUnwrap(member.structType(), member.name)
      XCTAssertEqual(reading.members.map(\.name), fields.map(\.0), member.name)
      for (m, (name, offset)) in zip(reading.members, fields) {
        XCTAssertEqual(m.offset, try XCTUnwrap(offset), "\(member.name).\(name)")
      }
    }
    XCTAssertEqual(MemoryLayout<F>.stride, 80, "mk_FrameParams is five 16-byte rows")
    typealias L = LUTParameters
    for index in [1, 2] {
      try check(buffers[index], L.self, [
        ("domainLow", MemoryLayout<L>.offset(of: \.domainLow)), ("domainScale", MemoryLayout<L>.offset(of: \.domainScale)),
        ("shape", MemoryLayout<L>.offset(of: \.shape)), ("shaperLow", MemoryLayout<L>.offset(of: \.shaperLow)),
        ("shaperScale", MemoryLayout<L>.offset(of: \.shaperScale)),
      ])
    }
  }
}
