#import <Cocoa/Cocoa.h>
#import "TBCompat.h"

@interface TranscriptView : NSView {
    NSArray *messages;
    float layoutWidth;
    float visibleHeight;
    NSMutableArray *boxes;
    NSDictionary *bodyAttrs;
    NSDictionary *userAttrs;
    NSDictionary *statusAttrs;
    NSMutableArray *movieViews;
    NSMutableArray *moviePaths;
    NSMutableDictionary *imageCache;
    NSMutableArray *textViews;
    NSMutableDictionary *sizeCache;
    NSMutableDictionary *richCache;
    NSString *copiedKey;
    BOOL forceTextReset;
    id dropTarget;
}

+ (NSColor *)backgroundColor;
/* How large the text in chats is drawn: 1.0 is the normal size. Kept in the preferences and shared by every window. */
+ (float)textScale;
+ (void)setTextScale:(float)scale;
- (void)setMessages:(NSArray *)newMessages;
- (void)layoutForWidth:(float)width visibleHeight:(float)visible;
- (void)scrollToEnd;
- (void)setActivitiesExpanded:(BOOL)expanded;
/* Files dropped on the chat are handed to the target's attachPaths:. */
- (void)setDropTarget:(id)target;
- (void)scrollToMessage:(id)message;

@end
