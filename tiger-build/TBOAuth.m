#import "TBOAuth.h"
#import "TBEngine.h"
#import "TBHTTP.h"
#import "TBJSON.h"
#import "TBSupport.h"
#import <AppKit/AppKit.h>
#import <sys/socket.h>
#import <sys/select.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import "mbedtls/sha256.h"

/* TB_OAUTH_TEST=1 (for the tests): the address to open is printed instead of opened, nobody is asked, and nothing is written to the Keychain. */
static BOOL testMode(void) { return getenv("TB_OAUTH_TEST") != NULL; }
static NSMutableDictionary *memoryStore = nil;

static NSMutableDictionary *loadAll(void)
{
    NSMutableDictionary *all = nil;
    if (testMode()) {
        if (!memoryStore)
            memoryStore = [[NSMutableDictionary alloc] init];
        return memoryStore;
    }
    {
        NSString *json = [TBSettings valueForName:@"mcp_oauth"];
        id parsed = [json length] ? TBJSONParseString(json, NULL) : nil;
        all = [NSMutableDictionary dictionaryWithDictionary:[parsed isKindOfClass:[NSDictionary class]] ? parsed : [NSDictionary dictionary]];
    }
    return all;
}

static void saveAll(NSDictionary *all)
{
    if (testMode())
        return;
    [TBSettings setValue:[all count] ? TBJSONString(all) : @"" forName:@"mcp_oauth"];
}

static NSString *encode(NSString *s)
{
    return [(NSString *)CFURLCreateStringByAddingPercentEscapes(NULL, (CFStringRef)s, NULL, CFSTR(":/?#[]@!$&'()*+,;="), kCFStringEncodingUTF8) autorelease];
}

static NSString *base64url(const unsigned char *bytes, unsigned n)
{
    static const char *t = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    NSMutableString *out = [NSMutableString string];
    unsigned i;
    for (i = 0; i < n; i += 3) {
        unsigned v = bytes[i] << 16 | (i + 1 < n ? bytes[i + 1] << 8 : 0) | (i + 2 < n ? bytes[i + 2] : 0);
        [out appendFormat:@"%c%c", t[(v >> 18) & 63], t[(v >> 12) & 63]];
        if (i + 1 < n) [out appendFormat:@"%c", t[(v >> 6) & 63]];
        if (i + 2 < n) [out appendFormat:@"%c", t[v & 63]];
    }
    return out;
}

static NSString *randomToken(unsigned bytes)
{
    unsigned char b[64];
    unsigned i;
    if (bytes > sizeof b) bytes = sizeof b;
    for (i = 0; i < bytes; i++)
        b[i] = (unsigned char)(arc4random() & 255);
    return base64url(b, bytes);
}

/* a request to a metadata or token address: the parsed JSON object, or nil with *why set */
static NSDictionary *call(NSString *method, NSString *url, NSString *contentType, NSData *body, NSString **why)
{
    TBHTTP *http = [TBHTTP request:method url:url];
    id json;
    [TBHTTP loadRoots];
    [http setHeader:@"Accept" value:@"application/json"];
    [http setHeader:@"User-Agent" value:@"TigerBuild"];
    if (contentType)
        [http setHeader:@"Content-Type" value:contentType];
    if (body)
        [http setBody:body];
    [http setIdleTimeout:30];
    if ([http perform] != TBNET_OK) {
        *why = [http error] ? [http error] : @"The connection failed.";
        return nil;
    }
    json = TBJSONParse([http data], NULL);
    if ([http status] < 200 || [http status] >= 300) {
        NSString *detail = [json isKindOfClass:[NSDictionary class]] ? ([TBString(json, @"error_description") length] ? TBString(json, @"error_description") : TBString(json, @"error")) : nil;
        *why = [NSString stringWithFormat:@"HTTP %d%@", [http status], [detail length] ? [@": " stringByAppendingString:detail] : @""];
        return nil;
    }
    if (![json isKindOfClass:[NSDictionary class]]) {
        *why = @"The answer was not JSON.";
        return nil;
    }
    return json;
}

