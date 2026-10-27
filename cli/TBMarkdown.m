#import "TBMarkdown.h"

static NSSet *wordsFor(NSString *lang)
{
    static NSMutableDictionary *cache = nil;
    NSString *list;
    NSSet *set;
    lang = [lang lowercaseString];
    if (!cache)
        cache = [[NSMutableDictionary alloc] init];
    set = [cache objectForKey:lang];
    if (set)
        return set;
    if ([lang isEqualToString:@"python"] || [lang isEqualToString:@"py"])
        list = @"def class return if elif else for while in not and or is None True False import from as with try except finally raise yield lambda pass break continue global del assert async await";
    else if ([lang isEqualToString:@"sh"] || [lang isEqualToString:@"bash"] || [lang isEqualToString:@"shell"] || [lang isEqualToString:@"zsh"])
        list = @"if then else elif fi for while do done case esac function in return export local cd echo exit set unset source";
    else if ([lang hasPrefix:@"js"] || [lang isEqualToString:@"javascript"] || [lang isEqualToString:@"ts"] || [lang isEqualToString:@"typescript"])
        list = @"function return if else for while const let var new class extends import export from default async await try catch finally throw switch case break continue typeof null undefined true false this";
    else if ([lang isEqualToString:@"json"])
        list = @"true false null";
    else if ([lang isEqualToString:@"rust"] || [lang isEqualToString:@"rs"])
        list = @"fn let mut pub struct enum impl trait use mod match if else for while loop return self Self true false const static unsafe async await";
    else if ([lang isEqualToString:@"go"])
        list = @"func package import return if else for range var const type struct interface go defer chan map switch case default nil true false";
    else
        list = @"if else for while return int char long void unsigned static const struct typedef enum union sizeof class public private protected new delete this nullptr NULL true false break continue switch case default do goto @interface @implementation @end @property @selector self nil YES NO id BOOL NSString NSArray NSDictionary";
    set = [NSSet setWithArray:[list componentsSeparatedByString:@" "]];
    [cache setObject:set forKey:lang];
    return set;
}

/* one line of code with a little colour: comments, strings, numbers, keywords */
static NSString *highlight(NSString *line, NSString *lang, TBTerm *term)
{
    NSMutableString *out = [NSMutableString string];
    NSSet *words = wordsFor(lang);
    NSUInteger i = 0, n = [line length];
    NSString *comment = ([lang isEqualToString:@"python"] || [lang isEqualToString:@"py"] || [lang isEqualToString:@"sh"] || [lang isEqualToString:@"bash"] || [lang isEqualToString:@"shell"] || [lang isEqualToString:@"yaml"] || [lang isEqualToString:@"toml"]) ? @"#" : @"//";
    if ([term colorLevel] == TBColorNone)
        return line;
    while (i < n) {
        unichar c = [line characterAtIndex:i];
        if ([line compare:comment options:0 range:NSMakeRange(i, MIN([comment length], n - i))] == NSOrderedSame && n - i >= [comment length]) {
            [out appendString:[term styled:[line substringFromIndex:i] with:@"gray"]];
            break;
        }
        if (c == '"' || c == '\'' || c == '`') {
            NSUInteger j = i + 1;
            while (j < n && [line characterAtIndex:j] != c) {
                if ([line characterAtIndex:j] == '\\')
                    j++;
                j++;
            }
            j = MIN(j + 1, n);
            [out appendString:[term styled:[line substringWithRange:NSMakeRange(i, j - i)] with:@"green"]];
            i = j;
            continue;
        }
        if (c >= '0' && c <= '9') {
            NSUInteger j = i;
            while (j < n && (([line characterAtIndex:j] >= '0' && [line characterAtIndex:j] <= '9') || [line characterAtIndex:j] == '.' || [line characterAtIndex:j] == 'x'))
                j++;
            [out appendString:[term styled:[line substringWithRange:NSMakeRange(i, j - i)] with:@"orange"]];
            i = j;
            continue;
        }
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '@') {
            NSUInteger j = i + 1;
            NSString *w;
            while (j < n && (([line characterAtIndex:j] >= 'a' && [line characterAtIndex:j] <= 'z') || ([line characterAtIndex:j] >= 'A' && [line characterAtIndex:j] <= 'Z') || ([line characterAtIndex:j] >= '0' && [line characterAtIndex:j] <= '9') || [line characterAtIndex:j] == '_'))
                j++;
            w = [line substringWithRange:NSMakeRange(i, j - i)];
            [out appendString:[words containsObject:w] ? [term styled:w with:@"magenta"] : w];
            i = j;
            continue;
        }
        [out appendFormat:@"%C", c];
        i++;
    }
    return out;
}

