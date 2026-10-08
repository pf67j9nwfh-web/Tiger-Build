#import <Cocoa/Cocoa.h>
#import "ChatController.h"
#import <string.h>
#import "TBExtract.h"

int main(int argc, char *argv[])
{
    NSAutoreleasePool *pool;
    NSApplication *app;
    ChatController *controller;
    int i;
    if (argc == 4 && strcmp(argv[1], "--convert") == 0)
        return TBConvertCommand(argv[2], argv[3]);
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
