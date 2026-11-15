#import "LTSignInViewController.h"
#import "LTAuth.h"
#import "LTYouTubeClient.h"
#import "LTLog.h"
#import "LTTheme.h"

// Google account sign-in inside a UIWebView. On legacy iOS the UIWebView
// shares its cookies with NSHTTPCookieStorage, so once the user is logged
// in the SAPISID cookie we need for authenticated requests is readable.
// A manual cookie paste is offered as a guaranteed fallback for devices
// where Google's login page refuses to cooperate.

@interface LTSignInViewController () <UIWebViewDelegate, UIAlertViewDelegate, UITextFieldDelegate>
@property (nonatomic, assign) BOOL pasteOnly;
@property (nonatomic, strong) UIWebView *webView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UILabel *hintLabel;
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
    CGFloat top = 0.0f;

    self.hintLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, top + 8, width - 24, 34)];
    self.hintLabel.font = [UIFont systemFontOfSize:12];
    self.hintLabel.textColor = [LTTheme secondaryText];
    self.hintLabel.numberOfLines = 2;
    self.hintLabel.textAlignment = NSTextAlignmentCenter;
    self.hintLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
    [self.view addSubview:self.hintLabel];
    top += CGRectGetMaxY(self.hintLabel.frame) + 4;

    if (self.pasteOnly) {
        self.hintLabel.text = @"Paste the SAPISID value (or the full Cookie header)\nfrom a browser signed into YouTube Music.";
        [self pasteTapped:nil];
        return;
    }

    self.webView = [[UIWebView alloc] initWithFrame:CGRectMake(0, top, width, self.view.bounds.size.height - top)];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.backgroundColor = [UIColor whiteColor];
    self.webView.delegate = self;
    self.webView.scalesPageToFit = NO;
    [self.view addSubview:self.webView];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    self.spinner.hidesWhenStopped = YES;
    [self.view addSubview:self.spinner];
    [self.spinner startAnimating];

    NSURL *url = [NSURL URLWithString:@"https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fmusic.youtube.com%2F&hl=en"];
    NSURLRequest *request = [NSURLRequest requestWithURL:url
                                             cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                         timeoutInterval:60.0];
    [self.webView loadRequest:request];
}

- (void)layoutSubviewsInRotation {
    // handled by autoresizing
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

#pragma mark - UIWebViewDelegate

- (void)webViewDidFinishLoad:(UIWebView *)webView {
    [self.spinner stopAnimating];
    NSString *host = webView.request.URL.host ?: @"";
    if ([host hasSuffix:@".google.com"] || [host hasSuffix:@"youtube.com"] || host.length == 0) {
        [self tryAdoptCookies];
    }
}

- (void)webView:(UIWebView *)webView didFailLoadWithError:(NSError *)error {
    [self.spinner stopAnimating];
    if (error.code == NSURLErrorCancelled) return;
    LTLog(@"AUTH webview load failed: %@", error);
}

#pragma mark - Buttons

- (void)checkTapped:(id)sender {
    if (![self tryAdoptCookies]) {
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Not signed in yet"
                                                        message:@"No Google account cookie found. Sign in in the page above, or use Paste cookie to enter SAPISID manually."
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
