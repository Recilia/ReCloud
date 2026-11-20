#import "LTSignInViewController.h"
#import "LTCookieSignInViewController.h"
#import "LTAuth.h"
#import "LTYouTubeClient.h"
#import "LTLog.h"
#import "LTTheme.h"
#include <dlfcn.h>

// Google's sign-in page in an in-app browser, offered on every device.
//
//   WKWebView (iOS 11+) — UIWebView can render Google's login page blank on
//   modern iOS, so newer systems use WKWebView. Its cookies live in
//   WKWebsiteDataStore rather than NSHTTPCookieStorage, so they are read back
//   through WKHTTPCookieStore (iOS 11) and handed to LTAuth as a Cookie
//   header. WebKit is not linked at all: the iOS 9.3 armv7 SDK ships it only as
//   a private framework, so it is dlopen'd on demand, which also keeps iOS 6-10
//   launches untouched by a framework they never use.
//
//   UIWebView (everything else) — iOS 6-10, 32-bit included. Those systems
//   either have no WKWebView or no way to read one's cookies back, so the page
//   is hosted in UIWebView, which shares NSHTTPCookieStorage with the app.
//
// Not every device can run it, so the screen degrades instead of showing a
// blank browser: 32-bit hardware never loads the page at all (it crashes the
// legacy WebKit engine natively, see +webSignInSupported), and a load failure
// or a dead web process swaps the browser for a panel that points the user at
// Cookies Sign-In.
//
// The cookie paste route lives in LTCookieSignInViewController and stays
// available next to this screen in Settings → Account.

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
- (void)setNavigationDelegate:(id)delegate;
@end

// Navigation callbacks for the WK path only, where WebKit is guaranteed to
// exist (iOS 11+). Declared locally for the same SDK reason as above.
@protocol LTWKNavigationDelegateLike <NSObject>
@optional
- (void)webView:(id)webView didFinishNavigation:(id)navigation;
- (void)webView:(id)webView didFailNavigation:(id)navigation withError:(NSError *)error;
- (void)webView:(id)webView didFailProvisionalNavigation:(id)navigation withError:(NSError *)error;
- (void)webViewWebContentProcessDidTerminate:(id)webView;
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

@interface LTSignInViewController () <UIWebViewDelegate, LTCookiePollReceiver, LTWKNavigationDelegateLike>
@property (nonatomic, strong) UILabel *hintLabel;
// Exactly one of these is used, depending on the OS version. The WK one is
// reached by runtime lookup only, never by naming a WebKit class.
@property (nonatomic, strong) UIWebView *webView;
@property (nonatomic, strong) id<LTWKWebViewLike> wkWebView;
// WKWebView cannot hand its cookies over on navigation callbacks (a weak-linked
// WKNavigationDelegate is unsafe on the iOS 6 fallback path), so the cookie
// store is polled instead.
@property (nonatomic, strong) NSTimer *cookiePollTimer;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
// YES once the sign-in finished, so the web view's repeated load callbacks
// cannot pop the screen twice.
@property (nonatomic, assign) BOOL finished;
// The browser is gone and the explanation panel is showing instead.
@property (nonatomic, assign) BOOL failed;
// A candidate cookie set is being checked against the account endpoint; nothing
// reaches LTAuth until it comes back with a name.
@property (nonatomic, assign) BOOL validating;
// The last candidate that was checked, so the 1.5s poll does not re-ask about
// the same set on every tick.
@property (nonatomic, copy) NSString *lastCheckedHeader;
// Set by Check so an explicit tap re-validates the same cookie set the poll
// already tried. It stays set across the asynchronous WK adopt hop (getAllCookies:
// -> adoptWKCookies: -> startCookieCheck:) and is consumed there; the automatic
// poll never sets it, so polling keeps deduping.
@property (nonatomic, assign) BOOL forceNextCheck;
@property (nonatomic, strong) UILabel *fallbackTitleLabel;
@property (nonatomic, strong) UILabel *fallbackBodyLabel;
@property (nonatomic, strong) UIButton *fallbackCookiesButton;
@property (nonatomic, strong) UIButton *fallbackRetryButton;
@end

