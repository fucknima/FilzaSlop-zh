#import "FSAccessManager.h"
#import "MCMFilzaIntegration.h"

static NSString *FSNormalizeVarPath(NSString *path)
{
    if ([path hasPrefix:@"/private/var/"])
        return [@"/var" stringByAppendingString:[path substringFromIndex:@"/private/var".length]];
    return path;
}

BOOL FSAccessCanManagePath(NSString *path)
{
    if (!path.length) return NO;
    if (MCMFilzaPathHasActiveLease(path)) return YES;
    NSString *normalized = FSNormalizeVarPath(path);
    NSString *home = FSNormalizeVarPath(NSHomeDirectory());
    return [normalized hasPrefix:home];
}
