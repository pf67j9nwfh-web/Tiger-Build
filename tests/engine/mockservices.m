/* A stand-in for the model services: the same streaming formats, canned replies. Used by the engine tests.
     mockservices PORT
   Paths: /openai /openai-retry /anthropic /anthropic-cache /gemini /responses /local/v1/chat/completions /mcp /mcp-sse and more below. */
#import <Foundation/Foundation.h>
#import "TBJSON.h"
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>
#include <pthread.h>
#include <CommonCrypto/CommonDigest.h>

static NSMutableArray *seen;
static NSMutableDictionary *attempts;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

#define D(...) [NSDictionary dictionaryWithObjectsAndKeys:__VA_ARGS__, nil]
#define A(...) [NSArray arrayWithObjects:__VA_ARGS__, nil]
#define N(x) [NSNumber numberWithInt:x]
#define Y [NSNumber numberWithBool:YES]

static void sendAll(int fd, NSData *data)
{
    const char *p = [data bytes];
    unsigned left = [data length];
    while (left) {
        ssize_t n = write(fd, p, left);
        if (n <= 0)
            return;
        p += n;
        left -= n;
    }
}

static void sendText(int fd, NSString *text) { sendAll(fd, [text dataUsingEncoding:NSUTF8StringEncoding]); }

static NSData *sse(NSArray *items)
{
    NSMutableString *out = [NSMutableString string];
    unsigned i;
    for (i = 0; i < [items count]; i++) {
        NSArray *pair = [items objectAtIndex:i];
        id kind = [pair objectAtIndex:0], data = [pair objectAtIndex:1];
        if ([kind isKindOfClass:[NSString class]])
            [out appendFormat:@"event: %@\n", kind];
        [out appendFormat:@"data: %@\n\n", [data isKindOfClass:[NSString class]] ? data : TBJSONString(data)];
    }
    return [out dataUsingEncoding:NSUTF8StringEncoding];
}

static NSArray *E(id kind, id data) { return A(kind ? kind : [NSNull null], data); }

static void sendChunked(int fd, int status, NSData *body)
{
    unsigned i;
    sendText(fd, [NSString stringWithFormat:@"HTTP/1.1 %d OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n", status]);
    /* small pieces, split mid-line, so the reader has to reassemble them */
    for (i = 0; i < [body length]; i += 37) {
        unsigned n = MIN(37, [body length] - i);
        sendText(fd, [NSString stringWithFormat:@"%x\r\n", n]);
        sendAll(fd, [body subdataWithRange:NSMakeRange(i, n)]);
        sendText(fd, @"\r\n");
    }
    sendText(fd, @"0\r\n\r\n");
}

static void sendBody(int fd, int status, NSString *type, NSData *body, NSString *extra)
{
    sendText(fd, [NSString stringWithFormat:@"HTTP/1.1 %d OK\r\nContent-Type: %@\r\n%@Content-Length: %u\r\nConnection: close\r\n\r\n", status, type, extra ? extra : @"", (unsigned)[body length]]);
    sendAll(fd, body);
}

static void sendJSON(int fd, int status, id object) { sendBody(fd, status, @"application/json", TBJSONData(object), nil); }

static NSArray *openaiChunks(BOOL tools)
{
    NSMutableArray *c = [NSMutableArray arrayWithObjects:
        D(A(D(D(@"Let me think. ", @"reasoning_content"), @"delta")), @"choices"),
        D(A(D(D(@"Hel", @"content"), @"delta")), @"choices"),
        D(A(D(D(@"lo <think>hidden", @"content"), @"delta")), @"choices"),
        D(A(D(D(@" more</think> there", @"content"), @"delta")), @"choices"), nil];
    NSMutableArray *out = [NSMutableArray array];
    unsigned i;
    if (tools) {
        [c addObject:D(A(D(D(A(D(N(0), @"index", @"call_1", @"id", D(@"start_process", @"name", @"{\"command\":", @"arguments"), @"function")), @"tool_calls"), @"delta")), @"choices")];
        [c addObject:D(A(D(D(A(D(N(0), @"index", D(@"\"ls\"}", @"arguments"), @"function")), @"tool_calls"), @"delta")), @"choices")];
    }
    [c addObject:D(A(D([NSDictionary dictionary], @"delta", tools ? @"tool_calls" : @"stop", @"finish_reason")), @"choices")];
    [c addObject:D([NSArray array], @"choices", D(N(100), @"prompt_tokens", N(20), @"completion_tokens", D(N(40), @"cached_tokens"), @"prompt_tokens_details"), @"usage")];
    for (i = 0; i < [c count]; i++)
        [out addObject:E(nil, [c objectAtIndex:i])];
    [out addObject:E(nil, @"[DONE]")];
    return out;
}


