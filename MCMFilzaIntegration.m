#import "MCMFilzaIntegration.h"

#import "MCMBridge.h"
#import <fcntl.h>
#import <limits.h>
#import <notify.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

static const uint64_t kMCMFlags = 0x900000000ULL;
static const uint64_t kMCMReadWritePartFlags = 0x8100000000ULL;
static NSString *const kRequiredIdentifier = @"com.apple.mobile.MobileHouseArrest";
static NSString *const kMCMAppDataDirectoryName = @"[MHA-C2] App Data";
static NSString *const kMCMAppGroupsDirectoryName = @"[MHA-C7] App Groups";
static NSString *const kMCMExtensionDataDirectoryName = @"[MHA-C4] Extension Data";
static NSString *const kMCMVPNDataDirectoryName = @"[MHA-C6] VPN Data";
static NSString *const kMCMServiceDataDirectoryName = @"[MHA-C10] Service Data";
static NSString *const kMCMSystemDataDirectoryName = @"[MHA-C12] System Data";
static NSString *const kMCMSystemGroupsDirectoryName = @"[MHA-C13] System Groups";
static NSString *const kMCMProtectedDataDirectoryName = @"[MHA-C15] Protected Data";
static NSString *const kMCMAdditionalLocationsDirectoryName =
    @"[MHA-C13 Scoped] Additional Locations";
static NSString *const kMCMExperimentalDirectoryName =
    @"[MHA-Mixed EXP] Experimental";
static NSString *const kMCMWallpaperLabDirectoryName = @"[MHA-C2] Wallpaper Lab";
static NSString *const kMCMDeletedGeneratedPathsKey =
    @"FilzaSlopDeletedGeneratedPaths";
static NSMutableDictionary<NSString *, MCMLease *> *gLeases;
static BOOL gUnrestrictedFilesystem;
static _Atomic(int) gMCMStartupComplete = 0;

NSNotificationName const MCMFilzaStartupProgressNotification =
    @"FilzaSlop.MCMStartupProgress";
NSNotificationName const MCMFilzaStartupCompleteNotification =
    @"FilzaSlop.MCMStartupComplete";
NSString *const MCMFilzaStartupProgressKey = @"progress";
NSString *const MCMFilzaStartupStatusKey = @"status";

typedef CFTypeRef SecTaskRef;
extern SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFStringRef SecTaskCopySigningIdentifier(SecTaskRef task, CFErrorRef *error);

static void MCMPostStartupProgress(double progress, NSString *status)
{
    progress = MAX(0.0, MIN(1.0, progress));
    [[NSNotificationCenter defaultCenter]
        postNotificationName:MCMFilzaStartupProgressNotification
                      object:nil
                    userInfo:@{
                        MCMFilzaStartupProgressKey: @(progress),
                        MCMFilzaStartupStatusKey: status ?: @"正在准备设备存储…",
                    }];
}

static void MCMFinishStartup(NSString *status)
{
    atomic_store_explicit(&gMCMStartupComplete, 1, memory_order_release);
    NSString *finalStatus = status.length ? status : @"设备存储已就绪";
    MCMPostStartupProgress(1.0, finalStatus);
    [[NSNotificationCenter defaultCenter]
        postNotificationName:MCMFilzaStartupCompleteNotification
                      object:nil
                    userInfo:@{MCMFilzaStartupStatusKey: finalStatus}];
}

BOOL MCMFilzaStartupIsComplete(void)
{
    return atomic_load_explicit(&gMCMStartupComplete, memory_order_acquire) != 0;
}

static NSString *MCMSignedCodeIdentifier(void)
{
    static NSString *identifier;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
        if (!task) return;
        CFErrorRef error = NULL;
        CFStringRef value = SecTaskCopySigningIdentifier(task, &error);
        if (value) identifier = [(__bridge NSString *)value copy];
        if (value) CFRelease(value);
        if (error) CFRelease(error);
        CFRelease(task);
    });
    return identifier;
}

BOOL MCMFilzaIsRunningInLiveContainer(void)
{
    const char *home = getenv("LC_HOME_PATH");
    return home && home[0] == '/';
}

static NSString *MCMAbsoluteEnvironmentPath(const char *name)
{
    const char *value = getenv(name);
    if (!value || value[0] != '/') return nil;
    NSString *path = [NSString stringWithUTF8String:value];
    return path.length ? path.stringByStandardizingPath : nil;
}

static NSString *MCMLiveContainerAppGroupPath(void)
{
    SEL selector = NSSelectorFromString(@"lcAppGroupPath");
    Class defaults = NSUserDefaults.class;
    if (![defaults respondsToSelector:selector]) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(defaults, selector);
    return [value isKindOfClass:NSString.class] && [value isAbsolutePath]
        ? [value stringByStandardizingPath] : nil;
}

static NSArray<NSString *> *MCMLiveContainerAuthorityRoots(void)
{
    if (!MCMFilzaIsRunningInLiveContainer()) return @[];
    NSMutableOrderedSet<NSString *> *roots = [NSMutableOrderedSet orderedSet];
    for (NSString *path in @[
        MCMAbsoluteEnvironmentPath("LC_HOME_PATH") ?: @"",
        MCMAbsoluteEnvironmentPath("HOME") ?: @"",
        MCMLiveContainerAppGroupPath() ?: @"",
    ]) {
        if (path.length) [roots addObject:path];
    }
    return roots.array;
}

void MCMFilzaSetUnrestrictedFilesystem(BOOL enabled)
{
    gUnrestrictedFilesystem = enabled;
}

static void MCMEnsureState(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ gLeases = [NSMutableDictionary dictionary]; });
}

@interface NSObject (MCMFilzaLaunchServices)
+ (id)defaultWorkspace;
- (NSArray *)allApplications;
- (NSString *)applicationIdentifier;
- (NSString *)bundleIdentifier;
@end

NSString *MCMFilzaVirtualRoot(void)
{
    if (MCMFilzaIsRunningInLiveContainer()) {
        NSString *home = MCMAbsoluteEnvironmentPath("HOME");
        if (home.length)
            return [[home stringByAppendingPathComponent:@"Documents"]
                stringByAppendingPathComponent:@"Device Storage"];
    }
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [documents stringByAppendingPathComponent:@"Device Storage"];
}

NSString *MCMFilzaArchivePath(void)
{
    return [[MCMFilzaVirtualRoot() stringByDeletingLastPathComponent]
        stringByAppendingPathComponent:@"FilzaSlop Archive"];
}

static NSString *MCMGeneratedPathKey(NSString *path)
{
    if (!path.length || !path.isAbsolutePath) return nil;
    NSString *root = MCMFilzaVirtualRoot().stringByStandardizingPath;
    NSString *candidate = path.stringByStandardizingPath;
    NSString *prefix = [root stringByAppendingString:@"/"];
    if (![candidate hasPrefix:prefix]) return nil;
    return [candidate substringFromIndex:prefix.length];
}

static NSSet<NSString *> *MCMDeletedGeneratedPaths(void)
{
    NSArray *values = [NSUserDefaults.standardUserDefaults
        arrayForKey:kMCMDeletedGeneratedPathsKey];
    return [NSSet setWithArray:[values isKindOfClass:NSArray.class] ? values : @[]];
}

static BOOL MCMGeneratedPathWasDeleted(NSString *path)
{
    NSString *key = MCMGeneratedPathKey(path);
    return key.length > 0 && [MCMDeletedGeneratedPaths() containsObject:key];
}

void MCMFilzaRecordDeletedGeneratedPath(NSString *path)
{
    NSString *key = MCMGeneratedPathKey(path);
    if (!key.length) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    @synchronized (defaults) {
        NSMutableOrderedSet<NSString *> *values = [NSMutableOrderedSet
            orderedSetWithArray:[defaults arrayForKey:kMCMDeletedGeneratedPathsKey]
                ?: @[]];
        if ([values containsObject:key]) return;
        [values addObject:key];
        [defaults setObject:values.array forKey:kMCMDeletedGeneratedPathsKey];
        [defaults synchronize];
    }
    NSLog(@"[GeneratedFiles] recorded deletion %@", key);
}

static BOOL MCMWriteGeneratedString(NSString *text, NSString *path)
{
    if (MCMGeneratedPathWasDeleted(path)) {
        NSLog(@"[GeneratedFiles] kept deleted path absent %@", path);
        return NO;
    }
    return [text writeToFile:path atomically:YES
                    encoding:NSUTF8StringEncoding error:nil];
}

static BOOL MCMWriteGeneratedPropertyList(id value, NSString *path)
{
    if (MCMGeneratedPathWasDeleted(path)) {
        NSLog(@"[GeneratedFiles] kept deleted path absent %@", path);
        return NO;
    }
    return [value writeToFile:path atomically:YES];
}

static void MCMRunGeneratedDeletionProbe(NSFileManager *manager, NSString *root)
{
    const char *phaseValue = getenv("FILZA_GENERATED_DELETE_PROBE");
    if (!phaseValue || !phaseValue[0]) return;
    NSString *phase = [NSString stringWithUTF8String:phaseValue];
    if (![phase isEqualToString:@"record"] &&
        ![phase isEqualToString:@"verify"]) return;

    NSString *path = [root
        stringByAppendingPathComponent:@".filzaslop-generated-delete-probe.txt"];
    BOOL setup = YES;
    if ([phase isEqualToString:@"record"]) {
        [manager removeItemAtPath:path error:nil];
        setup = [@"probe" writeToFile:path atomically:YES
                              encoding:NSUTF8StringEncoding error:nil];
        MCMFilzaRecordDeletedGeneratedPath(path);
        setup = [manager removeItemAtPath:path error:nil] && setup;
    }

    BOOL writeResult = MCMWriteGeneratedString(@"must stay deleted", path);
    BOOL exists = [manager fileExistsAtPath:path];
    BOOL recorded = [MCMDeletedGeneratedPaths()
        containsObject:MCMGeneratedPathKey(path)];
    BOOL passed = setup && !writeResult && !exists && recorded;
    fprintf(stderr,
        "[GeneratedDeleteProbe] phase=%s setup=%d write=%d exists=%d recorded=%d pass=%d\n",
        phase.UTF8String, setup, writeResult, exists, recorded, passed);
    fflush(stderr);
}

NSString *MCMFilzaWallpaperLabName(void)
{
    return kMCMWallpaperLabDirectoryName;
}

static NSString *MCMKey(uint64_t containerClass, NSString *identifier)
{
    return [NSString stringWithFormat:@"%llu:%@", containerClass, identifier];
}

static NSString *MCMScopedKey(uint64_t containerClass, NSString *identifier,
                              uint64_t part, NSString *partDomain, uint64_t flags)
{
    return [NSString stringWithFormat:@"%llu:%@:%llu:%@:%llx", containerClass,
        identifier, part, partDomain ?: @"", flags];
}

