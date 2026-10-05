#import "TBHEIC.h"
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>
#import <stdint.h>
#import <math.h>
#import "aom/aom_decoder.h"
#import "aom/aomdx.h"

/* ---- libde265, found at run time ---- */

typedef void *(*NewDecoder)(void);
typedef int (*FreeDecoder)(void *);
typedef int (*PushNAL)(void *, const void *, int, long long, void *);
typedef int (*FlushData)(void *);
typedef int (*Decode)(void *, int *);
typedef const void *(*NextPicture)(void *);
typedef int (*ImageInt)(const void *, int);
typedef const uint8_t *(*ImagePlane)(const void *, int, int *);
typedef int (*ChromaFormat)(const void *);
typedef int (*Init)(void);
typedef const char *(*ErrorText)(int);

static struct {
    void *handle;
    NewDecoder newDecoder;
    FreeDecoder freeDecoder;
    PushNAL push;
    FlushData flush;
    Decode decode;
    NextPicture next;
    ImageInt width, height, bits;
    ImagePlane plane;
    ChromaFormat chroma;
    ErrorText errorText;
} lib;

static NSString *loadLibrary(void)
{
    NSString *override = [[NSUserDefaults standardUserDefaults] stringForKey:@"TBDE265Path"];
    NSString *path = [override length] ? override : [[[NSBundle mainBundle] privateFrameworksPath] stringByAppendingPathComponent:@"libde265.dylib"];
    Init init;
    if (lib.handle)
        return nil;
    lib.handle = dlopen([path fileSystemRepresentation], RTLD_NOW | RTLD_LOCAL);
    if (!lib.handle)
        return @"The HEIC decoder (libde265) is not in this copy of Tiger Build.";
    lib.newDecoder = (NewDecoder)dlsym(lib.handle, "de265_new_decoder");
    lib.freeDecoder = (FreeDecoder)dlsym(lib.handle, "de265_free_decoder");
    lib.push = (PushNAL)dlsym(lib.handle, "de265_push_NAL");
    lib.flush = (FlushData)dlsym(lib.handle, "de265_flush_data");
    lib.decode = (Decode)dlsym(lib.handle, "de265_decode");
    lib.next = (NextPicture)dlsym(lib.handle, "de265_get_next_picture");
    lib.width = (ImageInt)dlsym(lib.handle, "de265_get_image_width");
    lib.height = (ImageInt)dlsym(lib.handle, "de265_get_image_height");
    lib.bits = (ImageInt)dlsym(lib.handle, "de265_get_bits_per_pixel");
    lib.plane = (ImagePlane)dlsym(lib.handle, "de265_get_image_plane");
    lib.chroma = (ChromaFormat)dlsym(lib.handle, "de265_get_chroma_format");
    lib.errorText = (ErrorText)dlsym(lib.handle, "de265_get_error_text");
    init = (Init)dlsym(lib.handle, "de265_init");
    if (!lib.newDecoder || !lib.freeDecoder || !lib.push || !lib.flush || !lib.decode || !lib.next || !lib.width || !lib.height || !lib.plane || !lib.chroma || !init) {
        dlclose(lib.handle);
        lib.handle = NULL;
        return @"The HEIC decoder is damaged.";
    }
    init();
    return nil;
}

/* ---- the container (ISO base media file format) ---- */

typedef struct {
    unsigned id;
    char type[5];
    int constructionMethod;
    unsigned long long offset, length;   /* of the first extent; items are stored in one piece */
    BOOL singleExtent;
    unsigned width, height;
    NSMutableArray *properties;          /* NSData of each property box, by index */
} Item;

@interface TBBox : NSObject {
@public
    unsigned long long start, end;       /* the payload */
    char type[5];
}
@end
@implementation TBBox
@end

static unsigned be16(const uint8_t *p) { return (p[0] << 8) | p[1]; }
static unsigned be32(const uint8_t *p) { return ((unsigned)p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3]; }
static unsigned long long be64(const uint8_t *p) { return ((unsigned long long)be32(p) << 32) | be32(p + 4); }

/* the boxes between start and end */
static NSArray *boxes(const uint8_t *d, unsigned long long start, unsigned long long end, unsigned long long total)
{
    NSMutableArray *out = [NSMutableArray array];
    unsigned long long at = start;
    if (end > total)
        end = total;
    while (at + 8 <= end) {
        unsigned long long size = be32(d + at), header = 8;
        TBBox *box = [[[TBBox alloc] init] autorelease];
        memcpy(box->type, d + at + 4, 4);
        box->type[4] = 0;
        if (size == 1) {
            if (at + 16 > end)
                break;
            size = be64(d + at + 8);
            header = 16;
        } else if (size == 0)
            size = end - at;
        if (size < header || at + size > end)
            break;
        box->start = at + header;
        box->end = at + size;
        [out addObject:box];
        at += size;
    }
    return out;
}

