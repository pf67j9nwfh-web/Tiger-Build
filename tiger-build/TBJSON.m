#import "TBJSON.h"

@implementation TBJSONRaw
+ (TBJSONRaw *)rawWithData:(NSData *)bytes
{
    TBJSONRaw *raw = [[[TBJSONRaw alloc] init] autorelease];
    raw->data = [bytes retain];
    return raw;
}
- (NSData *)data { return data; }
- (void)dealloc
{
    [data release];
    [super dealloc];
}
@end

/* ---- reading ---- */

typedef struct {
    const unsigned char *bytes;
    unsigned long length;
    unsigned long at;
    int depth;
    const char *problem;
} Reader;

static void skipSpace(Reader *r)
{
    while (r->at < r->length) {
        unsigned char c = r->bytes[r->at];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r')
            r->at++;
        else
            break;
    }
}

static id readValue(Reader *r);

static int hexValue(unsigned char c)
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return -1;
}

static int readHex4(Reader *r, unsigned *out)
{
    unsigned v = 0;
    int i;
    if (r->at + 4 > r->length)
        return 0;
    for (i = 0; i < 4; i++) {
        int d = hexValue(r->bytes[r->at + i]);
        if (d < 0)
            return 0;
        v = v * 16 + d;
    }
    r->at += 4;
    *out = v;
    return 1;
}

static NSString *readString(Reader *r)
{
    unsigned long start = ++r->at;
    BOOL plain = YES;
    unsigned long i;
    NSString *result;
    /* Most strings have no escapes: make them straight from the bytes. */
    for (i = start; i < r->length; i++) {
        unsigned char c = r->bytes[i];
        if (c == '"')
            break;
        if (c == '\\') {
            plain = NO;
            break;
        }
        if (c < 0x20) {
            r->problem = "a control character in a string";
            return nil;
        }
    }
    if (plain) {
        if (i >= r->length) {
            r->problem = "a string that does not end";
            return nil;
        }
        result = [[NSString alloc] initWithBytes:r->bytes + start length:i - start encoding:NSUTF8StringEncoding];
        r->at = i + 1;
        if (!result) {
            r->problem = "text that is not UTF-8";
            return nil;
        }
        return [result autorelease];
    }
    {
        NSMutableData *units = [NSMutableData dataWithCapacity:(i - start) * 2 + 32];
        unsigned long pos = start;
        while (pos < r->length) {
            unsigned char c = r->bytes[pos];
            unichar u;
            if (c == '"') {
                r->at = pos + 1;
                result = [[NSString alloc] initWithCharacters:[units bytes] length:[units length] / sizeof(unichar)];
                return [result autorelease];
            }
            if (c == '\\') {
                if (pos + 1 >= r->length)
                    break;
                c = r->bytes[pos + 1];
                pos += 2;
                switch (c) {
                    case '"': u = '"'; break;
                    case '\\': u = '\\'; break;
                    case '/': u = '/'; break;
                    case 'b': u = 8; break;
                    case 'f': u = 12; break;
                    case 'n': u = 10; break;
                    case 'r': u = 13; break;
                    case 't': u = 9; break;
                    case 'u': {
                        unsigned code;
                        r->at = pos;
                        if (!readHex4(r, &code)) {
                            r->problem = "a bad \\u escape";
                            return nil;
                        }
                        pos = r->at;
                        u = (unichar)code;
                        break;
                    }
                    default:
                        r->problem = "a bad escape in a string";
                        return nil;
                }
                [units appendBytes:&u length:sizeof(u)];
            } else if (c < 0x20) {
                r->problem = "a control character in a string";
                return nil;
            } else {
                /* A run of ordinary UTF-8 up to the next quote or backslash. */
                unsigned long runEnd = pos;
                NSString *run;
                while (runEnd < r->length && r->bytes[runEnd] != '"' && r->bytes[runEnd] != '\\' && r->bytes[runEnd] >= 0x20)
                    runEnd++;
                run = [[NSString alloc] initWithBytes:r->bytes + pos length:runEnd - pos encoding:NSUTF8StringEncoding];
                if (!run) {
                    r->problem = "text that is not UTF-8";
                    return nil;
                }
                {
                    unsigned n = [run length];
                    unichar *chars = malloc(n * sizeof(unichar) + 1);
                    [run getCharacters:chars];
                    [units appendBytes:chars length:n * sizeof(unichar)];
                    free(chars);
                }
                [run release];
                pos = runEnd;
            }
        }
    }
    r->problem = "a string that does not end";
    return nil;
}

