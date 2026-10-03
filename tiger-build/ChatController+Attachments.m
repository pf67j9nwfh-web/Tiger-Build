#import "ChatController_Private.h"

/* Files attached to a chat. Each file becomes a message from the person, shown as
   "Attached: name (size)" with a thumbnail for pictures, and the model sees it
   from then on in this conversation. A copy is kept in Application Support so the
   original can move or change. Text and code files go to the model as text;
   PDFs, Word, RTF and HTML documents are turned into text first; pictures are
   shrunk and sent as pictures. */

#define TB_ATTACH_MAX_BYTES (40 * 1024 * 1024)
#define TB_ATTACH_IMAGE_EDGE 1600.0f

@interface ChatController (AttachmentsPrivate)
- (NSString *)attachmentsDir;
- (NSString *)savedPathForName:(NSString *)name extension:(NSString *)ext;
- (NSMutableDictionary *)pictureAttachmentFromPath:(NSString *)path name:(NSString *)name pdf:(BOOL)pdf problem:(NSString **)problem;
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
    scale = TB_ATTACH_IMAGE_EDGE / (width > height ? width : height);
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

- (NSMutableDictionary *)attachmentForPath:(NSString *)path problem:(NSString **)problem
{
    NSString *name = [path lastPathComponent];
    NSString *ext = [[path pathExtension] lowercaseString];
    NSFileManager *manager = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    double size;
    NSString *text;
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
    if ([pictures containsObject:ext])
        return [self pictureAttachmentFromPath:path name:name pdf:NO problem:problem];
    if ([ext isEqualToString:@"pdf"]) {
        text = pdfText(path);
        if ([[text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length] > 20)
            return [self textAttachmentWithText:text name:name size:size problem:problem];
        /* No text (a scan, or this Mac has no PDFKit): the first page as a picture. */
        return [self pictureAttachmentFromPath:path name:name pdf:YES problem:problem];
    }
    if ([documents containsObject:ext]) {
        NSAttributedString *rich = [[[NSAttributedString alloc] initWithPath:path documentAttributes:NULL] autorelease];
        text = [rich string];
        if ([text length] == 0) {
            *problem = [NSString stringWithFormat:@"%@ could not be read on this version of Mac OS X. Save it as text, RTF or PDF and attach that.", name];
            return nil;
        }
        return [self textAttachmentWithText:text name:name size:size problem:problem];
    }
    text = TBReadTextFile(path, TB_ATTACH_TEXT_MAX, NULL);
    if (!text) {
        *problem = [NSString stringWithFormat:@"%@ does not look like a text file. Text and code files, PDFs, Word, RTF and HTML documents and pictures can be attached.", name];
        return nil;
    }
    return [self textAttachmentWithText:text name:name size:size problem:problem];
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
        NSMutableDictionary *attachment = [self attachmentForPath:[paths objectAtIndex:i] problem:&problem];
        if (attachment) {
            [[current objectForKey:@"messages"] addObject:[self messageForAttachment:attachment]];
            added++;
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
