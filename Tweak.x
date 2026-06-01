#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>

static BOOL alertShown = NO;

// -- Constants --
static NSString *const kClientId     = @"2019041810222516127";
static NSString *const kClientSecret = @"c5ad2a4290faa3df39683865c2e10310";
static NSString *const kAppCode      = @"sgmw_llb";
static NSString *const kAppVersion   = @"5.2.15";
static NSString *const kBaseURL      = @"https://api.baojun.net";
static NSString *const kControlURL   = @"https://openapi.baojun.net";

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

// -- SHA256 --
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

// -- Generate random hex string --
static NSString *RandomHex(int len) {
    NSMutableString *s = [NSMutableString stringWithCapacity:len * 2];
    for (int i = 0; i < len; i++) {
        [s appendFormat:@"%02x", arc4random_uniform(256)];
    }
    return s;
}

// -- Build signed headers --
static NSDictionary *BuildHeaders(NSString *accessToken) {
    NSString *timestamp = [NSString stringWithFormat:@"%lld", (long long)[[NSDate date] timeIntervalSince1970]];
    NSString *nonce = RandomHex(16);
    NSString *signStr = [NSString stringWithFormat:@"%@%@%@%@%@%@%@%@",
                         accessToken ?: @"", timestamp, nonce,
                         kClientId, kClientSecret, kAppCode, kAppVersion,
                         @"android", @"15"];
    NSString *signature = SHA256Hex(signStr);

    return @{
        @"Content-Type": @"application/json",
        @"accessToken": accessToken ?: @"",
        @"timestamp": timestamp,
        @"nonce": nonce,
        @"clientId": kClientId,
        @"clientSecret": kClientSecret,
        @"appCode": kAppCode,
        @"appVersion": kAppVersion,
        @"sgmwsystem": @"android",
        @"sgmwappversion": kAppVersion,
        @"signature": signature,
    };
}

// -- Make POST request --
static void PostRequest(NSString *urlStr, NSDictionary *body, NSDictionary *headers,
                        void(^callback)(NSDictionary *json, NSString *error)) {
    NSURL *url = [NSURL URLWithString:urlStr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setHTTPMethod:@"POST"];

    for (NSString *key in headers) {
        [req setValue:[headers objectForKey:key] forHTTPHeaderField:key];
    }

    if (body) {
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
        [req setHTTPBody:jsonData];
    }

    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) {
                callback(nil, [error localizedDescription]);
                return;
            }
            if (!data) {
                callback(nil, @"No data");
                return;
            }
            NSError *jsonErr = nil;
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
            if (jsonErr) {
                NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                callback(nil, [NSString stringWithFormat:@"JSON error: %@\nRaw: %@", jsonErr.localizedDescription, raw]);
                return;
            }
            callback(json, nil);
        }];
    [task resume];
}

