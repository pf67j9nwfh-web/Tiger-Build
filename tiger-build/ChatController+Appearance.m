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
    NSTabView *tabs;
    NSView *target;                 /* the tab the controls are being added to */
    NSMutableDictionary *controls;  /* key -> the control that edits it, so Reset and Refresh can set them all */
    NSMutableArray *bindings;       /* {control, key, kind} */
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
    [target addSubview:field];
    return field;
}

- (NSColorWell *)well:(NSRect)frame tip:(NSString *)tip action:(SEL)action
{
    NSColorWell *well = [[[NSColorWell alloc] initWithFrame:frame] autorelease];
    [well setTarget:self];
    [well setAction:action];
    [well setToolTip:tip];
    [target addSubview:well];
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
    [target addSubview:popup];
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

/* One tab of the panel: a view to add controls to. */
- (void)addTab:(NSString *)title
{
    NSTabViewItem *item = [[[NSTabViewItem alloc] initWithIdentifier:title] autorelease];
    [item setLabel:title];
    [item setView:[[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, 322)] autorelease]];
    [tabs addTabViewItem:item];
    target = [item view];
}

/* ---- controls for the new settings, found again by key ---- */

- (void)bind:(id)control key:(NSString *)key kind:(NSString *)kind fallback:(NSColor *)fallback
{
    [bindings addObject:fallback ? [NSArray arrayWithObjects:control, key, kind, fallback, nil] : [NSArray arrayWithObjects:control, key, kind, nil]];
}

- (NSArray *)bindingFor:(id)control
{
    unsigned i;
    for (i = 0; i < [bindings count]; i++)
        if ([[bindings objectAtIndex:i] objectAtIndex:0] == control)
            return [bindings objectAtIndex:i];
    return nil;
}

