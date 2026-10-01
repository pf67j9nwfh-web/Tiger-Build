#import <Cocoa/Cocoa.h>
#import "ChatController.h"
#import <string.h>

int main(int argc, char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSApplication *app = [NSApplication sharedApplication];
    ChatController *controller;
    int i;

    /* Before 1.6 the bundle identifier was local.jr.tigerbuild. Carry its
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
        }
    }
    [app setDelegate:controller];
    [app run];
    [controller release];
    [pool release];
    return 0;
}
