/* make test: checks the pieces of Tiger Build that do not need a window. */
#import <Foundation/Foundation.h>
#import "TBSupport.h"
#import "TBMarkup.h"
#import "TBEmoji.h"
#import "TBJSON.h"
#import <stdarg.h>
#import <unistd.h>

static int failures = 0;

/* A string from code points (0 ends the list), written out as UTF-16 because \U escapes do not work on Tiger. */
static NSString *tbcodes(int first, ...)
{
    NSMutableString *out = [NSMutableString string];
    int c = first;
    va_list args;
    va_start(args, first);
    while (c) {
        if (c >= 0x10000)
            [out appendFormat:@"%C%C", (unichar)(0xD800 + ((c - 0x10000) >> 10)), (unichar)(0xDC00 + ((c - 0x10000) & 0x3FF))];
        else
            [out appendFormat:@"%C", (unichar)c];
        c = va_arg(args, int);
    }
    va_end(args);
    return out;
}

static void tbcheck(BOOL ok, NSString *name)
{
    if (ok) {
        fprintf(stderr, "PASS %s\n", [name UTF8String]);
    } else {
        fprintf(stderr, "FAIL %s\n", [name UTF8String]);
        failures++;
    }
}

static BOOL overlaps(NSRect a, NSRect b)
{
    return NSIntersectsRect(a, b);
}

static void checkLayout(float w, float h, float wanted, float status, float thinking)
{
    TBChatLayout l = TBLayoutChatPane(w, h, wanted, status, thinking);
    NSString *tag = [NSString stringWithFormat:@"%.0fx%.0f field %.0f status %.0f think %.0f", w, h, wanted, status, thinking];
    float inputMid = NSMidY(l.input);
    float sendMid = NSMidY(l.send);
    tbcheck(l.fieldHeight >= TB_FIELD_MIN && l.fieldHeight <= TB_FIELD_MAX,
        [tag stringByAppendingString:@": field height clamped"]);
    tbcheck(NSHeight(l.input) == l.fieldHeight, [tag stringByAppendingString:@": input uses that height"]);
    /* The ghost Send button in Picture 7 came from this button moving. It
       must stay centred on the field (or pinned at the bottom margin). */
    tbcheck(fabsf(inputMid - sendMid) < 1.0f || NSMinY(l.send) == 10,
        [tag stringByAppendingString:@": send centred on field"]);
    tbcheck(fabsf(NSMidY(l.stop) - sendMid) < 0.5f, [tag stringByAppendingString:@": stop level with send"]);
    tbcheck(!overlaps(l.input, l.send) && !overlaps(l.input, l.stop) && !overlaps(l.stop, l.send),
        [tag stringByAppendingString:@": buttons beside field"]);
    tbcheck(NSMinY(l.transcript) >= NSMaxY(l.input), [tag stringByAppendingString:@": transcript above field"]);
    tbcheck(NSMaxX(l.send) <= w && NSMinX(l.input) >= 0, [tag stringByAppendingString:@": inside pane"]);
    tbcheck(!overlaps(l.transcript, l.send) && !overlaps(l.transcript, l.stop),
        [tag stringByAppendingString:@": buttons clear of transcript"]);
    tbcheck(NSMaxY(l.transcript) <= NSMinY(l.context) + 0.5f && NSMaxY(l.transcript) <= NSMinY(l.actions) + 0.5f,
        [tag stringByAppendingString:@": readout row above transcript"]);
    tbcheck(!overlaps(l.actions, l.context), [tag stringByAppendingString:@": actions clear of readout"]);
    if (thinking > 0) {
        tbcheck(!overlaps(l.thinking, l.transcript) && !overlaps(l.thinking, l.input),
            [tag stringByAppendingString:@": thinking strip clear"]);
        tbcheck(NSMinY(l.thinking) >= NSMaxY(l.input) && NSMaxY(l.thinking) <= NSMinY(l.transcript),
            [tag stringByAppendingString:@": thinking between transcript and field"]);
    }
    if (status > 0) {
        tbcheck(NSHeight(l.status) == (status > TB_STATUS_MAX ? TB_STATUS_MAX : status),
            [tag stringByAppendingString:@": status gets its height"]);
        tbcheck(NSWidth(l.status) == w - 16, [tag stringByAppendingString:@": status uses full width"]);
        tbcheck(!overlaps(l.status, l.context) && !overlaps(l.status, l.actions),
            [tag stringByAppendingString:@": status clear of readout"]);
        tbcheck(!overlaps(l.status, l.transcript), [tag stringByAppendingString:@": status clear of transcript"]);
        tbcheck(NSMaxY(l.status) <= h, [tag stringByAppendingString:@": status inside pane"]);
    }
}

