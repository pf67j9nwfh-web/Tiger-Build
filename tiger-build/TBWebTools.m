#import <AppKit/AppKit.h>
#import "TBWebTools.h"
#import "TBEngine.h"
#import "TBHTTP.h"
#import "TBJSON.h"
#import "TBSupport.h"
#import "TBOutputs.h"
#import "TBMedia.h"
#import "TBIntegrations.h"
#import "mbedtls/sha256.h"
#include <time.h>

static NSString *const webAgent = @"TigerBuild/2.7 (Tiger Build; https://github.com/pf67j9nwfh-web/Tiger-Build)";


/* keeps what a request sends, and stops it when it grows past the limit. With a file open, a good answer goes straight to the file
   (never all in memory) and is summed as it arrives. */
@interface TBWebSink : NSObject {
@public
    NSMutableData *bytes;
    unsigned long limit;
    BOOL tooBig;
    FILE *file;
    unsigned long written;
    BOOL writeFailed;
    mbedtls_sha256_context sum;
}
@end

@implementation TBWebSink
- (id)init
{
    self = [super init];
    bytes = [[NSMutableData alloc] init];
    return self;
}
- (void)dealloc
{
    if (file)
        fclose(file);
    [bytes release];
    [super dealloc];
}
- (BOOL)http:(TBHTTP *)http gotData:(NSData *)data
{
    if (file && [http status] >= 200 && [http status] < 300) {
        if (written + [data length] > limit) {
            tooBig = YES;
            return YES;
        }
        if (fwrite([data bytes], 1, [data length], file) != [data length]) {
            writeFailed = YES;
            return YES;
        }
        mbedtls_sha256_update(&sum, [data bytes], [data length]);
        written += [data length];
        return NO;
    }
    /* an answer that is not kept: an error page or a redirect is read, but only the start of it */
    if (file) {
        if ([bytes length] < 200000)
            [bytes appendData:data];
        return NO;
    }
    if ([bytes length] + [data length] > limit) {
        tooBig = YES;
        return YES;
    }
    [bytes appendData:data];
    return NO;
}
@end

/* Videos from X have composition offsets (ctts) in the newer signed form, which QuickTime before Mac OS X 10.7 refuses ("invalid public movie atom"). The same table in the old form, shifted so no offset is negative, plays; the shift is a few thousandths of a second. */
static unsigned be32(const unsigned char *p) { return ((unsigned)p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3]; }
static void put32(unsigned char *p, unsigned v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }

static void fixOffsets(unsigned char *b, unsigned long start, unsigned long end)
{
    unsigned long at = start;
    while (at + 8 <= end) {
        unsigned size = be32(b + at);
        const unsigned char *type = b + at + 4;
        if (size < 8 || at + size > end)
            return;
        if (!memcmp(type, "moov", 4) || !memcmp(type, "trak", 4) || !memcmp(type, "mdia", 4) || !memcmp(type, "minf", 4) || !memcmp(type, "stbl", 4))
            fixOffsets(b, at + 8, at + size);
        else if (!memcmp(type, "ctts", 4) && size >= 16 && b[at + 8] == 1) {
            unsigned count = be32(b + at + 12), k;
            int lowest = 0;
            if (16 + 8UL * count > size)
                return;
            for (k = 0; k < count; k++) {
                int offset = (int)be32(b + at + 16 + 8 * k + 4);
                if (offset < lowest)
                    lowest = offset;
            }
            for (k = 0; k < count; k++)
                put32(b + at + 16 + 8 * k + 4, (unsigned)((int)be32(b + at + 16 + 8 * k + 4) - lowest));
            b[at + 8] = 0;
        }
        at += size;
    }
}

static NSData *playableOnOldQuickTime(NSData *mp4)
{
    NSMutableData *copy;
    if ([mp4 length] < 32 || memcmp((const char *)[mp4 bytes] + 4, "ftyp", 4))
        return mp4;
    copy = [NSMutableData dataWithData:mp4];
    fixOffsets([copy mutableBytes], 0, [copy length]);
    return copy;
}

static NSString *replaceAll(NSString *text, NSString *from, NSString *to)
{
    return [[text componentsSeparatedByString:from] componentsJoinedByString:to];
}

/* ---- one request, with redirects followed by hand so every address is checked ---- */

/* {status, data, type, headers, url}. Sign-in headers are not sent on to another host. */
static NSDictionary *webRequestSaving(NSString *method, NSString *url, NSArray *headers, NSData *body, BOOL follow, int timeout, TBRun *run, NSString *savePart)
{
    NSString *current = url;
    int hop;
    for (hop = 0; hop < 8; hop++) {
        NSURL *parsed = [NSURL URLWithString:current];
        NSString *scheme = [[parsed scheme] lowercaseString];
        TBHTTP *http;
        TBWebSink *sink = [[[TBWebSink alloc] init] autorelease];
        int result, code;
        unsigned i;
        BOOL sameHost = [[[parsed host] lowercaseString] isEqualToString:[[[NSURL URLWithString:url] host] lowercaseString]];
        if (!parsed || !([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) || ![[parsed host] length])
            TBFail(@"Give a full address starting with http:// or https://.");
        http = [TBHTTP request:method url:current];
        [http setPublicOnly:![[NSUserDefaults standardUserDefaults] boolForKey:@"TBAllowLocalPictures"]];
        for (i = 0; i + 1 < [headers count]; i += 2) {
            NSString *name = [headers objectAtIndex:i];
            if (!sameHost && ([[name lowercaseString] isEqualToString:@"authorization"] || [[name lowercaseString] isEqualToString:@"cookie"]))
                continue;
            [http setHeader:name value:[headers objectAtIndex:i + 1]];
        }
        [http setHeader:@"User-Agent" value:webAgent];
        if (body)
            [http setBody:body];
        [http setIdleTimeout:timeout];
        sink->limit = [TBIntegrations downloadLimit];
        if (savePart) {
            sink->file = fopen([savePart fileSystemRepresentation], "wb");
            if (!sink->file)
                TBFail(@"Cannot write %@.", savePart);
            mbedtls_sha256_init(&sink->sum);
            mbedtls_sha256_starts(&sink->sum, 0);
        }
        [http setDelegate:sink];
        [run attach:http];
        result = [http perform];
        [run detach:http];
        [run check];
        if (sink->tooBig)
            TBFail(@"The response is larger than %lu MB, the limit in Tool Settings (Built-in Tools, Web Search).", [TBIntegrations downloadLimit] / (1024UL * 1024UL));
        if (sink->writeFailed)
            TBFail(@"The file could not be written (is the disk full?).");
        if (result != TBNET_OK)
            TBFail(@"%@", [http error]);
        code = [http status];
        if (follow && code >= 301 && code <= 308 && code != 304 && [[http responseHeader:@"Location"] length]) {
            current = [[NSURL URLWithString:[http responseHeader:@"Location"] relativeToURL:parsed] absoluteString];
            if (code <= 303 && ![method isEqualToString:@"HEAD"]) {
                method = @"GET";
                body = nil;
            }
            continue;
        }
        {
            NSMutableDictionary *done = [NSMutableDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:code], @"status", sink->bytes, @"data",
                [http responseHeader:@"Content-Type"] ? [http responseHeader:@"Content-Type"] : @"", @"type", [http allResponseHeaders], @"headers", current, @"url", nil];
            if (sink->file && code >= 200 && code < 300) {
                unsigned char digest[32];
                NSMutableString *hex = [NSMutableString string];
                int d;
                fclose(sink->file);
                sink->file = NULL;
                mbedtls_sha256_finish(&sink->sum, digest);
                for (d = 0; d < 32; d++)
                    [hex appendFormat:@"%02x", digest[d]];
                [done setObject:[NSNumber numberWithUnsignedLong:sink->written] forKey:@"written"];
                [done setObject:hex forKey:@"sha256"];
            }
            return done;
        }
    }
    TBFail(@"Too many redirects.");
    return nil;
}

