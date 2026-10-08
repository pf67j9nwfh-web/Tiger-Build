#import "TBExtract.h"
#import "TBEngine.h"
#import "TBCompat.h"
#import <zlib.h>
#import <ApplicationServices/ApplicationServices.h>
#import <pthread.h>
#import "webp/decode.h"
#import "webp/demux.h"
#import "TBHEIC.h"
#import "TBSpeech.h"
#import <unistd.h>
#import <AudioToolbox/AudioToolbox.h>
#if TB_INLINE_VIDEO
#import <QTKit/QTKit.h>
#endif
#import "../third_party/jxldec/jxl.h"
#import "TBOffice.h"
#import "TBSupport.h"

NSString *TBExtractError = @"TBExtractError";

#define MAX_TEXT 300000
#define MAX_PART (64 * 1024 * 1024)
#define MAX_ALL (400.0 * 1024 * 1024)

static void fail(NSString *format, ...)
{
    va_list args;
    NSString *text;
    va_start(args, format);
    text = [[[NSString alloc] initWithFormat:format arguments:args] autorelease];
    va_end(args);
    [NSException raise:TBExtractError format:@"%@", text];
}

static unsigned le16(const unsigned char *p) { return p[0] | (p[1] << 8); }
static unsigned le32(const unsigned char *p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((unsigned)p[3] << 24); }

/* ---- zip ---- */

@implementation TBZip

- (id)initWithData:(NSData *)bytes
{
    const unsigned char *p = [bytes bytes];
    long length = [bytes length], at, count, i;
    unsigned long directory;
    self = [super init];
    data = [bytes retain];
    entries = [[NSMutableDictionary alloc] init];
    for (at = length - 22; at >= 0 && at >= length - 22 - 65535; at--)
        if (p[at] == 'P' && p[at + 1] == 'K' && p[at + 2] == 5 && p[at + 3] == 6)
            break;
    if (at < 0 || length - 22 - 65535 > at) {
        [self release];
        return nil;
    }
    count = le16(p + at + 10);
    directory = le32(p + at + 16);
    if (count == 0xffff || directory == 0xffffffffu) {
        [self release];
        fail(@"This file is larger than the converter reads (zip64).");
    }
    for (i = 0; i < count; i++) {
        unsigned nameLength, extra, comment;
        NSString *name;
        if (directory + 46 > (unsigned long)length || le32(p + directory) != 0x02014b50) {
            [self release];
            return nil;
        }
        nameLength = le16(p + directory + 28);
        extra = le16(p + directory + 30);
        comment = le16(p + directory + 32);
        if (directory + 46 + nameLength > (unsigned long)length) {
            [self release];
            return nil;
        }
        name = [[NSString alloc] initWithBytes:p + directory + 46 length:nameLength encoding:NSUTF8StringEncoding];
        if (name) {
            [entries setObject:[NSArray arrayWithObjects:[NSNumber numberWithUnsignedLong:le32(p + directory + 42)], [NSNumber numberWithUnsignedLong:le32(p + directory + 20)],
                [NSNumber numberWithUnsignedLong:le32(p + directory + 24)], [NSNumber numberWithUnsignedInt:le16(p + directory + 10)], nil] forKey:name];
            [name release];
        }
        directory += 46 + nameLength + extra + comment;
    }
    return self;
}

+ (TBZip *)zipWithData:(NSData *)bytes
{
    return [[[TBZip alloc] initWithData:bytes] autorelease];
}

- (void)dealloc
{
    [data release];
    [entries release];
    [super dealloc];
}

- (NSArray *)names { return [entries allKeys]; }
- (double)sizeOf:(NSString *)name { return [[[entries objectForKey:name] objectAtIndex:2] doubleValue]; }
- (BOOL)has:(NSString *)name { return [entries objectForKey:name] != nil; }

- (double)totalSize
{
    double total = 0;
    NSEnumerator *each = [entries objectEnumerator];
    NSArray *entry;
    while ((entry = [each nextObject]))
        total += [[entry objectAtIndex:2] doubleValue];
    return total;
}

- (NSData *)dataFor:(NSString *)name
{
    NSArray *entry = [entries objectForKey:name];
    const unsigned char *p = [data bytes];
    unsigned long long offset, packed, size, start;
    unsigned method;
    if (!entry)
        fail(@"%@ is missing from the file.", name);
    offset = [[entry objectAtIndex:0] unsignedLongValue];
    packed = [[entry objectAtIndex:1] unsignedLongValue];
    size = [[entry objectAtIndex:2] unsignedLongValue];
    method = [[entry objectAtIndex:3] unsignedIntValue];
    if (size > MAX_PART)
        fail(@"A part of this file is too large to read (%@).", name);
    if (offset + 30 > (unsigned long long)[data length] || le32(p + offset) != 0x04034b50)
        fail(@"This file is damaged.");
    start = offset + 30 + le16(p + offset + 26) + le16(p + offset + 28);
    if (start > (unsigned long long)[data length] || packed > (unsigned long long)[data length] - start)
        fail(@"This file is damaged.");
    if (method == 0)
        return [NSData dataWithBytes:p + start length:packed];
    if (method == 8) {
        z_stream stream;
        NSMutableData *out = [NSMutableData dataWithLength:size];
        int result;
        memset(&stream, 0, sizeof stream);
        if (inflateInit2(&stream, -15) != Z_OK)
            fail(@"This file could not be unpacked.");
        stream.next_in = (Bytef *)(p + start);
        stream.avail_in = packed;
        stream.next_out = [out mutableBytes];
        stream.avail_out = size;
        result = inflate(&stream, Z_FINISH);
        inflateEnd(&stream);
        if (result != Z_STREAM_END && !(result == Z_OK && stream.avail_out == 0))
            fail(@"This file is damaged (%@).", name);
        [out setLength:size - stream.avail_out];
        return out;
    }
    fail(@"This file uses a compression the converter does not read.");
    return nil;
}

@end

NSData *TBGunzip(NSData *input, unsigned limit)
{
    z_stream stream;
    NSMutableData *out = [NSMutableData data];
    unsigned char buffer[65536];
    int result;
    memset(&stream, 0, sizeof stream);
    if (inflateInit2(&stream, 15 + 16) != Z_OK)
        return nil;
    stream.next_in = (Bytef *)[input bytes];
    stream.avail_in = [input length];
    do {
        stream.next_out = buffer;
        stream.avail_out = sizeof buffer;
        result = inflate(&stream, Z_NO_FLUSH);
        if (result != Z_OK && result != Z_STREAM_END) {
            inflateEnd(&stream);
            return nil;
        }
        [out appendBytes:buffer length:sizeof buffer - stream.avail_out];
        if ([out length] > limit) {
            inflateEnd(&stream);
            return nil;
        }
    } while (result != Z_STREAM_END);
    inflateEnd(&stream);
    return out;
}

/* ---- XML ---- */

/* stringByReplacingOccurrencesOfString: is 10.5 and later */
static NSString *swap(NSString *text, NSString *from, NSString *to)
{
    return [[text componentsSeparatedByString:from] componentsJoinedByString:to];
}

static NSString *localName(NSString *name)
{
    NSRange colon = [name rangeOfString:@":"];
    return colon.location == NSNotFound ? name : [name substringFromIndex:colon.location + 1];
}

static int memmem_ci(const void *bytes, unsigned n)
{
    const unsigned char *b = bytes;
    const char *needle = "<!entity";
    unsigned i, j;
    for (i = 0; i + 8 <= n; i++) {
        for (j = 0; j < 8; j++) {
            unsigned char c = b[i + j];
            if (c >= 'A' && c <= 'Z')
                c += 32;
            if (c != (unsigned char)needle[j])
                break;
        }
        if (j == 8)
            return 1;
    }
    return 0;
}

static NSData *checkedXML(NSData *xml)
{
    /* Entity definitions are refused: they are how a small file is made to expand into gigabytes. */
    unsigned n = [xml length] < 200000 ? [xml length] : 200000;
    if (memmem_ci([xml bytes], n))
        fail(@"This file uses XML features the converter will not read.");
    return xml;
}

/* The text of paragraphs: every <p> (or the elements named) gives one string. Text inside only the text elements
   named (w:t), or all of it when none are named. */
@interface TBParas : NSObject TB_PROTOCOLS(NSXMLParserDelegate)
{
    NSSet *paraNames, *textNames;
    BOOL breaks;
    NSMutableArray *open, *out;
    int inText;
}
+ (NSArray *)parse:(NSData *)xml paragraphs:(NSArray *)paras text:(NSArray *)texts breaks:(BOOL)breaks;
@end

@implementation TBParas

+ (NSArray *)parse:(NSData *)xml paragraphs:(NSArray *)paras text:(NSArray *)texts breaks:(BOOL)b
{
    TBParas *me = [[[TBParas alloc] init] autorelease];
    NSXMLParser *parser = [[[NSXMLParser alloc] initWithData:checkedXML(xml)] autorelease];
    me->paraNames = [NSSet setWithArray:paras];
    me->textNames = texts ? [NSSet setWithArray:texts] : nil;
    me->breaks = b;
    me->open = [NSMutableArray array];
    me->out = [NSMutableArray array];
    [parser setDelegate:me];
    [parser parse];
    return me->out;
}

- (void)add:(NSString *)text
{
    unsigned i;
    for (i = 0; i < [open count]; i++)
        [[open objectAtIndex:i] appendString:text];
}

- (void)parser:(NSXMLParser *)p didStartElement:(NSString *)element namespaceURI:(NSString *)uri qualifiedName:(NSString *)q attributes:(NSDictionary *)a
{
    NSString *name = localName(element);
    if ([paraNames containsObject:name])
        [open addObject:[NSMutableString string]];
    else if (textNames && [textNames containsObject:name])
        inText++;
    else if (breaks && [name isEqualToString:@"tab"])
        [self add:@"\t"];
    else if (breaks && ([name isEqualToString:@"br"] || [name isEqualToString:@"cr"]))
        [self add:@"\n"];
}

- (void)parser:(NSXMLParser *)p didEndElement:(NSString *)element namespaceURI:(NSString *)uri qualifiedName:(NSString *)q
{
    NSString *name = localName(element);
    if ([paraNames containsObject:name] && [open count]) {
        [out addObject:[[[open lastObject] copy] autorelease]];
        [open removeLastObject];
    } else if (textNames && [textNames containsObject:name] && inText > 0)
        inText--;
}

- (void)parser:(NSXMLParser *)p foundCharacters:(NSString *)string
{
    if ([open count] && (!textNames || inText > 0))
        [self add:string];
}

@end

/* shared strings, workbook sheets and relationships of a spreadsheet (the cells themselves are read straight from the bytes, below) */
@interface TBCells : NSObject TB_PROTOCOLS(NSXMLParserDelegate)
{
    NSMutableArray *strings, *sheets;
    NSMutableDictionary *targets;
    NSMutableString *item;
    BOOL inSI, inT;
}
+ (NSArray *)sharedStrings:(NSData *)xml;
+ (NSArray *)sheetNames:(NSData *)xml; /* [{name, id}] */
+ (NSDictionary *)relationships:(NSData *)xml;
@end

@implementation TBCells

+ (TBCells *)run:(NSData *)xml
{
    TBCells *me = [[[TBCells alloc] init] autorelease];
    NSXMLParser *parser = [[[NSXMLParser alloc] initWithData:checkedXML(xml)] autorelease];
    me->strings = [NSMutableArray array];
    me->sheets = [NSMutableArray array];
    me->targets = [NSMutableDictionary dictionary];
    me->item = [NSMutableString string];
    [parser setDelegate:me];
    [parser parse];
    return me;
}

