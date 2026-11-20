#import <UIKit/UIKit.h>

// Google's own sign-in page, hosted in an in-app browser. Offered on every
// version of the app: WKWebView wherever its cookies can be read back
// (iOS 11+), UIWebView everywhere else (which shares NSHTTPCookieStorage with
// the app, so the cookies need no copying).
@interface LTSignInViewController : UIViewController

// NO on 32-bit devices, where Google's page crashes the legacy WebKit engine
// natively. Those devices never load it: the screen explains why and points at
// Cookies Sign-In instead.
+ (BOOL)webSignInSupported;

@end