static NSArray *anthropicEvents(BOOL tools, BOOL thinking)
{
    NSMutableArray *e = [NSMutableArray array];
    int index = 0;
    [e addObject:E(@"message_start", D(@"message_start", @"type", D(D(N(50), @"input_tokens", N(10), @"cache_read_input_tokens", N(5), @"cache_creation_input_tokens", N(1), @"output_tokens"), @"usage"), @"message"))];
    if (thinking) {
        [e addObject:E(@"content_block_start", D(@"content_block_start", @"type", N(0), @"index", D(@"thinking", @"type", @"", @"thinking"), @"content_block"))];
        [e addObject:E(@"content_block_delta", D(@"content_block_delta", @"type", N(0), @"index", D(@"thinking_delta", @"type", @"Considering.", @"thinking"), @"delta"))];
        [e addObject:E(@"content_block_delta", D(@"content_block_delta", @"type", N(0), @"index", D(@"signature_delta", @"type", @"SIG", @"signature"), @"delta"))];
        [e addObject:E(@"content_block_stop", D(@"content_block_stop", @"type", N(0), @"index"))];
        index = 1;
    }
    [e addObject:E(@"content_block_start", D(@"content_block_start", @"type", N(index), @"index", D(@"text", @"type", @"", @"text"), @"content_block"))];
    [e addObject:E(@"content_block_delta", D(@"content_block_delta", @"type", N(index), @"index", D(@"text_delta", @"type", @"Hi ", @"text"), @"delta"))];
    [e addObject:E(@"content_block_delta", D(@"content_block_delta", @"type", N(index), @"index", D(@"text_delta", @"type", @"there", @"text"), @"delta"))];
    [e addObject:E(@"content_block_stop", D(@"content_block_stop", @"type", N(index), @"index"))];
    index++;
    if (tools) {
        [e addObject:E(@"content_block_start", D(@"content_block_start", @"type", N(index), @"index", D(@"tool_use", @"type", @"toolu_1", @"id", @"start_process", @"name", [NSDictionary dictionary], @"input"), @"content_block"))];
        [e addObject:E(@"content_block_delta", D(@"content_block_delta", @"type", N(index), @"index", D(@"input_json_delta", @"type", @"{\"command\":", @"partial_json"), @"delta"))];
        [e addObject:E(@"content_block_delta", D(@"content_block_delta", @"type", N(index), @"index", D(@"input_json_delta", @"type", @"\"ls\"}", @"partial_json"), @"delta"))];
        [e addObject:E(@"content_block_stop", D(@"content_block_stop", @"type", N(index), @"index"))];
    }
    [e addObject:E(@"message_delta", D(@"message_delta", @"type", D(tools ? @"tool_use" : @"end_turn", @"stop_reason"), @"delta", D(N(33), @"output_tokens"), @"usage"))];
    [e addObject:E(@"message_stop", D(@"message_stop", @"type"))];
    return e;
}



/* ---- the older HTTP+SSE transport: GET /legacy/sse holds a stream open; messages POSTed to /legacy/messages?sid=N are answered on it ---- */
static NSMutableDictionary *legacyQueues;   /* sid -> NSMutableArray of JSON strings */
static int legacyNext = 1;

