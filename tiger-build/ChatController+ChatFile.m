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

void TBSanitizeImportedChat(NSMutableDictionary *chat)
{
    NSDictionary *servers = [chat objectForKey:@"servers"];
    [chat removeObjectForKey:@"approve"];
    if ([servers isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *safe = [NSMutableDictionary dictionaryWithDictionary:servers];
        [safe removeObjectForKey:@"sudo"];
        [safe removeObjectForKey:@"download"];
        [safe removeObjectForKey:@"screen"];
        [chat setObject:safe forKey:@"servers"];
    } else
        [chat removeObjectForKey:@"servers"];
}

@interface ChatController (ChatFilePrivate)
- (NSDictionary *)portableChat:(NSDictionary *)chat;
- (NSDictionary *)historyRoot;
- (void)embedFilesInChat:(NSMutableDictionary *)copy into:(NSMutableDictionary *)files budget:(double *)budget;

- (void)restoreFilesInChat:(NSMutableDictionary *)chat from:(NSDictionary *)files;
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

/* Put the files a chat uses into `files` and point the chat at them ("tbfile:name"), so the
   chat can travel without the Mac it was made on. budget is how many more bytes may be added. */
- (void)embedFilesInChat:(NSMutableDictionary *)copy into:(NSMutableDictionary *)files budget:(double *)budget
{
    NSArray *messages = [copy objectForKey:@"messages"];
    NSFileManager *manager = [NSFileManager defaultManager];
    NSArray *fields = [NSArray arrayWithObjects:@"image", @"video", @"file", nil];
    unsigned i;
    unsigned f;
    for (i = 0; i < [messages count]; i++) {
        NSMutableDictionary *message = [messages objectAtIndex:i];
        NSMutableDictionary *attachment = [message objectForKey:@"attachment"];
        [message removeObjectForKey:@"open"];
        [message removeObjectForKey:@"pendingMedia"];
        for (f = 0; f < [fields count] + 1; f++) {
            NSMutableDictionary *holder = f < [fields count] ? message : attachment;
            NSString *key = f < [fields count] ? [fields objectAtIndex:f] : @"path";
            NSString *path = [holder objectForKey:key];
            double size;
            NSData *data = nil;
            NSString *name;
            if (!holder || ![path isKindOfClass:[NSString class]])
                continue;
            size = [[[manager fileAttributesAtPath:path traverseLink:YES] objectForKey:NSFileSize] doubleValue];
            if (size <= TB_EMBED_LIMIT && size <= *budget)
                data = [NSData dataWithContentsOfFile:path];
            if (!data) {
                [holder removeObjectForKey:key];
                continue;
            }
            *budget -= size;
            name = [NSString stringWithFormat:@"%u-%@", (unsigned)[files count] + 1, [path lastPathComponent]];
            [files setObject:data forKey:name];
            [holder setObject:[TB_FILE_PREFIX stringByAppendingString:name] forKey:key];
        }
    }
}

/* The reverse: write the files a chat carries back into this Mac's folders and point the chat at them. */
- (void)restoreFilesInChat:(NSMutableDictionary *)chat from:(NSDictionary *)files
{
    NSArray *messages = [chat objectForKey:@"messages"];
    NSArray *fields = [NSArray arrayWithObjects:@"image", @"video", @"file", nil];
    unsigned i;
    unsigned f;
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
}

- (NSDictionary *)portableChat:(NSDictionary *)chat
{
    NSMutableDictionary *copy = mutableCopyOfPlist(chat);
    NSMutableDictionary *files = [NSMutableDictionary dictionary];
    double budget = 400.0 * 1024 * 1024;
    if (!copy)
        return nil;
    [copy removeObjectForKey:@"id"];
    [copy removeObjectForKey:@"ctxTokens"];
    [copy removeObjectForKey:@"ctxAt"];
    [self embedFilesInChat:copy into:files budget:&budget];
    return [NSDictionary dictionaryWithObjectsAndKeys:TB_CHAT_FORMAT, @"format", [NSNumber numberWithInt:1], @"version",
        [NSDate date], @"exported", copy, @"chat", files, @"files", nil];
}

/* The history of every workspace, with the files its chats use inside it. For an export to a file;
   the copy on the relay and the backup before an import carry references only. */
- (NSData *)historyDataIncludingFiles
{
    NSDictionary *root = [self historyRoot];
    NSMutableDictionary *copy = mutableCopyOfPlist(root);
    NSMutableDictionary *files = [NSMutableDictionary dictionary];
    NSDictionary *spaces = [copy objectForKey:@"workspaces"];
    NSEnumerator *names = [spaces keyEnumerator];
    NSString *name;
    double budget = 800.0 * 1024 * 1024;
    NSString *error = nil;
    NSData *data;
    if (!copy)
        return nil;
    while ((name = [names nextObject])) {
        NSArray *list = [[spaces objectForKey:name] objectForKey:@"chats"];
        unsigned c;
        for (c = 0; c < [list count]; c++)
            [self embedFilesInChat:[list objectAtIndex:c] into:files budget:&budget];
    }
    [copy setObject:files forKey:@"files"];
    data = [NSPropertyListSerialization dataFromPropertyList:copy format:NSPropertyListBinaryFormat_v1_0 errorDescription:&error];
    if (error)
        [error release];
    return data;
}

/* A chat made from this one up to and including a message, in the same workspace. */
- (void)branchFromMessage:(NSMutableDictionary *)message
{
    NSMutableDictionary *copy;
    NSMutableArray *messages;
    NSUInteger index;
    NSString *title;
    if (busy || !current)
        return;
    index = [[current objectForKey:@"messages"] indexOfObjectIdenticalTo:message];
    if (index == NSNotFound)
        return;
    copy = mutableCopyOfPlist(current);
    if (!copy)
        return;
    messages = [copy objectForKey:@"messages"];
    while ([messages count] > index + 1)
        [messages removeLastObject];
    title = [copy objectForKey:@"title"];
    [copy setObject:[NSString stringWithFormat:@"%@ (branch)", title ? title : @"Chat"] forKey:@"title"];
    [copy setObject:[NSNumber numberWithBool:NO] forKey:@"autoTitle"];
    [copy setObject:[NSString stringWithFormat:@"%d", [store takeNextId]] forKey:@"id"];
    [copy removeObjectForKey:@"ctxTokens"];
    [copy removeObjectForKey:@"ctxAt"];
    [self forgetEdit];
    [chats insertObject:copy atIndex:0];
    [self saveStore];
    [self reloadTableSelect:0 show:YES];
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

/* ---- PDF ---- */

/* one line of a reply with **bold** and `code` styled and the marks taken out */
static void appendStyledLine(NSMutableAttributedString *out, NSString *line, NSDictionary *plain, NSDictionary *code, float size, BOOL boldAll)
{
    NSMutableString *run = [NSMutableString string];
    BOOL bold = boldAll, mono = NO;
    NSUInteger i, n = [line length];
    NSFont *base = [plain objectForKey:NSFontAttributeName];
    #define FLUSH do { if ([run length]) { \
        NSMutableDictionary *a = [NSMutableDictionary dictionaryWithDictionary:mono ? code : plain]; \
        if (!mono) [a setObject:bold ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size] forKey:NSFontAttributeName]; \
        [out appendAttributedString:[[[NSAttributedString alloc] initWithString:run attributes:a] autorelease]]; [run setString:@""]; } } while (0)
    (void)base;
    for (i = 0; i < n; i++) {
        unichar c = [line characterAtIndex:i];
        if (c == '*' && i + 1 < n && [line characterAtIndex:i + 1] == '*' && !mono) {
            FLUSH;
            bold = boldAll ? YES : !bold;
            i++;
        } else if (c == '`') {
            FLUSH;
            mono = !mono;
        } else
            [run appendFormat:@"%C", c];
    }
    FLUSH;
    [out appendAttributedString:[[[NSAttributedString alloc] initWithString:@"\n" attributes:plain] autorelease]];
    #undef FLUSH
}

