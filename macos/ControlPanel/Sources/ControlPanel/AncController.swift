import AppKit
import ApplicationServices
import CoreAudio

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
    case adaptive = "Adaptive"
    case off = "Off"
  }

  /// Whether AirPods are the current default audio output. The Control Center
  /// listening-mode controls only exist when AirPods are the active output, so
  /// when this is false there's nothing to switch — the caller should skip.
  static func airPodsAreOutput() -> Bool {
    guard let name = defaultOutputDeviceName() else { return false }
    return name.range(of: "airpods", options: .caseInsensitive) != nil
  }

  /// Whether the active AirPods output is a Pro model (vs Max/other), so the UI can
  /// pick the matching glyph. `nil` when AirPods aren't the current output (caller
  /// should keep the last-known kind).
  static func airPodsOutputIsPro() -> Bool? {
    guard let name = defaultOutputDeviceName(),
      name.range(of: "airpods", options: .caseInsensitive) != nil
    else { return nil }
    return name.range(of: "pro", options: .caseInsensitive) != nil
  }

  /// Full name of the AirPods currently serving as output (e.g. "AirPods Max"), else
  /// nil. This exact name labels their row in the Sound popover, so callers remember it
  /// while connected to know which pair to `reclaim` once they wander off.
  static func airPodsOutputName() -> String? {
    guard let name = defaultOutputDeviceName(),
      name.range(of: "airpods", options: .caseInsensitive) != nil
    else { return nil }
    return name
  }

  /// Pull AirPods that another device has taken (typically an iPhone answering a call)
  /// back to this Mac, by pressing their row in the Control Center Sound popover.
  ///
  /// Driving the UI is the only thing that works, and the alternatives fail in ways that
  /// look like success (all verified on macOS 26):
  ///  - CoreAudio can't help: while the phone owns the audio profile the AirPods vanish
  ///    from the device list entirely, so there is no device to make default.
  ///  - IOBluetooth can't either: `isConnected()` still reports true (the baseband ACL
  ///    link stays with the Mac, decoupled from who owns the audio) and
  ///    `openConnection()` returns success in ~0s without moving any audio.
  ///
  /// The Sound popover lists paired AirPods regardless of connection state, and pressing
  /// the row makes macOS claim the audio profile — exactly what a manual click does.
  ///
  /// Pass the full device name; nil falls back to the first row matching "AirPods".
  /// Returns whether a row was pressed — not whether the audio arrived, which lands
  /// asynchronously and is observed via `airPodsAreOutput()` on a later poll.
  @discardableResult
  static func reclaim(named name: String?) -> Bool {
    let wanted = name ?? "AirPods"
    guard let cc = controlCenterApp(), let soundItem = soundMenuBarItem() else {
      Log.line("reclaim(\(wanted)) — Control Center / Sound menu item not found")
      return false
    }

    let pressed = press(soundItem)
    Thread.sleep(forTimeInterval: 0.5)

    var ok = false
    if let window = (attr(cc, kAXWindowsAttribute as String) as? [AXUIElement])?.first {
      // The label can sit on the row itself or on a descendant, and only some of those
      // elements accept a press — try each match, pressable ones first.
      let matches = findAll(window) { containsLabel($0, wanted) }
        .map { (el: $0, canPress: pressable($0)) }
        .sorted { $0.canPress && !$1.canPress }

      if matches.isEmpty {
        // Log the AirPods rows that ARE present, so a name mismatch (the popover
        // labelling them differently than CoreAudio does) is obvious rather than silent.
        let seen = findAll(window) { containsLabel($0, "AirPods") }
          .compactMap { str($0, kAXTitleAttribute as String) }
        Log.line("reclaim — no row matching \"\(wanted)\"; AirPods rows present: \(Set(seen).sorted())")
      }

      for m in matches where press(m.el) || axPick(m.el) {
        ok = true
        break
      }
    }

    // Same dismissal dance as `set`: selecting a row doesn't reliably close the popover,
    // and the close press no-ops mid-animation, so settle then verify with retries.
    Thread.sleep(forTimeInterval: 0.35)
    var closeAttempts = 0
    while ccWindowCount(cc) > 0 && closeAttempts < 5 {
      _ = press(soundItem)
      closeAttempts += 1
      Thread.sleep(forTimeInterval: 0.3)
    }

    Log.line(
      "reclaim(\(wanted)) pressedSound=\(pressed) rowPressed=\(ok) "
        + "closeAttempts=\(closeAttempts) ccWindowsAfter=\(ccWindowCount(cc))")
    return ok
  }

  private static func defaultOutputDeviceName() -> String? {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)

    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
      deviceID != 0
    else { return nil }

    var name = "" as CFString
    var nameSize = UInt32(MemoryLayout<CFString>.size)
    var nameAddr = AudioObjectPropertyAddress(
      mSelector: kAudioObjectPropertyName,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)

    let status = withUnsafeMutablePointer(to: &name) {
      AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, $0)
    }
    return status == noErr ? (name as String) : nil
  }

  /// Whether this process is trusted for Accessibility (prompts if not).
  @discardableResult
  static func ensureTrusted() -> Bool {
    AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
  }

  /// Set the AirPods listening mode. Returns whether the control was pressed AND the
  /// mode that was selected *before* the press — read while the popover is already
  /// open, so capturing it costs no extra Control Center round-trip. Callers use
  /// `previous` to restore the user's own mode (Transparency, Adaptive, or even
  /// already-ANC) after an overflight instead of forcing Transparency.
  @discardableResult
  static func set(_ mode: Mode) -> (ok: Bool, previous: Mode?) {
    guard let cc = controlCenterApp(), let soundItem = soundMenuBarItem() else {
      Log.line("set(\(mode.rawValue)) — Control Center / Sound menu item not found")
      return (false, nil)
    }

    // Open the Sound popover.
    let pressed = press(soundItem)
    Thread.sleep(forTimeInterval: 0.5)

    var previous: Mode?
    var ok = false
    if let window = (attr(cc, kAXWindowsAttribute as String) as? [AXUIElement])?.first {
      // Read the currently-selected mode before changing it (for restore-on-release).
      previous = selectedMode(in: window)
      if let target = find(window, { matchesLabel($0, mode.rawValue) }) {
        ok = press(target) || axPick(target)
      }
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
        "previous=\(previous?.rawValue ?? "?") " +
        "closeAttempts=\(closeAttempts) ccWindowsAfter=\(ccWindowCount(cc))")
    return (ok, previous)
  }

  /// The listening mode currently selected (checked) in the open Sound popover, or
  /// nil if none reads as selected. Matches modes the same way `set` finds its press
  /// target, so it stays consistent with what we'd switch.
  private static func selectedMode(in window: AXUIElement) -> Mode? {
    for mode in [Mode.anc, .transparency, .adaptive, .off] {
      guard let el = find(window, { matchesLabel($0, mode.rawValue) }) else { continue }
      if let n = attr(el, kAXValueAttribute as String) as? NSNumber, n.intValue == 1 {
        return mode
      }
    }
    return nil
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

  // Substring match (vs `matchesLabel`'s exact compare): output rows carry extra text
  // like a battery percentage alongside the device name.
  private static func containsLabel(_ e: AXUIElement, _ needle: String) -> Bool {
    for key in [kAXTitleAttribute as String, kAXDescriptionAttribute as String] {
      if let v = str(e, key), v.range(of: needle, options: .caseInsensitive) != nil { return true }
    }
    return false
  }

  private static func findAll(_ root: AXUIElement, _ pred: (AXUIElement) -> Bool) -> [AXUIElement] {
    var out: [AXUIElement] = []
    var queue = [root]
    while !queue.isEmpty {
      let e = queue.removeFirst()
      if pred(e) { out.append(e) }
      queue.append(contentsOf: children(e))
    }
    return out
  }

  private static func pressable(_ e: AXUIElement) -> Bool {
    var names: CFArray?
    guard AXUIElementCopyActionNames(e, &names) == .success else { return false }
    return ((names as? [String]) ?? []).contains(kAXPressAction as String)
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
