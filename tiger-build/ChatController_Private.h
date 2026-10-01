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
@end
