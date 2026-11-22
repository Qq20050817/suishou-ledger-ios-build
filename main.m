#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

static NSString * const HomeURL = @"https://ledger.xiaokai123.de5.net/ledger";
static NSString * const IndependentURL = @"https://ledger-sync.xiaokai123.de5.net/ledger";

@protocol LedgerWebAccountBridge
+ (void)prepareIn:(WKHTTPCookieStore *)store completion:(void (^)(BOOL))completion;
@end

// Apply only inside the App's own ledger. Safari and other pages retain their
// normal zoom policy. Keep viewport-fit=cover for the existing safe-area bridge.
static NSString * const LedgerViewportScript =
    @"(() => {"
     "const hosts=['ledger-sync.xiaokai123.de5.net','ledger.xiaokai123.de5.net','suishou-ledger-0726.qq2301796536.chatgpt.site'];"
     "if(location.protocol!=='https:' || !hosts.includes(location.hostname) || !['/ledger','/ledger/'].includes(location.pathname)) return;"
     "const content='width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover';"
     "const apply=()=>{"
       "let tags=[...document.head.querySelectorAll('meta[name=viewport i]')];"
       "if(!tags.length){const tag=document.createElement('meta');tag.name='viewport';document.head.appendChild(tag);tags=[tag];}"
       "for(const tag of tags) if(tag.content!==content) tag.content=content;"
     "};"
     "apply();"
     "const addDevice=()=>{if(document.getElementById('suishou-device-link'))return;"
       "const search=document.querySelector('header button[aria-label*=搜索]');const form=document.querySelector('input[type=password]')?.closest('form');if(!search&&!form)return;"
       "const b=document.createElement('button');b.id='suishou-device-link';b.type='button';b.textContent='设备与同步';"
       "b.style.cssText='color:inherit;border:0;background:transparent;font:inherit;font-size:13px;padding:6px 8px;white-space:nowrap';"
       "b.onclick=()=>{location.href='suishou-ledger://device'};if(search)search.before(b);else form.after(b);};"
     "addDevice();new MutationObserver(addDevice).observe(document.body,{childList:true,subtree:true});"
     "new MutationObserver(apply).observe(document.head,{subtree:true,childList:true,attributes:true,attributeFilter:['name','content']});"
    "})();";

@interface LedgerController : UIViewController <WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate>
@property(nonatomic,strong) WKWebView *web;
@property(nonatomic,strong) UIView *errorView;
@property(nonatomic,strong) UILabel *errorLabel;
@property(nonatomic,strong) UIActivityIndicatorView *spinner;
@property(nonatomic,strong) UIBarButtonItem *backButton;
@property(nonatomic,strong) NSMutableSet<NSURL *> *downloads;
@end

