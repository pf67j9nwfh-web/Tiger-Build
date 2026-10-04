#import <Foundation/Foundation.h>

/* Reading the code blocks a model writes, and colouring them. Foundation only,
   so the unit tests can use it without a window. */

enum {
    TBTokPlain = 0,
    TBTokKeyword,
    TBTokType,
    TBTokString,
    TBTokComment,
    TBTokNumber,
    TBTokFunction,
    TBTokProperty,
    TBTokInsert,
    TBTokDelete
};

/* Splits chat text at ``` fences. Each item is a dictionary: "code" (NSNumber
   BOOL), "text" (the prose, or the code without its fence lines), and for code
   "lang" (the tag after the opening fence, lower case, possibly empty) and
   "closed" (NO while a reply is still streaming and the fence is not shut). */
NSArray *TBSplitBlocks(NSString *text);

/* The name to show above a block: "Python" for "py", "Shell" for "sh". A tag
   the program does not know is shown as written; no tag at all is guessed from
   the code, and "Code" when that fails. */
NSString *TBLanguageTitle(NSString *tag, NSString *code);

/* One byte per UTF-16 unit of code, each a TBTok value. */
NSData *TBHighlight(NSString *code, NSString *tag);

/* The file extension to suggest when saving a block of this language, from the
   title TBLanguageTitle gives: "py" for "Python", "txt" when unknown. */
NSString *TBLanguageExtension(NSString *title);

/* Whether the tag names a language the highlighter has rules for. */
BOOL TBLanguageKnown(NSString *tag);
