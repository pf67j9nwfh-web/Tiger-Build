#import "TBOffice.h"
#import "TBExtract.h"
#import "TBEngine.h"

#define MAX_TEXT 300000
#ifndef NSUTF16LittleEndianStringEncoding
#define NSUTF16LittleEndianStringEncoding ((NSStringEncoding)0x94000100)
#endif
#define ENDOFCHAIN 0xFFFFFFFEu

static void fail(NSString *format, ...)
{
    va_list args;
    NSString *text;
    va_start(args, format);
    text = [[[NSString alloc] initWithFormat:format arguments:args] autorelease];
    va_end(args);
    [NSException raise:TBExtractError format:@"%@", text];
}

static unsigned u16(const unsigned char *p) { return p[0] | (p[1] << 8); }
static unsigned u32(const unsigned char *p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((unsigned)p[3] << 24); }

/* ---- the compound file: sectors, the FAT, directory entries and the mini stream ---- */

@interface TBCompound : NSObject {
    NSData *file;
    unsigned sectorSize, miniSize, cutoff, sectors;
    unsigned *fat, fatCount, *miniFat, miniFatCount;
    NSMutableDictionary *entries;    /* name -> {start, size, type} */
    NSData *miniStream;
}
- (id)initWithData:(NSData *)data;
- (NSData *)stream:(NSString *)name;
@end

@implementation TBCompound

- (NSData *)chainFrom:(unsigned)start limit:(unsigned long)limit
{
    NSMutableData *out = [NSMutableData data];
    unsigned sector = start, guard = 0;
    const unsigned char *bytes = [file bytes];
    while (sector != ENDOFCHAIN && sector < sectors && guard++ <= sectors) {
        unsigned long at = (unsigned long)(sector + 1) * sectorSize;
        if (at + sectorSize > [file length])
            break;
        [out appendBytes:bytes + at length:sectorSize];
        if ([out length] >= limit)
            break;
        sector = sector < fatCount ? fat[sector] : ENDOFCHAIN;
    }
    return out;
}

- (id)initWithData:(NSData *)data
{
    const unsigned char *h = [data bytes];
    static const unsigned char magic[8] = {0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1};
    unsigned i, nfat, difatSector, ndifat, dirStart, miniStart, nmini;
    NSMutableData *fatBytes = [NSMutableData data];
    NSData *dir;
    self = [super init];
    if ([data length] < 512 || memcmp(h, magic, 8) != 0) {
        [self release];
        return nil;
    }
    file = [data retain];
    if (u16(h + 0x1E) < 7 || u16(h + 0x1E) > 12 || u16(h + 0x20) > 8) {
        [self release];
        return nil;
    }
    sectorSize = 1u << u16(h + 0x1E);
    miniSize = 1u << u16(h + 0x20);
    nfat = u32(h + 0x2C);
    dirStart = u32(h + 0x30);
    cutoff = u32(h + 0x38);
    miniStart = u32(h + 0x3C);
    nmini = u32(h + 0x40);
    difatSector = u32(h + 0x44);
    ndifat = u32(h + 0x48);
    sectors = ([data length] - sectorSize) / sectorSize + 1;
    {
        /* the FAT sectors: 109 in the header, then more through the DIFAT chain */
        NSMutableArray *list = [NSMutableArray array];
        for (i = 0; i < 109 && i < nfat; i++)
            if (u32(h + 0x4C + i * 4) < sectors)
                [list addObject:[NSNumber numberWithUnsignedInt:u32(h + 0x4C + i * 4)]];
        while (ndifat-- && difatSector < sectors && [list count] < nfat) {
            const unsigned char *s = h + (unsigned long)(difatSector + 1) * sectorSize;
            unsigned per = sectorSize / 4 - 1;
            if ((unsigned long)(difatSector + 2) * sectorSize > [data length])
                break;
            for (i = 0; i < per && [list count] < nfat; i++)
                if (u32(s + i * 4) < sectors)
                    [list addObject:[NSNumber numberWithUnsignedInt:u32(s + i * 4)]];
            difatSector = u32(s + per * 4);
        }
        for (i = 0; i < [list count]; i++) {
            unsigned long at = (unsigned long)([[list objectAtIndex:i] unsignedIntValue] + 1) * sectorSize;
            if (at + sectorSize <= [data length])
                [fatBytes appendBytes:h + at length:sectorSize];
        }
    }
    fatCount = [fatBytes length] / 4;
    fat = malloc(fatCount * 4 + 4);
    for (i = 0; i < fatCount; i++)
        fat[i] = u32((const unsigned char *)[fatBytes bytes] + i * 4);
    dir = [self chainFrom:dirStart limit:64 * 1024 * 1024];
    entries = [[NSMutableDictionary alloc] init];
    for (i = 0; i + 128 <= [dir length]; i += 128) {
        const unsigned char *e = (const unsigned char *)[dir bytes] + i;
        unsigned nameBytes = u16(e + 64), type = e[66];
        NSString *name;
        if (type == 0 || nameBytes < 2 || nameBytes > 64)
            continue;
        name = [[[NSString alloc] initWithBytes:e length:nameBytes - 2 encoding:NSUTF16LittleEndianStringEncoding] autorelease];
        if (name && ![entries objectForKey:name])
            [entries setObject:[NSArray arrayWithObjects:[NSNumber numberWithUnsignedInt:u32(e + 116)], [NSNumber numberWithUnsignedInt:u32(e + 120)], [NSNumber numberWithInt:type], nil] forKey:name];
    }
    {
        NSData *mf = [self chainFrom:miniStart limit:(unsigned long)nmini * sectorSize + 1];
        miniFatCount = [mf length] / 4;
        miniFat = malloc(miniFatCount * 4 + 4);
        for (i = 0; i < miniFatCount; i++)
            miniFat[i] = u32((const unsigned char *)[mf bytes] + i * 4);
    }
    return self;
}

