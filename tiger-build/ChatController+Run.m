#import "ChatController_Private.h"
#import "TranscriptView.h"
#import <stdlib.h>

/* Everything about a running turn and the per-chat tool switches:
   stop, guidance, tool approval, token usage and cost, the live thinking
   strip, edit and retry of the last message, and the Tools menu. */

static NSString *const TBGuidanceMark = @"Guidance";

/* Providers whose tool loop can take a note between steps. A note only
   arrives at a tool boundary, so a chat with no tools on cannot use it. */
static BOOL providerTakesGuidance(NSString *provider)
{
    return [provider isEqualToString:@"grok"] || [provider isEqualToString:@"chatgpt"]
        || [provider isEqualToString:@"claude"] || [provider isEqualToString:@"gemini"]
        || [provider isEqualToString:@"mistral"];
}

static NSString *newRunId(void)
{
    static unsigned counter = 0;
    counter++;
    return [NSString stringWithFormat:@"r%08x%04x%08x", (unsigned)CFAbsoluteTimeGetCurrent(), counter & 0xffff, (unsigned)random()];
}

@implementation ChatController (Run)

/* ---- per-chat tool switches ---- */

- (NSArray *)currentToolCatalog
{
    if ([toolCatalog count] > 0)
        return toolCatalog;
    return [NSArray arrayWithObject:[NSDictionary dictionaryWithObjectsAndKeys:
        @"commander", @"id", @"Commander (this Mac)", @"title", [NSNumber numberWithBool:YES], @"default", nil]];
}

- (NSDictionary *)catalogEntry:(NSString *)key
{
    NSArray *list = [self currentToolCatalog];
    unsigned i;
    for (i = 0; i < [list count]; i++) {
        NSDictionary *entry = [list objectAtIndex:i];
        if ([[entry objectForKey:@"id"] isEqualToString:key])
            return entry;
    }
    return nil;
}

- (BOOL)serverEnabled:(NSString *)key chat:(NSDictionary *)chat
{
    NSDictionary *servers = [chat objectForKey:@"servers"];
    id value = [servers isKindOfClass:[NSDictionary class]] ? [servers objectForKey:key] : nil;
    NSDictionary *entry;
    if (value)
        return [value boolValue];
    /* Chats from before 1.3 only have the Commander switch. */
    if ([key isEqualToString:@"commander"])
        return [self toolsEnabled:chat];
    entry = [self catalogEntry:key];
    if (entry && [entry objectForKey:@"default"])
        return [[entry objectForKey:@"default"] boolValue];
    return YES;
}

- (void)setServer:(NSString *)key enabled:(BOOL)on chat:(NSMutableDictionary *)chat
{
    NSMutableDictionary *servers = [chat objectForKey:@"servers"];
    if (![servers isKindOfClass:[NSMutableDictionary class]]) {
        servers = [NSMutableDictionary dictionaryWithDictionary:[servers isKindOfClass:[NSDictionary class]] ? servers : [NSDictionary dictionary]];
        [chat setObject:servers forKey:@"servers"];
    }
    [servers setObject:[NSNumber numberWithBool:on] forKey:key];
    if ([key isEqualToString:@"commander"])
        [chat setObject:[NSNumber numberWithBool:on] forKey:@"tools"];
}

- (BOOL)anyServerEnabled:(NSDictionary *)chat
{
    NSArray *list = [self currentToolCatalog];
    unsigned i;
    for (i = 0; i < [list count]; i++) {
        if ([self serverEnabled:[[list objectAtIndex:i] objectForKey:@"id"] chat:chat])
            return YES;
    }
    return NO;
}

- (BOOL)approvalOn:(NSString *)key chat:(NSDictionary *)chat
{
    NSDictionary *approve = [chat objectForKey:@"approve"];
    id value = [approve isKindOfClass:[NSDictionary class]] ? [approve objectForKey:key] : nil;
    if (value)
        return [value boolValue];
    value = [approve isKindOfClass:[NSDictionary class]] ? [approve objectForKey:@"all"] : nil;
    if (value)
        return [value boolValue];
    if (([key isEqualToString:@"commander"] || [key hasPrefix:@"mcp_"]) && [self chatHasAttachments:chat])
        return YES;
    return [[[self catalogEntry:key] objectForKey:@"approval"] boolValue];
}

