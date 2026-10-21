#import "ChatController_Private.h"
#import "TBSpeech.h"
#import "TBSupport.h"

/* A pseudo voice mode, entirely optional and off until switched on in the Chat menu.
     Speak Last Reply / Stop Speaking     read a reply aloud with the voice chosen here
     Speak Replies Automatically          read each reply when it finishes
     Voice Commands                       say "Send message", "Stop", "New chat", "Read that again" or "Stop talking"
   Mac OS X before 10.8 cannot turn speech into free text, only recognise a short list of commands, so talking to the
   model is by typing; speaking its answers and commanding the app by voice both work. */

@interface ChatController (VoiceNeeds)
- (IBAction)send:(id)sender;
- (IBAction)newChat:(id)sender;
- (void)speakWithService:(NSString *)provider voice:(NSString *)voice text:(NSString *)text sample:(BOOL)sample;
- (NSString *)voiceService;
- (NSString *)chosenEngine;
- (void)fillVoicePopup;
- (void)addVoiceLines:(NSArray *)lines selecting:(NSString *)saved;
- (void)closeVoicePanel;
- (void)sampleVoice:(id)sender;
- (void)endVoiceOK:(id)sender;
- (void)endVoiceCancel:(id)sender;
- (void)voiceSpoken:(EngineRequest *)request;
- (void)voicesArrived:(EngineRequest *)request;
- (void)voiceEngineChanged:(id)sender;
@end

static NSString *kAutoSpeak = @"TBVoiceAutoSpeak";
static NSString *kCommands = @"TBVoiceCommands";
static NSString *kVoice = @"TBVoiceName";
static NSString *kEngine = @"TBVoiceEngine";      /* absent: this Mac's voices; else the service whose voices read replies (chatgpt, gemini, grok, mistral) */

static NSString *serviceVoiceKey(NSString *provider) { return [@"TBVoiceService." stringByAppendingString:provider]; }
static NSString *consentKey(NSString *provider) { return [@"TBVoiceConsent." stringByAppendingString:provider]; }

@implementation ChatController (Voice)

- (NSSpeechSynthesizer *)synth
{
    if (!voiceSynth) {
        NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:kVoice];
        voiceSynth = [[NSSpeechSynthesizer alloc] initWithVoice:[saved length] ? saved : nil];
    }
    return voiceSynth;
}

