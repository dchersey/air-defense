import AppKit

struct PassiveRouteIcon {
  enum Fill: CaseIterable { case neutral, low, high, river, direct }
  let fill: Fill
  let departures: Bool

  @MainActor init(model: StatusModel, now: Int = Int(Date().timeIntervalSince1970)) {
    let fresh = model.routePolledAt.map { (0...90).contains(now - $0) } ?? false
    switch fresh ? model.route : nil {
    case "low approach": fill = .low
    case "high approach": fill = .high
    case "river approach": fill = .river
    case "direct approach": fill = .direct
    default: fill = .neutral
    }
    departures = (model.departurePolledAt.map { (0...30).contains(now - $0) } ?? false)
      && (model.departure?.confirmedRoutes?.contains("south_then_east")
        ?? (model.departure?.track == "south → east"))
  }

  init(fill: Fill, departures: Bool) { self.fill = fill; self.departures = departures }

  var image: NSImage {
    let tint: NSColor
    switch fill {
    case .neutral: tint = .labelColor
    case .low: tint = NSColor(srgbRed: 1, green: 0.74, blue: 0.22, alpha: 1)
    case .high: tint = NSColor(srgbRed: 0.39, green: 0.67, blue: 1, alpha: 1)
    case .river: tint = NSColor(srgbRed: 0x4A/255.0, green: 0x9A/255.0, blue: 0x78/255.0, alpha: 1)
    case .direct: tint = NSColor(srgbRed: 0x7B/255.0, green: 0x6C/255.0, blue: 0xAE/255.0, alpha: 1)
    }
    let base = NSImage(systemSymbolName: "airplane", accessibilityDescription: "\(fill) approach\(departures ? ", noisy departures" : "")") ?? NSImage()
    let weight = NSImage.SymbolConfiguration(pointSize: 14, weight: .bold)
    if fill == .neutral && !departures {
      base.isTemplate = true
      return base
    }
    func colored(_ color: NSColor) -> NSImage {
      let image = base.withSymbolConfiguration(weight.applying(NSImage.SymbolConfiguration(paletteColors: [color]))) ?? base
      image.isTemplate = false
      return image
    }
    let face = colored(tint)
    guard departures else { return face }
    let edge = colored(.yellow)
    let size = NSSize(width: face.size.width + 2, height: face.size.height + 2)
    let result = NSImage(size: size, flipped: false) { _ in
      // Expand the glyph's silhouette, then paint the route-colored face over it.
      for step in 0..<16 {
        let angle = Double(step) * .pi / 8
        edge.draw(at: NSPoint(x: 1 + cos(angle) * 0.85, y: 1 + sin(angle) * 0.85),
                  from: .zero, operation: .sourceOver, fraction: 1)
      }
      face.draw(at: NSPoint(x: 1, y: 1), from: .zero, operation: .sourceOver, fraction: 1)
      return true
    }
    result.isTemplate = false
    return result
  }
}
