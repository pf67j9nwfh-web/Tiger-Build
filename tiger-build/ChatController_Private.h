#import "ChatController.h"
#import "EngineRequest.h"
#import "TBSupport.h"

/* Methods the ChatController source files call on each other. They are
   implemented in ChatController.m and ChatController+Preferences.m. */
@interface ChatController (Internal)
- (void)copyDiagnostics:(id)sender;
- (void)rebuildPromptsMenu;
- (void)managePrompts:(id)sender;
- (void)savePromptFromInput:(id)sender;
- (void)usePrompt:(id)sender;
- (void)tryWithAnotherModel:(id)sender;
- (void)showCostReport:(id)sender;
- (void)importOtherExport:(id)sender;
- (void)quickAsk:(id)sender;
- (void)lockNow:(id)sender;
- (void)setLockPassword:(id)sender;
- (void)applyQuickAskHotKey;
- (void)startScheduler;
- (void)startLockWatcher;
- (void)lockIfWantedAtStart;
- (void)askTigerBuild:(NSPasteboard *)pboard userData:(NSString *)userData error:(NSString **)error;
- (BOOL)isLocked;
- (void)noteActivity;
- (void)askInNewChat:(NSString *)text send:(BOOL)send;
- (void)downloadAndOpenUpdate:(NSDictionary *)release;
- (NSString *)memoryRequestFragment;
- (void)updateMemoryAfterReply:(NSMutableDictionary *)chat;
- (void)editMemory:(id)sender;
- (void)buildAlertsTab:(NSTabView *)tabs;
- (void)loadAlertOptions;
- (void)saveAlertOptions;
- (void)noteReplyFinished:(BOOL)offScreen;
- (double)spendToday;
- (NSString *)spendLimitProblemForChat:(NSDictionary *)chat;
- (void)spendCheckAfterUsage:(NSDictionary *)event chat:(NSMutableDictionary *)chat;
- (void)checkForUpdates:(id)sender;
- (void)checkForUpdatesAtLaunch;
- (void)uninstallTigerBuild:(id)sender;
- (void)forgetMCPSignIns:(id)sender;
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
- (NSString *)relayProblemForRequest:(EngineRequest *)request;
- (NSMutableDictionary *)blankChat;
- (void)reloadTableSelect:(int)row show:(BOOL)show;
- (NSData *)historyData;
- (void)importHistoryData:(NSData *)data;
- (void)clearAllHistory:(id)sender;
- (IBAction)newChat:(id)sender;
- (void)exportHistory:(id)sender;
- (void)importHistory:(id)sender;
- (void)reportUnconfigured;
- (void)commanderStart:(id)sender;
- (void)commanderStop:(id)sender;
- (void)commanderAutostart:(id)sender;
- (void)commanderIP:(id)sender;
- (NSDictionary *)commanderCommand:(NSString *)command;
- (BOOL)loginLaunchOn;
- (void)applySSHServer:(BOOL)on;
- (void)shareToolCatalog;
- (void)setRemoteSudo:(BOOL)on;
- (BOOL)remoteSudoOn;
- (BOOL)administratorPasswordIsSaved;
- (void)copyRemoteSudoKey:(id)sender;
- (void)setLoginLaunch:(BOOL)on;
- (BOOL)administratorPasswordSaved;
- (BOOL)saveAdministratorPassword;
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
- (void)compactNow:(id)sender;
- (void)setWorkspaceChoice:(NSString *)name;
- (void)announceStoreChange;
- (BOOL)chatIsBusyElsewhere:(NSDictionary *)chat;
- (BOOL)anyWindowBusy;
- (BOOL)isBusy;
- (void)storeChanged:(NSNotification *)note;
- (void)storesReplaced:(NSNotification *)note;
- (void)startTurn;
- (BOOL)anyRunActive;
- (BOOL)chatHasParkedRun:(NSString *)chatId;
- (void)switchRunsToChat:(NSDictionary *)chat;
- (BOOL)enterRunOfTurn:(id)turn orChat:(NSString *)chatId;
- (void)leaveRun;
- (void)stopParkedRuns;
- (void)applyBusyUI;
- (void)showThinkingText;
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
- (void)refreshCommanderStatus;
@end

/* ChatController+Run.m */
@interface ChatController (Attachments)
- (IBAction)attachFile:(id)sender;
- (BOOL)chatHasAttachments:(NSDictionary *)chat;
- (BOOL)confirmCloudAttach;
- (BOOL)cancelAttachments;
- (BOOL)attachmentsRunning;
- (IBAction)attachPDFPages:(id)sender;
- (void)attachPaths:(NSArray *)paths;
- (NSArray *)attachmentsForPath:(NSString *)path problem:(NSString **)problem;
- (void)sweepStoredFiles;
- (NSArray *)imageAttachmentsForChat:(NSDictionary *)chat;
@end

@interface ChatController (ChatFile)
- (IBAction)exportChat:(id)sender;
- (IBAction)importChat:(id)sender;
@end

@interface ChatController (Extras)
- (NSArray *)findResultsFor:(NSString *)query;
- (void)openFindResult:(NSDictionary *)hit;
- (IBAction)showFind:(id)sender;
- (IBAction)editInstructions:(id)sender;
- (IBAction)biggerText:(id)sender;
- (IBAction)copyLastCode:(id)sender;
- (void)applyTextScale;
- (IBAction)smallerText:(id)sender;
- (IBAction)normalTextSize:(id)sender;
@end

/* Ask once and remember (see ChatController+Attachments.m). */
BOOL TBConfirmOnce(NSString *key, NSString *title, NSString *message, NSString *okTitle);

BOOL TBCommanderRemoteAllowed(void);
/* A chat from a file keeps no approval choices and no administrator or download switch: a file must not pre-approve tools. */
void TBSanitizeImportedChat(NSMutableDictionary *chat);

@interface ChatController (Sudo)
- (void)startSudoBroker;
- (void)refreshSudoStatus;
- (IBAction)toggleSudoMode:(id)sender;
- (IBAction)setAdministratorPassword:(id)sender;
@end

@interface ChatController (Appearance)
- (IBAction)showAppearance:(id)sender;
- (void)applyInterfaceTheme;
- (void)applyPopupTheme:(NSPopUpButton *)popup;
- (void)applyButtonTheme:(NSButton *)button;
- (void)interfaceThemeChanged:(NSNotification *)note;
@end

@interface ChatController (Dictation)
- (IBAction)toggleDictation:(id)sender;
- (IBAction)toggleDictationSend:(id)sender;
- (BOOL)isDictating;
- (BOOL)cancelDictation;
- (BOOL)dictationRunning;
- (void)finishDictation:(BOOL)keep;
- (void)beginDictation;
- (void)updateDictationClock:(NSTimer *)timer;
@end

@interface ChatController (Voice)
- (IBAction)speakLast:(id)sender;
- (IBAction)stopSpeaking:(id)sender;
- (IBAction)toggleAutoSpeak:(id)sender;
- (IBAction)toggleVoiceCommands:(id)sender;
- (IBAction)chooseVoice:(id)sender;
- (BOOL)isSpeakingNow;
- (BOOL)voiceCommandsOn;
- (void)speakFinishedReplyIfWanted:(NSMutableDictionary *)chat;
- (void)resumeVoiceIfWanted;
@end

@interface ChatController (EditAnywhere)
- (void)editAtIndex:(int)index;
- (void)editFromMessage:(NSMutableDictionary *)message;
- (void)branchFromMessage:(NSMutableDictionary *)message;
@end

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