/* A font popup (and a size popup if sizeKey) for settings under familyKey and sizeKey. */
- (void)fontRow:(NSString *)title y:(float)y family:(NSString *)familyKey size:(NSString *)sizeKey defaultName:(NSString *)defaultName
{
    NSArray *families = [[[NSFontManager sharedFontManager] availableFontFamilies] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    NSPopUpButton *font = [self popup:NSMakeRect(130, y, sizeKey ? 200 : 270, 22) tip:@"Font" action:@selector(genericFontChanged:)];
    unsigned i;
    [self label:title frame:NSMakeRect(10, y + 4, 114, 17) right:YES bold:NO];
    [font addItemWithTitle:defaultName];
    for (i = 0; i < [families count]; i++)
        [font addItemWithTitle:[families objectAtIndex:i]];
    [self bind:font key:familyKey kind:@"family" fallback:nil];
    if (sizeKey) {
        NSPopUpButton *size = [self popup:NSMakeRect(376, y, 64, 22) tip:@"Text size" action:@selector(genericSizeChanged:)];
        [self label:@"Size:" frame:NSMakeRect(336, y + 4, 36, 17) right:YES bold:NO];
        [size addItemWithTitle:@"Default"];
        for (i = 8; i <= 30; i++)
            [size addItemWithTitle:[NSString stringWithFormat:@"%u", i]];
        [self bind:size key:sizeKey kind:@"size" fallback:nil];
    }
}

- (NSColorWell *)colorRow:(NSString *)title x:(float)x y:(float)y key:(NSString *)key fallback:(NSColor *)fallback
{
    NSColorWell *well;
    [self label:title frame:NSMakeRect(x, y + 4, 114, 17) right:YES bold:NO];
    well = [self well:NSMakeRect(x + 120, y, 44, 24) tip:title action:@selector(genericColorChanged:)];
    [self bind:well key:key kind:@"color" fallback:fallback];
    [well setColor:fallback];
    return well;
}

- (void)build
{
    NSButton *reset;
    NSButton *done;
    NSView *preview;
    controls = [[NSMutableDictionary alloc] init];
    bindings = [[NSMutableArray alloc] init];
    panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 520, 530) styleMask:NSTitledWindowMask | NSClosableWindowMask
                                         backing:NSBackingStoreBuffered defer:NO];
    [panel setTitle:@"Appearance"];
    [panel setReleasedWhenClosed:NO];
    target = [panel contentView];
    preview = [[[TBThemePreview alloc] initWithFrame:NSMakeRect(20, 412, 480, 108)] autorelease];
    [[panel contentView] addSubview:preview];
    tabs = [[[NSTabView alloc] initWithFrame:NSMakeRect(10, 46, 500, 356)] autorelease];
    [tabs setFont:[NSFont systemFontOfSize:11]];
    [[panel contentView] addSubview:tabs];

    /* ---- chat: bubbles, text and the backdrop ---- */
    [self addTab:@"Chat"];
    [self section:@"Your messages" y:222 bubble:&sentBubble text:&sentText font:&sentFont size:&sentSize
     bubbleAction:@selector(sentBubbleChanged:) textAction:@selector(sentTextChanged:) fontAction:@selector(sentFontChanged:) sizeAction:@selector(sentFontChanged:)];
    [self section:@"Replies" y:132 bubble:&gotBubble text:&gotText font:&gotFont size:&gotSize
     bubbleAction:@selector(gotBubbleChanged:) textAction:@selector(gotTextChanged:) fontAction:@selector(gotFontChanged:) sizeAction:@selector(gotFontChanged:)];
    [self label:@"Background" frame:NSMakeRect(20, 102, 420, 18) right:NO bold:YES];
    [self label:@"Style:" frame:NSMakeRect(20, 74, 100, 17) right:YES bold:NO];
    backdrop = [self popup:NSMakeRect(130, 70, 130, 22) tip:@"Chat background" action:@selector(backdropChanged:)];
    [backdrop addItemWithTitle:@"Default"];
    [backdrop addItemWithTitle:@"Solid Color"];
    [backdrop addItemWithTitle:@"Gradient"];
    [backdrop addItemWithTitle:@"Picture"];
    backColor = [self well:NSMakeRect(272, 68, 44, 24) tip:@"Background color, or the top of the gradient" action:@selector(backColorChanged:)];
    backColor2 = [self well:NSMakeRect(322, 68, 44, 24) tip:@"Bottom of the gradient" action:@selector(backColorChanged:)];
    pictureButton = [[[NSButton alloc] initWithFrame:NSMakeRect(130, 34, 140, 28)] autorelease];
    [pictureButton setTitle:@"Choose Picture..."];
    [pictureButton setBezelStyle:NSRoundedBezelStyle];
    [pictureButton setTarget:self];
    [pictureButton setAction:@selector(choosePicture:)];
    [target addSubview:pictureButton];
    pictureName = [self label:@"" frame:NSMakeRect(276, 40, 164, 17) right:NO bold:NO];
    [[pictureName cell] setLineBreakMode:NSLineBreakByTruncatingMiddle];

    /* ---- tool calls ---- */
    [self addTab:@"Tool Calls"];
    [self label:@"The boxes that show each tool the model ran, such as \"start_process - Completed\"." frame:NSMakeRect(20, 290, 440, 17) right:NO bold:NO];
    [self fontRow:@"Font:" y:254 family:TBThemeToolFont size:TBThemeToolSize defaultName:@"Monaco"];
    [self colorRow:@"Text color:" x:10 y:218 key:TBThemeToolText fallback:[NSColor colorWithCalibratedWhite:0.35f alpha:1]];
    [self colorRow:@"Box color:" x:240 y:218 key:TBThemeToolBox fallback:[NSColor colorWithCalibratedWhite:0.96f alpha:1]];
    [self label:@"Sample" frame:NSMakeRect(20, 190, 100, 17) right:NO bold:YES];
    [target addSubview:[[[TBThemeSampleView alloc] initWithFrame:NSMakeRect(20, 80, 440, 104) mode:0] autorelease]];

    /* ---- status text between the bubbles ---- */
    [self addTab:@"Status Text"];
    [self label:@"The words outside the bubbles, such as \"Working on the next step...\"." frame:NSMakeRect(20, 290, 440, 17) right:NO bold:NO];
    [self fontRow:@"Font:" y:254 family:TBThemeStatusFont size:TBThemeStatusSize defaultName:@"System Font"];
    [self colorRow:@"Text color:" x:10 y:218 key:TBThemeStatusText fallback:[NSColor colorWithCalibratedWhite:0.35f alpha:1]];
    {
        NSPopUpButton *effect;
        [self label:@"Effect:" frame:NSMakeRect(10, 184, 114, 17) right:YES bold:NO];
        effect = [self popup:NSMakeRect(130, 180, 130, 22) tip:@"A soft shadow or a glow around the words" action:@selector(statusEffectChanged:)];
        [effect addItemWithTitle:@"None"];
        [effect addItemWithTitle:@"Shadow"];
        [effect addItemWithTitle:@"Glow"];
        [controls setObject:effect forKey:@"statusEffect"];
        [self colorRow:@"Effect color:" x:240 y:178 key:TBThemeStatusGlow fallback:[NSColor colorWithCalibratedWhite:0 alpha:1]];
    }
    [self label:@"Sample" frame:NSMakeRect(20, 150, 100, 17) right:NO bold:YES];
    [target addSubview:[[[TBThemeSampleView alloc] initWithFrame:NSMakeRect(20, 50, 440, 94) mode:1] autorelease]];

    /* ---- the controls around the chat ---- */
    [self addTab:@"Interface"];
    [self label:@"Chat list" frame:NSMakeRect(20, 296, 200, 17) right:NO bold:YES];
    [self fontRow:@"Font:" y:272 family:TBThemeSideFont size:TBThemeSideSize defaultName:@"System Font"];
    [self colorRow:@"Text color:" x:10 y:240 key:TBThemeSideText fallback:[NSColor blackColor]];
    [self colorRow:@"Background:" x:240 y:240 key:TBThemeSideBack fallback:[NSColor whiteColor]];
    [self label:@"Labels" frame:NSMakeRect(20, 214, 200, 17) right:NO bold:YES];
    [self fontRow:@"Font:" y:190 family:TBThemeLabelFont size:nil defaultName:@"System Font"];
    [self colorRow:@"Text color:" x:10 y:158 key:TBThemeLabelText fallback:[NSColor blackColor]];
    [self label:@"Buttons and menus" frame:NSMakeRect(20, 132, 200, 17) right:NO bold:YES];
    [self fontRow:@"Button font:" y:108 family:TBThemeButtonFont size:nil defaultName:@"System Font"];
    [self colorRow:@"Button text:" x:10 y:76 key:TBThemeButtonText fallback:[NSColor blackColor]];
    [self fontRow:@"Menu font:" y:50 family:TBThemeMenuFont size:nil defaultName:@"System Font"];
    [self colorRow:@"Menu text:" x:10 y:18 key:TBThemeMenuText fallback:[NSColor blackColor]];
    {
        NSPopUpButton *window;
        [self label:@"Window:" frame:NSMakeRect(240, 22, 60, 17) right:YES bold:NO];
        window = [self popup:NSMakeRect(304, 18, 110, 22) tip:@"The look of the window behind the chat list and controls" action:@selector(windowStyleChanged:)];
        [window addItemWithTitle:@"Brushed Metal"];
        [window addItemWithTitle:@"Plain Gray"];
        [window addItemWithTitle:@"Pinstripes"];
        [window addItemWithTitle:@"Solid Color"];
        [controls setObject:window forKey:@"windowStyle"];
        [controls setObject:[self well:NSMakeRect(420, 16, 44, 24) tip:@"Color of the window" action:@selector(windowColorChanged:)] forKey:@"windowColor"];
    }

    reset = [[[NSButton alloc] initWithFrame:NSMakeRect(20, 10, 150, 28)] autorelease];
    [reset setTitle:@"Reset to Default"];
    [reset setBezelStyle:NSRoundedBezelStyle];
    [reset setTarget:self];
    [reset setAction:@selector(resetTheme:)];
    [[panel contentView] addSubview:reset];
    done = [[[NSButton alloc] initWithFrame:NSMakeRect(420, 10, 80, 28)] autorelease];
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
    for (i = 0; i < (int)[bindings count]; i++) {
        NSArray *b = [bindings objectAtIndex:i];
        id control = [b objectAtIndex:0];
        NSString *key = [b objectAtIndex:1], *kind = [b objectAtIndex:2];
        if ([kind isEqualToString:@"color"]) {
            NSColor *c = [TBTheme colorForKey:key];
            [(NSColorWell *)control setColor:c ? c : [b objectAtIndex:3]];
        } else if ([kind isEqualToString:@"family"]) {
            NSString *fam = [[NSUserDefaults standardUserDefaults] stringForKey:key];
            if ([fam length] && [(NSPopUpButton *)control indexOfItemWithTitle:fam] >= 0)
                [(NSPopUpButton *)control selectItemWithTitle:fam];
            else
                [(NSPopUpButton *)control selectItemAtIndex:0];
        } else {
            int n = (int)[[NSUserDefaults standardUserDefaults] floatForKey:key];
            if (n >= 8 && n <= 30)
                [(NSPopUpButton *)control selectItemWithTitle:[NSString stringWithFormat:@"%d", n]];
            else
                [(NSPopUpButton *)control selectItemAtIndex:0];
        }
    }
    {
        NSString *effect = [[NSUserDefaults standardUserDefaults] stringForKey:TBThemeStatusEffect];
        NSString *window = [[NSUserDefaults standardUserDefaults] stringForKey:TBThemeWindow];
        NSColor *wc = [TBTheme colorForKey:TBThemeWindowColor];
        [[controls objectForKey:@"statusEffect"] selectItemAtIndex:[effect isEqualToString:@"shadow"] ? 1 : ([effect isEqualToString:@"glow"] ? 2 : 0)];
        [[controls objectForKey:@"windowStyle"] selectItemAtIndex:[window isEqualToString:@"gray"] ? 1 : ([window isEqualToString:@"stripes"] ? 2 : ([window isEqualToString:@"solid"] ? 3 : 0))];
        [[controls objectForKey:@"windowColor"] setColor:wc ? wc : [NSColor colorWithCalibratedWhite:0.85f alpha:1]];
        [[controls objectForKey:@"windowColor"] setEnabled:[window isEqualToString:@"solid"]];
    }
}

