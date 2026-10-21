#import <Foundation/Foundation.h>

/* The "smb" built-in server: look at and change files on SMB 2/3 shares (Windows PCs, NAS boxes, Samba, other Macs, Tiger Build's own file sharing) with
   libsmb2. A share is given as smb://[domain;]user[:password]@server[:port]/share[/path], or by the name of one saved in Preferences, Sharing (kept in the
   Keychain with the other secrets), so the password need not be said in a chat. Raises TBErrorException for a failure the model should see. */
@interface TBSMB : NSObject
/* tool: smb_list, smb_get, smb_put, smb_mkdir, smb_delete, smb_rename. local: whether local_path / output_path may be used (only in a chat with Commander on). */
+ (NSString *)call:(NSString *)tool arguments:(NSDictionary *)args allowLocal:(BOOL)local;
/* the saved shares, as the person edits them: one "name = smb://user:password@server/share" per line */
+ (NSString *)savedSharesText;
+ (void)setSavedSharesText:(NSString *)text;
/* exposed for tests */
+ (NSDictionary *)parseURL:(NSString *)url;
@end
