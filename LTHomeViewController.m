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
#import "LTShelfCell.h"
#import "LTPersonalShelves.h"
#import "LTToast.h"
#import "LTLucideIcons.h"

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
@property (nonatomic, strong) NSArray *radioSeeds;     // LTTrack seeds the home shelves were built from
@property (nonatomic, assign) BOOL radioLoading;
@property (nonatomic, strong) UIBarButtonItem *refreshItem;
@property (nonatomic, assign) BOOL refreshing;
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
    UIBarButtonItem *refresh = [[UIBarButtonItem alloc] initWithImage:[LTLucideIcons iconNamed:@"refresh-cw" size:20.0f color:[LTTheme text]]
                                                               style:UIBarButtonItemStyleBordered
                                                              target:self
                                                              action:@selector(refreshTapped:)];
    self.navigationItem.leftBarButtonItem = refresh;
    self.refreshItem = refresh;

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
    if ([LTTheme isDark]) {
        gradient.colors = @[
            (id)[UIColor colorWithRed:0.16f green:0.03f blue:0.03f alpha:1.0f].CGColor,
            (id)[UIColor colorWithRed:0.42f green:0.08f blue:0.08f alpha:1.0f].CGColor,
        ];
    } else {
        gradient.colors = @[
            (id)[UIColor colorWithWhite:0.97f alpha:1.0f].CGColor,
            (id)[UIColor colorWithWhite:0.90f alpha:1.0f].CGColor,
        ];
    }
    [banner.layer insertSublayer:gradient atIndex:0];

    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 20, width - 32, 30)];
    titleLabel.text = @"Welcome back.";
    titleLabel.font = [UIFont boldSystemFontOfSize:24];
    titleLabel.textColor = [LTTheme isDark] ? [UIColor whiteColor] : [LTTheme text];
    titleLabel.backgroundColor = [UIColor clearColor];
    self.bannerTitleLabel = titleLabel;
    [banner addSubview:titleLabel];

    UILabel *subtitleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 54, width - 32, 16)];
    subtitleLabel.text = @"";
    subtitleLabel.font = [UIFont systemFontOfSize:13];
    subtitleLabel.textColor = [LTTheme isDark] ? [UIColor colorWithWhite:1.0f alpha:0.75f]
                                               : [LTTheme secondaryText];
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

#pragma mark - Refresh

// Re-fetches the home content: radio-mix shelves, server shelves/account
// library + history when signed in, and the banner stats. The button shows
// a spinner and is disabled while any of those requests are in flight; on
// failure the previous content stays on screen.
- (void)refreshTapped:(id)sender {
    if (self.refreshing) return;
    self.refreshing = YES;
    [self setRefreshItemBusy:YES];

    [LTPersonalShelves invalidate];
    self.homeShelves = nil;
    self.radioSeeds = nil;
    self.accountLoaded = NO;
    self.accountLoading = NO;

    __weak LTHomeViewController *weakSelf = self;
    __block NSInteger remaining = 2;
    void (^jobDone)(void) = ^{
        LTHomeViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (--remaining > 0) return;
        strongSelf.refreshing = NO;
        [strongSelf setRefreshItemBusy:NO];
        [strongSelf updateBannerText];
        [strongSelf reloadData];
        if (strongSelf.sections.count == 0 && strongSelf.recentTracks.count) {
            [strongSelf showToast:@"Couldn't refresh — check your connection."];
        }
    };

    [self loadRecentsRadioShelvesIfNeededWithCompletion:jobDone];
    [self loadAccountContentIfNeededWithCompletion:jobDone];
}

- (void)setRefreshItemBusy:(BOOL)busy {
    if (busy) {
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
                                            initWithActivityIndicatorStyle:[LTTheme isDark]
                                            ? UIActivityIndicatorViewStyleWhite
                                            : UIActivityIndicatorViewStyleGray];
        spinner.hidesWhenStopped = YES;
        [spinner startAnimating];
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:spinner];
    } else {
        self.navigationItem.leftBarButtonItem = self.refreshItem;
    }
}

- (void)showToast:(NSString *)text {
    [LTToast showText:text inView:self.view];
}

#pragma mark - Account content

- (void)authDidChange:(NSNotification *)notification {
    self.homeShelves = nil;
    self.radioSeeds = nil;
    [LTPersonalShelves invalidate];
    self.libraryItems = nil;
    self.historyTracks = nil;
    self.accountLoaded = NO;
    self.accountLoading = NO;
    [self updateBannerText];
    [self reloadData];
    [self loadAccountContentIfNeeded];
}

