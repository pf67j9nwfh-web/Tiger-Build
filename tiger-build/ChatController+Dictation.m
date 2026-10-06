#import "ChatController_Private.h"
#import <CoreAudio/CoreAudio.h>

/* Dictation: record from the Mac's microphone, send the clip to a speech service, and put the words in the message box.
   Optional and off the path of everything else: it runs only when Chat > Voice > Dictate is chosen.

   Recording uses Core Audio's hardware layer, which Tiger through Snow Leopard all have, in 32 and 64 bits. The sound
   is mixed to one channel and reduced to about 16,000 samples a second, so a minute is under 2 MB, then sent as a WAV
   file. It is turned into text with whichever speech service has a key (OpenAI, Mistral or Google). */

#define DICTATION_MAX_SECONDS 90
#define DICTATION_RATE 16000

static NSString *kDictationSend = @"TBDictationSend";

/* What the microphone callback writes into. The callback runs on Core Audio's own thread; the main thread reads this
   only after the device has been stopped, so no locks are needed. */
typedef struct {
    short *samples;
    unsigned long capacity;
    unsigned long count;
    int decimate;
    int channelsSeen;
    double sum;
    int summed;
    float peak;
    volatile int full;
} DictationBuffer;

static DictationBuffer dictation;

static OSStatus dictationProc(AudioDeviceID device, const AudioTimeStamp *now, const AudioBufferList *input,
    const AudioTimeStamp *inputTime, AudioBufferList *output, const AudioTimeStamp *outputTime, void *client)
{
    UInt32 b;
    UInt32 frames = 0;
    UInt32 f;
    (void)device;
    (void)now;
    (void)inputTime;
    (void)output;
    (void)outputTime;
    (void)client;
    if (!input || input->mNumberBuffers == 0 || !dictation.samples || dictation.full)
        return 0;
    for (b = 0; b < input->mNumberBuffers; b++) {
        UInt32 channels = input->mBuffers[b].mNumberChannels ? input->mBuffers[b].mNumberChannels : 1;
        UInt32 have = input->mBuffers[b].mDataByteSize / (sizeof(float) * channels);
        if (b == 0 || have < frames)
            frames = have;
    }
    for (f = 0; f < frames; f++) {
        float mixed = 0;
        int used = 0;
        for (b = 0; b < input->mNumberBuffers; b++) {
            const float *data = (const float *)input->mBuffers[b].mData;
            UInt32 channels = input->mBuffers[b].mNumberChannels ? input->mBuffers[b].mNumberChannels : 1;
            UInt32 c;
            for (c = 0; c < channels; c++) {
                mixed += data[f * channels + c];
                used++;
            }
        }
        if (used > 0)
            mixed /= used;
        dictation.sum += mixed;
        dictation.summed++;
        if (dictation.summed >= dictation.decimate) {
            float value = (float)(dictation.sum / dictation.summed);
            float magnitude = value < 0 ? -value : value;
            long scaled;
            if (magnitude > dictation.peak)
                dictation.peak = magnitude;
            scaled = (long)(value * 32767.0f * 2.0f);
            if (scaled > 32767)
                scaled = 32767;
            if (scaled < -32768)
                scaled = -32768;
            if (dictation.count < dictation.capacity)
                dictation.samples[dictation.count++] = (short)scaled;
            else
                dictation.full = 1;
            dictation.sum = 0;
            dictation.summed = 0;
        }
    }
    return 0;
}

/* A WAV file holds little-endian numbers, whatever the Mac's own byte order is. */
static void appendLE(NSMutableData *data, unsigned long value, int bytes)
{
    unsigned char out[4];
    int i;
    for (i = 0; i < bytes; i++)
        out[i] = (unsigned char)((value >> (8 * i)) & 0xFF);
    [data appendBytes:out length:bytes];
}

