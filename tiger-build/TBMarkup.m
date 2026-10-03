#import "TBMarkup.h"
#include <string.h>
#include <stdlib.h>

/* ---- splitting text at code fences ---- */

/* The fence a line opens: how many backticks or tildes it starts with
   (3 or more), and the tag after them. Returns 0 when the line is not a fence. */
static int fenceLength(NSString *line, unichar *mark, NSString **info)
{
    unsigned i = 0;
    unsigned n = [line length];
    unichar c;
    int count = 0;
    while (i < n && i < 3 && [line characterAtIndex:i] == ' ')
        i++;
    if (i >= n)
        return 0;
    c = [line characterAtIndex:i];
    if (c != '`' && c != '~')
        return 0;
    while (i < n && [line characterAtIndex:i] == c) {
        count++;
        i++;
    }
    if (count < 3)
        return 0;
    *mark = c;
    *info = [[line substringFromIndex:i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return count;
}

static NSString *joinLines(NSArray *lines, unsigned from, unsigned to)
{
    NSMutableString *out = [NSMutableString string];
    unsigned i;
    for (i = from; i < to; i++) {
        if (i > from)
            [out appendString:@"\n"];
        [out appendString:[lines objectAtIndex:i]];
    }
    return out;
}

static NSString *tagFromInfo(NSString *info)
{
    NSString *tag = info;
    NSRange space;
    if ([tag length] == 0)
        return @"";
    space = [tag rangeOfCharacterFromSet:[NSCharacterSet whitespaceCharacterSet]];
    if (space.location != NSNotFound)
        tag = [tag substringToIndex:space.location];
    /* ```{.python} and ```python title="x" both appear. */
    tag = [tag stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"{}.:"]];
    return [tag lowercaseString];
}

NSArray *TBSplitBlocks(NSString *text)
{
    NSMutableArray *out = [NSMutableArray array];
    NSArray *lines;
    unsigned i;
    unsigned proseStart = 0;
    if (!text)
        text = @"";
    lines = [text componentsSeparatedByString:@"\n"];
    i = 0;
    while (i < [lines count]) {
        unichar mark = 0;
        NSString *info = nil;
        int count = fenceLength([lines objectAtIndex:i], &mark, &info);
        unsigned j;
        BOOL closed = NO;
        if (count == 0 || (mark == '`' && [info rangeOfString:@"`"].location != NSNotFound)) {
            i++;
            continue;
        }
        if (i > proseStart) {
            NSMutableDictionary *prose = [NSMutableDictionary dictionary];
            [prose setObject:[NSNumber numberWithBool:NO] forKey:@"code"];
            [prose setObject:joinLines(lines, proseStart, i) forKey:@"text"];
            [out addObject:prose];
        }
        for (j = i + 1; j < [lines count]; j++) {
            unichar closeMark = 0;
            NSString *closeInfo = nil;
            int closeCount = fenceLength([lines objectAtIndex:j], &closeMark, &closeInfo);
            if (closeCount >= count && closeMark == mark && [closeInfo length] == 0) {
                closed = YES;
                break;
            }
        }
        {
            NSMutableDictionary *code = [NSMutableDictionary dictionary];
            [code setObject:[NSNumber numberWithBool:YES] forKey:@"code"];
            [code setObject:joinLines(lines, i + 1, j) forKey:@"text"];
            [code setObject:tagFromInfo(info) forKey:@"lang"];
            [code setObject:[NSNumber numberWithBool:closed] forKey:@"closed"];
            [out addObject:code];
        }
        i = closed ? j + 1 : j;
        proseStart = i;
    }
    if (proseStart < [lines count]) {
        NSString *rest = joinLines(lines, proseStart, [lines count]);
        if ([rest length] > 0 || [out count] == 0) {
            NSMutableDictionary *prose = [NSMutableDictionary dictionary];
            [prose setObject:[NSNumber numberWithBool:NO] forKey:@"code"];
            [prose setObject:rest forKey:@"text"];
            [out addObject:prose];
        }
    }
    return out;
}

/* ---- languages ---- */

enum {
    F_SLASH   = 1 << 0,   /* // comments */
    F_HASH    = 1 << 1,   /* # comments */
    F_DASH    = 1 << 2,   /* -- comments */
    F_BLOCKC  = 1 << 3,   /* slash-star comments */
    F_SQ      = 1 << 4,   /* 'single' strings */
    F_DQ      = 1 << 5,   /* "double" strings */
    F_BT      = 1 << 6,   /* `backtick` strings */
    F_TRIPLE  = 1 << 7,   /* Python triple quotes */
    F_CASEINS = 1 << 8,   /* keywords in any case (SQL) */
    F_DOLLAR  = 1 << 9,   /* $variables */
    F_KEYS    = 1 << 10,  /* word or "string" followed by : is a key */
    F_TAGS    = 1 << 11,  /* HTML and XML */
    F_DIFF    = 1 << 12,
    F_CAPS    = 1 << 13,  /* Capitalised words are types */
    F_AT      = 1 << 14,  /* @word is a keyword */
    F_PREPROC = 1 << 15,  /* #include and friends */
    F_DASHID  = 1 << 16,  /* hyphens inside words (CSS) */
    F_PERCENT = 1 << 17,  /* % comments */
    F_NONE    = 1 << 18   /* plain text: nothing is coloured */
};

typedef struct {
    const char *name;      /* canonical tag */
    const char *title;
    const char *aliases;   /* space separated */
    int flags;
    const char *keywords;
    const char *types;
} Language;

static const Language languages[] = {
    {"python", "Python", "py python3 py3 pycon ipython",
        F_HASH | F_SQ | F_DQ | F_TRIPLE | F_AT,
        "and as assert async await break class continue def del elif else except finally for from global if import in is "
        "lambda nonlocal not or pass raise return try while with yield match case None True False self cls",
        "int str float bool list dict set tuple bytes object type Exception complex frozenset range"},
    {"javascript", "JavaScript", "js jsx node mjs cjs",
        F_SLASH | F_BLOCKC | F_SQ | F_DQ | F_BT | F_CAPS,
        "async await break case catch class const continue debugger default delete do else export extends finally for from "
        "function if import in instanceof let new of return static super switch this throw try typeof var void while with yield "
        "null undefined true false",
        "Array Object String Number Boolean Promise Map Set Date Error JSON Math Symbol RegExp"},
    {"typescript", "TypeScript", "ts tsx",
        F_SLASH | F_BLOCKC | F_SQ | F_DQ | F_BT | F_CAPS,
        "abstract as async await break case catch class const constructor continue declare default delete do else enum export "
        "extends finally for from function get if implements import in instanceof interface keyof let namespace new of private "
        "protected public readonly return set static super switch this throw try type typeof var void while yield null undefined true false",
        "string number boolean any unknown never void object Array Promise Record Partial"},
    {"c", "C", "h",
        F_SLASH | F_BLOCKC | F_SQ | F_DQ | F_PREPROC,
        "auto break case const continue default do else enum extern for goto if inline register restrict return sizeof static "
        "struct switch typedef union volatile while NULL true false",
        "int char short long float double void signed unsigned size_t uint8_t uint16_t uint32_t uint64_t int8_t int16_t int32_t "
        "int64_t bool FILE"},
    {"cpp", "C++", "c++ cc cxx hpp hxx h++",
        F_SLASH | F_BLOCKC | F_SQ | F_DQ | F_PREPROC,
        "alignas alignof and auto break case catch class const constexpr continue decltype default delete do else enum explicit "
        "export extern final for friend goto if inline namespace new noexcept nullptr operator override private protected public "
        "register return sizeof static struct switch template this throw try typedef typename union using virtual volatile while "
        "true false NULL",
        "int char short long float double void bool signed unsigned size_t string vector map set unique_ptr shared_ptr"},
    {"objc", "Objective-C", "objective-c objectivec m mm obj-c",
        F_SLASH | F_BLOCKC | F_SQ | F_DQ | F_PREPROC | F_AT,
        "auto break case const continue default do else enum extern for goto if inline return sizeof static struct switch "
        "typedef union volatile while self super nil Nil YES NO NULL in true false",
        "int char short long float double void id SEL Class BOOL NSString NSArray NSDictionary NSObject NSInteger NSUInteger "
        "CGFloat NSNumber NSData NSMutableArray NSMutableDictionary NSMutableString unsigned signed"},
    {"java", "Java", "",
        F_SLASH | F_BLOCKC | F_SQ | F_DQ | F_AT | F_CAPS,
        "abstract assert break case catch class const continue default do else enum extends final finally for goto if implements "
        "import instanceof interface native new package private protected public return static strictfp super switch synchronized "
        "this throw throws transient try volatile while var null true false",
        "int long short byte float double boolean char void String Object List Map Set"},
    {"kotlin", "Kotlin", "kt kts",
        F_SLASH | F_BLOCKC | F_SQ | F_DQ | F_AT | F_CAPS,
        "as break class continue do else for fun if in interface is null object package return super this throw true false try "
        "typealias val var when while by catch constructor finally import init override private protected public open data "
        "sealed companion abstract suspend",
        "Int Long Short Byte Float Double Boolean Char String Unit Any Nothing List Map Set"},
    {"swift", "Swift", "",
        F_SLASH | F_BLOCKC | F_DQ | F_AT | F_CAPS,
        "actor associatedtype async await break case catch class continue default defer deinit do else enum extension fallthrough "
        "false fileprivate for func guard if import in init inout internal is let nil open operator private protocol public repeat "
        "rethrows return self Self static struct subscript super switch throw throws true try typealias var where while",
        "Int Double Float String Bool Array Dictionary Set Optional Any AnyObject Void UInt Character"},
    {"go", "Go", "golang",
        F_SLASH | F_BLOCKC | F_SQ | F_DQ | F_BT,
        "break case chan const continue default defer else fallthrough for func go goto if import interface map package range "
        "return select struct switch type var nil true false iota",
        "int int8 int16 int32 int64 uint uint8 uint16 uint32 uint64 float32 float64 string bool byte rune error any uintptr"},
    {"rust", "Rust", "rs",
        F_SLASH | F_BLOCKC | F_DQ | F_CAPS,
        "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub "
        "ref return self Self static struct super trait true type unsafe use where while",
        "i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str String Vec Option Result Box"},
    {"ruby", "Ruby", "rb",
        F_HASH | F_SQ | F_DQ,
        "alias and begin break case class def defined do else elsif end ensure false for if in module next nil not or redo rescue "
        "retry return self super then true undef unless until when while yield require require_relative attr_accessor attr_reader "
        "attr_writer puts",
        "String Array Hash Integer Float Symbol Object Class Module Proc"},
    {"php", "PHP", "",
        F_SLASH | F_HASH | F_BLOCKC | F_SQ | F_DQ | F_DOLLAR,
        "abstract and array as break case catch class clone const continue declare default do echo else elseif empty enddeclare "
        "endfor endforeach endif endswitch endwhile extends final finally fn for foreach function global if implements include "
        "include_once instanceof interface isset list namespace new or print private protected public require require_once return "
        "static switch throw trait try unset use var while xor yield null true false",
        "int float string bool array object void mixed"},
    {"bash", "Shell", "sh shell zsh console terminal shellscript fish ksh dash",
        F_HASH | F_SQ | F_DQ | F_BT | F_DOLLAR,
        "if then else elif fi for while until do done case esac in function select time return exit break continue export local "
        "readonly declare unset source alias set eval exec trap shift true false",
        ""},
    {"sql", "SQL", "mysql postgres postgresql sqlite plsql tsql",
        F_DASH | F_BLOCKC | F_SQ | F_DQ | F_CASEINS,
        "select from where and or not in is null like between join inner outer left right full cross on as group by order having "
        "limit offset insert into values update set delete create alter drop table index view database primary key foreign "
        "references unique default check constraint distinct union all case when then else end exists asc desc with begin commit "
        "rollback truncate add column if returning",
        "int integer bigint smallint tinyint varchar char text boolean bool date datetime timestamp float double decimal numeric blob serial"},
    {"json", "JSON", "jsonc json5 jsonl geojson",
        F_SLASH | F_BLOCKC | F_DQ | F_KEYS,
        "true false null", ""},
    {"yaml", "YAML", "yml",
        F_HASH | F_SQ | F_DQ | F_KEYS,
        "true false null yes no on off", ""},
    {"toml", "TOML", "ini cfg conf properties env dotenv",
        F_HASH | F_SQ | F_DQ | F_KEYS,
        "true false", ""},
    {"html", "HTML", "htm xhtml vue svelte",
        F_TAGS | F_SQ | F_DQ,
        "", ""},
    {"xml", "XML", "svg plist xsl xslt rss atom xsd wsdl",
        F_TAGS | F_SQ | F_DQ,
        "", ""},
    {"css", "CSS", "scss sass less",
        F_BLOCKC | F_SLASH | F_SQ | F_DQ | F_DASHID | F_AT | F_KEYS,
        "important inherit initial none auto", ""},
    {"lua", "Lua", "",
        F_DASH | F_SQ | F_DQ,
        "and break do else elseif end false for function goto if in local nil not or repeat return then true until while", ""},
    {"perl", "Perl", "pl pm",
        F_HASH | F_SQ | F_DQ | F_DOLLAR,
        "and cmp continue do else elsif eq for foreach ge gt if last le lt my ne next no not or our package print redo require "
        "return sub unless until use while xor", ""},
    {"r", "R", "rstats",
        F_HASH | F_SQ | F_DQ,
        "break else for function if in next repeat return while TRUE FALSE NULL NA Inf NaN library require", ""},
    {"makefile", "Makefile", "make mk dockerfile docker cmake",
        F_HASH | F_SQ | F_DQ | F_DOLLAR,
        "FROM RUN CMD COPY ADD ENV EXPOSE WORKDIR ENTRYPOINT ARG VOLUME USER LABEL include ifeq ifneq ifdef ifndef else endif "
        "define endef export override", ""},
    {"diff", "Diff", "patch udiff",
        F_DIFF, "", ""},
    {"markdown", "Markdown", "md",
        F_NONE, "", ""},
    {"text", "Text", "txt plain plaintext none output log text/plain",
        F_NONE, "", ""},
    {NULL, NULL, NULL, 0, NULL, NULL}
};

static const Language *findLanguage(NSString *tag)
{
    const char *want;
    int i;
    if (!tag || [tag length] == 0)
        return NULL;
    want = [[tag lowercaseString] UTF8String];
    if (!want)
        return NULL;
    for (i = 0; languages[i].name; i++) {
        const char *p;
        size_t len = strlen(want);
        if (strcmp(languages[i].name, want) == 0)
            return &languages[i];
        p = languages[i].aliases;
        while (*p) {
            const char *end;
            while (*p == ' ')
                p++;
            end = p;
            while (*end && *end != ' ')
                end++;
            if ((size_t)(end - p) == len && strncmp(p, want, len) == 0)
                return &languages[i];
            p = end;
        }
    }
    return NULL;
}

BOOL TBLanguageKnown(NSString *tag)
{
    return findLanguage(tag) != NULL;
}

/* A guess for a fence with no tag. */
static const Language *sniffLanguage(NSString *code)
{
    NSString *head = code;
    NSString *trim;
    if ([head length] > 600)
        head = [head substringToIndex:600];
    trim = [head stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([trim length] == 0)
        return NULL;
    if ([trim hasPrefix:@"#!"]) {
        if ([trim rangeOfString:@"python"].location != NSNotFound && [trim rangeOfString:@"python"].location < 30)
            return findLanguage(@"python");
        if ([trim rangeOfString:@"ruby"].location != NSNotFound && [trim rangeOfString:@"ruby"].location < 30)
            return findLanguage(@"ruby");
        if ([trim rangeOfString:@"perl"].location != NSNotFound && [trim rangeOfString:@"perl"].location < 30)
            return findLanguage(@"perl");
        return findLanguage(@"bash");
    }
    if ([trim hasPrefix:@"<?php"])
        return findLanguage(@"php");
    if ([trim hasPrefix:@"<?xml"])
        return findLanguage(@"xml");
    if ([trim hasPrefix:@"<!DOCTYPE html"] || [trim hasPrefix:@"<html"] || [trim hasPrefix:@"<!doctype html"])
        return findLanguage(@"html");
    if ([trim hasPrefix:@"diff --git"] || ([trim hasPrefix:@"--- "] && [trim rangeOfString:@"\n+++ "].location != NSNotFound))
        return findLanguage(@"diff");
    if (([trim hasPrefix:@"{"] && [trim hasSuffix:@"}"]) || ([trim hasPrefix:@"["] && [trim hasSuffix:@"]"])) {
        if ([trim rangeOfString:@"\":"].location != NSNotFound)
            return findLanguage(@"json");
    }
    if ([trim hasPrefix:@"#include"] || [trim hasPrefix:@"int main"])
        return findLanguage(@"c");
    if ([trim hasPrefix:@"#import"] || [trim rangeOfString:@"@interface"].location != NSNotFound
        || [trim rangeOfString:@"NSString"].location != NSNotFound)
        return findLanguage(@"objc");
    if ([trim hasPrefix:@"package main"] || [trim hasPrefix:@"func "])
        return findLanguage(@"go");
    if ([trim hasPrefix:@"fn "] || [trim hasPrefix:@"use std"])
        return findLanguage(@"rust");
    if ([trim hasPrefix:@"def "] || [trim hasPrefix:@"import "] || [trim hasPrefix:@"from "] || [trim hasPrefix:@"class "]
        || [trim hasPrefix:@"print("] || [trim rangeOfString:@"\ndef "].location != NSNotFound)
        return findLanguage(@"python");
    if ([trim hasPrefix:@"$ "] || [trim hasPrefix:@"sudo "] || [trim hasPrefix:@"cd "] || [trim hasPrefix:@"ls "])
        return findLanguage(@"bash");
    if ([trim hasPrefix:@"SELECT "] || [trim hasPrefix:@"select "] || [trim hasPrefix:@"INSERT "] || [trim hasPrefix:@"CREATE "])
        return findLanguage(@"sql");
    if ([trim hasPrefix:@"function "] || [trim hasPrefix:@"const "] || [trim hasPrefix:@"let "] || [trim hasPrefix:@"console.log"])
        return findLanguage(@"javascript");
    return NULL;
}

NSString *TBLanguageTitle(NSString *tag, NSString *code)
{
    const Language *language = findLanguage(tag);
    if (language)
        return [NSString stringWithUTF8String:language->title];
    if (tag && [tag length] > 0) {
        /* Shown as the model wrote it, with a capital. */
        return [[[tag substringToIndex:1] uppercaseString] stringByAppendingString:[tag substringFromIndex:1]];
    }
    language = sniffLanguage(code);
    if (language)
        return [NSString stringWithUTF8String:language->title];
    return @"Code";
}

NSString *TBLanguageExtension(NSString *title)
{
    static NSDictionary *table = nil;
    NSString *ext;
    if (!table)
        table = [[NSDictionary alloc] initWithObjectsAndKeys:
            @"py", @"Python", @"js", @"JavaScript", @"ts", @"TypeScript", @"c", @"C", @"cpp", @"C++", @"m", @"Objective-C",
            @"java", @"Java", @"kt", @"Kotlin", @"swift", @"Swift", @"go", @"Go", @"rs", @"Rust", @"rb", @"Ruby", @"php", @"PHP",
            @"sh", @"Shell", @"sql", @"SQL", @"json", @"JSON", @"yml", @"YAML", @"toml", @"TOML", @"html", @"HTML", @"xml", @"XML",
            @"css", @"CSS", @"lua", @"Lua", @"pl", @"Perl", @"r", @"R", @"diff", @"Diff", @"md", @"Markdown", @"txt", @"Text", nil];
    ext = [table objectForKey:title];
    if (!ext && [title isEqualToString:@"Makefile"])
        return @"mk";
    return ext ? ext : @"txt";
}

/* ---- colouring ---- */

static int isIdStart(unichar c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c > 127;
}

static int isDigit(unichar c)
{
    return c >= '0' && c <= '9';
}

static int isIdChar(unichar c)
{
    return isIdStart(c) || isDigit(c);
}

static unichar lower(unichar c)
{
    return (c >= 'A' && c <= 'Z') ? c + 32 : c;
}

/* Whether the word w[0..len) is in the space separated list. */
static int inList(const unichar *w, int len, const char *list, int caseInsensitive)
{
    const char *p = list;
    if (!p)
        return 0;
    while (*p) {
        const char *end;
        int k;
        int same;
        while (*p == ' ')
            p++;
        end = p;
        while (*end && *end != ' ')
            end++;
        if (end - p == len) {
            same = 1;
            for (k = 0; k < len; k++) {
                unichar a = w[k];
                unichar b = (unichar)(unsigned char)p[k];
                if (caseInsensitive) {
                    a = lower(a);
                    b = lower(b);
                }
                if (a != b) {
                    same = 0;
                    break;
                }
            }
            if (same)
                return 1;
        }
        p = end;
    }
    return 0;
}

static int startsWith(const unichar *buf, unsigned n, unsigned i, const char *s)
{
    unsigned k = 0;
    while (s[k]) {
        if (i + k >= n || buf[i + k] != (unichar)(unsigned char)s[k])
            return 0;
        k++;
    }
    return 1;
}

static void paint(unsigned char *kinds, unsigned from, unsigned to, int kind)
{
    unsigned k;
    for (k = from; k < to; k++)
        kinds[k] = (unsigned char)kind;
}

static int atLineStart(const unichar *buf, unsigned i)
{
    while (i > 0) {
        unichar c = buf[i - 1];
        if (c == '\n')
            return 1;
        if (c != ' ' && c != '\t')
            return 0;
        i--;
    }
    return 1;
}

/* A string starting at i with the quote q; returns the index after it. */
static unsigned scanString(const unichar *buf, unsigned n, unsigned i, unichar q, int triple)
{
    unsigned j = i + 1;
    if (triple)
        j = i + 3;
    while (j < n) {
        unichar c = buf[j];
        if (c == '\\' && j + 1 < n) {
            j += 2;
            continue;
        }
        if (triple) {
            if (c == q && j + 2 < n && buf[j + 1] == q && buf[j + 2] == q)
                return j + 3;
        } else {
            if (c == q)
                return j + 1;
            if (c == '\n' && q != '`')
                return j;
        }
        j++;
    }
    return n;
}

static void highlightTags(const unichar *buf, unsigned n, unsigned char *kinds)
{
    unsigned i = 0;
    while (i < n) {
        if (buf[i] != '<') {
            i++;
            continue;
        }
        if (startsWith(buf, n, i, "<!--")) {
            unsigned j = i + 4;
            while (j < n && !startsWith(buf, n, j, "-->"))
                j++;
            j = (j < n) ? j + 3 : n;
            paint(kinds, i, j, TBTokComment);
            i = j;
            continue;
        }
        i++;
        if (i < n && (buf[i] == '/' || buf[i] == '!' || buf[i] == '?'))
            i++;
        {
            unsigned s = i;
            while (i < n && (isIdChar(buf[i]) || buf[i] == '-' || buf[i] == ':' || buf[i] == '.'))
                i++;
            paint(kinds, s, i, TBTokKeyword);
        }
        while (i < n && buf[i] != '>') {
            unichar c = buf[i];
            if (c == '"' || c == '\'') {
                unsigned j = scanString(buf, n, i, c, 0);
                paint(kinds, i, j, TBTokString);
                i = j;
            } else if (isIdStart(c)) {
                unsigned s = i;
                while (i < n && (isIdChar(buf[i]) || buf[i] == '-' || buf[i] == ':' || buf[i] == '.'))
                    i++;
                paint(kinds, s, i, TBTokType);
            } else if (c == '<') {
                break;
            } else {
                i++;
            }
        }
    }
}

static void highlightDiff(const unichar *buf, unsigned n, unsigned char *kinds)
{
    unsigned i = 0;
    while (i < n) {
        unsigned e = i;
        int kind = TBTokPlain;
        while (e < n && buf[e] != '\n')
            e++;
        if (e > i) {
            unichar c = buf[i];
            if (startsWith(buf, n, i, "+++") || startsWith(buf, n, i, "---") || startsWith(buf, n, i, "diff ")
                || startsWith(buf, n, i, "index "))
                kind = TBTokKeyword;
            else if (startsWith(buf, n, i, "@@"))
                kind = TBTokFunction;
            else if (c == '+')
                kind = TBTokInsert;
            else if (c == '-')
                kind = TBTokDelete;
        }
        paint(kinds, i, e, kind);
        i = (e < n) ? e + 1 : n;
    }
}

NSData *TBHighlight(NSString *code, NSString *tag)
{
    unsigned n = [code length];
    NSMutableData *result = [NSMutableData dataWithLength:n];
    unsigned char *kinds = (unsigned char *)[result mutableBytes];
    unichar *buf;
    const Language *language;
    int flags;
    int ci;
    unsigned i = 0;
    char lastWord[24];
    if (n == 0)
        return result;
    language = findLanguage(tag);
    if (!language && (!tag || [tag length] == 0))
        language = sniffLanguage(code);
    buf = (unichar *)malloc(sizeof(unichar) * n);
    if (!buf)
        return result;
    [code getCharacters:buf range:NSMakeRange(0, n)];
    if (language) {
        flags = language->flags;
    } else {
        /* A language with no rules: the marks nearly every language shares. */
        flags = F_SLASH | F_BLOCKC | F_HASH | F_SQ | F_DQ;
    }
    if (flags & F_NONE) {
        free(buf);
        return result;
    }
    if (flags & F_DIFF) {
        highlightDiff(buf, n, kinds);
        free(buf);
        return result;
    }
    if (flags & F_TAGS) {
        highlightTags(buf, n, kinds);
        free(buf);
        return result;
    }
    ci = (flags & F_CASEINS) ? 1 : 0;
    lastWord[0] = 0;
    while (i < n) {
        unichar c = buf[i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
            i++;
            continue;
        }
        /* comments */
        if ((flags & F_BLOCKC) && startsWith(buf, n, i, "/*")) {
            unsigned j = i + 2;
            while (j < n && !startsWith(buf, n, j, "*/"))
                j++;
            j = (j < n) ? j + 2 : n;
            paint(kinds, i, j, TBTokComment);
            i = j;
            continue;
        }
        if (((flags & F_SLASH) && startsWith(buf, n, i, "//"))
            || ((flags & F_DASH) && startsWith(buf, n, i, "--"))
            || ((flags & F_PERCENT) && c == '%')
            || ((flags & F_HASH) && c == '#' && !((flags & F_PREPROC) && atLineStart(buf, i))
                && (i == 0 || !isIdChar(buf[i - 1])) && !(i > 0 && buf[i - 1] == '$'))) {
            unsigned j = i;
            while (j < n && buf[j] != '\n')
                j++;
            paint(kinds, i, j, TBTokComment);
            i = j;
            continue;
        }
        /* C preprocessor */
        if ((flags & F_PREPROC) && c == '#' && atLineStart(buf, i)) {
            unsigned j = i + 1;
            unsigned wordStart;
            while (j < n && (buf[j] == ' ' || buf[j] == '\t'))
                j++;
            wordStart = j;
            while (j < n && isIdChar(buf[j]))
                j++;
            paint(kinds, i, j, TBTokKeyword);
            if (j > wordStart && (inList(buf + wordStart, (int)(j - wordStart), "include import", 0))) {
                unsigned k = j;
                while (k < n && (buf[k] == ' ' || buf[k] == '\t'))
                    k++;
                if (k < n && buf[k] == '<') {
                    unsigned e = k;
                    while (e < n && buf[e] != '>' && buf[e] != '\n')
                        e++;
                    if (e < n && buf[e] == '>')
                        e++;
                    paint(kinds, k, e, TBTokString);
                    j = e;
                }
            }
            i = j;
            continue;
        }
        /* strings */
        if ((c == '"' && (flags & F_DQ)) || (c == '\'' && (flags & F_SQ)) || (c == '`' && (flags & F_BT))) {
            int triple = (flags & F_TRIPLE) && c != '`' && startsWith(buf, n, i, c == '"' ? "\"\"\"" : "'''");
            unsigned j = scanString(buf, n, i, c, triple);
            int kind = TBTokString;
            if ((flags & F_KEYS) && c != '`') {
                unsigned k = j;
                while (k < n && (buf[k] == ' ' || buf[k] == '\t'))
                    k++;
                if (k < n && buf[k] == ':')
                    kind = TBTokProperty;
            }
            paint(kinds, i, j, kind);
            i = j;
            continue;
        }
        /* $variables */
        if ((flags & F_DOLLAR) && c == '$' && i + 1 < n) {
            unsigned j = i + 1;
            if (buf[j] == '{') {
                while (j < n && buf[j] != '}' && buf[j] != '\n')
                    j++;
                if (j < n && buf[j] == '}')
                    j++;
            } else if (buf[j] == '(') {
                j = i + 1;
                i++;
                continue;
            } else if (isIdStart(buf[j])) {
                while (j < n && isIdChar(buf[j]))
                    j++;
            } else if (isDigit(buf[j]) || buf[j] == '@' || buf[j] == '?' || buf[j] == '#' || buf[j] == '*' || buf[j] == '!') {
                j++;
            }
            paint(kinds, i, j, TBTokProperty);
            i = j;
            continue;
        }
        /* @words */
        if ((flags & F_AT) && c == '@' && i + 1 < n && isIdStart(buf[i + 1])) {
            unsigned j = i + 1;
            while (j < n && isIdChar(buf[j]))
                j++;
            paint(kinds, i, j, TBTokKeyword);
            i = j;
            continue;
        }
        /* numbers */
        if (isDigit(c) || (c == '.' && i + 1 < n && isDigit(buf[i + 1]) && (i == 0 || !isIdChar(buf[i - 1])))) {
            unsigned j = i + 1;
            while (j < n) {
                unichar d = buf[j];
                if (isIdChar(d) || d == '.') {
                    if ((d == 'e' || d == 'E') && j + 1 < n && (buf[j + 1] == '+' || buf[j + 1] == '-') && !(i + 1 < n && (buf[i + 1] == 'x' || buf[i + 1] == 'X'))) {
                        j += 2;
                        continue;
                    }
                    /* 1..5 and x.method() after a digit */
                    if (d == '.' && !(j + 1 < n && isDigit(buf[j + 1])))
                        break;
                    j++;
                    continue;
                }
                break;
            }
            paint(kinds, i, j, TBTokNumber);
            i = j;
            lastWord[0] = 0;
            continue;
        }
        /* words */
        if (isIdStart(c) || (c == '-' && (flags & F_DASHID) && i + 1 < n && isIdStart(buf[i + 1]))) {
            unsigned j = i + 1;
            int len;
            int kind = TBTokPlain;
            int isKeyword;
            while (j < n && (isIdChar(buf[j]) || ((flags & F_DASHID) && buf[j] == '-')))
                j++;
            len = (int)(j - i);
            isKeyword = inList(buf + i, len, language ? language->keywords : "", ci);
            if (isKeyword) {
                kind = TBTokKeyword;
            } else if (language && inList(buf + i, len, language->types, 0)) {
                kind = TBTokType;
            } else if (lastWord[0] && len < 60) {
                if (strcmp(lastWord, "fn") == 0 || strcmp(lastWord, "func") == 0 || strcmp(lastWord, "function") == 0
                    || strcmp(lastWord, "def") == 0 || strcmp(lastWord, "fun") == 0 || strcmp(lastWord, "sub") == 0)
                    kind = TBTokFunction;
                else if (strcmp(lastWord, "class") == 0 || strcmp(lastWord, "struct") == 0 || strcmp(lastWord, "interface") == 0
                    || strcmp(lastWord, "enum") == 0 || strcmp(lastWord, "trait") == 0 || strcmp(lastWord, "protocol") == 0
                    || strcmp(lastWord, "namespace") == 0 || strcmp(lastWord, "extension") == 0 || strcmp(lastWord, "interface") == 0
                    || strcmp(lastWord, "type") == 0 || strcmp(lastWord, "object") == 0)
                    kind = TBTokType;
            }
            if (kind == TBTokPlain) {
                if (j < n && buf[j] == '(' && !(flags & F_KEYS))
                    kind = TBTokFunction;
                else if ((flags & F_CAPS) && c >= 'A' && c <= 'Z' && len > 1)
                    kind = TBTokType;
                else if ((flags & F_KEYS) && !(language && (language->flags & F_DASHID) && 0)) {
                    unsigned k = j;
                    while (k < n && (buf[k] == ' ' || buf[k] == '\t'))
                        k++;
                    if (k < n && buf[k] == ':' && !(k + 1 < n && buf[k + 1] == ':') && atLineStart(buf, i))
                        kind = TBTokProperty;
                    else if (k < n && buf[k] == ':' && (flags & F_DASHID) && !(k + 1 < n && buf[k + 1] == ':'))
                        kind = TBTokProperty;
                }
            }
            paint(kinds, i, j, kind);
            if (kind == TBTokKeyword && len < (int)sizeof(lastWord) - 1) {
                int k;
                for (k = 0; k < len; k++)
                    lastWord[k] = (char)(buf[i + k] < 128 ? buf[i + k] : '?');
                lastWord[len] = 0;
            } else {
                lastWord[0] = 0;
            }
            i = j;
            continue;
        }
        lastWord[0] = 0;
        i++;
    }
    free(buf);
    return result;
}