static TBBox *find(NSArray *list, const char *type)
{
    unsigned i;
    for (i = 0; i < [list count]; i++)
        if (!strcmp(((TBBox *)[list objectAtIndex:i])->type, type))
            return [list objectAtIndex:i];
    return nil;
}

/* a big-endian number of 0, 4 or 8 bytes (and 1, 2 for the small ones) */
static unsigned long long number(const uint8_t *p, int size)
{
    unsigned long long v = 0;
    int i;
    for (i = 0; i < size; i++)
        v = (v << 8) | p[i];
    return v;
}

/* ---- YCbCr to RGB ---- */

static inline uint8_t clamp8(int v) { return v < 0 ? 0 : (v > 255 ? 255 : (uint8_t)v); }

typedef struct {
    int rv, gu, gv, bu;   /* 16.16 */
    BOOL full;
    BOOL p3;              /* Display P3 colours (iPhones), brought to sRGB */
} Matrix;

/* Display P3 to sRGB: both use the sRGB curve, so it is a matrix in linear light. Tables make it cheap on a slow Mac. */
static unsigned short linearOf[256];
static unsigned char encodedOf[4096];
static BOOL tablesReady = NO;

static void makeTables(void)
{
    int i;
    if (tablesReady)
        return;
    for (i = 0; i < 256; i++) {
        double c = i / 255.0;
        double l = c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
        linearOf[i] = (unsigned short)(l * 4095 + 0.5);
    }
    for (i = 0; i < 4096; i++) {
        double l = i / 4095.0;
        double c = l <= 0.0031308 ? l * 12.92 : 1.055 * pow(l, 1 / 2.4) - 0.055;
        int v = (int)(c * 255 + 0.5);
        encodedOf[i] = v < 0 ? 0 : (v > 255 ? 255 : v);
    }
    tablesReady = YES;
}

static void fromP3(int *r, int *g, int *b)
{
    int lr = linearOf[*r], lg = linearOf[*g], lb = linearOf[*b];
    int nr = (5017 * lr - 921 * lg + 2048) >> 12;                 /*  1.22494 -0.22494  0       */
    int ng = (-172 * lr + 4268 * lg + 2048) >> 12;                /* -0.04206  1.04206  0       */
    int nb = (-80 * lr - 322 * lg + 4499 * lb + 2048) >> 12;      /* -0.01964 -0.07864  1.09827 */
    *r = encodedOf[nr < 0 ? 0 : (nr > 4095 ? 4095 : nr)];
    *g = encodedOf[ng < 0 ? 0 : (ng > 4095 ? 4095 : ng)];
    *b = encodedOf[nb < 0 ? 0 : (nb > 4095 ? 4095 : nb)];
}

/* matrix_coefficients from the file's colour box: 1 is BT.709, 5 and 6 are BT.601 (what iPhones use) */
static Matrix matrixFor(int coefficients, BOOL full)
{
    double kr, kb, kg;
    Matrix m;
    if (coefficients == 1) { kr = 0.2126; kb = 0.0722; }
    else if (coefficients == 9) { kr = 0.2627; kb = 0.0593; }
    else { kr = 0.299; kb = 0.114; }
    kg = 1 - kr - kb;
    m.rv = (int)(2 * (1 - kr) * 65536 + 0.5);
    m.bu = (int)(2 * (1 - kb) * 65536 + 0.5);
    m.gu = (int)(2 * (1 - kb) * kb / kg * 65536 + 0.5);
    m.gv = (int)(2 * (1 - kr) * kr / kg * 65536 + 0.5);
    m.full = full;
    m.p3 = NO;
    return m;
}

