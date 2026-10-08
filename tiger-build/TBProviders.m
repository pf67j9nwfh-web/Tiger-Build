#import "TBProviders.h"
#import "TBJSON.h"
#import "TBHTTP.h"

@interface TBProviders (Private)
+ (NSArray *)anthropicMessagesFromLog:(NSArray *)log;
+ (NSArray *)geminiContentsFromLog:(NSArray *)log;
@end

@implementation TBRound

- (id)init
{
    self = [super init];
    if (self) {
        calls = [[NSMutableArray alloc] init];
        usage = [[NSMutableDictionary alloc] initWithObjectsAndKeys:[NSNumber numberWithLongLong:0], @"input", [NSNumber numberWithLongLong:0], @"cached",
            [NSNumber numberWithLongLong:0], @"written", [NSNumber numberWithLongLong:0], @"output", nil];
    }
    return self;
}

- (void)dealloc
{
    [run release];
    [calls release];
    [claudeBlocks release];
    [usage release];
    [super dealloc];
}

- (void)addUsageInput:(long long)input cached:(long long)cached written:(long long)written output:(long long)output
{
    NSString *names[4] = {@"input", @"cached", @"written", @"output"};
    long long values[4];
    int i;
    values[0] = input;
    values[1] = cached;
    values[2] = written;
    values[3] = output;
    for (i = 0; i < 4; i++) {
        long long add = values[i] > 0 ? values[i] : 0;
        [usage setObject:[NSNumber numberWithLongLong:[[usage objectForKey:names[i]] longLongValue] + add] forKey:names[i]];
    }
}

@end

/* ---- the answer stream: <think> and tool-call markup are kept out of the visible text ---- */

@interface TBAnswerStream (Private)
- (NSArray *)drain:(BOOL)final;
- (void)think:(NSString *)text;
@end

@implementation TBAnswerStream

- (id)init
{
    self = [super init];
    if (self) {
        buf = [[NSMutableString alloc] init];
        visible = [[NSMutableArray alloc] init];
        hidden = [[NSMutableArray alloc] init];
        reasoning = [[NSMutableArray alloc] init];
        toolMarkup = [[NSMutableArray alloc] init];
        thoughts = [[NSMutableArray alloc] init];
        hiding = @"";
    }
    return self;
}

- (void)dealloc
{
    [buf release];
    [visible release];
    [hidden release];
    [reasoning release];
    [toolMarkup release];
    [thoughts release];
    [super dealloc];
}

- (NSArray *)toolMarkup
{
    return toolMarkup;
}

- (NSArray *)reasoningPieces
{
    return reasoning;
}

- (NSArray *)takeThoughts
{
    NSMutableArray *out = [NSMutableArray array];
    unsigned i;
    for (i = 0; i < [thoughts count]; i++) {
        if ([[thoughts objectAtIndex:i] length] > 0)
            [out addObject:[thoughts objectAtIndex:i]];
    }
    [thoughts removeAllObjects];
    return out;
}

- (void)addReasoning:(NSString *)text
{
    if ([text length])
        [reasoning addObject:text];
}

- (NSArray *)addContent:(NSString *)text
{
    if ([text length] == 0)
        return [NSArray array];
    [buf appendString:text];
    return [self drain:NO];
}

- (void)think:(NSString *)text
{
    if ([text length]) {
        [hidden addObject:text];
        [thoughts addObject:text];
    }
}

- (NSArray *)drain:(BOOL)final
{
    NSMutableArray *fresh = [NSMutableArray array];
    NSMutableArray *pieces = [NSMutableArray array];
    unsigned i;
    for (;;) {
        if ([hiding isEqualToString:@"think"]) {
            NSRange end = [buf rangeOfString:@"</think>"];
            if (end.location != NSNotFound) {
                [self think:[buf substringToIndex:end.location]];
                [buf deleteCharactersInRange:NSMakeRange(0, end.location + end.length)];
                hiding = @"";
                continue;
            }
            {
                unsigned keep = final ? 0 : 7;
                if ([buf length] > keep) {
                    unsigned cut = [buf length] - keep;
                    [self think:[buf substringToIndex:cut]];
                    [buf deleteCharactersInRange:NSMakeRange(0, cut)];
                }
            }
            if (final)
                hiding = @"";
            break;
        }
        if ([hiding isEqualToString:@"tool"]) {
            NSRange end = [buf rangeOfString:@"</tool_call>"];
            if (end.location == NSNotFound) {
                if (final) {
                    [toolMarkup addObject:[@"<tool_call>" stringByAppendingString:buf]];
                    [buf setString:@""];
                    hiding = @"";
                }
                break;
            }
            [toolMarkup addObject:[NSString stringWithFormat:@"<tool_call>%@</tool_call>", [buf substringToIndex:end.location]]];
            [buf deleteCharactersInRange:NSMakeRange(0, end.location + end.length)];
            hiding = @"";
            continue;
        }
        {
            NSRange thinkAt = [buf rangeOfString:@"<think>"];
            NSRange toolAt = [buf rangeOfString:@"<tool_call>"];
            NSRange start = NSMakeRange(NSNotFound, 0);
            NSString *kind = @"";
            if (thinkAt.location != NSNotFound && (toolAt.location == NSNotFound || thinkAt.location <= toolAt.location)) {
                start = thinkAt;
                kind = @"think";
            } else if (toolAt.location != NSNotFound) {
                start = toolAt;
                kind = @"tool";
            }
            if (start.location == NSNotFound) {
                if (!final) {
                    NSRange cut = [buf rangeOfString:@"<" options:NSBackwardsSearch];
                    if (cut.location != NSNotFound && cut.location + 20 >= [buf length]) {
                        [fresh addObject:[buf substringToIndex:cut.location]];
                        [buf deleteCharactersInRange:NSMakeRange(0, cut.location)];
                        break;
                    }
                }
                [fresh addObject:[NSString stringWithString:buf]];
                [buf setString:@""];
                break;
            }
            [fresh addObject:[buf substringToIndex:start.location]];
            [buf deleteCharactersInRange:NSMakeRange(0, start.location + start.length)];
            hiding = kind;
        }
    }
    for (i = 0; i < [fresh count]; i++) {
        NSString *piece = [fresh objectAtIndex:i];
        if ([piece length]) {
            [pieces addObject:piece];
            [visible addObject:piece];
        }
    }
    return pieces;
}

- (NSArray *)flush
{
    return [self drain:YES];
}

static NSString *stripThink(NSString *text)
{
    TBAnswerStream *stream = [[[TBAnswerStream alloc] init] autorelease];
    NSMutableArray *pieces = [NSMutableArray array];
    NSString *seen;
    [pieces addObjectsFromArray:[stream addContent:text]];
    [pieces addObjectsFromArray:[stream drain:YES]];
    seen = TBTrim([pieces componentsJoinedByString:@""]);
    if ([seen length])
        return seen;
    seen = TBTrim([stream->hidden componentsJoinedByString:@""]);
    if ([seen length])
        return seen;
    if ([text rangeOfString:@"<tool_call>"].location != NSNotFound)
        return @"";
    return TBTrim(text ? text : @"");
}

- (NSString *)finish
{
    NSString *thought;
    [self drain:YES];
    if ([TBTrim([visible componentsJoinedByString:@""]) length])
        return @"";
    thought = TBTrim([reasoning componentsJoinedByString:@""]);
    if ([thought length]) {
        if ([thought rangeOfString:@"<tool_call>"].location != NSNotFound)
            [toolMarkup addObject:thought];
        return stripThink(thought);
    }
    return TBTrim([hidden componentsJoinedByString:@""]);
}

@end

/* ---- the catalogue ---- */

static NSMutableArray *providerList = nil;
static NSMutableDictionary *modelLists = nil;
static NSMutableDictionary *defaultModels = nil;

static void loadCatalog(void)
{
    NSString *text;
    NSArray *lines;
    unsigned i;
    if (providerList)
        return;
    providerList = [[NSMutableArray alloc] init];
    modelLists = [[NSMutableDictionary alloc] init];
    defaultModels = [[NSMutableDictionary alloc] init];
    text = [NSString stringWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"models" ofType:@"txt"]];
    if (!text)
        text = [NSString stringWithContentsOfFile:@"models.txt"];
    lines = [text componentsSeparatedByString:@"\n"];
    for (i = 0; i < [lines count]; i++) {
        NSArray *parts = [[lines objectAtIndex:i] componentsSeparatedByString:@"\t"];
        if ([parts count] >= 3 && [[parts objectAtIndex:0] isEqualToString:@"provider"]) {
            [providerList addObject:[NSDictionary dictionaryWithObjectsAndKeys:[parts objectAtIndex:1], @"id", [parts objectAtIndex:2], @"title", nil]];
            [modelLists setObject:[NSMutableArray array] forKey:[parts objectAtIndex:1]];
        } else if ([parts count] >= 5 && [[parts objectAtIndex:0] isEqualToString:@"model"]) {
            NSMutableArray *list = [modelLists objectForKey:[parts objectAtIndex:1]];
            [list addObject:[NSDictionary dictionaryWithObjectsAndKeys:[parts objectAtIndex:2], @"id", [parts objectAtIndex:3], @"title", nil]];
            if ([[parts objectAtIndex:4] isEqualToString:@"1"])
                [defaultModels setObject:[parts objectAtIndex:2] forKey:[parts objectAtIndex:1]];
        }
    }
}

