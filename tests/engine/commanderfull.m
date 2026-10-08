/* The rest of Commander's tools, against the real program: commanderfull PATH-TO-ppc-commander   (needs git and svn for those checks) */
#import <Foundation/Foundation.h>
#import "TBMCP.h"
#import "TBEngine.h"
#import "TBJSON.h"
#include <unistd.h>

static int failures = 0;
static TBMCPClient *client;
static NSString *program;

static void expectThat(BOOL ok, NSString *name)
{
    fprintf(stderr, "%s %s\n", ok ? "PASS" : "FAIL", [name UTF8String]);
    if (!ok)
        failures++;
}

static NSDictionary *call(TBMCPClient *c, NSString *name, NSDictionary *args)
{
    id r = [c request:@"tools/call" params:[NSDictionary dictionaryWithObjectsAndKeys:name, @"name", args ? args : [NSDictionary dictionary], @"arguments", nil] timeout:60];
    return [NSDictionary dictionaryWithObjectsAndKeys:TBMCPResultText(r), @"text", [NSNumber numberWithBool:TBTruth(r, @"isError")], @"error", nil];
}
#define TEXT(r) [r objectForKey:@"text"]
#define FAILED(r) [[r objectForKey:@"error"] boolValue]
static NSDictionary *D1(id v, NSString *k) { return [NSDictionary dictionaryWithObject:v forKey:k]; }

static TBMCPClient *start(NSDictionary *extra)
{
    NSMutableDictionary *env = [NSMutableDictionary dictionaryWithObjectsAndKeys:@"1", @"TB_LOCAL", @"C", @"LANG", nil];
    TBMCPClient *c;
    if (extra)
        [env addEntriesFromDictionary:extra];
    c = [TBMCPClient clientWithPath:program arguments:[NSArray array] environment:env label:@"Commander"];
    [c start];
    return c;
}

static NSString *run(NSString *command)
{
    NSTask *t = [[[NSTask alloc] init] autorelease];
    NSPipe *p = [NSPipe pipe];
    [t setLaunchPath:@"/bin/sh"];
    [t setArguments:[NSArray arrayWithObjects:@"-c", command, nil]];
    [t setStandardOutput:p];
    [t setStandardError:p];
    [t launch];
    return [[[NSString alloc] initWithData:[[p fileHandleForReading] readDataToEndOfFile] encoding:NSUTF8StringEncoding] autorelease];
}

