#import "ChatController_Private.h"
#import "TranscriptView.h"
#import <CoreServices/CoreServices.h>

static BOOL nextWindowIsExtra = NO;
static unsigned extraWindowCount = 0;
static NSMutableArray *extraWindows = nil;

@interface NSApplication (TigerBuildAppleMenu)
- (void)setAppleMenu:(NSMenu *)aMenu;
@end
#import <stdio.h>
#import <string.h>
#import <stdlib.h>

@interface ChatController (Stream)
- (void)handleStream:(CFReadStreamRef)stream event:(CFStreamEventType)type;
- (void)closeStream;
- (void)drainFrames;
- (void)finishStream;
- (void)syncModelMenu;
- (void)focusInputIfNotEditing;
- (void)cancelPendingInputFocus;
- (void)beginRenameForRow:(int)row;
- (void)placeRenameField;
- (float)clampedSidebar:(float)proposed;
- (float)inputHeightForWidth:(float)width;
- (void)fitFieldEditor;
- (void)layoutPanes;
- (void)updateContextReadout;
- (BOOL)startCompactionIfNeeded;
- (void)beginChatStream;
- (void)autonameChat:(NSMutableDictionary *)chat;
- (void)attachMedia:(NSString *)line toChat:(NSMutableDictionary *)chat;
- (void)fillProviderMenu:(NSMenu *)menu;
- (void)fillProviderPopup;
- (NSMenu *)modelMenu;
- (NSString *)providerForChat:(NSDictionary *)chat;
- (NSString *)defaultModelForProvider:(NSString *)provider;
@end

static int streamDepth = 0;
static int streamEndDeferred = 0;

static void streamCallback(CFReadStreamRef stream, CFStreamEventType type, void *info)
{
    [(ChatController *)info handleStream:stream event:type];
}

@interface MetalContent : NSView {
    ChatController *controller;
}
- (void)setController:(ChatController *)owner;
@end

@implementation MetalContent

- (void)setController:(ChatController *)owner
{
    controller = owner;
}

- (BOOL)isOpaque
{
    return NO;
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize
{
    (void)oldSize;
    [controller layoutSubviews];
}

@end

@interface ChatListTable : NSTableView {
    ChatController *owner;
}
- (void)setOwner:(ChatController *)controller;
@end

@implementation ChatListTable

- (void)setOwner:(ChatController *)controller
{
    owner = controller;
}

- (void)mouseDown:(NSEvent *)event
{
    NSPoint point;
    int row;
    if ([event clickCount] > 1) {
        point = [self convertPoint:[event locationInWindow] fromView:nil];
        row = [self rowAtPoint:point];
        [owner beginRenameForRow:row];
        return;
    }
    [super mouseDown:event];
}

@end

@implementation ChatController

- (id)init
{
    self = [super init];
    if (!self)
        return nil;
    chats = [[NSMutableArray alloc] init];
    frameBuffer = [[NSMutableData alloc] init];
    errorBody = [[NSMutableData alloc] init];
    localModels = [[NSMutableArray alloc] init];
    prefsFields = [[NSMutableDictionary alloc] init];
    contextPending = [[NSMutableDictionary alloc] init];
    nextNumber = 1;
    renameRow = -1;
    sidebarWidth = [[NSUserDefaults standardUserDefaults] floatForKey:@"TigerBuildSidebarWidth"];
    if (sidebarWidth < 160)
        sidebarWidth = 176;
    inputHeight = TB_FIELD_MIN;
    return self;
}

- (void)dealloc
{
    [relayTimer invalidate];
    [relayTimer release];
    [self closeStream];
    [workspacePopup release];
    [window release];
    [split release];
    [sidePane release];
    [chatPane release];
    [table release];
    [chatScroll release];
    [transcriptScroll release];
    [transcript release];
    [newButton release];
    [deleteButton release];
    [toolsButton release];
    [modelPopup release];
    [variantPopup release];
    [sendButton release];
    [input release];
    [contextField release];
    [relayStatusField release];
    [renameField release];
    [chats release];
    [frameBuffer release];
    [errorBody release];
    [streamingId release];
    [launchQuestion release];
    [localModels release];
    [contextPending release];
    [prefsFields release];
    [prefsWindow release];
    [super dealloc];
}

- (void)setLaunchQuestion:(NSString *)text
{
    [launchQuestion release];
    launchQuestion = [text copy];
}

- (NSString *)supportDir
{
    return [RelayRequest supportDir];
}

- (NSString *)storePath
{
    NSString *name=[self workspaceName];
    if([name isEqualToString:@"Default"])return [[self supportDir] stringByAppendingPathComponent:@"chats.plist"];
    NSString *dir=[[self supportDir] stringByAppendingPathComponent:@"workspaces"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir attributes:nil];
    return [dir stringByAppendingPathComponent:[name stringByAppendingString:@".plist"]];
}

- (BOOL)providerUsable:(NSString *)provider
{
    if ([provider isEqualToString:@"local"])
        return [localModels count] > 0;
    return [[ModelCatalog shared] providerUsable:provider];
}

/* The first provider with a key and working models, then Local if it has
   models, then Grok so a brand-new install still shows something. */
- (NSString *)firstUsableProvider
{
    NSArray *providers = [[ModelCatalog shared] providers];
    unsigned i;
    for (i = 0; i < [providers count]; i++) {
        NSString *pid = [[providers objectAtIndex:i] objectForKey:@"id"];
        if ([self providerUsable:pid])
            return pid;
    }
    return @"grok";
}

/* A chat nobody has typed in yet follows the providers that work. */
- (BOOL)chatIsUntouched:(NSDictionary *)chat
{
    NSArray *messages = [chat objectForKey:@"messages"];
    unsigned i;
    for (i = 0; i < [messages count]; i++) {
        if ([[[messages objectAtIndex:i] objectForKey:@"role"] isEqualToString:@"user"])
            return NO;
    }
    return YES;
}

- (void)moveUntouchedChatsToUsableProvider
{
    unsigned i;
    NSString *provider = [self firstUsableProvider];
    for (i = 0; i < [chats count]; i++) {
        NSMutableDictionary *chat = [chats objectAtIndex:i];
        if (![self chatIsUntouched:chat] || [self providerUsable:[self providerForChat:chat]])
            continue;
        if (![self providerUsable:provider])
            continue;
        [chat setObject:provider forKey:@"provider"];
        [chat setObject:[self defaultModelForProvider:provider] forKey:@"model"];
        [chat removeObjectForKey:@"contextLimit"];
    }
}

- (NSMutableDictionary *)blankChat
{
    NSMutableDictionary *chat = [NSMutableDictionary dictionary];
    NSMutableDictionary *hello = [NSMutableDictionary dictionary];
    NSMutableArray *messages = [NSMutableArray array];
    [hello setObject:@"assistant" forKey:@"role"];
    [hello setObject:@"Hello. Ask me anything." forKey:@"text"];
    [hello setObject:[NSNumber numberWithBool:NO] forKey:@"status"];
    [messages addObject:hello];
    [chat setObject:[NSString stringWithFormat:@"%d", nextNumber] forKey:@"id"];
    nextNumber += 1;
    [chat setObject:@"New Chat" forKey:@"title"];
    [chat setObject:[NSNumber numberWithBool:YES] forKey:@"autoTitle"];
    [chat setObject:[NSNumber numberWithBool:YES] forKey:@"tools"];
    [chat setObject:[self firstUsableProvider] forKey:@"provider"];
    [chat setObject:[self defaultModelForProvider:[chat objectForKey:@"provider"]] forKey:@"model"];
    [chat setObject:messages forKey:@"messages"];
    return chat;
}

- (void)loadStore
{
    NSData *data = [NSData dataWithContentsOfFile:[self storePath]];
    NSString *error = nil;
    id root;
    NSArray *saved;
    unsigned i;
    int highest = 0;
    [chats removeAllObjects];
    if (data) {
        root = [NSPropertyListSerialization propertyListFromData:data
                                                mutabilityOption:NSPropertyListMutableContainers
                                                          format:NULL
                                                errorDescription:&error];
        if (error)
            [error release];
        if ([root isKindOfClass:[NSDictionary class]]) {
            saved = [root objectForKey:@"chats"];
            if ([saved isKindOfClass:[NSArray class]]) {
                for (i = 0; i < [saved count]; i++) {
                    NSArray *list = [[saved objectAtIndex:i] objectForKey:@"messages"];
                    unsigned j;
                    for (j = 0; j < [list count]; j++) {
                        [[list objectAtIndex:j] removeObjectForKey:@"pendingMedia"];
                        [[list objectAtIndex:j] removeObjectForKey:@"open"];
                    }
                    [chats addObject:[saved objectAtIndex:i]];
                }
            }
            highest = [[root objectForKey:@"next"] intValue];
        }
    }
    if (highest < 1) {
        for (i = 0; i < [chats count]; i++) {
            int number = [[[chats objectAtIndex:i] objectForKey:@"id"] intValue];
            if (number > highest)
                highest = number;
        }
    }
    nextNumber = highest + 1;
    if ([chats count] == 0)
        [chats addObject:[self blankChat]];
}

- (void)saveStore
{
    /* A streamed reply, a rename, and a model change can all arrive within a
       second. Write once they settle rather than rewriting the file each time. */
    if (storeDirty)
        return;
    storeDirty = YES;
    [self performSelector:@selector(flushStore) withObject:nil afterDelay:0.75];
}

- (void)flushStore
{
    NSMutableDictionary *root;
    NSString *error = nil;
    NSData *data;
    if (!storeDirty)
        return;
    storeDirty = NO;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(flushStore) object:nil];
    root = [NSMutableDictionary dictionary];
    [root setObject:chats forKey:@"chats"];
    [root setObject:[NSNumber numberWithInt:nextNumber] forKey:@"next"];
    /* Binary plists are about half the size of XML and much faster to write.
       loadStore reads either format. */
    data = [NSPropertyListSerialization dataFromPropertyList:root
                                                      format:NSPropertyListBinaryFormat_v1_0
                                            errorDescription:&error];
    if (error) {
        NSLog(@"Tiger Build could not save chats: %@", error);
        [error release];
    }
    if (data)
        [data writeToFile:[self storePath] atomically:YES];
}

- (void)applicationWillTerminate:(NSNotification *)note
{
    (void)note;
    [self flushStore];
}

- (BOOL)toolsEnabled:(NSDictionary *)chat
{
    id flag;
    if (!chat)
        return YES;
    flag = [chat objectForKey:@"tools"];
    if (!flag)
        return YES;
    return [flag boolValue];
}

- (void)syncToolsButton
{
    if ([self toolsEnabled:current])
        [toolsButton setTitle:@"Commander Chat Access: On"];
    else
        [toolsButton setTitle:@"Commander Chat Access: Off"];
}

- (void)showChatAtIndex:(int)index
{
    if (index < 0 || index >= (int)[chats count])
        return;
    current = [chats objectAtIndex:index];
    [self syncToolsButton];
    [self syncModelMenu];
    [transcript setMessages:[current objectForKey:@"messages"]];
    [transcript scrollToEnd];
    [self rememberContextLimit];
    [self updateContextReadout];
}

- (void)reloadTableSelect:(int)row show:(BOOL)show
{
    suppressSelection = YES;
    [table reloadData];
    if (row < 0)
        row = 0;
    if (row >= (int)[chats count])
        row = (int)[chats count] - 1;
    if (row >= 0)
        [table selectRow:row byExtendingSelection:NO];
    suppressSelection = NO;
    if (show)
        [self showChatAtIndex:row];
}

- (NSString *)serverBase
{
    return [RelayRequest serverBase];
}

