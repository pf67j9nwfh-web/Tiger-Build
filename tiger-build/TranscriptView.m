#import "TranscriptView.h"
#import "TBSupport.h"
#import "TBMarkup.h"
#import "TBTheme.h"
#import "TBEmoji.h"
#if TB_INLINE_VIDEO
#import <QTKit/QTKit.h>
#endif

@interface TranscriptView (Selection)
- (void)toggleActivityAtView:(NSView *)view;
- (void)syncTextViews;
- (void)copyCode:(NSString *)code key:(NSString *)key;
- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)sender;
- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender;
- (void)saveCode:(NSString *)code title:(NSString *)title;
- (void)saveFileAtPath:(NSString *)path;
- (NSMenu *)menuForTextView:(NSTextView *)view base:(NSMenu *)base;
- (void)textScaleChanged:(NSNotification *)note;
- (void)updateTypingTimer;
@end

/* ---- emoji pictures (Macs before 10.7) ---- */

/* An emoji drawn as its Twemoji picture, sized to the text around it. */
@interface TBEmojiCell : NSTextAttachmentCell {
    float side;
    NSString *emoji;
}
- (id)initWithPicture:(NSImage *)picture emoji:(NSString *)text side:(float)points;
- (NSString *)emoji;
@end

@implementation TBEmojiCell

- (id)initWithPicture:(NSImage *)picture emoji:(NSString *)text side:(float)points
{
    self = [super initImageCell:picture];
    if (self) {
        side = points;
        emoji = [text copy];
    }
    return self;
}

- (void)dealloc
{
    [emoji release];
    [super dealloc];
}

- (NSString *)emoji
{
    return emoji;
}

- (NSSize)cellSize
{
    return NSMakeSize(side, side);
}

- (NSPoint)cellBaselineOffset
{
    return NSMakePoint(0, -side * 0.18f);
}

- (BOOL)wantsToTrackMouse
{
    return NO;
}

- (void)drawWithFrame:(NSRect)frame inView:(NSView *)view
{
    NSImage *picture = [self image];
    [picture setFlipped:[view isFlipped]];
    [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
    [picture drawInRect:frame fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1.0];
}

- (void)drawWithFrame:(NSRect)frame inView:(NSView *)view characterIndex:(NSUInteger)index layoutManager:(NSLayoutManager *)manager
{
    (void)index;
    (void)manager;
    [self drawWithFrame:frame inView:view];
}

@end

static BOOL hasStandIn(NSString *text)
{
    unsigned i;
    for (i = 0; i < [text length]; i++) {
        if (TBEmojiIsStandIn([text characterAtIndex:i]))
            return YES;
    }
    return NO;
}

/* The text as it is in a text view: a stand-in is one object character there. */
static NSString *withObjectCharacters(NSString *text)
{
    NSMutableString *out = [NSMutableString stringWithCapacity:[text length]];
    unsigned i;
    for (i = 0; i < [text length]; i++) {
        unichar c = [text characterAtIndex:i];
        [out appendFormat:@"%C", TBEmojiIsStandIn(c) ? (unichar)NSAttachmentCharacter : c];
    }
    return out;
}

/* Replaces each stand-in with its picture, one character for one, so positions in the text stay where they were. */
static NSAttributedString *withEmojiPictures(NSAttributedString *source)
{
    static NSMutableDictionary *pictures = nil;
    NSMutableAttributedString *text;
    unsigned i;
    if (!hasStandIn([source string]))
        return source;
    if (!pictures)
        pictures = [[NSMutableDictionary alloc] init];
    text = [[source mutableCopy] autorelease];
    for (i = 0; i < [text length]; i++) {
        unichar c = [[text string] characterAtIndex:i];
        NSNumber *key = [NSNumber numberWithUnsignedShort:c];
        NSImage *picture;
        NSFont *font;
        NSTextAttachment *attachment;
        NSRange spot = NSMakeRange(i, 1);
        if (!TBEmojiIsStandIn(c))
            continue;
        picture = [pictures objectForKey:key];
        if (!picture) {
            NSData *png = TBEmojiPNGForStandIn(c);
            picture = png ? [[[NSImage alloc] initWithData:png] autorelease] : nil;
            if (picture)
                [pictures setObject:picture forKey:key];
        }
        if (!picture) {
            [text replaceCharactersInRange:spot withString:TBDisplayText(TBEmojiForStandIn(c))];
            continue;
        }
        font = [text attribute:NSFontAttributeName atIndex:i effectiveRange:NULL];
        attachment = [[[NSTextAttachment alloc] init] autorelease];
        [attachment setAttachmentCell:[[[TBEmojiCell alloc] initWithPicture:picture emoji:TBEmojiForStandIn(c)
            side:(font ? [font pointSize] : 14) * 1.2f] autorelease]];
        [text replaceCharactersInRange:spot withString:[NSString stringWithFormat:@"%C", (unichar)NSAttachmentCharacter]];
        [text addAttribute:NSAttachmentAttributeName value:attachment range:spot];
    }
    return text;
}

/* Text with its emoji turned back from pictures, for copying. */
static NSString *plainWithEmoji(NSAttributedString *text)
{
    NSMutableString *out = [NSMutableString string];
    unsigned i;
    for (i = 0; i < [text length]; i++) {
        unichar c = [[text string] characterAtIndex:i];
        NSTextAttachment *attachment = c == NSAttachmentCharacter ? [text attribute:NSAttachmentAttributeName atIndex:i effectiveRange:NULL] : nil;
        if ([[attachment attachmentCell] isKindOfClass:[TBEmojiCell class]])
            [out appendString:[(TBEmojiCell *)[attachment attachmentCell] emoji]];
        else
            [out appendFormat:@"%C", c];
    }
    return out;
}

NSAttributedString *TBEmojiTitle(NSString *text, NSFont *font)
{
    NSMutableParagraphStyle *style;
    NSString *standIns = TBEmojiSubstitute(text);
    if (!hasStandIn(standIns))
        return nil;
    style = [[[NSMutableParagraphStyle alloc] init] autorelease];
    [style setLineBreakMode:NSLineBreakByTruncatingTail];
    return withEmojiPictures([[[NSAttributedString alloc] initWithString:standIns
        attributes:[NSDictionary dictionaryWithObjectsAndKeys:font, NSFontAttributeName, style, NSParagraphStyleAttributeName, nil]] autorelease]);
}

/* One of these sits on each message so the words can be highlighted and copied.
   A click on an activity card's triangle still expands it. */
@interface TBSelectText : NSTextView
{
    BOOL activity;
    NSArray *copies;
    NSString *speakerLabel;
}
- (void)setSpeakerLabel:(NSString *)label;
- (void)setActivity:(BOOL)flag;
- (void)setCopies:(NSArray *)list;
@end

@implementation TBSelectText

/* Copied text carries the emoji themselves, not the object characters their pictures are. */
- (BOOL)writeSelectionToPasteboard:(NSPasteboard *)board types:(NSArray *)types
{
    BOOL ok = [super writeSelectionToPasteboard:board types:types];
    NSRange range = [self selectedRange];
    if (ok && range.length > 0 && [types containsObject:NSStringPboardType])
        [board setString:plainWithEmoji([[self textStorage] attributedSubstringFromRange:range]) forType:NSStringPboardType];
    return ok;
}

- (void)setActivity:(BOOL)flag
{
    activity = flag;
}

/* Where each code block's Copy label is, in this view's own (flipped) coordinates. */
- (void)setCopies:(NSArray *)list
{
    if (list == copies)
        return;
    [list retain];
    [copies release];
    copies = list;
}

- (void)dealloc
{
    [copies release];
    [speakerLabel release];
    [super dealloc];
}

/* What VoiceOver says before the words: who spoke, and what else the message holds. */
- (void)setSpeakerLabel:(NSString *)label
{
    if (label == speakerLabel || [label isEqualToString:speakerLabel])
        return;
    [speakerLabel release];
    speakerLabel = [label copy];
}

- (NSArray *)accessibilityAttributeNames
{
    NSArray *names = [super accessibilityAttributeNames];
    if (speakerLabel && ![names containsObject:NSAccessibilityDescriptionAttribute])
        return [names arrayByAddingObject:NSAccessibilityDescriptionAttribute];
    return names;
}

- (id)accessibilityAttributeValue:(NSString *)attribute
{
    if ([attribute isEqualToString:NSAccessibilityDescriptionAttribute] && speakerLabel)
        return speakerLabel;
    return [super accessibilityAttributeValue:attribute];
}

- (NSMenu *)menuForEvent:(NSEvent *)event
{
    return [(TranscriptView *)[self superview] menuForTextView:self base:[super menuForEvent:event]];
}

/* A file dropped on a message goes to the chat, not into the message. */
- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)sender
{
    return [(TranscriptView *)[self superview] draggingEntered:sender];
}

