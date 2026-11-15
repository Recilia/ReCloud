#import "LTHomeViewController.h"
#import "LTPlaylistStore.h"
#import "LTPlayerController.h"
#import "LTTabBarController.h"
#import "LTLocalPlaylistDetailViewController.h"
#import "LTStatsViewController.h"
#import "LTTrackListViewController.h"
#import "LTAuth.h"
#import "LTMediaCell.h"
#import "LTYouTubeClient.h"
#import "LTModel.h"
#import "LTTheme.h"
#import "LTLog.h"
#import <QuartzCore/QuartzCore.h>

#pragma mark - Recently played horizontal strip

@interface LTHomeRecentsCell : UITableViewCell
@property (nonatomic, copy) void (^onTrackTapped)(LTTrack *track);
- (void)setTracks:(NSArray *)tracks;
@end

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
        _scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
        _scrollView.showsHorizontalScrollIndicator = NO;
        _scrollView.showsVerticalScrollIndicator = NO;
        _scrollView.directionalLockEnabled = YES;
        _scrollView.bounces = NO;
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
            NSString *artURL = [[LTYouTubeClient sharedClient] highResThumbnailURL:track.thumbnailURL];
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
@interface LTHomeShelfCell : UITableViewCell
@property (nonatomic, copy) void (^onTrackTapped)(LTTrack *track);
@property (nonatomic, copy) void (^onBrowseTapped)(LTBrowseItem *item);
- (void)setItems:(NSArray *)items;
@end

@implementation LTHomeShelfCell {
    UIScrollView *_scrollView;
    NSArray *_items;
}

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _scrollView = [[UIScrollView alloc] initWithFrame:CGRectZero];
        _scrollView.showsHorizontalScrollIndicator = NO;
        _scrollView.showsVerticalScrollIndicator = NO;
        _scrollView.directionalLockEnabled = YES;
        _scrollView.bounces = NO;
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
            if (!square) artURL = [[LTYouTubeClient sharedClient] highResThumbnailURL:thumbURL];
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

#pragma mark - Home

@interface LTHomeViewController ()
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray *recentTracks;
@property (nonatomic, strong) NSArray *playlists;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UILabel *bannerTitleLabel;
@property (nonatomic, strong) UILabel *bannerSubtitleLabel;
// Signed-in account content.
@property (nonatomic, strong) NSArray *homeShelves;    // @{"title",@"items"}
@property (nonatomic, strong) NSArray *libraryItems;   // LTBrowseItem
@property (nonatomic, strong) NSArray *historyTracks;  // LTTrack
@property (nonatomic, strong) NSArray *sections;       // section layout
@property (nonatomic, assign) BOOL accountLoaded;
@property (nonatomic, assign) BOOL accountLoading;
@property (nonatomic, strong) UIActivityIndicatorView *accountSpinner;
@end

@implementation LTHomeViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    if ([self respondsToSelector:@selector(setEdgesForExtendedLayout:)]) {
        self.edgesForExtendedLayout = UIRectEdgeNone;
    }
    self.title = @"Home";
    self.view.backgroundColor = [LTTheme background];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Stats"
                                                                             style:UIBarButtonItemStyleBordered
                                                                            target:self
                                                                            action:@selector(statsTapped:)];

    CGRect bounds = self.view.bounds;
    self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, bounds.size.width, bounds.size.height)
                                                  style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.backgroundColor = [LTTheme background];
    self.tableView.tableHeaderView = [self buildBanner];
    [self.view addSubview:self.tableView];

    self.emptyLabel = [[UILabel alloc] initWithFrame:CGRectMake(24, 190, bounds.size.width - 48, 60)];
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.font = [UIFont systemFontOfSize:15];
    self.emptyLabel.textColor = [LTTheme secondaryText];
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.hidden = YES;
    [self.view addSubview:self.emptyLabel];

    self.accountSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:
                           UIActivityIndicatorViewStyleGray];
    self.accountSpinner.hidesWhenStopped = YES;
    self.accountSpinner.center = CGPointMake(bounds.size.width / 2.0f, 300.0f);
    self.accountSpinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                                           UIViewAutoresizingFlexibleRightMargin;
    [self.view addSubview:self.accountSpinner];
}

