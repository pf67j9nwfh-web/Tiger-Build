#import "TBCLIApp.h"
#import "TBEngine.h"
#import "TBJSON.h"
#include <unistd.h>
#include <string.h>
#include <fnmatch.h>
#include <sys/stat.h>
#include <dirent.h>

static NSString *kVersion = @"2.8";

/* ---- what a tool does, for deciding whether to ask ---- */

static NSString *toolKind(NSString *name)
{
    static NSSet *reads = nil, *edits = nil;
    if (!reads) {
        reads = [[NSSet setWithObjects:@"view_image", @"repo_info", @"git_read", @"svn_read", @"get_config", @"read_file", @"read_multiple_files", @"list_directory", @"get_file_info",
            @"start_search", @"get_more_search_results", @"stop_search", @"list_searches", @"read_process_output", @"list_sessions", @"list_processes", @"get_usage_stats",
            @"get_recent_tool_calls", @"screen_info", nil] retain];
        edits = [[NSSet setWithObjects:@"write_file", @"create_directory", @"move_file", @"edit_block", @"git_write", @"svn_write", @"set_config_value", @"convert_file", nil] retain];
    }
    if ([reads containsObject:name])
        return @"read";
    if ([edits containsObject:name])
        return @"edit";
    if ([name isEqualToString:@"start_process"] || [name isEqualToString:@"interact_with_process"] || [name isEqualToString:@"force_terminate"] || [name isEqualToString:@"kill_process"])
        return @"exec";
    return @"other";
}

@implementation TBCLIApp

- (NSString *)cliDir
{
    NSString *dir = [TBCLISupportDir() stringByAppendingPathComponent:@"cli"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir attributes:nil];
    return dir;
}

- (id)initWithCore:(TBCLICore *)c
{
    NSString *text;
    self = [super init];
    core = c;
    term = [TBTerm term];
    config = [[NSMutableDictionary alloc] initWithContentsOfFile:[[self cliDir] stringByAppendingPathComponent:@"config.plist"]];
    if (!config)
        config = [[NSMutableDictionary alloc] init];
    editor = [[TBLineEditor alloc] initWithTerm:term historyPath:[[self cliDir] stringByAppendingPathComponent:@"history"]];
    [editor setDelegate:self];
    md = [[TBMarkdown alloc] initWithTerm:term margin:@"  " target:self action:@selector(mdLine:)];
    typed = [[NSMutableString alloc] init];
    thinkBuffer = [[NSMutableString alloc] init];
    shellNotes = [[NSMutableArray alloc] init];
    toolStarts = [[NSMutableDictionary alloc] init];
    verbose = [[config objectForKey:@"verbose"] boolValue];
    showThinking = [config objectForKey:@"showThinking"] ? [[config objectForKey:@"showThinking"] boolValue] : NO;
    bell = [config objectForKey:@"bell"] ? [[config objectForKey:@"bell"] boolValue] : YES;
    allowRules = [[config objectForKey:@"allow"] retain];
    denyRules = [[config objectForKey:@"deny"] retain];
    text = [self configString:@"mode" default:@"ask"];
    [core setPermissionMode:text];
    [core setEvents:self];
    return self;
}

- (NSString *)configString:(NSString *)key default:(NSString *)value
{
    NSString *v = [config objectForKey:key];
    return [v isKindOfClass:[NSString class]] && [v length] ? v : value;
}

- (void)saveConfig
{
    [config writeToFile:[[self cliDir] stringByAppendingPathComponent:@"config.plist"] atomically:YES];
}

/* ---- output above the prompt ---- */

- (void)clearLive
{
    if (liveShown) {
        [term write:@"\r\033[2K"];
        liveShown = NO;
    }
}

- (NSString *)spinnerGlyph
{
    static NSString *frames[] = {@"⠋", @"⠙", @"⠹", @"⠸", @"⠼", @"⠴", @"⠦", @"⠧", @"⠇", @"⠏"};
    if (![term unicode])
        return @"*";
    return frames[spinFrame % 10];
}

- (void)drawLive
{
    NSString *line;
    int cols;
    if (!working)
        return;
    cols = [term columns];
    line = [NSString stringWithFormat:@"%@ %@ %ds  esc to stop%@%@", [term styled:[self spinnerGlyph] with:@"orange"], spinLabel ? spinLabel : @"Working", (int)(CFAbsoluteTimeGetCurrent() - spinStart),
        [typed length] ? @"  › " : @"", typed];
    [term write:@"\r\033[2K"];
    [term write:[term clipToWidth:line width:cols]];
    liveShown = YES;
    [term flush];
}

- (void)emit:(NSString *)text
{
    [self clearLive];
    [term write:[[text componentsSeparatedByString:@"\n"] componentsJoinedByString:@"\r\n"]];
    [self drawLive];
    [term flush];
}

- (void)printLine:(NSString *)text { [self emit:[text stringByAppendingString:@"\n"]]; }
- (void)printStyled:(NSString *)text style:(NSString *)style { [self printLine:[term styled:text with:style]]; }

- (void)mdLine:(NSString *)text
{
    if (firstLine) {
        firstLine = NO;
        if ([text hasPrefix:@"  "])
            text = [NSString stringWithFormat:@"%@ %@", [term styled:[term unicode] ? @"●" : @"*" with:@"orange"], [text substringFromIndex:2]];
    }
    [self emit:text];
}

/* ---- the banner and the prompt ---- */

