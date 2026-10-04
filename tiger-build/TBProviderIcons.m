#import "TBProviderIcons.h"
#import "TBCompat.h"
#include <math.h>

/* Each mark is drawn on a 100 by 100 square. */

static NSColor *rgb(float r, float g, float b)
{
    return [NSColor colorWithCalibratedRed:r / 255 green:g / 255 blue:b / 255 alpha:1];
}

/* NSBezierPath's own rounded rectangle needs Mac OS X 10.5. */
static NSBezierPath *roundRect(NSRect r, float radius)
{
    NSBezierPath *path = [NSBezierPath bezierPath];
    float x = NSMinX(r), y = NSMinY(r), w = NSWidth(r), h = NSHeight(r);
    [path moveToPoint:NSMakePoint(x + radius, y)];
    [path appendBezierPathWithArcFromPoint:NSMakePoint(x + w, y) toPoint:NSMakePoint(x + w, y + h) radius:radius];
    [path appendBezierPathWithArcFromPoint:NSMakePoint(x + w, y + h) toPoint:NSMakePoint(x, y + h) radius:radius];
    [path appendBezierPathWithArcFromPoint:NSMakePoint(x, y + h) toPoint:NSMakePoint(x, y) radius:radius];
    [path appendBezierPathWithArcFromPoint:NSMakePoint(x, y) toPoint:NSMakePoint(x + w, y) radius:radius];
    [path closePath];
    return path;
}

static void drawClaude(void)
{
    int i;
    [rgb(217, 119, 87) set];
    for (i = 0; i < 12; i++) {
        float angle = i * M_PI / 6;
        float outer = (i % 2) ? 38 : 47;
        NSBezierPath *ray = [NSBezierPath bezierPath];
        [ray moveToPoint:NSMakePoint(50 + 10 * cosf(angle), 50 + 10 * sinf(angle))];
        [ray lineToPoint:NSMakePoint(50 + outer * cosf(angle), 50 + outer * sinf(angle))];
        [ray setLineWidth:11];
        [ray setLineCapStyle:NSRoundLineCapStyle];
        [ray stroke];
    }
}

static void drawChatGPT(void)
{
    int i;
    NSBezierPath *disc = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(2, 2, 96, 96)];
    [rgb(16, 163, 127) set];
    [disc fill];
    [[NSColor whiteColor] set];
    for (i = 0; i < 3; i++) {
        NSAffineTransform *turn = [NSAffineTransform transform];
        NSBezierPath *loop = roundRect(NSMakeRect(-27, -14, 54, 28), 14);
        [NSGraphicsContext saveGraphicsState];
        [turn translateXBy:50 yBy:50];
        [turn rotateByDegrees:i * 60];
        [turn concat];
        [loop setLineWidth:6.5];
        [loop stroke];
        [NSGraphicsContext restoreGraphicsState];
    }
}

static void drawGrok(void)
{
    NSBezierPath *tile = roundRect(NSMakeRect(2, 2, 96, 96), 22);
    NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(24, 24, 50, 50)];
    NSBezierPath *slash = [NSBezierPath bezierPath];
    [[NSColor blackColor] set];
    [tile fill];
    [[NSColor whiteColor] set];
    [ring setLineWidth:8];
    [ring stroke];
    [slash moveToPoint:NSMakePoint(30, 22)];
    [slash lineToPoint:NSMakePoint(80, 80)];
    [slash setLineWidth:9];
    [slash setLineCapStyle:NSRoundLineCapStyle];
    [[NSColor blackColor] set];
    {
        NSBezierPath *gap = [NSBezierPath bezierPath];
        [gap moveToPoint:NSMakePoint(30, 22)];
        [gap lineToPoint:NSMakePoint(80, 80)];
        [gap setLineWidth:17];
        [gap stroke];
    }
    [[NSColor whiteColor] set];
    [slash stroke];
}

