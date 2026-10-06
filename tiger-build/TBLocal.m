#import "TBLocal.h"
#import "TBEngine.h"
#import "TBHTTP.h"
#import "TBJSON.h"
#import "TBProviders.h"

static NSMutableArray *cachedList = nil;
static NSDate *cachedAt = nil;
static NSMutableDictionary *ollamaContexts = nil;

static id getJSON(NSString *url, double timeout)
{
    TBHTTP *http = [TBHTTP request:@"GET" url:url];
    NSString *key = [TBSettings keyForProvider:@"local"];
    [http setHeader:@"User-Agent" value:@"TigerBuild/2.0"];
    if ([key length])
        [http setHeader:@"Authorization" value:[@"Bearer " stringByAppendingString:key]];
    [http setIdleTimeout:(int)timeout];
    [http setConnectTimeout:(int)timeout];
    if ([http perform] != 0 || [http status] != 200)
        return nil;
    return TBJSONParse([http data], NULL);
}

static id postJSON(NSString *url, id body, double timeout)
{
    TBHTTP *http = [TBHTTP request:@"POST" url:url];
    [http setHeader:@"Content-Type" value:@"application/json"];
    [http setHeader:@"User-Agent" value:@"TigerBuild/2.0"];
    [http setBody:TBJSONData(body)];
    [http setIdleTimeout:(int)timeout];
    [http setConnectTimeout:(int)timeout];
    if ([http perform] != 0 || [http status] != 200)
        return nil;
    return TBJSONParse([http data], NULL);
}

/* Ollama has no /api/v0/models. A loaded model reports the length it was loaded with; the others, the most they allow. */
static NSDictionary *ollamaLimits(NSString *origin, NSArray *names)
{
    NSMutableDictionary *limits = [NSMutableDictionary dictionary];
    NSArray *loaded = TBArray(getJSON([origin stringByAppendingString:@"/api/ps"], 3), @"models");
    unsigned i;
    if (!ollamaContexts)
        ollamaContexts = [[NSMutableDictionary alloc] init];
    for (i = 0; i < [loaded count]; i++) {
        NSDictionary *item = [loaded objectAtIndex:i];
        long long length = TBInteger(item, @"context_length");
        NSString *name = [TBString(item, @"name") length] ? TBString(item, @"name") : TBString(item, @"model");
        if (length && [name length])
            [limits setObject:[NSNumber numberWithLongLong:length] forKey:name];
    }
    for (i = 0; i < [names count]; i++) {
        NSString *name = [names objectAtIndex:i];
        NSNumber *known;
        if ([limits objectForKey:name])
            continue;
        @synchronized(ollamaContexts) {
            known = [ollamaContexts objectForKey:name];
        }
        if (!known) {
            id info = postJSON([origin stringByAppendingString:@"/api/show"], [NSDictionary dictionaryWithObject:name forKey:@"model"], 3);
            NSDictionary *details = TBDictionary(info, @"model_info");
            NSEnumerator *keys = [details keyEnumerator];
            NSString *key;
            long long length = 0;
            while ((key = [keys nextObject])) {
                if ([key hasSuffix:@".context_length"])
                    length = TBInteger(details, key);
            }
            if (length) {
                known = [NSNumber numberWithLongLong:length];
                @synchronized(ollamaContexts) {
                    [ollamaContexts setObject:known forKey:name];
                }
            }
        }
        if (known)
            [limits setObject:known forKey:name];
    }
    return limits;
}

@implementation TBLocal

