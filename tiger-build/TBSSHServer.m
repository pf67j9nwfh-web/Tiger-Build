#import "TBSSHServer.h"
#import <Security/Authorization.h>
#import <Security/AuthorizationTags.h>
#import <sys/stat.h>
#import <sys/socket.h>
#import <sys/select.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <unistd.h>
#import <stdio.h>

#define SERVICE @"/usr/local/tbssh/bin/tbssh-service"
#define PORT 2222

/* only a file root owns, that nobody else can change, is run with the administrator's rights */
static BOOL trusted(NSString *path)
{
    struct stat info;
    if (stat([path fileSystemRepresentation], &info) != 0)
        return NO;
    return info.st_uid == 0 && !(info.st_mode & 0022);
}

@implementation TBSSHServer

+ (BOOL)installed
{
    return trusted(SERVICE) && trusted(@"/usr/local/tbssh/sbin/sshd") && trusted(@"/usr/local/tbssh/etc/sshd_config") && trusted(@"/Library/LaunchDaemons/local.tigerbuild.sshd.plist");
}

+ (BOOL)listening
{
    struct sockaddr_in address;
    int fd = socket(AF_INET, SOCK_STREAM, 0), flags, ok = NO;
    fd_set set;
    struct timeval wait = {1, 0};
    if (fd < 0)
        return NO;
    flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    memset(&address, 0, sizeof address);
    address.sin_family = AF_INET;
    address.sin_port = htons(PORT);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *)&address, sizeof address) == 0)
        ok = YES;
    else if (errno == EINPROGRESS) {
        FD_ZERO(&set);
        FD_SET(fd, &set);
        if (select(fd + 1, NULL, &set, NULL, &wait) > 0) {
            int soerr = 0;
            socklen_t len = sizeof soerr;
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &len);
            ok = soerr == 0;
        }
    }
    close(fd);
    return ok;
}

+ (NSString *)setRunning:(BOOL)on
{
    AuthorizationRef auth = NULL;
    const char *path = [SERVICE fileSystemRepresentation];
    char *arguments[2];
    FILE *pipe = NULL;
    OSStatus status;
    int i;
    if (![self installed])
        return @"Tiger Build's SSH server is not installed. Install it with the Tiger Build installer.";
    arguments[0] = on ? "on" : "off";
    arguments[1] = NULL;
    if (AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment, kAuthorizationFlagDefaults, &auth) != errAuthorizationSuccess)
        return @"The administrator dialog could not be opened.";
    {
        AuthorizationItem item = {kAuthorizationRightExecute, strlen(path), (void *)path, 0};
        AuthorizationRights rights = {1, &item};
        AuthorizationFlags flags = kAuthorizationFlagInteractionAllowed | kAuthorizationFlagExtendRights | kAuthorizationFlagPreAuthorize;
        status = AuthorizationCopyRights(auth, &rights, kAuthorizationEmptyEnvironment, flags, NULL);
        if (status == errAuthorizationCanceled) {
            AuthorizationFree(auth, kAuthorizationFlagDefaults);
            return @"cancelled";
        }
        if (status != errAuthorizationSuccess) {
            AuthorizationFree(auth, kAuthorizationFlagDefaults);
            return @"The administrator password was not accepted.";
        }
    }
    status = AuthorizationExecuteWithPrivileges(auth, path, kAuthorizationFlagDefaults, arguments, &pipe);
    if (status != errAuthorizationSuccess) {
        AuthorizationFree(auth, kAuthorizationFlagDefaults);
        return @"The SSH server could not be started with administrator rights.";
    }
    /* Not waited for until the pipe closes: another process can hold it open (on Tiger a launchd that launchctl starts did), so the answer is
       what the port does, for up to ten seconds. */
    if (pipe) {
        int fd = fileno(pipe);
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    }
    for (i = 0; i < 40; i++) {
        char buffer[256];
        if (pipe)
            while (read(fileno(pipe), buffer, sizeof buffer) > 0)
                ;
        if ([self listening] == on)
            break;
        usleep(250000);
    }
    if (pipe)
        fclose(pipe);
    AuthorizationFree(auth, kAuthorizationFlagDefaults);
    if ([self listening] == on)
        return nil;
    return on ? @"The SSH server did not start. See /var/log/tbsshd.log." : @"The SSH server did not stop.";
}

