#import "ChatController_Private.h"
#import "TBTheme.h"
#import "TranscriptView.h"

/* View > Appearance...: bubble colours, text colours and fonts for what you write and for replies, and a background
   that is the default, a solid colour, a gradient or a picture. Changes show at once in the chat and in the sample.
   Kept in the preferences, the same for every chat. */

@interface TBAppearance : NSObject {
    NSPanel *panel;
    NSColorWell *sentBubble;
    NSColorWell *sentText;
    NSColorWell *gotBubble;
    NSColorWell *gotText;
    NSPopUpButton *sentFont;
    NSPopUpButton *sentSize;
    NSPopUpButton *gotFont;
    NSPopUpButton *gotSize;
    NSPopUpButton *backdrop;
    NSColorWell *backColor;
    NSColorWell *backColor2;
    NSButton *pictureButton;
    NSTextField *pictureName;
}
+ (TBAppearance *)shared;
- (void)show;
@end

static NSString *kinds[] = {nil, @"solid", @"gradient", @"picture"};

@implementation TBAppearance

+ (TBAppearance *)shared
{
    static TBAppearance *one = nil;
    if (!one)
        one = [[TBAppearance alloc] init];
    return one;
}

- (NSTextField *)label:(NSString *)text frame:(NSRect)frame right:(BOOL)right bold:(BOOL)bold
{
    NSTextField *field = [[[NSTextField alloc] initWithFrame:frame] autorelease];
    [field setStringValue:text];
    [field setBezeled:NO];
    [field setDrawsBackground:NO];
    [field setEditable:NO];
    [field setSelectable:NO];
    [field setFont:bold ? [NSFont boldSystemFontOfSize:12] : [NSFont systemFontOfSize:12]];
    if (right)
        [field setAlignment:NSRightTextAlignment];
    [[panel contentView] addSubview:field];
    return field;
}

- (NSColorWell *)well:(NSRect)frame tip:(NSString *)tip action:(SEL)action
{
    NSColorWell *well = [[[NSColorWell alloc] initWithFrame:frame] autorelease];
    [well setTarget:self];
    [well setAction:action];
    [well setToolTip:tip];
    [[panel contentView] addSubview:well];
    return well;
}

- (NSPopUpButton *)popup:(NSRect)frame tip:(NSString *)tip action:(SEL)action
{
    NSPopUpButton *popup = [[[NSPopUpButton alloc] initWithFrame:frame pullsDown:NO] autorelease];
    [popup setTarget:self];
    [popup setAction:action];
    [popup setToolTip:tip];
    [[popup cell] setControlSize:NSSmallControlSize];
    [popup setFont:[NSFont systemFontOfSize:11]];
    [[panel contentView] addSubview:popup];
    return popup;
}

