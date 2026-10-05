#import "TBService.h"
#import "TBEngine.h"
#import "TBJSON.h"
#import "TBLocal.h"
#import "TBPricing.h"
#import "TBHTTP.h"
#import "TBExtract.h"
#import "TBSpeech.h"
#import "TBIntegrations.h"
#import "TBOutputs.h"

static NSDictionary *reply(int status, NSData *body, NSString *type)
{
    return [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:status], @"status", body ? body : [NSData data], @"body", type ? type : @"text/plain", @"type", nil];
}

static NSDictionary *textReply(int status, NSString *text)
{
    return reply(status, [text dataUsingEncoding:NSUTF8StringEncoding], @"text/plain; charset=utf-8");
}

static NSString *cleanTitle(NSString *text)
{
    NSArray *lines = [text componentsSeparatedByString:@"\n"];
    NSString *line = @"";
    unsigned i;
    for (i = 0; i < [lines count]; i++) {
        if ([TBTrim([lines objectAtIndex:i]) length]) {
            line = TBTrim([lines objectAtIndex:i]);
            break;
        }
    }
    /* \u escapes in string literals do not work on Tiger: the curly quotes are built from their codes. */
    line = TBTrim([line stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:
        [NSString stringWithFormat:@"\"' %C%C%C%C", (unichar)0x201c, (unichar)0x201d, (unichar)0x2018, (unichar)0x2019]]]);
    if ([line length] > 48)
        line = TBTrim([line substringToIndex:48]);
    return [line length] ? line : @"New Chat";
}

/* The conversation a request carries, checked the way the relay checked it. Raises TBError with a reason for a bad one. */
static NSArray *cleanedMessages(NSDictionary *incoming, BOOL requireUserEnd)
{
    NSArray *messages = TBArray(incoming, @"messages");
    NSMutableArray *cleaned = [NSMutableArray array];
    unsigned i;
    if ([messages count] == 0)
        TBFail(@"messages must be a non-empty list");
    for (i = 0; i < [messages count]; i++) {
        NSDictionary *item = [messages objectAtIndex:i];
        NSString *role, *content;
        NSMutableDictionary *entry;
        if (![item isKindOfClass:[NSDictionary class]])
            TBFail(@"each message must be an object");
        role = TBString(item, @"role");
        content = TBValue(item, @"content") ;
        if (!([role isEqualToString:@"user"] || [role isEqualToString:@"assistant"]) || ![TBValue(item, @"content") isKindOfClass:[NSString class]])
            TBFail(@"messages need role user or assistant and string content");
        if ([TBTrim(content) length] == 0)
            continue;
        entry = [NSMutableDictionary dictionaryWithObjectsAndKeys:role, @"role", content, @"content", nil];
        if ([role isEqualToString:@"user"]) {
            NSArray *images = TBArray(item, @"images");
            NSMutableArray *pictures = [NSMutableArray array];
            unsigned p;
            for (p = 0; p < [images count] && p < 8; p++) {
                NSDictionary *image = [images objectAtIndex:p];
                NSString *mime = TBString(image, @"mime");
                NSString *data = TBString(image, @"data");
                if (([mime isEqualToString:@"image/jpeg"] || [mime isEqualToString:@"image/png"] || [mime isEqualToString:@"image/gif"]) && [data length] > 0 && [data length] <= 8000000)
                    [pictures addObject:[NSDictionary dictionaryWithObjectsAndKeys:mime, @"mime", data, @"data", nil]];
            }
            if ([pictures count])
                [entry setObject:pictures forKey:@"images"];
        }
        [cleaned addObject:entry];
    }
    if ([cleaned count] == 0)
        TBFail(@"messages must be a non-empty list");
    if (requireUserEnd && ![TBString([cleaned lastObject], @"role") isEqualToString:@"user"])
        TBFail(@"the last message must be from the user");
    return cleaned;
}

@implementation TBService

+ (NSString *)version
{
    NSString *v = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return [v length] ? v : @"2.0";
}

/* ---- models ---- */

