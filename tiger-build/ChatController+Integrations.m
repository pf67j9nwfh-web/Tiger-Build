#import "ChatController_Private.h"

@interface ChatController (IntegrationPrivate)
- (NSMutableDictionary *)integrationFields;
- (void)renderServers;
- (void)loadIntegrationForm:(NSDictionary *)data;
- (NSDictionary *)integrationFormData;
- (void)applyClientBackup:(NSDictionary *)backup;
@end

@implementation ChatController (Integrations)
- (NSMutableDictionary *)integrationFields
{
    NSMutableDictionary *fields = [prefsFields objectForKey:@"integration.fields"];
    if (!fields) {
        fields = [NSMutableDictionary dictionary];
        [prefsFields setObject:fields forKey:@"integration.fields"];
    }
    return fields;
}
- (NSTextField *)integrationLabel:(NSString *)title frame:(NSRect)rect view:(NSView *)view
{
    NSTextField *f = [[[NSTextField alloc] initWithFrame:rect] autorelease];
    [f setStringValue:title];[f setEditable:NO];[f setSelectable:NO];[f setBezeled:NO];[f setDrawsBackground:NO];
    [f setFont:[NSFont systemFontOfSize:12]];[view addSubview:f];return f;
}
- (void)showIntegrations:(id)sender
{
    (void)sender;
    NSMutableDictionary *fields=[self integrationFields];
    NSWindow *panel=[fields objectForKey:@"window"];
    if (!panel) {
        panel=[[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,660,800)
            styleMask:NSTitledWindowMask|NSClosableWindowMask backing:NSBackingStoreBuffered defer:NO] autorelease];
        [panel setReleasedWhenClosed:NO];[panel setTitle:@"MCP Servers and Agent Tools"];[panel center];
        [fields setObject:panel forKey:@"window"];
        NSView *view=[panel contentView];
        NSArray *titles=[NSArray arrayWithObjects:@"PPC Commander (built in)",@"Agent toolbox (UTC time and scratch notes)",
            @"Web search for other providers (Brave or Tavily)",@"Grok native web search",@"Show model thinking (Claude, ChatGPT, Gemini, Mistral, local)",nil];
        NSArray *keys=[NSArray arrayWithObjects:@"ppc_enabled",@"toolbox_enabled",@"search_enabled",@"grok_native_search",@"claude_thinking",nil];
        unsigned i;
        for(i=0;i<[titles count];i++) {
            NSButton *b=[[[NSButton alloc] initWithFrame:NSMakeRect(16,757-i*27,620,24)] autorelease];
            [b setButtonType:NSSwitchButton];[b setTitle:[titles objectAtIndex:i]];[view addSubview:b];[fields setObject:b forKey:[keys objectAtIndex:i]];
        }
        [self integrationLabel:@"Brave Search API key (blank keeps saved)" frame:NSMakeRect(16,614,275,22) view:view];
        NSSecureTextField *key=[[[NSSecureTextField alloc] initWithFrame:NSMakeRect(295,614,342,24)] autorelease];
        [view addSubview:key];[fields setObject:key forKey:@"search_api_key"];
        NSButton *clear=[[[NSButton alloc] initWithFrame:NSMakeRect(295,585,342,24)] autorelease];
        [clear setButtonType:NSSwitchButton];[clear setTitle:@"Delete saved search key"];[view addSubview:clear];[fields setObject:clear forKey:@"clear_search_key"];
        [self integrationLabel:@"Tavily API key (blank keeps saved)" frame:NSMakeRect(16,549,275,22) view:view];
        NSSecureTextField *tavily=[[[NSSecureTextField alloc] initWithFrame:NSMakeRect(295,549,342,24)] autorelease];
        [view addSubview:tavily];[fields setObject:tavily forKey:@"tavily_api_key"];
        NSButton *clearT=[[[NSButton alloc] initWithFrame:NSMakeRect(295,520,342,24)] autorelease];
        [clearT setButtonType:NSSwitchButton];[clearT setTitle:@"Delete saved Tavily key"];[view addSubview:clearT];[fields setObject:clearT forKey:@"clear_tavily_key"];
        [self integrationLabel:@"Search service" frame:NSMakeRect(16,484,275,22) view:view];
        NSPopUpButton *provider=[[[NSPopUpButton alloc] initWithFrame:NSMakeRect(295,484,220,26) pullsDown:NO] autorelease];
        [provider addItemsWithTitles:[NSArray arrayWithObjects:@"Brave Search",@"Tavily",nil]];
        [view addSubview:provider];[fields setObject:provider forKey:@"search_provider"];
        [self integrationLabel:@"Custom stdio servers execute on the relay Mac. Enable only trusted programs." frame:NSMakeRect(16,386,628,22) view:view];
        NSScrollView *scroll=[[[NSScrollView alloc] initWithFrame:NSMakeRect(16,231,628,152)] autorelease];
        [scroll setHasVerticalScroller:YES];[scroll setBorderType:NSBezelBorder];
        NSView *doc=[[[NSView alloc] initWithFrame:NSMakeRect(0,0,605,152)] autorelease];[scroll setDocumentView:doc];[view addSubview:scroll];[fields setObject:doc forKey:@"list"];
        NSArray *labels=[NSArray arrayWithObjects:@"Server ID",@"Executable path",@"Arguments",nil];
        NSArray *names=[NSArray arrayWithObjects:@"id",@"command",@"args",nil];
        for(i=0;i<3;i++) {
            float y=196-i*31;
            [self integrationLabel:[labels objectAtIndex:i] frame:NSMakeRect(16,y,113,22) view:view];
            NSTextField *f=[[[NSTextField alloc] initWithFrame:NSMakeRect(132,y,505,24)] autorelease];
            [view addSubview:f];[fields setObject:f forKey:[names objectAtIndex:i]];
        }
        [[fields objectForKey:@"args"] setToolTip:@"Separate arguments with | (pipe). No shell expansion. Example: /path/server.py|--stdio"];
        NSArray *buttons=[NSArray arrayWithObjects:@"Add Disabled Server",@"Save",@"Export All Settings...",@"Import All Settings...",nil];
        SEL actions[]={@selector(addIntegrationServer:),@selector(saveIntegrations:),@selector(exportAllSettings:),@selector(importAllSettings:)};
        for(i=0;i<4;i++) {
            NSButton *b=[[[NSButton alloc] initWithFrame:NSMakeRect(i<2 ? 16+i*192 : 16+(i-2)*210,i<2 ? 91:52,i==1 ? 92:200,28)] autorelease];
            [b setTitle:[buttons objectAtIndex:i]];[b setBezelStyle:NSRoundedBezelStyle];[b setTarget:self];[b setAction:actions[i]];[view addSubview:b];
            if(i==1)[fields setObject:b forKey:@"save"];
        }
        NSTextField *status=[self integrationLabel:@"Loading..." frame:NSMakeRect(16,13,628,30) view:view];[fields setObject:status forKey:@"status"];
    }
    [[fields objectForKey:@"save"] setEnabled:NO];
    [panel makeKeyAndOrderFront:nil];
    [RelayRequest send:@"GET" path:@"/v1/integrations" body:nil timeout:15 target:self action:@selector(integrationsArrived:) context:nil];
}
- (void)integrationsArrived:(RelayRequest *)request
{
    NSMutableDictionary *fields=[self integrationFields];
    if(![request ok]) {[[fields objectForKey:@"status"] setStringValue:[self relayProblemForRequest:request]];return;}
    NSString *error=nil;
    NSDictionary *data=[NSPropertyListSerialization propertyListFromData:[request data] mutabilityOption:NSPropertyListMutableContainers format:NULL errorDescription:&error];
    if(error)[error release];
    if(![data isKindOfClass:[NSDictionary class]])return;
    [self loadIntegrationForm:data];[[fields objectForKey:@"save"] setEnabled:YES];
}
- (void)loadIntegrationForm:(NSDictionary *)data
{
    NSMutableDictionary *fields=[self integrationFields];
    NSArray *keys=[NSArray arrayWithObjects:@"ppc_enabled",@"toolbox_enabled",@"search_enabled",@"grok_native_search",@"claude_thinking",nil];
    unsigned i;
    for(i=0;i<[keys count];i++)[[fields objectForKey:[keys objectAtIndex:i]] setState:[[data objectForKey:[keys objectAtIndex:i]] boolValue]?NSOnState:NSOffState];
    [fields setObject:[NSMutableArray arrayWithArray:[data objectForKey:@"servers"]] forKey:@"servers"];
    [[fields objectForKey:@"search_api_key"] setStringValue:@""];[[fields objectForKey:@"clear_search_key"] setState:NSOffState];
    [[fields objectForKey:@"status"] setStringValue:([[data objectForKey:@"search_key_saved"] intValue]!=0)?@"Brave key is saved.":@"No Brave key saved. Grok can use its native search."];
    [[fields objectForKey:@"tavily_api_key"] setStringValue:@""];[[fields objectForKey:@"clear_tavily_key"] setState:NSOffState];
    [[fields objectForKey:@"search_provider"] selectItemAtIndex:[[data objectForKey:@"search_provider"] isEqualToString:@"tavily"]?1:0];
    [[fields objectForKey:@"status"] setStringValue:[NSString stringWithFormat:@"Saved keys: Brave %@, Tavily %@.",
        ([[data objectForKey:@"search_key_saved"] intValue]!=0)?@"yes":@"no",[[data objectForKey:@"tavily_key_saved"] boolValue]?@"yes":@"no"]];
    [self renderServers];
}
- (void)renderServers
{
    NSMutableDictionary *fields=[self integrationFields];NSView *doc=[fields objectForKey:@"list"];
    NSArray *subs=[NSArray arrayWithArray:[doc subviews]];unsigned i;
    for(i=0;i<[subs count];i++)[[subs objectAtIndex:i] removeFromSuperview];
    NSArray *servers=[fields objectForKey:@"servers"];float height=MAX(152,[servers count]*32);
    [doc setFrameSize:NSMakeSize(605,height)];
    for(i=0;i<[servers count];i++) {
        NSDictionary *s=[servers objectAtIndex:i];float y=height-30-i*32;
        NSButton *b=[[[NSButton alloc] initWithFrame:NSMakeRect(4,y,490,25)] autorelease];[b setButtonType:NSSwitchButton];
        [b setTitle:[NSString stringWithFormat:@"%@ - %@",[s objectForKey:@"id"],[s objectForKey:@"command"]]];
        [b setState:([[s objectForKey:@"enabled"] intValue]!=0)?NSOnState:NSOffState];[b setTag:i];[b setTarget:self];[b setAction:@selector(toggleIntegrationServer:)];[doc addSubview:b];
        NSButton *del=[[[NSButton alloc] initWithFrame:NSMakeRect(500,y,91,25)] autorelease];[del setTitle:@"Remove"];
        [del setBezelStyle:NSRoundedBezelStyle];[del setTag:i];[del setTarget:self];[del setAction:@selector(removeIntegrationServer:)];[doc addSubview:del];
    }
}
- (void)toggleIntegrationServer:(NSButton *)sender
{
    NSMutableArray *servers=[[self integrationFields] objectForKey:@"servers"];
    [[servers objectAtIndex:[sender tag]] setObject:[NSNumber numberWithBool:[sender state]==NSOnState] forKey:@"enabled"];
}
- (void)removeIntegrationServer:(NSButton *)sender
{
    [[[self integrationFields] objectForKey:@"servers"] removeObjectAtIndex:[sender tag]];[self renderServers];
}
- (void)addIntegrationServer:(id)sender
{
    (void)sender;NSMutableDictionary *fields=[self integrationFields];
    NSString *name=[[fields objectForKey:@"id"] stringValue];NSString *command=[[fields objectForKey:@"command"] stringValue];
    if(![name length]||![command hasPrefix:@"/"]){[[fields objectForKey:@"status"] setStringValue:@"Enter a unique ID and absolute executable path on the relay Mac."];return;}
    NSString *args=[[fields objectForKey:@"args"] stringValue];
    NSMutableDictionary *s=[NSMutableDictionary dictionaryWithObjectsAndKeys:name,@"id",command,@"command",
        [args length]?[args componentsSeparatedByString:@"|"]:[NSArray array],@"args",[NSMutableDictionary dictionary],@"env",[NSNumber numberWithBool:NO],@"enabled",nil];
    NSMutableArray *servers=[fields objectForKey:@"servers"];if(!servers){servers=[NSMutableArray array];[fields setObject:servers forKey:@"servers"];}
    [servers addObject:s];[self renderServers];
    [[fields objectForKey:@"status"] setStringValue:@"Added disabled. Enable only trusted executables, then Save."];
}
- (NSDictionary *)integrationFormData
{
    NSMutableDictionary *fields=[self integrationFields];NSMutableDictionary *data=[NSMutableDictionary dictionary];
    NSArray *keys=[NSArray arrayWithObjects:@"ppc_enabled",@"toolbox_enabled",@"search_enabled",@"grok_native_search",@"claude_thinking",@"clear_search_key",@"clear_tavily_key",nil];unsigned i;
    for(i=0;i<[keys count];i++)[data setObject:[NSNumber numberWithBool:[[fields objectForKey:[keys objectAtIndex:i]] state]==NSOnState] forKey:[keys objectAtIndex:i]];
    [data setObject:[[fields objectForKey:@"search_api_key"] stringValue] forKey:@"search_api_key"];
    [data setObject:[[fields objectForKey:@"tavily_api_key"] stringValue] forKey:@"tavily_api_key"];
    [data setObject:[[fields objectForKey:@"search_provider"] indexOfSelectedItem]==1?@"tavily":@"brave" forKey:@"search_provider"];
    [data setObject:[fields objectForKey:@"servers"] forKey:@"servers"];return data;
}
- (void)saveIntegrations:(id)sender
{
    (void)sender;
    if(NSRunAlertPanel(@"Enable relay tools?",@"Custom MCP executables run on the relay Mac with its user's permissions. "
        @"Enable only servers you trust. This configuration applies to every client of the relay.",@"Save",@"Cancel",nil)!=NSAlertDefaultReturn)return;
    NSString *error=nil;NSData *data=[NSPropertyListSerialization dataFromPropertyList:[self integrationFormData] format:NSPropertyListXMLFormat_v1_0 errorDescription:&error];
    if(error)[error release];NSString *text=[[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    [RelayRequest send:@"POST" path:@"/v1/integrations" body:text timeout:20 target:self action:@selector(integrationsSaved:) context:nil];
}
- (void)integrationsSaved:(RelayRequest *)request
{
    [[[self integrationFields] objectForKey:@"status"] setStringValue:[request ok]?@"Saved. New chat turns use the updated tools.":[request text]];
    if([request ok]){[[[self integrationFields] objectForKey:@"tavily_api_key"] setStringValue:@""];[[[self integrationFields] objectForKey:@"clear_tavily_key"] setState:NSOffState];[[[self integrationFields] objectForKey:@"search_api_key"] setStringValue:@""];[[[self integrationFields] objectForKey:@"clear_search_key"] setState:NSOffState];}
}

- (void)exportAllSettings:(id)sender
{
    (void)sender;
    if(NSRunAlertPanel(@"Export all settings?",@"This backup includes API keys, the relay token, custom MCP settings and environment secrets in plaintext. "
        @"Keep it private. Chat history and SSH private-key files are not included.",@"Export",@"Cancel",nil)!=NSAlertDefaultReturn)return;
    [RelayRequest send:@"GET" path:@"/v1/config-export" body:nil timeout:20 target:self action:@selector(settingsBackupArrived:) context:nil];
}
- (void)settingsBackupArrived:(RelayRequest *)request
{
    if(![request ok]){NSRunAlertPanel(@"Settings backup",@"%@",@"OK",nil,nil,[self relayProblemForRequest:request]);return;}
    NSSavePanel *panel=[NSSavePanel savePanel];[panel setRequiredFileType:@"plist"];
    if([panel runModalForDirectory:nil file:@"TigerBuild-all-settings.plist"]!=NSOKButton)return;
    NSString *domain=[[NSBundle mainBundle] bundleIdentifier];
    NSDictionary *defaults=[[NSUserDefaults standardUserDefaults] persistentDomainForName:domain];
    NSDictionary *client=[NSDictionary dictionaryWithObjectsAndKeys:[RelayRequest serverBase],@"server",[RelayRequest token],@"token",
        defaults?defaults:[NSDictionary dictionary],@"preferences",[self commanderCommand:@"status"],@"commander",nil];
    NSDictionary *backup=[NSDictionary dictionaryWithObjectsAndKeys:@"TigerBuild-config",@"format",[NSNumber numberWithInt:1],@"version",
        client,@"client",[request data],@"relay",nil];
    NSString *error=nil;NSData *data=[NSPropertyListSerialization dataFromPropertyList:backup format:NSPropertyListXMLFormat_v1_0 errorDescription:&error];
    if(error)[error release];
    if(![data writeToFile:[panel filename] atomically:YES]){NSRunAlertPanel(@"Settings backup",@"Could not save settings.",@"OK",nil,nil);return;}
    [[NSFileManager defaultManager] changeFileAttributes:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:0600] forKey:NSFilePosixPermissions] atPath:[panel filename]];
}
- (void)importAllSettings:(id)sender
{
    (void)sender;
    NSOpenPanel *panel=[NSOpenPanel openPanel];[panel setAllowsMultipleSelection:NO];
    if([panel runModalForDirectory:nil file:nil types:[NSArray arrayWithObject:@"plist"]]!=NSOKButton)return;
    NSData *data=[NSData dataWithContentsOfFile:[panel filename]];NSString *error=nil;
    if([data length]>3*1024*1024){NSRunAlertPanel(@"Settings",@"Backup exceeds 3 MB.",@"OK",nil,nil);return;}
    NSDictionary *backup=[NSPropertyListSerialization propertyListFromData:data mutabilityOption:NSPropertyListMutableContainers format:NULL errorDescription:&error];
    if(error)[error release];
    if([backup isKindOfClass:[NSDictionary class]]&&([[backup objectForKey:@"format"] isEqualToString:@"TigerDesk-config"]||[[backup objectForKey:@"format"] isEqualToString:@"TigerBuildRelay-config"])) {
        if(NSRunAlertPanel(@"Import relay settings?",@"This restores API keys and tools on the current relay. "
            @"Client settings and the relay's active connection stay unchanged. Imported custom MCPs remain disabled.",
            @"Import",@"Cancel",nil)!=NSAlertDefaultReturn)return;
        NSString *text=[[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
        [RelayRequest send:@"POST" path:@"/v1/config-import" body:text timeout:20 target:self action:@selector(relayOnlySettingsImported:) context:nil];
        return;
    }
    if(![backup isKindOfClass:[NSDictionary class]]||![[backup objectForKey:@"format"] isEqualToString:@"TigerBuild-config"]
        ||[[backup objectForKey:@"version"] intValue]!=1||![[backup objectForKey:@"relay"] isKindOfClass:[NSData class]]) {
        NSRunAlertPanel(@"Settings",@"Not a supported Tiger Build settings backup.",@"OK",nil,nil);return;
    }
    NSDictionary *client=[backup objectForKey:@"client"];
    if(![client isKindOfClass:[NSDictionary class]]||![[client objectForKey:@"server"] isKindOfClass:[NSString class]]
        ||![[client objectForKey:@"token"] isKindOfClass:[NSString class]]||![[client objectForKey:@"preferences"] isKindOfClass:[NSDictionary class]]) {
        NSRunAlertPanel(@"Settings",@"Malformed client configuration.",@"OK",nil,nil);return;
    }
    if(NSRunAlertPanel(@"Replace settings?",@"This replaces client preferences, Commander login settings and the current relay's API/tool configuration. "
        @"Custom MCP servers are imported disabled. The relay's active network and SSH settings stay unchanged. "
        @"Chat history is not affected. Export current settings first.",@"Import",@"Cancel",nil)!=NSAlertDefaultReturn)return;
    NSString *text=[[[NSString alloc] initWithData:[backup objectForKey:@"relay"] encoding:NSUTF8StringEncoding] autorelease];
    [RelayRequest send:@"POST" path:@"/v1/config-import" body:text timeout:20 target:self action:@selector(settingsBackupImported:) context:backup];
}
- (void)relayOnlySettingsImported:(RelayRequest *)request
{
    NSRunAlertPanel(@"Settings",@"%@",@"OK",nil,nil,[request ok]?@"Relay settings imported. Custom servers remain disabled.":[request text]);
    if([request ok]){[self refreshCatalog];[self refreshLocalModels];}
}
- (void)settingsBackupImported:(RelayRequest *)request
{
    if(![request ok]){NSRunAlertPanel(@"Settings",@"%@",@"OK",nil,nil,[request text]);return;}
    [self applyClientBackup:[request context]];
    [self refreshCatalog];[self refreshLocalModels];
    NSRunAlertPanel(@"Settings",@"Imported. Custom MCP servers remain disabled until explicitly enabled. "
        @"Some window preferences take effect at next launch.",@"OK",nil,nil);
}
- (void)applyClientBackup:(NSDictionary *)backup
{
    NSDictionary *client=[backup objectForKey:@"client"];
    [RelayRequest saveServerBase:[client objectForKey:@"server"] token:[client objectForKey:@"token"]];
    [[NSUserDefaults standardUserDefaults] setPersistentDomain:[client objectForKey:@"preferences"] forName:[[NSBundle mainBundle] bundleIdentifier]];
    NSDictionary *commander=[client objectForKey:@"commander"];
    if([commander isKindOfClass:[NSDictionary class]]) {
        [self commanderCommand:([[commander objectForKey:@"autostart"] intValue]!=0)?@"autostart-on":@"autostart-off"];
        [self commanderCommand:([[commander objectForKey:@"enabled"] intValue]!=0)?@"start":@"stop"];
    }
}
@end
