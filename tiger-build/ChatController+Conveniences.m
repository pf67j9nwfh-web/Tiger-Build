#import "ChatController_Private.h"
#import "TBEngine.h"
#import "TBJSON.h"
#import <unistd.h>
#import "TBSSHServer.h"
#import "TBExtract.h"
#import "TBIntegrations.h"
#import "TBSupport.h"
#import <Carbon/Carbon.h>
#import "mbedtls/sha256.h"

/* Small conveniences: Copy Diagnostics, saved and scheduled prompts, the Services entry and Quick Ask (with its keyboard shortcut), trying a message
   with another model, the cost report, importing ChatGPT and Claude exports, and the lock. */

@interface ChatController (ConveniencesNeeds)
- (void)promptsStoreFields;
- (void)promptsShowFields;
- (NSString *)askLockPassword:(NSString *)message;
- (BOOL)lockPasswordMatches:(NSString *)typed;
- (NSMutableDictionary *)blankChat;
- (NSString *)providerForChat:(NSDictionary *)chat;
- (NSString *)modelForChat:(NSDictionary *)chat;
- (NSString *)defaultModelForProvider:(NSString *)provider;
- (NSString *)providerNote:(NSString *)provider;
- (NSString *)providerMenuTitle:(NSDictionary *)item;
- (BOOL)model:(NSString *)model allowedForProvider:(NSString *)provider;
- (void)reloadTableSelect:(int)row show:(BOOL)show;
- (void)forgetEdit;
- (void)saveStore;
- (IBAction)send:(id)sender;
- (IBAction)newChat:(id)sender;
- (NSMutableDictionary *)chatWithId:(NSString *)chatId;
- (void)rememberContextLimit;
- (void)updateContextReadout;
@end

static NSString *kPromptsKey = @"TBPrompts";

/* ---- small helpers ---- */

static NSTextField *label(NSString *text, NSRect frame, BOOL bold)
{
    NSTextField *f = [[[NSTextField alloc] initWithFrame:frame] autorelease];
    [f setStringValue:text];
    [f setEditable:NO];
    [f setBezeled:NO];
    [f setDrawsBackground:NO];
    [f setFont:bold ? [NSFont boldSystemFontOfSize:12] : [NSFont systemFontOfSize:12]];
    return f;
}

static NSButton *button(NSString *title, NSRect frame, id target, SEL action)
{
    NSButton *b = [[[NSButton alloc] initWithFrame:frame] autorelease];
    [b setTitle:title];
    [b setBezelStyle:NSRoundedBezelStyle];
    [b setTarget:target];
    [b setAction:action];
    return b;
}

static NSScrollView *textArea(NSRect frame, NSTextView **view)
{
    NSScrollView *scroll = [[[NSScrollView alloc] initWithFrame:frame] autorelease];
    NSTextView *v = [[[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, frame.size.width - 20, frame.size.height)] autorelease];
    [scroll setHasVerticalScroller:YES];
    [scroll setBorderType:NSBezelBorder];
    [v setMinSize:NSMakeSize(0, frame.size.height)];
    [v setMaxSize:NSMakeSize(1000000, 1000000)];
    [v setVerticallyResizable:YES];
    [v setHorizontallyResizable:NO];
    [v setAutoresizingMask:NSViewWidthSizable];
    [[v textContainer] setContainerSize:NSMakeSize(frame.size.width - 20, 1000000)];
    [[v textContainer] setWidthTracksTextView:YES];
    [v setFont:[NSFont systemFontOfSize:12]];
    [scroll setDocumentView:v];
    *view = v;
    return scroll;
}

static NSString *dayKey2(void)
{
    return [[NSDate date] descriptionWithCalendarFormat:@"%Y-%m-%d" timeZone:nil locale:nil];
}

/* a borderless window that can take the keyboard, for the lock screen's password box */
@interface TBLockWindow : NSWindow
@end
@implementation TBLockWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

@implementation ChatController (Conveniences)

/* ---- a new chat with a message, sent or not ---- */

- (void)askInNewChat:(NSString *)text send:(BOOL)send
{
    if ([text length] == 0)
        return;
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self newChat:nil];
    [input setStringValue:text];
    if (send)
        [self performSelector:@selector(send:) withObject:nil afterDelay:0.4];
    else
        [window makeFirstResponder:input];
}

/* ---- Copy Diagnostics ---- */