+ (NSString *)modelsText
{
    NSMutableArray *lines = [NSMutableArray array];
    NSArray *providers = [TBProviders providers];
    unsigned i;
    for (i = 0; i < [providers count]; i++) {
        NSString *pid = TBString([providers objectAtIndex:i], @"id");
        BOOL keyed = [TBSettings hasKeyForProvider:pid];
        NSString *state;
        if ([pid isEqualToString:@"local"])
            state = [[TBProviders localBase] length] ? @"ok" : @"nokey";
        else
            state = keyed ? @"ok" : @"nokey";
        [lines addObject:[NSString stringWithFormat:@"provider\t%@\t%@\t%@", pid, TBString([providers objectAtIndex:i], @"title"), state]];
        if ([pid isEqualToString:@"local"] || !keyed)
            continue;
        {
            NSArray *models = [TBProviders modelsForProvider:pid];
            NSString *standard = [TBProviders defaultModelForProvider:pid];
            unsigned m;
            for (m = 0; m < [models count]; m++) {
                NSDictionary *item = [models objectAtIndex:m];
                [lines addObject:[NSString stringWithFormat:@"model\t%@\t%@\t%@\t%@\t%d", pid, TBString(item, @"id"), TBString(item, @"title"),
                    [TBString(item, @"id") isEqualToString:standard] ? @"1" : @"0", [TBProviders contextLimitForModel:TBString(item, @"id")]]];
            }
        }
    }
    return [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
}

/* ---- settings ---- */

+ (NSString *)settingsText
{
    NSMutableArray *lines = [NSMutableArray array];
    NSString *inUse = [TBProviders localBase];
    NSArray *names = [NSArray arrayWithObjects:@"xai_api_key", @"openai_api_key", @"anthropic_api_key", @"anthropic_workspace_id", @"mistral_api_key", @"muse_api_key",
        @"gemini_api_key", @"local_api_key", nil];
    unsigned i;
    [lines addObject:[@"local_url=" stringByAppendingString:inUse]];
    [lines addObject:[NSString stringWithFormat:@"local_url_set=%@", [inUse length] ? @"1" : @"0"]];
    [lines addObject:[@"local_status=" stringByAppendingString:[TBLocal status]]];
    for (i = 0; i < [names count]; i++)
        [lines addObject:[NSString stringWithFormat:@"%@=%@", [names objectAtIndex:i], [TBSettings hasValueForName:[names objectAtIndex:i]] ? @"1" : @"0"]];
    return [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
}

+ (void)updateSettings:(NSDictionary *)incoming
{
    NSArray *known = [NSArray arrayWithObjects:@"xai_api_key", @"openai_api_key", @"anthropic_api_key", @"anthropic_workspace_id", @"mistral_api_key", @"muse_api_key",
        @"gemini_api_key", @"local_api_key", @"local_url", nil];
    NSArray *clear = TBTruth(incoming, @"clear_all") ? known : TBArray(incoming, @"clear");
    unsigned i;
    if (TBTruth(incoming, @"clear_all")) {
        NSArray *more = [NSArray arrayWithObjects:@"search_api_key", @"tavily_api_key", @"mcp_servers", nil];
        for (i = 0; i < [more count]; i++)
            [TBSettings clearName:[more objectAtIndex:i]];
    }
    for (i = 0; i < [clear count]; i++) {
        if (![known containsObject:[clear objectAtIndex:i]])
            TBFail(@"Unknown setting %@.", [clear objectAtIndex:i]);
        [TBSettings clearName:[clear objectAtIndex:i]];
    }
    for (i = 0; i < [known count]; i++) {
        NSString *name = [known objectAtIndex:i];
        NSString *value = TBValue(incoming, name) && [TBValue(incoming, name) isKindOfClass:[NSString class]] ? TBTrim(TBValue(incoming, name)) : @"";
        if ([value length] == 0)
            continue;
        if ([name isEqualToString:@"local_url"]) {
            NSString *lower = [value lowercaseString];
            if (!([lower hasPrefix:@"http://"] || [lower hasPrefix:@"https://"]))
                TBFail(@"The local model address must start with http:// or https://.");
            if ([value rangeOfString:@" "].location != NSNotFound || [value rangeOfString:@".."].location != NSNotFound)
                TBFail(@"The local model address is not usable.");
        }
        if (![TBSettings setValue:value forName:name])
            TBFail(@"The Keychain refused %@. Unlock the login keychain and try again.", name);
    }
}

/* ---- the tool catalogue ---- */

+ (NSData *)toolsPlist
{
    NSMutableArray *rows = [NSMutableArray array];
    NSString *problem = [TBSession cachedCommanderProblem];
    NSString *error = nil;
    if ([TBSettings flag:@"ppc_enabled"])
        [rows addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"commander", @"id", @"Commander (this Mac)", @"title", [NSNumber numberWithBool:[TBSettings flag:@"ppc_approval"]], @"approval",
            [NSNumber numberWithBool:YES], @"default", nil]];
    if ([TBSettings flag:@"toolbox_enabled"])
        [rows addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"toolbox", @"id", @"Agent toolbox", @"title", [NSNumber numberWithBool:NO], @"approval", [NSNumber numberWithBool:YES], @"default", nil]];
    if ([TBSettings flag:@"search_enabled"])
        [rows addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"search", @"id", @"Web search", @"title", [NSNumber numberWithBool:NO], @"approval", [NSNumber numberWithBool:YES], @"default", nil]];
    if ([TBSettings flag:@"consult_enabled"])
        [rows addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"consult", @"id", @"Ask other models", @"title", [NSNumber numberWithBool:NO], @"approval", [NSNumber numberWithBool:NO], @"default", nil]];
    [rows addObjectsFromArray:[TBIntegrations catalogue]];
    return [NSPropertyListSerialization dataFromPropertyList:[NSDictionary dictionaryWithObjectsAndKeys:rows, @"tools", problem, @"commander_problem", @"", @"commander_code", nil]
                                                      format:NSPropertyListXMLFormat_v1_0 errorDescription:&error];
}

