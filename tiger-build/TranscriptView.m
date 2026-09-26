#import "TranscriptView.h"

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

typedef struct {
    float top[3];
    float bottom[3];
} ShadeInfo;

static void shadeEvaluate(void *info, const float *in, float *out)
{
    ShadeInfo *shade = (ShadeInfo *)info;
    float t = in[0];
    float gloss = 0.0;
    int i;
    if (t < 0.28)
        gloss = (0.28 - t) / 0.28 * 0.62;
    for (i = 0; i < 3; i++) {
        float c = shade->top[i] + (shade->bottom[i] - shade->top[i]) * t;
        c = c + (1.0 - c) * gloss;
        out[i] = c;
    }
    out[3] = 1.0;
}

static void shadeRelease(void *info)
{
    (void)info;
}

static void fillBubble(NSBezierPath *path, NSRect rect, float *top, float *bottom)
{
    ShadeInfo shade;
    CGFunctionCallbacks callbacks;
    float domain[2];
    float range[8];
    CGFunctionRef function;
    CGColorSpaceRef space;
    CGShadingRef shading;
    CGPoint start;
    CGPoint end;
    int i;

    for (i = 0; i < 3; i++) {
        shade.top[i] = top[i];
        shade.bottom[i] = bottom[i];
    }
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
    shading = CGShadingCreateAxial(space, start, end, function, 0, 0);
    [NSGraphicsContext saveGraphicsState];
    [path addClip];
    CGContextDrawShading((CGContextRef)[[NSGraphicsContext currentContext] graphicsPort], shading);
    [NSGraphicsContext restoreGraphicsState];
    CGShadingRelease(shading);
    CGColorSpaceRelease(space);
    CGFunctionRelease(function);
}

@implementation TranscriptView

