#import "TBSession.h"
#import "TBIntegrations.h"
#import "TBSSH.h"
#import "TBExtras.h"
#import "TBOutputs.h"
#import "TBJSON.h"
#import "TBHTTP.h"
#import "TBPricing.h"
#import "TBLocal.h"

static NSString *const kSystem = @"You are an assistant chatting inside Tiger Build on {machine} running "
    "{os}. You have ppc-commander tools that read files, "
    "edit files, and run shell commands on that Mac. Use them when "
    "the person asks about that computer or wants something done there. "
    "Do not use them for ordinary questions. "
    "Finish the task in this turn. Do not stop halfway, and do not ask the "
    "person to type continue, even if an earlier message did. Write a whole file in one call, then compile "
    "or test. Use timeout_ms of 15000, or 20000 for a compile. "
    "You may launch GUI applications when the person asks. For a GUI, or anything "
    "that should keep running, call start_process with detach set to true so it "
    "is not tied to this chat. Use open for a Mac .app. "
    "The shell is bash and the system Python is 2.3. "
    "After the tools finish, answer in a few plain sentences.";
static BOOL truthyValue(id v);
static BOOL mentionsWord(NSString *line, NSString *word);
static NSString *const kLimitNote = @"\n\n[The reply stopped here because the model reached its output limit. Say \"continue\" and it will pick up where it left off.]";
static NSString *const kStepNote = @"\n\n[Stopped after %d tool steps in one turn. Say \"continue\" to keep going.]";
static NSString *const kConsultTool = @"consult_model";
static NSString *const kScreenshotTool = @"take_screenshot";
static const double kCompactAt = 0.80;

@interface TBSession (Private)
- (void)emit:(NSString *)kind text:(NSString *)text;
- (NSArray *)commanderDefinitions;
- (NSString *)composeSystemForTools:(NSMutableArray *)tools useTools:(BOOL)useTools provider:(NSString *)provider skip:(NSSet *)skip;
- (NSDictionary *)runOneCall:(NSDictionary *)call provider:(NSString *)provider;
- (NSArray *)extraDefinitionsForProvider:(NSString *)provider skip:(NSSet *)skip;
- (void)closeExtras;
- (NSArray *)mediaToolsForProvider:(NSString *)provider;
- (void)runForeignProvider:(NSString *)provider messages:(NSArray *)messages system:(NSString *)system tools:(NSArray *)tools model:(NSString *)model;
- (void)runGrokMessages:(NSArray *)messages system:(NSString *)system tools:(NSArray *)tools model:(NSString *)model bare:(BOOL)bare;
- (NSDictionary *)executeCall:(NSDictionary *)call provider:(NSString *)provider;
- (NSString *)compactLog:(NSMutableArray *)log provider:(NSString *)provider model:(NSString *)model;
- (NSDictionary *)runMediaCall:(NSString *)name arguments:(NSDictionary *)args provider:(NSString *)provider;
- (NSString *)consult:(NSDictionary *)args;
- (BOOL)extraHandles:(NSString *)name;
- (NSDictionary *)runExtraCall:(NSString *)name arguments:(NSDictionary *)args;
- (void)turn:(NSArray *)incoming useTools:(BOOL)useTools provider:(NSString *)provider model:(NSString *)requested systemOverride:(NSString *)override;
- (NSString *)stoppedEarlyOutput:(NSString *)output reason:(NSString *)reason;
- (NSDictionary *)screenshotNoteForProvider:(NSString *)provider model:(NSString *)model images:(NSArray *)images;
- (int)contextLimitForProvider:(NSString *)provider model:(NSString *)model;
- (NSString *)usageEventForProvider:(NSString *)provider model:(NSString *)model usage:(NSDictionary *)usage;
- (NSArray *)takeGuidanceNotes;
@end

/* Passes a round's text and thinking on as frames. */
@interface TBFrameSink : NSObject {
    TBSession *session;
}
- (id)initWithSession:(TBSession *)session;
@end

@implementation TBFrameSink
- (id)initWithSession:(TBSession *)s
{
    self = [super init];
    session = s;
    return self;
}
- (void)round:(TBRound *)round text:(NSString *)text
{
    [session emit:@"t" text:text];
}
- (void)round:(TBRound *)round thinking:(NSString *)text
{
    [session emit:@"h" text:text];
}
@end

/* Collects the text of a round, and passes it and the thinking on. */
@interface TBTextCollector : NSObject {
    TBFrameSink *next;
    NSMutableString *spoken;
}
- (id)initWithSink:(TBFrameSink *)sink spoken:(NSMutableString *)spoken;
@end

@implementation TBTextCollector
- (id)initWithSink:(TBFrameSink *)sink spoken:(NSMutableString *)text
{
    self = [super init];
    next = sink;
    spoken = text;
    return self;
}
- (void)round:(TBRound *)round text:(NSString *)text
{
    [spoken appendString:text];
    [next round:round text:text];
}
- (void)round:(TBRound *)round thinking:(NSString *)text
{
    [next round:round thinking:text];
}
@end

/* Frame sink that keeps what it is sent, for helper calls that return text. */
@interface TBCollectFrames : NSObject {
@public
    NSMutableArray *text;
    NSMutableArray *usage;
}
@end

@implementation TBCollectFrames
- (id)init
{
    self = [super init];
    text = [[NSMutableArray alloc] init];
    usage = [[NSMutableArray alloc] init];
    return self;
}
- (void)dealloc
{
    [text release];
    [usage release];
    [super dealloc];
}
- (void)session:(id)session frame:(NSString *)kind text:(NSString *)t
{
    if ([kind isEqualToString:@"t"])
        [text addObject:t];
    else if ([kind isEqualToString:@"u"])
        [usage addObject:t];
}
@end

@implementation TBSession

+ (NSString *)cleanText:(NSString *)text
{
    NSMutableString *out;
    unsigned i, n;
    if (![text isKindOfClass:[NSString class]])
        return text;
    n = [text length];
    out = [NSMutableString stringWithCapacity:n];
    for (i = 0; i < n; i++) {
        unichar c = [text characterAtIndex:i];
        if (c == 0x1b) {
            /* A colour or cursor sequence (CSI) or an operating-system command (OSC): drop it. */
            if (i + 1 < n && [text characterAtIndex:i + 1] == '[') {
                i += 2;
                while (i < n && ((([text characterAtIndex:i] >= '0' && [text characterAtIndex:i] <= '9') || [text characterAtIndex:i] == ';' || [text characterAtIndex:i] == '?')))
                    i++;
                while (i < n && [text characterAtIndex:i] >= 0x20 && [text characterAtIndex:i] <= 0x2f)
                    i++;
                continue;
            }
            if (i + 1 < n && [text characterAtIndex:i + 1] == ']') {
                i += 2;
                while (i < n && [text characterAtIndex:i] != 0x07 && !([text characterAtIndex:i] == 0x1b && i + 1 < n && [text characterAtIndex:i + 1] == '\\'))
                    i++;
                if (i < n && [text characterAtIndex:i] == 0x1b)
                    i++;
                continue;
            }
        }
        if (c <= 8 || c == 0x0b || c == 0x0c || (c >= 0x0e && c <= 0x1f) || c == 0x7f || c == 0x1b)
            [out appendFormat:@"%C", (unichar)0xfffd];
        else
            [out appendFormat:@"%C", c];
    }
    return out;
}

