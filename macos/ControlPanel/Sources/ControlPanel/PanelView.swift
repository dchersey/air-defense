import AppKit
import SwiftUI

// MARK: - Design tokens (dark "Radar Console" + light "Live Map")

extension NSColor {
  /// 0xRRGGBB literal + optional alpha.
  convenience init(hex: UInt, alpha: CGFloat = 1) {
    self.init(
      srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
      green: CGFloat((hex >> 8) & 0xff) / 255,
      blue: CGFloat(hex & 0xff) / 255,
      alpha: alpha)
  }
}

extension Color {
  /// 0xRRGGBB literal + optional alpha.
  init(hex: UInt, alpha: Double = 1) {
    self.init(
      .sRGB,
      red: Double((hex >> 16) & 0xff) / 255,
      green: Double((hex >> 8) & 0xff) / 255,
      blue: Double(hex & 0xff) / 255,
      opacity: alpha)
  }

  /// A color that resolves to `light` or `dark` per the current appearance — the
  /// asset-catalog-free equivalent of a Color Set (this app has no .xcassets, and
  /// `swift build` doesn't compile one).
  static func dynamic(light: NSColor, dark: NSColor) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
      })
  }

  /// Same, taking hex literals: `.theme(light: 0x.., dark: 0x..)`.
  static func theme(light: UInt, dark: UInt, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1)
    -> Color
  {
    dynamic(light: NSColor(hex: light, alpha: lightAlpha), dark: NSColor(hex: dark, alpha: darkAlpha))
  }

  /// Lift brightness (HSB) — for the top-lit gradient on "on" surfaces. Resolves in
  /// the current appearance, so it tracks light/dark.
  func lighten(_ amount: Double) -> Color {
    let ns = (NSColor(self).usingColorSpace(.sRGB)) ?? .gray
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    return Color(hue: h, saturation: s, brightness: min(b + amount, 1), opacity: a)
  }
}

enum Palette {
  // Light = "Live Map" (warm sage ground, highway blue / park green / amber).
  // Dark  = "Radar Console" (navy ground, cyan / green / amber).
  static let panelTop = Color.theme(light: 0xEAEADF, dark: 0x173351)
  static let panelBottom = Color.theme(light: 0xDCE0D1, dark: 0x0C1B2A)
  static let ink = Color.theme(light: 0x2E312B, dark: 0xEAF2F8)
  static let ink2 = Color.theme(light: 0x2E312B, dark: 0xEAF2F8, lightAlpha: 0.62, darkAlpha: 0.60)
  static let ink3 = Color.theme(light: 0x2E312B, dark: 0xEAF2F8, lightAlpha: 0.42, darkAlpha: 0.38)
  static let hairline = Color.theme(light: 0x2E312B, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.09)
  static let line = Color.theme(light: 0x2E312B, dark: 0xFFFFFF, lightAlpha: 0.14, darkAlpha: 0.055)
  static let fill = Color.theme(light: 0x2E312B, dark: 0xFFFFFF, lightAlpha: 0.075, darkAlpha: 0.08)
  static let accent = Color.theme(light: 0x3F7CC4, dark: 0x3AD6C8)
  static let accentSoft = Color.theme(light: 0x3F7CC4, dark: 0x3AD6C8, lightAlpha: 0.14, darkAlpha: 0.16)
  static let inbound = Color.theme(light: 0xE0961A, dark: 0xFFB648)
  static let inboundSoft = Color.theme(light: 0xE0961A, dark: 0xFFB648, lightAlpha: 0.16, darkAlpha: 0.16)
  static let go = Color.theme(light: 0x5D9150, dark: 0x5BE37A)
  static let goSoft = Color.theme(light: 0x5D9150, dark: 0x5BE37A, lightAlpha: 0.16, darkAlpha: 0.16)
  static let stop = Color.theme(light: 0xD05641, dark: 0xFF6F6B)
  static let stopSoft = Color.theme(light: 0xD05641, dark: 0xFF6F6B, lightAlpha: 0.16, darkAlpha: 0.16)
  // Text on an accent fill: white on the light blue Start button, dark on cyan.
  static let onAccent = Color.theme(light: 0xFFFFFF, dark: 0x04221E)

  // Subtle ~168° diagonal so the whole surface reads less flat.
  static let gradient = LinearGradient(
    colors: [panelTop, panelBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension Font {
  static let adTitle = Font.system(.subheadline, design: .monospaced).weight(.semibold)
  static let adScreen = Font.system(.callout, design: .monospaced).weight(.semibold)
  static let adZone = Font.system(.callout, design: .monospaced)
  static let adMono = Font.system(.caption2, design: .monospaced)
}

/// A small status indicator. `glow` makes it a "live" dot: core + soft outer glow +
/// a translucent ring. Kept fully static — `MenuBarExtra(.window)` tears when a
/// `repeatForever` animation runs inside it, so no ping/blink. `pulse` is retained
/// for call-site compatibility but no longer animates.
private struct StatusDot: View {
  var color: Color
  var glow = false
  var pulse = false

  var body: some View {
    Circle()
      .fill(color)
      .frame(width: 9, height: 9)
      .shadow(color: glow ? color.opacity(0.9) : .clear, radius: glow ? 5 : 0)
      .overlay {
        if glow {
          Circle().stroke(color.opacity(0.35), lineWidth: 3).frame(width: 9, height: 9)
        }
      }
  }
}

/// Pill buttons. `lit` = primary action (Start/Create): a top-lit gradient + 1px
/// white top highlight + soft drop shadow. Flat (default) = secondary action
/// (Stop): a `fill` surface with a hairline `line` ring.
private struct PillButton: ButtonStyle {
  let bg: Color
  let fg: Color
  var lit = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.caption.weight(.semibold))
      .lineLimit(1)
      .fixedSize()
      .foregroundStyle(fg)
      .padding(.horizontal, 13)
      .frame(height: 28)
      .background(background)
      .opacity(configuration.isPressed ? 0.85 : 1)
  }

  @ViewBuilder private var background: some View {
    let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
    if lit {
      shape
        .fill(LinearGradient(colors: [bg.lighten(0.10), bg], startPoint: .top, endPoint: .bottom))
        .overlay(
          shape
            .stroke(.white.opacity(0.28), lineWidth: 1)
            .blendMode(.plusLighter)
            .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center)))
        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
    } else {
      shape.fill(bg).overlay(shape.stroke(Palette.line, lineWidth: 1))
    }
  }
}

