#import <Foundation/Foundation.h>
#import <CoreServices/CoreServices.h>
#import <CoreFoundation/CFPlugInCOM.h>
#import <QuickLook/QuickLook.h>
#import "TBExtract.h"

/* A Quick Look generator for the files Tiger Build can read and the old Macs cannot: HEIC, AVIF, WebP and JPEG XL pictures, JSON files (shown as text), Word, Excel and PowerPoint
   (docx, xlsx, pptx) and OpenDocument files. It uses Tiger Build's own converter (TBExtract): pictures become a JPEG preview and thumbnail, documents
   a plain-text preview. Leopard and Snow Leopard only (Tiger has no Quick Look). Installed in /Library/QuickLook by the Tiger Build installer. */

#define PLUGIN_FACTORY CFUUIDGetConstantUUIDWithBytes(NULL, 0x6B, 0x1D, 0x3E, 0x0A, 0x7C, 0x5E, 0x4F, 0x1D, 0x9A, 0x53, 0x2D, 0x8B, 0x6C, 0x4E, 0x7F, 0x10)

typedef struct {
    void *conduit;           /* QLGeneratorInterfaceStruct, which must come first */
    CFUUIDRef factoryID;
    UInt32 references;
} TBQuickLookPlugin;

static NSDictionary *converted(CFURLRef url)
{
    NSData *data;
    NSDictionary *result = nil;
    NSString *name = [(NSURL *)url lastPathComponent];
    {
        /* the HEIC decoder (libde265) travels inside this plug-in, not inside an application */
        CFBundleRef bundle = CFBundleGetBundleWithIdentifier(CFSTR("local.tigerbuild.quicklook"));
        CFURLRef library = bundle ? CFBundleCopyResourceURL(bundle, CFSTR("libde265"), CFSTR("dylib"), NULL) : NULL;
        if (library) {
            [[NSUserDefaults standardUserDefaults] registerDefaults:[NSDictionary dictionaryWithObject:[(NSURL *)library path] forKey:@"TBDE265Path"]];
            CFRelease(library);
        }
    }
    data = [NSData dataWithContentsOfURL:(NSURL *)url];
    if (!data || [data length] > 100 * 1024 * 1024)
        return nil;
    @try {
        result = [TBExtract extractName:name data:data];
    } @catch (NSException *e) {
        result = nil;
    }
    return result;
}

/* A JSON file as the text it is: the first 400,000 bytes, as UTF-8 (or Latin-1 when it is not). nil when it cannot be read. */
static NSString *jsonText(CFURLRef url)
{
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:[(NSURL *)url path]];
    NSData *data = [file readDataOfLength:400000];
    NSString *text = nil;
    unsigned trim;
    [file closeFile];
    if (!data)
        return nil;
    for (trim = 0; trim < 4 && !text && trim <= [data length]; trim++)   /* the cut may fall inside a UTF-8 character */
        text = [[[NSString alloc] initWithBytes:[data bytes] length:[data length] - trim encoding:NSUTF8StringEncoding] autorelease];
    if (!text)
        text = [[[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] autorelease];
    return text;
}

OSStatus GeneratePreviewForURL(void *thisInterface, QLPreviewRequestRef preview, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    if ([[[(NSURL *)url pathExtension] lowercaseString] isEqualToString:@"json"]) {
        NSString *text = jsonText(url);
        if (text) {
            NSDictionary *props = [NSDictionary dictionaryWithObjectsAndKeys:@"UTF-8", (NSString *)kQLPreviewPropertyTextEncodingNameKey, @"text/plain", (NSString *)kQLPreviewPropertyMIMETypeKey, nil];
            QLPreviewRequestSetDataRepresentation(preview, (CFDataRef)[text dataUsingEncoding:NSUTF8StringEncoding], kUTTypePlainText, (CFDictionaryRef)props);
        }
        [pool release];
        return noErr;
    }
    NSDictionary *result = converted(url);
    NSArray *images = [result objectForKey:@"images"];
    NSString *text = [result objectForKey:@"text"];
    if ([images count]) {
        QLPreviewRequestSetDataRepresentation(preview, (CFDataRef)[images objectAtIndex:0], kUTTypeJPEG, NULL);
    } else if ([text length]) {
        NSDictionary *props = [NSDictionary dictionaryWithObjectsAndKeys:@"UTF-8", (NSString *)kQLPreviewPropertyTextEncodingNameKey, @"text/plain", (NSString *)kQLPreviewPropertyMIMETypeKey, nil];
        if ([text length] > 400000)
            text = [text substringToIndex:400000];
        QLPreviewRequestSetDataRepresentation(preview, (CFDataRef)[text dataUsingEncoding:NSUTF8StringEncoding], kUTTypePlainText, (CFDictionaryRef)props);
    }
    [pool release];
    return noErr;
}

