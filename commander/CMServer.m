#import "CMCore.h"
#import "TBJSON.h"
#include <signal.h>
#include <unistd.h>
#include <sys/stat.h>

/* ppc-commander: the MCP server Tiger Build runs for its own chats, and that another computer may run over SSH. It speaks JSON-RPC on
   stdin and stdout, as newline-delimited JSON or with Content-Length headers, whichever the other side uses. */

#define MAX_MESSAGE (16 * 1024 * 1024)

static NSString *marker = nil;

/* one tool: name, description, then (name, type, description) triples, then the required names */
static NSDictionary *def(NSString *name, NSString *description, NSArray *props, NSArray *required)
{
    NSMutableDictionary *properties = [NSMutableDictionary dictionary], *schema;
    unsigned i;
    for (i = 0; i + 2 < [props count]; i += 3) {
        NSString *type = [props objectAtIndex:i + 1];
        NSMutableDictionary *p = [NSMutableDictionary dictionaryWithObject:[props objectAtIndex:i + 2] forKey:@"description"];
        if ([type isEqualToString:@"strings"]) {
            [p setObject:@"array" forKey:@"type"];
            [p setObject:[NSDictionary dictionaryWithObject:@"string" forKey:@"type"] forKey:@"items"];
        } else if ([type length])
            [p setObject:type forKey:@"type"];
        [properties setObject:p forKey:[props objectAtIndex:i]];
    }
    schema = [NSMutableDictionary dictionaryWithObjectsAndKeys:@"object", @"type", properties, @"properties", [NSNumber numberWithBool:YES], @"additionalProperties", nil];
    if ([required count])
        [schema setObject:required forKey:@"required"];
    return [NSDictionary dictionaryWithObjectsAndKeys:name, @"name", description, @"description", schema, @"inputSchema", nil];
}

#define P(...) [NSArray arrayWithObjects:__VA_ARGS__, nil]
#define NONE [NSArray array]