+ (NSArray *)sharedStrings:(NSData *)xml { return [self run:xml]->strings; }
+ (NSArray *)sheetNames:(NSData *)xml { return [self run:xml]->sheets; }
+ (NSDictionary *)relationships:(NSData *)xml { return [self run:xml]->targets; }

- (void)parser:(NSXMLParser *)p didStartElement:(NSString *)element namespaceURI:(NSString *)uri qualifiedName:(NSString *)q attributes:(NSDictionary *)a
{
    NSString *name = localName(element);
    if ([name isEqualToString:@"si"]) {
        inSI = YES;
        [item setString:@""];
    } else if ([name isEqualToString:@"sheet"]) {
        NSString *rid = nil;
        NSEnumerator *each = [a keyEnumerator];
        NSString *key;
        while ((key = [each nextObject]))
            if ([key isEqualToString:@"r:id"] || ([key hasSuffix:@":id"]))
                rid = [a objectForKey:key];
        [sheets addObject:[NSDictionary dictionaryWithObjectsAndKeys:[a objectForKey:@"name"] ? [a objectForKey:@"name"] : @"Sheet", @"name", rid ? rid : @"", @"id", nil]];
    } else if ([name isEqualToString:@"Relationship"]) {
        NSString *path = [a objectForKey:@"Target"];
        if ([a objectForKey:@"Id"] && path)
            [targets setObject:[path hasPrefix:@"/"] ? [path substringFromIndex:1] : [@"xl/" stringByAppendingString:path] forKey:[a objectForKey:@"Id"]];
    } else if ([name isEqualToString:@"t"]) {
        inT = YES;
    }
}

- (void)parser:(NSXMLParser *)p didEndElement:(NSString *)element namespaceURI:(NSString *)uri qualifiedName:(NSString *)q
{
    NSString *name = localName(element);
    if ([name isEqualToString:@"si"]) {
        inSI = NO;
        [strings addObject:[[item copy] autorelease]];
    } else if ([name isEqualToString:@"t"])
        inT = NO;
}

- (void)parser:(NSXMLParser *)p foundCharacters:(NSString *)string
{
    if (inSI && inT)
        [item appendString:string];
}

@end


static int columnOf(NSString *ref)
{
    int n = 0;
    unsigned i;
    for (i = 0; i < [ref length]; i++) {
        unichar c = [ref characterAtIndex:i];
        if (c < 'A' || c > 'Z')
            break;
        n = n * 26 + c - 'A' + 1;
    }
    return n ? n - 1 : 0;
}

static const unsigned char *memmem_ptr(const unsigned char *p, const unsigned char *end, const char *needle)
{
    size_t k = strlen(needle);
    while (p + k <= end) {
        const unsigned char *q = memchr(p, needle[0], end - p);
        if (!q || q + k > end)
            return NULL;
        if (!memcmp(q, needle, k))
            return q;
        p = q + 1;
    }
    return NULL;
}

/* ---- spreadsheet rows, read straight from the bytes (an XML parser takes many seconds on a big sheet on a G4) ---- */

static NSString *xmlText(const unsigned char *p, unsigned long n)
{
    NSMutableData *out = nil;
    unsigned long i, last = 0;
    NSString *text;
    for (i = 0; i < n; i++) {
        if (p[i] == '&') {
            const unsigned char *e = memchr(p + i, ';', n - i > 10 ? 10 : n - i);
            char code[12];
            unsigned len;
            unichar c = 0;
            const char *rep = NULL;
            if (!e)
                continue;
            len = (unsigned)(e - (p + i + 1));
            if (len == 0 || len > 8)
                continue;
            memcpy(code, p + i + 1, len);
            code[len] = 0;
            if (!strcmp(code, "amp")) rep = "&";
            else if (!strcmp(code, "lt")) rep = "<";
            else if (!strcmp(code, "gt")) rep = ">";
            else if (!strcmp(code, "quot")) rep = "\"";
            else if (!strcmp(code, "apos")) rep = "'";
            else if (code[0] == '#') {
                long number = code[1] == 'x' || code[1] == 'X' ? strtol(code + 2, NULL, 16) : strtol(code + 1, NULL, 10);
                if (number <= 0 || number > 0xffff)
                    continue;
                c = (unichar)number;
            } else
                continue;
            if (!out)
                out = [NSMutableData data];
            [out appendBytes:p + last length:i - last];
            if (rep)
                [out appendBytes:rep length:1];
            else {
                NSString *one = [NSString stringWithFormat:@"%C", c];
                NSData *bytes = [one dataUsingEncoding:NSUTF8StringEncoding];
                [out appendData:bytes];
            }
            i = (unsigned long)(e - p);
            last = i + 1;
        }
    }
    if (out) {
        [out appendBytes:p + last length:n - last];
        text = [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding];
    } else
        text = [[NSString alloc] initWithBytes:p length:n encoding:NSUTF8StringEncoding];
    return [text autorelease];
}

/* the value of an attribute inside a tag [p, end) */
static NSString *attributeOf(const unsigned char *p, const unsigned char *end, const char *name)
{
    size_t k = strlen(name);
    const unsigned char *q = p;
    while (q + k + 2 < end) {
        if ((q == p || q[-1] == ' ') && !memcmp(q, name, k) && q[k] == '=') {
            const unsigned char *v = q + k + 2, *e = v;
            unsigned char quote = q[k + 1];
            while (e < end && *e != quote)
                e++;
            return xmlText(v, (unsigned long)(e - v));
        }
        q++;
    }
    return nil;
}

/* The rows of a worksheet that hold something, as arrays of cell text, at most `limit` of them. *stopped says more were left. */
static NSArray *sheetRows(NSData *xml, NSArray *shared, int limit, BOOL *stopped)
{
    const unsigned char *b = [xml bytes], *end = b + [xml length], *p = b;
    NSMutableArray *rows = [NSMutableArray array], *cells = nil;
    int kept = 0;
    *stopped = NO;
    while (p < end && (p = memchr(p, '<', end - p))) {
        const unsigned char *tagEnd = memchr(p, '>', end - p);
        if (!tagEnd)
            break;
        if (tagEnd - p >= 4 && p[1] == 'r' && p[2] == 'o' && p[3] == 'w' && (p[4] == ' ' || p[4] == '>' || p[4] == '/')) {
            cells = (tagEnd[-1] == '/') ? nil : [NSMutableArray array];
        } else if (p[1] == '/' && !memcmp(p + 2, "row>", 4)) {
            if (cells) {
                unsigned c;
                BOOL holds = NO;
                for (c = 0; c < [cells count] && !holds; c++)
                    if ([[cells objectAtIndex:c] length])
                        holds = YES;
                [rows addObject:cells];
                cells = nil;
                if (holds && ++kept >= limit) {
                    *stopped = YES;
                    return rows;
                }
            }
        } else if (cells && p[1] == 'c' && (p[2] == ' ' || p[2] == '>')) {
            if (tagEnd[-1] != '/') {
                /* a cell with content: up to </c> */
                const unsigned char *close = p, *vstart = NULL, *vend = NULL;
                NSString *reference = attributeOf(p, tagEnd, "r"), *kind = attributeOf(p, tagEnd, "t"), *text = @"";
                int column = columnOf(reference);
                NSMutableString *inlineText = nil;
                while (close < end && (close = memchr(close + 1, '<', end - close - 1))) {
                    if (close[1] == '/' && close[2] == 'c' && close[3] == '>')
                        break;
                    if (close[1] == 'v' && close[2] == '>') {
                        const unsigned char *e = memmem_ptr(close + 3, end, "</v>");
                        vstart = close + 3;
                        vend = e;
                        if (e)
                            close = e;
                    } else if (close[1] == 't' && (close[2] == '>' || close[2] == ' ')) {
                        const unsigned char *gt = memchr(close, '>', end - close), *e = gt ? memmem_ptr(gt + 1, end, "</t>") : NULL;
                        if (e) {
                            if (!inlineText)
                                inlineText = [NSMutableString string];
                            [inlineText appendString:xmlText(gt + 1, (unsigned long)(e - gt - 1))];
                            close = e;
                        }
                    }
                }
                if (kind && [kind isEqualToString:@"inlineStr"] && inlineText)
                    text = inlineText;
                else if (vstart && vend) {
                    NSString *v = xmlText(vstart, (unsigned long)(vend - vstart));
                    if (kind && [kind isEqualToString:@"s"]) {
                        long index = strtol([v UTF8String], NULL, 10);
                        text = (index >= 0 && (unsigned long)index < [shared count]) ? [shared objectAtIndex:(unsigned)index] : @"";
                    } else
                        text = v;
                }
                while ((int)[cells count] < column && column < 16384)
                    [cells addObject:@""];
                if ([text length])
                    text = swap(swap(text, @"\t", @" "), @"\n", @" ");
                [cells addObject:text];
                p = close ? close : tagEnd;
            }
        }
        p = tagEnd + 1;
    }
    return rows;
}

/* ---- pictures ---- */

static BOOL isWebP(NSData *data)
{
    const unsigned char *b = [data bytes];
    return [data length] > 16 && !memcmp(b, "RIFF", 4) && !memcmp(b + 8, "WEBP", 4);
}

/* The JPEG of a decoded RGBA picture, laid on white (a JPEG has no transparency). */
static NSData *jpegFromRGBA(unsigned char *pixels, int width, int height, int stride, int longest)
{
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, pixels, (size_t)stride * height, NULL);
    CGImageRef image = CGImageCreate(width, height, 8, 32, stride, space, kCGImageAlphaLast, provider, NULL, false, kCGRenderingIntentDefault);
    int big = width > height ? width : height;
    double scale = big > longest ? (double)longest / big : 1.0;
    int dw = (int)(width * scale + 0.5), dh = (int)(height * scale + 0.5);
    CGContextRef context;
    NSMutableData *out = [NSMutableData data];
    NSData *result = nil;
    if (dw < 1) dw = 1;
    if (dh < 1) dh = 1;
    context = CGBitmapContextCreate(NULL, dw, dh, 8, dw * 4, space, kCGImageAlphaNoneSkipLast);
    if (image && context) {
        CGImageRef flat;
        CGContextSetRGBFillColor(context, 1, 1, 1, 1);
        CGContextFillRect(context, CGRectMake(0, 0, dw, dh));
        CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
        CGContextDrawImage(context, CGRectMake(0, 0, dw, dh), image);
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
    }
    if (image)
        CGImageRelease(image);
    if (context)
        CGContextRelease(context);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(space);
    return result;
}

static BOOL isJXL(NSData *data)
{
    return [data length] > 12 && jxl_signature_check([data bytes], [data length]) >= JXLDEC_SIG_CODESTREAM;
}

static void jxlMessage(void *user, jxl_severity severity, const char *message)
{
    (void)user; (void)severity; (void)message;
}

/* Up to four of n frames: the first, the last and two between. */
static NSArray *pickFrames(int n)
{
    NSMutableArray *out = [NSMutableArray array];
    int picks[4], i;
    if (n <= 4) {
        for (i = 0; i < n; i++)
            [out addObject:[NSNumber numberWithInt:i]];
        return out;
    }
    picks[0] = 0; picks[1] = n / 3; picks[2] = 2 * n / 3; picks[3] = n - 1;
    for (i = 0; i < 4; i++)
        [out addObject:[NSNumber numberWithInt:picks[i]]];
    return out;
}