@implementation LTSignInViewController

// NO on 32-bit hardware: Google's page crashes the legacy WebKit engine
// natively mid-render (uncatchable), so that page is never loaded there and
// the screen says so.
+ (BOOL)webSignInSupported {
    return sizeof(void *) == 8;
}

// YES when a WKWebView's cookies can be read back out, i.e. iOS 11+ on a
// 64-bit device. Everything else goes through UIWebView.
- (BOOL)canReadCookiesFromWKWebView {
    if (![[self class] webSignInSupported]) return NO;
    if ([[UIDevice currentDevice].systemVersion doubleValue] < 11.0) return NO;
    LTEnsureWebKitLoaded();
    return NSClassFromString(@"WKWebView") != nil && LTWKHTTPCookieStore() != nil;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Google Sign-In";
    self.view.backgroundColor = [LTTheme background];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Cancel"
                                                                            style:UIBarButtonItemStyleBordered
                                                                           target:self
                                                                           action:@selector(cancelTapped:)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Check"
                                                                             style:UIBarButtonItemStyleDone
                                                                            target:self
                                                                            action:@selector(checkTapped:)];

    CGFloat width = self.view.bounds.size.width;
    self.hintLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, width - 24, 40)];
    self.hintLabel.font = [UIFont systemFontOfSize:12];
    self.hintLabel.textColor = [LTTheme secondaryText];
    self.hintLabel.numberOfLines = 3;
    self.hintLabel.textAlignment = NSTextAlignmentCenter;
    self.hintLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
    self.hintLabel.text = @"Sign in with your Google account below. This screen closes by itself once Google is done.";
    [self.view addSubview:self.hintLabel];

    if (![[self class] webSignInSupported]) {
        [self showFallbackWithMessage:@"Google's sign-in page crashes the old WebKit engine on 32-bit devices, "
                                       "so it is not loaded here. Sign in with cookies instead: paste the "
                                       "cookie line from a desktop browser signed into YouTube Music."
                             canRetry:NO];
        return;
    }

    [self startLoadingWebPage];
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

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutFallback];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation {
    return YES;
}

#pragma mark - Loading

