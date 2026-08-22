#include "FSLog.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <unistd.h>
#import <objc/runtime.h>

@interface TGMenuManagerItem : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *title;
@end

@interface TGMenuBarButtonItem : UIBarButtonItem
@property(nonatomic, strong) id item;
@property(nonatomic, copy) NSString *label;
@end

static NSArray<NSString *> *FPBlockedIdentifiers(void)
{
    static NSArray<NSString *> *identifiers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        identifiers = @[@"terminal", @"uicache", @"makedeb", @"mountpoints", @"respring"];
    });
    return identifiers;
}

static BOOL FPTitleBlocked(NSString *title)
{
    if (![title isKindOfClass:[NSString class]] || title.length == 0) return NO;
    NSString *lower = [title lowercaseString];
    return ([lower containsString:@"uninstall"] ||
            [title containsString:@"卸载"] ||
            [lower containsString:@"uicache"]);
}

static void FPExtractItem(id menuItem, NSString **identifier, NSString **title)
{
    Class itemClass = NSClassFromString(@"TGMenuManagerItem");
    Class barClass = NSClassFromString(@"TGMenuBarButtonItem");
    if (barClass && [menuItem isKindOfClass:barClass]) {
        TGMenuBarButtonItem *bar = (TGMenuBarButtonItem *)menuItem;
        if ([bar.item isKindOfClass:itemClass]) {
            *identifier = [(TGMenuManagerItem *)bar.item identifier];
            *title = [(TGMenuManagerItem *)bar.item title];
        }
        if (!*title) *title = bar.label;
    } else if (itemClass && [menuItem isKindOfClass:itemClass]) {
        *identifier = [(TGMenuManagerItem *)menuItem identifier];
        *title = [(TGMenuManagerItem *)menuItem title];
    }
}

static BOOL FPShouldDrop(id menuItem)
{
    NSString *identifier = nil;
    NSString *title = nil;
    FPExtractItem(menuItem, &identifier, &title);
    if (identifier.length && [FPBlockedIdentifiers() containsObject:identifier.lowercaseString]) {
        FSLog(@"[FeaturePruning] drop root-only menu item (id=%@)", identifier);
        return YES;
    }
    if (FPTitleBlocked(title)) {
        FSLog(@"[FeaturePruning] drop root-only menu item (title=%@)", title);
        return YES;
    }
    return NO;
}

static NSArray *FPFilterMenuItems(NSArray *items)
{
    if (![items isKindOfClass:[NSArray class]] || items.count == 0) return items;
    NSMutableArray *kept = [NSMutableArray arrayWithCapacity:items.count];
    for (id menuItem in items) {
        if (!FPShouldDrop(menuItem)) [kept addObject:menuItem];
    }
    return kept;
}

#pragma mark - swizzle plumbing

static IMP origPageBar, origPagePanel, origPageCustomMenu;
static IMP origAppsBar, origAppsPanel, origAppsCustomMenu;

static NSArray *FPFilterBar(id self, SEL _cmd, id manager)
{
    return FPFilterMenuItems(((NSArray *(*)(id, SEL, id))origPageBar)(self, _cmd, manager));
}

static NSArray *FPFilterPanel(id self, SEL _cmd, id manager)
{
    return FPFilterMenuItems(((NSArray *(*)(id, SEL, id))origPagePanel)(self, _cmd, manager));
}

static NSArray *FPFilterCustomMenu(id self, SEL _cmd, id item, id sourceView, CGRect sourceRect)
{
    return FPFilterMenuItems(
        ((NSArray *(*)(id, SEL, id, id, CGRect))origPageCustomMenu)(self, _cmd, item, sourceView, sourceRect));
}

static NSArray *FPFilterBarApps(id self, SEL _cmd, id manager)
{
    return FPFilterMenuItems(((NSArray *(*)(id, SEL, id))origAppsBar)(self, _cmd, manager));
}

static NSArray *FPFilterPanelApps(id self, SEL _cmd, id manager)
{
    return FPFilterMenuItems(((NSArray *(*)(id, SEL, id))origAppsPanel)(self, _cmd, manager));
}

