#import "LTTableSongMenu.h"
#import "LTSongMenu.h"
#import <objc/runtime.h>

static char kLTTableSongMenuKey;      // LTSongMenu
static char kLTTableSongMenuVCKey;    // presenting view controller
static char kLTTableSongMenuBlockKey; // trackAtIndexPath block
static char kLTTableSongMenuPressKey; // gesture recognizer

@implementation UITableView (LTSongMenu)

- (void)lt_addSongMenuWithViewController:(UIViewController *)viewController
                       trackAtIndexPath:(LTTrack *(^)(NSIndexPath *indexPath))trackAtIndexPath {
    if (!viewController || !trackAtIndexPath) return;
    self.delaysContentTouches = NO;

    LTSongMenu *menu = [[LTSongMenu alloc] init];
    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc]
                                           initWithTarget:self
                                           action:@selector(lt_songMenuPressed:)];
    press.minimumPressDuration = 0.5;
    press.allowableMovement = 10.0f;
    press.cancelsTouchesInView = NO;
    objc_setAssociatedObject(self, &kLTTableSongMenuKey, menu, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &kLTTableSongMenuVCKey, viewController, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(self, &kLTTableSongMenuBlockKey, trackAtIndexPath, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(self, &kLTTableSongMenuPressKey, press, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [self addGestureRecognizer:press];
}

- (void)lt_songMenuPressed:(UILongPressGestureRecognizer *)press {
    if (press.state != UIGestureRecognizerStateBegan) return;
    NSIndexPath *indexPath = [self indexPathForRowAtPoint:[press locationInView:self]];
    if (!indexPath) return;
    LTTrack *(^trackAtIndexPath)(NSIndexPath *) = objc_getAssociatedObject(self, &kLTTableSongMenuBlockKey);
    UIViewController *viewController = objc_getAssociatedObject(self, &kLTTableSongMenuVCKey);
    LTSongMenu *menu = objc_getAssociatedObject(self, &kLTTableSongMenuKey);
    if (!trackAtIndexPath || !viewController || !menu) return;
    LTTrack *track = trackAtIndexPath(indexPath);
    if (!track) return;
    [menu presentForTrack:track fromViewController:viewController];
}

@end