- (BOOL)isSpeakingNow
{
    return (voiceSynth && [voiceSynth isSpeaking]) || voiceRequest || (voiceSound && [voiceSound isPlaying]);
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

/* The service whose voice reads replies, when one is chosen, has a key and was agreed to; else nil for this Mac's voice. */
- (NSString *)voiceService
{
    NSString *provider = [[NSUserDefaults standardUserDefaults] stringForKey:kEngine];
    if ([provider length] && [[TBSpeech providersWithVoices] containsObject:provider] && [self providerUsable:provider]
        && [[NSUserDefaults standardUserDefaults] boolForKey:consentKey(provider)])
        return provider;
    return nil;
}

- (void)speakText:(NSString *)text
{
    NSString *spoken = TBSpeechText(text), *provider;
    if ([spoken length] == 0)
        return;
    /* A very long reply is read in the first part only: nobody wants ten minutes of speech by accident. */
    if ([spoken length] > 4000)
        spoken = [[spoken substringToIndex:4000] stringByAppendingString:@" ... The rest of the reply is not read aloud."];
    [self stopSpeaking:nil];
    provider = [self voiceService];
    if (provider) {
        [self speakWithService:provider voice:[[NSUserDefaults standardUserDefaults] stringForKey:serviceVoiceKey(provider)] text:spoken sample:NO];
        return;
    }
    [[self synth] startSpeakingString:spoken];
}

/* The reply goes to the service as text and comes back as a WAV file, which is played once it has all arrived. */
- (void)speakWithService:(NSString *)provider voice:(NSString *)voice text:(NSString *)text sample:(BOOL)sample
{
    NSString *body = [NSString stringWithFormat:@"{\"provider\":\"%@\",\"voice\":\"%@\",\"text\":\"%@\"}", TBJSONEscape(provider), TBJSONEscape(voice ? voice : @""), TBJSONEscape(text)];
    [voiceRequest cancel];
    [voiceRequest release];
    voiceSpokenText = [text copy];
    voiceSpokenSample = sample;
    voiceRequest = [[EngineRequest send:@"POST" path:@"/v1/speak" body:body timeout:130 target:self action:@selector(voiceSpoken:) context:nil] retain];
}

- (void)voiceSpoken:(EngineRequest *)request
{
    NSSound *sound = nil;
    NSString *why;
    if (request != voiceRequest)
        return;
    [voiceRequest release];
    voiceRequest = nil;
    if ([request ok])
        sound = [[NSSound alloc] initWithData:[request data]];
    if (sound) {
        [voiceSound release];
        voiceSound = sound;
        [voiceSound play];
        [voiceSpokenText release];
        voiceSpokenText = nil;
        return;
    }
    why = [request ok] ? @"The audio could not be played." : [[request text] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSBeep();
    if (voiceSpokenSample || [voiceSpokenText length] == 0) {
        NSRunAlertPanel(@"Voice", @"%@", @"OK", nil, nil, [why length] ? why : @"The voice did not answer.");
    } else {
        /* the reply is read with this Mac's voice instead, and the first time the person is told why */
        static BOOL told = NO;
        if (!told) {
            told = YES;
            NSRunAlertPanel(@"The service's voice did not work", @"%@\n\nThis Mac's voice reads the reply instead.", @"OK", nil, nil, [why length] ? why : @"The voice did not answer.");
        }
        [[self synth] startSpeakingString:voiceSpokenText];
    }
    [voiceSpokenText release];
    voiceSpokenText = nil;
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
    [voiceRequest cancel];
    [voiceRequest release];
    voiceRequest = nil;
    [voiceSpokenText release];
    voiceSpokenText = nil;
    [voiceSound stop];
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

- (NSString *)chosenEngine { return [[voiceEnginePopup selectedItem] representedObject]; }

- (void)fillVoicePopup
{
    NSString *engine = [self chosenEngine];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *saved = engine ? [defaults stringForKey:serviceVoiceKey(engine)] : [defaults stringForKey:kVoice];
    unsigned i;
    [voicePopup removeAllItems];
    if (!engine) {
        NSArray *voices = [NSSpeechSynthesizer availableVoices];
        [voicePopup addItemWithTitle:@"System default voice"];
        for (i = 0; i < [voices count]; i++) {
            NSDictionary *info = [NSSpeechSynthesizer attributesForVoice:[voices objectAtIndex:i]];
            NSString *name = [info objectForKey:NSVoiceName];
            [voicePopup addItemWithTitle:name ? name : [voices objectAtIndex:i]];
            [[voicePopup lastItem] setRepresentedObject:[voices objectAtIndex:i]];
            if (saved && [saved isEqualToString:[voices objectAtIndex:i]])
                [voicePopup selectItem:[voicePopup lastItem]];
        }
        return;
    }
    if ([engine isEqualToString:@"mistral"]) {
        /* Mistral's voices are asked of the service */
        [voicePopup addItemWithTitle:@"Loading voices..."];
        [EngineRequest send:@"POST" path:@"/v1/voices" body:@"{\"provider\":\"mistral\"}" timeout:30 target:self action:@selector(voicesArrived:) context:engine];
        return;
    }
    [self addVoiceLines:[TBSpeech voicesForProvider:engine] selecting:saved];
}

- (void)addVoiceLines:(NSArray *)lines selecting:(NSString *)saved
{
    unsigned i;
    [voicePopup removeAllItems];
    for (i = 0; i < [lines count]; i++) {
        NSString *line = [lines objectAtIndex:i];
        NSRange bar = [line rangeOfString:@"|"];
        NSString *ident = bar.location == NSNotFound ? line : [line substringToIndex:bar.location];
        NSString *name = bar.location == NSNotFound ? line : [line substringFromIndex:bar.location + 1];
        if ([ident length] == 0)
            continue;
        [voicePopup addItemWithTitle:name];
        [[voicePopup lastItem] setRepresentedObject:ident];
        if (saved && [saved isEqualToString:ident])
            [voicePopup selectItem:[voicePopup lastItem]];
    }
}

- (void)voicesArrived:(EngineRequest *)request
{
    NSString *engine = [request context];
    NSString *text = [[request text] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!voicePanel || ![engine isEqualToString:[self chosenEngine] ? [self chosenEngine] : @""])
        return;
    if (![request ok] || [text length] == 0)
        text = @"gb_jane_neutral|Jane (neutral)";
    [self addVoiceLines:[text componentsSeparatedByString:@"\n"] selecting:[[NSUserDefaults standardUserDefaults] stringForKey:serviceVoiceKey(engine)]];
}

- (void)voiceEngineChanged:(id)sender
{
    (void)sender;
    [self fillVoicePopup];
}

- (IBAction)chooseVoice:(id)sender
{
    NSPanel *panel;
    NSPopUpButton *engines;
    NSArray *providers = [TBSpeech providersWithVoices];
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:kEngine];
    NSTextField *note;
    unsigned i;
    (void)sender;
    if (voicePanel) {
        [voicePanel makeKeyAndOrderFront:nil];
        return;
    }
    panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 420, 232) styleMask:NSTitledWindowMask | NSClosableWindowMask backing:NSBackingStoreBuffered defer:NO];
    [panel setReleasedWhenClosed:NO];
    [panel setTitle:@"Voice"];
    [panel setDelegate:self];
    engines = [[[NSPopUpButton alloc] initWithFrame:NSMakeRect(110, 188, 290, 26) pullsDown:NO] autorelease];
    [engines addItemWithTitle:@"This Mac"];
    for (i = 0; i < [providers count]; i++) {
        NSString *pid = [providers objectAtIndex:i];
        if (![self providerUsable:pid])
            continue;
        [engines addItemWithTitle:[[ModelCatalog shared] titleForProvider:pid]];
        [[engines lastItem] setRepresentedObject:pid];
        if ([saved isEqualToString:pid])
            [engines selectItem:[engines lastItem]];
    }
    [engines setTarget:self];
    [engines setAction:@selector(voiceEngineChanged:)];
    voiceEnginePopup = engines;
    voicePopup = [[[NSPopUpButton alloc] initWithFrame:NSMakeRect(110, 154, 290, 26) pullsDown:NO] autorelease];
    {
        NSTextField *l1 = [[[NSTextField alloc] initWithFrame:NSMakeRect(20, 192, 86, 18)] autorelease];
        NSTextField *l2 = [[[NSTextField alloc] initWithFrame:NSMakeRect(20, 158, 86, 18)] autorelease];
        NSButton *test = [[[NSButton alloc] initWithFrame:NSMakeRect(20, 108, 160, 28)] autorelease];
        NSButton *ok = [[[NSButton alloc] initWithFrame:NSMakeRect(320, 12, 80, 28)] autorelease];
        NSButton *cancel = [[[NSButton alloc] initWithFrame:NSMakeRect(230, 12, 80, 28)] autorelease];
        [l1 setStringValue:@"Voices from:"];
        [l2 setStringValue:@"Voice:"];
        TBStyleAsLabel(l1);
        TBStyleAsLabel(l2);
        [test setTitle:@"Hear This Voice"];
        [test setBezelStyle:NSRoundedBezelStyle];
        [test setTarget:self];
        [test setAction:@selector(sampleVoice:)];
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
        note = [[[NSTextField alloc] initWithFrame:NSMakeRect(20, 50, 380, 48)] autorelease];
        [note setStringValue:@"A service's voice sends each reply it reads to that service as text, with your key there, and plays the audio when the whole reply has arrived. This Mac's voices work offline."];
        TBStyleAsLabel(note);
        [note setFont:[NSFont systemFontOfSize:11]];
        [[note cell] setWraps:YES];
        [[panel contentView] addSubview:l1];
        [[panel contentView] addSubview:l2];
        [[panel contentView] addSubview:engines];
        [[panel contentView] addSubview:voicePopup];
        [[panel contentView] addSubview:test];
        [[panel contentView] addSubview:note];
        [[panel contentView] addSubview:ok];
        [[panel contentView] addSubview:cancel];
        [panel setDefaultButtonCell:[ok cell]];
    }
    voicePanel = panel;
    [self fillVoicePopup];
    [panel center];
    [panel makeKeyAndOrderFront:nil];
}

