#import "ChatController_Private.h"
#import <Security/Security.h>

/* Administrator (sudo) mode for Commander. The person turns it on here and types the administrator password
   once; it is kept in the Keychain, where only this app and /usr/bin/security (which Commander uses when a
   command needs sudo) may read it. The model never sees it. */

static NSString *kSudoService = @"Tiger Build Commander administrator";

static NSString *runCommander(NSString *flag)
{
    NSString *script = [NSHomeDirectory() stringByAppendingPathComponent:@"ppc-commander/ppc_commander.py"];
    NSTask *task = [[[NSTask alloc] init] autorelease];
    NSPipe *pipe = [NSPipe pipe];
    NSData *data;
    if (![[NSFileManager defaultManager] fileExistsAtPath:script])
        return nil;
    [task setLaunchPath:@"/usr/bin/python"];
    [task setArguments:[NSArray arrayWithObjects:script, @"--sudo", flag, nil]];
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
    SecTrustedApplicationRef me = NULL;
    SecTrustedApplicationRef security = NULL;
    SecAccessRef access = NULL;
    SecKeychainItemRef item = NULL;
    SecKeychainAttribute attributes[2];
    SecKeychainAttributeList list;
    const void *apps[2];
    CFArrayRef trusted;
    OSStatus status = -1;
    forgetPassword();
    if (SecTrustedApplicationCreateFromPath(NULL, &me) != noErr || SecTrustedApplicationCreateFromPath("/usr/bin/security", &security) != noErr)
        return NO;
    apps[0] = me;
    apps[1] = security;
    trusted = CFArrayCreate(NULL, apps, 2, &kCFTypeArrayCallBacks);
    if (SecAccessCreate((CFStringRef)@"Tiger Build administrator password", trusted, &access) == noErr) {
        attributes[0].tag = kSecServiceItemAttr;
        attributes[0].length = strlen(service);
        attributes[0].data = (void *)service;
        attributes[1].tag = kSecAccountItemAttr;
        attributes[1].length = strlen(account);
        attributes[1].data = (void *)account;
        list.count = 2;
        list.attr = attributes;
        status = SecKeychainItemCreateFromContent(kSecGenericPasswordItemClass, &list, strlen(secret), secret, NULL, access, &item);
    }
    if (item)
        CFRelease(item);
    if (access)
        CFRelease(access);
    CFRelease(trusted);
    CFRelease(me);
    CFRelease(security);
    return status == noErr;
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
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 400, 170) styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
    NSTextField *label = [[[NSTextField alloc] initWithFrame:NSMakeRect(20, 122, 360, 34)] autorelease];
    NSSecureTextField *field = [[[NSSecureTextField alloc] initWithFrame:NSMakeRect(20, 90, 360, 22)] autorelease];
    NSTextField *note = [[[NSTextField alloc] initWithFrame:NSMakeRect(20, 50, 360, 34)] autorelease];
    NSButton *ok = [[[NSButton alloc] initWithFrame:NSMakeRect(300, 12, 80, 28)] autorelease];
    NSButton *cancel = [[[NSButton alloc] initWithFrame:NSMakeRect(210, 12, 80, 28)] autorelease];
    NSString *password = nil;
    int result;
    [panel setTitle:@"Administrator Password"];
    [label setStringValue:[NSString stringWithFormat:@"Password for %@ on this Mac, so agents can run commands with sudo:", NSFullUserName()]];
    [note setStringValue:@"It is kept in your Keychain and used only when a command needs sudo. The model never sees it."];
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
        [status setStringValue:@"On. Agents can use sudo here; the password is in your Keychain."];
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