static BOOL MCMSafeIdentifier(NSString *identifier)
{
    if (identifier.length == 0 || identifier.length > 255) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"];
    return [identifier rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound &&
        ![identifier isEqualToString:@"."] && ![identifier isEqualToString:@".."];
}

static NSString *MCMActivate(uint64_t containerClass, NSString *identifier,
                             BOOL group, NSString **error)
{
    MCMEnsureState();
    if (![MCMSignedCodeIdentifier() isEqualToString:kRequiredIdentifier]) {
        if (error) *error = @"signed code identifier is not the required MCM caller identity";
        return nil;
    }
    if (!MCMSafeIdentifier(identifier)) {
        if (error) *error = @"identifier contains unsupported path characters";
        return nil;
    }
    @synchronized (gLeases) {
        MCMLease *existing = gLeases[MCMKey(containerClass, identifier)];
        if (existing.rootPath.length)
            return existing.rootPath;
        NSString *detail = nil;
        MCMLease *lease = [MCMLease leaseForClass:containerClass identifier:identifier
            group:group part:0 flags:kMCMFlags error:&detail];
        BOOL activated = lease && [lease activate:&detail];
        if (!lease) {
            if (error) *error = detail ?: @"MCM activation failed";
            return nil;
        }
        // iOS 26 containermanagerd lacks genericExtensionsAllowedForAll, so it
        // refuses sandbox tokens for callers not in the per-class allowed set.
        // The path is still valid — try opening it before giving up.
        int descriptor = open(lease.rootPath.fileSystemRepresentation,
                              O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if (descriptor < 0) {
            if (!activated && !gUnrestrictedFilesystem) {
                if (error) *error = detail ?: @"MCM activation failed";
                [lease invalidate];
                return nil;
            }
            if (error) *error = [NSString stringWithFormat:@"container root open failed errno=%d", errno];
            [lease invalidate];
            return nil;
        }
        close(descriptor);
        gLeases[MCMKey(containerClass, identifier)] = lease;
        return lease.rootPath;
    }
}

static NSString *MCMActivateScoped(uint64_t containerClass, NSString *identifier,
                                   BOOL group, uint64_t part,
                                   NSString *partDomain, uint64_t flags,
                                   NSString **error)
{
    MCMEnsureState();
    if (![MCMSignedCodeIdentifier() isEqualToString:kRequiredIdentifier]) {
        if (error) *error = @"signed code identifier is not the required MCM caller identity";
        return nil;
    }
    if (!MCMSafeIdentifier(identifier)) {
        if (error) *error = @"identifier contains unsupported path characters";
        return nil;
    }
    NSString *key = MCMScopedKey(containerClass, identifier, part, partDomain, flags);
    @synchronized (gLeases) {
        MCMLease *existing = gLeases[key];
        if (existing.rootPath.length) return existing.rootPath;
        NSString *detail = nil;
        MCMLease *lease = [MCMLease leaseForClass:containerClass
            identifier:identifier group:group part:part partDomain:partDomain
            flags:flags error:&detail];
        BOOL activated = lease && [lease activate:&detail];
        if (!lease) {
            if (error) *error = detail ?: @"scoped MCM activation failed";
            return nil;
        }
        int descriptor = open(lease.rootPath.fileSystemRepresentation,
                              O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        if (descriptor < 0) {
            if (!activated) {
                if (error) *error = detail ?: @"scoped MCM activation failed";
                [lease invalidate];
                return nil;
            }
            if (error) *error = [NSString stringWithFormat:
                @"scoped directory open failed errno=%d", errno];
            [lease invalidate];
            return nil;
        }
        close(descriptor);
        gLeases[key] = lease;
        return lease.rootPath;
    }
}

NSString *MCMFilzaDataContainerPath(NSString *identifier, NSString **error)
{
    return MCMActivate(2, identifier, NO, error);
}

static BOOL MCMPathIsInsideRoot(NSString *path, NSString *root)
{
    NSString *(^normalized)(NSString *) = ^NSString *(NSString *value) {
        NSString *result = value.stringByStandardizingPath;
        if ([result isEqualToString:@"/var"] || [result hasPrefix:@"/var/"])
            result = [@"/private" stringByAppendingString:result];
        return result;
    };
    NSString *candidate = normalized(path);
    NSString *base = normalized(root);
    return [candidate isEqualToString:base] ||
        [candidate hasPrefix:[base stringByAppendingString:@"/"]];
}

BOOL MCMFilzaPathHasActiveLease(NSString *path)
{
    if (path.length == 0 || !path.isAbsolutePath) return NO;
    if (gUnrestrictedFilesystem) return YES;
    NSString *virtualRoot = MCMFilzaVirtualRoot();
    NSString *experimentalRoot = [virtualRoot
        stringByAppendingPathComponent:kMCMExperimentalDirectoryName];
    NSString *filesTraversalRoot = [virtualRoot
        stringByAppendingPathComponent:@"Files Traversal"];
    // The experimental consumer mounts are browse-first. Keep the custom
    // local paste path from turning a traversal check into a target mutation.
    if (MCMPathIsInsideRoot(path, experimentalRoot) ||
        MCMPathIsInsideRoot(path, filesTraversalRoot)) return NO;
    if (MCMPathIsInsideRoot(path, virtualRoot) ||
        MCMPathIsInsideRoot(path, MCMFilzaArchivePath())) return YES;
    if (MCMFilzaIsRunningInLiveContainer()) {
        for (NSString *root in MCMLiveContainerAuthorityRoots())
            if (MCMPathIsInsideRoot(path, root)) return YES;
        return NO;
    }
    MCMEnsureState();
    @synchronized (gLeases) {
        for (MCMLease *lease in gLeases.allValues)
            if (lease.activated && MCMPathIsInsideRoot(path, lease.rootPath)) return YES;
    }
    return NO;
}

static void MCMInstallLiveContainerLink(NSFileManager *manager, NSString *root,
                                        NSString *name, NSString *target)
{
    if (!target.length || !target.isAbsolutePath) return;
    BOOL isDirectory = NO;
    if (![manager fileExistsAtPath:target isDirectory:&isDirectory] || !isDirectory)
        return;

    NSString *link = [root stringByAppendingPathComponent:name];
    struct stat status = {0};
    if (lstat(link.fileSystemRepresentation, &status) == 0) {
        if (!S_ISLNK(status.st_mode)) {
            NSLog(@"[LiveContainer] keeping non-link path %@", link);
            return;
        }
        if (unlink(link.fileSystemRepresentation) != 0) {
            NSLog(@"[LiveContainer] could not refresh link %@ errno=%d", link, errno);
            return;
        }
    }
    if (symlink(target.fileSystemRepresentation, link.fileSystemRepresentation) != 0)
        NSLog(@"[LiveContainer] link failed %@ -> %@ errno=%d", link, target, errno);
    else
        NSLog(@"[LiveContainer] linked %@ -> %@", link, target);
}

static void MCMInstallArchiveAlias(NSFileManager *manager, NSString *root)
{
    NSString *archive = MCMFilzaArchivePath();
    NSError *error = nil;
    if (![manager createDirectoryAtPath:archive withIntermediateDirectories:YES
                             attributes:@{NSFilePosixPermissions: @0700}
                                  error:&error]) {
        NSLog(@"[Archive] directory creation failed path=%@ error=%@", archive, error);
        return;
    }

    NSString *link = [root stringByAppendingPathComponent:@"Archive"];
    struct stat status = {0};
    if (lstat(link.fileSystemRepresentation, &status) == 0) {
        if (!S_ISLNK(status.st_mode)) {
            NSLog(@"[Archive] keeping non-link path %@", link);
            return;
        }
        if (unlink(link.fileSystemRepresentation) != 0) {
            NSLog(@"[Archive] stale alias removal failed path=%@ errno=%d", link, errno);
            return;
        }
    }
    if (symlink(archive.fileSystemRepresentation, link.fileSystemRepresentation) != 0)
        NSLog(@"[Archive] alias failed %@ -> %@ errno=%d", link, archive, errno);
    else
        NSLog(@"[Archive] alias ready %@ -> %@", link, archive);
}

static void MCMInstallLiveContainerRoot(void)
{
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *root = MCMFilzaVirtualRoot();
    [manager createDirectoryAtPath:root withIntermediateDirectories:YES
                        attributes:@{NSFilePosixPermissions: @0700} error:nil];
    MCMInstallArchiveAlias(manager, root);

    NSString *hostHome = MCMAbsoluteEnvironmentPath("LC_HOME_PATH");
    NSString *hostDocuments = [hostHome stringByAppendingPathComponent:@"Documents"];
    NSString *sharedRoot = [MCMLiveContainerAppGroupPath()
        stringByAppendingPathComponent:@"LiveContainer"];

    NSArray<NSArray<NSString *> *> *links = @[
        @[@"[LiveContainer] Local Apps",
          [hostDocuments stringByAppendingPathComponent:@"Applications"] ?: @""],
        @[@"[LiveContainer] Local App Data",
          [hostDocuments stringByAppendingPathComponent:@"Data/Application"] ?: @""],
        @[@"[LiveContainer] Local App Groups",
          [hostDocuments stringByAppendingPathComponent:@"Data/AppGroup"] ?: @""],
        @[@"[LiveContainer] Shared Apps",
          [sharedRoot stringByAppendingPathComponent:@"Applications"] ?: @""],
        @[@"[LiveContainer] Shared App Data",
          [sharedRoot stringByAppendingPathComponent:@"Data/Application"] ?: @""],
        @[@"[LiveContainer] Shared App Groups",
          [sharedRoot stringByAppendingPathComponent:@"Data/AppGroup"] ?: @""],
    ];
    for (NSArray<NSString *> *entry in links)
        MCMInstallLiveContainerLink(manager, root, entry[0], entry[1]);

    NSString *readme = @"LiveContainer 兼容模式\n\n"
        @"这些链接显示此 LiveContainer 存储的应用和数据。\n"
        @"编辑会影响实时访客容器。\n\n"
        @"进程仍使用 LiveContainer 的签名身份。"
         "无法获得 MobileHouseArrest 对系统应用容器的访问权限。\n";
    MCMWriteGeneratedString(readme,
        [root stringByAppendingPathComponent:@"README.txt"]);
}

static void MCMInstallLinkWithFailureLogging(NSString *directory,
                                             NSString *identifier,
                                             uint64_t containerClass,
                                             BOOL group,
                                             BOOL logFailure)
{
    NSString *error = nil;
    NSString *target = MCMActivate(containerClass, identifier, group, &error);
    if (!target) {
        if (logFailure)
            NSLog(@"[MCMFilza] activation failed class=%llu id=%@ detail=%@",
                  containerClass, identifier, error);
        return;
    }
    NSString *link = [directory stringByAppendingPathComponent:identifier];
    struct stat status = {0};
    if (lstat(link.fileSystemRepresentation, &status) == 0) {
        if (!S_ISLNK(status.st_mode)) return;
        char current[PATH_MAX] = {0};
        ssize_t count = readlink(link.fileSystemRepresentation, current, sizeof(current) - 1);
        if (count > 0 && [[NSString stringWithUTF8String:current] isEqualToString:target]) return;
        unlink(link.fileSystemRepresentation);
    }
    if (symlink(target.fileSystemRepresentation, link.fileSystemRepresentation) != 0)
        NSLog(@"[MCMFilza] symlink failed id=%@ errno=%d", identifier, errno);
}

static void MCMInstallLink(NSString *directory, NSString *identifier,
                           uint64_t containerClass, BOOL group)
{
    MCMInstallLinkWithFailureLogging(directory, identifier, containerClass,
                                     group, YES);
}

static NSString *MCMDirectIdentifier(NSString *containerPath, NSString *fallback)
{
    NSString *metadataPath = [containerPath stringByAppendingPathComponent:
        @".com.apple.mobile_container_manager.metadata.plist"];
    NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
    NSString *identifier = [metadata[@"MCMMetadataIdentifier"]
        isKindOfClass:NSString.class] ? metadata[@"MCMMetadataIdentifier"] : nil;
    return MCMSafeIdentifier(identifier) ? identifier : fallback;
}

static void MCMInstallDirectFilesystemLinks(NSString *directory,
                                             NSString *containerRoot)
{
    if (!gUnrestrictedFilesystem) return;
    NSFileManager *manager = NSFileManager.defaultManager;
    NSArray<NSString *> *children = [manager contentsOfDirectoryAtPath:containerRoot
                                                                  error:nil];
    for (NSString *child in children ?: @[]) {
        if (!MCMSafeIdentifier(child)) continue;
        NSString *target = [containerRoot stringByAppendingPathComponent:child];
        BOOL isDirectory = NO;
        if (![manager fileExistsAtPath:target isDirectory:&isDirectory] || !isDirectory)
            continue;
        NSString *identifier = MCMDirectIdentifier(target, child);
        if (!MCMSafeIdentifier(identifier)) continue;
        NSString *link = [directory stringByAppendingPathComponent:identifier];
        struct stat status = {0};
        if (lstat(link.fileSystemRepresentation, &status) == 0) {
            if (!S_ISLNK(status.st_mode)) continue;
            unlink(link.fileSystemRepresentation);
        }
        if (symlink(target.fileSystemRepresentation, link.fileSystemRepresentation) != 0)
            NSLog(@"[MCMFilza] direct symlink failed id=%@ target=%@ errno=%d",
                  identifier, target, errno);
    }
}

static void MCMMigrateStorageEntry(NSFileManager *manager, NSString *directory,
                                   NSString *oldName, NSString *newName)
{
    if (oldName.length == 0 || newName.length == 0 ||
        [oldName isEqualToString:newName])
        return;

    NSString *source = [directory stringByAppendingPathComponent:oldName];
    NSString *destination = [directory stringByAppendingPathComponent:newName];
    if ([manager fileExistsAtPath:source] &&
        ![manager fileExistsAtPath:destination]) {
        NSError *error = nil;
        if (![manager moveItemAtPath:source toPath:destination error:&error])
            NSLog(@"[MCMFilza] label migration failed old=%@ new=%@ error=%@",
                  source, destination, error);
        else
            NSLog(@"[MCMFilza] label migration complete old=%@ new=%@",
                  source, destination);
    } else if ([manager fileExistsAtPath:source]) {
        NSLog(@"[MCMFilza] label migration skipped because destination exists old=%@ new=%@",
              source, destination);
    }
}

static void MCMMigrateLegacyTopLevelNames(NSFileManager *manager, NSString *root)
{
    NSArray<NSArray<NSString *> *> *migrations = @[
        @[@"App Data", @"[MHA-C2] App Data"],
        @[@"App Groups", @"[MHA-C7] App Groups"],
        @[@"Extension Data", @"[MHA-C4] Extension Data"],
        @[@"VPN Data", @"[MHA-C6] VPN Data"],
        @[@"Service Data", @"[MHA-C10] Service Data"],
        @[@"System Data", @"[MHA-C12] System Data"],
        @[@"System Groups", @"[MHA-C13] System Groups"],
        @[@"Protected Data", @"[MHA-C15] Protected Data"],
        @[@"Additional Locations", @"[MHA-C13 Scoped] Additional Locations"],
        @[@"Experimental", @"[MHA-Mixed EXP] Experimental"],
        @[@"Wallpaper Lab", @"[MHA-C2] Wallpaper Lab"],
    ];
    for (NSArray<NSString *> *migration in migrations)
        MCMMigrateStorageEntry(manager, root, migration[0], migration[1]);
}

static void MCMInstallScopedLink(NSString *directory, NSString *linkName,
                                 uint64_t containerClass, NSString *identifier,
                                 BOOL group, uint64_t part, NSString *partDomain)
{
    NSString *link = [directory stringByAppendingPathComponent:linkName];
    NSString *error = nil;
    NSString *target = MCMActivateScoped(containerClass, identifier, group, part,
        partDomain, kMCMReadWritePartFlags, &error);
    if (!target) {
        struct stat stale = {0};
        if (lstat(link.fileSystemRepresentation, &stale) == 0 &&
            S_ISLNK(stale.st_mode))
            unlink(link.fileSystemRepresentation);
        NSLog(@"[MCMFilza] scoped activation failed class=%llu id=%@ part=%llu domain=%@ detail=%@",
              containerClass, identifier, part, partDomain, error);
        return;
    }
    struct stat status = {0};
    if (lstat(link.fileSystemRepresentation, &status) == 0) {
        if (!S_ISLNK(status.st_mode)) return;
        char current[PATH_MAX] = {0};
        ssize_t count = readlink(link.fileSystemRepresentation, current, sizeof(current) - 1);
        if (count > 0 && [[NSString stringWithUTF8String:current] isEqualToString:target]) return;
        unlink(link.fileSystemRepresentation);
    }
    if (symlink(target.fileSystemRepresentation, link.fileSystemRepresentation) != 0)
        NSLog(@"[MCMFilza] scoped symlink failed name=%@ errno=%d", linkName, errno);
    else
        NSLog(@"[MCMFilza] scoped path ready name=%@ target=%@", linkName, target);
}

static NSDictionary *MCMExperimentalPathStatus(NSString *path)
{
    NSMutableDictionary *result = [@{ @"Path": path ?: @"" }
        mutableCopy];
    struct stat status = {0};
    errno = 0;
    if (path.length == 0 || lstat(path.fileSystemRepresentation, &status) != 0) {
        int savedErrno = errno;
        result[@"Exists"] = @NO;
        result[@"Errno"] = @(savedErrno);
        result[@"Error"] = [NSString stringWithUTF8String:strerror(savedErrno)]
            ?: @"未知错误";
        return result;
    }

    BOOL directory = S_ISDIR(status.st_mode);
    result[@"Exists"] = @YES;
    result[@"Kind"] = directory ? @"目录" :
        (S_ISREG(status.st_mode) ? @"文件" :
         (S_ISLNK(status.st_mode) ? @"符号链接" : @"其他"));
    result[@"Mode"] = [NSString stringWithFormat:@"%04o",
        status.st_mode & 07777];
    result[@"UID"] = @(status.st_uid);
    result[@"GID"] = @(status.st_gid);

    errno = 0;
    BOOL readable = access(path.fileSystemRepresentation, R_OK) == 0;
    int readErrno = readable ? 0 : errno;
    errno = 0;
    BOOL writable = access(path.fileSystemRepresentation, W_OK) == 0;
    int writeErrno = writable ? 0 : errno;
    int flags = O_RDONLY | O_CLOEXEC | (directory ? O_DIRECTORY : 0);
    errno = 0;
    int descriptor = open(path.fileSystemRepresentation, flags);
    int openErrno = descriptor >= 0 ? 0 : errno;
    if (descriptor >= 0) close(descriptor);
    result[@"Readable"] = @(readable);
    result[@"ReadErrno"] = @(readErrno);
    result[@"Writable"] = @(writable);
    result[@"WriteErrno"] = @(writeErrno);
    result[@"ReadOnlyOpen"] = @(descriptor >= 0);
    result[@"OpenErrno"] = @(openErrno);
    return result;
}

static void MCMRemoveStaleExperimentalLink(NSString *path)
{
    struct stat status = {0};
    if (lstat(path.fileSystemRepresentation, &status) == 0 &&
        S_ISLNK(status.st_mode))
        unlink(path.fileSystemRepresentation);
}

static BOOL MCMInstallExperimentalSymlink(NSString *path, NSString *target,
                                          NSString **error)
{
    struct stat status = {0};
    if (lstat(path.fileSystemRepresentation, &status) == 0) {
        if (!S_ISLNK(status.st_mode)) {
            if (error) *error = @"条目已存在且不是符号链接";
            return NO;
        }
        char current[PATH_MAX] = {0};
        ssize_t count = readlink(path.fileSystemRepresentation, current,
                                 sizeof(current) - 1);
        NSString *currentTarget = count > 0
            ? [NSString stringWithUTF8String:current] : nil;
        if ([currentTarget isEqualToString:target]) return YES;
        if (unlink(path.fileSystemRepresentation) != 0) {
            if (error) *error = [NSString stringWithFormat:
                @"移除旧符号链接失败，错误码=%d", errno];
            return NO;
        }
    }
    if (symlink(target.fileSystemRepresentation,
                path.fileSystemRepresentation) != 0) {
        if (error) *error = [NSString stringWithFormat:
            @"创建符号链接失败，错误码=%d", errno];
        return NO;
    }
    return YES;
}

static NSString *MCMCanonicalLexicalPath(NSString *path)
{
    NSString *result = path.stringByStandardizingPath;
    if ([result isEqualToString:@"/var"] || [result hasPrefix:@"/var/"])
        result = [@"/private" stringByAppendingString:result];
    return result;
}

static NSString *MCMRelativeSymlinkTarget(NSString *sourceDirectory,
                                          NSString *absoluteTarget)
{
    NSArray<NSString *> *source =
        MCMCanonicalLexicalPath(sourceDirectory).pathComponents;
    NSArray<NSString *> *target =
        MCMCanonicalLexicalPath(absoluteTarget).pathComponents;
    NSUInteger common = 0;
    while (common < source.count && common < target.count &&
           [source[common] isEqualToString:target[common]])
        common++;

    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSUInteger index = common; index < source.count; index++)
        [parts addObject:@".."];
    for (NSUInteger index = common; index < target.count; index++)
        if (![target[index] isEqualToString:@"/"])
            [parts addObject:target[index]];
    return parts.count ? [parts componentsJoinedByString:@"/"] : @".";
}

static void MCMInstallFilesTraversalFolder(NSString *directory)
{
    // Files has explicit home-relative authority for these roots on the
    // audited iOS 27 build. The two parent entries are retained as best-effort
    // boundary checks; a failed link open does not imply a broader primitive.
    NSArray<NSDictionary *> *portals = @[
        @{ @"Name": @"01 All Mobile Containers",
           @"Target": @"/private/var/mobile/Containers" },
        @{ @"Name": @"02 App Data",
           @"Target": @"/private/var/mobile/Containers/Data/Application" },
        @{ @"Name": @"03 Extension Data",
           @"Target": @"/private/var/mobile/Containers/Data/PluginKitPlugin" },
        @{ @"Name": @"04 VPN Data",
           @"Target": @"/private/var/mobile/Containers/Data/VPNPlugin" },
        @{ @"Name": @"05 Internal Daemon Data",
           @"Target": @"/private/var/mobile/Containers/Data/InternalDaemon" },
        @{ @"Name": @"06 System Data",
           @"Target": @"/private/var/mobile/Containers/Data/System" },
        @{ @"Name": @"07 Protected Data",
           @"Target": @"/private/var/mobile/Containers/Data/Protected" },
        @{ @"Name": @"08 App Groups",
           @"Target": @"/private/var/mobile/Containers/Shared/AppGroup" },
        @{ @"Name": @"09 Shortcuts",
           @"Target": @"/private/var/mobile/Library/Shortcuts" },
        @{ @"Name": @"10 Cloud Storage",
           @"Target": @"/private/var/mobile/Library/CloudStorage" },
        @{ @"Name": @"11 Mobile Documents",
           @"Target": @"/private/var/mobile/Library/Mobile Documents" },
        @{ @"Name": @"12 Live Files",
           @"Target": @"/private/var/mobile/Library/LiveFiles" },
        @{ @"Name": @"13 Mobile Library - Best Effort",
           @"Target": @"/private/var/mobile/Library" },
        @{ @"Name": @"14 Mobile Home - Best Effort",
           @"Target": @"/private/var/mobile" },
    ];

    NSMutableArray<NSDictionary *> *results = [NSMutableArray array];
    for (NSDictionary *portal in portals) {
        NSString *name = portal[@"Name"];
        NSString *absoluteTarget = portal[@"Target"];
        NSString *relativeTarget = MCMRelativeSymlinkTarget(directory,
                                                             absoluteTarget);
        NSString *linkPath = [directory stringByAppendingPathComponent:name];
        NSString *detail = nil;
        BOOL created = MCMInstallExperimentalSymlink(linkPath, relativeTarget,
                                                      &detail);
        NSMutableDictionary *result = [portal mutableCopy];
        result[@"LinkPath"] = linkPath;
        result[@"RelativeTarget"] = relativeTarget;
        result[@"Created"] = @(created);
        result[@"SourceAppTargetStatus"] =
            MCMExperimentalPathStatus(absoluteTarget);
        if (!created) result[@"Error"] = detail ?: @"创建链接失败";
        [results addObject:result];
        NSLog(@"[MCMFilza] Files portal name=%@ relative=%@ created=%d detail=%@",
              name, relativeTarget, created, detail);
    }

    NSString *readme = @"Files 遍历入口\n\n"
        @"请通过 Apple 文件访问这些链接，不要在 Filza 中打开：\n"
        @"文件 > 在我的 iPhone 上 > Filza Mod > 设备存储 > Files Traversal\n\n"
        @"Files 使用自己的权限解析相对链接。Filza 仍受沙盒限制，因此入口在 Files 中可用时，在 Filza 中可能显示为空或打开失败。\n\n"
        @"这些链接指向实时数据。在 Files 中创建、复制、重命名、移动和删除会修改其他应用的真实容器。查看最安全。本文件夹不会创建 .Trash 链接。\n\n"
        @"Portal Results.plist 记录链接目标和 Filza 自身的检查结果。SourceAppTargetStatus 中出现 EPERM 属于预期，不能据此判断 Files 是否可以打开入口。Best Effort 条目可能会被 Files 拒绝。\n";
    MCMWriteGeneratedString(readme,
        [directory stringByAppendingPathComponent:@"README.txt"]);
    MCMWriteGeneratedPropertyList(results, [directory
        stringByAppendingPathComponent:@"Portal Results.plist"]);
}

static NSDictionary *MCMRunExperimentalProbe(NSString *directory,
                                              NSDictionary *probe)
{
    NSString *name = [probe[@"Name"] isKindOfClass:NSString.class]
        ? probe[@"Name"] : @"Unnamed Probe";
    uint64_t containerClass = [probe[@"Class"] unsignedLongLongValue];
    NSString *identifier = [probe[@"Identifier"] isKindOfClass:NSString.class]
        ? probe[@"Identifier"] : @"";
    BOOL group = [probe[@"Group"] boolValue];
    uint64_t part = [probe[@"Part"] unsignedLongLongValue];
    uint64_t flags = [probe[@"Flags"] unsignedLongLongValue];
    NSString *partDomain = [probe[@"PartDomain"] isKindOfClass:NSString.class]
        ? probe[@"PartDomain"] : nil;
    NSArray *expected = [probe[@"Expected"] isKindOfClass:NSArray.class]
        ? probe[@"Expected"] : @[];
    NSString *linkPath = [directory stringByAppendingPathComponent:name];

    NSMutableDictionary *result = [probe mutableCopy];
    result[@"FlagsHex"] = [NSString stringWithFormat:@"0x%llx", flags];
    [result removeObjectForKey:@"Flags"];
    NSString *detail = nil;
    NSString *target = MCMActivateScoped(containerClass, identifier, group,
        part, partDomain, flags, &detail);
    if (!target) {
        MCMRemoveStaleExperimentalLink(linkPath);
        result[@"Status"] = @"failed";
        result[@"Error"] = detail ?: @"激活失败";
        return result;
    }

    result[@"ReturnedPath"] = target;
    result[@"ReturnedPathStatus"] = MCMExperimentalPathStatus(target);
    NSMutableArray *expectedStatuses = [NSMutableArray array];
    for (id relativeValue in expected) {
        if (![relativeValue isKindOfClass:NSString.class]) continue;
        NSString *relative = relativeValue;
        NSString *expectedPath = [target stringByAppendingPathComponent:relative];
        NSMutableDictionary *expectedStatus =
            [MCMExperimentalPathStatus(expectedPath) mutableCopy];
        expectedStatus[@"RelativePath"] = relative;
        [expectedStatuses addObject:expectedStatus];
    }
    result[@"ExpectedPathStatus"] = expectedStatuses;

    NSString *linkError = nil;
    BOOL linked = MCMInstallExperimentalSymlink(linkPath, target, &linkError);
    result[@"Status"] = linked ? @"linked" : @"failed";
    result[@"LinkPath"] = linkPath;
    if (!linked) result[@"Error"] = linkError ?: @"创建链接失败";
    NSLog(@"[MCMFilza] experimental name=%@ class=%llu id=%@ part=%llu domain=%@ status=%@ target=%@ error=%@",
          name, containerClass, identifier, part, partDomain,
          result[@"Status"], target, result[@"Error"]);
    return result;
}

static void MCMInstallExperimentalFolder(NSString *directory)
{
    NSFileManager *manager = NSFileManager.defaultManager;
    NSArray<NSArray<NSString *> *> *nameMigrations = @[
        @[@"01 Install Coordination", @"01 [MHA-C13] Install Coordination"],
        @[@"02 MobileGestalt Cache", @"02 [MHA-C13] MobileGestalt Cache"],
        @[@"03 Eligibility Overrides", @"03 [MHA-C12] Eligibility Overrides"],
        @[@"04 App Managed Data", @"04 [MHA-C15] App Managed Data"],
        @[@"05 Configuration Profiles Root",
          @"05 [MHA-C13] Configuration Profiles Root"],
        @[@"06 Shared Web Credentials Root",
          @"06 [MHA-C10] Shared Web Credentials Root"],
        @[@"07 System Data Library Control",
          @"07 [MHA-C12] System Data Library Control"],
        @[@"08 MobileGestalt via System Data",
          @"08 [MHA-C12] MobileGestalt via System Data"],
    ];
    for (NSArray<NSString *> *migration in nameMigrations)
        MCMMigrateStorageEntry(manager, directory, migration[0], migration[1]);

    NSArray<NSDictionary *> *probes = @[
        @{
            @"Name": @"01 [MHA-C13] Install Coordination",
            @"Class": @13,
            @"Identifier": @"systemgroup.com.apple.installcoordinationd",
            @"Group": @YES,
            @"Part": @3,
            @"PartDomain": @"../InstallCoordination",
            @"Flags": @(kMCMReadWritePartFlags),
            @"Expected": @[@"Coordinators", @"DataPromises",
                            @"PromiseStaging"],
        },
        @{
            @"Name": @"02 [MHA-C13] MobileGestalt Cache",
            @"Class": @13,
            @"Identifier": @"systemgroup.com.apple.mobilegestaltcache",
            @"Group": @YES,
            @"Part": @3,
            @"Flags": @(kMCMReadWritePartFlags),
            @"Expected": @[@"com.apple.MobileGestalt.plist"],
        },
        @{
            @"Name": @"03 [MHA-C12] Eligibility Overrides",
            @"Class": @12,
            @"Identifier": @"com.apple.eligibilityd",
            @"Group": @NO,
            @"Part": @3,
            @"PartDomain": @"NeverRestore",
            @"Flags": @(kMCMReadWritePartFlags),
            @"Expected": @[@"eligibility_overrides.data"],
        },
        @{
            @"Name": @"04 [MHA-C15] App Managed Data",
            @"Class": @15,
            @"Identifier": @"com.apple.appmanagedfeaturesd",
            @"Group": @NO,
            @"Part": @0,
            @"Flags": @(kMCMReadWritePartFlags),
            @"Expected": @[
                @"com.apple.appmanagedfeaturesd/ConfigurationPersistence",
                @"com.apple.appmanagedfeaturesd/Archive/ConfigurationPersistence",
            ],
        },
        @{
            @"Name": @"05 [MHA-C13] Configuration Profiles Root",
            @"Class": @13,
            @"Identifier": @"systemgroup.com.apple.configurationprofiles",
            @"Group": @YES,
            @"Part": @0,
            @"Flags": @(kMCMReadWritePartFlags),
            @"Expected": @[
                @"Library/ConfigurationProfiles/PayloadManifest.plist",
            ],
        },
        @{
            @"Name": @"06 [MHA-C10] Shared Web Credentials Root",
            @"Class": @10,
            @"Identifier": @"com.apple.swcd",
            @"Group": @NO,
            @"Part": @0,
            @"Flags": @(kMCMFlags),
            @"Expected": @[@"com.apple.SharedWebCredentials/swc.db"],
        },
        @{
            @"Name": @"07 [MHA-C12] System Data Library Control",
            @"Class": @12,
            @"Identifier": @"com.apple.geod",
            @"Group": @NO,
            @"Part": @3,
            @"PartDomain": @"..",
            @"Flags": @(kMCMReadWritePartFlags),
            @"Expected": @[@"Caches", @"Preferences"],
        },
        @{
            @"Name": @"08 [MHA-C12] MobileGestalt via System Data",
            @"Class": @12,
            @"Identifier": @"com.apple.geod",
            @"Group": @NO,
            @"Part": @3,
            @"PartDomain": @"../../../../../../containers/Shared/SystemGroup/"
                @"systemgroup.com.apple.mobilegestaltcache/Library/Caches",
            @"Flags": @(kMCMReadWritePartFlags),
            @"Expected": @[@"com.apple.MobileGestalt.plist"],
        },
    ];

    NSMutableArray<NSDictionary *> *results = [NSMutableArray array];
    for (NSDictionary *probe in probes)
        [results addObject:MCMRunExperimentalProbe(directory, probe)];

    NSString *readme = @"实验性消费者遍历\n\n"
        @"MHA 表示 MobileHouseArrest 身份信任绕过。C10、C12、C13 和 C15 表示每个链接使用的 ContainerManager 类别。\n"
        @"这些是 class 10/12/13/15 审计中发现的、供系统服务读取文件的固定启动探测。\n"
        @"只有在 ContainerManager 返回令牌、激活成功且返回目录可以只读打开后，才会创建链接。\n"
        @"探测设置不会创建或修改目标文件。本文件夹内已禁用 Filza 自定义复制/粘贴路径。\n"
        @"链接仍指向实时目录；除非已单独备份并制定精确恢复方案，否则不要编辑候选文件。\n\n"
        @"Probe Results.plist 记录查询失败信息，以及每个预期消费者路径的读/写/打开状态。\n";
    MCMWriteGeneratedString(readme,
        [directory stringByAppendingPathComponent:@"README.txt"]);
    MCMWriteGeneratedPropertyList(results, [directory
        stringByAppendingPathComponent:@"Probe Results.plist"]);
}

static BOOL MCMLaunchServicesIdentifierByte(uint8_t value)
{
    return (value >= 'a' && value <= 'z') ||
        (value >= 'A' && value <= 'Z') ||
        (value >= '0' && value <= '9') ||
        value == '.' || value == '-' || value == '_';
}

static NSArray<NSString *> *MCMExpectedIdentifiersFromEnvironment(void)
{
    const char *value = getenv("FILZA_MCM_EXPECT_IDENTIFIERS");
    if (!value || !value[0]) return @[];
    NSString *joined = [NSString stringWithUTF8String:value];
    NSMutableOrderedSet<NSString *> *result = [NSMutableOrderedSet orderedSet];
    for (NSString *identifier in [joined componentsSeparatedByString:@","])
        if (MCMSafeIdentifier(identifier)) [result addObject:identifier];
    return result.array;
}

static void MCMLogExpectedIdentifierCoverage(NSString *label,
                                             NSSet<NSString *> *actual)
{
    NSArray<NSString *> *expected = MCMExpectedIdentifiersFromEnvironment();
    if (expected.count == 0) return;
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    for (NSString *identifier in expected)
        if (![actual containsObject:identifier]) [missing addObject:identifier];
    NSLog(@"[MCMFilza] %@ expected=%lu matched=%lu missing=%@", label,
          (unsigned long)expected.count,
          (unsigned long)(expected.count - missing.count), missing);
}

static void MCMResetAppLinksForTesting(NSString *directory)
{
    if (!getenv("FILZA_MCM_RESET_APP_LINKS")) return;
    NSFileManager *manager = NSFileManager.defaultManager;
    for (NSString *name in [manager contentsOfDirectoryAtPath:directory error:nil] ?: @[]) {
        NSString *path = [directory stringByAppendingPathComponent:name];
        struct stat status = {0};
        if (lstat(path.fileSystemRepresentation, &status) == 0 &&
            S_ISLNK(status.st_mode))
            unlink(path.fileSystemRepresentation);
    }
    NSLog(@"[MCMFilza] reset App Data links for test");
}

static NSArray<NSString *> *MCMLaunchServicesStoreIdentifiers(void)
{
    static const NSUInteger kMaximumCandidateCount = 65536;
    NSString *error = nil;
    NSString *container = MCMActivate(10, @"com.apple.lsd", NO, &error);
    if (!container.length) {
        NSLog(@"[MCMFilza] LaunchServices store unavailable detail=%@", error);
        return @[];
    }
    NSString *caches = [container stringByAppendingPathComponent:@"Library/Caches"];
    NSArray<NSString *> *names = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:caches error:nil];
    NSMutableOrderedSet<NSString *> *result = [NSMutableOrderedSet orderedSet];
    BOOL reachedLimit = NO;
    for (NSString *name in names ?: @[]) {
        if (![name hasPrefix:@"com.apple.LaunchServices-"] ||
            ![name hasSuffix:@"-v2.csstore"])
            continue;
        NSString *path = [caches stringByAppendingPathComponent:name];
        NSNumber *size = [[NSFileManager.defaultManager attributesOfItemAtPath:path
            error:nil] objectForKey:NSFileSize];
        if (!size || size.unsignedLongLongValue == 0 ||
            size.unsignedLongLongValue > 64 * 1024 * 1024)
            continue;
        NSError *readError = nil;
        NSData *data = [NSData dataWithContentsOfFile:path
            options:NSDataReadingMappedIfSafe error:&readError];
        if (!data) {
            NSLog(@"[MCMFilza] LaunchServices store read failed path=%@ error=%@",
                  path, readError);
            continue;
        }
        const uint8_t *bytes = data.bytes;
        NSUInteger start = NSNotFound;
        for (NSUInteger index = 0; index <= data.length; index++) {
            BOOL allowed = index < data.length &&
                MCMLaunchServicesIdentifierByte(bytes[index]);
            if (allowed) {
                if (start == NSNotFound) start = index;
                continue;
            }
            if (start == NSNotFound) continue;
            NSUInteger length = index - start;
            if (length >= 3 && length <= 255) {
                NSString *identifier = [[NSString alloc]
                    initWithBytes:bytes + start length:length
                    encoding:NSUTF8StringEncoding];
                BOOL malformedDots = [identifier containsString:@".."];
                BOOL looksLikeIdentifier = MCMSafeIdentifier(identifier) &&
                    [identifier containsString:@"."] &&
                    ![identifier hasPrefix:@"."] &&
                    ![identifier hasSuffix:@"."] && !malformedDots;
                if (looksLikeIdentifier) {
                    [result addObject:identifier];
                    if (result.count >= kMaximumCandidateCount) {
                        reachedLimit = YES;
                        break;
                    }
                }
            }
            start = NSNotFound;
        }
        NSLog(@"[MCMFilza] LaunchServices store path=%@ bytes=%lu candidates=%lu",
              path, (unsigned long)data.length, (unsigned long)result.count);
        if (reachedLimit) break;
    }
    if (reachedLimit)
        NSLog(@"[MCMFilza] LaunchServices store candidate limit reached");
    NSLog(@"[MCMFilza] LaunchServices store total candidates=%lu",
          (unsigned long)result.count);
    MCMLogExpectedIdentifierCoverage(@"LaunchServices store",
        [NSSet setWithArray:result.array]);
    return result.array;
}

static NSArray<NSString *> *MCMInstalledApplicationIdentifiers(void)
{
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    id workspace = [workspaceClass respondsToSelector:@selector(defaultWorkspace)]
        ? [workspaceClass defaultWorkspace] : nil;
    NSArray *applications = [workspace respondsToSelector:@selector(allApplications)]
        ? [workspace allApplications] : @[];
    NSMutableOrderedSet<NSString *> *result = [NSMutableOrderedSet orderedSet];
    for (id proxy in applications) {
        NSString *identifier = [proxy respondsToSelector:@selector(applicationIdentifier)]
            ? [proxy applicationIdentifier] : nil;
        if (!MCMSafeIdentifier(identifier) &&
            [proxy respondsToSelector:@selector(bundleIdentifier)])
            identifier = [proxy bundleIdentifier];
        if (MCMSafeIdentifier(identifier)) [result addObject:identifier];
        if (result.count >= 1024) break;
    }

    return result.array;
}

static NSArray<NSString *> *MCMResearchTargetIdentifiers(void)
{
    // Enumeration via container_query_iterate_results_sync returns near-empty
    // results on iOS 26 even though direct lookups succeed. Seed all known
    // first-party identifiers so the MHA bypass can resolve them by name.
    return @[
        @"com.apple.mobilesafari",
        @"com.apple.mobilenotes",
        @"com.apple.Maps",
        @"com.apple.facetime",
        @"com.apple.iBooks",
        @"com.apple.podcasts",
        @"com.apple.PosterBoard",
        @"com.apple.mobilemail",
        @"com.apple.weather",
        @"com.apple.camera",
        @"com.apple.Health",
        @"com.apple.Fitness",
        @"com.apple.tips",
        @"com.apple.Passbook",
        @"com.apple.reminders",
        @"com.apple.stocks",
        @"com.apple.news",
        @"com.apple.Home",
        @"com.apple.tv",
        @"com.apple.shortcuts",
        @"com.apple.freeform",
        @"com.apple.calculator",
        @"com.apple.MobileSMS",
        @"com.apple.InCallService",
        @"com.apple.Preferences",
        @"com.apple.springboard",
        @"com.apple.Photos",
        @"com.apple.AppStore",
        @"com.apple.Music",
        @"com.apple.Bridge",
        @"com.apple.Clock",
        @"com.apple.VoiceMemos",
        @"com.apple.Translate",
        @"com.apple.measure",
        @"com.apple.compass",
        @"com.apple.Magnifier",
        @"com.apple.DocumentsApp",
    ];
}

static NSArray<NSString *> *MCMCustomIdentifierKeys(void)
{
    return @[
        @"AppData",
        @"AppGroups",
        @"ExtensionData",
        @"VPNData",
        @"ServiceData",
        @"SystemData",
        @"SystemGroups",
        @"ProtectedData",
    ];
}

static NSArray<NSString *> *MCMDynamicIdentifiers(uint64_t containerClass)
{
    NSString *error = nil;
    NSArray *identifiers = MCMEnumerateIdentifiersForClass(containerClass, 1024, &error);
    NSLog(@"[MCMFilza] discovery class=%llu count=%lu detail=%@", containerClass,
          (unsigned long)identifiers.count, error);
    NSMutableArray *safe = [NSMutableArray arrayWithCapacity:identifiers.count];
    for (NSString *identifier in identifiers)
        if (MCMSafeIdentifier(identifier)) [safe addObject:identifier];
    return safe;
}

static NSDictionary *MCMCustomIdentifiers(void)
{
    if (getenv("FILZA_MCM_IGNORE_CUSTOM_IDENTIFIERS")) {
        NSMutableDictionary *empty = [NSMutableDictionary dictionary];
        for (NSString *key in MCMCustomIdentifierKeys()) empty[key] = @[];
        return empty;
    }
    NSString *documentsPath = [MCMFilzaVirtualRoot().stringByDeletingLastPathComponent
        stringByAppendingPathComponent:@"MCMIdentifiers.plist"];
    NSString *bundlePath = [NSBundle.mainBundle pathForResource:@"MCMIdentifiers"
                                                         ofType:@"plist"];
    NSMutableDictionary *merged = [NSMutableDictionary dictionary];
    for (NSString *key in MCMCustomIdentifierKeys())
        merged[key] = [NSMutableOrderedSet orderedSet];
    for (NSString *path in @[bundlePath ?: @"", documentsPath]) {
        NSDictionary *value = [NSDictionary dictionaryWithContentsOfFile:path];
        if (![value isKindOfClass:NSDictionary.class]) continue;
        for (NSString *key in merged) {
            NSArray *identifiers = [value[key] isKindOfClass:NSArray.class] ? value[key] : @[];
            for (id identifier in identifiers)
                if ([identifier isKindOfClass:NSString.class] && MCMSafeIdentifier(identifier))
                    [merged[key] addObject:identifier];
        }
    }
    for (NSString *key in MCMCustomIdentifierKeys())
        merged[key] = [merged[key] array];
    return merged;
}

static void MCMWriteInstructions(void)
{
    NSString *path = [MCMFilzaVirtualRoot() stringByAppendingPathComponent:@"README.txt"];
    NSString *text = @"设备存储研究构建\n\n"
        @"MHA 表示 MobileHouseArrest 身份信任绕过。C2 到 C15 表示每个文件夹使用的 ContainerManager 类别。\n"
        @"[MHA-C2] App Data 包含根据已安装应用标识解析出的 class-2 容器。\n"
        @"这些是实时私有容器，不是副本。Filza 中的编辑会影响目标应用。\n"
        @"[MHA-Mixed EXP] Experimental 包含固定的消费者遍历探测，并在 Probe Results.plist 中记录失败信息。\n"
        @"其中已禁用自定义复制/粘贴路径，但成功的链接仍指向实时目录。\n"
        @"此构建不提供 root、内核读写、任意 /var、Keychain、TCC 或应用包访问权限。\n\n"
        @"可选目标配置记录在研究源码仓库中。\n";
    MCMWriteGeneratedString(text, path);
}

static NSArray<NSDictionary<NSString *, NSString *> *> *
MCMSymlinkAccessEntries(NSFileManager *manager, NSString *directory)
{
    NSArray<NSString *> *names = [[manager contentsOfDirectoryAtPath:directory
                                                               error:nil]
        sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *entries =
        [NSMutableArray array];
    for (NSString *name in names ?: @[]) {
        NSString *path = [directory stringByAppendingPathComponent:name];
        struct stat status = {0};
        if (lstat(path.fileSystemRepresentation, &status) != 0 ||
            !S_ISLNK(status.st_mode))
            continue;

        char target[PATH_MAX] = {0};
        ssize_t count = readlink(path.fileSystemRepresentation, target,
                                 sizeof(target) - 1);
        if (count <= 0) continue;
        target[count] = '\0';
        NSString *targetPath = [NSString stringWithUTF8String:target];
        if (targetPath.length == 0) continue;
        [entries addObject:@{@"Name": name, @"Target": targetPath}];
    }
    return entries;
}

static void MCMAppendSymlinkAccess(NSMutableString *text,
                                   NSArray<NSDictionary<NSString *, NSString *> *> *entries)
{
    if (entries.count == 0) {
        [text appendString:@"已启用的根目录：无。\n"];
        return;
    }
    [text appendString:@"已启用的根目录：\n"];
    for (NSDictionary<NSString *, NSString *> *entry in entries) {
        [text appendFormat:@"• %@\n  根目录：%@\n",
            entry[@"Name"], entry[@"Target"]];
    }
    [text appendString:
        @"沙盒扩展覆盖上面列出的每个根目录。对子目录的访问仍受文件系统和数据保护机制控制。\n"];
}

static void MCMAppendExperimentalSubpaths(NSMutableString *text,
                                          NSString *experimentalDirectory)
{
    NSString *resultsPath = [experimentalDirectory
        stringByAppendingPathComponent:@"Probe Results.plist"];
    NSArray<NSDictionary *> *results = [NSArray arrayWithContentsOfFile:resultsPath];
    if (results.count == 0) return;

    [text appendString:@"\n实验性功能返回的路径和已检查的子路径：\n"];
    for (NSDictionary *result in results) {
        NSString *name = [result[@"Name"] isKindOfClass:NSString.class]
            ? result[@"Name"] : @"未命名探测";
        NSString *returnedPath = [result[@"ReturnedPath"] isKindOfClass:NSString.class]
            ? result[@"ReturnedPath"] : nil;
        NSString *status = result[@"Status"];
        if ([status isEqualToString:@"linked"]) status = @"已链接";
        else if ([status isEqualToString:@"failed"]) status = @"失败";
        else if (!status.length) status = @"未知";
        [text appendFormat:@"• %@ — 状态：%@\n", name, status];
        if (returnedPath.length > 0)
            [text appendFormat:@"  返回的根目录：%@\n", returnedPath];

        NSArray<NSDictionary *> *subpaths =
            [result[@"ExpectedPathStatus"] isKindOfClass:NSArray.class]
                ? result[@"ExpectedPathStatus"] : @[];
        for (NSDictionary *subpath in subpaths) {
            NSString *path = [subpath[@"Path"] isKindOfClass:NSString.class]
                ? subpath[@"Path"] : @"<未知>";
            NSString *exists = [subpath[@"Exists"] boolValue] ? @"是" : @"否";
            NSString *readable = [subpath[@"Readable"] boolValue] ? @"是" : @"否";
            NSString *writable = [subpath[@"Writable"] boolValue] ? @"是" : @"否";
            NSString *open = [subpath[@"ReadOnlyOpen"] boolValue] ? @"是" : @"否";
            [text appendFormat:
                @"  已检查子路径：%@ — 存在=%@ 可读=%@ 可写=%@ 可打开=%@\n",
                path,
                exists, readable, writable, open];
        }
    }
}

static void MCMWriteAccessReadme(NSFileManager *manager, NSString *directory,
                                 NSString *text)
{
    BOOL isDirectory = NO;
    if (![manager fileExistsAtPath:directory isDirectory:&isDirectory] ||
        !isDirectory)
        return;
    NSString *path = [directory
        stringByAppendingPathComponent:@"README - Access.txt"];
    MCMWriteGeneratedString(text, path);
}

static void MCMAppendUnifiedFindingMap(NSMutableString *map)
{
    [map appendString:
        @"根因图\n\n"
         "问题 A —— MobileHouseArrest 身份信任绕过\n"
         "组件：MobileContainerManager 和 containermanagerd。\n"
         "触发条件：应用具有签名代码标识 com.apple.mobile.MobileHouseArrest。\n"
         "原理：MobileContainerManager 接受该调用者身份，并签发其他容器的沙盒扩展。\n"
         "当前 24A5390f 证据：class-2 Safari、class-2 Notes 和 class-7 Notes 组根目录均通过令牌激活和 readdir。普通身份控制组拒绝了全部三个目标，不存在的目标也被拒绝。\n"
         "关联：下面标记的 Filza 文件夹使用同一个身份信任绕过，但对应不同的容器类别。\n\n"

         "问题 B —— 内置 class-12 geod 查找和 part-domain 遍历\n"
         "组件：MobileContainerManager 和 containermanagerd。\n"
         "触发条件：class 12、标识 com.apple.geod。ContainerManagerCommon 将 geod 列入内置查找绕过列表。\n"
         "当前 24A5390f 证据：container_system_path_for_identifier 返回 /private/var/containers/Data/System/com.apple.geod，readdir 列出了 Documents、Library、tmp 和元数据 plist。打开元数据 plist 仍因 EPERM 失败。\n"
         "存档的 24A5380h 证据：class 12、part 3、flags 0x8100000000 和遍历 part-domain 到达 MobileGestalt Caches 目录。275 字节的读写扩展允许写入指定的 plist 标记，测试随后恢复了原始 inode 和 SHA-256。\n"
         "关联：此路径不需要 MobileHouseArrest 身份。geod 允许路径和未检查的 part-domain 是两个独立的授权缺陷。\n\n"

         "问题 C —— class-13 已知 MobileGestalt 组授权缺口\n"
         "组件：MobileContainerManager 和 containermanagerd。\n"
         "触发条件：class 13、组 systemgroup.com.apple.mobilegestaltcache、part 3 和 flags 0x8100000000。\n"
         "目标根目录：/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches\n"
         "目标文件：/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches/com.apple.MobileGestalt.plist\n"
         "存档的 24A5380h 证据：普通沙盒调用者获得了 275 字节的读写扩展，写入指定的 CodexMCMWriteProof 标记，验证字节后恢复了原始 inode 和 SHA-256。\n"
         "当前 24A5390f 边界：简单的系统组路径和 class-13 查询均被拒绝。这些简单查询没有重复存档中的 part-3 读写请求。\n"
         "关联：此授权缺口与 MobileHouseArrest 身份信任绕过相互独立。\n\n"

         "已拒绝路径 —— 原始 ProxyForClient 欺骗\n"
         "当前 24A5390f 证据：原始 containermanagerd command 39 拒绝了 MobileHouseArrest、mobile_installation_proxy、filecoordinationd、accountsd 和 Safari.History 身份。没有任何回复包含容器路径或沙盒令牌。\n\n"

         "MobileGestalt 路径摘要\n"
         "直接路径：class-13 已知组授权缺口 -> MobileGestalt Caches。\n"
         "转接路径：class-12 geod 允许路径 -> part-3 域遍历 -> MobileGestalt Caches。\n"
         "两条路径都到达同一个固定目标。两者都不能证明可以访问任意 /var。\n"
         "本文件没有声称拥有 root、内核、Keychain、TCC 或应用包访问权限。\n\n"

         "当前 Filza 访问情况\n"
         "下面的章节会在本次启动期间生成。\n"
         "只有在令牌激活并通过目录打开检查后创建的直接符号链接，才会显示为已启用根目录。\n"
         "实验性章节还会显示每个已检查的子路径及其当前打开状态。\n\n"];
}

static NSString *MCMDisplayStorageName(NSString *name)
{
    NSDictionary<NSString *, NSString *> *names = @{
        kMCMAppDataDirectoryName: @"[MHA-C2] 应用数据",
        kMCMAppGroupsDirectoryName: @"[MHA-C7] 应用组",
        kMCMExtensionDataDirectoryName: @"[MHA-C4] 扩展数据",
        kMCMVPNDataDirectoryName: @"[MHA-C6] VPN 数据",
        kMCMServiceDataDirectoryName: @"[MHA-C10] 服务数据",
        kMCMSystemDataDirectoryName: @"[MHA-C12] 系统数据",
        kMCMSystemGroupsDirectoryName: @"[MHA-C13] 系统组",
        kMCMProtectedDataDirectoryName: @"[MHA-C15] 受保护数据",
        kMCMAdditionalLocationsDirectoryName: @"[MHA-C13 Scoped] 其他位置",
        kMCMExperimentalDirectoryName: @"[MHA-Mixed EXP] 实验性功能",
        kMCMWallpaperLabDirectoryName: @"[MHA-C2] 壁纸实验室",
    };
    return names[name] ?: name;
}

static NSString *MCMSpringBoardPreferencesWriteCheck(void)
{
    static const char *target =
        "/private/var/mobile/Library/Preferences/com.apple.springboard.plist";
    struct stat targetStatus = {0};
    errno = 0;
    int statResult = lstat(target, &targetStatus);
    int statErrno = statResult == 0 ? 0 : errno;

    errno = 0;
    int readDescriptor = open(target, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    int readErrno = readDescriptor >= 0 ? 0 : errno;
    if (readDescriptor >= 0) close(readDescriptor);

    errno = 0;
    int writeDescriptor = open(target, O_RDWR | O_CLOEXEC | O_NOFOLLOW);
    int writeErrno = writeDescriptor >= 0 ? 0 : errno;
    if (writeDescriptor >= 0) close(writeDescriptor);

    NSString *verdict = nil;
    const char *notification = NULL;
    if (writeDescriptor >= 0) {
        verdict = @"可写描述符";
        notification =
            "local.research.mcm.springboardprefs.writable";
    } else if (writeErrno == EPERM || writeErrno == EACCES) {
        verdict = @"拒绝";
        notification =
            "local.research.mcm.springboardprefs.denied";
    } else if (writeErrno == ENOENT) {
        verdict = @"缺失";
        notification =
            "local.research.mcm.springboardprefs.missing";
    } else {
        verdict = @"错误";
        notification =
            "local.research.mcm.springboardprefs.error";
    }
    int notifyResult = notify_post(notification);

    return [NSString stringWithFormat:
        @"SpringBoard 偏好设置精确写入权限检查\n"
         "目标：%s\n"
         "方法：在所有当前 MCM 路径激活后，使用 O_RDWR | O_CLOEXEC | O_NOFOLLOW 打开。\n"
         "结果：%@；打开错误码=%d（%s）。\n"
         "只读打开：%@；错误码=%d（%s）。\n"
         "目标元数据：lstat=%@；错误码=%d（%s）；模式=%04o；uid=%u；gid=%u。\n"
         "未写入任何字节。探测没有重命名、替换、截断或取消链接目标。\n"
         "主机通知：%s；notify_post=%d。\n\n",
        target, verdict, writeErrno, strerror(writeErrno),
         readDescriptor >= 0 ? @"允许" : @"拒绝",
        readErrno, strerror(readErrno),
         statResult == 0 ? @"存在" : @"不可用",
        statErrno, strerror(statErrno),
        statResult == 0 ? targetStatus.st_mode & 07777 : 0,
        statResult == 0 ? targetStatus.st_uid : 0,
        statResult == 0 ? targetStatus.st_gid : 0,
        notification, notifyResult];
}

static void MCMWriteAccessMap(NSFileManager *manager, NSString *root)
{
    NSArray<NSDictionary<NSString *, NSString *> *> *categories = @[
        @{@"Name": kMCMAppDataDirectoryName,
          @"Primitive": @"MHA-MCM class 2 应用数据查找和沙盒扩展"},
        @{@"Name": kMCMAppGroupsDirectoryName,
          @"Primitive": @"MHA-MCM class 7 应用组查找和沙盒扩展"},
        @{@"Name": kMCMExtensionDataDirectoryName,
          @"Primitive": @"MHA-MCM class 4 扩展数据查找和沙盒扩展"},
        @{@"Name": kMCMVPNDataDirectoryName,
          @"Primitive": @"MHA-MCM class 6 VPN 数据查找和沙盒扩展"},
        @{@"Name": kMCMServiceDataDirectoryName,
          @"Primitive": @"MHA-MCM class 10 服务数据查找和沙盒扩展"},
        @{@"Name": kMCMSystemDataDirectoryName,
          @"Primitive": @"MHA-MCM class 12 系统数据查找和沙盒扩展"},
        @{@"Name": kMCMSystemGroupsDirectoryName,
          @"Primitive": @"MHA-MCM class 13 系统组查找和沙盒扩展"},
        @{@"Name": kMCMProtectedDataDirectoryName,
          @"Primitive": @"MHA-MCM class 15 受保护数据查找和沙盒扩展"},
        @{@"Name": kMCMAdditionalLocationsDirectoryName,
          @"Primitive": @"MHA-MCM class 13 作用域 part-domain 查找和沙盒扩展"},
        @{@"Name": kMCMExperimentalDirectoryName,
          @"Primitive": @"MHA-MCM 作用域 class 10、12、13 和 15 探测"},
    ];

    NSMutableString *map = [NSMutableString stringWithFormat:
        @"MobileContainerManager 和 MobileGestalt 完整映射\n\n"
         "MHA-MCM 表示 MobileContainerManager 中的 MobileHouseArrest 身份信任绕过。\n"
         "下面会标记与构建相关的证据。当前设备为 %@。\n"
         "此映射记录根目录和预选探测子路径，不会枚举目标容器内的文件。\n\n",
         NSProcessInfo.processInfo.operatingSystemVersionString];
    MCMAppendUnifiedFindingMap(map);
    [map appendString:MCMSpringBoardPreferencesWriteCheck()];

    for (NSDictionary<NSString *, NSString *> *category in categories) {
        NSString *name = category[@"Name"];
        NSString *primitive = category[@"Primitive"];
        NSString *directory = [root stringByAppendingPathComponent:name];
        BOOL isDirectory = NO;
        BOOL present = [manager fileExistsAtPath:directory
                                     isDirectory:&isDirectory] && isDirectory;
        NSArray<NSDictionary<NSString *, NSString *> *> *entries = present
            ? MCMSymlinkAccessEntries(manager, directory) : @[];

        NSMutableString *section = [NSMutableString stringWithFormat:
            @"%@\n原理：%@\n", MCMDisplayStorageName(name), primitive];
        if (!present)
            [section appendString:@"状态：文件夹不存在；未启用根目录。\n"];
        else
            MCMAppendSymlinkAccess(section, entries);
        if ([name isEqualToString:kMCMExperimentalDirectoryName])
            MCMAppendExperimentalSubpaths(section, directory);
        [section appendString:@"\n"];
        [map appendString:section];
        if (present) MCMWriteAccessReadme(manager, directory, section);
    }

    NSString *wallpaperDirectory = [root
        stringByAppendingPathComponent:kMCMWallpaperLabDirectoryName];
    NSString *wallpaperSection = [NSString stringWithFormat:
        @"%@\n"
         "原理：通过 MHA-MCM class 2 查找 com.apple.PosterBoard 应用数据。\n"
         "状态：此文件夹用于本地暂存。只有执行壁纸实验室操作时才会访问 PosterBoard。\n"
         "潜在目标根目录：该操作返回的 class-2 com.apple.PosterBoard 数据容器。\n\n",
         MCMDisplayStorageName(kMCMWallpaperLabDirectoryName)];
    [map appendString:wallpaperSection];
    MCMWriteAccessReadme(manager, wallpaperDirectory, wallpaperSection);

    [map appendString:
        @"Files Traversal\n"
         "原理：Apple Files 相对符号链接入口实验。\n"
         "状态：已禁用。此构建会移除该文件夹，不启用任何 Files Traversal 路径。\n\n"
         "边界：不声称拥有任意 /var、Keychain、TCC、root、内核或应用包访问权限。\n"];

    NSString *mapPath = [root stringByAppendingPathComponent:@"ACCESS MAP.txt"];
    MCMWriteGeneratedString(map, mapPath);
}

static void MCMPruneEmptyGeneratedDirectory(NSString *directory)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:directory
                                                           error:nil];
    for (NSString *entry in entries ?: @[]) {
        NSString *path = [directory stringByAppendingPathComponent:entry];
        struct stat status = {0};
        if (lstat(path.fileSystemRepresentation, &status) != 0 ||
            !S_ISLNK(status.st_mode))
            continue;

        NSArray *targetEntries = [fm contentsOfDirectoryAtPath:path error:nil];
        if (targetEntries.count == 0) {
            unlink(path.fileSystemRepresentation);
            NSLog(@"[MCMFilza] removed empty generated link path=%@", path);
        }
    }

    entries = [fm contentsOfDirectoryAtPath:directory error:nil];
    if (entries.count == 0 && rmdir(directory.fileSystemRepresentation) == 0)
        NSLog(@"[MCMFilza] removed empty category path=%@", directory);
}

static void MCMPrepareStartupRoot(void)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = MCMFilzaVirtualRoot();
    if (!root.length) return;

    if (MCMFilzaIsRunningInLiveContainer()) {
        [fm createDirectoryAtPath:root withIntermediateDirectories:YES
                      attributes:@{NSFilePosixPermissions: @0700} error:nil];
        return;
    }

    NSString *legacyRoot = [root.stringByDeletingLastPathComponent
        stringByAppendingPathComponent:@"MCM Containers"];
    if ([fm fileExistsAtPath:legacyRoot] && ![fm fileExistsAtPath:root])
        [fm moveItemAtPath:legacyRoot toPath:root error:nil];
    [fm createDirectoryAtPath:root withIntermediateDirectories:YES
                   attributes:@{NSFilePosixPermissions: @0700} error:nil];
    MCMMigrateLegacyTopLevelNames(fm, root);

    for (NSString *name in @[
        kMCMAppDataDirectoryName,
        kMCMAppGroupsDirectoryName,
        kMCMExtensionDataDirectoryName,
        kMCMVPNDataDirectoryName,
        kMCMServiceDataDirectoryName,
        kMCMSystemDataDirectoryName,
        kMCMSystemGroupsDirectoryName,
        kMCMProtectedDataDirectoryName,
        kMCMAdditionalLocationsDirectoryName,
        kMCMExperimentalDirectoryName,
        kMCMWallpaperLabDirectoryName,
    ]) {
        [fm createDirectoryAtPath:[root stringByAppendingPathComponent:name]
      withIntermediateDirectories:YES
                       attributes:@{NSFilePosixPermissions: @0700} error:nil];
    }
}

