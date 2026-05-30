// AncProbe — verify AirPods Max ANC/Transparency can be driven via the native
// Accessibility (AXUIElement) API, which exposes Control Center identifiers that
// AppleScript/System Events hides on recent macOS.
//
// Usage:
//   swift run AncProbe dump          # open Sound module, print the element tree
//   swift run AncProbe nc            # set Noise Cancellation
//   swift run AncProbe transparency  # set Transparency
//
// Requires Accessibility permission for whatever runs it (Terminal during dev).
// Run `swift run AncProbe dump` first; it will prompt for permission if missing.

import AppKit
import ApplicationServices

// MARK: - AX helpers

func attr(_ element: AXUIElement, _ key: String) -> AnyObject? {
  var value: AnyObject?
  let result = AXUIElementCopyAttributeValue(element, key as CFString, &value)
  return result == .success ? value : nil
}

func str(_ element: AXUIElement, _ key: String) -> String? {
  attr(element, key) as? String
}

func children(_ element: AXUIElement) -> [AXUIElement] {
  (attr(element, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

func role(_ element: AXUIElement) -> String { str(element, kAXRoleAttribute as String) ?? "" }

/// Describe an element compactly for the dump.
func describe(_ e: AXUIElement) -> String {
  var parts: [String] = [role(e)]
  for key in [
    kAXTitleAttribute as String,
    kAXDescriptionAttribute as String,
    kAXIdentifierAttribute as String,
    kAXValueAttribute as String,
    kAXHelpAttribute as String,
  ] {
    if let v = str(e, key), !v.isEmpty { parts.append("\(key.replacingOccurrences(of: "AX", with: "")): \"\(v)\"") }
  }
  return parts.joined(separator: "  ")
}

/// Depth-first walk, printing the tree (bounded depth/count).
func dump(_ e: AXUIElement, depth: Int = 0, limit: inout Int) {
  if limit <= 0 { return }
  limit -= 1
  print(String(repeating: "  ", count: depth) + describe(e))
  for child in children(e) { dump(child, depth: depth + 1, limit: &limit) }
}

/// Find the first descendant matching `pred` (BFS).
func find(_ root: AXUIElement, _ pred: (AXUIElement) -> Bool) -> AXUIElement? {
  var queue = [root]
  while !queue.isEmpty {
    let e = queue.removeFirst()
    if pred(e) { return e }
    queue.append(contentsOf: children(e))
  }
  return nil
}

func press(_ e: AXUIElement) -> Bool {
  AXUIElementPerformAction(e, kAXPressAction as CFString) == .success
}

// MARK: - Control Center driving

func controlCenterApp() -> AXUIElement? {
  guard
    let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.controlcenter").first
  else { return nil }
  return AXUIElementCreateApplication(app.processIdentifier)
}

/// Open the Sound menu-bar item. Returns the opened window/popover root.
func openSound() -> AXUIElement? {
  guard let cc = controlCenterApp() else {
    print("ERROR: Control Center process not found")
    return nil
  }

  // Menu bar items have empty names via AX on recent macOS, so match by the
  // identifier instead.
  guard let menuBar = firstMenuBar(cc) else {
    print("ERROR: no menu bar on Control Center")
    return nil
  }

  let items = children(menuBar)
  print("Found \(items.count) menu-bar items. Identifiers:")
  for (i, item) in items.enumerated() {
    let ident = str(item, kAXIdentifierAttribute as String) ?? "(no id)"
    let desc = str(item, kAXDescriptionAttribute as String) ?? "(no desc)"
    print("  [\(i)] id=\(ident)  desc=\(desc)")
  }

  // Prefer a pinned Sound item (id "com.apple.menuextra.sound"); otherwise fall
  // back to the Control Center module itself and navigate inside it.
  let sound = items.first { (str($0, kAXIdentifierAttribute as String) ?? "").lowercased().contains("sound") }
    ?? items.first { (str($0, kAXIdentifierAttribute as String) ?? "").lowercased().contains("controlcenter") }

  guard let soundItem = sound else {
    print("Could not identify the Sound/Control-Center item by identifier. See the list above.")
    return nil
  }

  print("Pressing Sound item: \(describe(soundItem))")
  _ = press(soundItem)
  Thread.sleep(forTimeInterval: 0.7)

  // The popover appears as a window of the Control Center app.
  return (attr(cc, kAXWindowsAttribute as String) as? [AXUIElement])?.first
}

func firstMenuBar(_ app: AXUIElement) -> AXUIElement? {
  find(app) { role($0) == "AXMenuBar" }
}

/// Does this element carry `wanted` as its title or description (any role)?
func matchesLabel(_ e: AXUIElement, _ wanted: String) -> Bool {
  for key in [kAXTitleAttribute as String, kAXDescriptionAttribute as String] {
    if let v = str(e, key), v.caseInsensitiveCompare(wanted) == .orderedSame { return true }
  }
  return false
}

func setMode(_ wanted: String) {
  guard let window = openSound() else {
    print("ERROR: Sound popover did not open")
    return
  }

  var limit = 600
  print("\n--- Sound popover tree ---")
  dump(window, limit: &limit)

  // Listening-mode rows ("Off"/"Transparency"/"Adaptive"/"Noise Cancellation")
  // may be checkboxes/menu items, not plain buttons — match by label across any
  // role and try whichever action it supports.
  if let target = find(window, { matchesLabel($0, wanted) }) {
    print("\nFound target: \(describe(target))")
    let ok = press(target) || axPick(target)
    print(ok ? "OK: activated \(wanted)" : "FAILED to activate \(wanted)")
  } else {
    print("\nMode \"\(wanted)\" not visible. The AirPods row may need expanding; see the tree above.")
  }

  if let cc = controlCenterApp() { _ = press(cc) }
}

/// Fallback activation for non-button controls (checkbox/menu item).
func axPick(_ e: AXUIElement) -> Bool {
  for action in ["AXPick", "AXOpen", kAXPressAction as String] {
    if AXUIElementPerformAction(e, action as CFString) == .success { return true }
  }
  // Last resort: set AXValue = 1 (selects a checkbox/radio).
  return AXUIElementSetAttributeValue(e, kAXValueAttribute as CFString, 1 as CFNumber) == .success
}

// MARK: - Main

let args = CommandLine.arguments
let command = args.count > 1 ? args[1] : "dump"

// Trigger the Accessibility prompt if not yet granted. The option key constant
// is a non-Sendable global in Swift 6; use its known string value directly.
let trusted = AXIsProcessTrustedWithOptions(
  ["AXTrustedCheckOptionPrompt": true] as CFDictionary)
print("Accessibility trusted: \(trusted)")
if !trusted {
  print("Grant Accessibility to this binary/Terminal in System Settings → Privacy & Security → Accessibility, then re-run.")
}

/// Print the checked-state (AXValue) of each Listening Mode checkbox — objective
/// proof of which mode is selected, independent of audio.
func listeningModeStates(_ window: AXUIElement) {
  let modes = ["Off", "Transparency", "Adaptive", "Noise Cancellation"]
  // Only the Listening Mode group has these exact labels (besides Conversation
  // Awareness which is just Off/On), so Transparency/Adaptive/Noise Cancellation
  // are unambiguous; first "Off" is Listening Mode's.
  for mode in modes {
    if let e = find(window, { matchesLabel($0, mode) }) {
      let v = attr(e, kAXValueAttribute as String)
      print("  \(mode): value=\(v.map { "\($0)" } ?? "nil")")
    }
  }
}

func verify() {
  guard let window = openSound() else { print("ERROR: popover did not open"); return }
  print("\nListening Mode states (1 = selected):")
  listeningModeStates(window)
  if let cc = controlCenterApp() { _ = press(cc) }
}

/// Open once, read state, click `wanted`, wait, read again — no reopen in between.
func toggleAndVerify(_ wanted: String) {
  guard let window = openSound() else { print("ERROR: popover did not open"); return }

  print("\nBEFORE:")
  listeningModeStates(window)

  guard let target = find(window, { matchesLabel($0, wanted) }) else {
    print("target \(wanted) not found"); return
  }
  let ok = press(target) || axPick(target)
  print("clicked \(wanted): \(ok)")
  Thread.sleep(forTimeInterval: 1.2)

  print("AFTER (same popover):")
  listeningModeStates(window)

  if let cc = controlCenterApp() { _ = press(cc) }
}

switch command {
case "toggle": toggleAndVerify(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "Noise Cancellation")
case "nc": setMode("Noise Cancellation")
case "transparency", "tp": setMode("Transparency")
case "verify", "state": verify()
default:
  if let window = openSound() {
    var limit = 400
    print("\n--- Sound popover tree ---")
    dump(window, limit: &limit)
    if let cc = controlCenterApp() { _ = press(cc) }
  }
}