/* An animated WebP as JPEGs of up to four of its frames. *total is the number of frames. nil when it cannot be read. */
static NSArray *jpegFramesFromAnimatedWebP(NSData *data, int longest, int *total)
{
    WebPAnimDecoderOptions options;
    WebPAnimDecoder *decoder;
    WebPData source;
    WebPAnimInfo info;
    NSMutableArray *out = [NSMutableArray array];
    NSArray *wanted;
    int frame = 0;
    if (!WebPAnimDecoderOptionsInit(&options))
        return nil;
    options.color_mode = MODE_RGBA;
    options.use_threads = 0;
    source.bytes = [data bytes];
    source.size = [data length];
    decoder = WebPAnimDecoderNew(&source, &options);
    if (!decoder)
        return nil;
    if (!WebPAnimDecoderGetInfo(decoder, &info) || info.frame_count < 1 || info.canvas_width > 16384 || info.canvas_height > 16384) {
        WebPAnimDecoderDelete(decoder);
        return nil;
    }
    *total = (int)info.frame_count;
    wanted = pickFrames(*total);
    while (WebPAnimDecoderHasMoreFrames(decoder) && [out count] < [wanted count]) {
        uint8_t *pixels = NULL;
        int timestamp = 0;
        if (!WebPAnimDecoderGetNext(decoder, &pixels, &timestamp))
            break;
        if ([[wanted objectAtIndex:[out count]] intValue] == frame) {
            NSData *jpeg = jpegFromRGBA(pixels, info.canvas_width, info.canvas_height, info.canvas_width * 4, longest);
            if (jpeg)
                [out addObject:jpeg];
            else
                break;
        }
        frame++;
    }
    WebPAnimDecoderDelete(decoder);
    return [out count] ? out : nil;
}

/* A JPEG XL picture as a JPEG; an animation as up to four of its frames. *total is the number of frames. nil when it cannot be read.
   The decoder is jxldec (plain C, single-threaded); a picture of more than 40 million pixels is refused so a big one cannot fill memory. */
static NSArray *jpegFramesFromJXL(NSData *data, int longest, int *total, int *looked)
{
    jxl_ctx *ctx = jxl_ctx_new(NULL, NULL, jxlMessage, NULL);
    jxl_doc *doc;
    jxl_image_info info;
    NSMutableArray *out = [NSMutableArray array];
    NSArray *wanted;
    unsigned i;
    if (!ctx)
        return nil;
    jxl_ctx_set_srgb_output(ctx, 1);
    doc = jxl_doc_open(ctx, [data bytes], [data length]);
    if (!doc || jxl_doc_info(doc, &info) != 0 || info.width < 1 || info.height < 1 || info.width > 16384 || info.height > 16384
        || (double)info.width * info.height > 40e6) {
        if (doc)
            jxl_doc_close(doc);
        jxl_ctx_free(ctx);
        return nil;
    }
    *total = jxl_doc_frame_count(doc);
    if (*total < 1)
        *total = 1;
    /* frames can only be decoded in order, so a long animation is judged by its first frames: about 24 million pixels' worth, 4 to 120 frames */
    *looked = (int)(24e6 / ((double)info.width * info.height));
    if (*looked < 4) *looked = 4;
    if (*looked > 120) *looked = 120;
    if (*looked > *total) *looked = *total;
    wanted = pickFrames(*looked);
    for (i = 0; i < [wanted count]; i++) {
        jxl_image *picture = jxl_frame_render(doc, [[wanted objectAtIndex:i] intValue], JXLDEC_FORMAT_RGBA32);
        NSData *jpeg;
        if (!picture)
            break;
        jpeg = jpegFromRGBA(picture->data, picture->width, picture->height, picture->stride, longest);
        jxl_image_destroy(ctx, picture);
        if (!jpeg)
            break;
        [out addObject:jpeg];
    }
    jxl_doc_close(doc);
    jxl_ctx_free(ctx);
    return [out count] ? out : nil;
}

/* A WebP picture as a JPEG no larger than `longest` pixels, scaled while it is decoded so a big one does not fill memory. */
static NSData *jpegFromWebP(NSData *data, int longest)
{
    WebPDecoderConfig config;
    NSData *result = nil;
    if (!WebPInitDecoderConfig(&config) || WebPGetFeatures([data bytes], [data length], &config.input) != VP8_STATUS_OK)
        return nil;
    if (config.input.width > 16384 || config.input.height > 16384 || config.input.width < 1 || config.input.height < 1)
        return nil;
    if (config.input.width > longest || config.input.height > longest) {
        double scale = (double)longest / (config.input.width > config.input.height ? config.input.width : config.input.height);
        config.options.use_scaling = 1;
        config.options.scaled_width = (int)(config.input.width * scale + 0.5);
        config.options.scaled_height = (int)(config.input.height * scale + 0.5);
        if (config.options.scaled_width < 1) config.options.scaled_width = 1;
        if (config.options.scaled_height < 1) config.options.scaled_height = 1;
    }
    config.output.colorspace = MODE_RGBA;
    if (WebPDecode([data bytes], [data length], &config) == VP8_STATUS_OK)
        result = jpegFromRGBA(config.output.u.RGBA.rgba, config.output.width, config.output.height, config.output.u.RGBA.stride, longest);
    WebPFreeDecBuffer(&config.output);
    return result;
}

NSData *TBJPEGFromWebP(NSData *data, int longest)
{
    return jpegFromWebP(data, longest);
}

static NSData *jpegFromFrame(NSData *data, int longest, int index)
{
    if (isWebP(data))
        return jpegFromWebP(data, longest);
    CGImageSourceRef source = CGImageSourceCreateWithData((CFDataRef)data, NULL);
    NSData *result = nil;
    if (source && CGImageSourceGetCount(source) > 0) {
        NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:longest], (id)kCGImageSourceThumbnailMaxPixelSize,
            (id)kCFBooleanTrue, (id)kCGImageSourceCreateThumbnailFromImageAlways, (id)kCFBooleanTrue, (id)kCGImageSourceCreateThumbnailWithTransform, nil];
        CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, index, (CFDictionaryRef)options);
        if (image) {
            NSMutableData *out = [NSMutableData data];
            CGImageDestinationRef destination = CGImageDestinationCreateWithData((CFMutableDataRef)out, CFSTR("public.jpeg"), 1, NULL);
            if (destination) {
                NSDictionary *quality = [NSDictionary dictionaryWithObject:[NSNumber numberWithFloat:0.85f] forKey:(id)kCGImageDestinationLossyCompressionQuality];
                CGImageDestinationAddImage(destination, image, (CFDictionaryRef)quality);
                if (CGImageDestinationFinalize(destination) && [out length])
                    result = out;
                CFRelease(destination);
            }
            CGImageRelease(image);
        }
    }
    if (source)
        CFRelease(source);
    return result;
}

static NSData *jpegFrom(NSData *data, int longest)
{
    return jpegFromFrame(data, longest, 0);
}

static int frameCountOf(NSData *data)
{
    CGImageSourceRef source = CGImageSourceCreateWithData((CFDataRef)data, NULL);
    int n = source ? (int)CGImageSourceGetCount(source) : 0;
    if (source)
        CFRelease(source);
    return n;
}

static int orientationOf(NSData *data)
{
    CGImageSourceRef source = CGImageSourceCreateWithData((CFDataRef)data, NULL);
    int value = 1;
    if (source) {
        NSDictionary *info = (NSDictionary *)CGImageSourceCopyPropertiesAtIndex(source, 0, NULL);
        NSNumber *o = [info objectForKey:(id)kCGImagePropertyOrientation];
        if (o)
            value = [o intValue];
        [info release];
        CFRelease(source);
    }
    return value;
}

/* ---- iWork ---- */

NSData *TBSnappyDecompress(const unsigned char *b, unsigned size)
{
    unsigned position = 0;
    NSMutableData *out = [NSMutableData data];
    unsigned long total = 0;
    int shift = 0;
    while (position < size) {
        unsigned char byte = b[position++];
        total |= (unsigned long)(byte & 0x7f) << shift;
        shift += 7;
        if (!(byte & 0x80) || shift > 28)
            break;
    }
    if (total > MAX_PART)
        return nil;
    [out setLength:total];
    {
        unsigned char *o = [out mutableBytes];
        unsigned long n = 0;
        while (position < size) {
            unsigned tag = b[position++], kind = tag & 3;
            unsigned long length, offset;
            if (kind == 0) {
                unsigned count;
                length = tag >> 2;
                if (length < 60)
                    length++;
                else {
                    unsigned k;
                    count = length - 59;
                    length = 0;
                    if (position + count > size)
                        return nil;
                    for (k = 0; k < count; k++)
                        length |= (unsigned long)b[position + k] << (8 * k);
                    length++;
                    position += count;
                }
                if (position + length > size || n + length > total)
                    return nil;
                memcpy(o + n, b + position, length);
                n += length;
                position += length;
                continue;
            }
            if (kind == 1) {
                if (position + 1 > size)
                    return nil;
                length = ((tag >> 2) & 7) + 4;
                offset = ((tag >> 5) << 8) | b[position];
                position += 1;
            } else if (kind == 2) {
                if (position + 2 > size)
                    return nil;
                length = (tag >> 2) + 1;
                offset = le16(b + position);
                position += 2;
            } else {
                if (position + 4 > size)
                    return nil;
                length = (tag >> 2) + 1;
                offset = le32(b + position);
                position += 4;
            }
            if (offset == 0 || offset > n || n + length > total)
                return nil;
            {
                unsigned long k;
                for (k = 0; k < length; k++)
                    o[n + k] = o[n - offset + k];
                n += length;
            }
        }
        [out setLength:n];
    }
    return out;
}

static NSData *iwaBytes(NSData *raw)
{
    const unsigned char *p = [raw bytes];
    unsigned position = 0, size = [raw length];
    NSMutableData *out = [NSMutableData data];
    while (position + 4 <= size && p[position] == 0) {
        unsigned length = p[position + 1] | (p[position + 2] << 8) | (p[position + 3] << 16);
        NSData *piece;
        position += 4;
        if (position + length > size)
            break;
        piece = TBSnappyDecompress(p + position, length);
        if (!piece)
            return nil;
        [out appendData:piece];
        position += length;
    }
    return out;
}

/* a varint; NO when it runs off the end */
static BOOL varint(const unsigned char *b, unsigned long size, unsigned long *position, unsigned long long *value)
{
    int shift = 0;
    *value = 0;
    while (*position < size && shift < 64) {
        unsigned char byte = b[(*position)++];
        *value |= (unsigned long long)(byte & 0x7f) << shift;
        if (!(byte & 0x80))
            return YES;
        shift += 7;
    }
    return NO;
}

/* The fields of one message as [number, wire, value] where value is an NSNumber or NSData; nil when it is not a message. */
static NSArray *protoFields(const unsigned char *b, unsigned long size)
{
    unsigned long position = 0;
    NSMutableArray *out = [NSMutableArray array];
    while (position < size) {
        unsigned long long key, value;
        int wire;
        if (!varint(b, size, &position, &key))
            return nil;
        wire = key & 7;
        if (wire == 0) {
            if (!varint(b, size, &position, &value))
                return nil;
            [out addObject:[NSArray arrayWithObjects:[NSNumber numberWithUnsignedLongLong:key >> 3], [NSNumber numberWithInt:0], [NSNumber numberWithUnsignedLongLong:value], nil]];
        } else if (wire == 1 || wire == 5) {
            unsigned n = wire == 1 ? 8 : 4;
            if (position + n > size)
                return nil;
            position += n;
        } else if (wire == 2) {
            if (!varint(b, size, &position, &value) || position + value > size)
                return nil;
            [out addObject:[NSArray arrayWithObjects:[NSNumber numberWithUnsignedLongLong:key >> 3], [NSNumber numberWithInt:2], [NSData dataWithBytes:b + position length:value], nil]];
            position += value;
        } else
            return nil;
    }
    return out;
}