/* Heading, colour row and font row for one side; the rows sit at y and y - 30. */
- (void)section:(NSString *)title y:(float)y bubble:(NSColorWell **)bubble text:(NSColorWell **)text font:(NSPopUpButton **)font size:(NSPopUpButton **)size
    bubbleAction:(SEL)bubbleAction textAction:(SEL)textAction fontAction:(SEL)fontAction sizeAction:(SEL)sizeAction
{
    NSArray *families = [[[NSFontManager sharedFontManager] availableFontFamilies] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    unsigned i;
    [self label:title frame:NSMakeRect(20, y + 60, 420, 18) right:NO bold:YES];
    [self label:@"Bubble color:" frame:NSMakeRect(20, y + 32, 100, 17) right:YES bold:NO];
    *bubble = [self well:NSMakeRect(130, y + 28, 44, 24) tip:@"Bubble color" action:bubbleAction];
    [self label:@"Text color:" frame:NSMakeRect(200, y + 32, 80, 17) right:YES bold:NO];
    *text = [self well:NSMakeRect(290, y + 28, 44, 24) tip:@"Text color" action:textAction];
    [self label:@"Font:" frame:NSMakeRect(20, y + 4, 100, 17) right:YES bold:NO];
    *font = [self popup:NSMakeRect(130, y, 200, 22) tip:@"Font" action:fontAction];
    [*font addItemWithTitle:@"System Font"];
    for (i = 0; i < [families count]; i++)
        [*font addItemWithTitle:[families objectAtIndex:i]];
    [self label:@"Size:" frame:NSMakeRect(336, y + 4, 36, 17) right:YES bold:NO];
    *size = [self popup:NSMakeRect(376, y, 64, 22) tip:@"Text size" action:sizeAction];
    for (i = 10; i <= 28; i++)
        [*size addItemWithTitle:[NSString stringWithFormat:@"%u", i]];
}

- (void)build
{
    NSButton *reset;
    NSButton *done;
    NSView *preview;
    panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 460, 470) styleMask:NSTitledWindowMask | NSClosableWindowMask
                                         backing:NSBackingStoreBuffered defer:NO];
    [panel setTitle:@"Appearance"];
    [panel setReleasedWhenClosed:NO];
    preview = [[[TBThemePreview alloc] initWithFrame:NSMakeRect(20, 312, 420, 140)] autorelease];
    [[panel contentView] addSubview:preview];
    [self section:@"Your messages" y:232 bubble:&sentBubble text:&sentText font:&sentFont size:&sentSize
     bubbleAction:@selector(sentBubbleChanged:) textAction:@selector(sentTextChanged:) fontAction:@selector(sentFontChanged:) sizeAction:@selector(sentFontChanged:)];
    [self section:@"Replies" y:142 bubble:&gotBubble text:&gotText font:&gotFont size:&gotSize
     bubbleAction:@selector(gotBubbleChanged:) textAction:@selector(gotTextChanged:) fontAction:@selector(gotFontChanged:) sizeAction:@selector(gotFontChanged:)];
    [self label:@"Background" frame:NSMakeRect(20, 112, 420, 18) right:NO bold:YES];
    [self label:@"Style:" frame:NSMakeRect(20, 84, 100, 17) right:YES bold:NO];
    backdrop = [self popup:NSMakeRect(130, 80, 130, 22) tip:@"Chat background" action:@selector(backdropChanged:)];
    [backdrop addItemWithTitle:@"Default"];
    [backdrop addItemWithTitle:@"Solid Color"];
    [backdrop addItemWithTitle:@"Gradient"];
    [backdrop addItemWithTitle:@"Picture"];
    backColor = [self well:NSMakeRect(272, 78, 44, 24) tip:@"Background color, or the top of the gradient" action:@selector(backColorChanged:)];
    backColor2 = [self well:NSMakeRect(322, 78, 44, 24) tip:@"Bottom of the gradient" action:@selector(backColorChanged:)];
    pictureButton = [[[NSButton alloc] initWithFrame:NSMakeRect(130, 44, 140, 28)] autorelease];
    [pictureButton setTitle:@"Choose Picture..."];
    [pictureButton setBezelStyle:NSRoundedBezelStyle];
    [pictureButton setTarget:self];
    [pictureButton setAction:@selector(choosePicture:)];
    [[panel contentView] addSubview:pictureButton];
    pictureName = [self label:@"" frame:NSMakeRect(276, 50, 164, 17) right:NO bold:NO];
    [[pictureName cell] setLineBreakMode:NSLineBreakByTruncatingMiddle];
    reset = [[[NSButton alloc] initWithFrame:NSMakeRect(20, 10, 150, 28)] autorelease];
    [reset setTitle:@"Reset to Default"];
    [reset setBezelStyle:NSRoundedBezelStyle];
    [reset setTarget:self];
    [reset setAction:@selector(resetTheme:)];
    [[panel contentView] addSubview:reset];
    done = [[[NSButton alloc] initWithFrame:NSMakeRect(360, 10, 80, 28)] autorelease];
    [done setTitle:@"Done"];
    [done setBezelStyle:NSRoundedBezelStyle];
    [done setKeyEquivalent:@"\r"];
    [done setTarget:panel];
    [done setAction:@selector(performClose:)];
    [[panel contentView] addSubview:done];
    [panel center];
}

/* Put the controls in step with what is stored. */
- (void)refresh
{
    float top[3], body[3], low[3], line[3];
    NSString *kind = [[NSUserDefaults standardUserDefaults] stringForKey:TBThemeBackground];
    NSString *path = [[NSUserDefaults standardUserDefaults] stringForKey:TBThemePicture];
    NSColor *one;
    NSColor *two;
    NSString *family;
    int index = 0;
    int i;
    [TBTheme getBubble:YES top:top body:body low:low line:line];
    [sentBubble setColor:[NSColor colorWithCalibratedRed:body[0] green:body[1] blue:body[2] alpha:1]];
    [TBTheme getBubble:NO top:top body:body low:low line:line];
    [gotBubble setColor:[NSColor colorWithCalibratedRed:body[0] green:body[1] blue:body[2] alpha:1]];
    [sentText setColor:[TBTheme textColor:YES]];
    [gotText setColor:[TBTheme textColor:NO]];
    for (i = 0; i < 2; i++) {
        NSPopUpButton *fontPopup = i == 0 ? sentFont : gotFont;
        NSPopUpButton *sizePopup = i == 0 ? sentSize : gotSize;
        float size = [[NSUserDefaults standardUserDefaults] floatForKey:i == 0 ? TBThemeSentSize : TBThemeGotSize];
        family = [[NSUserDefaults standardUserDefaults] stringForKey:i == 0 ? TBThemeSentFont : TBThemeGotFont];
        if ([family length] && [fontPopup indexOfItemWithTitle:family] >= 0)
            [fontPopup selectItemWithTitle:family];
        else
            [fontPopup selectItemAtIndex:0];
        if (size < 10 || size > 28)
            size = 14;
        [sizePopup selectItemWithTitle:[NSString stringWithFormat:@"%d", (int)size]];
    }
    for (i = 1; i < 4; i++) {
        if ([kind isEqualToString:kinds[i]])
            index = i;
    }
    [backdrop selectItemAtIndex:index];
    one = [TBTheme colorForKey:TBThemeBackColor];
    two = [TBTheme colorForKey:TBThemeBackColor2];
    [backColor setColor:one ? one : [NSColor colorWithCalibratedRed:215.0 / 255 green:219.0 / 255 blue:227.0 / 255 alpha:1]];
    [backColor2 setColor:two ? two : [NSColor colorWithCalibratedRed:150.0 / 255 green:170.0 / 255 blue:205.0 / 255 alpha:1]];
    [backColor setEnabled:index == 1 || index == 2];
    [backColor2 setEnabled:index == 2];
    [pictureButton setEnabled:index == 3];
    [pictureName setStringValue:index == 3 && [path length] ? [path lastPathComponent] : @""];
}

