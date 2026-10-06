#import "CMCore.h"
#import "TBJSON.h"
#import <mach-o/dyld.h>
#import <sys/stat.h>
#import <regex.h>
#import <stdarg.h>
#import <unistd.h>

NSString *const CMFailure = @"CMFailure";

#define MAX_OUTPUT_CHARS 180000
#define HISTORY_MAX_BYTES 150000
#define HISTORY_KEEP_LINES 200

static NSMutableDictionary *config = nil;
static NSMutableDictionary *usage = nil;
static NSMutableDictionary *sysinfo = nil;
static NSString *workspaceRoot = @"";
static NSLock *recordLock = nil;

/* ---- errors and arguments ---- */

void CMFail(NSString *format, ...)
{
    va_list args;
    NSString *text;
    va_start(args, format);
    text = [[[NSString alloc] initWithFormat:format arguments:args] autorelease];
    va_end(args);
    [NSException raise:CMFailure format:@"%@", text];
}

void CMLog(NSString *format, ...)
{
    va_list args;
    NSString *text;
    va_start(args, format);
    text = [[[NSString alloc] initWithFormat:format arguments:args] autorelease];
    va_end(args);
    fprintf(stderr, "[ppc-commander] %s\n", [text UTF8String]);
    fflush(stderr);
}

NSString *CMOptString(NSDictionary *args, NSString *key, NSString *fallback)
{
    id v = [args objectForKey:key];
    if (!v || v == [NSNull null])
        return fallback;
    if (![v isKindOfClass:[NSString class]])
        CMFail(@"expected a string for %@", key);
    return v;
}

NSString *CMString(NSDictionary *args, NSString *key)
{
    NSString *v = CMOptString(args, key, nil);
    if (!v)
        CMFail(@"missing %@", key);
    return v;
}

static long long integerOf(id v, NSString *key)
{
    double d;
    if (![v isKindOfClass:[NSNumber class]] || (CFGetTypeID(v) == CFBooleanGetTypeID()))
        CMFail(@"expected a number for %@", key);
    d = [v doubleValue];
    if (d != (double)(long long)d)
        CMFail(@"expected an integer for %@", key);
    return (long long)d;
}

long long CMInteger(NSDictionary *args, NSString *key)
{
    id v = [args objectForKey:key];
    if (!v || v == [NSNull null])
        CMFail(@"missing %@", key);
    return integerOf(v, key);
}

long long CMOptInteger(NSDictionary *args, NSString *key, long long fallback)
{
    id v = [args objectForKey:key];
    if (!v || v == [NSNull null])
        return fallback;
    return integerOf(v, key);
}

BOOL CMOptBool(NSDictionary *args, NSString *key, BOOL fallback)
{
    id v = [args objectForKey:key];
    if (!v || v == [NSNull null])
        return fallback;
    if (!([v isKindOfClass:[NSNumber class]] && CFGetTypeID(v) == CFBooleanGetTypeID()))
        CMFail(@"expected a boolean for %@", key);
    return [v boolValue];
}

NSArray *CMStringList(id value)
{
    NSMutableArray *out = [NSMutableArray array];
    unsigned i;
    if (![value isKindOfClass:[NSArray class]])
        CMFail(@"expected an array of strings");
    for (i = 0; i < [value count]; i++) {
        if (![[value objectAtIndex:i] isKindOfClass:[NSString class]])
            CMFail(@"expected a string");
        [out addObject:[value objectAtIndex:i]];
    }
    return out;
}

NSString *CMClip(NSString *text, unsigned limit)
{
    if (!text)
        return @"";
    if ([text length] <= limit)
        return text;
    return [NSString stringWithFormat:@"%@...(%u chars)", [text substringToIndex:limit], (unsigned)[text length]];
}

NSString *CMCap(NSString *text)
{
    if ([text length] <= MAX_OUTPUT_CHARS)
        return text;
    return [[text substringToIndex:MAX_OUTPUT_CHARS] stringByAppendingFormat:@"\n... truncated at %d characters", MAX_OUTPUT_CHARS];
}

/* ---- text ---- */

