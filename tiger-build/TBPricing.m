#import "TBPricing.h"
#import "TBEngine.h"
#import "TBJSON.h"
#import "TBHTTP.h"

static NSDictionary *rates = nil;
static NSMutableDictionary *liveContexts = nil;
static BOOL started = NO;
static NSString *priceURL = @"https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json";

static NSString *cachePath(void)
{
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Tiger Build/pricing-cache.json"];
}

/* Keeps only the token rates: {name: {field: {tier: rate}}}. */
static NSDictionary *compact(NSDictionary *raw)
{
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSEnumerator *names = [raw keyEnumerator];
    NSString *name;
    while ((name = [names nextObject])) {
        NSDictionary *row = [raw objectForKey:name];
        NSMutableDictionary *fields = [NSMutableDictionary dictionary];
        NSEnumerator *keys;
        NSString *key;
        if (![row isKindOfClass:[NSDictionary class]])
            continue;
        keys = [row keyEnumerator];
        while ((key = [keys nextObject])) {
            NSString *field = nil;
            NSString *rest = nil;
            id value = [row objectForKey:key];
            long long tier = 0;
            NSRange above;
            if (![value isKindOfClass:[NSNumber class]] || (CFBooleanRef)value == kCFBooleanTrue || (CFBooleanRef)value == kCFBooleanFalse)
                continue;
            above = [key rangeOfString:@"_above_"];
            rest = above.location == NSNotFound ? key : [key substringToIndex:above.location];
            if ([rest isEqualToString:@"input_cost_per_token"])
                field = @"input";
            else if ([rest isEqualToString:@"output_cost_per_token"])
                field = @"output";
            else if ([rest isEqualToString:@"cache_read_input_token_cost"])
                field = @"cache_read_input";
            else if ([rest isEqualToString:@"cache_creation_input_token_cost"])
                field = @"cache_creation_input";
            if (!field)
                continue;
            if (above.location != NSNotFound) {
                NSString *tail = [key substringFromIndex:above.location + above.length];
                if (![tail hasSuffix:@"k_tokens"])
                    continue;
                tier = strtoll([[tail substringToIndex:[tail length] - 8] UTF8String], NULL, 10) * 1000;
            }
            {
                NSMutableDictionary *tiers = [fields objectForKey:field];
                if (!tiers) {
                    tiers = [NSMutableDictionary dictionary];
                    [fields setObject:tiers forKey:field];
                }
                [tiers setObject:value forKey:[NSString stringWithFormat:@"%lld", tier]];
            }
        }
        if ([fields objectForKey:@"input"] && [fields objectForKey:@"output"])
            [out setObject:fields forKey:name];
    }
    return out;
}

static void install(NSDictionary *newRates, double stamp)
{
    NSDictionary *blob;
    NSData *data;
    if ([newRates count] == 0)
        return;
    @synchronized([TBPricing class]) {
        [rates release];
        rates = [newRates retain];
    }
    blob = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithDouble:stamp], @"at", newRates, @"rates", nil];
    data = TBJSONData(blob);
    [[NSFileManager defaultManager] createDirectoryAtPath:[cachePath() stringByDeletingLastPathComponent] attributes:nil];
    [data writeToFile:cachePath() atomically:YES];
}

@implementation TBPricing

+ (void)refresh:(id)unused
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    @try {
        TBHTTP *http = [TBHTTP request:@"GET" url:priceURL];
        id raw;
        [http setIdleTimeout:60];
        if ([http perform] == 0 && [http status] == 200) {
            raw = TBJSONParse([http data], NULL);
            if ([raw isKindOfClass:[NSDictionary class]])
                install(compact(raw), [[NSDate date] timeIntervalSince1970]);
        }
    } @catch (NSException *e) {
    }
    [pool release];
}

+ (void)start
{
    NSData *data;
    id blob;
    double at = 0;
    if (started)
        return;
    started = YES;
    liveContexts = [[NSMutableDictionary alloc] init];
    data = [NSData dataWithContentsOfFile:cachePath()];
    blob = data ? TBJSONParse(data, NULL) : nil;
    if (![TBDictionary(blob, @"rates") count]) {
        data = [NSData dataWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"prices-seed" ofType:@"json"]];
        blob = data ? TBJSONParse(data, NULL) : nil;
    }
    if ([TBDictionary(blob, @"rates") count]) {
        rates = [TBDictionary(blob, @"rates") retain];
        at = [[blob objectForKey:@"at"] doubleValue];
    }
    if ([[NSDate date] timeIntervalSince1970] - at > 24 * 3600 || [rates count] < 20)
        [NSThread detachNewThreadSelector:@selector(refresh:) toTarget:self withObject:nil];
}