- (void)buildWindow
{
    unsigned int mask = NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask | NSResizableWindowMask | NSTexturedBackgroundWindowMask;
    MetalContent *metal;
    NSTextField *label;
    NSTableColumn *column;
    NSFont *labelFont;

    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(40, 80, 860, 660)
                                         styleMask:mask
                                           backing:NSBackingStoreBuffered
                                             defer:NO];
    [window setTitle:@"Tiger Build"];
    [window setMinSize:NSMakeSize(680, 440)];
    [window setDelegate:self];
    if (nextWindowIsExtra) {
        extraWindowCount++;
        [window setFrameAutosaveName:[NSString stringWithFormat:@"Tiger Build %u", extraWindowCount + 1]];
    } else {
        [window setFrameAutosaveName:@"Tiger Build"];
    }
    [window setReleasedWhenClosed:NO];
    metal = [[MetalContent alloc] initWithFrame:[[window contentView] frame]];
    [metal setController:self];
    [metal setAutoresizesSubviews:YES];
    [window setContentView:metal];
    content = metal;
    [metal release];
    sidePane = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, sidebarWidth, 400)];
    chatPane = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 400)];
    split = [[NSSplitView alloc] initWithFrame:[content bounds]];
    [split setVertical:YES];
    [split setDelegate:self];
    [split addSubview:sidePane];
    [split addSubview:chatPane];
    [content addSubview:split];

    labelFont = [NSFont boldSystemFontOfSize:13];
    label = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
    [label setStringValue:@"Chats"];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [label setFont:labelFont];
    [sidePane addSubview:label];
    [label release];

    newButton = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
    [newButton setTitle:@"New Chat"];
    [newButton setBezelStyle:NSRoundedBezelStyle];
    [newButton setTarget:self];
    [newButton setAction:@selector(newChat:)];
    [sidePane addSubview:newButton];

    deleteButton = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
    [deleteButton setTitle:@"Delete"];
    [deleteButton setBezelStyle:NSRoundedBezelStyle];
    [deleteButton setTarget:self];
    [deleteButton setAction:@selector(deleteChat:)];
    [deleteButton setToolTip:@"Delete the selected chat"];
    [sidePane addSubview:deleteButton];

    chatScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
    [chatScroll setHasVerticalScroller:YES];
    [chatScroll setAutohidesScrollers:YES];
    [chatScroll setBorderType:NSBezelBorder];
    table = [[ChatListTable alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
    [(ChatListTable *)table setOwner:self];
    column = [[NSTableColumn alloc] initWithIdentifier:@"title"];
    [column setWidth:140];
    [column setEditable:NO];
    [[column headerCell] setStringValue:@"Chats"];
    [[column dataCell] setEditable:YES];
    [[column dataCell] setScrollable:YES];
    [[column dataCell] setTextColor:[NSColor blackColor]];
    [table addTableColumn:column];
    [column release];
    [table setHeaderView:nil];
    [table setCornerView:nil];
    [table setAllowsEmptySelection:NO];
    [table setDataSource:self];
    [table setDelegate:self];
    [table setRowHeight:20];
    [table setFont:[NSFont systemFontOfSize:13]];
    [table setToolTip:@"Double-click a chat to rename it."];
    [chatScroll setDocumentView:table];
    [sidePane addSubview:chatScroll];

    toolsButton = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
    [toolsButton setTitle:@"Commander Chat Access: On"];
    [toolsButton setBezelStyle:NSRoundedBezelStyle];
    [toolsButton setFont:[NSFont systemFontOfSize:11]];
    [toolsButton setTarget:self];
    [toolsButton setAction:@selector(toggleTools:)];
    [sidePane addSubview:toolsButton];

    modelPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 10, 10) pullsDown:NO];
    [modelPopup setTarget:self];
    [modelPopup setAction:@selector(chooseModel:)];
    [modelPopup setFont:[NSFont systemFontOfSize:13]];
    [self fillProviderPopup];
    [modelPopup setToolTip:@"Provider for this chat"];
    [sidePane addSubview:modelPopup];

    variantPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 10, 10) pullsDown:NO];
    [variantPopup setTarget:self];
    [variantPopup setAction:@selector(chooseVariant:)];
    [variantPopup setFont:[NSFont systemFontOfSize:13]];
    [variantPopup setToolTip:@"Version for this chat"];
    [sidePane addSubview:variantPopup];

    transcriptScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
    [transcriptScroll setHasVerticalScroller:YES];
    [transcriptScroll setBorderType:NSBezelBorder];
    [transcriptScroll setDrawsBackground:YES];
    [transcriptScroll setBackgroundColor:[NSColor colorWithCalibratedRed:215.0 / 255.0 green:218.0 / 255.0 blue:224.0 / 255.0 alpha:1]];
    transcript = [[TranscriptView alloc] initWithFrame:NSMakeRect(0, 0, 400, 400)];
    [transcriptScroll setDocumentView:transcript];
    [chatPane addSubview:transcriptScroll];

    input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
    [input setEditable:YES];
    [input setSelectable:YES];
    [input setBezeled:YES];
    [input setDrawsBackground:YES];
    [input setFont:[NSFont systemFontOfSize:13]];
    [[input cell] setWraps:YES];
    [[input cell] setScrollable:NO];
    [input setTarget:self];
    [input setAction:@selector(send:)];
    [input setDelegate:self];
    [chatPane addSubview:input];

    sendButton = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
    [sendButton setTitle:@"Send"];
    [sendButton setBezelStyle:NSRoundedBezelStyle];
    [sendButton setTarget:self];
    [sendButton setAction:@selector(send:)];
    [chatPane addSubview:sendButton];

    relayStatusField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
    [relayStatusField setStringValue:@""];
    [relayStatusField setEditable:NO];
    [relayStatusField setSelectable:NO];
    [relayStatusField setBezeled:NO];
    [relayStatusField setDrawsBackground:NO];
    [relayStatusField setFont:[NSFont boldSystemFontOfSize:12]];
    [relayStatusField setTextColor:[NSColor colorWithCalibratedRed:0.72 green:0.08 blue:0.05 alpha:1]];
    /* Wraps across the top of the chat pane, so a long problem is never cut off (Picture 8). */
    [[relayStatusField cell] setWraps:YES];
    [[relayStatusField cell] setLineBreakMode:NSLineBreakByWordWrapping];
    [chatPane addSubview:relayStatusField];

    workspacePopup=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(0,0,10,10) pullsDown:NO];
    [workspacePopup setTarget:self];[workspacePopup setAction:@selector(chooseWorkspace:)];
    [workspacePopup setFont:[NSFont systemFontOfSize:12]];[sidePane addSubview:workspacePopup];
    [self refillWorkspacePopup];

    contextField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
    [contextField setStringValue:@""];
    [contextField setEditable:NO];
    [contextField setSelectable:NO];
    [contextField setBezeled:NO];
    [contextField setDrawsBackground:NO];
    [contextField setAlignment:NSRightTextAlignment];
    [contextField setFont:[NSFont systemFontOfSize:12]];
    [contextField setTextColor:[NSColor colorWithCalibratedWhite:0.25 alpha:1]];
    [chatPane addSubview:contextField];
}

- (float)clampedSidebar:(float)proposed
{
    float limit;
    float thickness;
    thickness = split ? [split dividerThickness] : 10;
    limit = NSWidth([content bounds]) - thickness - 280;
    if (proposed < 168)
        proposed = 168;
    if (limit < 168)
        limit = 168;
    if (proposed > limit)
        proposed = limit;
    return proposed;
}

- (void)layoutSubviews
{
    NSRect bounds = [content bounds];
    float side;
    float thickness;
    if (!split)
        return;
    [split setFrame:bounds];
    thickness = [split dividerThickness];
    side = [self clampedSidebar:sidebarWidth];
    sidebarWidth = side;
    [sidePane setFrame:NSMakeRect(0, 0, side, NSHeight(bounds))];
    [chatPane setFrame:NSMakeRect(side + thickness, 0, NSWidth(bounds) - side - thickness, NSHeight(bounds))];
    [self layoutPanes];
}

- (void)layoutPanes
{
    static int layingOut = 0;
    NSRect side;
    NSRect mainRect;
    float sideW;
    float sideH;
    float mainW;
    float mainH;
    float innerW;
    float innerH;
    float column;
    float fieldW;
    NSView *label = nil;
    NSArray *subs;
    unsigned i;
    TBChatLayout chatLayout;
    NSRect oldInputFrame;
    NSRect oldSendFrame;
    NSRect oldTranscriptFrame;
    BOOL moved = NO;
    if (layingOut)
        return;
    layingOut = 1;
    /* On Tiger, -setFrame: does not repaint the area a view leaves, and
       chatPane is transparent over the textured window. When the message
       field grew or shrank, the Send button moved and left a ghost copy
       behind (Picture 7). Remember the old frames and repaint old and new
       spots once everything is placed. TBLayoutChatPane is checked by
       `make test`. */
    oldInputFrame = [input frame];
    oldSendFrame = [sendButton frame];
    oldTranscriptFrame = [transcriptScroll frame];
    side = [sidePane bounds];
    mainRect = [chatPane bounds];
    sideW = NSWidth(side);
    sideH = NSHeight(side);
    mainW = NSWidth(mainRect);
    mainH = NSHeight(mainRect);
    subs = [sidePane subviews];
    for (i = 0; i < [subs count]; i++) {
        NSView *view = [subs objectAtIndex:i];
        if ([view isKindOfClass:[NSTextField class]] && view != renameField)
            label = view;
    }
    column = sideW - 28;
    if (column < 80)
        column = 80;
    fieldW = mainW - 104;
    if (fieldW < 80)
        fieldW = 80;
    chatLayout = TBLayoutChatPane(mainW, mainH, [self inputHeightForWidth:fieldW],
        [self relayStatusHeightForWidth:mainW - 16]);
    inputHeight = chatLayout.fieldHeight;
    [label setHidden:YES];
    /* Top margin 12; 10 pixels between the workspace selector and New,
       8 between buttons, 12 before the chat list. Never overlap controls. */
    [workspacePopup setFrame:NSMakeRect(14, sideH - 38, column, 26)];
    [newButton setFrame:NSMakeRect(14, sideH - 76, column, 28)];
    [deleteButton setFrame:NSMakeRect(14, sideH - 112, column, 28)];
    [modelPopup setFrame:NSMakeRect(14, 76, column, 26)];
    [variantPopup setFrame:NSMakeRect(14, 42, column, 26)];
    [toolsButton setFrame:NSMakeRect(14, 8, column, 28)];
    [chatScroll setFrame:NSMakeRect(14, 110, column, MAX(40, sideH - 234))];
    {
        /* The relay problem wraps across the top; the context readout sits below it. */
        NSRect oldStatus = [relayStatusField frame];
        NSRect oldReadout = [contextField frame];
        if (!NSEqualRects(oldStatus, chatLayout.status) || !NSEqualRects(oldReadout, chatLayout.context)) {
            [relayStatusField setFrame:chatLayout.status];
            [contextField setFrame:chatLayout.context];
            [chatPane setNeedsDisplayInRect:NSUnionRect(NSUnionRect(oldStatus, chatLayout.status),
                NSUnionRect(oldReadout, chatLayout.context))];
            moved = YES;
        }
    }
    if (!NSEqualRects(oldTranscriptFrame, chatLayout.transcript)) {
        [transcriptScroll setFrame:chatLayout.transcript];
        [chatPane setNeedsDisplayInRect:NSUnionRect(oldTranscriptFrame, chatLayout.transcript)];
        [transcriptScroll setNeedsDisplay:YES];
        moved = YES;
    }
    if (!NSEqualRects(oldInputFrame, chatLayout.input)) {
        [input setFrame:chatLayout.input];
        [self fitFieldEditor];
        [chatPane setNeedsDisplayInRect:NSUnionRect(oldInputFrame, chatLayout.input)];
        [input setNeedsDisplay:YES];
        moved = YES;
    }
    if (!NSEqualRects(oldSendFrame, chatLayout.send)) {
        [sendButton setFrame:chatLayout.send];
        [chatPane setNeedsDisplayInRect:NSUnionRect(oldSendFrame, chatLayout.send)];
        [sendButton setNeedsDisplay:YES];
        moved = YES;
    }
    [self placeRenameField];
    [self updateContextReadout];
    if ([[table tableColumns] count] > 0) {
        NSTableColumn *tableColumn = [[table tableColumns] objectAtIndex:0];
        [tableColumn setWidth:NSWidth([[chatScroll contentView] bounds])];
    }
    innerW = NSWidth([[transcriptScroll contentView] bounds]);
    innerH = NSHeight([[transcriptScroll contentView] bounds]);
    if (innerW < 40)
        innerW = NSWidth([transcriptScroll frame]) - 20;
    if (innerH < 40)
        innerH = NSHeight([transcriptScroll frame]) - 4;
    [transcript layoutForWidth:innerW visibleHeight:innerH];
    if (moved && [window isVisible])
        [window displayIfNeeded];
    layingOut = 0;
}

- (float)splitView:(NSSplitView *)sender constrainMinCoordinate:(float)proposedMin ofSubviewAt:(int)offset
{
    (void)sender;
    (void)proposedMin;
    (void)offset;
    return 168;
}

- (float)splitView:(NSSplitView *)sender constrainMaxCoordinate:(float)proposedMax ofSubviewAt:(int)offset
{
    (void)proposedMax;
    (void)offset;
    return NSWidth([sender bounds]) - [sender dividerThickness] - 280;
}