- (void)dealloc
{
    free(fat);
    free(miniFat);
    [file release];
    [entries release];
    [miniStream release];
    [super dealloc];
}

- (NSData *)stream:(NSString *)name
{
    NSArray *e = [entries objectForKey:name];
    unsigned start, size;
    if (!e)
        return nil;
    start = [[e objectAtIndex:0] unsignedIntValue];
    size = [[e objectAtIndex:1] unsignedIntValue];
    if (size >= cutoff) {
        NSData *all = [self chainFrom:start limit:(unsigned long)size];
        return [all length] >= size ? [all subdataWithRange:NSMakeRange(0, size)] : all;
    }
    if (!miniStream) {
        NSArray *root = [entries objectForKey:@"Root Entry"];
        miniStream = [root ? [self chainFrom:[[root objectAtIndex:0] unsignedIntValue] limit:(unsigned long)[[root objectAtIndex:1] unsignedIntValue]] : [NSData data] retain];
    }
    {
        NSMutableData *out = [NSMutableData data];
        unsigned sector = start, guard = 0;
        while (sector != ENDOFCHAIN && sector < miniFatCount && guard++ <= miniFatCount && [out length] < size) {
            unsigned long at = (unsigned long)sector * miniSize;
            if (at + miniSize > [miniStream length])
                break;
            [out appendBytes:(const unsigned char *)[miniStream bytes] + at length:miniSize];
            sector = miniFat[sector];
        }
        return [out length] > size ? [out subdataWithRange:NSMakeRange(0, size)] : out;
    }
}

@end

/* ---- text helpers ---- */

static const unichar cp1252High[32] = {0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F,
    0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178};

static void appendBytes8(NSMutableString *out, const unsigned char *p, unsigned n)
{
    unsigned i;
    for (i = 0; i < n; i++) {
        unichar c = p[i];
        if (c >= 0x80 && c < 0xA0)
            c = cp1252High[c - 0x80];
        [out appendString:[NSString stringWithCharacters:&c length:1]];
    }
}

static void appendUTF16(NSMutableString *out, const unsigned char *p, unsigned n)
{
    unsigned i;
    unichar buffer[256];
    unsigned used = 0;
    for (i = 0; i < n; i++) {
        buffer[used++] = u16(p + i * 2);
        if (used == 256) {
            [out appendString:[NSString stringWithCharacters:buffer length:used]];
            used = 0;
        }
    }
    if (used)
        [out appendString:[NSString stringWithCharacters:buffer length:used]];
}

/* ---- Word ---- */

