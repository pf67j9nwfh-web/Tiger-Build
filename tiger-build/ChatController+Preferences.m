#import "ChatController_Private.h"
#import "TBSession.h"

/* Preferences. Keys are kept in the Keychain by the engine, which only ever reports whether each key is saved, never the key itself.
   Answers arrive through EngineRequest, which the engine serves from inside the app. */

#define TB_LOCAL_EXAMPLE @"http://127.0.0.1:1234/v1"

static NSString *trimmedValue(NSTextField *field)
{
    return [[field stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

@interface ChatController (PreferencesPrivate)
- (void)loadSSHFields;
- (void)saveSSHFields;
- (void)fillNewChatModelPopup;
- (void)requestSettings;
- (void)refreshAfterPreferences;
- (void)setPreferencesStatus:(NSString *)text;
@end

@implementation ChatController (Preferences)

- (void)setPreferencesStatus:(NSString *)text
{
    [[prefsFields objectForKey:@"status"] setStringValue:text ? text : @""];
}

/* Fields from the saved settings; key fields blank; then ask what is saved. */
- (void)loadPreferenceForm
{
    NSEnumerator *names = [prefsFields keyEnumerator];
    NSString *name;
    while ((name = [names nextObject])) {
        if ([name hasPrefix:@"remove."])
            [[prefsFields objectForKey:name] setEnabled:NO];
    }
    [self fillNewChatModelPopup];
    [self loadSSHFields];
    [self requestSettings];
}

- (void)requestSettings
{
    [EngineRequest send:@"GET" path:@"/v1/settings" body:nil timeout:10
        target:self action:@selector(preferencesArrived:) context:nil];
}

- (NSString *)localStatusText:(NSString *)status url:(NSString *)url
{
    if ([url length] == 0 || [status isEqualToString:@"unset"])
        return @"No local LLM server set up. Enter its address if you use one.";
    if ([status hasPrefix:@"ok "])
        return [NSString stringWithFormat:@"In use: %@ - answering, %d models loaded", url,
            [[status substringFromIndex:3] intValue]];
    if ([status isEqualToString:@"empty"])
        return [NSString stringWithFormat:@"In use: %@ - answering, but no models are loaded", url];
    if ([status isEqualToString:@"offline"])
        return [NSString stringWithFormat:@"In use: %@ - not answering", url];
    return [NSString stringWithFormat:@"In use: %@", url];
}

- (void)preferencesArrived:(EngineRequest *)request
{
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    NSArray *lines;
    NSEnumerator *names;
    NSString *name;
    NSString *url;
    unsigned i;
    int saved = 0;
    if (![request ok]) {
        [self setPreferencesStatus:@"The saved settings could not be read."];
        return;
    }
    [self setPreferencesStatus:@""];
    lines = [[request text] componentsSeparatedByString:@"\n"];
    for (i = 0; i < [lines count]; i++) {
        NSString *line = [lines objectAtIndex:i];
        NSRange equals = [line rangeOfString:@"="];
        if (equals.location != NSNotFound)
            [values setObject:[line substringFromIndex:equals.location + 1]
                       forKey:[line substringToIndex:equals.location]];
    }
    url = [values objectForKey:@"local_url"];
    /* There is no assumed local server: blank means none is set up. */
    [[prefsFields objectForKey:@"local_url"]
        setStringValue:[[values objectForKey:@"local_url_set"] isEqualToString:@"1"] ? url : @""];
    [[prefsFields objectForKey:@"remove.local_url"]
        setEnabled:[[values objectForKey:@"local_url_set"] isEqualToString:@"1"]];
    [[prefsFields objectForKey:@"local.inuse"]
        setStringValue:[self localStatusText:[values objectForKey:@"local_status"] url:url]];
    names = [values keyEnumerator];
    while ((name = [names nextObject])) {
        BOOL isSaved = [[values objectForKey:name] isEqualToString:@"1"];
        NSButton *remove = [prefsFields objectForKey:[@"remove." stringByAppendingString:name]];
        if ([name hasPrefix:@"local_url"] || [name isEqualToString:@"local_status"])
            continue;
        [[prefsFields objectForKey:[name stringByAppendingString:@".note"]] setStringValue:isSaved ? @"saved" : @""];
        [[prefsFields objectForKey:name] setStringValue:@""];
        [remove setEnabled:isSaved];
        if (isSaved && [name hasSuffix:@"_api_key"] && ![name isEqualToString:@"local_api_key"])
            saved++;
    }
    if (saved == 0)
        [self setPreferencesStatus:@"No provider keys yet. Add a key or a local LLM server."];
}

- (void)showHelp:(id)sender
{
    NSRunInformationalAlertPanel(@"Preferences", @"%@", @"OK", nil, nil, [sender toolTip]);
}

- (void)removeSetting:(id)sender
{
    NSEnumerator *names = [prefsFields keyEnumerator];
    NSString *name;
    NSString *setting = nil;
    NSString *body;
    while ((name = [names nextObject])) {
        if ([name hasPrefix:@"remove."] && [prefsFields objectForKey:name] == sender)
            setting = [name substringFromIndex:7];
    }
    if (!setting)
        return;
    if ([setting isEqualToString:@"local_url"])
        body = @"{\"clear\":[\"local_url\"]}";
    else if (NSRunAlertPanel(@"Remove this key?", @"Tiger Build will remove it from your Keychain. You can add it again later.",
                @"Remove", @"Cancel", nil) != NSAlertDefaultReturn)
        return;
    else
        body = [NSString stringWithFormat:@"{\"clear\":[\"%@\"]}", TBJSONEscape(setting)];
    [self setPreferencesStatus:@"Saving..."];
    [EngineRequest send:@"POST" path:@"/v1/settings" body:body timeout:15
        target:self action:@selector(removalSaved:) context:nil];
}

- (void)clearAllSettings:(id)sender
{
    (void)sender;
    if (NSRunAlertPanel(@"Clear all settings?", @"Remove every provider and search API key, the workspace ID, the local LLM server and your custom MCP servers? "
        @"Chat history is kept.", @"Clear All", @"Cancel", nil)
        != NSAlertDefaultReturn) return;
    [EngineRequest send:@"POST" path:@"/v1/settings" body:@"{\"clear_all\":true}" timeout:15
        target:self action:@selector(removalSaved:) context:nil];
}

- (void)removalSaved:(EngineRequest *)request
{
    if (![request ok]) {
        [self setPreferencesStatus:@""];
        NSRunAlertPanel(@"Preferences", @"It could not be removed. %@", @"OK", nil, nil, [request text]);
        return;
    }
    [self requestSettings];
    [self refreshAfterPreferences];
}

- (void)refreshAfterPreferences
{
    [self refreshCatalog];
    [self refreshLocalModels];
    if (current) {
        [current removeObjectForKey:@"contextLimit"];
        [self rememberContextLimit];
        [self updateContextReadout];
    }
}

- (void)savePreferences:(id)sender
{
    NSArray *keys;
    NSMutableString *body;
    unsigned i;
    BOOL first = YES;
    (void)sender;
    {
        NSString *choice = [[[prefsFields objectForKey:@"new_chat_model"] selectedItem] representedObject];
        if (choice)
            [[NSUserDefaults standardUserDefaults] setObject:choice forKey:@"TigerBuildNewChatModel"];
    }
    [self saveSSHFields];
    keys = [NSArray arrayWithObjects:
        @"xai_api_key", @"openai_api_key", @"anthropic_api_key",
        @"anthropic_workspace_id", @"mistral_api_key", @"muse_api_key",
        @"gemini_api_key", @"local_api_key", @"local_url", nil];
    body = [NSMutableString stringWithString:@"{"];
    for (i = 0; i < [keys count]; i++) {
        NSString *key = [keys objectAtIndex:i];
        NSString *value = trimmedValue([prefsFields objectForKey:key]);
        /* Blank means "leave as saved". Remove clears a saved value. */
        if ([value length] == 0)
            continue;
        if (!first)
            [body appendString:@","];
        first = NO;
        [body appendFormat:@"\"%@\":\"%@\"", key, TBJSONEscape(value)];
    }
    [body appendString:@"}"];
    if (first) {
        [prefsWindow orderOut:nil];
        [self refreshAfterPreferences];
        return;
    }
    [self setPreferencesStatus:@"Saving..."];
    [EngineRequest send:@"POST" path:@"/v1/settings" body:body timeout:15
        target:self action:@selector(preferencesSaved:) context:nil];
}

- (void)preferencesSaved:(EngineRequest *)request
{
    NSString *reason;
    if (![request ok]) {
        reason = [[request text] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [self setPreferencesStatus:@""];
        NSRunAlertPanel(@"Preferences", @"The settings were not saved. %@", @"OK", nil, nil, reason);
        return;
    }
    [prefsWindow orderOut:nil];
    [self refreshAfterPreferences];
}

- (void)cancelPreferences:(id)sender
{
    (void)sender;
    [prefsWindow orderOut:nil];
}

/* ---- window ---- */

- (NSTextField *)preferencesLabel:(NSString *)text frame:(NSRect)frame inView:(NSView *)view
{
    NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
    [label setStringValue:text];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [label setFont:[NSFont systemFontOfSize:12]];
    [[label cell] setLineBreakMode:NSLineBreakByTruncatingTail];
    [view addSubview:label];
    [label release];
    return label;
}

- (void)preferencesHeading:(NSString *)text y:(float)y inView:(NSView *)view
{
    NSTextField *label = [self preferencesLabel:text frame:NSMakeRect(16, y, 400, 18) inView:view];
    [label setFont:[NSFont boldSystemFontOfSize:13]];
}

- (NSButton *)preferencesButton:(NSString *)title frame:(NSRect)frame action:(SEL)action inView:(NSView *)view
{
    NSButton *button = [[NSButton alloc] initWithFrame:frame];
    [button setTitle:title];
    [button setBezelStyle:NSRoundedBezelStyle];
    [button setTarget:self];
    [button setAction:action];
    [view addSubview:button];
    [button release];
    return button;
}

/* A small "?" button: hover shows the help as a tooltip, a click shows it
   in a panel. Tooltips on Tiger only appear after a pause, so both. */
- (void)preferencesHelp:(NSString *)help y:(float)y inView:(NSView *)view
{
    NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(176, y, 21, 23)];
    [button setBezelStyle:NSHelpButtonBezelStyle];
    [button setTitle:@""];
    [button setToolTip:help];
    [button setTarget:self];
    [button setAction:@selector(showHelp:)];
    [view addSubview:button];
    [button release];
}


/* One labelled field. removable adds a Remove (or Reset) button and a
   "saved" note, both filled in when the relay answers. */
- (NSTextField *)preferencesRow:(NSString *)title key:(NSString *)key y:(float)y secure:(BOOL)secure
                          width:(float)width help:(NSString *)help removable:(NSString *)removeTitle
                         inView:(NSView *)view
{
    NSTextField *field;
    NSButton *remove;
    [self preferencesLabel:title frame:NSMakeRect(16, y + 2, 158, 18) inView:view];
    if (help)
        [self preferencesHelp:help y:y inView:view];
    if (secure)
        field = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(200, y, width, 22)];
    else
        field = [[NSTextField alloc] initWithFrame:NSMakeRect(200, y, width, 22)];
    [field setEditable:YES];
    [field setSelectable:YES];
    [field setBezeled:YES];
    [field setFont:[NSFont systemFontOfSize:12]];
    if (help)
        [field setToolTip:help];
    [view addSubview:field];
    [prefsFields setObject:field forKey:key];
    [field release];
    [prefsFields setObject:[self preferencesLabel:@"" frame:NSMakeRect(200 + width + 4, y + 2, 44, 18) inView:view]
                    forKey:[key stringByAppendingString:@".note"]];
    if (removeTitle) {
        remove = [self preferencesButton:removeTitle frame:NSMakeRect(200 + width + 44, y - 3, 92, 28)
                                  action:@selector(removeSetting:) inView:view];
        [[remove cell] setControlSize:NSSmallControlSize];
        [remove setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
        [remove setEnabled:NO];
        [prefsFields setObject:remove forKey:[@"remove." stringByAppendingString:key]];
    }
    return field;
}

/* A tab holding one group of settings. */
- (NSView *)preferencesTab:(NSString *)label in:(NSTabView *)tabs
{
    NSTabViewItem *item = [[[NSTabViewItem alloc] initWithIdentifier:label] autorelease];
    NSView *view = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 556, 330)] autorelease];
    [item setLabel:label];
    [item setView:view];
    [tabs addTabViewItem:item];
    return view;
}