- (void)show
{
    if (!panel)
        [self build];
    [TBTheme reload];
    [self refresh];
    [panel setLevel:NSFloatingWindowLevel];
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

- (void)genericColorChanged:(id)sender
{
    NSArray *b = [self bindingFor:sender];
    if (!b)
        return;
    [TBTheme setColor:[(NSColorWell *)sender color] forKey:[b objectAtIndex:1]];
    [TBTheme changed:YES];
}

- (void)genericFontChanged:(id)sender
{
    NSArray *b = [self bindingFor:sender];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (!b)
        return;
    if ([sender indexOfSelectedItem] == 0)
        [defaults removeObjectForKey:[b objectAtIndex:1]];
    else
        [defaults setObject:[sender titleOfSelectedItem] forKey:[b objectAtIndex:1]];
    [defaults synchronize];
    [TBTheme changed:YES];
}

- (void)genericSizeChanged:(id)sender
{
    NSArray *b = [self bindingFor:sender];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (!b)
        return;
    if ([sender indexOfSelectedItem] == 0)
        [defaults removeObjectForKey:[b objectAtIndex:1]];
    else
        [defaults setInteger:[[sender titleOfSelectedItem] intValue] forKey:[b objectAtIndex:1]];
    [defaults synchronize];
    [TBTheme changed:YES];
}

- (void)statusEffectChanged:(id)sender
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    int n = [sender indexOfSelectedItem];
    if (n == 0)
        [defaults removeObjectForKey:TBThemeStatusEffect];
    else
        [defaults setObject:n == 1 ? @"shadow" : @"glow" forKey:TBThemeStatusEffect];
    [defaults synchronize];
    [TBTheme changed:YES];
}

