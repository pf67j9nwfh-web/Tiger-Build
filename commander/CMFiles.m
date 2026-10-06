#import "CMCore.h"
#import <sys/stat.h>
#import <dirent.h>
#import <fnmatch.h>
#import <regex.h>
#import <pwd.h>
#import <grp.h>
#import <pthread.h>
#import <unistd.h>
#import <fcntl.h>

#define MAX_FILE_BYTES (8 * 1024 * 1024)

static NSString *swap(NSString *text, NSString *from, NSString *to)
{
    return [[text componentsSeparatedByString:from] componentsJoinedByString:to];
}

static unsigned lineCount(NSString *content)
{
    unsigned n = 0, i;
    if (![content length])
        return 0;
    for (i = 0; i < [content length]; i++)
        if ([content characterAtIndex:i] == '\n')
            n++;
    return [content hasSuffix:@"\n"] ? n : n + 1;
}

static BOOL hasNul(NSData *data)
{
    unsigned n = [data length] < 4096 ? [data length] : 4096;
    return n && memchr([data bytes], 0, n) != NULL;
}

/* the file's bytes: all of them, or the first / last 8 MB of a bigger one */
static NSData *readBytes(NSString *path, long long offset, unsigned long long *size, NSString **note)
{
    struct stat st;
    FILE *f;
    NSMutableData *data;
    long long want;
    if (stat([path fileSystemRepresentation], &st) != 0)
        CMFail(@"cannot stat %@: %s", path, strerror(errno));
    *size = st.st_size;
    *note = @"";
    f = fopen([path fileSystemRepresentation], "rb");
    if (!f)
        CMFail(@"cannot open %@: %s", path, strerror(errno));
    want = (long long)st.st_size > MAX_FILE_BYTES ? MAX_FILE_BYTES : (long long)st.st_size;
    if (offset < 0 && (long long)st.st_size > MAX_FILE_BYTES) {
        fseeko(f, st.st_size - MAX_FILE_BYTES, SEEK_SET);
        *note = [NSString stringWithFormat:@"file is %llu bytes; loaded the last %lld", (unsigned long long)st.st_size, want];
    } else if ((long long)st.st_size > MAX_FILE_BYTES)
        *note = [NSString stringWithFormat:@"file is %llu bytes; loaded the first %lld", (unsigned long long)st.st_size, want];
    data = [NSMutableData dataWithLength:(unsigned)want];
    {
        size_t got = fread([data mutableBytes], 1, (size_t)want, f);
        [data setLength:got];
    }
    fclose(f);
    return data;
}

/* ---- reading, writing, listing ---- */

static NSString *readURL(NSString *url);   /* declared in CMProcess.m's neighbour; see below */

id CMToolReadFile(NSDictionary *args)
{
    NSString *path = CMOptString(args, @"path", @""), *encoding = nil, *note = nil, *header, *text, *body;
    BOOL isURL = CMOptBool(args, @"isUrl", NO);
    long long offset, length;
    unsigned long long size;
    NSData *data;
    NSArray *lines;
    unsigned total, start, end;
    BOOL pathIsURL = [path hasPrefix:@"http://"] || [path hasPrefix:@"https://"] || [path hasPrefix:@"ftp://"];
    if (isURL || pathIsURL) {
        NSString *low = [path lowercaseString];
        if (![path length])
            CMFail(@"missing path");
        /* a URL is never a way around the path checks: no file:, no other schemes, no options for curl */
        if (!([low hasPrefix:@"http://"] || [low hasPrefix:@"https://"] || [low hasPrefix:@"ftp://"]))
            CMFail(@"only http://, https:// and ftp:// addresses can be fetched. Use a plain path for a file on this Mac.");
        return readURL(path);
    }
    if (![path length])
        CMFail(@"missing path");
    path = CMCheckPath(path);
    {
        struct stat st;
        if (lstat([path fileSystemRepresentation], &st) != 0)
            CMFail(@"not found: %@", path);
        if (S_ISDIR(st.st_mode))
            CMFail(@"path is a directory: %@", path);
    }
    offset = CMOptInteger(args, @"offset", 0);
    length = CMOptInteger(args, @"length", [[CMConfig() objectForKey:@"fileReadLineLimit"] longLongValue]);
    if (length < 1) length = 1;
    if (length > 5000) length = 5000;
    data = readBytes(path, offset, &size, &note);
    if (hasNul(data))
        return [NSString stringWithFormat:@"path: %@\nsize: %llu\nbinary file\nhex: %@", path, size, CMHexPreview(data, 96)];
    text = CMDecode(data, &encoding);
    lines = CMSplitLines(text);
    total = [lines count];
    start = offset < 0 ? ((long long)total + offset < 0 ? 0 : (unsigned)((long long)total + offset)) : (offset > (long long)total ? total : (unsigned)offset);
    end = start + (unsigned)length;
    if (end > total)
        end = total;
    body = [[lines subarrayWithRange:NSMakeRange(start, end - start)] componentsJoinedByString:@"\n"];
    header = [NSString stringWithFormat:@"path: %@\nencoding: %@\nsize: %llu\nlines: %u-%u of %u", path, encoding, size, start, end, total];
    if ([note length])
        header = [header stringByAppendingFormat:@"\nnote: %@", note];
    if (end < total)
        header = [header stringByAppendingFormat:@"\nmore: pass offset %u to continue", end];
    return CMCap([NSString stringWithFormat:@"%@\n---\n%@", header, body]);
}

