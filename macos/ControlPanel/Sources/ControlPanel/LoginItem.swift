import ServiceManagement

/// Wraps registering this menu-bar app as a macOS login item via the modern
/// SMAppService API (no helper bundle needed). The toggle in the panel reads and
/// writes this.
enum LoginItem {
  static var isEnabled: Bool {
    SMAppService.mainApp.status == .enabled
  }

  /// Returns the new enabled-state after attempting the change.
  @discardableResult
  static func setEnabled(_ enabled: Bool) -> Bool {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      NSLog("LoginItem toggle failed: \(error)")
    }
    return isEnabled
  }
}
