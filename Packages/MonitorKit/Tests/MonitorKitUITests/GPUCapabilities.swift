// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Metal
import MonitorKit
import XCTest

/// What the GPU tests need beyond a Metal device, probed once per process. A
/// missing capability skips the test with the reason, so the suite passes on a
/// machine without it (a CI virtual machine's paravirtual GPU, say). A device
/// that has every capability and still fails (a shader that does not compile)
/// fails the test.
enum GPUCapabilities {
  /// Why the default device cannot run the classic GPU tests, or nil: they need
  /// a Metal device, an `MTLResidencySet` (every engine owns one) and a compile
  /// at MonitorKit's Metal Shading Language version.
  static let classicUnavailable: String? = {
    guard let device = MTLCreateSystemDefaultDevice() else { return "No Metal device" }
    do {
      _ = try device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
    } catch {
      return "\(device.name) cannot make an MTLResidencySet: \(error)"
    }
    let options = MonitorShaders.compileOptions
    do {
      _ = try device.makeLibrary(source: probeKernel, options: options)
    } catch {
      return "\(device.name) cannot compile Metal Shading Language (MTLLanguageVersion \(options.languageVersion.rawValue)): \(error)"
    }
    return nil
  }()

  /// Why the default device cannot run the Metal 4 tests, or nil: they need
  /// `MTLGPUFamily.metal4`, an `MTL4CommandQueue` and an `MTL4Compiler`.
  /// `MONITORKIT_TEST_NO_METAL4=1` reports Metal 4 as missing, to run the suite
  /// as on a device without it.
  static let metal4Unavailable: String? = {
    if let reason = GPUCapabilities.classicUnavailable { return reason }
    if ProcessInfo.processInfo.environment["MONITORKIT_TEST_NO_METAL4"] == "1" {
      return "MONITORKIT_TEST_NO_METAL4=1: running as on a device without Metal 4"
    }
    guard let device = MTLCreateSystemDefaultDevice() else { return "No Metal device" }
    guard device.supportsFamily(.metal4) else { return "\(device.name) does not support MTLGPUFamily.metal4" }
    guard device.makeMTL4CommandQueue() != nil else { return "\(device.name) cannot make an MTL4CommandQueue" }
    do {
      _ = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
    } catch {
      return "\(device.name) cannot make an MTL4Compiler: \(error)"
    }
    return nil
  }()

  /// False under `MONITORKIT_CI=1` (set by the CI workflow): a CI virtual
  /// machine's GPU and CPU timings say nothing about MonitorKit, so timing
  /// budgets are not checked there. Pixel and correctness checks still run.
  static var timingBudgetsApply: Bool { ProcessInfo.processInfo.environment["MONITORKIT_CI"] != "1" }

  static let probeKernel = "kernel void mk_capability_probe(device uint* out [[buffer(0)]]) { out[0] = 1u; }"
}

/// Skips unless the default device can run the classic GPU tests.
func requireClassicGPU() throws {
  if let reason = GPUCapabilities.classicUnavailable { throw XCTSkip(reason) }
}

/// Skips unless the default device can run the Metal 4 tests.
func requireMetal4() throws {
  if let reason = GPUCapabilities.metal4Unavailable { throw XCTSkip(reason) }
}

/// Timing budgets mean nothing under Metal's API or shader validation, which
/// slows encoding and every shader several times, or on a CI virtual machine
/// (`MONITORKIT_CI=1`); the benchmark classes skip.
func skipUnrepresentativeTiming() throws {
  let env = ProcessInfo.processInfo.environment
  if !GPUCapabilities.timingBudgetsApply {
    throw XCTSkip("MONITORKIT_CI=1: timing budgets are not checked on a CI virtual machine")
  }
  for name in ["MTL_DEBUG_LAYER", "MTL_SHADER_VALIDATION"] where env[name].map({ $0 != "0" }) ?? false {
    throw XCTSkip("\(name) is set: GPU and CPU timings are not representative")
  }
}
