#import "LTSettingsViewController.h"
#import "LTPlaylistStore.h"
#import "LTPlayerController.h"
#import "LTP2PSync.h"
#import "LTDownloadQueueViewController.h"
#import "LTTransitionSettings.h"
#import "LTTransitionSpeedViewController.h"
#import "LTRecentsTileSizeViewController.h"
#import "LTOneHandedMode.h"
#import "LTAppIcon.h"
#import "LTOneHandedModeViewController.h"
#import "LTWebExporter.h"
#import "LTPlaylistSelectViewController.h"
#import "LTHomeViewController.h"
#import "LTDebugMenuViewController.h"
#import "LTiPodViewController.h"
#import "LTUpdater.h"
#import "LTYouTubeClient.h"
#import "LTAuth.h"
#import "LTSignInViewController.h"
#import "LTCookieSignInViewController.h"
#import "LTTheme.h"
#import "LTLog.h"

typedef NS_ENUM(NSInteger, LTSettingsSection) {
    LTSettingsSectionUpdates = 0,
    LTSettingsSectionAccount,
    LTSettingsSectionPlayback,
    LTSettingsSectionAppearance,
    LTSettingsSectionData,
    LTSettingsSectionAbout,
    LTSettingsSectionCredits,
    LTSettingsSectionBranding,
};

@interface LTSettingsViewController () <UITableViewDataSource, UITableViewDelegate, UIAlertViewDelegate, UIActionSheetDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISwitch *awakeSwitch;
@property (nonatomic, strong) UISwitch *kbpsSwitch;
@property (nonatomic, strong) UISwitch *bgSwitch;
@property (nonatomic, strong) UISwitch *animSwitch;
@property (nonatomic, strong) UISwitch *ipodSwitch;
@property (nonatomic, strong) UIAlertView *progressAlert;
@property (nonatomic, assign) BOOL refreshingMetadata;
@property (nonatomic, assign) NSInteger versionTapCount;
// Updater state (manual checks only — see LTUpdater).
@property (nonatomic, assign) BOOL checkingUpdate;
@property (nonatomic, assign) BOOL downloadingUpdate;
@property (nonatomic, assign) BOOL updateChecked;
@property (nonatomic, strong) NSDictionary *updateRelease;
@property (nonatomic, copy) NSString *updateVersion;
@property (nonatomic, copy) NSString *downloadedUpdatePath;
// Both storage figures come from walking the audio and artwork directories.
// -tableView:cellForRowAtIndexPath: used to do that for every row that appeared,
// re-statting the whole cache while scrolling, so they are measured once per
// appearance on a background queue instead.
@property (nonatomic, assign) BOOL storageStatsLoaded;
@property (nonatomic, assign) BOOL loadingStorageStats;
@property (nonatomic, assign) NSInteger cachedOfflineFiles;
@property (nonatomic, assign) double cachedArtworkMB;
@end

@implementation LTSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    if ([self respondsToSelector:@selector(setEdgesForExtendedLayout:)]) {
        self.edgesForExtendedLayout = UIRectEdgeNone;
    }
    self.title = @"Settings";
    self.view.backgroundColor = [LTTheme groupedBackground];

    CGRect bounds = self.view.bounds;
    self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, bounds.size.width, bounds.size.height)
                                                  style:UITableViewStyleGrouped];
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.backgroundColor = [LTTheme groupedBackground];
    [self.view addSubview:self.tableView];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(authDidChange:)
                                                 name:LTAuthDidChangeNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self applyTheme];
    [self.tableView reloadData];
    [self refreshStorageStats];
}

- (void)refreshStorageStats {
    if (self.loadingStorageStats) return;
    self.loadingStorageStats = YES;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSInteger files = [[LTPlaylistStore sharedStore] offlineFileCount];
        double mb = (double)[LTYouTubeClient diskArtworkCacheSize] / (1024.0 * 1024.0);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.loadingStorageStats = NO;
            self.storageStatsLoaded = YES;
            self.cachedOfflineFiles = files;
            self.cachedArtworkMB = mb;
            [self.tableView reloadData];
        });
    });
}

- (void)authDidChange:(NSNotification *)notification {
    [self.tableView reloadData];
}

- (void)confirmSignOut {
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Sign out"
                                                    message:@"Sign out of your Google account? Recommendations, library and history will stop updating."
                                                   delegate:self
                                          cancelButtonTitle:@"Cancel"
                                          otherButtonTitles:@"Sign Out", nil];
    alert.tag = 904;
    [alert show];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self applyTheme];
    [self.tableView reloadData];
}

- (void)applyTheme {
    self.view.backgroundColor = [LTTheme groupedBackground];
    self.tableView.backgroundColor = [LTTheme groupedBackground];
}

#pragma mark - Controls

- (UISwitch *)awakeSwitch {
    if (!_awakeSwitch) {
        _awakeSwitch = [[UISwitch alloc] init];
        _awakeSwitch.on = [[NSUserDefaults standardUserDefaults] boolForKey:@"LTKeepAwake"];
        [_awakeSwitch addTarget:self action:@selector(awakeChanged:) forControlEvents:UIControlEventValueChanged];
    }
    return _awakeSwitch;
}

