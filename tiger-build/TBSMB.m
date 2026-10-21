#import "TBSMB.h"
#import "TBEngine.h"
#import "TBSupport.h"
#import "TBJSON.h"
#import "mbedtls/sha256.h"
#include <fcntl.h>
#include "smb2.h"
#include "libsmb2.h"
#include "libsmb2-raw.h"

#define MAX_TEXT_DEFAULT 20000
#define MAX_TRANSFER (200u * 1024 * 1024)

static NSString *unescape(NSString *s)
{
    NSString *out = [s stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    return out ? out : s;
}

@implementation TBSMB

+ (NSString *)savedSharesText
{
    NSString *text = [TBSettings valueForName:@"smb_shares"];
    return text ? text : @"";
}

+ (void)setSavedSharesText:(NSString *)text
{
    if ([TBTrim(text) length])
        [TBSettings setValue:text forName:@"smb_shares"];
    else
        [TBSettings clearName:@"smb_shares"];
}

/* smb://[domain;]user[:password]@host[:port]/share[/path] -> domain, user, password, server (host or host:port), share, path */
+ (NSDictionary *)parseURL:(NSString *)url
{
    NSString *rest, *authority, *path = @"", *host, *creds = nil;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSRange r;
    url = TBTrim(url);
    if (![[url lowercaseString] hasPrefix:@"smb://"])
        return nil;
    rest = [url substringFromIndex:6];
    r = [rest rangeOfString:@"/"];
    if (r.location == NSNotFound)
        return nil;
    authority = [rest substringToIndex:r.location];
    path = [rest substringFromIndex:r.location + 1];
    r = [authority rangeOfString:@"@" options:NSBackwardsSearch];
    if (r.location != NSNotFound) {
        creds = [authority substringToIndex:r.location];
        host = [authority substringFromIndex:r.location + 1];
    } else
        host = authority;
    if ([host length] == 0)
        return nil;
    [out setObject:host forKey:@"server"];
    if (creds) {
        NSString *user = creds, *password = @"";
        r = [creds rangeOfString:@":"];
        if (r.location != NSNotFound) {
            user = [creds substringToIndex:r.location];
            password = [creds substringFromIndex:r.location + 1];
        }
        r = [user rangeOfString:@";"];
        if (r.location != NSNotFound) {
            [out setObject:unescape([user substringToIndex:r.location]) forKey:@"domain"];
            user = [user substringFromIndex:r.location + 1];
        }
        [out setObject:unescape(user) forKey:@"user"];
        [out setObject:unescape(password) forKey:@"password"];
    }
    r = [path rangeOfString:@"/"];
    if (r.location == NSNotFound) {
        [out setObject:unescape(path) forKey:@"share"];
        [out setObject:@"" forKey:@"path"];
    } else {
        [out setObject:unescape([path substringToIndex:r.location]) forKey:@"share"];
        [out setObject:unescape([path substringFromIndex:r.location + 1]) forKey:@"path"];
    }
    return out;
}

/* a saved share by name */
+ (NSString *)savedURLNamed:(NSString *)name
{
    NSArray *lines = [[self savedSharesText] componentsSeparatedByString:@"\n"];
    unsigned i;
    for (i = 0; i < [lines count]; i++) {
        NSString *line = TBTrim([lines objectAtIndex:i]);
        NSRange eq;
        if ([line hasPrefix:@"#"] || [line length] == 0)
            continue;
        eq = [line rangeOfString:@"="];
        if (eq.location == NSNotFound)
            continue;
        if ([[TBTrim([line substringToIndex:eq.location]) lowercaseString] isEqualToString:[[TBTrim(name) lowercaseString] copy]])
            return TBTrim([line substringFromIndex:eq.location + 1]);
    }
    return nil;
}

static NSString *joinPath(NSString *base, NSString *extra)
{
    NSString *a = base ? base : @"", *b = extra ? extra : @"";
    NSMutableString *p;
    if ([a length] && [b length])
        p = [NSMutableString stringWithFormat:@"%@/%@", a, b];
    else
        p = [NSMutableString stringWithString:[a length] ? a : b];
    while ([p hasPrefix:@"/"])
        [p deleteCharactersInRange:NSMakeRange(0, 1)];
    return p;
}

/* where the model points: url, or connection (a saved name) with an optional path */
+ (NSDictionary *)targetFrom:(NSDictionary *)args
{
    NSString *connection = TBString(args, @"connection"), *url = TBString(args, @"url"), *extra = TBString(args, @"path");
    NSMutableDictionary *t;
    if ([connection length]) {
        url = [self savedURLNamed:connection];
        if (!url)
            TBFail(@"No saved share is named \"%@\". Saved shares are set up in Preferences, Sharing.", connection);
    }
    t = [NSMutableDictionary dictionaryWithDictionary:[self parseURL:url]];
    if (![t objectForKey:@"server"])
        TBFail(@"Give the share as url=smb://user@server/share/path, or the name of a share saved in Preferences, Sharing, as connection.");
    if ([TBString(args, @"user") length])
        [t setObject:TBString(args, @"user") forKey:@"user"];
    if ([TBString(args, @"password") length])
        [t setObject:TBString(args, @"password") forKey:@"password"];
    if ([TBString(args, @"domain") length])
        [t setObject:TBString(args, @"domain") forKey:@"domain"];
    [t setObject:joinPath([t objectForKey:@"path"], extra) forKey:@"path"];
    return t;
}

static struct smb2_context *connectTo(NSDictionary *t, NSString *shareOverride)
{
    struct smb2_context *smb2 = smb2_init_context();
    NSString *user = [t objectForKey:@"user"], *share = shareOverride ? shareOverride : [t objectForKey:@"share"];
    int rc;
    if (!smb2)
        TBFail(@"Out of memory.");
    smb2_set_timeout(smb2, 30);
    smb2_set_security_mode(smb2, SMB2_NEGOTIATE_SIGNING_ENABLED);
    if ([user length]) {
        smb2_set_user(smb2, [user UTF8String]);
        smb2_set_password(smb2, [[t objectForKey:@"password"] UTF8String] ? [[t objectForKey:@"password"] UTF8String] : "");
        if ([[t objectForKey:@"domain"] length])
            smb2_set_domain(smb2, [[t objectForKey:@"domain"] UTF8String]);
    } else {
        smb2_set_user(smb2, "Guest");
        smb2_set_password(smb2, "");
    }
    rc = smb2_connect_share(smb2, [[t objectForKey:@"server"] UTF8String], [share UTF8String], [user length] ? [user UTF8String] : "Guest");
    if (rc < 0) {
        NSString *why = [NSString stringWithUTF8String:smb2_get_error(smb2) ? smb2_get_error(smb2) : "could not connect"];
        smb2_destroy_context(smb2);
        TBFail(@"Could not connect to %@/%@: %@", [t objectForKey:@"server"], share, why);
    }
    return smb2;
}

static NSString *dateText(uint64_t secs)
{
    NSDate *d = [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)secs];
    return [d descriptionWithCalendarFormat:@"%Y-%m-%d %H:%M" timeZone:nil locale:nil];
}

