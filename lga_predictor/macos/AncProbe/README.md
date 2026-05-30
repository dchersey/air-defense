# AncProbe — verify AirPods Max ANC toggling on this Mac

This is a throwaway diagnostic to confirm we can drive AirPods Max
Noise Cancellation / Transparency via the macOS Accessibility API before we wire
it into the real menu-bar app. **It must be run by you, from your own Terminal**,
because it needs interactive Accessibility permission and a physical check that
your headphones actually switch.

## Prerequisites
- AirPods Max connected and set as the audio output device.
- (Recommended) Pin **Sound** to the menu bar: System Settings → Control Center →
  **Sound** → "Always Show in Menu Bar". This gives the probe a direct target.

## Run
```sh
cd macos/AncProbe
swift run AncProbe dump          # opens Sound, prints the AX element tree
```
The first run will prompt for **Accessibility** permission (or print that it's
untrusted). Grant Terminal in System Settings → Privacy & Security →
Accessibility, then re-run.

Then test the actual toggle while watching/listening to your AirPods:
```sh
swift run AncProbe nc            # should switch to Noise Cancellation
swift run AncProbe transparency  # should switch back to Transparency
```

## What to report back
- The `dump` output (the menu-bar item id list + the "Sound popover tree"), and
- whether `nc` / `transparency` physically changed the mode.

That tells me the exact element identifiers to hard-code in the real app and
confirms the approach works on your Tahoe build.
