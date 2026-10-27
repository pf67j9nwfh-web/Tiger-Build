/* The Finder mount's WebDAV server against tbsmbd: davtest PORT SHAREDIR   (tbsmbd serves SHAREDIR as "Share" to tbuser:s3cret-pass), from tiger-build/ */
#import <Foundation/Foundation.h>
#import "TBDAV.h"
#import "TBSupport.h"
#import "expect.h"

/* curl, to the status line and body */
static NSString *dav(NSString *method, NSString *url, NSArray *extra, NSString *body, int *status)
{
    NSTask *task = [[[NSTask alloc] init] autorelease];
    NSPipe *pipe = [NSPipe pipe];
    NSMutableArray *args = [NSMutableArray arrayWithObjects:@"-s", @"-i", @"-X", method, nil];
    NSData *data;
    NSString *text;
    NSRange r;
    if (extra)
        [args addObjectsFromArray:extra];
    if (body) {
        [args addObject:@"--data-binary"];
        [args addObject:body];
    }
    [args addObject:url];
    [task setLaunchPath:@"/usr/bin/curl"];
    [task setArguments:args];
    [task setStandardOutput:pipe];
    [task launch];
    data = [[pipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];
    text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    if (!text)
        text = @"";
    *status = [text hasPrefix:@"HTTP/1.1 "] ? [[text substringWithRange:NSMakeRange(9, 3)] intValue] : 0;
    r = [text rangeOfString:@"\r\n\r\n"];
    return r.location == NSNotFound ? text : [text substringFromIndex:r.location + 4];
}

int main(int argc, char **argv)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *port = [NSString stringWithUTF8String:argv[1]], *dir = [NSString stringWithUTF8String:argv[2]], *url, *problem = nil, *out, *bad;
    NSFileManager *fm = [NSFileManager defaultManager];
    int status;
    (void)argc;
    setenv("TB_SMB_SHARES", [[NSString stringWithFormat:@"Work files = smb://tbuser:s3cret-pass@127.0.0.1:%@/Share", port] UTF8String], 1);
    [@"hello from the share\n" writeToFile:[dir stringByAppendingPathComponent:@"hello.txt"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    [fm createDirectoryAtPath:[dir stringByAppendingPathComponent:@"docs"] attributes:nil];
    [@"in a folder" writeToFile:[dir stringByAppendingPathComponent:@"docs/a.txt"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    url = [TBDAV addressForShare:@"Work files" problem:&problem];
    expectThat(url && [url hasPrefix:@"http://127.0.0.1:"] && [url hasSuffix:@"/Work_files/"], @"dav: a saved share gets a loopback address with a secret and its name");
    expectThat([TBDAV addressForShare:@"nope" problem:&problem] == nil && [problem length], @"dav: an unknown share is refused");
    out = dav(@"OPTIONS", url, nil, nil, &status);
    expectThat(status == 200, @"dav: OPTIONS");
    out = dav(@"PROPFIND", url, [NSArray arrayWithObjects:@"-H", @"Depth: 1", nil], nil, &status);
    expectThat(status == 207 && [out rangeOfString:@"hello.txt"].length && [out rangeOfString:@"<D:collection/>"].length && [out rangeOfString:@"docs/"].length && [out rangeOfString:@"<D:getcontentlength>21</D:getcontentlength>"].length, @"dav: PROPFIND lists the files and folders with their sizes");
    out = dav(@"PROPFIND", [url stringByAppendingString:@"docs/"], [NSArray arrayWithObjects:@"-H", @"Depth: 1", nil], nil, &status);
    expectThat(status == 207 && [out rangeOfString:@"a.txt"].length, @"dav: PROPFIND inside a folder");
    out = dav(@"PROPFIND", [url stringByAppendingString:@"hello.txt"], [NSArray arrayWithObjects:@"-H", @"Depth: 0", nil], nil, &status);
    expectThat(status == 207 && [out rangeOfString:@"<D:resourcetype/>"].length, @"dav: PROPFIND on a file");
    out = dav(@"PROPFIND", [url stringByAppendingString:@"missing"], [NSArray arrayWithObjects:@"-H", @"Depth: 0", nil], nil, &status);
    expectThat(status == 404, @"dav: PROPFIND on a missing file is 404");
    out = dav(@"GET", [url stringByAppendingString:@"hello.txt"], nil, nil, &status);
    expectThat(status == 200 && [out isEqualToString:@"hello from the share\n"], @"dav: GET returns the file");
    out = dav(@"GET", [url stringByAppendingString:@"hello.txt"], [NSArray arrayWithObjects:@"-H", @"Range: bytes=6-9", nil], nil, &status);
    expectThat(status == 206 && [out isEqualToString:@"from"], @"dav: GET with a range");
    out = dav(@"PUT", [url stringByAppendingString:@"docs/new%20file.txt"], nil, @"written through WebDAV", &status);
    expectThat(status == 201 && [[NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"docs/new file.txt"] encoding:NSUTF8StringEncoding error:NULL] isEqualToString:@"written through WebDAV"], @"dav: PUT creates a file (spaces in the name)");
    out = dav(@"PUT", [url stringByAppendingString:@"docs/new%20file.txt"], nil, @"again", &status);
    expectThat(status == 204 && [[NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"docs/new file.txt"] encoding:NSUTF8StringEncoding error:NULL] isEqualToString:@"again"], @"dav: PUT over a file replaces it");
    /* a body of unknown length goes up as chunks (curl -T - does that), as an older Finder's may */
    {
        NSTask *task = [[[NSTask alloc] init] autorelease];
        NSPipe *pipe = [NSPipe pipe];
        NSString *shell = [NSString stringWithFormat:@"printf 'sent in chunks' | /usr/bin/curl -s -m 10 -o /dev/null -w '%%{http_code}' -T - '%@docs/chunked.txt'", url];
        NSData *data;
        [task setLaunchPath:@"/bin/sh"];
        [task setArguments:[NSArray arrayWithObjects:@"-c", shell, nil]];
        [task setStandardOutput:pipe];
        [task launch];
        data = [[pipe fileHandleForReading] readDataToEndOfFile];
        [task waitUntilExit];
        expectThat([[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] intValue] == 201 && [[NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"docs/chunked.txt"] encoding:NSUTF8StringEncoding error:NULL] isEqualToString:@"sent in chunks"], @"dav: PUT with a chunked body");
    }
    out = dav(@"MKCOL", [url stringByAppendingString:@"made"], nil, nil, &status);
    expectThat(status == 201 && [fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"made"]], @"dav: MKCOL");
    out = dav(@"MKCOL", [url stringByAppendingString:@"made"], nil, nil, &status);
    expectThat(status == 405, @"dav: MKCOL on an existing folder is 405");
    out = dav(@"MOVE", [url stringByAppendingString:@"docs/new%20file.txt"], [NSArray arrayWithObjects:@"-H", [NSString stringWithFormat:@"Destination: %@made/moved.txt", url], nil], nil, &status);
    expectThat((status == 201 || status == 204) && [fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"made/moved.txt"]] && ![fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"docs/new file.txt"]], @"dav: MOVE");
    out = dav(@"COPY", [url stringByAppendingString:@"hello.txt"], [NSArray arrayWithObjects:@"-H", [NSString stringWithFormat:@"Destination: %@made/copy.txt", url], nil], nil, &status);
    expectThat((status == 201 || status == 204) && [[NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"made/copy.txt"] encoding:NSUTF8StringEncoding error:NULL] isEqualToString:@"hello from the share\n"] && [fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"hello.txt"]], @"dav: COPY keeps the original");
    out = dav(@"COPY", [url stringByAppendingString:@"docs"], [NSArray arrayWithObjects:@"-H", [NSString stringWithFormat:@"Destination: %@made/docs2", url], nil], nil, &status);
    expectThat((status == 201 || status == 204) && [fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"made/docs2/a.txt"]], @"dav: COPY of a folder with its contents");
    out = dav(@"LOCK", [url stringByAppendingString:@"hello.txt"], nil, @"<lockinfo/>", &status);
    expectThat(status == 200 && [out rangeOfString:@"opaquelocktoken:"].length, @"dav: LOCK answers with a token (the Finder needs it to write)");
    out = dav(@"DELETE", [url stringByAppendingString:@"made"], nil, nil, &status);
    expectThat(status == 204 && ![fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"made"]], @"dav: DELETE of a folder takes what is in it");
    out = dav(@"DELETE", [url stringByAppendingString:@"missing"], nil, nil, &status);
    expectThat(status == 404, @"dav: DELETE of a missing file is 404");
    bad = [url stringByReplacingOccurrencesOfString:@"/Work_files/" withString:@"/Work_files/../../x"];
    out = dav(@"GET", [bad stringByReplacingOccurrencesOfString:@"/../../x" withString:@"/..%2f..%2fetc/passwd"], nil, nil, &status);
    expectThat(status != 200, @"dav: a path that climbs out of the share is refused");
    {
        NSRange slash = [url rangeOfString:@"/" options:NSBackwardsSearch range:NSMakeRange(0, [url length] - 1)];
        NSString *noToken = [[url substringToIndex:NSMaxRange([url rangeOfString:@"127.0.0.1:"]) + 5] stringByAppendingString:@"/wrongtoken/Work_files/hello.txt"];
        (void)slash;
        out = dav(@"GET", noToken, nil, nil, &status);
        expectThat(status == 404, @"dav: an address without the secret gets nothing");
    }
    [pool release];
    return failures ? 1 : 0;
}
