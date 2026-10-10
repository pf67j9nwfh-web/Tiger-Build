#import "ChatController_Private.h"
#import "TBSkills.h"
#import "TBEngine.h"

/* Chat, Skills...: the list of skills with a switch for each; New, Edit, From This Chat (the chat's model drafts a skill from the conversation), Import Folder, Delete and Show in Finder. */

#if MAC_OS_X_VERSION_MAX_ALLOWED >= 1060
@interface TBSkillsWindow : NSObject <NSTableViewDataSource> {
#else
@interface TBSkillsWindow : NSObject {
#endif
    NSWindow *window;
    NSTableView *table;
    NSArray *rows;
    ChatController *owner;
    NSTextField *status;
}
+ (void)showFor:(ChatController *)controller;
- (void)openEditorWithName:(NSString *)name description:(NSString *)description body:(NSString *)body folder:(NSString *)folder;
- (void)setStatus:(NSString *)text;
@end

static TBSkillsWindow *shared = nil;

@implementation TBSkillsWindow

- (void)reload
{
    [rows release];
    rows = [[TBSkills all] retain];
    [table reloadData];
}

- (id)init
{
    NSTableColumn *on, *name;
    NSScrollView *scroll;
    NSArray *titles = [NSArray arrayWithObjects:@"New...", @"Edit...", @"From This Chat...", @"Import Folder...", @"Delete", @"Show in Finder", nil];
    SEL actions[6] = { @selector(newSkill:), @selector(editSkill:), @selector(fromChat:), @selector(importFolder:), @selector(deleteSkill:), @selector(reveal:) };
    NSTextField *help;
    int i;
    self = [super init];
    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 360) styleMask:NSTitledWindowMask | NSClosableWindowMask backing:NSBackingStoreBuffered defer:NO];
    [window setTitle:@"Skills"];
    [window setReleasedWhenClosed:NO];
    help = [[[NSTextField alloc] initWithFrame:NSMakeRect(20, 312, 600, 38)] autorelease];
    [help setStringValue:@"A skill is a folder with a SKILL.md file: instructions for one kind of task. The model sees each skill's name and description, and loads one when the task fits."];
    [help setBezeled:NO]; [help setDrawsBackground:NO]; [help setEditable:NO]; [help setSelectable:NO];
    [[window contentView] addSubview:help];
    scroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(20, 84, 600, 220)] autorelease];
    [scroll setHasVerticalScroller:YES]; [scroll setBorderType:NSBezelBorder];
    table = [[[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 580, 220)] autorelease];
    on = [[[NSTableColumn alloc] initWithIdentifier:@"on"] autorelease];
    [on setWidth:26];
    {
        NSButtonCell *cell = [[[NSButtonCell alloc] init] autorelease];
        [cell setButtonType:NSSwitchButton]; [cell setTitle:@""];
        [on setDataCell:cell];
    }
    name = [[[NSTableColumn alloc] initWithIdentifier:@"name"] autorelease];
    [name setWidth:550];
    [[name headerCell] setStringValue:@"Skill"];
    [[on headerCell] setStringValue:@""];
    [table addTableColumn:on]; [table addTableColumn:name];
    [table setDataSource:self];
    [scroll setDocumentView:table];
    [[window contentView] addSubview:scroll];
    status = [[[NSTextField alloc] initWithFrame:NSMakeRect(20, 6, 600, 16)] autorelease];
    [status setBezeled:NO]; [status setDrawsBackground:NO]; [status setEditable:NO]; [status setSelectable:NO];
    [status setFont:[NSFont systemFontOfSize:11]];
    [[window contentView] addSubview:status];
    for (i = 0; i < 6; i++) {
        NSButton *b = [[[NSButton alloc] initWithFrame:NSMakeRect(20 + (i % 3) * 200, i < 3 ? 52 : 24, 190, 26)] autorelease];
        [b setTitle:[titles objectAtIndex:i]]; [b setBezelStyle:NSRoundedBezelStyle];
        [b setTarget:self]; [b setAction:actions[i]];
        [[window contentView] addSubview:b];
    }
    [self reload];
    return self;
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)view { (void)view; return [rows count]; }

