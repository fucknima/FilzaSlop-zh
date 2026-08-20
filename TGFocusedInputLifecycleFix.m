@import UIKit;
#import <objc/runtime.h>
#import <objc/message.h>

// iOS 27 compatibility for Filza's legacy RenameView.
//
// Filza's TGFocusedInput/RenameView predates the modern keyboard host. On iOS
// 27 the original input bar can be laid out at the physical bottom of the
// screen before the keyboard host is ready. Switching input methods rebuilds
// that host, which is why the bar only jumps above the keyboard afterwards.
//
// Do not fight that private layout with keyboard-height guesses or delayed
// transforms. For RenameView we bypass the legacy presentation layer only and
// keep Filza's original delegate contract for the actual rename operation. The
// replacement bar is constrained directly to UIKeyboardLayoutGuide.topAnchor,
// so its first frame is already above the keyboard.

static IMP gOrigRenameShow = NULL;
static const void *kRenameOverlayKey = &kRenameOverlayKey;

@interface FSModernRenameOverlay : NSObject <UITextFieldDelegate>
@property(nonatomic, weak) UIViewController *host;
@property(nonatomic, weak) id delegate;
@property(nonatomic, strong) id renameView;
@property(nonatomic, strong) UIView *overlay;
@property(nonatomic, strong) UIView *bar;
@property(nonatomic, strong) UIImageView *iconView;
@property(nonatomic, strong) UITextField *textField;
@property(nonatomic, strong) UIButton *cancelButton;
@property(nonatomic, strong) UIButton *doneButton;
@property(nonatomic, copy) NSString *originalName;
@property(nonatomic, assign) BOOL isDirectory;
@property(nonatomic, assign) BOOL dismissed;
- (instancetype)initWithRenameView:(id)renameView
                              host:(UIViewController *)host
                          delegate:(id)delegate
                       isDirectory:(BOOL)isDirectory;
- (void)present;
- (void)dismiss;
@end

static id FSMsgSendId1(id target, SEL selector, id arg) {
    if (!target || ![target respondsToSelector:selector]) return nil;
    return ((id(*)(id, SEL, id))objc_msgSend)(target, selector, arg);
}

static BOOL FSMsgSendBool2(id target, SEL selector, id arg1, id arg2) {
    if (!target || ![target respondsToSelector:selector]) return NO;
    return ((BOOL(*)(id, SEL, id, id))objc_msgSend)(target, selector, arg1, arg2);
}

static void FSMsgSendVoid2(id target, SEL selector, id arg1, id arg2) {
    if (!target || ![target respondsToSelector:selector]) return;
    ((void(*)(id, SEL, id, id))objc_msgSend)(target, selector, arg1, arg2);
}

@implementation FSModernRenameOverlay

- (instancetype)initWithRenameView:(id)renameView
                              host:(UIViewController *)host
                          delegate:(id)delegate
                       isDirectory:(BOOL)isDirectory {
    self = [super init];
    if (!self) return nil;
    _renameView = renameView;
    _host = host;
    _delegate = delegate;
    _isDirectory = isDirectory;

    NSString *name = FSMsgSendId1(delegate,
        NSSelectorFromString(@"nameForRenameView:"), renameView);
    _originalName = [name isKindOfClass:NSString.class] ? [name copy] : @"";
    return self;
}

- (UIView *)presentationRoot {
    UIViewController *host = self.host;
    if (!host) return nil;
    return host.view.window ?: host.view;
}

