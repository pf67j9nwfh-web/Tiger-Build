#import "ChatController_Private.h"
#import "TBSSHServer.h"
#import "TBSpotlight.h"
#import "TBSession.h"
#import <unistd.h>
#import "TBHTTP.h"
#import "TBEngine.h"
#import "mbedtls/sha256.h"
#import "TBJSON.h"
#import <Security/Security.h>

/* The small things around the chat: the sound when a reply finishes, spending limits, the check for a newer version, and the uninstaller. Their
   settings are on the Alerts tab of Preferences. */

@interface ChatController (HousekeepingNeeds)
- (NSView *)preferencesTab:(NSString *)label in:(NSTabView *)tabs;
- (NSTextField *)preferencesLabel:(NSString *)text frame:(NSRect)frame inView:(NSView *)view;
- (void)preferencesHeading:(NSString *)text y:(float)y inView:(NSView *)view;
- (NSTextField *)preferencesNote:(NSString *)text frame:(NSRect)frame inView:(NSView *)view;
- (NSButton *)preferencesButton:(NSString *)title frame:(NSRect)frame action:(SEL)action inView:(NSView *)view;
- (void)stopRun:(id)sender;
- (BOOL)enterRunOfTurn:(id)turn orChat:(NSString *)chatId;
- (void)leaveRun;
@end

static BOOL flagDefault(NSString *key, BOOL fallback)
{
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return v ? [v boolValue] : fallback;
}

static double numberOf(id v)
{
    return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 0;
}

/* ---- the download's progress window ---- */

static NSPanel *updatePanel = nil;
static NSProgressIndicator *updateBar = nil;
static NSTextField *updateText = nil;
static volatile int updateCancelled = 0;
static TBHTTP *updateHTTP = nil;

/* Takes the body of the download as it arrives (and ignores the body of a redirect), counting it for the progress window. */
@interface TBUpdateSink : NSObject {
@public
    NSMutableData *data;
    long long total;
    double lastShown;
    id controller;
}
@end

@implementation TBUpdateSink
- (id)init { self = [super init]; data = [[NSMutableData alloc] init]; return self; }
- (void)dealloc { [data release]; [super dealloc]; }
- (BOOL)http:(TBHTTP *)http gotData:(NSData *)piece
{
    double now = CFAbsoluteTimeGetCurrent();
    if ([http status] != 200)
        return NO;
    [data appendData:piece];
    if (total == 0)
    {
        const char *length = [[http responseHeader:@"Content-Length"] UTF8String];   /* none when the body comes in chunks: then only the amount so far is shown */
        total = length ? strtoll(length, NULL, 10) : 0;
        if (total == 0)
            total = -1;
    }
    if (now - lastShown > 0.1) {
        lastShown = now;
        [controller performSelectorOnMainThread:@selector(updateProgress:) withObject:[NSArray arrayWithObjects:[NSNumber numberWithLongLong:[data length]], [NSNumber numberWithLongLong:total], nil] waitUntilDone:NO];
    }
    return NO;
}
@end

@implementation ChatController (Housekeeping)

/* ---- the Alerts tab ---- */

- (NSButton *)alertsCheck:(NSString *)title key:(NSString *)key y:(float)y in:(NSView *)tab
{
    NSButton *button = [[[NSButton alloc] initWithFrame:NSMakeRect(16, y, 520, 20)] autorelease];
    [button setButtonType:NSSwitchButton];
    [button setTitle:title];
    [button setFont:[NSFont systemFontOfSize:12]];
    [tab addSubview:button];
    [prefsFields setObject:button forKey:key];
    return button;
}

- (NSTextField *)alertsMoney:(NSString *)label key:(NSString *)key y:(float)y in:(NSView *)tab
{
    NSTextField *field = [[[NSTextField alloc] initWithFrame:NSMakeRect(420, y - 2, 80, 22)] autorelease];
    [self preferencesLabel:label frame:NSMakeRect(16, y, 400, 18) inView:tab];
    [field setEditable:YES];
    [field setBezeled:YES];
    [field setFont:[NSFont systemFontOfSize:12]];
    [tab addSubview:field];
    [prefsFields setObject:field forKey:key];
    return field;
}

/* ---- Screen: this Mac's screen, mouse and keyboard for other computers and for programs such as Claude Code ---- */

/* what ppc-commander --screen says (on or off), or nil when it cannot be run */
static NSString *runScreenSetting(NSString *flag)
{
    NSTask *task = [[[NSTask alloc] init] autorelease];
    NSPipe *pipe = [NSPipe pipe];
    NSString *text;
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:TBCommanderProgram()])
        return nil;
    [task setLaunchPath:TBCommanderProgram()];
    [task setArguments:[NSArray arrayWithObjects:@"--screen", flag, nil]];
    [task setStandardOutput:pipe];
    [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];
    [task launch];
    text = [[[NSString alloc] initWithData:[[pipe fileHandleForReading] readDataToEndOfFile] encoding:NSUTF8StringEncoding] autorelease];
    [task waitUntilExit];
    return TBTrim(text);
}

/* how another computer's program reaches this Mac's Commander: Tiger Build's own SSH server (port 2222), which runs only Commander */
- (NSString *)commanderReachWord:(NSString *)name
{
    char host[256];
    NSString *address = [[[[self commanderCommand:@"status"] objectForKey:@"ip"] componentsSeparatedByString:@","] objectAtIndex:0];
    gethostname(host, sizeof host);
    if (![address length])
        address = [NSString stringWithUTF8String:host];
    (void)name;
    return [NSString stringWithFormat:@"%@@%@", NSUserName(), TBTrim(address)];
}

