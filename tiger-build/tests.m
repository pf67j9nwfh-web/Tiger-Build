/* make test: checks the pieces of Tiger Build that do not need a window. */
#import <Foundation/Foundation.h>
#import "TBSupport.h"

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

static void checkLayout(float w, float h, float wanted, float status)
{
    TBChatLayout l = TBLayoutChatPane(w, h, wanted, status);
    NSString *tag = [NSString stringWithFormat:@"%.0fx%.0f field %.0f status %.0f", w, h, wanted, status];
    float inputMid = NSMidY(l.input);
    float sendMid = NSMidY(l.send);
    tbcheck(l.fieldHeight >= TB_FIELD_MIN && l.fieldHeight <= TB_FIELD_MAX,
        [tag stringByAppendingString:@": field height clamped"]);
    tbcheck(NSHeight(l.input) == l.fieldHeight, [tag stringByAppendingString:@": input uses that height"]);
    /* The ghost Send button in Picture 7 came from this button moving. It
       must stay centred on the field (or pinned at the bottom margin). */
    tbcheck(fabsf(inputMid - sendMid) < 1.0f || NSMinY(l.send) == 10,
        [tag stringByAppendingString:@": send centred on field"]);
    tbcheck(!overlaps(l.input, l.send), [tag stringByAppendingString:@": send beside field"]);
    tbcheck(NSMinY(l.transcript) >= NSMaxY(l.input), [tag stringByAppendingString:@": transcript above field"]);
    tbcheck(NSMaxX(l.send) <= w && NSMinX(l.input) >= 0, [tag stringByAppendingString:@": inside pane"]);
    tbcheck(!overlaps(l.transcript, l.send), [tag stringByAppendingString:@": send clear of transcript"]);
    /* Picture 8: a long relay problem was cut off on one line. It now wraps
       across the top, and must not cover the readout or the transcript. */
    tbcheck(NSMaxY(l.transcript) <= NSMinY(l.context) + 0.5f, [tag stringByAppendingString:@": readout above transcript"]);
    if (status > 0) {
        tbcheck(NSHeight(l.status) == (status > TB_STATUS_MAX ? TB_STATUS_MAX : status),
            [tag stringByAppendingString:@": status gets its height"]);
        tbcheck(NSWidth(l.status) == w - 16, [tag stringByAppendingString:@": status uses full width"]);
        tbcheck(!overlaps(l.status, l.context), [tag stringByAppendingString:@": status clear of readout"]);
        tbcheck(!overlaps(l.status, l.transcript), [tag stringByAppendingString:@": status clear of transcript"]);
        tbcheck(NSMaxY(l.status) <= h, [tag stringByAppendingString:@": status inside pane"]);
    } else {
        tbcheck(NSMaxY(l.context) == h - 10, [tag stringByAppendingString:@": no problem, readout at top"]);
    }
}

int main(void)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    ModelCatalog *catalog;
    NSArray *chat;
    float wanted;

    for (wanted = 0; wanted <= 140; wanted += 8) {
        checkLayout(560, 600, wanted, 0);
        checkLayout(400, 290, wanted, 0);
        checkLayout(560, 600, wanted, 32);
        checkLayout(400, 290, wanted, 64);
        checkLayout(400, 290, wanted, 90);
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
