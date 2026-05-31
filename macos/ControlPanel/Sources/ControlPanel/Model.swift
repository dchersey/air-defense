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

struct StatusResponse: Codable {
  let active: Bool
  let mode: String
  let sessionEndsAt: Int?
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
  var sessionEndsAt: Int?
  var polls = 0
  var approxCredits = 0
  var zonesets: [ZonesetStatus] = []
  var recent: [Flight] = []
  var history: [Int] = []
  var reachable = false

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
      sessionEndsAt = status.sessionEndsAt
      polls = status.polls
      approxCredits = status.approxCredits
      zonesets = status.zonesets
      recent = status.recent
      history = status.history
      reachable = true

      applyModeIfChanged(status.mode)
    } catch {
      reachable = false
    }
  }

  /// Mirror the backend's desired mode onto the headphones. Only acts on a change
  /// (the AX switch opens Control Center briefly, so we don't do it every poll).
  /// Control Center "set mode" is idempotent and absolute, so if a previous apply
  /// failed we retry next poll (appliedMode only advances on success).
  private func applyModeIfChanged(_ desired: String) {
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
