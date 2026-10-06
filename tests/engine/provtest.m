/* Runs the provider code against mock_services.py. Needs the mock running: provtest PORT (from tiger-build/, for models.txt). */
#import <Foundation/Foundation.h>
#import "TBProviders.h"
#import "TBJSON.h"
#import "TBHTTP.h"

static int failures = 0;
static void expectThat(BOOL ok, NSString *name)
{
    fprintf(stderr, "%s %s\n", ok ? "PASS" : "FAIL", [name UTF8String]);
    if (!ok)
        failures++;
}

@interface Sink : NSObject {
@public
    NSMutableString *text;
    NSMutableString *thinking;
}
@end
@implementation Sink
- (id)init { self = [super init]; text = [[NSMutableString alloc] init]; thinking = [[NSMutableString alloc] init]; return self; }
- (void)round:(TBRound *)r text:(NSString *)t { [text appendString:t]; }
- (void)round:(TBRound *)r thinking:(NSString *)t { [thinking appendString:t]; }
@end

static NSString *base;
static id fetch(NSString *path)
{
    TBHTTP *http = [TBHTTP request:@"GET" url:[base stringByAppendingString:path]];
    [http perform];
    return TBJSONParse([http data], NULL);
}

static TBRound *run(NSString *provider, NSString *model, NSArray *tools, Sink *sink, NSString **error)
{
    TBRound *round = [[[TBRound alloc] init] autorelease];
    NSArray *log = [NSArray arrayWithObject:[NSDictionary dictionaryWithObjectsAndKeys:@"user", @"role", @"hello", @"content", nil]];
    round->run = [[TBRun runWithId:@"test-run-1"] retain];
    round->sink = sink;
    @try {
        [TBProviders streamRound:provider system:@"You are a test." log:log tools:tools round:round model:model];
    } @catch (NSException *e) {
        if (error)
            *error = [e reason];
        else
            @throw;
    }
    return round;
}

