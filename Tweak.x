#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

static BOOL alertShown = NO;

// ── 弹窗 ────────────────────────────────────────────────────
static void ShowAlert(NSString *title, NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (alertShown) return;
        alertShown = YES;
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title
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

// ── 搜索 Flutter 容器 ───────────────────────────────────────
static void SearchFlutterContainer(NSMutableString *msg) {
    @try {
        [msg appendString:@"\n── Flutter 容器搜索 ──\n"];

        // 搜索 /var/mobile/Containers/Data/Application/ 下所有 plist/json
        NSString *containerBase = @"/var/mobile/Containers/Data/Application";
        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *err = nil;
        NSArray *uuids = [fm contentsOfDirectoryAtPath:containerBase error:&err];
        if (err) {
            [msg appendFormat:@"  ❌ 无法扫描: %@\n", err.localizedDescription];
            return;
        }

        // 也搜 Group Containers
        NSString *groupBase = @"/var/mobile/Containers/Shared/AppGroup";
        NSArray *groupUUIDs = [fm contentsOfDirectoryAtPath:groupBase error:nil];

        NSUInteger found = 0;

        // 搜索每个 app container
        for (NSString *uuid in uuids) {
            NSString *libPref = [containerBase stringByAppendingPathComponent:
                                 [uuid stringByAppendingPathComponent:@"Library/Preferences"]];
            NSArray *prefFiles = [fm contentsOfDirectoryAtPath:libPref error:nil];
            for (NSString *f in prefFiles) {
                NSString *lower = f.lowercaseString;
                if ([lower containsString:@"cloudy"] || [lower containsString:@"lingling"] ||
                    [lower containsString:@"wuling"] || [lower containsString:@"sgmw"]) {
                    NSString *fullPath = [libPref stringByAppendingPathComponent:f];
                    NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
                    [msg appendFormat:@"  ✅ %@/%@ (%lld bytes)\n", uuid, f, [attrs fileSize]];
                    found++;

                    // 读取这个文件
                    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:fullPath];
                    if (d) {
                        [msg appendFormat:@"     keys: %lu\n", (unsigned long)d.count];
                        for (NSString *key in d) {
                            NSString *kl = key.lowercaseString;
                            if ([kl containsString:@"ble"] || [kl containsString:@"key"] ||
                                [kl containsString:@"flutter"] || [kl containsString:@"sp_"]) {
                                [msg appendFormat:@"     🎯 %@\n", key];
                            }
                        }
                    }
                }
            }

            // 也搜 Documents 下的 Flutter SharedPreferences
            NSString *docsPath = [containerBase stringByAppendingPathComponent:
                                  [uuid stringByAppendingPathComponent:@"Documents"]];
            NSString *libPath = [containerBase stringByAppendingPathComponent:
                                 [uuid stringByAppendingPathComponent:@"Library"]];

            // 搜索 flutter_application_info, shared_preferences 等
            for (NSString *dir in @[docsPath, libPath]) {
                NSDirectoryEnumerator *en = [fm enumeratorAtPath:dir];
                NSString *file;
                while ((file = [en nextObject])) {
                    NSString *lower = file.lowercaseString;
                    if ([lower containsString:@"shared_preference"] ||
                        [lower containsString:@"flutter"] ||
                        [lower containsString:@"sp_ble"] ||
                        [lower containsString:@"ble_key"]) {
                        NSString *full = [dir stringByAppendingPathComponent:file];
                        NSDictionary *a = [fm attributesOfItemAtPath:full error:nil];
                        [msg appendFormat:@"  📄 %@ %@ (%lld bytes)\n",
                              uuid, file, [a fileSize]];
                        found++;
                    }
                }
            }
        }

        // 搜索 Group Containers
        if (groupUUIDs) {
            for (NSString *uuid in groupUUIDs) {
                NSString *groupPath = [groupBase stringByAppendingPathComponent:uuid];
                NSDirectoryEnumerator *en = [fm enumeratorAtPath:groupPath];
                NSString *file;
                while ((file = [en nextObject])) {
                    NSString *lower = file.lowercaseString;
                    if ([lower containsString:@"cloudy"] || [lower containsString:@"flutter"] ||
                        [lower containsString:@"ble"] || [lower containsString:@"lingling"]) {
                        NSString *full = [groupPath stringByAppendingPathComponent:file];
                        NSDictionary *a = [fm attributesOfItemAtPath:full error:nil];
                        [msg appendFormat:@"  📁 Group/%@/%@ (%lld bytes)\n",
                              uuid, file, [a fileSize]];
                        found++;
                    }
                }
            }
        }

        if (found == 0) {
            [msg appendString:@"  (未找到)\n"];
        }
    } @catch (NSException *e) {
        [msg appendFormat:@"  ❌ exception: %@\n", e.reason];
    }
}

// ── Hook NSDictionary dictionaryWithContentsOfFile: ──────────
%hook NSDictionary