- (NSDragOperation)draggingUpdated:(id <NSDraggingInfo>)sender
{
    return [(TranscriptView *)[self superview] draggingEntered:sender];
}

- (BOOL)prepareForDragOperation:(id <NSDraggingInfo>)sender
{
    (void)sender;
    return YES;
}

- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender
{
    return [(TranscriptView *)[self superview] performDragOperation:sender];
}

- (void)mouseDown:(NSEvent *)event
{
    NSPoint local;
    if (copies && [copies count] > 0) {
        unsigned c;
        local = [self convertPoint:[event locationInWindow] fromView:nil];
        for (c = 0; c < [copies count]; c++) {
            NSDictionary *entry = [copies objectAtIndex:c];
            if (NSPointInRect(local, [[entry objectForKey:@"rect"] rectValue])) {
                if ([entry objectForKey:@"save"])
                    [(TranscriptView *)[self superview] saveCode:[entry objectForKey:@"code"] title:[entry objectForKey:@"title"]];
                else
                    [(TranscriptView *)[self superview] copyCode:[entry objectForKey:@"code"] key:[entry objectForKey:@"key"]];
                return;
            }
        }
    }
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
    float top[3], body[3], low[3], line[3];
    float height = NSHeight(rect);
    int i;
    [TBTheme getBubble:sent top:top body:body low:low line:line];

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

/* One bubble: the shaded body, a faint bright line inside the top, and the outline. */
static void paintBubble(NSRect rect, BOOL fromUser)
{
    NSBezierPath *path = [NSBezierPath bezierPath];
    NSBezierPath *light = [NSBezierPath bezierPath];
    float top[3], body[3], low[3], line[3];
    float radius = 16;
    [TBTheme getBubble:fromUser top:top body:body low:low line:line];
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
}

/* iChat's typing indicator: a thought cloud with two small bubbles trailing from it and three dots that
   light up in turn. Drawn from circles, so it is sharp at any size. rect is 84 by 50. */
static void paintThoughtCloud(NSRect rect, int phase)
{
    static const float puffs[][3] = {
        {32, 20, 11}, {44, 28, 13}, {58, 27, 12}, {69, 19, 10.5f}, {62, 13, 11}, {46, 13, 11}, {33, 13, 9}};
    NSBezierPath *cloud = [NSBezierPath bezierPath];
    NSBezierPath *small = [NSBezierPath bezierPath];
    float ox = NSMinX(rect) + 2;
    float oy = NSMinY(rect) + 1;
    unsigned i;
    for (i = 0; i < sizeof(puffs) / sizeof(puffs[0]); i++)
        [cloud appendBezierPathWithOvalInRect:NSMakeRect(ox + puffs[i][0] - puffs[i][2], oy + puffs[i][1] - puffs[i][2], puffs[i][2] * 2, puffs[i][2] * 2)];
    [small appendBezierPathWithOvalInRect:NSMakeRect(ox + 1, oy + 1, 9, 9)];
    [small appendBezierPathWithOvalInRect:NSMakeRect(ox + 11, oy + 5, 13, 13)];
    /* The outline is the outer half of a thick stroke; the fill covers the rest. */
    [[NSColor colorWithCalibratedWhite:0.62f alpha:1] set];
    [cloud setLineWidth:2];
    [cloud stroke];
    [small setLineWidth:2];
    [small stroke];
    [NSGraphicsContext saveGraphicsState];
    [cloud addClip];
    [TBTheme fillGradient:NSMakeRect(ox, oy, 84, 44) from:[NSColor colorWithCalibratedWhite:1 alpha:1] to:[NSColor colorWithCalibratedWhite:0.9f alpha:1]];
    [NSGraphicsContext restoreGraphicsState];
    [NSGraphicsContext saveGraphicsState];
    [small addClip];
    [TBTheme fillGradient:NSMakeRect(ox, oy, 30, 22) from:[NSColor colorWithCalibratedWhite:1 alpha:1] to:[NSColor colorWithCalibratedWhite:0.9f alpha:1]];
    [NSGraphicsContext restoreGraphicsState];
    for (i = 0; i < 3; i++) {
        float shade = ((int)i == phase) ? 0.32f : 0.66f;
        NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(ox + 36 + i * 12.5f - 4, oy + 20 - 4, 8, 8)];
        [[NSColor colorWithCalibratedWhite:shade alpha:1] set];
        [dot fill];
    }
}

@implementation TranscriptView

static float transcriptScale = 0;

+ (float)textScale
{
    if (transcriptScale <= 0) {
        float saved = [[NSUserDefaults standardUserDefaults] floatForKey:@"TBTextScale"];
        transcriptScale = (saved >= 0.8f && saved <= 1.8f) ? saved : 1.0f;
    }
    return transcriptScale;
}

+ (void)setTextScale:(float)scale
{
    if (scale < 0.8f)
        scale = 0.8f;
    if (scale > 1.8f)
        scale = 1.8f;
    transcriptScale = scale;
    [[NSUserDefaults standardUserDefaults] setFloat:scale forKey:@"TBTextScale"];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TBTextScaleChanged" object:nil];
}

/* The fonts messages are drawn in, at the chosen text size. */
- (void)rebuildFonts
{
    NSMutableParagraphStyle *style;
    float scale = [TranscriptView textScale];
    [bodyAttrs release];
    [userAttrs release];
    [statusAttrs release];
    [toolAttrs release];
    style = [[NSMutableParagraphStyle alloc] init];
    [style setLineBreakMode:NSLineBreakByWordWrapping];
    bodyAttrs = [[NSDictionary alloc] initWithObjectsAndKeys:
        [TBTheme font:NO scale:scale], NSFontAttributeName,
        [TBTheme textColor:NO], NSForegroundColorAttributeName,
        style, NSParagraphStyleAttributeName,
        nil];
    userAttrs = [[NSDictionary alloc] initWithObjectsAndKeys:
        [TBTheme font:YES scale:scale], NSFontAttributeName,
        [TBTheme textColor:YES], NSForegroundColorAttributeName,
        style, NSParagraphStyleAttributeName,
        nil];
    statusAttrs = [[TBTheme statusAttributesScale:scale paragraph:style] retain];
    toolAttrs = [[TBTheme toolAttributesScale:scale paragraph:style] retain];
    [style release];
}

/* A change in Appearance: the fonts and colours of the text need a new layout, the bubbles and backdrop only a redraw. */
- (void)themeChanged:(NSNotification *)note
{
    if ([[[note userInfo] objectForKey:@"layout"] boolValue]) {
        [self textScaleChanged:nil];
    } else {
        [self layoutForWidth:layoutWidth visibleHeight:visibleHeight];
        [self setNeedsDisplay:YES];
    }
}

/* The dots in the typing cloud light up in turn while a reply has not started. */
- (void)typingTick:(NSTimer *)timer
{
    unsigned i;
    (void)timer;
    typingPhase = (typingPhase + 1) % 3;
    for (i = 0; i < [boxes count]; i++) {
        NSDictionary *box = [boxes objectAtIndex:i];
        if ([[box objectForKey:@"typing"] boolValue])
            [self setNeedsDisplayInRect:[[box objectForKey:@"rect"] rectValue]];
    }
}

- (void)updateTypingTimer
{
    BOOL any = NO;
    unsigned i;
    for (i = 0; i < [boxes count]; i++) {
        if ([[[boxes objectAtIndex:i] objectForKey:@"typing"] boolValue])
            any = YES;
    }
    if (any && !typingTimer && [self window])
        typingTimer = [[NSTimer scheduledTimerWithTimeInterval:0.45 target:self selector:@selector(typingTick:) userInfo:nil repeats:YES] retain];
    if ((!any || ![self window]) && typingTimer) {
        [typingTimer invalidate];
        [typingTimer release];
        typingTimer = nil;
    }
}

