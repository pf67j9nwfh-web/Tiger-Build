#import "ChatController_Private.h"
#import "TranscriptView.h"
#import "TBMarkup.h"

/* Three small things the chat window needed:
     Custom Instructions   text the model is told to follow in this chat (and optionally every new chat in the workspace)
     Find in Chats         search every chat in the workspace and jump to the message
     Text size             bigger or smaller text in the chat, for small or old screens */

/* ---- Find in Chats ---- */

@interface TBFinder : NSObject TB_PROTOCOLS(NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate) {
    NSPanel *panel;
    NSTextField *field;
    NSTableView *table;
    NSMutableArray *results;
    NSTextField *count;
    id owner;
}
- (id)initWithOwner:(id)controller;
- (void)show;
- (void)openRow:(id)sender;
@end

@implementation TBFinder

- (id)initWithOwner:(id)controller
{
    NSScrollView *scroll;
    NSTableColumn *column;
    self = [super init];
    if (!self)
        return nil;
    owner = controller;
    results = [[NSMutableArray alloc] init];
    panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 520, 380)
        styleMask:NSTitledWindowMask | NSClosableWindowMask | NSResizableWindowMask backing:NSBackingStoreBuffered defer:NO];
    [panel setTitle:@"Find in Chats"];
    [panel setReleasedWhenClosed:NO];
    [panel setFloatingPanel:YES];
    [panel setMinSize:NSMakeSize(360, 220)];
    field = [[[NSTextField alloc] initWithFrame:NSMakeRect(14, 346, 492, 22)] autorelease];
    [field setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [field setDelegate:self];
    [[panel contentView] addSubview:field];
    count = [[[NSTextField alloc] initWithFrame:NSMakeRect(14, 8, 492, 16)] autorelease];
    [count setBezeled:NO];
    [count setDrawsBackground:NO];
    [count setEditable:NO];
    [count setSelectable:NO];
    [count setFont:[NSFont systemFontOfSize:11]];
    [count setTextColor:[NSColor colorWithCalibratedWhite:0.35 alpha:1]];
    [count setAutoresizingMask:NSViewWidthSizable | NSViewMaxYMargin];
    [[panel contentView] addSubview:count];
    scroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(14, 32, 492, 304)] autorelease];
    [scroll setHasVerticalScroller:YES];
    [scroll setBorderType:NSBezelBorder];
    [scroll setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    table = [[[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 480, 300)] autorelease];
    column = [[[NSTableColumn alloc] initWithIdentifier:@"hit"] autorelease];
    [column setWidth:470];
    [column setEditable:NO];
    [table addTableColumn:column];
    [table setHeaderView:nil];
    [table setDataSource:self];
    [table setDelegate:self];
    [table setTarget:self];
    [table setDoubleAction:@selector(openRow:)];
    [table setAllowsEmptySelection:YES];
    [scroll setDocumentView:table];
    [[panel contentView] addSubview:scroll];
    return self;
}

- (void)dealloc
{
    [panel release];
    [results release];
    [super dealloc];
}

- (void)show
{
    if (![panel isVisible])
        [panel center];
    [panel setLevel:NSFloatingWindowLevel];
    [panel makeKeyAndOrderFront:nil];
    [panel makeFirstResponder:field];
    [[field currentEditor] selectAll:nil];
}

- (void)controlTextDidChange:(NSNotification *)note
{
    (void)note;
    [results removeAllObjects];
    [results addObjectsFromArray:[owner findResultsFor:[field stringValue]]];
    [table reloadData];
    if ([[field stringValue] length] == 0)
        [count setStringValue:@""];
    else
        [count setStringValue:[NSString stringWithFormat:@"%u match%s%@", (unsigned)[results count], [results count] == 1 ? "" : "es",
            [results count] >= 200 ? @" (first 200 shown)" : @""]];
    if ([results count] > 0)
        [table selectRow:0 byExtendingSelection:NO];
}

/* Return in the search box opens the selected match; the arrows move through them. */
- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)command
{
    (void)control;
    (void)textView;
    if (command == @selector(insertNewline:)) {
        [self openRow:nil];
        return YES;
    }
    if (command == @selector(moveDown:) && [table selectedRow] < (int)[results count] - 1) {
        [table selectRow:[table selectedRow] + 1 byExtendingSelection:NO];
        [table scrollRowToVisible:[table selectedRow]];
        return YES;
    }
    if (command == @selector(moveUp:) && [table selectedRow] > 0) {
        [table selectRow:[table selectedRow] - 1 byExtendingSelection:NO];
        [table scrollRowToVisible:[table selectedRow]];
        return YES;
    }
    return NO;
}

