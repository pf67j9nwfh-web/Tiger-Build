#import <Foundation/Foundation.h>

/* JSON for Mac OS X 10.4 and later, which have none. Objects come back as NSDictionary, NSArray, NSString, NSNumber
   (true and false as the CFBoolean numbers) and NSNull. */

/* nil and an error message when the text is not JSON. */
id TBJSONParse(NSData *data, NSString **error);
id TBJSONParseString(NSString *text, NSString **error);

/* The UTF-8 text of an object made of the types above, plus TBJSONRaw. */
NSData *TBJSONData(id object);
NSString *TBJSONString(id object);

/* Text that is already JSON, put into the output as it is. For a picture's base64, which would be copied three times as a string. */
@interface TBJSONRaw : NSObject {
    NSData *data;
}
+ (TBJSONRaw *)rawWithData:(NSData *)data;
- (NSData *)data;
@end
