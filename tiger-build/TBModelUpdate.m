#import "TBModelUpdate.h"
#import "TBEngine.h"
#import "TBHTTP.h"
#import "TBJSON.h"
#import "TBProviders.h"
#import "TBSession.h"

#define PROBE_LIMIT 12
#define RETRY_AFTER (7 * 24 * 3600.0)

static BOOL hasAny(NSString *id, NSArray *words)
{
    unsigned i;
    for (i = 0; i < [words count]; i++)
        if ([id rangeOfString:[words objectAtIndex:i]].location != NSNotFound)
            return YES;
    return NO;
}

/* A name that is only a dated copy of another model (gpt-5-2025-08-07, claude-x-20251001, mistral-large-2411) */
static BOOL datedSnapshot(NSString *id)
{
    NSArray *parts = [id componentsSeparatedByString:@"-"];
    NSString *last = [parts lastObject];
    unsigned i;
    BOOL digits = [last length] >= 4;
    for (i = 0; i < [last length] && digits; i++)
        if ([last characterAtIndex:i] < '0' || [last characterAtIndex:i] > '9')
            digits = NO;
    if (digits)
        return YES;
    /* gpt-4o-2024-08-06: year, month and day as three parts */
    if ([parts count] >= 3) {
        NSString *a = [parts objectAtIndex:[parts count] - 3], *b = [parts objectAtIndex:[parts count] - 2];
        if ([a length] == 4 && [b length] == 2 && [a intValue] > 2000 && [last length] == 2)
            return YES;
    }
    return NO;
}

/* Where each service lists its models (TBModelsURL.<service> replaces it, for tests) */
static NSString *listURL(NSString *provider)
{
    NSString *over = [[NSUserDefaults standardUserDefaults] stringForKey:[@"TBModelsURL." stringByAppendingString:provider]];
    if ([over length])
        return over;
    if ([provider isEqualToString:@"chatgpt"]) return @"https://api.openai.com/v1/models";
    if ([provider isEqualToString:@"claude"]) return @"https://api.anthropic.com/v1/models?limit=100";
    if ([provider isEqualToString:@"gemini"]) return @"https://generativelanguage.googleapis.com/v1beta/models?pageSize=200";
    if ([provider isEqualToString:@"mistral"]) return @"https://api.mistral.ai/v1/models";
    if ([provider isEqualToString:@"grok"]) return @"https://api.x.ai/v1/models";
    if ([provider isEqualToString:@"muse"]) return @"https://api.meta.ai/v1/models";
    return nil;
}

@implementation TBModelUpdate

+ (NSArray *)candidatesFromList:(id)json provider:(NSString *)provider
{
    NSMutableArray *out = [NSMutableArray array];
    NSArray *items = [json isKindOfClass:[NSDictionary class]] ? ([json objectForKey:@"data"] ? [json objectForKey:@"data"] : [json objectForKey:@"models"]) : nil;
    NSArray *noise = [NSArray arrayWithObjects:@"embed", @"whisper", @"tts", @"audio", @"realtime", @"image", @"imagen", @"dall", @"moderation", @"transcribe", @"instruct", @"davinci", @"babbage",
        @"preview", @"-exp", @"aqa", @"ocr", @"imagine", @"video", @"live", @"computer-use", @"search", @"banana", @"vibe", @"labs-", @"zai-", @"glm", @"robotics", @"-tts", @"guard", nil];
    unsigned i;
    if (![items isKindOfClass:[NSArray class]])
        return out;
    for (i = 0; i < [items count]; i++) {
        NSDictionary *item = [items objectAtIndex:i];
        NSString *mid, *title;
        if (![item isKindOfClass:[NSDictionary class]])
            continue;
        mid = TBString(item, @"id");
        if ([mid length] == 0 && [TBString(item, @"name") hasPrefix:@"models/"])
            mid = [TBString(item, @"name") substringFromIndex:7];
        if ([mid length] == 0 || hasAny([mid lowercaseString], noise) || datedSnapshot(mid))
            continue;
        if ([provider isEqualToString:@"chatgpt"] && !([mid hasPrefix:@"gpt-"] || [mid hasPrefix:@"chatgpt-"] || ([mid length] > 1 && [mid characterAtIndex:0] == 'o' && [mid characterAtIndex:1] >= '0' && [mid characterAtIndex:1] <= '9')))
            continue;
        if ([provider isEqualToString:@"grok"] && ![mid hasPrefix:@"grok"])
            continue;
        if ([provider isEqualToString:@"claude"] && ![mid hasPrefix:@"claude"])
            continue;
        if ([provider isEqualToString:@"gemini"]) {
            NSArray *methods = TBArray(item, @"supportedGenerationMethods");
            if (![mid hasPrefix:@"gemini"] || ([methods count] && ![methods containsObject:@"generateContent"]))
                continue;
        }
        if ([provider isEqualToString:@"mistral"] && [[item objectForKey:@"capabilities"] isKindOfClass:[NSDictionary class]] && !TBTruth([item objectForKey:@"capabilities"], @"completion_chat"))
            continue;
        title = TBString(item, @"display_name");
        if ([title length] == 0)
            title = TBString(item, @"displayName");
        (void)title;
        [out addObject:[NSDictionary dictionaryWithObjectsAndKeys:mid, @"id", TBModelTitleFor(provider, mid), @"title", nil]];
    }
    return out;
}

