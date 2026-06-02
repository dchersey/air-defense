import AppKit
import Charts
import SwiftUI

struct PanelView: View {
  let model: StatusModel
  @State private var launchAtLogin = LoginItem.isEnabled
  @State private var showEditor = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header
      Divider()
      controls
      if model.active && !model.headphonesConnected {
        Label("AirPods not connected — monitoring paused (timer still running)", systemImage: "headphones")
          .font(.caption2)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }
      if model.history.contains(where: { $0 > 0 }) {
        chart
      }
      Divider()
      flights
      Divider()
      CreditBar(used: model.creditsUsedMonth, budget: model.creditsBudgetMonth, model: model)
      Divider()
      TimingOffsets(model: model)
      Divider()
      zoneEditor
      Divider()
      footer
    }
    .padding(14)
    .frame(width: 320)
  }

  // MARK: - Zone editor

  private var zoneEditor: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        showEditor.toggle()
        if showEditor { Task { await model.loadZones() } }
      } label: {
        Label(showEditor ? "Done editing zones" : "Edit zones", systemImage: "slider.horizontal.3")
          .font(.caption)
      }
      .buttonStyle(.borderless)

      if showEditor {
        if let err = model.editError {
          Text(err)
            .font(.caption2).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }

        ForEach(model.editZones) { zone in
          ZoneEditRow(zone: zone, model: model)
        }

        Divider()
        AddZoneForm(model: model)

        Text("Draw one polygon in geojson.io, Copy it, then Paste into Monitor or ANC.")
          .font(.caption2).foregroundStyle(.tertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
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

/// Monthly FR24 credit usage as a pace bar: remaining fills from the right, a
/// hashmark marks how far through the month we are. If the filled (remaining)
/// region reaches past the hashmark — i.e. used less than time elapsed — usage is
/// on/under pace (green); otherwise it's running ahead (orange).
private struct CreditBar: View {
  let used: Int?
  let budget: Int
  let model: StatusModel

  @State private var syncing = false
  @State private var remainingText = ""

  var body: some View {
    let usedFrac = min(1, max(0, Double(used ?? 0) / Double(max(budget, 1))))
    let remainFrac = 1 - usedFrac
    let elapsed = monthElapsed()
    let onPace = usedFrac <= elapsed

    VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text("Credits this month").font(.caption2).foregroundStyle(.secondary)
        Spacer()
        if let used { Text("\(remaining(used).formatted()) left").font(.caption2.monospaced()) }
        Text(used == nil ? "—" : "\(used!.formatted()) / \(budget.formatted())")
          .font(.caption2.monospaced()).foregroundStyle(.secondary)
        Button(syncing ? "Cancel" : "Sync") { syncing.toggle() }
          .buttonStyle(.plain).font(.caption2).foregroundStyle(.tint)
      }

      GeometryReader { geo in
        let w = geo.size.width
        ZStack(alignment: .leading) {
          Capsule().fill(Color.secondary.opacity(0.18))
          Capsule().fill(onPace ? Color.green : Color.orange)
            .frame(width: w * remainFrac)
            .frame(maxWidth: .infinity, alignment: .trailing)
          Rectangle().fill(Color.primary.opacity(0.75))
            .frame(width: 1.5)
            .offset(x: w * elapsed)
        }
      }
      .frame(height: 8)

      if syncing {
        HStack(spacing: 6) {
          Text("FR24 remaining:").font(.caption2).foregroundStyle(.secondary)
          TextField("e.g. 54239", text: $remainingText)
            .textFieldStyle(.roundedBorder).font(.caption2.monospaced()).frame(width: 80)
          Button("Set") {
            if let n = Int(remainingText.filter(\.isNumber)) {
              model.seedCredits(remaining: n)
              syncing = false
              remainingText = ""
            }
          }
          .font(.caption2)
        }
      }
    }
  }

  private func remaining(_ used: Int) -> Int { max(budget - used, 0) }

  // Fraction of the current month elapsed (day-of-month, with intra-day smoothing).
  private func monthElapsed() -> Double {
    let cal = Calendar.current
    let now = Date()
    let day = cal.component(.day, from: now)
    let hour = cal.component(.hour, from: now)
    let days = cal.range(of: .day, in: .month, for: now)?.count ?? 30
    return min(1, max(0, (Double(day - 1) + Double(hour) / 24) / Double(days)))
  }
}

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
    VStack(alignment: .leading, spacing: 4) {
      Text("ANC timing offset").font(.caption).foregroundStyle(.secondary)
      offsetRow("On", value: $engage)
      offsetRow("Off", value: $release)
    }
  }

  private func offsetRow(_ label: String, value: Binding<Double>) -> some View {
    HStack(spacing: 6) {
      Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: 26, alignment: .leading)
      Slider(value: value, in: -15...15, step: 1) { editing in
        if !editing { model.setAncOffsets(engage: engage, release: release) }
      }
      Text(format(value.wrappedValue)).font(.caption2.monospaced()).frame(width: 36, alignment: .trailing)
    }
  }

  private func format(_ v: Double) -> String {
    let n = Int(v)
    return n > 0 ? "+\(n)s" : "\(n)s"
  }
}

