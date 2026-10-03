#import "ChatController_Private.h"

/* Preferences.
   Relay address, port, and token are kept on this Mac (server.txt and
   token.txt). Provider keys and the local server are kept by the relay, which
   only ever reports whether each key is saved, never the key itself.
   Nothing here waits on the network; answers arrive via RelayRequest. */

#define TB_DEFAULT_PORT @"8765"
#define TB_LOCAL_EXAMPLE @"http://127.0.0.1:1234/v1"

static NSString *trimmedValue(NSTextField *field)
{
    return [[field stringValue] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

/* "http://192.168.1.10:8765" -> host "192.168.1.10", port "8765".
   *port is nil when the text has no port. */
static NSString *splitBase(NSString *base, NSString **port)
{
    NSString *rest = base ? base : @"";
    NSRange scheme = [rest rangeOfString:@"://"];
    NSRange colon;
    if (scheme.location != NSNotFound)
        rest = [rest substringFromIndex:NSMaxRange(scheme)];
    while ([rest hasSuffix:@"/"])
        rest = [rest substringToIndex:[rest length] - 1];
    colon = [rest rangeOfString:@":" options:NSBackwardsSearch];
    *port = nil;
    if (colon.location != NSNotFound) {
        *port = [rest substringFromIndex:colon.location + 1];
        rest = [rest substringToIndex:colon.location];
    }
    return rest;
}

@interface ChatController (PreferencesPrivate)
- (void)requestSSHState;
- (void)setSSHStatus:(NSString *)text;
- (void)saveSSHFields;
- (void)fillNewChatModelPopup;
- (void)requestSettings;
- (BOOL)saveRelayFields;
- (void)refreshAfterPreferences;
- (void)setPreferencesStatus:(NSString *)text;
@end

@implementation ChatController (Preferences)

- (void)setPreferencesStatus:(NSString *)text
{
    [[prefsFields objectForKey:@"status"] setStringValue:text ? text : @""];
}

- (void)setRelayTestText:(NSString *)text
{
    [[prefsFields objectForKey:@"relay.status"] setStringValue:text ? text : @""];
    [[prefsFields objectForKey:@"relay.status"] setToolTip:text];
}

/* Relay fields from disk; key fields blank; then ask the relay what it has. */
- (void)loadPreferenceForm
{
    NSString *port;
    NSString *host = splitBase([RelayRequest serverBase], &port);
    NSEnumerator *names = [prefsFields keyEnumerator];
    NSString *name;
    [[prefsFields objectForKey:@"relay_host"] setStringValue:host];
    [[prefsFields objectForKey:@"relay_port"] setStringValue:port ? port : TB_DEFAULT_PORT];
    [[prefsFields objectForKey:@"relay_token"] setStringValue:@""];
    [[prefsFields objectForKey:@"relay_token.note"]
        setStringValue:[[RelayRequest token] length] ? @"saved" : @""];
    while ((name = [names nextObject])) {
        if ([name hasPrefix:@"remove."])
            [[prefsFields objectForKey:name] setEnabled:NO];
    }
    [self setRelayTestText:@""];
    [self fillNewChatModelPopup];
    [self setSSHStatus:@""];
    [prefsFields removeObjectForKey:@"ssh.loaded"];
    [self requestSSHState];
    [self requestSettings];
}

- (void)requestSettings
{
    if ([[RelayRequest serverBase] length] == 0) {
        [self setPreferencesStatus:@"Enter the relay address and token, then Test Connection."];
        [[prefsFields objectForKey:@"local.inuse"] setStringValue:@"Unknown until the relay is reachable."];
        return;
    }
    [self setPreferencesStatus:@"Asking the relay..."];
    [RelayRequest send:@"GET" path:@"/v1/settings" body:nil timeout:10
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

- (void)preferencesArrived:(RelayRequest *)request
{
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    NSArray *lines;
    NSEnumerator *names;
    NSString *name;
    NSString *url;
    unsigned i;
    int saved = 0;
    if (![request ok]) {
        NSString *problem = [self relayProblemForRequest:request];
        [self setPreferencesStatus:@""];
        [self setRelayTestText:problem];
        [[prefsFields objectForKey:@"local.inuse"] setStringValue:@"Unknown until the relay is reachable."];
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
        [self setPreferencesStatus:@"No provider keys yet. Add any you use, or use only a local LLM server."];
}

/* Write the relay address, port, and token. NO (with an alert) if unusable. */
- (BOOL)saveRelayFields
{
    NSString *host = trimmedValue([prefsFields objectForKey:@"relay_host"]);
    NSString *port = trimmedValue([prefsFields objectForKey:@"relay_port"]);
    NSString *token = trimmedValue([prefsFields objectForKey:@"relay_token"]);
    NSString *typedPort;
    NSString *base = nil;
    int number;
    if ([host length] > 0) {
        /* Someone may paste http://192.168.1.10:8765 into the address box. */
        host = splitBase(host, &typedPort);
        if ([typedPort length])
            port = typedPort;
        if ([port length] == 0)
            port = TB_DEFAULT_PORT;
        number = [port intValue];
        if (number < 1 || number > 65535 || ![[NSString stringWithFormat:@"%d", number] isEqualToString:port]) {
            NSRunAlertPanel(@"Preferences", @"The port must be a number from 1 to 65535. The relay normally uses 8765.",
                @"OK", nil, nil);
            return NO;
        }
        if ([host rangeOfString:@" "].location != NSNotFound || [host rangeOfString:@"/"].location != NSNotFound) {
            NSRunAlertPanel(@"Preferences", @"The relay address should be an IP address or name, such as 192.168.1.10.",
                @"OK", nil, nil);
            return NO;
        }
        base = [NSString stringWithFormat:@"http://%@:%d", host, number];
        [[prefsFields objectForKey:@"relay_host"] setStringValue:host];
        [[prefsFields objectForKey:@"relay_port"] setStringValue:[NSString stringWithFormat:@"%d", number]];
    }
    [relayVersion release];
    relayVersion = nil;
    if (![RelayRequest saveServerBase:base token:([token length] ? token : nil)]) {
        NSRunAlertPanel(@"Preferences", @"Tiger Build could not save the relay address.", @"OK", nil, nil);
        return NO;
    }
    if ([token length]) {
        [[prefsFields objectForKey:@"relay_token"] setStringValue:@""];
        [[prefsFields objectForKey:@"relay_token.note"] setStringValue:@"saved"];
    }
    return YES;
}

- (void)testConnection:(id)sender
{
    (void)sender;
    if (![self saveRelayFields])
        return;
    if ([[RelayRequest serverBase] length] == 0) {
        [self setRelayTestText:@"Enter the relay address first."];
        return;
    }
    [self setRelayTestText:@"Testing..."];
    [RelayRequest send:@"GET" path:@"/v1/models" body:nil timeout:10
        target:self action:@selector(testArrived:) context:nil];
}

- (void)testArrived:(RelayRequest *)request
{
    NSArray *lines;
    NSMutableArray *ready = [NSMutableArray array];
    unsigned i;
    int models = 0;
    if (![request ok]) {
        [self setRelayTestText:[self relayProblemForRequest:request]];
        [self setRelayProblem:[self relayProblemForRequest:request]];
        return;
    }
    lines = [[request text] componentsSeparatedByString:@"\n"];
    for (i = 0; i < [lines count]; i++) {
        NSArray *parts = [[lines objectAtIndex:i] componentsSeparatedByString:@"\t"];
        if ([parts count] >= 4 && [[parts objectAtIndex:0] isEqualToString:@"provider"]
            && [[parts objectAtIndex:3] isEqualToString:@"ok"]
            && ![[parts objectAtIndex:1] isEqualToString:@"local"])
            [ready addObject:[parts objectAtIndex:2]];
        if ([parts count] >= 3 && [[parts objectAtIndex:0] isEqualToString:@"model"])
            models++;
    }
    if ([ready count])
        [self setRelayTestText:[NSString stringWithFormat:@"Connected. %d models ready: %@.",
            models, [ready componentsJoinedByString:@", "]]];
    else
        [self setRelayTestText:@"Connected. No provider keys yet; Local works if a server is set."];
    [self requestSettings];
    [self refreshAfterPreferences];
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
    else if (NSRunAlertPanel(@"Remove this key?", @"The relay will forget it. You can add it again later.",
                @"Remove", @"Cancel", nil) != NSAlertDefaultReturn)
        return;
    else
        body = [NSString stringWithFormat:@"{\"clear\":[\"%@\"]}", TBJSONEscape(setting)];
    [self setPreferencesStatus:@"Saving..."];
    [RelayRequest send:@"POST" path:@"/v1/settings" body:body timeout:15
        target:self action:@selector(removalSaved:) context:nil];
}

- (void)clearAllSettings:(id)sender
{
    (void)sender;
    if (NSRunAlertPanel(@"Clear all relay settings?", @"Remove every provider/search API key, workspace ID, local LLM server settings and custom MCP configuration? "
        @"The relay connection and chat history are kept. This affects the relay GUI too.", @"Clear All", @"Cancel", nil)
        != NSAlertDefaultReturn) return;
    [RelayRequest send:@"POST" path:@"/v1/settings" body:@"{\"clear_all\":true}" timeout:15
        target:self action:@selector(removalSaved:) context:nil];
}

- (void)removalSaved:(RelayRequest *)request
{
    if (![request ok]) {
        [self setPreferencesStatus:@""];
        NSRunAlertPanel(@"Preferences", @"The relay did not remove it. %@", @"OK", nil, nil,
            [self relayProblemForRequest:request] ? [self relayProblemForRequest:request] : [request text]);
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
    if (![self saveRelayFields])
        return;
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
    if ([[RelayRequest serverBase] length] == 0) {
        NSRunAlertPanel(@"Preferences", @"Enter the relay address first. Keys are stored by the relay.",
            @"OK", nil, nil);
        return;
    }
    [self setPreferencesStatus:@"Saving..."];
    [RelayRequest send:@"POST" path:@"/v1/settings" body:body timeout:15
        target:self action:@selector(preferencesSaved:) context:nil];
}

- (void)preferencesSaved:(RelayRequest *)request
{
    NSString *reason;
    if (![request ok]) {
        reason = [self relayProblemForRequest:request];
        if (!reason || [request status] == 400)
            reason = [[request text] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [self setPreferencesStatus:@""];
        NSRunAlertPanel(@"Preferences", @"The relay did not save the settings. %@", @"OK", nil, nil, reason);
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

    /* ---- Relay ---- */
    tab = [self preferencesTab:@"Relay" in:tabs];
    y = 284;
    field = [self preferencesRow:@"Relay address" key:@"relay_host" y:y secure:NO width:148
        help:@"The IP address or name of the Mac running the relay, such as 192.168.1.10. The relay app shows it under Reachable address. "
             @"Put the port in the Port box; the relay uses 8765 unless its config.sh says otherwise."
        removable:nil inView:tab];
    [[field cell] setPlaceholderString:@"relay Mac address"];
    [self preferencesLabel:@"Port" frame:NSMakeRect(356, y + 2, 32, 18) inView:tab];
    field = [[NSTextField alloc] initWithFrame:NSMakeRect(388, y, 56, 22)];
    [field setEditable:YES];
    [field setBezeled:YES];
    [field setFont:[NSFont systemFontOfSize:12]];
    [[field cell] setPlaceholderString:@"8765"];
    [field setToolTip:@"The relay's port. 8765 unless LISTEN_PORT was changed in the relay's config.sh."];
    [tab addSubview:field];
    [prefsFields setObject:field forKey:@"relay_port"];
    [field release];
    y -= 32;
    [self preferencesRow:@"Relay token" key:@"relay_token" y:y secure:YES width:280
        help:@"The shared secret that lets this Mac use the relay. It is in relay-token on the relay Mac; "
             @"setup.sh prints it and install-tiger.sh fills it in. Leave blank to keep the saved one."
        removable:nil inView:tab];
    y -= 36;
    [self preferencesButton:@"Test Connection" frame:NSMakeRect(210, y, 130, 28)
                     action:@selector(testConnection:) inView:tab];
    note = [self preferencesLabel:@"" frame:NSMakeRect(346, y + 6, 200, 18) inView:tab];
    [note setFont:[NSFont systemFontOfSize:11]];
    [prefsFields setObject:note forKey:@"relay.status"];
    y -= 56;
    [self preferencesHeading:@"Settings backup" y:y inView:tab];
    y -= 36;
    [self preferencesButton:@"Export Settings..." frame:NSMakeRect(16, y, 150, 28) action:@selector(exportAllSettings:) inView:tab];
    [self preferencesButton:@"Import Settings..." frame:NSMakeRect(172, y, 150, 28) action:@selector(importAllSettings:) inView:tab];
    [self preferencesButton:@"Clear All Settings..." frame:NSMakeRect(328, y, 170, 28) action:@selector(clearAllSettings:) inView:tab];
    y -= 22;
    [self preferencesNote:@"Backups include API keys and the relay token in plain text. Keep them private."
        frame:NSMakeRect(16, y - 10, 520, 28) inView:tab];

    /* ---- API keys ---- */
    tab = [self preferencesTab:@"API Keys" in:tabs];
    y = 304;
    [self preferencesNote:@"Add a key for each service you use. One is enough, and none is fine if you only use a local LLM server."
        frame:NSMakeRect(16, y - 14, 520, 30) inView:tab];
    y -= 40;
    keys = [NSArray arrayWithObjects:
        [NSArray arrayWithObjects:@"xAI (Grok)", @"xai_api_key", @"1", @"", nil],
        [NSArray arrayWithObjects:@"OpenAI (ChatGPT)", @"openai_api_key", @"1", @"", nil],
        [NSArray arrayWithObjects:@"Anthropic (Claude)", @"anthropic_api_key", @"1", @"", nil],
        [NSArray arrayWithObjects:@"Workspace ID (optional)", @"anthropic_workspace_id", @"0",
            @"Anthropic workspace ID. Optional. Only needed if your Anthropic key belongs to a workspace that requires the "
            @"workspace ID to be sent with each request. Most keys do not; leave it blank.", nil],
        [NSArray arrayWithObjects:@"Mistral", @"mistral_api_key", @"1", @"", nil],
        [NSArray arrayWithObjects:@"Muse", @"muse_api_key", @"1", @"", nil],
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
        help:@"An OpenAI-compatible server such as LM Studio, as this computer sees it. "
             @"It can be another computer. It is not the relay address. "
             @"Example on the relay computer: http://127.0.0.1:1234/v1. "
             @"Example on another computer: http://192.168.1.50:1234/v1. Reset removes it."
        removable:@"Reset" inView:tab];
    [[field cell] setPlaceholderString:@"not set (e.g. " TB_LOCAL_EXAMPLE ")"];
    y -= 24;
    note = [self preferencesLabel:@"" frame:NSMakeRect(200, y, 340, 16) inView:tab];
    [note setFont:[NSFont systemFontOfSize:11]];
    [prefsFields setObject:note forKey:@"local.inuse"];
    y -= 34;
    [self preferencesRow:@"Local API key (optional)" key:@"local_api_key" y:y secure:YES width:190
        help:@"Optional. Only needed if your local LLM server was set up to require a key. "
             @"LM Studio does not require one unless you turn that on."
        removable:@"Remove" inView:tab];

    /* ---- New chats ---- */
    tab = [self preferencesTab:@"New Chats" in:tabs];
    y = 284;
    [self preferencesLabel:@"New chats start with" frame:NSMakeRect(16, y + 2, 150, 18) inView:tab];
    {
        NSPopUpButton *popup = [[[NSPopUpButton alloc] initWithFrame:NSMakeRect(170, y - 2, 366, 26) pullsDown:NO] autorelease];
        [popup setFont:[NSFont systemFontOfSize:12]];
        [tab addSubview:popup];
        [prefsFields setObject:popup forKey:@"new_chat_model"];
    }
    y -= 34;
    [self preferencesNote:@"\"The model last used\" gives a new chat the model, the tool switches and the approval choices of the chat "
        @"you used most recently in the same workspace. Or pick one model to use every time."
        frame:NSMakeRect(16, y - 24, 520, 44) inView:tab];

    /* ---- Commander ---- */
    tab = [self preferencesTab:@"Commander" in:tabs];
    y = 292;
    [self preferencesNote:@"The relay runs Commander's tools on the Mac you chat from, and keeps one connection for each Mac that uses it. "
        @"These settings are for THIS Mac. Connect adds the relay's key here so no password is needed."
        frame:NSMakeRect(16, y - 28, 520, 46) inView:tab];
    y -= 74;
    [self preferencesRow:@"Mac's address" key:@"ssh_host" y:y secure:NO width:190
        help:@"The IP address or name of the Mac whose files and shell the model uses, as the relay sees it. For this Mac, choose Connect below."
        removable:nil inView:tab];
    y -= 32;
    [self preferencesRow:@"Account (short name)" key:@"ssh_user" y:y secure:NO width:190
        help:@"The short user name Commander signs in as, such as jr."
        removable:nil inView:tab];
    y -= 32;
    [self preferencesRow:@"Home folder (optional)" key:@"ssh_home" y:y secure:NO width:190
        help:@"Only needed if the account's home folder is not /Users/NAME."
        removable:nil inView:tab];
    y -= 40;
    [self preferencesButton:@"Connect This Mac" frame:NSMakeRect(16, y, 150, 28) action:@selector(connectCommanderSSH:) inView:tab];
    [self preferencesButton:@"Test" frame:NSMakeRect(172, y, 80, 28) action:@selector(testSSH:) inView:tab];
    [self preferencesButton:@"Forget Host Key" frame:NSMakeRect(258, y, 130, 28) action:@selector(forgetSSHHostKey:) inView:tab];
    [self preferencesButton:@"Disconnect" frame:NSMakeRect(394, y, 110, 28) action:@selector(disconnectCommander:) inView:tab];
    y -= 56;
    note = [self preferencesNote:@"" frame:NSMakeRect(16, y, 520, 54) inView:tab];
    [prefsFields setObject:note forKey:@"ssh.status"];

    note = [self preferencesLabel:@"" frame:NSMakeRect(16, 22, 360, 18) inView:view];
    [prefsFields setObject:note forKey:@"status"];
    button = [self preferencesButton:@"Save" frame:NSMakeRect(396, 16, 94, 30)
                              action:@selector(savePreferences:) inView:view];
    [button setKeyEquivalent:@"\r"];
    button = [self preferencesButton:@"Cancel" frame:NSMakeRect(494, 16, 94, 30)
                              action:@selector(cancelPreferences:) inView:view];
    [button setKeyEquivalent:@"\033"];
}

/* ---- Commander connection settings (kept by the relay) ---- */

- (void)setSSHStatus:(NSString *)text
{
    [[prefsFields objectForKey:@"ssh.status"] setStringValue:text ? text : @""];
}

- (void)requestSSHState
{
    if ([[RelayRequest serverBase] length] == 0)
        return;
    [RelayRequest send:@"GET" path:@"/v1/ssh" body:nil timeout:10 target:self action:@selector(sshStateArrived:) context:nil];
}

- (void)sshStateArrived:(RelayRequest *)request
{
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    NSArray *lines;
    unsigned i;
    if (![request ok])
        return;
    lines = [[request text] componentsSeparatedByString:@"\n"];
    for (i = 0; i < [lines count]; i++) {
        NSString *line = [lines objectAtIndex:i];
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location != NSNotFound)
            [values setObject:[line substringFromIndex:eq.location + 1] forKey:[line substringToIndex:eq.location]];
    }
    [[prefsFields objectForKey:@"ssh_host"] setStringValue:[values objectForKey:@"host"] ? [values objectForKey:@"host"] : @""];
    [[prefsFields objectForKey:@"ssh_user"] setStringValue:[values objectForKey:@"user"] ? [values objectForKey:@"user"] : @""];
    [[prefsFields objectForKey:@"ssh_home"] setStringValue:[values objectForKey:@"home"] ? [values objectForKey:@"home"] : @""];
    [prefsFields setObject:[NSString stringWithFormat:@"%@\n%@\n%@", [[prefsFields objectForKey:@"ssh_host"] stringValue],
        [[prefsFields objectForKey:@"ssh_user"] stringValue], [[prefsFields objectForKey:@"ssh_home"] stringValue]] forKey:@"ssh.loaded"];
    if ([[values objectForKey:@"problem"] length])
        [self setSSHStatus:[values objectForKey:@"problem"]];
    else if ([[values objectForKey:@"commander"] isEqualToString:@"online"])
        [self setSSHStatus:@"Commander is working."];
    else
        [self setSSHStatus:@""];
}

- (void)sshResultArrived:(RelayRequest *)request
{
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    NSArray *lines;
    unsigned i;
    if (![request ok]) {
        NSString *why = [[request text] length] ? [request text] : [self relayProblemForRequest:request];
        [self setSSHStatus:why];
        return;
    }
    lines = [[request text] componentsSeparatedByString:@"\n"];
    for (i = 0; i < [lines count]; i++) {
        NSString *line = [lines objectAtIndex:i];
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location != NSNotFound)
            [values setObject:[line substringFromIndex:eq.location + 1] forKey:[line substringToIndex:eq.location]];
    }
    [self setSSHStatus:[values objectForKey:@"message"]];
    [self refreshToolCatalog];
}

- (void)testSSH:(id)sender
{
    (void)sender;
    [self setSSHStatus:@"Testing..."];
    [RelayRequest send:@"POST" path:@"/v1/ssh/test" body:@"{}" timeout:40 target:self action:@selector(sshResultArrived:) context:nil];
}

- (void)disconnectCommander:(id)sender
{
    (void)sender;
    if (NSRunAlertPanel(@"Disconnect this Mac?", @"The relay stops running Commander for this Mac. Chats still work without tools. "
        @"You can connect again at any time.", @"Disconnect", @"Cancel", nil) != NSAlertDefaultReturn)
        return;
    [self setSSHStatus:@"Working..."];
    [RelayRequest send:@"POST" path:@"/v1/ssh/remove" body:@"{}" timeout:20 target:self action:@selector(sshResultArrived:) context:nil];
}

- (void)forgetSSHHostKey:(id)sender
{
    (void)sender;
    if (NSRunAlertPanel(@"Forget the saved host key?", @"Use this when the Mac was reinstalled or replaced. The relay learns its key again "
        @"the next time it connects.", @"Forget", @"Cancel", nil) != NSAlertDefaultReturn)
        return;
    [self setSSHStatus:@"Working..."];
    [RelayRequest send:@"POST" path:@"/v1/ssh/forget" body:@"{\"relearn\":true}" timeout:40 target:self
        action:@selector(sshResultArrived:) context:nil];
}

/* Send changed Commander connection fields to the relay. */
- (void)saveSSHFields
{
    NSString *now = [NSString stringWithFormat:@"%@\n%@\n%@", trimmedValue([prefsFields objectForKey:@"ssh_host"]),
        trimmedValue([prefsFields objectForKey:@"ssh_user"]), trimmedValue([prefsFields objectForKey:@"ssh_home"])];
    NSString *body;
    if (![prefsFields objectForKey:@"ssh.loaded"] || [now isEqualToString:[prefsFields objectForKey:@"ssh.loaded"]])
        return;
    body = [NSString stringWithFormat:@"{\"host\":\"%@\",\"user\":\"%@\",\"home\":\"%@\",\"remember_host_key\":true}",
        TBJSONEscape(trimmedValue([prefsFields objectForKey:@"ssh_host"])), TBJSONEscape(trimmedValue([prefsFields objectForKey:@"ssh_user"])),
        TBJSONEscape(trimmedValue([prefsFields objectForKey:@"ssh_home"]))];
    [prefsFields setObject:now forKey:@"ssh.loaded"];
    [RelayRequest send:@"POST" path:@"/v1/ssh/settings" body:body timeout:60 target:self action:@selector(sshSavedFromPrefs:) context:nil];
}

- (void)sshSavedFromPrefs:(RelayRequest *)request
{
    NSString *text = [request text];
    if (![request ok]) {
        NSRunAlertPanel(@"Preferences", @"The relay did not save the Commander settings. %@", @"OK", nil, nil, [text length] ? text : @"");
        return;
    }
    [self refreshToolCatalog];
}

- (void)showPreferences:(id)sender
{
    (void)sender;
    if (!prefsWindow)
        [self buildPreferencesWindow];
    [self loadPreferenceForm];
    [prefsWindow makeKeyAndOrderFront:nil];
}

@end
