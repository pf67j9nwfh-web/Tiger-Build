#import "TBIntegrations.h"
#import "TBEngine.h"
#import "TBJSON.h"

static NSString *kServers = @"mcp_servers";

static NSArray *flagNames(void)
{
    return [NSArray arrayWithObjects:@"ppc_approval", @"consult_enabled", @"ppc_enabled", @"toolbox_enabled", @"search_enabled", @"grok_native_search", @"gemini_native_search", @"download_enabled", @"subagents_enabled", @"claude_thinking", nil];
}

static BOOL validServerId(NSString *name)
{
    unsigned i;
    if (![name isKindOfClass:[NSString class]] || [name length] < 1 || [name length] > 20)
        return NO;
    for (i = 0; i < [name length]; i++) {
        unichar c = [name characterAtIndex:i];
        BOOL letter = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
        if (!(letter || (i > 0 && ((c >= '0' && c <= '9') || c == '_'))))
            return NO;
    }
    return YES;
}

/* the servers, checked; raises with a reason for a bad one */
static NSArray *validated(id list, BOOL forceOff)
{
    NSMutableArray *clean = [NSMutableArray array];
    NSMutableSet *ids = [NSMutableSet set];
    unsigned i;
    if (list == nil)
        return clean;
    if (![list isKindOfClass:[NSArray class]] || [list count] > 24)
        TBFail(@"At most 24 MCP servers allowed.");
    for (i = 0; i < [list count]; i++) {
        id row = [list objectAtIndex:i];
        NSString *name, *command, *title, *description;
        NSArray *args;
        NSDictionary *env;
        NSEnumerator *each;
        id key;
        if (![row isKindOfClass:[NSDictionary class]])
            TBFail(@"Malformed server.");
        name = TBString(row, @"id");
        if (!validServerId(name) || [ids containsObject:name])
            TBFail(@"Server IDs must be unique letters/digits/underscore, max 20 characters.");
        command = TBString(row, @"command");
        if (!([command hasPrefix:@"/"] || [command hasPrefix:@"builtin:"] || [command hasPrefix:@"ssh:"] || [[command lowercaseString] hasPrefix:@"https://"] || [[command lowercaseString] hasPrefix:@"http://"]))
            TBFail(@"Use an absolute program path, ssh:user@address, or an http:// or https:// address.");
        args = TBValue(row, @"args") ? TBValue(row, @"args") : [NSArray array];
        if (![args isKindOfClass:[NSArray class]])
            TBFail(@"Arguments must be a string array.");
        {
            unsigned a;
            for (a = 0; a < [args count]; a++)
                if (![[args objectAtIndex:a] isKindOfClass:[NSString class]])
                    TBFail(@"Arguments must be a string array.");
        }
        env = TBValue(row, @"env") ? TBValue(row, @"env") : [NSDictionary dictionary];
        if (![env isKindOfClass:[NSDictionary class]])
            TBFail(@"Environment must be text key/value pairs.");
        each = [env keyEnumerator];
        while ((key = [each nextObject]))
            if (![key isKindOfClass:[NSString class]] || ![[env objectForKey:key] isKindOfClass:[NSString class]])
                TBFail(@"Environment must be text key/value pairs.");
        title = TBString(row, @"title");
        if ([title length] > 60)
            TBFail(@"A server name must be text of at most 60 characters.");
        description = TBTrim(TBString(row, @"description"));
        if ([description length] > 1000)
            description = [description substringToIndex:1000];
        [ids addObject:name];
        [clean addObject:[NSDictionary dictionaryWithObjectsAndKeys:name, @"id", TBTrim(title), @"title", command, @"command", args, @"args", env, @"env", description, @"description",
            [NSNumber numberWithBool:forceOff ? NO : TBTruth(row, @"enabled")], @"enabled", [NSNumber numberWithBool:TBTruth(row, @"approval")], @"approval", nil]];
    }
    return clean;
}

@implementation TBIntegrations

+ (NSArray *)servers
{
    NSString *json = [TBSettings valueForName:kServers];
    id list = [json length] ? TBJSONParseString(json, NULL) : nil;
    NSArray *out;
    NS_DURING
        out = [list isKindOfClass:[NSArray class]] ? validated(list, NO) : [NSArray array];
    NS_HANDLER
        out = [NSArray array];
    NS_ENDHANDLER
    return out;
}

+ (void)storeServers:(NSArray *)servers
{
    if (![TBSettings setValue:[servers count] ? TBJSONString(servers) : @"" forName:kServers])
        TBFail(@"The Keychain refused the server list. Unlock the login keychain and try again.");
}

+ (int)steps
{
    NSNumber *saved = [[NSUserDefaults standardUserDefaults] objectForKey:@"TBTool.max_tool_steps"];
    return saved ? [saved intValue] : 40;
}

+ (NSString *)provider
{
    NSString *p = [TBSettings valueForName:@"search_provider"];
    return [p isEqualToString:@"tavily"] ? @"tavily" : @"brave";
}

