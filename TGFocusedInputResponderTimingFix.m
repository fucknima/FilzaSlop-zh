#include "FSLog.h"
@import UIKit;
#import <objc/runtime.h>

// iOS 27 compatibility for Filza's legacy TGFocusedInput flow.
//
// The supplied Filza binary does this sequence:
//   1. hiddenTextField.inputAccessoryView = mainInputView
//   2. hiddenTextField becomes first responder
//   3. textFieldDidBeginEditing(hiddenTextField) schedules, after 100 ms,
//      inputTextField.becomeFirstResponder()
//
// inputTextField itself lives inside mainInputView. On iOS 27 that fixed 100 ms
// hand-off can happen before UIKit commits the first keyboard/accessory host,
// leaving UIKeyboardItemContainerView at the bottom of the screen. Waiting all
// the way for UIKeyboardDidShow fixes the race, but makes the edit field appear
// only after the keyboard animation finishes.
//
// Final strategy:
//   - suppress Filza's fixed 100 ms hidden-field branch;
//   - wait for UIKeyboardWillShow, which means UIKit has committed a real
//     keyboard presentation;
//   - on the next main-loop turn, verify mainInputView is actually mounted in a
//     separate keyboard window, then perform Filza's intended responder handoff;
//   - retain UIKeyboardDidShow and a long timeout only as fallbacks.
//
// We never move views, change constraints, replace the UI, assign a different
// accessory view, or call reloadInputViews.

static IMP gOrigTGFocusedDidBegin = NULL;
static const void *kKeyboardWillShowObserverKey = &kKeyboardWillShowObserverKey;
static const void *kKeyboardDidShowObserverKey = &kKeyboardDidShowObserverKey;
static const void *kKeyboardFocusGenerationKey = &kKeyboardFocusGenerationKey;

static id TGFIValue(id self, NSString *key) {
    if (!self) return nil;
    @try { return [self valueForKey:key]; }
    @catch (__unused NSException *e) { return nil; }
}