void CancelPreviewGeneration(void *thisInterface, QLPreviewRequestRef preview)
{
}

OSStatus GenerateThumbnailForURL(void *thisInterface, QLThumbnailRequestRef thumbnail, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options, CGSize maxSize)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    if ([[[(NSURL *)url pathExtension] lowercaseString] isEqualToString:@"json"]) {
        [pool release];
        return noErr;
    }
    NSDictionary *result = converted(url);
    NSArray *images = [result objectForKey:@"images"];
    if ([images count])
        QLThumbnailRequestSetImageWithData(thumbnail, (CFDataRef)[images objectAtIndex:0], NULL);
    [pool release];
    return noErr;   /* documents get their ordinary icon */
}

void CancelThumbnailGeneration(void *thisInterface, QLThumbnailRequestRef thumbnail)
{
}

/* ---- the plug-in's COM-style boilerplate ---- */

static HRESULT QueryInterfaceImpl(void *thisInstance, REFIID iid, LPVOID *ppv);
static ULONG AddRefImpl(void *thisInstance);
static ULONG ReleaseImpl(void *thisInstance);

static QLGeneratorInterfaceStruct interfaceTable = {
    NULL, QueryInterfaceImpl, AddRefImpl, ReleaseImpl,
    GenerateThumbnailForURL, CancelThumbnailGeneration, GeneratePreviewForURL, CancelPreviewGeneration
};

static TBQuickLookPlugin *allocate(CFUUIDRef factoryID)
{
    TBQuickLookPlugin *plugin = (TBQuickLookPlugin *)malloc(sizeof(TBQuickLookPlugin));
    plugin->conduit = &interfaceTable;
    plugin->factoryID = (CFUUIDRef)CFRetain(factoryID);
    plugin->references = 1;
    CFPlugInAddInstanceForFactory(factoryID);
    return plugin;
}

static void deallocate(TBQuickLookPlugin *plugin)
{
    CFUUIDRef factoryID = plugin->factoryID;
    free(plugin);
    if (factoryID) {
        CFPlugInRemoveInstanceForFactory(factoryID);
        CFRelease(factoryID);
    }
}

static HRESULT QueryInterfaceImpl(void *thisInstance, REFIID iid, LPVOID *ppv)
{
    CFUUIDRef wanted = CFUUIDCreateFromUUIDBytes(NULL, iid);
    TBQuickLookPlugin *plugin = (TBQuickLookPlugin *)thisInstance;
    if (CFEqual(wanted, kQLGeneratorCallbacksInterfaceID) || CFEqual(wanted, IUnknownUUID)) {
        plugin->references++;
        *ppv = thisInstance;
        CFRelease(wanted);
        return S_OK;
    }
    *ppv = NULL;
    CFRelease(wanted);
    return E_NOINTERFACE;
}

static ULONG AddRefImpl(void *thisInstance)
{
    return ++((TBQuickLookPlugin *)thisInstance)->references;
}

static ULONG ReleaseImpl(void *thisInstance)
{
    TBQuickLookPlugin *plugin = (TBQuickLookPlugin *)thisInstance;
    plugin->references--;
    if (plugin->references == 0) {
        deallocate(plugin);
        return 0;
    }
    return plugin->references;
}

void *TBQuickLookFactory(CFAllocatorRef allocator, CFUUIDRef typeID)
{
    if (CFEqual(typeID, kQLGeneratorTypeID))
        return allocate(PLUGIN_FACTORY);
    return NULL;
}
