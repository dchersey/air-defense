import AppKit
import AVFoundation
import Foundation
import Observation

struct Flight: Codable, Identifiable {
  let callsign: String?
  let altFt: Double?
  let at: Int
  let entersIn: Int
  let dwell: Int
  // Airport route (origin/dest IATA) from the backend's FlightAware AeroAPI lookup;
  // nil until resolved. `isPrivate` = fetched but no route (GA/private) → show "private".
  let origin: String?
  let destination: String?
  let isPrivate: Bool?

  var id: String { "\(callsign ?? "?")-\(at)" }
}

struct ZonesetStatus: Codable, Identifiable {
  let id: String
  let name: String
  let active: Bool
  let endsAt: Int?
  // Per-zone live state for the UI: phase ("monitoring"/"armed"/"engaged"/"idle"),
  // the soonest ANC-engage time, and the count of active intercepts.
  let phase: String?
  let interceptAt: Int?
  let inbound: Int?
}

/// A zoneset as seen by the editor — GeoJSON kept as opaque strings (the backend
/// encodes/decodes/validates; the app only shuttles clipboard text).
struct EditableZone: Identifiable, Codable {
  let id: String
  var name: String
  var type: String?  // "arrival" | "departure" (drives the engage strategy)
  var pollIntervalMs: Int?
  // Per-zone ANC timing offsets (seconds); nil → fall back to the global offset. Lets
  // arrival and departure zones be calibrated independently.
  var engageDeltaSeconds: Double?
  var releaseDeltaSeconds: Double?
  var monitorGeojson: String
  var ancGeojson: String
}

private struct ZonesetsResponse: Codable {
  let zonesets: [EditableZone]
}

enum ZoneSlot { case monitor, anc }

/// Menu-bar indicator state. Drives icon + colour:
/// idle = white/default, pending = amber (flight detected, ANC scheduled),
/// engaged = red (ANC on), offline = service unreachable.
enum AncPhase {
  case offline, idle, pending, engaged, disconnected
}

struct StatusResponse: Codable {
  let active: Bool
  let mode: String
  let sessionEndsAt: Int?
  let ancPhase: String
  let engageDeltaSeconds: Double
  let releaseDeltaSeconds: Double
  let creditsUsedMonth: Int?
  let creditsBudgetMonth: Int
  let billingResetDay: Int
  let provider: String
  let fr24KeyPresent: Bool
  let aeroapiKeyPresent: Bool?
  let polls: Int
  let approxCredits: Int
  let zonesets: [ZonesetStatus]
  // Soonest inbound (for the banner): when ANC engages + the flight's route label.
  let inboundAt: Int?
  let inboundRoute: String?
  // Currently-overhead flight (ANC engaged): route label + clear-by time. overheadAt
  // is nil for live-tracked departures (radar mark instead of a countdown).
  let overheadAt: Int?
  let overheadRoute: String?
  let recent: [Flight]
  let history: [Int]
}

/// Polls the local Elixir service, mirrors the desired acoustic mode onto the
/// AirPods (only when it changes, to avoid flashing Control Center), and exposes
/// state to the SwiftUI panel.
@MainActor
@Observable
final class StatusModel {
  var active = false
  var mode = "transparency"
  var ancPhase = "idle"
  var sessionEndsAt: Int?
  var polls = 0
  var approxCredits = 0
  var zonesets: [ZonesetStatus] = []
  var recent: [Flight] = []
  // Soonest inbound for the banner (engage time + route label).
  var inboundAt: Int?
  var inboundRoute: String?
  // Currently-overhead flight (engaged): clear-by time (nil for live-tracked
  // departures) + route label.
  var overheadAt: Int?
  var overheadRoute: String?
  var history: [Int] = []
  var reachable = false

  // Manual ANC timing offsets (seconds), from the service config.
  var engageDelta: Double = 0
  var releaseDelta: Double = 0

  // FR24 month-to-date credit usage (nil until first fetched) + plan allotment.
  var creditsUsedMonth: Int?
  var creditsBudgetMonth = 60_000
  // Day-of-month the FR24 allotment resets (billing anniversary; 1 = calendar month).
  var billingResetDay = 1
  // Flight-data source for all zones, + whether an FR24 key is stored.
  var provider = "airplanes_live"
  var fr24KeyPresent = false
  // AeroAPI key (real-time flight routes for the recent-flights list).
  var aeroapiKeyPresent = false