- (void)awakeChanged:(id)sender {
    [[NSUserDefaults standardUserDefaults] setBool:self.awakeSwitch.on forKey:@"LTKeepAwake"];
    BOOL playing = [[LTPlayerController sharedController] isPlaying];
    [[UIApplication sharedApplication] setIdleTimerDisabled:(self.awakeSwitch.on && playing)];
}

- (UISwitch *)kbpsSwitch {
    if (!_kbpsSwitch) {
        _kbpsSwitch = [[UISwitch alloc] init];
        _kbpsSwitch.on = [[NSUserDefaults standardUserDefaults] boolForKey:@"LTShowKbpsCounter"];
        [_kbpsSwitch addTarget:self action:@selector(kbpsChanged:) forControlEvents:UIControlEventValueChanged];
    }
    return _kbpsSwitch;
}

- (void)kbpsChanged:(id)sender {
    [[NSUserDefaults standardUserDefaults] setBool:self.kbpsSwitch.on forKey:@"LTShowKbpsCounter"];
}

- (UISwitch *)bgSwitch {
    if (!_bgSwitch) {
        _bgSwitch = [[UISwitch alloc] init];
        _bgSwitch.on = [self artworkBackgroundEnabled];
        [_bgSwitch addTarget:self action:@selector(bgChanged:) forControlEvents:UIControlEventValueChanged];
    }
    return _bgSwitch;
}

- (void)bgChanged:(id)sender {
    [[NSUserDefaults standardUserDefaults] setBool:self.bgSwitch.on forKey:@"LTPlayerArtworkBackground"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (BOOL)artworkBackgroundEnabled {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:@"LTPlayerArtworkBackground"] == nil) {
        BOOL modern = ([UIDevice currentDevice].systemVersion.intValue >= 7);
        [defaults setBool:modern forKey:@"LTPlayerArtworkBackground"];
        [defaults synchronize];
        return modern;
    }
    return [defaults boolForKey:@"LTPlayerArtworkBackground"];
}

- (UISwitch *)animSwitch {
    if (!_animSwitch) {
        _animSwitch = [[UISwitch alloc] init];
        _animSwitch.on = [LTTransitionSettings animationsEnabled];
        [_animSwitch addTarget:self action:@selector(animChanged:) forControlEvents:UIControlEventValueChanged];
    }
    return _animSwitch;
}

- (void)animChanged:(id)sender {
    [LTTransitionSettings setAnimationsEnabled:self.animSwitch.on];
}

- (UISwitch *)ipodSwitch {
    if (!_ipodSwitch) {
        _ipodSwitch = [[UISwitch alloc] init];
        _ipodSwitch.on = [LTiPodViewController isEnabled];
        [_ipodSwitch addTarget:self action:@selector(ipodChanged:) forControlEvents:UIControlEventValueChanged];
    }
    return _ipodSwitch;
}

- (void)ipodChanged:(id)sender {
    [LTiPodViewController setEnabled:self.ipodSwitch.on];
    [LTiPodViewController applyiPodModeAnimated:YES];
}

#pragma mark - Storage

- (void)clearDownloadsTapped {
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Clear Offline Downloads"
                                                    message:@"This removes all downloaded tracks from the device. Streaming is not affected."
                                                   delegate:self
                                          cancelButtonTitle:@"Cancel"
                                          otherButtonTitles:@"Clear", nil];
    alert.tag = 900;
    [alert show];
}

- (void)clearOfflineFiles {
    LTPlaylistStore *store = [LTPlaylistStore sharedStore];
    NSError *error = nil;
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[store audioDirectory] error:&error];
    if ([files isKindOfClass:[NSArray class]]) {
        for (NSString *name in files) {
            if (![name hasSuffix:@".m4a"] && ![name hasSuffix:@".mp4"]) continue;
            NSString *path = [[store audioDirectory] stringByAppendingPathComponent:name];
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        }
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:LTPlaylistsDidChangeNotification object:store];
    self.cachedOfflineFiles = 0;
    [self.tableView reloadData];
}

- (void)clearArtworkCacheTapped {
    // Measuring the artwork directory here would stat every cached cover on the
    // main thread before the alert could even appear.
    double mb = self.storageStatsLoaded
        ? self.cachedArtworkMB
        : (double)[LTYouTubeClient diskArtworkCacheSize] / (1024.0 * 1024.0);
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Clear Cached Artwork"
                                                    message:[NSString stringWithFormat:
                                @"Remove the %.1f MB of cached album art and thumbnails? They are downloaded again when needed. Offline downloads and playlist covers are not affected.", mb]
                                                   delegate:self
                                          cancelButtonTitle:@"Cancel"
                                          otherButtonTitles:@"Clear", nil];
    alert.tag = 905;
    [alert show];
}

