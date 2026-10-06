#import <Foundation/Foundation.h>

/* SSH to another computer, for MCP servers that run there (a server entry whose program is ssh:user@address and whose argument is the
   command to run on it). Tiger Build makes its own key and keeps its own list of trusted hosts, in
   ~/Library/Application Support/Tiger Build/ssh, so nothing in ~/.ssh is touched. */
@interface TBSSH : NSObject
+ (NSString *)publicKey;               /* makes the key first; nil if ssh-keygen failed */
+ (NSString *)fingerprintOfHost:(NSString *)host problem:(NSString **)problem;   /* looks at the host's key; does not trust it */
+ (BOOL)trustHost:(NSString *)host problem:(NSString **)problem;                 /* remembers the key seen by -fingerprintOfHost: */
+ (void)forgetHost:(NSString *)host;
+ (NSString *)hostOfTarget:(NSString *)target;
/* The ssh arguments that run remoteCommand on user@host (empty command: just connect); nil with *problem if not set up. */
+ (NSArray *)argumentsForTarget:(NSString *)target remote:(NSString *)remoteCommand problem:(NSString **)problem;
/* Runs "echo ok" there. nil when it worked, else what went wrong in words. */
+ (NSString *)testTarget:(NSString *)target;
@end
