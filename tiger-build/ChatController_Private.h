#import "ChatController.h"
#import "RelayClient.h"
#import "TBSupport.h"

/* Methods the ChatController source files call on each other. They are
   implemented in ChatController.m and ChatController+Preferences.m. */
@interface ChatController (Internal)
- (NSString *)supportDir;
- (void)saveStore;
- (void)flushStore;
- (void)refreshCatalog;
- (void)refreshLocalModels;
- (int)rememberContextLimit;
- (void)updateContextReadout;
- (void)showPreferences:(id)sender;
- (void)setRelayProblem:(NSString *)text;
- (float)relayStatusHeightForWidth:(float)width;
- (void)relayStatusChanged;
- (NSString *)relayProblemForRequest:(RelayRequest *)request;
- (NSMutableDictionary *)blankChat;
- (void)reloadTableSelect:(int)row show:(BOOL)show;
- (NSData *)historyData;
- (void)importHistoryData:(NSData *)data;
- (void)clearAllHistory:(id)sender;
- (void)exportHistory:(id)sender;
- (void)exportHistoryToRelay:(id)sender;
- (void)importHistoryFromRelay:(id)sender;
- (void)importHistory:(id)sender;
- (void)reportUnconfigured;
- (void)commanderStart:(id)sender;
- (void)commanderStop:(id)sender;
- (void)commanderAutostart:(id)sender;
- (void)commanderIP:(id)sender;
- (NSDictionary *)commanderCommand:(NSString *)command;
- (void)showIntegrations:(id)sender;
- (void)exportAllSettings:(id)sender;
- (void)importAllSettings:(id)sender;
- (NSString *)workspaceName;
- (void)refillWorkspacePopup;
- (void)loadStore;
- (void)chooseWorkspace:(id)sender;
- (void)newWorkspace:(id)sender;
- (void)workspaceNext:(id)sender;
- (void)copyAnswer:(id)sender;
- (void)focusComposer:(id)sender;
- (void)jumpToLatest:(id)sender;
- (void)expandActivities:(id)sender;
- (void)collapseActivities:(id)sender;
- (void)deleteWorkspace:(id)sender;
- (void)showWorkspaceSettings:(id)sender;
- (void)connectCommanderSSH:(id)sender;
- (void)compactNow:(id)sender;
- (void)setWorkspaceChoice:(NSString *)name;
- (void)announceStoreChange;
- (BOOL)chatIsBusyElsewhere:(NSDictionary *)chat;
- (BOOL)anyWindowBusy;
- (BOOL)isBusy;
- (void)storeChanged:(NSNotification *)note;
- (void)storesReplaced:(NSNotification *)note;
- (void)startTurn;
- (void)finishWithoutStream:(NSMutableDictionary *)chat;
- (NSMutableDictionary *)chatWithId:(NSString *)chatId;
- (void)addStatus:(NSString *)text toChat:(NSMutableDictionary *)chat;
- (void)refreshTranscriptIfCurrent:(NSMutableDictionary *)chat;
- (void)finishStream;
- (void)layoutPanes;
- (void)relayStatusChanged;
- (BOOL)toolsEnabled:(NSDictionary *)chat;
- (BOOL)providerUsable:(NSString *)provider;
- (NSString *)providerForChat:(NSDictionary *)chat;
- (NSString *)modelForChat:(NSDictionary *)chat;
- (BOOL)model:(NSString *)model allowedForProvider:(NSString *)provider;
- (NSString *)defaultModelForProvider:(NSString *)provider;
- (NSString *)providerNote:(NSString *)provider;
- (NSArray *)workspaceNamesOnDisk;
- (void)ensureCommanderInstalled;
- (void)maybeOfferSSH;
- (void)refreshCommanderStatus;
@end

/* ChatController+Run.m */
@interface ChatController (Run)
- (NSArray *)currentToolCatalog;
- (BOOL)serverEnabled:(NSString *)key chat:(NSDictionary *)chat;
- (void)setServer:(NSString *)key enabled:(BOOL)on chat:(NSMutableDictionary *)chat;
- (BOOL)anyServerEnabled:(NSDictionary *)chat;
- (BOOL)approvalOn:(NSString *)key chat:(NSDictionary *)chat;
- (NSString *)runOptionsJSONForChat:(NSDictionary *)chat;
- (void)rebuildToolsMenu;
- (void)refreshToolCatalog;
- (void)noteUsage:(NSDictionary *)event chat:(NSMutableDictionary *)chat;
- (void)setThinkingText:(NSString *)text;
- (void)noteThinking:(NSString *)piece;
- (IBAction)stopRun:(id)sender;
- (BOOL)guidanceAvailable;
- (void)sendGuidance:(NSString *)text;
- (void)guidanceDelivered:(NSString *)text chat:(NSMutableDictionary *)chat;
- (void)returnUndeliveredGuidance;
- (void)askApprovalFrame:(NSData *)payload chat:(NSMutableDictionary *)chat;
- (void)startPulse;
- (void)stopPulse;
- (void)syncRunButtons;
- (int)lastUserIndex;
- (IBAction)retryLast:(id)sender;
- (IBAction)editLast:(id)sender;
- (IBAction)cancelEdit:(id)sender;
- (void)forgetEdit;
- (void)newRunId;
- (NSString *)commanderStatusLine;
- (void)commanderProblemChanged;
- (IBAction)toggleTools:(id)sender;
- (void)returnTextToField:(NSString *)text;
@end
