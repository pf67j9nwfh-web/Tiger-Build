/* What the converter makes of each kind of file, from tests/engine/fixtures: formatstest FIXTURES_DIR   (the audio decoding only: TB_AUDIO_DECODE_ONLY) */
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import "TBExtract.h"
#import "TBEngine.h"
#import "expect.h"


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
    r = convert(dir, @"tiny.svg");
    expectThat([[r objectForKey:@"text"] rangeOfString:@"<circle"].location != NSNotFound && [[r objectForKey:@"images"] count] == 1 && isJPEG([[r objectForKey:@"images"] objectAtIndex:0]), @"svg: the source as text and a picture of it as a JPEG");
    {
        NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:[[r objectForKey:@"images"] objectAtIndex:0]];
        /* the red circle is at about 3/8 across and halfway down; the corner is white */
        NSColor *dot = [[rep colorAtX:(int)([rep pixelsWide] * 0.375) y:(int)([rep pixelsHigh] * 0.5)] colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
        NSColor *corner = [[rep colorAtX:2 y:2] colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
        expectThat([dot redComponent] > 0.6 && [dot greenComponent] < 0.35 && [dot blueComponent] < 0.35 && [corner redComponent] > 0.9 && [corner greenComponent] > 0.9 && [corner blueComponent] > 0.9, @"svg: drawn where it should be (red circle, white corner)");
    }
    r = convert(dir, @"gradient.svg");
    {
        NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:[[r objectForKey:@"images"] objectAtIndex:0]];
        int w = (int)[rep pixelsWide], h = (int)[rep pixelsHigh], white = 0, x, y;
        NSColor *top = [[rep colorAtX:3 y:3] colorUsingColorSpaceName:NSCalibratedRGBColorSpace], *bottom = [[rep colorAtX:3 y:h - 4] colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
        expectThat([top redComponent] > 0.8 && [top blueComponent] < 0.25 && [bottom blueComponent] > 0.8 && [bottom redComponent] < 0.25, @"svg: a gradient with plain 0 to 1 coordinates runs from red at the top to blue at the bottom");
        /* the word "Hi" is white over the middle of the picture */
        for (y = h * 3 / 10; y < h * 7 / 10; y++)
            for (x = w * 3 / 10; x < w * 7 / 10; x++) {
                NSColor *c = [[rep colorAtX:x y:y] colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
                if ([c redComponent] > 0.85 && [c greenComponent] > 0.85 && [c blueComponent] > 0.85)
                    white++;
            }
        expectThat(white > (w * h) / 150, @"svg: text is drawn (white letters over the gradient)");
    }
    r = convert(dir, @"tiny.svgz");
    expectThat([[r objectForKey:@"text"] rangeOfString:@"<circle"].location != NSNotFound && [[r objectForKey:@"images"] count] == 1, @"svgz: gzipped SVG is read the same way");
    @try {
        r = [TBExtract extractName:@"notes.svg" data:[@"<html>no drawing here</html>" dataUsingEncoding:NSUTF8StringEncoding]];
        expectThat(NO, @"svg: a file that is not a drawing is refused");
    } @catch (NSException *e) {
        expectThat([[e reason] rangeOfString:@"does not look like an SVG"].location != NSNotFound, @"svg: a file that is not a drawing is refused");
    }
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
