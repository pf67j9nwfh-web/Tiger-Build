#import "CMCore.h"
#import <sys/stat.h>

/* git and Subversion, for the programs this Mac has. git is not part of Mac OS X before Lion and Subversion arrives with 10.5, so each
   tool says plainly when the program is missing. Nothing goes through a shell: the arguments reach the program as they are, only the
   sub-commands below are allowed, and options that make a program run another program or write to a path of its choosing are refused.
   The read tools never change anything; the write tools are separate so that Tiger Build can ask before they run. */

static NSArray *list(NSString *words)
{
    return [words componentsSeparatedByString:@" "];
}

static NSArray *gitRead(void) { return list(@"status diff log show blame annotate branch remote ls-files ls-tree rev-parse rev-list describe tag stash shortlog grep cat-file config reflog diff-tree name-rev merge-base whatchanged count-objects version check-ignore show-ref for-each-ref"); }
static NSArray *gitWrite(void) { return list(@"add rm mv restore checkout switch commit branch tag merge rebase cherry-pick revert reset stash pull fetch push clone init remote config clean apply"); }
static NSArray *svnRead(void) { return list(@"status stat st diff di log info list ls cat blame annotate praise propget pg proplist pl help"); }
static NSArray *svnWrite(void) { return list(@"add delete del rm remove commit ci update up revert move mv copy cp mkdir checkout co switch sw merge resolve resolved propset ps propdel pd import cleanup lock unlock patch"); }
static NSArray *gitBad(void) { return list(@"--upload-pack --receive-pack --exec --exec-path --output -o --ext-diff --paginate --open-files-in-pager --git-dir --work-tree --namespace -c --config --template --ssh-command --no-verify --force -f --force-with-lease --force-if-includes --mirror --delete --prune"); }
static NSArray *gitConfigAllowed(void) { return list(@"user.name user.email core.autocrlf core.filemode core.ignorecase pull.rebase init.defaultbranch push.default color.ui core.safecrlf core.quotepath"); }
static NSArray *svnBad(void) { return list(@"--password --diff-cmd --diff3-cmd --editor-cmd --merge-cmd --config-option --config-dir --ssl-trust-server-cert --trust-server-cert"); }

