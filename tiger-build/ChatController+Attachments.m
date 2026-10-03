#import "ChatController_Private.h"

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
- (BOOL)startRelayConversion:(NSString *)path problem:(NSString **)problem;
@end

@interface ChatController (HistorySweep)
- (NSDictionary *)allWorkspaces;
@end

@interface ChatController (AttachmentsPrivate)
- (NSString *)attachmentsDir;
- (NSString *)savedPathForName:(NSString *)name extension:(NSString *)ext;
- (NSMutableDictionary *)pictureAttachmentFromPath:(NSString *)path name:(NSString *)name pdf:(BOOL)pdf problem:(NSString **)problem;
- (NSMutableDictionary *)pictureAttachmentFromImage:(NSImage *)image path:(NSString *)path name:(NSString *)name pdf:(BOOL)pdf problem:(NSString **)problem;
- (NSArray *)pdfAttachmentsForPath:(NSString *)path name:(NSString *)name size:(double)size problem:(NSString **)problem;
- (NSMutableDictionary *)textAttachmentWithText:(NSString *)text name:(NSString *)name size:(double)size problem:(NSString **)problem;
- (NSMutableDictionary *)messageForAttachment:(NSMutableDictionary *)attachment;
@end

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
    [attachment setObject:[NSNumber numberWithInt:1000] forKey:@"tokens"];
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

/* A PDF: its text, cleaned, and when it is mostly drawing (little text for its pages)
   the first pages as pictures too, because the model needs to see those. */