- (void)show
{
    if (!panel)
        [self build];
    [TBTheme reload];
    [self refresh];
    [panel makeKeyAndOrderFront:nil];
}

- (void)saveColor:(NSColorWell *)well key:(NSString *)key layout:(BOOL)layout
{
    [TBTheme setColor:[well color] forKey:key];
    [TBTheme changed:layout];
}

- (void)sentBubbleChanged:(id)sender { [self saveColor:sender key:TBThemeSentBubble layout:NO]; }
- (void)gotBubbleChanged:(id)sender { [self saveColor:sender key:TBThemeGotBubble layout:NO]; }
- (void)sentTextChanged:(id)sender { [self saveColor:sender key:TBThemeSentText layout:YES]; }
- (void)gotTextChanged:(id)sender { [self saveColor:sender key:TBThemeGotText layout:YES]; }

- (void)saveFont:(NSPopUpButton *)fontPopup size:(NSPopUpButton *)sizePopup familyKey:(NSString *)familyKey sizeKey:(NSString *)sizeKey
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([fontPopup indexOfSelectedItem] == 0)
        [defaults removeObjectForKey:familyKey];
    else
        [defaults setObject:[fontPopup titleOfSelectedItem] forKey:familyKey];
    if ([[sizePopup titleOfSelectedItem] intValue] == 14)
        [defaults removeObjectForKey:sizeKey];
    else
        [defaults setInteger:[[sizePopup titleOfSelectedItem] intValue] forKey:sizeKey];
    [defaults synchronize];
    [TBTheme changed:YES];
}

- (void)sentFontChanged:(id)sender
{
    (void)sender;
    [self saveFont:sentFont size:sentSize familyKey:TBThemeSentFont sizeKey:TBThemeSentSize];
}

- (void)gotFontChanged:(id)sender
{
    (void)sender;
    [self saveFont:gotFont size:gotSize familyKey:TBThemeGotFont sizeKey:TBThemeGotSize];
}

- (void)backColorChanged:(id)sender
{
    (void)sender;
    [TBTheme setColor:[backColor color] forKey:TBThemeBackColor];
    [TBTheme setColor:[backColor2 color] forKey:TBThemeBackColor2];
    [TBTheme changed:NO];
}

- (void)choosePicture:(id)sender
{
    NSOpenPanel *open = [NSOpenPanel openPanel];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    (void)sender;
    [open setAllowsMultipleSelection:NO];
    [open setCanChooseDirectories:NO];
    [open setMessage:@"Choose the picture to put behind your chats."];
    if ([open runModalForDirectory:nil file:nil types:[NSImage imageFileTypes]] == NSOKButton && [[open filenames] count] > 0)
        [defaults setObject:[[open filenames] objectAtIndex:0] forKey:TBThemePicture];
    [defaults synchronize];
    [TBTheme changed:NO];
    [self refresh];
}

- (void)backdropChanged:(id)sender
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    int index = [backdrop indexOfSelectedItem];
    (void)sender;
    if (index == 0)
        [defaults removeObjectForKey:TBThemeBackground];
    else
        [defaults setObject:kinds[index] forKey:TBThemeBackground];
    if (index == 1 || index == 2) {
        [TBTheme setColor:[backColor color] forKey:TBThemeBackColor];
        [TBTheme setColor:[backColor2 color] forKey:TBThemeBackColor2];
    }
    [defaults synchronize];
    [TBTheme changed:NO];
    [self refresh];
    if (index == 3 && ![[defaults stringForKey:TBThemePicture] length])
        [self choosePicture:nil];
}

- (void)resetTheme:(id)sender
{
    (void)sender;
    [TBTheme reset];
    [self refresh];
}

@end

@implementation ChatController (Appearance)

- (IBAction)showAppearance:(id)sender
{
    (void)sender;
    [[TBAppearance shared] show];
}

@end
