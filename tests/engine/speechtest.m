/* Dictation against mock_services.py: speechtest PORT [HOST]   from tiger-build/ */
#import <Foundation/Foundation.h>
#import "TBSpeech.h"
#import "TBEngine.h"
#import "expect.h"


int main(int argc, char **argv)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *base = [NSString stringWithFormat:@"http://%s:%s", argc > 2 ? argv[2] : "127.0.0.1", argv[1]];
    NSMutableData *wav = [NSMutableData dataWithBytes:"RIFF\0\0\0\0WAVE" length:12];
    int status = 0;
    NSString *problem = nil, *words;
    [wav increaseLengthBy:200];
    [d setObject:[base stringByAppendingString:@"/audio-openai"] forKey:@"TBSpeechURL.openai"];
    [d setObject:[base stringByAppendingString:@"/audio-gemini"] forKey:@"TBSpeechURL.gemini"];
    setenv("TB_OPENAI_API_KEY", "", 1);
    setenv("TB_MISTRAL_API_KEY", "", 1);
    setenv("TB_GEMINI_API_KEY", "", 1);
    words = [TBSpeech transcribe:wav language:@"" status:&status problem:&problem];
    expectThat(!words && status == 424, @"no key gives 424");
    words = [TBSpeech transcribe:[NSData dataWithBytes:"hello" length:5] language:@"" status:&status problem:&problem];
    expectThat(!words && status == 422, @"not a WAV gives 422");
    setenv("TB_OPENAI_API_KEY", "sk-test", 1);
    words = [TBSpeech transcribe:wav language:@"en" status:&status problem:&problem];
    if (!words)
        fprintf(stderr, "%s\n", [problem UTF8String]);
    expectThat([words isEqualToString:@"hello from the mock"], @"openai falls back to the next model and trims");
    setenv("TB_OPENAI_API_KEY", "", 1);
    setenv("TB_GEMINI_API_KEY", "g-test", 1);
    words = [TBSpeech transcribe:wav language:@"" status:&status problem:&problem];
    expectThat([words isEqualToString:@"gemini words"], @"gemini");
    /* speaking */
    {
        NSData *wavOut;
        NSArray *voices;
        const unsigned char *b;
        [d setObject:[base stringByAppendingString:@"/tts-openai"] forKey:@"TBSpeechURL.openai-tts"];
        [d setObject:[base stringByAppendingString:@"/tts-gemini"] forKey:@"TBSpeechURL.gemini-tts"];
        [d setObject:[base stringByAppendingString:@"/tts-grok"] forKey:@"TBSpeechURL.grok-tts"];
        [d setObject:[base stringByAppendingString:@"/tts-mistral"] forKey:@"TBSpeechURL.mistral-tts"];
        [d setObject:[base stringByAppendingString:@"/tts-mistral-voices"] forKey:@"TBSpeechURL.mistral-voices"];
        setenv("TB_OPENAI_API_KEY", "", 1);
        setenv("TB_GEMINI_API_KEY", "", 1);
        wavOut = [TBSpeech speak:@"Hello there." provider:@"chatgpt" voice:@"coral" status:&status problem:&problem];
        expectThat(!wavOut && status == 424, @"speak: no key gives 424");
        wavOut = [TBSpeech speak:@"Hello there." provider:@"claude" voice:@"" status:&status problem:&problem];
        expectThat(!wavOut && status == 422, @"speak: a service without voices gives 422");
        setenv("TB_OPENAI_API_KEY", "sk-test", 1);
        wavOut = [TBSpeech speak:@"Hello there." provider:@"chatgpt" voice:@"coral" status:&status problem:&problem];
        b = [wavOut bytes];
        expectThat([wavOut length] == 4844 && !memcmp(b, "RIFF", 4) && !memcmp(b + 8, "WAVE", 4) && b[24] == 0xc0 && b[25] == 0x5d, @"speak openai: falls back to the next model, PCM wrapped as 24 kHz WAV");
        setenv("TB_GEMINI_API_KEY", "g-test", 1);
        wavOut = [TBSpeech speak:@"Hello there." provider:@"gemini" voice:@"Puck" status:&status problem:&problem];
        expectThat([wavOut length] == 4844, @"speak gemini: inline PCM wrapped as WAV");
        setenv("TB_XAI_API_KEY", "x-test", 1);
        wavOut = [TBSpeech speak:@"Hello there." provider:@"grok" voice:@"rex" status:&status problem:&problem];
        expectThat([wavOut length] == 4844, @"speak grok: voice, pcm codec");
        setenv("TB_MISTRAL_API_KEY", "m-test", 1);
        wavOut = [TBSpeech speak:@"Hello there." provider:@"mistral" voice:@"" status:&status problem:&problem];
        expectThat([wavOut length] == 56 && !memcmp([wavOut bytes], "RIFF", 4), @"speak mistral: default voice, base64 WAV");
        voices = [TBSpeech voicesForProvider:@"mistral"];
        expectThat([voices count] == 2 && [[voices objectAtIndex:0] isEqualToString:@"gb_jane_neutral|Jane"] && [[voices objectAtIndex:1] isEqualToString:@"def456|Max"], @"voices: Mistral's list from the service");
        expectThat([[TBSpeech voicesForProvider:@"gemini"] count] == 30 && [[TBSpeech voicesForProvider:@"chatgpt"] count] == 13, @"voices: fixed lists");
    }
    [pool release];
    return failures ? 1 : 0;
}
