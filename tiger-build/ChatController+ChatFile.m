#import "ChatController_Private.h"
#import "TBMarkup.h"

/* One conversation to a file and back. Three kinds of file:
     Tiger Build chat  a property list that carries the chat with the files it
                       uses (attachments, pictures, files the model made) inside it,
                       so it can be imported into any workspace, on any Mac
     Markdown / text   the conversation as something to read or print; not for import
   This is a manual, one-off copy; the relay is not involved. */

#define TB_CHAT_FORMAT @"TigerBuild-chat"
#define TB_EMBED_LIMIT (30 * 1024 * 1024)
#define TB_FILE_PREFIX @"tbfile:"

@interface ChatController (ChatFilePrivate)
- (NSDictionary *)portableChat:(NSDictionary *)chat;
- (NSString *)readableChat:(NSDictionary *)chat markdown:(BOOL)markdown;
- (NSString *)restoredPathForEmbedded:(NSData *)data name:(NSString *)name directory:(NSString *)directory;
@end

/* A copy of a property list with mutable containers. */
static id mutableCopyOfPlist(id value)
{
    NSData *data = [NSPropertyListSerialization dataFromPropertyList:value format:NSPropertyListXMLFormat_v1_0 errorDescription:NULL];
    if (!data)
        return nil;
    return [NSPropertyListSerialization propertyListFromData:data mutabilityOption:NSPropertyListMutableContainersAndLeaves
        format:NULL errorDescription:NULL];
}

static NSString *safeFileStem(NSString *title)
{
    NSMutableString *stem = [NSMutableString string];
    unsigned i;
    for (i = 0; i < [title length] && [stem length] < 60; i++) {
        unichar c = [title characterAtIndex:i];
        if (c == '/' || c == ':' || c == '\\' || c < 32)
            c = '-';
        [stem appendFormat:@"%C", c];
    }
    stem = (NSMutableString *)[stem stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" .-"]];
    return [stem length] > 0 ? stem : @"Chat";
}

@implementation ChatController (ChatFile)

/* ---- export ---- */

- (NSDictionary *)portableChat:(NSDictionary *)chat
{
    NSMutableDictionary *copy = mutableCopyOfPlist(chat);
    NSMutableDictionary *files = [NSMutableDictionary dictionary];
    NSArray *messages = [copy objectForKey:@"messages"];
    NSFileManager *manager = [NSFileManager defaultManager];
    NSArray *fields = [NSArray arrayWithObjects:@"image", @"video", @"file", nil];
    unsigned counter = 0;
    unsigned i;
    unsigned f;
    if (!copy)
        return nil;
    [copy removeObjectForKey:@"id"];
    [copy removeObjectForKey:@"ctxTokens"];
    [copy removeObjectForKey:@"ctxAt"];
    for (i = 0; i < [messages count]; i++) {
        NSMutableDictionary *message = [messages objectAtIndex:i];
        NSMutableDictionary *attachment = [message objectForKey:@"attachment"];
        [message removeObjectForKey:@"open"];
        [message removeObjectForKey:@"pendingMedia"];
        for (f = 0; f < [fields count] + 1; f++) {
            NSMutableDictionary *holder = f < [fields count] ? message : attachment;
            NSString *key = f < [fields count] ? [fields objectAtIndex:f] : @"path";
            NSString *path = [holder objectForKey:key];
            NSData *data;
            NSString *name;
            if (!holder || ![path isKindOfClass:[NSString class]])
                continue;
            data = [[[manager fileAttributesAtPath:path traverseLink:YES] objectForKey:NSFileSize] doubleValue] <= TB_EMBED_LIMIT
                ? [NSData dataWithContentsOfFile:path] : nil;
            if (!data) {
                [holder removeObjectForKey:key];
                continue;
            }
            counter++;
            name = [NSString stringWithFormat:@"%u-%@", counter, [path lastPathComponent]];
            [files setObject:data forKey:name];
            [holder setObject:[TB_FILE_PREFIX stringByAppendingString:name] forKey:key];
        }
    }
    return [NSDictionary dictionaryWithObjectsAndKeys:TB_CHAT_FORMAT, @"format", [NSNumber numberWithInt:1], @"version",
        [NSDate date], @"exported", copy, @"chat", files, @"files", nil];
}

