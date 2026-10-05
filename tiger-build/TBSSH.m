#import "TBSSH.h"
#import "TBEngine.h"
#import <sys/stat.h>
#import <sys/select.h>
#import <unistd.h>

static NSString *folder(void)
{
    NSString *f = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Tiger Build/ssh"];
    NSFileManager *m = [NSFileManager defaultManager];
    if (![m fileExistsAtPath:f]) {
        NSString *parent = [f stringByDeletingLastPathComponent];
        [m createDirectoryAtPath:[parent stringByDeletingLastPathComponent] attributes:nil];
        [m createDirectoryAtPath:parent attributes:nil];
        [m createDirectoryAtPath:f attributes:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:0700] forKey:NSFilePosixPermissions]];
    }
    return f;
}

static NSString *keyPath(void) { return [folder() stringByAppendingPathComponent:@"id_rsa"]; }
static NSString *knownPath(void) { return [folder() stringByAppendingPathComponent:@"known_hosts"]; }
static NSString *pendingPath(void) { return [folder() stringByAppendingPathComponent:@"pending_host"]; }

/* a program run to the end, with its output; nil if it could not start. Gives up after `seconds`. */
static NSString *run(NSString *path, NSArray *args, int *status, int seconds)
{
    NSTask *task = [[[NSTask alloc] init] autorelease];
    NSPipe *out = [NSPipe pipe];
    NSMutableData *all = [NSMutableData data];
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    NSFileHandle *reader = [out fileHandleForReading];
    [task setLaunchPath:path];
    [task setArguments:args];
    [task setStandardOutput:out];
    [task setStandardError:out];
    [task setStandardInput:[NSFileHandle fileHandleWithNullDevice]];
    NS_DURING
        [task launch];
    NS_HANDLER
        return nil;
    NS_ENDHANDLER
    /* read as it comes so a full pipe never stalls the program */
    {
        int fd = [reader fileDescriptor];
        while ([task isRunning] && [end timeIntervalSinceNow] > 0) {
            fd_set set;
            struct timeval tv = {0, 100000};
            FD_ZERO(&set);
            FD_SET(fd, &set);
            if (select(fd + 1, &set, NULL, NULL, &tv) > 0) {
                unsigned char buffer[4096];
                ssize_t n = read(fd, buffer, sizeof buffer);
                if (n > 0)
                    [all appendBytes:buffer length:n];
            }
        }
        if ([task isRunning]) {
            [task terminate];
            if (status)
                *status = -1;
        } else {
            [task waitUntilExit];
            if (status)
                *status = [task terminationStatus];
            [all appendData:[reader availableData]];
        }
    }
    return [[[NSString alloc] initWithData:all encoding:NSUTF8StringEncoding] autorelease];
}

@implementation TBSSH

+ (NSString *)host { NSString *v = [[NSUserDefaults standardUserDefaults] stringForKey:@"TBSSHHost"]; return v ? TBTrim(v) : @""; }
+ (NSString *)user { NSString *v = [[NSUserDefaults standardUserDefaults] stringForKey:@"TBSSHUser"]; return v ? TBTrim(v) : @""; }
+ (BOOL)enabled { return [[self host] length] > 0 && [[self user] length] > 0; }

+ (NSString *)home
{
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:@"TBSSHHome"];
    NSString *h = saved ? TBTrim(saved) : @"";
    return [h length] ? h : [@"/Users/" stringByAppendingString:[self user]];
}

+ (void)setHost:(NSString *)host user:(NSString *)user home:(NSString *)home
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:TBTrim(host) forKey:@"TBSSHHost"];
    [d setObject:TBTrim(user) forKey:@"TBSSHUser"];
    [d setObject:TBTrim(home) forKey:@"TBSSHHome"];
    [d synchronize];
}

+ (void)clear
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d removeObjectForKey:@"TBSSHHost"];
    [d removeObjectForKey:@"TBSSHUser"];
    [d removeObjectForKey:@"TBSSHHome"];
    [d synchronize];
}