- (void)copyDiagnostics:(id)sender
{
    NSMutableString *out = [NSMutableString string];
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSArray *providers = [[ModelCatalog shared] providers];
    unsigned i;
    (void)sender;
    [out appendFormat:@"Tiger Build %@ (%@)\n", [info objectForKey:@"CFBundleShortVersionString"], [info objectForKey:@"CFBundleVersion"]];
    [out appendFormat:@"System: %@\nMachine: %@ %@\n", [TBMachine systemVersion], [TBMachine name], [TBMachine detail]];
#if defined(__x86_64__)
    [out appendString:@"Running as: x86_64\n"];
#elif defined(__i386__)
    [out appendString:@"Running as: i386\n"];
#elif defined(__ppc64__)
    [out appendString:@"Running as: ppc64\n"];
#else
    [out appendString:@"Running as: ppc\n"];
#endif
    [out appendFormat:@"Workspace: %@; chats: %u\n", [self workspaceName], (unsigned)[chats count]];
    [out appendString:@"\nServices (a key is saved: yes or no, never the key):\n"];
    for (i = 0; i < [providers count]; i++) {
        NSString *pid = [[providers objectAtIndex:i] objectForKey:@"id"];
        [out appendFormat:@"  %@: key %@, %@\n", pid, [pid isEqualToString:@"local"] ? @"-" : ([TBSettings hasKeyForProvider:pid] ? @"yes" : @"no"),
            [self providerNote:pid] ? [self providerNote:pid] : @"usable"];
    }
    [out appendFormat:@"Local server: %@\n", [[d stringForKey:@"TBSetting.local_url"] length] ? @"set" : @"not set"];
    [out appendFormat:@"\nCommander: %@\nSSH server installed: %@, listening: %@\n", [commanderProblem length] ? commanderProblem : @"ready", [TBSSHServer installed] ? @"yes" : @"no", [TBSSHServer listening] ? @"yes" : @"no"];
    [out appendFormat:@"Settings: sound %@, update check %@, spending limits %@, memory (this workspace) %@, knowledge folder %@, lock %@\n",
        [d objectForKey:@"TBSoundOnFinish"] ? ([d boolForKey:@"TBSoundOnFinish"] ? @"on" : @"off") : @"on",
        [d objectForKey:@"TBCheckUpdates"] ? ([d boolForKey:@"TBCheckUpdates"] ? @"on" : @"off") : @"on",
        ([d objectForKey:@"TBSpendChatLimit"] || [d objectForKey:@"TBSpendDayLimit"]) ? @"set" : @"none",
        [[workspaceSettings objectForKey:@"memoryOn"] boolValue] ? @"on" : @"off", [[workspaceSettings objectForKey:@"knowledgeRoot"] length] ? @"set" : @"none",
        [TBSettings hasValueForName:@"lock_hash"] ? @"set" : @"none"];
    [out appendFormat:@"MCP servers: %u\n", (unsigned)[[TBIntegrations servers] count]];
    if ([commanderCode length])
        [out appendFormat:@"Commander code: %@\n", commanderCode];
    [[NSPasteboard generalPasteboard] declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
    [[NSPasteboard generalPasteboard] setString:out forType:NSStringPboardType];
    NSRunAlertPanel(@"Diagnostics copied", @"Version, system, which services have keys (not the keys), and which features are on are on the clipboard, ready to paste into a bug report. No chats, files or keys are included.", @"OK", nil, nil);
}

/* ---- saved prompts (some of which can run at a set time) ---- */

- (NSMutableArray *)savedPrompts
{
    NSArray *stored = [[NSUserDefaults standardUserDefaults] arrayForKey:kPromptsKey];
    NSMutableArray *out = [NSMutableArray array];
    unsigned i;
    for (i = 0; i < [stored count]; i++)
        [out addObject:[NSMutableDictionary dictionaryWithDictionary:[stored objectAtIndex:i]]];
    return out;
}

- (void)storePrompts:(NSArray *)list
{
    [[NSUserDefaults standardUserDefaults] setObject:list forKey:kPromptsKey];
    [self rebuildPromptsMenu];
}

- (void)rebuildPromptsMenu
{
    NSMenu *menu = promptsMenu;
    NSArray *list = [self savedPrompts];
    NSMenuItem *item;
    unsigned i;
    if (!menu)
        return;
    while ([menu numberOfItems] > 0)
        [menu removeItemAtIndex:0];
    for (i = 0; i < [list count] && i < 40; i++) {
        item = [[[NSMenuItem alloc] initWithTitle:[[list objectAtIndex:i] objectForKey:@"name"] action:@selector(usePrompt:) keyEquivalent:@""] autorelease];
        [item setTarget:self];
        [item setTag:(int)i];
        [menu addItem:item];
    }
    if ([list count])
        [menu addItem:[NSMenuItem separatorItem]];
    item = [[[NSMenuItem alloc] initWithTitle:@"Save Message as Prompt..." action:@selector(savePromptFromInput:) keyEquivalent:@""] autorelease];
    [item setTarget:self]; [menu addItem:item];
    item = [[[NSMenuItem alloc] initWithTitle:@"Manage Prompts..." action:@selector(managePrompts:) keyEquivalent:@""] autorelease];
    [item setTarget:self]; [menu addItem:item];
}

- (void)usePrompt:(id)sender
{
    NSArray *list = [self savedPrompts];
    int at = [sender tag];
    NSString *text, *now;
    if (at < 0 || at >= (int)[list count] || !current)
        return;
    text = [[list objectAtIndex:at] objectForKey:@"text"];
    now = [input stringValue];
    [input setStringValue:[now length] ? [NSString stringWithFormat:@"%@\n%@", now, text] : text];
    [window makeKeyAndOrderFront:nil];
    [window makeFirstResponder:input];
}

- (void)promptNameOK:(id)sender { (void)sender; [NSApp stopModalWithCode:1]; }
- (void)promptNameCancel:(id)sender { (void)sender; [NSApp stopModalWithCode:0]; }

- (void)savePromptFromInput:(id)sender
{
    NSString *text = TBTrim([input stringValue]);
    NSPanel *panel;
    NSTextField *name;
    int result;
    (void)sender;
    if ([text length] == 0) {
        NSRunAlertPanel(@"Save as prompt", @"Type the message in the message box first, then choose this again.", @"OK", nil, nil);
        return;
    }
    panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 380, 120) styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
    [panel setTitle:@"Save as Prompt"];
    [[panel contentView] addSubview:label(@"Name for this prompt:", NSMakeRect(20, 84, 340, 18), NO)];
    name = [[[NSTextField alloc] initWithFrame:NSMakeRect(20, 54, 340, 24)] autorelease];
    [name setStringValue:[text length] > 30 ? [text substringToIndex:30] : text];
    [[panel contentView] addSubview:name];
    {
        NSButton *ok = button(@"Save", NSMakeRect(280, 12, 80, 30), self, @selector(promptNameOK:));
        NSButton *cancel = button(@"Cancel", NSMakeRect(190, 12, 80, 30), self, @selector(promptNameCancel:));
        [ok setKeyEquivalent:@"\r"];
        [cancel setKeyEquivalent:@"\033"];
        [[panel contentView] addSubview:ok];
        [[panel contentView] addSubview:cancel];
    }
    [panel center];
    [panel makeFirstResponder:name];
    [panel setLevel:NSFloatingWindowLevel];
    result = [NSApp runModalForWindow:panel];
    [panel orderOut:nil];
    if (result == 1 && [TBTrim([name stringValue]) length]) {
        NSMutableArray *list = [self savedPrompts];
        [list addObject:[NSDictionary dictionaryWithObjectsAndKeys:TBTrim([name stringValue]), @"name", text, @"text", nil]];
        [self storePrompts:list];
    }
    [panel release];
}

/* the manager: a list of prompts, each with a name, its text and an optional time to run by itself */

- (void)promptsPick:(id)sender { (void)sender; [self promptsStoreFields]; promptsAt = [promptsList indexOfSelectedItem]; [self promptsShowFields]; }

- (void)promptsShowFields
{
    NSArray *list = promptsEditing;
    NSDictionary *p = promptsAt >= 0 && promptsAt < (int)[list count] ? [list objectAtIndex:promptsAt] : nil;
    [promptsName setStringValue:p ? [p objectForKey:@"name"] : @""];
    [promptsText setString:p ? [p objectForKey:@"text"] : @""];
    [promptsRun setState:[[p objectForKey:@"auto"] boolValue] ? NSOnState : NSOffState];
    [promptsHour setStringValue:[NSString stringWithFormat:@"%d", p ? [[p objectForKey:@"hour"] intValue] : 9]];
    [promptsMinute setStringValue:[NSString stringWithFormat:@"%02d", p ? [[p objectForKey:@"minute"] intValue] : 0]];
    [promptsDays selectItemAtIndex:p ? [[p objectForKey:@"days"] intValue] : 0];
    [promptsName setEnabled:p != nil];
}