static BOOL looksLikeText(NSData *data, NSString *type)
{
    NSString *t = [type lowercaseString];
    const unsigned char *b = [data bytes];
    unsigned long n = [data length] < 2000 ? [data length] : 2000, i;
    if ([t hasPrefix:@"text/"] || [t rangeOfString:@"json"].location != NSNotFound || [t rangeOfString:@"xml"].location != NSNotFound
        || [t rangeOfString:@"javascript"].location != NSNotFound || [t rangeOfString:@"yaml"].location != NSNotFound || [t hasPrefix:@"application/x-www-form"])
        return YES;
    if ([t hasPrefix:@"image/"] || [t hasPrefix:@"video/"] || [t hasPrefix:@"audio/"] || [t rangeOfString:@"zip"].location != NSNotFound || [t rangeOfString:@"pdf"].location != NSNotFound)
        return NO;
    for (i = 0; i < n; i++)
        if (b[i] == 0)
            return NO;
    return [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease] != nil;
}

static NSString *textOf(NSData *data)
{
    NSString *text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    return text ? text : [[[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] autorelease];
}

static NSString *hexSHA256(NSData *data)
{
    unsigned char digest[32];
    NSMutableString *hex = [NSMutableString string];
    int i;
    mbedtls_sha256([data bytes], [data length], digest, 0);
    for (i = 0; i < 32; i++)
        [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

/* "Name: value" lines, or an object of names and values, as the list name, value, name, value ... */
static NSArray *headerList(id given)
{
    NSMutableArray *list = [NSMutableArray array];
    NSArray *banned = [NSArray arrayWithObjects:@"host", @"content-length", @"connection", @"accept-encoding", @"transfer-encoding", @"user-agent", nil];
    NSMutableArray *pairs = [NSMutableArray array];
    unsigned i;
    if ([given isKindOfClass:[NSDictionary class]]) {
        NSArray *keys = [given allKeys];
        for (i = 0; i < [keys count]; i++)
            [pairs addObject:[NSArray arrayWithObjects:[keys objectAtIndex:i], [[given objectForKey:[keys objectAtIndex:i]] description], nil]];
    } else if ([given isKindOfClass:[NSArray class]]) {
        for (i = 0; i < [given count]; i++)
            [pairs addObject:[[given objectAtIndex:i] description]];
    } else if ([given isKindOfClass:[NSString class]]) {
        NSArray *lines = [replaceAll(given, @"\r", @"") componentsSeparatedByString:@"\n"];
        for (i = 0; i < [lines count]; i++)
            [pairs addObject:[lines objectAtIndex:i]];
    }
    for (i = 0; i < [pairs count]; i++) {
        id pair = [pairs objectAtIndex:i];
        NSString *name, *value;
        if ([pair isKindOfClass:[NSArray class]]) {
            name = [pair objectAtIndex:0];
            value = [pair objectAtIndex:1];
        } else {
            NSRange colon = [pair rangeOfString:@":"];
            if (colon.location == NSNotFound) {
                if ([TBTrim(pair) length])
                    TBFail(@"A header must look like 'Name: value'. Got '%@'.", pair);
                continue;
            }
            name = [pair substringToIndex:colon.location];
            value = [pair substringFromIndex:colon.location + 1];
        }
        name = TBTrim(name);
        value = TBTrim(value);
        if (![name length] || [name rangeOfString:@" "].location != NSNotFound || [name rangeOfString:@"\n"].location != NSNotFound || [value rangeOfString:@"\n"].location != NSNotFound || [value rangeOfString:@"\r"].location != NSNotFound)
            TBFail(@"The header '%@' is not valid.", name);
        if ([banned containsObject:[name lowercaseString]])
            continue;
        [list addObject:name];
        [list addObject:value];
    }
    return list;
}

static int intArg(NSDictionary *args, NSString *key, int fallback, int low, int high)
{
    id v = TBValue(args, key);
    int n = [v isKindOfClass:[NSNumber class]] ? [v intValue] : ([v isKindOfClass:[NSString class]] && [v length] ? [v intValue] : fallback);
    return n < low ? low : (n > high ? high : n);
}

static BOOL flagArg(NSDictionary *args, NSString *key, BOOL fallback)
{
    id v = TBValue(args, key);
    if ([v isKindOfClass:[NSNumber class]])
        return [v boolValue];
    if ([v isKindOfClass:[NSString class]]) {
        NSString *s = [v lowercaseString];
        if ([s isEqualToString:@"true"] || [s isEqualToString:@"yes"] || [s isEqualToString:@"1"])
            return YES;
        if ([s isEqualToString:@"false"] || [s isEqualToString:@"no"] || [s isEqualToString:@"0"])
            return NO;
    }
    return fallback;
}

static NSDictionary *answer(NSString *output, NSArray *media)
{
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithObjectsAndKeys:output, @"output", nil];
    if ([media count])
        [d setObject:[media componentsJoinedByString:@"\n"] forKey:@"media"];
    return d;
}

static NSString *fileNameFor(NSString *url, NSString *type, NSString *asked)
{
    NSString *name = TBTrim(asked);
    if (![name length])
        name = [[[NSURL URLWithString:url] path] lastPathComponent];
    if (![name length] || [name isEqualToString:@"/"])
        name = [type hasPrefix:@"image/"] ? @"picture" : @"download";
    return name;
}

static NSDictionary *webRequest(NSString *method, NSString *url, NSArray *headers, NSData *body, BOOL follow, int timeout, TBRun *run)
{
    return webRequestSaving(method, url, headers, body, follow, timeout, run, nil);
}

/* ---- curl ---- */

/* where output_path points: the absolute path, a folder getting the name of the file in the address, and never somewhere the system or a login depends on */
static NSString *savePathFor(NSString *given, NSString *url, BOOL overwrite)
{
    NSString *path = [TBTrim(given) stringByExpandingTildeInPath], *lower, *parent;
    BOOL isFolder = NO;
    NSFileManager *files = [NSFileManager defaultManager];
    NSArray *system = [NSArray arrayWithObjects:@"/system/", @"/usr/", @"/bin/", @"/sbin/", @"/etc/", @"/private/etc/", @"/private/var/db/", @"/library/startupitems/", nil];
    NSArray *anywhere = [NSArray arrayWithObjects:@"/.ssh/", @"/library/keychains/", @"/library/launchagents/", @"/library/launchdaemons/", nil];
    unsigned i;
    if (![path hasPrefix:@"/"])
        TBFail(@"output_path must be a full path (starting with / or ~/), for example ~/Downloads/report.pdf.");
    if ([files fileExistsAtPath:path isDirectory:&isFolder] && isFolder)
        path = [path stringByAppendingPathComponent:fileNameFor(url, @"", nil)];
    else if ([path hasSuffix:@"/"])
        TBFail(@"output_path is a folder that does not exist; give a file path, or an existing folder.");
    path = [path stringByStandardizingPath];
    lower = [[path stringByAppendingString:@"/"] lowercaseString];
    for (i = 0; i < [system count]; i++)
        if ([lower hasPrefix:[system objectAtIndex:i]])
            TBFail(@"Saving there is not allowed (%@).", [system objectAtIndex:i]);
    for (i = 0; i < [anywhere count]; i++)
        if ([lower rangeOfString:[anywhere objectAtIndex:i]].location != NSNotFound)
            TBFail(@"Saving there is not allowed (a folder named %@).", [anywhere objectAtIndex:i]);
    if (!overwrite && [files fileExistsAtPath:path])
        TBFail(@"%@ already exists. Pick another name, or set overwrite to true to replace it.", path);
    parent = [path stringByDeletingLastPathComponent];
    TBMakePath(parent);
    return path;
}

static NSDictionary *curlCall(NSDictionary *args, TBRun *run, BOOL allowSave)
{
    NSString *url = TBTrim(TBString(args, @"url")), *method = [TBTrim(TBString(args, @"method")) uppercaseString];
    id dataArg = TBValue(args, @"data");
    NSString *dataText = nil;
    NSData *body = nil;
    NSMutableArray *headers;
    NSDictionary *got = nil;
    NSData *data;
    NSString *type, *statusLine, *finalURL, *saveAs = TBString(args, @"save_as");
    NSMutableString *out = [NSMutableString string];
    int code, maxChars = intArg(args, @"max_chars", 20000, 500, 200000);
    NSString *outPath = TBTrim(TBString(args, @"output_path")), *part = nil, *target = nil;
    BOOL wantHeaders = flagArg(args, @"include_headers", NO), follow = flagArg(args, @"follow_redirects", YES), save = flagArg(args, @"save", NO) || [TBTrim(saveAs) length] > 0;
    unsigned i;
    BOOL hasType = NO;
    if (![url length] || [url length] > 4000)
        TBFail(@"Give the address to fetch in 'url', for example https://example.com/data.json.");
    if (![url rangeOfString:@"://"].length)
        url = [@"https://" stringByAppendingString:url];
    if (dataArg && ![dataArg isKindOfClass:[NSString class]])
        dataText = TBJSONString(dataArg);
    else if ([dataArg length])
        dataText = dataArg;
    if (![method length])
        method = dataText ? @"POST" : @"GET";
    if (![[NSArray arrayWithObjects:@"GET", @"POST", @"PUT", @"PATCH", @"DELETE", @"HEAD", nil] containsObject:method])
        TBFail(@"method must be GET, POST, PUT, PATCH, DELETE or HEAD.");
    if (dataText) {
        if ([dataText length] > 5000000)
            TBFail(@"The request body is larger than 5 MB.");
        body = [dataText dataUsingEncoding:NSUTF8StringEncoding];
    }
    headers = [NSMutableArray arrayWithArray:headerList(TBValue(args, @"headers"))];
    for (i = 0; i + 1 < [headers count]; i += 2)
        if ([[[headers objectAtIndex:i] lowercaseString] isEqualToString:@"content-type"])
            hasType = YES;
    if (body && !hasType) {
        NSString *first = [TBTrim(dataText) length] ? [TBTrim(dataText) substringToIndex:1] : @"";
        [headers addObject:@"Content-Type"];
        [headers addObject:[first isEqualToString:@"{"] || [first isEqualToString:@"["] ? @"application/json" : @"application/x-www-form-urlencoded"];
    }
    if ([outPath length]) {
        if (!allowSave)
            TBFail(@"Saving to a file needs Commander switched on in this chat (Tools menu).");
        if ([method isEqualToString:@"HEAD"])
            TBFail(@"A HEAD request has no body to save.");
        target = savePathFor(outPath, url, flagArg(args, @"overwrite", NO));
        part = [target stringByAppendingString:@".part"];
    }
    @try {
        got = webRequestSaving(method, url, headers, body, follow, intArg(args, @"timeout", 30, 5, 120), run, part);
    } @catch (NSException *e) {
        if (part)
            [[NSFileManager defaultManager] removeFileAtPath:part handler:nil];
        @throw;
    }
    if (part) {
        BOOL kept = [got objectForKey:@"written"] != nil;
        NSFileManager *files = [NSFileManager defaultManager];
        if (kept) {
            if ([files fileExistsAtPath:target])
                [files removeFileAtPath:target handler:nil];
            if (![files movePath:part toPath:target handler:nil]) {
                [files removeFileAtPath:part handler:nil];
                TBFail(@"The file could not be saved at %@.", target);
            }
            return answer([NSString stringWithFormat:@"%@\nSaved %lu bytes (%@) to %@\nSHA-256 %@",
                [[[[got objectForKey:@"headers"] componentsSeparatedByString:@"\r\n"] objectAtIndex:0] description], [[got objectForKey:@"written"] unsignedLongValue],
                [[got objectForKey:@"type"] length] ? [got objectForKey:@"type"] : @"unknown type", target, [got objectForKey:@"sha256"]], nil);
        }
        [files removeFileAtPath:part handler:nil];
        /* not a good answer: nothing was saved, and what the server said is shown below */
    }
    data = [got objectForKey:@"data"];
    type = [got objectForKey:@"type"];
    code = [[got objectForKey:@"status"] intValue];
    finalURL = [got objectForKey:@"url"];
    statusLine = [[[[got objectForKey:@"headers"] componentsSeparatedByString:@"\r\n"] objectAtIndex:0] description];
    [out appendFormat:@"%@\n", [statusLine length] ? statusLine : [NSString stringWithFormat:@"HTTP %d", code]];
    if (![finalURL isEqualToString:url])
        [out appendFormat:@"Final address: %@\n", finalURL];
    if ([type length])
        [out appendFormat:@"Content-Type: %@\n", type];
    [out appendFormat:@"Size: %lu bytes\n", (unsigned long)[data length]];
    if (wantHeaders)
        [out appendFormat:@"\nResponse headers:\n%@\n", TBTrim(replaceAll([got objectForKey:@"headers"], @"\r", @""))];
    if (![data length] || [method isEqualToString:@"HEAD"])
        return answer([out stringByAppendingString:@"\n(no body)"], nil);
    if (!save && looksLikeText(data, type)) {
        NSString *text = textOf(data);
        [out appendString:@"\n"];
        if ([text length] > (unsigned)maxChars) {
            [out appendString:[text substringToIndex:maxChars]];
            [out appendFormat:@"\n[cut off: %lu more characters. Ask again with a bigger max_chars (at most 200000), or with save set to true to keep the whole file.]", (unsigned long)([text length] - maxChars)];
        } else
            [out appendString:text];
        return answer(out, nil);
    }
    /* something to keep: a picture or video is shown, anything else is offered with a Save As button */
    {
        const unsigned char *b = [data bytes];
        NSString *name = fileNameFor(finalURL, type, saveAs), *lower = [type lowercaseString];
        BOOL png = [data length] > 8 && !memcmp(b, "\x89PNG", 4), jpeg = [data length] > 3 && b[0] == 0xff && b[1] == 0xd8 && b[2] == 0xff, gif = [data length] > 6 && !memcmp(b, "GIF8", 4);
        BOOL mp4 = [data length] > 12 && !memcmp(b + 4, "ftyp", 4) && ([lower hasPrefix:@"video/"] || [[name pathExtension] isEqualToString:@"mp4"]);
        NSString *line;
        if (!save && (png || jpeg || gif)) {
            line = [@"image " stringByAppendingString:TBSaveMedia(data, png ? @"png" : (jpeg ? @"jpg" : @"gif"))];
            [out appendString:@"\nThe picture is now shown in the chat."];
        } else if (!save && mp4) {
            line = [@"video " stringByAppendingString:TBSaveMedia(playableOnOldQuickTime(data), @"mp4")];
            [out appendString:@"\nThe video is now shown in the chat."];
        } else {
            line = [@"file " stringByAppendingString:[TBOutputs storeData:data name:name]];
            [out appendFormat:@"\nSaved as %@ and given to the person in the chat with a Save As button.", [TBOutputs cleanFileName:name]];
        }
        [out appendFormat:@" SHA-256 %@.", hexSHA256(data)];
        return answer(out, [NSArray arrayWithObject:line]);
    }
}

/* ---- X posts ---- */

static NSString *unescapeHTML(NSString *text)
{
    text = replaceAll(text, @"&lt;", @"<");
    text = replaceAll(text, @"&gt;", @">");
    text = replaceAll(text, @"&quot;", @"\"");
    text = replaceAll(text, @"&#39;", @"'");
    return replaceAll(text, @"&amp;", @"&");
}

static NSDate *parseCreated(NSString *text)
{
    int y, mo, d, h, mi, s;
    struct tm t;
    if ([text length] < 19 || sscanf([text UTF8String], "%d-%d-%dT%d:%d:%d", &y, &mo, &d, &h, &mi, &s) != 6)
        return nil;
    memset(&t, 0, sizeof t);
    t.tm_year = y - 1900;
    t.tm_mon = mo - 1;
    t.tm_mday = d;
    t.tm_hour = h;
    t.tm_min = mi;
    t.tm_sec = s;
    return [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)timegm(&t)];
}

static NSString *countText(double n)
{
    NSString *text;
    if (n < 1000)
        return [NSString stringWithFormat:@"%.0f", n];
    if (n < 10000)
        text = [NSString stringWithFormat:@"%.1fK", n / 1000];
    else if (n < 1000000)
        return [NSString stringWithFormat:@"%.0fK", n / 1000];
    else
        text = [NSString stringWithFormat:@"%.1fM", n / 1000000];
    return replaceAll(text, @".0", @"");
}

static NSString *ageText(NSDate *date)
{
    double age;
    time_t then;
    struct tm local, now;
    char buffer[40];
    time_t current = time(NULL);
    if (!date)
        return @"";
    age = -[date timeIntervalSinceNow];
    if (age < 60)
        return @"now";
    if (age < 3600)
        return [NSString stringWithFormat:@"%.0fm", age / 60];
    if (age < 86400)
        return [NSString stringWithFormat:@"%.0fh", age / 3600];
    then = (time_t)[date timeIntervalSince1970];
    gmtime_r(&then, &local);
    gmtime_r(&current, &now);
    strftime(buffer, sizeof buffer, local.tm_year == now.tm_year ? "%b %e" : "%b %e, %Y", &local);
    return TBTrim([NSString stringWithUTF8String:buffer]);
}

static NSString *durationText(double ms)
{
    int s = (int)(ms / 1000 + 0.5);
    return [NSString stringWithFormat:@"%d:%02d", s / 60, s % 60];
}

@implementation TBWebTools

/* the digits of a post: from an address like https://x.com/name/status/123 (twitter.com, mobile., fxtwitter.com and so on too), or the digits alone */
+ (NSString *)postIdFrom:(NSString *)text
{
    NSString *t = TBTrim(text);
    NSRange at;
    unsigned i, start;
    BOOL digits = [t length] > 0;
    if (![t length])
        return nil;
    for (i = 0; i < [t length]; i++)
        if ([t characterAtIndex:i] < '0' || [t characterAtIndex:i] > '9')
            digits = NO;
    if (digits)
        return [t length] <= 25 ? t : nil;
    at = [t rangeOfString:@"/status/"];
    if (at.location == NSNotFound)
        at = [t rangeOfString:@"/statuses/"];
    if (at.location == NSNotFound)
        return nil;
    start = NSMaxRange(at);
    for (i = start; i < [t length] && [t characterAtIndex:i] >= '0' && [t characterAtIndex:i] <= '9'; i++)
        ;
    return i > start && i - start <= 25 ? [t substringWithRange:NSMakeRange(start, i - start)] : nil;
}

/* the part of the service's answer the rest of this file uses */
+ (NSDictionary *)postFromSyndication:(id)json
{
    NSMutableDictionary *post = [NSMutableDictionary dictionary];
    id user = TBDictionary(json, @"user");
    NSString *text = TBString(json, @"text"), *handle = TBString(user, @"screen_name"), *avatar = TBString(user, @"profile_image_url_https");
    NSArray *urls = TBArray(TBDictionary(json, @"entities"), @"urls"), *media = TBArray(TBDictionary(json, @"entities"), @"media"), *details = TBArray(json, @"mediaDetails");
    NSMutableArray *photos = [NSMutableArray array], *photoSizes = [NSMutableArray array];
    unsigned i;
    if (!text)
        text = @"";
    for (i = 0; i < [urls count]; i++)
        if ([TBString([urls objectAtIndex:i], @"url") length])
            text = replaceAll(text, TBString([urls objectAtIndex:i], @"url"), [TBString([urls objectAtIndex:i], @"expanded_url") length] ? TBString([urls objectAtIndex:i], @"expanded_url") : TBString([urls objectAtIndex:i], @"display_url"));
    for (i = 0; i < [media count]; i++)
        if ([TBString([media objectAtIndex:i], @"url") length])
            text = replaceAll(text, TBString([media objectAtIndex:i], @"url"), @"");
    [post setObject:TBTrim(unescapeHTML(text)) forKey:@"text"];
    [post setObject:TBString(json, @"id_str") forKey:@"id"];
    [post setObject:[TBString(user, @"name") length] ? TBString(user, @"name") : handle forKey:@"name"];
    [post setObject:handle ? handle : @"" forKey:@"handle"];
    [post setObject:[NSNumber numberWithBool:TBTruth(user, @"is_blue_verified") || TBTruth(user, @"verified") || [TBString(user, @"verified_type") length]] forKey:@"verified"];
    /* the badge is blue for a person, gold for a business and grey for a government account; those accounts also have square pictures */
    if ([[TBString(user, @"verified_type") lowercaseString] isEqualToString:@"business"])
        [post setObject:@"gold" forKey:@"badge"];
    else if ([[TBString(user, @"verified_type") lowercaseString] isEqualToString:@"government"])
        [post setObject:@"grey" forKey:@"badge"];
    if ([[TBString(user, @"profile_image_shape") lowercaseString] isEqualToString:@"square"])
        [post setObject:[NSNumber numberWithBool:YES] forKey:@"square"];
    if ([avatar length])
        [post setObject:replaceAll(avatar, @"_normal.", @"_200x200.") forKey:@"avatar"];
    if (parseCreated(TBString(json, @"created_at")))
        [post setObject:parseCreated(TBString(json, @"created_at")) forKey:@"created"];
    if ([TBValue(json, @"favorite_count") isKindOfClass:[NSNumber class]])
        [post setObject:TBValue(json, @"favorite_count") forKey:@"likes"];
    if ([TBValue(json, @"conversation_count") isKindOfClass:[NSNumber class]])
        [post setObject:TBValue(json, @"conversation_count") forKey:@"replies"];
    for (i = 0; i < [details count]; i++) {
        id item = [details objectAtIndex:i];
        NSString *kind = TBString(item, @"type"), *base = TBString(item, @"media_url_https");
        if ([kind isEqualToString:@"photo"] && [base length]) {
            [photos addObject:base];
            [photoSizes addObject:[NSString stringWithFormat:@"%dx%d", [TBValue(TBDictionary(item, @"original_info"), @"width") intValue], [TBValue(TBDictionary(item, @"original_info"), @"height") intValue]]];
        } else if (([kind isEqualToString:@"video"] || [kind isEqualToString:@"animated_gif"]) && ![post objectForKey:@"video"]) {
            id info = TBDictionary(item, @"video_info");
            NSArray *variants = TBArray(info, @"variants");
            NSString *best = nil, *smallest = nil;
            double duration = [TBValue(info, @"duration_millis") isKindOfClass:[NSNumber class]] ? [TBValue(info, @"duration_millis") doubleValue] : 0, bestRate = -1, smallRate = 1e18;
            unsigned v;
            for (v = 0; v < [variants count]; v++) {
                id variant = [variants objectAtIndex:v];
                double rate = [TBValue(variant, @"bitrate") isKindOfClass:[NSNumber class]] ? [TBValue(variant, @"bitrate") doubleValue] : 0;
                int w = 0, h = 0;
                NSString *address = TBString(variant, @"url");
                NSArray *pieces = [[[address componentsSeparatedByString:@"?"] objectAtIndex:0] componentsSeparatedByString:@"/"];
                unsigned q;
                if (![TBString(variant, @"content_type") isEqualToString:@"video/mp4"] || ![address length])
                    continue;
                /* the picture size is a part of the address, as /vid/640x360/ */
                for (q = 0; q < [pieces count]; q++) {
                    int pw = 0, ph = 0, used = 0;
                    if (sscanf([[pieces objectAtIndex:q] UTF8String], "%dx%d%n", &pw, &ph, &used) == 2 && used == (int)[[pieces objectAtIndex:q] length]) {
                        w = pw;
                        h = ph;
                    }
                }
                (void)w;
                if (rate < smallRate) {
                    smallRate = rate;
                    smallest = address;
                }
                /* the best one that an old Mac can play: at most 540 pixels high (the big ones are refused or stutter on them), and not over 30 MB */
                if (rate > bestRate && h > 0 && h <= 540 && (duration <= 0 || rate * duration / 8000.0 <= 30e6)) {
                    bestRate = rate;
                    best = address;
                }
            }
            if (!best)
                best = smallest;
            if (best) {
                NSMutableDictionary *video = [NSMutableDictionary dictionaryWithObjectsAndKeys:best, @"url", base ? base : @"", @"poster", [NSNumber numberWithDouble:duration], @"duration", nil];
                if ([kind isEqualToString:@"animated_gif"])
                    [video setObject:[NSNumber numberWithBool:YES] forKey:@"gif"];
                [video setObject:[NSString stringWithFormat:@"%dx%d", [TBValue(TBDictionary(item, @"original_info"), @"width") intValue], [TBValue(TBDictionary(item, @"original_info"), @"height") intValue]] forKey:@"size"];
                [post setObject:video forKey:@"video"];
            }
        }
    }
    [post setObject:photos forKey:@"photos"];
    [post setObject:photoSizes forKey:@"photoSizes"];
    if ([TBDictionary(json, @"quoted_tweet") count]) {
        id q = TBDictionary(json, @"quoted_tweet");
        [post setObject:[NSString stringWithFormat:@"%@ (@%@): %@", TBString(TBDictionary(q, @"user"), @"name"), TBString(TBDictionary(q, @"user"), @"screen_name"), TBTrim(unescapeHTML(TBString(q, @"text")))] forKey:@"quoted"];
    }
    if ([TBValue(json, @"retweet_count") isKindOfClass:[NSNumber class]])
        [post setObject:TBValue(json, @"retweet_count") forKey:@"reposts"];
    if ([TBString(json, @"in_reply_to_screen_name") length])
        [post setObject:TBString(json, @"in_reply_to_screen_name") forKey:@"replyTo"];
    return post;
}

/* ---- the drawn copy of a post ---- */

static NSColor *rgb(int r, int g, int b)
{
    return [NSColor colorWithCalibratedRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:1];
}

/* a rectangle with round corners (NSBezierPath has no such call before 10.5) */
static NSBezierPath *roundedPath(NSRect r, float radius)
{
    NSBezierPath *p = [NSBezierPath bezierPath];
    float x0 = NSMinX(r), y0 = NSMinY(r), x1 = NSMaxX(r), y1 = NSMaxY(r);
    [p moveToPoint:NSMakePoint(x0 + radius, y0)];
    [p appendBezierPathWithArcFromPoint:NSMakePoint(x1, y0) toPoint:NSMakePoint(x1, y1) radius:radius];
    [p appendBezierPathWithArcFromPoint:NSMakePoint(x1, y1) toPoint:NSMakePoint(x0, y1) radius:radius];
    [p appendBezierPathWithArcFromPoint:NSMakePoint(x0, y1) toPoint:NSMakePoint(x0, y0) radius:radius];
    [p appendBezierPathWithArcFromPoint:NSMakePoint(x0, y0) toPoint:NSMakePoint(x1, y0) radius:radius];
    [p closePath];
    return p;
}

/* a picture filling a rectangle, cut to fit */
static void drawFilled(NSImage *image, NSRect cell)
{
    NSSize s = [image size];
    NSRect from;
    float scale;
    if (s.width <= 0 || s.height <= 0)
        return;
    scale = MAX(NSWidth(cell) / s.width, NSHeight(cell) / s.height);
    from = NSMakeRect((s.width - NSWidth(cell) / scale) / 2, (s.height - NSHeight(cell) / scale) / 2, NSWidth(cell) / scale, NSHeight(cell) / scale);
    [image drawInRect:cell fromRect:from operation:NSCompositeSourceOver fraction:1.0];
}

static void drawHeart(NSRect r, NSColor *color)
{
    NSBezierPath *p = [NSBezierPath bezierPath];
    float x = NSMinX(r), y = NSMinY(r), w = NSWidth(r), h = NSHeight(r);
    [p moveToPoint:NSMakePoint(x + w / 2, y)];
    [p curveToPoint:NSMakePoint(x, y + h * 0.68) controlPoint1:NSMakePoint(x + w * 0.35, y + h * 0.2) controlPoint2:NSMakePoint(x, y + h * 0.4)];
    [p curveToPoint:NSMakePoint(x + w / 2, y + h * 0.72) controlPoint1:NSMakePoint(x, y + h * 1.0) controlPoint2:NSMakePoint(x + w * 0.45, y + h * 1.0)];
    [p curveToPoint:NSMakePoint(x + w, y + h * 0.68) controlPoint1:NSMakePoint(x + w * 0.55, y + h * 1.0) controlPoint2:NSMakePoint(x + w, y + h * 1.0)];
    [p curveToPoint:NSMakePoint(x + w / 2, y) controlPoint1:NSMakePoint(x + w, y + h * 0.4) controlPoint2:NSMakePoint(x + w * 0.65, y + h * 0.2)];
    [p setLineWidth:1.7];
    [color set];
    [p stroke];
}

static void drawReply(NSRect r, NSColor *color)
{
    NSBezierPath *p = roundedPath(NSMakeRect(NSMinX(r), NSMinY(r) + 4, NSWidth(r), NSHeight(r) - 4), 6);
    NSBezierPath *tail = [NSBezierPath bezierPath];
    [p setLineWidth:1.7];
    [color set];
    [p stroke];
    [tail moveToPoint:NSMakePoint(NSMinX(r) + 5, NSMinY(r) + 4)];
    [tail lineToPoint:NSMakePoint(NSMinX(r) + 4, NSMinY(r))];
    [tail lineToPoint:NSMakePoint(NSMinX(r) + 10, NSMinY(r) + 4)];
    [tail setLineWidth:1.7];
    [tail stroke];
}

static void drawShare(NSRect r, NSColor *color)
{
    NSBezierPath *tray = [NSBezierPath bezierPath], *arrow = [NSBezierPath bezierPath];
    float x = NSMinX(r), y = NSMinY(r), w = NSWidth(r), h = NSHeight(r);
    [color set];
    [tray moveToPoint:NSMakePoint(x, y + h * 0.45)];
    [tray lineToPoint:NSMakePoint(x, y)];
    [tray lineToPoint:NSMakePoint(x + w, y)];
    [tray lineToPoint:NSMakePoint(x + w, y + h * 0.45)];
    [tray setLineWidth:1.7];
    [tray stroke];
    [arrow moveToPoint:NSMakePoint(x + w / 2, y + h * 0.25)];
    [arrow lineToPoint:NSMakePoint(x + w / 2, y + h)];
    [arrow moveToPoint:NSMakePoint(x + w * 0.22, y + h * 0.72)];
    [arrow lineToPoint:NSMakePoint(x + w / 2, y + h)];
    [arrow lineToPoint:NSMakePoint(x + w * 0.78, y + h * 0.72)];
    [arrow setLineWidth:1.7];
    [arrow stroke];
}

static void drawRepost(NSRect r, NSColor *color)
{
    NSBezierPath *p = [NSBezierPath bezierPath];
    float x = NSMinX(r), y = NSMinY(r), w = NSWidth(r), h = NSHeight(r);
    [color set];
    /* the upper arrow, running right, and the lower one, running left */
    [p moveToPoint:NSMakePoint(x + 2, y + h * 0.5)];
    [p lineToPoint:NSMakePoint(x + 2, y + h * 0.78)];
    [p lineToPoint:NSMakePoint(x + w - 3, y + h * 0.78)];
    [p moveToPoint:NSMakePoint(x + w - 6.5, y + h * 1.0)];
    [p lineToPoint:NSMakePoint(x + w - 3, y + h * 0.78)];
    [p lineToPoint:NSMakePoint(x + w - 6.5, y + h * 0.56)];
    [p moveToPoint:NSMakePoint(x + w - 2, y + h * 0.5)];
    [p lineToPoint:NSMakePoint(x + w - 2, y + h * 0.22)];
    [p lineToPoint:NSMakePoint(x + 3, y + h * 0.22)];
    [p moveToPoint:NSMakePoint(x + 6.5, y)];
    [p lineToPoint:NSMakePoint(x + 3, y + h * 0.22)];
    [p lineToPoint:NSMakePoint(x + 6.5, y + h * 0.44)];
    [p setLineWidth:1.7];
    [p stroke];
}

static void drawViews(NSRect r, NSColor *color)
{
    NSBezierPath *p = [NSBezierPath bezierPath];
    float x = NSMinX(r), y = NSMinY(r), w = NSWidth(r), h = NSHeight(r);
    [color set];
    [p moveToPoint:NSMakePoint(x + 1, y)];
    [p lineToPoint:NSMakePoint(x + 1, y + h * 0.45)];
    [p moveToPoint:NSMakePoint(x + w * 0.35, y)];
    [p lineToPoint:NSMakePoint(x + w * 0.35, y + h)];
    [p moveToPoint:NSMakePoint(x + w * 0.68, y)];
    [p lineToPoint:NSMakePoint(x + w * 0.68, y + h * 0.65)];
    [p moveToPoint:NSMakePoint(x + w - 1, y)];
    [p lineToPoint:NSMakePoint(x + w - 1, y + h * 0.3)];
    [p setLineWidth:2.2];
    [p stroke];
}

static void drawBadge(NSPoint center, NSString *kind)
{
    NSBezierPath *check = [NSBezierPath bezierPath];
    if ([kind isEqualToString:@"gold"])
        [rgb(226, 183, 25) set];
    else if ([kind isEqualToString:@"grey"])
        [rgb(130, 154, 171) set];
    else
        [rgb(29, 155, 240) set];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(center.x - 8.5, center.y - 8.5, 17, 17)] fill];
    [check moveToPoint:NSMakePoint(center.x - 4, center.y - 0.5)];
    [check lineToPoint:NSMakePoint(center.x - 1.2, center.y - 3.5)];
    [check lineToPoint:NSMakePoint(center.x + 4.5, center.y + 3.5)];
    [check setLineWidth:2];
    [[NSColor whiteColor] set];
    [check stroke];
}

