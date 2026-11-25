#import "LTSongMenu.h"
#import "LTToast.h"
#import "LTPlaylistStore.h"
#import "LTPlaylistPicker.h"
#import "LTPlayerController.h"
#import "LTModel.h"

#define kLTSongMenuSheetTag 9001

@interface LTSongMenu ()
@property (nonatomic, weak) UIViewController *presentingController;
@property (nonatomic, strong) LTTrack *pendingTrack;
@end

@implementation LTSongMenu

- (void)presentForTrack:(LTTrack *)track fromViewController:(UIViewController *)viewController {
    self.presentingController = viewController;
    self.pendingTrack = track;
    NSString *lastOption = [[LTPlaylistStore sharedStore] isTrackDownloaded:track] ? @"Remove Download" : @"Add to Download Queue";
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:track.title
                                                       delegate:self
                                              cancelButtonTitle:@"Cancel"
                                         destructiveButtonTitle:nil
                                              otherButtonTitles:@"Add to Queue", @"Add to Playlist...", lastOption, nil];
    sheet.tag = kLTSongMenuSheetTag;
    [sheet showInView:viewController.view];
}

- (void)showPlaylistPickerForTrack:(LTTrack *)track {
    [LTPlaylistPicker presentFromViewController:self.presentingController
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

- (void)actionSheet:(UIActionSheet *)actionSheet clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (actionSheet.tag != kLTSongMenuSheetTag) return;
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
            [[LTPlaylistStore sharedStore] enqueueDownloads:@[track]];
            [self showToast:@"Added to download queue"];
        }
    }
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (alertView.tag == 200 && buttonIndex == 1) {
        NSString *name = [[alertView textFieldAtIndex:0] text];
        LTLocalPlaylist *playlist = [[LTPlaylistStore sharedStore] createPlaylistWithName:name];
        if (playlist && self.pendingTrack) {
            [[LTPlaylistStore sharedStore] addTrack:self.pendingTrack toPlaylist:playlist];
            [self showToast:[NSString stringWithFormat:@"Added to %@", playlist.name]];
        }
    }
    self.pendingTrack = nil;
}

- (void)showToast:(NSString *)text {
    UIViewController *vc = self.presentingController;
    if (!vc) return;
    [LTToast showText:text inView:vc.view];
}

@end