static NSDictionary *mcpResult(NSDictionary *request, NSDictionary *headers)
{
    NSString *m = [request objectForKey:@"method"];
    id result;
    if ([m isEqualToString:@"initialize"])
        result = D(@"2025-06-18", @"protocolVersion", [NSDictionary dictionaryWithObject:[NSDictionary dictionary] forKey:@"tools"], @"capabilities", D(@"mock", @"name", @"1", @"version"), @"serverInfo");
    else if ([m isEqualToString:@"tools/list"])
        result = D(A(D(@"echo", @"name", @"Echo text", @"description", D(@"object", @"type", D(D(@"string", @"type"), @"text"), @"properties", A(@"text"), @"required"), @"inputSchema")), @"tools");
    else if ([m isEqualToString:@"tools/call"]) {
        NSString *text = [[[request objectForKey:@"params"] objectForKey:@"arguments"] objectForKey:@"text"];
        result = D(A(D(@"text", @"type", [NSString stringWithFormat:@"echo: %@ auth=%@", text ? text : @"", [headers objectForKey:@"authorization"] ? [headers objectForKey:@"authorization"] : @"none"], @"text")), @"content");
    } else
        result = [NSDictionary dictionary];
    return D(@"2.0", @"jsonrpc", [request objectForKey:@"id"], @"id", result, @"result");
}

static void legacyStream(int fd, NSDictionary *headers)
{
    int sid;
    pthread_mutex_lock(&lock);
    sid = legacyNext++;
    if (!legacyQueues)
        legacyQueues = [[NSMutableDictionary alloc] init];
    [legacyQueues setObject:[NSMutableArray array] forKey:N(sid)];
    pthread_mutex_unlock(&lock);
    if ([[headers objectForKey:@"x-need-token"] length]) {}
    sendText(fd, @"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n");
    sendText(fd, [NSString stringWithFormat:@"event: endpoint\ndata: /legacy/messages?sid=%d\n\n", sid]);
    for (int tick = 0; tick < 600; tick++) {
        NSString *next = nil;
        pthread_mutex_lock(&lock);
        NSMutableArray *q = [legacyQueues objectForKey:N(sid)];
        if ([q count]) {
            next = [[[q objectAtIndex:0] retain] autorelease];
            [q removeObjectAtIndex:0];
        }
        pthread_mutex_unlock(&lock);
        if (next)
            sendText(fd, [NSString stringWithFormat:@"event: message\ndata: %@\n\n", next]);
        else
            usleep(30000);
    }
}

/* ---- OAuth: discovery, registration, authorization (a redirect), tokens that last two seconds, and a protected MCP endpoint ---- */
static NSMutableDictionary *oauthCodes, *oauthTokens, *oauthRefresh, *oauthClients;

static NSString *queryValue(NSString *path, NSString *key)
{
    NSRange q = [path rangeOfString:@"?"];
    NSArray *pairs;
    unsigned i;
    if (q.location == NSNotFound)
        return nil;
    pairs = [[path substringFromIndex:q.location + 1] componentsSeparatedByString:@"&"];
    for (i = 0; i < [pairs count]; i++) {
        NSArray *kv = [[pairs objectAtIndex:i] componentsSeparatedByString:@"="];
        if ([kv count] == 2 && [[kv objectAtIndex:0] isEqualToString:key])
            return [[[kv objectAtIndex:1] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] stringByReplacingOccurrencesOfString:@"+" withString:@" "];
    }
    return nil;
}

static NSString *base64url(NSData *d)
{
    NSMutableString *out = [NSMutableString string];
    const unsigned char *b = [d bytes];
    static const char *t = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    unsigned i, n = [d length];
    for (i = 0; i < n; i += 3) {
        unsigned v = b[i] << 16 | (i + 1 < n ? b[i + 1] << 8 : 0) | (i + 2 < n ? b[i + 2] : 0);
        [out appendFormat:@"%c%c", t[(v >> 18) & 63], t[(v >> 12) & 63]];
        if (i + 1 < n) [out appendFormat:@"%c", t[(v >> 6) & 63]];
        if (i + 2 < n) [out appendFormat:@"%c", t[v & 63]];
    }
    return out;
}

