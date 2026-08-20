@import UIKit;
#import <objc/runtime.h>

// Filza's TGFocusedInput predates the modern iOS keyboard host.  On recent
// iOS builds, assigning hiddenTextField.inputAccessoryView before the field
// becomes first responder is not sufficient by itself: the first keyboard can
// come up while mainInputView is still attached to TGFocusedInput.  Switching
// input methods rebuilds the input host, which is why the bar then jumps to the
// correct position.
//
// Keep the existing compatibility hooks in Tweak.m for now, but fix the actual
// lifecycle edge here: prepare the accessory before editing begins, then force
// a single input-view reload once the hidden field really is first responder.

static IMP gOrigShouldBeginEditing = NULL;
static IMP gOrigDidBeginEditing = NULL;
static IMP gOrigShowControlsOnKeyboard = NULL;
static IMP gOrigShowInViewController = NULL;

static BOOL TGFIGetViews(id self, UIView **mainOut, UITextField **hiddenOut) {
    if (!self) return NO;

    UIView *main = nil;
    UITextField *hidden = nil;

    @try {
        id value = [self valueForKey:@"mainInputView"];
        if ([value isKindOfClass:UIView.class]) main = value;
    } @catch (__unused NSException *e) {}

    @try {
        id value = [self valueForKey:@"hiddenTextField"];
        if ([value isKindOfClass:UITextField.class]) hidden = value;
    } @catch (__unused NSException *e) {}

    if (mainOut) *mainOut = main;
    if (hiddenOut) *hiddenOut = hidden;
    return main && hidden;
}

static void TGFIPrepareAccessory(id self) {
    UIView *main = nil;
    UITextField *hidden = nil;
    if (!TGFIGetViews(self, &main, &hidden)) return;

    // Preserve Filza's visible input bar dimensions.  Some builds create the
    // view with a zero/placeholder frame and size it later.
    CGRect frame = main.frame;
    if (CGRectGetWidth(frame) < 10.0) frame.size.width = UIScreen.mainScreen.bounds.size.width;
    if (CGRectGetHeight(frame) < 10.0) frame.size.height = 56.0;
    if (!CGRectEqualToRect(frame, main.frame)) {
        frame.origin = CGPointZero;
        main.frame = frame;
        main.autoresizingMask |= UIViewAutoresizingFlexibleWidth;
    }

    if (hidden.inputAccessoryView != main) {
        hidden.inputAccessoryView = main;
        NSLog(@"[KeyboardLifecycleFix] prepared accessory hidden=%p main=%p", hidden, main);
    }
}

static void TGFIMountAccessoryIfNeeded(id self, BOOL forceReload) {
    UIView *main = nil;
    UITextField *hidden = nil;
    if (!TGFIGetViews(self, &main, &hidden)) return;

    if (hidden.inputAccessoryView != main)
        hidden.inputAccessoryView = main;

    // The failure mode we are fixing is specifically this state:
    //   hidden is first responder + accessory property is set + main is still
    //   attached to the full-screen TGFocusedInput overlay.
    // reloadInputViews makes UIKit rebuild the keyboard host immediately, the
    // same transition that previously happened only after switching keyboards.
    BOOL stillInOverlay = [main isDescendantOfView:(UIView *)self];
    if (hidden.isFirstResponder && (forceReload || stillInOverlay)) {
        [hidden reloadInputViews];
        NSLog(@"[KeyboardLifecycleFix] reloaded input views hidden=%p overlay=%d super=%@",
              hidden, stillInOverlay, NSStringFromClass(main.superview.class));
    }
}

static BOOL hook_TGFI_textFieldShouldBeginEditing(id self, SEL _cmd, UITextField *textField) {
    // Install before UIKit asks the responder for its input views.
    TGFIPrepareAccessory(self);

    BOOL result = YES;
    if (gOrigShouldBeginEditing)
        result = ((BOOL(*)(id, SEL, UITextField *))gOrigShouldBeginEditing)(self, _cmd, textField);

    // The original callback may rebuild Filza's input UI, so verify once more.
    if (result) TGFIPrepareAccessory(self);
    return result;
}