+ (NSString *)publicKey
{
    NSString *pub = [keyPath() stringByAppendingString:@".pub"];
    NSFileManager *m = [NSFileManager defaultManager];
    if (![m fileExistsAtPath:keyPath()] || ![m fileExistsAtPath:pub]) {
        int status = 0;
        [m removeFileAtPath:keyPath() handler:nil];
        [m removeFileAtPath:pub handler:nil];
        /* RSA: the old Macs' OpenSSH has nothing newer, and every server still understands it. */
        run(@"/usr/bin/ssh-keygen", [NSArray arrayWithObjects:@"-q", @"-t", @"rsa", @"-b", @"2048", @"-N", @"", @"-C", @"tiger-build", @"-f", keyPath(), nil], &status, 60);
        if (status != 0)
            return nil;
    }
    return TBTrim([NSString stringWithContentsOfFile:pub encoding:NSUTF8StringEncoding error:NULL]);
}

+ (BOOL)validHost:(NSString *)host
{
    unsigned i;
    if (![host length] || [host length] > 253 || [host hasPrefix:@"-"])
        return NO;
    for (i = 0; i < [host length]; i++) {
        unichar c = [host characterAtIndex:i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '_' || c == ':'))
            return NO;
    }
    return YES;
}

+ (NSString *)fingerprintOfHost:(NSString *)host problem:(NSString **)problem
{
    int status = 0;
    NSString *keys, *lines, *print;
    NSArray *pieces;
    unsigned i;
    host = TBTrim(host);
    if (![self validHost:host]) {
        *problem = @"That is not a usable address.";
        return nil;
    }
    keys = run(@"/usr/bin/ssh-keyscan", [NSArray arrayWithObjects:@"-T", @"10", @"-t", @"rsa", host, nil], &status, 20);
    lines = @"";
    pieces = [keys componentsSeparatedByString:@"\n"];
    for (i = 0; i < [pieces count]; i++)
        if ([[pieces objectAtIndex:i] length] && ![[pieces objectAtIndex:i] hasPrefix:@"#"])
            lines = [lines stringByAppendingFormat:@"%@\n", [pieces objectAtIndex:i]];
    if (![lines length]) {
        *problem = [NSString stringWithFormat:@"%@ did not answer on the SSH port. Check the address, and that Remote Login is on in System Preferences, Sharing.", host];
        return nil;
    }
    if (![lines writeToFile:pendingPath() atomically:YES encoding:NSUTF8StringEncoding error:NULL]) {
        *problem = @"Tiger Build could not save the host key.";
        return nil;
    }
    print = run(@"/usr/bin/ssh-keygen", [NSArray arrayWithObjects:@"-l", @"-f", pendingPath(), nil], &status, 15);
    return [TBTrim(print) length] ? TBTrim(print) : lines;
}

+ (BOOL)trustHost:(NSString *)host problem:(NSString **)problem
{
    NSString *seen = [NSString stringWithContentsOfFile:pendingPath() encoding:NSUTF8StringEncoding error:NULL];
    NSString *known = [NSString stringWithContentsOfFile:knownPath() encoding:NSUTF8StringEncoding error:NULL];
    (void)host;
    if (![seen length]) {
        *problem = @"Look at the host's key first.";
        return NO;
    }
    if (![[known ? known : @"" stringByAppendingString:seen] writeToFile:knownPath() atomically:YES encoding:NSUTF8StringEncoding error:NULL]) {
        *problem = @"Tiger Build could not save the host key.";
        return NO;
    }
    [[NSFileManager defaultManager] removeFileAtPath:pendingPath() handler:nil];
    return YES;
}

+ (void)forgetHost:(NSString *)host
{
    int status = 0;
    run(@"/usr/bin/ssh-keygen", [NSArray arrayWithObjects:@"-R", TBTrim(host), @"-f", knownPath(), nil], &status, 15);
}

