#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <objc/runtime.h>

static BOOL alertShown = NO;
static NSString *capturedToken = nil;
static BOOL fetchStarted = NO;

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
// Scan runtime for OAuth-related classes
// ================================================================
static void ScanOAuthClasses(void) {
    int numClasses = objc_getClassList(NULL, 0);
    Class *classes = (Class *)malloc(sizeof(Class) * numClasses);
    objc_getClassList(classes, numClasses);

    NSMutableString *found = [NSMutableString string];
    for (int i = 0; i < numClasses; i++) {
        NSString *name = NSStringFromClass(classes[i]);
        NSString *lower = [name lowercaseString];
        if ([lower containsString:@"oauth"] || [lower containsString:@"token"] ||
            [lower containsString:@"saved"] || [lower containsString:@"auth"] ||
            [lower containsString:@"login"] || [lower containsString:@"session"]) {
            [found appendFormat:@"  %@\n", name];
        }
    }
    free(classes);

    if ([found length] > 0) {
        NSLog(@"[BleVerify] OAuth/Auth classes:\n%@", found);
    }
}

// ================================================================
// Hook NSURLSession to intercept token from request headers
// ================================================================
%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    @try {
        NSString *token = [request valueForHTTPHeaderField:@"accessToken"];
        if (token && token.length > 20 && !capturedToken) {
            capturedToken = token;
            NSLog(@"[BleVerify] Token captured from network request: %@...", [token substringToIndex:MIN(30, token.length)]);

            // Show what URL was using this token
            NSLog(@"[BleVerify] URL: %@", [[request URL] absoluteString]);

            // Auto-fetch BLE key
            if (!fetchStarted) {
                fetchStarted = YES;
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    // Small delay to let more requests complete
                    [NSThread sleepForTimeInterval:1.0];

                    NSMutableString *msg = [NSMutableString string];
                    [msg appendString:@"[OK] Token captured from network!\n\n"];
                    [msg appendFormat:@"URL: %@\n", [[request URL] absoluteString]];
                    [msg appendFormat:@"Token: %@...\n\n", [token substringToIndex:MIN(40, token.length)]];
                    [msg appendString:@"Starting BLE key fetch...\n"];
                    ShowAlert(@"Token Captured", msg);
                });
            }
        }

        // Also check for other header names
        if (!capturedToken) {
            NSString *auth = [request valueForHTTPHeaderField:@"Authorization"];
            if (auth && auth.length > 20) {
                NSLog(@"[BleVerify] Authorization header: %@...", [auth substringToIndex:MIN(30, auth.length)]);
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[BleVerify] session hook exception: %@", e);
    }

    return %orig;
}

%end

// ================================================================
// Also hook NSUserDefaults to capture OAuth-related writes
// ================================================================
%hook NSUserDefaults

- (void)setObject:(id)value forKey:(NSString *)defaultName {
    %orig;

    @try {
        if (!defaultName) return;
        NSString *kl = [defaultName lowercaseString];

        // BLE key write
        if ([kl containsString:@"sp_ble"] || [kl containsString:@"flutter.sp"] ||
            [kl containsString:@"blekey"] || [kl containsString:@"masterkey"]) {
            NSLog(@"[BleVerify] BLE key write: %@", defaultName);
            if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 20) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSMutableString *msg = [NSMutableString string];
                    [msg appendString:@"[OK] BLE key write intercepted!\n\n"];
                    [msg appendFormat:@"Key: %@\n\n", defaultName];
                    [msg appendFormat:@"Value:\n%@\n", value];
                    ShowAlert(@"BLE Key Write", msg);
                });
            }
        }

        // OAuth-related writes
        if ([kl containsString:@"oauth"] || [kl containsString:@"token"] ||
            [kl containsString:@"access"]) {
            NSLog(@"[BleVerify] OAuth write: %@ class=%@", defaultName, NSStringFromClass([value class]));
        }
    } @catch (NSException *e) {}
}

%end

