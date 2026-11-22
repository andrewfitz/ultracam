// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Dispatch
import Metal
import MonitorKit
import Synchronization
import XCTest
@testable import MonitorKitScopes

final class ScopeSingleFlightAuditTests: XCTestCase {
  func testConcurrentColdComputeBuildHasOneOwner() throws {
    let (device, _, _) = try GPU.require()
    let engine = try ScopeEngine(device: device, specialization: .synchronous)
    let key = ScopeEngine.ComputeKey(kernel: .waveform, layout: 0)
    let errors = Mutex<[String]>([])
    DispatchQueue.concurrentPerform(iterations: 16) { _ in
      do { _ = try engine.computePipeline(key) }
      catch { errors.withLock { $0.append(String(describing: error)) } }
    }
    XCTAssertTrue(errors.withLock { $0.isEmpty })
    XCTAssertEqual(engine.builtOnCallerThread.withLock { $0.compute }, 1)
    XCTAssertFalse(engine.pendingCompute.withLock { $0.contains(key) })
  }

  func testConcurrentColdRenderBuildHasOneOwner() throws {
    let (device, _, _) = try GPU.require()
    let engine = try ScopeEngine(device: device, specialization: .synchronous)
    let key = ScopeEngine.RenderKey(target: MonitorRenderTargetFormat(colorPixelFormat: .rgba16Float), scope: nil)
    let errors = Mutex<[String]>([])
    DispatchQueue.concurrentPerform(iterations: 16) { _ in
      do { _ = try engine.renderPipeline(key) }
      catch { errors.withLock { $0.append(String(describing: error)) } }
    }
    XCTAssertTrue(errors.withLock { $0.isEmpty })
    XCTAssertEqual(engine.builtOnCallerThread.withLock { $0.render }, 1)
    XCTAssertFalse(engine.pendingRender.withLock { $0.contains(key) })
  }

  func testWarmupJoinsAsynchronousRenderOwner() throws {
    let (device, _, _) = try GPU.require()
    let engine = try ScopeEngine(device: device, specialization: .asynchronous)
    let key = ScopeEngine.RenderKey(target: MonitorRenderTargetFormat(colorPixelFormat: .bgra8Unorm), scope: nil)
    let errors = Mutex<[String]>([])
    DispatchQueue.concurrentPerform(iterations: 16) { _ in
      do { _ = try engine.preparedRenderPipeline(key) }
      catch { errors.withLock { $0.append(String(describing: error)) } }
    }
    XCTAssertTrue(errors.withLock { $0.isEmpty })
    XCTAssertEqual(engine.builtOnCallerThread.withLock { $0.render }, 0)
    XCTAssertTrue(engine.isPrepared(pixelFormat: .bgra8Unorm))
  }
}
