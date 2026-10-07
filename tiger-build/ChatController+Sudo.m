#import "ChatController_Private.h"
#import "TBSession.h"
#import <Security/Security.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <unistd.h>

/* Administrator (sudo) mode for Commander. The person turns it on here and types the administrator password
   once; it is kept in the Keychain, readable only by this app. Commander runs as a separate program, which cannot
   open that Keychain without asking, so when a command needs sudo it asks this app for the password over a socket only this
   account can use. The model never sees it. */

static NSString *kSudoService = @"Tiger Build Commander administrator";

static NSString *runCommander(NSString *flag)
{
    NSTask *task = [[[NSTask alloc] init] autorelease];
    NSPipe *pipe = [NSPipe pipe];
    NSData *data;
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:TBCommanderProgram()])
        return nil;
    [task setLaunchPath:TBCommanderProgram()];
    [task setArguments:[NSArray arrayWithObjects:@"--sudo", flag, nil]];
    [task setStandardOutput:pipe];
    [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];
    [task launch];
    data = [[pipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
}

static BOOL passwordSaved(void)
{
    const char *service = [kSudoService UTF8String];
    const char *account = [NSUserName() UTF8String];
    SecKeychainItemRef item = NULL;
    BOOL found = SecKeychainFindGenericPassword(NULL, strlen(service), service, strlen(account), account, NULL, NULL, &item) == noErr;
    if (item)
        CFRelease(item);
    return found;
}

static void forgetPassword(void)
{
    const char *service = [kSudoService UTF8String];
    const char *account = [NSUserName() UTF8String];
    SecKeychainItemRef item = NULL;
    if (SecKeychainFindGenericPassword(NULL, strlen(service), service, strlen(account), account, NULL, NULL, &item) == noErr && item) {
        SecKeychainItemDelete(item);
        CFRelease(item);
    }
}

static BOOL savePassword(NSString *password)
{
    const char *service = [kSudoService UTF8String];
    const char *account = [NSUserName() UTF8String];
    const char *secret = [password UTF8String];
    forgetPassword();
    return SecKeychainAddGenericPassword(NULL, strlen(service), service, strlen(account), account, strlen(secret), secret, NULL) == noErr;
}

/* ---- handing the password to Commander ---- */

/* The same path Commander uses (the sudo socket in CMProcess.m). */
static NSString *brokerPath(void)
{
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Tiger Build/commander/sudo.sock"];
    if ([path length] > 100)
        path = [NSString stringWithFormat:@"/tmp/tigerbuild-%d-sudo.sock", (int)getuid()];
    return path;
}

/* Open only while a reply is running in a chat that ticked the sudo item. Anything else on this account (a model's own shell
   included) that connects to the socket at another time is refused. */
static volatile BOOL brokerOpen = NO;

void TBSudoBrokerOpen(BOOL open)
{
    brokerOpen = open;
}

static void answerCommander(int client)
{
    char request[40];
    ssize_t got = read(client, request, sizeof(request) - 1);
    const char *service = [kSudoService UTF8String];
    const char *account = [NSUserName() UTF8String];
    UInt32 length = 0;
    void *data = NULL;
    uid_t uid;
    gid_t gid;
    if (got <= 0 || getpeereid(client, &uid, &gid) != 0 || uid != getuid())
        return;
    request[got] = 0;
    if (strcmp(request, "password\n") != 0)
        return;
    if (!brokerOpen) {
        const char *closed = "error: administrator mode is not switched on for the chat that is running.\n";
        write(client, closed, strlen(closed));
        return;
    }
    if (SecKeychainFindGenericPassword(NULL, strlen(service), service, strlen(account), account, &length, &data, NULL) == noErr) {
        write(client, data, length);
        write(client, "\n", 1);
        memset(data, 0, length);
        SecKeychainItemFreeContent(NULL, data);
    } else {
        const char *none = "error: no administrator password is saved. A person can set it in Tiger Build: Preferences, Commander.\n";
        write(client, none, strlen(none));
    }
}

/* Whether sudo takes this password for this account. */
static BOOL passwordAccepted(NSString *password)
{
    NSTask *forget = [[[NSTask alloc] init] autorelease];
    NSTask *check = [[[NSTask alloc] init] autorelease];
    NSPipe *input = [NSPipe pipe];
    [forget setLaunchPath:@"/usr/bin/sudo"];
    [forget setArguments:[NSArray arrayWithObject:@"-k"]];
    [forget launch];
    [forget waitUntilExit];
    [check setLaunchPath:@"/usr/bin/sudo"];
    [check setArguments:[NSArray arrayWithObjects:@"-S", @"-v", @"-p", @"", nil]];
    [check setStandardInput:input];
    [check setStandardOutput:[NSFileHandle fileHandleWithNullDevice]];
    [check setStandardError:[NSFileHandle fileHandleWithNullDevice]];
    [check launch];
    [[input fileHandleForWriting] writeData:[[password stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    [[input fileHandleForWriting] closeFile];
    [check waitUntilExit];
    return [check terminationStatus] == 0;
}

@implementation ChatController (Sudo)

- (BOOL)administratorPasswordSaved
{
    return passwordSaved();
}

- (void)sudoBrokerLoop:(NSNumber *)listener
{
    int fd = [listener intValue];
    for (;;) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        int client = accept(fd, NULL, NULL);
        if (client >= 0) {
            struct timeval wait;
            wait.tv_sec = 5;
            wait.tv_usec = 0;
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &wait, sizeof(wait));
            answerCommander(client);
            close(client);
        }
        [pool release];
    }
}

/* Called once at launch. */
- (void)startSudoBroker
{
    static BOOL started = NO;
    NSString *path = brokerPath();
    struct sockaddr_un address;
    int fd;
    if (started)
        return;
    started = YES;
    {
        NSString *folder = [path stringByDeletingLastPathComponent];
        NSDictionary *private = [NSDictionary dictionaryWithObject:[NSNumber numberWithInt:0700] forKey:NSFilePosixPermissions];
        [[NSFileManager defaultManager] createDirectoryAtPath:[folder stringByDeletingLastPathComponent] attributes:nil];
        [[NSFileManager defaultManager] createDirectoryAtPath:folder attributes:private];
    }
    unlink([path fileSystemRepresentation]);
    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0)
        return;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, [path fileSystemRepresentation], sizeof(address.sun_path));
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(fd, 4) != 0) {
        close(fd);
        return;
    }
    chmod([path fileSystemRepresentation], 0600);
    [NSThread detachNewThreadSelector:@selector(sudoBrokerLoop:) toTarget:self withObject:[NSNumber numberWithInt:fd]];
}

