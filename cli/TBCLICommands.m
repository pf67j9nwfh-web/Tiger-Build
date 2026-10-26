#import "TBCLIApp.h"
#import "TBEngine.h"
#import "TBBackground.h"
#import "TBIntegrations.h"

@implementation TBCLIApp (Commands)

- (NSArray *)commandNames
{
    return [NSArray arrayWithObjects:@"/help", @"/exit", @"/quit", @"/new", @"/clear", @"/chats", @"/resume", @"/model", @"/models", @"/tools", @"/mode", @"/cost", @"/context",
        @"/rename", @"/delete", @"/fork", @"/export", @"/copy", @"/retry", @"/workspace", @"/status", @"/verbose", @"/thinking", @"/instructions", @"/allow", @"/deny",
        @"/doctor", @"/wakes", @"/bg", @"/hooks", @"/mcp", @"/undo", @"/compact", @"/init", @"/history", @"/diff", @"/commit", @"/review", @"/bell", nil];
}

- (void)table:(NSArray *)rows
{
    unsigned i;
    for (i = 0; i < [rows count]; i++)
        [self printLine:[rows objectAtIndex:i]];
}

/* each command and what it does; laid out in two columns when the window is wide and one above the other when it is narrow, always wrapped to the width */
- (void)help
{
    static NSString *rows[][2] = {
        {@"/new", @"start a new chat"},
        {@"/chats [text]", @"list the chats, or search them"},
        {@"/resume [id|text]", @"open a chat"},
        {@"/fork [n]", @"copy this chat (its first n messages)"},
        {@"/rename TITLE", @"rename this chat"},
        {@"/delete [id]", @"delete a chat"},
        {@"/model [spec]", @"show or switch the model: grok, claude:claude-sonnet-5-5, a model name"},
        {@"/models [provider]", @"list the services and their models"},
        {@"/tools [name on|off]", @"switch tools on or off for this chat; /tools NAME approve on|off sets whether one asks first"},
        {@"/mode ask|edits|plan|auto", @"how much to ask before changing things (Shift-Tab cycles through them)"},
        {@"/allow RULE  /deny RULE", @"standing rules, for example start_process(git *)"},
        {@"/cost", @"what this chat has cost"},
        {@"/context", @"how full the model's context is"},
        {@"/compact", @"summarize the older messages now"},
        {@"/status", @"where things stand"},
        {@"/retry", @"ask for the last reply again"},
        {@"/copy", @"copy the last reply"},
        {@"/undo", @"put back the files the last reply changed"},
        {@"/export [file]", @"save the chat as Markdown"},
        {@"/history", @"show the whole chat again"},
        {@"/diff  /commit  /review", @"git helpers: the model does the work"},
        {@"/bg [stop ID]", @"background tasks the model started (it is woken when one finishes)"},
        {@"/wakes [N]", @"how many times in a row a finished task may wake the chat"},
        {@"/hooks", @"shell commands run around prompts and tools"},
        {@"/mcp", @"MCP servers"},
        {@"/workspace [name]", @"list or switch the workspace"},
        {@"/instructions", @"the project files in use"},
        {@"/verbose  /thinking  /bell", @"toggles"},
        {@"/doctor", @"check the set-up"},
        {@"/init", @"have the model write a TIGERBUILD.md for this folder"},
        {@"/exit", @"leave"},
    };
    unsigned i, count = sizeof rows / sizeof rows[0];
    int cols = [term columns], w = 0;
    NSMutableString *out = [NSMutableString string];
    NSArray *tips = [NSArray arrayWithObjects:@"@path adds a file or folder to your message.", @"!command runs a command here and tells the model.", @"# note adds a line to TIGERBUILD.md.",
        @"Esc stops a reply; Ctrl-C twice leaves.", nil];
    for (i = 0; i < count; i++)
        if ((int)[rows[i][0] length] > w)
            w = (int)[rows[i][0] length];
    if (w > 28)
        w = 28;
    if (cols < 64 || w + 24 > cols - 4) {
        for (i = 0; i < count; i++) {
            NSArray *lines = [[term wrap:rows[i][1] width:cols - 7 indent:@""] componentsSeparatedByString:@"\n"];
            unsigned j;
            [out appendFormat:@"  %@\n", [term styled:rows[i][0] with:@"bold"]];
            for (j = 0; j < [lines count]; j++)
                if ([[lines objectAtIndex:j] length])
                    [out appendFormat:@"     %@\n", [lines objectAtIndex:j]];
        }
    } else {
        NSString *gap = [@"" stringByPaddingToLength:(unsigned)(w + 4) withString:@" " startingAtIndex:0];
        for (i = 0; i < count; i++) {
            NSArray *lines = [[term wrap:rows[i][1] width:cols - w - 5 indent:@""] componentsSeparatedByString:@"\n"];
            unsigned j;
            NSString *pad = [@"" stringByPaddingToLength:(unsigned)(w - (int)[rows[i][0] length] > 0 ? w - (int)[rows[i][0] length] : 0) withString:@" " startingAtIndex:0];
            [out appendFormat:@"  %@%@  %@\n", [term styled:rows[i][0] with:@"bold"], pad, [lines objectAtIndex:0]];
            for (j = 1; j < [lines count]; j++)
                if ([[lines objectAtIndex:j] length])
                    [out appendFormat:@"%@%@\n", gap, [lines objectAtIndex:j]];
        }
    }
    [out appendString:@"\n"];
    for (i = 0; i < [tips count]; i++)
        [out appendFormat:@"%@\n", [term wrap:[@"  " stringByAppendingString:[tips objectAtIndex:i]] width:cols - 1 indent:@"    "]];
    [self printLine:[out substringToIndex:[out length] - 1]];
}

