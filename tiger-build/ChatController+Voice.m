#import "ChatController_Private.h"

/* A pseudo voice mode, entirely optional and off until switched on in the Chat menu.
     Speak Last Reply / Stop Speaking     read a reply aloud with the voice chosen here
     Speak Replies Automatically          read each reply when it finishes
     Voice Commands                       say "Send message", "Stop", "New chat", "Read that again" or "Stop talking"
   Mac OS X before 10.8 cannot turn speech into free text, only recognise a short list of commands, so talking to the
   model is by typing; speaking its answers and commanding the app by voice both work. */

@interface ChatController (VoiceNeeds)
- (IBAction)send:(id)sender;
- (IBAction)newChat:(id)sender;
@end

static NSString *kAutoSpeak = @"TBVoiceAutoSpeak";
static NSString *kCommands = @"TBVoiceCommands";
static NSString *kVoice = @"TBVoiceName";

@implementation ChatController (Voice)

- (NSSpeechSynthesizer *)synth
{
    if (!voiceSynth) {
        NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:kVoice];
        voiceSynth = [[NSSpeechSynthesizer alloc] initWithVoice:[saved length] ? saved : nil];
        [voiceSynth setDelegate:self];
    }
    return voiceSynth;
}

- (BOOL)isSpeakingNow
{
    return voiceSynth && [voiceSynth isSpeaking];
}

- (void)speechSynthesizer:(NSSpeechSynthesizer *)sender didFinishSpeaking:(BOOL)finished
{
    (void)sender;
    (void)finished;
}

/* The words of the newest reply of the assistant in the chat that is showing. */
- (NSString *)lastReplyText
{
    NSArray *messages = [current objectForKey:@"messages"];
    int i;
    for (i = (int)[messages count] - 1; i >= 0; i--) {
        NSDictionary *message = [messages objectAtIndex:i];
        NSString *text = [message objectForKey:@"text"];
        if ([[message objectForKey:@"status"] boolValue] || ![[message objectForKey:@"role"] isEqualToString:@"assistant"])
            continue;
        if ([message objectForKey:@"file"] || [message objectForKey:@"video"] || [[message objectForKey:@"open"] boolValue])
            continue;
        if ([text length] > 0)
            return text;
    }
    return nil;
}

- (void)speakText:(NSString *)text
{
    NSString *spoken = TBSpeechText(text);
    if ([spoken length] == 0)
        return;
    /* A very long reply is read in the first part only: nobody wants ten minutes of speech by accident. */
    if ([spoken length] > 4000)
        spoken = [[spoken substringToIndex:4000] stringByAppendingString:@" ... The rest of the reply is not read aloud."];
    [[self synth] stopSpeaking];
    [[self synth] startSpeakingString:spoken];
}

- (IBAction)speakLast:(id)sender
{
    NSString *text = [self lastReplyText];
    (void)sender;
    if (!text) {
        NSBeep();
        return;
    }
    [self speakText:text];
}

- (IBAction)stopSpeaking:(id)sender
{
    (void)sender;
    if (voiceSynth)
        [voiceSynth stopSpeaking];
}

- (IBAction)toggleAutoSpeak:(id)sender
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL on = ![defaults boolForKey:kAutoSpeak];
    (void)sender;
    [defaults setBool:on forKey:kAutoSpeak];
    [defaults synchronize];
    if (!on)
        [self stopSpeaking:nil];
}

/* Called when a reply has just finished. Does nothing unless Speak Replies Automatically is on. */
- (void)speakFinishedReplyIfWanted:(NSMutableDictionary *)chat
{
    NSArray *messages;
    int i;
    if (![[NSUserDefaults standardUserDefaults] boolForKey:kAutoSpeak] || chat != current)
        return;
    messages = [chat objectForKey:@"messages"];
    for (i = (int)[messages count] - 1; i >= 0; i--) {
        NSDictionary *message = [messages objectAtIndex:i];
        if ([[message objectForKey:@"status"] boolValue])
            continue;
        if ([[message objectForKey:@"role"] isEqualToString:@"assistant"] && [[message objectForKey:@"text"] length] > 0) {
            [self speakText:[message objectForKey:@"text"]];
            return;
        }
        if ([[message objectForKey:@"role"] isEqualToString:@"user"])
            return;
    }
}

/* ---- choosing the voice ---- */