- (void)clearSearchHistoryTapped {
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Clear Search History"
                                                    message:@"Remove all saved search terms?"
                                                   delegate:self
                                          cancelButtonTitle:@"Cancel"
                                          otherButtonTitles:@"Clear", nil];
    alert.tag = 903;
    [alert show];
}

- (void)resetStatsTapped {
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Reset Listening Stats"
                                                    message:@"This clears the Stats screen, the most-played list, the listening counter, any stats synced from other devices, and listening history. This cannot be undone."
                                                   delegate:self
                                          cancelButtonTitle:@"Cancel"
                                          otherButtonTitles:@"Reset", nil];
    alert.tag = 902;
    [alert show];
}

- (void)resetListeningStats {
    LTPlaylistStore *store = [LTPlaylistStore sharedStore];
    [store clearListeningStats];
    [self.tableView reloadData];
}

#pragma mark - Metadata refresh

- (void)refreshMetadataTapped {
    if (self.refreshingMetadata) return;
    NSInteger count = [[LTPlaylistStore sharedStore] offlineTrackCount];
    if (!count) {
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"No Offline Songs"
                                                        message:@"Download some tracks to a playlist first."
                                                       delegate:nil
                                              cancelButtonTitle:@"OK"
                                              otherButtonTitles:nil];
        [alert show];
        return;
    }
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Refresh Metadata"
                                                    message:[NSString stringWithFormat:@"Re-fetch titles, artists, durations and full-res album art for %d offline track(s)?", (int)count]
                                                   delegate:self
                                          cancelButtonTitle:@"Cancel"
                                          otherButtonTitles:@"Refresh", nil];
    alert.tag = 901;
    [alert show];
}

- (void)startMetadataRefresh {
    self.refreshingMetadata = YES;
    LTPlaylistStore *store = [LTPlaylistStore sharedStore];
    NSInteger total = [store offlineTrackCount];
    __weak LTSettingsViewController *weakSelf = self;
    [store refreshOfflineMetadataWithProgress:^(NSInteger done, NSInteger totalItems) {
        LTSettingsViewController *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.progressAlert) return;
        strongSelf.progressAlert.message = [NSString stringWithFormat:@"Updating %d of %d…", (int)done, (int)totalItems];
    } completion:^(NSInteger updated, NSInteger failed) {
        LTSettingsViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.refreshingMetadata = NO;
        [strongSelf.progressAlert dismissWithClickedButtonIndex:0 animated:NO];
        strongSelf.progressAlert = nil;
        [strongSelf.tableView reloadData];
        NSString *message = failed
            ? [NSString stringWithFormat:@"Updated %d track(s). %d failed — try again later.", (int)updated, (int)failed]
            : [NSString stringWithFormat:@"Updated %d track(s), including full-res album art.", (int)updated];
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Refresh Complete"
                                                        message:message
                                                       delegate:nil
                                              cancelButtonTitle:@"OK"
                                              otherButtonTitles:nil];
        [alert show];
    }];
    UIAlertView *progress = [[UIAlertView alloc] initWithTitle:@"Refreshing"
                                                       message:[NSString stringWithFormat:@"Updating 0 of %d…", (int)total]
                                                      delegate:nil
                                             cancelButtonTitle:nil
                                             otherButtonTitles:nil];
    [progress show];
    self.progressAlert = progress;
}

#pragma mark - Web export

- (void)exportToWebTapped {
    LTPlaylistStore *store = [LTPlaylistStore sharedStore];
    NSInteger count = [store offlineFileCount];
    if (!count) {
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Nothing to Export"
                                                        message:@"Download some tracks to a playlist first, then you can create a Rein Mini instance."
                                                       delegate:nil
                                              cancelButtonTitle:@"OK"
                                              otherButtonTitles:nil];
        [alert show];
        return;
    }

    // Only offer playlists that actually contain downloaded tracks.
    NSMutableArray *eligible = [NSMutableArray array];
    for (LTLocalPlaylist *p in store.playlists) {
        BOOL hasDownloaded = NO;
        for (LTTrack *t in p.tracks) {
            if ([store isTrackDownloaded:t]) { hasDownloaded = YES; break; }
        }
        if (hasDownloaded) [eligible addObject:p];
    }
    if (!eligible.count) {
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Nothing to Export"
                                                        message:@"Download some tracks to a playlist first, then you can create a Rein Mini instance."
                                                       delegate:nil
                                              cancelButtonTitle:@"OK"
                                              otherButtonTitles:nil];
        [alert show];
        return;
    }

    __weak LTSettingsViewController *weakSelf = self;
    LTPlaylistSelectViewController *picker =
        [[LTPlaylistSelectViewController alloc] initWithPlaylists:eligible
                                                       completion:^(NSArray *identifiers, BOOL cancelled) {
        LTSettingsViewController *strongSelf = weakSelf;
        [strongSelf dismissViewControllerAnimated:YES completion:NULL];
        if (!strongSelf || cancelled) return;
        [strongSelf startWebExportWithPlaylists:identifiers];
    }];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:picker];
    [self presentViewController:nav animated:YES completion:NULL];
}