static NSArray *toolDefs(void)
{
    NSString *gitArgs = @"git sub-command and options, one item each", *svnArgs = @"svn sub-command and options, one item each";
    NSMutableArray *t = [NSMutableArray array];
    [t addObject:def(@"take_screenshot", @"Take a screenshot of this Mac's main display and return it as an image, to see what an application or window looks like. It needs someone logged in at the console.",
        P(@"max_width", @"number", @"Widest the picture may be, in pixels. Default 1024."), NONE)];
    [t addObject:def(@"repo_info", @"Say which git repository or Subversion working copy a folder is in, its current state, and whether git and svn are installed. Use it first for any source control question.",
        P(@"path", @"string", @"Folder to look at. Default: the workspace folder or the home folder."), NONE)];
    [t addObject:def(@"git_read", @"Read-only git (status, diff, log, show, blame, listings, grep, rev-parse and similar). Give the sub-command and options as an array, for example [\"log\", \"--oneline\", \"-20\"]. It never changes the repository.",
        P(@"args", @"strings", gitArgs, @"path", @"string", @"Repository folder. Default: the workspace folder.", @"timeout_ms", @"number", @"Time limit, default 60000."), P(@"args"))];
    [t addObject:def(@"git_write", @"git commands that change things (add, commit with -m, checkout, branch, merge, rebase, reset, stash, pull, push, clone, and so on). Force pushes, deleting remote branches, skipping hooks and options that run other programs are refused. Check status and diff with git_read before committing.",
        P(@"args", @"strings", gitArgs, @"path", @"string", @"Repository folder. Default: the workspace folder.", @"timeout_ms", @"number", @"Time limit, default 60000."), P(@"args"))];
    [t addObject:def(@"svn_read", @"Read-only Subversion (status, diff, log, info, list, cat, blame, properties). Give the sub-command and options as an array, for example [\"log\", \"-l\", \"10\"]. It never changes the working copy.",
        P(@"args", @"strings", svnArgs, @"path", @"string", @"Working copy folder. Default: the workspace folder.", @"timeout_ms", @"number", @"Time limit, default 90000."), P(@"args"))];
    [t addObject:def(@"svn_write", @"Subversion commands that change things (add, delete, commit with -m, update, revert, move, copy, checkout, merge, and so on). Passwords on the command line and options that run other programs are refused: use saved credentials.",
        P(@"args", @"strings", svnArgs, @"path", @"string", @"Working copy folder. Default: the workspace folder.", @"timeout_ms", @"number", @"Time limit, default 90000."), P(@"args"))];
    [t addObject:def(@"view_image", @"Look at a picture file on this Mac (JPEG, PNG, GIF, TIFF, BMP, PDF first page, icns). The image is returned for you to see. Use it whenever the person asks about a picture or image file; read_file only returns text.",
        P(@"path", @"string", @"Path of the image file on this Mac", @"max_width", @"number", @"Widest the picture may be, in pixels. Default 1280."), P(@"path"))];
    [t addObject:def(@"get_config", @"Show ppc-commander configuration and what this Mac is running.", NONE, NONE)];
    [t addObject:def(@"set_config_value", @"Set one config key: fileReadLineLimit, fileWriteLineLimit, or telemetryEnabled (stored only; nothing is sent). blockedCommands, allowedDirectories, defaultShell and sudoMode are locked and can only be changed by a person on this Mac.",
        P(@"key", @"string", @"Config key", @"value", @"", @"New value: string, number, boolean, or array of strings"), P(@"key", @"value"))];
    [t addObject:def(@"read_file", @"Read a text file on this Mac. offset is a 0-based line number; negative offset reads from the end (like tail). length defaults to fileReadLineLimit. Also fetches http, https, or ftp URLs. Excel, PDF, and DOCX are not parsed.",
        P(@"path", @"string", @"Filesystem path or URL", @"isUrl", @"boolean", @"Set true to fetch path as a URL", @"offset", @"number", @"0-based line offset; negative means from the end", @"length", @"number", @"Maximum lines to return"), P(@"path"))];
    [t addObject:def(@"read_multiple_files", @"Read up to 20 text files. Each file returns at most 200 lines.", P(@"paths", @"strings", @"Paths on this Mac"), P(@"paths"))];
    [t addObject:def(@"write_file", @"Create or overwrite a text file, or append to it. mode is \"rewrite\" or \"append\". Refuses content larger than fileWriteLineLimit.",
        P(@"path", @"string", @"Destination path", @"content", @"string", @"File bytes as text", @"mode", @"string", @"rewrite (default) or append"), P(@"path", @"content"))];
    [t addObject:def(@"create_directory", @"Create a directory, including parents. Existing directories are fine.", P(@"path", @"string", @"Directory path"), P(@"path"))];
    [t addObject:def(@"list_directory", @"List a directory. depth defaults to 2 and is capped at 6. Listings stop at 500 entries.",
        P(@"path", @"string", @"Directory path", @"depth", @"number", @"How many levels to descend, default 2"), P(@"path"))];
    [t addObject:def(@"move_file", @"Move or rename a file or directory.", P(@"source", @"string", @"Existing path", @"destination", @"string", @"New path"), P(@"source", @"destination"))];
    [t addObject:def(@"get_file_info", @"Stat a file, directory, or symlink.", P(@"path", @"string", @"Path"), P(@"path"))];
    [t addObject:def(@"edit_block", @"Replace an exact snippet in a text file. old_string must match the file exactly expected_replacements times (default 1). Newlines are retried in normalized form if needed. Excel ranges are not supported.",
        P(@"file_path", @"string", @"File to edit", @"old_string", @"string", @"Exact text to replace", @"new_string", @"string", @"Replacement text; empty deletes the match", @"expected_replacements", @"number", @"How many matches to replace, default 1"),
        P(@"file_path", @"old_string", @"new_string"))];
    [t addObject:def(@"start_search", @"Search this Mac. searchType \"files\" matches names (glob if the pattern has * ? or [, otherwise a substring). searchType \"content\" uses a regular expression unless literalSearch is true. There is no ripgrep. Returns a sessionId for later pages.",
        P(@"path", @"string", @"File or directory to search", @"pattern", @"string", @"Name substring/glob, or content regex", @"searchType", @"string", @"files (default) or content",
          @"filePattern", @"string", @"Optional filename glob for content search", @"ignoreCase", @"boolean", @"Default true", @"maxResults", @"number", @"Stop after this many matches, default 200",
          @"includeHidden", @"boolean", @"Descend into dotfiles, default false", @"contextLines", @"number", @"Context lines around a content match, max 5",
          @"timeout_ms", @"number", @"Search budget, default 15000, max 60000", @"earlyTermination", @"boolean", @"Stop files search on an exact basename match",
          @"literalSearch", @"boolean", @"Treat a content pattern as plain text"), P(@"path", @"pattern"))];
    [t addObject:def(@"get_more_search_results", @"Read another page of a search started by start_search.",
        P(@"sessionId", @"string", @"sessionId from start_search", @"offset", @"number", @"0-based result offset", @"length", @"number", @"How many results, default 100"), P(@"sessionId"))];
    [t addObject:def(@"stop_search", @"Stop a running search.", P(@"sessionId", @"string", @"sessionId from start_search"), P(@"sessionId"))];
    [t addObject:def(@"list_searches", @"List search sessions started in this server process.", NONE, NONE)];
    [t addObject:def(@"start_process", @"Run a shell command on this Mac under bash -c, on a pseudo-terminal. Returns when the process exits, when output has been idle for about 0.4s, or when timeout_ms elapses (capped at 120000). The process keeps running after a timeout. Set detach true for a GUI or anything that should keep running after this call: it is started in its own session, with no terminal, and closing the chat does not stop it. Use open for a Mac .app. sudo works only when a person has turned administrator mode on for this Mac; then just write sudo in the command (not with detach). Include a trailing newline yourself when talking to an interactive program later.",
        P(@"command", @"string", @"Shell command", @"timeout_ms", @"number", @"How long to wait for the first output", @"shell", @"string", @"Optional shell path, default /bin/bash",
          @"detach", @"boolean", @"Start outside this chat so a GUI can keep running"), P(@"command", @"timeout_ms"))];
    [t addObject:def(@"interact_with_process", @"Write input to a process started by start_process. The bytes are sent as-is; include the newline if the program expects Enter.",
        P(@"pid", @"number", @"pid from start_process", @"input", @"string", @"Bytes to write", @"timeout_ms", @"number", @"How long to wait for new output"), P(@"pid", @"input"))];
    [t addObject:def(@"read_process_output", @"Read captured output. Omit offset (or pass 0) for lines since the last read. A positive offset is a 1-based absolute line. A negative offset reads from the end.",
        P(@"pid", @"number", @"pid from start_process", @"timeout_ms", @"number", @"Wait this long for more output first", @"offset", @"number", @"0 = new output, positive = 1-based line, negative = tail",
          @"length", @"number", @"Maximum lines"), P(@"pid"))];
    [t addObject:def(@"force_terminate", @"SIGKILL a process started by start_process.", P(@"pid", @"number", @"pid from start_process"), P(@"pid"))];
    [t addObject:def(@"list_sessions", @"List terminal sessions started by this server.", NONE, NONE)];
    [t addObject:def(@"list_processes", @"Run ps auxww on this Mac.", NONE, NONE)];
    [t addObject:def(@"kill_process", @"Send SIGTERM to any pid this user may signal. Refuses pid 1 and this server.", P(@"pid", @"number", @"Process id"), P(@"pid"))];
    [t addObject:def(@"get_usage_stats", @"Local counts of tool calls made to this server. Nothing is uploaded.", NONE, NONE)];
    [t addObject:def(@"get_recent_tool_calls", @"Recent local tool-call history with truncated arguments and output.",
        P(@"maxResults", @"number", @"How many calls, default 20, max 100", @"toolName", @"string", @"Optional tool name filter", @"since", @"string", @"Optional ISO timestamp; return calls at or after it"), NONE)];
    if (CMConvertAvailable())
        [t addObject:def(@"convert_file", @"Read a file this Mac cannot open by itself, with Tiger Build's converter: Word, Excel and PowerPoint (also the old .doc .xls .ppt), OpenDocument, Pages, Keynote and Numbers files give their text; HEIC, AVIF, WebP, JPEG XL, GIF, TIFF and other pictures give an upright JPEG you can look at. Returns the text and, when there is one, the first picture.",
            P(@"path", @"string", @"The file on this Mac"), P(@"path"))];
    if (CMScreenEnabled()) {
        NSString *where = @"Coordinates are pixels of the picture from the last take_screenshot (or screen points if none was taken). Take a screenshot first, act, then take another to see the result.";
        [t addObject:def(@"screen_info", @"Screen size, mouse position and the coordinate scale for the other screen_* tools.", NONE, NONE)];
        [t addObject:def(@"screen_click", [@"Click the mouse on the screen. " stringByAppendingString:where],
            P(@"x", @"number", @"Across", @"y", @"number", @"Down", @"button", @"string", @"left (default) or right", @"clicks", @"number", @"1 (default), 2 or 3"), P(@"x", @"y"))];
        [t addObject:def(@"screen_move", [@"Move the mouse pointer. " stringByAppendingString:where], P(@"x", @"number", @"Across", @"y", @"number", @"Down"), P(@"x", @"y"))];
        [t addObject:def(@"screen_drag", [@"Press at x,y, drag to to_x,to_y and release. " stringByAppendingString:where],
            P(@"x", @"number", @"Start across", @"y", @"number", @"Start down", @"to_x", @"number", @"End across", @"to_y", @"number", @"End down"), P(@"x", @"y", @"to_x", @"to_y"))];
        [t addObject:def(@"screen_scroll", @"Scroll with the mouse wheel, optionally after moving the pointer to x,y. Positive scrolls up.",
            P(@"amount", @"number", @"Lines, -50 to 50", @"x", @"number", @"Optional across", @"y", @"number", @"Optional down"), P(@"amount"))];
        [t addObject:def(@"screen_type", @"Type text into whatever has the keyboard focus (US keyboard characters only).", P(@"text", @"string", @"Up to 2000 characters"), P(@"text"))];
        [t addObject:def(@"screen_key", @"Press one key, with optional modifiers, in whatever has the keyboard focus, for example key \"w\" with modifiers [\"cmd\"].",
            P(@"key", @"string", @"One character, or return, tab, space, delete, escape, left, right, up, down, home, end, pageup, pagedown, forwarddelete, f1 to f12", @"modifiers", @"strings", @"cmd, shift, option, control"), P(@"key"))];
    }
    return t;
}

