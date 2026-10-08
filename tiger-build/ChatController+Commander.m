#import "ChatController_Private.h"
#include <sys/types.h>
#include <sys/socket.h>
#include <net/if.h>
#include <ifaddrs.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/select.h>
#import "TBSession.h"
#include <netinet/in.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <signal.h>

/* The Commander menu. Commander is the program inside the app that lets chats read files and run commands on this Mac.
   It starts with each chat that uses it, and nothing listens on the network. Another computer can use this Mac's
   Commander over SSH only when "Allow Other Computers" is on. The state is a few marker files in
   ~/Library/Application Support/Tiger Build/commander: disabled (Stop), remote-access (Allow Other Computers). */

static NSString *stateFolder(void)
{
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Tiger Build/commander"];
}

static NSString *marker(NSString *name)
{
    return [stateFolder() stringByAppendingPathComponent:name];
}

static void setMarker(NSString *name, BOOL on)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *private = [NSDictionary dictionaryWithObject:[NSNumber numberWithInt:0700] forKey:NSFilePosixPermissions];
    if (on) {
        NSString *folder = stateFolder();
        [fm createDirectoryAtPath:[[folder stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] attributes:nil];
        [fm createDirectoryAtPath:[folder stringByDeletingLastPathComponent] attributes:nil];
        [fm createDirectoryAtPath:folder attributes:private];
        [@"on\n" writeToFile:marker(name) atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } else
        [fm removeFileAtPath:marker(name) handler:nil];
}

/* the IPv4 addresses of this Mac other than loopback */
static NSString *addresses(void)
{
    struct ifaddrs *list = NULL, *p;
    NSMutableArray *found = [NSMutableArray array];
    if (getifaddrs(&list) != 0)
        return @"";
    for (p = list; p; p = p->ifa_next) {
        char text[32];
        struct sockaddr_in *a;
        const char *n = p->ifa_name;
        if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET || !(p->ifa_flags & IFF_UP))
            continue;
        /* virtual adapters (Parallels, VMware, VirtualBox, tunnels, bridges) are not how another computer reaches this Mac */
        if (!strncmp(n, "vnic", 4) || !strncmp(n, "vmnet", 5) || !strncmp(n, "vboxnet", 7) || !strncmp(n, "bridge", 6) || !strncmp(n, "utun", 4) || !strncmp(n, "tun", 3) || !strncmp(n, "tap", 3))
            continue;
        a = (struct sockaddr_in *)p->ifa_addr;
        if (ntohl(a->sin_addr.s_addr) >> 24 == 127 || !inet_ntop(AF_INET, &a->sin_addr, text, sizeof text))
            continue;
        [found addObject:[NSString stringWithUTF8String:text]];
    }
    freeifaddrs(list);
    return [found componentsJoinedByString:@", "];
}

/* whether something answers on this Mac's SSH port (Remote Login in System Preferences, Sharing) */
static BOOL remoteLoginOn(void)
{
    struct sockaddr_in a;
    int fd = socket(AF_INET, SOCK_STREAM, 0), flags;
    fd_set set;
    struct timeval wait = {1, 0};
    BOOL up = NO;
    if (fd < 0)
        return NO;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons(22);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    if (connect(fd, (struct sockaddr *)&a, sizeof a) == 0)
        up = YES;
    else if (errno == EINPROGRESS) {
        FD_ZERO(&set);
        FD_SET(fd, &set);
        if (select(fd + 1, NULL, &set, NULL, &wait) > 0) {
            int err = 0;
            socklen_t n = sizeof err;
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &n);
            up = err == 0;
        }
    }
    close(fd);
    return up;
}

/* Commander programs other computers have running here, from the files each leaves while it runs */
static void endSessions(void)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *names = [fm directoryContentsAtPath:stateFolder()];
    unsigned i;
    for (i = 0; i < [names count]; i++) {
        NSString *name = [names objectAtIndex:i];
        if ([name hasPrefix:@"session-"]) {
            int pid = [[name substringFromIndex:8] intValue];
            if (pid > 1)
                kill(pid, SIGTERM);
            [fm removeFileAtPath:marker(name) handler:nil];
        }
    }
}

BOOL TBCommanderRemoteAllowed(void)
{
    return [[NSFileManager defaultManager] fileExistsAtPath:marker(@"remote-access")];
}

/* The login item: Tiger Build starts hidden when this person logs in, so other computers can use Commander without anyone opening it.
   It is a normal entry in System Preferences, Accounts, Login Items. */
static NSString *loginItemPath(void)
{
    return [[NSBundle mainBundle] bundlePath];
}

