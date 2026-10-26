#import "TBTerm.h"
#include <termios.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <signal.h>
#include <sys/stat.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

static struct termios savedMode;
static volatile sig_atomic_t winchFlag = 0;

static void onWinch(int sig) { (void)sig; winchFlag = 1; }

/* ---- the width of a character in columns ---- */

static int charWidth(unsigned int c)
{
    if (c == 0 || c < 32 || (c >= 0x7f && c < 0xa0))
        return 0;
    if ((c >= 0x300 && c <= 0x36f) || (c >= 0x200b && c <= 0x200f) || (c >= 0x20d0 && c <= 0x20ff) || (c >= 0xfe00 && c <= 0xfe0f) || c == 0x200d || (c >= 0xe0100 && c <= 0xe01ef))
        return 0;
    if ((c >= 0x1100 && c <= 0x115f) || (c >= 0x2e80 && c <= 0xa4cf && c != 0x303f) || (c >= 0xac00 && c <= 0xd7a3) || (c >= 0xf900 && c <= 0xfaff) || (c >= 0xfe30 && c <= 0xfe6f)
        || (c >= 0xff00 && c <= 0xff60) || (c >= 0xffe0 && c <= 0xffe6) || (c >= 0x1f300 && c <= 0x1f64f) || (c >= 0x1f900 && c <= 0x1f9ff) || (c >= 0x20000 && c <= 0x3fffd))
        return 2;
    return 1;
}

/* the width of text, skipping escape sequences (CSI ... letter) */
static int textWidth(NSString *text)
{
    NSUInteger i, n = [text length];
    int w = 0;
    for (i = 0; i < n; i++) {
        unichar c = [text characterAtIndex:i];
        unsigned int cp = c;
        if (c == 0x1b) {
            if (i + 1 < n && [text characterAtIndex:i + 1] == '[') {
                i += 2;
                while (i < n && !([text characterAtIndex:i] >= 0x40 && [text characterAtIndex:i] <= 0x7e))
                    i++;
            }
            continue;
        }
        if (c >= 0xd800 && c < 0xdc00 && i + 1 < n) {
            unichar d = [text characterAtIndex:i + 1];
            cp = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00);
            i++;
        }
        w += charWidth(cp);
    }
    return w;
}

@implementation TBTerm

+ (TBTerm *)term
{
    static TBTerm *t = nil;
    if (!t)
        t = [[TBTerm alloc] init];
    return t;
}

- (id)init
{
    const char *colorterm = getenv("COLORTERM"), *termname = getenv("TERM"), *lang = getenv("LANG"), *lc = getenv("LC_ALL"), *ctype = getenv("LC_CTYPE");
    self = [super init];
    out = [[NSMutableData alloc] init];
    level = TBColor16;
    if (!isatty(1) || getenv("NO_COLOR") || (termname && !strcmp(termname, "dumb")))
        level = TBColorNone;
    else if (colorterm && (strstr(colorterm, "truecolor") || strstr(colorterm, "24bit")))
        level = TBColorTrue;
    else if (termname && strstr(termname, "256color"))
        level = TBColor256;
    /* text is UTF-8 unless the locale says otherwise or TB_ASCII is set (Terminal on Tiger is UTF-8 by default) */
    unicode = !getenv("TB_ASCII");
    if (unicode) {
        const char *loc = lc ? lc : (ctype ? ctype : lang);
        if (loc && *loc && strcmp(loc, "C") && strcmp(loc, "POSIX") && !strcasestr(loc, "utf"))
            unicode = NO;
    }
    signal(SIGWINCH, onWinch);
    return self;
}

- (BOOL)isInteractive { return isatty(0) && isatty(1); }
- (BOOL)outputIsTerminal { return isatty(1); }
- (TBColorLevel)colorLevel { return level; }
- (void)setColorLevel:(TBColorLevel)l { level = l; }
- (BOOL)unicode { return unicode; }