static id cleanObject(id data)
{
    if ([data isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        NSEnumerator *keys = [data keyEnumerator];
        id key;
        while ((key = [keys nextObject]))
            [out setObject:cleanObject([data objectForKey:key]) forKey:[TBSession cleanText:key]];
        return out;
    }
    if ([data isKindOfClass:[NSArray class]]) {
        NSMutableArray *out = [NSMutableArray array];
        unsigned i;
        for (i = 0; i < [data count]; i++)
            [out addObject:cleanObject([data objectAtIndex:i])];
        return out;
    }
    if ([data isKindOfClass:[NSString class]])
        return [TBSession cleanText:data];
    return data;
}

+ (NSString *)propertyListText:(NSDictionary *)dictionary
{
    NSString *problem = nil;
    NSData *data = [NSPropertyListSerialization dataFromPropertyList:cleanObject(dictionary) format:NSPropertyListXMLFormat_v1_0 errorDescription:&problem];
    return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
}

+ (NSDictionary *)cleanOptions:(id)incoming
{
    NSMutableDictionary *servers = [NSMutableDictionary dictionary];
    NSMutableDictionary *approve = [NSMutableDictionary dictionary];
    NSString *root = @"";
    NSString *instructions = @"";
    NSString *names[2] = {@"servers", @"approve"};
    NSMutableDictionary *tables[2];
    int t;
    tables[0] = servers;
    tables[1] = approve;
    if ([incoming isKindOfClass:[NSDictionary class]]) {
        id text = TBValue(incoming, @"instructions");
        id rootValue = TBValue(incoming, @"root");
        if ([text isKindOfClass:[NSString class]]) {
            instructions = [self cleanText:TBTrim(text)];
            if ([instructions length] > 4000)
                instructions = [instructions substringToIndex:4000];
        }
        for (t = 0; t < 2; t++) {
            NSDictionary *table = TBDictionary(incoming, names[t]);
            NSEnumerator *keys = [table keyEnumerator];
            id key;
            while ((key = [keys nextObject])) {
                id value = [table objectForKey:key];
                if ([key isKindOfClass:[NSString class]] && [key length] <= 40 && [value isKindOfClass:[NSNumber class]] && ((CFBooleanRef)value == kCFBooleanTrue || (CFBooleanRef)value == kCFBooleanFalse))
                    [tables[t] setObject:value forKey:key];
            }
        }
        if ([rootValue isKindOfClass:[NSString class]]) {
            NSString *r = TBTrim(rootValue);
            if ([r hasPrefix:@"/"] && [r length] <= 300 && [r rangeOfString:@"\n"].location == NSNotFound) {
                while ([r length] > 1 && [r hasSuffix:@"/"])
                    r = [r substringToIndex:[r length] - 1];
                root = r;
            }
        }
    }
    return [NSDictionary dictionaryWithObjectsAndKeys:servers, @"servers", approve, @"approve", root, @"root", instructions, @"instructions", nil];
}

/* Whether a model can look at a picture. A wrong guess only costs a tool. */
+ (BOOL)supportsImages:(NSString *)provider model:(NSString *)model
{
    NSString *m = [(model ? model : @"") lowercaseString];
    NSArray *words;
    unsigned i;
    if ([provider isEqualToString:@"claude"] || [provider isEqualToString:@"gemini"] || [provider isEqualToString:@"muse"])
        return YES;
    if ([provider isEqualToString:@"grok"])
        return [m rangeOfString:@"build"].location == NSNotFound;
    if ([provider isEqualToString:@"chatgpt"])
        return !([m isEqualToString:@"gpt-4"] || [m isEqualToString:@"gpt-3.5-turbo"] || [m isEqualToString:@"o1-mini"] || [m isEqualToString:@"o3-mini"] || [m hasPrefix:@"gpt-3"]);
    if ([provider isEqualToString:@"mistral"])
        words = [NSArray arrayWithObjects:@"ministral", @"pixtral", @"medium", @"large", @"small", @"magistral", nil];
    else if ([provider isEqualToString:@"local"])
        words = [NSArray arrayWithObjects:@"vl", @"vision", @"llava", @"gemma-3", @"gemma-4", @"pixtral", @"minicpm-v", @"-v-", @"qwen3.5", @"mistral-small-3", @"ministral", nil];
    else
        return NO;
    for (i = 0; i < [words count]; i++) {
        if ([m rangeOfString:[words objectAtIndex:i]].location != NSNotFound)
            return YES;
    }
    return NO;
}

static NSArray *withoutPictures(NSArray *messages)
{
    NSMutableArray *out = [NSMutableArray array];
    unsigned i;
    for (i = 0; i < [messages count]; i++) {
        NSDictionary *item = [messages objectAtIndex:i];
        NSArray *images = TBArray(item, @"images");
        if ([images count]) {
            NSMutableDictionary *copy = [NSMutableDictionary dictionaryWithDictionary:item];
            [copy removeObjectForKey:@"images"];
            [copy setObject:[NSString stringWithFormat:@"%@\n[%u attached picture%@ not shown: this model cannot view pictures.]", TBString(item, @"content"),
                (unsigned)[images count], [images count] == 1 ? @"" : @"s"] forKey:@"content"];
            item = copy;
        }
        [out addObject:item];
    }
    return out;
}

/* (files, added, removed) from a diff or a commit's own summary line, or nil when the output has neither. */
+ (NSDictionary *)changeStatsForTool:(NSString *)name output:(NSString *)output
{
    NSArray *lines;
    unsigned i;
    int files = 0, added = 0, removed = 0;
    BOOL seen = NO;
    NSRange found;
    if (!([name isEqualToString:@"git_read"] || [name isEqualToString:@"git_write"] || [name isEqualToString:@"svn_read"] || [name isEqualToString:@"svn_write"]) || [output length] == 0)
        return nil;
    found = [output rangeOfString:@" changed"];
    while (found.location != NSNotFound) {
        /* "3 files changed, 10 insertions(+), 2 deletions(-)" */
        NSRange lineStart = [output rangeOfString:@"\n" options:NSBackwardsSearch range:NSMakeRange(0, found.location)];
        unsigned from = lineStart.location == NSNotFound ? 0 : lineStart.location + 1;
        NSRange lineEnd = [output rangeOfString:@"\n" options:0 range:NSMakeRange(found.location, [output length] - found.location)];
        NSString *line = [output substringWithRange:NSMakeRange(from, (lineEnd.location == NSNotFound ? [output length] : lineEnd.location) - from)];
        NSScanner *scanner = [NSScanner scannerWithString:line];
        int n = 0;
        [scanner scanCharactersFromSet:[NSCharacterSet whitespaceCharacterSet] intoString:NULL];
        if ([scanner scanInt:&n] && ([scanner scanString:@"files changed" intoString:NULL] || [scanner scanString:@"file changed" intoString:NULL])) {
            int a = 0, d = 0, x;
            files = n;
            while ([scanner scanString:@"," intoString:NULL]) {
                if ([scanner scanInt:&x]) {
                    if ([scanner scanString:@"insertion" intoString:NULL])
                        a = x;
                    else if ([scanner scanString:@"deletion" intoString:NULL])
                        d = x;
                }
                [scanner scanUpToString:@"," intoString:NULL];
            }
            return [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:files], @"files", [NSNumber numberWithInt:a], @"added", [NSNumber numberWithInt:d], @"removed", nil];
        }
        if (lineEnd.location == NSNotFound)
            break;
        found = [output rangeOfString:@" changed" options:0 range:NSMakeRange(lineEnd.location, [output length] - lineEnd.location)];
    }
    lines = [output componentsSeparatedByString:@"\n"];
    for (i = 0; i < [lines count]; i++) {
        NSString *line = [lines objectAtIndex:i];
        if ([line hasPrefix:@"diff --git "] || [line hasPrefix:@"Index: "]) {
            files++;
            seen = YES;
        } else if ([line hasPrefix:@"+++ "] || [line hasPrefix:@"--- "]) {
            seen = YES;
        } else if ([line hasPrefix:@"+"] && seen) {
            added++;
        } else if ([line hasPrefix:@"-"] && seen && ![line hasPrefix:@"-----"]) {
            removed++;
        }
    }
    if (!seen)
        return nil;
    return [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:files > 0 ? files : 1], @"files", [NSNumber numberWithInt:added], @"added",
        [NSNumber numberWithInt:removed], @"removed", nil];
}