static id callHandler(NSString *name, NSDictionary *a)
{
    if ([name hasPrefix:@"screen_"]) {
        if (!CMScreenEnabled())
            CMFail(@"screen control is off. A person can turn it on in Tiger Build: the Tools menu of the chat, Screen control.");
        if ([name isEqualToString:@"screen_info"]) return CMToolScreenInfo(a);
        if ([name isEqualToString:@"screen_click"]) return CMToolScreenClick(a);
        if ([name isEqualToString:@"screen_move"]) return CMToolScreenMove(a);
        if ([name isEqualToString:@"screen_drag"]) return CMToolScreenDrag(a);
        if ([name isEqualToString:@"screen_scroll"]) return CMToolScreenScroll(a);
        if ([name isEqualToString:@"screen_type"]) return CMToolScreenType(a);
        if ([name isEqualToString:@"screen_key"]) return CMToolScreenKey(a);
    }
    if ([name isEqualToString:@"get_config"]) return CMToolGetConfig(a);
    if ([name isEqualToString:@"set_config_value"]) return CMToolSetConfig(a);
    if ([name isEqualToString:@"read_file"]) return CMToolReadFile(a);
    if ([name isEqualToString:@"read_multiple_files"]) return CMToolReadMultiple(a);
    if ([name isEqualToString:@"write_file"]) return CMToolWriteFile(a);
    if ([name isEqualToString:@"create_directory"]) return CMToolCreateDirectory(a);
    if ([name isEqualToString:@"list_directory"]) return CMToolListDirectory(a);
    if ([name isEqualToString:@"move_file"]) return CMToolMoveFile(a);
    if ([name isEqualToString:@"get_file_info"]) return CMToolFileInfo(a);
    if ([name isEqualToString:@"edit_block"]) return CMToolEditBlock(a);
    if ([name isEqualToString:@"start_search"]) return CMToolStartSearch(a);
    if ([name isEqualToString:@"get_more_search_results"]) return CMToolMoreSearch(a);
    if ([name isEqualToString:@"stop_search"]) return CMToolStopSearch(a);
    if ([name isEqualToString:@"list_searches"]) return CMToolListSearches(a);
    if ([name isEqualToString:@"start_process"]) return CMToolStartProcess(a);
    if ([name isEqualToString:@"interact_with_process"]) return CMToolInteract(a);
    if ([name isEqualToString:@"read_process_output"]) return CMToolReadOutput(a);
    if ([name isEqualToString:@"force_terminate"]) return CMToolForceTerminate(a);
    if ([name isEqualToString:@"list_sessions"]) return CMToolListSessions(a);
    if ([name isEqualToString:@"list_processes"]) return CMToolListProcesses(a);
    if ([name isEqualToString:@"kill_process"]) return CMToolKillProcess(a);
    if ([name isEqualToString:@"take_screenshot"]) return CMToolScreenshot(a);
    if ([name isEqualToString:@"view_image"]) return CMToolViewImage(a);
    if ([name isEqualToString:@"convert_file"]) return CMToolConvert(a);
    if ([name isEqualToString:@"repo_info"]) return CMToolRepoInfo(a);
    if ([name isEqualToString:@"git_read"]) return CMToolGit(a, NO);
    if ([name isEqualToString:@"git_write"]) return CMToolGit(a, YES);
    if ([name isEqualToString:@"svn_read"]) return CMToolSvn(a, NO);
    if ([name isEqualToString:@"svn_write"]) return CMToolSvn(a, YES);
    if ([name isEqualToString:@"get_usage_stats"]) return CMToolUsage(a);
    if ([name isEqualToString:@"get_recent_tool_calls"]) return CMToolRecent(a);
    CMFail(@"unknown tool %@", name);
    return nil;
}

