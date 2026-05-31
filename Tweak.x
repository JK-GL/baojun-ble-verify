#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// ── 全局存储 ─────────────────────────────────────────────────
static NSString *capturedBleKeyJson  = nil;
static NSString *capturedStatusJson  = nil;
static BOOL     alertShown           = NO;

// ── 安全 JSON 序列化 ─────────────────────────────────────────
static NSString *SafeJSON(id obj) {
    if (!obj) return @"(null)";
    @try {
        NSData *data = [NSJSONSerialization dataWithJSONObject:obj
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:nil];
        return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"(encode error)";
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"(json error: %@)", e.reason];
    }
}

// ── 主弹窗 ──────────────────────────────────────────────────
static void ShowResultAlert(NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (alertShown) return;
            alertShown = YES;

            UIAlertController *alert =
                [UIAlertController alertControllerWithTitle:@"🔍 BLE 钥匙验证"
                                                   message:message
                                            preferredStyle:UIAlertControllerStyleAlert];

            [alert addAction:
                [UIAlertAction actionWithTitle:@"复制全部"
                                         style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *a) {
                    UIPasteboard.generalPasteboard.string = message ?: @"";
                }]];

            [alert addAction:
                [UIAlertAction actionWithTitle:@"关闭"
                                         style:UIAlertActionStyleCancel
                                       handler:nil]];

            UIViewController *top = nil;
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if ([scene isKindOfClass:UIWindowScene.class]) {
                    for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                        if (w.isKeyWindow) { top = w.rootViewController; break; }
                    }
                }
                if (top) break;
            }
            while (top.presentedViewController) top = top.presentedViewController;
            if (top) [top presentViewController:alert animated:YES completion:nil];
        } @catch (NSException *e) {
            NSLog(@"[BleVerify] alert exception: %@", e);
        }
    });
}