NSString *CMDecode(NSData *data, NSString **encoding)
{
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (text) {
        if (encoding)
            *encoding = @"utf-8";
        return [text autorelease];
    }
    if (encoding)
        *encoding = @"latin-1";
    return [[[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] autorelease];
}

NSString *CMHexPreview(NSData *data, unsigned count)
{
    const unsigned char *b = [data bytes];
    unsigned n = [data length] < count ? [data length] : count, i;
    NSMutableArray *parts = [NSMutableArray array];
    for (i = 0; i < n; i++)
        [parts addObject:[NSString stringWithFormat:@"%02x", b[i]]];
    return [parts componentsJoinedByString:@" "];
}

NSArray *CMSplitLines(NSString *text)
{
    NSMutableArray *lines = [NSMutableArray arrayWithArray:[text componentsSeparatedByString:@"\n"]];
    if ([text hasSuffix:@"\n"] && [lines count] && [[lines lastObject] length] == 0)
        [lines removeLastObject];
    return lines;
}

NSString *CMBase64(NSData *data)
{
    static const char table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const unsigned char *b = [data bytes];
    unsigned n = [data length], i;
    NSMutableData *out = [NSMutableData dataWithCapacity:n * 4 / 3 + 4];
    for (i = 0; i + 2 < n; i += 3) {
        char c[4] = {table[b[i] >> 2], table[((b[i] & 3) << 4) | (b[i + 1] >> 4)], table[((b[i + 1] & 15) << 2) | (b[i + 2] >> 6)], table[b[i + 2] & 63]};
        [out appendBytes:c length:4];
    }
    if (i + 1 == n) {
        char c[4] = {table[b[i] >> 2], table[(b[i] & 3) << 4], '=', '='};
        [out appendBytes:c length:4];
    } else if (i + 2 == n) {
        char c[4] = {table[b[i] >> 2], table[((b[i] & 3) << 4) | (b[i + 1] >> 4)], table[(b[i + 1] & 15) << 2], '='};
        [out appendBytes:c length:4];
    }
    return [[[NSString alloc] initWithData:out encoding:NSASCIIStringEncoding] autorelease];
}

/* ---- where things are ---- */

NSString *CMPolicyPath(void) { return @"/etc/ppc-commander.json"; }

NSString *CMStateFolder(void)
{
    NSString *folder = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Tiger Build/commander"];
    NSFileManager *m = [NSFileManager defaultManager];
    if (![m fileExistsAtPath:folder]) {
        NSString *parent = [folder stringByDeletingLastPathComponent];
        NSDictionary *private = [NSDictionary dictionaryWithObject:[NSNumber numberWithInt:0700] forKey:NSFilePosixPermissions];
        if (![m fileExistsAtPath:[parent stringByDeletingLastPathComponent]])
            [m createDirectoryAtPath:[parent stringByDeletingLastPathComponent] attributes:nil];
        if (![m fileExistsAtPath:parent])
            [m createDirectoryAtPath:parent attributes:nil];
        [m createDirectoryAtPath:folder attributes:private];
    }
    return folder;
}

NSString *CMBinaryPath(void)
{
    char buffer[4096];
    uint32_t size = sizeof buffer;
    char real[PATH_MAX];
    if (_NSGetExecutablePath(buffer, &size) == 0 && realpath(buffer, real))
        return [NSString stringWithUTF8String:real];
    return @"";
}

static NSString *configPath(void) { return [CMStateFolder() stringByAppendingPathComponent:@"config.json"]; }
static NSString *historyPath(void) { return [CMStateFolder() stringByAppendingPathComponent:@"tool-history.jsonl"]; }
static NSString *usagePath(void) { return [CMStateFolder() stringByAppendingPathComponent:@"usage.json"]; }

NSString *CMNow(void)
{
    time_t t = time(NULL);
    struct tm local;
    char buffer[32];
    localtime_r(&t, &local);
    strftime(buffer, sizeof buffer, "%Y-%m-%dT%H:%M:%S", &local);
    return [NSString stringWithUTF8String:buffer];
}

NSMutableDictionary *CMConfig(void) { return config; }

static NSMutableDictionary *defaults(void)
{
    return [NSMutableDictionary dictionaryWithObjectsAndKeys:
        [NSMutableArray arrayWithObjects:@"mkfs", @"mkfs_hfs", @"newfs", @"newfs_hfs", @"fdisk", @"dd", @"shutdown", @"reboot", @"halt", @"poweroff", nil], @"blockedCommands",
        @"/bin/bash", @"defaultShell",
        [NSMutableArray array], @"allowedDirectories",
        [NSNumber numberWithInt:1000], @"fileReadLineLimit",
        [NSNumber numberWithInt:1000], @"fileWriteLineLimit",
        [NSNumber numberWithBool:NO], @"telemetryEnabled",
        [NSNumber numberWithBool:NO], @"sudoMode", nil];
}

void CMSaveConfig(void)
{
    NSString *path = configPath();
    NSString *temporary = [path stringByAppendingString:@".tmp"];
    if ([TBJSONData(config) writeToFile:temporary atomically:NO])
        rename([temporary fileSystemRepresentation], [path fileSystemRepresentation]);
}

/* A root-owned policy file can only tighten the settings. */
static void applyPolicy(void)
{
    struct stat info;
    NSData *raw;
    id policy;
    NSArray *blocked;
    if (stat([CMPolicyPath() fileSystemRepresentation], &info) != 0)
        return;
    if (info.st_uid != 0 || (info.st_mode & 0022)) {
        CMLog(@"ignoring %@: it must be owned by root and not writable by others", CMPolicyPath());
        return;
    }
    raw = [NSData dataWithContentsOfFile:CMPolicyPath()];
    policy = raw ? TBJSONParse(raw, NULL) : nil;
    if (![policy isKindOfClass:[NSDictionary class]])
        return;
    blocked = [policy objectForKey:@"blockedCommands"];
    if ([blocked isKindOfClass:[NSArray class]]) {
        NSMutableArray *merged = [NSMutableArray arrayWithArray:[config objectForKey:@"blockedCommands"]];
        unsigned i;
        for (i = 0; i < [blocked count]; i++)
            if (![merged containsObject:[blocked objectAtIndex:i]])
                [merged addObject:[blocked objectAtIndex:i]];
        [config setObject:merged forKey:@"blockedCommands"];
    }
    if ([policy objectForKey:@"allowedDirectories"])
        [config setObject:[policy objectForKey:@"allowedDirectories"] forKey:@"allowedDirectories"];
    if ([policy objectForKey:@"defaultShell"])
        [config setObject:[policy objectForKey:@"defaultShell"] forKey:@"defaultShell"];
    if ([policy objectForKey:@"sudoMode"] && ![[policy objectForKey:@"sudoMode"] boolValue])
        [config setObject:[NSNumber numberWithBool:NO] forKey:@"sudoMode"];
}

NSString *CMResolve(NSString *path)
{
    NSString *normal = [path stringByStandardizingPath];
    NSFileManager *m = [NSFileManager defaultManager];
    NSMutableArray *tail = [NSMutableArray array];
    NSString *current = normal, *base;
    char real[PATH_MAX];
    struct stat st;
    unsigned i;
    if (lstat([normal fileSystemRepresentation], &st) == 0) {
        if (realpath([normal fileSystemRepresentation], real))
            return [NSString stringWithUTF8String:real];
        return normal;
    }
    while ([current length] > 1 && lstat([current fileSystemRepresentation], &st) != 0) {
        NSString *parent;
        [tail addObject:[current lastPathComponent]];
        parent = [current stringByDeletingLastPathComponent];
        if ([parent isEqualToString:current])
            break;
        current = parent;
    }
    if (lstat([current fileSystemRepresentation], &st) == 0 && realpath([current fileSystemRepresentation], real))
        base = [NSString stringWithUTF8String:real];
    else
        base = current;
    (void)m;
    for (i = [tail count]; i > 0; i--)
        base = [base stringByAppendingPathComponent:[tail objectAtIndex:i - 1]];
    return [base stringByStandardizingPath];
}

static BOOL inside(NSString *path, NSString *root)
{
    NSString *r = root;
    while ([r length] > 1 && [r hasSuffix:@"/"])
        r = [r substringToIndex:[r length] - 1];
    return [path isEqualToString:r] || [path hasPrefix:[r stringByAppendingString:@"/"]] || [r isEqualToString:@"/"];
}

NSString *CMWorkspaceRoot(void) { return workspaceRoot; }

static BOOL workspaceAllows(NSString *path)
{
    return [workspaceRoot length] == 0 || inside(path, workspaceRoot);
}

BOOL CMPathAllowed(NSString *path)
{
    NSArray *roots = [config objectForKey:@"allowedDirectories"];
    unsigned i;
    if (!workspaceAllows(path))
        return NO;
    if (![roots isKindOfClass:[NSArray class]] || [roots count] == 0)
        return YES;
    for (i = 0; i < [roots count]; i++) {
        NSString *root = [roots objectAtIndex:i];
        if (![root isKindOfClass:[NSString class]] || ![root length])
            continue;
        if (inside(path, CMResolve([root stringByExpandingTildeInPath])))
            return YES;
    }
    return NO;
}

static NSString *deniedMessage(NSString *path)
{
    NSArray *roots = [config objectForKey:@"allowedDirectories"];
    NSMutableArray *shown = [NSMutableArray array];
    unsigned i;
    if (!workspaceAllows(path))
        return [NSString stringWithFormat:@"path is outside this workspace's directory: %@. Work inside %@.", path, workspaceRoot];
    for (i = 0; [roots isKindOfClass:[NSArray class]] && i < [roots count]; i++)
        [shown addObject:[[roots objectAtIndex:i] description]];
    return [NSString stringWithFormat:@"path is outside allowedDirectories: %@. allowed: %@. An empty allowedDirectories list permits every path. Terminal commands ignore this list.",
        path, [shown componentsJoinedByString:@", "]];
}

/* A path with accented characters may be stored decomposed (HFS+) while the model typed it composed, or the other way round. */
static NSString *fixUnicode(NSString *path)
{
    struct stat st;
    NSString *alt;
    if (lstat([path fileSystemRepresentation], &st) == 0)
        return path;
    alt = [path decomposedStringWithCanonicalMapping];
    if (lstat([alt fileSystemRepresentation], &st) == 0)
        return alt;
    alt = [path precomposedStringWithCanonicalMapping];
    if (lstat([alt fileSystemRepresentation], &st) == 0)
        return alt;
    return path;
}

NSString *CMCheckPath(NSString *path)
{
    NSString *full = fixUnicode([path stringByExpandingTildeInPath]);
    NSString *resolved;
    if (![full isAbsolutePath])
        full = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:full];
    resolved = CMResolve(full);
    if (!CMPathAllowed(resolved))
        CMFail(@"%@", deniedMessage(resolved));
    return resolved;
}

