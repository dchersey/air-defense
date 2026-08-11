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
    // Enter via the Control Center item, NOT the Sound one that `set` uses. Sound is a
    // separate menu extra only when pinned "Always Show"; on the common "Show When
    // Active" setting it disappears once the AirPods leave and output falls back to
    // built-in — precisely the state every reclaim runs in. Control Center is always
    // present, and carries the same device list one level in.
    guard let cc = controlCenterApp(), let ccItem = menuBarItem(idContains: "controlcenter")
    else {
      Log.line("reclaim(\(wanted)) — Control Center menu item not found; \(menuBarDiagnostic())")
      return false
    }

    let pressed = press(ccItem)
    Thread.sleep(forTimeInterval: 0.9)

    guard let window = (attr(cc, kAXWindowsAttribute as String) as? [AXUIElement])?.first,
      let tile = find(window, { str($0, kAXIdentifierAttribute as String) == "controlcenter-volume" })
    else {
      Log.line("reclaim(\(wanted)) — Sound tile not found in Control Center")
      dismiss(cc, ccItem)
      return false
    }

    // Expand the Sound tile into its Output list. AXPress on the tile toggles rather
    // than expands, so prefer the explicit "show details" action when offered.
    if let detail = actionNames(tile).first(where: { $0.lowercased().contains("show details") }) {
      _ = AXUIElementPerformAction(tile, detail as CFString)
    } else {
      _ = press(tile)
    }
    Thread.sleep(forTimeInterval: 1.0)

    var ok = false
    if let expanded = (attr(cc, kAXWindowsAttribute as String) as? [AXUIElement])?.first {
      // Match the exact identifier and require AXCheckBox. The row's *description*
      // carries a battery suffix ("AirPods Pro #2, 95%") so substring matching on labels
      // is brittle, and a disclosure triangle (the listening-mode chevron) shares the
      // very same identifier — pressing that expands the submenu instead of switching
      // output.
      let wantID = "sound-device-\(wanted)"
      let rows = findAll(expanded) { str($0, kAXIdentifierAttribute as String) == wantID }

      if let row = rows.first(where: { role($0) == "AXCheckBox" }) {
        ok = press(row)
      } else {
        let available = findAll(expanded) {
          (str($0, kAXIdentifierAttribute as String) ?? "").hasPrefix("sound-device-")
            && role($0) == "AXCheckBox"
        }
        .compactMap { str($0, kAXIdentifierAttribute as String) }
        Log.line("reclaim — no output row \"\(wantID)\"; available: \(available)")
      }
    }

    dismiss(cc, ccItem)
    Log.line("reclaim(\(wanted)) pressedCC=\(pressed) rowPressed=\(ok)")
    return ok
  }

  /// Toggle a Control Center popover shut, verifying it actually went away — the close
  /// press no-ops mid-animation, so settle first and retry.
  private static func dismiss(_ cc: AXUIElement, _ item: AXUIElement) {
    Thread.sleep(forTimeInterval: 0.35)
    var attempts = 0
    while ccWindowCount(cc) > 0 && attempts < 5 {
      _ = press(item)
      attempts += 1
      Thread.sleep(forTimeInterval: 0.3)
    }
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

  private static func actionNames(_ e: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(e, &names) == .success else { return [] }
    return (names as? [String]) ?? []
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

  /// Why the Sound menu-bar item wasn't found — distinguishes "Control Center missing",
  /// "menu bar not enumerable" (what an open menu-bar window causes) and "item renamed
  /// or unpinned", which otherwise all surface as the same silent nil.
  private static func menuBarDiagnostic() -> String {
    guard let cc = controlCenterApp() else { return "controlCenterApp=nil" }
    guard let menuBar = find(cc, { role($0) == "AXMenuBar" }) else {
      return "menuBar=nil (not enumerable)"
    }
    let ids = children(menuBar).map { str($0, kAXIdentifierAttribute as String) ?? "?" }
    return "menuBarChildren=\(ids.count) ids=\(ids)"
  }

  private static func controlCenterApp() -> AXUIElement? {
    NSRunningApplication
      .runningApplications(withBundleIdentifier: "com.apple.controlcenter")
      .first
      .map { AXUIElementCreateApplication($0.processIdentifier) }
  }

  /// The pinned Sound menu-bar item (id contains "sound"). Only present when Sound is
  /// pinned "Always Show", or while it's active — see `reclaim` for why that matters.
  private static func soundMenuBarItem() -> AXUIElement? { menuBarItem(idContains: "sound") }

  /// A Control Center menu-bar item whose identifier contains `needle`.
  private static func menuBarItem(idContains needle: String) -> AXUIElement? {
    guard let cc = controlCenterApp(), let menuBar = find(cc, { role($0) == "AXMenuBar" })
    else { return nil }

    return children(menuBar).first {
      (str($0, kAXIdentifierAttribute as String) ?? "").lowercased().contains(needle)
    }
  }
}