/* The timer holds its target, so it is stopped when the chat leaves its window. */
- (void)viewWillMoveToWindow:(NSWindow *)newWindow
{
    if (!newWindow && typingTimer) {
        [typingTimer invalidate];
        [typingTimer release];
        typingTimer = nil;
    }
}

- (void)viewDidMoveToWindow
{
    [self updateTypingTimer];
}

- (void)textScaleChanged:(NSNotification *)note
{
    (void)note;
    [self rebuildFonts];
    [sizeCache removeAllObjects];
    [richCache removeAllObjects];
    forceTextReset = YES;
    [self layoutForWidth:layoutWidth visibleHeight:visibleHeight];
    forceTextReset = NO;
}

- (id)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (!self)
        return nil;
    messages = [[NSArray alloc] init];
    boxes = [[NSMutableArray alloc] init];
    movieViews = [[NSMutableArray alloc] init];
    moviePaths = [[NSMutableArray alloc] init];
    imageCache = [[NSMutableDictionary alloc] init];
    sizeCache = [[NSMutableDictionary alloc] init];
    richCache = [[NSMutableDictionary alloc] init];
    textViews = [[NSMutableArray alloc] init];
    [self registerForDraggedTypes:[NSArray arrayWithObject:NSFilenamesPboardType]];
    [self rebuildFonts];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(textScaleChanged:) name:@"TBTextScaleChanged" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(themeChanged:) name:TBThemeChangedNotification object:nil];
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [typingTimer invalidate];
    [typingTimer release];
    [messages release];
    [boxes release];
    [movieViews release];
    [moviePaths release];
    [imageCache release];
    [sizeCache release];
    [richCache release];
    [copiedKey release];
    [textViews release];
    [bodyAttrs release];
    [userAttrs release];
    [statusAttrs release];
    [toolAttrs release];
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
    /* 64-bit builds without QTKit open videos in the default player. */
    return;
#else
    NSMutableArray *paths;
    if (!TBInlineVideoAvailable())
        return;
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
        attrs == statusAttrs ? @"s" : (attrs == userAttrs ? @"u" : (attrs == bodyAttrs ? @"b" : (attrs == toolAttrs ? @"t" : @"m")))];
    NSArray *hit = [sizeCache objectForKey:key];
    NSRect used;
    /* The text itself is compared too: a reply that grows from "..." to "OK."
       has the same length, and must not keep the old, narrower size. */
    if (hit && [[hit objectAtIndex:0] isEqualToString:signature] && [[hit objectAtIndex:2] isEqualToString:text])
        return [[hit objectAtIndex:1] rectValue];
    if (hasStandIn(text))
        used = [withEmojiPictures([[[NSAttributedString alloc] initWithString:text attributes:attrs] autorelease])
            boundingRectWithSize:NSMakeSize(width, height) options:NSStringDrawingUsesLineFragmentOrigin];
    else
        used = [text boundingRectWithSize:NSMakeSize(width, height) options:NSStringDrawingUsesLineFragmentOrigin attributes:attrs];
    if ([sizeCache count] > 4000)
        [sizeCache removeAllObjects];
    [sizeCache setObject:[NSArray arrayWithObjects:signature, [NSValue valueWithRect:used], [[text copy] autorelease], nil] forKey:key];
    return used;
}

/* ---- code blocks and light markup in replies ----
   A reply is cut at its ``` fences. Each code block becomes a dark panel with
   the language named in a header strip and a Copy label; the words in it are
   coloured by TBMarkup. Prose gets `code`, **bold**, headings and bullets.
   The panels are drawn behind the message's text view, from rectangles worked
   out with a layout manager that has the same text and width as that view. */

static NSColor *codeColor(int kind)
{
    switch (kind) {
    case TBTokKeyword:  return [NSColor colorWithCalibratedRed:0.78 green:0.55 blue:0.88 alpha:1];
    case TBTokType:     return [NSColor colorWithCalibratedRed:0.31 green:0.79 blue:0.69 alpha:1];
    case TBTokString:   return [NSColor colorWithCalibratedRed:0.93 green:0.62 blue:0.47 alpha:1];
    case TBTokComment:  return [NSColor colorWithCalibratedRed:0.42 green:0.60 blue:0.33 alpha:1];
    case TBTokNumber:   return [NSColor colorWithCalibratedRed:0.71 green:0.81 blue:0.66 alpha:1];
    case TBTokFunction: return [NSColor colorWithCalibratedRed:0.86 green:0.86 blue:0.67 alpha:1];
    case TBTokProperty: return [NSColor colorWithCalibratedRed:0.61 green:0.86 blue:1.00 alpha:1];
    case TBTokInsert:   return [NSColor colorWithCalibratedRed:0.50 green:0.85 blue:0.50 alpha:1];
    case TBTokDelete:   return [NSColor colorWithCalibratedRed:0.96 green:0.50 blue:0.50 alpha:1];
    }
    return [NSColor colorWithCalibratedWhite:0.86 alpha:1];
}

static NSFont *codeFont(void)
{
    float size = 11 * [TranscriptView textScale];
    NSFont *font = [NSFont fontWithName:@"Monaco" size:size];
    if (!font)
        font = [NSFont userFixedPitchFontOfSize:size];
    return font;
}

static NSParagraphStyle *fixedLineStyle(float height, float head, float tail, NSLineBreakMode mode)
{
    NSMutableParagraphStyle *style = [[[NSMutableParagraphStyle alloc] init] autorelease];
    [style setLineBreakMode:mode];
    if (height > 0) {
        [style setMinimumLineHeight:height];
        [style setMaximumLineHeight:height];
    }
    [style setFirstLineHeadIndent:head];
    [style setHeadIndent:head];
    [style setTailIndent:tail];
    return style;
}

/* A blank line of a fixed height, used for the header strip, the panel's lower
   edge and the gaps around a panel. */
static void appendBlankLine(NSMutableAttributedString *out, float height, float head, float tail)
{
    NSDictionary *attrs = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSFont systemFontOfSize:2], NSFontAttributeName,
        fixedLineStyle(height, head, tail, NSLineBreakByClipping), NSParagraphStyleAttributeName, nil];
    [out appendAttributedString:[[[NSAttributedString alloc] initWithString:@"\n" attributes:attrs] autorelease]];
}