- (void)splitViewDidResizeSubviews:(NSNotification *)note
{
    float width;
    (void)note;
    if (!sidePane)
        return;
    width = NSWidth([sidePane frame]);
    if (width >= 160)
        sidebarWidth = width;
    [[NSUserDefaults standardUserDefaults] setFloat:sidebarWidth forKey:@"TigerBuildSidebarWidth"];
    [self layoutPanes];
}

- (NSString *)providerForChat:(NSDictionary *)chat
{
    NSString *provider = [chat objectForKey:@"provider"];
    if (!provider || [provider length] == 0)
        return @"grok";
    return provider;
}

- (void)addModelItem:(NSString *)title identifier:(NSString *)identifier toMenu:(NSMenu *)menu
{
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(chooseModel:) keyEquivalent:@""];
    [item setTarget:self];
    [item setRepresentedObject:identifier];
    [menu addItem:item];
    [item release];
}

- (void)addEditItem:(NSString *)title action:(SEL)action key:(NSString *)key toMenu:(NSMenu *)menu
{
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key];
    [menu addItem:item];
    [item release];
}

/* Shortcuts live on items inside submenus too, so walk the whole tree. */
static void applyMenuShortcuts(NSMenu *menu, NSDictionary *shortcuts)
{
    unsigned i;
    for (i = 0; i < [menu numberOfItems]; i++) {
        NSMenuItem *item = [menu itemAtIndex:i];
        NSMenu *child = [item submenu];
        NSString *key = [shortcuts objectForKey:([item action] ? NSStringFromSelector([item action]) : @"")];
        if (key) {
            BOOL shifted = [key isEqualToString:[key uppercaseString]] && ![[key lowercaseString] isEqualToString:[key uppercaseString]];
            unsigned mask = NSCommandKeyMask | (shifted ? NSShiftKeyMask : 0);
            if ([item action] == @selector(commanderAutostart:) || [item action] == @selector(commanderIP:) || [item action] == @selector(showAbout:) || [item action] == @selector(showIntegrations:))
                mask |= NSAlternateKeyMask;
            [item setKeyEquivalent:[key lowercaseString]];
            [item setKeyEquivalentModifierMask:mask];
        }
        if (child)
            applyMenuShortcuts(child, shortcuts);
    }
}

- (void)installMenus
{
    NSMenu *bar = [[NSMenu alloc] init];
    NSMenuItem *appSlot = [[NSMenuItem alloc] init];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"Tiger Build"];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"Quit Tiger Build"
                                                  action:@selector(terminate:)
                                           keyEquivalent:@"q"];
    NSMenuItem *editSlot;
    NSMenu *editMenu;
    NSMenuItem *deleteItem;
    NSMenuItem *about = [[NSMenuItem alloc] initWithTitle:@"About Tiger Build"
                                                   action:@selector(showAbout:)
                                            keyEquivalent:@""];
    NSMenuItem *preferences = [[NSMenuItem alloc] initWithTitle:@"Preferences..."
                                                         action:@selector(showPreferences:)
                                                  keyEquivalent:@","];
    [about setTarget:self];
    [preferences setTarget:self];
    [appMenu addItem:about];
    [about release];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItem:preferences];
    [preferences release];
    [appMenu addItem:[NSMenuItem separatorItem]];
    {
        NSMenu *menu;
        NSMenuItem *item;
        NSMenuItem *slot;
        NSArray *titles;
        SEL actions[6];
        unsigned i;
        menu = [[[NSMenu alloc] initWithTitle:@"Configuration"] autorelease];
        titles = [NSArray arrayWithObjects:@"MCP Servers and Agent Tools...", @"Export All Settings...", @"Import All Settings...", nil];
        actions[0] = @selector(showIntegrations:); actions[1] = @selector(exportAllSettings:); actions[2] = @selector(importAllSettings:);
        for (i = 0; i < 3; i++) {
            item = [[[NSMenuItem alloc] initWithTitle:[titles objectAtIndex:i] action:actions[i] keyEquivalent:@""] autorelease];
            [item setTarget:self]; [menu addItem:item];
        }
        slot = [[[NSMenuItem alloc] initWithTitle:@"Configuration" action:NULL keyEquivalent:@""] autorelease];
        [slot setSubmenu:menu]; [appMenu addItem:slot];
        [appMenu addItem:[NSMenuItem separatorItem]];
        menu = [[[NSMenu alloc] initWithTitle:@"History"] autorelease];
        titles = [NSArray arrayWithObjects:@"Export History...", @"Import History...",
            @"Export History to Relay Host...", @"Import History from Relay Host...", @"Clear All History...", nil];
        actions[0] = @selector(exportHistory:); actions[1] = @selector(importHistory:);
        actions[2] = @selector(exportHistoryToRelay:); actions[3] = @selector(importHistoryFromRelay:);
        actions[4] = @selector(clearAllHistory:);
        for (i = 0; i < 5; i++) {
            if (i == 4) [menu addItem:[NSMenuItem separatorItem]];
            item = [[[NSMenuItem alloc] initWithTitle:[titles objectAtIndex:i] action:actions[i] keyEquivalent:@""] autorelease];
            [item setTarget:self]; [menu addItem:item];
        }
        slot = [[[NSMenuItem alloc] initWithTitle:@"History" action:NULL keyEquivalent:@""] autorelease];
        [slot setSubmenu:menu]; [appMenu addItem:slot];
    }
    [appMenu addItem:[NSMenuItem separatorItem]];
    [quit setTarget:NSApp];
    [appMenu addItem:quit];
    [quit release];
    [appSlot setSubmenu:appMenu];
    [bar addItem:appSlot];
    [appSlot release];

    editSlot = [[NSMenuItem alloc] init];
    editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [self addEditItem:@"Cut" action:@selector(cut:) key:@"x" toMenu:editMenu];
    [self addEditItem:@"Copy" action:@selector(copy:) key:@"c" toMenu:editMenu];
    [self addEditItem:@"Paste" action:@selector(paste:) key:@"v" toMenu:editMenu];
    [self addEditItem:@"Select All" action:@selector(selectAll:) key:@"a" toMenu:editMenu];
    [editMenu addItem:[NSMenuItem separatorItem]];
    deleteItem = [[NSMenuItem alloc] initWithTitle:@"Delete Chat"
                                            action:@selector(deleteChat:)
                                     keyEquivalent:@"\b"];
    [deleteItem setTarget:self];
    [editMenu addItem:deleteItem];
    [deleteItem release];
    [editSlot setSubmenu:editMenu];
    [editMenu release];
    [bar addItem:editSlot];
    [editSlot release];

    {
        NSMenu *chat = [[[NSMenu alloc] initWithTitle:@"Chat"] autorelease];
        NSMenuItem *slot = [[[NSMenuItem alloc] init] autorelease];
        NSMenuItem *item;
        NSArray *titles;
        SEL actions[8];
        unsigned i;
        item = [[[NSMenuItem alloc] initWithTitle:@"New Chat" action:@selector(newChat:) keyEquivalent:@"n"] autorelease];
        [item setTarget:self]; [chat addItem:item];
        item = [[[NSMenuItem alloc] initWithTitle:@"Toggle Tools for This Chat" action:@selector(toggleTools:) keyEquivalent:@"t"] autorelease];
        [item setTarget:self]; [chat addItem:item];
        [chat addItem:[NSMenuItem separatorItem]];
        {
            NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"Workspace"] autorelease];
            NSMenuItem *slot;
            titles = [NSArray arrayWithObjects:@"New Workspace...", @"Next Workspace", nil];
            actions[0] = @selector(newWorkspace:); actions[1] = @selector(workspaceNext:);
            for (i = 0; i < 2; i++) {
                item = [[[NSMenuItem alloc] initWithTitle:[titles objectAtIndex:i] action:actions[i] keyEquivalent:@""] autorelease];
                [item setTarget:self]; [menu addItem:item];
            }
            slot = [[[NSMenuItem alloc] initWithTitle:@"Workspace" action:NULL keyEquivalent:@""] autorelease];
            [slot setSubmenu:menu]; [chat addItem:slot];
            [chat addItem:[NSMenuItem separatorItem]];
            menu = [[[NSMenu alloc] initWithTitle:@"View"] autorelease];
            titles = [NSArray arrayWithObjects:@"Focus Message Field", @"Jump to Latest", @"Copy Last Answer",
                @"Expand Activity Details", @"Collapse Activity Details", nil];
            actions[0] = @selector(focusComposer:); actions[1] = @selector(jumpToLatest:);
            actions[2] = @selector(copyAnswer:); actions[3] = @selector(expandActivities:);
            actions[4] = @selector(collapseActivities:);
            for (i = 0; i < 5; i++) {
                item = [[[NSMenuItem alloc] initWithTitle:[titles objectAtIndex:i] action:actions[i] keyEquivalent:@""] autorelease];
                [item setTarget:self]; [menu addItem:item];
            }
            slot = [[[NSMenuItem alloc] initWithTitle:@"View" action:NULL keyEquivalent:@""] autorelease];
            [slot setSubmenu:menu]; [chat addItem:slot];
        }
        [slot setSubmenu:chat]; [bar addItem:slot];
    }

    NSMenuItem *modelSlot = [[NSMenuItem alloc] init];
    NSMenu *modelMenu = [[NSMenu alloc] initWithTitle:@"Model"];
    [self fillProviderMenu:modelMenu];
    [modelSlot setSubmenu:modelMenu];
    [modelMenu release];
    [bar addItem:modelSlot];
    [modelSlot release];

    {
        NSMenu *windowMenu = [[[NSMenu alloc] initWithTitle:@"Window"] autorelease];
        NSMenuItem *windowSlot = [[[NSMenuItem alloc] init] autorelease];
        NSArray *titles = [NSArray arrayWithObjects:@"New Window", @"Close Window", @"Minimize", @"Maximize", @"Keep It On Top", nil];
        SEL actions[] = {@selector(newWindow:), @selector(closeWindow:), @selector(minimizeWindow:), @selector(zoomWindow:), @selector(toggleOnTop:)};
        NSArray *keys = [NSArray arrayWithObjects:@"N", @"w", @"m", @"M", @"T", nil];
        unsigned i;
        for (i = 0; i < [titles count]; i++) {
            NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:[titles objectAtIndex:i] action:actions[i] keyEquivalent:[keys objectAtIndex:i]] autorelease];
            [item setTarget:self];
            if (i == 4)
                [windowMenu addItem:[NSMenuItem separatorItem]];
            [windowMenu addItem:item];
        }
        [windowSlot setSubmenu:windowMenu]; [bar addItem:windowSlot];
    }

    {
        NSMenu *menu = [[[NSMenu alloc] initWithTitle:@"Command Standalone"] autorelease];
        NSMenuItem *slot = [[[NSMenuItem alloc] init] autorelease];
        NSMenuItem *item;
        NSArray *titles;
        SEL actions[4];
        unsigned i;
        [menu setAutoenablesItems:NO];
        [menu setDelegate:self];
        item = [[[NSMenuItem alloc] initWithTitle:@"Command Standalone: Off" action:NULL keyEquivalent:@""] autorelease];
        [item setEnabled:NO];
        [menu addItem:item];
        titles = [NSArray arrayWithObjects:@"Start", @"Stop", @"Start at Login", @"This Mac's IP Addresses...", nil];
        actions[0] = @selector(commanderStart:);
        actions[1] = @selector(commanderStop:);
        actions[2] = @selector(commanderAutostart:);
        actions[3] = @selector(commanderIP:);
        for (i = 0; i < 4; i++) {
            if (i == 2)
                [menu addItem:[NSMenuItem separatorItem]];
            item = [[[NSMenuItem alloc] initWithTitle:[titles objectAtIndex:i] action:actions[i] keyEquivalent:@""] autorelease];
            [item setTarget:self];
            [menu addItem:item];
        }
        [slot setSubmenu:menu];
        [bar addItem:slot];
    }

    [bar setValue:@"NSMainMenu" forKey:@"name"];
    [appMenu setValue:@"NSAppleMenu" forKey:@"name"];
    {
        NSDictionary *shortcuts=[NSDictionary dictionaryWithObjectsAndKeys:
            @"n",@"newChat:",@"N",@"newWorkspace:",@"]",@"workspaceNext:",@"l",@"focusComposer:",
            @"j",@"jumpToLatest:",@"K",@"copyAnswer:",@"+",@"expandActivities:",@"-",@"collapseActivities:",
            @"e",@"exportHistory:",@"i",@"importHistory:",@"E",@"exportHistoryToRelay:",@"I",@"importHistoryFromRelay:",
            @"H",@"clearAllHistory:",@"u",@"commanderStart:",@"U",@"commanderStop:",@"a",@"commanderAutostart:",
            @"p",@"commanderIP:",@"m",@"showIntegrations:",@"s",@"exportAllSettings:",@"o",@"importAllSettings:",
            @"b",@"showAbout:",nil];
        unsigned g;
        for(g=0;g<[bar numberOfItems];g++)
            applyMenuShortcuts([[bar itemAtIndex:g] submenu], shortcuts);
    }
    [NSApp setMainMenu:bar];
    [NSApp setAppleMenu:appMenu];
    [appMenu release];
    [bar release];
}