- (id)initWithRun:(TBRun *)r options:(NSDictionary *)opts frames:(id)sink
{
    self = [super init];
    if (self) {
        run = [r retain];
        options = [(opts ? opts : [TBSession cleanOptions:nil]) retain];
        frames = sink;
        side = [[NSMutableArray alloc] init];
        client = [[NSDictionary dictionary] retain];
        offline = @"";
    }
    return self;
}

- (void)dealloc
{
    [self closeTools];
    [run release];
    [options release];
    [client release];
    [side release];
    [commanderTools release];
    [grokKey release];
    [extras release];
    [super dealloc];
}

- (void)closeTools
{
    [commander close];
    [commander release];
    commander = nil;
}

- (void)setClientInfo:(id)info
{
    NSMutableDictionary *clean = [NSMutableDictionary dictionary];
    NSArray *keys = [NSArray arrayWithObjects:@"machine", @"os", @"user", @"home", nil];
    unsigned i;
    if ([info isKindOfClass:[NSDictionary class]]) {
        for (i = 0; i < [keys count]; i++) {
            NSString *value = TBString(info, [keys objectAtIndex:i]);
            if ([value length]) {
                NSMutableString *single = [NSMutableString stringWithString:value];
                [single replaceOccurrencesOfString:@"\n" withString:@" " options:0 range:NSMakeRange(0, [single length])];
                value = TBTrim(single);
                if ([value length] > 160)
                    value = [value substringToIndex:160];
                if ([value length])
                    [clean setObject:value forKey:[keys objectAtIndex:i]];
            }
        }
    }
    [client release];
    client = [clean retain];
}

- (NSString *)machine
{
    if ([TBSSH enabled])
        return [NSString stringWithFormat:@"the Mac at %@", [TBSSH host]];
    return [TBString(client, @"machine") length] ? TBString(client, @"machine") : @"a Mac";
}

- (NSString *)osName
{
    return [TBString(client, @"os") length] ? TBString(client, @"os") : @"Mac OS X";
}

- (NSString *)account
{
    if ([TBSSH enabled])
        return [TBSSH user];
    return NSUserName();
}

- (NSString *)home
{
    if ([TBSSH enabled])
        return [TBSSH home];
    return NSHomeDirectory();
}

- (int)maxSteps
{
    NSNumber *saved = [[NSUserDefaults standardUserDefaults] objectForKey:@"TBTool.max_tool_steps"];
    int steps = saved ? [saved intValue] : 40;
    return steps < 1 ? 1 : (steps > 200 ? 200 : steps);
}

- (NSString *)mediaRoot
{
    return [[self home] stringByAppendingString:@"/Library/Application Support/Tiger Build/media"];
}

/* Tool groups the chat has switched off. Consulting another model costs money, so it is off unless the chat turned it on. */
- (NSSet *)skipKeys
{
    NSMutableSet *skip = [NSMutableSet set];
    NSDictionary *servers = TBDictionary(options, @"servers");
    NSEnumerator *keys = [servers keyEnumerator];
    id key;
    while ((key = [keys nextObject])) {
        if ((CFBooleanRef)[servers objectForKey:key] == kCFBooleanFalse)
            [skip addObject:key];
    }
    if ((CFBooleanRef)[servers objectForKey:@"consult"] != kCFBooleanTrue)
        [skip addObject:@"consult"];
    return skip;
}

- (void)emit:(NSString *)kind text:(NSString *)text
{
    [frames session:self frame:kind text:text];
}

- (void)emitSide
{
    NSArray *pending = [NSArray arrayWithArray:side];
    unsigned i;
    [side removeAllObjects];
    for (i = 0; i < [pending count]; i++)
        [self emit:TBString([pending objectAtIndex:i], @"kind") text:TBString([pending objectAtIndex:i], @"text")];
}

/* ---- the usage line ---- */

- (NSString *)usageEventForProvider:(NSString *)provider model:(NSString *)model usage:(NSDictionary *)usage
{
    NSMutableDictionary *row;
    long long input = TBInteger(usage, @"input"), cached = TBInteger(usage, @"cached"), written = TBInteger(usage, @"written"), output = TBInteger(usage, @"output");
    NSNumber *cost;
    if (input + cached + written + output == 0)
        return nil;
    row = [NSMutableDictionary dictionaryWithObjectsAndKeys:provider, @"provider", model, @"model", [NSNumber numberWithLongLong:input], @"input",
        [NSNumber numberWithLongLong:cached], @"cached", [NSNumber numberWithLongLong:written], @"written", [NSNumber numberWithLongLong:output], @"output", nil];
    cost = [TBPricing costForProvider:provider model:model usage:usage];
    if (cost)
        [row setObject:cost forKey:@"cost"];
    lastContext = input + cached + written;
    [row setObject:[NSNumber numberWithLongLong:lastContext] forKey:@"context"];
    return [TBSession propertyListText:row];
}