// ================================================================
// Fetch BLE key online
// ================================================================
static void FetchBLEKey(NSString *accessToken) {
    // Build signed request
    NSString *timestamp = [NSString stringWithFormat:@"%lld", (long long)[[NSDate date] timeIntervalSince1970]];
    NSString *nonce = RandomHex(16);
    NSString *signStr = [NSString stringWithFormat:@"%@%@%@%@%@%@%@%@%@",
                         accessToken, timestamp, nonce,
                         @"2019041810222516127", @"c5ad2a4290faa3df39683865c2e10310",
                         @"sgmw_llb", @"5.2.15", @"android", @"15"];
    NSString *signature = SHA256Hex(signStr);

    NSDictionary *headers = @{
        @"Content-Type": @"application/json",
        @"accessToken": accessToken,
        @"timestamp": timestamp,
        @"nonce": nonce,
        @"clientId": @"2019041810222516127",
        @"clientSecret": @"c5ad2a4290faa3df39683865c2e10310",
        @"appCode": @"sgmw_llb",
        @"appVersion": @"5.2.15",
        @"sgmwsystem": @"android",
        @"sgmwappversion": @"5.2.15",
        @"signature": signature,
    };

    // Step 1: Get VIN
    NSURL *url1 = [NSURL URLWithString:@"https://api.baojun.net/junApi/sgmw/userCarRelation/queryDefaultCarStatus"];
    NSMutableURLRequest *req1 = [NSMutableURLRequest requestWithURL:url1];
    [req1 setHTTPMethod:@"POST"];
    for (NSString *key in headers) {
        [req1 setValue:[headers objectForKey:key] forHTTPHeaderField:key];
    }
    [req1 setHTTPBody:[@"{}" dataUsingEncoding:NSUTF8StringEncoding]];

    // Use a plain session to avoid our hook
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    [[session dataTaskWithRequest:req1
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            if (err || !data) {
                ShowAlert(@"Step1 Error", err ? [err localizedDescription] : @"No data");
                return;
            }
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSLog(@"[BleVerify] Step1: %@", json);

            NSDictionary *d = [json objectForKey:@"data"];
            NSString *vin = [d objectForKey:@"vin"] ?: [d objectForKey:@"carVin"];
            NSString *userId = [d objectForKey:@"phone"] ?: [d objectForKey:@"userId"];

            if (!vin) {
                ShowAlert(@"No VIN", DumpDict(json));
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
            for (NSString *key in headers) {
                [req2 setValue:[headers objectForKey:key] forHTTPHeaderField:key];
            }
            [req2 setHTTPBody:bodyData];

            [[session dataTaskWithRequest:req2
                completionHandler:^(NSData *data2, NSURLResponse *resp2, NSError *err2) {
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
    }] resume];
}

// ================================================================
// Startup
// ================================================================
static void Startup(void) {
    // Scan runtime for OAuth classes
    ScanOAuthClasses();

    // Show car status
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSDictionary *all = [ud dictionaryRepresentation];

    NSMutableString *msg = [NSMutableString string];
    [msg appendString:@"-- Car Status --\n"];
    for (NSString *key in all) {
        if ([key hasPrefix:@"CYUnifiedCarStatusInfosFor"]) {
            NSDictionary *status = [all objectForKey:key];
            if ([status isKindOfClass:[NSDictionary class]]) {
                [msg appendFormat:@"[OK] bat:%@%% mileage:%@km\n",
                      [status objectForKey:@"batterySoc"],
                      [status objectForKey:@"mileage"]];
                break;
            }
        }
    }

    [msg appendString:@"\n-- Token Capture --\n"];
    [msg appendString:@"Hook: NSURLSession dataTaskWithRequest:\n"];
    [msg appendString:@"Waiting for app to make API request...\n\n"];
    [msg appendString:@"The token will be captured from\n"];
    [msg appendString:@"the accessToken header automatically.\n"];
    [msg appendString:@"Then BLE key will be fetched online.\n"];

    ShowAlert(@"BLE Key v9", msg);

    // Periodically check if token was captured
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (capturedToken && !fetchStarted) {
            fetchStarted = YES;
            FetchBLEKey(capturedToken);
        }
    });
}

%ctor {
    @autoreleasepool {
        NSLog(@"[BleVerify] v9 loaded in %@", [[NSProcessInfo processInfo] processName]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ Startup(); });
    }
}