static NSString *wordClean(NSString *raw)
{
    NSMutableString *out = [NSMutableString string];
    int fieldDepth = 0, hidden = 0;          /* inside a field's code: skip until its result */
    unsigned char inResult[32];
    unsigned i;
    memset(inResult, 0, sizeof inResult);
    for (i = 0; i < [raw length]; i++) {
        unichar c = [raw characterAtIndex:i];
        if (c == 0x13) {
            if (fieldDepth < 31)
                inResult[++fieldDepth] = 0;
            hidden++;
            continue;
        }
        if (c == 0x14 && fieldDepth > 0) {
            if (!inResult[fieldDepth]) {
                inResult[fieldDepth] = 1;
                hidden--;
            }
            continue;
        }
        if (c == 0x15 && fieldDepth > 0) {
            if (!inResult[fieldDepth])
                hidden--;
            fieldDepth--;
            continue;
        }
        if (hidden > 0)
            continue;
        switch (c) {
        case 0x0D: case 0x0B: case 0x0C: [out appendString:@"\n"]; break;
        case 0x07: [out appendString:@"\t"]; break;
        case 0x1E: [out appendString:@"-"]; break;
        case 0x09: [out appendString:@"\t"]; break;
        case 0x0A: break;
        default:
            if (c >= 0x20 && c != 0xFEFF)
                [out appendString:[NSString stringWithCharacters:&c length:1]];
        }
    }
    {
        /* a table row ends with two cell marks: drop tabs left at the ends of lines */
        NSArray *lines = [out componentsSeparatedByString:@"\n"];
        NSMutableArray *tidy = [NSMutableArray array];
        for (i = 0; i < [lines count]; i++) {
            NSMutableString *line = [NSMutableString stringWithString:[lines objectAtIndex:i]];
            while ([line hasSuffix:@"\t"])
                [line deleteCharactersInRange:NSMakeRange([line length] - 1, 1)];
            [tidy addObject:line];
        }
        {
            NSMutableString *joined = [NSMutableString stringWithString:[tidy componentsJoinedByString:@"\n"]];
            while ([joined replaceOccurrencesOfString:@"\n\n\n" withString:@"\n\n" options:0 range:NSMakeRange(0, [joined length])] > 0)
                ;
            return TBTrim(joined);
        }
    }
}

static NSString *docText(TBCompound *cfb)
{
    NSData *word = [cfb stream:@"WordDocument"], *table;
    const unsigned char *w, *t;
    unsigned flags, csw, cslw, cb, lcbOffset, ccpText, ccpFtn, fcClx, lcbClx, p, n, i;
    NSMutableString *raw = [NSMutableString string];
    unsigned long total, wanted;
    if ([word length] < 0x200)
        fail(@"This Word file could not be read.");
    w = [word bytes];
    if (u16(w) != 0xA5EC)
        fail(@"This Word file is too old: only Word 97 and later documents (.doc) can be read. Save it as .docx, PDF or text.");
    if (u16(w + 2) < 0xC1)
        fail(@"This Word file is from Word 95 or older, which cannot be read. Save it as .docx, PDF or text.");
    flags = u16(w + 0x0A);
    if (flags & 0x0100)
        fail(@"This Word file is password protected. Save a copy without the password.");
    table = [cfb stream:(flags & 0x0200) ? @"1Table" : @"0Table"];
    if (![table length])
        fail(@"This Word file is missing its text index and cannot be read.");
    t = [table bytes];
    csw = u16(w + 0x20);
    p = 0x22 + csw * 2;
    cslw = u16(w + p);
    p += 2;
    if (p + cslw * 4 + 2 > [word length] || cslw < 5)
        fail(@"This Word file could not be read.");
    ccpText = u32(w + p + 12);
    ccpFtn = u32(w + p + 16);
    p += cslw * 4;
    cb = u16(w + p);
    p += 2;
    lcbOffset = p + 33 * 8;
    if (cb < 34 || lcbOffset + 8 > [word length])
        fail(@"This Word file could not be read.");
    fcClx = u32(w + lcbOffset);
    lcbClx = u32(w + lcbOffset + 4);
    if (fcClx + lcbClx > [table length] || !lcbClx)
        fail(@"This Word file could not be read.");
    n = 0;
    p = fcClx;
    while (p < fcClx + lcbClx && t[p] == 1) {
        p += 3 + u16(t + p + 1);
    }
    if (p >= fcClx + lcbClx || t[p] != 2)
        fail(@"This Word file could not be read.");
    {
        unsigned lcb = u32(t + p + 1), pieces;
        const unsigned char *plc = t + p + 5;
        if (p + 5 + lcb > [table length] || lcb < 16)
            fail(@"This Word file could not be read.");
        pieces = (lcb - 4) / 12;
        total = 0;
        wanted = (unsigned long)ccpText + (ccpFtn ? ccpFtn + 1 : 0);
        for (i = 0; i < pieces && total < wanted && [raw length] < MAX_TEXT * 2; i++) {
            unsigned cpStart = u32(plc + i * 4), cpEnd = u32(plc + (i + 1) * 4);
            const unsigned char *pcd = plc + (pieces + 1) * 4 + i * 8;
            unsigned fc = u32(pcd + 2);
            unsigned long count, offset;
            if (cpEnd <= cpStart || cpStart >= wanted)
                continue;
            if (cpEnd > wanted)
                cpEnd = wanted;
            count = cpEnd - cpStart;
            if (fc & 0x40000000) {
                offset = (fc & 0x3FFFFFFF) / 2;
                if (offset + count <= [word length])
                    appendBytes8(raw, w + offset, count);
            } else {
                offset = fc;
                if (offset + count * 2 <= [word length])
                    appendUTF16(raw, w + offset, count);
            }
            total += count;
        }
    }
    {
        NSString *body = raw;
        if (ccpFtn && ccpText < [raw length]) {
            NSString *body0 = [raw substringToIndex:ccpText], *foot = [raw substringFromIndex:ccpText];
            return [NSString stringWithFormat:@"%@\n\n[Footnotes]\n%@", wordClean(body0), wordClean(foot)];
        }
        return wordClean(body);
    }
}

