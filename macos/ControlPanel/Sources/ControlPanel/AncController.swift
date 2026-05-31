import AppKit
import ApplicationServices

/// Drives AirPods Max noise control by automating the macOS Control Center Sound
/// popover via the Accessibility API. This is the ONLY mechanism confirmed to
/// actually change the listening mode on macOS 26 (Tahoe) — Shortcuts, the private
/// AVFoundation/IOBluetooth APIs, and AirBuddy's synthetic hotkey all failed.
///
/// The Sound popover becomes the key window (it grabs the keyboard) but does NOT
/// change the active application — so `set(_:)` dismisses it by pressing the same
/// menu-bar item again, which toggles it shut and returns the keyboard to the
/// still-frontmost app the user was working in. (App-activation APIs don't help:
/// the active app never changed, and they're ignored for a background agent under
/// macOS 14+ cooperative activation anyway.)
///
/// Requires Accessibility permission, the Sound module pinned to the menu bar
/// (com.apple.menuextra.sound), and AirPods connected as output.
enum AncController {
  enum Mode: String {
    case anc = "Noise Cancellation"
    case transparency = "Transparency"
  }

  /// Whether this process is trusted for Accessibility (prompts if not).
  @discardableResult
  static func ensureTrusted() -> Bool {
    AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
  }

  /// Set the AirPods listening mode. Returns true if the control was pressed.
  @discardableResult
  static func set(_ mode: Mode) -> Bool {
    guard let cc = controlCenterApp(), let soundItem = soundMenuBarItem() else {
      Log.line("set(\(mode.rawValue)) — Control Center / Sound menu item not found")
      return false
    }

    // Open the Sound popover.
    let pressed = press(soundItem)
    Thread.sleep(forTimeInterval: 0.5)

    let ok: Bool =
      if let window = (attr(cc, kAXWindowsAttribute as String) as? [AXUIElement])?.first,
         let target = find(window, { matchesLabel($0, mode.rawValue) }) {
        press(target) || axPick(target)
      } else {
        false
      }

    // Close the popover by toggling the same menu-bar item again. The popover is
    // a Control Center *window* that becomes the key window (it grabs the
    // keyboard) WITHOUT changing the active application — the previously-frontmost
    // app stays frontmost the whole time. So there is nothing to "re-focus", and
    // activating another app cannot dismiss it; pressing the item that opened it
    // toggles it shut, which returns key-window status (the keyboard) to the user.
    //
    // Selecting a mode does NOT auto-close it. The close press is timing-sensitive
    // right after selection (it no-ops mid-animation), so settle, then verify the
    // popover actually went away and retry a few times.
    Thread.sleep(forTimeInterval: 0.35)
    var closeAttempts = 0
    while ccWindowCount(cc) > 0 && closeAttempts < 5 {
      _ = press(soundItem)
      closeAttempts += 1
      Thread.sleep(forTimeInterval: 0.3)
    }

    Log.line(
      "set(\(mode.rawValue)) pressedSound=\(pressed) toggled=\(ok) " +
        "closeAttempts=\(closeAttempts) ccWindowsAfter=\(ccWindowCount(cc))")
    return ok
  }

  // How many windows Control Center exposes — its Sound popover IS such a window,
  // so >0 after we try to dismiss means the popover is still open.
  private static func ccWindowCount(_ cc: AXUIElement) -> Int {
    (attr(cc, kAXWindowsAttribute as String) as? [AXUIElement])?.count ?? 0
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

  /// The pinned Sound menu-bar item (id contains "sound").
  private static func soundMenuBarItem() -> AXUIElement? {
    guard let cc = controlCenterApp(), let menuBar = find(cc, { role($0) == "AXMenuBar" })
    else { return nil }

    return children(menuBar).first {
      (str($0, kAXIdentifierAttribute as String) ?? "").lowercased().contains("sound")
    }
  }
}
