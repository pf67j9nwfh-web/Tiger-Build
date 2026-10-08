#import <Foundation/Foundation.h>

/* Estimated cost of a model call, from the community-maintained LiteLLM price list: a seed in the app, a copy kept in
   Application Support, and a refresh once a day in the background. An estimate from the token counts each service reports,
   not an invoice. Local models are free, so they have no cost (nil). */
@interface TBPricing : NSObject
+ (void)start;
/* usage: input (not from cache), cached, written, output. Dollars, or nil if the price is unknown. */
+ (NSNumber *)costForProvider:(NSString *)provider model:(NSString *)model usage:(NSDictionary *)usage;
/* A context size learned from the service for this model, or 0 to use the table. */
@end
