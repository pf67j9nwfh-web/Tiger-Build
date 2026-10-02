#import "ChatController_Private.h"

/* The Commander menu (ppc-commander running on this Mac as a standalone
   service), the SSH link the relay uses, and keeping ppc-commander installed
   and current. */

@implementation ChatController (Commander)

- (NSDictionary *)commanderCommand:(NSString *)command
{
    NSTask *task = [[[NSTask alloc] init] autorelease];
    NSPipe *pipe = [NSPipe pipe];
    NSData *data;
    NSString *text;
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSArray *lines;
    unsigned i;
    NSString *script = [NSHomeDirectory() stringByAppendingPathComponent:@"ppc-commander/service.py"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:script]) return result;
    [task setLaunchPath:@"/usr/bin/python"];
    [task setArguments:[NSArray arrayWithObjects:script, command, nil]];
    [task setStandardOutput:pipe];
    [task launch];
    data = [[pipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    lines = [text componentsSeparatedByString:@"\n"];
    for (i = 0; i < [lines count]; i++) {
        NSString *line = [lines objectAtIndex:i];
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location != NSNotFound)
            [result setObject:[line substringFromIndex:eq.location + 1] forKey:[line substringToIndex:eq.location]];
    }
    return result;
}

/* Runs on a worker thread. The status command starts Python, which takes a
   moment on an old Mac; doing it while a menu opens made the menu hang. */
- (void)commanderStatusWorker:(id)unused
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSDictionary *state;
    (void)unused;
    state = [self commanderCommand:@"status"];
    [self performSelectorOnMainThread:@selector(commanderStatusFetched:) withObject:state waitUntilDone:NO];
    [pool release];
}

- (void)commanderStatusFetched:(NSDictionary *)state
{
    [commanderCache release];
    commanderCache = [state retain];
    commanderStatusPending = NO;
}

- (void)refreshCommanderStatus
{
    if (commanderStatusPending)
        return;
    commanderStatusPending = YES;
    [NSThread detachNewThreadSelector:@selector(commanderStatusWorker:) toTarget:self withObject:nil];
}

- (void)commanderStart:(id)sender
{
    [self commanderStatusFetched:[self commanderCommand:@"start"]];
    [self commanderStatusFetched:[self commanderCommand:@"status"]];
    [self menuNeedsUpdate:[sender menu]];
}
- (void)commanderStop:(id)sender
{
    if (NSRunAlertPanel(@"Stop Commander?", @"Active Commander tool sessions and their child processes will close. "
        @"New tool sessions are blocked until you choose Start. This does not stop the relay or ordinary SSH.",
        @"Stop", @"Cancel", nil) != NSAlertDefaultReturn) return;
    [self commanderCommand:@"stop"];
    [self commanderStatusFetched:[self commanderCommand:@"status"]];
    [self menuNeedsUpdate:[sender menu]];
}
- (void)commanderAutostart:(id)sender
{
    NSDictionary *state = [self commanderCommand:@"status"];
    [self commanderCommand:([[state objectForKey:@"autostart"] intValue] != 0) ? @"autostart-off" : @"autostart-on"];
    [self commanderStatusFetched:[self commanderCommand:@"status"]];
    [self menuNeedsUpdate:[sender menu]];
}
- (void)commanderIP:(id)sender
{
    (void)sender;
    NSDictionary *state = [self commanderCommand:@"status"];
    NSString *ip = [state objectForKey:@"ip"];
    NSRunInformationalAlertPanel(@"This Mac", @"%@\n%@\n\nIPv4 addresses: %@", @"OK", nil, nil,
        [TBMachine name], [TBMachine systemVersion], [ip length] ? ip : @"none active");
}
- (void)menuNeedsUpdate:(NSMenu *)menu
{
    NSDictionary *state = commanderCache;
    BOOL enabled;
    NSString *ip;
    if (![[menu title] isEqualToString:@"Commander"]) return;
    [self refreshCommanderStatus];
    if (!state)
        state = [self commanderCommand:@"status"];
    enabled = ([[state objectForKey:@"enabled"] intValue] != 0);
    ip = [state objectForKey:@"ip"];
    [[menu itemAtIndex:0] setTitle:enabled ? @"Commander: On" : @"Commander: Off"];
    [[menu itemAtIndex:1] setEnabled:!enabled];
    [[menu itemAtIndex:2] setEnabled:enabled];
    [[menu itemAtIndex:4] setTitle:([[state objectForKey:@"autostart"] intValue] != 0) ? @"Stop Start at Login" : @"Start at Login"];
    [[menu itemAtIndex:5] setTitle:[NSString stringWithFormat:@"IP: %@", [ip length] ? ip : @"unavailable"]];
}