static NSString *originOf(NSString *url)
{
    NSURL *u = [NSURL URLWithString:url];
    NSString *scheme = [u scheme], *host = [u host];
    if (!scheme || !host)
        return nil;
    return [u port] ? [NSString stringWithFormat:@"%@://%@:%@", scheme, host, [u port]] : [NSString stringWithFormat:@"%@://%@", scheme, host];
}

/* every endpoint found in metadata must be https, or http when the server itself is (a server on your own network) */
static BOOL endpointOK(NSString *endpoint, NSString *serverURL)
{
    NSString *lower = [endpoint lowercaseString];
    if ([lower hasPrefix:@"https://"])
        return YES;
    return [lower hasPrefix:@"http://"] && [[serverURL lowercaseString] hasPrefix:@"http://"];
}

/* the value of key="value" in a WWW-Authenticate header */
static NSString *headerParam(NSString *header, NSString *key)
{
    NSRange r = [header rangeOfString:[key stringByAppendingString:@"=\""] options:NSCaseInsensitiveSearch];
    NSString *rest;
    NSRange end;
    if (r.location == NSNotFound)
        return nil;
    rest = [header substringFromIndex:r.location + r.length];
    end = [rest rangeOfString:@"\""];
    return end.location == NSNotFound ? nil : [rest substringToIndex:end.location];
}

@implementation TBOAuth

+ (BOOL)hasTokenForServer:(NSString *)url
{
    @synchronized(self) {
        return [[loadAll() objectForKey:url] objectForKey:@"access"] != nil;
    }
    return NO;
}

+ (void)forgetServer:(NSString *)url
{
    @synchronized(self) {
        NSMutableDictionary *all = loadAll();
        if ([all objectForKey:url]) {
            [all removeObjectForKey:url];
            saveAll(all);
        }
    }
}

+ (NSString *)tokenForServer:(NSString *)url
{
    NSDictionary *entry;
    @synchronized(self) {
        entry = [[[loadAll() objectForKey:url] retain] autorelease];
    }
    if (![entry objectForKey:@"access"])
        return nil;
    if ([[entry objectForKey:@"expires"] doubleValue] > [[NSDate date] timeIntervalSince1970] + 60 || ![[entry objectForKey:@"expires"] doubleValue])
        return [entry objectForKey:@"access"];
    /* run out: a refresh, if there is one */
    if ([[entry objectForKey:@"refresh"] length] && [[entry objectForKey:@"token_endpoint"] length]) {
        NSMutableString *form = [NSMutableString stringWithFormat:@"grant_type=refresh_token&refresh_token=%@&client_id=%@", encode([entry objectForKey:@"refresh"]), encode([entry objectForKey:@"client_id"])];
        NSString *why = nil;
        NSDictionary *answer;
        if ([[entry objectForKey:@"resource"] length])
            [form appendFormat:@"&resource=%@", encode([entry objectForKey:@"resource"])];
        answer = call(@"POST", [entry objectForKey:@"token_endpoint"], @"application/x-www-form-urlencoded", [form dataUsingEncoding:NSUTF8StringEncoding], &why);
        if (answer && [TBString(answer, @"access_token") length]) {
            NSMutableDictionary *fresh = [NSMutableDictionary dictionaryWithDictionary:entry];
            double life = [[answer objectForKey:@"expires_in"] doubleValue];
            [fresh setObject:TBString(answer, @"access_token") forKey:@"access"];
            if ([TBString(answer, @"refresh_token") length])
                [fresh setObject:TBString(answer, @"refresh_token") forKey:@"refresh"];
            [fresh setObject:[NSNumber numberWithDouble:life > 0 ? [[NSDate date] timeIntervalSince1970] + life : 0] forKey:@"expires"];
            @synchronized(self) {
                NSMutableDictionary *all = loadAll();
                [all setObject:fresh forKey:url];
                saveAll(all);
            }
            return [fresh objectForKey:@"access"];
        }
    }
    [self forgetServer:url];
    return nil;
}

