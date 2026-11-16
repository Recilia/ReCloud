#import "LTSearchViewController.h"
#import "LTYouTubeClient.h"
#import "LTModel.h"
#import "LTMediaCell.h"
#import "LTTrackListViewController.h"
#import "LTArtistViewController.h"
#import "LTTabBarController.h"
#import "LTPlayerController.h"
#import "LTPlaylistStore.h"
#import "LTPlaylistPicker.h"
#import "LTLocalPlaylistDetailViewController.h"
#import "LTSpinnerView.h"
#import "LTGraphics.h"
#import "LTSimpleCell.h"
#import "LTTheme.h"
#import "LTLog.h"
#import "LTShelfCell.h"
#import "LTPersonalShelves.h"
#import "LTToast.h"
#import <QuartzCore/QuartzCore.h>

@interface LTSearchViewController () <UISearchBarDelegate, UITableViewDataSource, UITableViewDelegate,
                                       UIActionSheetDelegate, UIAlertViewDelegate>
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UISegmentedControl *segControl;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray *results;
@property (nonatomic, strong) NSArray *localResults;
@property (nonatomic, copy) NSString *currentQuery;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, strong) LTTrack *pendingTrack;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, assign) BOOL ignorePlaylistChanges;
@property (nonatomic, assign) BOOL showingHistory;
// Idle state (no query): recommendation content mirroring the Home screen.
@property (nonatomic, strong) NSArray *idleChips;
@property (nonatomic, strong) NSArray *trendingTracks;
@property (nonatomic, assign) BOOL trendingLoading;
@property (nonatomic, strong) NSArray *idleShelves;  // @{"title","items"}
@end

@implementation LTSearchViewController

- (id)init {
    return [self initWithType:@"songs"];
}

- (id)initWithType:(NSString *)type {
    self = [super init];
    if (self) {
        _type = [type copy] ?: @"songs";
        _results = [NSMutableArray array];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if ([self respondsToSelector:@selector(setEdgesForExtendedLayout:)]) {
        self.edgesForExtendedLayout = UIRectEdgeNone;
    }
    self.view.backgroundColor = [LTTheme background];

    CGRect bounds = self.view.bounds;
    CGFloat tableY = 0;

    if (![self isPlaylistsMode]) {
        self.title = @"Search";
        self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, bounds.size.width, 44)];
        self.searchBar.placeholder = [self searchPlaceholderForType:self.type];
        self.searchBar.delegate = self;
        self.searchBar.showsCancelButton = YES;
        self.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
        self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
        [self.view addSubview:self.searchBar];

        NSArray *types = @[@"songs", @"videos", @"albums", @"artists"];
        NSUInteger defaultIndex = [types indexOfObject:self.type];
        if (defaultIndex == NSNotFound) defaultIndex = 0;
        self.segControl = [[UISegmentedControl alloc] initWithItems:@[@"Songs", @"Videos", @"Albums", @"Artists"]];
        self.segControl.selectedSegmentIndex = (NSInteger)defaultIndex;
        [self.segControl addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
        self.segControl.frame = CGRectMake(8, 50, bounds.size.width - 16, 32);
        self.segControl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
        [self.view addSubview:self.segControl];

        tableY = 88;
    } else {
        self.title = @"Playlists";
    }

    self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, tableY, bounds.size.width, bounds.size.height - tableY)
                                                  style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.backgroundColor = [LTTheme background];
    [self.view addSubview:self.tableView];

    self.emptyLabel = [[UILabel alloc] initWithFrame:CGRectMake(24, 120, bounds.size.width - 48, 60)];
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.font = [UIFont systemFontOfSize:15];
    self.emptyLabel.textColor = [LTTheme secondaryText];
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.hidden = YES;
    [self.view addSubview:self.emptyLabel];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    CGFloat width = bounds.size.width;
    if (width < 1.0f) return;

    BOOL searchMode = ![self isPlaylistsMode];
    if (searchMode) {
        UIFont *font = (width < 360.0f) ? [UIFont boldSystemFontOfSize:9]
                                        : [UIFont boldSystemFontOfSize:11];
        [self.segControl setTitleTextAttributes:@{UITextAttributeFont: font}
                                       forState:UIControlStateNormal];
        self.segControl.frame = CGRectMake(8, 50, width - 16, 32);
        self.searchBar.frame = CGRectMake(0, 0, width, 44);
    }

    CGFloat tableY = searchMode ? 88.0f : 46.0f;
    self.tableView.frame = CGRectMake(0, tableY, width, bounds.size.height - tableY);
    self.emptyLabel.frame = CGRectMake(24, tableY + 80, width - 48, 120);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playlistsDidChange:)
                                                 name:LTPlaylistsDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(downloadProgress:)
                                                 name:LTPlaylistDownloadProgressNotification
                                               object:nil];
    if ([self isPlaylistsMode]) {
        [self showLocalPlaylists];
    } else if (self.currentQuery.length && !self.results.count && !self.loading) {
        [self performSearch];
    } else if (!self.currentQuery.length && !self.showingHistory) {
        [self showIdleContent];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    self.view.backgroundColor = [LTTheme background];
    self.tableView.backgroundColor = [LTTheme background];
    self.emptyLabel.textColor = [LTTheme secondaryText];
    [self.tableView reloadData];
}