int main(int argc, char **argv)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *dir = [NSString stringWithFormat:@"/tmp/cmfull-%d", (int)getpid()], *file = [dir stringByAppendingString:@"/lines.txt"];
    NSDictionary *r;
    NSString *pid;
    program = [NSString stringWithUTF8String:argv[1]];
    run([NSString stringWithFormat:@"rm -rf %@; mkdir -p %@/sub/deeper", dir, dir]);
    client = start(nil);

    /* reading */
    {
        NSMutableString *body = [NSMutableString string];
        int i;
        for (i = 1; i <= 50; i++)
            [body appendFormat:@"line %d\n", i];
        call(client, @"write_file", [NSDictionary dictionaryWithObjectsAndKeys:file, @"path", body, @"content", nil]);
    }
    r = call(client, @"read_file", [NSDictionary dictionaryWithObjectsAndKeys:file, @"path", [NSNumber numberWithInt:10], @"offset", [NSNumber numberWithInt:3], @"length", nil]);
    expectThat([TEXT(r) rangeOfString:@"line 11\nline 12\nline 13"].location != NSNotFound && [TEXT(r) rangeOfString:@"line 14"].location == NSNotFound, @"read_file offset and length");
    r = call(client, @"read_file", [NSDictionary dictionaryWithObjectsAndKeys:file, @"path", [NSNumber numberWithInt:-2], @"offset", nil]);
    expectThat([TEXT(r) rangeOfString:@"line 49"].location != NSNotFound && [TEXT(r) rangeOfString:@"line 48"].location == NSNotFound, @"read_file from the end");
    r = call(client, @"read_multiple_files", D1([NSArray arrayWithObjects:file, @"/etc/hosts", @"/no/such", nil], @"paths"));
    expectThat([TEXT(r) rangeOfString:@"line 1"].location != NSNotFound && [TEXT(r) rangeOfString:@"localhost"].location != NSNotFound, @"read_multiple_files reads several and survives a bad one");
    r = call(client, @"read_file", [NSDictionary dictionaryWithObjectsAndKeys:[@"file://" stringByAppendingString:file], @"path", [NSNumber numberWithBool:YES], @"isUrl", nil]);
    expectThat(FAILED(r) && [TEXT(r) rangeOfString:@"line 1"].location == NSNotFound, @"a file: address is not a way around the path checks");

    /* writing, moving, listing, info */
    r = call(client, @"write_file", [NSDictionary dictionaryWithObjectsAndKeys:file, @"path", @"appended\n", @"content", @"append", @"mode", nil]);
    r = call(client, @"read_file", [NSDictionary dictionaryWithObjectsAndKeys:file, @"path", [NSNumber numberWithInt:-1], @"offset", nil]);
    expectThat([TEXT(r) rangeOfString:@"appended"].location != NSNotFound, @"write_file appends");
    r = call(client, @"move_file", [NSDictionary dictionaryWithObjectsAndKeys:file, @"source", [dir stringByAppendingString:@"/sub/moved.txt"], @"destination", nil]);
    expectThat(!FAILED(r) && [[NSFileManager defaultManager] fileExistsAtPath:[dir stringByAppendingString:@"/sub/moved.txt"]], @"move_file moves");
    r = call(client, @"list_directory", [NSDictionary dictionaryWithObjectsAndKeys:dir, @"path", [NSNumber numberWithInt:3], @"depth", nil]);
    expectThat([TEXT(r) rangeOfString:@"moved.txt"].location != NSNotFound && [TEXT(r) rangeOfString:@"deeper"].location != NSNotFound, @"list_directory goes down");
    r = call(client, @"get_file_info", D1([dir stringByAppendingString:@"/sub/moved.txt"], @"path"));
    expectThat([TEXT(r) rangeOfString:@"size"].location != NSNotFound, @"get_file_info");
    r = call(client, @"edit_block", [NSDictionary dictionaryWithObjectsAndKeys:[dir stringByAppendingString:@"/sub/moved.txt"], @"file_path", @"line", @"old_string", @"x", @"new_string", nil]);
    expectThat(FAILED(r), @"edit_block refuses an ambiguous match");

    /* a program that talks: start, write to it, read, list, end */
    r = call(client, @"start_process", [NSDictionary dictionaryWithObjectsAndKeys:@"cat", @"command", [NSNumber numberWithInt:1000], @"timeout_ms", nil]);
    {
        NSRange at = [TEXT(r) rangeOfString:@"pid: "];
        pid = at.location == NSNotFound ? nil : [[[TEXT(r) substringFromIndex:NSMaxRange(at)] componentsSeparatedByString:@"\n"] objectAtIndex:0];
    }
    expectThat([pid length] > 0, @"start_process returns a pid for a running program");
    r = call(client, @"interact_with_process", [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:[pid intValue]], @"pid", @"hello cat\n", @"input", [NSNumber numberWithInt:1500], @"timeout_ms", nil]);
    expectThat([TEXT(r) rangeOfString:@"hello cat"].location != NSNotFound, @"interact_with_process sends input and reads the answer");
    r = call(client, @"list_sessions", nil);
    expectThat([TEXT(r) rangeOfString:pid].location != NSNotFound, @"list_sessions shows it");
    r = call(client, @"force_terminate", D1([NSNumber numberWithInt:[pid intValue]], @"pid"));
    expectThat(!FAILED(r), @"force_terminate");
    r = call(client, @"list_processes", nil);
    expectThat([TEXT(r) rangeOfString:@"PID"].location != NSNotFound, @"list_processes");
    r = call(client, @"kill_process", D1([NSNumber numberWithInt:1], @"pid"));
    expectThat(FAILED(r), @"kill_process refuses pid 1");
    r = call(client, @"start_process", [NSDictionary dictionaryWithObjectsAndKeys:@"sleep 30", @"command", [NSNumber numberWithInt:300], @"timeout_ms", nil]);
    expectThat([TEXT(r) rangeOfString:@"running"].location != NSNotFound, @"a slow command is reported as still running");

    /* blocked commands, in the disguises a model might try */
    {
        NSArray *tries = [NSArray arrayWithObjects:@"sudo mkfs /dev/null", @"env shutdown -h now", @"echo hi; reboot", @"/sbin/shutdown now", @"x=1 mkfs foo", @"bash -c 'halt'", @"dd if=/dev/zero of=/dev/null", nil];
        unsigned i;
        BOOL all = YES;
        for (i = 0; i < [tries count]; i++) {
            r = call(client, @"start_process", [NSDictionary dictionaryWithObjectsAndKeys:[tries objectAtIndex:i], @"command", [NSNumber numberWithInt:1000], @"timeout_ms", nil]);
            if (!FAILED(r)) {
                fprintf(stderr, "  not blocked: %s\n", [[tries objectAtIndex:i] UTF8String]);
                all = NO;
            }
        }
        expectThat(all, @"blocked commands stay blocked behind sudo, env, ; and paths");
    }
    r = call(client, @"set_config_value", [NSDictionary dictionaryWithObjectsAndKeys:@"blockedCommands", @"key", [NSArray array], @"value", nil]);
    expectThat(FAILED(r), @"a model cannot unblock commands");
    r = call(client, @"set_config_value", [NSDictionary dictionaryWithObjectsAndKeys:@"fileReadLineLimit", @"key", [NSNumber numberWithInt:500], @"value", nil]);
    expectThat(!FAILED(r), @"a model may change the read limit");
    r = call(client, @"get_usage_stats", nil);
    expectThat([TEXT(r) rangeOfString:@"start_process"].location != NSNotFound, @"usage counts calls");
    r = call(client, @"get_recent_tool_calls", D1([NSNumber numberWithInt:5], @"maxResults"));
    expectThat([TEXT(r) length] > 20, @"recent calls are kept");
    {   /* a picture */
        run([NSString stringWithFormat:@"/usr/bin/sips -s format png /System/Library/CoreServices/DefaultDesktop.heic --out %@/p.png >/dev/null 2>&1 || cp /System/Library/Desktop\\ Pictures/*.jpg %@/p.jpg 2>/dev/null", dir, dir]);
        if ([[NSFileManager defaultManager] fileExistsAtPath:[dir stringByAppendingString:@"/p.png"]]) {
            id raw = [client request:@"tools/call" params:[NSDictionary dictionaryWithObjectsAndKeys:@"view_image", @"name", D1([dir stringByAppendingString:@"/p.png"], @"path"), @"arguments", nil] timeout:60];
            expectThat([TBMCPResultImages(raw) count] == 1, @"view_image returns the picture");
        }
    }

    /* git and Subversion, when the Mac has them */
    if ([run(@"command -v git") length] > 0) {
        NSString *repo = [dir stringByAppendingString:@"/repo"];
        run([NSString stringWithFormat:@"mkdir %@ && cd %@ && git init -q && git config user.email t@t && git config user.name t", repo, repo]);
        call(client, @"write_file", [NSDictionary dictionaryWithObjectsAndKeys:[repo stringByAppendingString:@"/a.txt"], @"path", @"one\n", @"content", nil]);
        r = call(client, @"repo_info", D1(repo, @"path"));
        expectThat([TEXT(r) rangeOfString:@"git"].location != NSNotFound, @"repo_info sees a repository");
        r = call(client, @"git_write", [NSDictionary dictionaryWithObjectsAndKeys:[NSArray arrayWithObjects:@"add", @"a.txt", nil], @"args", repo, @"path", nil]);
        r = call(client, @"git_write", [NSDictionary dictionaryWithObjectsAndKeys:[NSArray arrayWithObjects:@"commit", @"-m", @"first", nil], @"args", repo, @"path", nil]);
        expectThat(!FAILED(r), @"git_write commits with -m");
        r = call(client, @"git_write", [NSDictionary dictionaryWithObjectsAndKeys:[NSArray arrayWithObjects:@"commit", @"--allow-empty", nil], @"args", repo, @"path", nil]);
        expectThat(FAILED(r), @"a commit without -m is refused");
        r = call(client, @"git_read", [NSDictionary dictionaryWithObjectsAndKeys:[NSArray arrayWithObjects:@"log", @"--oneline", nil], @"args", repo, @"path", nil]);
        expectThat([TEXT(r) rangeOfString:@"first"].location != NSNotFound, @"git_read log");
        r = call(client, @"git_read", [NSDictionary dictionaryWithObjectsAndKeys:[NSArray arrayWithObjects:@"commit", @"-m", @"x", nil], @"args", repo, @"path", nil]);
        expectThat(FAILED(r), @"git_read refuses a write");
        r = call(client, @"git_write", [NSDictionary dictionaryWithObjectsAndKeys:[NSArray arrayWithObjects:@"push", @"--force", @"origin", nil], @"args", repo, @"path", nil]);
        expectThat(FAILED(r), @"a force push is refused");
        r = call(client, @"git_write", [NSDictionary dictionaryWithObjectsAndKeys:[NSArray arrayWithObjects:@"log", @"--output=/tmp/cmfull-out", nil], @"args", repo, @"path", nil]);
        expectThat(FAILED(r), @"--output is refused");
        {
            NSArray *bad = [NSArray arrayWithObjects:[NSArray arrayWithObjects:@"rebase", @"-x", @"touch /tmp/cm-x", @"HEAD", nil], [NSArray arrayWithObjects:@"rebase", @"-xtouch /tmp/cm-x", @"HEAD", nil],
                [NSArray arrayWithObjects:@"rebase", @"--ex=touch /tmp/cm-x", @"HEAD", nil],
                [NSArray arrayWithObjects:@"grep", @"-Otouch /tmp/cm-x;", @"-e", @"x", nil], [NSArray arrayWithObjects:@"grep", @"-nOtouch /tmp/cm-x;", @"-e", @"x", nil], [NSArray arrayWithObjects:@"clone", @"--no-local", @"-u", @"touch /tmp/cm-x", @".", @"d2", nil],
                [NSArray arrayWithObjects:@"clone", @"--upload-p=touch /tmp/cm-x", @".", @"d3", nil], [NSArray arrayWithObjects:@"commit", @"--file=/etc/hosts", nil], nil];
            unsigned k;
            BOOL all = YES;
            for (k = 0; k < [bad count]; k++)
                if (!FAILED(call(client, @"git_write", [NSDictionary dictionaryWithObjectsAndKeys:[bad objectAtIndex:k], @"args", repo, @"path", nil])))
                    all = NO;
            expectThat(all && ![[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/cm-x"], @"short and abbreviated options that run programs, and paths in --option=value, are refused");
        }
        r = call(client, @"git_read", [NSDictionary dictionaryWithObjectsAndKeys:[NSArray arrayWithObjects:@"-c", @"core.pager=sh", @"log", nil], @"args", repo, @"path", nil]);
        expectThat(FAILED(r), @"a sub-command that is not on the list is refused");
    }
    if ([run(@"command -v svnadmin") length] > 0) {
        NSString *repo = [dir stringByAppendingString:@"/svnrepo"], *wc = [dir stringByAppendingString:@"/wc"];
        run([NSString stringWithFormat:@"svnadmin create %@ && svn checkout -q file://%@ %@", repo, repo, wc]);
        call(client, @"write_file", [NSDictionary dictionaryWithObjectsAndKeys:[wc stringByAppendingString:@"/s.txt"], @"path", @"svn\n", @"content", nil]);
        r = call(client, @"svn_write", [NSDictionary dictionaryWithObjectsAndKeys:[NSArray arrayWithObjects:@"add", @"s.txt", nil], @"args", wc, @"path", nil]);
        r = call(client, @"svn_write", [NSDictionary dictionaryWithObjectsAndKeys:[NSArray arrayWithObjects:@"commit", @"-m", @"one", nil], @"args", wc, @"path", nil]);
        expectThat(!FAILED(r), @"svn_write commits");
        r = call(client, @"svn_read", [NSDictionary dictionaryWithObjectsAndKeys:[NSArray arrayWithObjects:@"log", @"-r", @"HEAD", nil], @"args", wc, @"path", nil]);
        expectThat([TEXT(r) rangeOfString:@"one"].location != NSNotFound, @"svn_read log");
        r = call(client, @"svn_write", [NSDictionary dictionaryWithObjectsAndKeys:[NSArray arrayWithObjects:@"commit", @"--password", @"x", @"-m", @"y", nil], @"args", wc, @"path", nil]);
        expectThat(FAILED(r), @"a password on the command line is refused");
    }
    [client close];

    /* a workspace restriction: files and commands stay inside */
    {
        NSString *inside = [dir stringByAppendingString:@"/sub"];
        TBMCPClient *w = start(D1(inside, @"TB_WORKSPACE_ROOT"));
        r = call(w, @"read_file", D1(@"/etc/hosts", @"path"));
        expectThat(FAILED(r), @"a restricted workspace refuses a file outside it");
        r = call(w, @"read_file", D1([inside stringByAppendingString:@"/moved.txt"], @"path"));
        expectThat(!FAILED(r), @"and reads one inside it");
        r = call(w, @"start_process", [NSDictionary dictionaryWithObjectsAndKeys:@"cat /etc/hosts", @"command", [NSNumber numberWithInt:1000], @"timeout_ms", nil]);
        expectThat(FAILED(r), @"a command that names a path outside is refused");
        r = call(w, @"start_process", [NSDictionary dictionaryWithObjectsAndKeys:@"pwd", @"command", [NSNumber numberWithInt:1000], @"timeout_ms", nil]);
        expectThat([TEXT(r) rangeOfString:@"/sub"].location != NSNotFound, @"commands start in the workspace folder");
        [w close];
    }
    /* convert_file runs the converter of the application the Commander is inside (here a stand-in script), and is not offered without one */
    {
        NSString *app = [dir stringByAppendingString:@"/Fake.app/Contents"];
        NSString *copy = [app stringByAppendingString:@"/Resources/ppc-commander"], *script = [app stringByAppendingString:@"/MacOS/TigerBuild"], *doc = [dir stringByAppendingString:@"/doc.docx"];
        TBMCPClient *c;
        NSString *saved = program, *tools;
        run([NSString stringWithFormat:@"mkdir -p '%@/Resources' '%@/MacOS' && cp '%@' '%@' && printf 'x' > '%@'", app, app, program, copy, doc]);
        [@"#!/bin/sh\n[ \"$1\" = --convert ] || exit 2\nprintf 'converted text of %s\\n' \"$2\" > \"$3/text.txt\"\nprintf 'NOTE: stand-in\\nIMAGES: 0\\n'\n" writeToFile:script atomically:NO encoding:NSUTF8StringEncoding error:NULL];
        run([NSString stringWithFormat:@"chmod 755 '%@'", script]);
        program = copy;
        c = start(nil);
        tools = [[c request:@"tools/list" params:[NSDictionary dictionary] timeout:10] description];
        expectThat([tools rangeOfString:@"convert_file"].location != NSNotFound, @"convert_file is offered inside an application");
        r = call(c, @"convert_file", D1(doc, @"path"));
        expectThat(!FAILED(r) && [TEXT(r) rangeOfString:@"converted text of"].location != NSNotFound && [TEXT(r) rangeOfString:@"stand-in"].location != NSNotFound, @"it returns the converter's text");
        r = call(c, @"convert_file", D1(@"/etc/hosts/nothing", @"path"));
        expectThat(FAILED(r), @"a missing file is refused");
        [c close];
        program = saved;
        c = start(nil);
        expectThat([[[c request:@"tools/list" params:[NSDictionary dictionary] timeout:10] description] rangeOfString:@"convert_file"].location == NSNotFound, @"and is not offered without one");
        [c close];
    }
    /* sudo: a Commander of a chat with sudo ticked still needs the key Tiger Build sends it */
    {
        TBMCPClient *s = start(D1(@"1", @"TB_SUDO"));
        NSString *home = [NSString stringWithFormat:@"%@/nosock", dir];
        r = call(s, @"start_process", [NSDictionary dictionaryWithObjectsAndKeys:@"sudo -n true", @"command", [NSNumber numberWithInt:1000], @"timeout_ms", nil]);
        expectThat(FAILED(r) && [TEXT(r) rangeOfString:@"administrator key"].location != NSNotFound, @"sudo without the chat's key is refused before the password is asked for");
        [s notify:@"tb/sudo-key" params:D1(@"abc123", @"key")];
        r = call(s, @"start_process", [NSDictionary dictionaryWithObjectsAndKeys:@"sudo -n true", @"command", [NSNumber numberWithInt:1000], @"timeout_ms", nil]);
        expectThat(FAILED(r) && [TEXT(r) rangeOfString:@"administrator key"].location == NSNotFound, @"with a key it goes on to ask Tiger Build (not running here)");
        (void)home;
        [s close];
        s = start(D1(@"0", @"TB_SUDO"));
        r = call(s, @"start_process", [NSDictionary dictionaryWithObjectsAndKeys:@"sudo -n true", @"command", [NSNumber numberWithInt:1000], @"timeout_ms", nil]);
        expectThat(FAILED(r) && [TEXT(r) rangeOfString:@"commands are off"].location != NSNotFound, @"a chat without the item gets 'off' whatever else is set");
        [s close];
    }
    /* diffs on writes, an extra blocklist, screen tools only when switched on */
    {
        NSString *file = [dir stringByAppendingString:@"/diff.txt"];
        NSDictionary *on = [NSDictionary dictionaryWithObjectsAndKeys:@"1", @"TB_DIFFS", @"1", @"TB_SCREEN", @"curl, wget", @"TB_BLOCKED", nil];
        TBMCPClient *d = start(on);
        NSString *tools;
        r = call(d, @"write_file", [NSDictionary dictionaryWithObjectsAndKeys:file, @"path", @"one\ntwo\nthree\nfour\n", @"content", nil]);
        expectThat([TEXT(r) rangeOfString:@"+two"].location != NSNotFound, @"a new file's write shows its lines as added");
        r = call(d, @"edit_block", [NSDictionary dictionaryWithObjectsAndKeys:file, @"file_path", @"two", @"old_string", @"2", @"new_string", nil]);
        expectThat([TEXT(r) rangeOfString:@"-two"].location != NSNotFound && [TEXT(r) rangeOfString:@"+2"].location != NSNotFound && [TEXT(r) rangeOfString:@"@@"].location != NSNotFound, @"edit_block shows a diff");
        r = call(d, @"write_file", [NSDictionary dictionaryWithObjectsAndKeys:file, @"path", @"one\n2\nthree\n", @"content", nil]);
        expectThat([TEXT(r) rangeOfString:@"-four"].location != NSNotFound, @"a rewrite shows the removed line");
        r = call(d, @"start_process", [NSDictionary dictionaryWithObjectsAndKeys:@"curl --version", @"command", [NSNumber numberWithInt:1000], @"timeout_ms", nil]);
        expectThat(FAILED(r) && [TEXT(r) rangeOfString:@"blocked"].location != NSNotFound, @"a command from the person's blocklist is refused");
        r = call(d, @"screen_info", [NSDictionary dictionary]);
        expectThat(!FAILED(r) && [TEXT(r) rangeOfString:@"screen:"].location != NSNotFound, @"screen_info works when screen control is on");
        r = call(d, @"screen_click", [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:999999], @"x", [NSNumber numberWithInt:5], @"y", nil]);
        expectThat(FAILED(r), @"a click outside the screen is refused");
        r = call(d, @"screen_type", D1(@"caf\u00e9", @"text"));
        expectThat(FAILED(r), @"text that cannot be typed is refused before anything is typed");
        [d close];
        d = start([NSDictionary dictionaryWithObjectsAndKeys:@"0", @"TB_DIFFS", @"0", @"TB_SCREEN", nil]);
        r = call(d, @"edit_block", [NSDictionary dictionaryWithObjectsAndKeys:file, @"file_path", @"2", @"old_string", @"two", @"new_string", nil]);
        expectThat([TEXT(r) rangeOfString:@"@@"].location == NSNotFound, @"no diff when it is off");
        r = call(d, @"screen_info", [NSDictionary dictionary]);
        expectThat(FAILED(r), @"screen tools are refused when screen control is off");
        tools = [[d request:@"tools/list" params:[NSDictionary dictionary] timeout:10] description];
        expectThat([tools rangeOfString:@"screen_click"].location == NSNotFound, @"and are not listed");
        [d close];
    }
    run([NSString stringWithFormat:@"rm -rf %@", dir]);
    [pool release];
    fprintf(stderr, failures ? "%d failed\n" : "all passed\n", failures);
    return failures;
}