- (NSMutableDictionary *)pickChat:(NSString *)arg
{
    NSMutableDictionary *c;
    NSArray *hits;
    if (![arg length])
        return nil;
    c = [core chatWithId:arg];
    if (c)
        return c;
    hits = [core searchChats:arg];
    return [hits count] ? [hits objectAtIndex:0] : nil;
}

- (void)listChats:(NSArray *)list
{
    unsigned i;
    NSMutableDictionary *cur = [core currentChat];
    if (![list count]) {
        [self printStyled:@"  no chats" style:@"gray"];
        return;
    }
    for (i = 0; i < [list count] && i < 40; i++) {
        NSDictionary *c = [list objectAtIndex:i];
        [self printLine:[NSString stringWithFormat:@"  %@ %5@  %@  %@", c == cur ? @"›" : @" ", [c objectForKey:@"id"], [term clipToWidth:[core titleOf:c] width:[term columns] - 40],
            [term styled:[self modelLabel:c] with:@"gray"]]];
    }
}

- (BOOL)setToolArg:(NSString *)arg
{
    NSArray *parts = [arg componentsSeparatedByString:@" "], *cat = [core toolCatalog];
    NSMutableDictionary *chat = [core currentChat];
    NSString *name = [parts objectAtIndex:0], *key = nil, *what = [parts count] > 1 ? [parts objectAtIndex:1] : nil, *val = [parts count] > 2 ? [parts objectAtIndex:2] : nil;
    unsigned i;
    BOOL approve = NO;
    if ([what isEqualToString:@"approve"]) { approve = YES; what = val; }
    for (i = 0; i < [cat count]; i++) {
        NSDictionary *t = [cat objectAtIndex:i];
        if ([[t objectForKey:@"id"] isEqualToString:name] || [[[t objectForKey:@"title"] lowercaseString] isEqualToString:[name lowercaseString]]) { key = [t objectForKey:@"id"]; break; }
    }
    if (!key) {
        [self printStyled:[NSString stringWithFormat:@"  no tool called %@", name] style:@"red"];
        return NO;
    }
    if (![what length])
        what = [core serverEnabled:key chat:chat] ? @"off" : @"on";
    {
        BOOL on = [what isEqualToString:@"on"] || [what isEqualToString:@"yes"];
        if (approve)
            [core setApproval:on forKey:key chat:chat];
        else
            [core setServer:key enabled:on chat:chat];
        [core save];
        [self printStyled:[NSString stringWithFormat:@"  %@ %@ %@", key, approve ? @"approval" : @"", on ? @"on" : @"off"] style:@"gray"];
    }
    return YES;
}