- (BOOL)isPlaylistsMode {
    return [self.type isEqualToString:@"playlists"];
}

- (NSString *)currentType {
    return self.type;
}

- (NSString *)searchPlaceholderForType:(NSString *)type {
    if ([type isEqualToString:@"videos"]) return @"Search YouTube";
    return @"Search YouTube Music";
}

- (BOOL)hasLocalSection {
    return (![self isPlaylistsMode] && !self.showingHistory && self.currentQuery.length);
}

- (NSArray *)libraryTracksMatchingQuery:(NSString *)query {
    if (!query.length) return nil;
    query = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!query.length) return nil;
    NSMutableArray *matches = [NSMutableArray array];
    for (LTTrack *track in [[LTPlaylistStore sharedStore] downloadedTracks]) {
        NSString *title = track.title.length ? track.title : @"";
        NSString *artist = track.artist.length ? track.artist : @"";
        if ([title rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [artist rangeOfString:query options:NSCaseInsensitiveSearch].location != NSNotFound) {
            [matches addObject:track];
        }
    }
    return matches;
}

- (id)itemAtIndexPath:(NSIndexPath *)indexPath {
    if ([self hasLocalSection] && indexPath.section == 0) {
        if (indexPath.row >= (NSInteger)self.localResults.count) return nil;
        return [self.localResults objectAtIndex:(NSUInteger)indexPath.row];
    }
    return [self.results objectAtIndex:(NSUInteger)indexPath.row];
}

#pragma mark - Segmented control

- (void)segmentChanged:(id)sender {
    NSArray *types = @[@"songs", @"videos", @"albums", @"artists"];
    NSInteger idx = self.segControl.selectedSegmentIndex;
    if (idx < 0 || idx >= (NSInteger)types.count) return;
    NSString *newType = [types objectAtIndex:(NSUInteger)idx];
    if ([newType isEqualToString:self.type]) return;
    self.type = newType;
    self.searchBar.placeholder = [self searchPlaceholderForType:newType];
    self.currentQuery = nil;
    [self.results removeAllObjects];
    self.localResults = nil;
    [self.tableView reloadData];
    self.emptyLabel.hidden = YES;
    NSString *query = [self.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (query.length) {
        [self performSearch];
    } else {
        [self showIdleContent];
    }
}

#pragma mark - Actions

- (void)showLocalPlaylists {
    [self.results removeAllObjects];
    NSArray *playlists = [[LTPlaylistStore sharedStore] playlists];
    [self.results addObjectsFromArray:playlists];
    [self.tableView reloadData];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                                           target:self
                                                                                           action:@selector(newPlaylistTapped:)];
    if (!playlists.count) {
        self.emptyLabel.text = @"No playlists yet.\nTap + to create one.";
        self.emptyLabel.hidden = NO;
    } else {
        self.emptyLabel.hidden = YES;
    }
}

