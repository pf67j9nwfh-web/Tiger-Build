#import "TBCLIApp.h"
#import "TBEngine.h"
#import "TBIntegrations.h"
#include <signal.h>

/* Hooks (shell commands run at points in a chat) and MCP servers, for the terminal. */

@implementation TBCLIApp (Extras)

- (NSArray *)hookEvents
{
    return [NSArray arrayWithObjects:@"prompt", @"pre_tool", @"post_tool", @"stop", nil];
}

/* Runs the hook for the event, if one is set. Returns its exit status (0 when there is none) and puts what it printed in *output. */
- (int)runHook:(NSString *)event env:(NSDictionary *)extra output:(NSString **)output
{
    NSString *command = [[config objectForKey:@"hooks"] objectForKey:event];
    NSTask *task;
    NSPipe *pipe;
    NSMutableDictionary *env;
    NSMutableData *collected = [NSMutableData data];
    double start = CFAbsoluteTimeGetCurrent();
    int status = 0;
    if (output)
        *output = nil;
    if (![command isKindOfClass:[NSString class]] || ![command length])
        return 0;
    task = [[[NSTask alloc] init] autorelease];
    pipe = [NSPipe pipe];
    env = [NSMutableDictionary dictionaryWithDictionary:[[NSProcessInfo processInfo] environment]];
    [env setObject:event forKey:@"TB_HOOK"];
    [env setObject:[[core currentChat] objectForKey:@"id"] ? [[[core currentChat] objectForKey:@"id"] description] : @"" forKey:@"TB_CHAT"];
    [env addEntriesFromDictionary:extra];
    [task setLaunchPath:@"/bin/sh"];
    [task setArguments:[NSArray arrayWithObjects:@"-c", command, nil]];
    [task setEnvironment:env];
    [task setStandardOutput:pipe];
    [task setStandardError:pipe];
    [task setStandardInput:[NSFileHandle fileHandleWithNullDevice]];
    NS_DURING
        [task launch];
        while ([task isRunning]) {
            NSData *d = [[pipe fileHandleForReading] availableData];
            if ([d length])
                [collected appendData:d];
            else
                [NSThread sleepForTimeInterval:0.02];
            if (CFAbsoluteTimeGetCurrent() - start > 30) {
                kill([task processIdentifier], SIGKILL);
                break;
            }
        }
        [task waitUntilExit];
        [collected appendData:[[pipe fileHandleForReading] readDataToEndOfFile]];
        status = [task terminationStatus];
    NS_HANDLER
        status = 0;
    NS_ENDHANDLER
    if (output && [collected length])
        *output = [[[NSString alloc] initWithData:collected encoding:NSUTF8StringEncoding] autorelease];
    return status;
}

- (void)hooksCommand:(NSString *)arg
{
    NSArray *parts = [arg componentsSeparatedByString:@" "];
    NSMutableDictionary *hooks = [NSMutableDictionary dictionaryWithDictionary:[config objectForKey:@"hooks"]];
    NSString *sub = [parts count] ? [parts objectAtIndex:0] : @"", *event = [parts count] > 1 ? [parts objectAtIndex:1] : nil;
    unsigned i;
    if ([sub isEqualToString:@"set"] && event && [[self hookEvents] containsObject:event] && [parts count] > 2) {
        [hooks setObject:[[parts subarrayWithRange:NSMakeRange(2, [parts count] - 2)] componentsJoinedByString:@" "] forKey:event];
    } else if ([sub isEqualToString:@"clear"] && event) {
        [hooks removeObjectForKey:event];
    } else if ([arg length]) {
        [self printStyled:@"  /hooks set EVENT COMMAND   /hooks clear EVENT   (events: prompt, pre_tool, post_tool, stop)" style:@"gray"];
        return;
    }
    if ([arg length]) {
        [config setObject:hooks forKey:@"hooks"];
        [self saveConfig];
    }
    for (i = 0; i < [[self hookEvents] count]; i++) {
        NSString *e = [[self hookEvents] objectAtIndex:i];
        [self printLine:[NSString stringWithFormat:@"  %-10s %@", [e UTF8String], [hooks objectForKey:e] ? [hooks objectForKey:e] : [term styled:@"-" with:@"gray"]]];
    }
    if (![arg length])
        [self printStyled:@"  A hook is a shell command. prompt: a non-zero exit stops the message. pre_tool: a non-zero exit denies a tool that asks for approval (turn on /tools NAME approve on).\n  post_tool and stop run afterwards. They see TB_TOOL, TB_DETAIL and TB_PROMPT." style:@"gray"];
}