static id readNumber(Reader *r)
{
    unsigned long start = r->at;
    BOOL real = NO;
    char text[64];
    unsigned long n;
    if (r->at < r->length && r->bytes[r->at] == '-')
        r->at++;
    while (r->at < r->length) {
        unsigned char c = r->bytes[r->at];
        if (c >= '0' && c <= '9') {
            r->at++;
        } else if (c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-') {
            real = YES;
            r->at++;
        } else {
            break;
        }
    }
    n = r->at - start;
    if (n == 0 || n >= sizeof(text)) {
        r->problem = "a number that cannot be read";
        return nil;
    }
    memcpy(text, r->bytes + start, n);
    text[n] = 0;
    if (!real) {
        long long v = strtoll(text, NULL, 10);
        if (n < 19)
            return [NSNumber numberWithLongLong:v];
    }
    return [NSNumber numberWithDouble:strtod(text, NULL)];
}

static id readValue(Reader *r)
{
    id value;
    skipSpace(r);
    if (r->at >= r->length) {
        r->problem = "the text ended too soon";
        return nil;
    }
    if (++r->depth > 200) {
        r->problem = "values nested too deeply";
        return nil;
    }
    switch (r->bytes[r->at]) {
    case '{': {
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        r->at++;
        skipSpace(r);
        if (r->at < r->length && r->bytes[r->at] == '}') {
            r->at++;
            r->depth--;
            return dict;
        }
        for (;;) {
            NSString *key;
            id item;
            skipSpace(r);
            if (r->at >= r->length || r->bytes[r->at] != '"') {
                r->problem = "an object key that is not a string";
                return nil;
            }
            key = readString(r);
            if (!key)
                return nil;
            skipSpace(r);
            if (r->at >= r->length || r->bytes[r->at] != ':') {
                r->problem = "a missing colon";
                return nil;
            }
            r->at++;
            item = readValue(r);
            if (!item)
                return nil;
            [dict setObject:item forKey:key];
            skipSpace(r);
            if (r->at < r->length && r->bytes[r->at] == ',') {
                r->at++;
                continue;
            }
            if (r->at < r->length && r->bytes[r->at] == '}') {
                r->at++;
                break;
            }
            r->problem = "a missing comma or brace";
            return nil;
        }
        value = dict;
        break;
    }
    case '[': {
        NSMutableArray *list = [NSMutableArray array];
        r->at++;
        skipSpace(r);
        if (r->at < r->length && r->bytes[r->at] == ']') {
            r->at++;
            r->depth--;
            return list;
        }
        for (;;) {
            id item = readValue(r);
            if (!item)
                return nil;
            [list addObject:item];
            skipSpace(r);
            if (r->at < r->length && r->bytes[r->at] == ',') {
                r->at++;
                continue;
            }
            if (r->at < r->length && r->bytes[r->at] == ']') {
                r->at++;
                break;
            }
            r->problem = "a missing comma or bracket";
            return nil;
        }
        value = list;
        break;
    }
    case '"':
        value = readString(r);
        break;
    case 't':
        if (r->at + 4 <= r->length && memcmp(r->bytes + r->at, "true", 4) == 0) {
            r->at += 4;
            value = [NSNumber numberWithBool:YES];
        } else {
            r->problem = "an unknown word";
            return nil;
        }
        break;
    case 'f':
        if (r->at + 5 <= r->length && memcmp(r->bytes + r->at, "false", 5) == 0) {
            r->at += 5;
            value = [NSNumber numberWithBool:NO];
        } else {
            r->problem = "an unknown word";
            return nil;
        }
        break;
    case 'n':
        if (r->at + 4 <= r->length && memcmp(r->bytes + r->at, "null", 4) == 0) {
            r->at += 4;
            value = [NSNull null];
        } else {
            r->problem = "an unknown word";
            return nil;
        }
        break;
    default:
        value = readNumber(r);
        break;
    }
    r->depth--;
    return value;
}

