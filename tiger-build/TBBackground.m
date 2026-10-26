#import "TBBackground.h"
#import "TBEngine.h"
#import "TBSupport.h"
#include <signal.h>

static NSMutableDictionary *tasks = nil;      /* id -> {task, label, command, run, started, ended, reported, log, stopped} */
static NSMutableDictionary *runChats = nil;
static int counter = 0;

static NSString *logFolder(void)
{
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Tiger Build/background"];
    TBMakePath(dir);
    return dir;
}

static NSString *tailOf(NSString *path, int lines)
{
    NSFileHandle *h = [NSFileHandle fileHandleForReadingAtPath:path];
    NSData *data;
    unsigned long long size;
    NSString *text;
    NSArray *rows;
    if (!h)
        return @"";
    size = [h seekToEndOfFile];
    [h seekToFileOffset:size > 20000 ? size - 20000 : 0];
    data = [h readDataToEndOfFile];
    [h closeFile];
    text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    if (!text)
        text = [[[NSString alloc] initWithData:data encoding:NSMacOSRomanStringEncoding] autorelease];
    rows = [TBTrim(text) componentsSeparatedByString:@"\n"];
    if ((int)[rows count] > lines)
        rows = [rows subarrayWithRange:NSMakeRange([rows count] - lines, lines)];
    return [rows componentsJoinedByString:@"\n"];
}

/* notices a task that has ended */
static void refresh(NSMutableDictionary *t)
{
    NSTask *task = [t objectForKey:@"task"];
    if ([t objectForKey:@"ended"] || !task || [task isRunning])
        return;
    [t setObject:[NSDate date] forKey:@"ended"];
    [t setObject:[NSNumber numberWithInt:[task terminationStatus]] forKey:@"status"];
}

static NSString *stateText(NSString *ident, NSMutableDictionary *t, int lines)
{
    NSDate *end;
    NSString *state;
    refresh(t);
    end = [t objectForKey:@"ended"];
    state = !end ? @"running" : [[t objectForKey:@"stopped"] boolValue] ? @"stopped" : [NSString stringWithFormat:@"finished, exit status %d", [[t objectForKey:@"status"] intValue]];
    return [NSString stringWithFormat:@"%@ \"%@\" %@ after %ds.\nCommand: %@\n%@", ident, [t objectForKey:@"label"], state,
        (int)[(end ? end : [NSDate date]) timeIntervalSinceDate:[t objectForKey:@"started"]], [t objectForKey:@"command"],
        lines > 0 ? [NSString stringWithFormat:@"Last output:\n%@", tailOf([t objectForKey:@"log"], lines)] : @""];
}

@implementation TBBackground

