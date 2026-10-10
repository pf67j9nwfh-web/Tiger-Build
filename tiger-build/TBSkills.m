#import "TBSkills.h"
#import "TBEngine.h"

static NSString *const kDisabled = @"TBSkillsDisabled";

@implementation TBSkills

+ (NSString *)root
{
    NSString *over = [[NSUserDefaults standardUserDefaults] stringForKey:@"TBSkillsRoot"];   /* for tests */
    return [over length] ? over : [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Tiger Build/skills"];
}

static NSString *fileText(NSString *path, unsigned limit)
{
    NSData *data = [NSData dataWithContentsOfFile:path];
    NSString *text;
    if (!data)
        return nil;
    if ([data length] > limit)
        data = [data subdataWithRange:NSMakeRange(0, limit)];
    text = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
    if (!text)
        text = [[[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] autorelease];
    return text;
}

/* "---", then "key: value" lines, "---", then the instructions. Without that header the folder name is the name. */
+ (NSDictionary *)parse:(NSString *)text
{
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSString *body = text ? text : @"";
    NSArray *lines = [body componentsSeparatedByString:@"\n"];
    if ([lines count] > 1 && [TBTrim([lines objectAtIndex:0]) isEqualToString:@"---"]) {
        unsigned i;
        for (i = 1; i < [lines count]; i++) {
            NSString *line = [lines objectAtIndex:i];
            NSRange colon;
            if ([TBTrim(line) isEqualToString:@"---"]) {
                body = [[lines subarrayWithRange:NSMakeRange(i + 1, [lines count] - i - 1)] componentsJoinedByString:@"\n"];
                break;
            }
            colon = [line rangeOfString:@":"];
            if (colon.location != NSNotFound && colon.location > 0) {
                NSString *value = TBTrim([line substringFromIndex:colon.location + 1]);
                if ([value length] > 1 && ([value hasPrefix:@"\""] || [value hasPrefix:@"'"]) && [value hasSuffix:[value substringToIndex:1]])
                    value = [value substringWithRange:NSMakeRange(1, [value length] - 2)];
                [out setObject:value forKey:[[TBTrim([line substringToIndex:colon.location]) lowercaseString] copy]];
            }
        }
    }
    [out setObject:TBTrim(body) forKey:@"body"];
    return out;
}

+ (NSArray *)all
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *names = [[fm directoryContentsAtPath:[self root]] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    NSArray *off = [[NSUserDefaults standardUserDefaults] arrayForKey:kDisabled];
    NSMutableArray *list = [NSMutableArray array];
    unsigned i;
    for (i = 0; i < [names count]; i++) {
        NSString *folder = [[self root] stringByAppendingPathComponent:[names objectAtIndex:i]];
        NSString *text = fileText([folder stringByAppendingPathComponent:@"SKILL.md"], 200000);
        NSDictionary *parsed;
        NSString *name;
        if (!text)
            continue;
        parsed = [self parse:text];
        name = [[parsed objectForKey:@"name"] length] ? [parsed objectForKey:@"name"] : [names objectAtIndex:i];
        [list addObject:[NSDictionary dictionaryWithObjectsAndKeys:name, @"name", [[parsed objectForKey:@"description"] length] ? [parsed objectForKey:@"description"] : @"", @"description",
            folder, @"folder", [NSNumber numberWithBool:![off containsObject:name]], @"enabled", nil]];
    }
    return list;
}

+ (NSArray *)enabled
{
    NSMutableArray *list = [NSMutableArray array];
    NSArray *all = [self all];
    unsigned i;
    for (i = 0; i < [all count]; i++)
        if ([[[all objectAtIndex:i] objectForKey:@"enabled"] boolValue])
            [list addObject:[all objectAtIndex:i]];
    return list;
}

+ (void)setName:(NSString *)name enabled:(BOOL)on
{
    NSMutableArray *off = [NSMutableArray arrayWithArray:[[NSUserDefaults standardUserDefaults] arrayForKey:kDisabled]];
    [off removeObject:name];
    if (!on)
        [off addObject:name];
    [[NSUserDefaults standardUserDefaults] setObject:off forKey:kDisabled];
}

+ (NSString *)systemNote
{
    NSArray *list = [self enabled];
    NSMutableString *note = [NSMutableString string];
    unsigned i;
    if (![list count])
        return nil;
    [note appendString:@" The person has these skills (instructions for particular kinds of task). When one fits the task, call skill_load with its name first and follow what it says:"];
    for (i = 0; i < [list count] && i < 40; i++)
        [note appendFormat:@" %@: %@;", [[list objectAtIndex:i] objectForKey:@"name"], [[list objectAtIndex:i] objectForKey:@"description"]];
    return note;
}

+ (NSDictionary *)find:(NSString *)name
{
    NSArray *list = [self enabled];
    unsigned i;
    for (i = 0; i < [list count]; i++)
        if ([[[[list objectAtIndex:i] objectForKey:@"name"] lowercaseString] isEqualToString:[[name description] lowercaseString]])
            return [list objectAtIndex:i];
    return nil;
}

+ (NSString *)load:(NSString *)name
{
    NSDictionary *skill = [self find:name];
    NSMutableString *out;
    NSArray *files;
    unsigned i, shown = 0;
    if (!skill)
        TBFail(@"There is no skill called %@ (or it is switched off).", name);
    out = [NSMutableString stringWithString:[[self parse:fileText([[skill objectForKey:@"folder"] stringByAppendingPathComponent:@"SKILL.md"], 200000)] objectForKey:@"body"]];
    files = [[NSFileManager defaultManager] subpathsAtPath:[skill objectForKey:@"folder"]];
    for (i = 0; i < [files count] && shown < 60; i++) {
        NSString *f = [files objectAtIndex:i];
        BOOL dir = NO;
        if ([f isEqualToString:@"SKILL.md"] || [[f lastPathComponent] hasPrefix:@"."])
            continue;
        [[NSFileManager defaultManager] fileExistsAtPath:[[skill objectForKey:@"folder"] stringByAppendingPathComponent:f] isDirectory:&dir];
        if (dir)
            continue;
        if (!shown)
            [out appendString:@"\n\nOther files in this skill (read one with skill_read_file):"];
        [out appendFormat:@"\n- %@", f];
        shown++;
    }
    return out;
}

+ (NSString *)readFile:(NSString *)path ofSkill:(NSString *)name
{
    NSDictionary *skill = [self find:name];
    NSString *folder, *full, *text;
    if (!skill)
        TBFail(@"There is no skill called %@ (or it is switched off).", name);
    if (![path length] || [path hasPrefix:@"/"] || [path hasPrefix:@"~"] || [[path pathComponents] containsObject:@".."])
        TBFail(@"Give a path inside the skill's folder, like notes/guide.md.");
    folder = [[skill objectForKey:@"folder"] stringByResolvingSymlinksInPath];
    full = [[folder stringByAppendingPathComponent:path] stringByResolvingSymlinksInPath];
    if (![full hasPrefix:[folder stringByAppendingString:@"/"]])
        TBFail(@"That path is outside the skill's folder.");
    text = fileText(full, 60000);
    if (!text)
        TBFail(@"Could not read %@ in the skill.", path);
    return text;
}

+ (BOOL)writeFolder:(NSString *)folder name:(NSString *)name description:(NSString *)description body:(NSString *)body
{
    NSString *text = [NSString stringWithFormat:@"---\nname: %@\ndescription: %@\n---\n%@\n", name, [[description componentsSeparatedByString:@"\n"] componentsJoinedByString:@" "], body];
    if (![folder hasPrefix:[[self root] stringByAppendingString:@"/"]])
        return NO;
    return [[text dataUsingEncoding:NSUTF8StringEncoding] writeToFile:[folder stringByAppendingPathComponent:@"SKILL.md"] atomically:YES];
}

+ (BOOL)createNamed:(NSString *)name description:(NSString *)description body:(NSString *)body
{
    NSMutableString *safe = [NSMutableString string];
    NSString *folder, *text;
    unsigned i;
    for (i = 0; i < [name length]; i++) {
        unichar c = [name characterAtIndex:i];
        BOOL ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_';
        [safe appendString:ok ? [NSString stringWithFormat:@"%C", c] : (c == ' ' ? @"-" : @"")];
    }
    if (![safe length])
        return NO;
    folder = [[self root] stringByAppendingPathComponent:safe];
    {
        NSString *walk = @"/";
        NSArray *parts = [folder pathComponents];
        for (i = 1; i < [parts count]; i++) {
            walk = [walk stringByAppendingPathComponent:[parts objectAtIndex:i]];
            [[NSFileManager defaultManager] createDirectoryAtPath:walk attributes:nil];
        }
    }
    text = [NSString stringWithFormat:@"---\nname: %@\ndescription: %@\n---\n%@\n", safe, [[description componentsSeparatedByString:@"\n"] componentsJoinedByString:@" "], body];
    return [[text dataUsingEncoding:NSUTF8StringEncoding] writeToFile:[folder stringByAppendingPathComponent:@"SKILL.md"] atomically:YES];
}

@end
