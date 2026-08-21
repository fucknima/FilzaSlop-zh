#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "ArchiveUnzipFix.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <wchar.h>

#include "Vendor/unrar/include/unrar.h"

#if __has_include(<ptrauth.h>)
#include <ptrauth.h>
#endif

#pragma mark - Resolve Filza's local minizip symbols

// The original Filza binary contains minizip, but the functions are local Mach-O
// symbols rather than dyld exports. dlsym(RTLD_DEFAULT, ...) therefore cannot
// resolve them. Read the main executable's LC_SYMTAB and apply the runtime ASLR
// slide so the existing in-process implementation can be used without spawning
// Filza's root helper or bundled command-line unzip tool.

static NSDictionary<NSString *, NSNumber *> *FSMainExecutableLocalSymbols(void)
{
    static NSDictionary<NSString *, NSNumber *> *symbols;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = NSBundle.mainBundle.executablePath;
        NSError *error = nil;
        NSData *data = [NSData dataWithContentsOfFile:path
            options:NSDataReadingMappedIfSafe error:&error];
        if (!data || data.length < sizeof(struct mach_header_64)) {
            NSLog(@"[ArchiveUnzipFix] cannot map main executable: %@", error);
            symbols = @{};
            return;
        }

        const uint8_t *bytes = data.bytes;
        const struct mach_header_64 *header = (const struct mach_header_64 *)bytes;
        if (header->magic != MH_MAGIC_64) {
            NSLog(@"[ArchiveUnzipFix] unsupported main Mach-O magic=0x%x", header->magic);
            symbols = @{};
            return;
        }

        const struct symtab_command *symtab = NULL;
        const uint8_t *cursor = bytes + sizeof(*header);
        const uint8_t *end = bytes + data.length;
        for (uint32_t index = 0; index < header->ncmds; index++) {
            if (cursor + sizeof(struct load_command) > end) break;
            const struct load_command *command = (const struct load_command *)cursor;
            if (command->cmdsize < sizeof(*command) || cursor + command->cmdsize > end)
                break;
            if (command->cmd == LC_SYMTAB &&
                command->cmdsize >= sizeof(struct symtab_command))
                symtab = (const struct symtab_command *)command;
            cursor += command->cmdsize;
        }

        if (!symtab || symtab->symoff > data.length || symtab->stroff > data.length) {
            NSLog(@"[ArchiveUnzipFix] main executable has no usable LC_SYMTAB");
            symbols = @{};
            return;
        }

        uint64_t symbolsBytes = (uint64_t)symtab->nsyms * sizeof(struct nlist_64);
        if ((uint64_t)symtab->symoff + symbolsBytes > data.length ||
            (uint64_t)symtab->stroff + symtab->strsize > data.length) {
            NSLog(@"[ArchiveUnzipFix] malformed main symbol table bounds");
            symbols = @{};
            return;
        }

        NSSet<NSString *> *wanted = [NSSet setWithArray:@[
            @"_unzOpen64",
            @"_unzGoToFirstFile",
            @"_unzGoToNextFile",
            @"_unzGetCurrentFileInfo64",
            @"_unzOpenCurrentFilePassword",
            @"_unzReadCurrentFile",
            @"_unzCloseCurrentFile",
            @"_unzClose",
        ]];
        NSMutableDictionary<NSString *, NSNumber *> *found = [NSMutableDictionary dictionary];
        const struct nlist_64 *entries =
            (const struct nlist_64 *)(bytes + symtab->symoff);
        const char *strings = (const char *)(bytes + symtab->stroff);

        for (uint32_t index = 0; index < symtab->nsyms && found.count < wanted.count; index++) {
            const struct nlist_64 *entry = &entries[index];
            if ((entry->n_type & N_STAB) != 0 ||
                (entry->n_type & N_TYPE) != N_SECT || entry->n_value == 0)
                continue;
            uint32_t stringIndex = entry->n_un.n_strx;
            if (stringIndex == 0 || stringIndex >= symtab->strsize) continue;
            const char *name = strings + stringIndex;
            size_t remaining = symtab->strsize - stringIndex;
            size_t length = strnlen(name, remaining);
            if (length == 0 || length == remaining) continue;
            NSString *symbol = [[NSString alloc] initWithBytes:name
                length:length encoding:NSUTF8StringEncoding];
            if ([wanted containsObject:symbol])
                found[symbol] = @(entry->n_value);
        }
        symbols = [found copy];
        NSLog(@"[ArchiveUnzipFix] resolved %lu/%lu local minizip symbols",
              (unsigned long)symbols.count, (unsigned long)wanted.count);
    });
    return symbols;
}

static void *FSSignFunctionPointerIfNeeded(void *pointer)
{
#if __has_include(<ptrauth.h>) && __has_feature(ptrauth_calls)
    if (pointer)
        return ptrauth_sign_unauthenticated(pointer,
            ptrauth_key_function_pointer, 0);
#endif
    return pointer;
}

static void *FSResolveMainExecutableLocalSymbol(const char *bareName)
{
    if (!bareName || !bareName[0]) return NULL;
    NSString *symbolName = [@"_" stringByAppendingString:
        [NSString stringWithUTF8String:bareName]];
    NSNumber *value = FSMainExecutableLocalSymbols()[symbolName];
    if (!value) return NULL;
    uintptr_t address = (uintptr_t)value.unsignedLongLongValue +
        (uintptr_t)_dyld_get_image_vmaddr_slide(0);
    return FSSignFunctionPointerIfNeeded((void *)address);
}

#pragma mark - Minimal minizip ABI used by Filza

typedef void *FSUnzFile;
typedef unsigned long FSZULong;
typedef uint64_t FSZPos64;

typedef struct {
    unsigned int tm_sec;
    unsigned int tm_min;
    unsigned int tm_hour;
    unsigned int tm_mday;
    unsigned int tm_mon;
    unsigned int tm_year;
} FSTmUnz;

typedef struct {
    FSZULong version;
    FSZULong version_needed;
    FSZULong flag;
    FSZULong compression_method;
    FSZULong dosDate;
    FSZULong crc;
    FSZPos64 compressed_size;
    FSZPos64 uncompressed_size;
    FSZULong size_filename;
    FSZULong size_file_extra;
    FSZULong size_file_comment;
    FSZULong disk_num_start;
    FSZULong internal_fa;
    FSZULong external_fa;
    FSTmUnz tmu_date;
} FSUnzFileInfo64;

static FSUnzFile (*pFSUnzOpen64)(const char *);
static int (*pFSUnzGoToFirstFile)(FSUnzFile);
static int (*pFSUnzGoToNextFile)(FSUnzFile);
static int (*pFSUnzGetCurrentFileInfo64)(FSUnzFile, FSUnzFileInfo64 *,
    char *, unsigned long, void *, unsigned long, char *, unsigned long);