- (void)promptsStoreFields
{
    NSMutableDictionary *p;
    if (promptsAt < 0 || promptsAt >= (int)[promptsEditing count])
        return;
    p = [promptsEditing objectAtIndex:promptsAt];
    [p setObject:[TBTrim([promptsName stringValue]) length] ? TBTrim([promptsName stringValue]) : @"Prompt" forKey:@"name"];
    [p setObject:[promptsText string] forKey:@"text"];
    [p setObject:[NSNumber numberWithBool:[promptsRun state] == NSOnState] forKey:@"auto"];
    [p setObject:[NSNumber numberWithInt:MAX(0, MIN(23, [promptsHour intValue]))] forKey:@"hour"];
    [p setObject:[NSNumber numberWithInt:MAX(0, MIN(59, [promptsMinute intValue]))] forKey:@"minute"];
    [p setObject:[NSNumber numberWithInt:[promptsDays indexOfSelectedItem]] forKey:@"days"];
}

- (void)promptsRefillList
{
    unsigned i;
    [promptsList removeAllItems];
    for (i = 0; i < [promptsEditing count]; i++)
        [promptsList addItemWithTitle:[[promptsEditing objectAtIndex:i] objectForKey:@"name"]];
    if (promptsAt >= 0 && promptsAt < (int)[promptsEditing count])
        [promptsList selectItemAtIndex:promptsAt];
}

- (void)promptsNew:(id)sender
{
    (void)sender;
    [self promptsStoreFields];
    [promptsEditing addObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:@"New prompt", @"name", @"", @"text", nil]];
    promptsAt = (int)[promptsEditing count] - 1;
    [self promptsRefillList];
    [self promptsShowFields];
}

- (void)promptsDelete:(id)sender
{
    (void)sender;
    if (promptsAt < 0 || promptsAt >= (int)[promptsEditing count])
        return;
    [promptsEditing removeObjectAtIndex:promptsAt];
    promptsAt = [promptsEditing count] ? 0 : -1;
    [self promptsRefillList];
    [self promptsShowFields];
}

- (void)promptsDone:(id)sender { (void)sender; [NSApp stopModalWithCode:1]; }

- (void)managePrompts:(id)sender
{
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 520, 420) styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
    NSView *v = [panel contentView];
    NSScrollView *scroll;
    (void)sender;
    [panel setTitle:@"Prompts"];
    promptsEditing = [[self savedPrompts] retain];
    promptsAt = [promptsEditing count] ? 0 : -1;
    promptsList = [[[NSPopUpButton alloc] initWithFrame:NSMakeRect(20, 382, 300, 26) pullsDown:NO] autorelease];
    [promptsList setTarget:self];
    [promptsList setAction:@selector(promptsPick:)];
    [v addSubview:promptsList];
    [v addSubview:button(@"New", NSMakeRect(330, 380, 80, 30), self, @selector(promptsNew:))];
    [v addSubview:button(@"Delete", NSMakeRect(420, 380, 80, 30), self, @selector(promptsDelete:))];
    [v addSubview:label(@"Name", NSMakeRect(20, 352, 60, 18), NO)];
    promptsName = [[[NSTextField alloc] initWithFrame:NSMakeRect(80, 348, 420, 24)] autorelease];
    [v addSubview:promptsName];
    scroll = textArea(NSMakeRect(20, 150, 480, 190), &promptsText);
    [v addSubview:scroll];
    promptsRun = [[[NSButton alloc] initWithFrame:NSMakeRect(20, 112, 200, 22)] autorelease];
    [promptsRun setButtonType:NSSwitchButton];
    [promptsRun setTitle:@"Run by itself at"];
    [v addSubview:promptsRun];
    promptsHour = [[[NSTextField alloc] initWithFrame:NSMakeRect(150, 112, 36, 22)] autorelease];
    promptsMinute = [[[NSTextField alloc] initWithFrame:NSMakeRect(196, 112, 36, 22)] autorelease];
    [v addSubview:promptsHour];
    [v addSubview:label(@":", NSMakeRect(188, 114, 8, 18), NO)];
    [v addSubview:promptsMinute];
    promptsDays = [[[NSPopUpButton alloc] initWithFrame:NSMakeRect(246, 108, 150, 26) pullsDown:NO] autorelease];
    [promptsDays addItemsWithTitles:[NSArray arrayWithObjects:@"every day", @"weekdays", @"Mondays", @"Tuesdays", @"Wednesdays", @"Thursdays", @"Fridays", @"Saturdays", @"Sundays", nil]];
    [v addSubview:promptsDays];
    {
        NSTextField *note = label(@"A prompt set to run by itself starts a new chat and sends it at that time, while Tiger Build is open. It uses the model new chats start with, so tools that ask first will wait for you.", NSMakeRect(20, 52, 480, 48), NO);
        [note setFont:[NSFont systemFontOfSize:11]];
        [[note cell] setWraps:YES];
        [v addSubview:note];
    }
    {
        NSButton *done = button(@"Done", NSMakeRect(420, 12, 80, 30), self, @selector(promptsDone:));
        [done setKeyEquivalent:@"\r"];
        [v addSubview:done];
    }
    [self promptsRefillList];
    [self promptsShowFields];
    [panel center];
    [panel setLevel:NSFloatingWindowLevel];
    [NSApp runModalForWindow:panel];
    [panel orderOut:nil];
    [self promptsStoreFields];
    [self storePrompts:promptsEditing];
    [promptsEditing release];
    promptsEditing = nil;
    [panel release];
}

/* the clock: once a minute, prompts that are due run (each at most once a day) */

- (void)startScheduler
{
    if (schedulerTimer)
        return;
    schedulerTimer = [[NSTimer scheduledTimerWithTimeInterval:30 target:self selector:@selector(schedulerTick:) userInfo:nil repeats:YES] retain];
}

- (void)schedulerTick:(NSTimer *)timer
{
    NSArray *list = [self savedPrompts];
    NSCalendarDate *now = [NSCalendarDate calendarDate];
    NSString *today = dayKey2();
    NSMutableDictionary *done = [NSMutableDictionary dictionaryWithDictionary:[[NSUserDefaults standardUserDefaults] dictionaryForKey:@"TBPromptsRan"]];
    unsigned i;
    BOOL changed = NO;
    (void)timer;
    if (locked)
        return;
    for (i = 0; i < [list count]; i++) {
        NSDictionary *p = [list objectAtIndex:i];
        int days = [[p objectForKey:@"days"] intValue], weekday = (int)[now dayOfWeek];   /* 0 Sunday */
        NSString *key = [p objectForKey:@"name"];
        BOOL dayOK = days == 0 || (days == 1 && weekday >= 1 && weekday <= 5) || (days >= 2 && days <= 8 && weekday == (days - 1) % 7);
        int minutes = (int)[now hourOfDay] * 60 + (int)[now minuteOfHour], at = [[p objectForKey:@"hour"] intValue] * 60 + [[p objectForKey:@"minute"] intValue];
        if (![[p objectForKey:@"auto"] boolValue] || !dayOK || minutes < at || minutes > at + 10 || [[done objectForKey:key] isEqualToString:today])
            continue;
        [done setObject:today forKey:key];
        changed = YES;
        [self askInNewChat:[p objectForKey:@"text"] send:YES];
        break;   /* one at a time */
    }
    if (changed)
        [[NSUserDefaults standardUserDefaults] setObject:done forKey:@"TBPromptsRan"];
}

