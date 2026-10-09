#import "ChatController_Private.h"
#import "TBSkills.h"

/* Chat, Skills...: the list of skills with a switch for each, New (name, description, instructions), Import Folder, Delete and Show in Finder. */

@interface TBSkillsWindow : NSObject {
    NSWindow *window;
    NSTableView *table;
    NSArray *rows;
}
+ (void)show;
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
    NSArray *titles = [NSArray arrayWithObjects:@"New...", @"Import Folder...", @"Delete", @"Show in Finder", nil];
    SEL actions[4] = { @selector(newSkill:), @selector(importFolder:), @selector(deleteSkill:), @selector(reveal:) };
    NSTextField *help;
    int i;
    self = [super init];
    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 560, 340) styleMask:NSTitledWindowMask | NSClosableWindowMask backing:NSBackingStoreBuffered defer:NO];
    [window setTitle:@"Skills"];
    [window setReleasedWhenClosed:NO];
    help = [[[NSTextField alloc] initWithFrame:NSMakeRect(20, 292, 520, 38)] autorelease];
    [help setStringValue:@"A skill is a folder with a SKILL.md file: instructions for one kind of task. The model sees each skill's name and description, and loads one when the task fits."];
    [help setBezeled:NO]; [help setDrawsBackground:NO]; [help setEditable:NO]; [help setSelectable:NO];
    [[window contentView] addSubview:help];
    scroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(20, 56, 520, 228)] autorelease];
    [scroll setHasVerticalScroller:YES]; [scroll setBorderType:NSBezelBorder];
    table = [[[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 500, 228)] autorelease];
    on = [[[NSTableColumn alloc] initWithIdentifier:@"on"] autorelease];
    [on setWidth:26];
    {
        NSButtonCell *cell = [[[NSButtonCell alloc] init] autorelease];
        [cell setButtonType:NSSwitchButton]; [cell setTitle:@""];
        [on setDataCell:cell];
    }
    name = [[[NSTableColumn alloc] initWithIdentifier:@"name"] autorelease];
    [name setWidth:470];
    [[name headerCell] setStringValue:@"Skill"];
    [[on headerCell] setStringValue:@""];
    [table addTableColumn:on]; [table addTableColumn:name];
    [table setDataSource:self];
    [scroll setDocumentView:table];
    [[window contentView] addSubview:scroll];
    for (i = 0; i < 4; i++) {
        NSButton *b = [[[NSButton alloc] initWithFrame:NSMakeRect(20 + i * 130, 16, 124, 28)] autorelease];
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

- (void)newSkill:(id)sender
{
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 480, 360) styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
    NSTextField *nameField = [[[NSTextField alloc] initWithFrame:NSMakeRect(20, 318, 440, 22)] autorelease];
    NSTextField *descField = [[[NSTextField alloc] initWithFrame:NSMakeRect(20, 270, 440, 22)] autorelease];
    NSScrollView *scroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(20, 56, 440, 190)] autorelease];
    NSTextView *view = [[[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 420, 190)] autorelease];
    NSButton *ok = [[[NSButton alloc] initWithFrame:NSMakeRect(380, 12, 80, 28)] autorelease];
    NSButton *cancel = [[[NSButton alloc] initWithFrame:NSMakeRect(290, 12, 80, 28)] autorelease];
    int result;
    (void)sender;
    [panel setTitle:@"New Skill"];
    [nameField setPlaceholderString:@"Name (letters, numbers, dashes)"];
    [descField setPlaceholderString:@"When to use it, in one sentence"];
    [scroll setHasVerticalScroller:YES]; [scroll setBorderType:NSBezelBorder];
    [view setMinSize:NSMakeSize(0, 190)]; [view setMaxSize:NSMakeSize(1000000, 1000000)];
    [view setVerticallyResizable:YES]; [view setAutoresizingMask:NSViewWidthSizable];
    [[view textContainer] setWidthTracksTextView:YES];
    [scroll setDocumentView:view];
    [ok setTitle:@"Create"]; [ok setBezelStyle:NSRoundedBezelStyle]; [ok setKeyEquivalent:@"\r"];
    [ok setTarget:self]; [ok setAction:@selector(modalOK:)];
    [cancel setTitle:@"Cancel"]; [cancel setBezelStyle:NSRoundedBezelStyle]; [cancel setKeyEquivalent:@"\033"];
    [cancel setTarget:self]; [cancel setAction:@selector(modalCancel:)];
    [[panel contentView] addSubview:nameField]; [[panel contentView] addSubview:descField];
    [[panel contentView] addSubview:scroll]; [[panel contentView] addSubview:ok]; [[panel contentView] addSubview:cancel];
    [panel center];
    result = [NSApp runModalForWindow:panel];
    [panel orderOut:nil];
    if (result == 1) {
        if (![TBSkills createNamed:[nameField stringValue] description:[descField stringValue] body:[view string]])
            NSRunAlertPanel(@"Skills", @"The skill could not be created. Give it a name made of letters or numbers.", @"OK", nil, nil);
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
        int tag = 0;
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

+ (void)show
{
    if (!shared)
        shared = [[TBSkillsWindow alloc] init];
    [shared present];
}

@end

@implementation ChatController (Skills)

- (IBAction)showSkills:(id)sender
{
    (void)sender;
    [TBSkillsWindow show];
}

@end
