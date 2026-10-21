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
        NSString *boundary = [NSString stringWithFormat:@"----tigerbuild%08x%08x", (unsigned)arc4random(), (unsigned)arc4random()];
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

/* ---- speaking ---- */

static const int kSpeechRate = 24000;

static NSString *kGeminiVoices[] = {@"Kore", @"Puck", @"Zephyr", @"Charon", @"Fenrir", @"Leda", @"Orus", @"Aoede", @"Callirrhoe", @"Autonoe", @"Enceladus", @"Iapetus", @"Umbriel",
    @"Algieba", @"Despina", @"Erinome", @"Algenib", @"Rasalgethi", @"Laomedeia", @"Achernar", @"Alnilam", @"Schedar", @"Gacrux", @"Pulcherrima", @"Achird", @"Zubenelgenubi",
    @"Vindemiatrix", @"Sadachbia", @"Sadaltager", @"Sulafat", nil};

/* a request that returns the audio itself; *audio is the body */
static void postForData(NSString *url, NSData *body, NSArray *headers, int *status, NSData **audio, NSString **text)
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
    *audio = result == TBNET_OK ? [http data] : nil;
    *text = result == TBNET_OK ? [http text] : [http error];
}

static NSData *jsonBody(NSDictionary *dictionary) { return TBJSONData(dictionary); }

/* A WAV file's PCM, when it is plain 16-bit; otherwise nil */
static BOOL isWAV(NSData *data)
{
    const unsigned char *b = [data bytes];
    return [data length] > 44 && !memcmp(b, "RIFF", 4) && !memcmp(b + 8, "WAVE", 4);
}

static NSData *openaiSpeech(NSString *text, NSString *voice, NSString *key, int *status, NSString **problem)
{
    NSArray *models = [NSArray arrayWithObjects:@"gpt-4o-mini-tts", @"tts-1", nil];
    NSString *url = address(@"openai-tts", @"https://api.openai.com/v1/audio/speech");
    unsigned i;
    *problem = @"no answer";
    for (i = 0; i < [models count]; i++) {
        NSData *audio;
        NSString *answer;
        int code;
        postForData(url, jsonBody([NSDictionary dictionaryWithObjectsAndKeys:[models objectAtIndex:i], @"model", text, @"input", [voice length] ? voice : @"alloy", @"voice", @"pcm", @"response_format", nil]),
            [NSArray arrayWithObjects:@"Authorization", [@"Bearer " stringByAppendingString:key], @"Content-Type", @"application/json", nil], &code, &audio, &answer);
        if (code >= 200 && code < 300 && [audio length] > 200)
            return [TBSpeech wavFromPCM:audio sampleRate:kSpeechRate];
        *problem = failure(code, answer);
        *status = 502;
        if (code != 400 && code != 404)
            break;
    }
    return nil;
}

static NSData *geminiSpeech(NSString *text, NSString *voice, NSString *key, int *status, NSString **problem)
{
    NSArray *models = [NSArray arrayWithObjects:@"gemini-3.1-flash-tts-preview", @"gemini-2.5-flash-preview-tts", nil];
    unsigned i;
    *problem = @"no answer";
    for (i = 0; i < [models count]; i++) {
        NSString *url = address(@"gemini-tts", [NSString stringWithFormat:@"https://generativelanguage.googleapis.com/v1beta/models/%@:generateContent", [models objectAtIndex:i]]);
        NSDictionary *speech = [NSDictionary dictionaryWithObject:[NSDictionary dictionaryWithObject:[NSDictionary dictionaryWithObject:[voice length] ? voice : @"Kore" forKey:@"voiceName"] forKey:@"prebuiltVoiceConfig"] forKey:@"voiceConfig"];
        NSDictionary *payload = [NSDictionary dictionaryWithObjectsAndKeys:
            [NSArray arrayWithObject:[NSDictionary dictionaryWithObject:[NSArray arrayWithObject:[NSDictionary dictionaryWithObject:text forKey:@"text"]] forKey:@"parts"]], @"contents",
            [NSDictionary dictionaryWithObjectsAndKeys:[NSArray arrayWithObject:@"AUDIO"], @"responseModalities", speech, @"speechConfig", nil], @"generationConfig", nil];
        NSData *audio;
        NSString *answer;
        int code;
        postForData(url, jsonBody(payload), [NSArray arrayWithObjects:@"Content-Type", @"application/json", @"x-goog-api-key", key, nil], &code, &audio, &answer);
        if (code >= 200 && code < 300) {
            id json = TBJSONParse([answer dataUsingEncoding:NSUTF8StringEncoding], NULL);
            NSArray *candidates = TBArray(json, @"candidates");
            NSArray *parts = [candidates count] ? TBArray(TBDictionary([candidates objectAtIndex:0], @"content"), @"parts") : nil;
            NSMutableData *pcm = [NSMutableData data];
            unsigned p;
            for (p = 0; p < [parts count]; p++) {
                NSDictionary *inline_ = TBDictionary([parts objectAtIndex:p], @"inlineData");
                NSData *chunk;
                if (!inline_)
                    inline_ = TBDictionary([parts objectAtIndex:p], @"inline_data");
                chunk = TBBase64Decode(TBString(inline_, @"data"));
                if (chunk)
                    [pcm appendData:chunk];
            }
            if ([pcm length] > 200)
                return [TBSpeech wavFromPCM:pcm sampleRate:kSpeechRate];
            *problem = @"Gemini returned no audio";
            *status = 502;
            continue;
        }
        *problem = failure(code, answer);
        *status = 502;
        if (code != 400 && code != 404)
            break;
    }
    return nil;
}