static NSString *OPENAI_URL = @"https://api.openai.com/v1/chat/completions";
static NSString *OPENAI_RESPONSES_URL = @"https://api.openai.com/v1/responses";
static NSString *MUSE_URL = @"https://api.meta.ai/v1/chat/completions";
static NSString *MISTRAL_URL = @"https://api.mistral.ai/v1/chat/completions";
static NSString *ANTHROPIC_URL = @"https://api.anthropic.com/v1/messages";
static NSString *GEMINI_URL = @"https://generativelanguage.googleapis.com/v1beta/models/%@:streamGenerateContent?alt=sse";

/* A different address for a service, for tests: the preference TBBaseURL.<provider>. */
static NSString *baseOverride(NSString *provider, NSString *standard)
{
    NSString *over = [[NSUserDefaults standardUserDefaults] stringForKey:[@"TBBaseURL." stringByAppendingString:provider]];
    return [over length] ? over : standard;
}

@implementation TBProviders

+ (NSArray *)providers
{
    loadCatalog();
    return providerList;
}

+ (NSArray *)modelsForProvider:(NSString *)provider
{
    loadCatalog();
    return [modelLists objectForKey:provider];
}

+ (NSString *)defaultModelForProvider:(NSString *)provider
{
    loadCatalog();
    return [defaultModels objectForKey:provider];
}

+ (NSString *)normalize:(NSString *)name
{
    NSString *key = [TBTrim(name ? name : @"") lowercaseString];
    NSDictionary *aliases = [NSDictionary dictionaryWithObjectsAndKeys:@"grok", @"grok", @"grok", @"xai", @"chatgpt", @"chatgpt", @"chatgpt", @"openai",
        @"chatgpt", @"gpt", @"claude", @"claude", @"claude", @"anthropic", @"muse", @"muse", @"muse", @"meta", @"mistral", @"mistral",
        @"gemini", @"gemini", @"gemini", @"google", @"local", @"local", @"local", @"lmstudio", @"local", @"lm-studio", @"local", @"ollama", nil];
    NSString *found;
    if ([key length] == 0)
        return @"grok";
    found = [aliases objectForKey:key];
    if (!found)
        TBFail(@"Unknown model %@.", name);
    return found;
}

+ (BOOL)modelAllowed:(NSString *)model provider:(NSString *)provider
{
    NSArray *list = [self modelsForProvider:provider];
    unsigned i;
    for (i = 0; i < [list count]; i++) {
        if ([[[list objectAtIndex:i] objectForKey:@"id"] isEqualToString:model])
            return YES;
    }
    return NO;
}

+ (NSString *)resolveModel:(NSString *)requested provider:(NSString *)provider
{
    NSString *wanted = [requested isKindOfClass:[NSString class]] ? TBTrim(requested) : @"";
    loadCatalog();
    if ([provider isEqualToString:@"local"]) {
        if ([wanted length] == 0 || [wanted length] > 180 || [wanted rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound
            || [wanted hasPrefix:@"/"] || [wanted hasPrefix:@"\\"] || [wanted rangeOfString:@".."].location != NSNotFound)
            return @"";
        return wanted;
    }
    if (![modelLists objectForKey:provider])
        provider = @"grok";
    if ([wanted length] && [self modelAllowed:wanted provider:provider])
        return wanted;
    return [defaultModels objectForKey:provider];
}

+ (int)contextLimitForModel:(NSString *)model
{
    static const struct { const char *prefix; int limit; } table[] = {
        {"gpt-4-turbo", 128000}, {"gpt-4.1", 1047576}, {"gpt-4o", 128000}, {"gpt-3.5", 16385}, {"gpt-5", 400000}, {"gpt-6", 400000},
        {"chat-latest", 128000}, {"o1", 200000}, {"o3", 200000}, {"o4", 200000}, {"grok-", 256000}, {"claude-", 200000},
        {"gemini-", 1048576}, {"gemma-", 131072}, {"muse-", 128000}, {"ministral-", 131072}, {"codestral", 256000},
        {"mistral", 128000}, {"voxtral", 32768}, {NULL, 0}};
    int i;
    if ([model length] == 0)
        return 32000;
    if ([model isEqualToString:@"gpt-4"])
        return 8192;
    for (i = 0; table[i].prefix; i++) {
        if ([model hasPrefix:[NSString stringWithUTF8String:table[i].prefix]])
            return table[i].limit;
    }
    return 32000;
}

+ (NSString *)apiErrorText:(NSString *)detail code:(int)code
{
    id parsed = TBJSONParseString(detail, NULL);
    NSString *text;
    if ([parsed isKindOfClass:[NSDictionary class]]) {
        id err = TBValue(parsed, @"error");
        if ([err isKindOfClass:[NSDictionary class]] && [TBString(err, @"message") length])
            detail = TBString(err, @"message");
        else if ([err isKindOfClass:[NSString class]])
            detail = err;
    }
    if ([detail length] > 800)
        detail = [detail substringToIndex:800];
    text = [NSString stringWithFormat:@"The model service returned %d: %@", code, detail];
    if ([detail rangeOfString:@"anthropic-workspace-id"].location != NSNotFound)
        text = [text stringByAppendingString:@" Your Anthropic key needs its workspace ID: add it in Tiger Build Preferences under Workspace ID (optional)."];
    return text;
}

+ (NSString *)localBase
{
    NSString *text = [TBSettings valueForName:@"local_url"];
    NSString *lower;
    if ([text length] == 0)
        return @"";
    while ([text hasSuffix:@"/"])
        text = [text substringToIndex:[text length] - 1];
    lower = [text lowercaseString];
    if (!([lower hasPrefix:@"http://"] || [lower hasPrefix:@"https://"]) || [text rangeOfString:@" "].location != NSNotFound
        || [text rangeOfString:@".."].location != NSNotFound)
        return @"";
    if (![lower hasSuffix:@"/v1"])
        text = [text stringByAppendingString:@"/v1"];
    return text;
}

@end

/* ---- tools and messages in each service's shape ---- */

static NSDictionary *emptySchema(void)
{
    return [NSDictionary dictionaryWithObjectsAndKeys:@"object", @"type", [NSDictionary dictionary], @"properties", nil];
}

static NSString *toolDescription(NSDictionary *tool)
{
    NSString *d = TBString(tool, @"description");
    return [d length] ? d : TBString(tool, @"name");
}

static id toolParameters(NSDictionary *tool)
{
    id p = TBValue(tool, @"parameters");
    return p ? p : emptySchema();
}

static NSArray *openAITools(NSArray *tools)
{
    NSMutableArray *out = [NSMutableArray array];
    unsigned i;
    for (i = 0; i < [tools count]; i++) {
        NSDictionary *tool = [tools objectAtIndex:i];
        [out addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"function", @"type",
            [NSDictionary dictionaryWithObjectsAndKeys:TBString(tool, @"name"), @"name", toolDescription(tool), @"description", toolParameters(tool), @"parameters", nil], @"function", nil]];
    }
    return out;
}

static NSArray *anthropicTools(NSArray *tools)
{
    NSMutableArray *out = [NSMutableArray array];
    unsigned i;
    for (i = 0; i < [tools count]; i++) {
        NSDictionary *tool = [tools objectAtIndex:i];
        [out addObject:[NSDictionary dictionaryWithObjectsAndKeys:TBString(tool, @"name"), @"name", toolDescription(tool), @"description",
            toolParameters(tool), @"input_schema", nil]];
    }
    return out;
}

static NSArray *geminiTools(NSArray *tools)
{
    NSMutableArray *declarations = [NSMutableArray array];
    unsigned i;
    for (i = 0; i < [tools count]; i++) {
        NSDictionary *tool = [tools objectAtIndex:i];
        [declarations addObject:[NSDictionary dictionaryWithObjectsAndKeys:TBString(tool, @"name"), @"name", toolDescription(tool), @"description",
            toolParameters(tool), @"parameters", nil]];
    }
    if ([declarations count] == 0)
        return nil;
    return [NSArray arrayWithObject:[NSDictionary dictionaryWithObject:declarations forKey:@"functionDeclarations"]];
}

/* Tool arguments as an object: they arrive as JSON text. */
static NSDictionary *parseArgs(id raw)
{
    id parsed;
    if ([raw isKindOfClass:[NSDictionary class]])
        return raw;
    if (![raw isKindOfClass:[NSString class]] || [raw length] == 0)
        return [NSDictionary dictionary];
    parsed = TBJSONParseString(raw, NULL);
    return [parsed isKindOfClass:[NSDictionary class]] ? parsed : [NSDictionary dictionary];
}

static NSString *argsText(id arguments)
{
    if ([arguments isKindOfClass:[NSString class]])
        return arguments;
    return TBJSONString(arguments ? arguments : [NSDictionary dictionary]);
}

static NSArray *imageParts(NSDictionary *item)
{
    NSMutableArray *out = [NSMutableArray array];
    NSArray *images = TBArray(item, @"images");
    unsigned i;
    for (i = 0; i < [images count]; i++) {
        id image = [images objectAtIndex:i];
        if ([image isKindOfClass:[NSDictionary class]] && [TBString(image, @"data") length])
            [out addObject:image];
    }
    return out;
}

static NSString *mimeOf(NSDictionary *image)
{
    NSString *m = TBString(image, @"mime");
    return [m length] ? m : @"image/jpeg";
}

static NSString *orScreenshot(NSString *text)
{
    return [text length] ? text : @"(screenshot)";
}

@implementation TBProviders (Messages)

