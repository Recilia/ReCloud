#import "LTSignInViewController.h"
#import "LTAuth.h"
#import "LTYouTubeClient.h"
#import "LTLog.h"
#import "LTTheme.h"
#include <dlfcn.h>

// How the Google web sign-in is hosted, chosen by OS version:
//
//   WKWebView (iOS 11+) — UIWebView can render Google's login page blank on
//   modern iOS, so newer systems use WKWebView. Its cookies live in
//   WKWebsiteDataStore rather than NSHTTPCookieStorage, so they are read back
//   through WKHTTPCookieStore (iOS 11) and handed to LTAuth as a Cookie
//   header. WebKit is not linked at all: the iOS 9.3 armv7 SDK ships it only as
//   a private framework, so it is dlopen'd on demand, which also keeps iOS 6-10
//   launches untouched by a framework they never use.
//
//   UIWebView (iOS 8-10, 64-bit) — no WKHTTPCookieStore exists to read the
//   cookies out of a WKWebView, so those systems keep UIWebView, which shares
//   NSHTTPCookieStorage with the app and needs no cookie copying.
//
//   32-bit armv7 — Google's page crashes the legacy WebKit engine natively
//   mid-render (uncatchable), so no web sign-in is offered at all.
//
// Cookie sign-in — paste the SAPISID value (or a full Cookie header) from a
// desktop browser signed into YouTube Music. Needs no WebKit, works on every
// device, and stays available as a button and a bar item everywhere.

static NSString *const LTSignInWebUserAgent =
    @"Mozilla/5.0 (Linux; U; Android 2.3.7; en-us) AppleWebKit/533.1 "
     "(KHTML, like Gecko) Version/4.0 Mobile Safari/533.1";

static NSString *const LTSignInWebURL =
    @"https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fmusic.youtube.com%2F&hl=en";

// The armv7 build compiles against the iOS 9.3 SDK, which has no public WebKit
// headers at all and predates WKHTTPCookieStore. The few WK pieces used here are
// therefore declared locally and reached through NSClassFromString, so one
// source file builds for both SDKs with no WebKit header dependency.
@protocol LTWKDataStoreClassLike <NSObject>
+ (id)defaultDataStore;
@end

@protocol LTWKDataStoreLike <NSObject>
- (id)httpCookieStore;
@end

@protocol LTWKHTTPCookieStoreLike <NSObject>
- (void)getAllCookies:(void (^)(NSArray *cookies))completionHandler;
@end

// The WKWebView members this screen uses. Declared rather than reached through
// KVC: a mistyped key only throws at runtime, while a wrong signature here
// fails the build.
@protocol LTWKWebViewLike <NSObject>
- (void)loadRequest:(NSURLRequest *)request;
- (void)stopLoading;
- (BOOL)isLoading;
- (void)setCustomUserAgent:(NSString *)userAgent;
@end

@protocol LTCookiePollReceiver <NSObject>
- (void)pollWebViewCookies:(NSTimer *)timer;
@end

// NSTimer retains its target, so polling with the controller as the target
// would keep a dismissed sign-in screen alive for as long as the timer runs.
// The proxy holds it weakly and stops the timer once it is gone.
@interface LTWeakTimerProxy : NSObject
@property (nonatomic, weak) id<LTCookiePollReceiver> target;
+ (instancetype)proxyWithTarget:(id<LTCookiePollReceiver>)target;
- (void)poll:(NSTimer *)timer;
@end

@implementation LTWeakTimerProxy
+ (instancetype)proxyWithTarget:(id<LTCookiePollReceiver>)target {
    LTWeakTimerProxy *proxy = [[LTWeakTimerProxy alloc] init];
    proxy.target = target;
    return proxy;
}

- (void)poll:(NSTimer *)timer {
    id<LTCookiePollReceiver> target = self.target;
    if (!target) {
        [timer invalidate];
        return;
    }
    [target pollWebViewCookies:timer];
}
@end

// Only called from the iOS 11+ path; on older systems WKWebView either does not
// exist or cannot give its cookies back, so the framework is never loaded.
static void LTEnsureWebKitLoaded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (NSClassFromString(@"WKWebView")) return;
        dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_LAZY);
    });
}

