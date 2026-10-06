/* Writes tiger-build/prices-seed.json: the token prices of the models in tiger-build/models.txt, from the LiteLLM price list.
   The app starts with this and refreshes the whole list itself once a day.
     clang -fobjc-exceptions -framework Foundation -I../tiger-build -o /tmp/make-prices make-prices.m ../tiger-build/TBJSON.m
     /tmp/make-prices [downloaded-price-list.json]        (run from the scripts folder; downloads the list with curl when none is given) */
#import <Foundation/Foundation.h>
#import "TBJSON.h"

static NSString *const kURL = @"https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json";

/* input_cost_per_token, output_cost_per_token, cache_read_input_token_cost, cache_creation_input_token_cost, each with an
   optional _above_<n>k_tokens: returns the field name and the tier (tokens), or nil */
static NSString *field(NSString *key, int *tier)
{
    NSString *base = key;
    NSRange above = [key rangeOfString:@"_above_"];
    *tier = 0;
    if (above.location != NSNotFound) {
        NSString *rest = [key substringFromIndex:NSMaxRange(above)];
        if (![rest hasSuffix:@"k_tokens"])
            return nil;
        *tier = [[rest substringToIndex:[rest length] - 8] intValue] * 1000;
        if (*tier == 0)
            return nil;
        base = [key substringToIndex:above.location];
    }
    if ([base isEqualToString:@"input_cost_per_token"]) return @"input";
    if ([base isEqualToString:@"output_cost_per_token"]) return @"output";
    if ([base isEqualToString:@"cache_read_input_token_cost"]) return @"cache_read_input";
    if ([base isEqualToString:@"cache_creation_input_token_cost"]) return @"cache_creation_input";
    return nil;
}

int main(int argc, char **argv)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *root = @"../tiger-build";
    NSData *raw;
    NSDictionary *all, *prefixes;
    NSMutableSet *wanted = [NSMutableSet set];
    NSMutableDictionary *rates = [NSMutableDictionary dictionary];
    NSArray *lines;
    NSEnumerator *names;
    NSString *name, *error = nil;
    unsigned i, p;
    if (argc > 1)
        raw = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]];
    else {
        NSTask *task = [[[NSTask alloc] init] autorelease];
        NSPipe *pipe = [NSPipe pipe];
        [task setLaunchPath:@"/usr/bin/curl"];
        [task setArguments:[NSArray arrayWithObjects:@"-fsSL", kURL, nil]];
        [task setStandardOutput:pipe];
        [task launch];
        raw = [[pipe fileHandleForReading] readDataToEndOfFile];
        [task waitUntilExit];
    }
    all = TBJSONParse(raw, &error);
    if (![all isKindOfClass:[NSDictionary class]]) {
        fprintf(stderr, "could not read the price list: %s\n", [error UTF8String]);
        return 1;
    }
    prefixes = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSArray arrayWithObjects:@"xai/", @"", nil], @"grok", [NSArray arrayWithObjects:@"", @"openai/", nil], @"chatgpt",
        [NSArray arrayWithObjects:@"", @"anthropic/", nil], @"claude", [NSArray arrayWithObjects:@"mistral/", @"", nil], @"mistral",
        [NSArray arrayWithObjects:@"meta_ai/", @"meta/", @"", nil], @"muse", [NSArray arrayWithObjects:@"gemini/", @"", nil], @"gemini", nil];
    lines = [[NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"models.txt"] encoding:NSUTF8StringEncoding error:NULL] componentsSeparatedByString:@"\n"];
    for (i = 0; i < [lines count]; i++) {
        NSArray *parts = [[lines objectAtIndex:i] componentsSeparatedByString:@"\t"];
        NSArray *list;
        if ([parts count] < 3 || ![[parts objectAtIndex:0] isEqualToString:@"model"])
            continue;
        list = [prefixes objectForKey:[parts objectAtIndex:1]];
        if (!list)
            list = [NSArray arrayWithObject:@""];
        for (p = 0; p < [list count]; p++)
            [wanted addObject:[[list objectAtIndex:p] stringByAppendingString:[parts objectAtIndex:2]]];
    }
    names = [all keyEnumerator];
    while ((name = [names nextObject])) {
        NSDictionary *row = [all objectForKey:name];
        NSMutableDictionary *fields = [NSMutableDictionary dictionary];
        NSEnumerator *keys;
        NSString *key;
        if (![wanted containsObject:name] || ![row isKindOfClass:[NSDictionary class]])
            continue;
        keys = [row keyEnumerator];
        while ((key = [keys nextObject])) {
            int tier;
            NSString *f = field(key, &tier);
            id value = [row objectForKey:key];
            if (!f || ![value isKindOfClass:[NSNumber class]])
                continue;
            if (![fields objectForKey:f])
                [fields setObject:[NSMutableDictionary dictionary] forKey:f];
            [[fields objectForKey:f] setObject:[NSNumber numberWithDouble:[value doubleValue]] forKey:[NSString stringWithFormat:@"%d", tier]];
        }
        if ([fields objectForKey:@"input"] && [fields objectForKey:@"output"])
            [rates setObject:fields forKey:name];
    }
    [TBJSONData([NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithDouble:[[NSDate date] timeIntervalSince1970]], @"at", rates, @"rates", nil])
        writeToFile:[root stringByAppendingPathComponent:@"prices-seed.json"] atomically:YES];
    printf("%u models priced\n", (unsigned)[rates count]);
    [pool release];
    return 0;
}
