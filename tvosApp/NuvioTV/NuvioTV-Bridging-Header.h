//
// Use this file to import your target's public headers that you would like to expose to Swift.
//
#import "TorrentEngine.h"

#import <Foundation/Foundation.h>

/// Test build: runs `block` and returns the Objective-C exception it raised, if any (Swift can't
/// catch them; the download test's system calls raise them instead of failing).
static inline NSException * _Nullable NuvioTestCatchException(void (NS_NOESCAPE ^ _Nonnull block)(void)) {
    @try {
        block();
    } @catch (NSException *exception) {
        return exception;
    }
    return nil;
}