/* ---- keeping ppc-commander installed ---- */

static NSString *commanderVersion(NSData *data)
{
    NSString *text = [[[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding] autorelease];
    NSRange at = [text rangeOfString:@"VERSION = '"];
    NSRange end;
    if (at.location == NSNotFound)
        return nil;
    text = [text substringFromIndex:NSMaxRange(at)];
    end = [text rangeOfString:@"'"];
    return end.location == NSNotFound ? nil : [text substringToIndex:end.location];
}

/* x.y.z compared number by number. */
static int compareVersions(NSString *a, NSString *b)
{
    NSArray *left = [a componentsSeparatedByString:@"."];
    NSArray *right = [b componentsSeparatedByString:@"."];
    unsigned i;
    for (i = 0; i < [left count] || i < [right count]; i++) {
        int x = i < [left count] ? [[left objectAtIndex:i] intValue] : 0;
        int y = i < [right count] ? [[right objectAtIndex:i] intValue] : 0;
        if (x != y)
            return x < y ? -1 : 1;
    }
    return 0;
}

/* The app carries its own ppc-commander. At launch it is copied to
   ~/ppc-commander when that is missing or older, so the tools that need a new
   Commander (screenshots, directory restrictions) work without a separate install. */
- (void)ensureCommanderInstalled
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *folder = [NSHomeDirectory() stringByAppendingPathComponent:@"ppc-commander"];
    NSString *bundled = [[NSBundle mainBundle] pathForResource:@"ppc_commander" ofType:@"py" inDirectory:@"ppc-commander"];
    NSData *fresh;
    NSData *have;
    NSString *haveVersion;
    NSString *freshVersion;
    NSString *dest = [folder stringByAppendingPathComponent:@"ppc_commander.py"];
    NSString *serviceSource;
    NSDictionary *mode = [NSDictionary dictionaryWithObject:[NSNumber numberWithInt:0755] forKey:NSFilePosixPermissions];
    if (!bundled)
        return;
    fresh = [NSData dataWithContentsOfFile:bundled];
    if ([fresh length] == 0)
        return;
    have = [NSData dataWithContentsOfFile:dest];
    haveVersion = have ? commanderVersion(have) : nil;
    freshVersion = commanderVersion(fresh);
    if (have && haveVersion && freshVersion && compareVersions(haveVersion, freshVersion) >= 0)
        return;
    if (![fm fileExistsAtPath:folder])
        [fm createDirectoryAtPath:folder attributes:nil];
    if (have)
        [have writeToFile:[dest stringByAppendingString:@".previous"] atomically:YES];
    if (![fresh writeToFile:dest atomically:YES])
        return;
    [fm changeFileAttributes:mode atPath:dest];
    serviceSource = [[NSBundle mainBundle] pathForResource:@"service" ofType:@"py" inDirectory:@"ppc-commander"];
    if (serviceSource) {
        NSString *serviceDest = [folder stringByAppendingPathComponent:@"service.py"];
        [[NSData dataWithContentsOfFile:serviceSource] writeToFile:serviceDest atomically:YES];
        [fm changeFileAttributes:mode atPath:serviceDest];
    }
    NSLog(@"Tiger Build installed ppc-commander %@ (was %@)", freshVersion, haveVersion ? haveVersion : @"missing");
}

/* ---- the relay's SSH login to this Mac ---- */

- (BOOL)installRelayKey:(NSString *)key
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@".ssh"];
    NSString *file = [dir stringByAppendingPathComponent:@"authorized_keys"];
    NSString *existing = [NSString stringWithContentsOfFile:file];
    NSString *line = [key stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSDictionary *private = [NSDictionary dictionaryWithObject:[NSNumber numberWithInt:0700] forKey:NSFilePosixPermissions];
    NSDictionary *fileMode = [NSDictionary dictionaryWithObject:[NSNumber numberWithInt:0600] forKey:NSFilePosixPermissions];
    NSString *updated;
    if (![line hasPrefix:@"ssh-rsa "] || [line rangeOfString:@"\n"].location != NSNotFound)
        return NO;
    if (![fm fileExistsAtPath:dir])
        [fm createDirectoryAtPath:dir attributes:private];
    else
        [fm changeFileAttributes:private atPath:dir];
    if (existing && [existing rangeOfString:line].location != NSNotFound)
        return YES;
    if (!existing)
        existing = @"";
    if ([existing length] > 0 && ![existing hasSuffix:@"\n"])
        existing = [existing stringByAppendingString:@"\n"];
    updated = [existing stringByAppendingFormat:@"%@\n", line];
    if (![updated writeToFile:file atomically:YES])
        return NO;
    [fm changeFileAttributes:fileMode atPath:file];
    return YES;
}

