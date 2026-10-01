#import <Cocoa/Cocoa.h>
#import <CoreServices/CoreServices.h>

/* The relay address and token live in
   ~/Library/Application Support/Tiger Build/server.txt and token.txt. */
extern NSString *TBRelayTokenHeader;

/* One HTTP request to the relay. It runs on the main run loop and never
   blocks the window. When it finishes, fails, or times out it sends
   [target performSelector:action withObject:request] exactly once. */
@interface RelayRequest : NSObject {
    NSMutableData *payload;
    int statusCode;
    BOOL finished;
    BOOL timedOut;
    CFReadStreamRef stream;
    NSTimer *timer;
    id target;
    SEL action;
    id context;
    NSString *path;
}

+ (NSString *)supportDir;
+ (NSString *)serverBase;
+ (NSString *)token;
+ (BOOL)saveServerBase:(NSString *)base token:(NSString *)token;

/* A request message with the token and User-Agent set. Caller releases. */
+ (CFHTTPMessageRef)copyMessage:(NSString *)method path:(NSString *)path body:(NSData *)body;

+ (RelayRequest *)send:(NSString *)method
                  path:(NSString *)path
                  body:(NSString *)body
               timeout:(double)seconds
                target:(id)target
                action:(SEL)action
               context:(id)context;

- (void)cancel;
- (int)status;
- (BOOL)ok;
- (BOOL)timedOut;
- (NSData *)data;
- (NSString *)text;
- (id)context;
- (NSString *)path;
@end