+ (id)fetch:(NSString *)provider problem:(NSString **)problem
{
    NSString *url = listURL(provider), *key = [TBSettings keyForProvider:provider];
    TBHTTP *http;
    if (!url || [key length] == 0)
        return nil;
    http = [TBHTTP request:@"GET" url:url];
    [http setHeader:@"User-Agent" value:@"TigerBuild/2.7"];
    if ([provider isEqualToString:@"claude"]) {
        [http setHeader:@"x-api-key" value:key];
        [http setHeader:@"anthropic-version" value:@"2023-06-01"];
        if ([[TBSettings valueForName:@"anthropic_workspace_id"] length])
            [http setHeader:@"anthropic-workspace-id" value:[TBSettings valueForName:@"anthropic_workspace_id"]];
    } else if ([provider isEqualToString:@"gemini"])
        [http setHeader:@"x-goog-api-key" value:key];
    else
        [http setHeader:@"Authorization" value:[@"Bearer " stringByAppendingString:key]];
    [http setIdleTimeout:20];
    [http setConnectTimeout:15];
    if ([http perform] != 0) {
        if (problem)
            *problem = [http error] ? [http error] : @"no answer";
        return nil;
    }
    if ([http status] != 200) {
        if (problem)
            *problem = [NSString stringWithFormat:@"the service answered %d", [http status]];
        return nil;
    }
    return TBJSONParse([http data], NULL);
}

