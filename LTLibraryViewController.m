#import "LTLibraryViewController.h"
#import "LTLibrarySongsViewController.h"
#import "LTTrackListViewController.h"
#import "LTPlaylistStore.h"
#import "LTPlayerController.h"
#import "LTTabBarController.h"
#import "LTMediaCell.h"
#import "LTYouTubeClient.h"
#import "LTLocalPlaylistDetailViewController.h"
#import "LTGraphics.h"
#import "LTModel.h"
#import "LTToast.h"
#import "LTLog.h"
#import "LTSimpleCell.h"
#import "LTTheme.h"
#import "LTAuth.h"
#import "LTTableSongMenu.h"

// Cached copy of the signed-in account's playlists (Settings → Data management
// has no cache clearing for this; it refreshes on next successful fetch).
static NSString * const kLTLibraryAccountPlaylistsCache = @"LTLibraryAccountPlaylistsCache";

typedef NS_ENUM(NSInteger, LTLibrarySegment) {
    LTLibrarySegmentPlaylists = 0,
    LTLibrarySegmentSongs,
    LTLibrarySegmentArtists,
    LTLibrarySegmentAlbums,
};

@interface LTLibraryViewController () <UITableViewDataSource, UITableViewDelegate, UIAlertViewDelegate>
@property (nonatomic, strong) UISegmentedControl *segControl;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, assign) NSInteger currentSegment;
@property (nonatomic, strong) NSMutableArray *playlists;
@property (nonatomic, strong) NSMutableArray *songs;
@property (nonatomic, strong) NSArray *artists;
@property (nonatomic, strong) NSArray *albums;
@property (nonatomic, strong) NSMutableArray *accountItems;  // LTBrowseItem (account playlists)
@property (nonatomic, assign) BOOL accountLoading;
@property (nonatomic, assign) BOOL accountError;
@property (nonatomic, assign) BOOL accountRefreshed;
@property (nonatomic, strong) LTTrack *pendingRemoveTrack;
@property (nonatomic, assign) BOOL ignorePlaylistChanges;
@property (nonatomic, strong) NSMutableSet *attemptedArtistAvatars;
@end

@implementation LTLibraryViewController

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    CGFloat width = bounds.size.width;
    if (width < 1.0f) return;

    CGFloat tableY = 42.0f;

    UIFont *font = (width < 360.0f) ? [UIFont boldSystemFontOfSize:9]
                                    : [UIFont boldSystemFontOfSize:11];
    [self.segControl setTitleTextAttributes:@{UITextAttributeFont: font}
                                   forState:UIControlStateNormal];

    self.segControl.frame = CGRectMake(8, 6, width - 28, 30);
    self.tableView.frame = CGRectMake(0, tableY, width, bounds.size.height - tableY);
    self.emptyLabel.frame = CGRectMake(24, tableY + 150, width - 48, 60);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    if ([self respondsToSelector:@selector(setEdgesForExtendedLayout:)]) {
        self.edgesForExtendedLayout = UIRectEdgeNone;
    }
    self.title = @"Library";
    self.view.backgroundColor = [LTTheme background];
    self.currentSegment = LTLibrarySegmentPlaylists;
    self.attemptedArtistAvatars = [NSMutableSet set];
    [self loadAccountCache];

    CGRect bounds = self.view.bounds;
    self.segControl = [[UISegmentedControl alloc] initWithItems:@[@"Playlists", @"Songs", @"Artists", @"Albums"]];
    self.segControl.selectedSegmentIndex = 0;
    [self.segControl setTitleTextAttributes:@{UITextAttributeFont: [UIFont boldSystemFontOfSize:11]}
                                   forState:UIControlStateNormal];
    [self.segControl addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
    self.segControl.frame = CGRectMake(8, 6, bounds.size.width - 16, 30);
    self.segControl.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [self.view addSubview:self.segControl];

    CGFloat tableY = 42.0f;
    self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, tableY, bounds.size.width, bounds.size.height - tableY)
                                                  style:UITableViewStylePlain];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.backgroundColor = [LTTheme background];
    [self.view addSubview:self.tableView];
    // Hold a downloaded-song row (Songs segment) to open the song menu;
    // a vertical drag still scrolls.
    __weak LTLibraryViewController *weakSelf = self;
    [self.tableView lt_addSongMenuWithViewController:self
                                   trackAtIndexPath:^LTTrack *(NSIndexPath *indexPath) {
        LTLibraryViewController *strongSelf = weakSelf;
        if (!strongSelf) return nil;
        if (strongSelf.currentSegment != LTLibrarySegmentSongs) return nil;
        NSArray *items = [strongSelf currentItems];
        if (indexPath.row >= (NSInteger)items.count) return nil;
        id item = [items objectAtIndex:(NSUInteger)indexPath.row];
        return [item isKindOfClass:[LTTrack class]] ? item : nil;
    }];

    self.emptyLabel = [[UILabel alloc] initWithFrame:CGRectMake(24, tableY + 100, bounds.size.width - 48, 60)];
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.font = [UIFont systemFontOfSize:15];
    self.emptyLabel.textColor = [LTTheme secondaryText];
    self.emptyLabel.numberOfLines = 0;
    self.emptyLabel.hidden = YES;
    [self.view addSubview:self.emptyLabel];

    [self reloadModels];
    [self reloadForSegment];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(storeDidChange:)
                                                 name:LTPlaylistsDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(authDidChange:)
                                                 name:LTAuthDidChangeNotification
                                               object:nil];
    [self reloadModels];
    [self reloadForSegment];
    [self refreshAccountPlaylists];
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