/* ---- the Services menu entry and Quick Ask ---- */

/* Services: "Ask Tiger Build" with the selected text; it goes into a new chat's message box, to add a question and send */
- (void)askTigerBuild:(NSPasteboard *)pboard userData:(NSString *)userData error:(NSString **)error
{
    NSString *text = [pboard stringForType:NSStringPboardType];
    (void)userData;
    if ([text length] == 0) {
        *error = @"There was no text to send.";
        return;
    }
    if ([text length] > 100000)
        text = [text substringToIndex:100000];
    [self askInNewChat:[text stringByAppendingString:@"\n\n"] send:NO];
}

- (void)quickAskOK:(id)sender { (void)sender; [NSApp stopModalWithCode:1]; }
- (void)quickAskCancel:(id)sender { (void)sender; [NSApp stopModalWithCode:0]; }

- (void)quickAsk:(id)sender
{
    NSPanel *panel;
    NSTextField *field;
    int result;
    (void)sender;
    if (quickAskOpen)
        return;
    quickAskOpen = YES;
    panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 520, 96) styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
    [panel setTitle:@"Quick Ask"];
    field = [[[NSTextField alloc] initWithFrame:NSMakeRect(20, 52, 480, 24)] autorelease];
    [[field cell] setPlaceholderString:@"Ask anything: Return sends it in a new chat"];
    [[panel contentView] addSubview:field];
    {
        NSButton *ok = button(@"Ask", NSMakeRect(420, 10, 80, 30), self, @selector(quickAskOK:));
        NSButton *cancel = button(@"Cancel", NSMakeRect(330, 10, 80, 30), self, @selector(quickAskCancel:));
        [ok setKeyEquivalent:@"\r"];
        [cancel setKeyEquivalent:@"\033"];
        [[panel contentView] addSubview:ok];
        [[panel contentView] addSubview:cancel];
    }
    [panel center];
    [NSApp activateIgnoringOtherApps:YES];
    [panel makeFirstResponder:field];
    [panel setLevel:NSFloatingWindowLevel];
    result = [NSApp runModalForWindow:panel];
    [panel orderOut:nil];
    quickAskOpen = NO;
    if (result == 1 && [TBTrim([field stringValue]) length])
        [self askInNewChat:TBTrim([field stringValue]) send:YES];
    [panel release];
}

static OSStatus hotKeyHandler(EventHandlerCallRef next, EventRef event, void *context)
{
    [(ChatController *)context performSelectorOnMainThread:@selector(quickAsk:) withObject:nil waitUntilDone:NO];
    return noErr;
}

/* Control-Option-Space, while Tiger Build runs and the setting is on */
- (void)applyQuickAskHotKey
{
    BOOL want = [[NSUserDefaults standardUserDefaults] boolForKey:@"TBQuickAskKey"];
    if (want && !hotKeyRef) {
        EventTypeSpec spec = {kEventClassKeyboard, kEventHotKeyPressed};
        EventHotKeyID hid = {'TBQA', 1};
        InstallApplicationEventHandler(NewEventHandlerUPP(hotKeyHandler), 1, &spec, self, NULL);
        RegisterEventHotKey(49, controlKey | optionKey, hid, GetApplicationEventTarget(), 0, (EventHotKeyRef *)&hotKeyRef);
    } else if (!want && hotKeyRef) {
        UnregisterEventHotKey((EventHotKeyRef)hotKeyRef);
        hotKeyRef = NULL;
    }
}

/* ---- trying the last message with another model ---- */

- (void)compareOK:(id)sender { (void)sender; [NSApp stopModalWithCode:1]; }
- (void)compareCancel:(id)sender { (void)sender; [NSApp stopModalWithCode:0]; }

- (void)compareProviderChanged:(id)sender
{
    NSString *pid = [[compareProvider selectedItem] representedObject];
    NSArray *models = [pid isEqualToString:@"local"] ? nil : [[ModelCatalog shared] modelsForProvider:pid];
    unsigned i;
    (void)sender;
    [compareModel removeAllItems];
    if ([pid isEqualToString:@"local"]) {
        [compareModel addItemWithTitle:[self modelForChat:current]];
        [[compareModel lastItem] setRepresentedObject:[self modelForChat:current]];
        return;
    }
    for (i = 0; i < [models count]; i++) {
        [compareModel addItemWithTitle:[[models objectAtIndex:i] objectForKey:@"title"]];
        [[compareModel lastItem] setRepresentedObject:[[models objectAtIndex:i] objectForKey:@"id"]];
    }
}

