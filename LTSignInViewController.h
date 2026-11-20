#import <UIKit/UIKit.h>

@interface LTSignInViewController : UIViewController

// Sign-in offers a classic Google web login and a cookie paste fallback.
// The web login is 64-bit only (Google's page crashes the legacy WebKit engine
// on old armv7 devices); cookie paste works everywhere and jumps straight to
// the paste field when pasteOnly is YES.
+ (BOOL)webSignInAvailable;
- (id)initWithPasteOnly:(BOOL)pasteOnly;

@end
