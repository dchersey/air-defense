#import "ADListeningMode.h"
#import <CoreBluetooth/CoreBluetooth.h>
#import <dlfcn.h>
#import <os/log.h>

// Private CoreBluetooth surface. Declared rather than imported — these live in
// CBClassicManager / CBClassicPeer / CBManager and have no public headers.
@interface NSObject (ADPrivateCoreBluetooth)
- (instancetype)initWithQueue:(dispatch_queue_t)queue options:(nullable NSDictionary *)options;
- (void)sendLocalDeviceStateRequest;
- (void)performTCCCheck;
- (BOOL)tccApproved;
- (void)setTccApproved:(BOOL)approved;
- (nullable id)retrievePairedPeersWithOptions:(nullable NSDictionary *)options;
- (nullable NSMapTable *)peers;
- (nullable NSString *)addressString;
- (unsigned char)listeningMode;
- (void)setListeningMode:(unsigned char)mode;
@end

static os_log_t ADLog(void) {
  static os_log_t log;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ log = os_log_create("org.hersey.airdefense", "listeningmode"); });
  return log;
}

/// Hex digits only, lowercased — the two sides spell addresses differently
/// (IOBluetooth "70-f9-4a-8e-67-f3" vs CBClassicPeer "70:F9:4A:8E:67:F3").
static NSString *ADNormalizeAddress(NSString *address) {
  NSMutableString *out = [NSMutableString stringWithCapacity:12];
  for (NSUInteger i = 0; i < address.length; i++) {
    unichar c = [address characterAtIndex:i];
    if (isxdigit(c)) [out appendFormat:@"%c", tolower(c)];
  }
  return out;
}

@interface ADCentralDelegate : NSObject <CBCentralManagerDelegate>
@property(nonatomic, strong) dispatch_semaphore_t ready;
@property(nonatomic) BOOL signalled;
@end

@implementation ADCentralDelegate
- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
  if (central.state == CBManagerStatePoweredOn && !self.signalled) {
    self.signalled = YES;
    dispatch_semaphore_signal(self.ready);
  }
}
@end

@implementation ADListeningMode {
  dispatch_queue_t _queue;              // CoreBluetooth objects here are queue-affine
  CBCentralManager *_central;
  ADCentralDelegate *_delegate;
  id _classic;                          // CBClassicManager
  BOOL _available;
  BOOL _warmUpStarted;
}

+ (ADListeningMode *)shared {
  static ADListeningMode *shared;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ shared = [[ADListeningMode alloc] init]; });
  return shared;
}