@implementation TBMarkdown

- (id)initWithTerm:(TBTerm *)t margin:(NSString *)m target:(id)obj action:(SEL)sel
{
    self = [super init];
    term = t;
    margin = [m copy];
    target = obj;
    action = sel;
    pending = [[NSMutableString alloc] init];
    table = [[NSMutableArray alloc] init];
    width = 80;
    return self;
}

- (void)setWidth:(int)w { width = w; }

- (void)emit:(NSString *)text
{
    [target performSelector:action withObject:text];
}

/* **bold**, *italic*, `code`, ~~strike~~, [text](url) in one line of prose */
+ (NSString *)renderInline:(NSString *)text term:(TBTerm *)term
{
    NSMutableString *out = [NSMutableString string];
    NSUInteger i = 0, n = [text length];
    while (i < n) {
        unichar c = [text characterAtIndex:i];
        NSRange rest = NSMakeRange(i, n - i);
        if (c == '`') {
            NSRange end = [text rangeOfString:@"`" options:0 range:NSMakeRange(i + 1, n - i - 1)];
            if (end.location != NSNotFound && end.location > i + 1) {
                [out appendString:[term styled:[text substringWithRange:NSMakeRange(i + 1, end.location - i - 1)] with:@"cyan"]];
                i = end.location + 1;
                continue;
            }
        } else if (c == '*' && i + 1 < n && [text characterAtIndex:i + 1] == '*') {
            NSRange end = [text rangeOfString:@"**" options:0 range:NSMakeRange(i + 2, n - i - 2)];
            if (end.location != NSNotFound && end.location > i + 2) {
                [out appendString:[term styled:[self renderInline:[text substringWithRange:NSMakeRange(i + 2, end.location - i - 2)] term:term] with:@"bold"]];
                i = end.location + 2;
                continue;
            }
        } else if ((c == '*' || c == '_') && i + 1 < n && [text characterAtIndex:i + 1] != ' ' && (i == 0 || [text characterAtIndex:i - 1] == ' ' || [text characterAtIndex:i - 1] == '(')) {
            NSRange end = [text rangeOfString:[NSString stringWithFormat:@"%C", c] options:0 range:NSMakeRange(i + 1, n - i - 1)];
            if (end.location != NSNotFound && end.location > i + 1 && [text characterAtIndex:end.location - 1] != ' ') {
                [out appendString:[term styled:[text substringWithRange:NSMakeRange(i + 1, end.location - i - 1)] with:@"italic"]];
                i = end.location + 1;
                continue;
            }
        } else if (c == '~' && i + 1 < n && [text characterAtIndex:i + 1] == '~') {
            NSRange end = [text rangeOfString:@"~~" options:0 range:NSMakeRange(i + 2, n - i - 2)];
            if (end.location != NSNotFound) {
                [out appendString:[term styled:[text substringWithRange:NSMakeRange(i + 2, end.location - i - 2)] with:@"dim"]];
                i = end.location + 2;
                continue;
            }
        } else if (c == '[') {
            NSRange mid = [text rangeOfString:@"](" options:0 range:rest];
            if (mid.location != NSNotFound) {
                NSRange close = [text rangeOfString:@")" options:0 range:NSMakeRange(mid.location + 2, n - mid.location - 2)];
                if (close.location != NSNotFound) {
                    NSString *label = [text substringWithRange:NSMakeRange(i + 1, mid.location - i - 1)], *url = [text substringWithRange:NSMakeRange(mid.location + 2, close.location - mid.location - 2)];
                    [out appendString:[term styled:label with:@"underline"]];
                    if (![label isEqualToString:url])
                        [out appendString:[term styled:[NSString stringWithFormat:@" (%@)", url] with:@"gray"]];
                    i = close.location + 1;
                    continue;
                }
            }
        }
        [out appendFormat:@"%C", c];
        i++;
    }
    return out;
}