- (void)startWebExportWithPlaylists:(NSArray *)identifiers {
    UIAlertView *progress = [[UIAlertView alloc] initWithTitle:@"Creating Rein Mini"
                                                       message:@"Downloading missing artwork, then packaging your tracks…"
                                                      delegate:nil
                                             cancelButtonTitle:nil
                                             otherButtonTitles:nil];
    [progress show];
    self.progressAlert = progress;

    __weak LTSettingsViewController *weakSelf = self;
    [[LTWebExporter sharedExporter] exportWithSelectedPlaylists:identifiers
        completion:^(NSString *outDir, NSError *error) {
            LTSettingsViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.progressAlert dismissWithClickedButtonIndex:0 animated:NO];
            strongSelf.progressAlert = nil;
            NSString *title;
            NSString *message;
            if (outDir) {
                title = @"Rein Mini Created";
                message = [NSString stringWithFormat:@"Your Rein Mini was written to:\n%@\n\nCopy that folder to any computer or phone, then open its index.html to listen. It works fully offline.", outDir];
            } else {
                title = @"Create Failed";
                message = error.localizedDescription ?: @"Something went wrong while creating your Rein Mini.";
            }
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:title
                                                            message:message
                                                           delegate:nil
                                                  cancelButtonTitle:@"OK"
                                                  otherButtonTitles:nil];
            [alert show];
        }];
}

#pragma mark - UIAlertViewDelegate

- (void)presentIconPicker {
    UIAlertView *sheet = [[UIAlertView alloc] initWithTitle:@"App Icon"
                                                   message:@"Pick which icon revision shows on the Home Screen. iOS will confirm the change."
                                                  delegate:self
                                         cancelButtonTitle:@"Cancel"
                                         otherButtonTitles:@"Classic", @"Rounded", @"Modern", nil];
    sheet.tag = 950;
    [sheet show];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (alertView.tag == 950) {
        NSString *name = nil;
        if (buttonIndex == 1) name = [LTAppIcon classicIconName];
        else if (buttonIndex == 2) name = [LTAppIcon roundedIconName];
        else if (buttonIndex == 3) name = [LTAppIcon modernIconName];
        if (buttonIndex >= 1) {
            [LTAppIcon applyIconNamed:name];
            [self.tableView reloadData];
        }
        return;
    }
    if (alertView.tag == 955) {
        // Dark / Light / System -> LTThemeMode values 2 / 1 / 0.
        LTThemeMode mode = (buttonIndex == 1) ? LTThemeModeDark
                          : (buttonIndex == 2) ? LTThemeModeLight
                          : LTThemeModeSystem;
        [LTTheme setMode:mode];
        [self.tableView reloadData];
        return;
    }
    if (alertView.tag == 900 && buttonIndex == 1) {
        [self clearOfflineFiles];
    }
    if (alertView.tag == 901 && buttonIndex == 1) {
        [self startMetadataRefresh];
    }
    if (alertView.tag == 902 && buttonIndex == 1) {
        [self resetListeningStats];
    }
    if (alertView.tag == 903 && buttonIndex == 1) {
        [[LTPlaylistStore sharedStore] clearSearchHistory];
        [self.tableView reloadData];
    }
    if (alertView.tag == 904 && buttonIndex == 1) {
        [[LTAuth sharedAuth] signOut];
    }
    if (alertView.tag == 905 && buttonIndex == 1) {
        [LTYouTubeClient clearDiskArtworkCacheWithCompletion:^{
            [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:LTSettingsSectionData]
                         withRowAnimation:UITableViewRowAnimationNone];
            [self refreshStorageStats];
        }];
    }
    if (alertView.tag == 966 && buttonIndex == 1) {
        [self downloadUpdate];
        return;
    }
    if (alertView.tag == 967 && buttonIndex == 1) {
        if (![LTUpdater openDownloadedFileInFilza:self.downloadedUpdatePath]) {
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Filza Not Found"
                                                            message:[NSString stringWithFormat:
                                        @"The update is saved at:\n%@\n\nInstall it with Filza (AppSync Unified) or your usual IPA installer.",
                                        self.downloadedUpdatePath]
                                                           delegate:nil
                                                  cancelButtonTitle:@"OK"
                                                  otherButtonTitles:nil];
            [alert show];
        }
        return;
    }
}

- (NSString *)speedLabel {
    CGFloat multiplier = [LTTransitionSettings speedMultiplier];
    return [NSString stringWithFormat:@"%.1fx", multiplier];
}

- (NSString *)tileSizeLabel {
    CGFloat width = [[NSUserDefaults standardUserDefaults] floatForKey:@"LTHomeTileSize"];
    if (width < kHomeTileMinWidth || width > kHomeTileMaxWidth) {
        width = kHomeTileMinWidth;
    }
    return [NSString stringWithFormat:@"%.0f pt", width];
}