- (void)measure
{
    struct winsize ws;
    columns = 80;
    rows = 24;
    if (ioctl(1, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0) {
        columns = ws.ws_col;
        rows = ws.ws_row > 0 ? ws.ws_row : 24;
    } else if (getenv("COLUMNS") && atoi(getenv("COLUMNS")) > 0)
        columns = atoi(getenv("COLUMNS"));
}

- (int)columns { [self measure]; return columns; }
- (int)rows { [self measure]; return rows; }
- (BOOL)resized { BOOL r = winchFlag; winchFlag = 0; return r; }

- (void)enterRaw
{
    struct termios t;
    if (raw || !isatty(0))
        return;
    tcgetattr(0, &savedMode);
    t = savedMode;
    t.c_iflag &= ~(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
    t.c_lflag &= ~(ECHO | ICANON | IEXTEN | ISIG);
    t.c_cc[VMIN] = 1;
    t.c_cc[VTIME] = 0;
    tcsetattr(0, TCSANOW, &t);
    raw = YES;
    [self write:@"\033[?2004h"];   /* bracketed paste */
    [self flush];
}

- (void)leaveRaw
{
    if (!raw)
        return;
    [self write:@"\033[?2004l"];
    [self flush];
    tcsetattr(0, TCSANOW, &savedMode);
    raw = NO;
}

- (void)write:(NSString *)text
{
    NSData *d = [text dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
    if (!unicode) {
        d = [text dataUsingEncoding:NSASCIIStringEncoding allowLossyConversion:YES];
    }
    [out appendData:d];
    if ([out length] > 16384)
        [self flush];
}

- (void)flush
{
    const char *p = [out bytes];
    NSUInteger n = [out length], at = 0;
    while (at < n) {
        ssize_t w = write(1, p + at, n - at);
        if (w < 0) {
            if (errno == EINTR || errno == EAGAIN)
                continue;
            break;
        }
        at += (NSUInteger)w;
    }
    [out setLength:0];
}

/* one byte, waiting up to the time; -1 timeout, -2 end of input */
- (int)readByte:(int)ms
{
    fd_set set;
    struct timeval tv, *tvp = NULL;
    unsigned char c;
    ssize_t r;
    FD_ZERO(&set);
    FD_SET(0, &set);
    if (ms >= 0) {
        tv.tv_sec = ms / 1000;
        tv.tv_usec = (ms % 1000) * 1000;
        tvp = &tv;
    }
    r = select(1, &set, NULL, NULL, tvp);
    if (r < 0)
        return winchFlag ? -3 : -1;
    if (r == 0)
        return -1;
    r = read(0, &c, 1);
    if (r == 0)
        return -2;
    if (r < 0)
        return -1;
    return c;
}

- (TBKey)readKeyWithin:(int)ms
{
    TBKey k;
    int b = [self readByte:ms];
    memset(&k, 0, sizeof k);
    k.type = TBKeyNone;
    if (b == -3 || winchFlag) {
        k.type = TBKeyResize;
        if (b == -3)
            return k;
    }
    if (b == -2) { k.type = TBKeyEOF; return k; }
    if (b < 0)
        return k;
    if (b == 27) {
        int n = [self readByte:30];
        if (n < 0) { k.type = TBKeyEscape; return k; }
        if (n == '\r' || n == '\n') { k.type = TBKeyAltEnter; return k; }
        if (n == '[' || n == 'O') {
            NSMutableString *seq = [NSMutableString string];
            int c;
            while ((c = [self readByte:30]) >= 0) {
                [seq appendFormat:@"%c", c];
                if (c >= 0x40 && c <= 0x7e)
                    break;
            }
            if ([seq isEqualToString:@"A"]) k.type = TBKeyUp;
            else if ([seq isEqualToString:@"B"]) k.type = TBKeyDown;
            else if ([seq isEqualToString:@"C"]) k.type = TBKeyRight;
            else if ([seq isEqualToString:@"D"]) k.type = TBKeyLeft;
            else if ([seq isEqualToString:@"H"] || [seq isEqualToString:@"1~"] || [seq isEqualToString:@"7~"]) k.type = TBKeyHome;
            else if ([seq isEqualToString:@"F"] || [seq isEqualToString:@"4~"] || [seq isEqualToString:@"8~"]) k.type = TBKeyEnd;
            else if ([seq isEqualToString:@"3~"]) k.type = TBKeyDelete;
            else if ([seq isEqualToString:@"5~"]) k.type = TBKeyPageUp;
            else if ([seq isEqualToString:@"6~"]) k.type = TBKeyPageDown;
            else if ([seq isEqualToString:@"Z"]) k.type = TBKeyBackTab;
            else if ([seq isEqualToString:@"1;5C"] || [seq isEqualToString:@"1;3C"] || [seq isEqualToString:@"5C"]) k.type = TBKeyWordRight;
            else if ([seq isEqualToString:@"1;5D"] || [seq isEqualToString:@"1;3D"] || [seq isEqualToString:@"5D"]) k.type = TBKeyWordLeft;
            else if ([seq isEqualToString:@"200~"]) {
                /* a paste, up to ESC [ 201 ~ */
                NSMutableData *data = [NSMutableData data];
                int pc;
                unsigned char tail[6];
                int tn = 0;
                while ((pc = [self readByte:1000]) >= 0) {
                    unsigned char ch = (unsigned char)pc;
                    [data appendBytes:&ch length:1];
                    tail[tn % 6] = ch;
                    tn++;
                    if ([data length] >= 6) {
                        const unsigned char *bytes = [data bytes] + [data length] - 6;
                        if (!memcmp(bytes, "\033[201~", 6)) {
                            [data setLength:[data length] - 6];
                            break;
                        }
                    }
                }
                k.type = TBKeyPaste;
                {
                    NSString *s = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] autorelease];
                    if (!s)
                        s = [[[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] autorelease];
                    s = [[s componentsSeparatedByString:@"\r\n"] componentsJoinedByString:@"\n"];
                    s = [[s componentsSeparatedByString:@"\r"] componentsJoinedByString:@"\n"];
                    k.paste = s ? s : @"";
                }
            } else
                k.type = TBKeyNone;
            return k;
        }
        if (n == 'b') { k.type = TBKeyWordLeft; return k; }
        if (n == 'f') { k.type = TBKeyWordRight; return k; }
        if (n == 127 || n == 8) { k.type = TBKeyAlt; k.ch = 127; return k; }
        k.type = TBKeyAlt;
        k.ch = (unsigned)n;
        return k;
    }
    if (b == '\r' || b == '\n') { k.type = TBKeyEnter; return k; }
    if (b == '\t') { k.type = TBKeyTab; return k; }
    if (b == 127 || b == 8) { k.type = TBKeyBackspace; return k; }
    if (b < 32) {
        k.type = TBKeyCtrl;
        k.ch = (unsigned)(b + 'a' - 1);
        return k;
    }
    /* a UTF-8 character */
    {
        unsigned int cp = (unsigned)b;
        int extra = 0;
        if ((b & 0xe0) == 0xc0) { cp = b & 0x1f; extra = 1; }
        else if ((b & 0xf0) == 0xe0) { cp = b & 0x0f; extra = 2; }
        else if ((b & 0xf8) == 0xf0) { cp = b & 0x07; extra = 3; }
        while (extra-- > 0) {
            int c = [self readByte:100];
            if (c < 0)
                break;
            cp = (cp << 6) | (c & 0x3f);
        }
        k.type = TBKeyChar;
        k.ch = cp;
    }
    return k;
}

/* ---- styles ---- */

- (NSString *)style:(NSString *)name
{
    if (level == TBColorNone)
        return @"";
    if ([name isEqualToString:@"reset"]) return @"\033[0m";
    if ([name isEqualToString:@"bold"]) return @"\033[1m";
    if ([name isEqualToString:@"dim"]) return level >= TBColor256 ? @"\033[38;5;245m" : @"\033[2m";
    if ([name isEqualToString:@"italic"]) return @"\033[3m";
    if ([name isEqualToString:@"underline"]) return @"\033[4m";
    if ([name isEqualToString:@"red"]) return @"\033[31m";
    if ([name isEqualToString:@"green"]) return @"\033[32m";
    if ([name isEqualToString:@"yellow"]) return @"\033[33m";
    if ([name isEqualToString:@"blue"]) return @"\033[34m";
    if ([name isEqualToString:@"magenta"]) return @"\033[35m";
    if ([name isEqualToString:@"cyan"]) return @"\033[36m";
    if ([name isEqualToString:@"gray"]) return level >= TBColor256 ? @"\033[38;5;245m" : @"\033[90m";
    if ([name isEqualToString:@"orange"]) return level >= TBColor256 ? @"\033[38;5;208m" : @"\033[33m";
    if ([name isEqualToString:@"brightwhite"]) return @"\033[97m";
    if ([name isEqualToString:@"codebg"]) return level >= TBColor256 ? @"\033[48;5;236m" : @"";
    if ([name isEqualToString:@"userbg"]) return level >= TBColor256 ? @"\033[48;5;237m" : @"";
    if ([name isEqualToString:@"addbg"]) return level >= TBColor256 ? @"\033[48;5;22m" : @"\033[32m";
    if ([name isEqualToString:@"delbg"]) return level >= TBColor256 ? @"\033[48;5;52m" : @"\033[31m";
    return @"";
}

- (NSString *)styled:(NSString *)text with:(NSString *)name
{
    NSString *s = [self style:name];
    if ([s length] == 0)
        return text;
    return [NSString stringWithFormat:@"%@%@%@", s, text, [self style:@"reset"]];
}

- (int)widthOf:(NSString *)text { return textWidth(text); }

- (NSString *)clipToWidth:(NSString *)text width:(int)width
{
    NSMutableString *out2 = [NSMutableString string];
    NSUInteger i, n = [text length];
    int w = 0;
    BOOL cut = NO;
    for (i = 0; i < n; i++) {
        unichar c = [text characterAtIndex:i];
        if (c == 0x1b && i + 1 < n && [text characterAtIndex:i + 1] == '[') {
            NSUInteger j = i + 2;
            while (j < n && !([text characterAtIndex:j] >= 0x40 && [text characterAtIndex:j] <= 0x7e))
                j++;
            [out2 appendString:[text substringWithRange:NSMakeRange(i, MIN(j + 1, n) - i)]];
            i = j;
            continue;
        }
        if (w + charWidth(c) > width - 1 && textWidth([text substringFromIndex:i]) > width - w) {
            cut = YES;
            break;
        }
        [out2 appendFormat:@"%C", c];
        w += charWidth(c);
    }
    if (cut)
        [out2 appendString:unicode ? @"…" : @"~"];
    [out2 appendString:[self style:@"reset"]];
    return out2;
}

/* words are kept whole; styles carry over a break; each continuation line starts with the indent */
- (NSString *)wrap:(NSString *)text width:(int)width indent:(NSString *)indent
{
    NSMutableString *result = [NSMutableString string];
    NSArray *lines = [text componentsSeparatedByString:@"\n"];
    unsigned li;
    int indentWidth = textWidth(indent);
    if (width < 20)
        width = 20;
    for (li = 0; li < [lines count]; li++) {
        NSString *line = [lines objectAtIndex:li];
        NSMutableString *cur = [NSMutableString string];
        NSMutableString *active = [NSMutableString string];   /* the style in force */
        int w = 0;
        NSUInteger i = 0, n = [line length];
        BOOL firstWord = YES;
        int lead = 0;
        /* the line's own leading spaces are kept on its first row */
        while (lead < (int)n && [line characterAtIndex:lead] == ' ')
            lead++;
        if (lead > 0) {
            [cur appendString:[line substringToIndex:lead]];
            w = lead;
            i = lead;
        }
        while (i < n) {
            NSMutableString *word = [NSMutableString string];
            int ww = 0;
            BOOL sawSpace = NO;
            while (i < n && [line characterAtIndex:i] == ' ') { sawSpace = YES; i++; }
            while (i < n && [line characterAtIndex:i] != ' ') {
                unichar c = [line characterAtIndex:i];
                if (c == 0x1b && i + 1 < n && [line characterAtIndex:i + 1] == '[') {
                    NSUInteger j = i + 2;
                    NSString *seq;
                    while (j < n && !([line characterAtIndex:j] >= 0x40 && [line characterAtIndex:j] <= 0x7e))
                        j++;
                    seq = [line substringWithRange:NSMakeRange(i, MIN(j + 1, n) - i)];
                    [word appendString:seq];
                    if ([seq isEqualToString:@"\033[0m"])
                        [active setString:@""];
                    else
                        [active appendString:seq];
                    i = j + 1;
                    continue;
                }
                [word appendFormat:@"%C", c];
                if (c >= 0xd800 && c < 0xdc00 && i + 1 < n) {
                    [word appendFormat:@"%C", [line characterAtIndex:i + 1]];
                    ww += 2;
                    i += 2;
                    continue;
                }
                ww += charWidth(c);
                i++;
            }
            if ([word length] == 0)
                continue;
            if (!firstWord && w + (sawSpace ? 1 : 0) + ww > width) {
                [result appendString:cur];
                [result appendString:[self style:@"reset"]];
                [result appendString:@"\n"];
                [cur setString:indent];
                w = indentWidth;
                [cur appendString:active];
                sawSpace = NO;
            }
            if (sawSpace && !(w == indentWidth && !firstWord))
                { [cur appendString:@" "]; w++; }
            [cur appendString:word];
            w += ww;
            firstWord = NO;
        }
        [result appendString:cur];
        if (li + 1 < [lines count])
            [result appendString:@"\n"];
    }
    return result;
}

- (void)setTitle:(NSString *)title
{
    if ([self outputIsTerminal] && level != TBColorNone)
        [self write:[NSString stringWithFormat:@"\033]0;%@\007", title]];
}

- (void)bell { [self write:@"\007"]; [self flush]; }

@end

/* ================================================================== the line editor */

@implementation TBLineEditor

- (id)initWithTerm:(TBTerm *)t historyPath:(NSString *)path
{
    self = [super init];
    term = t;
    buffer = [[NSMutableString alloc] init];
    history = [[NSMutableArray alloc] init];
    killed = [[NSMutableString alloc] init];
    historyPath = [path copy];
    prompt = @"> ";
    continuation = @"  ";
    historyAt = -1;
    if (path) {
        NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
        NSArray *lines = [text componentsSeparatedByString:@"\n"];
        unsigned i;
        for (i = 0; i < [lines count]; i++)
            if ([[lines objectAtIndex:i] length])
                [history addObject:[[[lines objectAtIndex:i] componentsSeparatedByString:@"\\n"] componentsJoinedByString:@"\n"]];
        if ([history count] > 1000)
            [history removeObjectsInRange:NSMakeRange(0, [history count] - 1000)];
    }
    return self;
}

- (void)setDelegate:(id<TBLineEditorDelegate>)d { delegate = d; }
- (void)setPrompt:(NSString *)p continuation:(NSString *)c { [prompt release]; prompt = [p copy]; [continuation release]; continuation = [c copy]; }
- (void)setHint:(NSString *)text { [hint release]; hint = [text copy]; }
- (NSString *)text { return buffer; }

- (void)setText:(NSString *)text
{
    [buffer setString:text];
    cursor = (int)[buffer length];
}

- (void)insert:(NSString *)text
{
    NSUInteger at = (NSUInteger)cursor;
    if (at > [buffer length])
        at = [buffer length];
    [buffer insertString:text atIndex:at];
    cursor = (int)(at + [text length]);
}

- (void)addHistory:(NSString *)line
{
    if ([line length] == 0 || ([history count] && [[history lastObject] isEqualToString:line]))
        return;
    [history addObject:line];
    if (historyPath) {
        FILE *f = fopen([historyPath fileSystemRepresentation], "a");
        if (f) {
            fprintf(f, "%s\n", [[[line componentsSeparatedByString:@"\n"] componentsJoinedByString:@"\\n"] UTF8String]);
            fclose(f);
            chmod([historyPath fileSystemRepresentation], 0600);
        }
    }
}

- (void)clearDisplay
{
    if (renderedRows > 0) {
        if (cursorRow > 0)
            [term write:[NSString stringWithFormat:@"\033[%dA", cursorRow]];
        [term write:@"\r\033[J"];
    }
    renderedRows = 0;
    cursorRow = 0;
}

/* where the cursor index falls on the screen: row and column */
- (void)layout:(int *)endRow endCol:(int *)endCol cursorRow:(int *)crow cursorCol:(int *)ccol
{
    int cols = [term columns], row = 0, col = [term widthOf:prompt];
    NSUInteger i, n = [buffer length];
    BOOL placed = NO;
    for (i = 0; i <= n; i++) {
        if ((int)i == cursor && !placed) {
            *crow = row;
            *ccol = col;
            placed = YES;
        }
        if (i == n)
            break;
        {
            unichar c = [buffer characterAtIndex:i];
            if (c == '\n') {
                row++;
                col = [term widthOf:continuation];
                continue;
            }
            if (c >= 0xdc00 && c < 0xe000)
                continue;
            {
                NSString *one = (c >= 0xd800 && c < 0xdc00 && i + 1 < n) ? [buffer substringWithRange:NSMakeRange(i, 2)] : [NSString stringWithFormat:@"%C", c];
                int w = [term widthOf:one];
                if (col + w > cols) {
                    row++;
                    col = 0;
                }
                col += w;
            }
        }
    }
    *endRow = row;
    *endCol = col;
}

- (void)redraw
{
    int endRow, endCol, crow, ccol, cols = [term columns];
    NSMutableString *shown = [NSMutableString string];
    NSString *dimHint = nil;
    [self clearDisplay];
    [shown appendString:prompt];
    {
        NSArray *lines = [buffer componentsSeparatedByString:@"\n"];
        unsigned i;
        for (i = 0; i < [lines count]; i++) {
            if (i > 0) {
                [shown appendString:@"\r\n"];
                [shown appendString:continuation];
            }
            [shown appendString:[lines objectAtIndex:i]];
        }
    }
    [self layout:&endRow endCol:&endCol cursorRow:&crow cursorCol:&ccol];
    [term write:shown];
    if (endCol >= cols && endCol % cols == 0) {
        /* the cursor waits at the edge: force the wrap so the row count is right */
        [term write:@"\r\n"];
        endRow++;
    }
    renderedRows = endRow + 1;
    cursorRow = endRow;
    if ([hint length]) {
        dimHint = [term styled:[term clipToWidth:hint width:cols] with:@"dim"];
        [term write:@"\r\n"];
        [term write:dimHint];
        renderedRows++;
        cursorRow++;
    }
    /* put the cursor where the text cursor is */
    if (cursorRow > crow)
        [term write:[NSString stringWithFormat:@"\033[%dA", cursorRow - crow]];
    [term write:@"\r"];
    if (ccol > 0)
        [term write:[NSString stringWithFormat:@"\033[%dC", ccol % MAX(cols, 1) == 0 && ccol >= cols ? 0 : ccol % cols]];
    cursorRow = crow;
    [term flush];
}

- (void)finish
{
    int endRow, endCol, crow, ccol;
    [self layout:&endRow endCol:&endCol cursorRow:&crow cursorCol:&ccol];
    if (renderedRows > 0) {
        int below = renderedRows - 1 - cursorRow;
        if (below > 0)
            [term write:[NSString stringWithFormat:@"\033[%dB", below]];
        [term write:@"\r\033[J"];
    }
    renderedRows = 0;
    cursorRow = 0;
}

static int wordStart(NSString *s, int cursor)
{
    int i = cursor;
    while (i > 0 && ([s characterAtIndex:i - 1] == ' ' || [s characterAtIndex:i - 1] == '\n'))
        i--;
    while (i > 0 && [s characterAtIndex:i - 1] != ' ' && [s characterAtIndex:i - 1] != '\n')
        i--;
    return i;
}

static int wordEnd(NSString *s, int cursor)
{
    int i = cursor, n = (int)[s length];
    while (i < n && ([s characterAtIndex:i] == ' ' || [s characterAtIndex:i] == '\n'))
        i++;
    while (i < n && [s characterAtIndex:i] != ' ' && [s characterAtIndex:i] != '\n')
        i++;
    return i;
}

/* the index of the previous / next character boundary (a surrogate pair counts as one) */
static int prevIndex(NSString *s, int i)
{
    if (i <= 0)
        return 0;
    i--;
    if (i > 0 && [s characterAtIndex:i] >= 0xdc00 && [s characterAtIndex:i] < 0xe000)
        i--;
    return i;
}

static int nextIndex(NSString *s, int i)
{
    int n = (int)[s length];
    if (i >= n)
        return n;
    if ([s characterAtIndex:i] >= 0xd800 && [s characterAtIndex:i] < 0xdc00 && i + 1 < n)
        return i + 2;
    return i + 1;
}

- (int)rowStart:(int)at
{
    int i = at;
    while (i > 0 && [buffer characterAtIndex:i - 1] != '\n')
        i--;
    return i;
}

- (int)rowEnd:(int)at
{
    int i = at, n = (int)[buffer length];
    while (i < n && [buffer characterAtIndex:i] != '\n')
        i++;
    return i;
}

- (void)complete
{
    int start = 0;
    NSArray *options = [delegate editor:self completionsFor:buffer cursor:cursor start:&start];
    NSString *common;
    unsigned i;
    if ([options count] == 0) {
        [term bell];
        return;
    }
    common = [options objectAtIndex:0];
    for (i = 1; i < [options count]; i++) {
        NSString *o = [options objectAtIndex:i];
        NSUInteger k = 0;
        while (k < [common length] && k < [o length] && [common characterAtIndex:k] == [o characterAtIndex:k])
            k++;
        common = [common substringToIndex:k];
    }
    if (start < 0 || start > cursor)
        start = cursor;
    if ([common length] > (NSUInteger)(cursor - start) || [options count] == 1) {
        NSString *with = [options count] == 1 ? [common stringByAppendingString:@" "] : common;
        [buffer replaceCharactersInRange:NSMakeRange(start, cursor - start) withString:with];
        cursor = start + (int)[with length];
        return;
    }
    /* several: list them above the line */
    [self clearDisplay];
    {
        NSMutableString *list = [NSMutableString string];
        int cols = [term columns], used = 0, widest = 0;
        for (i = 0; i < [options count]; i++)
            widest = MAX(widest, [term widthOf:[options objectAtIndex:i]]);
        widest += 2;
        for (i = 0; i < [options count]; i++) {
            NSString *o = [options objectAtIndex:i];
            if (used + widest > cols) {
                [list appendString:@"\r\n"];
                used = 0;
            }
            [list appendString:[o stringByPaddingToLength:widest withString:@" " startingAtIndex:0]];
            used += widest;
        }
        [term write:[NSString stringWithFormat:@"%@\r\n", list]];
    }
}

- (BOOL)readLine:(NSString **)line interrupted:(BOOL *)interrupted
{
    [buffer setString:@""];
    cursor = 0;
    historyAt = -1;
    [saved release];
    saved = nil;
    if (interrupted)
        *interrupted = NO;
    [self redraw];
    for (;;) {
        TBKey k = [term readKeyWithin:80];
        BOOL changed = YES;
        switch (k.type) {
        case TBKeyNone:
            if ([term resized])
                [self redraw];
            [delegate editorIdle:self];
            continue;
        case TBKeyResize:
            [self redraw];
            continue;
        case TBKeyEOF:
            [self finish];
            return NO;
        case TBKeyEnter:
            /* a line ending in a backslash goes on */
            if ([buffer hasSuffix:@"\\"] && cursor == (int)[buffer length]) {
                [buffer deleteCharactersInRange:NSMakeRange([buffer length] - 1, 1)];
                [buffer appendString:@"\n"];
                cursor = (int)[buffer length];
                break;
            }
            [self finish];
            *line = [[buffer copy] autorelease];
            return YES;
        case TBKeyAltEnter:
            [self insert:@"\n"];
            break;
        case TBKeyPaste:
            [self insert:k.paste];
            break;
        case TBKeyChar: {
            unichar u[2];
            NSString *s;
            if (k.ch >= 0x10000) {
                unsigned int v = k.ch - 0x10000;
                u[0] = (unichar)(0xd800 + (v >> 10));
                u[1] = (unichar)(0xdc00 + (v & 0x3ff));
                s = [NSString stringWithCharacters:u length:2];
            } else {
                u[0] = (unichar)k.ch;
                s = [NSString stringWithCharacters:u length:1];
            }
            [self insert:s];
            break;
        }
        case TBKeyBackspace:
            if (cursor > 0) {
                int p = prevIndex(buffer, cursor);
                [buffer deleteCharactersInRange:NSMakeRange(p, cursor - p)];
                cursor = p;
            }
            break;
        case TBKeyDelete:
            if (cursor < (int)[buffer length])
                [buffer deleteCharactersInRange:NSMakeRange(cursor, nextIndex(buffer, cursor) - cursor)];
            break;
        case TBKeyLeft:
            cursor = prevIndex(buffer, cursor);
            break;
        case TBKeyRight:
            cursor = nextIndex(buffer, cursor);
            break;
        case TBKeyWordLeft:
            cursor = wordStart(buffer, cursor);
            break;
        case TBKeyWordRight:
            cursor = wordEnd(buffer, cursor);
            break;
        case TBKeyHome:
            cursor = [self rowStart:cursor];
            break;
        case TBKeyEnd:
            cursor = [self rowEnd:cursor];
            break;
        case TBKeyUp:
            /* inside a multi-line text it moves up a line; on the first line it goes back in the history */
            if ([self rowStart:cursor] > 0) {
                int start = [self rowStart:cursor], col = cursor - start, prevStart = [self rowStart:start - 1];
                cursor = MIN(prevStart + col, start - 1);
            } else if ([history count]) {
                if (historyAt < 0) {
                    [saved release];
                    saved = [buffer copy];
                    historyAt = (int)[history count];
                }
                if (historyAt > 0) {
                    historyAt--;
                    [self setText:[history objectAtIndex:historyAt]];
                }
            }
            break;
        case TBKeyDown:
            if ([self rowEnd:cursor] < (int)[buffer length]) {
                int start = [self rowStart:cursor], col = cursor - start, next = [self rowEnd:cursor] + 1, nextEnd = [self rowEnd:next];
                cursor = MIN(next + col, nextEnd);
            } else if (historyAt >= 0) {
                historyAt++;
                if (historyAt >= (int)[history count]) {
                    historyAt = -1;
                    [self setText:saved ? saved : @""];
                } else
                    [self setText:[history objectAtIndex:historyAt]];
            }
            break;
        case TBKeyBackTab:
            if (delegate && [(NSObject *)delegate respondsToSelector:@selector(editorBackTab:)])
                [(id)delegate editorBackTab:self];
            break;
        case TBKeyTab:
            if (delegate && [(NSObject *)delegate respondsToSelector:@selector(editor:completionsFor:cursor:start:)])
                [self complete];
            break;
        case TBKeyCtrl:
            switch (k.ch) {
            case 'a': cursor = [self rowStart:cursor]; break;
            case 'e': cursor = [self rowEnd:cursor]; break;
            case 'b': cursor = prevIndex(buffer, cursor); break;
            case 'f': cursor = nextIndex(buffer, cursor); break;
            case 'c':
                [self finish];
                [term write:@"^C\r\n"];
                if (interrupted)
                    *interrupted = YES;
                *line = @"";
                return YES;
            case 'd':
                if ([buffer length] == 0) {
                    [self finish];
                    return NO;
                }
                if (cursor < (int)[buffer length])
                    [buffer deleteCharactersInRange:NSMakeRange(cursor, nextIndex(buffer, cursor) - cursor)];
                break;
            case 'k': {
                int e = [self rowEnd:cursor];
                if (e == cursor && e < (int)[buffer length])
                    e++;
                [killed setString:[buffer substringWithRange:NSMakeRange(cursor, e - cursor)]];
                [buffer deleteCharactersInRange:NSMakeRange(cursor, e - cursor)];
                break;
            }
            case 'u': {
                int s = [self rowStart:cursor];
                [killed setString:[buffer substringWithRange:NSMakeRange(s, cursor - s)]];
                [buffer deleteCharactersInRange:NSMakeRange(s, cursor - s)];
                cursor = s;
                break;
            }
            case 'w': {
                int s = wordStart(buffer, cursor);
                [killed setString:[buffer substringWithRange:NSMakeRange(s, cursor - s)]];
                [buffer deleteCharactersInRange:NSMakeRange(s, cursor - s)];
                cursor = s;
                break;
            }
            case 'y': [self insert:killed]; break;
            case 'l':
                [term write:@"\033[2J\033[H"];
                renderedRows = 0;
                cursorRow = 0;
                break;
            case 'j': [self insert:@"\n"]; break;
            case 't': {
                if (cursor > 0 && cursor < (int)[buffer length]) {
                    unichar a = [buffer characterAtIndex:cursor - 1], b = [buffer characterAtIndex:cursor];
                    [buffer replaceCharactersInRange:NSMakeRange(cursor - 1, 2) withString:[NSString stringWithFormat:@"%C%C", b, a]];
                    cursor++;
                }
                break;
            }
            default:
                changed = NO;
            }
            break;
        case TBKeyAlt:
            if (k.ch == 127) {
                int s = wordStart(buffer, cursor);
                [buffer deleteCharactersInRange:NSMakeRange(s, cursor - s)];
                cursor = s;
            } else if (k.ch == 'd') {
                int e = wordEnd(buffer, cursor);
                [buffer deleteCharactersInRange:NSMakeRange(cursor, e - cursor)];
            } else
                changed = NO;
            break;
        case TBKeyEscape:
            if ([buffer length])
                [self setText:@""];
            break;
        default:
            changed = NO;
        }
        if (changed)
            [self redraw];
    }
}

@end
