#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// NSLog + append to Documents/filzaslop.log in the app sandbox, so logs are
// readable on-device with Filza itself. Format-string compatible with NSLog.
FOUNDATION_EXPORT void FSLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

// Absolute path of the sandbox log file.
FOUNDATION_EXPORT NSString *FSLogFilePath(void);

NS_ASSUME_NONNULL_END
