#import "TBSupport.h"
#import "TBMarkup.h"
#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>

NSString *TBJSONEscape(NSString *value)
{
    NSMutableString *out = [NSMutableString string];
    unsigned i;
    unsigned n;
    if (!value)
        return out;
    n = [value length];
    for (i = 0; i < n; i++) {
        unichar ch = [value characterAtIndex:i];
        if (ch == '"' || ch == '\\')
            [out appendFormat:@"\\%C", ch];
        else if (ch == '\n')
            [out appendString:@"\\n"];
        else if (ch == '\r')
            [out appendString:@"\\r"];
        else if (ch == '\t')
            [out appendString:@"\\t"];
        else if (ch < 32 || ch == 0x2028 || ch == 0x2029)
            [out appendFormat:@"\\u%04x", ch];
        else
            [out appendFormat:@"%C", ch];
    }
    return out;
}

TBChatLayout TBLayoutChatPane(float paneWidth, float paneHeight, float wanted, float statusHeight, float thinkingHeight)
{
    TBChatLayout layout;
    float sendW = 92;     /* wide enough for "Working." and "Guide ●" */
    float stopW = 76;
    /* The rounded bezels are drawn about 9 pixels in from the left of their frames and
       5 from the right, so frames that sit side by side look 14 pixels apart. These
       positions make the drawn gaps equal: text box to Stop, Stop to Send, and Send to
       the window edge are each about 14 pixels. */
    float edgeInset = 9;
    float fieldW = paneWidth - 8 - (edgeInset + sendW + stopW + 7);
    float maxField;
    float inputTop;
    float transcriptY;
    float transcriptH;
    float buttonY;
    float top;
    float rowY;
    float actionsW = TB_ACTIONS_WIDTH;
    if (statusHeight < 0)
        statusHeight = 0;
    if (statusHeight > TB_STATUS_MAX)
        statusHeight = TB_STATUS_MAX;
    if (thinkingHeight < 0)
        thinkingHeight = 0;
    if (thinkingHeight > TB_THINKING_MAX)
        thinkingHeight = TB_THINKING_MAX;
    top = statusHeight > 0 ? statusHeight + 4 : 0;
    if (fieldW < 80)
        fieldW = 80;
    maxField = paneHeight - 150 - (thinkingHeight > 0 ? thinkingHeight + 6 : 0);
    if (maxField > TB_FIELD_MAX)
        maxField = TB_FIELD_MAX;
    if (maxField < TB_FIELD_MIN)
        maxField = TB_FIELD_MIN;
    if (wanted < TB_FIELD_MIN)
        wanted = TB_FIELD_MIN;
    if (wanted > maxField)
        wanted = maxField;
    inputTop = 14 + wanted;
    if (thinkingHeight > 0) {
        layout.thinking = NSMakeRect(8, inputTop + 6, paneWidth - 16, thinkingHeight);
        inputTop += thinkingHeight + 6;
    } else {
        layout.thinking = NSMakeRect(8, inputTop + 6, paneWidth - 16, 0);
    }
    transcriptY = 8 + inputTop;
    rowY = paneHeight - 28 - top;
    transcriptH = rowY - 4 - transcriptY;
    if (transcriptH < 40)
        transcriptH = 40;
    buttonY = 14 + (wanted - 28) / 2;
    if (buttonY < 10)
        buttonY = 10;
    if (actionsW > paneWidth - 16 - 120)
        actionsW = paneWidth - 16 - 120;
    if (actionsW < 0)
        actionsW = 0;
    layout.fieldHeight = wanted;
    layout.input = NSMakeRect(8, 14, fieldW, wanted);
    layout.stop = NSMakeRect(paneWidth - edgeInset - sendW - stopW, buttonY, stopW, 28);
    layout.send = NSMakeRect(paneWidth - edgeInset - sendW, buttonY, sendW, 28);
    layout.transcript = NSMakeRect(8, transcriptY, paneWidth - 16, transcriptH);
    layout.actions = NSMakeRect(8, rowY, actionsW, 20);
    layout.context = NSMakeRect(8 + actionsW + 4, rowY, paneWidth - 16 - actionsW - 4, 18);
    layout.status = NSMakeRect(8, paneHeight - 10 - statusHeight, paneWidth - 16, statusHeight);
    return layout;
}

/* On PowerPC, sending doubleValue to nil returns whatever was left in the
   floating point register, not 0. Always go through this. */
static double numberD(id value)
{
    return value ? [value doubleValue] : 0.0;
}

NSString *TBFormatTokens(int count)
{
    if (count >= 1000000)
        return [NSString stringWithFormat:@"%.1fm", count / 1000000.0];
    if (count >= 1000)
        return [NSString stringWithFormat:@"%.1fk", count / 1000.0];
    return [NSString stringWithFormat:@"%d", count];
}

NSString *TBFormatCost(double dollars)
{
    if (dollars <= 0)
        return @"$0.00";
    if (dollars < 0.001)
        return @"<$0.001";
    if (dollars < 0.1)
        return [NSString stringWithFormat:@"$%.4f", dollars];
    if (dollars < 100)
        return [NSString stringWithFormat:@"$%.2f", dollars];
    return [NSString stringWithFormat:@"$%.0f", dollars];
}

void TBAddUsage(NSMutableDictionary *chat, NSDictionary *event)
{
    NSMutableDictionary *usage = [chat objectForKey:@"usage"];
    NSString *key;
    NSMutableDictionary *row;
    NSArray *names;
    unsigned i;
    if (!event || ![event objectForKey:@"model"])
        return;
    if (![usage isKindOfClass:[NSMutableDictionary class]]) {
        usage = [NSMutableDictionary dictionary];
        [chat setObject:usage forKey:@"usage"];
    }
    key = [NSString stringWithFormat:@"%@|%@", [event objectForKey:@"provider"], [event objectForKey:@"model"]];
    row = [usage objectForKey:key];
    if (!row) {
        row = [NSMutableDictionary dictionary];
        [usage setObject:row forKey:key];
    }
    names = [NSArray arrayWithObjects:@"input", @"cached", @"written", @"output", nil];
    for (i = 0; i < [names count]; i++) {
        NSString *name = [names objectAtIndex:i];
        [row setObject:[NSNumber numberWithInt:[[row objectForKey:name] intValue] + [[event objectForKey:name] intValue]] forKey:name];
    }
    [row setObject:[NSNumber numberWithInt:[[row objectForKey:@"calls"] intValue] + 1] forKey:@"calls"];
    if ([event objectForKey:@"cost"]) {
        [row setObject:[NSNumber numberWithDouble:numberD([row objectForKey:@"cost"]) + numberD([event objectForKey:@"cost"])]
                forKey:@"cost"];
        [row setObject:[NSNumber numberWithInt:[[row objectForKey:@"priced"] intValue] + 1] forKey:@"priced"];
    }
}