- (void)handleVersionTap {
    self.versionTapCount++;
    if (self.versionTapCount >= 5) {
        self.versionTapCount = 0;
        LTDebugMenuViewController *vc = [[LTDebugMenuViewController alloc] init];
        [self.navigationController pushViewController:vc animated:YES];
    }
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 8;
}

// The Theme row and the icon picker are appended after whatever the last
// appearance row happens to be, so they never shift the indices of the
// existing rows.
- (NSInteger)appearanceRowCount {
    NSInteger count = [LTOneHandedMode isSupported] ? 6 : 5;
    count += 1; // Theme
    if ([LTAppIcon isPickerSupported]) count += 1;
    return count;
}

// The Theme row sits just before the icon picker (which may be absent).
- (NSInteger)themeRowIndex {
    NSInteger row = [self appearanceRowCount] - 1;
    if ([LTAppIcon isPickerSupported]) row -= 1;
    return row;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case LTSettingsSectionUpdates: return @"Updates";
        case LTSettingsSectionAccount: return @"Account";
        case LTSettingsSectionPlayback: return @"Playback options";
        case LTSettingsSectionAppearance: return @"Appearance options";
        case LTSettingsSectionData: return @"Data management";
        case LTSettingsSectionAbout: return @"About";
        case LTSettingsSectionCredits: return @"Credits";
        case LTSettingsSectionBranding: return @"Branding";
        default: return @"";
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != LTSettingsSectionAccount) return nil;
    if ([[LTAuth sharedAuth] signedIn]) {
        NSString *name = [[LTAuth sharedAuth] accountName];
        return name.length ? [NSString stringWithFormat:@"Signed in as %@", name]
                           : @"Signed in to Google.";
    }
    return @"Sign in to personalize Home, your library and listening history.";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case LTSettingsSectionUpdates: return 1;
        case LTSettingsSectionAccount: return 3;
        case LTSettingsSectionPlayback: return 2;
        case LTSettingsSectionAppearance: return [self appearanceRowCount];
        case LTSettingsSectionData: return 9;
        case LTSettingsSectionAbout: return 2;
        case LTSettingsSectionCredits: return 5;
        case LTSettingsSectionBranding: return 2;
        default: return 0;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *CellId = @"LTSettingsCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:CellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:CellId];
    }
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    [LTTheme styleCell:cell];
    cell.textLabel.textColor = [LTTheme text];

    switch (indexPath.section) {
        case LTSettingsSectionUpdates: {
            // Manual updater: shows the running version, then either the
            // available update or the result of the last check.
            cell.textLabel.textColor = [LTTheme text];
            if (self.checkingUpdate) {
                cell.textLabel.text = @"Checking for Updates…";
                UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
                                                    initWithActivityIndicatorStyle:[LTTheme isDark]
                                                    ? UIActivityIndicatorViewStyleWhite
                                                    : UIActivityIndicatorViewStyleGray];
                [spinner startAnimating];
                cell.accessoryView = spinner;
            } else if (self.downloadingUpdate) {
                cell.textLabel.text = @"Downloading Update…";
                UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
                                                    initWithActivityIndicatorStyle:[LTTheme isDark]
                                                    ? UIActivityIndicatorViewStyleWhite
                                                    : UIActivityIndicatorViewStyleGray];
                [spinner startAnimating];
                cell.accessoryView = spinner;
            } else if (self.downloadedUpdatePath.length) {
                cell.textLabel.text = [NSString stringWithFormat:@"Install %@", self.updateVersion ?: @"Update"];
                cell.textLabel.textColor = [LTTheme accent];
                cell.detailTextLabel.text = @"Open in Filza";
            } else if (self.updateRelease && self.updateVersion.length) {
                cell.textLabel.text = [NSString stringWithFormat:@"Download %@", self.updateVersion];
                cell.textLabel.textColor = [LTTheme accent];
                cell.detailTextLabel.text = [LTUpdater isLegacyDevice] ? @"legacy IPA" : @"arm64 IPA";
            } else {
                cell.textLabel.text = @"Check for Updates";
                cell.detailTextLabel.text = self.updateChecked
                    ? [NSString stringWithFormat:@"Up to date (%@)", [LTUpdater currentVersion]]
                    : [NSString stringWithFormat:@"v%@", [LTUpdater currentVersion]];
            }
            cell.detailTextLabel.textColor = [LTTheme secondaryText];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.selectionStyle = UITableViewCellSelectionStyleBlue;
            break;
        }
        case LTSettingsSectionAccount: {
            // Two ways in, then the way out: the Google page in an in-app
            // browser, the SAPISID paste route, and Log Out below them.
            BOOL signedIn = [[LTAuth sharedAuth] signedIn];
            if (indexPath.row == 0) {
                cell.textLabel.text = @"Google Sign-In";
                // 32-bit hardware cannot run the page; the row stays so the
                // screen can explain and point at Cookies Sign-In.
                cell.detailTextLabel.text = [LTSignInViewController webSignInSupported]
                    ? @"Web page"
                    : @"Unavailable here";
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleBlue;
            } else if (indexPath.row == 1) {
                cell.textLabel.text = @"Cookies Sign-In";
                cell.detailTextLabel.text = @"Paste cookies";
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleBlue;
            } else {
                cell.textLabel.text = @"Log Out";
                cell.textLabel.textColor = signedIn ? [LTTheme accent] : [LTTheme secondaryText];
                cell.detailTextLabel.text = @"";
                cell.selectionStyle = signedIn ? UITableViewCellSelectionStyleBlue
                                               : UITableViewCellSelectionStyleNone;
            }
            cell.detailTextLabel.textColor = [LTTheme secondaryText];
            break;
        }
        case LTSettingsSectionPlayback: {
            if (indexPath.row == 0) {
                cell.textLabel.text = @"Keep Screen Awake";
                cell.accessoryView = [self awakeSwitch];
            } else {
                cell.textLabel.text = @"Show kbps Counter";
                cell.accessoryView = [self kbpsSwitch];
            }
            break;
        }
        case LTSettingsSectionAppearance: {
            if ([LTAppIcon isPickerSupported] && indexPath.row == [self appearanceRowCount] - 1) {
                cell.textLabel.text = @"App Icon";
                cell.detailTextLabel.text = [LTAppIcon currentIconLabel];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleBlue;
            } else if (indexPath.row == [self themeRowIndex]) {
                cell.textLabel.text = @"Theme";
                cell.detailTextLabel.text = [LTTheme labelForMode:[LTTheme mode]];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleBlue;
            } else if (indexPath.row == 0) {
                cell.textLabel.text = @"Album Art Background";
                cell.detailTextLabel.text = @"";
                cell.accessoryView = [self bgSwitch];
            } else if (indexPath.row == 1) {
                cell.textLabel.text = @"Enable Animations";
                cell.detailTextLabel.text = @"";
                cell.accessoryView = [self animSwitch];
            } else if (indexPath.row == 2) {
                cell.textLabel.text = @"Transition Speed";
                cell.detailTextLabel.text = [self speedLabel];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleBlue;
            } else if (indexPath.row == 3) {
                cell.textLabel.text = @"iPod Mode";
                cell.detailTextLabel.text = @"";
                cell.accessoryView = [self ipodSwitch];
            } else if (indexPath.row == 4) {
                cell.textLabel.text = @"Recents Tile Size";
                cell.detailTextLabel.text = [self tileSizeLabel];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleBlue;
            } else {
                cell.textLabel.text = @"One-Handed Mode";
                cell.detailTextLabel.text = [LTOneHandedMode currentLabel];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleBlue;
            }
            break;
        }
        case LTSettingsSectionData: {
            LTPlaylistStore *store = [LTPlaylistStore sharedStore];
            if (indexPath.row == 0) {
                cell.textLabel.text = @"Download Queue";
                NSInteger pending = [store pendingDownloadCount];
                cell.detailTextLabel.text = pending ? [NSString stringWithFormat:@"%d waiting", (int)pending] : @"Empty";
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                cell.selectionStyle = UITableViewCellSelectionStyleBlue;
            } else if (indexPath.row == 1) {
                cell.textLabel.text = @"Offline Downloads";
                cell.detailTextLabel.text = self.storageStatsLoaded
                    ? [NSString stringWithFormat:@"%d files", (int)self.cachedOfflineFiles]
                    : @"…";
            } else if (indexPath.row == 2) {
                cell.textLabel.text = @"Sync with Another Device";
                cell.detailTextLabel.text = @"";
                cell.selectionStyle = UITableViewCellSelectionStyleBlue;
            } else if (indexPath.row == 3) {
                cell.textLabel.text = @"Refresh Metadata & Artwork";
                cell.selectionStyle = UITableViewCellSelectionStyleBlue;
            } else if (indexPath.row == 4) {
                cell.textLabel.text = @"Create Rein Mini Instance (BETA)";
                cell.selectionStyle = UITableViewCellSelectionStyleBlue;
            } else if (indexPath.row == 5) {
                cell.textLabel.text = @"Clear Cached Artwork";
                cell.detailTextLabel.text = self.storageStatsLoaded
                    ? [NSString stringWithFormat:@"%.1f MB", self.cachedArtworkMB]
                    : @"…";
                cell.textLabel.textColor = [UIColor redColor];
                cell.selectionStyle = UITableViewCellSelectionStyleBlue;
            } else if (indexPath.row == 6) {
                cell.textLabel.text = @"Clear Offline Downloads";
                cell.textLabel.textColor = [UIColor redColor];
                cell.selectionStyle = UITableViewCellSelectionStyleBlue;
            } else if (indexPath.row == 7) {
                cell.textLabel.text = @"Reset Listening Stats";
                cell.textLabel.textColor = [UIColor redColor];
                cell.selectionStyle = UITableViewCellSelectionStyleBlue;
            } else {
                cell.textLabel.text = @"Clear Search History";
                cell.textLabel.textColor = [UIColor redColor];
                cell.selectionStyle = UITableViewCellSelectionStyleBlue;
            }
            break;
        }
        case LTSettingsSectionAbout: {
            if (indexPath.row == 0) {
                cell.textLabel.text = @"App";
                cell.detailTextLabel.text = @"Re:Cloud";
            } else {
                cell.textLabel.text = @"Version";
                NSString *version = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleVersion"];
                cell.detailTextLabel.text = version.length ? version : @"0.1.0";
            }
            cell.accessoryView = nil;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        }
        case LTSettingsSectionCredits: {
            static NSArray *names = nil;
            static NSArray *roles = nil;
            static dispatch_once_t once;
            dispatch_once(&once, ^{
                names = @[ @"Rein",
                           @"iReaching",
                           @"Discord: @ncros",
                           @"Github: @Recilia",
                           @"Email: ncros@duck.com" ];
                roles = @[ @"Developer", @"Developer", @"", @"", @"" ];
            });
            cell.textLabel.text = [names objectAtIndex:(NSUInteger)indexPath.row];
            cell.detailTextLabel.text = [roles objectAtIndex:(NSUInteger)indexPath.row];
            cell.accessoryView = nil;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.detailTextLabel.textColor = [LTTheme secondaryText];
            break;
        }
        case LTSettingsSectionBranding: {
            if (indexPath.row == 0) {
                cell.textLabel.text = @"Exelorent";
                cell.detailTextLabel.text = @"Branding";
            } else {
                cell.textLabel.text = @"Discord: @s.tyx";
                cell.detailTextLabel.text = @"";
            }
            cell.accessoryView = nil;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.detailTextLabel.textColor = [LTTheme secondaryText];
            break;
        }
        default:
            break;
    }
    return cell;
}

