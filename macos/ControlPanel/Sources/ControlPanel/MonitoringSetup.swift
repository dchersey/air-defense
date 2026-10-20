import SwiftUI
import UniformTypeIdentifiers

struct SettingsFile: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }
  var data: Data
  init(data: Data = Data()) { self.data = data }
  init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct MonitoringSetup: View {
  let model: StatusModel
  @State private var profile = "basic"
  @State private var values: [String: String] = [:]
  @State private var loaded = false
  @State private var busy = false
  @State private var message: String?
  @State private var importing = false
  @State private var exporting = false
  @State private var document = SettingsFile()
  @State private var pending: Data?
  @State private var preview = ""
  private let fields = [
    ("home_lat", "Home latitude"), ("home_lon", "Home longitude"),
    ("airport_lat", "Airport latitude"), ("airport_lon", "Airport longitude"),
    ("global_ceiling_ft", "Altitude ceiling · ft"),
    ("anc_latency_seconds", "ANC response delay · sec"),
    ("acoustic_decay_seconds", "Sound after closest pass · sec"),
    ("max_dwell_seconds", "Maximum predicted dwell · sec")
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Monitoring setup").font(.adTitle)
      Picker("Mode", selection: $profile) {
        Text("Basic monitoring").tag("basic")
        Text("LGA / Rego Park").tag("lga_personal")
      }.pickerStyle(.menu)
      Text(profile == "basic"
        ? "Zone-based ANC and flight history, without airport-specific route recognition."
        : "Personal LGA route recognition, departure tracks, route history and calibrated departure timing.")
        .font(.adMono).foregroundStyle(Palette.ink2)
      DisclosureGroup("Location and noise settings") {
        VStack(spacing: 7) {
          ForEach(fields, id: \.0) { key, label in
            HStack {
              Text(label).font(.adMono)
              Spacer()
              TextField("Optional", text: Binding(get: { values[key] ?? "" }, set: { values[key] = $0 }))
                .textFieldStyle(.roundedBorder).frame(width: 100)
                .accessibilityLabel(label)
            }
          }
          Text("Use decimal degrees. Leave both coordinates blank if unknown. Home anchors ANC release; airport is optional in Basic mode. Draw detection and noise areas in Edit zones.")
            .font(.adMono).foregroundStyle(Palette.ink2)
        }.padding(.top, 6)
      }
      Button("Save setup") { Task { await save() } }
        .disabled(!loaded || busy || model.active)
      if model.active {
        Text("Stop monitoring before changing setup or importing settings.").font(.adMono).foregroundStyle(Palette.ink2)
      }
      DisclosureGroup("Custom route modules") {
        Text("LGA / Rego Park is an optional, location-specific module. Basic monitoring does not use it. Developers can adapt the module directly or with AI assistance; see Customizations in the README. No route editor is required.")
          .font(.adMono).foregroundStyle(Palette.ink2).padding(.top, 6)
      }
      HStack {
        Button("Export settings…") { Task { await exportSettings() } }.disabled(busy)
        Button("Import settings…") { importing = true }.disabled(busy || model.active)
      }
      Text("Includes locations, receiver address, zones and timing. Excludes keys, URL credentials, listening devices, history and Mac preferences. Exported locations are personal.")
        .font(.adMono).foregroundStyle(Palette.ink3)
      if pending != nil {
        Text(preview).font(.adMono).textSelection(.enabled)
        HStack {
          Button("Replace settings") { Task { await applyImport() } }.disabled(busy || model.active)
          Button("Cancel") { pending = nil }
        }
      }
      if let message { Text(message).font(.adMono).foregroundStyle(Palette.ink2) }
    }
    .task { await load() }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
      do {
        let url = try result.get()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 1_000_000 else { throw failure("Settings file exceeds 1 MB") }
        let data = try Data(contentsOf: url)
        guard let packet = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          packet["format"] as? String == "air-defense-settings", packet["version"] as? Int == 1,
          let settings = packet["settings"] as? [String: Any],
          let zones = settings["zonesets"] as? [[String: Any]] else { throw failure("Not an Air Defense settings file") }
        preview = "Replace setup with \(settings["route_profile"] as? String ?? "basic")\nData source: \(settings["provider"] as? String ?? "local")\nReceiver: \(settings["local_feed_url"] as? String ?? "default")\nHome: \(settings["home_lat"] ?? "—"), \(settings["home_lon"] ?? "—")\nAirport: \(settings["airport_lat"] ?? "—"), \(settings["airport_lon"] ?? "—")\n\(zones.count) zones: \(zones.compactMap { $0["name"] as? String }.joined(separator: ", "))\nThe previous setup will be backed up locally. Keys stay unchanged."
        pending = data
        message = nil
      } catch { message = error.localizedDescription }
    }
    .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "Air Defense settings") { result in
      if case .failure(let error) = result { message = error.localizedDescription }
    }
  }

  private func failure(_ text: String) -> NSError { NSError(domain: "Settings", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
  private func request(_ path: String, method: String = "GET", data: Data? = nil) async throws -> Data {
    var req = URLRequest(url: URL(string: "http://127.0.0.1:4040\(path)")!)
    req.httpMethod = method
    req.httpBody = data
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let (body, response) = try await URLSession.shared.data(for: req)
    guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
      let detail = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
      throw failure(detail?["error"] as? String ?? "Settings request failed")
    }
    return body
  }
  private func load() async {
    do {
      let data = try await request("/api/config")
      let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
      profile = raw["route_profile"] as? String ?? "basic"
      for (key, _) in fields { values[key] = (raw[key] as? NSNumber)?.stringValue ?? "" }
      loaded = true
    } catch { message = error.localizedDescription }
  }
  private func save() async {
    busy = true
    defer { busy = false }
    do {
      var raw: [String: Any] = ["route_profile": profile]
      for (key, label) in fields {
        let text = (values[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty && (key.hasSuffix("_lat") || key.hasSuffix("_lon")) { raw[key] = NSNull() }
        else if let value = Double(text), value.isFinite { raw[key] = value }
        else { throw failure("Enter a number for \(label)") }
      }
      _ = try await request("/api/config", method: "PUT", data: JSONSerialization.data(withJSONObject: raw))
      await model.refresh()
      message = "Setup saved"
    } catch { message = error.localizedDescription }
  }
  private func exportSettings() async {
    busy = true
    defer { busy = false }
    do { document = SettingsFile(data: try await request("/api/settings/export")); exporting = true }
    catch { message = error.localizedDescription }
  }
  private func applyImport() async {
    guard let pending else { return }
    busy = true
    defer { busy = false }
    do {
      _ = try await request("/api/settings/import", method: "POST", data: pending)
      self.pending = nil
      await load()
      await model.refresh()
      message = "Settings imported; previous setup backed up"
    } catch { message = error.localizedDescription }
  }
}
