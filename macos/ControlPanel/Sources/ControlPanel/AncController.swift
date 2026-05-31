import AppKit
import ApplicationServices

/// Drives AirPods Max noise control by automating the macOS Control Center Sound
/// popover via the Accessibility API. This is the ONLY mechanism confirmed to
/// actually change the listening mode on macOS 26 (Tahoe) — Shortcuts, the private
/// AVFoundation/IOBluetooth APIs, and AirBuddy's synthetic hotkey all failed.
///
/// To avoid the two warts of naive Control Center automation (it steals keyboard
/// focus and the popover lingers), `set(_:)` captures the frontmost app before
/// opening Control Center and **reactivates it afterward**. Reactivating another
/// app makes the Control Center popover resign key — which both dismisses it and
/// returns keyboard focus to wherever the user was working.
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

    // Remember who had focus so we can hand it back (and dismiss the popover).
    // If WE are frontmost (user just clicked our menu-bar item), reactivating
    // ourselves does NOT make Control Center resign key — so the popover lingers
    // and focus stays stolen. Detect that and fall back to Finder.
    let previousApp = NSWorkspace.shared.frontmostApplication
    let prevId = previousApp?.bundleIdentifier
    let prevIsSelf = prevId == nil || prevId == Bundle.main.bundleIdentifier
    Log.line("set(\(mode.rawValue)) open: previousApp=\(prevId ?? "nil") isSelf=\(prevIsSelf)")

    let pressed = press(soundItem)
    Thread.sleep(forTimeInterval: 0.5)

    let ok: Bool =
      if let window = (attr(cc, kAXWindowsAttribute as String) as? [AXUIElement])?.first,
         let target = find(window, { matchesLabel($0, mode.rawValue) }) {
        press(target) || axPick(target)
      } else {
        false
      }
    Log.line("set(\(mode.rawValue)) pressedSound=\(pressed) toggled=\(ok)")

    // Activate another app to dismiss the popover (it resigns key) and restore
    // keyboard focus. NOTE: bare `activate()` is deprecated and a no-op on Tahoe;
    // `.activateIgnoringOtherApps` is what actually works (verified 2026-05-31).
    Thread.sleep(forTimeInterval: 0.2)
    let dismisser = prevIsSelf ? finderApp() : previousApp
    dismisser?.activate(options: [.activateIgnoringOtherApps])
    Log.line("set(\(mode.rawValue)) close: activated=\(dismisser?.bundleIdentifier ?? "nil")")

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

  /// Finder — a guaranteed-running app to activate when we can't hand focus back
  /// to a real previous app (e.g. we were frontmost), forcing the popover closed.
  private static func finderApp() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
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