int main(void)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    ModelCatalog *catalog;
    NSArray *chat;
    float wanted;

    for (wanted = 0; wanted <= 140; wanted += 8) {
        checkLayout(560, 600, wanted, 0, 0);
        checkLayout(400, 290, wanted, 0, 0);
        checkLayout(560, 600, wanted, 32, 36);
        checkLayout(480, 440, wanted, 64, 54);
        checkLayout(400, 360, wanted, 90, 54);
        checkLayout(820, 600, wanted, 0, 40);
    }

    tbcheck([TBJSONEscape(@"a\"b\\c\nd\te") isEqualToString:@"a\\\"b\\\\c\\nd\\te"], @"json escape");
    tbcheck([TBJSONEscape(nil) isEqualToString:@""], @"json nil");
    tbcheck([TBJSONEscape([NSString stringWithFormat:@"%C", (unichar)1]) isEqualToString:@"\\u0001"], @"json control");

    catalog = [[[ModelCatalog alloc] init] autorelease];
    tbcheck([catalog loadText:
        @"provider\tgrok\tGrok\nmodel\tgrok\tgrok-4.7\t4.7\t1\nmodel\tgrok\tgrok-4.3\t4.3\t0\n"
        @"provider\tclaude\tClaude\nmodel\tclaude\tclaude-opus-5\tOpus 5\t0\n"
        @"model\tclaude\tclaude-sonnet-5\tSonnet 5\t1\nprovider\tlocal\tLocal\n"], @"catalog parses");
    tbcheck([[catalog providers] count] == 3, @"catalog providers");
    tbcheck([[catalog defaultModelForProvider:@"claude"] isEqualToString:@"claude-sonnet-5"], @"catalog default");
    tbcheck([catalog hasModel:@"grok-4.3" forProvider:@"grok"], @"catalog has model");
    tbcheck(![catalog hasModel:@"grok-4.3" forProvider:@"claude"], @"catalog keeps providers apart");
    tbcheck([[catalog titleForProvider:@"local"] isEqualToString:@"Local"], @"catalog title");
    tbcheck([[catalog stateForProvider:@"grok"] isEqualToString:@"ok"], @"old list means ok");
    tbcheck([catalog providerUsable:@"claude"], @"provider with models usable");
    tbcheck([catalog loadText:
        @"provider\tgrok\tGrok\tnokey\nprovider\tclaude\tClaude\tok\n"
        @"model\tclaude\tclaude-sonnet-5\tSonnet 5\t1\t200000\n"
        @"provider\tlocal\tLocal\tok\nchecking\t3\n"], @"one key only");
    tbcheck(![catalog providerUsable:@"grok"], @"no key not usable");
    tbcheck([[catalog stateForProvider:@"grok"] isEqualToString:@"nokey"], @"no key state");
    tbcheck([catalog providerUsable:@"claude"], @"keyed provider usable");
    tbcheck([catalog checkingCount] == 3, @"checking count");
    tbcheck([catalog loadText:@"provider\tgrok\tGrok\tnokey\nprovider\tlocal\tLocal\tok\n"],
        @"local only list loads");
    tbcheck([[catalog modelsForProvider:@"grok"] count] == 0, @"local only has no cloud models");
    tbcheck(![catalog loadText:@"garbage"], @"catalog rejects garbage");
    tbcheck([[catalog providers] count] == 2, @"catalog keeps old list on bad text");

    chat = [NSArray arrayWithObjects:
        [NSDictionary dictionaryWithObjectsAndKeys:@"user", @"role", @"12345678", @"text", nil],
        [NSDictionary dictionaryWithObjectsAndKeys:@"status", @"role", @"ignored text here",
            @"text", [NSNumber numberWithBool:YES], @"status", nil],
        nil];
    {
        NSMutableDictionary *c = [NSMutableDictionary dictionary];
        tbcheck([TBCostReadout(c) length] == 0, @"no usage, no readout");
        TBAddUsage(c, [NSDictionary dictionaryWithObjectsAndKeys:@"local", @"provider", @"qwen", @"model",
            [NSNumber numberWithInt:100], @"input", [NSNumber numberWithInt:50], @"output", nil]);
        tbcheck([TBCostReadout(c) isEqualToString:@"Cost (est) N/A"], @"local only is N/A");
        TBAddUsage(c, [NSDictionary dictionaryWithObjectsAndKeys:@"claude", @"provider", @"sonnet", @"model",
            [NSNumber numberWithInt:1000], @"input", [NSNumber numberWithInt:200], @"output",
            [NSNumber numberWithDouble:0.0123], @"cost", nil]);
        tbcheck([TBCostReadout(c) isEqualToString:@"Cost (est) $0.0123+"], @"model switch keeps cloud cost, marks unpriced");
        TBAddUsage(c, [NSDictionary dictionaryWithObjectsAndKeys:@"claude", @"provider", @"sonnet", @"model",
            [NSNumber numberWithInt:1000], @"input", [NSNumber numberWithDouble:0.01], @"cost", nil]);
        tbcheck([[TBCostDetail(c) componentsSeparatedByString:@"\n"] count] >= 3, @"cost detail per model");
        tbcheck([TBFormatCost(0.0004) isEqualToString:@"<$0.001"], @"tiny cost");
        tbcheck([TBFormatCost(12.345) isEqualToString:@"$12.35"], @"cost rounds");
        tbcheck([TBFormatTokens(2500) isEqualToString:@"2.5k"], @"tokens format");
    }
    {
        NSDictionary *one = [NSDictionary dictionaryWithObjectsAndKeys:[NSArray array], @"chats", nil];
        NSDictionary *bundle = [NSDictionary dictionaryWithObjectsAndKeys:@"TigerBuild-history", @"format",
            [NSDictionary dictionaryWithObjectsAndKeys:one, @"Default", one, @"Work", nil], @"workspaces",
            @"Work", @"current", nil];
        NSDictionary *got = TBHistoryBundle(bundle, nil);
        tbcheck([[[got objectForKey:@"workspaces"] allKeys] count] == 2 && [[got objectForKey:@"bundle"] boolValue], @"bundle parses");
        tbcheck([[got objectForKey:@"current"] isEqualToString:@"Work"], @"bundle keeps current workspace");
        got = TBHistoryBundle(one, @"Imported");
        tbcheck([[[got objectForKey:@"workspaces"] allKeys] containsObject:@"Imported"] && ![[got objectForKey:@"bundle"] boolValue],
            @"old single-workspace export still imports");
        tbcheck(TBHistoryBundle([NSDictionary dictionaryWithObject:@"x" forKey:@"chats"], nil) == nil, @"bad chats rejected");
        tbcheck(TBHistoryBundle([NSDictionary dictionaryWithObjectsAndKeys:@"TigerBuild-history", @"format",
            [NSDictionary dictionaryWithObject:one forKey:@"../evil"], @"workspaces", nil], nil) == nil, @"bad workspace name rejected");
        tbcheck(TBWorkspaceNameOK(@"Project 1") && !TBWorkspaceNameOK(@".hidden") && !TBWorkspaceNameOK(@"a/b"), @"workspace names");
    }
    {
        /* Two windows on one workspace share one store; nothing is lost. */
        NSString *file = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"tbstore-%d.plist", (int)getpid()]];
        TBStore *a;
        TBStore *b;
        NSMutableDictionary *chatOne = [NSMutableDictionary dictionaryWithObjectsAndKeys:@"1", @"id", [NSMutableArray array], @"messages", nil];
        NSMutableDictionary *chatTwo = [NSMutableDictionary dictionaryWithObjectsAndKeys:@"2", @"id", [NSMutableArray array], @"messages", nil];
        [[NSFileManager defaultManager] removeFileAtPath:file handler:nil];
        a = [TBStore storeAtPath:file];
        b = [TBStore storeAtPath:file];
        tbcheck(a == b, @"two windows get the same store");
        tbcheck([a takeNextId] == 1 && [b takeNextId] == 2, @"chat numbers do not collide between windows");
        [[a chats] addObject:chatOne];
        [[b chats] addObject:chatTwo];
        tbcheck([[a chats] count] == 2, @"one window sees the other's new chat");
        [[a settings] setObject:@"x" forKey:@"k"];
        [a markDirty];
        [b markDirty];
        [TBStore flushAll];
        [TBStore forgetAll];
        a = [TBStore storeAtPath:file];
        fprintf(stderr, "INFO chats=%d next=%d\n", (int)[[a chats] count], [a next]);
        tbcheck([[a chats] count] == 2 && [a next] == 3, @"both windows' chats were saved");
        tbcheck([[[a settings] objectForKey:@"k"] isEqualToString:@"x"], @"settings were saved");
        tbcheck([TBStore storeAtPath:[file stringByAppendingString:@".other"]] != a, @"different workspaces get different stores");
        [TBStore forgetAll];
        [[NSFileManager defaultManager] removeFileAtPath:file handler:nil];
    }

    {
        NSArray *blocks = TBSplitBlocks(@"Here:\n```python\nprint(1)\n```\nDone.");
        tbcheck([blocks count] == 3 && [[[blocks objectAtIndex:1] objectForKey:@"code"] boolValue], @"fence splits prose and code");
        tbcheck([[[blocks objectAtIndex:1] objectForKey:@"lang"] isEqualToString:@"python"]
            && [[[blocks objectAtIndex:1] objectForKey:@"text"] isEqualToString:@"print(1)"]
            && [[[blocks objectAtIndex:1] objectForKey:@"closed"] boolValue], @"fence tag and body read");
        tbcheck([[[blocks objectAtIndex:2] objectForKey:@"text"] isEqualToString:@"Done."], @"prose after the fence kept");
        blocks = TBSplitBlocks(@"Start\n```js\nlet a = 1;");
        tbcheck([blocks count] == 2 && ![[[blocks objectAtIndex:1] objectForKey:@"closed"] boolValue], @"open fence while streaming");
        blocks = TBSplitBlocks(@"no code here");
        tbcheck([blocks count] == 1 && ![[[blocks objectAtIndex:0] objectForKey:@"code"] boolValue], @"plain text is one block");
        blocks = TBSplitBlocks(@"````\n```\ninner\n```\n````");
        tbcheck([blocks count] == 1 && [[[blocks objectAtIndex:0] objectForKey:@"text"] hasPrefix:@"```"], @"longer fence holds a shorter one");
        tbcheck([TBLanguageTitle(@"py", @"") isEqualToString:@"Python"] && [TBLanguageTitle(@"sh", @"") isEqualToString:@"Shell"]
            && [TBLanguageTitle(@"c++", @"") isEqualToString:@"C++"], @"language names");
        tbcheck([TBLanguageTitle(@"haskell", @"") isEqualToString:@"Haskell"], @"unknown tag shown as written");
        tbcheck([TBLanguageTitle(@"", @"#!/usr/bin/env python3\nprint(1)") isEqualToString:@"Python"]
            && [TBLanguageTitle(@"", @"hello there") isEqualToString:@"Code"], @"untagged code is guessed or called Code");
    }
    {
        NSString *code = @"def f(x):  # note\n    return \"a\" + 12";
        const unsigned char *k = (const unsigned char *)[TBHighlight(code, @"python") bytes];
        tbcheck(k[0] == TBTokKeyword && k[4] == TBTokFunction, @"python keyword and function name");
        tbcheck(k[11] == TBTokComment && k[16] == TBTokComment, @"python comment");
        tbcheck(k[[code rangeOfString:@"\"a\""].location] == TBTokString, @"python string");
        tbcheck(k[[code rangeOfString:@"12"].location] == TBTokNumber, @"python number");
        k = (const unsigned char *)[TBHighlight(@"{\"name\": \"x\", \"n\": 3}", @"json") bytes];
        tbcheck(k[1] == TBTokProperty && k[9] == TBTokString && k[16] == TBTokProperty, @"json keys and values");
        k = (const unsigned char *)[TBHighlight(@"#include <stdio.h>\nint main() { return 0; /* x */ }", @"c") bytes];
        tbcheck(k[0] == TBTokKeyword && k[9] == TBTokString && k[19] == TBTokType, @"c preprocessor, header and type");
        k = (const unsigned char *)[TBHighlight(@"+added\n-gone\n same", @"diff") bytes];
        tbcheck(k[0] == TBTokInsert && k[7] == TBTokDelete && k[13] == TBTokPlain, @"diff lines");
        k = (const unsigned char *)[TBHighlight(@"echo $HOME # hi", @"bash") bytes];
        tbcheck(k[5] == TBTokProperty && k[11] == TBTokComment, @"shell variable and comment");
        {
            NSString *page = @"<script>var n = 12; // x\n</script>";
            const unsigned char *h = (const unsigned char *)[TBHighlight(page, @"html") bytes];
            tbcheck(h[8] == TBTokKeyword && h[16] == TBTokNumber && h[20] == TBTokComment, @"script inside html is coloured as javascript");
            h = (const unsigned char *)[TBHighlight(@"data Maybe a = Nothing -- none", @"haskell") bytes];
            tbcheck(h[0] == TBTokKeyword && h[23] == TBTokComment, @"haskell keyword and comment");
        }
        tbcheck([TBHighlight(@"", @"python") length] == 0 && [TBHighlight(@"x = 'unterminated", @"python") length] == 17, @"empty and unterminated input");
    }
    {
        NSString *file = [NSTemporaryDirectory() stringByAppendingPathComponent:@"tb-attach-test.txt"];
        NSDictionary *attach = [NSDictionary dictionaryWithObjectsAndKeys:@"notes.txt", @"name", file, @"path", @"text", @"kind",
            [NSNumber numberWithInt:100], @"tokens", nil];
        NSDictionary *message = [NSDictionary dictionaryWithObjectsAndKeys:@"user", @"role", @"Attached: notes.txt", @"text", attach, @"attachment", nil];
        BOOL cut = YES;
        NSString *back;
        NSData *three = [NSData dataWithBytes:"abc" length:3];
        [@"first line\nsecond \xc3\xa9" writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        back = TBReadTextFile(file, 1000, &cut);
        tbcheck(back && !cut && [back hasPrefix:@"first line"], @"text file read");
        back = TBReadTextFile(file, 5, &cut);
        tbcheck(back && cut && [back isEqualToString:@"first"], @"long text file cut at the limit");
        tbcheck([TBMessageContent(message) rangeOfString:@"second"].location != NSNotFound
            && [TBMessageContent(message) rangeOfString:@"notes.txt"].location != NSNotFound, @"attachment goes to the model as its text");
        tbcheck([TBMessageContent([NSDictionary dictionaryWithObject:@"hi" forKey:@"text"]) isEqualToString:@"hi"], @"plain message unchanged");
        tbcheck(TBEstimateTokens([NSArray arrayWithObject:message], NO) == 400 + 100 + 12, @"attachment counted by its saved size");
        {
            NSString *hinted = TBMessageContent(message);
            tbcheck([hinted rangeOfString:@"is on their Mac at"].location != NSNotFound, @"the model is told where the copy is");
            TBSetPathHintRoot(@"/Some/Other/Project");
            tbcheck([TBMessageContent(message) rangeOfString:@"is on their Mac at"].location == NSNotFound, @"no path is given outside a restricted workspace");
            TBSetPathHintRoot(NSTemporaryDirectory());
            tbcheck([TBMessageContent(message) rangeOfString:@"is on their Mac at"].location != NSNotFound, @"a path inside the restricted workspace is given");
            TBSetPathHintRoot(nil);
        }
        [[NSFileManager defaultManager] removeFileAtPath:file handler:nil];
        tbcheck([TBMessageContent(message) rangeOfString:@"no longer available"].location != NSNotFound, @"missing attachment explained");
        [[NSData dataWithBytes:"ab\0cd" length:5] writeToFile:file atomically:YES];
        tbcheck(TBReadTextFile(file, 1000, NULL) == nil, @"binary file is not text");
        [[NSFileManager defaultManager] removeFileAtPath:file handler:nil];
        tbcheck([TBBase64(three) isEqualToString:@"YWJj"] && [TBBase64([NSData dataWithBytes:"ab" length:2]) isEqualToString:@"YWI="]
            && [TBBase64([NSData dataWithBytes:"a" length:1]) isEqualToString:@"YQ=="] && [TBBase64([NSData data]) isEqualToString:@""], @"base64");
        tbcheck([TBDisplayFileName(@"0123456789abcdef-report.md") isEqualToString:@"report.md"]
            && [TBDisplayFileName(@"/x/0123456789abcdeg-report.md") isEqualToString:@"0123456789abcdeg-report.md"]
            && [TBDisplayFileName(@"cat.jpg") isEqualToString:@"cat.jpg"], @"stored file name shown without its id");
        tbcheck([TBLanguageExtension(@"Python") isEqualToString:@"py"] && [TBLanguageExtension(@"Haskell") isEqualToString:@"txt"]
            && [TBLanguageExtension(@"C++") isEqualToString:@"cpp"], @"file extension for a language");
        tbcheck([TBHumanSize(500) isEqualToString:@"500 bytes"] && [TBHumanSize(2048) isEqualToString:@"2 KB"], @"file sizes");
    }
    {
        NSArray *blocks = TBSplitBlocks(@"Before\n| Name | Qty |\n|---|--:|\n| Bolt | 4 |\n| Long nut | 12 |\nAfter");
        NSDictionary *table = [blocks count] == 3 ? [blocks objectAtIndex:1] : nil;
        tbcheck(table && [[table objectForKey:@"lang"] isEqualToString:@"table"], @"a pipe table becomes a table block");
        tbcheck([[table objectForKey:@"text"] isEqualToString:@"Name     | Qty\n---------+----\nBolt     | 4\nLong nut | 12"], @"table columns are aligned");
        tbcheck([[table objectForKey:@"copy"] isEqualToString:@"Name\tQty\nBolt\t4\nLong nut\t12"], @"table copies as tab separated rows");
        tbcheck([[[blocks objectAtIndex:0] objectForKey:@"text"] isEqualToString:@"Before"] && [[[blocks objectAtIndex:2] objectForKey:@"text"] isEqualToString:@"After"], @"text around a table kept");
        tbcheck([TBSplitBlocks(@"a | b without a separator row\nnext") count] == 1, @"pipes alone are not a table");
        tbcheck([TBLanguageTitle(@"table", @"") isEqualToString:@"Table"] && [TBLanguageExtension(@"Table") isEqualToString:@"tsv"], @"table title and extension");
    }
    {
        NSString *shown = TBDisplayText([NSString stringWithFormat:@"Done %C%C!%C", (unichar)0xD83D, (unichar)0xDE80, (unichar)0x2705]);
        tbcheck([shown isEqualToString:@"Done (rocket)! (check)"] || TBSystemMinor() >= 7, @"emoji become words");
        tbcheck([TBDisplayText(@"caf\u00e9 \u65e5\u672c\u8a9e \u2192 \u2713") isEqualToString:@"caf\u00e9 \u65e5\u672c\u8a9e \u2192 \u2713"], @"other characters are untouched");
        tbcheck(![TBDisplayText([NSString stringWithFormat:@"a%C%C%Cb", (unichar)0xD83E, (unichar)0xDD2F, (unichar)0xFE0F]) hasPrefix:@"a\xed"], @"unknown pictographs dropped");
    }
    {
        NSString *err = nil;
        NSDictionary *d = TBJSONParseString(@"{\"a\":[1,-2,3.5,1e3,true,false,null],\"s\":\"caf\\u00e9 \\ud83d\\ude00 line\\nbreak \\\"q\\\"\",\"o\":{}}", &err);
        NSArray *a = [d objectForKey:@"a"];
        tbcheck(d && [a count] == 7 && [[a objectAtIndex:1] intValue] == -2 && [[a objectAtIndex:2] doubleValue] == 3.5 && [[a objectAtIndex:3] doubleValue] == 1000, @"json numbers");
        tbcheck([a objectAtIndex:4] == (id)kCFBooleanTrue && [a objectAtIndex:5] == (id)kCFBooleanFalse && [a objectAtIndex:6] == [NSNull null], @"json true, false, null");
        tbcheck([[d objectForKey:@"s"] isEqualToString:[NSString stringWithFormat:@"caf%C %C%C line\nbreak \"q\"", (unichar)0xE9, (unichar)0xD83D, (unichar)0xDE00]], @"json string escapes and surrogate pairs");
        tbcheck([[d objectForKey:@"o"] count] == 0, @"json empty object");
        tbcheck(TBJSONParseString(@"{\"a\":1,}", &err) == nil && err != nil, @"json trailing comma refused");
        tbcheck(TBJSONParseString(@"[1,2", &err) == nil && TBJSONParseString(@"{\"a\":\"\\x\"}", &err) == nil && TBJSONParseString(@"1 2", &err) == nil, @"json broken text refused");
        {
            NSDictionary *out = [NSDictionary dictionaryWithObjectsAndKeys:[NSString stringWithFormat:@"a\"b\\c\n%C\t%C%C", (unichar)1, (unichar)0xD83D, (unichar)0xDE00], @"text",
                [NSNumber numberWithBool:YES], @"flag", [NSNumber numberWithLongLong:9007199254740993LL], @"big", [NSNumber numberWithDouble:0.25], @"half",
                [NSArray arrayWithObjects:[NSNull null], [TBJSONRaw rawWithData:[@"\"RAW\"" dataUsingEncoding:NSUTF8StringEncoding]], nil], @"list", nil];
            NSDictionary *back = TBJSONParse(TBJSONData(out), &err);
            tbcheck(back && [[back objectForKey:@"text"] isEqualToString:[out objectForKey:@"text"]] && [back objectForKey:@"flag"] == (id)kCFBooleanTrue
                && [[back objectForKey:@"big"] longLongValue] == 9007199254740993LL && [[back objectForKey:@"half"] doubleValue] == 0.25
                && [[[back objectForKey:@"list"] objectAtIndex:1] isEqualToString:@"RAW"], @"json round trip");
        }
        {
            NSMutableArray *big = [NSMutableArray array];
            unsigned i;
            for (i = 0; i < 20000; i++)
                [big addObject:[NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithInt:i], @"n", @"some text here", @"t", nil]];
            tbcheck([TBJSONParse(TBJSONData(big), &err) count] == 20000, @"json handles a long list");
        }
    }
    TBEmojiUsePack(@"Emoji.pack");
    if (TBEmojiPicturesAvailable()) {
        NSString *grin = tbcodes(0x61, 0x1F600, 0x62, 0);
        NSString *shown = TBEmojiSubstitute(grin);
        tbcheck([shown length] == 3 && TBEmojiIsStandIn([shown characterAtIndex:1]) && [TBEmojiRestore(shown) isEqualToString:grin], @"an emoji becomes one stand-in and comes back");
        tbcheck([TBEmojiSubstitute(tbcodes(0x1F1FA, 0x1F1F8, 0)) length] == 1, @"a flag is one emoji");
        tbcheck([TBEmojiSubstitute(tbcodes(0x1F468, 0x200D, 0x1F469, 0x200D, 0x1F467, 0)) length] == 1, @"a family is one emoji");
        tbcheck([TBEmojiSubstitute(tbcodes(0x1F44D, 0x1F3FD, 0)) length] == 1, @"a skin tone stays with its emoji");
        tbcheck([TBEmojiSubstitute(tbcodes(0x31, 0xFE0F, 0x20E3, 0)) length] == 1 && [TBEmojiSubstitute(@"1 2") isEqualToString:@"1 2"], @"a keycap, but not a plain digit");
        {
            NSString *plain = TBEmojiSubstitute(tbcodes(0xA9, 0));
            NSString *asked = TBEmojiSubstitute(tbcodes(0xA9, 0xFE0F, 0));
            tbcheck([plain length] == 1 && !TBEmojiIsStandIn([plain characterAtIndex:0]) && [asked length] == 1 && TBEmojiIsStandIn([asked characterAtIndex:0]),
                @"a copyright sign is text unless asked for as an emoji");
        }
        tbcheck([TBEmojiSubstitute(tbcodes(0x2764, 0xFE0F, 0)) length] == 1, @"a heart with its selector is one emoji");
        {
            NSData *png = TBEmojiPNGForStandIn([TBEmojiSubstitute(grin) characterAtIndex:1]);
            tbcheck([png length] > 100 && ((const unsigned char *)[png bytes])[1] == 'P', @"the picture is a PNG");
        }
    }
    {
        NSString *said = TBSpeechText(@"## Title\nSee [the docs](https://example.com/x) or https://apple.com now. **Bold** and `code`.\n- one\n```python\nprint(1)\n```\n| a | b |\n|---|---|\n| 1 | 2 |\nDone.");
        tbcheck([said rangeOfString:@"the docs"].location != NSNotFound && [said rangeOfString:@"example.com"].location == NSNotFound
            && [said rangeOfString:@"a link"].location != NSNotFound, @"links are spoken as their words");
        tbcheck([said rangeOfString:@"print"].location == NSNotFound && [said rangeOfString:@"block of code"].location != NSNotFound
            && [said rangeOfString:@"table"].location != NSNotFound && [said rangeOfString:@"|"].location == NSNotFound, @"code and tables are not read out");
        tbcheck([said rangeOfString:@"**"].location == NSNotFound && [said rangeOfString:@"#"].location == NSNotFound && [said hasPrefix:@"Title"], @"markdown marks are dropped");
    }
    tbcheck(TBSystemMinor() >= 4, @"system minor version read");

    tbcheck(TBEstimateTokens(chat, NO) == 406, @"token estimate");
    tbcheck(TBEstimateTokens(chat, YES) > TBEstimateTokens(chat, NO), @"tools cost tokens");

    {
        NSString *name = [TBMachine name];
        NSString *version = [TBMachine systemVersion];
        tbcheck([name length] > 0, @"machine name read from the system");
        tbcheck([version hasPrefix:@"Mac OS X"], @"system version read from SystemVersion.plist");
        fprintf(stderr, "INFO machine=%s os=%s\n", [name UTF8String], [version UTF8String]);
    }
    [pool release];
    if (failures) {
        fprintf(stderr, "%d failed\n", failures);
        return 1;
    }
    fprintf(stderr, "all passed\n");
    return 0;
}