- (NSString *)modelLabel:(NSDictionary *)chat
{
    NSString *provider = [core providerForChat:chat], *model = [core modelForChat:chat];
    NSString *title = [[ModelCatalog shared] titleForProvider:provider];
    NSArray *list = [core modelsForProvider:provider];
    unsigned i;
    for (i = 0; i < [list count]; i++)
        if ([[[list objectAtIndex:i] objectForKey:@"id"] isEqualToString:model])
            return [NSString stringWithFormat:@"%@ %@", title ? title : provider, [[list objectAtIndex:i] objectForKey:@"title"] ? [[list objectAtIndex:i] objectForKey:@"title"] : model];
    return [NSString stringWithFormat:@"%@ %@", title ? title : provider, model];
}

- (NSString *)costText:(NSDictionary *)chat
{
    NSDictionary *usage = [chat objectForKey:@"usage"];
    NSEnumerator *keys = [usage keyEnumerator];
    NSString *key;
    double cost = 0;
    int priced = 0;
    while ((key = [keys nextObject])) {
        NSDictionary *row = [usage objectForKey:key];
        if ([row objectForKey:@"cost"]) {
            cost += [[row objectForKey:@"cost"] doubleValue];
            priced++;
        }
    }
    if (!priced)
        return nil;
    return cost < 0.01 ? [NSString stringWithFormat:@"$%.4f", cost] : [NSString stringWithFormat:@"$%.2f", cost];
}

- (NSString *)tokenText:(int)n
{
    if (n >= 1000000)
        return [NSString stringWithFormat:@"%.1fm", n / 1000000.0];
    if (n >= 1000)
        return [NSString stringWithFormat:@"%.1fk", n / 1000.0];
    return [NSString stringWithFormat:@"%d", n];
}

- (NSString *)statusLine
{
    NSMutableDictionary *chat = [core currentChat];
    NSString *cost = chat ? [self costText:chat] : nil;
    int used = chat ? [core contextTokensForChat:chat] : 0;
    NSString *mode = [core permissionMode];
    NSMutableArray *parts = [NSMutableArray array];
    if (chat)
        [parts addObject:[self modelLabel:chat]];
    [parts addObject:[NSString stringWithFormat:@"%@ mode", mode]];
    if (used > 0)
        [parts addObject:[NSString stringWithFormat:@"%@ tokens", [self tokenText:used]]];
    if (cost)
        [parts addObject:cost];
    return [parts componentsJoinedByString:@" · "];
}

- (NSString *)promptText
{
    return [NSString stringWithFormat:@"%@ ", [term styled:[term unicode] ? @"❯" : @">" with:@"cyan"]];
}

- (void)banner
{
    NSMutableDictionary *chat = [core currentChat];
    NSString *cwd = [[NSFileManager defaultManager] currentDirectoryPath];
    NSString *home = NSHomeDirectory();
    if ([cwd hasPrefix:home])
        cwd = [@"~" stringByAppendingString:[cwd substringFromIndex:[home length]]];
    [term write:[NSString stringWithFormat:@"\r\n %@ %@\r\n", [term styled:@"Tiger Build" with:@"bold"], [term styled:[NSString stringWithFormat:@"%@ · terminal", kVersion] with:@"gray"]]];
    if (chat)
        [term write:[NSString stringWithFormat:@" %@\r\n", [term styled:[NSString stringWithFormat:@"%@ · chat %@ “%@” · %@", [self modelLabel:chat], [chat objectForKey:@"id"], [core titleOf:chat], cwd] with:@"gray"]]];
    [term write:[NSString stringWithFormat:@" %@\r\n\r\n", [term styled:@"/help for commands · @ mentions a file · ! runs a command · Esc stops a reply · Shift-Tab changes the mode" with:@"gray"]]];
    [term flush];
}

/* ---- instructions from files in the project ---- */

- (void)loadProjectInstructions
{
    NSMutableString *all = [NSMutableString string];
    NSMutableArray *found = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [fm currentDirectoryPath], *home = NSHomeDirectory();
    NSArray *names = [NSArray arrayWithObjects:@"TIGERBUILD.md", @"AGENTS.md", @"CLAUDE.md", nil];
    NSMutableArray *dirs = [NSMutableArray array];
    unsigned i, j;
    while ([dir length] > 1) {
        [dirs insertObject:dir atIndex:0];
        if ([dir isEqualToString:home])
            break;
        dir = [dir stringByDeletingLastPathComponent];
    }
    for (i = 0; i < [dirs count]; i++)
        for (j = 0; j < [names count]; j++) {
            NSString *path = [[dirs objectAtIndex:i] stringByAppendingPathComponent:[names objectAtIndex:j]];
            NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
            if ([text length]) {
                [found addObject:path];
                [all appendFormat:@"Instructions from %@:\n%@\n\n", path, [text length] > 30000 ? [text substringToIndex:30000] : text];
                break;   /* one file per folder */
            }
        }
    {
        NSString *user = [NSString stringWithContentsOfFile:[[self cliDir] stringByAppendingPathComponent:@"TIGERBUILD.md"] encoding:NSUTF8StringEncoding error:NULL];
        if ([user length]) {
            [found insertObject:@"(your own TIGERBUILD.md)" atIndex:0];
            [all insertString:[NSString stringWithFormat:@"Instructions from the person (all projects):\n%@\n\n", user] atIndex:0];
        }
    }
    [projectNote release];
    projectNote = [found count] ? [[found componentsJoinedByString:@", "] copy] : nil;
    [self applyInstructions:all];
}