static NSArray *loginItems(void)
{
    id list = [(id)CFPreferencesCopyValue(CFSTR("AutoLaunchedApplicationDictionary"), CFSTR("loginwindow"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost) autorelease];
    return [list isKindOfClass:[NSArray class]] ? list : [NSArray array];
}

@implementation ChatController (Commander)

/* start, stop, remote-on, remote-off, status. Returns enabled, remote, ip as strings. */
- (NSDictionary *)commanderCommand:(NSString *)command
{
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([command isEqualToString:@"start"])
        setMarker(@"disabled", NO);
    else if ([command isEqualToString:@"stop"]) {
        setMarker(@"disabled", YES);
        endSessions();
    } else if ([command isEqualToString:@"remote-on"])
        setMarker(@"remote-access", YES);
    else if ([command isEqualToString:@"remote-off"]) {
        setMarker(@"remote-access", NO);
        endSessions();
        [self setLoginLaunch:NO];
        [self setRemoteSudo:NO];
    }
    return [NSDictionary dictionaryWithObjectsAndKeys:[fm fileExistsAtPath:marker(@"disabled")] ? @"0" : @"1", @"enabled",
        [fm fileExistsAtPath:marker(@"remote-access")] ? @"1" : @"0", @"remote", addresses(), @"ip", nil];
}

- (BOOL)loginLaunchOn
{
    NSArray *items = loginItems();
    unsigned i;
    for (i = 0; i < [items count]; i++)
        if ([[[items objectAtIndex:i] objectForKey:@"Path"] isEqualToString:loginItemPath()])
            return YES;
    return NO;
}

- (void)setLoginLaunch:(BOOL)on
{
    NSMutableArray *items = [NSMutableArray array];
    NSArray *old = loginItems();
    unsigned i;
    if (on == [self loginLaunchOn])
        return;
    for (i = 0; i < [old count]; i++)
        if (![[[old objectAtIndex:i] objectForKey:@"Path"] isEqualToString:loginItemPath()])
            [items addObject:[old objectAtIndex:i]];
    if (on)
        [items addObject:[NSDictionary dictionaryWithObjectsAndKeys:loginItemPath(), @"Path", [NSNumber numberWithBool:YES], @"Hide", nil]];
    CFPreferencesSetValue(CFSTR("AutoLaunchedApplicationDictionary"), items, CFSTR("loginwindow"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize(CFSTR("loginwindow"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
}

- (void)refreshCommanderStatus
{
    [commanderCache release];
    commanderCache = [[self commanderCommand:@"status"] retain];
}

- (void)commanderStart:(id)sender
{
    [self commanderCommand:@"start"];
    [TBSession forgetCommanderTools];
    [self refreshCommanderStatus];
    [self menuNeedsUpdate:[sender menu]];
}

- (void)commanderStop:(id)sender
{
    if (NSRunAlertPanel(@"Stop Commander?", @"Commander tool sessions that are open, here or from other computers, will close. "
        @"No chat can use Commander until you choose Start.", @"Stop", @"Cancel", nil) != NSAlertDefaultReturn)
        return;
    [self commanderCommand:@"stop"];
    [TBSession forgetCommanderTools];
    [self refreshCommanderStatus];
    [self menuNeedsUpdate:[sender menu]];
}

- (void)commanderRemote:(id)sender
{
    BOOL on = [[[self commanderCommand:@"status"] objectForKey:@"remote"] intValue] != 0;
    if (!on && NSRunAlertPanel(@"Allow other computers to use this Mac?",
        @"Another computer that can sign in to this Mac over SSH will be able to read and change files and run commands here as you, "
        @"through Commander. Turn it on only for computers you control. Remote Login must also be on in System Preferences, Sharing.",
        @"Allow", @"Cancel", nil) != NSAlertDefaultReturn)
        return;
    [self commanderCommand:on ? @"remote-off" : @"remote-on"];
    [self refreshCommanderStatus];
    [self menuNeedsUpdate:[sender menu]];
}

- (void)commanderIP:(id)sender
{
    NSDictionary *state = [self commanderCommand:@"status"];
    NSString *ip = [state objectForKey:@"ip"], *user = NSUserName();
    BOOL remote = [[state objectForKey:@"remote"] intValue] != 0;
    (void)sender;
    NSRunInformationalAlertPanel(@"This Mac", @"%@\n%@\n\nIPv4 addresses: %@\n\n%@\n\nTo use this Mac from another computer running Tiger Build, add it there under "
        @"Tool Settings, MCP Servers, Add, \"Commander on another computer\": address %@@%@.", @"OK", nil, nil,
        [TBMachine name], [TBMachine systemVersion], [ip length] ? ip : @"none active",
        remote ? (remoteLoginOn() ? @"Other computers are allowed, and Remote Login is on." : @"Other computers are allowed, but Remote Login is off: turn it on in System Preferences, Sharing.")
               : @"Other computers are not allowed (Commander > Allow Other Computers).",
        user, [ip length] ? [[ip componentsSeparatedByString:@","] objectAtIndex:0] : @"address");
}

- (void)menuNeedsUpdate:(NSMenu *)menu
{
    NSDictionary *state;
    BOOL enabled;
    if (![[menu title] isEqualToString:@"Commander"])
        return;
    state = [self commanderCommand:@"status"];
    enabled = [[state objectForKey:@"enabled"] intValue] != 0;
    [[menu itemAtIndex:0] setTitle:enabled ? @"Commander: On" : @"Commander: Off"];
    [[menu itemAtIndex:1] setEnabled:!enabled];
    [[menu itemAtIndex:2] setEnabled:enabled];
    [[menu itemAtIndex:4] setState:[[state objectForKey:@"remote"] intValue] != 0 ? NSOnState : NSOffState];
    [[menu itemAtIndex:5] setTitle:[NSString stringWithFormat:@"IP: %@", [[state objectForKey:@"ip"] length] ? [state objectForKey:@"ip"] : @"unavailable"]];
}

@end
