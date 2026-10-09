#import "TBSession.h"
#import "TBEngine.h"
#import "TBJSON.h"
#import <unistd.h>

/* Subagents: the run_subagents tool starts one TBSession per task, each on its own thread with its own tools, and returns every answer.
   A subagent shares the parent's Stop button and approvals (its tool calls ask the person like any other), cannot start subagents of its own,
   and has no administrator or screen control. Tool-call cards and usage lines flow into the parent's chat. */

#define SUB_MAX_TASKS 8
#define SUB_ANSWER_LIMIT 12000

@interface TBSession (SubagentNeeds)
- (void)emit:(NSString *)kind text:(NSString *)text;
- (void)turn:(NSArray *)incoming useTools:(BOOL)useTools provider:(NSString *)provider model:(NSString *)requested systemOverride:(NSString *)override;
- (NSArray *)consultChoices;
@end

static NSString *const kSubTool = @"run_subagents";

@interface TBSubSink : NSObject {
    TBSession *parent;
    int index;
    NSMutableString *answer;
}
- (id)initWithParent:(TBSession *)parent index:(int)index;
- (NSString *)answer;
@end

@implementation TBSubSink

- (id)initWithParent:(TBSession *)p index:(int)i
{
    self = [super init];
    parent = p;
    index = i;
    answer = [[NSMutableString alloc] init];
    return self;
}

- (void)dealloc
{
    [answer release];
    [super dealloc];
}

- (NSString *)answer
{
    @synchronized(self) { return [[answer copy] autorelease]; }
}

- (void)session:(id)session frame:(NSString *)kind text:(NSString *)text
{
    (void)session;
    if ([kind isEqualToString:@"t"]) {
        @synchronized(self) { [answer appendString:text]; }
        return;
    }
    if ([kind isEqualToString:@"s"])
        text = [NSString stringWithFormat:@"Subagent %d: %@", index + 1, text];
    else if ([kind isEqualToString:@"u"]) {
        /* the parent's context meter is about the parent, not about a helper's own conversation */
        NSString *problem = nil;
        NSMutableDictionary *usage = [NSPropertyListSerialization propertyListFromData:[text dataUsingEncoding:NSUTF8StringEncoding]
            mutabilityOption:NSPropertyListMutableContainers format:NULL errorDescription:&problem];
        if (![usage isKindOfClass:[NSMutableDictionary class]])
            return;
        [usage removeObjectForKey:@"context"];
        text = [TBSession propertyListText:usage];
    } else if (![kind isEqualToString:@"a"] && ![kind isEqualToString:@"q"] && ![kind isEqualToString:@"m"])
        return;
    @synchronized(parent) { [parent emit:kind text:text]; }
}

@end

@interface TBSubJob : NSObject {
@public
    TBSession *parent;
    int index;
    NSString *task, *provider, *model;
    TBSubSink *sink;
    NSString *failure;
    BOOL done;
}
- (void)work:(id)unused;
@end

@implementation TBSubJob

- (void)dealloc
{
    [task release]; [provider release]; [model release]; [sink release]; [failure release];
    [super dealloc];
}

- (void)work:(id)unused
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    TBSession *sub = nil;
    (void)unused;
    @try {
        NSMutableDictionary *opts = [NSMutableDictionary dictionaryWithDictionary:parent->options];
        NSMutableDictionary *servers = [NSMutableDictionary dictionaryWithDictionary:[parent->options objectForKey:@"servers"]];
        NSArray *off = [NSArray arrayWithObjects:@"subagents", @"sudo", @"screen", @"consult", nil];
        unsigned i;
        for (i = 0; i < [off count]; i++)
            [servers setObject:[NSNumber numberWithBool:NO] forKey:[off objectAtIndex:i]];
        [opts setObject:servers forKey:@"servers"];
        [opts setObject:@"You are a subagent: another assistant gave you one part of a bigger job. Do it with the tools you have, then reply with a complete, concise result. "
            "You cannot ask questions, so make sensible assumptions and say what you assumed." forKey:@"instructions"];
        [opts removeObjectForKey:@"memory"];
        sub = [[TBSession alloc] initWithRun:parent->run options:opts frames:sink];
        sub->subPrefix = [[NSString stringWithFormat:@"sub%d:", index + 1] retain];
        [sub setClientInfo:parent->client];
        [sub turn:[NSArray arrayWithObject:[NSDictionary dictionaryWithObjectsAndKeys:@"user", @"role", task, @"content", nil]]
            useTools:YES provider:provider model:model systemOverride:nil];
    } @catch (NSException *exception) {
        if (![[exception name] isEqualToString:TBStoppedException])
            failure = [[exception reason] copy];
    }
    @try { [sub closeTools]; } @catch (NSException *ignored) { }
    [sub release];
    @synchronized(self) { done = YES; }
    [pool release];
}

- (BOOL)finished
{
    @synchronized(self) { return done; }
}

@end

@implementation TBSession (Subagents)

static int cpuCount(void)
{
    int n = (int)[[NSProcessInfo processInfo] processorCount];
    return n < 1 ? 1 : n;
}

/* How many run at once: the Mac's cores up to four, unless TBTool.subagents_max says otherwise. */
static int concurrency(void)
{
    NSNumber *set = [[NSUserDefaults standardUserDefaults] objectForKey:@"TBTool.subagents_max"];
    int n = set ? [set intValue] : (cpuCount() < 4 ? cpuCount() : 4);
    return n < 1 ? 1 : (n > SUB_MAX_TASKS ? SUB_MAX_TASKS : n);
}

