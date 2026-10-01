#import "ChatController_Private.h"

@implementation ChatController (Commander)
- (NSDictionary *)commanderCommand:(NSString *)command
{
    NSTask *task = [[[NSTask alloc] init] autorelease];
    NSPipe *pipe = [NSPipe pipe];
    NSData *data;
    NSString *text;
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSArray *lines;
    unsigned i;
    NSString *script = [NSHomeDirectory() stringByAppendingPathComponent:@"ppc-commander/service.py"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:script]) return result;
    [task setLaunchPath:@"/usr/bin/python"];
    [task setArguments:[NSArray arrayWithObjects:script, command, nil]];
    [task setStandardOutput:pipe];
    [task launch];
    data = [[pipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    lines = [text componentsSeparatedByString:@"\n"];
    for (i = 0; i < [lines count]; i++) {
        NSString *line = [lines objectAtIndex:i];
        NSRange eq = [line rangeOfString:@"="];
        if (eq.location != NSNotFound)
            [result setObject:[line substringFromIndex:eq.location + 1] forKey:[line substringToIndex:eq.location]];
    }
    return result;
}
- (void)commanderStart:(id)sender
{
    [self commanderCommand:@"start"];
    [self menuNeedsUpdate:[sender menu]];
}
- (void)commanderStop:(id)sender
{
    if (NSRunAlertPanel(@"Stop PPC Commander?", @"Active Commander tool sessions and their child processes will close. "
        @"New tool sessions are blocked until you choose Start. This does not stop the relay or ordinary SSH.",
        @"Stop", @"Cancel", nil) != NSAlertDefaultReturn) return;
    [self commanderCommand:@"stop"];
    [self menuNeedsUpdate:[sender menu]];
}
- (void)commanderAutostart:(id)sender
{
    NSDictionary *state = [self commanderCommand:@"status"];
    [self commanderCommand:([[state objectForKey:@"autostart"] intValue] != 0) ? @"autostart-off" : @"autostart-on"];
    [self menuNeedsUpdate:[sender menu]];
}
- (void)commanderIP:(id)sender
{
    (void)sender;
    NSDictionary *state = [self commanderCommand:@"status"];
    NSString *ip = [state objectForKey:@"ip"];
    NSRunInformationalAlertPanel(@"This Mac", @"%@\n%@\n\nIPv4 addresses: %@", @"OK", nil, nil,
        [TBMachine name], [TBMachine systemVersion], [ip length] ? ip : @"none active");
}
- (void)menuNeedsUpdate:(NSMenu *)menu
{
    NSDictionary *state;
    BOOL enabled;
    NSString *ip;
    if (![[menu title] isEqualToString:@"Command Standalone"]) return;
    state = [self commanderCommand:@"status"];
    enabled = ([[state objectForKey:@"enabled"] intValue] != 0);
    ip = [state objectForKey:@"ip"];
    [[menu itemAtIndex:0] setTitle:enabled ? @"Command Standalone: On" : @"Command Standalone: Off"];
    [[menu itemAtIndex:1] setEnabled:!enabled];
    [[menu itemAtIndex:2] setEnabled:enabled];
    [[menu itemAtIndex:4] setTitle:([[state objectForKey:@"autostart"] intValue] != 0) ? @"Stop Start at Login" : @"Start at Login"];
    [[menu itemAtIndex:5] setTitle:[NSString stringWithFormat:@"IP: %@", [ip length] ? ip : @"unavailable"]];
}
@end