- (void)copyClaudeCodeCommand:(id)sender
{
    NSString *target = [self commanderReachWord:nil];
    NSString *sudoKey = [self remoteSudoKeyIfAllowed];
    NSString *text = [NSString stringWithFormat:@"claude mcp add --transport stdio %@mac-%@ -- ssh -p 2222 -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes -o HostKeyAlgorithms=ssh-ed25519 -o PubkeyAcceptedAlgorithms=ssh-ed25519%@ %@ commander",
        sudoKey ? [NSString stringWithFormat:@"-e TB_SUDO_KEY=%@ ", sudoKey] : @"", NSUserName(), sudoKey ? @" -o SendEnv=TB_SUDO_KEY" : @"", target];
    (void)sender;
    [[NSPasteboard generalPasteboard] declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
    [[NSPasteboard generalPasteboard] setString:text forType:NSStringPboardType];
    NSRunAlertPanel(@"Claude Code command copied", @"Run it on the computer that has Claude Code:\n\n%@\n\nThe key (-i) must be one listed under SSH Server, Allowed Keys here, and Allow Other Computers must be on (Commander menu).", @"OK", nil, nil, text);
}

- (void)copyMCPConfig:(id)sender
{
    NSString *target = [self commanderReachWord:nil];
    NSString *sudoKey = [self remoteSudoKeyIfAllowed];
    NSString *text = [NSString stringWithFormat:@"{\n  \"mcpServers\": {\n    \"mac-%@\": {\n      \"command\": \"ssh\",\n      \"args\": [\"-p\", \"2222\", \"-i\", \"~/.ssh/id_ed25519\", \"-o\", \"IdentitiesOnly=yes\", \"-o\", \"HostKeyAlgorithms=ssh-ed25519\", \"-o\", \"PubkeyAcceptedAlgorithms=ssh-ed25519\",%@ \"%@\", \"commander\"]%@\n    }\n  }\n}\n",
        NSUserName(), sudoKey ? @" \"-o\", \"SendEnv=TB_SUDO_KEY\"," : @"", target,
        sudoKey ? [NSString stringWithFormat:@",\n      \"env\": {\"TB_SUDO_KEY\": \"%@\"}", sudoKey] : @""];
    (void)sender;
    [[NSPasteboard generalPasteboard] declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
    [[NSPasteboard generalPasteboard] setString:text forType:NSStringPboardType];
    NSRunAlertPanel(@"MCP settings copied", @"Add this to the MCP settings of the application on the other computer (Claude Desktop, Cursor, and others that use an mcpServers list):\n\n%@", @"OK", nil, nil, text);
}

- (void)buildScreenTab:(NSTabView *)tabs
{
    NSView *tab = [self preferencesTab:@"Screen" in:tabs];
    float y = 292;
    [self preferencesHeading:@"Control this Mac from other computers and programs" y:y inView:tab];
    y -= 26;
    [self alertsCheck:@"Let other computers and programs use this Mac's screen, mouse and keyboard" key:@"screen.allow" y:y in:tab];
    y -= 20;
    [self preferencesNote:@"Through Commander: take_screenshot, screen_click, screen_move, screen_drag, screen_scroll, screen_type and screen_key. It works while someone is logged in at this Mac, "
        @"and acts on whatever is on the screen. For another computer, Allow Other Computers (Commander menu) must be on as well."
        frame:NSMakeRect(34, y - 56, 502, 70) inView:tab];
    y -= 82;
    [self alertsCheck:@"Use screen control without asking first" key:@"screen.noask" y:y in:tab];
    y -= 20;
    [self preferencesNote:@"Applies to this Mac's chats and to the chats of this Tiger Build that use another computer's Commander. Off, each use asks."
        frame:NSMakeRect(34, y - 22, 502, 32) inView:tab];
    y -= 48;
    [self preferencesHeading:@"Use this Mac from Claude Code and other MCP programs" y:y inView:tab];
    y -= 34;
    [self preferencesButton:@"Copy Claude Code Command" frame:NSMakeRect(16, y, 216, 28) action:@selector(copyClaudeCodeCommand:) inView:tab];
    [self preferencesButton:@"Copy MCP Settings" frame:NSMakeRect(240, y, 150, 28) action:@selector(copyMCPConfig:) inView:tab];
    y -= 14;
    [self preferencesNote:@"Commander speaks MCP over standard input and output, so any program that starts an MCP server over SSH can use it (port 2222, a key listed under SSH Server)."
        frame:NSMakeRect(16, y - 36, 520, 40) inView:tab];
}

- (void)buildShellTab:(NSTabView *)tabs
{
    NSView *tab = [self preferencesTab:@"Shell" in:tabs];
    float y = 292;
    NSTextField *field;
    [self preferencesHeading:@"A regular SSH server on this Mac (port 2223)" y:y inView:tab];
    y -= 26;
    [self alertsCheck:@"Allow SSH logins with a shell, sftp and scp" key:@"shell.allow" y:y in:tab];
    y -= 22;
    [self preferencesNote:@"Next to the Commander server (port 2222), which runs only Commander. This one gives a normal login: a terminal, sftp and scp, for the accounts named below, "
        @"with keys only (no passwords, no root, no port forwarding). It uses the same Allowed Keys as the Commander server and the account's own ~/.ssh/authorized_keys, "
        @"so ssh-copy-id -p 2223 works. Turning it on or off asks for the administrator password."
        frame:NSMakeRect(34, y - 66, 502, 82) inView:tab];
    y -= 100;
    [self preferencesLabel:@"Accounts allowed (names, separated by spaces):" frame:NSMakeRect(16, y, 300, 18) inView:tab];
    y -= 26;
    field = [[[NSTextField alloc] initWithFrame:NSMakeRect(16, y, 300, 22)] autorelease];
    [tab addSubview:field];
    [prefsFields setObject:field forKey:@"shell.users"];
    y -= 28;
    [prefsFields setObject:[self preferencesLabel:@"" frame:NSMakeRect(16, y, 520, 18) inView:tab] forKey:@"shell.status"];
    y -= 34;
    [self preferencesButton:@"Allowed Keys..." frame:NSMakeRect(16, y, 140, 28) action:@selector(editAllowedKeys:) inView:tab];
    [self preferencesButton:@"Copy Host Fingerprint" frame:NSMakeRect(162, y, 170, 28) action:@selector(copyHostFingerprint:) inView:tab];
}

- (NSArray *)shellUserNames
{
    NSMutableArray *names = [NSMutableArray array];
    NSMutableString *raw = [NSMutableString stringWithString:[[prefsFields objectForKey:@"shell.users"] stringValue]];
    NSArray *parts;
    [raw replaceOccurrencesOfString:@"," withString:@" " options:0 range:NSMakeRange(0, [raw length])];
    [raw replaceOccurrencesOfString:@"\t" withString:@" " options:0 range:NSMakeRange(0, [raw length])];
    parts = [raw componentsSeparatedByString:@" "];
    unsigned i;
    for (i = 0; i < [parts count]; i++)
        if ([[parts objectAtIndex:i] length])
            [names addObject:[parts objectAtIndex:i]];
    return names;
}

- (void)loadShellOptions
{
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"TBShellUsers"];
    BOOL installed = [TBSSHServer shellInstalled], on = installed && [TBSSHServer shellListening];
    [[prefsFields objectForKey:@"shell.allow"] setState:on ? NSOnState : NSOffState];
    [[prefsFields objectForKey:@"shell.allow"] setEnabled:installed];
    [[prefsFields objectForKey:@"shell.users"] setStringValue:[saved length] ? saved : NSUserName()];
    [[prefsFields objectForKey:@"shell.status"] setStringValue:!installed ? @"Not installed. The Tiger Build installer puts it in /usr/local/tbssh."
        : on ? @"Running on port 2223." : @"Installed and off."];
}

- (void)saveShellOptions
{
    BOOL want = [[prefsFields objectForKey:@"shell.allow"] state] == NSOnState, have = [TBSSHServer shellListening];
    NSArray *names = [self shellUserNames];
    NSString *why, *joined = [names componentsJoinedByString:@" "], *old = [[NSUserDefaults standardUserDefaults] stringForKey:@"TBShellUsers"];
    if (![TBSSHServer shellInstalled])
        return;
    [[NSUserDefaults standardUserDefaults] setObject:joined forKey:@"TBShellUsers"];
    /* a changed list of accounts takes a restart of the server, which is the same step as turning it on */
    if (want == have && !(want && old && ![old isEqualToString:joined]))
        return;
    if (want && NSRunAlertPanel(@"Allow SSH logins to this Mac?",
        @"Computers whose public key is in Allowed Keys (or in the account's ~/.ssh/authorized_keys) will be able to sign in as %@ and run anything that account can, with a terminal, sftp and scp. "
        @"Turn it on only for computers you control.", @"Allow", @"Cancel", nil, [names componentsJoinedByString:@", "]) != NSAlertDefaultReturn)
        return;
    why = [TBSSHServer setShellRunning:want users:names];
    if (why && ![why isEqualToString:@"cancelled"])
        NSRunAlertPanel(want ? @"The SSH server did not start" : @"The SSH server did not stop", @"%@", @"OK", nil, nil, why);
}

- (void)buildAlertsTab:(NSTabView *)tabs
{
    NSView *tab = [self preferencesTab:@"Alerts" in:tabs];
    float y = 292;
    [self preferencesHeading:@"When a reply finishes" y:y inView:tab];
    y -= 26;
    [self alertsCheck:@"Play a sound when a reply finishes off screen or in the background" key:@"alerts.sound" y:y in:tab];
    y -= 22;
    [self alertsCheck:@"Bounce the Dock icon too, while Tiger Build is in the background" key:@"alerts.bounce" y:y in:tab];
    y -= 22;
    [self alertsCheck:@"Play the sound for the chat on screen too, even with Tiger Build in front" key:@"alerts.always" y:y in:tab];
    y -= 30;
    [self preferencesHeading:@"Updates" y:y inView:tab];
    y -= 26;
    [self alertsCheck:@"Look for a newer version when Tiger Build starts" key:@"alerts.updates" y:y in:tab];
    [self preferencesButton:@"Check Now" frame:NSMakeRect(420, y - 6, 116, 28) action:@selector(checkForUpdates:) inView:tab];
    y -= 20;
    [self preferencesNote:@"At most once a day. Asks github.com for the latest release of Tiger Build and tells you if it is newer. Nothing else is sent."
        frame:NSMakeRect(34, y - 14, 380, 30) inView:tab];
    y -= 38;
    [self preferencesHeading:@"Spending limits (estimates)" y:y inView:tab];
    y -= 26;
    [self alertsMoney:@"Stop a reply when its chat has cost more than $" key:@"spend.chat" y:y in:tab];
    y -= 26;
    [self alertsMoney:@"Stop replies when today's total passes $" key:@"spend.day" y:y in:tab];
    y -= 22;
    {
        NSTextField *today = [self preferencesLabel:@"" frame:NSMakeRect(16, y, 520, 16) inView:tab];
        [today setFont:[NSFont systemFontOfSize:11]];
        [prefsFields setObject:today forKey:@"spend.today"];
    }
    [self preferencesNote:@"A blank box means no limit. Costs are estimates, so a limit is approximate; a chat or day stays blocked until you raise or clear it."
        frame:NSMakeRect(16, y - 36, 520, 30) inView:tab];
}

- (void)loadAlertOptions
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    double chat = numberOf([defaults objectForKey:@"TBSpendChatLimit"]), day = numberOf([defaults objectForKey:@"TBSpendDayLimit"]);
    [[prefsFields objectForKey:@"lock.auto"] setState:[defaults boolForKey:@"TBLockAtStart"] ? NSOnState : NSOffState];
    [[prefsFields objectForKey:@"quickask.key"] setState:[defaults boolForKey:@"TBQuickAskKey"] ? NSOnState : NSOffState];
    [[prefsFields objectForKey:@"spotlight.check"] setState:[TBSpotlight enabled] ? NSOnState : NSOffState];
    [[prefsFields objectForKey:@"alerts.sound"] setState:flagDefault(@"TBSoundOnFinish", YES) ? NSOnState : NSOffState];
    [[prefsFields objectForKey:@"alerts.bounce"] setState:flagDefault(@"TBBounceOnFinish", YES) ? NSOnState : NSOffState];
    [[prefsFields objectForKey:@"alerts.always"] setState:flagDefault(@"TBSoundAlways", NO) ? NSOnState : NSOffState];
    [[prefsFields objectForKey:@"alerts.updates"] setState:flagDefault(@"TBCheckUpdates", YES) ? NSOnState : NSOffState];
    [[prefsFields objectForKey:@"screen.allow"] setState:[runScreenSetting(@"status") isEqualToString:@"on"] ? NSOnState : NSOffState];
    [[prefsFields objectForKey:@"screen.noask"] setState:[defaults boolForKey:@"TBScreenNoAsk"] ? NSOnState : NSOffState];
    [[prefsFields objectForKey:@"spend.chat"] setStringValue:chat > 0 ? [NSString stringWithFormat:@"%g", chat] : @""];
    [[prefsFields objectForKey:@"spend.day"] setStringValue:day > 0 ? [NSString stringWithFormat:@"%g", day] : @""];
    [[prefsFields objectForKey:@"spend.today"] setStringValue:[NSString stringWithFormat:@"Spent today, in every chat: about %@.", TBFormatCost([self spendToday])]];
}

