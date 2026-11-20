#import "LTCookieSignInViewController.h"
#import "LTCookieTutorialViewController.h"
#import "LTAuth.h"
#import "LTYouTubeClient.h"
#import "LTLog.h"
#import "LTTheme.h"

@interface LTCookieSignInViewController () <UITextViewDelegate>
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, strong) UITextView *cookieField;
@property (nonatomic, strong) UILabel *placeholderLabel;
@property (nonatomic, strong) UIButton *signInButton;
@property (nonatomic, strong) UIButton *guideButton;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation LTCookieSignInViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Cookies Sign-In";
    self.view.backgroundColor = [LTTheme background];

    self.scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.backgroundColor = [LTTheme background];
    [self.view addSubview:self.scrollView];

    // Tapping the empty space puts the keyboard away without swallowing taps
    // meant for the buttons.
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                         action:@selector(backgroundTapped:)];
    tap.cancelsTouchesInView = NO;
    [self.scrollView addGestureRecognizer:tap];

    self.hintLabel = [[UILabel alloc] init];
    self.hintLabel.font = [UIFont systemFontOfSize:12];
    self.hintLabel.textColor = [LTTheme secondaryText];
    self.hintLabel.numberOfLines = 0;
    self.hintLabel.text = @"Paste the whole cookie line from a desktop browser signed into "
                           "YouTube Music — SID=…; HSID=…; SAPISID=…";
    [self.scrollView addSubview:self.hintLabel];

    self.cookieField = [[UITextView alloc] init];
    self.cookieField.font = [UIFont systemFontOfSize:13];
    self.cookieField.textColor = [LTTheme text];
    self.cookieField.backgroundColor = [LTTheme cellBackground];
    self.cookieField.layer.cornerRadius = 8;
    self.cookieField.layer.borderWidth = 1;
    self.cookieField.layer.borderColor = [LTTheme separator].CGColor;
    self.cookieField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.cookieField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.cookieField.spellCheckingType = UITextSpellCheckingTypeNo;
    self.cookieField.delegate = self;
    // textContainerInset is iOS 7+; the armv7 build still runs on iOS 6.
    if ([self.cookieField respondsToSelector:@selector(setTextContainerInset:)]) {
        self.cookieField.textContainerInset = UIEdgeInsetsMake(8, 6, 8, 6);
    }
    [self.scrollView addSubview:self.cookieField];

    self.placeholderLabel = [[UILabel alloc] init];
    self.placeholderLabel.font = [UIFont systemFontOfSize:13];
    self.placeholderLabel.textColor = [LTTheme secondaryText];
    self.placeholderLabel.text = @"SID=…; HSID=…; SAPISID=…";
    self.placeholderLabel.userInteractionEnabled = NO;
    [self.cookieField addSubview:self.placeholderLabel];

    self.signInButton = [self buttonWithTitle:@"Sign In" action:@selector(signInTapped:)];
    self.signInButton.backgroundColor = [LTTheme accent];
    [self.signInButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.signInButton.layer.borderWidth = 0;
    [self.scrollView addSubview:self.signInButton];

    self.guideButton = [self buttonWithTitle:@"How do I get my cookies?" action:@selector(guideTapped:)];
    [self.scrollView addSubview:self.guideButton];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    self.spinner.hidesWhenStopped = YES;
    [self.scrollView addSubview:self.spinner];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillShow:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];

    [self layoutContent];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self layoutContent];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation {
    return YES;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutContent];
}

- (UIButton *)buttonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.layer.cornerRadius = 8;
    button.layer.borderWidth = 1;
    button.layer.borderColor = [LTTheme separator].CGColor;
    button.backgroundColor = [LTTheme fill];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[LTTheme text] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:15];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)layoutContent {
    CGFloat width = self.view.bounds.size.width;
    CGFloat side = 16;
    CGFloat contentWidth = width - side * 2;
    if (contentWidth < 100) return;

    self.scrollView.frame = self.view.bounds;

    CGSize hintSize = [self.hintLabel sizeThatFits:CGSizeMake(contentWidth, CGFLOAT_MAX)];
    self.hintLabel.frame = CGRectMake(side, 12, contentWidth, hintSize.height);

    CGFloat fieldY = CGRectGetMaxY(self.hintLabel.frame) + 10;
    CGFloat fieldHeight = 96;
    self.cookieField.frame = CGRectMake(side, fieldY, contentWidth, fieldHeight);
    self.placeholderLabel.frame = CGRectMake(11, 8, contentWidth - 22, 18);

    CGFloat buttonY = CGRectGetMaxY(self.cookieField.frame) + 12;
    self.signInButton.frame = CGRectMake(side, buttonY, contentWidth, 44);

    CGFloat guideY = CGRectGetMaxY(self.signInButton.frame) + 10;
    self.guideButton.frame = CGRectMake(side, guideY, contentWidth, 40);

    self.spinner.center = CGPointMake(CGRectGetMidX(self.signInButton.frame) - 30,
                                      CGRectGetMidY(self.signInButton.frame));

    CGFloat contentHeight = CGRectGetMaxY(self.guideButton.frame) + 24;
    self.scrollView.contentSize = CGSizeMake(width, contentHeight);
}

