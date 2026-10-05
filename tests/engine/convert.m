#import <Foundation/Foundation.h>
/* convert FILE [OUT.jpg]: what Tiger Build's converter makes of a file (the note, how many pictures, the start of the text), and the first
   picture saved to OUT.jpg if given. Built by `make convert` in tiger-build, for trying files on each old Mac. */
#import "TBExtract.h"
int main(int argc, char **argv)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *path = [NSString stringWithUTF8String:argv[1]];
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSDictionary *r;
    @try {
        r = [TBExtract extractName:[path lastPathComponent] data:data];
        if (argc > 2 && [[r objectForKey:@"images"] count])
            [[[r objectForKey:@"images"] objectAtIndex:0] writeToFile:[NSString stringWithUTF8String:argv[2]] atomically:YES];
        printf("NOTE: %s\nIMAGES: %u\nTEXT (%u chars):\n%s\n", [[r objectForKey:@"note"] UTF8String], (unsigned)[[r objectForKey:@"images"] count], (unsigned)[[r objectForKey:@"text"] length], [[[r objectForKey:@"text"] substringToIndex:MIN(1500,[[r objectForKey:@"text"] length])] UTF8String]);
    } @catch (NSException *e) { printf("ERROR: %s\n", [[e reason] UTF8String]); }
    [pool release];
    return 0;
}