static NSDictionary *findRow(NSString *provider, NSString *model)
{
    NSArray *prefixes;
    NSDictionary *table;
    unsigned i;
    if ([provider isEqualToString:@"local"] || [model length] == 0)
        return nil;
    @synchronized([TBPricing class]) {
        table = [[rates retain] autorelease];
    }
    if ([provider isEqualToString:@"grok"])
        prefixes = [NSArray arrayWithObjects:@"xai/", @"", nil];
    else if ([provider isEqualToString:@"chatgpt"])
        prefixes = [NSArray arrayWithObjects:@"", @"openai/", nil];
    else if ([provider isEqualToString:@"claude"])
        prefixes = [NSArray arrayWithObjects:@"", @"anthropic/", nil];
    else if ([provider isEqualToString:@"mistral"])
        prefixes = [NSArray arrayWithObjects:@"mistral/", @"", nil];
    else if ([provider isEqualToString:@"muse"])
        prefixes = [NSArray arrayWithObjects:@"meta_ai/", @"meta/", @"", nil];
    else if ([provider isEqualToString:@"gemini"])
        prefixes = [NSArray arrayWithObjects:@"gemini/", @"", nil];
    else
        prefixes = [NSArray arrayWithObject:@""];
    for (i = 0; i < [prefixes count]; i++) {
        NSDictionary *row = [table objectForKey:[[prefixes objectAtIndex:i] stringByAppendingString:model]];
        if (row)
            return row;
    }
    return nil;
}

/* Per-token rate for a field at this prompt size: the highest tier reached. */
static double rate(NSDictionary *row, NSString *field, long long prompt)
{
    NSDictionary *tiers = [row objectForKey:field];
    NSEnumerator *keys;
    NSString *threshold;
    long long bestThreshold = -1;
    double best = 0;
    if (!tiers) {
        if ([field isEqualToString:@"cache_read_input"] || [field isEqualToString:@"cache_creation_input"])
            return rate(row, @"input", prompt);
        return 0;
    }
    keys = [tiers keyEnumerator];
    while ((threshold = [keys nextObject])) {
        long long t = strtoll([threshold UTF8String], NULL, 10);
        if (t < prompt && t > bestThreshold) {
            bestThreshold = t;
            best = [[tiers objectForKey:threshold] doubleValue];
        }
    }
    if (bestThreshold < 0)
        return [[tiers objectForKey:@"0"] doubleValue];
    return best;
}

+ (NSNumber *)costForProvider:(NSString *)provider model:(NSString *)model usage:(NSDictionary *)usage
{
    NSDictionary *row = findRow(provider, model);
    long long input, cached, written, output, prompt;
    if (!row)
        return nil;
    input = TBInteger(usage, @"input");
    cached = TBInteger(usage, @"cached");
    written = TBInteger(usage, @"written");
    output = TBInteger(usage, @"output");
    prompt = input + cached + written;
    return [NSNumber numberWithDouble:input * rate(row, @"input", prompt) + cached * rate(row, @"cache_read_input", prompt)
        + written * rate(row, @"cache_creation_input", prompt) + output * rate(row, @"output", prompt)];
}

+ (int)liveContextForProvider:(NSString *)provider model:(NSString *)model
{
    NSNumber *n;
    if (!liveContexts)
        return 0;
    @synchronized(liveContexts) {
        n = [liveContexts objectForKey:[NSString stringWithFormat:@"%@/%@", provider, model]];
    }
    return n ? [n intValue] : 0;
}

+ (void)setLiveContext:(int)tokens forProvider:(NSString *)provider model:(NSString *)model
{
    if (!liveContexts)
        liveContexts = [[NSMutableDictionary alloc] init];
    @synchronized(liveContexts) {
        [liveContexts setObject:[NSNumber numberWithInt:tokens] forKey:[NSString stringWithFormat:@"%@/%@", provider, model]];
    }
}

@end