#pragma mark - Keyboard

- (void)keyboardWillShow:(NSNotification *)notification {
    NSDictionary *info = [notification userInfo];
    CGRect keyboardFrame = [[info objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGFloat covered = CGRectGetHeight(keyboardFrame);
    UIEdgeInsets insets = UIEdgeInsetsMake(0, 0, covered, 0);
    self.scrollView.contentInset = insets;
    if ([self.scrollView respondsToSelector:@selector(setScrollIndicatorInsets:)]) {
        self.scrollView.scrollIndicatorInsets = insets;
    }
    [self.scrollView scrollRectToVisible:CGRectInset(self.cookieField.frame, 0, -12) animated:YES];
}

- (void)keyboardWillHide:(NSNotification *)notification {
    self.scrollView.contentInset = UIEdgeInsetsZero;
    if ([self.scrollView respondsToSelector:@selector(setScrollIndicatorInsets:)]) {
        self.scrollView.scrollIndicatorInsets = UIEdgeInsetsZero;
    }
}

- (void)backgroundTapped:(id)sender {
    [self.view endEditing:YES];
}

#pragma mark - UITextViewDelegate

- (void)textViewDidChange:(UITextView *)textView {
    self.placeholderLabel.hidden = textView.text.length > 0;
}

#pragma mark - Actions

- (void)guideTapped:(id)sender {
    LTCookieTutorialViewController *vc = [[LTCookieTutorialViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)signInTapped:(id)sender {
    NSString *text = [self.cookieField.text stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text.length) {
        [self showMessage:@"Nothing to sign in with"
                     body:@"Paste the whole YouTube Music cookie line first, or tap How do I get my cookies? for the steps."];
        return;
    }

    [self.view endEditing:YES];
    self.signInButton.enabled = NO;
    [self.spinner startAnimating];

    // Validate first, store second. The candidate cookie is used for one
    // request only, so a bad paste leaves whatever was already signed in
    // untouched instead of replacing it with something that does not work.
    NSString *candidate = [[LTAuth sharedAuth] normalizedCookieHeaderFromInput:text];
    __weak LTCookieSignInViewController *weakSelf = self;
    [[LTYouTubeClient sharedClient] fetchAccountNameWithCookieHeader:candidate
                                                         completion:^(NSString *name, NSError *error) {
        LTCookieSignInViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.spinner stopAnimating];
        strongSelf.signInButton.enabled = YES;

        if (!name.length) {
            LTLog(@"AUTH cookie sign-in rejected: %@", error);
            if (![[LTAuth sharedAuth] cookieHeaderHasSession:candidate]) {
                // The paste carried the hash secret but no session cookies, and
                // the server returned no account for it. Say that, and point at
                // the fuller paste, without claiming the value itself is wrong.
                [strongSelf showMessage:@"No account came back"
                                   body:@"YouTube Music returned no account for that paste, so nothing was changed. A whole cookie line (SID=…; HSID=…; SAPISID=…) is the most reliable thing to paste: tap How do I get my cookies? and copy the cookies as shown in step 4."];
                return;
            }
            [strongSelf showMessage:@"No account came back"
                               body:@"YouTube Music returned no account for that cookie, so nothing was changed. Check that the browser is signed into the account you want, copy a fresh cookie line, and try again."];
            return;
        }
        [[LTAuth sharedAuth] setCredentialsWithCookieHeader:candidate accountName:name];
        LTLog(@"AUTH signed in with a pasted cookie as %@", name);
        [strongSelf.navigationController popViewControllerAnimated:YES];
    }];
}

- (void)showMessage:(NSString *)title body:(NSString *)body {
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:title
                                                    message:body
                                                   delegate:nil
                                          cancelButtonTitle:@"OK"
                                          otherButtonTitles:nil];
    [alert show];
}

@end