/* ---- Excel (BIFF8) ---- */

static NSString *numberText(double v)
{
    char text[40];
    if (v == (double)(long long)v && v < 1e15 && v > -1e15)
        snprintf(text, sizeof text, "%lld", (long long)v);
    else {
        snprintf(text, sizeof text, "%.15g", v);
    }
    return [NSString stringWithUTF8String:text];
}

static double rkValue(unsigned rk)
{
    double v;
    if (rk & 2)
        v = (double)((int)rk >> 2);
    else {
        unsigned long long bits = ((unsigned long long)(rk & 0xFFFFFFFCu)) << 32;
        memcpy(&v, &bits, 8);
    }
    return (rk & 1) ? v / 100 : v;
}

static BOOL builtinDateFormat(unsigned id)
{
    return (id >= 14 && id <= 22) || (id >= 27 && id <= 36) || (id >= 45 && id <= 47) || (id >= 50 && id <= 58);
}

static BOOL customDateFormat(NSString *format)
{
    BOOL quoted = NO, bracket = NO, any = NO;
    unsigned i;
    for (i = 0; i < [format length]; i++) {
        unichar c = [format characterAtIndex:i];
        if (c == '"') quoted = !quoted;
        else if (quoted) continue;
        else if (c == '[') bracket = YES;
        else if (c == ']') bracket = NO;
        else if (c == '\\' || c == '_' || c == '*') i++;
        else if (!bracket && (c == 'd' || c == 'm' || c == 'y' || c == 'h' || c == 's' || c == 'D' || c == 'M' || c == 'Y' || c == 'H' || c == 'S'))
            any = YES;
    }
    return any && [format rangeOfString:@"General"].location == NSNotFound;
}

static NSString *dateText(double serial, BOOL mode1904)
{
    long days = (long)serial, unixDay, era, doe, yoe, doy, mp;
    double frac = serial - days;
    int y, m, d;
    if (serial < 0 || serial > 2958465)
        return numberText(serial);
    /* day 0 of the 1904 system is 1904-01-01; in the 1900 system serial 61 is 1900-03-01, because Excel counts a 29 February 1900 */
    unixDay = mode1904 ? days - 24107 : (days >= 61 ? days - 25569 : days - 25568);
    unixDay += 719468;
    era = (unixDay >= 0 ? unixDay : unixDay - 146096) / 146097;
    doe = unixDay - era * 146097;
    yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    y = (int)(yoe + era * 400);
    doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    mp = (5 * doy + 2) / 153;
    d = (int)(doy - (153 * mp + 2) / 5 + 1);
    m = (int)(mp < 10 ? mp + 3 : mp - 9);
    if (m <= 2)
        y++;
    if (frac > 0.00001) {
        long secs = (long)(frac * 86400 + 0.5);
        if (days == 0)
            return [NSString stringWithFormat:@"%02ld:%02ld:%02ld", secs / 3600, (secs / 60) % 60, secs % 60];
        return [NSString stringWithFormat:@"%04d-%02d-%02d %02ld:%02ld", y, m, d, secs / 3600, (secs / 60) % 60];
    }
    return [NSString stringWithFormat:@"%04d-%02d-%02d", y, m, d];
}

/* A BIFF8 string whose length comes first; `p` is where the length is, `lenBytes` is 1 or 2. Returns the characters; *used is the bytes taken. */
static NSString *biffString(const unsigned char *p, unsigned avail, unsigned lenBytes, unsigned *used)
{
    unsigned cch = lenBytes == 1 ? p[0] : u16(p), pos = lenBytes, flags, runs = 0, ext = 0;
    NSMutableString *out = [NSMutableString string];
    if (avail < lenBytes + 1) {
        *used = avail;
        return @"";
    }
    flags = p[pos++];
    if (flags & 0x08) { runs = u16(p + pos); pos += 2; }
    if (flags & 0x04) { ext = u32(p + pos); pos += 4; }
    if (flags & 1) {
        if (pos + cch * 2 > avail) cch = (avail - pos) / 2;
        appendUTF16(out, p + pos, cch);
        pos += cch * 2;
    } else {
        if (pos + cch > avail) cch = avail - pos;
        appendBytes8(out, p + pos, cch);
        pos += cch;
    }
    pos += runs * 4 + ext;
    *used = pos;
    return out;
}

