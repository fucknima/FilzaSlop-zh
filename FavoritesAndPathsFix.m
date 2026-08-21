@import UIKit;
#import <objc/runtime.h>
#import <objc/message.h>
#import "MCMFilzaIntegration.h"

#pragma mark - Helpers

static NSString *FPVirtualRoot(void) {
    NSString *root = MCMFilzaVirtualRoot();
    return root.length ? root : @"/var/mobile";
}

// 取 orig 收藏里能进入"设备存储"的条目：Filza 原生 Documents（/var/mobile/Documents）
// 点击时会被 Tweak.m 的 redirectedLegacyBrowserPath 重定向到 MCM 虚拟根。
static id FPDeviceStorageEntryIn(NSArray *orig) {
    if (![orig isKindOfClass:NSArray.class]) return nil;
    NSString *candidates[] = {
        @"/var/mobile/Documents",
        @"/var/mobile",
    };
    for (size_t c = 0; c < sizeof(candidates)/sizeof(candidates[0]); c++) {
        NSString *want = candidates[c];
        if (!want.length) continue;
        for (id obj in orig) {
            NSString *path = nil;
            if ([obj isKindOfClass:NSString.class]) path = obj;
            else if ([obj respondsToSelector:NSSelectorFromString(@"filePath")]) {
                @try { path = [obj performSelector:NSSelectorFromString(@"filePath")]; }
                @catch (__unused NSException *e) {}
            }
            if (path && [path isEqualToString:want]) {
                // 用 Filza 原生 FileItem，只把显示名改成"设备存储"，其余不动
                @try {
                    if ([obj respondsToSelector:NSSelectorFromString(@"setAFileName:")])
                        ((void(*)(id,SEL,id))objc_msgSend)(obj,
                            NSSelectorFromString(@"setAFileName:"), @"设备存储");
                } @catch (__unused NSException *e) {}
                return obj;
            }
        }
    }
    return nil;
}

static NSArray *FPFilteredFavorites(NSArray *orig) {
    NSMutableArray *filtered = [NSMutableArray array];
    id device = FPDeviceStorageEntryIn(orig);
    if (device) [filtered addObject:device];
    NSLog(@"[FavoritesFix] favoritedLinks -> %lu item(s)", (unsigned long)filtered.count);
    return filtered;
}

#pragma mark - TGPreferences hooks

static IMP orig_favoritedLinks = NULL;
static IMP orig_tempDirectory = NULL;
static IMP orig_downloadDirectory = NULL;

static id hook_favoritedLinks(id self, SEL _cmd) {
    NSArray *orig = orig_favoritedLinks ? ((id(*)(id,SEL))orig_favoritedLinks)(self, _cmd) : nil;
    return FPFilteredFavorites(orig);
}

static id hook_tempDirectory(id self, SEL _cmd) {
    NSString *tmp = [FPVirtualRoot() stringByAppendingPathComponent:@"tmp"];
    [[NSFileManager defaultManager] createDirectoryAtPath:tmp
                              withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions:@0755}
                                                    error:nil];
    return tmp;
}

static id hook_downloadDirectory(id self, SEL _cmd) {
    NSString *dl = [FPVirtualRoot() stringByAppendingPathComponent:@"Downloads"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dl
                              withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions:@0755}
                                                    error:nil];
    return dl;
}

#pragma mark - Install

static void InstallFavoritesAndPathsFix(void) {
    Class prefs = NSClassFromString(@"TGPreferences");
    if (prefs) {
        Method m = class_getInstanceMethod(prefs, NSSelectorFromString(@"favoritedLinks"));
        if (m) { orig_favoritedLinks = method_getImplementation(m); method_setImplementation(m, (IMP)hook_favoritedLinks); }
        m = class_getInstanceMethod(prefs, NSSelectorFromString(@"tempDirectory"));
        if (m) { orig_tempDirectory = method_getImplementation(m); method_setImplementation(m, (IMP)hook_tempDirectory); }
        m = class_getInstanceMethod(prefs, NSSelectorFromString(@"downloadDirectory"));
        if (m) { orig_downloadDirectory = method_getImplementation(m); method_setImplementation(m, (IMP)hook_downloadDirectory); }
        NSLog(@"[FavoritesFix] hooked TGPreferences favorites/temp/download");
    }
    NSLog(@"[FavoritesFix] installed");
}

__attribute__((constructor))
static void FavoritesAndPathsFixInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        MCMFilzaStart();
        InstallFavoritesAndPathsFix();
    });
}