#pragma mark - Data

// Account playlists are persisted so the tab is never blank on relaunch even
// before (or without) a network refresh.
- (void)loadAccountCache {
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kLTLibraryAccountPlaylistsCache];
    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *dict in saved) {
        if (![dict isKindOfClass:[NSDictionary class]]) continue;
        LTBrowseItem *item = [[LTBrowseItem alloc] init];
        item.kind = LTBrowseKindPlaylist;
        item.browseId = [dict objectForKey:@"browseId"];
        item.title = [dict objectForKey:@"title"];
        item.subtitle = [dict objectForKey:@"subtitle"];
        item.thumbnailURL = [dict objectForKey:@"thumb"];
        if (item.browseId.length && item.title.length) [items addObject:item];
    }
    self.accountItems = items;
}

- (void)saveAccountCache {
    NSMutableArray *array = [NSMutableArray array];
    for (LTBrowseItem *item in self.accountItems) {
        [array addObject:@{ @"browseId": item.browseId ?: @"",
                            @"title": item.title ?: @"",
                            @"subtitle": item.subtitle ?: @"",
                            @"thumb": item.thumbnailURL ?: @"" }];
    }
    [[NSUserDefaults standardUserDefaults] setObject:array forKey:kLTLibraryAccountPlaylistsCache];
}

- (BOOL)signedIn {
    return [[LTAuth sharedAuth] signedIn];
}

// Refreshes the account playlists once per session (and after each sign-in).
// On failure the cached copy stays visible; the error state is only shown when
// there is nothing cached at all.
- (void)refreshAccountPlaylists {
    if (!self.signedIn) return;
    if (self.accountLoading) return;
    self.accountLoading = YES;
    self.accountError = NO;
    [self reloadForSegment];

    LTYouTubeClient *client = [LTYouTubeClient sharedClient];
    __weak LTLibraryViewController *weakSelf = self;
    [client fetchLibraryPlaylistsWithCompletion:^(NSArray *items, NSError *error) {
        LTLibraryViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.accountLoading = NO;
        strongSelf.accountRefreshed = YES;
        if (error) {
            LTLog(@"LIB account playlists error %@", error);
            strongSelf.accountError = (strongSelf.accountItems.count == 0);
        } else {
            strongSelf.accountItems = [items mutableCopy] ?: [NSMutableArray array];
            strongSelf.accountError = NO;
            [strongSelf saveAccountCache];
        }
        [strongSelf reloadForSegment];
    }];
}

- (void)authDidChange:(NSNotification *)notification {
    self.accountRefreshed = NO;
    self.accountError = NO;
    if (!self.signedIn) {
        self.accountItems = [NSMutableArray array];
        [self saveAccountCache];
    }
    [self reloadForSegment];
    [self refreshAccountPlaylists];
}