- (NSTextField *)preferencesNote:(NSString *)text frame:(NSRect)frame inView:(NSView *)view
{
    NSTextField *note = [self preferencesLabel:text frame:frame inView:view];
    [note setFont:[NSFont systemFontOfSize:11]];
    [[note cell] setWraps:YES];
    [[note cell] setLineBreakMode:NSLineBreakByWordWrapping];
    return note;
}

/* The model a new chat starts with: the last one used, or one fixed choice. */
- (void)fillNewChatModelPopup
{
    NSPopUpButton *popup = [prefsFields objectForKey:@"new_chat_model"];
    NSArray *providers = [[ModelCatalog shared] providers];
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"TigerBuildNewChatModel"];
    unsigned i;
    unsigned j;
    if (!popup)
        return;
    [popup removeAllItems];
    [popup addItemWithTitle:@"The model last used (default)"];
    [[popup lastItem] setRepresentedObject:@"last"];
    for (i = 0; i < [providers count]; i++) {
        NSString *pid = [[providers objectAtIndex:i] objectForKey:@"id"];
        NSArray *models = [pid isEqualToString:@"local"] ? localModels : [[ModelCatalog shared] modelsForProvider:pid];
        if (![self providerUsable:pid])
            continue;
        for (j = 0; j < [models count]; j++) {
            NSDictionary *model = [models objectAtIndex:j];
            [popup addItemWithTitle:[NSString stringWithFormat:@"%@: %@", [[ModelCatalog shared] titleForProvider:pid], [model objectForKey:@"title"]]];
            [[popup lastItem] setRepresentedObject:[NSString stringWithFormat:@"%@|%@", pid, [model objectForKey:@"id"]]];
        }
    }
    if ([saved length] == 0)
        saved = @"last";
    for (i = 0; i < (unsigned)[popup numberOfItems]; i++) {
        if ([[[popup itemAtIndex:i] representedObject] isEqualToString:saved]) {
            [popup selectItemAtIndex:i];
            break;
        }
    }
}

