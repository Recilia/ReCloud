#import "LTTransitionSettings.h"

// Bumped key so the upgrade to 3.2 resets animations to their new OFF
// default; the pre-3.2 getter stored YES eagerly on first read, so the old
// key can't tell a user preference from an untouched install.
static NSString *const LTAnimationsEnabledKey = @"LTAnimationsEnabled.2";
static NSString *const LTTransitionSpeedKey = @"LTTransitionSpeed";

@implementation LTTransitionSettings

+ (BOOL)animationsEnabled {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:LTAnimationsEnabledKey];
    if (stored == nil) return NO;  // off by default
    return [stored boolValue];
}

+ (void)setAnimationsEnabled:(BOOL)enabled {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:LTAnimationsEnabledKey];
}

+ (CGFloat)speedMultiplier {
    id stored = [[NSUserDefaults standardUserDefaults] objectForKey:LTTransitionSpeedKey];
    if (!stored) return 1.0f;
    CGFloat value = [stored floatValue];
    if (value < 0.5f) value = 0.5f;
    if (value > 2.0f) value = 2.0f;
    return value;
}

+ (void)setSpeedMultiplier:(CGFloat)multiplier {
    if (multiplier < 0.5f) multiplier = 0.5f;
    if (multiplier > 2.0f) multiplier = 2.0f;
    [[NSUserDefaults standardUserDefaults] setFloat:multiplier forKey:LTTransitionSpeedKey];
}

+ (CGFloat)durationFor:(CGFloat)baseDuration {
    return baseDuration / [self speedMultiplier];
}

#pragma mark - Animation helpers

+ (void)animateWithDuration:(CGFloat)duration
                 animations:(void (^)(void))animations
                 completion:(void (^)(BOOL finished))completion {
    if (!animations) return;
    if (![self animationsEnabled]) {
        // Disabled: apply the final values directly, skipping the whole
        // UIView animation pipeline (no CA transaction, no render tree work).
        animations();
        if (completion) completion(YES);
        return;
    }
    [UIView animateWithDuration:[self durationFor:duration]
                          animations:animations
                          completion:completion];
}

+ (void)animateWithDuration:(CGFloat)duration animations:(void (^)(void))animations {
    [self animateWithDuration:duration animations:animations completion:nil];
}

@end