id CMToolReadMultiple(NSDictionary *args)
{
    NSArray *paths = CMStringList([args objectForKey:@"paths"]);
    NSMutableArray *parts = [NSMutableArray array];
    unsigned i;
    if ([paths count] > 20)
        CMFail(@"at most 20 paths");
    for (i = 0; i < [paths count]; i++) {
        @try {
            [parts addObject:CMToolReadFile([NSDictionary dictionaryWithObjectsAndKeys:[paths objectAtIndex:i], @"path", [NSNumber numberWithInt:0], @"offset", [NSNumber numberWithInt:200], @"length", nil])];
        } @catch (NSException *e) {
            if (![[e name] isEqualToString:CMFailure])
                @throw;
            [parts addObject:[NSString stringWithFormat:@"path: %@\nerror: %@", [paths objectAtIndex:i], [e reason]]];
        }
    }
    return CMCap([parts componentsJoinedByString:@"\n\n"]);
}

id CMToolWriteFile(NSDictionary *args)
{
    NSString *path = CMCheckWritable(CMCheckPath(CMString(args, @"path"))), *content = CMString(args, @"content"), *mode = CMOptString(args, @"mode", @"rewrite");
    long long limit = [[CMConfig() objectForKey:@"fileWriteLineLimit"] longLongValue];
    unsigned n = lineCount(content);
    NSData *bytes = [content dataUsingEncoding:NSUTF8StringEncoding];
    NSString *parent = [path stringByDeletingLastPathComponent];
    BOOL isDir = NO;
    FILE *f;
    if (![mode isEqualToString:@"rewrite"] && ![mode isEqualToString:@"append"])
        CMFail(@"mode must be rewrite or append");
    if ((long long)n > limit)
        CMFail(@"content has %u lines and fileWriteLineLimit is %lld. Use mode \"append\" in chunks, or raise the limit with set_config_value.", n, limit);
    if ([parent length] && !([[NSFileManager defaultManager] fileExistsAtPath:parent isDirectory:&isDir] && isDir))
        CMFail(@"parent directory does not exist: %@", parent);
    f = fopen([path fileSystemRepresentation], [mode isEqualToString:@"append"] ? "ab" : "wb");
    if (!f)
        CMFail(@"cannot write %@: %s", path, strerror(errno));
    fwrite([bytes bytes], 1, [bytes length], f);
    fclose(f);
    return [NSString stringWithFormat:@"wrote %u bytes (%u lines, %@) to %@", (unsigned)[bytes length], n, mode, path];
}

