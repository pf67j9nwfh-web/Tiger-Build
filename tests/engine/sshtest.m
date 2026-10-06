/* An MCP server on another computer over SSH, through the engine: sshtest TARGET REMOTE-COMMAND   (TARGET is user@address; Tiger Build's key must be
   in that account's authorized_keys, its host key trusted, and for Commander "Allow Other Computers" on there). Run from tiger-build/. */
#import <Foundation/Foundation.h>
#import "TBExtras.h"
#import "TBEngine.h"
#import "TBJSON.h"

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
    TBRun *run = [TBRun runWithId:@"ssh"];
    TBExtras *extras;
    NSArray *tools;
    NSDictionary *r;
    unsigned i;
    BOOL listed = NO, described = NO;
    NSString *server = [NSString stringWithFormat:@"[{\"id\":\"other\",\"title\":\"Other\",\"command\":\"ssh:%s\",\"args\":[%@],\"env\":{},\"enabled\":true,\"approval\":false,\"description\":\"Another Mac.\"}]",
        argv[1], TBJSONString([NSString stringWithUTF8String:argv[2]])];
    if (argc < 3)
        return 2;
    setenv("TB_MCP_SERVERS", [server UTF8String], 1);
    extras = [[TBExtras alloc] initWithRun:run];
    tools = [extras definitionsForProvider:@"claude" skip:[NSSet set]];
    for (i = 0; i < [tools count]; i++) {
        NSString *name = TBString([tools objectAtIndex:i], @"name");
        if ([name isEqualToString:@"mcp_other_start_process"])
            listed = YES;
        if ([name isEqualToString:@"mcp_other_start_process"] && [TBString([tools objectAtIndex:i], @"description") hasPrefix:@"[MCP other: Another Mac.]"])
            described = YES;
    }
    if ([[extras errors] count])
        fprintf(stderr, "errors: %s\n", [[[extras errors] componentsJoinedByString:@"; "] UTF8String]);
    expectThat(listed, @"the other computer's tools are offered");
    expectThat(described, @"the server's description is part of each tool's description");
    r = [extras call:@"mcp_other_start_process" arguments:[NSDictionary dictionaryWithObjectsAndKeys:@"echo from-the-other-mac; uname -n", @"command", [NSNumber numberWithInt:5000], @"timeout_ms", nil]];
    fprintf(stderr, "%s\n", [[r objectForKey:@"output"] UTF8String]);
    expectThat(![[r objectForKey:@"failed"] boolValue] && [[r objectForKey:@"output"] rangeOfString:@"from-the-other-mac"].location != NSNotFound, @"a command runs on the other computer");
    [extras release];
    [pool release];
    return failures ? 1 : 0;
}