- (UIView *)buildBanner {
    CGFloat width = self.view.bounds.size.width;
    UIView *banner = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, 92)];

    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.frame = banner.bounds;
    gradient.colors = @[
        (id)[UIColor colorWithRed:0.06f green:0.22f blue:0.46f alpha:1.0f].CGColor,
        (id)[UIColor colorWithRed:0.0f green:0.42f blue:0.85f alpha:1.0f].CGColor,
    ];
    [banner.layer insertSublayer:gradient atIndex:0];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 20, width - 32, 30)];
    titleLabel.text = @"Welcome back.";
    titleLabel.font = [UIFont boldSystemFontOfSize:24];
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.backgroundColor = [UIColor clearColor];
    self.bannerTitleLabel = titleLabel;
    [banner addSubview:titleLabel];

    UILabel *subtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 54, width - 32, 16)];
    subtitleLabel.text = @"";
    subtitleLabel.font = [UIFont systemFontOfSize:13];
    subtitleLabel.textColor = [UIColor colorWithWhite:1.0f alpha:0.75f];
    subtitleLabel.backgroundColor = [UIColor clearColor];
    self.bannerSubtitleLabel = subtitleLabel;
    [banner addSubview:subtitleLabel];

    [self updateBannerText];
    return banner;
}

- (void)updateBannerText {
    NSString *subtitle;
    if ([[LTAuth sharedAuth] signedIn]) {
        NSString *name = [[LTAuth sharedAuth] accountName];
        if (name.length) {
            subtitle = [NSString stringWithFormat:@"Signed in as %@.", name];
        } else {
            subtitle = @"Signed in — recommendations below.";
        }
    } else {
        NSInteger count = [[LTPlaylistStore sharedStore] listenedSongsCount];
        subtitle = [NSString stringWithFormat:@"You've listened to %d song%@.",
                    (int)count, count == 1 ? @"" : @"s"];
    }
    self.bannerSubtitleLabel.text = subtitle;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(storeDidChange:)
                                                 name:LTPlaylistsDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(storeDidChange:)
                                                 name:LTRecentsDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(authDidChange:)
                                                 name:LTAuthDidChangeNotification
                                               object:nil];
    [self reloadData];
    [self loadAccountContentIfNeeded];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    self.view.backgroundColor = [LTTheme background];
    self.tableView.backgroundColor = [LTTheme background];
    [self.tableView reloadData];
}

#pragma mark - Account content

- (void)authDidChange:(NSNotification *)notification {
    self.homeShelves = nil;
    self.libraryItems = nil;
    self.historyTracks = nil;
    self.accountLoaded = NO;
    self.accountLoading = NO;
    [self updateBannerText];
    [self reloadData];
    [self loadAccountContentIfNeeded];
}

- (void)loadAccountContentIfNeeded {
    if (![[LTAuth sharedAuth] signedIn]) return;
    if (self.accountLoaded || self.accountLoading) return;
    self.accountLoading = YES;
    [self.accountSpinner startAnimating];

    LTYouTubeClient *client = [LTYouTubeClient sharedClient];
    __weak LTHomeViewController *weakSelf = self;
    // All three requests complete on the main queue, so a plain counter
    // is enough to detect when the batch is done.
    __block NSInteger remaining = 3;

    void (^oneFinished)(void) = ^{
        remaining -= 1;
        if (remaining > 0) return;
        LTHomeViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.accountLoading = NO;
        strongSelf.accountLoaded = YES;
        [strongSelf.accountSpinner stopAnimating];
        [strongSelf reloadData];
    };

    [client fetchHomeRecommendationsWithCompletion:^(NSArray *shelves, NSError *error) {
        if (error) LTLog(@"HOME home shelves error %@", error);
        if (weakSelf) weakSelf.homeShelves = shelves;
        oneFinished();
    }];
    [client fetchLibraryPlaylistsWithCompletion:^(NSArray *items, NSError *error) {
        if (error) LTLog(@"HOME library error %@", error);
        if (weakSelf) weakSelf.libraryItems = items;
        oneFinished();
    }];
    [client fetchAccountHistoryWithCompletion:^(NSArray *tracks, NSError *error) {
        if (error) LTLog(@"HOME history error %@", error);
        if (weakSelf) weakSelf.historyTracks = tracks;
        oneFinished();
    }];
}

