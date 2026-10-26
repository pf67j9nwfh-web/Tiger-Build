#import <Foundation/Foundation.h>

/* Commands the model starts to run in the background (the "bg" built-in tools). When one finishes, the window or the tb command wakes the chat
   with its result, so the model carries on without being asked. They run as this program's children and end with it. */
@interface TBBackground : NSObject
/* A new task's number, e.g. "bg3". Raises TBError when it cannot start. run is the turn that asked; chat is looked up through -noteRun:chat:. */
+ (NSString *)start:(NSString *)command label:(NSString *)label directory:(NSString *)directory run:(NSString *)runId;
+ (NSString *)describe:(NSString *)ident tail:(int)lines;     /* state, time, exit status and the last lines of output */
+ (NSString *)list;
+ (BOOL)stop:(NSString *)ident;
+ (void)stopAll;
/* The window or tb tells which chat a run belongs to, so a finished task finds its chat. */
+ (void)noteRun:(NSString *)runId chat:(NSString *)chat;
/* Tasks of that chat that have finished since the last call, each as the message to send: "Background task bg3 (...) finished...". */
+ (NSArray *)takeFinishedMessagesForChat:(NSString *)chat;
+ (NSArray *)chatsWithFinished;                                 /* the chats that have a finished task nobody has been told about */
+ (BOOL)hasFinishedForChat:(NSString *)chat;                   /* finished and not yet reported */
+ (BOOL)hasPendingForChat:(NSString *)chat;                    /* running or finished and not yet reported */
@end