static int (*pFSUnzOpenCurrentFilePassword)(FSUnzFile, const char *);
static int (*pFSUnzReadCurrentFile)(FSUnzFile, void *, unsigned);
static int (*pFSUnzCloseCurrentFile)(FSUnzFile);
static int (*pFSUnzClose)(FSUnzFile);

BOOL FSLoadInProcessUnzip(void)
{
    static BOOL available = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pFSUnzOpen64 = FSResolveMainExecutableLocalSymbol("unzOpen64");
        pFSUnzGoToFirstFile = FSResolveMainExecutableLocalSymbol("unzGoToFirstFile");
        pFSUnzGoToNextFile = FSResolveMainExecutableLocalSymbol("unzGoToNextFile");
        pFSUnzGetCurrentFileInfo64 =
            FSResolveMainExecutableLocalSymbol("unzGetCurrentFileInfo64");
        pFSUnzOpenCurrentFilePassword =
            FSResolveMainExecutableLocalSymbol("unzOpenCurrentFilePassword");
        pFSUnzReadCurrentFile = FSResolveMainExecutableLocalSymbol("unzReadCurrentFile");
        pFSUnzCloseCurrentFile =
            FSResolveMainExecutableLocalSymbol("unzCloseCurrentFile");
        pFSUnzClose = FSResolveMainExecutableLocalSymbol("unzClose");
        available = pFSUnzOpen64 && pFSUnzGoToFirstFile && pFSUnzGoToNextFile &&
            pFSUnzGetCurrentFileInfo64 && pFSUnzOpenCurrentFilePassword &&
            pFSUnzReadCurrentFile && pFSUnzCloseCurrentFile && pFSUnzClose;
        NSLog(@"[ArchiveUnzipFix] in-process unzip available=%d", available);
    });
    return available;
}

#pragma mark - Safe streaming extraction

static NSString *FSArchivePathFromArgument(id value)
{
    if ([value isKindOfClass:NSString.class]) return value;
    SEL selector = NSSelectorFromString(@"filePath");
    id path = [value respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(value, selector) : nil;
    return [path isKindOfClass:NSString.class] ? path : nil;
}

static NSString *FSDecodeZipFilename(const void *bytes, NSUInteger length)
{
    if (!bytes || length == 0) return nil;
    NSString *name = [[NSString alloc] initWithBytes:bytes length:length
        encoding:NSUTF8StringEncoding];
    if (!name)
        name = [[NSString alloc] initWithBytes:bytes length:length
            encoding:NSISOLatin1StringEncoding];
    return name;
}

static NSString *FSSafeRelativeZipPath(NSString *rawName)
{
    if (rawName.length == 0) return nil;
    for (NSUInteger index = 0; index < rawName.length; index++) {
        if ([rawName characterAtIndex:index] == 0) return nil;
    }
    NSString *name = [rawName stringByReplacingOccurrencesOfString:@"\\"
                                                         withString:@"/"];
    if ([name hasPrefix:@"/"]) return nil;
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *part in [name componentsSeparatedByString:@"/"]) {
        if (part.length == 0 || [part isEqualToString:@"."]) continue;
        if ([part isEqualToString:@".."]) return nil;
        [parts addObject:part];
    }
    return parts.count ? [parts componentsJoinedByString:@"/"] : nil;
}

static void FSSetArchiveMessage(NSString **outMessage, NSString *format, ...)
{
    if (!outMessage) return;
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    *outMessage = message;
}

static id FSFileItemAtPath(NSString *path)
{
    if (!path.length) return nil;
    Class fileItemClass = NSClassFromString(@"FileItem");
    if (!fileItemClass) return nil;
    id item = [[fileItemClass alloc] init];
    SEL selector = NSSelectorFromString(@"setFilePath:attribute:");
    if (![item respondsToSelector:selector]) return nil;
    ((void (*)(id, SEL, id, id))objc_msgSend)(item, selector, path, nil);
    return item;
}

static NSArray *FSArchiveResultForDestination(NSString *destination,
                                              NSString *currentDirectory,
                                              NSArray<NSString *> *topLevelNames)
{
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *dest = destination.stringByStandardizingPath;
    NSString *current = currentDirectory.stringByStandardizingPath;
    if ([dest isEqualToString:current]) {
        NSMutableArray *items = [NSMutableArray array];
        for (NSString *name in topLevelNames) {
            NSString *path = [dest stringByAppendingPathComponent:name];
            if (![manager fileExistsAtPath:path]) continue;
            id item = FSFileItemAtPath(path);
            if (item) [items addObject:item];
        }
        return items.count ? [items copy] : nil;
    }
    id item = [manager fileExistsAtPath:dest] ? FSFileItemAtPath(dest) : nil;
    return item ? @[item] : nil;
}

static NSArray *FSValidatedArchiveResult(id result, NSString **outMessage)
{
    if (!result) return nil;
    if ([result isKindOfClass:NSArray.class]) return result;
    NSLog(@"[ArchiveUnzipFix] rejected invalid result class=%@",
          NSStringFromClass([result class]));
    FSSetArchiveMessage(outMessage, @"解压结果类型无效");
    return nil;
}

static BOOL FSWriteCurrentZipEntry(FSUnzFile archive, NSString *path,
                                   const char *password, mode_t mode,
                                   NSString **outMessage)
{
    int opened = pFSUnzOpenCurrentFilePassword(archive, password);
    if (opened != 0) {
        FSSetArchiveMessage(outMessage,
            password ? @"无法解密 ZIP 条目（密码可能不正确，代码 %d）"
                     : @"无法打开 ZIP 条目（可能需要密码，代码 %d）",
            opened);
        return NO;
    }

    NSString *temporaryPath = [path.stringByDeletingLastPathComponent
        stringByAppendingPathComponent:[NSString stringWithFormat:
            @".filza-unzip-%@.tmp", NSUUID.UUID.UUIDString]];
    int descriptor = open(temporaryPath.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (descriptor < 0) {
        int saved = errno;
        pFSUnzCloseCurrentFile(archive);
        FSSetArchiveMessage(outMessage, @"无法创建解压临时文件：%@（%s）",
                            path, strerror(saved));
        return NO;
    }

    BOOL success = YES;
    uint8_t buffer[64 * 1024];
    for (;;) {
        int count = pFSUnzReadCurrentFile(archive, buffer, sizeof(buffer));
        if (count == 0) break;
        if (count < 0) {
            FSSetArchiveMessage(outMessage, @"读取 ZIP 数据失败（代码 %d）", count);
            success = NO;
            break;
        }
        ssize_t offset = 0;
        while (offset < count) {
            ssize_t written = write(descriptor, buffer + offset,
                                    (size_t)(count - offset));
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) {
                int saved = errno ?: EIO;
                FSSetArchiveMessage(outMessage, @"写入解压文件失败：%@（%s）",
                                    path, strerror(saved));
                success = NO;
                break;
            }
            offset += written;
        }
        if (!success) break;
    }
    mode_t permissions = (mode & 0777) ?: 0644;
    if (success && fchmod(descriptor, permissions) != 0) {
        int saved = errno;
        FSSetArchiveMessage(outMessage, @"无法设置解压文件权限：%@（%s）",
                            path, strerror(saved));
        success = NO;
    }
    if (close(descriptor) != 0 && success) {
        int saved = errno;
        FSSetArchiveMessage(outMessage, @"关闭解压临时文件失败：%@（%s）",
                            path, strerror(saved));
        success = NO;
    }

    int closeResult = pFSUnzCloseCurrentFile(archive);
    if (success && closeResult != 0) {
        FSSetArchiveMessage(outMessage,
            @"ZIP 条目校验失败（CRC/密码错误，代码 %d）", closeResult);
        success = NO;
    }
    if (!success) {
        unlink(temporaryPath.fileSystemRepresentation);
        return NO;
    }
    if (rename(temporaryPath.fileSystemRepresentation,
               path.fileSystemRepresentation) != 0) {
        int saved = errno;
        unlink(temporaryPath.fileSystemRepresentation);
        FSSetArchiveMessage(outMessage, @"提交解压文件失败：%@（%s）",
                            path, strerror(saved));
        return NO;
    }
    return YES;
}