#pragma mark - Sections

- (void)rebuildSections {
    NSMutableArray *layout = [NSMutableArray array];
    BOOL signedIn = [[LTAuth sharedAuth] signedIn];
    if (signedIn && self.homeShelves.count) {
        for (NSUInteger i = 0; i < self.homeShelves.count; i++) {
            [layout addObject:@{ @"kind": @"shelf", @"index": @(i) }];
        }
    }
    if (signedIn && self.libraryItems.count) [layout addObject:@{ @"kind": @"library" }];
    if (signedIn && self.historyTracks.count) [layout addObject:@{ @"kind": @"history" }];
    if (self.recentTracks.count) [layout addObject:@{ @"kind": @"recents" }];
    if (self.playlists.count) [layout addObject:@{ @"kind": @"playlists" }];
    self.sections = layout;
}

- (NSInteger)sectionIndexForKind:(NSString *)kind {
    for (NSUInteger i = 0; i < self.sections.count; i++) {
        if ([[self.sections objectAtIndex:i][@"kind"] isEqualToString:kind]) {
            return (NSInteger)i;
        }
    }
    return -1;
}

- (void)reloadData {
    self.recentTracks = [[LTPlaylistStore sharedStore] recentTracks];
    self.playlists = [[LTPlaylistStore sharedStore] playlists];
    [self updateBannerText];
    [self rebuildSections];
    [self.tableView reloadData];
    if (self.sections.count == 0) {
        if ([[LTAuth sharedAuth] signedIn]) {
            self.emptyLabel.text = @"Loading your music…";
        } else {
            self.emptyLabel.text = @"Nothing here yet.\nPlay a song and create playlists to see them.";
        }
        self.emptyLabel.hidden = NO;
    } else {
        self.emptyLabel.hidden = YES;
    }
}

- (void)storeDidChange:(NSNotification *)notification {
    [self reloadData];
}