- (void)connectCommanderSSH:(id)sender
{
    (void)sender;
    if (NSRunAlertPanel(@"Connect Commander over SSH?",
        @"The relay runs Commander's tools on this Mac by signing in over SSH as \"%@\". This adds the relay's public key to "
        @"~/.ssh/authorized_keys on this Mac and tells the relay this Mac's address and user name. "
        @"Remote Login must be on (System Preferences, Sharing). No password is sent.",
        @"Connect", @"Cancel", nil, NSUserName()) != NSAlertDefaultReturn)
        return;
    [RelayRequest send:@"GET" path:@"/v1/ssh/public-key" body:nil timeout:20 target:self
        action:@selector(sshKeyArrived:) context:nil];
}

- (void)sshKeyArrived:(RelayRequest *)request
{
    NSString *body;
    if (![request ok]) {
        NSRunAlertPanel(@"Connect Commander", @"The relay could not give its SSH key. %@", @"OK", nil, nil,
            [self relayProblemForRequest:request] ? [self relayProblemForRequest:request] : [request text]);
        return;
    }
    if (![self installRelayKey:[request text]]) {
        NSRunAlertPanel(@"Connect Commander", @"Could not add the relay's key to ~/.ssh/authorized_keys on this Mac.", @"OK", nil, nil);
        return;
    }
    body = [NSString stringWithFormat:@"{\"user\":\"%@\",\"home\":\"%@\"}", TBJSONEscape(NSUserName()), TBJSONEscape(NSHomeDirectory())];
    [RelayRequest send:@"POST" path:@"/v1/ssh/connect" body:body timeout:60 target:self
        action:@selector(sshConnected:) context:nil];
}

- (void)sshConnected:(RelayRequest *)request
{
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    NSArray *lines;
    unsigned i;
    if (![request ok]) {
        NSString *why = [[request text] length] ? [request text] : [self relayProblemForRequest:request];
        NSRunAlertPanel(@"Connect Commander", @"%@", @"OK", nil, nil, why ? why : @"The relay did not answer.");
        return;
    }
    lines = [[request text] componentsSeparatedByString:@"\n"];
    for (i = 0; i < [lines count]; i++) {
        NSString *line = [lines objectAtIndex:i];
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location != NSNotFound)
            [values setObject:[line substringFromIndex:eq.location + 1] forKey:[line substringToIndex:eq.location]];
    }
    NSRunAlertPanel(@"Connect Commander", @"%@", @"OK", nil, nil,
        [[values objectForKey:@"ok"] isEqualToString:@"1"] ? [values objectForKey:@"message"]
            : [NSString stringWithFormat:@"The key is installed, but the relay could not sign in yet. %@", [values objectForKey:@"message"]]);
    [self refreshToolCatalog];
}

/* Offered once per launch when the relay says it cannot sign in, and the
   relay's Tiger Mac is this one (or none is set yet). */
- (void)maybeOfferSSH
{
    if (offeredSSH || ![commanderCode length])
        return;
    if (![commanderCode isEqualToString:@"auth"] && ![commanderCode isEqualToString:@"unset"]
        && ![commanderCode isEqualToString:@"unlinked"] && ![commanderCode isEqualToString:@"key_missing"])
        return;
    offeredSSH = YES;
    [RelayRequest send:@"GET" path:@"/v1/ssh" body:nil timeout:12 target:self action:@selector(sshStateForOffer:) context:nil];
}

- (void)sshStateForOffer:(RelayRequest *)request
{
    NSString *host = @"";
    NSArray *lines;
    NSArray *mine = [[NSHost currentHost] addresses];
    unsigned i;
    if (![request ok])
        return;
    lines = [[request text] componentsSeparatedByString:@"\n"];
    for (i = 0; i < [lines count]; i++) {
        if ([[lines objectAtIndex:i] hasPrefix:@"host="])
            host = [[lines objectAtIndex:i] substringFromIndex:5];
    }
    if ([host length] > 0 && ![mine containsObject:host])
        return;
    if (NSRunAlertPanel(@"Commander is not set up for this Mac", @"The relay runs Commander's tools on the Mac you chat from, "
        @"and it cannot reach this one yet because SSH is not set up. Set it up now? This adds the relay's key to ~/.ssh/authorized_keys. "
        @"You can also do it later from Configuration, Connect Commander over SSH.", @"Set Up", @"Not Now", nil) == NSAlertDefaultReturn)
        [self connectCommanderSSH:nil];
}

@end
