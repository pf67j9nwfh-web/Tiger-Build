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

- (NSArray *)bookmarkHits
{
    NSMutableArray *found = [NSMutableArray array];
    unsigned c, m;
    for (c = 0; c < [chats count] && [found count] < 40; c++) {
        NSMutableDictionary *chat = [chats objectAtIndex:c];
        NSArray *messages = [chat objectForKey:@"messages"];
        for (m = 0; m < [messages count] && [found count] < 40; m++) {
            NSMutableDictionary *message = [messages objectAtIndex:m];
            NSString *text, *title = [chat objectForKey:@"title"];
            if (![[message objectForKey:@"bookmark"] boolValue])
                continue;
            text = [[[message objectForKey:@"text"] componentsSeparatedByString:@"\n"] componentsJoinedByString:@" "];
            if ([text length] > 50)
                text = [[text substringToIndex:50] stringByAppendingString:@"..."];
            [found addObject:[NSDictionary dictionaryWithObjectsAndKeys:chat, @"chat", message, @"message",
                [NSString stringWithFormat:@"%@: %@", [title length] ? title : @"Chat", text ? text : @""], @"label", nil]];
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
        NSMenuItem *none = [[[NSMenuItem alloc] initWithTitle:@"No Bookmarks (right-click a message to add one)" action:NULL keyEquivalent:@""] autorelease];
        [none setEnabled:NO];
        [menu addItem:none];
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

@end