- (id)tableView:(NSTableView *)view objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
    NSDictionary *skill = [rows objectAtIndex:row];
    (void)view;
    if ([[column identifier] isEqualToString:@"on"])
        return [skill objectForKey:@"enabled"];
    return [[skill objectForKey:@"description"] length] ? [NSString stringWithFormat:@"%@ - %@", [skill objectForKey:@"name"], [skill objectForKey:@"description"]] : [skill objectForKey:@"name"];
}

- (void)tableView:(NSTableView *)view setObjectValue:(id)value forTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
    (void)view;
    if ([[column identifier] isEqualToString:@"on"])
        [TBSkills setName:[[rows objectAtIndex:row] objectForKey:@"name"] enabled:[value boolValue]];
    [self reload];
}

- (NSDictionary *)selected
{
    int row = [table selectedRow];
    return row >= 0 && row < (int)[rows count] ? [rows objectAtIndex:row] : nil;
}

- (void)setStatus:(NSString *)text { [status setStringValue:text ? text : @""]; }

- (void)newSkill:(id)sender
{
    (void)sender;
    [self openEditorWithName:@"" description:@"" body:@"" folder:nil];
}

- (void)editSkill:(id)sender
{
    NSDictionary *skill = [self selected];
    NSDictionary *parsed;
    (void)sender;
    if (!skill)
        return;
    parsed = [TBSkills parse:[NSString stringWithContentsOfFile:[[skill objectForKey:@"folder"] stringByAppendingPathComponent:@"SKILL.md"] encoding:NSUTF8StringEncoding error:NULL]];
    [self openEditorWithName:[skill objectForKey:@"name"] description:[skill objectForKey:@"description"] body:[parsed objectForKey:@"body"] folder:[skill objectForKey:@"folder"]];
}

- (void)fromChat:(id)sender
{
    (void)sender;
    [owner draftSkillFromChatFor:self];
}

/* Name, description and instructions; folder is the existing skill being edited (its folder name stays), or nil for a new one. */
- (void)openEditorWithName:(NSString *)name description:(NSString *)description body:(NSString *)body folder:(NSString *)folder
{
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 520, 400) styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
    NSTextField *nameField = [[[NSTextField alloc] initWithFrame:NSMakeRect(20, 358, 480, 22)] autorelease];
    NSTextField *descField = [[[NSTextField alloc] initWithFrame:NSMakeRect(20, 310, 480, 22)] autorelease];
    NSScrollView *scroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(20, 56, 480, 240)] autorelease];
    NSTextView *view = [[[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 460, 240)] autorelease];
    NSButton *ok = [[[NSButton alloc] initWithFrame:NSMakeRect(420, 12, 80, 28)] autorelease];
    NSButton *cancel = [[[NSButton alloc] initWithFrame:NSMakeRect(330, 12, 80, 28)] autorelease];
    int result;
    [panel setTitle:folder ? @"Edit Skill" : @"New Skill"];
    [[nameField cell] setPlaceholderString:@"Name (letters, numbers, dashes)"];
    [[descField cell] setPlaceholderString:@"When to use it, in one sentence"];
    [nameField setStringValue:name ? name : @""];
    [nameField setEnabled:folder == nil];
    [descField setStringValue:description ? description : @""];
    [scroll setHasVerticalScroller:YES]; [scroll setBorderType:NSBezelBorder];
    [view setMinSize:NSMakeSize(0, 240)]; [view setMaxSize:NSMakeSize(1000000, 1000000)];
    [view setVerticallyResizable:YES]; [view setAutoresizingMask:NSViewWidthSizable];
    [[view textContainer] setWidthTracksTextView:YES];
    [view setFont:[NSFont systemFontOfSize:12]];
    [view setString:body ? body : @""];
    [scroll setDocumentView:view];
    [ok setTitle:folder ? @"Save" : @"Create"]; [ok setBezelStyle:NSRoundedBezelStyle]; [ok setKeyEquivalent:@"\r"];
    [ok setTarget:self]; [ok setAction:@selector(modalOK:)];
    [cancel setTitle:@"Cancel"]; [cancel setBezelStyle:NSRoundedBezelStyle]; [cancel setKeyEquivalent:@"\033"];
    [cancel setTarget:self]; [cancel setAction:@selector(modalCancel:)];
    [[panel contentView] addSubview:nameField]; [[panel contentView] addSubview:descField];
    [[panel contentView] addSubview:scroll]; [[panel contentView] addSubview:ok]; [[panel contentView] addSubview:cancel];
    [panel center];
    result = [NSApp runModalForWindow:panel];
    [panel orderOut:nil];
    if (result == 1) {
        BOOL saved = folder ? [TBSkills writeFolder:folder name:name description:[descField stringValue] body:[view string]]
                            : [TBSkills createNamed:[nameField stringValue] description:[descField stringValue] body:[view string]];
        if (!saved)
            NSRunAlertPanel(@"Skills", @"The skill could not be saved. Give it a name made of letters or numbers.", @"OK", nil, nil);
        [self reload];
    }
    [panel release];
}

