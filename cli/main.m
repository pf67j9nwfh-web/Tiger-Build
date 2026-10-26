/* tb / tigerbuild: Tiger Build in the terminal. Uses the same engine, chats and settings as the window. */
#import <Foundation/Foundation.h>
#import "TBCLICore.h"
#import "TBCLIApp.h"
#import "TBEngine.h"
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
        "  -h, --help\n");
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
        i = [app runInteractive];
        [pool release];
        return i;
    }
    printer->json = [format hasPrefix:@"json"];
    printer->stream = [format isEqualToString:@"stream-json"];
    [core setEvents:printer];
    problem = [core sendText:prompt];
    if (problem) { fprintf(stderr, "tb: %s\n", [problem UTF8String]); return 1; }
    while ([core busy])
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    if (printer->json && !printer->stream)
        printf("{\"type\":\"result\",\"result\":\"%s\",\"chat\":\"%s\"}\n", [TBJSONEscape(printer->reply) UTF8String], [[chat objectForKey:@"id"] UTF8String]);
    else if (!printer->json)
        fputc('\n', stdout);
    [pool release];
    return 0;
}