/* the photos of a post as one picture, in the arrangement X uses: one alone, two side by side, three with one tall, four in a grid */
+ (NSData *)collagePNGForPhotos:(NSArray *)photoData video:(NSDictionary *)video
{
    NSMutableDictionary *job = [NSMutableDictionary dictionaryWithObject:photoData forKey:@"photos"];
    if (video)
        [job setObject:video forKey:@"video"];
    [self performSelectorOnMainThread:@selector(drawCollage:) withObject:job waitUntilDone:YES];
    return [job objectForKey:@"png"];
}

+ (void)drawCollage:(NSMutableDictionary *)job
{
    NSMutableArray *images = [NSMutableArray array];
    NSArray *photoData = [job objectForKey:@"photos"];
    unsigned i, n;
    float W = 460, H, scale = 2, half, gap = 3;
    NSSize first;
    NSImage *picture;
    NSBitmapImageRep *rep;
    NSRect frame;
    for (i = 0; i < [photoData count] && i < 4; i++) {
        NSImage *one = [[[NSImage alloc] initWithData:[photoData objectAtIndex:i]] autorelease];
        if (one && [one size].width > 0)
            [images addObject:one];
    }
    n = [images count];
    if (!n && ![job objectForKey:@"video"])
        return;
    first = n ? [[images objectAtIndex:0] size] : NSMakeSize(16, 9);
    half = (W - gap) / 2;
    H = n <= 1 ? MIN(W * first.height / first.width, 380) : (n == 2 ? 260 : 300);
    frame = NSMakeRect(0, 0, W, H);
    picture = [[[NSImage alloc] initWithSize:NSMakeSize(W * scale, H * scale)] autorelease];
    [picture lockFocus];
    {
        NSAffineTransform *zoom = [NSAffineTransform transform];
        [zoom scaleBy:scale];
        [zoom concat];
        [NSGraphicsContext saveGraphicsState];
        [roundedPath(frame, 14) addClip];
        [[NSColor colorWithCalibratedWhite:0.12 alpha:1] set];
        NSRectFill(frame);
        if (n == 1) {
            drawFilled([images objectAtIndex:0], frame);
        } else if (n == 2) {
            drawFilled([images objectAtIndex:0], NSMakeRect(0, 0, half, H));
            drawFilled([images objectAtIndex:1], NSMakeRect(half + gap, 0, half, H));
        } else if (n == 3) {
            drawFilled([images objectAtIndex:0], NSMakeRect(0, 0, half, H));
            drawFilled([images objectAtIndex:1], NSMakeRect(half + gap, H / 2 + gap / 2, half, H / 2 - gap / 2));
            drawFilled([images objectAtIndex:2], NSMakeRect(half + gap, 0, half, H / 2 - gap / 2));
        } else {
            drawFilled([images objectAtIndex:0], NSMakeRect(0, H / 2 + gap / 2, half, H / 2 - gap / 2));
            drawFilled([images objectAtIndex:1], NSMakeRect(half + gap, H / 2 + gap / 2, half, H / 2 - gap / 2));
            drawFilled([images objectAtIndex:2], NSMakeRect(0, 0, half, H / 2 - gap / 2));
            drawFilled([images objectAtIndex:3], NSMakeRect(half + gap, 0, half, H / 2 - gap / 2));
        }
        if ([job objectForKey:@"video"]) {
            /* a video is shown as its first picture with a play button, and its length */
            NSDictionary *video = [job objectForKey:@"video"];
            NSPoint c = NSMakePoint(W / 2, H / 2);
            NSBezierPath *triangle = [NSBezierPath bezierPath];
            NSString *label = [[video objectForKey:@"gif"] boolValue] ? @"GIF" : durationText([[video objectForKey:@"duration"] doubleValue]);
            NSDictionary *labelAttrs = [NSDictionary dictionaryWithObjectsAndKeys:[NSFont boldSystemFontOfSize:12], NSFontAttributeName, [NSColor whiteColor], NSForegroundColorAttributeName, nil];
            NSRect box = NSMakeRect(10, 10, [label sizeWithAttributes:labelAttrs].width + 14, 22);
            [[NSColor colorWithCalibratedWhite:0 alpha:0.55] set];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - 30, c.y - 30, 60, 60)] fill];
            [[NSColor whiteColor] set];
            [triangle moveToPoint:NSMakePoint(c.x - 8, c.y - 13)];
            [triangle lineToPoint:NSMakePoint(c.x + 15, c.y)];
            [triangle lineToPoint:NSMakePoint(c.x - 8, c.y + 13)];
            [triangle closePath];
            [triangle fill];
            if ([[video objectForKey:@"duration"] doubleValue] > 0 || [[video objectForKey:@"gif"] boolValue]) {
                [[NSColor colorWithCalibratedWhite:0 alpha:0.7] set];
                [roundedPath(box, 4) fill];
                [label drawAtPoint:NSMakePoint(NSMinX(box) + 7, NSMinY(box) + 4) withAttributes:labelAttrs];
            }
        }
        [NSGraphicsContext restoreGraphicsState];
    }
    rep = [[[NSBitmapImageRep alloc] initWithFocusedViewRect:NSMakeRect(0, 0, W * scale, H * scale)] autorelease];
    [picture unlockFocus];
    [job setObject:[rep representationUsingType:NSPNGFileType properties:[NSDictionary dictionary]] forKey:@"png"];
}

