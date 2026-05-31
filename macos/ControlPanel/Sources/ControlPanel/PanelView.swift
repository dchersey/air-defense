import AppKit
import Charts
import SwiftUI

struct PanelView: View {
  let model: StatusModel
  @State private var launchAtLogin = LoginItem.isEnabled

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      Divider()
      controls
      if model.history.contains(where: { $0 > 0 }) {
        chart
      }
      Divider()
      flights
      Divider()
      footer
    }
    .padding(14)
    .frame(width: 320)
  }

  // MARK: - Header

  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text("LGA Overflight").font(.headline)
        Text(model.reachable ? statusLine : "service offline")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      modeBadge
    }
  }

  private var statusLine: String {
    model.active ? "monitoring · \(countdown) left · ~\(model.approxCredits) cr" : "idle"
  }

  private var modeBadge: some View {
    let anc = model.mode == "anc"
    return Text(anc ? "ANC" : "Transparency")
      .font(.caption.bold())
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(anc ? Color.blue.opacity(0.2) : Color.green.opacity(0.2))
      .foregroundStyle(anc ? .blue : .green)
      .clipShape(Capsule())
  }

  private var countdown: String {
    guard let ends = model.sessionEndsAt else { return "—" }
    let remaining = max(0, ends - Int(Date().timeIntervalSince1970))
    return "\(remaining / 3600)h \((remaining % 3600) / 60)m"
  }

  // MARK: - Controls

  private var controls: some View {
    HStack {
      Button(action: model.start) {
        Label("Start 4h session", systemImage: "play.fill")
      }
      .disabled(model.active || !model.reachable)

      Button(action: model.stop) {
        Label("Stop", systemImage: "stop.fill")
      }
      .disabled(!model.active)
    }
    .buttonStyle(.bordered)
  }

  // MARK: - Chart

  private var chart: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Overflights (last hour, 5-min)").font(.caption).foregroundStyle(.secondary)
      Chart(Array(model.history.enumerated()), id: \.offset) { index, count in
        BarMark(x: .value("Bucket", index), y: .value("Flights", count))
          .foregroundStyle(.blue)
      }
      .chartYAxis { AxisMarks(position: .leading) }
      .chartXAxis(.hidden)
      .frame(height: 70)
    }
  }

  // MARK: - Flights

  private var flights: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Recent flights").font(.caption).foregroundStyle(.secondary)

      if model.recent.isEmpty {
        Text(model.active ? "none yet" : "start a session to monitor")
          .font(.caption).foregroundStyle(.tertiary)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(model.recent.prefix(12)) { flight in
              HStack {
                Text(flight.callsign ?? "?").font(.caption.monospaced())
                Spacer()
                if let alt = flight.altFt {
                  Text("\(Int(alt)) ft").font(.caption).foregroundStyle(.secondary)
                }
              }
            }
          }
        }
        .frame(maxHeight: 160)
      }
    }
  }

  // MARK: - Footer

  private var footer: some View {
    HStack {
      Toggle("Launch at Login", isOn: $launchAtLogin)
        .toggleStyle(.checkbox)
        .font(.caption)
        .onChange(of: launchAtLogin) { _, newValue in
          launchAtLogin = LoginItem.setEnabled(newValue)
        }
      Spacer()
      Button("Quit") { NSApplication.shared.terminate(nil) }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
  }
}
