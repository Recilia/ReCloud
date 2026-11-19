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

static NSString *LTAuthTrimmed(NSString *value) {
    return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static BOOL LTAuthIsCookieAttribute(NSString *name) {
    static NSSet *attributes = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        attributes = [NSSet setWithObjects:@"path", @"domain", @"expires", @"max-age",
                      @"secure", @"httponly", @"samesite", @"priority", @"version",
                      @"comment", @"discard", @"port", nil];
    });
    return [attributes containsObject:[name lowercaseString]];
}

static void LTAuthAddCookiePair(NSString *rawName, NSString *rawValue,
                                NSMutableArray *pairs, NSMutableSet *seen) {
    NSString *name = LTAuthTrimmed(rawName);
    NSString *value = LTAuthTrimmed(rawValue);
    if (!name.length || !value.length) return;

    // Cookie names are tokens. This rejects header names such as
    // ":authority" and fragments of a URL pulled out of a cURL command.
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-."];
    if ([name rangeOfCharacterFromSet:[allowed invertedSet]].location != NSNotFound) return;
    if (LTAuthIsCookieAttribute(name)) return;

    // Browsers quote values; YouTube compares them unquoted.
    if (value.length >= 2 && [value hasPrefix:@"\""] && [value hasSuffix:@"\""]) {
        value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
    }
    // A Set-Cookie value can be followed by attributes; keep only the value.
    NSRange semicolon = [value rangeOfString:@";"];
    if (semicolon.location != NSNotFound) {
        value = LTAuthTrimmed([value substringToIndex:semicolon.location]);
    }
    if (!value.length) return;
    if ([seen containsObject:name]) return;
    [seen addObject:name];
    [pairs addObject:[NSString stringWithFormat:@"%@=%@", name, value]];
}

// Continuation lines inside a wrapped "cookie:" block start with a real
// cookie name, unlike the other request headers that may surround them.
static BOOL LTAuthLineLooksLikeCookiePair(NSString *line) {
    NSString *lower = [line lowercaseString];
    for (NSString *name in LTAuthCookieWhitelist()) {
        NSString *prefix = [[name lowercaseString] stringByAppendingString:@"="];
        if ([lower hasPrefix:prefix]) return YES;
    }
    return NO;
}

// Accepts a raw "SID=...; HSID=..." blob, a "Cookie:" header, a whole
// Request Headers block, and multi-line wraps of any of those.
static void LTAuthCollectCookieBlob(NSString *blob, NSMutableArray *pairs, NSMutableSet *seen) {
    if (!blob.length) return;
    NSString *text = [blob stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSArray *rawLines = [text componentsSeparatedByString:@"\n"];

    BOOL hasCookieLabel = NO;
    for (NSString *rawLine in rawLines) {
        NSString *line = LTAuthTrimmed(rawLine);
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *label = [LTAuthTrimmed([line substringToIndex:colon.location]) lowercaseString];
        if ([label isEqualToString:@"cookie"] || [label isEqualToString:@"set-cookie"]) {
            hasCookieLabel = YES;
            break;
        }
    }

    for (NSString *rawLine in rawLines) {
        NSString *line = LTAuthTrimmed(rawLine);
        if (!line.length || [line hasPrefix:@"#"]) continue;

        BOOL labelled = NO;
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location != NSNotFound) {
            NSString *label = [LTAuthTrimmed([line substringToIndex:colon.location]) lowercaseString];
            if ([label isEqualToString:@"cookie"] || [label isEqualToString:@"set-cookie"]) {
                line = LTAuthTrimmed([line substringFromIndex:colon.location + 1]);
                labelled = YES;
            }
        }
        if (hasCookieLabel && !labelled && !LTAuthLineLooksLikeCookiePair(line)) continue;
        if (!line.length) continue;

        for (NSString *rawPart in [line componentsSeparatedByString:@";"]) {
            NSString *part = LTAuthTrimmed(rawPart);
            if (!part.length) continue;
            NSRange eq = [part rangeOfString:@"="];
            if (eq.location == NSNotFound) continue;
            LTAuthAddCookiePair([part substringToIndex:eq.location],
                                [part substringFromIndex:eq.location + 1], pairs, seen);
        }
    }
}

