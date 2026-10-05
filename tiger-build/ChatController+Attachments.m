#import "ChatController_Private.h"
#import "TBExtract.h"
#import <unistd.h>

/* Files attached to a chat. Each file becomes a message from the person, shown as
   "Attached: name (size)" with a thumbnail for pictures, and the model sees it
   from then on in this conversation. A copy is kept in Application Support so the
   original can move or change. Text and code files go to the model as text;
   PDFs, Word, RTF and HTML documents are turned into text first; pictures are
   shrunk and sent as pictures. */

#define TB_ATTACH_MAX_BYTES (40 * 1024 * 1024)
#define TB_ATTACH_IMAGE_EDGE 1600.0f

@interface ChatController (RelayConversion)
- (BOOL)relayConverts:(NSString *)path;
- (BOOL)startRelayConversion:(NSDictionary *)job problem:(NSString **)problem;
@end

@interface ChatController (HistorySweep)
- (NSDictionary *)allWorkspaces;
@end

@interface ChatController (AttachmentQueue)
- (void)attachNext;
- (void)attachRun:(NSDictionary *)job;
- (void)finishJob:(NSDictionary *)job made:(NSArray *)made problem:(NSString *)problem;
- (NSArray *)confirmedAttachments:(NSArray *)made chat:(NSMutableDictionary *)chat;
- (BOOL)confirmCloudAttach;
- (NSString *)tokenString:(int)count;
- (int)contextTokensForChat:(NSDictionary *)chat;
@end

@interface ChatController (AttachmentsPrivate)
- (NSString *)attachmentsDir;
- (NSString *)savedPathForName:(NSString *)name extension:(NSString *)ext;
- (NSMutableDictionary *)pictureAttachmentFromPath:(NSString *)path name:(NSString *)name pdf:(BOOL)pdf problem:(NSString **)problem;
- (NSMutableDictionary *)pictureAttachmentFromImage:(NSImage *)image path:(NSString *)path name:(NSString *)name pdf:(BOOL)pdf problem:(NSString **)problem;
- (NSArray *)pdfAttachmentsForJob:(NSDictionary *)job size:(double)size problem:(NSString **)problem;
- (NSArray *)pdfPageAttachmentForJob:(NSDictionary *)job problem:(NSString **)problem;
- (NSMutableDictionary *)textAttachmentWithText:(NSString *)text name:(NSString *)name size:(double)size problem:(NSString **)problem;
- (NSMutableDictionary *)messageForAttachment:(NSMutableDictionary *)attachment;
@end

/* A small question box: one line of text, OK and Cancel. */
@interface TBPagePrompt : NSObject {
    NSPanel *panel;
    NSTextField *field;
}
+ (NSString *)ask:(NSString *)message title:(NSString *)title;
- (void)accept:(id)sender;
- (void)cancel:(id)sender;
@end

@implementation TBPagePrompt

+ (NSString *)ask:(NSString *)message title:(NSString *)title
{
    TBPagePrompt *prompt = [[[TBPagePrompt alloc] init] autorelease];
    NSTextField *label;
    NSButton *ok;
    NSButton *cancel;
    int result;
    NSString *answer = nil;
    prompt->panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 380, 150)
        styleMask:NSTitledWindowMask backing:NSBackingStoreBuffered defer:NO];
    [prompt->panel setTitle:title];
    label = [[[NSTextField alloc] initWithFrame:NSMakeRect(20, 78, 340, 56)] autorelease];
    [label setStringValue:message];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [label setEditable:NO];
    [label setSelectable:NO];
    prompt->field = [[[NSTextField alloc] initWithFrame:NSMakeRect(20, 50, 340, 22)] autorelease];
    ok = [[[NSButton alloc] initWithFrame:NSMakeRect(280, 12, 80, 28)] autorelease];
    [ok setTitle:@"OK"];
    [ok setBezelStyle:NSRoundedBezelStyle];
    [ok setKeyEquivalent:@"\r"];
    [ok setTarget:prompt];
    [ok setAction:@selector(accept:)];
    cancel = [[[NSButton alloc] initWithFrame:NSMakeRect(190, 12, 80, 28)] autorelease];
    [cancel setTitle:@"Cancel"];
    [cancel setBezelStyle:NSRoundedBezelStyle];
    [cancel setKeyEquivalent:@"\033"];
    [cancel setTarget:prompt];
    [cancel setAction:@selector(cancel:)];
    [[prompt->panel contentView] addSubview:label];
    [[prompt->panel contentView] addSubview:prompt->field];
    [[prompt->panel contentView] addSubview:ok];
    [[prompt->panel contentView] addSubview:cancel];
    [prompt->panel setDefaultButtonCell:[ok cell]];
    [prompt->panel center];
    [prompt->panel makeFirstResponder:prompt->field];
    result = [NSApp runModalForWindow:prompt->panel];
    if (result == 1)
        answer = [[[prompt->field stringValue] copy] autorelease];
    [prompt->panel orderOut:nil];
    [prompt->panel release];
    prompt->panel = nil;
    return answer;
}

- (void)accept:(id)sender
{
    (void)sender;
    [NSApp stopModalWithCode:1];
}

- (void)cancel:(id)sender
{
    (void)sender;
    [NSApp stopModalWithCode:0];
}

@end