// -- Dump dict --
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
// MAIN: Fetch BLE key online
// ================================================================
static void FetchBLEKeyOnline(void) {
    @try {
        // Step 0: Read OAuth token
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        NSString *oauthStr = [ud objectForKey:@"CYBaoJunOAuthJSONSString"];
        if (!oauthStr || ![oauthStr isKindOfClass:[NSString class]]) {
            ShowAlert(@"Error", @"No OAuth token found.\nCYBaoJunOAuthJSONSString is nil.\nPlease login in the app first.");
            return;
        }

        NSError *jsonErr = nil;
        NSDictionary *oauth = [NSJSONSerialization JSONObjectWithData:[oauthStr dataUsingEncoding:NSUTF8StringEncoding]
                                                              options:0 error:&jsonErr];
        NSString *accessToken = [oauth objectForKey:@"access_token"];
        if (!accessToken) {
            ShowAlert(@"Error", [NSString stringWithFormat:@"No access_token in OAuth:\n%@\nJSON err: %@",
                                 oauthStr, jsonErr]);
            return;
        }

        NSLog(@"[BleVerify] Token: %@...", [accessToken substringToIndex:MIN(20, accessToken.length)]);
        NSDictionary *headers = BuildHeaders(accessToken);

        // Step 1: Query default car status to get VIN + phone
        NSDictionary *statusBody = @{};
        NSString *statusURL = [NSString stringWithFormat:@"%@/junApi/sgmw/userCarRelation/queryDefaultCarStatus", kBaseURL];

        PostRequest(statusURL, statusBody, headers, ^(NSDictionary *json, NSString *error) {
            if (error) {
                ShowAlert(@"Step 1 Error", error);
                return;
            }
            NSLog(@"[BleVerify] Step1 response: %@", json);

            NSDictionary *data = [json objectForKey:@"data"];
            NSString *vin = [data objectForKey:@"vin"];
            NSString *userId = [data objectForKey:@"phone"] ?: [data objectForKey:@"userId"];

            if (!vin) {
                // Try alternate paths
                vin = [data objectForKey:@"carVin"];
            }
            if (!vin) {
                ShowAlert(@"Step 1", [NSString stringWithFormat:@"No VIN found.\nResponse:\n%@\n\ndata:\n%@",
                                      DumpDict(json), DumpDict(data)]);
                return;
            }

            NSLog(@"[BleVerify] VIN=%@ userId=%@", vin, userId);

            // Step 2: Query BLE key
            NSMutableDictionary *keyBody = [NSMutableDictionary dictionary];
            [keyBody setObject:vin forKey:@"vin"];
            if (userId) {
                [keyBody setObject:userId forKey:@"userId"];
            }

            NSString *keyURL = [NSString stringWithFormat:@"%@/junApi/sgmw/car/control/ble/key/query", kBaseURL];

            PostRequest(keyURL, keyBody, headers, ^(NSDictionary *json2, NSString *error2) {
                if (error2) {
                    ShowAlert(@"Step 2 Error", [NSString stringWithFormat:@"VIN=%@\nuserId=%@\n\n%@",
                                                vin, userId, error2]);
                    return;
                }
                NSLog(@"[BleVerify] Step2 response: %@", json2);

                NSDictionary *data2 = [json2 objectForKey:@"data"];
                NSInteger code = [[json2 objectForKey:@"code"] integerValue];

                NSMutableString *msg = [NSMutableString string];

                if (code == 200 && data2) {
                    [msg appendString:@"[OK] BLE Key Retrieved Online!\n\n"];
                    [msg appendFormat:@"VIN: %@\n", vin];
                    [msg appendFormat:@"userId: %@\n\n", userId];

                    // Extract key fields
                    NSString *masterKey = [data2 objectForKey:@"masterKey"];
                    NSString *bleMac = [data2 objectForKey:@"bleMac"];
                    NSString *keyId = [data2 objectForKey:@"keyId"];
                    NSString *keyMasterRandom = [data2 objectForKey:@"keyMasterRandom"];
                    NSString *keyType = [data2 objectForKey:@"keyType"];
                    NSString *endTime = [data2 objectForKey:@"endTime"];

                    if (masterKey) [msg appendFormat:@"masterKey: %@\n", masterKey];
                    if (bleMac)    [msg appendFormat:@"bleMac: %@\n", bleMac];
                    if (keyId)     [msg appendFormat:@"keyId: %@\n", keyId];
                    if (keyMasterRandom) [msg appendFormat:@"keyMasterRandom: %@\n", keyMasterRandom];
                    if (keyType)   [msg appendFormat:@"keyType: %@\n", keyType];
                    if (endTime)   [msg appendFormat:@"endTime: %@\n", endTime];

                    if (!masterKey && !bleMac) {
                        [msg appendString:@"\n-- Full data keys --\n"];
                        [msg appendString:DumpDict(data2)];
                    }
                } else {
                    [msg appendFormat:@"[X] API returned code=%ld\n\n", (long)code];
                    [msg appendFormat:@"VIN: %@\nuserId: %@\n\n", vin, userId];
                    [msg appendString:DumpDict(json2)];
                }

                ShowAlert(@"BLE Key Online", msg);
            });
        });

    } @catch (NSException *e) {
        ShowAlert(@"Exception", [NSString stringWithFormat:@"%@\n%@", e.name, e.reason]);
    }
}

// ================================================================
// Startup
// ================================================================
static void ShowStartupAndFetch(void) {
    @try {
        // Show car status first
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        NSDictionary *all = [ud dictionaryRepresentation];

        NSMutableString *msg = [NSMutableString string];
        [msg appendString:@"-- Car Status --\n"];
        NSDictionary *status = nil;
        for (NSString *key in all) {
            if ([key hasPrefix:@"CYUnifiedCarStatusInfosFor"]) {
                id val = [all objectForKey:key];
                if ([val isKindOfClass:[NSDictionary class]]) { status = val; break; }
            }
        }
        if (status) {
            [msg appendFormat:@"[OK] bat:%@%% mileage:%@km\n",
                  [status objectForKey:@"batterySoc"],
                  [status objectForKey:@"mileage"]];
        }

        // Check OAuth
        NSString *oauthStr = [ud objectForKey:@"CYBaoJunOAuthJSONSString"];
        if (oauthStr) {
            NSDictionary *oauth = [NSJSONSerialization JSONObjectWithData:[oauthStr dataUsingEncoding:NSUTF8StringEncoding]
                                                                  options:0 error:nil];
            NSString *token = [oauth objectForKey:@"access_token"];
            if (token) {
                [msg appendFormat:@"\n[OK] OAuth token found (%lu chars)\n", (unsigned long)token.length];
                [msg appendString:@"\nFetching BLE key online...\n"];
                ShowAlert(@"BLE Key Fetch v7", msg);

                // Start the fetch after showing status
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                               dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    FetchBLEKeyOnline();
                });
            } else {
                [msg appendString:@"\n[X] No access_token in OAuth\n"];
                ShowAlert(@"BLE Key Fetch v7", msg);
            }
        } else {
            [msg appendString:@"\n[X] No OAuth token\n"];
            [msg appendString:@"Please login in the app first.\n"];
            ShowAlert(@"BLE Key Fetch v7", msg);
        }

    } @catch (NSException *e) {
        ShowAlert(@"Exception", [NSString stringWithFormat:@"%@\n%@", e.name, e.reason]);
    }
}

%ctor {
    @autoreleasepool {
        NSLog(@"[BleVerify] v7 loaded in %@", [[NSProcessInfo processInfo] processName]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ ShowStartupAndFetch(); });
    }
}
