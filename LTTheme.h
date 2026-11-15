#import <UIKit/UIKit.h>

// Central place for the few colors the app needs to change between light and
// dark appearance. The app ships against old SDKs (iOS 9.3 / 11.2), so it cannot
// use the iOS 13 dynamic system colors: dark mode is detected at runtime and the
// matching plain color is returned. On iOS 12 and older -isDark is always NO.
//
// A manual override stored in NSUserDefaults (Settings → Dark Mode) works on
// every iOS version; "System" follows the OS where it exists and means light
// on older devices. Changing the mode posts LTThemeModeDidChangeNotification
// so the app delegate can rebuild the UI with the new palette.
@interface LTTheme : NSObject

typedef NS_ENUM(NSInteger, LTAppearanceMode) {
    LTAppearanceModeSystem = 0,
    LTAppearanceModeLight  = 1,
    LTAppearanceModeDark   = 2,
};

extern NSString *const LTThemeModeDidChangeNotification;

+ (BOOL)isDark;
+ (NSInteger)appearanceMode;               // LTAppearanceMode
+ (void)setAppearanceMode:(NSInteger)mode;
+ (NSString *)labelForAppearanceMode:(NSInteger)mode;

+ (UIColor *)background;         // page / table background
+ (UIColor *)groupedBackground;  // behind grouped (settings-style) content
+ (UIColor *)cellBackground;     // raised surface inside grouped content
+ (UIColor *)fill;               // subtle fills (buttons, chips)
+ (UIColor *)placeholder;        // artwork placeholders
+ (UIColor *)text;               // primary text
+ (UIColor *)secondaryText;      // captions, detail text
+ (UIColor *)separator;
+ (UIColor *)accent;

@end