/* Decodes one hvc1 item to the canvas at (x, y). The tile's size on the canvas is `cw` by `ch` (the part inside the picture). */
static NSString *decodeItem(Item *item, NSData *hvcC, const uint8_t *file, unsigned long long fileLength, uint8_t *canvas, unsigned canvasWidth, unsigned canvasHeight, unsigned x, unsigned y, Matrix matrix)
{
    const uint8_t *c = [hvcC bytes];
    unsigned long long length = [hvcC length], at;
    int lengthSize, arrays, a;
    void *decoder;
    const void *picture = NULL;
    int more = 1, rounds = 0;
    unsigned w, h, row, col;
    int stride0, stride1, stride2, chroma, bits;
    const uint8_t *p0, *p1, *p2;
    if (length < 23)
        return @"The picture's settings are damaged.";
    lengthSize = (c[21] & 3) + 1;
    arrays = c[22];
    if (item->offset + item->length > fileLength)
        return @"The picture data is cut short.";
    decoder = lib.newDecoder();
    if (!decoder)
        return @"The decoder could not start.";
    at = 23;
    for (a = 0; a < arrays; a++) {
        int count, n;
        if (at + 3 > length)
            break;
        count = be16(c + at + 1);
        at += 3;
        for (n = 0; n < count; n++) {
            unsigned size;
            if (at + 2 > length)
                break;
            size = be16(c + at);
            at += 2;
            if (at + size > length)
                break;
            lib.push(decoder, c + at, size, 0, NULL);
            at += size;
        }
    }
    at = item->offset;
    while (at + lengthSize <= item->offset + item->length) {
        unsigned size = (unsigned)number(file + at, lengthSize);
        at += lengthSize;
        if (at + size > item->offset + item->length)
            break;
        lib.push(decoder, file + at, size, 0, NULL);
        at += size;
    }
    lib.flush(decoder);
    while (more && !picture && rounds++ < 100000) {
        int err = lib.decode(decoder, &more);
        picture = lib.next(decoder);
        if (err != 0 && err < 1000 && !picture && !more)
            break;
    }
    if (!picture) {
        lib.freeDecoder(decoder);
        return @"The picture could not be decoded.";
    }
    w = lib.width(picture, 0);
    h = lib.height(picture, 0);
    chroma = lib.chroma(picture);
    bits = lib.bits(picture, 0);
    p0 = lib.plane(picture, 0, &stride0);
    p1 = chroma ? lib.plane(picture, 1, &stride1) : NULL;
    p2 = chroma ? lib.plane(picture, 2, &stride2) : NULL;
    if (!p0 || (chroma && (!p1 || !p2)) || bits < 8 || bits > 16) {
        lib.freeDecoder(decoder);
        return @"This kind of HEIC picture is not supported.";
    }
    if (x + w > canvasWidth)
        w = canvasWidth - x;
    if (y + h > canvasHeight)
        h = canvasHeight - y;
    {
        int shift = bits - 8;
        int cx = chroma == 3 ? 0 : 1, cy = chroma == 1 ? 1 : 0;
        for (row = 0; row < h; row++) {
            uint8_t *out = canvas + ((size_t)(y + row) * canvasWidth + x) * 3;
            for (col = 0; col < w; col++) {
                int Y, Cb = 128, Cr = 128, r, g, b;
                if (bits == 8)
                    Y = p0[(size_t)row * stride0 + col];
                else
                    Y = ((const uint16_t *)(p0 + (size_t)row * stride0))[col] >> shift;
                if (chroma) {
                    size_t o1 = (size_t)(row >> cy) * stride1, o2 = (size_t)(row >> cy) * stride2;
                    if (bits == 8) {
                        Cb = p1[o1 + (col >> cx)];
                        Cr = p2[o2 + (col >> cx)];
                    } else {
                        Cb = ((const uint16_t *)(p1 + o1))[col >> cx] >> shift;
                        Cr = ((const uint16_t *)(p2 + o2))[col >> cx] >> shift;
                    }
                }
                if (!matrix.full) {
                    /* video range: 16 to 235 for luma, 16 to 240 for chroma */
                    Y = ((Y - 16) * 255 + 109) / 219;
                    Cb = 128 + ((Cb - 128) * 255 + 112) / 224;
                    Cr = 128 + ((Cr - 128) * 255 + 112) / 224;
                }
                r = Y + ((matrix.rv * (Cr - 128) + 32768) >> 16);
                g = Y - ((matrix.gu * (Cb - 128) + matrix.gv * (Cr - 128) + 32768) >> 16);
                b = Y + ((matrix.bu * (Cb - 128) + 32768) >> 16);
                r = clamp8(r);
                g = clamp8(g);
                b = clamp8(b);
                if (matrix.p3)
                    fromP3(&r, &g, &b);
                out[0] = r;
                out[1] = g;
                out[2] = b;
                out += 3;
            }
        }
    }
    lib.freeDecoder(decoder);
    return nil;
}

/* The alpha picture of an AVIF: an av01 item that an auxl reference ties to the main picture and whose auxC names alpha. */
static Item *findAlpha(NSDictionary *items, TBBox *iref, const uint8_t *d, unsigned long long total, unsigned primary, NSData **config)
{
    NSArray *refs;
    unsigned i, j;
    int rv;
    if (!iref)
        return NULL;
    rv = d[iref->start];
    refs = boxes(d, iref->start + 4, iref->end, total);
    for (i = 0; i < [refs count]; i++) {
        TBBox *r = [refs objectAtIndex:i];
        unsigned long long p = r->start;
        unsigned from = rv == 0 ? be16(d + p) : be32(d + p), n;
        Item *item;
        BOOL names = NO;
        if (strcmp(r->type, "auxl") || p + 4 > r->end)
            continue;
        p += rv == 0 ? 2 : 4;
        n = be16(d + p);
        p += 2;
        for (j = 0; j < n && p + (rv == 0 ? 2 : 4) <= r->end; j++, p += (rv == 0 ? 2 : 4)) {
            unsigned to = rv == 0 ? be16(d + p) : be32(d + p);
            if (to == primary)
                names = YES;
        }
        item = names ? [[items objectForKey:[NSNumber numberWithUnsignedInt:from]] pointerValue] : NULL;
        if (!item || strcmp(item->type, "av01"))
            continue;
        {
            BOOL alpha = NO;
            unsigned k;
            for (k = 0; k < [item->properties count]; k++) {
                NSData *pr = [item->properties objectAtIndex:k];
                if ([pr length] > 8 && !memcmp([pr bytes], "auxC", 4)) {
                    const uint8_t *z = [pr bytes];
                    unsigned m;
                    for (m = 4; m + 5 <= [pr length]; m++)
                        if (!memcmp(z + m, "alpha", 5))
                            alpha = YES;
                }
                else if ([pr length] > 4 && !memcmp([pr bytes], "av1C", 4))
                    *config = [NSData dataWithBytes:(const uint8_t *)[pr bytes] + 4 length:[pr length] - 4];
            }
            if (alpha && *config)
                return item;
        }
    }
    return NULL;
}

