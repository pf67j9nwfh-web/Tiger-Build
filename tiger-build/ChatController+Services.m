#import "ChatController_Private.h"
#import "TBSupport.h"
#import "TBSpotlight.h"

/* System-wide Services: Summarize, Explain and Rewrite the selected text, and add it to a chat's message box. Summarize and Explain
   show the answer in a small panel (Copy, and an option to copy it as soon as it arrives); Rewrite hands the new text straight back
   so the selection is replaced in place, and leaves it alone when the model cannot answer. */

static const double ServiceRewriteSeconds = 90;

/* waits for one EngineRequest, for the Services that must return a value */
@interface TBServiceWait : NSObject { @public EngineRequest *request; }
- (void)arrived:(EngineRequest *)r;
@end
@implementation TBServiceWait
- (void)arrived:(EngineRequest *)r { request = [r retain]; }
- (void)dealloc { [request release]; [super dealloc]; }
@end

/* the answer panel */
@interface TBAnswerPanel : NSObject {
    NSPanel *panel;
    NSTextView *view;
    NSButton *copyButton, *autoBox;
    ChatController *chat;
    NSString *answer;
}
- (id)initWithTitle:(NSString *)title controller:(ChatController *)controller;
- (void)show;
- (void)finishedRequest:(EngineRequest *)request;
@end

static TBAnswerPanel *openAnswer = nil;

@implementation TBAnswerPanel

- (void)setBody:(NSString *)text
{
    [view setString:text];
    [view scrollRangeToVisible:NSMakeRange(0, 0)];
}

- (id)initWithTitle:(NSString *)title controller:(ChatController *)controller
{
    NSScrollView *scroll;
    NSButton *close;
    self = [super init];
    chat = controller;
    panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 480, 360)
        styleMask:NSTitledWindowMask | NSClosableWindowMask | NSResizableWindowMask backing:NSBackingStoreBuffered defer:NO];
    [panel setTitle:title];
    [panel setReleasedWhenClosed:NO];
    [panel setFloatingPanel:YES];
    scroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(12, 46, 456, 302)] autorelease];
    [scroll setHasVerticalScroller:YES];
    [scroll setBorderType:NSBezelBorder];
    [scroll setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    view = [[[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 440, 302)] autorelease];
    [view setEditable:NO];
    [view setMinSize:NSMakeSize(0, 302)];
    [view setMaxSize:NSMakeSize(1e7, 1e7)];
    [view setVerticallyResizable:YES];
    [view setAutoresizingMask:NSViewWidthSizable];
    [[view textContainer] setWidthTracksTextView:YES];
    [view setFont:[NSFont systemFontOfSize:13]];
    [scroll setDocumentView:view];
    [[panel contentView] addSubview:scroll];
    copyButton = [[[NSButton alloc] initWithFrame:NSMakeRect(12, 10, 80, 28)] autorelease];
    [copyButton setTitle:@"Copy"];
    [copyButton setBezelStyle:NSRoundedBezelStyle];
    [copyButton setTarget:self];
    [copyButton setAction:@selector(copy:)];
    [copyButton setEnabled:NO];
    [[panel contentView] addSubview:copyButton];
    autoBox = [[[NSButton alloc] initWithFrame:NSMakeRect(100, 12, 250, 24)] autorelease];
    [autoBox setButtonType:NSSwitchButton];
    [autoBox setTitle:@"Copy the answer automatically"];
    [autoBox setState:[[NSUserDefaults standardUserDefaults] boolForKey:@"TBServicesAutoCopy"] ? NSOnState : NSOffState];
    [autoBox setTarget:self];
    [autoBox setAction:@selector(autoChanged:)];
    [[panel contentView] addSubview:autoBox];
    close = [[[NSButton alloc] initWithFrame:NSMakeRect(388, 10, 80, 28)] autorelease];
    [close setTitle:@"Close"];
    [close setBezelStyle:NSRoundedBezelStyle];
    [close setKeyEquivalent:@"\033"];
    [close setTarget:panel];
    [close setAction:@selector(performClose:)];
    [close setAutoresizingMask:NSViewMinXMargin];
    [[panel contentView] addSubview:close];
    [self setBody:@"Working..."];
    return self;
}

- (void)dealloc { [panel release]; [answer release]; [super dealloc]; }

