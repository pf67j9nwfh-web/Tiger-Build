#import <Foundation/Foundation.h>
#import <CoreServices/CoreServices.h>
#import <CoreFoundation/CFPlugInCOM.h>
#import <QuickLook/QuickLook.h>
#import "TBExtract.h"

/* A Quick Look generator for the files Tiger Build can read and the old Macs cannot: HEIC, AVIF, WebP and JPEG XL pictures, JSON files (as text), Markdown and CSV (as pages), ZIP file lists, EPUB books, Word, Excel and PowerPoint
   (docx, xlsx, pptx) and OpenDocument files. It uses Tiger Build's own converter (TBExtract): pictures become a JPEG preview and thumbnail, documents
   a plain-text preview. Leopard and Snow Leopard only (Tiger has no Quick Look). Installed in /Library/QuickLook by the Tiger Build installer. */

#define PLUGIN_FACTORY CFUUIDGetConstantUUIDWithBytes(NULL, 0x6B, 0x1D, 0x3E, 0x0A, 0x7C, 0x5E, 0x4F, 0x1D, 0x9A, 0x53, 0x2D, 0x8B, 0x6C, 0x4E, 0x7F, 0x10)

typedef struct {
    void *conduit;           /* QLGeneratorInterfaceStruct, which must come first */
    CFUUIDRef factoryID;
    UInt32 references;
} TBQuickLookPlugin;

static NSDictionary *converted(CFURLRef url)
{
    NSData *data;
    NSDictionary *result = nil;
    NSString *name = [(NSURL *)url lastPathComponent];
    {
        /* the HEIC decoder (libde265) travels inside this plug-in, not inside an application */
        CFBundleRef bundle = CFBundleGetBundleWithIdentifier(CFSTR("local.tigerbuild.quicklook"));
        CFURLRef library = bundle ? CFBundleCopyResourceURL(bundle, CFSTR("libde265"), CFSTR("dylib"), NULL) : NULL;
        if (library) {
            [[NSUserDefaults standardUserDefaults] registerDefaults:[NSDictionary dictionaryWithObject:[(NSURL *)library path] forKey:@"TBDE265Path"]];
            CFRelease(library);
        }
    }
    data = [NSData dataWithContentsOfURL:(NSURL *)url];
    if (!data || [data length] > 100 * 1024 * 1024)
        return nil;
    @try {
        result = [TBExtract extractName:name data:data];
    } @catch (NSException *e) {
        result = nil;
    }
    return result;
}


/* ---- Markdown and CSV, shown as a page ---- */

static NSString *esc(NSString *t)
{
    NSMutableString *m = [NSMutableString stringWithString:t];
    [m replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, [m length])];
    [m replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, [m length])];
    [m replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, [m length])];
    return m;
}

static NSString *pageHTML(NSString *body)
{
    return [NSString stringWithFormat:@"<html><head><meta charset=\"utf-8\"><style>"
        @"body{font:14px/1.5 'Lucida Grande',Helvetica,sans-serif;margin:18px 24px;color:#222}"
        @"h1,h2,h3{margin:1.1em 0 .4em}h1{font-size:1.7em;border-bottom:1px solid #ccc}h2{font-size:1.4em;border-bottom:1px solid #ddd}"
        @"pre{background:#f4f4f4;padding:8px 10px;border:1px solid #ddd;overflow:auto}code{font:12px Menlo,Monaco,monospace;background:#f1f1f1}pre code{background:none}"
        @"blockquote{margin:0 0 0 4px;padding-left:12px;border-left:4px solid #ccc;color:#555}"
        @"table{border-collapse:collapse}td,th{border:1px solid #ccc;padding:3px 8px;text-align:left;font-size:13px}th{background:#eee}"
        @"tr:nth-child(even) td{background:#fafafa}.note{color:#777;font-size:12px;margin:8px 0}"
        @"</style></head><body>%@</body></html>", body];
}

