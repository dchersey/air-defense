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

struct StatusResponse: Codable {
  let active: Bool
  let mode: String
  let sessionEndsAt: Int?
  let polls: Int
  let approxCredits: Int
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

  init() {
    AncController.ensureTrusted()
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
      recent = status.recent
      history = status.history
      reachable = true

      applyModeIfChanged(status.mode)
    } catch {
      reachable = false
    }
  }

  /// Mirror the backend's desired mode onto the headphones, but only on a change
  /// (the actuator posts AirBuddy's toggle hotkey, so firing every poll would
  /// flip the mode back and forth).
  private func applyModeIfChanged(_ desired: String) {
    guard desired != appliedMode else { return }
    let target: AncController.Mode = (desired == "anc") ? .anc : .transparency
    if AncController.set(target) {
      appliedMode = desired
    }
  }

  func start() { post("/api/session/start") }
  func stop() { post("/api/session/stop") }

  private func post(_ path: String) {
    guard let url = URL(string: base + path) else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    Task {
      _ = try? await URLSession.shared.data(for: request)
      await refresh()
    }
  }
}
