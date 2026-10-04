#import <Foundation/Foundation.h>
#import "TBHTTP.h"
#include <pthread.h>

/* One chat turn that can be stopped, steered and asked about, as the relay's runs.py: Stop ends it at once (closing whatever
   connection is waiting), a note typed while the model works is held for the next safe moment, and a tool that needs the
   person's say-so waits on their answer. Held in memory and dropped when the turn ends. */

extern NSString *TBStoppedException;

@interface TBRun : NSObject {
    NSString *runId;
    BOOL cancelled;
    NSMutableArray *guidance;
    NSMutableArray *active;          /* TBHTTP objects to cancel on Stop */
    NSMutableDictionary *answers;
    pthread_mutex_t lock;
    pthread_cond_t changed;
}
+ (TBRun *)runWithId:(NSString *)identifier;
+ (TBRun *)runForId:(NSString *)identifier;
+ (void)finish:(TBRun *)run;
- (NSString *)runId;
- (void)cancel;
- (BOOL)isCancelled;
/* Raises TBStoppedException when stopped. */
- (void)check;
/* Anything with -cancel (a request, a tool process) that Stop should end. */
- (void)attach:(id)http;
- (void)detach:(id)http;
- (BOOL)addGuidance:(NSString *)text;
- (NSArray *)takeGuidance;
/* The person's answer to a question: "allow", "deny" or "always". */
- (void)ask:(NSString *)callId;
- (BOOL)answer:(NSString *)callId decision:(NSString *)decision;
- (NSString *)waitFor:(NSString *)callId;
@end
