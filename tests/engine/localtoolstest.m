/* The web page reader, the knowledge folder and its path checks: localtoolstest (from tiger-build/; reads a page only when TB_TEST_PAGE is set) */
#import <Foundation/Foundation.h>
#import "TBLocalTools.h"
#import "TBEngine.h"

static int failures = 0;
static void expectThat(BOOL ok, NSString *name)
{
    fprintf(stderr, "%s %s\n", ok ? "PASS" : "FAIL", [name UTF8String]);
    if (!ok)
        failures++;
}


int main(int argc, char **argv)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:@"tb-knowledge-test"];
    NSFileManager *m = [NSFileManager defaultManager];
    NSString *text, *reason;
    [m removeFileAtPath:root handler:nil];
    [m createDirectoryAtPath:root attributes:nil];
    [m createDirectoryAtPath:[root stringByAppendingPathComponent:@"sub"] attributes:nil];
    [@"The lighthouse at Point Reyes was built in 1870 and uses a Fresnel lens.\nKeepers lived in cottages nearby.\n" writeToFile:[root stringByAppendingPathComponent:@"lighthouse.txt"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    [@"# Recipes\nSourdough bread needs flour, water, salt and a starter.\n" writeToFile:[root stringByAppendingPathComponent:@"sub/bread.md"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    [@"Tax notes: file by April.\n" writeToFile:[root stringByAppendingPathComponent:@".hidden.txt"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    symlink("/etc/hosts", [[root stringByAppendingPathComponent:@"linked.txt"] fileSystemRepresentation]);

    text = [TBLocalTools knowledgeSearch:@"fresnel lens lighthouse" root:root];
    expectThat([text hasPrefix:@"[1] lighthouse.txt"], @"knowledge: the best passage comes first, with its file");
    text = [TBLocalTools knowledgeSearch:@"sourdough starter" root:root];
    expectThat([text rangeOfString:@"sub/bread.md"].location != NSNotFound, @"knowledge: files in folders are found");
    text = [TBLocalTools knowledgeSearch:@"april taxes" root:root];
    expectThat([text rangeOfString:@"Nothing in the knowledge folder matches"].location != NSNotFound, @"knowledge: hidden files are not indexed");
    expectThat([[TBLocalTools knowledgeOpen:@"sub/bread.md" root:root] hasPrefix:@"# Recipes"], @"knowledge: a whole file opens");
    reason = nil;
    @try { [TBLocalTools knowledgeOpen:@"../../etc/hosts" root:root]; } @catch (NSException *e) { reason = [e reason]; }
    expectThat(reason != nil, @"knowledge: a path with .. is refused");
    reason = nil;
    @try { [TBLocalTools knowledgeOpen:@"/etc/hosts" root:root]; } @catch (NSException *e) { reason = [e reason]; }
    expectThat(reason != nil, @"knowledge: an absolute path is refused");
    reason = nil;
    @try { [TBLocalTools knowledgeOpen:@"linked.txt" root:root]; } @catch (NSException *e) { reason = [e reason]; }
    expectThat(reason != nil, @"knowledge: a link that points outside is refused");
    reason = nil;
    @try { [TBLocalTools knowledgeSearch:@"anything" root:@"/nonexistent/folder"]; } @catch (NSException *e) { reason = [e reason]; }
    expectThat(reason != nil, @"knowledge: a missing folder is reported");

    text = [TBLocalTools htmlToText:@"<html><head><title>T</title><style>p{color:red}</style><script>var x=1;</script></head><body><h1>Head &amp; shoulders</h1><!-- hidden --><p>One</p><p>Two&nbsp;words &#233;</p></body></html>"];
    expectThat([text rangeOfString:@"Head & shoulders"].location != NSNotFound && [text rangeOfString:@"var x"].location == NSNotFound && [text rangeOfString:@"color:red"].location == NSNotFound && [text rangeOfString:@"hidden"].location == NSNotFound, @"html to text: scripts, styles and comments gone, entities decoded");
    expectThat([text rangeOfString:@"One\nTwo"].location != NSNotFound || [text rangeOfString:@"One\n\nTwo"].location != NSNotFound, @"html to text: paragraphs are on their own lines");
    reason = nil;
    @try { [TBLocalTools readPage:@"http://127.0.0.1:1/" run:nil]; } @catch (NSException *e) { reason = [e reason]; }
    expectThat([reason rangeOfString:@"public"].location != NSNotFound, @"read page: a private address is refused");
    reason = nil;
    @try { [TBLocalTools readPage:@"file:///etc/hosts" run:nil]; } @catch (NSException *e) { reason = [e reason]; }
    expectThat(reason != nil, @"read page: only http and https");
    [m removeFileAtPath:root handler:nil];
    fprintf(stderr, failures ? "%d FAILED\n" : "all passed\n", failures);
    [pool release];
    return failures ? 1 : 0;
}
