#import "TBSession.h"
#import "TBExtras.h"
#import "TBMedia.h"
#import "TBJSON.h"
#import "TBHTTP.h"

/* The Grok loop and the model-consult tool: the parts of TBSession that are about particular services. */

static NSString *const kLimitNote = @"\n\n[The reply stopped here because the model reached its output limit. Say \"continue\" and it will pick up where it left off.]";
static NSString *const kConsultTool = @"consult_model";

@interface TBSession (GrokNeeds)
- (void)emit:(NSString *)kind text:(NSString *)text;
- (NSDictionary *)executeCall:(NSDictionary *)call provider:(NSString *)provider;
- (NSString *)usageEventForProvider:(NSString *)provider model:(NSString *)model usage:(NSDictionary *)usage;
- (NSString *)stoppedEarlyOutput:(NSString *)output reason:(NSString *)reason;
- (NSDictionary *)screenshotNoteForProvider:(NSString *)provider model:(NSString *)model images:(NSArray *)images;
- (NSArray *)takeGuidanceNotes;
- (int)maxSteps;
- (NSSet *)skipKeys;
- (NSString *)mediaRoot;
@end

/* xAI's Responses stream: text and reasoning as frames, then the finished response. */
@interface TBGrokStream : NSObject {
@public
    TBSession *session;
    TBSSE *sse;
    NSDictionary *completed;
    BOOL truncated;
    BOOL sawText;
    NSString *failure;
    BOOL thinking;
}
@end

@implementation TBGrokStream

- (id)initForSession:(TBSession *)s
{
    self = [super init];
    session = s;
    sse = [[TBSSE alloc] init];
    thinking = [TBSettings flag:@"claude_thinking"];
    return self;
}

- (void)dealloc
{
    [sse release];
    [completed release];
    [failure release];
    [super dealloc];
}

- (BOOL)http:(TBHTTP *)http gotData:(NSData *)data
{
    NSArray *events = [sse feed:data];
    unsigned i;
    for (i = 0; i < [events count]; i++) {
        id event;
        NSString *type;
        [session->run check];
        event = TBJSONParseString([[events objectAtIndex:i] objectForKey:@"data"], NULL);
        if (![event isKindOfClass:[NSDictionary class]])
            continue;
        type = TBString(event, @"type");
        if ([type isEqualToString:@"response.reasoning_summary_text.delta"] && thinking) {
            if ([TBString(event, @"delta") length])
                [session emit:@"h" text:TBString(event, @"delta")];
            continue;
        }
        if ([type isEqualToString:@"response.reasoning_summary_part.done"] && thinking) {
            [session emit:@"h" text:@"\n\n"];
            continue;
        }
        if ([type isEqualToString:@"response.output_text.delta"] && [TBString(event, @"delta") length]) {
            sawText = YES;
            [session emit:@"t" text:TBString(event, @"delta")];
        } else if (([type isEqualToString:@"response.completed"] || [type isEqualToString:@"response.incomplete"]) && TBDictionary(event, @"response")) {
            [completed release];
            completed = [TBDictionary(event, @"response") retain];
            truncated = [type isEqualToString:@"response.incomplete"];
        } else if ([type isEqualToString:@"error"] || [type isEqualToString:@"response.failed"] || [type isEqualToString:@"response.error"]) {
            id err = TBValue(event, @"error");
            NSString *m;
            if (!err)
                err = TBValue(TBDictionary(event, @"response"), @"error");
            m = [err isKindOfClass:[NSDictionary class]] ? TBString(err, @"message") : ([err isKindOfClass:[NSString class]] ? err : @"");
            failure = [([m length] ? m : @"The model failed.") copy];
            return YES;
        }
    }
    return [sse done];
}

@end

