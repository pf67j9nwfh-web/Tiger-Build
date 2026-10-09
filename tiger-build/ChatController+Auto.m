#import "ChatController_Private.h"
#import "TBProviders.h"
#import "TBSession.h"
#import "TBModelProfiles.h"
#import "TBPricing.h"

/* Auto model mode (optional: Preferences, New chats start with, Choose the model automatically). A new chat in auto mode is marked autoPending. When its first
   message is sent, the model chosen in Preferences ("Auto mode asks") reads the message and the list of usable models and names one. The chat then gets that
   provider and model exactly as if the person had picked them, and nothing records that it was automatic.
   Also here: what else on a chat follows when its model changes. */

@interface ChatController (AutoNeeds)
- (BOOL)startCompactionIfNeeded;
- (void)beginChatStream;
- (NSMutableDictionary *)chatWithId:(NSString *)chatId;
- (BOOL)model:(NSString *)model allowedForProvider:(NSString *)provider;
- (NSString *)defaultModelForProvider:(NSString *)provider;
- (BOOL)chatHasAttachments:(NSDictionary *)chat;
- (void)rememberContextLimit;
- (void)updateContextReadout;
- (void)syncModelMenu;
- (NSMenu *)modelMenu;
- (void)fillProviderMenu:(NSMenu *)menu;
- (void)fillProviderPopup;
- (void)setBusy:(BOOL)flag;
- (void)rememberLastUsed;
@end

@implementation ChatController (Auto)

/* ---- a chat follows its model ---- */

/* Everything on a chat that depends on which model it uses. Call after provider and model have been set. */
- (void)modelDidChangeForChat:(NSMutableDictionary *)chat
{
    NSMutableDictionary *params = [[chat objectForKey:@"params"] isKindOfClass:[NSDictionary class]] ? [NSMutableDictionary dictionaryWithDictionary:[chat objectForKey:@"params"]] : nil;
    /* the last reading of how full the model's context was, and the limit remembered for the old model, belong to the old one */
    [chat removeObjectForKey:@"contextLimit"];
    [chat removeObjectForKey:@"ctxTokens"];
    [chat removeObjectForKey:@"ctxAt"];
    /* a longest answer that could not fit the new model's context is brought down to half of it */
    if ([params objectForKey:@"max_tokens"]) {
        int limit = [TBProviders contextLimitForModel:[chat objectForKey:@"model"]];
        if (limit > 0 && [[params objectForKey:@"max_tokens"] intValue] > limit / 2) {
            [params setObject:[NSNumber numberWithInt:limit / 2] forKey:@"max_tokens"];
            [chat setObject:params forKey:@"params"];
        }
    }
}

/* A chat whose model is not one its provider offers (a model that was withdrawn, a changed local server) is given the provider's default. */
- (void)reconcileModelOfChat:(NSMutableDictionary *)chat
{
    NSString *provider = [self providerForChat:chat];
    if (![self model:[chat objectForKey:@"model"] allowedForProvider:provider]) {
        [chat setObject:[self defaultModelForProvider:provider] forKey:@"model"];
        [self modelDidChangeForChat:chat];
    }
}

/* ---- picking the model ---- */

/* Auto appears in the provider list when Preferences say so, and always while it is the default for new chats. */
- (BOOL)autoListed
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"TigerBuildAutoListed"] || [self autoModelWanted];
}

- (void)autoListingChanged
{
    NSMenu *menu = [self modelMenu];
    if (menu)
        [self fillProviderMenu:menu];
    [self fillProviderPopup];
    [self syncModelMenu];
}

- (BOOL)autoModelWanted
{
    return [[[NSUserDefaults standardUserDefaults] stringForKey:@"TigerBuildNewChatModel"] isEqualToString:@"auto"];
}

- (NSString *)routerSelection
{
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"TigerBuildAutoRouter"];
    NSRange bar = [saved rangeOfString:@"|"];
    if (bar.location != NSNotFound && [self providerUsable:[saved substringToIndex:bar.location]])
        return saved;
    return nil;
}

/* Dollars for a million tokens in and a million out, or nil when unknown (and for local models). */
- (NSNumber *)millionTokenPrice:(NSString *)provider model:(NSString *)model
{
    if ([provider isEqualToString:@"local"])
        return nil;
    return [TBPricing costForProvider:provider model:model usage:[NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:1000000], @"input", [NSNumber numberWithInt:1000000], @"output", nil]];
}