- (void)setApproval:(BOOL)on forKey:(NSString *)key chat:(NSMutableDictionary *)chat
{
    NSMutableDictionary *approve = [chat objectForKey:@"approve"];
    if (![approve isKindOfClass:[NSMutableDictionary class]]) {
        approve = [NSMutableDictionary dictionaryWithDictionary:[approve isKindOfClass:[NSDictionary class]] ? approve : [NSDictionary dictionary]];
        [chat setObject:approve forKey:@"approve"];
    }
    [approve setObject:[NSNumber numberWithBool:on] forKey:key];
}

/* The relay's switches for this chat, as JSON members to add to a request. */
- (NSString *)runOptionsJSONForChat:(NSDictionary *)chat
{
    NSMutableString *out = [NSMutableString string];
    NSArray *list = [self currentToolCatalog];
    NSDictionary *approve = [chat objectForKey:@"approve"];
    NSString *root = [workspaceSettings objectForKey:@"root"];
    unsigned i;
    [out appendString:@",\"servers\":{"];
    for (i = 0; i < [list count]; i++) {
        NSString *key = [[list objectAtIndex:i] objectForKey:@"id"];
        [out appendFormat:@"%@\"%@\":%s", i ? @"," : @"", TBJSONEscape(key), [self serverEnabled:key chat:chat] ? "true" : "false"];
    }
    [out appendString:@"},\"approve\":{"];
    {
        /* A document, web page or search result can contain instructions aimed at the model. In a chat that has
           attached files, tools that can act on the Mac ask first unless the person has chosen otherwise for them. */
        BOOL attached = NO;
        NSArray *messages = [chat objectForKey:@"messages"];
        unsigned m;
        for (m = 0; m < [messages count] && !attached; m++)
            attached = [[messages objectAtIndex:m] objectForKey:@"attachment"] != nil;
        if (attached) {
            NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:[approve isKindOfClass:[NSDictionary class]] ? approve : [NSDictionary dictionary]];
            for (i = 0; i < [list count]; i++) {
                NSString *key = [[list objectAtIndex:i] objectForKey:@"id"];
                if (([key isEqualToString:@"commander"] || [key hasPrefix:@"mcp_"]) && ![merged objectForKey:key] && ![merged objectForKey:@"all"])
                    [merged setObject:[NSNumber numberWithBool:YES] forKey:key];
            }
            approve = merged;
        }
    }
    if ([approve isKindOfClass:[NSDictionary class]]) {
        NSEnumerator *keys = [approve keyEnumerator];
        NSString *key;
        BOOL first = YES;
        while ((key = [keys nextObject])) {
            [out appendFormat:@"%@\"%@\":%s", first ? @"" : @",", TBJSONEscape(key), [[approve objectForKey:key] boolValue] ? "true" : "false"];
            first = NO;
        }
    }
    [out appendString:@"}"];
    if ([[workspaceSettings objectForKey:@"limitRoot"] boolValue] && [root length] > 0)
        [out appendFormat:@",\"root\":\"%@\"", TBJSONEscape(root)];
    if ([[chat objectForKey:@"instructions"] length] > 0)
        [out appendFormat:@",\"instructions\":\"%@\"", TBJSONEscape([chat objectForKey:@"instructions"])];
    return out;
}

/* ---- tools menu ---- */

- (NSString *)toolsSummary
{
    NSArray *list = [self currentToolCatalog];
    unsigned i;
    int on = 0;
    NSString *only = nil;
    for (i = 0; i < [list count]; i++) {
        NSDictionary *entry = [list objectAtIndex:i];
        if ([self serverEnabled:[entry objectForKey:@"id"] chat:current]) {
            on++;
            only = [entry objectForKey:@"title"];
        }
    }
    if (on == 0)
        return @"Tools: Off";
    if (on == 1) {
        if ([[only lowercaseString] hasPrefix:@"commander"])
            return @"Tools: Commander";
        return [NSString stringWithFormat:@"Tools: %@", only];
    }
    return [NSString stringWithFormat:@"Tools: %d on", on];
}

