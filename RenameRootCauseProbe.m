@import UIKit;
#import <objc/runtime.h>
#import <objc/message.h>

// Diagnostic-only probe for Filza's original TGFocusedInput / RenameView path.
// IMPORTANT: this file does not move views, change constraints, set an
// inputAccessoryView, reload input views, or otherwise attempt to fix layout.
// It only records what Filza/UIKit actually do before and after the first
// keyboard presentation and an input-method switch.

static IMP gOrigRenameShow = NULL;
static IMP gOrigTGShow = NULL;
static IMP gOrigShowControls = NULL;
static IMP gOrigShouldBegin = NULL;
static IMP gOrigDidBegin = NULL;
static IMP gOrigDidEnd = NULL;
static IMP gOrigLayoutSubviews = NULL;
static IMP gOrigDidMoveToWindow = NULL;
static NSString *gProbePath = nil;
static const void *kLastLayoutSignatureKey = &kLastLayoutSignatureKey;

static NSString *ProbeDocumentsPath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                          NSUserDomainMask,
                                                          YES).firstObject;
    return [docs stringByAppendingPathComponent:@"rename-root-cause.log"];
}

static void ProbeAppend(NSString *line) {
    if (!line.length) return;
    if (!gProbePath) gProbePath = ProbeDocumentsPath();
    NSString *full = [line stringByAppendingString:@"\n"];
    NSData *data = [full dataUsingEncoding:NSUTF8StringEncoding];
    if (![[NSFileManager defaultManager] fileExistsAtPath:gProbePath]) {
        [data writeToFile:gProbePath atomically:YES];
    } else {
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:gProbePath];
        if (h) {
            @try {
                [h seekToEndOfFile];
                [h writeData:data];
                [h closeFile];
            } @catch (__unused NSException *e) {}
        }
    }
    NSLog(@"[RenameRootProbe] %@", line);
}

static void ProbeLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
static void ProbeLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSTimeInterval t = NSDate.date.timeIntervalSince1970;
    ProbeAppend([NSString stringWithFormat:@"%.3f %@", t, body]);
}

static id ProbeValue(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *e) { return nil; }
}

static NSString *ProbeRect(CGRect r) {
    return [NSString stringWithFormat:@"{%.1f,%.1f %.1fx%.1f}",
            r.origin.x, r.origin.y, r.size.width, r.size.height];
}

static NSString *ProbeTransform(CGAffineTransform t) {
    return [NSString stringWithFormat:@"[%.3f %.3f %.3f %.3f %.1f %.1f]",
            t.a, t.b, t.c, t.d, t.tx, t.ty];
}

static NSString *ProbeViewDescription(UIView *v) {
    if (![v isKindOfClass:UIView.class]) return @"<nil>";
    UIWindow *w = v.window;
    CGRect wr = CGRectNull;
    if (w) {
        @try { wr = [v convertRect:v.bounds toView:w]; }
        @catch (__unused NSException *e) {}
    }
    return [NSString stringWithFormat:
        @"%@(%p) frame=%@ bounds=%@ winRect=%@ hidden=%d alpha=%.2f transform=%@ super=%@(%p) window=%@(%p)",
        NSStringFromClass(v.class), v,
        ProbeRect(v.frame), ProbeRect(v.bounds), ProbeRect(wr),
        v.hidden, v.alpha, ProbeTransform(v.transform),
        NSStringFromClass(v.superview.class), v.superview,
        NSStringFromClass(w.class), w];
}

static void ProbeConstraintDump(UIView *main) {
    if (![main isKindOfClass:UIView.class]) return;
    UIView *superview = main.superview;
    if (!superview) return;
    NSUInteger emitted = 0;
    for (NSLayoutConstraint *c in superview.constraints) {
        if (c.firstItem != main && c.secondItem != main) continue;
        ProbeLog(@"  CONSTRAINT %@.%ld %@ %@.%ld * %.2f + %.2f priority=%.0f active=%d",
                 NSStringFromClass([c.firstItem class]), (long)c.firstAttribute,
                 (c.relation == NSLayoutRelationEqual ? @"==" : (c.relation == NSLayoutRelationLessThanOrEqual ? @"<=" : @">=")),
                 NSStringFromClass([c.secondItem class]), (long)c.secondAttribute,
                 c.multiplier, c.constant, c.priority, c.active);
        if (++emitted >= 20) break;
    }
}

