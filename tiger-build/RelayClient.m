#import "RelayClient.h"
#import "TBService.h"
#include <sys/types.h>
#include <sys/socket.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <arpa/inet.h>

NSString *TBRelayTokenHeader = @"X-TigerBuild-Token";

/* This Mac's IPv4 addresses, comma separated, for a relay reached through an SSH tunnel: the relay then
   sees the connection come from itself and needs to be told which Mac is asking. */
static NSString *myAddresses(void)
{
    static NSString *cached = nil;
    static double when = 0;
    double now = CFAbsoluteTimeGetCurrent();
    struct ifaddrs *list = NULL;
    struct ifaddrs *item;
    NSMutableArray *found;
    if (cached && now - when < 300)
        return cached;
    found = [NSMutableArray array];
    if (getifaddrs(&list) == 0) {
        for (item = list; item; item = item->ifa_next) {
            if (item->ifa_addr && item->ifa_addr->sa_family == AF_INET && !(item->ifa_flags & IFF_LOOPBACK)) {
                struct sockaddr_in *address = (struct sockaddr_in *)item->ifa_addr;
                NSString *text = [NSString stringWithUTF8String:inet_ntoa(address->sin_addr)];
                if (text && ![found containsObject:text])
                    [found addObject:text];
            }
        }
        freeifaddrs(list);
    }
    [cached release];
    cached = [[found componentsJoinedByString:@","] retain];
    when = now;
    return cached;
}

@interface RelayRequest (Private)
- (BOOL)startMethod:(NSString *)method body:(NSString *)body timeout:(double)seconds;
- (void)noteStatus;
- (void)readAvailable;
- (void)complete;
@end

static void relayRequestCallback(CFReadStreamRef stream, CFStreamEventType type, void *info)
{
    RelayRequest *request = (RelayRequest *)info;
    (void)stream;
    if (type == kCFStreamEventHasBytesAvailable) {
        [request readAvailable];
        return;
    }
    if (type == kCFStreamEventEndEncountered || type == kCFStreamEventErrorOccurred) {
        [request readAvailable];
        [request complete];
    }
}

