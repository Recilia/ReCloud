#import <Foundation/Foundation.h>

// Lightweight Google account credentials for authenticated InnerTube
// (YouTube Music) requests. There is no Google Sign-In SDK on legacy iOS,
// so the app uses the cookie-based SAPISIDHASH scheme that the YouTube
// Music web client itself uses:
//
//   Authorization: SAPISIDHASH <unix-time>_<sha1("<time> <SAPISID> <origin>")>
//
// The SAPISID cookie is pasted manually from a desktop browser signed into
// YouTube Music (the in-app web login was removed; see LTSignInViewController).

extern NSString *const LTAuthDidChangeNotification;

@interface LTAuth : NSObject

+ (instancetype)sharedAuth;

@property (nonatomic, readonly, assign) BOOL signedIn;
@property (nonatomic, readonly, copy) NSString *accountName;

// The APISID value used for SAPISIDHASH (__Secure-3PAPISID, then SAPISID,
// then __Secure-1PAPISID).
@property (nonatomic, readonly, copy) NSString *sapisid;

// Full "Cookie:" header value built from the captured Google cookies.
@property (nonatomic, readonly, copy) NSString *cookieHeader;

// YES when the stored cookie set includes LOGIN_INFO, which YouTube requires
// alongside SAPISID to treat a request as signed in. A paste containing only
// SAPISID can produce a valid hash but still be served as a guest.
@property (nonatomic, readonly, assign) BOOL hasLoginInfo;

// Builds credentials from a complete cookie header string (or a bare
// SAPISID token). Pass accountName (may be nil) if known.
- (void)setCredentialsWithCookieHeader:(NSString *)cookieHeader
                           accountName:(NSString *)accountName;

// Stores the display name discovered after the cookie has been validated.
// Unlike setCredentials..., this does not post LTAuthDidChangeNotification,
// so signing in does not trigger a second library fetch.
- (void)updateAccountName:(NSString *)accountName;

// Collects Google cookies already present in the shared cookie store (e.g.
// left by another app or an older sign-in) and stores them. Returns YES if
// any whitelisted cookie was found.
- (BOOL)adoptCookiesFromSharedStorage;

// "SAPISIDHASH <time>_<digest>" for the given origin, e.g.
// "https://music.youtube.com". Returns nil when signed out.
- (NSString *)authorizationHeaderForOrigin:(NSString *)origin;

- (void)signOut;

@end
