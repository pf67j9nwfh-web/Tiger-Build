#import "TBCLICore.h"
#import "TBEngine.h"
#import "TBJSON.h"
#import "TBProviders.h"
#import "TBLocal.h"
#import "TBRun.h"

@interface TBCLICore (Private)
- (void)frame:(char)kind payload:(NSData *)payload;
- (void)mediaLine:(NSString *)line;
- (void)takeLease:(NSMutableDictionary *)chat;
- (void)addStatus:(NSString *)text;
- (BOOL)model:(NSString *)model allowedForProvider:(NSString *)provider;
@end
#include <unistd.h>
#include <signal.h>

NSString *TBCLISupportDir(void)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Tiger Build"];
    if (![fm fileExistsAtPath:dir])
        TBMakePath(dir);
    return dir;
}

static NSString *HelloText = @"Hello. Ask me anything.";

@interface TBCLICore (Private)
- (void)beginStream;
- (void)finishStream;
- (NSMutableDictionary *)openMessageIn:(NSMutableDictionary *)chat;
@end

@implementation TBCLICore

+ (TBCLICore *)core
{
    static TBCLICore *shared = nil;
    if (!shared)
        shared = [[TBCLICore alloc] init];
    return shared;
}

- (id)init
{
    self = [super init];
    localModels = [[NSMutableArray alloc] init];
    frameBuffer = [[NSMutableData alloc] init];
    overrides = [[NSMutableDictionary alloc] init];
    {
        /* the window's own preferences (which workspace, new chat model, the tool settings) are read from its domain */
        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        [d addSuiteNamed:@"local.tigerbuild.TigerBuild"];
    }
    return self;
}

- (void)setEvents:(id<TBCLIEvents>)delegate { events = delegate; }

/* ---- workspaces ---- */

- (NSString *)workspace
{
    if (!workspace) {
        NSString *name = [[NSUserDefaults standardUserDefaults] stringForKey:@"TigerBuildWorkspace"];
        workspace = [([name length] ? name : @"Default") copy];
    }
    return workspace;
}

- (NSString *)pathForWorkspace:(NSString *)name
{
    if ([name isEqualToString:@"Default"])
        return [TBCLISupportDir() stringByAppendingPathComponent:@"chats.plist"];
    return [[[TBCLISupportDir() stringByAppendingPathComponent:@"workspaces"] stringByAppendingPathComponent:name] stringByAppendingString:@".plist"];
}

- (NSArray *)workspaceNames
{
    NSMutableArray *names = [NSMutableArray array];
    NSArray *items = [[NSFileManager defaultManager] directoryContentsAtPath:[TBCLISupportDir() stringByAppendingPathComponent:@"workspaces"]];
    unsigned i;
    for (i = 0; i < [items count]; i++) {
        NSString *name = [items objectAtIndex:i];
        if ([name hasSuffix:@".plist"])
            [names addObject:[name stringByDeletingPathExtension]];
    }
    [names sortUsingSelector:@selector(caseInsensitiveCompare:)];
    [names insertObject:@"Default" atIndex:0];
    return names;
}

- (void)openWorkspace:(NSString *)name
{
    [workspace release];
    workspace = [name copy];
    [store release];
    store = [[TBStore storeAtPath:[self pathForWorkspace:name]] retain];
    current = nil;
}

- (TBStore *)store
{
    if (!store)
        store = [[TBStore storeAtPath:[self pathForWorkspace:[self workspace]]] retain];
    return store;
}

- (NSMutableArray *)chats { return [[self store] chats]; }
- (NSMutableDictionary *)workspaceSettings { return [[self store] settings]; }
- (NSMutableDictionary *)currentChat { return current; }
- (void)setCurrentChat:(NSMutableDictionary *)chat { current = chat; }

- (NSMutableDictionary *)chatWithId:(NSString *)ident
{
    NSArray *all = [self chats];
    unsigned i;
    for (i = 0; i < [all count]; i++)
        if ([[[all objectAtIndex:i] objectForKey:@"id"] isEqualToString:ident])
            return [all objectAtIndex:i];
    return nil;
}

- (void)save
{
    [[self store] markDirty];
    [[self store] flush];
}

- (NSString *)titleOf:(NSDictionary *)chat
{
    NSString *t = [chat objectForKey:@"title"];
    return [t length] ? t : @"Chat";
}

- (NSArray *)searchChats:(NSString *)text
{
    NSMutableArray *found = [NSMutableArray array];
    NSArray *all = [self chats];
    unsigned i, j;
    for (i = 0; i < [all count]; i++) {
        NSDictionary *chat = [all objectAtIndex:i];
        BOOL hit = [[self titleOf:chat] rangeOfString:text options:NSCaseInsensitiveSearch].length > 0;
        NSArray *messages = [chat objectForKey:@"messages"];
        for (j = 0; !hit && j < [messages count]; j++) {
            NSString *t = [[messages objectAtIndex:j] objectForKey:@"text"];
            hit = [t isKindOfClass:[NSString class]] && [t rangeOfString:text options:NSCaseInsensitiveSearch].length > 0;
        }
        if (hit)
            [found addObject:chat];
    }
    return found;
}

/* ---- models ---- */