static NSString *readTrimmed(NSString *file)
{
    NSString *text = [NSString stringWithContentsOfFile:file];
    if (!text)
        return @"";
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static BOOL writeText(NSString *text, NSString *file, int mode)
{
    NSData *data = [[text stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *attrs = [NSDictionary dictionaryWithObject:[NSNumber numberWithInt:mode]
                                                      forKey:NSFilePosixPermissions];
    if (![data writeToFile:file atomically:YES])
        return NO;
    [[NSFileManager defaultManager] changeFileAttributes:attrs atPath:file];
    return YES;
}

@interface RelayRequest (Local)
- (void)runLocal:(NSString *)method body:(NSData *)bytes file:(NSData *)file name:(NSString *)name;
@end

@implementation RelayRequest

+ (NSString *)supportDir
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Tiger Build"];
    if (![fm fileExistsAtPath:dir])
        [fm createDirectoryAtPath:dir attributes:nil];
    return dir;
}

+ (NSString *)serverBase
{
    NSString *text = readTrimmed([[self supportDir] stringByAppendingPathComponent:@"server.txt"]);
    while ([text hasSuffix:@"/"])
        text = [text substringToIndex:[text length] - 1];
    return text;
}

+ (NSString *)token
{
    return readTrimmed([[self supportDir] stringByAppendingPathComponent:@"token.txt"]);
}

+ (BOOL)saveServerBase:(NSString *)base token:(NSString *)token
{
    NSString *dir = [self supportDir];
    BOOL ok = YES;
    if (base)
        ok = writeText(base, [dir stringByAppendingPathComponent:@"server.txt"], 0644) && ok;
    if (token)
        ok = writeText(token, [dir stringByAppendingPathComponent:@"token.txt"], 0600) && ok;
    return ok;
}

+ (CFHTTPMessageRef)copyMessage:(NSString *)method path:(NSString *)relative body:(NSData *)body
{
    NSString *base = [self serverBase];
    NSString *token = [self token];
    NSURL *url;
    CFHTTPMessageRef message;
    if ([base length] == 0)
        return NULL;
    url = [NSURL URLWithString:[base stringByAppendingString:relative]];
    if (!url)
        return NULL;
    message = CFHTTPMessageCreateRequest(NULL, (CFStringRef)method, (CFURLRef)url, kCFHTTPVersion1_0);
    if (!message)
        return NULL;
    CFHTTPMessageSetHeaderFieldValue(message, CFSTR("User-Agent"), CFSTR("TigerBuild/1.2"));
    if ([token length] > 0)
        CFHTTPMessageSetHeaderFieldValue(message, (CFStringRef)TBRelayTokenHeader, (CFStringRef)token);
    if ([base rangeOfString:@"127.0.0.1"].location != NSNotFound || [base rangeOfString:@"localhost"].location != NSNotFound)
        CFHTTPMessageSetHeaderFieldValue(message, CFSTR("X-TigerBuild-Client"), (CFStringRef)myAddresses());
    if (body) {
        CFHTTPMessageSetBody(message, (CFDataRef)body);
        CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Content-Type"), CFSTR("application/json; charset=utf-8"));
        CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Content-Length"),
            (CFStringRef)[NSString stringWithFormat:@"%u", (unsigned)[body length]]);
    }
    return message;
}

+ (RelayRequest *)send:(NSString *)method
                  path:(NSString *)relative
                  body:(NSString *)body
               timeout:(double)seconds
                target:(id)aTarget
                action:(SEL)anAction
               context:(id)aContext
{
    RelayRequest *request = [[[RelayRequest alloc] init] autorelease];
    request->target = aTarget;
    request->action = anAction;
    request->context = [aContext retain];
    request->path = [relative copy];
    if ([TBService active]) {
        [request runLocal:method body:body ? [body dataUsingEncoding:NSUTF8StringEncoding] : nil file:nil name:nil];
        return request;
    }
    if (![request startMethod:method body:body timeout:seconds]) {
        /* Report the failure from the run loop, never from inside the caller. */
        [request retain];
        [request performSelector:@selector(complete) withObject:nil afterDelay:0.0];
    }
    return request;
}

+ (RelayRequest *)sendFile:(NSData *)data
                      name:(NSString *)name
                      path:(NSString *)relative
                   timeout:(double)seconds
                    target:(id)aTarget
                    action:(SEL)anAction
                   context:(id)aContext
{
    RelayRequest *request = [[[RelayRequest alloc] init] autorelease];
    request->target = aTarget;
    request->action = anAction;
    request->context = [aContext retain];
    request->path = [relative copy];
    request->fileData = [data retain];
    request->fileName = [name copy];
    if ([TBService active]) {
        [request runLocal:@"POST" body:nil file:data name:name];
        return request;
    }
    if (![request startMethod:@"POST" body:nil timeout:seconds]) {
        [request retain];
        [request performSelector:@selector(complete) withObject:nil afterDelay:0.0];
    }
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
    [context release];
    [path release];
    [fileData release];
    [fileName release];
    [super dealloc];
}

- (BOOL)startMethod:(NSString *)method body:(NSString *)body timeout:(double)seconds
{
    CFHTTPMessageRef message;
    CFStreamClientContext client;
    NSData *bytes = fileData ? fileData : (body ? [body dataUsingEncoding:NSUTF8StringEncoding] : nil);
    message = [RelayRequest copyMessage:method path:path body:bytes];
    if (!message)
        return NO;
    if (fileData) {
        NSString *escaped = [(NSString *)CFURLCreateStringByAddingPercentEscapes(NULL, (CFStringRef)fileName, NULL,
            CFSTR(":/?#[]@!$&'()*+,;= %"), kCFStringEncodingUTF8) autorelease];
        CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Content-Type"), CFSTR("application/octet-stream"));
        CFHTTPMessageSetHeaderFieldValue(message, CFSTR("X-Filename"), (CFStringRef)(escaped ? escaped : @"file"));
    }
    stream = CFReadStreamCreateForHTTPRequest(NULL, message);
    CFRelease(message);
    if (!stream)
        return NO;
    memset(&client, 0, sizeof(client));
    client.info = self;
    CFReadStreamSetClient(stream,
        kCFStreamEventHasBytesAvailable | kCFStreamEventEndEncountered | kCFStreamEventErrorOccurred,
        relayRequestCallback, &client);
    CFReadStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
    if (!CFReadStreamOpen(stream)) {
        CFReadStreamSetClient(stream, 0, NULL, NULL);
        CFReadStreamUnscheduleFromRunLoop(stream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
        CFRelease(stream);
        stream = NULL;
        return NO;
    }
    /* Keep ourselves alive until complete; the timer retains us too. */
    [self retain];
    timer = [NSTimer scheduledTimerWithTimeInterval:seconds
                                             target:self
                                           selector:@selector(timeout:)
                                           userInfo:nil
                                            repeats:NO];
    return YES;
}

/* The engine answers: the request runs on a worker thread and is reported from the main one, once. */
- (void)runLocal:(NSString *)method body:(NSData *)bytes file:(NSData *)file name:(NSString *)name
{
    NSDictionary *job = [NSDictionary dictionaryWithObjectsAndKeys:method, @"method", path, @"path", bytes ? bytes : [NSData data], @"body",
        file ? file : [NSData data], @"file", name ? name : @"", @"name", nil];
    /* One retain for the worker, one that complete balances, as for a network request. */
    [self retain];
    [self retain];
    [NSThread detachNewThreadSelector:@selector(localWork:) toTarget:self withObject:job];
}

- (void)localWork:(NSDictionary *)job
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSDictionary *result = [TBService handle:[job objectForKey:@"method"] path:[job objectForKey:@"path"] body:[job objectForKey:@"body"]
                                        file:[[job objectForKey:@"file"] length] ? [job objectForKey:@"file"] : nil name:[job objectForKey:@"name"]];
    [self performSelectorOnMainThread:@selector(localDone:) withObject:result waitUntilDone:NO];
    [pool release];
}

- (void)localDone:(NSDictionary *)result
{
    statusCode = [[result objectForKey:@"status"] intValue];
    [payload setData:[result objectForKey:@"body"]];
    [self complete];
    [self release];
}

- (void)timeout:(NSTimer *)aTimer
{
    (void)aTimer;
    timer = nil;
    timedOut = YES;
    [self complete];
}

- (void)noteStatus
{
    CFHTTPMessageRef response;
    if (statusCode != 0 || !stream)
        return;
    response = (CFHTTPMessageRef)CFReadStreamCopyProperty(stream, kCFStreamPropertyHTTPResponseHeader);
    if (!response)
        return;
    statusCode = CFHTTPMessageGetResponseStatusCode(response);
    CFRelease(response);
}

- (void)readAvailable
{
    UInt8 buf[8192];
    CFIndex count;
    if (!stream)
        return;
    [self noteStatus];
    while (CFReadStreamHasBytesAvailable(stream)) {
        count = CFReadStreamRead(stream, buf, sizeof(buf));
        if (count <= 0)
            break;
        [payload appendBytes:buf length:(unsigned)count];
    }
}

- (void)shutStream
{
    if (timer) {
        [timer invalidate];
        timer = nil;
    }
    if (stream) {
        [self noteStatus];
        CFReadStreamSetClient(stream, 0, NULL, NULL);
        CFReadStreamUnscheduleFromRunLoop(stream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
        CFReadStreamClose(stream);
        CFRelease(stream);
        stream = NULL;
    }
}

- (void)complete
{
    id aTarget;
    if (finished)
        return;
    finished = YES;
    [self shutStream];
    aTarget = target;
    target = nil;
    if (aTarget && action)
        [aTarget performSelector:action withObject:self];
    /* Balances the retain in startMethod or in send's failure path. */
    [self autorelease];
}

- (void)cancel
{
    if (finished)
        return;
    target = nil;
    [self complete];
}

- (int)status
{
    return statusCode;
}

- (BOOL)ok
{
    return !timedOut && statusCode == 200;
}

- (BOOL)timedOut
{
    return timedOut;
}

- (NSData *)data
{
    return payload;
}

- (NSString *)text
{
    NSString *value = [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding];
    if (!value)
        value = [[NSString alloc] initWithData:payload encoding:NSMacOSRomanStringEncoding];
    return [value autorelease];
}

- (id)context
{
    return context;
}

- (NSString *)path
{
    return path;
}

@end
