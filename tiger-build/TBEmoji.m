#import "TBEmoji.h"
#import "TBSupport.h"

#define STAND_IN_FIRST 0xE000
#define STAND_IN_LAST 0xF8FF

static NSString *packPath = nil;
static NSData *pack = nil;
static NSDictionary *packIndex = nil;
static BOOL packTried = NO;
static NSMutableArray *emojiList = nil;
static NSMutableDictionary *emojiNumbers = nil;

void TBEmojiUsePack(NSString *path)
{
    [packPath release];
    packPath = [path copy];
    [pack release];
    pack = nil;
    [packIndex release];
    packIndex = nil;
    packTried = NO;
    [emojiList removeAllObjects];
    [emojiNumbers removeAllObjects];
}

static void loadPack(void)
{
    const unsigned char *bytes;
    unsigned length;
    unsigned count;
    unsigned at;
    unsigned base;
    unsigned i;
    NSMutableDictionary *index;
    if (packTried)
        return;
    packTried = YES;
    pack = [[NSData alloc] initWithContentsOfMappedFile:packPath ? packPath : [[NSBundle mainBundle] pathForResource:@"Emoji" ofType:@"pack"]];
    if (!pack)
        return;
    bytes = [pack bytes];
    length = [pack length];
    if (length < 8 || memcmp(bytes, "TBEM", 4) != 0) {
        [pack release];
        pack = nil;
        return;
    }
    count = (bytes[4] << 24) | (bytes[5] << 16) | (bytes[6] << 8) | bytes[7];
    index = [NSMutableDictionary dictionaryWithCapacity:count];
    at = 8;
    for (i = 0; i < count && at < length; i++) {
        unsigned nameLength = bytes[at];
        NSString *name;
        unsigned offset, size;
        if (at + 1 + nameLength + 8 > length)
            break;
        name = [[[NSString alloc] initWithBytes:bytes + at + 1 length:nameLength encoding:NSASCIIStringEncoding] autorelease];
        at += 1 + nameLength;
        offset = (bytes[at] << 24) | (bytes[at + 1] << 16) | (bytes[at + 2] << 8) | bytes[at + 3];
        size = (bytes[at + 4] << 24) | (bytes[at + 5] << 16) | (bytes[at + 6] << 8) | bytes[at + 7];
        at += 8;
        [index setObject:[NSArray arrayWithObjects:[NSNumber numberWithUnsignedInt:offset], [NSNumber numberWithUnsignedInt:size], nil] forKey:name];
    }
    /* Offsets count from the end of the index, which is where the loop stopped. */
    base = at;
    packIndex = [[NSDictionary alloc] initWithObjectsAndKeys:index, @"index", [NSNumber numberWithUnsignedInt:base], @"base", nil];
}

BOOL TBEmojiPicturesAvailable(void)
{
    loadPack();
    return packIndex != nil && TBSystemMinor() < 7;
}

static NSData *pictureNamed(NSString *name)
{
    NSArray *where;
    loadPack();
    where = [[packIndex objectForKey:@"index"] objectForKey:name];
    if (!where)
        return nil;
    return [pack subdataWithRange:NSMakeRange([[packIndex objectForKey:@"base"] unsignedIntValue] + [[where objectAtIndex:0] unsignedIntValue],
        [[where objectAtIndex:1] unsignedIntValue])];
}

/* ---- finding emoji ---- */

static BOOL inRange(unsigned long c, unsigned long a, unsigned long b)
{
    return c >= a && c <= b;
}

static BOOL isTone(unsigned long c)
{
    return inRange(c, 0x1F3FB, 0x1F3FF);
}

