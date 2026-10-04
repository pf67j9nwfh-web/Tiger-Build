#import "TBTheme.h"

NSString *TBThemeChangedNotification = @"TBThemeChanged";
NSString *const TBThemeSentBubble = @"TBThemeSentBubble";
NSString *const TBThemeSentText = @"TBThemeSentText";
NSString *const TBThemeGotBubble = @"TBThemeGotBubble";
NSString *const TBThemeGotText = @"TBThemeGotText";
NSString *const TBThemeSentFont = @"TBThemeSentFont";
NSString *const TBThemeGotFont = @"TBThemeGotFont";
NSString *const TBThemeSentSize = @"TBThemeSentSize";
NSString *const TBThemeGotSize = @"TBThemeGotSize";
NSString *const TBThemeBackground = @"TBThemeBackground";
NSString *const TBThemeBackColor = @"TBThemeBackColor";
NSString *const TBThemeBackColor2 = @"TBThemeBackColor2";
NSString *const TBThemePicture = @"TBThemePicture";

/* The original look, as the numbers fillBubble used to hold. */
static const float defaultSent[4][3] = {
    {203.0f / 255, 222.0f / 255, 252.0f / 255}, {130.0f / 255, 180.0f / 255, 249.0f / 255},
    {178.0f / 255, 230.0f / 255, 255.0f / 255}, {58.0f / 255, 76.0f / 255, 112.0f / 255}};
static const float defaultGot[4][3] = {
    {248.0f / 255, 247.0f / 255, 247.0f / 255}, {203.0f / 255, 203.0f / 255, 203.0f / 255},
    {219.0f / 255, 219.0f / 255, 219.0f / 255}, {78.0f / 255, 82.0f / 255, 94.0f / 255}};

static NSDictionary *settings = nil;        /* a copy of the preferences, so drawing never reads them */
static NSImage *backdrop = nil;             /* the picture, scaled to fill the visible area */
static NSSize backdropSize;
static NSString *backdropPath = nil;
static NSImage *source = nil;

@implementation TBTheme

+ (NSArray *)keys
{
    return [NSArray arrayWithObjects:TBThemeSentBubble, TBThemeSentText, TBThemeGotBubble, TBThemeGotText, TBThemeSentFont, TBThemeGotFont,
        TBThemeSentSize, TBThemeGotSize, TBThemeBackground, TBThemeBackColor, TBThemeBackColor2, TBThemePicture, nil];
}

+ (void)reload
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *copy = [NSMutableDictionary dictionary];
    NSArray *keys = [self keys];
    unsigned i;
    for (i = 0; i < [keys count]; i++) {
        id value = [defaults objectForKey:[keys objectAtIndex:i]];
        if (value)
            [copy setObject:value forKey:[keys objectAtIndex:i]];
    }
    [settings release];
    settings = [copy retain];
    [backdrop release];
    backdrop = nil;
}

+ (void)changed:(BOOL)layout
{
    [self reload];
    [[NSNotificationCenter defaultCenter] postNotificationName:TBThemeChangedNotification object:nil
        userInfo:[NSDictionary dictionaryWithObject:[NSNumber numberWithBool:layout] forKey:@"layout"]];
}

+ (void)reset
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSArray *keys = [self keys];
    unsigned i;
    for (i = 0; i < [keys count]; i++)
        [defaults removeObjectForKey:[keys objectAtIndex:i]];
    [defaults synchronize];
    [self changed:YES];
}

+ (id)setting:(NSString *)key
{
    if (!settings)
        [self reload];
    return [settings objectForKey:key];
}

+ (NSColor *)colorForKey:(NSString *)key
{
    NSArray *rgb = [self setting:key];
    if (![rgb isKindOfClass:[NSArray class]] || [rgb count] != 3)
        return nil;
    return [NSColor colorWithCalibratedRed:[[rgb objectAtIndex:0] floatValue] green:[[rgb objectAtIndex:1] floatValue]
                                      blue:[[rgb objectAtIndex:2] floatValue] alpha:1];
}