static NSDictionary *callTool(id params)
{
    NSDictionary *args = nil;
    NSString *name, *text = nil;
    id result = nil, image = nil;
    BOOL ok = YES;
    NSDate *started = [NSDate date];
    NSMutableArray *content = [NSMutableArray array];
    if (![params isKindOfClass:[NSDictionary class]])
        CMFail(@"invalid params");
    name = [params objectForKey:@"name"];
    if (![name isKindOfClass:[NSString class]])
        CMFail(@"tool name missing");
    args = [params objectForKey:@"arguments"];
    if ([args isKindOfClass:[NSString class]])
        args = TBJSONParseString((NSString *)args, NULL);
    if (args == nil || args == (id)[NSNull null])
        args = [NSDictionary dictionary];
    if (![args isKindOfClass:[NSDictionary class]])
        CMFail(@"arguments must be an object");
    @try {
        result = callHandler(name, args);
        if ([result isKindOfClass:[NSDictionary class]]) {
            image = result;
            text = [result objectForKey:@"text"];
        } else
            text = result;
        if (![text isKindOfClass:[NSString class]])
            text = [text description] ? [text description] : @"";
    } @catch (NSException *e) {
        text = [@"error: " stringByAppendingString:[e reason] ? [e reason] : [e name]];
        ok = NO;
        image = nil;
    }
    CMRecord(name, args, text, ok, (int)(-[started timeIntervalSinceNow] * 1000));
    if (image)
        [content addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"image", @"type", [image objectForKey:@"image"], @"data", [image objectForKey:@"mime"], @"mimeType", nil]];
    [content addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"text", @"type", text, @"text", nil]];
    return [NSDictionary dictionaryWithObjectsAndKeys:content, @"content", [NSNumber numberWithBool:!ok], @"isError", nil];
}

