#import <Cocoa/Cocoa.h>

@interface ChatController : NSObject {
    NSWindow *window;
    NSView *content;
    NSTableView *table;
    NSScrollView *chatScroll;
    NSScrollView *transcriptScroll;
    NSButton *newButton;
    NSButton *deleteButton;
    NSButton *toolsButton;
    NSPopUpButton *modelPopup;
    NSPopUpButton *variantPopup;
    NSButton *sendButton;
    NSTextField *input;
    NSTextField *renameField;
    int renameRow;
    id transcript;
    NSMutableArray *chats;
    NSMutableDictionary *current;
    int nextNumber;
    BOOL suppressSelection;
    BOOL busy;
    void *bodyStream;
    double lastPaint;
    NSMutableData *frameBuffer;
    NSMutableData *errorBody;
    int httpStatus;
    NSString *streamingId;
    NSString *launchQuestion;
    NSTextField *contextField;
    NSSplitView *split;
    NSView *sidePane;
    NSView *chatPane;
    float sidebarWidth;
    float inputHeight;
    BOOL naming;
    NSMutableArray *localModels;
    NSMutableDictionary *prefsFields;
    NSWindow *prefsWindow;
}

- (void)setLaunchQuestion:(NSString *)text;
- (void)layoutSubviews;

@end
