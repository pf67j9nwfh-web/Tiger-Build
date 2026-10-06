/* Writes sample files for checking: outputstest FOLDER */
#import <Foundation/Foundation.h>
#import "TBOutputs.h"
#import "TBExtract.h"
#import "TBEngine.h"

static int failures = 0;
static void expectThat(BOOL ok, NSString *name)
{
    fprintf(stderr, "%s %s\n", ok ? "PASS" : "FAIL", [name UTF8String]);
    if (!ok)
        failures++;
}

int main(int argc, char **argv)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *folder = [NSString stringWithUTF8String:argv[1]], *clean = nil;
    NSString *doc = @"# Title\n\nSome **bold** and `code` & <stuff>.\n- one\n- two\n\n| Name | Qty |\n|---|---|\n| Apple | 3 |\n| Pear | 4 |\n";
    NSData *docx = [TBOutputs buildName:@"My Report.docx" content:doc base64:nil cleanName:&clean];
    NSDictionary *r;
    [docx writeToFile:[folder stringByAppendingPathComponent:@"t.docx"] atomically:NO];
    expectThat([clean isEqualToString:@"My_Report.docx"], @"name is cleaned");
    {
        /* a WebP that a service sends as a "png" is kept as a JPEG, which every system can show */
        const unsigned char tiny[] = {0x52,0x49,0x46,0x46,0x1a,0,0,0,0x57,0x45,0x42,0x50,0x56,0x50,0x38,0x4c,0x0d,0,0,0,0x2f,0,0,0,0x10,0x07,0x10,0x11,0x11,0x88,0x88,0xfe,0x07,0,0};
        NSString *name = TBSaveMedia([NSData dataWithBytes:tiny length:sizeof tiny], @"png");
        expectThat([name hasSuffix:@".jpg"] || [name hasSuffix:@".png"], @"a WebP sent as a picture is stored");
    }
    r = [TBExtract extractName:@"t.docx" data:docx];
    expectThat([[r objectForKey:@"text"] rangeOfString:@"Some bold and code & <stuff>."].location != NSNotFound, @"docx text round trip");
    expectThat([[r objectForKey:@"text"] rangeOfString:@"Apple"].location != NSNotFound && [[r objectForKey:@"text"] rangeOfString:@"Title"].location == 0, @"docx table and heading");
    {
        NSData *xlsx = [TBOutputs buildName:@"d.xlsx" content:@"Item\tCost\nPaint\t12.5\nCode\t0123\n\"a, b\"\t7" base64:nil cleanName:&clean];
        [xlsx writeToFile:[folder stringByAppendingPathComponent:@"t.xlsx"] atomically:NO];
        r = [TBExtract extractName:@"t.xlsx" data:xlsx];
        expectThat([[r objectForKey:@"text"] isEqualToString:@"--- Sheet: Sheet1 ---\nItem\tCost\nPaint\t12.5\nCode\t0123\na, b\t7"], @"xlsx round trip");
    }
    {
        NSData *pdf = [TBOutputs buildName:@"p.pdf" content:doc base64:nil cleanName:&clean];
        [pdf writeToFile:[folder stringByAppendingPathComponent:@"t.pdf"] atomically:NO];
        expectThat([pdf length] > 300 && !memcmp([pdf bytes], "%PDF-1.4", 8), @"pdf header");
    }
    {
        NSData *b = [TBOutputs buildName:@"x.bin" content:nil base64:@"aGVsbG8gd29ybGQ=" cleanName:&clean];
        expectThat([[[[NSString alloc] initWithData:b encoding:NSUTF8StringEncoding] autorelease] isEqualToString:@"hello world"], @"base64");
        expectThat(TBBase64Decode(@"a$b") == nil, @"bad base64");
    }
    @try {
        [TBOutputs buildName:@"e.txt" content:@"  " base64:nil cleanName:&clean];
        expectThat(NO, @"empty content refused");
    } @catch (NSException *e) {
        expectThat(YES, @"empty content refused");
    }
    [pool release];
    return failures ? 1 : 0;
}