- (instancetype)init {
  if ((self = [super init])) {
    _queue = dispatch_queue_create("org.hersey.airdefense.listeningmode", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (BOOL)available { return _available; }

- (void)warmUp {
  @synchronized(self) {
    if (_warmUpStarted) return;
    _warmUpStarted = YES;
  }
  // Off the caller's thread: the TCC handshake below waits on a callback delivered to
  // _queue, so blocking _queue (or the main thread) here would deadlock or stall the UI.
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [self setUp]; });
}

- (void)setUp {
  @try {
    // 1. CoreBluetooth TCC. bluetoothd parks every client at access level 0 and
    //    withholds device data until a real central reaches poweredOn.
    _delegate = [ADCentralDelegate new];
    _delegate.ready = dispatch_semaphore_create(0);
    _central = [[CBCentralManager alloc] initWithDelegate:_delegate queue:_queue];
    if (dispatch_semaphore_wait(_delegate.ready,
                                dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) != 0) {
      os_log(ADLog(), "warmUp: central never powered on");
      return;
    }

    dispatch_sync(_queue, ^{ [self rebuildClassicLocked]; });
  } @catch (NSException *e) {
    os_log_error(ADLog(), "warmUp threw %{public}@", e.name);
    _available = NO;
  }

  // A failed warm-up must not be permanent: the very first launch typically runs before
  // the user has answered the Bluetooth prompt, so it times out. Clear the latch and the
  // next poll retries.
  if (!_available) {
    @synchronized(self) { _warmUpStarted = NO; }
    os_log(ADLog(), "warmUp: not available — will retry");
  }
}

/// (Re)create the classic manager and re-satisfy the TCC gate. Must run on _queue.
/// Also used to recover mid-session: bluetoothd drops idle classic sessions, after which
/// peer lookups silently return nothing.
- (BOOL)rebuildClassicLocked {
  @try {
    Class cls = NSClassFromString(@"CBClassicManager");
    if (!cls) { os_log(ADLog(), "no CBClassicManager"); _available = NO; return NO; }
    _classic = [[cls alloc] initWithQueue:_queue options:nil];
    if (!_classic) { os_log(ADLog(), "classic manager init failed"); _available = NO; return NO; }
    [_classic sendLocalDeviceStateRequest];

    // The gate. -[CBClassicManager retrievePairedPeersWithOptions:] opens with
    // `if (![self tccApproved]) return nil;` and sends no XPC at all when false.
    // bluetoothd has already approved the session by this point; the client-side flag
    // simply doesn't get set, so nudge it and then set it directly.
    if ([_classic respondsToSelector:@selector(performTCCCheck)]) [_classic performTCCCheck];
    if ([_classic respondsToSelector:@selector(tccApproved)] && ![_classic tccApproved] &&
        [_classic respondsToSelector:@selector(setTccApproved:)]) {
      [_classic setTccApproved:YES];
    }
    _available = [_classic respondsToSelector:@selector(retrievePairedPeersWithOptions:)];
    os_log(ADLog(), "classic session ready: available=%{public}d", (int)_available);
    return _available;
  } @catch (NSException *e) {
    os_log_error(ADLog(), "rebuild threw %{public}@", e.name);
    _available = NO;
    return NO;
  }
}

/// Every paired classic peer bluetoothd knows about. Must run on _queue.
- (NSArray *)peersLocked {
  NSMutableArray *peers = [NSMutableArray array];
  @try {
    static NSString *pairedKey;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      void *handle = dlopen("/System/Library/Frameworks/CoreBluetooth.framework/CoreBluetooth",
                            RTLD_NOW);
      void **symbol = handle ? (void **)dlsym(handle, "CBClassicManagerOptionPairedKey") : NULL;
      pairedKey = symbol ? (__bridge NSString *)*symbol : nil;
    });
    NSDictionary *options = pairedKey ? @{pairedKey: @YES} : @{};
    id result = [_classic retrievePairedPeersWithOptions:options];
    if ([result isKindOfClass:NSArray.class]) [peers addObjectsFromArray:result];
    if (peers.count == 0) {
      NSMapTable *table = [_classic peers];
      for (id peer in table.objectEnumerator.allObjects) [peers addObject:peer];
    }
  } @catch (NSException *e) {
    os_log_error(ADLog(), "peers threw %{public}@", e.name);
  }
  return peers;
}

- (nullable id)lookupPeerLocked:(NSString *)needle {
  for (id peer in [self peersLocked]) {
    @try {
      NSString *addr = [peer addressString];
      if (addr && [ADNormalizeAddress(addr) isEqualToString:needle]) return peer;
    } @catch (NSException *e) { /* skip a peer that misbehaves */ }
  }
  return nil;
}

- (nullable id)peerForAddressLocked:(NSString *)wanted {
  NSString *needle = ADNormalizeAddress(wanted);
  if (needle.length == 0) return nil;
  id peer = [self lookupPeerLocked:needle];
  if (peer) return peer;

  // Empty lookup usually means the classic session went stale — bluetoothd tears down
  // idle ones, and afterwards every retrieve quietly returns nothing. Rebuild once and
  // retry before giving up and letting the caller fall back to UI automation.
  os_log(ADLog(), "peer lookup empty — rebuilding classic session");
  if ([self rebuildClassicLocked]) peer = [self lookupPeerLocked:needle];
  return peer;
}

- (ADMode)currentModeForAddress:(NSString *)address {
  // Only the central is a hard requirement (it carries the TCC approval). A missing or
  // stale classic manager is recoverable — peerForAddressLocked rebuilds it.
  if (!_central) return ADModeUnknown;
  __block ADMode mode = ADModeUnknown;
  dispatch_sync(_queue, ^{
    @try {
      id peer = [self peerForAddressLocked:address];
      if (peer) {
        unsigned char raw = [peer listeningMode];
        if (raw >= ADModeOff && raw <= ADModeAdaptive) mode = (ADMode)raw;
      }
    } @catch (NSException *e) {
      os_log_error(ADLog(), "currentMode threw %{public}@", e.name);
    }
  });
  return mode;
}

- (BOOL)setMode:(ADMode)mode forAddress:(NSString *)address {
  if (!_central) return NO;
  if (mode < ADModeOff || mode > ADModeAdaptive) return NO;
  __block BOOL ok = NO;
  dispatch_sync(_queue, ^{
    @try {
      id peer = [self peerForAddressLocked:address];
      if (!peer) { os_log(ADLog(), "setMode: no peer for %{public}@", address); return; }
      [peer setListeningMode:(unsigned char)mode];
      ok = YES;
    } @catch (NSException *e) {
      os_log_error(ADLog(), "setMode threw %{public}@", e.name);
    }
  });
  return ok;
}

@end