static NSData *wavFromSamples(const short *samples, unsigned long count, unsigned long rate)
{
    NSMutableData *wav = [NSMutableData dataWithCapacity:44 + count * 2];
    unsigned long i;
    unsigned long bytes = count * 2;
    [wav appendBytes:"RIFF" length:4];
    appendLE(wav, 36 + bytes, 4);
    [wav appendBytes:"WAVEfmt " length:8];
    appendLE(wav, 16, 4);
    appendLE(wav, 1, 2);
    appendLE(wav, 1, 2);
    appendLE(wav, rate, 4);
    appendLE(wav, rate * 2, 4);
    appendLE(wav, 2, 2);
    appendLE(wav, 16, 2);
    [wav appendBytes:"data" length:4];
    appendLE(wav, bytes, 4);
    for (i = 0; i < count; i++)
        appendLE(wav, (unsigned long)((unsigned short)samples[i]), 2);
    return wav;
}

@interface ChatController (DictationNeeds)
- (IBAction)send:(id)sender;
@end

@implementation ChatController (Dictation)

- (BOOL)isDictating
{
    return dictationDevice != 0;
}

- (void)showDictationStatus:(NSString *)text
{
    if (!dictationSaved)
        dictationSaved = [[relayStatusField stringValue] copy];
    [relayStatusField setStringValue:text];
    [relayStatusField setToolTip:nil];
    [relayStatusField setTextColor:[NSColor colorWithCalibratedWhite:0.25 alpha:1]];
    [self relayStatusChanged];
}

- (void)clearDictationStatus
{
    /* Put back whatever the status line said before (a relay problem, or nothing). */
    NSString *before = dictationSaved ? [dictationSaved autorelease] : @"";
    dictationSaved = nil;
    [self setRelayProblem:[before length] > 0 && !relayReachable ? before : nil];
}

- (IBAction)toggleDictation:(id)sender
{
    (void)sender;
    if ([self isDictating])
        [self finishDictation:YES];
    else
        [self beginDictation];
}

- (void)beginDictation
{
    AudioDeviceID device = 0;
    UInt32 size = sizeof(device);
    AudioStreamBasicDescription format;
    UInt32 formatSize = sizeof(format);
    OSStatus status;
    if (!current)
        return;
    if (!TBConfirmOnce(@"dictation", @"Send recordings to a speech service?",
        @"The clip goes to a speech service (OpenAI, Mistral or Google) to turn it into text. "
        @"It is not kept. Say only what you are happy to share.", @"Dictate"))
        return;
    status = AudioHardwareGetProperty(kAudioHardwarePropertyDefaultInputDevice, &size, &device);
    if (status != 0 || device == kAudioDeviceUnknown) {
        NSRunAlertPanel(@"Dictation", @"This Mac has no sound input. Plug in a microphone, or choose one in System Preferences, Sound, Input.", @"OK", nil, nil);
        return;
    }
    memset(&format, 0, sizeof(format));
    status = AudioDeviceGetProperty(device, 0, true, kAudioDevicePropertyStreamFormat, &formatSize, &format);
    if (status != 0 || format.mSampleRate < 8000 || !(format.mFormatFlags & kAudioFormatFlagIsFloat) || format.mBitsPerChannel != 32) {
        NSRunAlertPanel(@"Dictation", @"This Mac's sound input uses a format Tiger Build cannot read. Choose another input in System Preferences, Sound, Input.", @"OK", nil, nil);
        return;
    }
    [self stopSpeaking:nil];
    memset(&dictation, 0, sizeof(dictation));
    dictation.decimate = (int)(format.mSampleRate / DICTATION_RATE + 0.5);
    if (dictation.decimate < 1)
        dictation.decimate = 1;
    dictationRate = (unsigned long)(format.mSampleRate / dictation.decimate);
    dictation.capacity = (unsigned long)DICTATION_MAX_SECONDS * dictationRate;
    dictation.samples = (short *)malloc(dictation.capacity * sizeof(short));
    if (!dictation.samples) {
        NSBeep();
        return;
    }
    status = AudioDeviceAddIOProc(device, dictationProc, NULL);
    if (status == 0)
        status = AudioDeviceStart(device, dictationProc);
    if (status != 0) {
        AudioDeviceRemoveIOProc(device, dictationProc);
        free(dictation.samples);
        dictation.samples = NULL;
        NSRunAlertPanel(@"Dictation", @"The microphone could not be started (error %d). Another program may be using it.", @"OK", nil, nil, (int)status);
        return;
    }
    dictationDevice = device;
    dictationStarted = CFAbsoluteTimeGetCurrent();
    [self updateDictationClock:nil];
    [dictationTimer invalidate];
    dictationTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(updateDictationClock:) userInfo:nil repeats:YES];
}