+ (NSArray *)openAIMessagesWithSystem:(NSString *)system log:(NSArray *)log
{
    NSMutableArray *messages = [NSMutableArray array];
    unsigned i;
    [messages addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"system", @"role", system, @"content", nil]];
    for (i = 0; i < [log count]; i++) {
        NSDictionary *item = [log objectAtIndex:i];
        NSString *role = TBString(item, @"role");
        if ([role isEqualToString:@"tool"]) {
            [messages addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"tool", @"role", TBString(item, @"id"), @"tool_call_id", TBString(item, @"content"), @"content", nil]];
            continue;
        }
        if ([role isEqualToString:@"assistant"] && [TBArray(item, @"calls") count]) {
            NSMutableArray *toolCalls = [NSMutableArray array];
            NSArray *calls = TBArray(item, @"calls");
            unsigned c;
            for (c = 0; c < [calls count]; c++) {
                NSDictionary *call = [calls objectAtIndex:c];
                [toolCalls addObject:[NSDictionary dictionaryWithObjectsAndKeys:TBString(call, @"id"), @"id", @"function", @"type",
                    [NSDictionary dictionaryWithObjectsAndKeys:TBString(call, @"name"), @"name", argsText(TBValue(call, @"arguments")), @"arguments", nil], @"function", nil]];
            }
            [messages addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"assistant", @"role",
                [TBString(item, @"content") length] ? (id)TBString(item, @"content") : (id)[NSNull null], @"content", toolCalls, @"tool_calls", nil]];
            continue;
        }
        if ([role isEqualToString:@"user"] && [imageParts(item) count]) {
            NSMutableArray *parts = [NSMutableArray array];
            NSArray *images = imageParts(item);
            unsigned m;
            [parts addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"text", @"type", orScreenshot(TBString(item, @"content")), @"text", nil]];
            for (m = 0; m < [images count]; m++) {
                NSDictionary *image = [images objectAtIndex:m];
                [parts addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"image_url", @"type",
                    [NSDictionary dictionaryWithObject:[NSString stringWithFormat:@"data:%@;base64,%@", mimeOf(image), TBString(image, @"data")] forKey:@"url"], @"image_url", nil]];
            }
            [messages addObject:[NSDictionary dictionaryWithObjectsAndKeys:role, @"role", parts, @"content", nil]];
            continue;
        }
        [messages addObject:[NSDictionary dictionaryWithObjectsAndKeys:role, @"role", TBString(item, @"content"), @"content", nil]];
    }
    return messages;
}

+ (NSArray *)openAIResponsesInput:(NSArray *)log
{
    NSMutableArray *items = [NSMutableArray array];
    unsigned i;
    for (i = 0; i < [log count]; i++) {
        NSDictionary *item = [log objectAtIndex:i];
        NSString *role = TBString(item, @"role");
        if ([role isEqualToString:@"tool"]) {
            [items addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"function_call_output", @"type", TBString(item, @"id"), @"call_id", TBString(item, @"content"), @"output", nil]];
            continue;
        }
        if ([role isEqualToString:@"assistant"]) {
            NSArray *calls = TBArray(item, @"calls");
            unsigned c;
            if ([TBString(item, @"content") length])
                [items addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"assistant", @"role", TBString(item, @"content"), @"content", nil]];
            for (c = 0; c < [calls count]; c++) {
                NSDictionary *call = [calls objectAtIndex:c];
                [items addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"function_call", @"type", TBString(call, @"id"), @"call_id", TBString(call, @"name"), @"name",
                    argsText(TBValue(call, @"arguments")), @"arguments", nil]];
            }
            continue;
        }
        if ([role isEqualToString:@"user"] && [imageParts(item) count]) {
            NSMutableArray *parts = [NSMutableArray array];
            NSArray *images = imageParts(item);
            unsigned m;
            [parts addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"input_text", @"type", orScreenshot(TBString(item, @"content")), @"text", nil]];
            for (m = 0; m < [images count]; m++) {
                NSDictionary *image = [images objectAtIndex:m];
                [parts addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"input_image", @"type",
                    [NSString stringWithFormat:@"data:%@;base64,%@", mimeOf(image), TBString(image, @"data")], @"image_url", nil]];
            }
            [items addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"user", @"role", parts, @"content", nil]];
            continue;
        }
        if ([role isEqualToString:@"user"] || [role isEqualToString:@"assistant"])
            [items addObject:[NSDictionary dictionaryWithObjectsAndKeys:role, @"role", TBString(item, @"content"), @"content", nil]];
    }
    return items;
}

+ (NSArray *)ensureUserFirst:(NSArray *)log
{
    NSMutableArray *out;
    if ([log count] == 0 || [TBString([log objectAtIndex:0], @"role") isEqualToString:@"user"])
        return log;
    out = [NSMutableArray arrayWithObject:[NSDictionary dictionaryWithObjectsAndKeys:@"user", @"role", @"Hello.", @"content", nil]];
    [out addObjectsFromArray:log];
    return out;
}

/* LM Studio's Qwen template asks for tool calls as XML, not as OpenAI chunks. */
+ (NSArray *)qwenToolCalls:(NSString *)text
{
    NSMutableArray *calls = [NSMutableArray array];
    NSArray *chunks;
    unsigned i, index = 0;
    if ([text length] == 0 || [text rangeOfString:@"<tool_call>"].location == NSNotFound)
        return calls;
    chunks = [text componentsSeparatedByString:@"<tool_call>"];
    for (i = 1; i < [chunks count]; i++) {
        NSString *body = [[[chunks objectAtIndex:i] componentsSeparatedByString:@"</tool_call>"] objectAtIndex:0];
        NSRange nameAt = [body rangeOfString:@"<function="];
        NSRange nameEnd;
        NSString *name, *rest;
        NSMutableDictionary *params = [NSMutableDictionary dictionary];
        if (nameAt.location == NSNotFound)
            continue;
        nameEnd = [body rangeOfString:@">" options:0 range:NSMakeRange(nameAt.location, [body length] - nameAt.location)];
        if (nameEnd.location == NSNotFound)
            continue;
        name = TBTrim([body substringWithRange:NSMakeRange(nameAt.location + 10, nameEnd.location - nameAt.location - 10)]);
        if ([name length] == 0)
            continue;
        rest = [body substringFromIndex:nameEnd.location + 1];
        for (;;) {
            NSRange mark = [rest rangeOfString:@"<parameter="];
            NSRange end, close;
            NSString *key;
            if (mark.location == NSNotFound)
                break;
            end = [rest rangeOfString:@">" options:0 range:NSMakeRange(mark.location, [rest length] - mark.location)];
            if (end.location == NSNotFound)
                break;
            key = TBTrim([rest substringWithRange:NSMakeRange(mark.location + 11, end.location - mark.location - 11)]);
            close = [rest rangeOfString:@"</parameter>" options:0 range:NSMakeRange(end.location, [rest length] - end.location)];
            if (close.location == NSNotFound) {
                [params setObject:TBTrim([rest substringFromIndex:end.location + 1]) forKey:key];
                break;
            }
            [params setObject:TBTrim([rest substringWithRange:NSMakeRange(end.location + 1, close.location - end.location - 1)]) forKey:key];
            rest = [rest substringFromIndex:close.location + close.length];
        }
        index++;
        [calls addObject:[NSDictionary dictionaryWithObjectsAndKeys:[NSString stringWithFormat:@"%@-%u", name, index], @"id", name, @"name", TBJSONString(params), @"arguments", nil]];
    }
    return calls;
}

+ (NSArray *)anthropicMessagesFromLog:(NSArray *)log
{
    NSMutableArray *messages = [NSMutableArray array];
    unsigned i;
    for (i = 0; i < [log count]; i++) {
        NSDictionary *item = [log objectAtIndex:i];
        NSString *role = TBString(item, @"role");
        NSMutableDictionary *last = [messages count] ? [messages lastObject] : nil;
        BOOL lastUserList = last && [TBString(last, @"role") isEqualToString:@"user"] && [TBValue(last, @"content") isKindOfClass:[NSArray class]];
        if ([role isEqualToString:@"tool"]) {
            NSDictionary *block = [NSDictionary dictionaryWithObjectsAndKeys:@"tool_result", @"type", TBString(item, @"id"), @"tool_use_id", TBString(item, @"content"), @"content", nil];
            if (lastUserList) {
                NSMutableArray *content = [NSMutableArray arrayWithArray:TBArray(last, @"content")];
                [content addObject:block];
                [last setObject:content forKey:@"content"];
            } else {
                [messages addObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:@"user", @"role", [NSArray arrayWithObject:block], @"content", nil]];
            }
            continue;
        }
        if ([role isEqualToString:@"assistant"] && TBArray(item, @"claude_blocks") && [TBArray(item, @"claude_blocks") count]) {
            [messages addObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:@"assistant", @"role", TBArray(item, @"claude_blocks"), @"content", nil]];
            continue;
        }
        if ([role isEqualToString:@"assistant"] && [TBArray(item, @"calls") count]) {
            NSMutableArray *blocks = [NSMutableArray array];
            NSArray *calls = TBArray(item, @"calls");
            unsigned c;
            if ([TBString(item, @"content") length])
                [blocks addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"text", @"type", TBString(item, @"content"), @"text", nil]];
            for (c = 0; c < [calls count]; c++) {
                NSDictionary *call = [calls objectAtIndex:c];
                [blocks addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"tool_use", @"type", TBString(call, @"id"), @"id", TBString(call, @"name"), @"name",
                    parseArgs(TBValue(call, @"arguments")), @"input", nil]];
            }
            [messages addObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:@"assistant", @"role", blocks, @"content", nil]];
            continue;
        }
        if ([role isEqualToString:@"user"] && ([imageParts(item) count] || lastUserList)) {
            NSMutableArray *blocks = [NSMutableArray array];
            NSArray *images = imageParts(item);
            unsigned m;
            [blocks addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"text", @"type", orScreenshot(TBString(item, @"content")), @"text", nil]];
            for (m = 0; m < [images count]; m++) {
                NSDictionary *image = [images objectAtIndex:m];
                [blocks addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"image", @"type",
                    [NSDictionary dictionaryWithObjectsAndKeys:@"base64", @"type", mimeOf(image), @"media_type", TBString(image, @"data"), @"data", nil], @"source", nil]];
            }
            if (lastUserList) {
                NSMutableArray *content = [NSMutableArray arrayWithArray:TBArray(last, @"content")];
                [content addObjectsFromArray:blocks];
                [last setObject:content forKey:@"content"];
            } else {
                [messages addObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:@"user", @"role", blocks, @"content", nil]];
            }
            continue;
        }
        if ([role isEqualToString:@"user"] || [role isEqualToString:@"assistant"])
            [messages addObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:role, @"role", TBString(item, @"content"), @"content", nil]];
    }
    return messages;
}

