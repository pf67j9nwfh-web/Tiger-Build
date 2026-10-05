#import "TBEngine.h"
#import <Security/Security.h>
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

+ (NSString *)keychainValueForName:(NSString *)name
{
    const char *service = [kService UTF8String];
    const char *account = [name UTF8String];
    UInt32 length = 0;
    void *data = NULL;
    NSString *result = nil;
    if (SecKeychainFindGenericPassword(NULL, strlen(service), service, strlen(account), account, &length, &data, NULL) == noErr) {
        result = [[[NSString alloc] initWithBytes:data length:length encoding:NSUTF8StringEncoding] autorelease];
        SecKeychainItemFreeContent(NULL, data);
    }
    return result;
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
        const char *service = [kService UTF8String];
        const char *account = [name UTF8String];
        SecKeychainItemRef item = NULL;
        if (SecKeychainFindGenericPassword(NULL, strlen(service), service, strlen(account), account, NULL, NULL, &item) == noErr && item) {
            SecKeychainItemDelete(item);
            CFRelease(item);
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
        const char *service = [kService UTF8String];
        const char *account = [name UTF8String];
        const char *secret = [value UTF8String];
        [self clearName:name];
        return SecKeychainAddGenericPassword(NULL, strlen(service), service, strlen(account), account, strlen(secret), secret, NULL) == noErr;
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
    if ([name isEqualToString:@"ppc_approval"] || [name isEqualToString:@"toolbox_enabled"])
        return NO;
    return YES;
}

+ (void)setFlag:(NSString *)name value:(BOOL)value
{
    [[NSUserDefaults standardUserDefaults] setBool:value forKey:[@"TBTool." stringByAppendingString:name]];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@end
