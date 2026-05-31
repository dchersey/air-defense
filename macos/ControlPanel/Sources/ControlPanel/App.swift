import AppKit
import SwiftUI

@main
struct ControlPanelApp: App {
  @State private var model = StatusModel()

  var body: some Scene {
    MenuBarExtra {
      PanelView(model: model)
    } label: {
      // A SwiftUI Image in the menu bar is rendered as a TEMPLATE (monochrome) and
      // ignores .foregroundStyle, so amber/red wouldn't show. Render an explicit
      // non-template, palette-tinted NSImage instead.
      Image(nsImage: menuImage)
    }
    .menuBarExtraStyle(.window)
  }

  private var menuImage: NSImage {
    switch model.phase {
    case .offline: return symbol("airplane.slash", tint: nil)
    case .disconnected: return symbol("headphones", tint: .systemGray)
    case .engaged: return symbol("airpodsmax", tint: .systemRed)
    case .pending: return symbol("airplane.circle.fill", tint: .systemOrange)
    case .idle: return symbol(model.active ? "airplane.circle.fill" : "airplane", tint: nil)
    }
  }

  /// Build a menu-bar symbol image. `tint == nil` -> a template image that adapts
  /// to the menu bar (the normal monochrome look); a tint -> a non-template image
  /// drawn in that colour (amber/red), which the menu bar renders as-is.
  private func symbol(_ name: String, tint: NSColor?) -> NSImage {
    let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()

    guard let tint else {
      base.isTemplate = true
      return base
    }

    let config = NSImage.SymbolConfiguration(paletteColors: [tint])
    let img = base.withSymbolConfiguration(config) ?? base
    img.isTemplate = false
    return img
  }
}
