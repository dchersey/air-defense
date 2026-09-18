import AppKit
import SwiftUI
import Testing
@testable import ControlPanel

struct RouteHistoryRenderTests {
  @MainActor @Test func renderPopulatedAndEmptyHistory() throws {
    let model = StatusModel(startMonitoring: false)
    model.reachable = true
    let now = Date()
    let routes = ["low_approach", "high_approach", "river_approach"]
    let days = RouteTimeline.days(now: now)
    var spans: [RouteInterval] = []
    for (index, day) in days.enumerated() {
      for block in 0..<4 {
        let start = day.addingTimeInterval(Double(block * 6 + 1) * 3600)
        let end = min(now, start.addingTimeInterval(Double(3 + index % 3) * 3600))
        if end > start {
          spans.append(RouteInterval(route: routes[(index + block) % 3],
                                     startAt: Int(start.timeIntervalSince1970),
                                     endAt: Int(end.timeIntervalSince1970)))
        }
      }
    }
    let seconds = routes.map { route in
      spans.filter { $0.route == route }.reduce(0) { $0 + $1.endAt - $1.startAt }
    }
    let total = seconds.reduce(0, +)
    let shares = routes.enumerated().map { i, route in
      RouteShare(route: route, seconds: seconds[i], percent: Double(seconds[i]) * 100 / Double(total))
    }
    let data = RouteHistoryResponse(asOf: Int(now.timeIntervalSince1970),
      windowStart: Int(now.timeIntervalSince1970) - 30 * 86400, intervals: spans,
      shares: shares, classifiedSeconds: total, windowSeconds: 30 * 86400)
    for variant in ["light", "dark", "empty"] {
      model.routeHistory = variant == "empty"
        ? RouteHistoryResponse(asOf: data.asOf, windowStart: data.windowStart, intervals: [],
                               shares: [], classifiedSeconds: 0, windowSeconds: data.windowSeconds)
        : data
      let view = RouteHistoryView(model: model, onBack: {})
        .padding(15).frame(width: 340).background(Palette.gradient)
        .environment(\.colorScheme, variant == "dark" ? .dark : .light)
        .fixedSize(horizontal: false, vertical: true)
      let renderer = ImageRenderer(content: view)
      renderer.scale = 2
      let image = try #require(renderer.cgImage)
      #expect(image.width == 680)
      #expect(image.height > 800 && image.height < 1400)
      if let directory = ProcessInfo.processInfo.environment["ROUTE_HISTORY_PREVIEW_DIR"] {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("routes-\(variant).png"))
      }
    }
  }
}
