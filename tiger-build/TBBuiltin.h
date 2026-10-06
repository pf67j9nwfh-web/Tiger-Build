#import <Foundation/Foundation.h>
#import "TBRun.h"

/* The example MCP servers (calculator, notebook, system info, weather) built into the app, so they need no Python. They are
   listed in the settings as "builtin:calc" and so on, and speak the same way an outside server would. */
@interface TBBuiltin : NSObject
+ (BOOL)knows:(NSString *)name;                 /* "calc", "notes", "sysinfo", "weather" */
+ (NSDictionary *)listTools:(NSString *)name;   /* an MCP tools/list result */
/* The text a tool gives. Raises TBErrorException for a failure the model should see. */
+ (NSString *)call:(NSString *)tool arguments:(NSDictionary *)args server:(NSString *)name run:(TBRun *)run;
/* exposed for tests */
+ (NSString *)calculate:(NSString *)expression;
@end
