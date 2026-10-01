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

TBChatLayout TBLayoutChatPane(float paneWidth, float paneHeight, float wanted, float statusHeight)
{
    TBChatLayout layout;
    float fieldW = paneWidth - 104;
    float maxField = paneHeight - 150;
    float transcriptY;
    float transcriptH;
    float buttonY;
    float top;
    if (statusHeight < 0)
        statusHeight = 0;
    if (statusHeight > TB_STATUS_MAX)
        statusHeight = TB_STATUS_MAX;
    top = statusHeight > 0 ? statusHeight + 4 : 0;
    if (fieldW < 80)
        fieldW = 80;
    if (maxField > TB_FIELD_MAX)
        maxField = TB_FIELD_MAX;
    if (maxField < TB_FIELD_MIN)
        maxField = TB_FIELD_MIN;
    if (wanted < TB_FIELD_MIN)
        wanted = TB_FIELD_MIN;
    if (wanted > maxField)
        wanted = maxField;
    transcriptY = 22 + wanted;
    transcriptH = paneHeight - 28 - top - transcriptY;
    if (transcriptH < 40)
        transcriptH = 40;
    buttonY = 14 + (wanted - 28) / 2;
    if (buttonY < 10)
        buttonY = 10;
    layout.fieldHeight = wanted;
    layout.input = NSMakeRect(8, 14, fieldW, wanted);
    layout.send = NSMakeRect(paneWidth - 88, buttonY, 76, 28);
    layout.transcript = NSMakeRect(8, transcriptY, paneWidth - 16, transcriptH);
    layout.context = NSMakeRect(8, paneHeight - 28 - top, paneWidth - 16, 18);
    layout.status = NSMakeRect(8, paneHeight - 10 - statusHeight, paneWidth - 16, statusHeight);
    return layout;
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
