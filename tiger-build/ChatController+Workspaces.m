#import "ChatController_Private.h"
#import "TranscriptView.h"

@implementation ChatController (Workspaces)
/* Each window has its own workspace; the preference only remembers the last
   one chosen, for the next launch. */
- (NSString *)workspaceName
{
    if(!workspaceChoice) {
        NSString *name=[[NSUserDefaults standardUserDefaults] stringForKey:@"TigerBuildWorkspace"];
        workspaceChoice=[([name length]?name:@"Default") copy];
    }
    return workspaceChoice;
}
- (void)setWorkspaceChoice:(NSString *)name
{
    [workspaceChoice release];workspaceChoice=[name copy];
    [[NSUserDefaults standardUserDefaults] setObject:name forKey:@"TigerBuildWorkspace"];
}
/* The file a workspace's chats live in. Default has always been chats.plist. */
- (NSString *)pathForWorkspace:(NSString *)name
{
    if([name isEqualToString:@"Default"])return [[self supportDir] stringByAppendingPathComponent:@"chats.plist"];
    return [[[[self supportDir] stringByAppendingPathComponent:@"workspaces"] stringByAppendingPathComponent:name] stringByAppendingString:@".plist"];
}
/* Every workspace there is a file for. Default is listed only while it
   exists, so it can be deleted like any other; a fresh install with nothing
   saved yet still shows it. */
- (NSArray *)workspaceNames
{
    NSMutableArray *names=[NSMutableArray array];
    NSString *dir=[[self supportDir] stringByAppendingPathComponent:@"workspaces"];
    NSArray *items=[[NSFileManager defaultManager] directoryContentsAtPath:dir];
    unsigned i;
    for(i=0;i<[items count];i++) {
        NSString *name=[items objectAtIndex:i];
        if([name hasSuffix:@".plist"]&&TBWorkspaceNameOK([name stringByDeletingPathExtension])) [names addObject:[name stringByDeletingPathExtension]];
    }
    [names sortUsingSelector:@selector(caseInsensitiveCompare:)];
    if([[NSFileManager defaultManager] fileExistsAtPath:[self pathForWorkspace:@"Default"]]||[names count]==0||[[self workspaceName] isEqualToString:@"Default"])
        [names insertObject:@"Default" atIndex:0];
    return names;
}
- (void)refillWorkspacePopup
{
    [workspacePopup removeAllItems];
    NSArray *names=[self workspaceNames];unsigned i;
    for(i=0;i<[names count];i++) [workspacePopup addItemWithTitle:[names objectAtIndex:i]];
    [workspacePopup selectItemWithTitle:[self workspaceName]];
    [workspacePopup setToolTip:@"Each project has its own chats. API keys and tools are shared."];
}
- (void)switchWorkspace:(NSString *)name
{
    if(busy||naming) {NSBeep();return;}
    if([name isEqualToString:[self workspaceName]])return;
    [self forgetEdit];
    [self flushStore];
    [self setWorkspaceChoice:name];
    current=nil;
    [self loadStore];[self reloadTableSelect:0 show:YES];[self refillWorkspacePopup];
    [input setStringValue:@""];
    [window setTitle:[NSString stringWithFormat:@"Tiger Build - %@",name]];
}
- (void)chooseWorkspace:(id)sender
{
    NSString *name=[sender isKindOfClass:[NSPopUpButton class]]?[[sender selectedItem] title]:[sender representedObject];
    if(busy||naming){NSBeep();[self refillWorkspacePopup];return;}
    [self switchWorkspace:name];
}
/* Remove one workspace and its chats. When none is left, a new empty Default
   appears so there is always somewhere to chat. */
