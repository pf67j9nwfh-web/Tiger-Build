#import <Foundation/Foundation.h>

/* Speech to text for dictation: a short WAV clip goes to whichever service has a key (OpenAI, Mistral, then Google). */
@interface TBSpeech : NSObject
/* The words, or nil with *problem set. *status is the HTTP status to report (422 bad clip, 424 no key, 502 service failed). */
+ (NSString *)transcribe:(NSData *)wav language:(NSString *)language status:(int *)status problem:(NSString **)problem;
@end
