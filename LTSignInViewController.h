#import <UIKit/UIKit.h>

@interface LTSignInViewController : UIViewController

// Sign-in is paste-only: paste the SAPISID cookie from a desktop browser.
// (The in-app web login was removed — Google's login page crashes the legacy
// WebKit engine on old devices.)
- (id)initWithPasteOnly:(BOOL)pasteOnly;

@end