/* One line of prose: `code` and **bold** spans, a heading, a bullet. */
static BOOL appendProseLine(NSMutableAttributedString *out, NSString *line, NSDictionary *base)
{
    NSString *work = line;
    NSFont *baseFont = [base objectForKey:NSFontAttributeName];
    NSMutableDictionary *attrs = [NSMutableDictionary dictionaryWithDictionary:base];
    BOOL marked = NO;
    unsigned n;
    unsigned i = 0;
    unsigned start = 0;
    unichar buf[1];
    NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    unsigned level = 0;
    (void)buf;
    if ([trimmed hasPrefix:@"#"]) {
        while (level < [trimmed length] && [trimmed characterAtIndex:level] == '#')
            level++;
        if (level >= 1 && level <= 6 && level < [trimmed length] && [trimmed characterAtIndex:level] == ' ') {
            work = [[trimmed substringFromIndex:level + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            [attrs setObject:[NSFont boldSystemFontOfSize:(level == 1 ? 17 : (level == 2 ? 16 : 14.5)) * [TranscriptView textScale]] forKey:NSFontAttributeName];
            baseFont = [attrs objectForKey:NSFontAttributeName];
            marked = YES;
        }
    }
    if (!marked && ([line hasPrefix:@"- "] || [line hasPrefix:@"* "] || [line hasPrefix:@"  - "] || [line hasPrefix:@"  * "])
        && ![line hasPrefix:@"**"]) {
        NSRange mark = [line rangeOfString:@"- "];
        if (mark.location == NSNotFound)
            mark = [line rangeOfString:@"* "];
        work = [[line substringToIndex:mark.location] stringByAppendingFormat:@"%C ", (unichar)0x2022];
        work = [work stringByAppendingString:[line substringFromIndex:mark.location + 2]];
        marked = YES;
    }
    n = [work length];
    while (i < n) {
        unichar c = [work characterAtIndex:i];
        if (c == '`') {
            unsigned j = i + 1;
            while (j < n && [work characterAtIndex:j] != '`')
                j++;
            if (j < n && j > i + 1) {
                NSMutableDictionary *mono = [NSMutableDictionary dictionaryWithDictionary:attrs];
                if (i > start)
                    [out appendAttributedString:[[[NSAttributedString alloc] initWithString:[work substringWithRange:NSMakeRange(start, i - start)] attributes:attrs] autorelease]];
                [mono setObject:[NSFont fontWithName:@"Monaco" size:[baseFont pointSize] - 2] forKey:NSFontAttributeName];
                [mono setObject:[NSColor colorWithCalibratedWhite:0.72 alpha:1] forKey:NSBackgroundColorAttributeName];
                if (![mono objectForKey:NSFontAttributeName])
                    [mono setObject:[NSFont userFixedPitchFontOfSize:[baseFont pointSize] - 2] forKey:NSFontAttributeName];
                [out appendAttributedString:[[[NSAttributedString alloc] initWithString:[work substringWithRange:NSMakeRange(i + 1, j - i - 1)] attributes:mono] autorelease]];
                i = j + 1;
                start = i;
                marked = YES;
                continue;
            }
        } else if (c == '[' || (c == 'h' && (i + 7 < n) && ([work compare:@"http://" options:0 range:NSMakeRange(i, 7)] == NSOrderedSame
            || (i + 8 < n && [work compare:@"https://" options:0 range:NSMakeRange(i, 8)] == NSOrderedSame)))) {
            /* [words](address), or an address on its own */
            NSString *shown = nil;
            NSString *address = nil;
            unsigned after = i;
            if (c == '[') {
                unsigned close = i + 1;
                while (close < n && [work characterAtIndex:close] != ']')
                    close++;
                if (close + 1 < n && [work characterAtIndex:close + 1] == '(') {
                    unsigned end = close + 2;
                    while (end < n && [work characterAtIndex:end] != ')' && [work characterAtIndex:end] != ' ')
                        end++;
                    if (end < n && [work characterAtIndex:end] == ')' && close > i + 1) {
                        shown = [work substringWithRange:NSMakeRange(i + 1, close - i - 1)];
                        address = [work substringWithRange:NSMakeRange(close + 2, end - close - 2)];
                        after = end + 1;
                    }
                }
            } else {
                unsigned end = i;
                while (end < n && [work characterAtIndex:end] != ' ' && [work characterAtIndex:end] != ')' && [work characterAtIndex:end] != '>'
                    && [work characterAtIndex:end] != '"')
                    end++;
                while (end > i + 8 && ([work characterAtIndex:end - 1] == '.' || [work characterAtIndex:end - 1] == ',' || [work characterAtIndex:end - 1] == ';'
                    || [work characterAtIndex:end - 1] == ':' || [work characterAtIndex:end - 1] == '!' || [work characterAtIndex:end - 1] == '?'))
                    end--;
                shown = address = [work substringWithRange:NSMakeRange(i, end - i)];
                after = end;
            }
            if (address && ([address hasPrefix:@"http://"] || [address hasPrefix:@"https://"] || [address hasPrefix:@"mailto:"]) && [NSURL URLWithString:address]) {
                NSMutableDictionary *link = [NSMutableDictionary dictionaryWithDictionary:attrs];
                if (i > start)
                    [out appendAttributedString:[[[NSAttributedString alloc] initWithString:[work substringWithRange:NSMakeRange(start, i - start)] attributes:attrs] autorelease]];
                [link setObject:[NSURL URLWithString:address] forKey:NSLinkAttributeName];
                [link setObject:[NSColor colorWithCalibratedRed:0.05 green:0.2 blue:0.75 alpha:1] forKey:NSForegroundColorAttributeName];
                [link setObject:[NSNumber numberWithInt:NSSingleUnderlineStyle] forKey:NSUnderlineStyleAttributeName];
                [out appendAttributedString:[[[NSAttributedString alloc] initWithString:shown attributes:link] autorelease]];
                i = after;
                start = i;
                marked = YES;
                continue;
            }
        } else if (c == '*' && i + 1 < n && [work characterAtIndex:i + 1] != '*' && [work characterAtIndex:i + 1] != ' '
            && (i == 0 || [work characterAtIndex:i - 1] == ' ' || [work characterAtIndex:i - 1] == '(')) {
            /* *italic* */
            unsigned j = i + 1;
            while (j < n && !([work characterAtIndex:j] == '*' && [work characterAtIndex:j - 1] != ' '))
                j++;
            if (j < n && j > i + 1 && (j + 1 >= n || [work characterAtIndex:j + 1] != '*')) {
                NSMutableDictionary *slanted = [NSMutableDictionary dictionaryWithDictionary:attrs];
                if (i > start)
                    [out appendAttributedString:[[[NSAttributedString alloc] initWithString:[work substringWithRange:NSMakeRange(start, i - start)] attributes:attrs] autorelease]];
                /* The system font has no italic, so the letters are slanted. */
                [slanted setObject:[NSNumber numberWithFloat:0.22f] forKey:NSObliquenessAttributeName];
                [out appendAttributedString:[[[NSAttributedString alloc] initWithString:[work substringWithRange:NSMakeRange(i + 1, j - i - 1)] attributes:slanted] autorelease]];
                i = j + 1;
                start = i;
                marked = YES;
                continue;
            }
        } else if (c == '*' && i + 1 < n && [work characterAtIndex:i + 1] == '*') {
            unsigned j = i + 2;
            while (j + 1 < n && !([work characterAtIndex:j] == '*' && [work characterAtIndex:j + 1] == '*'))
                j++;
            if (j + 1 < n && j > i + 2) {
                NSMutableDictionary *bold = [NSMutableDictionary dictionaryWithDictionary:attrs];
                if (i > start)
                    [out appendAttributedString:[[[NSAttributedString alloc] initWithString:[work substringWithRange:NSMakeRange(start, i - start)] attributes:attrs] autorelease]];
                [bold setObject:[NSFont boldSystemFontOfSize:[baseFont pointSize]] forKey:NSFontAttributeName];
                [out appendAttributedString:[[[NSAttributedString alloc] initWithString:[work substringWithRange:NSMakeRange(i + 2, j - i - 2)] attributes:bold] autorelease]];
                i = j + 2;
                start = i;
                marked = YES;
                continue;
            }
        }
        i++;
    }
    if (start < n)
        [out appendAttributedString:[[[NSAttributedString alloc] initWithString:[work substringFromIndex:start] attributes:attrs] autorelease]];
    return marked;
}

/* The attributed text of a reply, and where its code blocks are. Returns nil
   when the reply has no markup at all, so plain replies take the old path. */
- (NSDictionary *)buildRich:(NSString *)text
{
    NSArray *blocks;
    NSMutableAttributedString *out;
    NSMutableArray *codes;
    BOOL marked = NO;
    unsigned b;
    BOOL previousProse = NO;
    if ([text rangeOfString:@"`"].location == NSNotFound && [text rangeOfString:@"**"].location == NSNotFound
        && [text rangeOfString:@"]("].location == NSNotFound && [text rangeOfString:@"http"].location == NSNotFound
        && [text rangeOfString:@" *"].location == NSNotFound && [text rangeOfString:@"|"].location == NSNotFound
        && [text rangeOfString:@"\n#"].location == NSNotFound && ![text hasPrefix:@"#"]
        && [text rangeOfString:@"\n- "].location == NSNotFound && [text rangeOfString:@"\n* "].location == NSNotFound
        && ![text hasPrefix:@"- "] && ![text hasPrefix:@"* "])
        return nil;
    blocks = TBSplitBlocks(text);
    out = [[[NSMutableAttributedString alloc] init] autorelease];
    codes = [NSMutableArray array];
    for (b = 0; b < [blocks count]; b++) {
        NSDictionary *block = [blocks objectAtIndex:b];
        NSString *content = [block objectForKey:@"text"];
        if ([[block objectForKey:@"code"] boolValue]) {
            NSString *tag = [block objectForKey:@"lang"];
            NSString *title = TBLanguageTitle(tag, content);
            NSString *copyText = [block objectForKey:@"copy"] ? [block objectForKey:@"copy"] : content;
            NSString *shown = [[content componentsSeparatedByString:@"\t"] componentsJoinedByString:@"    "];
            NSData *kinds = TBHighlight(shown, tag);
            const unsigned char *k = (const unsigned char *)[kinds bytes];
            NSParagraphStyle *codeStyle = fixedLineStyle(0, 12, -12, NSLineBreakByCharWrapping);
            NSMutableDictionary *attrs = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                codeFont(), NSFontAttributeName, codeStyle, NSParagraphStyleAttributeName, nil];
            unsigned run = 0;
            unsigned n = [shown length];
            unsigned headerLoc;
            unsigned footerLoc;
            if (previousProse && [out length] > 0)
                appendBlankLine(out, 10, 0, 0);
            headerLoc = [out length];
            [out appendAttributedString:[[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%C", (unichar)0xA0]
                attributes:[NSDictionary dictionaryWithObjectsAndKeys:codeFont(), NSFontAttributeName,
                    fixedLineStyle(26 * [TranscriptView textScale], 12, -12, NSLineBreakByClipping), NSParagraphStyleAttributeName, nil]] autorelease]];
            [out appendAttributedString:[[[NSAttributedString alloc] initWithString:@"\n" attributes:attrs] autorelease]];
            while (run < n) {
                unsigned e = run + 1;
                NSMutableDictionary *piece;
                while (e < n && k[e] == k[run])
                    e++;
                piece = [NSMutableDictionary dictionaryWithDictionary:attrs];
                [piece setObject:codeColor(k[run]) forKey:NSForegroundColorAttributeName];
                [out appendAttributedString:[[[NSAttributedString alloc] initWithString:[shown substringWithRange:NSMakeRange(run, e - run)]
                    attributes:piece] autorelease]];
                run = e;
            }
            if (n > 0)
                [out appendAttributedString:[[[NSAttributedString alloc] initWithString:@"\n" attributes:attrs] autorelease]];
            footerLoc = [out length];
            [out appendAttributedString:[[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%C", (unichar)0xA0]
                attributes:[NSDictionary dictionaryWithObjectsAndKeys:codeFont(), NSFontAttributeName,
                    fixedLineStyle(9, 12, -12, NSLineBreakByClipping), NSParagraphStyleAttributeName, nil]] autorelease]];
            [out appendAttributedString:[[[NSAttributedString alloc] initWithString:@"\n" attributes:attrs] autorelease]];
            if (b + 1 < [blocks count])
                appendBlankLine(out, 10, 0, 0);
            [codes addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                title, @"title", copyText, @"code",
                [NSNumber numberWithUnsignedInt:headerLoc], @"header",
                [NSNumber numberWithUnsignedInt:footerLoc], @"footer", nil]];
            previousProse = NO;
            marked = YES;
        } else {
            NSArray *lines;
            unsigned l;
            /* The blank lines around a fence are the gap; the panel brings its own. */
            while (b > 0 && [content hasPrefix:@"\n"])
                content = [content substringFromIndex:1];
            while (b + 1 < [blocks count] && [content hasSuffix:@"\n"])
                content = [content substringToIndex:[content length] - 1];
            if ([content length] == 0 && [blocks count] > 1)
                continue;
            lines = [content componentsSeparatedByString:@"\n"];
            for (l = 0; l < [lines count]; l++) {
                if (appendProseLine(out, [lines objectAtIndex:l], bodyAttrs))
                    marked = YES;
                if (l + 1 < [lines count] || b + 1 < [blocks count])
                    [out appendAttributedString:[[[NSAttributedString alloc] initWithString:@"\n" attributes:bodyAttrs] autorelease]];
            }
            previousProse = YES;
        }
    }
    if (!marked)
        return nil;
    /* A trailing newline would leave an empty last line. */
    if ([out length] > 0 && [[out string] hasSuffix:@"\n"])
        [out deleteCharactersInRange:NSMakeRange([out length] - 1, 1)];
    return [NSDictionary dictionaryWithObjectsAndKeys:out, @"attr", codes, @"codes", nil];
}

