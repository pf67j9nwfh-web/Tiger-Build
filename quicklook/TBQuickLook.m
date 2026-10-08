#import <Foundation/Foundation.h>
#import <CoreServices/CoreServices.h>
#import <CoreFoundation/CFPlugInCOM.h>
#import <QuickLook/QuickLook.h>
#import "TBExtract.h"

/* A Quick Look generator for the files Tiger Build can read and the old Macs cannot: HEIC, AVIF and WebP pictures, Word, Excel and PowerPoint
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

OSStatus GeneratePreviewForURL(void *thisInterface, QLPreviewRequestRef preview, CFURLRef url, CFStringRef contentTypeUTI, CFDictionaryRef options)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
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