- (void)tryWithAnotherModel:(id)sender
{
    NSPanel *panel;
    NSArray *providers = [[ModelCatalog shared] providers];
    NSArray *messages = [current objectForKey:@"messages"];
    NSMutableDictionary *copy;
    NSString *question = nil;
    unsigned i;
    int last = -1;
    int result;
    (void)sender;
    if (!current || busy)
        return;
    for (i = 0; i < [messages count]; i++)
        if ([[[messages objectAtIndex:i] objectForKey:@"role"] isEqualToString:@"user"] && [[[messages objectAtIndex:i] objectForKey:@"text"] length]
            && ![[messages objectAtIndex:i] objectForKey:@"attachment"] && ![[[messages objectAtIndex:i] objectForKey:@"status"] boolValue])
            last = (int)i;
    if (last < 0) {
        NSRunAlertPanel(@"Try with another model", @"This chat has no message of yours to send again.", @"OK", nil, nil);
        return;
    }
    question = [[messages objectAtIndex:last] objectForKey:@"text"];
    panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 420, 190) styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
    [panel setTitle:@"Try with Another Model"];
    [[panel contentView] addSubview:label(@"Send your last message again, in a new chat beside this one, to:", NSMakeRect(20, 150, 380, 18), NO)];
    compareProvider = [[[NSPopUpButton alloc] initWithFrame:NSMakeRect(20, 114, 380, 26) pullsDown:NO] autorelease];
    compareModel = [[[NSPopUpButton alloc] initWithFrame:NSMakeRect(20, 80, 380, 26) pullsDown:NO] autorelease];
    for (i = 0; i < [providers count]; i++) {
        NSString *pid = [[providers objectAtIndex:i] objectForKey:@"id"];
        if (![pid isEqualToString:@"local"] && [self providerNote:pid])
            continue;
        [compareProvider addItemWithTitle:[self providerMenuTitle:[providers objectAtIndex:i]]];
        [[compareProvider lastItem] setRepresentedObject:pid];
        if ([pid isEqualToString:[self providerForChat:current]])
            [compareProvider selectItemAtIndex:[compareProvider numberOfItems] - 1];
    }
    [compareProvider setTarget:self];
    [compareProvider setAction:@selector(compareProviderChanged:)];
    [[panel contentView] addSubview:compareProvider];
    [[panel contentView] addSubview:compareModel];
    [self compareProviderChanged:nil];
    {
        NSButton *ok = button(@"Send", NSMakeRect(320, 12, 80, 30), self, @selector(compareOK:));
        NSButton *cancel = button(@"Cancel", NSMakeRect(230, 12, 80, 30), self, @selector(compareCancel:));
        [ok setKeyEquivalent:@"\r"];
        [cancel setKeyEquivalent:@"\033"];
        [[panel contentView] addSubview:ok];
        [[panel contentView] addSubview:cancel];
    }
    [panel center];
    [panel setLevel:NSFloatingWindowLevel];
    result = [NSApp runModalForWindow:panel];
    [panel orderOut:nil];
    if (result == 1 && [compareProvider selectedItem] && [compareModel selectedItem]) {
        NSString *pid = [[compareProvider selectedItem] representedObject], *model = [[compareModel selectedItem] representedObject];
        NSMutableArray *kept;
        NSString *title = [current objectForKey:@"title"];
        NSData *data = [NSPropertyListSerialization dataFromPropertyList:current format:NSPropertyListBinaryFormat_v1_0 errorDescription:NULL];
        copy = [NSPropertyListSerialization propertyListFromData:data mutabilityOption:NSPropertyListMutableContainers format:NULL errorDescription:NULL];
        kept = [copy objectForKey:@"messages"];
        while ((int)[kept count] > last)
            [kept removeLastObject];
        [copy setObject:[NSString stringWithFormat:@"%@ (%@)", title ? title : @"Chat", [[compareModel selectedItem] title]] forKey:@"title"];
        [copy setObject:[NSNumber numberWithBool:NO] forKey:@"autoTitle"];
        [copy setObject:[NSString stringWithFormat:@"%d", [store takeNextId]] forKey:@"id"];
        [copy setObject:pid forKey:@"provider"];
        [copy setObject:model forKey:@"model"];
        [copy removeObjectForKey:@"ctxTokens"];
        [copy removeObjectForKey:@"ctxAt"];
        [copy removeObjectForKey:@"contextLimit"];
        [copy removeObjectForKey:@"usage"];
        [self forgetEdit];
        [chats insertObject:copy atIndex:0];
        [self saveStore];
        [self reloadTableSelect:0 show:YES];
        [input setStringValue:question];
        [self performSelector:@selector(send:) withObject:nil afterDelay:0.4];
    }
    compareProvider = nil;
    compareModel = nil;
    [panel release];
}

/* ---- the cost report ---- */

- (void)showCostReport:(id)sender
{
    NSMutableDictionary *byModel = [NSMutableDictionary dictionary];
    NSMutableArray *byChat = [NSMutableArray array];
    NSMutableString *out = [NSMutableString string];
    NSDictionary *daily = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"TBSpendDaily"];
    double total = 0, week = 0, month = 0;
    unsigned i, k;
    NSArray *keys;
    NSPanel *panel;
    NSTextView *view;
    (void)sender;
    for (i = 0; i < [chats count]; i++) {
        NSDictionary *chat = [chats objectAtIndex:i], *usage = [chat objectForKey:@"usage"];
        NSEnumerator *e;
        NSString *key;
        double chatTotal = 0;
        if (![usage isKindOfClass:[NSDictionary class]])
            continue;
        e = [usage keyEnumerator];
        while ((key = [e nextObject])) {
            NSDictionary *row = [usage objectForKey:key];
            NSMutableDictionary *m = [byModel objectForKey:key];
            double cost = [[row objectForKey:@"cost"] doubleValue];
            if (!m) {
                m = [NSMutableDictionary dictionary];
                [byModel setObject:m forKey:key];
            }
            [m setObject:[NSNumber numberWithDouble:[[m objectForKey:@"cost"] doubleValue] + cost] forKey:@"cost"];
            [m setObject:[NSNumber numberWithLongLong:[[m objectForKey:@"in"] longLongValue] + [[row objectForKey:@"input"] intValue] + [[row objectForKey:@"cached"] intValue] + [[row objectForKey:@"written"] intValue]] forKey:@"in"];
            [m setObject:[NSNumber numberWithLongLong:[[m objectForKey:@"out"] longLongValue] + [[row objectForKey:@"output"] intValue]] forKey:@"out"];
            [m setObject:[NSNumber numberWithInt:[[m objectForKey:@"calls"] intValue] + [[row objectForKey:@"calls"] intValue]] forKey:@"calls"];
            chatTotal += cost;
            total += cost;
        }
        if (chatTotal > 0)
            [byChat addObject:[NSDictionary dictionaryWithObjectsAndKeys:[chat objectForKey:@"title"] ? [chat objectForKey:@"title"] : @"Chat", @"title", [NSNumber numberWithDouble:chatTotal], @"cost", nil]];
    }
    keys = [daily allKeys];
    {
        NSString *today = dayKey2();
        NSCalendarDate *now = [NSCalendarDate calendarDate];
        for (k = 0; k < [keys count]; k++) {
            NSCalendarDate *d = [NSCalendarDate dateWithString:[[keys objectAtIndex:k] stringByAppendingString:@" 12:00:00"] calendarFormat:@"%Y-%m-%d %H:%M:%S"];
            double age = d ? [now timeIntervalSinceDate:d] / 86400.0 : 9999;
            double v = [[daily objectForKey:[keys objectAtIndex:k]] doubleValue];
            if (age <= 7.5) week += v;
            if (age <= 31) month += v;
        }
        (void)today;
    }
    [out appendFormat:@"Workspace \"%@\", estimates from token counts and published prices; not an invoice.\n\n", [self workspaceName]];
    [out appendFormat:@"All chats here: %@\nLast 7 days (all workspaces): %@\nLast 30 days (all workspaces): %@\nToday: %@\n\n", TBFormatCost(total), TBFormatCost(week), TBFormatCost(month), TBFormatCost([self spendToday])];
    [out appendString:@"By model\n"];
    {
        NSMutableArray *rows = [NSMutableArray array];
        NSEnumerator *e = [byModel keyEnumerator];
        NSString *key;
        while ((key = [e nextObject]))
            [rows addObject:[NSDictionary dictionaryWithObjectsAndKeys:key, @"key", [[byModel objectForKey:key] objectForKey:@"cost"], @"cost", nil]];
        [rows sortUsingDescriptors:[NSArray arrayWithObject:[[[NSSortDescriptor alloc] initWithKey:@"cost" ascending:NO] autorelease]]];
        keys = [rows valueForKey:@"key"];
    }
    for (k = 0; k < [keys count]; k++) {
        NSDictionary *m = [byModel objectForKey:[keys objectAtIndex:k]];
        NSString *name = [[[keys objectAtIndex:k] componentsSeparatedByString:@"|"] lastObject];
        [out appendFormat:@"  %@: %@ (%lld in, %lld out tokens, %d calls)\n", name, TBFormatCost([[m objectForKey:@"cost"] doubleValue]), [[m objectForKey:@"in"] longLongValue], [[m objectForKey:@"out"] longLongValue], [[m objectForKey:@"calls"] intValue]];
    }
    [byChat sortUsingDescriptors:[NSArray arrayWithObject:[[[NSSortDescriptor alloc] initWithKey:@"cost" ascending:NO] autorelease]]];
    [out appendString:@"\nMost expensive chats\n"];
    for (k = 0; k < [byChat count] && k < 10; k++)
        [out appendFormat:@"  %@: %@\n", [[byChat objectAtIndex:k] objectForKey:@"title"], TBFormatCost([[[byChat objectAtIndex:k] objectForKey:@"cost"] doubleValue])];
    if (![byModel count])
        [out appendString:@"  (no usage yet)\n"];
    panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 520, 440) styleMask:NSTitledWindowMask | NSClosableWindowMask | NSResizableWindowMask backing:NSBackingStoreBuffered defer:NO];
    [panel setTitle:@"Cost Report"];
    [[panel contentView] addSubview:textArea(NSMakeRect(20, 56, 480, 364), &view)];
    [view setEditable:NO];
    [view setString:out];
    [view setFont:[NSFont userFixedPitchFontOfSize:11]];
    {
        NSButton *done = button(@"Done", NSMakeRect(420, 14, 80, 30), self, @selector(promptsDone:));
        [done setKeyEquivalent:@"\r"];
        [[panel contentView] addSubview:done];
    }
    [panel center];
    [panel setLevel:NSFloatingWindowLevel];
    [NSApp runModalForWindow:panel];
    [panel orderOut:nil];
    [panel release];
}

