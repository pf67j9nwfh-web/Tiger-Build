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
        return @"No local server set up. Enter its address if you use one.";
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
        [self setPreferencesStatus:@"No provider keys yet. Add any you use, or use only a local server."];
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
    if (NSRunAlertPanel(@"Clear all relay settings?", @"Remove every provider/search API key, workspace ID, local server settings and custom MCP configuration? "
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
    NSButton *button = [[NSButton alloc] initWithFrame:NSMakeRect(190, y, 21, 23)];
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
    [self preferencesLabel:title frame:NSMakeRect(16, y + 2, 172, 18) inView:view];
    if (help)
        [self preferencesHelp:help y:y inView:view];
    if (secure)
        field = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(216, y, width, 22)];
    else
        field = [[NSTextField alloc] initWithFrame:NSMakeRect(216, y, width, 22)];
    [field setEditable:YES];
    [field setSelectable:YES];
    [field setBezeled:YES];
    [field setFont:[NSFont systemFontOfSize:12]];
    if (help)
        [field setToolTip:help];
    [view addSubview:field];
    [prefsFields setObject:field forKey:key];
    [field release];
    [prefsFields setObject:[self preferencesLabel:@"" frame:NSMakeRect(454, y + 2, 50, 18) inView:view]
                    forKey:[key stringByAppendingString:@".note"]];
    if (removeTitle) {
        remove = [self preferencesButton:removeTitle frame:NSMakeRect(506, y - 3, 92, 28)
                                  action:@selector(removeSetting:) inView:view];
        [[remove cell] setControlSize:NSSmallControlSize];
        [remove setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
        [remove setEnabled:NO];
        [prefsFields setObject:remove forKey:[@"remove." stringByAppendingString:key]];
    }
    return field;
}

- (void)buildPreferencesWindow
{
    NSView *view;
    NSTextField *field;
    NSTextField *note;
    NSButton *button;
    NSArray *keys;
    unsigned i;
    float y;
    prefsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 614, 640)
                                               styleMask:NSTitledWindowMask | NSClosableWindowMask
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
    [prefsWindow setTitle:@"Preferences"];
    [prefsWindow setReleasedWhenClosed:NO];
    [prefsWindow center];
    view = [prefsWindow contentView];
    y = 604;

    [self preferencesHeading:@"Relay" y:y inView:view];
    y -= 32;
    field = [self preferencesRow:@"Relay address" key:@"relay_host" y:y secure:NO width:148
        help:@"The IP address or name of the Mac running the relay, such as 192.168.1.10. The relay app shows it under Reachable address. "
             @"Put the port in the Port box; the relay uses 8765 unless its config.sh says otherwise."
        removable:nil inView:view];
    [[field cell] setPlaceholderString:@"relay Mac address"];
    [self preferencesLabel:@"Port" frame:NSMakeRect(370, y + 2, 32, 18) inView:view];
    field = [[NSTextField alloc] initWithFrame:NSMakeRect(402, y, 50, 22)];
    [field setEditable:YES];
    [field setBezeled:YES];
    [field setFont:[NSFont systemFontOfSize:12]];
    [[field cell] setPlaceholderString:@"8765"];
    [field setToolTip:@"The relay's port. 8765 unless LISTEN_PORT was changed in the relay's config.sh."];
    [view addSubview:field];
    [prefsFields setObject:field forKey:@"relay_port"];
    [field release];
    y -= 32;
    [self preferencesRow:@"Relay token" key:@"relay_token" y:y secure:YES width:236
        help:@"The shared secret that lets this Mac use the relay. It is in relay-token on the relay Mac; "
             @"setup.sh prints it and install-tiger.sh fills it in. Leave blank to keep the saved one."
        removable:nil inView:view];
    y -= 36;
    [self preferencesButton:@"Test Connection" frame:NSMakeRect(210, y, 130, 28)
                     action:@selector(testConnection:) inView:view];
    note = [self preferencesLabel:@"" frame:NSMakeRect(346, y + 6, 252, 18) inView:view];
    [note setFont:[NSFont systemFontOfSize:11]];
    [prefsFields setObject:note forKey:@"relay.status"];

    y -= 40;
    [self preferencesHeading:@"Provider API keys" y:y inView:view];
    y -= 18;
    note = [self preferencesLabel:@"Add a key for each service you use. One is enough, and none is fine if you only use a local server."
                            frame:NSMakeRect(16, y, 582, 16) inView:view];
    [note setFont:[NSFont systemFontOfSize:11]];
    y -= 30;
    /* title, key, secure ("1"), help or "" */
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
            secure:[[row objectAtIndex:2] isEqualToString:@"1"] width:236
            help:([help length] ? help : nil) removable:@"Remove" inView:view];
        y -= 30;
    }

    y -= 10;
    [self preferencesHeading:@"Local server" y:y inView:view];
    y -= 32;
    field = [self preferencesRow:@"Local server address" key:@"local_url" y:y secure:NO width:236
        help:@"An OpenAI-compatible server such as LM Studio, as this computer sees it. "
             @"It can be another computer. It is not the relay address. "
             @"Example on the relay computer: http://127.0.0.1:1234/v1. "
             @"Example on another computer: http://192.168.1.50:1234/v1. Reset removes it."
        removable:@"Reset" inView:view];
    [[field cell] setPlaceholderString:@"not set (e.g. " TB_LOCAL_EXAMPLE ")"];
    y -= 22;
    note = [self preferencesLabel:@"" frame:NSMakeRect(216, y, 382, 16) inView:view];
    [note setFont:[NSFont systemFontOfSize:11]];
    [prefsFields setObject:note forKey:@"local.inuse"];
    y -= 30;
    [self preferencesRow:@"Local API key (optional)" key:@"local_api_key" y:y secure:YES width:236
        help:@"Optional. Only needed if your local server was set up to require a key. "
             @"LM Studio does not require one unless you turn that on."
        removable:@"Remove" inView:view];

    note = [self preferencesLabel:@"" frame:NSMakeRect(16, 22, 360, 18) inView:view];
    [prefsFields setObject:note forKey:@"status"];
    [self preferencesButton:@"Clear All Settings..." frame:NSMakeRect(16, 48, 165, 28)
        action:@selector(clearAllSettings:) inView:view];
    [self preferencesButton:@"Export Settings..." frame:NSMakeRect(185,48,143,28) action:@selector(exportAllSettings:) inView:view];
    [self preferencesButton:@"Import Settings..." frame:NSMakeRect(330,48,143,28) action:@selector(importAllSettings:) inView:view];
    button = [self preferencesButton:@"Save" frame:NSMakeRect(410, 14, 94, 30)
                              action:@selector(savePreferences:) inView:view];
    [button setKeyEquivalent:@"\r"];
    button = [self preferencesButton:@"Cancel" frame:NSMakeRect(506, 14, 94, 30)
                              action:@selector(cancelPreferences:) inView:view];
    [button setKeyEquivalent:@"\033"];
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
