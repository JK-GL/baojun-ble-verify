#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>

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
// online fetch BLE key
// ================================================================
static void FetchBLEKey(NSString *accessToken, NSString *vin, NSString *userId) {
    @try {
        // build signed headers
        NSString *ts = [NSString stringWithFormat:@"%lld", (long long)[[NSDate date] timeIntervalSince1970]];
        NSString *nonce = RandomHex(16);
        NSString *signStr = [NSString stringWithFormat:@"%@%@%@%@%@%@%@%@%@",
                             accessToken, ts, nonce,
                             @"2019041810222516127", @"c5ad2a4290faa3df39683865c2e10310",
                             @"sgmw_llb", @"5.2.15", @"android", @"15"];
        NSString *signature = SHA256Hex(signStr);

        NSDictionary *headers = @{
            @"Content-Type": @"application/json",
            @"accessToken": accessToken,
            @"timestamp": ts,
            @"nonce": nonce,
            @"clientId": @"2019041810222516127",
            @"clientSecret": @"c5ad2a4290faa3df39683865c2e10310",
            @"appCode": @"sgmw_llb",
            @"appVersion": @"5.2.15",
            @"sgmwsystem": @"android",
            @"sgmwappversion": @"5.2.15",
            @"signature": signature,
        };

        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

        // If no VIN, get it first
        if (!vin) {
            NSURL *url1 = [NSURL URLWithString:@"https://api.baojun.net/junApi/sgmw/userCarRelation/queryDefaultCarStatus"];
            NSMutableURLRequest *req1 = [NSMutableURLRequest requestWithURL:url1];
            [req1 setHTTPMethod:@"POST"];
            for (NSString *key in headers) { [req1 setValue:[headers objectForKey:key] forHTTPHeaderField:key]; }
            [req1 setHTTPBody:[@"{}" dataUsingEncoding:NSUTF8StringEncoding]];

            [[session dataTaskWithRequest:req1 completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                if (err || !data) {
                    ShowAlert(@"Step1 Error", err ? [err localizedDescription] : @"No data");
                    return;
                }
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSLog(@"[BleVerify] Step1: %@", json);

                NSDictionary *d = [json objectForKey:@"data"];
                NSString *gotVin = [d objectForKey:@"vin"] ?: [d objectForKey:@"carVin"];
                NSString *gotUser = [d objectForKey:@"phone"] ?: [d objectForKey:@"userId"];

                if (!gotVin) {
                    ShowAlert(@"No VIN", DumpDict(json));
                    return;
                }

                FetchBLEKey(accessToken, gotVin, gotUser);
            }] resume];
            return;
        }

        // Step 2: BLE key query
        NSMutableDictionary *body = [NSMutableDictionary dictionary];
        [body setObject:vin forKey:@"vin"];
        if (userId) [body setObject:userId forKey:@"userId"];
        NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

        NSURL *url2 = [NSURL URLWithString:@"https://api.baojun.net/junApi/sgmw/car/control/ble/key/query"];
        NSMutableURLRequest *req2 = [NSMutableURLRequest requestWithURL:url2];
        [req2 setHTTPMethod:@"POST"];
        for (NSString *key in headers) { [req2 setValue:[headers objectForKey:key] forHTTPHeaderField:key]; }
        [req2 setHTTPBody:bodyData];

        [[session dataTaskWithRequest:req2 completionHandler:^(NSData *data2, NSURLResponse *resp2, NSError *err2) {
            if (err2 || !data2) {
                ShowAlert(@"Step2 Error", err2 ? [err2 localizedDescription] : @"No data");
                return;
            }
            NSDictionary *json2 = [NSJSONSerialization JSONObjectWithData:data2 options:0 error:nil];
            NSLog(@"[BleVerify] Step2: %@", json2);

            NSDictionary *d2 = [json2 objectForKey:@"data"];
            NSInteger code = [[json2 objectForKey:@"code"] integerValue];

            NSMutableString *msg = [NSMutableString string];
            if (code == 200 && d2) {
                [msg appendString:@"[OK] BLE Key Online!\n\n"];
                [msg appendFormat:@"VIN: %@\nuserId: %@\n\n", vin, userId];
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
                [msg appendFormat:@"[X] code=%ld\n\n%@\n", (long)code, DumpDict(json2)];
            }
            ShowAlert(@"BLE Key", msg);
        }] resume];

    } @catch (NSException *e) {
        ShowAlert(@"Exception", [NSString stringWithFormat:@"%@\n%@", e.name, e.reason]);
    }
}