void MCMFilzaStart(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        MCMEnsureState();
        MCMPrepareStartupRoot();
        MCMPostStartupProgress(0.03, @"正在初始化设备存储…");

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool {
                if (MCMFilzaIsRunningInLiveContainer()) {
                    MCMPostStartupProgress(0.35, @"正在准备 LiveContainer 存储…");
                    MCMInstallLiveContainerRoot();
                    MCMFinishStartup(@"设备存储已就绪");
                    return;
                }

                MCMPostStartupProgress(0.06, @"正在检查容器访问…");
                NSString *actual = MCMSignedCodeIdentifier();
                if (![actual isEqualToString:kRequiredIdentifier]) {
                    NSLog(@"[MCMFilza] disabled: signed code identifier %@ must be %@ (bundle=%@)",
                          actual, kRequiredIdentifier, NSBundle.mainBundle.bundleIdentifier);
                    MCMFinishStartup(@"设备存储不可用");
                    return;
                }
                if (!MCMBridgeAvailable()) {
                    NSLog(@"[MCMFilza] disabled: ContainerManager symbols unavailable");
                    MCMFinishStartup(@"ContainerManager 不可用");
                    return;
                }

                NSFileManager *fm = NSFileManager.defaultManager;
                NSString *root = MCMFilzaVirtualRoot();
                NSString *legacyRoot = [root.stringByDeletingLastPathComponent
                    stringByAppendingPathComponent:@"MCM Containers"];
                if ([fm fileExistsAtPath:legacyRoot] && ![fm fileExistsAtPath:root])
                    [fm moveItemAtPath:legacyRoot toPath:root error:nil];
                else if ([fm fileExistsAtPath:legacyRoot])
                    [fm removeItemAtPath:legacyRoot error:nil];
                MCMMigrateLegacyTopLevelNames(fm, root);
                NSString *apps = [root stringByAppendingPathComponent:kMCMAppDataDirectoryName];
                NSString *groups = [root stringByAppendingPathComponent:kMCMAppGroupsDirectoryName];
                NSString *extensions = [root
                    stringByAppendingPathComponent:kMCMExtensionDataDirectoryName];
                NSString *vpnData = [root stringByAppendingPathComponent:kMCMVPNDataDirectoryName];
                NSString *serviceData = [root
                    stringByAppendingPathComponent:kMCMServiceDataDirectoryName];
                NSString *systemData = [root
                    stringByAppendingPathComponent:kMCMSystemDataDirectoryName];
                NSString *systemGroups = [root
                    stringByAppendingPathComponent:kMCMSystemGroupsDirectoryName];
                NSString *protectedData = [root
                    stringByAppendingPathComponent:kMCMProtectedDataDirectoryName];
                NSString *additionalLocations = [root
                    stringByAppendingPathComponent:kMCMAdditionalLocationsDirectoryName];
                NSString *experimental = [root
                    stringByAppendingPathComponent:kMCMExperimentalDirectoryName];
                NSString *filesTraversal = [root stringByAppendingPathComponent:@"Files Traversal"];
                [fm removeItemAtPath:filesTraversal error:nil];
                for (NSString *directory in @[root, apps, groups, extensions, vpnData,
                                              serviceData, systemData, systemGroups,
                                              protectedData, additionalLocations,
                                              experimental])
                    [fm createDirectoryAtPath:directory withIntermediateDirectories:YES
                                   attributes:@{NSFilePosixPermissions: @0700} error:nil];
                MCMInstallArchiveAlias(fm, root);
                MCMResetAppLinksForTesting(apps);

                MCMPostStartupProgress(0.10, @"正在读取已安装应用…");
                NSMutableOrderedSet *appIdentifiers = [NSMutableOrderedSet orderedSetWithArray:
                    MCMDynamicIdentifiers(2)];
                [appIdentifiers addObjectsFromArray:MCMInstalledApplicationIdentifiers()];

                MCMPostStartupProgress(0.16, @"正在扫描 LaunchServices…");
                NSArray<NSString *> *launchServicesIdentifiers =
                    MCMLaunchServicesStoreIdentifiers();
                MCMPostStartupProgress(0.40, @"正在建立应用数据访问…");

                // Keep the proven targets as a compatibility fallback when metadata
                // enumeration is denied or incomplete on a particular build.
                [appIdentifiers addObjectsFromArray:MCMResearchTargetIdentifiers()];
                NSDictionary *custom = MCMCustomIdentifiers();
                for (id value in [custom[@"AppData"] isKindOfClass:NSArray.class] ? custom[@"AppData"] : @[])
                    if ([value isKindOfClass:NSString.class] && MCMSafeIdentifier(value)) [appIdentifiers addObject:value];

                NSUInteger appTotal = MAX((NSUInteger)1,
                    appIdentifiers.count + launchServicesIdentifiers.count);
                NSUInteger appDone = 0;
                for (NSString *identifier in appIdentifiers) {
                    MCMInstallLink(apps, identifier, 2, NO);
                    appDone++;
                    if ((appDone & 7U) == 0 || appDone == appTotal)
                        MCMPostStartupProgress(0.40 + 0.20 * ((double)appDone / appTotal),
                                               @"正在建立应用数据访问…");
                }
                for (NSString *identifier in launchServicesIdentifiers) {
                    if (![appIdentifiers containsObject:identifier])
                        MCMInstallLinkWithFailureLogging(apps, identifier, 2, NO, NO);
                    appDone++;
                    if ((appDone & 7U) == 0 || appDone == appTotal)
                        MCMPostStartupProgress(0.40 + 0.20 * ((double)appDone / appTotal),
                                               @"正在建立应用数据访问…");
                }
                MCMLogExpectedIdentifierCoverage(@"App Data links",
                    [NSSet setWithArray:[fm contentsOfDirectoryAtPath:apps error:nil] ?: @[]]);

                MCMPostStartupProgress(0.61, @"正在建立应用组访问…");
                NSMutableOrderedSet *groupIdentifiers = [NSMutableOrderedSet orderedSetWithArray:
                    MCMDynamicIdentifiers(7)];
                [groupIdentifiers addObjectsFromArray:@[
                    @"group.com.apple.notes",
                    @"group.com.apple.safari",
                    @"group.com.apple.weather",
                    @"group.com.apple.stocks",
                ]];
                for (id value in [custom[@"AppGroups"] isKindOfClass:NSArray.class] ? custom[@"AppGroups"] : @[])
                    if ([value isKindOfClass:NSString.class] && MCMSafeIdentifier(value))
                        [groupIdentifiers addObject:value];
                NSUInteger groupTotal = MAX((NSUInteger)1, groupIdentifiers.count);
                NSUInteger groupDone = 0;
                for (NSString *identifier in groupIdentifiers) {
                    MCMInstallLink(groups, identifier, 7, YES);
                    groupDone++;
                    if ((groupDone & 7U) == 0 || groupDone == groupTotal)
                        MCMPostStartupProgress(0.61 + 0.08 * ((double)groupDone / groupTotal),
                                               @"正在建立应用组访问…");
                }

                MCMPostStartupProgress(0.70, @"正在建立扩展数据访问…");
                NSMutableOrderedSet *extensionIdentifiers = [NSMutableOrderedSet orderedSetWithArray:
                    MCMDynamicIdentifiers(4)];
                for (id value in [custom[@"ExtensionData"] isKindOfClass:NSArray.class] ? custom[@"ExtensionData"] : @[])
                    if ([value isKindOfClass:NSString.class] && MCMSafeIdentifier(value))
                        [extensionIdentifiers addObject:value];
                NSUInteger extensionTotal = MAX((NSUInteger)1, extensionIdentifiers.count);
                NSUInteger extensionDone = 0;
                for (NSString *identifier in extensionIdentifiers) {
                    MCMInstallLink(extensions, identifier, 4, NO);
                    extensionDone++;
                    if ((extensionDone & 7U) == 0 || extensionDone == extensionTotal)
                        MCMPostStartupProgress(0.70 + 0.06 * ((double)extensionDone / extensionTotal),
                                               @"正在建立扩展数据访问…");
                }

                MCMInstallDirectFilesystemLinks(apps,
                    @"/private/var/mobile/Containers/Data/Application");
                MCMInstallDirectFilesystemLinks(groups,
                    @"/private/var/mobile/Containers/Shared/AppGroup");
                MCMInstallDirectFilesystemLinks(extensions,
                    @"/private/var/mobile/Containers/Data/PluginKitPlugin");

                NSArray<NSDictionary *> *additionalCategories = @[
                    @{@"Directory": vpnData, @"Class": @6, @"Group": @(NO),
                      @"CustomKey": @"VPNData", @"Fallback": @[],
                      @"Status": @"正在建立 VPN 数据访问…"},
                    @{@"Directory": serviceData, @"Class": @10, @"Group": @(NO),
                      @"CustomKey": @"ServiceData", @"Fallback": @[
                          @"com.apple.swcd", @"com.apple.familycircled",
                          @"com.apple.locationd", @"com.apple.installd",
                          @"com.apple.accountsd", @"com.apple.itunescloudd",
                          @"com.apple.nanonewscd"],
                      @"Status": @"正在建立服务数据访问…"},
                    @{@"Directory": systemData, @"Class": @12, @"Group": @(NO),
                      @"CustomKey": @"SystemData", @"Fallback": @[
                          @"com.apple.eligibilityd", @"com.apple.geod",
                          @"com.apple.springboard"],
                      @"Status": @"正在建立系统数据访问…"},
                    @{@"Directory": systemGroups, @"Class": @13, @"Group": @(YES),
                      @"CustomKey": @"SystemGroups", @"Fallback": @[
                          @"systemgroup.com.apple.configurationprofiles",
                          @"systemgroup.com.apple.pisco.suinfo",
                          @"systemgroup.com.apple.lsd.iconscache",
                          @"systemgroup.com.apple.icloud.findmydevice.managed",
                          @"systemgroup.com.apple.ondemandresources",
                          @"systemgroup.com.apple.mobilegestaltcache",
                          @"systemgroup.com.apple.nsurlstoragedresources",
                          @"systemgroup.com.apple.installcoordinationd",
                          @"systemgroup.com.apple.osanalytics",
                          @"systemgroup.com.apple.ContainerManagerTest.fixed"],
                      @"Status": @"正在建立系统组访问…"},
                    @{@"Directory": protectedData, @"Class": @15, @"Group": @(NO),
                      @"CustomKey": @"ProtectedData", @"Fallback": @[
                          @"com.apple.appmanagedfeaturesd"],
                      @"Status": @"正在建立受保护数据访问…"},
                ];
                NSUInteger categoryIndex = 0;
                for (NSDictionary *category in additionalCategories) {
                    NSString *categoryStatus = category[@"Status"];
                    double categoryStart = 0.77 + 0.025 * categoryIndex;
                    MCMPostStartupProgress(categoryStart, categoryStatus);
                    uint64_t containerClass = [category[@"Class"] unsignedLongLongValue];
                    NSMutableOrderedSet<NSString *> *identifiers =
                        [NSMutableOrderedSet orderedSetWithArray:
                            MCMDynamicIdentifiers(containerClass)];
                    [identifiers addObjectsFromArray:category[@"Fallback"]];
                    NSString *customKey = category[@"CustomKey"];
                    for (id value in [custom[customKey] isKindOfClass:NSArray.class]
                            ? custom[customKey] : @[])
                        if ([value isKindOfClass:NSString.class] && MCMSafeIdentifier(value))
                            [identifiers addObject:value];
                    for (NSString *identifier in identifiers)
                        MCMInstallLink(category[@"Directory"], identifier, containerClass,
                                       [category[@"Group"] boolValue]);
                    categoryIndex++;
                }

                MCMInstallDirectFilesystemLinks(vpnData,
                    @"/private/var/mobile/Containers/Data/VPNPlugin");
                MCMInstallDirectFilesystemLinks(serviceData,
                    @"/private/var/mobile/Containers/Data/InternalDaemon");
                MCMInstallDirectFilesystemLinks(systemData,
                    @"/private/var/mobile/Containers/Data/System");
                MCMInstallDirectFilesystemLinks(systemGroups,
                    @"/private/var/mobile/Containers/Shared/SystemGroup");
                MCMInstallDirectFilesystemLinks(protectedData,
                    @"/private/var/mobile/Containers/Data/Protected");

                MCMPostStartupProgress(0.90, @"正在准备其他位置…");
                // These part-domain lookups remain inside their server-selected system
                // group. They expose proven sibling directories but do not grant an
                // arbitrary path outside the managed group root.
                NSArray<NSArray<NSString *> *> *additionalLocationMigrations = @[
                    @[@"Install Coordination", @"[MHA-C13] Install Coordination"],
                    @[@"Configuration Profiles", @"[MHA-C13] Configuration Profiles"],
                    @[@"MobileGestalt Cache", @"[MHA-C13] MobileGestalt Cache"],
                ];
                for (NSArray<NSString *> *migration in additionalLocationMigrations)
                    MCMMigrateStorageEntry(fm, additionalLocations,
                                           migration[0], migration[1]);

                MCMInstallScopedLink(additionalLocations,
                    @"[MHA-C13] Install Coordination", 13,
                    @"systemgroup.com.apple.installcoordinationd", YES, 3,
                    @"../InstallCoordination");
                // Use the group root here. A part-3 ConfigurationProfiles lookup can
                // run the ContainerManager directory finalizer on the resolved path.
                MCMInstallScopedLink(additionalLocations,
                    @"[MHA-C13] Configuration Profiles", 13,
                    @"systemgroup.com.apple.configurationprofiles", YES, 0, nil);
                MCMInstallScopedLink(additionalLocations,
                    @"[MHA-C13] MobileGestalt Cache", 13,
                    @"systemgroup.com.apple.mobilegestaltcache", YES, 3, nil);

                MCMPostStartupProgress(0.94, @"正在检查实验性位置…");
                MCMInstallExperimentalFolder(experimental);

                MCMPostStartupProgress(0.97, @"正在整理设备存储…");
                if (!gUnrestrictedFilesystem) {
                    for (NSString *directory in @[apps, groups, extensions, vpnData,
                                                  serviceData, systemData, systemGroups,
                                                  protectedData, additionalLocations])
                        MCMPruneEmptyGeneratedDirectory(directory);
                }

                MCMPostStartupProgress(0.985, @"正在生成访问映射…");
                MCMWriteAccessMap(fm, root);
                MCMWriteInstructions();
                MCMRunGeneratedDeletionProbe(fm, root);
                NSError *listError = nil;
                NSArray *visibleEntries = [fm contentsOfDirectoryAtPath:root error:&listError];
                NSLog(@"[MCMFilza] ready root=%@ active_leases=%lu entries=%@ list_error=%@", root,
                      (unsigned long)gLeases.count, visibleEntries, listError);
                MCMFinishStartup(@"设备存储已就绪");
            }
        });
    });
}