- (void)applyInstructions:(NSString *)files
{
    NSMutableString *text = [NSMutableString string];
    NSString *mode = [core permissionMode];
    [text appendFormat:@"The person is using Tiger Build's terminal program (tb). The working directory is %@.\n\n", [[NSFileManager defaultManager] currentDirectoryPath]];
    if ([mode isEqualToString:@"plan"])
        [text appendString:@"PLAN MODE: do not change anything. You may read files and search, but do not write, edit, move or delete files, and do not run commands that change anything. "
            @"Investigate, then give a short numbered plan of what you would do and stop; the person approves it before anything is changed.\n\n"];
    if ([files length])
        [text appendString:files];
    [core setExtraInstructions:text];
}

- (void)refreshInstructions
{
    [self loadProjectInstructions];
}

/* ---- @file mentions ---- */

- (NSString *)expandMentions:(NSString *)text
{
    NSMutableString *flat = [NSMutableString stringWithString:text];
    NSArray *words;
    NSMutableString *extra = [NSMutableString string];
    NSMutableSet *done = [NSMutableSet set];
    NSFileManager *fm = [NSFileManager defaultManager];
    unsigned i;
    int total = 0;
    [flat replaceOccurrencesOfString:@"\n" withString:@" " options:0 range:NSMakeRange(0, [flat length])];
    [flat replaceOccurrencesOfString:@"\t" withString:@" " options:0 range:NSMakeRange(0, [flat length])];
    words = [flat componentsSeparatedByString:@" "];
    for (i = 0; i < [words count]; i++) {
        NSString *w = [words objectAtIndex:i], *path, *full;
        BOOL isDir = NO;
        if ([w length] < 2 || ![w hasPrefix:@"@"])
            continue;
        path = [w substringFromIndex:1];
        while ([path length] && [[NSCharacterSet characterSetWithCharactersInString:@",.;:)"] characterIsMember:[path characterAtIndex:[path length] - 1]] && ![fm fileExistsAtPath:[path stringByExpandingTildeInPath]])
            path = [path substringToIndex:[path length] - 1];
        full = [path stringByExpandingTildeInPath];
        if (![full isAbsolutePath])
            full = [[fm currentDirectoryPath] stringByAppendingPathComponent:full];
        if ([done containsObject:full] || ![fm fileExistsAtPath:full isDirectory:&isDir])
            continue;
        [done addObject:full];
        if (isDir) {
            NSArray *items = [[fm directoryContentsAtPath:full] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
            NSMutableString *list = [NSMutableString string];
            unsigned k;
            for (k = 0; k < [items count] && k < 200; k++) {
                BOOL d2 = NO;
                [fm fileExistsAtPath:[full stringByAppendingPathComponent:[items objectAtIndex:k]] isDirectory:&d2];
                [list appendFormat:@"%@%@\n", [items objectAtIndex:k], d2 ? @"/" : @""];
            }
            [extra appendFormat:@"\n\n--- folder %@ ---\n%@", full, list];
        } else {
            NSData *data = [NSData dataWithContentsOfFile:full];
            NSString *content = data ? [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease] : nil;
            if (!content) {
                [extra appendFormat:@"\n\n--- file %@ (%lu bytes, not text; use the tools to look at it) ---", full, (unsigned long)[data length]];
                continue;
            }
            if ([content length] > 60000)
                content = [[content substringToIndex:60000] stringByAppendingString:@"\n... (cut at 60,000 characters)"];
            total += (int)[content length];
            if (total > 200000)
                break;
            [extra appendFormat:@"\n\n--- file %@ ---\n```\n%@\n```", full, content];
        }
    }
    return [extra length] ? [text stringByAppendingString:extra] : text;
}

/* ---- Tab completion ---- */

- (NSArray *)editor:(TBLineEditor *)e completionsFor:(NSString *)line cursor:(int)cursor start:(int *)start
{
    NSString *before = [line substringToIndex:cursor];
    NSRange sp = [before rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet] options:NSBackwardsSearch];
    int wordAt = sp.location == NSNotFound ? 0 : (int)sp.location + 1;
    NSString *word = [before substringFromIndex:wordAt];
    NSMutableArray *out = [NSMutableArray array];
    unsigned i;
    *start = wordAt;
    if (wordAt == 0 && [word hasPrefix:@"/"]) {
        NSArray *names = [self commandNames];
        for (i = 0; i < [names count]; i++)
            if ([[names objectAtIndex:i] hasPrefix:word])
                [out addObject:[names objectAtIndex:i]];
        return out;
    }
    if ([word hasPrefix:@"@"]) {
        NSString *partial = [word substringFromIndex:1], *dirPart = [partial stringByDeletingLastPathComponent], *namePart = [partial lastPathComponent];
        NSString *dir = [dirPart length] ? [dirPart stringByExpandingTildeInPath] : @".";
        NSArray *items;
        if ([partial hasSuffix:@"/"]) { dirPart = [partial substringToIndex:[partial length] - 1]; namePart = @""; dir = [dirPart length] ? [dirPart stringByExpandingTildeInPath] : @"/"; }
        if (![dir isAbsolutePath])
            dir = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:dir];
        items = [[NSFileManager defaultManager] directoryContentsAtPath:dir];
        items = [items sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
        for (i = 0; i < [items count] && [out count] < 100; i++) {
            NSString *n = [items objectAtIndex:i];
            BOOL d = NO;
            if ([n hasPrefix:@"."] && ![namePart hasPrefix:@"."])
                continue;
            if (![n hasPrefix:namePart])
                continue;
            [[NSFileManager defaultManager] fileExistsAtPath:[dir stringByAppendingPathComponent:n] isDirectory:&d];
            [out addObject:[NSString stringWithFormat:@"@%@%@%@", [partial hasSuffix:@"/"] ? partial : ([dirPart length] ? [dirPart stringByAppendingString:@"/"] : @""), n, d ? @"/" : @""]];
        }
        return out;
    }
    return nil;
}