- (void)mcpCommand:(NSString *)arg
{
    NSArray *parts = [arg componentsSeparatedByString:@" "];
    NSString *sub = [parts count] ? [parts objectAtIndex:0] : @"", *ident = [parts count] > 1 ? [parts objectAtIndex:1] : nil;
    NSMutableArray *servers = [NSMutableArray array];
    unsigned i;
    BOOL changed = NO;
    for (i = 0; i < [[TBIntegrations servers] count]; i++)
        [servers addObject:[NSMutableDictionary dictionaryWithDictionary:[[TBIntegrations servers] objectAtIndex:i]]];
    if ([sub isEqualToString:@"add"] && [parts count] > 2) {
        NSArray *args = [parts count] > 3 ? [parts subarrayWithRange:NSMakeRange(3, [parts count] - 3)] : [NSArray array];
        [servers addObject:[NSMutableDictionary dictionaryWithObjectsAndKeys:ident, @"id", ident, @"title", [parts objectAtIndex:2], @"command", args, @"args",
            [NSDictionary dictionary], @"env", [NSNumber numberWithBool:YES], @"enabled", [NSNumber numberWithBool:YES], @"approval", nil]];
        changed = YES;
    } else if (ident && ([sub isEqualToString:@"remove"] || [sub isEqualToString:@"enable"] || [sub isEqualToString:@"disable"] || [sub isEqualToString:@"approve"] || [sub isEqualToString:@"noapprove"])) {
        for (i = 0; i < [servers count]; i++) {
            NSMutableDictionary *s = [servers objectAtIndex:i];
            if (![[s objectForKey:@"id"] isEqualToString:ident])
                continue;
            if ([sub isEqualToString:@"remove"]) { [servers removeObjectAtIndex:i]; }
            else if ([sub isEqualToString:@"enable"]) [s setObject:[NSNumber numberWithBool:YES] forKey:@"enabled"];
            else if ([sub isEqualToString:@"disable"]) [s setObject:[NSNumber numberWithBool:NO] forKey:@"enabled"];
            else [s setObject:[NSNumber numberWithBool:[sub isEqualToString:@"approve"]] forKey:@"approval"];
            changed = YES;
            break;
        }
        if (!changed) { [self printStyled:[NSString stringWithFormat:@"  no server %@", ident] style:@"red"]; return; }
    } else if ([arg length]) {
        [self printStyled:@"  /mcp add ID COMMAND [ARGS]   (COMMAND: /path/to/program, ssh:user@host, or an http(s):// address)\n  /mcp remove|enable|disable|approve|noapprove ID" style:@"gray"];
        return;
    }
    if (changed) {
        NS_DURING
            [TBIntegrations update:[NSDictionary dictionaryWithObject:servers forKey:@"servers"]];
        NS_HANDLER
            [self printStyled:[NSString stringWithFormat:@"  %@", [localException reason]] style:@"red"];
            return;
        NS_ENDHANDLER
        [core refreshCatalog];
    }
    servers = [NSMutableArray arrayWithArray:[TBIntegrations servers]];
    if (![servers count])
        [self printStyled:@"  no MCP servers" style:@"gray"];
    for (i = 0; i < [servers count]; i++) {
        NSDictionary *s = [servers objectAtIndex:i];
        [self printLine:[NSString stringWithFormat:@"  %@ %-14@ %@%@", [[s objectForKey:@"enabled"] boolValue] ? [term styled:@"on " with:@"green"] : [term styled:@"off" with:@"gray"], [s objectForKey:@"id"],
            [term clipToWidth:[s objectForKey:@"command"] width:[term columns] - 30], [[s objectForKey:@"approval"] boolValue] ? [term styled:@"  asks" with:@"yellow"] : @""]];
    }
}

@end
