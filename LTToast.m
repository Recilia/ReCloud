#import "LTToast.h"
#import "LTTransitionSettings.h"
#import <dispatch/dispatch.h>

@implementation LTToast

+ (void)showText:(NSString *)text inView:(UIView *)view {
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 220, 36)];
    label.center = CGPointMake(view.bounds.size.width / 2.0f, view.bounds.size.height - 80);
    label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75f];
    label.textColor = [UIColor whiteColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont systemFontOfSize:13];
    label.layer.cornerRadius = 6.0f;
    label.clipsToBounds = YES;
    label.text = text;
    [view addSubview:label];
    if (![LTTransitionSettings animationsEnabled]) {
        // No fade (Core Animation work on a 1s+ timer is the most expensive
        // part of a toast): hold it on screen, then remove it with GCD.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [label removeFromSuperview];
        });
        return;
    }
    [UIView animateWithDuration:1.4 delay:1.0 options:UIViewAnimationOptionCurveEaseIn
                     animations:^{ label.alpha = 0.0f; }
                     completion:^(BOOL finished) { [label removeFromSuperview]; }];
}

@end
