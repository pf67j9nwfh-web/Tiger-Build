/* The built-in servers, the HTTP MCP client and the toolbox, against mock_services.py: extrastest PORT [HOST]   from tiger-build/ */
#import <Foundation/Foundation.h>
#import "TBBuiltin.h"
#import "TBMCP.h"
#import "TBExtras.h"
#import "TBOutputs.h"
#import "TBEngine.h"

static int failures = 0;
static void expectThat(BOOL ok, NSString *name)
{
    fprintf(stderr, "%s %s\n", ok ? "PASS" : "FAIL", [name UTF8String]);
    if (!ok)
        failures++;
}

static NSString *calc(NSString *e)
{
    @try { return [TBBuiltin calculate:e]; } @catch (NSException *x) { return [@"ERR " stringByAppendingString:[x reason]]; }
}

int main(int argc, char **argv)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *base = [NSString stringWithFormat:@"http://%s:%s", argc > 2 ? argv[2] : "127.0.0.1", argv[1]];
    TBRun *run = [TBRun runWithId:@"t"];
    NSDictionary *a;
    expectThat([calc(@"17*23") isEqualToString:@"17*23 = 391"], @"integer arithmetic stays whole");
    expectThat([calc(@"10/4") isEqualToString:@"10/4 = 2.5"], @"division");
    expectThat([calc(@"10/2") isEqualToString:@"10/2 = 5.0"], @"division gives a float");
    expectThat([calc(@"-2**2") isEqualToString:@"-2**2 = -4"], @"power binds tighter than minus");
    expectThat([calc(@"2**-1") isEqualToString:@"2**-1 = 0.5"], @"negative exponent");
    expectThat([calc(@"7 % 3 + 7 // 2") isEqualToString:@"7 % 3 + 7 // 2 = 4"], @"modulo and floor division");
    expectThat([calc(@"sqrt(16)+pi") hasPrefix:@"sqrt(16)+pi = 7.14159265358979"], @"functions and constants");
    expectThat([calc(@"2**5000") hasPrefix:@"ERR exponent too large"], @"huge exponent refused");
    expectThat([calc(@"system('ls')") hasPrefix:@"ERR only numbers"], @"names are refused");
    expectThat([calc(@"1/0") hasPrefix:@"ERR division by zero"], @"division by zero");
    expectThat([[TBBuiltin call:@"convert_units" arguments:[NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:1], @"value", @"mi", @"from", @"km", @"to", nil] server:@"calc" run:run] hasPrefix:@"1 mi = 1.60934"], @"units");
    expectThat([[TBBuiltin call:@"convert_units" arguments:[NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:212], @"value", @"F", @"from", @"C", @"to", nil] server:@"calc" run:run] isEqualToString:@"212 F = 100 C"], @"temperature");
    expectThat([[TBBuiltin call:@"sha256" arguments:[NSDictionary dictionaryWithObject:@"abc" forKey:@"text"] server:@"sysinfo" run:run] isEqualToString:@"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"], @"sha256");
    [[NSUserDefaults standardUserDefaults] setObject:@"/tmp/tb-notes-test.json" forKey:@"TBNotesFile"];
    unlink("/tmp/tb-notes-test.json");
    [TBBuiltin call:@"note_set" arguments:[NSDictionary dictionaryWithObjectsAndKeys:@"a", @"title", @"hello", @"text", nil] server:@"notes" run:run];
    expectThat([[TBBuiltin call:@"note_get" arguments:[NSDictionary dictionaryWithObject:@"a" forKey:@"title"] server:@"notes" run:run] isEqualToString:@"hello"], @"notes keep what they are given");
    expectThat([[TBBuiltin call:@"note_list" arguments:[NSDictionary dictionary] server:@"notes" run:run] isEqualToString:@"a: hello"], @"notes list");

    {
        TBMCPHTTPClient *c = [TBMCPHTTPClient clientWithURL:[base stringByAppendingString:@"/mcp"] token:@"tok"];
        id listed, called;
        [c start];
        listed = [c request:@"tools/list" params:[NSDictionary dictionary] timeout:10];
        called = [c request:@"tools/call" params:[NSDictionary dictionaryWithObjectsAndKeys:@"echo", @"name", [NSDictionary dictionaryWithObject:@"hi" forKey:@"text"], @"arguments", nil] timeout:10];
        expectThat([TBMCPFunctionTools(listed) count] == 1, @"http mcp lists tools");
        expectThat([TBMCPResultText(called) isEqualToString:@"echo: hi token=Bearer tok session=sess-1"], @"http mcp sends the token and keeps the session");
    }
    {
        TBMCPHTTPClient *c = [TBMCPHTTPClient clientWithURL:[base stringByAppendingString:@"/mcp-sse"] token:@""];
        id called;
        [c start];
        called = [c request:@"tools/call" params:[NSDictionary dictionaryWithObjectsAndKeys:@"echo", @"name", [NSDictionary dictionaryWithObject:@"sse" forKey:@"text"], @"arguments", nil] timeout:10];
        expectThat([TBMCPResultText(called) hasPrefix:@"echo: sse"], @"http mcp reads an event stream");
    }
    {
        TBMCPHTTPClient *c = [TBMCPHTTPClient clientWithURL:@"http://example.com/mcp" token:@""];
        BOOL refused = NO;
        @try { [c start]; } @catch (NSException *e) { refused = [[e reason] rangeOfString:@"HTTPS"].location != NSNotFound; }
        expectThat(refused, @"plain http to a public host is refused");
    }
    expectThat([[TBBuiltin call:@"inflation_adjust" arguments:[NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:100], @"amount", [NSNumber numberWithInt:1980], @"from_year", [NSNumber numberWithInt:2024], @"to_year", nil] server:@"inflation" run:run] rangeOfString:@"$380.65 in 2024"].location != NSNotFound, @"inflation: 100 dollars of 1980 in 2024");
    expectThat([[TBBuiltin call:@"convert_currency" arguments:[NSDictionary dictionaryWithObjectsAndKeys:@"usd", @"from", @"USD", @"to", [NSNumber numberWithInt:5], @"amount", nil] server:@"currency" run:run] rangeOfString:@"same currency"].location != NSNotFound, @"currency: the same currency needs no service");
    {
        BOOL refused = NO;
        @try { [TBBuiltin call:@"convert_currency" arguments:[NSDictionary dictionaryWithObjectsAndKeys:@"dollars", @"from", @"EUR", @"to", nil] server:@"currency" run:run]; } @catch (NSException *x) { refused = YES; }
        expectThat(refused, @"currency: a bad code is refused");
    }
    {
        TBExtras *g = [[TBExtras alloc] initWithRun:run];
        NSDictionary *r;
        setenv("TB_GEMINI_API_KEY", "gk", 1);
        [[NSUserDefaults standardUserDefaults] setObject:[base stringByAppendingString:@"/gemini-search"] forKey:@"TBSearchURL.gemini-search"];
        [g definitionsForProvider:@"gemini" skip:[NSSet set]];
        r = [g call:@"agent_web_search" arguments:[NSDictionary dictionaryWithObject:@"capital of Australia" forKey:@"query"]];
        expectThat([[r objectForKey:@"output"] rangeOfString:@"Canberra is the capital."].location != NSNotFound && [[r objectForKey:@"output"] rangeOfString:@"wikipedia.org/wiki/Australia"].location != NSNotFound, @"Gemini search answers with its sources");
        [g release];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"TBSearchURL.gemini-search"];
    }
    {
        TBExtras *dl = [[TBExtras alloc] initWithRun:run];
        NSDictionary *r1, *r2;
        BOOL offeredOff;
        offeredOff = [[[dl definitionsForProvider:@"claude" skip:[NSSet set]] description] rangeOfString:@"agent_download_file"].location == NSNotFound;
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"TBTool.download_enabled"];
        [dl definitionsForProvider:@"claude" skip:[NSSet set]];
        r1 = [dl call:@"agent_download_file" arguments:[NSDictionary dictionaryWithObject:@"http://example.com/a.zip" forKey:@"url"]];
        r2 = [dl call:@"agent_download_file" arguments:[NSDictionary dictionaryWithObject:@"https://127.0.0.1/a.zip" forKey:@"url"]];
        expectThat(offeredOff, @"the download tool is not offered until it is switched on");
        expectThat([[r1 objectForKey:@"failed"] boolValue] && [[r1 objectForKey:@"output"] rangeOfString:@"https"].location != NSNotFound, @"a plain http download is refused");
        expectThat([[r2 objectForKey:@"failed"] boolValue] && [[r2 objectForKey:@"output"] rangeOfString:@"public"].location != NSNotFound, @"a download from this Mac's own network is refused");
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"TBTool.download_enabled"];
        [dl release];
    }
    a = [NSDictionary dictionaryWithObjectsAndKeys:@"x.md", @"name", @"# hi", @"content", nil];
    {
        TBExtras *extras = [[TBExtras alloc] initWithRun:run];
        NSArray *tools = [extras definitionsForProvider:@"claude" skip:[NSSet set]];
        NSDictionary *r;
        expectThat([extras handles:@"agent_save_file"], @"toolbox offers save file");
        r = [extras call:@"agent_save_file" arguments:a];
        expectThat([[r objectForKey:@"media"] hasPrefix:@"file "] && ![[r objectForKey:@"failed"] boolValue], @"saving a file returns it as media");
        r = [extras call:@"agent_show_image" arguments:[NSDictionary dictionaryWithObject:@"http://127.0.0.1/x.png" forKey:@"url"]];
        expectThat([[r objectForKey:@"failed"] boolValue] && [[r objectForKey:@"output"] rangeOfString:@"public"].location != NSNotFound, @"a model cannot make the app fetch local addresses");
        r = [extras call:@"agent_current_time" arguments:[NSDictionary dictionary]];
        expectThat([[r objectForKey:@"failed"] boolValue], @"a tool that was not offered is refused");
        (void)tools;
        [extras release];
    }
    [pool release];
    return failures ? 1 : 0;
}