// ================================================================
// startup
// ================================================================
static void Startup(void) {
    @try {
        // 1. Read car status
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        NSDictionary *all = [ud dictionaryRepresentation];

        NSMutableString *msg = [NSMutableString string];
        [msg appendString:@"-- Car Status --\n"];
        for (NSString *key in all) {
            if ([key hasPrefix:@"CYUnifiedCarStatusInfosFor"]) {
                NSDictionary *status = [all objectForKey:key];
                if ([status isKindOfClass:[NSDictionary class]]) {
                    id bat = [status objectForKey:@"batterySoc"];
                    id rangeE = [status objectForKey:@"leftMileage"];
                    id rangeO = [status objectForKey:@"oilLeftMileage"];
                    id ml = [status objectForKey:@"mileage"];
                    [msg appendFormat:@"[OK] bat:%@%% range:%@+%@km mileage:%@km\n", bat, rangeE, rangeO, ml];
                    break;
                }
            }
        }

        // 2. Read SavedOAuthModel from AppGroup
        NSFileManager *fm = [NSFileManager defaultManager];
        NSData *oauthData = nil;
        NSString *foundPath = nil;

        // Try multiple possible group identifiers
        NSArray *groupIds = @[
            @"group.com.cloudy.LingLingBang",
            @"group.com.cloudyoung.linglingbang",
            @"group.com.cloudy.linglingbang",
            @"group.baojun",
            @"group.sgmw",
        ];

        for (NSString *groupId in groupIds) {
            NSURL *groupURL = [fm containerURLForSecurityApplicationGroupIdentifier:groupId];
            if (groupURL) {
                NSString *candidate = [[groupURL path] stringByAppendingPathComponent:@"SavedOAuthModel"];
                if ([fm fileExistsAtPath:candidate]) {
                    oauthData = [NSData dataWithContentsOfFile:candidate];
                    if (oauthData) {
                        foundPath = candidate;
                        break;
                    }
                }
            }
        }

        // If not found, try to read from known path pattern
        if (!oauthData) {
            // Also try direct path with common UUID patterns
            NSString *appGroupBase = @"/var/mobile/Containers/Shared/AppGroup";
            NSArray *groupUUIDs = [fm contentsOfDirectoryAtPath:appGroupBase error:nil];
            for (NSString *uuid in groupUUIDs) {
                NSString *candidate = [[appGroupBase stringByAppendingPathComponent:uuid]
                                       stringByAppendingPathComponent:@"SavedOAuthModel"];
                if ([fm fileExistsAtPath:candidate]) {
                    oauthData = [NSData dataWithContentsOfFile:candidate];
                    if (oauthData) {
                        foundPath = candidate;
                        break;
                    }
                }
            }
        }

        if (!oauthData) {
            [msg appendString:@"\n[!] SavedOAuthModel not found\n"];
            [msg appendString:@"Tried group IDs:\n"];
            for (NSString *gid in groupIds) {
                NSURL *url = [fm containerURLForSecurityApplicationGroupIdentifier:gid];
                [msg appendFormat:@"  %@ => %@\n", gid, url ? [url path] : @"nil"];
            }
            ShowAlert(@"BLE Key v10", msg);
            return;
        }

        [msg appendFormat:@"\n[OK] Found: %@\n", foundPath];

        NSError *jsonErr = nil;
        NSDictionary *oauth = [NSJSONSerialization JSONObjectWithData:oauthData options:0 error:&jsonErr];
        NSString *token = [oauth objectForKey:@"access_token"];

        if (!token) {
            [msg appendString:@"\n[!] No access_token in file\n"];
            [msg appendFormat:@"  Content: %@\n", [[NSString alloc] initWithData:oauthData encoding:NSUTF8StringEncoding]];
            ShowAlert(@"BLE Key v10", msg);
            return;
        }

        [msg appendString:@"\n[OK] Token from SavedOAuthModel\n"];
        [msg appendFormat:@"  Token: %@...\n\n", [token substringToIndex:MIN(40, token.length)]];
        [msg appendString:@"Fetching BLE key online...\n"];

        ShowAlert(@"BLE Key v10", msg);

        // 3. Fetch BLE key
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            FetchBLEKey(token, nil, nil);
        });

    } @catch (NSException *e) {
        ShowAlert(@"Exception", [NSString stringWithFormat:@"%@\n%@", e.name, e.reason]);
    }
}

%ctor {
    @autoreleasepool {
        NSLog(@"[BleVerify] v10 loaded in %@", [[NSProcessInfo processInfo] processName]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ Startup(); });
    }
}