static NSString *sizeText(uint64_t n)
{
    if (n < 1024) return [NSString stringWithFormat:@"%llu B", (unsigned long long)n];
    if (n < 1024 * 1024) return [NSString stringWithFormat:@"%.1f KB", n / 1024.0];
    if (n < 1024ULL * 1024 * 1024) return [NSString stringWithFormat:@"%.1f MB", n / 1048576.0];
    return [NSString stringWithFormat:@"%.2f GB", n / 1073741824.0];
}

static NSString *fileName(NSString *path)
{
    NSRange r = [path rangeOfString:@"/" options:NSBackwardsSearch];
    return r.location == NSNotFound ? path : [path substringFromIndex:r.location + 1];
}

static BOOL looksText(NSData *data)
{
    const unsigned char *b = [data bytes];
    NSUInteger i, n = [data length] < 4096 ? [data length] : 4096;
    for (i = 0; i < n; i++)
        if (b[i] == 0)
            return NO;
    return YES;
}

static NSString *sha256Hex(NSData *data)
{
    unsigned char digest[32];
    NSMutableString *hex = [NSMutableString string];
    unsigned i;
    mbedtls_sha256([data bytes], [data length], digest, 0);
    for (i = 0; i < sizeof digest; i++)
        [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

+ (NSString *)call:(NSString *)tool arguments:(NSDictionary *)args allowLocal:(BOOL)local
{
    NSDictionary *t = [self targetFrom:args];
    NSString *path = [t objectForKey:@"path"], *share = [t objectForKey:@"share"];
    struct smb2_context *smb2 = NULL;
    NSMutableString *out = [NSMutableString string];
    @try {
        if ([tool isEqualToString:@"smb_list"]) {
            struct smb2dir *dir;
            struct smb2dirent *ent;
            unsigned count = 0;
            if ([share length] == 0 || [share isEqualToString:@"IPC$"])
                TBFail(@"Name the share: smb://server/share.");
            smb2 = connectTo(t, nil);
            dir = smb2_opendir(smb2, [path UTF8String]);
            if (!dir)
                TBFail(@"Could not list %@/%@: %s", share, path, smb2_get_error(smb2));
            while ((ent = smb2_readdir(smb2, dir))) {
                const char *n = ent->name;
                if (!strcmp(n, ".") || !strcmp(n, ".."))
                    continue;
                [out appendFormat:@"%@ %@  %@  %s\n", ent->st.smb2_type == SMB2_TYPE_DIRECTORY ? @"d" : @"-",
                    ent->st.smb2_type == SMB2_TYPE_DIRECTORY ? @"" : sizeText(ent->st.smb2_size), dateText(ent->st.smb2_mtime), n];
                if (++count >= 1000) {
                    [out appendString:@"... (the first 1000 entries)\n"];
                    break;
                }
            }
            smb2_closedir(smb2, dir);
            if (count == 0)
                [out appendString:@"(empty)\n"];
        } else if ([tool isEqualToString:@"smb_get"]) {
            struct smb2fh *fh;
            struct smb2_stat_64 st;
            NSMutableData *data;
            uint32_t chunk;
            NSString *to = TBString(args, @"output_path");
            double limit = [TBValue(args, @"max_chars") respondsToSelector:@selector(doubleValue)] ? [TBValue(args, @"max_chars") doubleValue] : MAX_TEXT_DEFAULT;
            if (![path length])
                TBFail(@"Give the file's path, for example path=Documents/report.txt.");
            if ([to length] && !local)
                TBFail(@"output_path is only available when Commander is on for this chat.");
            smb2 = connectTo(t, nil);
            if (smb2_stat(smb2, [path UTF8String], &st) < 0)
                TBFail(@"%@ was not found on %@: %s", path, share, smb2_get_error(smb2));
            if (st.smb2_type == SMB2_TYPE_DIRECTORY)
                TBFail(@"%@ is a folder; use smb_list.", path);
            if (st.smb2_size > MAX_TRANSFER)
                TBFail(@"%@ is %@, more than the %u MB limit.", path, sizeText(st.smb2_size), (unsigned)(MAX_TRANSFER / 1048576));
            fh = smb2_open(smb2, [path UTF8String], O_RDONLY);
            if (!fh)
                TBFail(@"Could not open %@: %s", path, smb2_get_error(smb2));
            chunk = smb2_get_max_read_size(smb2);
            if (chunk > 1048576 || chunk == 0)
                chunk = 1048576;
            data = [NSMutableData dataWithCapacity:(NSUInteger)st.smb2_size];
            {
                uint8_t *buf = malloc(chunk);
                uint64_t offset = 0;
                int n;
                if (!buf) {
                    smb2_close(smb2, fh);
                    TBFail(@"Out of memory.");
                }
                while ((n = smb2_pread(smb2, fh, buf, chunk, offset)) > 0) {
                    [data appendBytes:buf length:(NSUInteger)n];
                    offset += (uint64_t)n;
                }
                free(buf);
                if (n < 0) {
                    smb2_close(smb2, fh);
                    TBFail(@"Reading %@ failed: %s", path, smb2_get_error(smb2));
                }
            }
            smb2_close(smb2, fh);
            if ([to length]) {
                NSString *full = [to stringByExpandingTildeInPath];
                if (![full isAbsolutePath])
                    TBFail(@"output_path must be a full path.");
                if ([[NSFileManager defaultManager] fileExistsAtPath:full] && ![TBValue(args, @"overwrite") boolValue])
                    TBFail(@"%@ exists; give overwrite=true to replace it.", full);
                if (![data writeToFile:full atomically:YES])
                    TBFail(@"Could not write %@.", full);
                [out appendFormat:@"Saved %@ (%lu bytes) to %@. SHA-256 %@.\n", path, (unsigned long)[data length], full, sha256Hex(data)];
            } else if (looksText(data)) {
                NSString *text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
                if (!text)
                    text = [[[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] autorelease];
                if (limit < 100)
                    limit = MAX_TEXT_DEFAULT;
                if ([text length] > (NSUInteger)limit) {
                    [out appendString:[text substringToIndex:(NSUInteger)limit]];
                    [out appendFormat:@"\n... (%lu of %lu characters; raise max_chars to read more)\n", (unsigned long)limit, (unsigned long)[text length]];
                } else
                    [out appendString:text];
            } else
                [out appendFormat:@"%@ is a binary file (%@, SHA-256 %@). Use output_path to save it on this Mac (needs Commander).\n", path, sizeText([data length]), sha256Hex(data)];
        } else if ([tool isEqualToString:@"smb_put"]) {
            NSData *data = nil;
            NSString *from = TBString(args, @"local_path"), *text = TBString(args, @"text");
            struct smb2fh *fh;
            uint64_t offset = 0;
            uint32_t chunk;
            if (![path length])
                TBFail(@"Give the file's path on the share, for example path=Documents/report.txt.");
            if ([from length]) {
                if (!local)
                    TBFail(@"local_path is only available when Commander is on for this chat.");
                data = [NSData dataWithContentsOfFile:[from stringByExpandingTildeInPath]];
                if (!data)
                    TBFail(@"Could not read %@.", from);
            } else if (TBValue(args, @"text"))
                data = [text dataUsingEncoding:NSUTF8StringEncoding];
            else
                TBFail(@"Give text, or local_path (with Commander on).");
            if ([data length] > MAX_TRANSFER)
                TBFail(@"That is more than the %u MB limit.", (unsigned)(MAX_TRANSFER / 1048576));
            smb2 = connectTo(t, nil);
            {
                struct smb2_stat_64 st;
                if (smb2_stat(smb2, [path UTF8String], &st) == 0 && ![TBValue(args, @"overwrite") boolValue])
                    TBFail(@"%@ exists on %@; give overwrite=true to replace it.", path, share);
            }
            fh = smb2_open(smb2, [path UTF8String], O_WRONLY | O_CREAT | O_TRUNC);
            if (!fh)
                TBFail(@"Could not create %@: %s", path, smb2_get_error(smb2));
            chunk = smb2_get_max_write_size(smb2);
            if (chunk > 1048576 || chunk == 0)
                chunk = 1048576;
            while (offset < [data length]) {
                uint32_t n = (uint32_t)MIN((uint64_t)chunk, (uint64_t)[data length] - offset);
                int put = smb2_pwrite(smb2, fh, (const uint8_t *)[data bytes] + offset, n, offset);
                if (put <= 0) {
                    NSString *why = [NSString stringWithUTF8String:smb2_get_error(smb2)];
                    smb2_close(smb2, fh);
                    TBFail(@"Writing %@ failed: %@", path, why);
                }
                offset += (uint64_t)put;
            }
            smb2_close(smb2, fh);
            [out appendFormat:@"Wrote %lu bytes to %@/%@.\n", (unsigned long)[data length], share, path];
        } else if ([tool isEqualToString:@"smb_mkdir"]) {
            if (![path length])
                TBFail(@"Give the folder's path.");
            smb2 = connectTo(t, nil);
            if (smb2_mkdir(smb2, [path UTF8String]) < 0)
                TBFail(@"Could not create %@: %s", path, smb2_get_error(smb2));
            [out appendFormat:@"Created the folder %@/%@.\n", share, path];
        } else if ([tool isEqualToString:@"smb_delete"]) {
            struct smb2_stat_64 st;
            if (![path length])
                TBFail(@"Give the path of the file or empty folder to delete.");
            smb2 = connectTo(t, nil);
            if (smb2_stat(smb2, [path UTF8String], &st) < 0)
                TBFail(@"%@ was not found on %@: %s", path, share, smb2_get_error(smb2));
            if ((st.smb2_type == SMB2_TYPE_DIRECTORY ? smb2_rmdir(smb2, [path UTF8String]) : smb2_unlink(smb2, [path UTF8String])) < 0)
                TBFail(@"Could not delete %@: %s", path, smb2_get_error(smb2));
            [out appendFormat:@"Deleted %@/%@.\n", share, path];
        } else if ([tool isEqualToString:@"smb_rename"]) {
            NSString *to = joinPath(@"", TBString(args, @"new_path"));
            if (![path length] || ![to length])
                TBFail(@"Give path and new_path.");
            smb2 = connectTo(t, nil);
            if (smb2_rename(smb2, [path UTF8String], [to UTF8String]) < 0)
                TBFail(@"Could not rename %@: %s", path, smb2_get_error(smb2));
            [out appendFormat:@"Renamed %@ to %@ on %@.\n", path, to, share];
        } else
            TBFail(@"Unknown tool %@.", tool);
    } @finally {
        if (smb2) {
            smb2_disconnect_share(smb2);
            smb2_destroy_context(smb2);
        }
    }
    (void)fileName;
    return out;
}

@end
