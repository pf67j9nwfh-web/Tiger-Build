#import "ChatController_Private.h"

/* History covers every workspace at once: export, import, copy to and from the
   relay host, and clear. A history file written by 1.2 holds one workspace's
   chats and still imports, into the current workspace. */

@interface ChatController (HistoryPrivate)
- (NSDictionary *)historyRoot;
- (NSData *)historyDataIncludingFiles;
- (void)restoreFilesInChat:(NSMutableDictionary *)chat from:(NSDictionary *)files;
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
    [all setObject:[NSDictionary dictionaryWithObjectsAndKeys:chats, @"chats", [NSNumber numberWithInt:[store next]], @"next",
        workspaceSettings, @"settings", nil] forKey:mine];
    return all;
}

- (NSDictionary *)historyRoot
{
    return [NSDictionary dictionaryWithObjectsAndKeys:@"TigerBuild-history", @"format",
        [NSNumber numberWithInt:2], @"version", [self workspaceName], @"current", [self allWorkspaces], @"workspaces", nil];
}

- (NSData *)historyData
{
    NSDictionary *root = [self historyRoot];
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
    if ([self anyWindowBusy]) { NSBeep(); return; }
    if (NSRunAlertPanel(@"Clear all history and workspaces?", @"This deletes every chat in every workspace (%d) on this Mac, "
        @"and the workspaces themselves. A new empty Default workspace is made. "
        @"Exports you made are not deleted.", @"Clear All", @"Cancel", nil,
        (int)[[self workspaceNamesOnDisk] count])
        != NSAlertDefaultReturn) return;
    [self forgetEdit];
    [TBStore forgetAll];
    names = [self workspaceNamesOnDisk];
    for (i = 0; i < [names count]; i++)
        [[NSFileManager defaultManager] removeFileAtPath:[self pathForWorkspace:[names objectAtIndex:i]] handler:nil];
    [self setWorkspaceChoice:@"Default"];
    current = nil;
    [self loadStore];
    [self saveStore];
    [self flushStore];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TBStoresReplaced" object:nil];
    [self reloadTableSelect:0 show:YES];
    [self refillWorkspacePopup];
    [window setTitle:@"Tiger Build - Default"];
    [self sweepStoredFiles];
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
    data = [self historyDataIncludingFiles];
    if (!data || ![data writeToFile:[panel filename] atomically:YES])
        NSRunAlertPanel(@"History", @"Could not export the history.", @"OK", nil, nil);
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
        TBSanitizeImportedChat(c);
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

/* A history file made with files inside: write them out and point the chats at them. */
- (void)restoreWorkspaceFiles:(NSMutableDictionary *)space from:(NSDictionary *)files
{
    NSArray *list = [space objectForKey:@"chats"];
    unsigned c;
    if (![files isKindOfClass:[NSDictionary class]])
        files = [NSDictionary dictionary];
    for (c = 0; c < [list count]; c++)
        [self restoreFilesInChat:[list objectAtIndex:c] from:files];
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
    if ([self anyWindowBusy]) {
        NSRunAlertPanel(@"History", @"Wait until the current reply finishes, in every window, before importing.", @"OK", nil, nil);
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
    [TBStore forgetAll];
    if ([[bundle objectForKey:@"bundle"] boolValue]) {
        NSArray *old = [self workspaceNamesOnDisk];
        for (i = 0; i < [old count]; i++)
            [[NSFileManager defaultManager] removeFileAtPath:[self pathForWorkspace:[old objectAtIndex:i]] handler:nil];
        for (i = 0; i < [names count]; i++) {
            NSMutableDictionary *cleaned = [self cleanedWorkspace:[spaces objectForKey:[names objectAtIndex:i]]];
            [self restoreWorkspaceFiles:cleaned from:[root objectForKey:@"files"]];
            [self writeWorkspace:[names objectAtIndex:i] data:cleaned];
        }
        open = [bundle objectForKey:@"current"];
        if (!open)
            open = [names objectAtIndex:0];
    } else {
        NSMutableDictionary *cleaned = [self cleanedWorkspace:[spaces objectForKey:[names objectAtIndex:0]]];
        open = [self workspaceName];
        [self restoreWorkspaceFiles:cleaned from:[root objectForKey:@"files"]];
        [self writeWorkspace:open data:cleaned];
    }
    [self setWorkspaceChoice:open];
    current = nil;
    [self loadStore];
    [self saveStore];
    [self flushStore];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TBStoresReplaced" object:nil];
    [self reloadTableSelect:0 show:YES];
    [self refillWorkspacePopup];
    [window setTitle:[NSString stringWithFormat:@"Tiger Build - %@", open]];
}
@end
