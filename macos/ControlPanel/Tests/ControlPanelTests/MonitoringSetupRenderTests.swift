import AppKit
import SwiftUI
import Testing
@testable import ControlPanel

struct MonitoringSetupRenderTests {
  @MainActor @Test func setupFitsPanel() throws {
    let model = StatusModel(startMonitoring: false)
    let view = MonitoringSetup(model: model).padding(15).frame(width: 340)
      .background(Palette.gradient).fixedSize(horizontal: false, vertical: true)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    let image = try #require(renderer.cgImage)
    #expect(image.width == 680)
    #expect(image.height < 1240)
    if let directory = ProcessInfo.processInfo.environment["ROUTE_HISTORY_PREVIEW_DIR"] {
      let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
      try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("monitoring-setup.png"))
    }
  }
}