/* the first of `open` ... `close` in text, as a range of the whole span; NSNotFound when there is no pair */
static NSRange spanOf(NSString *text, NSString *open, NSString *close, NSUInteger from)
{
    NSRange a, b;
    if (from >= [text length])
        return NSMakeRange(NSNotFound, 0);
    a = [text rangeOfString:open options:0 range:NSMakeRange(from, [text length] - from)];
    if (a.location == NSNotFound)
        return a;
    b = [text rangeOfString:close options:0 range:NSMakeRange(a.location + a.length, [text length] - a.location - a.length)];
    if (b.location == NSNotFound || b.location == a.location + a.length)
        return NSMakeRange(NSNotFound, 0);
    return NSMakeRange(a.location, b.location + b.length - a.location);
}

/* **bold**, *italic*, _italic_ and `code` in one line (already HTML-escaped), and [text](address) links; images show their text */
static NSString *inlineMD(NSString *line)
{
    NSMutableString *m = [NSMutableString stringWithString:esc(line)];
    NSRange r;
    NSUInteger at;
    /* code spans first, so their contents are left alone */
    at = 0;
    while ((r = spanOf(m, @"`", @"`", at)).location != NSNotFound) {
        NSString *inner = [m substringWithRange:NSMakeRange(r.location + 1, r.length - 2)];
        NSString *html = [NSString stringWithFormat:@"<code>%@</code>", [[inner stringByReplacingOccurrencesOfString:@"*" withString:@"&#42;"] stringByReplacingOccurrencesOfString:@"_" withString:@"&#95;"]];
        [m replaceCharactersInRange:r withString:html];
        at = r.location + [html length];
    }
    at = 0;
    while ((r = spanOf(m, @"**", @"**", at)).location != NSNotFound) {
        NSString *html = [NSString stringWithFormat:@"<b>%@</b>", [m substringWithRange:NSMakeRange(r.location + 2, r.length - 4)]];
        [m replaceCharactersInRange:r withString:html];
        at = r.location + [html length];
    }
    at = 0;
    while ((r = spanOf(m, @"*", @"*", at)).location != NSNotFound) {
        NSString *html = [NSString stringWithFormat:@"<i>%@</i>", [m substringWithRange:NSMakeRange(r.location + 1, r.length - 2)]];
        [m replaceCharactersInRange:r withString:html];
        at = r.location + [html length];
    }
    at = 0;
    while ((r = spanOf(m, @" _", @"_", at)).location != NSNotFound) {
        NSString *html = [NSString stringWithFormat:@" <i>%@</i>", [m substringWithRange:NSMakeRange(r.location + 2, r.length - 3)]];
        [m replaceCharactersInRange:r withString:html];
        at = r.location + [html length];
    }
    /* links and images: [text](address) */
    at = 0;
    while ((r = spanOf(m, @"](", @")", at)).location != NSNotFound) {
        NSRange open = [m rangeOfString:@"[" options:NSBackwardsSearch range:NSMakeRange(0, r.location)];
        NSString *label, *address;
        BOOL image;
        if (open.location == NSNotFound) {
            at = r.location + 2;
            continue;
        }
        label = [m substringWithRange:NSMakeRange(open.location + 1, r.location - open.location - 1)];
        address = [m substringWithRange:NSMakeRange(r.location + 2, r.length - 3)];
        image = open.location > 0 && [m characterAtIndex:open.location - 1] == '!';
        if (image) {
            open.location--;
            open.length++;
        }
        {
            NSString *html = image ? [NSString stringWithFormat:@"[image: %@]", label] : [NSString stringWithFormat:@"<a href=\"%@\">%@</a>", address, label];
            NSRange whole = NSMakeRange(open.location, r.location + r.length - open.location);
            [m replaceCharactersInRange:whole withString:html];
            at = open.location + [html length];
        }
    }
    return m;
}