+ (NSString *)uninstallWithData:(NSString *)home
{
    NSString *script = @"/usr/local/tbssh/bin/tiger-build-uninstall";
    AuthorizationRef auth = NULL;
    const char *path = [script fileSystemRepresentation];
    char *arguments[3];
    FILE *pipe = NULL;
    OSStatus status;
    if (!trusted(script))
        return @"The uninstaller was not found. Tiger Build was probably not put here by its installer; quit it and drag Tiger Build to the Trash.";
    if ([home length] && [home hasPrefix:@"/Users/"]) {
        arguments[0] = "--data";
        arguments[1] = (char *)[home fileSystemRepresentation];
        arguments[2] = NULL;
    } else
        arguments[0] = NULL;
    if (AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment, kAuthorizationFlagDefaults, &auth) != errAuthorizationSuccess)
        return @"The administrator dialog could not be opened.";
    {
        AuthorizationItem item = {kAuthorizationRightExecute, strlen(path), (void *)path, 0};
        AuthorizationRights rights = {1, &item};
        AuthorizationFlags flags = kAuthorizationFlagInteractionAllowed | kAuthorizationFlagExtendRights | kAuthorizationFlagPreAuthorize;
        status = AuthorizationCopyRights(auth, &rights, kAuthorizationEmptyEnvironment, flags, NULL);
        if (status != errAuthorizationSuccess) {
            AuthorizationFree(auth, kAuthorizationFlagDefaults);
            return status == errAuthorizationCanceled ? @"cancelled" : @"The administrator password was not accepted.";
        }
    }
    status = AuthorizationExecuteWithPrivileges(auth, path, kAuthorizationFlagDefaults, arguments, &pipe);
    /* the script goes on by itself once Tiger Build has quit; the pipe and the authorization are left for the process to end with */
    if (status != errAuthorizationSuccess) {
        AuthorizationFree(auth, kAuthorizationFlagDefaults);
        return @"The uninstaller could not be started with administrator rights.";
    }
    return nil;
}

+ (NSString *)authorizedKeysPath
{
    NSString *folder = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Tiger Build/ssh"];
    NSFileManager *m = [NSFileManager defaultManager];
    if (![m fileExistsAtPath:folder]) {
        NSString *parent = [folder stringByDeletingLastPathComponent];
        [m createDirectoryAtPath:[parent stringByDeletingLastPathComponent] attributes:nil];
        [m createDirectoryAtPath:parent attributes:nil];
        [m createDirectoryAtPath:folder attributes:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:0700] forKey:NSFilePosixPermissions]];
    }
    return [folder stringByAppendingPathComponent:@"authorized_keys"];
}

+ (NSString *)authorizedKeys
{
    NSString *text = [NSString stringWithContentsOfFile:[self authorizedKeysPath] encoding:NSUTF8StringEncoding error:NULL];
    return text ? text : @"";
}

+ (BOOL)saveAuthorizedKeys:(NSString *)text
{
    NSString *path = [self authorizedKeysPath];
    NSMutableString *clean = [NSMutableString string];
    NSArray *lines = [text componentsSeparatedByString:@"\n"];
    unsigned i;
    /* one public key per line; a line may not start with options (command=, no-pty ...) so a key cannot carry its own permissions */
    for (i = 0; i < [lines count]; i++) {
        NSString *line = [[lines objectAtIndex:i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([line length] && ([line hasPrefix:@"ssh-"] || [line hasPrefix:@"ecdsa-"] || [line hasPrefix:@"sk-"]))
            [clean appendFormat:@"%@\n", line];
    }
    if (![clean writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL])
        return NO;
    [[NSFileManager defaultManager] changeFileAttributes:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:0600] forKey:NSFilePosixPermissions] atPath:path];
    return YES;
}

+ (NSString *)hostFingerprint
{
    NSTask *task = [[[NSTask alloc] init] autorelease];
    NSPipe *out = [NSPipe pipe];
    NSString *keygen = [[[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"ssh"] stringByAppendingPathComponent:@"ssh-keygen"], *text;
    if (![[NSFileManager defaultManager] fileExistsAtPath:@"/usr/local/tbssh/etc/ssh_host_ed25519_key.pub"])
        return nil;
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:keygen])
        keygen = @"/usr/local/tbssh/bin/ssh-keygen";
    [task setLaunchPath:keygen];
    [task setArguments:[NSArray arrayWithObjects:@"-lf", @"/usr/local/tbssh/etc/ssh_host_ed25519_key.pub", nil]];
    [task setStandardOutput:out];
    [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];
    NS_DURING
        [task launch];
        text = [[[NSString alloc] initWithData:[[out fileHandleForReading] readDataToEndOfFile] encoding:NSUTF8StringEncoding] autorelease];
        [task waitUntilExit];
    NS_HANDLER
        return nil;
    NS_ENDHANDLER
    return [text length] ? [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : nil;
}

@end
