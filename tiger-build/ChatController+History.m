#import "ChatController_Private.h"

@implementation ChatController (History)

- (NSData *)historyData
{
    NSDictionary *root = [NSDictionary dictionaryWithObjectsAndKeys:chats, @"chats",
        [NSNumber numberWithInt:nextNumber], @"next", nil];
    NSString *error = nil;
    NSData *data = [NSPropertyListSerialization dataFromPropertyList:root
        format:NSPropertyListXMLFormat_v1_0 errorDescription:&error];
    if (error) [error release];
    return data;
}

- (void)clearAllHistory:(id)sender
{
    (void)sender;
    if (busy) return;
    if (NSRunAlertPanel(@"Clear all chat history?", @"This deletes all chats in this workspace on this Mac. "
        @"Exports and history already copied to the relay are not deleted.", @"Clear All", @"Cancel", nil)
        != NSAlertDefaultReturn) return;
    [chats removeAllObjects];
    nextNumber = 1;
    [chats addObject:[self blankChat]];
    [self reloadTableSelect:0 show:YES];
    [self saveStore];
    [self flushStore];
}

- (void)exportHistory:(id)sender
{
    NSSavePanel *panel;
    NSData *data;
    (void)sender;
    if (busy) return;
    panel = [NSSavePanel savePanel];
    [panel setRequiredFileType:@"plist"];
    if ([panel runModalForDirectory:[NSHomeDirectory() stringByAppendingPathComponent:@"Desktop"]
        file:@"TigerBuild-history.plist"] != NSOKButton) return;
    data = [self historyData];
    if (!data || ![data writeToFile:[panel filename] atomically:YES])
        NSRunAlertPanel(@"History", @"Could not export the history.", @"OK", nil, nil);
}

- (void)exportHistoryToRelay:(id)sender
{
    NSString *xml;
    (void)sender;
    if (busy) return;
    if (NSRunAlertPanel(@"Copy history to relay host?", @"All chats will be copied to the relay Mac. "
        @"This replaces its previous history snapshot. Media files are not copied, only their references.",
        @"Copy", @"Cancel", nil) != NSAlertDefaultReturn) return;
    xml = [[[NSString alloc] initWithData:[self historyData] encoding:NSUTF8StringEncoding] autorelease];
    [RelayRequest send:@"POST" path:@"/v1/history" body:xml timeout:40 target:self
        action:@selector(historyUploaded:) context:nil];
}

- (void)historyUploaded:(RelayRequest *)request
{
    NSRunAlertPanel(@"History", @"%@", @"OK", nil, nil,
        [request ok] ? @"History copied to the relay host." : [request text]);
}

- (void)importHistoryFromRelay:(id)sender
{
    (void)sender;
    if (busy) return;
    [RelayRequest send:@"GET" path:@"/v1/history" body:nil timeout:40 target:self
        action:@selector(historyDownloaded:) context:nil];
}

- (void)historyDownloaded:(RelayRequest *)request
{
    if (![request ok]) {
        NSRunAlertPanel(@"History", @"%@", @"OK", nil, nil,
            [[request text] length] ? [request text] : @"Cannot reach the relay host.");
        return;
    }
    [self importHistoryData:[request data]];
}

- (void)importHistory:(id)sender
{
    NSOpenPanel *panel;
    (void)sender;
    if (busy) return;
    panel = [NSOpenPanel openPanel];
    [panel setAllowsMultipleSelection:NO];
    if ([panel runModalForDirectory:nil file:nil types:[NSArray arrayWithObject:@"plist"]] != NSOKButton) return;
    [self importHistoryData:[NSData dataWithContentsOfFile:[panel filename]]];
}

- (void)importHistoryData:(NSData *)data
{
    NSString *error = nil;
    NSDictionary *root;
    NSArray *incoming;
    unsigned i;
    NSString *backup;
    if (busy) {
        NSRunAlertPanel(@"History", @"Wait until the current reply finishes before importing.", @"OK", nil, nil);
        return;
    }
    root = [NSPropertyListSerialization propertyListFromData:data mutabilityOption:NSPropertyListMutableContainers
        format:NULL errorDescription:&error];
    if (error) [error release];
    incoming = [root isKindOfClass:[NSDictionary class]] ? [root objectForKey:@"chats"] : nil;
    if (![incoming isKindOfClass:[NSArray class]]) {
        NSRunAlertPanel(@"History", @"This is not a Tiger Build history export.", @"OK", nil, nil);
        return;
    }
    for (i = 0; i < [incoming count]; i++) {
        NSDictionary *c = [incoming objectAtIndex:i];
        if (![c isKindOfClass:[NSDictionary class]] || ![[c objectForKey:@"messages"] isKindOfClass:[NSArray class]]) {
            NSRunAlertPanel(@"History", @"The history contains a malformed chat.", @"OK", nil, nil); return;
        }
    }
    /* Validate message fields before touching the existing history. */
    for (i = 0; i < [incoming count]; i++) {
        NSDictionary *c = [incoming objectAtIndex:i];
        NSArray *list = [c objectForKey:@"messages"];
        unsigned j;
        for (j = 0; j < [list count]; j++) {
            NSDictionary *m = [list objectAtIndex:j];
            if (![m isKindOfClass:[NSDictionary class]] || ![[m objectForKey:@"text"] isKindOfClass:[NSString class]]
                || ![[m objectForKey:@"role"] isKindOfClass:[NSString class]]) {
                NSRunAlertPanel(@"History", @"Malformed message; import cancelled.", @"OK", nil, nil); return;
            }
        }
    }
    if (NSRunAlertPanel(@"Import history?", @"This replaces all current chats with the export. "
        @"The current history will first be backed up in Tiger Build's Application Support folder.",
        @"Import", @"Cancel", nil) != NSAlertDefaultReturn) return;
    backup = [[self supportDir] stringByAppendingPathComponent:[NSString stringWithFormat:
        @"history-before-import-%.0f.plist", CFAbsoluteTimeGetCurrent()]];
    if (![[self historyData] writeToFile:backup atomically:YES]) {
        NSRunAlertPanel(@"History", @"Could not back up the current history; import cancelled.", @"OK", nil, nil); return;
    }
    [chats removeAllObjects];
    nextNumber = 1;
    for (i = 0; i < [incoming count]; i++) {
        NSMutableDictionary *c = [incoming objectAtIndex:i];
        NSArray *list = [c objectForKey:@"messages"];
        unsigned j;
        [c setObject:[NSString stringWithFormat:@"%d", nextNumber++] forKey:@"id"];
        if (![[c objectForKey:@"title"] isKindOfClass:[NSString class]]) [c setObject:@"Imported Chat" forKey:@"title"];
        for (j = 0; j < [list count]; j++) {
            if ([[list objectAtIndex:j] isKindOfClass:[NSMutableDictionary class]]) {
                [[list objectAtIndex:j] removeObjectForKey:@"open"];
                [[list objectAtIndex:j] removeObjectForKey:@"pendingMedia"];
            }
        }
        [chats addObject:c];
    }
    if ([chats count] == 0) [chats addObject:[self blankChat]];
    [self reloadTableSelect:0 show:YES];
    [self saveStore];
    [self flushStore];
}
@end
