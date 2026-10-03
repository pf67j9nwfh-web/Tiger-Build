/* make test: checks the pieces of Tiger Build that do not need a window. */
#import <Foundation/Foundation.h>
#import "TBSupport.h"
#import <unistd.h>

static int failures = 0;

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
