#import "TBCLIApp.h"
#import "TBEngine.h"

@implementation TBCLIApp (Commands)

- (NSArray *)commandNames
{
    return [NSArray arrayWithObjects:@"/help", @"/exit", @"/quit", @"/new", @"/clear", @"/chats", @"/resume", @"/model", @"/models", @"/tools", @"/mode", @"/cost", @"/context",
        @"/rename", @"/delete", @"/fork", @"/export", @"/copy", @"/retry", @"/workspace", @"/status", @"/verbose", @"/thinking", @"/instructions", @"/allow", @"/deny",
        @"/doctor", @"/history", @"/diff", @"/commit", @"/review", @"/bell", nil];
}

- (void)table:(NSArray *)rows
{
    unsigned i;
    for (i = 0; i < [rows count]; i++)
        [self printLine:[rows objectAtIndex:i]];
}

- (void)help
{
    [self table:[NSArray arrayWithObjects:
        @"  /new                 start a new chat           /chats [text]       list or search chats",
        @"  /resume [id|text]    open a chat                /fork [n]           copy this chat (first n messages)",
        @"  /rename TITLE        rename                     /delete [id]        delete a chat",
        @"  /model [spec]        show or switch model       /models [provider]  list providers and models",
        @"  /tools [name on|off] tools; /tools NAME approve on|off",
        @"  /mode ask|edits|plan|auto   how much to ask     /allow RULE, /deny RULE   standing rules, e.g. start_process(git *)",
        @"  /cost  /context      spend and context size     /status             where things stand",
        @"  /retry               ask again                  /copy               last reply to the clipboard",
        @"  /export [file]       chat as Markdown           /history            the whole chat again",
        @"  /diff  /commit  /review   git helpers (the model does the work)",
        @"  /workspace [name]    list or switch workspace   /instructions       project files in use",
        @"  /verbose  /thinking  /bell  toggles             /doctor             check the set-up",
        @"  /exit                leave",
        @"  @path mentions a file or folder, !cmd runs a command, # note adds to TIGERBUILD.md, Shift-Tab changes the mode.", nil]];
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
        for (i = 0; i < [providers count]; i++) {
            NSString *p = [[providers objectAtIndex:i] objectForKey:@"id"];
            [self printLine:[NSString stringWithFormat:@"  %@ %@", [core providerUsable:p] ? [term styled:@"ok " with:@"green"] : [term styled:@"-- " with:@"gray"], [[ModelCatalog shared] titleForProvider:p]]];
        }
        [self printLine:[NSString stringWithFormat:@"  commander: %@", [core commanderProblem] ? [core commanderProblem] : @"ok"]];
    } else {
        [self printStyled:[NSString stringWithFormat:@"  unknown command %@ (/help)", cmd] style:@"red"];
    }
    return YES;
}

@end
