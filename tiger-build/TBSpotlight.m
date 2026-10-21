#import "TBSpotlight.h"
#import "TBSupport.h"
#import "EngineRequest.h"

#define MAX_TEXT 300000

static NSString *kEnabled = @"TBSpotlightIndex";
static NSMutableDictionary *written;      /* "<workspace>|<id>" -> what was written, so a chat is rewritten only when it changed */
static NSMutableSet *pending;             /* stores waiting for the quiet moment */

/* The workspace a store file holds: chats.plist is Default, workspaces/NAME.plist is NAME. */
static NSString *workspaceOfPath(NSString *path)
{
    NSString *base = [[path lastPathComponent] stringByDeletingPathExtension];
    return [base isEqualToString:@"chats"] ? @"Default" : base;
}

static NSString *folderFor(NSString *workspace)
{
    return [[[EngineRequest supportDir] stringByAppendingPathComponent:@"Spotlight"] stringByAppendingPathComponent:workspace];
}

static NSString *importerSource(void)
{
    return [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"TigerBuild.mdimporter"];
}

static NSString *importerInstalled(void)
{
    return [[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Spotlight"] stringByAppendingPathComponent:@"TigerBuild.mdimporter"];
}

static void runTool(NSString *tool, NSArray *arguments)
{
    NSTask *task = [[[NSTask alloc] init] autorelease];
    [task setLaunchPath:tool];
    [task setArguments:arguments];
    [task setStandardOutput:[NSFileHandle fileHandleWithNullDevice]];
    [task setStandardError:[NSFileHandle fileHandleWithNullDevice]];
    NS_DURING
        [task launch];
    NS_HANDLER
    NS_ENDHANDLER
}

/* The words of a chat: who spoke and what was said, up to a limit. Tool cards, pictures and files are left out. */
static NSString *chatText(NSArray *messages)
{
    NSMutableString *out = [NSMutableString string];
    unsigned i;
    for (i = 0; i < [messages count] && [out length] < MAX_TEXT; i++) {
        NSDictionary *message = [messages objectAtIndex:i];
        NSString *text = [message objectForKey:@"text"], *role = [message objectForKey:@"role"];
        if (![text isKindOfClass:[NSString class]] || [text length] == 0 || [[message objectForKey:@"status"] boolValue])
            continue;
        if ([message objectForKey:@"file"] || [message objectForKey:@"video"] || [message objectForKey:@"tweet"])
            continue;
        [out appendString:[role isEqualToString:@"user"] ? @"You: " : @"Reply: "];
        [out appendString:text];
        [out appendString:@"\n\n"];
    }
    if ([out length] > MAX_TEXT)
        [out deleteCharactersInRange:NSMakeRange(MAX_TEXT, [out length] - MAX_TEXT)];
    return out;
}

@implementation TBSpotlight

+ (BOOL)enabled
{
    return [[NSUserDefaults standardUserDefaults] boolForKey:kEnabled];
}

+ (void)syncStore:(TBStore *)store
{
    NSString *workspace = workspaceOfPath([store path]), *folder = folderFor(workspace);
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *chats = [store chats];
    NSMutableSet *keep = [NSMutableSet set];
    unsigned i;
    if (!written)
        written = [[NSMutableDictionary alloc] init];
    [fm createDirectoryAtPath:[folder stringByDeletingLastPathComponent] attributes:nil];
    [fm createDirectoryAtPath:folder attributes:nil];
    for (i = 0; i < [chats count]; i++) {
        NSDictionary *chat = [chats objectAtIndex:i];
        NSString *ident = [chat objectForKey:@"id"], *title = [chat objectForKey:@"title"], *key, *signature, *file;
        NSArray *messages = [chat objectForKey:@"messages"];
        NSDictionary *last = [messages lastObject];
        if (![ident isKindOfClass:[NSString class]] || [ident length] == 0 || ![messages isKindOfClass:[NSArray class]])
            continue;
        if (![title isKindOfClass:[NSString class]])
            title = @"";
        [keep addObject:[ident stringByAppendingString:@".tbchat"]];
        key = [NSString stringWithFormat:@"%@|%@", workspace, ident];
        signature = [NSString stringWithFormat:@"%@|%u|%u", title, (unsigned)[messages count], (unsigned)[[last objectForKey:@"text"] length]];
        file = [folder stringByAppendingPathComponent:[ident stringByAppendingString:@".tbchat"]];
        if ([[written objectForKey:key] isEqualToString:signature] && [fm fileExistsAtPath:file])
            continue;
        {
            NSString *text = chatText(messages);
            NSDictionary *plist = [NSDictionary dictionaryWithObjectsAndKeys:ident, @"id", workspace, @"workspace", [title length] ? title : @"Chat", @"title", text, @"text", nil];
            NSString *problem = nil;
            NSData *data = [NSPropertyListSerialization dataFromPropertyList:plist format:NSPropertyListXMLFormat_v1_0 errorDescription:&problem];
            if (problem)
                [problem release];
            if (data && [data writeToFile:file atomically:YES])
                [written setObject:signature forKey:key];
        }
    }
    /* chats that are gone */
    {
        NSArray *files = [fm directoryContentsAtPath:folder];
        for (i = 0; i < [files count]; i++) {
            NSString *name = [files objectAtIndex:i];
            if ([name hasSuffix:@".tbchat"] && ![keep containsObject:name]) {
                [fm removeFileAtPath:[folder stringByAppendingPathComponent:name] handler:nil];
                [written removeObjectForKey:[NSString stringWithFormat:@"%@|%@", workspace, [name stringByDeletingPathExtension]]];
            }
        }
    }
}

+ (void)flushPending
{
    NSArray *stores = [pending allObjects];
    unsigned i;
    [pending removeAllObjects];
    if (![self enabled])
        return;
    for (i = 0; i < [stores count]; i++)
        [self syncStore:[stores objectAtIndex:i]];
}

+ (void)noteStore:(NSNotification *)note
{
    [self storeChanged:[note object]];
}

+ (void)start
{
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(noteStore:) name:TBStoreChangedNotification object:nil];
}

+ (void)storeChanged:(id)store
{
    if (![self enabled] || !store)
        return;
    if (!pending)
        pending = [[NSMutableSet alloc] init];
    [pending addObject:store];
    /* once it has been quiet for half a minute: a reply that is still arriving changes the chat many times a second */
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(flushPending) object:nil];
    [self performSelector:@selector(flushPending) withObject:nil afterDelay:30];
}

