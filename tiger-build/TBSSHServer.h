#import <Foundation/Foundation.h>

/* Tiger Build's own SSH server (OpenSSH, port 2222), installed by the installer in /usr/local/tbssh with its launchd job switched off. It lets
   another computer's public key (the ones in ~/Library/Application Support/Tiger Build/ssh/authorized_keys) run Commander here and nothing
   else. Starting and stopping it takes the administrator password, which Tiger Build asks for with the system's own dialog. */
@interface TBSSHServer : NSObject
+ (BOOL)installed;                 /* the installer's files are there, owned by root */
+ (BOOL)listening;                 /* something answers on port 2222 of this Mac */
+ (NSString *)setRunning:(BOOL)on; /* nil when done, else what went wrong (including "cancelled") */
+ (NSString *)authorizedKeysPath;
+ (NSString *)authorizedKeys;
+ (BOOL)saveAuthorizedKeys:(NSString *)text;
+ (NSString *)hostFingerprint;     /* of the server's key, to compare on the other computer; nil until it has run once */
@end
