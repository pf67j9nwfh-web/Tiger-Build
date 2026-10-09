#import "TBModelProfiles.h"

#define RETRY_AFTER (7 * 24 * 3600.0)
#define NOTE_LIMIT 200

static NSMutableDictionary *notes = nil;     /* key -> {note, at} */

@implementation TBModelProfiles

+ (NSString *)notesPath
{
    NSString *over = [[NSUserDefaults standardUserDefaults] stringForKey:@"TBModelNotesPath"];   /* for tests */
    return [over length] ? over : [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Tiger Build/model-notes.plist"];
}

static void load(void)
{
    if (!notes) {
        NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:[TBModelProfiles notesPath]];
        notes = [[NSMutableDictionary alloc] initWithDictionary:saved ? saved : [NSDictionary dictionary]];
    }
}

static void save(void)
{
    NSString *path = [TBModelProfiles notesPath];
    NSString *walk = @"/";
    NSArray *parts = [[path stringByDeletingLastPathComponent] pathComponents];
    unsigned i;
    for (i = 1; i < [parts count]; i++) {
        walk = [walk stringByAppendingPathComponent:[parts objectAtIndex:i]];
        [[NSFileManager defaultManager] createDirectoryAtPath:walk attributes:nil];
    }
    [notes writeToFile:path atomically:YES];
}

static BOOL has(NSString *id, NSArray *words)
{
    unsigned i;
    for (i = 0; i < [words count]; i++)
        if ([id rangeOfString:[words objectAtIndex:i]].location != NSNotFound)
            return YES;
    return NO;
}

+ (NSString *)factsForProvider:(NSString *)provider model:(NSString *)model title:(NSString *)title vision:(BOOL)vision context:(int)context price:(NSNumber *)price
{
    NSString *id = [[NSString stringWithFormat:@"%@ %@", model, title] lowercaseString];
    NSMutableArray *facts = [NSMutableArray array];
    if (has(id, [NSArray arrayWithObjects:@"opus", @"ultra", @"-pro", @" pro", @"gpt-5", @"o3", @"large", @"max", nil]) && !has(id, [NSArray arrayWithObjects:@"mini", @"flash", @"lite", @"nano", nil]))
        [facts addObject:@"most capable tier"];
    if (has(id, [NSArray arrayWithObjects:@"flash", @"mini", @"nano", @"haiku", @"lite", @"small", @"instant", @"turbo", @"8b", @"7b", @"3b", nil]))
        [facts addObject:@"fast and inexpensive"];
    if (has(id, [NSArray arrayWithObjects:@"thinking", @"reason", @"-r1", @"o1", @"o3", @"o4", nil]))
        [facts addObject:@"deep reasoning"];
    if (has(id, [NSArray arrayWithObjects:@"code", @"codex", @"coder", @"devstral", nil]))
        [facts addObject:@"programming"];
    if (vision)
        [facts addObject:@"sees pictures"];
    if (context >= 1000)
        [facts addObject:[NSString stringWithFormat:@"%dk context", context / 1000]];
    if (price)
        [facts addObject:[NSString stringWithFormat:@"about $%.2f per million tokens in plus out", [price doubleValue]]];
    else if ([provider isEqualToString:@"local"])
        [facts addObject:@"runs on this Mac or the local network, free"];
    return [facts componentsJoinedByString:@"; "];
}

+ (NSString *)noteForKey:(NSString *)key
{
    NSString *note;
    load();
    note = [[notes objectForKey:key] objectForKey:@"note"];
    return [note length] ? note : nil;
}

+ (NSString *)lineForProvider:(NSString *)provider model:(NSString *)model title:(NSString *)title vision:(BOOL)vision context:(int)context price:(NSNumber *)price
{
    NSString *facts = [self factsForProvider:provider model:model title:title vision:vision context:context price:price];
    NSString *note = [self noteForKey:[NSString stringWithFormat:@"%@|%@", provider, model]];
    return [NSString stringWithFormat:@"%@|%@|%@%@%@%@%@", provider, model, [title length] ? title : model, [facts length] ? @"; " : @"", facts, note ? @"; " : @"", note ? note : @""];
}

+ (NSArray *)keysNeedingNotes:(NSArray *)keys
{
    NSMutableArray *need = [NSMutableArray array];
    double now = [[NSDate date] timeIntervalSince1970];
    unsigned i;
    load();
    for (i = 0; i < [keys count]; i++) {
        NSDictionary *entry = [notes objectForKey:[keys objectAtIndex:i]];
        if ([[entry objectForKey:@"note"] length])
            continue;
        if (entry && now - [[entry objectForKey:@"at"] doubleValue] < RETRY_AFTER)
            continue;
        [need addObject:[keys objectAtIndex:i]];
    }
    return need;
}

+ (void)storeReply:(NSString *)reply asked:(NSArray *)keys
{
    NSArray *lines = [reply componentsSeparatedByString:@"\n"];
    NSNumber *now = [NSNumber numberWithDouble:[[NSDate date] timeIntervalSince1970]];
    unsigned i;
    load();
    for (i = 0; i < [keys count]; i++)
        if (![notes objectForKey:[keys objectAtIndex:i]])
            [notes setObject:[NSDictionary dictionaryWithObjectsAndKeys:@"", @"note", now, @"at", nil] forKey:[keys objectAtIndex:i]];
    for (i = 0; i < [lines count]; i++) {
        NSArray *parts = [[lines objectAtIndex:i] componentsSeparatedByString:@"|"];
        NSString *key, *note;
        if ([parts count] < 3)
            continue;
        key = [NSString stringWithFormat:@"%@|%@", [[parts objectAtIndex:0] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" -*`\t"]],
            [[parts objectAtIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
        note = [[[parts subarrayWithRange:NSMakeRange(2, [parts count] - 2)] componentsJoinedByString:@"|"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (![keys containsObject:key] || [note length] == 0)
            continue;
        if ([note length] > NOTE_LIMIT)
            note = [note substringToIndex:NOTE_LIMIT];
        [notes setObject:[NSDictionary dictionaryWithObjectsAndKeys:note, @"note", now, @"at", nil] forKey:key];
    }
    save();
}

+ (double)lastRefresh { return [[NSUserDefaults standardUserDefaults] doubleForKey:@"TBModelNotesRefreshed"]; }
+ (void)setLastRefresh:(double)when { [[NSUserDefaults standardUserDefaults] setDouble:when forKey:@"TBModelNotesRefreshed"]; }

@end
