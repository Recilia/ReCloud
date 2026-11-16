#import "LTToast.h"

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
    [UIView animateWithDuration:1.4 delay:1.0 options:UIViewAnimationOptionCurveEaseIn
                     animations:^{ label.alpha = 0.0f; }
                     completion:^(BOOL finished) { [label removeFromSuperview]; }];
}

@end
