import AppKit
import Testing
@testable import ControlPanel

struct PassiveRouteIconTests {
  @MainActor @Test func freshRoutesAndDepartureOutline() {
    let m = StatusModel(startMonitoring: false)
    m.routePolledAt = 1000
    for (route, expected) in [("low approach", PassiveRouteIcon.Fill.low), ("high approach", .high),
                               ("river approach", .river), ("direct approach", .direct), ("no route detected", .neutral)] {
      m.route = route
      #expect(PassiveRouteIcon(model: m, now: 1030).fill == expected)
    }
    m.route = "low approach"
    m.ambient = true
    #expect(PassiveRouteIcon(model: m, now: 1091).fill == .neutral)
    #expect(PassiveRouteIcon(model: m, now: 999).fill == .neutral)
    m.departure = DepartureSummary(confirmedRoutes: ["south_then_east"], track: "north → west", count: 3, closestNm: 1, closestAltFt: 2000, callsign: nil)
    m.departurePolledAt = 1000
    #expect(PassiveRouteIcon(model: m, now: 1030).departures)
    #expect(!PassiveRouteIcon(model: m, now: 1031).departures)
    m.departure?.confirmedRoutes = ["north_then_west"]
    #expect(!PassiveRouteIcon(model: m, now: 1000).departures)
  }

  @MainActor @Test func renderAllVariants() throws {
    let output = ProcessInfo.processInfo.environment["ICON_PREVIEW"]
    let canvas = NSImage(size: NSSize(width: 220, height: 64))
    canvas.lockFocus()
    NSColor.darkGray.setFill(); NSRect(x: 0, y: 0, width: 220, height: 64).fill()
    for (index, fill) in PassiveRouteIcon.Fill.allCases.enumerated() {
      for (row, outlined) in [false, true].enumerated() {
        let icon = PassiveRouteIcon(fill: fill, departures: outlined).image
        #expect(icon.size.width > 0)
        #expect(icon.isTemplate == (fill == .neutral && !outlined))
        icon.draw(at: NSPoint(x: index * 44 + 8, y: row * 32 + 8), from: .zero, operation: .sourceOver, fraction: 1)
      }
    }
    canvas.unlockFocus()
    if let output {
      let rep = try #require(canvas.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
      try #require(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
    }
  }
}
