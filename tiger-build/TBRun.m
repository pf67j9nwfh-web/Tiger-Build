#import "TBRun.h"
#include <sys/time.h>

NSString *TBStoppedException = @"TBStopped";

static NSMutableDictionary *runs = nil;

@implementation TBRun

+ (void)initialize
{
    if (!runs)
        runs = [[NSMutableDictionary alloc] init];
}

+ (TBRun *)runWithId:(NSString *)identifier
{
    TBRun *run = [[[TBRun alloc] init] autorelease];
    TBRun *old;
    run->runId = [identifier copy];
    run->guidance = [[NSMutableArray alloc] init];
    run->active = [[NSMutableArray alloc] init];
    run->answers = [[NSMutableDictionary alloc] init];
    pthread_mutex_init(&run->lock, NULL);
    pthread_cond_init(&run->changed, NULL);
    @synchronized(runs) {
        old = [[runs objectForKey:identifier] retain];
        [runs setObject:run forKey:identifier];
    }
    [old cancel];
    [old release];
    return run;
}

+ (TBRun *)runForId:(NSString *)identifier
{
    TBRun *run;
    @synchronized(runs) {
        run = [[[runs objectForKey:identifier] retain] autorelease];
    }
    return run;
}

+ (void)finish:(TBRun *)run
{
    @synchronized(runs) {
        if ([runs objectForKey:[run runId]] == run)
            [runs removeObjectForKey:[run runId]];
    }
    [run cancel];
}

- (void)dealloc
{
    [runId release];
    [guidance release];
    [active release];
    [answers release];
    pthread_mutex_destroy(&lock);
    pthread_cond_destroy(&changed);
    [super dealloc];
}

- (NSString *)runId
{
    return runId;
}

- (void)cancel
{
    NSArray *requests;
    pthread_mutex_lock(&lock);
    if (cancelled) {
        pthread_mutex_unlock(&lock);
        return;
    }
    cancelled = YES;
    requests = [NSArray arrayWithArray:active];
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&lock);
    [requests makeObjectsPerformSelector:@selector(cancel)];
}

- (BOOL)isCancelled
{
    BOOL value;
    pthread_mutex_lock(&lock);
    value = cancelled;
    pthread_mutex_unlock(&lock);
    return value;
}

- (void)check
{
    if ([self isCancelled])
        [NSException raise:TBStoppedException format:@"Stopped"];
}

- (void)attach:(id)http
{
    BOOL already;
    pthread_mutex_lock(&lock);
    already = cancelled;
    if (!already)
        [active addObject:http];
    pthread_mutex_unlock(&lock);
    if (already)
        [http cancel];
}

- (void)detach:(id)http
{
    pthread_mutex_lock(&lock);
    [active removeObject:http];
    pthread_mutex_unlock(&lock);
}

- (BOOL)addGuidance:(NSString *)text
{
    BOOL ok = NO;
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([text length] == 0)
        return NO;
    if ([text length] > 4000)
        text = [text substringToIndex:4000];
    pthread_mutex_lock(&lock);
    if ([guidance count] < 8) {
        [guidance addObject:text];
        ok = YES;
    }
    pthread_mutex_unlock(&lock);
    return ok;
}

- (NSArray *)takeGuidance
{
    NSArray *notes;
    pthread_mutex_lock(&lock);
    notes = [NSArray arrayWithArray:guidance];
    [guidance removeAllObjects];
    pthread_mutex_unlock(&lock);
    return notes;
}

- (void)ask:(NSString *)callId
{
    pthread_mutex_lock(&lock);
    [answers setObject:[NSNull null] forKey:callId];
    pthread_mutex_unlock(&lock);
}

- (BOOL)answer:(NSString *)callId decision:(NSString *)decision
{
    BOOL known;
    pthread_mutex_lock(&lock);
    known = [answers objectForKey:callId] != nil;
    if (known)
        [answers setObject:decision forKey:callId];
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&lock);
    return known;
}

- (NSString *)waitFor:(NSString *)callId
{
    struct timespec limit;
    struct timeval now;
    NSString *decision;
    gettimeofday(&now, NULL);
    limit.tv_sec = now.tv_sec + 600;
    limit.tv_nsec = 0;
    pthread_mutex_lock(&lock);
    if ([answers objectForKey:callId] == nil) {
        pthread_mutex_unlock(&lock);
        return @"deny";
    }
    while ([answers objectForKey:callId] == (id)[NSNull null] && !cancelled) {
        if (pthread_cond_timedwait(&changed, &lock, &limit) != 0)
            break;
    }
    /* keep it alive: the dictionary held the only reference, and removing the entry would free it */
    decision = [[[answers objectForKey:callId] retain] autorelease];
    [answers removeObjectForKey:callId];
    pthread_mutex_unlock(&lock);
    [self check];
    return ([decision isKindOfClass:[NSString class]] && ([decision isEqualToString:@"allow"] || [decision isEqualToString:@"always"])) ? decision : @"deny";
}

@end
