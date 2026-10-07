#import "CMCore.h"
#import <sys/stat.h>
#import <sys/ioctl.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/select.h>
#import <sys/wait.h>
#import <util.h>
#import <signal.h>
#import <unistd.h>
#import <fcntl.h>
#import <termios.h>
#import <pthread.h>

#define MAX_PROCESS_OUTPUT 1500000

/* ---- running a program with no shell and no terminal (git, svn, sw_vers ...) ---- */

NSString *CMFindProgram(NSString *name)
{
    NSArray *dirs = [[NSString stringWithUTF8String:getenv("PATH") ? getenv("PATH") : "/usr/bin:/bin"] componentsSeparatedByString:@":"];
    NSMutableArray *all = [NSMutableArray arrayWithArray:dirs];
    unsigned i;
    [all addObjectsFromArray:[NSArray arrayWithObjects:@"/usr/bin", @"/usr/local/bin", @"/usr/local/git/bin", @"/opt/local/bin", @"/sw/bin", @"/opt/homebrew/bin", nil]];
    for (i = 0; i < [all count]; i++) {
        NSString *folder = [all objectAtIndex:i], *path;
        if (![folder length])
            continue;
        path = [folder stringByAppendingPathComponent:name];
        if (access([path fileSystemRepresentation], X_OK) == 0) {
            struct stat st;
            if (stat([path fileSystemRepresentation], &st) == 0 && S_ISREG(st.st_mode))
                return path;
        }
    }
    return nil;
}

int CMRunProgram(NSArray *argv, NSString *cwd, double timeout, NSDictionary *environment, NSString **output)
{
    int fds[2], status = 0, timedOut = 0;
    pid_t pid;
    NSMutableData *collected = [NSMutableData data];
    NSDate *started = [NSDate date];
    unsigned i, n = [argv count];
    char **cargv = calloc(n + 1, sizeof(char *));
    char *chdirTo = cwd ? strdup([cwd fileSystemRepresentation]) : NULL;
    NSMutableArray *envKeys = [NSMutableArray array];
    char **keys = NULL, **values = NULL;
    unsigned envCount = 0;
    for (i = 0; i < n; i++)
        cargv[i] = strdup([[argv objectAtIndex:i] fileSystemRepresentation]);
    if (environment) {
        [envKeys addObjectsFromArray:[environment allKeys]];
        envCount = [envKeys count];
        keys = calloc(envCount + 1, sizeof(char *));
        values = calloc(envCount + 1, sizeof(char *));
        for (i = 0; i < envCount; i++) {
            keys[i] = strdup([[envKeys objectAtIndex:i] UTF8String]);
            values[i] = strdup([[[environment objectForKey:[envKeys objectAtIndex:i]] description] UTF8String]);
        }
    }
    if (pipe(fds) != 0)
        CMFail(@"cannot make a pipe");
    pid = fork();
    if (pid == 0) {
        int null = open("/dev/null", O_RDONLY);
        close(fds[0]);
        dup2(fds[1], 1);
        dup2(fds[1], 2);
        dup2(null, 0);
        if (chdirTo && chdir(chdirTo) != 0)
            _exit(127);
        for (i = 0; i < envCount; i++)
            setenv(keys[i], values[i], 1);
        execv(cargv[0], cargv);
        _exit(127);
    }
    close(fds[1]);
    for (i = 0; i < n; i++)
        free(cargv[i]);
    free(cargv);
    free(chdirTo);
    for (i = 0; i < envCount; i++) {
        free(keys[i]);
        free(values[i]);
    }
    free(keys);
    free(values);
    for (;;) {
        double left = timeout - (-[started timeIntervalSinceNow]);
        fd_set set;
        struct timeval tv;
        if (left <= 0) {
            timedOut = 1;
            break;
        }
        FD_ZERO(&set);
        FD_SET(fds[0], &set);
        tv.tv_sec = (long)(left < 1.0 ? left : 1.0);
        tv.tv_usec = (long)(((left < 1.0 ? left : 1.0) - tv.tv_sec) * 1000000);
        if (select(fds[0] + 1, &set, NULL, NULL, &tv) > 0) {
            unsigned char buffer[8192];
            ssize_t got = read(fds[0], buffer, sizeof buffer);
            if (got <= 0)
                break;
            if ([collected length] < 360000)
                [collected appendBytes:buffer length:got];
        }
    }
    if (timedOut)
        kill(pid, SIGKILL);
    close(fds[0]);
    waitpid(pid, &status, 0);
    if (output)
        *output = CMDecode(collected, NULL);
    if (timedOut)
        return -1;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128;
}

