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

// DevTools hands out a "Cookie: a=b; c=d" header, some browsers wrap long
// values over several lines, and a copied Set-Cookie block also carries
// attributes (path, domain, expires, ...). Normalise all of that down to
// plain name=value pairs so the same paste works everywhere.
static NSString *LTAuthSanitizedCookieHeader(NSString *raw) {
    if (!raw.length) return nil;

    // Work line by line so a whole "Request Headers" block also works: drop a
    // leading "Cookie:" / "set-cookie:" label on each line, then treat the
    // remaining lines as cookie pairs (other headers simply don't parse).
    NSString *normalized = [raw stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *rawLine in [normalized componentsSeparatedByString:@"\n"]) {
        NSString *line = [rawLine stringByReplacingOccurrencesOfString:@"\t" withString:@" "];
        line = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!line.length) continue;
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location != NSNotFound) {
            NSString *label = [[line substringToIndex:colon.location] lowercaseString];
            label = [label stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([label isEqualToString:@"cookie"] || [label isEqualToString:@"set-cookie"]) {
                line = [line substringFromIndex:colon.location + 1];
            }
        }
        [lines addObject:line];
    }
    NSString *text = [lines componentsJoinedByString:@";"];

    NSSet *attributes = [NSSet setWithObjects:@"path", @"domain", @"expires", @"max-age",
                         @"secure", @"httponly", @"samesite", @"priority", @"version",
                         @"comment", @"discard", @"port", nil];
    NSMutableArray *pairs = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];

    for (NSString *rawPart in [text componentsSeparatedByString:@";"]) {
        NSString *part = [rawPart stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!part.length) continue;
        NSRange eq = [part rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;

        NSString *name = [[part substringToIndex:eq.location] stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *value = [[part substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!name.length || !value.length) continue;
        if ([name rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound) continue;
        if ([attributes containsObject:[name lowercaseString]]) continue;
        // Browsers quote values; YouTube compares them unquoted.
        if (value.length >= 2 && [value hasPrefix:@"\""] && [value hasSuffix:@"\""]) {
            value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
        }
        if ([seen containsObject:name]) continue;
        [seen addObject:name];
        [pairs addObject:[NSString stringWithFormat:@"%@=%@", name, value]];
    }

    if (!pairs.count) return nil;

    // OpenID/SAPISIDHASH auth wants __Secure-3PAPISID; the older SAPISID
    // pair carries the same value. Synthesize whichever is missing so a
    // paste of either name works.
    NSString *sapisid = nil;
    NSString *secure = nil;
    for (NSString *pair in pairs) {
        if ([pair hasPrefix:@"SAPISID="]) sapisid = [pair substringFromIndex:8];
        else if ([pair hasPrefix:@"__Secure-3PAPISID="]) secure = [pair substringFromIndex:18];
    }
    if (secure.length && !sapisid.length) {
        [pairs addObject:[@"SAPISID=" stringByAppendingString:secure]];
    } else if (sapisid.length && !secure.length) {
        [pairs addObject:[@"__Secure-3PAPISID=" stringByAppendingString:sapisid]];
    }

    return [pairs componentsJoinedByString:@"; "];
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
    // ytmusicapi and the web client sign with __Secure-3PAPISID; fall back to
    // the older names for cookies captured from browsers that omit it.
    NSString *value = LTAuthCookieValueForName(header, @"__Secure-3PAPISID");
    if (!value.length) value = LTAuthCookieValueForName(header, @"SAPISID");
    if (!value.length) value = LTAuthCookieValueForName(header, @"__Secure-1PAPISID");
    return value;
}

- (void)notifyChange {
    [[NSNotificationCenter defaultCenter] postNotificationName:LTAuthDidChangeNotification
                                                        object:nil];
}

- (void)updateAccountName:(NSString *)accountName {
    if (!accountName.length) return;
    [[NSUserDefaults standardUserDefaults] setObject:accountName forKey:kLTAuthAccountName];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

// Mirrors the captured cookies into NSHTTPCookieStorage. Even though the
// request sets an explicit Cookie header, the URL loading system is much more
// reliable when the same cookies also exist in the shared store (and it keeps
// them attached if a request has to be retried or redirected).
- (void)installCookiesIntoSharedStorage {
    NSString *header = [self cookieHeader];
    if (!header.length) return;

    NSHTTPCookieStorage *storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    storage.cookieAcceptPolicy = NSHTTPCookieAcceptPolicyAlways;

    for (NSString *part in [header componentsSeparatedByString:@";"]) {
        NSString *pair = [part stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSRange eq = [pair rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *name = [pair substringToIndex:eq.location];
        NSString *value = [pair substringFromIndex:eq.location + 1];
        if (!name.length || !value.length) continue;

        NSMutableDictionary *properties = [NSMutableDictionary dictionary];
        [properties setObject:name forKey:NSHTTPCookieName];
        [properties setObject:value forKey:NSHTTPCookieValue];
        [properties setObject:@".youtube.com" forKey:NSHTTPCookieDomain];
        [properties setObject:@"/" forKey:NSHTTPCookiePath];
        [properties setObject:@"TRUE" forKey:NSHTTPCookieSecure];
        [properties setObject:@"0" forKey:NSHTTPCookieVersion];
        [properties setObject:[NSDate dateWithTimeIntervalSinceNow:365 * 24 * 60 * 60]
                       forKey:NSHTTPCookieExpires];
        NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:properties];
        if (cookie) [storage setCookie:cookie];
    }
}

- (void)setCredentialsWithCookieHeader:(NSString *)cookieHeader
                           accountName:(NSString *)accountName {
    NSString *trimmed = [cookieHeader stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!trimmed.length) return;

    if ([trimmed rangeOfString:@"="].location == NSNotFound) {
        // A bare token: treat it as the SAPISID value and synthesize the
        // cookie pairs YouTube Music expects.
        trimmed = [NSString stringWithFormat:@"SAPISID=%@; __Secure-3PAPISID=%@", trimmed, trimmed];
    }

    NSString *sanitized = LTAuthSanitizedCookieHeader(trimmed) ?: trimmed;
    [[NSUserDefaults standardUserDefaults] setObject:sanitized forKey:kLTAuthCookieHeader];
    if (accountName.length) {
        [[NSUserDefaults standardUserDefaults] setObject:accountName forKey:kLTAuthAccountName];
    }
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self installCookiesIntoSharedStorage];
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
    // The web client hashes "<time> <SAPISID> <origin>" (SAPISID before the
    // origin). Getting this order wrong makes Google treat every request as
    // signed out, which is exactly what a "Sign in" card in the library means.
    NSString *payload = [NSString stringWithFormat:@"%lld %@ %@", seconds, sapisid, origin];

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

    // Drop the copies we mirrored into the shared cookie store as well.
    NSHTTPCookieStorage *storage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    NSArray *cookies = [[storage cookies] copy];
    for (NSHTTPCookie *cookie in cookies) {
        if (![LTAuthCookieWhitelist() containsObject:cookie.name]) continue;
        if ([cookie.domain rangeOfString:@"youtube.com"].location == NSNotFound &&
            [cookie.domain rangeOfString:@"google.com"].location == NSNotFound) continue;
        [storage deleteCookie:cookie];
    }

    [self notifyChange];
}

@end
