#import "ChatController_Private.h"
#import "TBProviders.h"

/* Configuration, Update Model List: asks each service with a key for its own list of models and adds the new chat models that work (TBModelUpdate).
   It also runs by itself at start and then every six hours. */

@implementation ChatController (Models)

- (void)sendModelListUpdate:(BOOL)manual
{
    if (modelListBusy) {
        if (manual)
            NSRunAlertPanel(@"Update Model List", @"An update is already running (it starts by itself when Tiger Build opens). Its result will be shown if you ask again in a minute.", @"OK", nil, nil);
        return;
    }
    modelListBusy = YES;
    [self refreshLocalModels];     /* the local server's own list is read again at the same time */
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
    if ([[request context] boolValue]) {
        NSString *local = [[TBProviders localBase] length] ? [NSString stringWithFormat:@"\nLocal server: %u model%@", (unsigned)[localModels count], [localModels count] == 1 ? @"" : @"s"] : @"";
        NSRunAlertPanel(@"Update Model List", @"%@%@", @"OK", nil, nil, [request ok] ? summary : @"The update could not be completed.", local);
    }
}

@end