- (void)present {
    UIView *root = [self presentationRoot];
    if (!root || self.dismissed) return;

    UIView *overlay = [[UIView alloc] initWithFrame:CGRectZero];
    overlay.translatesAutoresizingMaskIntoConstraints = NO;
    // Match Filza's faded full-screen focus treatment without depending on its
    // legacy TGFocusedInput geometry.
    overlay.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.90];
    self.overlay = overlay;
    [root addSubview:overlay];
    [NSLayoutConstraint activateConstraints:@[
        [overlay.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [overlay.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [overlay.topAnchor constraintEqualToAnchor:root.topAnchor],
        [overlay.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
    ]];

    UIView *bar = [[UIView alloc] initWithFrame:CGRectZero];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    bar.backgroundColor = [UIColor systemGray5Color];
    self.bar = bar;
    [overlay addSubview:bar];

    // This is the core of the fix. No keyboard notifications, cached heights,
    // transforms, or first-responder timing assumptions are involved.
    UIKeyboardLayoutGuide *keyboardGuide = root.keyboardLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:overlay.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:overlay.trailingAnchor],
        [bar.bottomAnchor constraintEqualToAnchor:keyboardGuide.topAnchor],
        [bar.heightAnchor constraintEqualToConstant:54.0],
    ]];

    UIView *separator = [[UIView alloc] initWithFrame:CGRectZero];
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    separator.backgroundColor = [UIColor separatorColor];
    [bar addSubview:separator];
    [NSLayoutConstraint activateConstraints:@[
        [separator.leadingAnchor constraintEqualToAnchor:bar.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:bar.trailingAnchor],
        [separator.topAnchor constraintEqualToAnchor:bar.topAnchor],
        [separator.heightAnchor constraintEqualToConstant:0.5],
    ]];

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    cancel.translatesAutoresizingMaskIntoConstraints = NO;
    cancel.titleLabel.font = [UIFont systemFontOfSize:18.0 weight:UIFontWeightRegular];
    [cancel setTitle:@"Cancel" forState:UIControlStateNormal];
    [cancel addTarget:self action:@selector(cancelPressed:) forControlEvents:UIControlEventTouchUpInside];
    self.cancelButton = cancel;
    [bar addSubview:cancel];

    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    done.translatesAutoresizingMaskIntoConstraints = NO;
    done.titleLabel.font = [UIFont systemFontOfSize:18.0 weight:UIFontWeightSemibold];
    [done setTitle:@"Done" forState:UIControlStateNormal];
    [done addTarget:self action:@selector(donePressed:) forControlEvents:UIControlEventTouchUpInside];
    self.doneButton = done;
    [bar addSubview:done];

    UITextField *field = [[UITextField alloc] initWithFrame:CGRectZero];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.backgroundColor = UIColor.clearColor;
    field.borderStyle = UITextBorderStyleNone;
    field.font = [UIFont systemFontOfSize:19.0];
    field.textColor = UIColor.labelColor;
    field.tintColor = UIColor.systemBlueColor;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.returnKeyType = UIReturnKeyDone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.spellCheckingType = UITextSpellCheckingTypeNo;
    field.delegate = self;
    field.text = self.originalName;
    [field addTarget:self action:@selector(textChanged:) forControlEvents:UIControlEventEditingChanged];
    self.textField = field;
    [bar addSubview:field];

    [NSLayoutConstraint activateConstraints:@[
        [cancel.leadingAnchor constraintEqualToAnchor:bar.safeAreaLayoutGuide.leadingAnchor constant:14.0],
        [cancel.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [cancel.widthAnchor constraintGreaterThanOrEqualToConstant:68.0],

        [done.trailingAnchor constraintEqualToAnchor:bar.safeAreaLayoutGuide.trailingAnchor constant:-14.0],
        [done.centerYAnchor constraintEqualToAnchor:bar.centerYAnchor],
        [done.widthAnchor constraintGreaterThanOrEqualToConstant:58.0],

        [field.leadingAnchor constraintEqualToAnchor:cancel.trailingAnchor constant:10.0],
        [field.trailingAnchor constraintEqualToAnchor:done.leadingAnchor constant:-10.0],
        [field.topAnchor constraintEqualToAnchor:bar.topAnchor constant:4.0],
        [field.bottomAnchor constraintEqualToAnchor:bar.bottomAnchor constant:-4.0],
    ]];

    UIImage *icon = FSMsgSendId1(self.delegate,
        NSSelectorFromString(@"iconForRenameView:"), self.renameView);
    if ([icon isKindOfClass:UIImage.class]) {
        UIImageView *iconView = [[UIImageView alloc] initWithImage:icon];
        iconView.translatesAutoresizingMaskIntoConstraints = NO;
        iconView.contentMode = UIViewContentModeScaleAspectFit;
        self.iconView = iconView;
        [overlay addSubview:iconView];
        [NSLayoutConstraint activateConstraints:@[
            [iconView.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
            [iconView.bottomAnchor constraintEqualToAnchor:bar.topAnchor constant:-20.0],
            [iconView.widthAnchor constraintEqualToConstant:64.0],
            [iconView.heightAnchor constraintEqualToConstant:64.0],
        ]];
    }

    [self updateDoneState];
    [root layoutIfNeeded];

    // Become first responder only after the bar has a keyboard-guide
    // constraint. Therefore the very first keyboard animation carries the bar
    // to its final position; there is no covered intermediate frame.
    [field becomeFirstResponder];

    // Filza selects the basename but leaves the extension untouched for files.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.dismissed || !self.textField.isFirstResponder) return;
        NSString *text = self.textField.text ?: @"";
        NSUInteger selectionLength = text.length;
        if (!self.isDirectory) {
            NSRange dot = [text rangeOfString:@"." options:NSBackwardsSearch];
            if (dot.location != NSNotFound && dot.location > 0)
                selectionLength = dot.location;
        }
        UITextPosition *start = self.textField.beginningOfDocument;
        UITextPosition *end = [self.textField positionFromPosition:start
                                                            offset:(NSInteger)selectionLength];
        if (start && end)
            self.textField.selectedTextRange = [self.textField textRangeFromPosition:start toPosition:end];
    });

    NSLog(@"[RenameKeyboardFix-v2] presented modern overlay root=%@ keyboardGuide=%@ name=%@",
          NSStringFromClass(root.class), keyboardGuide, self.originalName);
}

