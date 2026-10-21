#import "ChatController_Private.h"
#import "TBSSHServer.h"
#import "TBSMB.h"
#import "TBSupport.h"
#import "TBEngine.h"
#import <unistd.h>

/* Preferences, Sharing: this Mac's own SMB file server (tbsmbd, which the installer puts in /usr/local/tbssh) and the saved shares the SMB tools connect to. */

@interface ChatController (SharingPrivate)
- (NSTextField *)preferencesLabel:(NSString *)text frame:(NSRect)frame inView:(NSView *)view;
- (void)preferencesHeading:(NSString *)text y:(float)y inView:(NSView *)view;
- (NSTextField *)preferencesNote:(NSString *)text frame:(NSRect)frame inView:(NSView *)view;
- (NSButton *)preferencesButton:(NSString *)title frame:(NSRect)frame action:(SEL)action inView:(NSView *)view;
- (NSButton *)alertsCheck:(NSString *)title key:(NSString *)key y:(float)y in:(NSView *)tab;
- (NSView *)preferencesTab:(NSString *)label in:(NSTabView *)tabs;
@end

static NSString *smbUsersPath(void)
{
    NSString *folder = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Tiger Build/smb"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *parent = [folder stringByDeletingLastPathComponent];
    [fm createDirectoryAtPath:[parent stringByDeletingLastPathComponent] attributes:nil];
    [fm createDirectoryAtPath:parent attributes:nil];
    if (![fm fileExistsAtPath:folder])
        [fm createDirectoryAtPath:folder attributes:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:0700] forKey:NSFilePosixPermissions]];
    return [folder stringByAppendingPathComponent:@"users"];
}

/* name:password lines, only well-formed ones, written readable by this account alone */
static BOOL saveSMBPeople(NSString *text)
{
    NSMutableString *clean = [NSMutableString string];
    NSArray *lines = [text componentsSeparatedByString:@"\n"];
    NSString *path = smbUsersPath();
    unsigned i;
    for (i = 0; i < [lines count]; i++) {
        NSString *line = TBTrim([lines objectAtIndex:i]);
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound || colon.location == 0 || colon.location + 1 >= [line length] || [line hasPrefix:@"#"])
            continue;
        [clean appendFormat:@"%@\n", line];
    }
    if (![clean writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL])
        return NO;
    [[NSFileManager defaultManager] changeFileAttributes:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:0600] forKey:NSFilePosixPermissions] atPath:path];
    return YES;
}

static NSString *signatureOf(NSString *folder, NSString *share, BOOL readOnly, int port)
{
    return [NSString stringWithFormat:@"%@|%@|%d|%d", folder, share, readOnly, port];
}

@implementation ChatController (SMB)

