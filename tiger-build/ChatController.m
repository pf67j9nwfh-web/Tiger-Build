#import "ChatController.h"
#import "TranscriptView.h"
#import <CoreServices/CoreServices.h>

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
- (int)rememberContextLimit;
- (void)refreshLocalModels;
- (void)compactCurrentChatIfNeeded;
- (void)autonameChat:(NSMutableDictionary *)chat;
@end

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

static NSString *jsonEscape(NSString *value)
{
    NSMutableString *out = [NSMutableString string];
    unsigned i;
    unsigned n;
    if (!value)
        value = @"";
    n = [value length];
    for (i = 0; i < n; i++) {
        unichar ch = [value characterAtIndex:i];
        if (ch == '"' || ch == '\\') {
            [out appendString:@"\\"];
            [out appendFormat:@"%C", ch];
        } else if (ch == '\n') {
            [out appendString:@"\\n"];
        } else if (ch == '\r') {
            [out appendString:@"\\r"];
        } else if (ch == '\t') {
            [out appendString:@"\\t"];
        } else if (ch < 32) {
            [out appendFormat:@"\\u%04x", ch];
        } else {
            [out appendFormat:@"%C", ch];
        }
    }
    return out;
}

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

@interface RelayExchange : NSObject {
    NSMutableData *payload;
    int statusCode;
    BOOL finished;
}
- (void)append:(const UInt8 *)bytes length:(int)length;
- (void)noteStatus:(CFReadStreamRef)stream;
- (void)finish;
- (BOOL)finished;
- (int)status;
- (NSString *)text;
@end

@implementation RelayExchange

- (id)init
{
    self = [super init];
    if (!self)
        return nil;
    payload = [[NSMutableData alloc] init];
    return self;
}

- (void)dealloc
{
    [payload release];
    [super dealloc];
}

- (void)append:(const UInt8 *)bytes length:(int)length
{
    if (length > 0)
        [payload appendBytes:bytes length:(unsigned)length];
}

- (void)noteStatus:(CFReadStreamRef)stream
{
    CFHTTPMessageRef response;
    if (statusCode != 0)
        return;
    response = (CFHTTPMessageRef)CFReadStreamCopyProperty(stream, kCFStreamPropertyHTTPResponseHeader);
    if (!response)
        return;
    statusCode = CFHTTPMessageGetResponseStatusCode(response);
    CFRelease(response);
}

- (void)finish
{
    finished = YES;
}

- (BOOL)finished
{
    return finished;
}

- (int)status
{
    return statusCode;
}

- (NSString *)text
{
    NSString *value = [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding];
    if (!value)
        value = [[NSString alloc] initWithData:payload encoding:NSMacOSRomanStringEncoding];
    return [value autorelease];
}

@end

static void relayCallback(CFReadStreamRef stream, CFStreamEventType type, void *info)
{
    RelayExchange *exchange = (RelayExchange *)info;
    if (type == kCFStreamEventHasBytesAvailable) {
        UInt8 buf[4096];
        CFIndex count;
        [exchange noteStatus:stream];
        while (CFReadStreamHasBytesAvailable(stream)) {
            count = CFReadStreamRead(stream, buf, sizeof(buf));
            if (count <= 0)
                break;
            [exchange append:buf length:(int)count];
        }
        return;
    }
    if (type == kCFStreamEventEndEncountered || type == kCFStreamEventErrorOccurred) {
        [exchange noteStatus:stream];
        [exchange finish];
    }
}

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
    nextNumber = 1;
    renameRow = -1;
    sidebarWidth = [[NSUserDefaults standardUserDefaults] floatForKey:@"TigerBuildSidebarWidth"];
    if (sidebarWidth < 160)
        sidebarWidth = 176;
    inputHeight = 24;
    return self;
}

- (void)dealloc
{
    [window release];
    [chats release];
    [frameBuffer release];
    [errorBody release];
    [self closeStream];
    [streamingId release];
    [launchQuestion release];
    [localModels release];
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
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Tiger Build"];
    NSString *old = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/AquaChat"];
    NSString *savedChats;
    NSString *oldSaved;
    NSString *server;
    NSString *oldServer;
    if (![fm fileExistsAtPath:dir] && [fm fileExistsAtPath:old])
        [fm movePath:old toPath:dir handler:nil];
    if (![fm fileExistsAtPath:dir])
        [fm createDirectoryAtPath:dir attributes:nil];
    savedChats = [dir stringByAppendingPathComponent:@"chats.plist"];
    oldSaved = [old stringByAppendingPathComponent:@"chats.plist"];
    server = [dir stringByAppendingPathComponent:@"server.txt"];
    oldServer = [old stringByAppendingPathComponent:@"server.txt"];
    if (![fm fileExistsAtPath:savedChats] && [fm fileExistsAtPath:oldSaved])
        [fm copyPath:oldSaved toPath:savedChats handler:nil];
    if (![fm fileExistsAtPath:server] && [fm fileExistsAtPath:oldServer])
        [fm copyPath:oldServer toPath:server handler:nil];
    return dir;
}