/* ---- terminal sessions ---- */

@interface CMSession : NSObject {
@public
    pid_t pid;
    int fd;
    NSString *command;
    NSMutableData *buffer;
    unsigned long long dropped;
    BOOL exited;
    int exitCode;
    NSDate *started;
    unsigned consumedLines;
    pthread_mutex_t lock;
}
- (void)append:(NSData *)data;
@end

@implementation CMSession

- (id)init
{
    self = [super init];
    buffer = [[NSMutableData alloc] init];
    started = [[NSDate date] retain];
    exitCode = -1;
    pthread_mutex_init(&lock, NULL);
    return self;
}

- (void)append:(NSData *)data
{
    pthread_mutex_lock(&lock);
    [buffer appendData:data];
    if ([buffer length] > MAX_PROCESS_OUTPUT) {
        unsigned cut = [buffer length] - MAX_PROCESS_OUTPUT;
        [buffer replaceBytesInRange:NSMakeRange(0, cut) withBytes:NULL length:0];
        dropped += cut;
        consumedLines = 0;
    }
    pthread_mutex_unlock(&lock);
}

@end

static NSMutableDictionary *sessions = nil;

static NSString *normalizeNewlines(NSString *text)
{
    NSString *t = [[text componentsSeparatedByString:@"\r\n"] componentsJoinedByString:@"\n"];
    return [[t componentsSeparatedByString:@"\r"] componentsJoinedByString:@"\n"];
}

static int decodeStatus(int status)
{
    if (WIFEXITED(status))
        return WEXITSTATUS(status);
    if (WIFSIGNALED(status))
        return 128 + WTERMSIG(status);
    return status;
}

/* one thread per session reads what the program writes */
static void *readLoop(void *arg)
{
    CMSession *s = (CMSession *)arg;
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    unsigned char chunk[4096];
    int status = 0;
    for (;;) {
        ssize_t n = read(s->fd, chunk, sizeof chunk);
        if (n <= 0)
            break;
        [s append:[NSData dataWithBytes:chunk length:n]];
        [pool release];
        pool = [[NSAutoreleasePool alloc] init];
    }
    if (waitpid(s->pid, &status, 0) > 0)
        s->exitCode = decodeStatus(status);
    pthread_mutex_lock(&s->lock);
    s->exited = YES;
    pthread_mutex_unlock(&s->lock);
    close(s->fd);
    s->fd = -1;
    [pool release];
    return NULL;
}

/* text so far, how much was dropped, whether it ended, the lines already handed out */
static NSString *snapshot(CMSession *s, unsigned long long *dropped, BOOL *exited, unsigned *consumed)
{
    NSString *text;
    pthread_mutex_lock(&s->lock);
    text = normalizeNewlines(CMDecode(s->buffer, NULL));
    *dropped = s->dropped;
    *exited = s->exited;
    *consumed = s->consumedLines;
    pthread_mutex_unlock(&s->lock);
    return text;
}

static unsigned long long currentSize(CMSession *s)
{
    unsigned long long n;
    pthread_mutex_lock(&s->lock);
    n = [s->buffer length] + s->dropped;
    pthread_mutex_unlock(&s->lock);
    return n;
}

static void waitSession(CMSession *s, unsigned long long startSize, double timeoutMs)
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeoutMs / 1000.0], *lastChange = [NSDate date];
    unsigned long long last = startSize;
    for (;;) {
        unsigned long long cur = currentSize(s);
        BOOL done;
        if (cur != last) {
            last = cur;
            lastChange = [NSDate date];
        }
        pthread_mutex_lock(&s->lock);
        done = s->exited;
        pthread_mutex_unlock(&s->lock);
        if (done) {
            usleep(50000);
            return;
        }
        if (cur > startSize && -[lastChange timeIntervalSinceNow] >= 0.4)
            return;
        if ([deadline timeIntervalSinceNow] <= 0)
            return;
        usleep(50000);
    }
}

static CMSession *sessionFor(long long pid)
{
    CMSession *s = [sessions objectForKey:[NSNumber numberWithLongLong:pid]];
    if (!s)
        CMFail(@"no terminal session for pid %lld. start_process creates sessions. list_processes shows every process, but only commander sessions have captured output.", pid);
    return s;
}

