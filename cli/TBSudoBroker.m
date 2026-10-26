#import "TBSudoBroker.h"
#import "TBSupport.h"
#import "TBSession.h"
#import "TBEngine.h"
#import <Security/Security.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *kSudoService = @"Tiger Build Commander administrator";
static NSString *socketPath = nil;

static NSString *runCommanderWord(NSString *flag)
{
    NSTask *task = [[[NSTask alloc] init] autorelease];
    NSPipe *pipe = [NSPipe pipe];
    NSData *data;
    NSString *program = TBCommanderProgram();
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:program])
        return nil;
    [task setLaunchPath:program];
    [task setArguments:[NSArray arrayWithObjects:@"--sudo", flag, nil]];
    [task setStandardOutput:pipe];
    [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];
    [task setStandardInput:[NSFileHandle fileHandleWithNullDevice]];
    NS_DURING
        [task launch];
        data = [[pipe fileHandleForReading] readDataToEndOfFile];
        [task waitUntilExit];
    NS_HANDLER
        return nil;
    NS_ENDHANDLER
    return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
}

static void answerCommander(int client)
{
    char request[128];
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
    if (strncmp(request, "password ", 9) != 0 || request[got - 1] != '\n')
        return;
    request[got - 1] = 0;
    if (!TBSudoLocalKeyKnown([NSString stringWithUTF8String:request + 9])) {
        const char *refused = "error: administrator mode is not switched on for this chat.\n";
        write(client, refused, strlen(refused));
        return;
    }
    if (SecKeychainFindGenericPassword(NULL, strlen(service), service, strlen(account), account, &length, &data, NULL) == noErr) {
        write(client, data, length);
        write(client, "\n", 1);
        memset(data, 0, length);
        SecKeychainItemFreeContent(NULL, data);
    } else {
        const char *none = "error: no administrator password is saved. Set it in the Tiger Build window: Preferences, Commander.\n";
        write(client, none, strlen(none));
    }
}

@implementation TBSudoBroker

+ (BOOL)administratorModeOn
{
    NSString *reply = runCommanderWord(@"status");
    return reply && [reply hasPrefix:@"on"];
}

+ (void)primeKeychain
{
    const char *service = [kSudoService UTF8String];
    const char *account = [NSUserName() UTF8String];
    UInt32 length = 0;
    void *data = NULL;
    if (SecKeychainFindGenericPassword(NULL, strlen(service), service, strlen(account), account, &length, &data, NULL) == noErr && data) {
        memset(data, 0, length);
        SecKeychainItemFreeContent(NULL, data);
    }
}

+ (void)loop:(NSNumber *)listener
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
        } else if (errno != EINTR && errno != ECONNABORTED) {
            [pool release];
            break;
        }
        [pool release];
    }
}

+ (NSString *)start
{
    NSString *folder = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Tiger Build/commander"];
    NSString *path = [folder stringByAppendingPathComponent:[NSString stringWithFormat:@"sudo-tb-%d.sock", (int)getpid()]];
    struct sockaddr_un address;
    int fd;
    if (socketPath)
        return nil;
    if ([path length] > 100)
        path = [NSString stringWithFormat:@"/tmp/tigerbuild-%d-tb%d.sock", (int)getuid(), (int)getpid()];
    TBMakePath(folder);
    chmod([folder fileSystemRepresentation], 0700);
    unlink([path fileSystemRepresentation]);
    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0)
        return @"no socket";
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, [path fileSystemRepresentation], sizeof(address.sun_path));
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(fd, 4) != 0) {
        close(fd);
        return @"could not listen";
    }
    chmod([path fileSystemRepresentation], 0600);
    socketPath = [path copy];
    TBSudoSetSocketPath(path);
    [NSThread detachNewThreadSelector:@selector(loop:) toTarget:self withObject:[NSNumber numberWithInt:fd]];
    return nil;
}

+ (void)stop
{
    if (socketPath)
        unlink([socketPath fileSystemRepresentation]);
}

@end
