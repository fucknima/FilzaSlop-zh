@import UIKit;
#import <objc/runtime.h>
#import "MCMFilzaIntegration.h"

#pragma mark - Helpers

static NSString *FPFavoritesDeviceStoragePath(void) {
    NSString *root = MCMFilzaVirtualRoot();
    return root.length ? root : @"/var/mobile";
}

static BOOL FPIsUnwantedFavorite(NSString *path) {
    if (![path isKindOfClass:NSString.class] || path.length == 0) return YES;
    NSString *root = FPFavoritesDeviceStoragePath();
    if ([path isEqualToString:root]) return NO;
    // Keep only Device Storage
    // Unwanted: Documents, Applications, [Root], Scripts, Mount points, Trash, Music library, Apps manager
    // Their paths are typically: /var/mobile/Documents, /Applications, /, /var/mobile/Scripts, etc.
    // Also the localized names for the 5 defaults in preferences.plist
    static NSSet *unwantedNames = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        unwantedNames = [NSSet setWithArray:@[
            @"/var/mobile/Documents", @"/Applications", @"/", @"/var/mobile/Scripts",
            @"/var/stash", @"/var/mobile/Library/Music", @"/var/mobile/.Trash",
            // Localized names that may appear as favorites entries
            @"Documents", @"Applications", @"[Root]", @"Scripts",
            @"Mount points", @"Scripts", @"Trash", @"Music library", @"Apps manager",
            @"音乐库", @"回收站", @"App管理器", @"挂载点"
        ]];
    });
    // Also check if path is one of the unwanted absolute paths
    if ([unwantedNames containsObject:path]) return YES;
    // Check last component
    NSString *last = path.lastPathComponent;
    if ([unwantedNames containsObject:last]) return YES;
    // Check if path is inside unwanted
    for (NSString *u in unwantedNames) {
        if ([u hasPrefix:@"/"] && ([path isEqualToString:u] || [path hasPrefix:[u stringByAppendingString:@"/"]])) return YES;
    }
    // Keep only Device Storage
    return YES;
}

static NSArray *FPFilteredFavorites(NSArray *orig) {
    if (![orig isKindOfClass:NSArray.class]) return orig;
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
        // If we can't extract path, keep by name check
        if (!path && [obj respondsToSelector:NSSelectorFromString(@"name")]) {
            @try { path = [obj performSelector:NSSelectorFromString(@"name")]; } @catch (__unused NSException *e) {}
        }
        if (!path) continue;
        // Keep only Device Storage
        if ([path isEqualToString:keep] || [path hasPrefix:[keep stringByAppendingString:@"/"]]) {
            [filtered addObject:obj];
        } else if ([path isEqualToString:@"/var/mobile"] && [keep hasPrefix:@"/var/mobile"]) {
            // Also keep /var/mobile if it's the virtual root parent? No, we want only virtual root
            continue;
        } else {
            // Filter out all others
            NSLog(@"[FavoritesFix] filtered out %@", path);
        }
    }
    // Ensure at least Device Storage is present
    if (filtered.count == 0) {
        // Create a FileItem for Device Storage
        Class FI = NSClassFromString(@"FileItem");
        if (FI) {
            id item = [[FI alloc] init];
            if ([item respondsToSelector:NSSelectorFromString(@"setFilePath:attribute:")]) {
                ((void(*)(id,SEL,id,id))objc_msgSend)(item, NSSelectorFromString(@"setFilePath:attribute:"), keep, nil);
                [filtered addObject:item];
                NSLog(@"[FavoritesFix] added Device Storage %@", keep);
            } else if ([keep isKindOfClass:NSString.class]) {
                [filtered addObject:keep];
            }
        } else {
            [filtered addObject:keep];
        }
    }
    return filtered;
}

#pragma mark - TGPreferences hooks

static IMP orig_favoritedLinks = NULL;
static IMP orig_addNewFavoritesIfNeeds = NULL;
static IMP orig_updateFavorites = NULL;
static IMP orig_tempDirectory = NULL;
static IMP orig_downloadDirectory = NULL;

static id hook_favoritedLinks(id self, SEL _cmd) {
    NSArray *orig = orig_favoritedLinks ? ((id(*)(id,SEL))orig_favoritedLinks)(self, _cmd) : nil;
    NSArray *filtered = FPFilteredFavorites(orig);
    NSLog(@"[FavoritesFix] favoritedLinks orig %lu -> filtered %lu", (unsigned long)[orig count], (unsigned long)filtered.count);
    return filtered;
}