/* The usable models, one per line: provider|model|name, vision and context size. */
- (NSArray *)routingCandidatesForChat:(NSDictionary *)chat
{
    NSMutableArray *rows = [NSMutableArray array];
    NSArray *providers = [[ModelCatalog shared] providers];
    BOOL onlyThis = [self chatHasAttachments:chat];
    unsigned i, j;
    for (i = 0; i < [providers count] && [rows count] < 800; i++) {
        NSString *pid = [[providers objectAtIndex:i] objectForKey:@"id"];
        NSArray *models;
        if (![self providerUsable:pid] || (onlyThis && ![pid isEqualToString:[self providerForChat:chat]]))
            continue;
        models = [pid isEqualToString:@"local"] ? localModels : [[ModelCatalog shared] modelsForProvider:pid];
        for (j = 0; j < [models count]; j++) {
            NSDictionary *model = [models objectAtIndex:j];
            NSString *mid = [model objectForKey:@"id"];
            [rows addObject:[NSDictionary dictionaryWithObjectsAndKeys:pid, @"provider", mid, @"model",
                [TBModelProfiles lineForProvider:pid model:mid title:[model objectForKey:@"title"] vision:[TBSession supportsImages:pid model:mid] context:[TBProviders contextLimitForModel:mid] price:[self millionTokenPrice:pid model:mid]], @"line", nil]];
        }
    }
    return rows;
}

/* ---- notes on every model, written in the background ---- */

- (NSArray *)allModelKeys
{
    NSMutableArray *keys = [NSMutableArray array];
    NSArray *providers = [[ModelCatalog shared] providers];
    unsigned i, j;
    for (i = 0; i < [providers count]; i++) {
        NSString *pid = [[providers objectAtIndex:i] objectForKey:@"id"];
        NSArray *models;
        if (![self providerUsable:pid])
            continue;
        models = [pid isEqualToString:@"local"] ? localModels : [[ModelCatalog shared] modelsForProvider:pid];
        for (j = 0; j < [models count]; j++)
            [keys addObject:[NSString stringWithFormat:@"%@|%@", pid, [[models objectAtIndex:j] objectForKey:@"id"]]];
    }
    return keys;
}

/* When auto mode is on and some usable models have no note, the chosen chooser writes them (30 at a time, at most once an hour). */
- (void)scheduleModelNotes
{
    NSString *router = [self routerSelection];
    NSArray *need;
    NSMutableString *prompt;
    NSMutableString *body;
    NSMutableArray *batch = [NSMutableArray array];
    unsigned i;
    if (![self autoModelWanted] || modelNotesBusy || !router || [[NSDate date] timeIntervalSince1970] - [TBModelProfiles lastRefresh] < 3600)
        return;
    need = [TBModelProfiles keysNeedingNotes:[self allModelKeys]];
    if (![need count])
        return;
    for (i = 0; i < [need count] && i < 15; i++)
        [batch addObject:[need objectAtIndex:i]];
    prompt = [NSMutableString string];
    for (i = 0; i < [batch count]; i++) {
        NSArray *parts = [[batch objectAtIndex:i] componentsSeparatedByString:@"|"];
        NSString *mid = [parts objectAtIndex:1];
        [prompt appendFormat:@"%@\n", [TBModelProfiles lineForProvider:[parts objectAtIndex:0] model:mid title:mid vision:[TBSession supportsImages:[parts objectAtIndex:0] model:mid]
            context:[TBProviders contextLimitForModel:mid] price:[self millionTokenPrice:[parts objectAtIndex:0] model:mid]]];
    }
    body = [NSMutableString stringWithString:@"{\"messages\":[{\"role\":\"user\",\"content\":\""];
    [body appendString:TBJSONEscape(prompt)];
    [body appendFormat:@"\"}],\"provider\":\"%@\",\"model\":\"%@\"}", TBJSONEscape([router substringToIndex:[router rangeOfString:@"|"].location]),
        TBJSONEscape([router substringFromIndex:[router rangeOfString:@"|"].location + 1])];
    modelNotesBusy = YES;
    [modelNotesAsked release];
    modelNotesAsked = [batch retain];
    [EngineRequest send:@"POST" path:@"/v1/profile" body:body timeout:240 target:self action:@selector(modelNotesArrived:) context:nil];
}

