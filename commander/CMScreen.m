#import "CMCore.h"
#import <ApplicationServices/ApplicationServices.h>

/* Mouse and keyboard for the main display, so a model can use what a screenshot shows. These are the Tiger-era calls (CGPostMouseEvent,
   CGPostKeyboardEvent), which work on 10.4 through 10.6 without any permission setting. Keys follow the US keyboard layout. */

static double screenScale = 1.0;   /* screen points per pixel of the last screenshot */

void CMScreenSetScale(double scale)
{
    if (scale > 0.05 && scale < 50)
        screenScale = scale;
}

typedef struct { const char *name; CGKeyCode code; } KeyName;

static const KeyName keyNames[] = {
    {"return", 36}, {"enter", 36}, {"tab", 48}, {"space", 49}, {"delete", 51}, {"backspace", 51}, {"escape", 53}, {"esc", 53},
    {"left", 123}, {"right", 124}, {"down", 125}, {"up", 126}, {"home", 115}, {"end", 119}, {"pageup", 116}, {"pagedown", 121}, {"forwarddelete", 117},
    {"f1", 122}, {"f2", 120}, {"f3", 99}, {"f4", 118}, {"f5", 96}, {"f6", 97}, {"f7", 98}, {"f8", 100}, {"f9", 101}, {"f10", 109}, {"f11", 103}, {"f12", 111},
    {NULL, 0}
};

/* US layout: the key for a character, and whether Shift is held */
static BOOL keyForCharacter(unichar c, CGKeyCode *code, BOOL *shift)
{
    static const char *rows[2] = {
        "a\x00" "s\x01" "d\x02" "f\x03" "h\x04" "g\x05" "z\x06" "x\x07" "c\x08" "v\x09" "b\x0b" "q\x0c" "w\x0d" "e\x0e" "r\x0f" "y\x10" "t\x11"
        "1\x12" "2\x13" "3\x14" "4\x15" "6\x16" "5\x17" "=\x18" "9\x19" "7\x1a" "-\x1b" "8\x1c" "0\x1d" "]\x1e" "o\x1f" "u\x20" "[\x21" "i\x22" "p\x23"
        "l\x25" "j\x26" "'\x27" "k\x28" ";\x29" "\\\x2a" ",\x2b" "/\x2c" "n\x2d" "m\x2e" ".\x2f" "`\x32" " \x31",
        "!\x12" "@\x13" "#\x14" "$\x15" "^\x16" "%\x17" "+\x18" "(\x19" "&\x1a" "_\x1b" "*\x1c" ")\x1d" "}\x1e" "{\x21" "\"\x27" ":\x29" "|\x2a" "<\x2b" "?\x2c" ">\x2f" "~\x32"
    };
    const char *p;
    int r;
    if (c >= 'A' && c <= 'Z') {
        if (!keyForCharacter(c - 'A' + 'a', code, shift))
            return NO;
        *shift = YES;
        return YES;
    }
    if (c == '\n' || c == '\r') {
        *code = 36;
        *shift = NO;
        return YES;
    }
    if (c == '\t') {
        *code = 48;
        *shift = NO;
        return YES;
    }
    if (c > 126 || c < 32)
        return NO;
    for (r = 0; r < 2; r++)
        for (p = rows[r]; *p; p += 2)
            if ((unsigned char)*p == c) {
                *code = (unsigned char)p[1];
                *shift = r == 1;
                return YES;
            }
    return NO;
}

static void shortPause(void)
{
    usleep(12000);
}

static void keyPress(CGKeyCode code, unichar ch, BOOL down)
{
    CGPostKeyboardEvent((CGCharCode)ch, code, down);
    shortPause();
}

static CGPoint pointFrom(NSDictionary *args, NSString *xKey, NSString *yKey)
{
    CGRect bounds = CGDisplayBounds(CGMainDisplayID());
    double x = (double)CMInteger(args, xKey) * screenScale, y = (double)CMInteger(args, yKey) * screenScale;
    if (x < 0 || y < 0 || x >= bounds.size.width || y >= bounds.size.height)
        CMFail(@"(%@, %@) is outside the screen. Coordinates are pixels of the last screenshot (the screen is %d x %d points).", [args objectForKey:xKey], [args objectForKey:yKey], (int)bounds.size.width, (int)bounds.size.height);
    return CGPointMake(x, y);
}

static void mouseMove(CGPoint p)
{
    CGPostMouseEvent(p, true, 1, false);
    shortPause();
}

id CMToolScreenInfo(NSDictionary *args)
{
    CGRect bounds = CGDisplayBounds(CGMainDisplayID());
    CGEventRef event = CGEventCreate(NULL);
    CGPoint at = event ? CGEventGetLocation(event) : CGPointMake(0, 0);
    if (event)
        CFRelease(event);
    (void)args;
    return [NSString stringWithFormat:@"screen: %d x %d points (main display)\nmouse: %d, %d points\ncoordinates for the screen_* tools are pixels of the last take_screenshot picture (%.3f points per pixel); take a screenshot first, or the unit is points",
        (int)bounds.size.width, (int)bounds.size.height, (int)(at.x / screenScale), (int)(at.y / screenScale), screenScale];
}