- (void)newPlaylistTapped:(id)sender {
    [self promptForPlaylistNameWithTrack:nil];
}

- (void)showIdleContent {
    self.showingHistory = YES;
    [self.results removeAllObjects];
    self.localResults = nil;
    if (!self.idleChips.count) {
        self.idleChips = @[@"Pop", @"Rock", @"Hip-Hop", @"Electronic", @"Jazz",
                           @"Lo-fi", @"Workout", @"Chill", @"Focus", @"Party",
                           @"Sleep", @"Classical"];
    }
    self.emptyLabel.hidden = YES;
    [self.tableView reloadData];
    [self loadTrendingIfNeeded];
    [self loadIdleShelvesIfNeeded];
}

// Trending strip shown in the idle state, fetched once per session.
- (void)loadTrendingIfNeeded {
    if (self.trendingTracks.count || self.trendingLoading) return;
    self.trendingLoading = YES;
    __weak LTSearchViewController *weakSelf = self;
    [[LTYouTubeClient sharedClient] fetchTrendingSongsWithCompletion:^(NSArray *tracks, NSError *error) {
        LTSearchViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.trendingLoading = NO;
        if (error) {
            LTLog(@"SEARCH trending error %@", error);
        } else if (tracks.count) {
            strongSelf.trendingTracks = tracks;
        }
        if (strongSelf.showingHistory) [strongSelf.tableView reloadData];
    }];
}

// "Recommended for you" shelves, shared with Home via LTPersonalShelves
// (cached per seed set, so switching tabs refetches nothing).
- (void)loadIdleShelvesIfNeeded {
    if (self.idleShelves.count) return;
    __weak LTSearchViewController *weakSelf = self;
    [LTPersonalShelves buildShelvesWithCompletion:^(NSArray *shelves, BOOL finished) {
        LTSearchViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.idleShelves = shelves ?: @[];
        if (strongSelf.showingHistory) [strongSelf.tableView reloadData];
    }];
}

#pragma mark - Idle layout

// Section kinds of the idle table, in display order. Computed on demand so
// the data source always matches the current state.
- (NSArray *)idleSections {
    NSMutableArray *kinds = [NSMutableArray array];
    [kinds addObject:@"chips"];
    if ([[[LTPlaylistStore sharedStore] searchHistory] count]) [kinds addObject:@"history"];
    if (self.trendingTracks.count) [kinds addObject:@"trending"];
    for (NSUInteger i = 0; i < self.idleShelves.count; i++) {
        [kinds addObject:[NSString stringWithFormat:@"shelf%d", (int)i]];
    }
    return kinds;
}

- (NSString *)idleKindForSection:(NSInteger)section {
    NSArray *kinds = [self idleSections];
    if (section < 0 || section >= (NSInteger)kinds.count) return nil;
    return [kinds objectAtIndex:(NSUInteger)section];
}

- (NSDictionary *)shelfForSection:(NSInteger)section {
    NSString *kind = [self idleKindForSection:section];
    if (kind.length <= 5 || ![kind hasPrefix:@"shelf"]) return nil;
    NSInteger index = [kind substringFromIndex:5].integerValue;
    if (index < 0 || index >= (NSInteger)self.idleShelves.count) return nil;
    return [self.idleShelves objectAtIndex:(NSUInteger)index];
}

- (void)playTrack:(LTTrack *)track fromItems:(NSArray *)items sourceName:(NSString *)name {
    NSInteger index = 0;
    for (NSUInteger i = 0; i < (NSInteger)items.count; i++) {
        if ([items objectAtIndex:(NSUInteger)i] == track) { index = (NSInteger)i; break; }
    }
    [[LTPlayerController sharedController] playQueue:items atIndex:index];
    [LTPlayerController sharedController].queueSourceName = name;
    [(LTTabBarController *)self.tabBarController showNowPlaying];
}