/// Small chip buttons in the zone editor.
private struct ChipButton: ButtonStyle {
  var filled = false
  var disabled = false
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.adMono)
      .foregroundStyle(disabled ? Palette.ink3 : (filled ? Palette.accent : Palette.ink2))
      .padding(.horizontal, 10)
      .frame(height: 26)
      .background(
        RoundedRectangle(cornerRadius: 7)
          .fill(filled ? Palette.accentSoft : Palette.fill)
          .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.line, lineWidth: 1)))
      .opacity(configuration.isPressed ? 0.8 : 1)
  }
}

private func sectionLabel(_ text: String) -> some View {
  Text(text.uppercased())
    .font(.adMono)
    .tracking(0.9)
    .foregroundStyle(Palette.ink3)
}

// MARK: - Root

struct PanelView: View {
  let model: StatusModel
  @State private var showSettings = false
  @State private var showEditor = false

  var body: some View {
    content
      .padding(15)
      .frame(width: 340)
      .background(Palette.gradient)
      .tint(Palette.accent)
      .overlay(alignment: .bottom) {
        if let toast = model.toast {
          Text(toast)
            .font(.adMono)
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(Palette.panelBottom.opacity(0.96)))
            .overlay(Capsule().stroke(Palette.line, lineWidth: 1))
            .padding(.bottom, 14)
            .transition(.opacity)
        }
      }
      .animation(.easeInOut(duration: 0.2), value: model.toast)
      // MenuBarExtra(.window) keeps this view alive across open/close, so navigation
      // state would otherwise persist. Reset to the main page when the panel closes
      // (the window resigns key and orders out) so it always reopens on the main view.
      .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
        showSettings = false
        showEditor = false
      }
  }

  @ViewBuilder private var content: some View {
    if showEditor {
      ZoneEditorScreen(model: model, onSettings: { showEditor = false; showSettings = true })
        { showEditor = false }
    } else if showSettings {
      SettingsScreen(model: model, onEditZones: { showSettings = false; showEditor = true })
        { showSettings = false }
    } else {
      mainScreen
    }
  }

  // MARK: Main

  private var mainScreen: some View {
    VStack(alignment: .leading, spacing: 13) {
      Header(model: model)
      StatusBanner(model: model)
      watchZones
      ActivityStrip(model: model)
      Divider().overlay(Palette.hairline)
      footer
    }
  }

  private var watchZones: some View {
    VStack(alignment: .leading, spacing: 0) {
      sectionLabel("Watch zones · LGA")
        .padding(.bottom, 4)

      if !model.reachable {
        Text("service offline").font(.adMono).foregroundStyle(Palette.ink3).padding(.vertical, 8)
      } else if model.zonesets.isEmpty {
        Text("no zones configured").font(.adMono).foregroundStyle(Palette.ink3).padding(.vertical, 8)
      } else {
        ForEach(Array(model.zonesets.enumerated()), id: \.element.id) { index, zone in
          if index > 0 { Rectangle().fill(Palette.hairline).frame(height: 1) }
          ZoneRow(model: model, zone: zone)
        }
      }
    }
  }

  private var footer: some View {
    HStack(spacing: 4) {
      FooterButton(title: "Settings", icon: "gearshape") { showSettings = true }
      FooterButton(title: "Edit zones", icon: "map") { showEditor = true }
      Spacer()
      FooterButton(title: "Quit", icon: "power", hoverTint: Palette.stop) {
        NSApplication.shared.terminate(nil)
      }
    }
  }
}

// MARK: - Header

private struct Header: View {
  let model: StatusModel

  var body: some View {
    HStack(alignment: .top, spacing: 11) {
      // Clickable: opens FlightRadar24 over the ANC zone (default browser). The
      // thicker ring is the affordance.
      Button { model.openFlightRadar() } label: {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(Palette.accentSoft)
          .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
              .stroke(Palette.accent.opacity(0.7), lineWidth: 1.5))
          .frame(width: 30, height: 30)
          .overlay(
            Image(systemName: "dot.radiowaves.up.forward")
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(Palette.accent))
      }
      .buttonStyle(.plain)
      .help("Open FlightRadar24 over your ANC zone")
      .onHover { inside in
        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
      }

      VStack(alignment: .leading, spacing: 4) {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text("AIR DEFENSE")
            .font(.adTitle).tracking(0.4)
            .foregroundStyle(Palette.ink)
          Spacer(minLength: 8)
          ModeBadge(model: model)
        }
        statusLine.lineLimit(1)
      }
    }
  }

  private var statusLine: some View {
    let credits = " · ~\(model.approxCredits) cr"
    let line: Text
    if !model.reachable {
      line = Text("service offline").foregroundStyle(Palette.ink2)
    } else if model.active && !model.headphonesConnected {
      line = Text("paused · ").foregroundStyle(Palette.ink2)
        + Text("\(countdown(model.sessionEndsAt)) left").foregroundStyle(Palette.inbound)
        + Text(credits).foregroundStyle(Palette.ink2)
    } else if model.active {
      line = Text("monitoring · ").foregroundStyle(Palette.ink2)
        + Text("\(countdown(model.sessionEndsAt)) left").foregroundStyle(Palette.ink)
        + Text(credits).foregroundStyle(Palette.ink2)
    } else {
      line = Text("standby · ready").foregroundStyle(Palette.ink2)
        + Text(credits).foregroundStyle(Palette.ink2)
    }
    return line.font(.adMono).monospacedDigit()
  }
}

private struct ModeBadge: View {
  let model: StatusModel

  var body: some View {
    let paused = model.active && !model.headphonesConnected
    let (text, color, soft, pulse): (String, Color, Color, Bool) =
      paused
      ? ("ANC Off", Palette.ink3, Palette.line, false)
      : model.mode == "anc"
        ? ("Noise Cancellation", Palette.accent, Palette.accentSoft, true)
        : ("Transparency", Palette.go, Palette.goSoft, false)

    return HStack(spacing: 6) {
      StatusDot(color: color, pulse: pulse)
        .frame(width: 6, height: 6)
      Text(text.uppercased())
        .font(.system(.caption2, design: .monospaced).weight(.semibold))
        .tracking(0.5)
        .foregroundStyle(color)
        .lineLimit(1)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(Capsule().fill(soft))
    .overlay(Capsule().stroke(color.opacity(0.42), lineWidth: 0.5))
    .fixedSize()
  }
}

// MARK: - Status banner

private struct StatusBanner: View {
  let model: StatusModel