static NSString *markdownHTML(NSString *text)
{
    NSArray *lines = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"] componentsSeparatedByString:@"\n"];
    NSMutableString *out = [NSMutableString string], *para = [NSMutableString string];
    NSString *list = nil;       /* "ul" or "ol" while a list is open */
    BOOL code = NO, quote = NO;
    unsigned i;
    for (i = 0; i < [lines count]; i++) {
        NSString *line = [lines objectAtIndex:i], *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        BOOL bullet = [t hasPrefix:@"- "] || [t hasPrefix:@"* "] || [t hasPrefix:@"+ "];
        BOOL numbered = NO;
        if ([t hasPrefix:@"```"] || [t hasPrefix:@"~~~"]) {
            if ([para length]) { [out appendFormat:@"<p>%@</p>\n", inlineMD(para)]; [para setString:@""]; }
            if (list) { [out appendFormat:@"</%@>\n", list]; list = nil; }
            [out appendString:code ? @"</code></pre>\n" : @"<pre><code>"];
            code = !code;
            continue;
        }
        if (code) {
            [out appendFormat:@"%@\n", esc(line)];
            continue;
        }
        {
            NSRange dot = [t rangeOfString:@". "];
            numbered = dot.location != NSNotFound && dot.location > 0 && dot.location < 4
                && [[t substringToIndex:dot.location] rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound;
            if (numbered)
                t = [t substringFromIndex:dot.location + 2];
        }
        if (bullet || numbered) {
            NSString *kind = numbered ? @"ol" : @"ul";
            if ([para length]) { [out appendFormat:@"<p>%@</p>\n", inlineMD(para)]; [para setString:@""]; }
            if (list && ![list isEqualToString:kind]) { [out appendFormat:@"</%@>\n", list]; list = nil; }
            if (!list) { [out appendFormat:@"<%@>\n", kind]; list = kind; }
            [out appendFormat:@"<li>%@</li>\n", inlineMD(bullet ? [t substringFromIndex:2] : t)];
            continue;
        }
        if (list) { [out appendFormat:@"</%@>\n", list]; list = nil; }
        if ([t length] == 0) {
            if ([para length]) { [out appendFormat:@"<p>%@</p>\n", inlineMD(para)]; [para setString:@""]; }
            if (quote) { [out appendString:@"</blockquote>\n"]; quote = NO; }
            continue;
        }
        if ([t hasPrefix:@"#"]) {
            unsigned level = 0;
            while (level < [t length] && [t characterAtIndex:level] == '#') level++;
            if (level <= 6 && level < [t length] && [t characterAtIndex:level] == ' ') {
                if ([para length]) { [out appendFormat:@"<p>%@</p>\n", inlineMD(para)]; [para setString:@""]; }
                [out appendFormat:@"<h%u>%@</h%u>\n", level, inlineMD([t substringFromIndex:level + 1]), level];
                continue;
            }
        }
        if ([t isEqualToString:@"---"] || [t isEqualToString:@"***"] || [t isEqualToString:@"___"]) {
            if ([para length]) { [out appendFormat:@"<p>%@</p>\n", inlineMD(para)]; [para setString:@""]; }
            [out appendString:@"<hr>\n"];
            continue;
        }
        if ([t hasPrefix:@">"]) {
            if ([para length]) { [out appendFormat:@"<p>%@</p>\n", inlineMD(para)]; [para setString:@""]; }
            if (!quote) { [out appendString:@"<blockquote>"]; quote = YES; }
            [out appendFormat:@"%@<br>\n", inlineMD([[t substringFromIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]])];
            continue;
        }
        if ([t hasPrefix:@"|"] && i + 1 < [lines count] && [[lines objectAtIndex:i + 1] rangeOfString:@"---"].location != NSNotFound && [[lines objectAtIndex:i + 1] hasPrefix:@"|"]) {
            /* a table: header row, the dashes, then rows that start with | */
            unsigned j = i;
            BOOL head = YES;
            if ([para length]) { [out appendFormat:@"<p>%@</p>\n", inlineMD(para)]; [para setString:@""]; }
            [out appendString:@"<table>\n"];
            while (j < [lines count] && [[[lines objectAtIndex:j] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] hasPrefix:@"|"]) {
                NSString *row = [[lines objectAtIndex:j] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                NSArray *cells;
                unsigned c;
                if (j == i + 1) { j++; head = NO; continue; }
                if ([row hasPrefix:@"|"]) row = [row substringFromIndex:1];
                if ([row hasSuffix:@"|"]) row = [row substringToIndex:[row length] - 1];
                cells = [row componentsSeparatedByString:@"|"];
                [out appendString:@"<tr>"];
                for (c = 0; c < [cells count]; c++)
                    [out appendFormat:head ? @"<th>%@</th>" : @"<td>%@</td>", inlineMD([[cells objectAtIndex:c] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]])];
                [out appendString:@"</tr>\n"];
                j++;
            }
            [out appendString:@"</table>\n"];
            i = j - 1;
            continue;
        }
        if ([para length])
            [para appendString:@" "];
        [para appendString:t];
    }
    if ([para length]) [out appendFormat:@"<p>%@</p>\n", inlineMD(para)];
    if (list) [out appendFormat:@"</%@>\n", list];
    if (quote) [out appendString:@"</blockquote>\n"];
    if (code) [out appendString:@"</code></pre>\n"];
    return out;
}

/* a comma, semicolon or tab separated file as rows of cells (quotes and doubled quotes understood) */
static NSArray *csvRows(NSString *text, unsigned maxRows, unsigned *total)
{
    NSMutableArray *rows = [NSMutableArray array];
    NSMutableArray *row = [NSMutableArray array];
    NSMutableString *cell = [NSMutableString string];
    NSRange firstLine = [text rangeOfString:@"\n"];
    NSString *head = firstLine.location == NSNotFound ? text : [text substringToIndex:firstLine.location];
    unichar delimiter = ',';
    NSUInteger commas = [[head componentsSeparatedByString:@","] count], semis = [[head componentsSeparatedByString:@";"] count], tabs = [[head componentsSeparatedByString:@"\t"] count];
    BOOL quoted = NO;
    NSUInteger i, n = [text length];
    if (tabs > commas && tabs >= semis) delimiter = '\t';
    else if (semis > commas) delimiter = ';';
    *total = 0;
    for (i = 0; i < n; i++) {
        unichar c = [text characterAtIndex:i];
        if (quoted) {
            if (c == '"') {
                if (i + 1 < n && [text characterAtIndex:i + 1] == '"') { [cell appendString:@"\""]; i++; }
                else quoted = NO;
            } else
                [cell appendFormat:@"%C", c];
        } else if (c == '"' && [cell length] == 0)
            quoted = YES;
        else if (c == delimiter) {
            [row addObject:[[cell copy] autorelease]];
            [cell setString:@""];
        } else if (c == '\n' || c == '\r') {
            if (c == '\r' && i + 1 < n && [text characterAtIndex:i + 1] == '\n') i++;
            [row addObject:[[cell copy] autorelease]];
            [cell setString:@""];
            (*total)++;
            if ([rows count] < maxRows)
                [rows addObject:row];
            row = [NSMutableArray array];
        } else
            [cell appendFormat:@"%C", c];
        if ([rows count] >= maxRows && *total >= maxRows + 1000)
            break;
    }
    if ([cell length] || [row count]) {
        [row addObject:[[cell copy] autorelease]];
        (*total)++;
        if ([rows count] < maxRows)
            [rows addObject:row];
    }
    return rows;
}

static NSString *csvHTML(NSString *text)
{
    unsigned total = 0, r, c, columns = 0;
    NSArray *rows = csvRows(text, 300, &total);
    NSMutableString *out = [NSMutableString stringWithString:@"<table>\n"];
    for (r = 0; r < [rows count]; r++)
        if ([[rows objectAtIndex:r] count] > columns)
            columns = [[rows objectAtIndex:r] count];
    if (columns > 40) columns = 40;
    for (r = 0; r < [rows count]; r++) {
        NSArray *row = [rows objectAtIndex:r];
        [out appendString:@"<tr>"];
        for (c = 0; c < columns; c++) {
            NSString *v = c < [row count] ? [row objectAtIndex:c] : @"";
            if ([v length] > 200) v = [[v substringToIndex:200] stringByAppendingString:@"..."];
            [out appendFormat:r == 0 ? @"<th>%@</th>" : @"<td>%@</td>", esc(v)];
        }
        [out appendString:@"</tr>\n"];
    }
    [out appendString:@"</table>\n"];
    if (total > [rows count])
        [out appendFormat:@"<p class=\"note\">The first %u of %u rows.</p>", (unsigned)[rows count], total];
    return out;
}

static NSString *readText(CFURLRef url, NSUInteger limit)
{
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:[(NSURL *)url path]];
    NSData *data = [file readDataOfLength:limit];
    NSString *text = nil;
    unsigned trim;
    [file closeFile];
    if (!data)
        return nil;
    for (trim = 0; trim < 4 && !text && trim <= [data length]; trim++)
        text = [[[NSString alloc] initWithBytes:[data bytes] length:[data length] - trim encoding:NSUTF8StringEncoding] autorelease];
    if (!text)
        text = [[[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] autorelease];
    return text;
}

static void setHTML(QLPreviewRequestRef preview, NSString *html)
{
    NSDictionary *props = [NSDictionary dictionaryWithObjectsAndKeys:@"UTF-8", (NSString *)kQLPreviewPropertyTextEncodingNameKey, @"text/html", (NSString *)kQLPreviewPropertyMIMETypeKey, nil];
    QLPreviewRequestSetDataRepresentation(preview, (CFDataRef)[html dataUsingEncoding:NSUTF8StringEncoding], kUTTypeHTML, (CFDictionaryRef)props);
}

/* A JSON file as the text it is: the first 400,000 bytes, as UTF-8 (or Latin-1 when it is not). nil when it cannot be read. */
static NSString *jsonText(CFURLRef url)
{
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:[(NSURL *)url path]];
    NSData *data = [file readDataOfLength:400000];
    NSString *text = nil;
    unsigned trim;
    [file closeFile];
    if (!data)
        return nil;
    for (trim = 0; trim < 4 && !text && trim <= [data length]; trim++)   /* the cut may fall inside a UTF-8 character */
        text = [[[NSString alloc] initWithBytes:[data bytes] length:[data length] - trim encoding:NSUTF8StringEncoding] autorelease];
    if (!text)
        text = [[[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] autorelease];
    return text;
}

OSStatus GeneratePreviewForURL(void *thisInterface, QLPreviewRequestRef preview, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    if ([[[(NSURL *)url pathExtension] lowercaseString] isEqualToString:@"json"]) {
        NSString *text = jsonText(url);
        if (text) {
            NSDictionary *props = [NSDictionary dictionaryWithObjectsAndKeys:@"UTF-8", (NSString *)kQLPreviewPropertyTextEncodingNameKey, @"text/plain", (NSString *)kQLPreviewPropertyMIMETypeKey, nil];
            QLPreviewRequestSetDataRepresentation(preview, (CFDataRef)[text dataUsingEncoding:NSUTF8StringEncoding], kUTTypePlainText, (CFDictionaryRef)props);
        }
        [pool release];
        return noErr;
    }
    {
        NSString *ext = [[(NSURL *)url pathExtension] lowercaseString];
        if ([[NSArray arrayWithObjects:@"md", @"markdown", @"mdown", @"mkd", nil] containsObject:ext]) {
            NSString *t = readText(url, 400000);
            if (t) setHTML(preview, pageHTML(markdownHTML(t)));
            [pool release];
            return noErr;
        }
        if ([ext isEqualToString:@"csv"] || [ext isEqualToString:@"tsv"]) {
            NSString *t = readText(url, 600000);
            if (t) setHTML(preview, pageHTML(csvHTML(t)));
            [pool release];
            return noErr;
        }
    }
    NSDictionary *result = converted(url);
    NSArray *images = [result objectForKey:@"images"];
    NSString *text = [result objectForKey:@"text"];
    if ([images count] && !([[result objectForKey:@"textFirst"] boolValue] && [text length])) {
        QLPreviewRequestSetDataRepresentation(preview, (CFDataRef)[images objectAtIndex:0], kUTTypeJPEG, NULL);
    } else if ([text length]) {
        NSDictionary *props = [NSDictionary dictionaryWithObjectsAndKeys:@"UTF-8", (NSString *)kQLPreviewPropertyTextEncodingNameKey, @"text/plain", (NSString *)kQLPreviewPropertyMIMETypeKey, nil];
        if ([text length] > 400000)
            text = [text substringToIndex:400000];
        QLPreviewRequestSetDataRepresentation(preview, (CFDataRef)[text dataUsingEncoding:NSUTF8StringEncoding], kUTTypePlainText, (CFDictionaryRef)props);
    }
    [pool release];
    return noErr;
}

void CancelPreviewGeneration(void *thisInterface, QLPreviewRequestRef preview)
{
}

OSStatus GenerateThumbnailForURL(void *thisInterface, QLThumbnailRequestRef thumbnail, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options, CGSize maxSize)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    if ([[NSArray arrayWithObjects:@"json", @"md", @"markdown", @"mdown", @"mkd", @"csv", @"tsv", nil] containsObject:[[(NSURL *)url pathExtension] lowercaseString]]) {
        [pool release];
        return noErr;
    }
    NSDictionary *result = converted(url);
    NSArray *images = [result objectForKey:@"images"];
    if ([images count])
        QLThumbnailRequestSetImageWithData(thumbnail, (CFDataRef)[images objectAtIndex:0], NULL);
    [pool release];
    return noErr;   /* documents get their ordinary icon */
}