static id LTWKHTTPCookieStore(void) {
    Class dataStoreClass = NSClassFromString(@"WKWebsiteDataStore");
    if (!dataStoreClass || ![dataStoreClass respondsToSelector:@selector(defaultDataStore)]) return nil;
    id dataStore = [(id<LTWKDataStoreClassLike>)dataStoreClass defaultDataStore];
    if (!dataStore || ![dataStore respondsToSelector:NSSelectorFromString(@"httpCookieStore")]) return nil;
    return [(id<LTWKDataStoreLike>)dataStore httpCookieStore];
}

@interface LTSignInViewController () <UIWebViewDelegate, UIAlertViewDelegate, UITextFieldDelegate, LTCookiePollReceiver>
@property (nonatomic, assign) BOOL pasteOnly;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, strong) UIButton *webButton;
@property (nonatomic, strong) UIButton *pasteButton;
// Exactly one of these is used, depending on the OS version. The WK one is
// untyped on purpose: no WebKit class is referenced by name, only by runtime
// lookup, so the weak link works on devices without WebKit.
@property (nonatomic, strong) UIWebView *webView;
@property (nonatomic, strong) id<LTWKWebViewLike> wkWebView;
// WKWebView cannot hand its cookies over on navigation callbacks (a weak-linked
// WKNavigationDelegate is unsafe on the iOS 6 fallback path), so the cookie
// store is polled instead.
@property (nonatomic, strong) NSTimer *cookiePollTimer;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) UIAlertView *pasteAlert;
// YES once the sign-in finished, so the web view's repeated load callbacks
// cannot pop the screen twice.
@property (nonatomic, assign) BOOL finished;
@end

@implementation LTSignInViewController

// 64-bit only: Google's page crashes legacy WebKit on armv7. A class method so
// the rest of the screen can ask which routes exist.
+ (BOOL)webSignInAvailable {
    if (sizeof(void *) != 8) return NO;
    return NSClassFromString(@"WKWebView") != nil || NSClassFromString(@"UIWebView") != nil;
}

// YES when the login cookies can actually be read back out of WKWebView, i.e.
// iOS 11+ on a 64-bit device.
- (BOOL)wkWebSignInAvailable {
    if (![[self class] webSignInAvailable]) return NO;
    if ([[UIDevice currentDevice].systemVersion doubleValue] < 11.0) return NO;
    LTEnsureWebKitLoaded();
    return NSClassFromString(@"WKWebView") != nil && LTWKHTTPCookieStore() != nil;
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

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopCookiePolling];
}

- (void)dealloc {
    // The proxy above stops the timer once this controller is gone; invalidating
    // here as well covers a teardown that races an in-flight poll.
    [_cookiePollTimer invalidate];
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

    CGFloat top = CGRectGetMaxY(self.hintLabel.frame) + 4;
    CGRect frame = CGRectMake(0, top, self.view.bounds.size.width,
                              self.view.bounds.size.height - top);
    self.hintLabel.text = @"Loading Google's sign-in page…";

    BOOL useWKWebView = [self wkWebSignInAvailable];
    if (useWKWebView) {
        [self openWKWebViewInFrame:frame];
    } else {
        [self openUIWebViewInFrame:frame];
    }

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    self.spinner.hidesWhenStopped = YES;
    self.spinner.center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    self.spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                                    UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [self.view addSubview:self.spinner];
    [self.spinner startAnimating];

    if (useWKWebView) {
        [self.wkWebView loadRequest:[self loginRequest]];
        [self startCookiePolling];
    } else {
        [self.webView loadRequest:[self loginRequest]];
    }
}

- (NSURLRequest *)loginRequest {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:LTSignInWebURL]
                                                          cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                      timeoutInterval:60.0];
    // Pretend to be a very old Android browser so Google serves its
    // lightweight login page instead of the modern one that crashes the legacy
    // WebKit engine mid-render.
    [request setValue:LTSignInWebUserAgent forHTTPHeaderField:@"User-Agent"];
    return request;
}

- (void)openUIWebViewInFrame:(CGRect)frame {
    self.webView = [[UIWebView alloc] initWithFrame:frame];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.backgroundColor = [UIColor whiteColor];
    self.webView.delegate = self;
    self.webView.scalesPageToFit = YES;
    [self.view addSubview:self.webView];
}