static void FSCleanupCreatedDirectories(NSArray<NSString *> *directories)
{
    for (NSString *path in directories.reverseObjectEnumerator) {
        if (rmdir(path.fileSystemRepresentation) != 0 &&
            errno != ENOENT && errno != ENOTEMPTY) {
            NSLog(@"[ArchiveUnzipFix] cannot remove rollback directory %@: %s",
                  path, strerror(errno));
        }
    }
}

static BOOL FSCreateDirectoryChain(NSString *directory,
                                   NSMutableArray<NSString *> *createdDirectories,
                                   NSString **outMessage)
{
    NSMutableArray<NSString *> *missing = [NSMutableArray array];
    NSString *cursor = directory.stringByStandardizingPath;
    while (cursor.length) {
        struct stat status = {0};
        if (stat(cursor.fileSystemRepresentation, &status) == 0) {
            if (!S_ISDIR(status.st_mode)) {
                FSSetArchiveMessage(outMessage, @"解压目标不是目录：%@", cursor);
                return NO;
            }
            break;
        }
        int saved = errno;
        struct stat linkStatus = {0};
        if (lstat(cursor.fileSystemRepresentation, &linkStatus) == 0 &&
            S_ISLNK(linkStatus.st_mode)) {
            FSSetArchiveMessage(outMessage, @"解压目标包含失效的符号链接：%@", cursor);
            return NO;
        }
        if (saved != ENOENT) {
            FSSetArchiveMessage(outMessage, @"无法检查解压目录：%@（%s）",
                                cursor, strerror(saved));
            return NO;
        }
        [missing addObject:cursor];
        NSString *parent = cursor.stringByDeletingLastPathComponent;
        if (!parent.length || [parent isEqualToString:cursor]) {
            FSSetArchiveMessage(outMessage, @"解压目标路径无效：%@", directory);
            return NO;
        }
        cursor = parent;
    }

    for (NSString *path in missing.reverseObjectEnumerator) {
        if (mkdir(path.fileSystemRepresentation, 0755) != 0) {
            int saved = errno;
            struct stat status = {0};
            if (saved == EEXIST &&
                stat(path.fileSystemRepresentation, &status) == 0 &&
                S_ISDIR(status.st_mode)) {
                continue;
            }
            FSSetArchiveMessage(outMessage, @"无法创建解压目录：%@（%s）",
                                path, strerror(saved));
            return NO;
        }
        [createdDirectories addObject:path];
    }
    return YES;
}

static NSString *FSCanonicalDirectory(NSString *directory,
                                      NSString **outMessage)
{
    char resolved[PATH_MAX] = {0};
    if (!realpath(directory.fileSystemRepresentation, resolved)) {
        int saved = errno;
        FSSetArchiveMessage(outMessage, @"无法解析解压目标：%@（%s）",
                            directory, strerror(saved));
        return nil;
    }
    NSString *canonical = [NSFileManager.defaultManager
        stringWithFileSystemRepresentation:resolved length:strlen(resolved)];
    if (!canonical.length) {
        FSSetArchiveMessage(outMessage, @"解压目标的真实路径无效：%@", directory);
        return nil;
    }
    return canonical;
}

static NSString *FSCreateStagingDirectory(NSString *destination,
                                          NSString **outMessage)
{
    for (NSUInteger attempt = 0; attempt < 3; attempt++) {
        NSString *name = [NSString stringWithFormat:@".filza-unzip-stage-%@",
                          NSUUID.UUID.UUIDString];
        NSString *path = [destination stringByAppendingPathComponent:name];
        if (mkdir(path.fileSystemRepresentation, 0700) == 0) return path;
        if (errno != EEXIST) {
            int saved = errno;
            FSSetArchiveMessage(outMessage, @"无法创建解压暂存目录：%@（%s）",
                                path, strerror(saved));
            return nil;
        }
    }
    FSSetArchiveMessage(outMessage, @"无法分配唯一的解压暂存目录");
    return nil;
}

static BOOL FSEnsureSafeRelativeDirectory(
    NSString *destination, NSString *relativeDirectory, mode_t mode,
    NSMutableArray<NSString *> *createdDirectories, NSString **outMessage)
{
    if (!relativeDirectory.length || [relativeDirectory isEqualToString:@"."])
        return YES;

    NSArray<NSString *> *components =
        [relativeDirectory componentsSeparatedByString:@"/"];
    NSString *path = destination;
    for (NSUInteger index = 0; index < components.count; index++) {
        NSString *component = components[index];
        if (!component.length || [component isEqualToString:@"."]) continue;
        if ([component isEqualToString:@".."]) {
            FSSetArchiveMessage(outMessage, @"解压提交路径无效：%@",
                                relativeDirectory);
            return NO;
        }
        path = [path stringByAppendingPathComponent:component];

        struct stat status = {0};
        if (lstat(path.fileSystemRepresentation, &status) == 0) {
            if (S_ISLNK(status.st_mode)) {
                FSSetArchiveMessage(outMessage,
                    @"解压目标包含符号链接目录，已拒绝写入：%@", path);
                return NO;
            }
            if (!S_ISDIR(status.st_mode)) {
                FSSetArchiveMessage(outMessage,
                    @"解压目标中的路径不是目录：%@", path);
                return NO;
            }
            continue;
        }
        int saved = errno;
        if (saved != ENOENT) {
            FSSetArchiveMessage(outMessage, @"无法检查解压目标：%@（%s）",
                                path, strerror(saved));
            return NO;
        }

        BOOL finalComponent = index + 1 == components.count;
        mode_t permissions = finalComponent ? ((mode & 0777) ?: 0755) : 0755;
        if (mkdir(path.fileSystemRepresentation, permissions) != 0) {
            saved = errno;
            FSSetArchiveMessage(outMessage, @"无法创建解压目录：%@（%s）",
                                path, strerror(saved));
            return NO;
        }
        chmod(path.fileSystemRepresentation, permissions);
        [createdDirectories addObject:path];
    }
    return YES;
}

