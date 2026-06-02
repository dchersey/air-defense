import Foundation

/// Minimal file logger so the menu-bar app's behaviour is observable (it has no
/// console). Appends timestamped lines to ~/Library/Logs/air-defense-app.log.
enum Log {
  private static let url: URL = {
    let dir = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs")
    return dir.appendingPathComponent("air-defense-app.log")
  }()

  private static let formatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
  }()

  static func line(_ message: String) {
    let stamp = formatter.string(from: Date())
    let entry = "\(stamp) \(message)\n"
    guard let data = entry.data(using: .utf8) else { return }

    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      handle.seekToEndOfFile()
      handle.write(data)
    } else {
      try? data.write(to: url)
    }
  }
}