// ── 尝试构建并弹窗 ──────────────────────────────────────────
static void TryShowResult(void) {
    if (alertShown) return;
    if (!capturedBleKeyJson) return;  // 还没拦截到钥匙

    NSMutableString *msg = [NSMutableString string];

    // 解析 BLE 钥匙
    NSData *data = [capturedBleKeyJson dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *bleKey = data
        ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil]
        : nil;

    if ([bleKey isKindOfClass:NSDictionary.class]) {
        [msg appendString:@"✅ BLE 钥匙 (运行时拦截)\n\n"];
        [msg appendFormat:@"🔑 masterKey: %@\n",     bleKey[@"masterKey"]];
        [msg appendFormat:@"📱 userId:    %@\n",     bleKey[@"userId"]];
        [msg appendFormat:@"📡 bleMac:    %@\n",     bleKey[@"bleMac"]];
        [msg appendFormat:@"🆔 keyId:     %@\n",     bleKey[@"keyId"]];
        [msg appendFormat:@"🚗 VIN:       %@\n",     bleKey[@"vin"]];
        [msg appendFormat:@"🎲 random:    %@\n",     bleKey[@"keyMasterRandom"]];
        [msg appendFormat:@"👤 keyType:   %@\n",     bleKey[@"keyType"]];
        [msg appendFormat:@"⏳ endTime:   %@\n",     bleKey[@"endTime"]];
    } else {
        [msg appendFormat:@"✅ 拦截到 flutter.sp_ble_key\n\n%@\n", capturedBleKeyJson];
    }

    // 解析车辆状态
    if (capturedStatusJson) {
        NSData *sData = [capturedStatusJson dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *status = sData
            ? [NSJSONSerialization JSONObjectWithData:sData options:0 error:nil]
            : nil;
        if ([status isKindOfClass:NSDictionary.class]) {
            [msg appendString:@"\n── 车辆状态 (运行时拦截) ──\n"];
            [msg appendFormat:@"🔋 电量:    %@%%\n",  status[@"batterySoc"]];
            [msg appendFormat:@"📏 续航:    %@km\n",   status[@"oilLeftMileage"]];
            [msg appendFormat:@"🛣 里程:    %@km\n",   status[@"mileage"]];
            [msg appendFormat:@"🔒 车锁:    %@\n",
                  [status[@"doorLockStatus"] intValue] == 0 ? @"已锁" : @"未锁"];
            [msg appendFormat:@"🌡 温度:    %@°C\n",   status[@"interiorTemperature"]];
            [msg appendFormat:@"⚡ 电压:    %@V\n",    status[@"voltage"]];
        }
    } else {
        [msg appendString:@"\n⏳ 车辆状态: 尚未拦截到\n"];
    }

    ShowResultAlert(msg);
    NSLog(@"[BleVerify] result:\n%@", msg);
}

// ── Hook NSUserDefaults ──────────────────────────────────────
%hook NSUserDefaults

- (void)setObject:(id)value forKey:(NSString *)defaultName {
    %orig;

    @try {
        if (!defaultName || ![defaultName isKindOfClass:NSString.class]) return;

        // 拦截 BLE 钥匙
        if ([defaultName isEqualToString:@"flutter.sp_ble_key"]) {
            NSLog(@"[BleVerify] ✅ 拦截 flutter.sp_ble_key = %@", value);
            if ([value isKindOfClass:NSString.class]) {
                capturedBleKeyJson = value;
            } else if (value) {
                // 可能是 NSData
                capturedBleKeyJson = [[NSString alloc] initWithData:value
                                                           encoding:NSUTF8StringEncoding];
            }
            TryShowResult();
        }

        // 拦截车辆状态 (key 含 VIN)
        if ([defaultName containsString:@"CYUnifiedCarStatusInfos"] ||
            [defaultName containsString:@"LK6ADAH92RB765125"]) {
            NSLog(@"[BleVerify] ✅ 拦截状态 key=%@", defaultName);
            capturedStatusJson = SafeJSON(value);
            TryShowResult();
        }

        // 记录所有含 ble/key/status 的写入用于调试
        NSString *lower = defaultName.lowercaseString;
        if ([lower containsString:@"ble"] || [lower containsString:@"key"] ||
            [lower containsString:@"status"] || [lower containsString:@"car"]) {
            NSLog(@"[BleVerify] write: %@ = %@", defaultName,
                  [value isKindOfClass:NSString.class] ? value : NSStringFromClass([value class]));
        }
    } @catch (NSException *e) {
        NSLog(@"[BleVerify] hook exception: %@", e);
    }
}

- (id)objectForKey:(NSString *)defaultName {
    id result = %orig;

    @try {
        if (!defaultName) return result;

        // 读取时也检查
        if ([defaultName isEqualToString:@"flutter.sp_ble_key"] && result && !capturedBleKeyJson) {
            NSLog(@"[BleVerify] ✅ 读取到 flutter.sp_ble_key = %@", result);
            if ([result isKindOfClass:NSString.class]) {
                capturedBleKeyJson = result;
            }
            TryShowResult();
        }

        if ([defaultName containsString:@"CYUnifiedCarStatusInfos"] && result && !capturedStatusJson) {
            NSLog(@"[BleVerify] ✅ 读取到状态 key=%@", defaultName);
            capturedStatusJson = SafeJSON(result);
            TryShowResult();
        }
    } @catch (NSException *e) {
        NSLog(@"[BleVerify] objectForKey exception: %@", e);
    }

    return result;
}

%end

// ── 兜底：5 秒后如果没拦截到任何数据，弹诊断信息 ──────────────
static void ShowFallback(void) {
    if (alertShown) return;

    NSMutableString *msg = [NSMutableString string];
    [msg appendString:@"⚠️ 5秒内未拦截到 BLE 钥匙数据\n\n"];
    [msg appendString:@"可能原因:\n"];
    [msg appendString:@"1. 五菱 app 未登录/无钥匙\n"];
    [msg appendString:@"2. 数据不在 NSUserDefaults 中\n"];
    [msg appendString:@"3. 钥匙 key 名不是 flutter.sp_ble_key\n\n"];

    // 列出进程信息
    [msg appendFormat:@"进程: %@\n", NSProcessInfo.processInfo.processName];
    [msg appendFormat:@"Bundle: %@\n",
          [NSBundle mainBundle].bundleIdentifier ?: @"(nil)"];

    // 尝试列出 NSUserDefaults 所有 key
    NSDictionary *all = [[NSUserDefaults standardUserDefaults] dictionaryRepresentation];
    [msg appendFormat:@"\nNSUserDefaults 共 %lu keys:\n", (unsigned long)all.count];
    NSUInteger shown = 0;
    for (NSString *key in all) {
        if (shown >= 40) { [msg appendString:@"  ...\n"]; break; }
        id val = all[key];
        NSString *type = NSStringFromClass([val class]);
        if ([type isEqualToString:@"__NSCFString"] ||
            [type isEqualToString:@"NSTaggedPointerString"]) {
            NSString *preview = [val length] > 50
                ? [[val substringToIndex:50] stringByAppendingString:@"…"]
                : val;
            [msg appendFormat:@"  🔑 %@ = %@\n", key, preview];
        } else {
            [msg appendFormat:@"  🔑 %@ (%@)\n", key, type];
        }
        shown++;
    }

    ShowResultAlert(msg);
}

// ── %ctor ────────────────────────────────────────────────────
%ctor {
    @autoreleasepool {
        @try {
            NSLog(@"[BleVerify] loaded in %@", NSProcessInfo.processInfo.processName);

            // 5 秒兜底
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    ShowFallback();
                }
            );
        } @catch (NSException *e) {
            NSLog(@"[BleVerify] ctor exception: %@", e);
        }
    }
}
