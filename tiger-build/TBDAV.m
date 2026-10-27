#import "TBDAV.h"
#import "TBSMB.h"
#import "TBEngine.h"
#import "TBSupport.h"
#include <sys/socket.h>
#include <sys/mount.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include "smb2.h"
#include "libsmb2.h"

#define CHUNK (256 * 1024)

/* ---- one share: its connection, used by one request at a time ---- */

@interface TBDAVShare : NSObject
{
@public
    NSString *name;
    NSDictionary *target;
    NSLock *lock;
    void *context;
}
@end

@implementation TBDAVShare
- (void)dealloc
{
    [TBSMB disconnect:context];
    [name release];
    [target release];
    [lock release];
    [super dealloc];
}
@end

static NSMutableDictionary *shares = nil;        /* name -> TBDAVShare */
static NSString *token = nil;
static int listener = -1, listenPort = 0;
static NSObject *serverLock = nil;

/* the connection, made on first use and again after it was lost; the caller holds the share's lock */
static struct smb2_context *connection(TBDAVShare *s)
{
    if (!s->context) {
        NSString *problem = nil;
        s->context = [TBSMB connectTarget:s->target problem:&problem];
    }
    return s->context;
}

static void lostConnection(TBDAVShare *s)
{
    [TBSMB disconnect:s->context];
    s->context = NULL;
}

/* ---- text helpers ---- */

static NSString *rfc1123(uint64_t secs)
{
    static const char *days[] = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
    static const char *months[] = {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};
    time_t t = (time_t)secs;
    struct tm tm;
    gmtime_r(&t, &tm);
    return [NSString stringWithFormat:@"%s, %02d %s %04d %02d:%02d:%02d GMT", days[tm.tm_wday], tm.tm_mday, months[tm.tm_mon], tm.tm_year + 1900, tm.tm_hour, tm.tm_min, tm.tm_sec];
}

static NSString *iso8601(uint64_t secs)
{
    time_t t = (time_t)secs;
    struct tm tm;
    gmtime_r(&t, &tm);
    return [NSString stringWithFormat:@"%04d-%02d-%02dT%02d:%02d:%02dZ", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec];
}

static NSString *xmlEscape(NSString *s)
{
    NSMutableString *m = [NSMutableString stringWithString:s];
    [m replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, [m length])];
    [m replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, [m length])];
    [m replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, [m length])];
    return m;
}

