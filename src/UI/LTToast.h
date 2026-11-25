#import <UIKit/UIKit.h>

// Small transient toast message shown near the bottom of a view.
@interface LTToast : NSObject
+ (void)showText:(NSString *)text inView:(UIView *)view;
@end
