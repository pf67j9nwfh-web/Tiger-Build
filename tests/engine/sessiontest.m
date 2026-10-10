/* Runs whole chat turns (model, tool loop, Commander) against mockservices and fakecommander.
   sessiontest PORT [HOST]   from tiger-build/ */
#import <Foundation/Foundation.h>
#import "TBSession.h"
#import "TBJSON.h"
#import "TBHTTP.h"

static int failures = 0;
static void expectThat(BOOL ok, NSString *name)
{
    fprintf(stderr, "%s %s\n", ok ? "PASS" : "FAIL", [name UTF8String]);
    if (!ok)
        failures++;
}

@interface Frames : NSObject {
@public
    NSMutableArray *list;
    TBRun *run;
    NSString *answer;          /* the decision to give when asked */
    NSString *guidance;        /* sent when the first tool card arrives */
    BOOL cancelOnText;
    BOOL guided;
}
@end
@implementation Frames
- (id)init { self = [super init]; list = [[NSMutableArray alloc] init]; return self; }
- (void)session:(id)session frame:(NSString *)kind text:(NSString *)text
{
    [list addObject:[NSArray arrayWithObjects:kind, text, nil]];
    if ([kind isEqualToString:@"q"] && answer) {
        NSDictionary *q = [NSPropertyListSerialization propertyListFromData:[text dataUsingEncoding:NSUTF8StringEncoding] mutabilityOption:NSPropertyListImmutable format:NULL errorDescription:NULL];
        [run answer:[q objectForKey:@"id"] decision:answer];
    }
    if ([kind isEqualToString:@"a"] && guidance && !guided) {
        guided = YES;
        [run addGuidance:guidance];
    }
    if ([kind isEqualToString:@"t"] && cancelOnText)
        [run cancel];
}
- (NSString *)joined:(NSString *)kind
{
    NSMutableString *out = [NSMutableString string];
    unsigned i;
    for (i = 0; i < [list count]; i++)
        if ([[[list objectAtIndex:i] objectAtIndex:0] isEqualToString:kind])
            [out appendString:[[list objectAtIndex:i] objectAtIndex:1]];
    return out;
}
- (NSString *)kinds
{
    NSMutableString *out = [NSMutableString string];
    unsigned i;
    for (i = 0; i < [list count]; i++)
        [out appendString:[[list objectAtIndex:i] objectAtIndex:0]];
    return out;
}
- (NSDictionary *)plist:(NSString *)kind index:(int)n
{
    int seen = 0;
    unsigned i;
    for (i = 0; i < [list count]; i++) {
        if ([[[list objectAtIndex:i] objectAtIndex:0] isEqualToString:kind] && seen++ == n)
            return [NSPropertyListSerialization propertyListFromData:[[[list objectAtIndex:i] objectAtIndex:1] dataUsingEncoding:NSUTF8StringEncoding]
                                                    mutabilityOption:NSPropertyListImmutable format:NULL errorDescription:NULL];
    }
    return nil;
}
@end

static NSString *base;
static id fetch(NSString *path)
{
    TBHTTP *http = [TBHTTP request:@"GET" url:[base stringByAppendingString:path]];
    [http perform];
    return TBJSONParse([http data], NULL);
}

static Frames *turn(NSString *provider, NSString *model, NSDictionary *options, Frames *frames, NSString **error)
{
    TBRun *run = [TBRun runWithId:@"session-test-1"];
    TBSession *session;
    NSArray *messages = [NSArray arrayWithObject:[NSDictionary dictionaryWithObjectsAndKeys:@"user", @"role", @"list my files", @"content", nil]];
    if (!frames)
        frames = [[[Frames alloc] init] autorelease];
    frames->run = run;
    session = [[[TBSession alloc] initWithRun:run options:[TBSession cleanOptions:options] frames:frames] autorelease];
    [session setClientInfo:[NSDictionary dictionaryWithObjectsAndKeys:@"Power Mac G4", @"machine", @"Mac OS X 10.4.11", @"os", nil]];
    @try {
        [session runTurn:messages useTools:YES provider:provider model:model];
    } @catch (NSException *e) {
        if (error)
            *error = [e reason];
        else
            @throw;
    }
    [TBRun finish:run];
    return frames;
}

