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
    guard let cc = controlCenterApp(), let soundItem = soundMenuBarItem() else { return false }

    // Open the Sound popover (AXPress works for opening and doesn't move the cursor).
    _ = press(soundItem)
    Thread.sleep(forTimeInterval: 0.5)

    let ok: Bool =
      if let window = (attr(cc, kAXWindowsAttribute as String) as? [AXUIElement])?.first,
         let target = find(window, { matchesLabel($0, mode.rawValue) }) {
        press(target) || axPick(target)
      } else {
        false
      }

    // Close by a real synthetic click on the Sound item — AXPress and Escape do
    // NOT dismiss the popover on this machine (verified via AncProbe). The click
    // warps the cursor, so we save and restore it.
    Thread.sleep(forTimeInterval: 0.2)
    clickElement(soundItem)
    return ok
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

  /// The pinned Sound menu-bar item (id "com.apple.menuextra.sound").
  private static func soundMenuBarItem() -> AXUIElement? {
    guard let cc = controlCenterApp(), let menuBar = find(cc, { role($0) == "AXMenuBar" })
    else { return nil }

    return children(menuBar).first {
      (str($0, kAXIdentifierAttribute as String) ?? "").lowercased().contains("sound")
    }
  }

  /// Real synthetic left-click at an element's center, restoring the cursor
  /// afterward (the click warps it). Used to dismiss the Sound popover, which
  /// AXPress/Escape don't close reliably on this machine.
  private static func clickElement(_ e: AXUIElement) {
    var pos = CGPoint.zero, size = CGSize.zero
    guard let pv = attr(e, kAXPositionAttribute as String),
          let sv = attr(e, kAXSizeAttribute as String) else { return }
    AXValueGetValue(pv as! AXValue, .cgPoint, &pos)
    AXValueGetValue(sv as! AXValue, .cgSize, &size)
    let center = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)

    let saved = CGEvent(source: nil)?.location
    let src = CGEventSource(stateID: .combinedSessionState)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left)?.post(tap: .cghidEventTap)
    CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left)?.post(tap: .cghidEventTap)
    if let saved { CGWarpMouseCursorPosition(saved) }
  }

}
