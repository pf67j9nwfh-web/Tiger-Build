#import "ChatController_Private.h"
#import "TranscriptView.h"

/* Bookmarks: a star on any message (right-click, Bookmark This Message); the Chat menu lists them and jumps to one. */

@implementation ChatController (Bookmarks)

- (void)bookmarkMessage:(NSMutableDictionary *)message
{
    if (![message isKindOfClass:[NSMutableDictionary class]])
        return;
    if ([[message objectForKey:@"bookmark"] boolValue])
        [message removeObjectForKey:@"bookmark"];
    else
        [message setObject:[NSNumber numberWithBool:YES] forKey:@"bookmark"];
    [self saveStore];
    [self refreshTranscriptIfCurrent:current];
}

/* Chat, Bookmark Last Message: for a Mac with no right button, or when the star is hard to hit */
- (IBAction)bookmarkLastMessage:(id)sender
{
    NSArray *messages = [current objectForKey:@"messages"];
    int i;
    (void)sender;
    for (i = (int)[messages count] - 1; i >= 0; i--) {
        NSMutableDictionary *message = [messages objectAtIndex:i];
        if ([[message objectForKey:@"status"] boolValue] || [message objectForKey:@"activityKind"] || [[message objectForKey:@"text"] length] == 0)
            continue;
        [self bookmarkMessage:message];
        return;
    }
}

- (NSArray *)bookmarkHits { return [self bookmarkHitsLimit:40 matching:nil]; }

/* Every bookmarked message: chat, message, a label for lists, and the note (or ""). With words given, only those whose chat title, note or text has them. */
- (NSArray *)bookmarkHitsLimit:(unsigned)limit matching:(NSString *)words
{
    NSMutableArray *found = [NSMutableArray array];
    NSString *needle = [words stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    unsigned c, m;
    for (c = 0; c < [chats count] && [found count] < limit; c++) {
        NSMutableDictionary *chat = [chats objectAtIndex:c];
        NSArray *messages = [chat objectForKey:@"messages"];
        for (m = 0; m < [messages count] && [found count] < limit; m++) {
            NSMutableDictionary *message = [messages objectAtIndex:m];
            NSString *text, *title = [chat objectForKey:@"title"], *note = [message objectForKey:@"bookmarkNote"];
            if (![[message objectForKey:@"bookmark"] boolValue])
                continue;
            if ([needle length] && [title rangeOfString:needle options:NSCaseInsensitiveSearch].location == NSNotFound && [note rangeOfString:needle options:NSCaseInsensitiveSearch].location == NSNotFound
                && [[message objectForKey:@"text"] rangeOfString:needle options:NSCaseInsensitiveSearch].location == NSNotFound)
                continue;
            text = [[[message objectForKey:@"text"] componentsSeparatedByString:@"\n"] componentsJoinedByString:@" "];
            if ([text length] > 50)
                text = [[text substringToIndex:50] stringByAppendingString:@"..."];
            [found addObject:[NSDictionary dictionaryWithObjectsAndKeys:chat, @"chat", message, @"message",
                [NSString stringWithFormat:@"%@: %@", [title length] ? title : @"Chat", [note length] ? note : (text ? text : @"")], @"label", note ? note : @"", @"note",
                title ? title : @"Chat", @"title", [note length] ? note : (text ? text : @""), @"snippet", nil]];
        }
    }
    return found;
}

- (void)fillBookmarksMenu:(NSMenu *)menu
{
    NSArray *hits = [self bookmarkHits];
    unsigned i;
    while ([menu numberOfItems] > 0)
        [menu removeItemAtIndex:0];
    if (![hits count]) {
        NSMenuItem *none = [[[NSMenuItem alloc] initWithTitle:@"No Bookmarks (click the star beside a message)" action:NULL keyEquivalent:@""] autorelease];
        [none setEnabled:NO];
        [menu addItem:none];
        {
            NSMenuItem *manage = [[[NSMenuItem alloc] initWithTitle:@"Manage Bookmarks..." action:@selector(showBookmarkManager:) keyEquivalent:@""] autorelease];
            [manage setTarget:self];
            [menu addItem:manage];
        }
        return;
    }
    for (i = 0; i < [hits count]; i++) {
        NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:[[hits objectAtIndex:i] objectForKey:@"label"] action:@selector(openBookmark:) keyEquivalent:@""] autorelease];
        [item setTarget:self];
        [item setRepresentedObject:[hits objectAtIndex:i]];
        [menu addItem:item];
    }
    [menu addItem:[NSMenuItem separatorItem]];
    {
        NSMenuItem *manage = [[[NSMenuItem alloc] initWithTitle:@"Manage Bookmarks..." action:@selector(showBookmarkManager:) keyEquivalent:@""] autorelease];
        [manage setTarget:self];
        [menu addItem:manage];
    }
    {
        NSMenuItem *clear = [[[NSMenuItem alloc] initWithTitle:@"Remove All Bookmarks..." action:@selector(removeAllBookmarks:) keyEquivalent:@""] autorelease];
        [clear setTarget:self];
        [menu addItem:clear];
    }
}