static void drawGemini(void)
{
    NSBezierPath *star = [NSBezierPath bezierPath];
    [rgb(66, 133, 244) set];
    [star moveToPoint:NSMakePoint(50, 97)];
    [star curveToPoint:NSMakePoint(97, 50) controlPoint1:NSMakePoint(52, 66) controlPoint2:NSMakePoint(66, 52)];
    [star curveToPoint:NSMakePoint(50, 3) controlPoint1:NSMakePoint(66, 48) controlPoint2:NSMakePoint(52, 34)];
    [star curveToPoint:NSMakePoint(3, 50) controlPoint1:NSMakePoint(48, 34) controlPoint2:NSMakePoint(34, 48)];
    [star curveToPoint:NSMakePoint(50, 97) controlPoint1:NSMakePoint(34, 52) controlPoint2:NSMakePoint(48, 66)];
    [star closePath];
    [star fill];
}

static void drawMistral(void)
{
    static const char *rows[5] = {"X...X", "XX.XX", "X.X.X", "X...X", "X...X"};
    static const float colours[5][3] = {{255, 206, 0}, {255, 164, 0}, {255, 116, 0}, {255, 72, 0}, {226, 30, 20}};
    int r, c;
    for (r = 0; r < 5; r++) {
        [rgb(colours[r][0], colours[r][1], colours[r][2]) set];
        for (c = 0; c < 5; c++) {
            if (rows[r][c] == 'X')
                NSRectFill(NSMakeRect(5 + c * 18.4f, 5 + (4 - r) * 18.4f, 17, 17));
        }
    }
}

static void drawMuse(void)
{
    NSBezierPath *loop = [NSBezierPath bezierPath];
    int i;
    for (i = 0; i <= 48; i++) {
        float t = i * 2 * M_PI / 48;
        float d = 1 + sinf(t) * sinf(t);
        NSPoint p = NSMakePoint(50 + 42 * cosf(t) / d, 50 + 46 * sinf(t) * cosf(t) / d);
        if (i == 0)
            [loop moveToPoint:p];
        else
            [loop lineToPoint:p];
    }
    [loop closePath];
    [rgb(8, 102, 255) set];
    [loop setLineWidth:11];
    [loop setLineJoinStyle:NSRoundLineJoinStyle];
    [loop stroke];
}

static void drawLocal(void)
{
    int i;
    for (i = 0; i < 2; i++) {
        float y = i ? 56 : 14;
        NSBezierPath *box = roundRect(NSMakeRect(8, y, 84, 30), 8);
        NSBezierPath *light = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(20, y + 10, 10, 10)];
        [rgb(112, 122, 140) set];
        [box fill];
        [rgb(120, 220, 120) set];
        [light fill];
    }
}

void TBDrawProviderIcon(NSString *provider, NSRect rect)
{
    NSAffineTransform *place = [NSAffineTransform transform];
    [NSGraphicsContext saveGraphicsState];
    [place translateXBy:NSMinX(rect) yBy:NSMinY(rect)];
    [place scaleXBy:NSWidth(rect) / 100 yBy:NSHeight(rect) / 100];
    [place concat];
    if ([provider isEqualToString:@"claude"])
        drawClaude();
    else if ([provider isEqualToString:@"chatgpt"])
        drawChatGPT();
    else if ([provider isEqualToString:@"grok"])
        drawGrok();
    else if ([provider isEqualToString:@"gemini"])
        drawGemini();
    else if ([provider isEqualToString:@"mistral"])
        drawMistral();
    else if ([provider isEqualToString:@"muse"])
        drawMuse();
    else if ([provider isEqualToString:@"local"])
        drawLocal();
    [NSGraphicsContext restoreGraphicsState];
}

NSImage *TBProviderIcon(NSString *provider)
{
    static NSMutableDictionary *cache = nil;
    NSImage *image;
    if (!provider)
        return nil;
    if (!cache)
        cache = [[NSMutableDictionary alloc] init];
    image = [cache objectForKey:provider];
    if (image)
        return image;
    if (![[NSArray arrayWithObjects:@"claude", @"chatgpt", @"grok", @"gemini", @"mistral", @"muse", @"local", nil] containsObject:provider])
        return nil;
    image = [[[NSImage alloc] initWithSize:NSMakeSize(16, 16)] autorelease];
    [image lockFocus];
    TBDrawProviderIcon(provider, NSMakeRect(0, 0, 16, 16));
    [image unlockFocus];
    [cache setObject:image forKey:provider];
    return image;
}