- (NSMenuItem *)toolsItem:(NSString *)title action:(SEL)action key:(NSString *)key state:(BOOL)on
{
    NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""] autorelease];
    [item setTarget:self];
    [item setEnabled:YES];
    if (key)
        [item setRepresentedObject:key];
    [item setState:on ? NSOnState : NSOffState];
    return item;
}

- (void)rebuildToolsMenu
{
    NSMenu *menu;
    NSMenu *ask;
    NSMenuItem *slot;
    NSArray *list = [self currentToolCatalog];
    unsigned i;
    BOOL anyAsk = NO;
    if (!toolsPopup)
        return;
    menu = [toolsPopup menu];
    [menu setAutoenablesItems:NO];
    while ([menu numberOfItems] > 0)
        [menu removeItemAtIndex:0];
    /* The first item of a pull-down is the button's own title. */
    [menu addItem:[self toolsItem:[self toolsSummary] action:NULL key:nil state:NO]];
    for (i = 0; i < [list count]; i++) {
        NSDictionary *entry = [list objectAtIndex:i];
        NSString *key = [entry objectForKey:@"id"];
        [menu addItem:[self toolsItem:[entry objectForKey:@"title"] action:@selector(toggleServer:) key:key
            state:[self serverEnabled:key chat:current]]];
    }
    [menu addItem:[NSMenuItem separatorItem]];
    ask = [[[NSMenu alloc] initWithTitle:@"Ask Before Running"] autorelease];
    [ask setAutoenablesItems:NO];
    for (i = 0; i < [list count]; i++) {
        NSDictionary *entry = [list objectAtIndex:i];
        NSString *key = [entry objectForKey:@"id"];
        BOOL on = [self approvalOn:key chat:current];
        anyAsk = anyAsk || on;
        [ask addItem:[self toolsItem:[entry objectForKey:@"title"] action:@selector(toggleApproval:) key:key state:on]];
    }
    [menu addItem:[self toolsItem:@"Ask Before Running Any Tool" action:@selector(toggleApprovalAll:) key:@"all"
        state:[[[current objectForKey:@"approve"] objectForKey:@"all"] boolValue]]];
    slot = [[[NSMenuItem alloc] initWithTitle:anyAsk ? @"Ask Before Running (on for some)" : @"Ask Before Running"
        action:NULL keyEquivalent:@""] autorelease];
    [slot setSubmenu:ask];
    [slot setEnabled:YES];
    [menu addItem:slot];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItem:[self toolsItem:@"Tool Settings..." action:@selector(showIntegrations:) key:nil state:NO]];
    [menu addItem:[self toolsItem:@"Workspace Directory Restriction..." action:@selector(showWorkspaceSettings:) key:nil state:NO]];
    [toolsPopup selectItemAtIndex:0];
}

- (void)toggleServer:(id)sender
{
    NSString *key = [sender representedObject];
    if (!current || !key)
        return;
    [self setServer:key enabled:![self serverEnabled:key chat:current] chat:current];
    [self rebuildToolsMenu];
    [self saveStore];
    [self updateContextReadout];
}

- (void)toggleApproval:(id)sender
{
    NSString *key = [sender representedObject];
    if (!current || !key)
        return;
    [self setApproval:![self approvalOn:key chat:current] forKey:key chat:current];
    [self rebuildToolsMenu];
    [self saveStore];
}

- (void)toggleApprovalAll:(id)sender
{
    BOOL on = ![[[current objectForKey:@"approve"] objectForKey:@"all"] boolValue];
    (void)sender;
    if (!current)
        return;
    [self setApproval:on forKey:@"all" chat:current];
    /* Per-server answers made earlier would otherwise keep overriding "all". */
    if ([[current objectForKey:@"approve"] isKindOfClass:[NSMutableDictionary class]]) {
        NSMutableDictionary *approve = [current objectForKey:@"approve"];
        NSArray *list = [self currentToolCatalog];
        unsigned i;
        for (i = 0; i < [list count]; i++)
            [approve removeObjectForKey:[[list objectAtIndex:i] objectForKey:@"id"]];
    }
    [self rebuildToolsMenu];
    [self saveStore];
}