- (void)openBrowseItem:(LTBrowseItem *)bi {
    UIViewController *detail = nil;
    switch (bi.kind) {
        case LTBrowseKindAlbum:
            detail = [[LTTrackListViewController alloc] initWithBrowseId:bi.browseId
                                                                    kind:LTBrowseKindAlbum
                                                                   title:bi.title];
            break;
        case LTBrowseKindPlaylist:
            detail = [[LTTrackListViewController alloc] initWithBrowseId:bi.browseId
                                                                    kind:LTBrowseKindPlaylist
                                                                   title:bi.title];
            break;
        case LTBrowseKindArtist:
        default:
            detail = [[LTArtistViewController alloc] initWithBrowseId:bi.browseId
                                                               title:bi.title];
            break;
    }
    if (detail) [self.navigationController pushViewController:detail animated:YES];
}

- (void)performSearch {
    if ([self isPlaylistsMode]) {
        [self showLocalPlaylists];
        return;
    }
    [self.searchBar resignFirstResponder];
    NSString *query = self.searchBar.text;
    query = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!query.length) {
        [self showIdleContent];
        return;
    }
    self.showingHistory = NO;
    self.currentQuery = query;
    [[LTPlaylistStore sharedStore] recordSearchTerm:query];
    self.loading = YES;
    [self showSpinner:YES];

    NSString *type = [self currentType];
    if ([type isEqualToString:@"songs"]) {
        self.localResults = [self libraryTracksMatchingQuery:query];
    } else {
        self.localResults = nil;
    }
    LTLog(@"SEARCH query=%@ type=%@ downloaded=%d local=%d showHist=%d",
          query, type, (int)[[[LTPlaylistStore sharedStore] downloadedTracks] count],
          (int)self.localResults.count, (int)self.showingHistory);
    [self.tableView reloadData];

    __weak LTSearchViewController *weakSelf = self;
    void (^finish)(NSArray *, NSError *) = ^(NSArray *items, NSError *error) {
        LTSearchViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.loading = NO;
        [strongSelf showSpinner:NO];
        if (error) {
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Search Failed"
                                                            message:error.localizedDescription
                                                           delegate:nil
                                                  cancelButtonTitle:@"OK"
                                                  otherButtonTitles:nil];
            [alert show];
            return;
        }
        [strongSelf.results removeAllObjects];
        [strongSelf.results addObjectsFromArray:items];
        [strongSelf.tableView reloadData];
        strongSelf.emptyLabel.hidden = YES;
        if ([type isEqualToString:@"artists"]) {
            [strongSelf upgradeArtistAvatars];
        }
    };
    if ([type isEqualToString:@"videos"]) {
        [[LTYouTubeClient sharedClient] searchVideosWithQuery:query completion:finish];
    } else {
        [[LTYouTubeClient sharedClient] searchWithQuery:query type:type completion:finish];
    }
}

- (void)upgradeArtistAvatars {
    for (NSUInteger i = 0; i < self.results.count; i++) {
        id item = [self.results objectAtIndex:i];
        if (![item isKindOfClass:[LTBrowseItem class]]) continue;
        LTBrowseItem *bi = item;
        if (bi.kind != LTBrowseKindArtist || !bi.browseId.length) continue;
        __weak LTSearchViewController *weakSelf = self;
        [[LTYouTubeClient sharedClient] channelAvatarURLForBrowseId:bi.browseId completion:^(NSString *avatarURL) {
            LTSearchViewController *strongSelf = weakSelf;
            if (!strongSelf || !avatarURL.length) return;
            NSString *square = [[LTYouTubeClient sharedClient] channelAvatarURL:avatarURL size:160];
            bi.thumbnailURL = square;
            if (i < strongSelf.results.count && [strongSelf.results objectAtIndex:i] == bi) {
                [strongSelf.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:(NSInteger)i inSection:0]]
                                            withRowAnimation:UITableViewRowAnimationNone];
            }
        }];
    }
}

- (void)showSpinner:(BOOL)show {
    if (show) {
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
                                            initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhite];
        spinner.hidesWhenStopped = YES;
        [spinner startAnimating];
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:spinner];
    } else {
        self.navigationItem.rightBarButtonItem = nil;
    }
}

- (void)showToast:(NSString *)text {
    [LTToast showText:text inView:self.view];
}

#pragma mark - Add to playlist / queue