id CMToolCreateDirectory(NSDictionary *args)
{
    NSString *path = CMCheckWritable(CMCheckPath(CMString(args, @"path")));
    BOOL isDir = NO;
    NSArray *parts;
    NSString *built = @"";
    unsigned i;
    if ([[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir]) {
        if (isDir)
            return [NSString stringWithFormat:@"directory already exists: %@", path];
        CMFail(@"path exists and is not a directory: %@", path);
    }
    parts = [path pathComponents];
    for (i = 0; i < [parts count]; i++) {
        built = [built length] ? [built stringByAppendingPathComponent:[parts objectAtIndex:i]] : [parts objectAtIndex:i];
        if (![[NSFileManager defaultManager] fileExistsAtPath:built] && mkdir([built fileSystemRepresentation], 0777) != 0 && errno != EEXIST)
            CMFail(@"mkdir failed: %s", strerror(errno));
    }
    return [NSString stringWithFormat:@"created %@", path];
}

static NSComparisonResult compareNames(id a, id b, void *context)
{
    NSComparisonResult r = [(NSString *)a caseInsensitiveCompare:b];
    return r != NSOrderedSame ? r : [(NSString *)a compare:b];
}

typedef struct {
    NSMutableArray *lines;
    unsigned count;
    BOOL truncated;
} Walk;

static void walk(Walk *w, NSString *directory, int levels, NSString *prefix)
{
    DIR *d;
    struct dirent *e;
    NSMutableArray *names = [NSMutableArray array];
    unsigned i;
    if (w->truncated)
        return;
    d = opendir([directory fileSystemRepresentation]);
    if (!d) {
        [w->lines addObject:[NSString stringWithFormat:@"%@[cannot list: %s]", prefix, strerror(errno)]];
        return;
    }
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, ".."))
            continue;
        [names addObject:[NSString stringWithUTF8String:e->d_name] ? [NSString stringWithUTF8String:e->d_name] : @"?"];
    }
    closedir(d);
    [names sortUsingFunction:compareNames context:NULL];
    for (i = 0; i < [names count]; i++) {
        NSString *name = [names objectAtIndex:i], *full = [directory stringByAppendingPathComponent:name];
        struct stat st;
        if (w->count >= 500) {
            [w->lines addObject:[NSString stringWithFormat:@"%@... truncated at 500 entries", prefix]];
            w->truncated = YES;
            return;
        }
        w->count++;
        if (lstat([full fileSystemRepresentation], &st) != 0)
            [w->lines addObject:[NSString stringWithFormat:@"%@%@ (unreadable)", prefix, name]];
        else if (S_ISLNK(st.st_mode)) {
            char target[PATH_MAX];
            ssize_t n = readlink([full fileSystemRepresentation], target, sizeof target - 1);
            target[n > 0 ? n : 0] = 0;
            [w->lines addObject:[NSString stringWithFormat:@"%@%@ -> %s", prefix, name, n > 0 ? target : "?"]];
        } else if (S_ISDIR(st.st_mode)) {
            [w->lines addObject:[NSString stringWithFormat:@"%@%@/", prefix, name]];
            if (levels > 1)
                walk(w, full, levels - 1, [prefix stringByAppendingString:@"  "]);
        } else
            [w->lines addObject:[NSString stringWithFormat:@"%@%@ (%lld bytes)", prefix, name, (long long)st.st_size]];
    }
}