/* Commander's own on/off, used by the menu bar shortcut. */
- (IBAction)toggleTools:(id)sender
{
    (void)sender;
    if (!current)
        return;
    [self setServer:@"commander" enabled:![self serverEnabled:@"commander" chat:current] chat:current];
    [self rebuildToolsMenu];
    [self saveStore];
}

- (void)refreshToolCatalog
{
    [EngineRequest send:@"GET" path:@"/v1/tools" body:nil timeout:12 target:self action:@selector(toolCatalogArrived:) context:nil];
}

- (void)toolCatalogArrived:(EngineRequest *)request
{
    NSString *error = nil;
    NSDictionary *data;
    NSArray *list;
    if (![request ok])
        return;
    data = [NSPropertyListSerialization propertyListFromData:[request data] mutabilityOption:NSPropertyListImmutable
        format:NULL errorDescription:&error];
    if (error)
        [error release];
    if (![data isKindOfClass:[NSDictionary class]])
        return;
    list = [data objectForKey:@"tools"];
    if ([list isKindOfClass:[NSArray class]] && [list count] > 0) {
        [toolCatalog release];
        toolCatalog = [list retain];
    }
    [commanderProblem release];
    commanderProblem = [[data objectForKey:@"commander_problem"] copy];
    [commanderCode release];
    commanderCode = [[data objectForKey:@"commander_code"] copy];
    [self rebuildToolsMenu];
    [self commanderProblemChanged];
}

/* ---- usage, cost and context ---- */

- (void)noteUsage:(NSDictionary *)event chat:(NSMutableDictionary *)chat
{
    int context = [[event objectForKey:@"context"] intValue];
    TBAddUsage(chat, event);
    if (context > 0) {
        [chat setObject:[NSNumber numberWithInt:context] forKey:@"ctxTokens"];
        [chat setObject:[NSNumber numberWithInt:(int)[[chat objectForKey:@"messages"] count]] forKey:@"ctxAt"];
    }
    if (chat == current)
        [self updateContextReadout];
}

/* ---- the live thinking strip ---- */

- (void)setThinkingText:(NSString *)text
{
    NSString *shown;
    if ((!text && !thinkingText) || [text isEqualToString:thinkingText])
        return;
    [thinkingText release];
    thinkingText = [text copy];
    if ([text length] == 0) {
        [thinkingField setStringValue:@""];
    } else {
        /* Keep the end: that is what the model is on now. */
        shown = text;
        if ([shown length] > 360)
            shown = [@"..." stringByAppendingString:[shown substringFromIndex:[shown length] - 357]];
        shown = [[shown componentsSeparatedByString:@"\n\n"] componentsJoinedByString:@" "];
        shown = [[shown componentsSeparatedByString:@"\n"] componentsJoinedByString:@" "];
        [thinkingField setStringValue:[@"Thinking: " stringByAppendingString:shown]];
    }
    [self layoutPanes];
}

- (void)noteThinking:(NSString *)piece
{
    NSString *soFar = thinkingText ? thinkingText : @"";
    /* A new reasoning block replaces the old one; blocks arrive separated by
       blank lines, and only the latest matters. */
    if ([soFar length] > 6000)
        soFar = [soFar substringFromIndex:[soFar length] - 3000];
    [self setThinkingText:[soFar stringByAppendingString:piece ? piece : @""]];
}

/* ---- stop ---- */

- (IBAction)stopRun:(id)sender
{
    NSMutableDictionary *chat;
    (void)sender;
    if (!busy) {
        if (![self cancelDictation])
            [self cancelAttachments];
        return;
    }
    stopping = YES;
    [self stopSpeaking:nil];
    if (sideRequest) {
        /* Still compacting, before the chat stream started. */
        [sideRequest cancel];
        sideRequest = nil;
    }
    if (runId) {
        [EngineRequest send:@"POST" path:@"/v1/run"
            body:[NSString stringWithFormat:@"{\"id\":\"%@\",\"action\":\"stop\"}", TBJSONEscape(runId)]
            timeout:8 target:self action:@selector(runCommandDone:) context:nil];
    }
    chat = [self chatWithId:streamingId];
    if (chat) {
        /* Tool cards that were still running stop with the turn. */
        NSArray *messages = [chat objectForKey:@"messages"];
        unsigned i;
        for (i = 0; i < [messages count]; i++) {
            NSMutableDictionary *message = [messages objectAtIndex:i];
            NSString *text = [message objectForKey:@"text"];
            if ([message objectForKey:@"activityKind"] && [text hasSuffix:@" - Running"])
                [message setObject:[[text substringToIndex:[text length] - 7] stringByAppendingString:@"Stopped"] forKey:@"text"];
        }
        [self addStatus:@"Stopped." toChat:chat];
    }
    if (bodyStream)
        [self finishStream];
    else
        [self finishWithoutStream:chat];
}