static NSDictionary *rpc(id mid, NSString *key, id value)
{
    return [NSDictionary dictionaryWithObjectsAndKeys:@"2.0", @"jsonrpc", mid ? mid : [NSNull null], @"id", value, key, nil];
}

static NSDictionary *rpcError(id mid, int code, NSString *message)
{
    return rpc(mid, @"error", [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:code], @"code", message, @"message", nil]);
}

static NSDictionary *dispatch(id msg)
{
    NSString *method;
    id mid, params;
    if (![msg isKindOfClass:[NSDictionary class]])
        return rpcError(nil, -32600, @"invalid request");
    method = [msg objectForKey:@"method"];
    if (![method isKindOfClass:[NSString class]])
        method = @"";
    mid = [msg objectForKey:@"id"];
    if ([method isEqualToString:@"tb/sudo-key"] && [[msg objectForKey:@"params"] isKindOfClass:[NSDictionary class]]) {
        id key = [[msg objectForKey:@"params"] objectForKey:@"key"];
        if ([key isKindOfClass:[NSString class]] && [key length] < 200)
            CMSetSudoKey(key);
        return nil;
    }
    if ([method hasPrefix:@"notifications/"] || [method isEqualToString:@"initialized"] || mid == nil)
        return nil;
    params = [msg objectForKey:@"params"];
    if (![params isKindOfClass:[NSDictionary class]])
        params = [NSDictionary dictionary];
    @try {
        if ([method isEqualToString:@"initialize"]) {
            NSString *version = [params objectForKey:@"protocolVersion"];
            if (![version isKindOfClass:[NSString class]])
                version = @"2024-11-05";
            return rpc(mid, @"result", [NSDictionary dictionaryWithObjectsAndKeys:version, @"protocolVersion",
                [NSDictionary dictionaryWithObject:[NSDictionary dictionaryWithObject:[NSNumber numberWithBool:NO] forKey:@"listChanged"] forKey:@"tools"], @"capabilities",
                [NSDictionary dictionaryWithObjectsAndKeys:@"ppc-commander", @"name", CM_VERSION, @"version", nil], @"serverInfo",
                CMInstructions(), @"instructions", nil]);
        }
        if ([method isEqualToString:@"ping"] || [method isEqualToString:@"logging/setLevel"])
            return rpc(mid, @"result", [NSDictionary dictionary]);
        if ([method isEqualToString:@"tools/list"])
            return rpc(mid, @"result", [NSDictionary dictionaryWithObject:toolDefs() forKey:@"tools"]);
        if ([method isEqualToString:@"tools/call"])
            return rpc(mid, @"result", callTool(params));
        if ([method isEqualToString:@"resources/list"])
            return rpc(mid, @"result", [NSDictionary dictionaryWithObject:[NSArray array] forKey:@"resources"]);
        if ([method isEqualToString:@"resources/templates/list"])
            return rpc(mid, @"result", [NSDictionary dictionaryWithObject:[NSArray array] forKey:@"resourceTemplates"]);
        if ([method isEqualToString:@"prompts/list"])
            return rpc(mid, @"result", [NSDictionary dictionaryWithObject:[NSArray array] forKey:@"prompts"]);
        return rpcError(mid, -32601, [@"method not found: " stringByAppendingString:method]);
    } @catch (NSException *e) {
        return rpcError(mid, -32602, [e reason] ? [e reason] : [e name]);
    }
    return nil;
}

