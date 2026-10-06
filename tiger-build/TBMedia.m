#import "TBMedia.h"
#import "TBEngine.h"
#import "TBHTTP.h"
#import "TBJSON.h"
#import "TBSupport.h"
#import "TBOutputs.h"
#import "mbedtls/sha256.h"
#import <sys/socket.h>
#import <netdb.h>
#import <arpa/inet.h>
#import <netinet/in.h>

static NSString *override(NSString *name, NSString *standard)
{
    NSString *over = [[NSUserDefaults standardUserDefaults] stringForKey:[@"TBMediaURL." stringByAppendingString:name]];
    return [over length] ? over : standard;
}

static NSString *userAgent = @"TigerBuild/2.0 (Tiger Build; https://github.com/pf67j9nwfh-web/Tiger-Build)";

NSData *TBFetch(NSString *method, NSString *url, NSArray *headers, NSData *body, int timeout, int *status, TBRun *run)
{
    int hop;
    for (hop = 0; hop < 6; hop++) {
        TBHTTP *http = [TBHTTP request:method url:url];
        unsigned i;
        int result;
        for (i = 0; i + 1 < [headers count]; i += 2)
            [http setHeader:[headers objectAtIndex:i] value:[headers objectAtIndex:i + 1]];
        [http setHeader:@"User-Agent" value:userAgent];
        if (body)
            [http setBody:body];
        [http setIdleTimeout:timeout];
        [run attach:http];
        result = [http perform];
        [run detach:http];
        [run check];
        if (result != TBNET_OK) {
            *status = 0;
            return [[http error] dataUsingEncoding:NSUTF8StringEncoding];
        }
        *status = [http status];
        if (*status >= 301 && *status <= 308 && *status != 304 && [[http responseHeader:@"Location"] length]) {
            NSString *next = [http responseHeader:@"Location"];
            NSURL *base = [NSURL URLWithString:url];
            NSURL *resolved = [NSURL URLWithString:next relativeToURL:base];
            url = [resolved absoluteString];
            if (*status == 303) {
                method = @"GET";
                body = nil;
            }
            continue;
        }
        return [http data];
    }
    *status = 0;
    return [@"too many redirects" dataUsingEncoding:NSUTF8StringEncoding];
}

/* the service's own words for what went wrong */
static NSString *serviceMessage(int status, NSData *data)
{
    NSString *text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    id json = TBJSONParse(data, NULL);
    id err = TBValue(json, @"error");
    if (status == 0)
        return text ? text : @"the service could not be reached";
    if ([err isKindOfClass:[NSDictionary class]] && [TBString(err, @"message") length])
        text = TBString(err, @"message");
    else if ([err isKindOfClass:[NSString class]] && [err length])
        text = err;
    if (![TBTrim(text) length])
        text = [NSString stringWithFormat:@"The service answered HTTP %d with no explanation.", status];
    return [text length] > 500 ? [text substringToIndex:500] : text;
}

static id jsonCall(NSString *url, id payload, NSArray *headers, int timeout, TBRun *run)
{
    int status;
    NSArray *all = payload ? [headers arrayByAddingObjectsFromArray:[NSArray arrayWithObjects:@"Content-Type", @"application/json", nil]] : headers;
    NSData *data = TBFetch(payload ? @"POST" : @"GET", url, all, payload ? TBJSONData(payload) : nil, timeout, &status, run);
    id json;
    if (status < 200 || status >= 300)
        TBFail(@"%@", serviceMessage(status, data));
    json = TBJSONParse(data, NULL);
    if (![json isKindOfClass:[NSDictionary class]])
        TBFail(@"The media service returned an unreadable response.");
    return json;
}

static NSArray *bearer(NSString *key)
{
    return [NSArray arrayWithObjects:@"Authorization", [@"Bearer " stringByAppendingString:key], nil];
}

static NSString *needKey(NSString *provider)
{
    NSString *key = [TBSettings keyForProvider:provider];
    if (![key length])
        TBFail(@"Add the %@ key before generating media.", provider);
    return key;
}

static NSData *download(NSString *url, NSArray *headers, TBRun *run)
{
    int status;
    NSData *data = TBFetch(@"GET", url, headers, nil, 120, &status, run);
    if (status < 200 || status >= 300)
        TBFail(@"%@", serviceMessage(status, data));
    return data;
}

