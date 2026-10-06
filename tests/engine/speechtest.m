/* Dictation against mock_services.py: speechtest PORT [HOST]   from tiger-build/ */
#import <Foundation/Foundation.h>
#import "TBSpeech.h"
#import "TBEngine.h"

static int failures = 0;
static void expectThat(BOOL ok, NSString *name)
{
    fprintf(stderr, "%s %s\n", ok ? "PASS" : "FAIL", [name UTF8String]);
    if (!ok)
        failures++;
}

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
    [pool release];
    return failures ? 1 : 0;
}