- (void)buildSharingTab:(NSTabView *)tabs
{
    NSView *tab = [self preferencesTab:@"Sharing" in:tabs];
    float y = 292;
    NSTextField *field;
    [self preferencesHeading:@"Share a folder of this Mac over SMB" y:y inView:tab];
    y -= 24;
    [self alertsCheck:@"Let other computers open this folder (Windows, Linux, other Macs)" key:@"smb.allow" y:y in:tab];
    y -= 28;
    [self preferencesLabel:@"Folder:" frame:NSMakeRect(16, y + 2, 60, 18) inView:tab];
    field = [[[NSTextField alloc] initWithFrame:NSMakeRect(80, y, 330, 22)] autorelease];
    [tab addSubview:field];
    [prefsFields setObject:field forKey:@"smb.folder"];
    [self preferencesButton:@"Choose..." frame:NSMakeRect(416, y - 4, 100, 28) action:@selector(chooseShareFolder:) inView:tab];
    y -= 28;
    [self preferencesLabel:@"Name:" frame:NSMakeRect(16, y + 2, 60, 18) inView:tab];
    field = [[[NSTextField alloc] initWithFrame:NSMakeRect(80, y, 150, 22)] autorelease];
    [tab addSubview:field];
    [prefsFields setObject:field forKey:@"smb.share"];
    [self preferencesLabel:@"Port:" frame:NSMakeRect(250, y + 2, 40, 18) inView:tab];
    field = [[[NSTextField alloc] initWithFrame:NSMakeRect(290, y, 60, 22)] autorelease];
    [tab addSubview:field];
    [prefsFields setObject:field forKey:@"smb.port"];
    [self alertsCheck:@"Read only" key:@"smb.readonly" y:y - 1 in:tab];
    [[prefsFields objectForKey:@"smb.readonly"] setFrame:NSMakeRect(380, y - 1, 140, 20)];
    y -= 30;
    [self preferencesButton:@"People..." frame:NSMakeRect(16, y, 110, 28) action:@selector(editSMBPeople:) inView:tab];
    [prefsFields setObject:[self preferencesLabel:@"" frame:NSMakeRect(136, y + 6, 400, 18) inView:tab] forKey:@"smb.status"];
    y -= 14;
    [self preferencesNote:@"People: who may sign in, one name:password per line (a password for this only; the file is readable by your account alone). Computers connect to smb://this-mac/Name, "
        @"or \\\\this-mac\\Name on Windows. Port 445 is what other computers expect and needs the administrator password; the Mac's own File Sharing (System Preferences, Sharing) must not be using it."
        frame:NSMakeRect(16, y - 56, 520, 68) inView:tab];
    y -= 86;
    [self preferencesHeading:@"Connect to SMB shares" y:y inView:tab];
    y -= 34;
    [self preferencesButton:@"Saved Shares..." frame:NSMakeRect(16, y, 130, 28) action:@selector(editSavedShares:) inView:tab];
    y -= 14;
    [self preferencesNote:@"Shares that chats may use through the SMB file shares tools (Tool Settings, MCP Servers: turn on \"SMB file shares\"), one per line: name = smb://user:password@server/share. "
        @"They are kept in the Keychain, so a chat can say \"use the share office\" without being told the password."
        frame:NSMakeRect(16, y - 40, 520, 52) inView:tab];
}

/* a small text editor for lines; returns the new text, or nil when cancelled */
- (NSString *)editLinesTitled:(NSString *)title label:(NSString *)label text:(NSString *)text
{
    NSPanel *panel = [[[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 560, 320) styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO] autorelease];
    NSScrollView *scroll = [[[NSScrollView alloc] initWithFrame:NSMakeRect(16, 50, 528, 220)] autorelease];
    NSTextView *view = [[[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 510, 220)] autorelease];
    NSButton *save = [self preferencesButton:@"Save" frame:NSMakeRect(450, 12, 94, 30) action:@selector(sshKeysOK:) inView:[panel contentView]];
    NSButton *cancel = [self preferencesButton:@"Cancel" frame:NSMakeRect(350, 12, 94, 30) action:@selector(sshKeysCancel:) inView:[panel contentView]];
    NSString *result = nil;
    [self preferencesLabel:label frame:NSMakeRect(16, 278, 528, 32) inView:[panel contentView]];
    [save setKeyEquivalent:@"\r"];
    [cancel setKeyEquivalent:@"\033"];
    [view setFont:[NSFont fontWithName:@"Monaco" size:10]];
    [view setString:text];
    [view setEditable:YES];
    [view setMinSize:NSMakeSize(0, 220)];
    [view setMaxSize:NSMakeSize(1e7, 1e7)];
    [view setVerticallyResizable:YES];
    [view setAutoresizingMask:NSViewWidthSizable];
    [scroll setHasVerticalScroller:YES];
    [scroll setBorderType:NSBezelBorder];
    [scroll setDocumentView:view];
    [[panel contentView] addSubview:scroll];
    [panel setTitle:title];
    [panel setLevel:NSFloatingWindowLevel];
    if ([NSApp runModalForWindow:panel] == 1)
        result = [[[view string] copy] autorelease];
    [panel orderOut:nil];
    return result;
}