- (void)exportTo:(NSString *)path
{
    NSDictionary *chat = [core currentChat];
    NSMutableString *out = [NSMutableString stringWithFormat:@"# %@\n\n", [core titleOf:chat]];
    NSArray *ms = [chat objectForKey:@"messages"];
    unsigned i;
    for (i = 0; i < [ms count]; i++) {
        NSDictionary *m = [ms objectAtIndex:i];
        NSString *role = [m objectForKey:@"role"], *text = [m objectForKey:@"text"];
        if (![text length])
            continue;
        if ([role isEqualToString:@"user"]) [out appendFormat:@"## You\n\n%@\n\n", text];
        else if ([role isEqualToString:@"assistant"]) [out appendFormat:@"## %@\n\n%@\n\n", [self modelLabel:chat], text];
    }
    if (![path length])
        path = [NSString stringWithFormat:@"tiger-build-chat-%@.md", [chat objectForKey:@"id"]];
    path = [path stringByExpandingTildeInPath];
    if ([out writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL])
        [self printStyled:[NSString stringWithFormat:@"  wrote %@", path] style:@"gray"];
    else
        [self printStyled:@"  could not write the file" style:@"red"];
}

- (void)copyLast
{
    NSString *reply = [core lastReplyText:[core currentChat]];
    NSTask *task;
    NSPipe *pipe = [NSPipe pipe];
    if (![reply length]) { [self printStyled:@"  nothing to copy" style:@"gray"]; return; }
    /* over ssh the clipboard is the other machine's: OSC 52 asks the terminal to set its own */
    if (getenv("SSH_TTY") || getenv("SSH_CONNECTION")) {
        NSString *b64 = [[reply dataUsingEncoding:NSUTF8StringEncoding] description];
        (void)b64;
        [term write:[NSString stringWithFormat:@"\033]52;c;%@\007", TBBase64([reply dataUsingEncoding:NSUTF8StringEncoding])]];
        [term flush];
        [self printStyled:@"  sent to your terminal's clipboard" style:@"gray"];
        return;
    }
    task = [[[NSTask alloc] init] autorelease];
    [task setLaunchPath:@"/usr/bin/pbcopy"];
    [task setStandardInput:pipe];
    NS_DURING
        [task launch];
        [[pipe fileHandleForWriting] writeData:[reply dataUsingEncoding:NSUTF8StringEncoding]];
        [[pipe fileHandleForWriting] closeFile];
        [task waitUntilExit];
        [self printStyled:@"  copied" style:@"gray"];
    NS_HANDLER
        [self printStyled:@"  pbcopy failed" style:@"red"];
    NS_ENDHANDLER
}

- (void)addRule:(NSString *)rule key:(NSString *)key
{
    NSMutableArray *list = [NSMutableArray arrayWithArray:[config objectForKey:key]];
    if (![rule length]) {
        [self printStyled:[NSString stringWithFormat:@"  %@ rules: %@", key, [list count] ? [list componentsJoinedByString:@", "] : @"none"] style:@"gray"];
        return;
    }
    [list addObject:rule];
    [config setObject:list forKey:key];
    [self saveConfig];
    [allowRules release]; allowRules = [[config objectForKey:@"allow"] retain];
    [denyRules release]; denyRules = [[config objectForKey:@"deny"] retain];
    [self printStyled:[NSString stringWithFormat:@"  %@ %@ (saved)", key, rule] style:@"gray"];
}