- (NSMenu *)modelMenu
{
    NSMenu *bar = [NSApp mainMenu];
    int i;
    if (!bar)
        return nil;
    for (i = 0; i < [bar numberOfItems]; i++) {
        NSMenu *submenu = [[bar itemAtIndex:i] submenu];
        if (submenu && [[submenu title] isEqualToString:@"Model"])
            return submenu;
    }
    return nil;
}

- (NSString *)defaultModelForProvider:(NSString *)provider
{
    if ([provider isEqualToString:@"local"]) {
        if ([localModels count] > 0)
            return [[localModels objectAtIndex:0] objectForKey:@"id"];
        return @"";
    }
    return [[ModelCatalog shared] defaultModelForProvider:provider];
}

/* Why a provider cannot be picked, or nil when it can. */
- (NSString *)providerNote:(NSString *)provider
{
    NSString *state;
    if ([provider isEqualToString:@"local"])
        return [localModels count] > 0 ? nil : @"no local models";
    state = [[ModelCatalog shared] stateForProvider:provider];
    if ([state isEqualToString:@"nokey"])
        return @"no API key";
    if ([state isEqualToString:@"checking"])
        return @"testing models";
    if (![[ModelCatalog shared] providerUsable:provider])
        return @"unavailable";
    return nil;
}

- (NSString *)providerMenuTitle:(NSDictionary *)item
{
    NSString *note = [self providerNote:[item objectForKey:@"id"]];
    if (!note)
        return [item objectForKey:@"title"];
    return [NSString stringWithFormat:@"%@ (%@)", [item objectForKey:@"title"], note];
}

- (void)fillProviderMenu:(NSMenu *)menu
{
    NSArray *providers = [[ModelCatalog shared] providers];
    unsigned i;
    while ([menu numberOfItems] > 0)
        [menu removeItemAtIndex:0];
    for (i = 0; i < [providers count]; i++) {
        NSDictionary *item = [providers objectAtIndex:i];
        [self addModelItem:[self providerMenuTitle:item] identifier:[item objectForKey:@"id"] toMenu:menu];
        [[menu itemAtIndex:[menu numberOfItems]-1] setKeyEquivalent:[NSString stringWithFormat:@"%d",(int)i+1]];
    }
}

- (void)fillProviderPopup
{
    NSArray *providers = [[ModelCatalog shared] providers];
    unsigned i;
    if (!modelPopup)
        return;
    [[modelPopup menu] setAutoenablesItems:NO];
    [modelPopup removeAllItems];
    for (i = 0; i < [providers count]; i++) {
        NSDictionary *item = [providers objectAtIndex:i];
        NSString *pid = [item objectForKey:@"id"];
        [modelPopup addItemWithTitle:[self providerMenuTitle:item]];
        [[modelPopup lastItem] setRepresentedObject:pid];
        /* Local stays enabled so choosing it asks the server for models again. */
        [[modelPopup lastItem] setEnabled:([pid isEqualToString:@"local"] || [self providerNote:pid] == nil)];
    }
}

- (void)refreshCatalog
{
    [RelayRequest send:@"GET" path:@"/v1/models" body:nil timeout:15
        target:self action:@selector(catalogArrived:) context:nil];
}

- (NSString *)relayProblemForRequest:(RelayRequest *)request
{
    NSString *base = [self serverBase];
    if ([base length] == 0)
        return @"No relay is set. Choose Preferences and enter the relay address.";
    if ([request ok])
        return nil;
    if ([request status] == 401)
        return @"The relay rejected the token. Check the relay token in Preferences.";
    if ([request status] == 403)
        return [NSString stringWithFormat:@"The relay at %@ does not accept this Mac's address. "
            @"Add it to ALLOWED_CLIENTS in the relay's config.sh.", base];
    if ([request status] == 0 || [request timedOut])
        return [NSString stringWithFormat:@"Cannot reach the relay at %@. Check that it is running "
            @"and that Preferences has the right address and port.", base];
    return [NSString stringWithFormat:@"The relay at %@ answered with HTTP %d.", base, [request status]];
}

/* Height the relay problem needs at this width, 0 when there is none. */
- (float)relayStatusHeightForWidth:(float)width
{
    NSSize size;
    if (!relayStatusField || [[relayStatusField stringValue] length] == 0)
        return 0;
    if (width < 40)
        width = 40;
    size = [[relayStatusField cell] cellSizeForBounds:NSMakeRect(0, 0, width, 1000)];
    return ceilf(size.height);
}

/* Lay out again only when the problem now needs a different height. */
- (void)relayStatusChanged
{
    float width = NSWidth([chatPane bounds]) - 16;
    float height = [self relayStatusHeightForWidth:width];
    if (height > TB_STATUS_MAX)
        height = TB_STATUS_MAX;
    if (fabsf(height - NSHeight([relayStatusField frame])) >= 0.5f)
        [self layoutPanes];
    else
        [relayStatusField setNeedsDisplay:YES];
}

- (void)setRelayProblem:(NSString *)text
{
    relayReachable = (text == nil);
    [relayStatusField setStringValue:text ? text : @""];
    [relayStatusField setToolTip:text];
    [relayStatusField setTextColor:[NSColor colorWithCalibratedRed:0.72 green:0.08 blue:0.05 alpha:1]];
    if (!text && [[ModelCatalog shared] checkingCount] > 0) {
        [relayStatusField setStringValue:[NSString stringWithFormat:
            @"The relay is still testing %d models. More may appear.", [[ModelCatalog shared] checkingCount]]];
        [relayStatusField setTextColor:[NSColor colorWithCalibratedWhite:0.3 alpha:1]];
    }
    [self relayStatusChanged];
}

/* Every 30 seconds: while the relay is unreachable or still testing models,
   ask again; otherwise refresh the model list every 10 minutes. */
- (void)relayTick:(NSTimer *)timer
{
    double now = CFAbsoluteTimeGetCurrent();
    (void)timer;
    if (!relayReachable || [[ModelCatalog shared] checkingCount] > 0 || now - lastCatalog > 600)
        [self refreshCatalog];
    if (relayReachable && [[self providerForChat:current] isEqualToString:@"local"] && [localModels count] == 0)
        [self refreshLocalModels];
}

- (void)catalogArrived:(RelayRequest *)request
{
    NSString *text;
    NSMenu *menu;
    [self setRelayProblem:[self relayProblemForRequest:request]];
    if (![request ok])
        return;
    lastCatalog = CFAbsoluteTimeGetCurrent();
    text = [request text];
    if (![[ModelCatalog shared] loadText:text])
        return;
    [self setRelayProblem:nil];
    [self moveUntouchedChatsToUsableProvider];
    /* Keep a copy so the menus match the relay next launch, even offline. */
    [[text dataUsingEncoding:NSUTF8StringEncoding]
        writeToFile:[[self supportDir] stringByAppendingPathComponent:@"models.txt"] atomically:YES];
    menu = [self modelMenu];
    if (menu)
        [self fillProviderMenu:menu];
    [self fillProviderPopup];
    [self syncModelMenu];
    [self reportUnconfigured];
}

- (void)reportUnconfigured
{
    if (!relayReachable) return;
    NSArray *providers = [[ModelCatalog shared] providers];
    unsigned i;
    for (i = 0; i < [providers count]; i++) {
        NSString *pid = [[providers objectAtIndex:i] objectForKey:@"id"];
        if ([self providerUsable:pid]) return;
    }
    if ([[ModelCatalog shared] checkingCount] > 0) return;
    [relayStatusField setStringValue:@"No usable service configured. Add an API key or a local server in Preferences."];
    [relayStatusField setToolTip:[relayStatusField stringValue]];
    [relayStatusField setTextColor:[NSColor redColor]];
    [self relayStatusChanged];
}

- (BOOL)model:(NSString *)model allowedForProvider:(NSString *)provider
{
    int i;
    if (!model || [model length] == 0)
        return NO;
    if ([provider isEqualToString:@"local"]) {
        if ([localModels count] == 0)
            return YES;
        for (i = 0; i < (int)[localModels count]; i++) {
            if ([[[localModels objectAtIndex:i] objectForKey:@"id"] isEqualToString:model])
                return YES;
        }
        return NO;
    }
    return [[ModelCatalog shared] hasModel:model forProvider:provider];
}

- (NSString *)modelForChat:(NSDictionary *)chat
{
    NSString *provider = [self providerForChat:chat];
    NSString *model = [chat objectForKey:@"model"];
    if ([self model:model allowedForProvider:provider])
        return model;
    return [self defaultModelForProvider:provider];
}

- (void)addVariantTitle:(NSString *)title model:(NSString *)model
{
    [variantPopup addItemWithTitle:title];
    [[variantPopup lastItem] setRepresentedObject:model];
}

- (void)refillVariantPopup
{
    NSString *provider;
    NSString *selected;
    NSArray *list;
    NSDictionary *item;
    int i;
    if (!variantPopup)
        return;
    provider = [self providerForChat:current];
    [variantPopup removeAllItems];
    if ([provider isEqualToString:@"local"]) {
        list = localModels;
        if ([list count] == 0)
            [self addVariantTitle:@"No local models" model:@""];
    } else {
        list = [[ModelCatalog shared] modelsForProvider:provider];
        if ([list count] == 0) {
            NSString *note = [self providerNote:provider];
            [self addVariantTitle:(note ? [NSString stringWithFormat:@"No models (%@)", note] : @"No models")
                            model:@""];
        }
    }
    for (i = 0; i < (int)[list count]; i++) {
        item = [list objectAtIndex:i];
        [self addVariantTitle:[item objectForKey:@"title"] model:[item objectForKey:@"id"]];
    }
    selected = [self modelForChat:current];
    for (i = 0; i < [variantPopup numberOfItems]; i++) {
        if ([[[variantPopup itemAtIndex:i] representedObject] isEqualToString:selected]) {
            [variantPopup selectItemAtIndex:i];
            return;
        }
    }
}

- (void)syncModelMenu
{
    NSMenu *modelMenu = [self modelMenu];
    NSString *selected = [self providerForChat:current];
    int i;
    if (modelMenu) {
        for (i = 0; i < [modelMenu numberOfItems]; i++) {
            NSMenuItem *item = [modelMenu itemAtIndex:i];
            if ([[item representedObject] isEqualToString:selected])
                [item setState:NSOnState];
            else
                [item setState:NSOffState];
        }
    }
    if (modelPopup) {
        for (i = 0; i < [modelPopup numberOfItems]; i++) {
            NSMenuItem *item = [modelPopup itemAtIndex:i];
            if ([[item representedObject] isEqualToString:selected]) {
                [modelPopup selectItemAtIndex:i];
                break;
            }
        }
    }
    [self refillVariantPopup];
}

- (IBAction)chooseModel:(id)sender
{
    NSString *provider = nil;
    if (!current)
        return;
    if ([sender isKindOfClass:[NSMenuItem class]])
        provider = [sender representedObject];
    else if ([sender isKindOfClass:[NSPopUpButton class]])
        provider = [[sender selectedItem] representedObject];
    if (!provider || [provider length] == 0)
        return;
    if (![provider isEqualToString:@"local"] && [self providerNote:provider]) {
        NSString *note = [self providerNote:provider];
        NSBeep();
        [self syncModelMenu];
        if ([note isEqualToString:@"no API key"])
            [self setRelayProblem:[NSString stringWithFormat:
                @"%@ has no API key. Add one in Preferences.", [[ModelCatalog shared] titleForProvider:provider]]];
        return;
    }
    [current setObject:provider forKey:@"provider"];
    if ([provider isEqualToString:@"local"])
        [self refreshLocalModels];
    if (![self model:[current objectForKey:@"model"] allowedForProvider:provider])
        [current setObject:[self defaultModelForProvider:provider] forKey:@"model"];
    [current removeObjectForKey:@"contextLimit"];
    [self saveStore];
    [self syncModelMenu];
    [self rememberContextLimit];
    [self updateContextReadout];
}

- (IBAction)chooseVariant:(id)sender
{
    NSString *model = nil;
    NSString *provider;
    if (!current)
        return;
    if ([sender isKindOfClass:[NSMenuItem class]])
        model = [sender representedObject];
    else if ([sender isKindOfClass:[NSPopUpButton class]])
        model = [[sender selectedItem] representedObject];
    provider = [self providerForChat:current];
    if (![self model:model allowedForProvider:provider])
        return;
    [current setObject:model forKey:@"model"];
    [current removeObjectForKey:@"contextLimit"];
    [self saveStore];
    [self rememberContextLimit];
    [self updateContextReadout];
}