- (int)contextLimitForProvider:(NSString *)provider model:(NSString *)model
{
    int live = [provider isEqualToString:@"local"] ? [TBLocal contextForModel:model] : [TBPricing liveContextForProvider:provider model:model];
    return live ? live : [TBProviders contextLimitForModel:model];
}

/* ---- running one tool call ---- */

- (NSString *)toolKeyForName:(NSString *)name
{
    if ([name isEqualToString:@"generate_image"] || [name isEqualToString:@"generate_video"])
        return @"media";
    if ([name isEqualToString:kConsultTool])
        return @"consult";
    if ([extras ownerOf:name])
        return [extras ownerOf:name];
    return @"commander";
}

- (BOOL)needsApprovalForKey:(NSString *)key
{
    NSDictionary *approve = TBDictionary(options, @"approve");
    id value = [approve objectForKey:key];
    if (value)
        return [value boolValue];
    value = [approve objectForKey:@"all"];
    if (value)
        return [value boolValue];
    if ([key isEqualToString:@"commander"])
        return [TBSettings flag:@"ppc_approval"];
    if ([key hasPrefix:@"mcp_"])
        return [TBIntegrations serverApprovalForKey:key];
    return NO;
}

static NSDictionary *callArguments(NSDictionary *call)
{
    id raw = TBValue(call, @"arguments");
    id args = raw;
    if ([raw isKindOfClass:[NSString class]])
        args = [raw length] ? TBJSONParseString(raw, NULL) : nil;
    return [args isKindOfClass:[NSDictionary class]] ? args : [NSDictionary dictionary];
}

- (NSString *)toolEventForCall:(NSDictionary *)call phase:(NSString *)phase output:(NSString *)output failed:(BOOL)failed elapsed:(double)elapsed
{
    NSDictionary *args = callArguments(call);
    NSString *name = [TBString(call, @"name") length] ? TBString(call, @"name") : @"tool";
    id detail = TBValue(args, @"command");
    NSString *callId = [TBString(call, @"id") length] ? TBString(call, @"id") : ([TBString(call, @"call_id") length] ? TBString(call, @"call_id") : name);
    NSMutableDictionary *event;
    NSString *shown, *outText;
    NSDictionary *stats;
    unsigned i;
    NSArray *fallbacks = [NSArray arrayWithObjects:@"input", @"query", @"url", @"question", nil];
    for (i = 0; !truthyValue(detail) && i < [fallbacks count]; i++)
        detail = TBValue(args, [fallbacks objectAtIndex:i]);
    if (!truthyValue(detail))
        detail = TBJSONString(args);
    shown = [detail isKindOfClass:[NSString class]] ? detail : [detail description];
    if ([shown length] > 20000)
        shown = [shown substringToIndex:20000];
    outText = output ? output : @"";
    if ([outText length] > 100000)
        outText = [outText substringToIndex:100000];
    event = [NSMutableDictionary dictionaryWithObjectsAndKeys:callId, @"id", name, @"name", phase, @"phase", shown, @"detail", outText, @"output",
        [NSNumber numberWithBool:failed], @"failed", [NSNumber numberWithDouble:elapsed], @"elapsed", nil];
    stats = [phase isEqualToString:@"result"] && !failed ? [TBSession changeStatsForTool:name output:outText] : nil;
    if (stats)
        [event addEntriesFromDictionary:stats];
    return [TBSession propertyListText:event];
}

/* Whether a command line has this word as a command (not as part of another word). */
static BOOL mentionsWord(NSString *line, NSString *word)
{
    NSCharacterSet *breaks = [NSCharacterSet characterSetWithCharactersInString:@" \t\n;&|()`"];
    NSRange at = NSMakeRange(0, 0);
    while (YES) {
        NSRange found = [line rangeOfString:word options:0 range:NSMakeRange(NSMaxRange(at), [line length] - NSMaxRange(at))];
        BOOL before, after;
        if (found.location == NSNotFound)
            return NO;
        before = found.location == 0 || [breaks characterIsMember:[line characterAtIndex:found.location - 1]];
        after = NSMaxRange(found) == [line length] || [breaks characterIsMember:[line characterAtIndex:NSMaxRange(found)]];
        if (before && after)
            return YES;
        at = found;
    }
}

static BOOL truthyValue(id v)
{
    if (!v)
        return NO;
    if ([v isKindOfClass:[NSString class]])
        return [v length] > 0;
    if ([v isKindOfClass:[NSNumber class]])
        return [v boolValue];
    return YES;
}

- (NSDictionary *)capCommandWait:(NSDictionary *)args
{
    NSMutableDictionary *capped = [NSMutableDictionary dictionaryWithDictionary:args];
    id raw = TBValue(args, @"timeout_ms");
    long long wait = 15000;
    if ([raw isKindOfClass:[NSNumber class]])
        wait = [raw longLongValue];
    else if ([raw isKindOfClass:[NSString class]])
        wait = strtoll([raw UTF8String], NULL, 10);
    if (wait < 1000)
        wait = 1000;
    if (wait > 20000)
        wait = 20000;
    [capped setObject:[NSNumber numberWithLongLong:wait] forKey:@"timeout_ms"];
    return capped;
}

- (NSString *)stoppedEarlyOutput:(NSString *)output reason:(NSString *)reason
{
    NSString *detail = TBTrim(output ? output : @"");
    if ([detail length] == 0 && reason)
        detail = TBTrim(reason);
    if ([detail length] > 600)
        detail = [[detail substringToIndex:600] stringByAppendingString:@"..."];
    if ([detail length] == 0)
        return @"\n\nI couldn't finish after that step.";
    return [@"\n\nThe last command stopped with an error:\n" stringByAppendingString:detail];
}

/* Asks the person before a tool runs, when approval is on for it. YES to go ahead. */
- (BOOL)gateCall:(NSDictionary *)call
{
    NSString *name = TBString(call, @"name");
    NSString *key = [self toolKeyForName:name];
    NSString *callId, *detail, *decision;
    NSDictionary *args;
    if ([name isEqualToString:@"git_read"] || [name isEqualToString:@"svn_read"] || [name isEqualToString:@"repo_info"])
        return YES;
    if (![self needsApprovalForKey:key])
        return YES;
    callId = [TBString(call, @"id") length] ? TBString(call, @"id") : ([TBString(call, @"call_id") length] ? TBString(call, @"call_id") : ([name length] ? name : @"call"));
    [run ask:callId];
    args = callArguments(call);
    detail = nil;
    {
        NSArray *names = [NSArray arrayWithObjects:@"command", @"path", @"query", @"question", nil];
        unsigned i;
        for (i = 0; i < [names count] && !detail; i++) {
            id v = TBValue(args, [names objectAtIndex:i]);
            if (truthyValue(v))
                detail = [v isKindOfClass:[NSString class]] ? v : [v description];
        }
    }
    if (!detail)
        detail = TBJSONString(args);
    if (mentionsWord(TBString(args, @"command"), @"sudo"))
        detail = [@"As administrator (sudo): " stringByAppendingString:detail];
    if ([detail length] > 4000)
        detail = [detail substringToIndex:4000];
    [self emit:@"q" text:[TBSession propertyListText:[NSDictionary dictionaryWithObjectsAndKeys:callId, @"id", [name length] ? name : @"tool", @"name", key, @"server", detail, @"detail", nil]]];
    decision = [run waitFor:callId];
    return [decision isEqualToString:@"allow"] || [decision isEqualToString:@"always"];
}

