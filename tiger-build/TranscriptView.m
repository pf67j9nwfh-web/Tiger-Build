#import "TranscriptView.h"
#import "TBSupport.h"
#if TB_INLINE_VIDEO
#import <QTKit/QTKit.h>
#endif

@interface TranscriptView (Selection)
- (void)toggleActivityAtView:(NSView *)view;
- (void)syncTextViews;
@end

/* One of these sits on each message so the words can be highlighted and copied.
   A click on an activity card's triangle still expands it. */
@interface TBSelectText : NSTextView
{
    BOOL activity;
}
- (void)setActivity:(BOOL)flag;
@end

@implementation TBSelectText

- (void)setActivity:(BOOL)flag
{
    activity = flag;
}

- (void)mouseDown:(NSEvent *)event
{
    NSPoint local;
    if (activity) {
        local = [self convertPoint:[event locationInWindow] fromView:nil];
        if (local.x < 18.0) {
            [(TranscriptView *)[self superview] toggleActivityAtView:self];
            return;
        }
    }
    [super mouseDown:event];
}

@end

#if TB_INLINE_VIDEO
@interface SaveMovieView : QTMovieView
{
    NSString *mediaPath;
}
- (void)setMediaPath:(NSString *)path;
@end

@implementation SaveMovieView

- (void)setMediaPath:(NSString *)path
{
    if (path == mediaPath)
        return;
    [mediaPath release];
    mediaPath = [path retain];
}

- (void)dealloc
{
    [mediaPath release];
    [super dealloc];
}

- (NSMenu *)saveMenu
{
    NSMenu *menu;
    NSMenuItem *item;
    menu = [[[NSMenu alloc] initWithTitle:@"Video"] autorelease];
    item = [[[NSMenuItem alloc] initWithTitle:@"Save As..."
                                       action:@selector(saveMediaAs:)
                                keyEquivalent:@""] autorelease];
    [item setTarget:[self superview]];
    [item setRepresentedObject:mediaPath];
    [menu addItem:item];
    return menu;
}

- (NSView *)hitTest:(NSPoint)point
{
    NSEvent *event;
    NSPoint local;
    local = [self convertPoint:point fromView:[self superview]];
    if (!NSMouseInRect(local, [self bounds], [self isFlipped]))
        return nil;
    event = [NSApp currentEvent];
    if (event && ([event type] == NSRightMouseDown
        || [event type] == NSRightMouseDragged
        || [event type] == NSRightMouseUp))
        return self;
    return [super hitTest:point];
}

- (NSMenu *)menuForEvent:(NSEvent *)event
{
    (void)event;
    return [self saveMenu];
}

- (void)rightMouseDown:(NSEvent *)event
{
    [NSMenu popUpContextMenu:[self saveMenu] withEvent:event forView:self];
}

@end

#endif

static void appendRoundedRect(NSBezierPath *path, NSRect rect, float radius)
{
    float x = NSMinX(rect);
    float y = NSMinY(rect);
    float w = NSWidth(rect);
    float h = NSHeight(rect);
    if (radius > w / 2.0) radius = w / 2.0;
    if (radius > h / 2.0) radius = h / 2.0;
    [path moveToPoint:NSMakePoint(x + radius, y)];
    [path appendBezierPathWithArcWithCenter:NSMakePoint(x + w - radius, y + radius)
                                      radius:radius startAngle:270 endAngle:0 clockwise:NO];
    [path appendBezierPathWithArcWithCenter:NSMakePoint(x + w - radius, y + h - radius)
                                      radius:radius startAngle:0 endAngle:90 clockwise:NO];
    [path appendBezierPathWithArcWithCenter:NSMakePoint(x + radius, y + h - radius)
                                      radius:radius startAngle:90 endAngle:180 clockwise:NO];
    [path appendBezierPathWithArcWithCenter:NSMakePoint(x + radius, y + radius)
                                      radius:radius startAngle:180 endAngle:270 clockwise:NO];
    [path closePath];
}

/* The iOS 6 Messages bubble: a flat body, a bright rim along the top, a lighter
   glow along the bottom, a thin dark outline, and a pointed tail that is part
   of the outline. Sent bubbles are sky blue, received ones light gray. */
typedef struct {
    CGFloat top[3];     /* rim at the top edge */
    CGFloat body[3];    /* the flat middle */
    CGFloat low[3];     /* glow at the bottom edge */
    CGFloat topEnd;     /* where the rim has faded into the body (0..1 from the top) */
    CGFloat lowStart;   /* where the glow begins */
} ShadeInfo;