- (void)show
{
    [panel center];
    [panel makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)copy:(id)sender
{
    (void)sender;
    if ([answer length] == 0)
        return;
    [[NSPasteboard generalPasteboard] declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
    [[NSPasteboard generalPasteboard] setString:answer forType:NSStringPboardType];
}

- (void)autoChanged:(id)sender
{
    [[NSUserDefaults standardUserDefaults] setBool:[sender state] == NSOnState forKey:@"TBServicesAutoCopy"];
}

- (void)finishedRequest:(EngineRequest *)request
{
    NSString *text = [[request text] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [chat noteSideUsage:request chat:nil];
    if (![request ok] || [text length] == 0) {
        [self setBody:[request timedOut] ? @"The model took too long to answer." : ([text length] ? text : @"The model could not answer.")];
        return;
    }
    answer = [text retain];
    [self setBody:text];
    [copyButton setEnabled:YES];
    if ([autoBox state] == NSOnState)
        [self copy:nil];
}

@end

@implementation ChatController (Services)

/* the service and model a Service uses: the open chat's, or the first one that has a key */
- (BOOL)serviceProvider:(NSString **)provider model:(NSString **)model
{
    NSArray *all;
    unsigned i;
    NSString *pid = current ? [self providerForChat:current] : nil;
    if (pid && [self providerUsable:pid]) {
        *provider = pid;
        *model = [self modelForChat:current];
        return YES;
    }
    all = [[ModelCatalog shared] providers];
    for (i = 0; i < [all count]; i++) {
        pid = [[all objectAtIndex:i] objectForKey:@"id"];
        if ([self providerUsable:pid]) {
            *provider = pid;
            *model = [self defaultModelForProvider:pid];
            return YES;
        }
    }
    return NO;
}

- (NSString *)serviceBodyForMode:(NSString *)mode text:(NSString *)text
{
    NSString *provider, *model;
    if (![self serviceProvider:&provider model:&model])
        return nil;
    if ([text length] > 60000)
        text = [text substringToIndex:60000];
    return [NSString stringWithFormat:@"{\"mode\":\"%@\",\"messages\":[{\"role\":\"user\",\"content\":\"%@\"}],\"tools\":false,\"provider\":\"%@\",\"model\":\"%@\"}",
        mode, TBJSONEscape(text), TBJSONEscape(provider), TBJSONEscape(model ? model : @"")];
}

- (void)serviceAnswer:(NSPasteboard *)pboard mode:(NSString *)mode title:(NSString *)title error:(NSString **)error
{
    NSString *text = [pboard stringForType:NSStringPboardType];
    NSString *body;
    if ([text length] == 0) {
        *error = @"There was no text to work on.";
        return;
    }
    body = [self serviceBodyForMode:mode text:text];
    if (!body) {
        *error = @"Tiger Build has no service with a key. Add one in Preferences.";
        return;
    }
    [openAnswer release];
    openAnswer = [[TBAnswerPanel alloc] initWithTitle:title controller:self];
    [openAnswer show];
    [EngineRequest send:@"POST" path:@"/v1/transform" body:body timeout:120 target:openAnswer action:@selector(finishedRequest:) context:nil];
}

- (void)summarizeSelection:(NSPasteboard *)pboard userData:(NSString *)userData error:(NSString **)error
{
    (void)userData;
    [self serviceAnswer:pboard mode:@"summarize" title:@"Summary" error:error];
}

- (void)explainSelection:(NSPasteboard *)pboard userData:(NSString *)userData error:(NSString **)error
{
    (void)userData;
    [self serviceAnswer:pboard mode:@"explain" title:@"Explanation" error:error];
}

/* replaces the selection: the new text goes back on the pasteboard; on any failure the error leaves the selection as it was */
- (void)rewriteSelection:(NSPasteboard *)pboard userData:(NSString *)userData error:(NSString **)error
{
    NSString *text = [pboard stringForType:NSStringPboardType];
    NSString *body, *reply;
    TBServiceWait *wait;
    NSDate *until;
    (void)userData;
    if ([text length] == 0) {
        *error = @"There was no text to rewrite.";
        return;
    }
    body = [self serviceBodyForMode:@"rewrite" text:text];
    if (!body) {
        *error = @"Tiger Build has no service with a key. Add one in Preferences.";
        return;
    }
    wait = [[[TBServiceWait alloc] init] autorelease];
    [EngineRequest send:@"POST" path:@"/v1/transform" body:body timeout:ServiceRewriteSeconds target:wait action:@selector(arrived:) context:nil];
    until = [NSDate dateWithTimeIntervalSinceNow:ServiceRewriteSeconds + 5];
    while (!wait->request && [until timeIntervalSinceNow] > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    if (!wait->request) {
        *error = @"The model took too long to answer.";
        return;
    }
    [self noteSideUsage:wait->request chat:nil];
    reply = [[wait->request text] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (![wait->request ok] || [reply length] == 0) {
        *error = [reply length] ? reply : @"The model could not rewrite the text.";
        return;
    }
    /* keep the selection's own trailing line break, if it had one */
    if ([text hasSuffix:@"\n"] && ![reply hasSuffix:@"\n"])
        reply = [reply stringByAppendingString:@"\n"];
    [pboard declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
    [pboard setString:reply forType:NSStringPboardType];
}

/* the selection goes onto the end of the open chat's message box, ready to send; with no chat open, into a new one */
- (void)addSelection:(NSPasteboard *)pboard userData:(NSString *)userData error:(NSString **)error
{
    NSString *text = [pboard stringForType:NSStringPboardType];
    NSString *have;
    (void)userData;
    if ([text length] == 0) {
        *error = @"There was no text to add.";
        return;
    }
    if ([text length] > 100000)
        text = [text substringToIndex:100000];
    if (!current) {
        [self askInNewChat:[text stringByAppendingString:@"\n\n"] send:NO];
        return;
    }
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    have = [input stringValue];
    [input setStringValue:[have length] ? [NSString stringWithFormat:@"%@\n\n%@\n\n", have, text] : [text stringByAppendingString:@"\n\n"]];
    [window makeFirstResponder:input];
}

/* A result of Spotlight search of chats: the file names the workspace and the chat, which is shown. */
- (void)openSpotlightChat:(NSString *)path
{
    NSString *workspace = nil, *ident = nil;
    NSMutableDictionary *chat;
    unsigned at;
    if (![TBSpotlight readChatFile:path workspace:&workspace chatId:&ident])
        return;
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    if (![workspace isEqualToString:[self workspaceName]])
        [self switchWorkspace:workspace];
    chat = [self chatWithId:ident];
    if (!chat || ![workspace isEqualToString:[self workspaceName]]) {
        NSRunAlertPanel(@"Chat not found", @"That chat is no longer in the workspace \"%@\", or a reply is running, so the workspace was not changed.", @"OK", nil, nil, workspace);
        return;
    }
    at = (unsigned)[chats indexOfObjectIdenticalTo:chat];
    [self reloadTableSelect:(int)at show:YES];
}

@end
