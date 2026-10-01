#import "ChatController_Private.h"
#import "TranscriptView.h"

@implementation ChatController (Workspaces)
- (NSString *)workspaceName
{
    NSString *name=[[NSUserDefaults standardUserDefaults] stringForKey:@"TigerBuildWorkspace"];
    return [name length]?name:@"Default";
}
- (NSArray *)workspaceNames
{
    NSMutableArray *names=[NSMutableArray arrayWithObject:@"Default"];
    NSString *dir=[[self supportDir] stringByAppendingPathComponent:@"workspaces"];
    NSArray *items=[[NSFileManager defaultManager] directoryContentsAtPath:dir];
    unsigned i;
    for(i=0;i<[items count];i++) {
        NSString *name=[items objectAtIndex:i];
        if([name hasSuffix:@".plist"]) [names addObject:[name stringByDeletingPathExtension]];
    }
    return names;
}
- (void)refillWorkspacePopup
{
    [workspacePopup removeAllItems];
    NSArray *names=[self workspaceNames];unsigned i;
    for(i=0;i<[names count];i++) [workspacePopup addItemWithTitle:[names objectAtIndex:i]];
    [workspacePopup selectItemWithTitle:[self workspaceName]];
    [workspacePopup setToolTip:@"Each project has its own chats. API keys and relay tools are shared."];
}
- (void)switchWorkspace:(NSString *)name
{
    if(busy||naming) {NSBeep();return;}
    if([name isEqualToString:[self workspaceName]])return;
    [self saveStore];[self flushStore];
    [[NSUserDefaults standardUserDefaults] setObject:name forKey:@"TigerBuildWorkspace"];
    [chats removeAllObjects];nextNumber=1;
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
    [panel makeKeyAndOrderFront:nil];[panel makeFirstResponder:field];int result=[NSApp runModalForWindow:panel];[panel orderOut:nil];if(result!=1)return;
    NSString *name=[[field stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if(![name length]||[name length]>60||[name hasPrefix:@"."]||[name rangeOfString:@"/"].location!=NSNotFound
        ||[[self workspaceNames] containsObject:name]) {
        NSRunAlertPanel(@"Workspace",@"Use a unique name of 1-60 characters, without slashes or a leading dot.",@"OK",nil,nil);return;
    }
    NSString *dir=[[self supportDir] stringByAppendingPathComponent:@"workspaces"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir attributes:nil];
    NSDictionary *root=[NSDictionary dictionaryWithObjectsAndKeys:[NSArray array],@"chats",[NSNumber numberWithInt:1],@"next",nil];
    NSString *error=nil;NSData *data=[NSPropertyListSerialization dataFromPropertyList:root format:NSPropertyListXMLFormat_v1_0 errorDescription:&error];
    if(error)[error release];
    if(![data writeToFile:[dir stringByAppendingPathComponent:[name stringByAppendingString:@".plist"]] atomically:YES]) {
        NSRunAlertPanel(@"Workspace",@"Could not create workspace.",@"OK",nil,nil);return;
    }
    [self switchWorkspace:name];
}
- (void)workspaceNext:(id)sender
{
    (void)sender;NSArray *names=[self workspaceNames];unsigned index=[names indexOfObject:[self workspaceName]];
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
