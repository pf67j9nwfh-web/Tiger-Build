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
}

- (void)setMessages:(NSArray *)newMessages;
- (void)layoutForWidth:(float)width visibleHeight:(float)visible;
- (void)scrollToEnd;
- (void)setActivitiesExpanded:(BOOL)expanded;

@end