NSString *TBCostReadout(NSDictionary *chat)
{
    NSDictionary *usage = [chat objectForKey:@"usage"];
    NSEnumerator *keys;
    NSString *key;
    double total = 0;
    int priced = 0;
    int calls = 0;
    if (![usage isKindOfClass:[NSDictionary class]] || [usage count] == 0)
        return @"";
    keys = [usage keyEnumerator];
    while ((key = [keys nextObject])) {
        NSDictionary *row = [usage objectForKey:key];
        total += numberD([row objectForKey:@"cost"]);
        priced += [[row objectForKey:@"priced"] intValue];
        calls += [[row objectForKey:@"calls"] intValue];
    }
    if (priced == 0)
        return @"Cost (est) N/A";
    /* Some calls had no price (a local model, or a model the price list does
       not know): the total is then a floor, shown with a plus. */
    return [NSString stringWithFormat:@"Cost (est) %@%@", TBFormatCost(total), priced < calls ? @"+" : @""];
}

NSString *TBCostDetail(NSDictionary *chat)
{
    NSDictionary *usage = [chat objectForKey:@"usage"];
    NSArray *keys;
    NSMutableString *out = [NSMutableString string];
    unsigned i;
    if (![usage isKindOfClass:[NSDictionary class]] || [usage count] == 0)
        return @"No usage yet.";
    keys = [[usage allKeys] sortedArrayUsingSelector:@selector(compare:)];
    for (i = 0; i < [keys count]; i++) {
        NSString *key = [keys objectAtIndex:i];
        NSDictionary *row = [usage objectForKey:key];
        NSRange bar = [key rangeOfString:@"|"];
        NSString *model = bar.location == NSNotFound ? key : [key substringFromIndex:bar.location + 1];
        int tokensIn = [[row objectForKey:@"input"] intValue] + [[row objectForKey:@"cached"] intValue] + [[row objectForKey:@"written"] intValue];
        NSString *money = [[row objectForKey:@"priced"] intValue] > 0 ? TBFormatCost(numberD([row objectForKey:@"cost"])) : @"N/A";
        [out appendFormat:@"%@: %@ in, %@ out, %@\n", model, TBFormatTokens(tokensIn),
            TBFormatTokens([[row objectForKey:@"output"] intValue]), money];
    }
    [out appendString:@"Estimates from token counts and published prices; not an invoice."];
    return out;
}

BOOL TBWorkspaceNameOK(NSString *name)
{
    return [name length] > 0 && [name length] <= 60 && ![name hasPrefix:@"."]
        && [name rangeOfString:@"/"].location == NSNotFound && [name rangeOfString:@":"].location == NSNotFound;
}

NSString *TBChatListProblem(id chats)
{
    unsigned i;
    if (![chats isKindOfClass:[NSArray class]])
        return @"This is not a Tiger Build history export.";
    for (i = 0; i < [chats count]; i++) {
        NSDictionary *chat = [chats objectAtIndex:i];
        NSArray *list;
        unsigned j;
        if (![chat isKindOfClass:[NSDictionary class]] || ![[chat objectForKey:@"messages"] isKindOfClass:[NSArray class]])
            return @"The history contains a malformed chat.";
        list = [chat objectForKey:@"messages"];
        for (j = 0; j < [list count]; j++) {
            NSDictionary *message = [list objectAtIndex:j];
            if (![message isKindOfClass:[NSDictionary class]] || ![[message objectForKey:@"text"] isKindOfClass:[NSString class]]
                || ![[message objectForKey:@"role"] isKindOfClass:[NSString class]])
                return @"Malformed message; import cancelled.";
        }
    }
    return nil;
}

NSDictionary *TBHistoryBundle(id root, NSString *fallbackName)
{
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSMutableDictionary *spaces = [NSMutableDictionary dictionary];
    if (![root isKindOfClass:[NSDictionary class]])
        return nil;
    if ([[root objectForKey:@"format"] isEqualToString:@"TigerBuild-history"]) {
        NSDictionary *incoming = [root objectForKey:@"workspaces"];
        NSEnumerator *names;
        NSString *name;
        if (![incoming isKindOfClass:[NSDictionary class]] || [incoming count] == 0)
            return nil;
        names = [incoming keyEnumerator];
        while ((name = [names nextObject])) {
            NSDictionary *space = [incoming objectForKey:name];
            if (![name isKindOfClass:[NSString class]] || !TBWorkspaceNameOK(name) || ![space isKindOfClass:[NSDictionary class]])
                return nil;
            if (TBChatListProblem([space objectForKey:@"chats"]))
                return nil;
            [spaces setObject:space forKey:name];
        }
        [result setObject:spaces forKey:@"workspaces"];
        if ([[root objectForKey:@"current"] isKindOfClass:[NSString class]] && [spaces objectForKey:[root objectForKey:@"current"]])
            [result setObject:[root objectForKey:@"current"] forKey:@"current"];
        [result setObject:[NSNumber numberWithBool:YES] forKey:@"bundle"];
        return result;
    }
    /* The 1.2 format: one workspace's chats. */
    if (TBChatListProblem([root objectForKey:@"chats"]))
        return nil;
    [spaces setObject:root forKey:fallbackName ? fallbackName : @"Default"];
    [result setObject:spaces forKey:@"workspaces"];
    [result setObject:[NSNumber numberWithBool:NO] forKey:@"bundle"];
    return result;
}

int TBEstimateTokens(NSArray *messages, BOOL toolsOn)
{
    unsigned i;
    double tokens = 0;
    for (i = 0; i < [messages count]; i++) {
        NSDictionary *message = [messages objectAtIndex:i];
        NSString *text;
        unsigned n;
        unsigned j;
        unsigned wide = 0;
        if ([[message objectForKey:@"status"] boolValue])
            continue;
        if ([message objectForKey:@"attachment"]) {
            /* Counted when the file was attached, so a long text is not read again on every update. */
            tokens += [[[message objectForKey:@"attachment"] objectForKey:@"tokens"] intValue] + 12;
            continue;
        }
        text = [message objectForKey:@"text"];
        n = [text length];
        for (j = 0; j < n; j++) {
            if ([text characterAtIndex:j] > 0x7f)
                wide++;
        }
        /* About 4 characters per token for English, 1-2 for other scripts,
           plus the role wrapper each message costs. */
        tokens += (n - wide) / 4.0 + wide / 1.5 + 4;
        if ([message objectForKey:@"image"])
            tokens += 800;
    }
    /* The relay adds a system prompt, and the tool list when Commander is on. */
    tokens += toolsOn ? 3500 : 400;
    return (int)tokens;
}