- (void)buildPreferencesWindow
{
    NSView *view;
    NSView *tab;
    NSTabView *tabs;
    NSTextField *field;
    NSTextField *note;
    NSButton *button;
    NSArray *keys;
    unsigned i;
    float y;
    prefsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 600, 470)
                                               styleMask:NSTitledWindowMask | NSClosableWindowMask
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
    [prefsWindow setTitle:@"Preferences"];
    [prefsWindow setReleasedWhenClosed:NO];
    [prefsWindow center];
    view = [prefsWindow contentView];
    tabs = [[[NSTabView alloc] initWithFrame:NSMakeRect(12, 56, 576, 404)] autorelease];
    [tabs setFont:[NSFont systemFontOfSize:12]];
    [view addSubview:tabs];

    /* ---- API keys ---- */
    tab = [self preferencesTab:@"API Keys" in:tabs];
    y = 304;
    [self preferencesNote:@"Add a key for each service or local LLM server IP. You do not have to setup everything, you can configure as many or little as you want."
        frame:NSMakeRect(16, y - 14, 520, 30) inView:tab];
    y -= 40;
    keys = [NSArray arrayWithObjects:
        [NSArray arrayWithObjects:@"SpaceXAI (Grok)", @"xai_api_key", @"1", @"", nil],
        [NSArray arrayWithObjects:@"OpenAI (ChatGPT)", @"openai_api_key", @"1", @"", nil],
        [NSArray arrayWithObjects:@"Anthropic (Claude)", @"anthropic_api_key", @"1", @"", nil],
        [NSArray arrayWithObjects:@"Workspace ID (optional)", @"anthropic_workspace_id", @"0",
            @"Only needed if your Anthropic key belongs to a workspace that requires its ID. Most keys do not.", nil],
        [NSArray arrayWithObjects:@"Mistral", @"mistral_api_key", @"1", @"", nil],
        [NSArray arrayWithObjects:@"Meta (Muse)", @"muse_api_key", @"1", @"", nil],
        [NSArray arrayWithObjects:@"Google (Gemini)", @"gemini_api_key", @"1", @"", nil],
        nil];
    for (i = 0; i < [keys count]; i++) {
        NSArray *row = [keys objectAtIndex:i];
        NSString *help = [row objectAtIndex:3];
        [self preferencesRow:[row objectAtIndex:0] key:[row objectAtIndex:1] y:y
            secure:[[row objectAtIndex:2] isEqualToString:@"1"] width:190
            help:([help length] ? help : nil) removable:@"Remove" inView:tab];
        y -= 34;
    }

    /* ---- Local LLM server ---- */
    tab = [self preferencesTab:@"Local LLM Server" in:tabs];
    y = 284;
    field = [self preferencesRow:@"Local LLM server address" key:@"local_url" y:y secure:NO width:190
        help:@"LM Studio, Ollama or another OpenAI-compatible server. "
             @"For example http://127.0.0.1:1234 (LM Studio), http://127.0.0.1:11434 (Ollama), or an address on another computer. Reset removes it."
        removable:@"Reset" inView:tab];
    [[field cell] setPlaceholderString:@"not set (e.g. " TB_LOCAL_EXAMPLE ")"];
    y -= 24;
    note = [self preferencesLabel:@"" frame:NSMakeRect(200, y, 340, 16) inView:tab];
    [note setFont:[NSFont systemFontOfSize:11]];
    [prefsFields setObject:note forKey:@"local.inuse"];
    y -= 34;
    [self preferencesRow:@"Local API key (optional)" key:@"local_api_key" y:y secure:YES width:190
        help:@"Optional. Only needed if your local LLM server was set up to require a key. "
             @"LM Studio and Ollama do not require one unless you turn that on."
        removable:@"Remove" inView:tab];

    /* ---- New chats ---- */
    tab = [self preferencesTab:@"General" in:tabs];
    y = 284;
    [self preferencesLabel:@"New chats start with" frame:NSMakeRect(16, y + 2, 150, 18) inView:tab];
    {
        NSPopUpButton *popup = [[[NSPopUpButton alloc] initWithFrame:NSMakeRect(170, y - 2, 366, 26) pullsDown:NO] autorelease];
        [popup setFont:[NSFont systemFontOfSize:12]];
        [tab addSubview:popup];
        [prefsFields setObject:popup forKey:@"new_chat_model"];
    }
    y -= 34;
    [self preferencesNote:@"\"The model last used\" starts a new chat with the model, tools and approvals of your most recent chat in the workspace. "
        @"Or pick one model for every new chat."
        frame:NSMakeRect(16, y - 24, 520, 44) inView:tab];
    y -= 96;
    [self preferencesHeading:@"Settings backup" y:y inView:tab];
    y -= 36;
    [self preferencesButton:@"Export Settings..." frame:NSMakeRect(16, y, 150, 28) action:@selector(exportAllSettings:) inView:tab];
    [self preferencesButton:@"Import Settings..." frame:NSMakeRect(172, y, 150, 28) action:@selector(importAllSettings:) inView:tab];
    [self preferencesButton:@"Clear All Settings..." frame:NSMakeRect(328, y, 170, 28) action:@selector(clearAllSettings:) inView:tab];
    y -= 22;
    [self preferencesNote:@"Backups include your API keys in plain text. Keep them private. Chat history is not included."
        frame:NSMakeRect(16, y - 10, 520, 28) inView:tab];

    /* ---- Commander ---- */
    tab = [self preferencesTab:@"Commander" in:tabs];
    y = 292;
    [self preferencesNote:@"Commander is the part of Tiger Build that reads and edits files and runs commands on this Mac for a chat. It runs only while a chat uses it, "
        @"and nothing listens on the network. To use another computer's files and shell, add it under Tool Settings, MCP Servers (Commander on another computer)."
        frame:NSMakeRect(16, y - 40, 520, 58) inView:tab];
    y -= 76;
    button = [[[NSButton alloc] initWithFrame:NSMakeRect(16, y, 520, 20)] autorelease];
    [button setButtonType:NSSwitchButton];
    [button setTitle:@"Allow other computers to use Commander on this Mac"];
    [button setFont:[NSFont systemFontOfSize:12]];
    [button setToolTip:@"Off by default. Another computer running Tiger Build can then start Commander here over SSH and read, change and run things as you. Needs Remote Login in System Preferences, Sharing."];
    [tab addSubview:button];
    [prefsFields setObject:button forKey:@"remote.check"];
    y -= 22;
    [self preferencesNote:@"Turning this on allows other computers on the network to start Commander on this Mac, so it can be controlled by other copies of Tiger Build or other programs that speak MCP over SSH. Note: Remote Login must be on (System Preferences, Sharing) and the other computer's public SSH key must be in ~/.ssh/authorized_keys on this account; no password is used."
        frame:NSMakeRect(34, y - 56, 502, 72) inView:tab];
    y -= 100;
    button = [[[NSButton alloc] initWithFrame:NSMakeRect(16, y, 400, 20)] autorelease];
    [button setButtonType:NSSwitchButton];
    [button setTitle:@"Let agents run administrator (sudo) commands on this Mac"];
    [button setFont:[NSFont systemFontOfSize:12]];
    [button setTarget:self];
    [button setAction:@selector(toggleSudoMode:)];
    [button setToolTip:@"Off by default. Asks for your password once and keeps it in the Keychain, so commands with sudo just work. A chat can also switch it on from its Tools menu."];
    [tab addSubview:button];
    [prefsFields setObject:button forKey:@"sudo.check"];
    [self preferencesButton:@"Set Password..." frame:NSMakeRect(396, y - 4, 140, 28) action:@selector(setAdministratorPassword:) inView:tab];
    note = [self preferencesLabel:@"" frame:NSMakeRect(34, y - 26, 502, 16) inView:tab];
    [note setFont:[NSFont systemFontOfSize:11]];
    [prefsFields setObject:note forKey:@"sudo.status"];

    note = [self preferencesLabel:@"" frame:NSMakeRect(16, 22, 376, 18) inView:view];
    [prefsFields setObject:note forKey:@"status"];
    button = [self preferencesButton:@"Save" frame:NSMakeRect(396, 16, 94, 30)
                              action:@selector(savePreferences:) inView:view];
    [button setKeyEquivalent:@"\r"];
    button = [self preferencesButton:@"Cancel" frame:NSMakeRect(494, 16, 94, 30)
                              action:@selector(cancelPreferences:) inView:view];
    [button setKeyEquivalent:@"\033"];
}