static void pauseFor(double seconds, TBRun *run)
{
    [NSThread sleepUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
    [run check];
}

/* b64_json or url of the first picture of an images/generations answer */
static NSData *pictureFrom(id payload, NSString *who, TBRun *run)
{
    NSArray *items = TBArray(payload, @"data");
    id first = [items count] ? [items objectAtIndex:0] : nil;
    if ([TBString(first, @"b64_json") length]) {
        NSData *d = TBBase64Decode(TBString(first, @"b64_json"));
        if (d)
            return d;
    }
    if ([TBString(first, @"url") length])
        return download(TBString(first, @"url"), nil, run);
    TBFail(@"%@ did not return an image.", who);
    return nil;
}

static NSData *grokImage(NSString *prompt, TBRun *run, NSString **ext)
{
    id payload = jsonCall(override(@"grok-image", @"https://api.x.ai/v1/images/generations"),
        [NSDictionary dictionaryWithObjectsAndKeys:@"grok-imagine-image-2.0", @"model", prompt, @"prompt", @"b64_json", @"response_format", [NSNumber numberWithInt:1], @"n", nil],
        bearer(needKey(@"grok")), 120, run);
    *ext = @"jpg";
    return pictureFrom(payload, @"Grok", run);
}

static NSData *openaiImage(NSString *prompt, TBRun *run, NSString **ext)
{
    id payload = jsonCall(override(@"chatgpt-image", @"https://api.openai.com/v1/images/generations"),
        [NSDictionary dictionaryWithObjectsAndKeys:@"gpt-image-1.5", @"model", prompt, @"prompt", [NSNumber numberWithInt:1], @"n", @"1024x1024", @"size", nil],
        bearer(needKey(@"chatgpt")), 120, run);
    *ext = @"png";
    return pictureFrom(payload, @"ChatGPT", run);
}

static NSData *museImage(NSString *prompt, TBRun *run, NSString **ext)
{
    id payload = jsonCall(override(@"muse-image", @"https://api.meta.ai/v1/images/generations"),
        [NSDictionary dictionaryWithObjectsAndKeys:@"muse-image-1.0", @"model", prompt, @"prompt", [NSNumber numberWithInt:1], @"n", nil],
        bearer(needKey(@"muse")), 120, run);
    *ext = @"png";
    return pictureFrom(payload, @"Muse", run);
}

static NSString *swapName(NSString *name);

static NSString *geminiModel(BOOL video, TBRun *run)
{
    static NSString *cachedImage = nil, *cachedVideo = nil;
    if (!cachedImage && !cachedVideo) {
        id payload = jsonCall(override(@"gemini-models", @"https://generativelanguage.googleapis.com/v1beta/models?pageSize=200"), nil,
            [NSArray arrayWithObjects:@"x-goog-api-key", needKey(@"gemini"), nil], 30, run);
        NSArray *models = TBArray(payload, @"models");
        NSString *image = @"", *clip = @"";
        unsigned i;
        for (i = 0; i < [models count]; i++) {
            NSString *name = swapName(TBString([models objectAtIndex:i], @"name"));
            NSString *low = [name lowercaseString];
            NSArray *methods = TBArray([models objectAtIndex:i], @"supportedGenerationMethods");
            if ([low rangeOfString:@"image"].location != NSNotFound && [low rangeOfString:@"tts"].location == NSNotFound && [methods containsObject:@"generateContent"] && ![image length])
                image = name;
            if ([low rangeOfString:@"veo"].location != NSNotFound && ![clip length])
                clip = name;
        }
        cachedImage = [image retain];
        cachedVideo = [clip retain];
    }
    return video ? cachedVideo : cachedImage;
}

static NSData *geminiImage(NSString *prompt, TBRun *run, NSString **ext)
{
    NSString *model = geminiModel(NO, run);
    id payload;
    NSArray *candidates, *parts;
    unsigned i;
    if (![model length])
        TBFail(@"This Gemini key has no image model.");
    payload = jsonCall([NSString stringWithFormat:override(@"gemini-generate", @"https://generativelanguage.googleapis.com/v1beta/models/%@:generateContent"), model],
        [NSDictionary dictionaryWithObjectsAndKeys:[NSArray arrayWithObject:[NSDictionary dictionaryWithObjectsAndKeys:@"user", @"role",
            [NSArray arrayWithObject:[NSDictionary dictionaryWithObject:prompt forKey:@"text"]], @"parts", nil]], @"contents",
            [NSDictionary dictionaryWithObject:[NSArray arrayWithObjects:@"TEXT", @"IMAGE", nil] forKey:@"responseModalities"], @"generationConfig", nil],
        [NSArray arrayWithObjects:@"x-goog-api-key", needKey(@"gemini"), nil], 120, run);
    candidates = TBArray(payload, @"candidates");
    parts = [candidates count] ? TBArray(TBDictionary([candidates objectAtIndex:0], @"content"), @"parts") : nil;
    for (i = 0; i < [parts count]; i++) {
        id part = [parts objectAtIndex:i];
        id inline_ = TBDictionary(part, @"inlineData");
        NSString *encoded, *mime;
        if (![inline_ count])
            inline_ = TBDictionary(part, @"inline_data");
        encoded = TBString(inline_, @"data");
        mime = [TBString(inline_, @"mimeType") length] ? TBString(inline_, @"mimeType") : TBString(inline_, @"mime_type");
        if ([encoded length]) {
            *ext = ([mime rangeOfString:@"jp"].location != NSNotFound) ? @"jpg" : @"png";
            return TBBase64Decode(encoded);
        }
    }
    TBFail(@"Gemini did not return an image.");
    return nil;
}

static NSString *swapName(NSString *name)
{
    return [[name componentsSeparatedByString:@"models/"] componentsJoinedByString:@""];
}

static NSData *grokVideo(NSString *prompt, TBRun *run)
{
    NSArray *auth = bearer(needKey(@"grok"));
    id started = jsonCall(override(@"grok-video", @"https://api.x.ai/v1/videos/generations"),
        [NSDictionary dictionaryWithObjectsAndKeys:@"grok-imagine-video-1.5", @"model", prompt, @"prompt", [NSNumber numberWithInt:5], @"duration", @"16:9", @"aspect_ratio", @"480p", @"resolution", nil], auth, 120, run);
    NSString *requestId = TBString(started, @"request_id");
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:180];
    if (![requestId length])
        TBFail(@"Grok did not start a video.");
    while ([deadline timeIntervalSinceNow] > 0) {
        id status;
        NSString *state;
        pauseFor(4, run);
        status = jsonCall([override(@"grok-video-status", @"https://api.x.ai/v1/videos/") stringByAppendingString:requestId], nil, auth, 30, run);
        state = TBString(status, @"status");
        if ([state isEqualToString:@"done"]) {
            NSString *url = TBString(TBDictionary(status, @"video"), @"url");
            if (![url length])
                TBFail(@"Grok finished the video without a file.");
            return download(url, nil, run);
        }
        if ([state isEqualToString:@"failed"] || [state isEqualToString:@"expired"]) {
            id err = TBValue(status, @"error");
            NSString *message = [err isKindOfClass:[NSDictionary class]] ? TBString(err, @"message") : @"";
            TBFail(@"%@", [message length] ? message : @"Grok could not make the video.");
        }
    }
    TBFail(@"The video was still rendering after three minutes.");
    return nil;
}