@implementation TBHEIC

+ (BOOL)looksLikeHEIF:(NSData *)data
{
    const uint8_t *d = [data bytes];
    return [data length] > 16 && !memcmp(d + 4, "ftyp", 4);
}

/* ---- the picture ---- */

/* ops, in the order the file lists them: 1000 + n is irot (n quarter turns anticlockwise), 2000 + axis is imir (0 swaps top and bottom, 1 left and right) */
static NSData *jpegFromRGB(uint8_t *rgb, unsigned width, unsigned height, NSArray *ops, int longest)
{
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, rgb, (size_t)width * height * 3, NULL);
    CGImageRef image = CGImageCreate(width, height, 8, 24, (size_t)width * 3, space, kCGImageAlphaNone, provider, NULL, false, kCGRenderingIntentDefault);
    int turns = 0;
    unsigned outW, outH, o;
    double scale = 1;
    NSMutableData *out = [NSMutableData data];
    NSData *result = nil;
    CGContextRef context;
    for (o = 0; o < [ops count]; o++)
        if ([[ops objectAtIndex:o] intValue] / 1000 == 1)
            turns += [[ops objectAtIndex:o] intValue] % 1000;
    outW = (turns & 1) ? height : width;
    outH = (turns & 1) ? width : height;
    if (image) {
        unsigned big = outW > outH ? outW : outH;
        if ((int)big > longest)
            scale = (double)longest / big;
        {
            unsigned dw = (unsigned)(outW * scale + 0.5), dh = (unsigned)(outH * scale + 0.5);
            if (dw < 1) dw = 1;
            if (dh < 1) dh = 1;
            context = CGBitmapContextCreate(NULL, dw, dh, 8, dw * 4, space, kCGImageAlphaNoneSkipLast);
            if (context) {
                CGImageRef flat;
                CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
                CGContextTranslateCTM(context, dw / 2.0, dh / 2.0);
                /* the first operation in the file acts on the picture first, so it is the last one applied to the context */
                for (o = [ops count]; o > 0; o--) {
                    int op = [[ops objectAtIndex:o - 1] intValue];
                    if (op / 1000 == 1)
                        CGContextRotateCTM(context, (op % 1000) * M_PI / 2);   /* HEIF's irot is a quarter turn anticlockwise per step */
                    else if (op % 1000 == 0)
                        CGContextScaleCTM(context, 1, -1);       /* axis 0: top and bottom swap */
                    else
                        CGContextScaleCTM(context, -1, 1);       /* axis 1: left and right swap */
                }
                CGContextScaleCTM(context, scale, scale);
                CGContextDrawImage(context, CGRectMake(-(double)width / 2, -(double)height / 2, width, height), image);
                flat = CGBitmapContextCreateImage(context);
                if (flat) {
                    CGImageDestinationRef destination = CGImageDestinationCreateWithData((CFMutableDataRef)out, CFSTR("public.jpeg"), 1, NULL);
                    if (destination) {
                        NSDictionary *quality = [NSDictionary dictionaryWithObject:[NSNumber numberWithFloat:0.85f] forKey:(id)kCGImageDestinationLossyCompressionQuality];
                        CGImageDestinationAddImage(destination, flat, (CFDictionaryRef)quality);
                        if (CGImageDestinationFinalize(destination) && [out length])
                            result = out;
                        CFRelease(destination);
                    }
                    CGImageRelease(flat);
                }
                CGContextRelease(context);
            }
        }
        CGImageRelease(image);
    }
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(space);
    return result;
}

/* ---- AV1 pictures (AVIF), decoded by libaom ---- */

