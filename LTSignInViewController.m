#import "LTSignInViewController.h"
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

@interface LTSignInViewController () <UIWebViewDelegate, LTCookiePollReceiver>
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
@end

@implementation LTSignInViewController

// YES when a WKWebView's cookies can be read back out, i.e. iOS 11+ on a
// 64-bit device. Everything else goes through UIWebView.
- (BOOL)canReadCookiesFromWKWebView {
    if (sizeof(void *) != 8) return NO;
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

    CGFloat top = CGRectGetMaxY(self.hintLabel.frame) + 4;
    CGRect frame = CGRectMake(0, top, width, self.view.bounds.size.height - top);
    if ([self canReadCookiesFromWKWebView]) {
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

    if (self.wkWebView) {
        [self.wkWebView loadRequest:[self loginRequest]];
        [self startCookiePolling];
    } else {
        [self.webView loadRequest:[self loginRequest]];
    }
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

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation {
    return YES;
}

#pragma mark - Web view

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
        self.hintLabel.text = @"Signed in? Tap Check.";
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
    self.hintLabel.text = @"Signed in? Tap Check.";
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
    self.hintLabel.text = @"Google's sign-in page could not be loaded. Try again, or use Cookies Sign-In.";
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

- (void)cancelTapped:(id)sender {
    [self stopCookiePolling];
    if (self.navigationController.viewControllers.count > 1) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:NULL];
    }
}

- (void)checkTapped:(id)sender {
    if ([self tryAdoptCookies]) return;
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Not signed in yet"
                                                    message:@"No Google account cookie found yet. Finish signing in on the page, or use Cookies Sign-In to paste a SAPISID cookie."
                                                   delegate:nil
                                          cancelButtonTitle:@"OK"
                                          otherButtonTitles:nil];
    [alert show];
}

@end
