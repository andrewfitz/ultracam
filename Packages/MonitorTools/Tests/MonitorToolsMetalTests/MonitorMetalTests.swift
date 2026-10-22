import CoreVideo
@preconcurrency import Metal
import MonitorToolsCore
import XCTest

@testable import MonitorToolsMetal

final class MonitorMetalTests: XCTestCase {
  func buffer(_ format: OSType = kCVPixelFormatType_32BGRA, width: Int = 64, height: Int = 32)
    throws -> CVPixelBuffer
  {
    var b: CVPixelBuffer?
    guard
      CVPixelBufferCreate(
        nil, width, height, format, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &b)
        == kCVReturnSuccess, let b
    else { throw XCTSkip("Native format allocation unavailable") }
    CVPixelBufferLockBaseAddress(b, [])
    if let base = CVPixelBufferGetBaseAddress(b) { memset(base, 192, CVPixelBufferGetDataSize(b)) }
    CVPixelBufferUnlockBaseAddress(b, [])
    return b
  }
  func stamp() -> MonitorFrameStamp {
    MonitorFrameStamp(
      target: MonitorTargetID("fixture"), generation: 1, sequence: 1, sourcePTS: 1, hostTime: 1,
      configurationRevision: 1)
  }
  func testNativeCopiesAreDistinctAndChargedUntilConsumerRelease() throws {
    for f in [
      kCVPixelFormatType_32BGRA, kCVPixelFormatType_422YpCbCr10,
      kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
    ] {
      let input = try buffer(f)
      let ledger = MonitorAdmissionLedger()
      let service = CleanPreviewService(budget: ledger)
      let done = expectation(description: "copy")
      let held = Holder()
      XCTAssertTrue(
        service.offer(MonitorFrameBundle(stamp: stamp(), source: input)) { r in
          do { held.frame = try r.get() } catch { XCTFail("Format \(f): \(error)") }
          done.fulfill()
        })
      wait(for: [done], timeout: 3)
      let result = try XCTUnwrap(held.frame)
      XCTAssertFalse(input === result.pixelBuffer)
      XCTAssertNotNil(CVPixelBufferGetIOSurface(result.pixelBuffer))
      XCTAssertGreaterThan(ledger.snapshot.retainedBytes, 0)
      XCTAssertEqual(
        CVPixelBufferGetPixelFormatType(input), CVPixelBufferGetPixelFormatType(result.pixelBuffer))
    }
  }
  func testMissingShadersPreservesOwnedClean() throws {
    let b = try buffer()
    let r = MonitorRuntime(shaderSource: "invalid shader")
    let s = stamp()
    var c = MonitorConfiguration()
    c.toolsEnabled = true
    c.zebra.enabled = true
    r.configure(target: s.target, generation: 1, configurationRevision: 1, configuration: c)
    let done = expectation(description: "fallback")
    XCTAssertTrue(
      r.offer(MonitorFrameBundle(stamp: s, source: b)) { result in
        let output = try? result.get()
        XCTAssertNotNil(output?.clean)
        XCTAssertNil(output?.decorated)
        XCTAssertFalse(output?.availability.isEmpty ?? true)
        done.fulfill()
      })
    wait(for: [done], timeout: 10)
  }
  func testDeviceInitializationRetriesOnNextFrameAndKeepsSuccessfulContext() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    var attempts = 0
    let runtime = MonitorRuntime(sharedDevice: {
      attempts += 1
      return attempts == 1 ? nil : device
    })
    let input = try buffer()
    var config = MonitorConfiguration()
    config.toolsEnabled = true
    config.zebra.enabled = true
    let first = stamp()
    runtime.configure(target: first.target, generation: 1, configurationRevision: 1, configuration: config)
    for sequence in 1...3 {
      var next = first
      next.sequence = UInt64(sequence)
      let done = expectation(description: "initialization attempt frame \(sequence)")
      let bundle = MonitorFrameBundle(
        stamp: next, source: input,
        sourceSignal: MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "rec709"))
      // The previous frame's completion can arrive before its job slot is released,
      // and a busy runtime rejects the offer without calling back. Offer again until admitted.
      let deadline = Date().addingTimeInterval(5)
      var accepted = false
      repeat {
        accepted = runtime.offer(bundle) { result in
          let display = try? result.get()
          XCTAssertNotNil(display?.clean)
          if sequence == 1 {
            XCTAssertNil(display?.decorated)
          } else {
            XCTAssertNotNil(display?.decorated, "\(display?.availability ?? [])")
          }
          done.fulfill()
        }
        if !accepted { usleep(2_000) }
      } while !accepted && Date() < deadline
      XCTAssertTrue(accepted)
      wait(for: [done], timeout: 15)
      XCTAssertEqual(attempts, min(sequence, 2))
    }
  }

  func testShaderCompileFailureRetriesOnceOnEachLaterOffer() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    var attempts = 0
    let runtime = MonitorRuntime(sharedDevice: {
      attempts += 1
      return device
    }, shaderSource: "invalid shader")
    let input = try buffer()
    var config = MonitorConfiguration()
    config.toolsEnabled = true
    config.zebra.enabled = true
    let first = stamp()
    runtime.configure(target: first.target, generation: 1, configurationRevision: 1, configuration: config)
    for sequence in 1...2 {
      var next = first
      next.sequence = UInt64(sequence)
      let done = expectation(description: "shader compile fallback")
      XCTAssertTrue(runtime.offer(MonitorFrameBundle(stamp: next, source: input)) { result in
        XCTAssertNotNil(try? result.get().clean)
        XCTAssertNil((try? result.get())?.decorated)
        done.fulfill()
      })
      wait(for: [done], timeout: 15)
      XCTAssertEqual(attempts, sequence, "Exactly one initialization attempt per admitted frame")
    }
  }

  func testStaleGPUPreparationReleasesCompositeWithoutAnotherOffer() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    let entered = expectation(description: "GPU completed before publication")
    let gate = DispatchSemaphore(value: 0)
    defer { gate.signal() }
    let runtime = MonitorRuntime(sharedDevice: { device }, gpuTiming: { _, _ in
      entered.fulfill()
      _ = gate.wait(timeout: .now() + 5)
    })
    let input = try buffer()
    let first = stamp()
    var config = MonitorConfiguration()
    config.toolsEnabled = true
    config.zebra.enabled = true
    runtime.configure(target: first.target, generation: 1, configurationRevision: 1, configuration: config)
    let obsolete = expectation(description: "obsolete composite delivery")
    obsolete.isInverted = true
    XCTAssertTrue(runtime.offer(MonitorFrameBundle(stamp: first, source: input,
      sourceSignal: MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "rec709")
    )) { _ in obsolete.fulfill() })
    wait(for: [entered], timeout: 15)
    runtime.configure(target: first.target, generation: 2, configurationRevision: 1, configuration: config)
    gate.signal()
    let drained = expectation(for: NSPredicate { _, _ in
      runtime.ledger.snapshot.retainedBytes == 0 && runtime.ledger.snapshot.analysisJobs == 0
    }, evaluatedWith: nil)
    wait(for: [drained, obsolete], timeout: 3)
    XCTAssertEqual(runtime.resourceStatistics.compositePoolCapacityBytes, 0)
  }

  func testPostAdmissionAllocationFailureRecordsPressure() throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
    // Working and clean storage fit, but the composite's 1 MiB reservation does not.
    let ledger = MonitorAdmissionLedger(maximumBytes: 1_300_000, cleanReserveBytes: 1_000_000)
    let runtime = MonitorRuntime(ledger: ledger, sharedDevice: { device })
    let input = try buffer()
    var config = MonitorConfiguration()
    config.toolsEnabled = true
    config.zebra.enabled = true
    let first = stamp()
    runtime.configure(target: first.target, generation: 1, configurationRevision: 1, configuration: config)
    for sequence in 1...8 {
      var next = first
      next.sequence = UInt64(sequence)
      let done = expectation(description: "post-admission allocation failure")
      XCTAssertTrue(runtime.offer(MonitorFrameBundle(
        stamp: next, source: input,
        sourceSignal: MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "rec709")
      )) { result in
        let display = try? result.get()
        XCTAssertNotNil(display?.clean)
        XCTAssertNil(display?.decorated)
        XCTAssertTrue(display?.availability.contains { $0.contains("allocationFailed") } ?? false)
        done.fulfill()
      })
      wait(for: [done], timeout: 15)
      Thread.sleep(forTimeInterval: 0.26)
    }
    XCTAssertNotEqual(runtime.diagnostics(for: first.target).effectiveQuality.tier, .nominal)
  }

  func testActualGPUZebraAndSpatialScope() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
    let b = try buffer()
    let s = stamp()
    let r = MonitorRuntime()
    var c = MonitorConfiguration()
    c.toolsEnabled = true
    c.zebra.enabled = true
    c.zebra.thresholdIRE = 50
    c.scopes.enabled = true
    r.configure(target: s.target, generation: 1, configurationRevision: 1, configuration: c)
    let done = expectation(description: "GPU")
    XCTAssertTrue(
      r.offer(
        MonitorFrameBundle(
          stamp: s, source: b, output: b,
          sourceSignal: MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "rec709"),
          outputSignal: MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "rec709"))
      ) { result in
        do {
          let out = try result.get()
          XCTAssertNotNil(out.decorated, "\(out.availability)")
          XCTAssertNotNil(out.scope)
          if let decorated = out.decorated {
            CVPixelBufferLockBaseAddress(decorated.pixelBuffer, .readOnly)
            if let p = CVPixelBufferGetBaseAddress(decorated.pixelBuffer)?.assumingMemoryBound(
              to: UInt8.self)
            {
              XCTAssertGreaterThan(p[0], 192)
              XCTAssertEqual(p[32], 192, accuracy: 2)
            }
            CVPixelBufferUnlockBaseAddress(decorated.pixelBuffer, .readOnly)
          }
        } catch { XCTFail("\(error)") }
        done.fulfill()
      })
    wait(for: [done], timeout: 15)
  }
  func testARRIUsesSourceBeforeOutputLUT() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
    let source = try buffer()
    let output = try buffer()
    let s = stamp()
    let runtime = MonitorRuntime()
    for (b, value) in [(source, UInt8(250)), (output, UInt8(10))] {
      CVPixelBufferLockBaseAddress(b, [])
      memset(CVPixelBufferGetBaseAddress(b), Int32(value), CVPixelBufferGetDataSize(b))
      CVPixelBufferUnlockBaseAddress(b, [])
    }
    var c = MonitorConfiguration()
    c.toolsEnabled = true
    c.falseColor.mode = .arri
    c.falseColor.profileID = ARRIFalseColorProfile.logC3EI800.rawValue
    c.sourceProfileID = ARRIFalseColorProfile.logC3EI800.rawValue
    runtime.configure(target: s.target, generation: 1, configurationRevision: 1, configuration: c)
    let done = expectation(description: "ARRI source")
    let signal = MonitorFrameSignal(
      range: .full, matrix: .bt709, transfer: "logc3",
      profileID: ARRIFalseColorProfile.logC3EI800.rawValue)
    XCTAssertTrue(
      runtime.offer(
        MonitorFrameBundle(
          stamp: s, source: source, output: output, correspondence: .identity, sourceSignal: signal,
          outputSignal: MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "rec709"))
      ) { result in
        do {
          let out = try result.get()
          let b = try XCTUnwrap(out.decorated).pixelBuffer
          CVPixelBufferLockBaseAddress(b, .readOnly)
          defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
          let pixel = try XCTUnwrap(CVPixelBufferGetBaseAddress(b)).assumingMemoryBound(
            to: UInt8.self)
          XCTAssertEqual(pixel[2], 255)
          XCTAssertEqual(pixel[1], 0)
          XCTAssertEqual(pixel[0], 0)
        } catch { XCTFail("\(error)") }
        done.fulfill()
      })
    wait(for: [done], timeout: 10)
  }
  func testDisplayBufferLifetimeOwnsBudgetBeyondFrameWrapper() throws {
    let b = try buffer()
    let ledger = MonitorAdmissionLedger()
    let service = CleanPreviewService(budget: ledger)
    let done = expectation(description: "copy")
    let holder = Holder()
    XCTAssertTrue(
      service.offer(MonitorFrameBundle(stamp: stamp(), source: b)) { result in
        holder.buffer = (try? result.get())?.pixelBuffer
        done.fulfill()
      })
    wait(for: [done], timeout: 3)
    XCTAssertGreaterThan(ledger.snapshot.retainedBytes, 0)
    holder.buffer = nil
    XCTAssertEqual(ledger.snapshot.retainedBytes, 0)
  }

  func testSourceFocusUsesSourceEdgeDespiteFlatOutput() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
    let source = try buffer()
    let output = try buffer()
    let s = stamp()
    let runtime = MonitorRuntime()
    CVPixelBufferLockBaseAddress(source, [])
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(source)).assumingMemoryBound(
      to: UInt8.self)
    for y in 0..<32 {
      for x in 0..<64 {
        for channel in 0..<4 {
          base[y * CVPixelBufferGetBytesPerRow(source) + x * 4 + channel] = x < 32 ? 0 : 255
        }
      }
    }
    CVPixelBufferUnlockBaseAddress(source, [])
    var c = MonitorConfiguration()
    c.toolsEnabled = true
    c.focus.enabled = true
    runtime.configure(target: s.target, generation: 1, configurationRevision: 1, configuration: c)
    let done = expectation(description: "focus source")
    let signal = MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "rec709")
    XCTAssertTrue(
      runtime.offer(
        MonitorFrameBundle(
          stamp: s, source: source, output: output, correspondence: .identity, sourceSignal: signal,
          outputSignal: signal)
      ) { result in
        do {
          let out = try result.get()
          let b = try XCTUnwrap(out.decorated).pixelBuffer
          CVPixelBufferLockBaseAddress(b, .readOnly)
          defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
          let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(b)).assumingMemoryBound(
            to: UInt8.self)
          let edge = 16 * CVPixelBufferGetBytesPerRow(b) + 31 * 4
          XCTAssertGreaterThan(bytes[edge + 2], bytes[edge + 1])
          let flat = 16 * CVPixelBufferGetBytesPerRow(b) + 8 * 4
          XCTAssertEqual(bytes[flat], bytes[flat + 2])
        } catch { XCTFail("\(error)") }
        done.fulfill()
      })
    wait(for: [done], timeout: 10)
  }
  func testOccupiedAnalysisSlotsStillPermitCleanAndRetirementIsCharged() throws {
    let ledger = MonitorAdmissionLedger()
    let s = stamp()
    let b = try buffer()
    let first = try XCTUnwrap(
      ledger.tryAcquire(target: s.target, generation: 1, kind: .analysis, bytes: 4096))
    let second = try XCTUnwrap(
      ledger.tryAcquire(
        target: MonitorTargetID("other"), generation: 1, kind: .analysis, bytes: 4096))
    XCTAssertNil(
      ledger.tryAcquire(target: MonitorTargetID("third"), generation: 1, kind: .analysis, bytes: 0))
    ledger.retire(target: s.target, generation: 1)
    XCTAssertEqual(ledger.snapshot.retiredBytes, 4096)
    let done = expectation(description: "clean while analysis saturated")
    let service = CleanPreviewService(budget: ledger)
    XCTAssertTrue(
      service.offer(MonitorFrameBundle(stamp: s, source: b)) { result in
        XCTAssertNotNil(try? result.get())
        done.fulfill()
      })
    wait(for: [done], timeout: 3)
    XCTAssertEqual(ledger.snapshot.analysisJobs, 2)
    first.release()
    second.release()
    XCTAssertEqual(ledger.snapshot.analysisJobs, 0)
  }

  func testMetadataOnlyFairnessPreventsAlignedFeedStarvation() {
    let fair = MonitorFairAdmission()
    let a = MonitorTargetID("a")
    let b = MonitorTargetID("b")
    let c = MonitorTargetID("c")
    XCTAssertTrue(fair.mayAttempt(a))
    fair.attempted(a, admitted: true)
    fair.attempted(b, admitted: false)
    fair.attempted(c, admitted: false)
    XCTAssertFalse(fair.mayAttempt(a))
    XCTAssertTrue(fair.mayAttempt(b))
    fair.attempted(b, admitted: true)
    XCTAssertFalse(fair.mayAttempt(a))
    XCTAssertTrue(fair.mayAttempt(c))
    fair.attempted(c, admitted: true)
    XCTAssertTrue(fair.mayAttempt(a))
  }
  func testGenerationChangeDropsAlreadyAdmittedResultWithoutWaiting() throws {
    let gate = DispatchSemaphore(value: 0)
    let started = expectation(description: "initialization worker started")
    let callback = expectation(description: "obsolete callback")
    callback.isInverted = true
    let runtime = MonitorRuntime(sharedDevice: {
      started.fulfill()
      _ = gate.wait(timeout: .now() + 3)
      return MTLCreateSystemDefaultDevice()
    })
    let b = try buffer()
    let s = stamp()
    var c = MonitorConfiguration()
    c.toolsEnabled = true
    c.zebra.enabled = true
    runtime.configure(target: s.target, generation: 1, configurationRevision: 1, configuration: c)
    XCTAssertTrue(
      runtime.offer(MonitorFrameBundle(stamp: s, source: b)) { _ in callback.fulfill() })
    wait(for: [started], timeout: 2)
    runtime.configure(target: s.target, generation: 2, configurationRevision: 1, configuration: c)
    gate.signal()
    wait(for: [callback], timeout: 0.3)
    XCTAssertEqual(runtime.ledger.snapshot.analysisJobs, 0)
    let drained = expectation(for: NSPredicate { _, _ in
      runtime.ledger.snapshot.retainedBytes == 0
    }, evaluatedWith: nil)
    wait(for: [drained], timeout: 3)
    XCTAssertEqual(runtime.resourceStatistics.compositeAllocations, 0,
      "Obsolete initialization must not prepare a composite after reconfiguration")
  }

  func testScopeRGBOrderAndExtendedRangeAxesOnGPU() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      throw XCTSkip("Metal unavailable")
    }
    let b = try buffer()
    let s = stamp()
    let runtime = MonitorRuntime(sharedDevice: { device })
    let done = expectation(description: "scope bins")
    var c = MonitorConfiguration()
    c.toolsEnabled = true
    c.scopes.enabled = true
    runtime.configure(target: s.target, generation: 1, configurationRevision: 1, configuration: c)
    let signal = MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "rec709")
    XCTAssertTrue(
      runtime.offer(
        MonitorFrameBundle(
          stamp: s, source: b, output: b, sourceSignal: signal, outputSignal: signal)
      ) { result in
        guard let scope = (try? result.get())?.scope,
          let target = device.makeBuffer(length: 768 * 256 * 4, options: .storageModeShared),
          let command = queue.makeCommandBuffer(), let encoder = command.makeBlitCommandEncoder()
        else {
          XCTFail("scope unavailable")
          done.fulfill()
          return
        }
        encoder.copy(
          from: scope.texture, sourceSlice: 0, sourceLevel: 0,
          sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
          sourceSize: MTLSize(width: 768, height: 256, depth: 1), to: target, destinationOffset: 0,
          destinationBytesPerRow: 768 * 4, destinationBytesPerImage: 768 * 256 * 4)
        encoder.endEncoding()
        command.addCompletedHandler { _ in
          let bytes = target.contents().assumingMemoryBound(to: UInt8.self)
          // Independent axis calculation: 192/255 =75.29IRE, -10...110 maps tobin181,row74.
          let red = 74 * 768 * 4
          let green = red + 256 * 4
          let blue = red + 512 * 4
          XCTAssertGreaterThan(bytes[red + 2], bytes[red])
          XCTAssertGreaterThan(bytes[green + 1], bytes[green + 2])
          XCTAssertGreaterThan(bytes[blue], bytes[blue + 1])
          _ = scope
          done.fulfill()
        }
        command.commit()
      })
    wait(for: [done], timeout: 10)
  }

  func testZebraBandIsCenteredLikeIndependentScalarClassifier() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
    for code in [UInt8(166), UInt8(196)] {
      let b = try buffer()
      let s = stamp()
      let runtime = MonitorRuntime()
      let done = expectation(description: "centered band")
      CVPixelBufferLockBaseAddress(b, [])
      memset(CVPixelBufferGetBaseAddress(b), Int32(code), CVPixelBufferGetDataSize(b))
      CVPixelBufferUnlockBaseAddress(b, [])
      var c = MonitorConfiguration()
      c.toolsEnabled = true
      c.zebra.enabled = true
      c.zebra.mode = .band
      c.zebra.thresholdIRE = 70
      c.zebra.widthIRE = 10
      runtime.configure(target: s.target, generation: 1, configurationRevision: 1, configuration: c)
      let signal = MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "rec709")
      XCTAssertTrue(
        runtime.offer(
          MonitorFrameBundle(
            stamp: s, source: b, output: b, sourceSignal: signal, outputSignal: signal)
        ) { result in
          do {
            let output = try XCTUnwrap(try result.get().decorated).pixelBuffer
            CVPixelBufferLockBaseAddress(output, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
            let value = try XCTUnwrap(CVPixelBufferGetBaseAddress(output)).assumingMemoryBound(
              to: UInt8.self)[0]
            if code == 166 {
              XCTAssertGreaterThan(value, code)
            } else {
              XCTAssertEqual(value, code, accuracy: 1)
            }
          } catch { XCTFail("\(error)") }
          done.fulfill()
        })
      wait(for: [done], timeout: 10)
    }
  }

  func testUnknownOrHDRTransferDoesNotGetRetaggedAsSDR() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
    for transfer in ["Unknown", "SMPTE_ST_2084_PQ", "HLG"] {
      let b = try buffer()
      let s = stamp()
      let runtime = MonitorRuntime()
      let done = expectation(description: "unsupported transfer")
      var c = MonitorConfiguration()
      c.toolsEnabled = true
      c.zebra.enabled = true
      c.scopes.enabled = true
      runtime.configure(target: s.target, generation: 1, configurationRevision: 1, configuration: c)
      let signal = MonitorFrameSignal(range: .full, matrix: .bt709, transfer: transfer)
      XCTAssertTrue(
        runtime.offer(
          MonitorFrameBundle(
            stamp: s, source: b, output: b, sourceSignal: signal, outputSignal: signal)
        ) { result in
          do {
            let out = try result.get()
            XCTAssertNil(out.decorated)
            XCTAssertNotNil(out.scope)
            XCTAssertTrue(out.availability.contains { $0.contains("unsupported SDR") })
            XCTAssertNotNil(CVPixelBufferGetIOSurface(out.clean.pixelBuffer))
          } catch { XCTFail("\(error)") }
          done.fulfill()
        })
      wait(for: [done], timeout: 10)
    }
  }

  func testARRIFullRescaledToLegalUsesIndependentlyRoundedFullTable() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
    let source = try buffer(kCVPixelFormatType_422YpCbCr10)
    let output = try buffer()
    let s = stamp()
    let runtime = MonitorRuntime()
    let done = expectation(description: "native versus transported range")
    CVPixelBufferLockBaseAddress(source, [])
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(source))
    let patterns: [UInt32] = [
      512 | (878 << 10) | (512 << 20), 878 | (512 << 10) | (878 << 20),
      512 | (878 << 10) | (512 << 20), 878 | (512 << 10) | (878 << 20),
    ]
    for y in 0..<32 {
      let row = base.advanced(by: y * CVPixelBufferGetBytesPerRow(source)).assumingMemoryBound(
        to: UInt32.self)
      for x in 0..<64 { row[x] = patterns[x % 4] }
    }
    CVPixelBufferUnlockBaseAddress(source, [])
    var c = MonitorConfiguration()
    c.toolsEnabled = true
    c.falseColor.mode = .arri
    c.falseColor.profileID = ARRIFalseColorProfile.logC3EI800.rawValue
    c.sourceProfileID = ARRIFalseColorProfile.logC3EI800.rawValue
    c.sourceLogMapping = .fullRescaledToLegal10Bit
    runtime.configure(target: s.target, generation: 1, configurationRevision: 1, configuration: c)
    let signal = MonitorFrameSignal(
      range: .legal, matrix: .bt709, transfer: "logc3",
      profileID: ARRIFalseColorProfile.logC3EI800.rawValue)
    XCTAssertTrue(
      runtime.offer(
        MonitorFrameBundle(
          stamp: s, source: source, output: output, correspondence: .identity, sourceSignal: signal,
          outputSignal: MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "rec709"))
      ) { result in
        do {
          let b = try XCTUnwrap(try result.get().decorated).pixelBuffer
          CVPixelBufferLockBaseAddress(b, .readOnly)
          defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }
          let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(b)).assumingMemoryBound(
            to: UInt8.self)
          XCTAssertEqual(bytes[2], 255)
          XCTAssertEqual(bytes[1], 255)
          XCTAssertEqual(bytes[0], 0)
        } catch { XCTFail("\(error)") }
        done.fulfill()
      })
    wait(for: [done], timeout: 10)
  }

  func testOwnedDeliveryDoesNotHoldBoundedCopyAdmissionSlots() throws {
    let service = CleanPreviewService()
    let b = try buffer()
    let entered = expectation(description: "four independent copies")
    let finished = expectation(description: "four copies retired")
    let gate = DispatchSemaphore(value: 0)
    entered.expectedFulfillmentCount = 4
    finished.expectedFulfillmentCount = 4
    XCTAssertEqual(service.budget.maximumCleanCopyJobs, 4)
    for feed in 0..<4 {
      let s = MonitorFrameStamp(
        target: MonitorTargetID("copy-\(feed)"), generation: 1, sequence: 1, sourcePTS: 0,
        hostTime: 0, configurationRevision: 1)
      XCTAssertTrue(
        service.offer(MonitorFrameBundle(stamp: s, source: b)) { result in
          XCTAssertNotNil(try? result.get())
          withExtendedLifetime(result) {
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 5)
            finished.fulfill()
          }
        })
    }
    wait(for: [entered], timeout: 3)
    XCTAssertEqual(service.budget.snapshot.cleanCopyJobs, 0)
    XCTAssertGreaterThanOrEqual(service.budget.snapshot.retainedBytes, 4 * 1024 * 1024)
    let fifth = MonitorFrameStamp(
      target: MonitorTargetID("copy-fifth"), generation: 1, sequence: 1, sourcePTS: 0, hostTime: 0,
      configurationRevision: 1)
    let fifthDelivered = expectation(description: "copy proceeds during four owned deliveries")
    XCTAssertTrue(
      service.offer(MonitorFrameBundle(stamp: fifth, source: b)) { result in
        XCTAssertNotNil(try? result.get())
        fifthDelivered.fulfill()
      })
    wait(for: [fifthDelivered], timeout: 3)
    let occupied = try (0..<4).map { index in
      try XCTUnwrap(
        service.budget.tryAcquire(
          target: MonitorTargetID("occupied-\(index)"),
          generation: 1, kind: .cleanCopy, bytes: 0))
    }
    XCTAssertFalse(
      service.offer(MonitorFrameBundle(stamp: fifth, source: b)) { _ in
        XCTFail("A fifth active producer copy was admitted")
      })
    occupied.forEach { $0.release() }
    for _ in 0..<4 { gate.signal() }
    wait(for: [finished], timeout: 3)
  }

  func testAsymmetricAperturePreservesCoreVideoVerticalOffsetSign() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
    let b = try buffer()
    let stamp = stamp()
    let runtime = MonitorRuntime()
    let done = expectation(description: "asymmetric aperture")
    var c = MonitorConfiguration()
    c.toolsEnabled = true
    c.zebra.enabled = true
    runtime.configure(
      target: stamp.target, generation: 1, configurationRevision: 1, configuration: c)
    let signal = MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "rec709")
    let geometry = MonitorGeometry(
      width: 64, height: 32, cleanAperture: MonitorRect(x: 5, y: 3, width: 40, height: 20))
    XCTAssertTrue(
      runtime.offer(
        MonitorFrameBundle(
          stamp: stamp, source: b, output: b, outputGeometry: geometry, sourceSignal: signal,
          outputSignal: signal)
      ) { result in
        do {
          let b = try XCTUnwrap(try result.get().decorated).pixelBuffer
          let attachment =
            CVBufferCopyAttachment(b, kCVImageBufferCleanApertureKey, nil) as? [String: Any]
          XCTAssertEqual(
            (attachment?[kCVImageBufferCleanApertureVerticalOffsetKey as String] as? NSNumber)?
              .doubleValue, 3)
          XCTAssertEqual(
            (attachment?[kCVImageBufferCleanApertureHorizontalOffsetKey as String] as? NSNumber)?
              .doubleValue, -7)
        } catch { XCTFail("\(error)") }
        done.fulfill()
      })
    wait(for: [done], timeout: 10)
  }
  func testGraticuleToggleChangesOnlyScopeGridPixels() throws {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
      throw XCTSkip("Metal unavailable")
    }
    for enabled in [false, true] {
      let b = try buffer()
      let stamp = stamp()
      let runtime = MonitorRuntime(sharedDevice: { device })
      let done = expectation(description: "graticule")
      var c = MonitorConfiguration()
      c.toolsEnabled = true
      c.scopes.enabled = true
      c.scopes.graticule = enabled
      runtime.configure(
        target: stamp.target, generation: 1, configurationRevision: 1, configuration: c)
      let signal = MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "rec709")
      XCTAssertTrue(
        runtime.offer(
          MonitorFrameBundle(
            stamp: stamp, source: b, output: b, sourceSignal: signal, outputSignal: signal)
        ) { result in
          guard let out = try? result.get(), let scope = out.scope,
            let buffer = device.makeBuffer(length: 256, options: .storageModeShared),
            let command = queue.makeCommandBuffer(), let encoder = command.makeBlitCommandEncoder()
          else {
            XCTFail("scope unavailable")
            done.fulfill()
            return
          }
          XCTAssertEqual(out.pictureSignal?.transfer, "rec709")
          XCTAssertEqual(scope.signal?.range, .full)
          encoder.copy(
            from: scope.texture, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 1, y: 128, z: 0),
            sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: buffer, destinationOffset: 0,
            destinationBytesPerRow: 256, destinationBytesPerImage: 256)
          encoder.endEncoding()
          command.addCompletedHandler { _ in
            let value = buffer.contents().assumingMemoryBound(to: UInt8.self)[0]
            if enabled { XCTAssertGreaterThan(value, 0) } else { XCTAssertEqual(value, 0) }
            _ = scope
            done.fulfill()
          }
          command.commit()
        })
      wait(for: [done], timeout: 10)
    }
  }

  func testMalformedPlanarHeightCannotReadOrCopyUninitializedTail() throws {
    let storage = UnsafeMutableRawPointer.allocate(byteCount: 64 * 47, alignment: 64)
    memset(storage, 0, 64 * 47)
    var addresses: [UnsafeMutableRawPointer?] = [storage, storage.advanced(by: 64 * 32)]
    var widths = [64, 32]
    var heights = [32, 15]
    var strides = [64, 64]
    var image: CVPixelBuffer?
    let status = CVPixelBufferCreateWithPlanarBytes(
      nil, 64, 32, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, storage, 64 * 47, 2, &addresses,
      &widths, &heights, &strides,
      { _, data, _, _, _ in if let data { UnsafeMutableRawPointer(mutating: data).deallocate() } },
      nil, nil, &image)
    guard status == kCVReturnSuccess, let image else {
      storage.deallocate()
      return
    }  // Some OS versions reject malformed planes themselves.
    let done = expectation(description: "malformed plane rejected")
    let service = CleanPreviewService()
    XCTAssertTrue(
      service.offer(MonitorFrameBundle(stamp: stamp(), source: image)) { result in
        switch result {
        case .success: XCTFail("short chroma plane accepted")
        case .failure(let error): XCTAssertTrue(error is MonitorPreviewError)
        }
        done.fulfill()
      })
    wait(for: [done], timeout: 3)
  }

  func testFairnessUsesAllFourAdmittedCopySlots() {
    let fair = MonitorFairAdmission()
    let targets = (0..<5).map { MonitorTargetID("fair-\($0)") }
    for target in targets.prefix(4) { fair.attempted(target, admitted: false) }
    for target in targets.prefix(4) { XCTAssertTrue(fair.mayAttempt(target, capacity: 4)) }
    XCTAssertFalse(fair.mayAttempt(targets[4], capacity: 4))
    fair.attempted(targets[0], admitted: true)
    XCTAssertTrue(fair.mayAttempt(targets[4], capacity: 4))
  }

  func testPackedNonIOSurfaceInputCopiesWithoutMetalOrProducerRetention() throws {
    let storage = UnsafeMutableRawPointer.allocate(byteCount: 256 * 32, alignment: 64)
    memset(storage, 0x37, 256 * 32)
    var input: CVPixelBuffer?
    let status = CVPixelBufferCreateWithBytes(
      nil, 64, 32, kCVPixelFormatType_422YpCbCr10, storage, 256,
      { _, address in if let address { UnsafeMutableRawPointer(mutating: address).deallocate() } },
      nil, nil, &input)
    guard status == kCVReturnSuccess, let input else {
      storage.deallocate()
      throw XCTSkip("nonIOSurface packed buffer unavailable")
    }
    XCTAssertNil(CVPixelBufferGetIOSurface(input))
    let service = CleanPreviewService()
    let done = expectation(description: "packed native CPU copy")
    XCTAssertTrue(
      service.offer(MonitorFrameBundle(stamp: stamp(), source: input)) { result in
        do {
          let owned = try result.get()
          XCTAssertNotNil(CVPixelBufferGetIOSurface(owned.pixelBuffer))
          CVPixelBufferLockBaseAddress(owned.pixelBuffer, .readOnly)
          defer { CVPixelBufferUnlockBaseAddress(owned.pixelBuffer, .readOnly) }
          let byte = try XCTUnwrap(CVPixelBufferGetBaseAddress(owned.pixelBuffer)).load(
            as: UInt8.self)
          XCTAssertEqual(byte, 0x37)
        } catch { XCTFail("\(error)") }
        done.fulfill()
      })
    wait(for: [done], timeout: 3)
  }

  func testEveryPublishedARRINativeTenBitBoundaryOnGPU() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
    let runtime = MonitorRuntime()
    var revision: UInt64 = 0
    for profile in ARRIFalseColorProfile.allCases {
      for range in [MonitorCodeRange.legal, .full] {
        revision += 1
        let codes = profile.zones(range: range).flatMap {
          [max(0, Int($0.lower) - 1), Int($0.lower), Int($0.upper) - 1, Int($0.upper)]
        }
        let b = try buffer(kCVPixelFormatType_422YpCbCr10, width: codes.count * 6, height: 32)
        CVPixelBufferLockBaseAddress(b, [])
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(b))
        for row in 0..<32 {
          let words = base.advanced(by: row * CVPixelBufferGetBytesPerRow(b)).assumingMemoryBound(
            to: UInt32.self)
          for (index, code) in codes.enumerated() {
            let y = UInt32(code)
            words[index * 4] = 512 | (y << 10) | (512 << 20)
            words[index * 4 + 1] = y | (512 << 10) | (y << 20)
            words[index * 4 + 2] = 512 | (y << 10) | (512 << 20)
            words[index * 4 + 3] = y | (512 << 10) | (y << 20)
          }
        }
        CVPixelBufferUnlockBaseAddress(b, [])
        var config = MonitorConfiguration()
        config.toolsEnabled = true
        config.pictureStage = .source
        config.falseColor.mode = .arri
        config.falseColor.profileID = profile.rawValue
        config.sourceProfileID = profile.rawValue
        let stamp = MonitorFrameStamp(
          target: MonitorTargetID("boundaries"), generation: 1, sequence: revision,
          sourcePTS: Double(revision), hostTime: Double(revision), configurationRevision: revision)
        runtime.configure(
          target: stamp.target, generation: 1, configurationRevision: revision,
          configuration: config)
        let done = expectation(
          description: "\(profile.rawValue) \(range.rawValue) native boundary table")
        let offerBoundary = {
          runtime.offer(
            MonitorFrameBundle(
              stamp: stamp, source: b, correspondence: .identity,
              sourceSignal: MonitorFrameSignal(
                range: range, matrix: .bt709, transfer: profile.rawValue,
                profileID: profile.rawValue))
          ) { result in
            do {
              let output = try XCTUnwrap(try result.get().decorated).pixelBuffer
              CVPixelBufferLockBaseAddress(output, .readOnly)
              defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
              let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(output)).assumingMemoryBound(
                to: UInt8.self)
              for (index, code) in codes.enumerated() {
                let gray = range.normalizeLuma(code: Double(code), bitDepth: 10)!
                let rgb =
                  profile.category(achromaticCode: Double(code), range: range)?.color
                  ?? MonitorRGB(r: gray, g: gray, b: gray)
                let expected = [rgb.b, rgb.g, rgb.r]
                for channel in 0..<3 {
                  XCTAssertEqual(
                    Double(bytes[index * 6 * 4 + channel]), min(1, max(0, expected[channel])) * 255,
                    accuracy: 1, "\(profile.rawValue) \(range.rawValue) native code\(code)")
                }
              }
            } catch { XCTFail("\(error)") }
            done.fulfill()
          }
        }
        var admitted = offerBoundary()
        for _ in 0..<100 where !admitted {
          Thread.sleep(forTimeInterval: 0.001)
          admitted = offerBoundary()
        }
        XCTAssertTrue(admitted, "bounded admission retry; no producer FIFO")
        wait(for: [done], timeout: 10)
      }
    }
  }

  func testDeclaredSourceLogShowsCodeViewWithNumericZebraAndSourceFocus() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
    let b = try buffer()
    let runtime = MonitorRuntime()
    let s = stamp()
    let done = expectation(description: "declared Log numeric tools")
    CVPixelBufferLockBaseAddress(b, [])
    let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(b)).assumingMemoryBound(to: UInt8.self)
    for y in 0..<32 {
      for x in 0..<64 {
        for c in 0..<4 { base[y * CVPixelBufferGetBytesPerRow(b) + x * 4 + c] = x < 32 ? 0 : 192 }
      }
    }
    CVPixelBufferUnlockBaseAddress(b, [])
    let profile = "sony-slog3-sgamut3cine"
    var config = MonitorConfiguration()
    config.toolsEnabled = true
    config.pictureStage = .source
    config.sourceProfileID = profile
    config.zebra.enabled = true
    config.zebra.thresholdIRE = 50
    config.focus.enabled = true
    runtime.configure(
      target: s.target, generation: 1, configurationRevision: 1, configuration: config)
    XCTAssertTrue(
      runtime.offer(
        MonitorFrameBundle(
          stamp: s, source: b, correspondence: .identity,
          sourceSignal: MonitorFrameSignal(
            range: .full, matrix: .bt709, transfer: profile, profileID: profile))
      ) { result in
        do {
          let result = try result.get()
          XCTAssertTrue(result.availability.contains { $0.contains("code-value view") })
          XCTAssertEqual(result.pictureSignal?.profileID, profile)
          let image = try XCTUnwrap(result.decorated).pixelBuffer
          CVPixelBufferLockBaseAddress(image, .readOnly)
          defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
          let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(image)).assumingMemoryBound(
            to: UInt8.self)
          XCTAssertGreaterThan(bytes[48 * 4], 192)
          let edge = 16 * CVPixelBufferGetBytesPerRow(image) + 32 * 4
          XCTAssertGreaterThan(bytes[edge + 2], bytes[edge + 1])
        } catch { XCTFail("\(error)") }
        done.fulfill()
      })
    wait(for: [done], timeout: 10)
  }
  func testLargeNativePlanarCopiesUsePlaneStridesWithinReservedMemory() throws {
    let fixtures: [(OSType, Int, Int, Int)] = [
      (kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, 3840, 2160, 40 * 1024 * 1024),
      (kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, 3840, 2160, 32 * 1024 * 1024),
      (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 1920, 1080, 5 * 1024 * 1024),
      (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 1922, 1082, 5 * 1024 * 1024),
      (kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, 1922, 1082, 12 * 1024 * 1024),
    ]
    for (format, width, height, maximumAllocation) in fixtures {
      let input = try buffer(format, width: width, height: height)
      CVBufferSetAttachment(
        input, kCVImageBufferYCbCrMatrixKey,
        kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
      try Self.fillPlanarFixture(input)
      let reservation = CleanPreviewService.reservation(input)
      XCTAssertLessThanOrEqual(reservation, maximumAllocation)
      let ledger = MonitorAdmissionLedger(
        maximumCleanCopyJobs: 1, maximumBytes: 64 * 1024 * 1024,
        cleanReserveBytes: 64 * 1024 * 1024)
      let service = CleanPreviewService(budget: ledger)
      let holder = Holder()
      let copied = expectation(description: "large native owned copy")
      XCTAssertTrue(
        service.offer(MonitorFrameBundle(stamp: stamp(), source: input)) { result in
          do { holder.frame = try result.get() } catch { XCTFail("\(error)") }
          copied.fulfill()
        })
      wait(for: [copied], timeout: 5)
      let output = try XCTUnwrap(holder.frame).pixelBuffer
      XCTAssertGreaterThan(ledger.snapshot.retainedBytes, 0)
      XCTAssertLessThanOrEqual(ledger.snapshot.retainedBytes, 64 * 1024 * 1024)
      XCTAssertNotNil(CVPixelBufferGetIOSurface(output))
      XCTAssertFalse(input === output)
      XCTAssertLessThanOrEqual(CVPixelBufferGetDataSize(output), reservation)
      XCTAssertLessThanOrEqual(CVPixelBufferGetDataSize(output), maximumAllocation)
      XCTAssertEqual(CVPixelBufferGetPixelFormatType(output), format)
      XCTAssertEqual(
        CVBufferCopyAttachment(output, kCVImageBufferYCbCrMatrixKey, nil) as? String,
        kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
      try Self.assertPlanarSamplesEqual(input, output)
    }
  }

  func testPaddedPlanarSourceCompactsIntoSmallerOwnedNativeStrides() throws {
    let width = 1920
    let height = 1080
    let yStride = 2304
    let uvStride = 2432
    let byteCount = yStride * height + uvStride * (height / 2)
    let storage = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 64)
    var addresses: [UnsafeMutableRawPointer?] = [storage, storage.advanced(by: yStride * height)]
    var widths = [width, width / 2]
    var heights = [height, height / 2]
    var strides = [yStride, uvStride]
    var input: CVPixelBuffer?
    let status = CVPixelBufferCreateWithPlanarBytes(
      nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      storage, byteCount, 2, &addresses, &widths, &heights, &strides,
      { _, data, _, _, _ in
        if let data { UnsafeMutableRawPointer(mutating: data).deallocate() }
      }, nil, nil, &input)
    guard status == kCVReturnSuccess, let input else {
      storage.deallocate()
      throw XCTSkip("Padded native planar fixture unavailable")
    }
    try Self.fillPlanarFixture(input)
    let reservation = CleanPreviewService.reservation(input)
    let output = try CleanPreviewService.copy(input, reservation: reservation)
    XCTAssertLessThan(CVPixelBufferGetBytesPerRowOfPlane(output, 0), yStride)
    XCTAssertLessThan(CVPixelBufferGetBytesPerRowOfPlane(output, 1), uvStride)
    XCTAssertLessThanOrEqual(CVPixelBufferGetDataSize(output), reservation)
    try Self.assertPlanarSamplesEqual(input, output)
  }

  private static func fillPlanarFixture(_ image: CVPixelBuffer) throws {
    XCTAssertEqual(CVPixelBufferLockBaseAddress(image, []), kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(image, []) }
    let tenBit = [
      kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
      kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
    ].contains(CVPixelBufferGetPixelFormatType(image))
    for plane in 0..<CVPixelBufferGetPlaneCount(image) {
      let base = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(image, plane))
      let stride = CVPixelBufferGetBytesPerRowOfPlane(image, plane)
      let rows = CVPixelBufferGetHeightOfPlane(image, plane)
      let active =
        CVPixelBufferGetWidthOfPlane(image, plane) * (plane == 0 ? 1 : 2) * (tenBit ? 2 : 1)
      for y in 0..<rows {
        let row = base.advanced(by: y * stride)
        memset(row, 0xD3, stride)
        if tenBit {
          row.assumingMemoryBound(to: UInt16.self).initialize(
            repeating: UInt16((y + plane * 379) % 1024) << 6, count: active / 2)
        } else {
          memset(row, Int32((y * 13 + plane * 47) % 256), active)
        }
      }
    }
  }

  private static func assertPlanarSamplesEqual(_ input: CVPixelBuffer, _ output: CVPixelBuffer)
    throws
  {
    XCTAssertEqual(CVPixelBufferLockBaseAddress(input, .readOnly), kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(input, .readOnly) }
    XCTAssertEqual(CVPixelBufferLockBaseAddress(output, .readOnly), kCVReturnSuccess)
    defer { CVPixelBufferUnlockBaseAddress(output, .readOnly) }
    XCTAssertEqual(CVPixelBufferGetPlaneCount(input), CVPixelBufferGetPlaneCount(output))
    let tenBit = [
      kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
      kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
    ].contains(CVPixelBufferGetPixelFormatType(input))
    for plane in 0..<CVPixelBufferGetPlaneCount(input) {
      let src = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(input, plane))
      let dst = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(output, plane))
      let rows = CVPixelBufferGetHeightOfPlane(input, plane)
      XCTAssertEqual(rows, CVPixelBufferGetHeightOfPlane(output, plane))
      XCTAssertEqual(
        CVPixelBufferGetWidthOfPlane(input, plane), CVPixelBufferGetWidthOfPlane(output, plane))
      let active =
        CVPixelBufferGetWidthOfPlane(input, plane) * (plane == 0 ? 1 : 2) * (tenBit ? 2 : 1)
      let srcStride = CVPixelBufferGetBytesPerRowOfPlane(input, plane)
      let dstStride = CVPixelBufferGetBytesPerRowOfPlane(output, plane)
      for y in 0..<rows {
        XCTAssertEqual(
          memcmp(src.advanced(by: y * srcStride), dst.advanced(by: y * dstStride), active), 0,
          "Native plane \(plane), row \(y) changed active samples")
      }
    }
  }

  func testToolsOffOwnedDeliveryReleasesProducerBeforeBlockedConsumer() throws {
    let released = expectation(description: "producer storage released")
    let entered = expectation(description: "owned consumer entered")
    let finished = expectation(description: "owned consumer finished")
    let gate = DispatchSemaphore(value: 0)
    let storage = UnsafeMutableRawPointer.allocate(byteCount: 256 * 32, alignment: 64)
    memset(storage, 0x73, 256 * 32)
    let witness = Unmanaged.passRetained(ProducerReleaseWitness(released)).toOpaque()
    var source: CVPixelBuffer?
    let status = CVPixelBufferCreateWithBytes(
      nil, 64, 32, kCVPixelFormatType_32BGRA,
      storage, 256,
      { refcon, address in
        if let address { UnsafeMutableRawPointer(mutating: address).deallocate() }
        if let refcon {
          Unmanaged<ProducerReleaseWitness>.fromOpaque(refcon).takeRetainedValue().released
            .fulfill()
        }
      }, witness, nil, &source)
    guard status == kCVReturnSuccess else {
      Unmanaged<ProducerReleaseWitness>.fromOpaque(witness).release()
      storage.deallocate()
      throw XCTSkip("Native producer lifetime fixture unavailable")
    }
    let runtime = MonitorRuntime(sharedDevice: {
      XCTFail("Tools-off copy initialized Metal")
      return nil
    })
    let stamp = stamp()
    runtime.configure(
      target: stamp.target, generation: 1, configurationRevision: 1,
      configuration: MonitorConfiguration())
    XCTAssertTrue(
      runtime.offer(MonitorFrameBundle(stamp: stamp, source: try XCTUnwrap(source))) { result in
        XCTAssertNotNil(try? result.get())
        withExtendedLifetime(result) {
          entered.fulfill()
          _ = gate.wait(timeout: .now() + 5)
          finished.fulfill()
        }
      })
    source = nil
    wait(for: [released, entered], timeout: 3)
    XCTAssertEqual(runtime.ledger.snapshot.cleanCopyJobs, 0)
    XCTAssertGreaterThan(runtime.ledger.snapshot.retainedBytes, 0)
    gate.signal()
    wait(for: [finished], timeout: 3)
  }

  func testBlockedErrorDeliveryRetainsBudgetUntilConsumerReturns() throws {
    let input = try buffer(kCVPixelFormatType_32ARGB)  // Native allocation, unsupported clean format.
    let ledger = MonitorAdmissionLedger(
      maximumCleanCopyJobs: 4,
      maximumBytes: 1024 * 1024, cleanReserveBytes: 1024 * 1024)
    let service = CleanPreviewService(budget: ledger)
    let entered = expectation(description: "error-only consumer entered")
    let finished = expectation(description: "error-only consumer finished")
    let gate = DispatchSemaphore(value: 0)
    XCTAssertTrue(
      service.offer(MonitorFrameBundle(stamp: stamp(), source: input)) { result in
        if case .success = result { XCTFail("Unsupported native format unexpectedly copied") }
        entered.fulfill()
        _ = gate.wait(timeout: .now() + 5)
        finished.fulfill()
      })
    wait(for: [entered], timeout: 3)
    XCTAssertEqual(ledger.snapshot.cleanCopyJobs, 0)
    XCTAssertEqual(ledger.snapshot.retainedBytes, ledger.maximumBytes)
    let second = MonitorFrameStamp(
      target: MonitorTargetID("second-error"), generation: 1,
      sequence: 1, sourcePTS: 0, hostTime: 0, configurationRevision: 1)
    XCTAssertFalse(
      service.offer(MonitorFrameBundle(stamp: second, source: input)) { _ in
        XCTFail("Uncharged error delivery exceeded the byte budget")
      })
    gate.signal()
    wait(for: [finished], timeout: 3)
    let drained = expectation(
      for: NSPredicate { _, _ in ledger.snapshot.retainedBytes == 0 },
      evaluatedWith: nil, handler: nil)
    wait(for: [drained], timeout: 3)
  }

  private final class ProducerReleaseWitness: @unchecked Sendable {
    let released: XCTestExpectation
    init(_ released: XCTestExpectation) { self.released = released }
  }

  private final class Holder: @unchecked Sendable {
    var buffer: CVPixelBuffer?
    var frame: MonitorOwnedFrame?
  }

  func testAnalysisRoundAdmissionIsFairForFixedOrderFourFeedBursts() {
    for capacity in [2, 3] {
      let fair = MonitorAnalysisFairAdmission()
      let targets = (0..<4).map { MonitorTargetID("round-\($0)") }
      // Discover all targets without retaining any producer frame.
      var initial: [MonitorTargetID] = []
      for target in targets where fair.tryBegin(target, capacity: capacity) {
        initial.append(target)
      }
      for target in initial { fair.complete(target) }
      var counts = [Int](repeating: 0, count: 4)
      for _ in 0..<40 {
        var active: [MonitorTargetID] = []
        for (index, target) in targets.enumerated() {
          if fair.tryBegin(target, capacity: capacity) {
            active.append(target)
            counts[index] += 1
            XCTAssertFalse(
              fair.tryBegin(target, capacity: capacity), "one borrowed frame per target")
          }
        }
        XCTAssertEqual(active.count, capacity)
        for target in active { fair.complete(target) }
      }
      XCTAssertEqual(Set(counts).count, 1, "fixed ordering must not favor early feeds: \(counts)")
      XCTAssertEqual(counts[0], capacity * 10)
    }
    XCTAssertEqual(MonitorRuntime().ledger.maximumAnalysisJobs, 3)
    XCTAssertEqual(MonitorAdmissionLedger().maximumAnalysisJobs, 2)
  }

  func testAnalysisRoundProgressesWhenEligibleFeedDisappearsOrAdmissionFails() {
    let fair = MonitorAnalysisFairAdmission()
    let a = MonitorTargetID("active")
    let b = MonitorTargetID("hidden")
    let c = MonitorTargetID("late")
    XCTAssertTrue(fair.tryBegin(a, capacity: 2))
    XCTAssertTrue(fair.tryBegin(b, capacity: 2))
    XCTAssertFalse(fair.tryBegin(c, capacity: 2))
    fair.complete(a)
    fair.complete(b)
    // b no longer offers; unconsumed eligibility never holds an input or a slot.
    var admitted = 0
    for _ in 0..<20 {
      var current: [MonitorTargetID] = []
      for target in [a, c] where fair.tryBegin(target, capacity: 2) { current.append(target) }
      admitted += current.count
      for target in current { fair.complete(target) }  // also models failed ledger admission
    }
    XCTAssertGreaterThan(admitted, 20)
    XCTAssertTrue(fair.tryBegin(a, capacity: 2) || fair.tryBegin(c, capacity: 2))
  }

  func testRetiredLongRunningAnalysisDoesNotStallOtherFeedRounds() {
    let fair = MonitorAnalysisFairAdmission()
    let targets = (0..<4).map { MonitorTargetID("stalled-\($0)") }
    XCTAssertTrue(fair.tryBegin(targets[0], capacity: 3))
    XCTAssertTrue(fair.tryBegin(targets[1], capacity: 3))
    XCTAssertTrue(fair.tryBegin(targets[2], capacity: 3))
    XCTAssertFalse(fair.tryBegin(targets[3], capacity: 3))
    fair.complete(targets[1])
    fair.complete(targets[2])
    var counts = [Int](repeating: 0, count: 3)
    for _ in 0..<30 {
      var active: [MonitorTargetID] = []
      for (index, target) in targets.dropFirst().enumerated() {
        if fair.tryBegin(target, capacity: 3) {
          active.append(target)
          counts[index] += 1
        }
      }
      XCTAssertLessThanOrEqual(active.count, 2)
      for target in active { fair.complete(target) }
    }
    XCTAssertTrue(
      counts.allSatisfy { $0 > 10 }, "one retained retired job must not stall others: \(counts)")
    fair.complete(targets[0])
  }

  func testSoftGPUDeadlineInvalidatesPublicationWithoutReleasingCommittedResources() throws {
    let ledger = MonitorAdmissionLedger(maximumAnalysisJobs: 3)
    let fair = MonitorAnalysisFairAdmission()
    let target = MonitorTargetID("deadline")
    XCTAssertTrue(fair.tryBegin(target, capacity: 3))
    let lease = try XCTUnwrap(
      ledger.tryAcquire(target: target, generation: 1, kind: .analysis, bytes: 4096))
    let job = AnalysisJob(lease, target: target, fairness: fair)
    let timeout = expectation(description: "soft deadline")
    job.armDeadline(after: 0.01) { timeout.fulfill() }
    wait(for: [timeout], timeout: 1)
    XCTAssertTrue(job.deadlineExceeded)
    ledger.retire(target: target, generation: 1)
    XCTAssertEqual(ledger.snapshot.analysisJobs, 1)
    XCTAssertEqual(ledger.snapshot.retiredBytes, 4096)
    XCTAssertFalse(fair.tryBegin(target, capacity: 3))
    job.release()
    job.release()
    XCTAssertEqual(ledger.snapshot.retainedBytes, 0)
    XCTAssertEqual(ledger.snapshot.analysisJobs, 0)
    XCTAssertTrue(fair.tryBegin(target, capacity: 3))
    fair.complete(target)
  }

  func testRuntimeTelemetryAppliesPressureQualityAndCountsEveryUniqueResult() {
    let telemetry = RuntimeTelemetry()
    let target = MonitorTargetID("telemetry")
    let ledger = MonitorAdmissionLedger()
    for index in 0..<8 {
      telemetry.record(target, offer: true, skip: true, pressure: true, requestedScopeHz: 30)
      _ = telemetry.tick(now: Double(index) * 0.25, budget: ledger.snapshot)
    }
    let quality = telemetry.quality(target, requested: 30)
    XCTAssertEqual(quality.tier, .reduced)
    XCTAssertEqual(quality.pictureHeightLimit, 720)
    XCTAssertEqual(quality.scopeSamplingStride, 4)
    XCTAssertEqual(quality.scopeRefreshHz, 12)
    // Several results between UI snapshots must all contribute, including cached-scope deduplication.
    for index in 0..<30 {
      let stamp = MonitorFrameStamp(
        target: target, generation: 1, sequence: UInt64(index), sourcePTS: Double(index) / 30,
        hostTime: 1 + Double(index) / 30, configurationRevision: 1)
      telemetry.record(
        target, offer: true, admission: true, picture: stamp, scope: index % 3 == 0 ? stamp : nil)
    }
    _ = telemetry.tick(now: 2, budget: ledger.snapshot)
    let diagnostic = telemetry.diagnostic(target)
    XCTAssertEqual(diagnostic.pictureFPS, 30)
    XCTAssertEqual(diagnostic.scopeFPS, 10)
    XCTAssertEqual(diagnostic.effectiveQuality.tier, .reduced)
    for index in 0..<24 {
      _ = telemetry.tick(now: 3.25 + Double(index) * 0.25, budget: ledger.snapshot)
    }
    XCTAssertEqual(telemetry.quality(target, requested: 30).tier, .nominal)
  }

  func testGPUCompletionAtomicallyWinsBeforeSoftDeadline() throws {
    let ledger = MonitorAdmissionLedger()
    let fair = MonitorAnalysisFairAdmission()
    let target = MonitorTargetID("completed-before-deadline")
    XCTAssertTrue(fair.tryBegin(target, capacity: 2))
    let lease = try XCTUnwrap(
      ledger.tryAcquire(target: target, generation: 1, kind: .analysis, bytes: 4096))
    let job = AnalysisJob(lease, target: target, fairness: fair)
    let timeout = expectation(description: "completed work cannot later emit timeout")
    timeout.isInverted = true
    job.armDeadline(after: 0.01) { timeout.fulfill() }
    XCTAssertFalse(job.release(), "completion atomically claims publication and cancels timeout")
    wait(for: [timeout], timeout: 0.05)
    XCTAssertFalse(job.deadlineExceeded)
    XCTAssertEqual(ledger.snapshot.retainedBytes, 0)
  }

  func testAnalysisFailureDeliveryReleasesProducerBeforeBlockedConsumer() throws {
    for format in [kCVPixelFormatType_32BGRA, kCVPixelFormatType_32ARGB] {
      let released = expectation(description: "analysis producer released \(format)")
      let entered = expectation(description: "analysis failure consumer entered \(format)")
      let finished = expectation(description: "analysis failure consumer finished \(format)")
      let gate = DispatchSemaphore(value: 0)
      var source: CVPixelBuffer? = try producerBuffer(format: format, released: released)
      let runtime = MonitorRuntime(sharedDevice: { nil })
      var configuration = MonitorConfiguration()
      configuration.toolsEnabled = true
      configuration.zebra.enabled = true
      let stamp = stamp()
      runtime.configure(
        target: stamp.target, generation: 1, configurationRevision: 1, configuration: configuration)
      XCTAssertTrue(
        runtime.offer(
          MonitorFrameBundle(
            stamp: stamp, source: try XCTUnwrap(source),
            sourceSignal: MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "Rec709"))
        ) { result in
          if format == kCVPixelFormatType_32ARGB {
            if case .success = result { XCTFail("unsupported input should fail") }
          } else {
            XCTAssertNotNil(try? result.get().clean)
          }
          withExtendedLifetime(result) {
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 5)
            finished.fulfill()
          }
        })
      source = nil
      wait(for: [entered], timeout: 3)
      XCTAssertEqual(runtime.ledger.snapshot.analysisJobs, 0)
      wait(for: [released], timeout: 0.5)
      gate.signal()
      wait(for: [finished], timeout: 3)
    }
  }

  private func producerBuffer(format: OSType, released: XCTestExpectation) throws -> CVPixelBuffer {
    let storage = UnsafeMutableRawPointer.allocate(byteCount: 256 * 32, alignment: 64)
    memset(storage, 0x73, 256 * 32)
    let witness = Unmanaged.passRetained(ProducerReleaseWitness(released)).toOpaque()
    var source: CVPixelBuffer?
    let status = CVPixelBufferCreateWithBytes(
      nil, 64, 32, format, storage, 256,
      { refcon, address in
        if let address { UnsafeMutableRawPointer(mutating: address).deallocate() }
        if let refcon {
          Unmanaged<ProducerReleaseWitness>.fromOpaque(refcon).takeRetainedValue().released
            .fulfill()
        }
      }, witness, nil, &source)
    guard status == kCVReturnSuccess, let source else {
      Unmanaged<ProducerReleaseWitness>.fromOpaque(witness).release()
      storage.deallocate()
      throw XCTSkip("native producer lifetime fixture unavailable")
    }
    return source
  }

  func testBlockedGPUConsumerReleasesProducerAndReusesWorkingSetBeforeNextDelivery() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
    let ledger = MonitorAdmissionLedger(
      // Two composites now also retain two conservative pool-cache leases.
      // Preserve the previous slack: a second working set still cannot fit.
      maximumAnalysisJobs: 1, maximumBytes: 4_340_000 + 2 * 1_048_576,
      cleanReserveBytes: 1_000_000)
    let runtime = MonitorRuntime(ledger: ledger)
    var config = MonitorConfiguration()
    config.toolsEnabled = true
    config.zebra.enabled = true
    let firstStamp = stamp()
    runtime.configure(
      target: firstStamp.target, generation: 1, configurationRevision: 1, configuration: config)
    let released = expectation(description: "GPU producer released before consumer")
    let entered = expectation(description: "first GPU consumer blocked")
    let finished = expectation(description: "first GPU consumer finished")
    let next = expectation(description: "second GPU consumer progresses")
    let gate = DispatchSemaphore(value: 0)
    defer { gate.signal() }
    var source: CVPixelBuffer? = try producerBuffer(
      format: kCVPixelFormatType_32BGRA, released: released)
    let signal = MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "Rec709")
    XCTAssertTrue(
      runtime.offer(
        MonitorFrameBundle(stamp: firstStamp, source: try XCTUnwrap(source), sourceSignal: signal)
      ) { result in
        XCTAssertNotNil(try? result.get().decorated)
        withExtendedLifetime(result) {
          entered.fulfill()
          _ = gate.wait(timeout: .now() + 5)
          finished.fulfill()
        }
      })
    source = nil
    wait(for: [entered, released], timeout: 3)
    XCTAssertEqual(ledger.snapshot.analysisJobs, 0)
    let identity = try XCTUnwrap(runtime.cachedWorkingSetIdentities()[firstStamp.target])
    var secondStamp = firstStamp
    secondStamp.sequence = 2
    let secondInput = try buffer()
    XCTAssertTrue(
      runtime.offer(
        MonitorFrameBundle(stamp: secondStamp, source: secondInput, sourceSignal: signal)
      ) { result in
        XCTAssertNotNil(
          try? result.get().decorated,
          "budget fits one work set plus two owned results; allocating another set cannot pass")
        next.fulfill()
      })
    wait(for: [next], timeout: 3)
    XCTAssertEqual(runtime.cachedWorkingSetIdentities()[firstStamp.target], identity)
    XCTAssertLessThanOrEqual(ledger.snapshot.retainedBytes, ledger.maximumBytes)
    gate.signal()
    wait(for: [finished], timeout: 3)
  }

  func testFourStableFeedsReuseAllCachedWorkingSetsAndRetireWithinBudget() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
    let runtime = MonitorRuntime()
    let targets = (0..<4).map { MonitorTargetID("cache-\($0)") }
    let input = try buffer()
    var config = MonitorConfiguration()
    config.toolsEnabled = true
    config.zebra.enabled = true
    for target in targets {
      runtime.configure(
        target: target, generation: 1, configurationRevision: 1, configuration: config)
    }
    var original: [MonitorTargetID: ObjectIdentifier] = [:]
    for round in 0..<3 {
      for target in targets {
        let done = expectation(description: "cache round \(round) \(target.rawValue)")
        let stamp = MonitorFrameStamp(
          target: target, generation: 1, sequence: UInt64(round + 1),
          sourcePTS: Double(round), hostTime: Double(round), configurationRevision: 1)
        var admitted = false
        for _ in 0..<100 where !admitted {
          admitted = runtime.offer(
            MonitorFrameBundle(
              stamp: stamp, source: input,
              sourceSignal: MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "Rec709"))
          ) { result in
            XCTAssertNotNil(try? result.get().decorated)
            done.fulfill()
          }
          if !admitted { Thread.sleep(forTimeInterval: 0.001) }
        }
        XCTAssertTrue(admitted)
        wait(for: [done], timeout: 3)
      }
      let cached = runtime.cachedWorkingSetIdentities()
      XCTAssertEqual(cached.count, 4)
      if round == 0 {
        original = cached
      } else {
        XCTAssertEqual(cached, original, "stable fourth feed must not force cache churn")
      }
      XCTAssertEqual(runtime.ledger.snapshot.analysisJobs, 0)
      XCTAssertLessThanOrEqual(runtime.ledger.snapshot.retainedBytes, runtime.ledger.maximumBytes)
    }
    for target in targets { runtime.remove(target: target) }
    let drained = expectation(
      for: NSPredicate { _, _ in runtime.ledger.snapshot.retainedBytes == 0 }, evaluatedWith: nil)
    wait(for: [drained], timeout: 3)
  }

  func testAnalysisErrorOnlyDeliveryStaysBudgetBoundedWhileConsumerBlocks() throws {
    let ledger = MonitorAdmissionLedger(
      maximumAnalysisJobs: 1, maximumBytes: 1_250_000, cleanReserveBytes: 1_000_000)
    let runtime = MonitorRuntime(ledger: ledger, sharedDevice: { nil })
    let input = try buffer(kCVPixelFormatType_32ARGB)
    var config = MonitorConfiguration()
    config.toolsEnabled = true
    config.zebra.enabled = true
    let first = stamp()
    runtime.configure(
      target: first.target, generation: 1, configurationRevision: 1, configuration: config)
    let entered = expectation(description: "charged analysis error blocks")
    let finished = expectation(description: "charged analysis error finishes")
    let gate = DispatchSemaphore(value: 0)
    defer { gate.signal() }
    XCTAssertTrue(
      runtime.offer(MonitorFrameBundle(stamp: first, source: input)) { result in
        if case .success = result { XCTFail("unsupported input unexpectedly succeeded") }
        entered.fulfill()
        _ = gate.wait(timeout: .now() + 5)
        finished.fulfill()
      })
    wait(for: [entered], timeout: 3)
    XCTAssertEqual(ledger.snapshot.analysisJobs, 0)
    XCTAssertGreaterThanOrEqual(ledger.snapshot.retainedBytes, 1_048_576)
    var second = first
    second.sequence = 2
    XCTAssertFalse(
      runtime.offer(MonitorFrameBundle(stamp: second, source: input)) { _ in
        XCTFail("uncharged error exceeded budget")
      })
    gate.signal()
    wait(for: [finished], timeout: 3)
    runtime.remove(target: first.target)
    let drained = expectation(
      for: NSPredicate { _, _ in ledger.snapshot.retainedBytes == 0 }, evaluatedWith: nil)
    wait(for: [drained], timeout: 3)
  }

  func testDiagnosticBlockedGPUObserverCrossQueueChronology() throws {
    guard let device = MTLCreateSystemDefaultDevice(),
      let independentQueue = device.makeCommandQueue(),
      let destination = device.makeBuffer(length: 1024 * 1024, options: .storageModePrivate)
    else {
      throw XCTSkip("Metal unavailable")
    }
    let state = CrossQueueDiagnosticState()
    let runtime = MonitorRuntime(sharedDevice: { device }, gpuTiming: { _, _ in state.observe() })
    var config = MonitorConfiguration()
    config.toolsEnabled = true
    config.zebra.enabled = true
    let target = MonitorTargetID("cross-queue-diagnostic")
    runtime.configure(
      target: target, generation: 1, configurationRevision: 1, configuration: config)
    let signal = MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "Rec709")
    let warm = expectation(description: "warm monitor pipelines")
    XCTAssertTrue(
      runtime.offer(
        MonitorFrameBundle(
          stamp: MonitorFrameStamp(
            target: target, generation: 1,
            sequence: 1, sourcePTS: 0, hostTime: ProcessInfo.processInfo.systemUptime,
            configurationRevision: 1),
          source: try buffer(), sourceSignal: signal)
      ) { result in
        XCTAssertNotNil(try? result.get().decorated)
        warm.fulfill()
      })
    wait(for: [warm], timeout: 5)
    var receipts: [[String: Double]] = []
    for (index, hold) in [0.0, 0.1, 0.25, 0.5].enumerated() {
      let round = CrossQueueDiagnosticRound(hold: hold)
      guard let event = device.makeSharedEvent(),
        let command = independentQueue.makeCommandBuffer(),
        let blit = command.makeBlitCommandEncoder()
      else { throw XCTSkip("Shared GPU event unavailable") }
      blit.fill(buffer: destination, range: 0..<destination.length, value: UInt8(index + 1))
      blit.endEncoding()
      command.encodeSignalEvent(event, value: 1)
      command.addCompletedHandler { _ in round.record("independent_handler") }
      // Both command queues and every independent GPU resource exist before blocking the observer.
      var source: CVPixelBuffer? = try diagnosticProducer(round: round)
      state.set(round)
      let delivered = expectation(description: "monitor result after diagnostic hold \(hold)")
      let stamp = MonitorFrameStamp(
        target: target, generation: 1, sequence: UInt64(index + 2),
        sourcePTS: Double(index + 1), hostTime: ProcessInfo.processInfo.systemUptime,
        configurationRevision: 1)
      XCTAssertTrue(
        runtime.offer(
          MonitorFrameBundle(stamp: stamp, source: try XCTUnwrap(source), sourceSignal: signal)
        ) { result in
          XCTAssertNotNil(try? result.get().decorated)
          round.record("monitor_delivery")
          delivered.fulfill()
        })
      source = nil
      XCTAssertEqual(round.entered.wait(timeout: .now() + 3), .success)
      round.record("observer_entry_observed")
      let budget = runtime.ledger.snapshot
      round.setValue("ledger_jobs_while_observer_blocked", Double(budget.analysisJobs))
      round.setValue("ledger_bytes_while_observer_blocked", Double(budget.retainedBytes))
      // The release runs independently of both Metal completion handlers and the waiter.
      DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + hold) {
        round.record("gate_release")
        round.gate.signal()
      }
      DispatchQueue.global(qos: .userInteractive).async {
        round.record("independent_commit_begin")
        command.commit()
        round.record("independent_commit_return")
        round.record("wait_begin")
        command.waitUntilCompleted()
        round.record("wait_return")
        round.waitDone.signal()
      }
      var observedEvent = false
      var waitFinished = false
      let deadline = ProcessInfo.processInfo.systemUptime + 3
      while ProcessInfo.processInfo.systemUptime < deadline {
        if !observedEvent && event.signaledValue >= 1 {
          round.record("gpu_event_observed")
          observedEvent = true
        }
        if round.waitDone.wait(timeout: .now()) == .success {
          waitFinished = true
          break
        }
        Thread.sleep(forTimeInterval: 0.001)
      }
      XCTAssertTrue(waitFinished, "independent release bounds every injected stall")
      XCTAssertEqual(round.exited.wait(timeout: .now() + 3), .success)
      wait(for: [delivered], timeout: 3)
      round.setValue("independent_gpu_start", command.gpuStartTime)
      round.setValue("independent_gpu_end", command.gpuEndTime)
      let times = round.snapshot()
      round.setValue(
        "gpu_event_observed_while_gate_held",
        (times["gpu_event_observed"] ?? .infinity) < (times["gate_release"] ?? -.infinity) ? 1 : 0)
      round.setValue(
        "independent_wait_returned_while_gate_held",
        (times["wait_return"] ?? .infinity) < (times["gate_release"] ?? -.infinity) ? 1 : 0)
      let receipt = round.snapshot()
      XCTAssertNotNil(receipt["producer_release"])
      if let released = receipt["producer_release"], let entered = receipt["observer_enter"] {
        XCTAssertLessThanOrEqual(released, entered)
      }
      XCTAssertEqual(budget.analysisJobs, 0)
      XCTAssertGreaterThan(budget.retainedBytes, 0)
      receipts.append(receipt)
      state.set(nil)
    }
    let data = try JSONSerialization.data(
      withJSONObject: receipts, options: [.prettyPrinted, .sortedKeys])
    let path = "/Volumes/8TB/cinesomatic-build/monitor-cross-queue-diagnostic.json"
    try data.write(to: URL(fileURLWithPath: path))
    print("Cross-queue diagnostic receipt: \(path)")
    runtime.remove(target: target)
  }

  private func diagnosticProducer(round: CrossQueueDiagnosticRound) throws -> CVPixelBuffer {
    let storage = UnsafeMutableRawPointer.allocate(byteCount: 256 * 32, alignment: 64)
    memset(storage, 0x73, 256 * 32)
    let witness = Unmanaged.passRetained(round).toOpaque()
    var result: CVPixelBuffer?
    let status = CVPixelBufferCreateWithBytes(
      nil, 64, 32, kCVPixelFormatType_32BGRA, storage, 256,
      { refcon, address in
        if let address { UnsafeMutableRawPointer(mutating: address).deallocate() }
        if let refcon {
          Unmanaged<CrossQueueDiagnosticRound>.fromOpaque(refcon).takeRetainedValue().record(
            "producer_release")
        }
      }, witness, nil, &result)
    guard status == kCVReturnSuccess, let result else {
      Unmanaged<CrossQueueDiagnosticRound>.fromOpaque(witness).release()
      storage.deallocate()
      throw XCTSkip("Native producer lifetime fixture unavailable")
    }
    return result
  }
  private final class CrossQueueDiagnosticState: @unchecked Sendable {
    private let lock = NSLock()
    private var round: CrossQueueDiagnosticRound?
    func set(_ value: CrossQueueDiagnosticRound?) {
      lock.lock()
      round = value
      lock.unlock()
    }
    func observe() {
      lock.lock()
      let active = round
      lock.unlock()
      guard let active else { return }
      active.record("observer_enter")
      active.entered.signal()
      _ = active.gate.wait(timeout: .now() + 2)
      active.record("observer_exit")
      active.exited.signal()
    }
  }
  private final class CrossQueueDiagnosticRound: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), exited = DispatchSemaphore(value: 0)
    let gate = DispatchSemaphore(value: 0), waitDone = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var values: [String: Double]
    init(hold: Double) { values = ["requested_hold_seconds": hold] }
    func record(_ key: String) { setValue(key, ProcessInfo.processInfo.systemUptime) }
    func setValue(_ key: String, _ value: Double) {
      lock.lock()
      values[key] = value
      lock.unlock()
    }
    func snapshot() -> [String: Double] {
      lock.lock()
      defer { lock.unlock() }
      return values
    }
  }

  func testCriticalProducerFreshRecoveryAndStaleHandleLifecycle() {
    let registry = MonitorCriticalPipelineRegistry()
    let target = MonitorTargetID("critical-lifecycle")
    var old: MonitorCriticalPipelineProducer? = registry.makeProducer(target: target)
    XCTAssertTrue(
      old!.record(generation: 100, queueAge: 0.04, processingTime: 0, frameInterval: 1 / 30, now: 0)
    )
    XCTAssertEqual(registry.snapshot().phase, .paused)
    let producer = registry.makeProducer(target: target)
    XCTAssertEqual(
      registry.snapshot().phase, .nominal,
      "replacement controller starts a new capture generation epoch")
    XCTAssertTrue(
      producer.record(
        generation: 1, queueAge: 0.04, processingTime: 0, frameInterval: 1 / 30, now: 1))
    XCTAssertFalse(
      old!.record(generation: 101, queueAge: 0, processingTime: 0, frameInterval: 1 / 30, now: 1))
    XCTAssertFalse(old!.stop(generation: 101))
    old = nil
    XCTAssertEqual(registry.snapshot().phase, .paused, "stale deinit cannot remove its replacement")
    XCTAssertFalse(
      producer.record(generation: 0, queueAge: 0, processingTime: 0, frameInterval: 1 / 30, now: 1))
    // Silence cannot count toward the healthy interval.
    XCTAssertTrue(
      producer.record(
        generation: 1, queueAge: 0, processingTime: 0, frameInterval: 1 / 30, now: 100))
    XCTAssertEqual(registry.snapshot().phase, .paused)
    for index in 1...31 {
      XCTAssertTrue(
        producer.record(
          generation: 1, queueAge: 0, processingTime: 0.001,
          frameInterval: 1 / 30, now: 100 + Double(index) / 30))
    }
    XCTAssertEqual(registry.snapshot().phase, .recovering)
    for index in 32...183 {
      XCTAssertTrue(
        producer.record(
          generation: 1, queueAge: 0, processingTime: 0.001,
          frameInterval: 1 / 30, now: 100 + Double(index) / 30))
    }
    XCTAssertEqual(registry.snapshot().phase, .nominal)
    XCTAssertFalse(producer.stop(generation: 0))
    XCTAssertTrue(producer.stop(generation: 1))
    XCTAssertFalse(
      producer.record(
        generation: 1, queueAge: 1, processingTime: 1, frameInterval: 1 / 30, now: 200))
    XCTAssertEqual(registry.snapshot().phase, .nominal, "stopped producers are inactive globally")
    XCTAssertTrue(
      producer.record(
        generation: 2, queueAge: 0.1, processingTime: 0, frameInterval: 1 / 30, now: 201))
    XCTAssertEqual(registry.snapshot().phase, .paused)
  }

  func testCriticalPressureFromHiddenProducerRoutesNewAnalysisToNativeClean() throws {
    let runtime = MonitorRuntime(sharedDevice: {
      XCTFail("paused analysis initialized Metal")
      return nil
    })
    let visible = MonitorTargetID("visible")
    let hidden = MonitorTargetID("hidden-capture")
    var producer: MonitorCriticalPipelineProducer? = runtime.makeCriticalPipelineProducer(
      target: hidden)
    XCTAssertTrue(
      producer!.record(
        generation: 3, queueAge: 0.02, processingTime: 0.02, frameInterval: 1 / 30, now: 1))
    runtime.remove(target: hidden)  // Monitor demand must not unregister a real capture producer.
    var config = MonitorConfiguration()
    config.toolsEnabled = true
    config.zebra.enabled = true
    let expectedConfiguration = config.normalized()
    runtime.configure(
      target: visible, generation: 1, configurationRevision: 1, configuration: config)
    let committed = try XCTUnwrap(
      runtime.ledger.tryAcquire(
        target: MonitorTargetID("already-committed"),
        generation: 1, kind: .analysis, bytes: 4096))
    let before = runtime.ledger.snapshot
    let input = try buffer()
    let inputIdentity = ObjectIdentifier(input)
    let done = expectation(description: "clean continues while critical producer pauses analysis")
    XCTAssertTrue(
      runtime.offer(
        MonitorFrameBundle(
          stamp: MonitorFrameStamp(
            target: visible, generation: 1,
            sequence: 1, sourcePTS: 0, hostTime: 1, configurationRevision: 1), source: input)
      ) { result in
        do {
          let display = try result.get()
          XCTAssertNil(display.decorated)
          XCTAssertNil(display.scope)
          XCTAssertTrue(display.configuration.toolsEnabled)
          XCTAssertEqual(display.configuration, expectedConfiguration)
          XCTAssertTrue(display.availability.contains { $0.contains("output pipeline pressure") })
          XCTAssertNotEqual(ObjectIdentifier(display.clean.pixelBuffer), inputIdentity)
        } catch { XCTFail("\(error)") }
        done.fulfill()
      })
    wait(for: [done], timeout: 3)
    XCTAssertEqual(runtime.ledger.snapshot.analysisJobs, before.analysisJobs)
    XCTAssertGreaterThanOrEqual(runtime.ledger.snapshot.retainedBytes, 4096)
    if case .degraded(let reason) = runtime.diagnostics(for: visible).availability {
      XCTAssertTrue(reason.contains("output pipeline pressure"))
    } else {
      XCTFail("critical pause missing from diagnostics")
    }
    producer = nil
    committed.release()
    runtime.remove(target: visible)
  }

  func testCriticalRecoveringProducerCapsGPUQualityWithoutChangingConfiguration() throws {
    guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
    let runtime = MonitorRuntime()
    let target = MonitorTargetID("critical-recovery-picture")
    let producer = runtime.makeCriticalPipelineProducer(target: target)
    XCTAssertTrue(
      producer.record(
        generation: 1, queueAge: 0.1, processingTime: 0, frameInterval: 1 / 30, now: 0))
    for index in 1...33 {
      XCTAssertTrue(
        producer.record(
          generation: 1, queueAge: 0, processingTime: 0.001,
          frameInterval: 1 / 30, now: Double(index) / 30))
    }
    var config = MonitorConfiguration()
    config.toolsEnabled = true
    config.zebra.enabled = true
    config.scopes.enabled = true
    config.scopes.refreshHz = 30
    let expectedConfiguration = config.normalized()
    runtime.configure(
      target: target, generation: 1, configurationRevision: 1, configuration: config)
    let input = try buffer(width: 1280, height: 960)
    let done = expectation(description: "fresh critical recovery uses reduced actual GPU outputs")
    XCTAssertTrue(
      runtime.offer(
        MonitorFrameBundle(
          stamp: MonitorFrameStamp(
            target: target, generation: 1,
            sequence: 1, sourcePTS: 0, hostTime: 2, configurationRevision: 1), source: input,
          sourceSignal: MonitorFrameSignal(range: .full, matrix: .bt709, transfer: "Rec709"))
      ) { result in
        do {
          let display = try result.get()
          XCTAssertEqual(CVPixelBufferGetHeight(try XCTUnwrap(display.decorated).pixelBuffer), 720)
          XCTAssertEqual(display.scope?.samplingStride, 4)
          XCTAssertEqual(display.configuration, expectedConfiguration)
          XCTAssertTrue(display.availability.contains { $0.contains("recovers") })
        } catch { XCTFail("\(error)") }
        done.fulfill()
      })
    wait(for: [done], timeout: 5)
    XCTAssertEqual(runtime.diagnostics(for: target).effectiveQuality.tier, .reduced)
    producer.stop(generation: 1)
    runtime.remove(target: target)
  }

}
