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

static void RunDiagnostic(void) {
    if (alertShown) return;
    NSMutableString *msg = [NSMutableString string];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSDictionary *all = [ud dictionaryRepresentation];

    // -- 1. Car status --
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
        [msg appendFormat:@"[OK] bat:%@%% range:%@+%@km mileage:%@km\n", bat, rangeE, rangeO, ml];
        [msg appendFormat:@"  temp:%@C volt:%@V lock:%@ ac:%@\n", temp, volt, lockStr, acStr];
    } else {
        [msg appendString:@"- none\n"];
    }

    // -- 2. BLE key in NSUserDefaults --
    [msg appendString:@"\n-- NSUserDefaults BLE --\n"];
    BOOL foundBle = NO;
    for (NSString *key in all) {
        NSString *kl = [key lowercaseString];
        if ([kl containsString:@"sp_ble"] || [kl containsString:@"blekey"] ||
            [kl containsString:@"masterkey"] || [kl containsString:@"digitalkey"] ||
            ([kl containsString:@"flutter"] && [kl containsString:@"key"])) {
            id val = [all objectForKey:key];
            NSString *preview = [val description];
            if ([preview length] > 100) preview = [[preview substringToIndex:100] stringByAppendingString:@"..."];
            [msg appendFormat:@"  [*] %@ = %@\n", key, preview];
            foundBle = YES;
        }
    }
    if (!foundBle) [msg appendString:@"  - none\n"];

    // -- 3. Container Preferences dir --
    NSString *home = NSHomeDirectory();
    NSString *libDir = [home stringByAppendingPathComponent:@"Library"];
    NSString *docsDir = [home stringByAppendingPathComponent:@"Documents"];
    NSString *prefDir = [libDir stringByAppendingPathComponent:@"Preferences"];
    NSFileManager *fm = [NSFileManager defaultManager];

    [msg appendString:@"\n-- Container Prefs --\n"];
    NSArray *prefFiles = [fm contentsOfDirectoryAtPath:prefDir error:nil];
    [msg appendFormat:@"  Total %lu files\n", (unsigned long)prefFiles.count];
    for (NSString *f in prefFiles) {
        NSString *full = [prefDir stringByAppendingPathComponent:f];
        NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
        [msg appendFormat:@"  [F] %@ (%lld bytes)\n", f, [attrs fileSize]];
    }

    // -- 4. Scan Library/Preferences plists for BLE keys --
    [msg appendString:@"\n-- Plist Content --\n"];
    for (NSString *f in prefFiles) {
        if ([[f pathExtension] isEqualToString:@"plist"]) {
            NSString *full = [prefDir stringByAppending:f];
            NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:full];
            if (!d) continue;
            [msg appendFormat:@"\n  [F] %@ (%lu keys)\n", f, (unsigned long)d.count];
            for (NSString *key in d) {
                NSString *kl = [key lowercaseString];
                if ([kl containsString:@"ble"] || [kl containsString:@"sp_ble"] ||
                    [kl containsString:@"masterkey"] || [kl containsString:@"digitalkey"] ||
                    [kl containsString:@"flutter"]) {
                    id val = [d objectForKey:key];
                    NSString *preview = [val description];
                    if ([preview length] > 120) preview = [[preview substringToIndex:120] stringByAppendingString:@"..."];
                    [msg appendFormat:@"    [*] %@ = %@\n", key, preview];
                }
            }
        }
    }

    // -- 5. Recursive search Documents --
    [msg appendString:@"\n-- Documents Scan --\n"];
    NSDirectoryEnumerator *en = [fm enumeratorAtPath:docsDir];
    NSString *file;
    while ((file = [en nextObject])) {
        NSString *kl = [file lowercaseString];
        if ([kl containsString:@"flutter"] || [kl containsString:@"sp_"] ||
            [kl containsString:@"ble"] || [kl containsString:@"shared_pref"] ||
            [kl containsString:@"preference"]) {
            NSString *full = [docsDir stringByAppendingPathComponent:file];
            NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
            [msg appendFormat:@"  [F] %@ (%lld bytes)\n", file, [attrs fileSize]];
        }
    }

    // -- 6. Recursive search Library --
    [msg appendString:@"\n-- Library Scan --\n"];
    en = [fm enumeratorAtPath:libDir];
    while ((file = [en nextObject])) {
        NSString *kl = [file lowercaseString];
        if ([kl containsString:@"flutter"] || [kl containsString:@"sp_"] ||
            [kl containsString:@"shared_pref"] || [kl containsString:@"preference"]) {
            NSString *full = [libDir stringByAppendingPathComponent:file];
            NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
            [msg appendFormat:@"  [F] %@ (%lld bytes)\n", file, [attrs fileSize]];
        }
    }

    // -- 7. Container root listing --
    [msg appendFormat:@"\n-- Container Root --\n  home: %@\n", home];
    NSArray *rootFiles = [fm contentsOfDirectoryAtPath:home error:nil];
    for (NSString *f in rootFiles) {
        [msg appendFormat:@"  [D] %@\n", f];
    }

    // -- 8. Library sub-dirs --
    NSArray *libSubs = [fm contentsOfDirectoryAtPath:libDir error:nil];
    [msg appendFormat:@"\n-- Library Subs (%lu) --\n", (unsigned long)libSubs.count];
    for (NSString *f in libSubs) {
        NSString *full = [libDir stringByAppendingPathComponent:f];
        BOOL isDir = NO;
        [fm fileExistsAtPath:full isDirectory:&isDir];
        [msg appendFormat:@"  %@ %@\n", isDir ? @"[D]" : @"[F]", f];
    }

    // -- 9. Process info --
    [msg appendFormat:@"\n-- Process --\n  name: %@\n  bundle: %@\n",
          [[NSProcessInfo processInfo] processName],
          [[NSBundle mainBundle] bundleIdentifier] ?: @"(nil)"];

    ShowAlert(@"Diagnostic v5", msg);
    NSLog(@"[BleVerify] diagnostic:\n%@", msg);
}

%ctor {
    @autoreleasepool {
        NSLog(@"[BleVerify] loaded in %@", [[NSProcessInfo processInfo] processName]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ RunDiagnostic(); });
    }
}
