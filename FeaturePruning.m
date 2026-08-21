#include "FSLog.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
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

    FSLog(@"[FeaturePruning] root-only menu pruning installed");
}
