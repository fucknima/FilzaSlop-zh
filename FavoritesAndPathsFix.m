@import UIKit;
#import <objc/runtime.h>
#import <objc/message.h>
#import "MCMFilzaIntegration.h"

#pragma mark - Helpers

static NSString *FPVirtualRoot(void) {
    NSString *root = MCMFilzaVirtualRoot();
    return root.length ? root : @"/var/mobile";
}

static NSString *FPDeviceStorageName(void) {
    return @"设备存储";
}

static BOOL FPIsVirtualRootPath(NSString *path) {
    if (![path isKindOfClass:NSString.class] || path.length == 0) return NO;
    NSString *keep = FPVirtualRoot();
    return [path isEqualToString:keep] ||
        [path hasPrefix:[keep stringByAppendingString:@"/"]];
}

// Build a FileItem pointing at the virtual root with a friendly display name.
static id FPDeviceStorageItem(void) {
    NSString *root = FPVirtualRoot();
    Class FI = NSClassFromString(@"FileItem");
    if (!FI) return root;
    id item = [[FI alloc] init];
    @try {
        if ([item respondsToSelector:NSSelectorFromString(@"setFilePath:attribute:")])
            ((void(*)(id,SEL,id,id))objc_msgSend)(item,
                NSSelectorFromString(@"setFilePath:attribute:"), root, nil);
        if ([item respondsToSelector:NSSelectorFromString(@"setAFileName:")])
            ((void(*)(id,SEL,id))objc_msgSend)(item,
                NSSelectorFromString(@"setAFileName:"), FPDeviceStorageName());
        if ([item respondsToSelector:NSSelectorFromString(@"setDocumentPath:")])
            ((void(*)(id,SEL,id))objc_msgSend)(item,
                NSSelectorFromString(@"setDocumentPath:"), root);
    } @catch (__unused NSException *e) {}
    return item;
}

// Keep only the Device Storage favorite (dedupe), drop everything else.
static NSArray *FPFilteredFavorites(NSArray *orig) {
    NSMutableArray *filtered = [NSMutableArray array];
    if ([orig isKindOfClass:NSArray.class]) {
        for (id obj in orig) {
            NSString *path = nil;
            if ([obj isKindOfClass:NSString.class]) path = obj;
            else if ([obj respondsToSelector:NSSelectorFromString(@"filePath")]) {
                @try { path = [obj performSelector:NSSelectorFromString(@"filePath")]; }
                @catch (__unused NSException *e) {}
            } else if ([obj respondsToSelector:NSSelectorFromString(@"path")]) {
                @try { path = [obj performSelector:NSSelectorFromString(@"path")]; }
                @catch (__unused NSException *e) {}
            }
            if (!FPIsVirtualRootPath(path)) {
                NSLog(@"[FavoritesFix] filtered out %@", path);
                continue;
            }
            BOOL dup = NO;
            for (id existing in filtered) {
                NSString *ep = nil;
                if ([existing isKindOfClass:NSString.class]) ep = existing;
                else if ([existing respondsToSelector:NSSelectorFromString(@"filePath")]) {
                    @try { ep = [existing performSelector:NSSelectorFromString(@"filePath")]; }
                    @catch (__unused NSException *e) {}
                }
                if (ep && [ep isEqualToString:path]) { dup = YES; break; }
            }
            if (!dup) [filtered addObject:obj];
        }
    }
    // Always ensure Device Storage is present even if the store lacks it.
    if (filtered.count == 0) [filtered addObject:FPDeviceStorageItem()];
    return filtered;
}

#pragma mark - TGPreferences hooks

static IMP orig_favoritedLinks = NULL;
static IMP orig_objectForPreferenceKey = NULL;
static IMP orig_tempDirectory = NULL;
static IMP orig_downloadDirectory = NULL;

static id hook_favoritedLinks(id self, SEL _cmd) {
    NSArray *orig = orig_favoritedLinks ? ((id(*)(id,SEL))orig_favoritedLinks)(self, _cmd) : nil;
    NSArray *filtered = FPFilteredFavorites(orig);
    NSLog(@"[FavoritesFix] favoritedLinks orig %lu -> filtered %lu",
          (unsigned long)[orig count], (unsigned long)filtered.count);
    return filtered;
}

static id hook_objectForPreferenceKey(id self, SEL _cmd, id key) {
    id result = orig_objectForPreferenceKey
        ? ((id(*)(id,SEL,id))orig_objectForPreferenceKey)(self, _cmd, key) : nil;
    NSString *k = [key isKindOfClass:NSString.class] ? key : nil;
    if ([k isEqualToString:@"favorites"]) {
        // Sidebar system-favorites toggle: only Device Storage.
        result = @[FPVirtualRoot()];
    } else if ([k isEqualToString:@"temp-directory"]) {
        result = [FPVirtualRoot() stringByAppendingPathComponent:@"tmp"];
        [[NSFileManager defaultManager] createDirectoryAtPath:result
                                  withIntermediateDirectories:YES
                                                   attributes:@{NSFilePosixPermissions:@0755}
                                                        error:nil];
    } else if ([k isEqualToString:@"download-directory"]) {
        result = [FPVirtualRoot() stringByAppendingPathComponent:@"Downloads"];
        [[NSFileManager defaultManager] createDirectoryAtPath:result
                                  withIntermediateDirectories:YES
                                                   attributes:@{NSFilePosixPermissions:@0755}
                                                        error:nil];
    }
    return result;
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
        m = class_getInstanceMethod(prefs, NSSelectorFromString(@"objectForPreferenceKey:"));
        if (m) { orig_objectForPreferenceKey = method_getImplementation(m); method_setImplementation(m, (IMP)hook_objectForPreferenceKey); }
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