- (void)reloadModels {
    self.playlists = [[[LTPlaylistStore sharedStore] playlists] mutableCopy] ?: [NSMutableArray array];
    self.songs = [[[LTPlaylistStore sharedStore] downloadedTracks] mutableCopy] ?: [NSMutableArray array];

    NSMutableDictionary *artistMap = [NSMutableDictionary dictionary];
    for (LTTrack *track in self.songs) {
        NSString *name = (track.artist.length ? track.artist : @"Unknown Artist");
        NSString *key = [name lowercaseString];
        NSMutableDictionary *bucket = [artistMap objectForKey:key];
        if (!bucket) {
            bucket = [NSMutableDictionary dictionaryWithObjectsAndKeys:name, @"name",
                                                             [NSMutableArray array], @"tracks", nil];
            [artistMap setObject:bucket forKey:key];
        }
        [[bucket objectForKey:@"tracks"] addObject:track];
    }
    self.artists = [artistMap allValues];

    NSMutableDictionary *albumMap = [NSMutableDictionary dictionary];
    for (LTTrack *track in self.songs) {
        NSString *rawAlbum = (track.album.length ? track.album : (track.title.length ? track.title : @"Unknown Album"));
        NSString *album = [self isUnknownAlbumPlaceholder:rawAlbum] ? @"Unknown Album" : rawAlbum;
        NSString *artist = (track.artist.length ? track.artist : @"Unknown Artist");
        NSString *key = [NSString stringWithFormat:@"%@|%@", [artist lowercaseString], [album lowercaseString]];
        NSMutableDictionary *bucket = [albumMap objectForKey:key];
        if (!bucket) {
            bucket = [NSMutableDictionary dictionaryWithObjectsAndKeys:album, @"name",
                                                             artist, @"artist",
                                                             [NSMutableArray array], @"tracks", nil];
            [albumMap setObject:bucket forKey:key];
        }
        [[bucket objectForKey:@"tracks"] addObject:track];
    }
    self.albums = [albumMap allValues];
}

- (NSArray *)sortedByName:(NSArray *)buckets {
    return [buckets sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        return [[a objectForKey:@"name"] caseInsensitiveCompare:[b objectForKey:@"name"]];
    }];
}

- (NSArray *)currentItems {
    switch (self.currentSegment) {
        case LTLibrarySegmentPlaylists: return self.playlists;
        case LTLibrarySegmentSongs: return self.songs;
        case LTLibrarySegmentArtists: return [self sortedByName:self.artists];
        case LTLibrarySegmentAlbums: return [self sortedByName:self.albums];
    }
    return nil;
}

- (BOOL)isUnknownAlbumPlaceholder:(NSString *)name {
    if (name.length != 1) return NO;
    unichar character = [name characterAtIndex:0];
    NSCharacterSet *letters = [NSCharacterSet letterCharacterSet];
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    if ([letters characterIsMember:character]) return NO;
    if ([digits characterIsMember:character]) return NO;
    return YES;
}

- (void)reloadForSegment {
    [self updateRightBarButton];
    [self.tableView reloadData];
    [self refreshEmptyState];
}

- (void)updateRightBarButton {
    if (self.currentSegment == LTLibrarySegmentPlaylists) {
        self.navigationItem.leftBarButtonItem = nil;
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                                               target:self
                                                                                               action:@selector(newPlaylistTapped:)];
        self.navigationItem.rightBarButtonItem.style = UIBarButtonItemStyleBordered;
    } else if (self.currentSegment == LTLibrarySegmentSongs) {
        UIBarButtonItem *shuffleItem = [[UIBarButtonItem alloc] initWithTitle:@"Shuffle"
                                                                        style:UIBarButtonItemStyleBordered
                                                                       target:self
                                                                       action:@selector(shuffleAllTapped)];
        UIBarButtonItem *playItem = [[UIBarButtonItem alloc] initWithTitle:@"Play All"
                                                                     style:UIBarButtonItemStyleBordered
                                                                    target:self
                                                                    action:@selector(playAllTapped)];
        shuffleItem.enabled = self.songs.count > 0;
        playItem.enabled = self.songs.count > 0;
        self.navigationItem.leftBarButtonItem = shuffleItem;
        self.navigationItem.rightBarButtonItem = playItem;
    } else {
        self.navigationItem.leftBarButtonItem = nil;
        self.navigationItem.rightBarButtonItem = nil;
    }
}