static NSString *ProbeLayoutSignature(id self) {
    UIView *main = ProbeValue(self, @"mainInputView");
    UITextField *hidden = ProbeValue(self, @"hiddenTextField");
    UITextField *input = ProbeValue(self, @"inputTextField");
    return [NSString stringWithFormat:@"%@|%@|%@|%@|%@|%d|%d|%@|%@",
            ProbeRect(((UIView *)self).frame),
            ProbeRect(main.frame),
            ProbeRect(hidden.frame),
            ProbeRect(input.frame),
            NSStringFromClass(main.superview.class),
            hidden.isFirstResponder, input.isFirstResponder,
            NSStringFromClass(hidden.inputAccessoryView.class),
            NSStringFromClass(input.inputAccessoryView.class)];
}

static void ProbeDump(id self, NSString *tag) {
    if (!self) return;
    UIView *container = [self isKindOfClass:UIView.class] ? self : nil;
    UIView *main = ProbeValue(self, @"mainInputView");
    UITextField *hidden = ProbeValue(self, @"hiddenTextField");
    UITextField *input = ProbeValue(self, @"inputTextField");
    UIView *background = ProbeValue(self, @"inputBackground");
    UIButton *done = ProbeValue(self, @"doneButton");
    UIButton *cancel = ProbeValue(self, @"cancelButton");

    ProbeLog(@"DUMP %@ class=%@", tag, NSStringFromClass([self class]));
    ProbeLog(@"  SELF   %@", ProbeViewDescription(container));
    ProbeLog(@"  MAIN   %@", ProbeViewDescription(main));
    ProbeLog(@"  HIDDEN %@ first=%d accessory=%@(%p) accessorySuper=%@",
             ProbeViewDescription(hidden), hidden.isFirstResponder,
             NSStringFromClass(hidden.inputAccessoryView.class), hidden.inputAccessoryView,
             NSStringFromClass(hidden.inputAccessoryView.superview.class));
    ProbeLog(@"  INPUT  %@ first=%d accessory=%@(%p) accessorySuper=%@",
             ProbeViewDescription(input), input.isFirstResponder,
             NSStringFromClass(input.inputAccessoryView.class), input.inputAccessoryView,
             NSStringFromClass(input.inputAccessoryView.superview.class));
    ProbeLog(@"  BG     %@", ProbeViewDescription(background));
    ProbeLog(@"  DONE   %@", ProbeViewDescription(done));
    ProbeLog(@"  CANCEL %@", ProbeViewDescription(cancel));

    UIWindow *w = container.window ?: UIApplication.sharedApplication.keyWindow;
    if (w) {
        CGRect guide = CGRectZero;
        @try { guide = w.keyboardLayoutGuide.layoutFrame; }
        @catch (__unused NSException *e) {}
        ProbeLog(@"  WINDOW %@ frame=%@ bounds=%@ safe={%.1f %.1f %.1f %.1f} keyboardGuide=%@",
                 NSStringFromClass(w.class), ProbeRect(w.frame), ProbeRect(w.bounds),
                 w.safeAreaInsets.top, w.safeAreaInsets.left,
                 w.safeAreaInsets.bottom, w.safeAreaInsets.right,
                 ProbeRect(guide));
    }

    UITextInputMode *mode = UITextInputMode.currentInputMode;
    ProbeLog(@"  INPUTMODE %@", mode.primaryLanguage ?: @"<nil>");
    ProbeConstraintDump(main);
}

static UIView *ProbeFindTG(UIView *view, Class cls) {
    if (!view) return nil;
    if ([view isKindOfClass:cls]) return view;
    for (UIView *sub in view.subviews) {
        UIView *found = ProbeFindTG(sub, cls);
        if (found) return found;
    }
    return nil;
}

static void ProbeDumpActive(NSString *tag) {
    Class cls = NSClassFromString(@"TGFocusedInput");
    if (!cls) return;
    BOOL foundAny = NO;
    for (UIWindow *w in UIApplication.sharedApplication.windows) {
        UIView *found = ProbeFindTG(w, cls);
        if (found) {
            foundAny = YES;
            ProbeDump(found, tag);
        }
    }
    if (!foundAny) ProbeLog(@"DUMP %@ no TGFocusedInput found in windows", tag);
}

static void ProbeSchedule(id self, NSString *prefix) {
    NSArray<NSNumber *> *delays = @[@0, @50, @150, @350, @700];
    __weak id weakSelf = self;
    for (NSNumber *ms in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(ms.longLongValue * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            id strongSelf = weakSelf;
            if (strongSelf) ProbeDump(strongSelf,
                [NSString stringWithFormat:@"%@ +%@ms", prefix, ms]);
        });
    }
}

