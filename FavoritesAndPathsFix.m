@import UIKit;
#import <objc/runtime.h>
#import <objc/message.h>
#import "MCMFilzaIntegration.h"

#pragma mark - Helpers

static NSString *FPVirtualRoot(void) {
    NSString *root = MCMFilzaVirtualRoot();
    // Never hardcode UUID – MCMFilzaVirtualRoot() is dynamic and will change after reinstall.
    // If it hasn't been initialized yet, return nil and let callers handle gracefully.
    return root.length ? root : nil;
}

// 收藏夹过滤：只保留能进入虚拟根的条目，绝不合成新 FileItem（合成必然闪退）。
// 虚拟根不在原收藏里时返回空数组——宁可空也不崩。
static NSArray *FPFilteredFavorites(NSArray *orig) {
    NSString *keep = FPVirtualRoot();
    if (!keep.length) return orig;
    NSMutableArray *filtered = [NSMutableArray array];
    if ([orig isKindOfClass:NSArray.class]) {
        for (id obj in orig) {
            NSString *path = nil;
            if ([obj isKindOfClass:NSString.class]) path = obj;
            else if ([obj respondsToSelector:NSSelectorFromString(@"filePath")]) {
                @try { path = [obj performSelector:NSSelectorFromString(@"filePath")]; } @catch (__unused NSException *e) {}
            }
            if (!path) continue;
            // 只保留精确等于虚拟根的条目，其他全滤掉
            if ([path isEqualToString:keep]) {
                [filtered addObject:obj];
                NSLog(@"[FavoritesFix] kept virtual root %@", path);
            } else {
                NSLog(@"[FavoritesFix] filtered out %@", path);
            }
        }
    }
    NSLog(@"[FavoritesFix] favoritedLinks filtered -> %lu", (unsigned long)filtered.count);
    return filtered;
}

#pragma mark - TGPreferences hooks

static IMP orig_favoritedLinks = NULL;
static IMP orig_addItemToFavoritedLinks = NULL;
static IMP orig_tempDirectory = NULL;
static IMP orig_downloadDirectory = NULL;
static IMP orig_uploaderPath = NULL;

static id hook_favoritedLinks(id self, SEL _cmd) {
    NSArray *orig = orig_favoritedLinks ? ((id(*)(id,SEL))orig_favoritedLinks)(self, _cmd) : nil;
    return FPFilteredFavorites(orig);
}

static void hook_addItemToFavoritedLinks(id self, SEL _cmd, id item) {
    NSString *keep = FPVirtualRoot();
    if (!keep.length) {
        if (orig_addItemToFavoritedLinks) ((void(*)(id,SEL,id))orig_addItemToFavoritedLinks)(self, _cmd, item);
        return;
    }
    NSString *path = nil;
    @try {
        if ([item isKindOfClass:NSString.class]) path = item;
        else if ([item respondsToSelector:NSSelectorFromString(@"filePath")])
            path = [item performSelector:NSSelectorFromString(@"filePath")];
    } @catch (__unused NSException *e) {}
    // 只放行虚拟根，其余（Documents/Applications/[Root]/脚本等）一律不加入收藏
    if (path && [path isEqualToString:keep]) {
        NSLog(@"[FavoritesFix] allowing add Device Storage %@", path);
        if (orig_addItemToFavoritedLinks) ((void(*)(id,SEL,id))orig_addItemToFavoritedLinks)(self, _cmd, item);
        return;
    }
    NSLog(@"[FavoritesFix] blocked add favorite for %@", path);
    return;
}

static id hook_tempDirectory(id self, SEL _cmd) {
    NSString *keep = FPVirtualRoot();
    if (!keep.length) return orig_tempDirectory ? ((id(*)(id,SEL))orig_tempDirectory)(self, _cmd) : nil;
    NSString *tmp = [keep stringByAppendingPathComponent:@"tmp"];
    [[NSFileManager defaultManager] createDirectoryAtPath:tmp
                              withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions:@0755}
                                                    error:nil];
    return tmp;
}

static id hook_downloadDirectory(id self, SEL _cmd) {
    NSString *keep = FPVirtualRoot();
    if (!keep.length) return orig_downloadDirectory ? ((id(*)(id,SEL))orig_downloadDirectory)(self, _cmd) : nil;
    NSString *dl = [keep stringByAppendingPathComponent:@"Downloads"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dl
                              withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions:@0755}
                                                    error:nil];
    return dl;
}

static id hook_uploaderPath(id self, SEL _cmd) {
    NSString *keep = FPVirtualRoot();
    if (!keep.length) return orig_uploaderPath ? ((id(*)(id,SEL))orig_uploaderPath)(self, _cmd) : nil;
    NSString *up = [keep stringByAppendingPathComponent:@"tmp"];
    [[NSFileManager defaultManager] createDirectoryAtPath:up
                              withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions:@0755}
                                                    error:nil];
    return up;
}

#pragma mark - Install

static void InstallFavoritesAndPathsFix(void) {
    Class prefs = NSClassFromString(@"TGPreferences");
    if (prefs) {
        Method m = class_getInstanceMethod(prefs, NSSelectorFromString(@"favoritedLinks"));
        if (m) { orig_favoritedLinks = method_getImplementation(m); method_setImplementation(m, (IMP)hook_favoritedLinks); }
        m = class_getInstanceMethod(prefs, NSSelectorFromString(@"addItemToFavoritedLinks:"));
        if (m) { orig_addItemToFavoritedLinks = method_getImplementation(m); method_setImplementation(m, (IMP)hook_addItemToFavoritedLinks); }
        m = class_getInstanceMethod(prefs, NSSelectorFromString(@"tempDirectory"));
        if (m) { orig_tempDirectory = method_getImplementation(m); method_setImplementation(m, (IMP)hook_tempDirectory); }
        m = class_getInstanceMethod(prefs, NSSelectorFromString(@"downloadDirectory"));
        if (m) { orig_downloadDirectory = method_getImplementation(m); method_setImplementation(m, (IMP)hook_downloadDirectory); }
        m = class_getInstanceMethod(prefs, NSSelectorFromString(@"uploaderPath"));
        if (m) { orig_uploaderPath = method_getImplementation(m); method_setImplementation(m, (IMP)hook_uploaderPath); }
        NSLog(@"[FavoritesFix] hooked TGPreferences favorites/temp/download/uploader");
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
