#import "ChatController_Private.h"

/* The tools window: the relay's switches for Commander and the built-in tools,
   web search keys, and the list of custom MCP servers. It is tabbed so every
   control fits a 1024x768 screen. */

@interface ChatController (IntegrationPrivate)
- (NSMutableDictionary *)integrationFields;
- (void)loadIntegrationForm:(NSDictionary *)data;
- (NSDictionary *)integrationFormData;
- (void)applyClientBackup:(NSDictionary *)backup;
- (void)integrationStatus:(NSString *)text;
@end

/* Data source for the server table. Rows are the same dictionaries the relay
   saves, so checking a box changes the data directly. */
@interface TBServerSource : NSObject {
    NSMutableArray *servers;
}
- (NSMutableArray *)servers;
- (void)setServers:(NSArray *)list;
@end

@implementation TBServerSource
- (id)init
{
    self = [super init];
    servers = [[NSMutableArray alloc] init];
    return self;
}
- (void)dealloc
{
    [servers release];
    [super dealloc];
}
- (NSMutableArray *)servers { return servers; }
- (void)setServers:(NSArray *)list
{
    unsigned i;
    [servers removeAllObjects];
    for (i = 0; i < [list count]; i++)
        [servers addObject:[NSMutableDictionary dictionaryWithDictionary:[list objectAtIndex:i]]];
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)aTable
{
    (void)aTable;
    return (NSInteger)[servers count];
}
- (id)tableView:(NSTableView *)aTable objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
    NSDictionary *server;
    NSString *ident = [column identifier];
    (void)aTable;
    if (row < 0 || row >= (NSInteger)[servers count])
        return @"";
    server = [servers objectAtIndex:row];
    if ([ident isEqualToString:@"on"])
        return [NSNumber numberWithBool:[[server objectForKey:@"enabled"] boolValue]];
    if ([ident isEqualToString:@"ask"])
        return [NSNumber numberWithBool:[[server objectForKey:@"approval"] boolValue]];
    if ([ident isEqualToString:@"name"])
        return [[server objectForKey:@"title"] length] ? [server objectForKey:@"title"] : [server objectForKey:@"id"];
    return [server objectForKey:@"command"];
}
- (void)tableView:(NSTableView *)aTable setObjectValue:(id)value forTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
    NSString *ident = [column identifier];
    (void)aTable;
    if (row < 0 || row >= (NSInteger)[servers count])
        return;
    if ([ident isEqualToString:@"on"])
        [[servers objectAtIndex:row] setObject:[NSNumber numberWithBool:[value boolValue]] forKey:@"enabled"];
    else if ([ident isEqualToString:@"ask"])
        [[servers objectAtIndex:row] setObject:[NSNumber numberWithBool:[value boolValue]] forKey:@"approval"];
}
- (BOOL)tableView:(NSTableView *)aTable shouldEditTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
    (void)aTable;
    (void)row;
    return [[column identifier] isEqualToString:@"on"] || [[column identifier] isEqualToString:@"ask"];
}
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
    [f setFont:[NSFont systemFontOfSize:12]];[[f cell] setWraps:YES];[view addSubview:f];return f;
}
- (NSView *)integrationTab:(NSString *)label in:(NSTabView *)tabs
{
    NSTabViewItem *item = [[[NSTabViewItem alloc] initWithIdentifier:label] autorelease];
    NSView *view = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 556, 330)] autorelease];
    [item setLabel:label];[item setView:view];[tabs addTabViewItem:item];
    return view;
}
- (NSButton *)integrationSwitch:(NSString *)title key:(NSString *)key y:(float)y in:(NSView *)view
{
    NSButton *b = [[[NSButton alloc] initWithFrame:NSMakeRect(16, y, 524, 22)] autorelease];
    [b setButtonType:NSSwitchButton];[b setTitle:title];[view addSubview:b];
    [[self integrationFields] setObject:b forKey:key];
    return b;
}
- (void)integrationStatus:(NSString *)text
{
    [[[self integrationFields] objectForKey:@"status"] setStringValue:text ? text : @""];
}