- (void)deleteWorkspace:(id)sender
{
    (void)sender;
    if([self anyWindowBusy]){NSBeep();return;}
    NSString *name=[self workspaceName];
    if(NSRunAlertPanel(@"Delete this workspace?",@"This deletes the workspace \"%@\" and all %d chats in it from this Mac. "
        @"Exports you made are not deleted.",@"Delete",@"Cancel",nil,name,(int)[chats count])!=NSAlertDefaultReturn)return;
    [self forgetEdit];
    [TBStore flushAll];
    [TBStore forgetAll];
    [[NSFileManager defaultManager] removeFileAtPath:[self pathForWorkspace:name] handler:nil];
    NSArray *left=[self workspaceNamesOnDisk];
    NSString *next=[left count]?[left objectAtIndex:0]:@"Default";
    [self setWorkspaceChoice:next];
    current=nil;
    [self loadStore];
    if([left count]==0){[self saveStore];[self flushStore];}
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TBStoresReplaced" object:nil];
    [self reloadTableSelect:0 show:YES];[self refillWorkspacePopup];
    [input setStringValue:@""];
    [window setTitle:[NSString stringWithFormat:@"Tiger Build - %@",next]];
    [self sweepStoredFiles];
}
/* Workspaces that have a saved file, without the Default placeholder. */
- (NSArray *)workspaceNamesOnDisk
{
    NSMutableArray *out=[NSMutableArray array];
    NSArray *all=[self workspaceNames];unsigned i;
    for(i=0;i<[all count];i++)
        if([[NSFileManager defaultManager] fileExistsAtPath:[self pathForWorkspace:[all objectAtIndex:i]]])[out addObject:[all objectAtIndex:i]];
    return out;
}

/* ---- what a new chat starts with ---- */

/* Settings: New chats use "last" (the default) or one "provider|model". */
- (void)applyNewChatDefaults:(NSMutableDictionary *)chat
{
    NSDictionary *last=[workspaceSettings objectForKey:@"last"];
    NSString *wanted=[[NSUserDefaults standardUserDefaults] stringForKey:@"TigerBuildNewChatModel"];
    NSString *provider=nil;NSString *model=nil;
    if([wanted length]&&![wanted isEqualToString:@"last"]) {
        NSRange bar=[wanted rangeOfString:@"|"];
        if(bar.location!=NSNotFound){provider=[wanted substringToIndex:bar.location];model=[wanted substringFromIndex:bar.location+1];}
    } else if([last isKindOfClass:[NSDictionary class]]) {
        provider=[last objectForKey:@"provider"];model=[last objectForKey:@"model"];
    }
    if([provider length]&&[self providerUsable:provider]) {
        [chat setObject:provider forKey:@"provider"];
        if([self model:model allowedForProvider:provider])[chat setObject:model forKey:@"model"];
        else [chat setObject:[self defaultModelForProvider:provider] forKey:@"model"];
    }
    if([[workspaceSettings objectForKey:@"instructions"] length])
        [chat setObject:[workspaceSettings objectForKey:@"instructions"] forKey:@"instructions"];
    /* The same tool switches as the chat before it. */
    if([last isKindOfClass:[NSDictionary class]]) {
        if([[last objectForKey:@"servers"] isKindOfClass:[NSDictionary class]]) {
            [chat setObject:[NSMutableDictionary dictionaryWithDictionary:[last objectForKey:@"servers"]] forKey:@"servers"];
            if([[last objectForKey:@"servers"] objectForKey:@"commander"])
                [chat setObject:[[last objectForKey:@"servers"] objectForKey:@"commander"] forKey:@"tools"];
        }
        if([[last objectForKey:@"approve"] isKindOfClass:[NSDictionary class]])
            [chat setObject:[NSMutableDictionary dictionaryWithDictionary:[last objectForKey:@"approve"]] forKey:@"approve"];
    }
}
/* Called when a message is sent: this chat's model and tool switches become
   what the next new chat starts with. */
- (void)rememberLastUsed
{
    NSMutableDictionary *last=[NSMutableDictionary dictionary];
    if(!current)return;
    [last setObject:[self providerForChat:current] forKey:@"provider"];
    [last setObject:[self modelForChat:current] forKey:@"model"];
    if([[current objectForKey:@"servers"] isKindOfClass:[NSDictionary class]])[last setObject:[current objectForKey:@"servers"] forKey:@"servers"];
    if([[current objectForKey:@"approve"] isKindOfClass:[NSDictionary class]])[last setObject:[current objectForKey:@"approve"] forKey:@"approve"];
    [workspaceSettings setObject:[[last copy] autorelease] forKey:@"last"];
}

/* ---- workspace settings: limit Commander to a folder ---- */

