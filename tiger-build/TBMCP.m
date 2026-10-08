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
        [NSDictionary dictionaryWithObjectsAndKeys:@"tigerbuild", @"name", @"2.2", @"version", nil], @"clientInfo", nil] timeout:45];
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
            NSString *shown;
            [text replaceOccurrencesOfString:@"\n" withString:@" " options:0 range:NSMakeRange(0, [text length])];
            shown = [text length] > 80 ? [[text substringToIndex:80] stringByAppendingString:@"..."] : text;
            return [NSString stringWithFormat:@"%@ %@", name, shown];
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

/* ---- MCP over HTTP ---- */

#import "TBHTTP.h"
#import "TBOAuth.h"
#import <unistd.h>

@interface TBMCPHTTPClient (Legacy)
- (id)postLegacy:(NSDictionary *)message wantId:(id)wanted timeout:(double)seconds;
- (void)startLegacy;
@end

/* a dotted-quad address on a private network (10.x, 172.16 to 31, 192.168.x); a name that merely starts with those digits is not */
static BOOL privateNetworkAddress(NSString *host)
{
    int a, b, c, d, used = 0;
    if (sscanf([host UTF8String], "%d.%d.%d.%d%n", &a, &b, &c, &d, &used) != 4 || used != (int)strlen([host UTF8String]))
        return NO;
    if (a < 0 || a > 255 || b < 0 || b > 255 || c < 0 || c > 255 || d < 0 || d > 255)
        return NO;
    return a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168);
}

@implementation TBMCPHTTPClient

+ (TBMCPHTTPClient *)clientWithURL:(NSString *)u token:(NSString *)t
{
    TBMCPHTTPClient *c = [[[TBMCPHTTPClient alloc] init] autorelease];
    c->url = [u copy];
    c->token = [t copy];
    c->nextId = 1;
    return c;
}

- (void)dealloc
{
    [url release];
    [token release];
    [session release];
    [failure release];
    [postURL release];
    [answers release];
    [streamError release];
    [sseParser release];
    [lastChallenge release];
    [super dealloc];
}

- (NSString *)stderrText { return failure ? failure : @""; }

- (void)cancel
{
    closed = 1;
    [(TBHTTP *)current cancel];
}

- (void)close
{
    closed = 1;
    [(TBHTTP *)current cancel];
}

/* the token to send: the one the server was given, or what signing in produced */
- (NSString *)bearerNow
{
    if ([token length])
        return token;
    return [TBOAuth tokenForServer:url];
}

/* the server answered 401: sign in (once), then the caller tries again. NO when it cannot be done (the reason is raised). */
- (BOOL)signInAfter401:(NSString *)challenge
{
    NSString *why = nil;
    if ([token length] || freshAuth || [challenge rangeOfString:@"bearer" options:NSCaseInsensitiveSearch].location == NSNotFound)
        return NO;
    if (![TBOAuth authorizeServer:url challenge:challenge error:&why]) {
        if ([why isEqualToString:@"cancelled"])
            TBFail(@"Signing in to this server was cancelled.");
        TBFail(@"%@", why ? why : @"Signing in failed.");
    }
    return YES;
}

/* One message out. Returns the reply with this id, or nil for a notification. */
- (id)post:(NSDictionary *)message wantId:(id)wanted timeout:(double)seconds
{
    TBHTTP *http;
    if (legacy)
        return [self postLegacy:message wantId:wanted timeout:seconds];
    http = [TBHTTP request:@"POST" url:url];
    int result;
    NSString *type;
    [http setHeader:@"Content-Type" value:@"application/json"];
    [http setHeader:@"Accept" value:@"application/json, text/event-stream"];
    [http setHeader:@"MCP-Protocol-Version" value:@"2025-06-18"];
    if (session)
        [http setHeader:@"Mcp-Session-Id" value:session];
    {
        NSString *bearer = [self bearerNow];
        if ([bearer length])
            [http setHeader:@"Authorization" value:[@"Bearer " stringByAppendingString:bearer]];
    }
    [http setBody:TBJSONData(message)];
    [http setIdleTimeout:seconds > 5 ? (int)seconds : 5];
    current = http;
    result = [http perform];
    current = nil;
    if (result == TBNET_OK && [http status] == 401 && [self signInAfter401:[http responseHeader:@"WWW-Authenticate"]]) {
        id again;
        freshAuth = YES;
        @try {
            again = [self post:message wantId:wanted timeout:seconds];
        } @finally {
            freshAuth = NO;
        }
        return again;
    }
    if (closed)
        TBFail(@"The MCP server connection was closed.");
    if (result != TBNET_OK) {
        [failure release];
        failure = [[http error] copy];
        TBFail(@"%@", [http error]);
    }
    if ([[http responseHeader:@"Mcp-Session-Id"] length]) {
        [session release];
        session = [[http responseHeader:@"Mcp-Session-Id"] copy];
    }
    if ([http status] < 200 || [http status] >= 300) {
        NSString *body = [http text];
        TBFail(@"HTTP %d%@", [http status], [body length] ? [@": " stringByAppendingString:[body length] > 200 ? [body substringToIndex:200] : body] : @"");
    }
    if (!wanted)
        return nil;
    type = [http responseHeader:@"Content-Type"];
    if ([[type lowercaseString] hasPrefix:@"text/event-stream"]) {
        TBSSE *sse = [[[TBSSE alloc] init] autorelease];
        NSArray *events = [sse feed:[http data]];
        unsigned i;
        for (i = 0; i < [events count]; i++) {
            id json = TBJSONParseString([[events objectAtIndex:i] objectForKey:@"data"], NULL);
            if ([json isKindOfClass:[NSDictionary class]] && [[json objectForKey:@"id"] isEqual:wanted])
                return json;
        }
        TBFail(@"Remote MCP ended without a response.");
    }
    {
        id json = TBJSONParse([http data], NULL);
        if (![json isKindOfClass:[NSDictionary class]])
            TBFail(@"The MCP server sent a reply that is not JSON.");
        return json;
    }
}