/* The rich form of a message at a width: attributed text, its height, and for each
   code block its panel in the text's own coordinates (y from the top). Cached. */
- (NSDictionary *)richForMessage:(NSDictionary *)message text:(NSString *)text width:(float)width
{
    NSValue *key = [NSValue valueWithPointer:message];
    NSMutableDictionary *entry = [richCache objectForKey:key];
    NSDictionary *built;
    NSTextStorage *storage;
    NSLayoutManager *manager;
    NSTextContainer *container;
    NSMutableArray *panels;
    NSArray *codes;
    NSRect used;
    unsigned c;
    if (entry && [[entry objectForKey:@"source"] isEqualToString:text]) {
        if (![entry objectForKey:@"attr"])
            return nil;
        if (fabsf([[entry objectForKey:@"width"] floatValue] - width) < 0.5f)
            return entry;
    } else {
        built = [self buildRich:text];
        if ([richCache count] > 600)
            [richCache removeAllObjects];
        entry = [NSMutableDictionary dictionaryWithObject:[[text copy] autorelease] forKey:@"source"];
        [richCache setObject:entry forKey:key];
        if (!built)
            return nil;
        [entry setObject:withEmojiPictures([built objectForKey:@"attr"]) forKey:@"attr"];
        [entry setObject:[built objectForKey:@"codes"] forKey:@"codes"];
    }
    storage = [[NSTextStorage alloc] initWithAttributedString:[entry objectForKey:@"attr"]];
    manager = [[NSLayoutManager alloc] init];
    container = [[NSTextContainer alloc] initWithContainerSize:NSMakeSize(width, 1000000)];
    [container setLineFragmentPadding:0];
    [manager addTextContainer:container];
    [storage addLayoutManager:manager];
    [manager glyphRangeForTextContainer:container];
    used = [manager usedRectForTextContainer:container];
    panels = [NSMutableArray array];
    codes = [entry objectForKey:@"codes"];
    for (c = 0; c < [codes count]; c++) {
        NSDictionary *code = [codes objectAtIndex:c];
        NSRange headerGlyph = [manager glyphRangeForCharacterRange:NSMakeRange([[code objectForKey:@"header"] unsignedIntValue], 1) actualCharacterRange:NULL];
        NSRange footerGlyph = [manager glyphRangeForCharacterRange:NSMakeRange([[code objectForKey:@"footer"] unsignedIntValue], 1) actualCharacterRange:NULL];
        NSRect head = [manager lineFragmentRectForGlyphAtIndex:headerGlyph.location effectiveRange:NULL];
        NSRect foot = [manager lineFragmentRectForGlyphAtIndex:footerGlyph.location effectiveRange:NULL];
        [panels addObject:[NSDictionary dictionaryWithObjectsAndKeys:
            [NSValue valueWithRect:NSMakeRect(0, NSMinY(head), width, NSMaxY(foot) - NSMinY(head))], @"panel",
            [NSValue valueWithRect:NSMakeRect(0, NSMinY(head), width, NSHeight(head))], @"header",
            [code objectForKey:@"title"], @"title", [code objectForKey:@"code"], @"code", nil]];
    }
    [storage release];
    [manager release];
    [container release];
    [entry setObject:[NSNumber numberWithFloat:width] forKey:@"width"];
    [entry setObject:[NSNumber numberWithFloat:ceilf(NSHeight(used))] forKey:@"height"];
    [entry setObject:panels forKey:@"panels"];
    return entry;
}

/* The Copy label of a code block was clicked. */
- (void)copyCode:(NSString *)code key:(NSString *)key
{
    NSPasteboard *board = [NSPasteboard generalPasteboard];
    [board declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
    [board setString:code forType:NSStringPboardType];
    [copiedKey release];
    copiedKey = [key copy];
    [self setNeedsDisplay:YES];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(forgetCopied) object:nil];
    [self performSelector:@selector(forgetCopied) withObject:nil afterDelay:1.6];
}