/* the author's picture, small, as JPEG */
+ (NSData *)avatarJPEG:(NSData *)data
{
    NSMutableDictionary *job = [NSMutableDictionary dictionaryWithObject:data forKey:@"data"];
    [self performSelectorOnMainThread:@selector(drawAvatar:) withObject:job waitUntilDone:YES];
    return [job objectForKey:@"jpeg"];
}

+ (void)drawAvatar:(NSMutableDictionary *)job
{
    NSImage *source = [[[NSImage alloc] initWithData:[job objectForKey:@"data"]] autorelease], *small;
    NSBitmapImageRep *rep;
    if (!source || [source size].width <= 0)
        return;
    small = [[[NSImage alloc] initWithSize:NSMakeSize(64, 64)] autorelease];
    [small lockFocus];
    drawFilled(source, NSMakeRect(0, 0, 64, 64));
    rep = [[[NSBitmapImageRep alloc] initWithFocusedViewRect:NSMakeRect(0, 0, 64, 64)] autorelease];
    [small unlockFocus];
    [job setObject:[rep representationUsingType:NSJPEGFileType properties:[NSDictionary dictionaryWithObject:[NSNumber numberWithFloat:0.85] forKey:NSImageCompressionFactor]] forKey:@"jpeg"];
}

/* ---- the calls ---- */

