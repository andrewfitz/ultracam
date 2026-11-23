// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "HaishinKitRTMP",
  platforms: [.macOS(.v12)],
  products: [.library(name: "RTMPHaishinKit", targets: ["RTMPHaishinKit"])],
  dependencies: [.package(url: "https://github.com/shogo4405/Logboard.git", exact: "2.6.0")],
  targets: [
    .target(name: "HaishinKit", dependencies: ["Logboard"],
      swiftSettings: [.enableUpcomingFeature("ExistentialAny")]),
    .target(name: "RTMPHaishinKit", dependencies: ["HaishinKit"],
      exclude: ["RTMP/RTMPStream_Mac-Studio.local_Nov-22-122617-2026_Conflict.swift"],
      swiftSettings: [.enableUpcomingFeature("ExistentialAny")]),
    .testTarget(name: "RTMPHaishinKitTests", dependencies: ["RTMPHaishinKit"])
  ])
