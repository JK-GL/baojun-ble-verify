#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static BOOL alertShown = NO;

// ── 弹窗 ────────────────────────────────────────────────────
static void ShowMsg(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (alertShown) return;
        alertShown = YES;
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"🔍 全量诊断"
                                                                  message:msg
                                                           preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"复制" style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *_) {
            UIPasteboard.generalPasteboard.string = msg ?: @"";
        }]];
        [a addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
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

// ── 兜底扫描 (3 秒后执行) ───────────────────────────────────
static void ScanAll(void) {
    if (alertShown) return;

    NSMutableString *msg = [NSMutableString string];
    NSDictionary *all = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];

    // ── 1. 搜索 user_default_car_status_ (HUD 插件的 key) ──
    [msg appendString:@"── car_status key ──\n"];
    BOOL foundStatus = NO;
    for (NSString *key in all) {
        if ([key containsString:@"car_status"] || [key containsString:@"carStatus"]) {
            id val = all[key];
            NSString *type = NSStringFromClass([val class]);
            [msg appendFormat:@"  ✅ %@ (%@)\n", key, type];
            foundStatus = YES;
        }
    }
    if (!foundStatus) [msg appendString:@"  ❌ 无\n"];

    // ── 2. 搜索 flutter/ble/key 相关 ───────────────────────
    [msg appendString:@"\n── flutter/ble/key ──\n"];
    BOOL foundKey = NO;
    for (NSString *key in all) {
        NSString *lower = key.lowercaseString;
        if ([lower containsString:@"flutter"] || [lower containsString:@"ble_key"] ||
            [lower containsString:@"sp_ble"] || [lower containsString:@"digital"] ||
            [lower containsString:@"blekey"] || [lower containsString:@"masterkey"]) {
            id val = all[key];
            NSString *type = NSStringFromClass([val class]);
            NSString *preview = @"";
            if ([val isKindOfClass:NSString.class]) {
                preview = [(NSString *)val length] > 80
                    ? [[(NSString *)val substringToIndex:80] stringByAppendingString:@"…"]
                    : val;
            }
            [msg appendFormat:@"  ✅ %@ (%@) = %@\n", key, type, preview];
            foundKey = YES;
        }
    }
    if (!foundKey) [msg appendString:@"  ❌ 无\n"];

    // ── 3. 搜索 CY/SGMW/云海 相关 ──────────────────────────
    [msg appendString:@"\n── CY/SGMW/Wuling ──\n"];
    for (NSString *key in all) {
        NSString *lower = key.lowercaseString;
        if ([lower hasPrefix:@"cy"] || [lower containsString:@"sgmw"] ||
            [lower containsString:@"wuling"] || [lower containsString:@"unified"] ||
            [lower containsString:@"statusinfo"] || [lower containsString:@"ba0jun"] ||
            [lower containsString:@"savedoauth"]) {
            id val = all[key];
            NSString *type = NSStringFromClass([val class]);
            [msg appendFormat:@"  🔑 %@ (%@)\n", key, type];
        }
    }

    // ── 4. 扫描 app 容器找 plist/json ──────────────────────
    [msg appendString:@"\n── App 容器扫描 ──\n"];
    NSString *home = NSHomeDirectory();
    [msg appendFormat:@"home: %@\n", home];

    // 扫描 Documents, Library/Preferences
    NSArray *scanDirs = @[
        [home stringByAppendingPathComponent:@"Documents"],
        [home stringByAppendingPathComponent:@"Library"],
        [home stringByAppendingPathComponent:@"Library/Preferences"],
        [home stringByAppendingPathComponent:@"tmp"],
    ];

    for (NSString *dir in scanDirs) {
        NSError *err = nil;
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:&err];
        if (err || files.count == 0) continue;
        [msg appendFormat:@"\n📁 %@ (%lu files)\n", dir.lastPathComponent, (unsigned long)files.count];
        for (NSString *f in files) {
            NSString *lower = f.lowercaseString;
            if ([lower hasSuffix:@".plist"] || [lower hasSuffix:@".json"] ||
                [lower containsString:@"flutter"] || [lower containsString:@"ble"] ||
                [lower containsString:@"key"] || [lower containsString:@"sp_"] ||
                [lower containsString:@"shared_pref"]) {
                NSString *fullPath = [dir stringByAppendingPathComponent:f];
                NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:fullPath error:nil];
                unsigned long long size = [attrs fileSize];
                [msg appendFormat:@"  📄 %@ (%llu bytes)\n", f, size];
            }
        }
    }

    // ── 5. 递归搜索 Documents 下所有 plist ─────────────────
    [msg appendString:@"\n── Documents 递归搜索 ──\n"];
    NSString *docs = [home stringByAppendingPathComponent:@"Documents"];
    NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager]
                                         enumeratorAtPath:docs];
    NSString *file;
    while ((file = [enumerator nextObject])) {
        NSString *lower = file.lowercaseString;
        if ([lower hasSuffix:@".plist"] || [lower hasSuffix:@".json"] ||
            [lower containsString:@"flutter"] || [lower containsString:@"shared"] ||
            [lower containsString:@"sp_"] || [lower containsString:@"ble"]) {
            NSString *full = [docs stringByAppendingPathComponent:file];
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:full error:nil];
            [msg appendFormat:@"  📄 %@ (%lld bytes)\n", file, [attrs fileSize]];
        }
    }

    // ── 6. 也搜 Library 下的 plist ─────────────────────────
    [msg appendString:@"\n── Library 递归搜索 ──\n"];
    NSString *lib = [home stringByAppendingPathComponent:@"Library"];
    enumerator = [[NSFileManager defaultManager] enumeratorAtPath:lib];
    while ((file = [enumerator nextObject])) {
        NSString *lower = file.lowercaseString;
        if ([lower hasSuffix:@".plist"] || [lower hasSuffix:@".json"] ||
            [lower containsString:@"flutter"] || [lower containsString:@"shared"] ||
            [lower containsString:@"sp_"]) {
            NSString *full = [lib stringByAppendingPathComponent:file];
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:full error:nil];
            [msg appendFormat:@"  📄 %@ (%lld bytes)\n", file, [attrs fileSize]];
        }
    }

    // ── 7. 硬编码 plist 路径也检查 ──────────────────────────
    [msg appendString:@"\n── 硬编码路径 ──\n"];
    NSString *hardcoded = @"/var/mobile/Library/Preferences/com.cloudy.LingLingBang.plist";
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:hardcoded];
    [msg appendFormat:@"%@ %@\n", exists ? @"✅" : @"❌", hardcoded];
    if (exists) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:hardcoded];
        [msg appendFormat:@"  keys: %lu\n", (unsigned long)d.count);
    }

    ShowMsg(msg);
    NSLog(@"[BleVerify] diagnostic:\n%@", msg);
}

// ── %ctor ────────────────────────────────────────────────────
%ctor {
    @autoreleasepool {
        NSLog(@"[BleVerify] loaded in %@", NSProcessInfo.processInfo.processName);
        // 延时 3 秒，等 app 完全加载数据
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ ScanAll(); });
    }
}