- (void)applicationWillFinishLaunching:(NSNotification *)note
{
    (void)note;
    [self installMenus];
}

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    [TBMachine startDetection];
    (void)note;
    [self loadStore];
    [self buildWindow];
    [self layoutSubviews];
    [self reloadTableSelect:0 show:YES];
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [window makeFirstResponder:input];
    [window display];
    [self refreshCatalog];
    [self refreshLocalModels];
    relayTimer = [[NSTimer scheduledTimerWithTimeInterval:30 target:self
        selector:@selector(relayTick:) userInfo:nil repeats:YES] retain];
    if ([[self serverBase] length] == 0 || [[RelayRequest token] length] == 0)
        [self performSelector:@selector(showPreferences:) withObject:nil afterDelay:0.5];
    if (launchQuestion) {
        [input setStringValue:launchQuestion];
        [self performSelector:@selector(send:) withObject:nil afterDelay:0.4];
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app
{
    (void)app;
    return YES;
}

- (int)numberOfRowsInTableView:(NSTableView *)aTable
{
    (void)aTable;
    return (int)[chats count];
}

- (id)tableView:(NSTableView *)aTable objectValueForTableColumn:(NSTableColumn *)column row:(int)row
{
    NSString *title;
    NSString *chatId;
    (void)aTable;
    (void)column;
    if (row < 0 || row >= (int)[chats count])
        return @"";
    title = [[chats objectAtIndex:row] objectForKey:@"title"];
    chatId = [[chats objectAtIndex:row] objectForKey:@"id"];
    if ((busy || naming) && streamingId && [streamingId isEqualToString:chatId])
        return [NSString stringWithFormat:@"%C  %@", (unichar)0x2022, title ? title : @""];
    return title ? title : @"";
}

- (void)tableView:(NSTableView *)aTable setObjectValue:(id)value forTableColumn:(NSTableColumn *)column row:(int)row
{
    NSString *title;
    (void)aTable;
    (void)column;
    if (row < 0 || row >= (int)[chats count])
        return;
    if ([value isKindOfClass:[NSString class]])
        title = value;
    else
        title = [value description];
    title = [title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([title length] == 0)
        title = @"New Chat";
    if ([title length] > 80)
        title = [title substringToIndex:80];
    [[chats objectAtIndex:row] setObject:title forKey:@"title"];
    [self saveStore];
}

- (void)cancelPendingInputFocus
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(focusInputIfNotEditing) object:nil];
}

- (BOOL)tableView:(NSTableView *)aTable shouldEditTableColumn:(NSTableColumn *)column row:(int)row
{
    /* The table's own editor highlights the name and then drops keystrokes.
       Double-click opens renameField instead. */
    (void)aTable;
    (void)column;
    (void)row;
    return NO;
}

- (void)placeRenameField
{
    NSRect rowRect;
    NSRect inWindow;
    if (renameRow < 0 || !renameField)
        return;
    if (renameRow >= (int)[chats count])
        return;
    rowRect = [table rectOfRow:renameRow];
    rowRect = NSInsetRect(rowRect, 2, -1);
    inWindow = [table convertRect:rowRect toView:nil];
    [renameField setFrame:[content convertRect:inWindow fromView:nil]];
}

- (void)selectRenameText
{
    NSText *editor;
    if (renameRow < 0 || !renameField)
        return;
    editor = [renameField currentEditor];
    if (!editor && [[window firstResponder] isKindOfClass:[NSText class]])
        editor = (NSText *)[window firstResponder];
    if (editor)
        [editor setSelectedRange:NSMakeRange(0, [[renameField stringValue] length])];
}

- (void)beginRenameForRow:(int)row
{
    NSString *title;
    if (busy)
        return;
    if (row < 0 || row >= (int)[chats count])
        return;
    [self cancelPendingInputFocus];
    renameRow = row;
    suppressSelection = YES;
    [table selectRow:row byExtendingSelection:NO];
    suppressSelection = NO;
    [self showChatAtIndex:row];
    if (!renameField) {
        renameField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
        [renameField setEditable:YES];
        [renameField setSelectable:YES];
        [renameField setEnabled:YES];
        [renameField setBezeled:YES];
        [renameField setDrawsBackground:YES];
        [renameField setBackgroundColor:[NSColor whiteColor]];
        [renameField setTextColor:[NSColor blackColor]];
        [renameField setFont:[NSFont systemFontOfSize:13]];
        [renameField setTarget:self];
        [renameField setAction:@selector(commitRename:)];
        [renameField setDelegate:self];
        [[renameField cell] setScrollable:YES];
        [content addSubview:renameField];
    }
    [content addSubview:renameField];
    title = [[chats objectAtIndex:row] objectForKey:@"title"];
    if (!title)
        title = @"";
    [renameField setStringValue:title];
    [renameField setHidden:NO];
    [self placeRenameField];
    [window makeFirstResponder:renameField];
    [self selectRenameText];
    [self performSelector:@selector(selectRenameText) withObject:nil afterDelay:0.0];
}