NSString *CMCheckWritable(NSString *path)
{
    NSArray *guarded = [NSArray arrayWithObjects:CMResolve(CMStateFolder()), CMResolve(CMBinaryPath()), CMPolicyPath(), nil];
    unsigned i;
    for (i = 0; i < [guarded count]; i++)
        if (inside(path, [guarded objectAtIndex:i]))
            CMFail(@"ppc-commander does not let tools change its own files (%@). Edit them by hand on this Mac.", [guarded objectAtIndex:i]);
    return path;
}

/* ---- shell commands: what may run ---- */

/* stringByReplacingOccurrencesOfString: is 10.5 and later */
NSString *CMSwap(NSString *text, NSString *from, NSString *to)
{
    return [[text componentsSeparatedByString:from] componentsJoinedByString:to];
}

static NSString *kSeparator = nil;

static NSString *separator(void)
{
    if (!kSeparator)
        kSeparator = [[NSString stringWithFormat:@"%C", (unichar)1] retain];
    return kSeparator;
}

static NSString *normalizeCommand(NSString *command)
{
    NSMutableString *out = [NSMutableString string];
    NSString *text = [[command componentsSeparatedByString:@"\\\n"] componentsJoinedByString:@" "];
    unsigned i, n = [text length];
    if (!kSeparator)
        kSeparator = [[NSString stringWithFormat:@"%C", (unichar)1] retain];
    for (i = 0; i < n; i++) {
        unichar c = [text characterAtIndex:i], d = i + 1 < n ? [text characterAtIndex:i + 1] : 0;
        if (c == '\'' || c == '"' || c == '\\')
            continue;
        if (c == '$' && d == '(') {
            [out appendString:separator()];
            i++;
        } else if (c == '`' || c == '(' || c == ')' || c == '{' || c == '}')
            [out appendString:separator()];
        else if ((c == '&' && d == '&') || (c == '|' && d == '|')) {
            [out appendString:separator()];
            i++;
        } else if (c == ';' || c == '&' || c == '|' || c == '\n')
            [out appendString:separator()];
        else
            [out appendFormat:@"%C", c];
    }
    return out;
}

