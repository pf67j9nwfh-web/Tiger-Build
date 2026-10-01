#import "RelayClient.h"

NSString *TBRelayTokenHeader = @"X-TigerBuild-Token";

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
    if (![request startMethod:method body:body timeout:seconds]) {
        /* Report the failure from the run loop, never from inside the caller. */
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
    [super dealloc];
}

- (BOOL)startMethod:(NSString *)method body:(NSString *)body timeout:(double)seconds
{
    CFHTTPMessageRef message;
    CFStreamClientContext client;
    NSData *bytes = body ? [body dataUsingEncoding:NSUTF8StringEncoding] : nil;
    message = [RelayRequest copyMessage:method path:path body:bytes];
    if (!message)
        return NO;
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