- (void)saveAlertOptions
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    double chat = [TBTrim([[prefsFields objectForKey:@"spend.chat"] stringValue]) doubleValue];
    double day = [TBTrim([[prefsFields objectForKey:@"spend.day"] stringValue]) doubleValue];
    [defaults setBool:[[prefsFields objectForKey:@"lock.auto"] state] == NSOnState forKey:@"TBLockAtStart"];
    [defaults setInteger:[[prefsFields objectForKey:@"lock.auto"] state] == NSOnState ? 10 : 0 forKey:@"TBLockIdleMinutes"];
    [defaults setBool:[[prefsFields objectForKey:@"quickask.key"] state] == NSOnState forKey:@"TBQuickAskKey"];
    {
        BOOL want = [[prefsFields objectForKey:@"spotlight.check"] state] == NSOnState;
        if (want != [TBSpotlight enabled]) {
            NSString *why = [TBSpotlight setEnabled:want];
            if (why)
                NSRunAlertPanel(@"Spotlight search of chats", @"%@", @"OK", nil, nil, why);
        }
    }
    [self applyQuickAskHotKey];
    [defaults setBool:[[prefsFields objectForKey:@"alerts.sound"] state] == NSOnState forKey:@"TBSoundOnFinish"];
    [defaults setBool:[[prefsFields objectForKey:@"alerts.bounce"] state] == NSOnState forKey:@"TBBounceOnFinish"];
    [defaults setBool:[[prefsFields objectForKey:@"alerts.always"] state] == NSOnState forKey:@"TBSoundAlways"];
    [defaults setBool:[[prefsFields objectForKey:@"alerts.updates"] state] == NSOnState forKey:@"TBCheckUpdates"];
    runScreenSetting([[prefsFields objectForKey:@"screen.allow"] state] == NSOnState ? @"on" : @"off");
    [defaults setBool:[[prefsFields objectForKey:@"screen.noask"] state] == NSOnState forKey:@"TBScreenNoAsk"];
    if (chat > 0) [defaults setObject:[NSNumber numberWithDouble:chat] forKey:@"TBSpendChatLimit"]; else [defaults removeObjectForKey:@"TBSpendChatLimit"];
    if (day > 0) [defaults setObject:[NSNumber numberWithDouble:day] forKey:@"TBSpendDayLimit"]; else [defaults removeObjectForKey:@"TBSpendDayLimit"];
}

