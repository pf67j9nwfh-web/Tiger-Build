#import <Foundation/Foundation.h>

/* The administrator password for Commander, for the tb command: as the window does, this program holds the saved password (a Keychain item) and gives it over a
   socket only this account can use to the Commander it started, which asks with the key it was given; nobody else's key is taken. The socket is this
   program's own, so it does not meet the window's. The password is never shown to the model. */
@interface TBSudoBroker : NSObject
+ (BOOL)administratorModeOn;           /* ppc-commander --sudo status says on */
+ (NSString *)start;                    /* serves; nil when it does, else why not */
+ (void)primeKeychain;                  /* reads the saved password once and lets it go, so the Keychain asks now and not in the middle of a command */
+ (void)stop;
@end