/* ---- framing ---- */

static NSData *readLine(void)
{
    NSMutableData *line = [NSMutableData data];
    char c;
    ssize_t n;
    for (;;) {
        n = read(0, &c, 1);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            return [line length] ? line : nil;
        if (c == '\n')
            return line;
        [line appendBytes:&c length:1];
    }
}

static NSData *readExact(unsigned count)
{
    NSMutableData *body = [NSMutableData dataWithLength:count];
    unsigned done = 0;
    while (done < count) {
        ssize_t n = read(0, (char *)[body mutableBytes] + done, count - done);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            return nil;
        done += n;
    }
    return body;
}

static void writeAll(NSData *data)
{
    const char *p = [data bytes];
    unsigned left = [data length];
    while (left) {
        ssize_t n = write(1, p, left);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0) {
            CMShutdownSessions();
            if (marker)
                unlink([marker fileSystemRepresentation]);
            _exit(0);
        }
        p += n;
        left -= n;
    }
}

static void send(id obj, BOOL framed)
{
    NSData *body = TBJSONData(obj);
    NSMutableData *out = [NSMutableData data];
    if (framed)
        [out appendData:[[NSString stringWithFormat:@"Content-Length: %u\r\n\r\n", (unsigned)[body length]] dataUsingEncoding:NSASCIIStringEncoding]];
    [out appendData:body];
    if (!framed)
        [out appendBytes:"\n" length:1];
    writeAll(out);
}