/* ---- the sound when a reply finishes ---- */

/* offScreen: the reply was in a chat that is not on screen. A reply in the chat you are looking at only makes a sound when the application is in the background. */
- (void)noteReplyFinished:(BOOL)offScreen
{
    BOOL active = [NSApp isActive];
    if (active && !offScreen && !flagDefault(@"TBSoundAlways", NO))
        return;
    if (flagDefault(@"TBSoundOnFinish", YES)) {
        NSSound *sound = [NSSound soundNamed:@"Glass"];
        if (sound) {
            [sound stop];
            [sound play];
        }
    }
    if (!active && flagDefault(@"TBBounceOnFinish", YES))
        [NSApp requestUserAttention:NSInformationalRequest];
}

/* ---- spending limits ---- */

static NSString *dayKey(void)
{
    return [[NSDate date] descriptionWithCalendarFormat:@"%Y-%m-%d" timeZone:nil locale:nil];
}

- (double)spendToday
{
    NSDictionary *today = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"TBSpendToday"];
    return [[today objectForKey:@"day"] isEqual:dayKey()] ? numberOf([today objectForKey:@"total"]) : 0;
}

- (double)spendOfChat:(NSDictionary *)chat
{
    NSDictionary *usage = [chat objectForKey:@"usage"];
    NSEnumerator *keys;
    NSString *key;
    double total = 0;
    if (![usage isKindOfClass:[NSDictionary class]])
        return 0;
    keys = [usage keyEnumerator];
    while ((key = [keys nextObject]))
        total += numberOf([[usage objectForKey:key] objectForKey:@"cost"]);
    return total;
}

