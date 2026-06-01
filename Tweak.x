#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>

static void ShowAlert(NSString *title, NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
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

static NSString *SHA256Hex(NSString *input) {
    const char *str = [input UTF8String];
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(str, (CC_LONG)strlen(str), hash);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", hash[i]];
    }
    return hex;
}

// 10位随机字母数字
static NSString *RandomAlphaNum(int len) {
    NSString *chars = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    NSMutableString *s = [NSMutableString stringWithCapacity:len];
    for (int i = 0; i < len; i++) {
        [s appendFormat:@"%C", [chars characterAtIndex:arc4random_uniform((uint32_t)[chars length])]];
    }
    return s;
}

static NSString *DumpDict(NSDictionary *d) {
    if (!d) return @"(null)";
    NSMutableString *s = [NSMutableString string];
    for (NSString *key in d) {
        id val = [d objectForKey:key];
        if ([val isKindOfClass:[NSDictionary class]]) {
            [s appendFormat:@"  %@ = {..%lu keys..}\n", key, (unsigned long)[val count]];
        } else if ([val isKindOfClass:[NSArray class]]) {
            [s appendFormat:@"  %@ = [..%lu items..]\n", key, (unsigned long)[val count]];
        } else {
            NSString *desc = [val description];
            if ([desc length] > 100) desc = [[desc substringToIndex:100] stringByAppendingString:@"..."];
            [s appendFormat:@"  %@ = %@\n", key, desc];
        }
    }
    return s;
}

// Sync HTTP POST
static NSDictionary *SyncPost(NSString *urlStr, NSDictionary *body, NSDictionary *headers, NSString **errOut) {
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setHTTPMethod:@"POST"];
    [req setTimeoutInterval:15];
    for (NSString *key in headers) {
        [req setValue:[headers objectForKey:key] forHTTPHeaderField:key];
    }
    if (body) {
        NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        [req setHTTPBody:bodyData];
    } else {
        [req setHTTPBody:[@"{}" dataUsingEncoding:NSUTF8StringEncoding]];
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData *respData = nil;
    __block NSError *respErr = nil;
    __block NSInteger statusCode = 0;

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            respData = data;
            respErr = err;
            if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
                statusCode = [(NSHTTPURLResponse *)resp statusCode];
            }
            dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 20LL * NSEC_PER_SEC));

    if (respErr) {
        if (errOut) *errOut = [NSString stringWithFormat:@"网络错误: %@", [respErr localizedDescription]];
        return nil;
    }
    if (!respData) {
        if (errOut) *errOut = @"超时无响应";
        return nil;
    }
    if (statusCode != 200) {
        NSString *raw = [[NSString alloc] initWithData:respData encoding:NSUTF8StringEncoding];
        if (errOut) *errOut = [NSString stringWithFormat:@"HTTP %ld: %@", (long)statusCode, raw];
        return nil;
    }

    NSError *jsonErr = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:respData options:0 error:&jsonErr];
    if (jsonErr) {
        NSString *raw = [[NSString alloc] initWithData:respData encoding:NSUTF8StringEncoding];
        if (errOut) *errOut = [NSString stringWithFormat:@"JSON错误: %@", raw];
        return nil;
    }
    return json;
}

