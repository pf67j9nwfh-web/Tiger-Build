#import "TBLocalTools.h"
#import "TBEngine.h"
#import "TBHTTP.h"
#import "TBRun.h"
#import "TBExtract.h"
#import "TBSupport.h"
#import <AppKit/AppKit.h>
#import <sys/stat.h>
#import <unistd.h>
#import <stdlib.h>
#import <limits.h>
#import <fcntl.h>
#import <math.h>

/* ---- reading a web page ---- */

/* the text between <tag ...> and </tag> (case-insensitive) cut out of html */
static NSString *dropElement(NSString *html, NSString *tag)
{
    NSMutableString *out = [NSMutableString string];
    NSString *open = [@"<" stringByAppendingString:tag], *close = [[@"</" stringByAppendingString:tag] stringByAppendingString:@">"];
    NSUInteger at = 0, n = [html length];
    while (at < n) {
        NSRange o = [html rangeOfString:open options:NSCaseInsensitiveSearch range:NSMakeRange(at, n - at)], c;
        if (o.location == NSNotFound) {
            [out appendString:[html substringFromIndex:at]];
            break;
        }
        [out appendString:[html substringWithRange:NSMakeRange(at, o.location - at)]];
        c = [html rangeOfString:close options:NSCaseInsensitiveSearch range:NSMakeRange(o.location, n - o.location)];
        if (c.location == NSNotFound)
            break;
        at = NSMaxRange(c);
    }
    return out;
}

static NSString *decodeEntities(NSString *text)
{
    NSMutableString *out = [NSMutableString string];
    NSUInteger i, n = [text length];
    for (i = 0; i < n; i++) {
        unichar c = [text characterAtIndex:i];
        if (c == '&') {
            NSRange semi = [text rangeOfString:@";" options:0 range:NSMakeRange(i, n - i < 10 ? n - i : 10)];
            if (semi.location != NSNotFound) {
                NSString *name = [text substringWithRange:NSMakeRange(i + 1, semi.location - i - 1)];
                NSString *rep = nil;
                if ([name hasPrefix:@"#x"] || [name hasPrefix:@"#X"])
                    rep = [NSString stringWithFormat:@"%C", (unichar)strtol([[name substringFromIndex:2] UTF8String], NULL, 16)];
                else if ([name hasPrefix:@"#"])
                    rep = [NSString stringWithFormat:@"%C", (unichar)atoi([[name substringFromIndex:1] UTF8String])];
                else if ([name isEqualToString:@"amp"]) rep = @"&";
                else if ([name isEqualToString:@"lt"]) rep = @"<";
                else if ([name isEqualToString:@"gt"]) rep = @">";
                else if ([name isEqualToString:@"quot"]) rep = @"\"";
                else if ([name isEqualToString:@"apos"]) rep = @"'";
                else if ([name isEqualToString:@"nbsp"]) rep = @" ";
                else if ([name isEqualToString:@"ndash"]) rep = @"-";
                else if ([name isEqualToString:@"mdash"]) rep = @"-";
                else if ([name isEqualToString:@"hellip"]) rep = @"...";
                if (rep && [rep length] && [rep characterAtIndex:0] != 0) {
                    [out appendString:rep];
                    i = semi.location;
                    continue;
                }
            }
        }
        [out appendFormat:@"%C", c];
    }
    return out;
}

@implementation TBLocalTools