/* The item's AV1 data (with the configuration's own OBUs in front) to a picture. Free it with aom_codec_destroy. */
static NSString *decodeAV1(Item *item, NSData *av1C, const uint8_t *file, unsigned long long fileLength, aom_codec_ctx_t *codec, aom_image_t **img)
{
    NSMutableData *buffer = [NSMutableData data];
    aom_codec_iter_t iterator = NULL;
    if (item->constructionMethod != 0 || item->offset + item->length > fileLength)
        return @"The picture data is cut short.";
    if ([av1C length] > 4)
        [buffer appendBytes:(const uint8_t *)[av1C bytes] + 4 length:[av1C length] - 4];
    [buffer appendBytes:file + item->offset length:(unsigned)item->length];
    if (aom_codec_dec_init(codec, aom_codec_av1_dx(), NULL, 0))
        return @"The AV1 decoder could not start.";
    if (aom_codec_decode(codec, [buffer bytes], [buffer length], NULL)) {
        aom_codec_destroy(codec);
        return @"The AV1 picture could not be decoded.";
    }
    *img = aom_codec_get_frame(codec, &iterator);
    if (!*img) {
        aom_codec_destroy(codec);
        return @"The AV1 picture could not be decoded.";
    }
    return nil;
}

static inline int sampleOf(const aom_image_t *img, int plane, unsigned row, unsigned col, int shift)
{
    const uint8_t *line = img->planes[plane] + (size_t)row * img->stride[plane];
    return (img->fmt & AOM_IMG_FMT_HIGHBITDEPTH) ? ((const uint16_t *)line)[col] >> shift : line[col];
}

/* Draws the picture (and its alpha picture, over white) onto the canvas at (x, y). colr says whether the file's colour box gave the matrix. */
static NSString *paintAV1(const aom_image_t *img, const aom_image_t *alpha, uint8_t *canvas, unsigned cw, unsigned ch, unsigned x, unsigned y, Matrix matrix, BOOL colr)
{
    unsigned w = img->d_w, h = img->d_h, row, col;
    int bits = img->bit_depth, shift = bits - 8, cx = img->x_chroma_shift, cy = img->y_chroma_shift, mono = img->monochrome, identity = 0;
    int ashift = alpha ? (int)alpha->bit_depth - 8 : 0;
    if (bits < 8 || bits > 16)
        return @"This kind of AVIF picture is not supported.";
    if (!colr) {
        matrix = matrixFor(img->mc, img->range == AOM_CR_FULL_RANGE);
        if (img->cp == 12) {
            makeTables();
            matrix.p3 = YES;
        }
    }
    if (!colr && img->mc == 0 && !mono && cx == 0 && cy == 0) {
        identity = 1;
        matrix.full = YES;
    }
    if (x + w > cw)
        w = cw - x;
    if (y + h > ch)
        h = ch - y;
    for (row = 0; row < h; row++) {
        uint8_t *out = canvas + ((size_t)(y + row) * cw + x) * 3;
        for (col = 0; col < w; col++) {
            int Y = sampleOf(img, 0, row, col, shift), Cb = 128, Cr = 128, r, g, b;
            if (!mono) {
                Cb = sampleOf(img, 1, row >> cy, col >> cx, shift);
                Cr = sampleOf(img, 2, row >> cy, col >> cx, shift);
            }
            if (identity) {
                g = Y;
                b = Cb;
                r = Cr;
            } else {
                if (!matrix.full) {
                    Y = ((Y - 16) * 255 + 109) / 219;
                    Cb = 128 + ((Cb - 128) * 255 + 112) / 224;
                    Cr = 128 + ((Cr - 128) * 255 + 112) / 224;
                }
                r = Y + ((matrix.rv * (Cr - 128) + 32768) >> 16);
                g = Y - ((matrix.gu * (Cb - 128) + matrix.gv * (Cr - 128) + 32768) >> 16);
                b = Y + ((matrix.bu * (Cb - 128) + 32768) >> 16);
            }
            r = clamp8(r);
            g = clamp8(g);
            b = clamp8(b);
            if (matrix.p3)
                fromP3(&r, &g, &b);
            if (alpha && row < alpha->d_h && col < alpha->d_w) {
                int a = sampleOf(alpha, 0, row, col, ashift);
                if (alpha->range != AOM_CR_FULL_RANGE)
                    a = clamp8(((a - 16) * 255 + 109) / 219);
                r = (r * a + 255 * (255 - a) + 127) / 255;
                g = (g * a + 255 * (255 - a) + 127) / 255;
                b = (b * a + 255 * (255 - a) + 127) / 255;
            }
            out[0] = r;
            out[1] = g;
            out[2] = b;
            out += 3;
        }
    }
    return nil;
}

/* the AV1 picture (and alpha) of one item, painted onto the canvas */
static NSString *decodeAV1Item(Item *item, NSData *av1C, Item *alphaItem, NSData *alphaC, const uint8_t *file, unsigned long long fileLength, uint8_t *canvas, unsigned cw, unsigned ch, unsigned x, unsigned y, Matrix matrix, BOOL colr)
{
    aom_codec_ctx_t codec, alphaCodec;
    aom_image_t *img = NULL, *alphaImg = NULL;
    NSString *why = decodeAV1(item, av1C, file, fileLength, &codec, &img);
    BOOL haveAlpha = NO;
    if (why)
        return why;
    if (alphaItem && alphaC && !decodeAV1(alphaItem, alphaC, file, fileLength, &alphaCodec, &alphaImg))
        haveAlpha = YES;
    why = paintAV1(img, haveAlpha ? alphaImg : NULL, canvas, cw, ch, x, y, matrix, colr);
    aom_codec_destroy(&codec);
    if (haveAlpha)
        aom_codec_destroy(&alphaCodec);
    return why;
}