- (NSString *)readableChat:(NSDictionary *)chat markdown:(BOOL)markdown
{
    NSMutableString *out = [NSMutableString string];
    NSArray *messages = [chat objectForKey:@"messages"];
    NSString *title = [chat objectForKey:@"title"];
    unsigned i;
    [out appendString:markdown ? [NSString stringWithFormat:@"# %@\n\n", title] : [NSString stringWithFormat:@"%@\n%@\n\n", title,
        [@"" stringByPaddingToLength:[title length] withString:@"=" startingAtIndex:0]]];
    [out appendFormat:@"Model: %@ / %@\n\n", [self providerForChat:chat], [self modelForChat:chat]];
    for (i = 0; i < [messages count]; i++) {
        NSDictionary *message = [messages objectAtIndex:i];
        NSDictionary *attachment = [message objectForKey:@"attachment"];
        BOOL user = [[message objectForKey:@"role"] isEqualToString:@"user"];
        NSString *text = [message objectForKey:@"text"];
        NSString *file = [message objectForKey:@"file"];
        if ([[message objectForKey:@"status"] boolValue] || [message objectForKey:@"activityKind"])
            continue;
        if (attachment) {
            NSString *body = [[attachment objectForKey:@"kind"] isEqualToString:@"text"]
                ? TBReadTextFile([attachment objectForKey:@"path"], TB_ATTACH_TEXT_MAX, NULL) : nil;
            [out appendFormat:markdown ? @"**You attached %@ (%@)**\n\n" : @"[You attached %@ (%@)]\n\n",
                [attachment objectForKey:@"name"], TBHumanSize([[attachment objectForKey:@"size"] doubleValue])];
            if (body)
                [out appendFormat:markdown ? @"```\n%@\n```\n\n" : @"----\n%@\n----\n\n", body];
            continue;
        }
        [out appendString:markdown ? (user ? @"## You\n\n" : @"## Assistant\n\n") : (user ? @"You:\n" : @"Assistant:\n")];
        if ([text length] > 0)
            [out appendFormat:@"%@\n\n", text];
        if (file) {
            NSString *body = TBReadTextFile(file, 200000, NULL);
            if (body)
                [out appendFormat:markdown ? @"```\n%@\n```\n\n" : @"----\n%@\n----\n\n", body];
        } else if ([message objectForKey:@"image"] || [message objectForKey:@"video"]) {
            [out appendFormat:@"[%@: %@]\n\n", [message objectForKey:@"image"] ? @"Picture" : @"Video",
                [[message objectForKey:@"image"] ? [message objectForKey:@"image"] : [message objectForKey:@"video"] lastPathComponent]];
        }
    }
    return out;
}

- (IBAction)exportChat:(id)sender
{
    NSSavePanel *panel;
    NSView *accessory;
    NSTextField *label;
    NSPopUpButton *format;
    NSData *data = nil;
    NSString *path;
    NSString *ext;
    int kind;
    (void)sender;
    if (!current || busy)
        return;
    [self flushStore];
    panel = [NSSavePanel savePanel];
    accessory = [[[NSView alloc] initWithFrame:NSMakeRect(0, 0, 420, 34)] autorelease];
    label = [[[NSTextField alloc] initWithFrame:NSMakeRect(0, 8, 54, 17)] autorelease];
    [label setStringValue:@"Format:"];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setAlignment:NSRightTextAlignment];
    format = [[[NSPopUpButton alloc] initWithFrame:NSMakeRect(60, 4, 350, 26) pullsDown:NO] autorelease];
    [format addItemWithTitle:@"Tiger Build chat (can be imported again)"];
    [format addItemWithTitle:@"Markdown (to read)"];
    [format addItemWithTitle:@"Plain text (to read)"];
    [accessory addSubview:label];
    [accessory addSubview:format];
    [panel setAccessoryView:accessory];
    [panel setMessage:@"Save this conversation to a file."];
    if ([panel runModalForDirectory:[@"~/Desktop" stringByExpandingTildeInPath]
            file:safeFileStem([current objectForKey:@"title"])] != NSOKButton)
        return;
    kind = [format indexOfSelectedItem];
    ext = kind == 0 ? @"plist" : (kind == 1 ? @"md" : @"txt");
    path = [panel filename];
    if (![[[path pathExtension] lowercaseString] isEqualToString:ext]) {
        NSString *known = [[path pathExtension] lowercaseString];
        if ([known isEqualToString:@"plist"] || [known isEqualToString:@"md"] || [known isEqualToString:@"txt"])
            path = [path stringByDeletingPathExtension];
        path = [path stringByAppendingPathExtension:ext];
    }
    if (kind == 0) {
        NSDictionary *portable = [self portableChat:current];
        data = portable ? [NSPropertyListSerialization dataFromPropertyList:portable format:NSPropertyListBinaryFormat_v1_0
            errorDescription:NULL] : nil;
    } else {
        data = [[self readableChat:current markdown:kind == 1] dataUsingEncoding:NSUTF8StringEncoding];
    }
    if (!data || ![data writeToFile:path atomically:YES])
        NSRunAlertPanel(@"Export chat", @"The chat could not be saved to %@.", @"OK", nil, nil, path);
}

/* ---- import ---- */

- (NSString *)restoredPathForEmbedded:(NSData *)data name:(NSString *)name directory:(NSString *)directory
{
    static unsigned counter = 0;
    NSString *dir = [[self supportDir] stringByAppendingPathComponent:directory];
    NSString *base = name;
    NSRange dash = [name rangeOfString:@"-"];
    NSString *path;
    counter++;
    /* The export numbered the file ("3-report.md"); take the number off. */
    if (dash.location != NSNotFound && dash.location < 6)
        base = [name substringFromIndex:dash.location + 1];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir attributes:nil];
    if ([directory isEqualToString:@"media"] && [base length] > 17 && [base characterAtIndex:16] == '-')
        path = [dir stringByAppendingPathComponent:base];
    else
        path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%.0f-%u-%@", CFAbsoluteTimeGetCurrent(), counter, base]];
    return [data writeToFile:path atomically:YES] ? path : nil;
}