  // AirPods presence (the active output), checked locally via CoreAudio.
  var headphonesConnected = true
  private var lastSentHeadphones: Bool?
  // Last-known AirPods kind: true = Pro, false = Max/other. Sticky across a
  // disconnect so the disconnected/engaged glyph matches what was just in use;
  // updated whenever AirPods are the active output (e.g. switch Pro → Max).
  var headphonesArePro = false

  // Quiet-period alert: when a session has run 10 min with no detections, play a
  // message through the AirPods (so a busy user knows LGA may have shifted patterns
  // and they can take the headphones off). Re-alerts every 10 min while still quiet.
  @ObservationIgnored private var activeSince: Date?
  @ObservationIgnored private var lastQuietAlertAt: Date?
  // Last moment a flight was being tracked (inbound/amber or overhead/red). Folded
  // into the quiet-window reference so the all-clear never fires over an active
  // target and the clock restarts once it clears — even for a near-miss that tracks
  // through without engaging (so never lands in `recent`).
  @ObservationIgnored private var lastActivityAt: Date?
  @ObservationIgnored private var alertPlayer: AVAudioPlayer?
  private let quietGap: TimeInterval = 600

  // Headphones-off (not-monitoring) spans observed during a session, kept for the
  // last hour. Used to (a) NOT count off-time toward the quiet-alert window — else
  // reconnecting after a long pause would instantly trip the 10-min gap — and (b)
  // compact the activity chart so a pause shows no empty bars (with a separator if
  // the off span exceeded a bucket). The app is the source of truth for headphone
  // state (it polls CoreAudio every 2s), so these are recorded locally.
  private(set) var pauseIntervals: [DateInterval] = []
  private(set) var currentPauseStart: Date?

  // Soft pulse (0.5...1.0) for the menu-bar glyph while monitoring. Driven by a
  // timer rather than a SwiftUI animation — MenuBarExtra(.window) tears if a
  // repeatForever animation runs in the scene, so we animate by swapping the
  // tinted NSImage's alpha each tick.
  var menuPulse: Double = 1.0
  @ObservationIgnored private var pulseTimer: Timer?
  @ObservationIgnored private var pulseTick = 0

  // Zoneset editor state.
  var editZones: [EditableZone] = []
  var editError: String?

  // Transient toast message shown over the panel (auto-clears after a moment).
  var toast: String?
  @ObservationIgnored private var toastTask: Task<Void, Never>?

  private let base = "http://127.0.0.1:4040"
  private var timer: Timer?
  // Seeded to the assumed starting mode. The actuator is a BLIND toggle
  // (Ctrl-Shift-A), so we must not fire it on the first poll: we assume the
  // AirPods begin in Transparency when a session starts. If that assumption is
  // wrong the state can invert — toggle manually once to resync.
  private var appliedMode: String = "transparency"
  // Guards against a second AX sequence starting before the first finishes
  // (back-to-back desired-mode changes), which left the popover open.
  private var isApplying = false

  /// Current menu-bar phase from the backend actuator: engaged = ANC on (red),
  /// pending = a flight detected and ANC scheduled but not yet on (amber),
  /// idle = nothing scheduled (default).
  var phase: AncPhase {
    if !reachable { return .offline }
    if active && !headphonesConnected { return .disconnected }
    switch ancPhase {
    case "engaged": return .engaged
    case "armed": return .pending
    default: return .idle
    }
  }

