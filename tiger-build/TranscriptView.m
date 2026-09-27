#import "TranscriptView.h"
#import <QTKit/QTKit.h>

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
    movieViews = [[NSMutableArray alloc] init];
    moviePaths = [[NSMutableArray alloc] init];
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
    [movieViews release];
    [moviePaths release];
    [bodyAttrs release];
    [userAttrs release];
    [statusAttrs release];
    [super dealloc];
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
        used = [text boundingRectWithSize:NSMakeSize(status ? layoutWidth - 48 : maxText, 4000)
                                   options:NSStringDrawingUsesLineFragmentOrigin
                                attributes:attrs];
        if (used.size.width < 12)
            used.size.width = 12;
        if (!status && imagePath && [[NSFileManager defaultManager] fileExistsAtPath:imagePath]) {
            NSImage *picture = [[NSImage alloc] initWithContentsOfFile:imagePath];
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
            [picture release];
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
            [box setObject:[NSValue valueWithRect:NSMakeRect(24, yFromTop, layoutWidth - 48, used.size.height)] forKey:@"topRect"];
            yFromTop += used.size.height + 10;
        } else {
            bubble.size.width = used.size.width + 28;
            if (imageW + 28 > bubble.size.width)
                bubble.size.width = imageW + 28;
            if (videoW + 28 > bubble.size.width)
                bubble.size.width = videoW + 28;
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
                NSRect imageRect = NSMakeRect(NSMinX(rect) + 14, stackY, imageSize.width, imageSize.height);
                [box setObject:[NSValue valueWithRect:imageRect] forKey:@"imageRect"];
                stackY += imageSize.height + 8;
            }
            if ([box objectForKey:@"video"]) {
                NSSize videoSize = [[box objectForKey:@"videoSize"] sizeValue];
                NSRect videoRect = NSMakeRect(NSMinX(rect) + 14, stackY, videoSize.width, videoSize.height);
                [box setObject:[NSValue valueWithRect:videoRect] forKey:@"videoRect"];
            }
        }
    }
    [self setFrameSize:NSMakeSize(layoutWidth, contentH)];
    [self placeMovies];
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
            if ([box objectForKey:@"image"] || [box objectForKey:@"video"])
                textRect.origin.y = NSMaxY(rect) - 10 - textSize.height;
            else
                textRect.origin.y = NSMinY(rect) + (NSHeight(rect) - textSize.height) / 2.0;
            if ([box objectForKey:@"imageRect"]) {
                NSImage *picture = [[NSImage alloc] initWithContentsOfFile:[box objectForKey:@"image"]];
                NSRect imageRect = [[box objectForKey:@"imageRect"] rectValue];
                if (picture)
                    [picture drawInRect:imageRect fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1.0];
                [picture release];
            }
            if ([box objectForKey:@"videoRect"] && ![self playingVideo:[box objectForKey:@"video"]]) {
                NSRect videoRect = [[box objectForKey:@"videoRect"] rectValue];
                [[NSColor colorWithCalibratedWhite:0.15 alpha:1] set];
                NSRectFill(videoRect);
                [@"QuickTime could not open this video." drawInRect:videoRect withAttributes:statusAttrs];
            }
            [text drawInRect:textRect withAttributes:[self attrsForUser:fromUser]];
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
    if (!path)
        return [super menuForEvent:event];
    menu = [[[NSMenu alloc] initWithTitle:@"Media"] autorelease];
    item = [[[NSMenuItem alloc] initWithTitle:@"Save As..."
                                       action:@selector(saveMediaAs:)
                                keyEquivalent:@""] autorelease];
    [item setTarget:self];
    [item setRepresentedObject:path];
    [menu addItem:item];
    return menu;
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