- (void)shuffleAllTapped {
    if (!self.songs.count) return;
    LTPlayerController *player = [LTPlayerController sharedController];
    player.repeatMode = LTRepeatModeAll;
    player.queueSourceName = @"Library";
    [player playQueue:self.songs shuffle:YES];
    [(LTTabBarController *)self.tabBarController showNowPlaying];
}

- (void)playAllTapped {
    if (!self.songs.count) return;
    LTPlayerController *player = [LTPlayerController sharedController];
    player.repeatMode = LTRepeatModeAll;
    player.queueSourceName = @"Library";
    [player playQueue:self.songs atIndex:0];
    [(LTTabBarController *)self.tabBarController showNowPlaying];
}

- (void)refreshEmptyState {
    NSArray *items = [self currentItems];
    if (self.currentSegment == LTLibrarySegmentPlaylists) {
        BOOL hasAccount = self.accountItems.count > 0 || self.accountLoading;
        if (self.playlists.count || hasAccount) {
            self.emptyLabel.hidden = YES;
            return;
        }
        if (self.accountError) {
            self.emptyLabel.text = @"Couldn't load your account playlists.\nTap the playlist list to retry.";
            self.emptyLabel.hidden = NO;
            return;
        }
        self.emptyLabel.text = self.signedIn
            ? @"No playlists found on your account.\nTap + to create one on this device."
            : @"No playlists yet.\nTap + to create one, or sign in from Settings to see your account playlists.";
        self.emptyLabel.hidden = NO;
        return;
    }
    if (items.count) {
        self.emptyLabel.hidden = YES;
        return;
    }
    switch (self.currentSegment) {
        case LTLibrarySegmentSongs:
            self.emptyLabel.text = @"No downloaded songs yet.\nUse the download button in Search or in a playlist.";
            break;
        case LTLibrarySegmentArtists:
        case LTLibrarySegmentAlbums:
        default:
            self.emptyLabel.text = @"Download songs to build your library.";
            break;
    }
    self.emptyLabel.hidden = NO;
}

#pragma mark - Actions

- (void)segmentChanged:(id)sender {
    self.currentSegment = self.segControl.selectedSegmentIndex;
    [self reloadForSegment];
}

- (void)newPlaylistTapped:(id)sender {
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"New Playlist"
                                                    message:@"Enter a name for the playlist."
                                                   delegate:self
                                          cancelButtonTitle:@"Cancel"
                                          otherButtonTitles:@"Create", nil];
    alert.tag = 700;
    alert.alertViewStyle = UIAlertViewStylePlainTextInput;
    [alert show];
}

- (void)storeDidChange:(NSNotification *)notification {
    if (self.ignorePlaylistChanges) return;
    [self reloadModels];
    [self reloadForSegment];
}

- (void)showToast:(NSString *)text {
    [LTToast showText:text inView:self.view];
}

#pragma mark - UIAlertViewDelegate

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (alertView.tag == 620 && buttonIndex == 1) {
        if (self.pendingRemoveTrack) {
            LTTrack *track = self.pendingRemoveTrack;
            self.pendingRemoveTrack = nil;
            LTLog(@"LIB remove download %@ title=%@", track.videoId, track.title);
            [[LTPlaylistStore sharedStore] removeDownloadsForTracks:@[track]];
        }
        return;
    }
    if (alertView.tag == 700 && buttonIndex == 1) {
        NSString *name = [[alertView textFieldAtIndex:0] text];
        name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (name.length) {
            [[LTPlaylistStore sharedStore] createPlaylistWithName:name];
            [self showToast:@"Playlist created"];
        }
    }
}

#pragma mark - UITableViewDataSource

// Playlists segment shows two sections: the signed-in account's playlists on
// top, local playlists stored on the device below.
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return (self.currentSegment == LTLibrarySegmentPlaylists && self.signedIn) ? 2 : 1;
}