/* ---- Commander access ---- */

- (void)loadSSHFields
{
    [[prefsFields objectForKey:@"remote.check"] setState:[[[self commanderCommand:@"status"] objectForKey:@"remote"] intValue] != 0 ? NSOnState : NSOffState];
}

- (void)saveSSHFields
{
    BOOL want = [[prefsFields objectForKey:@"remote.check"] state] == NSOnState;
    BOOL have = [[[self commanderCommand:@"status"] objectForKey:@"remote"] intValue] != 0;
    if (want == have)
        return;
    if (want && NSRunAlertPanel(@"Allow other computers to use this Mac?",
        @"Another computer that can sign in to this Mac over SSH will be able to read and change files and run commands here as you, through Commander. "
        @"Turn it on only for computers you control.", @"Allow", @"Cancel", nil) != NSAlertDefaultReturn)
        return;
    [self commanderCommand:want ? @"remote-on" : @"remote-off"];
}

- (void)showPreferences:(id)sender
{
    (void)sender;
    if (!prefsWindow)
        [self buildPreferencesWindow];
    [self loadPreferenceForm];
    [self refreshSudoStatus];
    [prefsWindow setLevel:NSFloatingWindowLevel];
    [prefsWindow makeKeyAndOrderFront:nil];
}

@end