- (void)editorIdle:(TBLineEditor *)e
{
    /* chats changed by the window while the prompt waits */
    static double last = 0;
    double now = CFAbsoluteTimeGetCurrent();
    if (now - last > 1.5) {
        last = now;
        if ([[core store] reloadExternal]) {
            [editor setHint:[term styled:[self statusLine] with:@"dim"]];
            [editor setHint:[self statusLine]];
            [editor redraw];
        }
    }
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
}

- (void)editorBackTab:(TBLineEditor *)e
{
    NSArray *modes = [NSArray arrayWithObjects:@"ask", @"edits", @"plan", @"auto", nil];
    int at = (int)[modes indexOfObject:[core permissionMode]];
    [self setPermissionMode:[modes objectAtIndex:(at + 1) % [modes count]] announce:NO];
    [editor setHint:[self statusLine]];
}

- (void)setPermissionMode:(NSString *)mode announce:(BOOL)announce
{
    if ([mode isEqualToString:@"default"]) mode = @"ask";
    if ([mode isEqualToString:@"acceptEdits"] || [mode isEqualToString:@"accept-edits"]) mode = @"edits";
    if ([mode isEqualToString:@"yolo"] || [mode isEqualToString:@"bypass"]) mode = @"auto";
    [core setPermissionMode:mode];
    [config setObject:mode forKey:@"mode"];
    [self saveConfig];
    [self refreshInstructions];
    if (announce)
        [self printStyled:[NSString stringWithFormat:@"Mode: %@%@", mode, [mode isEqualToString:@"auto"] ? @" (nothing is asked; the model can change files and run commands)" : [mode isEqualToString:@"plan"] ? @" (the model investigates and plans; nothing is changed)" : [mode isEqualToString:@"edits"] ? @" (file changes go through; commands still ask)" : @" (changes and commands ask first)"] style:@"gray"];
}

/* ---- tool approval ---- */

static BOOL ruleMatches(NSString *rule, NSString *name, NSString *detail)
{
    NSRange open = [rule rangeOfString:@"("];
    NSString *toolPattern = rule, *argPattern = nil;
    if (open.location != NSNotFound && [rule hasSuffix:@")"]) {
        toolPattern = [rule substringToIndex:open.location];
        argPattern = [rule substringWithRange:NSMakeRange(open.location + 1, [rule length] - open.location - 2)];
    }
    if (fnmatch([toolPattern UTF8String], [name UTF8String], 0) != 0)
        return NO;
    if (argPattern && fnmatch([argPattern UTF8String], [detail UTF8String], 0) != 0)
        return NO;
    return YES;
}

- (NSString *)decisionFor:(NSDictionary *)event
{
    NSString *name = [event objectForKey:@"name"], *detail = [event objectForKey:@"detail"], *kind = toolKind(name), *mode = [core permissionMode];
    NSString *rule;
    NSEnumerator *e;
    if (!detail)
        detail = @"";
    e = [denyRules objectEnumerator];
    while ((rule = [e nextObject]))
        if ([rule isKindOfClass:[NSString class]] && ruleMatches(rule, name, detail))
            return @"deny";
    if ([mode isEqualToString:@"auto"])
        return @"allow";
    if ([mode isEqualToString:@"plan"] && ([kind isEqualToString:@"edit"] || [kind isEqualToString:@"exec"]))
        return @"deny";
    if ([kind isEqualToString:@"read"])
        return @"allow";
    e = [allowRules objectEnumerator];
    while ((rule = [e nextObject]))
        if ([rule isKindOfClass:[NSString class]] && ruleMatches(rule, name, detail))
            return @"allow";
    if ([mode isEqualToString:@"edits"] && [kind isEqualToString:@"edit"])
        return @"allow";
    if ([mode isEqualToString:@"plan"])
        return @"allow";      /* reads and other tools in plan mode */
    return nil;
}

/* the file change an editing tool is about to make, as a few coloured lines */
- (NSString *)diffPreviewFor:(NSDictionary *)event
{
    id parsed = TBJSONParse([[event objectForKey:@"args"] dataUsingEncoding:NSUTF8StringEncoding], NULL);
    NSString *name = [event objectForKey:@"name"];
    NSMutableString *out = [NSMutableString string];
    NSArray *lines;
    unsigned i, shown = 0;
    if (![parsed isKindOfClass:[NSDictionary class]])
        return nil;
    if ([name isEqualToString:@"edit_block"]) {
        NSString *from = TBString(parsed, @"old_string"), *to = TBString(parsed, @"new_string");
        if (![from length] && ![to length])
            return nil;
        lines = [from componentsSeparatedByString:@"\n"];
        for (i = 0; i < [lines count] && shown < 14; i++, shown++)
            [out appendFormat:@"%@\n", [term styled:[@"- " stringByAppendingString:[lines objectAtIndex:i]] with:@"red"]];
        lines = [to componentsSeparatedByString:@"\n"];
        for (i = 0, shown = 0; i < [lines count] && shown < 14; i++, shown++)
            [out appendFormat:@"%@\n", [term styled:[@"+ " stringByAppendingString:[lines objectAtIndex:i]] with:@"green"]];
        return out;
    }
    if ([name isEqualToString:@"write_file"]) {
        NSString *content = TBString(parsed, @"content");
        lines = [content componentsSeparatedByString:@"\n"];
        for (i = 0; i < [lines count] && i < 14; i++)
            [out appendFormat:@"%@\n", [term styled:[@"+ " stringByAppendingString:[lines objectAtIndex:i]] with:@"green"]];
        if ([lines count] > 14)
            [out appendFormat:@"%@\n", [term styled:[NSString stringWithFormat:@"  ... %lu more lines", (unsigned long)([lines count] - 14)] with:@"gray"]];
        return out;
    }
    return nil;
}