- (NSString *)mediaStatusForName:(NSString *)name
{
    if ([name isEqualToString:@"generate_image"])
        return @"Generating an image...";
    if ([name isEqualToString:@"generate_video"])
        return @"Generating a video. This can take a minute...";
    if ([name isEqualToString:kConsultTool])
        return @"Asking another model...";
    return @"";
}

/* Runs one call and sends its cards. Returns {output, failed, images}. */
- (NSDictionary *)executeCall:(NSDictionary *)call provider:(NSString *)provider
{
    NSString *name = TBString(call, @"name");
    BOOL allowed;
    NSString *output;
    BOOL failed;
    NSArray *images = [NSArray array];
    NSDate *started;
    NSString *announced;
    NSString *media = nil;
    [run check];
    allowed = [self gateCall:call];
    announced = [self mediaStatusForName:name];
    if ([announced length] && allowed)
        [self emit:@"s" text:announced];
    [self emit:@"a" text:[self toolEventForCall:call phase:@"start" output:@"" failed:NO elapsed:0]];
    started = [NSDate date];
    if (!allowed) {
        output = @"The person declined to run this tool. Do not retry it; continue without it or explain what you need.";
        failed = YES;
    } else {
        NSDictionary *result = [self runOneCall:call provider:provider];
        output = TBString(result, @"output");
        failed = TBTruth(result, @"failed");
        images = TBArray(result, @"images") ? TBArray(result, @"images") : images;
        media = TBValue(result, @"media");
    }
    [run check];
    [self emit:@"a" text:[self toolEventForCall:call phase:@"result" output:output failed:failed elapsed:-[started timeIntervalSinceNow]]];
    [self emitSide];
    if ([media length])
        [self emit:@"m" text:media];
    return [NSDictionary dictionaryWithObjectsAndKeys:output, @"output", [NSNumber numberWithBool:failed], @"failed", images, @"images", nil];
}

- (NSDictionary *)screenshotNoteForProvider:(NSString *)provider model:(NSString *)model images:(NSArray *)images
{
    if ([images count] && [TBSession supportsImages:provider model:model])
        return [NSDictionary dictionaryWithObjectsAndKeys:@"user", @"role", @"This is the image that your last tool call returned.", @"content", images, @"images", nil];
    return nil;
}

/* ---- the turn ---- */

- (void)runTurn:(NSArray *)incoming useTools:(BOOL)useTools provider:(NSString *)provider model:(NSString *)requested
{
    @try {
        [self turn:incoming useTools:useTools provider:provider model:requested systemOverride:nil];
    } @catch (NSException *exception) {
        if ([[exception name] isEqualToString:TBStoppedException])
            return;
        @throw;
    }
}

- (void)turn:(NSArray *)incoming useTools:(BOOL)useTools provider:(NSString *)provider model:(NSString *)requested systemOverride:(NSString *)override
{
    NSString *chosen = [TBProviders resolveModel:requested provider:provider];
    NSArray *messages = incoming;
    NSMutableArray *tools = [NSMutableArray array];
    NSSet *skip = [self skipKeys];
    NSString *system;
    if (![TBSession supportsImages:provider model:chosen])
        messages = withoutPictures(messages);
    if (useTools && !override) {
        if ([TBSettings flag:@"ppc_enabled"] && ![skip containsObject:@"commander"]) {
            [tools addObjectsFromArray:[self commanderDefinitions]];
            if (![TBSession supportsImages:provider model:chosen]) {
                NSMutableArray *kept = [NSMutableArray array];
                unsigned i;
                for (i = 0; i < [tools count]; i++) {
                    NSString *n = TBString([tools objectAtIndex:i], @"name");
                    if (![n isEqualToString:kScreenshotTool] && ![n isEqualToString:@"view_image"])
                        [kept addObject:[tools objectAtIndex:i]];
                }
                [tools setArray:kept];
            }
        }
        [tools addObjectsFromArray:[self extraDefinitionsForProvider:provider skip:skip]];
    }
    if (override) {
        system = override;
        useTools = NO;
    } else {
        system = [self composeSystemForTools:tools useTools:useTools provider:provider skip:skip];
    }
    @try {
        if (![provider isEqualToString:@"grok"])
            [self runForeignProvider:provider messages:messages system:system tools:tools model:chosen];
        else
            [self runGrokMessages:messages system:system tools:tools model:chosen bare:override != nil];
    } @finally {
        [self closeTools];
        [self closeExtras];
    }
}

