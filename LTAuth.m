#import "LTAuth.h"
#import <CommonCrypto/CommonDigest.h>

NSString *const LTAuthDidChangeNotification = @"LTAuthDidChangeNotification";

static NSString *const kLTAuthCookieHeader = @"LTAuthCookieHeader";
static NSString *const kLTAuthAccountName = @"LTAuthAccountName";

// Cookies worth carrying on authenticated InnerTube requests.
static NSArray *LTAuthCookieWhitelist(void) {
    static NSArray *names = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = @[ @"SID",
                   @"HSID",
                   @"SSID",
                   @"APISID",
                   @"SAPISID",
                   @"__Secure-1PAPISID",
                   @"__Secure-3PAPISID",
                   @"__Secure-1PSID",
                   @"__Secure-3PSID",
                   @"__Secure-1PSIDTS",
                   @"__Secure-3PSIDTS",
                   @"__Secure-1PSIDCC",
                   @"__Secure-3PSIDCC",
                   @"SIDCC",
                   @"LOGIN_INFO",
                   @"VISITOR_INFO1_LIVE",
                   @"YSC" ];
    });
    return names;
}

static NSString *LTAuthCookieValueForName(NSString *cookieHeader, NSString *name) {
    if (!cookieHeader.length || !name.length) return nil;
    // Matches "name=value" separated by "; " (or surrounded by start/whitespace).
    NSString *pattern = [NSString stringWithFormat:@"(?:^|;[ ]*|\\s)(%@)=([^;\\r\\n]+)", name];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                           options:0
                                                                             error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:cookieHeader
                                                    options:0
                                                      range:NSMakeRange(0, cookieHeader.length)];
    if (match.numberOfRanges < 3) return nil;
    return [cookieHeader substringWithRange:[match rangeAtIndex:2]];
}

@implementation LTAuth

+ (instancetype)sharedAuth {
    static LTAuth *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[LTAuth alloc] init];
    });
    return shared;
}

- (BOOL)signedIn {
    return [self sapisid].length > 0;
}

- (NSString *)accountName {
    NSString *name = [[NSUserDefaults standardUserDefaults] stringForKey:kLTAuthAccountName];
    return name ?: @"";
}

- (NSString *)cookieHeader {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kLTAuthCookieHeader] ?: @"";
}

- (NSString *)sapisid {
    NSString *header = [self cookieHeader];
    NSString *value = LTAuthCookieValueForName(header, @"SAPISID");
    if (!value.length) value = LTAuthCookieValueForName(header, @"__Secure-3PAPISID");
    if (!value.length) value = LTAuthCookieValueForName(header, @"__Secure-1PAPISID");
    return value;
}

- (void)notifyChange {
    [[NSNotificationCenter defaultCenter] postNotificationName:LTAuthDidChangeNotification
                                                        object:nil];
}

- (void)setCredentialsWithCookieHeader:(NSString *)cookieHeader
                           accountName:(NSString *)accountName {
    NSString *trimmed = [cookieHeader stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!trimmed.length) return;

    if ([trimmed rangeOfString:@"="].location == NSNotFound) {
        // A bare token: treat it as the SAPISID value and synthesize the
        // cookie pair YouTube Music expects.
        trimmed = [NSString stringWithFormat:@"SAPISID=%@; __Secure-3PAPISID=%@", trimmed, trimmed];
    }

    [[NSUserDefaults standardUserDefaults] setObject:trimmed forKey:kLTAuthCookieHeader];
    if (accountName.length) {
        [[NSUserDefaults standardUserDefaults] setObject:accountName forKey:kLTAuthAccountName];
    }
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self notifyChange];
}

- (BOOL)adoptCookiesFromSharedStorage {
    NSArray *cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies];
    NSMutableArray *pairs = [NSMutableArray array];
    for (NSHTTPCookie *cookie in cookies) {
        if (![LTAuthCookieWhitelist() containsObject:cookie.name]) continue;
        [pairs addObject:[NSString stringWithFormat:@"%@=%@", cookie.name, cookie.value]];
    }
    if (!pairs.count) return NO;

    NSString *header = [pairs componentsJoinedByString:@"; "];
    // Keep an existing account name if one is already stored.
    [self setCredentialsWithCookieHeader:header accountName:[self accountName]];
    return YES;
}

- (NSString *)authorizationHeaderForOrigin:(NSString *)origin {
    NSString *sapisid = [self sapisid];
    if (!sapisid.length || !origin.length) return nil;

    NSTimeInterval interval = [[NSDate date] timeIntervalSince1970];
    long long seconds = (long long)interval;
    NSString *payload = [NSString stringWithFormat:@"%lld %@ %@", seconds, origin, sapisid];

    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    NSData *data = [payload dataUsingEncoding:NSUTF8StringEncoding];
    CC_SHA1([data bytes], (CC_LONG)[data length], digest);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [NSString stringWithFormat:@"SAPISIDHASH %lld_%@", seconds, hex];
}

- (void)signOut {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kLTAuthCookieHeader];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kLTAuthAccountName];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self notifyChange];
}

@end