/* Bring a message into view (used by Find in Chats). */
- (void)scrollToMessage:(id)message
{
    unsigned i;
    for (i = 0; i < [boxes count]; i++) {
        NSDictionary *box = [boxes objectAtIndex:i];
        if ([box objectForKey:@"message"] == message) {
            NSRect rect = [[box objectForKey:@"rect"] rectValue];
            [self scrollRectToVisible:NSInsetRect(rect, 0, -30)];
            return;
        }
    }
}

- (void)setDropTarget:(id)target
{
    dropTarget = target;
}

- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)sender
{
    if (dropTarget && [[[sender draggingPasteboard] types] containsObject:NSFilenamesPboardType])
        return NSDragOperationCopy;
    return NSDragOperationNone;
}

- (BOOL)performDragOperation:(id <NSDraggingInfo>)sender
{
    NSArray *files = [[sender draggingPasteboard] propertyListForType:NSFilenamesPboardType];
    if (!dropTarget || ![files isKindOfClass:[NSArray class]] || [files count] == 0)
        return NO;
    [dropTarget performSelector:@selector(attachPaths:) withObject:files];
    return YES;
}

- (void)forgetCopied
{
    [copiedKey release];
    copiedKey = nil;
    [self setNeedsDisplay:YES];
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
        NSDictionary *rich;
        float imageH = 0;
        float imageW = 0;
        float videoH = 0;
        float videoW = 0;
        NSString *filePath = [message objectForKey:@"file"];
        float fileH = 0;
        BOOL typing = NO;
        if (!text)
            text = @"";
        text = TBEmojiSubstitute(text);
        if (open && [text length] == 0
            && (!imagePath || [imagePath length] == 0)
            && (!videoPath || [videoPath length] == 0))
        {
            text = @"...";
            typing = YES;
        }
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
            attrs=toolAttrs;
        }
        rich = nil;
        if (!status && !activity && !fromUser && [text length] > 0)
            rich = [self richForMessage:message text:text width:maxText];
        if (rich) {
            used = NSMakeRect(0, 0, maxText, [[rich objectForKey:@"height"] floatValue]);
        } else {
            used = [self measureText:text attrs:attrs
                               width:(status ? layoutWidth - (activity ? 64 : 48) : maxText)
                              height:(activity ? 1000000 : 4000) forMessage:message];
        }
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
        if (!status && filePath && [filePath length] > 0 && [[NSFileManager defaultManager] fileExistsAtPath:filePath])
            fileH = 34;
        if (used.size.height < 16 && !((imageH > 0 || videoH > 0) && [text length] == 0))
            used.size.height = 16;
        box = [NSMutableDictionary dictionary];
        [box setObject:rich ? [[rich objectForKey:@"attr"] string] : text forKey:@"text"];
        if (rich)
            [box setObject:rich forKey:@"rich"];
        [box setObject:message forKey:@"message"];
        [box setObject:[NSNumber numberWithBool:typing] forKey:@"typing"];
        [box setObject:attrs forKey:@"attrs"];
        [box setObject:[NSNumber numberWithBool:activity] forKey:@"activity"];
        [box setObject:[NSNumber numberWithBool:status] forKey:@"status"];
        [box setObject:[NSNumber numberWithBool:fromUser] forKey:@"user"];
        if (imageH > 0) {
            [box setObject:imagePath forKey:@"image"];
            [box setObject:[NSValue valueWithSize:NSMakeSize(imageW, imageH)] forKey:@"imageSize"];
        }
        if (fileH > 0)
            [box setObject:filePath forKey:@"file"];
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
            if (fileH > 0) {
                bubble.size.height += fileH;
                if (bubble.size.width < 150)
                    bubble.size.width = 150;
            }
            if (bubble.size.height < 36)
                bubble.size.height = 36;
            if (typing) {
                bubble.size.width = 84;
                bubble.size.height = 50;
            }
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
            if ([box objectForKey:@"file"])
                [box setObject:[NSValue valueWithRect:NSMakeRect(NSMinX(rect) + 17, NSMinY(rect) + 10, 96, 24)] forKey:@"fileRect"];
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
                if ([box objectForKey:@"image"] || [box objectForKey:@"video"] || [box objectForKey:@"file"])
                    textRect.origin.y = NSMaxY(rect) - 10 - textSize.height;
                else
                    textRect.origin.y = NSMinY(rect) + (NSHeight(rect) - textSize.height) / 2.0;
            }
            [box setObject:[NSValue valueWithRect:textRect] forKey:@"textRect"];
            if ([box objectForKey:@"rich"]) {
                NSArray *panels = [[box objectForKey:@"rich"] objectForKey:@"panels"];
                NSMutableArray *drawn = [NSMutableArray array];
                NSMutableArray *copies = [NSMutableArray array];
                unsigned p;
                for (p = 0; p < [panels count]; p++) {
                    NSDictionary *panel = [panels objectAtIndex:p];
                    NSRect pr = [[panel objectForKey:@"panel"] rectValue];
                    NSRect hr = [[panel objectForKey:@"header"] rectValue];
                    NSString *key = [NSString stringWithFormat:@"%p:%u", (void *)[box objectForKey:@"message"], p];
                    NSRect copyLocal = NSMakeRect(NSMaxX(hr) - 58, NSMinY(hr), 58, NSHeight(hr));
                    NSRect saveLocal = NSMakeRect(NSMaxX(hr) - 58 - 46, NSMinY(hr), 46, NSHeight(hr));
                    pr.origin.x += NSMinX(textRect);
                    pr.origin.y = NSMaxY(textRect) - pr.origin.y - pr.size.height;
                    hr.origin.x += NSMinX(textRect);
                    hr.origin.y = NSMaxY(textRect) - hr.origin.y - hr.size.height;
                    [drawn addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                        [NSValue valueWithRect:pr], @"panel", [NSValue valueWithRect:hr], @"header",
                        [panel objectForKey:@"title"], @"title", key, @"key", nil]];
                    [copies addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                        [NSValue valueWithRect:copyLocal], @"rect", [panel objectForKey:@"code"], @"code", key, @"key", nil]];
                    [copies addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                        [NSValue valueWithRect:saveLocal], @"rect", [panel objectForKey:@"code"], @"code", key, @"key",
                        [NSNumber numberWithBool:YES], @"save", [panel objectForKey:@"title"], @"title", nil]];
                }
                [box setObject:drawn forKey:@"drawnPanels"];
                [box setObject:copies forKey:@"copies"];
            }
        }
    }
    [self setFrameSize:NSMakeSize(layoutWidth, contentH)];
    /* A picture or gradient behind the chat is drawn against the visible part, so a scroll must redraw it. */
    [[[self enclosingScrollView] contentView] setCopiesOnScroll:![TBTheme hasCustomBackground]];
    [self updateTypingTimer];
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
    [view registerForDraggedTypes:[NSArray arrayWithObject:NSFilenamesPboardType]];
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
        [view setHidden:[[box objectForKey:@"typing"] boolValue]];
        [(TBSelectText *)view setActivity:[[box objectForKey:@"activity"] boolValue]];
        {
            NSString *who = [[box objectForKey:@"status"] boolValue] ? ([[box objectForKey:@"activity"] boolValue] ? @"Tool activity" : @"Status")
                : ([[box objectForKey:@"user"] boolValue] ? @"You said" : @"Assistant said");
            if ([box objectForKey:@"imageRect"])
                who = [who stringByAppendingString:@", with a picture"];
            if ([box objectForKey:@"videoRect"])
                who = [who stringByAppendingString:@", with a video"];
            if ([box objectForKey:@"fileRect"])
                who = [who stringByAppendingString:@", with a file to save"];
            if ([box objectForKey:@"copies"] && [[box objectForKey:@"copies"] count] > 0)
                who = [who stringByAppendingString:@", with code or a table. Use Copy Last Code Block in the Chat menu to copy it"];
            [(TBSelectText *)view setSpeakerLabel:who];
        }
        if (!NSEqualRects([view frame], textRect))
            [view setFrame:textRect];
        if (fabsf([[view textContainer] containerSize].width - NSWidth(textRect)) > 0.5f)
            [[view textContainer] setContainerSize:NSMakeSize(NSWidth(textRect), 1000000)];
        if ([box objectForKey:@"rich"]) {
            if (forceTextReset || ![[view string] isEqualToString:text])
                [[view textStorage] setAttributedString:[[box objectForKey:@"rich"] objectForKey:@"attr"]];
            [(TBSelectText *)view setCopies:[box objectForKey:@"copies"]];
            continue;
        }
        [(TBSelectText *)view setCopies:nil];
        if (hasStandIn(text)) {
            if (forceTextReset || ![[view string] isEqualToString:withObjectCharacters(text)])
                [[view textStorage] setAttributedString:withEmojiPictures([[[NSAttributedString alloc] initWithString:text attributes:attrs] autorelease])];
        } else if (forceTextReset || ![[view string] isEqualToString:text]) {
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

/* The dark panels behind code blocks: a header strip with the language and Copy. */
- (void)drawCodePanels:(NSArray *)panels
{
    unsigned p;
    NSDictionary *titleAttrs = [NSDictionary dictionaryWithObjectsAndKeys:
        [NSFont boldSystemFontOfSize:10], NSFontAttributeName,
        [NSColor colorWithCalibratedWhite:0.72 alpha:1], NSForegroundColorAttributeName, nil];
    for (p = 0; p < [panels count]; p++) {
        NSDictionary *entry = [panels objectAtIndex:p];
        NSRect panel = [[entry objectForKey:@"panel"] rectValue];
        NSRect header = [[entry objectForKey:@"header"] rectValue];
        NSBezierPath *shape = [NSBezierPath bezierPath];
        BOOL copied = copiedKey && [copiedKey isEqualToString:[entry objectForKey:@"key"]];
        NSString *label = copied ? @"Copied" : @"Copy";
        NSDictionary *copyAttrs = [NSDictionary dictionaryWithObjectsAndKeys:
            [NSFont boldSystemFontOfSize:10], NSFontAttributeName,
            copied ? [NSColor colorWithCalibratedRed:0.55 green:0.88 blue:0.55 alpha:1] : [NSColor colorWithCalibratedRed:0.62 green:0.78 blue:1 alpha:1],
            NSForegroundColorAttributeName, nil];
        NSSize labelSize = [label sizeWithAttributes:copyAttrs];
        NSSize titleSize = [[entry objectForKey:@"title"] sizeWithAttributes:titleAttrs];
        appendRoundedRect(shape, panel, 7);
        [[NSColor colorWithCalibratedWhite:0.13 alpha:1] set];
        [shape fill];
        [NSGraphicsContext saveGraphicsState];
        [shape addClip];
        [[NSColor colorWithCalibratedWhite:0.23 alpha:1] set];
        NSRectFill(header);
        [[NSColor colorWithCalibratedWhite:0.08 alpha:1] set];
        NSRectFill(NSMakeRect(NSMinX(header), NSMinY(header), NSWidth(header), 1));
        [NSGraphicsContext restoreGraphicsState];
        [[NSColor colorWithCalibratedWhite:0.05 alpha:1] set];
        [shape setLineWidth:1];
        [shape stroke];
        [[entry objectForKey:@"title"] drawAtPoint:NSMakePoint(NSMinX(header) + 12, NSMidY(header) - titleSize.height / 2) withAttributes:titleAttrs];
        [label drawAtPoint:NSMakePoint(NSMaxX(header) - 12 - labelSize.width, NSMidY(header) - labelSize.height / 2) withAttributes:copyAttrs];
        {
            NSDictionary *saveAttrs = [NSDictionary dictionaryWithObjectsAndKeys:
                [NSFont boldSystemFontOfSize:10], NSFontAttributeName,
                [NSColor colorWithCalibratedRed:0.62 green:0.78 blue:1 alpha:1], NSForegroundColorAttributeName, nil];
            NSSize saveSize = [@"Save" sizeWithAttributes:saveAttrs];
            [@"Save" drawAtPoint:NSMakePoint(NSMaxX(header) - 12 - 38 - 14 - saveSize.width, NSMidY(header) - saveSize.height / 2) withAttributes:saveAttrs];
        }
    }
}

- (void)drawRect:(NSRect)dirty
{
    unsigned i;

    [TBTheme drawBackground:dirty visible:[self visibleRect]];
    for (i = 0; i < [boxes count]; i++) {
        NSDictionary *box = [boxes objectAtIndex:i];
        NSRect rect = [[box objectForKey:@"rect"] rectValue];
        BOOL status = [[box objectForKey:@"status"] boolValue];
        BOOL fromUser = [[box objectForKey:@"user"] boolValue];
        if (status) {
            if([[box objectForKey:@"activity"] boolValue]) {
                NSBezierPath *card=[NSBezierPath bezierPath];appendRoundedRect(card,rect,5);
                [[TBTheme toolBoxColor] set];[card fill];
                [[TBTheme toolBorderColor] set];[card setLineWidth:1];[card stroke];
            }
            continue;
        }
        {
            if ([[box objectForKey:@"typing"] boolValue]) {
                paintThoughtCloud(rect, typingPhase);
                continue;
            }
            paintBubble(rect, fromUser);
            if ([box objectForKey:@"drawnPanels"])
                [self drawCodePanels:[box objectForKey:@"drawnPanels"]];
            if ([box objectForKey:@"fileRect"]) {
                NSRect pill = [[box objectForKey:@"fileRect"] rectValue];
                NSBezierPath *shape = [NSBezierPath bezierPath];
                NSDictionary *pillAttrs = [NSDictionary dictionaryWithObjectsAndKeys:
                    [NSFont boldSystemFontOfSize:11], NSFontAttributeName,
                    [NSColor colorWithCalibratedWhite:0.1 alpha:1], NSForegroundColorAttributeName, nil];
                NSSize pillSize = [@"Save As..." sizeWithAttributes:pillAttrs];
                appendRoundedRect(shape, pill, 12);
                [[NSColor colorWithCalibratedWhite:0.97 alpha:1] set];
                [shape fill];
                [[NSColor colorWithCalibratedWhite:0.45 alpha:1] set];
                [shape setLineWidth:1];
                [shape stroke];
                [@"Save As..." drawAtPoint:NSMakePoint(NSMidX(pill) - pillSize.width / 2, NSMidY(pill) - pillSize.height / 2) withAttributes:pillAttrs];
            }
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
                [(TBInlineVideoAvailable() ? @"QuickTime could not open this video." : @"Double-click to play this video.")
                    drawInRect:videoRect withAttributes:statusAttrs];
            }
        }
    }
}