#pragma mark - Updater (manual only)

// One row, three states: check → download → hand off to Filza. Nothing here
// runs automatically; GitHub is only contacted after an explicit tap.
- (void)handleUpdateRowTap {
    if (self.checkingUpdate || self.downloadingUpdate) return;

    if (self.downloadedUpdatePath.length) {
        if (![LTUpdater openDownloadedFileInFilza:self.downloadedUpdatePath]) {
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Update Downloaded"
                                                            message:[NSString stringWithFormat:
                                @"Saved to:\n%@\n\nOpen it in Filza (with AppSync Unified) or install it with your usual IPA tool to update.",
                                self.downloadedUpdatePath]
                                                           delegate:nil
                                                  cancelButtonTitle:@"OK"
                                                  otherButtonTitles:nil];
            [alert show];
        }
        return;
    }

    if (self.updateRelease && self.updateVersion.length) {
        [self downloadUpdate];
        return;
    }

    [self checkForUpdates];
}

- (void)checkForUpdates {
    self.checkingUpdate = YES;
    self.updateChecked = NO;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:LTSettingsSectionUpdates]
                  withRowAnimation:UITableViewRowAnimationNone];

    __weak LTSettingsViewController *weakSelf = self;
    [LTUpdater checkForUpdateWithCompletion:^(NSDictionary *release, NSString *latestVersion, NSError *error) {
        LTSettingsViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.checkingUpdate = NO;
        strongSelf.updateChecked = YES;
        if (error) {
            [strongSelf.tableView reloadSections:[NSIndexSet indexSetWithIndex:LTSettingsSectionUpdates]
                             withRowAnimation:UITableViewRowAnimationNone];
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Couldn't Check"
                                                            message:error.localizedDescription ?: @"GitHub is unreachable right now."
                                                           delegate:nil
                                                  cancelButtonTitle:@"OK"
                                                  otherButtonTitles:nil];
            [alert show];
            return;
        }
        if ([LTUpdater isReleaseNewer:release]) {
            NSDictionary *asset = [LTUpdater assetForRelease:release];
            if (!asset) {
                strongSelf.updateRelease = nil;
                strongSelf.updateVersion = nil;
                [strongSelf.tableView reloadSections:[NSIndexSet indexSetWithIndex:LTSettingsSectionUpdates]
                                 withRowAnimation:UITableViewRowAnimationNone];
                UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"No IPA for This Device"
                                                                message:[NSString stringWithFormat:
                                            @"%@ does not include an IPA built for this device yet.",
                                            latestVersion.length ? latestVersion : @"This release"]
                                                               delegate:nil
                                                      cancelButtonTitle:@"OK"
                                                      otherButtonTitles:nil];
                [alert show];
                return;
            }
            strongSelf.updateRelease = release;
            strongSelf.updateVersion = latestVersion;
            [strongSelf.tableView reloadSections:[NSIndexSet indexSetWithIndex:LTSettingsSectionUpdates]
                             withRowAnimation:UITableViewRowAnimationNone];
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:
                                      [NSString stringWithFormat:@"Update %@ available", latestVersion]
                                                            message:@"Download the IPA now? It is saved to the app's Documents folder."
                                                           delegate:self
                                                  cancelButtonTitle:@"Not Now"
                                                  otherButtonTitles:@"Download", nil];
            alert.tag = 966;
            [alert show];
        } else {
            strongSelf.updateRelease = nil;
            strongSelf.updateVersion = nil;
            [strongSelf.tableView reloadSections:[NSIndexSet indexSetWithIndex:LTSettingsSectionUpdates]
                             withRowAnimation:UITableViewRowAnimationNone];
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Up to Date"
                                                            message:[NSString stringWithFormat:
                                        @"You're on the latest version (%@).", [LTUpdater currentVersion]]
                                                           delegate:nil
                                                  cancelButtonTitle:@"OK"
                                                  otherButtonTitles:nil];
            [alert show];
        }
    }];
}

