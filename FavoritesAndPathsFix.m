@import UIKit;
#import <objc/runtime.h>
#import <objc/message.h>
#import "MCMFilzaIntegration.h"

#pragma mark - Helpers

static NSString *FPVirtualRoot(void) {
    NSString *root = MCMFilzaVirtualRoot();
    if (root.length) return root;
    // Fallback to the exact path you provided on this device
    return @"/var/mobile/Containers/Data/Application/689CF24F-ED69-4E10-8639-A82585F067AD/Documents/Device Storage";
}

// 构造一个指向虚拟根的完整 FileItem（用于收藏夹为空时补上）
static id FPCreateDeviceStorageItem(void) {
    NSString *root = FPVirtualRoot();
    Class FI = NSClassFromString(@"FileItem");
    if (!FI) return root;
    id item = [[FI alloc] init];
    @try {
        // Use setFilePath: which will stat the directory and fill fileName/isDirectory correctly.
        // setFilePath:attribute: with nil attribute also works but setFilePath: is simpler and less likely to crash.
        if ([item respondsToSelector:NSSelectorFromString(@"setFilePath:")]) {
            ((void(*)(id,SEL,id))objc_msgSend)(item, NSSelectorFromString(@"setFilePath:"), root);
        } else if ([item respondsToSelector:NSSelectorFromString(@"setFilePath:attribute:")]) {
            ((void(*)(id,SEL,id,id))objc_msgSend)(item, NSSelectorFromString(@"setFilePath:attribute:"), root, nil);
        }
        // Ensure display name is 设备存储
        if ([item respondsToSelector:NSSelectorFromString(@"setAFileName:")]) {
            ((void(*)(id,SEL,id))objc_msgSend)(item, NSSelectorFromString(@"setAFileName:"), @"设备存储");
        }
        // Verify it has a valid filePath, otherwise fallback to string
        NSString *p = nil;
        @try { p = [item performSelector:NSSelectorFromString(@"filePath")]; } @catch (__unused NSException *e) {}
        if (![p isEqualToString:root]) {
            // If setFilePath: didn't stick, try the other setter
            if ([item respondsToSelector:NSSelectorFromString(@"setFilePath:attribute:")]) {
                ((void(*)(id,SEL,id,id))objc_msgSend)(item, NSSelectorFromString(@"setFilePath:attribute:"), root, nil);
            }
        }
        NSLog(@"[FavoritesFix] created Device Storage item for %@", root);
        return item;
    } @catch (__unused NSException *e) {
        NSLog(@"[FavoritesFix] create item failed %@", e);
        return root;
    }
}

static NSArray *FPFilteredFavorites(NSArray *orig) {
    NSString *keep = FPVirtualRoot();
    NSMutableArray *filtered = [NSMutableArray array];
    if ([orig isKindOfClass:NSArray.class]) {
        for (id obj in orig) {
            NSString *path = nil;
            if ([obj isKindOfClass:NSString.class]) path = obj;
            else if ([obj respondsToSelector:NSSelectorFromString(@"filePath")]) {
                @try { path = [obj performSelector:NSSelectorFromString(@"filePath")]; } @catch (__unused NSException *e) {}
            }
            if (path && [path isEqualToString:keep]) {
                // Keep the exact virtual root entry, ensure its display name
                @try {
                    if ([obj respondsToSelector:NSSelectorFromString(@"setAFileName:")])
                        ((void(*)(id,SEL,id))objc_msgSend)(obj, NSSelectorFromString(@"setAFileName:"), @"设备存储");
                } @catch (__unused NSException *e) {}
                [filtered addObject:obj];
                NSLog(@"[FavoritesFix] kept virtual root %@", path);
            } else {
                if (path) NSLog(@"[FavoritesFix] filtered out %@", path);
            }
        }
    }
    // If no virtual root in original, add one we create
    if (filtered.count == 0) {
        id item = FPCreateDeviceStorageItem();
        if (item) [filtered addObject:item];
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
    NSString *path = nil;
    @try {
        if ([item isKindOfClass:NSString.class]) path = item;
        else if ([item respondsToSelector:NSSelectorFromString(@"filePath")])
            path = [item performSelector:NSSelectorFromString(@"filePath")];
    } @catch (__unused NSException *e) {}
    NSString *keep = FPVirtualRoot();
    // Allow Device Storage to be added, block everything else
    if ([path isEqualToString:keep]) {
        NSLog(@"[FavoritesFix] allowing add Device Storage %@", path);
        // Ensure display name
        @try {
            if ([item respondsToSelector:NSSelectorFromString(@"setAFileName:")])
                ((void(*)(id,SEL,id))objc_msgSend)(item, NSSelectorFromString(@"setAFileName:"), @"设备存储");
        } @catch (__unused NSException *e) {}
        if (orig_addItemToFavoritedLinks) ((void(*)(id,SEL,id))orig_addItemToFavoritedLinks)(self, _cmd, item);
        return;
    }
    // For any other path, check if it's the virtual root, allow; otherwise ignore (don't add)
    if (path && [path hasPrefix:keep]) {
        // Item inside Device Storage – allow but not needed for favorites root
        if (orig_addItemToFavoritedLinks) ((void(*)(id,SEL,id))orig_addItemToFavoritedLinks)(self, _cmd, item);
        return;
    }
    NSLog(@"[FavoritesFix] blocked add favorite for %@", path);
    // Don't add unwanted favorites
    return;
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

static id hook_uploaderPath(id self, SEL _cmd) {
    NSString *up = [FPVirtualRoot() stringByAppendingPathComponent:@"tmp"];
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
