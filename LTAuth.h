#import <Foundation/Foundation.h>

// Lightweight Google account credentials for authenticated InnerTube
// (YouTube Music) requests. There is no Google Sign-In SDK on legacy iOS,
// so the app uses the cookie-based SAPISIDHASH scheme that the YouTube
// Music web client itself uses:
//
//   Authorization: SAPISIDHASH <unix-time>_<sha1("<time> <origin> <SAPISID>")>
//
// The SAPISID cookie is pasted manually from a desktop browser signed into
// YouTube Music (the in-app web login was removed; see LTSignInViewController).

extern NSString *const LTAuthDidChangeNotification;

@interface LTAuth : NSObject

+ (instancetype)sharedAuth;

@property (nonatomic, readonly, assign) BOOL signedIn;
@property (nonatomic, readonly, copy) NSString *accountName;

// The APISID value used for SAPISIDHASH (SAPISID, then __Secure-3PAPISID,
// then __Secure-1PAPISID).
@property (nonatomic, readonly, copy) NSString *sapisid;

// Full "Cookie:" header value built from the captured Google cookies.
@property (nonatomic, readonly, copy) NSString *cookieHeader;

// Builds credentials from a complete cookie header string (or a bare
// SAPISID token). Pass accountName (may be nil) if known.
- (void)setCredentialsWithCookieHeader:(NSString *)cookieHeader
                           accountName:(NSString *)accountName;

// The same normalisation setCredentialsWithCookieHeader: applies (a bare
// token becomes the SAPISID pair), without storing anything. Used to check a
// pasted cookie before it is allowed to replace a working sign-in.
- (NSString *)normalizedCookieHeaderFromInput:(NSString *)input;

// The whitelisted Google cookies already in the shared cookie store (e.g. left
// by another app or an older sign-in) as one "NAME=VALUE; …" header, without
// storing anything, so a candidate can be checked before it is saved. Returns
// nil when there are none.
- (NSString *)cookieHeaderFromSharedStorage;

// "SAPISIDHASH <time>_<digest>" for the given origin, e.g.
// "https://music.youtube.com". Returns nil when signed out.
- (NSString *)authorizationHeaderForOrigin:(NSString *)origin;

// The same header computed from an arbitrary cookie header instead of the
// stored one, so a candidate sign-in can be tested without touching it.
- (NSString *)authorizationHeaderForCookieHeader:(NSString *)cookieHeader
                                          origin:(NSString *)origin;

- (void)signOut;

@end