/* Names that may run as programs: the first word of each command after VAR=value, and after a wrapper such as sudo, env,
   xargs or sh, every later word, because the wrapper may run any of them. */
NSArray *CMCommandWords(NSString *command)
{
    NSMutableArray *found = [NSMutableArray array];
    NSArray *segments = [normalizeCommand(command) componentsSeparatedByString:separator()];
    NSArray *wrappers = [NSArray arrayWithObjects:@"sudo", @"env", @"exec", @"nohup", @"time", @"nice", @"xargs", @"eval", @"command", @"builtin", @"arch", @"caffeinate",
        @"osascript", @"perl", @"python", @"ruby", @"sh", @"bash", @"zsh", @"csh", @"tcsh", @"ksh", @"dash", @"source", @".", nil];
    unsigned s, t;
    for (s = 0; s < [segments count]; s++) {
        NSString *flat = CMSwap(CMSwap([segments objectAtIndex:s], @"\t", @" "), @"\n", @" ");
        NSArray *tokens = [flat componentsSeparatedByString:@" "];
        BOOL wrapped = NO, first = YES;
        for (t = 0; t < [tokens count]; t++) {
            NSString *token = [tokens objectAtIndex:t], *name;
            if (![token length])
                continue;
            if (first && [token rangeOfString:@"="].location != NSNotFound && ![token hasPrefix:@"="])
                continue;
            if ([token hasPrefix:@"-"] && !first)
                continue;
            name = [token lastPathComponent];
            if (first || wrapped)
                [found addObject:name];
            if ([wrappers containsObject:name])
                wrapped = YES;
            first = NO;
        }
    }
    return found;
}