static NSString *extractText(NSDictionary *data)
{
    NSMutableArray *parts = [NSMutableArray array];
    NSArray *output = TBArray(data, @"output");
    NSString *text;
    unsigned i;
    id err;
    if ([TBString(data, @"output_text") length] && [TBTrim(TBString(data, @"output_text")) length])
        return TBTrim(TBString(data, @"output_text"));
    for (i = 0; i < [output count]; i++) {
        NSDictionary *item = [output objectAtIndex:i];
        id content;
        if (![item isKindOfClass:[NSDictionary class]])
            continue;
        if ([TBString(item, @"type") length] && ![TBString(item, @"type") isEqualToString:@"message"])
            continue;
        content = TBValue(item, @"content");
        if ([content isKindOfClass:[NSString class]]) {
            [parts addObject:content];
        } else if ([content isKindOfClass:[NSArray class]]) {
            unsigned p;
            for (p = 0; p < [content count]; p++) {
                id piece = [content objectAtIndex:p];
                if ([piece isKindOfClass:[NSDictionary class]] && [TBString(piece, @"text") length])
                    [parts addObject:TBString(piece, @"text")];
                else if ([piece isKindOfClass:[NSString class]])
                    [parts addObject:piece];
            }
        }
    }
    text = TBTrim([parts componentsJoinedByString:@"\n"]);
    if ([text length])
        return text;
    err = TBValue(data, @"error");
    if ([err isKindOfClass:[NSDictionary class]] && [TBString(err, @"message") length])
        TBFail(@"%@", TBString(err, @"message"));
    if ([err isKindOfClass:[NSString class]] && [err length])
        TBFail(@"%@", err);
    return @"";
}

static NSString *eventErrorMessage(NSDictionary *event)
{
    id err = TBValue(event, @"error");
    if (!err)
        err = TBValue(TBDictionary(event, @"response"), @"error");
    if ([err isKindOfClass:[NSDictionary class]] && [TBString(err, @"message") length])
        return TBString(err, @"message");
    if ([err isKindOfClass:[NSString class]] && [err length])
        return err;
    return @"The model failed.";
}

@implementation TBSession (Grok)

/* One streamed request to xAI. Returns the stream state; raises for a refusal or a lost connection. */
- (TBGrokStream *)postGrok:(NSDictionary *)payload
{
    NSMutableDictionary *body = [NSMutableDictionary dictionaryWithDictionary:payload];
    TBGrokStream *stream = [[[TBGrokStream alloc] initForSession:self] autorelease];
    NSString *key = [TBSettings keyForProvider:@"grok"];
    NSString *override = [[NSUserDefaults standardUserDefaults] stringForKey:@"TBBaseURL.grok"];
    TBHTTP *http = [TBHTTP request:@"POST" url:[override length] ? override : @"https://api.x.ai/v1/responses"];
    int rc;
    if ([key length] == 0)
        TBFail(@"Add your xAI (Grok) API key in Tiger Build Preferences.");
    [body setObject:[NSNumber numberWithBool:YES] forKey:@"stream"];
    [http setHeader:@"Content-Type" value:@"application/json"];
    [http setHeader:@"Authorization" value:[@"Bearer " stringByAppendingString:key]];
    [http setHeader:@"User-Agent" value:@"TigerBuild/2.0"];
    [http setBody:TBJSONData(body)];
    [http setIdleTimeout:180];
    [http setDelegate:stream];
    [run attach:http];
    @try {
        rc = [http perform];
    } @finally {
        [run detach:http];
    }
    [run check];
    if (rc != 0)
        TBFail(@"%@", [http error] ? [http error] : @"The connection failed.");
    if ([http status] >= 400)
        TBFail(@"%@", [TBProviders apiErrorText:[http text] code:[http status]]);
    if (stream->failure)
        TBFail(@"%@", stream->failure);
    return stream;
}

