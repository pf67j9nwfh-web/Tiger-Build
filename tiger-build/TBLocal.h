#import <Foundation/Foundation.h>

/* A model server on this network that speaks the OpenAI chat protocol: LM Studio, Ollama and the like. */
@interface TBLocal : NSObject
/* [{id, context, title}] without embedding models. Raises TBError if the server cannot be reached. */
+ (NSArray *)modelsWithTimeout:(double)seconds;
/* The same cached for half a minute; empty if the server cannot be reached. */
+ (NSArray *)cachedModels;
/* "id<TAB>context<TAB>title" lines, or "error<TAB>message". */
+ (NSString *)modelsText;
/* unset, "ok N", empty or offline. */
+ (NSString *)status;
+ (int)contextForModel:(NSString *)model;
@end
