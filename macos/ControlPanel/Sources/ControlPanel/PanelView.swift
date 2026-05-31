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
    VStack(alignment: .leading, spacing: 8) {
      if !model.reachable {
        Text("service offline").font(.caption).foregroundStyle(.tertiary)
      } else if model.zonesets.isEmpty {
        Text("no zones configured").font(.caption).foregroundStyle(.tertiary)
      } else {
        ForEach(model.zonesets) { zone in
          zoneRow(zone)
        }
      }
    }
  }

  // One Start 4h / Stop control per zoneset, with a live/idle indicator. Each
  // zone runs an independent session (start the one matching the active runway).
  private func zoneRow(_ zone: ZonesetStatus) -> some View {
    HStack(spacing: 8) {
      Circle()
        .fill(zone.active ? Color.green : Color.secondary.opacity(0.4))
        .frame(width: 8, height: 8)

      VStack(alignment: .leading, spacing: 1) {
        Text(zone.name).font(.subheadline)
        Text(zone.active ? "monitoring · \(zoneCountdown(zone)) left" : "idle")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      Spacer()

      if zone.active {
        Button { model.stop(zone.id) } label: {
          Label("Stop", systemImage: "stop.fill")
        }
      } else {
        Button { model.start(zone.id) } label: {
          Label("Start 4h", systemImage: "play.fill")
        }
      }
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
  }

  private func zoneCountdown(_ zone: ZonesetStatus) -> String {
    guard let ends = zone.endsAt else { return "—" }
    let remaining = max(0, ends - Int(Date().timeIntervalSince1970))
    return "\(remaining / 3600)h \((remaining % 3600) / 60)m"
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
