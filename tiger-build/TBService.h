#import <Foundation/Foundation.h>
#import "TBSession.h"

/* The engine behind the window. It answers requests made as a path and a body (models, settings, tools, conversion, dictation) and
   streams a chat turn as frames. */

@interface TBService : NSObject
+ (NSString *)version;
/* Runs one request. Returns {status, body (NSData), type}. Call it on a worker thread: some answers wait for the network. */
+ (NSDictionary *)handle:(NSString *)method path:(NSString *)path body:(NSData *)body file:(NSData *)file name:(NSString *)name;
@end

/* A chat turn running on its own thread. Frames reach the delegate on the main thread as -localTurn:bytes: (wire
   format: "<kind> <length>\n<text>"), and -localTurnEnded: after the last. */
@interface TBLocalTurn : NSObject {
    TBRun *run;
    id delegate;
    NSMutableData *pending;
    BOOL flushScheduled;
    BOOL ended;
    NSLock *lock;
    NSData *requestBody;
}
+ (TBLocalTurn *)startWithBody:(NSData *)body delegate:(id)delegate;
- (void)cancel;
@end

@interface NSObject (TBLocalTurnDelegate)
- (void)localTurn:(TBLocalTurn *)turn bytes:(NSData *)bytes;
- (void)localTurnEnded:(TBLocalTurn *)turn;
@end
