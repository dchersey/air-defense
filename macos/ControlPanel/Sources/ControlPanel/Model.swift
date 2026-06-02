import AppKit
import Foundation
import Observation

struct Flight: Codable, Identifiable {
  let callsign: String?
  let altFt: Double?
  let at: Int
  let entersIn: Int
  let dwell: Int

  var id: String { "\(callsign ?? "?")-\(at)" }
}

struct ZonesetStatus: Codable, Identifiable {
  let id: String
  let name: String
  let active: Bool
  let endsAt: Int?
}

/// A zoneset as seen by the editor — GeoJSON kept as opaque strings (the backend
/// encodes/decodes/validates; the app only shuttles clipboard text).
struct EditableZone: Identifiable, Codable {
  let id: String
  var name: String
  var pollIntervalMs: Int?
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
  let polls: Int
  let approxCredits: Int
  let zonesets: [ZonesetStatus]
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

  // AirPods presence (the active output), checked locally via CoreAudio.
  var headphonesConnected = true
  private var lastSentHeadphones: Bool?

  // Zoneset editor state.
  var editZones: [EditableZone] = []
  var editError: String?

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
      sessionEndsAt = status.sessionEndsAt
      polls = status.polls
      approxCredits = status.approxCredits
      zonesets = status.zonesets
      recent = status.recent
      history = status.history
      reachable = true

      updateHeadphones()
      applyModeIfChanged(status.mode)
    } catch {
      reachable = false
    }
  }

  /// Detect whether AirPods are the active output; push the state to the service
  /// when it changes so it can pause/resume monitoring.
  private func updateHeadphones() {
    let connected = AncController.airPodsAreOutput()
    headphonesConnected = connected

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