/* ---- the older HTTP+SSE transport ---- */

/* the address the server announced, which must be on the same site as the stream (the token goes there) */
- (NSString *)resolvedEndpoint:(NSString *)announced
{
    NSURL *base = [NSURL URLWithString:url], *full = [NSURL URLWithString:announced relativeToURL:base];
    NSURL *absolute = [full absoluteURL];
    if (!absolute || ![[[absolute host] lowercaseString] isEqualToString:[[base host] lowercaseString]] || ![[absolute scheme] isEqualToString:[base scheme]]
        || ([absolute port] ? [[absolute port] intValue] : 0) != ([base port] ? [[base port] intValue] : 0))
        return nil;
    return [absolute absoluteString];
}

/* On the reader thread: each event of the stream as it arrives */
- (BOOL)http:(TBHTTP *)http gotData:(NSData *)data
{
    NSArray *events;
    unsigned i;
    if (closed)
        return YES;
    events = [sseParser feed:data];
    for (i = 0; i < [events count]; i++) {
        NSDictionary *event = [events objectAtIndex:i];
        NSString *name = [event objectForKey:@"event"], *text = [event objectForKey:@"data"];
        if ([name isEqualToString:@"endpoint"]) {
            NSString *resolved = [self resolvedEndpoint:TBTrim(text)];
            @synchronized(self) {
                if (resolved && !postURL)
                    postURL = [resolved copy];
                else if (!resolved && !streamError)
                    streamError = [@"The server named a place to send messages that is on another site." copy];
            }
        } else if ([name length] == 0 || [name isEqualToString:@"message"]) {
            id json = TBJSONParseString(text, NULL);
            if ([json isKindOfClass:[NSDictionary class]] && [json objectForKey:@"id"] && ([json objectForKey:@"result"] || [json objectForKey:@"error"])) {
                @synchronized(self) {
                    [answers setObject:json forKey:[[json objectForKey:@"id"] description]];
                }
            }
        }
    }
    return NO;
}

- (void)readStream:(id)unused
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    TBHTTP *http = [TBHTTP request:@"GET" url:url];
    int rc;
    (void)unused;
    [TBHTTP loadRoots];
    [http setHeader:@"Accept" value:@"text/event-stream"];
    {
        NSString *bearer = [self bearerNow];
        if ([bearer length])
            [http setHeader:@"Authorization" value:[@"Bearer " stringByAppendingString:bearer]];
    }
    [http setIdleTimeout:3600];
    [http setDelegate:self];
    sseParser = [[TBSSE alloc] init];
    current = http;
    rc = [http perform];
    current = nil;
    @synchronized(self) {
        if ([http status] == 401) {
            [lastChallenge release];
            lastChallenge = [[http responseHeader:@"WWW-Authenticate"] copy];
        }
        if (!streamError && !closed)
            streamError = [(rc != TBNET_OK ? [http error] : ([http status] >= 300 ? [NSString stringWithFormat:@"HTTP %d", [http status]] : @"The server closed the stream.")) copy];
    }
    streamEnded = 1;
    [pool release];
}

- (id)postLegacy:(NSDictionary *)message wantId:(id)wanted timeout:(double)seconds
{
    TBHTTP *http;
    NSString *where;
    double waited = 0;
    @synchronized(self) { where = [[postURL copy] autorelease]; }
    if (!where)
        TBFail(@"The server has not said where to send messages.");
    http = [TBHTTP request:@"POST" url:where];
    [http setHeader:@"Content-Type" value:@"application/json"];
    {
        NSString *bearer = [self bearerNow];
        if ([bearer length])
            [http setHeader:@"Authorization" value:[@"Bearer " stringByAppendingString:bearer]];
    }
    [http setBody:TBJSONData(message)];
    [http setIdleTimeout:30];
    if ([http perform] != TBNET_OK)
        TBFail(@"%@", [http error]);
    if ([http status] < 200 || [http status] >= 300)
        TBFail(@"HTTP %d", [http status]);
    if (!wanted)
        return nil;
    for (;;) {
        id reply = nil;
        @synchronized(self) {
            reply = [answers objectForKey:[wanted description]];
            if (reply)
                [answers removeObjectForKey:[wanted description]];
        }
        if (reply)
            return reply;
        if (closed)
            TBFail(@"The MCP server connection was closed.");
        if (streamEnded) {
            NSString *why;
            @synchronized(self) { why = [[streamError copy] autorelease]; }
            TBFail(@"The MCP server's stream ended: %@", why ? why : @"closed");
        }
        if (waited >= seconds)
            TBFail(@"The MCP server did not answer in time.");
        usleep(40000);
        waited += 0.04;
    }
}

