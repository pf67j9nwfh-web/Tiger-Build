#import <Cocoa/Cocoa.h>

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
}

- (void)setMessages:(NSArray *)newMessages;
- (void)layoutForWidth:(float)width visibleHeight:(float)visible;
- (void)scrollToEnd;

@end
