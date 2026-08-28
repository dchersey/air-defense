import AppKit
import SwiftUI

@main
struct ControlPanelApp: App {
  @State private var model = StatusModel()

  var body: some Scene {
    MenuBarExtra {
      PanelView(model: model)
    } label: {
      // A SwiftUI Image in the menu bar renders as a TEMPLATE (monochrome) and
      // ignores .foregroundStyle, so to show color (green monitoring / amber / red)
      // we hand it explicit non-template, palette-tinted NSImages.
      if isMonitoring {
        // Actively scanning the sky: the radar mark (same glyph as the in-app
        // header), tinted green and softly pulsing via model.menuPulse (timer-
        // driven alpha — .symbolEffect renders static in status items).
        Image(nsImage: monitoringImage)
      } else {
        Image(nsImage: menuImage)
      }
    }
    .menuBarExtraStyle(.window)
  }

  // Session running and nothing inbound/engaged → the steady "monitoring" state.
  // Requires a live feed: with the feed down we are NOT monitoring, we're blind, and the
  // calm green mark would claim otherwise. It must also exclude a provider fallback for
  // the same reason — this branch is checked BEFORE menuImage, so without the guard the
  // green mark wins and the fallback icon below is unreachable dead code.
  private var isMonitoring: Bool {
    model.active && model.phase == .idle && model.feedOk && !isFallenBack
  }

  // Session running but the data feed is unreachable — we can't see traffic at all.
  // Only trust this when the backend itself is reachable; a dead backend is `.offline`.
  private var isBlind: Bool { model.active && model.reachable && !model.feedOk }

  // Running on a provider we did NOT configure, because the configured one failed and
  // the poller fell back. The feed is healthy again, so every other signal reads normal
  // and the calm green mark would say "all fine" while a metered fallback quietly spends
  // credits — and with a cancelled plan those credits are a finite reserve that never
  // refills. Same failure shape as isBlind: true-looking icon, untrue situation.
  private var isFallenBack: Bool {
    guard model.active, let live = model.providerActive else { return false }
    return live != model.provider
  }

  // Vivid radar-green, brighter than systemGreen so it reads on the menu bar.
  private let monitorGreen = NSColor(srgbRed: 0.30, green: 0.88, blue: 0.44, alpha: 1)
  // Bright amber-gold for the "locked-on" inbound mark (luminous so it reads).
  private let lockedOnAmber = NSColor(srgbRed: 1.0, green: 0.74, blue: 0.22, alpha: 1)

  // Bold green radar mark at the current pulse alpha (reading model.menuPulse
  // re-renders the label each timer tick → the soft pulse).
  private var monitoringImage: NSImage {
    symbol(
      "dot.radiowaves.up.forward", tint: monitorGreen, alpha: CGFloat(model.menuPulse), bold: true)
  }

  // AirPods Pro gets its own glyph; Max/other keep the over-ear icons.
  private var earpieceEngaged: String { model.headphonesArePro ? "airpodspro" : "airpodsmax" }
  private var earpieceDisconnected: String { model.headphonesArePro ? "airpodspro" : "headphones" }

  private var menuImage: NSImage {
    // Blind takes priority over every phase below: the session is up and the timer is
    // running, but no traffic can be seen, so nothing else the icon could say is true.
    if isBlind {
      return symbol("antenna.radiowaves.left.and.right.slash", tint: lockedOnAmber, bold: true)
    }
    // Below blind, above the phases. Deliberately NOT the radar mark in amber: that is
    // exactly what .pending (inbound, locked on) draws, and two meanings sharing one
    // icon is worse than no indicator. Use the same swap glyph the panel banner uses
    // for a failover, so the menu bar and the panel speak the same language.
    // Only replaces the idle/monitoring mark — an actual inbound or engaged flight is
    // more urgent than which feed it arrived on, so those phases still win.
    if isFallenBack, model.phase == .idle {
      return symbol("arrow.triangle.2.circlepath", tint: lockedOnAmber, bold: true)
    }
    switch model.phase {
    case .offline: return symbol("airplane.slash", tint: nil)
    case .disconnected: return symbol(earpieceDisconnected, tint: .systemGray)
    case .engaged: return symbol(earpieceEngaged, tint: .systemRed)
    // Inbound = "locked on": the radar mark in bold amber, static (no pulse).
    case .pending: return symbol("dot.radiowaves.up.forward", tint: lockedOnAmber, bold: true)
    // No session. Amber when low traffic has crossed the zone in the last 10 minutes:
    // ANC is off and the sky says you would want it on. Plain template glyph otherwise.
    case .idle:
      return symbol("airplane", tint: model.ambient ? lockedOnAmber : nil, bold: model.ambient)
    }
  }

  /// Build a menu-bar symbol image. `tint == nil` -> a template image that adapts
  /// to the menu bar (the normal monochrome look); a tint -> a non-template image
  /// drawn in that colour (green/amber/red). `alpha` < 1 redraws it semi-transparent
  /// for the monitoring pulse.
  private func symbol(_ name: String, tint: NSColor?, alpha: CGFloat = 1, bold: Bool = false)
    -> NSImage
  {
    let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()

    guard let tint else {
      base.isTemplate = true
      return base
    }

    // Merge color + (optional) heavier weight & larger size into one config so a
    // thin glyph like the radar mark reads boldly in the menu bar.
    var config = NSImage.SymbolConfiguration(paletteColors: [tint])
    if bold {
      config = config.applying(NSImage.SymbolConfiguration(pointSize: 14, weight: .bold))
    }
    let img = base.withSymbolConfiguration(config) ?? base
    img.isTemplate = false

    guard alpha < 1 else { return img }
    let faded = NSImage(size: img.size)
    faded.lockFocus()
    img.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: max(0.05, alpha))
    faded.unlockFocus()
    faded.isTemplate = false
    return faded
  }
}
