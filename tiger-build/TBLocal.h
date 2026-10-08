#import <Foundation/Foundation.h>

/* A model server on this network that speaks the OpenAI chat protocol: LM Studio, Ollama and the like. */
@interface TBLocal : NSObject
/* [{id, context, title}] without embedding models. Raises TBError if the server cannot be reached. */
+ (NSArray *)modelsWithTimeout:(double)seconds;
+ (NSArray *)openRouterModelsWithTimeout:(double)seconds base:(NSString *)base;
/* The same cached for half a minute; empty if the server cannot be reached. */
+ (NSArray *)cachedModels;
/* "id<TAB>context<TAB>title" lines, or "error<TAB>message". */
+ (NSString *)modelsText;
/* unset, "ok N", empty or offline. */
+ (NSString *)status;
+ (int)contextForModel:(NSString *)model;
/* OpenRouter lists what each model costs: {prompt, completion} in dollars per token, or nil (any other server, or a model it does not list) */
+ (NSDictionary *)pricesForModel:(NSString *)model;
@end