/* Characters that show as emoji without a variation selector after them. */
static BOOL showsAsEmoji(unsigned long c)
{
    static const unsigned short singles[] = {0x231A, 0x231B, 0x23F0, 0x23F3, 0x25FD, 0x25FE, 0x2614, 0x2615, 0x267F, 0x2693, 0x26A1, 0x26AA, 0x26AB,
        0x26BD, 0x26BE, 0x26C4, 0x26C5, 0x26CE, 0x26D4, 0x26EA, 0x26F2, 0x26F3, 0x26F5, 0x26FA, 0x26FD, 0x2705, 0x270A, 0x270B, 0x2728, 0x274C, 0x274E,
        0x2757, 0x2795, 0x2796, 0x2797, 0x27B0, 0x27BF, 0x2B1B, 0x2B1C, 0x2B50, 0x2B55};
    unsigned i;
    if (c >= 0x1F000)
        return YES;
    if (inRange(c, 0x23E9, 0x23EC) || inRange(c, 0x2648, 0x2653) || inRange(c, 0x2753, 0x2755))
        return YES;
    for (i = 0; i < sizeof(singles) / sizeof(singles[0]); i++) {
        if (singles[i] == c)
            return YES;
    }
    return NO;
}

static BOOL isBase(unsigned long c)
{
    if (inRange(c, 0x1F000, 0x1FAFF) && !inRange(c, 0x1F1E6, 0x1F1FF) && !isTone(c))
        return YES;
    if (inRange(c, 0x2600, 0x27BF) || inRange(c, 0x2B05, 0x2B07) || inRange(c, 0x2194, 0x2199) || inRange(c, 0x23E9, 0x23F3) || inRange(c, 0x23F8, 0x23FA)
        || inRange(c, 0x25FB, 0x25FE) || inRange(c, 0x2934, 0x2935))
        return YES;
    return c == 0xA9 || c == 0xAE || c == 0x203C || c == 0x2049 || c == 0x2122 || c == 0x2139 || c == 0x21A9 || c == 0x21AA || c == 0x231A || c == 0x231B
        || c == 0x2328 || c == 0x23CF || c == 0x24C2 || c == 0x25AA || c == 0x25AB || c == 0x25B6 || c == 0x25C0 || c == 0x2B1B || c == 0x2B1C
        || c == 0x2B50 || c == 0x2B55 || c == 0x3030 || c == 0x303D || c == 0x3297 || c == 0x3299;
}

/* How many code points the emoji starting at i has, or 0 if none does. */
static int clusterLength(const unsigned long *cp, int n, int i)
{
    unsigned long c = cp[i];
    int j = i + 1;
    if (inRange(c, 0x1F1E6, 0x1F1FF))
        return (j < n && inRange(cp[j], 0x1F1E6, 0x1F1FF)) ? 2 : 0;
    if (inRange(c, '0', '9') || c == '#' || c == '*') {
        if (j < n && cp[j] == 0xFE0F)
            j++;
        return (j < n && cp[j] == 0x20E3) ? j + 1 - i : 0;
    }
    if (!isBase(c))
        return 0;
    if (!showsAsEmoji(c) && !(j < n && cp[j] == 0xFE0F))
        return 0;
    for (;;) {
        if (j < n && cp[j] == 0xFE0F)
            j++;
        if (j < n && isTone(cp[j]))
            j++;
        if (c == 0x1F3F4) {
            while (j < n && inRange(cp[j], 0xE0020, 0xE007F))
                j++;
        }
        if (j + 1 < n && cp[j] == 0x200D && isBase(cp[j + 1])) {
            c = cp[j + 1];
            j += 2;
        } else {
            break;
        }
    }
    return j - i;
}

static NSString *hexName(const unsigned long *cp, int count, BOOL keepSelectors)
{
    NSMutableString *name = [NSMutableString string];
    int i;
    for (i = 0; i < count; i++) {
        if (!keepSelectors && cp[i] == 0xFE0F)
            continue;
        if ([name length] > 0)
            [name appendString:@"-"];
        [name appendFormat:@"%lx", cp[i]];
    }
    return name;
}

/* The picture's name for this emoji. Joined emoji the set lacks fall back to their first part. */
static NSString *pictureName(const unsigned long *cp, int count)
{
    int end = count;
    loadPack();
    while (end > 0) {
        NSString *plain = hexName(cp, end, NO);
        NSString *full = hexName(cp, end, YES);
        int k;
        if (pictureNamed(plain))
            return plain;
        if (pictureNamed(full))
            return full;
        for (k = end - 1; k > 0 && cp[k] != 0x200D; k--)
            ;
        if (k <= 0)
            break;
        end = k;
    }
    return nil;
}

