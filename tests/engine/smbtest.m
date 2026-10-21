/* The SMB tools against tbsmbd: smbtest PORT SHAREDIR   (tbsmbd serves SHAREDIR as "Share" to tbuser:s3cret-pass) from tiger-build/ */
#import <Foundation/Foundation.h>
#import "TBSMB.h"
#import "TBJSON.h"
#import "TBSupport.h"
#import "expect.h"

static NSString *attempt(NSString *tool, NSDictionary *args, BOOL local, NSString **error)
{
    @try {
        *error = nil;
        return [TBSMB call:tool arguments:args allowLocal:local];
    } @catch (NSException *e) {
        *error = [e reason];
        return nil;
    }
}

int main(int argc, char **argv)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *port = [NSString stringWithUTF8String:argv[1]], *dir = [NSString stringWithUTF8String:argv[2]], *base, *out, *err;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *p;
    (void)argc;
    base = [NSString stringWithFormat:@"smb://tbuser:s3cret-pass@127.0.0.1:%@/Share", port];

    p = [TBSMB parseURL:@"smb://WORK;al%40ice:p%3Ass@nas.local:4455/Docs/a/b.txt"];
    expectThat([[p objectForKey:@"domain"] isEqualToString:@"WORK"] && [[p objectForKey:@"user"] isEqualToString:@"al@ice"] && [[p objectForKey:@"password"] isEqualToString:@"p:ss"]
        && [[p objectForKey:@"server"] isEqualToString:@"nas.local:4455"] && [[p objectForKey:@"share"] isEqualToString:@"Docs"] && [[p objectForKey:@"path"] isEqualToString:@"a/b.txt"], @"smb url: domain, escaped user and password, port, share and path");
    expectThat([TBSMB parseURL:@"http://x/y"] == nil && [TBSMB parseURL:@"smb://nohost"] == nil, @"smb url: other schemes and no share are refused");

    [@"hello from the share\n" writeToFile:[dir stringByAppendingPathComponent:@"hello.txt"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    [fm createDirectoryAtPath:[dir stringByAppendingPathComponent:@"sub"] attributes:nil];
    out = attempt(@"smb_list", [NSDictionary dictionaryWithObject:base forKey:@"url"], NO, &err);
    expectThat(out && [out rangeOfString:@"hello.txt"].length && [out rangeOfString:@"sub"].length, @"list: the files and folders of the share");
    out = attempt(@"smb_get", [NSDictionary dictionaryWithObjectsAndKeys:base, @"url", @"hello.txt", @"path", nil], NO, &err);
    expectThat([out isEqualToString:@"hello from the share\n"], @"get: a text file comes back as text");
    out = attempt(@"smb_put", [NSDictionary dictionaryWithObjectsAndKeys:base, @"url", @"sub/new.txt", @"path", @"written over SMB", @"text", nil], NO, &err);
    expectThat(out && [[NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"sub/new.txt"] encoding:NSUTF8StringEncoding error:NULL] isEqualToString:@"written over SMB"], @"put: text is written to the share");
    out = attempt(@"smb_put", [NSDictionary dictionaryWithObjectsAndKeys:base, @"url", @"sub/new.txt", @"path", @"again", @"text", nil], NO, &err);
    expectThat(!out && [err rangeOfString:@"overwrite"].length, @"put: an existing file is kept unless overwrite is true");
    out = attempt(@"smb_put", [NSDictionary dictionaryWithObjectsAndKeys:base, @"url", @"sub/new.txt", @"path", @"again", @"text", [NSNumber numberWithBool:YES], @"overwrite", nil], NO, &err);
    expectThat(out && [[NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"sub/new.txt"] encoding:NSUTF8StringEncoding error:NULL] isEqualToString:@"again"], @"put: overwrite replaces it");
    out = attempt(@"smb_mkdir", [NSDictionary dictionaryWithObjectsAndKeys:base, @"url", @"made", @"path", nil], NO, &err);
    expectThat(out && [fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"made"]], @"mkdir");
    out = attempt(@"smb_rename", [NSDictionary dictionaryWithObjectsAndKeys:base, @"url", @"sub/new.txt", @"path", @"made/moved.txt", @"new_path", nil], NO, &err);
    expectThat(out && [fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"made/moved.txt"]] && ![fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"sub/new.txt"]], @"rename: moved inside the share");
    out = attempt(@"smb_delete", [NSDictionary dictionaryWithObjectsAndKeys:base, @"url", @"made/moved.txt", @"path", nil], NO, &err);
    expectThat(out && ![fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"made/moved.txt"]], @"delete: a file");
    out = attempt(@"smb_delete", [NSDictionary dictionaryWithObjectsAndKeys:base, @"url", @"made", @"path", nil], NO, &err);
    expectThat(out && ![fm fileExistsAtPath:[dir stringByAppendingPathComponent:@"made"]], @"delete: an empty folder");
    out = attempt(@"smb_get", [NSDictionary dictionaryWithObjectsAndKeys:base, @"url", @"missing.txt", @"path", nil], NO, &err);
    expectThat(!out && [err length], @"get: a missing file is an error the model sees");
    out = attempt(@"smb_get", [NSDictionary dictionaryWithObjectsAndKeys:base, @"url", @"../../etc/passwd", @"path", nil], NO, &err);
    expectThat(!out, @"a path that climbs out of the share is refused");
    expectThat(!attempt(@"smb_list", [NSDictionary dictionaryWithObject:@"smb://tbuser:wrong@127.0.0.1:%@/Share" forKey:@"url"], NO, &err) && [err length], @"a wrong password is refused");
    out = attempt(@"smb_list", [NSDictionary dictionaryWithObject:[NSString stringWithFormat:@"smb://tbuser:wrong@127.0.0.1:%@/Share", port] forKey:@"url"], NO, &err);
    expectThat(!out && [err rangeOfString:@"Could not connect"].length, @"a wrong password: could not connect");
    out = attempt(@"smb_get", [NSDictionary dictionaryWithObjectsAndKeys:base, @"url", @"hello.txt", @"path", @"/tmp/x.txt", @"output_path", nil], NO, &err);
    expectThat(!out && [err rangeOfString:@"Commander"].length, @"output_path needs Commander");
    {
        NSString *big = [NSTemporaryDirectory() stringByAppendingPathComponent:@"smb-big.bin"], *back = [NSTemporaryDirectory() stringByAppendingPathComponent:@"smb-back.bin"];
        NSMutableData *data = [NSMutableData dataWithLength:5 * 1024 * 1024 + 123];
        unsigned char *b = [data mutableBytes];
        unsigned i;
        for (i = 0; i < [data length]; i++)
            b[i] = (unsigned char)(i * 31 + (i >> 8));
        [data writeToFile:big atomically:NO];
        [fm removeItemAtPath:back error:NULL];
        out = attempt(@"smb_put", [NSDictionary dictionaryWithObjectsAndKeys:base, @"url", @"big.bin", @"path", big, @"local_path", nil], YES, &err);
        expectThat(out != nil, @"put: a 5 MB file from local_path");
        out = attempt(@"smb_get", [NSDictionary dictionaryWithObjectsAndKeys:base, @"url", @"big.bin", @"path", back, @"output_path", nil], YES, &err);
        expectThat(out != nil && [[NSData dataWithContentsOfFile:back] isEqualToData:data], @"get: the same 5 MB come back through output_path");
        [fm removeItemAtPath:big error:NULL];
        [fm removeItemAtPath:back error:NULL];
    }
    [pool release];
    return failures ? 1 : 0;
}
