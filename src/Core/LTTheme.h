#import <UIKit/UIKit.h>

// Central place for the colors the app needs to change between light and
// dark appearance, plus the user-selectable theme mode (Settings → Theme).
//
// A manual override stored in NSUserDefaults works on every iOS version;
// "System" follows the OS on iOS 13+ and is light on older devices. NEW
// INSTALLS DEFAULT TO DARK (YouTube-style black + red) until a mode is
// explicitly chosen. Changing the mode posts LTThemeModeDidChangeNotification
// so the app delegate can rebuild the UI with the new palette.
//
// The app ships against old SDKs (iOS 9.3 / 11.2), so it cannot use the iOS 13
// dynamic system colors: the matching plain color is returned per call.
typedef NS_ENUM(NSInteger, LTThemeMode) {
    LTThemeModeSystem = 0,
    LTThemeModeLight  = 1,
    LTThemeModeDark   = 2,
};

extern NSString * const LTThemeModeDidChangeNotification;

@interface LTTheme : NSObject

+ (LTThemeMode)mode;
+ (void)setMode:(LTThemeMode)mode;   // persists and posts the change notification
+ (NSString *)labelForMode:(LTThemeMode)mode;

// Resolves the stored mode: Dark/Light are fixed; System follows the OS on
// iOS 13+ and is light on older devices. Dark is the default when the user
// has never picked a mode.
+ (BOOL)isDark;

+ (UIColor *)background;         // page / table background
+ (UIColor *)groupedBackground;  // behind grouped (settings-style) content
+ (UIColor *)cellBackground;     // raised surface inside grouped content
+ (UIColor *)fill;               // subtle fills (buttons, chips)
+ (UIColor *)placeholder;        // artwork placeholders
+ (UIColor *)text;               // primary text
+ (UIColor *)secondaryText;      // captions, detail text
+ (UIColor *)separator;
+ (UIColor *)accent;             // YouTube red; buttons, active tab, highlights
+ (UIColor *)tabIcon;            // unselected tab bar icons

// Applies the active palette to a standard table cell: opaque background,
// primary/detail label colors. Call it right after dequeue/creation; rows may
// override individual label colors afterwards. Without this UIKit keeps the
// cell white (its default) while the labels go near-white in dark mode.
+ (void)styleCell:(UITableViewCell *)cell;

// Same for a table view: background plus separator tint.
+ (void)styleTableView:(UITableView *)tableView grouped:(BOOL)grouped;

@end