static void HookRenameShow(id self, SEL _cmd, id vc, id delegate, BOOL isDir) {
    ProbeLog(@"CALL -[RenameView showInViewController:delegate:isDirectory:] BEFORE vc=%@ delegate=%@ isDir=%d",
             NSStringFromClass([vc class]), NSStringFromClass([delegate class]), isDir);
    ProbeDump(self, @"Rename show BEFORE");
    ((void(*)(id,SEL,id,id,BOOL))gOrigRenameShow)(self,_cmd,vc,delegate,isDir);
    ProbeLog(@"CALL -[RenameView showInViewController:delegate:isDirectory:] AFTER");
    ProbeDump(self, @"Rename show AFTER");
    ProbeSchedule(self, @"Rename show");
}

static void HookTGShow(id self, SEL _cmd, id vc) {
    ProbeLog(@"CALL -[TGFocusedInput showInViewController:] BEFORE vc=%@", NSStringFromClass([vc class]));
    ProbeDump(self, @"TG show BEFORE");
    ((void(*)(id,SEL,id))gOrigTGShow)(self,_cmd,vc);
    ProbeLog(@"CALL -[TGFocusedInput showInViewController:] AFTER");
    ProbeDump(self, @"TG show AFTER");
}

static void HookShowControls(id self, SEL _cmd) {
    ProbeLog(@"CALL -[TGFocusedInput showControlsButtonOnkeyboard] BEFORE");
    ProbeDump(self, @"controls BEFORE");
    ((void(*)(id,SEL))gOrigShowControls)(self,_cmd);
    ProbeLog(@"CALL -[TGFocusedInput showControlsButtonOnkeyboard] AFTER");
    ProbeDump(self, @"controls AFTER");
}

static BOOL HookShouldBegin(id self, SEL _cmd, id field) {
    ProbeLog(@"CALL textFieldShouldBeginEditing field=%@(%p) BEFORE", NSStringFromClass([field class]), field);
    ProbeDump(self, @"shouldBegin BEFORE");
    BOOL result = ((BOOL(*)(id,SEL,id))gOrigShouldBegin)(self,_cmd,field);
    ProbeLog(@"CALL textFieldShouldBeginEditing AFTER result=%d", result);
    ProbeDump(self, @"shouldBegin AFTER");
    return result;
}

static void HookDidBegin(id self, SEL _cmd, id field) {
    ProbeLog(@"CALL textFieldDidBeginEditing field=%@(%p) BEFORE", NSStringFromClass([field class]), field);
    ProbeDump(self, @"didBegin BEFORE");
    ((void(*)(id,SEL,id))gOrigDidBegin)(self,_cmd,field);
    ProbeLog(@"CALL textFieldDidBeginEditing AFTER");
    ProbeDump(self, @"didBegin AFTER");
    ProbeSchedule(self, @"didBegin");
}

static void HookDidEnd(id self, SEL _cmd, id field) {
    ProbeLog(@"CALL textFieldDidEndEditing field=%@(%p) BEFORE", NSStringFromClass([field class]), field);
    ProbeDump(self, @"didEnd BEFORE");
    ((void(*)(id,SEL,id))gOrigDidEnd)(self,_cmd,field);
    ProbeLog(@"CALL textFieldDidEndEditing AFTER");
    ProbeDump(self, @"didEnd AFTER");
}

static void HookLayoutSubviews(id self, SEL _cmd) {
    ((void(*)(id,SEL))gOrigLayoutSubviews)(self,_cmd);
    NSString *sig = ProbeLayoutSignature(self);
    NSString *last = objc_getAssociatedObject(self, kLastLayoutSignatureKey);
    if (![sig isEqualToString:last]) {
        objc_setAssociatedObject(self, kLastLayoutSignatureKey, sig,
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
        ProbeLog(@"CALL layoutSubviews state changed");
        ProbeDump(self, @"layoutSubviews");
    }
}

static void HookDidMoveToWindow(id self, SEL _cmd) {
    ((void(*)(id,SEL))gOrigDidMoveToWindow)(self,_cmd);
    ProbeLog(@"CALL didMoveToWindow window=%@(%p)",
             NSStringFromClass(((UIView *)self).window.class), ((UIView *)self).window);
    ProbeDump(self, @"didMoveToWindow");
}

static void ProbeInstallMethod(Class cls, SEL sel, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) {
        ProbeLog(@"INSTALL missing %@ %@", NSStringFromClass(cls), NSStringFromSelector(sel));
        return;
    }
    IMP imp = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    *original = imp;

    // If the method is inherited, add an override on TGFocusedInput rather than
    // replacing UIView/UIResponder's implementation globally.
    if (!class_addMethod(cls, sel, replacement, types))
        method_setImplementation(method, replacement);

    ProbeLog(@"INSTALL %@ %@ original=%p replacement=%p",
             NSStringFromClass(cls), NSStringFromSelector(sel), imp, replacement);
}