/* ---- importing a ChatGPT or Claude export ---- */

static NSString *plainText(id v)
{
    if ([v isKindOfClass:[NSString class]])
        return v;
    if ([v isKindOfClass:[NSArray class]]) {
        NSMutableArray *parts = [NSMutableArray array];
        unsigned i;
        for (i = 0; i < [v count]; i++) {
            NSString *s = plainText([v objectAtIndex:i]);
            if ([s length])
                [parts addObject:s];
        }
        return [parts componentsJoinedByString:@"\n"];
    }
    if ([v isKindOfClass:[NSDictionary class]]) {
        if ([[v objectForKey:@"text"] isKindOfClass:[NSString class]])
            return [v objectForKey:@"text"];
        if ([v objectForKey:@"parts"])
            return plainText([v objectForKey:@"parts"]);
        if ([[v objectForKey:@"content"] isKindOfClass:[NSString class]])
            return [v objectForKey:@"content"];
    }
    return @"";
}

/* ChatGPT: each conversation has a "mapping" of nodes and a "current_node"; the visible thread is found by walking parents from there */
static NSArray *chatGPTMessages(NSDictionary *conversation)
{
    NSDictionary *mapping = [conversation objectForKey:@"mapping"];
    NSString *node = [conversation objectForKey:@"current_node"];
    NSMutableArray *reversed = [NSMutableArray array];
    int guard = 0;
    unsigned i;
    NSMutableArray *out = [NSMutableArray array];
    if (![mapping isKindOfClass:[NSDictionary class]])
        return out;
    while ([node isKindOfClass:[NSString class]] && guard++ < 5000) {
        NSDictionary *entry = [mapping objectForKey:node];
        NSDictionary *message = [entry isKindOfClass:[NSDictionary class]] ? [entry objectForKey:@"message"] : nil;
        NSDictionary *author;
        NSString *role, *text;
        if (![message isKindOfClass:[NSDictionary class]]) {
            node = [entry isKindOfClass:[NSDictionary class]] ? [entry objectForKey:@"parent"] : nil;
            continue;
        }
        author = [message objectForKey:@"author"];
        role = [author isKindOfClass:[NSDictionary class]] ? [author objectForKey:@"role"] : nil;
        text = plainText([message objectForKey:@"content"]);
        if (([role isEqualToString:@"user"] || [role isEqualToString:@"assistant"]) && [TBTrim(text) length])
            [reversed addObject:[NSDictionary dictionaryWithObjectsAndKeys:role, @"role", text, @"text", nil]];
        node = [entry objectForKey:@"parent"];
    }
    for (i = (unsigned)[reversed count]; i > 0; i--)
        [out addObject:[reversed objectAtIndex:i - 1]];
    return out;
}

/* Claude: "chat_messages" with "sender" human or assistant */
static NSArray *claudeMessages(NSDictionary *conversation)
{
    NSArray *list = [conversation objectForKey:@"chat_messages"];
    NSMutableArray *out = [NSMutableArray array];
    unsigned i;
    if (![list isKindOfClass:[NSArray class]])
        return out;
    for (i = 0; i < [list count]; i++) {
        NSDictionary *m = [list objectAtIndex:i];
        NSString *sender, *text;
        if (![m isKindOfClass:[NSDictionary class]])
            continue;
        sender = [m objectForKey:@"sender"];
        text = plainText([m objectForKey:@"text"]);
        if (![text length])
            text = plainText([m objectForKey:@"content"]);
        if (([sender isEqualToString:@"human"] || [sender isEqualToString:@"assistant"]) && [TBTrim(text) length])
            [out addObject:[NSDictionary dictionaryWithObjectsAndKeys:[sender isEqualToString:@"human"] ? @"user" : @"assistant", @"role", text, @"text", nil]];
    }
    return out;
}