/* ---- attached files ---- */

NSString *TBHumanSize(double bytes)
{
    if (bytes < 1024)
        return [NSString stringWithFormat:@"%.0f bytes", bytes];
    if (bytes < 1024 * 1024)
        return [NSString stringWithFormat:@"%.0f KB", bytes / 1024.0];
    return [NSString stringWithFormat:@"%.1f MB", bytes / (1024.0 * 1024.0)];
}

NSString *TBImageMime(NSString *path)
{
    NSString *ext = [[path pathExtension] lowercaseString];
    if ([ext isEqualToString:@"png"])
        return @"image/png";
    if ([ext isEqualToString:@"gif"])
        return @"image/gif";
    return @"image/jpeg";
}

/* The text of a file, or nil when it is not text. Reads at most maxBytes; the
   flag says whether there was more. UTF-8 first, then the Mac's own encoding. */
NSString *TBReadTextFile(NSString *path, unsigned maxBytes, BOOL *truncated)
{
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    NSData *data;
    NSString *text;
    const unsigned char *bytes;
    unsigned n;
    unsigned i;
    unsigned cut;
    if (truncated)
        *truncated = NO;
    if (!handle)
        return nil;
    data = [handle readDataOfLength:maxBytes + 1];
    [handle closeFile];
    n = [data length];
    bytes = (const unsigned char *)[data bytes];
    if (n > maxBytes) {
        n = maxBytes;
        if (truncated)
            *truncated = YES;
    }
    for (i = 0; i < n && i < 8192; i++) {
        if (bytes[i] == 0)
            return nil;
    }
    cut = n;
    /* Do not cut a UTF-8 character in two. */
    if (truncated && *truncated) {
        while (cut > 0 && (bytes[cut - 1] & 0xC0) == 0x80)
            cut--;
        if (cut > 0 && bytes[cut - 1] >= 0xC0)
            cut--;
    }
    text = [[[NSString alloc] initWithBytes:bytes length:cut encoding:NSUTF8StringEncoding] autorelease];
    if (!text)
        text = [[[NSString alloc] initWithBytes:bytes length:n encoding:NSMacOSRomanStringEncoding] autorelease];
    return text;
}

NSString *TBDisplayFileName(NSString *stored)
{
    NSString *name = [stored lastPathComponent];
    unsigned i;
    if ([name length] > 17 && [name characterAtIndex:16] == '-') {
        for (i = 0; i < 16; i++) {
            unichar c = [name characterAtIndex:i];
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')))
                return name;
        }
        return [name substringFromIndex:17];
    }
    return name;
}

static NSString *pathHintRoot = nil;

void TBSetPathHintRoot(NSString *root)
{
    [pathHintRoot release];
    pathHintRoot = [root length] > 0 ? [root copy] : nil;
}

/* " A copy is on their Mac at ~/Library/...": the home folder is written as ~ so the account name
   is not repeated to the service, and nothing is said when a workspace restriction hides the copy. */
static NSString *copyHint(NSString *path, NSString *what)
{
    NSString *home = NSHomeDirectory();
    NSString *shown = path;
    if (![path isKindOfClass:[NSString class]] || [path length] == 0)
        return @"";
    if (pathHintRoot && ![path hasPrefix:pathHintRoot])
        return @"";
    if ([path hasPrefix:home])
        shown = [@"~" stringByAppendingString:[path substringFromIndex:[home length]]];
    return [NSString stringWithFormat:@" %@ is on their Mac at %@.", what, shown];
}

/* What a message says to the model: for an attached text file, the file. */
NSString *TBMessageContent(NSDictionary *message)
{
    NSDictionary *file = [message objectForKey:@"attachment"];
    NSString *name;
    NSString *kind;
    NSString *body;
    BOOL truncated = NO;
    if (!file)
        return [message objectForKey:@"text"];
    name = [file objectForKey:@"name"];
    kind = [file objectForKey:@"kind"];
    if ([[file objectForKey:@"stub"] boolValue])
        return [NSString stringWithFormat:@"[The person attached \"%@\" earlier in the conversation. Its content is summarized in the summary above to save space.%@]",
            name, copyHint([file objectForKey:@"path"], @"The original")];
    if ([kind isEqualToString:@"image"])
        return [NSString stringWithFormat:@"[The person attached a picture named \"%@\".%@%@]",
            name, copyHint([file objectForKey:@"path"], @"A copy"), [file objectForKey:@"note"] ? [@" " stringByAppendingString:[file objectForKey:@"note"]] : @""];
    body = TBReadTextFile([file objectForKey:@"path"], TB_ATTACH_TEXT_MAX, &truncated);
    if (!body)
        return [NSString stringWithFormat:@"[The person attached a file named \"%@\", but it is no longer available on this Mac.]", name];
    return [NSString stringWithFormat:@"[The person attached a file named \"%@\". Its contents%@ follow.%@%@]\n\n%@\n\n[End of \"%@\".]",
        name, truncated ? @" (only the first part; the file is longer)" : @"", copyHint([file objectForKey:@"path"], @"A text copy"),
        [file objectForKey:@"note"] ? [@" Note: " stringByAppendingString:[file objectForKey:@"note"]] : @"", body, name];
}

static const char base64Table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

NSString *TBBase64(NSData *data)
{
    const unsigned char *in = (const unsigned char *)[data bytes];
    unsigned n = [data length];
    unsigned i;
    unsigned o = 0;
    char *out = (char *)malloc(((n + 2) / 3) * 4 + 1);
    NSString *result;
    if (!out)
        return @"";
    for (i = 0; i + 2 < n; i += 3) {
        out[o++] = base64Table[in[i] >> 2];
        out[o++] = base64Table[((in[i] & 3) << 4) | (in[i + 1] >> 4)];
        out[o++] = base64Table[((in[i + 1] & 15) << 2) | (in[i + 2] >> 6)];
        out[o++] = base64Table[in[i + 2] & 63];
    }
    if (i < n) {
        out[o++] = base64Table[in[i] >> 2];
        if (i + 1 < n) {
            out[o++] = base64Table[((in[i] & 3) << 4) | (in[i + 1] >> 4)];
            out[o++] = base64Table[(in[i + 1] & 15) << 2];
        } else {
            out[o++] = base64Table[(in[i] & 3) << 4];
            out[o++] = '=';
        }
        out[o++] = '=';
    }
    out[o] = 0;
    result = [NSString stringWithUTF8String:out];
    free(out);
    return result;
}

typedef struct { unsigned long code; const char *name; } EmojiName;

