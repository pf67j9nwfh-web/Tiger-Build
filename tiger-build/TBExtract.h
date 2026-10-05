#import <Foundation/Foundation.h>

/* Files the old Macs cannot open, turned into text and JPEG pictures; the relay's extract.py, built in.
   Word, PowerPoint, Excel, OpenDocument, Pages, Keynote and Numbers files give text (iWork files also their preview
   picture); other pictures are turned upright and into JPEG with ImageIO. Safe to call from a worker thread. */

extern NSString *TBExtractError; /* exception name; the reason is for the person to read */

@interface TBExtract : NSObject
+ (BOOL)handles:(NSString *)name;
/* {text: NSString, images: NSArray of JPEG NSData, note: NSString}. Raises TBExtractError. */
+ (NSDictionary *)extractName:(NSString *)name data:(NSData *)data;
@end

/* The pieces, public for the tests. */
@interface TBZip : NSObject
{
    NSData *data;
    NSMutableDictionary *entries;
}
+ (TBZip *)zipWithData:(NSData *)data;
- (NSArray *)names;
- (BOOL)has:(NSString *)name;
- (NSData *)dataFor:(NSString *)name; /* raises TBExtractError when it is too large or damaged */
- (double)totalSize;
@end

NSData *TBSnappyDecompress(const unsigned char *bytes, unsigned length); /* nil when damaged */
NSData *TBGunzip(NSData *data, unsigned limit);