  var body: some View {
    // A dead data feed takes priority — we're blind, not quiet. Only trust it when the
    // backend itself is reachable (a down backend is handled by .offline in the switch).
    if model.active && model.reachable && !model.feedOk {
      banner(
        icon: "antenna.radiowaves.left.and.right.slash", tint: Palette.inbound,
        bg: Palette.inboundSoft, strong: "Feed unreachable.",
        rest: " Can't see traffic — monitoring paused until the data feed recovers.")
    } else {
      bannerForPhase
    }
  }

  @ViewBuilder private var bannerForPhase: some View {
    switch model.phase {
    case .disconnected:
      banner(
        icon: "headphones", tint: Palette.inbound, bg: Palette.inboundSoft,
        strong: "AirPods not connected", rest: " — monitoring paused. Timer still running.")
    case .pending:
      // The countdown is wall-clock-driven, so re-render it on a 1 s timeline rather
      // than relying on model refreshes — while ANC is engaged the zoneset locks on
      // and stops polling, so the model goes static and a refresh-driven countdown
      // would freeze (the amber phase only churns because it's fast-polling).
      TimelineView(.periodic(from: .now, by: 1)) { _ in
        let route = model.inboundRoute ?? "LGA traffic"
        let eta =
          model.inboundAt.map { " Cancellation engages in \(mmss($0))." }
          ?? " Cancellation arming."
        banner(
          icon: "bolt.fill", tint: Palette.inbound, bg: Palette.inboundSoft,
          strong: "Inbound — \(route) on vector.", rest: eta)
      }
    case .engaged:
      // Overhead now (ANC on, red). Arrivals show a clear-by countdown; departures
      // are live-tracked (no reliable exit prediction) → a radar mark instead. Same
      // 1 s timeline so the clear-by countdown ticks down through the lock-on hold.
      TimelineView(.periodic(from: .now, by: 1)) { _ in
        let route = model.overheadRoute ?? "LGA traffic"
        if let at = model.overheadAt {
          banner(
            icon: "headphones", tint: Palette.stop, bg: Palette.stopSoft,
            strong: "Overhead — \(route).", rest: " Clears in \(mmss(at)).")
        } else {
          banner(
            icon: "dot.radiowaves.up.forward", tint: Palette.stop, bg: Palette.stopSoft,
            strong: "Overhead — \(route).", rest: " Live-tracking until it clears.")
        }
      }
    default:
      EmptyView()
    }
  }

  private func banner(icon: String, tint: Color, bg: Color, strong: String, rest: String)
    -> some View
  {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: icon).font(.caption).foregroundStyle(tint)
      (Text(strong).font(.caption.weight(.semibold)) + Text(rest).font(.caption))
        .foregroundStyle(tint)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 11)
    .padding(.vertical, 9)
    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(bg))
    .overlay(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .stroke(tint.opacity(0.30), lineWidth: 0.5))
  }
}

// MARK: - Watch-zone row

private struct ZoneRow: View {
  let model: StatusModel
  let zone: ZonesetStatus

  // Effective per-zone phase: the backend's phase, but a global headphones-
  // disconnect overrides it to "paused".
  private var phase: String {
    if zone.active && model.phase == .disconnected { return "paused" }
    return zone.phase ?? (zone.active ? "monitoring" : "idle")
  }

  var body: some View {
    let dotColor: Color = {
      switch phase {
      case "idle": return Palette.ink3
      case "armed", "paused": return Palette.inbound
      default: return Palette.accent  // monitoring / engaged
      }
    }()
    let (name, qualifier) = splitName(zone.name)

    HStack(spacing: 11) {
      // Live zones glow (amber when armed/intercepting); idle and paused stay flat.
      StatusDot(color: dotColor, glow: zone.active && phase != "paused")

      VStack(alignment: .leading, spacing: 2) {
        (Text(name).foregroundStyle(Palette.ink)
          + Text(qualifier.map { " \($0)" } ?? "").foregroundStyle(Palette.ink2))
          .font(.adZone)
        stateLine
      }

      Spacer(minLength: 6)

      if zone.active {
        Button { model.stop(zone.id) } label: { Label("Stop", systemImage: "stop.fill") }
          .buttonStyle(PillButton(bg: Palette.fill, fg: Palette.ink))
      } else {
        Button { model.start(zone.id) } label: { Label("Start 4h", systemImage: "play.fill") }
          .buttonStyle(PillButton(bg: Palette.accent, fg: Palette.onAccent, lit: true))
      }
    }
    .padding(.vertical, 11)
  }

  private var stateLine: some View {
    // "armed · intercept 0:42 · 2 inbound", "monitoring · 3h 37m left", etc.
    let text: Text =
      switch phase {
      case "armed":
        Text("armed · ").foregroundStyle(Palette.inbound)
          + (zone.interceptAt.map {
            Text("intercept \(mmss($0)) · ").foregroundStyle(Palette.inbound)
          } ?? Text(""))
          + Text("\(zone.inbound ?? 0) inbound").foregroundStyle(Palette.ink2)
      case "engaged":
        Text("engaged · overhead").foregroundStyle(Palette.accent)
      case "paused":
        Text("paused · ").foregroundStyle(Palette.ink2)
          + Text("\(countdown(zone.endsAt)) left").foregroundStyle(Palette.inbound)
      case "idle":
        Text("idle").foregroundStyle(Palette.ink3)
      default:  // monitoring
        Text("monitoring · ").foregroundStyle(Palette.ink2)
          + Text("\(countdown(zone.endsAt)) left").foregroundStyle(Palette.accent)
      }
    return text.font(.adMono).monospacedDigit()
  }

  /// "Departures (banking)" -> ("Departures", "(banking)").
  private func splitName(_ name: String) -> (String, String?) {
    guard name.hasSuffix(")"), let open = name.range(of: " (") else { return (name, nil) }
    return (String(name[..<open.lowerBound]), String(name[open.lowerBound...]).trimmingCharacters(in: .whitespaces))
  }
}

// MARK: - Activity strip + recent flights

private struct ActivityStrip: View {
  let model: StatusModel
  @State private var showFlights = false
  @State private var hoveredBar: Int?
  @State private var hoveredFlightID: String?

