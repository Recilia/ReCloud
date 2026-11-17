#import "LTShelfCell.h"
#import "LTYouTubeClient.h"
#import "LTTheme.h"

#pragma mark - Horizontal-only strip scroll view

// The strip cells live inside the (vertical) table view, so the inner
// scroll view's pan recognizer must only begin for horizontal movement:
// once it begins it blocks the table's pan, which is what made a
// press-and-hold on a tile freeze vertical scrolling. Letting the inner
// pan fail for vertical drags hands the touch back to the table, whose pan
// then cancels the tile button's touch (canCancelContentTouches) and
// scrolls the page. A plain horizontal drag still scrolls the strip.
@interface LTStripScrollView : UIScrollView
@end

@implementation LTStripScrollView

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == self.panGestureRecognizer) {
        CGPoint velocity = [(UIPanGestureRecognizer *)gestureRecognizer velocityInView:self];
        if (fabs(velocity.y) > fabs(velocity.x)) return NO;
    }
    return [super gestureRecognizerShouldBegin:gestureRecognizer];
}

@end

#pragma mark - Recently played horizontal strip

@implementation LTHomeRecentsCell {
    UIScrollView *_scrollView;
    NSArray *_tracks;
}

const CGFloat kHomeTileMinWidth = 90.0f;
const CGFloat kHomeTileMaxWidth = 130.0f;
const CGFloat kHomeTileArtRatio = 104.0f / 116.0f;

+ (CGFloat)tileWidth {
    CGFloat width = [[NSUserDefaults standardUserDefaults] floatForKey:@"LTHomeTileSize"];
    if (width < kHomeTileMinWidth || width > kHomeTileMaxWidth) {
        width = kHomeTileMinWidth;
        [[NSUserDefaults standardUserDefaults] setFloat:width forKey:@"LTHomeTileSize"];
    }
    return width;
}

+ (CGFloat)artworkHeight {
    return [LTHomeRecentsCell tileWidth] * kHomeTileArtRatio;
}

+ (CGFloat)contentHeight {
    return [LTHomeRecentsCell artworkHeight] + 54.0f;
}

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _scrollView = [[LTStripScrollView alloc] initWithFrame:CGRectZero];
        _scrollView.showsHorizontalScrollIndicator = NO;
        _scrollView.showsVerticalScrollIndicator = NO;
        _scrollView.directionalLockEnabled = YES;
        _scrollView.bounces = NO;
        _scrollView.delaysContentTouches = NO;
        _scrollView.canCancelContentTouches = YES;
        if ([_scrollView respondsToSelector:@selector(setAlwaysBounceVertical:)]) {
            _scrollView.alwaysBounceVertical = NO;
        }
        _scrollView.backgroundColor = [LTTheme background];
        _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [self.contentView addSubview:_scrollView];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _scrollView.frame = CGRectMake(0, 0, self.contentView.bounds.size.width, self.contentView.bounds.size.height);
}

- (void)setTracks:(NSArray *)tracks {
    if (tracks == _tracks) return;  // same array object → nothing changed
    _tracks = tracks;
    _scrollView.backgroundColor = [LTTheme background];
    self.backgroundColor = [LTTheme background];
    self.contentView.backgroundColor = [LTTheme background];
    for (UIView *view in _scrollView.subviews) {
        [view removeFromSuperview];
    }
    CGFloat tileWidth = [LTHomeRecentsCell tileWidth];
    CGFloat artH = [LTHomeRecentsCell artworkHeight];
    CGFloat gap = 10.0f;
    CGFloat x = 10.0f;
    NSUInteger index = 0;
    for (LTTrack *track in tracks) {
        UIView *tile = [[UIView alloc] initWithFrame:CGRectMake(x, 6, tileWidth, artH + 42)];

        UIButton *imageButton = [UIButton buttonWithType:UIButtonTypeCustom];
        imageButton.frame = CGRectMake(0, 0, tileWidth, artH);
        imageButton.backgroundColor = [LTTheme placeholder];
        imageButton.layer.cornerRadius = 8.0f;
        imageButton.clipsToBounds = YES;
        imageButton.tag = (NSInteger)index;
        [imageButton addTarget:self action:@selector(tileTapped:) forControlEvents:UIControlEventTouchUpInside];
        [tile addSubview:imageButton];

        UIImageView *artwork = [[UIImageView alloc] initWithFrame:imageButton.bounds];
        artwork.contentMode = UIViewContentModeScaleAspectFill;
        artwork.clipsToBounds = YES;
        [imageButton addSubview:artwork];
        if (track.thumbnailURL.length) {
            NSString *artURL = [[LTYouTubeClient sharedClient] listThumbnailURL:track.thumbnailURL];
            __weak UIImageView *weakArtwork = artwork;
            [[LTYouTubeClient sharedClient] loadImageWithURL:artURL completion:^(UIImage *image) {
                if (image) weakArtwork.image = image;
            }];
        }

        UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(2, artH + 4, tileWidth - 4, 26)];
        titleLabel.font = [UIFont boldSystemFontOfSize:12];
        titleLabel.numberOfLines = 2;
        titleLabel.textColor = [LTTheme text];
        titleLabel.text = track.title;
        [tile addSubview:titleLabel];

        UILabel *artistLabel = [[UILabel alloc] initWithFrame:CGRectMake(2, artH + 30, tileWidth - 4, 12)];
        artistLabel.font = [UIFont systemFontOfSize:11];
        artistLabel.textColor = [LTTheme secondaryText];
        artistLabel.text = track.artist.length ? track.artist : @"Unknown Artist";
        [tile addSubview:artistLabel];

        [_scrollView addSubview:tile];
        x += tileWidth + gap;
        index += 1;
    }
    CGFloat contentWidth = MAX(x, self.contentView.bounds.size.width + 1);
    _scrollView.contentSize = CGSizeMake(contentWidth, [LTHomeRecentsCell contentHeight]);
}

