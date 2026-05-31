#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// ── 文件路径 ────────────────────────────────────────────────
static NSString *const kPlistPath =
    @"/var/mobile/Library/Preferences/com.cloudy.LingLingBang.plist";

// 读取 plist 返回指定 key，失败返回 nil
static id ReadPref(NSString *key) {
    @try {
        static NSDictionary *cache = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            cache = [NSDictionary dictionaryWithContentsOfFile:kPlistPath];
            NSLog(@"[BleVerify] plist read %@: %@",
                  cache ? @"OK" : @"FAIL", kPlistPath);
        });
        return key ? cache[key] : nil;
    } @catch (NSException *e) {
        NSLog(@"[BleVerify] ReadPref exception: %@", e);
        return nil;
    }
}

// ── 弹窗：显示 BLE 钥匙 ────────────────────────────────────
static void ShowBleKeyAlert(void) {
    @try {
        // ── 读 BLE 钥匙 JSON ───────────────────────────────
        NSString *keyJson = ReadPref(@"flutter.sp_ble_key");
        NSDictionary *bleKey = nil;
        if ([keyJson isKindOfClass:NSString.class]) {
            NSData *data = [keyJson dataUsingEncoding:NSUTF8StringEncoding];
            if (data) {
                bleKey = [NSJSONSerialization JSONObjectWithData:data
                                                        options:0
                                                          error:nil];
            }
        }

        // ── 读车辆状态（VIN 用实际值匹配）────────────────────
        // 状态 key 名含 VIN，用前缀遍历找到它
        NSDictionary *status = nil;
        NSString *vin = bleKey[@"vin"] ?: @"LK6ADAH92RB765125";
        NSString *statusKey =
            [@"CYUnifiedCarStatusInfosFor" stringByAppendingString:vin];
        id raw = ReadPref(statusKey);
        if ([raw isKindOfClass:NSDictionary.class]) {
            status = raw;
        }

        // ── 拼接消息文本 ───────────────────────────────────
        NSMutableString *msg = [NSMutableString string];

        if (bleKey) {
            [msg appendString:@"✅ BLE 钥匙数据读取成功\n\n"];
            [msg appendFormat:@"🔑 masterKey: %@\n",     bleKey[@"masterKey"]];
            [msg appendFormat:@"📱 userId:    %@\n",     bleKey[@"userId"]];
            [msg appendFormat:@"📡 bleMac:    %@\n",     bleKey[@"bleMac"]];
            [msg appendFormat:@"🆔 keyId:     %@\n",     bleKey[@"keyId"]];
            [msg appendFormat:@"🚗 VIN:       %@\n",     bleKey[@"vin"]];
            [msg appendFormat:@"🎲 random:    %@\n",     bleKey[@"keyMasterRandom"]];
            [msg appendFormat:@"👤 keyType:   %@\n",     bleKey[@"keyType"]];
            [msg appendFormat:@"⏳ endTime:   %@\n",     bleKey[@"endTime"]];
        } else {
            [msg appendString:@"❌ BLE 钥匙数据未找到\n"];
            [msg appendFormat:@"  flutter.sp_ble_key = %@\n",
                  [keyJson class] ?: @"nil"];
        }

        if (status) {
            [msg appendString:@"\n── 车辆状态 ──\n"];
            [msg appendFormat:@"🔋 电量:      %@%%\n",   status[@"batterySoc"]];
            [msg appendFormat:@"📏 续航:      %@km\n",    status[@"oilLeftMileage"]];
            [msg appendFormat:@"🛣 里程:      %@km\n",    status[@"mileage"]];
            [msg appendFormat:@"🔒 车锁:      %@\n",
                  [status[@"doorLockStatus"] intValue] == 0 ? @"已锁" : @"未锁"];
            [msg appendFormat:@"🌡 车内温度:   %@°C\n",   status[@"interiorTemperature"]];
            [msg appendFormat:@"⚡ 电压:      %@V\n",     status[@"voltage"]];
            [msg appendFormat:@"❄️ 空调:      %@\n",
                  [status[@"acStatus"] intValue] == 1 ? @"开" : @"关"];
        } else {
            [msg appendString:@"\n❌ 车辆状态未找到\n"];
        }

        // ── 主线程弹窗 ─────────────────────────────────────
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                UIAlertController *alert =
                    [UIAlertController alertControllerWithTitle:@"🔍 BLE 钥匙验证"
                                                       message:msg
                                                preferredStyle:UIAlertControllerStyleAlert];

                [alert addAction:
                    [UIAlertAction actionWithTitle:@"复制全部"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
                    UIPasteboard *pb = [UIPasteboard generalPasteboard];
                    pb.string = msg ?: @"";
                }]];

                [alert addAction:
                    [UIAlertAction actionWithTitle:@"关闭"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];

                // 找顶层 VC 呈现
                UIViewController *top = nil;
                for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                    if ([scene isKindOfClass:UIWindowScene.class]) {
                        UIWindowScene *ws = (UIWindowScene *)scene;
                        for (UIWindow *w in ws.windows) {
                            if (w.isKeyWindow) {
                                top = w.rootViewController;
                                break;
                            }
                        }
                    }
                    if (top) break;
                }
                if (!top) {
                    top = UIApplication.sharedApplication.keyWindow.rootViewController;
                }
                // 向上找到最顶层 presented VC
                while (top.presentedViewController) {
                    top = top.presentedViewController;
                }
                if (top) {
                    [top presentViewController:alert animated:YES completion:nil];
                    NSLog(@"[BleVerify] alert presented");
                } else {
                    NSLog(@"[BleVerify] no rootViewController found");
                }
            } @catch (NSException *e) {
                NSLog(@"[BleVerify] alert exception: %@", e);
            }
        });

        // 也输出到 syslog
        NSLog(@"[BleVerify] bleKey=%@\nstatus=%@", bleKey, status);

    } @catch (NSException *e) {
        NSLog(@"[BleVerify] ShowBleKeyAlert exception: %@", e);
    }
}

// ── Hook: 在第一个有效 viewDidAppear 时弹窗 ────────────────
%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;

    // 只弹一次
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 延迟 1.5s 等 app 完全启动、root VC 就绪
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
            dispatch_get_main_queue(),
            ^{
                ShowBleKeyAlert();
            }
        );
    });
}

%end