- (void)runCommandDone:(EngineRequest *)request
{
    (void)request;
}

/* ---- guidance ---- */

- (BOOL)guidanceAvailable
{
    return busy && bodyStream != NULL && runId && !stopping && current
        && providerTakesGuidance([self providerForChat:[self chatWithId:streamingId]])
        && [self anyServerEnabled:[self chatWithId:streamingId]];
}

- (void)sendGuidance:(NSString *)text
{
    NSMutableDictionary *chat = [self chatWithId:streamingId];
    if (!chat || [text length] == 0)
        return;
    if (!queuedGuidance)
        queuedGuidance = [[NSMutableArray alloc] init];
    [queuedGuidance addObject:text];
    [self addStatus:[NSString stringWithFormat:@"%@ queued: %@", TBGuidanceMark, text] toChat:chat];
    [EngineRequest send:@"POST" path:@"/v1/run"
        body:[NSString stringWithFormat:@"{\"id\":\"%@\",\"action\":\"guide\",\"text\":\"%@\"}", TBJSONEscape(runId), TBJSONEscape(text)]
        timeout:10 target:self action:@selector(guidanceSent:) context:text];
}

- (void)guidanceSent:(EngineRequest *)request
{
    NSString *text = [request context];
    if ([request ok] || !text)
        return;
    /* The relay did not take it (the turn just ended, or too many queued). */
    [queuedGuidance removeObject:text];
    [self returnTextToField:text];
}

- (void)returnTextToField:(NSString *)text
{
    NSString *existing = [input stringValue];
    if ([existing length] > 0)
        text = [NSString stringWithFormat:@"%@\n%@", existing, text];
    [input setStringValue:text];
    [self layoutPanes];
}

- (void)guidanceDelivered:(NSString *)text chat:(NSMutableDictionary *)chat
{
    NSUInteger i = [queuedGuidance indexOfObject:text];
    if (i != NSNotFound)
        [queuedGuidance removeObjectAtIndex:i];
    [self addStatus:[NSString stringWithFormat:@"%@ delivered: %@", TBGuidanceMark, text] toChat:chat];
}

/* When the reply ends, notes the model never saw go back in the message box. */
- (void)returnUndeliveredGuidance
{
    unsigned i;
    for (i = 0; i < [queuedGuidance count]; i++)
        [self returnTextToField:[queuedGuidance objectAtIndex:i]];
    if ([queuedGuidance count] > 0) {
        NSMutableDictionary *chat = [self chatWithId:streamingId];
        if (chat)
            [self addStatus:@"The reply finished before the model took your guidance, so it is back in the message box." toChat:chat];
    }
    [queuedGuidance removeAllObjects];
}

/* ---- tool approval ---- */

- (void)askApprovalFrame:(NSData *)payload chat:(NSMutableDictionary *)chat
{
    NSString *error = nil;
    NSDictionary *event = [NSPropertyListSerialization propertyListFromData:payload mutabilityOption:NSPropertyListImmutable
        format:NULL errorDescription:&error];
    NSString *server;
    NSString *title;
    NSString *detail;
    int choice;
    NSString *decision;
    if (error)
        [error release];
    if (![event isKindOfClass:[NSDictionary class]])
        return;
    server = [event objectForKey:@"server"];
    title = [[self catalogEntry:server] objectForKey:@"title"];
    detail = [event objectForKey:@"detail"];
    if ([detail length] > 900)
        detail = [[detail substringToIndex:900] stringByAppendingString:@"..."];
    [NSApp activateIgnoringOtherApps:YES];
    choice = NSRunAlertPanel(@"Allow this tool?",
        @"The model wants to run %@ (%@):\n\n%@\n\n\"Always Allow\" stops asking for %@ in this chat.",
        @"Allow", @"Deny", @"Always Allow",
        [event objectForKey:@"name"], title ? title : server, detail, title ? title : server);
    if (choice == NSAlertDefaultReturn)
        decision = @"allow";
    else if (choice == NSAlertOtherReturn) {
        decision = @"always";
        [self setApproval:NO forKey:server chat:chat];
        [self rebuildToolsMenu];
        [self saveStore];
    } else
        decision = @"deny";
    [EngineRequest send:@"POST" path:@"/v1/run"
        body:[NSString stringWithFormat:@"{\"id\":\"%@\",\"action\":\"approve\",\"call\":\"%@\",\"decision\":\"%@\"}",
            TBJSONEscape(runId), TBJSONEscape([event objectForKey:@"id"]), decision]
        timeout:10 target:self action:@selector(runCommandDone:) context:nil];
}