/* nil when the chat may be used, else what limit it has reached */
- (NSString *)spendLimitProblemForChat:(NSDictionary *)chat
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    double chatLimit = numberOf([defaults objectForKey:@"TBSpendChatLimit"]), dayLimit = numberOf([defaults objectForKey:@"TBSpendDayLimit"]);
    if (chatLimit > 0 && [self spendOfChat:chat] >= chatLimit)
        return [NSString stringWithFormat:@"This chat has reached its spending limit (about %@ of %@). Raise or clear the limit in Preferences, Alerts, or start a new chat.",
            TBFormatCost([self spendOfChat:chat]), TBFormatCost(chatLimit)];
    if (dayLimit > 0 && [self spendToday] >= dayLimit)
        return [NSString stringWithFormat:@"Today's spending limit has been reached (about %@ of %@). Raise or clear it in Preferences, Alerts.",
            TBFormatCost([self spendToday]), TBFormatCost(dayLimit)];
    return nil;
}

/* From the usage line of every model call: adds to today's total and stops the reply when a limit is passed. */
- (void)spendCheckAfterUsage:(NSDictionary *)event chat:(NSMutableDictionary *)chat
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    double cost = numberOf([event objectForKey:@"cost"]);
    NSString *problem;
    if (cost > 0) {
        NSMutableDictionary *daily = [NSMutableDictionary dictionaryWithDictionary:[defaults dictionaryForKey:@"TBSpendDaily"]];
        [defaults setObject:[NSDictionary dictionaryWithObjectsAndKeys:dayKey(), @"day", [NSNumber numberWithDouble:[self spendToday] + cost], @"total", nil]
                     forKey:@"TBSpendToday"];
        [daily setObject:[NSNumber numberWithDouble:[[daily objectForKey:dayKey()] doubleValue] + cost] forKey:dayKey()];
        if ([daily count] > 400) {
            NSArray *old = [[daily allKeys] sortedArrayUsingSelector:@selector(compare:)];
            unsigned k;
            for (k = 0; k < [old count] - 366; k++)
                [daily removeObjectForKey:[old objectAtIndex:k]];
        }
        [defaults setObject:daily forKey:@"TBSpendDaily"];
    }
    problem = [self spendLimitProblemForChat:chat];
    if (problem && [chat objectForKey:@"id"])
        [self performSelector:@selector(spendStop:) withObject:[NSArray arrayWithObjects:[chat objectForKey:@"id"], problem, nil] afterDelay:0];
}

- (void)spendStop:(NSArray *)what
{
    NSString *chatId = [what objectAtIndex:0];
    NSMutableDictionary *chat = [self chatWithId:chatId];
    BOOL entered = NO;
    if (!chat)
        return;
    if (!(busy && streamingId && [streamingId isEqualToString:chatId]))
        entered = [self enterRunOfTurn:nil orChat:chatId];
    if (busy && streamingId && [streamingId isEqualToString:chatId] && !stopping) {
        [self addStatus:[what objectAtIndex:1] toChat:chat];
        [self stopRun:nil];
    }
    if (entered)
        [self leaveRun];
}

/* ---- a newer version ---- */

/* 2.10 is newer than 2.9: compared number by number */
static BOOL versionIsNewer(NSString *candidate, NSString *have)
{
    NSArray *a = [[candidate hasPrefix:@"v"] ? [candidate substringFromIndex:1] : candidate componentsSeparatedByString:@"."];
    NSArray *b = [have componentsSeparatedByString:@"."];
    unsigned i, n = [a count] > [b count] ? [a count] : [b count];
    for (i = 0; i < n; i++) {
        int x = i < [a count] ? [[a objectAtIndex:i] intValue] : 0, y = i < [b count] ? [[b objectAtIndex:i] intValue] : 0;
        if (x != y)
            return x > y;
    }
    return NO;
}

- (NSString *)thisVersion
{
    NSString *v = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return [v length] ? v : @"0";
}