- (IBAction)chooseVoice:(id)sender
{
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 380, 160) styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
    NSTextField *label = [[[NSTextField alloc] initWithFrame:NSMakeRect(20, 118, 340, 22)] autorelease];
    NSPopUpButton *popup = [[[NSPopUpButton alloc] initWithFrame:NSMakeRect(20, 86, 340, 26) pullsDown:NO] autorelease];
    NSButton *test = [[[NSButton alloc] initWithFrame:NSMakeRect(20, 48, 160, 28)] autorelease];
    NSButton *ok = [[[NSButton alloc] initWithFrame:NSMakeRect(280, 12, 80, 28)] autorelease];
    NSButton *cancel = [[[NSButton alloc] initWithFrame:NSMakeRect(190, 12, 80, 28)] autorelease];
    NSArray *voices = [NSSpeechSynthesizer availableVoices];
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:kVoice];
    unsigned i;
    int result;
    (void)sender;
    [panel setTitle:@"Voice"];
    [label setStringValue:@"The voice used to read replies aloud:"];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [label setEditable:NO];
    [label setSelectable:NO];
    [popup addItemWithTitle:@"System default voice"];
    for (i = 0; i < [voices count]; i++) {
        NSDictionary *info = [NSSpeechSynthesizer attributesForVoice:[voices objectAtIndex:i]];
        NSString *name = [info objectForKey:NSVoiceName];
        [popup addItemWithTitle:name ? name : [voices objectAtIndex:i]];
        [[popup lastItem] setRepresentedObject:[voices objectAtIndex:i]];
        if (saved && [saved isEqualToString:[voices objectAtIndex:i]])
            [popup selectItem:[popup lastItem]];
    }
    [test setTitle:@"Hear This Voice"];
    [test setBezelStyle:NSRoundedBezelStyle];
    [test setTarget:self];
    [test setAction:@selector(sampleVoice:)];
    [test setTag:0];
    voicePopup = popup;
    [ok setTitle:@"OK"];
    [ok setBezelStyle:NSRoundedBezelStyle];
    [ok setKeyEquivalent:@"\r"];
    [ok setTarget:self];
    [ok setAction:@selector(endVoiceOK:)];
    [cancel setTitle:@"Cancel"];
    [cancel setBezelStyle:NSRoundedBezelStyle];
    [cancel setKeyEquivalent:@"\033"];
    [cancel setTarget:self];
    [cancel setAction:@selector(endVoiceCancel:)];
    [[panel contentView] addSubview:label];
    [[panel contentView] addSubview:popup];
    [[panel contentView] addSubview:test];
    [[panel contentView] addSubview:ok];
    [[panel contentView] addSubview:cancel];
    [panel setDefaultButtonCell:[ok cell]];
    [panel center];
    result = [NSApp runModalForWindow:panel];
    [panel orderOut:nil];
    if (result == 1) {
        NSString *chosen = [[popup selectedItem] representedObject];
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        if (chosen)
            [defaults setObject:chosen forKey:kVoice];
        else
            [defaults removeObjectForKey:kVoice];
        [defaults synchronize];
        [voiceSynth release];
        voiceSynth = nil;
    }
    [voiceSynth stopSpeaking];
    voicePopup = nil;
    [panel release];
}

- (void)sampleVoice:(id)sender
{
    NSString *chosen = [[voicePopup selectedItem] representedObject];
    NSSpeechSynthesizer *sample = [[[NSSpeechSynthesizer alloc] initWithVoice:chosen] autorelease];
    (void)sender;
    [[self synth] stopSpeaking];
    [voiceSample release];
    voiceSample = [sample retain];
    [voiceSample startSpeakingString:@"This is how replies will sound."];
}

- (void)endVoiceOK:(id)sender
{
    (void)sender;
    [NSApp stopModalWithCode:1];
}

- (void)endVoiceCancel:(id)sender
{
    (void)sender;
    [NSApp stopModalWithCode:0];
}

/* ---- voice commands ---- */

- (BOOL)voiceCommandsOn
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:kCommands];
}

- (void)startVoiceCommands
{
    if (voiceRecognizer)
        return;
    voiceRecognizer = [[NSSpeechRecognizer alloc] init];
    [voiceRecognizer setCommands:[NSArray arrayWithObjects:@"Send message", @"Stop", @"New chat", @"Read that again", @"Stop talking", nil]];
    [voiceRecognizer setDelegate:self];
    /* Only while Tiger Build is the front application, so what is said to other programs is left alone. */
    [voiceRecognizer setListensInForegroundOnly:YES];
    [voiceRecognizer setBlocksOtherRecognizers:NO];
    [voiceRecognizer startListening];
}

- (void)stopVoiceCommands
{
    if (voiceRecognizer) {
        [voiceRecognizer stopListening];
        [voiceRecognizer setDelegate:nil];
        [voiceRecognizer release];
        voiceRecognizer = nil;
    }
}

- (IBAction)toggleVoiceCommands:(id)sender
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    BOOL on = ![defaults boolForKey:kCommands];
    (void)sender;
    [defaults setBool:on forKey:kCommands];
    [defaults synchronize];
    if (on)
        [self startVoiceCommands];
    else
        [self stopVoiceCommands];
}

- (void)speechRecognizer:(NSSpeechRecognizer *)sender didRecognizeCommand:(id)command
{
    NSString *said = [command description];
    (void)sender;
    if ([said isEqualToString:@"Send message"]) {
        [self send:nil];
    } else if ([said isEqualToString:@"Stop"]) {
        if (busy)
            [self stopRun:nil];
        else
            [self stopSpeaking:nil];
    } else if ([said isEqualToString:@"New chat"]) {
        if (!busy)
            [self newChat:nil];
    } else if ([said isEqualToString:@"Read that again"]) {
        [self speakLast:nil];
    } else if ([said isEqualToString:@"Stop talking"]) {
        [self stopSpeaking:nil];
    }
}

/* Called once at launch: commands listen again if they were left on. */
- (void)resumeVoiceIfWanted
{
    if ([self voiceCommandsOn])
        [self startVoiceCommands];
}

@end
