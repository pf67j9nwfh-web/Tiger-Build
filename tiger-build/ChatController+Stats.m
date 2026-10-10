#import "ChatController_Private.h"

/* Tokens and time for each reply (View, Show Tokens and Time): while a reply is made, each model call's usage line adds its tokens to the reply's message and
   stamps how long the reply has taken since it was sent; the transcript shows the totals under the reply when the setting is on. The numbers stay with
   the message either way, so switching the setting on shows them for replies made earlier. */

@implementation ChatController (Stats)

- (void)noteTurnStats:(NSDictionary *)event chat:(NSMutableDictionary *)chat
{
    NSMutableDictionary *open = [self openMessageIn:chat];
    double started = [[chat objectForKey:@"turnStart"] doubleValue];
    int in, out;
    if (!open || started <= 0)
        return;
    in = [[event objectForKey:@"input"] intValue] + [[event objectForKey:@"cached"] intValue] + [[event objectForKey:@"written"] intValue];
    out = [[event objectForKey:@"output"] intValue];
    [open setObject:[NSNumber numberWithInt:[[open objectForKey:@"statsIn"] intValue] + in] forKey:@"statsIn"];
    [open setObject:[NSNumber numberWithInt:[[open objectForKey:@"statsOut"] intValue] + out] forKey:@"statsOut"];
    [open setObject:[NSNumber numberWithDouble:CFAbsoluteTimeGetCurrent() - started] forKey:@"statsSeconds"];
}

- (void)markTurnStart:(NSMutableDictionary *)chat
{
    [chat setObject:[NSNumber numberWithDouble:CFAbsoluteTimeGetCurrent()] forKey:@"turnStart"];
}

- (IBAction)toggleStats:(id)sender
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    (void)sender;
    [defaults setBool:![defaults boolForKey:@"TBShowStats"] forKey:@"TBShowStats"];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TBStatsChanged" object:nil];
}

@end
