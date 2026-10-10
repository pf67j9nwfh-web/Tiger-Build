#import "TBSession.h"
#import "TBEngine.h"
#import "TBJSON.h"
#import "TBModelProfiles.h"
#import "TBPricing.h"
#import <unistd.h>

/* Subagents: the run_subagents tool starts one TBSession per task, each on its own thread with its own tools, and returns every answer.
   A subagent shares the parent's Stop button and approvals (its tool calls ask the person like any other), cannot start subagents of its own,
   and has no administrator or screen control. Tool-call cards and usage lines flow into the parent's chat. */

#define SUB_ANSWER_LIMIT 12000

@interface TBSession (SubagentNeeds)
- (void)emit:(NSString *)kind text:(NSString *)text;
- (void)turn:(NSArray *)incoming useTools:(BOOL)useTools provider:(NSString *)provider model:(NSString *)requested systemOverride:(NSString *)override;
- (NSArray *)consultChoices;
@end

static NSString *const kSubTool = @"run_subagents";

@class TBSubJob;
static void noteCard(TBSubJob *job, NSString *text);

@interface TBSubSink : NSObject {
    TBSession *parent;
    int index;
    NSMutableString *answer;
    TBSubJob *job;                   /* not retained: the job owns the sink */
}
- (id)initWithParent:(TBSession *)parent index:(int)index job:(TBSubJob *)job;
- (NSString *)answer;
@end

@implementation TBSubSink

- (id)initWithParent:(TBSession *)p index:(int)i job:(TBSubJob *)j
{
    self = [super init];
    parent = p;
    index = i;
    job = j;
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
    NSString *copy;
    @synchronized(self) { copy = [[answer copy] autorelease]; }
    return copy;
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
    if ([kind isEqualToString:@"a"])
        noteCard(job, text);
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
    BOOL done, started;
    int steps;                       /* tool calls finished so far */
    NSString *lastTool;              /* the tool it is on now */
    NSDate *startedAt, *finishedAt;
}
- (void)work:(id)unused;
@end

/* A tool card from a subagent, seen for progress: a call that starts is the tool it is on, one that finishes is a step. */
static void noteCard(TBSubJob *job, NSString *text)
{
    NSString *problem = nil;
    NSDictionary *event = [NSPropertyListSerialization propertyListFromData:[text dataUsingEncoding:NSUTF8StringEncoding]
        mutabilityOption:NSPropertyListImmutable format:NULL errorDescription:&problem];
    if (!job || ![event isKindOfClass:[NSDictionary class]])
        return;
    @synchronized(job) {
        if ([[event objectForKey:@"phase"] isEqualToString:@"result"]) {
            job->steps++;
            [job->lastTool release];
            job->lastTool = nil;
        } else {
            [job->lastTool release];
            job->lastTool = [[event objectForKey:@"name"] copy];
        }
    }
}

@implementation TBSubJob

- (void)dealloc
{
    [task release]; [provider release]; [model release]; [sink release]; [failure release]; [lastTool release]; [startedAt release]; [finishedAt release];
    [super dealloc];
}

- (void)work:(id)unused
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    TBSession *sub = nil;
    (void)unused;
    @synchronized(self) { started = YES; startedAt = [[NSDate date] retain]; }
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
    @synchronized(self) { done = YES; finishedAt = [[NSDate date] retain]; }
    [pool release];
}

- (BOOL)finished
{
    BOOL value;
    @synchronized(self) { value = done; }
    return value;
}

@end

@implementation TBSession (Subagents)

static int cpuCount(void)
{
    int n = TBCPUCount();
    return n < 1 ? 1 : n;
}

static int settingNumber(NSString *name, int fallback, int low, int high)
{
    NSNumber *set = [[NSUserDefaults standardUserDefaults] objectForKey:[@"TBTool." stringByAppendingString:name]];
    int n = set ? [set intValue] : fallback;
    return n < low ? low : (n > high ? high : n);
}

