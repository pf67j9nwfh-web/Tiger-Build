#import "TBSpeech.h"
#import "TBEngine.h"
#import "TBHTTP.h"
#import "TBJSON.h"
#import "TBSupport.h"

#define MAX_BYTES (30 * 1024 * 1024)

static NSString *address(NSString *provider, NSString *standard)
{
    NSString *over = [[NSUserDefaults standardUserDefaults] stringForKey:[@"TBSpeechURL." stringByAppendingString:provider]];
    return [over length] ? over : standard;
}

/* One request; the status comes back in *status (0 when the service could not be reached) with the text in *text. */
static void post(NSString *url, NSData *body, NSArray *headers, int *status, NSString **text)
{
    TBHTTP *http = [TBHTTP request:@"POST" url:url];
    unsigned i;
    int result;
    for (i = 0; i + 1 < [headers count]; i += 2)
        [http setHeader:[headers objectAtIndex:i] value:[headers objectAtIndex:i + 1]];
    [http setBody:body];
    [http setIdleTimeout:120];
    result = [http perform];
    *status = result == TBNET_OK ? [http status] : 0;
    *text = result == TBNET_OK ? [http text] : [http error];
}

static NSData *multipart(NSArray *fields, NSData *wav, NSString *boundary)
{
    NSMutableData *out = [NSMutableData data];
    unsigned i;
    for (i = 0; i + 1 < [fields count]; i += 2)
        [out appendData:[[NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"%@\"\r\n\r\n%@\r\n", boundary, [fields objectAtIndex:i], [fields objectAtIndex:i + 1]] dataUsingEncoding:NSUTF8StringEncoding]];
    [out appendData:[[NSString stringWithFormat:@"--%@\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    [out appendData:wav];
    [out appendData:[[NSString stringWithFormat:@"\r\n--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    return out;
}

static NSString *failure(int status, NSString *text)
{
    if (status == 0)
        return text;
    return [NSString stringWithFormat:@"HTTP %d: %@", status, [text length] > 300 ? [text substringToIndex:300] : text];
}

/* OpenAI and Mistral take a multipart upload; the first model id the service accepts is used. */
static NSString *uploadService(NSString *url, NSString *key, NSArray *models, NSData *wav, NSString *language, NSString **problem)
{
    unsigned i;
    NSString *last = @"no answer";
    for (i = 0; i < [models count]; i++) {
        NSMutableArray *fields = [NSMutableArray arrayWithObjects:@"model", [models objectAtIndex:i], @"response_format", @"json", nil];
        NSString *boundary = [NSString stringWithFormat:@"----tigerbuild%08x%08x", (unsigned)random(), (unsigned)random()];
        int status;
        NSString *text;
        if ([language length]) {
            [fields addObject:@"language"];
            [fields addObject:language];
        }
        post(url, multipart(fields, wav, boundary), [NSArray arrayWithObjects:@"Authorization", [@"Bearer " stringByAppendingString:key],
            @"Content-Type", [@"multipart/form-data; boundary=" stringByAppendingString:boundary], nil], &status, &text);
        if (status >= 200 && status < 300) {
            id json = TBJSONParse([text dataUsingEncoding:NSUTF8StringEncoding], NULL);
            NSString *words = TBString(json, @"text");
            if (TBValue(json, @"text") && [TBValue(json, @"text") isKindOfClass:[NSString class]])
                return TBTrim(words);
            last = @"no text in the answer";
            continue;
        }
        last = failure(status, text);
        if (status == 400 || status == 404)
            continue;
        break;
    }
    *problem = last;
    return nil;
}

static NSString *geminiService(NSString *key, NSData *wav, NSString **problem)
{
    NSArray *models = [NSArray arrayWithObjects:@"gemini-3.8-flash", @"gemini-2.5-flash", nil];
    NSString *last = @"no answer";
    unsigned i;
    for (i = 0; i < [models count]; i++) {
        NSString *url = address(@"gemini", [NSString stringWithFormat:@"https://generativelanguage.googleapis.com/v1beta/models/%@:generateContent", [models objectAtIndex:i]]);
        NSDictionary *part1 = [NSDictionary dictionaryWithObject:@"Transcribe this speech exactly as spoken. Reply with only the words, no commentary." forKey:@"text"];
        NSDictionary *part2 = [NSDictionary dictionaryWithObject:[NSDictionary dictionaryWithObjectsAndKeys:@"audio/wav", @"mime_type", TBBase64(wav), @"data", nil] forKey:@"inline_data"];
        NSDictionary *payload = [NSDictionary dictionaryWithObject:[NSArray arrayWithObject:[NSDictionary dictionaryWithObject:[NSArray arrayWithObjects:part1, part2, nil] forKey:@"parts"]] forKey:@"contents"];
        int status;
        NSString *text;
        post(url, TBJSONData(payload), [NSArray arrayWithObjects:@"Content-Type", @"application/json", @"x-goog-api-key", key, nil], &status, &text);
        if (status >= 200 && status < 300) {
            id json = TBJSONParse([text dataUsingEncoding:NSUTF8StringEncoding], NULL);
            NSArray *candidates = TBArray(json, @"candidates");
            NSArray *parts = [candidates count] ? TBArray(TBDictionary([candidates objectAtIndex:0], @"content"), @"parts") : nil;
            NSMutableString *words = [NSMutableString string];
            unsigned p;
            for (p = 0; p < [parts count]; p++)
                [words appendString:TBString([parts objectAtIndex:p], @"text")];
            if ([words length])
                return TBTrim(words);
            last = @"Gemini returned no text";
            continue;
        }
        last = failure(status, text);
        if (status == 400 || status == 404)
            continue;
        break;
    }
    *problem = last;
    return nil;
}

@implementation TBSpeech

+ (NSString *)transcribe:(NSData *)wav language:(NSString *)language status:(int *)status problem:(NSString **)problem
{
    const unsigned char *b = [wav bytes];
    NSMutableArray *problems = [NSMutableArray array];
    NSString *openai = [TBSettings keyForProvider:@"chatgpt"], *mistral = [TBSettings keyForProvider:@"mistral"], *gemini = [TBSettings keyForProvider:@"gemini"];
    NSString *words, *why = nil;
    if ([wav length] < 12 || memcmp(b, "RIFF", 4) || memcmp(b + 8, "WAVE", 4)) {
        *status = 422;
        *problem = @"The recording is not a WAV file.";
        return nil;
    }
    if ([wav length] > MAX_BYTES) {
        *status = 422;
        *problem = @"The recording is longer than can be transcribed.";
        return nil;
    }
    if (![openai length] && ![mistral length] && ![gemini length]) {
        *status = 424;
        *problem = @"Speech to text needs an OpenAI, Mistral or Google key. Add one in Preferences.";
        return nil;
    }
    if ([openai length]) {
        words = uploadService(address(@"openai", @"https://api.openai.com/v1/audio/transcriptions"), openai,
            [NSArray arrayWithObjects:@"gpt-4o-mini-transcribe", @"gpt-4o-transcribe", @"whisper-1", nil], wav, language, &why);
        if (words)
            return words;
        [problems addObject:[@"openai: " stringByAppendingString:why]];
    }
    if ([mistral length]) {
        words = uploadService(address(@"mistral", @"https://api.mistral.ai/v1/audio/transcriptions"), mistral,
            [NSArray arrayWithObject:@"voxtral-mini-latest"], wav, language, &why);
        if (words)
            return words;
        [problems addObject:[@"mistral: " stringByAppendingString:why]];
    }
    if ([gemini length]) {
        words = geminiService(gemini, wav, &why);
        if (words)
            return words;
        [problems addObject:[@"gemini: " stringByAppendingString:why]];
    }
    *status = 502;
    *problem = [NSString stringWithFormat:@"Could not transcribe: %@", [problems componentsJoinedByString:@"; "]];
    return nil;
}

@end