/* ---- the Send button while a model runs ---- */

- (void)startPulse
{
    if (pulseTimer)
        return;
    pulse = 0;
    pulseTimer = [[NSTimer scheduledTimerWithTimeInterval:0.6 target:self selector:@selector(pulseTick:) userInfo:nil repeats:YES] retain];
}

- (void)stopPulse
{
    [pulseTimer invalidate];
    [pulseTimer release];
    pulseTimer = nil;
}

- (void)pulseTick:(NSTimer *)timer
{
    (void)timer;
    pulse++;
    [self syncRunButtons];
}

/* Send becomes Guide (with a dot that blinks while the model works) when the
   model can take notes; otherwise it waits, disabled. Stop is live only while
   something runs. */
- (void)syncRunButtons
{
    BOOL guide = [self guidanceAvailable];
    if (!sendButton)
        return;
    [stopButton setEnabled:(busy && !stopping) || [self attachmentsRunning] || [self dictationRunning]];
    if (!busy) {
        [sendButton setTitle:editBackup ? @"Resend" : @"Send"];
        [sendButton setEnabled:YES];
        [sendButton setToolTip:@"Send the message (Return)"];
    } else if (guide) {
        [sendButton setTitle:[NSString stringWithFormat:@"Guide %C", (unichar)((pulse % 2) ? 0x25CB : 0x25CF)]];
        [sendButton setEnabled:YES];
        [sendButton setToolTip:@"The model is working. A note is given to it between steps, when that is safe."];
    } else {
        [sendButton setTitle:(pulse % 2) ? @"Working" : @"Working."];
        [sendButton setEnabled:NO];
        [sendButton setToolTip:nil];
    }
    [editButton setEnabled:!busy && (editBackup || [self lastUserIndex] >= 0) && ![self chatIsBusyElsewhere:current]];
    [retryButton setEnabled:!busy && [self lastUserIndex] >= 0 && ![self chatIsBusyElsewhere:current]];
    [attachButton setEnabled:!busy && current && ![self chatIsBusyElsewhere:current]];
    [editButton setTitle:editBackup ? @"Cancel Edit" : @"Edit Last"];
}

/* ---- edit and retry the last message ---- */

- (int)lastUserIndex
{
    NSArray *messages = [current objectForKey:@"messages"];
    int i;
    for (i = (int)[messages count] - 1; i >= 0; i--) {
        NSDictionary *message = [messages objectAtIndex:i];
        if ([[message objectForKey:@"role"] isEqualToString:@"user"] && ![[message objectForKey:@"status"] boolValue]
            && ![message objectForKey:@"attachment"])
            return i;
    }
    return -1;
}

