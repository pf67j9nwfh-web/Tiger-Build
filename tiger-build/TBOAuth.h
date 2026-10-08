#import <Foundation/Foundation.h>

/* OAuth for MCP servers that sit behind a sign-in (the MCP specification's authorization: protected-resource and authorization-server metadata, dynamic client
   registration, authorization code with PKCE, tokens refreshed as they expire). The sign-in happens in the person's own browser; the server's answer comes back to
   a port on this Mac that listens on 127.0.0.1 for that one visit. The tokens are kept in the Keychain item that holds the API keys. */
@interface TBOAuth : NSObject
/* A token for this server that is still good (refreshed when it has run out), or nil. Never shows anything. */
+ (NSString *)tokenForServer:(NSString *)url;
/* Signs in: asks the person first, opens the browser and waits (up to five minutes) for them. YES when a token is now stored; else *error says why
   (or "cancelled"). `challenge` is the server's WWW-Authenticate header from its 401. Run it on a worker thread. */
+ (BOOL)authorizeServer:(NSString *)url challenge:(NSString *)challenge error:(NSString **)error;
+ (void)forgetServer:(NSString *)url;
+ (BOOL)hasTokenForServer:(NSString *)url;
@end