/* On a worker thread: what GitHub says the latest release is. */
- (void)updateWorker:(NSNumber *)manual
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *repo = [[NSUserDefaults standardUserDefaults] stringForKey:@"TBUpdateRepo"];
    TBHTTP *http = [TBHTTP request:@"GET" url:[NSString stringWithFormat:@"https://api.github.com/repos/%@/releases/latest", [repo length] ? repo : @"pf67j9nwfh-web/Tiger-Build"]];
    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithObject:manual forKey:@"manual"];
    int rc;
    [TBHTTP loadRoots];
    [http setHeader:@"User-Agent" value:[@"TigerBuild/" stringByAppendingString:[self thisVersion]]];
    [http setHeader:@"Accept" value:@"application/vnd.github+json"];
    [http setIdleTimeout:20];
    [http setPublicOnly:YES];
    rc = [http perform];
    if (rc != TBNET_OK)
        [result setObject:[http error] ? [http error] : @"The connection failed." forKey:@"error"];
    else if ([http status] == 404)
        [result setObject:@"none" forKey:@"error"];
    else if ([http status] != 200)
        [result setObject:[NSString stringWithFormat:@"GitHub answered with status %d.", [http status]] forKey:@"error"];
    else {
        id json = TBJSONParse([http data], NULL);
        if ([json isKindOfClass:[NSDictionary class]] && [[json objectForKey:@"tag_name"] isKindOfClass:[NSString class]]) {
            [result setObject:[json objectForKey:@"tag_name"] forKey:@"tag"];
            if ([[json objectForKey:@"html_url"] isKindOfClass:[NSString class]])
                [result setObject:[json objectForKey:@"html_url"] forKey:@"url"];
            if ([[json objectForKey:@"name"] isKindOfClass:[NSString class]])
                [result setObject:[json objectForKey:@"name"] forKey:@"name"];
            {
                NSArray *assets = [[json objectForKey:@"assets"] isKindOfClass:[NSArray class]] ? [json objectForKey:@"assets"] : nil;
                unsigned a;
                for (a = 0; a < [assets count]; a++) {
                    NSDictionary *asset = [assets objectAtIndex:a];
                    NSString *aname = TBString(asset, @"name"), *link = TBString(asset, @"browser_download_url");
                    if ([[aname lowercaseString] hasSuffix:@".pkg.zip"] && [link hasPrefix:@"https://github.com/"] && TBInteger(asset, @"size") < 150 * 1024 * 1024) {
                        [result setObject:[NSDictionary dictionaryWithObjectsAndKeys:aname, @"name", link, @"url", TBString(asset, @"digest"), @"digest", nil] forKey:@"asset"];
                        break;
                    }
                }
            }
        } else
            [result setObject:@"GitHub's answer was not understood." forKey:@"error"];
    }
    [self performSelectorOnMainThread:@selector(updateResult:) withObject:result waitUntilDone:NO];
    [pool release];
}

- (void)updateResult:(NSDictionary *)result
{
    BOOL manual = [[result objectForKey:@"manual"] boolValue];
    NSString *tag = [result objectForKey:@"tag"], *error = [result objectForKey:@"error"];
    updateChecking = NO;
    if (error) {
        if (manual)
            NSRunAlertPanel(@"Could not check for updates", @"%@", @"OK", nil, nil,
                [error isEqualToString:@"none"] ? @"No release of Tiger Build has been published on GitHub yet." : error);
        return;
    }
    [[NSUserDefaults standardUserDefaults] setObject:[NSDate date] forKey:@"TBLastUpdateCheck"];
    if (!versionIsNewer(tag, [self thisVersion])) {
        if (manual)
            NSRunAlertPanel(@"Tiger Build is up to date", @"You have version %@, the latest release.", @"OK", nil, nil, [self thisVersion]);
        return;
    }
    if (!manual && [tag isEqualToString:[[NSUserDefaults standardUserDefaults] stringForKey:@"TBUpdateSkip"]])
        return;
    [NSApp activateIgnoringOtherApps:YES];
    {
        BOOL direct = [result objectForKey:@"asset"] != nil;
        int choice = NSRunAlertPanel([NSString stringWithFormat:@"Tiger Build %@ is available", [tag hasPrefix:@"v"] ? [tag substringFromIndex:1] : tag],
            direct ? @"You have version %@. Download the new installer now? It is saved in your Downloads folder (your Desktop on Mac OS X 10.4, which has none) and opens; installing it asks for your administrator password and closes Tiger Build."
                   : @"You have version %@. The download page has the new installer and what changed.",
            direct ? @"Download Installer" : @"Open Download Page", @"Not Now", @"Skip This Version", [self thisVersion]);
        if (choice == NSAlertDefaultReturn && direct)
            [NSThread detachNewThreadSelector:@selector(updateDownloadWorker:) toTarget:self withObject:[result objectForKey:@"asset"]];
        else if (choice == NSAlertDefaultReturn && [result objectForKey:@"url"])
            [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:[result objectForKey:@"url"]]];
        else if (choice == NSAlertOtherReturn)
            [[NSUserDefaults standardUserDefaults] setObject:tag forKey:@"TBUpdateSkip"];
    }
}

- (void)showUpdateProgress:(NSString *)title
{
    NSButton *cancel;
    if (!updatePanel) {
        updatePanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 400, 112) styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
        updateText = [[[NSTextField alloc] initWithFrame:NSMakeRect(20, 74, 360, 18)] autorelease];
        TBStyleAsLabel(updateText);
        updateBar = [[[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 50, 360, 16)] autorelease];
        [updateBar setStyle:NSProgressIndicatorBarStyle];
        [updateBar setIndeterminate:NO];
        [updateBar setMinValue:0];
        [updateBar setMaxValue:100];
        cancel = [[[NSButton alloc] initWithFrame:NSMakeRect(300, 12, 80, 28)] autorelease];
        [cancel setTitle:@"Cancel"];
        [cancel setBezelStyle:NSRoundedBezelStyle];
        [cancel setKeyEquivalent:@"\033"];
        [cancel setTarget:self];
        [cancel setAction:@selector(cancelUpdateDownload:)];
        [[updatePanel contentView] addSubview:updateText];
        [[updatePanel contentView] addSubview:updateBar];
        [[updatePanel contentView] addSubview:cancel];
    }
    updateCancelled = 0;
    [updatePanel setTitle:title];
    [updateText setStringValue:@"Starting the download..."];
    [updateBar setIndeterminate:NO];
    [updateBar setDoubleValue:0];
    [updatePanel center];
    [updatePanel makeKeyAndOrderFront:nil];
}

