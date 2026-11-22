// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "ProgramAV1",
  platforms: [.macOS(.v14)],
  products: [.library(name: "ProgramAV1", targets: ["ProgramAV1"])],
  dependencies: [
    .package(url: "https://github.com/HaishinKit/libaom-xcframework.git", exact: "3.15.3")
  ],
  targets: [
    .target(name: "CProgramAV1", dependencies: [.product(name: "libaom", package: "libaom-xcframework")]),
    .target(name: "ProgramAV1", dependencies: ["CProgramAV1"]),
    .testTarget(name: "ProgramAV1Tests", dependencies: ["ProgramAV1", .product(name: "libaom", package: "libaom-xcframework")])
  ]
)
