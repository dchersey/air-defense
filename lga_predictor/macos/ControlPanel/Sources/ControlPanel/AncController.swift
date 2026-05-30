import AppKit
import ApplicationServices

/// Drives AirPods Max noise control by automating the macOS Control Center Sound
/// popover via the native Accessibility API. Verified working on macOS 26 (Tahoe):
/// the Listening Mode rows are AXCheckBoxes whose AXDescription is
/// "Noise Cancellation" / "Transparency". Pressing one is idempotent.
///
/// Requires Accessibility permission for this app, the Sound module pinned to the
/// menu bar (com.apple.menuextra.sound), and AirPods connected as output.
enum AncController {
  enum Mode: String {
    case anc = "Noise Cancellation"
    case transparency = "Transparency"
  }

  // MARK: - Public

  /// Whether this process is trusted for Accessibility (prompts if not).
  @discardableResult
  static func ensureTrusted() -> Bool {
    AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
  }

  /// Set the AirPods listening mode. Returns true if the control was found+pressed.
  @discardableResult
  static func set(_ mode: Mode) -> Bool {
    guard let window = openSound() else { return false }
    defer { closeControlCenter() }

    guard let target = find(window, { matchesLabel($0, mode.rawValue) }) else { return false }
    return press(target) || axPick(target)
  }

  // MARK: - AX helpers

  private static func attr(_ e: AXUIElement, _ key: String) -> AnyObject? {
    var value: AnyObject?
    return AXUIElementCopyAttributeValue(e, key as CFString, &value) == .success ? value : nil
  }

  private static func str(_ e: AXUIElement, _ key: String) -> String? {
    attr(e, key) as? String
  }

  private static func children(_ e: AXUIElement) -> [AXUIElement] {
    (attr(e, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
  }

  private static func role(_ e: AXUIElement) -> String { str(e, kAXRoleAttribute as String) ?? "" }

  private static func matchesLabel(_ e: AXUIElement, _ wanted: String) -> Bool {
    for key in [kAXTitleAttribute as String, kAXDescriptionAttribute as String] {
      if let v = str(e, key), v.caseInsensitiveCompare(wanted) == .orderedSame { return true }
    }
    return false
  }

  private static func find(_ root: AXUIElement, _ pred: (AXUIElement) -> Bool) -> AXUIElement? {
    var queue = [root]
    while !queue.isEmpty {
      let e = queue.removeFirst()
      if pred(e) { return e }
      queue.append(contentsOf: children(e))
    }
    return nil
  }

  private static func press(_ e: AXUIElement) -> Bool {
    AXUIElementPerformAction(e, kAXPressAction as CFString) == .success
  }

  private static func axPick(_ e: AXUIElement) -> Bool {
    for action in ["AXPick", "AXOpen", kAXPressAction as String] {
      if AXUIElementPerformAction(e, action as CFString) == .success { return true }
    }
    return AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, 1 as CFNumber) == .success
  }

  // MARK: - Control Center

  private static func controlCenterApp() -> AXUIElement? {
    NSRunningApplication
      .runningApplications(withBundleIdentifier: "com.apple.controlcenter")
      .first
      .map { AXUIElementCreateApplication($0.processIdentifier) }
  }

  private static func openSound() -> AXUIElement? {
    guard let cc = controlCenterApp(), let menuBar = find(cc, { role($0) == "AXMenuBar" })
    else { return nil }

    let sound = children(menuBar).first {
      (str($0, kAXIdentifierAttribute as String) ?? "").lowercased().contains("sound")
    }
    guard let soundItem = sound else { return nil }

    _ = press(soundItem)
    Thread.sleep(forTimeInterval: 0.5)

    return (attr(cc, kAXWindowsAttribute as String) as? [AXUIElement])?.first
  }

  private static func closeControlCenter() {
    if let cc = controlCenterApp(), let win = (attr(cc, kAXWindowsAttribute as String) as? [AXUIElement])?.first {
      _ = press(win)  // dismiss; harmless if already closed
    }
  }
}
