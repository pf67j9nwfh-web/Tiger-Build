#import <Cocoa/Cocoa.h>
#import "TBCompat.h"

@class EngineRequest;
@class TBStore;

@interface ChatController : NSObject TB_PROTOCOLS(NSApplicationDelegate, NSWindowDelegate, NSSplitViewDelegate, NSTableViewDataSource,
    NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate, NSSpeechRecognizerDelegate) {
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
    NSButton *attachButton;
    NSMutableArray *attachQueue;
    EngineRequest *attachRequest;
    int attachGeneration;
    NSTextView *fieldEditor;
    id finder;
    unsigned long dictationDevice;
    unsigned long dictationRate;
    double dictationStarted;
    NSTimer *dictationTimer;
    EngineRequest *dictationRequest;
    NSString *dictationSaved;
    NSSpeechSynthesizer *voiceSynth;
    NSSpeechSynthesizer *voiceSample;
    NSSpeechRecognizer *voiceRecognizer;
    NSPopUpButton *voicePopup;
    double lastPartialSave;
    NSMutableArray *attachProblems;
    BOOL attachWorking;
    NSTextField *thinkingField;
    NSString *runId;
    NSMutableDictionary *workspaceSettings;
    NSArray *toolCatalog;
    NSString *commanderProblem;
    NSString *commanderCode;
    NSString *launchScreen;
    int launchWaits;
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
    EngineRequest *sideRequest;
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
    TBStore *store;
    NSString *workspaceChoice;
    int streamDepth;
    int streamEndDeferred;
    BOOL compactForced;
    BOOL compactOnly;
    BOOL layingOut;
    BOOL suppressSelection;
    BOOL busy;
    void *bodyStream;
    id localTurn;                 /* the built-in engine's turn, when there is one (bodyStream then marks it) */
    double lastPaint;
    NSMutableData *frameBuffer;
    NSString *streamingId;
    NSString *launchQuestion;
    NSTextField *contextField;
    NSSplitView *split;
    NSView *sidePane;
    NSView *chatPane;
    float sidebarWidth;
    BOOL sidebarHidden;              /* the chat list is folded away (Window menu, Command-backslash) */
    float inputHeight;
    BOOL naming;
    NSMutableArray *localModels;
    NSMutableDictionary *prefsFields;
    NSWindow *prefsWindow;
    NSMutableDictionary *contextPending;
    NSTextField *relayStatusField;
    NSTimer *relayTimer;
    BOOL relayReachable;
    double lastCatalog;
    NSMutableDictionary *parkedRuns;    /* chat id -> TBRunSlot: replies still working in chats that are not on screen */
    id displacedRun;                    /* while such a reply is handled, the run that is on screen waits here */
    NSString *swappedKey;
    BOOL swapped;
    BOOL updateChecking;
    BOOL memoryBusy;
    NSMenu *promptsMenu;
    NSMutableArray *promptsEditing;
    int promptsAt;
    NSPopUpButton *promptsList, *promptsDays, *compareProvider, *compareModel;
    NSTextField *promptsName, *promptsHour, *promptsMinute;
    NSTextView *promptsText;
    NSButton *promptsRun;
    NSTimer *schedulerTimer, *lockTimer;
    BOOL quickAskOpen, locked;
    NSMutableArray *lockCovers;
    void *hotKeyRef;
    double lastActivity;
    NSMutableDictionary *uiOriginals;   /* each control's own font, so Appearance can put it back */
}

- (void)setLaunchQuestion:(NSString *)text;
- (void)setLaunchScreen:(NSString *)spec;
- (void)layoutSubviews;

@end