- (IBAction)importChat:(id)sender
{
    NSOpenPanel *panel;
    NSData *data;
    NSDictionary *root;
    NSMutableDictionary *chat;
    NSDictionary *files;
    NSArray *messages;
    NSArray *fields = [NSArray arrayWithObjects:@"image", @"video", @"file", nil];
    NSString *problem;
    NSString *error = nil;
    unsigned i;
    unsigned f;
    (void)sender;
    if (busy || !current) {
        NSBeep();
        return;
    }
    panel = [NSOpenPanel openPanel];
    [panel setAllowsMultipleSelection:NO];
    [panel setMessage:@"Choose a chat exported from Tiger Build. It is added to this workspace as a new chat."];
    if ([panel runModalForDirectory:nil file:nil types:[NSArray arrayWithObject:@"plist"]] != NSOKButton)
        return;
    data = [NSData dataWithContentsOfFile:[panel filename]];
    root = data ? [NSPropertyListSerialization propertyListFromData:data mutabilityOption:NSPropertyListImmutable
        format:NULL errorDescription:&error] : nil;
    if (error)
        [error release];
    if (![root isKindOfClass:[NSDictionary class]]) {
        NSRunAlertPanel(@"Import chat", @"That file is not a Tiger Build chat.", @"OK", nil, nil);
        return;
    }
    if ([[root objectForKey:@"format"] isEqualToString:@"TigerBuild-history"]) {
        NSRunAlertPanel(@"Import chat", @"That is an export of all chats. Use History > Import History for it.", @"OK", nil, nil);
        return;
    }
    if (![[root objectForKey:@"format"] isEqualToString:TB_CHAT_FORMAT] || ![[root objectForKey:@"chat"] isKindOfClass:[NSDictionary class]]) {
        NSRunAlertPanel(@"Import chat", @"That file is not a Tiger Build chat.", @"OK", nil, nil);
        return;
    }
    if ([[root objectForKey:@"version"] intValue] > 1) {
        NSRunAlertPanel(@"Import chat", @"That chat was exported by a newer Tiger Build. Update this copy to import it.", @"OK", nil, nil);
        return;
    }
    chat = mutableCopyOfPlist([root objectForKey:@"chat"]);
    problem = TBChatListProblem([NSArray arrayWithObject:chat]);
    if (!chat || problem) {
        NSRunAlertPanel(@"Import chat", @"%@", @"OK", nil, nil, problem ? problem : @"That chat could not be read.");
        return;
    }
    files = [[root objectForKey:@"files"] isKindOfClass:[NSDictionary class]] ? [root objectForKey:@"files"] : [NSDictionary dictionary];
    messages = [chat objectForKey:@"messages"];
    for (i = 0; i < [messages count]; i++) {
        NSMutableDictionary *message = [messages objectAtIndex:i];
        NSMutableDictionary *attachment = [message objectForKey:@"attachment"];
        [message removeObjectForKey:@"open"];
        [message removeObjectForKey:@"pendingMedia"];
        for (f = 0; f < [fields count] + 1; f++) {
            NSMutableDictionary *holder = f < [fields count] ? message : attachment;
            NSString *key = f < [fields count] ? [fields objectAtIndex:f] : @"path";
            NSString *value = [holder objectForKey:key];
            NSString *name;
            NSData *embedded;
            NSString *restored;
            if (!holder || ![value isKindOfClass:[NSString class]])
                continue;
            if (![value hasPrefix:TB_FILE_PREFIX]) {
                [holder removeObjectForKey:key];
                continue;
            }
            name = [value substringFromIndex:[TB_FILE_PREFIX length]];
            embedded = [files objectForKey:name];
            restored = [embedded isKindOfClass:[NSData class]]
                ? [self restoredPathForEmbedded:embedded name:name directory:f < [fields count] ? @"media" : @"attachments"] : nil;
            if (restored)
                [holder setObject:restored forKey:key];
            else
                [holder removeObjectForKey:key];
        }
    }
    [chat setObject:[NSString stringWithFormat:@"%d", [store takeNextId]] forKey:@"id"];
    [chat removeObjectForKey:@"ctxTokens"];
    [chat removeObjectForKey:@"ctxAt"];
    if (![[chat objectForKey:@"title"] isKindOfClass:[NSString class]])
        [chat setObject:@"Imported Chat" forKey:@"title"];
    [chat setObject:[NSNumber numberWithBool:NO] forKey:@"autoTitle"];
    [self forgetEdit];
    [chats insertObject:chat atIndex:0];
    [self saveStore];
    [self reloadTableSelect:0 show:YES];
}

@end