id TBJSONParse(NSData *data, NSString **error)
{
    Reader r;
    id value;
    const unsigned char *bytes = [data bytes];
    unsigned long length = [data length];
    if (length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
        bytes += 3;
        length -= 3;
    }
    r.bytes = bytes;
    r.length = length;
    r.at = 0;
    r.depth = 0;
    r.problem = NULL;
    value = readValue(&r);
    if (value) {
        skipSpace(&r);
        if (r.at < r.length) {
            r.problem = "extra text after the JSON";
            value = nil;
        }
    }
    if (!value && error)
        *error = [NSString stringWithFormat:@"Not valid JSON: %s at byte %lu.", r.problem ? r.problem : "an error", r.at];
    return value;
}

id TBJSONParseString(NSString *text, NSString **error)
{
    return TBJSONParse([text dataUsingEncoding:NSUTF8StringEncoding], error);
}

/* ---- writing ---- */

static void put(NSMutableData *out, const char *text)
{
    [out appendBytes:text length:strlen(text)];
}

static void putString(NSMutableData *out, NSString *s)
{
    unsigned n = [s length];
    unichar *chars = malloc(n * sizeof(unichar) + 1);
    unsigned i, runStart = 0;
    [s getCharacters:chars];
    [out appendBytes:"\"" length:1];
    /* Plain stretches go out as UTF-8 in one piece; only the characters that need it are escaped. */
    for (i = 0; i <= n; i++) {
        unichar c = i < n ? chars[i] : 0;
        char escape[8];
        BOOL special = i == n || c == '"' || c == '\\' || c < 0x20 || c == 0x2028 || c == 0x2029;
        if (!special)
            continue;
        if (i > runStart) {
            NSString *run = [[NSString alloc] initWithCharacters:chars + runStart length:i - runStart];
            NSData *utf8 = [run dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
            [out appendData:utf8];
            [run release];
        }
        runStart = i + 1;
        if (i == n)
            break;
        switch (c) {
            case '"': put(out, "\\\""); break;
            case '\\': put(out, "\\\\"); break;
            case 10: put(out, "\\n"); break;
            case 13: put(out, "\\r"); break;
            case 9: put(out, "\\t"); break;
            default:
                snprintf(escape, sizeof(escape), "\\u%04x", c);
                put(out, escape);
        }
    }
    [out appendBytes:"\"" length:1];
    free(chars);
}

static void writeValue(NSMutableData *out, id object)
{
    if ([object isKindOfClass:[NSString class]]) {
        putString(out, object);
    } else if ([object isKindOfClass:[NSNumber class]]) {
        char text[40];
        if ((CFBooleanRef)object == kCFBooleanTrue) {
            put(out, "true");
        } else if ((CFBooleanRef)object == kCFBooleanFalse) {
            put(out, "false");
        } else if (CFNumberIsFloatType((CFNumberRef)object)) {
            snprintf(text, sizeof(text), "%.15g", [object doubleValue]);
            put(out, text);
        } else {
            snprintf(text, sizeof(text), "%lld", [object longLongValue]);
            put(out, text);
        }
    } else if ([object isKindOfClass:[NSDictionary class]]) {
        NSEnumerator *keys = [object keyEnumerator];
        id key;
        BOOL first = YES;
        put(out, "{");
        while ((key = [keys nextObject])) {
            if (!first)
                put(out, ",");
            first = NO;
            putString(out, [key description]);
            put(out, ":");
            writeValue(out, [object objectForKey:key]);
        }
        put(out, "}");
    } else if ([object isKindOfClass:[NSArray class]]) {
        unsigned i;
        put(out, "[");
        for (i = 0; i < [object count]; i++) {
            if (i)
                put(out, ",");
            writeValue(out, [object objectAtIndex:i]);
        }
        put(out, "]");
    } else if ([object isKindOfClass:[TBJSONRaw class]]) {
        [out appendData:[object data]];
    } else {
        put(out, "null");
    }
}

NSData *TBJSONData(id object)
{
    NSMutableData *out = [NSMutableData dataWithCapacity:256];
    writeValue(out, object);
    return out;
}

NSString *TBJSONString(id object)
{
    return [[[NSString alloc] initWithData:TBJSONData(object) encoding:NSUTF8StringEncoding] autorelease];
}
