@import UIKit;
#import <objc/runtime.h>

// iOS 27 compatibility for Filza's legacy TGFocusedInput flow.
//
// The original Filza binary does this sequence:
//   1. hiddenTextField.inputAccessoryView = mainInputView
//   2. hiddenTextField becomes first responder
//   3. textFieldDidBeginEditing(hiddenTextField) schedules, after 100 ms,
//      inputTextField.becomeFirstResponder()
//
// inputTextField itself lives *inside* mainInputView. On iOS 27 the 100 ms
// hand-off occurs while the keyboard/accessory host is still presenting. The
// first presentation is therefore interrupted and UIKeyboardItemContainerView
// can remain at the physical bottom of the app instead of finishing its normal
// keyboard-attached layout. Changing input mode later rebuilds the keyboard
// host, which is why the same view suddenly moves to the correct position.
//
// Do not move views, change constraints, install a replacement UI, or call
// reloadInputViews. We only replace the hidden-field branch of
// textFieldDidBeginEditing: and perform Filza's intended responder hand-off
// after UIKit reports that the keyboard presentation has completed.

static IMP gOrigTGFocusedDidBegin = NULL;
static const void *kKeyboardDidShowObserverKey = &kKeyboardDidShowObserverKey;
static const void *kKeyboardFocusGenerationKey = &kKeyboardFocusGenerationKey;

static id TGFIValue(id self, NSString *key) {
    if (!self) return nil;
    @try { return [self valueForKey:key]; }
    @catch (__unused NSException *e) { return nil; }
}

static void TGFIRemovePendingObserver(id self) {
    id token = objc_getAssociatedObject(self, kKeyboardDidShowObserverKey);
    if (token) {
        [NSNotificationCenter.defaultCenter removeObserver:token];
        objc_setAssociatedObject(self, kKeyboardDidShowObserverKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void TGFIFocusVisibleFieldIfStillNeeded(id self, NSString *reason) {
    UITextField *hidden = TGFIValue(self, @"hiddenTextField");
    UITextField *input = TGFIValue(self, @"inputTextField");
    if (![hidden isKindOfClass:UITextField.class] ||
        ![input isKindOfClass:UITextField.class]) return;

    // Only complete the hand-off Filza originally wanted. If the user has
    // already cancelled, another responder won, or the view left its window,
    // leave the responder chain alone.
    if (!hidden.isFirstResponder || input.isFirstResponder || !((UIView *)self).window)
        return;

    NSLog(@"[RenameResponderFix] focus input after %@ hidden=%p input=%p",
          reason, hidden, input);
    [input becomeFirstResponder];
}

static void hook_TGFocused_textFieldDidBeginEditing(id self, SEL _cmd,
                                                     UITextField *field) {
    UITextField *hidden = TGFIValue(self, @"hiddenTextField");

    if (![hidden isKindOfClass:UITextField.class] || field != hidden) {
        // Preserve Filza's original inputTextField branch. That branch sets
        // _blockHiddenTextField and calls initiateUI: for the visible field.
        if (gOrigTGFocusedDidBegin)
            ((void(*)(id,SEL,UITextField *))gOrigTGFocusedDidBegin)(self, _cmd, field);
        return;
    }

    // IMPORTANT: do not call the original hiddenTextField branch here.
    // Disassembly of the supplied Filza binary shows that branch has no other
    // side effects; it only dispatches inputTextField.becomeFirstResponder()
    // after 0.1 seconds. That exact early hand-off is the race we are removing.
    TGFIRemovePendingObserver(self);

    NSUInteger generation =
        [objc_getAssociatedObject(self, kKeyboardFocusGenerationKey) unsignedIntegerValue] + 1;
    objc_setAssociatedObject(self, kKeyboardFocusGenerationKey, @(generation),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak id weakSelf = self;
    __block id token = nil;
    token = [NSNotificationCenter.defaultCenter
        addObserverForName:UIKeyboardDidShowNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *note) {
        id strongSelf = weakSelf;
        if (!strongSelf) {
            if (token) [NSNotificationCenter.defaultCenter removeObserver:token];
            return;
        }

        NSNumber *current = objc_getAssociatedObject(strongSelf,
                                                      kKeyboardFocusGenerationKey);
        if (current.unsignedIntegerValue != generation) return;

        TGFIFocusVisibleFieldIfStillNeeded(strongSelf, @"UIKeyboardDidShow");
        TGFIRemovePendingObserver(strongSelf);
    }];

    objc_setAssociatedObject(self, kKeyboardDidShowObserverKey, token,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Hardware keyboards / unusual input methods may not emit DidShow. Keep a
    // conservative fallback well beyond the normal keyboard animation instead
    // of Filza's original 100 ms race.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 900 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
        id strongSelf = weakSelf;
        if (!strongSelf) return;
        NSNumber *current = objc_getAssociatedObject(strongSelf,
                                                      kKeyboardFocusGenerationKey);
        if (current.unsignedIntegerValue != generation) return;
        TGFIFocusVisibleFieldIfStillNeeded(strongSelf, @"900ms fallback");
        TGFIRemovePendingObserver(strongSelf);
    });

    NSLog(@"[RenameResponderFix] hidden field began; waiting for keyboard DidShow");
}

static void InstallTGFocusedResponderTimingFix(void) {
    Class cls = NSClassFromString(@"TGFocusedInput");
    SEL sel = NSSelectorFromString(@"textFieldDidBeginEditing:");
    Method method = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!method) {
        NSLog(@"[RenameResponderFix] TGFocusedInput textFieldDidBeginEditing: not found");
        return;
    }

    gOrigTGFocusedDidBegin = method_getImplementation(method);
    method_setImplementation(method, (IMP)hook_TGFocused_textFieldDidBeginEditing);
    NSLog(@"[RenameResponderFix] installed original=%p replacement=%p",
          gOrigTGFocusedDidBegin, hook_TGFocused_textFieldDidBeginEditing);
}

__attribute__((constructor))
static void TGFocusedResponderTimingFixInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        InstallTGFocusedResponderTimingFix();
    });
}