/* NO when the request was not an OAuth one */
static BOOL oauthHandle(int fd, NSString *method, NSString *path, NSDictionary *headers, NSData *raw)
{
    NSString *host = [headers objectForKey:@"host"], *me = [@"http://" stringByAppendingString:host ? host : @"127.0.0.1"];
    NSString *bare = [[path componentsSeparatedByString:@"?"] objectAtIndex:0];
    pthread_mutex_lock(&lock);
    if (!oauthCodes) {
        oauthCodes = [[NSMutableDictionary alloc] init];
        oauthTokens = [[NSMutableDictionary alloc] init];
        oauthRefresh = [[NSMutableDictionary alloc] init];
        oauthClients = [[NSMutableDictionary alloc] init];
    }
    pthread_mutex_unlock(&lock);
    if ([bare isEqualToString:@"/.well-known/oauth-protected-resource"]) {
        sendJSON(fd, 200, D([me stringByAppendingString:@"/oauth/mcp"], @"resource", A(me), @"authorization_servers"));
        return YES;
    }
    if ([bare isEqualToString:@"/.well-known/oauth-authorization-server"]) {
        sendJSON(fd, 200, D(me, @"issuer", [me stringByAppendingString:@"/oauth/authorize"], @"authorization_endpoint", [me stringByAppendingString:@"/oauth/token"], @"token_endpoint",
            [me stringByAppendingString:@"/oauth/register"], @"registration_endpoint", A(@"S256"), @"code_challenge_methods_supported"));
        return YES;
    }
    if ([bare isEqualToString:@"/oauth/register"]) {
        id d = TBJSONParse(raw, NULL);
        NSString *cid;
        pthread_mutex_lock(&lock);
        cid = [NSString stringWithFormat:@"client%u", (unsigned)[oauthClients count]];
        [oauthClients setObject:[d objectForKey:@"redirect_uris"] forKey:cid];
        pthread_mutex_unlock(&lock);
        sendJSON(fd, 201, D(cid, @"client_id"));
        return YES;
    }
    if ([bare isEqualToString:@"/oauth/authorize"]) {
        NSString *cid = queryValue(path, @"client_id"), *redirect = queryValue(path, @"redirect_uri"), *code;
        BOOL ok;
        pthread_mutex_lock(&lock);
        ok = cid && redirect && [[oauthClients objectForKey:cid] containsObject:redirect] && [queryValue(path, @"code_challenge_method") isEqualToString:@"S256"];
        code = [NSString stringWithFormat:@"code%u", (unsigned)[oauthCodes count]];
        if (ok)
            [oauthCodes setObject:D(queryValue(path, @"code_challenge"), @"challenge", redirect, @"redirect", queryValue(path, @"resource"), @"resource") forKey:code];
        pthread_mutex_unlock(&lock);
        if (!ok) {
            sendJSON(fd, 400, D(@"unknown client or redirect", @"error"));
            return YES;
        }
        sendText(fd, [NSString stringWithFormat:@"HTTP/1.1 302 Found\r\nLocation: %@?code=%@&state=%@\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", redirect, code, queryValue(path, @"state")]);
        return YES;
    }
    if ([bare isEqualToString:@"/oauth/token"]) {
        NSString *body = [[[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding] autorelease], *grant = queryValue([@"?" stringByAppendingString:body], @"grant_type");
        BOOL ok = NO;
        NSString *at, *rt;
        pthread_mutex_lock(&lock);
        if ([grant isEqualToString:@"authorization_code"]) {
            NSDictionary *entry = [oauthCodes objectForKey:queryValue([@"?" stringByAppendingString:body], @"code")];
            NSData *verifier = [queryValue([@"?" stringByAppendingString:body], @"code_verifier") dataUsingEncoding:NSUTF8StringEncoding];
            unsigned char sum[32];
            if (entry && verifier) {
                CC_SHA256([verifier bytes], (CC_LONG)[verifier length], sum);
                ok = [base64url([NSData dataWithBytes:sum length:32]) isEqualToString:[entry objectForKey:@"challenge"]]
                    && [[entry objectForKey:@"redirect"] isEqualToString:queryValue([@"?" stringByAppendingString:body], @"redirect_uri")];
            }
        } else if ([grant isEqualToString:@"refresh_token"])
            ok = [oauthRefresh objectForKey:queryValue([@"?" stringByAppendingString:body], @"refresh_token")] != nil;
        at = [NSString stringWithFormat:@"at%u", (unsigned)[oauthTokens count]];
        rt = [NSString stringWithFormat:@"rt%u", (unsigned)[oauthRefresh count]];
        if (ok) {
            [oauthTokens setObject:[NSNumber numberWithDouble:[[NSDate date] timeIntervalSince1970] + 2] forKey:at];
            [oauthRefresh setObject:Y forKey:rt];
        }
        pthread_mutex_unlock(&lock);
        if (ok)
            sendJSON(fd, 200, D(at, @"access_token", rt, @"refresh_token", N(2), @"expires_in", @"Bearer", @"token_type"));
        else
            sendJSON(fd, 400, D(@"invalid_grant", @"error", @"pkce or redirect mismatch", @"error_description"));
        return YES;
    }
    if ([bare isEqualToString:@"/oauth/mcp"] && [method isEqualToString:@"POST"]) {
        NSString *auth = [headers objectForKey:@"authorization"];
        BOOL good = NO;
        id request;
        if ([auth hasPrefix:@"Bearer "]) {
            pthread_mutex_lock(&lock);
            good = [[oauthTokens objectForKey:[auth substringFromIndex:7]] doubleValue] > [[NSDate date] timeIntervalSince1970];
            pthread_mutex_unlock(&lock);
        }
        if (!good) {
            sendText(fd, [NSString stringWithFormat:@"HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Bearer resource_metadata=\"%@/.well-known/oauth-protected-resource\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", me]);
            return YES;
        }
        request = TBJSONParse(raw, NULL);
        if (![request objectForKey:@"id"]) {
            sendText(fd, @"HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            return YES;
        }
        sendJSON(fd, 200, mcpResult(request, headers));
        return YES;
    }
    return NO;
}

static void handle(int fd, NSString *method, NSString *fullPath, NSDictionary *headers, NSData *raw)
{
    NSString *path = [[fullPath componentsSeparatedByString:@"?"] objectAtIndex:0];
    id request = nil;
    int count;
    BOOL tools;
    if ([method isEqualToString:@"GET"]) {
        if ([path isEqualToString:@"/seen"]) {
            pthread_mutex_lock(&lock);
            NSData *body = TBJSONData(seen);
            pthread_mutex_unlock(&lock);
            sendBody(fd, 200, @"application/json", body, nil);
        } else if ([path isEqualToString:@"/legacy/sse"]) {
            legacyStream(fd, headers);
        } else if (oauthHandle(fd, method, fullPath, headers, raw)) {
        } else if ([path isEqualToString:@"/reset"]) {
            pthread_mutex_lock(&lock);
            [seen removeAllObjects];
            [attempts removeAllObjects];
            pthread_mutex_unlock(&lock);
            sendJSON(fd, 200, [NSDictionary dictionary]);
        } else
            sendJSON(fd, 404, D(@"not found", @"error"));
        return;
    }
    if (oauthHandle(fd, method, fullPath, headers, raw))
        return;
    if ([path isEqualToString:@"/legacy/messages"]) {
        id message = TBJSONParse(raw, NULL);
        NSString *sidText = queryValue(fullPath, @"sid");
        pthread_mutex_lock(&lock);
        if ([message isKindOfClass:[NSDictionary class]] && [message objectForKey:@"id"])
            [[legacyQueues objectForKey:N([sidText intValue])] addObject:TBJSONString(mcpResult(message, headers))];
        pthread_mutex_unlock(&lock);
        sendText(fd, @"HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    }
    if ([path isEqualToString:@"/legacy-only/mcp"]) {   /* a server that has only the older transport: POST to the stream's address answers 405 */
        sendText(fd, @"HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        return;
    }
    request = [raw length] ? TBJSONParse(raw, NULL) : [NSDictionary dictionary];
    if (![request isKindOfClass:[NSDictionary class]]) {
        NSString *text = [[[NSString alloc] initWithData:raw encoding:NSISOLatin1StringEncoding] autorelease];
        request = D([text length] > 400 ? [text substringToIndex:400] : text, @"multipart");
    }
    pthread_mutex_lock(&lock);
    [seen addObject:D(path, @"path", headers, @"headers", request, @"body")];
    count = [[attempts objectForKey:path] intValue] + 1;
    [attempts setObject:N(count) forKey:path];
    pthread_mutex_unlock(&lock);
    tools = [[request objectForKey:@"tools"] count] > 0;
    if ([path isEqualToString:@"/mcp"] || [path isEqualToString:@"/mcp-sse"]) {
        NSString *m = [request objectForKey:@"method"];
        id ident = [request objectForKey:@"id"], result;
        NSString *message;
        if (!ident) {
            sendText(fd, @"HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            return;
        }
        if ([m isEqualToString:@"initialize"])
            result = D(@"2025-06-18", @"protocolVersion", [NSDictionary dictionaryWithObject:[NSDictionary dictionary] forKey:@"tools"], @"capabilities", D(@"mock", @"name", @"1", @"version"), @"serverInfo");
        else if ([m isEqualToString:@"tools/list"])
            result = D(A(D(@"echo", @"name", @"Echo text", @"description", D(@"object", @"type", D(D(@"string", @"type"), @"text"), @"properties", A(@"text"), @"required"), @"inputSchema")), @"tools");
        else if ([m isEqualToString:@"tools/call"]) {
            NSString *text = [[[request objectForKey:@"params"] objectForKey:@"arguments"] objectForKey:@"text"];
            result = D(A(D(@"text", @"type", [NSString stringWithFormat:@"echo: %@ token=%@ session=%@", text ? text : @"", [headers objectForKey:@"authorization"] ? [headers objectForKey:@"authorization"] : @"none",
                [headers objectForKey:@"mcp-session-id"] ? [headers objectForKey:@"mcp-session-id"] : @"none"], @"text")), @"content");
        } else
            result = [NSDictionary dictionary];
        message = TBJSONString(D(@"2.0", @"jsonrpc", ident, @"id", result, @"result"));
        if ([path isEqualToString:@"/mcp-sse"])
            sendBody(fd, 200, @"text/event-stream", [[NSString stringWithFormat:@"event: message\ndata: %@\n\n", message] dataUsingEncoding:NSUTF8StringEncoding], @"Mcp-Session-Id: sess-1\r\n");
        else
            sendBody(fd, 200, @"application/json", [message dataUsingEncoding:NSUTF8StringEncoding], @"Mcp-Session-Id: sess-1\r\n");
        return;
    }
    if ([path isEqualToString:@"/audio-openai"]) {
        if ([[request objectForKey:@"multipart"] rangeOfString:@"gpt-4o-mini-transcribe"].location != NSNotFound && count == 1)
            sendJSON(fd, 404, D(D(@"model not found", @"message"), @"error"));
        else
            sendJSON(fd, 200, D(@" hello from the mock ", @"text"));
    } else if ([path isEqualToString:@"/audio-gemini"])
        sendJSON(fd, 200, D(A(D(D(A(D(@"gemini words", @"text")), @"parts"), @"content")), @"candidates"));
    else if ([path isEqualToString:@"/openai"] || [path isEqualToString:@"/local/v1/chat/completions"])
        sendChunked(fd, 200, sse(openaiChunks(tools)));
    else if ([path isEqualToString:@"/openai-retry"]) {
        if (count == 1)
            sendJSON(fd, 400, D(D(@"Unknown parameter: stream_options", @"message"), @"error"));
        else
            sendChunked(fd, 200, sse(openaiChunks(NO)));
    } else if ([path isEqualToString:@"/slow"]) {
        NSData *first = sse(A(E(nil, D(A(D(D(@"start", @"content"), @"delta")), @"choices"))));
        sendText(fd, @"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n");
        sendText(fd, [NSString stringWithFormat:@"%x\r\n", (unsigned)[first length]]);
        sendAll(fd, first);
        sendText(fd, @"\r\n");
        sleep(8);
    } else if ([path isEqualToString:@"/loop-claude"] || [path isEqualToString:@"/loop-openai"]) {
        /* the first request asks for a tool; once a tool result is in the conversation, answer */
        NSString *text = TBJSONString(request);
        BOOL answered = [text rangeOfString:@"tool_result"].location != NSNotFound || [text rangeOfString:@"\"role\":\"tool\""].location != NSNotFound;
        if ([path isEqualToString:@"/loop-claude"])
            sendChunked(fd, 200, sse(anthropicEvents(!answered, NO)));
        else
            sendChunked(fd, 200, sse(openaiChunks(!answered)));
    } else if ([path isEqualToString:@"/grok"]) {
        NSArray *items;
        if ([request objectForKey:@"previous_response_id"])
            items = A(E(@"response.output_text.delta", D(@"response.output_text.delta", @"type", @"Grok done", @"delta")),
                E(@"response.completed", D(@"response.completed", @"type", D(@"r2", @"id", [NSArray array], @"output", D(N(40), @"input_tokens", N(4), @"output_tokens"), @"usage"), @"response")));
        else
            items = A(E(@"response.output_text.delta", D(@"response.output_text.delta", @"type", @"Checking. ", @"delta")),
                E(@"response.completed", D(@"response.completed", @"type", D(@"r1", @"id", A(D(@"function_call", @"type", @"fc_9", @"call_id", @"start_process", @"name", @"{\"command\":\"ls\"}", @"arguments")), @"output",
                    D(N(30), @"input_tokens", N(3), @"output_tokens"), @"usage"), @"response")));
        sendChunked(fd, 200, sse(items));
    } else if ([path isEqualToString:@"/gemini-search"])
        sendJSON(fd, 200, D(A(D(D(A(D(@"Canberra is the capital.", @"text")), @"parts"), @"content", D(A(D(D(@"Australia - Wikipedia", @"title", @"https://en.wikipedia.org/wiki/Australia", @"uri"), @"web")), @"groundingChunks"), @"groundingMetadata")), @"candidates"));
    else if ([path isEqualToString:@"/openai-down"])
        sendJSON(fd, 429, D(D(@"Rate limit reached", @"message"), @"error"));
    else if ([path isEqualToString:@"/anthropic"])
        sendChunked(fd, 200, sse(anthropicEvents(tools, [request objectForKey:@"thinking"] != nil)));
    else if ([path isEqualToString:@"/anthropic-cache"]) {
        if (count == 1)
            sendJSON(fd, 400, D(D(@"cache_control is not supported on this model", @"message"), @"error"));
        else
            sendChunked(fd, 200, sse(anthropicEvents(NO, NO)));
    } else if ([path isEqualToString:@"/anthropic-limit"]) {
        if (count == 1)
            sendJSON(fd, 400, D(D(@"max_tokens: 64000 > 8192, which is the maximum allowed", @"message"), @"error"));
        else
            sendChunked(fd, 200, sse(anthropicEvents(NO, NO)));
    } else if ([path hasPrefix:@"/gemini"]) {
        NSMutableArray *parts = [NSMutableArray arrayWithObjects:D(Y, @"thought", @"Pondering.", @"text"), D(@"Gem", @"text"), D(@"ini says hi", @"text"), nil];
        if (tools)
            [parts addObject:D(D(@"start_process", @"name", D(@"ls", @"command"), @"args"), @"functionCall", @"GSIG", @"thoughtSignature")];
        sendChunked(fd, 200, sse(A(E(nil, D(A(D(D(parts, @"parts"), @"content", @"STOP", @"finishReason")), @"candidates",
            D(N(70), @"promptTokenCount", N(20), @"cachedContentTokenCount", N(5), @"candidatesTokenCount", N(3), @"thoughtsTokenCount"), @"usageMetadata")))));
    } else if ([path isEqualToString:@"/responses"]) {
        NSMutableArray *output = [NSMutableArray array];
        if (tools)
            [output addObject:D(@"function_call", @"type", @"fc_1", @"call_id", @"start_process", @"name", @"{\"command\":\"ls\"}", @"arguments")];
        sendChunked(fd, 200, sse(A(
            E(@"response.reasoning_summary_text.delta", D(@"response.reasoning_summary_text.delta", @"type", @"Summary.", @"delta")),
            E(@"response.output_text.delta", D(@"response.output_text.delta", @"type", @"Resp", @"delta")),
            E(@"response.output_text.delta", D(@"response.output_text.delta", @"type", @"onse", @"delta")),
            E(@"response.completed", D(@"response.completed", @"type", D(@"r1", @"id", output, @"output", D(N(30), @"input_tokens", N(7), @"output_tokens", D(N(10), @"cached_tokens"), @"input_tokens_details"), @"usage"), @"response")))));
    } else
        sendJSON(fd, 404, D(D([@"unknown path " stringByAppendingString:path], @"message"), @"error"));
}

static void *serve(void *arg)
{
    int fd = (int)(long)arg;
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSMutableData *buf = [NSMutableData data];
    char tmp[4096];
    NSRange end = NSMakeRange(NSNotFound, 0);
    for (;;) {
        ssize_t n;
        NSData *crlf = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
        end = [buf rangeOfData:crlf options:0 range:NSMakeRange(0, [buf length])];
        if (end.location != NSNotFound)
            break;
        n = read(fd, tmp, sizeof tmp);
        if (n <= 0)
            goto done;
        [buf appendBytes:tmp length:n];
    }
    {
        NSString *head = [[[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, end.location)] encoding:NSISOLatin1StringEncoding] autorelease];
        NSArray *lines = [head componentsSeparatedByString:@"\r\n"];
        NSArray *first = [[lines objectAtIndex:0] componentsSeparatedByString:@" "];
        NSMutableDictionary *headers = [NSMutableDictionary dictionary];
        unsigned i, length = 0;
        NSMutableData *body;
        for (i = 1; i < [lines count]; i++) {
            NSRange colon = [[lines objectAtIndex:i] rangeOfString:@":"];
            if (colon.location != NSNotFound)
                [headers setObject:[[[lines objectAtIndex:i] substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]
                            forKey:[[[lines objectAtIndex:i] substringToIndex:colon.location] lowercaseString]];
        }
        length = [[headers objectForKey:@"content-length"] intValue];
        body = [NSMutableData dataWithData:[buf subdataWithRange:NSMakeRange(NSMaxRange(end), [buf length] - NSMaxRange(end))]];
        while ([body length] < length) {
            ssize_t n = read(fd, tmp, sizeof tmp);
            if (n <= 0)
                break;
            [body appendBytes:tmp length:n];
        }
        if ([first count] >= 2)
            handle(fd, [first objectAtIndex:0], [first objectAtIndex:1], headers, body);
    }
done:
    close(fd);
    [pool release];
    return NULL;
}

int main(int argc, char **argv)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    struct sockaddr_in a;
    int s = socket(AF_INET, SOCK_STREAM, 0), yes = 1;
    seen = [[NSMutableArray alloc] init];
    attempts = [[NSMutableDictionary alloc] init];
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof yes);
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons(argc > 1 ? atoi(argv[1]) : 8795);
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(s, (struct sockaddr *)&a, sizeof a) != 0 || listen(s, 16) != 0) { perror("mockservices"); return 1; }
    signal(SIGPIPE, SIG_IGN);
    for (;;) {
        int c = accept(s, NULL, NULL);
        pthread_t t;
        if (c < 0)
            continue;
        pthread_create(&t, NULL, serve, (void *)(long)c);
        pthread_detach(t);
    }
    [pool release];
    return 0;
}
