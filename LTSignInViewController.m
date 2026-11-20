#import "LTSignInViewController.h"
#import "LTAuth.h"
#import "LTYouTubeClient.h"
#import "LTLog.h"
#import "LTTheme.h"

// Two ways to sign in, picked by what the device can survive:
//
//   Google web sign-in — the classic accounts.google.com login page inside a
//   UIWebView. On legacy iOS the web view shares its cookies with
//   NSHTTPCookieStorage, so the SAPISID cookie the app needs lands exactly
//   where LTAuth reads it and no copying is involved. Google's page is heavy
//   modern JavaScript and 32-bit armv7 devices crash natively inside the old
//   WebKit engine while rendering it (uncatchable), so this route is only
//   offered on 64-bit devices and is never loaded on its own.
//
//   Cookie sign-in — paste the SAPISID value (or a full Cookie header) from a
//   desktop browser signed into YouTube Music. Needs no WebKit at all, so it
//   is the method for older devices and the fallback everywhere else.

static NSString *const LTSignInWebUserAgent =
    @"Mozilla/5.0 (Linux; U; Android 2.3.7; en-us) AppleWebKit/533.1 "
     "(KHTML, like Gecko) Version/4.0 Mobile Safari/533.1";

static NSString *const LTSignInWebURL =
    @"https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fmusic.youtube.com%2F&hl=en";

@interface LTSignInViewController () <UIWebViewDelegate, UIAlertViewDelegate, UITextFieldDelegate>
@property (nonatomic, assign) BOOL pasteOnly;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, strong) UIButton *webButton;
@property (nonatomic, strong) UIButton *pasteButton;
@property (nonatomic, strong) UIWebView *webView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIAlertView *pasteAlert;
// YES once the sign-in finished, so the web view's repeated load callbacks
// cannot pop the screen twice.
@property (nonatomic, assign) BOOL finished;
@end

@implementation LTSignInViewController

// 64-bit only: see the WebKit crash note above. A class method so the rest of
// the screen can ask which routes exist.
+ (BOOL)webSignInAvailable {
    return NSClassFromString(@"UIWebView") != nil && sizeof(void *) == 8;
}

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
    // Paste stays reachable in every mode, including while the Google page is
    // open, since that is the only route on older devices.
    UIBarButtonItem *pasteItem = [[UIBarButtonItem alloc] initWithTitle:@"Paste"
                                                                 style:UIBarButtonItemStyleBordered
                                                                target:self
                                                                action:@selector(pasteTapped:)];
    self.navigationItem.rightBarButtonItems = @[doneItem, pasteItem];

    // Leave the bar's left slot to the system back button: the screen is
    // pushed from Settings. A navigation root has nothing to pop to, so offer
    // a Close button there.
    if (!self.navigationController || self.navigationController.viewControllers.count <= 1) {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Close"
                                                                                 style:UIBarButtonItemStyleBordered
                                                                                target:self
                                                                                action:@selector(closeTapped:)];
    }

    CGFloat width = self.view.bounds.size.width;
    BOOL webAvailable = [[self class] webSignInAvailable];

    self.hintLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, width - 24, webAvailable ? 62 : 84)];
    self.hintLabel.font = [UIFont systemFontOfSize:12];
    self.hintLabel.textColor = [LTTheme secondaryText];
    self.hintLabel.numberOfLines = 5;
    self.hintLabel.textAlignment = NSTextAlignmentCenter;
    self.hintLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
    self.hintLabel.text = webAvailable
        ? @"Sign in with your Google account below, or paste the SAPISID\ncookie from a desktop browser signed into YouTube Music.\n(DevTools → Application → Cookies) A full Cookie header works too."
        : @"Paste the SAPISID cookie value from a desktop browser signed\ninto YouTube Music. (DevTools → Application → Cookies)\nA full Cookie header works too.\n\nIn-app Google sign-in is not available on this device.";
    [self.view addSubview:self.hintLabel];

    if (self.pasteOnly) {
        [self pasteTapped:nil];
        return;
    }

    CGFloat buttonY = CGRectGetMaxY(self.hintLabel.frame) + 8;
    if (webAvailable) {
        self.webButton = [self actionButtonWithTitle:@"Sign in with Google" y:buttonY];
        [self.webButton addTarget:self
                           action:@selector(openWebSignInTapped:)
                 forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:self.webButton];

        self.pasteButton = [self actionButtonWithTitle:@"Use a cookie instead"
                                                     y:buttonY + CGRectGetHeight(self.webButton.frame) + 10];
    } else {
        self.pasteButton = [self actionButtonWithTitle:@"Paste SAPISID cookie" y:buttonY];
    }
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

#pragma mark - Google web sign-in

- (void)openWebSignInTapped:(id)sender {
    [self.webButton removeFromSuperview];
    self.webButton = nil;
    [self.pasteButton removeFromSuperview];
    self.pasteButton = nil;

    CGFloat width = self.view.bounds.size.width;
    CGFloat top = CGRectGetMaxY(self.hintLabel.frame) + 4;
    self.hintLabel.text = @"Loading Google's sign-in page…";

    self.webView = [[UIWebView alloc] initWithFrame:CGRectMake(0, top, width, self.view.bounds.size.height - top)];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.backgroundColor = [UIColor whiteColor];
    self.webView.delegate = self;
    self.webView.scalesPageToFit = YES;
    [self.view addSubview:self.webView];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    self.spinner.hidesWhenStopped = YES;
    self.spinner.center = self.webView.center;
    self.spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                                    UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [self.view addSubview:self.spinner];
    [self.spinner startAnimating];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:LTSignInWebURL]
                                                          cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                      timeoutInterval:60.0];
    // Pretend to be a very old Android browser so Google serves its
    // lightweight login page instead of the modern one that crashes the legacy
    // WebKit engine mid-render.
    [request setValue:LTSignInWebUserAgent forHTTPHeaderField:@"User-Agent"];
    [self.webView loadRequest:request];
}

- (void)webViewDidStartLoad:(UIWebView *)webView {
    [self.spinner startAnimating];
}

- (void)webViewDidFinishLoad:(UIWebView *)webView {
    [self.spinner stopAnimating];
    self.hintLabel.text = @"Signed in? Tap Check, or paste a cookie instead.";
    // Every page that loads is a chance that the login just completed: the
    // cookies are shared with NSHTTPCookieStorage, so look for SAPISID.
    NSString *host = webView.request.URL.host ?: @"";
    if ([host hasSuffix:@"google.com"] || [host hasSuffix:@"youtube.com"]) {
        [self tryAdoptCookies];
    }
}

- (void)webView:(UIWebView *)webView didFailLoadWithError:(NSError *)error {
    [self.spinner stopAnimating];
    if (error.code == NSURLErrorCancelled) return;
    LTLog(@"AUTH webview load failed: %@", error);
    self.hintLabel.text = @"Google's sign-in page could not be loaded.\nUse Paste to enter the cookie instead.";
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
    if (self.finished) return;
    self.finished = YES;
    [self.webView stopLoading];
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
                                                        message:[[self class] webSignInAvailable]
                                                              ? @"No Google account cookie found yet. Finish signing in on the page, or paste the SAPISID cookie from a desktop browser signed into YouTube Music."
                                                              : @"No Google account cookie found. Paste the SAPISID cookie from a desktop browser signed into YouTube Music."
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
