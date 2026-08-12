// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ControlPanel",
  platforms: [.macOS(.v15)],
  targets: [
    // Objective-C on purpose: drives private CoreBluetooth, and only ObjC can catch the
    // NSExceptions that Apple's implementation raises. See ADListeningMode.h.
    .target(name: "ADBluetooth", path: "Sources/ADBluetooth"),
    .executableTarget(
      name: "ControlPanel", dependencies: ["ADBluetooth"], path: "Sources/ControlPanel")
  ]
)
