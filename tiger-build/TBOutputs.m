#import "TBOutputs.h"
#import "TBExtract.h"
#import "TBEngine.h"
#import <zlib.h>

#define TEXT_LIMIT 2000000
#define BINARY_LIMIT 8000000

/* ---- the media folder ---- */

NSString *TBMediaFolder(void)
{
    NSString *folder = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Tiger Build/media"];
    NSFileManager *manager = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if (![manager fileExistsAtPath:folder isDirectory:&isDirectory]) {
        NSString *parent = [folder stringByDeletingLastPathComponent];
        if (![manager fileExistsAtPath:parent])
            [manager createDirectoryAtPath:[parent stringByDeletingLastPathComponent] attributes:nil];
        [manager createDirectoryAtPath:parent attributes:nil];
        [manager createDirectoryAtPath:folder attributes:nil];
    }
    return folder;
}

NSString *TBSafeMediaName(NSString *name)
{
    unsigned i;
    if (![name length] || [name rangeOfString:@".."].location != NSNotFound)
        return nil;
    for (i = 0; i < [name length]; i++) {
        unichar c = [name characterAtIndex:i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-'))
            return nil;
    }
    return name;
}

static NSString *randomName(void)
{
    return [NSString stringWithFormat:@"%08x%08x", (unsigned)arc4random(), (unsigned)arc4random()];
}

NSString *TBSaveMedia(NSData *data, NSString *extension)
{
    NSString *name;
    /* some services (Muse) send WebP, which these systems cannot show: keep a JPEG instead */
    if ([data length] > 12 && !memcmp([data bytes], "RIFF", 4) && !memcmp((const char *)[data bytes] + 8, "WEBP", 4)) {
        NSData *jpeg = TBJPEGFromWebP(data, 2400);
        if (jpeg) {
            data = jpeg;
            extension = @"jpg";
        }
    }
    name = [NSString stringWithFormat:@"%@.%@", randomName(), extension];
    if (![data writeToFile:[TBMediaFolder() stringByAppendingPathComponent:name] atomically:NO])
        TBFail(@"The file could not be stored.");
    return name;
}

/* ---- base64 ---- */

NSData *TBBase64Decode(NSString *text)
{
    NSMutableData *out = [NSMutableData data];
    unsigned i, bits = 0, count = 0, padding = 0;
    for (i = 0; i < [text length]; i++) {
        unichar c = [text characterAtIndex:i];
        int v;
        if (c == ' ' || c == '\n' || c == '\r' || c == '\t')
            continue;
        if (c == '=') {
            padding++;
            continue;
        }
        if (padding)
            return nil;
        if (c >= 'A' && c <= 'Z') v = c - 'A';
        else if (c >= 'a' && c <= 'z') v = c - 'a' + 26;
        else if (c >= '0' && c <= '9') v = c - '0' + 52;
        else if (c == '+' || c == '-') v = 62;
        else if (c == '/' || c == '_') v = 63;
        else return nil;
        bits = (bits << 6) | v;
        if (++count == 4) {
            unsigned char b[3] = {(bits >> 16) & 255, (bits >> 8) & 255, bits & 255};
            [out appendBytes:b length:3];
            bits = 0;
            count = 0;
        }
    }
    if (count == 1)
        return nil;
    if (count == 2) {
        unsigned char b = (bits >> 4) & 255;
        [out appendBytes:&b length:1];
    } else if (count == 3) {
        unsigned char b[2] = {(bits >> 10) & 255, (bits >> 2) & 255};
        [out appendBytes:b length:2];
    }
    return out;
}

/* ---- small text helpers (the 10.4 Foundation has no stringByReplacingOccurrencesOfString:) ---- */

static NSString *swapText(NSString *text, NSString *from, NSString *to)
{
    return [[text componentsSeparatedByString:from] componentsJoinedByString:to];
}

static NSString *escapeXML(NSString *text)
{
    return swapText(swapText(swapText(text, @"&", @"&amp;"), @"<", @"&lt;"), @">", @"&gt;");
}

static NSString *bulletMark(void)
{
    return [NSString stringWithFormat:@"%C ", (unichar)0x2022];
}

static NSArray *lines(NSString *text)
{
    return [swapText(text, @"\r\n", @"\n") componentsSeparatedByString:@"\n"];
}

/* "# Title" gives 1 and sets *rest to "Title"; 0 when the line is not a heading of one to three marks */
static int headingLevel(NSString *stripped, NSString **rest)
{
    unsigned n = 0, len = [stripped length];
    while (n < len && [stripped characterAtIndex:n] == '#')
        n++;
    if (n < 1 || n > 3 || n >= len)
        return 0;
    if ([stripped characterAtIndex:n] != ' ' && [stripped characterAtIndex:n] != '\t')
        return 0;
    *rest = TBTrim([stripped substringFromIndex:n]);
    return n;
}

/* the text after "- ", "* " or a bullet; nil when the line is not a list item */
static NSString *bulletText(NSString *stripped)
{
    unichar c;
    if ([stripped length] < 2)
        return nil;
    c = [stripped characterAtIndex:0];
    if ((c == '-' || c == '*' || c == 0x2022) && ([stripped characterAtIndex:1] == ' ' || [stripped characterAtIndex:1] == '\t'))
        return TBTrim([stripped substringFromIndex:1]);
    return nil;
}

/* ---- zip ---- */

static void put16(NSMutableData *d, unsigned v)
{
    unsigned char b[2] = {v & 255, (v >> 8) & 255};
    [d appendBytes:b length:2];
}

static void put32(NSMutableData *d, unsigned v)
{
    unsigned char b[4] = {v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255};
    [d appendBytes:b length:4];
}

static NSData *deflated(NSData *data)
{
    z_stream s;
    NSMutableData *out = [NSMutableData dataWithLength:deflateBound(NULL, [data length]) + 64];
    memset(&s, 0, sizeof s);
    if (deflateInit2(&s, 6, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY) != Z_OK)
        return nil;
    s.next_in = (Bytef *)[data bytes];
    s.avail_in = [data length];
    s.next_out = [out mutableBytes];
    s.avail_out = [out length];
    deflate(&s, Z_FINISH);
    [out setLength:s.total_out];
    deflateEnd(&s);
    return out;
}

/* ---- Word ---- */

static NSString *runs(NSString *text)
{
    NSMutableString *out = [NSMutableString string];
    unsigned i = 0, n = [text length], start = 0;
    NSMutableString *plain = [NSMutableString string];
    (void)start;
    while (i < n) {
        unichar c = [text characterAtIndex:i];
        NSString *shown = nil;
        NSString *props = @"";
        unsigned next = i;
        if (c == '*' && i + 1 < n && [text characterAtIndex:i + 1] == '*') {
            unsigned j = i + 2;
            while (j < n && [text characterAtIndex:j] != '*')
                j++;
            if (j + 1 < n && [text characterAtIndex:j + 1] == '*' && j > i + 2) {
                shown = [text substringWithRange:NSMakeRange(i + 2, j - i - 2)];
                props = @"<w:rPr><w:b/></w:rPr>";
                next = j + 2;
            }
        } else if (c == '`') {
            unsigned j = i + 1;
            while (j < n && [text characterAtIndex:j] != '`')
                j++;
            if (j < n && j > i + 1) {
                shown = [text substringWithRange:NSMakeRange(i + 1, j - i - 1)];
                props = @"<w:rPr><w:rFonts w:ascii=\"Courier New\" w:hAnsi=\"Courier New\"/></w:rPr>";
                next = j + 1;
            }
        }
        if (shown) {
            if ([plain length]) {
                [out appendFormat:@"<w:r><w:t xml:space=\"preserve\">%@</w:t></w:r>", escapeXML(plain)];
                [plain setString:@""];
            }
            [out appendFormat:@"<w:r>%@<w:t xml:space=\"preserve\">%@</w:t></w:r>", props, escapeXML(shown)];
            i = next;
        } else {
            [plain appendFormat:@"%C", c];
            i++;
        }
    }
    if ([plain length])
        [out appendFormat:@"<w:r><w:t xml:space=\"preserve\">%@</w:t></w:r>", escapeXML(plain)];
    return [out length] ? out : @"<w:r><w:t></w:t></w:r>";
}

static NSString *paragraph(NSString *text, NSString *style, int indent)
{
    NSString *props = @"";
    if (style || indent)
        props = [NSString stringWithFormat:@"<w:pPr>%@%@</w:pPr>", style ? [NSString stringWithFormat:@"<w:pStyle w:val=\"%@\"/>", style] : @"",
            indent ? [NSString stringWithFormat:@"<w:ind w:left=\"%d\"/>", indent] : @""];
    return [NSString stringWithFormat:@"<w:p>%@%@</w:p>", props, runs(text)];
}

static BOOL isSeparatorCell(NSString *c)
{
    unsigned i, dashes = 0;
    for (i = 0; i < [c length]; i++) {
        unichar ch = [c characterAtIndex:i];
        if (ch == '-')
            dashes++;
        else if (ch != ':')
            return NO;
    }
    return dashes >= 2;
}

static NSString *tableXML(NSArray *rows)
{
    unsigned cells = 0, r, c;
    NSMutableString *out = [NSMutableString stringWithString:@"<w:tbl><w:tblPr><w:tblBorders>"];
    NSArray *sides = [NSArray arrayWithObjects:@"top", @"left", @"bottom", @"right", @"insideH", @"insideV", nil];
    for (r = 0; r < [rows count]; r++)
        if ([[rows objectAtIndex:r] count] > cells)
            cells = [[rows objectAtIndex:r] count];
    for (c = 0; c < [sides count]; c++)
        [out appendFormat:@"<w:%@ w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"999999\"/>", [sides objectAtIndex:c]];
    [out appendString:@"</w:tblBorders></w:tblPr>"];
    for (r = 0; r < [rows count]; r++) {
        NSArray *row = [rows objectAtIndex:r];
        [out appendString:@"<w:tr>"];
        for (c = 0; c < cells; c++) {
            NSString *text = c < [row count] ? [row objectAtIndex:c] : @"";
            if (r == 0 && [text length])
                text = [NSString stringWithFormat:@"**%@**", text];
            [out appendFormat:@"<w:tc>%@</w:tc>", paragraph(text, nil, 0)];
        }
        [out appendString:@"</w:tr>"];
    }
    [out appendString:@"</w:tbl>"];
    return out;
}

static NSData *utf8(NSString *s)
{
    return [s dataUsingEncoding:NSUTF8StringEncoding];
}

static NSData *makeDocx(NSString *text)
{
    NSArray *all = lines(text);
    NSMutableString *body = [NSMutableString string];
    unsigned index = 0;
    NSString *head = @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>";
    NSString *types, *rels, *docRels, *styles, *document;
    while (index < [all count]) {
        NSString *line = [all objectAtIndex:index], *stripped = TBTrim(line), *rest = nil, *item;
        int level;
        if ([stripped hasPrefix:@"|"] && [stripped hasSuffix:@"|"] && [[stripped componentsSeparatedByString:@"|"] count] >= 3) {
            NSMutableArray *rows = [NSMutableArray array];
            while (index < [all count] && [TBTrim([all objectAtIndex:index]) hasPrefix:@"|"]) {
                NSString *inner = TBTrim([all objectAtIndex:index]);
                NSArray *parts;
                NSMutableArray *cells = [NSMutableArray array];
                BOOL separator = YES, any = NO;
                unsigned p;
                inner = [inner substringFromIndex:1];
                if ([inner hasSuffix:@"|"])
                    inner = [inner substringToIndex:[inner length] - 1];
                parts = [inner componentsSeparatedByString:@"|"];
                for (p = 0; p < [parts count]; p++) {
                    NSString *cell = TBTrim([parts objectAtIndex:p]);
                    [cells addObject:cell];
                    if ([cell length]) {
                        any = YES;
                        if (!isSeparatorCell(cell))
                            separator = NO;
                    }
                }
                if (!(separator && any))
                    [rows addObject:cells];
                index++;
            }
            if ([rows count]) {
                [body appendString:tableXML(rows)];
                [body appendString:@"<w:p/>"];
            }
            continue;
        }
        level = headingLevel(stripped, &rest);
        item = bulletText(stripped);
        if (level)
            [body appendString:paragraph(rest, [NSString stringWithFormat:@"Heading%d", level], 0)];
        else if (item)
            [body appendString:paragraph([bulletMark() stringByAppendingString:item], nil, 360)];
        else if ([stripped length])
            [body appendString:paragraph(line, nil, 0)];
        else
            [body appendString:@"<w:p/>"];
        index++;
    }
    document = [NSString stringWithFormat:@"%@<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>%@"
        "<w:sectPr><w:pgSz w:w=\"12240\" w:h=\"15840\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\"/></w:sectPr></w:body></w:document>", head, body];
    styles = [NSString stringWithFormat:@"%@<w:styles xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
        "<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"Calibri\" w:hAnsi=\"Calibri\"/><w:sz w:val=\"22\"/></w:rPr></w:rPrDefault></w:docDefaults>"
        "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:pPr><w:spacing w:after=\"120\"/></w:pPr></w:style>"
        "<w:style w:type=\"paragraph\" w:styleId=\"Heading1\"><w:name w:val=\"heading 1\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:keepNext/><w:spacing w:before=\"240\" w:after=\"120\"/></w:pPr><w:rPr><w:b/><w:sz w:val=\"36\"/></w:rPr></w:style>"
        "<w:style w:type=\"paragraph\" w:styleId=\"Heading2\"><w:name w:val=\"heading 2\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:keepNext/><w:spacing w:before=\"200\" w:after=\"100\"/></w:pPr><w:rPr><w:b/><w:sz w:val=\"30\"/></w:rPr></w:style>"
        "<w:style w:type=\"paragraph\" w:styleId=\"Heading3\"><w:name w:val=\"heading 3\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:keepNext/><w:spacing w:before=\"160\" w:after=\"80\"/></w:pPr><w:rPr><w:b/><w:sz w:val=\"26\"/></w:rPr></w:style>"
        "</w:styles>", head];
    types = [NSString stringWithFormat:@"%@<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
        "<Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/></Types>", head];
    rels = [NSString stringWithFormat:@"%@<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>", head];
    docRels = [NSString stringWithFormat:@"%@<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/></Relationships>", head];
    return [TBOutputs zipFiles:[NSArray arrayWithObjects:@"[Content_Types].xml", utf8(types), @"_rels/.rels", utf8(rels), @"word/document.xml", utf8(document),
        @"word/styles.xml", utf8(styles), @"word/_rels/document.xml.rels", utf8(docRels), nil]];
}

/* ---- Excel ---- */

static NSString *columnName(unsigned index)
{
    NSMutableString *name = [NSMutableString string];
    index++;
    while (index) {
        unsigned rest = (index - 1) % 26;
        [name insertString:[NSString stringWithFormat:@"%c", (char)('A' + rest)] atIndex:0];
        index = (index - 1) / 26;
    }
    return name;
}

/* one line split at the delimiter, with "quoted, cells" kept whole */
static NSArray *splitRecord(NSString *line, unichar delimiter)
{
    NSMutableArray *cells = [NSMutableArray array];
    NSMutableString *cell = [NSMutableString string];
    BOOL quoted = NO;
    unsigned i, n = [line length];
    for (i = 0; i < n; i++) {
        unichar c = [line characterAtIndex:i];
        if (quoted) {
            if (c == '"' && i + 1 < n && [line characterAtIndex:i + 1] == '"') {
                [cell appendString:@"\""];
                i++;
            } else if (c == '"')
                quoted = NO;
            else
                [cell appendFormat:@"%C", c];
        } else if (c == '"' && [cell length] == 0)
            quoted = YES;
        else if (c == delimiter) {
            [cells addObject:[[cell copy] autorelease]];
            [cell setString:@""];
        } else
            [cell appendFormat:@"%C", c];
    }
    [cells addObject:cell];
    return cells;
}

static BOOL isNumber(NSString *v)
{
    unsigned i = 0, n = [v length], digits;
    if (!n)
        return NO;
    if ([v characterAtIndex:0] == '-')
        i++;
    digits = 0;
    while (i < n && [v characterAtIndex:i] >= '0' && [v characterAtIndex:i] <= '9') {
        i++;
        digits++;
    }
    if (!digits)
        return NO;
    if (i < n && [v characterAtIndex:i] == '.') {
        unsigned f = 0;
        i++;
        while (i < n && [v characterAtIndex:i] >= '0' && [v characterAtIndex:i] <= '9') {
            i++;
            f++;
        }
        if (!f)
            return NO;
    }
    if (i < n && ([v characterAtIndex:i] == 'e' || [v characterAtIndex:i] == 'E')) {
        unsigned e = 0;
        i++;
        if (i < n && ([v characterAtIndex:i] == '-' || [v characterAtIndex:i] == '+'))
            i++;
        while (i < n && [v characterAtIndex:i] >= '0' && [v characterAtIndex:i] <= '9') {
            i++;
            e++;
        }
        if (!e)
            return NO;
    }
    if (i != n)
        return NO;
    /* leading zeros (0123) are an identifier, not a number */
    {
        unsigned s = [v characterAtIndex:0] == '-' ? 1 : 0;
        if (n > s + 1 && [v characterAtIndex:s] == '0' && [v characterAtIndex:s + 1] >= '0' && [v characterAtIndex:s + 1] <= '9')
            return NO;
    }
    return YES;
}

static NSData *makeXlsx(NSString *text)
{
    NSString *sample = [text length] > 4000 ? [text substringToIndex:4000] : text;
    unichar delimiter = [sample rangeOfString:@"\t"].location != NSNotFound ? '\t' : ([sample rangeOfString:@","].location != NSNotFound ? ',' : ([sample rangeOfString:@"|"].location != NSNotFound ? '|' : '\t'));
    NSArray *all = lines(text);
    NSMutableArray *rows = [NSMutableArray array];
    NSMutableString *sheetRows = [NSMutableString string];
    NSString *head = @"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>";
    NSString *sheet, *workbook, *workbookRels, *types, *rels;
    unsigned r, c;
    for (r = 0; r < [all count]; r++) {
        NSArray *cells = splitRecord([all objectAtIndex:r], delimiter);
        if (delimiter == '|') {
            NSMutableArray *kept = [NSMutableArray array];
            BOOL separator = YES, any = NO;
            for (c = 0; c < [cells count]; c++) {
                NSString *cell = TBTrim([cells objectAtIndex:c]);
                if ([cell length]) {
                    any = YES;
                    if (!isSeparatorCell(cell))
                        separator = NO;
                    [kept addObject:cell];
                }
            }
            if (any && separator)
                continue;
            cells = kept;
        }
        if (r == [all count] - 1 && [cells count] == 1 && ![TBTrim([cells objectAtIndex:0]) length])
            continue; /* the empty last line is not a row */
        [rows addObject:cells];
    }
    for (r = 0; r < [rows count]; r++) {
        NSArray *row = [rows objectAtIndex:r];
        NSMutableString *cellsXML = [NSMutableString string];
        for (c = 0; c < [row count]; c++) {
            NSString *value = TBTrim([row objectAtIndex:c]);
            NSString *reference = [NSString stringWithFormat:@"%@%u", columnName(c), r + 1];
            if (![value length])
                continue;
            if (isNumber(value))
                [cellsXML appendFormat:@"<c r=\"%@\"><v>%@</v></c>", reference, value];
            else
                [cellsXML appendFormat:@"<c r=\"%@\" t=\"inlineStr\"><is><t xml:space=\"preserve\">%@</t></is></c>", reference, escapeXML(value)];
        }
        [sheetRows appendFormat:@"<row r=\"%u\">%@</row>", r + 1, cellsXML];
    }
    sheet = [NSString stringWithFormat:@"%@<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>%@</sheetData></worksheet>", head, sheetRows];
    workbook = [NSString stringWithFormat:@"%@<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
        "<sheets><sheet name=\"Sheet1\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>", head];
    workbookRels = [NSString stringWithFormat:@"%@<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>", head];
    types = [NSString stringWithFormat:@"%@<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>"
        "<Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/></Types>", head];
    rels = [NSString stringWithFormat:@"%@<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>", head];
    return [TBOutputs zipFiles:[NSArray arrayWithObjects:@"[Content_Types].xml", utf8(types), @"_rels/.rels", utf8(rels), @"xl/workbook.xml", utf8(workbook),
        @"xl/_rels/workbook.xml.rels", utf8(workbookRels), @"xl/worksheets/sheet1.xml", utf8(sheet), nil]];
}

/* ---- PDF ---- */

#define PDF_W 612
#define PDF_H 792
#define MARGIN 54

/* the character as a Windows-1252 byte */
static unsigned char cp1252(unichar c)
{
    if (c < 0x80 || (c >= 0xa0 && c <= 0xff))
        return c;
    switch (c) {
    case 0x20ac: return 0x80;
    case 0x2026: return 0x85;
    case 0x2018: return 0x91;
    case 0x2019: return 0x92;
    case 0x201c: return 0x93;
    case 0x201d: return 0x94;
    case 0x2022: return 0x95;
    case 0x2013: return 0x96;
    case 0x2014: return 0x97;
    case 0x2122: return 0x99;
    }
    return '?';
}

static NSData *pdfText(NSString *text)
{
    NSMutableData *out = [NSMutableData data];
    unsigned i;
    for (i = 0; i < [text length]; i++) {
        unichar c = [text characterAtIndex:i];
        unsigned char b;
        if (c == '\r')
            continue;
        if (c == '\\' || c == '(' || c == ')') {
            unsigned char slash = '\\';
            [out appendBytes:&slash length:1];
        }
        b = cp1252(c);
        [out appendBytes:&b length:1];
    }
    return out;
}

static NSArray *wrapLine(NSString *line, int size, BOOL bold)
{
    int per = (int)((PDF_W - 2 * MARGIN) / (size * (bold ? 0.55 : 0.5)));
    NSMutableArray *out = [NSMutableArray array];
    NSMutableString *current = [NSMutableString string];
    NSArray *words;
    unsigned i;
    if (per < 20)
        per = 20;
    if ((int)[line length] <= per)
        return [NSArray arrayWithObject:line];
    words = [line componentsSeparatedByString:@" "];
    for (i = 0; i < [words count]; i++) {
        NSString *word = [words objectAtIndex:i];
        while ((int)[word length] > per) {
            if ([current length]) {
                [out addObject:[[current copy] autorelease]];
                [current setString:@""];
            }
            [out addObject:[word substringToIndex:per]];
            word = [word substringFromIndex:per];
        }
        if ((int)([current length] + [word length] + ([current length] ? 1 : 0)) <= per) {
            if ([current length])
                [current appendString:@" "];
            [current appendString:word];
        } else {
            [out addObject:[[current copy] autorelease]];
            [current setString:word];
        }
    }
    [out addObject:current];
    return out;
}

static NSString *withoutBold(NSString *line)
{
    NSMutableString *out = [NSMutableString string];
    unsigned i = 0, n = [line length];
    while (i < n) {
        if ([line characterAtIndex:i] == '*' && i + 1 < n && [line characterAtIndex:i + 1] == '*') {
            unsigned j = i + 2;
            while (j < n && [line characterAtIndex:j] != '*')
                j++;
            if (j + 1 < n && [line characterAtIndex:j + 1] == '*' && j > i + 2) {
                [out appendString:[line substringWithRange:NSMakeRange(i + 2, j - i - 2)]];
                i = j + 2;
                continue;
            }
        }
        [out appendFormat:@"%C", [line characterAtIndex:i]];
        i++;
    }
    return out;
}

static NSData *makePdf(NSString *text)
{
    NSMutableArray *pages = [NSMutableArray arrayWithObject:[NSMutableArray array]];
    NSArray *all = lines(swapText(text, @"\t", @"    "));
    double y = PDF_H - MARGIN;
    unsigned i, p;
    NSMutableArray *objects = [NSMutableArray array];
    NSMutableArray *kids = [NSMutableArray array];
    NSMutableData *out = [NSMutableData data];
    NSMutableArray *offsets = [NSMutableArray array];
    int catalog, tree, regular, heavy, start;
    for (i = 0; i < [all count]; i++) {
        NSString *raw = [all objectAtIndex:i], *line = raw, *rest = nil;
        int size = 11, level;
        BOOL bold = NO;
        NSArray *pieces;
        level = headingLevel(TBTrim(raw), &rest);
        if (level) {
            size = level == 1 ? 18 : (level == 2 ? 15 : 13);
            bold = YES;
            line = rest;
        } else {
            NSString *item = bulletText(raw);
            line = withoutBold(line);
            if (item) {
                unsigned lead = 0;
                while (lead < [raw length] && ([raw characterAtIndex:lead] == ' ' || [raw characterAtIndex:lead] == '\t'))
                    lead++;
                line = [[raw substringToIndex:lead] stringByAppendingString:[bulletMark() stringByAppendingString:withoutBold(item)]];
            }
        }
        pieces = wrapLine(line, size, bold);
        for (p = 0; p < [pieces count]; p++) {
            double leading = size * 1.35;
            if (y - leading < MARGIN) {
                [pages addObject:[NSMutableArray array]];
                y = PDF_H - MARGIN;
            }
            y -= leading;
            [[pages lastObject] addObject:[NSArray arrayWithObjects:[NSNumber numberWithDouble:y], [NSNumber numberWithInt:size], [NSNumber numberWithBool:bold], [pieces objectAtIndex:p], nil]];
        }
        if (level)
            y -= 4;
    }
    /* objects are numbered from 1; catalog and tree are filled in at the end */
    [objects addObject:[NSData data]];
    [objects addObject:[NSData data]];
    catalog = 1;
    tree = 2;
    [objects addObject:utf8(@"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")];
    regular = 3;
    [objects addObject:utf8(@"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>")];
    heavy = 4;
    for (i = 0; i < [pages count]; i++) {
        NSMutableData *stream = [NSMutableData data];
        NSMutableData *content = [NSMutableData data];
        NSArray *page = [pages objectAtIndex:i];
        int contentNumber;
        for (p = 0; p < [page count]; p++) {
            NSArray *row = [page objectAtIndex:p];
            [stream appendData:utf8([NSString stringWithFormat:@"BT /F%d %d Tf %d %.2f Td (", [[row objectAtIndex:2] boolValue] ? 2 : 1, [[row objectAtIndex:1] intValue], MARGIN, [[row objectAtIndex:0] doubleValue]])];
            [stream appendData:pdfText([row objectAtIndex:3])];
            [stream appendData:utf8(@") Tj ET\n")];
        }
        [content appendData:utf8([NSString stringWithFormat:@"<< /Length %u >>\nstream\n", (unsigned)[stream length]])];
        [content appendData:stream];
        [content appendData:utf8(@"\nendstream")];
        [objects addObject:content];
        contentNumber = [objects count];
        [objects addObject:utf8([NSString stringWithFormat:@"<< /Type /Page /Parent %d 0 R /MediaBox [0 0 %d %d] /Contents %d 0 R /Resources << /Font << /F1 %d 0 R /F2 %d 0 R >> >> >>",
            tree, PDF_W, PDF_H, contentNumber, regular, heavy])];
        [kids addObject:[NSString stringWithFormat:@"%d 0 R", (int)[objects count]]];
    }
    [objects replaceObjectAtIndex:catalog - 1 withObject:utf8([NSString stringWithFormat:@"<< /Type /Catalog /Pages %d 0 R >>", tree])];
    [objects replaceObjectAtIndex:tree - 1 withObject:utf8([NSString stringWithFormat:@"<< /Type /Pages /Count %u /Kids [%@] >>", (unsigned)[kids count], [kids componentsJoinedByString:@" "]])];
    [out appendData:utf8(@"%PDF-1.4\n")];
    for (i = 0; i < [objects count]; i++) {
        [offsets addObject:[NSNumber numberWithUnsignedInt:[out length]]];
        [out appendData:utf8([NSString stringWithFormat:@"%u 0 obj\n", i + 1])];
        [out appendData:[objects objectAtIndex:i]];
        [out appendData:utf8(@"\nendobj\n")];
    }
    start = [out length];
    [out appendData:utf8([NSString stringWithFormat:@"xref\n0 %u\n0000000000 65535 f \n", (unsigned)[objects count] + 1])];
    for (i = 0; i < [offsets count]; i++)
        [out appendData:utf8([NSString stringWithFormat:@"%010u 00000 n \n", [[offsets objectAtIndex:i] unsignedIntValue]])];
    [out appendData:utf8([NSString stringWithFormat:@"trailer\n<< /Size %u /Root %d 0 R >>\nstartxref\n%d\n%%%%EOF\n", (unsigned)[objects count] + 1, catalog, start])];
    return out;
}

/* ---- the tool ---- */

@implementation TBOutputs

+ (NSData *)zipFiles:(NSArray *)items
{
    NSMutableData *out = [NSMutableData data], *directory = [NSMutableData data];
    unsigned i, count = 0;
    for (i = 0; i + 1 < [items count]; i += 2) {
        NSString *name = [items objectAtIndex:i];
        NSData *data = [items objectAtIndex:i + 1], *packed = deflated(data);
        NSData *nameBytes = utf8(name);
        unsigned crc = crc32(0, [data bytes], [data length]), offset = [out length];
        BOOL useDeflate = packed && [packed length] < [data length];
        NSData *stored = useDeflate ? packed : data;
        put32(out, 0x04034b50); put16(out, 20); put16(out, 0); put16(out, useDeflate ? 8 : 0); put16(out, 0); put16(out, 0x21);
        put32(out, crc); put32(out, [stored length]); put32(out, [data length]); put16(out, [nameBytes length]); put16(out, 0);
        [out appendData:nameBytes];
        [out appendData:stored];
        put32(directory, 0x02014b50); put16(directory, 20); put16(directory, 20); put16(directory, 0); put16(directory, useDeflate ? 8 : 0);
        put16(directory, 0); put16(directory, 0x21); put32(directory, crc); put32(directory, [stored length]); put32(directory, [data length]);
        put16(directory, [nameBytes length]); put16(directory, 0); put16(directory, 0); put16(directory, 0); put16(directory, 0); put32(directory, 0); put32(directory, offset);
        [directory appendData:nameBytes];
        count++;
    }
    {
        unsigned start = [out length];
        [out appendData:directory];
        put32(out, 0x06054b50); put16(out, 0); put16(out, 0); put16(out, count); put16(out, count);
        put32(out, [directory length]); put32(out, start); put16(out, 0);
    }
    return out;
}

+ (NSData *)buildName:(NSString *)name content:(NSString *)content base64:(NSString *)encoded cleanName:(NSString **)cleanOut
{
    NSMutableString *clean = [NSMutableString string];
    NSString *base, *ext;
    unsigned i;
    BOOL lastUnderscore = NO;
    NSData *data;
    if (![name isKindOfClass:[NSString class]])
        TBFail(@"Give a file name.");
    base = TBTrim([[swapText(name, @"\\", @"/") componentsSeparatedByString:@"/"] lastObject]);
    for (i = 0; i < [base length]; i++) {
        unichar c = [base characterAtIndex:i];
        BOOL ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
        if (ok) {
            [clean appendFormat:@"%C", c];
            lastUnderscore = NO;
        } else if (!lastUnderscore) {
            [clean appendString:@"_"];
            lastUnderscore = YES;
        }
    }
    while ([clean length] && ([clean hasPrefix:@"."] || [clean hasPrefix:@"_"]))
        [clean deleteCharactersInRange:NSMakeRange(0, 1)];
    while ([clean length] && ([clean hasSuffix:@"."] || [clean hasSuffix:@"_"]))
        [clean deleteCharactersInRange:NSMakeRange([clean length] - 1, 1)];
    if (![clean length])
        [clean setString:@"file.txt"];
    if ([clean length] > 80)
        [clean setString:[clean substringToIndex:80]];
    if ([clean rangeOfString:@"."].location == NSNotFound)
        [clean appendString:@".txt"];
    ext = [[clean pathExtension] lowercaseString];
    *cleanOut = clean;
    if (encoded) {
        if (![encoded isKindOfClass:[NSString class]])
            TBFail(@"content_base64 must be text.");
        data = TBBase64Decode(encoded);
        if (!data)
            TBFail(@"content_base64 is not valid base64.");
        if (![data length])
            TBFail(@"The file is empty.");
        if ([data length] > BINARY_LIMIT)
            TBFail(@"The file is larger than 8 MB.");
        return data;
    }
    if (![content isKindOfClass:[NSString class]] || ![TBTrim(content) length])
        TBFail(@"Give the file's content (or content_base64 for a binary file).");
    if ([[content dataUsingEncoding:NSUTF8StringEncoding] length] > TEXT_LIMIT)
        TBFail(@"The file is larger than 2 MB.");
    if ([ext isEqualToString:@"docx"])
        return makeDocx(content);
    if ([ext isEqualToString:@"xlsx"])
        return makeXlsx(content);
    if ([ext isEqualToString:@"pdf"])
        return makePdf(content);
    return utf8(content);
}

+ (NSString *)saveName:(NSString *)name content:(NSString *)content base64:(NSString *)encoded
{
    NSString *clean = nil, *stored;
    NSData *data = [self buildName:name content:content base64:encoded cleanName:&clean];
    stored = [NSString stringWithFormat:@"%@-%@", randomName(), clean];
    if (![data writeToFile:[TBMediaFolder() stringByAppendingPathComponent:stored] atomically:NO])
        TBFail(@"The file could not be stored.");
    return stored;
}

@end
