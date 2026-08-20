@import UIKit;
#import <objc/message.h>
#import <objc/runtime.h>

#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <stdint.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

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

static BOOL FSLoadInProcessUnzip(void)
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
    if ([item respondsToSelector:selector])
        ((void (*)(id, SEL, id, id))objc_msgSend)(item, selector, path, nil);
    return item;
}

static id FSArchiveResultForDestination(NSString *destination,
                                        NSString *currentDirectory,
                                        NSSet<NSString *> *before)
{
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *dest = destination.stringByStandardizingPath;
    NSString *current = currentDirectory.stringByStandardizingPath;
    if ([dest isEqualToString:current]) {
        NSArray<NSString *> *after = [manager contentsOfDirectoryAtPath:dest error:nil] ?: @[];
        NSMutableArray *items = [NSMutableArray array];
        for (NSString *name in after) {
            if ([before containsObject:name]) continue;
            id item = FSFileItemAtPath([dest stringByAppendingPathComponent:name]);
            if (item) [items addObject:item];
        }
        return items.count ? items : nil;
    }
    return [manager fileExistsAtPath:dest] ? FSFileItemAtPath(dest) : nil;
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

    int descriptor = open(path.fileSystemRepresentation,
        O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW,
        (mode & 0777) ?: 0644);
    if (descriptor < 0) {
        int saved = errno;
        pFSUnzCloseCurrentFile(archive);
        FSSetArchiveMessage(outMessage, @"无法创建解压文件：%@（%s）",
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
    close(descriptor);

    int closeResult = pFSUnzCloseCurrentFile(archive);
    if (success && closeResult != 0) {
        FSSetArchiveMessage(outMessage,
            @"ZIP 条目校验失败（CRC/密码错误，代码 %d）", closeResult);
        success = NO;
    }
    if (!success) {
        unlink(path.fileSystemRepresentation);
        return NO;
    }
    chmod(path.fileSystemRepresentation, (mode & 0777) ?: 0644);
    return YES;
}

static id FSExtractZip(id zipArgument, id destinationArgument,
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

    NSFileManager *manager = NSFileManager.defaultManager;
    NSError *directoryError = nil;
    if (![manager createDirectoryAtPath:destination withIntermediateDirectories:YES
                              attributes:@{NSFilePosixPermissions: @0755}
                                   error:&directoryError]) {
        FSSetArchiveMessage(outMessage, @"无法创建解压目录：%@", directoryError.localizedDescription);
        return nil;
    }

    NSSet<NSString *> *before = [NSSet setWithArray:
        [manager contentsOfDirectoryAtPath:destination error:nil] ?: @[]];
    FSUnzFile archive = pFSUnzOpen64(zipPath.fileSystemRepresentation);
    if (!archive) {
        FSSetArchiveMessage(outMessage, @"打开 ZIP 失败：%@", zipPath.lastPathComponent);
        return nil;
    }

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
        NSString *fullPath = [destination stringByAppendingPathComponent:relative];

        if (directoryEntry) {
            NSError *error = nil;
            if (![manager createDirectoryAtPath:fullPath withIntermediateDirectories:YES
                                      attributes:@{NSFilePosixPermissions:
                                          @((unixMode & 0777) ?: 0755)}
                                           error:&error]) {
                FSSetArchiveMessage(outMessage, @"创建解压目录失败：%@", error.localizedDescription);
                success = NO;
                break;
            }
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

        cursorResult = pFSUnzGoToNextFile(archive);
        if (cursorResult != 0 && cursorResult != -100) {
            FSSetArchiveMessage(outMessage, @"继续读取 ZIP 失败（代码 %d）", cursorResult);
            success = NO;
            break;
        }
    }

    pFSUnzClose(archive);
    if (!success) return nil;
    FSSetArchiveMessage(outMessage, @"完成（%lu 项）", (unsigned long)extracted);
    return FSArchiveResultForDestination(destination,
        currentDirectory ?: destination, before);
}

#pragma mark - Zipper overrides

static IMP gPreviousUnzip = NULL;
static IMP gPreviousUnzipWithPassword = NULL;

static id FSHookUnzip(id self, SEL _cmd, id zipPath, id toPath,
                      id currentDirectory, NSString **outMessage)
{
    id result = FSExtractZip(zipPath, toPath, currentDirectory, nil, outMessage);
    if (!result && !FSLoadInProcessUnzip() && gPreviousUnzip)
        return ((id (*)(id, SEL, id, id, id, NSString **))gPreviousUnzip)(
            self, _cmd, zipPath, toPath, currentDirectory, outMessage);
    return result;
}

static id FSHookUnzipWithPassword(id self, SEL _cmd, id zipPath, id toPath,
                                  id currentDirectory, id password,
                                  NSString **outMessage)
{
    id result = FSExtractZip(zipPath, toPath, currentDirectory, password, outMessage);
    if (!result && !FSLoadInProcessUnzip() && gPreviousUnzipWithPassword)
        return ((id (*)(id, SEL, id, id, id, id, NSString **))gPreviousUnzipWithPassword)(
            self, _cmd, zipPath, toPath, currentDirectory, password, outMessage);
    return result;
}

static void FSInstallArchiveUnzipFix(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class zipper = NSClassFromString(@"Zipper");
        if (!zipper) {
            NSLog(@"[ArchiveUnzipFix] Zipper class unavailable");
            return;
        }

        SEL plainSelector = NSSelectorFromString(
            @"unZipFile:toPath:currentDirectory:outMessage:");
        Method plain = class_getInstanceMethod(zipper, plainSelector);
        if (plain && method_getImplementation(plain) != (IMP)FSHookUnzip) {
            gPreviousUnzip = method_getImplementation(plain);
            method_setImplementation(plain, (IMP)FSHookUnzip);
        }

        SEL passwordSelector = NSSelectorFromString(
            @"unZipFile:toPath:currentDirectory:withPassword:outMessage:");
        Method protectedMethod = class_getInstanceMethod(zipper, passwordSelector);
        if (protectedMethod &&
            method_getImplementation(protectedMethod) != (IMP)FSHookUnzipWithPassword) {
            gPreviousUnzipWithPassword = method_getImplementation(protectedMethod);
            method_setImplementation(protectedMethod, (IMP)FSHookUnzipWithPassword);
        }
        NSLog(@"[ArchiveUnzipFix] installed Zipper in-process extraction hooks");
    });
}

__attribute__((constructor)) static void FSArchiveUnzipBootstrap(void)
{
    // Tweak.m installs its original hooks in another constructor. Scheduling on
    // the main queue guarantees this override runs after all image constructors.
    dispatch_async(dispatch_get_main_queue(), ^{
        FSInstallArchiveUnzipFix();
    });
    [NSNotificationCenter.defaultCenter
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil queue:nil usingBlock:^(__unused NSNotification *note) {
        FSInstallArchiveUnzipFix();
    }];
}
