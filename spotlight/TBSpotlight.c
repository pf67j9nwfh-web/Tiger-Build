/* Spotlight importer for Tiger Build's chat files (.tbchat): one small property list per chat, kept up to date by the app when Spotlight search of
   chats is switched on (Preferences, Privacy). It gives Spotlight the chat's title and its text. Plain C, CoreFoundation only, so it loads on Tiger. */
#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <CoreServices/CoreServices.h>

#define PLUGIN_FACTORY CFUUIDGetConstantUUIDWithBytes(NULL, 0x3A, 0x7F, 0x52, 0xC1, 0x90, 0x4D, 0x4B, 0x2E, 0x8E, 0x16, 0xD5, 0x07, 0xA9, 0x4C, 0x11, 0x62)
#define IMPORTER_TYPE CFUUIDGetConstantUUIDWithBytes(NULL, 0x8B, 0x08, 0xC4, 0xBF, 0x41, 0x5B, 0x11, 0xD8, 0xB3, 0xF9, 0x00, 0x03, 0x93, 0x67, 0x26, 0xFC)
#define IMPORTER_INTERFACE CFUUIDGetConstantUUIDWithBytes(NULL, 0x6E, 0xBC, 0x27, 0xC4, 0x89, 0x9C, 0x11, 0xD8, 0x84, 0xAE, 0x00, 0x03, 0x93, 0x67, 0x26, 0xFC)

typedef struct {
    MDImporterInterfaceStruct *conduit;
    CFUUIDRef factoryID;
    UInt32 references;
} TBImporter;

static Boolean importFile(void *thisInterface, CFMutableDictionaryRef attributes, CFStringRef contentTypeUTI, CFStringRef pathToFile)
{
    CFURLRef url = CFURLCreateWithFileSystemPath(NULL, pathToFile, kCFURLPOSIXPathStyle, false);
    CFDataRef data = NULL;
    CFPropertyListRef plist = NULL;
    Boolean done = false;
    (void)thisInterface;
    (void)contentTypeUTI;
    if (!url)
        return false;
    if (CFURLCreateDataAndPropertiesFromResource(NULL, url, &data, NULL, NULL, NULL) && data) {
        plist = CFPropertyListCreateFromXMLData(NULL, data, kCFPropertyListImmutable, NULL);
        if (plist && CFGetTypeID(plist) == CFDictionaryGetTypeID()) {
            CFStringRef title = CFDictionaryGetValue(plist, CFSTR("title"));
            CFStringRef text = CFDictionaryGetValue(plist, CFSTR("text"));
            CFStringRef workspace = CFDictionaryGetValue(plist, CFSTR("workspace"));
            if (title && CFGetTypeID(title) == CFStringGetTypeID()) {
                CFDictionarySetValue(attributes, kMDItemTitle, title);
                CFDictionarySetValue(attributes, kMDItemDisplayName, title);
            }
            if (text && CFGetTypeID(text) == CFStringGetTypeID())
                CFDictionarySetValue(attributes, kMDItemTextContent, text);
            if (workspace && CFGetTypeID(workspace) == CFStringGetTypeID())
                CFDictionarySetValue(attributes, kMDItemDescription, workspace);
            CFDictionarySetValue(attributes, kMDItemCreator, CFSTR("Tiger Build"));
            done = true;
        }
    }
    if (plist)
        CFRelease(plist);
    if (data)
        CFRelease(data);
    CFRelease(url);
    return done;
}

/* ---- the plug-in's COM-style boilerplate ---- */

static HRESULT queryInterface(void *thisInstance, REFIID iid, LPVOID *ppv);
static ULONG addRef(void *thisInstance);
static ULONG releaseRef(void *thisInstance);

static MDImporterInterfaceStruct interfaceTable = {NULL, queryInterface, addRef, releaseRef, importFile};

static TBImporter *allocate(CFUUIDRef factoryID)
{
    TBImporter *importer = (TBImporter *)malloc(sizeof(TBImporter));
    if (!importer)
        return NULL;
    importer->conduit = &interfaceTable;
    importer->factoryID = (CFUUIDRef)CFRetain(factoryID);
    importer->references = 1;
    CFPlugInAddInstanceForFactory(factoryID);
    return importer;
}

static void deallocate(TBImporter *importer)
{
    CFUUIDRef factoryID = importer->factoryID;
    free(importer);
    if (factoryID) {
        CFPlugInRemoveInstanceForFactory(factoryID);
        CFRelease(factoryID);
    }
}

static HRESULT queryInterface(void *thisInstance, REFIID iid, LPVOID *ppv)
{
    CFUUIDRef wanted = CFUUIDCreateFromUUIDBytes(NULL, iid);
    TBImporter *importer = (TBImporter *)thisInstance;
    if (CFEqual(wanted, IMPORTER_INTERFACE) || CFEqual(wanted, IUnknownUUID)) {
        importer->references++;
        *ppv = thisInstance;
        CFRelease(wanted);
        return S_OK;
    }
    *ppv = NULL;
    CFRelease(wanted);
    return E_NOINTERFACE;
}

static ULONG addRef(void *thisInstance)
{
    return ++((TBImporter *)thisInstance)->references;
}

static ULONG releaseRef(void *thisInstance)
{
    TBImporter *importer = (TBImporter *)thisInstance;
    importer->references--;
    if (importer->references == 0) {
        deallocate(importer);
        return 0;
    }
    return importer->references;
}

void *TBSpotlightFactory(CFAllocatorRef allocator, CFUUIDRef typeID)
{
    (void)allocator;
    if (CFEqual(typeID, IMPORTER_TYPE))
        return allocate(PLUGIN_FACTORY);
    return NULL;
}