  var body: some View {
    if model.reachable {
      VStack(alignment: .leading, spacing: 9) {
        HStack {
          sectionLabel("Overflights")
          Spacer()
          (Text("\(model.history.reduce(0, +))").foregroundStyle(Palette.ink)
            + Text(" · last hr · 5-min").foregroundStyle(Palette.ink3))
            .font(.adMono).monospacedDigit()
        }

        bars

        if !model.recent.isEmpty {
          Button { withAnimation(.easeInOut(duration: 0.18)) { showFlights.toggle() } } label: {
            HStack(spacing: 4) {
              Image(systemName: showFlights ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
              Text("Recent flights").font(.adMono)
            }
            .foregroundStyle(Palette.ink3)
          }
          .buttonStyle(.plain)

          if showFlights { flightList }
        }
      }
    }
  }

  // One drawn bar: its original history bucket index (for hover/time mapping) + count.
  private struct ChartBucket { let index: Int; let value: Int }

  // Drop buckets that were entirely headphones-off (not monitoring) so the chart shows
  // no empty gap, and mark where a removed span exceeded 5 min so a separator is drawn
  // between the surrounding bars. Buckets with detections are always kept.
  private func displayedBuckets() -> (bars: [ChartBucket], separatorsAfter: Set<Int>) {
    let n = model.history.count
    guard n > 0 else { return ([], []) }
    let now = Date().timeIntervalSince1970
    var bars: [ChartBucket] = []
    var seps: Set<Int> = []
    var removed: TimeInterval = 0

    for i in 0..<n {
      let end = now - Double(n - 1 - i) * 300
      let start = end - 300
      let value = model.history[i]
      let paused = model.pausedOverlap(start: start, end: end)

      if value == 0 && paused >= 150 {  // mostly not monitoring, nothing to show → drop
        removed += paused
        continue
      }
      // A >5-min removed span between two kept bars gets a separator (never leading).
      if removed > 300 && !bars.isEmpty { seps.insert(bars.count - 1) }
      removed = 0
      bars.append(ChartBucket(index: i, value: value))
    }
    return (bars, seps)
  }

  private var bars: some View {
    let (buckets, seps) = displayedBuckets()
    let maxV = max(buckets.map(\.value).max() ?? 1, 1)
    let count = max(buckets.count, 1)
    return HStack(alignment: .bottom, spacing: 4) {
      if buckets.isEmpty {
        Color.clear
      } else {
        ForEach(Array(buckets.enumerated()), id: \.offset) { _, b in
          let hot = b.index == model.history.count - 1 && model.phase == .pending
          // The bar sits at the bottom of a full-height, transparent column so the
          // whole 5-min slot is a hover target (empty bars are only a 6 pt stub).
          ZStack(alignment: .bottom) {
            Color.clear
            RoundedRectangle(cornerRadius: 2, style: .continuous)
              .fill(barFill(value: b.value, hot: hot))
              .frame(height: b.value == 0 ? 6 : max(10, 56 * Double(b.value) / Double(maxV)))
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .contentShape(Rectangle())
          .onHover { inside in
            if inside { hoveredBar = b.index } else if hoveredBar == b.index { hoveredBar = nil }
          }
        }
      }
    }
    .frame(height: 56, alignment: .bottom)
    // Vertical separators at the boundaries where a >5-min headphones-off span was
    // compacted out (zero layout impact so the bars stay uniform width).
    .overlay { separators(seps, count: count) }
    // Floating hovertip (a real .help() tooltip doesn't fire inside MenuBarExtra's
    // window), anchored over the hovered bar, clamped to the chart width.
    .overlay { hoverCard(buckets) }
  }

  @ViewBuilder private func separators(_ seps: Set<Int>, count: Int) -> some View {
    if !seps.isEmpty {
      GeometryReader { geo in
        ForEach(Array(seps), id: \.self) { k in
          Rectangle()
            .fill(Palette.ink3.opacity(0.55))
            .frame(width: 1)
            .position(x: geo.size.width * CGFloat(k + 1) / CGFloat(count), y: geo.size.height / 2)
        }
      }
    }
  }

  @ViewBuilder private func hoverCard(_ buckets: [ChartBucket]) -> some View {
    if let h = hoveredBar, let ord = buckets.firstIndex(where: { $0.index == h }) {
      GeometryReader { geo in
        let flights = bucketFlights(h)
        let shown = Array(flights.prefix(8))
        let cardW: CGFloat = 196
        let cardH = CGFloat(max(shown.count, 1)) * 16 + 16
        let n = max(buckets.count, 1)
        let center = geo.size.width * (CGFloat(ord) + 0.5) / CGFloat(n)
        let x = min(max(center, cardW / 2), geo.size.width - cardW / 2)
        tooltipCard(flights, shown: shown)
          .frame(width: cardW, alignment: .leading)
          .position(x: x, y: -cardH / 2 - 6)
      }
      .allowsHitTesting(false)
    }
  }

  private func tooltipCard(_ flights: [Flight], shown: [Flight]) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      if shown.isEmpty {
        Text("No overflights").font(.adMono).foregroundStyle(Palette.ink3)
      } else {
        ForEach(shown) { f in
          (Text(ancTime(f)).foregroundStyle(Palette.accent)
            + Text("  ").font(.adMono)
            + Text(routeLabel(f)).foregroundStyle(Palette.ink))
            .font(.adMono).monospacedDigit().lineLimit(1)
        }
        if flights.count > shown.count {
          Text("+\(flights.count - shown.count) more").font(.adMono).foregroundStyle(Palette.ink3)
        }
      }
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 7)
    .background(
      RoundedRectangle(cornerRadius: 7, style: .continuous)
        .fill(Palette.panelTop)
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Palette.line, lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
    )
  }

  // Flights whose detection time falls in bar `index`'s 5-min window (the bars are
  // 12 buckets, oldest→newest, the newest ending ~now), most recent first.
  private func bucketFlights(_ index: Int) -> [Flight] {
    let now = Date().timeIntervalSince1970
    let bucketsFromNewest = Double(model.history.count - 1 - index)
    let end = now - bucketsFromNewest * 300
    let start = end - 300
    return model.recent
      .filter { Double($0.at) >= start && Double($0.at) < end }
      .sorted { $0.at > $1.at }
  }