+ (void)setColor:(NSColor *)color forKey:(NSString *)key
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSColor *rgb = [color colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
    if (!rgb) {
        [defaults removeObjectForKey:key];
    } else {
        [defaults setObject:[NSArray arrayWithObjects:[NSNumber numberWithFloat:[rgb redComponent]],
            [NSNumber numberWithFloat:[rgb greenComponent]], [NSNumber numberWithFloat:[rgb blueComponent]], nil] forKey:key];
    }
    [defaults synchronize];
}

/* The colour mixed with white: 0 leaves it, 1 is white. */
static void lighten(const float *color, float amount, float *out)
{
    int i;
    for (i = 0; i < 3; i++)
        out[i] = color[i] + (1.0f - color[i]) * amount;
}

+ (void)getBubble:(BOOL)sent top:(float *)top body:(float *)body low:(float *)low line:(float *)line
{
    NSColor *custom = [self colorForKey:sent ? TBThemeSentBubble : TBThemeGotBubble];
    const float (*original)[3] = sent ? defaultSent : defaultGot;
    int i;
    if (!custom) {
        for (i = 0; i < 3; i++) {
            top[i] = original[0][i];
            body[i] = original[1][i];
            low[i] = original[2][i];
            line[i] = original[3][i];
        }
        return;
    }
    body[0] = [custom redComponent];
    body[1] = [custom greenComponent];
    body[2] = [custom blueComponent];
    lighten(body, 0.55f, top);
    lighten(body, 0.40f, low);
    for (i = 0; i < 3; i++)
        line[i] = body[i] * 0.45f;
}

+ (NSColor *)textColor:(BOOL)sent
{
    NSColor *custom = [self colorForKey:sent ? TBThemeSentText : TBThemeGotText];
    if (custom)
        return custom;
    return [NSColor colorWithCalibratedWhite:sent ? 0.06f : 0.08f alpha:1];
}

+ (NSFont *)font:(BOOL)sent scale:(float)scale
{
    NSString *family = [self setting:sent ? TBThemeSentFont : TBThemeGotFont];
    float size = [[self setting:sent ? TBThemeSentSize : TBThemeGotSize] floatValue];
    NSFont *font = nil;
    if (size < 8 || size > 40)
        size = 14;
    if ([family isKindOfClass:[NSString class]] && [family length] > 0)
        font = [[NSFontManager sharedFontManager] fontWithFamily:family traits:0 weight:5 size:size * scale];
    return font ? font : [NSFont systemFontOfSize:size * scale];
}

+ (BOOL)hasCustomBackground
{
    NSString *kind = [self setting:TBThemeBackground];
    if ([kind isEqualToString:@"solid"] || [kind isEqualToString:@"gradient"])
        return YES;
    return [kind isEqualToString:@"picture"] && [[self setting:TBThemePicture] length] > 0;
}

/* A straight blend between two colours down the area, for CGShading. */
typedef struct {
    float from[3];
    float to[3];
} BlendInfo;

static void blendEvaluate(void *info, const CGFloat *in, CGFloat *out)
{
    BlendInfo *blend = (BlendInfo *)info;
    int i;
    for (i = 0; i < 3; i++)
        out[i] = blend->from[i] + (blend->to[i] - blend->from[i]) * in[0];
    out[3] = 1.0;
}

static void blendRelease(void *info)
{
    (void)info;
}

