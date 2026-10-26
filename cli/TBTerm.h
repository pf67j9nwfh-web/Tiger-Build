#import "TBCompat.h"

/* The terminal: raw input, escape sequences, colours, the width of text, and a line editor. Plain ANSI (works on Tiger's Terminal, with 16 colours,
   and on modern terminals over ssh, which get more). No terminfo. */

typedef enum { TBKeyChar, TBKeyEnter, TBKeyTab, TBKeyBackTab, TBKeyBackspace, TBKeyDelete, TBKeyUp, TBKeyDown, TBKeyLeft, TBKeyRight, TBKeyHome, TBKeyEnd,
    TBKeyPageUp, TBKeyPageDown, TBKeyEscape, TBKeyCtrl, TBKeyAlt, TBKeyAltEnter, TBKeyWordLeft, TBKeyWordRight, TBKeyPaste, TBKeyEOF, TBKeyNone, TBKeyResize } TBKeyType;

typedef struct {
    TBKeyType type;
    unsigned int ch;          /* the character for TBKeyChar / TBKeyAlt; the letter for TBKeyCtrl ('a'..'z') */
    NSString *paste;          /* TBKeyPaste */
} TBKey;

typedef enum { TBColorNone, TBColor16, TBColor256, TBColorTrue } TBColorLevel;

@interface TBTerm : NSObject {
    BOOL raw;
    TBColorLevel level;
    BOOL unicode;
    BOOL asciiOnly, probeEncoding;       /* see -init: the terminal may not take UTF-8 */
    NSStringEncoding legacy;             /* what a terminal that is not UTF-8 takes: Mac OS Roman unless the locale says Latin 1 */
    int columns, rows;
    NSMutableData *out;
}
+ (TBTerm *)term;
- (BOOL)isInteractive;                  /* standard input and output are a terminal */
- (BOOL)outputIsTerminal;
- (TBColorLevel)colorLevel;
- (void)setColorLevel:(TBColorLevel)level;
- (BOOL)unicode;                           /* the terminal takes UTF-8 (else drawing characters are plain ones) */
- (void)probeUTF8;
- (int)readByte:(int)milliseconds;
- (int)columns;
- (int)rows;
- (void)enterRaw;
- (void)leaveRaw;
- (TBKey)readKeyWithin:(int)milliseconds;   /* TBKeyNone on timeout */
- (void)write:(NSString *)text;            /* buffered; flush to show */
- (void)flush;
/* styles: the escape for a role, or "" without colour */
- (NSString *)style:(NSString *)name;      /* reset bold dim italic underline red green yellow blue magenta cyan gray brightwhite and bg: userbg codebg */
- (NSString *)styled:(NSString *)text with:(NSString *)name;
- (int)widthOf:(NSString *)text;           /* columns the text takes, without escape sequences */
- (NSString *)wrap:(NSString *)text width:(int)width indent:(NSString *)indent;   /* ANSI aware, keeps words */
- (NSString *)clipToWidth:(NSString *)text width:(int)width;
- (void)setTitle:(NSString *)title;
- (void)bell;
- (BOOL)resized;                           /* the window changed size since the last call */
@end

/* A line editor with history and completion. */
@class TBLineEditor;
@protocol TBLineEditorDelegate
/* candidates for the word before the cursor; *start is where the word begins in the line. nil for none. */
- (NSArray *)editor:(TBLineEditor *)editor completionsFor:(NSString *)line cursor:(int)cursor start:(int *)start;
- (void)editorIdle:(TBLineEditor *)editor;
@end

@interface TBLineEditor : NSObject {
    TBTerm *term;
    NSMutableString *buffer;
    int cursor;                 /* in composed characters */
    NSMutableArray *history;
    NSString *historyPath;
    int historyAt;
    NSString *saved;
    NSString *prompt, *continuation;
    int renderedRows, cursorRow;
    id<TBLineEditorDelegate> delegate;
    NSMutableString *killed;
    BOOL ascii;
    NSString *hint;
    BOOL wake;
    NSString *carry;
}
- (void)wakeUp;                            /* make readLine return an empty line now (the typed text is kept for the next call) */
- (id)initWithTerm:(TBTerm *)t historyPath:(NSString *)path;
- (void)setDelegate:(id<TBLineEditorDelegate>)d;
- (void)setPrompt:(NSString *)p continuation:(NSString *)c;
- (void)setHint:(NSString *)text;           /* dim text under the line, e.g. the status */
/* NO at end of input (Control-D on an empty line). Control-C clears the line and returns @"" with *interrupted set. */
- (BOOL)readLine:(NSString **)line interrupted:(BOOL *)interrupted;
- (void)addHistory:(NSString *)line;
- (void)insert:(NSString *)text;
- (NSString *)text;
- (void)setText:(NSString *)text;
- (void)redraw;
- (void)clearDisplay;                       /* erase what the editor drew (before printing above it) */
- (void)finish;                             /* leave the line as it is and go below it */
@end