// Netscape cookies.txt, as exported by browser extensions and yt-dlp:
// domain<TAB>flag<TAB>path<TAB>secure<TAB>expiry<TAB>name<TAB>value
static BOOL LTAuthCollectNetscapeCookies(NSString *text, NSMutableArray *pairs, NSMutableSet *seen) {
    NSUInteger before = pairs.count;
    for (NSString *rawLine in [text componentsSeparatedByString:@"\n"]) {
        NSString *line = LTAuthTrimmed(rawLine);
        if (!line.length) continue;
        if ([line hasPrefix:@"#HttpOnly_"]) {
            line = [line substringFromIndex:[@"#HttpOnly_" length]];
        } else if ([line hasPrefix:@"#"]) {
            continue;
        }
        NSArray *fields = [line componentsSeparatedByString:@"\t"];
        if (fields.count < 7) continue;
        NSString *domain = [[fields objectAtIndex:0] lowercaseString];
        if (![domain hasSuffix:@"youtube.com"] && ![domain hasSuffix:@"google.com"] &&
            ![domain hasSuffix:@"googleusercontent.com"]) continue;
        LTAuthAddCookiePair([fields objectAtIndex:5], [fields objectAtIndex:6], pairs, seen);
    }
    return pairs.count > before;
}

static BOOL LTAuthTextLooksLikeCurl(NSString *text) {
    NSString *lower = [text lowercaseString];
    NSRange curl = [lower rangeOfString:@"curl"];
    if (curl.location == NSNotFound) return NO;
    if (curl.location > 0) {
        unichar previous = [lower characterAtIndex:curl.location - 1];
        if (![[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:previous]) return NO;
    }
    return ([lower rangeOfString:@"-h "].location != NSNotFound ||
            [lower rangeOfString:@"--header"].location != NSNotFound ||
            [lower rangeOfString:@"-b "].location != NSNotFound ||
            [lower rangeOfString:@"--cookie"].location != NSNotFound);
}

// "Copy as cURL" from Chrome, Edge, Firefox or Safari. Handles bash ("\")
// and Windows cmd ("^") line continuations and single or double quotes.
static void LTAuthCollectFromCurl(NSString *text, NSMutableArray *pairs, NSMutableSet *seen) {
    // cmd.exe escapes quotes as ^" and continues lines with a trailing ^.
    NSString *clean = [text stringByReplacingOccurrencesOfString:@"^" withString:@""];
    NSString *pattern = @"(?:^|\\s)(--header|--cookie|-H|-b)(?:=|\\s+)(?:'([^']*)'|\"([^\"]*)\"|(\\S+))";
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                           options:0
                                                                             error:nil];
    NSArray *matches = [regex matchesInString:clean options:0 range:NSMakeRange(0, clean.length)];
    for (NSTextCheckingResult *match in matches) {
        NSString *flag = [[clean substringWithRange:[match rangeAtIndex:1]] lowercaseString];
        NSString *value = nil;
        for (NSUInteger index = 2; index <= 4; index++) {
            NSRange range = [match rangeAtIndex:index];
            if (range.location != NSNotFound) {
                value = [clean substringWithRange:range];
                break;
            }
        }
        if (!value.length) continue;

        if ([flag isEqualToString:@"-b"] || [flag isEqualToString:@"--cookie"]) {
            // A bare path here would be a cookie file, which we can't read.
            if ([value rangeOfString:@"="].location == NSNotFound) continue;
            LTAuthCollectCookieBlob(value, pairs, seen);
            continue;
        }

        NSRange colon = [value rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *header = [LTAuthTrimmed([value substringToIndex:colon.location]) lowercaseString];
        if (![header isEqualToString:@"cookie"]) continue;
        LTAuthCollectCookieBlob([value substringFromIndex:colon.location + 1], pairs, seen);
    }
}

// DevTools "Copy object" / extensions that export JSON.
static void LTAuthCollectCookieJSONObject(id object, NSMutableArray *pairs,
                                          NSMutableSet *seen, BOOL insideCookieArray) {
    if ([object isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = object;
        BOOL cookieObject = insideCookieArray;
        if (!cookieObject) {
            // Cookie-Editor and similar tools export an array of objects such
            // as {"domain":".youtube.com","name":"SID","value":"..."}.
            cookieObject = ([dictionary objectForKey:@"domain"] != nil ||
                            [dictionary objectForKey:@"path"] != nil ||
                            [dictionary objectForKey:@"expirationDate"] != nil ||
                            [dictionary objectForKey:@"httpOnly"] != nil);
        }
        if (cookieObject) {
            id name = [dictionary objectForKey:@"name"];
            id value = [dictionary objectForKey:@"value"];
            if ([name isKindOfClass:[NSString class]] && [value isKindOfClass:[NSString class]]) {
                LTAuthAddCookiePair(name, value, pairs, seen);
            }
        }
        for (id key in dictionary) {
            if (![key isKindOfClass:[NSString class]]) continue;
            id value = [dictionary objectForKey:key];
            NSString *lower = [key lowercaseString];
            if ([lower isEqualToString:@"cookie"] && [value isKindOfClass:[NSString class]]) {
                LTAuthCollectCookieBlob(value, pairs, seen);
            } else if ([lower isEqualToString:@"cookies"] && [value isKindOfClass:[NSArray class]]) {
                for (id entry in (NSArray *)value) {
                    if ([entry isKindOfClass:[NSDictionary class]]) {
                        LTAuthCollectCookieJSONObject(entry, pairs, seen, YES);
                    } else if ([entry isKindOfClass:[NSString class]]) {
                        LTAuthCollectCookieBlob(entry, pairs, seen);
                    }
                }
            } else if ([value isKindOfClass:[NSDictionary class]] ||
                       [value isKindOfClass:[NSArray class]]) {
                LTAuthCollectCookieJSONObject(value, pairs, seen, NO);
            }
        }
    } else if ([object isKindOfClass:[NSArray class]]) {
        for (id entry in (NSArray *)object) {
            LTAuthCollectCookieJSONObject(entry, pairs, seen, insideCookieArray);
        }
    }
}

// DevTools hands out a "Cookie: a=b; c=d" header, browsers wrap long values,
// and a copied Set-Cookie block also carries attributes (path, domain, ...).
// Accept all of those, plus "Copy as cURL", JSON and Netscape cookies.txt, so
// the user only has to right-click once.
static NSString *LTAuthSanitizedCookieHeader(NSString *raw) {
    if (!raw.length) return nil;

    NSString *text = [raw stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    NSMutableArray *pairs = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];

    if (LTAuthCollectNetscapeCookies(text, pairs, seen)) {
        // Netscape export.
    } else if (LTAuthTextLooksLikeCurl(text)) {
        LTAuthCollectFromCurl(text, pairs, seen);
    } else {
        NSString *trimmed = LTAuthTrimmed(text);
        if ([trimmed hasPrefix:@"{"] || [trimmed hasPrefix:@"["]) {
            NSData *data = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (json) LTAuthCollectCookieJSONObject(json, pairs, seen, NO);
        }
        if (!pairs.count) {
            // DevTools "Copy as fetch" / PowerShell snippets are JS objects,
            // not JSON, but still contain one quoted "cookie" header value.
            NSString *pattern = @"[\"']cookie[\"']\\s*[:=]\\s*[\"']([^\"']+)[\"']";
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                                   options:NSRegularExpressionCaseInsensitive
                                                                                     error:nil];
            NSArray *matches = [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)];
            for (NSTextCheckingResult *match in matches) {
                if (match.numberOfRanges < 2) continue;
                NSString *value = [text substringWithRange:[match rangeAtIndex:1]];
                LTAuthCollectCookieBlob(value, pairs, seen);
            }
        }
        if (!pairs.count) LTAuthCollectCookieBlob(text, pairs, seen);
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

- (BOOL)hasLoginInfo {
    return LTAuthCookieValueForName([self cookieHeader], @"LOGIN_INFO").length > 0;
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

- (void)addSidAuthorizationWithScheme:(NSString *)scheme
                                  sid:(NSString *)sid
                               origin:(NSString *)origin
                                   to:(NSMutableArray *)out {
    if (!sid.length) return;

    long long seconds = (long long)[[NSDate date] timeIntervalSince1970];
    // The web client hashes "<time> <SAPISID> <origin>" (SAPISID before the
    // origin). Getting this order wrong makes Google treat every request as
    // signed out, which is exactly what a "Sign in" card in the library means.
    NSString *payload = [NSString stringWithFormat:@"%lld %@ %@", seconds, sid, origin];

    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    NSData *data = [payload dataUsingEncoding:NSUTF8StringEncoding];
    CC_SHA1([data bytes], (CC_LONG)[data length], digest);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    [out addObject:[NSString stringWithFormat:@"%@ %lld_%@", scheme, seconds, hex]];
}

- (NSString *)authorizationHeaderForOrigin:(NSString *)origin {
    if (!origin.length) return nil;

    NSString *header = [self cookieHeader];
    NSString *sapisid = LTAuthCookieValueForName(header, @"SAPISID");
    NSString *sapisid1 = LTAuthCookieValueForName(header, @"__Secure-1PAPISID");
    NSString *sapisid3 = LTAuthCookieValueForName(header, @"__Secure-3PAPISID");
    // YouTube falls back to __Secure-3PAPISID when SAPISID is absent.
    if (!sapisid.length) sapisid = sapisid3;

    // yt-dlp watches for three different schemes; some endpoints (notably
    // music.youtube.com) only accept the secure 1P/3P variants. Send every
    // variant the cookie set can produce, space separated.
    NSMutableArray *authorizations = [NSMutableArray array];
    [self addSidAuthorizationWithScheme:@"SAPISIDHASH" sid:sapisid origin:origin to:authorizations];
    [self addSidAuthorizationWithScheme:@"SAPISID1PHASH" sid:sapisid1 origin:origin to:authorizations];
    [self addSidAuthorizationWithScheme:@"SAPISID3PHASH" sid:sapisid3 origin:origin to:authorizations];
    if (!authorizations.count) return nil;
    return [authorizations componentsJoinedByString:@" "];
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