+ (NSArray *)geminiContentsFromLog:(NSArray *)log
{
    NSMutableArray *contents = [NSMutableArray array];
    unsigned i;
    for (i = 0; i < [log count]; i++) {
        NSDictionary *item = [log objectAtIndex:i];
        NSString *role = TBString(item, @"role");
        NSMutableDictionary *last = [contents count] ? [contents lastObject] : nil;
        if ([role isEqualToString:@"tool"]) {
            NSMutableDictionary *response = [NSMutableDictionary dictionaryWithObjectsAndKeys:TBString(item, @"name"), @"name",
                [NSDictionary dictionaryWithObject:TBString(item, @"content") forKey:@"result"], @"response", nil];
            NSDictionary *part;
            if ([TBString(item, @"id") length] && ![TBString(item, @"id") isEqualToString:TBString(item, @"name")])
                [response setObject:TBString(item, @"id") forKey:@"id"];
            part = [NSDictionary dictionaryWithObject:response forKey:@"functionResponse"];
            if (last && [TBString(last, @"role") isEqualToString:@"user"]) {
                NSMutableArray *parts = [NSMutableArray arrayWithArray:TBArray(last, @"parts")];
                [parts addObject:part];
                [last setObject:parts forKey:@"parts"];
            } else {
                [contents addObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:@"user", @"role", [NSArray arrayWithObject:part], @"parts", nil]];
            }
            continue;
        }
        if ([role isEqualToString:@"assistant"]) {
            NSMutableArray *parts = [NSMutableArray array];
            NSArray *calls = TBArray(item, @"calls");
            unsigned c;
            if ([TBString(item, @"content") length])
                [parts addObject:[NSDictionary dictionaryWithObject:TBString(item, @"content") forKey:@"text"]];
            for (c = 0; c < [calls count]; c++) {
                NSDictionary *call = [calls objectAtIndex:c];
                NSMutableDictionary *functionCall = [NSMutableDictionary dictionaryWithObjectsAndKeys:TBString(call, @"name"), @"name", parseArgs(TBValue(call, @"arguments")), @"args", nil];
                NSMutableDictionary *part;
                if ([TBString(call, @"id") length] && ![TBString(call, @"id") isEqualToString:TBString(call, @"name")])
                    [functionCall setObject:TBString(call, @"id") forKey:@"id"];
                part = [NSMutableDictionary dictionaryWithObject:functionCall forKey:@"functionCall"];
                if ([TBString(call, @"thought_signature") length])
                    [part setObject:TBString(call, @"thought_signature") forKey:@"thoughtSignature"];
                [parts addObject:part];
            }
            if ([parts count])
                [contents addObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:@"model", @"role", parts, @"parts", nil]];
            continue;
        }
        if ([role isEqualToString:@"user"]) {
            NSMutableArray *parts = [NSMutableArray array];
            NSArray *images = imageParts(item);
            unsigned m;
            BOOL afterResponse = NO;
            [parts addObject:[NSDictionary dictionaryWithObject:orScreenshot(TBString(item, @"content")) forKey:@"text"]];
            for (m = 0; m < [images count]; m++) {
                NSDictionary *image = [images objectAtIndex:m];
                [parts addObject:[NSDictionary dictionaryWithObject:[NSDictionary dictionaryWithObjectsAndKeys:mimeOf(image), @"mimeType", TBString(image, @"data"), @"data", nil] forKey:@"inlineData"]];
            }
            if (last && [TBString(last, @"role") isEqualToString:@"user"]) {
                NSArray *lastParts = TBArray(last, @"parts");
                unsigned p;
                for (p = 0; p < [lastParts count]; p++) {
                    if ([TBValue([lastParts objectAtIndex:p], @"functionResponse") isKindOfClass:[NSDictionary class]])
                        afterResponse = YES;
                }
            }
            if (afterResponse) {
                NSMutableArray *all = [NSMutableArray arrayWithArray:TBArray(last, @"parts")];
                [all addObjectsFromArray:parts];
                [last setObject:all forKey:@"parts"];
            } else {
                [contents addObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:@"user", @"role", parts, @"parts", nil]];
            }
        }
    }
    return contents;
}

@end

/* ---- reading a stream ---- */

static NSString *pieceText(id value)
{
    if ([value isKindOfClass:[NSString class]])
        return value;
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSString *t = TBString(value, @"text");
        return [t length] ? t : TBString(value, @"content");
    }
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableString *out = [NSMutableString string];
        unsigned i;
        for (i = 0; i < [value count]; i++) {
            id item = [value objectAtIndex:i];
            if ([item isKindOfClass:[NSString class]])
                [out appendString:item];
            else if ([item isKindOfClass:[NSDictionary class]]) {
                NSString *t = TBString(item, @"text");
                [out appendString:[t length] ? t : TBString(item, @"content")];
            }
        }
        return out;
    }
    return @"";
}

/* Mistral Magistral sends content as chunks; the {"type":"thinking"} ones hold the reasoning. */
static NSString *chunkThinking(id value)
{
    NSMutableString *out = [NSMutableString string];
    unsigned i;
    if (![value isKindOfClass:[NSArray class]])
        return @"";
    for (i = 0; i < [value count]; i++) {
        id item = [value objectAtIndex:i];
        if ([item isKindOfClass:[NSDictionary class]] && [TBString(item, @"type") isEqualToString:@"thinking"])
            [out appendString:pieceText(TBValue(item, @"thinking"))];
    }
    return out;
}

static NSString *streamFailure(id item)
{
    id err;
    NSString *message = @"";
    NSRange newline;
    if (![item isKindOfClass:[NSDictionary class]] || [TBArray(item, @"choices") count])
        return @"";
    err = TBValue(item, @"error");
    if ([err isKindOfClass:[NSDictionary class]])
        message = TBString(err, @"message");
    else if ([err isKindOfClass:[NSString class]])
        message = err;
    if ([message length] == 0)
        message = TBString(item, @"message");
    message = TBTrim(message);
    newline = [message rangeOfString:@"\n"];
    if (newline.location != NSNotFound)
        message = TBTrim([message substringToIndex:newline.location]);
    return [message length] > 400 ? [message substringToIndex:400] : message;
}

static void noteOpenAIUsage(TBRound *round, id usage)
{
    long long prompt, cached, output;
    id details;
    if (![usage isKindOfClass:[NSDictionary class]])
        return;
    prompt = TBInteger(usage, @"prompt_tokens") ? TBInteger(usage, @"prompt_tokens") : TBInteger(usage, @"input_tokens");
    details = TBDictionary(usage, @"prompt_tokens_details") ? TBDictionary(usage, @"prompt_tokens_details") : TBDictionary(usage, @"input_tokens_details");
    cached = TBInteger(details, @"cached_tokens");
    output = TBInteger(usage, @"completion_tokens") ? TBInteger(usage, @"completion_tokens") : TBInteger(usage, @"output_tokens");
    [round addUsageInput:prompt - cached cached:cached written:0 output:output];
}

enum { StreamOpenAI = 1, StreamResponses, StreamClaude, StreamGemini };

/* The state of one streaming request, fed by the HTTP layer as the reply arrives. */
@interface TBStreamer : NSObject {
@public
    TBRound *round;
    int kind;
    BOOL thinking;
    TBSSE *sse;
    NSString *failure;
    /* chat completions */
    NSMutableDictionary *slots;
    TBAnswerStream *answer;
    BOOL finished;
    /* responses */
    NSDictionary *completed;
    /* claude */
    NSMutableDictionary *blocks;
    NSMutableDictionary *arguments;
    NSMutableSet *complete;
    NSString *stop;
    NSDictionary *started;
    NSDictionary *ended;
    /* gemini */
    NSMutableArray *gcalls;
    NSMutableDictionary *seen;
    NSString *looseSignature;
    NSDictionary *meta;
}
- (id)initFor:(int)kind round:(TBRound *)round thinking:(BOOL)thinking;
@end

@implementation TBStreamer

- (id)initFor:(int)which round:(TBRound *)r thinking:(BOOL)think
{
    self = [super init];
    if (self) {
        kind = which;
        round = [r retain];
        thinking = think;
        sse = [[TBSSE alloc] init];
        slots = [[NSMutableDictionary alloc] init];
        answer = [[TBAnswerStream alloc] init];
        blocks = [[NSMutableDictionary alloc] init];
        arguments = [[NSMutableDictionary alloc] init];
        complete = [[NSMutableSet alloc] init];
        gcalls = [[NSMutableArray alloc] init];
        seen = [[NSMutableDictionary alloc] init];
        stop = @"";
        looseSignature = @"";
    }
    return self;
}

