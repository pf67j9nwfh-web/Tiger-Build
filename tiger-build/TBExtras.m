#import "TBExtras.h"
#import "TBLocalTools.h"
#import "TBEngine.h"
#import "TBIntegrations.h"
#import "TBSSH.h"
#import "TBBuiltin.h"
#import "TBMCP.h"
#import "TBMedia.h"
#import "TBOutputs.h"
#import "TBJSON.h"
#import "TBSupport.h"

static NSDictionary *function(NSString *name, NSString *description, NSArray *names, NSArray *descs, NSArray *required)
{
    NSMutableDictionary *props = [NSMutableDictionary dictionary];
    unsigned i;
    for (i = 0; i < [names count]; i++) {
        NSMutableDictionary *p = [NSMutableDictionary dictionaryWithObject:@"string" forKey:@"type"];
        if ([[descs objectAtIndex:i] length])
            [p setObject:[descs objectAtIndex:i] forKey:@"description"];
        [props setObject:p forKey:[names objectAtIndex:i]];
    }
    return [NSDictionary dictionaryWithObjectsAndKeys:@"function", @"type", name, @"name", description, @"description",
        [NSDictionary dictionaryWithObjectsAndKeys:@"object", @"type", props, @"properties", required, @"required", nil], @"parameters", nil];
}

static NSDictionary *result(NSString *output, BOOL failed, NSString *media)
{
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithObjectsAndKeys:output, @"output", [NSNumber numberWithBool:failed], @"failed", nil];
    if (media)
        [d setObject:media forKey:@"media"];
    return d;
}

/* ---- web search ---- */

static NSString *swap(NSString *text, NSString *from, NSString *to)
{
    return [[text componentsSeparatedByString:from] componentsJoinedByString:to];
}

static NSString *unescapeHTML(NSString *text)
{
    text = swap(text, @"&quot;", @"\"");
    text = swap(text, @"&#x27;", @"'");
    text = swap(text, @"&#39;", @"'");
    text = swap(text, @"&lt;", @"<");
    text = swap(text, @"&gt;", @">");
    text = swap(text, @"&nbsp;", @" ");
    return swap(text, @"&amp;", @"&");
}

static NSString *stripTags(NSString *html)
{
    NSMutableString *out = [NSMutableString string];
    BOOL inTag = NO;
    unsigned i;
    for (i = 0; i < [html length]; i++) {
        unichar c = [html characterAtIndex:i];
        if (c == '<')
            inTag = YES;
        else if (c == '>')
            inTag = NO;
        else if (!inTag)
            [out appendFormat:@"%C", c];
    }
    return TBTrim(unescapeHTML(out));
}