- (IBAction)retryLast:(id)sender
{
    NSMutableArray *messages;
    int index;
    NSDictionary *userMessage;
    NSMutableDictionary *openMessage;
    (void)sender;
    if (busy || !current || [self chatIsBusyElsewhere:current])
        return;
    if (editBackup)
        [self cancelEdit:nil];
    index = [self lastUserIndex];
    if (index < 0)
        return;
    if (![self providerUsable:[self providerForChat:current]]) {
        NSBeep();
        return;
    }
    messages = [current objectForKey:@"messages"];
    userMessage = [[messages objectAtIndex:index] retain];
    {
        /* Files attached after that message stay, and go in front of it again. */
        NSMutableArray *kept = [NSMutableArray array];
        unsigned k;
        for (k = index + 1; k < [messages count]; k++) {
            if ([[messages objectAtIndex:k] objectForKey:@"attachment"])
                [kept addObject:[messages objectAtIndex:k]];
        }
        while ((int)[messages count] > index)
            [messages removeLastObject];
        [messages addObjectsFromArray:kept];
    }
    [messages addObject:userMessage];
    [userMessage release];
    openMessage = [NSMutableDictionary dictionary];
    [openMessage setObject:@"assistant" forKey:@"role"];
    [openMessage setObject:@"" forKey:@"text"];
    [openMessage setObject:[NSNumber numberWithBool:NO] forKey:@"status"];
    [openMessage setObject:[NSNumber numberWithBool:YES] forKey:@"open"];
    [messages addObject:openMessage];
    [current removeObjectForKey:@"ctxTokens"];
    [self saveStore];
    [self refreshTranscriptIfCurrent:current];
    [self startTurn];
}

- (IBAction)editLast:(id)sender
{
    (void)sender;
    if (busy || !current || [self chatIsBusyElsewhere:current])
        return;
    if (editBackup) {
        [self cancelEdit:nil];
        return;
    }
    [self editAtIndex:[self lastUserIndex]];
}

/* Edit From Here, from the right-click menu of any message the person wrote. */
- (void)editFromMessage:(NSMutableDictionary *)message
{
    NSUInteger index;
    if (busy || !current || [self chatIsBusyElsewhere:current])
        return;
    if (editBackup)
        [self cancelEdit:nil];
    index = [[current objectForKey:@"messages"] indexOfObjectIdenticalTo:message];
    if (index == NSNotFound)
        return;
    [self editAtIndex:(int)index];
}

/* Take the message at this position back into the message box, with everything after it set aside
   (Cancel Edit puts it back). Files attached after it are kept, since they are not part of what is redone. */
- (void)editAtIndex:(int)index
{
    NSMutableArray *messages;
    NSMutableArray *removed;
    NSMutableArray *kept;
    NSString *text;
    unsigned k;
    if (index < 0)
        return;
    messages = [current objectForKey:@"messages"];
    removed = [NSMutableArray array];
    kept = [NSMutableArray array];
    text = [[messages objectAtIndex:index] objectForKey:@"text"];
    for (k = index; k < [messages count]; k++) {
        NSMutableDictionary *message = [messages objectAtIndex:k];
        if ((int)k > index && [message objectForKey:@"attachment"])
            [kept addObject:message];
        else
            [removed addObject:message];
    }
    while ((int)[messages count] > index)
        [messages removeLastObject];
    [messages addObjectsFromArray:kept];
    [editBackup release];
    editBackup = [removed retain];
    [input setStringValue:text ? text : @""];
    [self saveStore];
    [self refreshTranscriptIfCurrent:current];
    [self layoutPanes];
    [self syncRunButtons];
    [self updateContextReadout];
    [window makeFirstResponder:input];
}

/* Put the removed messages back; the edit is abandoned. */
- (IBAction)cancelEdit:(id)sender
{
    NSMutableArray *messages;
    (void)sender;
    if (!editBackup || !current)
        return;
    messages = [current objectForKey:@"messages"];
    [messages addObjectsFromArray:editBackup];
    [editBackup release];
    editBackup = nil;
    [input setStringValue:@""];
    [self saveStore];
    [self refreshTranscriptIfCurrent:current];
    [self layoutPanes];
    [self syncRunButtons];
    [self updateContextReadout];
}

/* An edit is over once the new message goes out, and when chats change. */
- (void)forgetEdit
{
    [editBackup release];
    editBackup = nil;
}

- (void)newRunId
{
    [runId release];
    runId = [newRunId() retain];
}

/* ---- Commander problems ---- */

- (void)commanderProblemChanged
{
    if (relayReachable)
        [self setRelayProblem:nil];
}

/* The line shown across the top for a Commander problem, or nil. */
- (NSString *)commanderStatusLine
{
    if (![commanderProblem length] || !current || ![self serverEnabled:@"commander" chat:current])
        return nil;
    return [NSString stringWithFormat:@"Commander: %@", commanderProblem];
}

@end