static BOOL FSRollbackCommittedFiles(NSArray<NSDictionary *> *changes)
{
    BOOL complete = YES;
    for (NSDictionary *change in changes.reverseObjectEnumerator) {
        NSString *path = change[@"path"];
        id backupValue = change[@"backup"];
        NSString *backup = backupValue == NSNull.null ? nil : backupValue;
        if (backup) {
            if (rename(backup.fileSystemRepresentation,
                       path.fileSystemRepresentation) != 0) {
                NSLog(@"[ArchiveUnzipFix] cannot restore backup %@ -> %@: %s",
                      backup, path, strerror(errno));
                complete = NO;
            }
        } else if (unlink(path.fileSystemRepresentation) != 0 &&
                   errno != ENOENT) {
            NSLog(@"[ArchiveUnzipFix] cannot remove rollback file %@: %s",
                  path, strerror(errno));
            complete = NO;
        }
    }
    return complete;
}

static BOOL FSCommitStagedExtraction(
    NSString *stagingDirectory, NSString *destination,
    NSDictionary<NSString *, NSNumber *> *directoryModes,
    NSMutableArray<NSString *> *createdDirectories, NSString **outMessage)
{
    NSFileManager *manager = NSFileManager.defaultManager;
    NSDirectoryEnumerator<NSString *> *enumerator =
        [manager enumeratorAtPath:stagingDirectory];
    if (!enumerator) {
        FSSetArchiveMessage(outMessage, @"无法读取解压暂存目录");
        return NO;
    }

    NSMutableArray<NSString *> *directories = [NSMutableArray array];
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    for (NSString *relative in enumerator) {
        NSString *path = [stagingDirectory stringByAppendingPathComponent:relative];
        struct stat status = {0};
        if (lstat(path.fileSystemRepresentation, &status) != 0) {
            int saved = errno;
            FSSetArchiveMessage(outMessage, @"无法检查解压暂存项目：%@（%s）",
                                relative, strerror(saved));
            return NO;
        }
        if (S_ISDIR(status.st_mode)) {
            [directories addObject:relative];
        } else if (S_ISREG(status.st_mode)) {
            [files addObject:relative];
        } else {
            FSSetArchiveMessage(outMessage, @"解压暂存项目类型不受支持：%@",
                                relative);
            return NO;
        }
    }

    [directories sortUsingComparator:^NSComparisonResult(NSString *left,
                                                           NSString *right) {
        NSUInteger leftDepth = [left componentsSeparatedByString:@"/"].count;
        NSUInteger rightDepth = [right componentsSeparatedByString:@"/"].count;
        if (leftDepth < rightDepth) return NSOrderedAscending;
        if (leftDepth > rightDepth) return NSOrderedDescending;
        return [left compare:right options:NSLiteralSearch];
    }];

    for (NSString *relative in directories) {
        NSString *stagedPath =
            [stagingDirectory stringByAppendingPathComponent:relative];
        struct stat status = {0};
        if (lstat(stagedPath.fileSystemRepresentation, &status) != 0) {
            int saved = errno;
            FSSetArchiveMessage(outMessage, @"无法检查暂存目录：%@（%s）",
                                relative, strerror(saved));
            return NO;
        }
        if (!FSEnsureSafeRelativeDirectory(destination, relative,
                0755, createdDirectories, outMessage)) {
            return NO;
        }
    }

    NSMutableArray<NSDictionary *> *changes = [NSMutableArray array];
    BOOL success = YES;
    BOOL rollbackMayBeIncomplete = NO;
    for (NSString *relative in files) {
        NSString *parent = relative.stringByDeletingLastPathComponent;
        if (!FSEnsureSafeRelativeDirectory(destination, parent, 0755,
                                            createdDirectories, outMessage)) {
            success = NO;
            break;
        }

        NSString *source =
            [stagingDirectory stringByAppendingPathComponent:relative];
        NSString *target = [destination stringByAppendingPathComponent:relative];
        NSString *backup = nil;
        struct stat targetStatus = {0};
        if (lstat(target.fileSystemRepresentation, &targetStatus) == 0) {
            if (S_ISDIR(targetStatus.st_mode)) {
                FSSetArchiveMessage(outMessage,
                    @"无法用文件覆盖已有目录：%@", target);
                success = NO;
                break;
            }
            backup = [target.stringByDeletingLastPathComponent
                stringByAppendingPathComponent:[NSString stringWithFormat:
                    @".filza-unzip-backup-%@.tmp", NSUUID.UUID.UUIDString]];
            if (rename(target.fileSystemRepresentation,
                       backup.fileSystemRepresentation) != 0) {
                int saved = errno;
                FSSetArchiveMessage(outMessage, @"无法备份已有文件：%@（%s）",
                                    target, strerror(saved));
                success = NO;
                break;
            }
        } else if (errno != ENOENT) {
            int saved = errno;
            FSSetArchiveMessage(outMessage, @"无法检查已有文件：%@（%s）",
                                target, strerror(saved));
            success = NO;
            break;
        }

        if (rename(source.fileSystemRepresentation,
                   target.fileSystemRepresentation) != 0) {
            int saved = errno;
            if (backup && rename(backup.fileSystemRepresentation,
                                 target.fileSystemRepresentation) != 0) {
                NSLog(@"[ArchiveUnzipFix] cannot restore immediate backup "
                      @"%@ -> %@: %s", backup, target, strerror(errno));
                rollbackMayBeIncomplete = YES;
            }
            FSSetArchiveMessage(outMessage, @"无法提交解压文件：%@（%s）",
                                target, strerror(saved));
            success = NO;
            break;
        }
        [changes addObject:@{
            @"path": target,
            @"backup": backup ?: NSNull.null,
        }];
    }

    if (!success) {
        NSString *failureMessage = outMessage ? *outMessage : nil;
        BOOL rollbackComplete = FSRollbackCommittedFiles(changes);
        if (!rollbackComplete || rollbackMayBeIncomplete) {
            FSSetArchiveMessage(outMessage,
                @"%@；自动回滚未完整完成，隐藏备份已保留",
                failureMessage ?: @"解压提交失败");
        }
        return NO;
    }

    NSSet<NSString *> *createdDirectorySet =
        [NSSet setWithArray:createdDirectories];
    for (NSString *relative in directories.reverseObjectEnumerator) {
        NSNumber *modeValue = directoryModes[relative];
        if (!modeValue) continue;
        NSString *path = [destination stringByAppendingPathComponent:relative];
        if (![createdDirectorySet containsObject:path]) continue;
        mode_t permissions = (mode_t)(modeValue.unsignedShortValue & 0777);
        if (!permissions) permissions = 0755;
        if (chmod(path.fileSystemRepresentation, permissions) != 0) {
            NSLog(@"[ArchiveUnzipFix] cannot apply directory mode to %@: %s",
                  path, strerror(errno));
        }
    }

    for (NSDictionary *change in changes) {
        id backupValue = change[@"backup"];
        if (backupValue == NSNull.null) continue;
        NSString *backup = backupValue;
        if (unlink(backup.fileSystemRepresentation) != 0 && errno != ENOENT) {
            NSLog(@"[ArchiveUnzipFix] cannot remove committed backup %@: %s",
                  backup, strerror(errno));
        }
    }
    return YES;
}

