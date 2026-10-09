#import <Foundation/Foundation.h>
#import "TBProviders.h"
#import "TBMCP.h"
#import "TBRun.h"

/* One chat turn: the model, the tools it may use, and the loop between them. A port of the relay's ToolSession. It runs on a
   worker thread and reports what happens as frames, the same ones the relay streamed:
     t text   s status   a tool card (property list)   h thinking   m media   u usage (property list)
     q approval question (property list)   g guidance delivered   c context compacted */

@interface NSObject (TBSessionFrames)
- (void)session:(id)session frame:(NSString *)kind text:(NSString *)text;
@end

@interface TBSession : NSObject {
@public
    NSDictionary *options;           /* servers {name: BOOL}, approve {name: BOOL}, root, instructions */
    NSDictionary *client;            /* machine, os, user, home */
    TBRun *run;
    id frames;
    long long lastContext;
    NSMutableArray *side;            /* frames from helper calls (consulting, summaries) to send with the next real one */
    TBMCPClient *commander;
    NSString *sudoKey;               /* this Commander's key for the administrator password, if the chat has sudo ticked */
    NSString *offline;
    NSArray *commanderTools;
    NSString *grokKey;
    id extras;
    NSString *subPrefix;             /* set on a subagent: its tool call ids start with this so they cannot clash with the parent's */
    NSString *turnProvider;
    NSString *turnModel;
    NSMutableSet *alwaysAllowed;     /* tool keys the person chose "Always Allow" for during this turn */
}
+ (NSDictionary *)cleanOptions:(id)incoming;
+ (BOOL)supportsImages:(NSString *)provider model:(NSString *)model;
+ (NSString *)cleanText:(NSString *)text;
+ (NSString *)propertyListText:(NSDictionary *)dictionary;
+ (NSDictionary *)changeStatsForTool:(NSString *)name output:(NSString *)output;   /* files, added, removed, or nil */
- (id)initWithRun:(TBRun *)run options:(NSDictionary *)options frames:(id)sink;
- (void)setClientInfo:(id)info;
/* Runs the whole turn, blocking, sending frames. Raises TBError for a failure the person should be told. */
- (void)runTurn:(NSArray *)messages useTools:(BOOL)useTools provider:(NSString *)provider model:(NSString *)model;
- (void)closeTools;
@end

/* The bundled Commander program. */
NSString *TBCommanderProgram(void);

@interface TBSession (Commander)
/* After Commander is installed or changed: look at its tools again. */
+ (void)forgetCommanderTools;
/* What the last look at Commander found wrong, or "". */
+ (NSString *)cachedCommanderProblem;
@end

@interface TBSession (Subagents)
- (NSDictionary *)subagentDefinition;
- (NSString *)runSubagents:(NSDictionary *)args;
@end

@interface TBSession (Research)
/* A reply that may use web search and nothing else (no Commander, no other tools): notes on models. */
- (NSString *)researchProvider:(NSString *)provider model:(NSString *)model system:(NSString *)system prompt:(NSString *)prompt;
@end

@interface TBSession (Loop)
/* A plain reply with no tools: titles, summaries, a consulted model. */
- (NSString *)completeProvider:(NSString *)provider model:(NSString *)model system:(NSString *)system messages:(NSArray *)messages;
@end
