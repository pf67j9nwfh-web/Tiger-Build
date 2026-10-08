#import <Foundation/Foundation.h>
#include <pthread.h>

/* Newline-delimited JSON-RPC to a program's standard input and output: how Commander, and any MCP server that runs on
   this Mac, are spoken to. A port of the relay's McpClient. Used from worker threads. */
@interface TBMCPClient : NSObject {
    NSTask *task;
    NSFileHandle *toChild;
    NSFileHandle *fromChild;
    NSFileHandle *errorsFromChild;
    NSMutableData *pending;
    NSMutableData *errorTail;
    NSMutableArray *messages;
    pthread_mutex_t lock;
    pthread_cond_t arrived;
    BOOL ended;
    BOOL closed;
    int nextId;
    NSString *path;
    NSArray *arguments;
    NSDictionary *environment;
    NSString *label;
}
+ (TBMCPClient *)clientWithPath:(NSString *)path arguments:(NSArray *)arguments environment:(NSDictionary *)extraEnvironment label:(NSString *)label;
/* Starts the program and does the MCP handshake. Raises TBError, in words, if it cannot. */
- (void)start;
- (id)request:(NSString *)method params:(id)params timeout:(double)seconds;
- (void)notify:(NSString *)method params:(id)params;
/* Safe from any thread, and more than once. Ends the program. */
- (void)close;
- (void)cancel;
- (NSString *)stderrText;
@end

/* The text of a tool result, its pictures ({mime, data}), and a short line for the tool's card. */
NSString *TBMCPResultText(id result);
NSArray *TBMCPResultImages(id result);
NSString *TBMCPToolSummary(NSString *name, NSDictionary *arguments);
/* MCP tool descriptions as function tools ({name, description, parameters}). */
NSArray *TBMCPFunctionTools(id listed);

/* An MCP server reached over HTTP or HTTPS (Streamable HTTP: a POST per message, the answer as JSON or as an event stream).
   The same calls as TBMCPClient. A token, if given, is sent as a bearer. A server that does not take that (404, 405 or 400 to the first message) or whose address
   ends in /sse is reached with the older HTTP+SSE transport: one long GET carries the answers, and the messages are POSTed to the address it announces. */
@interface TBMCPHTTPClient : NSObject {
    NSString *url;
    NSString *token;
    NSString *session;
    int nextId;
    volatile int closed;
    id current;
    NSString *failure;
    BOOL legacy;                          /* the older HTTP+SSE transport */
    NSString *postURL;                    /* where it said to send messages */
    NSMutableDictionary *answers;         /* id -> reply, filled by the reader thread */
    NSString *streamError;
    volatile int streamEnded;
    id sseParser;
    BOOL freshAuth;
    NSString *lastChallenge;
}
+ (TBMCPHTTPClient *)clientWithURL:(NSString *)url token:(NSString *)token;
- (void)start;
- (id)request:(NSString *)method params:(id)params timeout:(double)seconds;
- (void)notify:(NSString *)method params:(id)params;
- (void)close;
- (void)cancel;
- (NSString *)stderrText;
@end
