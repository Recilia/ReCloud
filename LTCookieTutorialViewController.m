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
            "browser that is already signed in. You copy one cookie once, paste it into the app, "
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
            "4. Look for the cookie named SAPISID and copy its Value. It is a long string of letters, "
            "numbers and symbols.\n\n"
            "5. In Re:Cloud open Settings → Account → Cookies Sign-In, paste the value into the box "
            "and tap Sign In.\n\n"
            "Pasting a whole cookie line\n"
            "Instead of a single value you can copy the cookies as one line, "
            "\"NAME=VALUE; NAME=VALUE; …\", and paste that. Re:Cloud picks SAPISID out of it.\n\n"
            "If SAPISID is not in the list\n"
            "Use __Secure-3PAPISID or __Secure-1PAPISID instead. Any of the three works.\n\n"
            "Keeping it working\n"
            "• Do not use \"Sign out of all devices\" on the Google account: that revokes this cookie.\n"
            "• A cookie normally lasts around two years. When Re:Cloud asks you to sign in again, "
            "repeat these steps for a fresh value.\n"
            "• Treat the cookie like a password: anyone who has it can use the account.\n";
}

@end
