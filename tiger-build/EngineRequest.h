#import <Cocoa/Cocoa.h>

/* One request to the built-in engine (TBService). It runs on a worker thread and never blocks the window. When it finishes
   it sends [target performSelector:action withObject:request] exactly once, on the main thread. */
@interface EngineRequest : NSObject {
    NSMutableData *payload;
    int statusCode;
    BOOL finished;
    id target;
    SEL action;
    id context;
    NSString *path;
    NSArray *usageEvents;     /* the usage lines (cost) of the model calls behind a side reply, as property list text */
}

/* ~/Library/Application Support/Tiger Build, made when needed. */
+ (NSString *)supportDir;

+ (EngineRequest *)send:(NSString *)method
                   path:(NSString *)path
                   body:(NSString *)body
                timeout:(double)seconds
                 target:(id)target
                 action:(SEL)action
                context:(id)context;

/* A file's bytes with its name (for converting and transcribing). */
+ (EngineRequest *)sendFile:(NSData *)data
                       name:(NSString *)name
                       path:(NSString *)path
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
- (NSArray *)usage;
- (NSArray *)takeUsage;     /* the usage lines, once: a second call gets none */
- (id)context;
- (NSString *)path;
@end
