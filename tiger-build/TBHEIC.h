#import <Foundation/Foundation.h>

/* HEIC pictures (what an iPhone takes) as JPEG. The container is read here; the pictures themselves are decoded by libde265
   (LGPL), which lives in the app as its own library, Contents/Frameworks/libde265.dylib, and is loaded only when a HEIC file is converted. */
@interface TBHEIC : NSObject
/* nil with *problem set when it cannot be done (also for AVIF, which uses the same container). */
+ (NSData *)jpegFromData:(NSData *)data longest:(int)longest problem:(NSString **)problem;
+ (BOOL)looksLikeHEIF:(NSData *)data;
@end