- (void)closeVoicePanel
{
    [voiceSample stopSpeaking];
    [voicePanel orderOut:nil];
    [voicePanel release];
    voicePanel = nil;
    voicePopup = nil;
    voiceEnginePopup = nil;
}

- (BOOL)windowShouldClose:(id)closing
{
    if (closing == voicePanel) {
        [self closeVoicePanel];
        return NO;
    }
    return YES;
}

- (void)sampleVoice:(id)sender
{
    NSString *engine = [self chosenEngine];
    NSString *chosen = [[voicePopup selectedItem] representedObject];
    (void)sender;
    [self stopSpeaking:nil];
    [voiceSample stopSpeaking];
    if (engine) {
        [self speakWithService:engine voice:chosen text:@"This is how replies will sound." sample:YES];
        return;
    }
    {
        NSSpeechSynthesizer *sample = [[[NSSpeechSynthesizer alloc] initWithVoice:chosen] autorelease];
        [voiceSample release];
        voiceSample = [sample retain];
        [voiceSample startSpeakingString:@"This is how replies will sound."];
    }
}

- (void)endVoiceOK:(id)sender
{
    NSString *engine = [self chosenEngine];
    NSString *chosen = [[voicePopup selectedItem] representedObject];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    (void)sender;
    if (engine && ![defaults boolForKey:consentKey(engine)]) {
        NSString *title = [[ModelCatalog shared] titleForProvider:engine];
        if (NSRunAlertPanel([NSString stringWithFormat:@"Read replies aloud with %@'s voice?", title],
            @"Each reply that is read aloud is sent to %@ as text, using your key there, and may be billed by them. Replies are never sent unless a voice from a service is chosen here.",
            @"Use This Voice", @"Cancel", nil, title) != NSAlertDefaultReturn)
            return;
        [defaults setBool:YES forKey:consentKey(engine)];
    }
    if (engine) {
        [defaults setObject:engine forKey:kEngine];
        if (chosen)
            [defaults setObject:chosen forKey:serviceVoiceKey(engine)];
    } else {
        [defaults removeObjectForKey:kEngine];
        if (chosen)
            [defaults setObject:chosen forKey:kVoice];
        else
            [defaults removeObjectForKey:kVoice];
        [voiceSynth release];
        voiceSynth = nil;
    }
    [defaults synchronize];
    [self stopSpeaking:nil];
    [self closeVoicePanel];
}

- (void)endVoiceCancel:(id)sender
{
    (void)sender;
    [self stopSpeaking:nil];
    [self closeVoicePanel];
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