/* CGFloat is a double in 64-bit builds, so the callback must say so. */
static void shadeEvaluate(void *info, const CGFloat *in, CGFloat *out)
{
    ShadeInfo *shade = (ShadeInfo *)info;
    CGFloat t = in[0];
    int i;
    for (i = 0; i < 3; i++) {
        CGFloat c = shade->body[i];
        if (t < shade->topEnd) {
            CGFloat k = t / shade->topEnd;
            c = shade->top[i] + (shade->body[i] - shade->top[i]) * k;
        } else if (t > shade->lowStart) {
            CGFloat k = (t - shade->lowStart) / (1.0 - shade->lowStart);
            c = shade->body[i] + (shade->low[i] - shade->body[i]) * k;
        }
        out[i] = c;
    }
    out[3] = 1.0;
}

static void shadeRelease(void *info)
{
    (void)info;
}

static const float sentTop[3] = {203.0 / 255.0, 222.0 / 255.0, 252.0 / 255.0};
static const float sentBody[3] = {130.0 / 255.0, 180.0 / 255.0, 249.0 / 255.0};
static const float sentLow[3] = {178.0 / 255.0, 230.0 / 255.0, 255.0 / 255.0};
static const float sentLine[3] = {58.0 / 255.0, 76.0 / 255.0, 112.0 / 255.0};
static const float gotTop[3] = {248.0 / 255.0, 247.0 / 255.0, 247.0 / 255.0};
static const float gotBody[3] = {203.0 / 255.0, 203.0 / 255.0, 203.0 / 255.0};
static const float gotLow[3] = {219.0 / 255.0, 219.0 / 255.0, 219.0 / 255.0};
static const float gotLine[3] = {78.0 / 255.0, 82.0 / 255.0, 94.0 / 255.0};

/* The bubble's outline: a rounded rectangle whose lower corner on the speaker's
   side sweeps out into a pointed tail. */
static void appendBubble(NSBezierPath *path, NSRect r, float radius, BOOL tailRight)
{
    float left = NSMinX(r);
    float right = NSMaxX(r);
    float bottom = NSMinY(r);
    float top = NSMaxY(r);
    if (radius > (top - bottom) / 2.0)
        radius = (top - bottom) / 2.0;
    if (tailRight) {
        [path moveToPoint:NSMakePoint(left + radius, top)];
        [path lineToPoint:NSMakePoint(right - radius, top)];
        [path appendBezierPathWithArcWithCenter:NSMakePoint(right - radius, top - radius)
                                         radius:radius startAngle:90 endAngle:0 clockwise:YES];
        [path lineToPoint:NSMakePoint(right, bottom + 15)];
        [path curveToPoint:NSMakePoint(right + 8, bottom - 3)
             controlPoint1:NSMakePoint(right, bottom + 8)
             controlPoint2:NSMakePoint(right + 3, bottom + 1)];
        [path curveToPoint:NSMakePoint(right - 10, bottom)
             controlPoint1:NSMakePoint(right + 3, bottom - 2)
             controlPoint2:NSMakePoint(right - 3, bottom - 0.5)];
        [path lineToPoint:NSMakePoint(left + radius, bottom)];
        [path appendBezierPathWithArcWithCenter:NSMakePoint(left + radius, bottom + radius)
                                         radius:radius startAngle:270 endAngle:180 clockwise:YES];
        [path lineToPoint:NSMakePoint(left, top - radius)];
        [path appendBezierPathWithArcWithCenter:NSMakePoint(left + radius, top - radius)
                                         radius:radius startAngle:180 endAngle:90 clockwise:YES];
    } else {
        [path moveToPoint:NSMakePoint(left + radius, top)];
        [path lineToPoint:NSMakePoint(right - radius, top)];
        [path appendBezierPathWithArcWithCenter:NSMakePoint(right - radius, top - radius)
                                         radius:radius startAngle:90 endAngle:0 clockwise:YES];
        [path lineToPoint:NSMakePoint(right, bottom + radius)];
        [path appendBezierPathWithArcWithCenter:NSMakePoint(right - radius, bottom + radius)
                                         radius:radius startAngle:0 endAngle:270 clockwise:YES];
        [path lineToPoint:NSMakePoint(left + 10, bottom)];
        [path curveToPoint:NSMakePoint(left - 8, bottom - 3)
             controlPoint1:NSMakePoint(left + 3, bottom - 0.5)
             controlPoint2:NSMakePoint(left - 3, bottom - 2)];
        [path curveToPoint:NSMakePoint(left, bottom + 15)
             controlPoint1:NSMakePoint(left - 3, bottom + 1)
             controlPoint2:NSMakePoint(left, bottom + 8)];
        [path lineToPoint:NSMakePoint(left, top - radius)];
        [path appendBezierPathWithArcWithCenter:NSMakePoint(left + radius, top - radius)
                                         radius:radius startAngle:180 endAngle:90 clockwise:YES];
    }
    [path closePath];
}