- (void)refreshCatalog
{
    NSDictionary *models = [TBService handle:@"GET" path:@"/v1/models" body:nil file:nil name:nil];
    NSDictionary *tools = [TBService handle:@"GET" path:@"/v1/tools" body:nil file:nil name:nil];
    NSDictionary *local = [TBService handle:@"GET" path:@"/v1/local-models" body:nil file:nil name:nil];
    NSString *text = [[[NSString alloc] initWithData:[models objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease];
    [[ModelCatalog shared] loadText:text];
    {
        NSString *error = nil;
        id plist = [NSPropertyListSerialization propertyListFromData:[tools objectForKey:@"body"] mutabilityOption:NSPropertyListImmutable format:NULL errorDescription:&error];
        if (error)
            [error release];
        if ([plist isKindOfClass:[NSDictionary class]]) {
            [toolCatalog release];
            toolCatalog = [[plist objectForKey:@"tools"] retain];
            [commanderProblem release];
            commanderProblem = [[plist objectForKey:@"commander_problem"] copy];
        }
    }
    {
        NSString *lines = [[[NSString alloc] initWithData:[local objectForKey:@"body"] encoding:NSUTF8StringEncoding] autorelease];
        NSArray *rows = [lines componentsSeparatedByString:@"\n"];
        unsigned i;
        [localModels removeAllObjects];
        for (i = 0; i < [rows count]; i++) {
            NSArray *parts = [[rows objectAtIndex:i] componentsSeparatedByString:@"\t"];
            if ([parts count] < 2 || [[parts objectAtIndex:0] isEqualToString:@"error"])
                continue;
            [localModels addObject:[NSDictionary dictionaryWithObjectsAndKeys:[parts objectAtIndex:0], @"id",
                [parts count] > 2 && [[parts objectAtIndex:2] length] ? [parts objectAtIndex:2] : [parts objectAtIndex:0], @"title", nil]];
        }
    }
}

- (NSString *)commanderProblem { return commanderProblem; }

- (BOOL)providerUsable:(NSString *)provider
{
    if ([provider isEqualToString:@"local"])
        return [localModels count] > 0;
    return [[ModelCatalog shared] providerUsable:provider];
}

- (NSString *)providerNote:(NSString *)provider
{
    NSString *state;
    if ([provider isEqualToString:@"local"])
        return [localModels count] > 0 ? nil : @"no local models";
    state = [[ModelCatalog shared] stateForProvider:provider];
    if ([state isEqualToString:@"nokey"])
        return @"no API key";
    if (![[ModelCatalog shared] providerUsable:provider])
        return @"unavailable";
    return nil;
}

- (NSString *)firstUsableProvider
{
    NSArray *providers = [[ModelCatalog shared] providers];
    unsigned i;
    for (i = 0; i < [providers count]; i++) {
        NSString *pid = [[providers objectAtIndex:i] objectForKey:@"id"];
        if ([self providerUsable:pid])
            return pid;
    }
    return @"grok";
}

- (NSString *)defaultModelForProvider:(NSString *)provider
{
    if ([provider isEqualToString:@"local"])
        return [localModels count] ? [[localModels objectAtIndex:0] objectForKey:@"id"] : @"";
    return [[ModelCatalog shared] defaultModelForProvider:provider];
}

- (NSArray *)modelsForProvider:(NSString *)provider
{
    if ([provider isEqualToString:@"local"])
        return localModels;
    return [[ModelCatalog shared] modelsForProvider:provider];
}

- (BOOL)model:(NSString *)model allowedForProvider:(NSString *)provider
{
    unsigned i;
    if ([model length] == 0)
        return NO;
    if ([provider isEqualToString:@"local"]) {
        for (i = 0; i < [localModels count]; i++)
            if ([[[localModels objectAtIndex:i] objectForKey:@"id"] isEqualToString:model])
                return YES;
        return NO;
    }
    return [[ModelCatalog shared] hasModel:model forProvider:provider];
}

- (NSString *)providerForChat:(NSDictionary *)chat
{
    NSString *p = [chat objectForKey:@"provider"];
    return [p length] ? p : @"grok";
}

- (NSString *)modelForChat:(NSDictionary *)chat
{
    NSString *provider = [self providerForChat:chat], *model = [chat objectForKey:@"model"];
    return [self model:model allowedForProvider:provider] ? model : [self defaultModelForProvider:provider];
}

- (BOOL)setProvider:(NSString *)provider model:(NSString *)model chat:(NSMutableDictionary *)chat error:(NSString **)problem
{
    if (![self providerUsable:provider]) {
        NSString *note = [self providerNote:provider];
        if (problem)
            *problem = [NSString stringWithFormat:@"%@ cannot be used (%@).", [[ModelCatalog shared] titleForProvider:provider] ? [[ModelCatalog shared] titleForProvider:provider] : provider, note ? note : @"unavailable"];
        return NO;
    }
    if ([model length] && ![self model:model allowedForProvider:provider]) {
        if (problem)
            *problem = [NSString stringWithFormat:@"%@ has no model \"%@\". /model %@ lists its models.", provider, model, provider];
        return NO;
    }
    [chat setObject:provider forKey:@"provider"];
    [chat setObject:[model length] ? model : [self defaultModelForProvider:provider] forKey:@"model"];
    /* what depends on the model */
    [chat removeObjectForKey:@"contextLimit"];
    [chat removeObjectForKey:@"ctxTokens"];
    [chat removeObjectForKey:@"ctxAt"];
    [chat removeObjectForKey:@"autoPending"];
    return YES;
}

/* "grok", "claude:claude-sonnet-5-5", "gpt-4o" (a model of any usable provider, by its id or its start) */
- (BOOL)setModelSpec:(NSString *)spec chat:(NSMutableDictionary *)chat error:(NSString **)problem
{
    NSRange colon = [spec rangeOfString:@":"];
    NSString *provider = nil, *model = nil, *lower = [spec lowercaseString];
    NSArray *providers = [[ModelCatalog shared] providers];
    unsigned i, j;
    spec = TBTrim(spec);
    if (colon.location != NSNotFound) {
        provider = [[spec substringToIndex:colon.location] lowercaseString];
        model = [spec substringFromIndex:colon.location + 1];
    } else {
        for (i = 0; i < [providers count]; i++) {
            NSString *pid = [[providers objectAtIndex:i] objectForKey:@"id"];
            NSString *title = [[[ModelCatalog shared] titleForProvider:pid] lowercaseString];
            if ([pid isEqualToString:lower] || [title isEqualToString:lower]) {
                provider = pid;
                break;
            }
        }
        if (!provider) {
            NSMutableArray *pids = [NSMutableArray arrayWithObject:@"local"];
            for (i = 0; i < [providers count]; i++)
                [pids addObject:[[providers objectAtIndex:i] objectForKey:@"id"]];
            for (i = 0; i < [pids count] && !provider; i++) {
                NSArray *list = [self modelsForProvider:[pids objectAtIndex:i]];
                for (j = 0; j < [list count]; j++) {
                    NSString *mid = [[list objectAtIndex:j] objectForKey:@"id"];
                    if ([[mid lowercaseString] isEqualToString:lower] || [[[[list objectAtIndex:j] objectForKey:@"title"] lowercaseString] isEqualToString:lower]) {
                        provider = [pids objectAtIndex:i];
                        model = mid;
                        break;
                    }
                }
            }
            for (i = 0; i < [pids count] && !provider; i++) {
                NSArray *list = [self modelsForProvider:[pids objectAtIndex:i]];
                for (j = 0; j < [list count]; j++)
                    if ([[[[list objectAtIndex:j] objectForKey:@"id"] lowercaseString] hasPrefix:lower] && [self providerUsable:[pids objectAtIndex:i]]) {
                        provider = [pids objectAtIndex:i];
                        model = [[list objectAtIndex:j] objectForKey:@"id"];
                        break;
                    }
            }
        }
    }
    if (!provider) {
        if (problem)
            *problem = [NSString stringWithFormat:@"No service or model matches \"%@\". /model lists them.", spec];
        return NO;
    }
    /* a title typed for a model of that provider */
    if ([model length] && ![self model:model allowedForProvider:provider]) {
        NSArray *list = [self modelsForProvider:provider];
        for (j = 0; j < [list count]; j++)
            if ([[[[list objectAtIndex:j] objectForKey:@"title"] lowercaseString] isEqualToString:[model lowercaseString]] || [[[[list objectAtIndex:j] objectForKey:@"id"] lowercaseString] hasPrefix:[model lowercaseString]])
                model = [[list objectAtIndex:j] objectForKey:@"id"];
    }
    return [self setProvider:provider model:model chat:chat error:problem];
}

/* ---- chats ---- */

- (NSMutableDictionary *)newChat
{
    NSMutableDictionary *chat = [NSMutableDictionary dictionary], *hello = [NSMutableDictionary dictionary];
    NSMutableArray *messages = [NSMutableArray array];
    NSDictionary *last = [[self workspaceSettings] objectForKey:@"last"];
    NSString *wanted = [[NSUserDefaults standardUserDefaults] stringForKey:@"TigerBuildNewChatModel"], *provider = nil, *model = nil;
    [hello setObject:@"assistant" forKey:@"role"];
    [hello setObject:HelloText forKey:@"text"];
    [hello setObject:[NSNumber numberWithBool:NO] forKey:@"status"];
    [messages addObject:hello];
    [chat setObject:[NSString stringWithFormat:@"%d", [[self store] takeNextId]] forKey:@"id"];
    [chat setObject:@"New Chat" forKey:@"title"];
    [chat setObject:[NSNumber numberWithBool:YES] forKey:@"autoTitle"];
    [chat setObject:[NSNumber numberWithBool:YES] forKey:@"tools"];
    [chat setObject:[self firstUsableProvider] forKey:@"provider"];
    [chat setObject:[self defaultModelForProvider:[chat objectForKey:@"provider"]] forKey:@"model"];
    [chat setObject:messages forKey:@"messages"];
    if ([wanted isEqualToString:@"auto"])
        [chat setObject:[NSNumber numberWithBool:YES] forKey:@"autoPending"];
    if ([wanted length] && ![wanted isEqualToString:@"last"] && ![wanted isEqualToString:@"auto"]) {
        NSRange bar = [wanted rangeOfString:@"|"];
        if (bar.location != NSNotFound) {
            provider = [wanted substringToIndex:bar.location];
            model = [wanted substringFromIndex:bar.location + 1];
        }
    } else if ([last isKindOfClass:[NSDictionary class]]) {
        provider = [last objectForKey:@"provider"];
        model = [last objectForKey:@"model"];
    }
    if ([provider length] && [self providerUsable:provider]) {
        [chat setObject:provider forKey:@"provider"];
        [chat setObject:[self model:model allowedForProvider:provider] ? model : [self defaultModelForProvider:provider] forKey:@"model"];
    }
    if ([[[self workspaceSettings] objectForKey:@"instructions"] length])
        [chat setObject:[[self workspaceSettings] objectForKey:@"instructions"] forKey:@"instructions"];
    if ([[[self workspaceSettings] objectForKey:@"params"] isKindOfClass:[NSDictionary class]])
        [chat setObject:[[self workspaceSettings] objectForKey:@"params"] forKey:@"params"];
    if ([last isKindOfClass:[NSDictionary class]]) {
        if ([[last objectForKey:@"servers"] isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary *same = [NSMutableDictionary dictionaryWithDictionary:[last objectForKey:@"servers"]];
            [same removeObjectForKey:@"sudo"];
            [same removeObjectForKey:@"macapps"];
            [same removeObjectForKey:@"download"];
            [same removeObjectForKey:@"screen"];
            [chat setObject:same forKey:@"servers"];
            if ([[last objectForKey:@"servers"] objectForKey:@"commander"])
                [chat setObject:[[last objectForKey:@"servers"] objectForKey:@"commander"] forKey:@"tools"];
        }
        if ([[last objectForKey:@"approve"] isKindOfClass:[NSDictionary class]])
            [chat setObject:[NSMutableDictionary dictionaryWithDictionary:[last objectForKey:@"approve"]] forKey:@"approve"];
    }
    [[self chats] insertObject:chat atIndex:0];
    current = chat;
    return chat;
}

- (NSMutableDictionary *)forkChat:(NSDictionary *)chat upTo:(int)messageCount
{
    NSMutableDictionary *copy = [[chat mutableCopy] autorelease];
    NSArray *messages = [chat objectForKey:@"messages"];
    NSMutableArray *kept = [NSMutableArray array];
    int i;
    for (i = 0; i < (int)[messages count] && (messageCount < 0 || i < messageCount); i++)
        [kept addObject:[[[messages objectAtIndex:i] mutableCopy] autorelease]];
    [copy setObject:kept forKey:@"messages"];
    [copy setObject:[NSString stringWithFormat:@"%d", [[self store] takeNextId]] forKey:@"id"];
    [copy setObject:[[self titleOf:chat] stringByAppendingString:@" (fork)"] forKey:@"title"];
    [copy setObject:[NSNumber numberWithBool:NO] forKey:@"autoTitle"];
    [copy removeObjectForKey:@"rev"];
    [copy removeObjectForKey:@"lease"];
    [[self chats] insertObject:copy atIndex:0];
    return copy;
}

- (void)deleteChat:(NSMutableDictionary *)chat
{
    [[self chats] removeObject:chat];
    if (current == chat)
        current = nil;
}

- (NSString *)lastReplyText:(NSDictionary *)chat
{
    NSArray *messages = [chat objectForKey:@"messages"];
    int i;
    for (i = (int)[messages count] - 1; i >= 0; i--) {
        NSDictionary *m = [messages objectAtIndex:i];
        NSString *t = [m objectForKey:@"text"];
        if ([[m objectForKey:@"status"] boolValue] || ![[m objectForKey:@"role"] isEqualToString:@"assistant"] || [m objectForKey:@"file"] || [m objectForKey:@"tweet"])
            continue;
        if ([t length])
            return t;
    }
    return nil;
}

- (int)contextTokensForChat:(NSDictionary *)chat
{
    int measured = [[chat objectForKey:@"ctxTokens"] intValue], at = [[chat objectForKey:@"ctxAt"] intValue];
    NSArray *messages = [chat objectForKey:@"messages"];
    int estimate = TBEstimateTokens(messages, YES);
    NSMutableArray *newer;
    unsigned i;
    if (measured <= 0 || at <= 0 || at > (int)[messages count])
        return estimate;
    newer = [NSMutableArray array];
    for (i = at; i < [messages count]; i++)
        [newer addObject:[messages objectAtIndex:i]];
    return measured + TBEstimateTokens(newer, NO) - 400;
}

/* ---- tool switches ---- */

- (NSArray *)toolCatalog
{
    if ([toolCatalog count])
        return toolCatalog;
    return [NSArray arrayWithObject:[NSDictionary dictionaryWithObjectsAndKeys:@"commander", @"id", @"Commander (this Mac)", @"title", [NSNumber numberWithBool:YES], @"default", nil]];
}

- (NSDictionary *)catalogEntry:(NSString *)key
{
    NSArray *list = [self toolCatalog];
    unsigned i;
    for (i = 0; i < [list count]; i++)
        if ([[[list objectAtIndex:i] objectForKey:@"id"] isEqualToString:key])
            return [list objectAtIndex:i];
    return nil;
}

- (BOOL)serverEnabled:(NSString *)key chat:(NSDictionary *)chat
{
    NSDictionary *servers = [chat objectForKey:@"servers"];
    id value = [overrides objectForKey:key];
    NSDictionary *entry;
    if (value)
        return [value boolValue];
    value = [servers isKindOfClass:[NSDictionary class]] ? [servers objectForKey:key] : nil;
    if (value)
        return [value boolValue];
    if ([key isEqualToString:@"commander"] && [chat objectForKey:@"tools"])
        return [[chat objectForKey:@"tools"] boolValue];
    entry = [self catalogEntry:key];
    if (entry && [entry objectForKey:@"default"])
        return [[entry objectForKey:@"default"] boolValue];
    return YES;
}

- (void)setServer:(NSString *)key enabled:(BOOL)on chat:(NSMutableDictionary *)chat
{
    NSMutableDictionary *servers = [chat objectForKey:@"servers"];
    if (![servers isKindOfClass:[NSMutableDictionary class]]) {
        servers = [NSMutableDictionary dictionaryWithDictionary:[servers isKindOfClass:[NSDictionary class]] ? servers : [NSDictionary dictionary]];
        [chat setObject:servers forKey:@"servers"];
    }
    [servers setObject:[NSNumber numberWithBool:on] forKey:key];
    if ([key isEqualToString:@"commander"])
        [chat setObject:[NSNumber numberWithBool:on] forKey:@"tools"];
}

- (BOOL)approvalOn:(NSString *)key chat:(NSDictionary *)chat
{
    NSDictionary *approve = [chat objectForKey:@"approve"];
    id value = [approve isKindOfClass:[NSDictionary class]] ? [approve objectForKey:key] : nil;
    if (value)
        return [value boolValue];
    value = [approve isKindOfClass:[NSDictionary class]] ? [approve objectForKey:@"all"] : nil;
    if (value)
        return [value boolValue];
    return [[[self catalogEntry:key] objectForKey:@"approval"] boolValue];
}

- (void)setApproval:(BOOL)on forKey:(NSString *)key chat:(NSMutableDictionary *)chat
{
    NSMutableDictionary *approve = [chat objectForKey:@"approve"];
    if (![approve isKindOfClass:[NSMutableDictionary class]]) {
        approve = [NSMutableDictionary dictionaryWithDictionary:[approve isKindOfClass:[NSDictionary class]] ? approve : [NSDictionary dictionary]];
        [chat setObject:approve forKey:@"approve"];
    }
    [approve setObject:[NSNumber numberWithBool:on] forKey:key];
}

- (void)setPermissionMode:(NSString *)mode { [permissionMode release]; permissionMode = [mode copy]; }
- (NSString *)permissionMode { return permissionMode ? permissionMode : @"ask"; }
- (void)setExtraInstructions:(NSString *)text { [extraInstructions release]; extraInstructions = [text copy]; }

- (void)setRunOverrides:(NSDictionary *)servers
{
    [overrides setDictionary:servers ? servers : [NSDictionary dictionary]];
}

/* ---- the request ---- */

- (BOOL)anyServerEnabled:(NSDictionary *)chat
{
    NSArray *list = [self toolCatalog];
    unsigned i;
    for (i = 0; i < [list count]; i++)
        if ([self serverEnabled:[[list objectAtIndex:i] objectForKey:@"id"] chat:chat])
            return YES;
    return NO;
}

- (NSData *)requestBodyForChat:(NSDictionary *)chat
{
    NSArray *messages = [chat objectForKey:@"messages"];
    NSMutableString *body = [NSMutableString stringWithString:@"{\"messages\":["];
    NSDictionary *settings = [self workspaceSettings];
    NSArray *list = [self toolCatalog];
    BOOL first = YES;
    unsigned i;
    TBSetPathHintRoot([[settings objectForKey:@"limitRoot"] boolValue] ? [settings objectForKey:@"root"] : nil);
    for (i = 0; i < [messages count]; i++) {
        NSDictionary *message = [messages objectAtIndex:i];
        NSString *text = TBMessageContent(message), *role;
        if ([[message objectForKey:@"status"] boolValue])
            continue;
        if ([[message objectForKey:@"open"] boolValue] && [text length] == 0)
            continue;
        role = [[message objectForKey:@"role"] isEqualToString:@"user"] ? @"user" : @"assistant";
        if (!first)
            [body appendString:@","];
        first = NO;
        [body appendFormat:@"{\"role\":\"%@\",\"content\":\"%@\"}", role, TBJSONEscape(text)];
    }
    [body appendFormat:@"],\"tools\":%s,\"provider\":\"%@\",\"model\":\"%@\",\"run\":\"%@\",\"client\":{\"machine\":\"%@\",\"os\":\"%@\",\"user\":\"%@\",\"home\":\"%@\"}",
        [self anyServerEnabled:chat] ? "true" : "false", TBJSONEscape([self providerForChat:chat]), TBJSONEscape([self modelForChat:chat]), TBJSONEscape(runId),
        TBJSONEscape([TBMachine name]), TBJSONEscape([TBMachine systemVersion]), TBJSONEscape(NSUserName()), TBJSONEscape(NSHomeDirectory())];
    [body appendString:@",\"servers\":{"];
    for (i = 0; i < [list count]; i++) {
        NSString *key = [[list objectAtIndex:i] objectForKey:@"id"];
        [body appendFormat:@"%@\"%@\":%s", i ? @"," : @"", TBJSONEscape(key), [self serverEnabled:key chat:chat] ? "true" : "false"];
    }
    [body appendString:@"},\"approve\":{"];
    {
        NSDictionary *approve = [chat objectForKey:@"approve"];
        NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:[approve isKindOfClass:[NSDictionary class]] ? approve : [NSDictionary dictionary]];
        NSEnumerator *keys;
        NSString *key;
        BOOL firstKey = YES, attached = NO;
        unsigned m;
        for (m = 0; m < [messages count] && !attached; m++)
            attached = [[messages objectAtIndex:m] objectForKey:@"attachment"] != nil;
        if (attached)
            for (i = 0; i < [list count]; i++) {
                key = [[list objectAtIndex:i] objectForKey:@"id"];
                if (([key isEqualToString:@"commander"] || [key hasPrefix:@"mcp_"]) && ![merged objectForKey:key] && ![merged objectForKey:@"all"])
                    [merged setObject:[NSNumber numberWithBool:YES] forKey:key];
            }
        /* the terminal asks by default: Commander asks unless the chat says otherwise, and plan mode always asks (and refuses) */
        {
            NSString *mode = [self permissionMode];
            for (i = 0; i < [list count]; i++) {
                key = [[list objectAtIndex:i] objectForKey:@"id"];
                if ([mode isEqualToString:@"auto"])
                    [merged setObject:[NSNumber numberWithBool:NO] forKey:key];
                else if ([key isEqualToString:@"commander"] && ([mode isEqualToString:@"plan"] || ![merged objectForKey:key]))
                    [merged setObject:[NSNumber numberWithBool:YES] forKey:key];
            }
        }
        keys = [merged keyEnumerator];
        while ((key = [keys nextObject])) {
            [body appendFormat:@"%@\"%@\":%s", firstKey ? @"" : @",", TBJSONEscape(key), [[merged objectForKey:key] boolValue] ? "true" : "false"];
            firstKey = NO;
        }
    }
    [body appendString:@"}"];
    if ([[settings objectForKey:@"limitRoot"] boolValue] && [[settings objectForKey:@"root"] length])
        [body appendFormat:@",\"root\":\"%@\"", TBJSONEscape([settings objectForKey:@"root"])];
    {
        NSString *own = [chat objectForKey:@"instructions"];
        NSString *all = [own length] ? ([extraInstructions length] ? [NSString stringWithFormat:@"%@\n\n%@", own, extraInstructions] : own) : extraInstructions;
        if ([all length])
            [body appendFormat:@",\"instructions\":\"%@\"", TBJSONEscape(all)];
    }
    if ([[settings objectForKey:@"memoryOn"] boolValue] && [[settings objectForKey:@"memory"] length])
        [body appendFormat:@",\"memory\":\"%@\"", TBJSONEscape([settings objectForKey:@"memory"])];
    if ([[chat objectForKey:@"params"] isKindOfClass:[NSDictionary class]] && [[chat objectForKey:@"params"] count])
        [body appendFormat:@",\"params\":%@", TBJSONString([chat objectForKey:@"params"])];
    if ([[settings objectForKey:@"knowledgeRoot"] length])
        [body appendFormat:@",\"knowledge\":\"%@\"", TBJSONEscape([settings objectForKey:@"knowledgeRoot"])];
    [body appendString:@"}"];
    TBSetPathHintRoot(nil);
    return [body dataUsingEncoding:NSUTF8StringEncoding];
}

/* ---- leases: who is working in a chat ---- */

- (NSString *)liveLeaseNoteForChat:(NSDictionary *)chat { return TBChatLeaseNote(chat); }

- (void)takeLease:(NSMutableDictionary *)chat { TBChatTakeLease(chat, @"the terminal (tb)"); }

/* ---- a turn ---- */

- (BOOL)busy { return busy; }
- (double)turnSeconds { return busy ? CFAbsoluteTimeGetCurrent() - turnStart : 0; }

- (NSString *)sendText:(NSString *)text
{
    NSMutableDictionary *user, *open;
    NSString *note;
    if (busy)
        return @"A reply is still being made.";
    if (!current)
        [self newChat];
    note = [self liveLeaseNoteForChat:current];
    if (note)
        return [NSString stringWithFormat:@"This chat is %@. Wait for it to finish, or start another chat (/new).", note];
    if (![self providerUsable:[self providerForChat:current]]) {
        NSString *pid = [self providerForChat:current], *why = [self providerNote:pid];
        return [NSString stringWithFormat:@"%@ cannot be used (%@). /model picks another service.", pid, why ? why : @"unavailable"];
    }
    if (![self model:[current objectForKey:@"model"] allowedForProvider:[self providerForChat:current]])
        [current setObject:[self defaultModelForProvider:[self providerForChat:current]] forKey:@"model"];
    user = [NSMutableDictionary dictionaryWithObjectsAndKeys:@"user", @"role", text, @"text", [NSNumber numberWithBool:NO], @"status", nil];
    open = [NSMutableDictionary dictionaryWithObjectsAndKeys:@"assistant", @"role", @"", @"text", [NSNumber numberWithBool:NO], @"status", [NSNumber numberWithBool:YES], @"open", nil];
    [[current objectForKey:@"messages"] addObject:user];
    [[current objectForKey:@"messages"] addObject:open];
    if ([[current objectForKey:@"title"] isEqualToString:@"New Chat"]) {
        NSString *t = [[text componentsSeparatedByString:@"\n"] objectAtIndex:0];
        if ([t length] > 26)
            t = [[t substringToIndex:26] stringByAppendingString:@"..."];
        [current setObject:t forKey:@"title"];
    }
    {
        NSMutableDictionary *last = [NSMutableDictionary dictionary];
        [last setObject:[self providerForChat:current] forKey:@"provider"];
        [last setObject:[self modelForChat:current] forKey:@"model"];
        if ([[current objectForKey:@"servers"] isKindOfClass:[NSDictionary class]])
            [last setObject:[current objectForKey:@"servers"] forKey:@"servers"];
        if ([[current objectForKey:@"approve"] isKindOfClass:[NSDictionary class]])
            [last setObject:[current objectForKey:@"approve"] forKey:@"approve"];
        [[self workspaceSettings] setObject:last forKey:@"last"];
    }
    [self takeLease:current];
    [current setObject:[NSNumber numberWithDouble:CFAbsoluteTimeGetCurrent()] forKey:@"turnStart"];
    [self save];
    busy = YES;
    stopping = NO;
    turnStart = CFAbsoluteTimeGetCurrent();
    [self beginStream];
    return nil;
}

- (NSString *)resend
{
    NSMutableArray *messages = [current objectForKey:@"messages"];
    int i, userAt = -1;
    NSString *text;
    if (busy || !current)
        return @"Nothing to resend.";
    for (i = (int)[messages count] - 1; i >= 0; i--)
        if ([[[messages objectAtIndex:i] objectForKey:@"role"] isEqualToString:@"user"] && ![[[messages objectAtIndex:i] objectForKey:@"status"] boolValue]) {
            userAt = i;
            break;
        }
    if (userAt < 0)
        return @"There is no message to send again.";
    text = [[messages objectAtIndex:userAt] objectForKey:@"text"];
    while ((int)[messages count] > userAt)
        [messages removeObjectAtIndex:userAt];
    return [self sendText:text];
}

- (NSMutableDictionary *)openMessageIn:(NSMutableDictionary *)chat
{
    NSMutableArray *messages = [chat objectForKey:@"messages"];
    int i;
    for (i = (int)[messages count] - 1; i >= 0; i--)
        if ([[[messages objectAtIndex:i] objectForKey:@"open"] boolValue])
            return [messages objectAtIndex:i];
    return nil;
}

- (void)beginStream
{
    NSData *payload;
    [runId release];
    runId = [[NSString stringWithFormat:@"tb%08x%08x", (unsigned)CFAbsoluteTimeGetCurrent(), (unsigned)arc4random()] retain];
    [frameBuffer setLength:0];
    payload = [self requestBodyForChat:current];
    if (getenv("TB_DEBUG_BODY"))
        fprintf(stderr, "REQUEST %s\n", [[[[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding] autorelease] UTF8String]);
    turn = [[TBLocalTurn startWithBody:payload delegate:self] retain];
}

- (void)stop
{
    if (!busy || stopping)
        return;
    stopping = YES;
    [TBService handle:@"POST" path:@"/v1/run" body:[[NSString stringWithFormat:@"{\"id\":\"%@\",\"action\":\"stop\"}", TBJSONEscape(runId)] dataUsingEncoding:NSUTF8StringEncoding] file:nil name:nil];
}

- (BOOL)guide:(NSString *)text
{
    NSDictionary *r;
    if (!busy)
        return NO;
    r = [TBService handle:@"POST" path:@"/v1/run" body:[[NSString stringWithFormat:@"{\"id\":\"%@\",\"action\":\"guide\",\"text\":\"%@\"}", TBJSONEscape(runId), TBJSONEscape(text)] dataUsingEncoding:NSUTF8StringEncoding] file:nil name:nil];
    return [[r objectForKey:@"status"] intValue] == 200;
}

- (void)answer:(NSString *)decision
{
    NSString *call = [question objectForKey:@"id"];
    if (!call)
        return;
    if ([decision isEqualToString:@"always"])
        [self setApproval:NO forKey:[question objectForKey:@"server"] chat:current];
    [TBService handle:@"POST" path:@"/v1/run" body:[[NSString stringWithFormat:@"{\"id\":\"%@\",\"action\":\"approve\",\"call\":\"%@\",\"decision\":\"%@\"}",
        TBJSONEscape(runId), TBJSONEscape(call), TBJSONEscape(decision)] dataUsingEncoding:NSUTF8StringEncoding] file:nil name:nil];
    [question release];
    question = nil;
}

/* frames arrive as "<kind> <length>\n<bytes>" */
- (void)localTurn:(TBLocalTurn *)t bytes:(NSData *)bytes
{
    const unsigned char *b;
    NSUInteger n, at = 0;
    (void)t;
    [frameBuffer appendData:bytes];
    b = [frameBuffer bytes];
    n = [frameBuffer length];
    while (at < n) {
        NSUInteger nl = at, len = 0, i;
        char kind;
        while (nl < n && b[nl] != '\n')
            nl++;
        if (nl >= n)
            break;
        kind = (char)b[at];
        for (i = at + 1; i < nl; i++)
            if (b[i] >= '0' && b[i] <= '9')
                len = len * 10 + (b[i] - '0');
        if (nl + 1 + len > n)
            break;
        [self frame:kind payload:[NSData dataWithBytes:b + nl + 1 length:len]];
        at = nl + 1 + len;
    }
    [frameBuffer replaceBytesInRange:NSMakeRange(0, at) withBytes:NULL length:0];
}

- (void)addStatus:(NSString *)text
{
    NSMutableArray *messages = [current objectForKey:@"messages"];
    NSMutableDictionary *note = [NSMutableDictionary dictionaryWithObjectsAndKeys:@"status", @"role", text ? text : @"", @"text", [NSNumber numberWithBool:YES], @"status", nil];
    NSMutableDictionary *open = [self openMessageIn:current];
    if (open && [[open objectForKey:@"text"] length] == 0)
        [messages insertObject:note atIndex:[messages indexOfObject:open]];
    else {
        if (open && [[open objectForKey:@"text"] length] > 0)
            [open setObject:[NSNumber numberWithBool:NO] forKey:@"open"];
        [messages addObject:note];
    }
}

- (void)frame:(char)kind payload:(NSData *)payload
{
    NSMutableDictionary *chat = current;
    NSString *text = nil;
    if (!chat)
        return;
    if (kind != 'd' && [payload length] > 0) {
        text = [[[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding] autorelease];
        if (!text)
            text = [[[NSString alloc] initWithData:payload encoding:NSMacOSRomanStringEncoding] autorelease];
    }
    switch (kind) {
    case 'k':
        return;
    case 'd':
        return;
    case 'u': {
        NSString *error = nil;
        NSDictionary *usage = [NSPropertyListSerialization propertyListFromData:payload mutabilityOption:NSPropertyListImmutable format:NULL errorDescription:&error];
        if (error)
            [error release];
        if ([usage isKindOfClass:[NSDictionary class]]) {
            int context = [[usage objectForKey:@"context"] intValue];
            NSMutableDictionary *open = [self openMessageIn:chat];
            double started = [[chat objectForKey:@"turnStart"] doubleValue];
            TBAddUsage(chat, usage);
            if (context > 0) {
                [chat setObject:[NSNumber numberWithInt:context] forKey:@"ctxTokens"];
                [chat setObject:[NSNumber numberWithInt:(int)[[chat objectForKey:@"messages"] count]] forKey:@"ctxAt"];
            }
            if (open && started > 0) {
                int in = [[usage objectForKey:@"input"] intValue] + [[usage objectForKey:@"cached"] intValue] + [[usage objectForKey:@"written"] intValue];
                [open setObject:[NSNumber numberWithInt:[[open objectForKey:@"statsIn"] intValue] + in] forKey:@"statsIn"];
                [open setObject:[NSNumber numberWithInt:[[open objectForKey:@"statsOut"] intValue] + [[usage objectForKey:@"output"] intValue]] forKey:@"statsOut"];
                [open setObject:[NSNumber numberWithDouble:CFAbsoluteTimeGetCurrent() - started] forKey:@"statsSeconds"];
                [open setObject:[NSNumber numberWithDouble:[[NSDate date] timeIntervalSince1970]] forKey:@"statsFinished"];
            }
            [events core:self usage:usage];
        }
        return;
    }
    case 'q': {
        NSString *error = nil;
        NSDictionary *event = [NSPropertyListSerialization propertyListFromData:payload mutabilityOption:NSPropertyListImmutable format:NULL errorDescription:&error];
        if (error)
            [error release];
        if ([event isKindOfClass:[NSDictionary class]]) {
            [question release];
            question = [[NSMutableDictionary dictionaryWithDictionary:event] retain];
            [events core:self question:event];
        }
        return;
    }
    case 'a': {
        NSString *error = nil;
        NSDictionary *event = [NSPropertyListSerialization propertyListFromData:payload mutabilityOption:NSPropertyListMutableContainers format:NULL errorDescription:&error];
        if (error)
            [error release];
        if ([event isKindOfClass:[NSDictionary class]]) {
            NSMutableArray *messages = [chat objectForKey:@"messages"];
            NSMutableDictionary *activity = nil;
            BOOL finished = [[event objectForKey:@"phase"] isEqualToString:@"result"];
            NSString *state = finished ? ([[event objectForKey:@"failed"] boolValue] ? @"Failed" : @"Completed") : @"Running";
            unsigned i;
            for (i = 0; i < [messages count]; i++)
                if ([[[messages objectAtIndex:i] objectForKey:@"activityID"] isEqualToString:[event objectForKey:@"id"]])
                    activity = [messages objectAtIndex:i];
            if (!activity) {
                activity = [NSMutableDictionary dictionaryWithObjectsAndKeys:@"status", @"role", [NSNumber numberWithBool:YES], @"status", [event objectForKey:@"id"], @"activityID", @"tool", @"activityKind", nil];
                [messages insertObject:activity atIndex:[messages count] > 0 ? [messages count] - 1 : 0];
            }
            [activity setObject:[NSString stringWithFormat:@"%@ - %@%@", [event objectForKey:@"name"], state,
                finished ? [NSString stringWithFormat:@" (%.1fs)", [[event objectForKey:@"elapsed"] doubleValue]] : ([[event objectForKey:@"label"] length] ? [NSString stringWithFormat:@": %@", [event objectForKey:@"label"]] : @"")] forKey:@"text"];
            if (finished && [event objectForKey:@"files"]) {
                int files = [[event objectForKey:@"files"] intValue];
                [activity setObject:[NSString stringWithFormat:@"%@   %d file%@  +%d  %C%d", [activity objectForKey:@"text"], files, files == 1 ? @"" : @"s",
                    [[event objectForKey:@"added"] intValue], (unichar)0x2212, [[event objectForKey:@"removed"] intValue]] forKey:@"text"];
            }
            [activity setObject:[NSString stringWithFormat:@"%@\n\n%@", [event objectForKey:@"detail"], [event objectForKey:@"output"]] forKey:@"detail"];
            if ([event objectForKey:@"failed"])
                [activity setObject:[event objectForKey:@"failed"] forKey:@"failed"];
            [events core:self activity:event];
        }
        return;
    }
    case 'h': {
        NSMutableArray *messages = [chat objectForKey:@"messages"];
        NSMutableDictionary *thinking = nil;
        int i;
        for (i = (int)[messages count] - 1; i >= 0; i--) {
            NSMutableDictionary *m = [messages objectAtIndex:i];
            if ([[m objectForKey:@"role"] isEqualToString:@"user"])
                break;
            if ([[m objectForKey:@"activityKind"] isEqualToString:@"thinking"]) {
                thinking = m;
                break;
            }
        }
        if (!thinking) {
            thinking = [NSMutableDictionary dictionaryWithObjectsAndKeys:@"status", @"role", [NSNumber numberWithBool:YES], @"status", @"thinking", @"activityKind", @"Model thinking (returned summary)", @"text", @"", @"detail", nil];
            [messages insertObject:thinking atIndex:[messages count] > 0 ? [messages count] - 1 : 0];
        }
        [thinking setObject:[[thinking objectForKey:@"detail"] stringByAppendingString:text ? text : @""] forKey:@"detail"];
        [events core:self thinking:text];
        return;
    }
    case 'g':
        [self addStatus:[NSString stringWithFormat:@"Guidance delivered: %@", text]];
        [events core:self status:[NSString stringWithFormat:@"Note delivered: %@", text] error:NO];
        return;
    case 't': {
        NSMutableDictionary *open = [self openMessageIn:chat];
        NSString *soFar;
        if (!open) {
            open = [NSMutableDictionary dictionaryWithObjectsAndKeys:@"assistant", @"role", @"", @"text", [NSNumber numberWithBool:NO], @"status", [NSNumber numberWithBool:YES], @"open", nil];
            [[chat objectForKey:@"messages"] addObject:open];
        }
        soFar = [open objectForKey:@"text"];
        [open setObject:[(soFar ? soFar : @"") stringByAppendingString:text ? text : @""] forKey:@"text"];
        [events core:self text:text];
        return;
    }
    case 'm':
        [self mediaLine:text];
        return;
    case 'c':
    case 's':
    case 'e':
        [self addStatus:text];
        [events core:self status:text error:kind == 'e'];
        return;
    default:
        return;
    }
}

/* A picture, video, file or post the model showed. The engine has already stored it in the media folder; the chat gets the same keys the window gives it. */
- (void)mediaLine:(NSString *)line
{
    NSArray *parts = [line componentsSeparatedByString:@" "];
    NSString *kind, *name, *path;
    NSMutableDictionary *open, *message;
    NSMutableArray *messages = [current objectForKey:@"messages"];
    if ([parts count] < 2)
        return;
    kind = [parts objectAtIndex:0];
    name = [parts objectAtIndex:1];
    if ([kind isEqualToString:@"tweet"]) {
        NSData *json = [parts count] > 2 ? TBBase64Decode([parts objectAtIndex:2]) : nil;
        NSDictionary *post = json ? TBJSONParse(json, NULL) : nil;
        NSMutableDictionary *shown, *bubble;
        NSString *postText, *avatar;
        if (![post isKindOfClass:[NSDictionary class]] || ![name length])
            return;
        open = [self openMessageIn:current];
        if (open && [[open objectForKey:@"text"] length] == 0 && ![open objectForKey:@"image"] && ![open objectForKey:@"video"] && ![open objectForKey:@"pendingMedia"])
            [messages removeObject:open];
        else if (open)
            [open setObject:[NSNumber numberWithBool:NO] forKey:@"open"];
        shown = [NSMutableDictionary dictionaryWithDictionary:post];
        avatar = [post objectForKey:@"avatar"];
        [shown removeObjectForKey:@"avatar"];
        if ([avatar isKindOfClass:[NSString class]] && TBBase64Decode(avatar))
            [shown setObject:TBBase64Decode(avatar) forKey:@"avatar"];
        postText = [post objectForKey:@"text"];
        bubble = [NSMutableDictionary dictionaryWithObjectsAndKeys:@"assistant", @"role", [postText isKindOfClass:[NSString class]] && [postText length] ? postText : @" ", @"text",
            [NSNumber numberWithBool:NO], @"status", shown, @"tweet", [@"https://x.com/i/status/" stringByAppendingString:name], @"tweetLink", nil];
        [messages addObject:bubble];
        [events core:self media:[NSString stringWithFormat:@"post by %@: %@", [[post objectForKey:@"user"] isKindOfClass:[NSDictionary class]] ? [[post objectForKey:@"user"] objectForKey:@"screen_name"] : @"?", postText ? postText : @""]];
        return;
    }
    if ([name length] == 0 || [name rangeOfString:@"/"].length || [name rangeOfString:@".."].length)
        return;
    path = [[TBCLISupportDir() stringByAppendingPathComponent:@"media"] stringByAppendingPathComponent:name];
    if ([parts count] > 2 && [[parts objectAtIndex:2] isEqualToString:@"tweet"] && ![kind isEqualToString:@"file"]) {
        int t;
        message = nil;
        for (t = (int)[messages count] - 1; t >= 0 && !message; t--)
            if ([[messages objectAtIndex:t] objectForKey:@"tweet"])
                message = [messages objectAtIndex:t];
        if (message) {
            [message setObject:path forKey:[kind isEqualToString:@"tweetvideo"] ? @"tweetVideo" : ([kind isEqualToString:@"image"] ? @"image" : @"video")];
            [events core:self media:[NSString stringWithFormat:@"%@ of the post", [kind isEqualToString:@"image"] ? @"picture" : @"video"]];
            return;
        }
    }
    open = [self openMessageIn:current];
    if ([kind isEqualToString:@"file"]) {
        message = [NSMutableDictionary dictionaryWithObjectsAndKeys:@"assistant", @"role", [NSNumber numberWithBool:NO], @"status", nil];
        if (open && [[open objectForKey:@"text"] length] == 0 && ![open objectForKey:@"image"] && ![open objectForKey:@"video"])
            [messages removeObject:open];
        else if (open)
            [open setObject:[NSNumber numberWithBool:NO] forKey:@"open"];
        [message setObject:path forKey:@"file"];
        [message setObject:[NSString stringWithFormat:@"%@ (%@)", TBDisplayFileName(path), TBHumanSize([[[NSFileManager defaultManager] fileAttributesAtPath:path traverseLink:NO] fileSize])] forKey:@"text"];
        [messages addObject:message];
        [events core:self media:[NSString stringWithFormat:@"file %@ (saved in %@)", TBDisplayFileName(path), [path stringByDeletingLastPathComponent]]];
        return;
    }
    if (open && ([open objectForKey:@"image"] || [open objectForKey:@"video"])) {
        [open setObject:[NSNumber numberWithBool:NO] forKey:@"open"];
        open = nil;
    }
    if (!open) {
        open = [NSMutableDictionary dictionaryWithObjectsAndKeys:@"assistant", @"role", @"", @"text", [NSNumber numberWithBool:NO], @"status", [NSNumber numberWithBool:YES], @"open", nil];
        [messages addObject:open];
    }
    [open setObject:path forKey:[kind isEqualToString:@"image"] ? @"image" : @"video"];
    [events core:self media:[NSString stringWithFormat:@"%@ %@", [kind isEqualToString:@"image"] ? @"picture" : @"video", TBDisplayFileName(path)]];
}

- (void)localTurnEnded:(TBLocalTurn *)t
{
    (void)t;
    [self finishStream];
}

- (void)finishStream
{
    NSMutableDictionary *open;
    [turn release];
    turn = nil;
    if (current) {
        open = [self openMessageIn:current];
        if (open) {
            [open setObject:[NSNumber numberWithBool:NO] forKey:@"open"];
            if ([[open objectForKey:@"text"] length] == 0 && ![open objectForKey:@"image"] && ![open objectForKey:@"video"])
                [[current objectForKey:@"messages"] removeObject:open];
        }
        [current removeObjectForKey:@"lease"];
        [self save];
    }
    busy = NO;
    [question release];
    question = nil;
    [events coreTurnEnded:self];
}

@end