/* "1-3, 7" as page numbers, each once, in order, none past the last page. */
static NSArray *pagesFromSpec(NSString *spec, unsigned total)
{
    NSMutableArray *found = [NSMutableArray array];
    NSArray *parts = [spec componentsSeparatedByString:@","];
    unsigned i;
    for (i = 0; i < [parts count]; i++) {
        NSString *part = [[parts objectAtIndex:i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSArray *range = [part componentsSeparatedByString:@"-"];
        int from = [part intValue];
        int to = from;
        int p;
        if ([range count] == 2) {
            from = [[range objectAtIndex:0] intValue];
            to = [[range objectAtIndex:1] intValue];
        }
        if (from < 1 || to < from)
            continue;
        for (p = from; p <= to && p <= (int)total; p++) {
            NSNumber *number = [NSNumber numberWithInt:p];
            if (![found containsObject:number])
                [found addObject:number];
        }
    }
    return found;
}

@implementation ChatController (Attachments)

- (NSString *)attachmentsDir
{
    NSString *dir = [[self supportDir] stringByAppendingPathComponent:@"attachments"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir attributes:nil];
    return dir;
}

- (NSString *)savedPathForName:(NSString *)name extension:(NSString *)ext
{
    static unsigned counter = 0;
    NSString *stem = [[name lastPathComponent] stringByDeletingPathExtension];
    NSString *safe = [[stem componentsSeparatedByString:@"/"] componentsJoinedByString:@"-"];
    counter++;
    if ([safe length] > 40)
        safe = [safe substringToIndex:40];
    return [[self attachmentsDir] stringByAppendingPathComponent:[NSString stringWithFormat:@"%.0f-%u-%@.%@",
        CFAbsoluteTimeGetCurrent(), counter, safe, ext]];
}

/* A picture: kept as it is when it is a small JPEG, PNG or GIF, otherwise
   redrawn as a JPEG no larger than 1600 pixels on a side. A PDF page is drawn
   larger so its text stays readable. */
- (NSMutableDictionary *)pictureAttachmentFromPath:(NSString *)path name:(NSString *)name pdf:(BOOL)pdf problem:(NSString **)problem
{
    NSImage *image = [[[NSImage alloc] initWithContentsOfFile:path] autorelease];
    return [self pictureAttachmentFromImage:image path:path name:name pdf:pdf problem:problem];
}

- (NSMutableDictionary *)pictureAttachmentFromImage:(NSImage *)image path:(NSString *)path name:(NSString *)name pdf:(BOOL)pdf problem:(NSString **)problem
{
    NSString *ext = [[path pathExtension] lowercaseString];
    NSArray *reps;
    float width = 0;
    float height = 0;
    float scale;
    unsigned i;
    NSString *saved;
    NSData *data = nil;
    double size = [[[[NSFileManager defaultManager] fileAttributesAtPath:path traverseLink:YES] objectForKey:NSFileSize] doubleValue];
    NSMutableDictionary *attachment;
    if (!image) {
        *problem = [NSString stringWithFormat:@"%@ could not be opened as a picture.", name];
        return nil;
    }
    reps = [image representations];
    for (i = 0; i < [reps count]; i++) {
        NSImageRep *rep = [reps objectAtIndex:i];
        if ([rep isKindOfClass:[NSBitmapImageRep class]]) {
            if ([rep pixelsWide] > width)
                width = [rep pixelsWide];
            if ([rep pixelsHigh] > height)
                height = [rep pixelsHigh];
        }
    }
    if (width < 1 || height < 1) {
        width = [image size].width;
        height = [image size].height;
    }
    if (width < 1 || height < 1) {
        *problem = [NSString stringWithFormat:@"%@ has no picture in it.", name];
        return nil;
    }
    scale = (pdf ? 2000.0f : TB_ATTACH_IMAGE_EDGE) / (width > height ? width : height);
    if (!pdf && scale > 1)
        scale = 1;
    if (!pdf && scale >= 1 && size <= 900000
        && ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"] || [ext isEqualToString:@"png"] || [ext isEqualToString:@"gif"])) {
        saved = [self savedPathForName:name extension:ext];
        if (![[NSFileManager defaultManager] copyPath:path toPath:saved handler:nil]) {
            *problem = [NSString stringWithFormat:@"%@ could not be copied.", name];
            return nil;
        }
    } else {
        float tw = floorf(width * scale);
        float th = floorf(height * scale);
        NSImage *drawn = [[NSImage alloc] initWithSize:NSMakeSize(tw, th)];
        NSBitmapImageRep *rep;
        [drawn lockFocus];
        [[NSColor whiteColor] set];
        NSRectFill(NSMakeRect(0, 0, tw, th));
        [image drawInRect:NSMakeRect(0, 0, tw, th) fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:1.0];
        rep = [[NSBitmapImageRep alloc] initWithFocusedViewRect:NSMakeRect(0, 0, tw, th)];
        [drawn unlockFocus];
        data = [rep representationUsingType:NSJPEGFileType
            properties:[NSDictionary dictionaryWithObject:[NSNumber numberWithFloat:0.8f] forKey:NSImageCompressionFactor]];
        [rep release];
        [drawn release];
        saved = [self savedPathForName:name extension:@"jpg"];
        if (!data || ![data writeToFile:saved atomically:YES]) {
            *problem = [NSString stringWithFormat:@"%@ could not be converted to a picture the model can read.", name];
            return nil;
        }
    }
    if (pdf)
        size = [[[[NSFileManager defaultManager] fileAttributesAtPath:saved traverseLink:YES] objectForKey:NSFileSize] doubleValue];
    attachment = [NSMutableDictionary dictionary];
    [attachment setObject:name forKey:@"name"];
    [attachment setObject:saved forKey:@"path"];
    [attachment setObject:@"image" forKey:@"kind"];
    [attachment setObject:[NSNumber numberWithDouble:size] forKey:@"size"];
    {
        /* About a token for every 750 pixels, between a small and a large picture. */
        float pixels = floorf(width * scale) * floorf(height * scale);
        int cost = (int)(pixels / 750.0f);
        if (cost < 300)
            cost = 300;
        if (cost > 1600)
            cost = 1600;
        [attachment setObject:[NSNumber numberWithInt:cost] forKey:@"tokens"];
    }
    [attachment setObject:TBImageMime(saved) forKey:@"mime"];
    return attachment;
}

- (NSMutableDictionary *)textAttachmentWithText:(NSString *)text name:(NSString *)name size:(double)size problem:(NSString **)problem
{
    NSMutableDictionary *attachment;
    NSString *saved = [self savedPathForName:name extension:@"txt"];
    BOOL truncated = NO;
    if ([text length] > TB_ATTACH_TEXT_MAX) {
        text = [text substringToIndex:TB_ATTACH_TEXT_MAX];
        truncated = YES;
    }
    if (![text writeToFile:saved atomically:YES encoding:NSUTF8StringEncoding error:NULL]) {
        *problem = [NSString stringWithFormat:@"%@ could not be copied.", name];
        return nil;
    }
    attachment = [NSMutableDictionary dictionary];
    [attachment setObject:name forKey:@"name"];
    [attachment setObject:saved forKey:@"path"];
    [attachment setObject:@"text" forKey:@"kind"];
    [attachment setObject:[NSNumber numberWithDouble:size] forKey:@"size"];
    [attachment setObject:[NSNumber numberWithInt:(int)([text length] / 3.6) + 40] forKey:@"tokens"];
    [attachment setObject:[NSNumber numberWithBool:truncated] forKey:@"truncated"];
    return attachment;
}

- (NSMutableDictionary *)messageForAttachment:(NSMutableDictionary *)attachment
{
    NSMutableDictionary *message = [NSMutableDictionary dictionary];
    NSString *note = [[attachment objectForKey:@"truncated"] boolValue] ? @", first part only" : @"";
    if ([attachment objectForKey:@"note"])
        note = [note stringByAppendingFormat:@". %@", [attachment objectForKey:@"note"]];
    [message setObject:@"user" forKey:@"role"];
    [message setObject:[NSString stringWithFormat:@"Attached: %@ (%@%@)", [attachment objectForKey:@"name"],
        TBHumanSize([[attachment objectForKey:@"size"] doubleValue]), note] forKey:@"text"];
    [message setObject:[NSNumber numberWithBool:NO] forKey:@"status"];
    [message setObject:attachment forKey:@"attachment"];
    if ([[attachment objectForKey:@"kind"] isEqualToString:@"image"])
        [message setObject:[attachment objectForKey:@"path"] forKey:@"image"];
    return message;
}

/* The text of a PDF, from PDFKit when this Mac has it. */
static NSString *pdfText(NSString *path)
{
    static BOOL tried = NO;
    Class pdfClass;
    id document;
    NSString *text = nil;
    if (!tried) {
        tried = YES;
        [[NSBundle bundleWithPath:@"/System/Library/Frameworks/Quartz.framework/Frameworks/PDFKit.framework"] load];
        [[NSBundle bundleWithPath:@"/System/Library/Frameworks/PDFKit.framework"] load];
    }
    pdfClass = NSClassFromString(@"PDFDocument");
    if (!pdfClass)
        return nil;
    document = [[pdfClass alloc] performSelector:@selector(initWithURL:) withObject:[NSURL fileURLWithPath:path]];
    if (document) {
        text = [document performSelector:@selector(string)];
        text = [[text copy] autorelease];
        [document release];
    }
    return text;
}

/* Text taken from drawings and scans comes out in scraps: a watermark or a rotated
   label becomes one letter per line. Runs of three or more very short lines are dropped. */
static NSString *cleanedPDFText(NSString *raw, unsigned *dropped)
{
    NSArray *lines = [raw componentsSeparatedByString:@"\n"];
    NSMutableString *out = [NSMutableString string];
    unsigned i = 0;
    *dropped = 0;
    while (i < [lines count]) {
        unsigned j = i;
        while (j < [lines count] && [[[lines objectAtIndex:j] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] length] <= 3
            && [[[lines objectAtIndex:j] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] length] > 0)
            j++;
        if (j - i >= 3) {
            *dropped += j - i;
            i = j;
            continue;
        }
        [out appendString:[lines objectAtIndex:i]];
        [out appendString:@"\n"];
        i++;
    }
    return out;
}

static unsigned pdfPageCount(NSString *path)
{
    NSPDFImageRep *rep = [NSPDFImageRep imageRepWithData:[NSData dataWithContentsOfMappedFile:path]];
    return rep ? (unsigned)[rep pageCount] : 0;
}

/* A PDF: its text, cleaned. When it is mostly drawing (little text for its pages) or has no text,
   its first pages are queued to follow as pictures, because the model needs to see those. */
- (NSArray *)pdfAttachmentsForJob:(NSDictionary *)job size:(double)size problem:(NSString **)problem
{
    NSString *path = [job objectForKey:@"path"];
    NSString *name = [path lastPathComponent];
    NSString *raw = pdfText(path);
    unsigned dropped = 0;
    NSString *text = raw ? cleanedPDFText(raw, &dropped) : @"";
    unsigned pages = pdfPageCount(path);
    unsigned usable = [[text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length];
    BOOL scrap = pages > 0 && (usable / (float)pages < 700 || dropped > 200);
    NSMutableArray *found = [NSMutableArray array];
    BOOL haveText = NO;
    if (usable > 20) {
        NSMutableDictionary *textPart = [self textAttachmentWithText:text name:name size:size problem:problem];
        if (!textPart)
            return nil;
        [found addObject:textPart];
        haveText = YES;
    }
    if (pages == 0 && !haveText) {
        *problem = [NSString stringWithFormat:@"%@ could not be read as a PDF.", name];
        return nil;
    }
    if (pages > 0 && (!haveText || scrap)) {
        unsigned want = pages < 3 ? pages : 3;
        unsigned p;
        for (p = want; p > 0; p--) {
            [attachQueue insertObject:[NSDictionary dictionaryWithObjectsAndKeys:path, @"path", [job objectForKey:@"chat"], @"chat",
                [job objectForKey:@"generation"] ? [job objectForKey:@"generation"] : [NSNumber numberWithInt:attachGeneration],
                @"generation", @"pdfpage", @"kind", [NSNumber numberWithUnsignedInt:p], @"page", [NSNumber numberWithUnsignedInt:pages], @"pages",
                [NSNumber numberWithBool:(p == want && pages > want)], @"more", nil] atIndex:0];
        }
    }
    return found;
}

/* One page of a PDF as a picture. */
- (NSArray *)pdfPageAttachmentForJob:(NSDictionary *)job problem:(NSString **)problem
{
    NSString *path = [job objectForKey:@"path"];
    NSString *name = [path lastPathComponent];
    unsigned page = [[job objectForKey:@"page"] unsignedIntValue];
    unsigned pages = [[job objectForKey:@"pages"] unsignedIntValue];
    NSPDFImageRep *rep = [NSPDFImageRep imageRepWithData:[NSData dataWithContentsOfMappedFile:path]];
    NSImage *picture;
    NSMutableDictionary *attachment;
    if (!rep || page < 1 || page > (unsigned)[rep pageCount]) {
        *problem = [NSString stringWithFormat:@"%@ has no page %u.", name, page];
        return nil;
    }
    [rep setCurrentPage:page - 1];
    picture = [[[NSImage alloc] initWithSize:[rep size]] autorelease];
    [picture addRepresentation:rep];
    attachment = [self pictureAttachmentFromImage:picture path:path
        name:[NSString stringWithFormat:@"%@ (page %u of %u)", name, page, pages] pdf:YES problem:problem];
    [picture removeRepresentation:rep];
    if (!attachment)
        return nil;
    if ([[job objectForKey:@"more"] boolValue])
        [attachment setObject:[NSString stringWithFormat:@"Only the first %u of %u pages were sent as pictures. The person can add others with Chat > Attach PDF Pages.",
            page, pages] forKey:@"note"];
    return [NSArray arrayWithObject:attachment];
}

- (NSArray *)attachmentsForPath:(NSString *)path problem:(NSString **)problem
{
    NSString *name = [path lastPathComponent];
    NSString *ext = [[path pathExtension] lowercaseString];
    NSFileManager *manager = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    double size;
    NSString *text;
    NSMutableDictionary *one;
    NSArray *pictures = [NSArray arrayWithObjects:@"jpg", @"jpeg", @"jpe", @"png", @"gif", @"tif", @"tiff", @"bmp", @"pict", @"pct",
        @"jp2", @"psd", @"tga", @"icns", @"ico", nil];
    NSArray *documents = [NSArray arrayWithObjects:@"rtf", @"rtfd", @"doc", @"html", @"htm", @"webarchive", nil];
    if (![manager fileExistsAtPath:path isDirectory:&isDirectory]) {
        *problem = [NSString stringWithFormat:@"%@ is not there any more.", name];
        return nil;
    }
    if (isDirectory && ![ext isEqualToString:@"rtfd"]) {
        *problem = [NSString stringWithFormat:@"%@ is a folder. Attach the files in it, or let Commander read the folder.", name];
        return nil;
    }
    size = [[[manager fileAttributesAtPath:path traverseLink:YES] objectForKey:NSFileSize] doubleValue];
    if (size > TB_ATTACH_MAX_BYTES) {
        *problem = [NSString stringWithFormat:@"%@ is %@. Files over 40 MB cannot be attached.", name, TBHumanSize(size)];
        return nil;
    }
    if ([pictures containsObject:ext]) {
        NSMutableDictionary *one = [self pictureAttachmentFromPath:path name:name pdf:NO problem:problem];
        return one ? [NSArray arrayWithObject:one] : nil;
    }
    if ([documents containsObject:ext]) {
        NSAttributedString *rich = [[[NSAttributedString alloc] initWithPath:path documentAttributes:NULL] autorelease];
        text = [rich string];
        if ([text length] == 0 && [ext isEqualToString:@"doc"]) {
            /* Cocoa could not read it (a newer Mac, or a file it dislikes): the converter reads Word 97 to 2003 files itself */
            NS_DURING
                text = [[TBExtract extractName:name data:[NSData dataWithContentsOfFile:path]] objectForKey:@"text"];
            NS_HANDLER
                text = nil;
            NS_ENDHANDLER
        }
        if ([text length] == 0) {
            *problem = [NSString stringWithFormat:@"%@ could not be read on this version of Mac OS X. Save it as text, RTF or PDF and attach that.", name];
            return nil;
        }
        one = [self textAttachmentWithText:text name:name size:size problem:problem];
        return one ? [NSArray arrayWithObject:one] : nil;
    }
    text = TBReadTextFile(path, TB_ATTACH_TEXT_MAX, NULL);
    if (!text) {
        *problem = [NSString stringWithFormat:@"%@ does not look like a text file. Text and code files, PDFs, Word, Excel, PowerPoint, Pages, Numbers and Keynote files, RTF and HTML documents, and pictures (including HEIC and WebP) can be attached.", name];
        return nil;
    }
    one = [self textAttachmentWithText:text name:name size:size problem:problem];
    return one ? [NSArray arrayWithObject:one] : nil;
}

/* ---- the queue ----
   Files are read one at a time, each with a "Reading..." note in the chat, and the window is
   free between steps, so a big PDF does not freeze it. */

/* Ask once, the first time, and remember the answer (one entry in the TBConsent preference per question). */
BOOL TBConfirmOnce(NSString *key, NSString *title, NSString *message, NSString *okTitle)
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *known = [defaults dictionaryForKey:@"TBConsent"];
    NSMutableDictionary *updated;
    if ([[known objectForKey:key] boolValue])
        return YES;
    if (NSRunAlertPanel(title, @"%@", okTitle, @"Cancel", nil, message) != NSAlertDefaultReturn)
        return NO;
    updated = [NSMutableDictionary dictionaryWithDictionary:known];
    [updated setObject:[NSNumber numberWithBool:YES] forKey:key];
    [defaults setObject:updated forKey:@"TBConsent"];
    [defaults synchronize];
    return YES;
}

/* Attached files go to the service chosen for the chat when a message is sent. Say so once for each service. */
- (BOOL)chatHasAttachments:(NSDictionary *)chat
{
    NSArray *messages = [chat objectForKey:@"messages"];
    unsigned i;
    for (i = 0; i < [messages count]; i++) {
        if ([[messages objectAtIndex:i] objectForKey:@"attachment"])
            return YES;
    }
    return NO;
}

- (BOOL)confirmCloudAttach
{
    NSString *provider = [self providerForChat:current];
    NSString *service;
    if ([provider isEqualToString:@"local"])
        return YES;
    service = [[ModelCatalog shared] titleForProvider:provider];
    if (!service)
        service = provider;
    return TBConfirmOnce([@"attach:" stringByAppendingString:provider], [NSString stringWithFormat:@"Send attached files to %@?", service],
        [NSString stringWithFormat:@"Attached files are sent to %@ with your messages. Attach only what you are happy to share with it. "
        @"Locally hosted models will only have attachments sent to them in the manner you've configured.", service], @"Attach");
}

- (void)attachPaths:(NSArray *)paths
{
    unsigned i;
    if (!current || [paths count] == 0)
        return;
    if (busy || [self chatIsBusyElsewhere:current]) {
        [self setRelayProblem:@"Wait for the reply to finish before attaching a file."];
        NSBeep();
        return;
    }
    if (![self confirmCloudAttach])
        return;
    if (!attachQueue)
        attachQueue = [[NSMutableArray alloc] init];
    if (!attachProblems)
        attachProblems = [[NSMutableArray alloc] init];
    for (i = 0; i < [paths count]; i++)
        [attachQueue addObject:[NSDictionary dictionaryWithObjectsAndKeys:[paths objectAtIndex:i], @"path", current, @"chat", @"file", @"kind",
            [NSNumber numberWithInt:attachGeneration], @"generation", nil]];
    [self forgetEdit];
    [self syncRunButtons];
    if (!attachWorking) {
        attachWorking = YES;
        [self performSelector:@selector(attachNext) withObject:nil afterDelay:0.0];
    }
}

- (void)attachNext
{
    NSDictionary *job;
    NSMutableDictionary *chat;
    NSMutableDictionary *placeholder;
    NSString *name;
    NSMutableDictionary *running;
    if ([attachQueue count] == 0) {
        attachWorking = NO;
        [self saveStore];
        if ([attachProblems count] > 0) {
            NSString *all = [attachProblems componentsJoinedByString:@"\n\n"];
            [attachProblems removeAllObjects];
            NSRunAlertPanel(@"Could not attach", @"%@", @"OK", nil, nil, all);
        }
        return;
    }
    job = [[[attachQueue objectAtIndex:0] retain] autorelease];
    [attachQueue removeObjectAtIndex:0];
    if ([[job objectForKey:@"generation"] intValue] != attachGeneration) {
        [self performSelector:@selector(attachNext) withObject:nil afterDelay:0.0];
        return;
    }
    chat = [job objectForKey:@"chat"];
    if ([chats indexOfObjectIdenticalTo:chat] == NSNotFound) {
        [self performSelector:@selector(attachNext) withObject:nil afterDelay:0.0];
        return;
    }
    name = [[job objectForKey:@"path"] lastPathComponent];
    placeholder = [NSMutableDictionary dictionary];
    [placeholder setObject:@"user" forKey:@"role"];
    [placeholder setObject:[[job objectForKey:@"kind"] isEqualToString:@"pdfpage"]
        ? [NSString stringWithFormat:@"Reading page %u of %@...", [[job objectForKey:@"page"] unsignedIntValue], name]
        : [NSString stringWithFormat:@"Reading %@...", name] forKey:@"text"];
    [placeholder setObject:[NSNumber numberWithBool:NO] forKey:@"status"];
    [placeholder setObject:[NSNumber numberWithBool:YES] forKey:@"converting"];
    [[chat objectForKey:@"messages"] addObject:placeholder];
    [self refreshTranscriptIfCurrent:chat];
    running = [NSMutableDictionary dictionaryWithDictionary:job];
    [running setObject:placeholder forKey:@"placeholder"];
    /* A moment for the window to draw the note before the work starts. */
    [self performSelector:@selector(attachRun:) withObject:running afterDelay:0.05];
}

- (void)attachRun:(NSDictionary *)job
{
    if ([[job objectForKey:@"generation"] intValue] != attachGeneration)
        return;
    NSString *path = [job objectForKey:@"path"];
    NSString *ext = [[path pathExtension] lowercaseString];
    NSString *problem = nil;
    NSArray *made = nil;
    if ([[job objectForKey:@"kind"] isEqualToString:@"pdfpage"]) {
        made = [self pdfPageAttachmentForJob:job problem:&problem];
    } else if ([self relayConverts:path]) {
        if ([self startRelayConversion:job problem:&problem])
            return;
    } else if ([ext isEqualToString:@"pdf"]) {
        NSFileManager *manager = [NSFileManager defaultManager];
        double size = [[[manager fileAttributesAtPath:path traverseLink:YES] objectForKey:NSFileSize] doubleValue];
        if (![manager fileExistsAtPath:path])
            problem = [NSString stringWithFormat:@"%@ is not there any more.", [path lastPathComponent]];
        else if (size > TB_ATTACH_MAX_BYTES)
            problem = [NSString stringWithFormat:@"%@ is %@. Files over 40 MB cannot be attached.", [path lastPathComponent], TBHumanSize(size)];
        else
            made = [self pdfAttachmentsForJob:job size:size problem:&problem];
    } else {
        made = [self attachmentsForPath:path problem:&problem];
    }
    [self finishJob:job made:made problem:problem];
}

/* Stop while files are being read: forget what is waiting, drop the notes, and let the relay's answer go unread. */
- (BOOL)cancelAttachments
{
    unsigned c;
    if (!attachWorking)
        return NO;
    attachGeneration++;
    [attachQueue removeAllObjects];
    [attachProblems removeAllObjects];
    if (attachRequest)
        [attachRequest cancel];
    attachRequest = nil;
    attachWorking = NO;
    for (c = 0; c < [chats count]; c++) {
        NSMutableArray *list = [[chats objectAtIndex:c] objectForKey:@"messages"];
        int m;
        for (m = (int)[list count] - 1; m >= 0; m--) {
            if ([[list objectAtIndex:m] objectForKey:@"converting"])
                [list removeObjectAtIndex:m];
        }
    }
    [self saveStore];
    [self refreshTranscriptIfCurrent:current];
    [self syncRunButtons];
    return YES;
}

- (BOOL)attachmentsRunning
{
    return attachWorking;
}

/* The job is over: its "Reading..." note becomes the files, after a check that they fit. */
- (void)finishJob:(NSDictionary *)job made:(NSArray *)made problem:(NSString *)problem
{
    NSMutableDictionary *placeholder = [job objectForKey:@"placeholder"];
    NSMutableDictionary *chat = [job objectForKey:@"chat"];
    NSMutableArray *messages = [chat objectForKey:@"messages"];
    NSUInteger index = [messages indexOfObjectIdenticalTo:placeholder];
    if (index != NSNotFound) {
        [messages removeObjectAtIndex:index];
        if ([made count] > 0) {
            NSArray *kept = [self confirmedAttachments:made chat:chat];
            unsigned k;
            for (k = 0; k < [kept count]; k++)
                [messages insertObject:[self messageForAttachment:[kept objectAtIndex:k]] atIndex:index + k];
        }
    }
    if (problem && ![made count])
        [attachProblems addObject:problem];
    if ([chats indexOfObjectIdenticalTo:chat] != NSNotFound) {
        [self saveStore];
        [self refreshTranscriptIfCurrent:chat];
        [self updateContextReadout];
        [self syncRunButtons];
    }
    [self performSelector:@selector(attachNext) withObject:nil afterDelay:0.01];
}

/* Whether what was just read fits the model's context. A big file is offered shortened, and
   a model with a small window is told so now instead of failing on the next message. */
- (NSArray *)confirmedAttachments:(NSArray *)made chat:(NSMutableDictionary *)chat
{
    int limit = [[chat objectForKey:@"contextLimit"] intValue];
    int incoming = 0;
    int used;
    unsigned i;
    BOOL shortenable = NO;
    int choice;
    int act;
    NSString *what;
    if (limit < 1000)
        return made;
    for (i = 0; i < [made count]; i++) {
        NSDictionary *item = [made objectAtIndex:i];
        incoming += [[item objectForKey:@"tokens"] intValue] + 12;
        if ([[item objectForKey:@"kind"] isEqualToString:@"text"])
            shortenable = YES;
    }
    used = [self contextTokensForChat:chat];
    if ((long)(used + incoming) * 100 <= (long)limit * 60)
        return made;
    what = [[made objectAtIndex:0] objectForKey:@"name"];
    /* act: 0 attach as it is, 1 attach shortened, 2 do not attach */
    if ((long)(used + incoming) > (long)limit * 95 / 100) {
        NSString *message = [NSString stringWithFormat:@"%@ is about %@ tokens, and this chat already uses about %@ of the %@ that %@ can hold at once. "
            @"The model would refuse the next message. Shorten the file, or choose a model with a larger context.",
            what, [self tokenString:incoming], [self tokenString:used], [self tokenString:limit], [self modelForChat:chat]];
        if (shortenable) {
            choice = NSRunAlertPanel(@"This will not fit", @"%@", @"Attach Shortened", @"Cancel", @"Attach Anyway", message);
            act = choice == NSAlertDefaultReturn ? 1 : (choice == NSAlertAlternateReturn ? 2 : 0);
        } else {
            choice = NSRunAlertPanel(@"This will not fit", @"%@", @"Cancel", @"Attach Anyway", nil, message);
            act = choice == NSAlertDefaultReturn ? 2 : 0;
        }
    } else {
        NSString *message = [NSString stringWithFormat:@"%@ is about %@ tokens, which brings this chat to about %d%% of what %@ can hold at once. "
            @"A long file also makes every later message slower and costlier.",
            what, [self tokenString:incoming], (int)((long)(used + incoming) * 100 / limit), [self modelForChat:chat]];
        if (shortenable) {
            choice = NSRunAlertPanel(@"This is a lot of context", @"%@", @"Attach", @"Cancel", @"Attach Shortened", message);
            act = choice == NSAlertDefaultReturn ? 0 : (choice == NSAlertAlternateReturn ? 2 : 1);
        } else {
            choice = NSRunAlertPanel(@"This is a lot of context", @"%@", @"Attach", @"Cancel", nil, message);
            act = choice == NSAlertDefaultReturn ? 0 : 2;
        }
    }
    if (act == 2) {
        for (i = 0; i < [made count]; i++)
            [[NSFileManager defaultManager] removeFileAtPath:[[made objectAtIndex:i] objectForKey:@"path"] handler:nil];
        return [NSArray array];
    }
    if (act == 1) {
        int room = limit / 2 - used;
        if (room < 2000)
            room = 2000;
        for (i = 0; i < [made count]; i++) {
            NSMutableDictionary *item = [made objectAtIndex:i];
            if ([[item objectForKey:@"kind"] isEqualToString:@"text"]) {
                int share = room / (int)[made count];
                NSString *body = TBReadTextFile([item objectForKey:@"path"], TB_ATTACH_TEXT_MAX, NULL);
                if (body && (int)([body length] / 3.6) > share) {
                    body = [body substringToIndex:(unsigned)(share * 3.6)];
                    [body writeToFile:[item objectForKey:@"path"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                    [item setObject:[NSNumber numberWithInt:share + 40] forKey:@"tokens"];
                    [item setObject:[NSNumber numberWithBool:YES] forKey:@"truncated"];
                }
            }
        }
    }
    return made;
}

/* Chat > Attach PDF Pages: some pages of a PDF as pictures, for drawings and layouts the text does not describe. */
- (IBAction)attachPDFPages:(id)sender
{
    NSOpenPanel *panel;
    NSString *path;
    unsigned pages;
    NSString *answer;
    NSArray *wanted;
    unsigned i;
    (void)sender;
    if (!current || busy)
        return;
    panel = [NSOpenPanel openPanel];
    [panel setAllowsMultipleSelection:NO];
    [panel setCanChooseDirectories:NO];
    [panel setMessage:@"Choose a PDF. You will then pick which pages to add as pictures."];
    if ([panel runModalForDirectory:nil file:nil types:[NSArray arrayWithObject:@"pdf"]] != NSOKButton)
        return;
    path = [panel filename];
    pages = pdfPageCount(path);
    if (pages == 0) {
        NSRunAlertPanel(@"Could not attach", @"%@ could not be read as a PDF.", @"OK", nil, nil, [path lastPathComponent]);
        return;
    }
    answer = [TBPagePrompt ask:[NSString stringWithFormat:@"Which pages of %@ (%u pages) should be added as pictures? For example 1-3, 7. Up to 12 at a time.",
        [path lastPathComponent], pages] title:@"Attach PDF Pages"];
    if (!answer)
        return;
    wanted = pagesFromSpec(answer, pages);
    if ([wanted count] == 0) {
        NSRunAlertPanel(@"Attach PDF Pages", @"No page numbers between 1 and %u were given.", @"OK", nil, nil, pages);
        return;
    }
    if (busy || ![self confirmCloudAttach])
        return;
    if (!attachQueue)
        attachQueue = [[NSMutableArray alloc] init];
    if (!attachProblems)
        attachProblems = [[NSMutableArray alloc] init];
    for (i = 0; i < [wanted count] && i < 12; i++)
        [attachQueue addObject:[NSDictionary dictionaryWithObjectsAndKeys:path, @"path", current, @"chat", @"pdfpage", @"kind",
            [wanted objectAtIndex:i], @"page", [NSNumber numberWithUnsignedInt:pages], @"pages",
            [NSNumber numberWithInt:attachGeneration], @"generation", nil]];
    [self forgetEdit];
    if (!attachWorking) {
        attachWorking = YES;
        [self performSelector:@selector(attachNext) withObject:nil afterDelay:0.0];
    }
}

- (IBAction)attachFile:(id)sender
{
    NSOpenPanel *panel;
    (void)sender;
    if (!current || busy)
        return;
    panel = [NSOpenPanel openPanel];
    [panel setAllowsMultipleSelection:YES];
    [panel setCanChooseDirectories:NO];
    [panel setMessage:@"Choose files to add to this chat. The model can use them for the rest of the conversation."];
    if ([panel runModalForDirectory:nil file:nil types:nil] != NSOKButton)
        return;
    [self attachPaths:[panel filenames]];
}

/* Every file path a property list mentions under the keys chats use. */
static void collectStoredPaths(id plist, NSMutableSet *used)
{
    if ([plist isKindOfClass:[NSDictionary class]]) {
        NSEnumerator *keys = [plist keyEnumerator];
        NSString *key;
        while ((key = [keys nextObject])) {
            id value = [plist objectForKey:key];
            if ([value isKindOfClass:[NSString class]]) {
                if ([key isEqualToString:@"path"] || [key isEqualToString:@"image"] || [key isEqualToString:@"video"] || [key isEqualToString:@"file"])
                    [used addObject:value];
            } else {
                collectStoredPaths(value, used);
            }
        }
    } else if ([plist isKindOfClass:[NSArray class]]) {
        unsigned i;
        for (i = 0; i < [plist count]; i++)
            collectStoredPaths([plist objectAtIndex:i], used);
    }
}

/* Files kept for chats that no longer exist are removed: attachments, and pictures and files
   the model made. A file stays while any chat in any workspace points to it, and while it is
   under ten minutes old (a message taken back for editing is not in a chat for a moment). */
- (void)sweepStoredFiles
{
    NSDictionary *all = [self allWorkspaces];
    NSMutableSet *used = [NSMutableSet set];
    NSEnumerator *spaces = [all objectEnumerator];
    NSDictionary *space;
    NSFileManager *manager = [NSFileManager defaultManager];
    NSArray *dirs = [NSArray arrayWithObjects:@"attachments", @"media", nil];
    unsigned d;
    while ((space = [spaces nextObject])) {
        NSArray *list = [space objectForKey:@"chats"];
        unsigned c;
        for (c = 0; c < [list count]; c++) {
            NSArray *messages = [[list objectAtIndex:c] objectForKey:@"messages"];
            unsigned m;
            for (m = 0; m < [messages count]; m++) {
                NSDictionary *message = [messages objectAtIndex:m];
                NSString *path;
                if ((path = [[message objectForKey:@"attachment"] objectForKey:@"path"]))
                    [used addObject:path];
                if ((path = [message objectForKey:@"image"]))
                    [used addObject:path];
                if ((path = [message objectForKey:@"video"]))
                    [used addObject:path];
                if ((path = [message objectForKey:@"file"]))
                    [used addObject:path];
            }
        }
    }
    {
        /* A backup made before an import still points at its files. */
        NSArray *support = [manager directoryContentsAtPath:[self supportDir]];
        unsigned b;
        for (b = 0; b < [support count]; b++) {
            NSString *file = [support objectAtIndex:b];
            if ([file hasPrefix:@"history-before-import-"] && [file hasSuffix:@".plist"]) {
                NSData *raw = [NSData dataWithContentsOfFile:[[self supportDir] stringByAppendingPathComponent:file]];
                id plist = raw ? [NSPropertyListSerialization propertyListFromData:raw mutabilityOption:NSPropertyListImmutable
                    format:NULL errorDescription:NULL] : nil;
                collectStoredPaths(plist, used);
            }
        }
    }
    if (editBackup) {
        unsigned m;
        for (m = 0; m < [editBackup count]; m++) {
            NSDictionary *message = [editBackup objectAtIndex:m];
            NSString *path = [[message objectForKey:@"attachment"] objectForKey:@"path"];
            if (path)
                [used addObject:path];
        }
    }
    for (d = 0; d < [dirs count]; d++) {
        NSString *dir = [[self supportDir] stringByAppendingPathComponent:[dirs objectAtIndex:d]];
        NSArray *names = [manager directoryContentsAtPath:dir];
        unsigned n;
        for (n = 0; n < [names count]; n++) {
            NSString *path = [dir stringByAppendingPathComponent:[names objectAtIndex:n]];
            NSDate *modified = [[manager fileAttributesAtPath:path traverseLink:NO] objectForKey:NSFileModificationDate];
            if ([used containsObject:path])
                continue;
            if (!modified || -[modified timeIntervalSinceNow] < 600)
                continue;
            [manager removeFileAtPath:path handler:nil];
        }
    }
}

/* ---- files the engine converts ----
   Word, Excel and PowerPoint files, Pages, Numbers and Keynote files, and pictures in
   newer formats cannot be read on these Macs. TBExtract turns them into text and JPEG pictures. */

- (BOOL)relayConverts:(NSString *)path
{
    NSArray *kinds = [NSArray arrayWithObjects:@"docx", @"pptx", @"xlsx", @"ppt", @"xls", @"pages", @"numbers", @"key", @"odt", @"ods", @"odp",
        @"heic", @"heif", @"webp", @"avif", @"gif", @"jpg", @"jpeg", nil];
    return [kinds containsObject:[[path pathExtension] lowercaseString]];
}

- (BOOL)startRelayConversion:(NSDictionary *)job problem:(NSString **)problem
{
    NSString *path = [job objectForKey:@"path"];
    NSString *name = [path lastPathComponent];
    NSFileManager *manager = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    NSData *data;
    NSString *zipped = nil;
    NSMutableDictionary *info;
    double size;
    if (![manager fileExistsAtPath:path isDirectory:&isDirectory]) {
        *problem = [NSString stringWithFormat:@"%@ is not there any more.", name];
        return NO;
    }
    if (isDirectory) {
        /* An iWork document saved as a folder: send it zipped. */
        NSTask *task = [[[NSTask alloc] init] autorelease];
        zipped = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"tb-%u-%@.zip", (unsigned)getpid(), name]];
        [task setLaunchPath:@"/usr/bin/ditto"];
        [task setArguments:[NSArray arrayWithObjects:@"-c", @"-k", path, zipped, nil]];
        [task launch];
        [task waitUntilExit];
    }
    size = [[[manager fileAttributesAtPath:zipped ? zipped : path traverseLink:YES] objectForKey:NSFileSize] doubleValue];
    if (size > 70 * 1024 * 1024) {
        *problem = [NSString stringWithFormat:@"%@ is %@. Files over 70 MB cannot be converted.", name, TBHumanSize(size)];
        return NO;
    }
    data = [NSData dataWithContentsOfMappedFile:zipped ? zipped : path];
    if (zipped)
        [manager removeFileAtPath:zipped handler:nil];
    if (!data || [data length] == 0) {
        *problem = [NSString stringWithFormat:@"%@ could not be read.", name];
        return NO;
    }
    [[job objectForKey:@"placeholder"] setObject:[NSString stringWithFormat:@"Converting %@...", name] forKey:@"text"];
    [self refreshTranscriptIfCurrent:[job objectForKey:@"chat"]];
    info = [NSMutableDictionary dictionaryWithDictionary:job];
    [info setObject:[NSNumber numberWithDouble:size] forKey:@"size"];
    attachRequest = [EngineRequest sendFile:data name:name path:@"/v1/extract" timeout:240 target:self action:@selector(conversionArrived:) context:info];
    return YES;
}

- (void)conversionArrived:(EngineRequest *)request
{
    NSDictionary *info = [request context];
    if ([[info objectForKey:@"generation"] intValue] != attachGeneration)
        return;
    attachRequest = nil;
    NSString *path = [info objectForKey:@"path"];
    NSString *name = [path lastPathComponent];
    double size = [[info objectForKey:@"size"] doubleValue];
    NSMutableArray *made = [NSMutableArray array];
    NSString *problem = nil;
    NSDictionary *result = nil;
    if ([request ok]) {
        NSString *error = nil;
        result = [NSPropertyListSerialization propertyListFromData:[request data] mutabilityOption:NSPropertyListImmutable
            format:NULL errorDescription:&error];
        if (error)
            [error release];
        if (![result isKindOfClass:[NSDictionary class]])
            result = nil;
    }
    if (!result) {
        NSString *why = [[request text] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *ext = [[name pathExtension] lowercaseString];
        if ([request status] == 0)
            why = [request timedOut] ? @"It took too long." : @"The converter could not be reached.";
        if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) {
            /* The converter only straightens photos; without it the picture is used as it is. */
            NSMutableDictionary *plain = [self pictureAttachmentFromPath:path name:name pdf:NO problem:&problem];
            if (plain) {
                [made addObject:plain];
                problem = nil;
            }
        } else {
            problem = [NSString stringWithFormat:@"%@ could not be converted. %@", name, why ? why : @""];
        }
    } else {
        NSString *text = [result objectForKey:@"text"];
        NSArray *pictures = [result objectForKey:@"images"];
        NSString *note = [result objectForKey:@"note"];
        unsigned i;
        if ([text isKindOfClass:[NSString class]] && [[text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length] > 0) {
            NSString *why = nil;
            NSMutableDictionary *attachment = [self textAttachmentWithText:text name:name size:size problem:&why];
            if (attachment) {
                if ([note length] > 0)
                    [attachment setObject:note forKey:@"note"];
                [made addObject:attachment];
            } else {
                problem = why;
            }
        }
        for (i = 0; [pictures isKindOfClass:[NSArray class]] && i < [pictures count] && i < 4; i++) {
            NSData *jpeg = [pictures objectAtIndex:i];
            NSString *why = nil;
            NSString *temp = [self savedPathForName:name extension:@"jpg"];
            NSMutableDictionary *attachment = nil;
            NSString *shownName = ([note hasPrefix:@"An animated"] && [pictures count] > 1) ? [name stringByAppendingFormat:@" (frame %u)", i + 1]
                : (([text length] > 0 || [pictures count] > 1) ? [name stringByAppendingString:@" (preview)"] : name);
            if ([jpeg isKindOfClass:[NSData class]] && [jpeg writeToFile:temp atomically:YES]) {
                attachment = [self pictureAttachmentFromPath:temp name:shownName pdf:NO problem:&why];
                [[NSFileManager defaultManager] removeFileAtPath:temp handler:nil];
            }
            if (attachment) {
                [attachment setObject:[NSNumber numberWithDouble:size] forKey:@"size"];
                if ([text length] == 0 && [note length] > 0)
                    [attachment setObject:note forKey:@"note"];
                [made addObject:attachment];
            }
        }
        if ([made count] == 0 && !problem)
            problem = [NSString stringWithFormat:@"Nothing could be read from %@.", name];
    }
    [self finishJob:info made:made problem:problem];
}

- (NSArray *)imageAttachmentsForChat:(NSDictionary *)chat
{
    NSArray *messages = [chat objectForKey:@"messages"];
    NSMutableArray *found = [NSMutableArray array];
    int i;
    double total = 0;
    for (i = (int)[messages count] - 1; i >= 0 && [found count] < 6; i--) {
        NSDictionary *file = [[messages objectAtIndex:i] objectForKey:@"attachment"];
        if (file && [[file objectForKey:@"kind"] isEqualToString:@"image"]) {
            double bytes = [[[[NSFileManager defaultManager] fileAttributesAtPath:[file objectForKey:@"path"] traverseLink:YES]
                objectForKey:NSFileSize] doubleValue];
            /* The relay takes 40 MB at most, and pictures travel as text a third larger. */
            if (total + bytes > 18.0 * 1024 * 1024)
                break;
            total += bytes;
            [found insertObject:[messages objectAtIndex:i] atIndex:0];
        }
    }
    return found;
}

@end
