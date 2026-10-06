/* Turns the generated icon into a Tiger-readable .icns. Tiger's Finder displays the classic icon elements (is32, il32, ih32, it32)
   and their 8-bit masks; modern PNG-based icns files stay blank on 10.4.
     clang -framework Cocoa -o /tmp/make-icns make-icns.m && /tmp/make-icns source.png outputfolder */
#import <Cocoa/Cocoa.h>

typedef struct { unsigned char r, g, b, a; } Pixel;

static Pixel *load(NSString *path, int *w, int *h)
{
    NSBitmapImageRep *rep = [NSBitmapImageRep imageRepWithData:[NSData dataWithContentsOfFile:path]];
    Pixel *p;
    int x, y;
    if (!rep) { fprintf(stderr, "not an image: %s\n", [path UTF8String]); exit(1); }
    *w = [rep pixelsWide]; *h = [rep pixelsHigh];
    p = calloc(*w * *h, sizeof(Pixel));
    for (y = 0; y < *h; y++)
        for (x = 0; x < *w; x++) {
            NSColor *c = [[rep colorAtX:x y:y] colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
            Pixel q = { (unsigned char)([c redComponent] * 255 + .5), (unsigned char)([c greenComponent] * 255 + .5), (unsigned char)([c blueComponent] * 255 + .5), (unsigned char)([c alphaComponent] * 255 + .5) };
            p[y * *w + x] = q;
        }
    return p;
}

static void save(NSString *path, Pixel *p, int w, int h)
{
    NSBitmapImageRep *rep = [[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
        colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:w * 4 bitsPerPixel:32] autorelease];
    memcpy([rep bitmapData], p, w * h * 4);
    [[rep representationUsingType:NSPNGFileType properties:nil] writeToFile:path atomically:YES];
}

static int dist(Pixel a, Pixel b) { return abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b); }

/* The source is a JPEG, so the backdrop is a crushed magenta rather than #ff00ff. Flood from the corners; JPEG fringes close to
   the backdrop are dropped so the rounded tile keeps no halo. */
static Pixel *keyBackdrop(Pixel *p, int w, int h)
{
    Pixel bg = p[0], *out = calloc(w * h, sizeof(Pixel));
    char *gone = calloc(w * h, 1);
    int *stack = malloc(sizeof(int) * 2 * w * h * 4), n = 0, i;
    int starts[4][2] = {{0, 0}, {w - 1, 0}, {0, h - 1}, {w - 1, h - 1}};
    for (i = 0; i < 4; i++) { stack[n++] = starts[i][0]; stack[n++] = starts[i][1]; }
    while (n) {
        int y = stack[--n], x = stack[--n], k = y * w + x;
        if (gone[k] || dist(p[k], bg) > 48) continue;
        gone[k] = 1;
        if (x > 0) { stack[n++] = x - 1; stack[n++] = y; }
        if (x + 1 < w) { stack[n++] = x + 1; stack[n++] = y; }
        if (y > 0) { stack[n++] = x; stack[n++] = y - 1; }
        if (y + 1 < h) { stack[n++] = x; stack[n++] = y + 1; }
    }
    for (i = 0; i < w * h; i++)
        if (!gone[i] && dist(p[i], bg) >= 100) { out[i] = p[i]; out[i].a = 255; }
    free(gone); free(stack);
    return out;
}

static Pixel *shrink(Pixel *p, int w, int h, int size)
{
    Pixel *out = calloc(size * size, sizeof(Pixel));
    int x, y;
    for (y = 0; y < size; y++)
        for (x = 0; x < size; x++) {
            int x0 = x * w / size, x1 = (x + 1) * w / size, y0 = y * h / size, y1 = (y + 1) * h / size, xx, yy, count = 0;
            long sr = 0, sg = 0, sb = 0, sa = 0;
            if (x1 <= x0) x1 = x0 + 1;
            if (y1 <= y0) y1 = y0 + 1;
            for (yy = y0; yy < y1; yy++)
                for (xx = x0; xx < x1; xx++) { Pixel q = p[yy * w + xx]; sr += q.r; sg += q.g; sb += q.b; sa += q.a; count++; }
            out[y * size + x] = (Pixel){ sr / count, sg / count, sb / count, sa / count };
        }
    return out;
}