- (void)dealloc
{
    [round release];
    [sse release];
    [failure release];
    [slots release];
    [answer release];
    [completed release];
    [blocks release];
    [arguments release];
    [complete release];
    [stop release];
    [started release];
    [ended release];
    [gcalls release];
    [seen release];
    [looseSignature release];
    [meta release];
    [super dealloc];
}

- (void)say:(NSString *)text
{
    if ([text length]) {
        round->spoke = YES;
        [round->sink round:round text:text];
    }
}

- (void)think:(NSString *)text
{
    if ([text length]) {
        round->spoke = YES;
        [round->sink round:round thinking:text];
    }
}

- (void)fail:(NSString *)message
{
    if (!failure)
        failure = [message copy];
}

- (void)openAIItem:(NSDictionary *)item
{
    NSString *problem = streamFailure(item);
    NSArray *choices;
    NSDictionary *choice, *delta, *message;
    NSMutableArray *sources = [NSMutableArray array];
    unsigned s;
    NSArray *toolCalls;
    unsigned c;
    if ([problem length]) {
        [self fail:problem];
        return;
    }
    if ([TBValue(item, @"usage") isKindOfClass:[NSDictionary class]])
        noteOpenAIUsage(round, TBValue(item, @"usage"));
    choices = TBArray(item, @"choices");
    if ([choices count] == 0)
        return;
    choice = [choices objectAtIndex:0];
    if (![choice isKindOfClass:[NSDictionary class]])
        return;
    delta = TBDictionary(choice, @"delta");
    if (!delta)
        delta = [NSDictionary dictionary];
    [sources addObject:[NSArray arrayWithObjects:delta, TBValue(choice, @"reasoning_content") ? TBValue(choice, @"reasoning_content") : (id)[NSNull null], nil]];
    message = TBDictionary(choice, @"message");
    if (message)
        [sources addObject:[NSArray arrayWithObjects:message, [NSNull null], nil]];
    for (s = 0; s < [sources count]; s++) {
        NSDictionary *source = [[sources objectAtIndex:s] objectAtIndex:0];
        id extra = [[sources objectAtIndex:s] objectAtIndex:1];
        id content = TBValue(source, @"content");
        id first = TBValue(source, @"reasoning_content");
        NSString *reasoning;
        NSArray *pieces;
        unsigned p;
        if (!TBTruthy(first))
            first = TBValue(source, @"reasoning");
        if (!TBTruthy(first))
            first = TBValue(source, @"reasoning_details");
        reasoning = [NSString stringWithFormat:@"%@%@%@", pieceText(first), pieceText(extra == (id)[NSNull null] ? nil : extra), chunkThinking(content)];
        [answer addReasoning:reasoning];
        if (thinking && [reasoning length])
            [self think:reasoning];
        pieces = [answer addContent:pieceText(content)];
        if (thinking) {
            NSArray *thoughts = [answer takeThoughts];
            for (p = 0; p < [thoughts count]; p++)
                [self think:[thoughts objectAtIndex:p]];
        }
        for (p = 0; p < [pieces count]; p++)
            [self say:[pieces objectAtIndex:p]];
    }
    toolCalls = TBArray(delta, @"tool_calls");
    for (c = 0; c < [toolCalls count]; c++) {
        NSDictionary *call = [toolCalls objectAtIndex:c];
        NSNumber *index = [NSNumber numberWithLongLong:TBValue(call, @"index") ? TBInteger(call, @"index") : 0];
        NSMutableDictionary *slot = [slots objectForKey:index];
        NSDictionary *function = TBDictionary(call, @"function");
        if (!slot) {
            slot = [NSMutableDictionary dictionaryWithObjectsAndKeys:@"", @"id", @"", @"name", [NSMutableString string], @"arguments", nil];
            [slots setObject:slot forKey:index];
        }
        if ([TBString(call, @"id") length])
            [slot setObject:TBString(call, @"id") forKey:@"id"];
        if ([TBString(function, @"name") length])
            [slot setObject:TBString(function, @"name") forKey:@"name"];
        if ([TBString(function, @"arguments") length])
            [[slot objectForKey:@"arguments"] appendString:TBString(function, @"arguments")];
    }
    if (TBTruthy(TBValue(choice, @"finish_reason"))) {
        if ([TBString(choice, @"finish_reason") isEqualToString:@"length"])
            round->truncated = YES;
        finished = YES;
    }
}

- (void)responsesItem:(NSDictionary *)item
{
    NSString *type = TBString(item, @"type");
    if ([type isEqualToString:@"response.output_text.delta"] && [TBString(item, @"delta") length]) {
        [self say:TBString(item, @"delta")];
    } else if ([type isEqualToString:@"response.reasoning_summary_text.delta"] && [TBString(item, @"delta") length]) {
        if (thinking)
            [self think:TBString(item, @"delta")];
    } else if ([type isEqualToString:@"response.reasoning_summary_part.done"] && thinking) {
        [self think:@"\n\n"];
    } else if (([type isEqualToString:@"response.completed"] || [type isEqualToString:@"response.incomplete"]) && TBDictionary(item, @"response")) {
        [completed release];
        completed = [TBDictionary(item, @"response") retain];
        if ([type isEqualToString:@"response.incomplete"])
            round->truncated = YES;
    } else if ([type isEqualToString:@"error"] || [type isEqualToString:@"response.failed"]) {
        id err = TBValue(item, @"error");
        NSString *message;
        if (!TBTruthy(err))
            err = TBValue(TBDictionary(item, @"response"), @"error");
        message = TBString(err, @"message");
        [self fail:[message length] ? message : @"The model failed."];
    }
}

- (void)claudeItem:(NSDictionary *)item
{
    NSString *type = TBString(item, @"type");
    NSNumber *index = [NSNumber numberWithLongLong:TBValue(item, @"index") ? TBInteger(item, @"index") : 0];
    if ([type isEqualToString:@"error"]) {
        NSString *m = TBString(TBDictionary(item, @"error"), @"message");
        [self fail:[m length] ? m : @"Claude stream error"];
        return;
    }
    if ([type isEqualToString:@"message_start"]) {
        [started release];
        started = [TBDictionary(TBDictionary(item, @"message"), @"usage") retain];
    } else if ([type isEqualToString:@"content_block_start"]) {
        NSMutableDictionary *block = [NSMutableDictionary dictionaryWithDictionary:TBDictionary(item, @"content_block") ? TBDictionary(item, @"content_block") : [NSDictionary dictionary]];
        [blocks setObject:block forKey:index];
        if ([TBString(block, @"type") isEqualToString:@"tool_use"])
            [arguments setObject:[NSMutableString string] forKey:index];
    } else if ([type isEqualToString:@"content_block_delta"]) {
        NSDictionary *delta = TBDictionary(item, @"delta");
        NSMutableDictionary *block = [blocks objectForKey:index];
        NSString *dt = TBString(delta, @"type");
        if (!block) {
            [self fail:@"Claude delta without content block"];
            return;
        }
        if ([dt isEqualToString:@"text_delta"]) {
            NSString *text = TBString(delta, @"text");
            [block setObject:[TBString(block, @"text") stringByAppendingString:text] forKey:@"text"];
            [self say:text];
        } else if ([dt isEqualToString:@"thinking_delta"]) {
            NSString *text = TBString(delta, @"thinking");
            [block setObject:[TBString(block, @"thinking") stringByAppendingString:text] forKey:@"thinking"];
            [self think:text];
        } else if ([dt isEqualToString:@"signature_delta"]) {
            [block setObject:[TBString(block, @"signature") stringByAppendingString:TBString(delta, @"signature")] forKey:@"signature"];
        } else if ([dt isEqualToString:@"input_json_delta"]) {
            NSMutableString *args = [arguments objectForKey:index];
            if (!args) {
                args = [NSMutableString string];
                [arguments setObject:args forKey:index];
            }
            [args appendString:TBString(delta, @"partial_json")];
        }
    } else if ([type isEqualToString:@"message_delta"]) {
        NSString *reason = TBString(TBDictionary(item, @"delta"), @"stop_reason");
        if ([reason length]) {
            [stop release];
            stop = [reason copy];
        }
        if (TBDictionary(item, @"usage")) {
            [ended release];
            ended = [TBDictionary(item, @"usage") retain];
        }
    } else if ([type isEqualToString:@"content_block_stop"]) {
        NSMutableDictionary *block = [blocks objectForKey:index];
        NSString *args = [arguments objectForKey:index];
        if ([TBString(block, @"type") isEqualToString:@"tool_use"] && [args length]) {
            id parsed = TBJSONParseString(args, NULL);
            if ([parsed isKindOfClass:[NSDictionary class]])
                [block setObject:parsed forKey:@"input"];
            else
                [block setObject:[NSNumber numberWithBool:YES] forKey:@"cut"];
        }
        [complete addObject:index];
    }
}