- (NSString *)composeSystemForTools:(NSMutableArray *)tools useTools:(BOOL)useTools provider:(NSString *)provider skip:(NSSet *)skip
{
    NSMutableString *system = [NSMutableString stringWithString:kSystem];
    NSArray *media;
    unsigned i;
    BOOL hasStart = NO, hasScreenshot = NO, hasRepo = NO, hasView = NO, hasSave = NO, hasConsult = NO;
    [system replaceOccurrencesOfString:@"{machine}" withString:[self machine] options:0 range:NSMakeRange(0, [system length])];
    [system replaceOccurrencesOfString:@"{os}" withString:[self osName] options:0 range:NSMakeRange(0, [system length])];
    media = [skip containsObject:@"media"] ? nil : [self mediaToolsForProvider:provider];
    if ([media count]) {
        [tools addObjectsFromArray:media];
        [system appendFormat:@" If the person asks for a picture, call generate_image. If they ask for a video or animation, call generate_video. "
            "Do not say a file was created unless that tool saved one. Saved pictures and videos are files in %@ on the Mac. "
            "If the person asks to put one somewhere else, copy that file with the shell. Do not invent a path.", [self mediaRoot]];
    }
    for (i = 0; i < [tools count]; i++) {
        NSString *n = TBString([tools objectAtIndex:i], @"name");
        if ([n isEqualToString:@"start_process"]) hasStart = YES;
        if ([n isEqualToString:kScreenshotTool]) hasScreenshot = YES;
        if ([n isEqualToString:@"repo_info"]) hasRepo = YES;
        if ([n isEqualToString:@"view_image"]) hasView = YES;
        if ([n isEqualToString:@"agent_save_file"]) hasSave = YES;
        if ([n isEqualToString:kConsultTool]) hasConsult = YES;
    }
    if (!useTools) {
        [system appendString:@" ppc-commander is turned off for this chat. Do not claim you can read files or run commands on the Mac. If asked to, say those tools are off for this chat."];
    } else if ([skip containsObject:@"commander"] || ![TBSettings flag:@"ppc_enabled"]) {
        [system appendString:@" Commander is switched off for this chat. Do not claim you can read files or run commands on the Mac."];
    } else if (!hasStart) {
        [system appendString:@" Commander is offline right now. If asked to touch the computer, say you cannot reach it."];
        if ([offline length])
            [self emit:@"s" text:offline];
    } else {
        [system appendFormat:@" The account on that Mac is %@. Home is %@ and the Desktop is %@/Desktop. Do not look for other users or call tools just to discover the home directory.",
            [self account], [self home], [self home]];
        if (hasScreenshot)
            [system appendString:@" Use take_screenshot when you need to see what is on that Mac's screen."];
        if (hasRepo)
            [system appendString:@" For source control on that Mac, start with repo_info. Use git_read and svn_read to look and git_write and svn_write to change things. "
                "Check status and diff before committing, write a clear message, commit only what was asked for, and never force-push. "
                "git may not be installed, and Subversion 1.4 to 1.6 lacks newer options."];
        if (hasView)
            [system appendString:@" To look at a picture file on that Mac, call view_image with its path; read_file returns only text."];
        if ([TBString(options, @"root") length])
            [system appendFormat:@" This workspace is restricted to the directory %@. File tools and shell commands cannot reach outside it; work inside it.", TBString(options, @"root")];
    }
    if (hasSave)
        [system appendString:@" Attached files appear in the conversation (documents as text, pictures as pictures). To give the person a new or changed file, "
            "call agent_save_file with its whole content; a name ending .docx, .xlsx or .pdf makes a real file from plain text (for .xlsx, tab or comma separated rows)."];
    if (hasConsult)
        [system appendString:@" You may use consult_model to get a second opinion from another model on hard decisions or reviews. Do not use it for simple questions."];
    if ([TBString(options, @"instructions") length])
        [system appendString:[@" The person's instructions for this chat: " stringByAppendingString:TBString(options, @"instructions")]];
    if ([provider isEqualToString:@"grok"]) {
        NSRange r = [system rangeOfString:@"You are an assistant"];
        if (r.location != NSNotFound)
            [system replaceCharactersInRange:r withString:@"You are Grok"];
    }
    return system;
}

@end

/* ---- Commander on this Mac ---- */

static NSMutableDictionary *toolCache = nil;      /* tools, at, offline */

/* TBCommanderPath and TBCommanderPython in the preferences replace the installed Commander and the system Python, for tests. */
static NSString *commanderPath(void)
{
    NSString *over = [[NSUserDefaults standardUserDefaults] stringForKey:@"TBCommanderPath"];
    return [over length] ? over : [NSHomeDirectory() stringByAppendingPathComponent:@"ppc-commander/ppc_commander.py"];
}

static NSString *commanderPython(void)
{
    NSString *over = [[NSUserDefaults standardUserDefaults] stringForKey:@"TBCommanderPython"];
    return [over length] ? over : @"/usr/bin/python";
}

@implementation TBSession (Commander)

+ (NSString *)cachedCommanderProblem
{
    NSString *problem = @"";
    if (!toolCache)
        return @"";
    @synchronized(toolCache) {
        problem = [[[[toolCache objectForKey:@"entry"] objectForKey:@"offline"] copy] autorelease];
    }
    return problem ? problem : @"";
}

+ (void)forgetCommanderTools
{
    @synchronized(toolCache ? (id)toolCache : (id)self) {
        [toolCache removeObjectForKey:@"entry"];
    }
}

- (TBMCPClient *)startCommanderWithRoot:(NSString *)root
{
    NSMutableArray *args = [NSMutableArray arrayWithObjects:@"LANG=C", @"LC_ALL=C", nil];
    NSString *program = @"/usr/bin/env";
    TBMCPClient *started;
    if ([TBSSH enabled]) {
        /* Commander on another Mac: the same program, started over SSH. */
        NSString *problem = nil, *remote;
        NSArray *ssh;
        remote = [NSString stringWithFormat:@"exec /usr/bin/env LANG=C LC_ALL=C %@/usr/bin/python -u \"$HOME/ppc-commander/ppc_commander.py\"",
            [root length] ? [NSString stringWithFormat:@"TB_WORKSPACE_ROOT='%@' ", [[root componentsSeparatedByString:@"'"] componentsJoinedByString:@"'\\''"]] : @""];
        ssh = [TBSSH commandArgumentsRunning:remote problem:&problem];
        if (!ssh)
            TBFail(@"%@", problem);
        program = @"/usr/bin/ssh";
        args = [NSMutableArray arrayWithArray:ssh];
    } else {
        if (![[NSFileManager defaultManager] fileExistsAtPath:commanderPath()])
            TBFail(@"Commander is not installed on this Mac. Quit and reopen Tiger Build to install it.");
        if ([root length])
            [args addObject:[@"TB_WORKSPACE_ROOT=" stringByAppendingString:root]];
        [args addObjectsFromArray:[NSArray arrayWithObjects:commanderPython(), @"-u", commanderPath(), nil]];
    }
    started = [TBMCPClient clientWithPath:program arguments:args environment:nil label:@"Commander"];
    [run attach:started];
    @try {
        [started start];
    } @catch (NSException *exception) {
        [run detach:started];
        [started close];
        [run check];
        TBFail(@"Commander could not run: %@ %@", [exception reason], [started stderrText]);
    }
    return started;
}

- (NSArray *)commanderDefinitions
{
    NSDictionary *entry;
    double age;
    if (commanderTools)
        return commanderTools;
    if (!toolCache)
        toolCache = [[NSMutableDictionary alloc] init];
    @synchronized(toolCache) {
        entry = [[[toolCache objectForKey:@"entry"] retain] autorelease];
    }
    age = entry ? -[[entry objectForKey:@"at"] timeIntervalSinceNow] : 1e9;
    if (!entry || age >= ([[entry objectForKey:@"tools"] count] ? 300 : 15)) {
        NSArray *tools = [NSArray array];
        NSString *problem = @"";
        TBMCPClient *probe = nil;
        @try {
            probe = [self startCommanderWithRoot:@""];
            tools = TBMCPFunctionTools([probe request:@"tools/list" params:[NSDictionary dictionary] timeout:30]);
        } @catch (NSException *exception) {
            if ([[exception name] isEqualToString:TBStoppedException])
                @throw;
            problem = [NSString stringWithFormat:@"Commander is offline. %@", [exception reason]];
        }
        [run detach:probe];
        [probe close];
        entry = [NSDictionary dictionaryWithObjectsAndKeys:tools, @"tools", [NSDate date], @"at", problem, @"offline", nil];
        @synchronized(toolCache) {
            [toolCache setObject:entry forKey:@"entry"];
        }
    }
    [commanderTools release];
    commanderTools = [[entry objectForKey:@"tools"] retain];
    [offline release];
    offline = [[entry objectForKey:@"offline"] copy];
    return commanderTools;
}

