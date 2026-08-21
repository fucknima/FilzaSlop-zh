#import "FSLog.h"

// ponytail: whole-file append with size cap; sqlite-style rotation if needed later
static NSString *logPath(void)
{
    static NSString *path;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // keep the log inside the Device Storage virtual root so it is reachable
        // from Filza's own browser; create it early, MCM start reuses the dir
        NSString *documents = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
        NSString *deviceStorage = [documents stringByAppendingPathComponent:@"Device Storage"];
        [[NSFileManager defaultManager] createDirectoryAtPath:deviceStorage
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        path = [deviceStorage stringByAppendingPathComponent:@"filzaslop.log"];
    });
    return path;
}

NSString *FSLogFilePath(void)
{
    return logPath();
}

void FSLog(NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"%@", message);

    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("filzaslop.fslog", DISPATCH_QUEUE_SERIAL);
    });

    dispatch_async(queue, ^{
        NSFileManager *manager = NSFileManager.defaultManager;
        NSDictionary *attributes = [manager attributesOfItemAtPath:logPath() error:nil];
        if (attributes.fileSize > 512 * 1024)
            [manager removeItemAtPath:logPath() error:nil];

        static NSDateFormatter *formatter;
        static dispatch_once_t formatOnce;
        dispatch_once(&formatOnce, ^{
            formatter = [[NSDateFormatter alloc] init];
            formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
        });
        NSString *line = [NSString stringWithFormat:@"%@ %@\n",
            [formatter stringFromDate:NSDate.date], message];
        FILE *file = fopen(logPath().fileSystemRepresentation, "a");
        if (!file) return;
        fputs(line.UTF8String, file);
        fclose(file);
    });
}
