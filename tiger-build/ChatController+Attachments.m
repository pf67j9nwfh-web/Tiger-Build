#import "ChatController_Private.h"

/* Files attached to a chat. Each file becomes a message from the person, shown as
   "Attached: name (size)" with a thumbnail for pictures, and the model sees it
   from then on in this conversation. A copy is kept in Application Support so the
   original can move or change. Text and code files go to the model as text;
   PDFs, Word, RTF and HTML documents are turned into text first; pictures are
   shrunk and sent as pictures. */

#define TB_ATTACH_MAX_BYTES (40 * 1024 * 1024)
#define TB_ATTACH_IMAGE_EDGE 1600.0f

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
    NSArray *documents = [NSArray arrayWithObjects:@"rtf", @"rtfd", @"doc", @"docx", @"html", @"htm", @"webarchive", @"odt", nil];
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
        *problem = [NSString stringWithFormat:@"%@ does not look like a text file. Text and code files, PDFs, Word, RTF and HTML documents and pictures can be attached.", name];
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
        NSArray *made = [self attachmentsForPath:[paths objectAtIndex:i] problem:&problem];
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