/* the shared string table, which the file splits across CONTINUE records */
static NSArray *sharedStringTable(NSArray *segments)
{
    NSMutableArray *out = [NSMutableArray array];
    unsigned seg = 0, pos = 8;                /* after cstTotal and cstUnique */
    unsigned unique;
    NSData *first;
    if (![segments count])
        return out;
    first = [segments objectAtIndex:0];
    if ([first length] < 8)
        return out;
    unique = u32((const unsigned char *)[first bytes] + 4);
    if (unique > 2000000)
        unique = 2000000;
    while ([out count] < unique && seg < [segments count]) {
        NSData *d = [segments objectAtIndex:seg];
        const unsigned char *b = [d bytes];
        unsigned len = [d length], cch, flags, runs = 0, ext = 0;
        NSMutableString *s = [NSMutableString string];
        if (pos + 3 > len) {                    /* the header itself is at the end: the next record starts a string */
            seg++;
            pos = 0;
            continue;
        }
        cch = u16(b + pos);
        flags = b[pos + 2];
        pos += 3;
        if (flags & 0x08) {
            if (pos + 2 > len) break;
            runs = u16(b + pos);
            pos += 2;
        }
        if (flags & 0x04) {
            if (pos + 4 > len) break;
            ext = u32(b + pos);
            pos += 4;
        }
        while (cch > 0) {
            unsigned width = (flags & 1) ? 2 : 1, room;
            if (pos >= len) {                   /* continue in the next record, which starts with the encoding byte */
                seg++;
                if (seg >= [segments count]) break;
                d = [segments objectAtIndex:seg];
                b = [d bytes];
                len = [d length];
                if (len < 1) break;
                flags = b[0];
                pos = 1;
                continue;
            }
            room = (len - pos) / width;
            if (room > cch) room = cch;
            if (width == 2) appendUTF16(s, b + pos, room);
            else appendBytes8(s, b + pos, room);
            pos += room * width;
            cch -= room;
            if (room == 0) break;
        }
        {
            unsigned skip = runs * 4 + ext;
            while (skip > 0 && seg < [segments count]) {
                unsigned have = len - pos;
                if (have >= skip) { pos += skip; skip = 0; }
                else {
                    skip -= have;
                    seg++;
                    if (seg >= [segments count]) break;
                    d = [segments objectAtIndex:seg];
                    b = [d bytes];
                    len = [d length];
                    pos = 0;
                }
            }
        }
        [out addObject:s];
        if (pos >= len) {
            seg++;
            pos = 0;
        }
    }
    return out;
}

