#import "ChatController_Private.h"
#import "TBSSH.h"
#import "TBEngine.h"

/* The tools window: the switches for Commander and the built-in tools,
   web search keys, and the list of custom MCP servers. It is tabbed so every
   control fits a 1024x768 screen. */

@interface ChatController (IntegrationPrivate)
- (NSMutableDictionary *)integrationFields;
- (void)loadIntegrationForm:(NSDictionary *)data;
- (void)fillSubagentPolicyPopup:(NSString *)saved;
- (NSDictionary *)integrationFormData;
- (void)applyClientBackup:(NSDictionary *)backup;
- (void)integrationStatus:(NSString *)text;
@end

/* Data source for the server table. Rows are the same dictionaries the relay
   saves, so checking a box changes the data directly. */
@interface TBServerSource : NSObject TB_PROTOCOLS(NSTableViewDataSource) {
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
        [self integrationSwitch:@"Commander (built in): read and edit files and run commands on the chat's Mac" key:@"ppc_enabled" y:y in:tab];y-=23;
        [self integrationSwitch:@"Ask first before Commander runs a tool (a chat can change this)" key:@"ppc_approval" y:y in:tab];y-=23;
        [self integrationSwitch:@"Agent toolbox (UTC time and scratch notes)" key:@"toolbox_enabled" y:y in:tab];y-=23;
        [self integrationSwitch:@"Ask other models: lets a model get a second opinion (a chat turns it on)" key:@"consult_enabled" y:y in:tab];y-=23;
        [self integrationSwitch:@"Let models start subagents: parallel helpers (off by default; a chat turns it on)" key:@"subagents_enabled" y:y in:tab];y-=23;
        [self integrationSwitch:@"Web and picture search for other providers" key:@"search_enabled" y:y in:tab];y-=23;
        [self integrationSwitch:@"Grok native web search" key:@"grok_native_search" y:y in:tab];y-=23;
        [self integrationSwitch:@"Gemini searches with Google (needs a Gemini key)" key:@"gemini_native_search" y:y in:tab];y-=23;
        [self integrationSwitch:@"Show model thinking (Claude, ChatGPT, Gemini, Mistral, local)" key:@"claude_thinking" y:y in:tab];y-=34;
        [self integrationLabel:@"Most tool steps in one reply" frame:NSMakeRect(16,y+2,200,18) view:tab];
        NSTextField *steps=[[[NSTextField alloc] initWithFrame:NSMakeRect(220,y,60,22)] autorelease];
        [steps setToolTip:@"A reply may use this many tool steps (1 to 1000; 0 means no limit, which can run up cost) before Tiger Build stops it and says so. Say continue to go on."];
        [tab addSubview:steps];[fields setObject:steps forKey:@"max_tool_steps"];y-=30;
        [self integrationLabel:@"Each chat can switch these on or off from the Tools button, and choose which ones must ask first. "
            @"The switches here apply to all your chats." frame:NSMakeRect(16,y-20,524,44) view:tab];
        tab=[self integrationTab:@"Subagents" in:tabs];
        y=284;
        [self integrationLabel:@"With subagents on (Built-in Tools, and the chat's Tools menu), a model can start helpers that work on parts of a task at the same time, "
            @"each with its own conversation and the chat's tools. Their cost is counted in the chat." frame:NSMakeRect(16,y-34,524,50) view:tab];y-=60;
        [self integrationLabel:@"Most helpers in one request" frame:NSMakeRect(16,y+2,230,18) view:tab];
        NSTextField *subTasks=[[[NSTextField alloc] initWithFrame:NSMakeRect(250,y,60,22)] autorelease];
        [subTasks setToolTip:@"1 to 16. A request with more tasks than this is refused and the model is told the limit."];
        [tab addSubview:subTasks];[fields setObject:subTasks forKey:@"subagents_tasks"];y-=32;
        [self integrationLabel:@"Most helpers running at once" frame:NSMakeRect(16,y+2,230,18) view:tab];
        NSTextField *subMax=[[[NSTextField alloc] initWithFrame:NSMakeRect(250,y,60,22)] autorelease];
        [subMax setToolTip:@"1 to 8. The Mac's cores, up to 4, unless you change it. The rest of a request waits for a free helper."];
        [tab addSubview:subMax];[fields setObject:subMax forKey:@"subagents_max"];y-=36;
        [self integrationLabel:@"Helpers use" frame:NSMakeRect(16,y+2,230,18) view:tab];
        NSPopUpButton *subPolicy=[[[NSPopUpButton alloc] initWithFrame:NSMakeRect(250,y-2,290,26) pullsDown:NO] autorelease];
        [subPolicy setFont:[NSFont systemFontOfSize:12]];
        [tab addSubview:subPolicy];[fields setObject:subPolicy forKey:@"subagents_policy"];y-=40;
        [self integrationLabel:@"\"The model picks\" lets a model choose a model for each task and shows it the list with notes on each, so a larger model can hand simple work to a smaller, cheaper one "
            @"(a Sonnet-class model handing searches to a Haiku-class one, for example). It uses the chat's own model when it does not choose." frame:NSMakeRect(16,y-50,524,64) view:tab];
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
        [clearT setButtonType:NSSwitchButton];[clearT setTitle:@"Delete saved Tavily key"];[tab addSubview:clearT];[fields setObject:clearT forKey:@"clear_tavily_key"];y-=40;
        [self integrationSwitch:@"Let models download files over https (off by default)" key:@"download_enabled" y:y in:tab];y-=26;