id CMToolListDirectory(NSDictionary *args)
{
    NSString *path = CMCheckPath(CMString(args, @"path"));
    long long depth = CMOptInteger(args, @"depth", 2);
    BOOL isDir = NO;
    Walk w;
    if (!([[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir] && isDir))
        CMFail(@"not a directory: %@", path);
    if (depth < 1) depth = 1;
    if (depth > 6) depth = 6;
    w.lines = [NSMutableArray arrayWithObject:path];
    w.count = 0;
    w.truncated = NO;
    walk(&w, path, (int)depth, @"  ");
    [w.lines addObject:[NSString stringWithFormat:@"entries: %u", w.count]];
    return CMCap([w.lines componentsJoinedByString:@"\n"]);
}

id CMToolMoveFile(NSDictionary *args)
{
    NSString *source = CMCheckWritable(CMCheckPath(CMString(args, @"source"))), *dest = CMCheckWritable(CMCheckPath(CMString(args, @"destination")));
    struct stat st;
    BOOL isDir = NO;
    NSString *parent = [dest stringByDeletingLastPathComponent];
    if (lstat([source fileSystemRepresentation], &st) != 0)
        CMFail(@"source not found: %@", source);
    if ([[NSFileManager defaultManager] fileExistsAtPath:dest isDirectory:&isDir] && isDir)
        dest = [dest stringByAppendingPathComponent:[source lastPathComponent]];
    else if (![[NSFileManager defaultManager] fileExistsAtPath:parent isDirectory:&isDir] || !isDir)
        CMFail(@"destination parent does not exist: %@", parent);
    if (rename([source fileSystemRepresentation], [dest fileSystemRepresentation]) != 0) {
        /* across volumes: copy then remove */
        if (errno != EXDEV || ![[NSFileManager defaultManager] copyPath:source toPath:dest handler:nil] || ![[NSFileManager defaultManager] removeFileAtPath:source handler:nil])
            CMFail(@"move failed: %s", strerror(errno));
    }
    return [NSString stringWithFormat:@"moved %@ to %@", source, dest];
}

id CMToolFileInfo(NSDictionary *args)
{
    NSString *path = CMCheckPath(CMString(args, @"path"));
    struct stat st;
    NSMutableArray *lines = [NSMutableArray arrayWithObject:[NSString stringWithFormat:@"path: %@", path]];
    struct passwd *pw;
    struct group *gr;
    char when[32];
    struct tm local;
    if (lstat([path fileSystemRepresentation], &st) != 0)
        CMFail(@"not found: %@", path);
    if (S_ISLNK(st.st_mode)) {
        char target[PATH_MAX];
        ssize_t n = readlink([path fileSystemRepresentation], target, sizeof target - 1);
        target[n > 0 ? n : 0] = 0;
        [lines addObject:@"type: symlink"];
        [lines addObject:[NSString stringWithFormat:@"target: %s", n > 0 ? target : "?"]];
    } else
        [lines addObject:S_ISDIR(st.st_mode) ? @"type: directory" : (S_ISREG(st.st_mode) ? @"type: file" : @"type: other")];
    [lines addObject:[NSString stringWithFormat:@"size: %lld", (long long)st.st_size]];
    [lines addObject:[NSString stringWithFormat:@"mode: %04o", st.st_mode & 07777]];
    [lines addObject:[NSString stringWithFormat:@"links: %d", (int)st.st_nlink]];
    pw = getpwuid(st.st_uid);
    gr = getgrgid(st.st_gid);
    [lines addObject:[NSString stringWithFormat:@"uid: %d (%s)", (int)st.st_uid, pw ? pw->pw_name : "?"]];
    [lines addObject:[NSString stringWithFormat:@"gid: %d (%s)", (int)st.st_gid, gr ? gr->gr_name : "?"]];
    localtime_r(&st.st_mtime, &local);
    strftime(when, sizeof when, "%Y-%m-%d %H:%M:%S", &local);
    [lines addObject:[NSString stringWithFormat:@"mtime: %s", when]];
    return [lines componentsJoinedByString:@"\n"];
}

static NSString *editHint(NSString *old, NSString *text)
{
    NSArray *oldLines = [old componentsSeparatedByString:@"\n"], *fileLines = [text componentsSeparatedByString:@"\n"];
    NSString *needle = [[oldLines objectAtIndex:0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    unsigned i, bestIndex = 0;
    double best = 0;
    if ([fileLines count] > 800 || ![needle length])
        return @"old_string was not found";
    for (i = 0; i < [fileLines count]; i++) {
        NSString *line = [[fileLines objectAtIndex:i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        /* a cheap similarity: the share of the needle's characters found in order in the line */
        unsigned a = 0, b = 0, matched = 0;
        double ratio;
        while (a < [needle length] && b < [line length]) {
            if ([needle characterAtIndex:a] == [line characterAtIndex:b]) {
                matched++;
                a++;
            }
            b++;
        }
        ratio = ([needle length] + [line length]) ? 2.0 * matched / ([needle length] + [line length]) : 0;
        if (ratio > best) {
            best = ratio;
            bestIndex = i;
        }
    }
    if (best >= 0.55)
        return [NSString stringWithFormat:@"old_string was not found. closest line %u (similarity %.0f%%): %@", bestIndex, best * 100, CMClip([fileLines objectAtIndex:bestIndex], 180)];
    return @"old_string was not found";
}

static unsigned countOf(NSString *text, NSString *needle)
{
    unsigned n = 0;
    NSRange at = NSMakeRange(0, 0);
    while ((at = [text rangeOfString:needle options:0 range:NSMakeRange(NSMaxRange(at), [text length] - NSMaxRange(at))]).location != NSNotFound)
        n++;
    return n;
}

id CMToolEditBlock(NSDictionary *args)
{
    NSString *path = CMOptString(args, @"file_path", nil), *old, *new, *encoding = nil, *note = nil, *text, *used;
    long long expected = CMOptInteger(args, @"expected_replacements", 1);
    NSData *data;
    unsigned long long size;
    unsigned count;
    NSString *updated;
    NSData *out;
    BOOL isDir = NO;
    if (!path)
        path = CMOptString(args, @"path", nil);
    if (!path)
        CMFail(@"missing file_path");
    path = CMCheckWritable(CMCheckPath(path));
    if (![args objectForKey:@"old_string"] || [args objectForKey:@"old_string"] == [NSNull null])
        CMFail(@"missing old_string");
    if (![args objectForKey:@"new_string"] || [args objectForKey:@"new_string"] == [NSNull null])
        CMFail(@"missing new_string");
    old = CMString(args, @"old_string");
    new = CMString(args, @"new_string");
    if (![old length])
        CMFail(@"old_string is empty");
    if (expected < 1)
        CMFail(@"expected_replacements must be >= 1");
    if (!([[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir] && !isDir))
        CMFail(@"not a file: %@", path);
    data = readBytes(path, 0, &size, &note);
    if ([note length])
        CMFail(@"file is too large to edit this way (%llu bytes)", size);
    if (hasNul(data))
        CMFail(@"refusing to edit a binary file");
    text = CMDecode(data, &encoding);
    used = text;
    count = countOf(text, old);
    if (count == 0) {
        NSString *norm = swap(swap(text, @"\r\n", @"\n"), @"\r", @"\n"), *oldNorm = swap(swap(old, @"\r\n", @"\n"), @"\r", @"\n");
        count = countOf(norm, oldNorm);
        if (count) {
            used = norm;
            old = oldNorm;
            new = swap(swap(new, @"\r\n", @"\n"), @"\r", @"\n");
        }
    }
    if (count == 0)
        CMFail(@"%@", editHint(old, text));
    if ((long long)count != expected)
        CMFail(@"found %u matches, expected %lld. Set expected_replacements to replace all of them.", count, expected);
    updated = swap(used, old, new);
    out = [updated dataUsingEncoding:[encoding isEqualToString:@"latin-1"] ? NSISOLatin1StringEncoding : NSUTF8StringEncoding allowLossyConversion:NO];
    if (!out) {
        out = [updated dataUsingEncoding:NSUTF8StringEncoding];
        encoding = @"utf-8";
    }
    if (![out writeToFile:path atomically:NO])
        CMFail(@"cannot write %@", path);
    return [NSString stringWithFormat:@"replaced %lld match(es) in %@ (%@, %u bytes)", expected, path, encoding, (unsigned)[out length]];
}

/* ---- search ---- */

@interface CMSearch : NSObject {
@public
    NSString *sid, *path, *pattern, *type, *filePattern, *note;
    BOOL ignoreCase, includeHidden, early, literal, done, stopped;
    unsigned maxResults;
    int contextLines;
    double timeoutMs;
    NSMutableArray *results;
    NSLock *lock;
    NSDate *started;
    regex_t regex;
    BOOL haveRegex;
}
@end

static NSMutableDictionary *searches = nil;
static int searchSeq = 0;

/* \d, \w and \s are accepted in a content pattern; POSIX has no such shorthand */
static NSString *translateRegex(NSString *p)
{
    NSMutableString *out = [NSMutableString string];
    unsigned i;
    for (i = 0; i < [p length]; i++) {
        unichar c = [p characterAtIndex:i];
        if (c == '\\' && i + 1 < [p length]) {
            unichar d = [p characterAtIndex:i + 1];
            i++;
            switch (d) {
            case 'd': [out appendString:@"[0-9]"]; break;
            case 'D': [out appendString:@"[^0-9]"]; break;
            case 'w': [out appendString:@"[[:alnum:]_]"]; break;
            case 'W': [out appendString:@"[^[:alnum:]_]"]; break;
            case 's': [out appendString:@"[[:space:]]"]; break;
            case 'S': [out appendString:@"[^[:space:]]"]; break;
            case 'b': [out appendString:@"[[:<:]]"]; break;
            case 't': [out appendString:@"\t"]; break;
            default: [out appendFormat:@"\\%C", d];
            }
        } else
            [out appendFormat:@"%C", c];
    }
    return out;
}

static NSString *escapeLiteral(NSString *p)
{
    NSMutableString *out = [NSMutableString string];
    unsigned i;
    for (i = 0; i < [p length]; i++) {
        unichar c = [p characterAtIndex:i];
        if (strchr("\\.[]{}()*+?^$|", c) && c < 128)
            [out appendString:@"\\"];
        [out appendFormat:@"%C", c];
    }
    return out;
}

@implementation CMSearch

- (BOOL)add:(NSString *)line
{
    BOOL more;
    [lock lock];
    if ([results count] >= maxResults) {
        note = @"max results";
        [lock unlock];
        return NO;
    }
    [results addObject:line];
    more = [results count] < maxResults;
    if (!more)
        note = @"max results";
    [lock unlock];
    return more;
}

- (BOOL)expired
{
    if (stopped) {
        note = @"stopped";
        return YES;
    }
    if (-[started timeIntervalSinceNow] * 1000.0 >= timeoutMs) {
        note = @"timeout";
        return YES;
    }
    return NO;
}

- (BOOL)nameAllowed:(NSString *)full
{
    NSString *base = [full lastPathComponent], *p = filePattern, *pathText = full;
    if (![filePattern length])
        return YES;
    if (ignoreCase) {
        base = [base lowercaseString];
        p = [p lowercaseString];
        pathText = [full lowercaseString];
    }
    return fnmatch([p UTF8String], [base UTF8String], 0) == 0 || fnmatch([p UTF8String], [pathText UTF8String], 0) == 0;
}

- (BOOL)scanContent:(NSString *)full
{
    struct stat st;
    NSData *data;
    NSString *text, *enc;
    NSArray *lines;
    unsigned i, found = 0;
    if (stat([full fileSystemRepresentation], &st) != 0 || !S_ISREG(st.st_mode) || st.st_size > 1000000)
        return YES;
    data = [NSData dataWithContentsOfFile:full];
    if (!data || (([data length] >= 1024 ? 1024 : [data length]) && memchr([data bytes], 0, [data length] >= 1024 ? 1024 : [data length])))
        return YES;
    text = CMDecode(data, &enc);
    lines = [text componentsSeparatedByString:@"\n"];
    for (i = 0; i < [lines count]; i++) {
        const char *line = [[lines objectAtIndex:i] UTF8String];
        if (line && regexec(&regex, line, 0, NULL, 0) == 0) {
            int start = (int)i - contextLines, end = (int)i + contextLines + 1, j;
            NSMutableArray *block = [NSMutableArray arrayWithObject:[NSString stringWithFormat:@"%@:%u: %@", full, i + 1, CMClip([lines objectAtIndex:i], 400)]];
            if (start < 0) start = 0;
            if (end > (int)[lines count]) end = (int)[lines count];
            for (j = start; j < end; j++)
                if (j != (int)i)
                    [block addObject:[NSString stringWithFormat:@"%@:%d- %@", full, j + 1, CMClip([lines objectAtIndex:j], 200)]];
            if (![self add:[block componentsJoinedByString:@"\n"]])
                return NO;
            if (++found >= 40)
                return YES;
        }
    }
    return YES;
}

- (BOOL)scanFile:(NSString *)full
{
    if ([type isEqualToString:@"files"]) {
        NSString *base = [full lastPathComponent], *p = pattern, *pathText = full;
        BOOL glob, hit, exact;
        if (ignoreCase) {
            base = [base lowercaseString];
            p = [p lowercaseString];
            pathText = [full lowercaseString];
        }
        glob = strchr([p UTF8String], '*') || strchr([p UTF8String], '?') || strchr([p UTF8String], '[');
        hit = glob ? (fnmatch([p UTF8String], [base UTF8String], 0) == 0 || fnmatch([p UTF8String], [pathText UTF8String], 0) == 0) : [pathText rangeOfString:p].location != NSNotFound;
        exact = [base isEqualToString:p];
        if (!hit)
            return YES;
        if (![self add:full])
            return NO;
        if (early && exact) {
            note = @"exact name";
            return NO;
        }
        return YES;
    }
    return [self scanContent:full];
}

/* a depth-first walk; NO when the search should stop */
- (BOOL)walk:(NSString *)directory
{
    DIR *d = opendir([directory fileSystemRepresentation]);
    struct dirent *e;
    NSMutableArray *dirs = [NSMutableArray array], *files = [NSMutableArray array];
    unsigned i;
    if (!d)
        return YES;
    if ([self expired]) {
        closedir(d);
        return NO;
    }
    while ((e = readdir(d))) {
        NSString *name;
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, ".."))
            continue;
        name = [NSString stringWithUTF8String:e->d_name];
        if (!name || (!includeHidden && [name hasPrefix:@"."]))
            continue;
        if (e->d_type == DT_DIR)
            [dirs addObject:name];
        else if (e->d_type == DT_REG || e->d_type == DT_UNKNOWN || e->d_type == DT_LNK)
            [files addObject:name];
    }
    closedir(d);
    for (i = 0; i < [files count]; i++) {
        NSString *full = [directory stringByAppendingPathComponent:[files objectAtIndex:i]];
        if ([self expired])
            return NO;
        if (![self nameAllowed:full])
            continue;
        if (![self scanFile:full])
            return NO;
    }
    for (i = 0; i < [dirs count]; i++) {
        NSString *full = [directory stringByAppendingPathComponent:[dirs objectAtIndex:i]];
        if ([[NSArray arrayWithObjects:@"/dev", @"/automount", @"/.vol", @"/net", @"/Network", nil] containsObject:full])
            continue;
        if (![self walk:full])
            return NO;
    }
    return YES;
}

- (void)run:(id)unused
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    struct stat st;
    (void)unused;
    @try {
        if ([type isEqualToString:@"content"]) {
            NSString *p = literal ? escapeLiteral(pattern) : translateRegex(pattern);
            int flags = REG_EXTENDED | REG_NOSUB | (ignoreCase ? REG_ICASE : 0);
            if (regcomp(&regex, [p UTF8String], flags) != 0) {
                note = @"bad regex";
                done = YES;
                [pool release];
                return;
            }
            haveRegex = YES;
        }
        if (stat([path fileSystemRepresentation], &st) == 0 && S_ISREG(st.st_mode))
            [self scanFile:path];
        else
            [self walk:path];
    } @catch (NSException *e) {
        note = [NSString stringWithFormat:@"error: %@", [e reason]];
    }
    done = YES;
    [pool release];
}

- (NSString *)formatFrom:(unsigned)offset length:(unsigned)length
{
    unsigned total, end;
    NSArray *chunk;
    NSMutableArray *lines;
    [lock lock];
    total = [results count];
    if (offset > total)
        offset = total;
    end = offset + length > total ? total : offset + length;
    chunk = [results subarrayWithRange:NSMakeRange(offset, end - offset)];
    lines = [NSMutableArray arrayWithObjects:[NSString stringWithFormat:@"sessionId: %@", sid], [NSString stringWithFormat:@"path: %@", path],
        [NSString stringWithFormat:@"searchType: %@", type], [NSString stringWithFormat:@"pattern: %@", CMClip(pattern, 200)], [NSString stringWithFormat:@"done: %@", done ? @"true" : @"false"],
        [NSString stringWithFormat:@"matched: %u", total], [NSString stringWithFormat:@"showing: %u-%u", offset, end], nil];
    if ([note length])
        [lines addObject:[NSString stringWithFormat:@"note: %@", note]];
    [lines addObject:@"---"];
    [lines addObject:[chunk count] ? [chunk componentsJoinedByString:@"\n"] : (done ? @"no matches" : @"no matches yet")];
    [lock unlock];
    return CMCap([lines componentsJoinedByString:@"\n"]);
}

@end

id CMToolStartSearch(NSDictionary *args)
{
    NSString *path = CMCheckPath(CMString(args, @"path")), *pattern = CMString(args, @"pattern"), *type = CMOptString(args, @"searchType", @"files");
    CMSearch *s;
    long long maxResults = CMOptInteger(args, @"maxResults", 200), context = CMOptInteger(args, @"contextLines", 2), timeout = CMOptInteger(args, @"timeout_ms", 15000);
    NSDate *deadline;
    if (![pattern length])
        CMFail(@"pattern is empty");
    if (![type isEqualToString:@"files"] && ![type isEqualToString:@"content"])
        CMFail(@"searchType must be files or content");
    if (![[NSFileManager defaultManager] fileExistsAtPath:path])
        CMFail(@"not found: %@", path);
    if (maxResults < 1) maxResults = 1;
    if (maxResults > 1000) maxResults = 1000;
    if (context < 0) context = 0;
    if (context > 5) context = 5;
    if (timeout < 500) timeout = 500;
    if (timeout > 60000) timeout = 60000;
    s = [[[CMSearch alloc] init] autorelease];
    s->sid = [[NSString stringWithFormat:@"search-%d", ++searchSeq] retain];
    s->path = [path retain];
    s->pattern = [pattern retain];
    s->type = [type retain];
    s->filePattern = [CMOptString(args, @"filePattern", @"") retain];
    s->note = @"";
    s->ignoreCase = CMOptBool(args, @"ignoreCase", YES);
    s->includeHidden = CMOptBool(args, @"includeHidden", NO);
    s->literal = CMOptBool(args, @"literalSearch", NO);
    s->early = [args objectForKey:@"earlyTermination"] && [args objectForKey:@"earlyTermination"] != [NSNull null] ? CMOptBool(args, @"earlyTermination", NO) : [type isEqualToString:@"files"];
    s->maxResults = (unsigned)maxResults;
    s->contextLines = (int)context;
    s->timeoutMs = (double)timeout;
    s->results = [[NSMutableArray alloc] init];
    s->lock = [[NSLock alloc] init];
    s->started = [[NSDate date] retain];
    if (!searches)
        searches = [[NSMutableDictionary alloc] init];
    [searches setObject:s forKey:s->sid];
    [NSThread detachNewThreadSelector:@selector(run:) toTarget:s withObject:nil];
    deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
    while ([deadline timeIntervalSinceNow] > 0 && !s->done && [s->results count] < 40)
        usleep(50000);
    return [s formatFrom:0 length:40];
}

id CMToolMoreSearch(NSDictionary *args)
{
    NSString *sid = CMString(args, @"sessionId");
    CMSearch *s = [searches objectForKey:sid];
    long long offset = CMOptInteger(args, @"offset", 0), length = CMOptInteger(args, @"length", 100);
    NSDate *deadline;
    if (!s)
        CMFail(@"no search session %@", sid);
    if (length < 1) length = 1;
    if (length > 300) length = 300;
    if (offset < 0) offset = 0;
    if (!s->done && offset >= (long long)[s->results count]) {
        deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
        while ([deadline timeIntervalSinceNow] > 0 && !s->done)
            usleep(50000);
    }
    return [s formatFrom:(unsigned)offset length:(unsigned)length];
}

id CMToolStopSearch(NSDictionary *args)
{
    NSString *sid = CMString(args, @"sessionId");
    CMSearch *s = [searches objectForKey:sid];
    NSDate *deadline;
    if (!s)
        CMFail(@"no search session %@", sid);
    s->stopped = YES;
    deadline = [NSDate dateWithTimeIntervalSinceNow:1.5];
    while ([deadline timeIntervalSinceNow] > 0 && !s->done)
        usleep(50000);
    return [s formatFrom:0 length:20];
}

id CMToolListSearches(NSDictionary *args)
{
    NSMutableArray *lines = [NSMutableArray array];
    NSEnumerator *each = [searches objectEnumerator];
    CMSearch *s;
    (void)args;
    if (![searches count])
        return @"no searches";
    while ((s = [each nextObject]))
        [lines addObject:[NSString stringWithFormat:@"%@ type=%@ done=%@ matches=%u pattern=%@", s->sid, s->type, s->done ? @"true" : @"false", (unsigned)[s->results count], CMClip(s->pattern, 80)]];
    return [lines componentsJoinedByString:@"\n"];
}

/* ---- fetching a URL: this Mac's own TLS cannot be reached from here, so ask curl, which every Mac has ---- */

static NSString *readURL(NSString *url)
{
    NSString *out = nil;
    NSData *data;
    NSString *text, *encoding = nil;
    /* redirects may only lead to http, https or ftp; curl before 7.19.4 (Tiger) has no such option, so there redirects are not followed */
    int code = CMRunProgram([NSArray arrayWithObjects:@"/usr/bin/curl", @"-sSL", @"--proto", @"=http,https,ftp", @"--proto-redir", @"=http,https,ftp", @"--max-time", @"20", @"--max-filesize", @"200000", @"-A", @"ppc-commander", @"--", url, nil], nil, 25, nil, &out);
    (void)swap;
    if (code == 2 || (code != 0 && [out rangeOfString:@"proto"].location != NSNotFound && [out rangeOfString:@"option"].location != NSNotFound))
        code = CMRunProgram([NSArray arrayWithObjects:@"/usr/bin/curl", @"-sS", @"--max-time", @"20", @"--max-filesize", @"200000", @"-A", @"ppc-commander", @"--", url, nil], nil, 25, nil, &out);
    if (code != 0 && ![out length])
        CMFail(@"fetch failed (curl exit %d). Old versions of curl cannot make modern HTTPS connections.", code);
    data = [out dataUsingEncoding:NSUTF8StringEncoding];
    text = CMDecode(data, &encoding);
    return CMCap([NSString stringWithFormat:@"url: %@\nbytes: %u\nencoding: %@\n---\n%@", url, (unsigned)[data length], encoding, text]);
}