- (void)startLoadingWebPage {
    self.failed = NO;
    self.hintLabel.hidden = NO;
    self.hintLabel.text = @"Sign in with your Google account below. This screen closes by itself once Google is done.";
    [self hideFallback];

    CGFloat top = CGRectGetMaxY(self.hintLabel.frame) + 4;
    CGRect frame = CGRectMake(0, top, self.view.bounds.size.width,
                              self.view.bounds.size.height - top);
    if ([self canReadCookiesFromWKWebView]) {
        [self openWKWebViewInFrame:frame];
    } else {
        [self openUIWebViewInFrame:frame];
    }

    if (!self.spinner) {
        self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
        self.spinner.hidesWhenStopped = YES;
        [self.view addSubview:self.spinner];
    }
    self.spinner.center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    self.spinner.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                                    UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [self.spinner startAnimating];

    if (self.wkWebView) {
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
    // lightweight login page instead of the modern one that the legacy WebKit
    // engine struggles with.
    [request setValue:LTSignInWebUserAgent forHTTPHeaderField:@"User-Agent"];
    return request;
}

- (void)openUIWebViewInFrame:(CGRect)frame {
    [self.webView removeFromSuperview];
    self.webView.delegate = nil;
    self.webView = [[UIWebView alloc] initWithFrame:frame];
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.backgroundColor = [UIColor whiteColor];
    self.webView.delegate = self;
    self.webView.scalesPageToFit = YES;
    [self.view addSubview:self.webView];
}

- (void)openWKWebViewInFrame:(CGRect)frame {
    [(UIView *)self.wkWebView removeFromSuperview];
    self.wkWebView = nil;

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
    // Needed only so a failed load or a dead web process can be noticed; the
    // cookies themselves come from the poll below.
    [webView setNavigationDelegate:self];
    self.wkWebView = webView;
    [self.view addSubview:view];
}

#pragma mark - Degraded state

// Replaces the browser with an explanation. The panel keeps the two things the
// user can do from here: go to Cookies Sign-In, or try the page again.
- (void)showFallbackWithMessage:(NSString *)message canRetry:(BOOL)canRetry {
    self.failed = YES;
    [self stopCookiePolling];
    [self.spinner stopAnimating];
    [self.spinner removeFromSuperview];
    self.spinner = nil;
    self.webView.delegate = nil;
    [self.webView removeFromSuperview];
    self.webView = nil;
    [(UIView *)self.wkWebView removeFromSuperview];
    self.wkWebView = nil;
    self.hintLabel.hidden = YES;

    if (!self.fallbackTitleLabel) {
        self.fallbackTitleLabel = [[UILabel alloc] init];
        self.fallbackTitleLabel.font = [UIFont boldSystemFontOfSize:17];
        self.fallbackTitleLabel.textColor = [LTTheme text];
        self.fallbackTitleLabel.textAlignment = NSTextAlignmentCenter;
        self.fallbackTitleLabel.numberOfLines = 0;
        self.fallbackTitleLabel.text = @"Google Sign-In can't run here";
        [self.view addSubview:self.fallbackTitleLabel];

        self.fallbackBodyLabel = [[UILabel alloc] init];
        self.fallbackBodyLabel.font = [UIFont systemFontOfSize:13];
        self.fallbackBodyLabel.textColor = [LTTheme secondaryText];
        self.fallbackBodyLabel.textAlignment = NSTextAlignmentCenter;
        self.fallbackBodyLabel.numberOfLines = 0;
        [self.view addSubview:self.fallbackBodyLabel];

        self.fallbackCookiesButton = [self fallbackButtonWithTitle:@"Use Cookies Sign-In"
                                                          accent:YES
                                                          action:@selector(openCookieSignInTapped:)];
        [self.view addSubview:self.fallbackCookiesButton];

        self.fallbackRetryButton = [self fallbackButtonWithTitle:@"Try Again"
                                                        accent:NO
                                                        action:@selector(retryTapped:)];
        [self.view addSubview:self.fallbackRetryButton];
    }

    self.fallbackBodyLabel.text = message;
    self.fallbackRetryButton.hidden = !canRetry;
    [self layoutFallback];
}

- (UIButton *)fallbackButtonWithTitle:(NSString *)title accent:(BOOL)accent action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.layer.cornerRadius = 8;
    button.layer.borderWidth = 1;
    button.layer.borderColor = [LTTheme separator].CGColor;
    button.backgroundColor = accent ? [LTTheme accent] : [LTTheme fill];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:accent ? [UIColor whiteColor] : [LTTheme text] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:15];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)layoutFallback {
    if (!self.fallbackTitleLabel || self.fallbackTitleLabel.superview == nil) return;

    CGFloat width = self.view.bounds.size.width;
    CGFloat side = 24;
    CGFloat contentWidth = MAX(120, width - side * 2);
    CGFloat buttonHeight = 44;
    CGFloat gap = 10;

    CGSize titleSize = [self.fallbackTitleLabel sizeThatFits:CGSizeMake(contentWidth, CGFLOAT_MAX)];
    CGSize bodySize = [self.fallbackBodyLabel sizeThatFits:CGSizeMake(contentWidth, CGFLOAT_MAX)];
    CGFloat retryHeight = self.fallbackRetryButton.hidden ? 0 : buttonHeight + gap;

    CGFloat total = titleSize.height + 8 + bodySize.height + 24 + buttonHeight + retryHeight;
    CGFloat y = MAX(16, (self.view.bounds.size.height - total) / 2.0);

    self.fallbackTitleLabel.frame = CGRectMake(side, y, contentWidth, titleSize.height);
    y = CGRectGetMaxY(self.fallbackTitleLabel.frame) + 8;
    self.fallbackBodyLabel.frame = CGRectMake(side, y, contentWidth, bodySize.height);
    y = CGRectGetMaxY(self.fallbackBodyLabel.frame) + 24;
    self.fallbackCookiesButton.frame = CGRectMake(side, y, contentWidth, buttonHeight);
    y = CGRectGetMaxY(self.fallbackCookiesButton.frame) + gap;
    self.fallbackRetryButton.frame = CGRectMake(side, y, contentWidth, buttonHeight);
}

