/* The engine's MCP client against the real Commander installed in ~/ppc-commander (Python on the old Macs). */
#import <Foundation/Foundation.h>
#import "TBMCP.h"
#import "TBEngine.h"
#include <sys/time.h>

static int failures = 0;
static void expectThat(BOOL ok, NSString *name)
{
    fprintf(stderr, "%s %s\n", ok ? "PASS" : "FAIL", [name UTF8String]);
    if (!ok)
        failures++;
}
static double now(void) { struct timeval tv; gettimeofday(&tv, NULL); return tv.tv_sec + tv.tv_usec / 1e6; }

int main(int argc, char **argv)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *script = [NSHomeDirectory() stringByAppendingPathComponent:@"ppc-commander/ppc_commander.py"];
    double t0 = now();
    TBMCPClient *c = [TBMCPClient clientWithPath:@"/usr/bin/env" arguments:[NSArray arrayWithObjects:@"LANG=C", @"LC_ALL=C", @"/usr/bin/python", @"-u", script, nil] environment:nil label:@"Commander"];
    id listed, result, text;
    @try {
        [c start];
        fprintf(stderr, "started in %.2f s\n", now() - t0);
        listed = [c request:@"tools/list" params:[NSDictionary dictionary] timeout:30];
        expectThat([TBMCPFunctionTools(listed) count] > 10, @"tools/list gives the tools");
        t0 = now();
        result = [c request:@"tools/call" params:[NSDictionary dictionaryWithObjectsAndKeys:@"start_process", @"name",
            [NSDictionary dictionaryWithObjectsAndKeys:@"echo hello-from-engine; uname -s", @"command", [NSNumber numberWithInt:5000], @"timeout_ms", nil], @"arguments", nil] timeout:30];
        text = TBMCPResultText(result);
        fprintf(stderr, "echo took %.2f s: %s\n", now() - t0, [text UTF8String]);
        expectThat([text rangeOfString:@"hello-from-engine"].location != NSNotFound && [text rangeOfString:@"Darwin"].location != NSNotFound, @"start_process runs a command and returns its output");
        result = [c request:@"tools/call" params:[NSDictionary dictionaryWithObjectsAndKeys:@"read_file", @"name", [NSDictionary dictionaryWithObject:@"/etc/hosts" forKey:@"path"], @"arguments", nil] timeout:30];
        expectThat([TBMCPResultText(result) rangeOfString:@"localhost"].location != NSNotFound, @"read_file reads a file");
        result = [c request:@"tools/call" params:[NSDictionary dictionaryWithObjectsAndKeys:@"read_file", @"name", [NSDictionary dictionaryWithObject:@"/no/such/file" forKey:@"path"], @"arguments", nil] timeout:30];
        expectThat(TBTruth(result, @"isError") || [TBMCPResultText(result) rangeOfString:@"rror"].location != NSNotFound, @"a failing call is reported as an error");
        result = [c request:@"tools/call" params:[NSDictionary dictionaryWithObjectsAndKeys:@"start_process", @"name",
            [NSDictionary dictionaryWithObjectsAndKeys:@"sudo echo nope", @"command", [NSNumber numberWithInt:3000], @"timeout_ms", nil], @"arguments", nil] timeout:30];
        expectThat([[TBMCPResultText(result) lowercaseString] rangeOfString:@"administrator"].location != NSNotFound || [[TBMCPResultText(result) lowercaseString] rangeOfString:@"sudo"].location != NSNotFound, @"sudo is refused unless a person turned it on");
    } @catch (NSException *e) {
        fprintf(stderr, "FAIL exception: %s (%s)\n", [[e reason] UTF8String], [[c stderrText] UTF8String]);
        failures++;
    }
    t0 = now();
    [c close];
    fprintf(stderr, "closed in %.2f s\n", now() - t0);
    [pool release];
    fprintf(stderr, failures ? "%d failed\n" : "all passed\n", failures);
    return failures;
}