- (void)showSongOptionsForTrack:(LTTrack *)track {
    self.pendingTrack = track;
    NSString *lastOption = [[LTPlaylistStore sharedStore] isTrackDownloaded:track] ? @"Remove Download" : @"Download";
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:track.title
                                                       delegate:self
                                              cancelButtonTitle:@"Cancel"
                                         destructiveButtonTitle:nil
                                              otherButtonTitles:@"Add to Queue", @"Add to Playlist...", lastOption, nil];
    sheet.tag = 10;
    [sheet showInView:self.view];
}

- (void)showPlaylistPickerForTrack:(LTTrack *)track {
    [LTPlaylistPicker presentFromViewController:self
                                     panelTitle:track.title
                                      onPicked:^(LTLocalPlaylist *playlist) {
        [[LTPlaylistStore sharedStore] addTrack:self.pendingTrack toPlaylist:playlist];
        [self showToast:[NSString stringWithFormat:@"Added to %@", playlist.name]];
        self.pendingTrack = nil;
    } onCreateNew:^(NSString *name) {
        LTLocalPlaylist *playlist = [[LTPlaylistStore sharedStore] createPlaylistWithName:name];
        if (playlist && self.pendingTrack) {
            [[LTPlaylistStore sharedStore] addTrack:self.pendingTrack toPlaylist:playlist];
            [self showToast:[NSString stringWithFormat:@"Added to %@", playlist.name]];
        }
        self.pendingTrack = nil;
    }];
}

- (void)promptForPlaylistNameWithTrack:(LTTrack *)track {
    self.pendingTrack = track;
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"New Playlist"
                                                    message:@"Enter a name for the playlist."
                                                   delegate:self
                                          cancelButtonTitle:@"Cancel"
                                          otherButtonTitles:@"Create", nil];
    alert.tag = 200;
    alert.alertViewStyle = UIAlertViewStylePlainTextInput;
    [alert show];
}

#pragma mark - UIActionSheetDelegate

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (actionSheet.tag == 10) {
        if (buttonIndex == 0) {
            [[LTPlayerController sharedController] enqueueTracks:@[self.pendingTrack]];
            [self showToast:@"Added to queue"];
            self.pendingTrack = nil;
        } else if (buttonIndex == 1) {
            [self showPlaylistPickerForTrack:self.pendingTrack];
        } else if (buttonIndex == 2) {
            LTTrack *track = self.pendingTrack;
            self.pendingTrack = nil;
            if ([[LTPlaylistStore sharedStore] isTrackDownloaded:track]) {
                [[LTPlaylistStore sharedStore] removeDownloadsForTracks:@[track]];
                [self showToast:@"Removed download"];
            } else {
                if ([[LTPlaylistStore sharedStore] isDownloading]) {
                    [self showToast:@"A download is already in progress"];
                } else {
                    __weak LTSearchViewController *weakSelf = self;
                    [[LTPlaylistStore sharedStore] downloadTracks:@[track] completion:^{
                        [weakSelf showToast:@"Downloaded"];
                    }];
                }
            }
        }
    } else if (actionSheet.tag == 11) {
        // Handled by LTPlaylistPicker now.
    }
}

#pragma mark - UIAlertViewDelegate

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (alertView.tag == 200 && buttonIndex == 1) {
        NSString *name = [[alertView textFieldAtIndex:0] text];
        LTLocalPlaylist *playlist = [[LTPlaylistStore sharedStore] createPlaylistWithName:name];
        if (playlist) {
            if (self.pendingTrack) {
                [[LTPlaylistStore sharedStore] addTrack:self.pendingTrack toPlaylist:playlist];
                [self showToast:[NSString stringWithFormat:@"Added to %@", playlist.name]];
            } else {
                [self showLocalPlaylists];
                [self showToast:@"Playlist created"];
            }
        }
    }
    self.pendingTrack = nil;
}

#pragma mark - Notifications

- (void)playlistsDidChange:(NSNotification *)notification {
    if (self.ignorePlaylistChanges) return;
    if ([self isPlaylistsMode]) {
        [self showLocalPlaylists];
    }
}

- (void)downloadProgress:(NSNotification *)notification {
    [self.tableView reloadData];
}