- (void)hideFallback {
    self.fallbackTitleLabel.hidden = YES;
    self.fallbackBodyLabel.hidden = YES;
    self.fallbackCookiesButton.hidden = YES;
    self.fallbackRetryButton.hidden = YES;
}

- (void)retryTapped:(id)sender {
    [self startLoadingWebPage];
}

- (void)openCookieSignInTapped:(id)sender {
    LTCookieSignInViewController *vc = [[LTCookieSignInViewController alloc] init];
    UINavigationController *nav = self.navigationController;
    if (!nav) {
        [self presentViewController:vc animated:YES completion:NULL];
        return;
    }
    // Replace this screen rather than stacking on it: once the cookie sign-in
    // succeeds it pops back to Settings, not to this dead end.
    NSMutableArray *stack = [NSMutableArray arrayWithArray:nav.viewControllers];
    if (stack.count) [stack removeLastObject];
    [stack addObject:vc];
    [nav setViewControllers:stack animated:YES];
}

- (void)handleWebFailure:(NSError *)error {
    if (error.code == NSURLErrorCancelled) return;
    LTLog(@"AUTH web view failed: %@", error);
    [self showFallbackWithMessage:@"Google's sign-in page could not be loaded on this device. "
                                   "Cookies Sign-In still works: paste your YouTube Music cookies from a "
                                   "browser signed into YouTube Music."
                         canRetry:YES];
}

#pragma mark - WKWebView navigation

- (void)webView:(id)webView didFinishNavigation:(id)navigation {
    [self.spinner stopAnimating];
    if (!self.validating) self.hintLabel.text = @"Signed in? Tap Check.";
}

- (void)webView:(id)webView didFailNavigation:(id)navigation withError:(NSError *)error {
    [self handleWebFailure:error];
}

- (void)webView:(id)webView didFailProvisionalNavigation:(id)navigation withError:(NSError *)error {
    [self handleWebFailure:error];
}

- (void)webViewWebContentProcessDidTerminate:(id)webView {
    // The page's process died — this is what a blank WKWebView looks like.
    LTLog(@"AUTH web content process terminated");
    [self showFallbackWithMessage:@"Google's sign-in page stopped responding on this device. "
                                   "Cookies Sign-In still works: paste your YouTube Music cookies from a "
                                   "browser signed into YouTube Music."
                         canRetry:YES];
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
        if (!self.validating) self.hintLabel.text = @"Signed in? Tap Check.";
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
    // Checked, not stored: an expired session captured from the page must not
    // replace a working sign-in. Only a good answer writes to LTAuth.
    NSArray *sorted = [pairs sortedArrayUsingSelector:@selector(compare:)];
    LTLog(@"AUTH checking %d cookies from WKWebView", (int)sorted.count);
    [self startCookieCheck:[sorted componentsJoinedByString:@"; "]];
}

#pragma mark - UIWebViewDelegate

- (void)webViewDidStartLoad:(UIWebView *)webView {
    [self.spinner startAnimating];
}

- (void)webViewDidFinishLoad:(UIWebView *)webView {
    [self.spinner stopAnimating];
    if (!self.validating) self.hintLabel.text = @"Signed in? Tap Check.";
    // Every page that loads is a chance that the login just completed: the
    // cookies are shared with NSHTTPCookieStorage, so look for SAPISID.
    NSString *host = webView.request.URL.host ?: @"";
    if ([host hasSuffix:@"google.com"] || [host hasSuffix:@"youtube.com"]) {
        [self tryAdoptCookies];
    }
}