- (NSString *)storePath
{
    return [[self supportDir] stringByAppendingPathComponent:@"chats.plist"];
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
    [chat setObject:@"grok" forKey:@"provider"];
    [chat setObject:@"grok-4.7" forKey:@"model"];
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
                for (i = 0; i < [saved count]; i++)
                    [chats addObject:[saved objectAtIndex:i]];
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
    NSMutableDictionary *root = [NSMutableDictionary dictionary];
    NSString *error = nil;
    NSData *data;
    [root setObject:chats forKey:@"chats"];
    [root setObject:[NSNumber numberWithInt:nextNumber] forKey:@"next"];
    data = [NSPropertyListSerialization dataFromPropertyList:root
                                                      format:NSPropertyListXMLFormat_v1_0
                                            errorDescription:&error];
    if (error)
        [error release];
    if (data)
        [data writeToFile:[self storePath] atomically:YES];
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
        [toolsButton setTitle:@"Commander: On"];
    else
        [toolsButton setTitle:@"Commander: Off"];
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
    NSString *path = [[self supportDir] stringByAppendingPathComponent:@"server.txt"];
    NSString *text = [NSString stringWithContentsOfFile:path];
    if (text)
        text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!text || [text length] == 0)
        text = @"http://10.0.1.231:8765";
    while ([text hasSuffix:@"/"])
        text = [text substringToIndex:[text length] - 1];
    return text;
}

- (void)reportFrame
{
    NSRect screen = [[NSScreen mainScreen] frame];
    NSRect frame = [window frame];
    float top = screen.size.height - NSMaxY(frame);
    fprintf(stderr, "FRAME %d %d %d %d\n", (int)NSMinX(frame), (int)top, (int)NSWidth(frame), (int)NSHeight(frame));
    fflush(stderr);
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
    [window setFrameAutosaveName:@"Tiger Build"];
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
    [toolsButton setTitle:@"Commander: On"];
    [toolsButton setBezelStyle:NSRoundedBezelStyle];
    [toolsButton setTarget:self];
    [toolsButton setAction:@selector(toggleTools:)];
    [sidePane addSubview:toolsButton];

    modelPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 10, 10) pullsDown:NO];
    [modelPopup setTarget:self];
    [modelPopup setAction:@selector(chooseModel:)];
    [modelPopup setFont:[NSFont systemFontOfSize:13]];
    [modelPopup addItemWithTitle:@"Grok"];
    [[modelPopup lastItem] setRepresentedObject:@"grok"];
    [modelPopup addItemWithTitle:@"ChatGPT"];
    [[modelPopup lastItem] setRepresentedObject:@"chatgpt"];
    [modelPopup addItemWithTitle:@"Claude"];
    [[modelPopup lastItem] setRepresentedObject:@"claude"];
    [modelPopup addItemWithTitle:@"Mistral"];
    [[modelPopup lastItem] setRepresentedObject:@"mistral"];
    [modelPopup addItemWithTitle:@"Muse"];
    [[modelPopup lastItem] setRepresentedObject:@"muse"];
    [modelPopup addItemWithTitle:@"Gemini"];
    [[modelPopup lastItem] setRepresentedObject:@"gemini"];
    [modelPopup setToolTip:@"Provider for this chat"];
    [modelPopup addItemWithTitle:@"Local"];
    [[modelPopup lastItem] setRepresentedObject:@"local"];
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
    NSView *label = nil;
    NSArray *subs;
    unsigned i;
    float innerW;
    float innerH;
    float column;
    float fieldW;
    float fieldH;
    float transcriptY;
    float transcriptH;
    float buttonY;
    float maxField;
    float previousH;
    if (layingOut)
        return;
    layingOut = 1;
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
    previousH = NSHeight([input frame]);
    fieldH = [self inputHeightForWidth:fieldW];
    maxField = mainH - 150;
    if (maxField < 24)
        maxField = 24;
    if (maxField > 112)
        maxField = 112;
    if (fieldH > maxField)
        fieldH = maxField;
    inputHeight = fieldH;
    transcriptY = 22 + fieldH;
    if (mainH - 36 - transcriptY < 60)
        transcriptY = mainH - 96;
    if (transcriptY < 22 + fieldH)
        transcriptY = 22 + fieldH;
    buttonY = 14 + (fieldH - 28) / 2;
    if (buttonY < 10)
        buttonY = 10;
    [label setFrame:NSMakeRect(16, sideH - 30, column, 18)];
    [newButton setFrame:NSMakeRect(14, sideH - 58, column, 28)];
    [deleteButton setFrame:NSMakeRect(14, sideH - 94, column, 28)];
    [modelPopup setFrame:NSMakeRect(14, 76, column, 26)];
    [variantPopup setFrame:NSMakeRect(14, 42, column, 26)];
    [toolsButton setFrame:NSMakeRect(14, 8, column, 28)];
    [chatScroll setFrame:NSMakeRect(14, 110, column, sideH - 212)];
    [contextField setFrame:NSMakeRect(8, mainH - 28, mainW - 16, 18)];
    transcriptH = mainH - 28 - transcriptY;
    if (transcriptH < 40)
        transcriptH = 40;
    [transcriptScroll setFrame:NSMakeRect(8, transcriptY, mainW - 16, transcriptH)];
    if (previousH != fieldH || NSWidth([input frame]) != fieldW) {
        [input setFrame:NSMakeRect(8, 14, fieldW, fieldH)];
        [self fitFieldEditor];
        if (previousH != fieldH) {
            [chatPane setNeedsDisplay:YES];
            [transcriptScroll setNeedsDisplay:YES];
            [chatPane display];
        }
    }
    [sendButton setFrame:NSMakeRect(mainW - 88, buttonY, 76, 28)];
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

    NSMenuItem *modelSlot = [[NSMenuItem alloc] init];
    NSMenu *modelMenu = [[NSMenu alloc] initWithTitle:@"Model"];
    [self addModelItem:@"Grok" identifier:@"grok" toMenu:modelMenu];
    [self addModelItem:@"ChatGPT" identifier:@"chatgpt" toMenu:modelMenu];
    [self addModelItem:@"Claude" identifier:@"claude" toMenu:modelMenu];
    [self addModelItem:@"Mistral" identifier:@"mistral" toMenu:modelMenu];
    [self addModelItem:@"Muse" identifier:@"muse" toMenu:modelMenu];
    [self addModelItem:@"Gemini" identifier:@"gemini" toMenu:modelMenu];
    [self addModelItem:@"Local" identifier:@"local" toMenu:modelMenu];
    [modelSlot setSubmenu:modelMenu];
    [modelMenu release];
    [bar addItem:modelSlot];
    [modelSlot release];
    [bar setValue:@"NSMainMenu" forKey:@"name"];
    [appMenu setValue:@"NSAppleMenu" forKey:@"name"];
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
    if ([provider isEqualToString:@"claude"])
        return @"claude-sonnet-5";
    if ([provider isEqualToString:@"chatgpt"])
        return @"gpt-5.5";
    if ([provider isEqualToString:@"mistral"])
        return @"ministral-14b-latest";
    if ([provider isEqualToString:@"muse"])
        return @"muse-spark-1.3";
    if ([provider isEqualToString:@"gemini"])
        return @"gemini-3.8-flash";
    if ([provider isEqualToString:@"local"]) {
        if ([localModels count] > 0)
            return [[localModels objectAtIndex:0] objectForKey:@"id"];
        return @"";
    }
    return @"grok-4.7";
}

