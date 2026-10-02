#import <Cocoa/Cocoa.h>
#import "TBCompat.h"

@class RelayRequest;

@interface ChatController : NSObject {
    NSWindow *window;
    NSPopUpButton *workspacePopup;
    NSView *content;
    NSTableView *table;
    NSScrollView *chatScroll;
    NSScrollView *transcriptScroll;
    NSButton *newButton;
    NSButton *deleteButton;
    NSPopUpButton *toolsPopup;
    NSButton *stopButton;
    NSButton *editButton;
    NSButton *retryButton;
    NSTextField *thinkingField;
    NSString *runId;
    NSMutableDictionary *workspaceSettings;
    NSArray *toolCatalog;
    NSString *commanderProblem;
    NSString *commanderCode;
    NSString *thinkingText;
    NSMutableArray *queuedGuidance;
    NSArray *editBackup;
    NSString *editedText;
    double lastFrame;
    double lastPaintRequest;
    BOOL stopping;
    BOOL paintScheduled;
    BOOL offeredSSH;
    int pulse;
    NSTimer *pulseTimer;
    RelayRequest *sideRequest;
    NSDictionary *commanderCache;
    BOOL commanderStatusPending;
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
    NSMutableDictionary *contextPending;
    BOOL storeDirty;
    NSTextField *relayStatusField;
    NSTimer *relayTimer;
    BOOL relayReachable;
    double lastCatalog;
}

- (void)setLaunchQuestion:(NSString *)text;
- (void)layoutSubviews;

@end