/* Whole-channel PackBits, as the icns rgb layout wants (not per scanline) */
static void pack(NSMutableData *out, const unsigned char *d, int end)
{
    unsigned char buf[128];
    int nb = 0, i = 0;
#define FLUSH do { if (nb) { unsigned char c = nb - 1; [out appendBytes:&c length:1]; [out appendBytes:buf length:nb]; nb = 0; } } while (0)
    while (i < end) {
        if (i + 2 < end && d[i] == d[i + 1] && d[i] == d[i + 2]) {
            int count = 3;
            unsigned char c;
            FLUSH;
            while (i + count < end && d[i + count] == d[i] && count < 130) count++;
            c = count + 0x7D;
            [out appendBytes:&c length:1];
            [out appendBytes:&d[i] length:1];
            i += count;
        } else {
            buf[nb++] = d[i++];
            if (nb > 127) FLUSH;
        }
    }
    FLUSH;
}

static void element(NSMutableData *icns, const char *type, NSData *body)
{
    unsigned long n = 8 + [body length];
    unsigned char len[4] = { n >> 24, n >> 16, n >> 8, n };
    [icns appendBytes:type length:4];
    [icns appendBytes:len length:4];
    [icns appendData:body];
}

int main(int argc, char **argv)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *out;
    int w, h, i, c, k;
    Pixel *src, *keyed;
    struct { const char *rgb, *mask; int size; } wanted[4] = { {"is32", "s8mk", 16}, {"il32", "l8mk", 32}, {"ih32", "h8mk", 48}, {"it32", "t8mk", 128} };
    NSMutableData *icns = [NSMutableData data];
    if (argc != 3) { fprintf(stderr, "usage: make-icns source.png outputfolder\n"); return 2; }
    (void)NSApplicationLoad();
    out = [NSString stringWithUTF8String:argv[2]];
    src = load([NSString stringWithUTF8String:argv[1]], &w, &h);
    keyed = keyBackdrop(src, w, h);
    save([out stringByAppendingPathComponent:@"icon-1024.png"], keyed, w, h);
    for (i = 0; i < 4; i++) {
        int size = wanted[i].size;
        Pixel *small = shrink(keyed, w, h, size);
        NSMutableData *rgb = [NSMutableData data], *mask = [NSMutableData data];
        unsigned char *plane = malloc(size * size);
        save([out stringByAppendingPathComponent:[NSString stringWithFormat:@"icon-%d.png", size]], small, size, size);
        if (size == 128) [rgb appendBytes:"\0\0\0\0" length:4];
        for (c = 0; c < 3; c++) {
            for (k = 0; k < size * size; k++) plane[k] = c == 0 ? small[k].r : (c == 1 ? small[k].g : small[k].b);
            pack(rgb, plane, size * size);
        }
        for (k = 0; k < size * size; k++) { unsigned char a = small[k].a; [mask appendBytes:&a length:1]; }
        element(icns, wanted[i].rgb, rgb);
        element(icns, wanted[i].mask, mask);
        free(plane); free(small);
    }
    save([out stringByAppendingPathComponent:@"icon-512.png"], shrink(keyed, w, h, 512), 512, 512);
    {   /* the icns header is the same shape as an element: type, then total length */
        NSMutableData *whole = [NSMutableData data];
        element(whole, "icns", icns);
        [whole writeToFile:[out stringByAppendingPathComponent:@"TigerBuild.icns"] atomically:YES];
    }
    printf("wrote %s/TigerBuild.icns\n", argv[2]);
    [pool release];
    return 0;
}
