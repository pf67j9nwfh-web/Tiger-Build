#import "TBExtract.h"
#import "TBEngine.h"
#import "TBCompat.h"
#import <zlib.h>
#import <ApplicationServices/ApplicationServices.h>
#import <pthread.h>
#import "webp/decode.h"
#import "TBHEIC.h"

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
    unsigned long offset, packed, size, start;
    unsigned method;
    if (!entry)
        fail(@"%@ is missing from the file.", name);
    offset = [[entry objectAtIndex:0] unsignedLongValue];
    packed = [[entry objectAtIndex:1] unsignedLongValue];
    size = [[entry objectAtIndex:2] unsignedLongValue];
    method = [[entry objectAtIndex:3] unsignedIntValue];
    if (size > MAX_PART)
        fail(@"A part of this file is too large to read (%@).", name);
    if (offset + 30 > [data length] || le32(p + offset) != 0x04034b50)
        fail(@"This file is damaged.");
    start = offset + 30 + le16(p + offset + 26) + le16(p + offset + 28);
    if (start + packed > [data length])
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

/* shared strings, workbook sheets, relationships and cells of a spreadsheet */
@interface TBCells : NSObject TB_PROTOCOLS(NSXMLParserDelegate)
{
    NSMutableArray *strings, *sheets, *rows, *cells;
    NSMutableDictionary *targets;
    NSMutableString *value, *inline_;
    NSString *kind, *reference;
    BOOL inSI, inV, inT;
    int inIS;
    NSMutableString *item;
}
+ (NSArray *)sharedStrings:(NSData *)xml;
+ (NSArray *)sheetNames:(NSData *)xml; /* [{name, id}] */
+ (NSDictionary *)relationships:(NSData *)xml;
+ (NSArray *)rowsOf:(NSData *)xml shared:(NSArray *)shared;
@end

@implementation TBCells

+ (TBCells *)run:(NSData *)xml
{
    TBCells *me = [[[TBCells alloc] init] autorelease];
    NSXMLParser *parser = [[[NSXMLParser alloc] initWithData:checkedXML(xml)] autorelease];
    me->strings = [NSMutableArray array];
    me->sheets = [NSMutableArray array];
    me->rows = [NSMutableArray array];
    me->targets = [NSMutableDictionary dictionary];
    me->value = [NSMutableString string];
    me->inline_ = [NSMutableString string];
    me->item = [NSMutableString string];
    [parser setDelegate:me];
    [parser parse];
    return me;
}

+ (NSArray *)sharedStrings:(NSData *)xml { return [self run:xml]->strings; }
+ (NSArray *)sheetNames:(NSData *)xml { return [self run:xml]->sheets; }
+ (NSDictionary *)relationships:(NSData *)xml { return [self run:xml]->targets; }
+ (NSArray *)rowsOf:(NSData *)xml shared:(NSArray *)shared
{
    TBCells *me = [[[TBCells alloc] init] autorelease];
    NSXMLParser *parser = [[[NSXMLParser alloc] initWithData:checkedXML(xml)] autorelease];
    me->strings = [NSMutableArray arrayWithArray:shared];
    me->rows = [NSMutableArray array];
    me->value = [NSMutableString string];
    me->inline_ = [NSMutableString string];
    me->item = [NSMutableString string];
    [parser setDelegate:me];
    [parser parse];
    return me->rows;
}

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
    } else if ([name isEqualToString:@"row"]) {
        cells = [NSMutableArray array];
    } else if ([name isEqualToString:@"c"]) {
        kind = [a objectForKey:@"t"];
        reference = [a objectForKey:@"r"];
        [value setString:@""];
        [inline_ setString:@""];
    } else if ([name isEqualToString:@"v"]) {
        inV = YES;
    } else if ([name isEqualToString:@"is"]) {
        inIS++;
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
    } else if ([name isEqualToString:@"v"]) {
        inV = NO;
    } else if ([name isEqualToString:@"t"]) {
        inT = NO;
    } else if ([name isEqualToString:@"is"]) {
        inIS--;
    } else if ([name isEqualToString:@"c"] && cells) {
        NSString *text = @"";
        int column = columnOf(reference);
        if ([kind isEqualToString:@"s"] && [value length] && [value intValue] >= 0 && (unsigned)[value intValue] < [strings count] && [[NSString stringWithFormat:@"%d", [value intValue]] isEqualToString:value])
            text = [strings objectAtIndex:[value intValue]];
        else if ([kind isEqualToString:@"inlineStr"])
            text = [[inline_ copy] autorelease];
        else if ([value length])
            text = [[value copy] autorelease];
        while ((int)[cells count] < column && column < 16384)
            [cells addObject:@""];
        text = swap(swap(text, @"\t", @" "), @"\n", @" ");
        [cells addObject:text];
    } else if ([name isEqualToString:@"row"] && cells) {
        [rows addObject:cells];
        cells = nil;
    }
}