- (void)tileTapped:(UIButton *)button {
    NSUInteger index = (NSUInteger)button.tag;
    if (index >= _tracks.count) return;
    if (self.onTrackTapped) self.onTrackTapped([_tracks objectAtIndex:index]);
}

@end

#pragma mark - Home shelf strip cell

// Horizontal strip that can hold a mix of LTTrack and LTBrowseItem tiles.

@implementation LTHomeShelfCell {
    UIScrollView *_scrollView;
    NSArray *_items;
}

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _scrollView = [[LTStripScrollView alloc] initWithFrame:CGRectZero];
        _scrollView.showsHorizontalScrollIndicator = NO;
        _scrollView.showsVerticalScrollIndicator = NO;
        _scrollView.directionalLockEnabled = YES;
        _scrollView.bounces = NO;
        _scrollView.delaysContentTouches = NO;
        _scrollView.canCancelContentTouches = YES;
        if ([_scrollView respondsToSelector:@selector(setAlwaysBounceVertical:)]) {
            _scrollView.alwaysBounceVertical = NO;
        }
        _scrollView.backgroundColor = [LTTheme background];
        _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [self.contentView addSubview:_scrollView];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _scrollView.frame = CGRectMake(0, 0, self.contentView.bounds.size.width, self.contentView.bounds.size.height);
}

- (void)setItems:(NSArray *)items {
    if (items == _items) return;  // same array object → nothing changed
    _items = items;
    _scrollView.backgroundColor = [LTTheme background];
    self.backgroundColor = [LTTheme background];
    self.contentView.backgroundColor = [LTTheme background];
    for (UIView *view in _scrollView.subviews) {
        [view removeFromSuperview];
    }
    CGFloat tileWidth = [LTHomeRecentsCell tileWidth];
    CGFloat artH = [LTHomeRecentsCell artworkHeight];
    CGFloat gap = 10.0f;
    CGFloat x = 10.0f;
    NSUInteger index = 0;
    for (id obj in items) {
        UIView *tile = [[UIView alloc] initWithFrame:CGRectMake(x, 6, tileWidth, artH + 42)];

        UIButton *imageButton = [UIButton buttonWithType:UIButtonTypeCustom];
        imageButton.frame = CGRectMake(0, 0, tileWidth, artH);
        imageButton.backgroundColor = [LTTheme placeholder];
        imageButton.layer.cornerRadius = 8.0f;
        imageButton.clipsToBounds = YES;
        imageButton.tag = (NSInteger)index;
        [imageButton addTarget:self action:@selector(tileTapped:) forControlEvents:UIControlEventTouchUpInside];
        [tile addSubview:imageButton];

        UIImageView *artwork = [[UIImageView alloc] initWithFrame:imageButton.bounds];
        artwork.contentMode = UIViewContentModeScaleAspectFill;
        artwork.clipsToBounds = YES;
        [imageButton addSubview:artwork];

        NSString *title = nil, *subtitle = nil, *thumbURL = nil;
        BOOL square = NO;
        if ([obj isKindOfClass:[LTTrack class]]) {
            LTTrack *track = obj;
            title = track.title;
            subtitle = track.artist.length ? track.artist : @"Unknown Artist";
            thumbURL = track.thumbnailURL;
        } else if ([obj isKindOfClass:[LTBrowseItem class]]) {
            LTBrowseItem *bi = obj;
            title = bi.title;
            subtitle = bi.subtitle.length ? bi.subtitle : [self kindLabel:bi.kind];
            thumbURL = bi.thumbnailURL;
            square = (bi.kind == LTBrowseKindArtist);
        }

        if (thumbURL.length) {
            NSString *artURL = thumbURL;
            if (!square) artURL = [[LTYouTubeClient sharedClient] listThumbnailURL:thumbURL];
            else artURL = [[LTYouTubeClient sharedClient] channelAvatarURL:thumbURL size:160];
            __weak UIImageView *weakArtwork = artwork;
            [[LTYouTubeClient sharedClient] loadImageWithURL:artURL completion:^(UIImage *image) {
                if (image) weakArtwork.image = image;
            }];
        }

        UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(2, artH + 4, tileWidth - 4, 26)];
        titleLabel.font = [UIFont boldSystemFontOfSize:12];
        titleLabel.numberOfLines = 2;
        titleLabel.textColor = [LTTheme text];
        titleLabel.text = title;
        [tile addSubview:titleLabel];

        UILabel *subtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(2, artH + 30, tileWidth - 4, 12)];
        subtitleLabel.font = [UIFont systemFontOfSize:11];
        subtitleLabel.textColor = [LTTheme secondaryText];
        subtitleLabel.text = subtitle;
        [tile addSubview:subtitleLabel];

        [_scrollView addSubview:tile];
        x += tileWidth + gap;
        index += 1;
    }
    CGFloat contentWidth = MAX(x, self.contentView.bounds.size.width + 1);
    _scrollView.contentSize = CGSizeMake(contentWidth, [LTHomeRecentsCell contentHeight]);
}