- (void)modelNotesArrived:(EngineRequest *)request
{
    modelNotesBusy = NO;
    [TBModelProfiles setLastRefresh:[[NSDate date] timeIntervalSince1970]];
    if ([request ok])
        [TBModelProfiles storeReply:[request text] asked:modelNotesAsked];
    else
        [TBModelProfiles storeReply:@"" asked:modelNotesAsked];
    [modelNotesAsked release];
    modelNotesAsked = nil;
}

/* Preferences, Update Model Notes Now */
- (IBAction)updateModelNotes:(id)sender
{
    (void)sender;
    [TBModelProfiles setLastRefresh:0];
    [self scheduleModelNotes];
}

/* Called from startTurn for a chat that is waiting for its model. YES when it took over (the turn continues in routeArrived:). */
- (BOOL)routeChatIfPending:(NSMutableDictionary *)chat
{
    NSArray *candidates;
    NSString *router = [self routerSelection], *first = nil;
    NSMutableString *prompt;
    NSMutableString *body;
    NSArray *messages = [chat objectForKey:@"messages"];
    unsigned i;
    if (![[chat objectForKey:@"autoPending"] boolValue])
        return NO;
    [chat removeObjectForKey:@"autoPending"];
    if (![self autoListed])
        return NO;
    if (!router)
        router = [NSString stringWithFormat:@"%@|%@", [self providerForChat:chat], [self modelForChat:chat]];
    candidates = [self routingCandidatesForChat:chat];
    if ([candidates count] < 2)
        return NO;
    for (i = (unsigned)[messages count]; i > 0 && !first; i--) {
        NSDictionary *message = [messages objectAtIndex:i - 1];
        if ([[message objectForKey:@"role"] isEqualToString:@"user"] && [[message objectForKey:@"text"] length] && ![message objectForKey:@"attachment"])
            first = [message objectForKey:@"text"];
    }
    if (!first)
        return NO;
    if ([first length] > 4000)
        first = [first substringToIndex:4000];
    prompt = [NSMutableString stringWithString:@"Models you can choose from (provider|model|description):\n"];
    for (i = 0; i < [candidates count]; i++)
        [prompt appendFormat:@"%@\n", [[candidates objectAtIndex:i] objectForKey:@"line"]];
    [prompt appendFormat:@"\n%@\n\nThe person's first message:\n%@", [self chatHasAttachments:chat] ? @"The person has attached files to this chat." : @"No files are attached.", first];
    body = [NSMutableString stringWithString:@"{\"messages\":[{\"role\":\"user\",\"content\":\""];
    [body appendString:TBJSONEscape(prompt)];
    [body appendFormat:@"\"}],\"tools\":false,\"provider\":\"%@\",\"model\":\"%@\"}", TBJSONEscape([router substringToIndex:[router rangeOfString:@"|"].location]),
        TBJSONEscape([router substringFromIndex:[router rangeOfString:@"|"].location + 1])];
    [autoCandidates release];
    autoCandidates = [candidates retain];
    [EngineRequest send:@"POST" path:@"/v1/route" body:body timeout:45 target:self action:@selector(routeArrived:) context:nil];
    return YES;
}

- (void)routeArrived:(EngineRequest *)request
{
    NSMutableDictionary *chat = [self chatWithId:streamingId];
    NSString *answer = [[[TBTrim([request text]) componentsSeparatedByString:@"\n"] objectAtIndex:0] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" `\"'*"]];
    unsigned i;
    if (!chat) {
        [self setBusy:NO];
        return;
    }
    if ([request ok]) {
        for (i = 0; i < [autoCandidates count]; i++) {
            NSDictionary *row = [autoCandidates objectAtIndex:i];
            NSString *key = [NSString stringWithFormat:@"%@|%@", [row objectForKey:@"provider"], [row objectForKey:@"model"]];
            if ([answer isEqualToString:key] || [answer hasPrefix:[key stringByAppendingString:@"|"]]) {
                [chat setObject:[row objectForKey:@"provider"] forKey:@"provider"];
                [chat setObject:[row objectForKey:@"model"] forKey:@"model"];
                [self modelDidChangeForChat:chat];
                break;
            }
        }
    }
    [autoCandidates release];
    autoCandidates = nil;
    if (chat == current) {
        [self syncModelMenu];
        [self rememberContextLimit];
        [self updateContextReadout];
    }
    [self rememberLastUsed];
    [self saveStore];
    if (![self startCompactionIfNeeded])
        [self beginChatStream];
}

@end
