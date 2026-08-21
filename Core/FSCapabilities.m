#import "FSCapabilities.h"
#import "MCMBridge.h"
#import "ArchiveUnzipFix.h"

BOOL FSCapNormalFilesystem(void)
{
    return YES;
}

// zip writer and unrar are statically linked into this dylib; unzip additionally
// needs the unz* local symbols of the Filza binary, so probe those.
BOOL FSCapArchive(void)
{
    static BOOL available = NO;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        available = FSLoadInProcessUnzip();
    });
    return available;
}

// SFTP/FTP/WebDAV/SMB clients are statically embedded in the Filza binary (userspace).
BOOL FSCapNetwork(void)
{
    return YES;
}

BOOL FSCapMCMContainers(void)
{
    return MCMBridgeAvailable();
}

BOOL FSCapRootHelper(void) { return NO; }
BOOL FSCapRootShell(void) { return NO; }
BOOL FSCapPackageManager(void) { return NO; }
BOOL FSCapSystemModification(void) { return NO; }

__attribute__((constructor)) static void FSCapabilitiesLogSnapshot(void)
{
    NSLog(@"[FSCapabilities] normal=%d archive=%d network=%d mcm=%d rootHelper=%d rootShell=%d packageManager=%d systemModification=%d",
          FSCapNormalFilesystem(), FSCapArchive(), FSCapNetwork(),
          FSCapMCMContainers(), FSCapRootHelper(), FSCapRootShell(),
          FSCapPackageManager(), FSCapSystemModification());
}