- (void)webView:(UIWebView *)webView didFailLoadWithError:(NSError *)error {
    [self handleWebFailure:error];
}

#pragma mark - Capture

- (BOOL)tryAdoptCookies {
    if (self.failed) return NO;
    if (self.wkWebView) {
        [self adoptCookiesFromWKWebView];
        return [[LTAuth sharedAuth] signedIn];
    }
    // UIWebView shares NSHTTPCookieStorage, so the candidate is read out of it
    // and checked; nothing is saved unless the account endpoint accepts it.
    [self startCookieCheck:[[LTAuth sharedAuth] cookieHeaderFromSharedStorage]];
    return [[LTAuth sharedAuth] signedIn];
}

// Checks a candidate cookie header and stores it only if the account endpoint
// answers with a name. Returns NO when there was nothing new to check: either a
// check is already running, or this exact set was already asked about and the
// caller is the poll. forceNextCheck makes an explicit Check retry it.
- (BOOL)startCookieCheck:(NSString *)cookieHeader {
    BOOL force = self.forceNextCheck;
    self.forceNextCheck = NO;
    if (self.finished || self.validating || !cookieHeader.length) return NO;
    if (!force && [cookieHeader isEqualToString:self.lastCheckedHeader]) return NO;
    self.lastCheckedHeader = cookieHeader;
    self.validating = YES;
    self.hintLabel.text = @"Checking the account…";

    __weak LTSignInViewController *weakSelf = self;
    [[LTYouTubeClient sharedClient] fetchAccountNameWithCookieHeader:cookieHeader
                                                         completion:^(NSString *name, NSError *error) {
        LTSignInViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.validating = NO;
        if (strongSelf.finished) return;

        if (!name.length) {
            // Keep whatever was already signed in and stay on the page.
            LTLog(@"AUTH web sign-in cookie not accepted yet: %@", error);
            strongSelf.hintLabel.text = @"Not signed in yet. Finish on the page, or use Cookies Sign-In.";
            return;
        }
        [[LTAuth sharedAuth] setCredentialsWithCookieHeader:cookieHeader accountName:name];
        [strongSelf finishSignInWithAccountName:name];
    }];
    return YES;
}

- (void)finishSignInWithAccountName:(NSString *)name {
    if (self.finished) return;
    self.finished = YES;
    [self stopCookiePolling];
    [self.webView stopLoading];
    [self.wkWebView stopLoading];
    if (name.length) LTLog(@"AUTH signed in from the web page as %@", name);
    [self.navigationController popViewControllerAnimated:YES];
}

#pragma mark - Buttons

- (void)cancelTapped:(id)sender {
    [self stopCookiePolling];
    if (self.navigationController.viewControllers.count > 1) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:NULL];
    }
}

- (void)checkTapped:(id)sender {
    if (self.failed) {
        // Nothing to check while the browser is down; offer the working route.
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Google Sign-In unavailable"
                                                        message:@"Google's page cannot run here. Use Cookies Sign-In and paste your YouTube Music cookies from a desktop browser."
                                                       delegate:nil
                                              cancelButtonTitle:@"OK"
                                              otherButtonTitles:nil];
        [alert show];
        return;
    }
    self.hintLabel.text = @"Checking the account…";
    // Arm the one-shot bypass before handing over: on the WK path the candidate
    // only reaches startCookieCheck: after the cookie store calls back.
    self.forceNextCheck = YES;
    if ([self tryAdoptCookies]) {
        self.forceNextCheck = NO;
        return;
    }
    // WK cookies arrive asynchronously, and a check already running reports
    // itself, so neither case needs the "not signed in" alert.
    if (self.wkWebView || self.validating) return;
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Not signed in yet"
                                                    message:@"No Google account cookie found yet. Finish signing in on the page, or use Cookies Sign-In to paste your YouTube Music cookies."
                                                   delegate:nil
                                          cancelButtonTitle:@"OK"
                                          otherButtonTitles:nil];
    [alert show];
}

@end
