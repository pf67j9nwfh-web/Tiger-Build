#import "ChatController_Private.h"
#import "TBEngine.h"

/* Automatic memory for a workspace (optional, off by default). While it is on, a few notes about the person and their projects are kept in the workspace's
   settings, told to the model in every chat of the workspace, and brought up to date after each reply by one more small call to that chat's model. */

#define MEMORY_LIMIT 3000

@interface ChatController (MemoryNeeds)
- (NSMutableDictionary *)chatWithId:(NSString *)chatId;
- (NSString *)providerForChat:(NSDictionary *)chat;
- (NSString *)modelForChat:(NSDictionary *)chat;
@end

@implementation ChatController (Memory)

- (BOOL)memoryOn
{
    return [[workspaceSettings objectForKey:@"memoryOn"] boolValue];
}

/* the part of a chat request that carries the memory ("" when it is off or empty) */
- (NSString *)memoryRequestFragment
{
    NSString *memory = [workspaceSettings objectForKey:@"memory"];
    if (![self memoryOn] || [memory length] == 0)
        return @"";
    return [NSString stringWithFormat:@",\"memory\":\"%@\"", TBJSONEscape(memory)];
}

/* After a reply: ask the model whether the exchange teaches anything worth keeping, and keep it */
- (void)updateMemoryAfterReply:(NSMutableDictionary *)chat
{
    NSArray *messages = [chat objectForKey:@"messages"];
    NSString *userText = nil, *assistantText = nil, *memory, *prompt;
    NSMutableString *body;
    int i;
    if (![self memoryOn] || memoryBusy || !chat)
        return;
    for (i = (int)[messages count] - 1; i >= 0 && !(userText && assistantText); i--) {
        NSDictionary *message = [messages objectAtIndex:i];
        NSString *text = [message objectForKey:@"text"], *role = [message objectForKey:@"role"];
        if ([[message objectForKey:@"status"] boolValue] || [message objectForKey:@"activityKind"] || [text length] == 0)
            continue;
        if ([role isEqualToString:@"assistant"] && !assistantText && !userText)
            assistantText = text;
        else if ([role isEqualToString:@"user"] && assistantText && !userText)
            userText = text;
    }
    if (!userText || !assistantText || [userText length] < 12)
        return;
    if ([userText length] > 2000)
        userText = [userText substringToIndex:2000];
    if ([assistantText length] > 2000)
        assistantText = [assistantText substringToIndex:2000];
    memory = [workspaceSettings objectForKey:@"memory"];
    prompt = [NSString stringWithFormat:@"Current memory:\n%@\n\nLatest exchange:\nPerson: %@\n\nAssistant: %@", [memory length] ? memory : @"(empty)", userText, assistantText];
    body = [NSMutableString stringWithString:@"{\"messages\":[{\"role\":\"user\",\"content\":\""];
    [body appendString:TBJSONEscape(prompt)];
    [body appendFormat:@"\"}],\"tools\":false,\"provider\":\"%@\",\"model\":\"%@\"}", TBJSONEscape([self providerForChat:chat]), TBJSONEscape([self modelForChat:chat])];
    memoryBusy = YES;
    [EngineRequest send:@"POST" path:@"/v1/memory" body:body timeout:60 target:self action:@selector(memoryArrived:) context:nil];
}

- (void)memoryArrived:(EngineRequest *)request
{
    NSString *text = TBTrim([request text]);
    memoryBusy = NO;
    if (![request ok] || [text length] == 0 || ![self memoryOn])
        return;
    if ([text isEqualToString:@"UNCHANGED"] || [text hasPrefix:@"UNCHANGED"])
        return;
    if ([text length] > MEMORY_LIMIT)
        text = [text substringToIndex:MEMORY_LIMIT];
    if ([text isEqualToString:[workspaceSettings objectForKey:@"memory"]])
        return;
    [workspaceSettings setObject:text forKey:@"memory"];
    [self saveStore];
}

/* ---- viewing and editing it ---- */