+ (NSDictionary *)publicConfig
{
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    unsigned i;
    for (i = 0; i < [flagNames() count]; i++)
        [out setObject:[NSNumber numberWithBool:[TBSettings flag:[flagNames() objectAtIndex:i]]] forKey:[flagNames() objectAtIndex:i]];
    [out setObject:[NSNumber numberWithInt:[self steps]] forKey:@"max_tool_steps"];
    [out setObject:[self provider] forKey:@"search_provider"];
    [out setObject:@"" forKey:@"search_api_key"];
    [out setObject:@"" forKey:@"tavily_api_key"];
    [out setObject:[NSNumber numberWithBool:[TBSettings hasValueForName:@"search_api_key"]] forKey:@"search_key_saved"];
    [out setObject:[NSNumber numberWithBool:[TBSettings hasValueForName:@"tavily_api_key"]] forKey:@"tavily_key_saved"];
    [out setObject:[self servers] forKey:@"servers"];
    [out setObject:[NSNumber numberWithBool:[[NSUserDefaults standardUserDefaults] boolForKey:@"TBExamplesInstalled"]] forKey:@"examples_installed"];
    return out;
}

+ (void)update:(NSDictionary *)incoming
{
    unsigned i;
    id steps = TBValue(incoming, @"max_tool_steps");
    NSString *provider = TBString(incoming, @"search_provider");
    NSArray *servers;
    if (![incoming isKindOfClass:[NSDictionary class]])
        TBFail(@"Configuration must be an object.");
    for (i = 0; i < [flagNames() count]; i++) {
        id v = TBValue(incoming, [flagNames() objectAtIndex:i]);
        if (v && (CFGetTypeID(v) != CFBooleanGetTypeID()))
            TBFail(@"%@ must be true or false.", [flagNames() objectAtIndex:i]);
    }
    if (steps && (![steps isKindOfClass:[NSNumber class]] || [steps intValue] < 0 || [steps intValue] > 1000))
        TBFail(@"Tool steps per reply must be a whole number from 1 to 1000, or 0 for no limit.");
    if ([provider length] && !([provider isEqualToString:@"brave"] || [provider isEqualToString:@"tavily"]))
        TBFail(@"Search provider must be brave or tavily.");
    servers = validated(TBValue(incoming, @"servers"), NO);
    for (i = 0; i < [flagNames() count]; i++) {
        id v = TBValue(incoming, [flagNames() objectAtIndex:i]);
        if (v)
            [TBSettings setFlag:[flagNames() objectAtIndex:i] value:[v boolValue]];
    }
    if (steps)
        [[NSUserDefaults standardUserDefaults] setInteger:[steps intValue] forKey:@"TBTool.max_tool_steps"];
    if ([provider length])
        [TBSettings setValue:provider forName:@"search_provider"];
    if (TBTruth(incoming, @"clear_search_key"))
        [TBSettings clearName:@"search_api_key"];
    else if ([TBString(incoming, @"search_api_key") length])
        [TBSettings setValue:TBString(incoming, @"search_api_key") forName:@"search_api_key"];
    if (TBTruth(incoming, @"clear_tavily_key"))
        [TBSettings clearName:@"tavily_api_key"];
    else if ([TBString(incoming, @"tavily_api_key") length])
        [TBSettings setValue:TBString(incoming, @"tavily_api_key") forName:@"tavily_api_key"];
    if (TBValue(incoming, @"servers"))
        [self storeServers:servers];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (NSDictionary *)exportConfig
{
    NSMutableDictionary *providers = [NSMutableDictionary dictionary];
    NSMutableDictionary *integrations = [NSMutableDictionary dictionaryWithDictionary:[self publicConfig]];
    NSArray *names = [NSArray arrayWithObjects:@"xai_api_key", @"openai_api_key", @"anthropic_api_key", @"anthropic_workspace_id", @"mistral_api_key", @"muse_api_key",
        @"gemini_api_key", @"local_api_key", @"local_url", nil];
    unsigned i;
    for (i = 0; i < [names count]; i++)
        [providers setObject:[TBSettings valueForName:[names objectAtIndex:i]] forKey:[names objectAtIndex:i]];
    [integrations setObject:[TBSettings valueForName:@"search_api_key"] forKey:@"search_api_key"];
    [integrations setObject:[TBSettings valueForName:@"tavily_api_key"] forKey:@"tavily_api_key"];
    return [NSDictionary dictionaryWithObjectsAndKeys:@"TigerBuildRelay-config", @"format", [NSNumber numberWithInt:1], @"version", providers, @"providers", integrations, @"integrations", nil];
}

+ (void)restore:(NSDictionary *)backup
{
    NSString *format = TBString(backup, @"format");
    NSDictionary *providers = TBDictionary(backup, @"providers");
    NSMutableDictionary *integrations = [NSMutableDictionary dictionaryWithDictionary:TBDictionary(backup, @"integrations")];
    NSArray *names = [NSArray arrayWithObjects:@"xai_api_key", @"openai_api_key", @"anthropic_api_key", @"anthropic_workspace_id", @"mistral_api_key", @"muse_api_key",
        @"gemini_api_key", @"local_api_key", @"local_url", nil];
    unsigned i;
    if (!([format isEqualToString:@"TigerBuildRelay-config"] || [format isEqualToString:@"TigerDesk-config"]) || TBInteger(backup, @"version") != 1)
        TBFail(@"Not a supported Tiger Build configuration backup.");
    if (![providers count] && !TBDictionary(backup, @"providers"))
        TBFail(@"Missing provider configuration.");
    for (i = 0; i < [names count]; i++) {
        id v = TBValue(providers, [names objectAtIndex:i]);
        if (v && ![v isKindOfClass:[NSString class]])
            TBFail(@"Provider fields must be text.");
    }
    /* a server is never started just because a file was imported */
    [integrations setObject:validated(TBValue(integrations, @"servers"), YES) forKey:@"servers"];
    [self update:integrations];
    for (i = 0; i < [names count]; i++) {
        NSString *v = TBString(providers, [names objectAtIndex:i]);
        if ([v length])
            [TBSettings setValue:v forName:[names objectAtIndex:i]];
    }
}

+ (NSArray *)catalogue
{
    NSMutableArray *rows = [NSMutableArray array];
    NSArray *servers = [self servers];
    unsigned i;
    for (i = 0; i < [servers count]; i++) {
        NSDictionary *s = [servers objectAtIndex:i];
        if (TBTruth(s, @"enabled"))
            [rows addObject:[NSDictionary dictionaryWithObjectsAndKeys:[@"mcp_" stringByAppendingString:TBString(s, @"id")], @"id",
                [TBString(s, @"title") length] ? TBString(s, @"title") : TBString(s, @"id"), @"title", [NSNumber numberWithBool:TBTruth(s, @"approval")], @"approval", [NSNumber numberWithBool:YES], @"default", nil]];
    }
    return rows;
}

+ (BOOL)serverApprovalForKey:(NSString *)key
{
    NSArray *servers = [self servers];
    unsigned i;
    for (i = 0; i < [servers count]; i++)
        if ([[@"mcp_" stringByAppendingString:TBString([servers objectAtIndex:i], @"id")] isEqualToString:key])
            return TBTruth([servers objectAtIndex:i], @"approval");
    return NO;
}

+ (void)installExamples
{
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSMutableArray *list;
    NSArray *have;
    NSArray *examples;
    unsigned i, e;
    NSMutableArray *given = [NSMutableArray arrayWithArray:[d arrayForKey:@"TBExamplesGiven"]];
    BOOL changed = NO;
    /* the first four were handed out once, before this list existed */
    if (![d arrayForKey:@"TBExamplesGiven"] && [d boolForKey:@"TBExamplesInstalled"])
        [given addObjectsFromArray:[NSArray arrayWithObjects:@"calc", @"notes", @"sysinfo", @"weather", nil]];
    have = [self servers];
    list = [NSMutableArray arrayWithArray:have];
    examples = [NSArray arrayWithObjects:
        [NSArray arrayWithObjects:@"calc", @"Calculator", [NSNumber numberWithBool:NO], nil],
        [NSArray arrayWithObjects:@"notes", @"Notebook", [NSNumber numberWithBool:YES], nil],
        [NSArray arrayWithObjects:@"sysinfo", @"System info", [NSNumber numberWithBool:NO], nil],
        [NSArray arrayWithObjects:@"weather", @"Weather (wttr.in)", [NSNumber numberWithBool:NO], nil],
        [NSArray arrayWithObjects:@"currency", @"Currency exchange rates", [NSNumber numberWithBool:NO], nil],
        [NSArray arrayWithObjects:@"inflation", @"US inflation (CPI-U)", [NSNumber numberWithBool:NO], nil], nil];
    for (e = 0; e < [examples count]; e++) {
        NSArray *x = [examples objectAtIndex:e];
        BOOL there = [given containsObject:[x objectAtIndex:0]];
        for (i = 0; i < [have count]; i++)
            if ([TBString([have objectAtIndex:i], @"id") isEqualToString:[x objectAtIndex:0]])
                there = YES;
        if (![given containsObject:[x objectAtIndex:0]]) {
            [given addObject:[x objectAtIndex:0]];
            changed = YES;
        }
        if (!there && [list count] < 24)
            [list addObject:[NSDictionary dictionaryWithObjectsAndKeys:[x objectAtIndex:0], @"id", [x objectAtIndex:1], @"title", [@"builtin:" stringByAppendingString:[x objectAtIndex:0]], @"command",
                [NSArray array], @"args", [NSDictionary dictionary], @"env", [NSNumber numberWithBool:YES], @"enabled", [x objectAtIndex:2], @"approval", nil]];
    }
    if (!changed)
        return;
    NS_DURING
        [self storeServers:list];
        [d setObject:given forKey:@"TBExamplesGiven"];
        [d setBool:YES forKey:@"TBExamplesInstalled"];
    NS_HANDLER
    NS_ENDHANDLER
}

@end
