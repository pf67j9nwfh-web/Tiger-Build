#import "ChatController_Private.h"
#import "TBSSHServer.h"
#import "TBHTTP.h"
#import "TBEngine.h"
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

- (void)buildAlertsTab:(NSTabView *)tabs
{
    NSView *tab = [self preferencesTab:@"Alerts" in:tabs];
    float y = 292;
    [self preferencesHeading:@"When a reply finishes" y:y inView:tab];
    y -= 26;
    [self alertsCheck:@"Play a sound when a reply finishes off screen or in the background" key:@"alerts.sound" y:y in:tab];
    y -= 22;
    [self alertsCheck:@"Bounce the Dock icon too, while Tiger Build is in the background" key:@"alerts.bounce" y:y in:tab];
    y -= 32;
    [self preferencesHeading:@"Updates" y:y inView:tab];
    y -= 26;
    [self alertsCheck:@"Look for a newer version when Tiger Build starts" key:@"alerts.updates" y:y in:tab];
    [self preferencesButton:@"Check Now" frame:NSMakeRect(420, y - 6, 116, 28) action:@selector(checkForUpdates:) inView:tab];
    y -= 20;
    [self preferencesNote:@"At most once a day. Asks github.com for the latest release of Tiger Build and tells you if it is newer. Nothing else is sent."
        frame:NSMakeRect(34, y - 14, 380, 30) inView:tab];
    y -= 46;
    [self preferencesHeading:@"Spending limits (estimates)" y:y inView:tab];
    y -= 26;
    [self alertsMoney:@"Stop a reply when its chat has cost more than $" key:@"spend.chat" y:y in:tab];
    y -= 26;
    [self alertsMoney:@"Stop replies when today's total passes $" key:@"spend.day" y:y in:tab];
    y -= 24;
    {
        NSTextField *today = [self preferencesLabel:@"" frame:NSMakeRect(16, y, 520, 16) inView:tab];
        [today setFont:[NSFont systemFontOfSize:11]];
        [prefsFields setObject:today forKey:@"spend.today"];
    }
    [self preferencesNote:@"A blank box means no limit. Costs are estimates, so a limit is approximate: a reply stops when the total passes it, and the chat or day stays "
        @"blocked until you raise or clear the limit."
        frame:NSMakeRect(16, y - 56, 520, 52) inView:tab];
}

- (void)loadAlertOptions
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    double chat = numberOf([defaults objectForKey:@"TBSpendChatLimit"]), day = numberOf([defaults objectForKey:@"TBSpendDayLimit"]);
    [[prefsFields objectForKey:@"lock.auto"] setState:[defaults boolForKey:@"TBLockAtStart"] ? NSOnState : NSOffState];
    [[prefsFields objectForKey:@"quickask.key"] setState:[defaults boolForKey:@"TBQuickAskKey"] ? NSOnState : NSOffState];
    [[prefsFields objectForKey:@"alerts.sound"] setState:flagDefault(@"TBSoundOnFinish", YES) ? NSOnState : NSOffState];
    [[prefsFields objectForKey:@"alerts.bounce"] setState:flagDefault(@"TBBounceOnFinish", YES) ? NSOnState : NSOffState];
    [[prefsFields objectForKey:@"alerts.updates"] setState:flagDefault(@"TBCheckUpdates", YES) ? NSOnState : NSOffState];
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
    [self applyQuickAskHotKey];
    [defaults setBool:[[prefsFields objectForKey:@"alerts.sound"] state] == NSOnState forKey:@"TBSoundOnFinish"];
    [defaults setBool:[[prefsFields objectForKey:@"alerts.bounce"] state] == NSOnState forKey:@"TBBounceOnFinish"];
    [defaults setBool:[[prefsFields objectForKey:@"alerts.updates"] state] == NSOnState forKey:@"TBCheckUpdates"];
    if (chat > 0) [defaults setObject:[NSNumber numberWithDouble:chat] forKey:@"TBSpendChatLimit"]; else [defaults removeObjectForKey:@"TBSpendChatLimit"];
    if (day > 0) [defaults setObject:[NSNumber numberWithDouble:day] forKey:@"TBSpendDayLimit"]; else [defaults removeObjectForKey:@"TBSpendDayLimit"];
}

/* ---- the sound when a reply finishes ---- */

/* offScreen: the reply was in a chat that is not on screen. A reply in the chat you are looking at only makes a sound when the application is in the background. */
- (void)noteReplyFinished:(BOOL)offScreen
{
    BOOL active = [NSApp isActive];
    if (active && !offScreen)
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
        int choice = NSRunAlertPanel([NSString stringWithFormat:@"Tiger Build %@ is available", [tag hasPrefix:@"v"] ? [tag substringFromIndex:1] : tag],
            @"You have version %@. The download page has the new installer and what changed.", @"Open Download Page", @"Not Now", @"Skip This Version", [self thisVersion]);
        if (choice == NSAlertDefaultReturn && [result objectForKey:@"url"])
            [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:[result objectForKey:@"url"]]];
        else if (choice == NSAlertOtherReturn)
            [[NSUserDefaults standardUserDefaults] setObject:tag forKey:@"TBUpdateSkip"];
    }
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