static void fillBubble(NSBezierPath *path, NSRect rect, BOOL sent)
{
    ShadeInfo shade;
    CGFunctionCallbacks callbacks;
    CGFloat domain[2];
    CGFloat range[8];
    CGFunctionRef function;
    CGColorSpaceRef space;
    CGShadingRef shading;
    CGPoint start;
    CGPoint end;
    const float *top = sent ? sentTop : gotTop;
    const float *body = sent ? sentBody : gotBody;
    const float *low = sent ? sentLow : gotLow;
    float height = NSHeight(rect);
    int i;

    for (i = 0; i < 3; i++) {
        shade.top[i] = top[i];
        shade.body[i] = body[i];
        shade.low[i] = low[i];
    }
    /* The rim is about 12 pixels deep and the glow 16, however tall the bubble. */
    shade.topEnd = height > 0 ? fminf(12.0f, height * 0.4f) / height : 0.3;
    shade.lowStart = height > 0 ? 1.0 - fminf(16.0f, height * 0.45f) / height : 0.6;
    callbacks.version = 0;
    callbacks.evaluate = shadeEvaluate;
    callbacks.releaseInfo = shadeRelease;
    domain[0] = 0;
    domain[1] = 1;
    for (i = 0; i < 8; i++) {
        range[i] = (i % 2 == 0) ? 0.0 : 1.0;
    }
    function = CGFunctionCreate(&shade, 1, domain, 4, range, &callbacks);
    space = CGColorSpaceCreateDeviceRGB();
    start = CGPointMake(NSMidX(rect), NSMaxY(rect));
    end = CGPointMake(NSMidX(rect), NSMinY(rect));
    /* Extended, so the tail below the bubble's bottom edge is painted too. */
    shading = CGShadingCreateAxial(space, start, end, function, 1, 1);
    [NSGraphicsContext saveGraphicsState];
    [path addClip];
    CGContextDrawShading((CGContextRef)[[NSGraphicsContext currentContext] graphicsPort], shading);
    [NSGraphicsContext restoreGraphicsState];
    CGShadingRelease(shading);
    CGColorSpaceRelease(space);
    CGFunctionRelease(function);
}

@implementation TranscriptView

/* The backdrop of iOS 6 Messages and iChat: a light blue-gray with very fine
   vertical lines. A tiled picture, so painting it costs one fill. */
+ (NSColor *)backgroundColor
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

- (id)initWithFrame:(NSRect)frame
{
    NSMutableParagraphStyle *style;
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    messages = [[NSArray alloc] init];
    boxes = [[NSMutableArray alloc] init];
    movieViews = [[NSMutableArray alloc] init];
    moviePaths = [[NSMutableArray alloc] init];
    imageCache = [[NSMutableDictionary alloc] init];
    sizeCache = [[NSMutableDictionary alloc] init];
    textViews = [[NSMutableArray alloc] init];
    style = [[NSMutableParagraphStyle alloc] init];
    [style setLineBreakMode:NSLineBreakByWordWrapping];
    bodyAttrs = [[NSDictionary alloc] initWithObjectsAndKeys:
        [NSFont systemFontOfSize:14], NSFontAttributeName,
        [NSColor colorWithCalibratedWhite:0.08 alpha:1], NSForegroundColorAttributeName,
        style, NSParagraphStyleAttributeName,
        nil];
    userAttrs = [[NSDictionary alloc] initWithObjectsAndKeys:
        [NSFont systemFontOfSize:14], NSFontAttributeName,
        [NSColor colorWithCalibratedWhite:0.06 alpha:1], NSForegroundColorAttributeName,
        style, NSParagraphStyleAttributeName,
        nil];
    statusAttrs = [[NSDictionary alloc] initWithObjectsAndKeys:
        [NSFont systemFontOfSize:11], NSFontAttributeName,
        [NSColor colorWithCalibratedWhite:0.35 alpha:1], NSForegroundColorAttributeName,
        style, NSParagraphStyleAttributeName,
        nil];
    [style release];
    return self;
}

- (void)dealloc
{
    [messages release];
    [boxes release];
    [movieViews release];
    [moviePaths release];
    [imageCache release];
    [sizeCache release];
    [textViews release];
    [bodyAttrs release];
    [userAttrs release];
    [statusAttrs release];
    [super dealloc];
}

/* Pictures used to be read from disk on every layout and every redraw,
   which made scrolling slow on older Macs. Keep decoded images in memory. */
- (NSImage *)cachedImage:(NSString *)path
{
    NSImage *picture;
    if (!path)
        return nil;
    picture = [imageCache objectForKey:path];
    if (picture)
        return picture;
    if (![[NSFileManager defaultManager] fileExistsAtPath:path])
        return nil;
    picture = [[NSImage alloc] initWithContentsOfFile:path];
    if (!picture)
        return nil;
    if ([imageCache count] >= 48)
        [imageCache removeAllObjects];
    [imageCache setObject:picture forKey:path];
    [picture release];
    return picture;
}

- (BOOL)playingVideo:(NSString *)path
{
    unsigned i;
    for (i = 0; i < [moviePaths count] && i < [movieViews count]; i++) {
        if ([[moviePaths objectAtIndex:i] isEqualToString:path])
            return [movieViews objectAtIndex:i] != [NSNull null];
    }
    return NO;
}