- (void)runGrokMessages:(NSArray *)messages system:(NSString *)system tools:(NSArray *)toolList model:(NSString *)chosen bare:(BOOL)bare
{
    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithObjectsAndKeys:chosen, @"model", [NSNumber numberWithBool:YES], @"store",
        nil];
    NSMutableArray *input = [NSMutableArray arrayWithObject:[NSDictionary dictionaryWithObjectsAndKeys:@"system", @"role", system, @"content", nil]];
    NSMutableArray *tools = [NSMutableArray arrayWithArray:toolList];
    int roundIndex = 0;
    BOOL forced = NO;
    NSString *lastOutput = @"";
    BOOL lastFailed = NO;
    [input addObjectsFromArray:[TBProviders openAIResponsesInput:messages]];
    [payload setObject:input forKey:@"input"];
    if (!bare && [TBSettings flag:@"grok_native_search"] && ![[self skipKeys] containsObject:@"search"])
        [tools addObject:[NSDictionary dictionaryWithObject:@"web_search" forKey:@"type"]];
    if ([tools count]) {
        [payload setObject:tools forKey:@"tools"];
        [payload setObject:@"auto" forKey:@"tool_choice"];
    }
    for (;;) {
        TBGrokStream *stream = nil;
        NSDictionary *completed;
        NSArray *calls;
        BOOL sawText;
        [run check];
        if (roundIndex)
            [self emit:@"s" text:@"Working on the next step..."];
        @try {
            stream = [self postGrok:payload];
        } @catch (NSException *exception) {
            [run check];
            if ([lastOutput length]) {
                [self emit:@"t" text:[self stoppedEarlyOutput:lastFailed ? lastOutput : @"" reason:[exception reason]]];
                return;
            }
            @throw;
        }
        [run check];
        sawText = stream->sawText;
        completed = stream->completed;
        if (completed) {
            TBRound *counter = [[[TBRound alloc] init] autorelease];
            NSDictionary *usage = TBDictionary(completed, @"usage");
            long long cached = TBInteger(TBDictionary(usage, @"input_tokens_details") ? TBDictionary(usage, @"input_tokens_details") : TBDictionary(usage, @"prompt_tokens_details"), @"cached_tokens");
            long long prompt = TBInteger(usage, @"input_tokens") ? TBInteger(usage, @"input_tokens") : TBInteger(usage, @"prompt_tokens");
            long long output = TBInteger(usage, @"output_tokens") ? TBInteger(usage, @"output_tokens") : TBInteger(usage, @"completion_tokens");
            NSString *text;
            [counter addUsageInput:prompt - cached cached:cached written:0 output:output];
            text = [self usageEventForProvider:@"grok" model:chosen usage:counter->usage];
            if (text)
                [self emit:@"u" text:text];
        }
        if (!completed) {
            if (sawText)
                return;
            if (lastFailed) {
                [self emit:@"t" text:[self stoppedEarlyOutput:lastOutput reason:nil]];
                return;
            }
            TBFail(@"The model stream ended early.");
        }
        if (TBValue(completed, @"error"))
            TBFail(@"%@", eventErrorMessage(completed));
        if (stream->truncated) {
            [self emit:@"t" text:kLimitNote];
            return;
        }
        {
            NSMutableArray *found = [NSMutableArray array];
            NSArray *output = TBArray(completed, @"output");
            unsigned i;
            for (i = 0; i < [output count] && [tools count]; i++) {
                if ([[output objectAtIndex:i] isKindOfClass:[NSDictionary class]] && [TBString([output objectAtIndex:i], @"type") isEqualToString:@"function_call"])
                    [found addObject:[output objectAtIndex:i]];
            }
            calls = found;
        }
        if ([calls count] && [TBString(completed, @"id") length] && !forced && roundIndex < [self maxSteps]) {
            NSMutableArray *outputs = [NSMutableArray array];
            NSMutableArray *extra = [NSMutableArray array];
            NSArray *notes;
            unsigned c;
            for (c = 0; c < [calls count]; c++) {
                NSDictionary *call = [calls objectAtIndex:c];
                NSDictionary *result = [self executeCall:call provider:@"grok"];
                NSString *output = TBString(result, @"output");
                NSDictionary *shot;
                lastOutput = output;
                lastFailed = TBTruth(result, @"failed");
                if (roundIndex >= [self maxSteps] - 3)
                    output = [output stringByAppendingString:@"\n\nFinish the task with the calls you have left. Do not ask the user to type continue."];
                [outputs addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"function_call_output", @"type",
                    [TBString(call, @"call_id") length] ? TBString(call, @"call_id") : TBString(call, @"id"), @"call_id", output, @"output", nil]];
                shot = [self screenshotNoteForProvider:@"grok" model:chosen images:TBArray(result, @"images")];
                if (shot)
                    [extra addObjectsFromArray:[TBProviders openAIResponsesInput:[NSArray arrayWithObject:shot]]];
            }
            notes = [self takeGuidanceNotes];
            for (c = 0; c < [notes count]; c++)
                [extra addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"user", @"role", [@"Note from the person while you work: " stringByAppendingString:[notes objectAtIndex:c]], @"content", nil]];
            [outputs addObjectsFromArray:extra];
            payload = [NSMutableDictionary dictionaryWithObjectsAndKeys:chosen, @"model", [NSNumber numberWithBool:YES], @"store", TBString(completed, @"id"), @"previous_response_id",
                tools, @"tools", @"auto", @"tool_choice", outputs, @"input", nil];
            roundIndex++;
            continue;
        }
        if ([calls count] && [TBString(completed, @"id") length] && !forced) {
            NSMutableArray *outputs = [NSMutableArray array];
            unsigned c;
            for (c = 0; c < [calls count]; c++) {
                NSDictionary *call = [calls objectAtIndex:c];
                [outputs addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"function_call_output", @"type",
                    [TBString(call, @"call_id") length] ? TBString(call, @"call_id") : TBString(call, @"id"), @"call_id",
                    @"No more tools this turn. Tell the user what already finished. Do not ask them to type continue.", @"output", nil]];
            }
            payload = [NSMutableDictionary dictionaryWithObjectsAndKeys:chosen, @"model", [NSNumber numberWithBool:YES], @"store", TBString(completed, @"id"), @"previous_response_id",
                tools, @"tools", @"none", @"tool_choice", outputs, @"input", nil];
            forced = YES;
            continue;
        }
        if (!sawText) {
            NSString *text = @"";
            @try {
                text = extractText(completed);
            } @catch (NSException *e) {
                text = @"";
            }
            if ([text length])
                [self emit:@"t" text:text];
            else if (lastFailed)
                [self emit:@"t" text:[self stoppedEarlyOutput:lastOutput reason:nil]];
            else if ([lastOutput length])
                [self emit:@"t" text:lastOutput];
            else if (roundIndex)
                [self emit:@"t" text:@"Done."];
            else
                TBFail(@"The model returned no text.");
        }
        return;
    }
}

