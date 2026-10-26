/* tb / tigerbuild: Tiger Build in the terminal. Uses the same engine, chats and settings as the window. */
#import <Foundation/Foundation.h>
#import "TBCLICore.h"
#import "TBCLIApp.h"
#import "TBBackground.h"
#import "TBSudoBroker.h"
#import "TBIntegrations.h"
#import "TBEngine.h"
#include <termios.h>
#include <pthread.h>
#include <sys/stat.h>
#include <Security/Security.h>
#include <unistd.h>
#include <stdio.h>

static void usage(void)
{
    fprintf(stderr,
        "usage: tb [options] [prompt]\n"
        "  -p, --print           answer once and exit (the prompt is the argument or standard input)\n"
        "  -c, --continue        continue the latest chat       -r, --resume [ID|text]  open a chat by number or search\n"
        "  -m, --model SPEC      service or model: grok, claude:claude-sonnet-5-5, gpt-4o\n"
        "      --no-tools        no tools        --tools a,b,c   only these tools (names from /tools)\n"
        "      --workspace NAME  the workspace whose chats to use\n"
        "      --output-format text|json|stream-json   (with -p)\n"
        "  -y, --yes             allow every tool without asking\n"
        "  -h, --help\n"
        "  tb login NAME | tb login --import | tb logout NAME | tb keys   API keys kept for use over ssh\n"
        "  tb [options] \"prompt\"   starts the interactive session with that first message\n");
}

/* -p: events go to the output */
@interface TBPrinter : NSObject <TBCLIEvents> {
@public
    BOOL json, stream, yes;
    NSMutableString *reply;
    int toolCalls;
}
@end

@implementation TBPrinter
- (id)init { self = [super init]; reply = [[NSMutableString alloc] init]; return self; }
- (void)core:(TBCLICore *)core text:(NSString *)delta
{
    [reply appendString:delta];
    if (!json) { fputs([delta UTF8String], stdout); fflush(stdout); }
    else if (stream) printf("{\"type\":\"text\",\"text\":\"%s\"}\n", [TBJSONEscape(delta) UTF8String]);
}
- (void)core:(TBCLICore *)core status:(NSString *)note error:(BOOL)error
{
    fprintf(stderr, "%s%s\n", error ? "error: " : "", [note UTF8String]);
}
- (void)core:(TBCLICore *)core activity:(NSDictionary *)event
{
    if ([[event objectForKey:@"phase"] isEqualToString:@"result"]) {
        toolCalls++;
        fprintf(stderr, "[%s %s]\n", [[event objectForKey:@"name"] UTF8String], [[event objectForKey:@"failed"] boolValue] ? "failed" : "done");
    }
}
- (void)core:(TBCLICore *)core thinking:(NSString *)delta {}
- (void)core:(TBCLICore *)core media:(NSString *)description { fprintf(stderr, "[%s: shown in the Tiger Build window]\n", [description UTF8String]); }
- (void)core:(TBCLICore *)core question:(NSDictionary *)event
{
    [core answer:yes ? @"allow" : @"deny"];
    if (!yes)
        fprintf(stderr, "[%s needs approval: denied (use --yes to allow)]\n", [[event objectForKey:@"name"] UTF8String]);
}
- (void)core:(TBCLICore *)core usage:(NSDictionary *)event {}
- (void)coreTurnEnded:(TBCLICore *)core { CFRunLoopStop(CFRunLoopGetCurrent()); }
@end

/* The saved keys are one Keychain item, and the first time this program reads it the system asks. Ask now, before anything else starts, so the question comes
   at the start and nothing waits on it half way (Commander included); say what it is if the answer takes a moment. Not over ssh: nobody is there to click. */
static volatile int keychainDone = 0;

static void *keychainHint(void *unused)
{
    int i;
    (void)unused;
    for (i = 0; i < 10 && !keychainDone; i++)
        usleep(100000);
    if (!keychainDone)
        fprintf(stderr, "Reading from the Keychain: if a window asks, choose Always Allow.\n");
    return NULL;
}

static void warmKeychain(BOOL quiet)
{
    pthread_t t;
    if (getenv("SSH_CONNECTION") || getenv("TB_NO_KEYCHAIN"))
        return;
    if (!quiet && pthread_create(&t, NULL, keychainHint, NULL) == 0)
        pthread_detach(t);
    [TBSettings keychainValueForName:@"openai_api_key"];
    keychainDone = 1;
}

/* Administrator mode (Preferences, Commander) lets a chat that has the sudo tool on use sudo through Commander. This program serves the saved password to that
   Commander, as the window does; the Keychain's question about it comes now, at the start. Not over ssh: nobody is there to answer it. */