- (void)workspaceSettingsChoose:(id)sender
{
    (void)sender;
    NSOpenPanel *open=[NSOpenPanel openPanel];
    [open setCanChooseDirectories:YES];[open setCanChooseFiles:NO];[open setAllowsMultipleSelection:NO];
    [open setPrompt:@"Choose"];
    if([open runModalForDirectory:NSHomeDirectory() file:nil types:nil]==NSOKButton) {
        NSTextField *field=[prefsFields objectForKey:@"ws.root"];
        [field setStringValue:[[open filenames] objectAtIndex:0]];
        [[prefsFields objectForKey:@"ws.limit"] setState:NSOnState];
    }
}
- (void)workspaceSettingsSave:(id)sender
{
    (void)sender;
    NSString *root=[[[prefsFields objectForKey:@"ws.root"] stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    BOOL limit=[[prefsFields objectForKey:@"ws.limit"] state]==NSOnState;
    BOOL isDir=NO;
    if(limit&&(![root hasPrefix:@"/"]||![[NSFileManager defaultManager] fileExistsAtPath:root isDirectory:&isDir]||!isDir)) {
        NSRunAlertPanel(@"Workspace",@"Choose a directory that exists on this Mac, such as /Users/%@/Projects.",@"OK",nil,nil,NSUserName());return;
    }
    while([root length]>1&&[root hasSuffix:@"/"])root=[root substringToIndex:[root length]-1];
    [workspaceSettings setObject:[NSNumber numberWithBool:limit] forKey:@"limitRoot"];
    [workspaceSettings setObject:root forKey:@"root"];
    [self saveStore];
    [NSApp stopModalWithCode:1];
}
- (void)workspaceSettingsCancel:(id)sender {(void)sender;[NSApp stopModalWithCode:0];}
- (void)showWorkspaceSettings:(id)sender
{
    (void)sender;
    NSPanel *panel=[[[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,500,232) styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO] autorelease];
    NSView *view=[panel contentView];
    [panel setTitle:[NSString stringWithFormat:@"Workspace Settings - %@",[self workspaceName]]];[panel center];
    NSButton *limit=[[[NSButton alloc] initWithFrame:NSMakeRect(20,190,460,22)] autorelease];
    [limit setButtonType:NSSwitchButton];[limit setTitle:@"Restrict Commander to one directory in this workspace"];
    [limit setState:[[workspaceSettings objectForKey:@"limitRoot"] boolValue]?NSOnState:NSOffState];[view addSubview:limit];
    [prefsFields setObject:limit forKey:@"ws.limit"];
    NSTextField *field=[[[NSTextField alloc] initWithFrame:NSMakeRect(20,156,360,24)] autorelease];
    [field setStringValue:[workspaceSettings objectForKey:@"root"]?[workspaceSettings objectForKey:@"root"]:@""];
    [[field cell] setPlaceholderString:[NSString stringWithFormat:@"/Users/%@/Projects",NSUserName()]];[view addSubview:field];
    [prefsFields setObject:field forKey:@"ws.root"];
    NSButton *choose=[[[NSButton alloc] initWithFrame:NSMakeRect(388,153,96,30)] autorelease];
    [choose setTitle:@"Choose..."];[choose setBezelStyle:NSRoundedBezelStyle];[choose setTarget:self];[choose setAction:@selector(workspaceSettingsChoose:)];[view addSubview:choose];
    NSTextField *note=[[[NSTextField alloc] initWithFrame:NSMakeRect(20,60,460,86)] autorelease];
    [note setStringValue:@"Commander's file tools stay inside this directory, and shell commands start there and may only name paths inside it "
        @"(system programs still run). A command line can only be checked so far: for a hard limit, use a separate account."];
    [note setEditable:NO];[note setBezeled:NO];[note setDrawsBackground:NO];[note setFont:[NSFont systemFontOfSize:11]];[[note cell] setWraps:YES];[view addSubview:note];
    NSButton *save=[[[NSButton alloc] initWithFrame:NSMakeRect(290,16,92,30)] autorelease];
    [save setTitle:@"Save"];[save setBezelStyle:NSRoundedBezelStyle];[save setKeyEquivalent:@"\r"];[save setTarget:self];[save setAction:@selector(workspaceSettingsSave:)];[view addSubview:save];
    NSButton *cancel=[[[NSButton alloc] initWithFrame:NSMakeRect(388,16,92,30)] autorelease];
    [cancel setTitle:@"Cancel"];[cancel setBezelStyle:NSRoundedBezelStyle];[cancel setKeyEquivalent:@"\033"];[cancel setTarget:self];[cancel setAction:@selector(workspaceSettingsCancel:)];[view addSubview:cancel];
    [panel setLevel:NSFloatingWindowLevel];[panel makeKeyAndOrderFront:nil];[NSApp runModalForWindow:panel];[panel orderOut:nil];
    [prefsFields removeObjectForKey:@"ws.limit"];[prefsFields removeObjectForKey:@"ws.root"];
}
- (void)workspaceCreateConfirm:(id)sender {(void)sender;[[NSApp modalWindow] makeFirstResponder:nil];[NSApp stopModalWithCode:1];}
- (void)workspaceCreateCancel:(id)sender {(void)sender;[NSApp stopModalWithCode:0];}
- (void)newWorkspace:(id)sender
{
    (void)sender;if(busy||naming){NSBeep();return;}
    NSPanel *panel=[[[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,420,145) styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO] autorelease];
    [panel setTitle:@"New Workspace / Project"];[panel center];
    NSTextField *field=[[[NSTextField alloc] initWithFrame:NSMakeRect(20,76,380,24)] autorelease];
    [[panel contentView] addSubview:field];
    NSButton *create=[[[NSButton alloc] initWithFrame:NSMakeRect(207,21,92,28)] autorelease];
    [create setTitle:@"Create"];[create setBezelStyle:NSRoundedBezelStyle];[create setTarget:self];
    [create setAction:@selector(workspaceCreateConfirm:)];[create setKeyEquivalent:@"\r"];[[panel contentView] addSubview:create];
    NSButton *cancel=[[[NSButton alloc] initWithFrame:NSMakeRect(303,21,92,28)] autorelease];
    [cancel setTitle:@"Cancel"];[cancel setBezelStyle:NSRoundedBezelStyle];[cancel setTarget:self];
    [cancel setAction:@selector(workspaceCreateCancel:)];[cancel setKeyEquivalent:@"\033"];[[panel contentView] addSubview:cancel];
    [field setTarget:self];[field setAction:@selector(workspaceCreateConfirm:)];
    [panel setLevel:NSFloatingWindowLevel];[panel makeKeyAndOrderFront:nil];[panel makeFirstResponder:field];int result=[NSApp runModalForWindow:panel];[panel orderOut:nil];if(result!=1)return;
    NSString *name=[[field stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if(!TBWorkspaceNameOK(name)||[[self workspaceNames] containsObject:name]) {
        NSRunAlertPanel(@"Workspace",@"Use a unique name of 1-60 characters, without slashes or a leading dot.",@"OK",nil,nil);return;
    }
    NSString *dir=[[self supportDir] stringByAppendingPathComponent:@"workspaces"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir attributes:nil];
    NSDictionary *root=[NSDictionary dictionaryWithObjectsAndKeys:[NSArray array],@"chats",[NSNumber numberWithInt:1],@"next",[NSDictionary dictionary],@"settings",nil];
    NSString *error=nil;NSData *data=[NSPropertyListSerialization dataFromPropertyList:root format:NSPropertyListXMLFormat_v1_0 errorDescription:&error];
    if(error)[error release];
    if(![data writeToFile:[dir stringByAppendingPathComponent:[name stringByAppendingString:@".plist"]] atomically:YES]) {
        NSRunAlertPanel(@"Workspace",@"Could not create workspace.",@"OK",nil,nil);return;
    }
    [self switchWorkspace:name];
}
- (void)workspaceNext:(id)sender
{
    (void)sender;NSArray *names=[self workspaceNames];NSUInteger index=[names indexOfObject:[self workspaceName]];
    if(index==NSNotFound)index=0;
    [self switchWorkspace:[names objectAtIndex:(index+1)%[names count]]];
}
- (void)copyAnswer:(id)sender
{
    (void)sender;NSArray *messages=[current objectForKey:@"messages"];int i;
    for(i=(int)[messages count]-1;i>=0;i--) {
        NSDictionary *m=[messages objectAtIndex:i];
        if([[m objectForKey:@"status"] boolValue]||![[m objectForKey:@"role"] isEqualToString:@"assistant"])continue;
        NSString *text=[m objectForKey:@"text"];
        if([text length]) {
            NSPasteboard *p=[NSPasteboard generalPasteboard];[p declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];[p setString:text forType:NSStringPboardType];return;
        }
    }
    NSBeep();
}
- (void)focusComposer:(id)sender {(void)sender;[window makeFirstResponder:input];}
- (void)jumpToLatest:(id)sender {(void)sender;[transcript scrollToEnd];}
- (void)expandActivities:(id)sender {(void)sender;[transcript setActivitiesExpanded:YES];}
- (void)collapseActivities:(id)sender {(void)sender;[transcript setActivitiesExpanded:NO];}
@end
