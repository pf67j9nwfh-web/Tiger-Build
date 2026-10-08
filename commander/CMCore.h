#import <Foundation/Foundation.h>

/* ppc-commander: a Desktop Commander-style MCP server for Mac OS X 10.4 and later, written in Objective-C so it needs no
   Python. It speaks MCP over standard input and output and does what a model asks on this Mac: files, search, shell
   commands on a terminal, screenshots, git and Subversion. Tiger Build starts it for its own chats; another computer can
   start it over SSH if this Mac's owner allows that. Log lines go to standard error only. */

#define CM_VERSION @"1.0.0"

extern NSString *const CMFailure;                    /* exception name: the reason is for the model */
void CMFail(NSString *format, ...);

/* Arguments of a tool call. Missing or wrong-typed values raise CMFailure. */
NSString *CMOptString(NSDictionary *args, NSString *key, NSString *fallback);
NSString *CMString(NSDictionary *args, NSString *key);
long long CMInteger(NSDictionary *args, NSString *key);
long long CMOptInteger(NSDictionary *args, NSString *key, long long fallback);
BOOL CMOptBool(NSDictionary *args, NSString *key, BOOL fallback);
NSArray *CMStringList(id value);
NSString *CMSwap(NSString *text, NSString *from, NSString *to);   /* every occurrence replaced (stringByReplacingOccurrencesOfString: is 10.5 and later) */
NSString *CMClip(NSString *text, unsigned limit);
NSString *CMCap(NSString *text);                   /* the reply cut at 180,000 characters */

/* Text of files. Bytes that are not UTF-8 are read as Latin-1. */
NSString *CMDecode(NSData *data, NSString **encoding);
NSString *CMHexPreview(NSData *data, unsigned count);
NSArray *CMSplitLines(NSString *text);
NSString *CMBase64(NSData *data);

/* State and settings. Everything lives in ~/Library/Application Support/Tiger Build/commander. */
NSString *CMStateFolder(void);
NSString *CMBinaryPath(void);
NSMutableDictionary *CMConfig(void);               /* blockedCommands, defaultShell, allowedDirectories, fileReadLineLimit, ... */
void CMLoadSettings(void);
void CMSaveConfig(void);
BOOL CMSudoEnabled(void);
BOOL CMPolicyAllowsSudo(void);
void CMSetSudoKey(NSString *key);
NSString *CMSudoKey(void);
BOOL CMDiffsEnabled(void);                         /* write_file and edit_block show what changed */
BOOL CMScreenEnabled(void);                        /* the screen_* tools are offered */
NSString *CMNow(void);
void CMLog(NSString *format, ...);
NSString *CMSystemInfo(NSString *key);             /* uname, sw_vers, model, mem */
NSString *CMInstructions(void);
NSString *CMPolicyPath(void);

/* Where tools may go. */
NSString *CMCheckPath(NSString *path);             /* absolute, symlinks resolved, allowed; raises otherwise */
NSString *CMCheckWritable(NSString *path);         /* the same, and not one of Commander's own files */
NSString *CMResolve(NSString *path);
BOOL CMPathAllowed(NSString *resolved);
NSString *CMWorkspaceRoot(void);
NSString *CMWhyBlocked(NSString *command);         /* nil when a shell command may run */
NSString *CMWorkspaceCommandProblem(NSString *command);
NSArray *CMCommandWords(NSString *command);

/* History and usage. */
void CMRecord(NSString *tool, NSDictionary *args, NSString *text, BOOL ok, int millis);

/* The tools. Each returns an NSString, or an NSDictionary {text, image (base64), mime} for a picture. */
id CMToolScreenInfo(NSDictionary *args);
id CMToolScreenClick(NSDictionary *args);
id CMToolScreenMove(NSDictionary *args);
id CMToolScreenDrag(NSDictionary *args);
id CMToolScreenScroll(NSDictionary *args);
id CMToolScreenType(NSDictionary *args);
id CMToolScreenKey(NSDictionary *args);
void CMScreenSetScale(double scale);
id CMToolReadFile(NSDictionary *args);
id CMToolReadMultiple(NSDictionary *args);
id CMToolWriteFile(NSDictionary *args);
id CMToolCreateDirectory(NSDictionary *args);
id CMToolListDirectory(NSDictionary *args);
id CMToolMoveFile(NSDictionary *args);
id CMToolFileInfo(NSDictionary *args);
id CMToolEditBlock(NSDictionary *args);
id CMToolStartSearch(NSDictionary *args);
id CMToolMoreSearch(NSDictionary *args);
id CMToolStopSearch(NSDictionary *args);
id CMToolListSearches(NSDictionary *args);
id CMToolStartProcess(NSDictionary *args);
id CMToolInteract(NSDictionary *args);
id CMToolReadOutput(NSDictionary *args);
id CMToolForceTerminate(NSDictionary *args);
id CMToolListSessions(NSDictionary *args);
id CMToolListProcesses(NSDictionary *args);
id CMToolKillProcess(NSDictionary *args);
id CMToolScreenshot(NSDictionary *args);
id CMToolViewImage(NSDictionary *args);
id CMToolRepoInfo(NSDictionary *args);
id CMToolGit(NSDictionary *args, BOOL writing);
id CMToolSvn(NSDictionary *args, BOOL writing);
id CMToolGetConfig(NSDictionary *args);
id CMToolSetConfig(NSDictionary *args);
id CMToolUsage(NSDictionary *args);
id CMToolRecent(NSDictionary *args);
void CMShutdownSessions(void);

/* Running a program without a shell: its exit code (-1 when it timed out) and its output. */
int CMRunProgram(NSArray *argv, NSString *cwd, double timeout, NSDictionary *environment, NSString **output);
NSString *CMFindProgram(NSString *name);
