@import UIKit;
#import <objc/runtime.h>
#import <objc/message.h>
#import "MCMFilzaIntegration.h"

#pragma mark - Helpers

static NSString *FPFavoritesDeviceStoragePath(void) {
    NSString *root = MCMFilzaVirtualRoot();
    return root.length ? root : @"/var/mobile";
}

// Returns YES when the given favorite should be kept (only Device Storage root).
static BOOL FPShouldKeepFavorite(NSString *path) {
    if (![path isKindOfClass:NSString.class] || path.length == 0) return NO;
    NSString *keep = FPFavoritesDeviceStoragePath();
    if ([path isEqualToString:keep]) return YES;
    // Only the exact virtual root is kept. Nothing else – no Documents, no
    // Applications, no [Root], no system shortcuts (Trash, Apps, Mounts, Scripts).
    return NO;
}

static NSArray *FPFilteredFavorites(NSArray *orig) {
    if (![orig isKindOfClass:NSArray.class] || orig.count == 0) return orig;
    NSString *keep = FPFavoritesDeviceStoragePath();
    NSMutableArray *filtered = [NSMutableArray array];
    for (id obj in orig) {
        NSString *path = nil;
        if ([obj isKindOfClass:NSString.class]) path = obj;
        else if ([obj respondsToSelector:NSSelectorFromString(@"filePath")]) {
            @try { path = [obj performSelector:NSSelectorFromString(@"filePath")]; } @catch (__unused NSException *e) {}
        } else if ([obj respondsToSelector:NSSelectorFromString(@"path")]) {
            @try { path = [obj performSelector:NSSelectorFromString(@"path")]; } @catch (__unused NSException *e) {}
        }
        if (!path && [obj respondsToSelector:NSSelectorFromString(@"name")]) {
            @try { path = [obj performSelector:NSSelectorFromString(@"name")]; } @catch (__unused NSException *e) {}
        }
        if (!path || !FPShouldKeepFavorite(path)) continue;
        if ([path isEqualToString:keep] || [path hasPrefix:[keep stringByAppendingString:@"/"]]) {
            [filtered addObject:obj];
        }
    }
    return filtered;
}

#pragma mark - TGPreferences hooks

static IMP orig_favoritedLinks = NULL;
static IMP orig_tempDirectory = NULL;
static IMP orig_downloadDirectory = NULL;

static id hook_favoritedLinks(id self, SEL _cmd) {
    NSArray *orig = orig_favoritedLinks ? ((id(*)(id,SEL))orig_favoritedLinks)(self, _cmd) : nil;
    NSArray *filtered = FPFilteredFavorites(orig);
    if ([filtered count] != [orig count])
        NSLog(@"[FavoritesFix] favoritedLinks orig %lu -> filtered %lu",
              (unsigned long)[orig count], (unsigned long)filtered.count);
    return filtered;
}

static id hook_tempDirectory(id self, SEL _cmd) {
    NSString *root = FPFavoritesDeviceStoragePath();
    NSString *tmp = [root stringByAppendingPathComponent:@"tmp"];
    [[NSFileManager defaultManager] createDirectoryAtPath:tmp
                              withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions:@0755}
                                                    error:nil];
    return tmp;
}

static id hook_downloadDirectory(id self, SEL _cmd) {
    NSString *root = FPFavoritesDeviceStoragePath();
    NSString *dl = [root stringByAppendingPathComponent:@"Downloads"];
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