static void startSudo(BOOL quiet)
{
    pthread_t t;
    if (getenv("SSH_CONNECTION") || getenv("TB_NO_KEYCHAIN") || ![TBSudoBroker administratorModeOn])
        return;
    keychainDone = 0;
    if (!quiet && pthread_create(&t, NULL, keychainHint, NULL) == 0)
        pthread_detach(t);
    [TBSudoBroker primeKeychain];
    keychainDone = 1;
    [TBSudoBroker start];
}

/* tb login [name] | tb login --import | tb logout name | tb keys: the key file that stands in for the Keychain over ssh */
static int keyCommand(NSArray *args)
{
    NSString *cmd = [args objectAtIndex:0], *path = [TBSettings keyFilePath];
    NSMutableDictionary *keys = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    NSArray *names = [TBSettings secretNames];
    NSString *name = [args count] > 1 ? [args objectAtIndex:1] : nil;
    unsigned i;
    if (!keys)
        keys = [NSMutableDictionary dictionary];
    if ([cmd isEqualToString:@"keys"]) {
        for (i = 0; i < [names count]; i++) {
            NSString *n = [names objectAtIndex:i];
            if ([n hasSuffix:@"_api_key"])
                printf("%-18s %s\n", [n UTF8String], getenv([[@"TB_" stringByAppendingString:[n uppercaseString]] UTF8String]) ? "environment" : [keys objectForKey:n] ? "key file" : [[TBSettings keychainValueForName:n] length] ? "keychain" : "-");
        }
        return 0;
    }
    if ([cmd isEqualToString:@"logout"]) {
        if (!name) { fprintf(stderr, "usage: tb logout NAME\n"); return 2; }
        [keys removeObjectForKey:name];
    } else if ([name isEqualToString:@"--import"]) {
        /* from the Keychain (run this at the Mac itself, where it can ask) */
        for (i = 0; i < [names count]; i++) {
            NSString *v = [TBSettings keychainValueForName:[names objectAtIndex:i]];
            if ([v length] && [[names objectAtIndex:i] hasSuffix:@"_api_key"])
                [keys setObject:v forKey:[names objectAtIndex:i]];
        }
    } else {
        char buf[1024];
        struct termios t, old;
        if (!name) {
            fprintf(stderr, "usage: tb login NAME   (one of:");
            for (i = 0; i < [names count]; i++)
                if ([[names objectAtIndex:i] hasSuffix:@"_api_key"])
                    fprintf(stderr, " %s", [[names objectAtIndex:i] UTF8String]);
            fprintf(stderr, ")\n       tb login --import   copy the keys from the Keychain\n");
            return 2;
        }
        if (![names containsObject:name]) { fprintf(stderr, "tb: unknown key %s (tb login lists them)\n", [name UTF8String]); return 2; }
        fprintf(stderr, "%s: ", [name UTF8String]);
        tcgetattr(0, &old);
        t = old;
        t.c_lflag &= ~ECHO;
        tcsetattr(0, TCSANOW, &t);
        buf[0] = 0;
        fgets(buf, sizeof buf, stdin);
        tcsetattr(0, TCSANOW, &old);
        fprintf(stderr, "\n");
        if (!strlen(buf) || buf[0] == '\n') return 1;
        [keys setObject:TBTrim([NSString stringWithUTF8String:buf]) forKey:name];
    }
    TBMakePath([path stringByDeletingLastPathComponent]);
    if (![keys writeToFile:path atomically:YES]) { fprintf(stderr, "tb: cannot write %s\n", [path UTF8String]); return 1; }
    chmod([path fileSystemRepresentation], 0600);
    fprintf(stderr, "saved in %s\n", [path UTF8String]);
    return 0;
}

