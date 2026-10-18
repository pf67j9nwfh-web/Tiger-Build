/* The engine's MCP client against the real Commander program.   commandertest PATH-TO-ppc-commander */
#import <Foundation/Foundation.h>
#import "TBMCP.h"
#import "TBEngine.h"
#import "TBJSON.h"
#import "expect.h"
#include <sys/time.h>

static double now(void) { struct timeval tv; gettimeofday(&tv, NULL); return tv.tv_sec + tv.tv_usec / 1e6; }

int main(int argc, char **argv)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *program = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : [NSHomeDirectory() stringByAppendingPathComponent:@"commander/ppc-commander"];
    NSString *scratch = [NSString stringWithFormat:@"/tmp/commandertest-%d", (int)getpid()];
    double t0 = now();
    TBMCPClient *c = [TBMCPClient clientWithPath:program arguments:[NSArray array] environment:[NSDictionary dictionaryWithObjectsAndKeys:@"1", @"TB_LOCAL", @"C", @"LANG", nil] label:@"Commander"];
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
        /* files */
        result = [c request:@"tools/call" params:[NSDictionary dictionaryWithObjectsAndKeys:@"create_directory", @"name", [NSDictionary dictionaryWithObject:scratch forKey:@"path"], @"arguments", nil] timeout:30];
        result = [c request:@"tools/call" params:[NSDictionary dictionaryWithObjectsAndKeys:@"write_file", @"name",
            [NSDictionary dictionaryWithObjectsAndKeys:[scratch stringByAppendingString:@"/a.txt"], @"path", @"one\ntwo\nthree\n", @"content", nil], @"arguments", nil] timeout:30];
        expectThat(!TBTruth(result, @"isError"), @"write_file writes a file");
        result = [c request:@"tools/call" params:[NSDictionary dictionaryWithObjectsAndKeys:@"edit_block", @"name",
            [NSDictionary dictionaryWithObjectsAndKeys:[scratch stringByAppendingString:@"/a.txt"], @"file_path", @"two", @"old_string", @"2", @"new_string", nil], @"arguments", nil] timeout:30];
        expectThat(!TBTruth(result, @"isError"), @"edit_block replaces a snippet");
        result = [c request:@"tools/call" params:[NSDictionary dictionaryWithObjectsAndKeys:@"read_file", @"name", [NSDictionary dictionaryWithObject:[scratch stringByAppendingString:@"/a.txt"] forKey:@"path"], @"arguments", nil] timeout:30];
        expectThat([TBMCPResultText(result) rangeOfString:@"one\n2\nthree"].location != NSNotFound, @"the edit shows when the file is read");
        result = [c request:@"tools/call" params:[NSDictionary dictionaryWithObjectsAndKeys:@"start_search", @"name",
            [NSDictionary dictionaryWithObjectsAndKeys:scratch, @"path", @"thr+ee", @"pattern", @"content", @"searchType", nil], @"arguments", nil] timeout:30];
        expectThat([TBMCPResultText(result) rangeOfString:@"a.txt:3"].location != NSNotFound, @"a content search finds the line");
        result = [c request:@"tools/call" params:[NSDictionary dictionaryWithObjectsAndKeys:@"start_process", @"name",
            [NSDictionary dictionaryWithObjectsAndKeys:@"mkfs /dev/null", @"command", [NSNumber numberWithInt:3000], @"timeout_ms", nil], @"arguments", nil] timeout:30];
        expectThat(TBTruth(result, @"isError") && [TBMCPResultText(result) rangeOfString:@"blocked"].location != NSNotFound, @"a blocked command is refused");
        result = [c request:@"tools/call" params:[NSDictionary dictionaryWithObjectsAndKeys:@"git_write", @"name",
            [NSDictionary dictionaryWithObjectsAndKeys:[NSArray arrayWithObjects:@"push", @"--force", nil], @"args", scratch, @"path", nil], @"arguments", nil] timeout:30];
        expectThat(TBTruth(result, @"isError") && [TBMCPResultText(result) rangeOfString:@"not allowed"].location != NSNotFound, @"a force push is refused");
        result = [c request:@"tools/call" params:[NSDictionary dictionaryWithObjectsAndKeys:@"repo_info", @"name", [NSDictionary dictionaryWithObject:scratch forKey:@"path"], @"arguments", nil] timeout:30];
        expectThat([TBMCPResultText(result) rangeOfString:@"program"].location != NSNotFound, @"repo_info reports on the source control programs");
    } @catch (NSException *e) {
        fprintf(stderr, "FAIL exception: %s (%s)\n", [[e reason] UTF8String], [[c stderrText] UTF8String]);
        failures++;
    }
    t0 = now();
    [c close];
    [[NSFileManager defaultManager] removeFileAtPath:scratch handler:nil];
    /* another computer arriving over SSH has no TB_LOCAL: refused unless remote access is switched on */
    {
        TBMCPClient *remote = [TBMCPClient clientWithPath:program arguments:[NSArray array] environment:[NSDictionary dictionaryWithObject:@"" forKey:@"TB_LOCAL"] label:@"Remote"];
        BOOL refused = NO;
        NSString *marker = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Tiger Build/commander/remote-access"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:marker]) {
            @try {
                [remote start];
                [remote request:@"tools/list" params:[NSDictionary dictionary] timeout:5];
            } @catch (NSException *e) {
                refused = YES;
            }
            expectThat(refused, @"another computer is refused while remote access is off");
        }
        [remote close];
    }
    {
        /* a stop signal while a program runs: the Commander ends at once, takes the program with it, and does not spin (it once hung at full CPU in its handler) */
        NSTask *task = [[[NSTask alloc] init] autorelease];
        NSPipe *input = [NSPipe pipe];
        NSString *requests = @"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"t\",\"version\":\"1\"}}}\n"
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n"
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"start_process\",\"arguments\":{\"command\":\"sleep 31\",\"timeout_ms\":800}}}\n";
        double begun;
        BOOL gone;
        [task setLaunchPath:program];
        [task setEnvironment:[NSDictionary dictionaryWithObjectsAndKeys:@"1", @"TB_LOCAL", @"C", @"LANG", NSHomeDirectory(), @"HOME", nil]];
        [task setStandardInput:input];
        [task setStandardOutput:[NSFileHandle fileHandleWithNullDevice]];
        [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];
        [task launch];
        [[input fileHandleForWriting] writeData:[requests dataUsingEncoding:NSUTF8StringEncoding]];
        [NSThread sleepForTimeInterval:2.0];
        kill([task processIdentifier], SIGTERM);
        begun = now();
        while ([task isRunning] && now() - begun < 3)
            [NSThread sleepForTimeInterval:0.05];
        gone = ![task isRunning];
        [NSThread sleepForTimeInterval:0.3];
        expectThat(gone && now() - begun < 2.5, @"a stop signal ends the Commander at once");
        expectThat(system("pgrep -f 'sleep 31' > /dev/null") != 0, @"and the program it was running stops with it");
        if (!gone)
            kill([task processIdentifier], SIGKILL);
    }
    {
        /* ppc-commander --screen: the saved setting that a program which does not say (another computer, Claude Code) goes by */
        NSString *home = @"/tmp/tb-screen-home";
        NSTask *task;
        NSPipe *out;
        NSString *answer;
        NSDictionary *environment = [NSDictionary dictionaryWithObjectsAndKeys:home, @"HOME", @"1", @"TB_LOCAL", @"C", @"LANG", nil];
        NSString *words[] = {@"status", @"on", @"status", @"off"};
        NSString *want[] = {@"off", @"on", @"on", @"off"};
        int k;
        [[NSFileManager defaultManager] removeFileAtPath:home handler:nil];
        [[NSFileManager defaultManager] createDirectoryAtPath:home attributes:nil];
        for (k = 0; k < 4; k++) {
            task = [[[NSTask alloc] init] autorelease];
            out = [NSPipe pipe];
            [task setLaunchPath:program];
            [task setArguments:[NSArray arrayWithObjects:@"--screen", words[k], nil]];
            [task setEnvironment:environment];
            [task setStandardOutput:out];
            [task launch];
            answer = TBTrim([[[NSString alloc] initWithData:[[out fileHandleForReading] readDataToEndOfFile] encoding:NSUTF8StringEncoding] autorelease]);
            [task waitUntilExit];
            expectThat([answer isEqualToString:want[k]], [NSString stringWithFormat:@"--screen %@ says %@", words[k], want[k]]);
        }
        {
            NSString *state;
            TBMCPClient *plain;
            NSDictionary *saved;
            /* on again, then a client that sets no TB_SCREEN is offered the screen tools; off, it is not */
            task = [[[NSTask alloc] init] autorelease];
            [task setLaunchPath:program];
            [task setArguments:[NSArray arrayWithObjects:@"--screen", @"on", nil]];
            [task setEnvironment:environment];
            [task setStandardOutput:[NSFileHandle fileHandleWithNullDevice]];
            [task launch];
            [task waitUntilExit];
            plain = [TBMCPClient clientWithPath:program arguments:[NSArray array] environment:environment label:@"Commander"];
            [plain start];
            saved = [plain request:@"tools/list" params:[NSDictionary dictionary] timeout:10];
            state = [TBJSONString(saved) rangeOfString:@"screen_click"].length ? @"offered" : @"hidden";
            [plain close];
            expectThat([state isEqualToString:@"offered"], @"with the setting on, a client that sets nothing is offered the screen tools");
            task = [[[NSTask alloc] init] autorelease];
            [task setLaunchPath:program];
            [task setArguments:[NSArray arrayWithObjects:@"--screen", @"off", nil]];
            [task setEnvironment:environment];
            [task setStandardOutput:[NSFileHandle fileHandleWithNullDevice]];
            [task launch];
            [task waitUntilExit];
            plain = [TBMCPClient clientWithPath:program arguments:[NSArray array] environment:environment label:@"Commander"];
            [plain start];
            saved = [plain request:@"tools/list" params:[NSDictionary dictionary] timeout:10];
            [plain close];
            expectThat([TBJSONString(saved) rangeOfString:@"screen_click"].length == 0, @"with it off they are not offered");
        }
        [[NSFileManager defaultManager] removeFileAtPath:home handler:nil];
    }
    fprintf(stderr, "closed in %.2f s\n", now() - t0);
    [pool release];
    fprintf(stderr, failures ? "%d failed\n" : "all passed\n", failures);
    return failures;
}