- (void)modalOK:(id)sender { (void)sender; [NSApp stopModalWithCode:1]; }
- (void)modalCancel:(id)sender { (void)sender; [NSApp stopModalWithCode:0]; }

- (void)importFolder:(id)sender
{
    NSOpenPanel *open = [NSOpenPanel openPanel];
    (void)sender;
    [open setCanChooseDirectories:YES]; [open setCanChooseFiles:NO];
    [open setMessage:@"Choose a skill folder (it must contain SKILL.md)."];
    if ([open runModalForDirectory:nil file:nil types:nil] != NSOKButton)
        return;
    {
        NSString *from = [[open filenames] objectAtIndex:0];
        NSString *to = [[TBSkills root] stringByAppendingPathComponent:[from lastPathComponent]];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *walk = @"/";
        NSArray *parts = [[TBSkills root] pathComponents];
        unsigned i;
        if (![fm fileExistsAtPath:[from stringByAppendingPathComponent:@"SKILL.md"]]) {
            NSRunAlertPanel(@"Skills", @"That folder has no SKILL.md file in it.", @"OK", nil, nil);
            return;
        }
        for (i = 1; i < [parts count]; i++) {
            walk = [walk stringByAppendingPathComponent:[parts objectAtIndex:i]];
            [fm createDirectoryAtPath:walk attributes:nil];
        }
        if ([fm fileExistsAtPath:to])
            NSRunAlertPanel(@"Skills", @"A skill with that folder name is already installed.", @"OK", nil, nil);
        else if (![fm copyPath:from toPath:to handler:nil])
            NSRunAlertPanel(@"Skills", @"The folder could not be copied.", @"OK", nil, nil);
        [self reload];
    }
}

- (void)deleteSkill:(id)sender
{
    NSDictionary *skill = [self selected];
    (void)sender;
    if (!skill)
        return;
    if (NSRunAlertPanel(@"Delete this skill?", @"The skill's folder is moved to the Trash.", @"Delete", @"Cancel", nil) != NSAlertDefaultReturn)
        return;
    {
        NSString *folder = [skill objectForKey:@"folder"];
        NSInteger tag = 0;
        [[NSWorkspace sharedWorkspace] performFileOperation:NSWorkspaceRecycleOperation source:[folder stringByDeletingLastPathComponent]
            destination:@"" files:[NSArray arrayWithObject:[folder lastPathComponent]] tag:&tag];
    }
    [self reload];
}