#pragma mark - Self-contained RAR/RAR5 extraction

typedef struct {
    int descriptor;
    int writeError;
} FSRarWriteContext;

static int CALLBACK FSRarStreamCallback(UINT message, LPARAM userData,
                                        LPARAM parameter1, LPARAM parameter2)
{
    if (message != UCM_PROCESSDATA) return 0;
    FSRarWriteContext *context = (FSRarWriteContext *)(intptr_t)userData;
    if (!context || context->descriptor < 0 || parameter2 < 0) return -1;

    const uint8_t *bytes = (const uint8_t *)(intptr_t)parameter1;
    size_t remaining = (size_t)parameter2;
    while (remaining > 0) {
        ssize_t written = write(context->descriptor, bytes, remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) {
            context->writeError = written < 0 ? errno : EIO;
            return -1;
        }
        bytes += written;
        remaining -= (size_t)written;
    }
    return 0;
}

static NSString *FSRarHeaderName(const struct RARHeaderDataEx *header)
{
    if (!header) return nil;
    if (header->FileNameW[0] != 0) {
        size_t length = 0;
        while (length < sizeof(header->FileNameW) / sizeof(wchar_t) &&
               header->FileNameW[length] != 0) length++;
        if (length > 0) {
            NSStringEncoding encoding = sizeof(wchar_t) == 4
                ? NSUTF32LittleEndianStringEncoding
                : NSUTF16LittleEndianStringEncoding;
            NSString *name = [[NSString alloc] initWithBytes:header->FileNameW
                length:length * sizeof(wchar_t) encoding:encoding];
            if (name.length) return name;
        }
    }
    return header->FileName[0] ? [NSString stringWithUTF8String:header->FileName]
                               : nil;
}

static NSString *FSRarFailureDescription(int code, BOOL hasPassword)
{
    if (code == ERAR_BAD_PASSWORD || code == ERAR_MISSING_PASSWORD)
        return hasPassword ? @"RAR 密码不正确" : @"RAR 需要密码";
    if (code == ERAR_BAD_ARCHIVE || code == ERAR_UNKNOWN_FORMAT)
        return @"RAR 文件格式无效或已损坏";
    if (code == ERAR_BAD_DATA) return @"RAR 数据或校验失败";
    return [NSString stringWithFormat:@"RAR 解压失败（代码 %d）", code];
}