- (NSDictionary *)subagentDefinition
{
    NSDictionary *task = [NSDictionary dictionaryWithObjectsAndKeys:@"object", @"type",
        [NSDictionary dictionaryWithObjectsAndKeys:
            [NSDictionary dictionaryWithObjectsAndKeys:@"string", @"type", @"The whole job for this helper, with everything it needs: it cannot see this chat.", @"description", nil], @"task",
            [NSDictionary dictionaryWithObjectsAndKeys:@"string", @"type", @"Optional provider/model, for example claude/claude-haiku-5-5, to run this helper on. Blank uses the model of this chat.", @"description", nil], @"model", nil], @"properties",
        [NSArray arrayWithObject:@"task"], @"required", nil];
    return [NSDictionary dictionaryWithObjectsAndKeys:@"function", @"type", kSubTool, @"name",
        [NSString stringWithFormat:@"Run up to %d helpers (subagents) at the same time, each on its own task, and get all their answers back. They have the same tools as you, work independently and cannot see this chat. "
            "This Mac runs %d at once; the rest wait their turn. Use it for work that splits into independent parts.", SUB_MAX_TASKS, concurrency()], @"description",
        [NSDictionary dictionaryWithObjectsAndKeys:@"object", @"type",
            [NSDictionary dictionaryWithObjectsAndKeys:
                [NSDictionary dictionaryWithObjectsAndKeys:@"array", @"type", task, @"items", @"The tasks, one per helper.", @"description", nil], @"tasks", nil], @"properties",
            [NSArray arrayWithObject:@"tasks"], @"required", nil], @"parameters", nil];
}

- (NSString *)runSubagents:(NSDictionary *)args
{
    id raw = TBValue(args, @"tasks");
    NSMutableArray *jobs = [NSMutableArray array];
    NSMutableString *out = [NSMutableString string];
    NSArray *choices = nil;
    int limit = concurrency(), started = 0, active, i;
    NSException *stopped = nil;
    if (subPrefix)
        TBFail(@"A subagent cannot start subagents.");
    if (![raw isKindOfClass:[NSArray class]] || ![raw count])
        TBFail(@"Give a list of tasks.");
    if ([raw count] > SUB_MAX_TASKS)
        TBFail(@"At most %d tasks at a time.", SUB_MAX_TASKS);
    for (i = 0; i < (int)[raw count]; i++) {
        id item = [raw objectAtIndex:i];
        NSString *task = [item isKindOfClass:[NSDictionary class]] ? TBString(item, @"task") : ([item isKindOfClass:[NSString class]] ? item : nil);
        NSString *spec = [item isKindOfClass:[NSDictionary class]] ? TBString(item, @"model") : @"";
        TBSubJob *job = [[[TBSubJob alloc] init] autorelease];
        if ([TBTrim(task) length] == 0)
            TBFail(@"Task %d is empty.", i + 1);
        job->parent = self;
        job->index = i;
        job->task = [task copy];
        job->provider = [turnProvider copy];
        job->model = [turnModel copy];
        if ([spec length]) {
            NSRange slash = [spec rangeOfString:@"/"];
            NSString *p = [TBProviders normalize:slash.location == NSNotFound ? spec : [spec substringToIndex:slash.location]];
            NSString *m = slash.location == NSNotFound ? nil : [spec substringFromIndex:slash.location + 1];
            unsigned c;
            BOOL ok = NO;
            if (!choices)
                choices = [self consultChoices];
            for (c = 0; c < [choices count]; c++)
                if ([TBString([choices objectAtIndex:c], @"provider") isEqualToString:p] && (![m length] || [TBString([choices objectAtIndex:c], @"model") isEqualToString:m]))
                    ok = YES;
            if (!ok)
                TBFail(@"%@ is not an available model for a subagent.", spec);
            [job->provider release];
            job->provider = [p copy];
            [job->model release];
            job->model = [[TBProviders resolveModel:[m length] ? m : nil provider:p] copy];
        }
        job->sink = [[TBSubSink alloc] initWithParent:self index:i];
        [jobs addObject:job];
    }
    for (;;) {
        int finished = 0;
        active = 0;
        for (i = 0; i < (int)[jobs count]; i++) {
            TBSubJob *job = [jobs objectAtIndex:i];
            if (i >= started)
                continue;
            if ([job finished]) finished++; else active++;
        }
        if (finished == (int)[jobs count])
            break;
        if (!stopped) {
            @try { [run check]; } @catch (NSException *e) { stopped = [e retain]; }
        }
        while (!stopped && active < limit && started < (int)[jobs count]) {
            [NSThread detachNewThreadSelector:@selector(work:) toTarget:[jobs objectAtIndex:started] withObject:nil];
            started++;
            active++;
        }
        if (stopped && started < (int)[jobs count]) {
            /* never started: count them as finished */
            for (i = started; i < (int)[jobs count]; i++)
                ((TBSubJob *)[jobs objectAtIndex:i])->done = YES;
            started = (int)[jobs count];
        }
        usleep(100000);
    }
    if (stopped)
        @throw [stopped autorelease];
    for (i = 0; i < (int)[jobs count]; i++) {
        TBSubJob *job = [jobs objectAtIndex:i];
        NSString *answer = [TBTrim([job->sink answer]) length] ? TBTrim([job->sink answer]) : @"(no answer)";
        if ([answer length] > SUB_ANSWER_LIMIT)
            answer = [[answer substringToIndex:SUB_ANSWER_LIMIT] stringByAppendingString:@"\n[cut off]"];
        [out appendFormat:@"%@### Subagent %d (%@/%@): %@\n%@%@\n", i ? @"\n" : @"", i + 1, job->provider, job->model,
            [job->task length] > 80 ? [[job->task substringToIndex:80] stringByAppendingString:@"..."] : job->task,
            job->failure ? [NSString stringWithFormat:@"It failed: %@\n", job->failure] : @"", answer];
    }
    return out;
}

@end