id CMToolScreenClick(NSDictionary *args)
{
    CGPoint p = pointFrom(args, @"x", @"y");
    NSString *button = CMOptString(args, @"button", @"left");
    long long clicks = CMOptInteger(args, @"clicks", 1);
    int i;
    BOOL right = [button isEqualToString:@"right"];
    if (!right && ![button isEqualToString:@"left"])
        CMFail(@"button must be left or right");
    if (clicks < 1 || clicks > 3)
        CMFail(@"clicks must be 1, 2 or 3");
    mouseMove(p);
    for (i = 0; i < clicks; i++) {
        CGPostMouseEvent(p, true, 2, right ? false : true, right ? true : false);
        shortPause();
        CGPostMouseEvent(p, true, 2, false, false);
        shortPause();
    }
    return [NSString stringWithFormat:@"clicked %@ x%lld at %d, %d", button, clicks, (int)p.x, (int)p.y];
}

id CMToolScreenMove(NSDictionary *args)
{
    CGPoint p = pointFrom(args, @"x", @"y");
    mouseMove(p);
    return [NSString stringWithFormat:@"mouse at %d, %d", (int)p.x, (int)p.y];
}

id CMToolScreenDrag(NSDictionary *args)
{
    CGPoint from = pointFrom(args, @"x", @"y"), to = pointFrom(args, @"to_x", @"to_y");
    int step;
    mouseMove(from);
    CGPostMouseEvent(from, true, 1, true);
    shortPause();
    for (step = 1; step <= 10; step++) {
        CGPoint p = CGPointMake(from.x + (to.x - from.x) * step / 10, from.y + (to.y - from.y) * step / 10);
        CGPostMouseEvent(p, true, 1, true);
        usleep(20000);
    }
    CGPostMouseEvent(to, true, 1, false);
    shortPause();
    return [NSString stringWithFormat:@"dragged from %d, %d to %d, %d", (int)from.x, (int)from.y, (int)to.x, (int)to.y];
}

id CMToolScreenScroll(NSDictionary *args)
{
    long long amount = CMInteger(args, @"amount");
    if (amount < -50 || amount > 50 || amount == 0)
        CMFail(@"amount must be from -50 to 50 and not 0 (positive scrolls up)");
    if ([args objectForKey:@"x"] && [args objectForKey:@"y"])
        mouseMove(pointFrom(args, @"x", @"y"));
    CGPostScrollWheelEvent(1, (int32_t)amount);
    shortPause();
    return [NSString stringWithFormat:@"scrolled %lld", amount];
}

id CMToolScreenType(NSDictionary *args)
{
    NSString *text = CMString(args, @"text");
    unsigned i;
    CGKeyCode code;
    BOOL shift;
    if ([text length] > 2000)
        CMFail(@"at most 2000 characters at a time");
    for (i = 0; i < [text length]; i++)   /* nothing is typed unless all of it can be */
        if (!keyForCharacter([text characterAtIndex:i], &code, &shift))
            CMFail(@"character %u of the text cannot be typed (US keyboard characters only)", i + 1);
    for (i = 0; i < [text length]; i++) {
        unichar c = [text characterAtIndex:i];
        keyForCharacter(c, &code, &shift);
        if (shift)
            keyPress(56, 0, YES);
        keyPress(code, c, YES);
        keyPress(code, c, NO);
        if (shift)
            keyPress(56, 0, NO);
    }
    return [NSString stringWithFormat:@"typed %u characters", (unsigned)[text length]];
}

id CMToolScreenKey(NSDictionary *args)
{
    NSString *key = [[CMString(args, @"key") lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSArray *modifiers = [args objectForKey:@"modifiers"] ? CMStringList([args objectForKey:@"modifiers"]) : [NSArray array];
    CGKeyCode code = 0, held[4];
    unsigned heldCount = 0, i;
    BOOL shift = NO, found = NO;
    const KeyName *k;
    for (k = keyNames; k->name; k++)
        if (!strcmp(k->name, [key UTF8String])) {
            code = k->code;
            found = YES;
        }
    if (!found && [key length] == 1)
        found = keyForCharacter([key characterAtIndex:0], &code, &shift);
    if (!found)
        CMFail(@"unknown key %@. Use a single character, or return, tab, space, delete, escape, left, right, up, down, home, end, pageup, pagedown, forwarddelete, f1 to f12.", key);
    for (i = 0; i < [modifiers count] && heldCount < 4; i++) {
        NSString *m = [[modifiers objectAtIndex:i] lowercaseString];
        if ([m isEqualToString:@"cmd"] || [m isEqualToString:@"command"])
            held[heldCount++] = 55;
        else if ([m isEqualToString:@"shift"])
            held[heldCount++] = 56;
        else if ([m isEqualToString:@"option"] || [m isEqualToString:@"alt"])
            held[heldCount++] = 58;
        else if ([m isEqualToString:@"control"] || [m isEqualToString:@"ctrl"])
            held[heldCount++] = 59;
        else
            CMFail(@"unknown modifier %@ (cmd, shift, option, control)", m);
    }
    for (i = 0; i < heldCount; i++)
        keyPress(held[i], 0, YES);
    if (shift)
        keyPress(56, 0, YES);
    keyPress(code, 0, YES);
    keyPress(code, 0, NO);
    if (shift)
        keyPress(56, 0, NO);
    for (i = heldCount; i-- > 0;)
        keyPress(held[i], 0, NO);
    return [NSString stringWithFormat:@"pressed %@%@", [modifiers count] ? [[modifiers componentsJoinedByString:@"+"] stringByAppendingString:@"+"] : @"", key];
}
