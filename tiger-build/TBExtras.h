#import <Foundation/Foundation.h>
#import "TBRun.h"

/* What a chat turn can use beyond Commander: the agent toolbox (save a file, notes, the time), web and picture search,
   showing a picture, and the custom MCP servers (programs on this Mac, HTTP or HTTPS addresses, and the built-in examples). */
@interface TBExtras : NSObject {
    TBRun *run;
    NSMutableDictionary *clients;   /* server id -> client */
    NSMutableDictionary *routes;    /* tool alias -> [server id, original name] */
    NSMutableDictionary *owners;    /* tool name -> the chat's key for it ("toolbox", "search", "mcp_<id>") */
    NSMutableSet *offered;
    NSMutableArray *errors;
    NSString *lastProvider;         /* the provider of the latest request, for tools that work differently for one */
}
- (id)initWithRun:(TBRun *)run;
/* The tools to offer. skip holds the keys the chat turned off. */
- (NSArray *)definitionsForProvider:(NSString *)provider skip:(NSSet *)skip;
- (BOOL)handles:(NSString *)name;
- (NSString *)ownerOf:(NSString *)name;
/* {output, failed, media (optional)} */
- (NSDictionary *)call:(NSString *)name arguments:(NSDictionary *)args;
- (NSArray *)errors;
- (void)close;
@end
