#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "TBRun.h"

/* The built-in "web" server (curl: fetch any address, with a method, headers and a body) and the "xposts" server (a post on X, with its
   pictures and video, and a drawn copy of the post). A call returns {output, media}; media is lines of "image NAME", "video NAME",
   "file NAME" or "tweet ID DATA" (the post as base64 JSON; then "image NAME tweet" and "tweetvideo NAME tweet" belong to that post's bubble) for the chat to show. Raises TBErrorException for a failure the model should see. */

@interface TBWebTools : NSObject
+ (BOOL)knows:(NSString *)server;
+ (NSDictionary *)call:(NSString *)tool arguments:(NSDictionary *)args server:(NSString *)server run:(TBRun *)run;
/* exposed for tests */
+ (NSDictionary *)postFromSyndication:(id)json;
+ (NSData *)collagePNGForPhotos:(NSArray *)photoData video:(NSDictionary *)video;
+ (NSData *)avatarJPEG:(NSData *)data;
+ (NSString *)postIdFrom:(NSString *)text;
+ (NSData *)playableVideo:(NSData *)mp4;
@end

/* what the chat draws for a post: counts as text ("3.2K"), the age ("17m"), the icons (0 reply, 1 repost, 2 like, 3 views, 4 share) and the verified badge */
NSString *TBTweetCount(double n);
NSString *TBTweetAge(NSDate *date);
void TBDrawTweetIcon(int kind, NSRect rect, NSColor *color);
void TBDrawTweetBadge(NSPoint center);
