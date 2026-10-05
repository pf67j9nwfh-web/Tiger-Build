#import <Foundation/Foundation.h>

/* Optional: run Commander on another Mac over SSH instead of on this one. Tiger Build makes its own key and keeps its own
   list of trusted hosts, in ~/Library/Application Support/Tiger Build/ssh, so nothing in ~/.ssh is touched. */
@interface TBSSH : NSObject
+ (BOOL)enabled;                       /* a remote Mac is set */
+ (NSString *)host;
+ (NSString *)user;
+ (NSString *)home;                    /* the remote home folder, from the setting or /Users/<user> */
+ (void)setHost:(NSString *)host user:(NSString *)user home:(NSString *)home;
+ (void)clear;
+ (NSString *)publicKey;               /* makes the key first; nil if ssh-keygen failed */
+ (NSString *)fingerprintOfHost:(NSString *)host problem:(NSString **)problem;   /* looks at the host's key; does not trust it */
+ (BOOL)trustHost:(NSString *)host problem:(NSString **)problem;                 /* remembers the key seen by -fingerprintOfHost: */
+ (void)forgetHost:(NSString *)host;
/* The program and arguments that run the remote command; nil with *problem if it is not set up. */
+ (NSArray *)commandArgumentsRunning:(NSString *)remoteCommand problem:(NSString **)problem;
/* Copies the bundled Commander onto the other Mac. nil when it worked, else what went wrong. */
+ (NSString *)installCommanderFrom:(NSString *)localPath;
/* Runs "echo ok" there. nil when it worked, else what went wrong in words. */
+ (NSString *)test;
@end
