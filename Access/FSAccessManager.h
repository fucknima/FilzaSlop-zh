#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// YES when the path lies in a domain this tweak can manage in-process:
// an active MCM lease, the MCM virtual root, or the app's own sandbox container.
// NO for everything else (remote/network paths, inaccessible system locations),
// which must keep falling through to Filza's native handlers.
FOUNDATION_EXPORT BOOL FSAccessCanManagePath(NSString *path);

NS_ASSUME_NONNULL_END