- (void)memoryPanelOK:(id)sender { (void)sender; [NSApp stopModalWithCode:1]; }
- (void)memoryPanelClear:(id)sender { (void)sender; [NSApp stopModalWithCode:2]; }
- (void)memoryPanelCancel:(id)sender { (void)sender; [NSApp stopModalWithCode:0]; }

- (void)editMemory:(id)sender
{
    NSPanel *panel;
    NSScrollView *scroll;
    NSTextView *view;
    NSTextField *label;
    NSButton *ok, *cancel, *clear;
    int result;
    (void)sender;
    panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 480, 340) styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
    [panel setTitle:[NSString stringWithFormat:@"Memory - %@", [self workspaceName]]];
    label = [[[NSTextField alloc] initWithFrame:NSMakeRect(20, 280, 440, 48)] autorelease];
    [label setStringValue:@"What Tiger Build keeps in mind for every chat in this workspace. It is kept up to date after each reply while memory is on; you can change it "
        @"here at any time. Remove anything you do not want carried over."];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setFont:[NSFont systemFontOfSize:11]];
    [[label cell] setWraps:YES];
    scroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(20, 56, 440, 216)] autorelease];
    [scroll setHasVerticalScroller:YES];
    [scroll setBorderType:NSBezelBorder];
    view = [[[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 420, 216)] autorelease];
    [view setMinSize:NSMakeSize(0, 216)];
    [view setMaxSize:NSMakeSize(1000000, 1000000)];
    [view setVerticallyResizable:YES];
    [view setHorizontallyResizable:NO];
    [view setAutoresizingMask:NSViewWidthSizable];
    [[view textContainer] setContainerSize:NSMakeSize(420, 1000000)];
    [[view textContainer] setWidthTracksTextView:YES];
    [view setFont:[NSFont systemFontOfSize:12]];
    [view setString:[workspaceSettings objectForKey:@"memory"] ? [workspaceSettings objectForKey:@"memory"] : @""];
    [scroll setDocumentView:view];
    ok = [[[NSButton alloc] initWithFrame:NSMakeRect(380, 12, 80, 28)] autorelease];
    [ok setTitle:@"Save"];
    [ok setBezelStyle:NSRoundedBezelStyle];
    [ok setKeyEquivalent:@"\r"];
    [ok setTarget:self];
    [ok setAction:@selector(memoryPanelOK:)];
    cancel = [[[NSButton alloc] initWithFrame:NSMakeRect(290, 12, 80, 28)] autorelease];
    [cancel setTitle:@"Cancel"];
    [cancel setBezelStyle:NSRoundedBezelStyle];
    [cancel setKeyEquivalent:@"\033"];
    [cancel setTarget:self];
    [cancel setAction:@selector(memoryPanelCancel:)];
    clear = [[[NSButton alloc] initWithFrame:NSMakeRect(20, 12, 110, 28)] autorelease];
    [clear setTitle:@"Clear Memory"];
    [clear setBezelStyle:NSRoundedBezelStyle];
    [clear setTarget:self];
    [clear setAction:@selector(memoryPanelClear:)];
    [[panel contentView] addSubview:label];
    [[panel contentView] addSubview:scroll];
    [[panel contentView] addSubview:ok];
    [[panel contentView] addSubview:cancel];
    [[panel contentView] addSubview:clear];
    [panel setDefaultButtonCell:[ok cell]];
    [panel center];
    [panel makeFirstResponder:view];
    [panel setLevel:NSFloatingWindowLevel];
    result = [NSApp runModalForWindow:panel];
    [panel orderOut:nil];
    if (result == 1) {
        NSString *text = TBTrim([view string]);
        if ([text length] > MEMORY_LIMIT)
            text = [text substringToIndex:MEMORY_LIMIT];
        if ([text length])
            [workspaceSettings setObject:text forKey:@"memory"];
        else
            [workspaceSettings removeObjectForKey:@"memory"];
        [self saveStore];
    } else if (result == 2) {
        [workspaceSettings removeObjectForKey:@"memory"];
        [self saveStore];
    }
    [panel release];
}

@end