/* ---- asking another model ---- */

/* {provider, model, title} for every model that has a key: each provider's default first. */
- (NSArray *)consultChoices
{
    NSMutableArray *rows = [NSMutableArray array];
    NSArray *providers = [TBProviders providers];
    unsigned i;
    for (i = 0; i < [providers count]; i++) {
        NSString *provider = TBString([providers objectAtIndex:i], @"id");
        NSArray *models = [TBProviders modelsForProvider:provider];
        NSString *standard = [TBProviders defaultModelForProvider:provider];
        unsigned m;
        unsigned first = [rows count];
        if ([provider isEqualToString:@"local"] || ![TBSettings hasKeyForProvider:provider])
            continue;
        for (m = 0; m < [models count]; m++) {
            NSDictionary *item = [models objectAtIndex:m];
            NSDictionary *row = [NSDictionary dictionaryWithObjectsAndKeys:provider, @"provider", TBString(item, @"id"), @"model", TBString(item, @"title"), @"title", nil];
            if ([TBString(item, @"id") isEqualToString:standard])
                [rows insertObject:row atIndex:first];
            else
                [rows addObject:row];
        }
    }
    return rows;
}

- (NSDictionary *)consultDefinition
{
    NSArray *rows = [self consultChoices];
    NSMutableDictionary *seen = [NSMutableDictionary dictionary];
    NSMutableArray *listing = [NSMutableArray array];
    unsigned i;
    if ([rows count] == 0)
        return nil;
    for (i = 0; i < [rows count]; i++) {
        NSString *provider = TBString([rows objectAtIndex:i], @"provider");
        int n = [[seen objectForKey:provider] intValue] + 1;
        [seen setObject:[NSNumber numberWithInt:n] forKey:provider];
        if (n <= 6)
            [listing addObject:[NSString stringWithFormat:@"%@/%@", provider, TBString([rows objectAtIndex:i], @"model")]];
    }
    return [NSDictionary dictionaryWithObjectsAndKeys:@"function", @"type", kConsultTool, @"name",
        [NSString stringWithFormat:@"Ask a different AI model for advice or a review: a second opinion on a plan, a bug, a design, or a draft. The other model cannot use tools or see this chat, "
            "so put what it needs in question. Its answer comes back as the tool result; weigh it, do not just repeat it. Available: %@.", [listing componentsJoinedByString:@", "]], @"description",
        [NSDictionary dictionaryWithObjectsAndKeys:@"object", @"type",
            [NSDictionary dictionaryWithObjectsAndKeys:
                [NSDictionary dictionaryWithObjectsAndKeys:@"string", @"type", @"grok, chatgpt, claude, mistral, muse, gemini or local", @"description", nil], @"provider",
                [NSDictionary dictionaryWithObjectsAndKeys:@"string", @"type", @"Model id from the list. Optional; the provider's default is used when blank.", @"description", nil], @"model",
                [NSDictionary dictionaryWithObjectsAndKeys:@"string", @"type", @"What to ask. Be specific and include any code or text to review.", @"description", nil], @"question", nil], @"properties",
            [NSArray arrayWithObjects:@"provider", @"question", nil], @"required", nil], @"parameters", nil];
}

