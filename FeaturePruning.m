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

    FSLog(@"[FeaturePruning] root-only menu pruning installed");
}
