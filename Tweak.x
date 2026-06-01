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

static NSString *RandomHex(int len) {
    NSMutableString *s = [NSMutableString stringWithCapacity:len * 2];
    for (int i = 0; i < len; i++) {
        [s appendFormat:@"%02x", arc4random_uniform(256)];
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

// ================================================================
// Sync HTTP POST (blocks current thread)
// ================================================================
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
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData *responseData = nil;
    __block NSError *responseError = nil;
    __block NSInteger statusCode = 0;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            responseData = data;
            responseError = err;
            if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
                statusCode = [(NSHTTPURLResponse *)resp statusCode];
            }
            dispatch_semaphore_signal(sem);
        }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));

    if (responseError) {
        if (errOut) *errOut = [NSString stringWithFormat:@"网络错误: %@", [responseError localizedDescription]];
        return nil;
    }
    if (!responseData) {
        if (errOut) *errOut = @"无返回数据 (超时)";
        return nil;
    }
    if (statusCode != 200) {
        NSString *raw = [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding];
        if (errOut) *errOut = [NSString stringWithFormat:@"HTTP %ld: %@", (long)statusCode, raw];
        return nil;
    }

    NSError *jsonErr = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:&jsonErr];
    if (jsonErr) {
        NSString *raw = [[NSString alloc] initWithData:responseData encoding:NSUTF8StringEncoding];
        if (errOut) *errOut = [NSString stringWithFormat:@"JSON解析错误: %@\nRaw: %@", jsonErr.localizedDescription, raw];
        return nil;
    }
    return json;
}

// ================================================================
// Main: collect all info, then show ONE alert
// ================================================================
static void RunAll(void) {
    @try {
        NSMutableString *msg = [NSMutableString string];
        NSFileManager *fm = [NSFileManager defaultManager];

        // -- 1. Car Status --
        [msg appendString:@"== Car Status ==\n"];
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        NSDictionary *all = [ud dictionaryRepresentation];
        for (NSString *key in all) {
            if ([key hasPrefix:@"CYUnifiedCarStatusInfosFor"]) {
                NSDictionary *status = [all objectForKey:key];
                if ([status isKindOfClass:[NSDictionary class]]) {
                    [msg appendFormat:@"[OK] bat:%@%% range:%@+%@km\n",
                          [status objectForKey:@"batterySoc"],
                          [status objectForKey:@"leftMileage"],
                          [status objectForKey:@"oilLeftMileage"]];
                    [msg appendFormat:@"mileage:%@km temp:%@C volt:%@V\n",
                          [status objectForKey:@"mileage"],
                          [status objectForKey:@"interiorTemperature"],
                          [status objectForKey:@"voltage"]];
                    break;
                }
            }
        }

        // -- 2. Read Token --
        [msg appendString:@"\n== OAuth Token ==\n"];
        NSString *oauthPath = @"/var/mobile/Containers/Shared/AppGroup/C2FEACA3-9C36-4C24-B905-C0C2F1670B4C/SavedOAuthModel";
        NSData *oauthData = [NSData dataWithContentsOfFile:oauthPath];
        if (!oauthData) {
            // Fallback scan
            NSString *appGroupBase = @"/var/mobile/Containers/Shared/AppGroup";
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
            ShowAlert(@"BLE Key v13", msg);
            return;
        }

        NSError *jsonErr = nil;
        NSDictionary *oauth = [NSJSONSerialization JSONObjectWithData:oauthData options:0 error:&jsonErr];
        NSString *token = [oauth objectForKey:@"access_token"];
        if (!token) {
            [msg appendString:@"[!] no access_token\n"];
            ShowAlert(@"BLE Key v13", msg);
            return;
        }
        [msg appendString:@"[OK] Token found\n"];

        // -- 3. Build Signed Headers --
        NSString *ts = [NSString stringWithFormat:@"%lld", (long long)[[NSDate date] timeIntervalSince1970]];
        NSString *nonce = RandomHex(16);
        NSString *signStr = [NSString stringWithFormat:@"%@%@%@%@%@%@%@%@%@",
                             token, ts, nonce,
                             @"2019041810222516127", @"c5ad2a4290faa3df39683865c2e10310",
                             @"sgmw_llb", @"5.2.15", @"android", @"15"];
        NSString *sig = SHA256Hex(signStr);

        NSDictionary *headers = @{
            @"Content-Type": @"application/json",
            @"accessToken": token,
            @"timestamp": ts,
            @"nonce": nonce,
            @"clientId": @"2019041810222516127",
            @"clientSecret": @"c5ad2a4290faa3df39683865c2e10310",
            @"appCode": @"sgmw_llb",
            @"appVersion": @"5.2.15",
            @"sgmwsystem": @"android",
            @"sgmwappversion": @"5.2.15",
            @"signature": sig,
        };

        // -- 4. Step1: get VIN --
        [msg appendString:@"\n== Step1: VIN ==\n"];
        NSString *err1 = nil;
        NSDictionary *json1 = SyncPost(
            @"https://api.baojun.net/junApi/sgmw/userCarRelation/queryDefaultCarStatus",
            @{}, headers, &err1);

        if (err1) {
            [msg appendFormat:@"[!] %@\n", err1];
            ShowAlert(@"BLE Key v13", msg);
            return;
        }

        NSDictionary *d1 = [json1 objectForKey:@"data"];
        NSString *vin = [d1 objectForKey:@"vin"] ?: [d1 objectForKey:@"carVin"];
        NSString *userId = [d1 objectForKey:@"phone"] ?: [d1 objectForKey:@"userId"];

        if (!vin) {
            [msg appendFormat:@"[!] No VIN\n%@\n", DumpDict(json1)];
            ShowAlert(@"BLE Key v13", msg);
            return;
        }
        [msg appendFormat:@"[OK] VIN=%@\nuserId=%@\n", vin, userId];

        // -- 5. Step2: BLE key --
        [msg appendString:@"\n== Step2: BLE Key ==\n"];
        NSMutableDictionary *body = [NSMutableDictionary dictionary];
        [body setObject:vin forKey:@"vin"];
        if (userId) [body setObject:userId forKey:@"userId"];

        NSString *err2 = nil;
        NSDictionary *json2 = SyncPost(
            @"https://api.baojun.net/junApi/sgmw/car/control/ble/key/query",
            body, headers, &err2);

        if (err2) {
            [msg appendFormat:@"[!] %@\n", err2];
            ShowAlert(@"BLE Key v13", msg);
            return;
        }

        NSInteger code = [[json2 objectForKey:@"code"] integerValue];
        NSDictionary *d2 = [json2 objectForKey:@"data"];

        if (code == 200 && d2) {
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
                [msg appendFormat:@"\n返回数据:\n%@\n", DumpDict(d2)];
            }
        } else {
            [msg appendFormat:@"[!] code=%ld\n%@\n", (long)code, DumpDict(json2)];
        }

        // -- Done --
        ShowAlert(@"BLE Key v13", msg);

    } @catch (NSException *e) {
        ShowAlert(@"Exception", [NSString stringWithFormat:@"%@\n%@", e.name, e.reason]);
    }
}

%ctor {
    @autoreleasepool {
        NSLog(@"[BleVerify] v13 loaded");
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [NSThread sleepForTimeInterval:3.0];
            RunAll();
        });
    }
}