/* ---- the requests ---- */

+ (NSDictionary *)handle:(NSString *)method path:(NSString *)fullPath body:(NSData *)body file:(NSData *)file name:(NSString *)name
{
    NSString *path = fullPath;
    NSString *query = @"";
    NSRange q = [fullPath rangeOfString:@"?"];
    if (q.location != NSNotFound) {
        path = [fullPath substringToIndex:q.location];
        query = [fullPath substringFromIndex:q.location + 1];
    }
    @try {
        if ([path isEqualToString:@"/v1/models"])
            return textReply(200, [self modelsText]);
        if ([path isEqualToString:@"/v1/version"])
            return textReply(200, [[self version] stringByAppendingString:@"\n"]);
        if ([path isEqualToString:@"/v1/settings"]) {
            if ([method isEqualToString:@"POST"]) {
                id incoming = TBJSONParse(body, NULL);
                if (![incoming isKindOfClass:[NSDictionary class]])
                    return textReply(400, @"request was not JSON\n");
                [self updateSettings:incoming];
            }
            return textReply(200, [self settingsText]);
        }
        if ([path isEqualToString:@"/v1/tools"])
            return reply(200, [self toolsPlist], @"application/x-plist");
        if ([path isEqualToString:@"/v1/local-models"])
            return textReply(200, [TBLocal modelsText]);
        if ([path isEqualToString:@"/v1/context"]) {
            NSString *provider = @"grok", *model = @"";
            NSArray *pieces = [query componentsSeparatedByString:@"&"];
            unsigned i;
            int limit;
            for (i = 0; i < [pieces count]; i++) {
                NSString *piece = [pieces objectAtIndex:i];
                NSRange eq = [piece rangeOfString:@"="];
                NSString *value;
                if (eq.location == NSNotFound)
                    continue;
                value = [[piece substringFromIndex:eq.location + 1] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
                if ([piece hasPrefix:@"provider="]) {
                    @try { provider = [TBProviders normalize:value]; } @catch (NSException *e) { provider = @"grok"; }
                } else if ([piece hasPrefix:@"model="]) {
                    model = value ? value : @"";
                }
            }
            limit = [provider isEqualToString:@"local"] ? [TBLocal contextForModel:model] : [TBPricing liveContextForProvider:provider model:model];
            if (!limit)
                limit = [TBProviders contextLimitForModel:model];
            return textReply(200, [NSString stringWithFormat:@"%d\n", limit]);
        }
        if ([path isEqualToString:@"/v1/extract"]) {
            NSDictionary *result;
            NSString *error = nil;
            if (![file length] || [file length] > 80 * 1024 * 1024)
                return textReply(422, @"Files from 1 byte to 80 MB can be converted.\n");
            if (![TBExtract handles:name])
                return textReply(422, @"This kind of file cannot be converted.\n");
            @try {
                result = [TBExtract extractName:name data:file];
            } @catch (NSException *exception) {
                if ([[exception name] isEqualToString:TBExtractError])
                    return textReply(422, [[exception reason] stringByAppendingString:@"\n"]);
                return textReply(500, [NSString stringWithFormat:@"Could not convert the file: %@\n", [exception reason]]);
            }
            return reply(200, [NSPropertyListSerialization dataFromPropertyList:result format:NSPropertyListXMLFormat_v1_0 errorDescription:&error], @"application/x-plist");
        }
        if ([path isEqualToString:@"/v1/transcribe"]) {
            int status = 200;
            NSString *problem = nil;
            NSString *words;
            if ([file length] < 100 || [file length] > 30 * 1024 * 1024)
                return textReply(422, @"Recordings from a moment to about three minutes can be transcribed.\n");
            words = [TBSpeech transcribe:file language:@"" status:&status problem:&problem];
            return words ? textReply(200, words) : textReply(status, [problem stringByAppendingString:@"\n"]);
        }
        if ([path isEqualToString:@"/v1/integrations"] || [path isEqualToString:@"/v1/config-export"] || [path isEqualToString:@"/v1/config-import"]) {
            NSString *error = nil;
            NSDictionary *plist;
            if ([method isEqualToString:@"GET"]) {
                plist = [path isEqualToString:@"/v1/integrations"] ? [TBIntegrations publicConfig] : [TBIntegrations exportConfig];
                return reply(200, [NSPropertyListSerialization dataFromPropertyList:plist format:NSPropertyListXMLFormat_v1_0 errorDescription:&error], @"application/x-plist");
            }
            if ([body length] < 1 || [body length] > 2 * 1024 * 1024)
                return textReply(400, @"Configuration limit is 2 MB.\n");
            plist = [NSPropertyListSerialization propertyListFromData:body mutabilityOption:NSPropertyListImmutable format:NULL errorDescription:&error];
            if (error)
                [error release];
            if (![plist isKindOfClass:[NSDictionary class]])
                return textReply(400, @"Invalid configuration plist.\n");
            if ([path isEqualToString:@"/v1/integrations"])
                [TBIntegrations update:plist];
            else
                [TBIntegrations restore:plist];
            return textReply(200, @"Configuration saved. Imported custom MCP servers stay disabled until enabled.\n");
        }
        if ([path hasPrefix:@"/v1/media/"]) {
            NSString *file = TBSafeMediaName([path substringFromIndex:10]);
            NSData *bytes = file ? [NSData dataWithContentsOfFile:[TBMediaFolder() stringByAppendingPathComponent:file]] : nil;
            NSString *type = @"application/octet-stream";
            if (!bytes)
                return textReply(404, @"not found\n");
            if ([file hasSuffix:@".png"]) type = @"image/png";
            else if ([file hasSuffix:@".gif"]) type = @"image/gif";
            else if ([file hasSuffix:@".mp4"]) type = @"video/mp4";
            else if ([file hasSuffix:@".jpg"] || [file hasSuffix:@".jpeg"]) type = @"image/jpeg";
            return reply(200, bytes, type);
        }
        if ([path isEqualToString:@"/v1/run"]) {
            id incoming = TBJSONParse(body, NULL);
            TBRun *run = [TBRun runForId:TBString(incoming, @"id")];
            NSString *action = TBString(incoming, @"action");
            if (!run)
                return textReply(404, @"That turn is not running.\n");
            if ([action isEqualToString:@"stop"]) {
                [run cancel];
            } else if ([action isEqualToString:@"guide"]) {
                if (![run addGuidance:TBString(incoming, @"text")])
                    return textReply(400, @"Could not take that note.\n");
            } else if ([action isEqualToString:@"approve"]) {
                if (![run answer:TBString(incoming, @"call") decision:[TBString(incoming, @"decision") length] ? TBString(incoming, @"decision") : @"deny"])
                    return textReply(404, @"Nothing is waiting for that answer.\n");
            } else {
                return textReply(400, @"Unknown action.\n");
            }
            return textReply(200, @"ok\n");
        }
        if ([path isEqualToString:@"/v1/title"] || [path isEqualToString:@"/v1/summarize"]) {
            id incoming = TBJSONParse(body, NULL);
            NSArray *messages;
            NSString *provider, *system, *text;
            TBSession *session;
            if (![incoming isKindOfClass:[NSDictionary class]])
                return textReply(400, @"request was not JSON\n");
            messages = cleanedMessages(incoming, YES);
            provider = [TBProviders normalize:TBString(incoming, @"provider")];
            system = [path isEqualToString:@"/v1/title"]
                ? @"You name chats. Reply with a short title of at most six words. No quotes."
                : @"Summarize this conversation so a later reply can continue it. Keep names, decisions, file paths, and unfinished work. Write plain prose.";
            session = [[[TBSession alloc] initWithRun:[TBRun runWithId:[NSString stringWithFormat:@"side-%p", body]] options:nil frames:nil] autorelease];
            text = [session completeProvider:provider model:[TBString(incoming, @"model") length] ? TBString(incoming, @"model") : nil system:system messages:messages];
            [TBRun finish:session->run];
            return textReply(200, [path isEqualToString:@"/v1/title"] ? cleanTitle(text) : text);
        }
    } @catch (NSException *exception) {
        return textReply(400, [[exception reason] stringByAppendingString:@"\n"]);
    }
    return textReply(404, @"not found\n");
}

@end

/* ---- a chat turn ---- */

@interface TBLocalTurn (Private)
- (void)work:(id)unused;
- (void)push:(NSString *)kind text:(NSString *)text;
- (void)flush;
@end

@interface TBTurnFrames : NSObject {
    TBLocalTurn *turn;
}
- (id)initWithTurn:(TBLocalTurn *)turn;
@end

@implementation TBTurnFrames
- (id)initWithTurn:(TBLocalTurn *)t
{
    self = [super init];
    turn = t;
    return self;
}
- (void)session:(id)session frame:(NSString *)kind text:(NSString *)text
{
    [turn push:kind text:text];
}
@end

@implementation TBLocalTurn

+ (TBLocalTurn *)startWithBody:(NSData *)body delegate:(id)delegate
{
    TBLocalTurn *turn = [[[TBLocalTurn alloc] init] autorelease];
    turn->delegate = delegate;
    turn->pending = [[NSMutableData alloc] init];
    turn->lock = [[NSLock alloc] init];
    turn->requestBody = [body retain];
    [turn retain];
    [NSThread detachNewThreadSelector:@selector(work:) toTarget:turn withObject:nil];
    return turn;
}

- (void)dealloc
{
    [run release];
    [pending release];
    [lock release];
    [requestBody release];
    [super dealloc];
}

- (void)cancel
{
    [lock lock];
    delegate = nil;
    [lock unlock];
    [run cancel];
}

/* Frames are batched: a model can send hundreds of small pieces a second, and each need not wake the window. */
- (void)push:(NSString *)kind text:(NSString *)text
{
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    NSString *head = [NSString stringWithFormat:@"%@ %lu\n", kind, (unsigned long)[data length]];
    BOOL schedule = NO;
    [lock lock];
    [pending appendData:[head dataUsingEncoding:NSASCIIStringEncoding]];
    [pending appendData:data];
    if (!flushScheduled) {
        flushScheduled = YES;
        schedule = YES;
    }
    [lock unlock];
    if (schedule)
        [self performSelectorOnMainThread:@selector(flush) withObject:nil waitUntilDone:NO];
}

- (void)flush
{
    NSData *bytes;
    id target;
    [lock lock];
    bytes = [NSData dataWithData:pending];
    [pending setLength:0];
    flushScheduled = NO;
    target = delegate;
    [lock unlock];
    if (target && [bytes length])
        [target localTurn:self bytes:bytes];
}

- (void)finish
{
    id target;
    [self flush];
    [lock lock];
    target = delegate;
    ended = YES;
    [lock unlock];
    if (target)
        [target localTurnEnded:self];
    [self release];
}

- (void)work:(id)unused
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    TBTurnFrames *frames = [[[TBTurnFrames alloc] initWithTurn:self] autorelease];
    TBSession *session = nil;
    TBRun *mine = nil;
    @try {
        id incoming = TBJSONParse(requestBody, NULL);
        NSArray *messages;
        BOOL useTools = YES;
        NSString *provider, *model;
        NSString *runId;
        if (![incoming isKindOfClass:[NSDictionary class]])
            TBFail(@"request was not JSON");
        messages = cleanedMessages(incoming, YES);
        if (TBValue(incoming, @"tools") && [TBValue(incoming, @"tools") isKindOfClass:[NSNumber class]] && ![TBValue(incoming, @"tools") boolValue])
            useTools = NO;
        provider = [TBProviders normalize:TBString(incoming, @"provider")];
        model = [TBString(incoming, @"model") length] ? TBString(incoming, @"model") : nil;
        runId = [TBString(incoming, @"run") length] >= 4 ? TBString(incoming, @"run") : [NSString stringWithFormat:@"run-%p", self];
        mine = [TBRun runWithId:runId];
        [lock lock];
        run = [mine retain];
        [lock unlock];
        session = [[[TBSession alloc] initWithRun:mine options:[TBSession cleanOptions:incoming] frames:frames] autorelease];
        [session setClientInfo:TBValue(incoming, @"client")];
        [session runTurn:messages useTools:useTools provider:provider model:model];
        [self push:@"d" text:@""];
    } @catch (NSException *exception) {
        if (![[exception name] isEqualToString:TBStoppedException]) {
            [self push:@"e" text:[exception reason] ? [exception reason] : @"The turn failed."];
            [self push:@"d" text:@""];
        } else {
            [self push:@"d" text:@""];
        }
    }
    if (mine)
        [TBRun finish:mine];
    [self performSelectorOnMainThread:@selector(finish) withObject:nil waitUntilDone:NO];
    [pool release];
}

@end