NSString *TBEmojiSubstitute(NSString *text)
{
    unsigned n = [text length];
    unsigned long *cp;
    unsigned *at;
    unsigned count = 0;
    unsigned i;
    NSMutableString *out;
    BOOL changed = NO;
    if (n == 0 || !TBEmojiPicturesAvailable())
        return TBDisplayText(text);
    if (!emojiList) {
        emojiList = [[NSMutableArray alloc] init];
        emojiNumbers = [[NSMutableDictionary alloc] init];
    }
    cp = malloc(sizeof(unsigned long) * n);
    at = malloc(sizeof(unsigned) * (n + 1));
    for (i = 0; i < n;) {
        unichar c = [text characterAtIndex:i];
        at[count] = i;
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < n) {
            cp[count++] = 0x10000 + (((unsigned long)c - 0xD800) << 10) + ((unsigned long)[text characterAtIndex:i + 1] - 0xDC00);
            i += 2;
        } else {
            cp[count++] = c;
            i++;
        }
    }
    at[count] = n;
    out = [NSMutableString stringWithCapacity:n];
    for (i = 0; i < count;) {
        int length = clusterLength(cp, count, i);
        NSString *name = length > 0 ? pictureName(cp + i, length) : nil;
        if (name) {
            NSString *emoji = [text substringWithRange:NSMakeRange(at[i], at[i + length] - at[i])];
            NSNumber *number = [emojiNumbers objectForKey:emoji];
            if (!number && [emojiList count] <= STAND_IN_LAST - STAND_IN_FIRST) {
                number = [NSNumber numberWithUnsignedInt:[emojiList count]];
                [emojiList addObject:emoji];
                [emojiNumbers setObject:number forKey:emoji];
            }
            if (number) {
                [out appendFormat:@"%C", (unichar)(STAND_IN_FIRST + [number unsignedIntValue])];
                i += length;
                changed = YES;
                continue;
            }
        }
        [out appendString:[text substringWithRange:NSMakeRange(at[i], at[i + 1] - at[i])]];
        i++;
    }
    free(cp);
    free(at);
    return TBDisplayText(changed ? out : text);
}

BOOL TBEmojiIsStandIn(unichar c)
{
    return c >= STAND_IN_FIRST && c <= STAND_IN_LAST && (unsigned)(c - STAND_IN_FIRST) < [emojiList count];
}

NSString *TBEmojiForStandIn(unichar c)
{
    return TBEmojiIsStandIn(c) ? [emojiList objectAtIndex:c - STAND_IN_FIRST] : nil;
}

NSData *TBEmojiPNGForStandIn(unichar c)
{
    NSString *emoji = TBEmojiForStandIn(c);
    unsigned long cp[32];
    unsigned count = 0;
    unsigned i;
    NSString *name;
    if (!emoji)
        return nil;
    for (i = 0; i < [emoji length] && count < 32;) {
        unichar u = [emoji characterAtIndex:i];
        if (u >= 0xD800 && u <= 0xDBFF && i + 1 < [emoji length]) {
            cp[count++] = 0x10000 + (((unsigned long)u - 0xD800) << 10) + ((unsigned long)[emoji characterAtIndex:i + 1] - 0xDC00);
            i += 2;
        } else {
            cp[count++] = u;
            i++;
        }
    }
    name = pictureName(cp, count);
    return name ? pictureNamed(name) : nil;
}

NSString *TBEmojiRestore(NSString *text)
{
    NSMutableString *out = nil;
    unsigned i;
    for (i = 0; i < [text length]; i++) {
        unichar c = [text characterAtIndex:i];
        if (TBEmojiIsStandIn(c)) {
            if (!out)
                out = [NSMutableString stringWithString:[text substringToIndex:i]];
            [out appendString:TBEmojiForStandIn(c)];
        } else if (out) {
            [out appendFormat:@"%C", c];
        }
    }
    return out ? out : text;
}
