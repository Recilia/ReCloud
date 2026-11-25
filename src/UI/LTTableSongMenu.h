#import <UIKit/UIKit.h>
#import "LTModel.h"

// Hold-to-open song menu support for song lists. The recognizer never
// cancels the touches it sees (cancelsTouchesInView = NO) and the table
// forwards touches immediately (delaysContentTouches = NO), so a vertical
// drag still scrolls the list while a press-and-hold opens the song menu.
// Tap-to-play and accessory buttons are unaffected.
@interface UITableView (LTSongMenu)

- (void)lt_addSongMenuWithViewController:(UIViewController *)viewController
                       trackAtIndexPath:(LTTrack *(^)(NSIndexPath *indexPath))trackAtIndexPath;

@end
