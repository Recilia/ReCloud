#import "LTTheme.h"

NSString * const LTThemeModeDidChangeNotification = @"LTThemeModeDidChangeNotification";

@implementation LTTheme

// UIUserInterfaceStyleDark. The enum is not in the SDKs this app compiles with,
// so the value is spelled out and -userInterfaceStyle is called reflectively.
static const NSInteger LTUserInterfaceStyleDark = 2;

static NSString * const kLTThemeMode = @"LTThemeMode";

+ (LTThemeMode)mode {
    NSNumber *saved = [[NSUserDefaults standardUserDefaults] objectForKey:kLTThemeMode];
    if (!saved) return LTThemeModeDark; // black + red dark is the default
    NSInteger mode = [saved integerValue];
    if (mode < LTThemeModeSystem || mode > LTThemeModeDark) return LTThemeModeDark;
    return (LTThemeMode)mode;
}

+ (void)setMode:(LTThemeMode)mode {
    if (mode < LTThemeModeSystem) mode = LTThemeModeSystem;
    if (mode > LTThemeModeDark) mode = LTThemeModeDark;
    if (mode == [self mode]) return;
    [[NSUserDefaults standardUserDefaults] setObject:@(mode) forKey:kLTThemeMode];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:LTThemeModeDidChangeNotification object:nil];
}

+ (NSString *)labelForMode:(LTThemeMode)mode {
    switch (mode) {
        case LTThemeModeLight: return @"Light";
        case LTThemeModeDark:  return @"Dark";
        default:               return @"System";
    }
}

+ (BOOL)isDark {
    NSInteger mode = [self mode];
    if (mode == LTThemeModeDark) return YES;
    if (mode == LTThemeModeLight) return NO;
    // System: follow the OS on iOS 13+; light on older devices.
    UITraitCollection *traits = nil;
    UIWindow *window = [[UIApplication sharedApplication] keyWindow];
    if (!window) {
        NSArray *windows = [[UIApplication sharedApplication] windows];
        if (windows.count) window = [windows objectAtIndex:0];
    }
    if ([window respondsToSelector:@selector(traitCollection)]) {
        traits = window.traitCollection;
    }
    if (!traits && [window.rootViewController respondsToSelector:@selector(traitCollection)]) {
        traits = window.rootViewController.traitCollection;
    }
    if (!traits) return NO;

    SEL selector = NSSelectorFromString(@"userInterfaceStyle");
    if (![traits respondsToSelector:selector]) return NO;
    typedef NSInteger (*LTUserInterfaceStyleFunction)(id, SEL);
    LTUserInterfaceStyleFunction function = (LTUserInterfaceStyleFunction)[traits methodForSelector:selector];
    if (!function) return NO;
    return function(traits, selector) == LTUserInterfaceStyleDark;
}

// Dark: YouTube-style near-black surfaces. Light: clean white surfaces.
// Both share the same red accent (slightly deeper on white for contrast).
+ (UIColor *)background {
    return [self isDark] ? [UIColor colorWithRed:0.059f green:0.059f blue:0.059f alpha:1.0f]   // #0F0F0F
                         : [UIColor whiteColor];
}

+ (UIColor *)groupedBackground {
    return [self background];
}

+ (UIColor *)cellBackground {
    return [self isDark] ? [UIColor colorWithRed:0.11f green:0.11f blue:0.11f alpha:1.0f]      // #1C1C1C
                         : [UIColor whiteColor];
}

+ (UIColor *)fill {
    return [self isDark] ? [UIColor colorWithRed:0.15f green:0.15f blue:0.15f alpha:1.0f]      // #262626
                         : [UIColor colorWithWhite:0.95f alpha:1.0f];
}

+ (UIColor *)placeholder {
    return [self isDark] ? [UIColor colorWithRed:0.17f green:0.17f blue:0.17f alpha:1.0f]      // #2B2B2B
                         : [UIColor colorWithWhite:0.92f alpha:1.0f];
}

+ (UIColor *)text {
    return [self isDark] ? [UIColor colorWithRed:0.945f green:0.945f blue:0.945f alpha:1.0f]   // #F1F1F1
                         : [UIColor colorWithRed:0.075f green:0.075f blue:0.075f alpha:1.0f];  // #131313
}

+ (UIColor *)secondaryText {
    return [self isDark] ? [UIColor colorWithWhite:0.92f alpha:0.6f]
                         : [UIColor colorWithWhite:0.24f alpha:0.6f];
}

+ (UIColor *)separator {
    return [self isDark] ? [UIColor colorWithWhite:1.0f alpha:0.16f]
                         : [UIColor colorWithWhite:0.24f alpha:0.29f];
}

+ (UIColor *)accent {
    return [self isDark] ? [UIColor colorWithRed:1.0f green:0.20f blue:0.20f alpha:1.0f]       // #FF3333
                         : [UIColor colorWithRed:0.80f green:0.0f blue:0.0f alpha:1.0f];       // #CC0000
}

+ (UIColor *)tabIcon {
    return [self isDark] ? [UIColor colorWithWhite:0.85f alpha:1.0f]
                         : [UIColor colorWithWhite:0.35f alpha:1.0f];
}

+ (void)styleCell:(UITableViewCell *)cell {
    if (!cell) return;
    cell.backgroundColor = [self cellBackground];
    cell.textLabel.textColor = [self text];
    cell.detailTextLabel.textColor = [self secondaryText];
}

+ (void)styleTableView:(UITableView *)tableView grouped:(BOOL)grouped {
    if (!tableView) return;
    tableView.backgroundColor = grouped ? [self groupedBackground] : [self background];
    tableView.separatorColor = [self separator];
}

@end
