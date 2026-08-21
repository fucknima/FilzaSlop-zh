#include "FSLog.h"
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-parameter"

static id rhbNilStub(id self, SEL _cmd, id a1, id a2, id a3, id a4) { return nil; }
static void rhbVoidStub(id self, SEL _cmd, id a1, id a2, id a3, id a4) {}
static long rhbFailStub(id self, SEL _cmd, id a1, id a2, id a3, id a4) { return -1; }
static BOOL rhbNoStub(id self, SEL _cmd) { return NO; }

#pragma clang diagnostic pop

static IMP RHBPickImp(Method m) {
    const char *enc = method_getTypeEncoding(m);
    char r = enc ? enc[0] : '@';
    if (r == '@') return (IMP)rhbNilStub;
    if (r == 'v') return (IMP)rhbVoidStub;
    if (r == 'B' || r == 'c') return (IMP)rhbNoStub;
    return (IMP)rhbFailStub;
}

static void RHBReplaceInstance(Class cls, const char *selName) {
    SEL sel = sel_registerName(selName);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) {
        FSLog(@"[RootHelperBlocker] missing instance method %s on %@", selName, cls);
        return;
    }
    method_setImplementation(m, RHBPickImp(m));
}

static void RHBReplaceClassMethod(Class cls, const char *selName) {
    SEL sel = sel_registerName(selName);
    Method m = class_getClassMethod(cls, sel);
    if (!m) {
        FSLog(@"[RootHelperBlocker] missing class method %s on %@", selName, cls);
        return;
    }
    method_setImplementation(m, (IMP)rhbNoStub);
}

static void RHBInstall(void) {
    Class fm = NSClassFromString(@"TGRootFileManager");
    Class avail = NSClassFromString(@"TGAvailability");
    if (!fm || !avail) {
        FSLog(@"[RootHelperBlocker] target classes not found (fm=%@ avail=%@)", fm, avail);
        return;
    }

    RHBReplaceInstance(fm, "_execRootShell:chdir:");
    RHBReplaceInstance(fm, "_execRootShell:args:chdir:");
    RHBReplaceInstance(fm, "_execRootShellWithOutput:args:chdir:maxOutLen:");
    RHBReplaceInstance(fm, "forkRootShell:chdir:");
    RHBReplaceInstance(fm, "dpkgInfo:");

    RHBReplaceClassMethod(avail, "IsShellAvailable");
    RHBReplaceClassMethod(avail, "IsDEBAvailable");

    FSLog(@"[RootHelperBlocker] root shell / dpkg fallback paths fused");
}

__attribute__((constructor)) static void RootHelperBlockerInit(void) {
    RHBInstall();
}