void CancelThumbnailGeneration(void *thisInterface, QLThumbnailRequestRef thumbnail)
{
}

/* ---- the plug-in's COM-style boilerplate ---- */

static HRESULT QueryInterfaceImpl(void *thisInstance, REFIID iid, LPVOID *ppv);
static ULONG AddRefImpl(void *thisInstance);
static ULONG ReleaseImpl(void *thisInstance);

static QLGeneratorInterfaceStruct interfaceTable = {
    NULL, QueryInterfaceImpl, AddRefImpl, ReleaseImpl,
    GenerateThumbnailForURL, CancelThumbnailGeneration, GeneratePreviewForURL, CancelPreviewGeneration
};

static TBQuickLookPlugin *allocate(CFUUIDRef factoryID)
{
    TBQuickLookPlugin *plugin = (TBQuickLookPlugin *)malloc(sizeof(TBQuickLookPlugin));
    plugin->conduit = &interfaceTable;
    plugin->factoryID = (CFUUIDRef)CFRetain(factoryID);
    plugin->references = 1;
    CFPlugInAddInstanceForFactory(factoryID);
    return plugin;
}

static void deallocate(TBQuickLookPlugin *plugin)
{
    CFUUIDRef factoryID = plugin->factoryID;
    free(plugin);
    if (factoryID) {
        CFPlugInRemoveInstanceForFactory(factoryID);
        CFRelease(factoryID);
    }
}