- (NSArray *)variantPair:(NSString *)title model:(NSString *)model
{
    return [NSArray arrayWithObjects:title, model, nil];
}

- (NSArray *)variantPairsForProvider:(NSString *)provider
{
    /* Titles and ids match relay/providers.py CATALOG. */
    if ([provider isEqualToString:@"claude"]) {
        return [NSArray arrayWithObjects:
            [self variantPair:@"Opus 5.5" model:@"claude-opus-5-5"],
            [self variantPair:@"Opus 5" model:@"claude-opus-5"],
            [self variantPair:@"Opus 4.8" model:@"claude-opus-4-8"],
            [self variantPair:@"Opus 4.7" model:@"claude-opus-4-7"],
            [self variantPair:@"Opus 4.6" model:@"claude-opus-4-6"],
            [self variantPair:@"Opus 4.5" model:@"claude-opus-4-5-20251101"],
            [self variantPair:@"Fable 5.1" model:@"claude-fable-5-1"],
            [self variantPair:@"Fable 5" model:@"claude-fable-5"],
            [self variantPair:@"Sonnet 5" model:@"claude-sonnet-5"],
            [self variantPair:@"Sonnet 4.6" model:@"claude-sonnet-4-6"],
            [self variantPair:@"Sonnet 4.5" model:@"claude-sonnet-4-5-20250929"],
            [self variantPair:@"Haiku 4.5" model:@"claude-haiku-4-5-20251001"],
            nil];
    }
    if ([provider isEqualToString:@"chatgpt"]) {
        return [NSArray arrayWithObjects:
            [self variantPair:@"6 Astra" model:@"gpt-6-astra"],
            [self variantPair:@"6 Luna" model:@"gpt-6-luna"],
            [self variantPair:@"6 Sol" model:@"gpt-6-sol"],
            [self variantPair:@"5.6 Luna" model:@"gpt-5.6-luna"],
            [self variantPair:@"5.6 Sol" model:@"gpt-5.6-sol"],
            [self variantPair:@"5.6 Terra" model:@"gpt-5.6-terra"],
            [self variantPair:@"5.5" model:@"gpt-5.5"],
            [self variantPair:@"5.5 Pro" model:@"gpt-5.5-pro"],
            [self variantPair:@"5.4" model:@"gpt-5.4"],
            [self variantPair:@"5.4 Mini" model:@"gpt-5.4-mini"],
            [self variantPair:@"5.4 Nano" model:@"gpt-5.4-nano"],
            [self variantPair:@"5.4 Pro" model:@"gpt-5.4-pro"],
            [self variantPair:@"5.2" model:@"gpt-5.2"],
            [self variantPair:@"5.2 Pro" model:@"gpt-5.2-pro"],
            [self variantPair:@"5.1" model:@"gpt-5.1"],
            [self variantPair:@"5" model:@"gpt-5"],
            [self variantPair:@"5 Mini" model:@"gpt-5-mini"],
            [self variantPair:@"5 Nano" model:@"gpt-5-nano"],
            [self variantPair:@"5 Pro" model:@"gpt-5-pro"],
            [self variantPair:@"4.1" model:@"gpt-4.1"],
            [self variantPair:@"4.1 Mini" model:@"gpt-4.1-mini"],
            [self variantPair:@"4.1 Nano" model:@"gpt-4.1-nano"],
            [self variantPair:@"4o" model:@"gpt-4o"],
            [self variantPair:@"4o Mini" model:@"gpt-4o-mini"],
            [self variantPair:@"4 Turbo" model:@"gpt-4-turbo"],
            [self variantPair:@"4" model:@"gpt-4"],
            [self variantPair:@"3.5" model:@"gpt-3.5-turbo"],
            [self variantPair:@"o3" model:@"o3"],
            [self variantPair:@"o4 Mini" model:@"o4-mini"],
            [self variantPair:@"o3 Mini" model:@"o3-mini"],
            [self variantPair:@"o1" model:@"o1"],
            [self variantPair:@"o1 Pro" model:@"o1-pro"],
            [self variantPair:@"Latest" model:@"chat-latest"],
            nil];
    }
    if ([provider isEqualToString:@"mistral"]) {
        return [NSArray arrayWithObjects:
            [self variantPair:@"Ministral 14B" model:@"ministral-14b-latest"],
            [self variantPair:@"Ministral 8B" model:@"ministral-8b-latest"],
            [self variantPair:@"Ministral 3B" model:@"ministral-3b-latest"],
            [self variantPair:@"Codestral" model:@"codestral-latest"],
            [self variantPair:@"Mistral Code" model:@"mistral-code-latest"],
            [self variantPair:@"Voxtral Small" model:@"voxtral-small-latest"],
            nil];
    }
    if ([provider isEqualToString:@"muse"]) {
        return [NSArray arrayWithObjects:
            [self variantPair:@"Spark 1.3" model:@"muse-spark-1.3"],
            [self variantPair:@"1.3 Contributor" model:@"muse-spark-1.3-contributor"],
            [self variantPair:@"Spark 1.2" model:@"muse-spark-1.2"],
            [self variantPair:@"1.2 Contributor" model:@"muse-spark-1.2-contributor"],
            [self variantPair:@"Spark 1.1" model:@"muse-spark-1.1"],
            nil];
    }
    if ([provider isEqualToString:@"gemini"]) {
        return [NSArray arrayWithObjects:
            [self variantPair:@"3.8 Flash" model:@"gemini-3.8-flash"],
            [self variantPair:@"3.7 Flash" model:@"gemini-3.7-flash"],
            [self variantPair:@"3.6 Flash" model:@"gemini-3.6-flash"],
            [self variantPair:@"3.5 Flash" model:@"gemini-3.5-flash"],
            [self variantPair:@"3.5 Flash Lite" model:@"gemini-3.5-flash-lite"],
            [self variantPair:@"3.1 Pro" model:@"gemini-3.1-pro-preview"],
            [self variantPair:@"3.1 Pro Tools" model:@"gemini-3.1-pro-preview-customtools"],
            [self variantPair:@"3.1 Flash Lite" model:@"gemini-3.1-flash-lite"],
            [self variantPair:@"3 Flash" model:@"gemini-3-flash-preview"],
            [self variantPair:@"Gemma 4 31B" model:@"gemma-4-31b-it"],
            [self variantPair:@"Gemma 4 26B" model:@"gemma-4-26b-a4b-it"],
            nil];
    }
    return [NSArray arrayWithObjects:
        [self variantPair:@"4.7" model:@"grok-4.7"],
        [self variantPair:@"4.6" model:@"grok-4.6"],
        [self variantPair:@"4.5" model:@"grok-4.5"],
        [self variantPair:@"4.3" model:@"grok-4.3"],
        [self variantPair:@"4.20 Reasoning" model:@"grok-4.20-0309-reasoning"],
        [self variantPair:@"4.20" model:@"grok-4.20-0309-non-reasoning"],
        [self variantPair:@"Build 0.1" model:@"grok-build-0.1"],
        nil];
}