- (id)initWithFrame:(NSRect)frame
{
    NSMutableParagraphStyle *style;
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    messages = [[NSArray alloc] init];
    boxes = [[NSMutableArray alloc] init];
    style = [[NSMutableParagraphStyle alloc] init];
    [style setLineBreakMode:NSLineBreakByWordWrapping];
    bodyAttrs = [[NSDictionary alloc] initWithObjectsAndKeys:
        [NSFont systemFontOfSize:14], NSFontAttributeName,
        [NSColor colorWithCalibratedWhite:0.08 alpha:1], NSForegroundColorAttributeName,
        style, NSParagraphStyleAttributeName,
        nil];
    userAttrs = [[NSDictionary alloc] initWithObjectsAndKeys:
        [NSFont systemFontOfSize:14], NSFontAttributeName,
        [NSColor whiteColor], NSForegroundColorAttributeName,
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
    [bodyAttrs release];
    [userAttrs release];
    [statusAttrs release];
    [super dealloc];
}

- (void)setMessages:(NSArray *)newMessages
{
    [messages release];
    messages = [newMessages retain];
    [self layoutForWidth:layoutWidth visibleHeight:visibleHeight];
}

- (NSDictionary *)attrsForUser:(BOOL)fromUser
{
    if (fromUser)
        return userAttrs;
    return bodyAttrs;
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
        BOOL status = [[message objectForKey:@"status"] boolValue];
        BOOL open = [[message objectForKey:@"open"] boolValue];
        BOOL fromUser = [[message objectForKey:@"role"] isEqualToString:@"user"];
        NSDictionary *attrs;
        NSRect used;
        NSRect bubble;
        NSMutableDictionary *box;
        if (!text)
            text = @"";
        if (open && [text length] == 0)
            text = @"...";
        if (status)
            attrs = statusAttrs;
        else
            attrs = [self attrsForUser:fromUser];
        used = [text boundingRectWithSize:NSMakeSize(status ? layoutWidth - 48 : maxText, 4000)
                                   options:NSStringDrawingUsesLineFragmentOrigin
                                attributes:attrs];
        if (used.size.width < 12)
            used.size.width = 12;
        if (used.size.height < 16)
            used.size.height = 16;
        box = [NSMutableDictionary dictionary];
        [box setObject:text forKey:@"text"];
        [box setObject:[NSNumber numberWithBool:status] forKey:@"status"];
        [box setObject:[NSNumber numberWithBool:fromUser] forKey:@"user"];
        if (status) {
            [box setObject:[NSValue valueWithRect:NSMakeRect(24, yFromTop, layoutWidth - 48, used.size.height)] forKey:@"topRect"];
            yFromTop += used.size.height + 10;
        } else {
            bubble.size.width = used.size.width + 28;
            bubble.size.height = used.size.height + 18;
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
    }
    [self setFrameSize:NSMakeSize(layoutWidth, contentH)];
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
    float blueTop[3] = {126.0 / 255.0, 198.0 / 255.0, 252.0 / 255.0};
    float blueBottom[3] = {12.0 / 255.0, 112.0 / 255.0, 222.0 / 255.0};
    float grayTop[3] = {252.0 / 255.0, 252.0 / 255.0, 254.0 / 255.0};
    float grayBottom[3] = {208.0 / 255.0, 208.0 / 255.0, 216.0 / 255.0};
    unsigned i;

    [[NSColor colorWithCalibratedRed:215.0 / 255.0 green:218.0 / 255.0 blue:224.0 / 255.0 alpha:1] set];
    NSRectFill([self bounds]);
    for (i = 0; i < [boxes count]; i++) {
        NSDictionary *box = [boxes objectAtIndex:i];
        NSRect rect = [[box objectForKey:@"rect"] rectValue];
        NSString *text = [box objectForKey:@"text"];
        BOOL status = [[box objectForKey:@"status"] boolValue];
        BOOL fromUser = [[box objectForKey:@"user"] boolValue];
        if (status) {
            NSRect textRect = rect;
            [text drawInRect:textRect withAttributes:statusAttrs];
            continue;
        }
        {
            NSBezierPath *path = [NSBezierPath bezierPath];
            NSBezierPath *tail = [NSBezierPath bezierPath];
            NSRect textRect;
            NSSize textSize = [[box objectForKey:@"textSize"] sizeValue];
            float radius = 16;
            float *top = fromUser ? blueTop : grayTop;
            float *bottom = fromUser ? blueBottom : grayBottom;
            if (radius > rect.size.height / 2.0)
                radius = rect.size.height / 2.0;
            appendRoundedRect(path, rect, radius);
            [[NSColor colorWithCalibratedRed:bottom[0] green:bottom[1] blue:bottom[2] alpha:1] set];
            [path fill];
            fillBubble(path, rect, top, bottom);
            if (fromUser) {
                [tail moveToPoint:NSMakePoint(NSMaxX(rect) - 22, NSMinY(rect) + 10)];
                [tail lineToPoint:NSMakePoint(NSMaxX(rect) - 6, NSMinY(rect) + 2)];
                [tail lineToPoint:NSMakePoint(NSMaxX(rect) + 8, NSMinY(rect) - 8)];
            } else {
                [tail moveToPoint:NSMakePoint(NSMinX(rect) + 22, NSMinY(rect) + 10)];
                [tail lineToPoint:NSMakePoint(NSMinX(rect) + 6, NSMinY(rect) + 2)];
                [tail lineToPoint:NSMakePoint(NSMinX(rect) - 8, NSMinY(rect) - 8)];
            }
            [tail closePath];
            [[NSColor colorWithCalibratedRed:bottom[0] green:bottom[1] blue:bottom[2] alpha:1] set];
            [tail fill];
            textRect.size = textSize;
            textRect.origin.x = NSMinX(rect) + 14;
            textRect.origin.y = NSMinY(rect) + (NSHeight(rect) - textSize.height) / 2.0;
            [text drawInRect:textRect withAttributes:[self attrsForUser:fromUser]];
        }
    }
}

- (BOOL)isFlipped
{
    return NO;
}

@end