- (void)editSMBPeople:(id)sender
{
    NSString *old = [NSString stringWithContentsOfFile:smbUsersPath() encoding:NSUTF8StringEncoding error:NULL];
    NSString *text;
    (void)sender;
    text = [self editLinesTitled:@"People who may open the shared folder" label:@"One person per line, as  name:password  . Use a password made for this; it is kept in a file only your account can read." text:old ? old : @""];
    if (text && !saveSMBPeople(text))
        NSRunAlertPanel(@"People", @"The list could not be saved.", @"OK", nil, nil);
    [self refreshSharingStatus];
}

- (void)editSavedShares:(id)sender
{
    NSString *text;
    (void)sender;
    text = [self editLinesTitled:@"Saved SMB shares" label:@"One per line:  name = smb://user:password@server/share  (add :port after the server if it is not 445; domain;user for a domain). Kept in the Keychain."
        text:[TBSMB savedSharesText]];
    if (text)
        [TBSMB setSavedSharesText:text];
}

- (void)chooseShareFolder:(id)sender
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    (void)sender;
    [panel setCanChooseDirectories:YES];
    [panel setCanChooseFiles:NO];
    [panel setAllowsMultipleSelection:NO];
    [panel setPrompt:@"Choose"];
    if ([panel runModal] == NSOKButton)
        [[prefsFields objectForKey:@"smb.folder"] setStringValue:[[panel filenames] objectAtIndex:0]];
}

- (int)smbPortFromField
{
    int port = [[[prefsFields objectForKey:@"smb.port"] stringValue] intValue];
    return port >= 1 && port <= 65535 ? port : 445;
}

- (void)refreshSharingStatus
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *text;
    NSString *people = [NSString stringWithContentsOfFile:smbUsersPath() encoding:NSUTF8StringEncoding error:NULL];
    int n = 0;
    unsigned i;
    NSArray *lines = [people componentsSeparatedByString:@"\n"];
    for (i = 0; i < [lines count]; i++)
        if ([TBTrim([lines objectAtIndex:i]) length])
            n++;
    if (![TBSSHServer smbInstalled])
        text = @"Not installed. The Tiger Build installer puts it in /usr/local/tbssh.";
    else if ([TBSSHServer smbListeningOnPort:[d integerForKey:@"TBSMBPortRunning"] ? (int)[d integerForKey:@"TBSMBPortRunning"] : 445] && [d stringForKey:@"TBSMBRunning"])
        text = [NSString stringWithFormat:@"Sharing on port %d. %d %@ may sign in.", (int)[d integerForKey:@"TBSMBPortRunning"], n, n == 1 ? @"person" : @"people"];
    else
        text = [NSString stringWithFormat:@"Off. %d %@ set up.", n, n == 1 ? @"person" : @"people"];
    [[prefsFields objectForKey:@"smb.status"] setStringValue:text];
}

- (void)loadSharingOptions
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    int running = (int)[d integerForKey:@"TBSMBPortRunning"];
    BOOL installed = [TBSSHServer smbInstalled], on = installed && [d stringForKey:@"TBSMBRunning"] && [TBSSHServer smbListeningOnPort:running ? running : 445];
    NSString *folder = [d stringForKey:@"TBSMBFolder"], *share = [d stringForKey:@"TBSMBShare"];
    [[prefsFields objectForKey:@"smb.allow"] setState:on ? NSOnState : NSOffState];
    [[prefsFields objectForKey:@"smb.allow"] setEnabled:installed];
    [[prefsFields objectForKey:@"smb.folder"] setStringValue:[folder length] ? folder : [NSHomeDirectory() stringByAppendingPathComponent:@"Public"]];
    [[prefsFields objectForKey:@"smb.share"] setStringValue:[share length] ? share : @"Shared"];
    [[prefsFields objectForKey:@"smb.port"] setStringValue:[d objectForKey:@"TBSMBPort"] ? [NSString stringWithFormat:@"%d", (int)[d integerForKey:@"TBSMBPort"]] : @"445"];
    [[prefsFields objectForKey:@"smb.readonly"] setState:[d boolForKey:@"TBSMBReadOnly"] ? NSOnState : NSOffState];
    [self refreshSharingStatus];
}

