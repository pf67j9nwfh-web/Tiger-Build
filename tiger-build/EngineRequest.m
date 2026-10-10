#import "EngineRequest.h"
#import "TBService.h"

@interface EngineRequest (Private)
- (void)runWithMethod:(NSString *)method body:(NSData *)bytes file:(NSData *)file name:(NSString *)name;
- (void)complete;
@end

@implementation EngineRequest

+ (NSString *)supportDir
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Tiger Build"];
    if (![fm fileExistsAtPath:dir])
        [fm createDirectoryAtPath:dir attributes:nil];
    return dir;
}

+ (EngineRequest *)send:(NSString *)method
                   path:(NSString *)relative
                   body:(NSString *)body
                timeout:(double)seconds
                 target:(id)aTarget
                 action:(SEL)anAction
                context:(id)aContext
{
    EngineRequest *request = [[[EngineRequest alloc] init] autorelease];
    (void)seconds;
    request->target = aTarget;
    request->action = anAction;
    request->context = [aContext retain];
    request->path = [relative copy];
    [request runWithMethod:method body:body ? [body dataUsingEncoding:NSUTF8StringEncoding] : nil file:nil name:nil];
    return request;
}

+ (EngineRequest *)sendFile:(NSData *)data
                       name:(NSString *)name
                       path:(NSString *)relative
                    timeout:(double)seconds
                     target:(id)aTarget
                     action:(SEL)anAction
                    context:(id)aContext
{
    EngineRequest *request = [[[EngineRequest alloc] init] autorelease];
    (void)seconds;
    request->target = aTarget;
    request->action = anAction;
    request->context = [aContext retain];
    request->path = [relative copy];
    [request runWithMethod:@"POST" body:nil file:data name:name];
    return request;
}

- (id)init
{
    self = [super init];
    if (!self)
        return nil;
    payload = [[NSMutableData alloc] init];
    return self;
}

- (void)dealloc
{
    [payload release];
    [usageEvents release];
    [context release];
    [path release];
    [super dealloc];
}

/* The engine answers from a worker thread; the result is reported from the main one, once. */
- (void)runWithMethod:(NSString *)method body:(NSData *)bytes file:(NSData *)file name:(NSString *)name
{
    NSDictionary *job = [NSDictionary dictionaryWithObjectsAndKeys:method, @"method", path, @"path", bytes ? bytes : [NSData data], @"body",
        file ? file : [NSData data], @"file", name ? name : @"", @"name", nil];
    /* One retain for the worker, one that complete balances. */
    [self retain];
    [self retain];
    [NSThread detachNewThreadSelector:@selector(work:) toTarget:self withObject:job];
}

- (void)work:(NSDictionary *)job
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSDictionary *result = [TBService handle:[job objectForKey:@"method"] path:[job objectForKey:@"path"] body:[job objectForKey:@"body"]
                                        file:[[job objectForKey:@"file"] length] ? [job objectForKey:@"file"] : nil name:[job objectForKey:@"name"]];
    [self performSelectorOnMainThread:@selector(done:) withObject:result waitUntilDone:NO];
    [pool release];
}

- (void)done:(NSDictionary *)result
{
    statusCode = [[result objectForKey:@"status"] intValue];
    [payload setData:[result objectForKey:@"body"]];
    usageEvents = [[result objectForKey:@"usage"] retain];
    [self complete];
    [self release];
}

- (void)complete
{
    id aTarget;
    if (finished)
        return;
    finished = YES;
    aTarget = target;
    target = nil;
    if (aTarget && action)
        [aTarget performSelector:action withObject:self];
    [self autorelease];
}

- (void)cancel
{
    if (finished)
        return;
    target = nil;
    [self complete];
}

- (NSArray *)usage { return usageEvents; }
- (NSArray *)takeUsage
{
    NSArray *taken = [[usageEvents retain] autorelease];
    [usageEvents release];
    usageEvents = nil;
    return taken;
}
- (int)status { return statusCode; }
- (BOOL)ok { return statusCode == 200; }
- (BOOL)timedOut { return NO; }
- (NSData *)data { return payload; }

- (NSString *)text
{
    NSString *value = [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding];
    if (!value)
        value = [[NSString alloc] initWithData:payload encoding:NSMacOSRomanStringEncoding];
    return [value autorelease];
}

- (id)context { return context; }
- (NSString *)path { return path; }

@end