#pragma mark - UISearchBarDelegate

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [self performSearch];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    searchBar.text = @"";
    self.currentQuery = nil;
    [self.results removeAllObjects];
    self.localResults = nil;
    self.emptyLabel.hidden = YES;
    [self showIdleContent];
}

- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar {
    searchBar.showsCancelButton = YES;
    if (!searchBar.text.length && !self.currentQuery.length) {
        [self showIdleContent];
    }
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    if ([self isPlaylistsMode]) return 1;
    if (self.showingHistory) return (NSInteger)[self idleSections].count;
    return [self hasLocalSection] ? 2 : 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if ([self isPlaylistsMode]) return (NSInteger)self.results.count;
    if (self.showingHistory) {
        NSString *kind = [self idleKindForSection:section];
        if ([kind isEqualToString:@"chips"] || [kind isEqualToString:@"trending"]) return 1;
        if ([kind isEqualToString:@"history"]) {
            return (NSInteger)[[[LTPlaylistStore sharedStore] searchHistory] count];
        }
        return 1; // recommended shelf strip
    }
    if ([self hasLocalSection] && section == 0) {
        return self.localResults.count > 0 ? (NSInteger)self.localResults.count : 1;
    }
    return (NSInteger)self.results.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (self.showingHistory) {
        NSString *kind = [self idleKindForSection:section];
        if ([kind isEqualToString:@"history"]) return @"Recent Searches";
        if ([kind isEqualToString:@"trending"]) return @"Trending";
        NSDictionary *shelf = [self shelfForSection:section];
        return [shelf objectForKey:@"title"];
    }
    if ([self hasLocalSection]) {
        if (section == 0) return @"From Your Library";
        if (section == 1) return @"YouTube";
    }
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.showingHistory) {
        NSString *kind = [self idleKindForSection:indexPath.section];
        if ([kind isEqualToString:@"chips"]) return [LTChipStripCell contentHeight];
        if ([kind isEqualToString:@"history"]) return 44.0f;
        return [LTHomeRecentsCell contentHeight];
    }
    if (![self isPlaylistsMode] && [self hasLocalSection] && indexPath.section == 0) return 60.0f;
    return 60.0f;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.showingHistory) {
        NSString *kind = [self idleKindForSection:indexPath.section];

        if ([kind isEqualToString:@"chips"]) {
            static NSString *ChipCellId = @"LTSearchChipCell";
            LTChipStripCell *cell = [tableView dequeueReusableCellWithIdentifier:ChipCellId];
            if (!cell) {
                cell = [[LTChipStripCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:ChipCellId];
            }
            __weak LTSearchViewController *weakSelf = self;
            cell.onChipTapped = ^(NSInteger index, NSString *title) {
                LTSearchViewController *strongSelf = weakSelf;
                if (!strongSelf) return;
                strongSelf.searchBar.text = title;
                [strongSelf performSearch];
            };
            [cell setChips:self.idleChips];
            return cell;
        }

        if ([kind isEqualToString:@"trending"] || [kind hasPrefix:@"shelf"]) {
            NSDictionary *shelf = [self shelfForSection:indexPath.section];
            NSArray *items = shelf ? [shelf objectForKey:@"items"] : nil;
            BOOL isTrending = [kind isEqualToString:@"trending"];
            if (!items && isTrending) items = self.trendingTracks;

            static NSString *StripCellId = @"LTSearchStripCell";
            LTHomeShelfCell *cell = [tableView dequeueReusableCellWithIdentifier:StripCellId];
            if (!cell) {
                cell = [[LTHomeShelfCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:StripCellId];
            }
            __weak LTSearchViewController *weakSelf = self;
            cell.onTrackTapped = ^(LTTrack *track) {
                LTSearchViewController *strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf playTrack:track
                            fromItems:items
                           sourceName:isTrending ? @"Trending" : @"Recommended"];
            };
            cell.onBrowseTapped = ^(LTBrowseItem *item) {
                LTSearchViewController *strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf openBrowseItem:item];
            };
            [cell setItems:items];
            return cell;
        }

        static NSString *HistoryCellId = @"LTHistoryCell";
        NSArray *history = [[LTPlaylistStore sharedStore] searchHistory];
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:HistoryCellId];
        if (!cell) {
            cell = [[LTSimpleCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:HistoryCellId];
            cell.textLabel.font = [UIFont systemFontOfSize:15];
            cell.textLabel.textColor = [LTTheme text];
        }
        cell.textLabel.textAlignment = NSTextAlignmentLeft;
        cell.textLabel.text = [history objectAtIndex:(NSUInteger)indexPath.row];
        cell.textLabel.textColor = [LTTheme text];
        cell.imageView.image = [LTGraphics searchIcon];
        cell.accessoryView = nil;
        return cell;
    }

    static NSString *CellId = @"LTMediaCell";
    LTMediaCell *cell = [tableView dequeueReusableCellWithIdentifier:CellId];
    if (!cell) {
        cell = [[LTMediaCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:CellId];
        cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
        cell.detailTextLabel.textColor = [LTTheme secondaryText];
    }
    if ([self hasLocalSection] && indexPath.section == 0 && !self.localResults.count) {
        cell.textLabel.text = @"No matches in your library";
        cell.textLabel.textColor = [LTTheme secondaryText];
        cell.detailTextLabel.text = @"";
        cell.accessoryView = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.imageView.image = nil;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    id item = [self itemAtIndexPath:indexPath];
    if ([item isKindOfClass:[LTTrack class]]) {
        LTTrack *track = item;
        cell.textLabel.text = track.title;
        NSMutableString *detail = [NSMutableString string];
        if (track.artist.length) [detail appendString:track.artist];
        if (track.album.length) {
            if (detail.length) [detail appendString:@"  •  "];
            [detail appendString:track.album];
        }
        cell.detailTextLabel.text = detail;
        if ([[LTPlaylistStore sharedStore] isTrackDownloading:track]) {
            LTSpinnerView *spinner = [[LTSpinnerView alloc] initWithFrame:CGRectMake(0, 0, 22, 22)];
            [spinner startAnimating];
            cell.accessoryView = spinner;
        } else {
            UIButton *plus = [UIButton buttonWithType:UIButtonTypeContactAdd];
            NSInteger offset = ([self hasLocalSection] && indexPath.section == 0) ? 0 : 100000;
            plus.tag = offset + (NSInteger)indexPath.row;
            [plus addTarget:self action:@selector(songPlusTapped:) forControlEvents:UIControlEventTouchUpInside];
            cell.accessoryView = plus;
        }
        [cell setImageFromURL:track.thumbnailURL];
    } else if ([item isKindOfClass:[LTBrowseItem class]]) {
        LTBrowseItem *bi = item;
        cell.textLabel.text = bi.title;
        cell.detailTextLabel.text = bi.subtitle;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        [cell setImageFromURL:bi.thumbnailURL];
    } else if ([item isKindOfClass:[LTLocalPlaylist class]]) {
        LTLocalPlaylist *playlist = item;
        cell.textLabel.text = playlist.name;
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%d tracks", (int)playlist.tracks.count];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.imageView.image = nil;
        if (playlist.coverPath.length) {
            cell.imageView.image = [UIImage imageWithContentsOfFile:playlist.coverPath];
        } else if (playlist.tracks.count) {
            LTTrack *first = [playlist.tracks objectAtIndex:0];
            if (first.thumbnailURL.length) {
                NSString *artURL = [[LTYouTubeClient sharedClient] highResThumbnailURL:first.thumbnailURL];
                cell.imageView.image = nil;
                __weak UITableViewCell *weakCell = cell;
                [[LTYouTubeClient sharedClient] loadImageWithURL:artURL completion:^(UIImage *image) {
                    if (image) weakCell.imageView.image = image;
                }];
            }
        }
    }
    return cell;
}

#pragma mark - UITableViewDelegate

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self isPlaylistsMode];
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (![self isPlaylistsMode]) return UITableViewCellEditingStyleNone;
    if (indexPath.row >= (NSInteger)self.results.count) return UITableViewCellEditingStyleNone;
    id item = [self.results objectAtIndex:(NSUInteger)indexPath.row];
    return [item isKindOfClass:[LTLocalPlaylist class]] ? UITableViewCellEditingStyleDelete : UITableViewCellEditingStyleNone;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    id item = [self.results objectAtIndex:(NSUInteger)indexPath.row];
    if (![item isKindOfClass:[LTLocalPlaylist class]]) return;
    LTLocalPlaylist *playlist = item;
    self.ignorePlaylistChanges = YES;
    [[LTPlaylistStore sharedStore] deletePlaylist:playlist];
    [self.results removeObject:playlist];
    [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    self.ignorePlaylistChanges = NO;
    [self refreshEmptyState];
}