@implementation LedgerController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"随手账";
    self.view.backgroundColor = [UIColor colorWithRed:253.0/255 green:251.0/255 blue:254.0/255 alpha:1];
    self.edgesForExtendedLayout = UIRectEdgeAll;
    self.extendedLayoutIncludesOpaqueBars = YES;
    self.downloads = [NSMutableSet set];
    WKWebViewConfiguration *config = [WKWebViewConfiguration new];
    config.websiteDataStore = WKWebsiteDataStore.defaultDataStore;
    config.allowsInlineMediaPlayback = YES;
    config.applicationNameForUserAgent = @"SuishouLedger/1.1";
    config.ignoresViewportScaleLimits = NO;
    Class reminderClass = NSClassFromString(@"LedgerReminderBridge");
    if (reminderClass) {
        id<WKScriptMessageHandlerWithReply> reminders = [[reminderClass alloc] init];
        [config.userContentController addScriptMessageHandlerWithReply:reminders contentWorld:WKContentWorld.pageWorld name:@"ledgerReminders"];
    }
    [config.userContentController addUserScript:[[WKUserScript alloc] initWithSource:LedgerViewportScript injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES]];
    self.web = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config];
    self.web.translatesAutoresizingMaskIntoConstraints = NO;
    self.web.navigationDelegate = self;
    self.web.UIDelegate = self;
    self.web.allowsBackForwardNavigationGestures = YES;
    self.web.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    self.web.backgroundColor = self.view.backgroundColor;
    self.web.opaque = NO;
    [self.view addSubview:self.web];
    [NSLayoutConstraint activateConstraints:@[
        // viewport-fit=cover and CSS env(safe-area-inset-*) own content avoidance.
        // Constraining the WebView to safeAreaLayoutGuide applies it twice.
        [self.web.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.web.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.web.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.web.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];
    self.backButton = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.left"] style:UIBarButtonItemStylePlain target:self action:@selector(back)];
    self.backButton.accessibilityLabel = @"返回上一页";
    self.navigationItem.leftBarButtonItem = self.backButton;
    UIBarButtonItem *menu = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] style:UIBarButtonItemStylePlain target:self action:@selector(menu)];
    menu.accessibilityLabel = @"更多操作";
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;
    self.navigationItem.rightBarButtonItems = @[menu, [[UIBarButtonItem alloc] initWithCustomView:self.spinner]];
    self.errorView = [UIView new];
    self.errorView.backgroundColor = self.view.backgroundColor;
    self.errorView.translatesAutoresizingMaskIntoConstraints = NO;
    self.errorView.hidden = YES;
    [self.view addSubview:self.errorView];
    self.errorLabel = [UILabel new];
    self.errorLabel.numberOfLines = 0;
    self.errorLabel.textAlignment = NSTextAlignmentCenter;
    self.errorLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.errorLabel.textColor = UIColor.secondaryLabelColor;
    UIButton *retry = [UIButton buttonWithType:UIButtonTypeSystem];
    [retry setTitle:@"重新加载" forState:UIControlStateNormal];
    retry.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    [retry addTarget:self action:@selector(reload) forControlEvents:UIControlEventTouchUpInside];
    UIButton *device = [UIButton buttonWithType:UIButtonTypeSystem];
    [device setTitle:@"打开离线账本" forState:UIControlStateNormal];
    [device addTarget:self action:@selector(showDevice) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.errorLabel,retry,device]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 24;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.errorView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [self.errorView.topAnchor constraintEqualToAnchor:self.web.topAnchor],
        [self.errorView.bottomAnchor constraintEqualToAnchor:self.web.bottomAnchor],
        [self.errorView.leadingAnchor constraintEqualToAnchor:self.web.leadingAnchor],
        [self.errorView.trailingAnchor constraintEqualToAnchor:self.web.trailingAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.errorView.centerYAnchor],
        [stack.centerXAnchor constraintEqualToAnchor:self.errorView.centerXAnchor],
        [stack.widthAnchor constraintLessThanOrEqualToConstant:340],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.errorView.leadingAnchor constant:28],
        [retry.heightAnchor constraintGreaterThanOrEqualToConstant:44]
    ]];
    UIRefreshControl *refresh = [UIRefreshControl new];
    [refresh addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    self.web.scrollView.refreshControl = refresh;
#if DEBUG
    if (NSProcessInfo.processInfo.environment[@"RECEIPT_RENDER_TESTS"]) return;
#endif
    [self home];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateNavigationChrome];
}
- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self updateWebSafeArea];
}
- (void)updateWebSafeArea {
    // Some WKWebView versions report CSS env() as zero with automatic scroll
    // insets disabled. Supply measured native insets without shrinking the web.
    UIEdgeInsets inset = self.view.safeAreaInsets;
    NSString *script = [NSString stringWithFormat:@"document.documentElement.style.setProperty('--app-safe-area-top','%.2fpx');document.documentElement.style.setProperty('--app-safe-area-bottom','%.2fpx');", inset.top, inset.bottom];
    [self.web evaluateJavaScript:script completionHandler:nil];
}
- (void)updateNavigationChrome {
    NSURL *url = self.web.URL;
    BOOL ledgerHost = [@[@"ledger-sync.xiaokai123.de5.net", @"ledger.xiaokai123.de5.net", @"suishou-ledger-0726.qq2301796536.chatgpt.site"] containsObject:url.host.lowercaseString];
    BOOL ledgerPage = !url || (ledgerHost && ([url.path isEqualToString:@"/ledger"] || [url.path isEqualToString:@"/ledger/"]));
    self.web.scrollView.pinchGestureRecognizer.enabled = !ledgerPage;
    self.web.scrollView.bouncesZoom = !ledgerPage;
    // The ledger already supplies a title and navigation. Keep native controls
    // for other pages, such as downloads and account setup.
    [self.navigationController setNavigationBarHidden:ledgerPage animated:NO];
}
- (void)home {
    Class<LedgerWebAccountBridge> bridge = (Class<LedgerWebAccountBridge>)NSClassFromString(@"LedgerWebAccount");
    void (^load)(BOOL) = ^(BOOL independent) {
        NSURL *url = [NSURL URLWithString:independent ? IndependentURL : HomeURL];
        [self.web loadRequest:[NSURLRequest requestWithURL:url]];
    };
    if (bridge) [bridge prepareIn:self.web.configuration.websiteDataStore.httpCookieStore completion:load];
    else load(NO);
}
- (void)showDevice {
    Class device = NSClassFromString(@"IndependentLedgerController");
    if (!device || self.presentedViewController) return;
    UIViewController *panel = [device new];
    panel.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:panel animated:YES completion:nil];
}
- (void)back { if (self.web.canGoBack) [self.web goBack]; }
- (void)reload { if (self.web.URL) [self.web reload]; else [self home]; }
- (void)anchor:(UIViewController *)controller {
    UIPopoverPresentationController *popover = controller.popoverPresentationController;
    if (!self.navigationController.navigationBarHidden) {
        popover.barButtonItem = self.navigationItem.rightBarButtonItems.firstObject;
    } else {
        popover.sourceView = self.view;
        popover.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
        popover.permittedArrowDirections = 0;
    }
}
- (void)share:(id)item {
    UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[item] applicationActivities:nil];
    [self anchor:sheet];
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)openExternal:(NSURL *)url {
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL success) {
        if (!success) [self notify:@"无法打开链接" message:@"请确认已安装对应的 App，或从更多操作中选择在 Safari 打开。"];
    }];
}
- (void)notify:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    if (!self.presentedViewController) [self presentViewController:alert animated:YES completion:nil];
}
- (void)menu {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"随手账" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"设备与同步" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self showDevice]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"刷新页面" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self reload]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"回到账本" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self home]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"在 Safari 打开" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self openExternal:self.web.URL ?: [NSURL URLWithString:HomeURL]]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"分享当前链接" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { [self share:self.web.URL ?: [NSURL URLWithString:HomeURL]]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self anchor:sheet];
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    self.errorView.hidden = YES;
    [self.spinner startAnimating];
    self.backButton.enabled = webView.canGoBack;
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    [self.spinner stopAnimating];
    [self.web.scrollView.refreshControl endRefreshing];
    [self updateNavigationChrome];
    [self updateWebSafeArea];
    self.backButton.enabled = webView.canGoBack;
}
- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation { [self updateNavigationChrome]; }
- (void)failed:(NSError *)error {
    [self.spinner stopAnimating];
    [self.web.scrollView.refreshControl endRefreshing];
    if (error.code == NSURLErrorCancelled) return;
    self.errorLabel.text = @"暂时无法打开随手账\n\n请检查网络连接后重试。";
    self.errorView.hidden = NO;
}
- (void)webView:(WKWebView *)w didFailProvisionalNavigation:(WKNavigation *)n withError:(NSError *)e { [self failed:e]; }
- (void)webView:(WKWebView *)w didFailNavigation:(WKNavigation *)n withError:(NSError *)e { [self failed:e]; }
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)w { [w reload]; }
- (void)webView:(WKWebView *)w decidePolicyForNavigationAction:(WKNavigationAction *)a decisionHandler:(void (^)(WKNavigationActionPolicy))done {
    NSURL *url = a.request.URL;
    NSString *scheme = url.scheme.lowercaseString;
    if ([scheme isEqualToString:@"suishou-ledger"]) {
        WKSecurityOrigin *source = a.sourceFrame.securityOrigin;
        if (a.sourceFrame.mainFrame && [source.protocol isEqualToString:@"https"] &&
            [@[@"ledger.xiaokai123.de5.net", @"ledger-sync.xiaokai123.de5.net", @"suishou-ledger-0726.qq2301796536.chatgpt.site"] containsObject:source.host.lowercaseString] &&
            [url.host isEqualToString:@"device"]) [self showDevice];
        done(WKNavigationActionPolicyCancel); return;
    }
    if ([url.path.pathExtension.lowercaseString isEqualToString:@"shortcut"]) {
        [self openExternal:url]; done(WKNavigationActionPolicyCancel); return;
    }
    if (a.shouldPerformDownload) { done(WKNavigationActionPolicyDownload); return; }
    if ([@[@"https",@"about",@"blob",@"data"] containsObject:scheme]) {
        // Keep redirects and authentication callbacks in the same persistent store.
        done(WKNavigationActionPolicyAllow); return;
    }
    if ([@[@"shortcuts",@"tel",@"mailto",@"itms-apps"] containsObject:scheme]) [self openExternal:url];
    done(WKNavigationActionPolicyCancel);
}
- (void)webView:(WKWebView *)w decidePolicyForNavigationResponse:(WKNavigationResponse *)response decisionHandler:(void (^)(WKNavigationResponsePolicy))done {
    done(response.canShowMIMEType ? WKNavigationResponsePolicyAllow : WKNavigationResponsePolicyDownload);
}
- (WKWebView *)webView:(WKWebView *)w createWebViewWithConfiguration:(WKWebViewConfiguration *)c forNavigationAction:(WKNavigationAction *)a windowFeatures:(WKWindowFeatures *)f {
    if (!a.targetFrame) [w loadRequest:a.request];
    return nil;
}
- (void)webView:(WKWebView *)w runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(void))done {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"随手账" message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { done(); }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)webView:(WKWebView *)w runJavaScriptConfirmPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL))done {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"随手账" message:message preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { done(NO); }]];
    [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { done(YES); }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)webView:(WKWebView *)w runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt defaultText:(NSString *)text initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(NSString *))done {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"随手账" message:prompt preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *field) { field.text = text; }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { done(nil); }]];
    [a addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { done(a.textFields.firstObject.text); }]];
    [self presentViewController:a animated:YES completion:nil];
}
- (void)webView:(WKWebView *)w navigationAction:(WKNavigationAction *)a didBecomeDownload:(WKDownload *)download { download.delegate = self; }
- (void)webView:(WKWebView *)w navigationResponse:(WKNavigationResponse *)r didBecomeDownload:(WKDownload *)download { download.delegate = self; }
- (void)download:(WKDownload *)download decideDestinationUsingResponse:(NSURLResponse *)response suggestedFilename:(NSString *)filename completionHandler:(void (^)(NSURL *))done {
    NSURL *directory = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    NSError *error = nil;
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error];
    if (error) { done(nil); return; }
    NSURL *destination = [directory URLByAppendingPathComponent:filename.lastPathComponent.length ? filename.lastPathComponent : @"账本导出"];
    [self.downloads addObject:destination];
    // Associate the destination with this download without an external dependency.
    objc_setAssociatedObject(download, @selector(downloadDidFinish:), destination, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    done(destination);
}
- (void)downloadDidFinish:(WKDownload *)download {
    [self.spinner stopAnimating];
    NSURL *url = objc_getAssociatedObject(download, @selector(downloadDidFinish:));
    if (url) [self share:url];
}
- (void)download:(WKDownload *)download didFailWithError:(NSError *)error resumeData:(NSData *)resumeData {
    [self.spinner stopAnimating];
    [self notify:@"下载未完成" message:@"请重试，或在 Safari 中打开页面后导出。"];
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    // App Intents may start this process in the background. Do not create the
    // WebView or a visible window until the person explicitly opens the App.
    return YES;
}
- (void)applicationDidBecomeActive:(UIApplication *)application {
#if DEBUG
    if (NSProcessInfo.processInfo.environment[@"RECEIPT_RENDER_TESTS"]) return;
#endif
    if (self.window) return;
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    UIViewController *entry = [LedgerController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:entry];
    UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = [UIColor colorWithRed:0.973 green:0.984 blue:1 alpha:1];
    nav.navigationBar.standardAppearance = appearance;
    nav.navigationBar.scrollEdgeAppearance = appearance;
    nav.navigationBar.compactAppearance = appearance;
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class)); }
}
