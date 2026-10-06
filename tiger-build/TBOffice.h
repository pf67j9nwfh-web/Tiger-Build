#import <Foundation/Foundation.h>

/* The text of the old binary Office files: Word .doc, Excel .xls and PowerPoint .ppt (Office 97 to 2003). They are OLE compound files
   with their own record formats; this reads the words, cells and slide text and leaves the layout. Raises TBExtractError (see
   TBExtract.h) with a sentence for the person when a file cannot be read. */
NSString *TBLegacyOfficeText(NSString *extension, NSData *data);