- (BOOL)isFlipped
{
    return NO;
}

/* The menu for one message: copy it, and for what the person wrote, edit from there; for any, branch. */
- (NSMenu *)messageMenuForBox:(NSDictionary *)box
{
    NSMenu *menu;
    NSMenuItem *item;
    NSDictionary *message=[box objectForKey:@"message"];
    NSString *content=[[box objectForKey:@"activity"] boolValue]?[message objectForKey:@"detail"]:[message objectForKey:@"text"];
    menu=[[[NSMenu alloc] initWithTitle:@"Message"] autorelease];
    item=[[[NSMenuItem alloc] initWithTitle:@"Copy Whole Message" action:@selector(copyMessageText:) keyEquivalent:@""] autorelease];
    [item setTarget:self];[item setRepresentedObject:content?content:@""];[menu addItem:item];
    if(dropTarget&&![[message objectForKey:@"status"] boolValue]&&![message objectForKey:@"activityKind"]) {
        BOOL fromPerson=[[message objectForKey:@"role"] isEqualToString:@"user"]&&![message objectForKey:@"attachment"];
        [menu addItem:[NSMenuItem separatorItem]];
        if(fromPerson&&[dropTarget respondsToSelector:@selector(editFromMessage:)]) {
            item=[[[NSMenuItem alloc] initWithTitle:@"Edit From Here" action:@selector(editFromHere:) keyEquivalent:@""] autorelease];
            [item setTarget:self];[item setRepresentedObject:message];[menu addItem:item];
        }
        if([dropTarget respondsToSelector:@selector(branchFromMessage:)]) {
            item=[[[NSMenuItem alloc] initWithTitle:@"Branch Chat From Here" action:@selector(branchFromHere:) keyEquivalent:@""] autorelease];
            [item setTarget:self];[item setRepresentedObject:message];[menu addItem:item];
        }
    }
    return menu;
}