- (void)placeMovies
{
#if !TB_INLINE_VIDEO
    /* 64-bit builds have no QuickTime player view; videos open in the default player. */
    return;
#else
    NSMutableArray *paths;
    NSMutableArray *rects;
    unsigned i;
    BOOL same;
    paths = [NSMutableArray array];
    rects = [NSMutableArray array];
    for (i = 0; i < [boxes count]; i++) {
        NSDictionary *box = [boxes objectAtIndex:i];
        if ([box objectForKey:@"video"] && [box objectForKey:@"videoRect"]) {
            [paths addObject:[box objectForKey:@"video"]];
            [rects addObject:[box objectForKey:@"videoRect"]];
        }
    }
    same = [paths count] == [moviePaths count];
    for (i = 0; same && i < [paths count]; i++) {
        if (![[paths objectAtIndex:i] isEqualToString:[moviePaths objectAtIndex:i]])
            same = NO;
    }
    if (same) {
        for (i = 0; i < [movieViews count] && i < [rects count]; i++) {
            id view = [movieViews objectAtIndex:i];
            if (view != [NSNull null])
                [view setFrame:[[rects objectAtIndex:i] rectValue]];
        }
        return;
    }
    for (i = 0; i < [movieViews count]; i++) {
        id view = [movieViews objectAtIndex:i];
        if (view != [NSNull null])
            [view removeFromSuperview];
    }
    [movieViews removeAllObjects];
    [moviePaths removeAllObjects];
    for (i = 0; i < [paths count]; i++) {
        NSString *path = [paths objectAtIndex:i];
        QTMovie *movie = [QTMovie movieWithFile:path error:nil];
        SaveMovieView *view;
        [moviePaths addObject:path];
        if (!movie) {
            [movieViews addObject:[NSNull null]];
            continue;
        }
        view = [[SaveMovieView alloc] initWithFrame:[[rects objectAtIndex:i] rectValue]];
        [view setMovie:movie];
        [view setMediaPath:path];
        [view setPreservesAspectRatio:YES];
        [view setControllerVisible:YES];
        [view setEditable:NO];
        [self addSubview:view];
        [movieViews addObject:view];
        [view release];
    }
#endif
}

- (void)setMessages:(NSArray *)newMessages
{
    if (newMessages != messages)
        [sizeCache removeAllObjects];
    [newMessages retain];
    [messages release];
    messages = newMessages;
    [self layoutForWidth:layoutWidth visibleHeight:visibleHeight];
}

- (NSDictionary *)attrsForUser:(BOOL)fromUser
{
    if (fromUser)
        return userAttrs;
    return bodyAttrs;
}

/* Measuring wraps every message's text, which is the slow part of laying out
   a chat. A message that did not change since the last layout keeps its size,
   so a streaming reply only re-measures itself. */
- (NSRect)measureText:(NSString *)text attrs:(NSDictionary *)attrs width:(float)width height:(float)height forMessage:(id)message
{
    NSValue *key = [NSValue valueWithPointer:message];
    NSString *signature = [NSString stringWithFormat:@"%lu|%.0f|%.0f|%@", (unsigned long)[text length], width, height,
        attrs == statusAttrs ? @"s" : (attrs == userAttrs ? @"u" : (attrs == bodyAttrs ? @"b" : @"m"))];
    NSArray *hit = [sizeCache objectForKey:key];
    NSRect used;
    if (hit && [[hit objectAtIndex:0] isEqualToString:signature])
        return [[hit objectAtIndex:1] rectValue];
    used = [text boundingRectWithSize:NSMakeSize(width, height) options:NSStringDrawingUsesLineFragmentOrigin attributes:attrs];
    if ([sizeCache count] > 4000)
        [sizeCache removeAllObjects];
    [sizeCache setObject:[NSArray arrayWithObjects:signature, [NSValue valueWithRect:used], nil] forKey:key];
    return used;
}