- (void)importOtherExport:(id)sender
{
    NSOpenPanel *open = [NSOpenPanel openPanel];
    NSData *data;
    id parsed;
    NSString *error = nil, *path;
    unsigned i, added = 0;
    (void)sender;
    if (busy)
        return;
    [open setMessage:@"Choose the export you downloaded from ChatGPT or Claude (the .zip, or the conversations.json inside it)."];
    [open setAllowsMultipleSelection:NO];
    if ([open runModalForDirectory:[@"~/Downloads" stringByExpandingTildeInPath] file:nil types:[NSArray arrayWithObjects:@"zip", @"json", nil]] != NSOKButton)
        return;
    path = [[open filenames] objectAtIndex:0];
    data = [NSData dataWithContentsOfFile:path];
    if (!data || [data length] > 600 * 1024 * 1024) {
        NSRunAlertPanel(@"Import", @"That file could not be read, or is larger than 600 MB.", @"OK", nil, nil);
        return;
    }
    if ([[[path pathExtension] lowercaseString] isEqualToString:@"zip"]) {
        TBZip *zip = [TBZip zipWithData:data];
        data = nil;
        @try {
            data = [zip has:@"conversations.json"] ? [zip dataFor:@"conversations.json"] : nil;
        } @catch (NSException *e) {
            error = [e reason];
        }
        if (!data) {
            NSRunAlertPanel(@"Import", @"%@", @"OK", nil, nil, error ? error : @"There is no conversations.json in that zip file.");
            return;
        }
    }
    parsed = TBJSONParse(data, NULL);
    if (![parsed isKindOfClass:[NSArray class]] || ![parsed count]) {
        NSRunAlertPanel(@"Import", @"That does not look like a ChatGPT or Claude export (a list of conversations).", @"OK", nil, nil);
        return;
    }
    if (NSRunAlertPanel(@"Import conversations?", @"%u conversations will be added to the workspace \"%@\" as chats. Nothing is sent anywhere, and they are only text (no pictures or files).",
        @"Import", @"Cancel", nil, (unsigned)[parsed count], [self workspaceName]) != NSAlertDefaultReturn)
        return;
    for (i = 0; i < [parsed count] && i < 3000; i++) {
        NSDictionary *c = [parsed objectAtIndex:i];
        NSArray *list;
        NSMutableDictionary *chat;
        NSMutableArray *messages;
        NSString *title;
        unsigned m;
        if (![c isKindOfClass:[NSDictionary class]])
            continue;
        list = [c objectForKey:@"mapping"] ? chatGPTMessages(c) : claudeMessages(c);
        if (![list count])
            continue;
        chat = [self blankChat];
        messages = [chat objectForKey:@"messages"];
        [messages removeAllObjects];
        for (m = 0; m < [list count]; m++) {
            NSString *text = [[list objectAtIndex:m] objectForKey:@"text"];
            if ([text length] > 200000)
                text = [text substringToIndex:200000];
            [messages addObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:[[list objectAtIndex:m] objectForKey:@"role"], @"role", text, @"text", [NSNumber numberWithBool:NO], @"status", nil]];
        }
        title = [c objectForKey:@"title"];
        if (![title isKindOfClass:[NSString class]] || ![title length])
            title = [c objectForKey:@"name"];
        if (![title isKindOfClass:[NSString class]] || ![title length])
            title = @"Imported chat";
        if ([title length] > 80)
            title = [title substringToIndex:80];
        [chat setObject:title forKey:@"title"];
        [chat setObject:[NSNumber numberWithBool:NO] forKey:@"autoTitle"];
        [chats addObject:chat];
        added++;
    }
    [self saveStore];
    [self reloadTableSelect:0 show:YES];
    NSRunAlertPanel(@"Import finished", @"%u chats were added at the end of the chat list.", @"OK", nil, nil, added);
}

/* ---- the lock ---- */

static NSString *hashPassword(NSString *password, NSString *salt)
{
    unsigned char digest[32];
    NSData *in = [[salt stringByAppendingString:password] dataUsingEncoding:NSUTF8StringEncoding];
    int i;
    NSMutableString *out = [NSMutableString string];
    unsigned char block[32];
    mbedtls_sha256([in bytes], [in length], block, 0);
    /* a few thousand rounds slow a guesser down a little */
    for (i = 0; i < 20000; i++) {
        mbedtls_sha256(block, 32, digest, 0);
        memcpy(block, digest, 32);
    }
    for (i = 0; i < 32; i++)
        [out appendFormat:@"%02x", block[i]];
    return out;
}

- (BOOL)lockPasswordIsSet { return [TBSettings hasValueForName:@"lock_hash"]; }

- (void)lockOK:(id)sender { (void)sender; [NSApp stopModalWithCode:1]; }
- (void)lockCancel:(id)sender { (void)sender; [NSApp stopModalWithCode:0]; }

- (void)setLockPassword:(id)sender
{
    NSPanel *panel;
    NSSecureTextField *one, *two;
    int result;
    (void)sender;
    if ([self lockPasswordIsSet]) {
        if (!locked) {
            NSString *typed = [self askLockPassword:@"Type the current lock password."];
            if (!typed || ![self lockPasswordMatches:typed])
                return;
        }
    }
    panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 380, 190) styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
    [panel setTitle:@"Lock Password"];
    [[panel contentView] addSubview:label(@"New password (leave empty to remove the lock):", NSMakeRect(20, 154, 340, 18), NO)];
    one = [[[NSSecureTextField alloc] initWithFrame:NSMakeRect(20, 124, 340, 24)] autorelease];
    [[panel contentView] addSubview:one];
    [[panel contentView] addSubview:label(@"Again:", NSMakeRect(20, 96, 340, 18), NO)];
    two = [[[NSSecureTextField alloc] initWithFrame:NSMakeRect(20, 66, 340, 24)] autorelease];
    [[panel contentView] addSubview:two];
    [[panel contentView] addSubview:label(@"A reminder cannot be recovered: if the password is lost, delete the Tiger Build Keychain item to remove the lock.", NSMakeRect(20, 28, 340, 32), NO)];
    [[[[panel contentView] subviews] lastObject] setFont:[NSFont systemFontOfSize:10]];
    {
        NSButton *ok = button(@"Save", NSMakeRect(290, 4, 70, 26), self, @selector(lockOK:));
        NSButton *cancel = button(@"Cancel", NSMakeRect(210, 4, 70, 26), self, @selector(lockCancel:));
        [ok setKeyEquivalent:@"\r"];
        [cancel setKeyEquivalent:@"\033"];
        [[panel contentView] addSubview:ok];
        [[panel contentView] addSubview:cancel];
    }
    [panel center];
    [panel makeFirstResponder:one];
    [panel setLevel:NSFloatingWindowLevel];
    result = [NSApp runModalForWindow:panel];
    [panel orderOut:nil];
    if (result == 1) {
        NSString *a = [one stringValue], *b = [two stringValue];
        if (![a isEqualToString:b])
            NSRunAlertPanel(@"Lock password", @"The two passwords are not the same, so nothing was changed.", @"OK", nil, nil);
        else if ([a length] == 0)
            [TBSettings clearName:@"lock_hash"];
        else {
            NSString *salt = [NSString stringWithFormat:@"%08x%08x", arc4random(), arc4random()];
            [TBSettings setValue:[NSString stringWithFormat:@"%@$%@", salt, hashPassword(a, salt)] forName:@"lock_hash"];
        }
    }
    [panel release];
}