- (BOOL)model:(NSString *)model allowedForProvider:(NSString *)provider
{
    NSArray *pairs;
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
    pairs = [self variantPairsForProvider:provider];
    for (i = 0; i < (int)[pairs count]; i++) {
        if ([[[pairs objectAtIndex:i] objectAtIndex:1] isEqualToString:model])
            return YES;
    }
    return NO;
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
    NSDictionary *item;
    int i;
    if (!variantPopup)
        return;
    provider = [self providerForChat:current];
    [variantPopup removeAllItems];
    if ([provider isEqualToString:@"local"]) {
        if ([localModels count] == 0)
            [self addVariantTitle:@"No local models" model:@""];
        for (i = 0; i < (int)[localModels count]; i++) {
            item = [localModels objectAtIndex:i];
            [self addVariantTitle:[item objectForKey:@"title"] model:[item objectForKey:@"id"]];
        }
    } else {
        NSArray *pairs;
        NSArray *pair;
        pairs = [self variantPairsForProvider:provider];
        for (i = 0; i < (int)[pairs count]; i++) {
            pair = [pairs objectAtIndex:i];
            [self addVariantTitle:[pair objectAtIndex:0] model:[pair objectAtIndex:1]];
        }
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
    (void)note;
    [self loadStore];
    [self buildWindow];
    [self layoutSubviews];
    [self reloadTableSelect:0 show:YES];
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [window makeFirstResponder:input];
    [window display];
    [self reportFrame];
    [self refreshLocalModels];
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

- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    if ([item action] == @selector(deleteChat:))
        return !busy && [table selectedRow] >= 0;
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
    [input setEnabled:!flag];
    [sendButton setEnabled:!flag];
    [deleteButton setEnabled:!flag];
    [window setTitle:flag ? @"Tiger Build - Sending..." : @"Tiger Build"];
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
    [transcript setMessages:[chat objectForKey:@"messages"]];
    [transcript scrollToEnd];
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
        version = @"1.0";
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

- (NSString *)relayPath:(NSString *)path method:(NSString *)method body:(NSString *)body timeout:(double)timeout status:(int *)status
{
    RelayExchange *exchange;
    NSURL *url;
    CFHTTPMessageRef message;
    CFReadStreamRef stream;
    CFStreamClientContext context;
    NSData *payload = nil;
    double start;
    NSString *text;
    if (status)
        *status = 0;
    url = [NSURL URLWithString:[[self serverBase] stringByAppendingString:path]];
    if (!url)
        return nil;
    exchange = [[RelayExchange alloc] init];
    if (body)
        payload = [body dataUsingEncoding:NSUTF8StringEncoding];
    message = CFHTTPMessageCreateRequest(NULL, (CFStringRef)method, (CFURLRef)url, kCFHTTPVersion1_0);
    if (payload) {
        CFHTTPMessageSetBody(message, (CFDataRef)payload);
        CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Content-Type"), CFSTR("application/json; charset=utf-8"));
        CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Content-Length"),
            (CFStringRef)[NSString stringWithFormat:@"%u", (unsigned)[payload length]]);
    }
    CFHTTPMessageSetHeaderFieldValue(message, CFSTR("User-Agent"), CFSTR("TigerBuild/1.0"));
    stream = CFReadStreamCreateForHTTPRequest(NULL, message);
    CFRelease(message);
    if (!stream) {
        [exchange release];
        return nil;
    }
    memset(&context, 0, sizeof(context));
    context.info = exchange;
    CFReadStreamSetClient(stream,
        kCFStreamEventHasBytesAvailable | kCFStreamEventEndEncountered | kCFStreamEventErrorOccurred,
        relayCallback, &context);
    CFReadStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    if (!CFReadStreamOpen(stream)) {
        CFReadStreamSetClient(stream, 0, NULL, NULL);
        CFReadStreamUnscheduleFromRunLoop(stream, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        CFRelease(stream);
        [exchange release];
        return nil;
    }
    start = CFAbsoluteTimeGetCurrent();
    while (![exchange finished]) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, true);
        if (CFAbsoluteTimeGetCurrent() - start > timeout)
            break;
    }
    CFReadStreamSetClient(stream, 0, NULL, NULL);
    CFReadStreamUnscheduleFromRunLoop(stream, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    CFReadStreamClose(stream);
    CFRelease(stream);
    if (status)
        *status = [exchange status];
    text = [exchange text];
    [exchange release];
    return text;
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
    NSArray *messages = [chat objectForKey:@"messages"];
    unsigned i;
    int chars = 0;
    for (i = 0; i < [messages count]; i++) {
        NSDictionary *message = [messages objectAtIndex:i];
        NSString *text;
        if ([[message objectForKey:@"status"] boolValue])
            continue;
        text = [message objectForKey:@"text"];
        chars += (int)[text length];
    }
    if (chars < 4)
        return 1;
    return chars / 4;
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
    NSString *text;
    int status = 0;
    int limit = 0;
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
    }
    if (limit <= 0 && [model length] > 0) {
        text = [self relayPath:[NSString stringWithFormat:@"/v1/context?provider=%@&model=%@",
                [self urlEncode:provider], [self urlEncode:model]]
            method:@"GET" body:nil timeout:8 status:&status];
        if (status == 200 && text)
            limit = [text intValue];
    }
    if (limit <= 0)
        limit = 32000;
    [current setObject:[NSNumber numberWithInt:limit] forKey:@"contextLimit"];
    return limit;
}

