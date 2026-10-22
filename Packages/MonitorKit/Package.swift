// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
  name: "MonitorKit",
  platforms: [.macOS(.v26), .iOS(.v26)],
  products: [
    .library(name: "MonitorKitCore", targets: ["MonitorKitCore"]),
    .library(name: "MonitorKit", targets: ["MonitorKit"]),
    .library(name: "MonitorKitScopes", targets: ["MonitorKitScopes"]),
    .library(name: "MonitorKitAudio", targets: ["MonitorKitAudio"]),
    .library(name: "MonitorKitUI", targets: ["MonitorKitUI"]),
  ],
  targets: [
    // Pure Swift: settings, signal descriptions, geometry, LUT parsing and the
    // CPU reference math that the GPU results are tested against.
    .target(name: "MonitorKitCore", swiftSettings: strict),
    // Metal picture pass, LUTs and focus analysis. Encodes into the host's
    // command buffers. Shaders are text resources compiled at runtime, so no
    // Metal toolchain is needed to build.
    .target(
      name: "MonitorKit", dependencies: ["MonitorKitCore"],
      resources: [.copy("Shaders")], swiftSettings: strict),
    // Waveform, vectorscope and histogram on the GPU.
    .target(
      name: "MonitorKitScopes", dependencies: ["MonitorKit", "MonitorKitCore"],
      resources: [.copy("Shaders")], swiftSettings: strict),
    // Audio meters and loudness. Pure Swift + Accelerate, no GPU.
    .target(name: "MonitorKitAudio", swiftSettings: strict),
    // CAMetalLayer view, SwiftUI controls, legends and meters.
    .target(
      name: "MonitorKitUI",
      dependencies: ["MonitorKit", "MonitorKitCore", "MonitorKitScopes", "MonitorKitAudio"],
      swiftSettings: strict),
    .testTarget(name: "MonitorKitCoreTests", dependencies: ["MonitorKitCore"]),
    .testTarget(name: "MonitorKitTests", dependencies: ["MonitorKit", "MonitorKitCore"]),
    .testTarget(
      name: "MonitorKitScopesTests",
      dependencies: ["MonitorKitScopes", "MonitorKit", "MonitorKitCore"]),
    .testTarget(name: "MonitorKitAudioTests", dependencies: ["MonitorKitAudio"]),
    .testTarget(
      name: "MonitorKitUITests",
      dependencies: [
        "MonitorKitUI", "MonitorKit", "MonitorKitCore", "MonitorKitScopes", "MonitorKitAudio",
      ]),
  ],
  swiftLanguageModes: [.v6]
)