- (NSArray *)pdfAttachmentsForPath:(NSString *)path name:(NSString *)name size:(double)size problem:(NSString **)problem
{
    NSString *raw = pdfText(path);
    unsigned dropped = 0;
    NSString *text = raw ? cleanedPDFText(raw, &dropped) : @"";
    unsigned pages = pdfPageCount(path);
    unsigned usable = [[text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length];
    BOOL scrap = pages > 0 && (usable / (float)pages < 700 || dropped > 200);
    NSMutableArray *found = [NSMutableArray array];
    NSMutableDictionary *textPart = nil;
    unsigned shown = 0;
    unsigned p;
    if (usable > 20) {
        NSString *note = nil;
        textPart = [self textAttachmentWithText:text name:name size:size problem:problem];
        if (!textPart)
            return nil;
        (void)note;
        [found addObject:textPart];
    }
    if (!textPart || scrap) {
        NSData *data = [NSData dataWithContentsOfMappedFile:path];
        NSPDFImageRep *rep = [NSPDFImageRep imageRepWithData:data];
        unsigned want = pages < 3 ? pages : 3;
        if (!rep) {
            if (!textPart)
                *problem = [NSString stringWithFormat:@"%@ could not be read as a PDF.", name];
            return textPart ? found : nil;
        }
        for (p = 0; p < want; p++) {
            NSImage *page = [[[NSImage alloc] initWithSize:[rep size]] autorelease];
            NSString *pageName = [NSString stringWithFormat:@"%@ (page %u of %u)", name, p + 1, pages];
            NSMutableDictionary *picture;
            NSString *pictureProblem = nil;
            [rep setCurrentPage:p];
            [page addRepresentation:rep];
            picture = [self pictureAttachmentFromImage:page path:path name:pageName pdf:YES problem:&pictureProblem];
            [page removeRepresentation:rep];
            if (picture) {
                [found addObject:picture];
                shown++;
            }
        }
        if (shown > 0 && pages > shown)
            [[found objectAtIndex:[found count] - 1] setObject:[NSString stringWithFormat:@"Only the first %u of %u pages were sent as pictures.", shown, pages] forKey:@"note"];
    }
    if ([found count] == 0 && !*problem)
        *problem = [NSString stringWithFormat:@"%@ has no text or pages that could be read.", name];
    return [found count] ? found : nil;
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
    if ([ext isEqualToString:@"pdf"])
        return [self pdfAttachmentsForPath:path name:name size:size problem:problem];
    if ([documents containsObject:ext]) {
        NSAttributedString *rich = [[[NSAttributedString alloc] initWithPath:path documentAttributes:NULL] autorelease];
        text = [rich string];
        if ([text length] == 0) {
            *problem = [NSString stringWithFormat:@"%@ could not be read on this version of Mac OS X. Save it as text, RTF or PDF and attach that.", name];
            return nil;
        }
        one = [self textAttachmentWithText:text name:name size:size problem:problem];
        return one ? [NSArray arrayWithObject:one] : nil;
    }
    text = TBReadTextFile(path, TB_ATTACH_TEXT_MAX, NULL);
    if (!text) {
        *problem = [NSString stringWithFormat:@"%@ does not look like a text file. Text and code files, PDFs, Word, Excel, PowerPoint, Pages, Numbers and Keynote files, RTF and HTML documents, and pictures (including HEIC and WebP) can be attached. Older .xls and .ppt files can be saved as .xlsx or .pptx first.", name];
        return nil;
    }
    one = [self textAttachmentWithText:text name:name size:size problem:problem];
    return one ? [NSArray arrayWithObject:one] : nil;
}

- (void)attachPaths:(NSArray *)paths
{
    NSMutableString *problems = [NSMutableString string];
    unsigned added = 0;
    unsigned i;
    if (!current || [paths count] == 0)
        return;
    if (busy || [self chatIsBusyElsewhere:current]) {
        [self setRelayProblem:@"Wait for the reply to finish before attaching a file."];
        NSBeep();
        return;
    }
    for (i = 0; i < [paths count]; i++) {
        NSString *problem = nil;
        NSArray *made;
        if ([self relayConverts:[paths objectAtIndex:i]]) {
            if ([self startRelayConversion:[paths objectAtIndex:i] problem:&problem]) {
                added++;
                continue;
            }
            made = nil;
        } else {
            made = [self attachmentsForPath:[paths objectAtIndex:i] problem:&problem];
        }
        if (made) {
            unsigned k;
            for (k = 0; k < [made count]; k++) {
                [[current objectForKey:@"messages"] addObject:[self messageForAttachment:[made objectAtIndex:k]]];
                added++;
            }
        } else {
            if ([problems length] > 0)
                [problems appendString:@"\n\n"];
            [problems appendString:problem ? problem : @"That file could not be attached."];
        }
    }
    if (added > 0) {
        [self forgetEdit];
        [self saveStore];
        [self refreshTranscriptIfCurrent:current];
        [self syncRunButtons];
        [self updateContextReadout];
    }
    if ([problems length] > 0)
        NSRunAlertPanel(@"Could not attach", @"%@", @"OK", nil, nil, problems);
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

/* ---- files the relay converts ----
   Word, Excel and PowerPoint files, Pages, Numbers and Keynote files, and HEIC, WebP
   and similar pictures cannot be read on these Macs. The relay (a modern computer)
   turns them into text and JPEG pictures; see relay/extract.py. */

- (BOOL)relayConverts:(NSString *)path
{
    NSArray *kinds = [NSArray arrayWithObjects:@"docx", @"pptx", @"xlsx", @"pages", @"numbers", @"key", @"odt", @"ods", @"odp",
        @"heic", @"heif", @"webp", @"avif", @"jpg", @"jpeg", nil];
    return [kinds containsObject:[[path pathExtension] lowercaseString]];
}

- (BOOL)startRelayConversion:(NSString *)path problem:(NSString **)problem
{
    NSString *name = [path lastPathComponent];
    NSFileManager *manager = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    NSData *data;
    NSString *zipped = nil;
    NSMutableDictionary *placeholder;
    NSDictionary *info;
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
    placeholder = [NSMutableDictionary dictionary];
    [placeholder setObject:@"user" forKey:@"role"];
    [placeholder setObject:[NSString stringWithFormat:@"Converting %@ on the relay...", name] forKey:@"text"];
    [placeholder setObject:[NSNumber numberWithBool:NO] forKey:@"status"];
    [placeholder setObject:[NSNumber numberWithBool:YES] forKey:@"converting"];
    [[current objectForKey:@"messages"] addObject:placeholder];
    info = [NSDictionary dictionaryWithObjectsAndKeys:placeholder, @"placeholder", current, @"chat", name, @"name",
        [NSNumber numberWithDouble:size], @"size", path, @"path", nil];
    [RelayRequest sendFile:data name:name path:@"/v1/extract" timeout:240 target:self action:@selector(conversionArrived:) context:info];
    return YES;
}

- (void)conversionArrived:(RelayRequest *)request
{
    NSDictionary *info = [request context];
    NSMutableDictionary *placeholder = [info objectForKey:@"placeholder"];
    NSMutableDictionary *chat = [info objectForKey:@"chat"];
    NSString *name = [info objectForKey:@"name"];
    double size = [[info objectForKey:@"size"] doubleValue];
    NSMutableArray *messages = [chat objectForKey:@"messages"];
    NSUInteger index = [messages indexOfObjectIdenticalTo:placeholder];
    NSMutableArray *made = [NSMutableArray array];
    NSString *problem = nil;
    NSDictionary *result = nil;
    if (index == NSNotFound)
        return;
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
        if ([request status] == 404 || [request status] == 405)
            why = @"The relay is too old to convert files. Update it to 1.4.";
        else if ([request status] == 0)
            why = [request timedOut] ? @"The relay took too long." : @"The relay could not be reached.";
        NSString *ext = [[name pathExtension] lowercaseString];
        if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) {
            /* The relay only straightens photos; without it the picture is used as it is. */
            NSMutableDictionary *plain = [self pictureAttachmentFromPath:[info objectForKey:@"path"] name:name pdf:NO problem:&problem];
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
        for (i = 0; [pictures isKindOfClass:[NSArray class]] && i < [pictures count] && i < 3; i++) {
            NSData *jpeg = [pictures objectAtIndex:i];
            NSString *why = nil;
            NSString *temp = [self savedPathForName:name extension:@"jpg"];
            NSMutableDictionary *attachment = nil;
            NSString *shownName = ([text length] > 0 || [pictures count] > 1) ? [name stringByAppendingString:@" (preview)"] : name;
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
    [messages removeObjectAtIndex:index];
    if ([made count] > 0) {
        unsigned k;
        for (k = 0; k < [made count]; k++)
            [messages insertObject:[self messageForAttachment:[made objectAtIndex:k]] atIndex:index + k];
    }
    if ([chats indexOfObjectIdenticalTo:chat] != NSNotFound) {
        [self saveStore];
        [self refreshTranscriptIfCurrent:chat];
        [self updateContextReadout];
        [self syncRunButtons];
    }
    if (problem)
        NSRunAlertPanel(@"Could not attach", @"%@", @"OK", nil, nil, problem);
}

/* The pictures to send with the next request: those of the last few attached pictures. */
- (NSArray *)imageAttachmentsForChat:(NSDictionary *)chat
{
    NSArray *messages = [chat objectForKey:@"messages"];
    NSMutableArray *found = [NSMutableArray array];
    int i;
    for (i = (int)[messages count] - 1; i >= 0 && [found count] < 6; i--) {
        NSDictionary *file = [[messages objectAtIndex:i] objectForKey:@"attachment"];
        if (file && [[file objectForKey:@"kind"] isEqualToString:@"image"])
            [found insertObject:[messages objectAtIndex:i] atIndex:0];
    }
    return found;
}

@end