static NSString *xlsText(TBCompound *cfb)
{
    NSData *book = [cfb stream:@"Workbook"];
    const unsigned char *b;
    unsigned long p = 0, n;
    NSMutableArray *sstSegments = [NSMutableArray array], *sheets = [NSMutableArray array], *xfFormats = [NSMutableArray array];
    NSMutableDictionary *formats = [NSMutableDictionary dictionary];
    NSArray *shared;
    BOOL mode1904 = NO, inSST = NO;
    NSMutableArray *out = [NSMutableArray array];
    long budget = MAX_TEXT;
    unsigned s;
    if (![book length])
        book = [cfb stream:@"Book"];
    if ([book length] < 8)
        fail(@"This Excel file has no readable workbook. Save it as .xlsx or CSV.");
    b = [book bytes];
    n = [book length];
    if (u16(b) != 0x0809 || u16(b + 4) < 0x0600)
        fail(@"This Excel file is from Excel 95 or older, which cannot be read. Save it as .xlsx or CSV.");
    /* the workbook's global records */
    while (p + 4 <= n) {
        unsigned type = u16(b + p), len = u16(b + p + 2);
        const unsigned char *d = b + p + 4;
        if (p + 4 + len > n)
            break;
        if (type == 0x00FC) {
            [sstSegments addObject:[NSData dataWithBytes:d length:len]];
            inSST = YES;
        } else if (type == 0x003C && inSST)
            [sstSegments addObject:[NSData dataWithBytes:d length:len]];
        else {
            inSST = NO;
            if (type == 0x0085 && len >= 8) {
                unsigned used;
                NSString *name = biffString(d + 6, len - 6, 1, &used);
                if (d[5] == 0)
                    [sheets addObject:[NSArray arrayWithObjects:name, [NSNumber numberWithUnsignedInt:u32(d)], nil]];
            } else if (type == 0x0022 && len >= 2)
                mode1904 = u16(d) == 1;
            else if (type == 0x041E && len >= 5) {
                unsigned used;
                [formats setObject:biffString(d + 2, len - 2, 2, &used) forKey:[NSNumber numberWithUnsignedInt:u16(d)]];
            } else if (type == 0x00E0 && len >= 4)
                [xfFormats addObject:[NSNumber numberWithUnsignedInt:u16(d + 2)]];
            else if (type == 0x000A)
                break;
        }
        p += 4 + len;
    }
    shared = sharedStringTable(sstSegments);
    for (s = 0; s < [sheets count] && budget > 0; s++) {
        NSString *name = [[sheets objectAtIndex:s] objectAtIndex:0];
        unsigned long q = [[[sheets objectAtIndex:s] objectAtIndex:1] unsignedIntValue];
        NSMutableDictionary *rows = [NSMutableDictionary dictionary];
        int pendingRow = -1, pendingCol = -1;
        NSMutableArray *rowNumbers;
        unsigned shown = 0, i;
        BOOL started = NO;
        [out addObject:[NSString stringWithFormat:@"--- Sheet: %@ ---", name]];
        while (q + 4 <= n) {
            unsigned type = u16(b + q), len = u16(b + q + 2);
            const unsigned char *d = b + q + 4;
            NSString *value = nil;
            int row = -1, col = -1;
            if (q + 4 + len > n)
                break;
            if (type == 0x0809) {
                if (started)
                    break;
                started = YES;
            } else if (type == 0x000A)
                break;
            else if (type == 0x00FD && len >= 10) {
                unsigned idx = u32(d + 6);
                row = u16(d); col = u16(d + 2);
                value = idx < [shared count] ? [shared objectAtIndex:idx] : @"";
            } else if ((type == 0x0203 || type == 0x027E) && len >= 10) {
                double v;
                unsigned xf = u16(d + 4);
                row = u16(d); col = u16(d + 2);
                if (type == 0x0203 && len >= 14) {
                    unsigned long long bits = ((unsigned long long)u32(d + 10) << 32) | u32(d + 6);
                    memcpy(&v, &bits, 8);
                } else
                    v = rkValue(u32(d + 6));
                {
                    unsigned fmt = xf < [xfFormats count] ? [[xfFormats objectAtIndex:xf] unsignedIntValue] : 0;
                    NSString *custom = [formats objectForKey:[NSNumber numberWithUnsignedInt:fmt]];
                    value = (custom ? customDateFormat(custom) : builtinDateFormat(fmt)) ? dateText(v, mode1904) : numberText(v);
                }
            } else if (type == 0x00BD && len >= 6) {
                unsigned first = u16(d + 2), k, count = (len - 6) / 6;
                row = u16(d);
                for (k = 0; k < count; k++) {
                    double v = rkValue(u32(d + 4 + k * 6 + 2));
                    unsigned xf = u16(d + 4 + k * 6);
                    unsigned fmt = xf < [xfFormats count] ? [[xfFormats objectAtIndex:xf] unsignedIntValue] : 0;
                    NSString *custom = [formats objectForKey:[NSNumber numberWithUnsignedInt:fmt]];
                    NSMutableDictionary *r = [rows objectForKey:[NSNumber numberWithInt:row]];
                    if (!r) {
                        r = [NSMutableDictionary dictionary];
                        [rows setObject:r forKey:[NSNumber numberWithInt:row]];
                    }
                    [r setObject:(custom ? customDateFormat(custom) : builtinDateFormat(fmt)) ? dateText(v, mode1904) : numberText(v) forKey:[NSNumber numberWithInt:first + k]];
                }
                row = -1;
            } else if (type == 0x0204 && len >= 8) {
                unsigned used;
                row = u16(d); col = u16(d + 2);
                value = biffString(d + 6, len - 6, 2, &used);
            } else if (type == 0x0006 && len >= 20) {
                row = u16(d); col = u16(d + 2);
                if (u16(d + 12) == 0xFFFF) {
                    if (d[6] == 0) {
                        pendingRow = row;
                        pendingCol = col;
                        row = -1;
                    } else if (d[6] == 1)
                        value = d[8] ? @"TRUE" : @"FALSE";
                    else if (d[6] == 2)
                        value = @"#ERROR";
                    else
                        row = -1;
                } else {
                    unsigned long long bits = ((unsigned long long)u32(d + 10) << 32) | u32(d + 6);
                    double v;
                    unsigned xf = u16(d + 4);
                    unsigned fmt = xf < [xfFormats count] ? [[xfFormats objectAtIndex:xf] unsignedIntValue] : 0;
                    NSString *custom = [formats objectForKey:[NSNumber numberWithUnsignedInt:fmt]];
                    memcpy(&v, &bits, 8);
                    value = (custom ? customDateFormat(custom) : builtinDateFormat(fmt)) ? dateText(v, mode1904) : numberText(v);
                }
            } else if (type == 0x0207 && pendingRow >= 0 && len >= 3) {
                unsigned used;
                row = pendingRow; col = pendingCol;
                value = biffString(d, len, 2, &used);
                pendingRow = -1;
            } else if (type == 0x0205 && len >= 8) {
                row = u16(d); col = u16(d + 2);
                value = d[7] ? @"#ERROR" : (d[6] ? @"TRUE" : @"FALSE");
            }
            if (value && row >= 0 && col >= 0 && col < 4096) {
                NSMutableDictionary *r = [rows objectForKey:[NSNumber numberWithInt:row]];
                if (!r) {
                    r = [NSMutableDictionary dictionary];
                    [rows setObject:r forKey:[NSNumber numberWithInt:row]];
                }
                [r setObject:value forKey:[NSNumber numberWithInt:col]];
            }
            q += 4 + len;
        }
        rowNumbers = [NSMutableArray arrayWithArray:[[rows allKeys] sortedArrayUsingSelector:@selector(compare:)]];
        for (i = 0; i < [rowNumbers count] && shown < 2000 && budget > 0; i++) {
            NSDictionary *r = [rows objectForKey:[rowNumbers objectAtIndex:i]];
            NSArray *cols = [[r allKeys] sortedArrayUsingSelector:@selector(compare:)];
            NSMutableString *line = [NSMutableString string];
            int next = 0;
            unsigned k;
            for (k = 0; k < [cols count]; k++) {
                int c = [[cols objectAtIndex:k] intValue];
                while (next < c) {
                    [line appendString:@"\t"];
                    next++;
                }
                [line appendString:[r objectForKey:[cols objectAtIndex:k]]];
                next = c;
            }
            if ([TBTrim(line) length]) {
                [out addObject:line];
                shown++;
                budget -= [line length];
            }
        }
        if (i < [rowNumbers count])
            [out addObject:@"[more rows not shown]"];
    }
    return TBTrim([out componentsJoinedByString:@"\n"]);
}