static void hook_addNewFavoritesIfNeeds(id self, SEL _cmd) {
    // Call original first to let it populate, then filter and save
    if (orig_addNewFavoritesIfNeeds) ((void(*)(id,SEL))orig_addNewFavoritesIfNeeds)(self, _cmd);
    // Now filter the stored favorites
    NSArray *orig = nil;
    @try { orig = [self performSelector:NSSelectorFromString(@"favoritedLinks")]; } @catch (__unused NSException *e) {}
    NSArray *filtered = FPFilteredFavorites(orig);
    @try { [self performSelector:NSSelectorFromString(@"restoreFavoritedLinks:") withObject:filtered]; } @catch (__unused NSException *e) {}
    @try { [self performSelector:NSSelectorFromString(@"saveFavoritedLinks")]; } @catch (__unused NSException *e) {}
    NSLog(@"[FavoritesFix] addNewFavoritesIfNeeds filtered");
}

static void hook_updateFavorites(id self, SEL _cmd) {
    if (orig_updateFavorites) ((void(*)(id,SEL))orig_updateFavorites)(self, _cmd);
    NSArray *orig = nil;
    @try { orig = [self performSelector:NSSelectorFromString(@"favoritedLinks")]; } @catch (__unused NSException *e) {}
    NSArray *filtered = FPFilteredFavorites(orig);
    @try { [self performSelector:NSSelectorFromString(@"restoreFavoritedLinks:") withObject:filtered]; } @catch (__unused NSException *e) {}
    NSLog(@"[FavoritesFix] updateFavorites filtered");
}

static id hook_tempDirectory(id self, SEL _cmd) {
    NSString *root = FPFavoritesDeviceStoragePath();
    NSString *tmp = [root stringByAppendingPathComponent:@"tmp"];
    // Ensure directory exists
    [[NSFileManager defaultManager] createDirectoryAtPath:tmp withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:nil];
    NSLog(@"[FavoritesFix] tempDirectory -> %@", tmp);
    return tmp;
}

static id hook_downloadDirectory(id self, SEL _cmd) {
    NSString *root = FPFavoritesDeviceStoragePath();
    NSString *dl = [root stringByAppendingPathComponent:@"Downloads"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dl withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0755} error:nil];
    NSLog(@"[FavoritesFix] downloadDirectory -> %@", dl);
    return dl;
}

#pragma mark - LeftPanel/FavoritesTableViewController hooks

static IMP orig_LeftPanelLoadFavorites = NULL;
static IMP orig_LeftPanelReloadFavorites = NULL;
static IMP orig_FavoritesReload = NULL;

static void hook_LeftPanelLoadFavorites(id self, SEL _cmd) {
    if (orig_LeftPanelLoadFavorites) ((void(*)(id,SEL))orig_LeftPanelLoadFavorites)(self, _cmd);
    // Try to filter the panel's data source if it has a favorites array
    @try {
        // LeftPanelTableViewController has a method to reload, but its data is from TGPreferences
        // Force a filtered save
        Class prefsCls = NSClassFromString(@"TGPreferences");
        id prefs = [prefsCls respondsToSelector:NSSelectorFromString(@"sharedInstance")] ? ((id(*)(id,SEL))objc_msgSend)(prefsCls, NSSelectorFromString(@"sharedInstance")) : nil;
        if (prefs) {
            NSArray *orig = [prefs performSelector:NSSelectorFromString(@"favoritedLinks")];
            NSArray *filtered = FPFilteredFavorites(orig);
            if (filtered.count != [orig count]) {
                [prefs performSelector:NSSelectorFromString(@"restoreFavoritedLinks:") withObject:filtered];
                [prefs performSelector:NSSelectorFromString(@"saveFavoritedLinks")];
            }
        }
    } @catch (__unused NSException *e) {}
}

static void hook_LeftPanelReloadFavorites(id self, SEL _cmd) {
    if (orig_LeftPanelReloadFavorites) ((void(*)(id,SEL))orig_LeftPanelReloadFavorites)(self, _cmd);
    // Same filter
    @try {
        Class prefsCls = NSClassFromString(@"TGPreferences");
        id prefs = [prefsCls respondsToSelector:NSSelectorFromString(@"sharedInstance")] ? ((id(*)(id,SEL))objc_msgSend)(prefsCls, NSSelectorFromString(@"sharedInstance")) : nil;
        if (prefs) {
            NSArray *orig = [prefs performSelector:NSSelectorFromString(@"favoritedLinks")];
            NSArray *filtered = FPFilteredFavorites(orig);
            if (filtered.count != [orig count]) {
                [prefs performSelector:NSSelectorFromString(@"restoreFavoritedLinks:") withObject:filtered];
            }
        }
    } @catch (__unused NSException *e) {}
}