- (void)cancelUpdateDownload:(id)sender
{
    (void)sender;
    updateCancelled = 1;
    [updateHTTP cancel];
    [updatePanel orderOut:nil];
}

/* {bytes so far, total bytes or 0} from the worker; or a status line (a string) for the steps after the download */
- (void)updateProgress:(id)what
{
    if (![updatePanel isVisible])
        return;
    if ([what isKindOfClass:[NSString class]]) {
        [updateText setStringValue:what];
        [updateBar setIndeterminate:YES];
        [updateBar startAnimation:nil];
        return;
    }
    {
        double done = [[what objectAtIndex:0] doubleValue], total = [[what objectAtIndex:1] doubleValue];
        if (total > 0) {
            [updateBar setIndeterminate:NO];
            [updateBar setDoubleValue:done * 100.0 / total];
            [updateText setStringValue:[NSString stringWithFormat:@"%@ of %@ (%d%%)", TBHumanSize(done), TBHumanSize(total), (int)(done * 100.0 / total)]];
        } else {
            /* the size is not known (GitHub sent the file in chunks): a moving bar and the amount so far */
            [updateBar setIndeterminate:YES];
            [updateBar startAnimation:nil];
            [updateText setStringValue:[NSString stringWithFormat:@"%@ downloaded", TBHumanSize(done)]];
        }
    }
}

/* Where the installer goes: ~/Downloads when it exists; otherwise the Desktop on Tiger (a new account there has no Downloads folder, and Safari
   saves to the Desktop); on later systems ~/Downloads is made. */
- (NSString *)updateFolder
{
    NSString *downloads = [NSHomeDirectory() stringByAppendingPathComponent:@"Downloads"];
    BOOL isDirectory = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:downloads isDirectory:&isDirectory] && isDirectory)
        return downloads;
    if (TBSystemMinor() < 5)
        return [NSHomeDirectory() stringByAppendingPathComponent:@"Desktop"];
    return downloads;
}

/* on a worker thread: the installer's zip from GitHub into the Downloads folder, checked against the digest GitHub gives, unpacked, opened */
- (void)updateDownloadWorker:(NSDictionary *)asset
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *nextURL = [asset objectForKey:@"url"], *problem = nil, *opened = nil;
    int hop;
    NSData *bytes = nil;
    TBUpdateSink *sink = [[[TBUpdateSink alloc] init] autorelease];
    sink->controller = self;
    [TBHTTP loadRoots];
    [self performSelectorOnMainThread:@selector(showUpdateProgress:) withObject:[NSString stringWithFormat:@"Downloading %@", [[asset objectForKey:@"name"] lastPathComponent]] waitUntilDone:YES];
    for (hop = 0; hop < 6 && !bytes && !problem && !updateCancelled; hop++) {
        TBHTTP *http = [TBHTTP request:@"GET" url:nextURL];
        [http setHeader:@"User-Agent" value:[@"TigerBuild/" stringByAppendingString:[self thisVersion]]];
        [http setPublicOnly:YES];
        [http setIdleTimeout:60];
        [http setDelegate:sink];
        [sink->data setLength:0];
        updateHTTP = http;
        if ([http perform] != TBNET_OK) {
            if (!updateCancelled)
                problem = [http error] ? [http error] : @"The download failed.";
            break;
        }
        if ([http status] >= 301 && [http status] <= 308 && [[http responseHeader:@"Location"] length]) {
            NSString *next = [[[NSURL URLWithString:[http responseHeader:@"Location"] relativeToURL:[NSURL URLWithString:nextURL]] absoluteURL] absoluteString];
            if (![[next lowercaseString] hasPrefix:@"https://"]) {
                problem = @"The download was redirected to an address that is not secure.";
                break;
            }
            nextURL = next;
            continue;
        }
        if ([http status] != 200) {
            problem = [NSString stringWithFormat:@"GitHub answered with status %d.", [http status]];
            break;
        }
        bytes = sink->data;
    }
    updateHTTP = nil;
    if (updateCancelled) {
        [pool release];
        return;
    }
    [self performSelectorOnMainThread:@selector(updateProgress:) withObject:@"Checking and unpacking the installer..." waitUntilDone:NO];
    if (!bytes && !problem)
        problem = @"Too many redirects.";
    if (bytes) {
        NSString *digest = [asset objectForKey:@"digest"];
        if ([digest hasPrefix:@"sha256:"]) {
            unsigned char sum[32];
            NSMutableString *hex = [NSMutableString string];
            int i;
            mbedtls_sha256([bytes bytes], [bytes length], sum, 0);
            for (i = 0; i < 32; i++)
                [hex appendFormat:@"%02x", sum[i]];
            if (![[digest substringFromIndex:7] isEqualToString:hex])
                problem = @"The downloaded file does not match the checksum GitHub lists for it, so it was thrown away.";
        }
    }
    if (bytes && !problem) {
        NSString *downloads = [self updateFolder];
        NSString *zip = [downloads stringByAppendingPathComponent:[[asset objectForKey:@"name"] lastPathComponent]];
        NSTask *task;
        [[NSFileManager defaultManager] createDirectoryAtPath:downloads attributes:nil];
        if (![bytes writeToFile:zip atomically:YES])
            problem = [NSString stringWithFormat:@"The installer could not be saved in %@.", [downloads lastPathComponent]];
        else {
            task = [[[NSTask alloc] init] autorelease];
            [task setLaunchPath:@"/usr/bin/ditto"];
            [task setArguments:[NSArray arrayWithObjects:@"-x", @"-k", zip, downloads, nil]];
            @try {
                [task launch];
                [task waitUntilExit];
            } @catch (NSException *e) {
                problem = @"The installer could not be unpacked.";
            }
            if (!problem && [task terminationStatus] != 0)
                problem = @"The installer could not be unpacked.";
            if (!problem) {
                opened = [zip substringToIndex:[zip length] - 4];
                /* the package's scripts are run by the installer, which Tiger and the Leopards need to be told are executable */
                {
                    NSTask *fix = [[[NSTask alloc] init] autorelease];
                    [fix setLaunchPath:@"/bin/chmod"];
                    [fix setArguments:[NSArray arrayWithObjects:@"755", [opened stringByAppendingPathComponent:@"Contents/Resources/postflight"], [opened stringByAppendingPathComponent:@"Contents/Resources/preflight"], nil]];
                    @try { [fix launch]; [fix waitUntilExit]; } @catch (NSException *e) {}
                }
                [[NSFileManager defaultManager] removeFileAtPath:zip handler:nil];
            }
        }
    }
    [self performSelectorOnMainThread:@selector(updateDownloaded:) withObject:[NSDictionary dictionaryWithObjectsAndKeys:problem ? problem : @"", @"problem", opened ? opened : @"", @"opened", nil] waitUntilDone:NO];
    [pool release];
}