static BOOL FSExtractRarEntries(NSString *archivePath,
                                NSString *stagingDirectory,
                                NSString *password,
                                NSMutableOrderedSet<NSString *> *topLevelNames,
                                NSUInteger *outExtracted,
                                NSString **outMessage)
{
    struct RAROpenArchiveDataEx openData = {0};
    openData.ArcName = (char *)archivePath.fileSystemRepresentation;
    openData.OpenMode = RAR_OM_EXTRACT;
    HANDLE archive = RAROpenArchiveEx(&openData);
    if (!archive || openData.OpenResult != ERAR_SUCCESS) {
        int code = openData.OpenResult ?: ERAR_EOPEN;
        FSSetArchiveMessage(outMessage, @"%@",
            FSRarFailureDescription(code, password.length > 0));
        if (archive) RARCloseArchive(archive);
        return NO;
    }

    char passwordBuffer[2048] = {0};
    if (password.length) {
        if (![password getCString:passwordBuffer maxLength:sizeof(passwordBuffer)
                         encoding:NSUTF8StringEncoding]) {
            RARCloseArchive(archive);
            FSSetArchiveMessage(outMessage, @"RAR 密码无法转换为 UTF-8");
            return NO;
        }
        RARSetPassword(archive, passwordBuffer);
    }

    NSFileManager *manager = NSFileManager.defaultManager;
    NSUInteger extracted = 0;
    BOOL success = YES;
    int result = ERAR_SUCCESS;
    for (;;) {
        struct RARHeaderDataEx header = {0};
        result = RARReadHeaderEx(archive, &header);
        if (result == ERAR_END_ARCHIVE) break;
        if (result != ERAR_SUCCESS) {
            FSSetArchiveMessage(outMessage, @"%@",
                FSRarFailureDescription(result, password.length > 0));
            success = NO;
            break;
        }

        NSString *rawName = FSRarHeaderName(&header);
        NSString *relative = FSSafeRelativeZipPath(rawName);
        if (!relative.length || header.RedirType != 0) {
            FSSetArchiveMessage(outMessage,
                header.RedirType != 0 ? @"RAR 包含链接条目，已拒绝：%@"
                                      : @"RAR 包含不安全路径：%@",
                rawName ?: @"<unknown>");
            success = NO;
            break;
        }
        [topLevelNames addObject:[relative componentsSeparatedByString:@"/"].firstObject];

        NSString *outputPath =
            [stagingDirectory stringByAppendingPathComponent:relative];
        BOOL directory = (header.Flags & RHDF_DIRECTORY) != 0;
        if (directory) {
            NSError *directoryError = nil;
            if (![manager createDirectoryAtPath:outputPath
                     withIntermediateDirectories:YES attributes:nil
                                           error:&directoryError]) {
                FSSetArchiveMessage(outMessage, @"创建 RAR 目录失败：%@",
                                    directoryError.localizedDescription);
                success = NO;
                break;
            }
            result = RARProcessFileW(archive, RAR_SKIP, NULL, NULL);
            if (result != ERAR_SUCCESS) {
                FSSetArchiveMessage(outMessage, @"%@",
                    FSRarFailureDescription(result, password.length > 0));
                success = NO;
                break;
            }
            extracted++;
            continue;
        }

        NSError *parentError = nil;
        if (![manager createDirectoryAtPath:outputPath.stringByDeletingLastPathComponent
                 withIntermediateDirectories:YES attributes:nil
                                       error:&parentError]) {
            FSSetArchiveMessage(outMessage, @"创建 RAR 父目录失败：%@",
                                parentError.localizedDescription);
            success = NO;
            break;
        }
        NSString *temporaryPath = [outputPath.stringByDeletingLastPathComponent
            stringByAppendingPathComponent:[NSString stringWithFormat:
                @".filza-rar-%@.tmp", NSUUID.UUID.UUIDString]];
        int descriptor = open(temporaryPath.fileSystemRepresentation,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
        if (descriptor < 0) {
            FSSetArchiveMessage(outMessage, @"无法创建 RAR 临时文件：%@（%s）",
                                temporaryPath, strerror(errno));
            success = NO;
            break;
        }

        FSRarWriteContext context = {.descriptor = descriptor, .writeError = 0};
        RARSetCallback(archive, FSRarStreamCallback, (LPARAM)(intptr_t)&context);
        result = RARProcessFileW(archive, RAR_TEST, NULL, NULL);
        RARSetCallback(archive, NULL, 0);
        BOOL fileSuccess = result == ERAR_SUCCESS && context.writeError == 0;
        if (fileSuccess && fchmod(descriptor, 0644) != 0) {
            context.writeError = errno;
            fileSuccess = NO;
        }
        if (fileSuccess && fsync(descriptor) != 0) {
            context.writeError = errno;
            fileSuccess = NO;
        }
        if (close(descriptor) != 0 && fileSuccess) {
            context.writeError = errno;
            fileSuccess = NO;
        }
        context.descriptor = -1;
        if (fileSuccess && rename(temporaryPath.fileSystemRepresentation,
                                  outputPath.fileSystemRepresentation) != 0) {
            context.writeError = errno;
            fileSuccess = NO;
        }
        if (!fileSuccess) {
            unlink(temporaryPath.fileSystemRepresentation);
            if (context.writeError) {
                FSSetArchiveMessage(outMessage, @"写入 RAR 文件失败：%@（%s）",
                                    relative, strerror(context.writeError));
            } else {
                FSSetArchiveMessage(outMessage, @"%@",
                    FSRarFailureDescription(result, password.length > 0));
            }
            success = NO;
            break;
        }
        extracted++;
    }

    RARCloseArchive(archive);
    if (outExtracted) *outExtracted = extracted;
    return success;
}

static NSArray *FSExtractRar(id archiveArgument, id destinationArgument,
                             id currentDirectoryArgument, id passwordArgument,
                             NSString **outMessage)
{
    NSString *archivePath = FSArchivePathFromArgument(archiveArgument);
    NSString *destination = FSArchivePathFromArgument(destinationArgument);
    NSString *currentDirectory =
        FSArchivePathFromArgument(currentDirectoryArgument);
    if (!archivePath.length || !destination.length) {
        FSSetArchiveMessage(outMessage, @"RAR 路径或解压目标无效");
        return nil;
    }

    NSMutableArray<NSString *> *createdDirectories = [NSMutableArray array];
    if (!FSCreateDirectoryChain(destination, createdDirectories, outMessage)) {
        FSCleanupCreatedDirectories(createdDirectories);
        return nil;
    }
    NSString *operationDestination =
        FSCanonicalDirectory(destination, outMessage);
    NSString *stagingDirectory = operationDestination
        ? FSCreateStagingDirectory(operationDestination, outMessage) : nil;
    if (!stagingDirectory) {
        FSCleanupCreatedDirectories(createdDirectories);
        return nil;
    }

    NSString *password = [passwordArgument isKindOfClass:NSString.class]
        ? passwordArgument : nil;
    NSMutableOrderedSet<NSString *> *topLevelNames =
        [NSMutableOrderedSet orderedSet];
    NSUInteger extracted = 0;
    BOOL success = FSExtractRarEntries(archivePath, stagingDirectory, password,
                                       topLevelNames, &extracted, outMessage);
    if (success && extracted == 0) {
        FSSetArchiveMessage(outMessage, @"RAR 中没有可解压的项目");
        success = NO;
    }
    if (success) {
        success = FSCommitStagedExtraction(stagingDirectory,
            operationDestination, @{}, createdDirectories, outMessage);
    }

    NSError *cleanupError = nil;
    if (![NSFileManager.defaultManager removeItemAtPath:stagingDirectory
                                                   error:&cleanupError] &&
        cleanupError.code != NSFileNoSuchFileError) {
        NSLog(@"[ArchiveUnzipFix] cannot remove RAR staging %@: %@",
              stagingDirectory, cleanupError);
    }
    if (!success) {
        FSCleanupCreatedDirectories(createdDirectories);
        return nil;
    }
    FSSetArchiveMessage(outMessage, @"完成（%lu 项）", (unsigned long)extracted);
    return FSArchiveResultForDestination(destination,
        currentDirectory ?: destination, topLevelNames.array);
}

static BOOL FSArchivePathIsRar(NSString *path)
{
    if (!path.length) return NO;
    if ([path.pathExtension.lowercaseString isEqualToString:@"rar"]) return YES;
    int descriptor = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
    if (descriptor < 0) return NO;
    uint8_t signature[8] = {0};
    ssize_t count = read(descriptor, signature, sizeof(signature));
    close(descriptor);
    static const uint8_t rarPrefix[] = {0x52, 0x61, 0x72, 0x21, 0x1a, 0x07};
    return count >= 7 && memcmp(signature, rarPrefix, sizeof(rarPrefix)) == 0;
}

static NSArray *FSExtractZip(id zipArgument, id destinationArgument,
                             id currentDirectoryArgument, id passwordArgument,
                             NSString **outMessage)
{
    if (!FSLoadInProcessUnzip()) {
        FSSetArchiveMessage(outMessage, @"内置 ZIP 解压模块不可用");
        return nil;
    }

    NSString *zipPath = FSArchivePathFromArgument(zipArgument);
    NSString *destination = FSArchivePathFromArgument(destinationArgument);
    if (!destination && [destinationArgument isKindOfClass:NSString.class])
        destination = destinationArgument;
    NSString *currentDirectory = FSArchivePathFromArgument(currentDirectoryArgument);
    if (!currentDirectory && [currentDirectoryArgument isKindOfClass:NSString.class])
        currentDirectory = currentDirectoryArgument;
    if (!zipPath.length || !destination.length) {
        FSSetArchiveMessage(outMessage, @"ZIP 路径或解压目标无效");
        return nil;
    }

    const char *password = NULL;
    if ([passwordArgument isKindOfClass:NSString.class] &&
        [(NSString *)passwordArgument length] > 0)
        password = [(NSString *)passwordArgument UTF8String];

    FSUnzFile archive = pFSUnzOpen64(zipPath.fileSystemRepresentation);
    if (!archive) {
        FSSetArchiveMessage(outMessage, @"打开 ZIP 失败：%@", zipPath.lastPathComponent);
        return nil;
    }

    NSFileManager *manager = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *createdDirectories = [NSMutableArray array];
    if (!FSCreateDirectoryChain(destination, createdDirectories, outMessage)) {
        pFSUnzClose(archive);
        FSCleanupCreatedDirectories(createdDirectories);
        return nil;
    }
    NSString *operationDestination =
        FSCanonicalDirectory(destination, outMessage);
    if (!operationDestination) {
        pFSUnzClose(archive);
        FSCleanupCreatedDirectories(createdDirectories);
        return nil;
    }
    NSString *stagingDirectory =
        FSCreateStagingDirectory(operationDestination, outMessage);
    if (!stagingDirectory) {
        pFSUnzClose(archive);
        FSCleanupCreatedDirectories(createdDirectories);
        return nil;
    }

    NSMutableOrderedSet<NSString *> *topLevelNames =
        [NSMutableOrderedSet orderedSet];
    NSMutableDictionary<NSString *, NSNumber *> *directoryModes =
        [NSMutableDictionary dictionary];

    BOOL success = YES;
    NSUInteger extracted = 0;
    int cursorResult = pFSUnzGoToFirstFile(archive);
    if (cursorResult != 0 && cursorResult != -100) {
        FSSetArchiveMessage(outMessage, @"读取 ZIP 目录失败（代码 %d）", cursorResult);
        success = NO;
    }

    while (success && cursorResult == 0) {
        FSUnzFileInfo64 info = {0};
        int infoResult = pFSUnzGetCurrentFileInfo64(archive, &info,
            NULL, 0, NULL, 0, NULL, 0);
        if (infoResult != 0 || info.size_filename == 0 || info.size_filename > 65535) {
            FSSetArchiveMessage(outMessage, @"读取 ZIP 文件名失败（代码 %d）", infoResult);
            success = NO;
            break;
        }

        NSMutableData *nameData = [NSMutableData dataWithLength:(NSUInteger)info.size_filename + 1];
        infoResult = pFSUnzGetCurrentFileInfo64(archive, &info,
            nameData.mutableBytes, info.size_filename + 1, NULL, 0, NULL, 0);
        if (infoResult != 0) {
            FSSetArchiveMessage(outMessage, @"读取 ZIP 条目信息失败（代码 %d）", infoResult);
            success = NO;
            break;
        }

        NSString *rawName = FSDecodeZipFilename(nameData.bytes,
                                                 (NSUInteger)info.size_filename);
        NSString *relative = FSSafeRelativeZipPath(rawName);
        if (!relative.length) {
            FSSetArchiveMessage(outMessage, @"ZIP 包含不安全或无效路径：%@",
                                rawName ?: @"<无法解码>");
            success = NO;
            break;
        }

        mode_t unixMode = (mode_t)((info.external_fa >> 16) & 0xffff);
        BOOL directoryEntry = [rawName hasSuffix:@"/"] || [rawName hasSuffix:@"\\"] ||
            S_ISDIR(unixMode);
        NSString *fullPath =
            [stagingDirectory stringByAppendingPathComponent:relative];

        if (directoryEntry) {
            NSError *error = nil;
            if (![manager createDirectoryAtPath:fullPath withIntermediateDirectories:YES
                                      attributes:@{NSFilePosixPermissions: @0755}
                                           error:&error]) {
                FSSetArchiveMessage(outMessage, @"创建解压目录失败：%@", error.localizedDescription);
                success = NO;
                break;
            }
            directoryModes[relative] = @((unixMode & 0777) ?: 0755);
            extracted++;
        } else {
            NSError *parentError = nil;
            NSString *parent = fullPath.stringByDeletingLastPathComponent;
            if (![manager createDirectoryAtPath:parent withIntermediateDirectories:YES
                                      attributes:@{NSFilePosixPermissions: @0755}
                                           error:&parentError]) {
                FSSetArchiveMessage(outMessage, @"创建父目录失败：%@", parentError.localizedDescription);
                success = NO;
                break;
            }
            if (!FSWriteCurrentZipEntry(archive, fullPath, password,
                                        unixMode, outMessage)) {
                success = NO;
                break;
            }
            extracted++;
        }

        NSString *topLevelName =
            [[relative componentsSeparatedByString:@"/"] firstObject];
        if (topLevelName.length) [topLevelNames addObject:topLevelName];

        cursorResult = pFSUnzGoToNextFile(archive);
        if (cursorResult != 0 && cursorResult != -100) {
            FSSetArchiveMessage(outMessage, @"继续读取 ZIP 失败（代码 %d）", cursorResult);
            success = NO;
            break;
        }
    }

    int archiveCloseResult = pFSUnzClose(archive);
    if (success && archiveCloseResult != 0) {
        FSSetArchiveMessage(outMessage, @"关闭 ZIP 失败（代码 %d）",
                            archiveCloseResult);
        success = NO;
    }
    if (success) {
        success = FSCommitStagedExtraction(stagingDirectory,
                                           operationDestination,
                                           directoryModes,
                                           createdDirectories, outMessage);
    }

    NSError *cleanupError = nil;
    if (![manager removeItemAtPath:stagingDirectory error:&cleanupError] &&
        cleanupError.code != NSFileNoSuchFileError) {
        NSLog(@"[ArchiveUnzipFix] cannot remove staging directory %@: %@",
              stagingDirectory, cleanupError);
    }
    if (!success) {
        FSCleanupCreatedDirectories(createdDirectories);
        return nil;
    }
    FSSetArchiveMessage(outMessage, @"完成（%lu 项）", (unsigned long)extracted);
    return FSArchiveResultForDestination(destination,
        currentDirectory ?: destination, topLevelNames.array);
}

static NSArray *FSExtractSupportedArchive(
    id archiveArgument, id destinationArgument, id currentDirectoryArgument,
    id passwordArgument, NSString **outMessage)
{
    NSString *archivePath = FSArchivePathFromArgument(archiveArgument);
    if (FSArchivePathIsRar(archivePath)) {
        return FSExtractRar(archiveArgument, destinationArgument,
            currentDirectoryArgument, passwordArgument, outMessage);
    }
    return FSExtractZip(archiveArgument, destinationArgument,
        currentDirectoryArgument, passwordArgument, outMessage);
}

#pragma mark - Zipper overrides

static NSArray *FSHookUnzip(id self, SEL _cmd, id zipPath, id toPath,
                            id currentDirectory, NSString **outMessage)
{
    NSArray *result = FSExtractSupportedArchive(zipPath, toPath,
        currentDirectory, nil, outMessage);
    return FSValidatedArchiveResult(result, outMessage);
}

static NSArray *FSHookUnzipWithPassword(id self, SEL _cmd, id zipPath, id toPath,
                                        id currentDirectory, id password,
                                        NSString **outMessage)
{
    NSArray *result = FSExtractSupportedArchive(zipPath, toPath,
        currentDirectory, password, outMessage);
    return FSValidatedArchiveResult(result, outMessage);
}

static NSArray *FSHookUnrar(id self, SEL _cmd, id rarPath, id toPath,
                            id currentDirectory, NSString **outMessage)
{
    NSArray *result = FSExtractRar(rarPath, toPath, currentDirectory, nil,
                                   outMessage);
    return FSValidatedArchiveResult(result, outMessage);
}

static NSArray *FSHookUnrarWithPassword(id self, SEL _cmd, id rarPath, id toPath,
                                        id currentDirectory, id password,
                                        NSString **outMessage)
{
    NSArray *result = FSExtractRar(rarPath, toPath, currentDirectory, password,
                                   outMessage);
    return FSValidatedArchiveResult(result, outMessage);
}

static const char *FSSkipObjCTypeQualifiers(const char *type)
{
    while (type && *type && strchr("rnNoORV", *type)) type++;
    return type;
}

static BOOL FSObjCTypeIsObject(const char *type)
{
    type = FSSkipObjCTypeQualifiers(type);
    return type && type[0] == '@';
}

static BOOL FSObjCTypeIsObjectPointer(const char *type)
{
    type = FSSkipObjCTypeQualifiers(type);
    if (!type || type[0] != '^') return NO;
    return FSObjCTypeIsObject(type + 1);
}

static BOOL FSMethodHasExpectedUnzipSignature(Method method,
                                              unsigned int argumentCount)
{
    if (!method || method_getNumberOfArguments(method) != argumentCount)
        return NO;

    char returnType[128] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    if (!FSObjCTypeIsObject(returnType)) return NO;

    char argumentType[128] = {0};
    method_getArgumentType(method, 0, argumentType, sizeof(argumentType));
    if (!FSObjCTypeIsObject(argumentType)) return NO;
    memset(argumentType, 0, sizeof(argumentType));
    method_getArgumentType(method, 1, argumentType, sizeof(argumentType));
    if (FSSkipObjCTypeQualifiers(argumentType)[0] != ':') return NO;

    for (unsigned int index = 2; index + 1 < argumentCount; index++) {
        memset(argumentType, 0, sizeof(argumentType));
        method_getArgumentType(method, index, argumentType,
                               sizeof(argumentType));
        if (!FSObjCTypeIsObject(argumentType)) return NO;
    }
    memset(argumentType, 0, sizeof(argumentType));
    method_getArgumentType(method, argumentCount - 1, argumentType,
                           sizeof(argumentType));
    return FSObjCTypeIsObjectPointer(argumentType);
}

void FSInstallArchiveUnzipFix(void)
{
    Class zipper = NSClassFromString(@"Zipper");
    if (!zipper) {
        NSLog(@"[ArchiveUnzipFix] Zipper class unavailable");
        return;
    }

    SEL plainSelector = NSSelectorFromString(
        @"unZipFile:toPath:currentDirectory:outMessage:");
    SEL passwordSelector = NSSelectorFromString(
        @"unZipFile:toPath:currentDirectory:withPassword:outMessage:");
    SEL rarSelector = NSSelectorFromString(
        @"unRarFile:toPath:currentDirectory:outMessage:");
    SEL rarPasswordSelector = NSSelectorFromString(
        @"unRarFile:toPath:currentDirectory:withPassword:outMessage:");
    Method plain = class_getInstanceMethod(zipper, plainSelector);
    Method protectedMethod = class_getInstanceMethod(zipper, passwordSelector);
    Method rar = class_getInstanceMethod(zipper, rarSelector);
    Method protectedRar = class_getInstanceMethod(zipper, rarPasswordSelector);

    if (FSMethodHasExpectedUnzipSignature(plain, 6)) {
        static dispatch_once_t plainOnceToken;
        dispatch_once(&plainOnceToken, ^{
            if (method_getImplementation(plain) != (IMP)FSHookUnzip)
                method_setImplementation(plain, (IMP)FSHookUnzip);
            NSLog(@"[ArchiveUnzipFix] installed plain Zipper extraction hook");
        });
    } else {
        NSLog(@"[ArchiveUnzipFix] incompatible plain Zipper method: %s",
              plain ? method_getTypeEncoding(plain) : "<missing>");
    }

    if (FSMethodHasExpectedUnzipSignature(protectedMethod, 7)) {
        static dispatch_once_t protectedOnceToken;
        dispatch_once(&protectedOnceToken, ^{
            if (method_getImplementation(protectedMethod) !=
                (IMP)FSHookUnzipWithPassword) {
                method_setImplementation(protectedMethod,
                                         (IMP)FSHookUnzipWithPassword);
            }
            NSLog(@"[ArchiveUnzipFix] installed password Zipper extraction hook");
        });
    } else {
        NSLog(@"[ArchiveUnzipFix] incompatible password Zipper method: %s",
              protectedMethod ? method_getTypeEncoding(protectedMethod)
                              : "<missing>");
    }

    if (FSMethodHasExpectedUnzipSignature(rar, 6)) {
        static dispatch_once_t rarOnceToken;
        dispatch_once(&rarOnceToken, ^{
            if (method_getImplementation(rar) != (IMP)FSHookUnrar)
                method_setImplementation(rar, (IMP)FSHookUnrar);
            NSLog(@"[ArchiveUnzipFix] installed plain RAR extraction hook");
        });
    } else {
        NSLog(@"[ArchiveUnzipFix] incompatible plain RAR method: %s",
              rar ? method_getTypeEncoding(rar) : "<missing>");
    }

    if (FSMethodHasExpectedUnzipSignature(protectedRar, 7)) {
        static dispatch_once_t protectedRarOnceToken;
        dispatch_once(&protectedRarOnceToken, ^{
            if (method_getImplementation(protectedRar) !=
                (IMP)FSHookUnrarWithPassword) {
                method_setImplementation(protectedRar,
                                         (IMP)FSHookUnrarWithPassword);
            }
            NSLog(@"[ArchiveUnzipFix] installed password RAR extraction hook");
        });
    } else {
        NSLog(@"[ArchiveUnzipFix] incompatible password RAR method: %s",
              protectedRar ? method_getTypeEncoding(protectedRar)
                           : "<missing>");
    }
}