static void hook_FavoritesReload(id self, SEL _cmd) {
    if (orig_FavoritesReload) ((void(*)(id,SEL))orig_FavoritesReload)(self, _cmd);
    // Filter links array on the view controller
    @try {
        NSArray *links = [self performSelector:NSSelectorFromString(@"links")];
        NSArray *filtered = FPFilteredFavorites(links);
        if (filtered.count != [links count]) {
            [self performSelector:NSSelectorFromString(@"setLinks:") withObject:filtered];
            // Force table reload
            if ([self respondsToSelector:NSSelectorFromString(@"tableView")]) {
                UITableView *tv = [self performSelector:NSSelectorFromString(@"tableView")];
                [tv reloadData];
            }
        }
    } @catch (__unused NSException *e) {}
}

#pragma mark - Install

static void InstallFavoritesAndPathsFix(void) {
    Class prefs = NSClassFromString(@"TGPreferences");
    if (prefs) {
        Method m = class_getInstanceMethod(prefs, NSSelectorFromString(@"favoritedLinks"));
        if (m) { orig_favoritedLinks = method_getImplementation(m); method_setImplementation(m, (IMP)hook_favoritedLinks); }
        m = class_getInstanceMethod(prefs, NSSelectorFromString(@"addNewFavoritesIfNeeds"));
        if (m) { orig_addNewFavoritesIfNeeds = method_getImplementation(m); method_setImplementation(m, (IMP)hook_addNewFavoritesIfNeeds); }
        m = class_getInstanceMethod(prefs, NSSelectorFromString(@"updateFavorites"));
        if (m) { orig_updateFavorites = method_getImplementation(m); method_setImplementation(m, (IMP)hook_updateFavorites); }
        m = class_getInstanceMethod(prefs, NSSelectorFromString(@"tempDirectory"));
        if (m) { orig_tempDirectory = method_getImplementation(m); method_setImplementation(m, (IMP)hook_tempDirectory); }
        m = class_getInstanceMethod(prefs, NSSelectorFromString(@"downloadDirectory"));
        if (m) { orig_downloadDirectory = method_getImplementation(m); method_setImplementation(m, (IMP)hook_downloadDirectory); }
        NSLog(@"[FavoritesFix] hooked TGPreferences");
    }
    Class left = NSClassFromString(@"LeftPanelTableViewController");
    if (left) {
        Method m = class_getInstanceMethod(left, NSSelectorFromString(@"loadFavorites"));
        if (m) { orig_LeftPanelLoadFavorites = method_getImplementation(m); method_setImplementation(m, (IMP)hook_LeftPanelLoadFavorites); }
        m = class_getInstanceMethod(left, NSSelectorFromString(@"reloadFavorites"));
        if (m) { orig_LeftPanelReloadFavorites = method_getImplementation(m); method_setImplementation(m, (IMP)hook_LeftPanelReloadFavorites); }
        NSLog(@"[FavoritesFix] hooked LeftPanel");
    }
    Class fav = NSClassFromString(@"FavoritesTableViewController");
    if (fav) {
        Method m = class_getInstanceMethod(fav, NSSelectorFromString(@"reloadFavorites"));
        if (m) { orig_FavoritesReload = method_getImplementation(m); method_setImplementation(m, (IMP)hook_FavoritesReload); }
        NSLog(@"[FavoritesFix] hooked FavoritesTable");
    }
    NSLog(@"[FavoritesFix] installed");
}

__attribute__((constructor))
static void FavoritesAndPathsFixInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        MCMFilzaStart();
        InstallFavoritesAndPathsFix();
        // Ensure initial favorites are filtered even before first UI loads
        Class prefsCls = NSClassFromString(@"TGPreferences");
        id prefs = [prefsCls respondsToSelector:NSSelectorFromString(@"sharedInstance")] ? ((id(*)(id,SEL))objc_msgSend)(prefsCls, NSSelectorFromString(@"sharedInstance")) : nil;
        if (prefs) {
            @try { [prefs performSelector:NSSelectorFromString(@"addNewFavoritesIfNeeds")]; } @catch (__unused NSException *e) {}
            @try { [prefs performSelector:NSSelectorFromString(@"updateFavorites")]; } @catch (__unused NSException *e) {}
        }
    });
}
