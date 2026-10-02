#import <Foundation/Foundation.h>
#import "TBCompat.h"

/* Foundation-only helpers, so `make test` can check them without a window. */

/* Escape a string for use inside a JSON string literal. nil becomes "". */
NSString *TBJSONEscape(NSString *value);

/* Frames for the chat pane. Top to bottom: the relay problem line (wraps), a
   row with the Edit/Retry buttons on the left and the context and cost
   readout on the right, the transcript, the live "thinking" strip while a model
   works, and the message field with the Stop and Send buttons beside it. All
   of it must fit a 1024x768 screen, so the smallest window the app allows
   still shows every control. */
typedef struct {
    NSRect input;
    NSRect send;
    NSRect stop;
    NSRect transcript;
    NSRect context;
    NSRect actions;
    NSRect status;
    NSRect thinking;
    float fieldHeight;
} TBChatLayout;

#define TB_FIELD_MIN 24.0f
#define TB_FIELD_MAX 112.0f
#define TB_STATUS_MAX 64.0f
#define TB_THINKING_MAX 54.0f
#define TB_ACTIONS_WIDTH 188.0f

TBChatLayout TBLayoutChatPane(float paneWidth, float paneHeight, float wantedFieldHeight, float statusHeight, float thinkingHeight);

/* Estimated cost. Amounts are dollars. A chat keeps its usage by model:
   chat[@"usage"][@"provider|model"] = {input, cached, written, output,
   calls, cost, priced (calls the relay could price)}. */
NSString *TBFormatCost(double dollars);
NSString *TBFormatTokens(int count);
void TBAddUsage(NSMutableDictionary *chat, NSDictionary *event);
/* "Cost (est) $0.0123", or "Cost (est) N/A" when nothing was priced (local models). */
NSString *TBCostReadout(NSDictionary *chat);
/* One line per model for the readout's tooltip. */
NSString *TBCostDetail(NSDictionary *chat);

/* The relay only describes a chat as chat.plist describes it. These check an
   imported chat list before it replaces anything. NULL is fine; otherwise the
   result says what is wrong. */
NSString *TBChatListProblem(id chats);
/* A history file is either one workspace (chats, next) or a bundle of all of
   them (format TigerBuild-history, workspaces name -> {chats, next,
   settings}). Returns nil for anything else. */
NSDictionary *TBHistoryBundle(id root, NSString *fallbackName);
BOOL TBWorkspaceNameOK(NSString *name);

/* One workspace's chats, shared by every window that shows it. Windows used
   to each load their own copy of the file, so the one that saved last
   silently erased the other's work. A store is created on first use and
   found again by path; saves are batched and written once. */
extern NSString *TBStoreChangedNotification;
@interface TBStore : NSObject {
    NSString *path;
    NSMutableArray *chats;
    NSMutableDictionary *settings;
    int next;
    BOOL dirty;
}
- (id)initWithPath:(NSString *)file;
+ (TBStore *)storeAtPath:(NSString *)path;
/* Forget every open store without saving: the files were replaced. */
+ (void)forgetAll;
+ (void)flushAll;
- (NSString *)path;
- (NSMutableArray *)chats;
- (NSMutableDictionary *)settings;
- (int)next;
- (int)takeNextId;
- (void)setNext:(int)value;
- (void)markDirty;
- (void)flush;
@end

/* Rough token count for a chat, used for the context readout and to decide
   when to compact. messages holds dictionaries with text/role/status/image. */
int TBEstimateTokens(NSArray *messages, BOOL toolsOn);

/* The model list the relay serves at /v1/models. The relay builds it at
   launch from each provider's own model list, keeping only models that
   answered a test call. Tab-separated lines:
     provider<TAB>id<TAB>title<TAB>state    ok, nokey, checking, error, offline
     model<TAB>provider<TAB>id<TAB>title<TAB>isDefault<TAB>context
     checking<TAB>count                     models still being tested
   Older lists without a state column mean "ok". */
/* The Mac Tiger Build is running on, read from the system. */
@interface TBMachine : NSObject
+ (void)startDetection;
+ (NSString *)name;        /* "Power Mac G4 (AGP graphics)", or the model code */
+ (NSString *)detail;      /* CPU, speed and memory, when known */
+ (NSString *)systemVersion;
@end

@interface ModelCatalog : NSObject {
    NSMutableArray *providers;
    NSMutableDictionary *models;
    NSMutableDictionary *defaults;
    NSMutableDictionary *states;
    int checking;
}
+ (ModelCatalog *)shared;
- (BOOL)loadText:(NSString *)text;
- (NSArray *)providers;
- (NSString *)titleForProvider:(NSString *)provider;
- (NSArray *)modelsForProvider:(NSString *)provider;
- (NSString *)defaultModelForProvider:(NSString *)provider;
- (BOOL)hasModel:(NSString *)model forProvider:(NSString *)provider;
- (NSString *)stateForProvider:(NSString *)provider;
/* A provider can be picked for a chat: it has a key and working models.
   Local is judged by the app's own local model list, not by this. */
- (BOOL)providerUsable:(NSString *)provider;
- (int)checkingCount;
@end
