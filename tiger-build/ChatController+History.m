#import "ChatController_Private.h"

/* History covers every workspace at once: export, import, copy to and from the
   relay host, and clear. A history file written by 1.2 holds one workspace's
   chats and still imports, into the current workspace. */

@interface ChatController (HistoryPrivate)
- (NSDictionary *)allWorkspaces;
- (NSString *)pathForWorkspace:(NSString *)name;
- (NSArray *)workspaceNames;
- (NSArray *)workspaceNamesOnDisk;
- (void)writeWorkspace:(NSString *)name data:(NSDictionary *)space;
@end

@implementation ChatController (History)

/* name -> {chats, next, settings}, for every workspace. The open one comes
   from memory, the others from their files. */
- (NSDictionary *)allWorkspaces
{
    NSMutableDictionary *all = [NSMutableDictionary dictionary];
    NSArray *names = [self workspaceNamesOnDisk];
    NSString *mine = [self workspaceName];
    unsigned i;
    [self flushStore];
    for (i = 0; i < [names count]; i++) {
        NSString *name = [names objectAtIndex:i];
        NSData *data;
        NSDictionary *root;
        NSString *error = nil;
        if ([name isEqualToString:mine])
            continue;
        data = [NSData dataWithContentsOfFile:[self pathForWorkspace:name]];
        if (!data)
            continue;
        root = [NSPropertyListSerialization propertyListFromData:data mutabilityOption:NSPropertyListImmutable
            format:NULL errorDescription:&error];
        if (error)
            [error release];
        if ([root isKindOfClass:[NSDictionary class]] && [[root objectForKey:@"chats"] isKindOfClass:[NSArray class]])
            [all setObject:root forKey:name];
    }
    [all setObject:[NSDictionary dictionaryWithObjectsAndKeys:chats, @"chats", [NSNumber numberWithInt:nextNumber], @"next",
        workspaceSettings, @"settings", nil] forKey:mine];
    return all;
}

- (NSData *)historyData
{
    NSDictionary *root = [NSDictionary dictionaryWithObjectsAndKeys:@"TigerBuild-history", @"format",
        [NSNumber numberWithInt:2], @"version", [self workspaceName], @"current", [self allWorkspaces], @"workspaces", nil];
    NSString *error = nil;
    NSData *data = [NSPropertyListSerialization dataFromPropertyList:root
        format:NSPropertyListXMLFormat_v1_0 errorDescription:&error];
    if (error) [error release];
    return data;
}

- (void)writeWorkspace:(NSString *)name data:(NSDictionary *)space
{
    NSString *error = nil;
    NSString *dir = [[self supportDir] stringByAppendingPathComponent:@"workspaces"];
    NSData *data;
    [[NSFileManager defaultManager] createDirectoryAtPath:dir attributes:nil];
    data = [NSPropertyListSerialization dataFromPropertyList:space format:NSPropertyListBinaryFormat_v1_0 errorDescription:&error];
    if (error) [error release];
    if (data)
        [data writeToFile:[self pathForWorkspace:name] atomically:YES];
}

