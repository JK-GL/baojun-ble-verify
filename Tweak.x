#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static BOOL alertShown = NO;

static void ShowAlert(NSString *title, NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (alertShown) return;
        alertShown = YES;
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                                  message:msg
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Copy" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *_) {
            UIPasteboard.generalPasteboard.string = msg ?: @"";
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
        UIViewController *top = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
            if ([s isKindOfClass:UIWindowScene.class]) {
                for (UIWindow *w in ((UIWindowScene *)s).windows) {
                    if (w.isKeyWindow) { top = w.rootViewController; break; }
                }
            }
            if (top) break;
        }
        while (top.presentedViewController) top = top.presentedViewController;
        if (top) [top presentViewController:a animated:YES completion:nil];
    });
}

// -- Helper: dump any object as readable text --
static NSString *DumpObject(id obj, int depth) {
    if (!obj || obj == [NSNull null]) return @"(null)";
    if (depth > 3) return @"...";

    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableString *s = [NSMutableString string];
        [s appendString:@"{\n"];
        for (NSString *key in obj) {
            id val = [obj objectForKey:key];
            [s appendFormat:@"  %@ = %@\n", key, DumpObject(val, depth + 1)];
        }
        [s appendString:@"}"];
        return s;
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableString *s = [NSMutableString string];
        [s appendString:@"[\n"];
        for (id item in obj) {
            [s appendFormat:@"  %@\n", DumpObject(item, depth + 1)];
        }
        [s appendString:@"]"];
        return s;
    }
    if ([obj isKindOfClass:[NSString class]]) {
        NSString *str = (NSString *)obj;
        if ([str length] > 300) {
            return [[str substringToIndex:300] stringByAppendingString:@"..."];
        }
        return str;
    }
    return [obj description];
}

// ================================================================
// Hook 1: CYCarDigitalBleKeyManager queryCarKeyWithUserId:VIN:back:
// ================================================================
%hook CYCarDigitalBleKeyManager

- (void)queryCarKeyWithUserId:(NSString *)userId VIN:(NSString *)vin
                         back:(void(^)(id result))completion {

    NSLog(@"[BleVerify] queryCarKeyWithUserId userId=%@ vin=%@", userId, vin);

    void (^wrappedBack)(id) = ^(id result) {
        NSLog(@"[BleVerify] queryCarKey RESULT: %@", result);

        // Format the result
        NSMutableString *msg = [NSMutableString string];
        [msg appendString:@"[OK] CYCarDigitalBleKeyManager\n"];
        [msg appendString:@"queryCarKeyWithUserId:VIN:back:\n\n"];
        [msg appendFormat:@"userId: %@\nvin: %@\n\n", userId, vin];
        [msg appendFormat:@"Result:\n%@\n", DumpObject(result, 0)];

        ShowAlert(@"BLE Key Query", msg);

        if (completion) {
            completion(result);
        }
    };

    %orig(userId, vin, wrappedBack);
}

- (void)ConnectWithKeyId:(NSString *)keyId vin:(NSString *)vin
                     back:(void(^)(id result))completion {
    NSLog(@"[BleVerify] ConnectWithKeyId keyId=%@ vin=%@", keyId, vin);

    void (^wrappedBack)(id) = ^(id result) {
        NSLog(@"[BleVerify] ConnectWithKeyId RESULT: %@", result);

        NSMutableString *msg = [NSMutableString string];
        [msg appendString:@"[OK] ConnectWithKeyId\n\n"];
        [msg appendFormat:@"keyId: %@\vin: %@\n\n", keyId, vin];
        [msg appendFormat:@"Result:\n%@\n", DumpObject(result, 0)];

        ShowAlert(@"BLE Connect", msg);

        if (completion) {
            completion(result);
        }
    };

    %orig(keyId, vin, wrappedBack);
}

%end

// ================================================================
// Hook 2: E300BleBluetoothManager loadLocalBleKeyData
// ================================================================
%hook E300BleBluetoothManager

- (id)loadLocalBleKeyData {
    id result = %orig;
    NSLog(@"[BleVerify] loadLocalBleKeyData => %@", result);

    if (result) {
        NSMutableString *msg = [NSMutableString string];
        [msg appendString:@"[OK] E300BleBluetoothManager\n"];
        [msg appendString:@"loadLocalBleKeyData\n\n"];
        [msg appendFormat:@"Data:\n%@\n", DumpObject(result, 0)];

        ShowAlert(@"BLE Local Key", msg);
    }

    return result;
}