- (NSInteger)accountSectionRowCount {
    if (self.accountLoading) return 1;
    if (self.accountError) return 1;
    return (NSInteger)self.accountItems.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.currentSegment == LTLibrarySegmentPlaylists && self.signedIn && section == 0) {
        return [self accountSectionRowCount];
    }
    if (self.currentSegment == LTLibrarySegmentPlaylists) return (NSInteger)self.playlists.count;
    return (NSInteger)[[self currentItems] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (self.currentSegment == LTLibrarySegmentPlaylists && self.signedIn) {
        return section == 0 ? @"Account playlists" : @"On this device";
    }
    return @"";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *TrackCellId = @"LTLibraryTrackCell";
    static NSString *BucketCellId = @"LTLibraryBucketCell";

    if (self.currentSegment == LTLibrarySegmentPlaylists && self.signedIn && indexPath.section == 0) {
        static NSString *AccountCellId = @"LTLibraryAccountCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:AccountCellId];
        if (!cell) {
            cell = [[LTSimpleCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:AccountCellId];
            cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
            cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
            cell.detailTextLabel.textColor = [LTTheme secondaryText];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        cell.imageView.image = nil;
        cell.accessibilityIdentifier = nil;
        if (self.accountLoading) {
            cell.textLabel.text = @"Loading your playlists…";
            cell.detailTextLabel.text = @"";
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }
        if (self.accountError) {
            cell.textLabel.text = @"Couldn't load account playlists";
            cell.detailTextLabel.text = @"Tap to retry";
            cell.detailTextLabel.textColor = [LTTheme accent];
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.selectionStyle = UITableViewCellSelectionStyleBlue;
            return cell;
        }
        cell.detailTextLabel.textColor = [LTTheme secondaryText];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        LTBrowseItem *item = [self.accountItems objectAtIndex:(NSUInteger)indexPath.row];
        cell.textLabel.text = item.title;
        cell.detailTextLabel.text = item.subtitle.length ? item.subtitle : @"Playlist";
        cell.accessibilityIdentifier = item.browseId;
        if (item.thumbnailURL.length) {
            NSString *artURL = [[LTYouTubeClient sharedClient] highResThumbnailURL:item.thumbnailURL];
            __weak UITableViewCell *weakCell = cell;
            [[LTYouTubeClient sharedClient] loadImageWithURL:artURL completion:^(UIImage *image) {
                UITableViewCell *strongCell = weakCell;
                if (image && [strongCell.accessibilityIdentifier isEqualToString:item.browseId]) {
                    strongCell.imageView.image = image;
                }
            }];
        }
        return cell;
    }

    NSArray *items = [self currentItems];    id item = [items objectAtIndex:(NSUInteger)indexPath.row];

    if (self.currentSegment == LTLibrarySegmentSongs) {
        LTMediaCell *cell = [tableView dequeueReusableCellWithIdentifier:TrackCellId];
        if (!cell) {
            cell = [[LTMediaCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:TrackCellId];
            cell.textLabel.font = [UIFont boldSystemFontOfSize:15];
            cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
            cell.detailTextLabel.textColor = [UIColor grayColor];
            cell.accessoryType = UITableViewCellAccessoryNone;
        }
        LTTrack *track = item;
        cell.textLabel.text = track.title;
        NSMutableString *detail = [NSMutableString string];
        if (track.artist.length) [detail appendString:track.artist];
        if (track.duration > 0) {
            if (detail.length) [detail appendString:@"   "];
            [detail appendString:[self formatDuration:track.duration]];
        }
        cell.detailTextLabel.text = detail;
        if (track.thumbnailURL.length) {
            [cell setImageFromURL:track.thumbnailURL];
        } else {
            cell.imageView.image = nil;
        }
        cell.accessoryView = [self removeAccessoryButtonForRow:indexPath.row];
        return cell;
    }

    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:BucketCellId];
    if (!cell) {
        cell = [[LTSimpleCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:BucketCellId];
        cell.textLabel.font = [UIFont boldSystemFontOfSize:16];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
        cell.detailTextLabel.textColor = [UIColor grayColor];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    cell.imageView.image = nil;

    if ([item isKindOfClass:[LTLocalPlaylist class]]) {
        LTLocalPlaylist *playlist = item;
        cell.textLabel.text = playlist.name;
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%d track%@", (int)playlist.tracks.count, playlist.tracks.count == 1 ? @"" : @"s"];
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
    } else {
        NSDictionary *bucket = item;
        NSArray *tracks = [bucket objectForKey:@"tracks"];
        NSString *name = [bucket objectForKey:@"name"];
        BOOL isArtist = (self.currentSegment == LTLibrarySegmentArtists);
        if (isArtist) {
            cell.textLabel.text = name;
            cell.accessibilityIdentifier = name;
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%d song%@", (int)tracks.count, tracks.count == 1 ? @"" : @"s"];
        } else {
            cell.textLabel.text = name;
            NSString *artist = [bucket objectForKey:@"artist"];
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%@   %d song%@",
                                         artist, (int)tracks.count, tracks.count == 1 ? @"" : @"s"];
        }
        NSString *avatarURL = isArtist ? [[LTPlaylistStore sharedStore] artistAvatarURLForName:name] : nil;
        if (avatarURL.length) {
            NSString *artURL = [[LTYouTubeClient sharedClient] channelAvatarURL:avatarURL size:120];
            __weak UITableViewCell *weakCell = cell;
            [[LTYouTubeClient sharedClient] loadImageWithURL:artURL completion:^(UIImage *image) {
                UITableViewCell *strongCell = weakCell;
                if (image && [strongCell.accessibilityIdentifier isEqualToString:name]) strongCell.imageView.image = image;
            }];
        } else {
            if (isArtist) [self resolveAvatarForArtistName:name];
            if (tracks.count) {
                LTTrack *first = [tracks objectAtIndex:0];
                if (first.thumbnailURL.length) {
                    NSString *artURL = [[LTYouTubeClient sharedClient] highResThumbnailURL:first.thumbnailURL];
                    __weak UITableViewCell *weakCell = cell;
                    [[LTYouTubeClient sharedClient] loadImageWithURL:artURL completion:^(UIImage *image) {
                        if (image) weakCell.imageView.image = image;
                    }];
                }
            }
        }
    }
    return cell;
}

- (void)resolveAvatarForArtistName:(NSString *)name {
    if (!name.length) return;
    NSString *key = [name lowercaseString];
    if ([self.attemptedArtistAvatars containsObject:key]) return;
    [self.attemptedArtistAvatars addObject:key];
    __weak LTLibraryViewController *weakSelf = self;
    [[LTYouTubeClient sharedClient] resolveArtistAvatarForName:name completion:^(NSString *avatarURL) {
        LTLibraryViewController *strongSelf = weakSelf;
        if (!strongSelf || !avatarURL.length) return;
        if (strongSelf.currentSegment != LTLibrarySegmentArtists) return;
        NSArray *items = [strongSelf currentItems];
        for (NSUInteger i = 0; i < items.count; i++) {
            id candidate = [items objectAtIndex:i];
            if (![candidate isKindOfClass:[NSDictionary class]]) continue;
            if (![[candidate objectForKey:@"name"] isEqualToString:name]) continue;
            [strongSelf.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:(NSInteger)i inSection:0]]
                                        withRowAnimation:UITableViewRowAnimationNone];
            break;
        }
    }];
}

- (UIButton *)removeAccessoryButtonForRow:(NSInteger)row {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.frame = CGRectMake(0, 0, 40, 32);
    [button setImage:[self scaledIcon:[LTGraphics checkmarkIcon]] forState:UIControlStateNormal];
    button.imageView.contentMode = UIViewContentModeCenter;
    button.tag = row;
    [button addTarget:self action:@selector(rowRemoveTapped:) forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIImage *)scaledIcon:(UIImage *)image {
    if (!image) return nil;
    CGSize target = CGSizeMake(22.0f, 22.0f);
    UIGraphicsBeginImageContextWithOptions(target, NO, image.scale);
    CGFloat scale = MIN(target.width / image.size.width, target.height / image.size.height);
    CGFloat dw = image.size.width * scale;
    CGFloat dh = image.size.height * scale;
    CGRect rect = CGRectMake((target.width - dw) / 2.0f, (target.height - dh) / 2.0f, dw, dh);
    [image drawInRect:rect];
    UIImage *scaled = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return scaled;
}

- (void)rowRemoveTapped:(id)sender {
    UIButton *button = (UIButton *)sender;
    NSInteger row = button.tag;
    NSArray *items = [self currentItems];
    if (row < 0 || row >= (NSInteger)items.count) return;
    LTTrack *track = [items objectAtIndex:(NSUInteger)row];
    if (![[LTPlaylistStore sharedStore] isTrackDownloaded:track]) return;
    self.pendingRemoveTrack = track;
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Remove Download"
                                                    message:[NSString stringWithFormat:@"Remove \"%@\" from your offline downloads?", track.title]
                                                   delegate:self
                                          cancelButtonTitle:@"Cancel"
                                          otherButtonTitles:@"Remove", nil];
    alert.tag = 620;
    [alert show];
}

- (NSString *)formatDuration:(NSTimeInterval)duration {
    NSInteger seconds = (NSInteger)duration;
    return [NSString stringWithFormat:@"%d:%02d", (int)(seconds / 60), (int)(seconds % 60)];
}

#pragma mark - UITableViewDelegate

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 58.0f;
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.currentSegment != LTLibrarySegmentPlaylists) return NO;
    if (self.signedIn && indexPath.section == 0) return NO; // account rows aren't editable
    return YES;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.currentSegment != LTLibrarySegmentPlaylists) return UITableViewCellEditingStyleNone;
    if (self.signedIn && indexPath.section == 0) return UITableViewCellEditingStyleNone;
    if (indexPath.row >= (NSInteger)self.playlists.count) return UITableViewCellEditingStyleNone;
    return UITableViewCellEditingStyleDelete;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    if (self.signedIn && indexPath.section == 0) return;
    if (indexPath.row >= (NSInteger)self.playlists.count) return;
    LTLocalPlaylist *playlist = [self.playlists objectAtIndex:(NSUInteger)indexPath.row];
    self.ignorePlaylistChanges = YES;
    [[LTPlaylistStore sharedStore] deletePlaylist:playlist];
    [self.playlists removeObject:playlist];
    [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    self.ignorePlaylistChanges = NO;
    [self refreshEmptyState];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (self.currentSegment == LTLibrarySegmentPlaylists && self.signedIn && indexPath.section == 0) {
        if (self.accountError) {
            [self refreshAccountPlaylists];
            return;
        }
        if (self.accountLoading) return;
        if (indexPath.row >= (NSInteger)self.accountItems.count) return;
        LTBrowseItem *item = [self.accountItems objectAtIndex:(NSUInteger)indexPath.row];
        LTTrackListViewController *detail =
            [[LTTrackListViewController alloc] initWithBrowseId:item.browseId
                                                            kind:item.kind
                                                           title:item.title];
        [self.navigationController pushViewController:detail animated:YES];
        return;
    }

    NSArray *items = [self currentItems];
    if (indexPath.row >= (NSInteger)items.count) return;
    id item = [items objectAtIndex:(NSUInteger)indexPath.row];

    if (self.currentSegment == LTLibrarySegmentSongs) {
        [LTPlayerController sharedController].queueSourceName = @"Library";
        [[LTPlayerController sharedController] playQueue:[self currentItems] atIndex:indexPath.row];
        [(LTTabBarController *)self.tabBarController showNowPlaying];
    } else if (self.currentSegment == LTLibrarySegmentPlaylists && [item isKindOfClass:[LTLocalPlaylist class]]) {
        LTLocalPlaylistDetailViewController *detail = [[LTLocalPlaylistDetailViewController alloc] initWithPlaylist:item];
        [self.navigationController pushViewController:detail animated:YES];
    } else if ([item isKindOfClass:[NSDictionary class]]) {
        NSDictionary *bucket = item;
        NSArray *tracks = [bucket objectForKey:@"tracks"];
        NSString *name = [bucket objectForKey:@"name"];
        LTLibrarySongsViewController *detail = [[LTLibrarySongsViewController alloc] initWithTracks:tracks title:name];
        [self.navigationController pushViewController:detail animated:YES];
    }
}

@end