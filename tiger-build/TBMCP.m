#import "TBMCP.h"
#import "TBEngine.h"
#import "TBJSON.h"
#include <sys/time.h>

@interface TBMCPClient (Private)
- (void)readLoop;
- (void)errorLoop;
@end

@implementation TBMCPClient

+ (TBMCPClient *)clientWithPath:(NSString *)launchPath arguments:(NSArray *)args environment:(NSDictionary *)extra label:(NSString *)name
{
    TBMCPClient *client = [[[TBMCPClient alloc] init] autorelease];
    client->path = [launchPath copy];
    client->arguments = [args retain];
    client->environment = [extra retain];
    client->label = [name copy];
    client->pending = [[NSMutableData alloc] init];
    client->errorTail = [[NSMutableData alloc] init];
    client->messages = [[NSMutableArray alloc] init];
    client->nextId = 1;
    pthread_mutex_init(&client->lock, NULL);
    pthread_cond_init(&client->arrived, NULL);
    return client;
}

- (void)dealloc
{
    [self close];
    [path release];
    [arguments release];
    [environment release];
    [label release];
    [pending release];
    [errorTail release];
    [messages release];
    pthread_mutex_destroy(&lock);
    pthread_cond_destroy(&arrived);
    [super dealloc];
}

- (void)start
{
    NSPipe *in = [NSPipe pipe];
    NSPipe *out = [NSPipe pipe];
    NSPipe *err = [NSPipe pipe];
    NSMutableDictionary *env = [NSMutableDictionary dictionaryWithDictionary:[[NSProcessInfo processInfo] environment]];
    if (environment)
        [env addEntriesFromDictionary:environment];
    task = [[NSTask alloc] init];
    [task setLaunchPath:path];
    [task setArguments:arguments];
    [task setEnvironment:env];
    [task setStandardInput:in];
    [task setStandardOutput:out];
    [task setStandardError:err];
    @try {
        [task launch];
    } @catch (NSException *exception) {
        [task release];
        task = nil;
        TBFail(@"%@ could not be started: %@", label, [exception reason]);
    }
    toChild = [[in fileHandleForWriting] retain];
    fromChild = [[out fileHandleForReading] retain];
    errorsFromChild = [[err fileHandleForReading] retain];
    [NSThread detachNewThreadSelector:@selector(readLoop) toTarget:self withObject:nil];
    [NSThread detachNewThreadSelector:@selector(errorLoop) toTarget:self withObject:nil];
    [self request:@"initialize" params:[NSDictionary dictionaryWithObjectsAndKeys:@"2025-06-18", @"protocolVersion", [NSDictionary dictionary], @"capabilities",
        [NSDictionary dictionaryWithObjectsAndKeys:@"tigerbuild", @"name", @"2.0", @"version", nil], @"clientInfo", nil] timeout:45];
    [self notify:@"notifications/initialized" params:[NSDictionary dictionary]];
}

- (void)errorLoop
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSFileHandle *handle = [errorsFromChild retain];
    for (;;) {
        NSData *data;
        NSAutoreleasePool *inner = [[NSAutoreleasePool alloc] init];
        @try {
            data = [handle availableData];
        } @catch (NSException *e) {
            data = nil;
        }
        if ([data length] == 0) {
            [inner release];
            break;
        }
        pthread_mutex_lock(&lock);
        [errorTail appendData:data];
        if ([errorTail length] > 4000)
            [errorTail setData:[errorTail subdataWithRange:NSMakeRange([errorTail length] - 4000, 4000)]];
        pthread_mutex_unlock(&lock);
        [inner release];
    }
    [handle release];
    [pool release];
}