- (void)openRow:(id)sender
{
    int row = [table selectedRow];
    (void)sender;
    if (row >= 0 && row < (int)[results count])
        [owner openFindResult:[results objectAtIndex:row]];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)view
{
    (void)view;
    return (int)[results count];
}

- (id)tableView:(NSTableView *)view objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
    NSDictionary *hit = [results objectAtIndex:row];
    (void)view;
    (void)column;
    return [NSString stringWithFormat:@"%@: %@", [hit objectForKey:@"title"], [hit objectForKey:@"snippet"]];
}

@end

@implementation ChatController (Extras)

/* Every message of every chat in this workspace that has the words in it, newest chats first. */
- (NSArray *)findResultsFor:(NSString *)query
{
    NSMutableArray *found = [NSMutableArray array];
    NSString *needle = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    unsigned c;
    if ([needle length] == 0)
        return found;
    for (c = 0; c < [chats count] && [found count] < 200; c++) {
        NSMutableDictionary *chat = [chats objectAtIndex:c];
        NSArray *messages = [chat objectForKey:@"messages"];
        NSString *title = [chat objectForKey:@"title"];
        unsigned m;
        if ([title rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound && [found count] < 200)
            [found addObject:[NSDictionary dictionaryWithObjectsAndKeys:chat, @"chat", title ? title : @"Chat", @"title", @"(chat title)", @"snippet", nil]];
        for (m = 0; m < [messages count] && [found count] < 200; m++) {
            NSMutableDictionary *message = [messages objectAtIndex:m];
            NSString *text = [message objectForKey:@"detail"] ? [message objectForKey:@"detail"] : [message objectForKey:@"text"];
            NSRange where;
            if ([[message objectForKey:@"status"] boolValue] && ![message objectForKey:@"activityKind"])
                continue;
            if (![text isKindOfClass:[NSString class]])
                continue;
            where = [text rangeOfString:needle options:NSCaseInsensitiveSearch];
            if (where.location != NSNotFound) {
                unsigned from = where.location > 40 ? (unsigned)where.location - 40 : 0;
                unsigned to = MIN([text length], (unsigned)NSMaxRange(where) + 60);
                NSString *snippet = [[[text substringWithRange:NSMakeRange(from, to - from)] componentsSeparatedByString:@"\n"] componentsJoinedByString:@" "];
                if (from > 0)
                    snippet = [@"..." stringByAppendingString:snippet];
                [found addObject:[NSDictionary dictionaryWithObjectsAndKeys:chat, @"chat", message, @"message",
                    title ? title : @"Chat", @"title", snippet, @"snippet", nil]];
            }
        }
    }
    return found;
}

- (void)openFindResult:(NSDictionary *)hit
{
    NSMutableDictionary *chat = [hit objectForKey:@"chat"];
    NSUInteger row = [chats indexOfObjectIdenticalTo:chat];
    if (row == NSNotFound || busy)
        return;
    [self reloadTableSelect:(int)row show:YES];
    if ([hit objectForKey:@"message"])
        [transcript scrollToMessage:[hit objectForKey:@"message"]];
}

- (IBAction)showFind:(id)sender
{
    (void)sender;
    if (!finder)
        finder = [[TBFinder alloc] initWithOwner:self];
    [finder show];
}

/* ---- Custom Instructions ---- */

- (IBAction)editInstructions:(id)sender
{
    NSPanel *panel;
    NSScrollView *scroll;
    NSTextView *view;
    NSButton *everyChat;
    NSButton *ok;
    NSButton *cancel;
    NSTextField *label;
    int result;
    (void)sender;
    if (!current)
        return;
    panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 480, 310) styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
    [panel setTitle:@"Custom Instructions"];
    label = [[[NSTextField alloc] initWithFrame:NSMakeRect(20, 262, 440, 38)] autorelease];
    [label setStringValue:@"Tell the model how to answer in this chat: a role, a tone, what to avoid. It follows these with every message."];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [label setEditable:NO];
    [label setSelectable:NO];
    scroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(20, 84, 440, 170)] autorelease];
    [scroll setHasVerticalScroller:YES];
    [scroll setBorderType:NSBezelBorder];
    view = [[[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 420, 170)] autorelease];
    [view setMinSize:NSMakeSize(0, 170)];
    [view setMaxSize:NSMakeSize(1000000, 1000000)];
    [view setVerticallyResizable:YES];
    [view setHorizontallyResizable:NO];
    [view setAutoresizingMask:NSViewWidthSizable];
    [[view textContainer] setContainerSize:NSMakeSize(420, 1000000)];
    [[view textContainer] setWidthTracksTextView:YES];
    [view setFont:[NSFont systemFontOfSize:13]];
    [view setString:[current objectForKey:@"instructions"] ? [current objectForKey:@"instructions"] : @""];
    [scroll setDocumentView:view];
    everyChat = [[[NSButton alloc] initWithFrame:NSMakeRect(20, 54, 440, 22)] autorelease];
    [everyChat setButtonType:NSSwitchButton];
    [everyChat setTitle:@"Also use these for every new chat in this workspace"];
    [everyChat setState:NSOffState];
    ok = [[[NSButton alloc] initWithFrame:NSMakeRect(380, 12, 80, 28)] autorelease];
    [ok setTitle:@"OK"];
    [ok setBezelStyle:NSRoundedBezelStyle];
    [ok setKeyEquivalent:@"\r"];
    [ok setTarget:self];
    [ok setAction:@selector(endInstructionsOK:)];
    cancel = [[[NSButton alloc] initWithFrame:NSMakeRect(290, 12, 80, 28)] autorelease];
    [cancel setTitle:@"Cancel"];
    [cancel setBezelStyle:NSRoundedBezelStyle];
    [cancel setKeyEquivalent:@"\033"];
    [cancel setTarget:self];
    [cancel setAction:@selector(endInstructionsCancel:)];
    [[panel contentView] addSubview:label];
    [[panel contentView] addSubview:scroll];
    [[panel contentView] addSubview:everyChat];
    [[panel contentView] addSubview:ok];
    [[panel contentView] addSubview:cancel];
    [panel setDefaultButtonCell:[ok cell]];
    [panel center];
    [panel makeFirstResponder:view];
    [panel setLevel:NSFloatingWindowLevel];
    result = [NSApp runModalForWindow:panel];
    [panel orderOut:nil];
    if (result == 1) {
        NSString *text = [[view string] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([text length] > 4000)
            text = [text substringToIndex:4000];
        if ([text length] > 0)
            [current setObject:text forKey:@"instructions"];
        else
            [current removeObjectForKey:@"instructions"];
        if ([everyChat state] == NSOnState) {
            if ([text length] > 0)
                [workspaceSettings setObject:text forKey:@"instructions"];
            else
                [workspaceSettings removeObjectForKey:@"instructions"];
        }
        [self saveStore];
    }
    [panel release];
}