- (void)statsTapped:(id)sender {
    LTStatsViewController *stats = [[LTStatsViewController alloc] init];
    [self.navigationController pushViewController:stats animated:YES];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (NSInteger)self.sections.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sections.count) return @"";
    NSString *kind = [self.sections objectAtIndex:(NSUInteger)section][@"kind"];
    if ([kind isEqualToString:@"shelf"]) {
        NSInteger idx = [[self.sections objectAtIndex:(NSUInteger)section][@"index"] integerValue];
        NSDictionary *shelf = self.homeShelves.count > (NSUInteger)idx ?
            [self.homeShelves objectAtIndex:(NSUInteger)idx] : nil;
        return [shelf objectForKey:@"title"] ?: @"";
    }
    if ([kind isEqualToString:@"library"]) return @"Your Library";
    if ([kind isEqualToString:@"history"]) return @"History";
    if ([kind isEqualToString:@"recents"]) return @"Recently Played";
    if ([kind isEqualToString:@"playlists"]) return @"Your Playlists";
    return @"";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section < 0 || section >= (NSInteger)self.sections.count) return 0;
    NSString *kind = [self.sections objectAtIndex:(NSUInteger)section][@"kind"];
    if ([kind isEqualToString:@"playlists"]) return (NSInteger)self.playlists.count;
    return 1;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *kind = [self.sections objectAtIndex:(NSUInteger)indexPath.section][@"kind"];

    if ([kind isEqualToString:@"playlists"]) {
        static NSString *CellId = @"LTHomeCell";
        LTMediaCell *cell = [tableView dequeueReusableCellWithIdentifier:CellId];
        if (!cell) {
            cell = [[LTMediaCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:CellId];
            cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
            cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
            cell.detailTextLabel.textColor = [LTTheme secondaryText];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        LTLocalPlaylist *playlist = [self.playlists objectAtIndex:(NSUInteger)indexPath.row];
        cell.textLabel.text = playlist.name;
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%d tracks", (int)playlist.tracks.count];
        cell.accessoryView = nil;
        cell.imageView.image = nil;
        if (playlist.coverPath.length) {
            cell.imageView.image = [UIImage imageWithContentsOfFile:playlist.coverPath];
        } else if (playlist.tracks.count) {
            LTTrack *first = [playlist.tracks objectAtIndex:0];
            if (first.thumbnailURL.length) {
                NSString *artURL = [[LTYouTubeClient sharedClient] highResThumbnailURL:first.thumbnailURL];
                __weak UITableViewCell *weakCell = cell;
                [[LTYouTubeClient sharedClient] loadImageWithURL:artURL completion:^(UIImage *image) {
                    if (image) weakCell.imageView.image = image;
                }];
            }
        }
        return cell;
    }

    // All other sections are horizontal strip cells.
    static NSString *StripCellId = @"LTHomeShelfCell";
    LTHomeShelfCell *cell = [tableView dequeueReusableCellWithIdentifier:StripCellId];
    if (!cell) {
        cell = [[LTHomeShelfCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:StripCellId];
    }
    __weak LTHomeViewController *weakSelf = self;

    cell.onTrackTapped = ^(LTTrack *track) {
        LTHomeViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        [LTPlayerController sharedController].queueSourceName = @"Home";
        [[LTPlayerController sharedController] playQueue:@[track] atIndex:0];
        [(LTTabBarController *)strongSelf.tabBarController showNowPlaying];
    };

    cell.onBrowseTapped = ^(LTBrowseItem *item) {
        LTHomeViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        LTTrackListViewController *detail =
            [[LTTrackListViewController alloc] initWithBrowseId:item.browseId
                                                           kind:item.kind
                                                          title:item.title];
        [strongSelf.navigationController pushViewController:detail animated:YES];
    };

    if ([kind isEqualToString:@"shelf"]) {
        NSInteger idx = [[self.sections objectAtIndex:(NSUInteger)indexPath.section][@"index"] integerValue];
        NSArray *items = self.homeShelves.count > (NSUInteger)idx ?
            [[self.homeShelves objectAtIndex:(NSUInteger)idx] objectForKey:@"items"] : nil;
        [cell setItems:items ?: @[]];
    } else if ([kind isEqualToString:@"library"]) {
        [cell setItems:self.libraryItems];
    } else if ([kind isEqualToString:@"history"]) {
        [cell setItems:self.historyTracks];
    } else if ([kind isEqualToString:@"recents"]) {
        [cell setItems:self.recentTracks];
    }
    return cell;
}

#pragma mark - Editing (swipe to delete playlists)

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section >= (NSInteger)self.sections.count) return NO;
    NSString *kind = [self.sections objectAtIndex:(NSUInteger)indexPath.section][@"kind"];
    return [kind isEqualToString:@"playlists"] && self.playlists.count > 0;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    if (indexPath.section >= (NSInteger)self.sections.count) return;
    NSString *kind = [self.sections objectAtIndex:(NSUInteger)indexPath.section][@"kind"];
    if (![kind isEqualToString:@"playlists"]) return;
    LTLocalPlaylist *playlist = [self.playlists objectAtIndex:(NSUInteger)indexPath.row];
    [[LTPlaylistStore sharedStore] deletePlaylist:playlist];
    [self reloadData];
}

#pragma mark - UITableViewDelegate

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section < (NSInteger)self.sections.count) {
        NSString *kind = [self.sections objectAtIndex:(NSUInteger)indexPath.section][@"kind"];
        if (![kind isEqualToString:@"playlists"]) return [LTHomeRecentsCell contentHeight];
    }
    return 64.0f;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section >= (NSInteger)self.sections.count) return;
    NSString *kind = [self.sections objectAtIndex:(NSUInteger)indexPath.section][@"kind"];
    if (![kind isEqualToString:@"playlists"]) return;
    LTLocalPlaylist *playlist = [self.playlists objectAtIndex:(NSUInteger)indexPath.row];
    LTLocalPlaylistDetailViewController *detail = [[LTLocalPlaylistDetailViewController alloc] initWithPlaylist:playlist];
    [self.navigationController pushViewController:detail animated:YES];
}

@end
