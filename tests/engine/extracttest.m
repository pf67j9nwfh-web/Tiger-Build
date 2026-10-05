#import <Foundation/Foundation.h>
#import "TBExtract.h"
#import "TBEngine.h"
/* usage: extracttest file... ; prints what each file gives */
int main(int argc, char **argv)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    int i;
    for (i = 1; i < argc; i++) {
        NSString *path = [NSString stringWithUTF8String:argv[i]];
        NSData *data = [NSData dataWithContentsOfFile:path];
        @try {
            NSDictionary *r = [TBExtract extractName:[path lastPathComponent] data:data];
            NSString *text = [r objectForKey:@"text"];
            printf("== %s: %u chars, %u images, note: %s\n", argv[i], (unsigned)[text length], (unsigned)[[r objectForKey:@"images"] count], [[r objectForKey:@"note"] UTF8String]);
            if ([[r objectForKey:@"images"] count] && getenv("DUMP"))
                [[[r objectForKey:@"images"] objectAtIndex:0] writeToFile:[path stringByAppendingString:@".out.jpg"] atomically:NO];
            printf("%s\n", [[text length] > 600 ? [text substringToIndex:600] : text UTF8String]);
        } @catch (NSException *e) {
            printf("== %s: FAILED %s\n", argv[i], [[e reason] UTF8String]);
        }
    }
    [pool release];
    return 0;
}