static NSData *geminiVideo(NSString *prompt, TBRun *run)
{
    NSString *model = geminiModel(YES, run);
    NSArray *auth = [NSArray arrayWithObjects:@"x-goog-api-key", needKey(@"gemini"), nil];
    id started;
    NSString *name;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:180];
    if (![model length])
        TBFail(@"This Gemini key has no video model.");
    started = jsonCall([NSString stringWithFormat:override(@"gemini-video", @"https://generativelanguage.googleapis.com/v1beta/models/%@:predictLongRunning"), model],
        [NSDictionary dictionaryWithObject:[NSArray arrayWithObject:[NSDictionary dictionaryWithObject:prompt forKey:@"prompt"]] forKey:@"instances"], auth, 120, run);
    name = TBString(started, @"name");
    if (![name length])
        TBFail(@"Gemini did not start a video.");
    while ([deadline timeIntervalSinceNow] > 0) {
        id status, response, video;
        NSArray *samples;
        pauseFor(5, run);
        status = jsonCall([override(@"gemini-operation", @"https://generativelanguage.googleapis.com/v1beta/") stringByAppendingString:name], nil, auth, 30, run);
        if (!TBTruth(status, @"done"))
            continue;
        if (TBValue(status, @"error")) {
            id err = TBValue(status, @"error");
            NSString *message = [err isKindOfClass:[NSDictionary class]] ? TBString(err, @"message") : @"";
            TBFail(@"%@", [message length] ? message : @"Gemini could not make the video.");
        }
        response = TBDictionary(status, @"response");
        samples = TBArray(TBDictionary(response, @"generateVideoResponse"), @"generatedSamples");
        if (![samples count])
            samples = TBArray(response, @"videos");
        if ([samples count]) {
            video = TBDictionary([samples objectAtIndex:0], @"video");
            if (![video count])
                video = [samples objectAtIndex:0];
            if ([TBString(video, @"bytesBase64Encoded") length])
                return TBBase64Decode(TBString(video, @"bytesBase64Encoded"));
            if ([TBString(video, @"uri") length])
                return download(TBString(video, @"uri"), auth, run);
        }
        TBFail(@"Gemini finished the video without a file.");
    }
    TBFail(@"The video was still rendering after three minutes.");
    return nil;
}