- (void)readLoop
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSFileHandle *handle = [fromChild retain];
    for (;;) {
        NSData *data;
        NSAutoreleasePool *inner = [[NSAutoreleasePool alloc] init];
        const unsigned char *bytes;
        unsigned long start = 0, i, length;
        @try {
            data = [handle availableData];
        } @catch (NSException *e) {
            data = nil;
        }
        if ([data length] == 0) {
            [inner release];
            break;
        }
        [pending appendData:data];
        bytes = [pending bytes];
        length = [pending length];
        for (i = 0; i < length; i++) {
            if (bytes[i] == '\n') {
                if (i > start) {
                    NSData *line = [NSData dataWithBytes:bytes + start length:i - start];
                    id message = TBJSONParse(line, NULL);
                    /* A login banner or stray print is not protocol; skip it. */
                    if ([message isKindOfClass:[NSDictionary class]]) {
                        pthread_mutex_lock(&lock);
                        [messages addObject:message];
                        pthread_cond_broadcast(&arrived);
                        pthread_mutex_unlock(&lock);
                    }
                }
                start = i + 1;
            }
        }
        if (start > 0)
            [pending setData:[NSData dataWithBytes:bytes + start length:length - start]];
        [inner release];
    }
    pthread_mutex_lock(&lock);
    ended = YES;
    pthread_cond_broadcast(&arrived);
    pthread_mutex_unlock(&lock);
    [handle release];
    [pool release];
}

- (void)writeMessage:(id)message
{
    NSMutableData *line = [NSMutableData dataWithData:TBJSONData(message)];
    [line appendBytes:"\n" length:1];
    @try {
        [toChild writeData:line];
    } @catch (NSException *e) {
        TBFail(@"%@ closed the connection.", label);
    }
}

- (void)notify:(NSString *)method params:(id)params
{
    [self writeMessage:[NSDictionary dictionaryWithObjectsAndKeys:@"2.0", @"jsonrpc", method, @"method", params, @"params", nil]];
}

- (id)request:(NSString *)method params:(id)params timeout:(double)seconds
{
    int mid = nextId++;
    struct timeval now;
    struct timespec limit;
    [self writeMessage:[NSDictionary dictionaryWithObjectsAndKeys:@"2.0", @"jsonrpc", [NSNumber numberWithInt:mid], @"id", method, @"method", params, @"params", nil]];
    gettimeofday(&now, NULL);
    limit.tv_sec = now.tv_sec + (long)seconds;
    limit.tv_nsec = now.tv_usec * 1000;
    pthread_mutex_lock(&lock);
    for (;;) {
        unsigned i;
        for (i = 0; i < [messages count]; i++) {
            NSDictionary *message = [messages objectAtIndex:i];
            id identifier = TBValue(message, @"id");
            if ([identifier isKindOfClass:[NSNumber class]] && [identifier intValue] == mid) {
                id error = TBValue(message, @"error");
                id result = TBValue(message, @"result");
                NSString *text = nil;
                [[message retain] autorelease];
                [messages removeObjectAtIndex:i];
                pthread_mutex_unlock(&lock);
                if (error)
                    text = [error isKindOfClass:[NSDictionary class]] ? TBString(error, @"message") : [error description];
                if (text)
                    TBFail(@"%@", [text length] ? text : @"The tool failed.");
                return result ? result : [NSDictionary dictionary];
            }
            [messages removeObjectAtIndex:i];
            i--;
        }
        if (ended || closed) {
            pthread_mutex_unlock(&lock);
            TBFail(@"%@ closed the connection.", label);
        }
        if (pthread_cond_timedwait(&arrived, &lock, &limit) != 0) {
            pthread_mutex_unlock(&lock);
            TBFail(@"%@ did not answer.", label);
        }
    }
}

- (void)close
{
    NSTask *old;
    pthread_mutex_lock(&lock);
    if (closed) {
        pthread_mutex_unlock(&lock);
        return;
    }
    closed = YES;
    old = task;
    task = nil;
    pthread_cond_broadcast(&arrived);
    pthread_mutex_unlock(&lock);
    @try {
        [toChild closeFile];
    } @catch (NSException *e) {
    }
    if (old) {
        @try {
            if ([old isRunning])
                [old terminate];
        } @catch (NSException *e) {
        }
        [old release];
    }
    [toChild release];
    toChild = nil;
}

- (void)cancel
{
    [self close];
}

- (NSString *)stderrText
{
    NSString *text;
    pthread_mutex_lock(&lock);
    text = [[[NSString alloc] initWithData:errorTail encoding:NSUTF8StringEncoding] autorelease];
    pthread_mutex_unlock(&lock);
    return TBTrim(text ? text : @"");
}