static const EmojiName emojiTable[] = {
    {0x1F600, ":D"}, {0x1F603, ":D"}, {0x1F604, ":D"}, {0x1F601, ":D"}, {0x1F60A, ":)"}, {0x1F642, ":)"}, {0x1F609, ";)"},
    {0x1F641, ":("}, {0x1F61E, ":("}, {0x1F622, ":'("}, {0x1F62D, ":'("}, {0x1F62E, ":O"}, {0x1F61B, ":P"},
    {0x1F602, "(laughing)"}, {0x1F923, "(laughing)"}, {0x1F914, "(thinking)"}, {0x1F60E, "(cool)"}, {0x1F60D, "(love)"},
    {0x1F680, "(rocket)"}, {0x1F44D, "(+1)"}, {0x1F44E, "(-1)"}, {0x1F44F, "(clap)"}, {0x1F44B, "(wave)"}, {0x1F64F, "(thanks)"},
    {0x1F389, "(party)"}, {0x1F525, "(fire)"}, {0x1F4A1, "(idea)"}, {0x1F4DD, "(note)"}, {0x1F4C4, "(file)"}, {0x1F4C1, "(folder)"},
    {0x1F50D, "(search)"}, {0x1F527, "(tool)"}, {0x1F4CA, "(chart)"}, {0x1F4D6, "(book)"}, {0x1F4BB, "(computer)"}, {0x1F512, "(lock)"},
    {0x1F41B, "(bug)"}, {0x1F4AF, "(100)"}, {0x2705, "(check)"}, {0x274C, "(x)"}, {0x26A0, "(warning)"}, {0x2728, "*"}, {0x2B50, "*"},
    {0x1F31F, "*"}, {0x2600, "(sun)"}, {0x26A1, "(zap)"}, {0x1F496, "(heart)"}, {0x1F499, "<3"}, {0x1F49A, "<3"}, {0x2139, "(info)"},
    {0, NULL}
};

static BOOL isPictograph(unichar c)
{
    return c == 0x2705 || c == 0x274C || c == 0x26A0 || c == 0x2728 || c == 0x2600 || c == 0x26A1 || c == 0x2139 || (c >= 0x2B00 && c <= 0x2BFF);
}

NSString *TBDisplayText(NSString *text)
{
    NSMutableString *out;
    unsigned n = [text length];
    unsigned i;
    BOOL needed = NO;
    if (n == 0 || TBSystemMinor() >= 7)
        return text;
    for (i = 0; i < n; i++) {
        unichar c = [text characterAtIndex:i];
        if ((c >= 0xD800 && c <= 0xDFFF) || c == 0xFE0F || c == 0x200D || isPictograph(c)) {
            needed = YES;
            break;
        }
    }
    if (!needed)
        return text;
    out = [NSMutableString stringWithCapacity:n];
    i = 0;
    while (i < n) {
        unichar c = [text characterAtIndex:i];
        if (c == 0xFE0F || c == 0x200D) {
            i++;
        } else if ((c >= 0xD800 && c <= 0xDBFF && i + 1 < n) || isPictograph(c)) {
            unsigned long code = c;
            const EmojiName *row;
            if (c >= 0xD800 && c <= 0xDBFF) {
                unichar low = [text characterAtIndex:i + 1];
                code = 0x10000 + (((unsigned long)c - 0xD800) << 10) + ((unsigned long)low - 0xDC00);
                i += 2;
            } else {
                i++;
            }
            for (row = emojiTable; row->name; row++) {
                if (row->code == code) {
                    NSString *name = [NSString stringWithUTF8String:row->name];
                    unsigned have = [out length];
                    if (have > 0 && row->name[0] == '(' && [out characterAtIndex:have - 1] != ' ')
                        [out appendString:@" "];
                    [out appendString:name];
                    break;
                }
            }
            /* skin tones and the rest of the pictographs have no text form, and are left out */
        } else {
            [out appendFormat:@"%C", c];
            i++;
        }
    }
    return out;
}