+ (instancetype)dictionaryWithContentsOfFile:(NSString *)path {
    NSDictionary *result = %orig;

    @try {
        if (!path || !result) return result;

        NSString *lower = path.lowercaseString;
        // 拦截含 flutter/shared_preference/ble 的文件读取
        if ([lower containsString:@"flutter"] || [lower containsString:@"shared_pref"] ||
            [lower containsString:@"sp_ble"] || [lower containsString:@"ble_key"] ||
            [lower containsString:@"cloudy"] || [lower containsString:@"lingling"]) {
            NSLog(@"[BleVerify] 📄 读取文件: %@ (%lu keys)", path, (unsigned long)result.count);

            // 检查是否含 BLE 钥匙
            for (NSString *key in result) {
                NSString *kl = key.lowercaseString;
                if ([kl containsString:@"ble"] || [kl containsString:@"key"] ||
                    [kl containsString:@"sp_ble"] || [kl containsString:@"masterkey"]) {
                    NSLog(@"[BleVerify] 🎯 文件 %@ 中发现 key: %@", path.lastPathComponent, key);
                }
            }
        }

        // 特别检查：任何含 flutter.sp_ble_key 的字典
        if (result[@"flutter.sp_ble_key"]) {
            NSLog(@"[BleVerify] ✅✅✅ 在文件 %@ 中找到 flutter.sp_ble_key!", path);
        }
    } @catch (NSException *e) {
        NSLog(@"[BleVerify] dict hook exception: %@", e);
    }

    return result;
}

%end

// ── Hook NSArray arrayWithContentsOfFile: (Flutter 可能用) ──
%hook NSArray

+ (instancetype)arrayWithContentsOfFile:(NSString *)path {
    NSArray *result = %orig;
    @try {
        if (path && result) {
            NSString *lower = path.lowercaseString;
            if ([lower containsString:@"flutter"] || [lower containsString:@"shared_pref"] ||
                [lower containsString:@"cloudy"]) {
                NSLog(@"[BleVerify] 📄 NSArray 读取: %@ (%lu items)", path, (unsigned long)result.count);
            }
        }
    } @catch (NSException *e) {}
    return result;
}

%end

// ── 主诊断 (3 秒后) ─────────────────────────────────────────
static void RunDiagnostic(void) {
    if (alertShown) return;

    NSMutableString *msg = [NSMutableString string];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSDictionary *all = [ud dictionaryRepresentation];

    // ── 1. 读车辆状态 ───────────────────────────────────────
    [msg appendString:@"── 车辆状态 ──\n"];
    NSDictionary *status = nil;
    for (NSString *key in all) {
        if ([key hasPrefix:@"CYUnifiedCarStatusInfosFor"] && [key containsString:@"LK6ADAH92RB765125"]) {
            id val = all[key];
            if ([val isKindOfClass:NSDictionary.class]) {
                status = val;
                break;
            }
        }
    }
    if (status) {
        [msg appendFormat:@"✅ 电量: %@%% | 续航: %@km(电)+%@km(油)\n",
              status[@"batterySoc"], status[@"leftMileage"], status[@"oilLeftMileage"]];
        [msg appendFormat:@"  里程: %@km | 温度: %@°C | 电压: %@V\n",
              status[@"mileage"], status[@"interiorTemperature"], status[@"voltage"]];
        [msg appendFormat:@"  车锁: %@ | 空调: %@ | 位置: %@,%@\n",
              [status[@"doorLockStatus"] intValue] == 0 ? @"已锁" : @"未锁",
              [status[@"acStatus"] intValue] == 1 ? @"开" : @"关",
              status[@"latitude"], status[@"longitude"]];
    } else {
        [msg appendString:@"❌ 未找到车辆状态\n"];
    }

    // ── 2. 检查 OAuth ───────────────────────────────────────
    [msg appendString:@"\n── OAuth ──\n"];
    NSString *oauth = all[@"CYBaoJunOAuthJSONSString"];
    if (oauth) {
        [msg appendFormat:@"✅ CYBaoJunOAuthJSONSString (%lu chars)\n", (unsigned long)oauth.length];
    } else {
        [msg appendString:@"❌ 无 OAuth\n"];
    }

    // ── 3. 搜索 BLE 钥匙 ───────────────────────────────────
    [msg appendString:@"\n── BLE 钥匙搜索 ──\n"];
    BOOL foundBleKey = NO;
    for (NSString *key in all) {
        NSString *kl = key.lowercaseString;
        if ([kl containsString:@"sp_ble"] || [kl containsString:@"blekey"] ||
            [kl containsString:@"flutter"] || [kl containsString:@"masterkey"] ||
            [kl containsString:@"digital"] || [kl containsString:@"keyid"]) {
            id val = all[key];
            NSString *preview = @"";
            if ([val isKindOfClass:NSString.class]) {
                preview = [(NSString *)val length] > 100
                    ? [[(NSString *)val substringToIndex:100] stringByAppendingString:@"…"]
                    : val;
            }
            [msg appendFormat:@"  🎯 %@ = %@\n", key, preview];
            foundBleKey = YES;
        }
    }
    if (!foundBleKey) {
        [msg appendString:@"  ❌ NSUserDefaults 中无 BLE 钥匙\n"];
        [msg appendString:@"  → 钥匙在 Flutter 容器文件中\n"];
    }

    // ── 4. 搜索 Flutter 容器 ────────────────────────────────
    SearchFlutterContainer(msg);

    // ── 5. 当前进程信息 ─────────────────────────────────────
    [msg appendFormat:@"\n── 进程 ──\n"];
    [msg appendFormat:@"进程: %@\n", NSProcessInfo.processInfo.processName];
    [msg appendFormat:@"容器: %@\n", NSHomeDirectory()];

    ShowAlert(@"🔍 诊断 v4", msg);
    NSLog(@"[BleVerify] diagnostic:\n%@", msg);
}

// ── %ctor ────────────────────────────────────────────────────
%ctor {
    @autoreleasepool {
        NSLog(@"[BleVerify] loaded in %@", NSProcessInfo.processInfo.processName);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ RunDiagnostic(); });
    }
}