  // Idle = faint flat stub; active = top-lit gradient fading to 45% at the base;
  // the current 5-min bucket turns amber ("hot") while a plane is inbound.
  private func barFill(value: Int, hot: Bool) -> LinearGradient {
    if value == 0 {
      return LinearGradient(colors: [Palette.fill, Palette.fill], startPoint: .top, endPoint: .bottom)
    }
    let c = hot ? Palette.inbound : Palette.accent
    return LinearGradient(colors: [c, c.opacity(0.45)], startPoint: .top, endPoint: .bottom)
  }

  // Plain VStack (no ScrollView — a greedy ScrollView collapses to ~0 height in the
  // content-sized MenuBarExtra window). Each row: flight id + the time ANC engaged
  // (≈ detection time + lead-to-zone-entry). The release is a fixed dwell, so it's
  // omitted.
  private var flightList: some View {
    VStack(alignment: .leading, spacing: 5) {
      ForEach(model.recent.prefix(10)) { flight in
        HStack(spacing: 8) {
          Text(routeLabel(flight)).font(.adMono).foregroundStyle(Palette.ink)
          if let type = flight.type, !type.isEmpty {
            Text("· \(type)").font(.adMono).foregroundStyle(Palette.ink2)
          }
          if let alt = flight.altFt {
            Text("· \(Int(alt)) ft").font(.adMono).foregroundStyle(Palette.ink3)
          }
          Spacer(minLength: 8)
          Text(ancTime(flight)).font(.adMono).monospacedDigit().foregroundStyle(Palette.accent)
            .frame(width: 92, alignment: .trailing)
        }
        .contentShape(Rectangle())
        // Only SET on enter; clearing is handled once at the list level (below) so
        // moving between rows never blips through the empty/hint state.
        .onHover { inside in if inside { hoveredFlightID = flight.id } }
      }

      // Hover detail: the full aircraft name for the hovered row — a real .help()
      // tooltip doesn't fire inside MenuBarExtra's window, so we mirror the chart's
      // hover pattern. Reserved one-line height so the rows above never shift.
      Text(hoverDetail)
        .font(.adMono)
        .foregroundStyle(hoveredAircraftName == nil ? Palette.ink3 : Palette.ink2)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 1)
    }
    .padding(.top, 2)
    // Clear only when the cursor leaves the whole list — debounces the row-to-row
    // hand-off (per-row exits would otherwise flash back to the hint between rows).
    .contentShape(Rectangle())
    .onHover { inside in if !inside { hoveredFlightID = nil } }
  }

  // Full name ("Boeing 737-800") for the hovered row's type code, or nil if the row
  // has no/unknown type or nothing is hovered.
  private var hoveredAircraftName: String? {
    guard let id = hoveredFlightID,
      let type = model.recent.first(where: { $0.id == id })?.type, !type.isEmpty
    else { return nil }
    return AircraftTypes.name(for: type)
  }

  // The hover line: "B738 — Boeing 737-800" when known, else a faint affordance.
  private var hoverDetail: String {
    guard let id = hoveredFlightID,
      let type = model.recent.first(where: { $0.id == id })?.type, !type.isEmpty,
      let name = AircraftTypes.name(for: type)
    else { return "hover a type code for the aircraft model" }
    return "\(type) — \(name)"
  }

  // Clock time ANC engaged for this flight: detection time + predicted lead to the
  // ANC zone (the engage offset/latency shift it by a second or two).
  private func ancTime(_ flight: Flight) -> String {
    Date(timeIntervalSince1970: TimeInterval(flight.at + flight.entersIn))
      .formatted(date: .omitted, time: .standard)
  }

  // Airport route when known (e.g. "YYZ → LGA"); "private" for GA/no-route flights;
  // the raw callsign while the lookup is still pending.
  private func routeLabel(_ flight: Flight) -> String {
    if let o = flight.origin, let d = flight.destination { return "\(o) → \(d)" }
    if flight.isPrivate == true { return "private" }
    return flight.callsign ?? "—"
  }
}

// MARK: - Footer button

private struct FooterButton: View {
  let title: String
  let icon: String
  var hoverTint: Color = Palette.ink
  let action: () -> Void
  @State private var hover = false

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: icon)
        .font(.caption)
        .foregroundStyle(hover ? hoverTint : Palette.ink2)
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 9)
    .padding(.vertical, 6)
    .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Color.white.opacity(0.04) : .clear))
    .onHover { hover = $0 }
  }
}

/// Back-chevron screen header used by Settings and the zone editor.
private struct ScreenHeader: View {
  let title: String
  let onBack: () -> Void

  var body: some View {
    Button(action: onBack) {
      HStack(spacing: 7) {
        Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
        Text(title).font(.adScreen)
      }
      .foregroundStyle(Palette.ink)
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Settings

private struct SettingsScreen: View {
  let model: StatusModel
  let onEditZones: () -> Void
  let onBack: () -> Void

  @State private var launchAtLogin = LoginItem.isEnabled
  @AppStorage("autoPauseWithoutAirPods") private var autoPause = true
  @AppStorage("quietAlertEnabled") private var quietAlert = true

  init(model: StatusModel, onEditZones: @escaping () -> Void, _ onBack: @escaping () -> Void) {
    self.model = model
    self.onEditZones = onEditZones
    self.onBack = onBack
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      ScreenHeader(title: "Settings", onBack: onBack)
      Divider().overlay(Palette.hairline)

      TimingOffsets(model: model)
      Divider().overlay(Palette.hairline)

      toggleRow(
        "Auto-pause without AirPods", subtitle: "Hold monitoring when no buds are connected",
        isOn: $autoPause)
      toggleRow(
        "Quiet-period alert", subtitle: "Play a message after 10 min with no flights",
        isOn: $quietAlert)
      toggleRow(
        "Launch at Login", subtitle: "Start Air Defense when you sign in", isOn: $launchAtLogin
      )
      .onChange(of: launchAtLogin) { _, newValue in launchAtLogin = LoginItem.setEnabled(newValue) }

      Divider().overlay(Palette.hairline)
      DataSource(model: model)
      if model.provider == "fr24" {
        CreditBar(used: model.creditsUsedMonth, budget: model.creditsBudgetMonth, model: model)
      }

      Divider().overlay(Palette.hairline)
      RouteSource(model: model)

      Divider().overlay(Palette.hairline)
      HStack(spacing: 4) {
        FooterButton(title: "Edit zones", icon: "map", action: onEditZones)
        Spacer()
        FooterButton(title: "Quit", icon: "power", hoverTint: Palette.stop) {
          NSApplication.shared.terminate(nil)
        }
      }
    }
  }

  private func toggleRow(_ title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.callout.weight(.medium)).foregroundStyle(Palette.ink)
        Text(subtitle).font(.adMono).foregroundStyle(Palette.ink2)
      }
      Spacer()
      Toggle("", isOn: isOn).labelsHidden().toggleStyle(.switch).tint(Palette.go)
    }
  }
}