- (void)sendAppAuthorizationRequestWithBleKey:(id)bleKey {
    NSLog(@"[BleVerify] sendAppAuthorizationRequestWithBleKey: %@", bleKey);

    if (bleKey) {
        NSMutableString *msg = [NSMutableString string];
        [msg appendString:@"[OK] Auth Request with BleKey\n\n"];
        [msg appendFormat:@"Data:\n%@\n", DumpObject(bleKey, 0)];

        ShowAlert(@"BLE Auth", msg);
    }

    %orig(bleKey);
}

%end

// ================================================================
// Hook 3: CYBaoJunOAuthJSONSString setter (capture OAuth)
// ================================================================
%hook NSUserDefaults

- (void)setObject:(id)value forKey:(NSString *)defaultName {
    %orig;

    @try {
        if (!defaultName) return;

        NSString *kl = [defaultName lowercaseString];

        // Capture any BLE key related writes
        if ([kl containsString:@"ble"] || [kl containsString:@"sp_ble"] ||
            [kl containsString:@"flutter"] || [kl containsString:@"digitalkey"] ||
            [kl containsString:@"masterkey"] || [kl containsString:@"carkey"]) {
            NSLog(@"[BleVerify] NSUserDefaults write: %@ = %@", defaultName, value);

            if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 20) {
                NSMutableString *msg = [NSMutableString string];
                [msg appendString:@"[OK] NSUserDefaults write detected\n\n"];
                [msg appendFormat:@"Key: %@\nValue:\n%@\n", defaultName, DumpObject(value, 0)];
                ShowAlert(@"BLE Key Write", msg);
            }
        }

        // Also capture status updates for HUD
        if ([defaultName hasPrefix:@"CYUnifiedCarStatusInfos"]) {
            NSLog(@"[BleVerify] Car status updated: %@", defaultName);
        }
    } @catch (NSException *e) {
        NSLog(@"[BleVerify] hook exception: %@", e);
    }
}

%end

// ================================================================
// Startup: show car status + trigger BLE key query
// ================================================================
static void ShowStartupInfo(void) {
    @try {
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        NSDictionary *all = [ud dictionaryRepresentation];

        NSMutableString *msg = [NSMutableString string];
        [msg appendString:@"-- Car Status --\n"];

        NSDictionary *status = nil;
        for (NSString *key in all) {
            if ([key hasPrefix:@"CYUnifiedCarStatusInfosFor"]) {
                id val = [all objectForKey:key];
                if ([val isKindOfClass:[NSDictionary class]]) { status = val; break; }
            }
        }
        if (status) {
            id bat = [status objectForKey:@"batterySoc"];
            id rangeE = [status objectForKey:@"leftMileage"];
            id rangeO = [status objectForKey:@"oilLeftMileage"];
            id ml = [status objectForKey:@"mileage"];
            id temp = [status objectForKey:@"interiorTemperature"];
            id volt = [status objectForKey:@"voltage"];
            id lock = [status objectForKey:@"doorLockStatus"];
            id ac = [status objectForKey:@"acStatus"];
            NSString *lockStr = [lock intValue] == 0 ? @"Locked" : @"Unlocked";
            NSString *acStr = [ac intValue] == 1 ? @"ON" : @"OFF";
            [msg appendFormat:@"[OK] bat:%@%% range:%@+%@km\n", bat, rangeE, rangeO];
            [msg appendFormat:@"  mileage:%@km temp:%@C\n", ml, temp];
            [msg appendFormat:@"  volt:%@V lock:%@ ac:%@\n", volt, lockStr, acStr];
        }

        [msg appendString:@"\n-- BLE Key Hooks Active --\n"];
        [msg appendString:@"Waiting for:\n"];
        [msg appendString:@"  CYCarDigitalBleKeyManager\n"];
        [msg appendString:@"    queryCarKeyWithUserId:VIN:back:\n"];
        [msg appendString:@"    ConnectWithKeyId:vin:back:\n"];
        [msg appendString:@"  E300BleBluetoothManager\n"];
        [msg appendString:@"    loadLocalBleKeyData\n"];
        [msg appendString:@"    sendAppAuthorizationRequestWithBleKey:\n\n"];
        [msg appendString:@"Open BLE key section or wait for\n"];
        [msg appendString:@"auto-query to capture key data.\n"];

        ShowAlert(@"BLE Key Monitor v6", msg);

    } @catch (NSException *e) {
        NSLog(@"[BleVerify] startup exception: %@", e);
    }
}

%ctor {
    @autoreleasepool {
        NSLog(@"[BleVerify] ====== LOADED ======");
        NSLog(@"[BleVerify] Bundle: %@", [[NSBundle mainBundle] bundleIdentifier]);
        NSLog(@"[BleVerify] Process: %@", [[NSProcessInfo processInfo] processName]);
        NSLog(@"[BleVerify] =====================");

        // Show startup info after 3 seconds
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ ShowStartupInfo(); });
    }
}