static void serve(void)
{
    for (;;) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        NSData *line = readLine();
        NSString *text, *error = nil;
        id msg;
        BOOL framed = NO;
        if (!line) {
            [pool release];
            break;
        }
        text = [[[NSString alloc] initWithData:line encoding:NSUTF8StringEncoding] autorelease];
        if (!text)
            text = [[[NSString alloc] initWithData:line encoding:NSISOLatin1StringEncoding] autorelease];
        text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (![text length]) {
            [pool release];
            continue;
        }
        if ([[text lowercaseString] hasPrefix:@"content-length:"]) {
            int length = -1;
            NSString *current = text;
            NSData *body;
            framed = YES;
            for (;;) {
                if ([current length]) {
                    NSRange colon = [current rangeOfString:@":"];
                    if (colon.location != NSNotFound && [[[[current substringToIndex:colon.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString] isEqualToString:@"content-length"])
                        length = [[current substringFromIndex:colon.location + 1] intValue];
                } else
                    break;
                line = readLine();
                if (!line)
                    break;
                current = [[[[NSString alloc] initWithData:line encoding:NSUTF8StringEncoding] autorelease] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (!current)
                    current = @"";
            }
            if (length < 0 || length > MAX_MESSAGE || !(body = readExact(length))) {
                send(rpcError(nil, -32700, @"parse error: bad Content-Length message"), NO);
                [pool release];
                continue;
            }
            msg = TBJSONParse(body, &error);
        } else
            msg = TBJSONParseString(text, &error);
        if (!msg)
            send(rpcError(nil, -32700, [@"parse error: " stringByAppendingString:error ? error : @"invalid JSON"]), framed);
        else {
            NSDictionary *reply = dispatch(msg);
            if (reply)
                send(reply, framed);
        }
        [pool release];
    }
    CMShutdownSessions();
}

static void stopped(int sig)
{
    CMShutdownSessions();
    if (marker)
        unlink([marker fileSystemRepresentation]);
    _exit(0);
}

static int sudoCommand(NSArray *words)
{
    NSString *action = [words count] ? [words objectAtIndex:0] : @"status";
    if (![[NSArray arrayWithObjects:@"on", @"off", @"remote-on", @"remote-off", @"status", nil] containsObject:action]) {
        fprintf(stderr, "usage: ppc-commander --sudo on|off|remote-on|remote-off|status\n");
        return 2;
    }
    if (![action isEqualToString:@"status"]) {
        NSMutableDictionary *c = (NSMutableDictionary *)CMConfig();
        BOOL remote = [action hasPrefix:@"remote-"];
        [c setObject:[NSNumber numberWithBool:[action hasSuffix:@"on"]] forKey:remote ? @"remoteSudo" : @"sudoMode"];
        CMSaveConfig();
        CMLoadSettings();
    }
    if (CMPolicyAllowsSudo() && [[CMConfig() objectForKey:[action hasPrefix:@"remote-"] ? @"remoteSudo" : @"sudoMode"] boolValue])
        printf("on\n");
    else {
        printf("off\n");
        if ([action hasSuffix:@"on"] && !CMPolicyAllowsSudo())
            printf("a policy file (%s) keeps administrator mode off on this Mac\n", [CMPolicyPath() UTF8String]);
    }
    return 0;
}

/* Tiger Build starts Commander for its own chats with TB_LOCAL=1. Anything else is another computer arriving over SSH, which is
   refused unless a person turned remote access on (the file remote-access in the state folder). */
static BOOL fromAnotherComputer(void)
{
    return getenv("TB_LOCAL") == NULL || strcmp(getenv("TB_LOCAL"), "1") != 0;
}

int main(int argc, char **argv)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *state;
    chdir([NSHomeDirectory() fileSystemRepresentation]);
    CMLoadSettings();
    if (argc > 1 && strcmp(argv[1], "--sudo") == 0) {
        NSMutableArray *rest = [NSMutableArray array];
        int i;
        for (i = 2; i < argc; i++)
            [rest addObject:[NSString stringWithUTF8String:argv[i]]];
        return sudoCommand(rest);
    }
    if (argc > 1 && strcmp(argv[1], "--version") == 0) {
        printf("ppc-commander %s\n", [CM_VERSION UTF8String]);
        return 0;
    }
    state = CMStateFolder();
    if ([fm fileExistsAtPath:[state stringByAppendingPathComponent:@"disabled"]]) {
        CMLog(@"Commander is stopped. Choose Commander > Start in Tiger Build.");
        return 1;
    }
    if (fromAnotherComputer() && ![fm fileExistsAtPath:[state stringByAppendingPathComponent:@"remote-access"]]) {
        CMLog(@"Other computers may not use Commander on this Mac. Turn on Commander > Allow Other Computers in Tiger Build here first.");
        return 1;
    }
    marker = [[state stringByAppendingPathComponent:[NSString stringWithFormat:@"session-%d", (int)getpid()]] retain];
    [@"session" writeToFile:marker atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    signal(SIGTERM, stopped);
    signal(SIGINT, stopped);
    signal(SIGPIPE, SIG_IGN);
    CMLog(@"ready pid=%d %@%@", (int)getpid(), CMSystemInfo(@"uname"), fromAnotherComputer() ? @" (remote)" : @"");
    serve();
    unlink([marker fileSystemRepresentation]);
    [pool release];
    return 0;
}