NSString *TBSpeechText(NSString *text)
{
    NSArray *blocks = TBSplitBlocks(text);
    NSMutableString *out = [NSMutableString string];
    unsigned b;
    for (b = 0; b < [blocks count]; b++) {
        NSDictionary *block = [blocks objectAtIndex:b];
        NSString *body;
        NSArray *lines;
        unsigned l;
        if ([[block objectForKey:@"code"] boolValue]) {
            [out appendString:[[block objectForKey:@"lang"] isEqualToString:@"table"] ? @"\nThere is a table here.\n" : @"\nThere is a block of code here.\n"];
            continue;
        }
        body = [block objectForKey:@"text"];
        lines = [body componentsSeparatedByString:@"\n"];
        for (l = 0; l < [lines count]; l++) {
            NSString *line = [[lines objectAtIndex:l] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSMutableString *clean = [NSMutableString string];
            unsigned i = 0;
            unsigned n;
            while ([line hasPrefix:@"#"])
                line = [[line substringFromIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([line hasPrefix:@"- "] || [line hasPrefix:@"* "])
                line = [line substringFromIndex:2];
            n = [line length];
            while (i < n) {
                unichar c = [line characterAtIndex:i];
                if (c == '[') {
                    /* [words](address): keep the words */
                    unsigned close = i + 1;
                    while (close < n && [line characterAtIndex:close] != ']')
                        close++;
                    if (close + 1 < n && [line characterAtIndex:close + 1] == '(') {
                        unsigned end = close + 2;
                        while (end < n && [line characterAtIndex:end] != ')')
                            end++;
                        if (end < n) {
                            [clean appendString:[line substringWithRange:NSMakeRange(i + 1, close - i - 1)]];
                            i = end + 1;
                            continue;
                        }
                    }
                }
                if (c == 'h' && (([line compare:@"http://" options:0 range:NSMakeRange(i, MIN(7u, n - i))] == NSOrderedSame)
                    || ([line compare:@"https://" options:0 range:NSMakeRange(i, MIN(8u, n - i))] == NSOrderedSame))) {
                    while (i < n && [line characterAtIndex:i] != ' ')
                        i++;
                    [clean appendString:@"a link"];
                    continue;
                }
                if (c == '*' || c == '`' || c == '_' || c == '|' || c == 0xFE0F || c == 0x200D || (c >= 0xD800 && c <= 0xDFFF)) {
                    i++;
                    continue;
                }
                [clean appendFormat:@"%C", c];
                i++;
            }
            if ([clean length] > 0) {
                [out appendString:clean];
                [out appendString:@"\n"];
            }
        }
    }
    return [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

/* Before a workspace file is replaced, keep the old one: five copies in a ring, one slot for each half hour, and one
   at the first save of every session. A bad write or a bug then costs at most half an hour of chats. */
void TBRollingBackup(NSString *path)
{
    static NSMutableDictionary *last = nil;
    NSFileManager *manager = [NSFileManager defaultManager];
    double now = CFAbsoluteTimeGetCurrent();
    NSNumber *before;
    NSString *dir;
    NSString *target;
    int slot;
    if (!last)
        last = [[NSMutableDictionary alloc] init];
    if (![manager fileExistsAtPath:path])
        return;
    before = [last objectForKey:path];
    if (before && now - [before doubleValue] < 1800)
        return;
    if ([[[manager fileAttributesAtPath:path traverseLink:YES] objectForKey:NSFileSize] doubleValue] < 200)
        return;
    dir = [[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"backups"];
    [manager createDirectoryAtPath:dir attributes:nil];
    slot = (int)(now / 1800.0) % 5;
    target = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%d.plist", [[path lastPathComponent] stringByDeletingPathExtension], slot]];
    [manager removeFileAtPath:target handler:nil];
    if ([manager copyPath:path toPath:target handler:nil])
        [last setObject:[NSNumber numberWithDouble:now] forKey:path];
}

NSString *TBStoreChangedNotification = @"TBStoreChanged";
static NSMutableDictionary *openStores = nil;

/* ---- sharing the file between processes (the window and the terminal program) ----
   Every chat carries a revision ("rev"). A process remembers, for each chat, what it last read or wrote (a fingerprint and the revision), so at a
   save it can tell which chats it changed itself, and under a lock on the file it merges: the chats it changed are written, the others are taken
   from the file if another process changed them, chats made elsewhere are added, chats deleted here are dropped from the file. When two processes
   changed the same chat, the file's version is kept as a second chat ("... (other copy)") so nothing is lost. */

static unsigned long long fnv(unsigned long long h, const void *bytes, size_t n)
{
    const unsigned char *b = bytes;
    size_t i;
    for (i = 0; i < n; i++)
        h = (h ^ b[i]) * 1099511628211ULL;
    return h;
}

static unsigned long long fnvString(unsigned long long h, NSString *s)
{
    const char *u = [s UTF8String];
    return u ? fnv(h, u, strlen(u)) : h;
}

/* what a chat is, apart from its revision: its settings, how many messages, their sizes, and the last two in full */
static unsigned long long chatPrint(NSDictionary *chat)
{
    unsigned long long h = 14695981039346656037ULL;
    NSArray *keys = [[chat allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSArray *messages = [chat objectForKey:@"messages"];
    unsigned i, count = [messages isKindOfClass:[NSArray class]] ? [messages count] : 0;
    for (i = 0; i < [keys count]; i++) {
        NSString *key = [keys objectAtIndex:i];
        if ([key isEqualToString:@"messages"] || [key isEqualToString:@"rev"])
            continue;
        h = fnvString(h, key);
        h = fnvString(h, [[chat objectForKey:key] description]);
    }
    h = fnv(h, &count, sizeof count);
    for (i = 0; i < count; i++) {
        NSDictionary *m = [messages objectAtIndex:i];
        unsigned long len = [[m objectForKey:@"text"] length], n = [m count];
        h = fnv(h, &len, sizeof len);
        h = fnv(h, &n, sizeof n);
        if (i + 2 >= count)
            h = fnvString(h, [m description]);
    }
    return h;
}

static NSString *fileStamp(NSString *path)
{
    struct stat st;
    if (stat([path fileSystemRepresentation], &st) != 0)
        return @"none";
    return [NSString stringWithFormat:@"%llu-%ld.%ld-%lld", (unsigned long long)st.st_ino, (long)st.st_mtimespec.tv_sec, (long)st.st_mtimespec.tv_nsec, (long long)st.st_size];
}

static NSMutableDictionary *readRoot(NSString *path)
{
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSString *error = nil;
    id root;
    if (!data)
        return nil;
    root = [NSPropertyListSerialization propertyListFromData:data mutabilityOption:NSPropertyListMutableContainers format:NULL errorDescription:&error];
    if (error)
        [error release];
    return [root isKindOfClass:[NSMutableDictionary class]] ? root : nil;
}

@interface TBStore (Private)
- (int)takeNextIdLocked;
@end

@implementation TBStore

+ (TBStore *)storeAtPath:(NSString *)path
{
    TBStore *store;
    if (!openStores)
        openStores = [[NSMutableDictionary alloc] init];
    store = [openStores objectForKey:path];
    if (store)
        return store;
    store = [[[TBStore alloc] initWithPath:path] autorelease];
    [openStores setObject:store forKey:path];
    return store;
}

+ (void)forgetAll
{
    NSEnumerator *all = [[openStores allValues] objectEnumerator];
    TBStore *store;
    while ((store = [all nextObject])) {
        [NSObject cancelPreviousPerformRequestsWithTarget:store selector:@selector(flush) object:nil];
        store->dirty = NO;
    }
    [openStores removeAllObjects];
}

+ (void)flushAll
{
    NSEnumerator *all = [[openStores allValues] objectEnumerator];
    TBStore *store;
    while ((store = [all nextObject]))
        [store flush];
}

/* every couple of seconds, look for changes another process made to a file this one has open (the window does; the terminal program asks when it needs to) */
+ (void)startWatching
{
    static NSTimer *timer = nil;
    if (!timer)
        timer = [[NSTimer scheduledTimerWithTimeInterval:2 target:self selector:@selector(watchTick:) userInfo:nil repeats:YES] retain];
}

+ (void)watchTick:(NSTimer *)timer
{
    NSEnumerator *all = [[openStores allValues] objectEnumerator];
    TBStore *store;
    (void)timer;
    while ((store = [all nextObject]))
        if ([store reloadExternal])
            [[NSNotificationCenter defaultCenter] postNotificationName:TBStoreChangedNotification object:store userInfo:nil];
}

- (void)rebaseline
{
    unsigned i;
    [baseline release];
    baseline = [[NSMutableDictionary alloc] init];
    for (i = 0; i < [chats count]; i++) {
        NSDictionary *chat = [chats objectAtIndex:i];
        NSString *ident = [chat objectForKey:@"id"];
        if (ident)
            [baseline setObject:[NSArray arrayWithObjects:[NSNumber numberWithUnsignedLongLong:chatPrint(chat)], [chat objectForKey:@"rev"] ? [chat objectForKey:@"rev"] : [NSNumber numberWithInt:0], nil] forKey:ident];
    }
    [settingsPrint release];
    settingsPrint = [[settings description] copy];
}

- (id)initWithPath:(NSString *)file
{
    NSMutableDictionary *root;
    NSArray *saved;
    unsigned i;
    int highest = 0;
    self = [super init];
    if (!self)
        return nil;
    path = [file copy];
    chats = [[NSMutableArray alloc] init];
    settings = [[NSMutableDictionary alloc] init];
    root = readRoot(path);
    if (root) {
        saved = [root objectForKey:@"chats"];
        if ([saved isKindOfClass:[NSArray class]]) {
            for (i = 0; i < [saved count]; i++) {
                NSArray *list = [[saved objectAtIndex:i] objectForKey:@"messages"];
                unsigned j;
                for (j = 0; j < [list count]; j++) {
                    /* A reply that was still streaming when the app quit. */
                    [[list objectAtIndex:j] removeObjectForKey:@"pendingMedia"];
                    [[list objectAtIndex:j] removeObjectForKey:@"open"];
                }
                [chats addObject:[saved objectAtIndex:i]];
            }
        }
        highest = [[root objectForKey:@"next"] intValue];
        if ([[root objectForKey:@"settings"] isKindOfClass:[NSDictionary class]])
            [settings addEntriesFromDictionary:[root objectForKey:@"settings"]];
    }
    /* The saved value is the next number to hand out. Without one, go by the
       highest chat number there is. */
    if (highest < 1) {
        for (i = 0; i < [chats count]; i++) {
            int number = [[[chats objectAtIndex:i] objectForKey:@"id"] intValue];
            if (number > highest)
                highest = number;
        }
        highest++;
    }
    next = highest;
    [self rebaseline];
    stamp = [fileStamp(path) copy];
    return self;
}

- (void)dealloc
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [path release];
    [chats release];
    [settings release];
    [baseline release];
    [settingsPrint release];
    [stamp release];
    [super dealloc];
}

- (NSString *)path { return path; }
- (NSMutableArray *)chats { return chats; }
- (NSMutableDictionary *)settings { return settings; }
- (int)next { return next; }

/* the lock on the file, held while it is read and written */
- (int)lockFile
{
    int fd;
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent] attributes:nil];
    fd = open([[path stringByAppendingString:@".lock"] fileSystemRepresentation], O_RDWR | O_CREAT, 0600);
    if (fd >= 0)
        flock(fd, LOCK_EX);
    return fd;
}

- (void)unlockFile:(int)fd
{
    if (fd >= 0) {
        flock(fd, LOCK_UN);
        close(fd);
    }
}

/* Chat numbers are handed out from a file of their own, so two processes never give the same number to different chats. */
- (int)takeNextId
{
    NSString *counter = [path stringByAppendingString:@".next"];
    int fd = [self lockFile], value = next;
    NSString *text = [NSString stringWithContentsOfFile:counter encoding:NSUTF8StringEncoding error:NULL];
    NSMutableDictionary *root = readRoot(path);
    if ([text intValue] > value)
        value = [text intValue];
    if ([[root objectForKey:@"next"] intValue] > value)
        value = [[root objectForKey:@"next"] intValue];
    [[NSString stringWithFormat:@"%d\n", value + 1] writeToFile:counter atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [self unlockFile:fd];
    next = value + 1;
    return value;
}

- (BOOL)chatChanged:(NSDictionary *)chat
{
    NSArray *base = [baseline objectForKey:[chat objectForKey:@"id"]];
    return !base || [[base objectAtIndex:0] unsignedLongLongValue] != chatPrint(chat);
}

/* Brings what is in the file together with what is in memory (the file is locked by the caller). With writing NO, only changes made elsewhere are taken in
   (nothing is resolved or written); returns whether memory changed. */
- (BOOL)mergeWithDisk:(NSMutableDictionary *)disk writing:(BOOL)writing
{
    NSMutableDictionary *mine = [NSMutableDictionary dictionary];
    NSMutableSet *onDisk = [NSMutableSet set];
    NSArray *theirs = [disk objectForKey:@"chats"];
    NSMutableArray *added = [NSMutableArray array];
    BOOL changed = NO;
    unsigned i;
    for (i = 0; i < [chats count]; i++)
        if ([[chats objectAtIndex:i] objectForKey:@"id"])
            [mine setObject:[chats objectAtIndex:i] forKey:[[chats objectAtIndex:i] objectForKey:@"id"]];
    if (![theirs isKindOfClass:[NSArray class]])
        theirs = [NSArray array];
    for (i = 0; i < [theirs count]; i++) {
        NSMutableDictionary *other = [theirs objectAtIndex:i], *chat;
        NSString *ident = [other objectForKey:@"id"];
        NSArray *base;
        BOOL local, remote;
        if (![ident isKindOfClass:[NSString class]])
            continue;
        [onDisk addObject:ident];
        chat = [mine objectForKey:ident];
        base = [baseline objectForKey:ident];
        if (!chat) {
            if (!base) {                      /* made elsewhere */
                [added addObject:other];
                changed = YES;
            }                                 /* else: deleted here, so it is not kept */
            continue;
        }
        local = [self chatChanged:chat];
        remote = !base || [[other objectForKey:@"rev"] intValue] != [[base objectAtIndex:1] intValue];
        if (!remote)
            continue;
        if (!local) {                          /* changed elsewhere only: take it, keeping this object */
            [chat setDictionary:other];
            [baseline setObject:[NSArray arrayWithObjects:[NSNumber numberWithUnsignedLongLong:chatPrint(chat)], [chat objectForKey:@"rev"] ? [chat objectForKey:@"rev"] : [NSNumber numberWithInt:0], nil] forKey:ident];
            changed = YES;
        } else if (writing) {                  /* changed in both: this one stays, the other becomes a second chat */
            NSString *title = [other objectForKey:@"title"];
            int theirRev = [[other objectForKey:@"rev"] intValue], baseRev = base ? [[base objectAtIndex:1] intValue] : 0;
            [other setObject:[NSString stringWithFormat:@"%d", [self takeNextIdLocked]] forKey:@"id"];
            [other setObject:[NSString stringWithFormat:@"%@ (other copy)", title ? title : @"Chat"] forKey:@"title"];
            [other removeObjectForKey:@"rev"];
            [added addObject:other];
            [chat setObject:[NSNumber numberWithInt:MAX(theirRev, baseRev)] forKey:@"rev"];
            changed = YES;
        }
    }
    /* chats that are no longer in the file */
    for (i = 0; i < [chats count]; i++) {
        NSDictionary *chat = [chats objectAtIndex:i];
        NSString *ident = [chat objectForKey:@"id"];
        if (ident && ![onDisk containsObject:ident] && [baseline objectForKey:ident] && ![self chatChanged:chat]) {
            [chats removeObjectAtIndex:i--];   /* deleted elsewhere, and not touched here */
            changed = YES;
        }
    }
    for (i = 0; i < [added count]; i++) {
        NSDictionary *chat = [added objectAtIndex:i];
        [chats insertObject:chat atIndex:0];
        [baseline setObject:[NSArray arrayWithObjects:[NSNumber numberWithUnsignedLongLong:chatPrint(chat)], [chat objectForKey:@"rev"] ? [chat objectForKey:@"rev"] : [NSNumber numberWithInt:0], nil] forKey:[chat objectForKey:@"id"]];
    }
    /* the workspace's settings: the file's, with this process's own changes on top */
    {
        NSDictionary *theirSettings = [disk objectForKey:@"settings"];
        BOOL localSettings = ![[settings description] isEqualToString:settingsPrint];
        if ([theirSettings isKindOfClass:[NSDictionary class]] && ![[theirSettings description] isEqualToString:[settings description]]) {
            NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:theirSettings];
            if (localSettings) {
                if (writing)
                    [merged addEntriesFromDictionary:settings];
                else
                    merged = nil;
            }
            if (merged) {
                [settings setDictionary:merged];
                if (!writing)
                    [settingsPrint release], settingsPrint = [[settings description] copy];
                changed = changed || !localSettings;
            }
        }
    }
    if ([[disk objectForKey:@"next"] intValue] > next)
        next = [[disk objectForKey:@"next"] intValue];
    return changed;
}

/* a number for a chat while the file is already locked */
- (int)takeNextIdLocked
{
    NSString *counter = [path stringByAppendingString:@".next"];
    NSString *text = [NSString stringWithContentsOfFile:counter encoding:NSUTF8StringEncoding error:NULL];
    int value = next;
    if ([text intValue] > value)
        value = [text intValue];
    [[NSString stringWithFormat:@"%d\n", value + 1] writeToFile:counter atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    next = value + 1;
    return value;
}

/* Takes in what another process wrote since this one last looked. NO when the file is as it was. */
- (BOOL)reloadExternal
{
    NSMutableDictionary *disk;
    BOOL changed;
    int fd;
    if ([fileStamp(path) isEqualToString:stamp])
        return NO;
    fd = [self lockFile];
    disk = readRoot(path);
    changed = disk ? [self mergeWithDisk:disk writing:NO] : NO;
    [stamp release];
    stamp = [fileStamp(path) copy];
    [self unlockFile:fd];
    return changed;
}

/* A streamed reply, a rename and a model change can all arrive within a
   second. Write once they settle rather than rewriting the file each time. */
- (void)markDirty
{
    if (dirty)
        return;
    dirty = YES;
    [self performSelector:@selector(flush) withObject:nil afterDelay:0.75];
}

- (void)flush
{
    NSMutableDictionary *root, *disk;
    NSString *error = nil;
    NSData *data;
    unsigned i;
    int fd;
    if (!dirty)
        return;
    dirty = NO;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(flush) object:nil];
    fd = [self lockFile];
    disk = readRoot(path);
    if (disk)
        [self mergeWithDisk:disk writing:YES];
    /* the chats this process changed move to a new revision */
    for (i = 0; i < [chats count]; i++) {
        NSMutableDictionary *chat = [chats objectAtIndex:i];
        NSArray *base = [baseline objectForKey:[chat objectForKey:@"id"]];
        if ([self chatChanged:chat]) {
            int old = [[chat objectForKey:@"rev"] intValue];
            if (base && [[base objectAtIndex:1] intValue] > old)
                old = [[base objectAtIndex:1] intValue];
            [chat setObject:[NSNumber numberWithInt:old + 1] forKey:@"rev"];
        }
    }
    root = [NSMutableDictionary dictionary];
    [root setObject:chats forKey:@"chats"];
    [root setObject:[NSNumber numberWithInt:next] forKey:@"next"];
    [root setObject:settings forKey:@"settings"];
    /* Binary plists are about half the size of XML and much faster to write.
       Loading reads either format. */
    data = [NSPropertyListSerialization dataFromPropertyList:root format:NSPropertyListBinaryFormat_v1_0
        errorDescription:&error];
    if (error) {
        NSLog(@"Tiger Build could not save chats: %@", error);
        [error release];
    }
    if (data) {
        NSFileManager *manager = [NSFileManager defaultManager];
        [manager createDirectoryAtPath:[path stringByDeletingLastPathComponent] attributes:nil];
        TBRollingBackup(path);
        if ([data writeToFile:path atomically:YES]) {
            [self rebaseline];
            [stamp release];
            stamp = [fileStamp(path) copy];
        }
    }
    [self unlockFile:fd];
}

@end

@implementation ModelCatalog

+ (ModelCatalog *)shared
{
    static ModelCatalog *catalog = nil;
    NSString *text;
    if (catalog)
        return catalog;
    catalog = [[ModelCatalog alloc] init];
    /* The copy saved from the relay last time, then the one built into the app. */
    text = [NSString stringWithContentsOfFile:[NSHomeDirectory()
        stringByAppendingPathComponent:@"Library/Application Support/Tiger Build/models.txt"]];
    if (![catalog loadText:text]) {
        text = [NSString stringWithContentsOfFile:TBResourcePath(@"models", @"txt")];
        if (![catalog loadText:text])
            [catalog loadText:@"provider\tgrok\tGrok\nmodel\tgrok\tgrok-4.7\t4.7\t1\nprovider\tlocal\tLocal\n"];
    }
    return catalog;
}

- (void)dealloc
{
    [providers release];
    [models release];
    [defaults release];
    [states release];
    [super dealloc];
}

- (BOOL)loadText:(NSString *)text
{
    NSMutableArray *newProviders = [NSMutableArray array];
    NSMutableDictionary *newModels = [NSMutableDictionary dictionary];
    NSMutableDictionary *newDefaults = [NSMutableDictionary dictionary];
    NSMutableDictionary *newStates = [NSMutableDictionary dictionary];
    int newChecking = 0;
    NSArray *lines;
    unsigned i;
    unsigned modelCount = 0;
    if (!text || [text length] == 0)
        return NO;
    lines = [text componentsSeparatedByString:@"\n"];
    for (i = 0; i < [lines count]; i++) {
        NSArray *parts = [[lines objectAtIndex:i] componentsSeparatedByString:@"\t"];
        NSString *kind;
        if ([parts count] == 2 && [[parts objectAtIndex:0] isEqualToString:@"checking"]) {
            newChecking = [[parts objectAtIndex:1] intValue];
            continue;
        }
        if ([parts count] < 3)
            continue;
        kind = [parts objectAtIndex:0];
        if ([kind isEqualToString:@"provider"]) {
            NSString *pid = [parts objectAtIndex:1];
            [newStates setObject:([parts count] > 3 ? [parts objectAtIndex:3] : @"ok") forKey:pid];
            [newProviders addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                pid, @"id", [parts objectAtIndex:2], @"title", nil]];
            if (![newModels objectForKey:pid])
                [newModels setObject:[NSMutableArray array] forKey:pid];
        } else if ([kind isEqualToString:@"model"] && [parts count] >= 5) {
            NSString *pid = [parts objectAtIndex:1];
            NSString *mid = [parts objectAtIndex:2];
            NSMutableArray *list = [newModels objectForKey:pid];
            if (!list) {
                list = [NSMutableArray array];
                [newModels setObject:list forKey:pid];
            }
            [list addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                mid, @"id", [parts objectAtIndex:3], @"title", nil]];
            if ([[parts objectAtIndex:4] isEqualToString:@"1"] || ![newDefaults objectForKey:pid])
                [newDefaults setObject:mid forKey:pid];
            modelCount++;
        }
    }
    /* No models at all is fine: someone may only use a local server. */
    (void)modelCount;
    if ([newProviders count] == 0)
        return NO;
    [providers release];
    providers = [newProviders retain];
    [models release];
    models = [newModels retain];
    [defaults release];
    defaults = [newDefaults retain];
    [states release];
    states = [newStates retain];
    checking = newChecking;
    return YES;
}

- (NSArray *)providers
{
    return providers;
}

- (NSString *)titleForProvider:(NSString *)provider
{
    unsigned i;
    for (i = 0; i < [providers count]; i++) {
        NSDictionary *item = [providers objectAtIndex:i];
        if ([[item objectForKey:@"id"] isEqualToString:provider])
            return [item objectForKey:@"title"];
    }
    return provider;
}

- (NSArray *)modelsForProvider:(NSString *)provider
{
    NSArray *list = [models objectForKey:provider];
    return list ? list : [NSArray array];
}

- (NSString *)defaultModelForProvider:(NSString *)provider
{
    NSString *model = [defaults objectForKey:provider];
    return model ? model : @"";
}

- (NSString *)stateForProvider:(NSString *)provider
{
    NSString *state = [states objectForKey:provider];
    return state ? state : @"ok";
}

- (BOOL)providerUsable:(NSString *)provider
{
    return [[self stateForProvider:provider] isEqualToString:@"ok"]
        && [[self modelsForProvider:provider] count] > 0;
}

- (int)checkingCount
{
    return checking;
}

- (BOOL)hasModel:(NSString *)model forProvider:(NSString *)provider
{
    NSArray *list = [self modelsForProvider:provider];
    unsigned i;
    for (i = 0; i < [list count]; i++) {
        if ([[[list objectAtIndex:i] objectForKey:@"id"] isEqualToString:model])
            return YES;
    }
    return NO;
}

@end

NSString *TBNumberText(double v)
{
    char text[40];
    if (v == (double)(long long)v && v < 1e15 && v > -1e15)
        snprintf(text, sizeof text, "%lld", (long long)v);
    else
        snprintf(text, sizeof text, "%.12g", v);
    return [NSString stringWithUTF8String:text];
}

void TBCivilFromDays(long long unixDays, int *year, int *month, int *day)
{
    long long z = unixDays + 719468, era = (z >= 0 ? z : z - 146096) / 146097, doe = z - era * 146097;
    long long yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365, doy = doe - (365 * yoe + yoe / 4 - yoe / 100), mp = (5 * doy + 2) / 153;
    *day = (int)(doy - (153 * mp + 2) / 5 + 1);
    *month = (int)(mp < 10 ? mp + 3 : mp - 9);
    *year = (int)(yoe + era * 400) + (*month <= 2);
}

static NSMutableSet *sudoKeys = nil;

NSString *TBSudoLocalKeyNew(void)
{
    NSString *key = [NSString stringWithFormat:@"%08x%08x%08x%08x", arc4random(), arc4random(), arc4random(), arc4random()];
    @synchronized([NSString class]) {
        if (!sudoKeys)
            sudoKeys = [[NSMutableSet alloc] init];
        [sudoKeys addObject:key];
    }
    return key;
}

void TBSudoLocalKeyForget(NSString *key)
{
    @synchronized([NSString class]) {
        [sudoKeys removeObject:key];
    }
}

BOOL TBSudoLocalKeyKnown(NSString *key)
{
    BOOL known;
    @synchronized([NSString class]) {
        known = key != nil && [sudoKeys containsObject:key];
    }
    return known;
}

NSData *TBBase64Decode(NSString *text)
{
    NSMutableData *out = [NSMutableData data];
    unsigned i, bits = 0, count = 0, padding = 0;
    for (i = 0; i < [text length]; i++) {
        unichar c = [text characterAtIndex:i];
        int v;
        if (c == ' ' || c == '\n' || c == '\r' || c == '\t')
            continue;
        if (c == '=') {
            padding++;
            continue;
        }
        if (padding)
            return nil;
        if (c >= 'A' && c <= 'Z') v = c - 'A';
        else if (c >= 'a' && c <= 'z') v = c - 'a' + 26;
        else if (c >= '0' && c <= '9') v = c - '0' + 52;
        else if (c == '+' || c == '-') v = 62;
        else if (c == '/' || c == '_') v = 63;
        else return nil;
        bits = (bits << 6) | v;
        if (++count == 4) {
            unsigned char b[3] = {(bits >> 16) & 255, (bits >> 8) & 255, bits & 255};
            [out appendBytes:b length:3];
            bits = 0;
            count = 0;
        }
    }
    if (count == 1)
        return nil;
    if (count == 2) {
        unsigned char b = (bits >> 4) & 255;
        [out appendBytes:&b length:1];
    } else if (count == 3) {
        unsigned char b[2] = {(bits >> 10) & 255, (bits >> 2) & 255};
        [out appendBytes:b length:2];
    }
    return out;
}

NSString *TBResourcePath(NSString *name, NSString *ext)
{
    NSString *path = [[NSBundle mainBundle] pathForResource:name ofType:ext];
    NSString *file = [name stringByAppendingPathExtension:ext];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *dirs = [NSArray arrayWithObjects:[NSString stringWithUTF8String:getenv("TB_RESOURCES") ? getenv("TB_RESOURCES") : "/nonexistent"],
        @"/Applications/Tiger Build.app/Contents/Resources", [NSHomeDirectory() stringByAppendingPathComponent:@"Applications/Tiger Build.app/Contents/Resources"], @".", nil];
    unsigned i;
    for (i = 0; !path && i < [dirs count]; i++) {
        NSString *p = [[dirs objectAtIndex:i] stringByAppendingPathComponent:file];
        if ([fm fileExistsAtPath:p])
            path = p;
    }
    return path;
}