  init() {
    let trusted = AncController.ensureTrusted()
    Log.line("StatusModel init — accessibility trusted=\(trusted)")
    timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
      Task { await self?.refresh() }
    }
    Task { await refresh() }
  }

  func refresh() async {
    guard let url = URL(string: "\(base)/api/status") else { return }

    do {
      let (data, _) = try await URLSession.shared.data(from: url)
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      let status = try decoder.decode(StatusResponse.self, from: data)

      active = status.active
      mode = status.mode
      ancPhase = status.ancPhase
      engageDelta = status.engageDeltaSeconds
      releaseDelta = status.releaseDeltaSeconds
      creditsUsedMonth = status.creditsUsedMonth
      creditsBudgetMonth = status.creditsBudgetMonth
      billingResetDay = status.billingResetDay
      provider = status.provider
      fr24KeyPresent = status.fr24KeyPresent
      aeroapiKeyPresent = status.aeroapiKeyPresent ?? false
      sessionEndsAt = status.sessionEndsAt
      polls = status.polls
      approxCredits = status.approxCredits
      zonesets = status.zonesets
      inboundAt = status.inboundAt
      inboundRoute = status.inboundRoute
      overheadAt = status.overheadAt
      overheadRoute = status.overheadRoute
      recent = status.recent
      history = status.history
      reachable = true

      updateHeadphones()
      trackPauses()
      applyModeIfChanged(status.mode)
      updateMenuPulse()
      evaluateQuietAlert()
    } catch {
      reachable = false
      updateMenuPulse()
    }
  }

  // Whether the quiet-period alert is enabled (Settings toggle; default on).
  private var quietAlertEnabled: Bool {
    UserDefaults.standard.object(forKey: "quietAlertEnabled") as? Bool ?? true
  }

  // Fire (and periodically re-fire) the alert after `quietGap` seconds of MONITORED
  // silence, measured from the later of session start or the last detection. So both
  // "busy, then quiet" AND "activated a monitor but nothing showed" alert the user.
  private func evaluateQuietAlert() {
    guard active else {
      activeSince = nil
      lastQuietAlertAt = nil
      lastActivityAt = nil
      return
    }
    if activeSince == nil { activeSince = Date() }
    guard let start = activeSince, headphonesConnected, quietAlertEnabled else { return }

    // A flight currently inbound (amber/armed) or overhead (red/engaged) is activity:
    // never sound the all-clear over it, and stamp the moment so the quiet clock
    // restarts once it clears (covers near-misses that track through but never engage,
    // so never appear in `recent`).
    if phase == .pending || phase == .engaged {
      lastActivityAt = Date()
      return
    }

    // Quiet window runs from the most recent of: session start, last alert, the last
    // detection this session, or the last time a flight was being tracked (stale
    // flights from before `start` are ignored).
    var reference = max(start, lastQuietAlertAt ?? .distantPast)
    if let lastFlight = recent.first.map({ Date(timeIntervalSince1970: TimeInterval($0.at)) }),
      lastFlight > reference {
      reference = lastFlight
    }
    if let activity = lastActivityAt, activity > reference { reference = activity }

    // Measure the gap in MONITORED time only — subtract any headphones-off spans
    // since the reference, so a long pause doesn't make us fire the instant the buds
    // come back on.
    let monitored = Date().timeIntervalSince(reference) - pausedSeconds(since: reference)
    if monitored >= quietGap {
      playQuietAlert()
      lastQuietAlertAt = Date()
    }
  }

  // Record headphones-off spans (only while a session is active) and prune to the
  // last hour. Runs every refresh tick, after `updateHeadphones()` sets the state.
  private func trackPauses() {
    let now = Date()
    if active && !headphonesConnected {
      if currentPauseStart == nil { currentPauseStart = now }
    } else if let start = currentPauseStart {
      pauseIntervals.append(DateInterval(start: start, end: now))
      currentPauseStart = nil
    }
    let cutoff = now.addingTimeInterval(-3600)
    pauseIntervals.removeAll { $0.end < cutoff }
  }

  // Total headphones-off time after `ref` (completed spans + any open pause to now).
  private func pausedSeconds(since ref: Date) -> TimeInterval {
    let now = Date()
    var total: TimeInterval = 0
    for iv in pauseIntervals {
      let lo = max(iv.start, ref)
      if iv.end > lo { total += iv.end.timeIntervalSince(lo) }
    }
    if let open = currentPauseStart {
      let lo = max(open, ref)
      if now > lo { total += now.timeIntervalSince(lo) }
    }
    return total
  }

  // Seconds of the wall-clock window [start, end] (unix epoch) that were NOT
  // monitored (headphones off). Drives the activity chart's gap compaction.
  func pausedOverlap(start: TimeInterval, end: TimeInterval) -> TimeInterval {
    let s = Date(timeIntervalSince1970: start)
    let e = Date(timeIntervalSince1970: end)
    var total: TimeInterval = 0
    for iv in pauseIntervals {
      let lo = max(iv.start, s), hi = min(iv.end, e)
      if hi > lo { total += hi.timeIntervalSince(lo) }
    }
    if let open = currentPauseStart {
      let lo = max(open, s), hi = min(Date(), e)
      if hi > lo { total += hi.timeIntervalSince(lo) }
    }
    return total
  }

  // Play the bundled "all-clear" message at a modest volume through the active output.
  private func playQuietAlert() {
    guard let url = Bundle.main.url(forResource: "all-clear", withExtension: "mp3") else {
      Log.line("quiet alert: all-clear.mp3 not found in bundle")
      return
    }
    do {
      let player = try AVAudioPlayer(contentsOf: url)
      player.volume = 0.45  // modest
      player.prepareToPlay()
      player.play()
      alertPlayer = player  // retain until playback finishes
      Log.line("quiet-period alert played (\(Int(quietGap / 60)) min no flights)")
    } catch {
      Log.line("quiet alert play failed: \(error)")
    }
  }

  // Run the menu-bar pulse only while actively monitoring (session up, nothing
  // inbound/engaged, headphones present — i.e. phase == .idle && active).
  private func updateMenuPulse() {
    if active && phase == .idle { startPulse() } else { stopPulse() }
  }

  private func startPulse() {
    guard pulseTimer == nil else { return }
    pulseTick = 0
    let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tickPulse() }
    }
    RunLoop.main.add(timer, forMode: .common)  // keep pulsing during menu tracking
    pulseTimer = timer
  }

  private func tickPulse() {
    pulseTick += 1
    let t = Double(pulseTick) * 0.06
    let s = (sin(t * 2 * .pi / 1.5) + 1) / 2  // 1.5s period, 0...1
    menuPulse = 0.65 + 0.35 * s  // 0.65...1.0 — soft pulse that stays legible
  }

  private func stopPulse() {
    pulseTimer?.invalidate()
    pulseTimer = nil
    menuPulse = 1.0
  }

  /// Detect whether AirPods are the active output; push the state to the service
  /// when it changes so it can pause/resume monitoring.
  private func updateHeadphones() {
    let connected = AncController.airPodsAreOutput()
    headphonesConnected = connected
    // Remember the kind while connected (sticky across the next disconnect).
    if let pro = AncController.airPodsOutputIsPro() { headphonesArePro = pro }

    guard connected != lastSentHeadphones else { return }
    lastSentHeadphones = connected
    Log.line("headphones \(connected ? "connected" : "disconnected") -> notifying service")

    guard let url = URL(string: "\(base)/api/headphones") else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["connected": connected])
    Task { _ = try? await URLSession.shared.data(for: request) }
  }

  /// Mirror the backend's desired mode onto the headphones. Only acts on a change
  /// (the AX switch opens Control Center briefly, so we don't do it every poll).
  /// Control Center "set mode" is idempotent and absolute, so if a previous apply
  /// failed we retry next poll (appliedMode only advances on success).
  private func applyModeIfChanged(_ desired: String) {
    // Nothing to switch if AirPods aren't the active output — leave appliedMode
    // pending so the desired mode applies the instant they reconnect.
    guard headphonesConnected else { return }
    guard desired != appliedMode else { return }
    guard !isApplying else {
      Log.line("applyMode skipped (busy) desired=\(desired)")
      return
    }

    isApplying = true
    defer { isApplying = false }

    let target: AncController.Mode = (desired == "anc") ? .anc : .transparency
    let ok = AncController.set(target)
    Log.line("applyMode desired=\(desired) applied=\(appliedMode) -> set(\(target.rawValue)) ok=\(ok)")
    if ok {
      appliedMode = desired
    }
  }

  func start(_ zoneset: String) { post("/api/session/start", body: ["zoneset": zoneset]) }
  func stop(_ zoneset: String) { post("/api/session/stop", body: ["zoneset": zoneset]) }

  /// Set the global ANC engage/release offsets (seconds). Partial PUT — the
  /// service merges these and keeps the zonesets.
  func setAncOffsets(engage: Double, release: Double) {
    guard let url = URL(string: "\(base)/api/config") else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: [
      "engage_delta_seconds": Int(engage),
      "release_delta_seconds": Int(release),
    ])
    Task {
      _ = try? await URLSession.shared.data(for: request)
      await refresh()
    }
  }

  /// Align the month-to-date self-tally with the FR24 dashboard: pass the
  /// *remaining* balance shown in your FR24 profile. The service converts it to
  /// `budget - remaining` and tracks live from there.
  func seedCredits(remaining: Int) {
    guard let url = URL(string: "\(base)/api/credits/seed") else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["remaining": remaining])
    Task {
      _ = try? await URLSession.shared.data(for: request)
      await refresh()
    }
  }

  /// Set the FR24 billing-anniversary day (1–31). Partial PUT — the service
  /// merges it and the credit ledger re-keys its cycle to this day.
  func setBillingResetDay(_ day: Int) {
    guard let url = URL(string: "\(base)/api/config") else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["billing_reset_day": day])
    Task {
      _ = try? await URLSession.shared.data(for: request)
      await refresh()
    }
  }

  /// Switch the flight-data provider for all zones (airplanes_live | adsb_lol | fr24).
  func setProvider(_ id: String) {
    provider = id  // optimistic; refresh() reconciles
    guard let url = URL(string: "\(base)/api/config") else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "PUT"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["provider": id])
    Task { _ = try? await URLSession.shared.data(for: request); await refresh() }
  }

  /// Store the FlightRadar24 API key (backend writes it to the Keychain).
  func setFR24Key(_ key: String) {
    guard let url = URL(string: "\(base)/api/fr24_key") else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["key": key])
    Task { _ = try? await URLSession.shared.data(for: request); await refresh() }
  }

  /// Store the FlightAware AeroAPI key (backend writes it to the Keychain) — used to
  /// resolve real-time airport routes for the recent-flights list.
  func setAeroapiKey(_ key: String) {
    guard let url = URL(string: "\(base)/api/aeroapi_key") else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: ["key": key])
    Task { _ = try? await URLSession.shared.data(for: request); await refresh() }
  }

  // MARK: - Zoneset editor

  func loadZones() async {
    guard let url = URL(string: "\(base)/api/zonesets") else { return }
    do {
      let (data, _) = try await URLSession.shared.data(from: url)
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      editZones = try decoder.decode(ZonesetsResponse.self, from: data).zonesets
      editError = nil
    } catch {
      editError = "Couldn't load zones (service offline?)"
    }
  }

  /// Show a transient message over the panel for a couple of seconds.
  func flashToast(_ message: String) {
    toast = message
    toastTask?.cancel()
    toastTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(2.5))
      if !Task.isCancelled { self?.toast = nil }
    }
  }

  /// Open FlightRadar24 (in the system default browser) centered on the ANC zone at
  /// a useful zoom. Lazily loads the zones (geometry isn't in /api/status). If no
  /// ANC zone is defined, shows a toast instead.
  func openFlightRadar() {
    Task {
      if editZones.isEmpty { await loadZones() }
      guard let c = ancCenter() else {
        flashToast("No noise zones defined")
        return
      }
      let path = String(format: "%.4f,%.4f/15", c.lat, c.lon)
      if let u = URL(string: "https://www.flightradar24.com/\(path)") {
        NSWorkspace.shared.open(u)  // system default browser
      }
    }
  }

  /// Centroid of the ANC polygon for the active zoneset (or the first), as (lat, lon).
  private func ancCenter() -> (lat: Double, lon: Double)? {
    let activeID = zonesets.first(where: \.active)?.id
    let zone = editZones.first { $0.id == activeID } ?? editZones.first
    guard let geo = zone?.ancGeojson, !geo.isEmpty else { return nil }
    return centroid(geo)
  }

  /// Average of every [lon, lat] position in a GeoJSON object → (lat, lon).
  private func centroid(_ geojson: String) -> (lat: Double, lon: Double)? {
    guard let data = geojson.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: data)
    else { return nil }

    var lats: [Double] = []
    var lons: [Double] = []
    func walk(_ any: Any) {
      if let array = any as? [Any] {
        if array.count >= 2, let x = array[0] as? Double, let y = array[1] as? Double,
          abs(x) <= 180, abs(y) <= 90
        {
          lons.append(x)
          lats.append(y)
        } else {
          array.forEach(walk)
        }
      } else if let dict = any as? [String: Any] {
        dict.values.forEach(walk)
      }
    }
    walk(obj)

    guard !lats.isEmpty else { return nil }
    return (lats.reduce(0, +) / Double(lats.count), lons.reduce(0, +) / Double(lons.count))
  }

  /// Open a zone's GeoJSON directly in geojson.io — rendered for viewing/editing
  /// and zoomed to the zone. (Bring edits back with "Paste".)
  func openInGeojsonIO(_ geojson: String) {
    // encodeURIComponent equivalent: only RFC-3986 unreserved chars stay literal.
    let unreserved = CharacterSet(
      charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
    guard let encoded = geojson.addingPercentEncoding(withAllowedCharacters: unreserved) else {
      return
    }

    // The (rewritten) geojson.io reads the view from the QUERY (?map=zoom/lat/lon)
    // and loads data from the hash (#data=data:application/json,<encoded>).
    var url = "https://geojson.io/"
    if let c = firstCoordinate(geojson) {
      url += "?map=14/\(c.lat)/\(c.lon)"
    }
    url += "#data=data:application/json,\(encoded)"

    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
  }

  /// Best-effort dig for the first [lon, lat] pair so geojson.io can center there.
  private func firstCoordinate(_ geojson: String) -> (lat: Double, lon: Double)? {
    guard let data = geojson.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: data)
    else { return nil }

    func search(_ any: Any) -> [Double]? {
      if let array = any as? [Any] {
        if array.count >= 2, let x = array[0] as? Double, let y = array[1] as? Double {
          return [x, y]
        }
        for element in array { if let found = search(element) { return found } }
      } else if let dict = any as? [String: Any] {
        for value in dict.values { if let found = search(value) { return found } }
      }
      return nil
    }

    guard let coord = search(obj), coord.count >= 2 else { return nil }
    return (lat: coord[1], lon: coord[0])  // GeoJSON is [lon, lat]
  }

  func pasteZone(_ id: String, slot: ZoneSlot) async {
    guard let clip = NSPasteboard.general.string(forType: .string), !clip.isEmpty else {
      editError = "Clipboard is empty — copy a polygon from geojson.io first."
      return
    }
    let field = slot == .monitor ? "monitor_geojson" : "anc_geojson"
    await mutate("PATCH", "/api/zonesets/\(id)", [field: clip])
  }

  func renameZone(_ id: String, to name: String) async {
    await mutate("PATCH", "/api/zonesets/\(id)", ["name": name])
  }

  /// Set this zone's poll cadence in whole seconds; nil clears it to the global default.
  func setPollInterval(_ id: String, seconds: Int?) async {
    let value: Any = seconds.map { $0 * 1000 } ?? NSNull()
    await mutate("PATCH", "/api/zonesets/\(id)", ["poll_interval_ms": value])
  }

  /// Set this zone's type: "arrival" (ETA-scheduled) or "departure" (engage on
  /// actual zone entry, tracked fast).
  func setZoneType(_ id: String, type: String) async {
    await mutate("PATCH", "/api/zonesets/\(id)", ["type": type])
  }

  /// Set this zone's ANC engage offset (seconds, may be negative = engage earlier);
  /// nil clears it to the global default.
  func setEngageDelta(_ id: String, seconds: Int?) async {
    let value: Any = seconds.map { $0 as Any } ?? NSNull()
    await mutate("PATCH", "/api/zonesets/\(id)", ["engage_delta_seconds": value])
  }

  /// Set this zone's ANC release offset (seconds); nil clears it to the global default.
  func setReleaseDelta(_ id: String, seconds: Int?) async {
    let value: Any = seconds.map { $0 as Any } ?? NSNull()
    await mutate("PATCH", "/api/zonesets/\(id)", ["release_delta_seconds": value])
  }

  func deleteZone(_ id: String) async {
    await mutate("DELETE", "/api/zonesets/\(id)", nil)
  }

  @discardableResult
  func addZone(name: String, monitor: String, anc: String) async -> Bool {
    await mutate("POST", "/api/zonesets", [
      "name": name, "monitor_geojson": monitor, "anc_geojson": anc,
    ])
  }

  /// Fire a write request; on success clear the error and reload the list, else
  /// surface the backend's validation message. Returns whether it succeeded.
  @discardableResult
  private func mutate(_ method: String, _ path: String, _ body: [String: Any]?) async -> Bool {
    guard let url = URL(string: base + path) else { return false }
    var request = URLRequest(url: url)
    request.httpMethod = method
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    }

    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      if code == 200 {
        editError = nil
        await loadZones()
        return true
      }
      let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
      editError = message ?? "Request failed (\(code))"
      return false
    } catch {
      editError = "Request failed"
      return false
    }
  }

  private func post(_ path: String, body: [String: String]? = nil) {
    guard let url = URL(string: base + path) else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try? JSONSerialization.data(withJSONObject: body)
    }
    Task {
      _ = try? await URLSession.shared.data(for: request)
      await refresh()
    }
  }
}