static HRESULT QueryInterfaceImpl(void *thisInstance, REFIID iid, LPVOID *ppv)
{
    CFUUIDRef wanted = CFUUIDCreateFromUUIDBytes(NULL, iid);
    TBQuickLookPlugin *plugin = (TBQuickLookPlugin *)thisInstance;
    if (CFEqual(wanted, kQLGeneratorCallbacksInterfaceID) || CFEqual(wanted, IUnknownUUID)) {
        plugin->references++;
        *ppv = thisInstance;
        CFRelease(wanted);
        return S_OK;
    }
    *ppv = NULL;
    CFRelease(wanted);
    return E_NOINTERFACE;
}

static ULONG AddRefImpl(void *thisInstance)
{
    return ++((TBQuickLookPlugin *)thisInstance)->references;
}

static ULONG ReleaseImpl(void *thisInstance)
{
    TBQuickLookPlugin *plugin = (TBQuickLookPlugin *)thisInstance;
    plugin->references--;
    if (plugin->references == 0) {
        deallocate(plugin);
        return 0;
    }
    return plugin->references;
}

void *TBQuickLookFactory(CFAllocatorRef allocator, CFUUIDRef typeID)
{
    if (CFEqual(typeID, kQLGeneratorTypeID))
        return allocate(PLUGIN_FACTORY);
    return NULL;
}
