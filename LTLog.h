#import <Foundation/Foundation.h>
#import "LTFilePaths.h"

// Appends one line to the on-device log. Implemented in LTLog.m so the whole app
// shares a single open file handle instead of opening, seeking and closing the
// file for every line.
void LTLogAppend(NSString *message);

static inline void LTLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"%@", msg);
    LTLogAppend(msg);
}