/* /name runs the text of .tigerbuild/commands/name.md (this folder or above) or cli/commands/name.md, with $ARGUMENTS replaced */
- (NSString *)customCommandFile:(NSString *)name
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dir = [fm currentDirectoryPath], *file = [name stringByAppendingPathExtension:@"md"];
    for (;;) {
        NSString *p = [[[dir stringByAppendingPathComponent:@".tigerbuild"] stringByAppendingPathComponent:@"commands"] stringByAppendingPathComponent:file];
        if ([fm fileExistsAtPath:p])
            return p;
        if ([dir length] <= 1)
            break;
        dir = [dir stringByDeletingLastPathComponent];
    }
    {
        NSString *p = [[[self cliDir] stringByAppendingPathComponent:@"commands"] stringByAppendingPathComponent:file];
        return [fm fileExistsAtPath:p] ? p : nil;
    }
}

- (NSArray *)customCommandNames
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *dirs = [NSMutableArray array], *names = [NSMutableArray array];
    NSString *dir = [fm currentDirectoryPath];
    unsigned i, j;
    for (;;) {
        [dirs addObject:[[dir stringByAppendingPathComponent:@".tigerbuild"] stringByAppendingPathComponent:@"commands"]];
        if ([dir length] <= 1)
            break;
        dir = [dir stringByDeletingLastPathComponent];
    }
    [dirs addObject:[[self cliDir] stringByAppendingPathComponent:@"commands"]];
    for (i = 0; i < [dirs count]; i++) {
        NSArray *files = [fm directoryContentsAtPath:[dirs objectAtIndex:i]];
        for (j = 0; j < [files count]; j++) {
            NSString *f = [files objectAtIndex:j], *n;
            if (![[f pathExtension] isEqualToString:@"md"])
                continue;
            n = [@"/" stringByAppendingString:[f stringByDeletingPathExtension]];
            if (![names containsObject:n])
                [names addObject:n];
        }
    }
    return names;
}

- (BOOL)runCustomCommand:(NSString *)cmd arguments:(NSString *)arg
{
    NSString *path = [self customCommandFile:[cmd substringFromIndex:1]], *text;
    NSMutableString *body;
    if (!path || [cmd rangeOfString:@"/" options:0 range:NSMakeRange(1, [cmd length] - 1)].length)
        return NO;
    text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    if (![text length])
        return NO;
    body = [NSMutableString stringWithString:text];
    if ([body rangeOfString:@"$ARGUMENTS"].length)
        [body replaceOccurrencesOfString:@"$ARGUMENTS" withString:arg options:0 range:NSMakeRange(0, [body length])];
    else if ([arg length])
        [body appendFormat:@"\n\n%@", arg];
    [self runTurnWithText:body];
    return YES;
}