static void TGFIRemoveObserverForKey(id self, const void *key) {
    id token = objc_getAssociatedObject(self, key);
    if (!token) return;
    [NSNotificationCenter.defaultCenter removeObserver:token];
    objc_setAssociatedObject(self, key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void TGFIRemovePendingObservers(id self) {
    TGFIRemoveObserverForKey(self, kKeyboardWillShowObserverKey);
    TGFIRemoveObserverForKey(self, kKeyboardDidShowObserverKey);
}

static BOOL TGFICurrentGenerationMatches(id self, NSUInteger generation) {
    NSNumber *current = objc_getAssociatedObject(self, kKeyboardFocusGenerationKey);
    return current.unsignedIntegerValue == generation;
}

static BOOL TGFIKeyboardHostCommitted(id self) {
    if (![self isKindOfClass:UIView.class]) return NO;

    UIView *main = TGFIValue(self, @"mainInputView");
    UITextField *hidden = TGFIValue(self, @"hiddenTextField");
    if (![main isKindOfClass:UIView.class] ||
        ![hidden isKindOfClass:UITextField.class]) return NO;

    UIWindow *appWindow = ((UIView *)self).window;
    UIWindow *keyboardWindow = main.window;

    // This is the state captured in the device probe once UIKit has taken
    // ownership of the accessory: hidden still owns mainInputView as its
    // inputAccessoryView, while mainInputView has been re-parented into a
    // keyboard-host window (UITextEffectsWindow on the tested iOS 27 build).
    if (!appWindow || !keyboardWindow || keyboardWindow == appWindow) return NO;
    if (!main.superview || hidden.inputAccessoryView != main) return NO;
    if (CGRectGetWidth(main.bounds) < 1.0 || CGRectGetHeight(main.bounds) < 1.0) return NO;

    return YES;
}

static BOOL TGFIFocusVisibleFieldIfStillNeeded(id self, NSString *reason,
                                                BOOL requireCommittedHost) {
    UITextField *hidden = TGFIValue(self, @"hiddenTextField");
    UITextField *input = TGFIValue(self, @"inputTextField");
    if (![hidden isKindOfClass:UITextField.class] ||
        ![input isKindOfClass:UITextField.class]) return NO;

    if (!hidden.isFirstResponder || input.isFirstResponder ||
        ![self isKindOfClass:UIView.class] || !((UIView *)self).window)
        return NO;

    if (requireCommittedHost && !TGFIKeyboardHostCommitted(self)) {
        FSLog(@"[RenameResponderFix] %@ arrived but keyboard host is not committed yet",
              reason);
        return NO;
    }

    UIView *main = TGFIValue(self, @"mainInputView");
    FSLog(@"[RenameResponderFix] focus input after %@ hidden=%p input=%p mainWindow=%@ super=%@",
          reason, hidden, input,
          NSStringFromClass(main.window.class), NSStringFromClass(main.superview.class));
    return [input becomeFirstResponder];
}

static void hook_TGFocused_textFieldDidBeginEditing(id self, SEL _cmd,
                                                     UITextField *field) {
    UITextField *hidden = TGFIValue(self, @"hiddenTextField");

    if (![hidden isKindOfClass:UITextField.class] || field != hidden) {
        // Preserve Filza's original visible-input branch. Disassembly shows it
        // sets _blockHiddenTextField and calls initiateUI: (RenameView uses that
        // to select the filename excluding the extension).
        if (gOrigTGFocusedDidBegin)
            ((void(*)(id,SEL,UITextField *))gOrigTGFocusedDidBegin)(self, _cmd, field);
        return;
    }

    // Do not call Filza's hidden-field branch. Its only behavior is a fixed
    // dispatch_after(100 ms) -> inputTextField.becomeFirstResponder().
    TGFIRemovePendingObservers(self);

    NSUInteger generation =
        [objc_getAssociatedObject(self, kKeyboardFocusGenerationKey) unsignedIntegerValue] + 1;
    objc_setAssociatedObject(self, kKeyboardFocusGenerationKey, @(generation),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak id weakSelf = self;

    __block id willToken = nil;
    willToken = [NSNotificationCenter.defaultCenter
        addObserverForName:UIKeyboardWillShowNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *note) {
        id strongSelf = weakSelf;
        if (!strongSelf) {
            if (willToken) [NSNotificationCenter.defaultCenter removeObserver:willToken];
            return;
        }
        if (!TGFICurrentGenerationMatches(strongSelf, generation)) return;

        CGRect endFrame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
        if (CGRectGetWidth(endFrame) < 1.0 || CGRectGetHeight(endFrame) < 1.0) return;

        // Never change responder from inside UIKit's keyboard notification
        // callback itself. One main-loop turn lets UIKit commit the host/window
        // transaction first, while still being far earlier than DidShow.
        dispatch_async(dispatch_get_main_queue(), ^{
            id innerSelf = weakSelf;
            if (!innerSelf || !TGFICurrentGenerationMatches(innerSelf, generation)) return;
            if (TGFIFocusVisibleFieldIfStillNeeded(innerSelf,
                    @"UIKeyboardWillShow + next runloop", YES)) {
                TGFIRemovePendingObservers(innerSelf);
            }
        });
    }];
    objc_setAssociatedObject(self, kKeyboardWillShowObserverKey, willToken,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Proven-safe fallback from the previous test build. This remains in case a
    // keyboard implementation sends WillShow before the accessory is mounted.
    __block id didToken = nil;
    didToken = [NSNotificationCenter.defaultCenter
        addObserverForName:UIKeyboardDidShowNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *note) {
        id strongSelf = weakSelf;
        if (!strongSelf) {
            if (didToken) [NSNotificationCenter.defaultCenter removeObserver:didToken];
            return;
        }
        if (!TGFICurrentGenerationMatches(strongSelf, generation)) return;

        if (TGFIFocusVisibleFieldIfStillNeeded(strongSelf,
                @"UIKeyboardDidShow fallback", NO)) {
            TGFIRemovePendingObservers(strongSelf);
        }
    }];
    objc_setAssociatedObject(self, kKeyboardDidShowObserverKey, didToken,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Hardware keyboards / unusual input methods may emit neither notification.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 900 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        id strongSelf = weakSelf;
        if (!strongSelf || !TGFICurrentGenerationMatches(strongSelf, generation)) return;
        if (TGFIFocusVisibleFieldIfStillNeeded(strongSelf,
                @"900ms fallback", NO)) {
            TGFIRemovePendingObservers(strongSelf);
        }
    });

    FSLog(@"[RenameResponderFix] hidden field began; waiting for keyboard WillShow commit");
}

static void InstallTGFocusedResponderTimingFix(void) {
    Class cls = NSClassFromString(@"TGFocusedInput");
    SEL sel = NSSelectorFromString(@"textFieldDidBeginEditing:");
    Method method = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!method) {
        FSLog(@"[RenameResponderFix] TGFocusedInput textFieldDidBeginEditing: not found");
        return;
    }

    gOrigTGFocusedDidBegin = method_getImplementation(method);
    method_setImplementation(method, (IMP)hook_TGFocused_textFieldDidBeginEditing);
    FSLog(@"[RenameResponderFix] installed original=%p replacement=%p",
          gOrigTGFocusedDidBegin, hook_TGFocused_textFieldDidBeginEditing);
}

__attribute__((constructor))
static void TGFocusedResponderTimingFixInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        InstallTGFocusedResponderTimingFix();
    });
}
