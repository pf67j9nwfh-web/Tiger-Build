#import <Foundation/Foundation.h>

/* Shared pieces of the built-in engine, which does what the relay did: talk to the model services, run the tool loop,
   convert attachments. Everything here is safe to call from a worker thread. */

extern NSString *TBErrorException;

/* Raise an error the person should read; the engine reports its text. */
void TBFail(NSString *format, ...);

/* Reading values out of parsed JSON without checking each step; a wrong type reads as empty. */
id TBValue(id container, NSString *key);
NSString *TBString(id container, NSString *key);
NSDictionary *TBDictionary(id container, NSString *key);
NSArray *TBArray(id container, NSString *key);
long long TBInteger(id container, NSString *key);
BOOL TBTruth(id container, NSString *key);
NSString *TBTrim(NSString *text);
BOOL TBTruthy(id value);   /* non-empty text or collection, true number, any other object */

/* Keys and settings. The service keys are in the Keychain; the rest in the preferences. Names are the relay's:
   xai_api_key, openai_api_key, anthropic_api_key, mistral_api_key, muse_api_key, gemini_api_key, local_api_key,
   anthropic_workspace_id, local_url. TB_<NAME> in the environment overrides, for tests. */
@interface TBSettings : NSObject
+ (NSString *)valueForName:(NSString *)name;
+ (BOOL)setValue:(NSString *)value forName:(NSString *)name;
+ (BOOL)hasValueForName:(NSString *)name;
+ (void)clearName:(NSString *)name;
+ (NSArray *)secretNames;
+ (NSString *)settingForProvider:(NSString *)provider;
+ (NSString *)keyForProvider:(NSString *)provider;
+ (BOOL)hasKeyForProvider:(NSString *)provider;
/* The tool settings (see the relay's integrations.py); a key not set reads as its default. */
+ (BOOL)flag:(NSString *)name;
+ (void)setFlag:(NSString *)name value:(BOOL)value;
@end