- (BOOL)runCommand:(NSString *)line
{
    NSRange sp = [line rangeOfString:@" "];
    NSString *cmd = sp.location == NSNotFound ? line : [line substringToIndex:sp.location];
    NSString *arg = sp.location == NSNotFound ? @"" : [[line substringFromIndex:sp.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSMutableDictionary *chat = [core currentChat];
    NSString *problem = nil;
    if ([cmd isEqualToString:@"/help"] || [cmd isEqualToString:@"/?"]) [self help];
    else if ([cmd isEqualToString:@"/exit"] || [cmd isEqualToString:@"/quit"]) quit = YES;
    else if ([cmd isEqualToString:@"/new"] || [cmd isEqualToString:@"/clear"]) {
        [core newChat];
        [term write:@"\033[2J\033[H"];
        [self banner];
    } else if ([cmd isEqualToString:@"/chats"])
        [self listChats:[arg length] ? [core searchChats:arg] : [core chats]];
    else if ([cmd isEqualToString:@"/resume"]) {
        NSMutableDictionary *c = [arg length] ? [self pickChat:arg] : ([[core chats] count] ? [[core chats] objectAtIndex:0] : nil);
        if (!c) [self printStyled:@"  no such chat (/chats lists them)" style:@"red"];
        else { [core setCurrentChat:c]; [self showChat:c full:NO]; }
    } else if ([cmd isEqualToString:@"/history"]) [self showChat:chat full:YES];
    else if ([cmd isEqualToString:@"/model"]) {
        if (![arg length])
            [self printLine:[NSString stringWithFormat:@"  %@  (%@:%@)", [self modelLabel:chat], [core providerForChat:chat], [core modelForChat:chat]]];
        else if ([core setModelSpec:arg chat:chat error:&problem]) { [core save]; [self printStyled:[NSString stringWithFormat:@"  %@", [self modelLabel:chat]] style:@"gray"]; }
        else [self printStyled:[NSString stringWithFormat:@"  %@", problem] style:@"red"];
    } else if ([cmd isEqualToString:@"/models"]) {
        NSArray *providers = [[ModelCatalog shared] providers];
        unsigned i, j;
        for (i = 0; i < [providers count]; i++) {
            NSString *p = [[providers objectAtIndex:i] objectForKey:@"id"];
            NSArray *ms;
            if ([arg length] && ![p isEqualToString:arg] && ![[[[ModelCatalog shared] titleForProvider:p] lowercaseString] hasPrefix:[arg lowercaseString]])
                continue;
            ms = [core modelsForProvider:p];
            [self printLine:[NSString stringWithFormat:@"%@ %@%@", [term styled:[[ModelCatalog shared] titleForProvider:p] with:@"bold"], [term styled:p with:@"gray"],
                [core providerUsable:p] ? @"" : [term styled:[NSString stringWithFormat:@"  (%@)", [core providerNote:p]] with:@"yellow"]]];
            if ([arg length] || [providers count] <= 1)
                for (j = 0; j < [ms count]; j++)
                    [self printLine:[NSString stringWithFormat:@"    %@  %@", [[ms objectAtIndex:j] objectForKey:@"id"], [term styled:[[ms objectAtIndex:j] objectForKey:@"title"] with:@"gray"]]];
        }
        if (![arg length]) [self printStyled:@"  /models PROVIDER lists its models; /model PROVIDER:MODEL switches" style:@"gray"];
    } else if ([cmd isEqualToString:@"/tools"]) {
        if ([arg length]) [self setToolArg:arg];
        else {
            NSArray *cat = [core toolCatalog];
            unsigned i;
            for (i = 0; i < [cat count]; i++) {
                NSDictionary *t = [cat objectAtIndex:i];
                NSString *k = [t objectForKey:@"id"];
                [self printLine:[NSString stringWithFormat:@"  %@ %-22@ %@%@", [core serverEnabled:k chat:chat] ? [term styled:@"on " with:@"green"] : [term styled:@"off" with:@"gray"], k,
                    [term styled:[t objectForKey:@"title"] with:@"gray"], [core approvalOn:k chat:chat] ? [term styled:@"  asks" with:@"yellow"] : @""]];
            }
            [self printStyled:@"  /tools NAME on|off   /tools NAME approve on|off" style:@"gray"];
        }
    } else if ([cmd isEqualToString:@"/mode"]) {
        if ([arg length]) [self setPermissionMode:arg announce:YES];
        else [self printStyled:[NSString stringWithFormat:@"  mode: %@ (ask, edits, plan, auto)", [core permissionMode]] style:@"gray"];
    } else if ([cmd isEqualToString:@"/allow"]) [self addRule:arg key:@"allow"];
    else if ([cmd isEqualToString:@"/deny"]) [self addRule:arg key:@"deny"];
    else if ([cmd isEqualToString:@"/cost"]) {
        NSDictionary *usage = [chat objectForKey:@"usage"];
        NSEnumerator *e = [usage keyEnumerator];
        NSString *k;
        while ((k = [e nextObject])) {
            NSDictionary *r = [usage objectForKey:k];
            [self printLine:[NSString stringWithFormat:@"  %@  in %@  out %@  %@ calls  %@", k, [self tokenText:[[r objectForKey:@"input"] intValue]], [self tokenText:[[r objectForKey:@"output"] intValue]],
                [r objectForKey:@"calls"], [r objectForKey:@"cost"] ? [NSString stringWithFormat:@"$%.4f", [[r objectForKey:@"cost"] doubleValue]] : @"unpriced"]];
        }
        if (![usage count]) [self printStyled:@"  nothing used yet" style:@"gray"];
    } else if ([cmd isEqualToString:@"/context"])
        [self printLine:[NSString stringWithFormat:@"  about %@ tokens in the last request, %lu messages", [self tokenText:[core contextTokensForChat:chat]], (unsigned long)[[chat objectForKey:@"messages"] count]]];
    else if ([cmd isEqualToString:@"/rename"]) {
        if ([arg length]) { [chat setObject:arg forKey:@"title"]; [chat setObject:[NSNumber numberWithBool:NO] forKey:@"autoTitle"]; [core save]; }
    } else if ([cmd isEqualToString:@"/delete"]) {
        NSMutableDictionary *c = [arg length] ? [self pickChat:arg] : chat;
        if (c) { [core deleteChat:c]; [self printStyled:@"  deleted" style:@"gray"]; if (c == chat) [core newChat]; }
    } else if ([cmd isEqualToString:@"/fork"]) {
        NSMutableDictionary *f = [core forkChat:chat upTo:[arg length] ? [arg intValue] : (int)[[chat objectForKey:@"messages"] count]];
        if (f) { [core setCurrentChat:f]; [self printStyled:[NSString stringWithFormat:@"  forked as chat %@", [f objectForKey:@"id"]] style:@"gray"]; }
    } else if ([cmd isEqualToString:@"/export"]) [self exportTo:arg];
    else if ([cmd isEqualToString:@"/copy"]) [self copyLast];
    else if ([cmd isEqualToString:@"/retry"]) {
        problem = [core resend];
        if (problem) [self printStyled:problem style:@"red"];
        else [self watchTurn];
    } else if ([cmd isEqualToString:@"/workspace"]) {
        if ([arg length]) { [core openWorkspace:arg]; [core newChat]; [self printStyled:[NSString stringWithFormat:@"  workspace %@", [core workspace]] style:@"gray"]; }
        else [self printLine:[NSString stringWithFormat:@"  %@  (all: %@)", [core workspace], [[core workspaceNames] componentsJoinedByString:@", "]]];
    } else if ([cmd isEqualToString:@"/status"]) {
        [self printLine:[NSString stringWithFormat:@"  %@", [self statusLine]]];
        [self printLine:[NSString stringWithFormat:@"  workspace %@ · chat %@ · %@", [core workspace], [chat objectForKey:@"id"], [[NSFileManager defaultManager] currentDirectoryPath]]];
        if (projectNote) [self printLine:[NSString stringWithFormat:@"  instructions: %@", projectNote]];
        if ([core liveLeaseNoteForChat:chat]) [self printStyled:[NSString stringWithFormat:@"  %@", [core liveLeaseNoteForChat:chat]] style:@"yellow"];
    } else if ([cmd isEqualToString:@"/verbose"]) { verbose = !verbose; [config setObject:[NSNumber numberWithBool:verbose] forKey:@"verbose"]; [self saveConfig]; [self printStyled:verbose ? @"  tool output in full" : @"  tool output short" style:@"gray"]; }
    else if ([cmd isEqualToString:@"/thinking"]) { showThinking = !showThinking; [config setObject:[NSNumber numberWithBool:showThinking] forKey:@"showThinking"]; [self saveConfig]; [self printStyled:showThinking ? @"  thinking shown" : @"  thinking hidden" style:@"gray"]; }
    else if ([cmd isEqualToString:@"/bell"]) { bell = !bell; [config setObject:[NSNumber numberWithBool:bell] forKey:@"bell"]; [self saveConfig]; [self printStyled:bell ? @"  bell on" : @"  bell off" style:@"gray"]; }
    else if ([cmd isEqualToString:@"/instructions"]) [self printLine:projectNote ? [NSString stringWithFormat:@"  %@", projectNote] : @"  none (TIGERBUILD.md, AGENTS.md or CLAUDE.md in this folder or above)"];
    else if ([cmd isEqualToString:@"/diff"]) [self runTurnWithText:@"Show me what has changed in this git repository (git status and git diff) and summarise it."];
    else if ([cmd isEqualToString:@"/commit"]) [self runTurnWithText:[NSString stringWithFormat:@"Look at the git changes in this folder and commit them with a clear message.%@", [arg length] ? [@" " stringByAppendingString:arg] : @""]];
    else if ([cmd isEqualToString:@"/review"]) [self runTurnWithText:[NSString stringWithFormat:@"Review the uncommitted changes in this git repository for bugs and problems. Do not change anything.%@", [arg length] ? [@" " stringByAppendingString:arg] : @""]];
    else if ([cmd isEqualToString:@"/doctor"]) {
        NSArray *providers = [[ModelCatalog shared] providers];
        unsigned i;
        [core refreshCatalog];
        for (i = 0; i < [providers count]; i++) {
            NSString *p = [[providers objectAtIndex:i] objectForKey:@"id"];
            [self printLine:[NSString stringWithFormat:@"  %@ %@", [core providerUsable:p] ? [term styled:@"ok " with:@"green"] : [term styled:@"-- " with:@"gray"], [[ModelCatalog shared] titleForProvider:p]]];
        }
        [self printLine:[NSString stringWithFormat:@"  commander: %@", [[core commanderProblem] length] ? [core commanderProblem] : @"ok"]];
        [self printLine:[NSString stringWithFormat:@"  sudo: %@", TBSudoSocketPath() ? @"administrator mode is on and served from here; /tools sudo on lets a chat use it" : @"not available here (administrator mode is off, or this is an ssh session)"]];
    } else if ([cmd isEqualToString:@"/wakes"]) {
        if ([arg length]) {
            int n = [arg intValue];
            if (n < 0 || n > 100 || (n == 0 && ![arg isEqualToString:@"0"])) { [self printStyled:@"  0 to 100" style:@"red"]; return YES; }
            /* the setting lives in the application's preferences, so the window sees it too */
            CFPreferencesSetAppValue(CFSTR("TBTool.bg_wake_limit"), (CFNumberRef)[NSNumber numberWithInt:n], CFSTR("local.tigerbuild.TigerBuild"));
            CFPreferencesAppSynchronize(CFSTR("local.tigerbuild.TigerBuild"));
        }
        [self printStyled:[NSString stringWithFormat:@"  a finished background task wakes a chat up to %d times in a row without you writing%@", [TBIntegrations backgroundWakeLimit], [TBIntegrations backgroundWakeLimit] ? @"" : @" (never)"] style:@"gray"];
    } else if ([cmd isEqualToString:@"/bg"]) {
        NSArray *p = [arg componentsSeparatedByString:@" "];
        if ([[p objectAtIndex:0] isEqualToString:@"stop"] && [p count] > 1)
            [self printStyled:[TBBackground stop:[p objectAtIndex:1]] ? @"  stopped" : @"  not running" style:@"gray"];
        else
            [self printLine:[@"  " stringByAppendingString:[[[TBBackground list] componentsSeparatedByString:@"\n"] componentsJoinedByString:@"\n  "]]];
    } else if ([cmd isEqualToString:@"/hooks"]) [self hooksCommand:arg];
    else if ([cmd isEqualToString:@"/mcp"]) [self mcpCommand:arg];
    else if ([cmd isEqualToString:@"/undo"])
        [self printStyled:[NSString stringWithFormat:@"  %@", [self undoLast]] style:@"gray"];
    else if ([cmd isEqualToString:@"/compact"]) {
        problem = [core compact];
        if (problem) [self printStyled:[NSString stringWithFormat:@"  %@", problem] style:@"gray"];
        else [self watchTurn];
    } else if ([cmd isEqualToString:@"/init"])
        [self runTurnWithText:@"Look around this folder and write a TIGERBUILD.md here: what the project is, how to build and test it, and the conventions to follow. Keep it short."];
    else if (![self runCustomCommand:cmd arguments:arg]) {
        [self printStyled:[NSString stringWithFormat:@"  unknown command %@ (/help)", cmd] style:@"red"];
    }
    return YES;
}

@end