/* How many run at once: the Mac's cores up to four, unless Preferences say otherwise. */
static int concurrency(void)
{
    return settingNumber(@"subagents_max", cpuCount() < 4 ? cpuCount() : 4, 1, 8);
}

/* How many tasks one run_subagents call may hold. */
static int maxTasks(void)
{
    return settingNumber(@"subagents_tasks", 8, 1, 16);
}

/* Which model a subagent runs on: "choose" (the model says, the chat's own by default), "same" (always the chat's), or "provider|model" (always that one). */
static NSString *policy(void)
{
    NSString *p = [[NSUserDefaults standardUserDefaults] stringForKey:@"TBTool.subagents_policy"];
    return [p length] ? p : @"choose";
}

/* The usable models, one line each with what is known about them, so the model can match a subtask to a model (a small fast one for simple work). */
- (NSString *)subagentModelListing
{
    NSArray *rows = [self consultChoices];
    NSMutableString *out = [NSMutableString string];
    unsigned i;
    for (i = 0; i < [rows count] && i < 40; i++) {
        NSString *p = TBString([rows objectAtIndex:i], @"provider"), *m = TBString([rows objectAtIndex:i], @"model");
        [out appendFormat:@"%@\n", [TBModelProfiles lineForProvider:p model:m title:TBString([rows objectAtIndex:i], @"title") vision:[TBSession supportsImages:p model:m]
            context:[TBProviders contextLimitForModel:m] price:[self millionTokenPriceForProvider:p model:m]]];
    }
    return out;
}

- (NSNumber *)millionTokenPriceForProvider:(NSString *)provider model:(NSString *)model
{
    return [TBPricing costForProvider:provider model:model usage:[NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:1000000], @"input", [NSNumber numberWithInt:1000000], @"output", nil]];
}

- (NSDictionary *)subagentDefinition
{
    BOOL choose = [policy() isEqualToString:@"choose"];
    NSMutableDictionary *taskProps = [NSMutableDictionary dictionaryWithObject:
        [NSDictionary dictionaryWithObjectsAndKeys:@"string", @"type", @"The whole job for this helper, with everything it needs: it cannot see this chat.", @"description", nil] forKey:@"task"];
    NSMutableString *description = [NSMutableString stringWithFormat:@"Run up to %d helpers (subagents) at the same time, each on its own task, and get all their answers back. "
        "They have the same tools as you, work independently and cannot see this chat. This Mac runs %d at once; the rest wait their turn. "
        "Use it for work that splits into independent parts.", maxTasks(), concurrency()];
    if (choose) {
        NSString *listing = [self subagentModelListing];
        [taskProps setObject:[NSDictionary dictionaryWithObjectsAndKeys:@"string", @"type", @"Optional provider/model from the list in the tool description. Blank means the model of this chat.", @"description", nil] forKey:@"model"];
        [description appendFormat:@" You may give each task its own model. Match the model to the task: a small, fast, inexpensive model for simple, mechanical or narrow work (searching, "
            "extracting, summarizing, checking), and keep your own model or a stronger one for hard reasoning. The cost of every helper counts toward the chat. Models (provider|model|notes):\n%@", listing];
    } else if (![policy() isEqualToString:@"same"])
        [description appendFormat:@" Every helper runs on %@.", [[policy() componentsSeparatedByString:@"|"] componentsJoinedByString:@"/"]];
    else
        [description appendString:@" Every helper runs on the same model as this chat."];
    return [NSDictionary dictionaryWithObjectsAndKeys:@"function", @"type", kSubTool, @"name", description, @"description",
        [NSDictionary dictionaryWithObjectsAndKeys:@"object", @"type",
            [NSDictionary dictionaryWithObjectsAndKeys:
                [NSDictionary dictionaryWithObjectsAndKeys:@"array", @"type",
                    [NSDictionary dictionaryWithObjectsAndKeys:@"object", @"type", taskProps, @"properties", [NSArray arrayWithObject:@"task"], @"required", nil], @"items",
                    @"The tasks, one per helper.", @"description", nil], @"tasks", nil], @"properties",
            [NSArray arrayWithObject:@"tasks"], @"required", nil], @"parameters", nil];
}