- (void)sudoPanelOK:(id)sender
{
    (void)sender;
    [NSApp stopModalWithCode:1];
}

- (void)sudoPanelCancel:(id)sender
{
    (void)sender;
    [NSApp stopModalWithCode:0];
}

/* nil when the person cancels. */
- (NSString *)askAdministratorPassword
{
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 400, 196) styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
    NSTextField *label = [[[NSTextField alloc] initWithFrame:NSMakeRect(20, 146, 360, 34)] autorelease];
    NSSecureTextField *field = [[[NSSecureTextField alloc] initWithFrame:NSMakeRect(20, 114, 360, 22)] autorelease];
    NSTextField *note = [[[NSTextField alloc] initWithFrame:NSMakeRect(20, 54, 360, 52)] autorelease];
    NSButton *ok = [[[NSButton alloc] initWithFrame:NSMakeRect(300, 12, 80, 28)] autorelease];
    NSButton *cancel = [[[NSButton alloc] initWithFrame:NSMakeRect(210, 12, 80, 28)] autorelease];
    NSString *password = nil;
    int result;
    [panel setTitle:@"Administrator Password"];
    [label setStringValue:[NSString stringWithFormat:@"Password for %@ on this Mac, so agents can run commands with sudo:", NSFullUserName()]];
    [note setStringValue:@"It is kept in your Keychain, used only when a command needs sudo, and handed to Commander only while Tiger Build is open. The model never sees it."];
    [label setFont:[NSFont systemFontOfSize:12]];
    [note setFont:[NSFont systemFontOfSize:11]];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [label setEditable:NO];
    [label setSelectable:NO];
    [note setBezeled:NO];
    [note setDrawsBackground:NO];
    [note setEditable:NO];
    [note setSelectable:NO];
    [ok setTitle:@"OK"];
    [ok setBezelStyle:NSRoundedBezelStyle];
    [ok setKeyEquivalent:@"\r"];
    [ok setTarget:self];
    [ok setAction:@selector(sudoPanelOK:)];
    [cancel setTitle:@"Cancel"];
    [cancel setBezelStyle:NSRoundedBezelStyle];
    [cancel setKeyEquivalent:@"\033"];
    [cancel setTarget:self];
    [cancel setAction:@selector(sudoPanelCancel:)];
    [[panel contentView] addSubview:label];
    [[panel contentView] addSubview:field];
    [[panel contentView] addSubview:note];
    [[panel contentView] addSubview:ok];
    [[panel contentView] addSubview:cancel];
    [panel setInitialFirstResponder:field];
    [panel center];
    [panel setLevel:NSFloatingWindowLevel];
    result = [NSApp runModalForWindow:panel];
    [panel orderOut:nil];
    if (result == 1)
        password = [NSString stringWithString:[field stringValue]];
    [field setStringValue:@""];
    [panel release];
    return password;
}