/* everything but letters, digits and -._~/ as %XX (UTF-8) */
static NSString *hrefEscape(NSString *s)
{
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    const unsigned char *b = [d bytes];
    NSMutableString *out = [NSMutableString string];
    NSUInteger i;
    for (i = 0; i < [d length]; i++) {
        unsigned char c = b[i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' || c == '~' || c == '/')
            [out appendFormat:@"%c", c];
        else
            [out appendFormat:@"%%%02X", c];
    }
    return out;
}

/* NSString's -longLongValue is 10.5 and later; Tiger has -intValue only */
static long long llv(NSString *s)
{
    return s ? strtoll([s UTF8String], NULL, 10) : 0;
}

static NSString *lastComponent(NSString *path)
{
    NSRange r = [path rangeOfString:@"/" options:NSBackwardsSearch];
    return r.location == NSNotFound ? path : [path substringFromIndex:r.location + 1];
}

/* ---- the connection to the Finder ---- */

typedef struct {
    int fd;
    NSMutableData *buffer;       /* bytes read and not used yet */
} Conn;

static BOOL sendAll(int fd, const void *bytes, size_t n)
{
    const char *p = bytes;
    while (n > 0) {
        ssize_t w = send(fd, p, n, 0);
        if (w < 0) {
            if (errno == EINTR)
                continue;
            return NO;
        }
        p += w;
        n -= (size_t)w;
    }
    return YES;
}

/* more bytes into the buffer; NO at the end of the connection */
static BOOL fill(Conn *c)
{
    char tmp[65536];
    ssize_t n;
    do
        n = recv(c->fd, tmp, sizeof tmp, 0);
    while (n < 0 && errno == EINTR);
    if (n <= 0)
        return NO;
    [c->buffer appendBytes:tmp length:(NSUInteger)n];
    return YES;
}

static NSString *statusText(int code)
{
    switch (code) {
    case 100: return @"Continue";
    case 200: return @"OK";
    case 201: return @"Created";
    case 204: return @"No Content";
    case 206: return @"Partial Content";
    case 207: return @"Multi-Status";
    case 400: return @"Bad Request";
    case 403: return @"Forbidden";
    case 404: return @"Not Found";
    case 405: return @"Method Not Allowed";
    case 409: return @"Conflict";
    case 412: return @"Precondition Failed";
    case 416: return @"Requested Range Not Satisfiable";
    case 502: return @"Bad Gateway";
    case 507: return @"Insufficient Storage";
    default: return @"Error";
    }
}

/* TB_DEBUG_DAV=file: every request and the answer, for finding out what the Finder asks */
static void dlog(NSString *line)
{
    const char *path = getenv("TB_DEBUG_DAV");
    FILE *f;
    if (!path || !(f = fopen(path, "a")))
        return;
    fprintf(f, "%s\n", [line UTF8String]);
    fclose(f);
}

static BOOL respond(Conn *c, int code, NSString *extraHeaders, NSData *body, BOOL head)
{
    dlog([NSString stringWithFormat:@"  -> %d", code]);
    NSMutableString *h = [NSMutableString stringWithFormat:@"HTTP/1.1 %d %@\r\nServer: TigerBuild-DAV\r\nDAV: 1, 2\r\nMS-Author-Via: DAV\r\nContent-Length: %lu\r\n%@\r\n",
        code, statusText(code), (unsigned long)(body ? [body length] : 0), extraHeaders ? extraHeaders : @""];
    NSData *hd = [h dataUsingEncoding:NSUTF8StringEncoding];
    if (!sendAll(c->fd, [hd bytes], [hd length]))
        return NO;
    if (body && [body length] && !head)
        return sendAll(c->fd, [body bytes], [body length]);
    return YES;
}

static BOOL respondXML(Conn *c, int code, NSString *xml, NSString *extra)
{
    return respond(c, code, [NSString stringWithFormat:@"Content-Type: application/xml; charset=\"utf-8\"\r\n%@", extra ? extra : @""], [xml dataUsingEncoding:NSUTF8StringEncoding], NO);
}

static int errorStatus(int rc)
{
    switch (-rc) {
    case ENOENT: return 404;
    case EEXIST: return 405;
    case EACCES: case EPERM: case EROFS: return 403;
    case ENOTEMPTY: case ENOTDIR: return 409;
    case ENOSPC: case EDQUOT: return 507;
    default: return 502;
    }
}

/* ---- the share's files ---- */

static BOOL isConnectionLoss(int rc)
{
    return rc == -ECONNRESET || rc == -ENOTCONN || rc == -EPIPE || rc == -ETIMEDOUT || rc == -EIO || rc == -ECONNABORTED;
}

static void entryXML(NSMutableString *x, NSString *href, NSString *displayName, BOOL dir, struct smb2_stat_64 *st, struct smb2_statvfs *vfs)
{
    uint64_t mtime = st ? st->smb2_mtime : 0, btime = st && st->smb2_btime ? st->smb2_btime : mtime;
    [x appendFormat:@"<D:response><D:href>%@</D:href><D:propstat><D:prop><D:displayname>%@</D:displayname>", hrefEscape(href), xmlEscape(displayName)];
    if (dir)
        [x appendString:@"<D:resourcetype><D:collection/></D:resourcetype>"];
    else
        [x appendFormat:@"<D:resourcetype/><D:getcontentlength>%llu</D:getcontentlength><D:getcontenttype>application/octet-stream</D:getcontenttype>", (unsigned long long)st->smb2_size];
    [x appendFormat:@"<D:getlastmodified>%@</D:getlastmodified><D:creationdate>%@</D:creationdate><D:getetag>\"%llx-%llx\"</D:getetag>",
        rfc1123(mtime), iso8601(btime), (unsigned long long)(st ? st->smb2_size : 0), (unsigned long long)mtime];
    [x appendString:@"<D:supportedlock><D:lockentry><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockentry></D:supportedlock>"];
    if (vfs && dir)
        [x appendFormat:@"<D:quota-available-bytes>%llu</D:quota-available-bytes><D:quota-used-bytes>%llu</D:quota-used-bytes>",
            (unsigned long long)vfs->f_bavail * vfs->f_frsize, (unsigned long long)(vfs->f_blocks - vfs->f_bfree) * vfs->f_frsize];
    [x appendString:@"</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>\n"];
}

/* deletes a file, or a folder and everything in it */
static int removeTree(struct smb2_context *smb2, NSString *path)
{
    struct smb2_stat_64 st;
    int rc = smb2_stat(smb2, [path UTF8String], &st);
    if (rc < 0)
        return rc;
    if (st.smb2_type == SMB2_TYPE_DIRECTORY) {
        struct smb2dir *dir = smb2_opendir(smb2, [path UTF8String]);
        struct smb2dirent *ent;
        NSMutableArray *names = [NSMutableArray array];
        unsigned i;
        if (!dir)
            return -EIO;
        while ((ent = smb2_readdir(smb2, dir)))
            if (strcmp(ent->name, ".") && strcmp(ent->name, ".."))
                [names addObject:[NSString stringWithUTF8String:ent->name]];
        smb2_closedir(smb2, dir);
        for (i = 0; i < [names count]; i++) {
            rc = removeTree(smb2, [path length] ? [NSString stringWithFormat:@"%@/%@", path, [names objectAtIndex:i]] : [names objectAtIndex:i]);
            if (rc < 0)
                return rc;
        }
        return smb2_rmdir(smb2, [path UTF8String]);
    }
    return smb2_unlink(smb2, [path UTF8String]);
}

/* a copy of a file or folder inside the share */
static int copyTree(struct smb2_context *smb2, NSString *from, NSString *to)
{
    struct smb2_stat_64 st;
    int rc = smb2_stat(smb2, [from UTF8String], &st);
    if (rc < 0)
        return rc;
    if (st.smb2_type == SMB2_TYPE_DIRECTORY) {
        struct smb2dir *dir;
        struct smb2dirent *ent;
        NSMutableArray *names = [NSMutableArray array];
        unsigned i;
        rc = smb2_mkdir(smb2, [to UTF8String]);
        if (rc < 0 && rc != -EEXIST)
            return rc;
        dir = smb2_opendir(smb2, [from UTF8String]);
        if (!dir)
            return -EIO;
        while ((ent = smb2_readdir(smb2, dir)))
            if (strcmp(ent->name, ".") && strcmp(ent->name, ".."))
                [names addObject:[NSString stringWithUTF8String:ent->name]];
        smb2_closedir(smb2, dir);
        for (i = 0; i < [names count]; i++) {
            NSString *n = [names objectAtIndex:i];
            rc = copyTree(smb2, [from length] ? [NSString stringWithFormat:@"%@/%@", from, n] : n, [to length] ? [NSString stringWithFormat:@"%@/%@", to, n] : n);
            if (rc < 0)
                return rc;
        }
        return 0;
    } else {
        struct smb2fh *in = smb2_open(smb2, [from UTF8String], O_RDONLY), *out;
        uint8_t *buf = malloc(CHUNK);
        uint64_t offset = 0;
        int n;
        if (!in || !buf) {
            free(buf);
            if (in)
                smb2_close(smb2, in);
            return in ? -ENOMEM : -ENOENT;
        }
        out = smb2_open(smb2, [to UTF8String], O_WRONLY | O_CREAT | O_TRUNC);
        if (!out) {
            smb2_close(smb2, in);
            free(buf);
            return -EACCES;
        }
        while ((n = smb2_pread(smb2, in, buf, CHUNK, offset)) > 0) {
            int put = smb2_pwrite(smb2, out, buf, (uint32_t)n, offset);
            if (put <= 0) {
                n = -EIO;
                break;
            }
            offset += (uint64_t)n;
        }
        smb2_close(smb2, in);
        smb2_close(smb2, out);
        free(buf);
        return n < 0 ? n : 0;
    }
}

/* ---- one request ---- */

typedef struct {
    NSString *method, *path;          /* the path is decoded, after the secret and the share's name */
    NSString *shareName;              /* "" at the top */
    NSDictionary *headers;            /* names in lower case */
    NSString *rawPath;
} Request;

static NSString *header(Request *r, NSString *name)
{
    return [r->headers objectForKey:name];
}

/* the body the client sends, to a buffer in memory (small requests: PROPFIND and LOCK send XML) */
static NSData *readBody(Conn *c, Request *r)
{
    NSString *len = header(r, @"content-length");
    NSMutableData *body = [NSMutableData data];
    long long n = len ? llv(len) : 0;
    if (n > 1048576)
        n = 0;
    while ((long long)[c->buffer length] < n)
        if (!fill(c))
            return body;
    if (n > 0) {
        [body appendBytes:[c->buffer bytes] length:(NSUInteger)n];
        [c->buffer replaceBytesInRange:NSMakeRange(0, (NSUInteger)n) withBytes:NULL length:0];
    }
    return body;
}

static void discardBody(Conn *c, Request *r)
{
    NSString *len = header(r, @"content-length");
    long long n = len ? llv(len) : 0;
    while (n > 0) {
        long long have = (long long)[c->buffer length];
        if (have > 0) {
            long long take = have < n ? have : n;
            [c->buffer replaceBytesInRange:NSMakeRange(0, (NSUInteger)take) withBytes:NULL length:0];
            n -= take;
        } else if (!fill(c))
            return;
    }
}

static NSString *joinedPath(NSString *base, NSString *name)
{
    return [base length] ? [NSString stringWithFormat:@"%@/%@", base, name] : name;
}

/* the part of an address after the secret and the share: "" or "folder/file" (nil when it climbs out) */
static NSString *cleanPath(NSString *p)
{
    NSMutableArray *parts = [NSMutableArray array];
    NSArray *raw = [p componentsSeparatedByString:@"/"];
    unsigned i;
    for (i = 0; i < [raw count]; i++) {
        NSString *s = [raw objectAtIndex:i];
        if ([s length] == 0 || [s isEqualToString:@"."])
            continue;
        if ([s isEqualToString:@".."])
            return nil;
        [parts addObject:s];
    }
    return [parts componentsJoinedByString:@"/"];
}

static BOOL handlePropfind(Conn *c, Request *r, TBDAVShare *s)
{
    NSString *depth = header(r, @"depth"), *base = [NSString stringWithFormat:@"/%@/%@", token, hrefEscape(r->shareName)];
    NSMutableString *x = [NSMutableString stringWithString:@"<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:multistatus xmlns:D=\"DAV:\">\n"];
    struct smb2_stat_64 st;
    struct smb2_statvfs vfs;
    BOOL haveVfs;
    int rc, status = 207;
    NSString *selfHref;
    discardBody(c, r);
    [s->lock lock];
    if (!connection(s)) {
        [s->lock unlock];
        return respond(c, 502, nil, nil, NO);
    }
    {
        struct smb2_context *smb2 = s->context;
        rc = [r->path length] ? smb2_stat(smb2, [r->path UTF8String], &st) : 0;
        if ([r->path length] == 0) {
            memset(&st, 0, sizeof st);
            st.smb2_type = SMB2_TYPE_DIRECTORY;
            st.smb2_mtime = (uint64_t)time(NULL);
        }
        if (rc < 0) {
            if (isConnectionLoss(rc))
                lostConnection(s);
            [s->lock unlock];
            return respond(c, errorStatus(rc), nil, nil, NO);
        }
        haveVfs = smb2_statvfs(smb2, [r->path length] ? [r->path UTF8String] : "", &vfs) == 0;
        selfHref = [r->path length] ? [NSString stringWithFormat:@"%@/%@%@", base, r->path, st.smb2_type == SMB2_TYPE_DIRECTORY ? @"/" : @""] : [base stringByAppendingString:@"/"];
        entryXML(x, selfHref, [r->path length] ? lastComponent(r->path) : r->shareName, st.smb2_type == SMB2_TYPE_DIRECTORY, &st, haveVfs ? &vfs : NULL);
        if (st.smb2_type == SMB2_TYPE_DIRECTORY && ![depth isEqualToString:@"0"]) {
            struct smb2dir *dir = smb2_opendir(smb2, [r->path UTF8String] ? [r->path UTF8String] : "");
            struct smb2dirent *ent;
            if (dir) {
                while ((ent = smb2_readdir(smb2, dir))) {
                    NSString *name;
                    BOOL isDir = ent->st.smb2_type == SMB2_TYPE_DIRECTORY;
                    if (!strcmp(ent->name, ".") || !strcmp(ent->name, ".."))
                        continue;
                    name = [NSString stringWithUTF8String:ent->name];
                    if (!name)
                        continue;
                    entryXML(x, [NSString stringWithFormat:@"%@/%@%@", selfHref, name, isDir ? @"/" : @""], name, isDir, &ent->st, NULL);
                }
                smb2_closedir(smb2, dir);
            }
        }
    }
    [s->lock unlock];
    [x appendString:@"</D:multistatus>\n"];
    return respondXML(c, status, x, nil);
}

static BOOL handleGet(Conn *c, Request *r, TBDAVShare *s, BOOL head)
{
    struct smb2_stat_64 st;
    struct smb2fh *fh;
    NSString *range = header(r, @"range"), *h;
    uint64_t start = 0, end;
    int code = 200, rc;
    uint8_t *buf;
    [s->lock lock];
    if (!connection(s)) {
        [s->lock unlock];
        return respond(c, 502, nil, nil, head);
    }
    rc = [r->path length] ? smb2_stat(s->context, [r->path UTF8String], &st) : -EISDIR;
    if (rc < 0 || st.smb2_type == SMB2_TYPE_DIRECTORY) {
        if (isConnectionLoss(rc))
            lostConnection(s);
        [s->lock unlock];
        return respond(c, rc < 0 && rc != -EISDIR ? errorStatus(rc) : 405, nil, nil, head);
    }
    end = st.smb2_size ? st.smb2_size - 1 : 0;
    if ([range hasPrefix:@"bytes="]) {
        NSArray *p = [[range substringFromIndex:6] componentsSeparatedByString:@"-"];
        if ([p count] == 2) {
            NSString *a = [p objectAtIndex:0], *b = [p objectAtIndex:1];
            if ([a length]) {
                start = (uint64_t)llv(a);
                if ([b length])
                    end = (uint64_t)llv(b);
            } else if ([b length]) {
                uint64_t n = (uint64_t)llv(b);
                start = n > st.smb2_size ? 0 : st.smb2_size - n;
            }
            if (end >= st.smb2_size)
                end = st.smb2_size ? st.smb2_size - 1 : 0;
            if (start > end && st.smb2_size) {
                [s->lock unlock];
                return respond(c, 416, [NSString stringWithFormat:@"Content-Range: bytes */%llu\r\n", (unsigned long long)st.smb2_size], nil, head);
            }
            code = 206;
        }
    }
    fh = head ? NULL : smb2_open(s->context, [r->path UTF8String], O_RDONLY);
    [s->lock unlock];
    if (!head && !fh)
        return respond(c, 403, nil, nil, NO);
    {
        uint64_t length = st.smb2_size ? end - start + 1 : 0;
        h = [NSString stringWithFormat:@"Content-Type: application/octet-stream\r\nAccept-Ranges: bytes\r\nLast-Modified: %@\r\nETag: \"%llx-%llx\"\r\n%@",
            rfc1123(st.smb2_mtime), (unsigned long long)st.smb2_size, (unsigned long long)st.smb2_mtime,
            code == 206 ? [NSString stringWithFormat:@"Content-Range: bytes %llu-%llu/%llu\r\n", (unsigned long long)start, (unsigned long long)end, (unsigned long long)st.smb2_size] : @""];
        {
            NSString *line = [NSString stringWithFormat:@"HTTP/1.1 %d %@\r\nServer: TigerBuild-DAV\r\nDAV: 1, 2\r\nContent-Length: %llu\r\n%@\r\n", code, statusText(code), (unsigned long long)length, h];
            NSData *hd = [line dataUsingEncoding:NSUTF8StringEncoding];
            if (!sendAll(c->fd, [hd bytes], [hd length])) {
                if (fh) { [s->lock lock]; smb2_close(s->context, fh); [s->lock unlock]; }
                return NO;
            }
        }
        if (head || length == 0) {
            if (fh) { [s->lock lock]; smb2_close(s->context, fh); [s->lock unlock]; }
            return YES;
        }
        buf = malloc(CHUNK);
        if (!buf) {
            [s->lock lock]; smb2_close(s->context, fh); [s->lock unlock];
            return NO;
        }
        {
            uint64_t offset = start, left = length;
            BOOL ok = YES;
            while (left > 0 && ok) {
                uint32_t want = (uint32_t)(left < CHUNK ? left : CHUNK);
                int n;
                [s->lock lock];
                n = s->context ? smb2_pread(s->context, fh, buf, want, offset) : -ECONNRESET;
                if (isConnectionLoss(n))
                    lostConnection(s);
                [s->lock unlock];
                if (n <= 0 || !sendAll(c->fd, buf, (size_t)n)) {
                    ok = NO;
                    break;
                }
                offset += (uint64_t)n;
                left -= (uint64_t)n;
            }
            free(buf);
            [s->lock lock];
            if (s->context)
                smb2_close(s->context, fh);
            [s->lock unlock];
            return ok;
        }
    }
}

/* the request body goes to the file as it arrives, in pieces */
static BOOL handlePut(Conn *c, Request *r, TBDAVShare *s)
{
    NSString *len = header(r, @"content-length"), *enc = [header(r, @"transfer-encoding") lowercaseString];
    BOOL chunked = enc != nil && [enc rangeOfString:@"chunked"].length > 0, existed;   /* not a message to nil: a struct result from nil is garbage on PowerPC */
    long long left = len ? llv(len) : 0;
    struct smb2_stat_64 st;
    struct smb2fh *fh;
    uint64_t offset = 0;
    int status = 201, failure = 0;
    long long chunkLeft = 0;
    BOOL finished = NO;
    if ([r->path length] == 0)
        return respond(c, 405, nil, nil, NO);
    if ([[header(r, @"expect") lowercaseString] hasPrefix:@"100"]) {
        const char *go = "HTTP/1.1 100 Continue\r\n\r\n";
        if (!sendAll(c->fd, go, strlen(go)))
            return NO;
    }
    [s->lock lock];
    if (!connection(s)) {
        [s->lock unlock];
        discardBody(c, r);
        return respond(c, 502, nil, nil, NO);
    }
    dlog(@"  put: connected");
    existed = smb2_stat(s->context, [r->path UTF8String], &st) == 0;
    dlog([NSString stringWithFormat:@"  put: statted, existed=%d", existed]);
    if (existed && st.smb2_type == SMB2_TYPE_DIRECTORY) {
        [s->lock unlock];
        discardBody(c, r);
        return respond(c, 405, nil, nil, NO);
    }
    fh = smb2_open(s->context, [r->path UTF8String], O_WRONLY | O_CREAT | O_TRUNC);
    [s->lock unlock];
    dlog([NSString stringWithFormat:@"  put: opened, fh=%p", fh]);
    if (!fh) {
        discardBody(c, r);
        return respond(c, 409, nil, nil, NO);
    }
    status = existed ? 204 : 201;
    while (!finished) {
        NSUInteger have;
        long long take;
        if (chunked && chunkLeft == 0) {
            /* the size line of the next piece */
            NSRange eol;
            for (;;) {
                const char *b = [c->buffer bytes];
                NSUInteger i, n = [c->buffer length];
                eol = NSMakeRange(NSNotFound, 0);
                for (i = 0; i + 1 < n; i++)
                    if (b[i] == '\r' && b[i + 1] == '\n') {
                        eol = NSMakeRange(i, 2);
                        break;
                    }
                if (eol.location != NSNotFound)
                    break;
                if (!fill(c)) {
                    failure = 1;
                    break;
                }
            }
            if (failure)
                break;
            {
                NSString *line = [[[NSString alloc] initWithBytes:[c->buffer bytes] length:eol.location encoding:NSASCIIStringEncoding] autorelease];
                chunkLeft = (long long)strtoull([line UTF8String], NULL, 16);
                [c->buffer replaceBytesInRange:NSMakeRange(0, eol.location + 2) withBytes:NULL length:0];
                if (chunkLeft == 0) {
                    /* the trailer ends with an empty line */
                    for (;;) {
                        const char *b = [c->buffer bytes];
                        NSUInteger n = [c->buffer length];
                        if (n >= 2 && b[0] == '\r' && b[1] == '\n') {
                            [c->buffer replaceBytesInRange:NSMakeRange(0, 2) withBytes:NULL length:0];
                            break;
                        }
                        if (n >= 4) {
                            NSUInteger k;
                            BOOL done = NO;
                            for (k = 0; k + 3 < n; k++)
                                if (!memcmp(b + k, "\r\n\r\n", 4)) {
                                    [c->buffer replaceBytesInRange:NSMakeRange(0, k + 4) withBytes:NULL length:0];
                                    done = YES;
                                    break;
                                }
                            if (done)
                                break;
                        }
                        if (!fill(c)) {
                            failure = 1;
                            break;
                        }
                    }
                    finished = YES;
                    continue;
                }
            }
        }
        take = chunked ? chunkLeft : left;
        if (!chunked && left <= 0)
            break;
        have = [c->buffer length];
        if (have == 0) {
            if (!fill(c)) {
                failure = 1;
                break;
            }
            have = [c->buffer length];
        }
        if ((long long)have > take)
            have = (NSUInteger)take;
        if (have > CHUNK)
            have = CHUNK;
        {
            int put;
            [s->lock lock];
            put = s->context ? smb2_pwrite(s->context, fh, (const uint8_t *)[c->buffer bytes], (uint32_t)have, offset) : -ECONNRESET;
            if (isConnectionLoss(put))
                lostConnection(s);
            [s->lock unlock];
            if (put < 0) {
                failure = put;
                break;
            }
            if ((NSUInteger)put < have)
                have = (NSUInteger)put;
        }
        offset += have;
        [c->buffer replaceBytesInRange:NSMakeRange(0, have) withBytes:NULL length:0];
        if (chunked) {
            chunkLeft -= (long long)have;
            if (chunkLeft == 0) {
                while ([c->buffer length] < 2)
                    if (!fill(c)) { failure = 1; break; }
                if (!failure)
                    [c->buffer replaceBytesInRange:NSMakeRange(0, 2) withBytes:NULL length:0];
            }
        } else
            left -= (long long)have;
        if (failure)
            break;
    }
    dlog(@"  put: closing");
    [s->lock lock];
    if (s->context)
        smb2_close(s->context, fh);
    [s->lock unlock];
    dlog(@"  put: closed");
    if (failure)
        return respond(c, failure < 0 ? errorStatus(failure) : 400, @"Connection: close\r\n", nil, NO) && NO;
    return respond(c, status, nil, nil, NO);
}

static NSString *destinationPath(Request *r, NSString *shareName, int *status)
{
    NSString *dest = header(r, @"destination"), *prefix = [NSString stringWithFormat:@"/%@/", token], *p;
    NSRange scheme;
    NSArray *parts;
    if (![dest length]) {
        *status = 400;
        return nil;
    }
    scheme = [dest rangeOfString:@"://"];
    if (scheme.location != NSNotFound) {
        NSRange slash = [dest rangeOfString:@"/" options:0 range:NSMakeRange(scheme.location + 3, [dest length] - scheme.location - 3)];
        dest = slash.location == NSNotFound ? @"/" : [dest substringFromIndex:slash.location];
    }
    p = [dest stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    if (![p hasPrefix:prefix]) {
        *status = 502;
        return nil;
    }
    parts = [[p substringFromIndex:[prefix length]] componentsSeparatedByString:@"/"];
    if ([parts count] == 0 || ![[parts objectAtIndex:0] isEqualToString:shareName]) {
        *status = 502;                    /* another share: not served */
        return nil;
    }
    p = cleanPath([[parts subarrayWithRange:NSMakeRange(1, [parts count] - 1)] componentsJoinedByString:@"/"]);
    if (!p) {
        *status = 403;
        return nil;
    }
    return p;
}

static BOOL handleMoveCopy(Conn *c, Request *r, TBDAVShare *s, BOOL move)
{
    int status = 0, rc;
    NSString *to = destinationPath(r, r->shareName, &status);
    BOOL overwrite = ![[[header(r, @"overwrite") uppercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] isEqualToString:@"F"];
    struct smb2_stat_64 st;
    BOOL existed;
    discardBody(c, r);
    if (!to || [to length] == 0 || [r->path length] == 0)
        return respond(c, status ? status : 403, nil, nil, NO);
    [s->lock lock];
    if (!connection(s)) {
        [s->lock unlock];
        return respond(c, 502, nil, nil, NO);
    }
    if (smb2_stat(s->context, [r->path UTF8String], &st) < 0) {
        [s->lock unlock];
        return respond(c, 404, nil, nil, NO);
    }
    existed = smb2_stat(s->context, [to UTF8String], &st) == 0;
    if (existed && !overwrite) {
        [s->lock unlock];
        return respond(c, 412, nil, nil, NO);
    }
    if (existed)
        removeTree(s->context, to);
    rc = move ? smb2_rename(s->context, [r->path UTF8String], [to UTF8String]) : copyTree(s->context, r->path, to);
    if (isConnectionLoss(rc))
        lostConnection(s);
    [s->lock unlock];
    if (rc < 0)
        return respond(c, errorStatus(rc) == 405 ? 412 : errorStatus(rc), nil, nil, NO);
    return respond(c, existed ? 204 : 201, nil, nil, NO);
}

static NSString *newLockToken(void)
{
    return [NSString stringWithFormat:@"opaquelocktoken:%08x-%04x-%04x-%04x-%08x%04x", arc4random(), arc4random() & 0xffff, arc4random() & 0xffff, arc4random() & 0xffff, arc4random(), arc4random() & 0xffff];
}

/* the list of shares at the top of the address (not used by the Finder's mount, which goes straight to a share) */
static BOOL handleTop(Conn *c, Request *r)
{
    NSMutableString *x = [NSMutableString stringWithString:@"<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:multistatus xmlns:D=\"DAV:\">\n"];
    NSArray *names;
    unsigned i;
    discardBody(c, r);
    @synchronized(serverLock) {
        names = [[shares allKeys] sortedArrayUsingSelector:@selector(compare:)];
    }
    entryXML(x, [NSString stringWithFormat:@"/%@/", token], @"Shares", YES, NULL, NULL);
    if (![[header(r, @"depth") description] isEqualToString:@"0"])
        for (i = 0; i < [names count]; i++)
            entryXML(x, [NSString stringWithFormat:@"/%@/%@/", token, [names objectAtIndex:i]], [names objectAtIndex:i], YES, NULL, NULL);
    [x appendString:@"</D:multistatus>\n"];
    return respondXML(c, 207, x, nil);
}

/* one request; NO to close the connection */
static BOOL handleRequest(Conn *c, Request *r)
{
    NSString *m = r->method;
    TBDAVShare *s;
    if ([m isEqualToString:@"OPTIONS"]) {
        discardBody(c, r);
        return respond(c, 200, @"Allow: OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, MOVE, COPY, PROPFIND, PROPPATCH, LOCK, UNLOCK\r\n", nil, NO);
    }
    if ([r->shareName length] == 0) {
        if ([m isEqualToString:@"PROPFIND"])
            return handleTop(c, r);
        discardBody(c, r);
        return respond(c, 405, nil, nil, NO);
    }
    @synchronized(serverLock) {
        s = [[[shares objectForKey:r->shareName] retain] autorelease];
    }
    if (!s) {
        discardBody(c, r);
        return respond(c, 404, nil, nil, NO);
    }
    if ([m isEqualToString:@"PROPFIND"])
        return handlePropfind(c, r, s);
    if ([m isEqualToString:@"GET"] || [m isEqualToString:@"HEAD"]) {
        discardBody(c, r);
        return handleGet(c, r, s, [m isEqualToString:@"HEAD"]);
    }
    if ([m isEqualToString:@"PUT"])
        return handlePut(c, r, s);
    if ([m isEqualToString:@"MKCOL"]) {
        int rc;
        discardBody(c, r);
        if ([r->path length] == 0)
            return respond(c, 405, nil, nil, NO);
        [s->lock lock];
        {
            struct smb2_stat_64 there;
            if (connection(s) && smb2_stat(s->context, [r->path UTF8String], &there) == 0) {
                [s->lock unlock];
                return respond(c, 405, nil, nil, NO);          /* it exists */
            }
        }
        rc = connection(s) ? smb2_mkdir(s->context, [r->path UTF8String]) : -ECONNRESET;
        if (isConnectionLoss(rc))
            lostConnection(s);
        [s->lock unlock];
        return respond(c, rc < 0 ? (rc == -ENOENT ? 409 : errorStatus(rc)) : 201, nil, nil, NO);
    }
    if ([m isEqualToString:@"DELETE"]) {
        int rc;
        discardBody(c, r);
        if ([r->path length] == 0)
            return respond(c, 403, nil, nil, NO);
        [s->lock lock];
        rc = connection(s) ? removeTree(s->context, r->path) : -ECONNRESET;
        if (isConnectionLoss(rc))
            lostConnection(s);
        [s->lock unlock];
        return respond(c, rc < 0 ? errorStatus(rc) : 204, nil, nil, NO);
    }
    if ([m isEqualToString:@"MOVE"])
        return handleMoveCopy(c, r, s, YES);
    if ([m isEqualToString:@"COPY"])
        return handleMoveCopy(c, r, s, NO);
    if ([m isEqualToString:@"LOCK"]) {
        NSString *t = newLockToken();
        discardBody(c, r);
        return respondXML(c, 200, [NSString stringWithFormat:@"<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:prop xmlns:D=\"DAV:\"><D:lockdiscovery><D:activelock><D:locktype><D:write/></D:locktype>"
            @"<D:lockscope><D:exclusive/></D:lockscope><D:depth>0</D:depth><D:owner/><D:timeout>Second-600</D:timeout><D:locktoken><D:href>%@</D:href></D:locktoken></D:activelock></D:lockdiscovery></D:prop>\n", t],
            [NSString stringWithFormat:@"Lock-Token: <%@>\r\n", t]);
    }
    if ([m isEqualToString:@"UNLOCK"]) {
        discardBody(c, r);
        return respond(c, 204, nil, nil, NO);
    }
    if ([m isEqualToString:@"PROPPATCH"]) {
        discardBody(c, r);
        return respondXML(c, 207, [NSString stringWithFormat:@"<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:multistatus xmlns:D=\"DAV:\"><D:response><D:href>%@</D:href><D:propstat><D:prop/>"
            @"<D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>\n", hrefEscape(r->rawPath)], nil);
    }
    discardBody(c, r);
    return respond(c, 405, nil, nil, NO);
}

/* the head of the next request: NO at the end of the connection */
static BOOL readRequest(Conn *c, Request *r)
{
    NSString *head, *line, *target;
    NSArray *lines, *first;
    NSMutableDictionary *h = [NSMutableDictionary dictionary];
    NSString *decoded;
    NSArray *parts;
    unsigned i;
    for (;;) {
        const char *b = [c->buffer bytes];
        NSUInteger n = [c->buffer length], k;
        BOOL found = NO;
        for (k = 0; k + 3 < n; k++)
            if (!memcmp(b + k, "\r\n\r\n", 4)) {
                found = YES;
                break;
            }
        if (found) {
            head = [[[NSString alloc] initWithBytes:b length:k encoding:NSUTF8StringEncoding] autorelease];
            if (!head)
                head = [[[NSString alloc] initWithBytes:b length:k encoding:NSISOLatin1StringEncoding] autorelease];
            [c->buffer replaceBytesInRange:NSMakeRange(0, k + 4) withBytes:NULL length:0];
            break;
        }
        if (n > 65536 || !fill(c))
            return NO;
    }
    lines = [head componentsSeparatedByString:@"\r\n"];
    line = [lines objectAtIndex:0];
    first = [line componentsSeparatedByString:@" "];
    if ([first count] < 2)
        return NO;
    r->method = [[first objectAtIndex:0] uppercaseString];
    target = [first objectAtIndex:1];
    if ([target rangeOfString:@"://"].location != NSNotFound) {
        NSRange scheme = [target rangeOfString:@"://"];
        NSRange slash = [target rangeOfString:@"/" options:0 range:NSMakeRange(scheme.location + 3, [target length] - scheme.location - 3)];
        target = slash.location == NSNotFound ? @"/" : [target substringFromIndex:slash.location];
    }
    {
        NSRange q = [target rangeOfString:@"?"];
        if (q.location != NSNotFound)
            target = [target substringToIndex:q.location];
    }
    for (i = 1; i < [lines count]; i++) {
        NSString *l = [lines objectAtIndex:i];
        NSRange colon = [l rangeOfString:@":"];
        if (colon.location == NSNotFound)
            continue;
        [h setObject:TBTrim([l substringFromIndex:colon.location + 1]) forKey:[[l substringToIndex:colon.location] lowercaseString]];
    }
    r->headers = h;
    r->rawPath = target;
    decoded = [target stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    if (!decoded)
        decoded = target;
    parts = [decoded componentsSeparatedByString:@"/"];
    /* "", token, share, ... */
    if ([parts count] < 2 || ![[parts objectAtIndex:1] isEqualToString:token]) {
        r->shareName = @"?";
        r->path = @"";
        return YES;                       /* answered 404 by handleRequest (no such share) */
    }
    r->shareName = [parts count] > 2 ? [parts objectAtIndex:2] : @"";
    r->path = cleanPath([parts count] > 3 ? [[parts subarrayWithRange:NSMakeRange(3, [parts count] - 3)] componentsJoinedByString:@"/"] : @"");
    if (!r->path)
        r->path = @"\x01";
    return YES;
}

@interface TBDAVServer : NSObject
+ (void)serveConnection:(NSNumber *)fd;
+ (void)acceptLoop:(NSNumber *)unused;
@end

@implementation TBDAVServer

+ (void)serveConnection:(NSNumber *)fdNumber
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    Conn conn;
    int one = 1;
    struct timeval wait;
    conn.fd = [fdNumber intValue];
    conn.buffer = [NSMutableData data];
    setsockopt(conn.fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    wait.tv_sec = 120;
    wait.tv_usec = 0;
    setsockopt(conn.fd, SOL_SOCKET, SO_RCVTIMEO, &wait, sizeof wait);
    for (;;) {
        NSAutoreleasePool *inner = [[NSAutoreleasePool alloc] init];
        Request r;
        BOOL keep;
        memset(&r, 0, sizeof r);
        if (!readRequest(&conn, &r)) {
            [inner release];
            break;
        }
        dlog([NSString stringWithFormat:@"%@ %@ depth=%@ dest=%@ auth=%@ len=%@ te=%@ expect=%@ if=%@", r.method, r.rawPath, [r.headers objectForKey:@"depth"], [r.headers objectForKey:@"destination"], [r.headers objectForKey:@"authorization"] ? @"yes" : @"no",
            [r.headers objectForKey:@"content-length"], [r.headers objectForKey:@"transfer-encoding"], [r.headers objectForKey:@"expect"], [r.headers objectForKey:@"if"]]);
        if ([r.path isEqualToString:@"\x01"]) {
            discardBody(&conn, &r);
            keep = respond(&conn, 403, nil, nil, NO);
        } else
            keep = handleRequest(&conn, &r);
        [inner release];
        if (!keep)
            break;
    }
    close(conn.fd);
    [pool release];
}

+ (void)acceptLoop:(NSNumber *)unused
{
    (void)unused;
    for (;;) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        struct sockaddr_in from;
        socklen_t len = sizeof from;
        int fd = accept(listener, (struct sockaddr *)&from, &len);
        if (fd < 0) {
            [pool release];
            if (errno == EINTR || errno == ECONNABORTED)
                continue;
            break;
        }
        if (from.sin_addr.s_addr != htonl(INADDR_LOOPBACK)) {
            close(fd);
            [pool release];
            continue;
        }
        [NSThread detachNewThreadSelector:@selector(serveConnection:) toTarget:self withObject:[NSNumber numberWithInt:fd]];
        [pool release];
    }
}

@end

/* the name in an address: letters, digits and . _ - only, so no client has to guess how many times to escape it */
static NSString *slugFor(NSString *name)
{
    NSMutableString *s = [NSMutableString string];
    unsigned i;
    for (i = 0; i < [name length]; i++) {
        unichar c = [name characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-')
            [s appendFormat:@"%C", c];
        else
            [s appendString:@"_"];
    }
    return [s length] ? s : @"share";
}

@implementation TBDAV

+ (void)initialize
{
    if (!serverLock) {
        serverLock = [[NSObject alloc] init];
        shares = [[NSMutableDictionary alloc] init];
    }
}

/* the server, on a free port of the loopback address, started once */
+ (NSString *)startServer
{
    struct sockaddr_in a;
    socklen_t len = sizeof a;
    int one = 1;
    if (listener >= 0)
        return nil;
    signal(SIGPIPE, SIG_IGN);
    listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0)
        return @"no socket";
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = 0;
    if (bind(listener, (struct sockaddr *)&a, sizeof a) != 0 || listen(listener, 16) != 0 || getsockname(listener, (struct sockaddr *)&a, &len) != 0) {
        close(listener);
        listener = -1;
        return @"could not listen on this Mac";
    }
    listenPort = ntohs(a.sin_port);
    token = [[NSString stringWithFormat:@"%08x%08x%08x%08x", arc4random(), arc4random(), arc4random(), arc4random()] retain];
    [NSThread detachNewThreadSelector:@selector(acceptLoop:) toTarget:[TBDAVServer class] withObject:nil];
    return nil;
}

+ (NSString *)addressForShare:(NSString *)name problem:(NSString **)problem
{
    NSDictionary *target = [TBSMB savedTargetNamed:name];
    TBDAVShare *s;
    NSString *why;
    if (!target) {
        if (problem)
            *problem = [NSString stringWithFormat:@"There is no saved share called \"%@\".", name];
        return nil;
    }
    @synchronized(serverLock) {
        why = [self startServer];
        if (why) {
            if (problem)
                *problem = why;
            return nil;
        }
        s = [shares objectForKey:slugFor(name)];
        if (!s) {
            s = [[[TBDAVShare alloc] init] autorelease];
            s->name = [name copy];
            s->lock = [[NSLock alloc] init];
            [shares setObject:s forKey:slugFor(name)];
        }
        [s->target release];
        s->target = [target retain];
    }
    return [NSString stringWithFormat:@"http://127.0.0.1:%d/%@/%@/", listenPort, token, slugFor(name)];
}

+ (NSString *)mountShareInFinder:(NSString *)name
{
    NSString *problem = nil, *url = [self addressForShare:name problem:&problem];
    NSTask *task;
    NSPipe *pipe = [NSPipe pipe];
    NSData *data;
    NSString *text;
    if (!url)
        return problem;
    /* prove the share can be reached now, so a wrong password is said plainly instead of a Finder error */
    {
        TBDAVShare *s;
        void *ctx;
        @synchronized(serverLock) {
            s = [[[shares objectForKey:slugFor(name)] retain] autorelease];
        }
        [s->lock lock];
        ctx = connection(s);
        [s->lock unlock];
        if (!ctx) {
            NSString *why = nil;
            void *again = [TBSMB connectTarget:s->target problem:&why];
            if (again)
                [TBSMB disconnect:again];
            return why ? why : @"Could not connect to the share.";
        }
    }
    task = [[[NSTask alloc] init] autorelease];
    [task setLaunchPath:@"/usr/bin/osascript"];
    /* a name and password in the address, which this server does not ask for: without them the system asks the person for a login to a server that wants none */
    [task setArguments:[NSArray arrayWithObjects:@"-e", [NSString stringWithFormat:@"mount volume \"%@\"", [@"http://tigerbuild:tigerbuild@" stringByAppendingString:[url substringFromIndex:7]]], nil]];
    [task setStandardOutput:pipe];
    [task setStandardError:pipe];
    [task setStandardInput:[NSFileHandle fileHandleWithNullDevice]];
    NS_DURING
        [task launch];
        data = [[pipe fileHandleForReading] readDataToEndOfFile];
        [task waitUntilExit];
    NS_HANDLER
        return @"Could not ask the Finder to mount it.";
    NS_ENDHANDLER
    if ([task terminationStatus] != 0) {
        text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
        return [NSString stringWithFormat:@"The Finder could not mount it. %@", TBTrim(text ? text : @"")];
    }
    return nil;
}

/* the places the Finder has mounted from this server */
+ (NSArray *)mountPointsForShare:(NSString *)name
{
    NSMutableArray *points = [NSMutableArray array];
    struct statfs *list = NULL;
    int n = getmntinfo(&list, MNT_NOWAIT), i;
    NSString *prefix = token ? [NSString stringWithFormat:@"http://127.0.0.1:%d/%@/", listenPort, token] : nil;
    if (!prefix)
        return points;
    for (i = 0; i < n; i++) {
        NSString *from = [NSString stringWithUTF8String:list[i].f_mntfromname];
        if ([from hasPrefix:@"http://tigerbuild:tigerbuild@"])      /* Tiger lists the name and password of the address too */
            from = [@"http://" stringByAppendingString:[from substringFromIndex:[@"http://tigerbuild:tigerbuild@" length]]];
        if ([from hasPrefix:prefix] && (!name || [from hasPrefix:[prefix stringByAppendingString:slugFor(name)]]))
            [points addObject:[NSString stringWithUTF8String:list[i].f_mntonname]];
    }
    return points;
}

+ (NSArray *)mountedNames
{
    NSMutableArray *names = [NSMutableArray array];
    NSArray *all;
    unsigned i;
    @synchronized(serverLock) {
        all = [shares allValues];
    }
    for (i = 0; i < [all count]; i++)
        if ([[self mountPointsForShare:((TBDAVShare *)[all objectAtIndex:i])->name] count])
            [names addObject:((TBDAVShare *)[all objectAtIndex:i])->name];
    return names;
}

/* still mounted? (by its mount point) */
static BOOL stillMounted(NSString *path)
{
    struct statfs *list = NULL;
    int n = getmntinfo(&list, MNT_NOWAIT), i;
    for (i = 0; i < n; i++)
        if ([[NSString stringWithUTF8String:list[i].f_mntonname] isEqualToString:path])
            return YES;
    return NO;
}

static void runTool(NSString *program, NSArray *arguments)
{
    NSTask *task = [[[NSTask alloc] init] autorelease];
    [task setLaunchPath:program];
    [task setArguments:arguments];
    [task setStandardOutput:[NSFileHandle fileHandleWithNullDevice]];
    [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];
    [task setStandardInput:[NSFileHandle fileHandleWithNullDevice]];
    NS_DURING
        [task launch];
        [task waitUntilExit];
    NS_HANDLER
    NS_ENDHANDLER
}

/* diskutil first (Tiger's has no "force"); umount when the disk is still there, which a disk of this account allows */
static BOOL eject(NSString *path, BOOL force)
{
    runTool(@"/usr/sbin/diskutil", [NSArray arrayWithObjects:@"unmount", path, nil]);
    if (!stillMounted(path))
        return YES;
    runTool(@"/sbin/umount", force ? [NSArray arrayWithObjects:@"-f", path, nil] : [NSArray arrayWithObject:path]);
    return !stillMounted(path);
}

+ (NSString *)unmountShare:(NSString *)name
{
    NSArray *points = [self mountPointsForShare:name];
    unsigned i;
    NSString *problem = nil;
    for (i = 0; i < [points count]; i++)
        if (!eject([points objectAtIndex:i], NO))
            problem = [NSString stringWithFormat:@"%@ is in use, so it was not ejected.", [[points objectAtIndex:i] lastPathComponent]];
    return problem;
}

+ (void)unmountAll
{
    NSArray *points = [self mountPointsForShare:nil];
    unsigned i;
    for (i = 0; i < [points count]; i++)
        eject([points objectAtIndex:i], YES);
}

@end