- (void)openWKWebViewInFrame:(CGRect)frame {
    Class webViewClass = NSClassFromString(@"WKWebView");
    if (!webViewClass) return;
    id<LTWKWebViewLike> webView = (id<LTWKWebViewLike>)[[webViewClass alloc] initWithFrame:frame];
    if (!webView) return;
    UIView *view = (UIView *)webView;
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    view.backgroundColor = [UIColor whiteColor];
    // Same lightweight page as the UIWebView path: the request header alone
    // does not change WKWebView's user agent, customUserAgent does.
    if ([webView respondsToSelector:@selector(setCustomUserAgent:)]) {
        [webView setCustomUserAgent:LTSignInWebUserAgent];
    }
    self.wkWebView = webView;
    [self.view addSubview:view];
}

#pragma mark - WKWebView cookie capture

- (void)startCookiePolling {
    [self stopCookiePolling];
    if (!self.wkWebView) return;
    self.cookiePollTimer = [NSTimer scheduledTimerWithTimeInterval:1.5
                                                           target:[LTWeakTimerProxy proxyWithTarget:self]
                                                         selector:@selector(poll:)
                                                         userInfo:nil
                                                          repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.cookiePollTimer forMode:NSRunLoopCommonModes];
}

- (void)stopCookiePolling {
    [self.cookiePollTimer invalidate];
    self.cookiePollTimer = nil;
}

- (void)pollWebViewCookies:(NSTimer *)timer {
    if (self.finished || !self.wkWebView) {
        [timer invalidate];
        self.cookiePollTimer = nil;
        return;
    }
    if (!self.wkWebView.isLoading) {
        [self.spinner stopAnimating];
        self.hintLabel.text = @"Signed in? Tap Check, or paste a cookie instead.";
    }
    [self adoptCookiesFromWKWebView];
}

// Reads WKWebsiteDataStore's cookies and hands the Google/YouTube ones to
// LTAuth. Only a set that actually contains SAPISID replaces the stored
// credentials, so browsing a Google page while signed out cannot wipe an
// existing sign-in.
- (void)adoptCookiesFromWKWebView {
    if (self.finished) return;
    id<LTWKHTTPCookieStoreLike> cookieStore = (id<LTWKHTTPCookieStoreLike>)LTWKHTTPCookieStore();
    if (!cookieStore) return;
    __weak LTSignInViewController *weakSelf = self;
    [cookieStore getAllCookies:^(NSArray *cookies) {
        LTSignInViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        // WKHTTPCookieStore calls back on a background queue.
        dispatch_async(dispatch_get_main_queue(), ^{
            [strongSelf adoptWKCookies:cookies];
        });
    }];
}

- (void)adoptWKCookies:(NSArray *)cookies {
    if (self.finished || !cookies.count) return;
    NSMutableArray *pairs = [NSMutableArray array];
    BOOL hasSapisid = NO;
    for (NSHTTPCookie *cookie in cookies) {
        if (![cookie isKindOfClass:[NSHTTPCookie class]]) continue;
        NSString *domain = [cookie.domain lowercaseString];
        if ([domain rangeOfString:@"google"].location == NSNotFound &&
            [domain rangeOfString:@"youtube"].location == NSNotFound) {
            continue;
        }
        if (!cookie.name.length || !cookie.value.length) continue;
        if ([cookie.name isEqualToString:@"SAPISID"] ||
            [cookie.name isEqualToString:@"__Secure-1PAPISID"] ||
            [cookie.name isEqualToString:@"__Secure-3PAPISID"]) {
            hasSapisid = YES;
        }
        [pairs addObject:[NSString stringWithFormat:@"%@=%@", cookie.name, cookie.value]];
    }
    if (!hasSapisid) return;
    [[LTAuth sharedAuth] setCredentialsWithCookieHeader:[pairs componentsJoinedByString:@"; "]
                                            accountName:nil];
    if ([[LTAuth sharedAuth] signedIn]) {
        LTLog(@"AUTH captured cookies from WKWebView (%d cookies)", (int)pairs.count);
        [self finishSignIn];
    }
}

#pragma mark - UIWebViewDelegate

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
    if (self.wkWebView) {
        [self adoptCookiesFromWKWebView];
        return [[LTAuth sharedAuth] signedIn];
    }
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
    [self stopCookiePolling];
    [self.webView stopLoading];
    [self.wkWebView stopLoading];
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
    [self stopCookiePolling];
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