- (void)downloadUpdate {
    NSDictionary *asset = [LTUpdater assetForRelease:self.updateRelease];
    if (!asset) return;
    self.downloadingUpdate = YES;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:LTSettingsSectionUpdates]
                  withRowAnimation:UITableViewRowAnimationNone];

    __weak LTSettingsViewController *weakSelf = self;
    [LTUpdater downloadAsset:asset completion:^(NSString *path, NSError *error) {
        LTSettingsViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.downloadingUpdate = NO;
        if (path.length) {
            strongSelf.downloadedUpdatePath = path;
            [strongSelf.tableView reloadSections:[NSIndexSet indexSetWithIndex:LTSettingsSectionUpdates]
                             withRowAnimation:UITableViewRowAnimationNone];
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Update Downloaded"
                                                            message:@"Open it in Filza (AppSync Unified) or your IPA installer to update. It is also saved in the app's Documents folder."
                                                           delegate:self
                                                  cancelButtonTitle:@"Later"
                                                  otherButtonTitles:@"Open in Filza", nil];
            alert.tag = 967;
            [alert show];
        } else {
            [strongSelf.tableView reloadSections:[NSIndexSet indexSetWithIndex:LTSettingsSectionUpdates]
                             withRowAnimation:UITableViewRowAnimationNone];
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Download Failed"
                                                            message:error.localizedDescription ?: @"Try again in a moment."
                                                           delegate:nil
                                                  cancelButtonTitle:@"OK"
                                                  otherButtonTitles:nil];
            [alert show];
        }
    }];
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == LTSettingsSectionUpdates) {
        [self handleUpdateRowTap];
        return;
    }
    if (indexPath.section == LTSettingsSectionAbout && indexPath.row == 1) {
        [self handleVersionTap];
        return;
    }
    if (indexPath.section == LTSettingsSectionAccount) {
        if (indexPath.row == 0) {
            LTSignInViewController *vc = [[LTSignInViewController alloc] init];
            [self.navigationController pushViewController:vc animated:YES];
        } else if (indexPath.row == 1) {
            LTCookieSignInViewController *vc = [[LTCookieSignInViewController alloc] init];
            [self.navigationController pushViewController:vc animated:YES];
        } else if ([[LTAuth sharedAuth] signedIn]) {
            [self confirmSignOut];
        }
        return;
    }
    if (indexPath.section == LTSettingsSectionAppearance) {
        if ([LTAppIcon isPickerSupported] && indexPath.row == [self appearanceRowCount] - 1) {
            [self presentIconPicker];
        } else if (indexPath.row == [self themeRowIndex]) {
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Theme"
                                                            message:@"Dark is the YouTube-style black and red theme. System follows the OS on iOS 13+ and is light on older devices."
                                                           delegate:self
                                                  cancelButtonTitle:@"Cancel"
                                                  otherButtonTitles:@"Dark", @"Light", @"System", nil];
            alert.tag = 955;
            [alert show];
        } else if (indexPath.row == 2) {
            LTTransitionSpeedViewController *vc = [[LTTransitionSpeedViewController alloc] init];
            [self.navigationController pushViewController:vc animated:YES];
        } else if (indexPath.row == 4) {
            LTRecentsTileSizeViewController *vc = [[LTRecentsTileSizeViewController alloc] init];
            [self.navigationController pushViewController:vc animated:YES];
        } else if (indexPath.row == 5 && [LTOneHandedMode isSupported]) {
            LTOneHandedModeViewController *vc = [[LTOneHandedModeViewController alloc] init];
            [self.navigationController pushViewController:vc animated:YES];
        }
        return;
    }
    if (indexPath.section == LTSettingsSectionData) {
        if (indexPath.row == 0) {
            LTDownloadQueueViewController *queue = [[LTDownloadQueueViewController alloc] init];
            [self.navigationController pushViewController:queue animated:YES];
        } else if (indexPath.row == 2) {
            [LTP2PSync beginFromViewController:self];
        } else if (indexPath.row == 3) {
            [self refreshMetadataTapped];
        } else if (indexPath.row == 4) {
            [self exportToWebTapped];
        } else if (indexPath.row == 5) {
            [self clearArtworkCacheTapped];
        } else if (indexPath.row == 6) {
            [self clearDownloadsTapped];
        } else if (indexPath.row == 7) {
            [self resetStatsTapped];
        } else if (indexPath.row == 8) {
            [self clearSearchHistoryTapped];
        }
        return;
    }
}

@end
