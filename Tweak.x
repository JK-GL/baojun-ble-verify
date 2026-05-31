#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// ── 主弹窗：诊断 plist 存储 ─────────────────────────────────
static void ShowDiagnosticAlert(void) {
    @try {
        NSMutableString *msg = [NSMutableString string];

        // ── 1. 检查已知路径 ─────────────────────────────────
        NSArray *paths = @[
            @"/var/mobile/Library/Preferences/com.cloudy.LingLingBang.plist",
            @"/var/mobile/Library/Preferences/com.cloudyoung.linglingbang.plist",
            @"/var/mobile/Library/Preferences/com.cloudy.LingLingBang.prefs.plist",
        ];

        [msg appendString:@"── 路径检查 ──\n"];
        for (NSString *p in paths) {
            BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:p];
            [msg appendFormat:@"%@ %@\n", exists ? @"✅" : @"❌", p.lastPathComponent];
        }

        // ── 2. 扫描 Preferences 目录找五菱相关 plist ─────────
        [msg appendString:@"\n── Preferences 目录扫描 ──\n"];
        NSString *prefDir = @"/var/mobile/Library/Preferences";
        NSError *err = nil;
        NSArray *files = [[NSFileManager defaultManager]
                          contentsOfDirectoryAtPath:prefDir error:&err];
        NSMutableArray *related = [NSMutableArray array];
        for (NSString *f in files) {
            NSString *lower = f.lowercaseString;
            if ([lower containsString:@"cloudy"] ||
                [lower containsString:@"lingling"] ||
                [lower containsString:@"wuling"] ||
                [lower containsString:@"sgmw"] ||
                [lower containsString:@"cyunified"] ||
                [lower containsString:@"cybaojun"]) {
                [related addObject:f];
            }
        }
        if (related.count > 0) {
            for (NSString *f in related) {
                [msg appendFormat:@"  📄 %@\n", f];
            }
        } else {
            [msg appendString:@"  (未找到五菱相关 plist)\n"];
            // 列出所有 plist 前10个供参考
            NSUInteger count = MIN(files.count, 15);
            [msg appendFormat:@"  前 %lu 个 plist:\n", (unsigned long)count];
            for (NSUInteger i = 0; i < count; i++) {
                [msg appendFormat:@"  📄 %@\n", files[i]];
            }
            if (files.count > count) {
                [msg appendFormat:@"  ... 共 %lu 个文件\n", (unsigned long)files.count];
            }
        }

        // ── 3. 读五菱 plist 所有 key ────────────────────────
        NSString *wulingPlist = [prefDir stringByAppendingPathComponent:
                                 @"com.cloudy.LingLingBang.plist"];
        NSDictionary *allPrefs = [NSDictionary dictionaryWithContentsOfFile:wulingPlist];
        [msg appendFormat:@"\n── 五菱 plist keys (%lu) ──\n",
              (unsigned long)allPrefs.count];
        if (allPrefs.count > 0) {
            for (NSString *key in allPrefs) {
                id val = allPrefs[key];
                NSString *type = NSStringFromClass([val class]);
                NSString *preview = @"";
                if ([val isKindOfClass:NSString.class]) {
                    preview = [val length] > 80
                        ? [[val substringToIndex:80] stringByAppendingString:@"…"]
                        : val;
                } else if ([val isKindOfClass:NSNumber.class]) {
                    preview = [val stringValue];
                } else if ([val isKindOfClass:NSDictionary.class]) {
                    preview = [NSString stringWithFormat:@"{%lu keys}",
                               (unsigned long)[val count]];
                } else if ([val isKindOfClass:NSArray.class]) {
                    preview = [NSString stringWithFormat:@"[%lu items]",
                               (unsigned long)[val count]];
                }
                [msg appendFormat:@"  🔑 %@ (%@) = %@\n", key, type, preview];
            }
        } else {
            [msg appendString:@"  (plist 为空或不存在)\n"];
        }

        // ── 4. NSUserDefaults domain 读取 ───────────────────
        NSUserDefaults *ud = [[NSUserDefaults alloc]
                              initWithSuiteName:@"com.cloudy.LingLingBang"];
        NSDictionary *udDict = [ud dictionaryRepresentation];
        [msg appendFormat:@"\n── NSUserDefaults (%lu) ──\n",
              (unsigned long)udDict.count];
        if (udDict.count > 0) {
            NSUInteger shown = 0;
            for (NSString *key in udDict) {
                if (shown >= 30) {
                    [msg appendFormat:@"  ... 共 %lu keys\n",
                          (unsigned long)udDict.count];
                    break;
                }
                id val = udDict[key];
                NSString *type = NSStringFromClass([val class]);
                NSString *preview = @"";
                if ([val isKindOfClass:NSString.class]) {
                    preview = [val length] > 60
                        ? [[val substringToIndex:60] stringByAppendingString:@"…"]
                        : val;
                } else if ([val isKindOfClass:NSNumber.class]) {
                    preview = [val stringValue];
                } else if ([val isKindOfClass:NSDictionary.class]) {
                    preview = [NSString stringWithFormat:@"{%lu keys}",
                               (unsigned long)[val count]];
                }
                [msg appendFormat:@"  🔑 %@ (%@) = %@\n", key, type, preview];
                shown++;
            }
        } else {
            [msg appendString:@"  (无数据)\n"];
        }

        // ── 5. 查找所有含 "ble_key" 或 "sp_ble" 的 key ──────
        [msg appendString:@"\n── BLE 钥匙关键字搜索 ──\n"];
        BOOL found = NO;
        if (allPrefs) {
            for (NSString *key in allPrefs) {
                NSString *lower = key.lowercaseString;
                if ([lower containsString:@"ble"] ||
                    [lower containsString:@"key"] ||
                    [lower containsString:@"blekey"] ||
                    [lower containsString:@"sp_ble"] ||
                    [lower containsString:@"digital"] ||
                    [lower containsString:@"cyunified"] ||
                    [lower containsString:@"statusinfos"]) {
                    id val = allPrefs[key];
                    NSString *type = NSStringFromClass([val class]);
                    [msg appendFormat:@"  🎯 %@ (%@)\n", key, type];
                    found = YES;
                }
            }
        }
        if (!found) {
            [msg appendString:@"  (无匹配 key)\n"];
        }

        // ── 主线程弹窗 ─────────────────────────────────────
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                UIAlertController *alert =
                    [UIAlertController alertControllerWithTitle:@"🔍 诊断结果"
                                                       message:msg
                                                preferredStyle:UIAlertControllerStyleAlert];

                [alert addAction:
                    [UIAlertAction actionWithTitle:@"复制全部"
                                             style:UIAlertActionStyleDefault
                                           handler:^(UIAlertAction *a) {
                    UIPasteboard.generalPasteboard.string = msg;
                }]];

                [alert addAction:
                    [UIAlertAction actionWithTitle:@"关闭"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];

                // 找顶层 VC
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
                while (top.presentedViewController) {
                    top = top.presentedViewController;
                }
                if (top) {
                    [top presentViewController:alert animated:YES completion:nil];
                }
            } @catch (NSException *e) {
                NSLog(@"[BleVerify] alert exception: %@", e);
            }
        });

        NSLog(@"[BleVerify] diagnostic:\n%@", msg);

    } @catch (NSException *e) {
        NSLog(@"[BleVerify] exception: %@", e);
    }
}

// ── Hook ─────────────────────────────────────────────────────
%hook UIViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                ShowDiagnosticAlert();
            }
        );
    });
}

%end