- (void)showIntegrations:(id)sender
{
    (void)sender;
    NSMutableDictionary *fields=[self integrationFields];
    NSWindow *panel=[fields objectForKey:@"window"];
    if (!panel) {
        panel=[[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,600,470)
            styleMask:NSTitledWindowMask|NSClosableWindowMask backing:NSBackingStoreBuffered defer:NO] autorelease];
        [panel setReleasedWhenClosed:NO];[panel setTitle:@"MCP Servers and Agent Tools"];[panel center];
        [fields setObject:panel forKey:@"window"];
        NSView *view=[panel contentView];
        NSTabView *tabs=[[[NSTabView alloc] initWithFrame:NSMakeRect(12,56,576,404)] autorelease];
        [tabs setFont:[NSFont systemFontOfSize:12]];[view addSubview:tabs];
        NSView *tab=[self integrationTab:@"Built-in Tools" in:tabs];
        float y=292;
        [self integrationSwitch:@"Commander (built in): read and edit files and run commands on the chat's Mac" key:@"ppc_enabled" y:y in:tab];y-=26;
        [self integrationSwitch:@"Ask first before Commander runs a tool (a chat can change this)" key:@"ppc_approval" y:y in:tab];y-=26;
        [self integrationSwitch:@"Agent toolbox (UTC time and scratch notes)" key:@"toolbox_enabled" y:y in:tab];y-=26;
        [self integrationSwitch:@"Ask other models: lets a model get a second opinion (a chat turns it on)" key:@"consult_enabled" y:y in:tab];y-=26;
        [self integrationSwitch:@"Web and picture search for other providers" key:@"search_enabled" y:y in:tab];y-=26;
        [self integrationSwitch:@"Grok native web search" key:@"grok_native_search" y:y in:tab];y-=26;
        [self integrationSwitch:@"Show model thinking (Claude, ChatGPT, Gemini, Mistral, local)" key:@"claude_thinking" y:y in:tab];y-=40;
        [self integrationLabel:@"Most tool steps in one reply" frame:NSMakeRect(16,y+2,200,18) view:tab];
        NSTextField *steps=[[[NSTextField alloc] initWithFrame:NSMakeRect(220,y,60,22)] autorelease];
        [steps setToolTip:@"A reply may use this many tool steps (1 to 200) before the relay stops it and says so. Say continue to go on."];
        [tab addSubview:steps];[fields setObject:steps forKey:@"max_tool_steps"];y-=30;
        [self integrationLabel:@"Each chat can switch these on or off from the Tools button, and choose which ones must ask first. "
            @"The switches here are the relay's: they apply to every Mac that uses it." frame:NSMakeRect(16,y-20,524,44) view:tab];
        tab=[self integrationTab:@"Web Search" in:tabs];
        y=284;
        [self integrationLabel:@"Search service" frame:NSMakeRect(16,y+2,170,18) view:tab];
        NSPopUpButton *provider=[[[NSPopUpButton alloc] initWithFrame:NSMakeRect(190,y-2,200,26) pullsDown:NO] autorelease];
        [provider addItemsWithTitles:[NSArray arrayWithObjects:@"Brave Search",@"Tavily",nil]];
        [tab addSubview:provider];[fields setObject:provider forKey:@"search_provider"];y-=40;
        [self integrationLabel:@"Brave Search API key" frame:NSMakeRect(16,y+2,170,18) view:tab];
        NSSecureTextField *key=[[[NSSecureTextField alloc] initWithFrame:NSMakeRect(190,y,350,24)] autorelease];
        [[key cell] setPlaceholderString:@"blank keeps the saved key"];
        [tab addSubview:key];[fields setObject:key forKey:@"search_api_key"];y-=28;
        NSButton *clear=[[[NSButton alloc] initWithFrame:NSMakeRect(190,y,350,22)] autorelease];
        [clear setButtonType:NSSwitchButton];[clear setTitle:@"Delete saved Brave key"];[tab addSubview:clear];[fields setObject:clear forKey:@"clear_search_key"];y-=40;
        [self integrationLabel:@"Tavily API key" frame:NSMakeRect(16,y+2,170,18) view:tab];
        NSSecureTextField *tavily=[[[NSSecureTextField alloc] initWithFrame:NSMakeRect(190,y,350,24)] autorelease];
        [[tavily cell] setPlaceholderString:@"blank keeps the saved key"];
        [tab addSubview:tavily];[fields setObject:tavily forKey:@"tavily_api_key"];y-=28;
        NSButton *clearT=[[[NSButton alloc] initWithFrame:NSMakeRect(190,y,350,22)] autorelease];
        [clearT setButtonType:NSSwitchButton];[clearT setTitle:@"Delete saved Tavily key"];[tab addSubview:clearT];[fields setObject:clearT forKey:@"clear_tavily_key"];

        tab=[self integrationTab:@"MCP Servers" in:tabs];
        [self integrationLabel:@"Custom stdio servers run on the relay Mac, not on the chat's Mac. Only add programs you trust; new ones start switched off."
            frame:NSMakeRect(16,288,524,32) view:tab];
        NSScrollView *scroll=[[[NSScrollView alloc] initWithFrame:NSMakeRect(16,52,524,230)] autorelease];
        [scroll setHasVerticalScroller:YES];[scroll setBorderType:NSBezelBorder];
        NSTableView *list=[[[NSTableView alloc] initWithFrame:NSMakeRect(0,0,500,230)] autorelease];
        TBServerSource *source=[[[TBServerSource alloc] init] autorelease];
        [fields setObject:source forKey:@"source"];[fields setObject:list forKey:@"table"];
        NSArray *ids=[NSArray arrayWithObjects:@"on",@"name",@"command",@"ask",nil];
        NSArray *heads=[NSArray arrayWithObjects:@"On",@"Server",@"Program",@"Ask first",nil];
        float widths[4]={34,140,250,64};unsigned c;
        for(c=0;c<4;c++) {
            NSTableColumn *col=[[[NSTableColumn alloc] initWithIdentifier:[ids objectAtIndex:c]] autorelease];
            [[col headerCell] setStringValue:[heads objectAtIndex:c]];[col setWidth:widths[c]];
            if(c==0||c==3){NSButtonCell *cell=[[[NSButtonCell alloc] init] autorelease];[cell setButtonType:NSSwitchButton];[cell setTitle:@""];[col setDataCell:cell];[col setEditable:YES];}
            else {[[col dataCell] setFont:[NSFont systemFontOfSize:12]];[col setEditable:NO];}
            [list addTableColumn:col];
        }
        [list setDataSource:source];[list setRowHeight:20];[list setAllowsEmptySelection:YES];[list setDoubleAction:@selector(editIntegrationServer:)];[list setTarget:self];
        [scroll setDocumentView:list];[tab addSubview:scroll];
        NSArray *labels=[NSArray arrayWithObjects:@"Add...",@"Edit...",@"Remove",nil];
        SEL acts[]={@selector(addIntegrationServer:),@selector(editIntegrationServer:),@selector(removeIntegrationServer:)};
        unsigned i;
        for(i=0;i<3;i++) {
            NSButton *b=[[[NSButton alloc] initWithFrame:NSMakeRect(16+i*100,12,94,28)] autorelease];
            [b setTitle:[labels objectAtIndex:i]];[b setBezelStyle:NSRoundedBezelStyle];[b setTarget:self];[b setAction:acts[i]];[tab addSubview:b];
        }
        NSTextField *status=[self integrationLabel:@"Loading..." frame:NSMakeRect(16,22,360,30) view:view];[fields setObject:status forKey:@"status"];
        NSButton *save=[[[NSButton alloc] initWithFrame:NSMakeRect(396,16,94,30)] autorelease];
        [save setTitle:@"Save"];[save setBezelStyle:NSRoundedBezelStyle];[save setKeyEquivalent:@"\r"];[save setTarget:self];[save setAction:@selector(saveIntegrations:)];[view addSubview:save];[fields setObject:save forKey:@"save"];
        NSButton *close=[[[NSButton alloc] initWithFrame:NSMakeRect(494,16,94,30)] autorelease];
        [close setTitle:@"Close"];[close setBezelStyle:NSRoundedBezelStyle];[close setKeyEquivalent:@"\033"];[close setTarget:panel];[close setAction:@selector(performClose:)];[view addSubview:close];
    }
    [[fields objectForKey:@"save"] setEnabled:NO];
    [self integrationStatus:@"Loading..."];
    [panel makeKeyAndOrderFront:nil];
    [RelayRequest send:@"GET" path:@"/v1/integrations" body:nil timeout:15 target:self action:@selector(integrationsArrived:) context:nil];
}
- (void)integrationsArrived:(RelayRequest *)request
{
    NSMutableDictionary *fields=[self integrationFields];
    if(![request ok]) {[self integrationStatus:[self relayProblemForRequest:request]];return;}
    NSString *error=nil;
    NSDictionary *data=[NSPropertyListSerialization propertyListFromData:[request data] mutabilityOption:NSPropertyListMutableContainers format:NULL errorDescription:&error];
    if(error)[error release];
    if(![data isKindOfClass:[NSDictionary class]])return;
    [self loadIntegrationForm:data];[[fields objectForKey:@"save"] setEnabled:YES];
}
- (void)loadIntegrationForm:(NSDictionary *)data
{
    NSMutableDictionary *fields=[self integrationFields];
    NSArray *keys=[NSArray arrayWithObjects:@"ppc_enabled",@"ppc_approval",@"toolbox_enabled",@"consult_enabled",@"search_enabled",@"grok_native_search",@"claude_thinking",nil];
    unsigned i;
    for(i=0;i<[keys count];i++)[[fields objectForKey:[keys objectAtIndex:i]] setState:[[data objectForKey:[keys objectAtIndex:i]] boolValue]?NSOnState:NSOffState];
    [(TBServerSource *)[fields objectForKey:@"source"] setServers:[data objectForKey:@"servers"]];
    [[fields objectForKey:@"max_tool_steps"] setStringValue:[NSString stringWithFormat:@"%d",[[data objectForKey:@"max_tool_steps"] intValue]>0?[[data objectForKey:@"max_tool_steps"] intValue]:40]];
    [[fields objectForKey:@"table"] reloadData];
    [[fields objectForKey:@"search_api_key"] setStringValue:@""];[[fields objectForKey:@"clear_search_key"] setState:NSOffState];
    [[fields objectForKey:@"tavily_api_key"] setStringValue:@""];[[fields objectForKey:@"clear_tavily_key"] setState:NSOffState];
    [[fields objectForKey:@"search_provider"] selectItemAtIndex:[[data objectForKey:@"search_provider"] isEqualToString:@"tavily"]?1:0];
    [self integrationStatus:[NSString stringWithFormat:@"Saved keys: Brave %@, Tavily %@.",
        ([[data objectForKey:@"search_key_saved"] intValue]!=0)?@"yes":@"no",[[data objectForKey:@"tavily_key_saved"] boolValue]?@"yes":@"no"]];
}

