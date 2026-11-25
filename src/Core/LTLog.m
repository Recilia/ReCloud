#import "LTLog.h"

// Logging runs from every thread, and the hot paths (each cover that loads, each
// playback tick) call it several times a second. Opening the log, seeking to its
// end, writing and closing it again cost four syscalls per line, which was
// measurable on an iPhone 4S while scrolling, so the handle is opened once and
// kept. The file is capped as well: a long session on a 16 GB device previously
// grew it without any limit at all.
static const unsigned long long LTLogMaxBytes = 1024ULL * 1024ULL;

static NSFileHandle *LTLogHandle = nil;
static unsigned long long LTLogBytesWritten = 0;
static NSLock *LTLogLock = nil;

void LTLogAppend(NSString *message) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        LTLogLock = [[NSLock alloc] init];
        NSString *path = [LTTempDirectory() stringByAppendingPathComponent:@"reinmusic.log"];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
        unsigned long long existing =
            [[attrs objectForKey:NSFileSize] unsignedLongLongValue];
        if (existing > LTLogMaxBytes) {
            // Start over rather than grow without bound next session.
            [fm removeItemAtPath:path error:NULL];
            existing = 0;
        }
        if (!existing) [fm createFileAtPath:path contents:nil attributes:nil];
        LTLogHandle = [NSFileHandle fileHandleForWritingAtPath:path];
        LTLogBytesWritten = existing;
        [LTLogHandle seekToEndOfFile];
    });
    if (!LTLogHandle) return;

    NSData *line = [[NSString stringWithFormat:@"[%@] %@\n", [NSDate date], message]
        dataUsingEncoding:NSUTF8StringEncoding];

    [LTLogLock lock];
    if (LTLogBytesWritten + line.length > LTLogMaxBytes) {
        // Keep the log bounded in place instead of letting it fill the disk.
        [LTLogHandle truncateFileAtOffset:0];
        [LTLogHandle seekToFileOffset:0];
        LTLogBytesWritten = 0;
    }
    @try {
        [LTLogHandle writeData:line];
        LTLogBytesWritten += line.length;
    } @catch (NSException *exception) {
        // A full disk or a deleted temp file must never take the app down.
    }
    [LTLogLock unlock];
}