- (void)layoutForWidth:(float)width visibleHeight:(float)visible
{
    float maxText;
    float yFromTop;
    float contentH;
    unsigned i;

    layoutWidth = width;
    visibleHeight = visible;
    if (layoutWidth < 80)
        layoutWidth = 80;
    [boxes removeAllObjects];
    maxText = layoutWidth - 150;
    if (maxText < 120)
        maxText = layoutWidth - 48;
    yFromTop = 16;
    for (i = 0; i < [messages count]; i++) {
        NSDictionary *message = [messages objectAtIndex:i];
        NSString *text = [message objectForKey:@"text"];
        NSString *imagePath = [message objectForKey:@"image"];
        NSString *videoPath = [message objectForKey:@"video"];
        BOOL status = [[message objectForKey:@"status"] boolValue];
        BOOL open = [[message objectForKey:@"open"] boolValue];
        BOOL fromUser = [[message objectForKey:@"role"] isEqualToString:@"user"];
        NSDictionary *attrs;
        NSRect used;
        NSRect bubble;
        NSMutableDictionary *box;
        float imageH = 0;
        float imageW = 0;
        float videoH = 0;
        float videoW = 0;
        if (!text)
            text = @"";
        if (open && [text length] == 0
            && (!imagePath || [imagePath length] == 0)
            && (!videoPath || [videoPath length] == 0))
            text = @"...";
        if (status)
            attrs = statusAttrs;
        else
            attrs = [self attrsForUser:fromUser];
        BOOL activity=[message objectForKey:@"activityKind"]!=nil;
        if(activity) {
            NSString *prefix=[NSString stringWithFormat:@"%C ", (unichar)([[message objectForKey:@"expanded"] boolValue] ? 0x25bc : 0x25b6)];
            text=[prefix stringByAppendingString:text];
            if([[message objectForKey:@"expanded"] boolValue]&&[[message objectForKey:@"detail"] length])
                text=[text stringByAppendingFormat:@"\n%@",[message objectForKey:@"detail"]];
            NSMutableDictionary *mono=[NSMutableDictionary dictionaryWithDictionary:statusAttrs];
            [mono setObject:[NSFont fontWithName:@"Monaco" size:11] forKey:NSFontAttributeName];
            attrs=mono;
        }
        used = [self measureText:text attrs:attrs
                           width:(status ? layoutWidth - (activity ? 64 : 48) : maxText)
                          height:(activity ? 1000000 : 4000) forMessage:message];
        if (used.size.width < 12)
            used.size.width = 12;
        if (!status && imagePath && [self cachedImage:imagePath]) {
            NSImage *picture = [self cachedImage:imagePath];
            NSSize isize = [picture size];
            imageW = maxText;
            imageH = 160;
            if (isize.width > 1 && isize.height > 1) {
                imageH = isize.height * (imageW / isize.width);
                if (imageH > 220) {
                    imageH = 220;
                    imageW = isize.width * (220.0 / isize.height);
                }
            }
        }
        if (!status && videoPath && [[NSFileManager defaultManager] fileExistsAtPath:videoPath]) {
            videoW = maxText;
            videoH = videoW * 9.0 / 16.0;
            if (videoH > 220) {
                videoH = 220;
                videoW = 220.0 * 16.0 / 9.0;
            }
        }
        if (used.size.height < 16 && !((imageH > 0 || videoH > 0) && [text length] == 0))
            used.size.height = 16;
        box = [NSMutableDictionary dictionary];
        [box setObject:text forKey:@"text"];
        [box setObject:message forKey:@"message"];
        [box setObject:attrs forKey:@"attrs"];
        [box setObject:[NSNumber numberWithBool:activity] forKey:@"activity"];
        [box setObject:[NSNumber numberWithBool:status] forKey:@"status"];
        [box setObject:[NSNumber numberWithBool:fromUser] forKey:@"user"];
        if (imageH > 0) {
            [box setObject:imagePath forKey:@"image"];
            [box setObject:[NSValue valueWithSize:NSMakeSize(imageW, imageH)] forKey:@"imageSize"];
        }
        if (videoH > 0) {
            [box setObject:videoPath forKey:@"video"];
            [box setObject:[NSValue valueWithSize:NSMakeSize(videoW, videoH)] forKey:@"videoSize"];
        }
        if (status) {
            [box setObject:[NSValue valueWithRect:NSMakeRect(24, yFromTop, layoutWidth - 48, used.size.height+(activity?18:0))] forKey:@"topRect"];
            yFromTop += used.size.height + (activity?28:10);
        } else {
            bubble.size.width = used.size.width + 34;
            if (imageW + 34 > bubble.size.width)
                bubble.size.width = imageW + 34;
            if (videoW + 34 > bubble.size.width)
                bubble.size.width = videoW + 34;
            bubble.size.height = used.size.height + 18;
            if (imageH > 0)
                bubble.size.height += imageH + 8;
            if (videoH > 0)
                bubble.size.height += videoH + 8;
            if (bubble.size.height < 36)
                bubble.size.height = 36;
            [box setObject:[NSValue valueWithSize:used.size] forKey:@"textSize"];
            [box setObject:[NSValue valueWithRect:NSMakeRect(0, yFromTop, bubble.size.width, bubble.size.height)] forKey:@"topRect"];
            yFromTop += bubble.size.height + 10;
        }
        [boxes addObject:box];
    }
    contentH = yFromTop + 8;
    if (contentH < visibleHeight)
        contentH = visibleHeight;
    if (contentH < 40)
        contentH = 40;
    for (i = 0; i < [boxes count]; i++) {
        NSMutableDictionary *box = [boxes objectAtIndex:i];
        NSRect topRect = [[box objectForKey:@"topRect"] rectValue];
        NSRect rect;
        BOOL status = [[box objectForKey:@"status"] boolValue];
        BOOL fromUser = [[box objectForKey:@"user"] boolValue];
        rect.size = topRect.size;
        rect.origin.y = contentH - topRect.origin.y - topRect.size.height;
        if (status)
            rect.origin.x = 24;
        else if (fromUser)
            rect.origin.x = layoutWidth - 18 - rect.size.width;
        else
            rect.origin.x = 16;
        [box setObject:[NSValue valueWithRect:rect] forKey:@"rect"];
        if (!status) {
            float stackY = NSMinY(rect) + 10;
            if ([box objectForKey:@"image"]) {
                NSSize imageSize = [[box objectForKey:@"imageSize"] sizeValue];
                NSRect imageRect = NSMakeRect(NSMinX(rect) + 17, stackY, imageSize.width, imageSize.height);
                [box setObject:[NSValue valueWithRect:imageRect] forKey:@"imageRect"];
                stackY += imageSize.height + 8;
            }
            if ([box objectForKey:@"video"]) {
                NSSize videoSize = [[box objectForKey:@"videoSize"] sizeValue];
                NSRect videoRect = NSMakeRect(NSMinX(rect) + 17, stackY, videoSize.width, videoSize.height);
                [box setObject:[NSValue valueWithRect:videoRect] forKey:@"videoRect"];
            }
        }
        {
            NSRect textRect;
            if (status) {
                textRect = rect;
                if ([[box objectForKey:@"activity"] boolValue])
                    textRect = NSInsetRect(rect, 8, 8);
            } else {
                NSSize textSize = [[box objectForKey:@"textSize"] sizeValue];
                textRect.size = textSize;
                textRect.origin.x = NSMinX(rect) + 17;
                if ([box objectForKey:@"image"] || [box objectForKey:@"video"])
                    textRect.origin.y = NSMaxY(rect) - 10 - textSize.height;
                else
                    textRect.origin.y = NSMinY(rect) + (NSHeight(rect) - textSize.height) / 2.0;
            }
            [box setObject:[NSValue valueWithRect:textRect] forKey:@"textRect"];
        }
    }
    [self setFrameSize:NSMakeSize(layoutWidth, contentH)];
    [self placeMovies];
    [self syncTextViews];
    [self setNeedsDisplay:YES];
}

