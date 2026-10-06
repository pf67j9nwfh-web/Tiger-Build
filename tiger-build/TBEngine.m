#import "TBEngine.h"
#import <Security/Security.h>
#import "TBJSON.h"
#include <stdarg.h>

NSString *TBErrorException = @"TBError";

void TBFail(NSString *format, ...)
{
    va_list args;
    NSString *text;
    va_start(args, format);
    text = [[[NSString alloc] initWithFormat:format arguments:args] autorelease];
    va_end(args);
    [NSException raise:TBErrorException format:@"%@", text];
}

id TBValue(id container, NSString *key)
{
    id value;
    if (![container isKindOfClass:[NSDictionary class]])
        return nil;
    value = [container objectForKey:key];
    return value == (id)[NSNull null] ? nil : value;
}

NSString *TBString(id container, NSString *key)
{
    id value = TBValue(container, key);
    if ([value isKindOfClass:[NSString class]])
        return value;
    return @"";
}

NSDictionary *TBDictionary(id container, NSString *key)
{
    id value = TBValue(container, key);
    return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

NSArray *TBArray(id container, NSString *key)
{
    id value = TBValue(container, key);
    return [value isKindOfClass:[NSArray class]] ? value : nil;
}

long long TBInteger(id container, NSString *key)
{
    id value = TBValue(container, key);
    if ([value isKindOfClass:[NSNumber class]])
        return [value longLongValue];
    /* NSString has no longLongValue before Mac OS X 10.5. */
    if ([value isKindOfClass:[NSString class]])
        return strtoll([value UTF8String], NULL, 10);
    return 0;
}

BOOL TBTruth(id container, NSString *key)
{
    id value = TBValue(container, key);
    return [value isKindOfClass:[NSNumber class]] && [value boolValue];
}

NSString *TBTrim(NSString *text)
{
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *kService = @"Tiger Build API keys";

@implementation TBSettings

+ (NSArray *)secretNames
{
    return [NSArray arrayWithObjects:@"xai_api_key", @"openai_api_key", @"anthropic_api_key", @"mistral_api_key", @"muse_api_key",
        @"gemini_api_key", @"local_api_key", @"search_api_key", @"tavily_api_key", @"mcp_servers", nil];
}

+ (BOOL)isSecret:(NSString *)name
{
    return [[self secretNames] containsObject:name];
}

+ (NSString *)environmentValue:(NSString *)name
{
    const char *value = getenv([[@"TB_" stringByAppendingString:[name uppercaseString]] UTF8String]);
    return value ? [NSString stringWithUTF8String:value] : nil;
}

/* All the secrets are one Keychain item holding a JSON object, so the system asks for permission once, not once per key. */
static NSMutableDictionary *secrets = nil;
static NSString *kAccount = @"keys";

+ (NSMutableDictionary *)loadSecrets
{
    @synchronized(kService) {
        if (!secrets) {
            const char *service = [kService UTF8String];
            const char *account = [kAccount UTF8String];
            UInt32 length = 0;
            void *data = NULL;
            id parsed = nil;
            OSStatus status = SecKeychainFindGenericPassword(NULL, strlen(service), service, strlen(account), account, &length, &data, NULL);
            if (status == noErr) {
                NSData *json = [NSData dataWithBytes:data length:length];
                SecKeychainItemFreeContent(NULL, data);
                parsed = TBJSONParse(json, NULL);
            } else if (status != errSecItemNotFound)
                return nil;   /* locked, or the person said no: do not treat it as empty, or a save would erase the keys */
            secrets = [[NSMutableDictionary alloc] initWithDictionary:[parsed isKindOfClass:[NSDictionary class]] ? parsed : [NSDictionary dictionary]];
        }
        return secrets;
    }
    return nil;
}

+ (BOOL)saveSecrets
{
    NSData *json = TBJSONData(secrets);
    const char *service = [kService UTF8String];
    const char *account = [kAccount UTF8String];
    SecKeychainItemRef item = NULL;
    OSStatus status;
    if (SecKeychainFindGenericPassword(NULL, strlen(service), service, strlen(account), account, NULL, NULL, &item) == noErr && item) {
        status = SecKeychainItemModifyAttributesAndData(item, NULL, [json length], [json bytes]);
        CFRelease(item);
        return status == noErr;
    }
    return SecKeychainAddGenericPassword(NULL, strlen(service), service, strlen(account), account, [json length], [json bytes], NULL) == noErr;
}

+ (NSString *)keychainValueForName:(NSString *)name
{
    @synchronized(kService) {
        id v = [[self loadSecrets] objectForKey:name];
        return [v isKindOfClass:[NSString class]] ? v : nil;
    }
    return nil;
}

+ (NSString *)valueForName:(NSString *)name
{
    NSString *value = [self environmentValue:name];
    if (value)
        return TBTrim(value);
    if ([self isSecret:name])
        value = [self keychainValueForName:name];
    else
        value = [[NSUserDefaults standardUserDefaults] stringForKey:[@"TBSetting." stringByAppendingString:name]];
    return value ? TBTrim(value) : @"";
}

+ (BOOL)hasValueForName:(NSString *)name
{
    return [[self valueForName:name] length] > 0;
}

+ (void)clearName:(NSString *)name
{
    if ([self isSecret:name]) {
        @synchronized(kService) {
            if (![self loadSecrets])
                return;
            if ([secrets objectForKey:name]) {
                [secrets removeObjectForKey:name];
                [self saveSecrets];
            }
        }
    } else {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:[@"TBSetting." stringByAppendingString:name]];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
}

+ (BOOL)setValue:(NSString *)value forName:(NSString *)name
{
    value = TBTrim(value);
    if ([value length] == 0) {
        [self clearName:name];
        return YES;
    }
    if ([self isSecret:name]) {
        @synchronized(kService) {
            if (![self loadSecrets])
                return NO;
            [secrets setObject:value forKey:name];
            return [self saveSecrets];
        }
        return NO;
    }
    [[NSUserDefaults standardUserDefaults] setObject:value forKey:[@"TBSetting." stringByAppendingString:name]];
    [[NSUserDefaults standardUserDefaults] synchronize];
    return YES;
}

+ (NSString *)settingForProvider:(NSString *)provider
{
    if ([provider isEqualToString:@"grok"])
        return @"xai_api_key";
    if ([provider isEqualToString:@"chatgpt"])
        return @"openai_api_key";
    if ([provider isEqualToString:@"claude"])
        return @"anthropic_api_key";
    if ([provider isEqualToString:@"mistral"])
        return @"mistral_api_key";
    if ([provider isEqualToString:@"muse"])
        return @"muse_api_key";
    if ([provider isEqualToString:@"gemini"])
        return @"gemini_api_key";
    if ([provider isEqualToString:@"local"])
        return @"local_api_key";
    return nil;
}

+ (NSString *)keyForProvider:(NSString *)provider
{
    NSString *name = [self settingForProvider:provider];
    return name ? [self valueForName:name] : @"";
}

+ (BOOL)hasKeyForProvider:(NSString *)provider
{
    return [[self keyForProvider:provider] length] > 0;
}

+ (BOOL)flag:(NSString *)name
{
    NSString *key = [@"TBTool." stringByAppendingString:name];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:key])
        return [defaults boolForKey:key];
    /* Defaults, as the relay's integrations.py had them. */
    if ([name isEqualToString:@"ppc_approval"] || [name isEqualToString:@"toolbox_enabled"] || [name isEqualToString:@"download_enabled"])
        return NO;
    return YES;
}

+ (void)setFlag:(NSString *)name value:(BOOL)value
{
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:[@"TBTool." stringByAppendingString:name]];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@end
