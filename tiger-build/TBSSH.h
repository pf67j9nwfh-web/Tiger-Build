#import <Foundation/Foundation.h>

/* SSH to another computer, for MCP servers that run there (a server entry whose program is ssh:user@address and whose argument is the
   command to run on it). Tiger Build makes its own key and keeps its own list of trusted hosts, in
   ~/Library/Application Support/Tiger Build/ssh, so nothing in ~/.ssh is touched. */
@interface TBSSH : NSObject
+ (NSString *)publicKeyForHost:(NSString *)host;     /* the key that host is reached with (ed25519, or RSA for a host that only speaks the old algorithms) */
+ (NSString *)programForTarget:(NSString *)target;   /* the ssh to run: Tiger Build's own, or the system's for an old host */
+ (NSString *)fingerprintOfHost:(NSString *)host problem:(NSString **)problem;   /* looks at the host's key; does not trust it */
+ (BOOL)trustHost:(NSString *)host problem:(NSString **)problem;                 /* remembers the key seen by -fingerprintOfHost: */
+ (NSString *)hostOfTarget:(NSString *)target;
/* The ssh arguments that run remoteCommand on user@host (empty command: just connect); nil with *problem if not set up. */
+ (NSArray *)argumentsForTarget:(NSString *)target remote:(NSString *)remoteCommand problem:(NSString **)problem;
/* Runs "echo ok" there. nil when it worked, else what went wrong in words. */
+ (NSString *)testTarget:(NSString *)target;
@end