/* ---- PowerPoint ---- */

/* the text atoms inside the records from `start` to `end` of the stream, in order */
static void pptCollect(const unsigned char *b, unsigned long start, unsigned long end, NSMutableArray *lines, int depth, BOOL *sawText)
{
    unsigned long p = start;
    while (p + 8 <= end) {
        unsigned verInst = u16(b + p), type = u16(b + p + 2);
        unsigned long len = u32(b + p + 4);
        if (p + 8 + len > end)
            len = end - p - 8;
        if ((verInst & 0x0F) == 0x0F && depth < 12)
            pptCollect(b, p + 8, p + 8 + len, lines, depth + 1, sawText);
        else if (type == 0x0FA0 || type == 0x0FA8) {
            NSMutableString *s = [NSMutableString string];
            unsigned i;
            NSArray *parts;
            if (type == 0x0FA0)
                appendUTF16(s, b + p + 8, (unsigned)len / 2);
            else
                appendBytes8(s, b + p + 8, (unsigned)len);
            parts = [[[s componentsSeparatedByString:@"\r"] componentsJoinedByString:@"\n"] componentsSeparatedByString:@"\n"];
            for (i = 0; i < [parts count]; i++) {
                NSString *t = [[[parts objectAtIndex:i] componentsSeparatedByString:@"\v"] componentsJoinedByString:@" "];
                if ([TBTrim(t) length])
                    [lines addObject:t];
            }
            *sawText = YES;
        }
        p += 8 + len;
    }
}