/* Asks until sudo accepts the password, then keeps it. NO if the person gives up. */
- (BOOL)saveAdministratorPassword
{
    for (;;) {
        NSString *password = [self askAdministratorPassword];
        if (!password)
            return NO;
        if ([password length] == 0 || !passwordAccepted(password)) {
            NSRunAlertPanel(@"That password was not accepted",
                @"Use the password you log in to this Mac with. The account must be an administrator.", @"Try Again", nil, nil);
            continue;
        }
        if (!savePassword(password)) {
            NSRunAlertPanel(@"The password could not be saved", @"The Keychain refused it. Unlock the login keychain and try again.", @"OK", nil, nil);
            return NO;
        }
        return YES;
    }
}

- (void)refreshSudoStatus
{
    NSButton *check = [prefsFields objectForKey:@"sudo.check"];
    NSTextField *status = [prefsFields objectForKey:@"sudo.status"];
    NSString *reply = runCommander(@"status");
    BOOL on = reply && [reply hasPrefix:@"on"];
    BOOL saved = passwordSaved();
    if (!reply) {
        [check setEnabled:NO];
        [status setStringValue:@"Commander is not installed on this Mac yet."];
        return;
    }
    [check setEnabled:YES];
    [check setState:on ? NSOnState : NSOffState];
    if (on && saved)
        [status setStringValue:@"On. Agents can use sudo here while Tiger Build is open."];
    else if (on)
        [status setStringValue:@"On, but no password is saved. Choose Set Password."];
    else
        [status setStringValue:@"Off. Agents cannot use sudo on this Mac."];
}

- (IBAction)toggleSudoMode:(id)sender
{
    if ([sender state] == NSOnState) {
        NSString *reply;
        if (!passwordSaved() && ![self saveAdministratorPassword]) {
            [self refreshSudoStatus];
            return;
        }
        reply = runCommander(@"on");
        if (!reply || ![reply hasPrefix:@"on"])
            NSRunAlertPanel(@"Administrator mode is still off", @"A policy file on this Mac (/etc/ppc-commander.json) keeps it off.", @"OK", nil, nil);
    } else {
        runCommander(@"off");
        forgetPassword();
    }
    [self refreshSudoStatus];
}

- (IBAction)setAdministratorPassword:(id)sender
{
    (void)sender;
    [self saveAdministratorPassword];
    [self refreshSudoStatus];
}

@end