- (void)reveal:(id)sender
{
    NSDictionary *skill = [self selected];
    (void)sender;
    [[NSWorkspace sharedWorkspace] selectFile:skill ? [skill objectForKey:@"folder"] : nil inFileViewerRootedAtPath:skill ? @"" : [TBSkills root]];
}

- (void)present
{
    [self reload];
    [window center];
    [window makeKeyAndOrderFront:nil];
}

+ (void)showFor:(ChatController *)controller
{
    if (!shared)
        shared = [[TBSkillsWindow alloc] init];
    shared->owner = controller;
    [shared present];
}

@end

@implementation ChatController (Skills)

- (IBAction)showSkills:(id)sender
{
    (void)sender;
    [TBSkillsWindow showFor:self];
}

/* From This Chat: the chat's own model reads the conversation and drafts a skill from it; the editor opens with the draft. */
- (void)draftSkillFromChatFor:(id)win
{
    NSArray *messages = [current objectForKey:@"messages"];
    NSMutableString *convo = [NSMutableString string];
    NSMutableString *body;
    int i, from = (int)[messages count] - 40;
    if (!current || busy)
        return;
    for (i = from < 0 ? 0 : from; i < (int)[messages count]; i++) {
        NSDictionary *m = [messages objectAtIndex:i];
        NSString *text = [m objectForKey:@"text"];
        if ([[m objectForKey:@"status"] boolValue] || [m objectForKey:@"activityKind"] || [text length] == 0)
            continue;
        [convo appendFormat:@"%@: %@\n\n", [[m objectForKey:@"role"] isEqualToString:@"user"] ? @"Person" : @"Assistant", [text length] > 3000 ? [[text substringToIndex:3000] stringByAppendingString:@"..."] : text];
    }
    if ([convo length] < 40) {
        [win setStatus:@"This chat has no conversation to draft a skill from yet."];
        return;
    }
    if ([convo length] > 24000)
        convo = (NSMutableString *)[convo substringFromIndex:[convo length] - 24000];
    body = [NSMutableString stringWithString:@"{\"messages\":[{\"role\":\"user\",\"content\":\""];
    [body appendString:TBJSONEscape(convo)];
    [body appendFormat:@"\"}],\"tools\":false,\"provider\":\"%@\",\"model\":\"%@\"}", TBJSONEscape([self providerForChat:current]), TBJSONEscape([self modelForChat:current])];
    [win setStatus:@"Drafting a skill from this chat..."];
    [EngineRequest send:@"POST" path:@"/v1/skill" body:body timeout:120 target:self action:@selector(skillDraftArrived:)
        context:[NSDictionary dictionaryWithObjectsAndKeys:win, @"window", current, @"chat", nil]];
}

- (void)skillDraftArrived:(EngineRequest *)request
{
    NSDictionary *info = [request context];
    id win = [info objectForKey:@"window"];
    NSString *text = [request text], *name = @"", *description = @"", *rest = text;
    NSArray *lines;
    unsigned i;
    [self noteSideUsage:request chat:[info objectForKey:@"chat"]];
    if (![request ok] || [TBTrim(text) length] == 0) {
        [win setStatus:@"The model could not draft a skill."];
        return;
    }
    /* name: ..., description: ..., a line of ---, then the instructions */
    lines = [text componentsSeparatedByString:@"\n"];
    for (i = 0; i < [lines count]; i++) {
        NSString *line = TBTrim([lines objectAtIndex:i]);
        if ([line isEqualToString:@"---"] && i > 0) {
            rest = [[lines subarrayWithRange:NSMakeRange(i + 1, [lines count] - i - 1)] componentsJoinedByString:@"\n"];
            break;
        }
        if ([[line lowercaseString] hasPrefix:@"name:"])
            name = TBTrim([line substringFromIndex:5]);
        else if ([[line lowercaseString] hasPrefix:@"description:"])
            description = TBTrim([line substringFromIndex:12]);
    }
    [win setStatus:@""];
    [win openEditorWithName:name description:description body:TBTrim(rest) folder:nil];
}

@end