- (void)loadAccountContentIfNeeded {
    [self loadRecentsRadioShelvesIfNeeded];
    [self loadAccountContentIfNeededWithCompletion:nil];
}

// The home shelves are built locally from the listening history (radio
// mixes seeded by recently played tracks), so they follow what the user
// actually listened to instead of YouTube's geo-personalized home, which
// is dominated by content from the user's country. The optional completion
// fires exactly once, when both account requests are done (immediately when
// nothing needed fetching). Note: this does NOT build the radio shelves;
// callers that need them invoke loadRecentsRadioShelvesIfNeeded themselves.
- (void)loadAccountContentIfNeededWithCompletion:(void (^)(void))completion {
    if (![[LTAuth sharedAuth] signedIn]) {
        if (completion) completion();
        return;
    }
    if (self.accountLoaded || self.accountLoading) {
        if (completion) completion();
        return;
    }
    self.accountLoading = YES;
    [self.accountSpinner startAnimating];

    LTYouTubeClient *client = [LTYouTubeClient sharedClient];
    __weak LTHomeViewController *weakSelf = self;
    // Both requests complete on the main queue, so a plain counter
    // is enough to detect when the batch is done.
    __block NSInteger remaining = 2;

    void (^oneFinished)(void) = ^{
        remaining -= 1;
        if (remaining > 0) return;
        LTHomeViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.accountLoading = NO;
        strongSelf.accountLoaded = YES;
        [strongSelf.accountSpinner stopAnimating];
        [strongSelf reloadData];
        if (completion) completion();
    };

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

// Builds one "Because you played …" shelf per recently played track (up to
// six seeds) using YouTube Music mixes (RDAMVM<videoId>). The mix fetching
// and caching live in LTPersonalShelves, shared with the Search idle state.
// The optional completion fires exactly once, after every mix request of the
// build has finished (immediately when nothing needed fetching).
- (void)loadRecentsRadioShelvesIfNeeded {
    [self loadRecentsRadioShelvesIfNeededWithCompletion:nil];
}

- (void)loadRecentsRadioShelvesIfNeededWithCompletion:(void (^)(void))completion {
    self.recentTracks = [[LTPlaylistStore sharedStore] recentTracks];
    if (!self.recentTracks.count) {
        // No listening history yet: recommend nothing. (The old fallback
        // pulled YouTube's country-personalized home shelves — geo content,
        // removed.) The empty state tells the user what to do.
        if (completion) completion();
        return;
    }

    // Rebuild only when there is nothing cached yet or the user's refresh
    // button / a sign-in change dropped the cache — never on every action
    // (appearing, playing a song, etc.). Stale seeds are fine; the refresh
    // button is the explicit way to catch up.
    if (self.radioSeeds && [LTPersonalShelves hasCachedShelves]) {
        if (completion) completion();
        return;
    }
    NSArray *seeds = [LTPersonalShelves currentSeeds];
    self.radioSeeds = seeds;
    self.radioLoading = YES;

    __weak LTHomeViewController *weakSelf = self;
    [LTPersonalShelves buildShelvesWithCompletion:^(NSArray *shelves, BOOL finished) {
        LTHomeViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        // Keep the previous content if every mix failed, so a refresh can
        // never blank the page.
        if (shelves.count) strongSelf.homeShelves = shelves;
        if (finished) {
            strongSelf.radioLoading = NO;
            if (completion) completion();
        }
        [strongSelf reloadData];
    }];
}

#pragma mark - Sections

- (void)rebuildSections {
    NSMutableArray *layout = [NSMutableArray array];
    BOOL signedIn = [[LTAuth sharedAuth] signedIn];
    if (self.homeShelves.count) {
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
            self.emptyLabel.text = @"Nothing here yet.\nPlay a song, or tap ↻ to fetch recommendations.";
        } else {
            self.emptyLabel.text = @"Nothing here yet.\nPlay a song and create playlists to see them.";
        }
        self.emptyLabel.hidden = NO;
    } else {
        self.emptyLabel.hidden = YES;
    }
}

- (void)storeDidChange:(NSNotification *)notification {
    // Recents/playlists changed: only update the locally-built sections.
    // The radio shelves are NOT rebuilt here — a new song must not trigger
    // network work; the refresh button rebuilds them on demand.
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