/* the public internet only: a model must not make the app fetch things on the local network */
static BOOL publicHost(NSString *host)
{
    struct addrinfo hints, *found = NULL, *at;
    BOOL ok = YES;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo([host UTF8String], NULL, &hints, &found) != 0)
        TBFail(@"Cannot find that address.");
    for (at = found; at; at = at->ai_next) {
        if (at->ai_family == AF_INET) {
            unsigned char *b = (unsigned char *)&((struct sockaddr_in *)at->ai_addr)->sin_addr;
            if (b[0] == 10 || b[0] == 127 || b[0] == 0 || b[0] >= 224 || (b[0] == 169 && b[1] == 254) || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168) || (b[0] == 100 && b[1] >= 64 && b[1] <= 127))
                ok = NO;
        } else if (at->ai_family == AF_INET6) {
            unsigned char *b = ((struct sockaddr_in6 *)at->ai_addr)->sin6_addr.s6_addr;
            int zeros = 1, i;
            for (i = 0; i < 15; i++)
                if (b[i])
                    zeros = 0;
            if ((zeros && (b[15] == 0 || b[15] == 1)) || (b[0] & 0xfe) == 0xfc || (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) || b[0] == 0xff)
                ok = NO;
            else if (b[10] == 0xff && b[11] == 0xff && !b[0] && !b[1] && !b[2] && !b[3] && !b[4] && !b[5] && !b[6] && !b[7] && !b[8] && !b[9]) {
                /* an IPv4 address in IPv6 clothes */
                if (b[12] == 10 || b[12] == 127 || (b[12] == 192 && b[13] == 168) || (b[12] == 172 && b[13] >= 16 && b[13] <= 31) || (b[12] == 169 && b[13] == 254))
                    ok = NO;
            }
        }
    }
    if (found)
        freeaddrinfo(found);
    return ok;
}

static void checkPictureURL(NSString *url)
{
    NSURL *parsed = [NSURL URLWithString:url];
    NSString *scheme = [[parsed scheme] lowercaseString];
    if (!parsed || !([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) || ![[parsed host] length])
        TBFail(@"Give a full http or https picture address.");
    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"TBAllowLocalPictures"] && !publicHost([parsed host]))
        TBFail(@"Pictures can only come from public web addresses.");
}

@implementation TBMedia

+ (NSArray *)toolsForProvider:(NSString *)provider
{
    NSMutableArray *tools = [NSMutableArray array];
    NSDictionary *prompt = [NSDictionary dictionaryWithObject:[NSDictionary dictionaryWithObjectsAndKeys:@"string", @"type", nil] forKey:@"prompt"];
    NSMutableDictionary *p;
    if ([provider isEqualToString:@"grok"] || [provider isEqualToString:@"chatgpt"] || [provider isEqualToString:@"gemini"] || [provider isEqualToString:@"muse"]) {
        p = [NSMutableDictionary dictionaryWithDictionary:prompt];
        [p setObject:[NSDictionary dictionaryWithObjectsAndKeys:@"string", @"type", @"What the picture should show.", @"description", nil] forKey:@"prompt"];
        [tools addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"function", @"type", @"generate_image", @"name",
            @"Generate a picture with this provider's image service. Use when the person asks for an image, drawing, or illustration.", @"description",
            [NSDictionary dictionaryWithObjectsAndKeys:@"object", @"type", p, @"properties", [NSArray arrayWithObject:@"prompt"], @"required", nil], @"parameters", nil]];
    }
    if ([provider isEqualToString:@"grok"] || [provider isEqualToString:@"gemini"]) {   /* OpenAI closed its Videos API on 24 September 2026 */
        p = [NSMutableDictionary dictionary];
        [p setObject:[NSDictionary dictionaryWithObjectsAndKeys:@"string", @"type", @"What the video should show.", @"description", nil] forKey:@"prompt"];
        [tools addObject:[NSDictionary dictionaryWithObjectsAndKeys:@"function", @"type", @"generate_video", @"name",
            @"Generate a short video with this provider's video service. Use when the person asks for a video, clip, or animation.", @"description",
            [NSDictionary dictionaryWithObjectsAndKeys:@"object", @"type", p, @"properties", [NSArray arrayWithObject:@"prompt"], @"required", nil], @"parameters", nil]];
    }
    return tools;
}

