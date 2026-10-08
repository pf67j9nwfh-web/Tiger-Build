#import "ChatController_Private.h"

/* Several chats working at once, in one window. The reply that belongs to the chat on screen lives in the controller's own run variables (busy, localTurn,
   streamingId ...); a reply in a chat that is not on screen is parked in a slot, and the slot is swapped in for the moment its frames or its summary
   are handled, so the one-reply logic everywhere else stays as it is. Choosing another chat swaps the replies the same way. */

@interface TBRunSlot : NSObject
{
@public
    BOOL busy, stopping, compactForced, compactOnly;
    void *bodyStream;
    id localTurn;
    NSMutableData *frameBuffer;
    NSString *streamingId, *runId, *thinkingText;
    int streamDepth, streamEndDeferred;
    double lastFrame;
    NSMutableArray *queuedGuidance;
    EngineRequest *sideRequest;
}
@end

@implementation TBRunSlot
- (void)dealloc
{
    [localTurn release];
    [frameBuffer release];
    [streamingId release];
    [runId release];
    [thinkingText release];
    [queuedGuidance release];
    [super dealloc];
}
@end

@implementation ChatController (Runs)

/* the run variables out into a slot, leaving the controller idle */
- (TBRunSlot *)takeRun
{
    TBRunSlot *s = [[[TBRunSlot alloc] init] autorelease];
    s->busy = busy;
    s->stopping = stopping;
    s->compactForced = compactForced;
    s->compactOnly = compactOnly;
    s->bodyStream = bodyStream;
    s->localTurn = localTurn;
    s->frameBuffer = frameBuffer;
    s->streamingId = streamingId;
    s->runId = runId;
    s->thinkingText = thinkingText;
    s->streamDepth = streamDepth;
    s->streamEndDeferred = streamEndDeferred;
    s->lastFrame = lastFrame;
    s->queuedGuidance = queuedGuidance;
    s->sideRequest = sideRequest;
    busy = NO;
    stopping = NO;
    compactForced = NO;
    compactOnly = NO;
    bodyStream = NULL;
    localTurn = nil;
    frameBuffer = [[NSMutableData alloc] init];
    streamingId = nil;
    runId = nil;
    thinkingText = nil;
    streamDepth = 0;
    streamEndDeferred = 0;
    lastFrame = 0;
    queuedGuidance = [[NSMutableArray alloc] init];
    sideRequest = nil;
    return s;
}

/* a slot's run back into the controller (which must be idle) */
- (void)restoreRun:(TBRunSlot *)s
{
    [frameBuffer release];
    [queuedGuidance release];
    [streamingId release];
    [runId release];
    [thinkingText release];
    busy = s->busy;
    stopping = s->stopping;
    compactForced = s->compactForced;
    compactOnly = s->compactOnly;
    bodyStream = s->bodyStream;
    localTurn = s->localTurn;
    frameBuffer = s->frameBuffer;
    streamingId = s->streamingId;
    runId = s->runId;
    thinkingText = s->thinkingText;
    streamDepth = s->streamDepth;
    streamEndDeferred = s->streamEndDeferred;
    lastFrame = s->lastFrame;
    queuedGuidance = s->queuedGuidance;
    sideRequest = s->sideRequest;
    s->localTurn = nil;
    s->frameBuffer = nil;
    s->streamingId = nil;
    s->runId = nil;
    s->thinkingText = nil;
    s->queuedGuidance = nil;
}

- (BOOL)anyRunActive
{
    return busy || [parkedRuns count] > 0;
}

- (BOOL)chatHasParkedRun:(NSString *)chatId
{
    return chatId && [parkedRuns objectForKey:chatId] != nil;
}

/* The chat on screen is changing: its reply (if any) is parked, and the new chat's reply (if it has one) comes in. */
- (void)switchRunsToChat:(NSDictionary *)chat
{
    NSString *newId = [chat objectForKey:@"id"];
    TBRunSlot *waiting;
    if (swapped || !chat)
        return;
    if (busy && streamingId && ![streamingId isEqualToString:newId]) {
        NSString *key = [[streamingId copy] autorelease];
        if (!parkedRuns)
            parkedRuns = [[NSMutableDictionary alloc] init];
        [parkedRuns setObject:[self takeRun] forKey:key];
    }
    waiting = newId ? [parkedRuns objectForKey:newId] : nil;
    if (waiting && !busy) {
        [self restoreRun:waiting];
        [parkedRuns removeObjectForKey:newId];
    }
}

/* Swaps in the parked reply that a message is about (by its turn, or by its chat). NO when it is the one on screen or none. */
- (BOOL)enterRunOfTurn:(id)turn orChat:(NSString *)chatId
{
    NSEnumerator *keys = [[parkedRuns allKeys] objectEnumerator];
    NSString *key;
    TBRunSlot *found = nil;
    if (swapped)
        return NO;
    while ((key = [keys nextObject])) {
        TBRunSlot *s = [parkedRuns objectForKey:key];
        if ((turn && s->localTurn == turn) || (chatId && [key isEqualToString:chatId])) {
            found = s;
            break;
        }
    }
    if (!found)
        return NO;
    swappedKey = [key copy];
    displacedRun = [[self takeRun] retain];
    [[found retain] autorelease];
    [parkedRuns removeObjectForKey:swappedKey];
    [self restoreRun:found];
    swapped = YES;
    return YES;
}

/* The swapped-in reply goes back to its slot (or is dropped when it has finished) and the screen's own reply returns. */
- (void)leaveRun
{
    TBRunSlot *left;
    if (!swapped)
        return;
    left = [self takeRun];
    if (left->busy || left->localTurn || left->sideRequest)
        [parkedRuns setObject:left forKey:swappedKey];
    [self restoreRun:displacedRun];
    [displacedRun release];
    displacedRun = nil;
    [swappedKey release];
    swappedKey = nil;
    swapped = NO;
    [self applyBusyUI];
}

/* Every reply that is not on screen stops (a window closing, the application quitting). */
- (void)stopParkedRuns
{
    NSEnumerator *keys = [[parkedRuns allKeys] objectEnumerator];
    NSString *key;
    while ((key = [keys nextObject])) {
        TBRunSlot *s = [parkedRuns objectForKey:key];
        [s->localTurn cancel];
        [s->sideRequest cancel];
        [parkedRuns removeObjectForKey:key];
    }
}

@end
