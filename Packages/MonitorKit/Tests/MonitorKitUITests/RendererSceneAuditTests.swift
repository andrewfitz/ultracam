// Copyright 2026 Andrew Fitzgerald
// SPDX-License-Identifier: Apache-2.0

import Metal
import MonitorKit
import MonitorKitCore
import MonitorKitScopes
import XCTest

@testable import MonitorKitUI

final class RendererSceneAuditTests: XCTestCase {
  func testChangingScopeCadenceSplitsAndRejoinsFusedGroups() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    source.submit(try gpu.sdrFrame())
    let fast = MonitorScopeOverlay(source: source, settings: ScopeSettings(kind: .histogram))
    let slow = MonitorScopeOverlay(source: source, settings: ScopeSettings(kind: .waveform))
    let renderer = MonitorRenderer(
      engine: gpu.engine, scene: MonitorScene(scopes: [fast, slow]), scopeEngine: try gpu.scopeEngine())
    let target = gpu.texture(.bgra8Unorm, 64, 36)
    func draw() throws {
      try renderer.update()
      try gpu.run { try renderer.encode(target: target, into: $0) }
    }
    try draw()
    XCTAssertTrue(renderer.scopeGroup(for: fast) === renderer.scopeGroup(for: slow))
    slow.accumulationInterval = 3600
    try draw()
    XCTAssertFalse(renderer.scopeGroup(for: fast) === renderer.scopeGroup(for: slow))
    let slowGeneration = try XCTUnwrap(renderer.accumulator(for: slow)).generation
    let fastGeneration = try XCTUnwrap(renderer.accumulator(for: fast)).generation
    source.submit(try gpu.sdrFrame(seed: 1))
    try draw()
    XCTAssertEqual(renderer.accumulator(for: slow)?.generation, slowGeneration)
    XCTAssertNotEqual(renderer.accumulator(for: fast)?.generation, fastGeneration)
    slow.accumulationInterval = 0
    try draw()
    XCTAssertTrue(renderer.scopeGroup(for: fast) === renderer.scopeGroup(for: slow))
  }

  func testCleanSceneStopsVisibleMemberOfPreviouslyFusedGroup() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    source.submit(try gpu.sdrFrame())
    let visible = MonitorScopeOverlay(source: source, settings: ScopeSettings(kind: .histogram))
    let hidden = MonitorScopeOverlay(source: source, settings: ScopeSettings(kind: .waveform), isHidden: true)
    let scene = MonitorScene(scopes: [visible, hidden])
    let renderer = MonitorRenderer(engine: gpu.engine, scene: scene, scopeEngine: try gpu.scopeEngine())
    let target = gpu.texture(.bgra8Unorm, 64, 36)
    func draw() throws {
      try renderer.update()
      try gpu.run { try renderer.encode(target: target, into: $0) }
    }
    try draw()
    XCTAssertTrue(renderer.scopeGroup(for: visible) === renderer.scopeGroup(for: hidden))
    let stopped = try XCTUnwrap(renderer.accumulator(for: visible)).generation
    let measuring = try XCTUnwrap(renderer.accumulator(for: hidden)).generation
    scene.clean = true
    source.submit(try gpu.sdrFrame(seed: 1))
    try draw()
    XCTAssertEqual(renderer.accumulator(for: visible)?.generation, stopped)
    XCTAssertNotEqual(renderer.accumulator(for: hidden)?.generation, measuring)
    XCTAssertFalse(renderer.scopeGroup(for: visible) === renderer.scopeGroup(for: hidden))
    scene.clean = false
    try draw()
    XCTAssertNotEqual(renderer.accumulator(for: visible)?.generation, stopped)
    XCTAssertTrue(renderer.scopeGroup(for: visible) === renderer.scopeGroup(for: hidden))
  }

  func testClearedSourcePublishesEmptySurfaceGeometryAndStatus() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    source.submit(try gpu.sdrFrame())
    var state = MonitorState()
    state.focus.enabled = true
    let surface = MonitorSurface(source: source, state: state)
    let renderer = MonitorRenderer(engine: gpu.engine, scene: MonitorScene(surfaces: [surface]))
    let target = gpu.texture(.bgra8Unorm, 64, 36)
    try renderer.update()
    try gpu.run { try renderer.encode(target: target, into: $0) }
    XCTAssertNotNil(surface.layout)
    XCTAssertTrue(surface.status.isActive(.focusPeaking))
    _ = renderer.takeStatusChanges()
    source.clear()
    try renderer.update()
    try gpu.run { try renderer.encode(target: target, into: $0) }
    XCTAssertNil(surface.layout)
    XCTAssertNil(surface.viewport)
    XCTAssertEqual(surface.status, MonitorStatus())
    XCTAssertTrue(renderer.takeStatusChanges())
    source.submit(try gpu.sdrFrame(seed: 2))
    try renderer.update()
    try gpu.run { try renderer.encode(target: target, into: $0) }
    XCTAssertNotNil(surface.layout)
    XCTAssertTrue(surface.status.isActive(.focusPeaking))
  }

  func testHiddenScopeClearsPublishedViewportAndRestoresIt() throws {
    let gpu = try requireGPU()
    let source = MonitorSource()
    source.submit(try gpu.sdrFrame())
    let overlay = MonitorScopeOverlay(source: source, settings: ScopeSettings(kind: .histogram))
    let renderer = MonitorRenderer(
      engine: gpu.engine, scene: MonitorScene(scopes: [overlay]), scopeEngine: try gpu.scopeEngine())
    let target = gpu.texture(.bgra8Unorm, 64, 36)
    func draw() throws {
      try renderer.update()
      try gpu.run { try renderer.encode(target: target, into: $0) }
    }
    try draw()
    XCTAssertNotNil(overlay.viewport)
    overlay.isHidden = true
    try draw()
    XCTAssertNil(overlay.viewport)
    overlay.isHidden = false
    try draw()
    XCTAssertNotNil(overlay.viewport)
  }
}