+ (NSString *)htmlToText:(NSString *)html
{
    NSMutableString *out = [NSMutableString string];
    NSArray *blocks = [NSArray arrayWithObjects:@"p", @"div", @"br", @"li", @"tr", @"h1", @"h2", @"h3", @"h4", @"h5", @"h6", @"section", @"article", @"header", @"footer", @"table", @"ul", @"ol", @"pre", @"blockquote", nil];
    NSUInteger i, n;
    BOOL inTag = NO;
    NSMutableString *tag = [NSMutableString string];
    NSRange commentStart;
    html = dropElement(html, @"script");
    html = dropElement(html, @"style");
    html = dropElement(html, @"noscript");
    html = dropElement(html, @"svg");
    /* comments */
    while ((commentStart = [html rangeOfString:@"<!--"]).location != NSNotFound) {
        NSRange end = [html rangeOfString:@"-->" options:0 range:NSMakeRange(commentStart.location, [html length] - commentStart.location)];
        html = [html stringByReplacingCharactersInRange:NSMakeRange(commentStart.location, end.location == NSNotFound ? [html length] - commentStart.location : NSMaxRange(end) - commentStart.location) withString:@""];
    }
    n = [html length];
    for (i = 0; i < n; i++) {
        unichar c = [html characterAtIndex:i];
        if (c == '<') {
            inTag = YES;
            [tag setString:@""];
        } else if (c == '>' && inTag) {
            NSString *name = [[tag lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/ "]];
            NSRange sp = [name rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (sp.location != NSNotFound)
                name = [name substringToIndex:sp.location];
            if ([blocks containsObject:name])
                [out appendString:@"\n"];
            inTag = NO;
        } else if (inTag) {
            if ([tag length] < 40)
                [tag appendFormat:@"%C", c];
        } else
            [out appendFormat:@"%C", c];
    }
    {
        NSString *text = decodeEntities(out);
        NSMutableArray *lines = [NSMutableArray array];
        NSArray *raw = [text componentsSeparatedByString:@"\n"];
        unsigned k;
        BOOL blank = NO;
        for (k = 0; k < [raw count]; k++) {
            NSString *line = TBTrim([raw objectAtIndex:k]);
            if ([line length] == 0) {
                if (!blank && [lines count])
                    [lines addObject:@""];
                blank = YES;
                continue;
            }
            blank = NO;
            [lines addObject:line];
        }
        return [lines componentsJoinedByString:@"\n"];
    }
}

+ (NSString *)readPage:(NSString *)address run:(TBRun *)run
{
    NSString *current = TBTrim(address ? address : @"");
    int hop;
    if (![[current lowercaseString] hasPrefix:@"https://"] && ![[current lowercaseString] hasPrefix:@"http://"])
        TBFail(@"Give a web address that starts with http:// or https://.");
    for (hop = 0; hop < 6; hop++) {
        TBHTTP *http = [TBHTTP request:@"GET" url:current];
        NSString *type, *text = nil, *title = nil;
        NSData *data;
        int result;
        [http setHeader:@"User-Agent" value:@"Mozilla/5.0 (compatible; TigerBuild; +https://github.com/pf67j9nwfh-web/Tiger-Build)"];
        [http setHeader:@"Accept" value:@"text/html,text/plain,application/json;q=0.9,*/*;q=0.5"];
        [http setPublicOnly:YES];
        [http setIdleTimeout:25];
        [run attach:http];
        result = [http perform];
        [run detach:http];
        [run check];
        if (result != TBNET_OK)
            TBFail(@"The page could not be loaded: %@", [http error]);
        if ([http status] >= 301 && [http status] <= 308 && [http status] != 304 && [[http responseHeader:@"Location"] length]) {
            NSURL *next = [NSURL URLWithString:[http responseHeader:@"Location"] relativeToURL:[NSURL URLWithString:current]];
            NSString *absolute = [[next absoluteURL] absoluteString];
            if ([[current lowercaseString] hasPrefix:@"https://"] && ![[absolute lowercaseString] hasPrefix:@"https://"])
                TBFail(@"The page redirected from https to plain http, which is not followed.");
            current = absolute;
            continue;
        }
        if ([http status] < 200 || [http status] >= 300)
            TBFail(@"The page answered HTTP %d.", [http status]);
        data = [http data];
        if ([data length] > 6 * 1024 * 1024)
            data = [data subdataWithRange:NSMakeRange(0, 6 * 1024 * 1024)];
        type = [[http responseHeader:@"Content-Type"] lowercaseString];
        if ([type length] && [type rangeOfString:@"text"].location == NSNotFound && [type rangeOfString:@"json"].location == NSNotFound && [type rangeOfString:@"xml"].location == NSNotFound)
            TBFail(@"That address is %@, not a page of text.", [type length] > 60 ? [type substringToIndex:60] : type);
        text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
        if (!text)
            text = [[[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] autorelease];
        if (!text)
            TBFail(@"The page could not be read as text.");
        if ([type rangeOfString:@"html"].location != NSNotFound || [[text substringToIndex:[text length] < 400 ? [text length] : 400] rangeOfString:@"<html" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            NSRange t = [text rangeOfString:@"<title" options:NSCaseInsensitiveSearch];
            if (t.location != NSNotFound) {
                NSRange gt = [text rangeOfString:@">" options:0 range:NSMakeRange(t.location, [text length] - t.location)];
                NSRange end = gt.location == NSNotFound ? gt : [text rangeOfString:@"</title" options:NSCaseInsensitiveSearch range:NSMakeRange(gt.location, [text length] - gt.location)];
                if (gt.location != NSNotFound && end.location != NSNotFound)
                    title = TBTrim(decodeEntities([text substringWithRange:NSMakeRange(gt.location + 1, end.location - gt.location - 1)]));
            }
            text = [self htmlToText:text];
        }
        if ([text length] > 40000)
            text = [[text substringToIndex:40000] stringByAppendingString:@"\n\n[The page goes on; only the first 40,000 characters are shown.]"];
        return [NSString stringWithFormat:@"%@%@\n\n%@", title ? [NSString stringWithFormat:@"Title: %@\n", title] : @"", [@"Address: " stringByAppendingString:current], text];
    }
    TBFail(@"Too many redirects.");
    return nil;
}

/* ---- the knowledge folder ---- */

static NSMutableDictionary *indexes = nil;   /* root -> {chunks, df, built, signature} */

static BOOL pathInside(NSString *path, NSString *root)
{
    char a[PATH_MAX], b[PATH_MAX];
    if (!realpath([path fileSystemRepresentation], a) || !realpath([root fileSystemRepresentation], b))
        return NO;
    return strcmp(a, b) == 0 || (strncmp(a, b, strlen(b)) == 0 && a[strlen(b)] == '/');
}

static NSArray *wordsOf(NSString *text)
{
    NSMutableArray *out = [NSMutableArray array];
    NSMutableString *w = [NSMutableString string];
    NSUInteger i, n = [text length];
    for (i = 0; i <= n; i++) {
        unichar c = i < n ? [text characterAtIndex:i] : ' ';
        if ([[NSCharacterSet alphanumericCharacterSet] characterIsMember:c]) {
            [w appendFormat:@"%C", c];
        } else if ([w length]) {
            if ([w length] > 1 && [w length] < 40)
                [out addObject:[w lowercaseString]];
            [w setString:@""];
        }
    }
    return out;
}

static NSString *textOfFile(NSString *path)
{
    NSString *ext = [[path pathExtension] lowercaseString];
    NSArray *plain = [NSArray arrayWithObjects:@"txt", @"md", @"markdown", @"rst", @"csv", @"tsv", @"json", @"xml", @"html", @"htm", @"yml", @"yaml", @"toml", @"ini", @"cfg", @"conf", @"log",
        @"c", @"h", @"m", @"mm", @"cpp", @"hpp", @"cc", @"py", @"js", @"ts", @"rb", @"sh", @"swift", @"java", @"go", @"rs", @"php", @"sql", @"tex", @"rtf", nil];
    NSData *data;
    if ([plain containsObject:ext] || [ext length] == 0) {
        NSString *text;
        if ([ext isEqualToString:@"rtf"]) {
            NSAttributedString *rich = [[[NSAttributedString alloc] initWithPath:path documentAttributes:NULL] autorelease];
            return [rich string];
        }
        data = [NSData dataWithContentsOfFile:path options:NSMappedRead error:NULL];
        if (!data || [data length] > 3 * 1024 * 1024)
            return nil;
        text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
        if (!text)
            text = [[[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] autorelease];
        if ([ext isEqualToString:@"html"] || [ext isEqualToString:@"htm"])
            text = [TBLocalTools htmlToText:text];
        /* a binary file with no extension is not text */
        if (text && [ext length] == 0 && [text rangeOfString:[NSString stringWithFormat:@"%C", (unichar)0]].location != NSNotFound)
            return nil;
        return text;
    }
    if ([ext isEqualToString:@"pdf"]) {
        Class pdfClass = NSClassFromString(@"PDFDocument");
        id doc;
        if (!pdfClass) {
            [[NSBundle bundleWithPath:@"/System/Library/Frameworks/Quartz.framework/Frameworks/PDFKit.framework"] load];
            pdfClass = NSClassFromString(@"PDFDocument");
        }
        if (!pdfClass)
            return nil;
        @try {
            doc = [[[pdfClass alloc] initWithURL:[NSURL fileURLWithPath:path]] autorelease];
            return [doc string];
        } @catch (NSException *e) {
            return nil;
        }
    }
    if ([[NSArray arrayWithObjects:@"docx", @"xlsx", @"pptx", @"doc", @"xls", @"ppt", @"odt", @"ods", @"odp", @"pages", @"numbers", @"key", @"epub", nil] containsObject:ext]) {
        NSDictionary *got;
        data = [NSData dataWithContentsOfFile:path options:NSMappedRead error:NULL];
        if (!data || [data length] > 40 * 1024 * 1024)
            return nil;
        @try {
            got = [TBExtract extractName:[path lastPathComponent] data:data];
        } @catch (NSException *e) {
            return nil;
        }
        return [got objectForKey:@"text"];
    }
    return nil;
}

/* every file under root that this can read, with how it looks right now */
static NSArray *knowledgeFiles(NSString *root, NSString **signature)
{
    NSMutableArray *files = [NSMutableArray array];
    NSDirectoryEnumerator *walk = [[NSFileManager defaultManager] enumeratorAtPath:root];
    NSString *relative;
    double newest = 0, total = 0;
    while ((relative = [walk nextObject]) && [files count] < 2500) {
        NSString *name = [relative lastPathComponent];
        NSDictionary *attrs;
        if ([name hasPrefix:@"."]) {
            [walk skipDescendents];
            continue;
        }
        attrs = [walk fileAttributes];
        if ([[attrs objectForKey:NSFileType] isEqualToString:NSFileTypeSymbolicLink]) {
            [walk skipDescendents];
            continue;
        }
        if (![[attrs objectForKey:NSFileType] isEqualToString:NSFileTypeRegular])
            continue;
        [files addObject:relative];
        total += [[attrs objectForKey:NSFileSize] doubleValue];
        if ([[attrs objectForKey:NSFileModificationDate] timeIntervalSince1970] > newest)
            newest = [[attrs objectForKey:NSFileModificationDate] timeIntervalSince1970];
    }
    *signature = [NSString stringWithFormat:@"%u|%.0f|%.0f", (unsigned)[files count], total, newest];
    return files;
}

+ (NSDictionary *)indexForRoot:(NSString *)root
{
    NSString *signature = nil;
    NSDictionary *have;
    NSArray *files;
    NSMutableArray *chunks = [NSMutableArray array];
    NSMutableDictionary *df = [NSMutableDictionary dictionary];
    unsigned f, skipped = 0;
    double started = [NSDate timeIntervalSinceReferenceDate];
    @synchronized(self) {
        if (!indexes)
            indexes = [[NSMutableDictionary alloc] init];
        have = [[[indexes objectForKey:root] retain] autorelease];
    }
    if (have && [NSDate timeIntervalSinceReferenceDate] - [[have objectForKey:@"checked"] doubleValue] < 30)
        return have;
    files = knowledgeFiles(root, &signature);
    if (have && [[have objectForKey:@"signature"] isEqualToString:signature]) {
        NSMutableDictionary *same = [NSMutableDictionary dictionaryWithDictionary:have];
        [same setObject:[NSNumber numberWithDouble:[NSDate timeIntervalSinceReferenceDate]] forKey:@"checked"];
        @synchronized(self) { [indexes setObject:same forKey:root]; }
        return same;
    }
    for (f = 0; f < [files count]; f++) {
        NSString *relative = [files objectAtIndex:f];
        NSString *text = textOfFile([root stringByAppendingPathComponent:relative]);
        NSArray *paras;
        NSMutableString *piece = [NSMutableString string];
        unsigned p;
        if ([NSDate timeIntervalSinceReferenceDate] - started > 240)
            break;   /* a very large folder: what is indexed so far is used */
        if (![text length]) {
            skipped++;
            continue;
        }
        if ([text length] > 400000)
            text = [text substringToIndex:400000];
        paras = [text componentsSeparatedByString:@"\n"];
        for (p = 0; p <= [paras count]; p++) {
            NSString *line = p < [paras count] ? [paras objectAtIndex:p] : nil;
            if (line && [piece length] + [line length] < 1200) {
                [piece appendFormat:@"%@\n", line];
                continue;
            }
            if ([TBTrim(piece) length] > 20) {
                NSArray *words = wordsOf([relative stringByAppendingFormat:@" %@", piece]);
                NSCountedSet *counts = [NSCountedSet setWithArray:words];
                NSEnumerator *each = [[counts allObjects] objectEnumerator];
                NSString *w;
                while ((w = [each nextObject]))
                    [df setObject:[NSNumber numberWithInt:[[df objectForKey:w] intValue] + 1] forKey:w];
                [chunks addObject:[NSDictionary dictionaryWithObjectsAndKeys:relative, @"file", [[piece copy] autorelease], @"text", counts, @"counts", [NSNumber numberWithUnsignedInt:(unsigned)[words count]], @"length", nil]];
            }
            [piece setString:line ? [NSString stringWithFormat:@"%@\n", line] : @""];
        }
    }
    {
        NSDictionary *built = [NSDictionary dictionaryWithObjectsAndKeys:chunks, @"chunks", df, @"df", signature, @"signature", [NSNumber numberWithUnsignedInt:(unsigned)[files count]], @"files",
            [NSNumber numberWithUnsignedInt:skipped], @"skipped", [NSNumber numberWithDouble:[NSDate timeIntervalSinceReferenceDate]], @"checked", nil];
        @synchronized(self) { [indexes setObject:built forKey:root]; }
        return built;
    }
}

+ (NSString *)knowledgeSearch:(NSString *)query root:(NSString *)root
{
    NSDictionary *index;
    NSArray *chunks, *terms;
    NSDictionary *df;
    NSMutableArray *scored = [NSMutableArray array];
    NSMutableString *out = [NSMutableString string];
    double n;
    unsigned i, shown = 0;
    BOOL isDir = NO;
    if (![root length] || ![[NSFileManager defaultManager] fileExistsAtPath:root isDirectory:&isDir] || !isDir)
        TBFail(@"This workspace has no knowledge folder, or it is not on this Mac.");
    if (![query isKindOfClass:[NSString class]] || ![TBTrim(query) length])
        TBFail(@"Give words to look for.");
    index = [self indexForRoot:root];
    chunks = [index objectForKey:@"chunks"];
    df = [index objectForKey:@"df"];
    n = [chunks count];
    if (n == 0)
        return [NSString stringWithFormat:@"The knowledge folder has %@ files, but none could be read as text.", [index objectForKey:@"files"]];
    terms = wordsOf(query);
    if (![terms count])
        TBFail(@"Give words to look for.");
    for (i = 0; i < [chunks count]; i++) {
        NSDictionary *chunk = [chunks objectAtIndex:i];
        NSCountedSet *counts = [chunk objectForKey:@"counts"];
        double score = 0, length = [[chunk objectForKey:@"length"] doubleValue] + 20;
        unsigned t;
        for (t = 0; t < [terms count]; t++) {
            NSString *w = [terms objectAtIndex:t];
            unsigned tf = (unsigned)[counts countForObject:w];
            double d;
            if (!tf)
                continue;
            d = [[df objectForKey:w] doubleValue];
            score += (tf / (tf + 1.2 + 0.75 * length / 120.0)) * log((n + 1) / (d + 0.5)) * 2.2;
        }
        if (score > 0)
            [scored addObject:[NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithDouble:score], @"score", chunk, @"chunk", nil]];
    }
    [scored sortUsingDescriptors:[NSArray arrayWithObject:[[[NSSortDescriptor alloc] initWithKey:@"score" ascending:NO] autorelease]]];
    for (i = 0; i < [scored count] && shown < 6; i++) {
        NSDictionary *chunk = [[scored objectAtIndex:i] objectForKey:@"chunk"];
        NSString *text = TBTrim([chunk objectForKey:@"text"]);
        if ([text length] > 900)
            text = [[text substringToIndex:900] stringByAppendingString:@" ..."];
        [out appendFormat:@"[%u] %@\n%@\n\n", shown + 1, [chunk objectForKey:@"file"], text];
        shown++;
    }
    if (!shown)
        return @"Nothing in the knowledge folder matches those words. Try other words.";
    [out appendFormat:@"(%u files in the folder; use knowledge_open with a file path above to read a whole file.)", [[index objectForKey:@"files"] unsignedIntValue]];
    return out;
}

+ (NSString *)knowledgeOpen:(NSString *)path root:(NSString *)root
{
    NSString *full, *text;
    BOOL isDir = NO;
    if (![root length] || ![[NSFileManager defaultManager] fileExistsAtPath:root isDirectory:&isDir] || !isDir)
        TBFail(@"This workspace has no knowledge folder, or it is not on this Mac.");
    if (![path isKindOfClass:[NSString class]] || ![path length] || [path hasPrefix:@"/"] || [path rangeOfString:@".."].location != NSNotFound)
        TBFail(@"Give a path inside the knowledge folder, as search results show it.");
    full = [root stringByAppendingPathComponent:path];
    if (![[NSFileManager defaultManager] fileExistsAtPath:full] || !pathInside(full, root))
        TBFail(@"That file is not in the knowledge folder.");
    text = textOfFile(full);
    if (![text length])
        TBFail(@"That file could not be read as text.");
    if ([text length] > 30000)
        text = [[text substringToIndex:30000] stringByAppendingString:@"\n\n[The file goes on; only the first 30,000 characters are shown.]"];
    return text;
}

/* ---- Calendar, Contacts and Mail ---- */

+ (BOOL)isMacAppsTool:(NSString *)name
{
    return [name isEqualToString:@"mac_calendar_events"] || [name isEqualToString:@"mac_contacts_search"] || [name isEqualToString:@"mac_mail_unread"];
}

static NSString *runScript(NSString *script, NSArray *args, int seconds, NSString **failure)
{
    NSTask *task = [[[NSTask alloc] init] autorelease];
    NSPipe *out = [NSPipe pipe], *err = [NSPipe pipe];
    NSMutableArray *arguments = [NSMutableArray arrayWithObjects:@"-e", script, nil];
    NSMutableData *got = [NSMutableData data], *bad = [NSMutableData data];
    double deadline = [NSDate timeIntervalSinceReferenceDate] + seconds;
    [arguments addObjectsFromArray:args];
    [task setLaunchPath:@"/usr/bin/osascript"];
    [task setArguments:arguments];
    [task setStandardOutput:out];
    [task setStandardError:err];
    [task setStandardInput:[NSFileHandle fileHandleWithNullDevice]];
    @try {
        [task launch];
    } @catch (NSException *e) {
        *failure = @"AppleScript could not be started.";
        return nil;
    }
    {
        int fdo = [[out fileHandleForReading] fileDescriptor], fde = [[err fileHandleForReading] fileDescriptor];
        fcntl(fdo, F_SETFL, fcntl(fdo, F_GETFL, 0) | O_NONBLOCK);
        fcntl(fde, F_SETFL, fcntl(fde, F_GETFL, 0) | O_NONBLOCK);
        while ([task isRunning] || 1) {
            char buffer[8192];
            ssize_t r;
            BOOL any = NO;
            while ((r = read(fdo, buffer, sizeof buffer)) > 0) { [got appendBytes:buffer length:r]; any = YES; }
            while ((r = read(fde, buffer, sizeof buffer)) > 0) { [bad appendBytes:buffer length:r]; any = YES; }
            if (![task isRunning] && !any)
                break;
            if ([NSDate timeIntervalSinceReferenceDate] > deadline) {
                [task terminate];
                *failure = @"The application took too long to answer.";
                return nil;
            }
            if (!any)
                usleep(50000);
            if ([got length] > 400000)
                break;
        }
    }
    if ([task isRunning])
        [task terminate];
    if ([task terminationStatus] != 0 && [got length] == 0) {
        NSString *why = [[[NSString alloc] initWithData:bad encoding:NSUTF8StringEncoding] autorelease];
        *failure = [why length] ? TBTrim(why) : @"AppleScript reported an error.";
        return nil;
    }
    return [[[NSString alloc] initWithData:got encoding:NSUTF8StringEncoding] autorelease];
}

+ (NSString *)macAppsTool:(NSString *)name arguments:(NSDictionary *)args
{
    NSString *failure = nil, *text = nil;
    if ([name isEqualToString:@"mac_calendar_events"]) {
        int days = TBInteger(args, @"days") > 0 ? (int)TBInteger(args, @"days") : 7, back = TBInteger(args, @"days_back") > 0 ? (int)TBInteger(args, @"days_back") : 0;
        NSString *script =
            @"on run argv\n"
            @"set aheadDays to (item 1 of argv) as integer\n"
            @"set backDays to (item 2 of argv) as integer\n"
            @"set s to (current date) - backDays * days\n"
            @"set time of s to 0\n"
            @"set e to (current date) + aheadDays * days\n"
            @"set out to \"\"\n"
            @"tell application \"iCal\"\n"
            @"repeat with c in calendars\n"
            @"set evs to (every event of c whose start date >= s and start date <= e)\n"
            @"repeat with ev in evs\n"
            @"set loc to \"\"\n"
            @"try\n"
            @"set loc to location of ev\n"
            @"end try\n"
            @"if loc is missing value then set loc to \"\"\n"
            @"set out to out & (start date of ev as string) & \" | \" & (summary of ev) & \" | \" & (title of c) & \" | \" & loc & linefeed\n"
            @"end repeat\n"
            @"end repeat\n"
            @"end tell\n"
            @"return out\n"
            @"end run";
        if (days > 60) days = 60;
        if (back > 30) back = 30;
        text = runScript(script, [NSArray arrayWithObjects:[NSString stringWithFormat:@"%d", days], [NSString stringWithFormat:@"%d", back], nil], 60, &failure);
        if (!text)
            TBFail(@"Calendar could not be read: %@", failure);
        return [TBTrim(text) length] ? [@"Start | Title | Calendar | Location\n" stringByAppendingString:text] : @"No events in that period.";
    }
    if ([name isEqualToString:@"mac_contacts_search"]) {
        NSString *query = TBString(args, @"query");
        NSString *script =
            @"on run argv\n"
            @"set q to item 1 of argv\n"
            @"set out to \"\"\n"
            @"tell application \"Address Book\"\n"
            @"set ps to (every person whose name contains q)\n"
            @"set n to count of ps\n"
            @"if n > 15 then set n to 15\n"
            @"repeat with i from 1 to n\n"
            @"set p to item i of ps\n"
            @"set theLine to name of p\n"
            @"try\n"
            @"if organization of p is not missing value then set theLine to theLine & \" (\" & organization of p & \")\"\n"
            @"end try\n"
            @"repeat with m in emails of p\n"
            @"set theLine to theLine & \" | \" & (value of m)\n"
            @"end repeat\n"
            @"repeat with ph in phones of p\n"
            @"set theLine to theLine & \" | \" & (value of ph)\n"
            @"end repeat\n"
            @"set out to out & theLine & linefeed\n"
            @"end repeat\n"
            @"end tell\n"
            @"return out\n"
            @"end run";
        if (![TBTrim(query) length] || [query length] > 100)
            TBFail(@"Give part of a name to look for.");
        text = runScript(script, [NSArray arrayWithObject:query], 40, &failure);
        if (!text)
            TBFail(@"Contacts could not be read: %@", failure);
        return [TBTrim(text) length] ? text : @"No contact has that in its name.";
    }
    if ([name isEqualToString:@"mac_mail_unread"]) {
        NSString *script =
            @"on run argv\n"
            @"set out to \"\"\n"
            @"tell application \"Mail\"\n"
            @"set msgs to (messages of inbox whose read status is false)\n"
            @"set n to count of msgs\n"
            @"if n > 20 then set n to 20\n"
            @"repeat with i from 1 to n\n"
            @"set m to item i of msgs\n"
            @"set out to out & (date received of m as string) & \" | \" & (sender of m) & \" | \" & (subject of m) & linefeed\n"
            @"end repeat\n"
            @"set total to count of (messages of inbox whose read status is false)\n"
            @"end tell\n"
            @"return (total as string) & \" unread in the inbox; the newest \" & n & \":\" & linefeed & out\n"
            @"end run";
        text = runScript(script, [NSArray array], 90, &failure);
        if (!text)
            TBFail(@"Mail could not be read: %@", failure);
        return text;
    }
    TBFail(@"Unknown tool.");
    return nil;
}

@end
