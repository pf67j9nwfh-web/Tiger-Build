/* Mounts a saved share in the Finder through TBDAV and keeps the server up for a while: davmount NAME [SECONDS]   (TB_SMB_SHARES="NAME = smb://user:password@server/share") */
#import <Foundation/Foundation.h>
#import "TBDAV.h"
#import "TBSMB.h"

int main(int argc, char **argv)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *name = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"", *problem;
    int seconds = argc > 2 ? atoi(argv[2]) : 40;
    if (argc > 3 && !strcmp(argv[3], "put")) {            /* the SMB tool alone, to tell a slow share from a slow bridge */
        @try {
            printf("%s\n", [[TBSMB call:@"smb_put" arguments:[NSDictionary dictionaryWithObjectsAndKeys:name, @"connection", @"put-test.txt", @"path", argc > 4 ? [NSString stringWithUTF8String:argv[4]] : @"written by the tool", @"text", [NSNumber numberWithBool:YES], @"overwrite", nil] allowLocal:NO] UTF8String]);
        } @catch (NSException *e) {
            printf("failed: %s\n", [[e reason] UTF8String]);
        }
        return 0;
    }
    problem = [TBDAV mountShareInFinder:name];
    printf("%s\n", problem ? [problem UTF8String] : "mounted");
    fflush(stdout);
    if (!problem) {
        sleep((unsigned)seconds);
        [TBDAV unmountAll];
        printf("ejected\n");
    }
    [pool release];
    return problem ? 1 : 0;
}