static NSData *grokSpeech(NSString *text, NSString *voice, NSString *key, int *status, NSString **problem)
{
    NSString *url = address(@"grok-tts", @"https://api.x.ai/v1/tts");
    NSData *audio;
    NSString *answer;
    int code;
    postForData(url, jsonBody([NSDictionary dictionaryWithObjectsAndKeys:text, @"text", [voice length] ? voice : @"eve", @"voice_id", @"auto", @"language",
        [NSDictionary dictionaryWithObjectsAndKeys:@"pcm", @"codec", [NSNumber numberWithInt:kSpeechRate], @"sample_rate", nil], @"output_format", nil]),
        [NSArray arrayWithObjects:@"Authorization", [@"Bearer " stringByAppendingString:key], @"Content-Type", @"application/json", nil], &code, &audio, &answer);
    if (code >= 200 && code < 300 && [audio length] > 200)
        return [TBSpeech wavFromPCM:audio sampleRate:kSpeechRate];
    *problem = failure(code, answer);
    *status = 502;
    return nil;
}

static NSData *mistralSpeech(NSString *text, NSString *voice, NSString *key, int *status, NSString **problem)
{
    NSArray *models = [NSArray arrayWithObjects:@"voxtral-mini-tts-3-0", @"voxtral-mini-tts-latest", nil];
    NSString *url = address(@"mistral-tts", @"https://api.mistral.ai/v1/audio/speech");
    unsigned i;
    *problem = @"no answer";
    for (i = 0; i < [models count]; i++) {
        NSData *audio;
        NSString *answer;
        int code;
        postForData(url, jsonBody([NSDictionary dictionaryWithObjectsAndKeys:[models objectAtIndex:i], @"model", text, @"input", [voice length] ? voice : @"gb_jane_neutral", @"voice_id", @"wav", @"response_format", nil]),
            [NSArray arrayWithObjects:@"Authorization", [@"Bearer " stringByAppendingString:key], @"Content-Type", @"application/json", nil], &code, &audio, &answer);
        if (code >= 200 && code < 300) {
            NSData *wav = TBBase64Decode(TBString(TBJSONParse([answer dataUsingEncoding:NSUTF8StringEncoding], NULL), @"audio_data"));
            if (isWAV(wav))
                return wav;
            *problem = @"Mistral returned no audio";
            *status = 502;
            continue;
        }
        *problem = failure(code, answer);
        *status = 502;
        if (code != 400 && code != 404)
            break;
    }
    return nil;
}

@implementation TBSpeech

