// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "MonitorTools",
  platforms: [.macOS("26.0")],
  products: [
    .library(name: "MonitorToolsCore", type: .static, targets: ["MonitorToolsCore"]),
    .library(name: "MonitorToolsMetal", type: .static, targets: ["MonitorToolsMetal"]),
    .library(name: "MonitorToolsUI", type: .static, targets: ["MonitorToolsUI"]),
  ],
  targets: [
    .target(
      name: "MonitorToolsCore", swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
    .target(
      name: "MonitorToolsMetal", dependencies: ["MonitorToolsCore"],
      resources: [.process("Resources")],
      swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
    .target(
      name: "MonitorToolsUI", dependencies: ["MonitorToolsCore", "MonitorToolsMetal"],
      swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
    .testTarget(name: "MonitorToolsCoreTests", dependencies: ["MonitorToolsCore"]),
    .testTarget(
      name: "MonitorToolsMetalTests", dependencies: ["MonitorToolsCore", "MonitorToolsMetal"]),
    .testTarget(
      name: "MonitorToolsUITests",
      dependencies: ["MonitorToolsUI", "MonitorToolsMetal", "MonitorToolsCore"]),
  ],
  swiftLanguageVersions: [.v5]
)
