#import <Foundation/Foundation.h>

// Lightweight Google account credentials for authenticated InnerTube
// (YouTube Music) requests. There is no Google Sign-In SDK on legacy iOS,
// so the app uses the cookie-based SAPISIDHASH scheme that the YouTube
// Music web client itself uses:
//
//   Authorization: SAPISIDHASH <unix-time>_<sha1("<time> <origin> <SAPISID>")>
//
// The SAPISID cookie is captured either from an in-app UIWebView sign-in
// (UIWebView shares cookies with NSHTTPCookieStorage) or pasted manually
// from a desktop browser.

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

// Collects Google cookies from the shared cookie store (populated by a
// UIWebView sign-in) and stores them. Returns YES if an APISID cookie was
// found.
- (BOOL)adoptCookiesFromSharedStorage;

// "SAPISIDHASH <time>_<digest>" for the given origin, e.g.
// "https://music.youtube.com". Returns nil when signed out.
- (NSString *)authorizationHeaderForOrigin:(NSString *)origin;

- (void)signOut;

@end
