/* The built-in servers, the HTTP MCP client and the toolbox, against mock_services.py: extrastest PORT [HOST]   from tiger-build/ */
#import <Foundation/Foundation.h>
#import "TBBuiltin.h"
#import "TBWebTools.h"
#import "TBIntegrations.h"
#import "TBMCP.h"
#import "TBExtras.h"
#import "TBOutputs.h"
#import "TBEngine.h"
#import "TBJSON.h"
#import "expect.h"


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
    expectThat([[TBBuiltin call:@"host_info" arguments:[NSDictionary dictionary] server:@"sysinfo" run:run] rangeOfString:@"memory:"].length > 0, @"host_info reports memory");
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
        if (getenv("TB_LIVE_DOWNLOAD")) {
            NSDictionary *r3 = [dl call:@"agent_download_file" arguments:[NSDictionary dictionaryWithObject:[NSString stringWithUTF8String:getenv("TB_LIVE_DOWNLOAD")] forKey:@"url"]];
            printf("live download: %s\n", [[r3 description] UTF8String]);
        }
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
    {
        /* the web tool and X posts, against the stand-in service (which is on this Mac, so local addresses are let through) */
        NSDictionary *r;
        NSString *out;
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"TBAllowLocalPictures"];
        [[NSUserDefaults standardUserDefaults] setObject:base forKey:@"TBBaseURL.xposts"];
        [[NSUserDefaults standardUserDefaults] setObject:base forKey:@"TBBaseURL.fxtwitter"];
        r = [TBWebTools call:@"curl" arguments:[NSDictionary dictionaryWithObjectsAndKeys:[base stringByAppendingString:@"/echo?x=1"], @"url", @"X-Test: yes\nAuthorization: Bearer k", @"headers", nil] server:@"web" run:run];
        out = [r objectForKey:@"output"];
        expectThat([out hasPrefix:@"HTTP/1.1 200"] && [out rangeOfString:@"GET /echo?x=1"].length && [out rangeOfString:@"x-test: yes"].length, @"curl: a GET shows the status and the text, and sends the headers");
        r = [TBWebTools call:@"curl" arguments:[NSDictionary dictionaryWithObjectsAndKeys:[base stringByAppendingString:@"/echo"], @"url", @"{\"a\":1}", @"data", nil] server:@"web" run:run];
        out = [r objectForKey:@"output"];
        expectThat([out rangeOfString:@"POST /echo"].length && [out rangeOfString:@"content-type: application/json"].length && [out hasSuffix:@"{\"a\":1}"], @"curl: data makes a POST with a JSON content type");
        r = [TBWebTools call:@"curl" arguments:[NSDictionary dictionaryWithObjectsAndKeys:[base stringByAppendingString:@"/redirect"], @"url", [NSNumber numberWithBool:YES], @"include_headers", nil] server:@"web" run:run];
        expectThat([[r objectForKey:@"output"] rangeOfString:@"Final address:"].length && [[r objectForKey:@"output"] rangeOfString:@"from=redirect"].length, @"curl: redirects are followed");
        r = [TBWebTools call:@"curl" arguments:[NSDictionary dictionaryWithObject:[base stringByAppendingString:@"/px.png"] forKey:@"url"] server:@"web" run:run];
        expectThat([[r objectForKey:@"media"] hasPrefix:@"image "], @"curl: a picture is shown in the chat");
        r = [TBWebTools call:@"curl" arguments:[NSDictionary dictionaryWithObject:[base stringByAppendingString:@"/clip.mp4"] forKey:@"url"] server:@"web" run:run];
        expectThat([[r objectForKey:@"media"] hasPrefix:@"video "], @"curl: a video is shown in the chat");
        r = [TBWebTools call:@"curl" arguments:[NSDictionary dictionaryWithObjectsAndKeys:[base stringByAppendingString:@"/echo"], @"url", @"echo.txt", @"save_as", nil] server:@"web" run:run];
        expectThat([[r objectForKey:@"media"] hasPrefix:@"file "] && [[r objectForKey:@"output"] rangeOfString:@"SHA-256"].length, @"curl: save_as keeps text as a file");
        r = [TBWebTools call:@"curl" arguments:[NSDictionary dictionaryWithObjectsAndKeys:[base stringByAppendingString:@"/echo"], @"url", [NSNumber numberWithInt:500], @"max_chars", nil] server:@"web" run:run];
        expectThat([r objectForKey:@"media"] == nil, @"curl: text gives no media");
        {
            /* ftyp, then moov > trak > mdia > minf > stbl > ctts (version 1, offsets 0, -40, 60) */
            unsigned char file[] = {0,0,0,12,'f','t','y','p','i','s','o','m',
                0,0,0,72,'m','o','o','v', 0,0,0,64,'t','r','a','k', 0,0,0,56,'m','d','i','a', 0,0,0,48,'m','i','n','f', 0,0,0,40,'s','t','b','l',
                0,0,0,32,'c','t','t','s', 1,0,0,0, 0,0,0,2, 0,0,0,1, 0xff,0xff,0xff,0xd8, 0,0,0,1, 0,0,0,60};
            NSData *fixed = [TBWebTools playableVideo:[NSData dataWithBytes:file length:sizeof file]];
            const unsigned char *f = [fixed bytes];
            expectThat([fixed length] == sizeof file && f[60] == 0 && f[75] == 0 && f[83] == 100, @"video: signed composition offsets are rewritten so old QuickTime opens it");
        }
        {
            NSString *file = @"/tmp/tb-curl-test/sub/out.txt";
            NSDictionary *want = [NSDictionary dictionaryWithObjectsAndKeys:[base stringByAppendingString:@"/echo?save=1"], @"url", file, @"output_path", nil];
            BOOL refusedSecond = NO, refusedSystem = NO, refusedOff = NO;
            [[NSFileManager defaultManager] removeFileAtPath:@"/tmp/tb-curl-test" handler:nil];
            r = [TBWebTools call:@"curl" arguments:want server:@"web" run:run];
            out = [r objectForKey:@"output"];
            expectThat([out rangeOfString:@"Saved "].length && [out rangeOfString:file].length && [out rangeOfString:@"SHA-256 "].length && [r objectForKey:@"media"] == nil
                && [[NSString stringWithContentsOfFile:file] hasPrefix:@"GET /echo?save=1"] && ![[NSFileManager defaultManager] fileExistsAtPath:[file stringByAppendingString:@".part"]], @"curl: output_path writes the response to that file (making folders) and says so");
            @try { [TBWebTools call:@"curl" arguments:want server:@"web" run:run]; } @catch (NSException *x) { refusedSecond = [[x reason] rangeOfString:@"already exists"].length > 0; }
            expectThat(refusedSecond, @"curl: output_path does not replace a file unless overwrite is set");
            r = [TBWebTools call:@"curl" arguments:[NSDictionary dictionaryWithObjectsAndKeys:[base stringByAppendingString:@"/echo?again=1"], @"url", file, @"output_path", [NSNumber numberWithBool:YES], @"overwrite", nil] server:@"web" run:run];
            expectThat([[NSString stringWithContentsOfFile:file] hasPrefix:@"GET /echo?again=1"], @"curl: overwrite replaces it");
            @try { [TBWebTools call:@"curl" arguments:[NSDictionary dictionaryWithObjectsAndKeys:[base stringByAppendingString:@"/echo"], @"url", @"/etc/tb-test", @"output_path", nil] server:@"web" run:run]; } @catch (NSException *x) { refusedSystem = [[x reason] rangeOfString:@"not allowed"].length > 0; }
            expectThat(refusedSystem, @"curl: system folders are refused");
            @try { [TBWebTools call:@"curl" arguments:want server:@"web" run:run saving:NO]; } @catch (NSException *x) { refusedOff = [[x reason] rangeOfString:@"Commander"].length > 0; }
            expectThat(refusedOff, @"curl: output_path needs Commander on");
            [[NSFileManager defaultManager] removeFileAtPath:@"/tmp/tb-curl-test" handler:nil];
            expectThat([TBIntegrations downloadLimit] == 50UL * 1024 * 1024, @"the download limit is 50 MB unless changed");
            [[NSUserDefaults standardUserDefaults] setInteger:7 forKey:@"TBTool.download_max_mb"];
            expectThat([TBIntegrations downloadLimit] == 7UL * 1024 * 1024, @"the download limit follows the setting");
            [[NSUserDefaults standardUserDefaults] setInteger:1 forKey:@"TBTool.download_max_mb"];
            {
                BOOL refusedBig = NO, refusedBigFile = NO;
                @try { [TBWebTools call:@"curl" arguments:[NSDictionary dictionaryWithObject:[base stringByAppendingString:@"/big"] forKey:@"url"] server:@"web" run:run]; } @catch (NSException *x) { refusedBig = [[x reason] rangeOfString:@"larger than 1 MB"].length > 0; }
                @try { [TBWebTools call:@"curl" arguments:[NSDictionary dictionaryWithObjectsAndKeys:[base stringByAppendingString:@"/big"], @"url", @"/tmp/tb-curl-big.bin", @"output_path", nil] server:@"web" run:run]; } @catch (NSException *x) { refusedBigFile = [[x reason] rangeOfString:@"larger than 1 MB"].length > 0; }
                expectThat(refusedBig && refusedBigFile && ![[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/tb-curl-big.bin"] && ![[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/tb-curl-big.bin.part"], @"curl: a response over the limit is refused, and no partial file is left");
            }
            [[NSUserDefaults standardUserDefaults] setInteger:3 forKey:@"TBTool.download_max_mb"];
            r = [TBWebTools call:@"curl" arguments:[NSDictionary dictionaryWithObjectsAndKeys:[base stringByAppendingString:@"/big"], @"url", @"/tmp/tb-curl-big.bin", @"output_path", nil] server:@"web" run:run];
            expectThat([[r objectForKey:@"output"] rangeOfString:@"Saved 2097152 bytes"].length > 0, @"curl: a larger limit lets a 2 MB file be saved");
            unlink("/tmp/tb-curl-big.bin");
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"TBTool.download_max_mb"];
        }
        expectThat([[TBWebTools postIdFrom:@"https://x.com/ada/status/1585341984679469056?s=20"] isEqualToString:@"1585341984679469056"]
            && [[TBWebTools postIdFrom:@"https://twitter.com/i/web/status/123"] isEqualToString:@"123"] && [[TBWebTools postIdFrom:@"456"] isEqualToString:@"456"] && ![TBWebTools postIdFrom:@"https://x.com/ada"], @"x_post: the post number from an address");
        r = [TBWebTools call:@"x_post" arguments:[NSDictionary dictionaryWithObject:@"https://x.com/ada/status/999" forKey:@"url"] server:@"xposts" run:run];
        out = [r objectForKey:@"output"];
        expectThat([out rangeOfString:@"Post by Ada (@ada), verified"].length && [out rangeOfString:@"Hello & welcome https://example.com/page"].length && [out rangeOfString:@"pic"].length && [out rangeOfString:@"Replies 57, likes 1200, reposts 321, views 9000."].length, @"x_post: the text is read, with links opened and the picture link left out");
        {
            NSArray *lines = [[r objectForKey:@"media"] componentsSeparatedByString:@"\n"];
            NSArray *first = [[lines objectAtIndex:0] componentsSeparatedByString:@" "];
            id data = [first count] == 3 ? TBJSONParse(TBBase64Decode([first objectAtIndex:2]), NULL) : nil;
            expectThat([lines count] == 3 && [[lines objectAtIndex:2] hasPrefix:@"tweetvideo "] && [[lines objectAtIndex:2] hasSuffix:@" tweet"] && [[first objectAtIndex:0] isEqualToString:@"tweet"] && [[first objectAtIndex:1] isEqualToString:@"999"] && [[lines objectAtIndex:1] hasPrefix:@"image "] && [[lines objectAtIndex:1] hasSuffix:@" tweet"], @"x_post: the post and its photos as one picture come back for the chat");
            expectThat([[data objectForKey:@"name"] isEqualToString:@"Ada"] && [[data objectForKey:@"reposts"] intValue] == 321 && [[data objectForKey:@"text"] hasPrefix:@"Hello & welcome"] && [[data objectForKey:@"avatar"] length] > 20 && [[data objectForKey:@"badge"] isEqualToString:@"gold"] && [[data objectForKey:@"square"] boolValue], @"x_post: the post's data, author picture and the gold badge of a business travel with it");
        }
        r = [TBWebTools call:@"x_post" arguments:[NSDictionary dictionaryWithObjectsAndKeys:@"999", @"url", @"all", @"show", nil] server:@"xposts" run:run];
        expectThat([[[r objectForKey:@"media"] componentsSeparatedByString:@"\n"] count] == 5, @"x_post: show all gives the post, its photos and video, and both photos at full size");
        r = [TBWebTools call:@"x_post" arguments:[NSDictionary dictionaryWithObjectsAndKeys:@"999", @"url", @"text", @"show", nil] server:@"xposts" run:run];
        expectThat([r objectForKey:@"media"] == nil, @"x_post: show text gives no pictures");
        {
            BOOL refused = NO;
            @try { [TBWebTools call:@"x_post" arguments:[NSDictionary dictionaryWithObject:@"888" forKey:@"url"] server:@"xposts" run:run]; }
            @catch (NSException *x) { refused = [[x reason] rangeOfString:@"could not be found"].length > 0; }
            expectThat(refused, @"x_post: a missing post is explained");
        }
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"TBAllowLocalPictures"];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"TBBaseURL.xposts"];
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"TBBaseURL.fxtwitter"];
    }
    [pool release];
    return failures ? 1 : 0;
}
