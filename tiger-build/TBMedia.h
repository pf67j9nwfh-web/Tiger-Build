#import <Foundation/Foundation.h>
#import "TBRun.h"

/* Pictures and videos from the services that make them, and pictures fetched from the web for the chat. The relay's media.py. */

@interface TBMedia : NSObject
+ (NSArray *)toolsForProvider:(NSString *)provider; /* generate_image, generate_video definitions the provider offers */
/* Makes the file and stores it; returns {kind: image|video, filename}. Raises TBErrorException. */
+ (NSDictionary *)create:(NSString *)tool prompt:(NSString *)prompt provider:(NSString *)provider run:(TBRun *)run;
/* A picture at a public web address, stored for the chat; returns its file name. */
+ (NSString *)fetchImage:(NSString *)url;
@end

@interface TBMedia (Download)
/* A file at a public https address, over TLS, up to 50 MB, kept for the chat. Returns {stored, name, size, sha256, type, url}. Raises TBErrorException. */
+ (NSDictionary *)downloadURL:(NSString *)url name:(NSString *)name run:(TBRun *)run;
@end

/* A request that follows redirects. *status is 0 when the service could not be reached (the data is then the reason). */
NSData *TBFetch(NSString *method, NSString *url, NSArray *headers, NSData *body, int timeout, int *status, TBRun *run);
