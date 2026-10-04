#import <Foundation/Foundation.h>
#import "TBSession.h"

/* What the relay used to be, inside the app. It answers the same requests Tiger Build always made (a path, a body) and streams a
   chat turn as the same frames, so the window code did not have to change. */

@interface TBService : NSObject
/* NO only while someone is comparing against a relay (the preference TBUseRelay). */
+ (BOOL)active;
+ (NSString *)version;
/* Runs one request. Returns {status, body (NSData), type}. Call it on a worker thread: some answers wait for the network. */
+ (NSDictionary *)handle:(NSString *)method path:(NSString *)path body:(NSData *)body file:(NSData *)file name:(NSString *)name;
@end

/* A chat turn running on its own thread. Frames reach the delegate on the main thread as -localTurn:bytes: (the relay's wire
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