- (NSDictionary *)runCommanderCall:(NSString *)name arguments:(NSDictionary *)args
{
    NSString *output;
    BOOL failed = NO;
    NSArray *images = [NSArray array];
    id result;
    if (![TBSettings flag:@"ppc_enabled"])
        return [NSDictionary dictionaryWithObjectsAndKeys:@"error: Commander is switched off in Tiger Build.", @"output", [NSNumber numberWithBool:YES], @"failed", nil];
    @try {
        if (!commander)
            commander = [[self startCommanderWithRoot:TBString(options, @"root")] retain];
        result = [commander request:@"tools/call" params:[NSDictionary dictionaryWithObjectsAndKeys:name, @"name", args, @"arguments", nil] timeout:120];
        output = TBMCPResultText(result);
        failed = TBTruth(result, @"isError");
        images = TBMCPResultImages(result);
    } @catch (NSException *exception) {
        [run check];
        output = [NSString stringWithFormat:@"error: Commander could not run (%@). %@", [exception reason], commander ? [commander stderrText] : @""];
        failed = YES;
        [commander close];
        [commander release];
        commander = nil;
        @synchronized(toolCache) {
            [toolCache removeObjectForKey:@"entry"];
        }
    }
    {
        NSMutableDictionary *answer = [NSMutableDictionary dictionaryWithObjectsAndKeys:output, @"output", [NSNumber numberWithBool:failed], @"failed", images, @"images", nil];
        /* Show the picture the model looked at in the chat too. */
        if ([images count] && !failed) {
            @try {
                NSDictionary *first = [images objectAtIndex:0];
                NSData *bytes = TBBase64Decode(TBString(first, @"data"));
                NSString *mime = TBString(first, @"mime");
                if (bytes)
                    [answer setObject:[@"image " stringByAppendingString:TBSaveMedia(bytes, [mime isEqualToString:@"image/png"] ? @"png" : ([mime isEqualToString:@"image/gif"] ? @"gif" : @"jpg"))] forKey:@"media"];
            } @catch (NSException *ignored) {
            }
        }
        return answer;
    }
}

- (NSDictionary *)runOneCall:(NSDictionary *)call provider:(NSString *)provider
{
    NSString *name = TBString(call, @"name");
    NSDictionary *args = callArguments(call);
    if ([name isEqualToString:@"start_process"] || [name isEqualToString:@"interact_with_process"])
        args = [self capCommandWait:args];
    if ([name isEqualToString:@"generate_image"] || [name isEqualToString:@"generate_video"])
        return [self runMediaCall:name arguments:args provider:provider];
    if ([name isEqualToString:kConsultTool]) {
        @try {
            return [NSDictionary dictionaryWithObjectsAndKeys:[self consult:args], @"output", [NSNumber numberWithBool:NO], @"failed", nil];
        } @catch (NSException *exception) {
            [run check];
            return [NSDictionary dictionaryWithObjectsAndKeys:[@"error: " stringByAppendingString:[exception reason]], @"output", [NSNumber numberWithBool:YES], @"failed", nil];
        }
    }
    if ([self extraHandles:name])
        return [self runExtraCall:name arguments:args];
    return [self runCommanderCall:name arguments:args];
}

@end

/* ---- the loop for every service but Grok ---- */

@implementation TBSession (Loop)

/* Shorten old tool results. A long run piles up command output that the model no longer needs word for word. */
- (int)trimToolOutputIn:(NSMutableArray *)log
{
    int trimmed = 0;
    NSMutableArray *positions = [NSMutableArray array];
    unsigned i;
    for (i = 0; i < [log count]; i++) {
        if ([TBString([log objectAtIndex:i], @"role") isEqualToString:@"tool"])
            [positions addObject:[NSNumber numberWithUnsignedInt:i]];
    }
    if ([positions count] > 6) {
        for (i = 0; i < [positions count] - 6; i++) {
            unsigned index = [[positions objectAtIndex:i] unsignedIntValue];
            NSDictionary *item = [log objectAtIndex:index];
            NSString *text = TBString(item, @"content");
            if ([text length] > 700) {
                NSMutableDictionary *copy = [NSMutableDictionary dictionaryWithDictionary:item];
                [copy setObject:[NSString stringWithFormat:@"%@\n...[%u characters removed to save space]...\n%@", [text substringToIndex:350], (unsigned)([text length] - 550),
                    [text substringFromIndex:[text length] - 200]] forKey:@"content"];
                [log replaceObjectAtIndex:index withObject:copy];
                trimmed++;
            }
        }
    }
    return trimmed;
}

static unsigned long contentSize(NSArray *log)
{
    unsigned long total = 0;
    unsigned i;
    for (i = 0; i < [log count]; i++)
        total += [TBString([log objectAtIndex:i], @"content") length];
    return total;
}

/* Make room in a long run: shorten old tool output first; if that is not enough, summarize the oldest part. Returns a sentence
   for the person, or "" when nothing changed. */
- (NSString *)compactLog:(NSMutableArray *)log provider:(NSString *)provider model:(NSString *)model
{
    unsigned long before = contentSize(log);
    int trimmed = [self trimToolOutputIn:log];
    int limit = [self contextLimitForProvider:provider model:model];
    long long estimate = lastContext;
    NSString *shortened = trimmed ? @"Context was getting full, so older tool output was shortened." : @"";
    int cut;
    NSMutableArray *older = [NSMutableArray array];
    NSString *text, *summary;
    unsigned i;
    if (trimmed) {
        unsigned long after = contentSize(log);
        estimate = (long long)(estimate * ((double)after / (before ? before : 1)));
    }
    if (estimate < limit * kCompactAt)
        return shortened;
    cut = (int)[log count] - 6;
    while (cut > 1 && [TBString([log objectAtIndex:cut], @"role") isEqualToString:@"tool"])
        cut--;
    if (cut < 2)
        return shortened;
    for (i = 0; i < (unsigned)cut; i++) {
        NSDictionary *item = [log objectAtIndex:i];
        NSMutableString *piece = [NSMutableString stringWithString:TBString(item, @"content")];
        NSArray *calls = TBArray(item, @"calls");
        if ([calls count]) {
            NSMutableArray *names = [NSMutableArray array];
            unsigned c;
            for (c = 0; c < [calls count]; c++)
                [names addObject:TBString([calls objectAtIndex:c], @"name")];
            [piece appendFormat:@" [called %@]", [names componentsJoinedByString:@", "]];
        }
        if ([piece length])
            [older addObject:[NSString stringWithFormat:@"%@: %@", TBString(item, @"role"), [piece length] > 3000 ? [piece substringToIndex:3000] : piece]];
    }
    text = [older componentsJoinedByString:@"\n\n"];
    if ([text length] > 60000)
        text = [text substringToIndex:60000];
    @try {
        summary = [self completeProvider:provider model:model system:@"Summarize this conversation and the work done so far so the assistant can carry on. Keep names, decisions, file paths, "
            "commands that worked, errors seen and unfinished work. Plain prose." messages:[NSArray arrayWithObject:[NSDictionary dictionaryWithObjectsAndKeys:@"user", @"role", text, @"content", nil]]];
    } @catch (NSException *exception) {
        if ([[exception name] isEqualToString:TBStoppedException])
            @throw;
        return shortened;
    }
    [log replaceObjectsInRange:NSMakeRange(0, cut) withObjectsFromArray:[NSArray arrayWithObject:[NSDictionary dictionaryWithObjectsAndKeys:@"user", @"role",
        [@"Summary of the earlier part of this conversation:\n" stringByAppendingString:summary], @"content", nil]]];
    return @"Context was full, so the earlier part of this run was summarized.";
}

