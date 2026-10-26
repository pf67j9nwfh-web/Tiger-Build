#import "TBCompat.h"
#import "TBSupport.h"
#import "TBService.h"

/* The part of the terminal program that is not the terminal: the workspace and its chats (the same files the window uses), the models and tools,
   the request a chat makes, a turn running, and its frames put into the chat as the window puts them (so the window shows the chat the same way).
   Foundation only. Call it from the main thread, with the run loop running while a turn works. */

@class TBCLICore;

@protocol TBCLIEvents
- (void)core:(TBCLICore *)core text:(NSString *)delta;                 /* the reply grows */
- (void)core:(TBCLICore *)core status:(NSString *)note error:(BOOL)error;
- (void)core:(TBCLICore *)core activity:(NSDictionary *)event;          /* a tool started or finished: phase, name, label, detail, output, failed, elapsed */
- (void)core:(TBCLICore *)core thinking:(NSString *)delta;
- (void)core:(TBCLICore *)core media:(NSString *)description;           /* a picture, video, file or post that the window shows */
- (void)core:(TBCLICore *)core question:(NSDictionary *)event;          /* a tool wants approval: answer with -answer:decision: */
- (void)core:(TBCLICore *)core usage:(NSDictionary *)event;
- (void)coreTurnEnded:(TBCLICore *)core;
@end

@interface TBCLICore : NSObject {
    TBStore *store;
    NSString *workspace;
    NSMutableDictionary *current;
    NSArray *toolCatalog;
    NSMutableArray *localModels;
    NSString *commanderProblem;
    id<TBCLIEvents> events;
    TBLocalTurn *turn;
    NSString *runId;
    NSMutableData *frameBuffer;
    BOOL busy, stopping, compacting, compactOnly;
    double turnStart;
    NSMutableDictionary *question;     /* the approval being asked, if any */
    NSMutableDictionary *overrides;    /* command line: servers on/off for this run */
    NSString *permissionMode, *extraInstructions;
}
+ (TBCLICore *)core;
- (void)setEvents:(id<TBCLIEvents>)delegate;

/* workspaces and chats */
- (NSString *)workspace;
- (NSArray *)workspaceNames;
- (void)openWorkspace:(NSString *)name;
- (TBStore *)store;
- (NSMutableArray *)chats;
- (NSMutableDictionary *)workspaceSettings;
- (NSMutableDictionary *)currentChat;
- (void)setCurrentChat:(NSMutableDictionary *)chat;
- (NSMutableDictionary *)chatWithId:(NSString *)ident;
- (NSMutableDictionary *)newChat;                     /* made current, not yet stored */
- (NSMutableDictionary *)forkChat:(NSDictionary *)chat upTo:(int)messageCount;
- (void)deleteChat:(NSMutableDictionary *)chat;
- (void)save;                                          /* now, and tell the lock holder's merge */
- (NSArray *)searchChats:(NSString *)text;            /* chats whose title or messages contain the text, newest first */
- (NSString *)titleOf:(NSDictionary *)chat;

/* models */
- (void)refreshCatalog;                                /* the model list, local models, tool list */
- (NSString *)providerForChat:(NSDictionary *)chat;
- (NSString *)modelForChat:(NSDictionary *)chat;
- (BOOL)providerUsable:(NSString *)provider;
- (NSString *)providerNote:(NSString *)provider;      /* why not, or nil */
- (NSArray *)modelsForProvider:(NSString *)provider;  /* [{id, title}] */
- (NSString *)defaultModelForProvider:(NSString *)provider;
- (BOOL)setProvider:(NSString *)provider model:(NSString *)model chat:(NSMutableDictionary *)chat error:(NSString **)problem;
- (BOOL)setModelSpec:(NSString *)spec chat:(NSMutableDictionary *)chat error:(NSString **)problem;   /* "provider:model", "provider", or a model name */
- (NSString *)firstUsableProvider;

/* tools */
- (NSArray *)toolCatalog;                              /* [{id, title, default, approval}] */
- (BOOL)serverEnabled:(NSString *)key chat:(NSDictionary *)chat;
- (void)setServer:(NSString *)key enabled:(BOOL)on chat:(NSMutableDictionary *)chat;
- (BOOL)approvalOn:(NSString *)key chat:(NSDictionary *)chat;
- (void)setApproval:(BOOL)on forKey:(NSString *)key chat:(NSMutableDictionary *)chat;
- (NSString *)commanderProblem;
/* how tools are approved: ask (the default), edits (file changes go through), plan (nothing changes; the model plans), auto (nothing is asked) */
- (void)setPermissionMode:(NSString *)mode;
- (NSString *)permissionMode;
- (void)setExtraInstructions:(NSString *)text;       /* added to every request: project files and the mode's own note */
- (void)setRunOverrides:(NSDictionary *)servers;      /* {key: BOOL} applied to every request of this run, not saved */

/* a turn */
- (BOOL)busy;
- (NSString *)sendText:(NSString *)text;               /* nil when started, else why not */
- (NSString *)resend;                                  /* ask again for the last user message */
- (void)stop;
- (NSString *)compact;                                 /* summarize the older messages now; nil when started, else why not */
- (int)contextLimitForChat:(NSMutableDictionary *)chat;
- (void)answer:(NSString *)decision;                   /* allow, always or deny, for the question being asked */
- (BOOL)guide:(NSString *)text;                        /* a note to the model while it works */
- (double)turnSeconds;
- (NSData *)requestBodyForChat:(NSDictionary *)chat;

/* chat contents */
- (NSString *)lastReplyText:(NSDictionary *)chat;
- (int)contextTokensForChat:(NSDictionary *)chat;
- (NSString *)liveLeaseNoteForChat:(NSDictionary *)chat;   /* "working in the Tiger Build window" and the like, or nil */
@end

NSString *TBCLISupportDir(void);
