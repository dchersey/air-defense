#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// AAP listening-mode values, as bluetoothd sends them in AACP control command 0x0D.
typedef NS_ENUM(int, ADMode) {
  ADModeUnknown = 0,
  ADModeOff = 1,
  ADModeNoiseCancellation = 2,
  ADModeTransparency = 3,
  ADModeAdaptive = 4,
};

/// Reads and sets the AirPods listening mode **without** touching the UI — no Control
/// Center, no Accessibility, and none of the sub-second keyboard grab that automation
/// costs. It asks `bluetoothd` (which owns the AAP link to the AirPods) over the same
/// private CoreBluetooth path Control Center itself uses.
///
/// Written in Objective-C on purpose: this drives private API, and Swift cannot catch
/// the NSExceptions that Apple's implementation can raise. Every call here is wrapped,
/// so a failure degrades to "not available" and the caller falls back to automation.
///
/// Private API, so treat availability as a runtime question, never an assumption:
/// `available` can go false after any macOS update and the fallback must stay.
@interface ADListeningMode : NSObject

@property(class, readonly) ADListeningMode *shared;

/// Whether the private path is usable right now. False until `warmUp` finishes, and
/// false forever if any part of the sequence stopped working.
@property(readonly) BOOL available;

/// Begin the (asynchronous) setup: satisfy CoreBluetooth's TCC handshake and bring up
/// the classic manager. Safe to call repeatedly; only the first call does work. Call it
/// at launch so the first real switch doesn't pay the setup cost.
- (void)warmUp;

/// Current mode for a Bluetooth device address, or `ADModeUnknown`.
/// Address may be in any separator style ("70:F9:4A:8E:67:F3", "70-f9-...").
- (ADMode)currentModeForAddress:(NSString *)address;

/// Set the mode. Returns NO if the private path isn't usable or the device wasn't found,
/// in which case the caller should fall back to Control Center automation.
- (BOOL)setMode:(ADMode)mode forAddress:(NSString *)address;

@end

NS_ASSUME_NONNULL_END