static NSString *percentEncode(NSString *text)
{
    NSMutableString *out = [NSMutableString string];
    NSData *bytes = [text dataUsingEncoding:NSUTF8StringEncoding];
    const unsigned char *b = [bytes bytes];
    unsigned i;
    for (i = 0; i < [bytes length]; i++) {
        unsigned char c = b[i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~')
            [out appendFormat:@"%c", c];
        else if (c == ' ')
            [out appendString:@"+"];
        else
            [out appendFormat:@"%%%02X", c];
    }
    return out;
}

static NSString *base(NSString *name, NSString *standard)
{
    NSString *over = [[NSUserDefaults standardUserDefaults] stringForKey:[@"TBSearchURL." stringByAppendingString:name]];
    return [over length] ? over : standard;
}

static NSData *get(NSString *url, NSArray *headers, NSData *body, int timeout, int *status, TBRun *run)
{
    return TBFetch(body ? @"POST" : @"GET", url, headers, body, timeout, status, run);
}

static NSArray *freeSearch(NSString *query, TBRun *run)
{
    int status;
    NSData *page = get(base(@"duckduckgo", @"https://html.duckduckgo.com/html/"),
        [NSArray arrayWithObjects:@"Content-Type", @"application/x-www-form-urlencoded", nil], [[@"q=" stringByAppendingString:percentEncode(query)] dataUsingEncoding:NSUTF8StringEncoding], 20, &status, run);
    NSString *html = status >= 200 && status < 300 ? [[[NSString alloc] initWithData:page encoding:NSUTF8StringEncoding] autorelease] : nil;
    NSMutableArray *rows = [NSMutableArray array];
    NSRange at = NSMakeRange(0, 0);
    while (html && [rows count] < 6) {
        NSRange mark, anchor, href, hrefEnd, open, close, next, snip;
        NSString *link, *title, *snippet = @"", *segment;
        mark = [html rangeOfString:@"class=\"result__a\"" options:0 range:NSMakeRange(NSMaxRange(at), [html length] - NSMaxRange(at))];
        if (mark.location == NSNotFound)
            break;
        anchor = [html rangeOfString:@"<a" options:NSBackwardsSearch range:NSMakeRange(0, mark.location)];
        href = [html rangeOfString:@"href=\"" options:0 range:NSMakeRange(mark.location, [html length] - mark.location)];
        at = mark;
        if (anchor.location == NSNotFound || href.location == NSNotFound)
            continue;
        hrefEnd = [html rangeOfString:@"\"" options:0 range:NSMakeRange(NSMaxRange(href), [html length] - NSMaxRange(href))];
        open = [html rangeOfString:@">" options:0 range:NSMakeRange(hrefEnd.location, [html length] - hrefEnd.location)];
        close = [html rangeOfString:@"</a>" options:0 range:NSMakeRange(NSMaxRange(open), [html length] - NSMaxRange(open))];
        if (hrefEnd.location == NSNotFound || open.location == NSNotFound || close.location == NSNotFound)
            break;
        link = unescapeHTML([html substringWithRange:NSMakeRange(NSMaxRange(href), hrefEnd.location - NSMaxRange(href))]);
        title = stripTags([html substringWithRange:NSMakeRange(NSMaxRange(open), close.location - NSMaxRange(open))]);
        {
            NSRange uddg = [link rangeOfString:@"uddg="];
            if (uddg.location != NSNotFound) {
                NSString *rest = [link substringFromIndex:NSMaxRange(uddg)];
                NSRange amp = [rest rangeOfString:@"&"];
                if (amp.location != NSNotFound)
                    rest = [rest substringToIndex:amp.location];
                link = [swap(rest, @"+", @"%20") stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
                if (!link)
                    link = rest;
            }
            if ([link hasPrefix:@"//"])
                link = [@"https:" stringByAppendingString:link];
        }
        next = [html rangeOfString:@"class=\"result__a\"" options:0 range:NSMakeRange(NSMaxRange(close), [html length] - NSMaxRange(close))];
        segment = [html substringWithRange:NSMakeRange(NSMaxRange(close), (next.location == NSNotFound ? [html length] : next.location) - NSMaxRange(close))];
        snip = [segment rangeOfString:@"class=\"result__snippet\""];
        if (snip.location != NSNotFound) {
            NSRange o = [segment rangeOfString:@">" options:0 range:NSMakeRange(NSMaxRange(snip), [segment length] - NSMaxRange(snip))];
            NSRange c = o.location == NSNotFound ? o : [segment rangeOfString:@"</a>" options:0 range:NSMakeRange(NSMaxRange(o), [segment length] - NSMaxRange(o))];
            if (o.location != NSNotFound && c.location != NSNotFound)
                snippet = stripTags([segment substringWithRange:NSMakeRange(NSMaxRange(o), c.location - NSMaxRange(o))]);
        }
        [rows addObject:[NSDictionary dictionaryWithObjectsAndKeys:title, @"title", link, @"url", snippet, @"description", nil]];
        at = close;
    }
    if (![rows count]) {
        /* DuckDuckGo limits automated callers now and then. Wikipedia always answers. */
        NSData *data = get([NSString stringWithFormat:@"%@?action=query&format=json&list=search&srsearch=%@&srlimit=6", base(@"wikipedia", @"https://en.wikipedia.org/w/api.php"), percentEncode(query)], nil, nil, 20, &status, run);
        id json = status >= 200 && status < 300 ? TBJSONParse(data, NULL) : nil;
        NSArray *found = TBArray(TBDictionary(json, @"query"), @"search");
        unsigned i;
        for (i = 0; i < [found count]; i++) {
            NSString *t = TBString([found objectAtIndex:i], @"title");
            [rows addObject:[NSDictionary dictionaryWithObjectsAndKeys:t, @"title",
                [@"https://en.wikipedia.org/wiki/" stringByAppendingString:percentEncode(swap(t, @" ", @"_"))], @"url", stripTags(TBString([found objectAtIndex:i], @"snippet")), @"description", nil]];
        }
    }
    if (![rows count])
        TBFail(@"The free search found nothing. Add a Brave or Tavily key in Tools settings for broader search.");
    return rows;
}

static NSComparisonResult pageOrder(id a, id b, void *context)
{
    long long x = TBInteger(a, @"index"), y = TBInteger(b, @"index");
    return x < y ? NSOrderedAscending : (x > y ? NSOrderedDescending : NSOrderedSame);
}

/* Gemini's own Google Search, asked as a separate request so it works with every model: the answer comes back with the pages it used.
   nil when it cannot be used (no key, or the service refused), and the ordinary search takes over. */
static NSString *geminiSearch(NSString *query, TBRun *run)
{
    NSString *key = [TBSettings valueForName:@"gemini_api_key"], *root = base(@"gemini-search", @"https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-latest:generateContent");
    int status = 0;
    NSData *data;
    id json, candidate, answer;
    NSMutableString *text = [NSMutableString string];
    NSMutableArray *links = [NSMutableArray array];
    NSArray *parts, *chunks;
    unsigned i;
    if (![key length])
        return nil;
    data = get(root, [NSArray arrayWithObjects:@"x-goog-api-key", key, @"Content-Type", @"application/json", nil],
        TBJSONData([NSDictionary dictionaryWithObjectsAndKeys:
            [NSArray arrayWithObject:[NSDictionary dictionaryWithObject:[NSArray arrayWithObject:[NSDictionary dictionaryWithObject:query forKey:@"text"]] forKey:@"parts"]], @"contents",
            [NSArray arrayWithObject:[NSDictionary dictionaryWithObject:[NSDictionary dictionary] forKey:@"google_search"]], @"tools", nil]), 45, &status, run);
    if (status < 200 || status >= 300)
        return nil;
    json = TBJSONParse(data, NULL);
    candidate = [TBArray(json, @"candidates") count] ? [TBArray(json, @"candidates") objectAtIndex:0] : nil;
    parts = TBArray(TBDictionary(candidate, @"content"), @"parts");
    for (i = 0; i < [parts count]; i++)
        [text appendString:TBString([parts objectAtIndex:i], @"text")];
    if (![TBTrim(text) length])
        return nil;
    chunks = TBArray(TBDictionary(candidate, @"groundingMetadata"), @"groundingChunks");
    for (i = 0; i < [chunks count]; i++) {
        id web = TBDictionary([chunks objectAtIndex:i], @"web");
        if ([TBString(web, @"uri") length])
            [links addObject:[NSDictionary dictionaryWithObjectsAndKeys:TBString(web, @"title"), @"title", TBString(web, @"uri"), @"url", nil]];
    }
    answer = [NSDictionary dictionaryWithObjectsAndKeys:@"Google Search through Gemini", @"source", text, @"answer", links, @"sources", nil];
    return TBJSONString(answer);
}

static NSString *search(NSString *query, TBRun *run)
{
    NSString *provider = [[TBSettings valueForName:@"search_provider"] isEqualToString:@"tavily"] ? @"tavily" : @"brave";
    NSString *key = [TBSettings valueForName:[provider isEqualToString:@"tavily"] ? @"tavily_api_key" : @"search_api_key"];
    int status;
    NSData *data;
    id json;
    NSMutableArray *rows = [NSMutableArray array];
    unsigned i;
    if (![TBSettings flag:@"search_enabled"])
        TBFail(@"Web search is turned off in the tool settings.");
    if (![query isKindOfClass:[NSString class]] || ![TBTrim(query) length] || [query length] > 1500)
        TBFail(@"Supply a query of 1-1500 characters.");
    if (![key length])
        return TBJSONString(freeSearch(query, run));
    if ([provider isEqualToString:@"tavily"]) {
        data = get(base(@"tavily", @"https://api.tavily.com/search"), [NSArray arrayWithObjects:@"Authorization", [@"Bearer " stringByAppendingString:key], @"Content-Type", @"application/json", nil],
            TBJSONData([NSDictionary dictionaryWithObjectsAndKeys:query, @"query", [NSNumber numberWithInt:5], @"max_results", @"basic", @"search_depth", [NSNumber numberWithBool:NO], @"include_answer", nil]), 25, &status, run);
        json = status >= 200 && status < 300 ? TBJSONParse(data, NULL) : nil;
        for (i = 0; i < [TBArray(json, @"results") count]; i++) {
            id item = [TBArray(json, @"results") objectAtIndex:i];
            [rows addObject:[NSDictionary dictionaryWithObjectsAndKeys:TBString(item, @"title"), @"title", TBString(item, @"url"), @"url", TBString(item, @"content"), @"description", nil]];
        }
    } else {
        data = get([NSString stringWithFormat:@"%@?q=%@&count=5", base(@"brave", @"https://api.search.brave.com/res/v1/web/search"), percentEncode(query)],
            [NSArray arrayWithObjects:@"X-Subscription-Token", key, @"Accept", @"application/json", nil], nil, 20, &status, run);
        json = status >= 200 && status < 300 ? TBJSONParse(data, NULL) : nil;
        for (i = 0; i < [TBArray(TBDictionary(json, @"web"), @"results") count]; i++) {
            id item = [TBArray(TBDictionary(json, @"web"), @"results") objectAtIndex:i];
            [rows addObject:[NSDictionary dictionaryWithObjectsAndKeys:stripTags(TBString(item, @"title")), @"title", TBString(item, @"url"), @"url", stripTags(TBString(item, @"description")), @"description", nil]];
        }
    }
    if (status >= 200 && status < 300)
        return TBJSONString(rows);
    /* A rejected or used-up key should not leave the model without search. */
    if (status == 401 || status == 402 || status == 403 || status == 429)
        return TBJSONString([NSDictionary dictionaryWithObjectsAndKeys:[NSString stringWithFormat:@"The %@ key was refused (HTTP %d), so the free search was used. Fix the key in Tools settings.", provider, status], @"note", freeSearch(query, run), @"results", nil]);
    TBFail(@"The search service answered HTTP %d.", status);
    return nil;
}

static NSString *imageSearch(NSString *query, TBRun *run)
{
    NSString *provider = [[TBSettings valueForName:@"search_provider"] isEqualToString:@"tavily"] ? @"tavily" : @"brave";
    NSMutableArray *rows = [NSMutableArray array];
    int status;
    NSData *data;
    id json;
    unsigned i;
    if (![TBSettings flag:@"search_enabled"])
        TBFail(@"Web search is turned off in the tool settings.");
    if (![query isKindOfClass:[NSString class]] || ![TBTrim(query) length] || [query length] > 500)
        TBFail(@"Supply a query of 1-500 characters.");
    if ([provider isEqualToString:@"brave"] && [[TBSettings valueForName:@"search_api_key"] length]) {
        data = get([NSString stringWithFormat:@"%@?q=%@&count=8", base(@"brave-images", @"https://api.search.brave.com/res/v1/images/search"), percentEncode(query)],
            [NSArray arrayWithObjects:@"X-Subscription-Token", [TBSettings valueForName:@"search_api_key"], @"Accept", @"application/json", nil], nil, 20, &status, run);
        json = status >= 200 && status < 300 ? TBJSONParse(data, NULL) : nil;
        for (i = 0; i < [TBArray(json, @"results") count]; i++) {
            id item = [TBArray(json, @"results") objectAtIndex:i];
            NSString *image = [TBString(TBDictionary(item, @"properties"), @"url") length] ? TBString(TBDictionary(item, @"properties"), @"url") : TBString(TBDictionary(item, @"thumbnail"), @"src");
            if ([image length])
                [rows addObject:[NSDictionary dictionaryWithObjectsAndKeys:TBString(item, @"title"), @"title", image, @"image_url", TBString(item, @"url"), @"page_url", nil]];
        }
    } else if ([provider isEqualToString:@"tavily"] && [[TBSettings valueForName:@"tavily_api_key"] length]) {
        data = get(base(@"tavily", @"https://api.tavily.com/search"), [NSArray arrayWithObjects:@"Authorization", [@"Bearer " stringByAppendingString:[TBSettings valueForName:@"tavily_api_key"]], @"Content-Type", @"application/json", nil],
            TBJSONData([NSDictionary dictionaryWithObjectsAndKeys:query, @"query", [NSNumber numberWithInt:3], @"max_results", [NSNumber numberWithBool:YES], @"include_images", [NSNumber numberWithBool:YES], @"include_image_descriptions", nil]), 25, &status, run);
        json = status >= 200 && status < 300 ? TBJSONParse(data, NULL) : nil;
        for (i = 0; i < [TBArray(json, @"images") count]; i++) {
            id item = [TBArray(json, @"images") objectAtIndex:i];
            if ([item isKindOfClass:[NSDictionary class]])
                [rows addObject:[NSDictionary dictionaryWithObjectsAndKeys:TBString(item, @"description"), @"title", TBString(item, @"url"), @"image_url", nil]];
            else if ([item isKindOfClass:[NSString class]])
                [rows addObject:[NSDictionary dictionaryWithObject:item forKey:@"image_url"]];
        }
    }
    if (![rows count]) {
        /* Wikimedia Commons: free, no key, pictures that are fine to show. */
        data = get([NSString stringWithFormat:@"%@?action=query&format=json&generator=search&gsrnamespace=6&gsrsearch=%@&gsrlimit=12&prop=imageinfo&iiprop=url%%7Cmime&iiurlwidth=640",
            base(@"commons", @"https://commons.wikimedia.org/w/api.php"), percentEncode(query)], nil, nil, 20, &status, run);
        json = status >= 200 && status < 300 ? TBJSONParse(data, NULL) : nil;
        {
            NSDictionary *pages = TBDictionary(TBDictionary(json, @"query"), @"pages");
            NSArray *sorted = [[pages allValues] sortedArrayUsingFunction:pageOrder context:NULL];
            for (i = 0; i < [sorted count] && [rows count] < 8; i++) {
                id page = [sorted objectAtIndex:i];
                NSArray *infos = TBArray(page, @"imageinfo");
                id info = [infos count] ? [infos objectAtIndex:0] : [NSDictionary dictionary];
                NSString *mime = TBString(info, @"mime");
                if (([mime isEqualToString:@"image/jpeg"] || [mime isEqualToString:@"image/png"] || [mime isEqualToString:@"image/gif"]) && [TBString(info, @"thumburl") length])
                    [rows addObject:[NSDictionary dictionaryWithObjectsAndKeys:swap(TBString(page, @"title"), @"File:", @""), @"title", TBString(info, @"thumburl"), @"image_url", TBString(info, @"descriptionurl"), @"page_url", nil]];
            }
        }
    }
    if (![rows count])
        TBFail(@"No pictures found for that search.");
    return TBJSONString([rows count] > 8 ? [rows subarrayWithRange:NSMakeRange(0, 8)] : rows);
}

@implementation TBExtras

- (id)initWithRun:(TBRun *)r
{
    self = [super init];
    run = [r retain];
    clients = [[NSMutableDictionary alloc] init];
    routes = [[NSMutableDictionary alloc] init];
    owners = [[NSMutableDictionary alloc] init];
    offered = [[NSMutableSet alloc] init];
    errors = [[NSMutableArray alloc] init];
    return self;
}

- (void)dealloc
{
    [self close];
    [run release];
    [clients release];
    [routes release];
    [owners release];
    [offered release];
    [errors release];
    [lastProvider release];
    [knowledgeRoot release];
    [super dealloc];
}

- (NSArray *)errors { return errors; }

- (void)setKnowledgeRoot:(NSString *)root
{
    [knowledgeRoot release];
    knowledgeRoot = [root copy];
}

- (NSArray *)auxiliaryForProvider:(NSString *)provider skip:(NSSet *)skip
{
    NSMutableArray *tools = [NSMutableArray array];
    BOOL native = [provider isEqualToString:@"grok"] && [TBSettings flag:@"grok_native_search"];
    if (![skip containsObject:@"toolbox"]) {
        [tools addObject:function(@"agent_save_file",
            @"Hand the person a file to save on their Mac: a new document, script, data file, or the complete changed version of a file they attached. Give the whole content. "
            "They get a Save As button in the chat. Use this instead of pasting long files into the reply when they ask for a file. A name ending in .docx, .xlsx or .pdf makes a real Word, "
            "Excel or PDF file: for .docx and .pdf give plain text (# headings, - bullets, **bold**, | tables | work); for .xlsx give rows separated by new lines and cells by tabs or commas.",
            [NSArray arrayWithObjects:@"name", @"content", @"content_base64", nil],
            [NSArray arrayWithObjects:@"File name with extension, for example report.docx, data.xlsx, notes.md or fixed.py.", @"The complete text of the file.",
                @"Instead of content: the file's bytes as base64, for a binary file such as an image (up to 8 MB).", nil], [NSArray arrayWithObject:@"name"])];
        if ([TBSettings flag:@"toolbox_enabled"]) {
            [tools addObject:function(@"agent_current_time", @"Current UTC date and time.", [NSArray array], [NSArray array], [NSArray array])];
            [tools addObject:function(@"agent_notes_read", @"Read persistent agent scratch notes.", [NSArray array], [NSArray array], [NSArray array])];
            [tools addObject:function(@"agent_notes_write", @"Replace persistent agent scratch notes. Never store credentials.", [NSArray arrayWithObject:@"text"], [NSArray arrayWithObject:@""], [NSArray arrayWithObject:@"text"])];
        }
    }
    if ([TBSettings flag:@"search_enabled"] && !native && ![skip containsObject:@"search"]) {
        [tools addObject:function(@"agent_web_search", @"Search the web. Returns titles, links and snippets, not full pages.", [NSArray arrayWithObject:@"query"], [NSArray arrayWithObject:@""], [NSArray arrayWithObject:@"query"])];
        [tools addObject:function(@"agent_image_search", @"Find pictures on the web. Returns image addresses with titles and the pages they come from. Then call agent_show_image to put one in the chat.",
            [NSArray arrayWithObject:@"query"], [NSArray arrayWithObject:@""], [NSArray arrayWithObject:@"query"])];
        [tools addObject:function(@"agent_show_image", @"Download a picture from a web address (an image_url from agent_image_search, or any direct link to a JPEG, PNG or GIF) and show it to the person in the chat. Each call shows one picture.",
            [NSArray arrayWithObject:@"url"], [NSArray arrayWithObject:@""], [NSArray arrayWithObject:@"url"])];
    }
    if ([TBSettings flag:@"search_enabled"] && ![skip containsObject:@"search"])
        [tools addObject:function(@"agent_read_page", @"Read a web page: give its address (starting with http:// or https://) and get the page's text (the first 40,000 characters). Use it for a link the person pasted or one from a search result. Only public web pages can be read.",
            [NSArray arrayWithObject:@"url"], [NSArray arrayWithObject:@"The web address of the page."], [NSArray arrayWithObject:@"url"])];
    if ([knowledgeRoot length] && ![skip containsObject:@"knowledge"]) {
        [tools addObject:function(@"knowledge_search", @"Search the person's knowledge folder for this workspace (their own notes and documents). Returns the best matching passages with the file they came from. Use it when a question may be answered by their documents.",
            [NSArray arrayWithObject:@"query"], [NSArray arrayWithObject:@"The words to look for."], [NSArray arrayWithObject:@"query"])];
        [tools addObject:function(@"knowledge_open", @"Read a whole file from the knowledge folder (the first 30,000 characters), by the path that knowledge_search showed.",
            [NSArray arrayWithObject:@"path"], [NSArray arrayWithObject:@"The path inside the knowledge folder."], [NSArray arrayWithObject:@"path"])];
    }
    if ([skip containsObject:@"macapps"] == NO) {
        [tools addObject:function(@"mac_calendar_events", @"List the events in this Mac's Calendar (iCal) from a few days ago to some days ahead. Read only. Opens the Calendar application if it is not running.",
            [NSArray arrayWithObjects:@"days", @"days_back", nil], [NSArray arrayWithObjects:@"How many days ahead to list (default 7, at most 60).", @"How many days back to include (default 0, at most 30).", nil], [NSArray array])];
        [tools addObject:function(@"mac_contacts_search", @"Find people in this Mac's Contacts (Address Book) whose name contains some words, with their emails and phone numbers. Read only.",
            [NSArray arrayWithObject:@"query"], [NSArray arrayWithObject:@"Part of the person's name."], [NSArray arrayWithObject:@"query"])];
        [tools addObject:function(@"mac_mail_unread", @"List the newest unread messages in this Mac's Mail inbox: date, sender and subject only, not the bodies. Read only. Opens Mail if it is not running.",
            [NSArray array], [NSArray array], [NSArray array])];
    }
    if ([TBSettings flag:@"download_enabled"] && [skip containsObject:@"download"] == NO)
        [tools addObject:function(@"agent_download_file", @"Download a file from an https address on the internet (up to 50 MB) and give it to the person with a Save As button. The connection uses TLS and the server's certificate is checked. "
            "Say where it came from and its SHA-256 afterwards. Only download what the person asked for.",
            [NSArray arrayWithObjects:@"url", @"name", nil], [NSArray arrayWithObjects:@"The https address of the file.", @"Optional file name to save it as.", nil], [NSArray arrayWithObject:@"url"])];
    return tools;
}

- (NSString *)aliasFor:(NSString *)serverId tool:(NSString *)original
{
    NSMutableString *clean = [NSMutableString string];
    unsigned i;
    for (i = 0; i < [original length]; i++) {
        unichar c = [original characterAtIndex:i];
        BOOL ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
        [clean appendString:ok ? [NSString stringWithFormat:@"%C", c] : @"_"];
    }
    return [NSString stringWithFormat:@"mcp_%@_%@", serverId, clean];
}

- (NSArray *)definitionsForProvider:(NSString *)provider skip:(NSSet *)skip
{
    [lastProvider release];
    lastProvider = [provider copy];
    NSMutableArray *tools = [NSMutableArray arrayWithArray:[self auxiliaryForProvider:provider skip:skip]];
    NSArray *servers = [TBIntegrations servers];
    unsigned i, t;
    for (i = 0; i < [tools count]; i++) {
        NSString *n = TBString([tools objectAtIndex:i], @"name");
        [owners setObject:([n isEqualToString:@"agent_web_search"] || [n isEqualToString:@"agent_image_search"] || [n isEqualToString:@"agent_show_image"] || [n isEqualToString:@"agent_read_page"]) ? @"search"
            : ([n isEqualToString:@"agent_download_file"] ? @"download" : ([n hasPrefix:@"knowledge_"] ? @"knowledge" : ([n hasPrefix:@"mac_"] ? @"macapps" : @"toolbox"))) forKey:n];
    }
    for (i = 0; i < [servers count]; i++) {
        NSDictionary *server = [servers objectAtIndex:i];
        NSString *sid = TBString(server, @"id"), *command = TBString(server, @"command");
        NSString *key = [@"mcp_" stringByAppendingString:sid];
        id client = nil, listed;
        if (!TBTruth(server, @"enabled") || [skip containsObject:key])
            continue;
        @try {
            if ([command hasPrefix:@"builtin:"]) {
                NSString *name = [command substringFromIndex:8];
                if (![TBBuiltin knows:name])
                    TBFail(@"Unknown built-in server %@.", name);
                listed = [TBBuiltin listTools:name];
            } else {
                NSDictionary *env = TBDictionary(server, @"env");
                if ([[command lowercaseString] hasPrefix:@"http://"] || [[command lowercaseString] hasPrefix:@"https://"])
                    client = [TBMCPHTTPClient clientWithURL:command token:TBString(env, @"MCP_AUTH_TOKEN")];
                else if ([command hasPrefix:@"ssh:"]) {
                    NSString *problem = nil;
                    NSArray *remote = TBArray(server, @"args");
                    NSArray *ssh = [TBSSH argumentsForTarget:[command substringFromIndex:4] remote:[remote count] ? [remote componentsJoinedByString:@" "] : nil problem:&problem];
                    if (!ssh)
                        TBFail(@"%@", problem);
                    client = [TBMCPClient clientWithPath:[TBSSH programForTarget:[command substringFromIndex:4]] arguments:ssh environment:nil label:sid];
                } else
                    client = [TBMCPClient clientWithPath:command arguments:TBArray(server, @"args") environment:env label:sid];
                [run attach:client];
                [client start];
                /* another computer's sudo: only a chat with the sudo item ticked sends the key its owner gave (a line TB_SUDO_KEY=... in the server's
                   Environment); it goes over standard input, not in the ssh command, where other programs could read it */
                if ([command hasPrefix:@"ssh:"] && ![skip containsObject:@"sudo"] && [TBString(TBDictionary(server, @"env"), @"TB_SUDO_KEY") length])
                    [client notify:@"tb/sudo-key" params:[NSDictionary dictionaryWithObject:TBString(TBDictionary(server, @"env"), @"TB_SUDO_KEY") forKey:@"key"]];
                listed = [client request:@"tools/list" params:[NSDictionary dictionary] timeout:20];
                [clients setObject:client forKey:sid];
            }
            {
                NSArray *functions = TBMCPFunctionTools(listed);
                for (t = 0; t < [functions count]; t++) {
                    NSDictionary *f = [functions objectAtIndex:t];
                    NSString *original = TBString(f, @"name");
                    NSString *alias = [self aliasFor:sid tool:original];
                    NSMutableDictionary *copy;
                    if ([alias length] > 64 || [routes objectForKey:alias])
                        continue;
                    [routes setObject:[NSArray arrayWithObjects:sid, original, nil] forKey:alias];
                    [owners setObject:key forKey:alias];
                    copy = [NSMutableDictionary dictionaryWithDictionary:f];
                    [copy setObject:alias forKey:@"name"];
                    [copy setObject:[NSString stringWithFormat:@"[MCP %@%@] %@", sid, [TBString(server, @"description") length] ? [@": " stringByAppendingString:TBString(server, @"description")] : @"", TBString(f, @"description")] forKey:@"description"];
                    [tools addObject:copy];
                }
            }
        } @catch (NSException *exception) {
            if ([[exception name] isEqualToString:TBStoppedException])
                @throw;
            NSString *tail = [client respondsToSelector:@selector(stderrText)] ? TBTrim([client stderrText]) : @"";
            if (client) {
                [run detach:client];
                [client close];
            }
            [errors addObject:[NSString stringWithFormat:@"%@: %@%@", sid, [exception reason], [tail length] ? [@" " stringByAppendingString:tail] : @""]];
        }
    }
    [offered removeAllObjects];
    for (i = 0; i < [tools count]; i++)
        [offered addObject:TBString([tools objectAtIndex:i], @"name")];
    return tools;
}

- (BOOL)handles:(NSString *)name
{
    return [routes objectForKey:name] != nil || [owners objectForKey:name] != nil;
}

- (NSString *)ownerOf:(NSString *)name
{
    return [owners objectForKey:name];
}

- (NSString *)notesFile
{
    NSString *folder = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Tiger Build"];
    [[NSFileManager defaultManager] createDirectoryAtPath:[folder stringByDeletingLastPathComponent] attributes:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:folder attributes:nil];
    return [folder stringByAppendingPathComponent:@"agent-notes.txt"];
}

- (NSDictionary *)call:(NSString *)name arguments:(NSDictionary *)args
{
    @try {
        NSArray *route = [routes objectForKey:name];
        if (![offered containsObject:name])
            TBFail(@"Tool was not enabled or advertised for this request.");
        if (route) {
            NSString *sid = [route objectAtIndex:0], *original = [route objectAtIndex:1];
            id client = [clients objectForKey:sid];
            if (!client) {
                NSString *builtin = nil;
                unsigned i;
                NSArray *servers = [TBIntegrations servers];
                for (i = 0; i < [servers count]; i++)
                    if ([TBString([servers objectAtIndex:i], @"id") isEqualToString:sid] && [TBString([servers objectAtIndex:i], @"command") hasPrefix:@"builtin:"])
                        builtin = [TBString([servers objectAtIndex:i], @"command") substringFromIndex:8];
                if (!builtin)
                    TBFail(@"The server %@ is not running.", sid);
                return result([TBBuiltin call:original arguments:args server:builtin run:run], NO, nil);
            }
            {
                id reply = [client request:@"tools/call" params:[NSDictionary dictionaryWithObjectsAndKeys:original, @"name", args, @"arguments", nil] timeout:90];
                NSString *text = TBMCPResultText(reply);
                NSArray *images = TBMCPResultImages(reply);
                if (TBTruth(reply, @"isError"))
                    TBFail(@"%@", text);
                (void)images;
                return result(text, NO, nil);
            }
        }
        if ([name isEqualToString:@"agent_save_file"]) {
            NSString *stored = [TBOutputs saveName:TBString(args, @"name") content:TBValue(args, @"content") base64:TBValue(args, @"content_base64")];
            return result(@"The file is now in the chat with a Save As button. Do not paste it again.", NO, [@"file " stringByAppendingString:stored]);
        }
        if ([name isEqualToString:@"agent_download_file"]) {
            NSDictionary *got = [TBMedia downloadURL:TBString(args, @"url") name:TBString(args, @"name") run:run];
            return result([NSString stringWithFormat:@"Downloaded %@ (%lu bytes, %@) from %@. SHA-256 %@. The file is now in the chat with a Save As button.",
                [got objectForKey:@"name"], [[got objectForKey:@"size"] unsignedLongValue], [[got objectForKey:@"type"] length] ? [got objectForKey:@"type"] : @"unknown type", [got objectForKey:@"url"], [got objectForKey:@"sha256"]],
                NO, [@"file " stringByAppendingString:[got objectForKey:@"stored"]]);
        }
        if ([name isEqualToString:@"agent_read_page"])
            return result([TBLocalTools readPage:TBString(args, @"url") run:run], NO, nil);
        if ([name isEqualToString:@"knowledge_search"])
            return result([TBLocalTools knowledgeSearch:TBString(args, @"query") root:knowledgeRoot], NO, nil);
        if ([name isEqualToString:@"knowledge_open"])
            return result([TBLocalTools knowledgeOpen:TBString(args, @"path") root:knowledgeRoot], NO, nil);
        if ([TBLocalTools isMacAppsTool:name])
            return result([TBLocalTools macAppsTool:name arguments:args], NO, nil);
        if ([name isEqualToString:@"agent_show_image"]) {
            NSString *file = [TBMedia fetchImage:TBString(args, @"url")];
            return result(@"The picture is now shown in the chat.", NO, [@"image " stringByAppendingString:file]);
        }
        if ([name isEqualToString:@"agent_web_search"])
        {
            NSString *answer = nil;
            if ([lastProvider isEqualToString:@"gemini"] && [TBSettings flag:@"gemini_native_search"] && [TBSettings flag:@"search_enabled"])
                answer = geminiSearch(TBString(args, @"query"), run);
            return result(answer ? answer : search(TBString(args, @"query"), run), NO, nil);
        }
        if ([name isEqualToString:@"agent_image_search"])
            return result(imageSearch(TBString(args, @"query"), run), NO, nil);
        if ([name isEqualToString:@"agent_current_time"]) {
            NSDateFormatter *f = [[[NSDateFormatter alloc] init] autorelease];
            [f setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss'+00:00'"];
            [f setTimeZone:[NSTimeZone timeZoneWithName:@"UTC"]];
            return result([f stringFromDate:[NSDate date]], NO, nil);
        }
        if ([name isEqualToString:@"agent_notes_read"]) {
            NSString *text = [NSString stringWithContentsOfFile:[self notesFile] encoding:NSUTF8StringEncoding error:NULL];
            return result([text length] ? ([text length] > 20000 ? [text substringToIndex:20000] : text) : @"No notes yet.", NO, nil);
        }
        if ([name isEqualToString:@"agent_notes_write"]) {
            NSString *text = TBString(args, @"text");
            if (![TBValue(args, @"text") isKindOfClass:[NSString class]] || [text length] > 20000)
                TBFail(@"Notes limited to 20000 characters.");
            if (![text writeToFile:[self notesFile] atomically:YES encoding:NSUTF8StringEncoding error:NULL])
                TBFail(@"The notes could not be saved.");
            return result(@"Notes saved.", NO, nil);
        }
        TBFail(@"Unknown tool.");
    } @catch (NSException *exception) {
        if ([[exception name] isEqualToString:TBStoppedException])
            @throw;
        return result([@"error: " stringByAppendingString:[exception reason] ? [exception reason] : @"the tool failed"], YES, nil);
    }
    return nil;
}

- (void)close
{
    NSEnumerator *each = [clients objectEnumerator];
    id client;
    while ((client = [each nextObject])) {
        [run detach:client];
        [client close];
    }
    [clients removeAllObjects];
}

@end