+ (NSString *)refreshWithSession:(TBSession *)session
{
    NSString *path = [TBProviders liveModelsPath];
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:path];
    NSMutableDictionary *probed = [NSMutableDictionary dictionaryWithDictionary:[[saved objectForKey:@"probed"] isKindOfClass:[NSDictionary class]] ? [saved objectForKey:@"probed"] : [NSDictionary dictionary]];
    NSMutableDictionary *added = [NSMutableDictionary dictionary], *gone = [NSMutableDictionary dictionary];
    NSMutableArray *lines = [NSMutableArray array];
    NSArray *providers = [TBProviders providers];
    double now = [[NSDate date] timeIntervalSince1970];
    unsigned i, j;
    for (i = 0; i < [providers count]; i++) {
        NSString *pid = TBString([providers objectAtIndex:i], @"id");
        NSString *name = TBString([providers objectAtIndex:i], @"title");
        NSMutableSet *known = [NSMutableSet set];
        NSArray *bundled = [TBProviders bundledModelsForProvider:pid], *candidates;
        NSMutableArray *fresh = [NSMutableArray array], *kept = [NSMutableArray array];
        NSMutableArray *newNames = [NSMutableArray array];
        id json;
        int tried = 0, checkedGone = 0;
        NSString *reason = nil;
        if ([pid isEqualToString:@"local"] || !listURL(pid) || ![TBSettings hasKeyForProvider:pid])
            continue;
        json = [self fetch:pid problem:&reason];
        if (!json) {
            /* the service could not be asked: what was found before stays */
            NSArray *before = [[saved objectForKey:@"added"] objectForKey:pid];
            if ([before count])
                [added setObject:before forKey:pid];
            if ([[[saved objectForKey:@"gone"] objectForKey:pid] count])
                [gone setObject:[[saved objectForKey:@"gone"] objectForKey:pid] forKey:pid];   /* unknown now: what was decided before stays */
            [lines addObject:[NSString stringWithFormat:@"%@: could not get its list (%@)", name, reason ? reason : @"unreadable answer"]];
            continue;
        }
        for (j = 0; j < [bundled count]; j++)
            [known addObject:TBString([bundled objectAtIndex:j], @"id")];
        candidates = [[self candidatesFromList:json provider:pid] sortedArrayUsingDescriptors:[NSArray arrayWithObject:[[[NSSortDescriptor alloc] initWithKey:@"id" ascending:NO] autorelease]]];
        for (j = 0; j < [bundled count]; j++)
            [known addObject:TBModelFamilyKey(TBString([bundled objectAtIndex:j], @"id"))];
        for (j = 0; j < [candidates count]; j++) {
            NSString *family = TBModelFamilyKey(TBString([candidates objectAtIndex:j], @"id"));
            if (![known containsObject:TBString([candidates objectAtIndex:j], @"id")] && ![known containsObject:family]) {
                [known addObject:family];      /* 3.5 and 3-5, or a -latest alias of one already taken, are one model */
                [fresh addObject:[candidates objectAtIndex:j]];
            }
        }
        for (j = 0; j < [fresh count]; j++) {
            NSDictionary *model = [fresh objectAtIndex:j];
            NSString *key = [NSString stringWithFormat:@"%@|%@", pid, TBString(model, @"id")];
            NSDictionary *before = [probed objectForKey:key];
            BOOL ok;
            if (before && (TBTruth(before, @"ok") || now - [TBValue(before, @"at") doubleValue] < RETRY_AFTER)) {
                ok = TBTruth(before, @"ok");
            } else if (tried >= PROBE_LIMIT) {
                continue;
            } else {
                tried++;
                ok = YES;
                @try {
                    [session completeProvider:pid model:TBString(model, @"id") system:@"Reply with the single word OK."
                        messages:[NSArray arrayWithObject:[NSDictionary dictionaryWithObjectsAndKeys:@"user", @"role", @"Hello", @"content", nil]]];
                } @catch (NSException *failed) {
                    if ([[failed name] isEqualToString:TBStoppedException])
                        @throw;
                    ok = NO;
                }
                [probed setObject:[NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithBool:ok], @"ok", [NSNumber numberWithDouble:now], @"at", nil] forKey:key];
            }
            if (ok) {
                [kept addObject:model];
                [newNames addObject:TBString(model, @"id")];
            }
        }
        /* Bundled models the service's list no longer has: tried once; one that really fails is hidden, and stays hidden for as long as the list leaves it out */
        {
            NSMutableSet *listed = [NSMutableSet set];
            NSMutableArray *missing = [NSMutableArray array];
            NSArray *items = [json isKindOfClass:[NSDictionary class]] ? ([json objectForKey:@"data"] ? [json objectForKey:@"data"] : [json objectForKey:@"models"]) : nil;
            NSArray *before = [[[saved objectForKey:@"gone"] objectForKey:pid] isKindOfClass:[NSArray class]] ? [[saved objectForKey:@"gone"] objectForKey:pid] : [NSArray array];
            unsigned k;
            for (k = 0; k < [items count]; k++) {
                NSString *mid = [[items objectAtIndex:k] isKindOfClass:[NSDictionary class]] ? TBString([items objectAtIndex:k], @"id") : @"";
                if ([mid length] == 0 && [[[items objectAtIndex:k] isKindOfClass:[NSDictionary class]] ? TBString([items objectAtIndex:k], @"name") : @"" hasPrefix:@"models/"])
                    mid = [TBString([items objectAtIndex:k], @"name") substringFromIndex:7];
                [listed addObject:mid];
            }
            if ([listed count] >= 3) {      /* a list too short to trust (an error page, a partial answer) hides nothing */
                for (k = 0; k < [bundled count]; k++) {
                    NSString *mid = TBString([bundled objectAtIndex:k], @"id");
                    if (![listed containsObject:mid] && ![mid isEqualToString:[TBProviders defaultModelForProvider:pid]])
                        [missing addObject:mid];
                }
                for (k = 0; k < [missing count]; k++) {
                    NSString *mid = [missing objectAtIndex:k];
                    BOOL dead = NO;
                    if ([before containsObject:mid])
                        dead = YES;
                    else if (checkedGone < 40) {
                        checkedGone++;
                        @try {
                            [session completeProvider:pid model:mid system:@"Reply with the single word OK."
                                messages:[NSArray arrayWithObject:[NSDictionary dictionaryWithObjectsAndKeys:@"user", @"role", @"Hello", @"content", nil]]];
                        } @catch (NSException *failed) {
                            if ([[failed name] isEqualToString:TBStoppedException])
                                @throw;
                            dead = YES;
                        }
                    }
                    if (dead) {
                        if (![gone objectForKey:pid])
                            [gone setObject:[NSMutableArray array] forKey:pid];
                        [[gone objectForKey:pid] addObject:mid];
                    }
                }
            }
        }
        [TBProviders setGoneModels:[gone objectForKey:pid] forProvider:pid];
        if ([kept count])
            [added setObject:kept forKey:pid];
        {
            NSString *news = [kept count] ? [NSString stringWithFormat:@"%u new (%@%@)", (unsigned)[kept count], [[newNames subarrayWithRange:NSMakeRange(0, [newNames count] > 4 ? 4 : [newNames count])] componentsJoinedByString:@", "],
                [newNames count] > 4 ? [NSString stringWithFormat:@", and %u more", (unsigned)[newNames count] - 4] : @""] : @"no new models";
            unsigned goneCount = (unsigned)[[gone objectForKey:pid] count];
            [lines addObject:[NSString stringWithFormat:@"%@: %@%@", name, news, goneCount ? [NSString stringWithFormat:@"; %u withdrawn", goneCount] : @""]];
        }
        [TBProviders setAddedModels:kept forProvider:pid];
    }
    {
        NSDictionary *file = [NSDictionary dictionaryWithObjectsAndKeys:added, @"added", gone, @"gone", probed, @"probed", [NSNumber numberWithDouble:now], @"at", nil];
        TBMakePath([path stringByDeletingLastPathComponent]);
        [file writeToFile:path atomically:YES];
    }
    return [lines count] ? [lines componentsJoinedByString:@"\n"] : @"No service with a key to ask.";
}

@end