/* ---- the add/edit sheet for one server ---- */

- (void)serverSheetDone:(id)sender {(void)sender;[[NSApp modalWindow] makeFirstResponder:nil];[NSApp stopModalWithCode:1];}
- (void)serverSheetCancel:(id)sender {(void)sender;[NSApp stopModalWithCode:0];}

/* server nil adds a new one. Returns the edited dictionary, or nil when cancelled. */
- (NSMutableDictionary *)runServerSheet:(NSDictionary *)server
{
    NSPanel *panel=[[[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,520,356) styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO] autorelease];
    NSView *view=[panel contentView];
    NSArray *labels=[NSArray arrayWithObjects:@"Server ID",@"Name (optional)",@"Program path",@"Arguments",nil];
    NSMutableArray *fieldList=[NSMutableArray array];
    unsigned i;
    [panel setTitle:server?@"Edit MCP Server":@"Add MCP Server"];[panel center];
    for(i=0;i<4;i++) {
        float y=312-i*36;
        [self integrationLabel:[labels objectAtIndex:i] frame:NSMakeRect(16,y+2,120,18) view:view];
        NSTextField *f=[[[NSTextField alloc] initWithFrame:NSMakeRect(140,y,364,24)] autorelease];[view addSubview:f];[fieldList addObject:f];
    }
    [[fieldList objectAtIndex:0] setToolTip:@"Letters, digits and underscore, up to 20 characters. Used to name its tools."];
    [[fieldList objectAtIndex:2] setToolTip:@"Absolute path of the program on the relay Mac."];
    [[fieldList objectAtIndex:3] setToolTip:@"Separate arguments with | (pipe). No shell expansion. Example: /path/server.py|--stdio"];
    [self integrationLabel:@"Environment" frame:NSMakeRect(16,168,120,18) view:view];
    NSScrollView *envScroll=[[[NSScrollView alloc] initWithFrame:NSMakeRect(140,100,364,86)] autorelease];
    [envScroll setHasVerticalScroller:YES];[envScroll setBorderType:NSBezelBorder];
    NSTextView *env=[[[NSTextView alloc] initWithFrame:NSMakeRect(0,0,346,86)] autorelease];
    [env setFont:[NSFont fontWithName:@"Monaco" size:10]];[env setRichText:NO];[env setVerticallyResizable:YES];
    [env setMinSize:NSMakeSize(0,86)];[env setMaxSize:NSMakeSize(1000000,1000000)];
    [[env textContainer] setWidthTracksTextView:YES];
    [envScroll setDocumentView:env];[view addSubview:envScroll];
    [self integrationLabel:@"One NAME=value per line" frame:NSMakeRect(16,122,120,34) view:view];
    NSButton *on=[[[NSButton alloc] initWithFrame:NSMakeRect(140,72,364,22)] autorelease];
    [on setButtonType:NSSwitchButton];[on setTitle:@"Switched on (its tools run on the relay Mac)"];[view addSubview:on];
    NSButton *ask=[[[NSButton alloc] initWithFrame:NSMakeRect(140,48,364,22)] autorelease];
    [ask setButtonType:NSSwitchButton];[ask setTitle:@"Ask before running its tools"];[view addSubview:ask];
    if(server) {
        [[fieldList objectAtIndex:0] setStringValue:[server objectForKey:@"id"]];[[fieldList objectAtIndex:0] setEditable:NO];
        [[fieldList objectAtIndex:1] setStringValue:[server objectForKey:@"title"]?[server objectForKey:@"title"]:@""];
        [[fieldList objectAtIndex:2] setStringValue:[server objectForKey:@"command"]];
        [[fieldList objectAtIndex:3] setStringValue:[[server objectForKey:@"args"] componentsJoinedByString:@"|"]];
        NSMutableString *text=[NSMutableString string];NSDictionary *vars=[server objectForKey:@"env"];NSEnumerator *names=[vars keyEnumerator];NSString *n;
        while((n=[names nextObject]))[text appendFormat:@"%@=%@\n",n,[vars objectForKey:n]];
        [env setString:text];
        [on setState:[[server objectForKey:@"enabled"] boolValue]?NSOnState:NSOffState];
        [ask setState:[[server objectForKey:@"approval"] boolValue]?NSOnState:NSOffState];
    }
    NSButton *okButton=[[[NSButton alloc] initWithFrame:NSMakeRect(318,10,90,30)] autorelease];
    [okButton setTitle:server?@"Done":@"Add"];[okButton setBezelStyle:NSRoundedBezelStyle];[okButton setKeyEquivalent:@"\r"];[okButton setTarget:self];[okButton setAction:@selector(serverSheetDone:)];[view addSubview:okButton];
    NSButton *cancel=[[[NSButton alloc] initWithFrame:NSMakeRect(414,10,90,30)] autorelease];
    [cancel setTitle:@"Cancel"];[cancel setBezelStyle:NSRoundedBezelStyle];[cancel setKeyEquivalent:@"\033"];[cancel setTarget:self];[cancel setAction:@selector(serverSheetCancel:)];[view addSubview:cancel];
    [panel makeKeyAndOrderFront:nil];[panel makeFirstResponder:[fieldList objectAtIndex:server?2:0]];
    int result=[NSApp runModalForWindow:panel];[panel orderOut:nil];
    if(result!=1)return nil;
    NSString *name=[[[fieldList objectAtIndex:0] stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *command=[[[fieldList objectAtIndex:2] stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if(![name length]||[name length]>20||![command hasPrefix:@"/"]) {
        NSRunAlertPanel(@"MCP Server",@"Enter an ID (letters, digits or underscore, up to 20 characters) and the absolute path of the program on the relay Mac.",@"OK",nil,nil);
        return nil;
    }
    NSString *args=[[fieldList objectAtIndex:3] stringValue];
    NSMutableDictionary *vars=[NSMutableDictionary dictionary];
    NSArray *lines=[[env string] componentsSeparatedByString:@"\n"];
    for(i=0;i<[lines count];i++) {
        NSString *line=[lines objectAtIndex:i];NSRange eq=[line rangeOfString:@"="];
        if(eq.location!=NSNotFound&&eq.location>0)[vars setObject:[line substringFromIndex:eq.location+1] forKey:[line substringToIndex:eq.location]];
    }
    return [NSMutableDictionary dictionaryWithObjectsAndKeys:name,@"id",[[fieldList objectAtIndex:1] stringValue],@"title",command,@"command",
        [args length]?[args componentsSeparatedByString:@"|"]:[NSArray array],@"args",vars,@"env",
        [NSNumber numberWithBool:[on state]==NSOnState],@"enabled",[NSNumber numberWithBool:[ask state]==NSOnState],@"approval",nil];
}
- (void)addIntegrationServer:(id)sender
{
    (void)sender;
    NSMutableDictionary *fields=[self integrationFields];
    TBServerSource *source=[fields objectForKey:@"source"];
    NSMutableDictionary *added=[self runServerSheet:nil];
    unsigned i;
    if(!added)return;
    for(i=0;i<[[source servers] count];i++) {
        if([[[[source servers] objectAtIndex:i] objectForKey:@"id"] isEqualToString:[added objectForKey:@"id"]]) {
            NSRunAlertPanel(@"MCP Server",@"There is already a server with that ID.",@"OK",nil,nil);return;
        }
    }
    /* Switched on only if the person said so in the sheet; a new server is otherwise off. */
    [[source servers] addObject:added];
    [[fields objectForKey:@"table"] reloadData];
    [self integrationStatus:[[added objectForKey:@"enabled"] boolValue]?@"Added and switched on. Save to apply. Enable only trusted programs.":@"Added switched off. Save to keep it."];
}
- (void)editIntegrationServer:(id)sender
{
    (void)sender;
    NSMutableDictionary *fields=[self integrationFields];
    TBServerSource *source=[fields objectForKey:@"source"];
    NSTableView *list=[fields objectForKey:@"table"];
    int row=[list selectedRow];
    if(row<0||row>=(int)[[source servers] count]){NSBeep();return;}
    NSMutableDictionary *edited=[self runServerSheet:[[source servers] objectAtIndex:row]];
    if(!edited)return;
    [[source servers] replaceObjectAtIndex:row withObject:edited];
    [list reloadData];
    [self integrationStatus:@"Changed. Save to apply."];
}
- (void)removeIntegrationServer:(id)sender
{
    (void)sender;
    NSMutableDictionary *fields=[self integrationFields];
    TBServerSource *source=[fields objectForKey:@"source"];
    NSTableView *list=[fields objectForKey:@"table"];
    int row=[list selectedRow];
    if(row<0||row>=(int)[[source servers] count]){NSBeep();return;}
    if(NSRunAlertPanel(@"Remove this server?",@"\"%@\" is removed from the relay's list when you Save.",@"Remove",@"Cancel",nil,[[[source servers] objectAtIndex:row] objectForKey:@"id"])!=NSAlertDefaultReturn)return;
    [[source servers] removeObjectAtIndex:row];
    [list reloadData];
    [self integrationStatus:@"Removed. Save to apply."];
}
- (NSDictionary *)integrationFormData
{
    NSMutableDictionary *fields=[self integrationFields];NSMutableDictionary *data=[NSMutableDictionary dictionary];
    NSArray *keys=[NSArray arrayWithObjects:@"ppc_enabled",@"ppc_approval",@"toolbox_enabled",@"consult_enabled",@"search_enabled",@"grok_native_search",@"claude_thinking",@"clear_search_key",@"clear_tavily_key",nil];unsigned i;
    for(i=0;i<[keys count];i++)[data setObject:[NSNumber numberWithBool:[[fields objectForKey:[keys objectAtIndex:i]] state]==NSOnState] forKey:[keys objectAtIndex:i]];
    [data setObject:[[fields objectForKey:@"search_api_key"] stringValue] forKey:@"search_api_key"];
    [data setObject:[[fields objectForKey:@"tavily_api_key"] stringValue] forKey:@"tavily_api_key"];
    [data setObject:[[fields objectForKey:@"search_provider"] indexOfSelectedItem]==1?@"tavily":@"brave" forKey:@"search_provider"];
    {int steps=[[[fields objectForKey:@"max_tool_steps"] stringValue] intValue];if(steps<1)steps=40;if(steps>200)steps=200;
        [data setObject:[NSNumber numberWithInt:steps] forKey:@"max_tool_steps"];}
    [data setObject:[(TBServerSource *)[fields objectForKey:@"source"] servers] forKey:@"servers"];return data;
}
- (void)saveIntegrations:(id)sender
{
    (void)sender;
    BOOL anyOn=NO;
    NSArray *servers=[(TBServerSource *)[[self integrationFields] objectForKey:@"source"] servers];
    unsigned i;
    for(i=0;i<[servers count];i++)if([[[servers objectAtIndex:i] objectForKey:@"enabled"] boolValue])anyOn=YES;
    if(anyOn&&NSRunAlertPanel(@"Enable relay tools?",@"Custom MCP executables run on the relay Mac with its user's permissions. "
        @"Enable only servers you trust. This configuration applies to every client of the relay.",@"Save",@"Cancel",nil)!=NSAlertDefaultReturn)return;
    NSString *error=nil;NSData *data=[NSPropertyListSerialization dataFromPropertyList:[self integrationFormData] format:NSPropertyListXMLFormat_v1_0 errorDescription:&error];
    if(error)[error release];NSString *text=[[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    [RelayRequest send:@"POST" path:@"/v1/integrations" body:text timeout:20 target:self action:@selector(integrationsSaved:) context:nil];
}
- (void)integrationsSaved:(RelayRequest *)request
{
    [self integrationStatus:[request ok]?@"Saved. New chat turns use the updated tools.":[request text]];
    if([request ok]){[[[self integrationFields] objectForKey:@"tavily_api_key"] setStringValue:@""];[[[self integrationFields] objectForKey:@"clear_tavily_key"] setState:NSOffState];[[[self integrationFields] objectForKey:@"search_api_key"] setStringValue:@""];[[[self integrationFields] objectForKey:@"clear_search_key"] setState:NSOffState];[self refreshToolCatalog];}
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
    if(NSRunAlertPanel(@"Replace settings?",@"This replaces your preferences, Commander login settings and the relay's API and tool settings. MCP servers are imported disabled. "
        @"The relay's network and SSH settings and your chats are unchanged. Export current settings first.",@"Import",@"Cancel",nil)!=NSAlertDefaultReturn)return;
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
