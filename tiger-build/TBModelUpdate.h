#import <Foundation/Foundation.h>

@class TBSession;

/* Finds models the app does not ship with. For each service with a key it asks for the service's own list of models, keeps the ones that are chat models
   and not dated snapshots or previews, leaves out those already bundled, and tries each new one with a one-word question (a failure is not asked again for a week).
   The ones that answer are added to the model list (kept in model-live.plist, so they are there at the next start). */
@interface TBModelUpdate : NSObject
+ (NSString *)refreshWithSession:(TBSession *)session;                   /* a summary, one line per service */
+ (NSArray *)candidatesFromList:(id)json provider:(NSString *)provider;  /* {id, title} chat models in a service's reply (public for tests) */
@end