- (void)refreshEmptyState {
    if (![self isPlaylistsMode]) return;
    if (!self.results.count) {
        self.emptyLabel.text = @"No playlists yet.\nTap + to create one.";
        self.emptyLabel.hidden = NO;
    } else {
        self.emptyLabel.hidden = YES;
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.showingHistory) {
        NSString *kind = [self idleKindForSection:indexPath.section];
        if (![kind isEqualToString:@"history"]) return; // strips/chips handle their own taps
        NSArray *history = [[LTPlaylistStore sharedStore] searchHistory];
        if (indexPath.row >= (NSInteger)history.count) return;
        self.searchBar.text = [history objectAtIndex:(NSUInteger)indexPath.row];
        [self performSearch];
        return;
    }
    id item = [self itemAtIndexPath:indexPath];
    if (!item) return;
    if ([item isKindOfClass:[LTTrack class]]) {
        if ([self hasLocalSection] && indexPath.section == 0) {
            [[LTPlayerController sharedController] playQueue:self.localResults atIndex:indexPath.row];
            [LTPlayerController sharedController].queueSourceName = @"Library";
        } else {
            NSArray *tracks = [self tracksFromResults];
            NSInteger index = 0;
            for (NSUInteger i = 0; i < tracks.count; i++) {
                if ([[tracks objectAtIndex:i] isEqual:item]) { index = (NSInteger)i; break; }
            }
            [[LTPlayerController sharedController] playQueue:tracks atIndex:index];
            [LTPlayerController sharedController].queueSourceName = self.searchBar.text ?: @"Search";
        }
        [(LTTabBarController *)self.tabBarController showNowPlaying];
    } else if ([item isKindOfClass:[LTBrowseItem class]]) {
        [self openBrowseItem:item];
    } else if ([item isKindOfClass:[LTLocalPlaylist class]]) {
        LTLocalPlaylist *playlist = item;
        LTLocalPlaylistDetailViewController *detail = [[LTLocalPlaylistDetailViewController alloc] initWithPlaylist:playlist];
        [self.navigationController pushViewController:detail animated:YES];
    }
}

