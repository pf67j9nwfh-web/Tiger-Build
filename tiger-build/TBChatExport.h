#import <Foundation/Foundation.h>

/* A chat written in the formats other chat tools import:
     ChatGPT   a conversations.json like the one ChatGPT's data export makes (ChatGPT-style tools and LibreChat read it);
     Claude    a conversations.json like the one Claude's data export makes (LibreChat reads it);
     LibreChat the JSON that LibreChat itself exports.
   Only the words are carried: tool cards, status lines and attachments (named in the text) are left out. */
@interface TBChatExport : NSObject
+ (NSData *)chatGPTExportOfChat:(NSDictionary *)chat;
+ (NSData *)claudeExportOfChat:(NSDictionary *)chat;
+ (NSData *)libreChatExportOfChat:(NSDictionary *)chat;
+ (NSArray *)turnsOfChat:(NSDictionary *)chat;       /* {role: user|assistant, text} in order */
@end