- (NSString *)consult:(NSDictionary *)args
{
    NSString *question = TBString(args, @"question");
    NSString *provider, *model, *chosen, *system, *answer;
    NSMutableArray *pool = [NSMutableArray array];
    NSArray *choices = [self consultChoices];
    unsigned i;
    if ([TBTrim(question) length] == 0)
        TBFail(@"Give a question.");
    if ([question length] > 60000)
        TBFail(@"The question is too long; send the key parts.");
    provider = [TBProviders normalize:TBString(args, @"provider")];
    model = [TBString(args, @"model") length] ? TBString(args, @"model") : nil;
    for (i = 0; i < [choices count]; i++) {
        if ([TBString([choices objectAtIndex:i], @"provider") isEqualToString:provider])
            [pool addObject:[choices objectAtIndex:i]];
    }
    if ([pool count] == 0)
        TBFail(@"%@ has no working models right now.", provider);
    if (model) {
        BOOL found = NO;
        for (i = 0; i < [pool count]; i++) {
            if ([TBString([pool objectAtIndex:i], @"model") isEqualToString:model])
                found = YES;
        }
        if (!found)
            TBFail(@"%@ is not an available %@ model.", model, provider);
    }
    chosen = [TBProviders resolveModel:model provider:provider];
    system = @"Another AI assistant is consulting you for advice or a review. Answer directly and concisely. Say plainly what you would change and why, and what you are unsure about. You have no tools.";
    answer = [self completeProvider:provider model:chosen system:system messages:[NSArray arrayWithObject:[NSDictionary dictionaryWithObjectsAndKeys:@"user", @"role", question, @"content", nil]]];
    return [NSString stringWithFormat:@"Answer from %@/%@:\n\n%@", provider, chosen, answer];
}

/* ---- extras: custom MCP servers, the agent toolbox, search and media (added as they are ported) ---- */

- (NSArray *)extraDefinitionsForProvider:(NSString *)provider skip:(NSSet *)skip
{
    NSMutableArray *tools = [NSMutableArray array];
    if ([TBSettings flag:@"consult_enabled"] && ![skip containsObject:@"consult"]) {
        NSDictionary *consult = [self consultDefinition];
        if (consult)
            [tools addObject:consult];
    }
    if (!extras)
        extras = [[TBExtras alloc] initWithRun:run];
    [tools addObjectsFromArray:[extras definitionsForProvider:provider skip:skip]];
    return tools;
}

- (void)closeExtras
{
    [extras close];
    [extras release];
    extras = nil;
}

- (BOOL)extraHandles:(NSString *)name
{
    return [extras handles:name];
}

- (NSDictionary *)runExtraCall:(NSString *)name arguments:(NSDictionary *)args
{
    return [extras call:name arguments:args];
}

- (NSArray *)mediaToolsForProvider:(NSString *)provider
{
    return [TBMedia toolsForProvider:provider];
}

- (NSDictionary *)runMediaCall:(NSString *)name arguments:(NSDictionary *)args provider:(NSString *)provider
{
    @try {
        NSDictionary *info = [TBMedia create:name prompt:TBString(args, @"prompt") provider:provider run:run];
        NSString *kind = TBString(info, @"kind"), *file = TBString(info, @"filename");
        NSString *path = [NSString stringWithFormat:@"%@/%@", [self mediaRoot], file];
        return [NSDictionary dictionaryWithObjectsAndKeys:[NSString stringWithFormat:@"Saved the %@ on this Mac at %@.", kind, path], @"output", [NSNumber numberWithBool:NO], @"failed",
            [NSString stringWithFormat:@"%@ %@", kind, file], @"media", nil];
    } @catch (NSException *exception) {
        if ([[exception name] isEqualToString:TBStoppedException])
            @throw;
        return [NSDictionary dictionaryWithObjectsAndKeys:[@"error: " stringByAppendingString:[exception reason]], @"output", [NSNumber numberWithBool:YES], @"failed", nil];
    }
    return nil;
}

@end