- (void)updateDictationClock:(NSTimer *)timer
{
    int seconds = (int)(CFAbsoluteTimeGetCurrent() - dictationStarted);
    (void)timer;
    if (![self isDictating])
        return;
    if (dictation.full || seconds >= DICTATION_MAX_SECONDS) {
        [self finishDictation:YES];
        return;
    }
    [self showDictationStatus:[NSString stringWithFormat:@"Recording %d:%02d. Choose Dictate again (or press Command-Option-R) to stop; Command-period cancels.",
        seconds / 60, seconds % 60]];
}

/* Stop the microphone. With `keep`, the clip is sent; without it, it is thrown away. */
- (void)finishDictation:(BOOL)keep
{
    NSData *wav = nil;
    float peak;
    unsigned long count;
    if (![self isDictating])
        return;
    AudioDeviceStop(dictationDevice, dictationProc);
    AudioDeviceRemoveIOProc(dictationDevice, dictationProc);
    dictationDevice = 0;
    [dictationTimer invalidate];
    dictationTimer = nil;
    peak = dictation.peak;
    count = dictation.count;
    if (keep && count > dictationRate / 4)
        wav = wavFromSamples(dictation.samples, count, dictationRate);
    free(dictation.samples);
    dictation.samples = NULL;
    if (!keep) {
        [self clearDictationStatus];
        return;
    }
    if (!wav) {
        [self clearDictationStatus];
        NSBeep();
        return;
    }
    if (peak < 0.002f) {
        [self clearDictationStatus];
        NSRunAlertPanel(@"Dictation", @"Nothing was heard. Check that the microphone is plugged in, not muted, and chosen in System Preferences, Sound, Input.", @"OK", nil, nil);
        return;
    }
    [self showDictationStatus:@"Turning your speech into text..."];
    dictationRequest = [EngineRequest sendFile:wav name:@"speech.wav" path:@"/v1/transcribe" timeout:120 target:self
        action:@selector(dictationArrived:) context:nil];
}

- (void)dictationArrived:(EngineRequest *)request
{
    NSString *text = [[request text] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSText *editor;
    NSString *existing;
    dictationRequest = nil;
    [self clearDictationStatus];
    if (![request ok]) {
        NSString *why = text;
        if ([request status] == 0)
            why = [request timedOut] ? @"It took too long." : @"The speech service could not be reached.";
        NSRunAlertPanel(@"Dictation", @"%@", @"OK", nil, nil, [why length] ? why : @"The speech could not be turned into text.");
        return;
    }
    if ([text length] == 0) {
        NSRunAlertPanel(@"Dictation", @"No words were found in the recording.", @"OK", nil, nil);
        return;
    }
    editor = [input currentEditor];
    existing = editor ? [editor string] : [input stringValue];
    if ([existing length] > 0 && ![existing hasSuffix:@" "])
        text = [@" " stringByAppendingString:text];
    text = [existing stringByAppendingString:text];
    [input setStringValue:text];
    if (editor)
        [editor setString:text];
    [self layoutPanes];
    [window makeFirstResponder:input];
    [[input currentEditor] setSelectedRange:NSMakeRange([text length], 0)];
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kDictationSend] && !busy)
        [self send:nil];
}

/* Command-period (Stop) while recording or transcribing throws the clip away. */
- (BOOL)cancelDictation
{
    if ([self isDictating]) {
        [self finishDictation:NO];
        return YES;
    }
    if (dictationRequest) {
        [dictationRequest cancel];
        dictationRequest = nil;
        [self clearDictationStatus];
        return YES;
    }
    return NO;
}

- (BOOL)dictationRunning
{
    return [self isDictating] || dictationRequest != nil;
}

- (IBAction)toggleDictationSend:(id)sender
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    (void)sender;
    [defaults setBool:![defaults boolForKey:kDictationSend] forKey:kDictationSend];
    [defaults synchronize];
}

@end
