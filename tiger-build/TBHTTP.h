#import <Foundation/Foundation.h>
#import "TBNet.h"

/* One HTTP or HTTPS request, run on the calling thread (a worker; never the main one). The body can be delivered as it
   arrives, which is how a model's reply is shown while it is being written. */
@interface TBHTTP : NSObject {
    NSString *method;
    NSString *url;
    NSMutableArray *headerLines;
    NSData *body;
    int connectTimeout;
    int idleTimeout;
    volatile int cancelled;
    id delegate;
    NSMutableData *received;
    NSString *responseHeaders;
    NSString *errorText;
    NSException *raised;
    BOOL stoppedByDelegate;
    int status;
}

/* Loads cacert.pem from the app once; safe to call again. */
+ (void)loadRoots;
+ (TBHTTP *)request:(NSString *)method url:(NSString *)url;
- (void)setHeader:(NSString *)name value:(NSString *)value;
- (void)setBody:(NSData *)data;
- (void)setIdleTimeout:(int)seconds;
- (void)setConnectTimeout:(int)seconds;
/* Optional. Told of each piece of the body with -http:gotData: (return YES to stop). Without a delegate the body is kept. */
- (void)setDelegate:(id)object;
/* Blocks until the response is complete. Returns TBNET_OK or a TBNET_ERR_ code; see -error. The status is -status. */
- (int)perform;
/* From any thread. */
- (void)cancel;
- (int)status;
- (NSString *)error;
- (NSData *)data;
- (NSString *)text;
- (NSString *)responseHeader:(NSString *)name;
@end

@interface NSObject (TBHTTPDelegate)
- (BOOL)http:(TBHTTP *)http gotData:(NSData *)data;
@end

/* Server-sent events: "event:" and "data:" lines, as model services stream them. Feed it pieces as they arrive. */
@interface TBSSE : NSObject {
    NSMutableData *pending;
    NSString *eventName;
    BOOL done;
}
/* The data lines that are complete so far, each {event, data} with the text after "data:". "[DONE]" sets -done and ends the list. */
- (NSArray *)feed:(NSData *)data;
- (BOOL)done;
@end