- (void)geminiItem:(NSDictionary *)item
{
    NSArray *candidates = TBArray(item, @"candidates");
    unsigned c;
    if (TBDictionary(item, @"usageMetadata")) {
        [meta release];
        meta = [TBDictionary(item, @"usageMetadata") retain];
    }
    for (c = 0; c < [candidates count]; c++) {
        NSDictionary *candidate = [candidates objectAtIndex:c];
        NSArray *parts = TBArray(TBDictionary(candidate, @"content"), @"parts");
        unsigned p;
        if ([TBString(candidate, @"finishReason") isEqualToString:@"MAX_TOKENS"])
            round->truncated = YES;
        for (p = 0; p < [parts count]; p++) {
            NSDictionary *part = [parts objectAtIndex:p];
            NSString *signature = TBString(part, @"thoughtSignature");
            NSString *text;
            NSDictionary *call;
            if ([signature length]) {
                [looseSignature release];
                looseSignature = [signature copy];
            }
            if (TBTruthy(TBValue(part, @"thought"))) {
                if (thinking && [TBString(part, @"text") length])
                    [self think:TBString(part, @"text")];
                continue;
            }
            text = TBString(part, @"text");
            if ([text length])
                [self say:text];
            call = TBDictionary(part, @"functionCall");
            if (call && [TBString(call, @"name") length]) {
                NSString *marker = [TBString(call, @"id") length] ? TBString(call, @"id") : TBJSONString(call);
                NSMutableDictionary *slot = [seen objectForKey:marker];
                NSMutableDictionary *record;
                if (slot) {
                    if ([signature length] && ![TBString(slot, @"thought_signature") length])
                        [slot setObject:signature forKey:@"thought_signature"];
                    continue;
                }
                record = [NSMutableDictionary dictionaryWithObjectsAndKeys:[TBString(call, @"id") length] ? TBString(call, @"id") : TBString(call, @"name"), @"id",
                    TBString(call, @"name"), @"name", TBJSONString(TBDictionary(call, @"args") ? TBDictionary(call, @"args") : [NSDictionary dictionary]), @"arguments", nil];
                if ([signature length])
                    [record setObject:signature forKey:@"thought_signature"];
                [seen setObject:record forKey:marker];
                [gcalls addObject:record];
            }
        }
    }
}

- (BOOL)http:(TBHTTP *)http gotData:(NSData *)data
{
    NSArray *events = [sse feed:data];
    unsigned i;
    for (i = 0; i < [events count]; i++) {
        id item;
        [round->run check];
        item = TBJSONParseString([[events objectAtIndex:i] objectForKey:@"data"], NULL);
        if (![item isKindOfClass:[NSDictionary class]])
            continue;
        switch (kind) {
            case StreamOpenAI: [self openAIItem:item]; break;
            case StreamResponses: [self responsesItem:item]; break;
            case StreamClaude: [self claudeItem:item]; break;
            case StreamGemini: [self geminiItem:item]; break;
        }
        if (failure)
            return YES;
    }
    return [sse done];
}

@end

/* ---- one request to a service ---- */

static NSMutableSet *noReasoning = nil;            /* Mistral models that refused reasoning_effort */
static NSMutableDictionary *claudeLimits = nil;    /* the output limit a Claude model said it has */

/* Sends the request and streams the reply into the streamer. Returns the HTTP object: look at -status for a refusal. */
static TBHTTP *postStream(NSString *url, id payload, NSDictionary *headers, TBRound *round, TBStreamer *streamer)
{
    TBHTTP *http = [TBHTTP request:@"POST" url:url];
    NSEnumerator *names = [headers keyEnumerator];
    NSString *name;
    int rc;
    while ((name = [names nextObject]))
        [http setHeader:name value:[headers objectForKey:name]];
    [http setBody:TBJSONData(payload)];
    [http setIdleTimeout:180];
    [http setDelegate:streamer];
    [round->run attach:http];
    @try {
        rc = [http perform];
    } @finally {
        [round->run detach:http];
    }
    [round->run check];
    if (rc != TBNET_OK)
        TBFail(@"%@", [http error] ? [http error] : @"The connection failed.");
    if (streamer && streamer->failure)
        TBFail(@"%@", streamer->failure);
    return http;
}

static NSString *refusal(TBHTTP *http)
{
    return [TBProviders apiErrorText:[http text] code:[http status]];
}

static BOOL showThinking(TBRound *round)
{
    return [TBSettings flag:@"claude_thinking"] && !round->probe;
}

static NSDictionary *standardHeaders(NSString *key)
{
    NSMutableDictionary *h = [NSMutableDictionary dictionaryWithObjectsAndKeys:@"application/json", @"Content-Type", @"TigerBuild/2.0", @"User-Agent", nil];
    if ([key length])
        [h setObject:[@"Bearer " stringByAppendingString:key] forKey:@"Authorization"];
    return h;
}

@implementation TBProviders (Streaming)

+ (void)streamOpenAICompatible:(NSString *)url key:(NSString *)key model:(NSString *)model system:(NSString *)system log:(NSArray *)log
                         tools:(NSArray *)tools round:(TBRound *)round
{
    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithObjectsAndKeys:model, @"model", [NSNumber numberWithBool:YES], @"stream",
        [self openAIMessagesWithSystem:system log:log], @"messages", nil];
    BOOL thinking = showThinking(round);
    BOOL askMistral;
    NSString *mistralURL = baseOverride(@"mistral", MISTRAL_URL);
    NSString *openaiURL = baseOverride(@"chatgpt", OPENAI_URL);
    TBStreamer *streamer = nil;
    TBHTTP *http;
    int attempt;
    if ([tools count]) {
        NSString *effort = nil;
        [payload setObject:openAITools(tools) forKey:@"tools"];
        [payload setObject:@"auto" forKey:@"tool_choice"];
        if ([model isEqualToString:@"gpt-5.6-luna"] || [model isEqualToString:@"gpt-5.6-sol"] || [model isEqualToString:@"gpt-5.6-terra"]
            || [model isEqualToString:@"gpt-6-luna"] || [model isEqualToString:@"gpt-6-sol"])
            effort = @"none";
        if (effort && [url isEqualToString:openaiURL])
            [payload setObject:effort forKey:@"reasoning_effort"];
    }
    if ([url isEqualToString:openaiURL] || [url isEqualToString:mistralURL] || ([url hasSuffix:@"/chat/completions"] && ![url isEqualToString:baseOverride(@"muse", MUSE_URL)]))
        [payload setObject:[NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES] forKey:@"include_usage"] forKey:@"stream_options"];
    if (!noReasoning)
        noReasoning = [[NSMutableSet alloc] init];
    askMistral = thinking && [url isEqualToString:mistralURL] && ![noReasoning containsObject:model];
    if (askMistral)
        [payload setObject:@"high" forKey:@"reasoning_effort"];
    for (attempt = 0; attempt < 2; attempt++) {
        [streamer release];
        streamer = [[TBStreamer alloc] initFor:StreamOpenAI round:round thinking:thinking];
        http = postStream(url, payload, standardHeaders(key), round, streamer);
        if ([http status] < 400)
            break;
        {
            NSString *text = refusal(http);
            if (attempt == 0 && [text rangeOfString:@"stream_options"].location != NSNotFound && [payload objectForKey:@"stream_options"]) {
                [payload removeObjectForKey:@"stream_options"];
                continue;
            }
            if (attempt == 0 && askMistral && [text rangeOfString:@"reasoning_effort"].location != NSNotFound) {
                [payload removeObjectForKey:@"reasoning_effort"];
                [noReasoning addObject:model];
                continue;
            }
            [streamer release];
            TBFail(@"%@", text);
        }
    }
    [streamer autorelease];
    {
        NSMutableArray *calls = [NSMutableArray array];
        NSArray *indexes = [[streamer->slots allKeys] sortedArrayUsingSelector:@selector(compare:)];
        NSArray *tail;
        NSString *fallback;
        unsigned i;
        for (i = 0; i < [indexes count]; i++) {
            NSDictionary *slot = [streamer->slots objectForKey:[indexes objectAtIndex:i]];
            if ([TBString(slot, @"name") length])
                [calls addObject:[NSDictionary dictionaryWithObjectsAndKeys:TBString(slot, @"id"), @"id", TBString(slot, @"name"), @"name",
                    [NSString stringWithString:[slot objectForKey:@"arguments"]], @"arguments", nil]];
        }
        tail = [streamer->answer flush];
        if (thinking) {
            NSArray *thoughts = [streamer->answer takeThoughts];
            for (i = 0; i < [thoughts count]; i++)
                [streamer think:[thoughts objectAtIndex:i]];
        }
        for (i = 0; i < [tail count]; i++)
            [streamer say:[tail objectAtIndex:i]];
        fallback = [streamer->answer finish];
        if ([calls count] == 0) {
            NSMutableArray *markup = [NSMutableArray arrayWithArray:[streamer->answer toolMarkup]];
            [markup addObjectsFromArray:[streamer->answer reasoningPieces]];
            [calls addObjectsFromArray:[self qwenToolCalls:[markup componentsJoinedByString:@"\n"]]];
        }
        if ([fallback rangeOfString:@"<tool_call>"].location != NSNotFound)
            fallback = @"";
        if ([fallback length] && [calls count] == 0)
            [streamer say:fallback];
        [round->calls setArray:calls];
    }
}

