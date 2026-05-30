// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ControlPanel",
  platforms: [.macOS(.v15)],
  targets: [
    .executableTarget(name: "ControlPanel", path: "Sources/ControlPanel")
  ]
)