- (void)tableView:(UITableView *)tableView accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)indexPath {
    [self showSongOptionsAtIndex:(NSInteger)indexPath.row section:(NSInteger)indexPath.section];
}

- (void)songPlusTapped:(UIButton *)button {
    NSInteger tag = (NSInteger)button.tag;
    NSInteger row = tag % 100000;
    NSInteger section = (tag < 100000) ? 0 : 1;
    [self showSongOptionsAtIndex:row section:section];
}

- (void)showSongOptionsAtIndex:(NSInteger)row section:(NSInteger)section {
    id item = nil;
    if ([self hasLocalSection] && section == 0) {
        if (row < 0 || row >= (NSInteger)self.localResults.count) return;
        item = [self.localResults objectAtIndex:(NSUInteger)row];
    } else {
        if (row < 0 || row >= (NSInteger)self.results.count) return;
        item = [self.results objectAtIndex:(NSUInteger)row];
    }
    if ([item isKindOfClass:[LTTrack class]]) {
        [self showSongOptionsForTrack:item];
    }
}

- (NSArray *)tracksFromResults {
    NSMutableArray *tracks = [NSMutableArray array];
    for (id item in self.results) {
        if ([item isKindOfClass:[LTTrack class]]) {
            [tracks addObject:item];
        }
    }
    return tracks;
}

@end