- (void)refreshLocalModels
{
    NSString *text;
    NSArray *lines;
    unsigned i;
    int status = 0;
    [localModels removeAllObjects];
    text = [self relayPath:@"/v1/local-models" method:@"GET" body:nil timeout:12 status:&status];
    if (status != 200 || !text)
        return;
    lines = [text componentsSeparatedByString:@"\n"];
    for (i = 0; i < [lines count]; i++) {
        NSString *line = [lines objectAtIndex:i];
        NSArray *parts;
        NSMutableDictionary *item;
        if ([line length] == 0)
            continue;
        parts = [line componentsSeparatedByString:@"\t"];
        if ([parts count] < 2)
            continue;
        if ([[parts objectAtIndex:0] isEqualToString:@"error"])
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
    if (current && [[self providerForChat:current] isEqualToString:@"local"]) {
        if (![self model:[current objectForKey:@"model"] allowedForProvider:@"local"])
            [current setObject:[self defaultModelForProvider:@"local"] forKey:@"model"];
        [current removeObjectForKey:@"contextLimit"];
        [self syncModelMenu];
        [self rememberContextLimit];
        [self updateContextReadout];
    }
}

- (void)compactCurrentChatIfNeeded
{
    NSMutableArray *messages;
    NSMutableArray *spoken;
    NSMutableArray *older;
    NSMutableString *earlier;
    NSMutableString *body;
    NSMutableDictionary *summary;
    NSString *text;
    unsigned i;
    int limit;
    int used;
    int status = 0;
    BOOL inserted;
    if (!current)
        return;
    limit = [self rememberContextLimit];
    used = [self estimatedTokens:current];
    if (limit < 1000 || (long)used * 100 < (long)limit * 85)
        return;
    messages = [current objectForKey:@"messages"];
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
        return;
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
    [body appendString:jsonEscape(earlier)];
    [body appendFormat:@"\"}],\"tools\":false,\"provider\":\"%@\",\"model\":\"%@\"}",
        [self providerForChat:current], [self modelForChat:current]];
    text = [self relayPath:@"/v1/summarize" method:@"POST" body:body timeout:90 status:&status];
    if (status != 200 || !text || [text length] == 0) {
        [self addStatus:@"Could not compact this chat." toChat:current];
        return;
    }
    summary = [NSMutableDictionary dictionary];
    [summary setObject:@"assistant" forKey:@"role"];
    [summary setObject:[NSString stringWithFormat:@"Earlier in this chat:\n%@", text] forKey:@"text"];
    [summary setObject:[NSNumber numberWithBool:NO] forKey:@"status"];
    {
        NSMutableArray *rebuilt = [NSMutableArray array];
        inserted = NO;
        for (i = 0; i < [messages count]; i++) {
            NSDictionary *message = [messages objectAtIndex:i];
            unsigned j;
            BOOL drop = NO;
            for (j = 0; j < [older count]; j++) {
                if ([older objectAtIndex:j] == message)
                    drop = YES;
            }
            if (drop) {
                if (!inserted) {
                    [rebuilt addObject:summary];
                    inserted = YES;
                }
                continue;
            }
            [rebuilt addObject:message];
        }
        [messages setArray:rebuilt];
    }
    [self saveStore];
    [self refreshTranscriptIfCurrent:current];
    [self updateContextReadout];
}

- (void)autonameChat:(NSMutableDictionary *)chat
{
    NSArray *messages;
    NSString *userText = nil;
    NSString *assistantText = nil;
    NSString *text;
    NSMutableString *body;
    NSString *prompt;
    id flag;
    int i;
    int status = 0;
    if (!chat)
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
    [body appendString:jsonEscape(prompt)];
    [body appendFormat:@"\"}],\"tools\":false,\"provider\":\"%@\",\"model\":\"%@\"}",
        [self providerForChat:chat], [self modelForChat:chat]];
    naming = YES;
    suppressSelection = YES;
    [table reloadData];
    suppressSelection = NO;
    text = [self relayPath:@"/v1/title" method:@"POST" body:body timeout:40 status:&status];
    naming = NO;
    suppressSelection = YES;
    [table reloadData];
    suppressSelection = NO;
    if (status != 200 || !text)
        return;
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([text length] == 0 || [text isEqualToString:@"New Chat"])
        return;
    if ([text length] > 80)
        text = [text substringToIndex:80];
    flag = [chat objectForKey:@"autoTitle"];
    if (flag && ![flag boolValue])
        return;
    [chat setObject:text forKey:@"title"];
    [chat setObject:[NSNumber numberWithBool:NO] forKey:@"autoTitle"];
    [self saveStore];
    [table reloadData];
}

- (void)loadPreferenceForm
{
    NSString *text;
    NSArray *lines;
    unsigned i;
    int status = 0;
    text = [self relayPath:@"/v1/settings" method:@"GET" body:nil timeout:8 status:&status];
    if (status != 200 || !text)
        return;
    lines = [text componentsSeparatedByString:@"\n"];
    for (i = 0; i < [lines count]; i++) {
        NSString *line = [lines objectAtIndex:i];
        NSRange equals;
        NSString *name;
        NSString *value;
        NSTextField *field;
        NSTextField *note;
        if ([line length] == 0)
            continue;
        equals = [line rangeOfString:@"="];
        if (equals.location == NSNotFound)
            continue;
        name = [line substringToIndex:equals.location];
        value = [line substringFromIndex:equals.location + 1];
        field = [prefsFields objectForKey:name];
        note = [prefsFields objectForKey:[name stringByAppendingString:@".note"]];
        if ([name isEqualToString:@"local_url"]) {
            if (field)
                [field setStringValue:value];
            continue;
        }
        if (note)
            [note setStringValue:[value isEqualToString:@"1"] ? @"saved" : @""];
        if (field)
            [field setStringValue:@""];
    }
}

- (void)savePreferences:(id)sender
{
    NSArray *keys;
    NSMutableString *body;
    NSString *text;
    unsigned i;
    BOOL first = YES;
    int status = 0;
    (void)sender;
    keys = [NSArray arrayWithObjects:
        @"xai_api_key", @"openai_api_key", @"anthropic_api_key",
        @"anthropic_workspace_id", @"mistral_api_key", @"muse_api_key",
        @"gemini_api_key", @"local_api_key", @"local_url", nil];
    body = [NSMutableString stringWithString:@"{"];
    for (i = 0; i < [keys count]; i++) {
        NSString *key = [keys objectAtIndex:i];
        NSTextField *field = [prefsFields objectForKey:key];
        NSString *value;
        if (!field)
            continue;
        value = [[field stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([value length] == 0)
            continue;
        if (!first)
            [body appendString:@","];
        first = NO;
        [body appendFormat:@"\"%@\":\"%@\"", key, jsonEscape(value)];
    }
    [body appendString:@"}"];
    text = [self relayPath:@"/v1/settings" method:@"POST" body:body timeout:12 status:&status];
    if (status != 200) {
        NSRunAlertPanel(@"Preferences", @"The relay did not save the settings.", @"OK", nil, nil);
        return;
    }
    (void)text;
    [self loadPreferenceForm];
    [self refreshLocalModels];
    [prefsWindow orderOut:nil];
}

- (void)cancelPreferences:(id)sender
{
    (void)sender;
    [prefsWindow orderOut:nil];
}

- (void)showPreferences:(id)sender
{
    NSArray *rows;
    NSView *view;
    unsigned i;
    (void)sender;
    if (!prefsWindow) {
        NSButton *saveButton;
        NSButton *cancelButton;
        prefsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 560, 448)
                                                   styleMask:NSTitledWindowMask | NSClosableWindowMask
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
        [prefsWindow setTitle:@"Preferences"];
        [prefsWindow center];
        view = [prefsWindow contentView];
        rows = [NSArray arrayWithObjects:
            [NSArray arrayWithObjects:@"xAI API key", @"xai_api_key", @"1", nil],
            [NSArray arrayWithObjects:@"OpenAI API key", @"openai_api_key", @"1", nil],
            [NSArray arrayWithObjects:@"Anthropic API key", @"anthropic_api_key", @"1", nil],
            [NSArray arrayWithObjects:@"Anthropic workspace", @"anthropic_workspace_id", @"0", nil],
            [NSArray arrayWithObjects:@"Mistral API key", @"mistral_api_key", @"1", nil],
            [NSArray arrayWithObjects:@"Muse API key", @"muse_api_key", @"1", nil],
            [NSArray arrayWithObjects:@"Gemini API key", @"gemini_api_key", @"1", nil],
            [NSArray arrayWithObjects:@"Local API key", @"local_api_key", @"1", nil],
            [NSArray arrayWithObjects:@"Local server", @"local_url", @"0", nil],
            nil];
        for (i = 0; i < [rows count]; i++) {
            NSArray *row = [rows objectAtIndex:i];
            NSTextField *label;
            NSTextField *field;
            NSTextField *note;
            float y = 400 - (float)i * 38;
            label = [[NSTextField alloc] initWithFrame:NSMakeRect(16, y, 150, 22)];
            [label setStringValue:[row objectAtIndex:0]];
            [label setEditable:NO];
            [label setSelectable:NO];
            [label setBezeled:NO];
            [label setDrawsBackground:NO];
            [label setFont:[NSFont systemFontOfSize:12]];
            [view addSubview:label];
            [label release];
            if ([[row objectAtIndex:2] isEqualToString:@"1"])
                field = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(170, y, 280, 24)];
            else
                field = [[NSTextField alloc] initWithFrame:NSMakeRect(170, y, 280, 24)];
            [field setEditable:YES];
            [field setSelectable:YES];
            [field setBezeled:YES];
            [field setFont:[NSFont systemFontOfSize:12]];
            [view addSubview:field];
            [prefsFields setObject:field forKey:[row objectAtIndex:1]];
            [field release];
            note = [[NSTextField alloc] initWithFrame:NSMakeRect(458, y, 80, 22)];
            [note setEditable:NO];
            [note setSelectable:NO];
            [note setBezeled:NO];
            [note setDrawsBackground:NO];
            [note setFont:[NSFont systemFontOfSize:12]];
            [view addSubview:note];
            [prefsFields setObject:note forKey:[[row objectAtIndex:1] stringByAppendingString:@".note"]];
            [note release];
        }
        saveButton = [[NSButton alloc] initWithFrame:NSMakeRect(360, 16, 90, 28)];
        [saveButton setTitle:@"Save"];
        [saveButton setBezelStyle:NSRoundedBezelStyle];
        [saveButton setTarget:self];
        [saveButton setAction:@selector(savePreferences:)];
        [view addSubview:saveButton];
        [saveButton release];
        cancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(456, 16, 90, 28)];
        [cancelButton setTitle:@"Cancel"];
        [cancelButton setBezelStyle:NSRoundedBezelStyle];
        [cancelButton setTarget:self];
        [cancelButton setAction:@selector(cancelPreferences:)];
        [view addSubview:cancelButton];
        [cancelButton release];
    }
    [self loadPreferenceForm];
    [prefsWindow makeKeyAndOrderFront:nil];
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
        [body appendFormat:@"{\"role\":\"%@\",\"content\":\"%@\"}", role, jsonEscape(text)];
    }
    [body appendFormat:@"],\"tools\":%s,\"provider\":\"%@\",\"model\":\"%@\"}",
        [self toolsEnabled:chat] ? "true" : "false",
        [self providerForChat:chat],
        [self modelForChat:chat]];
    return body;
}