int main(int argc, char **argv)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSArray *tools = [NSArray arrayWithObject:[NSDictionary dictionaryWithObjectsAndKeys:@"start_process", @"name", @"run a command", @"description",
        [NSDictionary dictionaryWithObjectsAndKeys:@"object", @"type", [NSDictionary dictionaryWithObject:[NSDictionary dictionaryWithObject:@"string" forKey:@"type"] forKey:@"command"], @"properties", nil], @"parameters", nil]];
    NSString *port = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"8801";
    Sink *sink;
    TBRound *round;
    NSString *error;
    NSArray *seen;
    base = [NSString stringWithFormat:@"http://%@:%@", argc > 2 ? [NSString stringWithUTF8String:argv[2]] : @"127.0.0.1", port];
    setenv("TB_OPENAI_API_KEY", "sk-test-openai", 1);
    setenv("TB_ANTHROPIC_API_KEY", "sk-ant-test", 1);
    setenv("TB_GEMINI_API_KEY", "gem-test", 1);
    setenv("TB_MISTRAL_API_KEY", "mis-test", 1);
    setenv("TB_LOCAL_URL", [[base stringByAppendingString:@"/local"] UTF8String], 1);
    [d setObject:[base stringByAppendingString:@"/openai"] forKey:@"TBBaseURL.chatgpt"];
    [d setObject:[base stringByAppendingString:@"/responses"] forKey:@"TBBaseURL.chatgpt-responses"];
    [d setObject:[base stringByAppendingString:@"/anthropic"] forKey:@"TBBaseURL.claude"];
    [d setObject:[base stringByAppendingString:@"/gemini/%@"] forKey:@"TBBaseURL.gemini"];
    [d setObject:[base stringByAppendingString:@"/openai"] forKey:@"TBBaseURL.mistral"];
    fetch(@"/reset");

    /* chat completions: reasoning, hidden <think> text, a tool call and the token counts */
    sink = [[[Sink alloc] init] autorelease];
    round = run(@"chatgpt", @"gpt-4o", tools, sink, NULL);
    expectThat([sink->text isEqualToString:@"Hello  there"], @"openai: visible text without the think block");
    expectThat([sink->thinking isEqualToString:@"Let me think. hidden more"], @"openai: thinking from reasoning_content and <think>");
    expectThat([round->calls count] == 1 && [[[round->calls objectAtIndex:0] objectForKey:@"name"] isEqualToString:@"start_process"]
        && [[[round->calls objectAtIndex:0] objectForKey:@"arguments"] isEqualToString:@"{\"command\":\"ls\"}"] && [[[round->calls objectAtIndex:0] objectForKey:@"id"] isEqualToString:@"call_1"], @"openai: tool call assembled from pieces");
    expectThat([[round->usage objectForKey:@"input"] intValue] == 60 && [[round->usage objectForKey:@"cached"] intValue] == 40 && [[round->usage objectForKey:@"output"] intValue] == 20, @"openai: usage counts");
    seen = fetch(@"/seen");
    expectThat([[[[seen lastObject] objectForKey:@"headers"] objectForKey:@"authorization"] isEqualToString:@"Bearer sk-test-openai"], @"openai: bearer key sent");
    expectThat([[[[seen lastObject] objectForKey:@"body"] objectForKey:@"stream_options"] objectForKey:@"include_usage"] != nil && [[[seen lastObject] objectForKey:@"body"] objectForKey:@"tools"], @"openai: usage option and tools sent");
    expectThat([[[[[[seen lastObject] objectForKey:@"body"] objectForKey:@"messages"] objectAtIndex:0] objectForKey:@"role"] isEqualToString:@"system"], @"openai: system message first");

    /* a refusal of stream_options is retried without it */
    fetch(@"/reset");
    [d setObject:[base stringByAppendingString:@"/openai-retry"] forKey:@"TBBaseURL.chatgpt"];
    sink = [[[Sink alloc] init] autorelease];
    round = run(@"chatgpt", @"gpt-4o", nil, sink, NULL);
    seen = fetch(@"/seen");
    expectThat([seen count] == 2 && [[[seen objectAtIndex:0] objectForKey:@"body"] objectForKey:@"stream_options"] && ![[[seen objectAtIndex:1] objectForKey:@"body"] objectForKey:@"stream_options"]
        && [sink->text isEqualToString:@"Hello  there"], @"openai: stream_options refused, retried without it");

    /* a service error is reported in words */
    [d setObject:[base stringByAppendingString:@"/openai-down"] forKey:@"TBBaseURL.chatgpt"];
    error = nil;
    run(@"chatgpt", @"gpt-4o", nil, [[[Sink alloc] init] autorelease], &error);
    expectThat([error isEqualToString:@"The model service returned 429: Rate limit reached"], @"openai: HTTP 429 reported");

    /* Mistral asks for reasoning and drops it when refused */
    fetch(@"/reset");
    [d setObject:[base stringByAppendingString:@"/openai"] forKey:@"TBBaseURL.mistral"];
    sink = [[[Sink alloc] init] autorelease];
    round = run(@"mistral", @"ministral-14b-latest", nil, sink, NULL);
    seen = fetch(@"/seen");
    expectThat([[[[seen lastObject] objectForKey:@"body"] objectForKey:@"reasoning_effort"] isEqualToString:@"high"], @"mistral: reasoning_effort high asked for");

    /* Claude */
    fetch(@"/reset");
    sink = [[[Sink alloc] init] autorelease];
    round = run(@"claude", @"claude-sonnet-5", tools, sink, NULL);
    expectThat([sink->text isEqualToString:@"Hi there"] && [sink->thinking isEqualToString:@"Considering."], @"claude: text and thinking");
    expectThat([round->calls count] == 1 && [[[round->calls objectAtIndex:0] objectForKey:@"id"] isEqualToString:@"toolu_1"]
        && [[[round->calls objectAtIndex:0] objectForKey:@"arguments"] isEqualToString:@"{\"command\":\"ls\"}"], @"claude: tool_use input assembled");
    expectThat([round->claudeBlocks count] == 3 && [[[round->claudeBlocks objectAtIndex:0] objectForKey:@"type"] isEqualToString:@"thinking"] && [[[round->claudeBlocks objectAtIndex:0] objectForKey:@"signature"] isEqualToString:@"SIG"], @"claude: signed thinking block kept for replay");
    expectThat([[round->usage objectForKey:@"input"] intValue] == 50 && [[round->usage objectForKey:@"cached"] intValue] == 10 && [[round->usage objectForKey:@"written"] intValue] == 5 && [[round->usage objectForKey:@"output"] intValue] == 33, @"claude: usage counts");
    seen = fetch(@"/seen");
    {
        NSDictionary *body = [[seen lastObject] objectForKey:@"body"];
        NSDictionary *last = [[body objectForKey:@"messages"] lastObject];
        expectThat([[[seen lastObject] objectForKey:@"headers"] objectForKey:@"x-api-key"] != nil && [[[[seen lastObject] objectForKey:@"headers"] objectForKey:@"anthropic-version"] isEqualToString:@"2023-06-01"], @"claude: key and version headers");
        expectThat([[[[body objectForKey:@"system"] objectAtIndex:0] objectForKey:@"cache_control"] objectForKey:@"type"] != nil
            && [[[[last objectForKey:@"content"] lastObject] objectForKey:@"cache_control"] objectForKey:@"type"] != nil, @"claude: cache marks on the system prompt and last message");
        expectThat([[[body objectForKey:@"thinking"] objectForKey:@"type"] isEqualToString:@"adaptive"] && [[body objectForKey:@"max_tokens"] intValue] == 64000, @"claude: adaptive thinking and max_tokens");
    }
    fetch(@"/reset");
    [d setObject:[base stringByAppendingString:@"/anthropic-cache"] forKey:@"TBBaseURL.claude"];
    sink = [[[Sink alloc] init] autorelease];
    run(@"claude", @"claude-haiku-4-5-20251001", nil, sink, NULL);
    seen = fetch(@"/seen");
    expectThat([seen count] == 2 && [[[seen objectAtIndex:1] objectForKey:@"body"] objectForKey:@"system"] && [[[[seen objectAtIndex:1] objectForKey:@"body"] objectForKey:@"system"] isKindOfClass:[NSString class]]
        && [sink->text isEqualToString:@"Hi there"], @"claude: cache_control refused, retried without marks");
    fetch(@"/reset");
    [d setObject:[base stringByAppendingString:@"/anthropic-limit"] forKey:@"TBBaseURL.claude"];
    run(@"claude", @"claude-haiku-4-5-20251001", nil, [[[Sink alloc] init] autorelease], NULL);
    seen = fetch(@"/seen");
    expectThat([seen count] == 2 && [[[[seen objectAtIndex:1] objectForKey:@"body"] objectForKey:@"max_tokens"] intValue] == 8192, @"claude: max_tokens limit learned and retried");

    /* Gemini */
    fetch(@"/reset");
    sink = [[[Sink alloc] init] autorelease];
    round = run(@"gemini", @"gemini-3.8-flash", tools, sink, NULL);
    expectThat([sink->text isEqualToString:@"Gemini says hi"] && [sink->thinking isEqualToString:@"Pondering."], @"gemini: text and thinking");
    expectThat([round->calls count] == 1 && [[[round->calls objectAtIndex:0] objectForKey:@"thought_signature"] isEqualToString:@"GSIG"], @"gemini: function call with its signature");
    expectThat([[round->usage objectForKey:@"input"] intValue] == 50 && [[round->usage objectForKey:@"cached"] intValue] == 20 && [[round->usage objectForKey:@"output"] intValue] == 8, @"gemini: usage counts");
    seen = fetch(@"/seen");
    expectThat([[[[seen lastObject] objectForKey:@"headers"] objectForKey:@"x-goog-api-key"] isEqualToString:@"gem-test"] && [[[seen lastObject] objectForKey:@"path"] hasPrefix:@"/gemini/gemini-3.8-flash"], @"gemini: key header and model in the address");

    /* the Responses API (a reasoning ChatGPT model) */
    fetch(@"/reset");
    [d setObject:[base stringByAppendingString:@"/openai"] forKey:@"TBBaseURL.chatgpt"];
    sink = [[[Sink alloc] init] autorelease];
    round = run(@"chatgpt", @"gpt-5.5", tools, sink, NULL);
    expectThat([sink->text isEqualToString:@"Response"] && [sink->thinking isEqualToString:@"Summary."], @"responses: text and reasoning summary");
    expectThat([round->calls count] == 1 && [[[round->calls objectAtIndex:0] objectForKey:@"id"] isEqualToString:@"fc_1"], @"responses: function call");
    expectThat([[round->usage objectForKey:@"input"] intValue] == 20 && [[round->usage objectForKey:@"cached"] intValue] == 10 && [[round->usage objectForKey:@"output"] intValue] == 7, @"responses: usage counts");

    /* a local server (LM Studio, Ollama) */
    fetch(@"/reset");
    sink = [[[Sink alloc] init] autorelease];
    round = run(@"local", @"qwen/qwen3.8-27b", tools, sink, NULL);
    expectThat([sink->text isEqualToString:@"Hello  there"] && [round->calls count] == 1, @"local: chat through the server's /v1 address");
    seen = fetch(@"/seen");
    expectThat([[[seen lastObject] objectForKey:@"path"] isEqualToString:@"/local/v1/chat/completions"] && ![[[seen lastObject] objectForKey:@"headers"] objectForKey:@"authorization"], @"local: address and no key");

    /* Stop closes the connection that is waiting */
    [d setObject:[base stringByAppendingString:@"/slow"] forKey:@"TBBaseURL.chatgpt"];
    {
        TBRun *stopper = [TBRun runWithId:@"test-run-2"];
        NSDate *started = [NSDate date];
        TBRound *r2 = [[[TBRound alloc] init] autorelease];
        Sink *s2 = [[[Sink alloc] init] autorelease];
        NSString *name = nil;
        r2->run = [stopper retain];
        r2->sink = s2;
        [NSThread detachNewThreadSelector:@selector(cancel) toTarget:stopper withObject:nil];
        @try {
            [TBProviders streamRound:@"chatgpt" system:@"x" log:[NSArray arrayWithObject:[NSDictionary dictionaryWithObjectsAndKeys:@"user", @"role", @"hi", @"content", nil]] tools:nil round:r2 model:@"gpt-4o"];
        } @catch (NSException *e) {
            name = [e name];
        }
        expectThat([name isEqualToString:TBStoppedException] && -[started timeIntervalSinceNow] < 4, @"stop ends a request that is waiting");
    }
    /* no key */
    unsetenv("TB_XAI_API_KEY");
    error = nil;
    run(@"muse", @"muse-spark-1.3", nil, [[[Sink alloc] init] autorelease], &error);
    expectThat([error rangeOfString:@"Add your Muse API key"].location != NSNotFound, @"a missing key says what to do");
    [pool release];
    fprintf(stderr, failures ? "%d failed\n" : "all passed\n", failures);
    return failures ? 1 : 0;
}
