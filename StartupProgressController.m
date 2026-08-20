#import <UIKit/UIKit.h>
#import <objc/message.h>

#import "MCMFilzaIntegration.h"

@interface FSStartupProgressController : NSObject
@property(nonatomic, strong) UIView *overlay;
@property(nonatomic, strong) UIProgressView *progressView;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UILabel *percentLabel;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic) double latestProgress;
@property(nonatomic, copy) NSString *latestStatus;
@property(nonatomic) BOOL finished;
@property(nonatomic) BOOL retryScheduled;
+ (instancetype)sharedController;
- (void)showIfNeeded;
- (void)applyProgress:(double)progress status:(NSString *)status;
- (void)finishWithStatus:(NSString *)status;
@end

static UIWindow *FSStartupKeyWindow(void)
{
    UIApplication *application = UIApplication.sharedApplication;
    for (UIWindow *window in application.windows)
        if (window.isKeyWindow) return window;
    for (UIWindow *window in application.windows)
        if (!window.hidden && window.alpha > 0.0) return window;
    return nil;
}

static UIViewController *FSStartupVisibleController(UIViewController *controller)
{
    while (controller) {
        UIViewController *next = controller.presentedViewController;
        if (!next && [controller isKindOfClass:UINavigationController.class])
            next = ((UINavigationController *)controller).visibleViewController;
        if (!next && [controller isKindOfClass:UITabBarController.class])
            next = ((UITabBarController *)controller).selectedViewController;
        if (!next && [controller isKindOfClass:UISplitViewController.class])
            next = ((UISplitViewController *)controller).viewControllers.lastObject;
        if (!next || next == controller) break;
        controller = next;
    }
    return controller;
}

static void FSStartupReloadBrowser(void)
{
    UIWindow *window = FSStartupKeyWindow();
    UIViewController *controller = FSStartupVisibleController(window.rootViewController);
    SEL loadSelector = NSSelectorFromString(@"doLoadingPage");
    if ([controller respondsToSelector:loadSelector]) {
        ((void (*)(id, SEL))objc_msgSend)(controller, loadSelector);
        NSLog(@"[StartupProgress] reloaded browser after background initialization class=%@",
              NSStringFromClass(controller.class));
    }
}

@implementation FSStartupProgressController

+ (instancetype)sharedController
{
    static FSStartupProgressController *controller;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controller = [FSStartupProgressController new];
        controller.latestProgress = 0.02;
        controller.latestStatus = @"正在准备设备存储…";
    });
    return controller;
}

- (void)showIfNeeded
{
    NSAssert(NSThread.isMainThread, @"startup UI must run on main thread");
    if (self.finished || MCMFilzaStartupIsComplete() || self.overlay) return;

    UIWindow *window = FSStartupKeyWindow();
    if (!window) {
        if (!self.retryScheduled) {
            self.retryScheduled = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                           dispatch_get_main_queue(), ^{
                self.retryScheduled = NO;
                [self showIfNeeded];
            });
        }
        return;
    }

    UIView *overlay = [UIView new];
    overlay.translatesAutoresizingMaskIntoConstraints = NO;
    overlay.backgroundColor = UIColor.systemBackgroundColor;
    overlay.accessibilityViewIsModal = YES;

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"FilzaSlop";
    title.font = [UIFont systemFontOfSize:28 weight:UIFontWeightSemibold];
    title.textAlignment = NSTextAlignmentCenter;

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [spinner startAnimating];

    UIProgressView *progressView = [[UIProgressView alloc]
        initWithProgressViewStyle:UIProgressViewStyleDefault];
    progressView.translatesAutoresizingMaskIntoConstraints = NO;
    progressView.progress = (float)MAX(0.0, MIN(1.0, self.latestProgress));

    UILabel *status = [UILabel new];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    status.text = self.latestStatus;
    status.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    status.textColor = UIColor.secondaryLabelColor;
    status.textAlignment = NSTextAlignmentCenter;
    status.numberOfLines = 2;

    UILabel *percent = [UILabel new];
    percent.translatesAutoresizingMaskIntoConstraints = NO;
    percent.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
    percent.textColor = UIColor.tertiaryLabelColor;
    percent.textAlignment = NSTextAlignmentCenter;
    percent.text = [NSString stringWithFormat:@"%ld%%",
        (long)llround(MAX(0.0, MIN(1.0, self.latestProgress)) * 100.0)];

    UIStackView *stack = [[UIStackView alloc]
        initWithArrangedSubviews:@[title, spinner, progressView, status, percent]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentFill;
    stack.spacing = 14.0;
    [stack setCustomSpacing:22.0 afterView:title];
    [stack setCustomSpacing:18.0 afterView:spinner];

    [overlay addSubview:stack];
    [window addSubview:overlay];
    [NSLayoutConstraint activateConstraints:@[
        [overlay.leadingAnchor constraintEqualToAnchor:window.leadingAnchor],
        [overlay.trailingAnchor constraintEqualToAnchor:window.trailingAnchor],
        [overlay.topAnchor constraintEqualToAnchor:window.topAnchor],
        [overlay.bottomAnchor constraintEqualToAnchor:window.bottomAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor constant:-24.0],
        [stack.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [stack.widthAnchor constraintLessThanOrEqualToConstant:300.0],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:overlay.leadingAnchor constant:36.0],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:overlay.trailingAnchor constant:-36.0],
        [progressView.heightAnchor constraintEqualToConstant:4.0],
    ]];

    self.overlay = overlay;
    self.progressView = progressView;
    self.statusLabel = status;
    self.percentLabel = percent;
    self.spinner = spinner;
    NSLog(@"[StartupProgress] overlay shown progress=%.3f status=%@",
          self.latestProgress, self.latestStatus);
}