/// One editable zoneset: rename (on submit), copy/paste each zone's GeoJSON, delete.
private struct ZoneEditRow: View {
  let zone: EditableZone
  let model: StatusModel
  @State private var name: String
  @State private var pollSeconds: String
  @FocusState private var focus: Field?

  private enum Field { case name, poll }

  init(zone: EditableZone, model: StatusModel) {
    self.zone = zone
    self.model = model
    _name = State(initialValue: zone.name)
    _pollSeconds = State(initialValue: zone.pollIntervalMs.map { String($0 / 1000) } ?? "")
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        TextField("name", text: $name)
          .textFieldStyle(.roundedBorder)
          .focused($focus, equals: .name)
          .onSubmit { commitName() }
        Button(role: .destructive) {
          Task { await model.deleteZone(zone.id) }
        } label: {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
      }

      slotRow("Monitor", geojson: zone.monitorGeojson, slot: .monitor)
      slotRow("ANC", geojson: zone.ancGeojson, slot: .anc)

      HStack(spacing: 6) {
        Text("Poll every").font(.caption2).foregroundStyle(.secondary)
        TextField("default", text: $pollSeconds)
          .frame(width: 44)
          .focused($focus, equals: .poll)
          .onSubmit { commitPoll() }
        Text("s (blank = global)").font(.caption2).foregroundStyle(.secondary)
      }
      .controlSize(.small)
    }
    .padding(.vertical, 2)
    // Save when a field loses focus (or on Return) so edits aren't lost.
    .onChange(of: focus) { old, _ in
      if old == .name { commitName() }
      if old == .poll { commitPoll() }
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

  private func slotRow(_ label: String, geojson: String, slot: ZoneSlot) -> some View {
    HStack(spacing: 6) {
      Text(label).font(.caption2).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
      Button("Open") { model.openInGeojsonIO(geojson) }
      Button("Paste") { Task { await model.pasteZone(zone.id, slot: slot) } }
    }
    .controlSize(.small)
    .buttonStyle(.bordered)
  }
}

/// Add a new zoneset: name + paste a Monitor polygon + paste an ANC polygon → Create.
private struct AddZoneForm: View {
  let model: StatusModel
  @State private var name = ""
  @State private var monitor: String?
  @State private var anc: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Add a zone").font(.caption).foregroundStyle(.secondary)
      TextField("name", text: $name).textFieldStyle(.roundedBorder)

      HStack(spacing: 6) {
        Button(monitor == nil ? "Paste Monitor" : "Monitor ✓") {
          monitor = NSPasteboard.general.string(forType: .string)
        }
        Button(anc == nil ? "Paste ANC" : "ANC ✓") {
          anc = NSPasteboard.general.string(forType: .string)
        }
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
        .disabled(name.isEmpty || monitor == nil || anc == nil)
      }
      .controlSize(.small)
      .buttonStyle(.bordered)
    }
  }
}