- (void)updateDownloaded:(NSDictionary *)result
{
    [updateBar stopAnimation:nil];
    [updatePanel orderOut:nil];
    if ([[result objectForKey:@"problem"] length]) {
        NSRunAlertPanel(@"The installer was not downloaded", @"%@", @"OK", nil, nil, [result objectForKey:@"problem"]);
        return;
    }
    [[NSWorkspace sharedWorkspace] openFile:[result objectForKey:@"opened"]];
}

- (void)checkForUpdates:(id)sender
{
    BOOL manual = sender != nil;
    if (updateChecking)
        return;
    updateChecking = YES;
    [NSThread detachNewThreadSelector:@selector(updateWorker:) toTarget:self withObject:[NSNumber numberWithBool:manual]];
}

- (void)checkForUpdatesAtLaunch
{
    NSDate *last = [[NSUserDefaults standardUserDefaults] objectForKey:@"TBLastUpdateCheck"];
    if (!flagDefault(@"TBCheckUpdates", YES))
        return;
    if (last && [[NSDate date] timeIntervalSinceDate:last] < 20 * 3600)
        return;
    [self checkForUpdates:nil];
}

/* ---- MCP sign-ins ---- */

- (void)forgetMCPSignIns:(id)sender
{
    (void)sender;
    if (NSRunAlertPanel(@"Forget saved sign-ins?", @"Tiger Build will forget the access it was given by MCP servers that ask you to sign in. They will ask you to sign in again the next time they are used.",
        @"Forget", @"Cancel", nil) != NSAlertDefaultReturn)
        return;
    [TBSettings clearName:@"mcp_oauth"];
}

/* ---- the uninstaller ---- */

- (void)uninstallTigerBuild:(id)sender
{
    int choice;
    NSString *problem, *home = nil;
    (void)sender;
    if ([self anyRunActive]) {
        NSBeep();
        return;
    }
    choice = NSRunAlertPanel(@"Uninstall Tiger Build?",
        @"This removes Tiger Build from this Mac: the application, the SSH tools, sshfs and Tiger Build's SSH server in /usr/local/tbssh, and the Quick Look generator. "
        @"It asks for the administrator password, and quits Tiger Build. Your chats, settings and keys stay on the Mac unless you choose to delete them too.",
        @"Cancel", @"Uninstall", @"Uninstall and Delete My Data");
    if (choice == NSAlertDefaultReturn)
        return;
    if (choice == NSAlertOtherReturn) {
        if (NSRunAlertPanel(@"Delete your data too?",
            @"Your chats, workspaces, attached files, settings, SSH keys and the API keys saved in the Keychain will be deleted. This cannot be undone.",
            @"Cancel", @"Delete Everything", nil) != NSAlertAlternateReturn)
            return;
        home = NSHomeDirectory();
    }
    problem = [TBSSHServer uninstallWithData:home];
    if (problem) {
        if (![problem isEqualToString:@"cancelled"])
            NSRunAlertPanel(@"Tiger Build was not uninstalled", @"%@", @"OK", nil, nil, problem);
        return;
    }
    if (home) {
        /* the API keys are one Keychain item of this account's, which the administrator's script cannot reach */
        const char *service = "Tiger Build API keys", *account = "keys";
        SecKeychainItemRef item = NULL;
        if (SecKeychainFindGenericPassword(NULL, strlen(service), service, strlen(account), account, NULL, NULL, &item) == noErr && item) {
            SecKeychainItemDelete(item);
            CFRelease(item);
        }
    }
    /* the script waits for the application to quit before it deletes anything */
    [NSApp terminate:nil];
}

@end