/* one visit to the loopback port: the query of GET /callback?..., or nil when the time ran out */
+ (NSDictionary *)waitForRedirectOnSocket:(int)fd seconds:(int)seconds
{
    double deadline = [[NSDate date] timeIntervalSince1970] + seconds;
    for (;;) {
        fd_set set;
        struct timeval wait = {1, 0};
        int client;
        char buffer[4096];
        ssize_t n;
        NSString *request, *line, *path;
        NSRange q;
        if ([[NSDate date] timeIntervalSince1970] > deadline)
            return nil;
        FD_ZERO(&set);
        FD_SET(fd, &set);
        if (select(fd + 1, &set, NULL, NULL, &wait) <= 0)
            continue;
        client = accept(fd, NULL, NULL);
        if (client < 0)
            continue;
        {
            struct timeval rt = {5, 0};
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &rt, sizeof rt);
        }
        n = read(client, buffer, sizeof buffer - 1);
        if (n <= 0) {
            close(client);
            continue;
        }
        buffer[n] = 0;
        request = [NSString stringWithUTF8String:buffer];
        line = [[request componentsSeparatedByString:@"\r\n"] objectAtIndex:0];
        path = [[line componentsSeparatedByString:@" "] count] > 1 ? [[line componentsSeparatedByString:@" "] objectAtIndex:1] : @"";
        q = [path rangeOfString:@"?"];
        if (![path hasPrefix:@"/callback"] || q.location == NSNotFound) {
            const char *no = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            write(client, no, strlen(no));
            close(client);
            continue;
        }
        {
            const char *page = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n"
                "<html><body style=\"font-family:Helvetica;margin:3em\"><h2>Signed in</h2><p>You can close this tab and go back to Tiger Build.</p></body></html>";
            write(client, page, strlen(page));
            close(client);
        }
        {
            NSMutableDictionary *out = [NSMutableDictionary dictionary];
            NSArray *pairs = [[path substringFromIndex:q.location + 1] componentsSeparatedByString:@"&"];
            unsigned i;
            for (i = 0; i < [pairs count]; i++) {
                NSArray *kv = [[pairs objectAtIndex:i] componentsSeparatedByString:@"="];
                NSString *v = [kv count] > 1 ? [[[[kv objectAtIndex:1] componentsSeparatedByString:@"+"] componentsJoinedByString:@" "] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] : @"";
                if ([kv count] && v)
                    [out setObject:v forKey:[kv objectAtIndex:0]];
            }
            return out;
        }
    }
}

+ (void)askOnMain:(NSMutableDictionary *)job
{
    NSString *name = [job objectForKey:@"host"];
    int choice;
    [NSApp activateIgnoringOtherApps:YES];
    choice = NSRunAlertPanel([NSString stringWithFormat:@"Sign in to %@?", name],
        @"This tool server asks you to sign in. Tiger Build will open your web browser at %@'s sign-in page; when you are done, the browser comes back here. "
        @"Tiger Build keeps the access it is given in the Keychain.", @"Open Browser", @"Cancel", nil, name);
    [job setObject:[NSNumber numberWithBool:choice == NSAlertDefaultReturn] forKey:@"yes"];
}

+ (void)openOnMain:(NSString *)url
{
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:url]];
}

