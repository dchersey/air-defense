-- Standalone test: dump Control Center menu-bar item names, then try to open Sound.
-- Run from YOUR terminal:  osascript scripts/anc_test.applescript
tell application "System Events"
  tell process "ControlCenter"
    set itemNames to name of every menu bar item of menu bar 1
    log "Menu bar item names: " & (itemNames as string)
  end tell
end tell