+ (NSString *)start:(NSString *)command label:(NSString *)label directory:(NSString *)directory run:(NSString *)runId
{
    NSString *ident, *log;
    NSMutableDictionary *t;
    NSTask *task;
    NSFileHandle *out;
    NSString *dir = [directory length] ? [directory stringByExpandingTildeInPath] : NSHomeDirectory();
    BOOL isDir = NO;
    int running = 0;
    NSEnumerator *e;
    NSMutableDictionary *other;
    @synchronized(self) {
        if (!tasks)
            tasks = [[NSMutableDictionary alloc] init];
        if (!runChats)
            runChats = [[NSMutableDictionary alloc] init];
        if (![command length])
            TBFail(@"Give the command to run.");
        if (![[NSFileManager defaultManager] fileExistsAtPath:dir isDirectory:&isDir] || !isDir)
            TBFail(@"The folder %@ does not exist.", dir);
        e = [tasks objectEnumerator];
        while ((other = [e nextObject])) {
            refresh(other);
            if (![other objectForKey:@"ended"])
                running++;
        }
        if (running >= 8)
            TBFail(@"Eight background tasks are already running. Stop one first.");
        counter++;
        ident = [NSString stringWithFormat:@"bg%d", counter];
        log = [logFolder() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-%d.log", ident, (int)getpid()]];
        [[NSFileManager defaultManager] createFileAtPath:log contents:[NSData data] attributes:nil];
        out = [NSFileHandle fileHandleForWritingAtPath:log];
        task = [[[NSTask alloc] init] autorelease];
        [task setLaunchPath:@"/bin/sh"];
        [task setArguments:[NSArray arrayWithObjects:@"-c", command, nil]];
        [task setCurrentDirectoryPath:dir];
        [task setStandardOutput:out];
        [task setStandardError:out];
        [task setStandardInput:[NSFileHandle fileHandleWithNullDevice]];
        NS_DURING
            [task launch];
        NS_HANDLER
            [out closeFile];
            TBFail(@"Could not start it: %@", [localException reason]);
        NS_ENDHANDLER
        t = [NSMutableDictionary dictionaryWithObjectsAndKeys:task, @"task", [label length] ? label : command, @"label", command, @"command", log, @"log",
            [NSDate date], @"started", runId ? runId : @"", @"run", nil];
        [tasks setObject:t forKey:ident];
        if (getenv("TB_DEBUG_BG"))
            fprintf(stderr, "bg %s run=%s chat=%s\n", [ident UTF8String], [runId UTF8String], [[runChats objectForKey:runId] UTF8String]);
    }
    return ident;
}

+ (NSString *)describe:(NSString *)ident tail:(int)lines
{
    @synchronized(self) {
        NSMutableDictionary *t = [tasks objectForKey:ident];
        if (!t)
            TBFail(@"There is no background task %@.", ident);
        return stateText(ident, t, lines);
    }
    return nil;
}

+ (NSString *)list
{
    NSMutableArray *rows = [NSMutableArray array];
    @synchronized(self) {
        NSArray *keys = [[tasks allKeys] sortedArrayUsingSelector:@selector(compare:)];
        unsigned i;
        for (i = 0; i < [keys count]; i++)
            [rows addObject:[[stateText([keys objectAtIndex:i], [tasks objectForKey:[keys objectAtIndex:i]], 0) componentsSeparatedByString:@"\n"] objectAtIndex:0]];
    }
    return [rows count] ? [rows componentsJoinedByString:@"\n"] : @"No background tasks.";
}

+ (BOOL)stop:(NSString *)ident
{
    @synchronized(self) {
        NSMutableDictionary *t = [tasks objectForKey:ident];
        NSTask *task = [t objectForKey:@"task"];
        if (!t || ![task isRunning])
            return NO;
        [t setObject:[NSNumber numberWithBool:YES] forKey:@"stopped"];
        [t setObject:[NSNumber numberWithBool:YES] forKey:@"reported"];   /* the person stopped it: no wake */
        kill([task processIdentifier], SIGTERM);
        return YES;
    }
    return NO;
}

+ (void)stopAll
{
    @synchronized(self) {
        NSEnumerator *e = [tasks objectEnumerator];
        NSMutableDictionary *t;
        while ((t = [e nextObject]))
            if ([[t objectForKey:@"task"] isRunning])
                kill([[t objectForKey:@"task"] processIdentifier], SIGTERM);
    }
}

+ (void)noteRun:(NSString *)runId chat:(NSString *)chat
{
    @synchronized(self) {
        if (!runChats)
            runChats = [[NSMutableDictionary alloc] init];
        if ([runId length] && chat)
            [runChats setObject:chat forKey:runId];
    }
}

+ (NSArray *)takeFinishedMessagesForChat:(NSString *)chat
{
    NSMutableArray *out = [NSMutableArray array];
    @synchronized(self) {
        NSArray *keys = [[tasks allKeys] sortedArrayUsingSelector:@selector(compare:)];
        unsigned i;
        for (i = 0; i < [keys count]; i++) {
            NSMutableDictionary *t = [tasks objectForKey:[keys objectAtIndex:i]];
            refresh(t);
            if (![t objectForKey:@"ended"] || [[t objectForKey:@"reported"] boolValue] || ![[runChats objectForKey:[t objectForKey:@"run"]] isEqualToString:chat])
                continue;
            [t setObject:[NSNumber numberWithBool:YES] forKey:@"reported"];
            [out addObject:[NSString stringWithFormat:@"[Background task %@]", stateText([keys objectAtIndex:i], t, 40)]];
        }
    }
    return out;
}

+ (BOOL)hasFinishedForChat:(NSString *)chat
{
    @synchronized(self) {
        NSEnumerator *e = [tasks objectEnumerator];
        NSMutableDictionary *t;
        while ((t = [e nextObject])) {
            refresh(t);
            if ([t objectForKey:@"ended"] && ![[t objectForKey:@"reported"] boolValue] && [[runChats objectForKey:[t objectForKey:@"run"]] isEqualToString:chat])
                return YES;
        }
    }
    return NO;
}

+ (BOOL)hasPendingForChat:(NSString *)chat
{
    @synchronized(self) {
        NSEnumerator *e = [tasks objectEnumerator];
        NSMutableDictionary *t;
        while ((t = [e nextObject])) {
            refresh(t);
            if (![[t objectForKey:@"reported"] boolValue] && [[runChats objectForKey:[t objectForKey:@"run"]] isEqualToString:chat])
                return YES;
        }
    }
    return NO;
}

@end