- (void)startLegacy
{
    double waited = 0;
    legacy = YES;
    streamEnded = 0;
    [postURL release]; postURL = nil;
    [answers release]; answers = [[NSMutableDictionary alloc] init];
    [streamError release]; streamError = nil;
    [NSThread detachNewThreadSelector:@selector(readStream:) toTarget:self withObject:nil];
    for (;;) {
        BOOL have;
        @synchronized(self) { have = postURL != nil || streamError != nil; }
        if (have || streamEnded || closed || waited > 20)
            break;
        usleep(50000);
        waited += 0.05;
    }
    {
        NSString *challenge = nil;
        BOOL unauthorized;
        @synchronized(self) {
            unauthorized = !postURL && [streamError hasPrefix:@"HTTP 401"];
            challenge = [[lastChallenge copy] autorelease];
        }
        if (unauthorized && !freshAuth && [self signInAfter401:challenge]) {
            freshAuth = YES;
            @try {
                [self startLegacy];
            } @finally {
                freshAuth = NO;
            }
            return;
        }
    }
    @synchronized(self) {
        if (!postURL)
            TBFail(@"%@", streamError ? streamError : @"The server did not say where to send messages (the older SSE transport needs an endpoint event).");
    }
}

- (id)request:(NSString *)method params:(id)params timeout:(double)seconds
{
    NSNumber *ident = [NSNumber numberWithInt:nextId++];
    NSDictionary *reply = [self post:[NSDictionary dictionaryWithObjectsAndKeys:@"2.0", @"jsonrpc", ident, @"id", method, @"method", params ? params : [NSDictionary dictionary], @"params", nil]
        wantId:ident timeout:seconds];
    id err = [reply objectForKey:@"error"];
    if (err) {
        NSString *m = [err isKindOfClass:[NSDictionary class]] ? [err objectForKey:@"message"] : [err description];
        TBFail(@"%@", m ? m : @"The MCP server returned an error.");
    }
    return [reply objectForKey:@"result"] ? [reply objectForKey:@"result"] : [NSDictionary dictionary];
}

- (void)notify:(NSString *)method params:(id)params
{
    [self post:[NSDictionary dictionaryWithObjectsAndKeys:@"2.0", @"jsonrpc", method, @"method", params ? params : [NSDictionary dictionary], @"params", nil] wantId:nil timeout:30];
}

- (void)start
{
    NSString *lower = [url lowercaseString];
    NSURL *parsed = [NSURL URLWithString:url];
    NSString *host = [[parsed host] lowercaseString];
    if (!parsed || ![host length])
        TBFail(@"Specify a valid Streamable HTTP MCP URL.");
    if ([lower hasPrefix:@"http://"] && !([host isEqualToString:@"localhost"] || [host isEqualToString:@"127.0.0.1"] || [host isEqualToString:@"::1"] || [host hasSuffix:@".local"] || [host hasSuffix:@".lan"] || [host hasSuffix:@".home"]
        || privateNetworkAddress(host) || [[NSUserDefaults standardUserDefaults] boolForKey:@"TBAllowPlainMCP"]))
        TBFail(@"MCP servers outside your own network must use HTTPS.");
    {
        NSDictionary *hello = [NSDictionary dictionaryWithObjectsAndKeys:@"2025-06-18", @"protocolVersion", [NSDictionary dictionary], @"capabilities",
            [NSDictionary dictionaryWithObjectsAndKeys:@"tigerbuild", @"name", @"2.2", @"version", nil], @"clientInfo", nil];
        if ([[[parsed path] lowercaseString] hasSuffix:@"/sse"])
            [self startLegacy];
        else {
            @try {
                [self request:@"initialize" params:hello timeout:45];
            } @catch (NSException *e) {
                NSString *why = [e reason];
                /* the answers of a server that only has the older transport (the specification's own way to tell) */
                if ([why hasPrefix:@"HTTP 404"] || [why hasPrefix:@"HTTP 405"] || [why hasPrefix:@"HTTP 400"])
                    [self startLegacy];
                else
                    [e raise];
            }
        }
        if (legacy)
            [self request:@"initialize" params:[NSDictionary dictionaryWithObjectsAndKeys:@"2024-11-05", @"protocolVersion", [NSDictionary dictionary], @"capabilities",
                [NSDictionary dictionaryWithObjectsAndKeys:@"tigerbuild", @"name", @"2.2", @"version", nil], @"clientInfo", nil] timeout:45];
    }
    [self notify:@"notifications/initialized" params:[NSDictionary dictionary]];
}

@end