+ (BOOL)authorizeServer:(NSString *)serverURL challenge:(NSString *)challenge error:(NSString **)error
{
    NSString *why = nil, *origin = originOf(serverURL), *metaURL, *asBase = nil, *scope = nil;
    NSDictionary *resource = nil, *meta = nil, *registration = nil, *tokens = nil, *redirectInfo;
    NSString *authEndpoint, *tokenEndpoint, *regEndpoint, *verifier, *challengeCode, *state, *redirect, *authURL, *clientId;
    unsigned char digest[32];
    int fd = -1;
    struct sockaddr_in addr;
    socklen_t len = sizeof addr;
    int port;
    NSMutableDictionary *job;
    NSMutableString *form;
    *error = nil;
    if (!origin) {
        *error = @"The server address is not valid.";
        return NO;
    }
    /* 1. where is the authorization server? (RFC 9728, then the older habit of the server being its own) */
    metaURL = headerParam(challenge, @"resource_metadata");
    if (![metaURL length])
        metaURL = [origin stringByAppendingString:@"/.well-known/oauth-protected-resource"];
    if (endpointOK(metaURL, serverURL)) {
        resource = call(@"GET", metaURL, nil, nil, &why);
        if ([[resource objectForKey:@"authorization_servers"] isKindOfClass:[NSArray class]] && [[resource objectForKey:@"authorization_servers"] count])
            asBase = [[resource objectForKey:@"authorization_servers"] objectAtIndex:0];
        if ([[resource objectForKey:@"scopes_supported"] isKindOfClass:[NSArray class]] && [[resource objectForKey:@"scopes_supported"] count])
            scope = [[resource objectForKey:@"scopes_supported"] componentsJoinedByString:@" "];
    }
    if (![asBase isKindOfClass:[NSString class]] || ![asBase length])
        asBase = origin;
    while ([asBase hasSuffix:@"/"])
        asBase = [asBase substringToIndex:[asBase length] - 1];
    if (!endpointOK(asBase, serverURL)) {
        *error = @"The server's sign-in address is not a secure (https) address.";
        return NO;
    }
    /* 2. its endpoints */
    meta = call(@"GET", [asBase stringByAppendingString:@"/.well-known/oauth-authorization-server"], nil, nil, &why);
    if (!meta)
        meta = call(@"GET", [asBase stringByAppendingString:@"/.well-known/openid-configuration"], nil, nil, &why);
    if (!meta) {
        *error = [NSString stringWithFormat:@"The sign-in service could not be found (%@).", why];
        return NO;
    }
    authEndpoint = TBString(meta, @"authorization_endpoint");
    tokenEndpoint = TBString(meta, @"token_endpoint");
    regEndpoint = TBString(meta, @"registration_endpoint");
    if (![authEndpoint length] || ![tokenEndpoint length] || !endpointOK(authEndpoint, serverURL) || !endpointOK(tokenEndpoint, serverURL)) {
        *error = @"The sign-in service did not give usable addresses.";
        return NO;
    }
    if (![regEndpoint length] || !endpointOK(regEndpoint, serverURL)) {
        *error = @"This server's sign-in does not allow programs to register themselves, and Tiger Build has no client id for it.";
        return NO;
    }
    /* 3. ask the person */
    if (testMode()) {
        /* no dialog */
    } else {
        job = [NSMutableDictionary dictionaryWithObject:[[NSURL URLWithString:serverURL] host] forKey:@"host"];
        [self performSelectorOnMainThread:@selector(askOnMain:) withObject:job waitUntilDone:YES];
        if (![[job objectForKey:@"yes"] boolValue]) {
            *error = @"cancelled";
            return NO;
        }
    }
    /* 4. a port on this Mac for the browser to come back to */
    fd = socket(AF_INET, SOCK_STREAM, 0);
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0;
    if (fd < 0 || bind(fd, (struct sockaddr *)&addr, sizeof addr) != 0 || listen(fd, 4) != 0 || getsockname(fd, (struct sockaddr *)&addr, &len) != 0) {
        if (fd >= 0) close(fd);
        *error = @"A port to receive the sign-in could not be opened.";
        return NO;
    }
    port = ntohs(addr.sin_port);
    redirect = [NSString stringWithFormat:@"http://127.0.0.1:%d/callback", port];
    /* 5. register this program (RFC 7591) */
    registration = call(@"POST", regEndpoint, @"application/json", TBJSONData([NSDictionary dictionaryWithObjectsAndKeys:@"Tiger Build", @"client_name",
        [NSArray arrayWithObject:redirect], @"redirect_uris", [NSArray arrayWithObjects:@"authorization_code", @"refresh_token", nil], @"grant_types",
        [NSArray arrayWithObject:@"code"], @"response_types", @"none", @"token_endpoint_auth_method", nil]), &why);
    clientId = TBString(registration, @"client_id");
    if (![clientId length]) {
        close(fd);
        *error = [NSString stringWithFormat:@"Tiger Build could not register with the sign-in service (%@).", why ? why : @"no client id"];
        return NO;
    }
    /* 6. the browser */
    verifier = randomToken(48);
    mbedtls_sha256((const unsigned char *)[verifier UTF8String], [verifier length], digest, 0);
    challengeCode = base64url(digest, 32);
    state = randomToken(24);
    authURL = [NSString stringWithFormat:@"%@%@response_type=code&client_id=%@&redirect_uri=%@&code_challenge=%@&code_challenge_method=S256&state=%@&resource=%@",
        authEndpoint, [authEndpoint rangeOfString:@"?"].location == NSNotFound ? @"?" : @"&", encode(clientId), encode(redirect), challengeCode, state, encode(serverURL)];
    if ([scope length])
        authURL = [authURL stringByAppendingFormat:@"&scope=%@", encode(scope)];
    if (testMode())
        printf("OAUTH-URL: %s\n", [authURL UTF8String]), fflush(stdout);
    else
        [self performSelectorOnMainThread:@selector(openOnMain:) withObject:authURL waitUntilDone:NO];
    redirectInfo = [self waitForRedirectOnSocket:fd seconds:300];
    close(fd);
    if (!redirectInfo) {
        *error = @"Nothing came back from the sign-in page in five minutes.";
        return NO;
    }
    if ([[redirectInfo objectForKey:@"error"] length]) {
        *error = [NSString stringWithFormat:@"The sign-in was refused: %@", [redirectInfo objectForKey:@"error"]];
        return NO;
    }
    if (![[redirectInfo objectForKey:@"state"] isEqualToString:state] || ![[redirectInfo objectForKey:@"code"] length]) {
        *error = @"The sign-in answer did not match this request.";
        return NO;
    }
    /* 7. the token */
    form = [NSMutableString stringWithFormat:@"grant_type=authorization_code&code=%@&redirect_uri=%@&client_id=%@&code_verifier=%@&resource=%@",
        encode([redirectInfo objectForKey:@"code"]), encode(redirect), encode(clientId), verifier, encode(serverURL)];
    tokens = call(@"POST", tokenEndpoint, @"application/x-www-form-urlencoded", [form dataUsingEncoding:NSUTF8StringEncoding], &why);
    if (![TBString(tokens, @"access_token") length]) {
        *error = [NSString stringWithFormat:@"The sign-in service did not give an access token (%@).", why ? why : @"no token"];
        return NO;
    }
    {
        double life = [[tokens objectForKey:@"expires_in"] doubleValue];
        NSDictionary *entry = [NSDictionary dictionaryWithObjectsAndKeys:TBString(tokens, @"access_token"), @"access", TBString(tokens, @"refresh_token"), @"refresh",
            [NSNumber numberWithDouble:life > 0 ? [[NSDate date] timeIntervalSince1970] + life : 0], @"expires", clientId, @"client_id", tokenEndpoint, @"token_endpoint",
            serverURL, @"resource", nil];
        @synchronized(self) {
            NSMutableDictionary *all = loadAll();
            [all setObject:entry forKey:serverURL];
            saveAll(all);
        }
    }
    return YES;
}

@end
