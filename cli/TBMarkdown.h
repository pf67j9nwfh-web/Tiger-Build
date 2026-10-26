#import <Foundation/Foundation.h>
#import "TBTerm.h"

/* Markdown as it arrives, drawn for a terminal: headings, lists, quotes, rules, tables, inline styles, links, and fenced code with a little syntax
   colour and coloured diffs. Output is produced one whole line at a time, wrapped to the width, through the callback. */
@interface TBMarkdown : NSObject {
    TBTerm *term;
    NSMutableString *pending;
    BOOL inCode;
    NSString *codeLang;
    NSMutableArray *table;
    int width;
    NSString *margin;
    id target;
    SEL action;
    BOOL lastBlank;
    BOOL started;
}
- (id)initWithTerm:(TBTerm *)t margin:(NSString *)m target:(id)obj action:(SEL)sel;   /* action takes one NSString: lines with their newlines */
- (void)feed:(NSString *)text;
- (void)finish;                                 /* the last partial line, closing a code block */
- (void)setWidth:(int)w;
+ (NSString *)renderInline:(NSString *)text term:(TBTerm *)term;
@end