- (void)saveSharingOptions
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    BOOL want = [[prefsFields objectForKey:@"smb.allow"] state] == NSOnState, readOnly = [[prefsFields objectForKey:@"smb.readonly"] state] == NSOnState;
    NSString *folder = TBTrim([[prefsFields objectForKey:@"smb.folder"] stringValue]), *share = TBTrim([[prefsFields objectForKey:@"smb.share"] stringValue]);
    int port = [self smbPortFromField], running = (int)[d integerForKey:@"TBSMBPortRunning"];
    BOOL have = [d stringForKey:@"TBSMBRunning"] != nil && [TBSSHServer smbListeningOnPort:running ? running : 445];
    NSString *signature = signatureOf(folder, share, readOnly, port), *why;
    NSString *people;
    BOOL isDir = NO;
    if (![TBSSHServer smbInstalled])
        return;
    [d setObject:folder forKey:@"TBSMBFolder"];
    [d setObject:share forKey:@"TBSMBShare"];
    [d setBool:readOnly forKey:@"TBSMBReadOnly"];
    [d setInteger:port forKey:@"TBSMBPort"];
    if (want == have && !(want && ![signature isEqualToString:[d stringForKey:@"TBSMBRunning"]]))
        return;
    if (!want) {
        why = [TBSSHServer setSMBRunning:NO user:nil folder:nil share:nil readOnly:NO port:running ? running : 445];
        if (why && ![why isEqualToString:@"cancelled"])
            NSRunAlertPanel(@"File sharing did not stop", @"%@", @"OK", nil, nil, why);
        else if (!why)
            [d removeObjectForKey:@"TBSMBRunning"];
        return;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:folder isDirectory:&isDir] || !isDir) {
        NSRunAlertPanel(@"File sharing", @"%@ is not a folder. Choose the folder to share.", @"OK", nil, nil, folder);
        return;
    }
    if (![share length] || [share rangeOfString:@"/"].length || [share rangeOfString:@"\\"].length) {
        NSRunAlertPanel(@"File sharing", @"Give the share a name without slashes, such as Shared.", @"OK", nil, nil);
        return;
    }
    people = [NSString stringWithContentsOfFile:smbUsersPath() encoding:NSUTF8StringEncoding error:NULL];
    if ([TBTrim(people) length] == 0) {
        NSRunAlertPanel(@"File sharing", @"Add at least one person first (People...): nobody can open the folder without a name and password.", @"OK", nil, nil);
        return;
    }
    if (NSRunAlertPanel(@"Share this folder?", @"Computers that sign in as one of the people you listed will be able to %@ everything in %@ and the folders inside it. Turn it on only on a network you trust.",
        @"Share", @"Cancel", nil, readOnly ? @"read" : @"read, change and delete", folder) != NSAlertDefaultReturn)
        return;
    if (have)
        [TBSSHServer setSMBRunning:NO user:nil folder:nil share:nil readOnly:NO port:running ? running : 445];
    why = [TBSSHServer setSMBRunning:YES user:NSUserName() folder:folder share:share readOnly:readOnly port:port];
    if (why && ![why isEqualToString:@"cancelled"])
        NSRunAlertPanel(@"File sharing did not start", @"%@", @"OK", nil, nil, why);
    else if (!why) {
        [d setObject:signature forKey:@"TBSMBRunning"];
        [d setInteger:port forKey:@"TBSMBPortRunning"];
    }
}

@end