- (NSTextView *)textViewAt:(unsigned)index
{
    TBSelectText *view;
    NSTextContainer *container;
    if (index < [textViews count])
        return [textViews objectAtIndex:index];
    view = [[TBSelectText alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
    [view setEditable:NO];
    [view setSelectable:YES];
    [view setDrawsBackground:NO];
    [view setRichText:YES];
    [view setImportsGraphics:NO];
    [view setFocusRingType:NSFocusRingTypeNone];
    [view setVerticallyResizable:NO];
    [view setHorizontallyResizable:NO];
    [view setAutoresizingMask:NSViewNotSizable];
    [view setTextContainerInset:NSMakeSize(0, 0)];
    container = [view textContainer];
    [container setLineFragmentPadding:0];
    [container setWidthTracksTextView:YES];
    [self addSubview:view];
    [textViews addObject:view];
    [view release];
    return view;
}

- (void)syncTextViews
{
    unsigned i;
    while ([textViews count] > [boxes count]) {
        NSTextView *extra = [textViews lastObject];
        [extra removeFromSuperview];
        [textViews removeLastObject];
    }
    for (i = 0; i < [boxes count]; i++) {
        NSDictionary *box = [boxes objectAtIndex:i];
        NSString *text = [box objectForKey:@"text"];
        NSDictionary *attrs = [box objectForKey:@"attrs"];
        NSRect textRect = [[box objectForKey:@"textRect"] rectValue];
        NSTextView *view = [self textViewAt:i];
        NSTextStorage *storage;
        if (!text)
            text = @"";
        [(TBSelectText *)view setActivity:[[box objectForKey:@"activity"] boolValue]];
        if (!NSEqualRects([view frame], textRect))
            [view setFrame:textRect];
        if (fabsf([[view textContainer] containerSize].width - NSWidth(textRect)) > 0.5f)
            [[view textContainer] setContainerSize:NSMakeSize(NSWidth(textRect), 1000000)];
        if (![[view string] isEqualToString:text]) {
            [view setString:text];
            storage = [view textStorage];
            if ([text length] > 0)
                [storage setAttributes:attrs range:NSMakeRange(0, [text length])];
        }
    }
}

- (void)toggleActivityAtView:(NSView *)view
{
    NSUInteger index = [textViews indexOfObject:view];
    NSMutableDictionary *message;
    if (index == NSNotFound || index >= [boxes count])
        return;
    message = [[boxes objectAtIndex:index] objectForKey:@"message"];
    [message setObject:[NSNumber numberWithBool:![[message objectForKey:@"expanded"] boolValue]] forKey:@"expanded"];
    [self layoutForWidth:layoutWidth visibleHeight:visibleHeight];
    [self setNeedsDisplay:YES];
}

- (void)scrollToEnd
{
    NSScrollView *scroll = [self enclosingScrollView];
    NSClipView *clip;
    if (!scroll)
        return;
    clip = [scroll contentView];
    [clip scrollToPoint:NSMakePoint(0, 0)];
    [scroll reflectScrolledClipView:clip];
}

- (void)drawRect:(NSRect)dirty
{
    unsigned i;

    [[TranscriptView backgroundColor] set];
    NSRectFill(dirty);
    for (i = 0; i < [boxes count]; i++) {
        NSDictionary *box = [boxes objectAtIndex:i];
        NSRect rect = [[box objectForKey:@"rect"] rectValue];
        BOOL status = [[box objectForKey:@"status"] boolValue];
        BOOL fromUser = [[box objectForKey:@"user"] boolValue];
        if (status) {
            if([[box objectForKey:@"activity"] boolValue]) {
                NSBezierPath *card=[NSBezierPath bezierPath];appendRoundedRect(card,rect,5);
                [[NSColor colorWithCalibratedWhite:0.96 alpha:1] set];[card fill];
                [[NSColor colorWithCalibratedWhite:0.72 alpha:1] set];[card setLineWidth:1];[card stroke];
            }
            continue;
        }
        {
            NSBezierPath *path = [NSBezierPath bezierPath];
            NSBezierPath *light = [NSBezierPath bezierPath];
            const float *line = fromUser ? sentLine : gotLine;
            float radius = 16;
            appendBubble(path, rect, radius, fromUser);
            fillBubble(path, rect, fromUser);
            /* A faint bright line just inside the outline, over the upper half only.
               Going all the way round drew a white arc across the tail. */
            {
                float left = NSMinX(rect) + 1.5f;
                float right = NSMaxX(rect) - 1.5f;
                float topY = NSMaxY(rect) - 1.5f;
                float midY = NSMidY(rect);
                float r = radius - 1.5f;
                if (r > (topY - midY))
                    r = topY - midY;
                [light moveToPoint:NSMakePoint(left, midY)];
                [light lineToPoint:NSMakePoint(left, topY - r)];
                [light appendBezierPathWithArcWithCenter:NSMakePoint(left + r, topY - r) radius:r startAngle:180 endAngle:90 clockwise:YES];
                [light lineToPoint:NSMakePoint(right - r, topY)];
                [light appendBezierPathWithArcWithCenter:NSMakePoint(right - r, topY - r) radius:r startAngle:90 endAngle:0 clockwise:YES];
                [light lineToPoint:NSMakePoint(right, midY)];
            }
            [NSGraphicsContext saveGraphicsState];
            [path addClip];
            [[NSColor colorWithCalibratedWhite:1 alpha:fromUser ? 0.30 : 0.55] set];
            [light setLineWidth:1];
            [light stroke];
            [NSGraphicsContext restoreGraphicsState];
            [[NSColor colorWithCalibratedRed:line[0] green:line[1] blue:line[2] alpha:1] set];
            [path setLineWidth:1.2];
            [path stroke];
            if ([box objectForKey:@"imageRect"]) {
                NSImage *picture = [self cachedImage:[box objectForKey:@"image"]];
                NSRect imageRect = [[box objectForKey:@"imageRect"] rectValue];
                if (picture)
                    [picture drawInRect:imageRect fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1.0];
            }
            if ([box objectForKey:@"videoRect"] && ![self playingVideo:[box objectForKey:@"video"]]) {
                NSRect videoRect = [[box objectForKey:@"videoRect"] rectValue];
                [[NSColor colorWithCalibratedWhite:0.15 alpha:1] set];
                NSRectFill(videoRect);
                [(TB_INLINE_VIDEO ? @"QuickTime could not open this video." : @"Double-click to play this video.")
                    drawInRect:videoRect withAttributes:statusAttrs];
            }
        }
    }
}

- (BOOL)isFlipped
{
    return NO;
}

- (NSMenu *)menuForEvent:(NSEvent *)event
{
    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
    NSString *path = nil;
    NSMenu *menu;
    NSMenuItem *item;
    unsigned i;
    for (i = 0; i < [boxes count]; i++) {
        NSDictionary *box = [boxes objectAtIndex:i];
        NSRect hit;
        if ([box objectForKey:@"imageRect"]) {
            hit = [[box objectForKey:@"imageRect"] rectValue];
            if (NSPointInRect(point, hit)) {
                path = [box objectForKey:@"image"];
                break;
            }
        }
        if ([box objectForKey:@"videoRect"]) {
            hit = [[box objectForKey:@"videoRect"] rectValue];
            if (NSPointInRect(point, hit)) {
                path = [box objectForKey:@"video"];
                break;
            }
        }
    }
    if (!path) {
        for(i=0;i<[boxes count];i++) {
            NSDictionary *box=[boxes objectAtIndex:i];
            if(!NSPointInRect(point,[[box objectForKey:@"rect"] rectValue]))continue;
            NSDictionary *message=[box objectForKey:@"message"];
            NSString *content=[[box objectForKey:@"activity"] boolValue]?[message objectForKey:@"detail"]:[message objectForKey:@"text"];
            menu=[[[NSMenu alloc] initWithTitle:@"Message"] autorelease];
            item=[[[NSMenuItem alloc] initWithTitle:@"Copy Text" action:@selector(copyMessageText:) keyEquivalent:@"c"] autorelease];
            [item setTarget:self];[item setRepresentedObject:content?content:@""];[menu addItem:item];return menu;
        }
        return [super menuForEvent:event];
    }
    menu = [[[NSMenu alloc] initWithTitle:@"Media"] autorelease];
    item = [[[NSMenuItem alloc] initWithTitle:@"Save As..."
                                       action:@selector(saveMediaAs:)
                                keyEquivalent:@""] autorelease];
    [item setTarget:self];
    [item setRepresentedObject:path];
    [menu addItem:item];
    return menu;
}

/* Double-click a picture: Leopard and Snow Leopard have Quick Look, which
   shows it in a floating preview; on Tiger it opens in the default viewer. */
- (void)openMediaPath:(NSString *)path
{
    if(!path)return;
    if(TBSystemMinor()>=5&&[[NSFileManager defaultManager] isExecutableFileAtPath:@"/usr/bin/qlmanage"]) {
        NSTask *task=[[[NSTask alloc] init] autorelease];
        [task setLaunchPath:@"/usr/bin/qlmanage"];
        [task setArguments:[NSArray arrayWithObjects:@"-p",path,nil]];
        [task setStandardOutput:[NSFileHandle fileHandleWithNullDevice]];
        [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];
        [task launch];
        return;
    }
    [[NSWorkspace sharedWorkspace] openFile:path];
}
- (void)copyMessageText:(id)sender
{
    NSPasteboard *p=[NSPasteboard generalPasteboard];[p declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
    [p setString:[sender representedObject] forType:NSStringPboardType];
}
- (void)mouseDown:(NSEvent *)event
{
    NSPoint point=[self convertPoint:[event locationInWindow] fromView:nil];unsigned i;
    if([event clickCount]>1) {
        for(i=0;i<[boxes count];i++) {
            NSDictionary *pictureBox=[boxes objectAtIndex:i];
            if([pictureBox objectForKey:@"imageRect"]&&NSPointInRect(point,[[pictureBox objectForKey:@"imageRect"] rectValue])) {
                [self openMediaPath:[pictureBox objectForKey:@"image"]];return;
            }
        }
        for(i=0;i<[boxes count];i++) {
            NSDictionary *box=[boxes objectAtIndex:i];
            if([box objectForKey:@"videoRect"]&&NSPointInRect(point,[[box objectForKey:@"videoRect"] rectValue])&&![self playingVideo:[box objectForKey:@"video"]]) {
                [[NSWorkspace sharedWorkspace] openFile:[box objectForKey:@"video"]];return;
            }
        }
    }
    for(i=0;i<[boxes count];i++) {
        NSDictionary *box=[boxes objectAtIndex:i];
        if([[box objectForKey:@"activity"] boolValue]&&NSPointInRect(point,[[box objectForKey:@"rect"] rectValue])) {
            NSMutableDictionary *m=[box objectForKey:@"message"];
            [m setObject:[NSNumber numberWithBool:![[m objectForKey:@"expanded"] boolValue]] forKey:@"expanded"];
            [self layoutForWidth:layoutWidth visibleHeight:visibleHeight];[self setNeedsDisplay:YES];return;
        }
    }
    [super mouseDown:event];
}
- (void)setActivitiesExpanded:(BOOL)expanded
{
    unsigned i;
    for(i=0;i<[messages count];i++) {
        NSMutableDictionary *m=[messages objectAtIndex:i];
        if([m objectForKey:@"activityKind"]) [m setObject:[NSNumber numberWithBool:expanded] forKey:@"expanded"];
    }
    [self layoutForWidth:layoutWidth visibleHeight:visibleHeight];[self setNeedsDisplay:YES];
}

- (void)saveMediaAs:(id)sender
{
    NSString *path = [sender representedObject];
    NSSavePanel *panel;
    NSString *name;
    NSData *data;
    NSString *dest;
    int result;
    if (!path || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSBeep();
        return;
    }
    panel = [NSSavePanel savePanel];
    name = [path lastPathComponent];
    if ([[name pathExtension] length] > 0)
        [panel setRequiredFileType:[name pathExtension]];
    result = [panel runModalForDirectory:[@"~/Desktop" stringByExpandingTildeInPath] file:name];
    if (result != NSOKButton)
        return;
    dest = [panel filename];
    data = [NSData dataWithContentsOfFile:path];
    if (!data || ![data writeToFile:dest atomically:YES])
        NSBeep();
}

@end