- (void)core:(TBCLICore *)c question:(NSDictionary *)event
{
    NSString *decision = [self decisionFor:event];
    NSString *name = [event objectForKey:@"name"];
    if (decision) {
        if ([decision isEqualToString:@"deny"])
            [self printStyled:[NSString stringWithFormat:@"  ✗ %@ is not allowed %@", name, [[core permissionMode] isEqualToString:@"plan"] ? @"in plan mode" : @"by your rules"] style:@"red"];
        [core answer:decision];
        return;
    }
    {
        NSString *server = [event objectForKey:@"server"], *detail = [event objectForKey:@"detail"], *diff = [self diffPreviewFor:event];
        NSString *title = server;
        BOOL full = NO;
        for (;;) {
            NSMutableString *card = [NSMutableString string];
            TBKey k;
            NSArray *rows = [detail componentsSeparatedByString:@"\n"];
            unsigned i, cap = full ? 60 : 6;
            [card appendFormat:@"%@\n", [term styled:[NSString stringWithFormat:@"%@ Allow %@?  %@", [term unicode] ? @"╭─" : @",-", name, title] with:@"yellow"]];
            for (i = 0; i < [rows count] && i < cap; i++)
                [card appendFormat:@"%@%@\n", [term styled:[term unicode] ? @"│ " : @"| " with:@"yellow"], [term clipToWidth:[rows objectAtIndex:i] width:[term columns] - 4]];
            if ([rows count] > cap)
                [card appendFormat:@"%@%@\n", [term styled:[term unicode] ? @"│ " : @"| " with:@"yellow"], [term styled:[NSString stringWithFormat:@"... %lu more lines (v shows more)", (unsigned long)([rows count] - cap)] with:@"gray"]];
            if (diff) {
                NSArray *d = [diff componentsSeparatedByString:@"\n"];
                for (i = 0; i < [d count]; i++)
                    if ([[d objectAtIndex:i] length])
                        [card appendFormat:@"%@%@\n", [term styled:[term unicode] ? @"│ " : @"| " with:@"yellow"], [term clipToWidth:[d objectAtIndex:i] width:[term columns] - 4]];
            }
            [card appendFormat:@"%@%@", [term styled:[term unicode] ? @"╰─ " : @"`- " with:@"yellow"], [term styled:@"y allow · a always for this chat · n deny · v more" with:@"gray"]];
            [self emit:card];
            [self clearLive];
            for (;;) {
                k = [term readKeyWithin:200];
                if (k.type == TBKeyNone || k.type == TBKeyResize) {
                    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
                    continue;
                }
                if (k.type == TBKeyChar && !strchr("yYaAnNvV", (int)k.ch))
                    continue;
                if (k.type != TBKeyChar && k.type != TBKeyEnter && k.type != TBKeyEscape && k.type != TBKeyEOF && k.type != TBKeyCtrl)
                    continue;
                break;
            }
            [term write:@"\r\n"];
            if (k.type == TBKeyChar && (k.ch == 'v' || k.ch == 'V')) { full = YES; continue; }
            if (k.type == TBKeyChar && (k.ch == 'y' || k.ch == 'Y')) { [core answer:@"allow"]; break; }
            if (k.type == TBKeyEnter) { [core answer:@"allow"]; break; }
            if (k.type == TBKeyChar && (k.ch == 'a' || k.ch == 'A')) { [core answer:@"always"]; break; }
            if (k.type == TBKeyChar && (k.ch == 'n' || k.ch == 'N')) { [core answer:@"deny"]; break; }
            if (k.type == TBKeyEscape || k.type == TBKeyEOF || (k.type == TBKeyCtrl && k.ch == 'c')) { [core answer:@"deny"]; break; }
        }
        [self drawLive];
    }
}

/* ---- events from a turn ---- */

- (void)endText
{
    if (textStarted) {
        [md finish];
        textStarted = NO;
    }
    if (thinkingStarted) {
        thinkingStarted = NO;
    }
}

- (void)core:(TBCLICore *)c text:(NSString *)delta
{
    if (!textStarted) {
        textStarted = YES;
        firstLine = YES;
        [md setWidth:[term columns]];
        if (lastWasTool)
            lastWasTool = NO;
    }
    [spinLabel release];
    spinLabel = nil;
    [md feed:delta];
}

- (void)core:(TBCLICore *)c status:(NSString *)note error:(BOOL)error
{
    [self endText];
    [self printStyled:[NSString stringWithFormat:@"%@ %@", error ? @"✗" : @"·", note] style:error ? @"red" : @"gray"];
}