// ================================================================
// Main
// ================================================================
static void RunAll(void) {
    @try {
        NSMutableString *msg = [NSMutableString string];

        // == 1. Car Status ==
        [msg appendString:@"== Car Status ==\n"];
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        NSDictionary *all = [ud dictionaryRepresentation];
        for (NSString *key in all) {
            if ([key hasPrefix:@"CYUnifiedCarStatusInfosFor"]) {
                NSDictionary *st = [all objectForKey:key];
                if ([st isKindOfClass:[NSDictionary class]]) {
                    [msg appendFormat:@"[OK] bat:%@%% range:%@+%@km\n",
                          [st objectForKey:@"batterySoc"],
                          [st objectForKey:@"leftMileage"],
                          [st objectForKey:@"oilLeftMileage"]];
                    [msg appendFormat:@"mileage:%@km temp:%@C volt:%@V\n",
                          [st objectForKey:@"mileage"],
                          [st objectForKey:@"interiorTemperature"],
                          [st objectForKey:@"voltage"]];
                    break;
                }
            }
        }

        // == 2. Read Token from AppGroup ==
        [msg appendString:@"\n== Token ==\n"];
        NSString *oauthPath = @"/var/mobile/Containers/Shared/AppGroup/group.com.cloudy.LingLingBang/SavedOAuthModel";
        NSData *oauthData = [NSData dataWithContentsOfFile:oauthPath];
        if (!oauthData) {
            // Fallback: scan AppGroup for SavedOAuthModel
            NSString *appGroupBase = @"/var/mobile/Containers/Shared/AppGroup";
            NSFileManager *fm = [NSFileManager defaultManager];
            NSArray *uuids = [fm contentsOfDirectoryAtPath:appGroupBase error:nil];
            for (NSString *uuid in uuids) {
                NSString *c = [[appGroupBase stringByAppendingPathComponent:uuid]
                               stringByAppendingPathComponent:@"SavedOAuthModel"];
                if ([fm fileExistsAtPath:c]) {
                    oauthData = [NSData dataWithContentsOfFile:c];
                    if (oauthData) { oauthPath = c; break; }
                }
            }
        }
        if (!oauthData) {
            [msg appendString:@"[!] SavedOAuthModel not found\n"];
            ShowAlert(@"BLE Key", msg);
            return;
        }

        NSDictionary *oauth = [NSJSONSerialization JSONObjectWithData:oauthData options:0 error:nil];
        NSString *token = [oauth objectForKey:@"access_token"];
        if (!token) {
            [msg appendString:@"[!] no access_token\n"];
            ShowAlert(@"BLE Key", msg);
            return;
        }
        [msg appendString:@"[OK] Token found\n"];

        // == 3. Build headers (iOS mode, appVersion 5.2.15) ==
        // 毫秒时间戳 (13位)
        NSString *ts = [NSString stringWithFormat:@"%lld",
                         (long long)([[NSDate date] timeIntervalSince1970] * 1000)];
        NSString *nonce = [RandomAlphaNum(10) lowercaseString];

        // signStr = token + timestamp + nonce + clientId + clientSecret + appCode + appVersion + system + systemVersion
        NSString *signStr = [NSString stringWithFormat:@"%@%@%@%@%@%@%@%@%@",
                             token, ts, nonce,
                             @"2019041810222516127",
                             @"c5ad2a4290faa3df39683865c2e10310",
                             @"sgmw_llb",
                             @"5.2.15",
                             @"iOS",
                             @"15.4.1"];
        NSString *sig = SHA256Hex(signStr);

        NSDictionary *headers = @{
            @"Content-Type": @"application/json; charset=UTF-8",
            @"User-Agent": @"LingLingBang/5.2.15 (iPhone; iOS 15.4.1; Scale/3.00)",
            @"sgmwaccesstoken": token,
            @"sgmwtimestamp": ts,
            @"sgmwnonce": nonce,
            @"sgmwclientid": @"2019041810222516127",
            @"sgmwclientsecret": @"c5ad2a4290faa3df39683865c2e10310",
            @"sgmwappcode": @"sgmw_llb",
            @"sgmwappversion": @"5.2.15",
            @"sgmwsystem": @"iOS",
            @"sgmwsystemversion": @"15.4.1",
            @"sgmwsignature": sig,
        };

        // == 4. Step1: get VIN + phone ==
        [msg appendString:@"\n== VIN ==\n"];
        NSString *err1 = nil;
        NSDictionary *json1 = SyncPost(
            @"https://openapi.baojun.net/junApi/sgmw/userCarRelation/queryDefaultCarStatus",
            @{}, headers, &err1);

        if (err1) {
            [msg appendFormat:@"[!] %@\n", err1];
            ShowAlert(@"BLE Key", msg);
            return;
        }

        BOOL result1 = [[json1 objectForKey:@"result"] boolValue];
        if (!result1) {
            [msg appendFormat:@"[!] API error: %@\n", [json1 objectForKey:@"errorMessage"]];
            ShowAlert(@"BLE Key", msg);
            return;
        }

        NSDictionary *carInfo = [[json1 objectForKey:@"data"] objectForKey:@"carInfo"];
        NSString *vin = [carInfo objectForKey:@"vin"];
        NSString *phone = [carInfo objectForKey:@"bindCarUserMobile"];

        if (!vin) {
            [msg appendFormat:@"[!] No VIN\n%@\n", DumpDict(json1)];
            ShowAlert(@"BLE Key", msg);
            return;
        }
        [msg appendFormat:@"[OK] VIN=%@\nphone=%@\n", vin, phone ?: @"(nil)"];

        // == 5. Step2: BLE key query ==
        [msg appendString:@"\n== BLE Key ==\n"];
        NSMutableDictionary *body = [NSMutableDictionary dictionary];
        [body setObject:vin forKey:@"vin"];
        if (phone) [body setObject:phone forKey:@"userId"];

        NSString *err2 = nil;
        NSDictionary *json2 = SyncPost(
            @"https://openapi.baojun.net/junApi/sgmw/car/control/ble/key/query",
            body, headers, &err2);

        if (err2) {
            [msg appendFormat:@"[!] %@\n", err2];
            ShowAlert(@"BLE Key", msg);
            return;
        }

        BOOL result2 = [[json2 objectForKey:@"result"] boolValue];
        NSDictionary *d2 = [json2 objectForKey:@"data"];

        if (result2 && d2) {
            [msg appendString:@"[OK] BLE Key!\n\n"];
            NSString *mk = [d2 objectForKey:@"masterKey"];
            NSString *mac = [d2 objectForKey:@"bleMac"];
            NSString *kid = [d2 objectForKey:@"keyId"];
            NSString *kmr = [d2 objectForKey:@"keyMasterRandom"];
            NSString *kt = [d2 objectForKey:@"keyType"];
            NSString *et = [d2 objectForKey:@"endTime"];
            if (mk)  [msg appendFormat:@"masterKey: %@\n", mk];
            if (mac) [msg appendFormat:@"bleMac: %@\n", mac];
            if (kid) [msg appendFormat:@"keyId: %@\n", kid];
            if (kmr) [msg appendFormat:@"keyMasterRandom: %@\n", kmr];
            if (kt)  [msg appendFormat:@"keyType: %@\n", kt];
            if (et)  [msg appendFormat:@"endTime: %@\n", et];
            if (!mk && !mac) {
                [msg appendFormat:@"\nFull data:\n%@\n", DumpDict(d2)];
            }
        } else {
            [msg appendFormat:@"[!] %@\n%@\n",
                  [json2 objectForKey:@"errorMessage"],
                  DumpDict(json2)];
        }

        ShowAlert(@"BLE Key", msg);

    } @catch (NSException *e) {
        ShowAlert(@"Exception", [NSString stringWithFormat:@"%@\n%@", e.name, e.reason]);
    }
}

%ctor {
    @autoreleasepool {
        NSLog(@"[BleVerify] v14 loaded");
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [NSThread sleepForTimeInterval:3.0];
            RunAll();
        });
    }
}
