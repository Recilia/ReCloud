#import "LTSignInViewController.h"
#import "LTAuth.h"
#import "LTYouTubeClient.h"
#import "LTLog.h"
#import "LTTheme.h"

// Google account sign-in via a pasted SAPISID cookie. The in-app web login
// (UIWebView) was removed: Google's login page crashes the legacy WebKit
// engine on old armv7 devices mid-render, and the crash is native and
// uncatchable. Pasting the SAPISID value (or the full Cookie header) from a
// desktop browser signed into YouTube Music always works and provides the
// exact same credentials.

@interface LTSignInViewController () <UIAlertViewDelegate, UITextFieldDelegate>
@property (nonatomic, assign) BOOL pasteOnly;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, strong) UIButton *pasteButton;
@property (nonatomic, strong) UIAlertView *pasteAlert;
@end

@implementation LTSignInViewController

- (id)initWithPasteOnly:(BOOL)pasteOnly {
    self = [super init];
    if (self) _pasteOnly = pasteOnly;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Sign in";
    self.view.backgroundColor = [LTTheme background];

    UIBarButtonItem *pasteItem = [[UIBarButtonItem alloc] initWithTitle:@"Paste cookie"
                                                                 style:UIBarButtonItemStyleBordered
                                                                target:self
                                                                action:@selector(pasteTapped:)];
    self.navigationItem.leftBarButtonItem = pasteItem;

    UIBarButtonItem *doneItem = [[UIBarButtonItem alloc] initWithTitle:@"Check"
                                                                style:UIBarButtonItemStyleDone
                                                               target:self
                                                               action:@selector(checkTapped:)];
    self.navigationItem.rightBarButtonItem = doneItem;

    CGFloat width = self.view.bounds.size.width;

    self.hintLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, width - 24, 62)];
    self.hintLabel.font = [UIFont systemFontOfSize:12];
    self.hintLabel.textColor = [LTTheme secondaryText];
    self.hintLabel.numberOfLines = 4;
    self.hintLabel.textAlignment = NSTextAlignmentCenter;
    self.hintLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
    self.hintLabel.text = @"Sign in to music.youtube.com in a desktop browser, then\ncopy the whole Cookie header (DevTools → Network → any request →\nRequest Headers → Cookie) and paste it here. Include\n__Secure-3PAPISID if it is listed.";
    [self.view addSubview:self.hintLabel];

    if (self.pasteOnly) {
        [self pasteTapped:nil];
        return;
    }

    self.pasteButton = [self actionButtonWithTitle:@"Paste SAPISID cookie"
                                                 y:CGRectGetMaxY(self.hintLabel.frame) + 8];
    [self.pasteButton addTarget:self
                         action:@selector(pasteTapped:)
               forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.pasteButton];
}

- (UIButton *)actionButtonWithTitle:(NSString *)title y:(CGFloat)y {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.frame = CGRectMake(16, y, self.view.bounds.size.width - 32, 44);
    button.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
    button.layer.cornerRadius = 8;
    button.layer.borderWidth = 1;
    button.layer.borderColor = [LTTheme separator].CGColor;
    button.backgroundColor = [LTTheme fill];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[LTTheme text] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:15];
    return button;
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation {
    return YES;
}

#pragma mark - Capture

- (BOOL)tryAdoptCookies {
    BOOL adopted = [[LTAuth sharedAuth] adoptCookiesFromSharedStorage];
    BOOL signedIn = [[LTAuth sharedAuth] signedIn];
    if (signedIn) {
        LTLog(@"AUTH captured cookies from shared storage");
        [self finishSignIn];
    } else if (adopted) {
        // Cookies exist but no SAPISID — the user isn't logged in yet.
    }
    return signedIn;
}

- (void)finishSignIn {
    // The account menu only supplies a display name; it is not a reliable
    // sign-in test (YouTube can report logged_in=0 there while the library
    // endpoints work). The first library page is the real check: a guest gets
    // a "Sign in" card, an authenticated account gets its library.
    self.title = @"Checking…";
    self.navigationItem.rightBarButtonItem.enabled = NO;

    __weak LTSignInViewController *weakSelf = self;
    [[LTYouTubeClient sharedClient] checkLibraryAuthWithCompletion:^(BOOL signedIn, NSError *error) {
        LTSignInViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.title = @"Sign in";
        strongSelf.navigationItem.rightBarButtonItem.enabled = YES;

        if (signedIn) {
            LTLog(@"AUTH verified signed in");
            // Name is cosmetic: fetch it without delaying the transition.
            [[LTYouTubeClient sharedClient] fetchAccountNameWithCompletion:^(NSString *name, NSError *nameError) {
                if (name.length) [[LTAuth sharedAuth] updateAccountName:name];
            }];
            [strongSelf.navigationController popViewControllerAnimated:YES];
            return;
        }

        LTLog(@"AUTH verification failed: %@", error);
        BOOL authRejected = (error.code == 401 || error.code == 403);
        if (authRejected) [[LTAuth sharedAuth] signOut];

        NSString *message;
        if (authRejected) {
            message = @"YouTube Music still sees this request as signed out.\n\nMake sure you copied the cookie from a tab that is open on music.youtube.com while signed in, include the whole Cookie header (SID, HSID, SSID, APISID, SAPISID and __Secure-3PAPISID), and capture it while this iPhone is on the same Wi-Fi network as the browser (Google ties the session to the originating network).";
        } else {
            message = @"Couldn't reach YouTube Music to verify the cookie. Check the connection and tap Check again.";
            if (error.localizedDescription.length) {
                message = [message stringByAppendingFormat:@"\n\n%@", error.localizedDescription];
            }
        }
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Sign-in failed"
                                                        message:message
                                                       delegate:nil
                                              cancelButtonTitle:@"OK"
                                              otherButtonTitles:nil];
        [alert show];
    }];
}

#pragma mark - Buttons

- (void)checkTapped:(id)sender {
    if (![self tryAdoptCookies]) {
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Not signed in yet"
                                                        message:@"No Google account cookie found. Paste the SAPISID cookie from a desktop browser signed into YouTube Music."
                                                       delegate:nil
                                              cancelButtonTitle:@"OK"
                                              otherButtonTitles:nil];
        [alert show];
    }
}

- (void)pasteTapped:(id)sender {
    if (!self.pasteAlert) {
        self.pasteAlert = [[UIAlertView alloc] initWithTitle:@"Paste credentials"
                                                     message:@"Paste the whole Cookie header from a desktop browser tab that is open on music.youtube.com while signed in. A bare __Secure-3PAPISID / SAPISID value also works."
                                                    delegate:self
                                           cancelButtonTitle:@"Cancel"
                                           otherButtonTitles:@"Save", nil];
        self.pasteAlert.alertViewStyle = UIAlertViewStylePlainTextInput;
        UITextField *field = [self.pasteAlert textFieldAtIndex:0];
        field.secureTextEntry = YES;
        field.delegate = self;
        field.placeholder = @"SAPISID=... or bare token";
    }
    [self.pasteAlert show];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (alertView != self.pasteAlert || buttonIndex != 1) return;
    UITextField *field = [alertView textFieldAtIndex:0];
    NSString *text = [field.text stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length) return;
    [[LTAuth sharedAuth] setCredentialsWithCookieHeader:text accountName:nil];
    [self finishSignIn];
}

@end
