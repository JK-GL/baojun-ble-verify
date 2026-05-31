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

// ── 递归搜索目录，返回匹配的文件路径 ────────────────────────
static NSMutableArray<NSString *> *SearchDir(NSString *dir, NSArray<NSString *> *keywords) {
    NSMutableArray *results = [NSMutableArray array];
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDirectoryEnumerator *en = [fm enumeratorAtPath:dir];
        NSString *file;
        while ((file = [en nextObject])) {
            NSString *lower = file.lowercaseString;
            for (NSString *kw in keywords) {
                if ([lower containsString:kw]) {
                    NSString *full = [dir stringByAppendingPathComponent:file];
                    NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
                    unsigned long long size = [attrs fileSize];
                    [results addObject:[NSString stringWithFormat:@"%@ (%llu bytes)", file, size]];
                    break;
                }
            }
        }
    } @catch (NSException *e) {
        [results addObject:[NSString stringWithFormat:@"error: %@", e.reason]];
    }
    return results;
}

// ── 读取 plist 并搜索含 BLE key 的 entry ────────────────────
static void ScanPlistAtPath(NSString *path, NSMutableString *msg) {
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:path];
        if (!d) return;
        [msg appendFormat:@"\n  📄 %@\n", path.lastPathComponent];
        [msg appendFormat:@"     %lu keys\n", (unsigned long)d.count];

        // 搜索 BLE 钥匙相关 key
        for (NSString *key in d) {
            NSString *kl = key.lowercaseString;
            if ([kl containsString:@"ble"] || [kl containsString:@"sp_ble"] ||
                [kl containsString:@"masterkey"] || [kl containsString:@"keyid"] ||
                [kl containsString:@"flutter"] || [kl containsString:@"digitalkey"]) {
                id val = d[key];
                NSString *type = NSStringFromClass([val class]);
                NSString *preview = @"";
                if ([val isKindOfClass:NSString.class]) {
                    preview = [(NSString *)val length] > 120
                        ? [[(NSString *)val substringToIndex:120] stringByAppendingString:@"…"]
                        : val;
                }
                [msg appendFormat:@"     🎯 %@ (%@) = %@\n", key, type, preview];
            }
        }

        // 检查整个 dict 是否含 flutter.sp_ble_key
        if (d[@"flutter.sp_ble_key"]) {
            [msg appendFormat:@"     ✅✅ flutter.sp_ble_key = %@\n", d[@"flutter.sp_ble_key"]];
        }
    } @catch (NSException *e) {}
}