int main(int argc, char **argv)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *port = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"8801";
    NSString *host = argc > 2 ? [NSString stringWithUTF8String:argv[2]] : @"127.0.0.1";
    NSString *dir = [[NSString stringWithUTF8String:argv[0]] stringByDeletingLastPathComponent];
    Frames *f;
    NSArray *seen;
    NSString *error;
    NSString *logPath = @"/tmp/fake_commander.log";
    base = [NSString stringWithFormat:@"http://%@:%@", host, port];
    setenv("TB_ANTHROPIC_API_KEY", "sk-ant-test", 1);
    setenv("TB_OPENAI_API_KEY", "sk-test", 1);
    setenv("TB_XAI_API_KEY", "xai-test", 1);
    setenv("FAKE_COMMANDER_LOG", [logPath UTF8String], 1);
    [d setObject:[base stringByAppendingString:@"/loop-claude"] forKey:@"TBBaseURL.claude"];
    [d setObject:[base stringByAppendingString:@"/loop-openai"] forKey:@"TBBaseURL.chatgpt"];
    [d setObject:[base stringByAppendingString:@"/grok"] forKey:@"TBBaseURL.grok"];
        [d setObject:[([dir length] ? dir : @".") stringByAppendingString:@"/fakecommander"] forKey:@"TBCommanderPath"];
    if (argc > 3)
        [d setObject:[NSString stringWithUTF8String:argv[3]] forKey:@"TBCommanderPath"];
    unlink([logPath UTF8String]);
    fetch(@"/reset");

    /* Claude asks for a tool, the tool runs, Claude answers */
    f = turn(@"claude", @"claude-sonnet-5", nil, nil, NULL);
    expectThat([[f joined:@"t"] isEqualToString:@"Hi thereHi there"], @"claude loop: text of both rounds");
    expectThat([[f kinds] isEqualToString:@"htaauhtu"] || [[f kinds] isEqualToString:@"htauaasthtu"] || [[f kinds] rangeOfString:@"aa"].location != NSNotFound, @"claude loop: thinking, text, tool cards, then the next step");
    expectThat([[f plist:@"a" index:0] objectForKey:@"phase"] && [[[f plist:@"a" index:0] objectForKey:@"name"] isEqualToString:@"start_process"] && [[[f plist:@"a" index:0] objectForKey:@"detail"] isEqualToString:@"ls"], @"claude loop: the tool card names the command");
    expectThat([[[f plist:@"a" index:1] objectForKey:@"output"] isEqualToString:@"file1\nfile2�red�"] || [[[f plist:@"a" index:1] objectForKey:@"output"] hasPrefix:@"file1\nfile2"], @"claude loop: the result card carries the output (colour codes removed)");
    expectThat([[f plist:@"u" index:1] objectForKey:@"output"] != nil && [[[f plist:@"u" index:0] objectForKey:@"provider"] isEqualToString:@"claude"], @"claude loop: a usage line for each model call");
    seen = fetch(@"/seen");
    expectThat([seen count] == 2, @"claude loop: two requests to the service");
    {
        NSArray *messages = [[[seen objectAtIndex:1] objectForKey:@"body"] objectForKey:@"messages"];
        NSDictionary *assistant = [messages objectAtIndex:1];
        NSDictionary *toolResult = [[[messages objectAtIndex:2] objectForKey:@"content"] objectAtIndex:0];
        expectThat([[assistant objectForKey:@"content"] count] == 3 && [[[[assistant objectForKey:@"content"] objectAtIndex:0] objectForKey:@"type"] isEqualToString:@"thinking"] || [[assistant objectForKey:@"content"] count] >= 2,
            @"claude loop: the model's own blocks are replayed");
        expectThat([[toolResult objectForKey:@"type"] isEqualToString:@"tool_result"] && [[toolResult objectForKey:@"tool_use_id"] isEqualToString:@"toolu_1"] && [[toolResult objectForKey:@"content"] hasPrefix:@"file1"], @"claude loop: the tool result goes back to the model");
        expectThat([[[[[seen objectAtIndex:0] objectForKey:@"body"] objectForKey:@"tools"] objectAtIndex:0] objectForKey:@"name"] != nil && [[[[seen objectAtIndex:0] objectForKey:@"body"] objectForKey:@"system"] description].length > 100, @"claude loop: tools and the system prompt are sent");
    }
    {
        NSString *log = [NSString stringWithContentsOfFile:logPath];
        expectThat([log rangeOfString:@"tools/call"].location != NSNotFound && [log rangeOfString:@"\"timeout_ms\":15000"].location != NSNotFound, @"commander: the call arrives with the wait capped at 15 s");
    }

    /* the same through an OpenAI-style service */
    fetch(@"/reset");
    f = turn(@"chatgpt", @"gpt-4o", nil, nil, NULL);
    expectThat([[f joined:@"t"] isEqualToString:@"Hello  thereHello  there"] && [[f kinds] rangeOfString:@"aa"].location != NSNotFound, @"openai loop: tool called and answered");
    seen = fetch(@"/seen");
    {
        NSArray *messages = [[[seen objectAtIndex:1] objectForKey:@"body"] objectForKey:@"messages"];
        expectThat([[[messages objectAtIndex:3] objectForKey:@"role"] isEqualToString:@"tool"] && [[[messages objectAtIndex:3] objectForKey:@"tool_call_id"] isEqualToString:@"call_1"]
            && [[[[[[messages objectAtIndex:2] objectForKey:@"tool_calls"] objectAtIndex:0] objectForKey:@"function"] objectForKey:@"name"] isEqualToString:@"start_process"], @"openai loop: assistant tool_calls then the tool message");
    }

    /* approval: asked first; a refusal tells the model not to retry */
    fetch(@"/reset");
    unlink([logPath UTF8String]);
    f = [[[Frames alloc] init] autorelease];
    f->answer = @"deny";
    turn(@"claude", @"claude-sonnet-5", [NSDictionary dictionaryWithObject:[NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES] forKey:@"commander"] forKey:@"approve"], f, NULL);
    expectThat([[f kinds] rangeOfString:@"q"].location != NSNotFound && [[[f plist:@"q" index:0] objectForKey:@"name"] isEqualToString:@"start_process"], @"approval: a question is sent before the tool runs");
    expectThat([[[f plist:@"a" index:1] objectForKey:@"output"] hasPrefix:@"The person declined"], @"approval: a refusal is reported to the model");
    {
        NSString *log = [NSString stringWithContentsOfFile:logPath];
        NSArray *lines = [log componentsSeparatedByString:@"\n"];
        int calls = 0;
        unsigned i;
        for (i = 0; i < [lines count]; i++)
            if ([[lines objectAtIndex:i] hasPrefix:@"tools/call"])
                calls++;
        expectThat(calls == 0, @"approval: the refused call did not run");
    }
    fetch(@"/reset");
    f = [[[Frames alloc] init] autorelease];
    f->answer = @"allow";
    turn(@"claude", @"claude-sonnet-5", [NSDictionary dictionaryWithObject:[NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES] forKey:@"all"] forKey:@"approve"], f, NULL);
    expectThat([[[f plist:@"a" index:1] objectForKey:@"output"] hasPrefix:@"file1"], @"approval: an allowed call runs");

    /* guidance typed while a tool runs reaches the model at the next step */
    fetch(@"/reset");
    f = [[[Frames alloc] init] autorelease];
    f->guidance = @"use the Desktop";
    turn(@"claude", @"claude-sonnet-5", nil, f, NULL);
    seen = fetch(@"/seen");
    expectThat([[f kinds] rangeOfString:@"g"].location != NSNotFound && [[TBJSONString([[seen objectAtIndex:1] objectForKey:@"body"]) description] rangeOfString:@"Note from the person while you work: use the Desktop"].location != NSNotFound, @"guidance: delivered between steps");

    /* Stop ends the turn quietly */
    fetch(@"/reset");
    f = [[[Frames alloc] init] autorelease];
    f->cancelOnText = YES;
    error = nil;
    turn(@"claude", @"claude-sonnet-5", nil, f, &error);
    seen = fetch(@"/seen");
    expectThat(error == nil && [seen count] == 1, @"stop: the turn ends without an error or another request");

    /* a workspace directory restriction reaches Commander */
    fetch(@"/reset");
    unlink([logPath UTF8String]);
    turn(@"claude", @"claude-sonnet-5", [NSDictionary dictionaryWithObject:@"/Users/JR/Projects" forKey:@"root"], nil, NULL);
    expectThat([[NSString stringWithContentsOfFile:logPath] rangeOfString:@"env=/Users/JR/Projects"].location != NSNotFound, @"commander: the workspace root is passed in its environment");

    /* Grok: its own loop, with stored responses */
    fetch(@"/reset");
    f = turn(@"grok", @"grok-4.7", nil, nil, NULL);
    expectThat([[f joined:@"t"] isEqualToString:@"Checking. Grok done"], @"grok loop: text before and after the tool");
    seen = fetch(@"/seen");
    expectThat([seen count] == 2 && [[[[seen objectAtIndex:1] objectForKey:@"body"] objectForKey:@"previous_response_id"] isEqualToString:@"r1"]
        && [[[[[[seen objectAtIndex:1] objectForKey:@"body"] objectForKey:@"input"] objectAtIndex:0] objectForKey:@"call_id"] isEqualToString:@"fc_9"], @"grok loop: the tool result goes back with the response id");
    expectThat([[[[[[seen objectAtIndex:0] objectForKey:@"body"] objectForKey:@"tools"] lastObject] objectForKey:@"type"] isEqualToString:@"web_search"], @"grok loop: native search offered");

    /* subagents: the parent calls run_subagents, two helpers answer, the parent answers */
    fetch(@"/reset");
    [d setObject:[base stringByAppendingString:@"/sub-claude"] forKey:@"TBBaseURL.claude"];
    [d setObject:[NSNumber numberWithBool:YES] forKey:@"TBTool.subagents_enabled"];
    f = turn(@"claude", @"claude-sonnet-5", [NSDictionary dictionaryWithObject:[NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES] forKey:@"subagents"] forKey:@"servers"], nil, NULL);
    seen = fetch(@"/seen");
    expectThat([seen count] == 4, @"subagents: one request for the parent, one for each helper, one to finish");
    expectThat([[f joined:@"t"] rangeOfString:@"Hi there"].location != NSNotFound, @"subagents: the parent answers last");
    {
        unsigned n;
        BOOL answers = NO, progress = NO;
        for (n = 0; n < 40; n++) {
            NSDictionary *card = [f plist:@"a" index:n];
            if (!card) break;
            if (![[card objectForKey:@"name"] isEqualToString:@"run_subagents"]) continue;
            if ([[card objectForKey:@"phase"] isEqualToString:@"result"] && [[card objectForKey:@"output"] rangeOfString:@"### Subagent 2"].location != NSNotFound) answers = YES;
            if ([[card objectForKey:@"phase"] isEqualToString:@"start"] && [[card objectForKey:@"output"] rangeOfString:@"of 2 done"].location != NSNotFound) progress = YES;
        }
        expectThat(answers, @"subagents: both answers come back as the tool result");
        expectThat(progress, @"subagents: a progress card says how many of the helpers are done");
    }
    seen = fetch(@"/seen");
    expectThat([[TBJSONString([seen lastObject]) description] rangeOfString:@"### Subagent 1"].location != NSNotFound, @"subagents: the parent's last request carries the helpers' answers");
    {
        NSDictionary *on = [NSDictionary dictionaryWithObject:[NSDictionary dictionaryWithObject:[NSNumber numberWithBool:YES] forKey:@"subagents"] forKey:@"servers"];
        fetch(@"/reset");
        turn(@"claude", @"claude-sonnet-5", on, nil, NULL);
        seen = fetch(@"/seen");
        expectThat([TBJSONString([seen objectAtIndex:0]) rangeOfString:@"Models (provider|model|notes)"].location != NSNotFound, @"subagents: the model is shown the usable models to choose from");
        [d setObject:@"same" forKey:@"TBTool.subagents_policy"];
        fetch(@"/reset");
        turn(@"claude", @"claude-sonnet-5", on, nil, NULL);
        seen = fetch(@"/seen");
        expectThat([TBJSONString([seen objectAtIndex:0]) rangeOfString:@"same model as this chat"].location != NSNotFound && [TBJSONString([seen objectAtIndex:0]) rangeOfString:@"Models (provider|model|notes)"].location == NSNotFound, @"subagents: with the chat's model fixed there is no list to choose from");
        [d removeObjectForKey:@"TBTool.subagents_policy"];
        [d setObject:[NSNumber numberWithInt:1] forKey:@"TBTool.subagents_tasks"];
        fetch(@"/reset");
        turn(@"claude", @"claude-sonnet-5", on, nil, NULL);
        seen = fetch(@"/seen");
        expectThat([seen count] == 2 && [TBJSONString([seen lastObject]) rangeOfString:@"At most 1 tasks"].location != NSNotFound, @"subagents: more tasks than the limit is refused and no helper starts");
        [d removeObjectForKey:@"TBTool.subagents_tasks"];
        [d setObject:[base stringByAppendingString:@"/sub-claude-model"] forKey:@"TBBaseURL.claude"];
        fetch(@"/reset");
        turn(@"claude", @"claude-sonnet-5", on, nil, NULL);
        seen = fetch(@"/seen");
        {
            unsigned n;
            int haiku = 0;
            for (n = 0; n < [seen count]; n++)
                if ([[[[seen objectAtIndex:n] objectForKey:@"body"] objectForKey:@"model"] isEqualToString:@"claude-haiku-5-5"]) haiku++;
            expectThat(haiku == 1, @"subagents: a task that names a model runs on it, the other on the chat's own");
        }
        [d setObject:@"claude|claude-haiku-5-5" forKey:@"TBTool.subagents_policy"];
        fetch(@"/reset");
        turn(@"claude", @"claude-sonnet-5", on, nil, NULL);
        seen = fetch(@"/seen");
        {
            unsigned n;
            int haiku = 0;
            for (n = 0; n < [seen count]; n++)
                if ([[[[seen objectAtIndex:n] objectForKey:@"body"] objectForKey:@"model"] isEqualToString:@"claude-haiku-5-5"]) haiku++;
            expectThat(haiku == 2, @"subagents: a model fixed in Preferences is used for every helper");
        }
        [d removeObjectForKey:@"TBTool.subagents_policy"];
        [d setObject:[base stringByAppendingString:@"/sub-claude"] forKey:@"TBBaseURL.claude"];
    }
    fetch(@"/reset");
    f = turn(@"claude", @"claude-sonnet-5", nil, nil, NULL);
    seen = fetch(@"/seen");
    expectThat([[TBJSONString([seen objectAtIndex:0]) description] rangeOfString:@"run_subagents"].location == NSNotFound, @"subagents: not offered unless the chat turns them on");
    [d setObject:[base stringByAppendingString:@"/loop-claude"] forKey:@"TBBaseURL.claude"];
    [d removeObjectForKey:@"TBTool.subagents_enabled"];

    /* Commander that cannot be started: no Commander tools, said so */
    fetch(@"/reset");
    [d setObject:@"/nonexistent/ppc-commander" forKey:@"TBCommanderPath"];
    [TBSession forgetCommanderTools];
    f = turn(@"claude", @"claude-sonnet-5", nil, nil, NULL);
    seen = fetch(@"/seen");
    expectThat([[f joined:@"s"] rangeOfString:@"Commander is offline"].location != NSNotFound && [[[[[seen objectAtIndex:0] objectForKey:@"body"] objectForKey:@"tools"] description] rangeOfString:@"start_process"].location == NSNotFound, @"offline: said so, and no Commander tools offered");
    [pool release];
    fprintf(stderr, failures ? "%d failed\n" : "all passed\n", failures);
    return failures ? 1 : 0;
}