@end

NSString *TBMCPResultText(id result)
{
    NSArray *content;
    NSMutableArray *parts = [NSMutableArray array];
    NSString *text;
    unsigned i;
    if (![result isKindOfClass:[NSDictionary class]])
        return [result description];
    content = TBArray(result, @"content");
    for (i = 0; i < [content count]; i++) {
        id item = [content objectAtIndex:i];
        if ([item isKindOfClass:[NSDictionary class]] && [TBString(item, @"text") length])
            [parts addObject:TBString(item, @"text")];
        else if ([item isKindOfClass:[NSString class]])
            [parts addObject:item];
    }
    text = TBTrim([parts componentsJoinedByString:@"\n"]);
    if (TBTruth(result, @"isError") && [text length] == 0)
        text = @"the tool failed";
    if ([text length] > 8000)
        text = [[text substringToIndex:8000] stringByAppendingString:@"\n... truncated"];
    return [text length] ? text : @"ok";
}

NSArray *TBMCPResultImages(id result)
{
    NSMutableArray *images = [NSMutableArray array];
    NSArray *content = TBArray(result, @"content");
    unsigned i;
    for (i = 0; i < [content count]; i++) {
        id item = [content objectAtIndex:i];
        NSString *mime;
        if (![item isKindOfClass:[NSDictionary class]] || ![TBString(item, @"type") isEqualToString:@"image"] || ![TBString(item, @"data") length])
            continue;
        mime = [TBString(item, @"mimeType") length] ? TBString(item, @"mimeType") : @"image/jpeg";
        if (([mime isEqualToString:@"image/jpeg"] || [mime isEqualToString:@"image/png"] || [mime isEqualToString:@"image/gif"] || [mime isEqualToString:@"image/webp"])
            && [TBString(item, @"data") length] < 6000000)
            [images addObject:[NSDictionary dictionaryWithObjectsAndKeys:mime, @"mime", TBString(item, @"data"), @"data", nil]];
    }
    return images;
}

NSString *TBMCPToolSummary(NSString *name, NSDictionary *arguments)
{
    static const char *keys[] = {"path", "command", "file_path", "source", "sessionId", "pid", NULL};
    int i;
    if (![arguments isKindOfClass:[NSDictionary class]])
        return name;
    for (i = 0; keys[i]; i++) {
        id value = TBValue(arguments, [NSString stringWithUTF8String:keys[i]]);
        if (value && !([value isKindOfClass:[NSString class]] && [value length] == 0)) {
            NSMutableString *text = [NSMutableString stringWithString:[value description]];
            [text replaceOccurrencesOfString:@"\n" withString:@" " options:0 range:NSMakeRange(0, [text length])];
            if ([text length] > 80)
                text = [[text substringToIndex:80] stringByAppendingString:@"..."];
            return [NSString stringWithFormat:@"%@ %@", name, text];
        }
    }
    return name;
}

NSArray *TBMCPFunctionTools(id listed)
{
    NSMutableArray *tools = [NSMutableArray array];
    NSArray *items = TBArray(listed, @"tools");
    unsigned i;
    for (i = 0; i < [items count]; i++) {
        NSDictionary *tool = [items objectAtIndex:i];
        NSString *name = TBString(tool, @"name");
        NSMutableDictionary *schema;
        if ([name length] == 0)
            continue;
        schema = [NSMutableDictionary dictionaryWithDictionary:TBDictionary(tool, @"inputSchema") ? TBDictionary(tool, @"inputSchema") : [NSDictionary dictionary]];
        if (![TBString(schema, @"type") isEqualToString:@"object"])
            schema = [NSMutableDictionary dictionaryWithObjectsAndKeys:@"object", @"type", [NSDictionary dictionary], @"properties", nil];
        [schema removeObjectForKey:@"additionalProperties"];
        [tools addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"function", @"type", name, @"name",
            [TBString(tool, @"description") length] ? TBString(tool, @"description") : name, @"description", schema, @"parameters", nil]];
    }
    return tools;
}