+ (NSData *)wavFromPCM:(NSData *)pcm sampleRate:(int)rate
{
    NSMutableData *out = [NSMutableData dataWithCapacity:[pcm length] + 44];
    unsigned char header[44];
    unsigned length = (unsigned)[pcm length], byteRate = (unsigned)rate * 2;
    memcpy(header, "RIFF", 4);
    header[4] = (36 + length) & 255; header[5] = ((36 + length) >> 8) & 255; header[6] = ((36 + length) >> 16) & 255; header[7] = ((36 + length) >> 24) & 255;
    memcpy(header + 8, "WAVEfmt ", 8);
    header[16] = 16; header[17] = 0; header[18] = 0; header[19] = 0;
    header[20] = 1; header[21] = 0;       /* PCM */
    header[22] = 1; header[23] = 0;       /* mono */
    header[24] = rate & 255; header[25] = (rate >> 8) & 255; header[26] = (rate >> 16) & 255; header[27] = (rate >> 24) & 255;
    header[28] = byteRate & 255; header[29] = (byteRate >> 8) & 255; header[30] = (byteRate >> 16) & 255; header[31] = (byteRate >> 24) & 255;
    header[32] = 2; header[33] = 0;       /* block align */
    header[34] = 16; header[35] = 0;      /* bits */
    memcpy(header + 36, "data", 4);
    header[40] = length & 255; header[41] = (length >> 8) & 255; header[42] = (length >> 16) & 255; header[43] = (length >> 24) & 255;
    [out appendBytes:header length:44];
    [out appendData:pcm];
    return out;
}

+ (NSArray *)providersWithVoices
{
    return [NSArray arrayWithObjects:@"chatgpt", @"gemini", @"grok", @"mistral", nil];
}

+ (NSArray *)voicesForProvider:(NSString *)provider
{
    if ([provider isEqualToString:@"chatgpt"])
        return [NSArray arrayWithObjects:@"alloy", @"ash", @"ballad", @"coral", @"echo", @"fable", @"nova", @"onyx", @"sage", @"shimmer", @"verse", @"marin", @"cedar", nil];
    if ([provider isEqualToString:@"gemini"]) {
        NSMutableArray *list = [NSMutableArray array];
        int i;
        for (i = 0; kGeminiVoices[i]; i++)
            [list addObject:kGeminiVoices[i]];
        return list;
    }
    if ([provider isEqualToString:@"grok"])
        return [NSArray arrayWithObjects:@"eve", @"ara", @"rex", @"sal", @"leo", nil];
    if ([provider isEqualToString:@"mistral"]) {
        NSString *key = [TBSettings keyForProvider:@"mistral"];
        NSMutableArray *list = [NSMutableArray array];
        if ([key length]) {
            TBHTTP *http = [TBHTTP request:@"GET" url:address(@"mistral-voices", @"https://api.mistral.ai/v1/audio/voices?limit=100")];
            [http setHeader:@"Authorization" value:[@"Bearer " stringByAppendingString:key]];
            [http setIdleTimeout:20];
            if ([http perform] == TBNET_OK && [http status] >= 200 && [http status] < 300) {
                NSArray *items = TBArray(TBJSONParse([http data], NULL), @"items");
                unsigned i;
                for (i = 0; i < [items count]; i++) {
                    NSString *slug = TBString([items objectAtIndex:i], @"slug"), *ident = TBString([items objectAtIndex:i], @"id"), *name = TBString([items objectAtIndex:i], @"name");
                    NSString *use = [slug length] ? slug : ident;
                    if ([use length])
                        [list addObject:[name length] && ![name isEqualToString:use] ? [NSString stringWithFormat:@"%@|%@", use, name] : use];
                }
            }
        }
        if ([list count] == 0)
            [list addObject:@"gb_jane_neutral|Jane (neutral)"];
        return list;
    }
    return [NSArray array];
}

+ (NSData *)speak:(NSString *)text provider:(NSString *)provider voice:(NSString *)voice status:(int *)status problem:(NSString **)problem
{
    NSString *key = [TBSettings keyForProvider:provider];
    NSData *wav = nil;
    *status = 200;
    *problem = nil;
    if (![[self providersWithVoices] containsObject:provider]) {
        *status = 422;
        *problem = @"That service has no voices.";
        return nil;
    }
    if ([TBTrim(text) length] == 0) {
        *status = 422;
        *problem = @"There is nothing to say.";
        return nil;
    }
    if (![key length]) {
        *status = 424;
        *problem = @"That voice needs its service's key. Add one in Preferences.";
        return nil;
    }
    if ([text length] > 4000)
        text = [text substringToIndex:4000];
    if ([provider isEqualToString:@"chatgpt"])
        wav = openaiSpeech(text, voice, key, status, problem);
    else if ([provider isEqualToString:@"gemini"])
        wav = geminiSpeech(text, voice, key, status, problem);
    else if ([provider isEqualToString:@"grok"])
        wav = grokSpeech(text, voice, key, status, problem);
    else
        wav = mistralSpeech(text, voice, key, status, problem);
    if (!wav && !*problem)
        *problem = @"The service returned no audio.";
    return wav;
}


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
