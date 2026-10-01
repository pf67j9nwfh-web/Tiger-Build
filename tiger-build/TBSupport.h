#import <Foundation/Foundation.h>

/* Foundation-only helpers, so `make test` can check them without a window. */

/* Escape a string for use inside a JSON string literal. nil becomes "". */
NSString *TBJSONEscape(NSString *value);

/* Frames for the chat pane. The Send button is centred on the message field,
   so both move whenever the field grows or shrinks. status is the relay
   problem line across the top; it wraps, so statusHeight is the height its
   text needs (0 when there is no problem) and the transcript moves down. */
typedef struct {
    NSRect input;
    NSRect send;
    NSRect transcript;
    NSRect context;
    NSRect status;
    float fieldHeight;
} TBChatLayout;

#define TB_FIELD_MIN 24.0f
#define TB_FIELD_MAX 112.0f
#define TB_STATUS_MAX 64.0f

TBChatLayout TBLayoutChatPane(float paneWidth, float paneHeight, float wantedFieldHeight, float statusHeight);

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