static NSData *plainGet(NSString *url, TBRun *run)
{
    NSDictionary *got = webRequest(@"GET", url, [NSArray arrayWithObjects:@"Accept", @"image/jpeg,image/png,*/*;q=0.5", nil], nil, YES, 25, run);
    return [[got objectForKey:@"status"] intValue] == 200 ? [got objectForKey:@"data"] : nil;
}

static NSDictionary *postCall(NSDictionary *args, TBRun *run)
{
    NSString *given = TBString(args, @"url"), *postId = [TBWebTools postIdFrom:given], *show = [TBTrim(TBString(args, @"show")) lowercaseString];
    NSString *base = [[NSUserDefaults standardUserDefaults] stringForKey:@"TBBaseURL.xposts"];
    NSDictionary *got, *post;
    NSMutableArray *media = [NSMutableArray array], *cardPhotos = [NSMutableArray array], *lines = [NSMutableArray array];
    BOOL card, photos, video;
    NSString *link;
    NSDictionary *videoInfo;
    NSArray *photoURLs;
    NSMutableString *out = [NSMutableString string];
    id json;
    unsigned i;
    if (![show length])
        show = @"card";
    if (!postId)
        TBFail(@"Give the address of a post, such as https://x.com/name/status/1234567890123456789, or its number.");
    if (![[NSArray arrayWithObjects:@"card", @"media", @"all", @"text", nil] containsObject:show])
        TBFail(@"show must be card (a drawn copy of the post, and any video), media (the pictures and video at full size), all, or text.");
    card = [show isEqualToString:@"card"] || [show isEqualToString:@"all"];
    photos = [show isEqualToString:@"media"] || [show isEqualToString:@"all"];
    video = ![show isEqualToString:@"text"];
    got = webRequest(@"GET", [NSString stringWithFormat:@"%@/tweet-result?id=%@&token=a&lang=en", [base length] ? base : @"https://cdn.syndication.twimg.com", postId],
        [NSArray arrayWithObjects:@"Accept", @"application/json", nil], nil, YES, 25, run);
    if ([[got objectForKey:@"status"] intValue] == 404 || ![[got objectForKey:@"type"] hasPrefix:@"application/json"])
        TBFail(@"That post could not be found. It may be deleted, private, or from an account that does not allow it to be shown outside X.");
    if ([[got objectForKey:@"status"] intValue] != 200)
        TBFail(@"X answered HTTP %d for that post.", [[got objectForKey:@"status"] intValue]);
    json = TBJSONParse([got objectForKey:@"data"], NULL);
    if (![TBString(json, @"id_str") length] || ![TBDictionary(json, @"user") count] || [TBString(json, @"__typename") isEqualToString:@"TweetTombstone"])
        TBFail(@"That post could not be shown: it is deleted, private or hidden.");
    post = [TBWebTools postFromSyndication:json];
    if (![post objectForKey:@"reposts"] || ![post objectForKey:@"views"]) {
        /* X's embed service leaves out reposts and views; fxtwitter's public list has them. Without it the post is shown with what it has. */
        @try {
            NSString *other = [[NSUserDefaults standardUserDefaults] stringForKey:@"TBBaseURL.fxtwitter"];
            NSDictionary *more = webRequest(@"GET", [NSString stringWithFormat:@"%@/status/%@", [other length] ? other : @"https://api.fxtwitter.com", postId], [NSArray arrayWithObjects:@"Accept", @"application/json", nil], nil, YES, 12, run);
            id tweet = [[more objectForKey:@"status"] intValue] == 200 ? TBDictionary(TBJSONParse([more objectForKey:@"data"], NULL), @"tweet") : nil;
            NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:post];
            if ([TBValue(tweet, @"retweets") isKindOfClass:[NSNumber class]])
                [merged setObject:TBValue(tweet, @"retweets") forKey:@"reposts"];
            if ([TBValue(tweet, @"views") isKindOfClass:[NSNumber class]] && [TBValue(tweet, @"views") doubleValue] > 0)
                [merged setObject:TBValue(tweet, @"views") forKey:@"views"];
            if (![merged objectForKey:@"likes"] && [TBValue(tweet, @"likes") isKindOfClass:[NSNumber class]])
                [merged setObject:TBValue(tweet, @"likes") forKey:@"likes"];
            if (![merged objectForKey:@"replies"] && [TBValue(tweet, @"replies") isKindOfClass:[NSNumber class]])
                [merged setObject:TBValue(tweet, @"replies") forKey:@"replies"];
            post = merged;
        } @catch (NSException *e) {
            if ([[e name] isEqualToString:TBStoppedException])
                @throw;
        }
    }
    link = [NSString stringWithFormat:@"https://x.com/%@/status/%@", [post objectForKey:@"handle"], [post objectForKey:@"id"]];
    photoURLs = [post objectForKey:@"photos"];
    videoInfo = [post objectForKey:@"video"];
    /* the text, for the model */
    [out appendFormat:@"Post by %@ (@%@)%@", [post objectForKey:@"name"], [post objectForKey:@"handle"], [[post objectForKey:@"verified"] boolValue] ? @", verified" : @""];
    if ([post objectForKey:@"created"]) {
        time_t t = (time_t)[[post objectForKey:@"created"] timeIntervalSince1970];
        struct tm utc;
        char buffer[40];
        gmtime_r(&t, &utc);
        strftime(buffer, sizeof buffer, "%Y-%m-%d %H:%M UTC", &utc);
        [out appendFormat:@", %s", buffer];
    }
    [out appendFormat:@"\n%@\n\n%@\n", link, [[post objectForKey:@"text"] length] ? [post objectForKey:@"text"] : @"(no text)"];
    if ([post objectForKey:@"replyTo"])
        [out appendFormat:@"\nA reply to @%@.", [post objectForKey:@"replyTo"]];
    if ([post objectForKey:@"quoted"])
        [out appendFormat:@"\nQuoted post: %@\n", [post objectForKey:@"quoted"]];
    if ([post objectForKey:@"replies"] || [post objectForKey:@"likes"]) {
        [out appendFormat:@"\nReplies %@, likes %@", [post objectForKey:@"replies"] ? [post objectForKey:@"replies"] : @"unknown", [post objectForKey:@"likes"] ? [post objectForKey:@"likes"] : @"unknown"];
        if ([post objectForKey:@"reposts"])
            [out appendFormat:@", reposts %@", [post objectForKey:@"reposts"]];
        if ([post objectForKey:@"views"])
            [out appendFormat:@", views %@", [post objectForKey:@"views"]];
        [out appendString:@"."];
    }
    for (i = 0; i < [photoURLs count]; i++)
        [lines addObject:[NSString stringWithFormat:@"photo %u (%@): %@", i + 1, [[post objectForKey:@"photoSizes"] objectAtIndex:i], [photoURLs objectAtIndex:i]]];
    if (videoInfo)
        [lines addObject:[NSString stringWithFormat:@"%@ %@, %@: %@", [[videoInfo objectForKey:@"gif"] boolValue] ? @"animated GIF" : @"video", durationText([[videoInfo objectForKey:@"duration"] doubleValue]), [videoInfo objectForKey:@"size"], [videoInfo objectForKey:@"url"]]];
    if ([lines count])
        [out appendFormat:@"\n\nMedia:\n%@", [lines componentsJoinedByString:@"\n"]];
    /* the pictures, shown */
    if (card) {
        /* a post in a chat bubble: its data in one line, then its photos as one picture, then its video, each for the bubble the first line makes */
        NSData *avatar = [post objectForKey:@"avatar"] ? plainGet([post objectForKey:@"avatar"], run) : nil, *small = avatar ? [TBWebTools avatarJPEG:avatar] : nil;
        NSMutableDictionary *shown = [NSMutableDictionary dictionaryWithObjectsAndKeys:[post objectForKey:@"id"], @"id", [post objectForKey:@"name"], @"name", [post objectForKey:@"handle"], @"handle",
            [post objectForKey:@"verified"], @"verified", [post objectForKey:@"text"], @"text", nil];
        NSString *keys[] = {@"replies", @"reposts", @"likes", @"views"};
        NSData *collage;
        if ([post objectForKey:@"badge"])
            [shown setObject:[post objectForKey:@"badge"] forKey:@"badge"];
        if ([post objectForKey:@"square"])
            [shown setObject:[post objectForKey:@"square"] forKey:@"square"];
        for (i = 0; i < 4; i++)
            if ([post objectForKey:keys[i]])
                [shown setObject:[post objectForKey:keys[i]] forKey:keys[i]];
        if ([post objectForKey:@"created"])
            [shown setObject:[NSNumber numberWithDouble:[[post objectForKey:@"created"] timeIntervalSince1970]] forKey:@"created"];
        if (small)
            [shown setObject:TBBase64(small) forKey:@"avatar"];
        [media addObject:[NSString stringWithFormat:@"tweet %@ %@", [post objectForKey:@"id"], TBBase64(TBJSONData(shown))]];
        for (i = 0; i < [photoURLs count] && i < 4; i++) {
            NSData *one = plainGet([[photoURLs objectAtIndex:i] stringByAppendingString:@"?format=jpg&name=medium"], run);
            if (one)
                [cardPhotos addObject:one];
        }
        if (videoInfo && ![cardPhotos count] && [[videoInfo objectForKey:@"poster"] length]) {
            NSData *poster = plainGet([[videoInfo objectForKey:@"poster"] stringByAppendingString:@"?format=jpg&name=medium"], run);
            if (poster)
                [cardPhotos addObject:poster];
        }
        collage = [cardPhotos count] || videoInfo ? [TBWebTools collagePNGForPhotos:cardPhotos video:videoInfo] : nil;
        if (collage)
            [media addObject:[NSString stringWithFormat:@"image %@ tweet", TBSaveMedia(collage, @"png")]];
        [out appendString:@"\n\nThe post is now shown in the chat, with its pictures; its Share button copies the link."];
    }
    if (photos) {
        for (i = 0; i < [photoURLs count]; i++) {
            @try {
                [media addObject:[@"image " stringByAppendingString:[TBMedia fetchImage:[[photoURLs objectAtIndex:i] stringByAppendingString:@"?format=jpg&name=large"]]]];
            } @catch (NSException *e) {
                if ([[e name] isEqualToString:TBStoppedException])
                    @throw;
                [out appendFormat:@"\nPhoto %u could not be fetched: %@", i + 1, [e reason]];
            }
        }
    }
    if (video && videoInfo) {
        @try {
            NSDictionary *file = webRequest(@"GET", [videoInfo objectForKey:@"url"], nil, nil, YES, 60, run);
            if ([[file objectForKey:@"status"] intValue] == 200 && [[file objectForKey:@"data"] length]) {
                [media addObject:[NSString stringWithFormat:@"%@ %@%@", card ? @"tweetvideo" : @"video", TBSaveMedia(playableOnOldQuickTime([file objectForKey:@"data"]), @"mp4"), card ? @" tweet" : @""]];
                [out appendString:card ? @"\nThe video plays when the person clicks its picture in the chat." : @"\nThe video is now shown in the chat."];
            } else
                [out appendString:@"\nThe video could not be fetched."];
        } @catch (NSException *e) {
            if ([[e name] isEqualToString:TBStoppedException])
                @throw;
            [out appendFormat:@"\nThe video could not be fetched: %@", [e reason]];
        }
    }
    if (photos && [photoURLs count])
        [out appendString:@"\nThe pictures are now shown in the chat."];
    return answer(out, media);
}

