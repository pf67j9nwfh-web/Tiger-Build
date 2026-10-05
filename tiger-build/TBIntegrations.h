#import <Foundation/Foundation.h>

/* The tool settings the relay kept in integrations.json: which tools are on, search, and the custom MCP servers.
   Servers (which can hold tokens) live in the Keychain; the rest in the preferences. */
@interface TBIntegrations : NSObject
+ (NSArray *)servers;                     /* [{id, title, command, args, env, enabled, approval}] */
+ (NSDictionary *)publicConfig;           /* what the settings window shows; the keys themselves are never sent */
+ (void)update:(NSDictionary *)incoming;  /* from the settings window; empty keys stay unless clear_* is set. Raises TBError. */
+ (NSDictionary *)exportConfig;           /* everything, keys included, for a backup */
+ (void)restore:(NSDictionary *)backup;   /* a backup, from here or from a 1.x relay; servers come back switched off */
+ (NSArray *)catalogue;                   /* the chat's tools menu: [{id, title, approval, default}] */
+ (void)installExamples;                  /* once: the calculator, notebook, system info and weather servers */
+ (BOOL)serverApprovalForKey:(NSString *)key;
@end