static NSString *formatSession(CMSession *s, NSString *body, unsigned start, unsigned end, unsigned total, NSString *note)
{
    unsigned long long dropped;
    BOOL exited;
    unsigned consumed;
    NSMutableArray *lines = [NSMutableArray array];
    snapshot(s, &dropped, &exited, &consumed);
    [lines addObject:[NSString stringWithFormat:@"pid: %d", (int)s->pid]];
    [lines addObject:[NSString stringWithFormat:@"command: %@", CMClip(s->command, 400)]];
    if (exited) {
        [lines addObject:@"status: exited"];
        [lines addObject:[NSString stringWithFormat:@"exit_code: %d", s->exitCode]];
    } else
        [lines addObject:@"status: running"];
    [lines addObject:[NSString stringWithFormat:@"elapsed_ms: %d", (int)(-[s->started timeIntervalSinceNow] * 1000)]];
    if (dropped)
        [lines addObject:[NSString stringWithFormat:@"dropped_bytes: %llu", dropped]];
    if ([note length])
        [lines addObject:note];
    [lines addObject:[NSString stringWithFormat:@"output_lines: %u-%u of %u (process lines are 0-based in this range)", start, end, total]];
    [lines addObject:@"---"];
    [lines addObject:body];
    return CMCap([lines componentsJoinedByString:@"\n"]);
}

/* the lines to hand out: new ones, or from an offset; a plain read moves the "already read" mark */
static NSString *page(CMSession *s, long long offset, long long length, BOOL newOnly, unsigned *startOut, unsigned *endOut, unsigned *totalOut)
{
    unsigned long long dropped;
    BOOL exited, advance = NO;
    unsigned consumed, total, start, end;
    NSArray *lines = CMSplitLines(snapshot(s, &dropped, &exited, &consumed));
    total = [lines count];
    if (newOnly || offset == 0) {
        start = consumed;
        advance = YES;
    } else if (offset < 0)
        start = (long long)total + offset < 0 ? 0 : (unsigned)((long long)total + offset);
    else
        start = (unsigned)(offset - 1);
    if (start > total)
        start = total;
    end = start + (unsigned)length > total ? total : start + (unsigned)length;
    if (advance) {
        pthread_mutex_lock(&s->lock);
        s->consumedLines = end;
        pthread_mutex_unlock(&s->lock);
    }
    *startOut = start;
    *endOut = end;
    *totalOut = total;
    return [[lines subarrayWithRange:NSMakeRange(start, end - start)] componentsJoinedByString:@"\n"];
}

/* ---- administrator (sudo) ---- */

static NSString *sudoSocketPath(void)
{
    NSString *path = [CMStateFolder() stringByAppendingPathComponent:@"sudo.sock"];
    if ([path length] > 100)
        path = [NSString stringWithFormat:@"/tmp/tigerbuild-%d-sudo.sock", (int)getuid()];
    return path;
}

