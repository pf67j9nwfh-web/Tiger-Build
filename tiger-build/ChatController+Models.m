#import "ChatController_Private.h"

/* Configuration, Update Model List: asks each service with a key for its own list of models and adds the new chat models that work (TBModelUpdate).
   It also runs by itself at start and then every six hours. */

@implementation ChatController (Models)

- (void)sendModelListUpdate:(BOOL)manual
{
    if (modelListBusy)
        return;
    modelListBusy = YES;
    [EngineRequest send:@"POST" path:@"/v1/models/refresh" body:@"" timeout:300 target:self action:@selector(modelListUpdated:) context:[NSNumber numberWithBool:manual]];
}

- (IBAction)updateModelList:(id)sender
{
    (void)sender;
    [self sendModelListUpdate:YES];
}

/* Called when the model catalog arrives: once at start, then when six hours have passed. */
- (void)updateModelListIfDue
{
    NSNumber *last = [[NSUserDefaults standardUserDefaults] objectForKey:@"TBModelListUpdated"];
    if ([last doubleValue] > 0 && [[NSDate date] timeIntervalSince1970] - [last doubleValue] < 6 * 3600.0)
        return;
    [self sendModelListUpdate:NO];
}

- (void)modelListUpdated:(EngineRequest *)request
{
    NSString *summary = [request text];
    modelListBusy = NO;
    [self noteSideUsage:request chat:nil];
    if ([request ok])
        [[NSUserDefaults standardUserDefaults] setObject:[NSNumber numberWithDouble:[[NSDate date] timeIntervalSince1970]] forKey:@"TBModelListUpdated"];
    [self refreshCatalog];
    if ([[request context] boolValue])
        NSRunAlertPanel(@"Update Model List", @"%@", @"OK", nil, nil, [request ok] ? summary : @"The update could not be completed.");
}

@end