- (void)blank
{
    if (!lastBlank && started)
        [self emit:@"\n"];
    lastBlank = YES;
}

- (void)line:(NSString *)text
{
    [self emit:[text stringByAppendingString:@"\n"]];
    lastBlank = NO;
    started = YES;
}

- (void)flushTable
{
    NSMutableArray *rows = [NSMutableArray array];
    NSMutableArray *widths = [NSMutableArray array];
    unsigned r, c, cols = 0;
    int total = 0, avail = width - [term widthOf:margin];
    if ([table count] == 0)
        return;
    for (r = 0; r < [table count]; r++) {
        NSString *row = [[table objectAtIndex:r] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSMutableArray *cells = [NSMutableArray array];
        NSArray *parts;
        BOOL rule = YES;
        if ([row hasPrefix:@"|"])
            row = [row substringFromIndex:1];
        if ([row hasSuffix:@"|"])
            row = [row substringToIndex:[row length] - 1];
        parts = [row componentsSeparatedByString:@"|"];
        for (c = 0; c < [parts count]; c++) {
            NSString *cell = [[parts objectAtIndex:c] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSMutableString *plain = [NSMutableString string];
            {
                unsigned pi;
                for (pi = 0; pi < [cell length]; pi++) {   /* the cell without its dashes, colons and spaces (the 10.5-only component call is not on Tiger) */
                    unichar pc = [cell characterAtIndex:pi];
                    if (pc != '-' && pc != ':' && pc != ' ')
                        [plain appendFormat:@"%C", pc];
                }
            }
            if ([plain length])
                rule = NO;
            [cells addObject:cell];
        }
        if (rule)
            continue;
        [rows addObject:cells];
        cols = MAX(cols, (unsigned)[cells count]);
    }
    for (c = 0; c < cols; c++) {
        int w = 1;
        for (r = 0; r < [rows count]; r++)
            if (c < [[rows objectAtIndex:r] count])
                w = MAX(w, [term widthOf:[TBMarkdown renderInline:[[rows objectAtIndex:r] objectAtIndex:c] term:term]]);
        [widths addObject:[NSNumber numberWithInt:w]];
        total += w + 3;
    }
    if (total + 1 > avail && cols > 0) {
        /* too wide: shrink the widest columns */
        while (total + 1 > avail) {
            int widest = 0;
            unsigned wi = 0;
            for (c = 0; c < cols; c++)
                if ([[widths objectAtIndex:c] intValue] > widest) { widest = [[widths objectAtIndex:c] intValue]; wi = c; }
            if (widest <= 6)
                break;
            [widths replaceObjectAtIndex:wi withObject:[NSNumber numberWithInt:widest - 1]];
            total--;
        }
    }
    {
        BOOL u = [term unicode];
        NSString *v = u ? @"│" : @"|", *h = u ? @"─" : @"-";
        [self blank];
        for (r = 0; r < [rows count]; r++) {
            NSArray *cells = [rows objectAtIndex:r];
            NSMutableArray *wrapped = [NSMutableArray array];
            unsigned maxLines = 1, k;
            for (c = 0; c < cols; c++) {
                NSString *cell = c < [cells count] ? [TBMarkdown renderInline:[cells objectAtIndex:c] term:term] : @"";
                NSString *w = [term wrap:cell width:[[widths objectAtIndex:c] intValue] indent:@""];
                NSArray *ls = [w componentsSeparatedByString:@"\n"];
                [wrapped addObject:ls];
                maxLines = MAX(maxLines, (unsigned)[ls count]);
            }
            for (k = 0; k < maxLines; k++) {
                NSMutableString *line = [NSMutableString stringWithString:margin];
                [line appendString:v];
                for (c = 0; c < cols; c++) {
                    NSArray *ls = [wrapped objectAtIndex:c];
                    NSString *part = k < [ls count] ? [ls objectAtIndex:k] : @"";
                    int pad = [[widths objectAtIndex:c] intValue] - [term widthOf:part];
                    [line appendString:@" "];
                    [line appendString:r == 0 ? [term styled:part with:@"bold"] : part];
                    while (pad-- > 0)
                        [line appendString:@" "];
                    [line appendFormat:@" %@", v];
                }
                [self line:line];
            }
            if (r == 0 && [rows count] > 1) {
                NSMutableString *rule = [NSMutableString stringWithString:margin];
                [rule appendString:v];
                for (c = 0; c < cols; c++) {
                    int k2;
                    for (k2 = 0; k2 < [[widths objectAtIndex:c] intValue] + 2; k2++)
                        [rule appendString:h];
                    [rule appendString:v];
                }
                [self line:[term styled:rule with:@"gray"]];
            }
        }
        lastBlank = NO;
    }
    [table removeAllObjects];
}

- (void)renderLine:(NSString *)line
{
    NSString *trim = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    int avail = width - [term widthOf:margin];
    if (inCode) {
        if ([trim hasPrefix:@"```"]) {
            inCode = NO;
            [self line:[term styled:[NSString stringWithFormat:@"%@%@", margin, [term unicode] ? @"└─" : @"`--"] with:@"gray"]];
            return;
        }
        {
            NSString *prefix = [term styled:[term unicode] ? @"│ " : @"| " with:@"gray"], *body;
            if ([codeLang isEqualToString:@"diff"] || [codeLang isEqualToString:@"patch"]) {
                if ([line hasPrefix:@"+"] && ![line hasPrefix:@"+++"])
                    body = [term styled:line with:@"green"];
                else if ([line hasPrefix:@"-"] && ![line hasPrefix:@"---"])
                    body = [term styled:line with:@"red"];
                else if ([line hasPrefix:@"@@"])
                    body = [term styled:line with:@"cyan"];
                else
                    body = line;
            } else
                body = highlight(line, codeLang, term);
            /* code is not re-flowed; a long line is cut to the width */
            [self line:[NSString stringWithFormat:@"%@%@%@", margin, prefix, [term clipToWidth:body width:avail - 2]]];
        }
        return;
    }
    if ([trim hasPrefix:@"```"]) {
        NSString *lang = [[trim substringFromIndex:3] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        [self flushTable];
        inCode = YES;
        [codeLang release];
        codeLang = [[lang lowercaseString] copy];
        [self line:[term styled:[NSString stringWithFormat:@"%@%@%@", margin, [term unicode] ? @"┌─ " : @",-- ", [lang length] ? lang : @"code"] with:@"gray"]];
        return;
    }
    if ([trim hasPrefix:@"|"] && [trim rangeOfString:@"|" options:0 range:NSMakeRange(1, [trim length] - 1)].location != NSNotFound) {
        [table addObject:trim];
        return;
    }
    [self flushTable];
    if ([trim length] == 0) {
        [self blank];
        return;
    }
    if ([trim hasPrefix:@"#"]) {
        int level = 0;
        NSString *rest;
        while (level < (int)[trim length] && [trim characterAtIndex:level] == '#')
            level++;
        rest = [[trim substringFromIndex:level] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (level <= 6 && [rest length]) {
            [self blank];
            [self line:[NSString stringWithFormat:@"%@%@", margin, [term styled:[TBMarkdown renderInline:rest term:term] with:level <= 2 ? @"bold" : @"underline"]]];
            return;
        }
    }
    if ([trim isEqualToString:@"---"] || [trim isEqualToString:@"***"] || [trim isEqualToString:@"___"]) {
        NSMutableString *rule = [NSMutableString string];
        int k;
        for (k = 0; k < MIN(avail, 60); k++)
            [rule appendString:[term unicode] ? @"─" : @"-"];
        [self line:[NSString stringWithFormat:@"%@%@", margin, [term styled:rule with:@"gray"]]];
        return;
    }
    if ([trim hasPrefix:@">"]) {
        NSString *rest = [[trim substringFromIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *bar = [term styled:[term unicode] ? @"▎ " : @"| " with:@"gray"];
        NSArray *rows = [[term wrap:[term styled:[TBMarkdown renderInline:rest term:term] with:@"italic"] width:avail - 2 indent:@""] componentsSeparatedByString:@"\n"];
        unsigned i;
        for (i = 0; i < [rows count]; i++)
            [self line:[NSString stringWithFormat:@"%@%@%@", margin, bar, [rows objectAtIndex:i]]];
        return;
    }
    {
        /* a list item keeps its indent and hangs the wrapped rows under the text */
        int lead = 0;
        NSString *bullet = nil, *rest = line, *hang;
        while (lead < (int)[line length] && [line characterAtIndex:lead] == ' ')
            lead++;
        {
            NSString *t = [line substringFromIndex:lead];
            if ([t hasPrefix:@"- "] || [t hasPrefix:@"* "] || [t hasPrefix:@"+ "]) {
                bullet = [term unicode] ? @"•" : @"*";
                rest = [t substringFromIndex:2];
            } else {
                NSUInteger k = 0;
                while (k < [t length] && [t characterAtIndex:k] >= '0' && [t characterAtIndex:k] <= '9')
                    k++;
                if (k > 0 && k + 1 < [t length] && [t characterAtIndex:k] == '.' && [t characterAtIndex:k + 1] == ' ') {
                    bullet = [t substringToIndex:k + 1];
                    rest = [t substringFromIndex:k + 2];
                }
            }
        }
        {
            NSString *pad = [@"" stringByPaddingToLength:lead withString:@" " startingAtIndex:0];
            NSString *rendered = [TBMarkdown renderInline:bullet ? rest : [line substringFromIndex:lead] term:term];
            NSString *first = bullet ? [NSString stringWithFormat:@"%@%@ ", pad, bullet] : pad;
            NSArray *rows;
            unsigned i;
            hang = [@"" stringByPaddingToLength:[term widthOf:first] withString:@" " startingAtIndex:0];
            rows = [[term wrap:rendered width:avail - [term widthOf:first] indent:@""] componentsSeparatedByString:@"\n"];
            for (i = 0; i < [rows count]; i++)
                [self line:[NSString stringWithFormat:@"%@%@%@", margin, i == 0 ? first : hang, [rows objectAtIndex:i]]];
        }
    }
}

- (void)feed:(NSString *)text
{
    NSRange nl;
    [pending appendString:text];
    while ((nl = [pending rangeOfString:@"\n"]).location != NSNotFound) {
        NSString *line = [pending substringToIndex:nl.location];
        [pending deleteCharactersInRange:NSMakeRange(0, nl.location + 1)];
        [self renderLine:line];
    }
}

- (void)finish
{
    if ([pending length]) {
        NSString *line = [[pending copy] autorelease];
        [pending setString:@""];
        [self renderLine:line];
    }
    [self flushTable];
    if (inCode) {
        inCode = NO;
        [self line:[term styled:[NSString stringWithFormat:@"%@%@", margin, [term unicode] ? @"└─" : @"`--"] with:@"gray"]];
    }
    lastBlank = NO;
    started = NO;
}

@end
