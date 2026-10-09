#import "ChatController_Private.h"

/* Pinned chats stay at the top of the chat list (Chat, Pin Chat). New chats go in below the pinned ones. */

@implementation ChatController (Pins)

- (int)pinnedCount
{
    int n = 0;
    while (n < (int)[chats count] && [[[chats objectAtIndex:n] objectForKey:@"pinned"] boolValue])
        n++;
    return n;
}

/* Puts a new chat first among the unpinned ones; returns its row. */
- (int)insertChatAtTop:(NSMutableDictionary *)chat
{
    int row = [self pinnedCount];
    [chats insertObject:chat atIndex:row];
    return row;
}

- (IBAction)togglePin:(id)sender
{
    NSMutableDictionary *chat = current;
    BOOL pin;
    int row;
    (void)sender;
    if (!chat || busy)
        return;
    pin = ![[chat objectForKey:@"pinned"] boolValue];
    [chat retain];
    [chats removeObjectIdenticalTo:chat];
    if (pin)
        [chat setObject:[NSNumber numberWithBool:YES] forKey:@"pinned"];
    else
        [chat removeObjectForKey:@"pinned"];
    row = [self pinnedCount];
    [chats insertObject:chat atIndex:pin ? 0 : row];
    [chat release];
    [self saveStore];
    [self reloadTableSelect:[chats indexOfObjectIdenticalTo:chat] show:NO];
}

@end
