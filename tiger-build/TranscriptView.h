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
    NSDictionary *toolAttrs;
    NSMutableArray *movieViews;
    NSMutableArray *moviePaths;
    NSMutableDictionary *imageCache;
    NSMutableArray *textViews;
    NSMutableDictionary *sizeCache;
    NSMutableDictionary *richCache;
    NSString *copiedKey;
    BOOL forceTextReset;
    id dropTarget;
    int typingPhase;
    NSTimer *typingTimer;
}

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

/* The sample in the Appearance panel: the backdrop with a bubble from you, one from the model and the typing cloud. */
@interface TBThemePreview : NSView
@end

/* A chat title with its emoji as pictures, for the chat list; nil when it has none (or the system draws emoji itself). */
NSAttributedString *TBEmojiTitle(NSString *text, NSFont *font);

/* A sample of tool-card text (mode 0) or status text (mode 1) on the chat background, for the Appearance tabs. */
@interface TBThemeSampleView : NSView {
    int mode;
}
- (id)initWithFrame:(NSRect)frame mode:(int)which;
@end