static BOOL matches(const char *pattern, NSString *text)
{
    regex_t re;
    BOOL hit;
    if (regcomp(&re, pattern, REG_EXTENDED | REG_NOSUB) != 0)
        return NO;
    hit = regexec(&re, [text UTF8String], 0, NULL, 0) == 0;
    regfree(&re);
    return hit;
}

NSString *CMWhyBlocked(NSString *command)
{
    NSString *flat = CMSwap(normalizeCommand(command), separator(), @" ; ");
    NSArray *texts = [NSArray arrayWithObjects:command, flat, nil];
    NSArray *words = CMCommandWords(command), *blocked;
    unsigned i;
    for (i = 0; i < [texts count]; i++) {
        if (matches(">[[:space:]]*/dev/r?disk", [texts objectAtIndex:i]))
            return @"redirect to a disk device";
        if (matches("(^|[[:space:]])of=/dev/r?disk", [texts objectAtIndex:i]))
            return @"write to a disk device";
    }
    if ([words containsObject:@"diskutil"] && matches("diskutil[[:space:]]+([^[:space:]]+[[:space:]]+)*(erase|partition|zero|split|secureErase|reformat)", flat))
        return @"diskutil erase/partition";
    blocked = [config objectForKey:@"blockedCommands"];
    if (![blocked isKindOfClass:[NSArray class]])
        return nil;
    for (i = 0; i < [blocked count]; i++) {
        id name = [blocked objectAtIndex:i];
        if ([name isKindOfClass:[NSString class]] && [name length] && [words containsObject:name])
            return name;
    }
    return nil;
}

/* The path-like words of a command: split at spaces, quotes and shell punctuation. */
static NSArray *commandPaths(NSString *command)
{
    NSMutableArray *found = [NSMutableArray array];
    NSMutableString *word = [NSMutableString string];
    unsigned i;
    NSCharacterSet *breaks = [NSCharacterSet characterSetWithCharactersInString:@" \t\r\n;|&<>()=`$\"'"];
    for (i = 0; i <= [command length]; i++) {
        unichar c = i < [command length] ? [command characterAtIndex:i] : ' ';
        if ([breaks characterIsMember:c]) {
            if ([word length] && ([word hasPrefix:@"/"] || [word hasPrefix:@"~"] || [word isEqualToString:@".."] || [word hasPrefix:@"../"] || [word rangeOfString:@"/../"].location != NSNotFound || [word hasSuffix:@"/.."]))
                [found addObject:[[word copy] autorelease]];
            [word setString:@""];
        } else
            [word appendFormat:@"%C", c];
    }
    return found;
}

NSString *CMWorkspaceCommandProblem(NSString *command)
{
    NSArray *words, *systemDirs;
    unsigned i, d;
    if (![workspaceRoot length])
        return nil;
    systemDirs = [NSArray arrayWithObjects:@"/bin", @"/sbin", @"/usr/bin", @"/usr/sbin", @"/usr/local/bin", @"/usr/libexec", @"/usr/lib", @"/usr/share", @"/System/Library", @"/Developer/usr",
        @"/Developer/SDKs", @"/Developer/Library", @"/dev/null", @"/dev/tty", @"/dev/zero", @"/usr/include", @"/Library/Frameworks", nil];
    words = commandPaths(command);
    for (i = 0; i < [words count]; i++) {
        NSString *word = [words objectAtIndex:i], *full = [word stringByExpandingTildeInPath];
        BOOL ok = NO;
        if (![full isAbsolutePath])
            full = [workspaceRoot stringByAppendingPathComponent:full];
        full = CMResolve(full);
        if (inside(full, workspaceRoot))
            continue;
        for (d = 0; d < [systemDirs count]; d++)
            if (inside(full, [systemDirs objectAtIndex:d]))
                ok = YES;
        if (!ok)
            return [NSString stringWithFormat:@"the command uses %@, which is outside this workspace directory (%@)", word, workspaceRoot];
    }
    return nil;
}