- (BOOL)lockPasswordMatches:(NSString *)typed
{
    NSString *stored = [TBSettings valueForName:@"lock_hash"];
    NSRange dollar = [stored rangeOfString:@"$"];
    if (dollar.location == NSNotFound)
        return NO;
    return [[stored substringFromIndex:dollar.location + 1] isEqualToString:hashPassword(typed, [stored substringToIndex:dollar.location])];
}

- (NSString *)askLockPassword:(NSString *)message
{
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 340, 130) styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
    NSSecureTextField *field = [[[NSSecureTextField alloc] initWithFrame:NSMakeRect(20, 56, 300, 24)] autorelease];
    NSString *result = nil;
    [panel setTitle:@"Tiger Build"];
    [[panel contentView] addSubview:label(message, NSMakeRect(20, 92, 300, 18), NO)];
    [[panel contentView] addSubview:field];
    {
        NSButton *ok = button(@"OK", NSMakeRect(250, 14, 70, 28), self, @selector(lockOK:));
        NSButton *cancel = button(@"Cancel", NSMakeRect(170, 14, 70, 28), self, @selector(lockCancel:));
        [ok setKeyEquivalent:@"\r"];
        [[panel contentView] addSubview:ok];
        if (!locked) {
            [cancel setKeyEquivalent:@"\033"];
            [[panel contentView] addSubview:cancel];
        }
    }
    [panel center];
    [NSApp activateIgnoringOtherApps:YES];
    [panel makeFirstResponder:field];
    [panel setLevel:NSModalPanelWindowLevel];
    if ([NSApp runModalForWindow:panel] == 1)
        result = [[[field stringValue] copy] autorelease];
    [panel orderOut:nil];
    [panel release];
    return result;
}

/* Hides every window and asks for the password until it is right. Replies that are running go on. */
- (void)lockNow:(id)sender
{
    NSArray *all;
    unsigned i;
    (void)sender;
    if (locked)
        return;
    if (![self lockPasswordIsSet]) {
        NSRunAlertPanel(@"Lock Tiger Build", @"Set a lock password first: Preferences, Privacy, Set Lock Password.", @"OK", nil, nil);
        return;
    }
    locked = YES;
    /* a solid sheet over every screen's whole area (the Dock and menu bar too) hides the chats; the windows themselves are not closed or hidden */
    {
        NSArray *screens = [NSScreen screens];
        unsigned k;
        lockCovers = [[NSMutableArray alloc] init];
        (void)all; (void)i;
        for (k = 0; k < [screens count]; k++) {
            NSWindow *cover = [[(k == 0 ? [TBLockWindow class] : [NSWindow class]) alloc] initWithContentRect:[[screens objectAtIndex:k] frame] styleMask:NSBorderlessWindowMask backing:NSBackingStoreBuffered defer:NO];
            [cover setLevel:NSScreenSaverWindowLevel];
            [cover setBackgroundColor:[NSColor colorWithCalibratedWhite:0.12f alpha:1]];
            [cover setOpaque:YES];
            [cover setReleasedWhenClosed:NO];
            [cover setHasShadow:NO];
            [cover orderFrontRegardless];
            [lockCovers addObject:cover];
            [cover release];
        }
    }
    [self performSelector:@selector(askToUnlock) withObject:nil afterDelay:0.1 inModes:[NSArray arrayWithObjects:NSDefaultRunLoopMode, NSModalPanelRunLoopMode, NSEventTrackingRunLoopMode, nil]];
}

- (void)lockEnter:(id)sender { (void)sender; [NSApp stopModalWithCode:1]; }

- (void)askToUnlock
{
    NSWindow *cover = [lockCovers count] ? [lockCovers objectAtIndex:0] : nil;
    NSView *v = [cover contentView];
    NSSize size = [v bounds].size;
    NSTextField *title, *message;
    NSSecureTextField *field;
    NSButton *go;
    if (!cover)
        return;
    title = label(@"Tiger Build is locked", NSMakeRect(size.width / 2 - 200, size.height / 2 + 40, 400, 24), YES);
    [title setFont:[NSFont boldSystemFontOfSize:18]];
    [title setTextColor:[NSColor whiteColor]];
    [title setAlignment:NSCenterTextAlignment];
    message = label(@"Type the password and press Return.", NSMakeRect(size.width / 2 - 200, size.height / 2 + 12, 400, 18), NO);
    [message setTextColor:[NSColor lightGrayColor]];
    [message setAlignment:NSCenterTextAlignment];
    field = [[[NSSecureTextField alloc] initWithFrame:NSMakeRect(size.width / 2 - 130, size.height / 2 - 24, 260, 26)] autorelease];
    go = button(@"Unlock", NSMakeRect(size.width / 2 - 45, size.height / 2 - 66, 90, 30), self, @selector(lockEnter:));
    [go setKeyEquivalent:@"\r"];
    [v addSubview:title];
    [v addSubview:message];
    [v addSubview:field];
    [v addSubview:go];
    [NSApp activateIgnoringOtherApps:YES];
    [cover makeKeyAndOrderFront:nil];
    [cover makeFirstResponder:field];
    for (;;) {
        [field setStringValue:@""];
        [cover makeFirstResponder:field];
        [NSApp runModalForWindow:cover];
        if ([self lockPasswordMatches:[field stringValue]])
            break;
        [message setStringValue:@"That is not the password. Try again."];
        [message setTextColor:[NSColor colorWithCalibratedRed:1 green:0.55f blue:0.5f alpha:1]];
        usleep(700000);
    }
    locked = NO;
    [lockCovers makeObjectsPerformSelector:@selector(orderOut:) withObject:nil];
    [lockCovers release];
    lockCovers = nil;
    lastActivity = [NSDate timeIntervalSinceReferenceDate];
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

/* the lock when Tiger Build starts, and after some idle minutes */
- (void)lockIfWantedAtStart
{
    if ([self lockPasswordIsSet] && [[NSUserDefaults standardUserDefaults] boolForKey:@"TBLockAtStart"])
        [self lockNow:nil];
}

- (void)lockIdleTick:(NSTimer *)timer
{
    int minutes = (int)[[NSUserDefaults standardUserDefaults] integerForKey:@"TBLockIdleMinutes"];
    (void)timer;
    if (locked || minutes <= 0 || ![self lockPasswordIsSet] || [self anyRunActive])
        return;
    if ([NSDate timeIntervalSinceReferenceDate] - lastActivity > minutes * 60.0 && ![NSApp isActive])
        [self lockNow:nil];
}

- (void)noteActivity
{
    lastActivity = [NSDate timeIntervalSinceReferenceDate];
}

- (void)startLockWatcher
{
    if (lockTimer)
        return;
    lastActivity = [NSDate timeIntervalSinceReferenceDate];
    lockTimer = [[NSTimer scheduledTimerWithTimeInterval:20 target:self selector:@selector(lockIdleTick:) userInfo:nil repeats:YES] retain];
}

- (BOOL)isLocked { return locked; }

@end