- (BOOL)nameAlreadyExists:(NSString *)name {
    return FSMsgSendBool2(self.delegate,
        NSSelectorFromString(@"renameView:checkIfNameExisted:"), self.renameView, name);
}

- (void)updateDoneState {
    NSString *name = self.textField.text ?: @"";
    BOOL valid = name.length > 0 && ![name isEqualToString:self.originalName];
    if (valid && [self nameAlreadyExists:name]) valid = NO;
    self.doneButton.enabled = valid;
}

- (void)textChanged:(__unused UITextField *)sender {
    [self updateDoneState];
}

- (void)cancelPressed:(__unused UIButton *)sender {
    [self dismiss];
}

- (void)donePressed:(__unused UIButton *)sender {
    NSString *name = self.textField.text ?: @"";
    if (!self.doneButton.enabled || name.length == 0) return;

    // Keep the original RenameView instance as the protocol sender so Filza's
    // controller receives exactly the same delegate shape it expects.
    FSMsgSendVoid2(self.delegate,
        NSSelectorFromString(@"renameView:completeWithName:"), self.renameView, name);
    [self dismiss];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (self.doneButton.enabled) {
        [self donePressed:nil];
        return NO;
    }
    return YES;
}

- (void)dismiss {
    if (self.dismissed) return;
    self.dismissed = YES;
    [self.textField resignFirstResponder];

    UIView *overlay = self.overlay;
    id renameView = self.renameView;
    [UIView animateWithDuration:0.15 animations:^{
        overlay.alpha = 0.0;
    } completion:^(__unused BOOL finished) {
        [overlay removeFromSuperview];
        objc_setAssociatedObject(renameView, kRenameOverlayKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }];
}

@end

static void hook_Rename_showModern(id self, SEL _cmd, id vc, id delegate, BOOL isDirectory) {
    if (![vc isKindOfClass:UIViewController.class] || !delegate) {
        // Unexpected Filza build: preserve the original implementation rather
        // than breaking rename completely.
        if (gOrigRenameShow)
            ((void(*)(id, SEL, id, id, BOOL))gOrigRenameShow)(self, _cmd, vc, delegate, isDirectory);
        return;
    }

    FSModernRenameOverlay *old = objc_getAssociatedObject(self, kRenameOverlayKey);
    if ([old isKindOfClass:FSModernRenameOverlay.class]) [old dismiss];

    FSModernRenameOverlay *overlay = [[FSModernRenameOverlay alloc]
        initWithRenameView:self host:(UIViewController *)vc delegate:delegate
        isDirectory:isDirectory];
    objc_setAssociatedObject(self, kRenameOverlayKey, overlay,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [overlay present];
}

static void InstallModernRenameFix(void) {
    Class rename = NSClassFromString(@"RenameView");
    SEL selector = NSSelectorFromString(@"showInViewController:delegate:isDirectory:");
    Method method = rename ? class_getInstanceMethod(rename, selector) : NULL;
    if (!method) {
        NSLog(@"[RenameKeyboardFix-v2] RenameView selector not found");
        return;
    }

    gOrigRenameShow = method_getImplementation(method);
    method_setImplementation(method, (IMP)hook_Rename_showModern);
    NSLog(@"[RenameKeyboardFix-v2] installed modern RenameView presentation");
}

__attribute__((constructor))
static void RenameKeyboardFixInit(void) {
    // Tweak.m also hooks RenameView. Install on the next main-loop turn so this
    // layer is last and deliberately replaces only the presentation path.
    dispatch_async(dispatch_get_main_queue(), ^{
        InstallModernRenameFix();
    });
}