- (void)windowStyleChanged:(id)sender
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *names[4] = {nil, @"gray", @"stripes", @"solid"};
    int n = [sender indexOfSelectedItem];
    if (n == 0)
        [defaults removeObjectForKey:TBThemeWindow];
    else
        [defaults setObject:names[n] forKey:TBThemeWindow];
    if (n == 3)
        [TBTheme setColor:[[controls objectForKey:@"windowColor"] color] forKey:TBThemeWindowColor];
    [defaults synchronize];
    [TBTheme changed:NO];
    [self refresh];
}

- (void)windowColorChanged:(id)sender
{
    [TBTheme setColor:[(NSColorWell *)sender color] forKey:TBThemeWindowColor];
    [TBTheme changed:NO];
}

- (void)resetTheme:(id)sender
{
    (void)sender;
    [TBTheme reset];
    [self refresh];
}

@end

@implementation ChatController (Appearance)

/* the font a control had before Appearance changed it */
- (NSFont *)originalFontOf:(id)control fallback:(NSFont *)fallback
{
    NSValue *key = [NSValue valueWithPointer:control];
    NSFont *font;
    if (!uiOriginals)
        uiOriginals = [[NSMutableDictionary alloc] init];
    font = [uiOriginals objectForKey:key];
    if (!font) {
        font = [control respondsToSelector:@selector(font)] && [control font] ? [control font] : fallback;
        [uiOriginals setObject:font forKey:key];
    }
    return font;
}