+ (NSDictionary *)create:(NSString *)tool prompt:(NSString *)prompt provider:(NSString *)provider run:(TBRun *)run
{
    NSData *data;
    NSString *ext = @"mp4", *kind;
    prompt = TBTrim(prompt);
    if (![prompt length])
        TBFail(@"Say what the picture or video should show.");
    if ([tool isEqualToString:@"generate_image"]) {
        kind = @"image";
        if ([provider isEqualToString:@"grok"]) data = grokImage(prompt, run, &ext);
        else if ([provider isEqualToString:@"chatgpt"]) data = openaiImage(prompt, run, &ext);
        else if ([provider isEqualToString:@"gemini"]) data = geminiImage(prompt, run, &ext);
        else if ([provider isEqualToString:@"muse"]) data = museImage(prompt, run, &ext);
        else { TBFail(@"This model cannot generate images."); return nil; }
    } else if ([tool isEqualToString:@"generate_video"]) {
        kind = @"video";
        if ([provider isEqualToString:@"grok"]) data = grokVideo(prompt, run);
        else if ([provider isEqualToString:@"gemini"]) data = geminiVideo(prompt, run);
        else { TBFail(@"This model cannot generate videos."); return nil; }
    } else {
        TBFail(@"Unknown media tool.");
        return nil;
    }
    if (![data length])
        TBFail(@"The media service returned an empty file.");
    return [NSDictionary dictionaryWithObjectsAndKeys:kind, @"kind", TBSaveMedia(data, ext), @"filename", nil];
}

+ (NSString *)fetchImage:(NSString *)url
{
    NSString *current = TBTrim(url);
    int hop;
    if (![url isKindOfClass:[NSString class]] || [url length] > 2000)
        TBFail(@"Give a picture address.");
    for (hop = 0; hop < 6; hop++) {
        TBHTTP *http;
        int result;
        const unsigned char *b;
        NSData *data;
        checkPictureURL(current);
        http = [TBHTTP request:@"GET" url:current];
        [http setHeader:@"User-Agent" value:userAgent];
        [http setHeader:@"Accept" value:@"image/jpeg,image/png,image/gif,*/*;q=0.5"];
        [http setIdleTimeout:25];
        result = [http perform];
        if (result != TBNET_OK)
            TBFail(@"%@", [http error]);
        if ([http status] >= 301 && [http status] <= 308 && [[http responseHeader:@"Location"] length]) {
            current = [[NSURL URLWithString:[http responseHeader:@"Location"] relativeToURL:[NSURL URLWithString:current]] absoluteString];
            continue;
        }
        if ([http status] < 200 || [http status] >= 300)
            TBFail(@"The picture could not be fetched (HTTP %d).", [http status]);
        data = [http data];
        if ([data length] > 10000000)
            TBFail(@"That picture is larger than 10 MB.");
        b = [data bytes];
        if ([data length] > 8 && !memcmp(b, "\x89PNG\r\n\x1a\n", 8))
            return TBSaveMedia(data, @"png");
        if ([data length] > 3 && b[0] == 0xff && b[1] == 0xd8 && b[2] == 0xff)
            return TBSaveMedia(data, @"jpg");
        if ([data length] > 6 && (!memcmp(b, "GIF87a", 6) || !memcmp(b, "GIF89a", 6)))
            return TBSaveMedia(data, @"gif");
        TBFail(@"That address is not a JPEG, PNG or GIF picture. Try another result.");
    }
    TBFail(@"Too many redirects.");
    return nil;
}

@end

