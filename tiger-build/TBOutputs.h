#import <Foundation/Foundation.h>

/* Files a model hands to the person: text as it is, a real Word, Excel or PDF file built from plain text, or any file
   given as base64. The relay's outputs.py, built in. */

NSData *TBBase64Decode(NSString *text); /* nil when it is not base64 */
NSString *TBMediaFolder(void);          /* ~/Library/Application Support/Tiger Build/media, made when needed */
NSString *TBSafeMediaName(NSString *name); /* the name, or nil when it could point elsewhere */
NSString *TBSaveMedia(NSData *data, NSString *extension); /* a new file in the folder; returns its name */

@interface TBOutputs : NSObject
/* The file name made safe, and the bytes. Raises TBErrorException with a reason for the model. */
+ (NSData *)buildName:(NSString *)name content:(NSString *)content base64:(NSString *)encoded cleanName:(NSString **)clean;
/* Writes it into the media folder for the chat to fetch; returns the stored name. */
+ (NSString *)saveName:(NSString *)name content:(NSString *)content base64:(NSString *)encoded;
+ (NSString *)cleanFileName:(NSString *)name;
+ (NSString *)storeData:(NSData *)data name:(NSString *)name;   /* a download, kept in the media folder under a safe name */
+ (NSData *)zipFiles:(NSArray *)namesAndData; /* [name, NSData, name, NSData...] */
@end
