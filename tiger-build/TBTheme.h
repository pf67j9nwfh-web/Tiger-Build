#import <Cocoa/Cocoa.h>
#import "TBCompat.h"

/* How chats look, in the way of iChat's Messages preferences: a bubble colour, text colour and font for what the
   person wrote and for replies, and a background (the default, a solid colour, a gradient or a picture).
   Everything is kept in the preferences; nothing set means the original look. */

extern NSString *TBThemeChangedNotification;   /* userInfo "layout" is YES when text sizes or colours changed */

@interface TBTheme : NSObject

+ (void)reload;                 /* read the preferences again; call after changing them */
+ (void)changed:(BOOL)layout;   /* reload, then tell every chat to redraw (and re-lay out if layout) */
+ (void)reset;

/* Colour preferences, stored as three numbers. nil means the original. */
+ (NSColor *)colorForKey:(NSString *)key;
+ (void)setColor:(NSColor *)color forKey:(NSString *)key;

/* Bubble colours as red, green, blue (0 to 1): the bright rim, the body, the glow at the bottom and the outline. */
+ (void)getBubble:(BOOL)sent top:(float *)top body:(float *)body low:(float *)low line:(float *)line;
+ (NSColor *)textColor:(BOOL)sent;
+ (NSFont *)font:(BOOL)sent scale:(float)scale;

/* A straight vertical blend that fills the current clip. */
+ (void)fillGradient:(NSRect)area from:(NSColor *)top to:(NSColor *)bottom;
+ (BOOL)hasCustomBackground;
/* Paints the area `dirty` of a view whose visible part is `visible` (the backdrop stays put while scrolling). */
+ (void)drawBackground:(NSRect)dirty visible:(NSRect)visible;

@end

/* The preference keys. */
extern NSString *const TBThemeSentBubble;
extern NSString *const TBThemeSentText;
extern NSString *const TBThemeGotBubble;
extern NSString *const TBThemeGotText;
extern NSString *const TBThemeSentFont;      /* family name, or nothing for the system font */
extern NSString *const TBThemeGotFont;
extern NSString *const TBThemeSentSize;      /* points at normal text size, 0 or nothing for the default */
extern NSString *const TBThemeGotSize;
extern NSString *const TBThemeBackground;    /* "solid", "gradient" or "picture"; nothing for the default */
extern NSString *const TBThemeBackColor;
extern NSString *const TBThemeBackColor2;
extern NSString *const TBThemePicture;       /* path of the picture */