/* the text of a message: its ``` blocks in a code font on gray, headings, bullets, bold and inline code styled */
static void appendMessageText(NSMutableAttributedString *out, NSString *text, NSDictionary *plain, NSDictionary *code)
{
    NSArray *parts = [text componentsSeparatedByString:@"```"];
    NSCharacterSet *edge = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    unsigned i;
    for (i = 0; i < [parts count]; i++) {
        NSString *part = [parts objectAtIndex:i];
        if (i % 2 == 1) {
            /* the first line of a fenced block names the language: left out */
            NSRange nl = [part rangeOfString:@"\n"];
            if (nl.location != NSNotFound && nl.location < 24)
                part = [part substringFromIndex:nl.location + 1];
            part = [part stringByTrimmingCharactersInSet:edge];
            [out appendAttributedString:[[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@\n\n", part] attributes:code] autorelease]];
        } else {
            NSArray *lines = [[part stringByTrimmingCharactersInSet:edge] componentsSeparatedByString:@"\n"];
            unsigned k;
            if (![[part stringByTrimmingCharactersInSet:edge] length])
                continue;
            for (k = 0; k < [lines count]; k++) {
                NSString *line = [lines objectAtIndex:k];
                unsigned level = 0;
                while (level < [line length] && [line characterAtIndex:level] == '#')
                    level++;
                if (level > 0 && level < [line length] && [line characterAtIndex:level] == ' ')
                    appendStyledLine(out, [line substringFromIndex:level + 1], plain, code, level == 1 ? 15 : (level == 2 ? 13.5f : 12), YES);
                else if ([line hasPrefix:@"- "] || [line hasPrefix:@"* "])
                    appendStyledLine(out, [NSString stringWithFormat:@"%C %@", (unichar)0x2022, [line substringFromIndex:2]], plain, code, 11, NO);
                else
                    appendStyledLine(out, line, plain, code, 11, NO);
            }
            [out appendAttributedString:[[[NSAttributedString alloc] initWithString:@"\n" attributes:plain] autorelease]];
        }
    }
}

- (NSAttributedString *)pdfContentForChat:(NSDictionary *)chat width:(float)width
{
    NSMutableAttributedString *out = [[[NSMutableAttributedString alloc] init] autorelease];
    NSArray *messages = [chat objectForKey:@"messages"];
    NSMutableParagraphStyle *para = [[[NSMutableParagraphStyle alloc] init] autorelease];
    NSDictionary *titleAttrs, *metaAttrs, *userAttrs, *botAttrs, *plain, *code, *note;
    unsigned i;
    [para setLineBreakMode:NSLineBreakByWordWrapping];
    [para setParagraphSpacing:2];
    titleAttrs = [NSDictionary dictionaryWithObjectsAndKeys:[NSFont boldSystemFontOfSize:20], NSFontAttributeName, nil];
    metaAttrs = [NSDictionary dictionaryWithObjectsAndKeys:[NSFont systemFontOfSize:10], NSFontAttributeName, [NSColor grayColor], NSForegroundColorAttributeName, nil];
    userAttrs = [NSDictionary dictionaryWithObjectsAndKeys:[NSFont boldSystemFontOfSize:12], NSFontAttributeName, [NSColor colorWithCalibratedRed:0.1 green:0.3 blue:0.75 alpha:1], NSForegroundColorAttributeName, nil];
    botAttrs = [NSDictionary dictionaryWithObjectsAndKeys:[NSFont boldSystemFontOfSize:12], NSFontAttributeName, [NSColor colorWithCalibratedRed:0.15 green:0.45 blue:0.2 alpha:1], NSForegroundColorAttributeName, nil];
    plain = [NSDictionary dictionaryWithObjectsAndKeys:[NSFont systemFontOfSize:11], NSFontAttributeName, para, NSParagraphStyleAttributeName, nil];
    code = [NSDictionary dictionaryWithObjectsAndKeys:[NSFont userFixedPitchFontOfSize:9.5f], NSFontAttributeName,
        [NSColor colorWithCalibratedWhite:0.93f alpha:1], NSBackgroundColorAttributeName, nil];
    note = [NSDictionary dictionaryWithObjectsAndKeys:[NSFont systemFontOfSize:10], NSFontAttributeName, [NSColor colorWithCalibratedWhite:0.4f alpha:1], NSForegroundColorAttributeName, nil];
    [out appendAttributedString:[[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@\n", [chat objectForKey:@"title"] ? [chat objectForKey:@"title"] : @"Chat"] attributes:titleAttrs] autorelease]];
    [out appendAttributedString:[[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@ / %@\n\n", [self providerForChat:chat], [self modelForChat:chat]] attributes:metaAttrs] autorelease]];
    for (i = 0; i < [messages count]; i++) {
        NSDictionary *message = [messages objectAtIndex:i], *attachment = [message objectForKey:@"attachment"];
        BOOL user = [[message objectForKey:@"role"] isEqualToString:@"user"];
        NSString *text = [message objectForKey:@"text"], *file = [message objectForKey:@"file"], *imagePath = [message objectForKey:@"image"];
        if ([[message objectForKey:@"status"] boolValue] || [message objectForKey:@"activityKind"])
            continue;
        if (attachment) {
            [out appendAttributedString:[[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"You attached %@ (%@)\n\n", [attachment objectForKey:@"name"],
                TBHumanSize([[attachment objectForKey:@"size"] doubleValue])] attributes:note] autorelease]];
            continue;
        }
        [out appendAttributedString:[[[NSAttributedString alloc] initWithString:user ? @"You\n" : @"Assistant\n" attributes:user ? userAttrs : botAttrs] autorelease]];
        if ([text length])
            appendMessageText(out, text, plain, code);
        if (file) {
            NSString *body = TBReadTextFile(file, 60000, NULL);
            if (body)
                [out appendAttributedString:[[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@\n\n", body] attributes:code] autorelease]];
        } else if (imagePath) {
            NSImage *image = [[[NSImage alloc] initWithContentsOfFile:imagePath] autorelease];
            if (image && [image size].width > 0) {
                NSSize size = [image size];
                NSTextAttachment *attachmentView;
                float limit = width < 420 ? width : 420;
                if (size.width > limit) {
                    size.height = size.height * limit / size.width;
                    size.width = limit;
                }
                [image setScalesWhenResized:YES];
                [image setSize:size];
                attachmentView = [[[NSTextAttachment alloc] init] autorelease];
                [attachmentView setAttachmentCell:[[[NSTextAttachmentCell alloc] initImageCell:image] autorelease]];
                [out appendAttributedString:[NSAttributedString attributedStringWithAttachment:attachmentView]];
                [out appendAttributedString:[[[NSAttributedString alloc] initWithString:@"\n\n" attributes:plain] autorelease]];
            } else
                [out appendAttributedString:[[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"[Picture: %@]\n\n", [imagePath lastPathComponent]] attributes:note] autorelease]];
        } else if ([message objectForKey:@"video"])
            [out appendAttributedString:[[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"[Video: %@]\n\n", [[message objectForKey:@"video"] lastPathComponent]] attributes:note] autorelease]];
    }
    return out;
}

/* The chat as a paginated PDF at `path`. NO when the file could not be made. */
- (BOOL)writePDFOfChat:(NSDictionary *)chat toPath:(NSString *)path
{
    NSPrintInfo *info = [[[NSPrintInfo sharedPrintInfo] copy] autorelease];
    NSTextView *view;
    NSPrintOperation *operation;
    float width;
    [info setJobDisposition:NSPrintSaveJob];
    [[info dictionary] setObject:path forKey:NSPrintSavePath];
    [info setLeftMargin:54];
    [info setRightMargin:54];
    [info setTopMargin:54];
    [info setBottomMargin:54];
    [info setHorizontalPagination:NSFitPagination];
    [info setVerticalPagination:NSAutoPagination];
    [info setVerticallyCentered:NO];
    [info setHorizontallyCentered:NO];
    width = [info paperSize].width - [info leftMargin] - [info rightMargin];
    view = [[[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, width, 100)] autorelease];
    [view setHorizontallyResizable:NO];
    [view setVerticallyResizable:YES];
    [[view textContainer] setContainerSize:NSMakeSize(width, 1.0e7f)];
    [[view textContainer] setWidthTracksTextView:YES];
    [[view textStorage] setAttributedString:[self pdfContentForChat:chat width:width]];
    [view sizeToFit];
    operation = [NSPrintOperation printOperationWithView:view printInfo:info];
    [operation setShowPanels:NO];
    return [operation runOperation] && [[NSFileManager defaultManager] fileExistsAtPath:path];
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
    [format addItemWithTitle:@"PDF (to read or print)"];
    [accessory addSubview:label];
    [accessory addSubview:format];
    [panel setAccessoryView:accessory];
    [panel setMessage:@"Save this conversation to a file."];
    if ([panel runModalForDirectory:[@"~/Desktop" stringByExpandingTildeInPath]
            file:safeFileStem([current objectForKey:@"title"])] != NSOKButton)
        return;
    kind = [format indexOfSelectedItem];
    ext = kind == 0 ? @"plist" : (kind == 1 ? @"md" : (kind == 2 ? @"txt" : @"pdf"));
    path = [panel filename];
    if (![[[path pathExtension] lowercaseString] isEqualToString:ext]) {
        NSString *known = [[path pathExtension] lowercaseString];
        if ([known isEqualToString:@"plist"] || [known isEqualToString:@"md"] || [known isEqualToString:@"txt"] || [known isEqualToString:@"pdf"])
            path = [path stringByDeletingPathExtension];
        path = [path stringByAppendingPathExtension:ext];
    }
    if (kind == 3) {
        if (![self writePDFOfChat:current toPath:path])
            NSRunAlertPanel(@"Export chat", @"The PDF could not be made at %@.", @"OK", nil, nil, path);
        return;
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
    /* The name comes from the file being imported, so it is never trusted as a path. */
    base = [[[base componentsSeparatedByString:@"/"] lastObject] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@". "]];
    base = [[base componentsSeparatedByString:@":"] componentsJoinedByString:@"-"];
    if ([base length] == 0)
        base = @"file";
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
    NSString *problem;
    NSString *error = nil;
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
    TBSanitizeImportedChat(chat);
    [self restoreFilesInChat:chat from:files];
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
