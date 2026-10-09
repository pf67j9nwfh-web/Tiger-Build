/* The web page reader, the knowledge folder and its path checks: localtoolstest (from tiger-build/; reads a page only when TB_TEST_PAGE is set) */
#import <Foundation/Foundation.h>
#import "TBLocalTools.h"
#import "TBSkills.h"
#import "TBModelProfiles.h"
#import "TBEngine.h"

static int failures = 0;
static void expectThat(BOOL ok, NSString *name)
{
    fprintf(stderr, "%s %s\n", ok ? "PASS" : "FAIL", [name UTF8String]);
    if (!ok)
        failures++;
}


int main(int argc, char **argv)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:@"tb-knowledge-test"];
    NSFileManager *m = [NSFileManager defaultManager];
    NSString *text, *reason;
    [m removeFileAtPath:root handler:nil];
    [m createDirectoryAtPath:root attributes:nil];
    [m createDirectoryAtPath:[root stringByAppendingPathComponent:@"sub"] attributes:nil];
    [@"The lighthouse at Point Reyes was built in 1870 and uses a Fresnel lens.\nKeepers lived in cottages nearby.\n" writeToFile:[root stringByAppendingPathComponent:@"lighthouse.txt"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    [@"# Recipes\nSourdough bread needs flour, water, salt and a starter.\n" writeToFile:[root stringByAppendingPathComponent:@"sub/bread.md"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    [@"Tax notes: file by April.\n" writeToFile:[root stringByAppendingPathComponent:@".hidden.txt"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
    symlink("/etc/hosts", [[root stringByAppendingPathComponent:@"linked.txt"] fileSystemRepresentation]);

    text = [TBLocalTools knowledgeSearch:@"fresnel lens lighthouse" root:root];
    expectThat([text hasPrefix:@"[1] lighthouse.txt"], @"knowledge: the best passage comes first, with its file");
    text = [TBLocalTools knowledgeSearch:@"sourdough starter" root:root];
    expectThat([text rangeOfString:@"sub/bread.md"].location != NSNotFound, @"knowledge: files in folders are found");
    text = [TBLocalTools knowledgeSearch:@"april taxes" root:root];
    expectThat([text rangeOfString:@"Nothing in the knowledge folder matches"].location != NSNotFound, @"knowledge: hidden files are not indexed");
    expectThat([[TBLocalTools knowledgeOpen:@"sub/bread.md" root:root] hasPrefix:@"# Recipes"], @"knowledge: a whole file opens");
    reason = nil;
    @try { [TBLocalTools knowledgeOpen:@"../../etc/hosts" root:root]; } @catch (NSException *e) { reason = [e reason]; }
    expectThat(reason != nil, @"knowledge: a path with .. is refused");
    reason = nil;
    @try { [TBLocalTools knowledgeOpen:@"/etc/hosts" root:root]; } @catch (NSException *e) { reason = [e reason]; }
    expectThat(reason != nil, @"knowledge: an absolute path is refused");
    reason = nil;
    @try { [TBLocalTools knowledgeOpen:@"linked.txt" root:root]; } @catch (NSException *e) { reason = [e reason]; }
    expectThat(reason != nil, @"knowledge: a link that points outside is refused");
    reason = nil;
    @try { [TBLocalTools knowledgeSearch:@"anything" root:@"/nonexistent/folder"]; } @catch (NSException *e) { reason = [e reason]; }
    expectThat(reason != nil, @"knowledge: a missing folder is reported");

    text = [TBLocalTools htmlToText:@"<html><head><title>T</title><style>p{color:red}</style><script>var x=1;</script></head><body><h1>Head &amp; shoulders</h1><!-- hidden --><p>One</p><p>Two&nbsp;words &#233;</p></body></html>"];
    expectThat([text rangeOfString:@"Head & shoulders"].location != NSNotFound && [text rangeOfString:@"var x"].location == NSNotFound && [text rangeOfString:@"color:red"].location == NSNotFound && [text rangeOfString:@"hidden"].location == NSNotFound, @"html to text: scripts, styles and comments gone, entities decoded");
    expectThat([text rangeOfString:@"One\nTwo"].location != NSNotFound || [text rangeOfString:@"One\n\nTwo"].location != NSNotFound, @"html to text: paragraphs are on their own lines");
    reason = nil;
    @try { [TBLocalTools readPage:@"http://127.0.0.1:1/" run:nil]; } @catch (NSException *e) { reason = [e reason]; }
    expectThat([reason rangeOfString:@"public"].location != NSNotFound, @"read page: a private address is refused");
    reason = nil;
    @try { [TBLocalTools readPage:@"file:///etc/hosts" run:nil]; } @catch (NSException *e) { reason = [e reason]; }
    expectThat(reason != nil, @"read page: only http and https");
    [m removeFileAtPath:root handler:nil];
    fprintf(stderr, failures ? "%d FAILED\n" : "all passed\n", failures);
    {
        NSString *home = [NSTemporaryDirectory() stringByAppendingPathComponent:@"tb-skills-home"];
        NSString *folder;
        [m removeFileAtPath:home handler:nil];
        [m createDirectoryAtPath:home attributes:nil];
        [[NSUserDefaults standardUserDefaults] setObject:[home stringByAppendingPathComponent:@"skills"] forKey:@"TBSkillsRoot"];
        expectThat([[TBSkills all] count] == 0 && [TBSkills systemNote] == nil, @"skills: none to begin with, nothing said to the model");
        expectThat([TBSkills createNamed:@"Tax Prep" description:@"Help with the tax forms" body:@"Ask for the W-2 first."], @"skills: a skill can be created");
        folder = [[TBSkills root] stringByAppendingPathComponent:@"Tax-Prep"];
        [@"Line 14 is the total." writeToFile:[folder stringByAppendingPathComponent:@"guide.txt"] atomically:NO encoding:NSUTF8StringEncoding error:NULL];
        expectThat([[[TBSkills all] objectAtIndex:0] objectForKey:@"description"] != nil && [[TBSkills systemNote] rangeOfString:@"Tax-Prep: Help with the tax forms"].location != NSNotFound, @"skills: the note lists name and description");
        text = [TBSkills load:@"tax-prep"];
        expectThat([text hasPrefix:@"Ask for the W-2 first."] && [text rangeOfString:@"- guide.txt"].location != NSNotFound, @"skills: load gives the instructions and the other files");
        expectThat([[TBSkills readFile:@"guide.txt" ofSkill:@"Tax-Prep"] hasPrefix:@"Line 14"], @"skills: a file of the skill can be read");
        reason = nil;
        @try { [TBSkills readFile:@"../../../etc/hosts" ofSkill:@"Tax-Prep"]; } @catch (NSException *e) { reason = [e reason]; }
        expectThat(reason != nil, @"skills: a path that climbs out is refused");
        reason = nil;
        symlink("/etc/hosts", [[folder stringByAppendingPathComponent:@"link.txt"] fileSystemRepresentation]);
        @try { [TBSkills readFile:@"link.txt" ofSkill:@"Tax-Prep"]; } @catch (NSException *e) { reason = [e reason]; }
        expectThat(reason != nil, @"skills: a link that leaves the folder is refused");
        [TBSkills setName:@"Tax-Prep" enabled:NO];
        reason = nil;
        @try { [TBSkills load:@"Tax-Prep"]; } @catch (NSException *e) { reason = [e reason]; }
        expectThat(reason != nil && [TBSkills systemNote] == nil, @"skills: a switched-off skill cannot be loaded or listed");
        [TBSkills setName:@"Tax-Prep" enabled:YES];
        expectThat([[[TBSkills parse:@"---\nname: x\ndescription: \"quoted: yes\"\n---\nBody"] objectForKey:@"description"] isEqualToString:@"quoted: yes"], @"skills: header values may be quoted");
    }
    {
        NSString *file = [NSTemporaryDirectory() stringByAppendingPathComponent:@"tb-notes-test.plist"];
        NSArray *keys = [NSArray arrayWithObjects:@"claude|claude-haiku-5-5", @"claude|claude-opus-5-5", @"gemini|gemini-x", nil];
        NSString *line;
        [m removeFileAtPath:file handler:nil];
        [[NSUserDefaults standardUserDefaults] setObject:file forKey:@"TBModelNotesPath"];
        line = [TBModelProfiles lineForProvider:@"claude" model:@"claude-haiku-5-5" title:@"Haiku 5.5" vision:YES context:200000 price:[NSNumber numberWithDouble:6.0]];
        expectThat([line hasPrefix:@"claude|claude-haiku-5-5|Haiku 5.5; "] && [line rangeOfString:@"fast and inexpensive"].location != NSNotFound && [line rangeOfString:@"sees pictures"].location != NSNotFound && [line rangeOfString:@"200k context"].location != NSNotFound && [line rangeOfString:@"$6.00"].location != NSNotFound, @"model notes: a line is made at once from what the app knows");
        expectThat([[TBModelProfiles lineForProvider:@"claude" model:@"claude-opus-5-5" title:@"Opus 5.5" vision:NO context:0 price:nil] rangeOfString:@"most capable tier"].location != NSNotFound, @"model notes: name hints");
        expectThat([[TBModelProfiles keysNeedingNotes:keys] count] == 3, @"model notes: all three need notes at first");
        [TBModelProfiles storeReply:@"claude|claude-haiku-5-5|Quick, cheap, good for short answers\nnot a line\nother|model|ignored" asked:keys];
        expectThat([[TBModelProfiles noteForKey:@"claude|claude-haiku-5-5"] hasPrefix:@"Quick, cheap"] && [[TBModelProfiles noteForKey:@"other|model"] length] == 0, @"model notes: stored for asked models only");
        expectThat([[TBModelProfiles keysNeedingNotes:keys] count] == 0, @"model notes: unanswered ones are not asked again for a week");
        expectThat([[TBModelProfiles lineForProvider:@"claude" model:@"claude-haiku-5-5" title:@"Haiku 5.5" vision:NO context:0 price:nil] hasSuffix:@"Quick, cheap, good for short answers"], @"model notes: the note rides on the line");
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"TBModelNotesPath"];
        [m removeFileAtPath:file handler:nil];
    }
    [pool release];
    return failures ? 1 : 0;
}
