#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>

static BOOL alertShown = NO;
static NSString *savedToken = nil;

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
// Hook SavedOAuthModel to capture token
// ================================================================
%hook SavedOAuthModel

- (void)setAccessToken:(NSString *)token {
    NSLog(@"[BleVerify] SavedOAuthModel setAccessToken: %@...", [token substringToIndex:MIN(30, token.length)]);
    savedToken = token;
    %orig;
}

- (NSString *)accessToken {
    NSString *token = %orig;
    if (token && !savedToken) {
        NSLog(@"[BleVerify] SavedOAuthModel accessToken => %@...", [token substringToIndex:MIN(30, token.length)]);
        savedToken = token;
    }
    return token;
}

// Try common init methods
- (id)initWithDictionary:(NSDictionary *)dict {
    id result = %orig;
    if (dict) {
        NSString *t = [dict objectForKey:@"access_token"];
        if (t) {
            NSLog(@"[BleVerify] SavedOAuthModel initWithDict access_token: %@...", [t substringToIndex:MIN(30, t.length)]);
            savedToken = t;
        }
    }
    return result;
}

- (void)setValuesForKeysWithDictionary:(NSDictionary *)keyedValues {
    %orig;
    if (keyedValues) {
        NSString *t = [keyedValues objectForKey:@"access_token"];
        if (t) {
            NSLog(@"[BleVerify] SavedOAuthModel setValuesForKeys access_token: %@...", [t substringToIndex:MIN(30, t.length)]);
            savedToken = t;
        }
    }
}

%end

// ================================================================
// Also hook CYBaoJunOAuthJSONSString read to find decryption
// ================================================================
// Hook NSUserDefaults to capture when the app reads the OAuth key
%hook NSUserDefaults

- (id)objectForKey:(NSString *)defaultName {
    id result = %orig;

    if ([defaultName isEqualToString:@"CYBaoJunOAuthJSONSString"] && result) {
        NSLog(@"[BleVerify] objectForKey CYBaoJunOAuthJSONSString => class=%@", NSStringFromClass([result class]));

        // If it's already a dict (decrypted), capture token
        if ([result isKindOfClass:[NSDictionary class]]) {
            NSString *t = [result objectForKey:@"access_token"];
            if (t && !savedToken) {
                savedToken = t;
                NSLog(@"[BleVerify] Got token from dict: %@...", [t substringToIndex:MIN(30, t.length)]);
            }
        }
    }

    return result;
}

- (void)setObject:(id)value forKey:(NSString *)defaultName {
    %orig;

    @try {
        if (!defaultName) return;

        // Capture any token-related writes
        if ([defaultName isEqualToString:@"CYBaoJunOAuthJSONSString"]) {
            NSLog(@"[BleVerify] setObject CYBaoJunOAuthJSONSString class=%@", NSStringFromClass([value class]));
        }

        // Capture BLE key writes
        NSString *kl = [defaultName lowercaseString];
        if ([kl containsString:@"sp_ble"] || [kl containsString:@"flutter"] ||
            [kl containsString:@"blekey"] || [kl containsString:@"masterkey"]) {
            NSLog(@"[BleVerify] BLE write: %@ = %@", defaultName, value);
            if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 20) {
                NSMutableString *msg = [NSMutableString string];
                [msg appendString:@"[OK] BLE key intercepted!\n\n"];
                [msg appendFormat:@"Key: %@\nValue:\n%@\n", defaultName, value];
                ShowAlert(@"BLE Key Write", msg);
            }
        }

        if ([defaultName hasPrefix:@"CYUnifiedCarStatusInfos"]) {
            NSLog(@"[BleVerify] Car status updated: %@", defaultName);
        }
    } @catch (NSException *e) {
        NSLog(@"[BleVerify] hook exception: %@", e);
    }
}

%end

// ================================================================
// Online fetch function
// ================================================================
static void FetchBLEKey(NSString *accessToken) {
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

    // Step 1: Get VIN + phone
    NSURL *url1 = [NSURL URLWithString:@"https://api.baojun.net/junApi/sgmw/userCarRelation/queryDefaultCarStatus"];
    NSMutableURLRequest *req1 = [NSMutableURLRequest requestWithURL:url1];
    [req1 setHTTPMethod:@"POST"];
    for (NSString *key in headers) {
        [req1 setValue:[headers objectForKey:key] forHTTPHeaderField:key];
    }
    [req1 setHTTPBody:[@"{}" dataUsingEncoding:NSUTF8StringEncoding]];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req1
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
                ShowAlert(@"Step1 No VIN", DumpDict(json));
                return;
            }

            // Step 2: Get BLE key
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

            [[[NSURLSession sharedSession] dataTaskWithRequest:req2
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
                        [msg appendFormat:@"[X] code=%ld\nVIN=%@ userId=%@\n\n%@\n",
                              (long)code, vin, userId, DumpDict(json2)];
                    }
                    ShowAlert(@"BLE Key", msg);
            }] resume];
    }] resume];
}

// ================================================================
// Startup
// ================================================================
static void TryFetch(void) {
    if (savedToken) {
        NSLog(@"[BleVerify] Token captured, starting fetch...");
        FetchBLEKey(savedToken);
        return;
    }

    // Wait a bit more for token
    NSLog(@"[BleVerify] No token yet, waiting 2s...");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (savedToken) {
            FetchBLEKey(savedToken);
        } else {
            // Show diagnostic
            NSMutableString *msg = [NSMutableString string];
            [msg appendString:@"-- Car Status --\n"];
            NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
            NSDictionary *all = [ud dictionaryRepresentation];
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

            [msg appendString:@"\n-- Token Status --\n"];
            [msg appendString:@"[X] SavedOAuthModel not loaded yet\n\n"];
            [msg appendString:@"Hooks active:\n"];
            [msg appendString:@"  SavedOAuthModel.accessToken (setter/getter)\n"];
            [msg appendString:@"  SavedOAuthModel.initWithDictionary:\n"];
            [msg appendString:@"  NSUserDefaults.CYBaoJunOAuthJSONSString\n\n"];
            [msg appendString:@"The token will be captured when the\n"];
            [msg appendString:@"app loads it, then auto-fetch runs.\n\n"];
            [msg appendString:@"Or navigate to a screen that\n"];
            [msg appendString:@"triggers OAuth token loading.\n"];

            ShowAlert(@"BLE Key v8", msg);
        }
    });
}

%ctor {
    @autoreleasepool {
        NSLog(@"[BleVerify] v8 loaded in %@", [[NSProcessInfo processInfo] processName]);

        // Start after 3s
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ TryFetch(); });
    }
}
