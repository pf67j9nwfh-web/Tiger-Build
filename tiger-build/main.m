#import <Cocoa/Cocoa.h>
#import "ChatController.h"
#import <string.h>
#import "TBExtract.h"
#import "TBSpotlight.h"

int main(int argc, char *argv[])
{
    NSAutoreleasePool *pool;
    NSApplication *app;
    ChatController *controller;
    int i;
    if (argc == 4 && strcmp(argv[1], "--convert") == 0)
        return TBConvertCommand(argv[2], argv[3]);
    if (argc == 3 && strcmp(argv[1], "--spotlight") == 0) {
        /* TigerBuild --spotlight on|off|update: switches Spotlight search of the chats from a terminal, or brings the files up to date */
        NSString *why = nil;
        pool = [[NSAutoreleasePool alloc] init];
        if (strcmp(argv[2], "update") == 0)
            [TBSpotlight rebuildAll];
        else
            why = [TBSpotlight setEnabled:strcmp(argv[2], "on") == 0];
        if (why)
            fprintf(stderr, "%s\n", [why UTF8String]);
        [pool release];
        return why ? 1 : 0;
    }
    pool = [[NSAutoreleasePool alloc] init];
    app = [NSApplication sharedApplication];

    /* Before 1.2 the bundle identifier was local.jr.tigerbuild. Carry its
       preferences (window, sidebar, current workspace) over once. */
    {
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        NSString *current = [[NSBundle mainBundle] bundleIdentifier];
        NSString *old = @"local.jr.tigerbuild";
        if (current && ![current isEqualToString:old] && ![defaults persistentDomainForName:current]) {
            NSDictionary *saved = [defaults persistentDomainForName:old];
            if (saved) {
                [defaults setPersistentDomain:saved forName:current];
                [defaults synchronize];
            }
        }
    }
    controller = [[ChatController alloc] init];

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--ask") == 0 && i + 1 < argc) {
            [controller setLaunchQuestion:[NSString stringWithUTF8String:argv[i + 1]]];
            i++;
        } else if (strcmp(argv[i], "--screen") == 0 && i + 1 < argc) {
            /* For the documentation's screenshots: "prefs:2" opens Preferences on its third tab, "tools:1" the tools window. */
            [controller setLaunchScreen:[NSString stringWithUTF8String:argv[i + 1]]];
            i++;
        }
    }
    [app setDelegate:controller];
    [app run];
    [controller release];
    [pool release];
    return 0;
}
