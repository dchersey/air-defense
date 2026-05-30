// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "AncProbe",
  platforms: [.macOS(.v14)],
  targets: [
    .executableTarget(name: "AncProbe", path: "Sources/AncProbe")
  ]
)
