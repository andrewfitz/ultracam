// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Dispatch
import Foundation
import Metal
import Synchronization
import XCTest

@testable import MonitorKit

final class Fresh06PipelineSingleFlightTests: XCTestCase {
  func testConcurrentColdPipelineRequestsCompileOncePerKey() throws {
    let gpu = try requireGPU()
    let engine = try MonitorEngine(device: gpu.device, specialization: .synchronous)
    let key = MonitorEngine.PipelineKey(
      target: .init(colorPixelFormat: .rgba16Float), layout: 0, variant: .uber, color: .fromUniforms)
    let errors = Mutex<[String]>([])
    let start = DispatchTime.now().uptimeNanoseconds
    DispatchQueue.concurrentPerform(iterations: 16) { _ in
      do {
        _ = try engine.renderPipeline(key)
        _ = try engine.computePipeline(key)
        _ = try engine.focusPipeline(.init(layout: 0, burnInLUT: false, monitorLUT: false))
        _ = try engine.copyPipeline(integer: true)
        _ = try engine.copyPipeline(integer: false)
      } catch { errors.withLock { $0.append(String(describing: error)) } }
    }
    let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    print("BENCH picture concurrent cold pipeline requests: \(milliseconds) ms, 16 callers, 5 unique keys")
    XCTAssertTrue(errors.withLock { $0.isEmpty })
    XCTAssertEqual(engine.pipelinesBuiltOnCaller, 2)
    XCTAssertEqual(engine.computeCompilationsOnCaller, 4)
  }

  func testSynchronousPreparationJoinsAsynchronousOwners() throws {
    let gpu = try requireGPU()
    let engine = try MonitorEngine(device: gpu.device, specialization: .asynchronous)
    try verifyAsynchronousOwners(engine)
  }

  func testSynchronousPreparationJoinsMetal4CompilerOwners() throws {
    try requireMetal4()
    let gpu = try requireGPU()
    let compiler = try gpu.device.makeCompiler(descriptor: MTL4CompilerDescriptor())
    let engine = try MonitorEngine(device: gpu.device, specialization: .asynchronous, compiler: compiler)
    try verifyAsynchronousOwners(engine)
  }

  private func verifyAsynchronousOwners(_ engine: MonitorEngine) throws {
    let key = MonitorEngine.PipelineKey(
      target: .init(colorPixelFormat: .rgba16Float), layout: 0, variant: .uber, color: .fromUniforms)
    _ = try engine.specializedPipeline(key)
    _ = try engine.specializedComputePipeline(key)
    _ = try engine.renderPipeline(key)
    _ = try engine.computePipeline(key)
    _ = try engine.copyPipeline(integer: true)
    _ = try engine.copyPipeline(integer: false)
    XCTAssertEqual(engine.pipelinesBuiltOnCaller, 0)
    XCTAssertEqual(engine.computeCompilationsOnCaller, 0)
  }
}