static NSArray *FPFilterCustomMenuApps(id self, SEL _cmd, id item, id sourceView, CGRect sourceRect)
{
    return FPFilterMenuItems(
        ((NSArray *(*)(id, SEL, id, id, CGRect))origAppsCustomMenu)(self, _cmd, item, sourceView, sourceRect));
}

static void FPSwizzle(Class cls, const char *selName, IMP newImp, IMP *origOut)
{
    if (!cls) {
        FSLog(@"[FeaturePruning] class missing for %s", selName);
        return;
    }
    Method m = class_getInstanceMethod(cls, sel_registerName(selName));
    if (!m) {
        FSLog(@"[FeaturePruning] method missing: %s on %@", selName, cls);
        return;
    }
    *origOut = method_getImplementation(m);
    method_setImplementation(m, newImp);
}

#pragma mark - preferences.plist sanitation

// Filza defaults point at /var/tmp and /var/mobile/Downloads — both unwritable
// jailed, which breaks every download/preview/edit/remote-extract flow and
// crashes CloudPageViewController when the nil result hits its completion array.
static NSString *FPRedirectedDownloadDirectory(void)
{
    NSString *target = [[[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"]
        stringByAppendingPathComponent:@"Device Storage"]
        stringByAppendingPathComponent:@"Downloads"];
    [[NSFileManager defaultManager] createDirectoryAtPath:target
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return target;
}

static NSMutableDictionary *FPSanitizedPreferences(NSDictionary *prefs)
{
    NSMutableDictionary *sanitized = [prefs mutableCopy];
    for (NSString *key in [prefs allKeys])
        if ([key hasPrefix:@"air-"])   // WebDAV server group: LaunchDaemon-only, dead jailed
            [sanitized removeObjectForKey:key];

    void (^redirect)(NSString *, NSString *) = ^(NSString *key, NSString *value) {
        NSDictionary *entry = sanitized[key];
        if (![entry isKindOfClass:[NSDictionary class]]) return;
        NSMutableDictionary *updated = [entry mutableCopy];
        updated[@"selected-value"] = value;
        sanitized[key] = updated;
    };
    redirect(@"temp-directory", NSTemporaryDirectory());
    redirect(@"download-directory", FPRedirectedDownloadDirectory());
    return sanitized;
}

static IMP origDictWithContentsOfFile;

static id FP_dictWithContentsOfFile(id self, SEL _cmd, NSString *path)
{
    id result = ((id(*)(id, SEL, id))origDictWithContentsOfFile)(self, _cmd, path);
    if ([path isKindOfClass:[NSString class]] && [path hasSuffix:@"preferences.plist"] &&
        [result isKindOfClass:[NSDictionary class]]) {
        FSLog(@"[FeaturePruning] preferences.plist sanitized (air-* removed, temp/download redirected)");
        return FPSanitizedPreferences(result);
    }
    return result;
}

static IMP origDictInitWithContentsOfFile;

static id FP_dictInitWithContentsOfFile(id self, SEL _cmd, NSString *path)
{
    id result = ((id(*)(id, SEL, id))origDictInitWithContentsOfFile)(self, _cmd, path);
    if ([path isKindOfClass:[NSString class]] && [path hasSuffix:@"preferences.plist"] &&
        [result isKindOfClass:[NSDictionary class]]) {
        FSLog(@"[FeaturePruning] preferences.plist sanitized (init path)");
        return FPSanitizedPreferences(result);
    }
    return result;
}

static void FPInstallPreferencesHooks(void)
{
    Method classMethod = class_getClassMethod([NSDictionary class],
        sel_registerName("dictionaryWithContentsOfFile:"));
    if (classMethod) {
        origDictWithContentsOfFile = method_getImplementation(classMethod);
        method_setImplementation(classMethod, (IMP)FP_dictWithContentsOfFile);
    }
    Method instanceMethod = class_getInstanceMethod([NSDictionary class],
        sel_registerName("initWithContentsOfFile:"));
    if (instanceMethod) {
        origDictInitWithContentsOfFile = method_getImplementation(instanceMethod);
        method_setImplementation(instanceMethod, (IMP)FP_dictInitWithContentsOfFile);
    }
}

#pragma mark - runtime directory getters + settings items scrub

static IMP origTempDirectoryGetter;
static IMP origDownloadDirectoryGetter;
static BOOL loggedGetterHit = NO;

static NSString *FP_safeTempDirectory(id self, SEL _cmd)
{
    if (!loggedGetterHit) {
        loggedGetterHit = YES;
        FSLog(@"[FeaturePruning] TGPreferences tempDirectory getter hooked");
    }
    return NSTemporaryDirectory();
}

static NSString *FP_safeDownloadDirectory(id self, SEL _cmd)
{
    if (!loggedGetterHit) {
        loggedGetterHit = YES;
        FSLog(@"[FeaturePruning] TGPreferences downloadDirectory getter hooked");
    }
    return FPRedirectedDownloadDirectory();
}

static BOOL FPIsAirRow(NSDictionary *row)
{
    NSString *selector = row[@"selector"];
    if ([selector isKindOfClass:[NSString class]] && [selector containsString:@"AirBrowser"])
        return YES;
    for (NSString *key in @[@"key", @"identifier"]) {
        NSString *value = row[key];
        if ([value isKindOfClass:[NSString class]] && [value hasPrefix:@"air-"])
            return YES;
    }
    return NO;
}

static id FPScrubAir(id obj)
{
    if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *result = [NSMutableArray array];
        for (id element in obj) {
            if ([element isKindOfClass:[NSDictionary class]] && FPIsAirRow(element)) continue;
            id cleaned = FPScrubAir(element);
            [result addObject:cleaned ?: [NSNull null]];
        }
        return result;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        for (id key in obj) {
            if ([key isKindOfClass:[NSString class]] && [key hasPrefix:@"air-"]) continue;
            id value = obj[key];
            if ([value isKindOfClass:[NSDictionary class]] && FPIsAirRow(value)) continue;
            id cleaned = FPScrubAir(value);
            result[key] = cleaned ?: [NSNull null];
        }
        return result;
    }
    return obj;
}

static IMP origSetItems;

static void FP_setItems(id self, SEL _cmd, id items)
{
    ((void(*)(id, SEL, id))origSetItems)(self, _cmd, FPScrubAir(items));
}

static IMP origTitleForHeader;
static IMP origNumberOfRows;

static NSString *FP_titleForHeader(id self, SEL _cmd, UITableView *tableView, NSInteger section)
{
    NSString *title = ((NSString *(*)(id, SEL, UITableView *, NSInteger))origTitleForHeader)(
        self, _cmd, tableView, section);
    if ([title isKindOfClass:[NSString class]] &&
        [title.lowercaseString containsString:@"webdav"])
        return nil;
    return title;
}

static NSInteger FP_numberOfRows(id self, SEL _cmd, UITableView *tableView, NSInteger section)
{
    NSString *title = ((NSString *(*)(id, SEL, UITableView *, NSInteger))origTitleForHeader)(
        self, _cmd, tableView, section);
    if ([title isKindOfClass:[NSString class]] &&
        [title.lowercaseString containsString:@"webdav"])
        return 0;
    return ((NSInteger(*)(id, SEL, UITableView *, NSInteger))origNumberOfRows)(
        self, _cmd, tableView, section);
}

static IMP origStartSFTPSession;

static void FP_sftpStartSession(id self, SEL _cmd)
{
    id session = ((id(*)(id, SEL))objc_msgSend)(self, sel_registerName("session"));
    FSLog(@"[FeaturePruning] startSFTPSession session=%@ -> %@",
          session ?: @"nil", session ? @"skip" : @"start");
    if (session) return;   // redundant re-start raises 'Already connected'
    ((void(*)(id, SEL))origStartSFTPSession)(self, _cmd);
}

static void FPInstallRuntimeFixes(void)
{
    Class prefsClass = NSClassFromString(@"TGPreferences");
    Method tempMethod = class_getInstanceMethod(prefsClass, sel_registerName("tempDirectory"));
    if (tempMethod) {
        origTempDirectoryGetter = method_getImplementation(tempMethod);
        method_setImplementation(tempMethod, (IMP)FP_safeTempDirectory);
    }
    Method downloadMethod = class_getInstanceMethod(prefsClass, sel_registerName("downloadDirectory"));
    if (downloadMethod) {
        origDownloadDirectoryGetter = method_getImplementation(downloadMethod);
        method_setImplementation(downloadMethod, (IMP)FP_safeDownloadDirectory);
    }

    Class settingsClass = NSClassFromString(@"TGPreferencesTableViewController");
    Method setItemsMethod = class_getInstanceMethod(settingsClass, sel_registerName("setItems:"));
    if (setItemsMethod) {
        origSetItems = method_getImplementation(setItemsMethod);
        method_setImplementation(setItemsMethod, (IMP)FP_setItems);
    }

    // the WEBDAV 服务 section is hardcoded; hide it at table-data level
    Class tableClass = settingsClass;
    Method titleMethod = class_getInstanceMethod(tableClass,
        sel_registerName("tableView:titleForHeaderInSection:"));
    Method rowsMethod = class_getInstanceMethod(tableClass,
        sel_registerName("tableView:numberOfRowsInSection:"));
    if (titleMethod && rowsMethod) {
        origTitleForHeader = method_getImplementation(titleMethod);
        origNumberOfRows = method_getImplementation(rowsMethod);
        method_setImplementation(titleMethod, (IMP)FP_titleForHeader);
        method_setImplementation(rowsMethod, (IMP)FP_numberOfRows);
    }

    // DLSFTPConnection raises 'Already connected' when a second op re-runs
    // startSFTPSession on a live session; skip the redundant start instead
    Class sftpClass = NSClassFromString(@"DLSFTPConnection");
    Method sftpStart = class_getInstanceMethod(sftpClass, sel_registerName("startSFTPSession"));
    if (sftpStart) {
        origStartSFTPSession = method_getImplementation(sftpStart);
        method_setImplementation(sftpStart, (IMP)FP_sftpStartSession);
    } else {
        FSLog(@"[FeaturePruning] DLSFTPConnection not found");
    }

    // POSIX access() lies here: /var/tmp is world-writable but the seatbelt
    // profile still denies writes outside our container. Force-override both.
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:NSTemporaryDirectory() forKey:@"temp-directory"];
    [defaults setObject:FPRedirectedDownloadDirectory() forKey:@"download-directory"];
}

__attribute__((constructor)) static void FeaturePruningInit(void)
{
    Class pageClass = NSClassFromString(@"TGPageViewController");
    Class appsClass = NSClassFromString(@"TGApplicationsViewController");

    FPSwizzle(pageClass, "itemsForBarMenuManager:", (IMP)FPFilterBar, &origPageBar);
    FPSwizzle(pageClass, "itemsForPanelMenuManager:", (IMP)FPFilterPanel, &origPagePanel);
    FPSwizzle(pageClass, "customMenuElementItemsForItem:sourceView:sourceRect:",
              (IMP)FPFilterCustomMenu, &origPageCustomMenu);

    FPSwizzle(appsClass, "itemsForBarMenuManager:", (IMP)FPFilterBarApps, &origAppsBar);
    FPSwizzle(appsClass, "itemsForPanelMenuManager:", (IMP)FPFilterPanelApps, &origAppsPanel);
    FPSwizzle(appsClass, "customMenuElementItemsForItem:sourceView:sourceRect:",
              (IMP)FPFilterCustomMenuApps, &origAppsCustomMenu);

    FPInstallPreferencesHooks();
    FPInstallRuntimeFixes();

    FSLog(@"[FeaturePruning] root-only menu pruning installed");
}