- (void)endInstructionsOK:(id)sender
{
    (void)sender;
    [NSApp stopModalWithCode:1];
}

- (void)endInstructionsCancel:(id)sender
{
    (void)sender;
    [NSApp stopModalWithCode:0];
}

/* ---- text size ---- */

/* The sidebar's chat list, the message box and the thinking line follow the text size too. The popups and
   buttons are drawn by the system at their own fixed size. */
- (void)applyTextScale
{
    float scale = [TranscriptView textScale];
    float box = scale > 1.3f ? 1.3f : scale;
    [table setFont:[NSFont systemFontOfSize:13 * scale]];
    if ([[table tableColumns] count] > 0)
        [[[[table tableColumns] objectAtIndex:0] dataCell] setFont:[NSFont systemFontOfSize:13 * scale]];
    [table setRowHeight:ceilf(20 * (scale > 1.6f ? 1.6f : scale))];
    [table reloadData];
    [input setFont:[NSFont systemFontOfSize:13 * box]];
    [thinkingField setFont:[NSFont systemFontOfSize:11 * box]];
    [self layoutPanes];
}

/* Chat > Copy Last Code Block: for people who cannot click the Copy label in the panel. */
- (IBAction)copyLastCode:(id)sender
{
    NSArray *messages = [current objectForKey:@"messages"];
    int i;
    (void)sender;
    for (i = (int)[messages count] - 1; i >= 0; i--) {
        NSDictionary *message = [messages objectAtIndex:i];
        NSArray *blocks;
        int b;
        if ([[message objectForKey:@"status"] boolValue] || ![[message objectForKey:@"role"] isEqualToString:@"assistant"])
            continue;
        blocks = TBSplitBlocks([message objectForKey:@"text"]);
        for (b = (int)[blocks count] - 1; b >= 0; b--) {
            NSDictionary *block = [blocks objectAtIndex:b];
            if ([[block objectForKey:@"code"] boolValue]) {
                NSPasteboard *board = [NSPasteboard generalPasteboard];
                [board declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
                [board setString:[block objectForKey:@"copy"] ? [block objectForKey:@"copy"] : [block objectForKey:@"text"] forType:NSStringPboardType];
                return;
            }
        }
    }
    NSBeep();
}

- (IBAction)biggerText:(id)sender
{
    (void)sender;
    [TranscriptView setTextScale:[TranscriptView textScale] + 0.1f];
}

- (IBAction)smallerText:(id)sender
{
    (void)sender;
    [TranscriptView setTextScale:[TranscriptView textScale] - 0.1f];
}

- (IBAction)normalTextSize:(id)sender
{
    (void)sender;
    [TranscriptView setTextScale:1.0f];
}

@end