+ (NSData *)jpegFromData:(NSData *)data longest:(int)longest problem:(NSString **)problem
{
    const uint8_t *d = [data bytes];
    unsigned long long total = [data length];
    NSArray *top = boxes(d, 0, total, total);
    TBBox *meta = find(top, "meta");
    NSArray *kids;
    TBBox *pitm, *iinf, *iloc, *iref, *iprp, *idat;
    unsigned primary, i, j;
    NSMutableDictionary *items = [NSMutableDictionary dictionary];
    NSString *failure;
    if (!meta) {
        *problem = @"This is not a HEIC picture.";
        return nil;
    }
    kids = boxes(d, meta->start + 4, meta->end, total);
    pitm = find(kids, "pitm");
    iinf = find(kids, "iinf");
    iloc = find(kids, "iloc");
    iref = find(kids, "iref");
    iprp = find(kids, "iprp");
    idat = find(kids, "idat");
    if (!pitm || !iinf || !iloc || !iprp) {
        *problem = @"The HEIC file is missing parts.";
        return nil;
    }
    primary = d[pitm->start] == 0 ? be16(d + pitm->start + 4) : be32(d + pitm->start + 4);
    /* items and their types */
    {
        int version = d[iinf->start];
        unsigned long long at = iinf->start + 4;
        unsigned count = version == 0 ? be16(d + at) : be32(d + at);
        NSArray *infe;
        at += version == 0 ? 2 : 4;
        infe = boxes(d, at, iinf->end, total);
        for (i = 0; i < [infe count] && i < count; i++) {
            TBBox *b = [infe objectAtIndex:i];
            int v = d[b->start];
            Item *item = calloc(1, sizeof(Item));
            unsigned long long p = b->start + 4;
            if (strcmp(b->type, "infe") || v < 2 || p + 8 > b->end) {
                free(item);
                continue;
            }
            item->id = v == 2 ? be16(d + p) : be32(d + p);
            p += v == 2 ? 2 : 4;
            p += 2;
            memcpy(item->type, d + p, 4);
            item->type[4] = 0;
            item->properties = [[NSMutableArray alloc] init];
            [items setObject:[NSValue valueWithPointer:item] forKey:[NSNumber numberWithUnsignedInt:item->id]];
        }
    }
    /* where each item's bytes are */
    {
        int version = d[iloc->start];
        unsigned long long at = iloc->start + 4;
        int offsetSize = d[at] >> 4, lengthSize = d[at] & 15, baseSize = d[at + 1] >> 4, indexSize = version > 0 ? (d[at + 1] & 15) : 0;
        unsigned count;
        at += 2;
        count = version < 2 ? be16(d + at) : be32(d + at);
        at += version < 2 ? 2 : 4;
        for (i = 0; i < count && at + 8 < iloc->end; i++) {
            unsigned id = version < 2 ? be16(d + at) : be32(d + at);
            int method = 0, extents;
            unsigned long long base;
            Item *item;
            at += version < 2 ? 2 : 4;
            if (version > 0) {
                method = be16(d + at) & 15;
                at += 2;
            }
            at += 2;
            base = number(d + at, baseSize);
            at += baseSize;
            extents = be16(d + at);
            at += 2;
            item = [[items objectForKey:[NSNumber numberWithUnsignedInt:id]] pointerValue];
            for (j = 0; j < (unsigned)extents && at < iloc->end; j++) {
                unsigned long long off, len;
                at += indexSize;
                off = number(d + at, offsetSize);
                at += offsetSize;
                len = number(d + at, lengthSize);
                at += lengthSize;
                if (item && j == 0) {
                    item->constructionMethod = method;
                    item->offset = base + off;
                    item->length = len;
                    item->singleExtent = extents == 1;
                }
            }
        }
    }
    /* properties: the list, then which belong to which item */
    {
        NSArray *pk = boxes(d, iprp->start, iprp->end, total);
        TBBox *ipco = find(pk, "ipco"), *ipma = find(pk, "ipma");
        NSArray *props = ipco ? boxes(d, ipco->start, ipco->end, total) : [NSArray array];
        if (ipma) {
            int version = d[ipma->start], flags = d[ipma->start + 3];
            unsigned long long at = ipma->start + 4;
            unsigned entries = be32(d + at);
            at += 4;
            for (i = 0; i < entries && at + 3 < ipma->end; i++) {
                unsigned id = version < 1 ? be16(d + at) : be32(d + at);
                int n = d[at + (version < 1 ? 2 : 4)];
                Item *item = [[items objectForKey:[NSNumber numberWithUnsignedInt:id]] pointerValue];
                at += (version < 1 ? 2 : 4) + 1;
                for (j = 0; j < (unsigned)n && at < ipma->end; j++) {
                    unsigned index = (flags & 1) ? (be16(d + at) & 0x7fff) : (d[at] & 0x7f);
                    at += (flags & 1) ? 2 : 1;
                    if (item && index >= 1 && index <= [props count]) {
                        TBBox *pb = [props objectAtIndex:index - 1];
                        NSMutableData *entry = [NSMutableData dataWithBytes:pb->type length:4];
                        [entry appendBytes:d + pb->start length:(unsigned)(pb->end - pb->start)];
                        [item->properties addObject:entry];
                    }
                }
            }
        }
    }
    /* the picture */
    {
        Item *primaryItem = [[items objectForKey:[NSNumber numberWithUnsignedInt:primary]] pointerValue];
        NSData *result = nil;
        NSString *why = nil;
        NSMutableArray *ops = [NSMutableArray array];
        Matrix matrix = matrixFor(6, YES);
        BOOL p3 = NO, colr = NO;
        Item *alphaItem = NULL;
        unsigned width = 0, height = 0;
        uint8_t *canvas = NULL;
        NSEnumerator *each;
        id key;
        if (!primaryItem) {
            *problem = @"The HEIC file has no main picture.";
            goto done;
        }
        /* properties of the primaryItem item */
        for (i = 0; i < [primaryItem->properties count]; i++) {
            NSData *pr = [primaryItem->properties objectAtIndex:i];
            const uint8_t *q = [pr bytes];
            unsigned n = [pr length];
            if (n >= 16 && !memcmp(q, "ispe", 4)) {
                width = be32(q + 8);
                height = be32(q + 12);
            } else if (n >= 5 && !memcmp(q, "irot", 4))
                [ops addObject:[NSNumber numberWithInt:1000 + (q[4] & 3)]];
            else if (n >= 5 && !memcmp(q, "imir", 4))
                [ops addObject:[NSNumber numberWithInt:2000 + (q[4] & 1)]];
            else if (n >= 15 && !memcmp(q, "colr", 4) && !memcmp(q + 4, "nclx", 4)) {
                matrix = matrixFor(be16(q + 12), (q[14] & 0x80) != 0);
                colr = YES;
                if (be16(q + 8) == 12)
                    p3 = YES;
            } else if (n > 12 && !memcmp(q, "colr", 4) && !memcmp(q + 4, "prof", 4)) {
                /* an ICC profile: iPhones use Display P3 */
                unsigned k;
                for (k = 8; k + 10 < n && k < 600; k++)
                    if (!memcmp(q + k, "Display P3", 10))
                        p3 = YES;
            }
        }
        if (p3) {
            makeTables();
            matrix.p3 = YES;
        }
        if (!width || !height || (unsigned long long)width * height > 100000000ULL) {
            *problem = @"The picture's size is not usable.";
            goto done;
        }
        if (!strcmp(primaryItem->type, "av01")) {
            NSData *av1C = nil, *alphaC = nil;
            for (i = 0; i < [primaryItem->properties count]; i++)
                if (!memcmp([[primaryItem->properties objectAtIndex:i] bytes], "av1C", 4))
                    av1C = [NSData dataWithBytes:(const uint8_t *)[[primaryItem->properties objectAtIndex:i] bytes] + 4 length:[[primaryItem->properties objectAtIndex:i] length] - 4];
            alphaItem = findAlpha(items, iref, d, total, primary, &alphaC);
            canvas = malloc((size_t)width * height * 3);
            if (!av1C || !canvas) {
                *problem = @"This kind of AVIF picture is not supported.";
                goto done;
            }
            why = decodeAV1Item(primaryItem, av1C, alphaItem, alphaC, d, total, canvas, width, height, 0, 0, matrix, colr);
            if (why) {
                *problem = why;
                goto done;
            }
        } else if (!strcmp(primaryItem->type, "hvc1") || !strcmp(primaryItem->type, "hev1")) {
            NSData *hvcC = nil;
            if ((failure = loadLibrary())) {
                *problem = failure;
                goto done;
            }
            for (i = 0; i < [primaryItem->properties count]; i++)
                if (!memcmp([[primaryItem->properties objectAtIndex:i] bytes], "hvcC", 4))
                    hvcC = [NSData dataWithBytes:(const uint8_t *)[[primaryItem->properties objectAtIndex:i] bytes] + 4 length:[[primaryItem->properties objectAtIndex:i] length] - 4];
            canvas = malloc((size_t)width * height * 3);
            if (!hvcC || !canvas || primaryItem->constructionMethod != 0) {
                *problem = @"This kind of HEIC picture is not supported.";
                goto done;
            }
            why = decodeItem(primaryItem, hvcC, d, total, canvas, width, height, 0, 0, matrix);
            if (why) {
                *problem = why;
                goto done;
            }
        } else if (!strcmp(primaryItem->type, "grid")) {
            /* a grid of tiles, how an iPhone stores a big picture */
            const uint8_t *g;
            unsigned rows, cols, outW, outH, tile = 0;
            NSMutableArray *tiles = [NSMutableArray array];
            /* the grid's own few bytes are kept in the idat box by most encoders, or in the file */
            if (primaryItem->constructionMethod == 1 && idat && idat->start + primaryItem->offset + primaryItem->length <= idat->end)
                g = d + idat->start + primaryItem->offset;
            else if (primaryItem->constructionMethod == 0 && primaryItem->offset + primaryItem->length <= total)
                g = d + primaryItem->offset;
            else
                g = NULL;
            if (!g || primaryItem->length < 8) {
                *problem = @"This kind of HEIC picture is not supported.";
                goto done;
            }
            rows = g[2] + 1;
            cols = g[3] + 1;
            if (g[1] & 1) {
                if (primaryItem->length < 12) { *problem = @"The picture's tiles are damaged."; goto done; }
                outW = be32(g + 4);
                outH = be32(g + 8);
            } else {
                outW = be16(g + 4);
                outH = be16(g + 6);
            }
            if (!outW || !outH || (unsigned long long)outW * outH > 100000000ULL || rows * cols > 4096) {
                *problem = @"The picture's size is not usable.";
                goto done;
            }
            width = outW;
            height = outH;
            /* the tile ids, in order, from the "dimg" references */
            if (iref) {
                int rv = d[iref->start];
                NSArray *refs = boxes(d, iref->start + 4, iref->end, total);
                for (i = 0; i < [refs count]; i++) {
                    TBBox *r = [refs objectAtIndex:i];
                    unsigned long long p = r->start;
                    unsigned from = rv == 0 ? be16(d + p) : be32(d + p), n;
                    if (strcmp(r->type, "dimg") || from != primary)
                        continue;
                    p += rv == 0 ? 2 : 4;
                    n = be16(d + p);
                    p += 2;
                    for (j = 0; j < n && p + (rv == 0 ? 2 : 4) <= r->end; j++) {
                        [tiles addObject:[NSNumber numberWithUnsignedInt:rv == 0 ? be16(d + p) : be32(d + p)]];
                        p += rv == 0 ? 2 : 4;
                    }
                }
            }
            if ([tiles count] != rows * cols) {
                *problem = @"The picture's tiles are damaged.";
                goto done;
            }
            canvas = calloc((size_t)width * height, 3);
            if (!canvas) {
                *problem = @"There is not enough memory for this picture.";
                goto done;
            }
            for (tile = 0; tile < rows * cols; tile++) {
                Item *t = [[items objectForKey:[tiles objectAtIndex:tile]] pointerValue];
                NSData *hvcC = nil, *tileAV1 = nil;
                unsigned tw = 0, th = 0;
                BOOL av1Tile = t && !strcmp(t->type, "av01");
                if (!t || (strcmp(t->type, "hvc1") && !av1Tile) || t->constructionMethod != 0) {
                    *problem = @"This kind of picture is not supported.";
                    goto done;
                }
                if (!av1Tile && (failure = loadLibrary())) {
                    *problem = failure;
                    goto done;
                }
                for (i = 0; i < [t->properties count]; i++) {
                    NSData *pr = [t->properties objectAtIndex:i];
                    const uint8_t *q = [pr bytes];
                    if (!memcmp(q, "hvcC", 4))
                        hvcC = [NSData dataWithBytes:q + 4 length:[pr length] - 4];
                    else if (!memcmp(q, "av1C", 4))
                        tileAV1 = [NSData dataWithBytes:q + 4 length:[pr length] - 4];
                    else if (!memcmp(q, "ispe", 4) && [pr length] >= 16) {
                        tw = be32(q + 8);
                        th = be32(q + 12);
                    }
                }
                if ((!hvcC && !tileAV1) || !tw || !th) {
                    *problem = @"The picture's tiles are damaged.";
                    goto done;
                }
                if ((tile % cols) * tw >= width || (tile / cols) * th >= height)
                    continue;
                if (av1Tile)
                    why = decodeAV1Item(t, tileAV1, NULL, nil, d, total, canvas, width, height, (tile % cols) * tw, (tile / cols) * th, matrix, colr);
                else
                    why = decodeItem(t, hvcC, d, total, canvas, width, height, (tile % cols) * tw, (tile / cols) * th, matrix);
                if (why) {
                    *problem = why;
                    goto done;
                }
            }
        } else {
            *problem = [NSString stringWithFormat:@"This kind of HEIC picture (%s) is not supported.", primaryItem->type];
            goto done;
        }
        result = jpegFromRGB(canvas, width, height, ops, longest);
        if (!result)
            *problem = @"The picture could not be saved as a JPEG.";
    done:
        if (canvas)
            free(canvas);
        each = [items keyEnumerator];
        while ((key = [each nextObject])) {
            Item *it = [[items objectForKey:key] pointerValue];
            [it->properties release];
            free(it);
        }
        return result;
    }
}

@end
