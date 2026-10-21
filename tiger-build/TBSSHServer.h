#import <Foundation/Foundation.h>

/* Tiger Build's own SSH server (OpenSSH, port 2222), installed by the installer in /usr/local/tbssh with its launchd job switched off. It lets
   another computer's public key (the ones in ~/Library/Application Support/Tiger Build/ssh/authorized_keys) run Commander here and nothing
   else. Starting and stopping it takes the administrator password, which Tiger Build asks for with the system's own dialog. */
@interface TBSSHServer : NSObject
+ (BOOL)installed;                 /* the installer's files are there, owned by root */
+ (BOOL)listening;                 /* something answers on port 2222 of this Mac */
+ (BOOL)shellInstalled;            /* the regular server's files (port 2223) are there too */
+ (BOOL)shellListening;            /* something answers on port 2223 */
+ (NSString *)setShellRunning:(BOOL)on users:(NSArray *)users; /* the regular server: a shell, sftp and scp for the named accounts; same results as setRunning: */
+ (BOOL)smbInstalled;             /* tbsmbd (file sharing over SMB) is installed */
+ (BOOL)smbListeningOnPort:(int)port;
/* file sharing: the folder is shared as share, with the people in smb/users (see TBSMBShare), by user's account, on port (445 for most computers' file browsers) */
+ (NSString *)setSMBRunning:(BOOL)on user:(NSString *)user folder:(NSString *)folder share:(NSString *)share readOnly:(BOOL)readOnly port:(int)port;
+ (NSString *)setRunning:(BOOL)on; /* nil when done, else what went wrong (including "cancelled") */
+ (NSString *)authorizedKeysPath;
+ (NSString *)authorizedKeys;
+ (BOOL)saveAuthorizedKeys:(NSString *)text;
+ (NSString *)uninstallWithData:(NSString *)home; /* runs the installer's uninstaller with the administrator's rights, without waiting; nil when started, else what went wrong ("cancelled" included). home: also delete that person's data */
+ (NSString *)hostFingerprint;     /* of the server's key, to compare on the other computer; nil until it has run once */
@end