+ (void)streamResponsesKey:(NSString *)key model:(NSString *)model system:(NSString *)system log:(NSArray *)log tools:(NSArray *)tools round:(TBRound *)round
{
    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithObjectsAndKeys:model, @"model", [NSNumber numberWithBool:YES], @"stream",
        [NSNumber numberWithBool:NO], @"store", system, @"instructions", [self openAIResponsesInput:log], @"input", nil];
    BOOL thinking = showThinking(round);
    TBStreamer *streamer;
    TBHTTP *http;
    NSString *url = baseOverride(@"chatgpt-responses", OPENAI_RESPONSES_URL);
    if ([tools count]) {
        NSMutableArray *flat = [NSMutableArray array];
        unsigned i;
        for (i = 0; i < [tools count]; i++) {
            NSDictionary *tool = [tools objectAtIndex:i];
            [flat addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"function", @"type", TBString(tool, @"name"), @"name", toolDescription(tool), @"description",
                toolParameters(tool), @"parameters", nil]];
        }
        [payload setObject:flat forKey:@"tools"];
        [payload setObject:@"auto" forKey:@"tool_choice"];
    }
    if (thinking)
        [payload setObject:[NSDictionary dictionaryWithObject:@"auto" forKey:@"summary"] forKey:@"reasoning"];
    streamer = [[[TBStreamer alloc] initFor:StreamResponses round:round thinking:thinking] autorelease];
    http = postStream(url, payload, standardHeaders(key), round, streamer);
    if ([http status] >= 400) {
        if (!thinking)
            TBFail(@"%@", refusal(http));
        /* Summaries need a reasoning model and, for some accounts, a verified organization: answer without them. */
        [payload removeObjectForKey:@"reasoning"];
        thinking = NO;
        streamer = [[[TBStreamer alloc] initFor:StreamResponses round:round thinking:NO] autorelease];
        http = postStream(url, payload, standardHeaders(key), round, streamer);
        if ([http status] >= 400)
            TBFail(@"%@", refusal(http));
    }
    {
        NSDictionary *done = streamer->completed;
        NSArray *output = TBArray(done, @"output");
        unsigned i;
        noteOpenAIUsage(round, TBValue(done, @"usage"));
        for (i = 0; i < [output count]; i++) {
            NSDictionary *item = [output objectAtIndex:i];
            id arguments;
            NSString *callId;
            if (![item isKindOfClass:[NSDictionary class]] || ![TBString(item, @"type") isEqualToString:@"function_call"])
                continue;
            arguments = TBValue(item, @"arguments");
            callId = [TBString(item, @"call_id") length] ? TBString(item, @"call_id") : ([TBString(item, @"id") length] ? TBString(item, @"id") : TBString(item, @"name"));
            [round->calls addObject:[NSDictionary dictionaryWithObjectsAndKeys:callId, @"id", TBString(item, @"name"), @"name",
                [arguments isKindOfClass:[NSString class]] && [arguments length] ? arguments : (arguments ? TBJSONString(arguments) : @"{}"), @"arguments", nil]];
        }
    }
}

/* ---- Claude ---- */

static NSDictionary *cacheMark(NSString *system, NSArray *messages)
{
    unsigned long total = [system length];
    unsigned i;
    for (i = 0; i < [messages count]; i++) {
        id content = TBValue([messages objectAtIndex:i], @"content");
        if ([content isKindOfClass:[NSString class]]) {
            total += [content length];
        } else if ([content isKindOfClass:[NSArray class]]) {
            unsigned b;
            for (b = 0; b < [content count]; b++) {
                id block = [content objectAtIndex:b];
                if ([block isKindOfClass:[NSDictionary class]])
                    total += [TBString(block, @"text") length] + [[TBValue(block, @"content") description] length] + ([TBString(block, @"type") isEqualToString:@"image"] ? 3000 : 0);
            }
        }
    }
    if (total > 60000)
        return [NSDictionary dictionaryWithObjectsAndKeys:@"ephemeral", @"type", @"1h", @"ttl", nil];
    return [NSDictionary dictionaryWithObject:@"ephemeral" forKey:@"type"];
}

/* Marks where Claude may reuse what it has already read: the system prompt and everything up to the last message. */
static id claudeCacheMarks(NSString *system, NSMutableArray *messages)
{
    NSDictionary *mark = cacheMark(system, messages);
    id marked = system;
    if ([system length])
        marked = [NSArray arrayWithObject:[NSDictionary dictionaryWithObjectsAndKeys:@"text", @"type", system, @"text", mark, @"cache_control", nil]];
    if ([messages count]) {
        NSMutableDictionary *last = [messages lastObject];
        id content = TBValue(last, @"content");
        NSMutableArray *blocks;
        NSMutableDictionary *block;
        if ([content isKindOfClass:[NSString class]] && [TBTrim(content) length])
            content = [NSArray arrayWithObject:[NSDictionary dictionaryWithObjectsAndKeys:@"text", @"type", content, @"text", nil]];
        if ([content isKindOfClass:[NSArray class]] && [content count] && [[content lastObject] isKindOfClass:[NSDictionary class]]) {
            NSString *type;
            blocks = [NSMutableArray arrayWithArray:content];
            block = [NSMutableDictionary dictionaryWithDictionary:[blocks lastObject]];
            type = TBString(block, @"type");
            if (([type isEqualToString:@"text"] || [type isEqualToString:@"image"] || [type isEqualToString:@"tool_result"] || [type isEqualToString:@"tool_use"])
                && !([type isEqualToString:@"text"] && [TBTrim(TBString(block, @"text")) length] == 0)) {
                [block setObject:mark forKey:@"cache_control"];
                [blocks replaceObjectAtIndex:[blocks count] - 1 withObject:block];
            }
            [last setObject:blocks forKey:@"content"];
        } else if (content) {
            [last setObject:content forKey:@"content"];
        }
    }
    return marked;
}

static void withoutCacheMarks(NSMutableDictionary *payload)
{
    id system = TBValue(payload, @"system");
    NSArray *messages = TBArray(payload, @"messages");
    unsigned i;
    if ([system isKindOfClass:[NSArray class]] && [system count])
        [payload setObject:TBString([system objectAtIndex:0], @"text") forKey:@"system"];
    for (i = 0; i < [messages count]; i++) {
        NSMutableDictionary *message = [messages objectAtIndex:i];
        id content = TBValue(message, @"content");
        if ([content isKindOfClass:[NSArray class]]) {
            NSMutableArray *clean = [NSMutableArray array];
            unsigned b;
            for (b = 0; b < [content count]; b++) {
                id block = [content objectAtIndex:b];
                if ([block isKindOfClass:[NSDictionary class]] && TBValue(block, @"cache_control")) {
                    NSMutableDictionary *copy = [NSMutableDictionary dictionaryWithDictionary:block];
                    [copy removeObjectForKey:@"cache_control"];
                    block = copy;
                }
                [clean addObject:block];
            }
            [message setObject:clean forKey:@"content"];
        }
    }
}

static NSString *claudeThinkingType(NSString *model)
{
    static const char *adaptive[] = {"opus-4-6", "opus-4-7", "opus-4-8", "opus-5", "sonnet-4-6", "sonnet-5", "fable-5", NULL};
    int i;
    for (i = 0; adaptive[i]; i++) {
        if ([model rangeOfString:[NSString stringWithUTF8String:adaptive[i]]].location != NSNotFound)
            return @"adaptive";
    }
    return @"enabled";
}

/* "max_tokens: 64000 > 32000" in a refusal: the limit the model has. */
static int claudeLimitIn(NSString *message)
{
    NSRange at = [message rangeOfString:@"max_tokens:"];
    NSScanner *scanner;
    int first = 0, limit = 0;
    if (at.location == NSNotFound)
        return 0;
    scanner = [NSScanner scannerWithString:[message substringFromIndex:at.location + at.length]];
    if ([scanner scanInt:&first] && [scanner scanString:@">" intoString:NULL] && [scanner scanInt:&limit])
        return limit;
    return 0;
}