        tab=[self integrationTab:@"MCP Servers" in:tabs];
        [self integrationLabel:@"Custom servers are programs on this Mac, programs on another computer over SSH, or http:// and https:// addresses. Only add ones you trust."
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
    [panel setLevel:NSFloatingWindowLevel];
    [panel makeKeyAndOrderFront:nil];
    [EngineRequest send:@"GET" path:@"/v1/integrations" body:nil timeout:15 target:self action:@selector(integrationsArrived:) context:nil];
}
- (void)integrationsArrived:(EngineRequest *)request
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
    NSArray *keys=[NSArray arrayWithObjects:@"ppc_enabled",@"ppc_approval",@"toolbox_enabled",@"consult_enabled",@"search_enabled",@"grok_native_search",@"gemini_native_search",@"download_enabled",@"subagents_enabled",@"claude_thinking",nil];
    unsigned i;
    for(i=0;i<[keys count];i++)[[fields objectForKey:[keys objectAtIndex:i]] setState:[[data objectForKey:[keys objectAtIndex:i]] boolValue]?NSOnState:NSOffState];
    [(TBServerSource *)[fields objectForKey:@"source"] setServers:[data objectForKey:@"servers"]];
    [[fields objectForKey:@"subagents_tasks"] setStringValue:[NSString stringWithFormat:@"%d",[[data objectForKey:@"subagents_tasks"] intValue]?[[data objectForKey:@"subagents_tasks"] intValue]:8]];
    [[fields objectForKey:@"subagents_max"] setStringValue:[NSString stringWithFormat:@"%d",[[data objectForKey:@"subagents_max"] intValue]?[[data objectForKey:@"subagents_max"] intValue]:4]];
    [self fillSubagentPolicyPopup:[data objectForKey:@"subagents_policy"]];
    [[fields objectForKey:@"max_tool_steps"] setStringValue:[NSString stringWithFormat:@"%d",[data objectForKey:@"max_tool_steps"]?[[data objectForKey:@"max_tool_steps"] intValue]:40]];
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

static NSString *const kRemoteCommander = @"\"/Applications/Tiger Build.app/Contents/Resources/ppc-commander\"";

/* 0 program on this Mac, 1 web address, 2 another computer over SSH, 3 Commander on another computer */
- (void)serverKindChanged:(id)sender
{
    NSMutableDictionary *f=[self integrationFields];
    int kind=[(NSPopUpButton *)sender indexOfSelectedItem];
    BOOL ssh=kind>=2;
    NSTextField *program=[f objectForKey:@"sheetProgram"],*args=[f objectForKey:@"sheetArgs"];
    unsigned i;
    [[f objectForKey:@"sheetProgramLabel"] setStringValue:ssh?@"User and address":(kind==1?@"Web address":@"Program path")];
    [[f objectForKey:@"sheetArgsLabel"] setStringValue:ssh?@"Run there":@"Arguments"];
    [program setToolTip:ssh?@"user@address of the other computer, for example thomas@10.0.1.50. It needs Remote Login on, and Tiger Build's key in its ~/.ssh/authorized_keys.":
        @"Absolute path of a program on this Mac, or an http:// or https:// address of a Streamable HTTP server (a token goes in Environment as MCP_AUTH_TOKEN=...)."];
    [args setToolTip:ssh?@"The command to run on the other computer. It must speak MCP on standard input and output.":@"Separate arguments with | (pipe). No shell expansion. Example: /path/server.py|--stdio"];
    if(kind==3&&![[args stringValue] length])[args setStringValue:kRemoteCommander];
    for(i=0;i<[[f objectForKey:@"sheetSSH"] count];i++)[[[f objectForKey:@"sheetSSH"] objectAtIndex:i] setHidden:!ssh];
}
- (void)sheetStatus:(NSString *)text {[[[self integrationFields] objectForKey:@"sheetStatus"] setStringValue:text?text:@""];[[[self integrationFields] objectForKey:@"sheetStatus"] displayIfNeeded];}
- (NSString *)sheetTarget {return TBTrim([[[self integrationFields] objectForKey:@"sheetProgram"] stringValue]);}
- (void)sheetCopyKey:(id)sender
{
    (void)sender;
    NSString *key=[TBSSH publicKeyForHost:[TBSSH hostOfTarget:[self sheetTarget]]];
    if(!key){[self sheetStatus:@"Tiger Build could not make its SSH key."];return;}
    [[NSPasteboard generalPasteboard] declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
    [[NSPasteboard generalPasteboard] setString:key forType:NSStringPboardType];
    [self sheetStatus:@"Key copied. Add it as a line in ~/.ssh/authorized_keys on the other computer (for a Tiger Build SSH server, in its authorized keys file), then Trust Host."];
}
- (void)sheetTrust:(id)sender
{
    (void)sender;
    NSString *problem=nil,*print,*host=[TBSSH hostOfTarget:[self sheetTarget]];
    [self sheetStatus:@"Looking at the other computer's key..."];
    print=[TBSSH fingerprintOfHost:host problem:&problem];
    if(!print){[self sheetStatus:problem];return;}
    if(NSRunAlertPanel(@"Trust this computer?",@"%@ identifies itself with this key:\n\n%@\n\nTrust it only if this matches the other computer. Tiger Build will refuse to connect if the key ever changes.",@"Trust",@"Cancel",nil,host,print)!=NSAlertDefaultReturn){[self sheetStatus:@"Not trusted."];return;}
    if([TBSSH trustHost:host problem:&problem])[self sheetStatus:@"Trusted. Now choose Test."];else [self sheetStatus:problem];
}
- (void)sheetTest:(id)sender
{
    (void)sender;
    NSString *why;
    [self sheetStatus:@"Testing..."];
    why=[TBSSH testTarget:[self sheetTarget]];
    [self sheetStatus:why?why:@"Connected."];
}

/* server nil adds a new one. Returns the edited dictionary, or nil when cancelled. */
- (NSMutableDictionary *)runServerSheet:(NSDictionary *)server
{
    NSMutableDictionary *f=[self integrationFields];
    NSPanel *panel=[[[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,520,560) styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO] autorelease];
    NSView *view=[panel contentView];
    NSArray *labels=[NSArray arrayWithObjects:@"Server ID",@"Name (optional)",@"Program path",@"Arguments",nil];
    NSMutableArray *fieldList=[NSMutableArray array],*sshViews=[NSMutableArray array];
    NSString *oldCommand=server?[server objectForKey:@"command"]:@"";
    unsigned i;
    [panel setTitle:server?@"Edit MCP Server":@"Add MCP Server"];[panel center];[panel setLevel:NSFloatingWindowLevel];
    [self integrationLabel:@"Type" frame:NSMakeRect(16,522,120,18) view:view];
    NSPopUpButton *kind=[[[NSPopUpButton alloc] initWithFrame:NSMakeRect(140,518,364,26) pullsDown:NO] autorelease];
    [kind addItemsWithTitles:[NSArray arrayWithObjects:@"Program on this Mac",@"Web address (Streamable HTTP)",@"Program on another computer (SSH)",@"Commander on another computer (SSH)",nil]];
    [kind setTarget:self];[kind setAction:@selector(serverKindChanged:)];[view addSubview:kind];[f setObject:kind forKey:@"sheetKind"];
    for(i=0;i<4;i++) {
        float y=478-i*34;
        NSTextField *l=[self integrationLabel:[labels objectAtIndex:i] frame:NSMakeRect(16,y+2,120,18) view:view];
        NSTextField *t=[[[NSTextField alloc] initWithFrame:NSMakeRect(140,y,364,24)] autorelease];[view addSubview:t];[fieldList addObject:t];
        if(i==2){[f setObject:l forKey:@"sheetProgramLabel"];[f setObject:t forKey:@"sheetProgram"];}
        if(i==3){[f setObject:l forKey:@"sheetArgsLabel"];[f setObject:t forKey:@"sheetArgs"];}
    }
    [[fieldList objectAtIndex:0] setToolTip:@"Letters, digits and underscore, up to 20 characters. Used to name its tools."];
    [self integrationLabel:@"Description for the model" frame:NSMakeRect(16,318,120,34) view:view];
    NSScrollView *descScroll=[[[NSScrollView alloc] initWithFrame:NSMakeRect(140,286,364,76)] autorelease];
    [descScroll setHasVerticalScroller:YES];[descScroll setBorderType:NSBezelBorder];
    NSTextView *desc=[[[NSTextView alloc] initWithFrame:NSMakeRect(0,0,346,76)] autorelease];
    [desc setFont:[NSFont systemFontOfSize:11]];[desc setRichText:NO];[desc setVerticallyResizable:YES];
    [desc setMinSize:NSMakeSize(0,76)];[desc setMaxSize:NSMakeSize(1000000,1000000)];[[desc textContainer] setWidthTracksTextView:YES];
    [descScroll setDocumentView:desc];[view addSubview:descScroll];
    [desc setToolTip:@"Added to every tool of this server that the model sees: what the server is for and when to use it, or extra instructions."];
    [self integrationLabel:@"Environment" frame:NSMakeRect(16,252,120,18) view:view];
    NSScrollView *envScroll=[[[NSScrollView alloc] initWithFrame:NSMakeRect(140,186,364,90)] autorelease];
    [envScroll setHasVerticalScroller:YES];[envScroll setBorderType:NSBezelBorder];
    NSTextView *env=[[[NSTextView alloc] initWithFrame:NSMakeRect(0,0,346,90)] autorelease];
    [env setFont:[NSFont fontWithName:@"Monaco" size:10]];[env setRichText:NO];[env setVerticallyResizable:YES];
    [env setMinSize:NSMakeSize(0,90)];[env setMaxSize:NSMakeSize(1000000,1000000)];
    [[env textContainer] setWidthTracksTextView:YES];
    [envScroll setDocumentView:env];[view addSubview:envScroll];
    [self integrationLabel:@"One NAME=value per line" frame:NSMakeRect(16,214,120,34) view:view];
    NSButton *on=[[[NSButton alloc] initWithFrame:NSMakeRect(140,158,364,22)] autorelease];
    [on setButtonType:NSSwitchButton];[on setTitle:@"Switched on"];[view addSubview:on];
    NSButton *ask=[[[NSButton alloc] initWithFrame:NSMakeRect(140,134,364,22)] autorelease];
    [ask setButtonType:NSSwitchButton];[ask setTitle:@"Ask before running its tools"];[view addSubview:ask];
    NSArray *sshTitles=[NSArray arrayWithObjects:@"Copy Key",@"Trust Host...",@"Test",nil];
    SEL sshActs[]={@selector(sheetCopyKey:),@selector(sheetTrust:),@selector(sheetTest:)};
    for(i=0;i<3;i++) {
        NSButton *b=[[[NSButton alloc] initWithFrame:NSMakeRect(140+i*108,98,102,28)] autorelease];
        [b setTitle:[sshTitles objectAtIndex:i]];[b setBezelStyle:NSRoundedBezelStyle];[b setTarget:self];[b setAction:sshActs[i]];[view addSubview:b];[sshViews addObject:b];
    }
    NSTextField *status=[self integrationLabel:@"" frame:NSMakeRect(16,50,488,40) view:view];[status setFont:[NSFont systemFontOfSize:11]];
    [f setObject:status forKey:@"sheetStatus"];[f setObject:sshViews forKey:@"sheetSSH"];
    if(server) {
        [[fieldList objectAtIndex:0] setStringValue:[server objectForKey:@"id"]];[[fieldList objectAtIndex:0] setEditable:NO];
        [[fieldList objectAtIndex:1] setStringValue:[server objectForKey:@"title"]?[server objectForKey:@"title"]:@""];
        if([oldCommand hasPrefix:@"ssh:"]){
            [kind selectItemAtIndex:[[[server objectForKey:@"args"] componentsJoinedByString:@" "] isEqualToString:kRemoteCommander]?3:2];
            [[fieldList objectAtIndex:2] setStringValue:[oldCommand substringFromIndex:4]];
            [[fieldList objectAtIndex:3] setStringValue:[[server objectForKey:@"args"] componentsJoinedByString:@" "]];
        } else {
            [kind selectItemAtIndex:[[oldCommand lowercaseString] hasPrefix:@"http"]?1:0];
            [[fieldList objectAtIndex:2] setStringValue:oldCommand];
            [[fieldList objectAtIndex:3] setStringValue:[[server objectForKey:@"args"] componentsJoinedByString:@"|"]];
        }
        [desc setString:[server objectForKey:@"description"]?[server objectForKey:@"description"]:@""];
        NSMutableString *text=[NSMutableString string];NSDictionary *vars=[server objectForKey:@"env"];NSEnumerator *names=[vars keyEnumerator];NSString *n;
        while((n=[names nextObject]))[text appendFormat:@"%@=%@\n",n,[vars objectForKey:n]];
        [env setString:text];
        [on setState:[[server objectForKey:@"enabled"] boolValue]?NSOnState:NSOffState];
        [ask setState:[[server objectForKey:@"approval"] boolValue]?NSOnState:NSOffState];
    }
    {
        NSString *keepArgs=[[fieldList objectAtIndex:3] stringValue];
        [self serverKindChanged:kind];
        if(server)[[fieldList objectAtIndex:3] setStringValue:keepArgs];
    }
    NSButton *okButton=[[[NSButton alloc] initWithFrame:NSMakeRect(318,10,90,30)] autorelease];
    [okButton setTitle:server?@"Done":@"Add"];[okButton setBezelStyle:NSRoundedBezelStyle];[okButton setKeyEquivalent:@"\r"];[okButton setTarget:self];[okButton setAction:@selector(serverSheetDone:)];[view addSubview:okButton];
    NSButton *cancel=[[[NSButton alloc] initWithFrame:NSMakeRect(414,10,90,30)] autorelease];
    [cancel setTitle:@"Cancel"];[cancel setBezelStyle:NSRoundedBezelStyle];[cancel setKeyEquivalent:@"\033"];[cancel setTarget:self];[cancel setAction:@selector(serverSheetCancel:)];[view addSubview:cancel];
    [panel makeKeyAndOrderFront:nil];[panel makeFirstResponder:[fieldList objectAtIndex:server?2:0]];
    int result=[NSApp runModalForWindow:panel];[panel orderOut:nil];
    if(result!=1)return nil;
    int chosen=[kind indexOfSelectedItem];
    NSString *name=TBTrim([[fieldList objectAtIndex:0] stringValue]);
    NSString *command=TBTrim([[fieldList objectAtIndex:2] stringValue]);
    NSString *args=[[fieldList objectAtIndex:3] stringValue];
    NSArray *argList;
    if(chosen>=2){
        if(![[command componentsSeparatedByString:@"@"] count]||[[command componentsSeparatedByString:@"@"] count]!=2||![TBTrim(args) length]){
            NSRunAlertPanel(@"MCP Server",@"Enter the other computer as user@address, and the command to run there.",@"OK",nil,nil);return nil;
        }
        command=[@"ssh:" stringByAppendingString:command];
        argList=[NSArray arrayWithObject:TBTrim(args)];
    } else {
        if(!([command hasPrefix:@"/"]||[[command lowercaseString] hasPrefix:@"http://"]||[[command lowercaseString] hasPrefix:@"https://"]||[command hasPrefix:@"builtin:"])) {
            NSRunAlertPanel(@"MCP Server",@"Enter the absolute path of a program on this Mac, or an http:// or https:// address.",@"OK",nil,nil);return nil;
        }
        argList=[args length]?[args componentsSeparatedByString:@"|"]:[NSArray array];
    }
    if(![name length]||[name length]>20){
        NSRunAlertPanel(@"MCP Server",@"Enter an ID of letters, digits or underscore, up to 20 characters.",@"OK",nil,nil);return nil;
    }
    NSMutableDictionary *vars=[NSMutableDictionary dictionary];
    NSArray *lines=[[env string] componentsSeparatedByString:@"\n"];
    for(i=0;i<[lines count];i++) {
        NSString *line=[lines objectAtIndex:i];NSRange eq=[line rangeOfString:@"="];
        if(eq.location!=NSNotFound&&eq.location>0)[vars setObject:[line substringFromIndex:eq.location+1] forKey:[line substringToIndex:eq.location]];
    }
    return [NSMutableDictionary dictionaryWithObjectsAndKeys:name,@"id",[[fieldList objectAtIndex:1] stringValue],@"title",command,@"command",
        argList,@"args",vars,@"env",TBTrim([desc string]),@"description",
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
    if(NSRunAlertPanel(@"Remove this server?",@"\"%@\" is removed from the list when you Save.",@"Remove",@"Cancel",nil,[[[source servers] objectAtIndex:row] objectForKey:@"id"])!=NSAlertDefaultReturn)return;
    [[source servers] removeObjectAtIndex:row];
    [list reloadData];
    [self integrationStatus:@"Removed. Save to apply."];
}
/* "The model picks", "The chat's model", or one fixed model of a service you can use */
- (void)fillSubagentPolicyPopup:(NSString *)saved
{
    NSPopUpButton *popup=[[self integrationFields] objectForKey:@"subagents_policy"];
    NSArray *providers=[[ModelCatalog shared] providers];
    unsigned i,j;
    if(!popup)return;
    [popup removeAllItems];
    [popup addItemWithTitle:@"The model picks for each task"];[[popup lastItem] setRepresentedObject:@"choose"];
    [popup addItemWithTitle:@"Always the chat's own model"];[[popup lastItem] setRepresentedObject:@"same"];
    for(i=0;i<[providers count];i++) {
        NSString *pid=[[providers objectAtIndex:i] objectForKey:@"id"];
        NSArray *models=[pid isEqualToString:@"local"]?localModels:[[ModelCatalog shared] modelsForProvider:pid];
        if(![self providerUsable:pid])continue;
        for(j=0;j<[models count];j++) {
            [popup addItemWithTitle:[NSString stringWithFormat:@"Always %@: %@",[[ModelCatalog shared] titleForProvider:pid],[[models objectAtIndex:j] objectForKey:@"title"]]];
            [[popup lastItem] setRepresentedObject:[NSString stringWithFormat:@"%@|%@",pid,[[models objectAtIndex:j] objectForKey:@"id"]]];
        }
    }
    for(i=0;i<(unsigned)[popup numberOfItems];i++)
        if([[[popup itemAtIndex:i] representedObject] isEqualToString:[saved length]?saved:@"choose"]){[popup selectItemAtIndex:i];break;}
}
- (NSDictionary *)integrationFormData
{
    NSMutableDictionary *fields=[self integrationFields];NSMutableDictionary *data=[NSMutableDictionary dictionary];
    NSArray *keys=[NSArray arrayWithObjects:@"ppc_enabled",@"ppc_approval",@"toolbox_enabled",@"consult_enabled",@"search_enabled",@"grok_native_search",@"gemini_native_search",@"download_enabled",@"subagents_enabled",@"claude_thinking",@"clear_search_key",@"clear_tavily_key",nil];unsigned i;
    for(i=0;i<[keys count];i++)[data setObject:[NSNumber numberWithBool:[[fields objectForKey:[keys objectAtIndex:i]] state]==NSOnState] forKey:[keys objectAtIndex:i]];
    [data setObject:[[fields objectForKey:@"search_api_key"] stringValue] forKey:@"search_api_key"];
    [data setObject:[[fields objectForKey:@"tavily_api_key"] stringValue] forKey:@"tavily_api_key"];
    [data setObject:[[fields objectForKey:@"search_provider"] indexOfSelectedItem]==1?@"tavily":@"brave" forKey:@"search_provider"];
    {NSString *text=[[fields objectForKey:@"max_tool_steps"] stringValue];int steps=[text length]?[text intValue]:40;if(steps<0)steps=40;if(steps>1000)steps=1000;
        [data setObject:[NSNumber numberWithInt:steps] forKey:@"max_tool_steps"];}
    {int tasks=[[[fields objectForKey:@"subagents_tasks"] stringValue] intValue];int cap=[[[fields objectForKey:@"subagents_max"] stringValue] intValue];
        if(tasks<1)tasks=8;if(tasks>16)tasks=16;if(cap<1)cap=4;if(cap>8)cap=8;
        [data setObject:[NSNumber numberWithInt:tasks] forKey:@"subagents_tasks"];[data setObject:[NSNumber numberWithInt:cap] forKey:@"subagents_max"];
        NSString *rule=[[[[fields objectForKey:@"subagents_policy"] selectedItem] representedObject] description];
        [data setObject:[rule length]?rule:@"choose" forKey:@"subagents_policy"];}
    [data setObject:[(TBServerSource *)[fields objectForKey:@"source"] servers] forKey:@"servers"];return data;
}
- (void)saveIntegrations:(id)sender
{
    (void)sender;
    BOOL anyOn=NO;
    NSArray *servers=[(TBServerSource *)[[self integrationFields] objectForKey:@"source"] servers];
    unsigned i;
    for(i=0;i<[servers count];i++)if([[[servers objectAtIndex:i] objectForKey:@"enabled"] boolValue]&&![[[servers objectAtIndex:i] objectForKey:@"command"] hasPrefix:@"builtin:"])anyOn=YES;
    if(anyOn&&NSRunAlertPanel(@"Enable custom servers?",@"Custom MCP servers run with your permissions, or receive what the model sends them. "
        @"Enable only servers you trust.",@"Save",@"Cancel",nil)!=NSAlertDefaultReturn)return;
    NSString *error=nil;NSData *data=[NSPropertyListSerialization dataFromPropertyList:[self integrationFormData] format:NSPropertyListXMLFormat_v1_0 errorDescription:&error];
    if(error)[error release];NSString *text=[[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    [EngineRequest send:@"POST" path:@"/v1/integrations" body:text timeout:20 target:self action:@selector(integrationsSaved:) context:nil];
}
- (void)integrationsSaved:(EngineRequest *)request
{
    [self integrationStatus:[request ok]?@"Saved. New chat turns use the updated tools.":[request text]];
    if([request ok]){[[[self integrationFields] objectForKey:@"tavily_api_key"] setStringValue:@""];[[[self integrationFields] objectForKey:@"clear_tavily_key"] setState:NSOffState];[[[self integrationFields] objectForKey:@"search_api_key"] setStringValue:@""];[[[self integrationFields] objectForKey:@"clear_search_key"] setState:NSOffState];[self refreshToolCatalog];}
}

- (void)exportAllSettings:(id)sender
{
    (void)sender;
    if(NSRunAlertPanel(@"Export all settings?",@"This backup includes API keys, custom MCP settings and their environment secrets in plaintext. "
        @"Keep it private. Chat history and SSH keys are not included.",@"Export",@"Cancel",nil)!=NSAlertDefaultReturn)return;
    [EngineRequest send:@"GET" path:@"/v1/config-export" body:nil timeout:20 target:self action:@selector(settingsBackupArrived:) context:nil];
}
- (void)settingsBackupArrived:(EngineRequest *)request
{
    if(![request ok]){NSRunAlertPanel(@"Settings backup",@"%@",@"OK",nil,nil,[self relayProblemForRequest:request]);return;}
    NSSavePanel *panel=[NSSavePanel savePanel];[panel setRequiredFileType:@"plist"];
    if([panel runModalForDirectory:nil file:@"TigerBuild-all-settings.plist"]!=NSOKButton)return;
    NSString *domain=[[NSBundle mainBundle] bundleIdentifier];
    NSDictionary *defaults=[[NSUserDefaults standardUserDefaults] persistentDomainForName:domain];
    NSDictionary *client=[NSDictionary dictionaryWithObjectsAndKeys:
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
        if(NSRunAlertPanel(@"Import settings?",@"This restores API keys and tools from an earlier relay backup. "
            @"Your other preferences stay unchanged. Imported custom MCPs remain disabled.",
            @"Import",@"Cancel",nil)!=NSAlertDefaultReturn)return;
        NSString *text=[[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
        [EngineRequest send:@"POST" path:@"/v1/config-import" body:text timeout:20 target:self action:@selector(relayOnlySettingsImported:) context:nil];
        return;
    }
    if(![backup isKindOfClass:[NSDictionary class]]||![[backup objectForKey:@"format"] isEqualToString:@"TigerBuild-config"]
        ||[[backup objectForKey:@"version"] intValue]!=1||![[backup objectForKey:@"relay"] isKindOfClass:[NSData class]]) {
        NSRunAlertPanel(@"Settings",@"Not a supported Tiger Build settings backup.",@"OK",nil,nil);return;
    }
    NSDictionary *client=[backup objectForKey:@"client"];
    if(![client isKindOfClass:[NSDictionary class]]||![[client objectForKey:@"preferences"] isKindOfClass:[NSDictionary class]]) {
        NSRunAlertPanel(@"Settings",@"Malformed client configuration.",@"OK",nil,nil);return;
    }
    if(NSRunAlertPanel(@"Replace settings?",@"This replaces your preferences, API keys and tool settings. MCP servers are imported disabled. "
        @"Your chats are unchanged. Export current settings first.",@"Import",@"Cancel",nil)!=NSAlertDefaultReturn)return;
    NSString *text=[[[NSString alloc] initWithData:[backup objectForKey:@"relay"] encoding:NSUTF8StringEncoding] autorelease];
    [EngineRequest send:@"POST" path:@"/v1/config-import" body:text timeout:20 target:self action:@selector(settingsBackupImported:) context:backup];
}
- (void)relayOnlySettingsImported:(EngineRequest *)request
{
    NSRunAlertPanel(@"Settings",@"%@",@"OK",nil,nil,[request ok]?@"Settings imported. Custom servers remain disabled.":[request text]);
    if([request ok]){[self refreshCatalog];[self refreshLocalModels];}
}
- (void)settingsBackupImported:(EngineRequest *)request
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
    [[NSUserDefaults standardUserDefaults] setPersistentDomain:[client objectForKey:@"preferences"] forName:[[NSBundle mainBundle] bundleIdentifier]];
    NSDictionary *commander=[client objectForKey:@"commander"];
    if([commander isKindOfClass:[NSDictionary class]]) {
        [self commanderCommand:([[commander objectForKey:@"remote"] intValue]!=0)?@"remote-on":@"remote-off"];
        [self commanderCommand:([[commander objectForKey:@"enabled"] intValue]!=0)?@"start":@"stop"];
    }
}
@end