- (void)parser:(NSXMLParser *)p foundCharacters:(NSString *)string
{
    if (inSI && inT)
        [item appendString:string];
    else if (inIS && inT)
        [inline_ appendString:string];
    else if (inV)
        [value appendString:string];
}

@end

/* ---- pictures ---- */

static BOOL isWebP(NSData *data)
{
    const unsigned char *b = [data bytes];
    return [data length] > 16 && !memcmp(b, "RIFF", 4) && !memcmp(b + 8, "WEBP", 4);
}

/* The JPEG of a decoded RGBA picture, laid on white (a JPEG has no transparency). */
static NSData *jpegFromRGBA(unsigned char *pixels, int width, int height, int stride)
{
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, pixels, (size_t)stride * height, NULL);
    CGImageRef image = CGImageCreate(width, height, 8, 32, stride, space, kCGImageAlphaLast, provider, NULL, false, kCGRenderingIntentDefault);
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space, kCGImageAlphaNoneSkipLast);
    NSMutableData *out = [NSMutableData data];
    NSData *result = nil;
    if (image && context) {
        CGImageRef flat;
        CGContextSetRGBFillColor(context, 1, 1, 1, 1);
        CGContextFillRect(context, CGRectMake(0, 0, width, height));
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
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
        result = jpegFromRGBA(config.output.u.RGBA.rgba, config.output.width, config.output.height, config.output.u.RGBA.stride);
    WebPFreeDecBuffer(&config.output);
    return result;
}

static NSData *jpegFrom(NSData *data, int longest)
{
    if (isWebP(data))
        return jpegFromWebP(data, longest);
    CGImageSourceRef source = CGImageSourceCreateWithData((CFDataRef)data, NULL);
    NSData *result = nil;
    if (source && CGImageSourceGetCount(source) > 0) {
        NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:longest], (id)kCGImageSourceThumbnailMaxPixelSize,
            (id)kCFBooleanTrue, (id)kCGImageSourceCreateThumbnailFromImageAlways, (id)kCFBooleanTrue, (id)kCGImageSourceCreateThumbnailWithTransform, nil];
        CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (CFDictionaryRef)options);
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
        if (!part || ![zip has:part])
            continue;
        [out addObject:[NSString stringWithFormat:@"--- Sheet: %@ ---", [sheet objectForKey:@"name"]]];
        rows = [TBCells rowsOf:[zip dataFor:part] shared:shared];
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
        if ([rows count] > r)
            [out addObject:[NSString stringWithFormat:@"[%u more rows not shown]", (unsigned)([rows count] - r)]];
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
    case 0: return [NSArray arrayWithObjects:@"heic", @"heif", @"webp", @"avif", @"jp2", @"jpg", @"jpeg", @"tif", @"tiff", @"bmp", @"gif", @"png", nil];
    case 1: return [NSArray arrayWithObjects:@"docx", @"pptx", @"xlsx", nil];
    }
    return [NSArray arrayWithObjects:@"pages", @"numbers", @"key", nil];
}

@interface TBExtract (Private)
+ (NSDictionary *)convert:(NSString *)name data:(NSData *)data;
@end

static pthread_mutex_t gate = PTHREAD_MUTEX_INITIALIZER;

@implementation TBExtract

+ (BOOL)handles:(NSString *)name
{
    NSString *ext = [[name pathExtension] lowercaseString];
    return [types(0) containsObject:ext] || [types(1) containsObject:ext] || [types(2) containsObject:ext] || [[NSArray arrayWithObjects:@"odt", @"ods", @"odp", nil] containsObject:ext];
}

+ (NSDictionary *)extractName:(NSString *)name data:(NSData *)data
{
    NSDictionary *result = nil;
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
    zip = [TBZip zipWithData:data];
    if (!zip)
        fail(@"This file is not in a form the converter can read. Save it again, or export it as PDF or text.");
    if ([zip totalSize] > MAX_ALL)
        fail(@"This file unpacks to more than 400 MB, which the converter will not read.");
    if ([ext isEqualToString:@"docx"])
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
        if (![text length])
            text = iworkStrings(zip);
        while ((entry = [each nextObject])) {
            if ([previews containsObject:[entry lowercaseString]] && ![images count]) {
                [images addObject:[zip dataFor:entry]];
            }
        }
        note = [NSString stringWithFormat:@"Text was read from inside the %@ file, so slide order may differ, tables and layout are lost, and some text may be missing. The picture is the first page or slide.", ext];
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
