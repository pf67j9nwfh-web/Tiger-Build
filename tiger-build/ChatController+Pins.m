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


/* ---- putting the pinned chats in order: drag one, or Chat, Move Pinned Chat Up / Down ---- */

static NSString *const kPinnedRowType = @"TBPinnedChatRow";

- (void)registerPinDrag
{
    [table registerForDraggedTypes:[NSArray arrayWithObject:kPinnedRowType]];
}

/* Moves a pinned chat to another place among the pinned ones (to is a gap: 0 is above the first). */
- (void)movePinnedFrom:(int)from to:(int)to
{
    int pinned = [self pinnedCount];
    NSMutableDictionary *chat;
    if (from < 0 || from >= pinned || to < 0 || to > pinned || to == from || to == from + 1)
        return;
    chat = [[chats objectAtIndex:from] retain];
    [chats removeObjectAtIndex:from];
    [chats insertObject:chat atIndex:to > from ? to - 1 : to];
    [chat release];
    [self saveStore];
    [self reloadTableSelect:[chats indexOfObjectIdenticalTo:chat] show:NO];
}

- (BOOL)tableView:(NSTableView *)aTable writeRowsWithIndexes:(NSIndexSet *)rows toPasteboard:(NSPasteboard *)board
{
    (void)aTable;
    if ([rows count] != 1 || (int)[rows firstIndex] >= [self pinnedCount] || busy)
        return NO;
    [board declareTypes:[NSArray arrayWithObject:kPinnedRowType] owner:self];
    [board setString:[NSString stringWithFormat:@"%d", (int)[rows firstIndex]] forType:kPinnedRowType];
    return YES;
}

- (NSDragOperation)tableView:(NSTableView *)aTable validateDrop:(id <NSDraggingInfo>)info proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)op
{
    if (![[[info draggingPasteboard] types] containsObject:kPinnedRowType])
        return NSDragOperationNone;
    if (row > [self pinnedCount])
        row = [self pinnedCount];
    [aTable setDropRow:row dropOperation:NSTableViewDropAbove];
    (void)op;
    return NSDragOperationMove;
}

- (BOOL)tableView:(NSTableView *)aTable acceptDrop:(id <NSDraggingInfo>)info row:(NSInteger)row dropOperation:(NSTableViewDropOperation)op
{
    NSString *from = [[info draggingPasteboard] stringForType:kPinnedRowType];
    (void)aTable; (void)op;
    if (!from)
        return NO;
    [self movePinnedFrom:[from intValue] to:row > [self pinnedCount] ? [self pinnedCount] : (int)row];
    return YES;
}

- (IBAction)movePinnedUp:(id)sender
{
    int row = (int)[chats indexOfObjectIdenticalTo:current];
    (void)sender;
    if (row > 0 && row < [self pinnedCount])
        [self movePinnedFrom:row to:row - 1];
}

- (IBAction)movePinnedDown:(id)sender
{
    int row = (int)[chats indexOfObjectIdenticalTo:current];
    (void)sender;
    if (row >= 0 && row < [self pinnedCount] - 1)
        [self movePinnedFrom:row to:row + 2];
}

@end