static void ProbeKeyboardNotification(NSNotification *note) {
    NSDictionary *u = note.userInfo;
    CGRect begin = [u[UIKeyboardFrameBeginUserInfoKey] CGRectValue];
    CGRect end = [u[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    double dur = [u[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    NSInteger curve = [u[UIKeyboardAnimationCurveUserInfoKey] integerValue];
    ProbeLog(@"NOTIFY %@ begin=%@ end=%@ duration=%.3f curve=%ld mode=%@",
             note.name, ProbeRect(begin), ProbeRect(end), dur, (long)curve,
             UITextInputMode.currentInputMode.primaryLanguage ?: @"<nil>");
    ProbeDumpActive(note.name);
}

static void ProbeInputModeChanged(NSNotification *note) {
    ProbeLog(@"NOTIFY %@ mode=%@", note.name,
             UITextInputMode.currentInputMode.primaryLanguage ?: @"<nil>");
    ProbeDumpActive(@"INPUT MODE CHANGED");
    dispatch_async(dispatch_get_main_queue(), ^{
        ProbeDumpActive(@"INPUT MODE CHANGED next runloop");
    });
}

static void InstallRenameRootCauseProbe(void) {
    gProbePath = ProbeDocumentsPath();
    [[NSFileManager defaultManager] removeItemAtPath:gProbePath error:nil];
    ProbeLog(@"=== Rename root-cause probe start ===");
    ProbeLog(@"OS=%@ device=%@ bundle=%@ screen=%@ log=%@",
             UIDevice.currentDevice.systemVersion,
             UIDevice.currentDevice.model,
             NSBundle.mainBundle.bundleIdentifier,
             ProbeRect(UIScreen.mainScreen.bounds), gProbePath);

    Class tg = NSClassFromString(@"TGFocusedInput");
    Class rename = NSClassFromString(@"RenameView");
    if (!tg || !rename) {
        ProbeLog(@"FATAL classes tg=%@ rename=%@", tg, rename);
        return;
    }

    ProbeInstallMethod(rename,
        NSSelectorFromString(@"showInViewController:delegate:isDirectory:"),
        (IMP)HookRenameShow, &gOrigRenameShow);
    ProbeInstallMethod(tg, NSSelectorFromString(@"showInViewController:"),
        (IMP)HookTGShow, &gOrigTGShow);
    ProbeInstallMethod(tg, NSSelectorFromString(@"showControlsButtonOnkeyboard"),
        (IMP)HookShowControls, &gOrigShowControls);
    ProbeInstallMethod(tg, NSSelectorFromString(@"textFieldShouldBeginEditing:"),
        (IMP)HookShouldBegin, &gOrigShouldBegin);
    ProbeInstallMethod(tg, NSSelectorFromString(@"textFieldDidBeginEditing:"),
        (IMP)HookDidBegin, &gOrigDidBegin);
    ProbeInstallMethod(tg, NSSelectorFromString(@"textFieldDidEndEditing:"),
        (IMP)HookDidEnd, &gOrigDidEnd);
    ProbeInstallMethod(tg, @selector(layoutSubviews),
        (IMP)HookLayoutSubviews, &gOrigLayoutSubviews);
    ProbeInstallMethod(tg, @selector(didMoveToWindow),
        (IMP)HookDidMoveToWindow, &gOrigDidMoveToWindow);

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    NSArray<NSNotificationName> *keyboardNames = @[
        UIKeyboardWillShowNotification,
        UIKeyboardDidShowNotification,
        UIKeyboardWillChangeFrameNotification,
        UIKeyboardDidChangeFrameNotification,
        UIKeyboardWillHideNotification,
        UIKeyboardDidHideNotification,
    ];
    for (NSNotificationName n in keyboardNames) {
        [nc addObserverForName:n object:nil queue:NSOperationQueue.mainQueue
                   usingBlock:^(NSNotification *note) { ProbeKeyboardNotification(note); }];
    }
    [nc addObserverForName:UITextInputCurrentInputModeDidChangeNotification
                    object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) { ProbeInputModeChanged(note); }];

    ProbeLog(@"=== Probe installed; reproduce: first Rename -> switch keyboard once -> Cancel ===");
}

__attribute__((constructor))
static void RenameRootCauseProbeInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        InstallRenameRootCauseProbe();
    });
}