/* The password, from the running Tiger Build, over a socket only this account can use. Never shown to the model. */
static NSString *sudoPassword(void)
{
    NSString *path = sudoSocketPath();
    NSString *notRunning = @"the administrator password is held by Tiger Build, which is not running on this Mac. Open Tiger Build there, and check that administrator mode is on for this chat.";
    int sock;
    struct sockaddr_un addr;
    char buffer[2048];
    ssize_t got, total = 0;
    struct timeval tv = {90, 0};
    NSString *line;
    if (access([path fileSystemRepresentation], F_OK) != 0)
        CMFail(@"%@", notRunning);
    sock = socket(AF_UNIX, SOCK_STREAM, 0);
    memset(&addr, 0, sizeof addr);
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, [path fileSystemRepresentation], sizeof addr.sun_path - 1);
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    if (connect(sock, (struct sockaddr *)&addr, sizeof addr) != 0) {
        close(sock);
        CMFail(@"%@", notRunning);
    }
    write(sock, "password\n", 9);
    while (total < (ssize_t)sizeof buffer - 1 && !memchr(buffer, '\n', total)) {
        got = read(sock, buffer + total, sizeof buffer - 1 - total);
        if (got <= 0)
            break;
        total += got;
    }
    close(sock);
    buffer[total] = 0;
    line = [[[NSString stringWithUTF8String:buffer] componentsSeparatedByString:@"\n"] objectAtIndex:0];
    if ([line hasPrefix:@"error:"])
        CMFail(@"%@", [[line substringFromIndex:6] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
    if (![line length])
        CMFail(@"Tiger Build sent no administrator password");
    return line;
}

/* (command to run, read end of a pipe holding the password or -1): the password reaches sudo through a file descriptor that is
   closed before the model's command starts, so it is in no command line, file or environment. */
static NSString *withSudo(NSString *command, BOOL detach, int *pipeOut)
{
    int fds[2];
    NSString *password, *prefix;
    *pipeOut = -1;
    if (![CMCommandWords(command) containsObject:@"sudo"])
        return command;
    if (!CMSudoEnabled())
        CMFail(@"administrator (sudo) commands are off. A person can turn them on in Tiger Build: the Tools menu of the chat, Administrator (sudo). Do not try to work around this.");
    if (detach)
        CMFail(@"sudo cannot be used with detach. Run it in the foreground.");
    password = sudoPassword();
    if ([password length] > 1000)
        CMFail(@"the saved administrator password is too long");
    if (pipe(fds) != 0)
        CMFail(@"cannot make a pipe");
    {
        NSData *bytes = [[password stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
        write(fds[1], [bytes bytes], [bytes length]);
        close(fds[1]);
    }
    prefix = [NSString stringWithFormat:@"sudo -S -v -p \"\" <&%d 2>/dev/null || { echo \"sudo: the saved administrator password was not accepted. A person can set it again in Tiger Build.\" >&2; exit 1; }; exec %d<&-; ", fds[0], fds[0]];
    *pipeOut = fds[0];
    return [prefix stringByAppendingString:command];
}

/* ---- starting and talking to programs ---- */

static pid_t detachCommand(NSString *command, NSString *shell)
{
    int fds[2];
    pid_t pid;
    char text[64];
    ssize_t got;
    char *cshell = strdup([shell fileSystemRepresentation]), *ccommand = strdup([command UTF8String]), *chdirTo = [CMWorkspaceRoot() length] ? strdup([CMWorkspaceRoot() fileSystemRepresentation]) : NULL;
    char *shellName = strdup([[shell lastPathComponent] fileSystemRepresentation]);
    if (pipe(fds) != 0)
        CMFail(@"cannot make a pipe");
    pid = fork();
    if (pid == 0) {
        pid_t second;
        int null;
        close(fds[0]);
        setsid();
        second = fork();
        if (second != 0) {
            char buffer[32];
            int n = snprintf(buffer, sizeof buffer, "%d\n", (int)second);
            write(fds[1], buffer, n);
            _exit(0);
        }
        close(fds[1]);
        signal(SIGHUP, SIG_IGN);
        if (chdirTo)
            chdir(chdirTo);
        null = open("/dev/null", O_RDWR);
        dup2(null, 0);
        dup2(null, 1);
        dup2(null, 2);
        if (null > 2)
            close(null);
        execl(cshell, shellName, "-c", ccommand, (char *)NULL);
        _exit(127);
    }
    close(fds[1]);
    got = read(fds[0], text, sizeof text - 1);
    close(fds[0]);
    waitpid(pid, NULL, 0);
    free(cshell);
    free(ccommand);
    free(chdirTo);
    free(shellName);
    if (got <= 0)
        CMFail(@"could not detach the process");
    text[got] = 0;
    if (atoi(text) <= 0)
        CMFail(@"could not detach the process");
    return (pid_t)atoi(text);
}

id CMToolStartProcess(NSDictionary *args)
{
    NSString *command = CMString(args, @"command"), *shell = [CMConfig() objectForKey:@"defaultShell"], *chosen = CMOptString(args, @"shell", nil), *why, *shown, *run;
    long long timeout = CMOptInteger(args, @"timeout_ms", 10000);
    BOOL detach = CMOptBool(args, @"detach", NO);
    int passwordPipe;
    struct winsize size = {40, 120, 0, 0};
    int master;
    pid_t pid;
    CMSession *s;
    BOOL isDir = NO;
    char *cshell, *ccommand, *shellName, *chdirTo;
    if (![[command stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length])
        CMFail(@"command is empty");
    if (timeout < 0) timeout = 0;
    if (timeout > 120000) timeout = 120000;
    if (![shell isKindOfClass:[NSString class]])
        shell = @"/bin/bash";
    if (chosen && [chosen length])
        shell = chosen;
    if (access([shell fileSystemRepresentation], X_OK) != 0)
        CMFail(@"shell does not exist: %@", shell);
    why = CMWhyBlocked(command);
    if (why)
        CMFail(@"blocked command (%@). Change blockedCommands only if you mean to.", why);
    if ([CMWorkspaceRoot() length] && !([[NSFileManager defaultManager] fileExistsAtPath:CMWorkspaceRoot() isDirectory:&isDir] && isDir))
        CMFail(@"this workspace is limited to %@, which does not exist on this Mac. Change the directory in the workspace settings.", CMWorkspaceRoot());
    why = CMWorkspaceCommandProblem(command);
    if (why)
        CMFail(@"blocked by the workspace directory restriction: %@", why);
    shown = command;
    run = withSudo(command, detach, &passwordPipe);
    if (detach) {
        pid_t child = detachCommand(run, shell);
        return CMCap([NSString stringWithFormat:@"pid: %d\ncommand: %@\nstatus: detached\nnote: running on its own; closing the chat will not stop it", (int)child, CMClip(run, 400)]);
    }
    cshell = strdup([shell fileSystemRepresentation]);
    ccommand = strdup([run UTF8String]);
    shellName = strdup([[shell lastPathComponent] fileSystemRepresentation]);
    chdirTo = [CMWorkspaceRoot() length] ? strdup([CMWorkspaceRoot() fileSystemRepresentation]) : NULL;
    pid = forkpty(&master, NULL, NULL, &size);
    if (pid == 0) {
        if (chdirTo)
            chdir(chdirTo);
        setenv("TERM", "vt100", 1);
        setenv("LANG", "C", 1);
        setenv("LC_ALL", "C", 1);
        execl(cshell, shellName, "-c", ccommand, (char *)NULL);
        _exit(127);
    }
    free(cshell);
    free(ccommand);
    free(shellName);
    free(chdirTo);
    if (pid < 0)
        CMFail(@"cannot start the program: %s", strerror(errno));
    if (passwordPipe >= 0)
        close(passwordPipe);
    s = [[[CMSession alloc] init] autorelease];
    s->pid = pid;
    s->fd = master;
    s->command = [shown retain];
    if (!sessions)
        sessions = [[NSMutableDictionary alloc] init];
    {
        pthread_t thread;
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        [s retain];
        pthread_create(&thread, &attr, readLoop, s);
        pthread_attr_destroy(&attr);
    }
    [sessions setObject:s forKey:[NSNumber numberWithLongLong:pid]];
    if ([sessions count] > 40) {
        NSEnumerator *each = [[sessions allValues] objectEnumerator];
        CMSession *other;
        CMSession *oldest = nil;
        while ((other = [each nextObject]))
            if (other->exited && other != s && (!oldest || [other->started compare:oldest->started] == NSOrderedAscending))
                oldest = other;
        if (oldest)
            [sessions removeObjectForKey:[NSNumber numberWithLongLong:oldest->pid]];
    }
    waitSession(s, 0, (double)timeout);
    {
        unsigned start, end, total;
        NSString *body = page(s, 0, [[CMConfig() objectForKey:@"fileReadLineLimit"] longLongValue], YES, &start, &end, &total);
        BOOL done;
        pthread_mutex_lock(&s->lock);
        done = s->exited;
        pthread_mutex_unlock(&s->lock);
        return formatSession(s, body, start, end, total, done ? @"" : @"still running; use read_process_output or interact_with_process with this pid");
    }
}

id CMToolInteract(NSDictionary *args)
{
    long long pid = CMInteger(args, @"pid"), timeout = CMOptInteger(args, @"timeout_ms", 5000);
    NSString *input = CMString(args, @"input");
    CMSession *s = sessionFor(pid);
    NSData *bytes = [input dataUsingEncoding:NSUTF8StringEncoding];
    unsigned long long before;
    unsigned start, end, total;
    NSString *body;
    BOOL done;
    NSString *why = CMWhyBlocked(input);
    if (!why)
        why = CMWorkspaceCommandProblem(input);
    if (why)
        CMFail(@"blocked: %@. The same rules apply to what is typed into a running program as to a new command.", why);
    if ([CMCommandWords(input) containsObject:@"sudo"] && !CMSudoEnabled())
        CMFail(@"administrator (sudo) commands are off. A person can turn them on in Tiger Build: the Tools menu of the chat, Administrator (sudo). Do not try to work around this.");
    if (timeout < 0) timeout = 0;
    if (timeout > 120000) timeout = 120000;
    pthread_mutex_lock(&s->lock);
    done = s->exited || s->fd < 0;
    pthread_mutex_unlock(&s->lock);
    if (done)
        CMFail(@"process %lld is not running", pid);
    before = currentSize(s);
    if (write(s->fd, [bytes bytes], [bytes length]) < 0)
        CMFail(@"write failed: %s", strerror(errno));
    waitSession(s, before, (double)timeout);
    body = page(s, 0, [[CMConfig() objectForKey:@"fileReadLineLimit"] longLongValue], YES, &start, &end, &total);
    return formatSession(s, body, start, end, total, [NSString stringWithFormat:@"input sent (%u bytes)", (unsigned)[bytes length]]);
}

id CMToolReadOutput(NSDictionary *args)
{
    long long pid = CMInteger(args, @"pid"), timeout = CMOptInteger(args, @"timeout_ms", 0), length = CMOptInteger(args, @"length", [[CMConfig() objectForKey:@"fileReadLineLimit"] longLongValue]), offset = 0;
    CMSession *s = sessionFor(pid);
    BOOL newOnly = YES;
    unsigned start, end, total;
    NSString *body;
    if (timeout > 0) {
        if (timeout > 120000) timeout = 120000;
        waitSession(s, currentSize(s), (double)timeout);
    }
    if (length < 1) length = 1;
    if (length > 5000) length = 5000;
    if ([args objectForKey:@"offset"] && [args objectForKey:@"offset"] != [NSNull null]) {
        offset = CMInteger(args, @"offset");
        newOnly = (offset == 0);
    }
    body = page(s, offset, length, newOnly, &start, &end, &total);
    return formatSession(s, body, start, end, total, @"");
}

id CMToolForceTerminate(NSDictionary *args)
{
    long long pid = CMInteger(args, @"pid");
    CMSession *s;
    NSDate *deadline;
    if (pid <= 1 || pid == getpid() || pid == getppid())
        CMFail(@"refusing to kill pid %lld", pid);
    s = sessionFor(pid);
    if (s->exited)
        return [NSString stringWithFormat:@"pid %lld already exited with %d", pid, s->exitCode];
    if (kill(-(pid_t)pid, SIGKILL) != 0 && kill((pid_t)pid, SIGKILL) != 0)
        CMFail(@"kill failed: %s", strerror(errno));
    deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
    while ([deadline timeIntervalSinceNow] > 0 && !s->exited)
        usleep(50000);
    if (s->exited)
        return [NSString stringWithFormat:@"killed %lld (exit_code %d)", pid, s->exitCode];
    return [NSString stringWithFormat:@"sent SIGKILL to %lld", pid];
}

id CMToolListSessions(NSDictionary *args)
{
    NSMutableArray *lines = [NSMutableArray array];
    NSEnumerator *each = [sessions objectEnumerator];
    CMSession *s;
    (void)args;
    if (![sessions count])
        return @"no terminal sessions";
    while ((s = [each nextObject]))
        [lines addObject:[NSString stringWithFormat:@"pid %d %@ %@", (int)s->pid, s->exited ? [NSString stringWithFormat:@"exited:%d", s->exitCode] : @"running", CMClip(s->command, 160)]];
    return [lines componentsJoinedByString:@"\n"];
}

id CMToolListProcesses(NSDictionary *args)
{
    NSString *out = nil;
    NSMutableArray *lines;
    (void)args;
    CMRunProgram([NSArray arrayWithObjects:@"/bin/ps", @"auxww", nil], nil, 10, nil, &out);
    lines = [NSMutableArray arrayWithArray:[out componentsSeparatedByString:@"\n"]];
    if ([lines count] > 250) {
        [lines removeObjectsInRange:NSMakeRange(250, [lines count] - 250)];
        [lines addObject:@"... truncated"];
    }
    return [lines componentsJoinedByString:@"\n"];
}

id CMToolKillProcess(NSDictionary *args)
{
    long long pid = CMInteger(args, @"pid");
    CMSession *s;
    if (pid <= 1 || pid == getpid() || pid == getppid())
        CMFail(@"refusing to kill pid %lld", pid);
    if (kill((pid_t)pid, SIGTERM) != 0)
        CMFail(@"kill failed: %s", strerror(errno));
    s = [sessions objectForKey:[NSNumber numberWithLongLong:pid]];
    if (s && !s->exited)
        kill(-(pid_t)pid, SIGTERM);
    return [NSString stringWithFormat:@"sent SIGTERM to %lld", pid];
}

void CMShutdownSessions(void)
{
    NSEnumerator *each = [sessions objectEnumerator];
    CMSession *s;
    while ((s = [each nextObject]))
        if (!s->exited && s->pid > 1 && kill(-s->pid, SIGTERM) != 0)
            kill(s->pid, SIGTERM);
}

/* ---- pictures ---- */

static NSData *fileBytes(NSString *path)
{
    return [NSData dataWithContentsOfFile:path];
}

id CMToolScreenshot(NSDictionary *args)
{
    long long width = CMOptInteger(args, @"max_width", 1024);
    NSString *stamp = [NSString stringWithFormat:@"%d-%d", (int)getpid(), (int)time(NULL)], *png = [NSString stringWithFormat:@"/tmp/ppc-shot-%@.png", stamp], *jpg = [NSString stringWithFormat:@"/tmp/ppc-shot-%@.jpg", stamp];
    NSData *data;
    int code;
    struct stat st;
    if (width < 320) width = 320;
    if (width > 2048) width = 2048;
    @try {
        code = CMRunProgram([NSArray arrayWithObjects:@"/usr/sbin/screencapture", @"-x", png, nil], nil, 20, nil, NULL);
        if (code != 0 || stat([png fileSystemRepresentation], &st) != 0 || st.st_size == 0)
            CMFail(@"could not capture the screen. Someone must be logged in at this Mac, the display must be awake, and the command must be started from that login (not over SSH on 10.5 and later).");
        CMRunProgram([NSArray arrayWithObjects:@"/usr/bin/sips", @"-Z", [NSString stringWithFormat:@"%lld", width], @"-s", @"format", @"jpeg", @"-s", @"formatOptions", @"60", png, @"--out", jpg, nil], nil, 30, nil, NULL);
        data = fileBytes(jpg);
        if (![data length])
            CMFail(@"could not shrink the screenshot");
        return [NSDictionary dictionaryWithObjectsAndKeys:[NSString stringWithFormat:@"Screenshot of the main display (%u bytes, JPEG).", (unsigned)[data length]], @"text", CMBase64(data), @"image", @"image/jpeg", @"mime", nil];
    } @finally {
        unlink([png fileSystemRepresentation]);
        unlink([jpg fileSystemRepresentation]);
    }
    return nil;
}

id CMToolViewImage(NSDictionary *args)
{
    NSString *path = CMCheckPath(CMOptString(args, @"path", @""));
    long long width = CMOptInteger(args, @"max_width", 1280);
    NSString *jpg = [NSString stringWithFormat:@"/tmp/ppc-view-%d-%d.jpg", (int)getpid(), (int)time(NULL)];
    struct stat st;
    NSData *data;
    if (stat([path fileSystemRepresentation], &st) != 0 || !S_ISREG(st.st_mode))
        CMFail(@"not a file: %@", path);
    if (width < 160) width = 160;
    if (width > 2048) width = 2048;
    if (st.st_size > 200 * 1024 * 1024)
        CMFail(@"file is larger than 200 MB");
    @try {
        CMRunProgram([NSArray arrayWithObjects:@"/usr/bin/sips", @"-Z", [NSString stringWithFormat:@"%lld", width], @"-s", @"format", @"jpeg", @"-s", @"formatOptions", @"70", path, @"--out", jpg, nil], nil, 60, nil, NULL);
        data = fileBytes(jpg);
        if (![data length])
            CMFail(@"this Mac could not read %@ as a picture. Use list_directory or get_file_info to check it is an image (JPEG, PNG, GIF, TIFF, BMP, PDF, icns).", path);
        if ([data length] > 4000000)
            CMFail(@"the picture is still too large after shrinking; try a smaller max_width");
        return [NSDictionary dictionaryWithObjectsAndKeys:[NSString stringWithFormat:@"Picture %@, shrunk to at most %lld pixels wide (%u bytes, JPEG).", path, width, (unsigned)[data length]], @"text",
            CMBase64(data), @"image", @"image/jpeg", @"mime", nil];
    } @finally {
        unlink([jpg fileSystemRepresentation]);
    }
    return nil;
}
