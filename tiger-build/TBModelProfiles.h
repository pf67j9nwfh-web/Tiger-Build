#import <Foundation/Foundation.h>

/* What auto mode knows about each model, so that its choice can use the whole list and still be quick. Each model gets a line made at once from facts
   the app already has (its name, whether it sees pictures, its context size, its price) plus a short note kept in a file in Application Support. The notes are
   written in the background, now and then, by the model the person picked for auto mode (which may search the web); choosing never waits for them. */
@interface TBModelProfiles : NSObject
+ (NSString *)factsForProvider:(NSString *)provider model:(NSString *)model title:(NSString *)title vision:(BOOL)vision context:(int)context price:(NSNumber *)price;
+ (NSString *)lineForProvider:(NSString *)provider model:(NSString *)model title:(NSString *)title vision:(BOOL)vision context:(int)context price:(NSNumber *)price;
+ (NSString *)noteForKey:(NSString *)key;                   /* "provider|model" */
+ (NSArray *)keysNeedingNotes:(NSArray *)keys;              /* those with no note and not tried in the last week */
+ (void)storeReply:(NSString *)reply asked:(NSArray *)keys; /* "provider|model|note" lines; asked models with no line are marked tried */
+ (NSString *)notesPath;
+ (double)lastRefresh;
+ (void)setLastRefresh:(double)when;
@end
