#import <Foundation/Foundation.h>

@class TBRun;

/* Three small tool families a model can use besides Commander and the web search:
   - reading a web page by its address (text only, public addresses only);
   - searching and opening the files of a workspace's knowledge folder (an index built in memory, words weighted by how rare they are);
   - read-only questions to Calendar (iCal), Contacts (Address Book) and Mail, asked through AppleScript. */
@interface TBLocalTools : NSObject
+ (NSString *)readPage:(NSString *)url run:(TBRun *)run;                       /* raises through TBFail */
+ (NSString *)knowledgeSearch:(NSString *)query root:(NSString *)root;
+ (NSString *)knowledgeOpen:(NSString *)path root:(NSString *)root;
+ (NSString *)macAppsTool:(NSString *)name arguments:(NSDictionary *)args;     /* mac_calendar_events, mac_contacts_search, mac_mail_unread */
+ (BOOL)isMacAppsTool:(NSString *)name;
+ (NSString *)htmlToText:(NSString *)html;
@end
