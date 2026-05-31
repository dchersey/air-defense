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

  func copyToClipboard(_ string: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(string, forType: .string)
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
  private func mutate(_ method: String, _ path: String, _ body: [String: String]?) async -> Bool {
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