/* The progress card: each helper's model, state, steps and what it is doing. */
- (NSString *)subagentProgressForJobs:(NSArray *)jobs
{
    NSMutableString *out = [NSMutableString string];
    unsigned i;
    int doneCount = 0;
    for (i = 0; i < [jobs count]; i++) {
        TBSubJob *job = [jobs objectAtIndex:i];
        NSString *state;
        @synchronized(job) {
            if (job->done) {
                state = job->failure ? [NSString stringWithFormat:@"failed (%@)", job->failure]
                    : [NSString stringWithFormat:@"done, %d step%@, %.0fs", job->steps, job->steps == 1 ? @"" : @"s", [job->finishedAt timeIntervalSinceDate:job->startedAt]];
                doneCount++;
            } else if (job->started)
                state = [NSString stringWithFormat:@"working, %d step%@%@%@", job->steps, job->steps == 1 ? @"" : @"s", job->lastTool ? @", now " : @"", job->lastTool ? job->lastTool : @""];
            else
                state = @"waiting for a free core";
        }
        [out appendFormat:@"%d. %@/%@ - %@\n   %@\n", i + 1, job->provider, job->model, state,
            [job->task length] > 100 ? [[job->task substringToIndex:100] stringByAppendingString:@"..."] : job->task];
    }
    return [NSString stringWithFormat:@"%d of %d done\n\n%@", doneCount, (int)[jobs count], out];
}

- (void)emitSubagentProgress:(NSArray *)jobs
{
    NSString *text = [self subagentProgressForJobs:jobs];
    NSArray *lines = [text componentsSeparatedByString:@"\n"];
    NSMutableDictionary *event;
    if (![subCallId length])
        return;
    event = [NSMutableDictionary dictionaryWithObjectsAndKeys:subCallId, @"id", kSubTool, @"name", @"start", @"phase", @"", @"detail", text, @"output",
        [NSNumber numberWithBool:NO], @"failed", [NSNumber numberWithDouble:0], @"elapsed", [lines objectAtIndex:0], @"label", nil];
    [self emit:@"a" text:[TBSession propertyListText:event]];
}

- (NSString *)runSubagents:(NSDictionary *)args
{
    id raw = TBValue(args, @"tasks");
    NSMutableArray *jobs = [NSMutableArray array];
    NSMutableString *out = [NSMutableString string];
    NSArray *choices = nil;
    NSString *rule = policy();
    int limit = concurrency(), started = 0, active, i;
    NSException *stopped = nil;
    NSDate *lastEmit = nil;
    NSString *lastText = nil;
    if (subPrefix)
        TBFail(@"A subagent cannot start subagents.");
    if (![raw isKindOfClass:[NSArray class]] || ![raw count])
        TBFail(@"Give a list of tasks.");
    if ((int)[raw count] > maxTasks())
        TBFail(@"At most %d tasks at a time (that is the limit set in Preferences).", maxTasks());
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
        if ([rule rangeOfString:@"|"].location != NSNotFound)
            spec = [[rule componentsSeparatedByString:@"|"] componentsJoinedByString:@"/"];   /* fixed by Preferences */
        else if (![rule isEqualToString:@"choose"])
            spec = @"";
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
        job->sink = [[TBSubSink alloc] initWithParent:self index:i job:job];
        [jobs addObject:job];
    }
    [self emitSubagentProgress:jobs];
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
        /* progress, when something changed, at most twice a second */
        if (!stopped && (!lastEmit || -[lastEmit timeIntervalSinceNow] > 0.5)) {
            NSString *now = [self subagentProgressForJobs:jobs];
            if (![now isEqualToString:lastText]) {
                [self emitSubagentProgress:jobs];
                [lastText release];
                lastText = [now retain];
            }
            [lastEmit release];
            lastEmit = [[NSDate date] retain];
        }
        usleep(100000);
    }
    [lastText release];
    [lastEmit release];
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