- (void)openBookmark:(id)sender
{
    [self openFindResult:[sender representedObject]];
}

- (void)removeAllBookmarks:(id)sender
{
    unsigned c, m;
    (void)sender;
    if (NSRunAlertPanel(@"Remove all bookmarks?", @"The messages stay; only the stars go.", @"Remove", @"Cancel", nil) != NSAlertDefaultReturn)
        return;
    for (c = 0; c < [chats count]; c++) {
        NSArray *messages = [[chats objectAtIndex:c] objectForKey:@"messages"];
        for (m = 0; m < [messages count]; m++)
            [[messages objectAtIndex:m] removeObjectForKey:@"bookmark"];
    }
    [self saveStore];
    [self refreshTranscriptIfCurrent:current];
}


/* ---- a note on a bookmark ---- */

/* YES and the note typed, or NO. An empty note clears it. */
- (BOOL)askBookmarkNote:(NSString **)note
{
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 420, 120) styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
    NSTextField *label = [[[NSTextField alloc] initWithFrame:NSMakeRect(20, 84, 380, 18)] autorelease];
    NSTextField *field = [[[NSTextField alloc] initWithFrame:NSMakeRect(20, 54, 380, 22)] autorelease];
    NSButton *ok = [[[NSButton alloc] initWithFrame:NSMakeRect(320, 12, 80, 28)] autorelease];
    NSButton *cancel = [[[NSButton alloc] initWithFrame:NSMakeRect(230, 12, 80, 28)] autorelease];
    int result;
    [panel setTitle:@"Bookmark Note"];
    [label setStringValue:@"A note to find this by (optional):"];
    [label setBezeled:NO]; [label setDrawsBackground:NO]; [label setEditable:NO]; [label setSelectable:NO];
    [field setStringValue:*note ? *note : @""];
    [ok setTitle:@"OK"]; [ok setBezelStyle:NSRoundedBezelStyle]; [ok setKeyEquivalent:@"\r"];
    [ok setTarget:self]; [ok setAction:@selector(endInstructionsOK:)];
    [cancel setTitle:@"Cancel"]; [cancel setBezelStyle:NSRoundedBezelStyle]; [cancel setKeyEquivalent:@"\033"];
    [cancel setTarget:self]; [cancel setAction:@selector(endInstructionsCancel:)];
    [[panel contentView] addSubview:label]; [[panel contentView] addSubview:field];
    [[panel contentView] addSubview:ok]; [[panel contentView] addSubview:cancel];
    [panel setDefaultButtonCell:[ok cell]];
    [panel center];
    [panel makeFirstResponder:field];
    [panel setLevel:NSFloatingWindowLevel];
    result = [NSApp runModalForWindow:panel];
    [panel orderOut:nil];
    if (result == 1)
        *note = [[field stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [panel release];
    return result == 1;
}

- (void)setBookmarkNoteOfMessage:(NSMutableDictionary *)message
{
    NSString *note = [message objectForKey:@"bookmarkNote"];
    if (![self askBookmarkNote:&note])
        return;
    if ([note length] > 200)
        note = [note substringToIndex:200];
    if ([note length])
        [message setObject:note forKey:@"bookmarkNote"];
    else
        [message removeObjectForKey:@"bookmarkNote"];
    if (![[message objectForKey:@"bookmark"] boolValue] && [note length])
        [message setObject:[NSNumber numberWithBool:YES] forKey:@"bookmark"];
    [self saveStore];
    [self refreshTranscriptIfCurrent:current];
}

- (NSMutableDictionary *)currentChatForBookmarks { return current; }

@end

/* ---- Chat, Manage Bookmarks...: every bookmark in the workspace, searchable, with notes ---- */

@interface TBBookmarkWindow : NSObject TB_PROTOCOLS(NSTextFieldDelegate, NSTableViewDataSource) {
    ChatController *owner;
    NSPanel *panel;
    NSTextField *field;
    NSTableView *table;
    NSArray *rows;
}
- (id)initWithOwner:(ChatController *)controller;
- (void)show;
@end

static TBBookmarkWindow *bookmarkWindow = nil;

@implementation TBBookmarkWindow

- (void)reload
{
    [rows release];
    rows = [[owner bookmarkHitsLimit:500 matching:[field stringValue]] retain];
    [table reloadData];
}

- (id)initWithOwner:(ChatController *)controller
{
    NSScrollView *scroll;
    NSTableColumn *column;
    NSArray *titles = [NSArray arrayWithObjects:@"Go To", @"Note...", @"Remove", nil];
    SEL actions[3] = { @selector(goTo:), @selector(editNote:), @selector(removeSelected:) };
    int i;
    self = [super init];
    owner = controller;
    panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 560, 380) styleMask:NSTitledWindowMask | NSClosableWindowMask | NSResizableWindowMask backing:NSBackingStoreBuffered defer:NO];
    [panel setTitle:@"Bookmarks"];
    [panel setReleasedWhenClosed:NO];
    [panel setFloatingPanel:YES];
    [panel setMinSize:NSMakeSize(420, 240)];
    field = [[[NSTextField alloc] initWithFrame:NSMakeRect(14, 346, 532, 22)] autorelease];
    [[field cell] setPlaceholderString:@"Search bookmarks"];
    [field setAutoresizingMask:NSViewWidthSizable | NSViewMinYMargin];
    [field setDelegate:self];
    [[panel contentView] addSubview:field];
    scroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(14, 48, 532, 288)] autorelease];
    [scroll setHasVerticalScroller:YES]; [scroll setBorderType:NSBezelBorder];
    [scroll setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    table = [[[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 520, 288)] autorelease];
    column = [[[NSTableColumn alloc] initWithIdentifier:@"b"] autorelease];
    [column setWidth:510]; [column setEditable:NO];
    [table addTableColumn:column];
    [table setHeaderView:nil];
    [table setDataSource:self];
    [table setTarget:self];
    [table setDoubleAction:@selector(goTo:)];
    [scroll setDocumentView:table];
    [[panel contentView] addSubview:scroll];
    for (i = 0; i < 3; i++) {
        NSButton *b = [[[NSButton alloc] initWithFrame:NSMakeRect(14 + i * 96, 12, 90, 28)] autorelease];
        [b setTitle:[titles objectAtIndex:i]]; [b setBezelStyle:NSRoundedBezelStyle];
        [b setTarget:self]; [b setAction:actions[i]];
        [b setAutoresizingMask:NSViewMaxXMargin | NSViewMaxYMargin];
        [[panel contentView] addSubview:b];
    }
    return self;
}