- (NSString *)kindLabel:(LTBrowseKind)kind {
    if (kind == LTBrowseKindAlbum) return @"Album";
    if (kind == LTBrowseKindArtist) return @"Artist";
    return @"Playlist";
}

- (void)tileTapped:(UIButton *)button {
    NSUInteger index = (NSUInteger)button.tag;
    if (index >= _items.count) return;
    id obj = [_items objectAtIndex:index];
    if ([obj isKindOfClass:[LTTrack class]]) {
        if (self.onTrackTapped) self.onTrackTapped(obj);
    } else if ([obj isKindOfClass:[LTBrowseItem class]]) {
        if (self.onBrowseTapped) self.onBrowseTapped(obj);
    }
}

@end

#pragma mark - Genre / mood chip strip

@implementation LTChipStripCell {
    UIScrollView *_scrollView;
    NSArray *_chips;
}

+ (CGFloat)contentHeight {
    return 48.0f;
}

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.backgroundColor = [LTTheme background];
        _scrollView = [[LTStripScrollView alloc] initWithFrame:CGRectZero];
        _scrollView.showsHorizontalScrollIndicator = NO;
        _scrollView.showsVerticalScrollIndicator = NO;
        _scrollView.alwaysBounceHorizontal = YES;
        _scrollView.delaysContentTouches = NO;
        _scrollView.canCancelContentTouches = YES;
        _scrollView.backgroundColor = [LTTheme background];
        _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [self.contentView addSubview:_scrollView];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _scrollView.frame = self.contentView.bounds;
}

- (void)setChips:(NSArray *)chips {
    if (chips == _chips) return;  // same array object → nothing changed
    _chips = chips;
    for (UIView *view in _scrollView.subviews) {
        [view removeFromSuperview];
    }
    CGFloat x = 10.0f;
    CGFloat height = 30.0f;
    NSUInteger index = 0;
    for (NSString *chip in chips) {
        CGFloat width = [chip sizeWithFont:[UIFont boldSystemFontOfSize:13]].width + 28.0f;
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.frame = CGRectMake(x, 9.0f, width, height);
        button.layer.cornerRadius = height / 2.0f;
        button.clipsToBounds = YES;
        button.backgroundColor = [LTTheme placeholder];
        button.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        [button setTitleColor:[LTTheme text] forState:UIControlStateNormal];
        [button setTitle:chip forState:UIControlStateNormal];
        button.tag = (NSInteger)index;
        [button addTarget:self action:@selector(chipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_scrollView addSubview:button];
        x += width + 8.0f;
        index += 1;
    }
    _scrollView.contentSize = CGSizeMake(MAX(x, self.contentView.bounds.size.width + 1), [LTChipStripCell contentHeight]);
}

- (void)chipTapped:(UIButton *)button {
    NSUInteger index = (NSUInteger)button.tag;
    if (index >= _chips.count) return;
    if (self.onChipTapped) self.onChipTapped((NSInteger)index, [_chips objectAtIndex:index]);
}

@end