static NSString *trimmed(NSString *s)
{
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *directoryFor(NSDictionary *args)
{
    NSString *raw = CMOptString(args, @"path", nil), *path;
    BOOL isDir = NO;
    if (![raw length])
        raw = [CMWorkspaceRoot() length] ? CMWorkspaceRoot() : NSHomeDirectory();
    path = CMCheckPath(raw);
    if (!([[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir] && isDir))
        CMFail(@"not a directory: %@", path);
    return path;
}

static NSArray *argumentList(NSDictionary *args)
{
    NSArray *items;
    unsigned i;
    if (![[args objectForKey:@"args"] isKindOfClass:[NSArray class]])
        CMFail(@"args must be an array of strings, for example [\"status\", \"--short\"]");
    items = CMStringList([args objectForKey:@"args"]);
    if (![items count])
        CMFail(@"args is empty; the first item is the sub-command");
    if ([items count] > 60)
        CMFail(@"too many arguments");
    for (i = 0; i < [items count]; i++)
        if (strlen([[items objectAtIndex:i] UTF8String]) != [[[items objectAtIndex:i] dataUsingEncoding:NSUTF8StringEncoding] length])
            CMFail(@"arguments cannot contain a null character");
    return items;
}

/* git and svn take any unique start of a long option (--upload-p, --ex), and a short option can have its value attached (-xCMD), so a name
   is refused when it starts a blocked one, and the short forms that run programs are listed here too */
static void checkOptions(NSArray *items, NSArray *bad, NSString *program)
{
    unsigned i, b;
    NSString *sub = [items objectAtIndex:0];
    for (i = 1; i < [items count]; i++) {
        NSString *item = [items objectAtIndex:i], *name = [[item componentsSeparatedByString:@"="] objectAtIndex:0];
        BOOL refuse = [bad containsObject:name];
        if ([item isEqualToString:@"--"])
            break;
        if (!refuse && [name hasPrefix:@"--"] && [name length] >= 4)
            for (b = 0; b < [bad count]; b++)
                if ([[bad objectAtIndex:b] hasPrefix:name])
                    refuse = YES;
        if (!refuse && [program isEqualToString:@"git"] && ([sub isEqualToString:@"rebase"] || [sub isEqualToString:@"clone"]) && [item hasPrefix:@"-"] && ![item hasPrefix:@"--"]
            && ([item hasPrefix:@"-x"] || [item hasPrefix:@"-u"] || [item hasPrefix:@"-c"] || [item hasPrefix:@"-o"]))
            refuse = YES;
        /* git grep -O<command> runs the command as the pager; the letter can sit inside a bundle of short options (-nOcmd) */
        if (!refuse && [program isEqualToString:@"git"] && [sub isEqualToString:@"grep"] && [item hasPrefix:@"-"] && ![item hasPrefix:@"--"] && [item rangeOfString:@"O"].location != NSNotFound)
            refuse = YES;
        if (refuse)
            CMFail(@"%@ is not allowed with this tool (%@). Ask the person to run it themselves.", item, program);
    }
}

/* paths named as plain arguments must stay inside the allowed directories */
static void checkPaths(NSArray *items, NSString *cwd)
{
    BOOL after = NO;
    unsigned i;
    for (i = 1; i < [items count]; i++) {
        NSString *item = [items objectAtIndex:i], *full;
        if ([item isEqualToString:@"--"]) {
            after = YES;
            continue;
        }
        if ([item hasPrefix:@"-"] && !after) {
            /* --option=/path: the path part is checked like any other */
            NSRange eq = [item rangeOfString:@"="];
            if (eq.location != NSNotFound && ([item hasPrefix:@"--"])) {
                NSString *value = [item substringFromIndex:eq.location + 1], *full;
                if ([value hasPrefix:@"/"] || [value hasPrefix:@"~"] || [value rangeOfString:@".."].location != NSNotFound) {
                    full = [value stringByExpandingTildeInPath];
                    if (![full isAbsolutePath])
                        full = [cwd stringByAppendingPathComponent:full];
                    if (!CMPathAllowed(CMResolve(full)))
                        CMFail(@"%@ is outside the directories this chat may use", item);
                }
            }
            continue;
        }
        if ([item rangeOfString:@"/"].location == NSNotFound && [item rangeOfString:@".."].location == NSNotFound)
            continue;
        if ([item hasPrefix:@"http:"] || [item hasPrefix:@"https:"] || [item rangeOfString:@"://"].location != NSNotFound || [item rangeOfString:@"@"].location != NSNotFound)
            continue;
        if ([item rangeOfString:@".."].location != NSNotFound || [item hasPrefix:@"/"] || [item hasPrefix:@"~"]) {
            full = [item stringByExpandingTildeInPath];
            if (![full isAbsolutePath])
                full = [cwd stringByAppendingPathComponent:full];
            if (!CMPathAllowed(CMResolve(full)))
                CMFail(@"%@ is outside the directories this chat may use", item);
        }
    }
}

static NSString *finish(NSString *program, NSArray *items, int code, NSString *output, NSString *note)
{
    NSString *text = output;
    if ([text length] > 180000)
        text = [[text substringToIndex:180000] stringByAppendingString:@"\n... truncated at 180000 characters"];
    if (code == -1)
        CMFail(@"%@ %@ did not finish in time and was stopped.\n%@", program, [items objectAtIndex:0], CMClip(text, 2000));
    if (code != 0)
        CMFail(@"%@ %@ failed (exit %d):\n%@", program, [items objectAtIndex:0], code, text);
    if (![trimmed(text) length])
        text = [NSString stringWithFormat:@"(no output; %@ %@ finished)", program, [items objectAtIndex:0]];
    if ([note length])
        text = [text stringByAppendingFormat:@"\n%@", note];
    return text;
}

static NSString *missing(NSString *kind)
{
    if ([kind isEqualToString:@"git"])
        return @"git is not installed on this Mac. Mac OS X does not include it before 10.7 Lion. Install a build for this system (for example from MacPorts or a git installer for 10.5/10.6), then try again. Subversion (svn_read, svn_write) may be available instead.";
    return @"svn (Subversion) is not installed on this Mac. It comes with Mac OS X 10.5 and later; on 10.4 Tiger install it (for example from MacPorts). git_read and git_write may be available instead.";
}

/* for sub-commands that read or change depending on the options: YES when this is a read */
static BOOL gitQueryOnly(NSArray *items)
{
    NSString *sub = [items objectAtIndex:0];
    NSMutableArray *rest = [NSMutableArray arrayWithArray:items], *plain = [NSMutableArray array];
    unsigned i;
    [rest removeObjectAtIndex:0];
    for (i = 0; i < [rest count]; i++)
        if (![[rest objectAtIndex:i] hasPrefix:@"-"])
            [plain addObject:[rest objectAtIndex:i]];
    if ([sub isEqualToString:@"branch"]) {
        BOOL listing = NO;
        for (i = 0; i < [rest count]; i++) {
            if ([list(@"-d -D -m -M -c -C --delete --move --copy -u --set-upstream-to --unset-upstream --edit-description -f") containsObject:[rest objectAtIndex:i]])
                return NO;
            if ([list(@"-a -r -v -vv --list -l --show-current --contains --merged --no-merged --all --remotes --verbose") containsObject:[rest objectAtIndex:i]])
                listing = YES;
        }
        return [plain count] == 0 || listing;
    }
    if ([sub isEqualToString:@"remote"]) {
        if (![rest count])
            return YES;
        return [list(@"-v --verbose show get-url") containsObject:[rest objectAtIndex:0]];
    }
    if ([sub isEqualToString:@"tag"]) {
        if (![plain count])
            return YES;
        for (i = 0; i < [rest count]; i++)
            if ([list(@"-l --list --contains --merged --no-merged -n") containsObject:[rest objectAtIndex:i]])
                return YES;
        return NO;
    }
    if ([sub isEqualToString:@"stash"])
        return [rest count] > 0 && [list(@"list show") containsObject:[rest objectAtIndex:0]];
    if ([sub isEqualToString:@"config"]) {
        for (i = 0; i < [rest count]; i++)
            if ([list(@"--get --get-all --list -l --get-regexp --show-origin") containsObject:[rest objectAtIndex:i]])
                return YES;
        return NO;
    }
    return YES;
}

static BOOL hasMessage(NSArray *items, NSArray *flags)
{
    unsigned i;
    for (i = 0; i < [items count]; i++) {
        NSString *item = [items objectAtIndex:i];
        if ([flags containsObject:item] || [item hasPrefix:@"--message="] || [item hasPrefix:@"-m"])
            return YES;
    }
    return NO;
}

id CMToolGit(NSDictionary *args, BOOL writing)
{
    NSString *cwd = directoryFor(args), *sub, *program, *output = nil;
    NSArray *items = argumentList(args), *allowed = writing ? gitWrite() : gitRead();
    NSMutableArray *full = [NSMutableArray array];
    NSDictionary *env;
    double timeout;
    int code;
    NSString *note = @"";
    sub = [items objectAtIndex:0];
    if (![allowed containsObject:sub]) {
        if (writing && [gitRead() containsObject:sub])
            CMFail(@"git %@ only reads; use git_read for it", sub);
        if (!writing && [gitWrite() containsObject:sub])
            CMFail(@"git %@ can change the repository; use git_write for it", sub);
        CMFail(@"git %@ is not available. Allowed: %@", sub, [allowed componentsJoinedByString:@" "]);
    }
    if (!writing && !gitQueryOnly(items))
        CMFail(@"git %@ with those options changes the repository; use git_write", sub);
    checkOptions(items, gitBad(), @"git");
    if ([sub isEqualToString:@"rebase"] && ([items containsObject:@"-i"] || [items containsObject:@"--interactive"]))
        CMFail(@"interactive rebase needs an editor and cannot run here");
    if ([sub isEqualToString:@"commit"] && !hasMessage(items, list(@"-m --message -F --file -C --reuse-message --amend")))
        CMFail(@"give the commit message with -m \"message\"; there is no editor here");
    if ([sub isEqualToString:@"config"] && writing) {
        NSMutableArray *plain = [NSMutableArray array];
        unsigned i;
        for (i = 1; i < [items count]; i++)
            if (![[items objectAtIndex:i] hasPrefix:@"-"])
                [plain addObject:[items objectAtIndex:i]];
        if (![plain count] || ![gitConfigAllowed() containsObject:[[plain objectAtIndex:0] lowercaseString]])
            CMFail(@"only these settings can be changed: %@", [gitConfigAllowed() componentsJoinedByString:@" "]);
    }
    checkPaths(items, cwd);
    program = CMFindProgram(@"git");
    if (!program)
        CMFail(@"%@", missing(@"git"));
    [full addObject:program];
    [full addObject:@"-c"];
    [full addObject:@"protocol.ext.allow=never"];   /* ext:: addresses run programs */
    [full addObject:sub];
    if ([list(@"diff log show whatchanged") containsObject:sub])
        [full addObject:@"--no-ext-diff"];
    [full addObjectsFromArray:[items subarrayWithRange:NSMakeRange(1, [items count] - 1)]];
    env = [NSDictionary dictionaryWithObjectsAndKeys:@"0", @"GIT_TERMINAL_PROMPT", @"true", @"GIT_EDITOR", @"cat", @"GIT_PAGER", @"cat", @"PAGER", @"/usr/bin/true", @"GIT_ASKPASS",
        @"", @"GIT_EXTERNAL_DIFF", @"C", @"LANG", @"C", @"LC_ALL", @"dumb", @"TERM", nil];
    timeout = CMOptInteger(args, @"timeout_ms", 60000) / 1000.0;
    if (timeout > 300)
        timeout = 300;
    code = CMRunProgram(full, cwd, timeout, env, &output);
    if (code != 0 && [output rangeOfString:@"not a git repository"].location != NSNotFound)
        note = @"Tip: use repo_info to see which folders are repositories.";
    return finish(@"git", items, code, output, note);
}

id CMToolSvn(NSDictionary *args, BOOL writing)
{
    NSString *cwd = directoryFor(args), *sub, *program, *output = nil, *note = @"";
    NSArray *items = argumentList(args), *allowed = writing ? svnWrite() : svnRead();
    NSMutableArray *full;
    NSDictionary *env;
    double timeout;
    int code;
    sub = [items objectAtIndex:0];
    if (![allowed containsObject:sub]) {
        if (writing && [svnRead() containsObject:sub])
            CMFail(@"svn %@ only reads; use svn_read for it", sub);
        if (!writing && [svnWrite() containsObject:sub])
            CMFail(@"svn %@ can change files or the repository; use svn_write for it", sub);
        CMFail(@"svn %@ is not available. Allowed: %@", sub, [allowed componentsJoinedByString:@" "]);
    }
    checkOptions(items, svnBad(), @"svn");
    if (([sub isEqualToString:@"commit"] || [sub isEqualToString:@"ci"]) && !hasMessage(items, list(@"-m --message -F --file")))
        CMFail(@"give the commit message with -m \"message\"; there is no editor here");
    checkPaths(items, cwd);
    program = CMFindProgram(@"svn");
    if (!program)
        CMFail(@"%@", missing(@"svn"));
    full = [NSMutableArray arrayWithObjects:program, sub, @"--non-interactive", nil];
    [full addObjectsFromArray:[items subarrayWithRange:NSMakeRange(1, [items count] - 1)]];
    env = [NSDictionary dictionaryWithObjectsAndKeys:@"C", @"LANG", @"C", @"LC_ALL", @"dumb", @"TERM", @"/usr/bin/true", @"SVN_EDITOR", nil];
    timeout = CMOptInteger(args, @"timeout_ms", 90000) / 1000.0;
    if (timeout > 300)
        timeout = 300;
    code = CMRunProgram(full, cwd, timeout, env, &output);
    if (code != 0 && [output rangeOfString:@"doesn't accept option '--non-interactive'"].location != NSNotFound) {
        /* Subversion 1.4 takes the option only for commands that use the network */
        full = [NSMutableArray arrayWithObjects:program, sub, nil];
        [full addObjectsFromArray:[items subarrayWithRange:NSMakeRange(1, [items count] - 1)]];
        code = CMRunProgram(full, cwd, timeout, env, &output);
    }
    if (code != 0 && [output rangeOfString:@"is not a working copy"].location != NSNotFound)
        note = @"Tip: use repo_info to see which folders are working copies.";
    return finish(@"svn", items, code, output, note);
}

id CMToolRepoInfo(NSDictionary *args)
{
    NSString *start = directoryFor(args), *git = CMFindProgram(@"git"), *svn = CMFindProgram(@"svn"), *folder = start, *found = @"", *kind = @"", *out = nil;
    NSMutableArray *lines = [NSMutableArray array];
    NSDictionary *c = [NSDictionary dictionaryWithObject:@"C" forKey:@"LANG"];
    BOOL isDir;
    if (git) {
        CMRunProgram([NSArray arrayWithObjects:git, @"--version", nil], nil, 10, c, &out);
        [lines addObject:[NSString stringWithFormat:@"git program: %@ (%@)", git, trimmed(out)]];
    } else
        [lines addObject:@"git program: not installed"];
    if (svn) {
        CMRunProgram([NSArray arrayWithObjects:svn, @"--version", @"--quiet", nil], nil, 10, c, &out);
        [lines addObject:[NSString stringWithFormat:@"svn program: %@ (version %@)", svn, trimmed(out)]];
    } else
        [lines addObject:@"svn program: not installed"];
    for (;;) {
        NSString *parent;
        if ([[NSFileManager defaultManager] fileExistsAtPath:[folder stringByAppendingPathComponent:@".git"]]) {
            found = folder;
            kind = @"git";
            break;
        }
        if ([[NSFileManager defaultManager] fileExistsAtPath:[folder stringByAppendingPathComponent:@".svn"] isDirectory:&isDir] && isDir) {
            found = folder;
            kind = @"svn";
            /* a Subversion 1.6 or older working copy has .svn in every folder; the top one is the highest that has it */
            parent = [folder stringByDeletingLastPathComponent];
            while (![parent isEqualToString:folder] && [[NSFileManager defaultManager] fileExistsAtPath:[parent stringByAppendingPathComponent:@".svn"] isDirectory:&isDir] && isDir) {
                folder = parent;
                found = folder;
                parent = [folder stringByDeletingLastPathComponent];
            }
            break;
        }
        parent = [folder stringByDeletingLastPathComponent];
        if ([parent isEqualToString:folder])
            break;
        folder = parent;
    }
    if (![found length]) {
        [lines addObject:[NSString stringWithFormat:@"%@ is not inside a git repository or a Subversion working copy", start]];
        return [lines componentsJoinedByString:@"\n"];
    }
    [lines addObject:[NSString stringWithFormat:@"repository type: %@", kind]];
    [lines addObject:[NSString stringWithFormat:@"top folder: %@", found]];
    if ([kind isEqualToString:@"git"] && git) {
        CMRunProgram([NSArray arrayWithObjects:git, @"status", @"--short", @"--branch", nil], found, 30,
            [NSDictionary dictionaryWithObjectsAndKeys:@"0", @"GIT_TERMINAL_PROMPT", @"C", @"LANG", @"cat", @"GIT_PAGER", nil], &out);
        [lines addObject:CMClip(trimmed(out), 3000)];
    }
    if ([kind isEqualToString:@"svn"] && svn) {
        CMRunProgram([NSArray arrayWithObjects:svn, @"info", @"--non-interactive", nil], found, 30, c, &out);
        [lines addObject:CMClip(trimmed(out), 1500)];
        CMRunProgram([NSArray arrayWithObjects:svn, @"status", @"--non-interactive", nil], found, 60, c, &out);
        [lines addObject:[@"changes:\n" stringByAppendingString:CMClip(trimmed(out), 2500)]];
    }
    return [lines componentsJoinedByString:@"\n"];
}
