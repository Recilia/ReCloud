#import <UIKit/UIKit.h>

@interface LTSignInViewController : UIViewController

// YES when opened from the paste-only flow (no web login attempt).
- (id)initWithPasteOnly:(BOOL)pasteOnly;

@end
