#import <Foundation/Foundation.h>

/* A saved SMB share as a disk in the Finder. The Finder cannot speak SMB 2 or 3 on the old systems (Snow Leopard and earlier have SMB 1 only, which modern
   servers have switched off), so this program, which can (libsmb2), serves the share to the Finder as WebDAV, which every system from Tiger on mounts: a
   small web server on this Mac's loopback address only, at a web address with a secret in it that only this program and the Finder are told. */
@interface TBDAV : NSObject
/* mounts the saved share by that name as a disk; nil when it worked, else why not (it can take several seconds: call it off the main thread) */
+ (NSString *)mountShareInFinder:(NSString *)name;
+ (NSString *)unmountShare:(NSString *)name;
+ (void)unmountAll;                      /* at quit: a disk whose server is gone would hang the Finder */
+ (NSArray *)mountedNames;
/* the address the Finder is given for a share (starts the server); for tests and for mounting by hand */
+ (NSString *)addressForShare:(NSString *)name problem:(NSString **)problem;
@end