/* Right-click on a message's own text: the text view's usual menu, then this one's items. */
- (NSMenu *)menuForTextView:(NSTextView *)view base:(NSMenu *)base
{
    NSUInteger index=[textViews indexOfObject:view];
    NSMenu *extra;
    unsigned i;
    if(index==NSNotFound||index>=[boxes count])return base;
    extra=[self messageMenuForBox:[boxes objectAtIndex:index]];
    if(!base)return extra;
    [base addItem:[NSMenuItem separatorItem]];
    while([extra numberOfItems]>0) {
        NSMenuItem *moved=[[[extra itemAtIndex:0] retain] autorelease];
        [extra removeItemAtIndex:0];
        [base addItem:moved];
    }
    (void)i;
    return base;
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
        if ([box objectForKey:@"file"] && NSPointInRect(point, [[box objectForKey:@"rect"] rectValue])) {
            path = [box objectForKey:@"file"];
            break;
        }
    }
    if (!path) {
        for(i=0;i<[boxes count];i++) {
            NSDictionary *box=[boxes objectAtIndex:i];
            if(!NSPointInRect(point,[[box objectForKey:@"rect"] rectValue]))continue;
            return [self messageMenuForBox:box];
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
- (void)editFromHere:(id)sender
{
    [dropTarget performSelector:@selector(editFromMessage:) withObject:[sender representedObject]];
}

- (void)branchFromHere:(id)sender
{
    [dropTarget performSelector:@selector(branchFromMessage:) withObject:[sender representedObject]];
}

- (void)copyMessageText:(id)sender
{
    NSPasteboard *p=[NSPasteboard generalPasteboard];[p declareTypes:[NSArray arrayWithObject:NSStringPboardType] owner:nil];
    [p setString:[sender representedObject] forType:NSStringPboardType];
}
- (void)mouseDown:(NSEvent *)event
{
    NSPoint point=[self convertPoint:[event locationInWindow] fromView:nil];unsigned i;
    for(i=0;i<[boxes count];i++) {
        NSDictionary *fileBox=[boxes objectAtIndex:i];
        if([fileBox objectForKey:@"fileRect"]&&NSPointInRect(point,[[fileBox objectForKey:@"fileRect"] rectValue])) {
            [self saveFileAtPath:[fileBox objectForKey:@"file"]];return;
        }
    }
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

/* Save As for a block of code the model wrote. */
- (void)saveCode:(NSString *)code title:(NSString *)title
{
    NSSavePanel *panel = [NSSavePanel savePanel];
    NSString *ext = TBLanguageExtension(title);
    NSString *name = [ext isEqualToString:@"mk"] ? @"Makefile" : [@"snippet." stringByAppendingString:ext];
    if ([panel runModalForDirectory:[@"~/Desktop" stringByExpandingTildeInPath] file:name] != NSOKButton)
        return;
    if (![[code dataUsingEncoding:NSUTF8StringEncoding] writeToFile:[panel filename] atomically:YES])
        NSBeep();
}

/* Save As for a file a model made. */
- (void)saveFileAtPath:(NSString *)path
{
    NSSavePanel *panel;
    NSData *data;
    if (!path || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        NSBeep();
        return;
    }
    panel = [NSSavePanel savePanel];
    if ([panel runModalForDirectory:[@"~/Desktop" stringByExpandingTildeInPath] file:TBDisplayFileName(path)] != NSOKButton)
        return;
    data = [NSData dataWithContentsOfFile:path];
    if (!data || ![data writeToFile:[panel filename] atomically:YES])
        NSBeep();
}

- (void)saveMediaAs:(id)sender
{
    NSString *path = [sender representedObject];
    if ([[path lastPathComponent] length] > 17 && [[path lastPathComponent] characterAtIndex:16] == '-') {
        [self saveFileAtPath:path];
        return;
    }
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


/* ---- the sample in the Appearance panel ---- */

@implementation TBThemePreview

- (id)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self)
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh:) name:TBThemeChangedNotification object:nil];
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [super dealloc];
}

- (void)refresh:(NSNotification *)note
{
    (void)note;
    [self setNeedsDisplay:YES];
}

/* One sample bubble, with its words, at the edge it would sit against. */
- (void)drawSample:(NSString *)words sent:(BOOL)sent y:(float)y
{
    NSMutableParagraphStyle *style = [[[NSMutableParagraphStyle alloc] init] autorelease];
    NSDictionary *attrs;
    NSSize size;
    NSRect rect;
    [style setLineBreakMode:NSLineBreakByClipping];
    attrs = [NSDictionary dictionaryWithObjectsAndKeys:[TBTheme font:sent scale:1.0f], NSFontAttributeName,
        [TBTheme textColor:sent], NSForegroundColorAttributeName, style, NSParagraphStyleAttributeName, nil];
    size = [words sizeWithAttributes:attrs];
    if (size.width > NSWidth([self bounds]) - 120)
        size.width = NSWidth([self bounds]) - 120;
    rect = NSMakeRect(sent ? NSWidth([self bounds]) - 18 - size.width - 34 : 16, y, size.width + 34, size.height + 18);
    paintBubble(rect, sent);
    [words drawInRect:NSMakeRect(NSMinX(rect) + 17, NSMinY(rect) + 9, size.width, size.height) withAttributes:attrs];
}

- (void)drawRect:(NSRect)dirty
{
    [TBTheme drawBackground:dirty visible:[self bounds]];
    [self drawSample:@"Can you help me with this?" sent:YES y:NSHeight([self bounds]) - 46];
    [self drawSample:@"Yes. What would you like to know?" sent:NO y:NSHeight([self bounds]) - 86];
    paintThoughtCloud(NSMakeRect(NSWidth([self bounds]) - 104, 4, 84, 40), 1);
    /* The thin frame around the sample, as in iChat's preferences. */
    [[NSColor colorWithCalibratedWhite:0.45f alpha:1] set];
    NSFrameRect(NSInsetRect([self bounds], 0, 0));
}

@end

/* A line of the chat's tool card or status text, drawn the way the transcript draws it, for the Appearance tabs. */
@implementation TBThemeSampleView

- (id)initWithFrame:(NSRect)frame mode:(int)which
{
    self = [super initWithFrame:frame];
    if (self) {
        mode = which;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh:) name:TBThemeChangedNotification object:nil];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [super dealloc];
}

- (void)refresh:(NSNotification *)note
{
    (void)note;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirty
{
    NSMutableParagraphStyle *style = [[[NSMutableParagraphStyle alloc] init] autorelease];
    [style setLineBreakMode:NSLineBreakByClipping];
    [TBTheme drawBackground:dirty visible:[self bounds]];
    if (mode == 0) {
        NSDictionary *attrs = [TBTheme toolAttributesScale:1 paragraph:style];
        NSString *lines[2] = {[NSString stringWithFormat:@"%C start_process - Completed (0.5s)", (unichar)0x25b6], [NSString stringWithFormat:@"%C read_file - Completed (0.1s)", (unichar)0x25b6]};
        int i;
        for (i = 0; i < 2; i++) {
            NSSize size = [lines[i] sizeWithAttributes:attrs];
            NSRect card = NSMakeRect(24, NSHeight([self bounds]) - 12 - (i + 1) * (size.height + 16) - i * 6, NSWidth([self bounds]) - 48, size.height + 12);
            NSBezierPath *path = [NSBezierPath bezierPath];
            appendRoundedRect(path, card, 5);
            [[TBTheme toolBoxColor] set];
            [path fill];
            [[TBTheme toolBorderColor] set];
            [path setLineWidth:1];
            [path stroke];
            [lines[i] drawInRect:NSMakeRect(NSMinX(card) + 8, NSMinY(card) + 6, NSWidth(card) - 16, size.height) withAttributes:attrs];
        }
    } else {
        NSDictionary *attrs = [TBTheme statusAttributesScale:1 paragraph:style];
        NSString *text = @"Working on the next step...";
        NSSize size = [text sizeWithAttributes:attrs];
        [text drawAtPoint:NSMakePoint((NSWidth([self bounds]) - size.width) / 2, (NSHeight([self bounds]) - size.height) / 2) withAttributes:attrs];
    }
    [[NSColor colorWithCalibratedWhite:0.45f alpha:1] set];
    NSFrameRect([self bounds]);
}

@end