- (void)core:(TBCLICore *)c activity:(NSDictionary *)event
{
    NSString *phase = [event objectForKey:@"phase"], *name = [event objectForKey:@"name"], *label = [event objectForKey:@"label"];
    [self endText];
    lastWasTool = YES;
    if (![phase isEqualToString:@"result"]) {
        [toolStarts setObject:[NSNumber numberWithDouble:CFAbsoluteTimeGetCurrent()] forKey:[event objectForKey:@"id"]];
        [spinLabel release];
        spinLabel = [[NSString stringWithFormat:@"%@%@", name, [label length] ? [@": " stringByAppendingString:label] : @""] copy];
        [self printLine:[NSString stringWithFormat:@"%@ %@%@", [term styled:[term unicode] ? @"●" : @"*" with:@"cyan"], [term styled:name with:@"bold"],
            [label length] ? [@"  " stringByAppendingString:[term styled:[term clipToWidth:label width:[term columns] - [term widthOf:name] - 6] with:@"gray"]] : @""]];
        return;
    }
    turnTools++;
    {
        BOOL failed = [[event objectForKey:@"failed"] boolValue];
        NSString *output = [event objectForKey:@"output"];
        NSArray *rows = [output componentsSeparatedByString:@"\n"];
        unsigned i, cap = verbose ? 80 : 4;
        NSMutableString *card = [NSMutableString string];
        NSString *summary = [NSString stringWithFormat:@"%@ %.1fs", failed ? @"failed" : @"done", [[event objectForKey:@"elapsed"] doubleValue]];
        if ([event objectForKey:@"files"])
            summary = [NSString stringWithFormat:@"%@ · %d file%@ +%d −%d", summary, [[event objectForKey:@"files"] intValue], [[event objectForKey:@"files"] intValue] == 1 ? @"" : @"s", [[event objectForKey:@"added"] intValue], [[event objectForKey:@"removed"] intValue]];
        [card appendFormat:@"  %@ %@\n", [term styled:[term unicode] ? @"⎿" : @"`" with:@"gray"], [term styled:summary with:failed ? @"red" : @"gray"]];
        if ([output length] && (failed || verbose || [rows count] <= 4)) {
            for (i = 0; i < [rows count] && i < cap; i++)
                if ([[rows objectAtIndex:i] length] || verbose)
                    [card appendFormat:@"    %@\n", [term styled:[term clipToWidth:[rows objectAtIndex:i] width:[term columns] - 6] with:@"gray"]];
            if ([rows count] > cap)
                [card appendFormat:@"    %@\n", [term styled:[NSString stringWithFormat:@"... %lu more lines (/verbose shows all)", (unsigned long)([rows count] - cap)] with:@"gray"]];
        }
        [self emit:card];
        [spinLabel release];
        spinLabel = nil;
    }
}

- (void)core:(TBCLICore *)c thinking:(NSString *)delta
{
    if (!showThinking) {
        [spinLabel release];
        spinLabel = [@"Thinking" copy];
        return;
    }
    [self endTextOnly];
    if (!thinkingStarted) {
        thinkingStarted = YES;
        [self printLine:[term styled:[term unicode] ? @"✻ Thinking" : @"* Thinking" with:@"gray"]];
    }
    [thinkBuffer appendString:delta ? delta : @""];
    {
        NSRange nl;
        while ((nl = [thinkBuffer rangeOfString:@"\n"]).location != NSNotFound) {
            NSString *line = [thinkBuffer substringToIndex:nl.location];
            [thinkBuffer deleteCharactersInRange:NSMakeRange(0, nl.location + 1)];
            if ([line length])
                [self printLine:[term styled:[NSString stringWithFormat:@"  %@", line] with:@"gray"]];
        }
    }
}

- (void)endTextOnly { if (textStarted) { [md finish]; textStarted = NO; } }

- (void)core:(TBCLICore *)c media:(NSString *)description
{
    [self endText];
    [self printStyled:[NSString stringWithFormat:@"  [%@ — shown in the Tiger Build window]", description] style:@"gray"];
}

- (void)core:(TBCLICore *)c usage:(NSDictionary *)event {}

- (void)coreTurnEnded:(TBCLICore *)c
{
    working = NO;
}

/* ---- a turn ---- */

- (void)handleWorkingKey:(TBKey)k
{
    switch (k.type) {
    case TBKeyEscape:
        [core stop];
        [typed setString:@""];
        break;
    case TBKeyCtrl:
        if (k.ch == 'c')
            [core stop];
        break;
    case TBKeyEnter:
        if ([typed length]) {
            NSString *note = [[typed copy] autorelease];
            [typed setString:@""];
            if ([core guide:note])
                [self printStyled:[NSString stringWithFormat:@"  › note for the model: %@", note] style:@"gray"];
            else
                [self printStyled:@"  The model cannot take a note now." style:@"red"];
        }
        break;
    case TBKeyBackspace:
        if ([typed length])
            [typed deleteCharactersInRange:NSMakeRange([typed length] - 1, 1)];
        break;
    case TBKeyChar: {
        unichar u[2];
        if (k.ch >= 0x10000) {
            unsigned int v = k.ch - 0x10000;
            u[0] = (unichar)(0xd800 + (v >> 10));
            u[1] = (unichar)(0xdc00 + (v & 0x3ff));
            [typed appendString:[NSString stringWithCharacters:u length:2]];
        } else {
            u[0] = (unichar)k.ch;
            [typed appendString:[NSString stringWithCharacters:u length:1]];
        }
        break;
    }
    case TBKeyPaste:
        [typed appendString:[[k.paste componentsSeparatedByString:@"\n"] componentsJoinedByString:@" "]];
        break;
    default:
        break;
    }
}

- (void)runTurnWithText:(NSString *)text
{
    NSString *problem;
    NSMutableString *full = [NSMutableString string];
    unsigned i;
    for (i = 0; i < [shellNotes count]; i++)
        [full appendFormat:@"%@\n\n", [shellNotes objectAtIndex:i]];
    [shellNotes removeAllObjects];
    [full appendString:[self expandMentions:text]];
    problem = [core sendText:full];
    if (problem) {
        [self printStyled:problem style:@"red"];
        return;
    }
    [self watchTurn];
}

