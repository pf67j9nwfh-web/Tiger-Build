#import <Cocoa/Cocoa.h>
#import "ChatController.h"
#import <string.h>

int main(int argc, char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSApplication *app = [NSApplication sharedApplication];
    ChatController *controller = [[ChatController alloc] init];
    int i;

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