- (IBAction)send:(id)sender
{
    NSString *text;
    NSMutableDictionary *userMessage;
    NSMutableDictionary *openMessage;
    NSString *title;
    NSString *body;
    NSURL *url;
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
    [input setStringValue:@""];
    if (editor)
        [editor setString:@""];
    inputHeight = 24;
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
    [self compactCurrentChatIfNeeded];
    body = [self requestBodyForChat:current];
    url = [NSURL URLWithString:[[self serverBase] stringByAppendingString:@"/v1/chat"]];
    [frameBuffer setLength:0];
    [errorBody setLength:0];
    httpStatus = 0;
    [self closeStream];
    {
        CFHTTPMessageRef message;
        CFReadStreamRef stream;
        CFStreamClientContext context = { 0, self, NULL, NULL, NULL };
        NSData *payload = [body dataUsingEncoding:NSUTF8StringEncoding];
        message = CFHTTPMessageCreateRequest(NULL, CFSTR("POST"), (CFURLRef)url, kCFHTTPVersion1_0);
        CFHTTPMessageSetBody(message, (CFDataRef)payload);
        CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Content-Type"), CFSTR("application/json; charset=utf-8"));
        CFHTTPMessageSetHeaderFieldValue(message, CFSTR("X-AquaChat-Protocol"), CFSTR("frames"));
        CFHTTPMessageSetHeaderFieldValue(message, CFSTR("User-Agent"), CFSTR("TigerBuild/1.0"));
        CFHTTPMessageSetHeaderFieldValue(message, CFSTR("Content-Length"), (CFStringRef)[NSString stringWithFormat:@"%u", (unsigned)[payload length]]);
        stream = CFReadStreamCreateForHTTPRequest(NULL, message);
        CFRelease(message);
        if (!stream || !CFReadStreamSetClient(stream,
                kCFStreamEventHasBytesAvailable | kCFStreamEventEndEncountered | kCFStreamEventErrorOccurred,
                streamCallback, &context)) {
            if (stream)
                CFRelease(stream);
            [self addStatus:@"Could not start the chat connection." toChat:current];
            [self setBusy:NO];
            return;
        }
        CFReadStreamScheduleWithRunLoop(stream, CFRunLoopGetCurrent(), kCFRunLoopCommonModes);
        bodyStream = stream;
        if (!CFReadStreamOpen(stream)) {
            [self addStatus:@"Could not open the chat connection." toChat:current];
            [self closeStream];
            [self setBusy:NO];
            return;
        }
    }
    [self setBusy:YES];
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
        if (httpStatus < 400)
            [self drainFrames];
        return;
    }
    if (type == kCFStreamEventEndEncountered) {
        [self noteResponseStatus:stream];
        if (httpStatus >= 400) {
            NSString *text = [[NSString alloc] initWithData:errorBody encoding:NSUTF8StringEncoding];
            if (!text || [text length] == 0) {
                [text release];
                text = [[NSString alloc] initWithFormat:@"The chat service returned HTTP %d.", httpStatus];
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
        [self addStatus:@"The chat connection failed." toChat:[self chatWithId:streamingId]];
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
            if ([[open objectForKey:@"text"] length] == 0)
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
    fprintf(stderr, "STREAMDONE\n");
    fflush(stderr);
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
    if (kind == 't')
        [self appendDelta:text toChat:chat];
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