- (void)watchTurn
{
    working = YES;
    textStarted = thinkingStarted = lastWasTool = NO;
    turnTools = 0;
    spinStart = CFAbsoluteTimeGetCurrent();
    [typed setString:@""];
    [spinLabel release];
    spinLabel = [@"Working" copy];
    [term write:@"\r\n"];
    [self drawLive];
    while (working) {
        TBKey k = [term readKeyWithin:60];
        double now = CFAbsoluteTimeGetCurrent();
        if (k.type != TBKeyNone && k.type != TBKeyResize) {
            [self handleWorkingKey:k];
            [self clearLive];
            [self drawLive];
        }
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.001]];
        if (now - lastSpin > 0.09) {
            lastSpin = now;
            spinFrame++;
            [self clearLive];
            [self drawLive];
        }
    }
    [self endText];
    [self clearLive];
    {
        NSMutableDictionary *chat = [core currentChat];
        NSString *reply = [core lastReplyText:chat];
        NSMutableArray *messages = [chat objectForKey:@"messages"];
        NSDictionary *last = nil;
        int m;
        NSMutableString *line = [NSMutableString string];
        for (m = (int)[messages count] - 1; m >= 0; m--)
            if ([[[messages objectAtIndex:m] objectForKey:@"role"] isEqualToString:@"assistant"] && [[messages objectAtIndex:m] objectForKey:@"statsSeconds"]) {
                last = [messages objectAtIndex:m];
                break;
            }
        [line appendFormat:@"%.1fs", CFAbsoluteTimeGetCurrent() - spinStart];
        if (last)
            [line appendFormat:@" · ↑%@ ↓%@", [self tokenText:[[last objectForKey:@"statsIn"] intValue]], [self tokenText:[[last objectForKey:@"statsOut"] intValue]]];
        if ([self costText:chat])
            [line appendFormat:@" · %@ in this chat", [self costText:chat]];
        if (turnTools)
            [line appendFormat:@" · %d tool call%@", turnTools, turnTools == 1 ? @"" : @"s"];
        [self printStyled:line style:@"gray"];
        if (bell)
            [term write:@"\007"];
        (void)reply;
    }
    [term flush];
    if ([[core permissionMode] isEqualToString:@"plan"])
        [self offerPlanApproval];
}

/* in plan mode, after the model's plan: carry it out? */
- (void)offerPlanApproval
{
    TBKey k;
    NSString *reply = [core lastReplyText:[core currentChat]];
    if ([reply length] < 40)
        return;
    [term write:[NSString stringWithFormat:@"%@\r\n", [term styled:@"Carry out this plan?  y yes (file changes go through)  a yes, no questions  n keep planning" with:@"yellow"]]];
    [term flush];
    for (;;) {
        k = [term readKeyWithin:500];
        if (k.type == TBKeyNone) continue;
        if (k.type == TBKeyChar && (k.ch == 'y' || k.ch == 'Y')) { [self setPermissionMode:@"edits" announce:YES]; [self runTurnWithText:@"Go ahead and carry out the plan."]; return; }
        if (k.type == TBKeyChar && (k.ch == 'a' || k.ch == 'A')) { [self setPermissionMode:@"auto" announce:YES]; [self runTurnWithText:@"Go ahead and carry out the plan."]; return; }
        return;
    }
}

/* ---- showing a chat ---- */

- (void)showChat:(NSDictionary *)chat full:(BOOL)full
{
    NSArray *messages = [chat objectForKey:@"messages"];
    int start = 0, i;
    TBMarkdown *show;
    if (!full && [messages count] > 30)
        start = (int)[messages count] - 30;
    if (start > 0)
        [self printStyled:[NSString stringWithFormat:@"  ... %d earlier messages (/history shows all)", start] style:@"gray"];
    show = [[[TBMarkdown alloc] initWithTerm:term margin:@"  " target:self action:@selector(mdPlain:)] autorelease];
    [show setWidth:[term columns]];
    for (i = start; i < (int)[messages count]; i++) {
        NSDictionary *m = [messages objectAtIndex:i];
        NSString *role = [m objectForKey:@"role"], *text = [m objectForKey:@"text"];
        if (![text isKindOfClass:[NSString class]])
            text = @"";
        if ([role isEqualToString:@"user"]) {
            [term write:[NSString stringWithFormat:@"\r\n%@ %@\r\n", [term styled:[term unicode] ? @"❯" : @">" with:@"cyan"], [term styled:text with:@"bold"]]];
        } else if ([role isEqualToString:@"status"]) {
            NSString *kind = [m objectForKey:@"activityKind"];
            if ([kind isEqualToString:@"thinking"])
                continue;
            if ([kind isEqualToString:@"tool"])
                [term write:[NSString stringWithFormat:@"%@ %@\r\n", [term styled:[term unicode] ? @"●" : @"*" with:@"cyan"], [term styled:text with:@"gray"]]];
            else
                [term write:[NSString stringWithFormat:@"%@\r\n", [term styled:[NSString stringWithFormat:@"  · %@", text] with:@"gray"]]];
        } else {
            if ([m objectForKey:@"tweet"]) {
                [term write:[NSString stringWithFormat:@"%@\r\n", [term styled:[NSString stringWithFormat:@"  [post: %@ — shown in the Tiger Build window]", [text length] > 100 ? [[text substringToIndex:100] stringByAppendingString:@"..."] : text] with:@"gray"]]];
                continue;
            }
            if ([text length]) {
                firstLine = YES;
                [show feed:text];
                [show feed:@"\n"];
                [show finish];
            }
            if ([m objectForKey:@"image"])
                [term write:[NSString stringWithFormat:@"%@\r\n", [term styled:[NSString stringWithFormat:@"  [picture %@ — shown in the Tiger Build window]", [[m objectForKey:@"image"] lastPathComponent]] with:@"gray"]]];
            if ([m objectForKey:@"video"])
                [term write:[NSString stringWithFormat:@"%@\r\n", [term styled:[NSString stringWithFormat:@"  [video %@ — shown in the Tiger Build window]", [[m objectForKey:@"video"] lastPathComponent]] with:@"gray"]]];
            if ([m objectForKey:@"file"])
                [term write:[NSString stringWithFormat:@"%@\r\n", [term styled:[NSString stringWithFormat:@"  [file %@]", [m objectForKey:@"file"]] with:@"gray"]]];
        }
    }
    [term flush];
}

