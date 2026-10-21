#import <Foundation/Foundation.h>

/* Speech to text for dictation: a short WAV clip goes to whichever service has a key (OpenAI, Mistral, then Google). */
@interface TBSpeech : NSObject
/* The words, or nil with *problem set. *status is the HTTP status to report (422 bad clip, 424 no key, 502 service failed). */
+ (NSString *)transcribe:(NSData *)wav language:(NSString *)language status:(int *)status problem:(NSString **)problem;

/* Text to speech with a service's own voices. provider: chatgpt, gemini, grok or mistral. Returns a WAV file, or nil with *problem set
   (*status as above: 424 no key, 502 service failed). The text is read as it is: 4000 characters at most. */
+ (NSData *)speak:(NSString *)text provider:(NSString *)provider voice:(NSString *)voice status:(int *)status problem:(NSString **)problem;
/* The voices to choose from: lines "id" or "id|name". Mistral's come from the service when it can be asked, the others are fixed lists. */
+ (NSArray *)voicesForProvider:(NSString *)provider;
+ (NSArray *)providersWithVoices;     /* chatgpt, gemini, grok, mistral */
+ (NSData *)wavFromPCM:(NSData *)pcm sampleRate:(int)rate;   /* 16-bit mono */
@end
