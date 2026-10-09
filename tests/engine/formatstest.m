/* What the converter makes of each kind of file, from tests/engine/fixtures: formatstest FIXTURES_DIR   (the audio decoding only: TB_AUDIO_DECODE_ONLY) */
#import <Foundation/Foundation.h>
#import "TBExtract.h"
#import "TBEngine.h"

static int failures = 0;
static void expectThat(BOOL ok, NSString *name)
{
    fprintf(stderr, "%s %s\n", ok ? "PASS" : "FAIL", [name UTF8String]);
    if (!ok)
        failures++;
}

static NSDictionary *convert(NSString *dir, NSString *name)
{
    @try {
        return [TBExtract extractName:name data:[NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:name]]];
    } @catch (NSException *e) {
        return [NSDictionary dictionaryWithObject:[e reason] forKey:@"error"];
    }
}

static BOOL isJPEG(NSData *d) { const unsigned char *b = [d bytes]; return [d length] > 3 && b[0] == 0xFF && b[1] == 0xD8; }

int main(int argc, char **argv)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *dir = [NSString stringWithUTF8String:argv[1]];
    NSDictionary *r;
    setenv("TB_AUDIO_DECODE_ONLY", "1", 1);
    r = convert(dir, @"book.epub");
    expectThat([[r objectForKey:@"text"] hasPrefix:@"The Test Book\nby A. Writer"], @"epub: title and author first");
    expectThat([[r objectForKey:@"text"] rangeOfString:@"Chapter One"].location < [[r objectForKey:@"text"] rangeOfString:@"Chapter Two"].location, @"epub: chapters in reading order");
    expectThat([[r objectForKey:@"text"] rangeOfString:@"bright cold day & the clocks"].location != NSNotFound, @"epub: entities are decoded, spaces in file names are followed");
    expectThat([[r objectForKey:@"images"] count] == 1 && isJPEG([[r objectForKey:@"images"] objectAtIndex:0]), @"epub: the cover comes as a JPEG");
    r = convert(dir, @"stuff.zip");
    expectThat([[r objectForKey:@"text"] rangeOfString:@"3 files, 2.9 MB unpacked"].location != NSNotFound, @"zip: counts and sizes");
    expectThat([[r objectForKey:@"text"] rangeOfString:@"src/main.c"].location != NSNotFound && [[r objectForKey:@"text"] rangeOfString:@"folder  src/"].location != NSNotFound, @"zip: files and folders listed");
    r = convert(dir, @"tiny.jxl");
    expectThat([[r objectForKey:@"images"] count] == 1 && isJPEG([[r objectForKey:@"images"] objectAtIndex:0]), @"jpeg xl: lossless picture decodes to a JPEG");
    r = convert(dir, @"tiny-lossy.jxl");
    expectThat([[r objectForKey:@"images"] count] == 1 && isJPEG([[r objectForKey:@"images"] objectAtIndex:0]), @"jpeg xl: lossy picture decodes to a JPEG");
    r = convert(dir, @"tiny.bmp");
    expectThat([[r objectForKey:@"images"] count] == 1 && isJPEG([[r objectForKey:@"images"] objectAtIndex:0]), @"bmp: becomes a JPEG");
    r = convert(dir, @"tiny.tif");
    expectThat([[r objectForKey:@"images"] count] == 1 && isJPEG([[r objectForKey:@"images"] objectAtIndex:0]), @"tif: becomes a JPEG");
    r = convert(dir, @"speech.wav");
    expectThat([[r objectForKey:@"text"] rangeOfString:@"decoded"].location != NSNotFound && [[r objectForKey:@"text"] hasPrefix:@"Audio speech.wav: 0:0"], @"audio: decoded to 16 kHz samples, with its length");
    {
        NSMutableData *junk = [NSMutableData dataWithLength:300];
        BOOL refused = NO;
        memset([junk mutableBytes], 0x41, 300);
        @try { [TBExtract extractName:@"broken.jxl" data:junk]; } @catch (NSException *e) { refused = YES; }
        expectThat(refused, @"jpeg xl: garbage is refused, not decoded");
    }
    fprintf(stderr, failures ? "%d FAILED\n" : "all passed\n", failures);
    [pool release];
    return failures ? 1 : 0;
}