+ (NSArray *)baseArguments
{
    return [NSArray arrayWithObjects:@"-T", @"-i", keyPath(), @"-o", @"IdentitiesOnly=yes", @"-o", @"BatchMode=yes", @"-o", @"PreferredAuthentications=publickey",
        @"-o", @"StrictHostKeyChecking=yes", @"-o", [@"UserKnownHostsFile=" stringByAppendingString:knownPath()], @"-o", @"ConnectTimeout=12",
        @"-o", @"ServerAliveInterval=20", @"-o", @"ServerAliveCountMax=6", [NSString stringWithFormat:@"%@@%@", [self user], [self host]], nil];
}

+ (NSArray *)commandArgumentsRunning:(NSString *)remoteCommand problem:(NSString **)problem
{
    NSMutableArray *args;
    if (![self enabled]) {
        *problem = @"No other Mac is set up.";
        return nil;
    }
    if (![self validHost:[self host]]) {
        *problem = @"The other Mac's address is not usable.";
        return nil;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:knownPath()]) {
        *problem = @"The other Mac's key is not trusted yet. Open Preferences, Commander, and choose Trust.";
        return nil;
    }
    args = [NSMutableArray arrayWithArray:[self baseArguments]];
    [args addObject:remoteCommand];
    return args;
}

+ (NSString *)installCommanderFrom:(NSString *)localPath
{
    NSData *code = [NSData dataWithContentsOfFile:localPath];
    NSMutableArray *args = [NSMutableArray arrayWithArray:[self baseArguments]];
    NSTask *task = [[[NSTask alloc] init] autorelease];
    NSPipe *in = [NSPipe pipe], *out = [NSPipe pipe];
    NSString *text;
    if (![code length])
        return @"The bundled Commander could not be read.";
    [args addObject:@"mkdir -p \"$HOME/ppc-commander\" && cat > \"$HOME/ppc-commander/ppc_commander.py\" && echo tiger-build-installed"];
    [task setLaunchPath:@"/usr/bin/ssh"];
    [task setArguments:args];
    [task setStandardInput:in];
    [task setStandardOutput:out];
    [task setStandardError:out];
    NS_DURING
        [task launch];
        [[in fileHandleForWriting] writeData:code];
        [[in fileHandleForWriting] closeFile];
        text = [[[NSString alloc] initWithData:[[out fileHandleForReading] readDataToEndOfFile] encoding:NSUTF8StringEncoding] autorelease];
        [task waitUntilExit];
    NS_HANDLER
        return @"ssh could not be started.";
    NS_ENDHANDLER
    return [text rangeOfString:@"tiger-build-installed"].location != NSNotFound ? nil : ([TBTrim(text) length] ? TBTrim(text) : @"The copy failed.");
}

+ (NSString *)test
{
    NSString *problem = nil, *text, *low;
    int status = 0;
    NSMutableArray *args;
    if (![self publicKey])
        return @"Tiger Build could not make its SSH key.";
    if (!([self commandArgumentsRunning:@"echo tiger-build-ok" problem:&problem]))
        return problem;
    args = [NSMutableArray arrayWithArray:[self baseArguments]];
    [args addObject:@"echo tiger-build-ok"];
    text = run(@"/usr/bin/ssh", args, &status, 30);
    if (status == 0 && [text rangeOfString:@"tiger-build-ok"].location != NSNotFound)
        return nil;
    low = [text lowercaseString];
    if ([low rangeOfString:@"permission denied"].location != NSNotFound)
        return [NSString stringWithFormat:@"%@ refused the key. Add Tiger Build's public key to ~/.ssh/authorized_keys on that Mac (use Copy Public Key). "
            @"A recent macOS may also need ssh-rsa switched on for this key.", [self host]];
    if ([low rangeOfString:@"host key verification failed"].location != NSNotFound || [low rangeOfString:@"host key"].location != NSNotFound)
        return @"The other Mac's key changed. If that is expected, choose Forget and Trust again.";
    if ([low rangeOfString:@"timed out"].location != NSNotFound || status == -1)
        return @"The other Mac did not answer. Check its address and that it is awake.";
    if ([low rangeOfString:@"refused"].location != NSNotFound)
        return @"The other Mac refused the connection. Turn on Remote Login in System Preferences, Sharing.";
    return [TBTrim(text) length] ? TBTrim(text) : @"The SSH connection failed.";
}

@end
