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

// The SAPISIDHASH header for one cookie header and origin. Kept separate from
// the stored credentials so a candidate cookie can be tested before it is
// saved over a working sign-in.
static NSString *LTAuthAuthorizationHeader(NSString *sapisid, NSString *origin) {
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
    // A pasted header often has "SAPISID=value ;" or a trailing space, and a
    // stray space in the value breaks the SAPISIDHASH digest for a cookie that
    // is otherwise correct.
    NSString *value = [cookieHeader substringWithRange:[match rangeAtIndex:2]];
    return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
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

// One pasted line reduced to the part that belongs in a Cookie: header — the
// devtools "Cookie:" name is stripped, quotes and tabs are dropped elsewhere.
- (NSString *)cookieEntryFromPastedLine:(NSString *)line {
    NSCharacterSet *space = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *entry = [line stringByTrimmingCharactersInSet:space];
    if (!entry.length) return nil;
    if ([[entry lowercaseString] hasPrefix:@"cookie:"]) {
        entry = [entry substringFromIndex:@"cookie:".length];
        entry = [entry stringByTrimmingCharactersInSet:space];
    }
    return entry;
}

// A paste arrives in whatever shape the user happened to copy: a bare SAPISID
// token, a "Cookie: …" header line, one cookie per line, or a quoted value.
// Sending any of those verbatim makes YouTube reject a cookie that is actually
// valid, which is exactly how a correct paste looked like a wrong one.
- (NSString *)normalizedCookieHeaderFromInput:(NSString *)input {
    if (!input.length) return nil;
    NSCharacterSet *space = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *text = [input stringByTrimmingCharactersInSet:space];
    if (!text.length) return nil;

    // A value copied with its surrounding quotes.
    if (text.length >= 2) {
        unichar first = [text characterAtIndex:0];
        unichar last = [text characterAtIndex:(NSUInteger)(text.length - 1)];
        BOOL doubleQuoted = (first == '"' && last == '"');
        BOOL singleQuoted = (first == '\'' && last == '\'');
        if ((doubleQuoted || singleQuoted) && text.length > 2) {
            text = [text substringWithRange:NSMakeRange(1, (NSUInteger)(text.length - 2))];
            text = [text stringByTrimmingCharactersInSet:space];
        }
    }

    NSArray *lines = [text componentsSeparatedByCharactersInSet:
                      [NSCharacterSet newlineCharacterSet]];
    if (lines.count > 1) {
        // Several requests headers / cookies pasted together: keep the pairs.
        NSMutableArray *parts = [NSMutableArray array];
        for (NSString *line in lines) {
            NSString *entry = [self cookieEntryFromPastedLine:line];
            if (!entry.length) continue;
            if ([entry rangeOfString:@"="].location == NSNotFound) continue;
            [parts addObject:entry];
        }
        if (parts.count) text = [parts componentsJoinedByString:@"; "];
    } else {
        NSString *entry = [self cookieEntryFromPastedLine:text];
        if (entry.length) text = entry;
    }

    text = [text stringByReplacingOccurrencesOfString:@"\t" withString:@" "];
    text = [text stringByTrimmingCharactersInSet:space];
    while (text.length && [text hasSuffix:@";"]) {
        text = [[text substringToIndex:(NSUInteger)(text.length - 1)]
                stringByTrimmingCharactersInSet:space];
    }
    if (!text.length) return nil;

    if ([text rangeOfString:@"="].location == NSNotFound) {
        // A bare token: treat it as the SAPISID value and synthesize the cookie
        // pairs YouTube Music expects.
        text = [NSString stringWithFormat:@"SAPISID=%@; __Secure-3PAPISID=%@", text, text];
    }
    return text;
}

- (void)setCredentialsWithCookieHeader:(NSString *)cookieHeader
                           accountName:(NSString *)accountName {
    NSString *trimmed = [self normalizedCookieHeaderFromInput:cookieHeader];
    if (!trimmed.length) return;

    [[NSUserDefaults standardUserDefaults] setObject:trimmed forKey:kLTAuthCookieHeader];
    if (accountName.length) {
        [[NSUserDefaults standardUserDefaults] setObject:accountName forKey:kLTAuthAccountName];
    }
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self notifyChange];
}

- (NSString *)cookieHeaderFromSharedStorage {
    NSArray *cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies];
    NSMutableArray *pairs = [NSMutableArray array];
    for (NSHTTPCookie *cookie in cookies) {
        if (![LTAuthCookieWhitelist() containsObject:cookie.name]) continue;
        if (!cookie.name.length || !cookie.value.length) continue;
        [pairs addObject:[NSString stringWithFormat:@"%@=%@", cookie.name, cookie.value]];
    }
    if (!pairs.count) return nil;
    // Sorted so the same cookie set always reads the same way; callers use
    // that to tell one candidate from the next without re-checking.
    NSArray *sorted = [pairs sortedArrayUsingSelector:@selector(compare:)];
    return [sorted componentsJoinedByString:@"; "];
}

- (BOOL)cookieHeaderHasSession:(NSString *)cookieHeader {
    if (!cookieHeader.length) return NO;
    if (LTAuthCookieValueForName(cookieHeader, @"SID").length) return YES;
    if (LTAuthCookieValueForName(cookieHeader, @"__Secure-1PSID").length) return YES;
    if (LTAuthCookieValueForName(cookieHeader, @"__Secure-3PSID").length) return YES;
    return NO;
}

- (NSString *)authorizationHeaderForOrigin:(NSString *)origin {
    return LTAuthAuthorizationHeader([self sapisid], origin);
}

- (NSString *)authorizationHeaderForCookieHeader:(NSString *)cookieHeader
                                          origin:(NSString *)origin {
    if (!cookieHeader.length) return nil;
    // Same preference order as -sapisid.
    NSString *sapisid = LTAuthCookieValueForName(cookieHeader, @"SAPISID");
    if (!sapisid.length) sapisid = LTAuthCookieValueForName(cookieHeader, @"__Secure-3PAPISID");
    if (!sapisid.length) sapisid = LTAuthCookieValueForName(cookieHeader, @"__Secure-1PAPISID");
    return LTAuthAuthorizationHeader(sapisid, origin);
}

- (void)signOut {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kLTAuthCookieHeader];
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:kLTAuthAccountName];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self notifyChange];
}

@end