static void hook_TGFI_textFieldDidBeginEditing(id self, SEL _cmd, UITextField *textField) {
    if (gOrigDidBeginEditing)
        ((void(*)(id, SEL, UITextField *))gOrigDidBeginEditing)(self, _cmd, textField);

    // At this point the hidden field is actually first responder.  Mount now,
    // not on a guessed 80/300 ms keyboard timer.
    TGFIMountAccessoryIfNeeded(self, NO);

    // Let UIKit finish the current responder callback, then verify the host one
    // more time.  This is a run-loop ordering fix, not a keyboard-height delay.
    __weak id weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        id strongSelf = weakSelf;
        if (strongSelf) TGFIMountAccessoryIfNeeded(strongSelf, NO);
    });
}

static void hook_TGFI_showControlsButtonOnkeyboard(id self, SEL _cmd) {
    if (gOrigShowControlsOnKeyboard)
        ((void(*)(id, SEL))gOrigShowControlsOnKeyboard)(self, _cmd);

    // Filza calls this while arranging the controls around the keyboard.  Its
    // own implementation can re-parent mainInputView, so repair after it runs.
    TGFIMountAccessoryIfNeeded(self, NO);
}

static void hook_TGFI_showInViewController(id self, SEL _cmd, UIViewController *controller) {
    // The implementation we capture may already be Tweak.m's compatibility
    // hook.  Chain through it; do not bypass the existing behavior.
    if (gOrigShowInViewController)
        ((void(*)(id, SEL, UIViewController *))gOrigShowInViewController)(self, _cmd, controller);

    // showInViewController: can create/replace hiddenTextField.  Prepare the
    // final instance after Filza has completed that setup.
    TGFIPrepareAccessory(self);
    dispatch_async(dispatch_get_main_queue(), ^{
        TGFIMountAccessoryIfNeeded(self, NO);
    });
}

static void TGFIInstallLifecycleFix(void) {
    Class cls = NSClassFromString(@"TGFocusedInput");
    if (!cls) {
        NSLog(@"[KeyboardLifecycleFix] TGFocusedInput not found");
        return;
    }

    Method shouldBegin = class_getInstanceMethod(cls, NSSelectorFromString(@"textFieldShouldBeginEditing:"));
    if (shouldBegin) {
        gOrigShouldBeginEditing = method_getImplementation(shouldBegin);
        method_setImplementation(shouldBegin, (IMP)hook_TGFI_textFieldShouldBeginEditing);
    }

    Method didBegin = class_getInstanceMethod(cls, NSSelectorFromString(@"textFieldDidBeginEditing:"));
    if (didBegin) {
        gOrigDidBeginEditing = method_getImplementation(didBegin);
        method_setImplementation(didBegin, (IMP)hook_TGFI_textFieldDidBeginEditing);
    }

    Method showControls = class_getInstanceMethod(cls, NSSelectorFromString(@"showControlsButtonOnkeyboard"));
    if (showControls) {
        gOrigShowControlsOnKeyboard = method_getImplementation(showControls);
        method_setImplementation(showControls, (IMP)hook_TGFI_showControlsButtonOnkeyboard);
    }

    Method show = class_getInstanceMethod(cls, NSSelectorFromString(@"showInViewController:"));
    if (show) {
        gOrigShowInViewController = method_getImplementation(show);
        method_setImplementation(show, (IMP)hook_TGFI_showInViewController);
    }

    NSLog(@"[KeyboardLifecycleFix] installed should=%d did=%d controls=%d show=%d",
          shouldBegin != NULL, didBegin != NULL, showControls != NULL, show != NULL);
}

__attribute__((constructor))
static void TGFIKeyboardLifecycleFixInit(void) {
    // Tweak.m also swizzles TGFocusedInput during dylib initialization.  Install
    // on the next main-loop turn so this layer is last and chains through the
    // already-installed implementation instead of racing constructor order.
    dispatch_async(dispatch_get_main_queue(), ^{
        TGFIInstallLifecycleFix();
    });
}
