#import <UIKit/UIKit.h>

// Central animation switch. Animations are OFF by default: the app targets
// legacy devices (iPhone 4S, 512 MB) where every Core Animation commit and
// fade costs real memory bandwidth, so UI changes apply instantly unless the
// user turns animations on in Settings.
//
// Call sites should use +animateWithDuration:animations:(completion:) instead
// of [UIView animateWithDuration:...] directly — when animations are disabled
// it runs the changes block immediately (no animation machinery, no CA
// transaction) instead of committing a 0-duration animation.
@interface LTTransitionSettings : NSObject
+ (BOOL)animationsEnabled;
+ (void)setAnimationsEnabled:(BOOL)enabled;
+ (CGFloat)speedMultiplier;
+ (void)setSpeedMultiplier:(CGFloat)multiplier;
+ (CGFloat)durationFor:(CGFloat)baseDuration;

// Replacements for [UIView animateWithDuration:...]:
+ (void)animateWithDuration:(CGFloat)duration
                 animations:(void (^)(void))animations
                 completion:(void (^)(BOOL finished))completion;
+ (void)animateWithDuration:(CGFloat)duration animations:(void (^)(void))animations;
@end
