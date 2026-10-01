#import "TBSupport.h"
#import <sys/types.h>
#import <sys/sysctl.h>

/* What kind of Mac this is, read from the system rather than assumed.
   sysctl hw.model gives the model code at once ("PowerMac3,1"). Then
   system_profiler, which takes about a second on a slow Mac, supplies the
   marketing name ("Power Mac G4 (AGP graphics)") in the background. */

static NSString *machineName = nil;
static NSString *machineDetail = nil;

static NSString *modelCode(void)
{
    char buffer[128];
    size_t size = sizeof(buffer);
    if (sysctlbyname("hw.model", buffer, &size, NULL, 0) != 0 || size == 0)
        return @"Mac";
    buffer[sizeof(buffer) - 1] = 0;
    return [NSString stringWithUTF8String:buffer];
}

static NSString *profilerValue(NSString *text, NSString *label)
{
    NSArray *lines = [text componentsSeparatedByString:@"\n"];
    unsigned i;
    for (i = 0; i < [lines count]; i++) {
        NSString *line = [[lines objectAtIndex:i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([line hasPrefix:label])
            return [[line substringFromIndex:[label length]] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    }
    return nil;
}

@implementation TBMachine

+ (void)profilerFinished:(NSNotification *)note
{
    NSData *data = [[note userInfo] objectForKey:NSFileHandleNotificationDataItem];
    NSString *text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    NSString *name = profilerValue(text, @"Machine Name:");
    NSString *cpu = profilerValue(text, @"CPU Type:");
    NSString *speed = profilerValue(text, @"CPU Speed:");
    NSString *memory = profilerValue(text, @"Memory:");
    [[NSNotificationCenter defaultCenter] removeObserver:self name:NSFileHandleReadToEndOfFileCompletionNotification object:[note object]];
    if ([name length]) {
        [machineName release];
        machineName = [name copy];
    }
    if ([cpu length] || [speed length]) {
        [machineDetail release];
        machineDetail = [[NSString stringWithFormat:@"%@%@%@%@%@",
            cpu ? cpu : @"", (cpu && speed) ? @", " : @"", speed ? speed : @"",
            memory ? @", " : @"", memory ? memory : @""] copy];
    }
}

+ (void)startDetection
{
    NSTask *task;
    NSPipe *pipe;
    if (!machineName)
        machineName = [modelCode() copy];
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:@"/usr/sbin/system_profiler"])
        return;
    task = [[[NSTask alloc] init] autorelease];
    pipe = [NSPipe pipe];
    [task setLaunchPath:@"/usr/sbin/system_profiler"];
    [task setArguments:[NSArray arrayWithObject:@"SPHardwareDataType"]];
    [task setStandardOutput:pipe];
    [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(profilerFinished:)
        name:NSFileHandleReadToEndOfFileCompletionNotification object:[pipe fileHandleForReading]];
    [[pipe fileHandleForReading] readToEndOfFileInBackgroundAndNotify];
    [task launch];
}

+ (NSString *)name
{
    if (!machineName)
        machineName = [modelCode() copy];
    return machineName;
}

+ (NSString *)detail
{
    return machineDetail ? machineDetail : @"";
}

+ (NSString *)systemVersion
{
    NSDictionary *version = [NSDictionary dictionaryWithContentsOfFile:@"/System/Library/CoreServices/SystemVersion.plist"];
    NSString *name = [version objectForKey:@"ProductName"];
    NSString *number = [version objectForKey:@"ProductVersion"];
    if (!number)
        return [[NSProcessInfo processInfo] operatingSystemVersionString];
    return [NSString stringWithFormat:@"%@ %@", name ? name : @"Mac OS X", number];
}

@end
