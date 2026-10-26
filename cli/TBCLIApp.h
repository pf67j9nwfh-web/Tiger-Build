#import <Foundation/Foundation.h>
#import "TBCLICore.h"
#import "TBTerm.h"
#import "TBMarkdown.h"

/* The interactive terminal program: prompt, streamed and rendered replies, tool cards, approvals, slash commands. */

@interface TBCLIApp : NSObject <TBCLIEvents, TBLineEditorDelegate> {
@public
    TBCLICore *core;
    TBTerm *term;
    TBLineEditor *editor;
    TBMarkdown *md;
    NSMutableDictionary *config;
    BOOL quit;
    BOOL verbose, showThinking, bell;
    /* a turn on screen */
    BOOL working, textStarted, thinkingStarted, lastWasTool;
    NSMutableString *typed;            /* what is typed while the model works */
    double spinStart;
    int spinFrame;
    double lastSpin;
    NSString *spinLabel;
    BOOL liveShown;
    NSMutableString *thinkBuffer;
    NSDictionary *pendingQuestion;
    NSMutableArray *shellNotes;        /* output of !commands waiting to go to the model with the next message */
    double lastInterrupt;
    NSString *projectNote;             /* the project files read for the instructions */
    NSMutableDictionary *toolStarts;
    int turnTools;
    BOOL planPending;
    NSArray *allowRules, *denyRules;
    double lastKeepaliveCheck;
    NSString *firstLinePrefix;
    NSString *initial;                 /* a first message given on the command line */
    BOOL firstLine;
}
- (id)initWithCore:(TBCLICore *)c;
- (int)runInteractive;
- (void)printLine:(NSString *)text;                        /* a line above the prompt */
- (void)printStyled:(NSString *)text style:(NSString *)style;
- (void)setPermissionMode:(NSString *)mode announce:(BOOL)announce;
- (NSString *)configString:(NSString *)key default:(NSString *)value;
- (void)saveConfig;
- (NSString *)costText:(NSDictionary *)chat;
- (void)runTurnWithText:(NSString *)text;
- (void)showChat:(NSDictionary *)chat full:(BOOL)full;     /* its messages in the terminal */
- (NSString *)expandMentions:(NSString *)text;
@end

@interface TBCLIApp (Commands)
- (BOOL)runCommand:(NSString *)line;                       /* a slash command; YES when it was one */
- (NSArray *)commandNames;
@end

@interface TBCLIApp (Private)
- (void)watchTurn;
- (NSString *)cliDir;
- (BOOL)runCustomCommand:(NSString *)cmd arguments:(NSString *)arg;
- (void)banner;
- (NSString *)modelLabel:(NSDictionary *)chat;
- (NSString *)statusLine;
- (NSString *)tokenText:(int)n;
- (void)applyInstructions:(NSString *)files;
- (void)refreshInstructions;
- (void)endTextOnly;
- (void)offerPlanApproval;
- (void)runShell:(NSString *)command;
- (void)appendNote:(NSString *)note;
- (void)mdLine:(NSString *)text;
- (void)mdPlain:(NSString *)text;
@end