+ (void)streamClaudeKey:(NSString *)key model:(NSString *)model system:(NSString *)system log:(NSArray *)log tools:(NSArray *)tools round:(TBRound *)round
{
    NSMutableArray *messages = [NSMutableArray arrayWithArray:[self anthropicMessagesFromLog:log]];
    NSNumber *learned;
    NSMutableDictionary *payload;
    NSMutableDictionary *headers;
    NSString *workspace = [TBSettings valueForName:@"anthropic_workspace_id"];
    TBStreamer *streamer;
    TBHTTP *http;
    NSString *url = baseOverride(@"claude", ANTHROPIC_URL);
    int attempt;
    if (!claudeLimits)
        claudeLimits = [[NSMutableDictionary alloc] init];
    learned = [claudeLimits objectForKey:model];
    payload = [NSMutableDictionary dictionaryWithObjectsAndKeys:model, @"model", [NSNumber numberWithInt:learned ? [learned intValue] : 64000], @"max_tokens",
        [NSNumber numberWithBool:YES], @"stream", claudeCacheMarks(system, messages), @"system", messages, @"messages", nil];
    if ([tools count])
        [payload setObject:anthropicTools(tools) forKey:@"tools"];
    if (showThinking(round)) {
        /* Adaptive thinking text is omitted unless display is "summarized"; older models take a bounded budget. */
        if ([claudeThinkingType(model) isEqualToString:@"adaptive"])
            [payload setObject:[NSDictionary dictionaryWithObjectsAndKeys:@"adaptive", @"type", @"summarized", @"display", nil] forKey:@"thinking"];
        else
            [payload setObject:[NSDictionary dictionaryWithObjectsAndKeys:@"enabled", @"type", [NSNumber numberWithInt:2048], @"budget_tokens", nil] forKey:@"thinking"];
    }
    headers = [NSMutableDictionary dictionaryWithObjectsAndKeys:@"application/json", @"Content-Type", key, @"x-api-key", @"2023-06-01", @"anthropic-version",
        @"TigerBuild/2.0", @"User-Agent", nil];
    if ([workspace length])
        [headers setObject:workspace forKey:@"anthropic-workspace-id"];
    for (attempt = 0; attempt < 2; attempt++) {
        streamer = [[[TBStreamer alloc] initFor:StreamClaude round:round thinking:YES] autorelease];
        http = postStream(url, payload, headers, round, streamer);
        if ([http status] < 400)
            break;
        {
            NSString *text = refusal(http);
            int limit;
            if (attempt == 0 && [text rangeOfString:@"cache_control"].location != NSNotFound) {
                withoutCacheMarks(payload);
                continue;
            }
            limit = claudeLimitIn(text);
            if (attempt == 0 && limit && limit < [[payload objectForKey:@"max_tokens"] intValue]) {
                [claudeLimits setObject:[NSNumber numberWithInt:limit] forKey:model];
                [payload setObject:[NSNumber numberWithInt:limit] forKey:@"max_tokens"];
                continue;
            }
            TBFail(@"%@", text);
        }
    }
    [round addUsageInput:TBInteger(streamer->started, @"input_tokens") cached:TBInteger(streamer->started, @"cache_read_input_tokens")
                 written:TBInteger(streamer->started, @"cache_creation_input_tokens")
                  output:TBInteger(streamer->ended, @"output_tokens") ? TBInteger(streamer->ended, @"output_tokens") : TBInteger(streamer->started, @"output_tokens")];
    if ([streamer->stop isEqualToString:@"max_tokens"] || [streamer->stop isEqualToString:@"model_context_window_exceeded"])
        round->truncated = YES;
    {
        NSArray *indexes = [[streamer->blocks allKeys] sortedArrayUsingSelector:@selector(compare:)];
        NSMutableArray *ordered = [NSMutableArray array];
        unsigned i;
        if ([streamer->stop isEqualToString:@"max_tokens"]) {
            /* A tool call cut off mid-arguments must not run or be replayed. */
            [round->calls removeAllObjects];
            [round->claudeBlocks release];
            round->claudeBlocks = [[NSArray array] retain];
            return;
        }
        for (i = 0; i < [indexes count]; i++) {
            NSNumber *index = [indexes objectAtIndex:i];
            NSMutableDictionary *block = [streamer->blocks objectForKey:index];
            if (![streamer->complete containsObject:index])
                TBFail(@"Claude returned an incomplete content block; refusing to replay it");
            if ([TBString(block, @"type") isEqualToString:@"thinking"] && [TBString(block, @"signature") length] == 0)
                TBFail(@"Claude thinking block missing its signature; refusing to replay it");
            [ordered addObject:block];
            if ([TBString(block, @"type") isEqualToString:@"tool_use"])
                [round->calls addObject:[NSDictionary dictionaryWithObjectsAndKeys:TBString(block, @"id"), @"id", TBString(block, @"name"), @"name", @"tool_use", @"type",
                    TBJSONString(TBDictionary(block, @"input") ? TBDictionary(block, @"input") : [NSDictionary dictionary]), @"arguments", nil]];
        }
        [round->claudeBlocks release];
        round->claudeBlocks = [ordered retain];
    }
}

+ (void)streamGeminiKey:(NSString *)key model:(NSString *)model system:(NSString *)system log:(NSArray *)log tools:(NSArray *)tools round:(TBRound *)round
{
    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithObjectsAndKeys:
        [NSDictionary dictionaryWithObject:[NSArray arrayWithObject:[NSDictionary dictionaryWithObject:system forKey:@"text"]] forKey:@"parts"], @"systemInstruction",
        [self geminiContentsFromLog:log], @"contents", nil];
    NSArray *declared = geminiTools(tools);
    BOOL thinking = showThinking(round);
    NSDictionary *headers = [NSDictionary dictionaryWithObjectsAndKeys:@"application/json", @"Content-Type", key, @"x-goog-api-key", @"TigerBuild/2.0", @"User-Agent", nil];
    NSString *url = [NSString stringWithFormat:baseOverride(@"gemini", GEMINI_URL), model];
    TBStreamer *streamer;
    TBHTTP *http;
    if (declared)
        [payload setObject:declared forKey:@"tools"];
    if (thinking)
        [payload setObject:[NSDictionary dictionaryWithObject:[NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES] forKey:@"includeThoughts"] forKey:@"thinkingConfig"]
                    forKey:@"generationConfig"];
    streamer = [[[TBStreamer alloc] initFor:StreamGemini round:round thinking:thinking] autorelease];
    http = postStream(url, payload, headers, round, streamer);
    if ([http status] >= 400) {
        if (!thinking)
            TBFail(@"%@", refusal(http));
        /* Models without thinking reject thinkingConfig; answer without it. */
        [payload removeObjectForKey:@"generationConfig"];
        thinking = NO;
        streamer = [[[TBStreamer alloc] initFor:StreamGemini round:round thinking:NO] autorelease];
        http = postStream(url, payload, headers, round, streamer);
        if ([http status] >= 400)
            TBFail(@"%@", refusal(http));
    }
    {
        long long cached = TBInteger(streamer->meta, @"cachedContentTokenCount");
        unsigned i;
        [round addUsageInput:TBInteger(streamer->meta, @"promptTokenCount") - cached cached:cached written:0
                      output:TBInteger(streamer->meta, @"candidatesTokenCount") + TBInteger(streamer->meta, @"thoughtsTokenCount")];
        if ([streamer->looseSignature length]) {
            for (i = 0; i < [streamer->gcalls count]; i++) {
                NSMutableDictionary *record = [streamer->gcalls objectAtIndex:i];
                if (![TBString(record, @"thought_signature") length]) {
                    [record setObject:streamer->looseSignature forKey:@"thought_signature"];
                    break;
                }
            }
        }
        [round->calls setArray:streamer->gcalls];
    }
}

static BOOL reasoningModel(NSString *model)
{
    NSString *m = [(model ? model : @"") lowercaseString];
    if ([m rangeOfString:@"chat"].location != NSNotFound || [m rangeOfString:@"audio"].location != NSNotFound || [m rangeOfString:@"realtime"].location != NSNotFound
        || [m rangeOfString:@"image"].location != NSNotFound)
        return NO;
    return [m hasPrefix:@"o1"] || [m hasPrefix:@"o3"] || [m hasPrefix:@"o4"] || [m hasPrefix:@"gpt-5"] || [m hasPrefix:@"gpt-6"];
}

static BOOL responsesOnly(NSString *model)
{
    static const char *list[] = {"gpt-6-astra", "gpt-5.5-pro", "gpt-5.4-pro", "gpt-5.2-pro", "gpt-5-pro", "o1-pro", NULL};
    int i;
    for (i = 0; list[i]; i++) {
        if ([model isEqualToString:[NSString stringWithUTF8String:list[i]]])
            return YES;
    }
    return NO;
}

static NSString *keyLabel(NSString *provider)
{
    if ([provider isEqualToString:@"chatgpt"])
        return @"OpenAI";
    if ([provider isEqualToString:@"claude"])
        return @"Anthropic";
    if ([provider isEqualToString:@"mistral"])
        return @"Mistral";
    if ([provider isEqualToString:@"muse"])
        return @"Muse";
    if ([provider isEqualToString:@"gemini"])
        return @"Google (Gemini)";
    return @"xAI (Grok)";
}

+ (void)streamRound:(NSString *)provider system:(NSString *)system log:(NSArray *)log tools:(NSArray *)tools round:(TBRound *)round model:(NSString *)model
{
    NSString *key;
    model = [self resolveModel:model provider:provider];
    [round->calls removeAllObjects];
    if ([provider isEqualToString:@"local"]) {
        NSString *base = [self localBase];
        if ([model length] == 0)
            TBFail(@"Choose a local model in the version menu.");
        if ([base length] == 0)
            TBFail(@"No local model server is set up. Add its address in Tiger Build Preferences.");
        [self streamOpenAICompatible:[base stringByAppendingString:@"/chat/completions"] key:[TBSettings keyForProvider:@"local"] model:model system:system
                                 log:[self ensureUserFirst:log] tools:tools round:round];
        return;
    }
    key = [TBSettings keyForProvider:provider];
    if ([key length] == 0)
        TBFail(@"Add your %@ API key in Tiger Build Preferences.", keyLabel(provider));
    if ([provider isEqualToString:@"chatgpt"] && responsesOnly(model)) {
        [self streamResponsesKey:key model:model system:system log:log tools:tools round:round];
        return;
    }
    if ([provider isEqualToString:@"chatgpt"] && reasoningModel(model) && showThinking(round)) {
        /* Chat completions never return reasoning, so a reasoning model is asked through the Responses API, which returns
           summaries. If that refuses before anything was said, fall back to chat completions. */
        @try {
            [self streamResponsesKey:key model:model system:system log:log tools:tools round:round];
            return;
        } @catch (NSException *exception) {
            if (![[exception name] isEqualToString:TBErrorException] || round->spoke)
                @throw;
            [round->calls removeAllObjects];
        }
    }
    if ([provider isEqualToString:@"chatgpt"]) {
        [self streamOpenAICompatible:baseOverride(@"chatgpt", OPENAI_URL) key:key model:model system:system log:log tools:tools round:round];
    } else if ([provider isEqualToString:@"mistral"]) {
        [self streamOpenAICompatible:baseOverride(@"mistral", MISTRAL_URL) key:key model:model system:system log:log tools:tools round:round];
    } else if ([provider isEqualToString:@"muse"]) {
        [self streamOpenAICompatible:baseOverride(@"muse", MUSE_URL) key:key model:model system:system log:log tools:tools round:round];
    } else if ([provider isEqualToString:@"claude"]) {
        [self streamClaudeKey:key model:model system:system log:log tools:tools round:round];
    } else if ([provider isEqualToString:@"gemini"]) {
        [self streamGeminiKey:key model:model system:system log:log tools:tools round:round];
    } else {
        TBFail(@"Unknown model.");
    }
}

@end