int main(int argc, char **argv)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    TBCLICore *core = [TBCLICore core];
    TBPrinter *printer = [[[TBPrinter alloc] init] autorelease];
    NSMutableArray *words = [NSMutableArray array];
    NSString *model = nil, *resume = nil, *workspace = nil, *only = nil, *format = @"text";
    BOOL print = NO, cont = NO, notools = NO;
    NSMutableDictionary *chat;
    NSString *prompt, *problem = nil;
    int i;
    if (argc > 1 && (!strcmp(argv[1], "login") || !strcmp(argv[1], "logout") || !strcmp(argv[1], "keys"))) {
        NSMutableArray *rest = [NSMutableArray array];
        for (i = 1; i < argc; i++)
            [rest addObject:[NSString stringWithUTF8String:argv[i]]];
        return keyCommand(rest);
    }
    if (getenv("SSH_CONNECTION"))
        SecKeychainSetUserInteractionAllowed(FALSE);   /* nobody at the screen to click Allow */
    for (i = 1; i < argc; i++) {
        NSString *a = [NSString stringWithUTF8String:argv[i]];
        if ([a hasPrefix:@"-TB"] && i + 1 < argc) i++;   /* a preference given on the command line (NSArgumentDomain), for tests */
        else if ([a isEqualToString:@"-p"] || [a isEqualToString:@"--print"]) print = YES;
        else if ([a isEqualToString:@"-c"] || [a isEqualToString:@"--continue"]) cont = YES;
        else if (([a isEqualToString:@"-r"] || [a isEqualToString:@"--resume"]) && i + 1 < argc) resume = [NSString stringWithUTF8String:argv[++i]];
        else if (([a isEqualToString:@"-m"] || [a isEqualToString:@"--model"]) && i + 1 < argc) model = [NSString stringWithUTF8String:argv[++i]];
        else if ([a isEqualToString:@"--no-tools"]) notools = YES;
        else if ([a isEqualToString:@"--tools"] && i + 1 < argc) only = [NSString stringWithUTF8String:argv[++i]];
        else if ([a isEqualToString:@"--workspace"] && i + 1 < argc) workspace = [NSString stringWithUTF8String:argv[++i]];
        else if ([a isEqualToString:@"--output-format"] && i + 1 < argc) format = [NSString stringWithUTF8String:argv[++i]];
        else if ([a isEqualToString:@"-y"] || [a isEqualToString:@"--yes"]) printer->yes = YES;
        else if ([a isEqualToString:@"-h"] || [a isEqualToString:@"--help"]) { usage(); return 0; }
        else if ([a hasPrefix:@"-"] && ![a isEqualToString:@"-"]) { fprintf(stderr, "tb: unknown option %s\n", argv[i]); usage(); return 2; }
        else [words addObject:a];
    }
    if (workspace)
        [core openWorkspace:workspace];
    warmKeychain(print);
    startSudo(print);
    [core refreshCatalog];
    prompt = [words componentsJoinedByString:@" "];
    if (print && ![prompt length]) {
        NSData *in = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
        prompt = [[[NSString alloc] initWithData:in encoding:NSUTF8StringEncoding] autorelease];
    }
    if (cont && [[core chats] count])
        [core setCurrentChat:[[core chats] objectAtIndex:0]];
    else if (resume) {
        NSMutableDictionary *found = [core chatWithId:resume];
        if (!found && [[core searchChats:resume] count])
            found = [[core searchChats:resume] objectAtIndex:0];
        if (!found) { fprintf(stderr, "tb: no chat matches \"%s\"\n", [resume UTF8String]); return 1; }
        [core setCurrentChat:found];
    }
    chat = [core currentChat] ? [core currentChat] : [core newChat];
    if (model && ![core setModelSpec:model chat:chat error:&problem]) { fprintf(stderr, "tb: %s\n", [problem UTF8String]); return 1; }
    if (notools || only) {
        NSMutableDictionary *o = [NSMutableDictionary dictionary];
        NSArray *list = [core toolCatalog], *names = only ? [only componentsSeparatedByString:@","] : [NSArray array];
        for (i = 0; i < (int)[list count]; i++) {
            NSString *key = [[list objectAtIndex:i] objectForKey:@"id"];
            [o setObject:[NSNumber numberWithBool:[names containsObject:key]] forKey:key];
        }
        [core setRunOverrides:o];
    }
    if (!print) {
        TBCLIApp *app;
        if (![[TBTerm term] isInteractive]) { fprintf(stderr, "tb: needs a terminal; use -p for scripts\n"); return 1; }
        app = [[TBCLIApp alloc] initWithCore:core];
        app->initial = [prompt length] ? prompt : nil;
        i = [app runInteractive];
        [TBSudoBroker stop];
        [pool release];
        return i;
    }
    printer->json = [format hasPrefix:@"json"];
    printer->stream = [format isEqualToString:@"stream-json"];
    [core setEvents:printer];
    problem = [core sendText:prompt];
    if (problem) { fprintf(stderr, "tb: %s\n", [problem UTF8String]); return 1; }
    {
        NSString *chatId = [[chat objectForKey:@"id"] description];
        int wakes = 0;
        for (;;) {
            while ([core busy])
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
            /* background tasks the model started: wait for them and let it carry on, as the window does */
            if (wakes >= [TBIntegrations backgroundWakeLimit] || ![TBBackground hasPendingForChat:chatId])
                break;
            while (![TBBackground hasFinishedForChat:chatId])
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
            wakes++;
            problem = [core sendText:[core takeBackgroundMessage]];
            if (problem) { fprintf(stderr, "tb: %s\n", [problem UTF8String]); break; }
        }
        [TBBackground stopAll];
        [TBSudoBroker stop];
    }
    if (printer->json && !printer->stream)
        printf("{\"type\":\"result\",\"result\":\"%s\",\"chat\":\"%s\"}\n", [TBJSONEscape(printer->reply) UTF8String], [[chat objectForKey:@"id"] UTF8String]);
    else if (!printer->json)
        fputc('\n', stdout);
    [pool release];
    return 0;
}