- (IBAction)commitRename:(id)sender
{
    NSString *title;
    int row;
    (void)sender;
    if (renameRow < 0 || !renameField)
        return;
    row = renameRow;
    title = [[renameField stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    renameRow = -1;
    [renameField setHidden:YES];
    if ([title length] == 0)
        title = @"New Chat";
    if ([title length] > 80)
        title = [title substringToIndex:80];
    if (row >= 0 && row < (int)[chats count]) {
        [[chats objectAtIndex:row] setObject:title forKey:@"title"];
        [[chats objectAtIndex:row] setObject:[NSNumber numberWithBool:NO] forKey:@"autoTitle"];
        [self saveStore];
        suppressSelection = YES;
        [table reloadData];
        if (row >= (int)[chats count])
            row = (int)[chats count] - 1;
        if (row >= 0)
            [table selectRow:row byExtendingSelection:NO];
        suppressSelection = NO;
        [self showChatAtIndex:row];
    }
    [window makeFirstResponder:input];
}

- (void)cancelRename:(id)sender
{
    (void)sender;
    renameRow = -1;
    if (renameField)
        [renameField setHidden:YES];
    [self cancelPendingInputFocus];
    [window makeFirstResponder:input];
}

- (void)controlTextDidBeginEditing:(NSNotification *)note
{
    NSText *editor;
    if ([note object] != renameField)
        return;
    editor = [[note userInfo] objectForKey:@"NSFieldEditor"];
    if (![editor isKindOfClass:[NSTextView class]])
        return;
    [(NSTextView *)editor setEditable:YES];
    [(NSTextView *)editor setSelectable:YES];
    [(NSTextView *)editor setTextColor:[NSColor blackColor]];
    [(NSTextView *)editor setBackgroundColor:[NSColor whiteColor]];
    [(NSTextView *)editor setDrawsBackground:YES];
}

- (void)focusInputIfNotEditing
{
    NSEvent *event;
    if (busy || renameRow >= 0)
        return;
    if ([table editedRow] >= 0 || [table currentEditor] != nil)
        return;
    event = [NSApp currentEvent];
    if (event && [event type] == NSLeftMouseDown && [event clickCount] > 1)
        return;
    [window makeFirstResponder:input];
}

- (void)tableViewSelectionDidChange:(NSNotification *)note
{
    (void)note;
    if (suppressSelection)
        return;
    [self showChatAtIndex:[table selectedRow]];
    if (renameRow >= 0)
        return;
    [self cancelPendingInputFocus];
    [self performSelector:@selector(focusInputIfNotEditing) withObject:nil afterDelay:0.5];
}

- (NSWindow *)frontWindow
{
    NSWindow *win = [NSApp keyWindow];
    if (!win)
        win = [NSApp mainWindow];
    if (!win)
        win = window;
    return win;
}

- (void)openSecondary
{
    NSRect frame;
    nextWindowIsExtra = YES;
    [self loadStore];
    [self buildWindow];
    nextWindowIsExtra = NO;
    [self layoutSubviews];
    [self reloadTableSelect:0 show:YES];
    frame = [window frame];
    frame.origin.x += 28;
    frame.origin.y -= 28;
    [window setFrame:frame display:NO];
    [window makeKeyAndOrderFront:nil];
    [window makeFirstResponder:input];
    [self refreshCatalog];
    [self refreshLocalModels];
    relayTimer = [[NSTimer scheduledTimerWithTimeInterval:30 target:self
        selector:@selector(relayTick:) userInfo:nil repeats:YES] retain];
}

- (void)retireExtraWindow
{
    [extraWindows removeObject:self];
}

- (void)windowWillClose:(NSNotification *)note
{
    (void)note;
    if (self == [NSApp delegate])
        return;
    [self performSelector:@selector(retireExtraWindow) withObject:nil afterDelay:0];
}

- (IBAction)newWindow:(id)sender
{
    ChatController *extra;
    (void)sender;
    if (!extraWindows)
        extraWindows = [[NSMutableArray alloc] init];
    extra = [[ChatController alloc] init];
    [extraWindows addObject:extra];
    [extra release];
    [extra openSecondary];
}

- (IBAction)closeWindow:(id)sender
{
    [[self frontWindow] performClose:sender];
}

- (IBAction)minimizeWindow:(id)sender
{
    [[self frontWindow] miniaturize:sender];
}

- (IBAction)zoomWindow:(id)sender
{
    [[self frontWindow] zoom:sender];
}

- (IBAction)toggleOnTop:(id)sender
{
    NSWindow *win = [self frontWindow];
    (void)sender;
    if (!win)
        return;
    if ([win level] > NSNormalWindowLevel)
        [win setLevel:NSNormalWindowLevel];
    else
        [win setLevel:NSFloatingWindowLevel];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    if ([item action] == @selector(toggleOnTop:)) {
        NSWindow *win = [self frontWindow];
        [item setState:(win && [win level] > NSNormalWindowLevel) ? NSOnState : NSOffState];
    }
    if ([[[item menu] title] isEqualToString:@"Workspace"]) return !busy && !naming;
    if ([[[item menu] title] isEqualToString:@"Configuration"]) return !busy;
    if ([[[item menu] title] isEqualToString:@"History"])
        return !busy;
    if ([item action] == @selector(deleteChat:))
        return !busy && [table selectedRow] >= 0;
    if ([item action] == @selector(chooseModel:) && [[item representedObject] isKindOfClass:[NSString class]]) {
        NSString *pid = [item representedObject];
        return [pid isEqualToString:@"local"] || [self providerNote:pid] == nil;
    }
    return YES;
}

- (IBAction)deleteChat:(id)sender
{
    int row;
    int choice;
    NSString *title;
    NSString *message;
    (void)sender;
    if (busy)
        return;
    if (renameRow >= 0)
        [self cancelRename:nil];
    row = [table selectedRow];
    if (row < 0 || row >= (int)[chats count])
        return;
    if ([table editedRow] >= 0)
        [window endEditingFor:table];
    title = [[chats objectAtIndex:row] objectForKey:@"title"];
    if (!title || [title length] == 0)
        title = @"New Chat";
    message = [NSString stringWithFormat:@"Delete \"%@\"?", title];
    choice = NSRunAlertPanel(@"Delete Chat", @"%@", @"Delete", @"Cancel", nil, message);
    if (choice != NSAlertDefaultReturn)
        return;
    [chats removeObjectAtIndex:row];
    if ([chats count] == 0)
        [chats addObject:[self blankChat]];
    if (row >= (int)[chats count])
        row = (int)[chats count] - 1;
    [self saveStore];
    [self reloadTableSelect:row show:YES];
    [window makeFirstResponder:input];
}

- (IBAction)newChat:(id)sender
{
    NSMutableDictionary *chat;
    (void)sender;
    chat = [self blankChat];
    [chats insertObject:chat atIndex:0];
    [self saveStore];
    [self reloadTableSelect:0 show:YES];
    [window makeFirstResponder:input];
}

- (IBAction)toggleTools:(id)sender
{
    BOOL on;
    (void)sender;
    if (!current)
        return;
    on = [self toolsEnabled:current];
    [current setObject:[NSNumber numberWithBool:!on] forKey:@"tools"];
    [self syncToolsButton];
    [self saveStore];
}

- (void)setBusy:(BOOL)flag
{
    busy = flag;
    [workspacePopup setEnabled:!flag];
    [input setEnabled:!flag];
    [sendButton setEnabled:!flag];
    [deleteButton setEnabled:!flag];
    [window setTitle:flag ? [NSString stringWithFormat:@"Tiger Build - %@ - Working...",[self workspaceName]]
        : [NSString stringWithFormat:@"Tiger Build - %@",[self workspaceName]]];
    suppressSelection = YES;
    [table reloadData];
    suppressSelection = NO;
    if (!flag)
        [window makeFirstResponder:input];
}

- (NSMutableDictionary *)chatWithId:(NSString *)chatId
{
    unsigned i;
    for (i = 0; i < [chats count]; i++) {
        NSMutableDictionary *chat = [chats objectAtIndex:i];
        if ([[chat objectForKey:@"id"] isEqualToString:chatId])
            return chat;
    }
    return nil;
}

- (NSMutableDictionary *)openMessageIn:(NSMutableDictionary *)chat
{
    NSMutableArray *messages = [chat objectForKey:@"messages"];
    int i;
    for (i = (int)[messages count] - 1; i >= 0; i--) {
        NSMutableDictionary *message = [messages objectAtIndex:i];
        if ([[message objectForKey:@"open"] boolValue])
            return message;
    }
    return nil;
}

- (void)refreshTranscriptIfCurrent:(NSMutableDictionary *)chat
{
    double now;
    if (chat != current)
        return;
    NSRect visible=[transcript visibleRect];
    BOOL follow=NSMaxY(visible)>NSHeight([transcript bounds])-70;
    [transcript setMessages:[chat objectForKey:@"messages"]];
    if(follow)[transcript scrollToEnd];
    /* NSURLConnection on Tiger delivers the body only when the connection
       closes. The read stream calls us as bytes arrive, and the window will
       not redraw until this callback returns to an idle run loop, which does
       not happen while more bytes are already waiting. Paint here. */
    now = CFAbsoluteTimeGetCurrent();
    if (now - lastPaint > 0.05) {
        lastPaint = now;
        [window displayIfNeeded];
    }
}

- (void)addStatus:(NSString *)text toChat:(NSMutableDictionary *)chat
{
    NSMutableArray *messages = [chat objectForKey:@"messages"];
    NSMutableDictionary *note = [NSMutableDictionary dictionary];
    NSMutableDictionary *open = [self openMessageIn:chat];
    [note setObject:@"status" forKey:@"role"];
    [note setObject:text ? text : @"" forKey:@"text"];
    [note setObject:[NSNumber numberWithBool:YES] forKey:@"status"];
    if (open && [[open objectForKey:@"text"] length] == 0) {
        unsigned index = [messages indexOfObject:open];
        [messages insertObject:note atIndex:index];
    } else {
        if (open && [[open objectForKey:@"text"] length] > 0)
            [open setObject:[NSNumber numberWithBool:NO] forKey:@"open"];
        [messages addObject:note];
    }
    [self refreshTranscriptIfCurrent:chat];
}

- (void)appendDelta:(NSString *)text toChat:(NSMutableDictionary *)chat
{
    NSMutableDictionary *open = [self openMessageIn:chat];
    NSString *soFar;
    if (!open) {
        open = [NSMutableDictionary dictionary];
        [open setObject:@"assistant" forKey:@"role"];
        [open setObject:@"" forKey:@"text"];
        [open setObject:[NSNumber numberWithBool:NO] forKey:@"status"];
        [open setObject:[NSNumber numberWithBool:YES] forKey:@"open"];
        [[chat objectForKey:@"messages"] addObject:open];
    }
    soFar = [open objectForKey:@"text"];
    if (!soFar)
        soFar = @"";
    [open setObject:[soFar stringByAppendingString:text ? text : @""] forKey:@"text"];
    [self refreshTranscriptIfCurrent:chat];
}

- (void)showAbout:(id)sender
{
    NSString *version;
    (void)sender;
    version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (!version || [version length] == 0)
        version = @"1.2";
    NSRunAlertPanel(@"About Tiger Build",
        @"Version %@\nLicensed under the MIT License.",
        @"OK", nil, nil, version);
}

- (NSString *)urlEncode:(NSString *)value
{
    NSString *encoded;
    if (!value)
        value = @"";
    encoded = (NSString *)CFURLCreateStringByAddingPercentEscapes(
        NULL, (CFStringRef)value, NULL,
        CFSTR(":/?#[]@!$&'()*+,;="), kCFStringEncodingUTF8);
    return [encoded autorelease];
}

- (void)attachMedia:(NSString *)line toChat:(NSMutableDictionary *)chat
{
    NSArray *parts;
    NSString *kind;
    NSString *name;
    NSMutableDictionary *open;
    NSDictionary *info;
    if (!line || !chat)
        return;
    parts = [line componentsSeparatedByString:@" "];
    if ([parts count] < 2)
        return;
    kind = [parts objectAtIndex:0];
    name = [parts objectAtIndex:1];
    if ([name length] == 0 || [name rangeOfString:@"/"].location != NSNotFound
        || [name rangeOfString:@".."].location != NSNotFound)
        return;
    open = [self openMessageIn:chat];
    if (!open) {
        open = [NSMutableDictionary dictionary];
        [open setObject:@"assistant" forKey:@"role"];
        [open setObject:@"" forKey:@"text"];
        [open setObject:[NSNumber numberWithBool:NO] forKey:@"status"];
        [open setObject:[NSNumber numberWithBool:YES] forKey:@"open"];
        [[chat objectForKey:@"messages"] addObject:open];
    }
    /* The reply keeps streaming while the file downloads. finishStream keeps
       a message with a download pending even when it has no text yet. */
    [open setObject:[NSNumber numberWithInt:[[open objectForKey:@"pendingMedia"] intValue] + 1]
             forKey:@"pendingMedia"];
    info = [NSDictionary dictionaryWithObjectsAndKeys:
        kind, @"kind", name, @"name", open, @"message", chat, @"chat", nil];
    [RelayRequest send:@"GET" path:[@"/v1/media/" stringByAppendingString:name] body:nil
        timeout:([kind isEqualToString:@"video"] ? 180 : 90)
        target:self action:@selector(mediaArrived:) context:info];
}

- (void)mediaArrived:(RelayRequest *)request
{
    NSDictionary *info = [request context];
    NSMutableDictionary *message = [info objectForKey:@"message"];
    NSMutableDictionary *chat = [info objectForKey:@"chat"];
    NSString *dir = [[self supportDir] stringByAppendingPathComponent:@"media"];
    NSString *path = [dir stringByAppendingPathComponent:[info objectForKey:@"name"]];
    int pending = [[message objectForKey:@"pendingMedia"] intValue] - 1;
    if (pending > 0)
        [message setObject:[NSNumber numberWithInt:pending] forKey:@"pendingMedia"];
    else
        [message removeObjectForKey:@"pendingMedia"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir attributes:nil];
    if ([request ok] && [[request data] length] > 0 && [[request data] writeToFile:path atomically:YES]) {
        if ([[info objectForKey:@"kind"] isEqualToString:@"image"])
            [message setObject:path forKey:@"image"];
        else
            [message setObject:path forKey:@"video"];
    } else {
        NSString *soFar = [message objectForKey:@"text"];
        [message setObject:[(soFar ? soFar : @"") stringByAppendingString:@"\nThe file could not be saved."]
                    forKey:@"text"];
    }
    if ([chats indexOfObjectIdenticalTo:chat] != NSNotFound) {
        [self saveStore];
        [self refreshTranscriptIfCurrent:chat];
    }
}

- (NSString *)tokenString:(int)count
{
    if (count >= 1000000)
        return [NSString stringWithFormat:@"%.1fm", count / 1000000.0];
    if (count >= 1000)
        return [NSString stringWithFormat:@"%.1fk", count / 1000.0];
    return [NSString stringWithFormat:@"%d", count];
}

- (int)estimatedTokens:(NSDictionary *)chat
{
    return TBEstimateTokens([chat objectForKey:@"messages"], [self toolsEnabled:chat]);
}

- (void)updateContextReadout
{
    int used;
    int limit;
    if (!contextField)
        return;
    if (!current) {
        [contextField setStringValue:@""];
        return;
    }
    used = [self estimatedTokens:current];
    limit = [[current objectForKey:@"contextLimit"] intValue];
    if (limit > 0) {
        [contextField setStringValue:[NSString stringWithFormat:@"Context %@ / %@",
            [self tokenString:used], [self tokenString:limit]]];
    } else {
        [contextField setStringValue:[NSString stringWithFormat:@"Context %@",
            [self tokenString:used]]];
    }
}

- (int)rememberContextLimit
{
    NSString *provider;
    NSString *model;
    NSString *key;
    NSDictionary *info;
    int limit;
    int i;
    if (!current)
        return 0;
    limit = [[current objectForKey:@"contextLimit"] intValue];
    if (limit > 0)
        return limit;
    provider = [self providerForChat:current];
    model = [self modelForChat:current];
    if ([provider isEqualToString:@"local"]) {
        for (i = 0; i < (int)[localModels count]; i++) {
            NSDictionary *item = [localModels objectAtIndex:i];
            if ([[item objectForKey:@"id"] isEqualToString:model]) {
                limit = [[item objectForKey:@"context"] intValue];
                break;
            }
        }
        if (limit > 0) {
            [current setObject:[NSNumber numberWithInt:limit] forKey:@"contextLimit"];
            return limit;
        }
    }
    if ([model length] == 0)
        return 0;
    /* Ask the relay without waiting; the readout fills in when it answers.
       This used to block the window for up to 8 seconds per chat switch. */
    key = [NSString stringWithFormat:@"%@|%@|%@", [current objectForKey:@"id"], provider, model];
    if ([contextPending objectForKey:key])
        return 0;
    [contextPending setObject:[NSNumber numberWithBool:YES] forKey:key];
    info = [NSDictionary dictionaryWithObjectsAndKeys:current, @"chat", model, @"model", key, @"key", nil];
    [RelayRequest send:@"GET"
        path:[NSString stringWithFormat:@"/v1/context?provider=%@&model=%@",
            [self urlEncode:provider], [self urlEncode:model]]
        body:nil timeout:10 target:self action:@selector(contextArrived:) context:info];
    return 0;
}

- (void)contextArrived:(RelayRequest *)request
{
    NSDictionary *info = [request context];
    NSMutableDictionary *chat = [info objectForKey:@"chat"];
    int limit = [request ok] ? [[request text] intValue] : 0;
    [contextPending removeObjectForKey:[info objectForKey:@"key"]];
    if (limit <= 0)
        return;
    if (![[self modelForChat:chat] isEqualToString:[info objectForKey:@"model"]])
        return;
    [chat setObject:[NSNumber numberWithInt:limit] forKey:@"contextLimit"];
    if (chat == current)
        [self updateContextReadout];
}

- (void)refreshLocalModels
{
    [RelayRequest send:@"GET" path:@"/v1/local-models" body:nil timeout:12
        target:self action:@selector(localModelsArrived:) context:nil];
}

- (void)localModelsArrived:(RelayRequest *)request
{
    NSArray *lines;
    unsigned i;
    if (![request ok])
        return;
    [localModels removeAllObjects];
    lines = [[request text] componentsSeparatedByString:@"\n"];
    for (i = 0; i < [lines count]; i++) {
        NSArray *parts = [[lines objectAtIndex:i] componentsSeparatedByString:@"\t"];
        NSMutableDictionary *item;
        if ([parts count] < 2 || [[parts objectAtIndex:0] isEqualToString:@"error"])
            continue;
        item = [NSMutableDictionary dictionary];
        [item setObject:[parts objectAtIndex:0] forKey:@"id"];
        [item setObject:[NSNumber numberWithInt:[[parts objectAtIndex:1] intValue]] forKey:@"context"];
        if ([parts count] > 2 && [[parts objectAtIndex:2] length] > 0)
            [item setObject:[parts objectAtIndex:2] forKey:@"title"];
        else
            [item setObject:[parts objectAtIndex:0] forKey:@"title"];
        [localModels addObject:item];
    }
    {
        NSMenu *menu = [self modelMenu];
        if (menu)
            [self fillProviderMenu:menu];
        [self fillProviderPopup];
        [self moveUntouchedChatsToUsableProvider];
        [self syncModelMenu];
    }
    if (current && [[self providerForChat:current] isEqualToString:@"local"]) {
        if (![self model:[current objectForKey:@"model"] allowedForProvider:@"local"])
            [current setObject:[self defaultModelForProvider:@"local"] forKey:@"model"];
        [current removeObjectForKey:@"contextLimit"];
        [self syncModelMenu];
        [self rememberContextLimit];
        [self updateContextReadout];
    }
    [self reportUnconfigured];
}

- (BOOL)startCompactionIfNeeded
{
    NSMutableDictionary *chat = [self chatWithId:streamingId];
    NSMutableArray *messages;
    NSMutableArray *spoken;
    NSMutableArray *older;
    NSMutableString *earlier;
    NSMutableString *body;
    NSDictionary *info;
    unsigned i;
    int limit;
    int used;
    if (!chat)
        return NO;
    limit = [[chat objectForKey:@"contextLimit"] intValue];
    if (limit <= 0 && chat == current)
        limit = [self rememberContextLimit];
    used = [self estimatedTokens:chat];
    /* Compact at 80 percent: the estimate is rough, and the reply needs room. */
    if (limit < 1000 || (long)used * 100 < (long)limit * 80)
        return NO;
    messages = [chat objectForKey:@"messages"];
    spoken = [NSMutableArray array];
    for (i = 0; i < [messages count]; i++) {
        NSDictionary *message = [messages objectAtIndex:i];
        if ([[message objectForKey:@"status"] boolValue])
            continue;
        if ([[message objectForKey:@"text"] length] == 0)
            continue;
        [spoken addObject:message];
    }
    if ((int)[spoken count] < 6)
        return NO;
    older = [NSMutableArray array];
    for (i = 0; i < [spoken count] - 4; i++)
        [older addObject:[spoken objectAtIndex:i]];
    earlier = [NSMutableString string];
    for (i = 0; i < [older count]; i++) {
        NSDictionary *message = [older objectAtIndex:i];
        NSString *piece = [message objectForKey:@"text"];
        if ([piece length] > 4000)
            piece = [piece substringToIndex:4000];
        [earlier appendFormat:@"%@: %@\n\n", [message objectForKey:@"role"], piece];
        if ([earlier length] > 24000)
            break;
    }
    [window setTitle:@"Tiger Build - Compacting..."];
    body = [NSMutableString stringWithString:@"{\"messages\":[{\"role\":\"user\",\"content\":\""];
    [body appendString:TBJSONEscape(earlier)];
    [body appendFormat:@"\"}],\"tools\":false,\"provider\":\"%@\",\"model\":\"%@\"}",
        TBJSONEscape([self providerForChat:chat]), TBJSONEscape([self modelForChat:chat])];
    info = [NSDictionary dictionaryWithObjectsAndKeys:chat, @"chat", older, @"older", nil];
    [RelayRequest send:@"POST" path:@"/v1/summarize" body:body timeout:120
        target:self action:@selector(compactionArrived:) context:info];
    return YES;
}

- (void)compactionArrived:(RelayRequest *)request
{
    NSDictionary *info = [request context];
    NSMutableDictionary *chat = [info objectForKey:@"chat"];
    NSArray *older = [info objectForKey:@"older"];
    NSMutableArray *messages = [chat objectForKey:@"messages"];
    NSString *text = [[request text] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (![request ok] || [text length] == 0) {
        [self addStatus:@"Could not compact this chat, so it was sent whole." toChat:chat];
    } else {
        NSMutableDictionary *summary = [NSMutableDictionary dictionary];
        NSMutableArray *rebuilt = [NSMutableArray array];
        BOOL inserted = NO;
        unsigned i;
        [summary setObject:@"assistant" forKey:@"role"];
        [summary setObject:[NSString stringWithFormat:@"Earlier in this chat:\n%@", text] forKey:@"text"];
        [summary setObject:[NSNumber numberWithBool:NO] forKey:@"status"];
        for (i = 0; i < [messages count]; i++) {
            NSDictionary *message = [messages objectAtIndex:i];
            if ([older indexOfObjectIdenticalTo:message] != NSNotFound) {
                if (!inserted) {
                    [rebuilt addObject:summary];
                    inserted = YES;
                }
                continue;
            }
            [rebuilt addObject:message];
        }
        [messages setArray:rebuilt];
        [self saveStore];
        [self refreshTranscriptIfCurrent:chat];
        [self updateContextReadout];
    }
    [window setTitle:@"Tiger Build - Sending..."];
    [self beginChatStream];
}

- (void)autonameChat:(NSMutableDictionary *)chat
{
    NSArray *messages;
    NSString *userText = nil;
    NSString *assistantText = nil;
    NSMutableString *body;
    NSString *prompt;
    id flag;
    int i;
    if (!chat || naming)
        return;
    flag = [chat objectForKey:@"autoTitle"];
    if (flag && ![flag boolValue])
        return;
    if (!flag && ![[chat objectForKey:@"title"] isEqualToString:@"New Chat"])
        return;
    messages = [chat objectForKey:@"messages"];
    for (i = 0; i < (int)[messages count]; i++) {
        NSDictionary *message = [messages objectAtIndex:i];
        NSString *role;
        NSString *piece;
        if ([[message objectForKey:@"status"] boolValue])
            continue;
        piece = [message objectForKey:@"text"];
        if ([piece length] == 0)
            continue;
        role = [message objectForKey:@"role"];
        if ([role isEqualToString:@"user"])
            userText = piece;
        else if ([role isEqualToString:@"assistant"])
            assistantText = piece;
    }
    if (!userText || !assistantText || [assistantText isEqualToString:@"Hello. Ask me anything."])
        return;
    if ([userText length] > 1500)
        userText = [userText substringToIndex:1500];
    if ([assistantText length] > 1500)
        assistantText = [assistantText substringToIndex:1500];
    prompt = [NSString stringWithFormat:@"User: %@\n\nAssistant: %@", userText, assistantText];
    body = [NSMutableString stringWithString:@"{\"messages\":[{\"role\":\"user\",\"content\":\""];
    [body appendString:TBJSONEscape(prompt)];
    [body appendFormat:@"\"}],\"tools\":false,\"provider\":\"%@\",\"model\":\"%@\"}",
        TBJSONEscape([self providerForChat:chat]), TBJSONEscape([self modelForChat:chat])];
    naming = YES;
    suppressSelection = YES;
    [table reloadData];
    suppressSelection = NO;
    [RelayRequest send:@"POST" path:@"/v1/title" body:body timeout:40
        target:self action:@selector(titleArrived:) context:chat];
}

- (void)titleArrived:(RelayRequest *)request
{
    NSMutableDictionary *chat = [request context];
    NSString *text = [[request text] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    id flag;
    naming = NO;
    suppressSelection = YES;
    [table reloadData];
    suppressSelection = NO;
    if (![request ok] || [text length] == 0 || [text isEqualToString:@"New Chat"])
        return;
    if ([chats indexOfObjectIdenticalTo:chat] == NSNotFound)
        return;
    flag = [chat objectForKey:@"autoTitle"];
    if (flag && ![flag boolValue])
        return;
    if ([text length] > 80)
        text = [text substringToIndex:80];
    [chat setObject:text forKey:@"title"];
    [chat setObject:[NSNumber numberWithBool:NO] forKey:@"autoTitle"];
    [self saveStore];
    suppressSelection = YES;
    [table reloadData];
    suppressSelection = NO;
}

- (NSString *)requestBodyForChat:(NSDictionary *)chat
{
    NSArray *messages = [chat objectForKey:@"messages"];
    NSMutableString *body = [NSMutableString stringWithString:@"{\"messages\":["];
    unsigned i;
    BOOL first = YES;
    for (i = 0; i < [messages count]; i++) {
        NSDictionary *message = [messages objectAtIndex:i];
        NSString *role;
        NSString *text = [message objectForKey:@"text"];
        if ([[message objectForKey:@"status"] boolValue])
            continue;
        if ([[message objectForKey:@"open"] boolValue] && [text length] == 0)
            continue;
        if ([[message objectForKey:@"role"] isEqualToString:@"user"])
            role = @"user";
        else
            role = @"assistant";
        if (!first)
            [body appendString:@","];
        first = NO;
        [body appendFormat:@"{\"role\":\"%@\",\"content\":\"%@\"}", role, TBJSONEscape(text)];
    }
    /* Provider and model come from saved chats and the local server's model
       list, so they are escaped like any other text. */
    /* The relay describes this Mac to the model from what it reports here,
       so nothing about the machine or account is assumed. */
    [body appendFormat:@"],\"tools\":%s,\"provider\":\"%@\",\"model\":\"%@\","
        @"\"client\":{\"machine\":\"%@\",\"os\":\"%@\",\"user\":\"%@\",\"home\":\"%@\"}}",
        [self toolsEnabled:chat] ? "true" : "false",
        TBJSONEscape([self providerForChat:chat]),
        TBJSONEscape([self modelForChat:chat]),
        TBJSONEscape([TBMachine name]), TBJSONEscape([TBMachine systemVersion]),
        TBJSONEscape(NSUserName()), TBJSONEscape(NSHomeDirectory())];
    return body;
}

- (IBAction)send:(id)sender
{
    NSString *text;
    NSMutableDictionary *userMessage;
    NSMutableDictionary *openMessage;
    NSString *title;
    NSText *editor;
    (void)sender;
    if (busy || !current)
        return;
    editor = [input currentEditor];
    if (editor)
        text = [[editor string] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    else
        text = [[input stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([text length] == 0)
        return;
    if (![self providerUsable:[self providerForChat:current]]) {
        NSString *pid = [self providerForChat:current];
        NSString *note = [self providerNote:pid];
        if ([pid isEqualToString:@"local"])
            [self setRelayProblem:@"The local server has no models loaded. Load one, or set the local server in Preferences."];
        else if (!relayReachable)
            [self setRelayProblem:[self relayProblemForRequest:nil]];
        else
            [self setRelayProblem:[NSString stringWithFormat:@"%@ cannot be used (%@). Pick another model or add its key in Preferences.",
                [[ModelCatalog shared] titleForProvider:pid], note ? note : @"unavailable"]];
        NSBeep();
        return;
    }
    [input setStringValue:@""];
    if (editor)
        [editor setString:@""];
    inputHeight = TB_FIELD_MIN;
    [self layoutPanes];
    userMessage = [NSMutableDictionary dictionary];
    [userMessage setObject:@"user" forKey:@"role"];
    [userMessage setObject:text forKey:@"text"];
    [userMessage setObject:[NSNumber numberWithBool:NO] forKey:@"status"];
    [[current objectForKey:@"messages"] addObject:userMessage];
    openMessage = [NSMutableDictionary dictionary];
    [openMessage setObject:@"assistant" forKey:@"role"];
    [openMessage setObject:@"" forKey:@"text"];
    [openMessage setObject:[NSNumber numberWithBool:NO] forKey:@"status"];
    [openMessage setObject:[NSNumber numberWithBool:YES] forKey:@"open"];
    [[current objectForKey:@"messages"] addObject:openMessage];
    title = [current objectForKey:@"title"];
    if ([title isEqualToString:@"New Chat"]) {
        NSString *trimmed = text;
        if ([trimmed length] > 26)
            trimmed = [[trimmed substringToIndex:26] stringByAppendingString:@"..."];
        [current setObject:trimmed forKey:@"title"];
        [self reloadTableSelect:[table selectedRow] show:NO];
    }
    [self saveStore];
    [self refreshTranscriptIfCurrent:current];
    [streamingId release];
    streamingId = [[current objectForKey:@"id"] copy];
    [self setBusy:YES];
    /* A long chat is summarized first; compactionArrived: then starts the stream. */
    if ([self startCompactionIfNeeded])
        return;
    [self beginChatStream];
}

- (void)finishWithoutStream:(NSMutableDictionary *)chat
{
    NSMutableDictionary *open = [self openMessageIn:chat];
    if (open) {
        if ([[open objectForKey:@"text"] length] == 0)
            [[chat objectForKey:@"messages"] removeObject:open];
        else
            [open setObject:[NSNumber numberWithBool:NO] forKey:@"open"];
    }
    [self saveStore];
    [self refreshTranscriptIfCurrent:chat];
    [self setBusy:NO];
}

- (void)beginChatStream
{
    NSMutableDictionary *chat = [self chatWithId:streamingId];
    CFHTTPMessageRef message;
    CFReadStreamRef stream;
    CFStreamClientContext context = { 0, self, NULL, NULL, NULL };
    NSData *payload;
    if (!chat) {
        [self setBusy:NO];
        return;
    }
    [frameBuffer setLength:0];
    [errorBody setLength:0];
    httpStatus = 0;
    [self closeStream];
    payload = [[self requestBodyForChat:chat] dataUsingEncoding:NSUTF8StringEncoding];
    message = [RelayRequest copyMessage:@"POST" path:@"/v1/chat" body:payload];
    if (!message) {
        [self addStatus:@"Set the relay address and token in Preferences first." toChat:chat];
        [self finishWithoutStream:chat];
        return;
    }
    CFHTTPMessageSetHeaderFieldValue(message, CFSTR("X-TigerBuild-Protocol"), CFSTR("frames"));
    stream = CFReadStreamCreateForHTTPRequest(NULL, message);
    CFRelease(message);
    if (!stream || !CFReadStreamSetClient(stream,
            kCFStreamEventHasBytesAvailable | kCFStreamEventEndEncountered | kCFStreamEventErrorOccurred,
            streamCallback, &context)) {
        if (stream)
            CFRelease(stream);
        [self addStatus:@"Could not start the chat connection." toChat:chat];
        [self finishWithoutStream:chat];
        return;
    }
    CFReadStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
    bodyStream = stream;
    if (!CFReadStreamOpen(stream)) {
        [self closeStream];
        [self addStatus:@"Could not open the chat connection." toChat:chat];
        [self finishWithoutStream:chat];
    }
}

- (void)closeStream
{
    CFReadStreamRef stream = (CFReadStreamRef)bodyStream;
    if (!stream)
        return;
    CFReadStreamSetClient(stream, 0, NULL, NULL);
    CFReadStreamUnscheduleFromRunLoop(stream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
    CFReadStreamClose(stream);
    CFRelease(stream);
    bodyStream = NULL;
}

- (void)noteResponseStatus:(CFReadStreamRef)stream
{
    CFHTTPMessageRef response;
    if (httpStatus != 0)
        return;
    response = (CFHTTPMessageRef)CFReadStreamCopyProperty(stream, kCFStreamPropertyHTTPResponseHeader);
    if (!response)
        return;
    httpStatus = CFHTTPMessageGetResponseStatusCode(response);
    CFRelease(response);
}

- (void)handleStream:(CFReadStreamRef)stream event:(CFStreamEventType)type
{
    if (type == kCFStreamEventHasBytesAvailable) {
        UInt8 buf[4096];
        [self noteResponseStatus:stream];
        while (CFReadStreamHasBytesAvailable(stream)) {
            CFIndex count = CFReadStreamRead(stream, buf, sizeof(buf));
            if (count <= 0)
                break;
            if (httpStatus >= 400)
                [errorBody appendBytes:buf length:count];
            else
                [frameBuffer appendBytes:buf length:count];
        }
        if (httpStatus < 400 && streamDepth == 0) {
            streamDepth = 1;
            [self drainFrames];
            streamDepth = 0;
            if (streamEndDeferred) {
                streamEndDeferred = 0;
                [self finishStream];
            }
        }
        return;
    }
    if (type == kCFStreamEventEndEncountered) {
        [self noteResponseStatus:stream];
        if (streamDepth) {
            UInt8 buf[4096];
            while (CFReadStreamHasBytesAvailable(stream)) {
                CFIndex count = CFReadStreamRead(stream, buf, sizeof(buf));
                if (count <= 0)
                    break;
                if (httpStatus >= 400)
                    [errorBody appendBytes:buf length:count];
                else
                    [frameBuffer appendBytes:buf length:count];
            }
            streamEndDeferred = 1;
            return;
        }
        if (httpStatus >= 400) {
            NSString *text = [[NSString alloc] initWithData:errorBody encoding:NSUTF8StringEncoding];
            if (!text || [text length] == 0) {
                [text release];
                text = [[NSString alloc] initWithFormat:@"The chat service returned HTTP %d.", httpStatus];
            if (httpStatus == 401 || httpStatus == 403)
                [self setRelayProblem:(httpStatus == 401
                    ? @"The relay rejected the token. Check the relay token in Preferences."
                    : @"The relay does not accept this Mac's address. Add it to ALLOWED_CLIENTS in the relay's config.sh.")];
            }
            [self addStatus:text toChat:[self chatWithId:streamingId]];
            [text release];
        } else {
            [self drainFrames];
        }
        [self finishStream];
        return;
    }
    if (type == kCFStreamEventErrorOccurred) {
        if (streamDepth) {
            streamEndDeferred = 1;
            return;
        }
        [self addStatus:[NSString stringWithFormat:@"The chat connection to the relay at %@ failed.",
            [self serverBase]] toChat:[self chatWithId:streamingId]];
        [self setRelayProblem:[NSString stringWithFormat:@"Cannot reach the relay at %@. Check that it is "
            @"running and that Preferences has the right address and port.", [self serverBase]]];
        [self finishStream];
    }
}

- (void)finishStream
{
    NSMutableDictionary *chat;
    NSMutableDictionary *open;
    if (!bodyStream)
        return;
    chat = [self chatWithId:streamingId];
    [self closeStream];
    if (chat) {
        open = [self openMessageIn:chat];
        if (open) {
            [open setObject:[NSNumber numberWithBool:NO] forKey:@"open"];
            if ([[open objectForKey:@"text"] length] == 0
                && [open objectForKey:@"image"] == nil
                && [open objectForKey:@"video"] == nil
                && [open objectForKey:@"pendingMedia"] == nil)
                [[chat objectForKey:@"messages"] removeObject:open];
        }
        [self saveStore];
        [self refreshTranscriptIfCurrent:chat];
        [window displayIfNeeded];
        [self updateContextReadout];
    }
    [self setBusy:NO];
    if (chat)
        [self autonameChat:chat];
}

- (void)dispatchFrameKind:(char)kind payload:(NSData *)payload
{
    NSMutableDictionary *chat = [self chatWithId:streamingId];
    NSString *text = nil;
    if (!chat)
        return;
    if (kind != 'd' && [payload length] > 0) {
        text = [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding];
        if (!text)
            text = [[NSString alloc] initWithData:payload encoding:NSMacOSRomanStringEncoding];
    }
    if (kind == 'a') {
        NSString *error=nil;
        NSDictionary *event=[NSPropertyListSerialization propertyListFromData:payload mutabilityOption:NSPropertyListMutableContainers format:NULL errorDescription:&error];
        if(error)[error release];
        if([event isKindOfClass:[NSDictionary class]]) {
            NSMutableArray *messages=[chat objectForKey:@"messages"];NSMutableDictionary *activity=nil;unsigned i;
            for(i=0;i<[messages count];i++) {
                NSMutableDictionary *m=[messages objectAtIndex:i];
                if([[m objectForKey:@"activityID"] isEqualToString:[event objectForKey:@"id"]])activity=m;
            }
            if(!activity) {
                activity=[NSMutableDictionary dictionaryWithObjectsAndKeys:@"status",@"role",[NSNumber numberWithBool:YES],@"status",
                    [event objectForKey:@"id"],@"activityID",@"tool",@"activityKind",nil];
                [messages insertObject:activity atIndex:[messages count]>0?[messages count]-1:0];
            }
            BOOL finished=[[event objectForKey:@"phase"] isEqualToString:@"result"];
            NSString *state=finished?([[event objectForKey:@"failed"] boolValue]?@"Failed":@"Completed"):@"Running";
            [activity setObject:[NSString stringWithFormat:@"%@ - %@%@",[event objectForKey:@"name"],state,
                finished?[NSString stringWithFormat:@" (%.1fs)",[[event objectForKey:@"elapsed"] doubleValue]]:@""] forKey:@"text"];
            [activity setObject:[NSString stringWithFormat:@"%@\n\n%@",[event objectForKey:@"detail"],[event objectForKey:@"output"]] forKey:@"detail"];
            [activity setObject:[event objectForKey:@"failed"] forKey:@"failed"];
            [self refreshTranscriptIfCurrent:chat];
        }
    }
    else if (kind == 'h') {
        NSMutableArray *messages=[chat objectForKey:@"messages"];NSMutableDictionary *thinking=nil;int i;
        for(i=(int)[messages count]-1;i>=0;i--) {
            NSMutableDictionary *m=[messages objectAtIndex:i];
            if([[m objectForKey:@"role"] isEqualToString:@"user"])break;
            if([[m objectForKey:@"activityKind"] isEqualToString:@"thinking"]){thinking=m;break;}
        }
        if(!thinking) {
            thinking=[NSMutableDictionary dictionaryWithObjectsAndKeys:@"status",@"role",[NSNumber numberWithBool:YES],@"status",
                @"thinking",@"activityKind",@"Model thinking (returned summary)",@"text",@"",@"detail",nil];
            [messages insertObject:thinking atIndex:[messages count]>0?[messages count]-1:0];
        }
        [thinking setObject:[[thinking objectForKey:@"detail"] stringByAppendingString:text?text:@""] forKey:@"detail"];
        [self refreshTranscriptIfCurrent:chat];
    }
    else if (kind == 't')
        [self appendDelta:text toChat:chat];
    else if (kind == 'm')
        [self attachMedia:text toChat:chat];
    else if (kind == 's' || kind == 'e')
        [self addStatus:text toChat:chat];
    [text release];
}

- (void)drainFrames
{
    while (1) {
        const unsigned char *bytes = [frameBuffer bytes];
        unsigned length = [frameBuffer length];
        unsigned i;
        char header[80];
        char *space;
        int count;
        char kind;
        if (length == 0)
            return;
        for (i = 0; i < length && i < 70; i++) {
            if (bytes[i] == '\n')
                break;
        }
        if (i >= length)
            return;
        if (i >= 70) {
            [self addStatus:@"The chat service sent a bad stream." toChat:[self chatWithId:streamingId]];
            [frameBuffer setLength:0];
            return;
        }
        memcpy(header, bytes, i);
        header[i] = 0;
        space = strchr(header, ' ');
        if (!space) {
            [self addStatus:@"The chat service sent a bad stream." toChat:[self chatWithId:streamingId]];
            [frameBuffer setLength:0];
            return;
        }
        kind = header[0];
        count = atoi(space + 1);
        if (count < 0 || (unsigned)(i + 1 + count) > 8000000) {
            [self addStatus:@"The chat service sent a bad stream." toChat:[self chatWithId:streamingId]];
            [frameBuffer setLength:0];
            return;
        }
        if (length < (unsigned)(i + 1 + count))
            return;
        {
            NSData *payload = [NSData dataWithBytes:bytes + i + 1 length:count];
            [frameBuffer replaceBytesInRange:NSMakeRange(0, i + 1 + count) withBytes:NULL length:0];
            if (kind == 'd') {
                [self finishStream];
                return;
            }
            [self dispatchFrameKind:kind payload:payload];
        }
    }
}

- (float)inputHeightForWidth:(float)width
{
    NSTextFieldCell *sizer;
    NSString *value;
    NSText *editor;
    NSSize size;
    float height;
    if (!input)
        return 24;
    if (width < 80)
        width = 80;
    editor = [input currentEditor];
    if (editor)
        value = [editor string];
    else
        value = [input stringValue];
    if (!value || [value length] == 0)
        return 24;
    sizer = [[NSTextFieldCell alloc] initTextCell:value];
    [sizer setFont:[input font]];
    [sizer setWraps:YES];
    [sizer setScrollable:NO];
    size = [sizer cellSizeForBounds:NSMakeRect(0, 0, width - 18, 10000)];
    [sizer release];
    height = size.height + 8;
    if (height < 24)
        height = 24;
    if (height > 112)
        height = 112;
    return height;
}

- (void)fitFieldEditor
{
    NSText *editor;
    NSTextView *editorView;
    NSView *parent;
    NSRect interior;
    if (!input)
        return;
    editor = [input currentEditor];
    if (!editor)
        return;
    interior = [[input cell] drawingRectForBounds:[input bounds]];
    parent = [editor superview];
    if (parent && parent != input)
        interior = [input convertRect:interior toView:parent];
    [editor setFrame:interior];
    if (![editor isKindOfClass:[NSTextView class]])
        return;
    editorView = (NSTextView *)editor;
    [editorView setHorizontallyResizable:NO];
    [editorView setVerticallyResizable:NO];
    [editorView setMinSize:interior.size];
    [editorView setMaxSize:interior.size];
    [[editorView textContainer] setWidthTracksTextView:YES];
    [[editorView textContainer] setHeightTracksTextView:YES];
    [[editorView textContainer] setContainerSize:NSMakeSize(NSWidth(interior), NSHeight(interior))];
    if ([parent isKindOfClass:[NSClipView class]] && [[parent superview] isKindOfClass:[NSScrollView class]]) {
        NSScrollView *scroll = (NSScrollView *)[parent superview];
        [scroll setHasHorizontalScroller:NO];
        [scroll setHasVerticalScroller:NO];
    }
}

- (void)controlTextDidChange:(NSNotification *)note
{
    if ([note object] != input)
        return;
    [self layoutPanes];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command
{
    (void)textView;
    if (renameField && control == renameField) {
        if (command == @selector(insertNewline:)) {
            [self commitRename:nil];
            return YES;
        }
        if (command == @selector(cancelOperation:) || command == @selector(cancel:)) {
            [self cancelRename:nil];
            return YES;
        }
        return NO;
    }
    if (command == @selector(insertNewline:)) {
        [self send:nil];
        return YES;
    }
    return NO;
}

@end
