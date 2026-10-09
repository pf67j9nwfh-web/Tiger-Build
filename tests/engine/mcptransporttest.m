/* The older HTTP+SSE transport and OAuth sign-in, against mockservices: mcptransporttest PORT   (from tiger-build/, with TB_OAUTH_TEST=1 set) */
#import <Foundation/Foundation.h>
#import "TBMCP.h"
#import "TBOAuth.h"
#import "TBHTTP.h"
#import "TBEngine.h"

static int failures = 0;
static void expectThat(BOOL ok, NSString *name)
{
    fprintf(stderr, "%s %s\n", ok ? "PASS" : "FAIL", [name UTF8String]);
    if (!ok)
        failures++;
}

static NSString *toolText(TBMCPHTTPClient *c, NSString *word)
{
    id called = [c request:@"tools/call" params:[NSDictionary dictionaryWithObjectsAndKeys:@"echo", @"name", [NSDictionary dictionaryWithObject:word forKey:@"text"], @"arguments", nil] timeout:10];
    return TBMCPResultText(called);
}

/* the browser: visits the sign-in address from the file, which redirects to the loopback port Tiger Build listens on */
@interface Browser : NSObject
- (void)visit:(id)unused;
@end
@implementation Browser
- (void)visit:(id)unused
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    int i;
    for (i = 0; i < 100; i++) {
        NSString *url = [NSString stringWithContentsOfFile:@"/tmp/tb-oauth-url.txt" encoding:NSUTF8StringEncoding error:NULL];
        if ([url length]) {
            TBHTTP *first = [TBHTTP request:@"GET" url:url];
            [first perform];
            if ([[first responseHeader:@"Location"] length]) {
                TBHTTP *back = [TBHTTP request:@"GET" url:[first responseHeader:@"Location"]];
                [back perform];
            }
            break;
        }
        usleep(100000);
    }
    [pool release];
}
@end

int main(int argc, char **argv)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *base = [NSString stringWithFormat:@"http://127.0.0.1:%s", argv[1]];
    setenv("TB_OAUTH_TEST", "1", 1);
    setenv("TB_OAUTH_URLFILE", "/tmp/tb-oauth-url.txt", 1);
    unlink("/tmp/tb-oauth-url.txt");
    {
        TBMCPHTTPClient *c = [TBMCPHTTPClient clientWithURL:[base stringByAppendingString:@"/legacy/sse"] token:@"tok"];
        id listed;
        [c start];
        listed = [c request:@"tools/list" params:[NSDictionary dictionary] timeout:10];
        expectThat([TBMCPFunctionTools(listed) count] == 1, @"legacy sse: lists tools (an address ending /sse)");
        expectThat([toolText(c, @"one") isEqualToString:@"echo: one auth=Bearer tok"], @"legacy sse: a call is answered on the stream, with the token");
        expectThat([toolText(c, @"two") hasPrefix:@"echo: two"], @"legacy sse: a second call works");
        [c close];
    }
    {
        TBMCPHTTPClient *c = [TBMCPHTTPClient clientWithURL:[base stringByAppendingString:@"/legacy-only/mcp"] token:@""];
        BOOL fellBack = NO;
        /* the address is not /sse and answers 405 to a POST, but has no stream there either: it must fail cleanly, not hang */
        @try { [c start]; } @catch (NSException *e) { fellBack = YES; }
        expectThat(fellBack, @"a 405 with no event stream behind it fails with an error");
    }
    {
        TBMCPHTTPClient *c = [TBMCPHTTPClient clientWithURL:[base stringByAppendingString:@"/oauth/mcp"] token:@""];
        Browser *browser = [[[Browser alloc] init] autorelease];
        NSString *url = [base stringByAppendingString:@"/oauth/mcp"], *text = nil;
        [NSThread detachNewThreadSelector:@selector(visit:) toTarget:browser withObject:nil];
        @try {
            [c start];
            text = toolText(c, @"signed in");
        } @catch (NSException *e) {
            fprintf(stderr, "oauth error: %s\n", [[e reason] UTF8String]);
        }
        expectThat([text hasPrefix:@"echo: signed in auth=Bearer at"], @"oauth: signed in through the browser step and called a tool");
        expectThat([TBOAuth hasTokenForServer:url], @"oauth: the token is kept");
        sleep(3);   /* the mock's tokens last two seconds */
        text = nil;
        @try { text = toolText(c, @"after expiry"); } @catch (NSException *e) { fprintf(stderr, "refresh error: %s\n", [[e reason] UTF8String]); }
        expectThat([text hasPrefix:@"echo: after expiry auth=Bearer at"], @"oauth: an expired token is refreshed without asking again");
        [TBOAuth forgetServer:url];
        expectThat(![TBOAuth hasTokenForServer:url], @"oauth: forgetting removes the token");
    }
    fprintf(stderr, failures ? "%d FAILED\n" : "all passed\n", failures);
    [pool release];
    return failures ? 1 : 0;
}
