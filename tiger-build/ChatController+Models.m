#import "ChatController_Private.h"
#import "TBProviders.h"

/* Configuration, Update Model List: asks each service with a key for its own list of models and adds the new chat models that work (TBModelUpdate).
   It also runs by itself at start and then every six hours. */

static NSPanel *listPanel = nil;
static NSProgressIndicator *listBar = nil;
static BOOL listManual = NO;        /* someone asked for the update: show the result when it finishes, even if it was already running */

@implementation ChatController (Models)

/* A small window while the update works: it asks each service, then tests new models, which takes a few minutes on a slow Mac. */
- (void)showListProgress
{
    if (!listPanel) {
        NSTextField *text;
        listPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 400, 96) styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
        [listPanel setTitle:@"Update Model List"];
        text = [[[NSTextField alloc] initWithFrame:NSMakeRect(20, 52, 360, 34)] autorelease];
        TBStyleAsLabel(text);
        [text setStringValue:@"Asking each service for its models and trying the new ones. This can take a few minutes on an older Mac; you can keep working."];
        listBar = [[[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 22, 360, 16)] autorelease];
        [listBar setStyle:NSProgressIndicatorBarStyle];
        [listBar setIndeterminate:YES];
        [[listPanel contentView] addSubview:text];
        [[listPanel contentView] addSubview:listBar];
    }
    [listBar startAnimation:nil];
    [listPanel center];
    [listPanel orderFront:nil];
}

- (void)sendModelListUpdate:(BOOL)manual
{
    if (manual) {
        listManual = YES;
        [self showListProgress];
    }
    if (modelListBusy)
        return;      /* one is already running (it starts by itself when Tiger Build opens): its result is shown when it ends */
    modelListBusy = YES;
    [self refreshLocalModels];     /* the local server's own list is read again at the same time */
    [EngineRequest send:@"POST" path:@"/v1/models/refresh" body:@"" timeout:300 target:self action:@selector(modelListUpdated:) context:nil];
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
    [listBar stopAnimation:nil];
    [listPanel orderOut:nil];
    if (listManual) {
        NSString *local = [[TBProviders localBase] length] ? [NSString stringWithFormat:@"\nLocal server: %u model%@", (unsigned)[localModels count], [localModels count] == 1 ? @"" : @"s"] : @"";
        listManual = NO;
        NSRunAlertPanel(@"Update Model List", @"%@%@", @"OK", nil, nil, [request ok] ? summary : @"The update could not be completed.", local);
    }
}

@end
