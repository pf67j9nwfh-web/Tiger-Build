#import "TBSupport.h"

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
    float sendW = 76;
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
    if ([kind isEqualToString:@"image"])
        return [NSString stringWithFormat:@"[The person attached a picture named \"%@\". A copy is on their Mac at %@.%@]",
            name, [file objectForKey:@"path"], [file objectForKey:@"note"] ? [@" " stringByAppendingString:[file objectForKey:@"note"]] : @""];
    body = TBReadTextFile([file objectForKey:@"path"], TB_ATTACH_TEXT_MAX, &truncated);
    if (!body)
        return [NSString stringWithFormat:@"[The person attached a file named \"%@\", but it is no longer available on this Mac.]", name];
    return [NSString stringWithFormat:@"[The person attached a file named \"%@\". Its contents%@ follow. A text copy is on their Mac at %@.%@]\n\n%@\n\n[End of \"%@\".]",
        name, truncated ? @" (only the first part; the file is longer)" : @"", [file objectForKey:@"path"],
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

NSString *TBStoreChangedNotification = @"TBStoreChanged";
static NSMutableDictionary *openStores = nil;

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

- (id)initWithPath:(NSString *)file
{
    NSData *data;
    NSString *error = nil;
    id root;
    NSArray *saved;
    unsigned i;
    int highest = 0;
    self = [super init];
    if (!self)
        return nil;
    path = [file copy];
    chats = [[NSMutableArray alloc] init];
    settings = [[NSMutableDictionary alloc] init];
    data = [NSData dataWithContentsOfFile:path];
    if (data) {
        root = [NSPropertyListSerialization propertyListFromData:data mutabilityOption:NSPropertyListMutableContainers
            format:NULL errorDescription:&error];
        if (error)
            [error release];
        if ([root isKindOfClass:[NSDictionary class]]) {
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
    return self;
}

- (void)dealloc
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [path release];
    [chats release];
    [settings release];
    [super dealloc];
}

- (NSString *)path { return path; }
- (NSMutableArray *)chats { return chats; }
- (NSMutableDictionary *)settings { return settings; }
- (int)next { return next; }
- (void)setNext:(int)value { next = value; }

- (int)takeNextId
{
    int value = next;
    next++;
    return value;
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
    NSMutableDictionary *root;
    NSString *error = nil;
    NSData *data;
    if (!dirty)
        return;
    dirty = NO;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(flush) object:nil];
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
        [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent] attributes:nil];
        [data writeToFile:path atomically:YES];
    }
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
        text = [NSString stringWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"models" ofType:@"txt"]];
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
