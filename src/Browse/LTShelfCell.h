#import <UIKit/UIKit.h>
#import "LTModel.h"

// Horizontal strip cells shared by the Home and Search screens.
// LTHomeRecentsCell renders track-only tiles ("Recently Played");
// LTHomeShelfCell renders a mix of LTTrack and LTBrowseItem tiles
// (recommendation shelves, library, history).

extern const CGFloat kHomeTileMinWidth;
extern const CGFloat kHomeTileMaxWidth;

@interface LTHomeRecentsCell : UITableViewCell
@property (nonatomic, copy) void (^onTrackTapped)(LTTrack *track);
- (void)setTracks:(NSArray *)tracks;
+ (CGFloat)tileWidth;
+ (CGFloat)artworkHeight;
+ (CGFloat)contentHeight;
@end

@interface LTHomeShelfCell : UITableViewCell
@property (nonatomic, copy) void (^onTrackTapped)(LTTrack *track);
@property (nonatomic, copy) void (^onBrowseTapped)(LTBrowseItem *item);
- (void)setItems:(NSArray *)items;
@end

// Horizontal strip of rounded genre/mood chips used in the Search idle
// state. Tapping a chip searches for its title.
@interface LTChipStripCell : UITableViewCell
@property (nonatomic, copy) void (^onChipTapped)(NSInteger index, NSString *title);
- (void)setChips:(NSArray *)chips;
+ (CGFloat)contentHeight;
@end