// MARK: - ANC timing offsets

/// Two sliders that nudge the computed ANC engage/release times (±15s). The
/// service's ETA estimate is unchanged; these are added on top. Persists on
/// slider release.
private struct TimingOffsets: View {
  let model: StatusModel
  @State private var engage: Double
  @State private var release: Double

  init(model: StatusModel) {
    self.model = model
    _engage = State(initialValue: model.engageDelta)
    _release = State(initialValue: model.releaseDelta)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("ANC timing offset", systemImage: "bolt.fill")
        .font(.callout.weight(.semibold)).foregroundStyle(Palette.ink)
      Text(
        "Lead the engage so cancellation is already on as the jet crosses your zone; lag the release so you don't surface into the tail of the roar."
      )
      .font(.adMono).foregroundStyle(Palette.ink2)
      .fixedSize(horizontal: false, vertical: true)

      offsetRow("Engage", value: $engage, tint: Palette.accent)
      offsetRow("Release", value: $release, tint: Palette.inbound)
    }
  }

  private func offsetRow(_ label: String, value: Binding<Double>, tint: Color) -> some View {
    HStack(spacing: 8) {
      Text(label).font(.adMono).foregroundStyle(Palette.ink2)
        .frame(width: 52, alignment: .leading)
      Slider(value: value, in: -15...15, step: 1) { editing in
        if !editing { model.setAncOffsets(engage: engage, release: release) }
      }
      .tint(tint)
      Text(format(value.wrappedValue)).font(.adMono).monospacedDigit().foregroundStyle(tint)
        .frame(width: 38, alignment: .trailing)
    }
  }

  private func format(_ v: Double) -> String {
    let n = Int(v)
    return n > 0 ? "+\(n)s" : "\(n)s"
  }
}

// MARK: - Data source

/// Choose the flight-data provider for all zones. The free ADS-B feeds need no
/// key; FlightRadar24 needs an API key (entered here → stored in the Keychain).
private struct DataSource: View {
  let model: StatusModel
  @State private var keyText = ""

  private let providers = [
    ("airplanes_live", "airplanes.live (free)"),
    ("fr24", "FlightRadar24 (API key)"),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        sectionLabel("Data source")
        Spacer()
        Picker("", selection: Binding(get: { model.provider }, set: { model.setProvider($0) })) {
          ForEach(providers, id: \.0) { Text($0.1).tag($0.0) }
        }
        .labelsHidden().pickerStyle(.menu).fixedSize()
      }

      if model.provider == "fr24" {
        HStack(spacing: 6) {
          Image(systemName: model.fr24KeyPresent ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
            .font(.adMono).foregroundStyle(model.fr24KeyPresent ? Palette.go : Palette.inbound)
          SecureField(model.fr24KeyPresent ? "Replace API key…" : "Paste FR24 API key", text: $keyText)
            .textFieldStyle(.roundedBorder).font(.adMono)
          Button("Save") {
            let k = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !k.isEmpty { model.setFR24Key(k); keyText = "" }
          }
          .font(.adMono).disabled(keyText.isEmpty)
        }
        Text("Billed per flight; keep monitor zones small.").font(.adMono).foregroundStyle(Palette.ink2)
      } else {
        Text("Free ADS-B — no API key, no credits used.").font(.adMono).foregroundStyle(Palette.ink2)
      }
    }
  }
}

// MARK: - Flight-route source

/// FlightAware AeroAPI key for real-time airport routes in the recent-flights list
/// (stored in the Keychain by the backend). Independent of the position provider.
/// Without a key — or once the monthly query cap is hit — the list shows the raw
/// callsign instead of "ORIG → DEST".
private struct RouteSource: View {
  let model: StatusModel
  @State private var keyText = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      sectionLabel("Flight routes")
      HStack(spacing: 6) {
        Image(
          systemName: model.aeroapiKeyPresent
            ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
        )
        .font(.adMono).foregroundStyle(model.aeroapiKeyPresent ? Palette.go : Palette.inbound)
        SecureField(
          model.aeroapiKeyPresent ? "Replace AeroAPI key…" : "Paste FlightAware AeroAPI key",
          text: $keyText
        )
        .textFieldStyle(.roundedBorder).font(.adMono)
        Button("Save") {
          let k = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
          if !k.isEmpty {
            model.setAeroapiKey(k)
            keyText = ""
          }
        }
        .font(.adMono).disabled(keyText.isEmpty)
      }
      Text(
        model.aeroapiKeyPresent
          ? "Real-time routes via FlightAware (cached; ~1,200 lookups/mo)."
          : "Add a key for ORIG → DEST routes; otherwise the list shows the callsign."
      )
      .font(.adMono).foregroundStyle(Palette.ink2)
    }
  }
}

// MARK: - FR24 credit pace bar

/// Monthly FR24 credit usage as a pace bar: remaining fills from the right, a
/// hashmark marks how far through the cycle we are. On/under pace = green,
/// running ahead = amber.
private struct CreditBar: View {
  let used: Int?
  let budget: Int
  let model: StatusModel

  @State private var syncing = false
  @State private var remainingText = ""
  @State private var resetDayText = ""

  var body: some View {
    let usedFrac = min(1, max(0, Double(used ?? 0) / Double(max(budget, 1))))
    let remainFrac = 1 - usedFrac
    let elapsed = cycleElapsed(resetDay: model.billingResetDay)
    let onPace = usedFrac <= elapsed

    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(cycleLabel(resetDay: model.billingResetDay)).font(.adMono).foregroundStyle(Palette.ink2)
        Spacer()
        if let used {
          Text("\(remaining(used).formatted()) left").font(.adMono).monospacedDigit()
            .foregroundStyle(Palette.ink)
        }
        Text(used == nil ? "—" : "\(used!.formatted()) / \(budget.formatted())")
          .font(.adMono).monospacedDigit().foregroundStyle(Palette.ink2)
        Button(syncing ? "Cancel" : "Sync") { syncing.toggle() }
          .buttonStyle(.plain).font(.adMono).foregroundStyle(Palette.accent)
      }