- (void)mdPlain:(NSString *)text
{
    if (firstLine) {
        firstLine = NO;
        if ([text hasPrefix:@"  "])
            text = [NSString stringWithFormat:@"%@ %@", [term styled:[term unicode] ? @"●" : @"*" with:@"orange"], [text substringFromIndex:2]];
    }
    [term write:[[text componentsSeparatedByString:@"\n"] componentsJoinedByString:@"\r\n"]];
}

/* ---- the loop ---- */

- (int)runInteractive
{
    NSString *line;
    BOOL interrupted;
    [core refreshCatalog];
    if (![core currentChat]) {
        NSMutableDictionary *fresh = [core newChat];
        (void)fresh;
    }
    [self refreshInstructions];
    [term enterRaw];
    [term setTitle:@"Tiger Build"];
    [self banner];
    if ([[[[core currentChat] objectForKey:@"messages"] lastObject] objectForKey:@"role"] && [[[core currentChat] objectForKey:@"messages"] count] > 1)
        [self showChat:[core currentChat] full:NO];
    if (initial) {
        [self runTurnWithText:initial];
        initial = nil;
    }
    while (!quit) {
        [editor setPrompt:[self promptText] continuation:@"  "];
        [editor setHint:[self statusLine]];
        if (![editor readLine:&line interrupted:&interrupted])
            break;
        if (interrupted) {
            double now = CFAbsoluteTimeGetCurrent();
            if (now - lastInterrupt < 2)
                break;
            lastInterrupt = now;
            [self printStyled:@"Press Ctrl-C again to exit (or Ctrl-D)." style:@"gray"];
            continue;
        }
        line = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([line length] == 0)
            continue;
        [editor addHistory:line];
        if ([line hasPrefix:@"/"] && ![line hasPrefix:@"//"]) {
            if ([self runCommand:line])
                continue;
        }
        if ([line hasPrefix:@"!"]) {
            [self runShell:[[line substringFromIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
            continue;
        }
        if ([line hasPrefix:@"#"] && [line length] > 1) {
            /* a note for the project's instructions file */
            [self appendNote:[[line substringFromIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
            continue;
        }
        [self runTurnWithText:line];
    }
    [term write:@"\r\n"];
    [term leaveRaw];
    [core save];
    return 0;
}

/* !command: run it here, show the output, and give it to the model with the next message */
- (void)runShell:(NSString *)command
{
    NSTask *task = [[[NSTask alloc] init] autorelease];
    NSPipe *pipe = [NSPipe pipe];
    NSData *data;
    NSString *output;
    if ([command length] == 0)
        return;
    [task setLaunchPath:@"/bin/sh"];
    [task setArguments:[NSArray arrayWithObjects:@"-c", command, nil]];
    [task setStandardOutput:pipe];
    [task setStandardError:pipe];
    [task setStandardInput:[NSFileHandle fileHandleWithNullDevice]];
    [term leaveRaw];
    NS_DURING
        [task launch];
        data = [[pipe fileHandleForReading] readDataToEndOfFile];
        [task waitUntilExit];
    NS_HANDLER
        data = nil;
    NS_ENDHANDLER
    [term enterRaw];
    output = data ? [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease] : @"";
    if (!output)
        output = @"(not text)";
    if ([output length] > 30000)
        output = [[output substringToIndex:30000] stringByAppendingString:@"\n... (cut)"];
    [self printLine:[output length] ? [term styled:[[output componentsSeparatedByString:@"\n"] componentsJoinedByString:@"\n"] with:@"gray"] : [term styled:@"(no output)" with:@"gray"]];
    [shellNotes addObject:[NSString stringWithFormat:@"I ran `%@` in the terminal. It printed:\n```\n%@\n```", command, output]];
    [self printStyled:@"  (the output goes to the model with your next message)" style:@"gray"];
}

- (void)appendNote:(NSString *)note
{
    NSString *path = [[[NSFileManager defaultManager] currentDirectoryPath] stringByAppendingPathComponent:@"TIGERBUILD.md"];
    NSString *old = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    NSString *new = [NSString stringWithFormat:@"%@%@- %@\n", old ? old : @"", [old length] && ![old hasSuffix:@"\n"] ? @"\n" : @"", note];
    if ([new writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]) {
        [self printStyled:[NSString stringWithFormat:@"  noted in %@", path] style:@"gray"];
        [self refreshInstructions];
    } else
        [self printStyled:@"  could not write TIGERBUILD.md here" style:@"red"];
}

@end