/* Delete every workspace, then start over with one empty Default. */
- (void)clearAllHistory:(id)sender
{
    NSArray *names;
    unsigned i;
    (void)sender;
    if (busy) return;
    if (NSRunAlertPanel(@"Clear all history and workspaces?", @"This deletes every chat in every workspace (%d) on this Mac, "
        @"and the workspaces themselves. A new empty Default workspace is made. "
        @"Exports and history already copied to the relay are not deleted.", @"Clear All", @"Cancel", nil,
        (int)[[self workspaceNamesOnDisk] count])
        != NSAlertDefaultReturn) return;
    [self forgetEdit];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(flushStore) object:nil];
    names = [self workspaceNamesOnDisk];
    for (i = 0; i < [names count]; i++)
        [[NSFileManager defaultManager] removeFileAtPath:[self pathForWorkspace:[names objectAtIndex:i]] handler:nil];
    [[NSUserDefaults standardUserDefaults] setObject:@"Default" forKey:@"TigerBuildWorkspace"];
    [chats removeAllObjects];
    nextNumber = 1;
    [workspaceSettings removeAllObjects];
    [chats addObject:[self blankChat]];
    storeDirty = NO;
    [self reloadTableSelect:0 show:YES];
    [self refillWorkspacePopup];
    [window setTitle:@"Tiger Build - Default"];
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
    if (NSRunAlertPanel(@"Copy history to relay host?", @"The chats of every workspace will be copied to the relay Mac. "
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

/* Make a chat list safe to keep: renumber, drop in-flight markers. */
- (NSMutableDictionary *)cleanedWorkspace:(NSDictionary *)space
{
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSMutableArray *list = [NSMutableArray array];
    NSArray *incoming = [space objectForKey:@"chats"];
    int number = 1;
    unsigned i;
    for (i = 0; i < [incoming count]; i++) {
        NSMutableDictionary *c = [NSPropertyListSerialization propertyListFromData:
            [NSPropertyListSerialization dataFromPropertyList:[incoming objectAtIndex:i] format:NSPropertyListXMLFormat_v1_0 errorDescription:NULL]
            mutabilityOption:NSPropertyListMutableContainers format:NULL errorDescription:NULL];
        NSArray *messages;
        unsigned j;
        if (![c isKindOfClass:[NSMutableDictionary class]])
            continue;
        [c setObject:[NSString stringWithFormat:@"%d", number++] forKey:@"id"];
        if (![[c objectForKey:@"title"] isKindOfClass:[NSString class]])
            [c setObject:@"Imported Chat" forKey:@"title"];
        messages = [c objectForKey:@"messages"];
        for (j = 0; j < [messages count]; j++) {
            [[messages objectAtIndex:j] removeObjectForKey:@"open"];
            [[messages objectAtIndex:j] removeObjectForKey:@"pendingMedia"];
        }
        [list addObject:c];
    }
    [out setObject:list forKey:@"chats"];
    [out setObject:[NSNumber numberWithInt:number] forKey:@"next"];
    if ([[space objectForKey:@"settings"] isKindOfClass:[NSDictionary class]])
        [out setObject:[space objectForKey:@"settings"] forKey:@"settings"];
    return out;
}

- (void)importHistoryData:(NSData *)data
{
    NSString *error = nil;
    NSDictionary *root;
    NSDictionary *bundle;
    NSDictionary *spaces;
    NSArray *names;
    NSString *backup;
    NSString *open;
    unsigned i;
    if (busy) {
        NSRunAlertPanel(@"History", @"Wait until the current reply finishes before importing.", @"OK", nil, nil);
        return;
    }
    root = [NSPropertyListSerialization propertyListFromData:data mutabilityOption:NSPropertyListImmutable
        format:NULL errorDescription:&error];
    if (error) [error release];
    bundle = TBHistoryBundle(root, [self workspaceName]);
    if (!bundle) {
        id chatList = [root isKindOfClass:[NSDictionary class]] ? [root objectForKey:@"chats"] : nil;
        NSString *why = TBChatListProblem(chatList);
        NSRunAlertPanel(@"History", @"%@", @"OK", nil, nil, why ? why : @"This is not a Tiger Build history export.");
        return;
    }
    spaces = [bundle objectForKey:@"workspaces"];
    names = [[spaces allKeys] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    if ([[bundle objectForKey:@"bundle"] boolValue]) {
        if (NSRunAlertPanel(@"Import history?", @"This replaces every workspace and chat on this Mac with the %d workspaces in the export. "
            @"The current history will first be backed up in Tiger Build's Application Support folder.",
            @"Import", @"Cancel", nil, (int)[names count]) != NSAlertDefaultReturn) return;
    } else {
        if (NSRunAlertPanel(@"Import history?", @"This replaces all chats in the workspace \"%@\" with the export. "
            @"The current history will first be backed up in Tiger Build's Application Support folder.",
            @"Import", @"Cancel", nil, [self workspaceName]) != NSAlertDefaultReturn) return;
    }
    backup = [[self supportDir] stringByAppendingPathComponent:[NSString stringWithFormat:
        @"history-before-import-%.0f.plist", CFAbsoluteTimeGetCurrent()]];
    if (![[self historyData] writeToFile:backup atomically:YES]) {
        NSRunAlertPanel(@"History", @"Could not back up the current history; import cancelled.", @"OK", nil, nil); return;
    }
    [self forgetEdit];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(flushStore) object:nil];
    storeDirty = NO;
    if ([[bundle objectForKey:@"bundle"] boolValue]) {
        NSArray *old = [self workspaceNamesOnDisk];
        for (i = 0; i < [old count]; i++)
            [[NSFileManager defaultManager] removeFileAtPath:[self pathForWorkspace:[old objectAtIndex:i]] handler:nil];
        for (i = 0; i < [names count]; i++)
            [self writeWorkspace:[names objectAtIndex:i] data:[self cleanedWorkspace:[spaces objectForKey:[names objectAtIndex:i]]]];
        open = [bundle objectForKey:@"current"];
        if (!open)
            open = [names objectAtIndex:0];
    } else {
        open = [self workspaceName];
        [self writeWorkspace:open data:[self cleanedWorkspace:[spaces objectForKey:[names objectAtIndex:0]]]];
    }
    [[NSUserDefaults standardUserDefaults] setObject:open forKey:@"TigerBuildWorkspace"];
    [chats removeAllObjects];
    nextNumber = 1;
    [self loadStore];
    [self reloadTableSelect:0 show:YES];
    [self refillWorkspacePopup];
    [window setTitle:[NSString stringWithFormat:@"Tiger Build - %@", open]];
    [self saveStore];
    [self flushStore];
}
@end
