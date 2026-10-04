#import "TBHTTP.h"

static const char *kRoots = NULL;

@implementation TBHTTP

+ (void)loadRoots
{
    static BOOL loaded = NO;
    NSData *pem;
    if (loaded)
        return;
    loaded = YES;
    pem = [NSData dataWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"cacert" ofType:@"pem"]];
    if (!pem)
        pem = [NSData dataWithContentsOfFile:@"cacert.pem"];
    if (pem)
        tbnet_set_roots([pem bytes], [pem length]);
    (void)kRoots;
}

+ (TBHTTP *)request:(NSString *)verb url:(NSString *)address
{
    TBHTTP *http = [[[TBHTTP alloc] init] autorelease];
    http->method = [verb copy];
    http->url = [address copy];
    http->headerLines = [[NSMutableArray alloc] init];
    http->received = [[NSMutableData alloc] init];
    http->connectTimeout = 15;
    http->idleTimeout = 120;
    return http;
}

- (void)dealloc
{
    [method release];
    [url release];
    [headerLines release];
    [body release];
    [received release];
    [responseHeaders release];
    [errorText release];
    [raised release];
    [super dealloc];
}

- (void)setHeader:(NSString *)name value:(NSString *)value
{
    [headerLines addObject:[NSString stringWithFormat:@"%@: %@", name, value]];
}

- (void)setBody:(NSData *)data
{
    [body release];
    body = [data retain];
}

- (void)setIdleTimeout:(int)seconds
{
    idleTimeout = seconds;
}

- (void)setConnectTimeout:(int)seconds
{
    connectTimeout = seconds;
}

- (void)setDelegate:(id)object
{
    delegate = object;
}

static void headersArrived(void *context, int code, const char *text)
{
    TBHTTP *http = (TBHTTP *)context;
    [http noteStatus:code headers:text];
}

static int bodyArrived(void *context, const unsigned char *bytes, size_t length)
{
    TBHTTP *http = (TBHTTP *)context;
    return [http noteBytes:bytes length:length];
}

- (void)noteStatus:(int)code headers:(const char *)text
{
    status = code;
    [responseHeaders release];
    responseHeaders = [[NSString alloc] initWithUTF8String:text ? text : ""];
    if (!responseHeaders)
        responseHeaders = [[NSString alloc] initWithCString:text ? text : "" encoding:NSISOLatin1StringEncoding];
}

- (int)noteBytes:(const unsigned char *)bytes length:(size_t)length
{
    NSData *piece;
    if (cancelled)
        return 1;
    if (!delegate || status >= 400) {
        [received appendBytes:bytes length:length];
        return 0;
    }
    piece = [NSData dataWithBytes:bytes length:length];
    /* An exception must not unwind through the C code that called this; keep it and raise it after. */
    @try {
        if ([delegate http:self gotData:piece]) {
            stoppedByDelegate = YES;
            return 1;
        }
        return 0;
    } @catch (NSException *exception) {
        [raised release];
        raised = [exception retain];
        return 1;
    }
}

- (int)perform
{
    TBNetRequest request;
    char message[300];
    NSArray *lines = headerLines;
    const char **headers = malloc(sizeof(char *) * ([lines count] + 1));
    NSMutableArray *keep = [NSMutableArray array];
    unsigned i;
    int rc;
    [TBHTTP loadRoots];
    for (i = 0; i < [lines count]; i++) {
        NSData *line = [[lines objectAtIndex:i] dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
        NSMutableData *terminated = [NSMutableData dataWithData:line];
        [terminated appendBytes:"\0" length:1];
        [keep addObject:terminated];
        headers[i] = [terminated bytes];
    }
    headers[i] = NULL;
    memset(&request, 0, sizeof(request));
    request.method = [method UTF8String];
    request.url = [url UTF8String];
    request.headers = headers;
    request.body = body ? [body bytes] : NULL;
    request.bodyLength = body ? [body length] : 0;
    request.connectTimeout = connectTimeout;
    request.idleTimeout = idleTimeout;
    request.cancel = &cancelled;
    request.context = self;
    request.onHeaders = headersArrived;
    request.onBody = bodyArrived;
    status = 0;
    [received setLength:0];
    [raised release];
    raised = nil;
    stoppedByDelegate = NO;
    rc = tbnet_perform(&request, message, sizeof(message));
    if (rc == TBNET_ERR_CANCELLED && stoppedByDelegate && !cancelled && !raised)
        rc = TBNET_OK;
    free(headers);
    if (raised) {
        NSException *again = [[raised retain] autorelease];
        [raised release];
        raised = nil;
        [again raise];
    }
    [errorText release];
    errorText = rc == TBNET_OK ? nil : [[NSString alloc] initWithUTF8String:message];
    return rc;
}

- (void)cancel
{
    cancelled = 1;
}

- (int)status
{
    return status;
}

- (NSString *)error
{
    return errorText;
}

- (NSData *)data
{
    return received;
}

- (NSString *)text
{
    NSString *text = [[NSString alloc] initWithData:received encoding:NSUTF8StringEncoding];
    if (!text)
        text = [[NSString alloc] initWithData:received encoding:NSISOLatin1StringEncoding];
    return [text autorelease];
}

- (NSString *)responseHeader:(NSString *)name
{
    NSArray *lines = [responseHeaders componentsSeparatedByString:@"\r\n"];
    NSString *prefix = [[name lowercaseString] stringByAppendingString:@":"];
    unsigned i;
    for (i = 0; i < [lines count]; i++) {
        NSString *line = [lines objectAtIndex:i];
        if ([[line lowercaseString] hasPrefix:prefix])
            return [[line substringFromIndex:[prefix length]] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }
    return nil;
}

@end

@implementation TBSSE

- (id)init
{
    self = [super init];
    if (self) {
        pending = [[NSMutableData alloc] init];
        eventName = @"";
    }
    return self;
}

- (void)dealloc
{
    [pending release];
    [eventName release];
    [super dealloc];
}

- (BOOL)done
{
    return done;
}

- (NSArray *)feed:(NSData *)data
{
    NSMutableArray *events = [NSMutableArray array];
    const unsigned char *bytes;
    unsigned long start = 0, i, length;
    if (done)
        return events;
    [pending appendData:data];
    bytes = [pending bytes];
    length = [pending length];
    for (i = 0; i < length; i++) {
        NSString *line;
        unsigned long end;
        if (bytes[i] != '\n')
            continue;
        end = i;
        if (end > start && bytes[end - 1] == '\r')
            end--;
        line = [[NSString alloc] initWithBytes:bytes + start length:end - start encoding:NSUTF8StringEncoding];
        if (!line)
            line = [[NSString alloc] initWithBytes:bytes + start length:end - start encoding:NSISOLatin1StringEncoding];
        start = i + 1;
        if ([line length] == 0) {
            [eventName release];
            eventName = @"";
        } else if ([line hasPrefix:@"event:"]) {
            [eventName release];
            eventName = [[[line substringFromIndex:6] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] retain];
        } else if ([line hasPrefix:@"data:"]) {
            NSString *payload = [[line substringFromIndex:5] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([payload isEqualToString:@"[DONE]"]) {
                done = YES;
                [line release];
                break;
            }
            if ([payload length])
                [events addObject:[NSDictionary dictionaryWithObjectsAndKeys:eventName, @"event", payload, @"data", nil]];
        }
        [line release];
    }
    if (start > 0) {
        NSData *rest = [NSData dataWithBytes:bytes + start length:length - start];
        [pending setData:rest];
    }
    return events;
}

@end