      GeometryReader { geo in
        let w = geo.size.width
        ZStack(alignment: .leading) {
          Capsule().fill(Palette.fill)
          Capsule().fill(onPace ? Palette.go : Palette.inbound)
            .frame(width: w * remainFrac)
            .frame(maxWidth: .infinity, alignment: .trailing)
          Rectangle().fill(Palette.ink.opacity(0.75))
            .frame(width: 1.5)
            .offset(x: w * elapsed)
        }
      }
      .frame(height: 8)

      if syncing { syncForm }
    }
  }

  private var syncForm: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Text("Resets on day").font(.adMono).foregroundStyle(Palette.ink2)
        TextField("1–31", text: $resetDayText)
          .textFieldStyle(.roundedBorder).font(.adMono).monospacedDigit().frame(width: 44)
          .onSubmit(applyResetDay)
        Text("of each month").font(.adMono).foregroundStyle(Palette.ink2)
      }
      HStack(spacing: 6) {
        Text("FR24 remaining:").font(.adMono).foregroundStyle(Palette.ink2)
        TextField("e.g. 54239", text: $remainingText)
          .textFieldStyle(.roundedBorder).font(.adMono).monospacedDigit().frame(width: 80)
        Button("Set") {
          applyResetDay()
          if let n = Int(remainingText.filter(\.isNumber)) { model.seedCredits(remaining: n) }
          syncing = false
          remainingText = ""
        }
        .font(.adMono)
      }
    }
    .onAppear { resetDayText = String(model.billingResetDay) }
  }

  private func applyResetDay() {
    if let d = Int(resetDayText.filter(\.isNumber)), (1...31).contains(d), d != model.billingResetDay {
      model.setBillingResetDay(d)
    }
  }

  private func remaining(_ used: Int) -> Int { max(budget - used, 0) }

  private func cycleLabel(resetDay: Int) -> String {
    resetDay == 1 ? "Credits this month" : "Credits this cycle"
  }

  /// Fraction of the current billing cycle elapsed (mirrors CreditLedger.cycle_start).
  private func cycleElapsed(resetDay: Int) -> Double {
    let cal = Calendar.current
    let now = Date()
    let start = cycleStart(now, resetDay: resetDay, cal: cal)
    guard let end = cal.date(byAdding: .month, value: 1, to: start) else { return 0 }
    let span = end.timeIntervalSince(start)
    guard span > 0 else { return 0 }
    return min(1, max(0, now.timeIntervalSince(start) / span))
  }

  private func cycleStart(_ date: Date, resetDay: Int, cal: Calendar) -> Date {
    let day = cal.component(.day, from: date)
    let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? date
    let daysInMonth = cal.range(of: .day, in: .month, for: date)?.count ?? 30
    let anchor = min(resetDay, daysInMonth)
    if day >= anchor {
      return cal.date(byAdding: .day, value: anchor - 1, to: monthStart) ?? monthStart
    } else {
      let prevMonth = cal.date(byAdding: .month, value: -1, to: monthStart) ?? monthStart
      let prevDays = cal.range(of: .day, in: .month, for: prevMonth)?.count ?? 30
      return cal.date(byAdding: .day, value: min(resetDay, prevDays) - 1, to: prevMonth) ?? prevMonth
    }
  }
}

// MARK: - Zone editor

private struct ZoneEditorScreen: View {
  let model: StatusModel
  let onSettings: () -> Void
  let onBack: () -> Void

  init(model: StatusModel, onSettings: @escaping () -> Void, _ onBack: @escaping () -> Void) {
    self.model = model
    self.onSettings = onSettings
    self.onBack = onBack
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ScreenHeader(title: "Done · Watch zones", onBack: onBack)
      Divider().overlay(Palette.hairline)

      if let err = model.editError {
        Text(err).font(.adMono).foregroundStyle(Palette.stop)
          .fixedSize(horizontal: false, vertical: true)
      }

      ForEach(Array(model.editZones.enumerated()), id: \.element.id) { index, zone in
        if index > 0 { Rectangle().fill(Palette.hairline).frame(height: 1) }
        ZoneEditRow(zone: zone, model: model)
      }

      Divider().overlay(Palette.hairline)
      AddZoneForm(model: model)

      Divider().overlay(Palette.hairline)
      HStack(spacing: 4) {
        FooterButton(title: "Settings", icon: "gearshape", action: onSettings)
        Spacer()
        FooterButton(title: "Quit", icon: "power", hoverTint: Palette.stop) {
          NSApplication.shared.terminate(nil)
        }
      }
    }
    // Load on appear so the list is fresh regardless of how we got here
    // (main dashboard or Settings → Edit zones).
    .task { await model.loadZones() }
  }
}

/// One editable zoneset: rename (on submit), set/open each zone's GeoJSON, poll
/// cadence, delete.
private struct ZoneEditRow: View {
  let zone: EditableZone
  let model: StatusModel
  @State private var name: String
  @State private var pollSeconds: String
  @State private var zoneType: String
  @State private var engageDelta: String
  @State private var releaseDelta: String
  @FocusState private var focus: Field?

  private enum Field { case name, poll, engage, release }

  init(zone: EditableZone, model: StatusModel) {
    self.zone = zone
    self.model = model
    _name = State(initialValue: zone.name)
    _pollSeconds = State(initialValue: zone.pollIntervalMs.map { String($0 / 1000) } ?? "")
    _zoneType = State(initialValue: zone.type ?? "arrival")
    _engageDelta = State(initialValue: zone.engageDeltaSeconds.map { String(Int($0)) } ?? "")
    _releaseDelta = State(initialValue: zone.releaseDeltaSeconds.map { String(Int($0)) } ?? "")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 9) {
        StatusDot(
          color: model.zonesets.first { $0.id == zone.id }?.active == true
            ? Palette.accent : Palette.ink3,
          glow: model.zonesets.first { $0.id == zone.id }?.active == true)
        TextField("name", text: $name)
          .textFieldStyle(.roundedBorder).font(.adZone)
          .focused($focus, equals: .name)
          .onSubmit { commitName() }
        Button(role: .destructive) {
          Task { await model.deleteZone(zone.id) }
        } label: {
          Image(systemName: "trash").foregroundStyle(Palette.ink2)
        }
        .buttonStyle(.plain)
      }

