#import "LTCookieTutorialViewController.h"
#import "LTTheme.h"

@interface LTCookieTutorialViewController ()
@property (nonatomic, strong) UITextView *textView;
@end

@implementation LTCookieTutorialViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Cookie Sign-In Guide";
    self.view.backgroundColor = [LTTheme background];

    self.textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    self.textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.textView.backgroundColor = [LTTheme background];
    self.textView.textColor = [LTTheme text];
    self.textView.font = [UIFont systemFontOfSize:14];
    self.textView.editable = NO;
    self.textView.scrollEnabled = YES;
    self.textView.alwaysBounceVertical = YES;
    // iOS 7+; the armv7 build still runs on iOS 6.
    if ([self.textView respondsToSelector:@selector(setTextContainerInset:)]) {
        self.textView.textContainerInset = UIEdgeInsetsMake(16, 16, 24, 16);
    }
    self.textView.text = [[self class] guideText];
    [self.view addSubview:self.textView];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation {
    return YES;
}

+ (NSString *)guideText {
    return @"Signing in with a cookie\n\n"
            "Re:Cloud talks to YouTube Music the same way the website does, with the cookies of a "
            "browser that is already signed in. You copy those cookies once, paste them into the app, "
            "and Re:Cloud uses that account from then on.\n\n"
            "You need a computer with a browser and the Google account you want to use.\n\n"
            "1. On the computer, open music.youtube.com and sign in.\n\n"
            "2. Open the browser's developer tools:\n"
            "   • Chrome, Edge or Brave: press F12 (Option-Command-I on macOS)\n"
            "   • Firefox: press F12 (Option-Command-I on macOS)\n"
            "   • Safari: enable Settings → Advanced → Show Develop menu, then press Option-Command-I\n\n"
            "3. Find the cookies for music.youtube.com:\n"
            "   • Chrome, Edge, Brave: Application tab → Storage → Cookies → https://music.youtube.com\n"
            "   • Firefox: Storage tab → Cookies → https://music.youtube.com\n"
            "   • Safari: Storage tab → Cookies\n\n"
            "4. Copy all the cookies as one line. The quickest way: switch the developer tools to the "
            "Network tab, reload the page, click any music.youtube.com request and copy its "
            "\"cookie\" request header. In the Cookies panel you can also select a cookie row and "
            "press Command-A then Command-C (Ctrl-A, Ctrl-C).\n\n"
            "5. In Re:Cloud open Settings → Account → Cookies Sign-In, paste that whole line into the "
            "box and tap Sign In. It looks like \"SID=…; HSID=…; SSID=…; APISID=…; SAPISID=…\".\n\n"
            "Pasting the whole line\n"
            "The whole line carries the session cookies (SID and the rest) together with SAPISID, which "
            "is what Re:Cloud expects. If all you have is the SAPISID value you can paste that as well; "
            "if Re:Cloud says that no account came back, return here and copy all the cookies instead.\n\n"
            "Keeping it working\n"
            "• Do not use \"Sign out of all devices\" on the Google account: that revokes this cookie.\n"
            "• A cookie normally lasts around two years. When Re:Cloud asks you to sign in again, "
            "repeat these steps for a fresh value.\n"
            "• Treat the cookie like a password: anyone who has it can use the account.\n";
}

@end
