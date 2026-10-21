#import <Foundation/Foundation.h>

/* Spotlight search of the chats, off until it is switched on (Preferences, Privacy). One small property list per chat is kept in
   ~/Library/Application Support/Tiger Build/Spotlight/<workspace>/<chat number>.tbchat (title and text; no pictures, files or tool output),
   which the importer inside the app (TigerBuild.mdimporter, copied to ~/Library/Spotlight) reads; opening a result opens that chat. */
@interface TBSpotlight : NSObject
+ (void)start;      /* at launch: follows the chats being saved */
+ (BOOL)enabled;
/* Switching on installs the importer and writes every chat's file; off removes them. Returns nil, or what went wrong. */
+ (NSString *)setEnabled:(BOOL)on;
/* Called when a store (one workspace's chats) changed: its files are brought up to date a little later, once it has been quiet. */
+ (void)storeChanged:(id)store;
/* Writes the files of every workspace now. */
+ (void)rebuildAll;
/* The workspace and chat number a .tbchat file stands for. */
+ (BOOL)readChatFile:(NSString *)path workspace:(NSString **)workspace chatId:(NSString **)chatId;
@end