- (NSArray *)takeGuidanceNotes
{
    NSArray *notes = [run takeGuidance];
    unsigned i;
    for (i = 0; i < [notes count]; i++)
        [self emit:@"g" text:[notes objectAtIndex:i]];
    return notes;
}

- (void)runForeignProvider:(NSString *)provider messages:(NSArray *)messages system:(NSString *)system tools:(NSArray *)tools model:(NSString *)model
{
    NSMutableArray *log = [NSMutableArray array];
    TBFrameSink *sink = [[[TBFrameSink alloc] initWithSession:self] autorelease];
    int roundIndex = 0;
    NSString *lastOutput = @"";
    BOOL lastFailed = NO;
    BOOL anyText = NO;
    unsigned i;
    for (i = 0; i < [messages count]; i++) {
        NSDictionary *message = [messages objectAtIndex:i];
        NSMutableDictionary *entry = [NSMutableDictionary dictionaryWithObjectsAndKeys:TBString(message, @"role"), @"role", TBString(message, @"content"), @"content", nil];
        if ([TBArray(message, @"images") count])
            [entry setObject:TBArray(message, @"images") forKey:@"images"];
        [log addObject:entry];
    }
    for (;;) {
        TBRound *round;
        BOOL sawText;
        NSMutableString *spoken = [NSMutableString string];
        NSArray *calls;
        NSString *usageText;
        NSMutableArray *shots = [NSMutableArray array];
        unsigned c;
        [run check];
        if (roundIndex) {
            [self emit:@"s" text:@"Working on the next step..."];
            if (lastContext && lastContext >= [self contextLimitForProvider:provider model:model] * kCompactAt) {
                NSString *note = [self compactLog:log provider:provider model:model];
                if ([note length])
                    [self emit:@"c" text:note];
            }
        }
        round = [[[TBRound alloc] init] autorelease];
        round->run = [run retain];
        round->sink = [[[TBTextCollector alloc] initWithSink:sink spoken:spoken] autorelease];
        @try {
            [TBProviders streamRound:provider system:system log:log tools:tools round:round model:model];
        } @catch (NSException *exception) {
            [run check];
            if (anyText || [lastOutput length] || [spoken length]) {
                [self emit:@"t" text:[self stoppedEarlyOutput:lastFailed ? lastOutput : @"" reason:[exception reason]]];
                return;
            }
            @throw;
        }
        [run check];
        sawText = [spoken length] > 0;
        if (sawText)
            anyText = YES;
        usageText = [self usageEventForProvider:provider model:model usage:round->usage];
        if (usageText)
            [self emit:@"u" text:usageText];
        calls = [NSArray arrayWithArray:round->calls];
        if (round->truncated) {
            if (!round->noted)
                [self emit:@"t" text:kLimitNote];
            return;
        }
        if ([calls count] == 0 || roundIndex >= [self maxSteps]) {
            if ([calls count] && roundIndex >= [self maxSteps])
                [self emit:@"t" text:[NSString stringWithFormat:kStepNote, [self maxSteps]]];
            else if (!sawText && lastFailed)
                [self emit:@"t" text:[self stoppedEarlyOutput:lastOutput reason:nil]];
            else if (!sawText && [lastOutput length] && !anyText)
                [self emit:@"t" text:lastOutput];
            else if (!sawText && [calls count] == 0 && !anyText && !roundIndex)
                TBFail(@"The model returned no text.");
            else if (!sawText && roundIndex && !anyText)
                [self emit:@"t" text:@"Done."];
            return;
        }
        {
            NSMutableDictionary *assistant = [NSMutableDictionary dictionaryWithObjectsAndKeys:@"assistant", @"role", [NSString stringWithString:spoken], @"content", calls, @"calls", nil];
            if (round->claudeBlocks)
                [assistant setObject:round->claudeBlocks forKey:@"claude_blocks"];
            [log addObject:assistant];
        }
        for (c = 0; c < [calls count]; c++) {
            NSDictionary *call = [calls objectAtIndex:c];
            NSDictionary *result = [self executeCall:call provider:provider];
            lastOutput = TBString(result, @"output");
            lastFailed = TBTruth(result, @"failed");
            [shots addObjectsFromArray:TBArray(result, @"images")];
            [log addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"tool", @"role", [TBString(call, @"id") length] ? TBString(call, @"id") : TBString(call, @"name"), @"id",
                TBString(call, @"name"), @"name", lastOutput, @"content", nil]];
        }
        {
            NSDictionary *shot = [self screenshotNoteForProvider:provider model:model images:shots];
            NSArray *notes;
            if (shot)
                [log addObject:shot];
            else if ([shots count])
                [log addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"user", @"role",
                    @"(A picture was returned, but this model cannot view images, so describe what you can from the file name, size and other tools.)", @"content", nil]];
            notes = [self takeGuidanceNotes];
            for (c = 0; c < [notes count]; c++)
                [log addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"user", @"role", [@"Note from the person while you work: " stringByAppendingString:[notes objectAtIndex:c]], @"content", nil]];
        }
        roundIndex++;
    }
}

/* A plain reply with no tools: titles, summaries, a consulted model. */
- (NSString *)completeProvider:(NSString *)provider model:(NSString *)model system:(NSString *)system messages:(NSArray *)messages
{
    TBSession *inner = [[[TBSession alloc] initWithRun:run options:nil frames:[[[TBCollectFrames alloc] init] autorelease]] autorelease];
    TBCollectFrames *collector = (TBCollectFrames *)inner->frames;
    NSString *text;
    [inner turn:messages useTools:NO provider:provider model:model systemOverride:system];
    text = TBTrim([collector->text componentsJoinedByString:@""]);
    {
        unsigned i;
        for (i = 0; i < [collector->usage count]; i++)
            [side addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"u", @"kind", [collector->usage objectAtIndex:i], @"text", nil]];
    }
    if ([text length] == 0)
        TBFail(@"The model returned no text.");
    return text;
}

@end