- (void)dealloc
{
    [rows release];
    [panel release];
    [super dealloc];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)view { (void)view; return [rows count]; }

- (id)tableView:(NSTableView *)view objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
    NSDictionary *hit = [rows objectAtIndex:row];
    NSString *text = [[[[hit objectForKey:@"message"] objectForKey:@"text"] componentsSeparatedByString:@"\n"] componentsJoinedByString:@" "];
    NSString *note = [hit objectForKey:@"note"];
    (void)view; (void)column;
    if ([text length] > 90)
        text = [[text substringToIndex:90] stringByAppendingString:@"..."];
    return [note length] ? [NSString stringWithFormat:@"%C %@: %@  (%@)", (unichar)0x2605, [hit objectForKey:@"title"], note, text]
                         : [NSString stringWithFormat:@"%C %@: %@", (unichar)0x2605, [hit objectForKey:@"title"], text];
}

- (void)controlTextDidChange:(NSNotification *)note { (void)note; [self reload]; }

- (NSDictionary *)selected
{
    int row = [table selectedRow];
    return row >= 0 && row < (int)[rows count] ? [rows objectAtIndex:row] : nil;
}

- (void)goTo:(id)sender
{
    NSDictionary *hit = [self selected];
    (void)sender;
    if (hit)
        [owner openFindResult:hit];
}

- (void)editNote:(id)sender
{
    NSDictionary *hit = [self selected];
    (void)sender;
    if (!hit)
        return;
    [owner setBookmarkNoteOfMessage:[hit objectForKey:@"message"]];
    [self reload];
}

- (void)removeSelected:(id)sender
{
    NSDictionary *hit = [self selected];
    (void)sender;
    if (!hit)
        return;
    [[hit objectForKey:@"message"] removeObjectForKey:@"bookmark"];
    [[hit objectForKey:@"message"] removeObjectForKey:@"bookmarkNote"];
    [owner saveStore];
    [owner refreshTranscriptIfCurrent:[owner currentChatForBookmarks]];
    [self reload];
}

- (void)show
{
    [self reload];
    if (![panel isVisible])
        [panel center];
    [panel makeKeyAndOrderFront:nil];
    [panel makeFirstResponder:field];
}

@end

@implementation ChatController (BookmarkManager)

- (IBAction)showBookmarkManager:(id)sender
{
    (void)sender;
    if (!bookmarkWindow)
        bookmarkWindow = [[TBBookmarkWindow alloc] initWithOwner:self];
    [bookmarkWindow show];
}

@end
