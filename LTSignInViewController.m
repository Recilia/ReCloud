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

    UIBarButtonItem *doneItem = [[UIBarButtonItem alloc] initWithTitle:@"Check"
                                                                style:UIBarButtonItemStyleDone
                                                               target:self
                                                               action:@selector(checkTapped:)];

    // Leave the bar's left slot to the system back button: the screen is
    // pushed from Settings and pasting has its own button below.
    if (self.pasteOnly) {
        UIBarButtonItem *pasteItem = [[UIBarButtonItem alloc] initWithTitle:@"Paste"
                                                                     style:UIBarButtonItemStyleBordered
                                                                    target:self
                                                                    action:@selector(pasteTapped:)];
        self.navigationItem.rightBarButtonItems = @[doneItem, pasteItem];
    } else {
        self.navigationItem.rightBarButtonItem = doneItem;
    }
    // A navigation root has nothing to pop to, so offer a Close button there.
    if (!self.navigationController || self.navigationController.viewControllers.count <= 1) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Close"
                                                                                 style:UIBarButtonItemStyleBordered
                                                                                target:self
                                                                                action:@selector(closeTapped:)];
    }

    CGFloat width = self.view.bounds.size.width;

    self.hintLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, width - 24, 62)];
    self.hintLabel.font = [UIFont systemFontOfSize:12];
    self.hintLabel.textColor = [LTTheme secondaryText];
    self.hintLabel.numberOfLines = 4;
    self.hintLabel.textAlignment = NSTextAlignmentCenter;
    self.hintLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
    self.hintLabel.text = @"Sign in to YouTube Music in a desktop browser, then\ncopy the SAPISID cookie value (DevTools → Application →\nCookies) and paste it here. A full Cookie header works too.";
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
    [[LTYouTubeClient sharedClient] fetchAccountNameWithCompletion:^(NSString *name, NSError *error) {
        if (name.length) {
            [[LTAuth sharedAuth] setCredentialsWithCookieHeader:[[LTAuth sharedAuth] cookieHeader]
                                                    accountName:name];
        }
        [self.navigationController popViewControllerAnimated:YES];
    }];
}

#pragma mark - Buttons

- (void)closeTapped:(id)sender {
    if (self.navigationController.viewControllers.count > 1) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:NULL];
    }
}

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
                                                     message:@"Paste the SAPISID value or the full Cookie header copied from a desktop browser signed into YouTube Music."
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