- (void)applyProgress:(double)progress status:(NSString *)status
{
    NSAssert(NSThread.isMainThread, @"startup UI must run on main thread");
    if (self.finished) return;
    progress = MAX(0.0, MIN(1.0, progress));
    if (progress >= self.latestProgress) self.latestProgress = progress;
    if (status.length) self.latestStatus = status;
    [self showIfNeeded];
    [self.progressView setProgress:(float)self.latestProgress animated:YES];
    self.statusLabel.text = self.latestStatus;
    self.percentLabel.text = [NSString stringWithFormat:@"%ld%%",
        (long)llround(self.latestProgress * 100.0)];
}

- (void)finishWithStatus:(NSString *)status
{
    NSAssert(NSThread.isMainThread, @"startup UI must run on main thread");
    if (self.finished) return;
    self.finished = YES;
    self.latestProgress = 1.0;
    self.latestStatus = status.length ? status : @"准备完成";

    FSStartupReloadBrowser();
    if (!self.overlay) return;

    [self.progressView setProgress:1.0 animated:YES];
    self.statusLabel.text = self.latestStatus;
    self.percentLabel.text = @"100%";
    [self.spinner stopAnimating];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.22 animations:^{
            self.overlay.alpha = 0.0;
        } completion:^(__unused BOOL finished) {
            [self.overlay removeFromSuperview];
            self.overlay = nil;
            self.progressView = nil;
            self.statusLabel = nil;
            self.percentLabel = nil;
            self.spinner = nil;
            NSLog(@"[StartupProgress] overlay finished");
        }];
    });
}

@end

__attribute__((constructor)) static void FSStartupProgressInstall(void)
{
    FSStartupProgressController *controller =
        [FSStartupProgressController sharedController];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;

    [center addObserverForName:UIApplicationDidFinishLaunchingNotification
                        object:nil queue:nil
                    usingBlock:^(__unused NSNotification *note) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [controller showIfNeeded];
        });
    }];

    [center addObserverForName:MCMFilzaStartupProgressNotification
                        object:nil queue:nil
                    usingBlock:^(NSNotification *note) {
        NSNumber *number = note.userInfo[MCMFilzaStartupProgressKey];
        NSString *status = note.userInfo[MCMFilzaStartupStatusKey];
        dispatch_async(dispatch_get_main_queue(), ^{
            [controller applyProgress:number.doubleValue status:status];
        });
    }];

    [center addObserverForName:MCMFilzaStartupCompleteNotification
                        object:nil queue:nil
                    usingBlock:^(NSNotification *note) {
        NSString *status = note.userInfo[MCMFilzaStartupStatusKey];
        dispatch_async(dispatch_get_main_queue(), ^{
            [controller finishWithStatus:status];
        });
    }];
}
