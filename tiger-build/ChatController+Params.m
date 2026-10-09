#import "ChatController_Private.h"

/* Model parameters for a chat: temperature, top_p and the longest answer. Each one is used only when its box is ticked; a model that refuses one
   gets the request again without it (and the chat says so). */

@implementation ChatController (Params)

- (IBAction)editParameters:(id)sender
{
    NSPanel *panel;
    NSDictionary *have;
    NSString *keys[3] = { @"temperature", @"top_p", @"max_tokens" };
    NSString *titles[3] = { @"Temperature (0 to 2; lower is steadier)", @"Top P (0 to 1)", @"Longest answer, in tokens" };
    NSString *defaults[3] = { @"1.0", @"1.0", @"4096" };
    NSButton *boxes[3];
    NSTextField *fields[3];
    NSButton *everyChat, *ok, *cancel;
    NSTextField *label;
    int i, result;
    (void)sender;
    if (!current)
        return;
    have = [current objectForKey:@"params"];
    panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 440, 230) styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
    [panel setTitle:@"Model Parameters"];
    label = [[[NSTextField alloc] initWithFrame:NSMakeRect(20, 186, 400, 34)] autorelease];
    [label setStringValue:@"Tick a setting to send it with every message of this chat. Unticked settings stay at the model's own default."];
    [label setBezeled:NO]; [label setDrawsBackground:NO]; [label setEditable:NO]; [label setSelectable:NO];
    [[panel contentView] addSubview:label];
    for (i = 0; i < 3; i++) {
        id value = [have isKindOfClass:[NSDictionary class]] ? [have objectForKey:keys[i]] : nil;
        float y = 152 - i * 32;
        boxes[i] = [[[NSButton alloc] initWithFrame:NSMakeRect(20, y, 290, 22)] autorelease];
        [boxes[i] setButtonType:NSSwitchButton];
        [boxes[i] setTitle:titles[i]];
        [boxes[i] setState:value ? NSOnState : NSOffState];
        fields[i] = [[[NSTextField alloc] initWithFrame:NSMakeRect(320, y, 100, 22)] autorelease];
        [fields[i] setStringValue:value ? [value description] : defaults[i]];
        [[panel contentView] addSubview:boxes[i]];
        [[panel contentView] addSubview:fields[i]];
    }
    everyChat = [[[NSButton alloc] initWithFrame:NSMakeRect(20, 54, 400, 22)] autorelease];
    [everyChat setButtonType:NSSwitchButton];
    [everyChat setTitle:@"Also use these for every new chat in this workspace"];
    [[panel contentView] addSubview:everyChat];
    ok = [[[NSButton alloc] initWithFrame:NSMakeRect(340, 12, 80, 28)] autorelease];
    [ok setTitle:@"OK"]; [ok setBezelStyle:NSRoundedBezelStyle]; [ok setKeyEquivalent:@"\r"];
    [ok setTarget:self]; [ok setAction:@selector(endInstructionsOK:)];
    cancel = [[[NSButton alloc] initWithFrame:NSMakeRect(250, 12, 80, 28)] autorelease];
    [cancel setTitle:@"Cancel"]; [cancel setBezelStyle:NSRoundedBezelStyle]; [cancel setKeyEquivalent:@"\033"];
    [cancel setTarget:self]; [cancel setAction:@selector(endInstructionsCancel:)];
    [[panel contentView] addSubview:ok];
    [[panel contentView] addSubview:cancel];
    [panel setDefaultButtonCell:[ok cell]];
    [panel center];
    [panel setLevel:NSFloatingWindowLevel];
    result = [NSApp runModalForWindow:panel];
    [panel orderOut:nil];
    if (result == 1) {
        NSMutableDictionary *params = [NSMutableDictionary dictionary];
        double v;
        for (i = 0; i < 3; i++) {
            if ([boxes[i] state] != NSOnState)
                continue;
            v = [[fields[i] stringValue] doubleValue];
            if (i == 0 && v >= 0 && v <= 2 && [[fields[i] stringValue] length])
                [params setObject:[NSNumber numberWithDouble:v] forKey:keys[i]];
            else if (i == 1 && v > 0 && v <= 1)
                [params setObject:[NSNumber numberWithDouble:v] forKey:keys[i]];
            else if (i == 2 && v >= 16 && v <= 400000)
                [params setObject:[NSNumber numberWithInt:(int)v] forKey:keys[i]];
        }
        if ([params count]) [current setObject:params forKey:@"params"];
        else [current removeObjectForKey:@"params"];
        if ([everyChat state] == NSOnState) {
            if ([params count]) [workspaceSettings setObject:params forKey:@"params"];
            else [workspaceSettings removeObjectForKey:@"params"];
        }
        [self saveStore];
    }
    [panel release];
}

@end