// ── 主诊断 ──────────────────────────────────────────────────
static void RunDiagnostic(void) {
    if (alertShown) return;
    NSMutableString *msg = [NSMutableString string];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSDictionary *all = [ud dictionaryRepresentation];

    // ── 1. Car Status ─────────────────────────────────────────
    [msg appendString:@"── Car Status ──\n"];
    NSDictionary *status = nil;
    for (NSString *key in all) {
        if ([key hasPrefix:@"CYUnifiedCarStatusInfosFor"]) {
            id val = all[key];
            if ([val isKindOfClass:NSDictionary.class]) { status = val; break; }
        }
    }
    if (status) {
        [msg appendFormat:@"✅ bat:%@%% range:%@+%@km mileage:%@km\n",
              status[@"batterySoc"], status[@"leftMileage"],
              status[@"oilLeftMileage"], status[@"mileage]];
        [msg appendFormat:@"  temp:%@C volt:%@V lock:%@ ac:%@\n",
              status[@"interiorTemperature"], status[@"voltage"],
              [status[@"doorLockStatus"] intValue] == 0 ? @"Y" : @"N",
              [status[@"acStatus"] intValue] == 1 ? @"ON" : @"OFF"];
    } else {
        [msg appendString:@"- none\n"];
    }

    // ── 2. BLE 钥匙 (NSUserDefaults) ────────────────────────
    [msg appendString:@"\n── NSUserDefaults BLE ──\n"];
    BOOL foundBle = NO;
    for (NSString *key in all) {
        NSString *kl = key.lowercaseString;
        if ([kl containsString:@"sp_ble"] || [kl containsString:@"blekey"] ||
            [kl containsString:@"masterkey"] || [kl containsString:@"digitalkey"] ||
            ([kl containsString:@"flutter"] && [kl containsString:@"key"])) {
            id val = all[key];
            NSString *preview = @"";
            if ([val isKindOfClass:NSString.class]) {
                preview = [(NSString *)val length] > 100
                    ? [[(NSString *)val substringToIndex:100] stringByAppendingString:@"…"] : val;
            }
            [msg appendFormat:@"  🎯 %@ = %@\n", key, preview];
            foundBle = YES;
        }
    }
    if (!foundBle) [msg appendString:@"  - none\n"];

    // ── 3. 搜索自己容器 ─────────────────────────────────────
    NSString *home = NSHomeDirectory();
    NSString *libDir = [home stringByAppendingPathComponent:@"Library"];
    NSString *docsDir = [home stringByAppendingPathComponent:@"Documents"];
    NSString *prefDir = [libDir stringByAppendingPathComponent:@"Preferences"];

    [msg appendString:@"\n── Container Prefs ──\n"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *prefFiles = [fm contentsOfDirectoryAtPath:prefDir error:nil];
    [msg appendFormat:@"  Total %lu files\n", (unsigned long)prefFiles.count];
    for (NSString *f in prefFiles) {
        NSString *full = [prefDir stringByAppendingPathComponent:f];
        NSDictionary *a = [fm attributesOfItemAtPath:full error:nil];
        [msg appendFormat:@"  📄 %@ (%lld bytes)\n", f, [a fileSize]];
    }

    // ── 4. 递归搜 Documents 和 Library ─────────────────────
    NSArray *keywords = @[@"flutter", @"sp_", @"ble", @"key", @"shared_pref", @"preference"];
    [msg appendString:@"\n── Documents Scan ──\n"];
    NSMutableArray *docResults = SearchDir(docsDir, keywords);
    if (docResults.count > 0) {
        for (NSString *r in docResults) [msg appendFormat:@"  %@\n", r];
    } else {
        [msg appendString:@"  (no match)\n"];
    }

    [msg appendString:@"\n── Library Scan ──\n"];
    NSMutableArray *libResults = SearchDir(libDir, keywords);
    if (libResults.count > 0) {
        for (NSString *r in libResults) [msg appendFormat:@"  %@\n", r];
    } else {
        [msg appendString:@"  (no match)\n"];
    }

    // ── 5. 读取 Preferences 目录中所有 plist ────────────────
    [msg appendString:@"\n── Prefs plist ──\n"];
    for (NSString *f in prefFiles) {
        if ([f.pathExtension isEqualToString:@"plist"]) {
            NSString *full = [prefDir stringByAppendingPathComponent:f];
            ScanPlistAtPath(full, msg);
        }
    }

    // ── 6. 尝试读 Flutter SharedPrefs ────────────────
    // Flutter shared_preferences 有时存在 Documents/shared_preferences/
    [msg appendString:@"\n── Flutter SharedPrefs ──\n"];
    NSString *spDir = [docsDir stringByAppendingPathComponent:@"shared_preferences"];
    if ([fm fileExistsAtPath:spDir]) {
        NSArray *spFiles = [fm contentsOfDirectoryAtPath:spDir error:nil];
        for (NSString *f in spFiles) {
            NSString *full = [spDir stringByAppendingPathComponent:f];
            NSDictionary *a = [fm attributesOfItemAtPath:full error:nil];
            [msg appendFormat:@"  📄 %@ (%lld bytes)\n", f, [a fileSize]];
            // 如果是 plist 尝试读取
            if ([f.pathExtension isEqualToString:@"plist"]) {
                ScanPlistAtPath(full, msg);
            }
        }
    } else {
        [msg appendFormat:@"  ❌ not found: %@\n", spDir.lastPathComponent];
    }

    // ── 7. Container Root列出 ───────────────────────────────────
    [msg appendFormat:@"\n── Container Root ──\n  home: %@\n", home];
    NSArray *rootFiles = [fm contentsOfDirectoryAtPath:home error:nil];
    for (NSString *f in rootFiles) {
        [msg appendFormat:@"  📁 %@\n", f];
    }

    // 列出 Library Subs
    NSArray *libSubs = [fm contentsOfDirectoryAtPath:libDir error:nil];
    [msg appendFormat:@"\n── Library Subs (%lu) ──\n", (unsigned long)libSubs.count];
    for (NSString *f in libSubs) {
        NSString *full = [libDir stringByAppendingPathComponent:f];
        BOOL isDir = NO;
        [fm fileExistsAtPath:full isDirectory:&isDir];
        [msg appendFormat:@"  %@ %@\n", isDir ? @"📁" : @"📄", f];
    }

    ShowAlert(@"🔍 Diagnostic v5", msg);
    NSLog(@"[BleVerify] diagnostic:\n%@", msg);
}

%ctor {
    @autoreleasepool {
        NSLog(@"[BleVerify] loaded in %@", NSProcessInfo.processInfo.processName);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ RunDiagnostic(); });
    }
}