static NSString *pptText(TBCompound *cfb)
{
    NSData *doc = [cfb stream:@"PowerPoint Document"], *user = [cfb stream:@"Current User"];
    const unsigned char *b;
    unsigned long n;
    NSMutableDictionary *persist = [NSMutableDictionary dictionary];
    NSMutableArray *out = [NSMutableArray array], *slideOrder = [NSMutableArray array];
    unsigned long edit = 0;
    unsigned docId = 0, guard = 0, i;
    NSMutableArray *edits = [NSMutableArray array];
    if ([doc length] < 16)
        fail(@"This PowerPoint file has no readable slides. Save it as .pptx or PDF.");
    b = [doc bytes];
    n = [doc length];
    if ([user length] >= 16 && u32((const unsigned char *)[user bytes] + 4) == 0xF3D1C4DF)
        fail(@"This PowerPoint file is password protected. Save a copy without the password.");
    if ([user length] >= 16)
        edit = u32((const unsigned char *)[user bytes] + 8);
    /* the edits, newest first, each with a table of where every object now lives */
    while (edit && edit + 8 + 28 <= n && guard++ < 1000) {
        const unsigned char *e = b + edit + 8;
        unsigned long dirOffset = u32(e + 12), last = u32(e + 8);
        if (u16(b + edit + 2) != 0x0FF5)
            break;
        if (!docId)
            docId = u32(e + 16);
        [edits addObject:[NSNumber numberWithUnsignedLong:dirOffset]];
        edit = last;
    }
    for (i = [edits count]; i > 0; i--) {
        unsigned long at = [[edits objectAtIndex:i - 1] unsignedLongValue];
        unsigned long end;
        if (at + 8 > n || u16(b + at + 2) != 0x1772)
            continue;
        end = at + 8 + u32(b + at + 4);
        if (end > n)
            end = n;
        at += 8;
        while (at + 4 <= end) {
            unsigned head = u32(b + at), base = head & 0xFFFFF, count = head >> 20, k;
            at += 4;
            for (k = 0; k < count && at + 4 <= end; k++, at += 4)
                [persist setObject:[NSNumber numberWithUnsignedInt:u32(b + at)] forKey:[NSNumber numberWithUnsignedInt:base + k]];
        }
    }
    {
        NSNumber *docOffset = [persist objectForKey:[NSNumber numberWithUnsignedInt:docId]];
        if (docOffset && [docOffset unsignedLongValue] + 8 <= n) {
            /* the slide list: a SlidePersistAtom for each slide, in order */
            unsigned long at = [docOffset unsignedLongValue] + 8, end = at + u32(b + [docOffset unsignedLongValue] + 4);
            if (end > n)
                end = n;
            while (at + 8 <= end) {
                unsigned verInst = u16(b + at), type = u16(b + at + 2);
                unsigned long len = u32(b + at + 4);
                if (at + 8 + len > end)
                    break;
                if (type == 0x0FF0 && (verInst >> 4) == 0) {
                    unsigned long q = at + 8, qend = at + 8 + len;
                    while (q + 8 <= qend) {
                        unsigned long l2 = u32(b + q + 4);
                        if (u16(b + q + 2) == 0x03F3 && l2 >= 4)
                            [slideOrder addObject:[NSNumber numberWithUnsignedInt:u32(b + q + 8)]];
                        q += 8 + l2;
                    }
                }
                at += 8 + len;
            }
        }
    }
    if ([slideOrder count]) {
        for (i = 0; i < [slideOrder count]; i++) {
            NSNumber *at = [persist objectForKey:[slideOrder objectAtIndex:i]];
            NSMutableArray *lines = [NSMutableArray array];
            BOOL saw = NO;
            unsigned j;
            [out addObject:[NSString stringWithFormat:@"--- Slide %u ---", i + 1]];
            if (at && [at unsignedLongValue] + 8 <= n && u16(b + [at unsignedLongValue] + 2) == 0x03EE) {
                unsigned long s = [at unsignedLongValue], len = u32(b + s + 4);
                if (s + 8 + len > n)
                    len = n - s - 8;
                pptCollect(b, s + 8, s + 8 + len, lines, 0, &saw);
            }
            for (j = 0; j < [lines count]; j++)
                [out addObject:[lines objectAtIndex:j]];
        }
    } else {
        /* no usable edit history: every slide record in the file, in file order */
        unsigned long p = 0;
        unsigned count = 0;
        while (p + 8 <= n) {
            unsigned verInst = u16(b + p), type = u16(b + p + 2);
            unsigned long len = u32(b + p + 4);
            if (p + 8 + len > n)
                len = n - p - 8;
            if ((verInst & 0x0F) == 0x0F && type == 0x03EE) {
                NSMutableArray *lines = [NSMutableArray array];
                BOOL saw = NO;
                [out addObject:[NSString stringWithFormat:@"--- Slide %u ---", ++count]];
                pptCollect(b, p + 8, p + 8 + len, lines, 0, &saw);
                [out addObjectsFromArray:lines];
            }
            p += ((verInst & 0x0F) == 0x0F) ? 8 : 8 + len;
        }
    }
    return TBTrim([out componentsJoinedByString:@"\n"]);
}

NSString *TBLegacyOfficeText(NSString *extension, NSData *data)
{
    TBCompound *cfb = [[[TBCompound alloc] initWithData:data] autorelease];
    NSString *text;
    if (!cfb) {
        const unsigned char *head = [data bytes];
        if ([data length] > 4 && head[0] == '{' && head[1] == '\\')
            fail(@"This is a Rich Text file with a different extension. Rename it to .rtf.");
        fail(@"This file is not a Word, Excel or PowerPoint 97-2003 file, or it is damaged. Save it again, or export it as PDF or text.");
    }
    if ([extension isEqualToString:@"doc"])
        text = docText(cfb);
    else if ([extension isEqualToString:@"xls"])
        text = xlsText(cfb);
    else
        text = pptText(cfb);
    return text;
}