+ (void)rebuildAll
{
    NSString *support = [EngineRequest supportDir];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *paths = [NSMutableArray array];
    NSArray *items = [fm directoryContentsAtPath:[support stringByAppendingPathComponent:@"workspaces"]];
    NSArray *known;
    unsigned i;
    if ([fm fileExistsAtPath:[support stringByAppendingPathComponent:@"chats.plist"]])
        [paths addObject:[support stringByAppendingPathComponent:@"chats.plist"]];
    for (i = 0; i < [items count]; i++)
        if ([[items objectAtIndex:i] hasSuffix:@".plist"])
            [paths addObject:[[support stringByAppendingPathComponent:@"workspaces"] stringByAppendingPathComponent:[items objectAtIndex:i]]];
    for (i = 0; i < [paths count]; i++)
        [self syncStore:[TBStore storeAtPath:[paths objectAtIndex:i]]];
    /* a deleted workspace leaves its folder behind */
    known = [fm directoryContentsAtPath:[support stringByAppendingPathComponent:@"Spotlight"]];
    for (i = 0; i < [known count]; i++) {
        NSString *name = [known objectAtIndex:i];
        NSString *plist = [name isEqualToString:@"Default"] ? [support stringByAppendingPathComponent:@"chats.plist"]
            : [[[support stringByAppendingPathComponent:@"workspaces"] stringByAppendingPathComponent:name] stringByAppendingString:@".plist"];
        if (![fm fileExistsAtPath:plist])
            [fm removeFileAtPath:folderFor(name) handler:nil];
    }
}

+ (NSString *)setEnabled:(BOOL)on
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *installed = importerInstalled();
    if (on) {
        NSString *folder = [installed stringByDeletingLastPathComponent];
        if (![fm fileExistsAtPath:importerSource()])
            return @"This copy of Tiger Build has no Spotlight importer (it is built into the application from version 2.7).";
        [fm createDirectoryAtPath:[folder stringByDeletingLastPathComponent] attributes:nil];
        [fm createDirectoryAtPath:folder attributes:nil];
        [fm removeFileAtPath:installed handler:nil];
        if (![fm copyPath:importerSource() toPath:installed handler:nil])
            return @"The Spotlight importer could not be copied to ~/Library/Spotlight.";
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kEnabled];
        [[NSUserDefaults standardUserDefaults] synchronize];
        [self rebuildAll];
        runTool(@"/usr/bin/mdimport", [NSArray arrayWithObjects:@"-r", installed, nil]);
        runTool(@"/usr/bin/mdimport", [NSArray arrayWithObject:[[EngineRequest supportDir] stringByAppendingPathComponent:@"Spotlight"]]);
        return nil;
    }
    [[NSUserDefaults standardUserDefaults] setBool:NO forKey:kEnabled];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(flushPending) object:nil];
    [pending removeAllObjects];
    [written removeAllObjects];
    [fm removeFileAtPath:[[EngineRequest supportDir] stringByAppendingPathComponent:@"Spotlight"] handler:nil];
    [fm removeFileAtPath:installed handler:nil];
    runTool(@"/usr/bin/mdimport", [NSArray arrayWithObjects:@"-r", installed, nil]);
    return nil;
}

+ (BOOL)readChatFile:(NSString *)path workspace:(NSString **)workspace chatId:(NSString **)chatId
{
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:path];
    NSString *w = [plist objectForKey:@"workspace"], *i = [plist objectForKey:@"id"];
    if (![w isKindOfClass:[NSString class]] || ![i isKindOfClass:[NSString class]] || ![w length] || ![i length])
        return NO;
    *workspace = w;
    *chatId = i;
    return YES;
}

@end