+ (NSData *)playableVideo:(NSData *)mp4
{
    return playableOnOldQuickTime(mp4);
}

+ (BOOL)knows:(NSString *)server
{
    return [server isEqualToString:@"web"] || [server isEqualToString:@"xposts"];
}

+ (NSDictionary *)call:(NSString *)tool arguments:(NSDictionary *)args server:(NSString *)server run:(TBRun *)run
{
    return [self call:tool arguments:args server:server run:run saving:YES];
}

+ (NSDictionary *)call:(NSString *)tool arguments:(NSDictionary *)args server:(NSString *)server run:(TBRun *)run saving:(BOOL)allowSave
{
    if ([server isEqualToString:@"web"] && [tool isEqualToString:@"curl"])
        return curlCall(args, run, allowSave);
    if ([server isEqualToString:@"xposts"] && [tool isEqualToString:@"x_post"])
        return postCall(args, run);
    TBFail(@"Unknown tool %@.", tool);
    return nil;
}

@end

/* the pieces of a post's bubble that the chat draws itself */
NSString *TBTweetCount(double n) { return countText(n); }
NSString *TBTweetAge(NSDate *date) { return ageText(date); }

void TBDrawTweetIcon(int kind, NSRect r, NSColor *color)
{
    if (kind == 0)
        drawReply(r, color);
    else if (kind == 1)
        drawRepost(r, color);
    else if (kind == 2)
        drawHeart(r, color);
    else if (kind == 3)
        drawViews(r, color);
    else
        drawShare(r, color);
}

void TBDrawTweetBadge(NSPoint center, NSString *kind) { drawBadge(center, kind); }