BOOL CMSudoEnabled(void)
{
    const char *env = getenv("TB_SUDO");
    /* Tiger Build says for each chat: "1" on, "0" off. Only a run without it (another computer, a terminal) goes by the saved setting. */
    if (env && !strcmp(env, "0"))
        return NO;
    if (env && !strcmp(env, "1")) {
        /* a root-owned policy that keeps administrator mode off wins over the chat's switch */
        struct stat info;
        if (stat([CMPolicyPath() fileSystemRepresentation], &info) == 0 && info.st_uid == 0 && !(info.st_mode & 0022)) {
            id policy = [TBJSONParse([NSData dataWithContentsOfFile:CMPolicyPath()], NULL) retain];
            BOOL off = [policy isKindOfClass:[NSDictionary class]] && [policy objectForKey:@"sudoMode"] && ![[policy objectForKey:@"sudoMode"] boolValue];
            [policy release];
            if (off)
                return NO;
        }
        return YES;
    }
    return [[config objectForKey:@"sudoMode"] boolValue];
}

/* ---- this Mac ---- */

static NSString *TBTrim_(NSString *s) { return s ? [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : @""; }

static NSString *runLine(NSString *path, NSString *arg)
{
    NSMutableArray *argv = [NSMutableArray arrayWithObject:path];
    NSString *out = nil;
    if (arg)
        [argv addObject:arg];
    CMRunProgram(argv, nil, 5, nil, &out);
    return TBTrim_(out);
}

NSString *CMSystemInfo(NSString *key)
{
    if (!sysinfo) {
        sysinfo = [[NSMutableDictionary alloc] init];
        [sysinfo setObject:runLine(@"/usr/bin/uname", @"-a") forKey:@"uname"];
        [sysinfo setObject:runLine(@"/usr/bin/sw_vers", nil) forKey:@"sw_vers"];
        {
            NSString *out = nil;
            CMRunProgram([NSArray arrayWithObjects:@"/usr/sbin/sysctl", @"-n", @"hw.model", nil], nil, 5, nil, &out);
            [sysinfo setObject:TBTrim_(out) forKey:@"model"];
            out = nil;
            CMRunProgram([NSArray arrayWithObjects:@"/usr/sbin/sysctl", @"-n", @"hw.memsize", nil], nil, 5, nil, &out);
            [sysinfo setObject:TBTrim_(out) forKey:@"mem"];
        }
    }
    return [sysinfo objectForKey:key] ? [sysinfo objectForKey:key] : @"";
}

NSString *CMInstructions(void)
{
    return [NSString stringWithFormat:@"ppc-commander executes on this Mac, not on the MCP client. uname: %@. sw_vers: %@. model: %@. memory_bytes: %@. Default shell: %@. "
        @"There is no Node.js and no ripgrep. allowedDirectories limits file tools only; an empty list means the whole filesystem. Terminal commands are not limited by that list. "
        @"Disk-erase commands stay blocked. blockedCommands, allowedDirectories, and defaultShell are locked, and the file tools cannot edit ppc-commander itself. "
        @"Prefer edit_block for small changes. start_process returns when output goes idle or timeout_ms elapses (capped at 120s) and leaves the process running. "
        @"GUI apps are allowed. start_process with detach true runs them outside this session so they stay open after the chat moves on.",
        CMSystemInfo(@"uname"), CMSwap(CMSystemInfo(@"sw_vers"), @"\n", @"; "), CMSystemInfo(@"model"), CMSystemInfo(@"mem"),
        [config objectForKey:@"defaultShell"]];
}

/* ---- loading ---- */

void CMLoadSettings(void)
{
    NSData *raw;
    id data;
    NSString *root;
    NSEnumerator *keys;
    NSString *key;
    config = [defaults() retain];
    raw = [NSData dataWithContentsOfFile:configPath()];
    if (!raw)
        CMSaveConfig();
    else {
        data = TBJSONParse(raw, NULL);
        if (![data isKindOfClass:[NSDictionary class]])
            CMLog(@"config unreadable; using defaults");
        else {
            keys = [defaults() keyEnumerator];
            while ((key = [keys nextObject]))
                if ([data objectForKey:key])
                    [config setObject:[data objectForKey:key] forKey:key];
        }
        applyPolicy();
    }
    root = [NSString stringWithUTF8String:getenv("TB_WORKSPACE_ROOT") ? getenv("TB_WORKSPACE_ROOT") : ""];
    root = [root stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    workspaceRoot = @"";
    if ([root length]) {
        if (![root isAbsolutePath])
            CMLog(@"ignoring TB_WORKSPACE_ROOT: it must be an absolute path");
        else
            workspaceRoot = [CMResolve(root) retain];
    }
    usage = [[NSMutableDictionary alloc] initWithObjectsAndKeys:CMNow(), @"started", [NSNumber numberWithInt:0], @"tool_calls", [NSNumber numberWithInt:0], @"errors",
        [NSMutableDictionary dictionary], @"by_tool", nil];
    raw = [NSData dataWithContentsOfFile:usagePath()];
    if (raw) {
        data = TBJSONParse(raw, NULL);
        if ([data isKindOfClass:[NSDictionary class]]) {
            [usage release];
            usage = [[NSMutableDictionary alloc] initWithDictionary:data];
            if (![[usage objectForKey:@"by_tool"] isKindOfClass:[NSDictionary class]])
                [usage setObject:[NSMutableDictionary dictionary] forKey:@"by_tool"];
        }
    }
    recordLock = [[NSLock alloc] init];
}

/* ---- history and usage ---- */

void CMRecord(NSString *tool, NSDictionary *args, NSString *text, BOOL ok, int millis)
{
    NSMutableDictionary *safe = [NSMutableDictionary dictionary], *byTool;
    NSEnumerator *keys;
    NSString *key;
    NSDictionary *row;
    NSFileHandle *h;
    NSString *path = historyPath();
    if ([tool isEqualToString:@"get_recent_tool_calls"])
        return;
    [recordLock lock];
    @try {
        keys = [args keyEnumerator];
        while ((key = [keys nextObject])) {
            id v = [args objectForKey:key];
            [safe setObject:[v isKindOfClass:[NSString class]] ? CMClip(v, 600) : v forKey:key];
        }
        [usage setObject:[NSNumber numberWithInt:[[usage objectForKey:@"tool_calls"] intValue] + 1] forKey:@"tool_calls"];
        if (!ok)
            [usage setObject:[NSNumber numberWithInt:[[usage objectForKey:@"errors"] intValue] + 1] forKey:@"errors"];
        byTool = [NSMutableDictionary dictionaryWithDictionary:[usage objectForKey:@"by_tool"]];
        [byTool setObject:[NSNumber numberWithInt:[[byTool objectForKey:tool] intValue] + 1] forKey:tool];
        [usage setObject:byTool forKey:@"by_tool"];
        [TBJSONData(usage) writeToFile:usagePath() atomically:YES];
        row = [NSDictionary dictionaryWithObjectsAndKeys:CMNow(), @"time", tool, @"tool", [NSNumber numberWithBool:ok], @"ok", [NSNumber numberWithInt:millis], @"duration_ms",
            safe, @"arguments", CMClip(text, 600), @"output_preview", nil];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path])
            [[NSFileManager defaultManager] createFileAtPath:path contents:[NSData data] attributes:nil];
        h = [NSFileHandle fileHandleForWritingAtPath:path];
        [h seekToEndOfFile];
        [h writeData:TBJSONData(row)];
        [h writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
        [h closeFile];
        {
            struct stat st;
            if (stat([path fileSystemRepresentation], &st) == 0 && st.st_size > HISTORY_MAX_BYTES) {
                NSArray *lines = [[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] componentsSeparatedByString:@"\n"];
                if ([lines count] > HISTORY_KEEP_LINES) {
                    NSArray *keep = [lines subarrayWithRange:NSMakeRange([lines count] - HISTORY_KEEP_LINES, HISTORY_KEEP_LINES)];
                    [[keep componentsJoinedByString:@"\n"] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                }
            }
        }
    } @catch (NSException *e) {
        CMLog(@"history failed: %@", [e reason]);
    }
    [recordLock unlock];
}

/* ---- configuration tools ---- */

id CMToolGetConfig(NSDictionary *args)
{
    id roots = [config objectForKey:@"allowedDirectories"];
    NSString *rootText = ([roots isKindOfClass:[NSArray class]] && [roots count] == 0) ? @"(empty - file tools may use the whole filesystem)" : TBJSONString(roots);
    (void)args;
    return [NSString stringWithFormat:@"blockedCommands: %@\ndefaultShell: %@\nallowedDirectories: %@\nfileReadLineLimit: %@\nfileWriteLineLimit: %@\ntelemetryEnabled: %@\n"
        @"sudoMode: %@\ntelemetry: this server does not send telemetry anywhere\nmodel: %@\nmem_bytes: %@\nuname: %@\nsw_vers: %@\nversion: %@",
        TBJSONString([config objectForKey:@"blockedCommands"]), [config objectForKey:@"defaultShell"], rootText, [config objectForKey:@"fileReadLineLimit"],
        [config objectForKey:@"fileWriteLineLimit"], [[config objectForKey:@"telemetryEnabled"] boolValue] ? @"true" : @"false",
        CMSudoEnabled() ? @"on (commands with sudo run as administrator)" : @"off", CMSystemInfo(@"model"), CMSystemInfo(@"mem"), CMSystemInfo(@"uname"),
        CMSwap(CMSystemInfo(@"sw_vers"), @"\n", @"; "), CM_VERSION];
}

id CMToolSetConfig(NSDictionary *args)
{
    NSString *key = CMString(args, @"key");
    id value;
    if (![[defaults() allKeys] containsObject:key])
        CMFail(@"unknown config key %@", key);
    if (![args objectForKey:@"value"])
        CMFail(@"missing value");
    value = [args objectForKey:@"value"];
    if ([[NSArray arrayWithObjects:@"blockedCommands", @"allowedDirectories", @"defaultShell", @"sudoMode", nil] containsObject:key])
        CMFail(@"%@ is locked. It controls what tools may run and touch, so only a person can change it, by editing %@ on this Mac (or %@ as an administrator).",
            key, [CMStateFolder() stringByAppendingPathComponent:@"config.json"], CMPolicyPath());
    if ([key isEqualToString:@"fileReadLineLimit"] || [key isEqualToString:@"fileWriteLineLimit"]) {
        long long n = integerOf(value, key);
        if (n < 1 || n > 100000)
            CMFail(@"%@ must be from 1 to 100000", key);
        [config setObject:[NSNumber numberWithLongLong:n] forKey:key];
    } else if ([key isEqualToString:@"telemetryEnabled"]) {
        if (!([value isKindOfClass:[NSNumber class]] && CFGetTypeID(value) == CFBooleanGetTypeID()))
            CMFail(@"expected a boolean");
        [config setObject:value forKey:key];
    }
    CMSaveConfig();
    return [NSString stringWithFormat:@"set %@\n%@", key, CMToolGetConfig([NSDictionary dictionary])];
}

id CMToolUsage(NSDictionary *args)
{
    (void)args;
    return [NSString stringWithFormat:@"started: %@\ntool_calls: %@\nerrors: %@\nby_tool: %@\nserver: ppc-commander %@", [usage objectForKey:@"started"], [usage objectForKey:@"tool_calls"],
        [usage objectForKey:@"errors"], TBJSONString([usage objectForKey:@"by_tool"]), CM_VERSION];
}

id CMToolRecent(NSDictionary *args)
{
    long long limit = CMOptInteger(args, @"maxResults", 20);
    NSString *name = CMOptString(args, @"toolName", nil), *since = CMOptString(args, @"since", nil);
    NSString *text = [NSString stringWithContentsOfFile:historyPath() encoding:NSUTF8StringEncoding error:NULL];
    NSMutableArray *rows = [NSMutableArray array], *parts = [NSMutableArray array];
    NSArray *lines;
    unsigned i;
    if (limit < 1) limit = 1;
    if (limit > 100) limit = 100;
    if (!text)
        return @"no tool calls yet";
    lines = [text componentsSeparatedByString:@"\n"];
    for (i = 0; i < [lines count]; i++) {
        id rec;
        if (![[lines objectAtIndex:i] length])
            continue;
        rec = TBJSONParseString([lines objectAtIndex:i], NULL);
        if (![rec isKindOfClass:[NSDictionary class]])
            continue;
        if (name && ![[rec objectForKey:@"tool"] isEqual:name])
            continue;
        if (since && [[[rec objectForKey:@"time"] description] compare:since] == NSOrderedAscending)
            continue;
        [rows addObject:rec];
    }
    if ((long long)[rows count] > limit)
        [rows removeObjectsInRange:NSMakeRange(0, [rows count] - (unsigned)limit)];
    if (![rows count])
        return @"no matching tool calls";
    for (i = [rows count]; i > 0; i--) {
        id rec = [rows objectAtIndex:i - 1];
        [parts addObject:[NSString stringWithFormat:@"%@ %@ ok=%@ %@ms\nargs: %@\noutput: %@", [rec objectForKey:@"time"], [rec objectForKey:@"tool"],
            [[rec objectForKey:@"ok"] boolValue] ? @"true" : @"false", [rec objectForKey:@"duration_ms"], TBJSONString([rec objectForKey:@"arguments"]), [rec objectForKey:@"output_preview"]]];
    }
    return CMCap([parts componentsJoinedByString:@"\n\n"]);
}