+ (NSArray *)modelsWithTimeout:(double)seconds
{
    NSString *base = [TBProviders localBase];
    NSString *origin;
    NSArray *v0, *v1;
    NSMutableDictionary *limits = [NSMutableDictionary dictionary];
    NSMutableSet *skip = [NSMutableSet set];
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableArray *models = [NSMutableArray array];
    NSArray *source;
    unsigned i;
    if ([base length] == 0)
        TBFail(@"No local model server is set up.");
    origin = [base hasSuffix:@"/v1"] ? [base substringToIndex:[base length] - 3] : base;
    v0 = TBArray(getJSON([origin stringByAppendingString:@"/api/v0/models"], seconds), @"data");
    v1 = TBArray(getJSON([base stringByAppendingString:@"/models"], seconds), @"data");
    for (i = 0; i < [v0 count]; i++) {
        NSDictionary *item = [v0 objectAtIndex:i];
        NSString *mid = TBString(item, @"id");
        if ([mid length] == 0)
            continue;
        if ([[TBString(item, @"type") lowercaseString] isEqualToString:@"embeddings"] || [[mid lowercaseString] rangeOfString:@"embed"].location != NSNotFound) {
            [skip addObject:mid];
            continue;
        }
        [limits setObject:[NSNumber numberWithLongLong:TBInteger(item, @"max_context_length")] forKey:mid];
    }
    if ([v1 count]) {
        source = v1;
    } else {
        NSMutableArray *fromLimits = [NSMutableArray array];
        NSEnumerator *keys = [limits keyEnumerator];
        NSString *key;
        while ((key = [keys nextObject]))
            [fromLimits addObject:[NSDictionary dictionaryWithObject:key forKey:@"id"]];
        source = fromLimits;
    }
    for (i = 0; i < [source count]; i++) {
        NSString *mid = TBString([source objectAtIndex:i], @"id");
        NSString *title;
        NSRange slash;
        if ([mid length] == 0 || [skip containsObject:mid] || [seen containsObject:mid] || [[mid lowercaseString] rangeOfString:@"embed"].location != NSNotFound)
            continue;
        [seen addObject:mid];
        slash = [mid rangeOfString:@"/" options:NSBackwardsSearch];
        title = slash.location == NSNotFound ? mid : [mid substringFromIndex:slash.location + 1];
        [models addObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:mid, @"id", [NSNumber numberWithLongLong:[[limits objectForKey:mid] longLongValue] ? [[limits objectForKey:mid] longLongValue] : 32768], @"context",
            [title length] ? title : mid, @"title", nil]];
    }
    if ([models count] && [v0 count] == 0) {
        NSMutableArray *names = [NSMutableArray array];
        NSDictionary *real;
        for (i = 0; i < [models count]; i++)
            [names addObject:TBString([models objectAtIndex:i], @"id")];
        real = ollamaLimits(origin, names);
        for (i = 0; i < [models count]; i++) {
            NSNumber *length = [real objectForKey:TBString([models objectAtIndex:i], @"id")];
            if (length)
                [[models objectAtIndex:i] setObject:length forKey:@"context"];
        }
    }
    if ([models count] == 0 && [v0 count] == 0 && [v1 count] == 0)
        TBFail(@"Cannot reach the local model server.");
    return models;
}

+ (NSArray *)cachedModels
{
    NSArray *models;
    @synchronized(self) {
        if (cachedList && cachedAt && -[cachedAt timeIntervalSinceNow] < 30)
            return [[cachedList retain] autorelease];
    }
    @try {
        models = [self modelsWithTimeout:8];
    } @catch (NSException *e) {
        @synchronized(self) {
            return [[cachedList retain] autorelease];
        }
    }
    @synchronized(self) {
        [cachedList release];
        cachedList = [[NSMutableArray arrayWithArray:models] retain];
        [cachedAt release];
        cachedAt = [[NSDate date] retain];
    }
    return models;
}

+ (NSString *)modelsText
{
    NSArray *models;
    NSMutableArray *lines = [NSMutableArray array];
    unsigned i;
    @try {
        models = [self modelsWithTimeout:8];
    } @catch (NSException *e) {
        @synchronized(self) {
            [cachedList release];
            cachedList = [[NSMutableArray array] retain];
            [cachedAt release];
            cachedAt = [[NSDate date] retain];
        }
        return [NSString stringWithFormat:@"error\t%@\n", [e reason]];
    }
    @synchronized(self) {
        [cachedList release];
        cachedList = [[NSMutableArray arrayWithArray:models] retain];
        [cachedAt release];
        cachedAt = [[NSDate date] retain];
    }
    for (i = 0; i < [models count]; i++) {
        NSDictionary *item = [models objectAtIndex:i];
        [lines addObject:[NSString stringWithFormat:@"%@\t%lld\t%@", TBString(item, @"id"), TBInteger(item, @"context"), TBString(item, @"title")]];
    }
    return [lines count] ? [[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] : @"";
}

+ (NSString *)status
{
    NSArray *models;
    if ([[TBProviders localBase] length] == 0)
        return @"unset";
    @try {
        models = [self modelsWithTimeout:2];
    } @catch (NSException *e) {
        return @"offline";
    }
    return [models count] ? [NSString stringWithFormat:@"ok %u", (unsigned)[models count]] : @"empty";
}

+ (int)contextForModel:(NSString *)model
{
    NSArray *models = [self cachedModels];
    unsigned i;
    for (i = 0; i < [models count]; i++) {
        if ([TBString([models objectAtIndex:i], @"id") isEqualToString:model])
            return (int)TBInteger([models objectAtIndex:i], @"context");
    }
    return 32000;
}

@end
