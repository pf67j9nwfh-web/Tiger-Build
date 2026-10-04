#import <Foundation/Foundation.h>
#import "TBEngine.h"
#import "TBRun.h"

/* The model services: which there are, how to ask each one, and how to read its stream. A port of the relay's providers.py.
   One call to +streamRound is one request to a service; it reports text and thinking as they arrive and leaves the
   tool calls and the token counts in the TBRound. */

@interface TBRound : NSObject {
@public
    TBRun *run;
    NSMutableArray *calls;           /* {id, name, arguments (JSON text), thought_signature?} */
    NSArray *claudeBlocks;           /* Claude's own content blocks, to replay with the next request */
    BOOL truncated;
    BOOL noted;
    BOOL probe;
    BOOL spoke;                      /* anything was sent to the sink */
    NSMutableDictionary *usage;      /* input, cached, written, output */
    id sink;                         /* gets -round:text: and -round:thinking: */
}
- (void)addUsageInput:(long long)input cached:(long long)cached written:(long long)written output:(long long)output;
@end

@interface NSObject (TBRoundSink)
- (void)round:(TBRound *)round text:(NSString *)text;
- (void)round:(TBRound *)round thinking:(NSString *)text;
@end

@interface TBProviders : NSObject
+ (NSArray *)providers;                                   /* {id, title} in menu order */
+ (NSArray *)modelsForProvider:(NSString *)provider;      /* {id, title} */
+ (NSString *)defaultModelForProvider:(NSString *)provider;
+ (NSString *)normalize:(NSString *)name;                 /* "openai" -> "chatgpt"; fails on a name it does not know */
+ (NSString *)resolveModel:(NSString *)requested provider:(NSString *)provider;
+ (int)contextLimitForModel:(NSString *)model;
+ (void)setLiveModels:(NSArray *)ids forProvider:(NSString *)provider;
+ (NSString *)apiErrorText:(NSString *)detail code:(int)code;
+ (NSString *)localBase;                                  /* the local server's /v1 address, or "" */

@end

@interface TBProviders (Streaming)
+ (void)streamRound:(NSString *)provider system:(NSString *)system log:(NSArray *)log tools:(NSArray *)tools
              round:(TBRound *)round model:(NSString *)model;
@end

/* A conversation in the shapes each service wants. */
@interface TBProviders (Messages)
+ (NSArray *)openAIMessagesWithSystem:(NSString *)system log:(NSArray *)log;
+ (NSArray *)openAIResponsesInput:(NSArray *)log;
+ (NSArray *)ensureUserFirst:(NSArray *)log;
+ (NSArray *)qwenToolCalls:(NSString *)text;
@end

/* Hides <think> blocks and Qwen tool-call markup from the visible answer, keeping them for display and parsing. */
@interface TBAnswerStream : NSObject {
    NSMutableString *buf;
    NSMutableArray *visible;
    NSMutableArray *hidden;
    NSMutableArray *reasoning;
    NSMutableArray *toolMarkup;
    NSMutableArray *thoughts;
    NSString *hiding;
}
- (NSArray *)addContent:(NSString *)text;
- (void)addReasoning:(NSString *)text;
- (NSArray *)takeThoughts;
- (NSArray *)flush;
- (NSString *)finish;
- (NSArray *)toolMarkup;
- (NSArray *)reasoningPieces;
@end