/* collects a download, and stops it when it grows past the limit */
@interface TBDownloadSink : NSObject {
@public
    NSMutableData *bytes;
    unsigned long limit;
    BOOL tooBig;
}
@end

@implementation TBDownloadSink
- (id)init
{
    self = [super init];
    bytes = [[NSMutableData alloc] init];
    return self;
}
- (void)dealloc
{
    [bytes release];
    [super dealloc];
}
- (BOOL)http:(TBHTTP *)http gotData:(NSData *)data
{
    (void)http;
    if ([bytes length] + [data length] > limit) {
        tooBig = YES;
        return YES;
    }
    [bytes appendData:data];
    return NO;
}
@end

#define DOWNLOAD_LIMIT (50UL * 1024 * 1024)

@implementation TBMedia (Download)

/* A file at an https address on the public internet, over TLS 1.2 or 1.3 with the certificate checked, kept in the media folder.
   Returns {stored, name, size, sha256, type, url}. */
+ (NSDictionary *)downloadURL:(NSString *)url name:(NSString *)requested run:(TBRun *)run
{
    NSString *current = TBTrim(url);
    int hop;
    if (![url isKindOfClass:[NSString class]] || [current length] > 2000)
        TBFail(@"Give the https address of the file.");
    for (hop = 0; hop < 6; hop++) {
        NSURL *parsed = [NSURL URLWithString:current];
        TBHTTP *http;
        TBDownloadSink *sink = [[[TBDownloadSink alloc] init] autorelease];
        int result;
        NSString *type, *disposition, *fileName;
        unsigned char digest[32];
        NSMutableString *hex = [NSMutableString string];
        int i;
        if (!parsed || ![[[parsed scheme] lowercaseString] isEqualToString:@"https"] || ![[parsed host] length])
            TBFail(@"Only https addresses can be downloaded, so the connection is encrypted and the server's certificate is checked.");
        if (![[NSUserDefaults standardUserDefaults] boolForKey:@"TBAllowLocalPictures"] && !publicHost([parsed host]))
            TBFail(@"Files can only be downloaded from public web addresses.");
        http = [TBHTTP request:@"GET" url:current];
        [http setHeader:@"User-Agent" value:userAgent];
        [http setIdleTimeout:30];
        sink->limit = DOWNLOAD_LIMIT;
        [http setDelegate:sink];
        [run attach:http];
        result = [http perform];
        [run detach:http];
        [run check];
        if (sink->tooBig)
            TBFail(@"That file is larger than 50 MB.");
        if (result != TBNET_OK)
            TBFail(@"%@", [http error]);
        if ([http status] >= 301 && [http status] <= 308 && [[http responseHeader:@"Location"] length]) {
            current = [[NSURL URLWithString:[http responseHeader:@"Location"] relativeToURL:parsed] absoluteString];
            continue;
        }
        if ([http status] < 200 || [http status] >= 300)
            TBFail(@"The server answered HTTP %d.", [http status]);
        if (![sink->bytes length])
            TBFail(@"The server sent an empty file.");
        type = [http responseHeader:@"Content-Type"];
        disposition = [http responseHeader:@"Content-Disposition"];
        fileName = TBTrim(requested);
        if (![fileName length] && [disposition length]) {
            NSRange at = [[disposition lowercaseString] rangeOfString:@"filename="];
            if (at.location != NSNotFound) {
                NSString *rest = [disposition substringFromIndex:NSMaxRange(at)];
                rest = [[rest componentsSeparatedByString:@";"] objectAtIndex:0];
                fileName = [rest stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" \"'"]];
            }
        }
        if (![fileName length])
            fileName = [[parsed path] lastPathComponent];
        if (![fileName length] || [fileName isEqualToString:@"/"])
            fileName = @"download";
        mbedtls_sha256([sink->bytes bytes], [sink->bytes length], digest, 0);
        for (i = 0; i < 32; i++)
            [hex appendFormat:@"%02x", digest[i]];
        return [NSDictionary dictionaryWithObjectsAndKeys:[TBOutputs storeData:sink->bytes name:fileName], @"stored", [TBOutputs cleanFileName:fileName], @"name",
            [NSNumber numberWithUnsignedLong:[sink->bytes length]], @"size", hex, @"sha256", type ? type : @"", @"type", current, @"url", nil];
    }
    TBFail(@"Too many redirects.");
    return nil;
}

@end