+ (void)fillGradient:(NSRect)area from:(NSColor *)top to:(NSColor *)bottom
{
    BlendInfo blend;
    CGFunctionCallbacks callbacks;
    CGFloat domain[2] = {0, 1};
    CGFloat range[8] = {0, 1, 0, 1, 0, 1, 0, 1};
    CGFunctionRef function;
    CGColorSpaceRef space;
    CGShadingRef shading;
    top = [top colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
    bottom = [bottom colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
    blend.from[0] = [top redComponent];
    blend.from[1] = [top greenComponent];
    blend.from[2] = [top blueComponent];
    blend.to[0] = [bottom redComponent];
    blend.to[1] = [bottom greenComponent];
    blend.to[2] = [bottom blueComponent];
    callbacks.version = 0;
    callbacks.evaluate = blendEvaluate;
    callbacks.releaseInfo = blendRelease;
    function = CGFunctionCreate(&blend, 1, domain, 4, range, &callbacks);
    space = CGColorSpaceCreateDeviceRGB();
    shading = CGShadingCreateAxial(space, CGPointMake(NSMidX(area), NSMaxY(area)), CGPointMake(NSMidX(area), NSMinY(area)), function, 1, 1);
    CGContextDrawShading((CGContextRef)[[NSGraphicsContext currentContext] graphicsPort], shading);
    CGShadingRelease(shading);
    CGColorSpaceRelease(space);
    CGFunctionRelease(function);
}

/* The picture, cropped to fill the area and kept as a bitmap that size, so scrolling does not rescale it. */
+ (NSImage *)backdropForSize:(NSSize)size
{
    NSString *path = [self setting:TBThemePicture];
    NSSize original;
    float scale;
    NSRect target;
    if (![path length])
        return nil;
    if (!source || ![backdropPath isEqualToString:path]) {
        [source release];
        [backdropPath release];
        source = [[NSImage alloc] initWithContentsOfFile:path];
        backdropPath = [path copy];
    }
    if (!source)
        return nil;
    if (backdrop && NSEqualSizes(backdropSize, size))
        return backdrop;
    original = [source size];
    if (original.width < 1 || original.height < 1)
        return nil;
    scale = fmaxf(size.width / original.width, size.height / original.height);
    target = NSMakeRect((size.width - original.width * scale) / 2, (size.height - original.height * scale) / 2,
        original.width * scale, original.height * scale);
    [backdrop release];
    backdrop = [[NSImage alloc] initWithSize:size];
    backdropSize = size;
    [backdrop lockFocus];
    [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
    [source drawInRect:target fromRect:NSMakeRect(0, 0, original.width, original.height) operation:NSCompositeCopy fraction:1.0];
    [backdrop unlockFocus];
    return backdrop;
}

/* The backdrop of iOS 6 Messages and iChat: a light blue-gray with very fine
   vertical lines. A tiled picture, so painting it costs one fill. */
+ (NSColor *)defaultBackground
{
    static NSColor *color = nil;
    NSImage *tile;
    if (color)
        return color;
    tile = [[NSImage alloc] initWithSize:NSMakeSize(4, 4)];
    [tile lockFocus];
    [[NSColor colorWithCalibratedRed:215.0 / 255.0 green:219.0 / 255.0 blue:227.0 / 255.0 alpha:1] set];
    NSRectFill(NSMakeRect(0, 0, 4, 4));
    [[NSColor colorWithCalibratedRed:205.0 / 255.0 green:210.0 / 255.0 blue:220.0 / 255.0 alpha:1] set];
    NSRectFill(NSMakeRect(0, 0, 1, 4));
    [tile unlockFocus];
    color = [[NSColor colorWithPatternImage:tile] retain];
    [tile release];
    return color;
}

+ (void)drawBackground:(NSRect)dirty visible:(NSRect)visible
{
    NSString *kind = [self setting:TBThemeBackground];
    NSColor *one = [self colorForKey:TBThemeBackColor];
    NSColor *two = [self colorForKey:TBThemeBackColor2];
    [NSGraphicsContext saveGraphicsState];
    NSRectClip(dirty);
    if ([kind isEqualToString:@"picture"]) {
        NSImage *picture = [self backdropForSize:visible.size];
        if (picture) {
            [picture drawAtPoint:visible.origin fromRect:NSMakeRect(0, 0, visible.size.width, visible.size.height)
                       operation:NSCompositeCopy fraction:1.0];
            [NSGraphicsContext restoreGraphicsState];
            return;
        }
    } else if ([kind isEqualToString:@"gradient"]) {
        [self fillGradient:visible from:one ? one : [NSColor whiteColor] to:two ? two : [NSColor colorWithCalibratedWhite:0.7f alpha:1]];
        [NSGraphicsContext restoreGraphicsState];
        return;
    } else if ([kind isEqualToString:@"solid"]) {
        [(one ? one : [NSColor whiteColor]) set];
        NSRectFill(dirty);
        [NSGraphicsContext restoreGraphicsState];
        return;
    }
    [[self defaultBackground] set];
    NSRectFill(dirty);
    [NSGraphicsContext restoreGraphicsState];
}

@end