/* Font and text colour for a pop-up button and its menu items (the colour is an attributed title on each item). */
- (void)applyPopupTheme:(NSPopUpButton *)popup
{
    NSFont *font = [TBTheme interfaceFont:[self originalFontOf:popup fallback:[NSFont systemFontOfSize:12]] group:@"menus"];
    NSColor *color = [TBTheme interfaceColor:@"menus"];
    NSArray *items;
    unsigned i;
    if (!popup)
        return;
    [popup setFont:font];
    [[popup menu] setFont:font];
    items = [[popup menu] itemArray];
    for (i = 0; i < [items count]; i++) {
        NSMenuItem *item = [items objectAtIndex:i];
        if (![item isSeparatorItem] && ![item submenu]) {
            if (color)
                [item setAttributedTitle:[[[NSAttributedString alloc] initWithString:[item title]
                    attributes:[NSDictionary dictionaryWithObjectsAndKeys:font, NSFontAttributeName, color, NSForegroundColorAttributeName, nil]] autorelease]];
            else
                [item setTitle:[item title]];
        }
    }
}

- (void)applyButtonTheme:(NSButton *)button
{
    NSFont *font = [TBTheme interfaceFont:[self originalFontOf:button fallback:[NSFont systemFontOfSize:12]] group:@"buttons"];
    NSColor *color = [TBTheme interfaceColor:@"buttons"];
    NSString *title = [button title];
    [button setFont:font];
    if (color && [title length]) {
        NSMutableParagraphStyle *centered = [[[NSMutableParagraphStyle alloc] init] autorelease];
        [centered setAlignment:NSCenterTextAlignment];
        [button setAttributedTitle:[[[NSAttributedString alloc] initWithString:title attributes:[NSDictionary dictionaryWithObjectsAndKeys:
            font, NSFontAttributeName, color, NSForegroundColorAttributeName, centered, NSParagraphStyleAttributeName, nil]] autorelease]];
    } else
        [button setTitle:title];
}

/* The chat list, the labels, buttons and menus, and the window behind them, in the chosen look. Called when a setting changes and after
   a window is built; popups that are rebuilt later call applyPopupTheme: themselves. */
- (void)applyInterfaceTheme
{
    NSArray *panes = [NSArray arrayWithObjects:sidePane, chatPane, nil];
    NSTableColumn *column = [[table tableColumns] count] ? [[table tableColumns] objectAtIndex:0] : nil;
    NSColor *sideColor = [TBTheme interfaceColor:@"side"], *labelColor = [TBTheme interfaceColor:@"labels"], *sideBack = [TBTheme sidebarBackground];
    unsigned p, i;
    if (!window)
        return;
    if (column) {
        NSFont *font = [TBTheme interfaceFont:[NSFont systemFontOfSize:13] group:@"side"];   /* the list's own font is the system font at 13 */
        [[column dataCell] setFont:font];
        [[column dataCell] setTextColor:sideColor ? sideColor : [NSColor blackColor]];
        [table setRowHeight:MAX(20, ceilf([font pointSize] + 8))];
    }
    [table setBackgroundColor:sideBack ? sideBack : [NSColor whiteColor]];
    [table reloadData];
    for (p = 0; p < [panes count]; p++) {
        NSArray *views = [[panes objectAtIndex:p] subviews];
        for (i = 0; i < [views count]; i++) {
            id v = [views objectAtIndex:i];
            if ([v isKindOfClass:[NSPopUpButton class]])
                [self applyPopupTheme:v];
            else if ([v isKindOfClass:[NSButton class]])
                [self applyButtonTheme:v];
            else if ([v isKindOfClass:[NSTextField class]] && ![v isEditable] && v != relayStatusField) {
                [v setFont:[TBTheme interfaceFont:[self originalFontOf:v fallback:[NSFont systemFontOfSize:12]] group:@"labels"]];
                if (labelColor)
                    [v setTextColor:labelColor];
            }
        }
    }
    if ([content respondsToSelector:@selector(setNeedsDisplay:)])
        [content setNeedsDisplay:YES];
    [window display];
}

- (void)interfaceThemeChanged:(NSNotification *)note
{
    (void)note;
    [self applyInterfaceTheme];
}

- (IBAction)showAppearance:(id)sender
{
    (void)sender;
    [[TBAppearance shared] show];
}

@end