      slotRow("Monitor", geojson: zone.monitorGeojson, slot: .monitor)
      slotRow("ANC", geojson: zone.ancGeojson, slot: .anc)

      HStack(spacing: 6) {
        sectionLabel("Type").frame(width: 56, alignment: .leading)
        Picker(
          "",
          selection: Binding(
            get: { zoneType },
            set: { newValue in
              zoneType = newValue
              Task { await model.setZoneType(zone.id, type: newValue) }
            })
        ) {
          Text("Arrival").tag("arrival")
          Text("Departure").tag("departure")
        }
        .labelsHidden().pickerStyle(.menu).fixedSize()
        Spacer(minLength: 0)
      }

      HStack(spacing: 6) {
        sectionLabel("Poll")
        Text("every").font(.adMono).foregroundStyle(Palette.ink2)
        TextField("default", text: $pollSeconds)
          .textFieldStyle(.roundedBorder).font(.adMono).monospacedDigit().frame(width: 50)
          .focused($focus, equals: .poll)
          .onSubmit { commitPoll() }
        Text("s").font(.adMono).foregroundStyle(Palette.ink2)
        Text("blank = global").font(.adMono).foregroundStyle(Palette.ink3)
      }

      // Per-zone ANC timing offsets — calibrate arrival vs departure independently
      // (negative engage = fire earlier). Blank uses the global Settings offset.
      HStack(spacing: 6) {
        sectionLabel("Offset").frame(width: 56, alignment: .leading)
        Text("eng").font(.adMono).foregroundStyle(Palette.ink2)
        TextField("0", text: $engageDelta)
          .textFieldStyle(.roundedBorder).font(.adMono).monospacedDigit().frame(width: 40)
          .focused($focus, equals: .engage)
          .onSubmit { commitEngage() }
        Text("rel").font(.adMono).foregroundStyle(Palette.ink2)
        TextField("0", text: $releaseDelta)
          .textFieldStyle(.roundedBorder).font(.adMono).monospacedDigit().frame(width: 40)
          .focused($focus, equals: .release)
          .onSubmit { commitRelease() }
        Text("s · blank = global").font(.adMono).foregroundStyle(Palette.ink3)
      }
    }
    .padding(.vertical, 4)
    .onChange(of: focus) { old, _ in
      if old == .name { commitName() }
      if old == .poll { commitPoll() }
      if old == .engage { commitEngage() }
      if old == .release { commitRelease() }
    }
  }

  private func commitName() {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed != zone.name else { return }
    Task { await model.renameZone(zone.id, to: trimmed) }
  }

  private func commitPoll() {
    let seconds = Int(pollSeconds.trimmingCharacters(in: .whitespaces))
    guard seconds.map({ $0 * 1000 }) != zone.pollIntervalMs else { return }
    Task { await model.setPollInterval(zone.id, seconds: seconds) }
  }

  private func commitEngage() {
    let seconds = Int(engageDelta.trimmingCharacters(in: .whitespaces))
    guard seconds.map(Double.init) != zone.engageDeltaSeconds else { return }
    Task { await model.setEngageDelta(zone.id, seconds: seconds) }
  }

  private func commitRelease() {
    let seconds = Int(releaseDelta.trimmingCharacters(in: .whitespaces))
    guard seconds.map(Double.init) != zone.releaseDeltaSeconds else { return }
    Task { await model.setReleaseDelta(zone.id, seconds: seconds) }
  }

  private func slotRow(_ label: String, geojson: String, slot: ZoneSlot) -> some View {
    HStack(spacing: 6) {
      sectionLabel(label).frame(width: 56, alignment: .leading)
      if geojson.isEmpty {
        Button("Open") { model.openInGeojsonIO(geojson) }.buttonStyle(ChipButton())
      } else {
        Button { model.openInGeojsonIO(geojson) } label: {
          HStack(spacing: 5) {
            Circle().fill(Palette.accent).frame(width: 6, height: 6)
            Text("Polygon set")
          }
        }
        .buttonStyle(ChipButton(filled: true))
      }
      Button("Paste") { Task { await model.pasteZone(zone.id, slot: slot) } }
        .buttonStyle(ChipButton())
      Spacer(minLength: 0)
    }
  }
}

/// Add a new zoneset: name + paste a Monitor polygon + paste an ANC polygon → Create.
private struct AddZoneForm: View {
  let model: StatusModel
  @State private var name = ""
  @State private var monitor: String?
  @State private var anc: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      sectionLabel("Add a zone")
      TextField("name — e.g. Final approach", text: $name)
        .textFieldStyle(.roundedBorder).font(.adZone)

      HStack(spacing: 6) {
        Button(monitor == nil ? "Paste Monitor" : "Monitor ✓") {
          monitor = NSPasteboard.general.string(forType: .string)
        }
        .buttonStyle(ChipButton(filled: monitor != nil))
        Button(anc == nil ? "Paste ANC" : "ANC ✓") {
          anc = NSPasteboard.general.string(forType: .string)
        }
        .buttonStyle(ChipButton(filled: anc != nil))
        Spacer()
        Button("Create") {
          Task {
            if await model.addZone(name: name, monitor: monitor ?? "", anc: anc ?? "") {
              name = ""
              monitor = nil
              anc = nil
            }
          }
        }
        .buttonStyle(PillButton(bg: canCreate ? Palette.accent : Palette.fill, fg: canCreate ? Palette.onAccent : Palette.ink3, lit: canCreate))
        .disabled(!canCreate)
      }

      (Text("Draw one polygon on ").foregroundStyle(Palette.ink3)
        + Text("geojson.io").foregroundStyle(Palette.accent)
        + Text(", copy it, then paste into Monitor or ANC.").foregroundStyle(Palette.ink3))
        .font(.adMono)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var canCreate: Bool { !name.isEmpty && monitor != nil && anc != nil }
}

// MARK: - Shared helpers

/// "3h 37m" remaining until a unix-seconds deadline.
func countdown(_ endsAt: Int?) -> String {
  guard let ends = endsAt else { return "—" }
  let remaining = max(0, ends - Int(Date().timeIntervalSince1970))
  return "\(remaining / 3600)h \((remaining % 3600) / 60)m"
}

/// "0:42" remaining until a unix-seconds deadline (minutes:seconds).
func mmss(_ at: Int) -> String {
  let s = max(0, at - Int(Date().timeIntervalSince1970))
  return "\(s / 60):" + String(format: "%02d", s % 60)
}