static NSString *printable(NSData *value)
{
    NSString *text = [[[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding] autorelease];
    unsigned i;
    if (![text length])
        return nil;
    for (i = 0; i < [text length]; i++) {
        unichar c = [text characterAtIndex:i];
        if (c == '\n' || c == '\t' || c == '\r' || c == 0x2028 || c == 0x2029 || c == 0xfffc)
            continue;
        if (c < 0x20 || (c >= 0x7f && c < 0xa0) || (c >= 0xd800 && c < 0xf900) || c == 0xfffe || c == 0xffff)
            return nil;
    }
    return text;
}

static void protoStrings(NSData *buffer, int depth, NSMutableArray *out)
{
    NSArray *fields = protoFields([buffer bytes], [buffer length]);
    unsigned i;
    for (i = 0; i < [fields count]; i++) {
        NSArray *f = [fields objectAtIndex:i];
        NSString *text;
        if ([[f objectAtIndex:1] intValue] != 2)
            continue;
        text = printable([f objectAtIndex:2]);
        if (text)
            [out addObject:text];
        else if (depth < 8)
            protoStrings([f objectAtIndex:2], depth + 1, out);
    }
}

/* language codes (en, pt_BR) and UUIDs are bookkeeping, not text */
static BOOL noise(NSString *text)
{
    unsigned n = [text length], i;
    if (n == 36) {
        for (i = 0; i < 36; i++) {
            unichar c = [text characterAtIndex:i];
            if (i == 8 || i == 13 || i == 18 || i == 23 ? c != '-' : !((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F')))
                break;
        }
        if (i == 36)
            return YES;
    }
    if (n >= 2 && n <= 8) {
        unsigned letters = 0;
        BOOL ok = YES;
        for (i = 0; i < n && ok; i++) {
            unichar c = [text characterAtIndex:i];
            if (c >= 'a' && c <= 'z' && i < 3)
                letters++;
            else if ((c == '-' || c == '_') && letters >= 2 && i < n - 2)
                break;
            else
                ok = NO;
        }
        if (ok) {
            if (i == n)
                return letters >= 2;
            for (i++; i < n; i++) {
                unichar c = [text characterAtIndex:i];
                if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')))
                    return NO;
            }
            return YES;
        }
    }
    return NO;
}

static NSComparisonResult naturalCompare(id a, id b, void *context)
{
    return [(NSString *)a compare:b options:NSNumericSearch];
}

static NSString *iworkStrings(TBZip *zip)
{
    NSMutableArray *blocks = [NSMutableArray array], *names = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableArray *result = [NSMutableArray array];
    NSEnumerator *each = [[zip names] objectEnumerator];
    NSString *name;
    int slide = 0;
    unsigned i;
    while ((name = [each nextObject]))
        if ([[name lowercaseString] hasSuffix:@".iwa"])
            [names addObject:name];
    names = (NSMutableArray *)[names sortedArrayUsingFunction:naturalCompare context:NULL];
    for (i = 0; i < [names count]; i++) {
        NSString *low = [[names objectAtIndex:i] lowercaseString];
        NSData *decoded;
        NSMutableArray *found = [NSMutableArray array];
        const unsigned char *b;
        unsigned long size, position = 0;
        BOOL skip = NO;
        NSArray *words = [NSArray arrayWithObjects:@"stylesheet", @"metadata", @"masterslide", @"viewstate", @"annotation", nil];
        unsigned w;
        for (w = 0; w < [words count]; w++)
            if ([low rangeOfString:[words objectAtIndex:w]].location != NSNotFound)
                skip = YES;
        if (skip)
            continue;
        NS_DURING
            decoded = iwaBytes([zip dataFor:[names objectAtIndex:i]]);
        NS_HANDLER
            decoded = nil;
        NS_ENDHANDLER
        if (!decoded)
            continue;
        b = [decoded bytes];
        size = [decoded length];
        while (position < size) {
            unsigned long long length;
            NSArray *info;
            unsigned f;
            if (!varint(b, size, &position, &length) || position + length > size)
                break;
            info = protoFields(b + position, length);
            position += length;
            if (!info)
                break;
            for (f = 0; f < [info count]; f++) {
                NSArray *field = [info objectAtIndex:f];
                NSArray *details;
                unsigned long long type = 0, payloadSize = 0;
                unsigned d;
                if ([[field objectAtIndex:0] intValue] != 2 || [[field objectAtIndex:1] intValue] != 2)
                    continue;
                details = protoFields([[field objectAtIndex:2] bytes], [[field objectAtIndex:2] length]);
                for (d = 0; d < [details count]; d++) {
                    NSArray *x = [details objectAtIndex:d];
                    if ([[x objectAtIndex:0] intValue] == 1 && [[x objectAtIndex:1] intValue] == 0)
                        type = [[x objectAtIndex:2] unsignedLongLongValue];
                    if ([[x objectAtIndex:0] intValue] == 3 && [[x objectAtIndex:1] intValue] == 0)
                        payloadSize = [[x objectAtIndex:2] unsignedLongLongValue];
                }
                if (position + payloadSize > size)
                    break;
                if (type == 2001 || type == 6005) {
                    NSMutableArray *strings = [NSMutableArray array];
                    unsigned s;
                    protoStrings([NSData dataWithBytes:b + position length:payloadSize], 0, strings);
                    for (s = 0; s < [strings count]; s++) {
                        NSString *text = swap([strings objectAtIndex:s], [NSString stringWithFormat:@"%C", (unichar)0xfffc], @"");
                        if (!noise(text) && [TBTrim(text) length]) {
                            while ([text hasSuffix:@"\n"])
                                text = [text substringToIndex:[text length] - 1];
                            [found addObject:text];
                        }
                    }
                }
                position += payloadSize;
            }
        }
        if (![found count])
            continue;
        if ([low rangeOfString:@"/slide"].location != NSNotFound)
            [blocks addObject:[NSString stringWithFormat:@"--- Slide %d ---", ++slide]];
        [blocks addObjectsFromArray:found];
    }
    for (i = 0; i < [blocks count]; i++) {
        NSString *block = [blocks objectAtIndex:i];
        if ([block hasPrefix:@"---"] || ![seen containsObject:block]) {
            [seen addObject:block];
            [result addObject:block];
        }
    }
    return [result componentsJoinedByString:@"\n"];
}

static NSString *joinLines(NSArray *lines);

/* ---- Numbers tables: the cells themselves, from the IWA archives ---- */

static NSArray *protoAll(NSArray *fields, unsigned number)
{
    NSMutableArray *out = [NSMutableArray array];
    unsigned i;
    for (i = 0; i < [fields count]; i++)
        if ([[[fields objectAtIndex:i] objectAtIndex:0] unsignedIntValue] == number)
            [out addObject:[[fields objectAtIndex:i] objectAtIndex:2]];
    return out;
}

static id protoFirst(NSArray *fields, unsigned number)
{
    NSArray *all = protoAll(fields, number);
    return [all count] ? [all objectAtIndex:0] : nil;
}

static NSArray *messageFields(id data)
{
    return [data isKindOfClass:[NSData class]] ? protoFields([data bytes], [data length]) : nil;
}

/* the object a Reference message points to */
static NSNumber *referenceId(id data)
{
    return protoFirst(messageFields(data), 1);
}

/* every object in the document's archives: identifier -> [[type, payload]...] */
static NSDictionary *iworkObjects(TBZip *zip)
{
    NSMutableDictionary *objects = [NSMutableDictionary dictionary];
    NSEnumerator *each = [[zip names] objectEnumerator];
    NSString *name;
    while ((name = [each nextObject])) {
        NSData *decoded;
        const unsigned char *b;
        unsigned long size, position = 0;
        if (![[name lowercaseString] hasSuffix:@".iwa"])
            continue;
        NS_DURING
            decoded = iwaBytes([zip dataFor:name]);
        NS_HANDLER
            decoded = nil;
        NS_ENDHANDLER
        if (!decoded)
            continue;
        b = [decoded bytes];
        size = [decoded length];
        while (position < size) {
            unsigned long long length;
            NSArray *info, *infos;
            NSNumber *identifier;
            unsigned k;
            if (!varint(b, size, &position, &length) || position + length > size)
                break;
            info = protoFields(b + position, length);
            position += length;
            if (!info)
                break;
            identifier = protoFirst(info, 1);
            infos = protoAll(info, 2);
            for (k = 0; k < [infos count]; k++) {
                NSArray *m = messageFields([infos objectAtIndex:k]);
                unsigned long long payload = [protoFirst(m, 3) unsignedLongLongValue];
                NSNumber *type = protoFirst(m, 1);
                if (position + payload > size)
                    break;
                if (identifier && type) {
                    NSMutableArray *list = [objects objectForKey:identifier];
                    if (!list) {
                        list = [NSMutableArray array];
                        [objects setObject:list forKey:identifier];
                    }
                    [list addObject:[NSArray arrayWithObjects:type, [NSData dataWithBytes:b + position length:payload], nil]];
                }
                position += payload;
            }
        }
    }
    return objects;
}

static NSData *objectOfType(NSDictionary *objects, NSNumber *identifier, int type1, int type2)
{
    NSArray *list = [objects objectForKey:identifier];
    unsigned i;
    for (i = 0; i < [list count]; i++) {
        int t = [[[list objectAtIndex:i] objectAtIndex:0] intValue];
        if (t == type1 || t == type2)
            return [[list objectAtIndex:i] objectAtIndex:1];
    }
    return nil;
}

/* key -> string for a table's string list (and its segments) */
static NSDictionary *stringList(NSDictionary *objects, NSNumber *identifier)
{
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSData *list = identifier ? objectOfType(objects, identifier, 6005, 6201) : nil;
    NSArray *fields = messageFields(list), *entries, *segments;
    unsigned i, s;
    if (!list)
        return out;
    entries = protoAll(fields, 3);
    segments = protoAll(fields, 4);
    for (s = 0; s < [segments count]; s++) {
        NSData *segment = objectOfType(objects, referenceId([segments objectAtIndex:s]), 6011, 6011);
        entries = [entries arrayByAddingObjectsFromArray:protoAll(messageFields(segment), 3)];
    }
    for (i = 0; i < [entries count]; i++) {
        NSArray *e = messageFields([entries objectAtIndex:i]);
        NSData *text = protoFirst(e, 3);
        if (text)
            [out setObject:[[[NSString alloc] initWithData:text encoding:NSUTF8StringEncoding] autorelease] forKey:protoFirst(e, 1)];
    }
    return out;
}

/* seconds after 1 January 2001 as a date (and a time when there is one) */
static NSString *numbersDate(double seconds)
{
    long long days = (long long)floor(seconds / 86400.0);
    long secs = (long)(seconds - days * 86400.0 + 0.5);
    int y, m, d;
    TBCivilFromDays(days + 11323, &y, &m, &d);   /* 2001-01-01 is 11323 days after 1970-01-01 */
    if (secs)
        return [NSString stringWithFormat:@"%04d-%02d-%02d %02ld:%02ld", y, m, d, secs / 3600, (secs / 60) % 60];
    return [NSString stringWithFormat:@"%04d-%02d-%02d", y, m, d];
}

/* one cell from its storage bytes (version 5); nil when empty or not understood */
static NSString *numbersCell(const unsigned char *b, unsigned long n, NSDictionary *strings)
{
    unsigned flags, offset = 12;
    double decimal = 0, number = 0, seconds = 0;
    BOOL haveDecimal = NO, haveNumber = NO, haveSeconds = NO;
    int stringId = -1, type;
    if (n < 12 || b[0] != 5)
        return nil;
    type = b[1];
    flags = le32(b + 8);
    if (flags & 0x1) {
        const unsigned char *d = b + offset;
        double mantissa = d[14] & 1;
        int exponent = (((d[15] & 0x7F) << 7) | (d[14] >> 1)) - 0x1820, i;
        if (offset + 16 > n)
            return nil;
        for (i = 13; i >= 0; i--)
            mantissa = mantissa * 256 + d[i];
        decimal = (d[15] & 0x80 ? -mantissa : mantissa) * pow(10, exponent);
        haveDecimal = YES;
        offset += 16;
    }
    if (flags & 0x2) {
        if (offset + 8 > n)
            return nil;
        memcpy(&number, b + offset, 8);
        haveNumber = YES;
        offset += 8;
    }
    if (flags & 0x4) {
        if (offset + 8 > n)
            return nil;
        memcpy(&seconds, b + offset, 8);
        haveSeconds = YES;
        offset += 8;
    }
    if (flags & 0x8) {
        if (offset + 4 > n)
            return nil;
        stringId = (int)le32(b + offset);
        offset += 4;
    }
    switch (type) {
    case 2: case 10: return haveDecimal ? TBNumberText(decimal) : nil;
    case 3: return stringId >= 0 ? [strings objectForKey:[NSNumber numberWithUnsignedInt:(unsigned)stringId]] : nil;
    case 5: return haveSeconds ? numbersDate(seconds) : nil;
    case 6: return haveNumber ? (number > 0 ? @"TRUE" : @"FALSE") : nil;
    case 7: return haveNumber ? TBNumberText(number) : nil;
    case 8: return @"#ERROR";
    }
    return nil;
}

/* the tables of a Numbers file as tab-separated rows, or nil when none could be read */
static NSString *numbersTables(TBZip *zip)
{
    NSDictionary *objects = iworkObjects(zip);
    NSMutableDictionary *sheetOf = [NSMutableDictionary dictionary];
    NSMutableArray *tableIds = [NSMutableArray array], *out = [NSMutableArray array];
    NSEnumerator *each = [objects keyEnumerator];
    NSNumber *identifier;
    NSString *lastSheet = nil;
    unsigned i;
    long budget = MAX_TEXT;
    while ((identifier = [each nextObject])) {
        NSData *sheet = objectOfType(objects, identifier, 2, 2), *table = objectOfType(objects, identifier, 6001, 6001);
        if (table)
            [tableIds addObject:identifier];
        if (sheet) {
            NSArray *f = messageFields(sheet), *drawables = protoAll(f, 2);
            NSData *nameData = protoFirst(f, 1);
            NSString *sheetName = nameData ? [[[NSString alloc] initWithData:nameData encoding:NSUTF8StringEncoding] autorelease] : @"";
            unsigned k;
            for (k = 0; k < [drawables count]; k++) {
                NSData *info = objectOfType(objects, referenceId([drawables objectAtIndex:k]), 6000, 6000);
                NSNumber *model = referenceId(protoFirst(messageFields(info), 2));
                if (model)
                    [sheetOf setObject:sheetName forKey:model];
            }
        }
    }
    tableIds = (NSMutableArray *)[tableIds sortedArrayUsingSelector:@selector(compare:)];
    for (i = 0; i < [tableIds count] && budget > 0; i++) {
        NSNumber *tid = [tableIds objectAtIndex:i];
        NSArray *table = messageFields(objectOfType(objects, tid, 6001, 6001)), *store = messageFields(protoFirst(table, 4));
        NSData *nameData = protoFirst(table, 8);
        unsigned columns = [protoFirst(table, 7) unsignedIntValue], tileSize = 256;
        NSArray *tileStorage = messageFields(protoFirst(store, 3)), *tiles = protoAll(tileStorage, 1);
        NSDictionary *strings = stringList(objects, referenceId(protoFirst(store, 4)));
        NSMutableDictionary *rows = [NSMutableDictionary dictionary];
        NSArray *rowNumbers;
        NSString *sheetName = [sheetOf objectForKey:tid];
        unsigned t, r;
        if (protoFirst(tileStorage, 2))
            tileSize = [protoFirst(tileStorage, 2) unsignedIntValue];
        if (!tileSize || columns > 1000)
            continue;
        for (t = 0; t < [tiles count]; t++) {
            NSArray *tileRef = messageFields([tiles objectAtIndex:t]);
            unsigned base = [protoFirst(tileRef, 1) unsignedIntValue] * tileSize;
            NSArray *tile = messageFields(objectOfType(objects, referenceId(protoFirst(tileRef, 2)), 6002, 6002)), *infos = protoAll(tile, 5);
            for (r = 0; r < [infos count]; r++) {
                NSArray *info = messageFields([infos objectAtIndex:r]);
                NSData *buffer = protoFirst(info, 6), *offsetData = protoFirst(info, 7);
                BOOL wide = [protoFirst(info, 8) intValue] != 0;
                const unsigned char *bytes = [buffer bytes], *o = [offsetData bytes];
                unsigned count = [offsetData length] / 2, c;
                NSMutableDictionary *row = [NSMutableDictionary dictionary];
                if (!buffer || !offsetData)
                    continue;
                for (c = 0; c < count && c < columns; c++) {
                    int start = (short)(o[c * 2] | (o[c * 2 + 1] << 8)), end = (int)[buffer length], k;
                    NSString *text;
                    if (start < 0)
                        continue;
                    if (wide)
                        start *= 4;
                    for (k = c + 1; k < (int)count; k++) {
                        int next = (short)(o[k * 2] | (o[k * 2 + 1] << 8));
                        if (next >= 0) {
                            end = wide ? next * 4 : next;
                            break;
                        }
                    }
                    if (start >= end || end > (int)[buffer length])
                        continue;
                    text = numbersCell(bytes + start, end - start, strings);
                    if (text)
                        [row setObject:text forKey:[NSNumber numberWithUnsignedInt:c]];
                }
                [rows setObject:row forKey:[NSNumber numberWithUnsignedInt:base + [protoFirst(info, 1) unsignedIntValue]]];
            }
        }
        if (![rows count])
            continue;
        if (sheetName && ![sheetName isEqualToString:lastSheet]) {
            [out addObject:[NSString stringWithFormat:@"--- Sheet: %@ ---", sheetName]];
            lastSheet = sheetName;
        }
        [out addObject:[NSString stringWithFormat:@"Table: %@", nameData ? [[[NSString alloc] initWithData:nameData encoding:NSUTF8StringEncoding] autorelease] : @""]];
        rowNumbers = [[rows allKeys] sortedArrayUsingSelector:@selector(compare:)];
        for (r = 0; r < [rowNumbers count] && r < 2000 && budget > 0; r++) {
            NSDictionary *row = [rows objectForKey:[rowNumbers objectAtIndex:r]];
            NSMutableString *line = [NSMutableString string];
            unsigned c, last = 0;
            for (c = 0; c < columns; c++)
                if ([row objectForKey:[NSNumber numberWithUnsignedInt:c]])
                    last = c + 1;
            for (c = 0; c < last; c++) {
                NSString *cell = [row objectForKey:[NSNumber numberWithUnsignedInt:c]];
                if (c)
                    [line appendString:@"\t"];
                if (cell)
                    [line appendString:cell];
            }
            if ([line length]) {
                [out addObject:line];
                budget -= [line length];
            }
        }
    }
    return [out count] ? joinLines(out) : nil;
}

static NSString *iworkOldText(TBZip *zip)
{
    NSString *names[2] = {@"index.xml", @"index.xml.gz"};
    int n;
    for (n = 0; n < 2; n++) {
        NSData *xml;
        NSArray *pieces;
        NSMutableArray *lines = [NSMutableArray array];
        unsigned i;
        if (![zip has:names[n]])
            continue;
        xml = [zip dataFor:names[n]];
        if (n == 1)
            xml = TBGunzip(xml, MAX_PART);
        if (!xml)
            return @"";
        pieces = [TBParas parse:xml paragraphs:[NSArray arrayWithObjects:@"t", @"ls", @"span", nil] text:nil breaks:NO];
        for (i = 0; i < [pieces count]; i++) {
            NSString *line = TBTrim([pieces objectAtIndex:i]);
            if ([line length] && ![lines containsObject:line])
                [lines addObject:line];
        }
        return [lines componentsJoinedByString:@"\n"];
    }
    return @"";
}

/* ---- Office ---- */

static NSString *joinLines(NSArray *lines)
{
    return TBTrim([lines componentsJoinedByString:@"\n"]);
}

static NSString *docxText(TBZip *zip)
{
    NSMutableArray *lines = [NSMutableArray array];
    NSString *parts[3] = {@"word/document.xml", @"word/footnotes.xml", @"word/endnotes.xml"};
    int n;
    for (n = 0; n < 3; n++) {
        NSArray *paras;
        unsigned i;
        if (![zip has:parts[n]])
            continue;
        if (n > 0) {
            NSString *base = [[[parts[n] lastPathComponent] stringByDeletingPathExtension] capitalizedString];
            [lines addObject:@""];
            [lines addObject:[NSString stringWithFormat:@"[%@]", base]];
        }
        paras = [TBParas parse:[zip dataFor:parts[n]] paragraphs:[NSArray arrayWithObject:@"p"] text:[NSArray arrayWithObject:@"t"] breaks:YES];
        for (i = 0; i < [paras count]; i++) {
            NSString *text = [paras objectAtIndex:i];
            if ([TBTrim(text) length] || ([lines count] && [TBTrim([lines lastObject]) length]))
                [lines addObject:text];
        }
    }
    return joinLines(lines);
}

static NSArray *slideNames(TBZip *zip)
{
    NSMutableArray *slides = [NSMutableArray array];
    NSEnumerator *each = [[zip names] objectEnumerator];
    NSString *name;
    while ((name = [each nextObject])) {
        if ([name hasPrefix:@"ppt/slides/slide"] && [name hasSuffix:@".xml"]) {
            NSString *middle = [name substringWithRange:NSMakeRange(16, [name length] - 20)];
            if ([middle length] && [[NSString stringWithFormat:@"%d", [middle intValue]] isEqualToString:middle])
                [slides addObject:name];
        }
    }
    return [slides sortedArrayUsingFunction:naturalCompare context:NULL];
}

static NSString *pptxText(TBZip *zip)
{
    NSArray *slides = slideNames(zip);
    NSMutableArray *out = [NSMutableArray array];
    unsigned i;
    NSArray *p = [NSArray arrayWithObject:@"p"], *t = [NSArray arrayWithObject:@"t"];
    for (i = 0; i < [slides count]; i++) {
        NSString *slide = [slides objectAtIndex:i];
        NSString *relations = [[[slide stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"_rels"] stringByAppendingPathComponent:[[slide lastPathComponent] stringByAppendingString:@".rels"]];
        NSArray *paras = [TBParas parse:[zip dataFor:slide] paragraphs:p text:t breaks:NO];
        unsigned j;
        [out addObject:[NSString stringWithFormat:@"--- Slide %u ---", i + 1]];
        for (j = 0; j < [paras count]; j++)
            if ([TBTrim([paras objectAtIndex:j]) length])
                [out addObject:[paras objectAtIndex:j]];
        if ([zip has:relations]) {
            NSString *rels = [[[NSString alloc] initWithData:[zip dataFor:relations] encoding:NSUTF8StringEncoding] autorelease];
            NSRange at = NSMakeRange(0, 0);
            NSString *marker = @"Target=\"../notesSlides/";
            while (rels && (at = [rels rangeOfString:marker options:0 range:NSMakeRange(NSMaxRange(at), [rels length] - NSMaxRange(at))]).location != NSNotFound) {
                NSRange end = [rels rangeOfString:@"\"" options:0 range:NSMakeRange(NSMaxRange(at), [rels length] - NSMaxRange(at))];
                NSString *notes;
                if (end.location == NSNotFound)
                    break;
                notes = [@"ppt/notesSlides/" stringByAppendingString:[rels substringWithRange:NSMakeRange(NSMaxRange(at), end.location - NSMaxRange(at))]];
                if ([zip has:notes]) {
                    NSArray *np = [TBParas parse:[zip dataFor:notes] paragraphs:p text:t breaks:NO];
                    NSMutableArray *spoken = [NSMutableArray array];
                    unsigned k;
                    for (k = 0; k < [np count]; k++) {
                        NSString *line = TBTrim([np objectAtIndex:k]);
                        if ([line length] && ![[NSString stringWithFormat:@"%d", [line intValue]] isEqualToString:line])
                            [spoken addObject:[np objectAtIndex:k]];
                    }
                    if ([spoken count])
                        [out addObject:[@"[Speaker notes] " stringByAppendingString:[spoken componentsJoinedByString:@" "]]];
                }
            }
        }
    }
    return joinLines(out);
}

static NSString *xlsxText(TBZip *zip)
{
    NSArray *shared = [zip has:@"xl/sharedStrings.xml"] ? [TBCells sharedStrings:[zip dataFor:@"xl/sharedStrings.xml"]] : [NSArray array];
    NSDictionary *targets = [zip has:@"xl/_rels/workbook.xml.rels"] ? [TBCells relationships:[zip dataFor:@"xl/_rels/workbook.xml.rels"]] : [NSDictionary dictionary];
    NSArray *sheets = [TBCells sheetNames:[zip dataFor:@"xl/workbook.xml"]];
    NSMutableArray *out = [NSMutableArray array];
    long budget = MAX_TEXT;
    unsigned i;
    for (i = 0; i < [sheets count]; i++) {
        NSDictionary *sheet = [sheets objectAtIndex:i];
        NSString *part = [targets objectForKey:[sheet objectForKey:@"id"]];
        NSArray *rows;
        unsigned shown = 0, r;
        BOOL stopped = NO;
        if (!part || ![zip has:part])
            continue;
        [out addObject:[NSString stringWithFormat:@"--- Sheet: %@ ---", [sheet objectForKey:@"name"]]];
        if (budget <= 0) {
            [out addObject:@"[this sheet is not shown: the text limit was reached]"];
            continue;
        }
        rows = sheetRows(checkedXML([zip dataFor:part]), shared, 2000, &stopped);
        for (r = 0; r < [rows count] && shown < 2000 && budget > 0; r++) {
            NSMutableString *line = [NSMutableString stringWithString:[[rows objectAtIndex:r] componentsJoinedByString:@"\t"]];
            while ([line hasSuffix:@"\t"])
                [line deleteCharactersInRange:NSMakeRange([line length] - 1, 1)];
            if ([line length]) {
                [out addObject:line];
                shown++;
                budget -= [line length];
            }
        }
        if (stopped)
            [out addObject:@"[more rows not shown]"];
        else if (r < [rows count] && budget <= 0)
            [out addObject:@"[more rows not shown: the text limit was reached]"];
    }
    return joinLines(out);
}

static NSString *odfText(TBZip *zip)
{
    NSArray *paras = [TBParas parse:[zip dataFor:@"content.xml"] paragraphs:[NSArray arrayWithObjects:@"p", @"h", nil] text:nil breaks:NO];
    NSMutableArray *lines = [NSMutableArray array];
    unsigned i;
    for (i = 0; i < [paras count]; i++)
        if ([TBTrim([paras objectAtIndex:i]) length])
            [lines addObject:[paras objectAtIndex:i]];
    return joinLines(lines);
}

/* ---- the entry point ---- */

static NSArray *types(int which)
{
    switch (which) {
    case 0: return [NSArray arrayWithObjects:@"heic", @"heif", @"webp", @"avif", @"jxl", @"jp2", @"jpg", @"jpeg", @"tif", @"tiff", @"bmp", @"gif", @"png", nil];
    case 1: return [NSArray arrayWithObjects:@"docx", @"pptx", @"xlsx", @"doc", @"ppt", @"xls", @"epub", @"zip", @"mp3", @"m4a", @"aac", @"wav", @"aif", @"aiff", @"aifc", @"caf", @"au", @"snd", @"amr", @"mp2", @"mov", @"mp4", @"m4v", @"mpg", @"mpeg", @"3gp", @"3g2", @"avi", @"qt", nil];
    }
    return [NSArray arrayWithObjects:@"pages", @"numbers", @"key", nil];
}

@interface TBExtract (Private)
+ (NSDictionary *)convert:(NSString *)name data:(NSData *)data;
@end

static pthread_mutex_t gate = PTHREAD_MUTEX_INITIALIZER;

/* ---- ZIP archives (the list of what is inside) and EPUB books ---- */

static NSString *sizeText(double bytes)
{
    if (bytes < 1024)
        return [NSString stringWithFormat:@"%.0f B", bytes];
    if (bytes < 1024 * 1024)
        return [NSString stringWithFormat:@"%.1f KB", bytes / 1024];
    if (bytes < 1024.0 * 1024 * 1024)
        return [NSString stringWithFormat:@"%.1f MB", bytes / (1024 * 1024)];
    return [NSString stringWithFormat:@"%.2f GB", bytes / (1024.0 * 1024 * 1024)];
}

static NSString *pad10(NSString *t)
{
    unsigned n = [t length];
    return n >= 10 ? t : [[@"" stringByPaddingToLength:10 - n withString:@" " startingAtIndex:0] stringByAppendingString:t];
}

static NSString *zipListing(TBZip *zip)
{
    NSArray *names = [[zip names] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableString *out = [NSMutableString string];
    unsigned i, files = 0, shown = 0;
    for (i = 0; i < [names count]; i++)
        if (![[names objectAtIndex:i] hasSuffix:@"/"])
            files++;
    [out appendFormat:@"ZIP archive: %u files, %@ unpacked.\n\n", files, sizeText([zip totalSize])];
    for (i = 0; i < [names count] && shown < 1000; i++) {
        NSString *name = [names objectAtIndex:i];
        [out appendFormat:@"%@  %@\n", pad10([name hasSuffix:@"/"] ? @"folder" : sizeText([zip sizeOf:name])), name];
        shown++;
    }
    if (shown < [names count])
        [out appendFormat:@"... and %u more.\n", (unsigned)[names count] - shown];
    return out;
}

/* The value of attribute `name` inside one tag's text */
static NSString *tagAttr(NSString *tag, NSString *name)
{
    NSRange r = [tag rangeOfString:[name stringByAppendingString:@"=\""]];
    char quote = '"';
    NSRange end;
    if (r.location == NSNotFound) {
        r = [tag rangeOfString:[name stringByAppendingString:@"='"]];
        quote = '\'';
    }
    if (r.location == NSNotFound)
        return nil;
    tag = [tag substringFromIndex:r.location + r.length];
    end = [tag rangeOfString:[NSString stringWithFormat:@"%c", quote]];
    return end.location == NSNotFound ? nil : [tag substringToIndex:end.location];
}

/* every <tag ...> of that name in the XML text */
static NSArray *tagsNamed(NSString *xml, NSString *name)
{
    NSMutableArray *out = [NSMutableArray array];
    NSString *open = [@"<" stringByAppendingString:name];
    NSRange from = NSMakeRange(0, [xml length]);
    for (;;) {
        NSRange r = [xml rangeOfString:open options:0 range:from], close;
        unichar after;
        if (r.location == NSNotFound)
            break;
        from = NSMakeRange(r.location + r.length, [xml length] - r.location - r.length);
        if (from.length == 0)
            break;
        after = [xml characterAtIndex:from.location];
        if (after != ' ' && after != '\n' && after != '\t' && after != '/' && after != '>')
            continue;
        close = [xml rangeOfString:@">" options:0 range:from];
        if (close.location == NSNotFound)
            break;
        [out addObject:[xml substringWithRange:NSMakeRange(r.location, close.location - r.location)]];
        from = NSMakeRange(close.location, [xml length] - close.location);
    }
    return out;
}

static NSString *utf8(NSData *d)
{
    NSString *s = [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] autorelease];
    return s ? s : [[[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding] autorelease];
}

/* An EPUB's title, author and the text of its chapters in reading order; *cover gets the cover picture's bytes when there is one. */
static NSString *epubText(TBZip *zip, NSData **cover)
{
    NSString *container = [zip has:@"META-INF/container.xml"] ? utf8([zip dataFor:@"META-INF/container.xml"]) : nil;
    NSArray *roots = container ? tagsNamed(container, @"rootfile") : nil;
    NSString *opfPath = [roots count] ? tagAttr([roots objectAtIndex:0], @"full-path") : nil, *dir, *opf, *coverId = nil;
    NSMutableDictionary *hrefs = [NSMutableDictionary dictionary], *props = [NSMutableDictionary dictionary];
    NSMutableString *out = [NSMutableString string];
    NSArray *titles, *authors, *items;
    unsigned i;
    if (!opfPath || ![zip has:opfPath])
        fail(@"This EPUB has no book description (container.xml), so it cannot be read.");
    opf = utf8([zip dataFor:opfPath]);
    dir = [opfPath rangeOfString:@"/"].location == NSNotFound ? @"" : [[opfPath stringByDeletingLastPathComponent] stringByAppendingString:@"/"];
    items = tagsNamed(opf, @"item");
    for (i = 0; i < [items count]; i++) {
        NSString *tag = [items objectAtIndex:i], *ident = tagAttr(tag, @"id"), *href = tagAttr(tag, @"href");
        if (ident && href) {
            [hrefs setObject:href forKey:ident];
            if (tagAttr(tag, @"properties"))
                [props setObject:tagAttr(tag, @"properties") forKey:ident];
            if ([[props objectForKey:ident] rangeOfString:@"cover-image"].location != NSNotFound)
                coverId = ident;
        }
    }
    {
        NSArray *metas = tagsNamed(opf, @"meta");
        for (i = 0; i < [metas count] && !coverId; i++)
            if ([tagAttr([metas objectAtIndex:i], @"name") isEqualToString:@"cover"])
                coverId = tagAttr([metas objectAtIndex:i], @"content");
    }
    titles = [TBParas parse:[opf dataUsingEncoding:NSUTF8StringEncoding] paragraphs:[NSArray arrayWithObject:@"title"] text:nil breaks:NO];
    authors = [TBParas parse:[opf dataUsingEncoding:NSUTF8StringEncoding] paragraphs:[NSArray arrayWithObject:@"creator"] text:nil breaks:NO];
    if ([titles count])
        [out appendFormat:@"%@\n", TBTrim([titles objectAtIndex:0])];
    if ([authors count])
        [out appendFormat:@"by %@\n", TBTrim([authors componentsJoinedByString:@", "])];
    [out appendString:@"\n"];
    if (coverId && [hrefs objectForKey:coverId] && cover) {
        NSString *path = [dir stringByAppendingString:[[hrefs objectForKey:coverId] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
        if ([zip has:path] && [zip sizeOf:path] < 20 * 1024 * 1024)
            *cover = [zip dataFor:path];
    }
    {
        NSArray *refs = tagsNamed(opf, @"itemref");
        NSArray *blocks = [NSArray arrayWithObjects:@"p", @"h1", @"h2", @"h3", @"h4", @"h5", @"h6", @"li", @"blockquote", @"pre", @"td", nil];
        for (i = 0; i < [refs count] && [out length] < MAX_TEXT; i++) {
            NSString *href = [hrefs objectForKey:tagAttr([refs objectAtIndex:i], @"idref")], *path;
            NSData *page;
            NSArray *paras;
            if (!href)
                continue;
            if ([href rangeOfString:@"#"].location != NSNotFound)
                href = [href substringToIndex:[href rangeOfString:@"#"].location];
            path = [dir stringByAppendingString:[href stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding]];
            if (![zip has:path] || [zip sizeOf:path] > 8 * 1024 * 1024)
                continue;
            page = [zip dataFor:path];
            paras = [TBParas parse:page paragraphs:blocks text:nil breaks:YES];
            if ([paras count] > 0) {
                unsigned k;
                for (k = 0; k < [paras count]; k++) {
                    NSString *line = TBTrim([paras objectAtIndex:k]);
                    if ([line length])
                        [out appendFormat:@"%@\n\n", line];
                }
            }
        }
    }
    return out;
}

/* ---- audio and video files ----
   The sound is turned into 16 kHz mono WAV by the system's afconvert and sent for transcription in pieces of three minutes (the same speech-to-text as
   dictation: OpenAI, Mistral or Google, whichever has a key). A video also gives up to four pictures from it, taken by QuickTime. */

static NSArray *audioTypes(void) { return [NSArray arrayWithObjects:@"mp3", @"m4a", @"aac", @"wav", @"aif", @"aiff", @"aifc", @"caf", @"au", @"snd", @"amr", @"mp2", nil]; }
static NSArray *videoTypes(void) { return [NSArray arrayWithObjects:@"mov", @"mp4", @"m4v", @"mpg", @"mpeg", @"3gp", @"3g2", @"avi", @"qt", nil]; }

static NSString *clockText(double seconds)
{
    int s = (int)(seconds + 0.5);
    return s >= 3600 ? [NSString stringWithFormat:@"%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60] : [NSString stringWithFormat:@"%d:%02d", s / 60, s % 60];
}

static NSData *wavChunk(const unsigned char *pcm, unsigned length)
{
    NSMutableData *out = [NSMutableData dataWithCapacity:length + 44];
    unsigned char h[44];
    unsigned rate = 16000, bytes = rate * 2;
    memcpy(h, "RIFF", 4); h[4] = (length + 36) & 255; h[5] = ((length + 36) >> 8) & 255; h[6] = ((length + 36) >> 16) & 255; h[7] = ((length + 36) >> 24) & 255;
    memcpy(h + 8, "WAVEfmt ", 8);
    h[16] = 16; h[17] = h[18] = h[19] = 0;
    h[20] = 1; h[21] = 0;           /* PCM */
    h[22] = 1; h[23] = 0;           /* mono */
    h[24] = rate & 255; h[25] = (rate >> 8) & 255; h[26] = h[27] = 0;
    h[28] = bytes & 255; h[29] = (bytes >> 8) & 255; h[30] = (bytes >> 16) & 255; h[31] = 0;
    h[32] = 2; h[33] = 0;           /* bytes per frame */
    h[34] = 16; h[35] = 0;          /* bits */
    memcpy(h + 36, "data", 4);
    h[40] = length & 255; h[41] = (length >> 8) & 255; h[42] = (length >> 16) & 255; h[43] = (length >> 24) & 255;
    [out appendBytes:h length:44];
    [out appendBytes:pcm length:length];
    return out;
}

/* The sound of a file as 16 kHz mono 16-bit samples (native byte order), up to `maxFrames` of them. nil when the system cannot read it.
   CoreAudio (ExtAudioFile, in Tiger and later) does the decoding, so mp3, AAC and the rest need no program of their own. */
static NSData *pcmOfFile(NSString *path, double *seconds, unsigned maxFrames)
{
    FSRef ref;
    ExtAudioFileRef file = NULL;
    AudioStreamBasicDescription source, client;
    UInt32 size = sizeof source;
    SInt64 frames = 0;
    NSMutableData *out;
    if (FSPathMakeRef((const UInt8 *)[path fileSystemRepresentation], &ref, NULL) != noErr)
        return nil;
    if (ExtAudioFileOpen(&ref, &file) != noErr || !file)
        return nil;
    if (ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &source) != noErr || source.mSampleRate <= 0) {
        ExtAudioFileDispose(file);
        return nil;
    }
    size = sizeof frames;
    if (ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileLengthFrames, &size, &frames) == noErr && frames > 0)
        *seconds = frames / source.mSampleRate;
    memset(&client, 0, sizeof client);
    client.mSampleRate = 16000;
    client.mFormatID = kAudioFormatLinearPCM;
    client.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
#if defined(__BIG_ENDIAN__)
    client.mFormatFlags |= kAudioFormatFlagIsBigEndian;
#endif
    client.mChannelsPerFrame = 1;
    client.mBitsPerChannel = 16;
    client.mFramesPerPacket = 1;
    client.mBytesPerFrame = client.mBytesPerPacket = 2;
    if (ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat, sizeof client, &client) != noErr) {
        ExtAudioFileDispose(file);
        return nil;
    }
    out = [NSMutableData data];
    for (;;) {
        short buffer[16000];
        AudioBufferList list;
        UInt32 want = 16000;
        list.mNumberBuffers = 1;
        list.mBuffers[0].mNumberChannels = 1;
        list.mBuffers[0].mDataByteSize = sizeof buffer;
        list.mBuffers[0].mData = buffer;
        if (ExtAudioFileRead(file, &want, &list) != noErr || want == 0)
            break;
        [out appendBytes:buffer length:want * 2];
        if ([out length] / 2 >= maxFrames)
            break;
    }
    ExtAudioFileDispose(file);
    if ([out length] / 2 < maxFrames)
        *seconds = [out length] / 32000.0;   /* all of it was read: this is the real length (some files report a wrong one) */
    return [out length] ? out : nil;
}

/* The words in an audio file (nil with *why set when it could not be done). *seconds is its length. */
static NSString *transcribeFile(NSString *path, double *seconds, NSString **why)
{
    unsigned limitFrames = 30 * 60 * 16000;
    NSData *pcm = pcmOfFile(path, seconds, limitFrames + 16000);
    const unsigned char *b;
    unsigned long pcmLength, i;
    NSMutableString *out = [NSMutableString string];
    Class speech = NSClassFromString(@"TBSpeech");
    if (!pcm) {
        *why = @"This Mac could not read the sound in this file.";
        return nil;
    }
    b = [pcm bytes];
    pcmLength = [pcm length];
    if (pcmLength < 3200) {
        *why = @"There is no sound in this file.";
        return nil;
    }
    {
        /* CoreAudio gives native-endian samples; a WAV holds little-endian ones */
#if defined(__BIG_ENDIAN__)
        NSMutableData *swapped = [NSMutableData dataWithData:pcm];
        unsigned char *w = [swapped mutableBytes];
        for (i = 0; i + 1 < pcmLength; i += 2) {
            unsigned char t = w[i];
            w[i] = w[i + 1];
            w[i + 1] = t;
        }
        pcm = swapped;
        b = [pcm bytes];
#endif
    }
    if (getenv("TB_AUDIO_DECODE_ONLY"))   /* for trying the decoding on a Mac without sending anything */
        return [NSString stringWithFormat:@"(decoded %lu samples, first %d %d %d)\n", pcmLength / 2, ((short *)[pcm bytes])[100], ((short *)[pcm bytes])[2000], ((short *)[pcm bytes])[4000]];
    if (!speech) {
        *why = @"Transcription is not available in this program.";
        return nil;
    }
    {
        unsigned long chunk = 180 * 32000, limit = 30 * 60 * 32000;
        unsigned long end = pcmLength < limit ? pcmLength : limit;
        for (i = 0; i < end; i += chunk) {
            unsigned long part = end - i < chunk ? end - i : chunk;
            int status = 0;
            NSString *problem = nil, *words;
            if (part < 6400)
                break;   /* under a fifth of a second left */
            words = [speech transcribe:wavChunk(b + i, (unsigned)part) language:@"" status:&status problem:&problem];
            if (!words) {
                if (![out length]) {
                    *why = problem ? problem : @"The speech could not be transcribed.";
                    return nil;
                }
                [out appendFormat:@"\n[%@] (this part could not be transcribed: %@)\n", clockText(i / 32000.0), problem];
                continue;
            }
            [out appendFormat:@"[%@] %@\n\n", clockText(i / 32000.0), words];
        }
        if (pcmLength > limit)
            [out appendFormat:@"(Only the first 30 minutes were transcribed.)\n"];
    }
    return out;
}

#if TB_INLINE_VIDEO
/* QuickTime, asked on the main thread (QTKit wants it): the length, size and up to four pictures (TIFF) of a video file */
@interface TBMoviePeek : NSObject
+ (NSDictionary *)peek:(NSString *)path;
+ (void)peekOnMain:(NSMutableDictionary *)job;
@end

@implementation TBMoviePeek
+ (void)peekOnMain:(NSMutableDictionary *)job
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSError *error = nil;
    QTMovie *movie = [QTMovie movieWithFile:[job objectForKey:@"path"] error:&error];
    if (movie) {
        QTTime duration = [movie duration];
        double seconds = duration.timeScale ? (double)duration.timeValue / duration.timeScale : 0;
        NSSize size = [[movie attributeForKey:QTMovieNaturalSizeAttribute] sizeValue];
        NSMutableArray *frames = [NSMutableArray array];
        int i;
        for (i = 0; i < 4 && size.width > 0; i++) {
            double t = seconds * (0.04 + 0.9 * i / 3.0);
            NSImage *image = nil;
            @try {
                image = [movie frameImageAtTime:QTMakeTime((long long)(t * duration.timeScale), duration.timeScale)];
            } @catch (NSException *e) {
                image = nil;
            }
            if (image && [image TIFFRepresentation])
                [frames addObject:[image TIFFRepresentation]];
        }
        [job setObject:[NSNumber numberWithDouble:seconds] forKey:@"seconds"];
        [job setObject:[NSNumber numberWithFloat:size.width] forKey:@"width"];
        [job setObject:[NSNumber numberWithFloat:size.height] forKey:@"height"];
        [job setObject:frames forKey:@"frames"];
    }
    [pool release];
}

+ (NSDictionary *)peek:(NSString *)path
{
    NSMutableDictionary *job = [NSMutableDictionary dictionaryWithObject:path forKey:@"path"];
    if (pthread_main_np())
        [self peekOnMain:job];
    else if (NSClassFromString(@"NSApplication") && [NSApp isRunning])
        [self performSelectorOnMainThread:@selector(peekOnMain:) withObject:job waitUntilDone:YES];
    else
        return nil;   /* no main thread to ask (a Quick Look generator): no pictures */
    return [job objectForKey:@"frames"] ? job : nil;
}
@end
#endif

static NSDictionary *mediaReply(NSString *name, NSData *data, NSString *ext)
{
    static unsigned counter = 0;
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"tb-media-%u-%u", (unsigned)getpid(), ++counter]];
    NSString *path = [dir stringByAppendingPathComponent:[@"sound." stringByAppendingString:ext]];
    BOOL video = [videoTypes() containsObject:ext];
    NSMutableString *text = [NSMutableString string];
    NSMutableArray *images = [NSMutableArray array];
    NSString *why = nil, *words = nil, *note;
    double seconds = 0;
    [[NSFileManager defaultManager] createDirectoryAtPath:dir attributes:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:0700] forKey:NSFilePosixPermissions]];
    if (![data writeToFile:path atomically:NO]) {
        [[NSFileManager defaultManager] removeFileAtPath:dir handler:nil];
        fail(@"The file could not be read.");
    }
#if TB_INLINE_VIDEO
    if (video && TBInlineVideoAvailable()) {
        NSDictionary *peek = nil;
        @try {
            peek = [TBMoviePeek peek:path];
        } @catch (NSException *e) {
            peek = nil;   /* QuickTime cannot open a window here (no one is logged in): the sound alone */
        }
        if (peek) {
            NSArray *frames = [peek objectForKey:@"frames"];
            unsigned i;
            seconds = [[peek objectForKey:@"seconds"] doubleValue];
            [text appendFormat:@"Video %@: %@, %.0f x %.0f.\n\n", name, clockText(seconds), [[peek objectForKey:@"width"] doubleValue], [[peek objectForKey:@"height"] doubleValue]];
            for (i = 0; i < [frames count]; i++) {
                NSData *jpeg = jpegFrom([frames objectAtIndex:i], 1280);
                if (jpeg)
                    [images addObject:jpeg];
            }
        }
    }
#endif
    words = transcribeFile(path, &seconds, &why);
    [[NSFileManager defaultManager] removeFileAtPath:dir handler:nil];
    if (video && ![text length])
        [text appendFormat:@"Video %@: %@.\n\n", name, seconds > 0 ? clockText(seconds) : @"length unknown"];
    if (!video)
        [text appendFormat:@"Audio %@: %@.\n\n", name, seconds > 0 ? clockText(seconds) : @"length unknown"];
    if (words) {
        [text appendString:@"Transcript:\n\n"];
        [text appendString:words];
        note = video ? @"The pictures are four moments of the video; the words were transcribed from its sound." : @"The words were transcribed from this recording by a speech-to-text service.";
    } else {
        if (video && [images count])
            [text appendFormat:@"(The sound was not transcribed: %@)\n", why];
        else
            fail(@"%@", why ? why : @"This file could not be read.");
        note = @"The pictures are four moments of the video; its sound could not be transcribed.";
    }
    return [NSDictionary dictionaryWithObjectsAndKeys:text, @"text", images, @"images", note, @"note", nil];
}

@implementation TBExtract

+ (BOOL)handles:(NSString *)name
{
    NSString *ext = [[name pathExtension] lowercaseString];
    return [types(0) containsObject:ext] || [types(1) containsObject:ext] || [types(2) containsObject:ext] || [[NSArray arrayWithObjects:@"odt", @"ods", @"odp", nil] containsObject:ext];
}

+ (NSDictionary *)extractName:(NSString *)name data:(NSData *)data
{
    NSDictionary *result = nil;
    {
        NSString *ext = [[name pathExtension] lowercaseString];
        if ([audioTypes() containsObject:ext] || [videoTypes() containsObject:ext])
            return mediaReply(name, data, ext);   /* minutes of network and decoding must not hold up the others */
    }
    pthread_mutex_lock(&gate);
    NS_DURING
        result = [self convert:name data:data];
    NS_HANDLER
        pthread_mutex_unlock(&gate);
        [localException raise];
    NS_ENDHANDLER
    pthread_mutex_unlock(&gate);
    return result;
}

+ (NSDictionary *)reply:(NSString *)text images:(NSArray *)images note:(NSString *)note
{
    return [NSDictionary dictionaryWithObjectsAndKeys:text, @"text", images, @"images", note, @"note", nil];
}

+ (NSDictionary *)convert:(NSString *)name data:(NSData *)data
{
    NSString *ext = [[name pathExtension] lowercaseString];
    NSString *text = @"", *note = @"";
    NSMutableArray *images = [NSMutableArray array];
    TBZip *zip;
    BOOL tables = NO;
    if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) {
        /* Phone photos are stored sideways with a rotation tag the old Macs ignore. */
        NSData *jpeg;
        if (orientationOf(data) == 1)
            return [self reply:@"" images:[NSArray arrayWithObject:data] note:@""];
        jpeg = jpegFrom(data, 2400);
        if (!jpeg)
            fail(@"This picture could not be turned upright.");
        return [self reply:@"" images:[NSArray arrayWithObject:jpeg] note:@"Turned upright."];
    }
    /* Animated GIF and WebP: up to four frames, so the model sees how it changes */
    if ([ext isEqualToString:@"gif"] || isWebP(data)) {
        NSMutableArray *frames = [NSMutableArray array];
        int total = 0;
        if (isWebP(data)) {
            WebPBitstreamFeatures features;
            if (WebPGetFeatures([data bytes], [data length], &features) == VP8_STATUS_OK && features.has_animation) {
                NSArray *shots = jpegFramesFromAnimatedWebP(data, 1600, &total);
                if (!shots)
                    fail(@"This animated WebP picture could not be read.");
                [frames addObjectsFromArray:shots];
            }
        } else {
            total = frameCountOf(data);
            if (total > 1) {
                NSArray *wanted = pickFrames(total);
                unsigned f;
                for (f = 0; f < [wanted count]; f++) {
                    NSData *jpeg = jpegFromFrame(data, 1600, [[wanted objectAtIndex:f] intValue]);
                    if (jpeg)
                        [frames addObject:jpeg];
                }
            }
        }
        if ([frames count] > 1 || total > 1)
            return [self reply:@"" images:frames note:[NSString stringWithFormat:@"An animated %@ with %d frames; %u of them are shown, in order.", [ext uppercaseString], total, (unsigned)[frames count]]];
    }
    if ([ext isEqualToString:@"jxl"] || isJXL(data)) {
        int total = 0, looked = 0;
        NSArray *frames = jpegFramesFromJXL(data, 2400, &total, &looked);
        if (!frames)
            fail(@"This JPEG XL picture could not be read.");
        if (total > 1)
            return [self reply:@"" images:frames note:[NSString stringWithFormat:@"An animated JPEG XL picture with %d frames; %u of %@%d are shown, in order. Any transparent parts are shown white.", total, (unsigned)[frames count], looked < total ? @"its first " : @"", looked]];
        return [self reply:@"" images:frames note:@"Converted from JPEG XL to JPEG."];
    }
    if ([types(0) containsObject:ext]) {
        NSData *jpeg = jpegFrom(data, 2400);
        if (!jpeg && [TBHEIC looksLikeHEIF:data]) {
            /* ImageIO before 10.13 cannot read HEIC: the built-in reader and libde265 do. */
            NSString *problem = nil;
            jpeg = [TBHEIC jpegFromData:data longest:2400 problem:&problem];
            if (!jpeg)
                fail(@"%@", problem ? problem : @"This HEIC picture could not be converted.");
        }
        if (!jpeg)
            fail(@"This Mac cannot convert %@ pictures.", [ext uppercaseString]);
        return [self reply:@"" images:[NSArray arrayWithObject:jpeg] note:[NSString stringWithFormat:@"Converted from %@ to JPEG.", [ext uppercaseString]]];
    }
    if ([ext isEqualToString:@"doc"] || [ext isEqualToString:@"xls"] || [ext isEqualToString:@"ppt"]) {
        text = TBLegacyOfficeText(ext, data);
        if ([text length] > MAX_TEXT) {
            text = [text substringToIndex:MAX_TEXT];
            note = @"Only the first part of the text is included.";
        }
        if (![TBTrim(text) length])
            fail(@"No text could be found in this file.");
        return [self reply:text images:images note:[NSString stringWithFormat:@"Text was read from this old-format %@ file; layout, pictures and formatting are not included.", [ext uppercaseString]]];
    }
    zip = [TBZip zipWithData:data];
    if (!zip) {
        const unsigned char *head = [data bytes];
        if ([data length] > 4 && head[0] == 'P' && head[1] == 'K')
            fail(@"This file looks cut short, as if its copy or download did not finish. Copy it again.");
        fail(@"This file is not in a form the converter can read. Save it again, or export it as PDF or text.");
    }
    if ([ext isEqualToString:@"zip"])
        return [self reply:zipListing(zip) images:[NSArray array] note:@"A list of what is in this archive; nothing was unpacked."];
    if ([zip totalSize] > MAX_ALL)
        fail(@"This file unpacks to more than 400 MB, which the converter will not read.");
    if ([ext isEqualToString:@"epub"]) {
        NSData *cover = nil;
        NSMutableDictionary *book;
        text = epubText(zip, &cover);
        if (cover) {
            NSData *jpeg = jpegFrom(cover, 1200);
            if (jpeg)
                [images addObject:jpeg];
        }
        if ([text length] > MAX_TEXT)
            text = [text substringToIndex:MAX_TEXT];
        book = [NSMutableDictionary dictionaryWithDictionary:[self reply:text images:images note:@"The title, author and text of the chapters of this book, in reading order; pictures and layout are not included. The picture is the cover."]];
        [book setObject:[NSNumber numberWithBool:YES] forKey:@"textFirst"];
        return book;
    } else if ([ext isEqualToString:@"docx"])
        text = docxText(zip);
    else if ([ext isEqualToString:@"pptx"]) {
        text = pptxText(zip);
        if ([zip has:@"docProps/thumbnail.jpeg"])
            [images addObject:[zip dataFor:@"docProps/thumbnail.jpeg"]];
    } else if ([ext isEqualToString:@"xlsx"])
        text = xlsxText(zip);
    else if ([[NSArray arrayWithObjects:@"odt", @"ods", @"odp", nil] containsObject:ext])
        text = odfText(zip);
    else if ([types(2) containsObject:ext]) {
        NSArray *previews = [NSArray arrayWithObjects:@"preview.jpg", @"quicklook/thumbnail.jpg", @"preview-web.jpg", @"docprops/thumbnail.jpeg", nil];
        NSEnumerator *each = [[zip names] objectEnumerator];
        NSString *entry;
        text = iworkOldText(zip);
        if (![text length] && [ext isEqualToString:@"numbers"]) {
            text = numbersTables(zip);
            if ([text length])
                tables = YES;
        }
        if (![text length])
            text = iworkStrings(zip);
        while ((entry = [each nextObject])) {
            if ([previews containsObject:[entry lowercaseString]] && ![images count]) {
                [images addObject:[zip dataFor:entry]];
            }
        }
        note = tables ? @"Cell values were read from the tables in this Numbers file; formulas, number formats and charts are not included. The picture is the first sheet."
            : [NSString stringWithFormat:@"Text was read from inside the %@ file, so slide order may differ, tables and layout are lost, and some text may be missing. The picture is the first page or slide.", ext];
    } else
        fail(@"Files of this type cannot be converted.");
    if ([text length] > MAX_TEXT) {
        text = [text substringToIndex:MAX_TEXT];
        note = [note stringByAppendingString:@" Only the first part of the text is included."];
    }
    if (![TBTrim(text) length] && ![images count])
        fail(@"No text could be found in this file.");
    return [self reply:text images:images note:TBTrim(note)];
}

@end

int TBConvertCommand(const char *file, const char *outdir)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *path = [NSString stringWithUTF8String:file], *out = [NSString stringWithUTF8String:outdir];
    NSData *data = [NSData dataWithContentsOfFile:path];
    int code = 0;
    @try {
        NSDictionary *result;
        NSArray *images;
        unsigned i;
        if (!data)
            [NSException raise:TBExtractError format:@"The file could not be read."];
        result = [TBExtract extractName:[path lastPathComponent] data:data];
        images = [result objectForKey:@"images"];
        [[result objectForKey:@"text"] writeToFile:[out stringByAppendingPathComponent:@"text.txt"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
        for (i = 0; i < [images count] && i < 8; i++)
            [[images objectAtIndex:i] writeToFile:[out stringByAppendingPathComponent:[NSString stringWithFormat:@"image-%u.jpg", i + 1]] atomically:NO];
        printf("NOTE: %s\nIMAGES: %u\n", [[result objectForKey:@"note"] UTF8String], (unsigned)[images count]);
    } @catch (NSException *e) {
        printf("ERROR: %s\n", [[e reason] UTF8String]);
        code = 1;
    }
    [pool release];
    return code;
}
